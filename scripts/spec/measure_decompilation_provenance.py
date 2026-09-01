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
208 을 뒷받침하는 것은 아래 `needsMinus0xD0List` 17건의 −0xD0 대조뿐이고, 정본도 그
**개별 17건 한정**으로 좁혀 적는다.

**[정정 2026-08-30] 종전 이 자리와 정본은 그 수를 7 로 적었다.** 7 은 아래 신호 ③ 이
뒤집혀 있던 탓에 나온 수다 — 재생성 코퍼스는 **참 VA** 로 이름이 붙는데(위 ②), 종전 코드는
"인용 주소에 파일이 있으면 변위" 로 판정해 부호를 반대로 읽었다. 그래서 코퍼스만이 증거인
변위 인용 4건을 미확정으로 흘려보내고, 참 VA 인 인용 2건을 변위로 실었다. 신호를 고쳐
다시 세면 **42 / 17 변위 / 3 미확정**이었다(실측 2026-08-30). 이후 참 VA 로 정정한
인용 4건이 늘어 같은 날 다음 재측정은 **46 / 17 / 3(합계 66)** 이었다. 현행 값은 동적으로
생성되는 `decomp.citedAddressClassification`을 본다(아래 재실행 명령).

인용을 눈으로 보면 셋이 구분되지 않는다. 이 문서가 그 구분을 기록한다.

## 왜 지금 재는가

분석 리포(Waple-wallpaper-source)는 삭제 예정이고, 거기엔 원본 바이너리가
`wallpaper_engine/wallpaper64.exe` 한 자리에만 있다 — `binaries/wallpaper64.exe` 는
원본이 아니라 주입본과 바이트 동일하다(실측). 리포가 사라지면 보정을 검증할 근거도
사라지므로, 해시와 분류 결과를 여기 남긴다. 바이너리 자체는 커밋하지 않는다(독점 소프트웨어).

## 인용 census 는 **리포가 인용을 하나 더 적을 때마다** 낡는다 (2026-09-01)

`decomp.citedAddressClassification.total` 은 `CITATION_ROOTS` 아래의 `FUN_140xxxxxx` 고유
주소 수다. 즉 **소스·테스트·문서에 근거 인용을 하나 추가하면 그 순간 정본이 낡고**
`scripts/spec/check_cited_address_census.py` 가 rc=1 을 낸다(실측 2026-09-01:
정본 95 vs 실측 104). 그런데 갱신은 원본 바이너리(+재생성 코퍼스)를 요구하므로 **CI 러너에서
자가 복구가 불가능**하다 — 게이트가 빨간 채로 남고, 그 빨강은 "인용이 틀렸다" 가 아니라
"인용이 늘었다" 다.

그래서 값만 먼저 확인할 수 있게 `--census` 를 둔다. **바이너리 없이 돌고 아무것도 쓰지
않는다.** 정본 갱신은 여전히 아래 「재실행」이며, 여러 사람이 동시에 인용을 늘리는
라운드에서는 **전부 끝난 뒤 한 번** 돌리는 것이 맞다(중간에 돌리면 곧바로 다시 낡는다).

    python3 scripts/spec/measure_decompilation_provenance.py --census

## 재실행

    WE_BINARY=/path/to/wallpaper64.exe \
    WE_DECOMPILED=/path/to/analysis/decompiled/all \
    python3 scripts/spec/measure_decompilation_provenance.py

원본인지는 아래 기록된 sha256 로 대조할 것. 주입본을 넣으면 분류가 반대로 나온다.
`WE_DECOMPILED` 는 **재생성** 코퍼스여야 한다 — 1세대(변위) 코퍼스를 넣으면 신호 ③ 이
반대로 판정한다(파일명 주소 공간이 다르다).
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
# 생성 코드·테스트에 남은 근거 인용도 정본과 같은 보정 판정을 받아야 한다. 빌드 산출물이나
# 임의 루트 파일까지 훑으면 모집단이 환경에 따라 흔들리므로, 버전 관리되는 근거 경로만 명시한다.
CITATION_ROOTS = ("Sources", "Tests", "spec", "docs", "scripts")


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
    """**재생성** Ghidra 산출물 파일명에서 얻은 함수 시작 VA 집합(**참 VA** 주소 공간).

    `WE_DECOMPILED` 가 없거나 디렉터리가 아니면 빈 집합 — 그러면 이 신호 없이 종전대로 분류한다.
    산출물은 삭제 예정 리포에만 있으므로, 이 함수가 비어도 스크립트는 돌아야 한다.

    **[정정 2026-08-30] 종전 이 독스트링은 이 집합을 "주입본 주소 공간" 이라 적었다.**
    거짓이다 — 재생성 코퍼스는 참 VA 로 이름이 붙는다(모듈 머리말 ②, 정본
    decomp.richHeaderShift.doesNotApplyTo). 그 오해가 아래 분류의 신호 ③ 을 뒤집어 놨다.

    **[정정 2026-08-30] 세는 정규식을 파일명 두 꼴로 넓혔다.** 종전은
    `[0-9a-f]{16}__FUN_(…)\\.c` 만 봤는데, 코퍼스 7,748개 중 **281개는 심볼 이름**으로 붙어
    그 꼴에 안 맞았다(`…____acrt_LCMapStringA.c` · `…__thunk_FUN_<va>.c` ·
    `…__FID_conflict__ltow_s.c`). 그래서 집합 크기가 7,467 이었고, 정본이 적던 7,748 과
    281 어긋났다 — 같은 정본의 `measured` 산문(7,748개 중 6,824 일치)은 7,748 쪽으로 세고
    있었으니 한 문서 안에서 두 수를 섞어 쓰던 셈이다.

    두 꼴 다 **앞 16자리 hex 가 그 함수의 VA** 다. 그래서 선두 16자리로 센다. 실측 근거:
      · 종전 정규식에 맞던 7,467개는 전건 선두 VA == `FUN_` 안쪽 VA (불일치 0)
      · 선두 16자리로 세면 7,748개 전건이 고유하고, `manifest.json` 의 addr 집합과 **일치**
      · `thunk_FUN_…` 46개는 안쪽 VA 가 선두와 **다르다** — 그래서 안쪽 토큰이 아니라
        선두를 읽어야 한다(안쪽을 읽으면 존재하지 않는 함수 시작을 만든다)
    정규식을 넓힌 당시 인용 판정 결과는 두 꼴 어느 집합으로 해도 같았다(46/17/3, 실측) —
    이 넓힘은 판정을 바꾸려는 것이 아니라 `decompiledFunctionCount` 를 그 정의와 일치시키려는
    것이다. 이후 인용이 늘어난 현행 분류는 생성된 정본의 동적 도수를 본다.
    """
    root = os.environ.get("WE_DECOMPILED", "")
    if not root or not os.path.isdir(root):
        return set()
    out = set()
    for name in os.listdir(root):
        m = re.fullmatch(r"([0-9a-f]{16})__.+\.c", name)
        if m:
            out.add(int(m.group(1), 16))
    return out


def cited_addresses():
    """리포가 인용하는 FUN_140xxxxxx 주소 전수(중복 제거)."""
    out = subprocess.run(
        ["grep", "-rhoE", r"FUN_140[0-9a-f]{6}", *CITATION_ROOTS],
        capture_output=True, text=True, cwd=REPO).stdout
    return sorted({int(tok[4:], 16) - IMAGE_BASE for tok in out.split() if tok.startswith("FUN_")})


def main():
    if "--census" in sys.argv:
        # 바이너리 없이 도는 진단 전용 경로 — **아무것도 쓰지 않는다.**
        # `check_cited_address_census.py` 가 rc=1 을 낼 때 "정본이 낡았는가" 를
        # 러너에서도 바로 확인할 수 있게 한다(위 doc 「인용 census …」 참조).
        cited = cited_addresses()
        print(f"인용 고유 주소 {len(cited)}개 "
              f"(모집단: {' '.join(CITATION_ROOTS)} 아래 FUN_140xxxxxx)")
        print("  정본 갱신은 원본 바이너리가 필요하다 — 위 「재실행」.")
        return
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
    # **[정정 2026-08-30] 종전 이 주석과 아래 분기는 신호 ③ 의 부호가 반대였다.**
    # 종전 문면(보존):
    #
    # > 주의: 산출물은 **주입본** 주소 공간으로 이름 붙어 있다(`FUN_140xxxxxx.c`).
    # > 그러므로 파일이 인용 주소 그대로 존재하면 그 인용은 **주입본 기준**이고,
    # > 원본에서 읽으려면 −0xD0 이 필요하다 — `shifted` 와 같은 부류다.
    #
    # 그 전제가 이 파일 자신의 머리말 ②(`재생성 Ghidra 산출물의 파일명 — 참 VA 로 이름이
    # 붙는다`)와 정본 `decomp.richHeaderShift.doesNotApplyTo`(`재생성 코퍼스의 파일명·행
    # 인용(참 VA 라 보정하면 오히려 틀린다)`)와 **정면으로 모순**된다. 코퍼스는 재생성본이므로
    # 판정은 그 반대다:
    #
    #   · 인용 주소 **그대로** 파일이 있으면 → 그 인용은 이미 **참 VA** 다(`raw_ok`)
    #   · (인용 주소 − 0xD0) 에 파일이 있으면 → 그 인용이 **1세대(변위) 세대**다(`shifted`)
    #
    # 뒤집힌 코드로 재생성하면 정본이 **양방향으로** 거짓이 됐다(실측 2026-08-30):
    #   · 코퍼스만이 증거인 변위 인용 4건(0x14009c5d0 · 0x14009c630 · 0x14009c690 ·
    #     0x140261750)이 미확정으로 떨어진다 — 넷 다 −0xD0 자리에 실제 코퍼스 파일이 있다
    #   · 참 VA 인 인용 2건(0x1401531c0 · 0x14015c760)이 needsMinus0xD0 로 올라간다 —
    #     둘 다 인용 주소 그대로 코퍼스에 있고(manifest size 50 / 360), −0xD0 자리는
    #     .pdata 에도 코퍼스에도 없다. 독자가 그 지시대로 0x1401530f0 을 디스어셈하면
    #     함수가 아닌 자리를 읽는다.
    # 즉 재생성이 이 정본을 고치는 대신 오염시키는 상태였다.
    #
    # 신호 ② 가 먼저 걸리는 순서는 그대로 둔다 — `.pdata` 는 바이너리 1차 근거이고
    # 코퍼스는 2차이므로, 둘이 같은 답을 낼 때 강한 근거를 남긴다(실측: ② 로 잡히는 13건은
    # 코퍼스로도 전건 같은 판정이다).
    decompiled = decompiled_function_starts()
    # `decompiled` 는 Ghidra 가 찾은 함수 전수이고 `starts` 는 unwind 정보가 있는
    # `.pdata` 시작점이다. 전자는 리프 함수도 포함하므로 단순히 두 집합의 크기를 나눈
    # 값은 coverage 가 아니다. 분자는 반드시 같은 모집단의 교집합이어야 한다.
    decompiled_pdata_starts = {
        va for va in decompiled if (va - IMAGE_BASE) in starts
    }
    raw_ok, shifted, indeterminate = [], [], []
    for rva in cited_addresses():
        if rva in starts:
            raw_ok.append(rva)
        elif (rva - RICH_SHIFT) in starts:
            shifted.append(rva)
        elif (IMAGE_BASE + rva - RICH_SHIFT) in decompiled:
            shifted.append(rva)   # −0xD0 자리에 산출물이 있다 — 1세대(변위) 세대 인용
        elif (IMAGE_BASE + rva) in decompiled:
            raw_ok.append(rva)    # 인용 주소 그대로 산출물이 있다 — 이미 참 VA
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
            "scope": "[정정 2026-08-30] **개별 인용 17건 한정** — 같은 문서 "
                     "decomp.citedAddressClassification.needsMinus0xD0List 에 열거된 것들. 전칭이 아니다. "
                     "종전 이 자리는 **7건 한정**이라 적었고 그 7 은 거짓이었다 — 생성기의 신호 ③ 이 "
                     "뒤집혀(재생성 코퍼스를 주입본 주소 공간이라 오해) 코퍼스만이 증거인 변위 인용 "
                     "4건을 미확정으로 흘렸고, `cited_addresses()` 의 모집단도 39 에서 62 로 자란 뒤 "
                     "재측정되지 않았다. 실측 재분류는 2026-08-30 시점 42 / **17** 변위 / "
                     "3 미확정이고, [갱신 2026-08-31] 참 VA 인용 4건이 늘어난 다음 재측정은 "
                     "**46 / 17 / 3(합계 66)** 이었다. 그 뒤 인용까지 포함한 현행 재측정은 "
                     f"**{len(raw_ok)} / {len(shifted)} / {len(indeterminate)}"
                     f"(합계 {len(raw_ok) + len(shifted) + len(indeterminate)})** 이다.",
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
                        "아래 **17건**의 −0xD0 대조뿐이다(정정 2026-08-30 — 종전 이 자리는 "
                        "\"아래 7건\" 이었고, 그 7 은 신호 ③ 이 뒤집혀 있던 탓에 나온 수다. "
                        "같은 항목 scope 참조).",
            "appliesTo": "1세대(변위) 코퍼스에서 뜬 **개별 인용 17건**. 그 인용을 원본 이미지에서 "
                         "되읽을 때만 −0xD0 한다. 17건 전건이 두 신호로 확인된다 — 13건은 "
                         "(VA−0xD0) 이 원본 .pdata 함수 시작이고, 남은 4건"
                         "(0x14009c5d0 · 0x14009c630 · 0x14009c690 · 0x140261750)은 .pdata 에 "
                         "없는 리프라 (VA−0xD0) 에 재생성 코퍼스 파일이 있는 것으로 확인된다. "
                         "17건 모두 인용 주소 **그대로는** .pdata 에도 코퍼스에도 없다.",
            "doesNotApplyTo": "바이너리를 직접 관찰한 인용(어셈블리 주소·.rdata 덤프), 그리고 "
                              "**재생성 코퍼스의 파일명·행 인용**(참 VA 라 보정하면 오히려 틀린다).",
            "usedInTests": "[정정 2026-08-30] 자리별 도수를 다시 셌다. 종전 문면: "
                           "\"7건 중 3건이 테스트 기대값의 근거 주석으로 쓰인다 — "
                           "FUN_1400d0380 · FUN_1400d8060 · FUN_140261950. 나머지 4건"
                           "(0x14009c5d0 · 0x14009c630 · 0x14009c690 · 0x140261750)은 Sources "
                           "주석에만 있다.\" 목록이 7 → 17 로 자라 그 산술이 전부 틀렸고, "
                           "\"3건\" 자체도 낡았다. 실측(`grep -rl FUN_<va> Tests` · 같은 것을 "
                           "Sources 로): needsMinus0xD0List 17건 중 **Tests 5건 · Sources 7건 · "
                           "둘의 합집합 9건**이고, 나머지 **8건은 docs/ 의 감사 기록에만** 있다. "
                           "자리별 도수는 겹치므로 더하지 말 것(5 + 7 ≠ 12).\n"
                           "Tests 5건: FUN_1400d0380(WapleRenderTests/AudioInputPipelineTests.swift · "
                           "AudioCalibrationTests.swift · EngineAttenuationLaneTests.swift) · "
                           "FUN_1400d8060(WapleCoreTests/Model3DTests.swift) · "
                           "FUN_140261950(WapleCoreTests/Model3DVertexLayoutTests.swift · "
                           "Model3DTrailerSkeletonTailTests.swift) · "
                           "FUN_14009c5d0 · FUN_140261750(둘 다 "
                           "WapleCoreTests/Model3DVertexLayoutTests.swift). 뒤 2건은 종전 문면이 "
                           "\"Sources 주석에만 있다\" 고 단언한 것들이라 그 단언도 거짓이었다.\n"
                           "여기 주소를 `0x…` 로 다시 열거하지 않는 이유는 population 항목의 "
                           "주의를 볼 것 — 산문 줄의 주소는 scripts/re/va_citations.py 의 면제 표가 "
                           "걸 수 없어 경계 이탈로 보고된다. 이름을 참 VA 로 옮길 때 이 테스트 "
                           "주석도 같이 옮겨야 한다.",
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
            "signals": "① 원본 .pdata 함수 시작 → correctAsIs ② −0xD0 한 값이 .pdata 함수 시작 "
                       "→ needsMinus0xD0 ③ **재생성** Ghidra 산출물 파일명(**참 VA** 주소 공간, "
                       "WE_DECOMPILED 지정 시). ③ 은 .pdata 에 없는 리프 함수를 잡아 종전 미확정 "
                       "일부를 판정한다 — (인용 주소 − 0xD0) 에 파일이 있으면 그 인용이 1세대(변위) "
                       "세대이므로 needsMinus0xD0 이고, 인용 주소 **그대로** 파일이 있으면 그 인용은 "
                       "이미 참 VA 이므로 correctAsIs 다.\n"
                       "[정정 2026-08-30] 종전 이 자리는 ③ 을 거꾸로 적었다 — 종전 문면: "
                       "\"③ Ghidra 산출물 파일명(주입본 주소 공간, WE_DECOMPILED 지정 시). … "
                       "파일이 인용 주소 그대로 있으면 그 인용은 주입본 기준이므로 needsMinus0xD0 다.\" "
                       "그 문장은 같은 문서 decomp.richHeaderShift.doesNotApplyTo(\"재생성 코퍼스의 "
                       "파일명·행 인용 — 참 VA 라 보정하면 오히려 틀린다\")와 정면으로 모순되고, "
                       "생성기 코드도 그 거짓 문면대로 분기해 있었다. 그래서 재생성이 정본을 "
                       "**양방향으로** 오염시켰다 — 변위 인용 4건이 미확정으로 떨어지고 참 VA 인 "
                       "0x1401531c0 · 0x14015c760 이 needsMinus0xD0 로 올라갔다(둘 다 코퍼스에 "
                       "그 주소 그대로 있고 −0xD0 자리는 .pdata·코퍼스 어디에도 없다). 코드와 이 "
                       "문면을 함께 고쳤다.",
            "population": "이 도수의 모집단은 리포가 인용하는 FUN_140xxxxxx **고유 주소 전수**다. "
                          "세는 법(cited_addresses() 와 같은 레시피): "
                          f"`grep -rhoE 'FUN_140[0-9a-f]{{6}}' {' '.join(CITATION_ROOTS)} | "
                          "sort -u | wc -l`. "
                          "[정정 2026-08-30] 이 모집단이 39 → 62 로 자란 뒤 정본이 재측정되지 "
                          "않아 total 이 23건 모자란 채 전수 census 로 읽혔다. 미분류로 남아 있던 "
                          "23건 중 하나가 0x140261880 — spec/README.md 가 \"정정된 참 VA\" 로 "
                          "소개하는 그 주소였다(이제 correctAsIs 로 판정된다). 값이 동적이라 "
                          "check_canon_generator_values.py 는 설계상 건너뛰므로, 같은 레시피를 "
                          "다시 세어 total 과 대조하는 게이트를 따로 뒀다 — "
                          "scripts/spec/check_cited_address_census.py(바이너리 없이 돈다). "
                          "[갱신 2026-08-31] Model3D.swift 의 참 VA 정정 인용 4건이 순증해 "
                          "모집단은 62 → 66, correctAsIs 는 42 → 46 이 됐다"
                          "(변위 17 · 미확정 3은 동일). 그 뒤 인용까지 포함한 현행 값은 "
                          f"모집단 {len(raw_ok) + len(shifted) + len(indeterminate)} · "
                          f"correctAsIs {len(raw_ok)} · 변위 {len(shifted)} · "
                          f"미확정 {len(indeterminate)}다.\n"
                          "**주의: 이 정본 자신이 그 grep 의 입력이다**(`spec` 이 훑히는 경로에 "
                          "있다). 그래서 여기 산문에 `FUN_<주소>` 꼴 예시를 적으면 그 예시가 "
                          "인용으로 세어져 모집단이 늘고 census 게이트가 붉어진다 — 실측으로 "
                          "겪었다(2026-08-30, 파일명 예시 한 줄이 62 → 63 을 만들었다). "
                          "판정 대상이 아닌 예시 주소는 `FUN_<va>` 처럼 자리표시자로 적어라. "
                          "판정 대상인 주소(두 목록의 원소)는 `0x…` 꼴이라 grep 에 안 잡힌다.",
            "decompiledSignalUsed": bool(decompiled),
            "decompiledFunctionCount": len(decompiled),
            "decompiledFunctionCountNote":
                "[2026-08-28] 종전 11205 는 폐기된 1세대(변위) 코퍼스의 수치라 낡았다. 재생성본 "
                "실측은 **7748** — analysis/decompiled/manifest.json 의 total 이 7748 이고 "
                "`.c` 파일 실물도 7,748개다.\n"
                "[정정 2026-08-30] 값은 맞았지만 **세는 법이 그 값을 내지 못했다.** 종전 문면: "
                "\"세는 법: 산출물 디렉터리에서 `[0-9a-f]{16}__FUN_([0-9a-f]+)\\.c` 로 이름이 "
                "붙은 파일 수(= decompiled_function_starts() 의 집합 크기).\" 그 정규식에 맞는 "
                "파일은 **7,467개**다 — 나머지 281개는 심볼 이름으로 붙어 있다"
                "(`…____acrt_LCMapStringA.c` · `…__thunk_FUN_<va>.c` · "
                "`…__FID_conflict__ltow_s.c` — 여기 실주소를 적지 않는 이유는 아래 population "
                "항목의 주의를 볼 것). 즉 정본은 \"디렉터리의 .c 파일 수\"(7748)와 "
                "\"분류기가 쓰는 VA 집합 크기\"(7467)라는 서로 다른 두 도수를 한 문장에 섞어 "
                "적고 있었고, 그 상태로 재생성하면 7748 → 7467 로 조용히 바뀌면서 "
                "pdataCoverage 도 52.4% → 50.5% 로 흔들렸다(축소 가드는 양수→0 만 잡으므로 "
                "통과한다). manifest 를 읽어 어느 쪽이 사실인지 정했다: **7748 이 사실**이다 — "
                "manifest.json 의 total 이 7748 이고 functions 원소도 7748 이며 그 addr 집합이 "
                "선두 16자리로 센 파일명 VA 집합과 **완전히 일치**한다. 그래서 값이 아니라 "
                "세는 법을 값에 맞췄다 — decompiled_function_starts() 의 정규식을 "
                r"`([0-9a-f]{16})__.+\.c` 로 넓혔다. 두 꼴 다 선두 16자리가 그 함수의 VA 이고"
                "(종전 꼴에 맞던 7,467개는 전건 선두 == 안쪽 VA, 불일치 0), 넓힌 집합 7,748개는 "
                "전건 고유하다. `thunk_FUN_…` 46개는 안쪽 VA 가 선두와 다르므로 **선두를** "
                "읽어야 한다. 정규식을 넓힌 당시 인용 판정은 두 집합 어느 쪽으로도 같았다"
                "(46/17/3, 실측) — 이 넓힘은 판정을 바꾸지 않았다. 현행 도수는 위 분류 필드가 "
                "동적으로 기록한다.\n"
                "세는 법(현행): 산출물 디렉터리에서 파일명 선두 16자리 hex 를 VA 로 읽은 "
                "고유 집합의 크기(= decompiled_function_starts() 의 집합 크기). "
                "셸 대조: `ls <dir> | grep -cE '^[0-9a-f]{16}__.+\\.c$'`.",
            "pdataCoverage": f"{len(decompiled_pdata_starts)} / {len(starts)} = "
                             f"**{100.0 * len(decompiled_pdata_starts) / len(starts):.1f}%**. "
                             f"분자는 디컴파일 산출물 {len(decompiled):,}개 전수가 아니라 그중 "
                             f"`.pdata` 함수 시작과 일치하는 교집합이다. 나머지 "
                             f"{len(decompiled) - len(decompiled_pdata_starts):,}개는 리프 함수 등으로 "
                             f"`.pdata` 시작 모집단에 없으므로 분자에 더하지 않는다. "
                             f"'산출물에 없다' 가 '함수가 아니다' 를 뜻하지 않는 이유도 같다.",
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
