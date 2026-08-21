"""`.mdl` 레이아웃 심층 측정 — spec/formats/mdl-deep.json 을 생성한다.

측정 대상은 두 벌이다:
  (1) 설치본 .mdl 28개 (Z:\\...\\wallpaper_engine 하위 전수)
  (2) 워크샵 코퍼스 scene.pkg 안의 .mdl 423개
합쳐 451개. 이 스크립트의 핵심 주장은 "버전별 메시 프레이밍 표 하나로
451개가 전부 EOF / 말미 NUL / 다음 섹션 매직에 정확히 착지한다" 이고,
그게 곧 레이아웃의 증명이다(한 필드라도 어긋나면 착지가 깨진다).

파서 본체는 verify_rosetta.py 와 공유한다 — 로제타석 16쌍 바이트 대조와
코퍼스 451개 착지 검증이 같은 코드로 돌아야 의미가 있다.
"""
import collections
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt
from verify_rosetta import FRAMING, SECTION_MAGICS, landing, parse_mdl, vertex_layout

WS = os.environ.get("WE_WORKSHOP", r"Z:\SteamLibrary\steamapps\workshop\content\431960")
WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), "spec", "formats", "mdl-deep.json")

# resourcecompiler 옵션 json 키 -> formatFlag 비트. 값은 실측 대응(측정에서 검증한다).
OPTION_BITS = {"normals": 0x2, "tangentspace": 0x4, "skinning": 0x0180_0000}


def parse_pkg(data):
    n, p = len(data), 0

    def i32():
        nonlocal p
        if p + 4 > n:
            raise ValueError("eof")
        v = struct.unpack_from("<i", data, p)[0]
        p += 4
        return v

    vlen = i32()
    if vlen < 0 or p + vlen > n:
        raise ValueError("bad vlen")
    p += vlen
    count = i32()
    if count < 0 or count > 65536:
        raise ValueError("bad count")
    entries = []
    for _ in range(count):
        nlen = i32()
        if nlen < 0 or p + nlen > n:
            raise ValueError("bad nlen")
        name = data[p:p + nlen].decode("utf-8", "ignore")
        p += nlen
        entries.append((name, i32(), i32()))
    return entries, p


def collect():
    """(출처, 이름, 바이트) 목록. 설치본은 경로도 함께 쓰려고 절대경로를 남긴다."""
    out = []
    for dirpath, _, files in os.walk(WE):
        for f in files:
            if f.lower().endswith(".mdl"):
                path = os.path.join(dirpath, f)
                with open(path, "rb") as fh:
                    out.append(("install", path, fh.read()))
    if os.path.isdir(WS):
        for wid in sorted(os.listdir(WS)):
            d = os.path.join(WS, wid)
            if not os.path.isdir(d):
                continue
            for fn in ("scene.pkg", "gifscene.pkg"):
                path = os.path.join(d, fn)
                if not os.path.exists(path):
                    continue
                try:
                    with open(path, "rb") as fh:
                        blob = fh.read()
                    entries, base = parse_pkg(blob)
                except ValueError:
                    continue
                for name, off, size in entries:
                    if name.lower().endswith(".mdl"):
                        out.append((wid, name, blob[base + off:base + off + size]))
    return out


def parse_mdmp(data, magic_off, meshes):
    """MDMP0001 모프 섹션. 레코드 내용은 **메시 게이트워드 비트**로 게이팅된다
    (엔진 디컴파일 FUN_140261950 의 MDMP 분기: bit10/11/12/13 각각 별도 리드,
    크기 불일치 시 trap). 성공하면 (끝오프셋, 레코드목록)."""
    p = magic_off + 8 + 1
    next_off = struct.unpack_from("<I", data, p)[0]
    p += 4
    records = []
    for mi in range(len(meshes)):
        count = struct.unpack_from("<H", data, p)[0]
        p += 2
        if count == 0:
            continue
        weight = struct.unpack_from("<f", data, p)[0]
        p += 4
        vcount = struct.unpack_from("<I", data, p)[0]
        p += 4
        gate = meshes[mi]["gate"]
        for _ in range(count):
            rid = struct.unpack_from("<Q", data, p)[0]
            p += 8
            end = data.index(b"\0", p)
            name = data[p:end].decode("utf-8", "replace")
            p = end + 1
            blobs = []
            for bit, unit in ((None, 6), (0x400, 6), (0x800, 6), (0x1000, 2)):
                if bit is not None and not (gate & bit):
                    continue
                size = struct.unpack_from("<I", data, p)[0]
                p += 4
                if size != vcount * unit:
                    raise ValueError(f"MDMP 블롭 {size} != vcount*{unit}")
                p += size
                blobs.append((bit, size))
            if gate & 0x2000:
                p += 16                     # u32 bone | u32 | f32 | f32
            records.append({"mesh": mi, "id": rid, "name": name,
                            "vcount": vcount, "weight": weight, "blobs": blobs})
    return p, next_off, records


ANIM_MODES = ("loop", "single", "mirror", "clamp")
MAX_BONES = 128                            # Sources/WapleCore/Model3DFormat.swift:98


def skeleton_bone_count(data):
    """MDLS 섹션의 본 수. `"MDLS000N" | u8 0 | u32 nextOff | u32 boneCount`.

    매직 스캔은 블롭 한복판에 오탐 착지할 수 있으므로 상한(`MAX_BONES`)으로 거른다 —
    Waple 이 `Model3D.swift:642` 에서 같은 이유로 상한을 100,000 → 128 로 좁혔다.
    """
    i = data.find(b"MDLS000")
    if i < 0 or i + 17 > len(data):
        return None
    n = struct.unpack_from("<I", data, i + 13)[0]
    return n if 0 < n <= MAX_BONES else None


def _cstring(data, p, limit=96):
    e = data.find(b"\0", p)
    if e < 0 or e - p > limit:
        return None
    return data[p:e].decode("utf-8", "replace"), e + 1


def parse_mdla(data, magic_off, bone_count):
    """MDLA 애니 섹션의 **클립마다** 본 트랙 프레이밍을 잰다. (클립목록, 위반목록).

    엔진이 강제하는 불변식(둘 다 어기면 `int 0x29` = __fastfail):

        trackBytes % 36 == 0            (0x140263c78 lea/0x140263c7c shl 로 몫×36 을 만들어
                                         0x140263c80 sub 로 나머지를 내고 0x140263c8e test →
                                         0x140263c95 int 0x29)
        trackBytes / 36 == frameCount + 1
                                        (0x140263c61 movabs 0xe38e38e38e38e38f · 0x140263c71 mul ·
                                         0x140263c74 shr rdx,5 = /36 · 0x140263c83 inc ecx =
                                         frameCount+1 · 0x140263c85 cmp → 0x140263c8c int 0x29)

    **Waple 은 앞의 하나만 본다**(`Model3D.swift:759` `tsRaw % 36 == 0`) — 뒤의
    `frameCount + 1` 관계는 어디에서도 검사하지 않는다. 그것이 이 측정의 이유다.

    레이아웃은 `Sources/WapleCore/Model3D.swift` 의 `parseAnimations` 를 그대로 옮겼다
    (그쪽이 워크샵 33 애니모델 전수로 검증된 모델이다):

        "MDLA000N" | u8 0 | u32 nextOff | u32 animCount | u32 baseId | u32 0
        클립: cstring 이름 | cstring 모드 | f32 fps | u32 frameCount | u32 0 | u32 boneCount | u32 0
              본별: u32 trackBytes | trackBytes | u32 blob2Bytes | blob2Bytes
              가변 트레일러(32~39B) → 다음 클립 헤더를 ≤256B 앞에서 **리싱크**로 찾는다
    """
    def try_header(p):
        got = _cstring(data, p)
        if not got or not got[0]:
            return None
        name, p2 = got
        got = _cstring(data, p2, limit=16)
        if not got or (got[0] and got[0] not in ANIM_MODES):
            return None
        mode, p3 = got
        if p3 + 20 > len(data):
            return None
        fps = struct.unpack_from("<f", data, p3)[0]
        if not (0 < fps <= 240):
            return None
        frames, bc = struct.unpack_from("<I", data, p3 + 4)[0], struct.unpack_from("<I", data, p3 + 12)[0]
        if bc != bone_count:
            return None
        return dict(name=name, mode=mode, fps=fps, frames=frames, bones=bc, off=p3 + 20)

    clips, bad = [], []
    p = magic_off + 9
    if p + 16 > len(data):
        return clips, bad
    p += 16
    while True:
        h = try_header(p)
        if h is None:
            break
        p = h["off"]
        tracks, ok = [], True
        for bi in range(h["bones"]):
            if p + 4 > len(data):
                ok = False
                break
            ts = struct.unpack_from("<I", data, p)[0]
            if p + 4 + ts > len(data):
                ok = False
                break
            p += 4
            if ts % 36:
                bad.append({"clip": h["name"], "bone": bi, "trackBytes": ts,
                            "why": "36 의 배수가 아니다(나머지 %d)" % (ts % 36)})
            elif ts // 36 != h["frames"] + 1:
                bad.append({"clip": h["name"], "bone": bi, "trackBytes": ts,
                            "why": "키 %d개인데 frameCount+1 = %d" % (ts // 36, h["frames"] + 1)})
            p += ts
            if p + 4 > len(data):
                ok = False
                break
            blob2 = struct.unpack_from("<I", data, p)[0]
            if p + 4 + blob2 > len(data):
                ok = False
                break
            p += 4 + blob2
            tracks.append(ts)
        if not ok or len(tracks) != h["bones"]:
            bad.append({"clip": h["name"], "bone": len(tracks), "trackBytes": None,
                        "why": "본 트랙이 잘렸다(%d/%d)" % (len(tracks), h["bones"])})
            break
        clips.append({"name": h["name"], "mode": h["mode"], "fps": round(h["fps"], 4),
                      "frames": h["frames"], "bones": h["bones"],
                      "keysPerTrack": (tracks[0] // 36) if tracks else 0})
        nxt = None
        for d in range(257):               # 가변 트레일러 리싱크(Model3D.swift:779 와 동일 폭)
            if try_header(p + d) is not None:
                nxt = p + d
                break
        if nxt is None:
            break
        p = nxt
    return clips, bad


def channel_probe(data, mesh, tally, sample=256):
    """정점 채널 **오프셋**을 값의 성질로 검증한다.

    stride 가 맞는다고 채널 자리가 맞는 건 아니다 — 위치는 항상 오프셋 0 이라
    '위치가 obj 안에 있다' 로는 나머지 채널을 하나도 못 잡는다. 그래서 표가
    산출한 오프셋에서 값을 꺼내 그 채널이어야만 성립하는 성질을 본다:
    법선/탄젠트xyz 는 단위길이, 탄젠트 w 는 ±1, 웨이트 4성분 합은 1.0.
    (특히 웨이트 합 1.0 은 스키닝 정점 레이아웃 — boneIndices/weights 오프셋 —
    을 독립으로 확증하는 유일한 수단이다. 로제타석 16쌍은 전부 정적 메시라
    이 경로를 하나도 안 밟는다.)"""
    n = mesh["count"]
    step = max(1, n // sample)
    for i in range(0, n, step):
        base = mesh["vbase"] + i * mesh["stride"]
        for key, kind in (("normal", "unit3"), ("tangent", "tangent4"),
                          ("weights", "sum1"), ("position16", "pos16w")):
            off = mesh["offsets"].get(key)
            if off is None:
                continue
            if kind == "unit3":
                x, y, z = struct.unpack_from("<3f", data, base + off)
                tally["normal.total"] += 1
                tally["normal.unit"] += abs((x * x + y * y + z * z) ** 0.5 - 1.0) <= 1e-3
            elif kind == "tangent4":
                x, y, z, w = struct.unpack_from("<4f", data, base + off)
                tally["tangent.total"] += 1
                tally["tangent.unit"] += abs((x * x + y * y + z * z) ** 0.5 - 1.0) <= 1e-3
                tally["tangent.w1"] += abs(abs(w) - 1.0) <= 1e-3
            elif kind == "sum1":
                w = struct.unpack_from("<4f", data, base + off)
                tally["weights.total"] += 1
                tally["weights.sum1"] += abs(sum(w) - 1.0) <= 1e-3
            elif kind == "pos16w":
                w = struct.unpack_from("<4f", data, base + off)[3]
                tally["pos16.total"] += 1
                tally["pos16.w1"] += abs(w - 1.0) <= 1e-6
                tally["pos16.w0"] += abs(w) <= 1e-6
        off = mesh["offsets"].get("boneIndices")
        if off is not None:
            bi = struct.unpack_from("<4I", data, base + off)
            tally["boneIdx.total"] += 1
            tally["boneIdx.small"] += all(b < 4096 for b in bi)


def main():
    # **[2026-08-20] 자기 입력 가드.** 종전엔 코퍼스 없이도 끝까지 돌아 파일수/메시수를
    # 0/0 으로 쓰려 했다 — 유일한 방어선이 `specfmt.dump` 의 축소 가드였다(그 가드에도
    # 부분 축소 구멍이 있었다). 자매 생성기 11개처럼 입력을 직접 본다.
    # 이 문서의 도수(파일수·메시수·스킨 분포·gateWord 분포)는 **워크샵 코퍼스**에서 나온다.
    # 설치본만으로 돌리면 분포에서 키가 통째로 사라진다 — 실측으로 확인했다(축소 가드가
    # `skinCount: 키 2개 소멸`, `gateWord 값: 키 7개 소멸` 로 잡는다). 축소 가드가 뒤에서
    # 잡아 주긴 하지만, 그 자리에서 나오는 메시지는 "무엇이 없어서" 인지를 말하지 않는다.
    if not os.path.isdir(WS):
        raise SystemExit(
            f"[measure_mdl_deep] 워크샵 코퍼스가 없다: {WS}\n"
            f"  WE_WORKSHOP 으로 코퍼스 루트를 지정하라 — 설치본(WE_ROOT={WE})만으로 돌리면\n"
            f"  스킨/gateWord 분포에서 키가 사라져 근거만 지워진다.")
    files = collect()
    if not files:
        raise SystemExit(
            f"[measure_mdl_deep] 입력 경로는 있는데 `.mdl` 을 하나도 못 찾았다"
            f"(WE_WORKSHOP={WS} · WE_ROOT={WE}) — 경로가 맞는지 확인하라.")
    versions = collections.Counter()
    landings = collections.Counter()
    stride_by_flag = collections.Counter()
    skin_counts = collections.Counter()
    mesh_counts = collections.Counter()
    gate_words = collections.Counter()
    header_flag_ne_mesh = 0
    mesh_total = 0
    parse_ok = 0
    failures = []
    sections = collections.Counter()
    maxindex_ok = maxindex_total = 0
    idx16 = idx32 = 0
    idx16_max, idx32_min = 0, 1 << 62
    static_exact = static_total = skin_exact = skin_total = 0
    skin_worst = 0.0
    static_outliers = []
    tally = collections.Counter()
    gate_hi_meshes = []

    for src, name, data in files:
        try:
            mdl = parse_mdl(data)
        except (ValueError, IndexError, struct.error) as e:
            failures.append((src, name, str(e)))
            continue
        land = landing(data, mdl["end"])
        if land is None:
            failures.append((src, name, f"미착지 @{mdl['end']}/{len(data)}"))
            continue
        parse_ok += 1
        versions[mdl["magic"]] += 1
        landings["섹션매직" if land not in ("EOF", "말미NUL") else land] += 1
        skin_counts[mdl["skinCount"]] += 1
        mesh_counts[mdl["meshCount"]] += 1
        for mi, m in enumerate(mdl["meshes"]):
            mesh_total += 1
            stride_by_flag[(m["flag"], m["stride"])] += 1
            gate_words[m["gate"]] += 1
            channel_probe(data, m, tally)
            if m["gate"] & 0x3C00:          # MDMP 레코드를 게이팅하는 bit10..13
                gate_hi_meshes.append({"file": f"{src}:{os.path.basename(name)}", "mesh": mi,
                                       "gate": f"0x{m['gate']:x}",
                                       "hasMDMP": data.find(b"MDMP0001") >= 0})
            if m["flag"] != mdl["headerFlag"]:
                header_flag_ne_mesh += 1
            if m["count"] > 0xFFFF:
                idx32 += 1
                idx32_min = min(idx32_min, m["count"])
            else:
                idx16 += 1
                idx16_max = max(idx16_max, m["count"])
            if m["indices"]:
                maxindex_total += 1
                if max(m["indices"]) == m["count"] - 1:
                    maxindex_ok += 1
            if m["aabb"] is not None and m["positions"]:
                worst = max(max(abs(m["aabb"][a] - min(q[a] for q in m["positions"])),
                                abs(m["aabb"][3 + a] - max(q[a] for q in m["positions"])))
                            for a in range(3))
                if m["flag"] & 0x0180_0000:
                    skin_total += 1
                    skin_exact += worst <= 1e-4
                    skin_worst = max(skin_worst, worst)
                else:
                    static_total += 1
                    if worst <= 1e-4:
                        static_exact += 1
                    else:
                        static_outliers.append({"file": f"{src}:{os.path.basename(name)}",
                                                "mesh": mi, "편차": round(worst, 4),
                                                "flag": f"0x{m['flag']:x}"})
        for magic in SECTION_MAGICS:
            i = data.find(magic, max(mdl["end"] - 1, 0))
            if i >= 0:
                sections[data[i:i + 8].decode("ascii", "replace")] += 1

    # MDMP 섹션 실물 파스
    mdmp_ok, mdmp_fail, mdmp_examples = 0, [], []
    for src, name, data in files:
        i = data.find(b"MDMP0001")
        if i < 0:
            continue
        try:
            mdl = parse_mdl(data)
            end, next_off, recs = parse_mdmp(data, i, mdl["meshes"])
        except (ValueError, IndexError, struct.error) as e:
            mdmp_fail.append((src, name, str(e)))
            continue
        land = landing(data, end)
        if land is None:
            mdmp_fail.append((src, name, f"미착지 @{end}/{len(data)}"))
            continue
        mdmp_ok += 1
        for r in recs[:1]:
            mdmp_examples.append({"file": f"{src}:{os.path.basename(name)}", "name": r["name"],
                                  "id": r["id"], "morphVertexCount": r["vcount"],
                                  "blobs": [{"gateBit": (f"0x{b:x}" if b else "필수"), "bytes": s}
                                            for b, s in r["blobs"]]})

    # MDLA 애니 섹션 — 클립마다 본 트랙 프레이밍 불변식(36 배수 · frameCount+1)
    mdla_files = mdla_ok = 0
    mdla_clips = 0
    mdla_bad = []
    mdla_noskel = []
    anim_bones = collections.Counter()
    anim_frames = collections.Counter()
    anim_per_file = collections.Counter()
    anim_modes = collections.Counter()
    mdla_magics = collections.Counter()
    for src, name, data in files:
        i = data.find(b"MDLA000")
        if i < 0:
            continue
        mdla_files += 1
        mdla_magics[data[i:i + 8].decode("ascii", "replace")] += 1
        bc = skeleton_bone_count(data)
        if bc is None:
            mdla_noskel.append(f"{src}:{os.path.basename(name)}")
            continue
        clips, bad = parse_mdla(data, i, bc)
        for b in bad:
            mdla_bad.append(dict(b, file=f"{src}:{os.path.basename(name)}"))
        if clips and not bad:
            mdla_ok += 1
        mdla_clips += len(clips)
        anim_per_file[len(clips)] += 1
        for c in clips:
            anim_bones[c["bones"]] += 1
            anim_frames[c["frames"]] += 1
            anim_modes[c["mode"] or "(빈 모드=디렉토리 레코드)"] += 1

    # 설치본 .mdl <-> 형제 옵션 json 대조
    opt_match, opt_mismatch = 0, []
    for src, path, data in files:
        if src != "install":
            continue
        jp = path[:-4] + ".json"
        if not os.path.exists(jp):
            continue
        try:
            with open(jp, encoding="utf-8-sig") as fh:
                opts = json.load(fh)
        except (ValueError, OSError):
            continue
        if not opts:
            continue                       # 빈 {} 는 옵션 미기재 — 대조 대상 아님
        mdl = parse_mdl(data)
        want_skin = len(opts["skins"]) if isinstance(opts.get("skins"), list) else 1
        bad = []
        if want_skin != mdl["skinCount"]:
            bad.append(f"skins {want_skin} != {mdl['skinCount']}")
        for key, bit in OPTION_BITS.items():
            for m in mdl["meshes"]:
                if bool(opts.get(key)) != bool(m["flag"] & bit):
                    bad.append(f"{key} {bool(opts.get(key))} vs flag 0x{m['flag']:x}")
                    break
        if bad:
            opt_mismatch.append((os.path.relpath(path, WE), bad))
        else:
            opt_match += 1

    ev_corpus = specfmt.ev("corpus", f"워크샵 scene.pkg 내부 .mdl + 설치본 .mdl 전수 {len(files)}개",
                           "scripts/spec/measure_mdl_deep.py")
    ev_rosetta = specfmt.ev("file", "projects/defaultprojects/*/models/*.{obj,mdl} 16쌍",
                            "scripts/spec/verify_rosetta.py — 16/16 대조 통과")
    ev_bin = specfmt.ev("binary", "wallpaper64.exe FUN_140261950 (RVA 0x261880)",
                        "MDL 디코더 디컴파일")
    ev_rc = specfmt.ev("binary", "bin/resourcecompiler64.exe FUN_140020260 (RVA 0x20260)",
                       ".mdl 굽기 경로 — MDLV0023 문자열과 skins/normals/tangentspace 옵션 키를 같이 참조")

    entries = [
        specfmt.entry(
            "format.mdl.parseCoverage",
            {"파일수": len(files), "착지성공": parse_ok, "실패": len(failures),
             "메시수": mesh_total, "착지분포": dict(landings),
             # **[2026-08-21 추가]** "착지성공 451/451" 이 파일 내용 전체를 검증한 것으로
             # 읽히는 오독을 막는다. 이 수치가 말하는 것은 **메시 섹션까지의 프레이밍**뿐이다.
             "검사 범위": {
                 "이 수치가 뜻하는 것": "헤더 + 메시 섹션(정점/인덱스/AABB/메시 트레일러)을 "
                                         "버전별 프레이밍 표로 끝까지 읽었을 때 파스 끝이 EOF · "
                                         "말미 NUL · 다음 섹션 매직 중 하나에 **정확히 닿는다** 는 것. "
                                         "한 필드라도 어긋나면 착지가 깨지므로 메시 프레이밍의 증명이다",
                 "이 수치가 뜻하지 않는 것": "스켈레톤(MDLS)·애니(MDLA)·부착점(MDAT)·에디터(MDLE) "
                                              "섹션의 **내용**은 이 451/451 에 들어 있지 않다. "
                                              "그 넷은 메시 섹션 뒤에 오므로 착지가 성공해도 내용은 "
                                              "안 읽힌 채다",
                 "섹션별 실제 검사 깊이": {
                     "메시/정점/인덱스/AABB": "깊이 파스 + 불변식(stride·maxIndex·채널 성질·AABB 대조)",
                     "MDMP0001": "깊이 파스 + 착지 검증(format.mdl.mdmpSection)",
                     "MDLA": "**[2026-08-21 신설]** 클립별 본 트랙 프레이밍 "
                             "(format.mdl.mdlaTrackFraming)",
                     "MDLS0002/0003/0004": "매직 도수만. 본 계층·부모 인덱스·바인드 행렬·꼬리 "
                                           "T1..T7 은 **여기서 안 본다** — Waple 쪽 파서와 테스트는 "
                                           "Sources/WapleCore/Model3D.swift 의 parseSkeletonTail 에 있다",
                     "MDAT0001": "매직 도수만. 부착점 이름·본 인덱스·로컬 행렬은 안 본다",
                     "MDLE0002": "매직 도수만. 64B 강체변환 블록은 안 본다",
                 }}},
            "확정" if not failures else "보고", [ev_corpus]),

        specfmt.entry(
            "format.mdl.mdlaTrackFraming",
            {"불변식": "MDLA 클립의 본 트랙 블롭 `trackBytes` 는 **36 의 배수**이고 "
                       "`trackBytes / 36 == frameCount + 1` 이다. 엔진은 둘 다 어기면 "
                       "`int 0x29`(__fastfail) 로 즉시 죽는다 — 즉 **엔진 자신이 강제하는 불변식**이라 "
                       "실물 파일은 전건 만족해야 한다",
             "근거 명령열": "wallpaper64.exe 0x140263c5c movsxd r8,[rsp+0x70](trackBytes) · "
                             "0x140263c61 movabs rax,0xe38e38e38e38e38f · 0x140263c6b mov ecx,[rbp+0xbc]"
                             "(frameCount) · 0x140263c71 mul r8 · 0x140263c74 shr rdx,5 (= /36) · "
                             "0x140263c78 lea rax,[rdx+rdx*8] · 0x140263c7c shl rax,2 (= 몫×36) · "
                             "0x140263c80 sub r8,rax (= 나머지) · 0x140263c83 inc ecx (= frameCount+1) · "
                             "0x140263c85 cmp rdx,rcx → 0x140263c8c int 0x29 · "
                             "0x140263c8e test r8,r8 → 0x140263c95 int 0x29",
             "키 레이아웃": "36B = pos 3f | 오일러각 3f(라디안) | 스케일 3f",
             "Waple 격차": "Sources/WapleCore/Model3D.swift 의 parseAnimations 는 `tsRaw % 36 == 0` "
                           "만 본다 — `frameCount + 1` 관계는 어디서도 검사하지 않는다. "
                           "그래서 프레임 수와 키 수가 어긋난 파일을 조용히 받아들인다",
             "왜 +1 인가": "[미해결] 마지막 프레임을 닫는 키(루프 복귀 키)로 보이지만 확인하지 못했다. "
                           "엔진이 강제한다는 것만 확정이다",
             "실측": {"MDLA 보유 파일": mdla_files, "클립 전건 통과 파일": mdla_ok,
                      "클립 수": mdla_clips, "위반": mdla_bad[:20],
                      "스켈레톤 본수를 못 읽어 건너뛴 파일": mdla_noskel[:20],
                      "매직": dict(sorted(mdla_magics.items()))},
             "본 수 분포": {str(k): v for k, v in sorted(anim_bones.items())},
             "프레임 수 분포": {str(k): v for k, v in sorted(anim_frames.items())},
             "파일당 클립 수 분포": {str(k): v for k, v in sorted(anim_per_file.items())},
             "모드 분포": dict(sorted(anim_modes.items())),
             "표본 없음일 때": "설치본만 붙은 환경에서는 MDLA 보유 파일이 0개다(설치본 .mdl 28개 전부 "
                               "MDLS/MDLA 0건 — 2026-08-21 실측). 그때 위 도수는 전부 비고 위반도 0이다. "
                               "**0/0 은 불변식을 증명하지 않는다** — 그래서 status 를 표본 유무로 가른다. "
                               "합성 픽스처 양성 대조는 scripts/spec/tests/test_mdla_framing.py",
             "파스 모델 출처": "Sources/WapleCore/Model3D.swift parseAnimations — 워크샵 33 애니모델 "
                               "전수 파스로 검증된 모델을 그대로 옮겼다(가변 트레일러는 ≤256B 리싱크)"},
            "확정" if (mdla_clips and not mdla_bad) else "보고",
            [specfmt.ev("binary", "wallpaper64.exe 0x140263c61–0x140263c95",
                        "MDLA 트랙 프레이밍 __fastfail 두 개"),
             ev_corpus,
             specfmt.ev("script", "scripts/spec/tests/test_mdla_framing.py",
                        "합성 픽스처 음성 대조 — 36 배수 위반 · frameCount+1 위반 · 다중 클립 리싱크")]),

        specfmt.entry(
            "format.mdl.header",
            {"레이아웃": 'cstring magic "MDLV%04d" (9B, NUL 포함) | u32 formatFlag | u32 skinCount | u32 meshCount',
             "총 21바이트": True,
             "formatFlag@9": "정점 포맷 기본값. v>=15 는 메시마다 덮어쓴다",
             "skinCount@13": "메시마다 읽는 머티리얼 cstring 개수(스킨 = 같은 메시의 재질 변형). "
                             "meshCount 가 아니다 — 실물에 skinCount=1·meshCount=64 파일이 있다",
             "meshCount@17": "서브메시 개수"},
            "확정", [ev_bin, ev_corpus,
                     specfmt.ev("file", "projects/defaultprojects/audiophile/models/grid/grid.{mdl,json}",
                                "모델 옵션 json 의 skins 2개 ↔ .mdl skinCount=2 ↔ 머티리얼 cstring 2개. "
                                "같은 메시의 fantasticcar 짝은 skins 1개/문자열 1개, 파일 크기 차 25B = "
                                '"materials/grid/grid2.json\\0" 길이와 정확히 일치')]),

        specfmt.entry(
            "format.mdl.stringLoopIsPerMesh",
            {"결론": "머티리얼 cstring 은 파일 선두의 전역 문자열 표가 아니라 메시 블록마다 skinCount 개씩 온다",
             "근거1": "디컴파일: 메시 do-루프 **안**에서 `if (param_3[1] != 0) do { cstring } "
                      "while (i < param_3[1])` — param_3[1] 이 헤더 오프셋 13 필드",
             "근거2": "실물 skinCount=1·meshCount=3/4 파일(orbitaleffects/orbitsmall)이 "
                      "메시마다 서로 다른 머티리얼을 갖고 전수 착지",
             "skinCount == 0": "**0 이면 0개다**(2026-08-21). 리드 루프가 카운터를 0 으로 놓고 "
                               "0x14026193e cmp dword [r15+8], ebx / 0x140261942 jbe 0x140261979 로 "
                               "**먼저 재므로** cstring 을 한 개도 안 읽고 gateWord 로 넘어간다"
                               "([r15+8] 은 0x1402618fb 에서 저장된 skinCount). 종전 Waple 구현은 "
                               "여기서 1개를 읽어 이후 전 오프셋을 cstring 길이만큼 밀었다 — "
                               "**실물 미목격이라 무회귀지만 엔진과 다르게 읽는 자리였다**"},
            "확정", [ev_bin, ev_rosetta]),

        specfmt.entry(
            "format.mdl.meshLayout",
            {"공통": "skinCount×cstring material | u32 gateWord | [gateWord&2: u32 extra] | "
                     "[v>=17: AABB min3f max3f = 24B] | [v>=15: u32 formatFlag] | "
                     "u32 vertexBytes | 정점 | u32 indexBytes | 인덱스 | [v>=21: 메시 트레일러]",
             "gateWord": "메시 능력 플래그. bit1(0x2)=여분 u32 1개, bit10/11/12/13 은 MDMP 레코드 구성을 게이팅",
             # **[2026-08-21 정정]** 종전 이 두 줄은 인덱스를 **u16 고정**으로 적었다. 폭은
             # gateWord bit0 이 정한다 — `format.mdl.indexWidth` 가 같은 파일 안에서 이미 그렇게
             # 적고 있었으므로 이 엔트리는 **정본 안에서 자기모순**이었다.
             "인덱스": "트라이앵글 리스트. **원소 폭 = 2 + 2*(gateWord & 1)** 바이트다"
                       "(u16 고정이 아니다 — format.mdl.indexWidth 참조). "
                       "실측 maxIndex == vertexCount-1 이 %d/%d"
                       % (maxindex_ok, maxindex_total)},
            "확정", [ev_bin, ev_corpus]),

        specfmt.entry(
            "format.mdl.versionGates",
            {"AABB": "version >= 17 (디컴파일 `if (iVar11 < 0x11)`)",
             "섹션루프": "version >= 13 (0x140262382 cmp edi, 0x0d / jl 0x140265a0c). "
                         "메시 섹션 뒤 MDLS/MDAT/MDLA/MDMP/MDLE 디스패치 루프 전체를 게이팅한다 — "
                         "**게이트 경계 13 은 다른 넷 어디와도 다른 값이고, v0004 가 종단 NUL 없이 "
                         "끝나는 이유가 이것이다**",
             "perMeshFormatFlag": "version >= 15 (디컴파일 `if (0xe < iVar11) goto 읽기`) — "
                                  "v<=14 는 헤더 formatFlag 를 그대로 쓴다",
             "gateWord": "version >= 4 (디컴파일 `if (iVar11 < 4) gate = 0`)",
             "메시트레일러": "version >= 21 (디컴파일 `if (0x14 < iVar11)`)",
             "모프레코드": "version >= 23 (디컴파일 `if (0x16 < iVar11)`)",
             "관측버전": {k: v for k, v in sorted(versions.items())},
             "미관측": "0015/0018/0020/0022 — 게이트 경계값 15 는 바이너리에서만 확인(실물 없음)"},
            "확정", [ev_bin, ev_corpus]),

        specfmt.entry(
            "format.mdl.formatFlagBits",
            {"표": "stride = set bit 의 기여 합, 채널 오프셋은 테이블 인덱스 오름차순 누적",
             # **[2026-08-21]** 종전 이 표는 **11엔트리**였고 TEXCOORD1-5 의 15비트를 통째로
             # 비워 뒀다. 그 비트를 단 플래그는 표 불해결로 떨어져 추측 경로(꼬리고정 uv@stride-8)를
             # 타고 **TEXCOORD1 을 uv0 으로 읽는다**. 아래는 `.rdata` 병렬 배열 넷을 통째로 떠서
             # 채운 전 26엔트리다(값은 Sources/WapleCore/Model3D.swift 의 vertexLayoutTable 과 동일).
             "표 출처": "wallpaper64.exe .rdata 병렬 배열 4개 ×26 — 마스크 0x140484a20 · "
                        "바이트크기 0x1404849b0 · 속성이름 0x140484a90 · "
                        "디스크립터{nameIdx,typeIdx,semanticIdx,semanticNumber} 0x140482fa0. "
                        "스트라이드 누산 루프가 이 표를 그대로 돈다(0x140261a3a-0x140261b2b: "
                        "SSE 로 idx0..23 을 4개씩 6묶음, 스칼라 꼬리 0x140261b10/0x140261b1a 와 "
                        "0x140261b25 cmp rax,0x1a → 0x140261b2b mov [rbp+0xac],ecx). "
                        "독립 사본이 0x1400ea5b0(스트라이드 전용 헬퍼)에도 있다",
             "타입": "**전 채널이 32비트 float 다** — BLENDINDICES(idx5)만 uint4. 정규화·팩 포맷이 "
                     "아예 없고 a_Color 도 u8x4 가 아니라 float4 다",
             "상위 6비트": "26엔트리 마스크의 합집합이 정확히 하위 26비트(0x03FFFFFF)다. 누산 루프가 "
                           "idx 26 이상을 아예 안 보므로(0x140261b25 cmp rax,0x1a) 상위 6비트는 "
                           "스트라이드 기여가 0 이다 — 무시가 곧 엔진 동작이다",
             "비트": {"0x00000001": "idx0  a_Position       float3 : POSITION0     (12B)",
                      "0x00010000": "idx1  a_PositionVec4   float4 : POSITION0     (16B) — "
                                    "0x1 부재 시 이것이 위치. 4번째 성분은 동차좌표 w 가 아니다(아래 항목)",
                      "0x02000000": "idx2  a_PositionC1     float3 : POSITION1     (12B)",
                      "0x00000002": "idx3  a_Normal         float3 : NORMAL0       (12B) — 옵션 json `normals`",
                      "0x00000004": "idx4  a_Tangent4       float4 : TANGENT0      (16B, w=handedness) — "
                                    "옵션 json `tangentspace`",
                      "0x00800000": "idx5  a_BlendIndices   uint4  : BLENDINDICES0 (16B) — 옵션 json `skinning`",
                      "0x01000000": "idx6  a_BlendWeights   float4 : BLENDWEIGHT0  (16B) — 옵션 json `skinning`",
                      "0x00000008": "idx7  a_TexCoord       float2 : TEXCOORD0     (8B)",
                      "0x00000010": "idx8  a_TexCoordVec3   float3 : TEXCOORD0     (12B) — uv 는 .xy",
                      "0x00000020": "idx9  a_TexCoordVec4   float4 : TEXCOORD0     (16B) — "
                                    "uv0=.xy, uv1=.zw. 옵션 json `seconduvchannel`",
                      "0x00000040": "idx10 a_TexCoordC1     float2 : TEXCOORD1     (8B)",
                      "0x00000080": "idx11 a_TexCoordVec3C1 float3 : TEXCOORD1     (12B)",
                      "0x00000100": "idx12 a_TexCoordVec4C1 float4 : TEXCOORD1     (16B)",
                      "0x00000200": "idx13 a_TexCoordC2     float2 : TEXCOORD2     (8B)",
                      "0x00000400": "idx14 a_TexCoordVec3C2 float3 : TEXCOORD2     (12B)",
                      "0x00000800": "idx15 a_TexCoordVec4C2 float4 : TEXCOORD2     (16B)",
                      "0x00001000": "idx16 a_TexCoordC3     float2 : TEXCOORD3     (8B)",
                      "0x00002000": "idx17 a_TexCoordVec3C3 float3 : TEXCOORD3     (12B)",
                      "0x00004000": "idx18 a_TexCoordVec4C3 float4 : TEXCOORD3     (16B)",
                      "0x00020000": "idx19 a_TexCoordC4     float2 : TEXCOORD4     (8B)",
                      "0x00040000": "idx20 a_TexCoordVec3C4 float3 : TEXCOORD4     (12B)",
                      "0x00080000": "idx21 a_TexCoordVec4C4 float4 : TEXCOORD4     (16B)",
                      "0x00100000": "idx22 a_TexCoordC5     float2 : TEXCOORD5     (8B)",
                      "0x00200000": "idx23 a_TexCoordVec3C5 float3 : TEXCOORD5     (12B)",
                      "0x00400000": "idx24 a_TexCoordVec4C5 float4 : TEXCOORD5     (16B)",
                      "0x00008000": "idx25 a_Color          float4 : COLOR0        (16B) — "
                                    "**표 인덱스 25 = 항상 맨 뒤**라 다른 채널 오프셋을 밀지 않는다. "
                                    "**[2026-08-21 정정]** 종전 이 줄은 '의미 미독 float4' 였다"},
             "TEXCOORD1-5 오독": "이 15비트가 표에 없던 동안 그 비트를 단 플래그는 stride 를 추측으로 "
                                 "메웠고, 그 경로의 꼬리고정 규칙(uv@stride-8)이 **TEXCOORD1 을 uv0 으로** "
                                 "읽었다. 예: 플래그 0x4f 면 진짜 uv0 은 @40 인데 @48 을 읽는다. "
                                 "maxIndex 가드도 골든도 이 클래스를 구조적으로 못 잡는다 — 회귀 핀은 "
                                 "Tests/WapleCoreTests/Model3DVertexLayoutTests.swift 의 "
                                 "testTexCoord1FlagResolvesUV0AtTableOffset",
             "실측 flag->stride": {f"0x{f:08x}": {"stride": s, "메시수": c}
                                   for (f, s), c in sorted(stride_by_flag.items())},
             "헤더flag != 메시flag 인 메시": header_flag_ne_mesh,
             "결론": "per-mesh flag 가 있으면 그쪽이 정본이다 — 헤더 flag 와 다른 메시가 실물에 있다",
             "채널 오프셋 검증": {
                 "방법": "stride 가 맞아도 채널 자리는 안 맞을 수 있다(위치는 늘 오프셋 0 이라 "
                         "위치 대조로는 못 잡는다). 표가 산출한 오프셋에서 값을 꺼내 그 채널이어야만 "
                         "성립하는 성질을 본다 — 메시당 최대 256정점 균등 샘플",
                 "normal 단위길이": f"{tally['normal.unit']}/{tally['normal.total']}",
                 "tangent xyz 단위길이": f"{tally['tangent.unit']}/{tally['tangent.total']}",
                 "tangent w = ±1": f"{tally['tangent.w1']}/{tally['tangent.total']}",
                 "weights 4성분 합 = 1.0": f"{tally['weights.sum1']}/{tally['weights.total']}",
                 "boneIndices < 4096": f"{tally['boneIdx.small']}/{tally['boneIdx.total']}",
                 "의의": "웨이트 합 1.0 이 스키닝 레이아웃(boneIndices/weights 오프셋)을 독립으로 "
                         "확증한다 — 로제타석 16쌍은 전부 정적 메시라 이 경로를 하나도 안 밟는다. "
                         "boneIndices 는 weights 와 인접이라 함께 결정된다"},
             "0x00010000 채널 4번째 성분": {
                 "표본": tally["pos16.total"], "값 1.0": tally["pos16.w1"], "값 0.0": tally["pos16.w0"],
                 "결론": "동차좌표 w 가 아니다 — 1.0 은 거의 없고 대부분 0.0 이다. 앞 3성분만 "
                         "위치로 읽고 4번째는 무시하는 현행 처리가 맞다(4번째의 의미는 미상)"},
             "0x00000020 의 .zw 가 두 번째 UV 라는 셰이더 측 근거": {
                 "선언": "shaders/generic.vert 이 #if LIGHTMAP 에서 a_TexCoord 를 vec4 로 받는다",
                 "샘플": "shaders/generic.frag 이 texSample2D(g_LightmapMapSampler, v_TexCoord.zw) 로 "
                         ".zw 만 샘플한다",
                 "설치본 도달": "projects/defaultprojects/arsenal/models/pistols/pistols.mdl 6메시 — "
                                "옵션 json \"seconduvchannel\": true, 재질 6개 중 4개가 \"lightmap\": 1",
                 "실측 분리": "uv0 범위 [-3.70, 4.71](타일링) vs uv1 범위 [0.0019, 0.9982](아틀라스) — "
                              "서로 다른 UV 집합임이 값으로도 갈린다"}},
            "확정", [ev_corpus, ev_rosetta,
                     specfmt.ev("file", "projects/defaultprojects/arsenal/models/pistols/pistols.{mdl,json}",
                                'json 이 {"normals":true,"seconduvchannel":true,"tangentspace":true} 이고 '
                                "flag=0x27(=0x1|0x2|0x4|0x20, stride 56). uv float4 의 .xy 는 u∈[0.002,1.999] "
                                "타일링, .zw 는 [0.002,0.998] 로 서로 다른 UV 집합 — 2채널 패킹 확증")]),

        specfmt.entry(
            "format.mdl.compilerOptionMapping",
            {"옵션json": "모델 .mdl 과 같은 이름의 .json 이 resourcecompiler 굽기 옵션이다",
             "키": "normals / tangentspace / seconduvchannel / skinning / normalizeuvs / skins / "
                   "materialbasedirectory / materialdirectory",
             "대조": {"일치": opt_match, "불일치": len(opt_mismatch),
                      "불일치목록": [{"file": f, "사유": b} for f, b in opt_mismatch]},
             # 종전 이 문장은 `measure_mdl_deep.py:301` 로 **줄 번호**를 가리켰다. 이 파일에
             # 한 줄만 더해도 그 참조가 거짓이 되므로(2026-08-21 에 실제로 밀렸다) 줄 번호를 뺀다.
             # 나머지 문면은 정본에 사람이 손질해 둔 판(강조 포함)을 생성기 쪽으로 되가져온 것이다 —
             # 종전엔 정본만 손질돼 있어 재생성하면 그 강조가 조용히 사라지는 상태였다.
             "주의": "짝 `.json` 이 **없는** .mdl 은 대조에서 제외한다(옵션 대조 루프의 "
                     "`if not os.path.exists(jp): continue`). **이걸 '옵션 부재 = 기본값' 으로 "
                     "읽으면 안 된다** — 설치본 실측(28개 전수, 2026-08-20 재측정): 짝 json 없음 "
                     "**14**개 / 옵션 있음 14개, **빈 `{}` 는 0개**. 그 14개의 formatFlag 는 "
                     "0x9 12개 · 0xf 2개로 **갈린다**(0x9: audiophile flow·glow, ricepod "
                     "jet·skybox·orbitaleffects, fantasticcar dome·shadow, retro bgfade, "
                     "dna_fragment bgfade, techno glow·rays·orbitsmall / 0xf: "
                     "assets/models/editor/camera, particleelementpreviews/collisionmodel/sphere). "
                     "즉 json 부재는 '이 파일이 굽기 옵션을 안 담고 있다' 는 뜻이지 옵션이 어떤 "
                     "기본값이라는 뜻이 아니다. **[2026-08-20 정정]** 종전 이 줄은 같은 논증을 "
                     "*'빈 {} json'* 으로 적고 네 파일을 그 예로 들었는데, 네 파일 모두 빈 json 이 "
                     "아니라 **json 이 아예 없다**. 논증은 그대로 성립하고 분류만 틀렸다."},
            "확정", [ev_rc, specfmt.ev("file", "projects/defaultprojects/*/models/*/*.json",
                                       "설치본 모델 옵션 json ↔ .mdl formatFlag/skinCount 대조")]),

        specfmt.entry(
            "format.mdl.meshTrailer",
            {"게이트": "version >= 21",
             "레이아웃": "u8 gateA [≠0: u32 word | u32 size | size바이트] | "
                         "u8 gateB [≠0: u32 size | size바이트(16B 레코드 N개)] | "
                         "[v>=23: u32 morphCount | morphCount×(u64 id | cstring name | u32 flags | "
                         "u32 n1 | n1×u32 | u32 n2 | n2×u32)]",
             "전부 0 일 때 크기": "v>=23 은 6바이트, v21/22 는 2바이트"},
            "확정", [ev_bin, ev_corpus]),

        specfmt.entry(
            "format.mdl.sectionLoop",
            {"구조": "메시 섹션 뒤는 `cstring 을 읽어 매직으로 strncmp 디스패치` 하는 do-루프다"
                     "(디컴파일에서 루프와 5개 분기를 직접 확인)",
             "버전게이트": "**섹션 루프는 v >= 13 에서만 돈다** — 0x140262382 cmp edi, 0x0d / "
                             "jl 0x140265a0c 로 v<13 이면 루프를 통째로 건너뛴다. "
                             "메시 루프가 끝난 직후(0x14026232f)의 모델 AABB 집계 뒤에 온다",
             "종단자": "**확정(2026-08-21)**. v>=13 경로가 0x1402623d8 에서 섹션 매직을 cstring 으로 "
                       "읽고 0x1402623ec/0x1402623f4 je 로 **빈 문자열이면 루프를 끝낸다**. "
                       "그것이 실물 말미 단일 0x00 의 정체다(189파일). "
                       "**[2026-08-21 정정]** 종전 이 줄은 같은 결론을 적으면서 '종료 조건을 "
                       "디컴파일에서 짚어 확인한 것은 아니다(추정)' 로 헤지했다 — 이제 짚었다",
             "디스패치": ["MDLS0002/0003/0004", "MDLA0003..0006", "MDAT0001", "MDMP0001", "MDLE0002"],
             "실측 착지": dict(landings),
             "실측 섹션 도수": dict(sorted(sections.items())),
             # **[2026-08-21]** 이 도수를 "섹션 개수" 로 읽으면 틀린다 — 그렇게 읽힌다는
             # 지적을 받아 뜻을 못박는다.
             "실측 섹션 도수의 뜻": "매직마다 `data.find` **1회**다 — 그 매직을 가진 **파일 수**이지 "
                                     "섹션 수가 아니다. 한 파일에 같은 매직이 둘 있어도 1로 센다. "
                                     "(같은 이유로 블롭 한복판의 가짜 매직도 1로 셀 수 있다 — "
                                     "Waple 의 매직 스캔이 실제로 그 오탐에 당한 적이 있다: "
                                     "Tests/WapleCoreTests/Model3DTrailerSkeletonTailTests.swift 의 "
                                     "가짜 MDLA 회귀 테스트.) 섹션 **내용**은 MDMP/MDLA 만 판다",
             "MDLV0004 예외": "v0004 파일 8개는 종단 NUL 없이 정확히 EOF 에서 끝난다. "
                              "**[2026-08-21 정정]** 종전 사유는 '리더가 EOF 를 빈 문자열로 보고 루프를 "
                              "끝낸다' 였는데 그게 아니다 — **v0004 는 애초에 섹션 루프에 들어가지 않는다**"
                              "(위 버전게이트, v>=13). 그래서 쓸 종단자도 없다. "
                              "**v0004 와 v0014 의 유일한 컨테이너 차이가 이것**이다(다른 게이트 넷 — "
                              "AABB v>=17 · per-mesh flag v>=15 · 트레일러 v>=21 · 모프 v>=23 — 은 "
                              "둘 다 미충족이라 갈리지 않는다)"},
            "확정", [ev_corpus, ev_bin]),

        specfmt.entry(
            "format.mdl.mdmpSection",
            {"레이아웃": '"MDMP0001" | u8 0 | u32 nextOff | '
                         "메시마다: u16 recordCount | [≠0: f32 weight | u32 morphVertexCount | "
                         "recordCount×레코드]",
             "레코드": "u64 id | cstring name | u32 size + 블롭(size == morphVertexCount*6) | "
                       "[gate&0x400: 같은 크기 블롭] | [gate&0x800: 같은 크기 블롭] | "
                       "[gate&0x1000: u32 size + 블롭(size == morphVertexCount*2)] | "
                       "[gate&0x2000: u32 bone | u32 | f32 | f32]",
             "gate": "그 메시의 gateWord(머티리얼 cstring 직후 u32). 디컴파일이 참조하는 것은 "
                     "메시 구조체 +0x18 이라 그것이 gateWord 라는 동정 자체는 간접인데, 실물이 "
                     "이를 뒷받침한다 — bit10..13 중 하나라도 선 메시는 전 코퍼스에 "
                     f"{len(gate_hi_meshes)}개뿐이고 그 파일이 정확히 MDMP0001 보유 파일과 일치한다",
             "bit10..13 보유 메시": gate_hi_meshes,
             "블롭 해석": "6B/정점 = half3 위치 델타(추정), 2B/정점 = u16 정점 인덱스(희소 모프). "
                          "엔진은 크기가 어긋나면 즉시 trap 하므로 단위는 확정, **의미는 추정**",
             "실측": {"보유파일": mdmp_ok + len(mdmp_fail), "파스+착지성공": mdmp_ok,
                      "실패": [{"file": f"{a}:{os.path.basename(b)}", "why": c} for a, b, c in mdmp_fail],
                      "예시": mdmp_examples}},
            "확정" if mdmp_ok and not mdmp_fail else "보고", [ev_bin, ev_corpus]),

        specfmt.entry(
            "format.mdl.indexWidth",
            {"규칙": "인덱스 원소 폭은 **gateWord bit0** 이 정한다 — 폭 = 2 + 2*(gateWord & 1). "
                     "포맷이 자기기술하며 정점 수는 이 사슬 어디에도 들어가지 않는다",
             "규칙 근거": ".mdl 전용 GPU 업로드 경로 0x1401d7760(파스 직후 0x1401d5bb1 에서 호출): "
                          "movzx ecx,byte[rdi+0x18](0x1401d784c) -> and cl,1(0x1401d7853) -> "
                          "lea r9d,[r10*2+2](0x1401d7870) -> idiv r9d(0x1401d7878). 그 플래그가 "
                          "인자로 넘어가(0x1401d786b) 소비처 0x14009a98d 에서 test edx,edx -> cmove 로 "
                          "0x39(R16_UINT) / 0x2a(R32_UINT) 를 고르고 ByteWidth 도 같은 비트로 갈린다",
             "실측": f"u16 메시 {idx16}개(최대 vertexCount {idx16_max}) / "
                     f"u32 메시 {idx32}개(최소 vertexCount {idx32_min}) — 어느 규칙으로 읽어도 "
                     f"maxIndex == vertexCount-1 이 {maxindex_ok}/{maxindex_total}",
             "오판시 증상": "u32 블롭을 u16 로 읽으면 상위 워드 0 이 섞여 maxIndex 가 정확히 0xFFFF 로 "
                            "찍히고(실측 17메시 전부) 삼각형이 뒤죽박죽이 된다. 정점 수보다 작으므로 "
                            "'maxIndex < vertexCount' 류의 검사로는 절대 안 걸린다",
             "경계": f"직접 목격한 vertexCount 경계는 ({idx16_max}, {idx32_min}] 구간이다. 65535 라는 "
                     f"값 자체는 u16 주소지정 한계에서 온 추론이지 그 경계의 파일을 본 것은 아니다 — "
                     f"그리고 **그 추론이 규칙이 아니라는 것이 위 '규칙 근거' 로 확정됐다**. 이 줄은 "
                     f"종전 항목이 스스로 달아 둔 헤지이고, 그 헤지가 옳았다는 기록으로 남긴다",
             "종전 규칙이 맞아 보였던 이유": f"관측 코퍼스에서 두 규칙이 완전히 겹친다 — 정점이 65535 를 "
                     f"넘는 메시는 내보내기 도구가 gateWord bit0 을 세우기 때문이다. 갈리는 것은 bit0 이 "
                     f"선 작은 메시와 비트가 없는 큰 메시뿐이고 둘 다 코퍼스에 없다. 설치본도 45메시 "
                     f"전건 gateWord 0 / 최대 정점수 10,995 라 같은 답을 낸다. 즉 위 '실측' 은 전부 참이지만 "
                     f"그건 **상관**이지 규칙이 아니다 — '이 코퍼스에서 성립한다' 와 '엔진이 이렇게 정한다' 는 "
                     f"다른 명제이고, 후자는 코드를 읽어야만 나온다",
             "코드 상태": "Sources/WapleCore/Model3D.swift:577 `let iWidth = (gateWord & 1) == 0 ? 2 : 4` "
                          "— 커밋 0197a2d 로 코드가 먼저 고쳐졌고 이 정본이 뒤늦게 따라왔다"},
            "확정", [ev_bin, ev_corpus]),

        specfmt.entry(
            "format.mdl.aabb",
            {"위치": "v>=17 메시 헤더의 6f (min xyz, max xyz)",
             "정적 메시": f"{static_exact}/{static_total} 이 그 메시 정점 위치의 최소/최대와 1e-4 이내 일치",
             "정적 예외": static_outliers or "없음",
             "예외 해석": "예외 3개는 전부 *_puppet.mdl 이다 — 정점 플래그에 스키닝 비트가 없어 "
                          "'정적' 으로 분류됐을 뿐 스켈레톤을 달고 움직이는 모델이다. 즉 경계는 "
                          "'스키닝 비트' 가 아니라 '애니메이션 여부' 로 갈리는 것으로 보인다(추정)",
             "스키닝 메시": f"{skin_exact}/{skin_total} 만 일치. 나머지는 크게 벗어난다(최대 편차 "
                            f"{skin_worst:.1f} 단위) — 바인드 포즈 정점이 아니라 애니메이션을 "
                            "포함한 넉넉한 경계로 보인다(미확정)",
             "결론": "움직이지 않는 메시에 한해 '정점 바운딩 박스' 다. 애니메이션 모델의 산출식은 "
                     "미상 — 컬링에 쓸 때 바인드 포즈 박스로 대체하면 안 된다(포즈가 박스를 "
                     "벗어나 잘려 사라진다)",
             "모델 AABB 는 파일에 없다": {
                 "산출": "메시 루프가 끝난 직후 0x14026232f 에서 집계 헬퍼 0x1402617c0 을 부른다 — "
                         "min 을 +FLT_MAX(0x7f7fffff), max 를 -FLT_MAX(0xff7fffff) 로 놓고"
                         "(0x1402617c0-0x1402617e3) 원소 0xC8 짜리 메시 벡터를 훑으며 "
                         "메시 AABB min@+0x20 / max@+0x2c 를 minss/maxss 로 누적한다"
                         "(0x140261800-0x140261865). 결과는 모델 구조체 +0x1b8(min) / +0x1c4(max)",
                 "폴백 ±131072": "헬퍼는 `comiss` 로 max.x > min.x 인지 보고 al 을 돌려준다"
                                 "(0x140261867/0x14026186a, 메시 0개면 0x14026186e 의 -FLT_MAX 비교). "
                                 "**거짓이면** 호출자가 min 을 0xc8000000(=-131072.0f), max 를 "
                                 "0x48000000(=+131072.0f)로 덮어쓴다"
                                 "(0x140262349 / 0x14026234f / 0x14026235a / 0x140262365 / "
                                 "0x14026236c / 0x140262377)",
                 "언제 밟히나": "**v<17 은 메시 AABB 자체가 파일에 없다**. 그 경우 메시 AABB 슬롯이 "
                                "채워지지 않으므로 집계가 퇴화하고 이 ±131072 상자가 그대로 모델 "
                                "경계가 된다 — v0004(설치본 8) · v0014(설치본 15)가 여기다. "
                                "메시가 0개인 파일도 같은 자리로 떨어진다",
                 "함의": "**컬링·프레이밍에 쓰는 모델 경계는 파일이 주는 값이 아니다.** v>=17 은 "
                         "메시 AABB 의 합집합, v<17 은 상수 상자다. 정점에서 다시 재면 엔진과 "
                         "다른 답이 된다(더 타이트해져 v<17 모델이 다르게 프레이밍된다)"}},
            "확정", [ev_corpus, ev_rosetta]),

        specfmt.entry(
            "format.mdl.uvOriginFlip",
            {"결론": "구운 UV 의 V 는 OBJ 의 1-v 다(텍스처 원점 규약 차)",
             "실측": "로제타석 16쌍 전부 뒤집힌 집합에 포함. 그중 11쌍은 원본 집합과 불일치라 "
                     "방향이 유일하게 결정되고, 5쌍은 UV 가 0/1 코너뿐이라 두 집합이 같아 판정 불가"},
            "확정", [ev_rosetta]),

        specfmt.entry(
            "format.mdl.skinCountDistribution",
            {"skinCount": dict(sorted(skin_counts.items())),
             "meshCount 상위": dict(mesh_counts.most_common(10)),
             "gateWord 값": {f"0x{k:x}": v for k, v in sorted(gate_words.items())}},
            "확정", [ev_corpus]),

        specfmt.entry(
            "format.mdl.vertexDedupRule",
            {"관측": "mdl 정점 수는 obj `v` 수 이상이다(면 코너 전개로 복제). 16쌍 중 12쌍은 "
                     "obj 면 코너의 고유 (v,vt,vn) 조합 수와 정확히 같지만 4쌍은 어긋난다 "
                     "(flow 153→163, dome 145→236, jet 48→60, shadow 184→90)",
             "해석": "리소스컴파일러가 법선/탄젠트를 재생성한 뒤 그 값으로 분할·병합하는 것으로 보인다 "
                     "(dome/jet 의 obj 는 vn 이 아예 없고, shadow 는 mdl 이 법선을 담지 않는다). "
                     "OBJ 만으로 재현할 수 없어 검증기는 '줄지 않는다' 만 강제한다",
             "미해결": "정확한 분할 기준(스무딩 각도 등)"},
            "추정", [ev_rosetta]),
    ]

    doc = specfmt.doc("scripts/spec/measure_mdl_deep.py", entries,
                      {"note": "verify_rosetta.py 와 파서를 공유한다 — 16쌍 바이트 대조와 "
                               "451개 착지 검증이 같은 코드로 돌아야 한다"})
    specfmt.dump(doc, OUT)

    print(f"파일 {len(files)} / 착지성공 {parse_ok} / 실패 {len(failures)} / 메시 {mesh_total}")
    print(f"착지: {dict(landings)}")
    print(f"AABB 정적 {static_exact}/{static_total}, 스키닝 {skin_exact}/{skin_total} "
          f"(최대편차 {skin_worst:.1f}), maxIndex 일치 {maxindex_ok}/{maxindex_total}")
    print(f"인덱스 u16 {idx16}(최대 vcount {idx16_max}) / u32 {idx32}(최소 vcount {idx32_min})")
    print(f"채널 오프셋: normal {tally['normal.unit']}/{tally['normal.total']} 단위, "
          f"tangent {tally['tangent.unit']}/{tally['tangent.total']} 단위·w±1 {tally['tangent.w1']}, "
          f"weights 합1 {tally['weights.sum1']}/{tally['weights.total']}, "
          f"boneIdx<4096 {tally['boneIdx.small']}/{tally['boneIdx.total']}, "
          f"pos16 w1={tally['pos16.w1']} w0={tally['pos16.w0']} n={tally['pos16.total']}")
    print(f"정적 AABB 예외: {static_outliers}")
    print(f"gate bit10..13 메시: {len(gate_hi_meshes)}")
    print(f"MDMP 파스+착지 {mdmp_ok} (실패 {len(mdmp_fail)})")
    print(f"MDLA 보유 {mdla_files} / 전건통과 {mdla_ok} / 클립 {mdla_clips} / "
          f"트랙 프레이밍 위반 {len(mdla_bad)} / 스켈레톤 미판독 {len(mdla_noskel)}")
    for b in mdla_bad[:10]:
        print(f"   MDLA 위반 {b}")
    print(f"옵션json 대조 일치 {opt_match} / 불일치 {len(opt_mismatch)}")
    for f, b in opt_mismatch:
        print(f"   {f}: {b}")
    for f in failures[:10]:
        print(f"   실패 {f}")
    print(f"-> {OUT}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
