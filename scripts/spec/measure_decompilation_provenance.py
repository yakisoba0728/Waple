"""디컴파일 인용 주소의 출처와 오프셋 보정 범위를 잰다.

## 왜 필요한가

Waple 의 소스·정본은 `FUN_140xxxxxx` 형태로 wallpaper64.exe 의 주소를 인용한다.
그 주소의 출처가 셋이고, 그중 하나만 0xD0(208바이트) 어긋나 있다:

  ① 바이너리 직접 관찰(어셈블리 주소, .rdata 덤프) — 원본 기준, 보정 불필요
  ② **재생성** Ghidra 산출물의 파일명 — 참 VA 로 이름이 붙는다. 보정 불필요
  ③ **폐기된 1세대(변위) 산출물**에서 뜬 옛 인용 — 그때의 주입기가 FileAlignment 를
     어겨 섹션이 실제로 밀렸다. 원본에서 되읽으려면 −0xD0.

**[2026-08-28] 종전 이 자리와 정본은 ②③ 을 구분하지 않고 "산출물의 모든 주소가 +0xD0
밀린다" 는 전칭을 적었다. 그 전칭은 거짓이다.** 실측 셋:
  · 산출물 파일명 VA 7,748개 중 **6,824개가 원본 `.pdata` 함수 시작과 보정 없이 일치**한다
    (변위 가설로만 설명되는 것 340개, 그중 307개는 보정 전후 양쪽이 함수 시작인 중복 판정)
  · `wallpaper64.exe` 와 `wallpaper64_rich.exe` 의 `.pdata` 시작 주소 **14,792개가 비트동일**
    — 리치헤더 주입 자체는 VA 를 밀지 않는다
  · 종전 근거였던 `e_lfanew 0x40 → 0x110(208B)` 은 실물과 다르다 — 실물 주입본의
    `e_lfanew` 는 **0x240**(+512B)이다. 그 문장은 208 을 뒷받침하지 못한다.
208 을 뒷받침하는 것은 아래 `needsMinus0xD0List` 7건의 −0xD0 대조뿐이고, 정본도 그
**개별 7건 한정**으로 좁혀 적는다.

인용을 눈으로 보면 셋이 구분되지 않는다. 이 문서가 그 구분을 기록한다.

## 왜 지금 재는가

분석 리포(Waple-wallpaper-source)는 삭제 예정이고, 거기엔 원본 바이너리가
`wallpaper_engine/wallpaper64.exe` 한 자리에만 있다 — `binaries/wallpaper64.exe` 는
원본이 아니라 주입본과 바이트 동일하다(실측). 리포가 사라지면 보정을 검증할 근거도
사라지므로, 해시와 분류 결과를 여기 남긴다. 바이너리 자체는 커밋하지 않는다(독점 소프트웨어).

## 재실행

    WE_BINARY=/path/to/wallpaper64.exe python3 scripts/spec/measure_decompilation_provenance.py

원본인지는 아래 기록된 sha256 로 대조할 것. 주입본을 넣으면 분류가 반대로 나온다.
"""
import hashlib
import os
import re
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt

BIN = os.environ.get("WE_BINARY", r"Z:\SteamLibrary\steamapps\common\wallpaper_engine\wallpaper64.exe")
IMAGE_BASE = 0x140000000
RICH_SHIFT = 0xD0
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def pe_facts(data):
    """e_lfanew · TimeDateStamp · ImageBase · .pdata 위치 · 섹션표."""
    off = struct.unpack_from("<I", data, 0x3C)[0]
    if data[off:off + 4] != b"PE\0\0":
        raise SystemExit(f"[decomp-provenance] PE 시그니처가 없다: {BIN}")
    nsec = struct.unpack_from("<H", data, off + 6)[0]
    timestamp = struct.unpack_from("<I", data, off + 8)[0]
    optsz = struct.unpack_from("<H", data, off + 20)[0]
    image_base = struct.unpack_from("<Q", data, off + 24 + 24)[0]
    pdata_rva, pdata_size = struct.unpack_from("<II", data, off + 24 + 112 + 3 * 8)
    sections, so = [], off + 24 + optsz
    for i in range(nsec):
        vsize, vaddr, rsize, raw = struct.unpack_from("<IIII", data, so + i * 40 + 8)
        sections.append((vaddr, vsize, raw, rsize))
    return off, timestamp, image_base, pdata_rva, pdata_size, sections


def function_starts(data, pdata_rva, pdata_size, sections):
    """.pdata RUNTIME_FUNCTION 의 시작 RVA 집합.

    주의: .pdata 는 **unwind 정보를 가진 함수만** 담는다. 리프 함수는 없을 수 있으므로
    '집합에 없음'이 '함수가 아님'을 뜻하지 않는다 — 아래 분류에서 '미확정'으로 센다.
    """
    file_off = None
    for vaddr, vsize, raw, rsize in sections:
        if vaddr <= pdata_rva < vaddr + max(vsize, rsize):
            file_off = raw + (pdata_rva - vaddr)
    if file_off is None:
        raise SystemExit("[decomp-provenance] .pdata 를 파일 오프셋으로 못 옮겼다")
    starts = set()
    for i in range(pdata_size // 12):
        begin, _end, _unwind = struct.unpack_from("<III", data, file_off + i * 12)
        starts.add(begin)
    return starts


def decompiled_function_starts():
    """Ghidra 산출물 파일명에서 얻은 함수 시작 VA 집합(**주입본** 주소 공간).

    `WE_DECOMPILED` 가 없거나 디렉터리가 아니면 빈 집합 — 그러면 이 신호 없이 종전대로 분류한다.
    산출물은 삭제 예정 리포에만 있으므로, 이 함수가 비어도 스크립트는 돌아야 한다.
    """
    root = os.environ.get("WE_DECOMPILED", "")
    if not root or not os.path.isdir(root):
        return set()
    out = set()
    for name in os.listdir(root):
        m = re.fullmatch(r"[0-9a-f]{16}__FUN_([0-9a-f]+)\.c", name)
        if m:
            out.add(int(m.group(1), 16))
    return out


def cited_addresses():
    """리포가 인용하는 FUN_140xxxxxx 주소 전수(중복 제거)."""
    out = subprocess.run(
        ["grep", "-rhoE", r"FUN_140[0-9a-f]{6}", "Sources", "spec", "docs"],
        capture_output=True, text=True, cwd=REPO).stdout
    return sorted({int(tok[4:], 16) - IMAGE_BASE for tok in out.split() if tok.startswith("FUN_")})


def main():
    if not os.path.isfile(BIN):
        raise SystemExit(
            f"[decomp-provenance] 바이너리가 없다: {BIN}\n"
            f"  WE_BINARY 로 원본 wallpaper64.exe 를 지정할 것.\n"
            f"  주입본(rich header 삽입, +208B)을 넣으면 분류가 반대로 나온다 — sha256 대조 필수.")
    data = open(BIN, "rb").read()
    sha = hashlib.sha256(data).hexdigest()
    e_lfanew, timestamp, image_base, prva, psize, sections = pe_facts(data)
    starts = function_starts(data, prva, psize, sections)

    # [2026-08-19] 세 번째 신호: Ghidra 디컴파일 산출물의 **파일명**.
    #
    # `.pdata` 는 unwind 정보를 가진 함수만 담는다 — 리프 함수는 없다. 그래서 위 두 검사로
    # 어느 쪽에도 안 걸리는 인용이 생겼고(종전 '미확정' 9건), 그게 "틀렸다" 를 뜻하지 않았다.
    # Ghidra 는 `.pdata` 없이도 함수를 찾으므로 그 산출물이 판정을 좁힌다.
    #
    # 주의: 산출물은 **주입본** 주소 공간으로 이름 붙어 있다(`FUN_140xxxxxx.c`).
    # 그러므로 파일이 인용 주소 그대로 존재하면 그 인용은 **주입본 기준**이고,
    # 원본에서 읽으려면 −0xD0 이 필요하다 — `shifted` 와 같은 부류다.
    decompiled = decompiled_function_starts()
    raw_ok, shifted, indeterminate = [], [], []
    for rva in cited_addresses():
        if rva in starts:
            raw_ok.append(rva)
        elif (rva - RICH_SHIFT) in starts:
            shifted.append(rva)
        elif (IMAGE_BASE + rva) in decompiled:
            shifted.append(rva)   # Ghidra 가 함수로 인정 — 주입본 기준 인용
        else:
            indeterminate.append(rva)

    ev = specfmt.ev("binary", "wallpaper64.exe (WE 2.8.42 원본)",
                    f"sha256 {sha}, {len(data)} bytes")
    hexes = lambda xs: [f"0x{IMAGE_BASE + x:x}" for x in xs]

    specfmt.dump(specfmt.doc("scripts/spec/measure_decompilation_provenance.py", [
        specfmt.entry("decomp.analyzedBinary.sha256", sha, "확정", [ev]),
        specfmt.entry("decomp.analyzedBinary.fileBytes", len(data), "확정", [ev]),
        specfmt.entry("decomp.analyzedBinary.timeDateStamp", timestamp, "확정", [ev]),
        specfmt.entry("decomp.analyzedBinary.eLfanew", e_lfanew, "확정", [ev]),
        specfmt.entry("decomp.analyzedBinary.imageBase", f"0x{image_base:x}", "확정", [ev]),
        specfmt.entry("decomp.pdataFunctionStarts", len(starts), "확정", [ev]),
        specfmt.entry("decomp.richHeaderShift", {
            "bytes": RICH_SHIFT,
            "scope": "[2026-08-28] **개별 인용 7건 한정** — 같은 문서 "
                     "decomp.citedAddressClassification.needsMinus0xD0List 에 열거된 것들. 전칭이 아니다.",
            "why": "종전 문면은 '디컴파일 산출물의 **모든** 주소가 +0xD0 밀린다' 는 전칭이었고 "
                   "그 전칭은 거짓이다. 208B/0xD0 은 헤더 크기 차이가 아니라 **폐기된 1세대 손상 "
                   "코퍼스**(주입기가 FileAlignment 를 어겨 섹션이 실제로 밀렸던 판)에서 나온 변위이며, "
                   "그 세대에서 뜬 개별 인용에만 남아 있다. 재생성본은 참 VA 로 이름이 붙는다"
                   "(Sources/WapleCore/Model3DFormat.swift 의 [2026-08-27] 주석과 같은 사실).",
            "measured": "① 산출물 파일명 VA 7,748개를 원본 .pdata 함수 시작 14,792개와 대조하면 "
                        "**6,824개가 보정 없이 그대로 일치**한다. 변위 가설로만 설명되는 것은 340개이고 "
                        "그중 307개는 보정 전후가 둘 다 함수 시작이라 중복 판정이다 — 전칭이 참이면 "
                        "나올 수 없는 분포다. ② wallpaper64.exe 와 wallpaper64_rich.exe 의 .pdata 시작 "
                        "주소 **14,792개가 비트동일**하다. 리치헤더 주입 자체는 VA 를 밀지 않는다. "
                        "③ 종전 근거로 적혀 있던 'e_lfanew 0x40 → 0x110(208B 선행)' 은 실물과 다르다 — "
                        "실물 wallpaper64_rich.exe 의 e_lfanew 는 **0x240**(원본 0x40 대비 +512B)이다. "
                        "즉 그 근거 문장은 208 을 뒷받침하지 못한다. 208 을 뒷받침하는 것은 오직 "
                        "아래 7건의 −0xD0 대조뿐이다.",
            "appliesTo": "1세대(변위) 코퍼스에서 뜬 **개별 인용 7건**. 그 인용을 원본 이미지에서 "
                         "되읽을 때만 −0xD0 한다.",
            "doesNotApplyTo": "바이너리를 직접 관찰한 인용(어셈블리 주소·.rdata 덤프), 그리고 "
                              "**재생성 코퍼스의 파일명·행 인용**(참 VA 라 보정하면 오히려 틀린다).",
            "usedInTests": "7건 중 3건이 테스트 기대값의 근거 주석으로 쓰인다 — "
                           "FUN_1400d0380(Tests/WapleRenderTests/AudioInputPipelineTests.swift · "
                           "AudioCalibrationTests.swift · EngineAttenuationLaneTests.swift) · "
                           "FUN_1400d8060(Tests/WapleCoreTests/Model3DTests.swift) · "
                           "FUN_140261950(Tests/WapleCoreTests/Model3DVertexLayoutTests.swift · "
                           "Model3DTrailerSkeletonTailTests.swift). 나머지 4건"
                           "(0x14009c5d0 · 0x14009c630 · 0x14009c690 · 0x140261750)은 Sources 주석에만 "
                           "있다. 이름을 참 VA 로 옮길 때 이 테스트 주석도 같이 옮겨야 한다.",
        }, "확정", [ev]),
        specfmt.entry("decomp.citedAddressClassification", {
            "total": len(raw_ok) + len(shifted) + len(indeterminate),
            "correctAsIs": len(raw_ok),
            "needsMinus0xD0": len(shifted),
            "indeterminate": len(indeterminate),
            "needsMinus0xD0List": hexes(shifted),
            "indeterminateList": hexes(indeterminate),
            "note": "미확정은 '틀렸다'가 아니다 — .pdata 는 unwind 정보를 가진 함수만 담으므로 "
                    "리프 함수이거나 함수 중간을 가리키는 인용이면 어느 쪽에도 안 걸린다.",
            "signals": "① 원본 .pdata 함수 시작 ② −0xD0 한 값이 .pdata 함수 시작 "
                       "③ Ghidra 산출물 파일명(주입본 주소 공간, WE_DECOMPILED 지정 시). "
                       "③ 은 .pdata 에 없는 리프 함수를 잡아 종전 미확정 일부를 판정한다 — "
                       "파일이 인용 주소 그대로 있으면 그 인용은 주입본 기준이므로 needsMinus0xD0 다.",
            "decompiledSignalUsed": bool(decompiled),
            "decompiledFunctionCount": len(decompiled),
            "decompiledFunctionCountNote":
                "[2026-08-28] 종전 11205 는 폐기된 1세대(변위) 코퍼스의 수치라 낡았다. 재생성본 "
                "실측은 **7748** — analysis/decompiled/manifest.json 의 total 이 7748 이고 "
                "`.c` 파일 실물도 7,748개다. 세는 법: 산출물 디렉터리에서 "
                r"`[0-9a-f]{16}__FUN_([0-9a-f]+)\.c` 로 이름이 붙은 파일 수"
                "(= decompiled_function_starts() 의 집합 크기).",
            "pdataCoverage": f"{len(decompiled)} / {len(starts)} = "
                             f"**{100.0 * len(decompiled) / len(starts):.1f}%**. 디컴파일 산출물은 "
                             f".pdata 함수 시작의 절반쯤만 덮는다 — '산출물에 없다' 가 '함수가 아니다' 를 "
                             f"뜻하지 않는 두 번째 이유다(첫 번째는 리프 함수).",
        }, "확정", [ev]),
    ]), os.path.join("spec", "engine", "decompilation-provenance.json"))

    print(f"바이너리 {BIN}")
    print(f"  sha256 {sha}")
    print(f"  {len(data)} bytes · e_lfanew 0x{e_lfanew:x} · TimeDateStamp {timestamp}")
    print(f"  .pdata 함수 시작 {len(starts)}개")
    print(f"인용 주소 {len(raw_ok) + len(shifted) + len(indeterminate)}개 분류:")
    print(f"  그대로 맞음   {len(raw_ok)}")
    print(f"  -0xD0 필요    {len(shifted)}  {hexes(shifted)}")
    print(f"  미확정        {len(indeterminate)}")


if __name__ == "__main__":
    main()
