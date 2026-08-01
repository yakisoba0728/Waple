"""주어진 VA 에서 선형 디스어셈 + rip-상대 피연산자 주석(문자열/float 해석).

`xref.py` 가 찾은 VA 는 **명령 경계가 확실**하므로 거기서 시작하면 동기가 맞는다.
임의 주소에서 시작하면 어긋난다 — 반드시 xref 결과를 진입점으로 쓸 것.

capstone 이 필요하다(`pip install capstone`). 없으면 xref.py 만으로도
문자열 클러스터/참조 위치까지는 알 수 있다.

**파일명 주의**: 이 파일을 `dis.py` 로 두면 파이썬 표준 라이브러리 `dis` 를 가려
capstone 임포트가 순환 임포트로 깨진다. 실제로 한 번 밟았다.

usage:
    python scripts/re/disasm.py 0x1401c55e4 200
"""
import os
import re
import struct
import sys

try:
    from capstone import Cs, CS_ARCH_X86, CS_MODE_64
except ImportError:
    print("capstone 이 필요하다: pip install capstone")
    sys.exit(1)

BIN = os.path.join(os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine"),
                   "wallpaper64.exe")


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


def off_of(va, secs):
    for s in secs:
        if s["va"] <= va < s["vend"]:
            o = s["raw"] + (va - s["va"])
            return o if o < s["rawEnd"] else None
    return None


def cstr(data, secs, va, limit=72):
    o = off_of(va, secs)
    if o is None:
        return None
    end = data.find(b"\0", o, o + limit)
    if end < 0:
        return None
    b = data[o:end]
    if not b or not all(0x20 <= c < 0x7F for c in b):
        return None
    return b.decode("ascii")


def f32(data, secs, va):
    o = off_of(va, secs)
    return struct.unpack_from("<f", data, o)[0] if o is not None else None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    data, secs = load()
    start = int(sys.argv[1], 16)
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 200
    o = off_of(start, secs)
    if o is None:
        print(f"0x{start:x} 는 섹션 범위 밖")
        return 1
    md = Cs(CS_ARCH_X86, CS_MODE_64)
    for ins in md.disasm(data[o:o + n], start):
        note = ""
        m = re.search(r"\[rip \+ (0x[0-9a-f]+)\]|\[rip - (0x[0-9a-f]+)\]", ins.op_str)
        if m:
            d = int(m.group(1), 16) if m.group(1) else -int(m.group(2), 16)
            tgt = ins.address + ins.size + d
            s = cstr(data, secs, tgt)
            fv = f32(data, secs, tgt)
            note = f"   ; 0x{tgt:x}"
            if s:
                note += f' = "{s}"'
            elif fv is not None and (fv == 0.0 or 1e-6 < abs(fv) < 1e6):
                note += f" = {fv:g}f"
        print(f"  0x{ins.address:x}  {ins.mnemonic:<7} {ins.op_str}{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
