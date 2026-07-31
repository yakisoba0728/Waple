"""로제타석 검증 — WE 기본 프로젝트의 .obj(소스)와 .mdl(컴파일 결과) 대조.

.mdl 은 정본 생성 수단이 없다(resourcecompiler 의 -mdl 은 무한 스핀,
.mdl -> obj 역변환 부재). 대신 projects/defaultprojects/*/models/ 에
같은 이름의 .obj 와 .mdl 이 공존한다. OBJ 는 정점이 평문이므로
이것으로 .mdl 파서를 바이트 단위 검증할 수 있다.

16쌍 전부(MDLV0004/0014/0023, formatFlag 0x09/0x0b/0x0f) 대조한다.
버전별 메시 프레이밍은 추측이 아니라 전수 착지 측정으로 정했다 —
scripts/spec/measure_mdl_deep.py 가 설치본+코퍼스 .mdl 451개를 이 표로
파싱해 451/451 이 EOF/말미NUL/다음섹션매직에 정확히 착지함을 보인다.
표에 없는 버전(0015/0018/0020/0022 등 미목격)은 SKIP 한다 — 레이아웃을
모르면서 '대조 통과' 를 만드는 것이 이 검증기가 가장 하면 안 되는 일이다.
"""
import os
import struct
import sys

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")

# 정점 레이아웃 테이블 — (비트, 바이트, 채널). stride 는 set bit 의 기여 합,
# 채널 오프셋은 **테이블 인덱스 오름차순** 누적(비트 값 순이 아니다).
# 출처: wallpaper64.exe .rdata 의 (마스크,기여) 26엔트리 — Waple Model3D.swift
# vertexLayoutTable 과 동일한 표. 여기 실린 11개는 실물 .mdl 에서 관측된 비트만.
VERTEX_CHANNELS = [
    (0x0000_0001, 12, "position"),     # POSITION float3
    (0x0001_0000, 16, "position16"),   # 16B pos 계열(position 부재 시 이것이 pos)
    (0x0200_0000, 12, "position12"),
    (0x0000_0002, 12, "normal"),       # NORMAL float3
    (0x0000_0004, 16, "tangent"),      # TANGENT float4 (w = handedness)
    (0x0080_0000, 16, "boneIndices"),  # BLENDINDICES uint4
    (0x0100_0000, 16, "weights"),      # BLENDWEIGHT float4
    (0x0000_0008, 8, "uv2"),           # TEXCOORD0 float2
    (0x0000_0010, 12, "uv3"),          # TEXCOORD0 float3
    (0x0000_0020, 16, "uv4"),          # TEXCOORD0 float4
    (0x0000_8000, 16, "unknown8000"),  # float4 채널(색 후보 — 미독)
]
KNOWN_BITS = 0
for _b, _s, _n in VERTEX_CHANNELS:
    KNOWN_BITS |= _b

# 버전 -> (AABB 유무, per-mesh formatFlag 유무, 메시 트레일러 유무).
# 전수 착지 측정으로 확정(measure_mdl_deep.py). 미목격 버전은 넣지 않는다.
FRAMING = {
    4:  (False, False, False),
    14: (False, False, False),
    16: (False, True, False),
    17: (True, True, False),
    19: (True, True, False),
    21: (True, True, True),
    23: (True, True, True),
}

SECTION_MAGICS = (b"MDLS", b"MDLA", b"MDAT", b"MDLE", b"MDMP")


def vertex_layout(flag):
    """flag -> (stride, {채널: 오프셋}). 미지 비트가 하나라도 있으면 None."""
    if flag == 0 or flag & ~KNOWN_BITS:
        return None
    offsets = {}
    stride = 0
    for bit, size, name in VERTEX_CHANNELS:
        if flag & bit:
            offsets[name] = stride
            stride += size
    return stride, offsets


def parse_obj(text):
    """v / vt / vn / f 를 읽는다. f 는 (vi, ti, ni) 코너 목록, 인덱스는 0 기반."""
    v, vt, vn, f, groups = [], [], [], [], []
    mtl = None
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        tag = parts[0]
        if tag == "v" and len(parts) >= 4:
            v.append(tuple(float(x) for x in parts[1:4]))
        elif tag == "vt" and len(parts) >= 3:
            vt.append(tuple(float(x) for x in parts[1:3]))
        elif tag == "vn" and len(parts) >= 4:
            vn.append(tuple(float(x) for x in parts[1:4]))
        elif tag == "usemtl" and len(parts) >= 2:
            mtl = parts[1]
        elif tag == "f":
            face = []
            for p in parts[1:]:
                bits = p.split("/")
                vi = int(bits[0]) - 1
                ti = int(bits[1]) - 1 if len(bits) > 1 and bits[1] else None
                ni = int(bits[2]) - 1 if len(bits) > 2 and bits[2] else None
                face.append((vi, ti, ni))
            f.append(face)
            groups.append(mtl)
    return {"v": v, "vt": vt, "vn": vn, "f": f, "groups": groups}


def parse_mdl(data):
    """MDLV0004~0023 메시 섹션 파서. 지원하지 않는 버전은 ValueError."""
    if data[:4] != b"MDLV":
        raise ValueError(f"MDLV 매직이 아니다: {data[:8]!r}")
    magic = data[:8].decode("ascii", "ignore")
    try:
        version = int(data[4:8])
    except ValueError:
        raise ValueError(f"버전 숫자 파싱 불가: {magic}")
    if version not in FRAMING:
        raise ValueError(f"{magic} 프레이밍 미확정 — 실물 미목격 버전은 읽지 않는다")
    if data[8] != 0:
        raise ValueError("매직 뒤 NUL 종단자가 없다")
    has_aabb, has_mesh_flag, has_trailer = FRAMING[version]

    header_flag, skin_count, mesh_count = struct.unpack_from("<III", data, 9)
    p = 21
    meshes = []
    for _ in range(mesh_count):
        # 머티리얼 cstring 은 메시당 skinCount 개다(스킨 = 같은 메시의 재질 변형).
        materials = []
        for _ in range(max(skin_count, 1)):
            end = data.index(b"\0", p)
            materials.append(data[p:end].decode("utf-8", "replace"))
            p = end + 1
        gate = struct.unpack_from("<I", data, p)[0]
        p += 4
        if gate & 2:            # bit1 이 서면 u32 가 정확히 하나 더 온다
            p += 4
        aabb = None
        if has_aabb:
            aabb = struct.unpack_from("<6f", data, p)
            p += 24
        flag = header_flag
        if has_mesh_flag:
            flag = struct.unpack_from("<I", data, p)[0]
            p += 4
        vertex_bytes = struct.unpack_from("<I", data, p)[0]
        p += 4
        if vertex_bytes == 0 or p + vertex_bytes > len(data):
            raise ValueError(f"vertexBytes {vertex_bytes} 가 파일 범위 밖")
        vbase, p = p, p + vertex_bytes

        index_bytes = struct.unpack_from("<I", data, p)[0]
        p += 4
        if index_bytes % 2 or p + index_bytes > len(data):
            raise ValueError(f"indexBytes {index_bytes} 불량")
        ibase, p = p, p + index_bytes

        lay = vertex_layout(flag)
        if lay is None:
            raise ValueError(f"미등록 formatFlag 0x{flag:08x}")
        stride, offsets = lay
        if vertex_bytes % stride:
            raise ValueError(f"vertexBytes {vertex_bytes} % stride {stride} != 0 (flag 0x{flag:08x})")
        count = vertex_bytes // stride

        # 인덱스 폭은 정점 수가 정한다 — u16 로 못 가리키면 u32 다(실측 986/986:
        # vertexCount <= 65535 인 969 메시는 u16, > 65535 인 17 메시는 u32 로 읽어야
        # maxIndex == vertexCount-1 이 성립한다. u16 로 읽으면 상위 워드 0 이 섞여
        # maxIndex 가 정확히 0xFFFF 로 찍히고 삼각형이 뒤죽박죽이 된다).
        if count > 0xFFFF:
            if index_bytes % 4:
                raise ValueError(f"indexBytes {index_bytes} 가 4의 배수가 아니다(u32 인덱스)")
            indices = struct.unpack_from(f"<{index_bytes // 4}I", data, ibase) if index_bytes else ()
        else:
            indices = struct.unpack_from(f"<{index_bytes // 2}H", data, ibase) if index_bytes else ()

        pos_key = next((k for k in ("position", "position16", "position12") if k in offsets), None)
        uv_key = next((k for k in ("uv2", "uv3", "uv4") if k in offsets), None)
        positions, uvs, normals, tangents = [], [], [], []
        for i in range(count):
            base = vbase + i * stride
            if pos_key is not None:
                positions.append(struct.unpack_from("<3f", data, base + offsets[pos_key]))
            if uv_key is not None:
                uvs.append(struct.unpack_from("<2f", data, base + offsets[uv_key]))
            if "normal" in offsets:
                normals.append(struct.unpack_from("<3f", data, base + offsets["normal"]))
            if "tangent" in offsets:
                tangents.append(struct.unpack_from("<4f", data, base + offsets["tangent"]))

        meshes.append({"materials": materials, "gate": gate, "aabb": aabb, "flag": flag,
                       "stride": stride, "offsets": offsets, "count": count,
                       "vbase": vbase, "vertexBytes": vertex_bytes,
                       "positions": positions, "uvs": uvs, "normals": normals,
                       "tangents": tangents, "indices": indices})
        if has_trailer:
            p = skip_mesh_trailer(data, p, version)

    return {"magic": magic, "version": version, "headerFlag": header_flag,
            "skinCount": skin_count, "meshCount": mesh_count,
            "meshes": meshes, "end": p}


def skip_mesh_trailer(data, p, version):
    """v>=21 메시 트레일러: u8 gateA[≠0: u32 word + u32 size + blob]
    | u8 gateB[≠0: u32 size + blob] | (v>=23) u32 morphCount + 레코드."""
    if data[p]:
        p += 1 + 4
        size = struct.unpack_from("<I", data, p)[0]
        p += 4 + size
    else:
        p += 1
    if data[p]:
        p += 1
        size = struct.unpack_from("<I", data, p)[0]
        p += 4 + size
    else:
        p += 1
    if version >= 23:
        n = struct.unpack_from("<I", data, p)[0]
        p += 4
        if n > 4096:
            raise ValueError(f"모프 레코드 수 {n} 폭주")
        for _ in range(n):
            p += 8                                   # u64 id
            p = data.index(b"\0", p) + 1             # cstring name
            p += 4                                   # u32 flags
            n1 = struct.unpack_from("<I", data, p)[0]
            p += 4 + n1 * 4
            n2 = struct.unpack_from("<I", data, p)[0]
            p += 4 + n2 * 4
    return p


def landing(data, p):
    """메시 섹션 끝의 착지 지점. 프레이밍이 맞으면 셋 중 하나여야 한다."""
    if p == len(data):
        return "EOF"
    if p == len(data) - 1 and data[p] == 0:
        return "말미NUL"
    if data[p:p + 4] in SECTION_MAGICS:
        return data[p:p + 8].decode("ascii", "replace")
    return None


class NearSet:
    """부동소수 근방 매칭 — 반올림 집합 매칭은 쓸 수 없다. OBJ 는 10진 텍스트,
    MDL 은 float32 라 왕복에서 1e-7 수준 오차가 나고 반올림 경계에서 갈린다
    (실측 flow.obj 2건). 격자 근방 탐색으로 허용오차 매칭한다."""

    def __init__(self, points, tol=1e-4):
        self.tol = tol
        self.dim = len(points[0]) if points else 0
        self.cell = max(tol, 1e-6) * 4
        self.grid = {}
        for pt in points:
            self.grid.setdefault(self._key(pt), []).append(pt)

    def _key(self, pt):
        return tuple(int(x // self.cell) for x in pt)

    def __contains__(self, pt):
        base = self._key(pt)
        ranges = [(-1, 0, 1)] * self.dim
        for delta in _product(ranges):
            key = tuple(b + d for b, d in zip(base, delta))
            for cand in self.grid.get(key, ()):
                if all(abs(a - b) <= self.tol for a, b in zip(cand, pt)):
                    return True
        return False


def _product(ranges):
    if not ranges:
        yield ()
        return
    for head in ranges[0]:
        for tail in _product(ranges[1:]):
            yield (head,) + tail


def compare(obj, mdl, tol=1e-4):
    """순서 무관 대조. 인덱스 대 인덱스로 비교하면 안 된다 — 실측 두 가지 때문이다:

    1) MDL 은 OBJ 의 `v` 배열 순서가 아니라 **면 전개 순서**로 정점을 굽는다.
       glow.obj 의 면이 `f 1/1 2/2 4/4 3/3`(인덱스 0,1,3,2)인데 mdl 의 [2]/[3] 이
       obj 의 v[3]/v[2] 와 일치한다.
    2) 면 코너마다 (v,vt,vn) 조합이 다르면 정점이 **복제**된다. 그래서 mdl 정점 수
       >= obj `v` 수 다(실측: 153 -> 163, 102 -> 236).

    검증 가능한 불변식:
      (a) 모든 mdl 위치/법선이 obj 집합 안에 있다
      (b) 바운딩 박스가 일치한다
      (c) mdl 총 정점 수 >= obj `v` 수 (복제만 일어나므로 줄 수 없다)
      (d) mdl 총 삼각형 수 == Σ(면 코너수 - 2)  [팬 삼각화]
      (e) 법선 단위길이, 탄젠트 xyz 단위길이 + w = ±1
      (f) 메시별 maxIndex == vertexCount - 1, 인덱스 수 % 3 == 0
      (g) v>=17 의 per-mesh AABB == 그 메시 정점 위치의 바운딩 박스

    (c) 를 '고유 (v,vt,vn) 코너 조합 수와 정확히 같다' 로 강화하면 안 된다 —
    16쌍 중 12쌍은 그렇지만 4쌍은 어긋난다(flow 153->163, dome 145->236,
    jet 48->60, shadow 184->90). 리소스컴파일러가 법선/탄젠트를 **재생성**하고
    (dome/jet/shadow 의 obj 는 vn 이 없거나 mdl 이 법선을 안 담는다) 그 값 기준으로
    분할·병합하기 때문으로, OBJ 만으로는 재현할 수 없는 규칙이다. 지어내지 않는다.
    """
    errs = []
    all_pos = [p for m in mdl["meshes"] for p in m["positions"]]
    if not all_pos:
        errs.append("mdl 정점이 0 — 레이아웃 파싱 실패")
        return errs

    # (a) 위치 포함
    near_v = NearSet(obj["v"], tol)
    missing = [p for p in all_pos if p not in near_v]
    if missing:
        errs.append(f"obj 에 없는 위치가 mdl 에 {len(missing)}개 — 예: {missing[0]}")

    # (b) 바운딩 박스
    for axis in range(3):
        a_lo = min(v[axis] for v in obj["v"])
        a_hi = max(v[axis] for v in obj["v"])
        b_lo = min(v[axis] for v in all_pos)
        b_hi = max(v[axis] for v in all_pos)
        if abs(a_lo - b_lo) > tol or abs(a_hi - b_hi) > tol:
            errs.append(f"바운딩박스 축{axis} 불일치: obj [{a_lo}, {a_hi}] vs mdl [{b_lo}, {b_hi}]")

    # (c) 정점 복제: 면 코너 전개로 늘어날 수는 있어도 줄 수는 없다
    total = sum(m["count"] for m in mdl["meshes"])
    if total < len(obj["v"]):
        errs.append(f"mdl 정점 수가 obj 보다 적다: {total} < {len(obj['v'])} "
                    f"(복제만 일어나야 하므로 줄 수 없다)")

    # (d) 팬 삼각화
    want_tris = sum(len(face) - 2 for face in obj["f"])
    got_tris = sum(len(m["indices"]) for m in mdl["meshes"]) // 3
    if want_tris != got_tris:
        errs.append(f"삼각형 수 불일치: obj Σ(n-2)={want_tris} vs mdl {got_tris}")

    near_n = NearSet(obj["vn"], tol) if obj["vn"] else None
    for i, m in enumerate(mdl["meshes"]):
        # (e) 법선 / 탄젠트
        if m["normals"]:
            bad = [n for n in m["normals"] if abs(_len3(n) - 1.0) > 1e-3]
            if bad:
                errs.append(f"m{i}: 법선 단위길이 아님 {len(bad)}개 — 예 {bad[0]} (|n|={_len3(bad[0]):.4f})")
            if near_n is not None:
                out = [n for n in m["normals"] if n not in near_n]
                if out:
                    errs.append(f"m{i}: obj vn 에 없는 법선 {len(out)}개 — 예 {out[0]}")
        if m["tangents"]:
            bad = [t for t in m["tangents"] if abs(_len3(t[:3]) - 1.0) > 1e-3]
            if bad:
                errs.append(f"m{i}: 탄젠트 xyz 단위길이 아님 {len(bad)}개 — 예 {bad[0]}")
            badw = [t for t in m["tangents"] if abs(abs(t[3]) - 1.0) > 1e-3]
            if badw:
                errs.append(f"m{i}: 탄젠트 w 가 ±1 아님 {len(badw)}개 — 예 {badw[0][3]}")
        # (f) 인덱스
        if len(m["indices"]) % 3:
            errs.append(f"m{i}: 인덱스 수 {len(m['indices'])} 가 3의 배수가 아님")
        if m["indices"] and max(m["indices"]) != m["count"] - 1:
            errs.append(f"m{i}: maxIndex {max(m['indices'])} != vertexCount-1 {m['count'] - 1}")
        # (g) AABB
        if m["aabb"] is not None and m["positions"]:
            for axis in range(3):
                lo = min(p[axis] for p in m["positions"])
                hi = max(p[axis] for p in m["positions"])
                if abs(m["aabb"][axis] - lo) > tol or abs(m["aabb"][3 + axis] - hi) > tol:
                    errs.append(f"m{i}: AABB 축{axis} 불일치 "
                                f"헤더 [{m['aabb'][axis]}, {m['aabb'][3 + axis]}] vs 정점 [{lo}, {hi}]")
    return errs


def _len3(v):
    return (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) ** 0.5


def uv_v_flipped(obj, mdl, tol=1e-4):
    """UV 의 V 축이 뒤집혔는지(1-v) 판정. 반환 = (라벨, 오류여부).

    실측: grid.obj vt (-7.707174, 0.539319) 가 mdl (-7.707, 0.4607) 로 나온다
    (0.4607 = 1 - 0.539319). 텍스처 원점 규약 차이다. 반올림 집합이 아니라
    위치와 같은 허용오차 매칭을 쓴다 — float32 왕복 오차 때문.

    UV 가 0/1 코너뿐인 모델은 뒤집힌 집합과 원본 집합이 같아 구분이 안 된다
    (실측 5쌍). 그건 '대칭'으로 보고하고, 어느 쪽에도 안 맞는 경우만 오류다."""
    uvs = [uv for m in mdl["meshes"] for uv in m["uvs"]]
    if not obj["vt"] or not uvs:
        return "UV 없음", False
    direct = NearSet(obj["vt"], tol)
    flipped = NearSet([(u, 1.0 - v) for u, v in obj["vt"]], tol)
    ok_direct = all(uv in direct for uv in uvs)
    ok_flip = all(uv in flipped for uv in uvs)
    if ok_flip and ok_direct:
        return "UV-V 대칭(판정불가)", False
    if ok_flip:
        return "UV-V 뒤집힘", False
    if ok_direct:
        return "UV 직결", False
    return "UV 가 obj vt 집합과 불일치", True


def find_pairs(root=None):
    root = root or os.path.join(WE, "projects", "defaultprojects")
    pairs = []
    for dirpath, _, files in os.walk(root):
        for f in files:
            if not f.endswith(".obj"):
                continue
            mdl = os.path.join(dirpath, f[:-4] + ".mdl")
            if os.path.exists(mdl):
                pairs.append((os.path.join(dirpath, f), mdl))
    return sorted(pairs)


def main():
    pairs = find_pairs()
    print(f"로제타석 {len(pairs)} 쌍 발견\n")
    checked = skipped = failed = 0
    for objp, mdlp in pairs:
        rel = os.path.relpath(objp, WE)
        with open(mdlp, "rb") as fh:
            data = fh.read()
        try:
            mdl = parse_mdl(data)
        except ValueError as e:
            print(f"  SKIP {rel}: {e}")
            skipped += 1
            continue
        with open(objp, encoding="utf-8", errors="replace") as fh:
            obj = parse_obj(fh.read())

        errs = []
        land = landing(data, mdl["end"])
        if land is None:
            errs.append(f"메시 섹션 미착지: end={mdl['end']} / size={len(data)}")
        errs += compare(obj, mdl)
        flip_s, flip_bad = uv_v_flipped(obj, mdl)
        if flip_bad:
            errs.append(flip_s)
        flags = "/".join(sorted({f"0x{m['flag']:x}" for m in mdl["meshes"]}))
        total = sum(m["count"] for m in mdl["meshes"])
        desc = (f"{mdl['magic']}, flag {flags}, 메시 {mdl['meshCount']}, 스킨 {mdl['skinCount']}, "
                f"obj v {len(obj['v'])} -> mdl {total} 정점, 착지 {land}, {flip_s}")
        if errs:
            print(f"  FAIL {rel} ({desc})")
            for e in errs[:6]:
                print(f"        {e}")
            failed += 1
        else:
            print(f"  ok   {rel} ({desc})")
            checked += 1

    print(f"\n대조 {checked} / 스킵 {skipped} / 불일치 {failed}")
    if skipped:
        print("스킵 사유는 레이아웃 미확정이다 — 억지로 읽어 '통과' 를 만들지 않는다.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
