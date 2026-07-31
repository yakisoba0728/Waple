"""wallpaper64.exe 에서 엔진 심볼(g_* 유니폼, _rt_* 렌더타깃)을 뽑는다.

PE 파일을 직접 스캔한다. Ghidra 를 거치지 않는 이유는 재현성이다 —
이 스크립트는 WE 설치본만 있으면 어디서든 돈다.

VA(가상주소)를 함께 남기는 이유: 나중에 Ghidra 에서 "이 심볼을 어느 함수가
참조하는가" 로 확장할 때의 진입점이 된다.
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

WE = os.environ.get("WE_ROOT", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine")
BIN = os.path.join(WE, "wallpaper64.exe")

UNIFORM = re.compile(rb"g_[A-Z][A-Za-z0-9_]{2,40}")
RT = re.compile(rb"(?:_rt_|_alias_)[A-Za-z0-9_]{2,40}")


def section_map(data):
    pe_off = struct.unpack_from("<I", data, 0x3C)[0]
    coff = pe_off + 4
    nsec = struct.unpack_from("<H", data, coff + 2)[0]
    opt_size = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    pe32plus = struct.unpack_from("<H", data, opt)[0] == 0x20B
    base = (struct.unpack_from("<Q", data, opt + 24)[0] if pe32plus
            else struct.unpack_from("<I", data, opt + 28)[0])
    secs = []
    for i in range(nsec):
        b = opt + opt_size + i * 40
        name = data[b:b + 8].rstrip(b"\0").decode("ascii", "ignore")
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, b + 8)
        secs.append((name, rawptr, rawptr + rawsize, base + vaddr))
    return secs


def va_of(off, secs):
    for name, s, e, va in secs:
        if s <= off < e:
            return va + (off - s), name
    return None, None


def main():
    with open(BIN, "rb") as fh:
        data = fh.read()
    secs = section_map(data)

    def collect(rx):
        out = {}
        for m in rx.finditer(data):
            s = m.group().decode("ascii")
            if s in out:
                continue
            va, sec = va_of(m.start(), secs)
            out[s] = {"va": hex(va) if va else None, "section": sec}
        return out

    uniforms = collect(UNIFORM)
    rts = collect(RT)

    src = specfmt.ev("binary", "wallpaper64.exe 문자열 전수 스캔 (PE 섹션 매핑 포함)")

    specfmt.dump(specfmt.doc("scripts/spec/measure_engine_symbols.py", [
        specfmt.entry("engine.uniforms.count", len(uniforms), "확정", [src]),
        specfmt.entry("engine.uniforms", dict(sorted(uniforms.items())), "확정", [src]),
    ]), os.path.join("spec", "engine", "uniforms.json"))

    specfmt.dump(specfmt.doc("scripts/spec/measure_engine_symbols.py", [
        specfmt.entry("engine.renderTargets.count", len(rts), "확정", [src]),
        specfmt.entry("engine.renderTargets", dict(sorted(rts.items())), "확정", [src]),
    ]), os.path.join("spec", "engine", "render-targets.json"))

    print(f"유니폼 {len(uniforms)}종, 렌더타깃 {len(rts)}종")
    for k in sorted(rts):
        print(f"  {k}")


if __name__ == "__main__":
    main()
