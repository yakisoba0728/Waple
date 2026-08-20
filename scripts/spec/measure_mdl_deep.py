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
             "메시수": mesh_total, "착지분포": dict(landings)},
            "확정" if not failures else "보고", [ev_corpus]),

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
                      "메시마다 서로 다른 머티리얼을 갖고 전수 착지"},
            "확정", [ev_bin, ev_rosetta]),

        specfmt.entry(
            "format.mdl.meshLayout",
            {"공통": "skinCount×cstring material | u32 gateWord | [gateWord&2: u32 extra] | "
                     "[v>=17: AABB min3f max3f = 24B] | [v>=15: u32 formatFlag] | "
                     "u32 vertexBytes | 정점 | u32 indexBytes | u16 인덱스 | [v>=21: 메시 트레일러]",
             "gateWord": "메시 능력 플래그. bit1(0x2)=여분 u32 1개, bit10/11/12/13 은 MDMP 레코드 구성을 게이팅",
             "인덱스": "u16 트라이앵글 리스트. 실측 maxIndex == vertexCount-1 이 %d/%d"
                       % (maxindex_ok, maxindex_total)},
            "확정", [ev_bin, ev_corpus]),

        specfmt.entry(
            "format.mdl.versionGates",
            {"AABB": "version >= 17 (디컴파일 `if (iVar11 < 0x11)`)",
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
             "비트": {"0x00000001": "POSITION float3 (12B)",
                      "0x00010000": "16B 위치 계열 (0x1 부재 시 이것이 위치)",
                      "0x02000000": "12B 위치 계열",
                      "0x00000002": "NORMAL float3 (12B) — 옵션 json `normals`",
                      "0x00000004": "TANGENT float4 (16B, w=handedness) — 옵션 json `tangentspace`",
                      "0x00800000": "BLENDINDICES uint4 (16B) — 옵션 json `skinning`",
                      "0x01000000": "BLENDWEIGHT float4 (16B) — 옵션 json `skinning`",
                      "0x00000008": "TEXCOORD0 float2 (8B)",
                      "0x00000010": "TEXCOORD0 float3 (12B)",
                      "0x00000020": "TEXCOORD float4 (16B) = UV0 in .xy + UV1 in .zw — "
                                    "옵션 json `seconduvchannel`",
                      "0x00008000": "float4 채널 (16B) — 의미 미독"},
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
                         "위치로 읽고 4번째는 무시하는 현행 처리가 맞다(4번째의 의미는 미상)"}},
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
             "주의": "빈 {} json 은 대조에서 제외한다. **이걸 '기본값 = 0x9' 로 읽으면 안 된다** — "
                     "실물에 {}+0x9(flow/glow)와 {}+0x0f(assets/models/editor/camera, "
                     "elementpreviews/collisionmodel/sphere)가 둘 다 있다. 빈 json 은 "
                     "'이 파일이 굽기 옵션을 안 담고 있다' 는 뜻이지 옵션이 기본값이라는 뜻이 아니다"},
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
             "종단자": "실측으로 확정된 것은 '메시/섹션 끝 뒤에 단일 0x00 이 온다'(189파일) 뿐이다. "
                       "그 0x00 이 '빈 cstring 이라 루프가 끝난다' 는 해석은 루프 구조와 모순이 없을 뿐 "
                       "종료 조건을 디컴파일에서 짚어 확인한 것은 아니다(추정)",
             "디스패치": ["MDLS0002/0003/0004", "MDLA0003..0006", "MDAT0001", "MDMP0001", "MDLE0002"],
             "실측 착지": dict(landings),
             "실측 섹션 도수": dict(sorted(sections.items())),
             "MDLV0004 예외": "v0004 파일 8개는 종단 NUL 없이 정확히 EOF 에서 끝난다 "
                              "(리더가 EOF 를 빈 문자열로 보고 루프를 끝내므로 동작은 동일)"},
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
            {"규칙": "인덱스 원소 폭은 정점 수가 정한다 — vertexCount <= 65535 면 u16, 넘으면 u32",
             "실측": f"u16 메시 {idx16}개(최대 vertexCount {idx16_max}) / "
                     f"u32 메시 {idx32}개(최소 vertexCount {idx32_min}) — 이 규칙으로 읽으면 "
                     f"maxIndex == vertexCount-1 이 {maxindex_ok}/{maxindex_total}",
             "오판시 증상": "u32 블롭을 u16 로 읽으면 상위 워드 0 이 섞여 maxIndex 가 정확히 0xFFFF 로 "
                            "찍히고(실측 17메시 전부) 삼각형이 뒤죽박죽이 된다. 정점 수보다 작으므로 "
                            "'maxIndex < vertexCount' 류의 검사로는 절대 안 걸린다",
             "경계": f"직접 목격한 경계는 ({idx16_max}, {idx32_min}] 구간이다. 65535 라는 값 자체는 "
                     "u16 주소지정 한계에서 온 추론이지 그 경계의 파일을 본 것은 아니다"},
            "확정", [ev_corpus]),

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
                     "벗어나 잘려 사라진다)"},
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
    print(f"옵션json 대조 일치 {opt_match} / 불일치 {len(opt_mismatch)}")
    for f, b in opt_mismatch:
        print(f"   {f}: {b}")
    for f in failures[:10]:
        print(f"   실패 {f}")
    print(f"-> {OUT}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
