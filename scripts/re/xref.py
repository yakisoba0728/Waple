"""wallpaper64.exe 에서 문자열 참조를 찾는다 — 순수 파이썬(capstone 불필요).

이 저장소의 RE 는 Ghidra 를 쓰지 않는다. 설치돼 있지 않고, 재현성 때문에도 그 편이 낫다
(WE 설치본만 있으면 어디서든 돈다).

두 갈래로 찾는다:

 1. `lea reg, [rip+disp32]` **바이트 패턴** 스캔
    x64: REX.W(0x48 또는 0x4C) + 0x8D + modrm(mod=00, r/m=101) + disp32
    modrm ∈ {0x05,0x0D,0x15,0x1D,0x25,0x2D,0x35,0x3D}
    target = (그 명령의 VA) + 7 + disp32

    **선형 디스어셈을 쓰지 않는 이유**: .text 를 처음부터 훑으면 데이터/패딩에서 동기가
    어긋나 그 뒤가 전부 쓰레기가 된다. 실제로 처음에 그 방식으로 참조 0건이 나왔다.
    바이트 패턴은 동기가 필요 없고, 오탐은 **정확한 VA 일치**로 걸러진다.

 2. 8바이트 포인터 테이블 스캔 — 키/기본값 쌍이 테이블로 있으면 여기 걸린다.

usage:
    python scripts/re/xref.py flags perspective
    python scripts/re/xref.py sequencemultiplier animationmode sphererandom
"""
import os
import re
import struct
import sys

BIN = os.path.join(os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine"),
                   "wallpaper64.exe")
MODRM = {0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D}


def load():
    data = open(BIN, "rb").read()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    coff = pe + 4
    nsec = struct.unpack_from("<H", data, coff + 2)[0]
    optsz = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    base = struct.unpack_from("<Q", data, opt + 24)[0]
    secs = []
    for i in range(nsec):
        b = opt + optsz + i * 40
        nm = data[b:b + 8].rstrip(b"\0").decode("ascii", "ignore")
        vsz, vaddr, rsz, rptr = struct.unpack_from("<IIII", data, b + 8)
        secs.append({"name": nm, "raw": rptr, "rawEnd": rptr + rsz, "va": base + vaddr,
                     "vend": base + vaddr + max(vsz, rsz)})
    return data, secs


def va_of(off, secs):
    for s in secs:
        if s["raw"] <= off < s["rawEnd"]:
            return s["va"] + (off - s["raw"])
    return None


def sec(name, secs):
    return next((s for s in secs if s["name"] == name), None)


def find_str(data, secs, needle):
    pat = needle.encode() + b"\0"
    for m in re.finditer(re.escape(pat), data):
        va = va_of(m.start(), secs)
        if va is not None:
            yield va


def lea_refs(data, secs, targets):
    t = sec(".text", secs)
    tset = set(targets)
    blob = data[t["raw"]:t["rawEnd"]]
    out = []
    for i in range(len(blob) - 7):
        if blob[i] not in (0x48, 0x4C) or blob[i + 1] != 0x8D or blob[i + 2] not in MODRM:
            continue
        disp = struct.unpack_from("<i", blob, i + 3)[0]
        va = t["va"] + i
        tgt = va + 7 + disp
        if tgt in tset:
            out.append((va, tgt))
    return out


def ptr_refs(data, secs, targets):
    tset = set(targets)
    out = []
    for s in secs:
        if s["name"] not in (".rdata", ".data", "_RDATA"):
            continue
        blob = data[s["raw"]:s["rawEnd"]]
        for i in range(0, len(blob) - 8, 8):
            v = struct.unpack_from("<Q", blob, i)[0]
            if v in tset:
                out.append((s["va"] + i, v, s["name"]))
    return out


def main():
    names = sys.argv[1:]
    if not names:
        print(__doc__)
        return 1
    data, secs = load()
    targets = {}
    for n in names:
        for va in find_str(data, secs, n):
            targets[va] = n
    print(f"바이너리: {BIN}")
    print(f"대상 문자열 {len(targets)}개")
    for n in names:
        vas = [f"0x{va:x}" for va, nm in targets.items() if nm == n]
        print(f"  {n:<26} {len(vas):>2}곳  {', '.join(vas[:4])}")
    if not targets:
        print("  문자열을 못 찾았다 — 철자/버전 확인")
        return 1

    lr = lea_refs(data, secs, targets)
    print(f"\n=== lea [rip+d] 참조 {len(lr)}건 ===")
    by = {}
    for va, tgt in lr:
        by.setdefault(targets[tgt], []).append(va)
    for n in names:
        vs = by.get(n, [])
        print(f"  {n:<26} {len(vs):>3}건  " + ", ".join(f"0x{v:x}" for v in vs[:10]))

    pr = ptr_refs(data, secs, targets)
    print(f"\n=== 8바이트 포인터 참조 {len(pr)}건 ===")
    for va, tgt, s in pr[:20]:
        print(f"  {s} 0x{va:x} -> {targets[tgt]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
