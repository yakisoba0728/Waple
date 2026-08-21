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

 3. **`mov reg, [rip+disp32]` 바이트 패턴 스캔** — 짧은 문자열 전용.

    [2026-08-20] 위 둘만으로는 **구조적 사각지대**가 있다. MSVC `std::string` 은 15바이트까지
    SSO 라, 짧은 키는 `.rdata` 의 **주소를 싣지 않고** 바이트를 스택 버퍼에 직접 조립한다.
    오브젝트 팩토리가 `"model"` 을 만드는 자리:

        0x14018ff7a  mov   eax, dword [rip+0x2f91c8]   ; 0x140489148  = "mode"
        0x14018ff8e  mov   dword [rbp-0x60], eax
        0x14018ff95  movzx eax, byte  [rip+0x2f91b0]   ; 0x14048914c  = "l"
        0x14018ff9c  mov   r15d, 5                     ; 길이
        0x14018ffa8  mov   ebx, 0xf                    ; SSO 용량 15

    문자열은 `.rdata` 에 **있다**(NUL 종단 1건). `lea` 가 한 번도 안 나올 뿐이다. 그래서
    lea-only 스캔은 `model`/`image`/`text`/`sound`/`shape` 급 키를 **하나도 못 찾는다** —
    실제로 씬 오브젝트 9종 중 3종이 그렇게 누락됐다.

    이 스캔은 문자열 **시작 주소뿐 아니라 내부 오프셋**(위 예의 `+4`)도 맞춰 본다. 그래야
    2단계 조립이 잡힌다.

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


# `mov r32, [rip+d]`(8B 05 /r) · `mov r64, [rip+d]`(REX.W 8B) · `movzx r32, byte [rip+d]`(0F B6)
# · `movzx r32, word [rip+d]`(0F B7). REX 접두는 0x40~0x4F.
def mov_refs(data, secs, targets):
    """짧은 문자열의 **바이트 적재**를 잡는다. 문자열 시작 + 내부 오프셋까지 본다.

    탐침 범위는 **그 문자열 길이**로 조인다. 넉넉히 잡으면 뒤에 붙어 있는 **다른 문자열**의
    적재를 이 문자열의 것으로 오인한다(실측: `"sprite"`(6자)에 +8 오탐 2건)."""
    t = sec(".text", secs)
    blob = data[t["raw"]:t["rawEnd"]]
    # 대상 VA → (문자열 VA, 이름, 내부 오프셋). NUL 은 SSO 조립에 안 실리므로 len 미만만.
    probe = {}
    for va, name in targets.items():
        for k in range(max(1, len(name))):
            probe.setdefault(va + k, (va, name, k))
    out = []
    i = 0
    n = len(blob)
    while i < n - 7:
        b = blob[i]
        j = i + 1 if 0x40 <= b <= 0x4F else i        # REX 건너뛰기
        if j >= n - 6:
            i += 1; continue
        op = blob[j]
        if op == 0x8B and blob[j + 1] in MODRM:      # mov reg, [rip+d]
            ln = (j + 2) - i + 4
            disp = struct.unpack_from("<i", blob, j + 2)[0]
        elif op == 0x0F and blob[j + 1] in (0xB6, 0xB7) and blob[j + 2] in MODRM:
            ln = (j + 3) - i + 4                     # movzx reg, byte/word [rip+d]
            disp = struct.unpack_from("<i", blob, j + 3)[0]
        else:
            i += 1; continue
        va = t["va"] + i
        tgt = va + ln + disp
        hit = probe.get(tgt)
        if hit:
            out.append((va, tgt, hit[0], hit[1], hit[2]))
        i += 1
    # REX 접두가 붙은 명령은 접두를 건너뛴 해석과 건너뛰지 않은 해석이 **같은 타깃**을 내서
    # 인접 VA 두 건으로 잡힌다(실측: particle @0x140190001·0x140190002). 앞엣것만 남긴다.
    seen = {(va, tgt) for va, tgt, _, _, _ in out}
    return [r for r in out if (r[0] - 1, r[1]) not in seen]


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

    mr = mov_refs(data, secs, targets)
    if mr:
        print(f"\n=== mov/movzx [rip+d] 바이트 적재 {len(mr)}건 (짧은 문자열 SSO) ===")
        for va, tgt, sva, name, off in mr[:60]:
            tail = f" (문자열 +{off})" if off else ""
            print(f"  0x{va:x} → 0x{tgt:x}{tail}  \"{name}\"")
        if len(mr) > 60:
            print(f"  … 외 {len(mr) - 60}건")

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
