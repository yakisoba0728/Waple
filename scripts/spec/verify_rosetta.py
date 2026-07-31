"""로제타석 검증 — WE 기본 프로젝트의 .obj(소스)와 .mdl(컴파일 결과) 대조.

.mdl 은 정본 생성 수단이 없다(resourcecompiler 의 -mdl 은 무한 스핀,
.mdl -> obj 역변환 부재). 대신 projects/defaultprojects/*/models/ 에
같은 이름의 .obj 와 .mdl 이 공존한다. OBJ 는 정점이 평문이므로
이것으로 .mdl 파서를 바이트 단위 검증할 수 있다.
"""
import os
import struct
import sys

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")

# formatFlag 하위 바이트 -> 정점 stride(바이트)
STRIDE_BY_FLAG = {0x09: 20}   # pos(12) + uv(8). 관측된 것만 등록한다.


def parse_obj(text):
    v, vt, f = [], [], []
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        tag = parts[0]
        if tag == "v" and len(parts) >= 4:
            v.append(tuple(float(x) for x in parts[1:4]))
        elif tag == "vt" and len(parts) >= 3:
            vt.append(tuple(float(x) for x in parts[1:3]))
        elif tag == "f":
            face = []
            for p in parts[1:]:
                bits = p.split("/")
                vi = int(bits[0]) - 1
                ti = int(bits[1]) - 1 if len(bits) > 1 and bits[1] else None
                face.append((vi, ti))
            f.append(face)
    return {"v": v, "vt": vt, "f": f}


def parse_mdl_v4(data):
    """MDLV0004 레이아웃만 파싱한다.

    v17 이상은 메시마다 AABB 가 붙고 트레일러 구조도 달라 이 레이아웃이 통하지
    않는다(실측: 그대로 읽으면 정점 수가 어긋나거나 0 이 나온다). 확정되지 않은
    버전을 억지로 읽어 '대조 통과' 를 만드는 것이 이 검증기가 가장 하면 안 되는
    일이라, 미확정 버전은 명시적으로 거부한다.
    """
    if data[:4] != b"MDLV":
        raise ValueError(f"MDLV 매직이 아니다: {data[:8]!r}")
    version = data[:8].decode("ascii", "ignore")
    if version != "MDLV0004":
        raise ValueError(f"{version} 레이아웃 미확정 — 이 검증기는 MDLV0004 만 읽는다")
    p = 8
    if data[p:p + 1] != b"\0":
        raise ValueError("매직 뒤 NUL 종단자가 없다")
    p += 1
    format_flag, const1, mesh_count = struct.unpack_from("<III", data, p)
    p += 12
    end = data.index(b"\0", p)
    material = data[p:end].decode("utf-8", "ignore")
    p = end + 1
    p += 4                                   # u32 0
    vertex_bytes = struct.unpack_from("<I", data, p)[0]
    p += 4

    # 같은 MDLV0004·같은 flag 인데 이 위치가 정점블롭 크기가 아닌 파일이 있다
    # (실측: grid.mdl 176B 인데 1,818,323,314 로 읽힌다 = ASCII 를 정수로 본 값).
    # 레이아웃 변형이 있다는 뜻이므로, 억지로 읽지 말고 미해독으로 표시한다.
    plausible = 0 <= vertex_bytes <= len(data) - p
    stride = STRIDE_BY_FLAG.get(format_flag & 0xFF) if plausible else None
    positions, uvs = [], []
    if stride and vertex_bytes % stride == 0:
        for i in range(vertex_bytes // stride):
            o = p + i * stride
            x, y, z, u, vv = struct.unpack_from("<3f2f", data, o)
            positions.append((x, y, z))
            uvs.append((u, vv))

    return {"version": version, "formatFlag": format_flag, "const1": const1,
            "meshCount": mesh_count, "material": material,
            "vertexBytes": vertex_bytes, "stride": stride,
            "plausible": plausible,
            "positions": positions, "uvs": uvs}


def compare(obj, mdl, tol=1e-4):
    """순서 무관 대조.

    인덱스 대 인덱스로 비교하면 안 된다 — 실측으로 확인된 두 가지 때문이다:

    1) MDL 은 OBJ 의 `v` 배열 순서가 아니라 **면 전개 순서**로 정점을 굽는다.
       glow.obj 의 면이 `f 1/1 2/2 4/4 3/3`(인덱스 0,1,3,2)인데 mdl 의 [2]/[3] 이
       obj 의 v[3]/v[2] 와 일치한다.
    2) 면마다 UV 가 다르면 정점이 **복제**된다. 그래서 mdl 정점 수 >= obj 정점 수 다
       (실측: 153 -> 163, 102 -> 236).

    따라서 검증 가능한 불변식은 (a) mdl 의 모든 위치가 obj 위치 집합 안에 있고
    (b) 바운딩 박스가 일치하는 것이다.
    """
    errs = []
    if not mdl["positions"]:
        errs.append("mdl 정점이 0 — 레이아웃 파싱 실패")
        return errs
    if len(mdl["positions"]) < len(obj["v"]):
        errs.append(f"mdl 정점 수가 obj 보다 적다: {len(mdl['positions'])} < {len(obj['v'])} "
                    f"(복제만 일어나야 하므로 줄 수 없다)")

    # 반올림 집합 매칭은 쓸 수 없다 — OBJ 는 10진 텍스트, MDL 은 float32 라
    # 왕복에서 1e-7 수준 오차가 생기고 반올림 경계에서 갈린다(실측 flow.obj 2건).
    # 격자 근방 탐색으로 허용오차 매칭한다.
    cell = max(tol, 1e-6) * 4
    grid = {}
    for v in obj["v"]:
        grid.setdefault(tuple(int(x // cell) for x in v), []).append(v)

    def near(p):
        base = tuple(int(x // cell) for x in p)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    for c in grid.get((base[0] + dx, base[1] + dy, base[2] + dz), ()):
                        if all(abs(a - b) <= tol for a, b in zip(c, p)):
                            return True
        return False

    missing = [p for p in mdl["positions"] if not near(p)]
    if missing:
        errs.append(f"obj 에 없는 위치가 mdl 에 {len(missing)}개 — 예: {missing[0]}")

    for axis in range(3):
        a_lo = min(v[axis] for v in obj["v"])
        a_hi = max(v[axis] for v in obj["v"])
        b_lo = min(v[axis] for v in mdl["positions"])
        b_hi = max(v[axis] for v in mdl["positions"])
        if abs(a_lo - b_lo) > tol or abs(a_hi - b_hi) > tol:
            errs.append(f"바운딩박스 축{axis} 불일치: obj [{a_lo}, {a_hi}] vs mdl [{b_lo}, {b_hi}]")

    return errs


def uv_v_flipped(obj, mdl, tol=1e-4):
    """UV 의 V 축이 뒤집혔는지(1-v) 판정. 판정 불가면 None.

    실측: glow 에서 obj vt (0,0) 이 mdl (0,1) 로 나온다. 텍스처 원점 규약 차이다.
    """
    if not obj["vt"] or not mdl["uvs"]:
        return None
    q = lambda x: round(x, 4)
    direct = {(q(u), q(v)) for u, v in obj["vt"]}
    flipped = {(q(u), q(1.0 - v)) for u, v in obj["vt"]}
    got = {(q(u), q(v)) for u, v in mdl["uvs"]}
    if got <= flipped and not got <= direct:
        return True
    if got <= direct and not got <= flipped:
        return False
    return None


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
            mdl = parse_mdl_v4(data)
        except ValueError as e:
            print(f"  SKIP {rel}: {e}")
            skipped += 1
            continue
        if not mdl["plausible"]:
            print(f"  SKIP {rel}: 레이아웃 변형 미해독 "
                  f"(vertexBytes={mdl['vertexBytes']} > 파일크기 {len(data)})")
            skipped += 1
            continue
        if mdl["stride"] is None:
            print(f"  SKIP {rel}: 미등록 formatFlag 0x{mdl['formatFlag']:x} ({mdl['version']})")
            skipped += 1
            continue
        with open(objp, encoding="utf-8", errors="replace") as fh:
            obj = parse_obj(fh.read())
        errs = compare(obj, mdl)
        flip = uv_v_flipped(obj, mdl)
        flip_s = {True: "UV-V 뒤집힘", False: "UV 직결", None: "UV 판정불가"}[flip]
        if errs:
            print(f"  FAIL {rel} ({mdl['version']}, obj {len(obj['v'])} -> mdl {len(mdl['positions'])} 정점)")
            for e in errs[:5]:
                print(f"        {e}")
            failed += 1
        else:
            print(f"  ok   {rel} ({mdl['version']}, obj {len(obj['v'])} -> mdl "
                  f"{len(mdl['positions'])} 정점, {flip_s})")
            checked += 1

    print(f"\n대조 {checked} / 스킵 {skipped} / 불일치 {failed}")
    print("스킵 사유는 레이아웃 미확정이다 — 억지로 읽어 '통과' 를 만들지 않는다.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
