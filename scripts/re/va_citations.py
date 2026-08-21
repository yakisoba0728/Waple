#!/usr/bin/env python3
"""인용된 VA 가 **명령 경계**인지 바이너리로 검사한다 — 아니면 무엇이 밀렸는지 말해 준다.

## 왜 필요한가

이 리포의 주석·문서는 VA 를 만 건 단위로 인용한다. 그 VA 가 명령 경계가 아니면 읽는 사람이
거기서 디스어셈했을 때 **없는 명령이 보인다**(`docs/dev/re-methodology.md` 의 함정 15).
그리고 한 번 잘못 적힌 VA 는 다음 사람이 그대로 베껴 번진다(함정 14).

경계를 벗어나는 인용에는 **재현 가능한 원인**이 하나 있다. xref 스캔은 `lea r8, [rip+d]` 를
찾을 때 명령 주소가 아니라 **disp32 필드의 위치**를 준다. 그걸 그대로 적으면 정확히
3바이트(또는 명령 인코딩만큼) 밀린다. 이 검사기는 그 경우를 따로 이름 붙여 **원래 명령
주소를 제시한다.**

## 판정

각 VA 에 대해:

  · `.pdata` 함수 범위 안이 아니면 → `데이터/리프`(`.rdata` 상수, `.pdata` 미등재 리프 함수).
    판정하지 않는다.
  · 함수 안이면 그 함수를 **시작에서 선형으로** 디스어셈해 경계 집합을 만든다.
    - VA 가 경계면 `OK`.
    - 아니면 VA 를 포함하는 명령을 찾아 `+N` 을 보고한다. 그 명령이 rip-상대이고
      VA 가 정확히 **disp32 필드 위치**면 `disp32` 로 분류하고 명령 주소를 제시한다.

## 한계 (숨기지 않는다)

  · **바이너리를 하나만 본다**(함정 11). WE 는 `webwallpaper64.exe`·`scenescript64.dll`·
    `wallpaperui.exe`·`mediaextensions64.dll` 등으로 나뉘고 전부 imagebase 가 같다.
    다른 바이너리의 VA 를 이 바이너리로 재면 전부 오탐이다. 그래서 검사 대상 파일이 다른
    바이너리 이름을 언급하면 **그 사실을 머리에 찍는다** — 그 파일의 결과는 사람이 걸러야 한다.
  · **함수 안 점프 테이블은 선형 디스어셈을 어긋나게 한다.** 그 뒤 경계는 전부 거짓 양성이
    될 수 있다. 한 함수에서 경계 이탈이 무더기로 나오면 이쪽을 먼저 의심하라.

## 실행

바이너리가 필요하므로 **CI 게이트가 아니라 로컬 도구**다(형제: `scripts/dev/check-rdata-citations.py`).

    WE_ROOT=/path/to/wallpaper_engine python3 scripts/re/va_citations.py
    WE_ROOT=... python3 scripts/re/va_citations.py docs/re/tonemapping.md Sources/WapleCore

`WE_ROOT` 로 찾은 `wallpaper64.exe` 가 없으면 아무것도 검사하지 않고 0 으로 끝난다 —
사람이 못 돌리는 검사를 초록으로 위장하지 않도록 그 사실을 화면에 찍는다.
"""
import collections
import os
import pathlib
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

VA_RE = re.compile(r"0x1[0-9a-fA-F]{8}")
# 범위 표기: `A–B`(엔대시) · `A-B` · `A..B` · `dis(A, B)` · `vdis2.py A B`
RANGE_RE = re.compile(r"(0x1[0-9a-fA-F]{8})[`'\"]?\s*(?:–|—|-|\.\.|,\s*|\s+)\s*[`'\"]?(0x1[0-9a-fA-F]{8})")
# Ghidra 산출물(주입본)과 원본 이미지의 주소 차. `spec/engine/decompilation-provenance.json` 참조.
GHIDRA_SHIFT = 0xD0

OTHER_BINARIES = ("webwallpaper64.exe", "scenescript64.dll", "wallpaperui.exe",
                  "mediaextensions64.dll", "resourceutil64.dll", "resourcecompiler64.exe",
                  "cloneextensions64.dll", "winrtutil64.exe", "wallpaper32.exe")
DEFAULT_TARGETS = ("Sources", "Tests", "docs/re", "docs/dev", "scripts/spec", "spec")

# **정정 기록** — 일부러 남긴 옛 주소. 툼스톤 규약상 "종전 0xA 를 0xB 로 고쳤다" 는 기록이
# 문서에 남고, 그 0xA 는 당연히 명령 경계가 아니다. 그걸 매번 이탈로 세면 정정할수록
# 보고서가 더러워진다.
#
# 키는 `line.strip()` 전문 일치다 — **줄 번호로 걸지 않는다**(줄 번호로 건 예외가 무관한
# 편집을 막고 조용히 낡는 사고를 이 리포가 실제로 당했다. `check_spec_shrink_guard.py` 머리말).
# 쓰이지 않는 항목은 낡은 흉터이므로 실행 끝에 지목한다.
# 줄 문면 전문 대신 **명시 마커**로 면제하는 길. 주석·문서 한 줄에 이 마커를 넣으면 그 줄의
# VA 는 "정정 기록" 으로 보고 판정하지 않는다. 툼스톤 규약(옛 주소를 남긴다)을 지킬수록
# 보고서가 더러워지는 모순을 없애면서, **면제가 명시적**이라 heuristic 처럼 조용히 넓어지지 않는다.
# JSON 정본처럼 마커를 넣을 수 없는 자리만 아래 `CORRECTION_LINES` 전문 일치를 쓴다.
CORRECTION_MARKER = "[VA-정정]"

CORRECTION_LINES = {
    # `decompilation-provenance.json` 의 두 목록은 **일부러** 비경계 주소를 담는다 —
    # `needsMinus0xD0List` 는 주입본 주소이고 `indeterminateList` 는 어느 쪽도 아닌 것들이다.
    # 그게 그 정본의 존재 이유이므로 이탈로 세면 안 된다.
    '"0x14009c690",': "decompilation-provenance.json needsMinus0xD0List",
    '"0x1400d8060",': "decompilation-provenance.json needsMinus0xD0List",
    '"0x140261950"': "decompilation-provenance.json needsMinus0xD0List(마지막 원소)",
    '"0x140064fa0",': "decompilation-provenance.json indeterminateList",
    "> | `0x140020ee6` | `0x140020ee3` | `lea r8, [rip + 0x453d30]` → `0x140474c1a` | disp32 필드 위치 |":
        "scene-object-model.md 정정 표",
    "> | `0x140259458` | `0x140259455` | `mov rax, [rip + 0x23841c]` → `0x140491878` | disp32 필드 위치 |":
        "scene-object-model.md 정정 표",
    "> | `0x1402594e6` | `0x1402594e3` | `lea rdx, [rip + 0x23838e]` → `0x140491878` | disp32 필드 위치 |":
        "scene-object-model.md 정정 표",
    "> | `0x14018ac60` | `0x14018ac5c` | `mov rcx, [rdi + 0xd8]` | 재현 명령의 **시작** 주소 |":
        "scene-object-model.md 정정 표",
    "> | `0x14022bea0` | `0x14022be9c` | `movaps [rsp + 0x50], xmm1` | 재현 명령의 **시작** 주소 |":
        "scene-object-model.md 정정 표",
    "> `collisionmodel` 행의 \"모델 참조 push\" 호출 자리가 `0x1401cfdcc` 로 적혀 있었는데 그 주소는":
        "particle-operator-vm.md 정정 문단",
    "> **`Sources/WapleCore/SceneDocument.swift` 의 주석에도 `0x140259458`/`0x1402594e6` 이 그대로":
        "scene-object-model.md — 소유 밖 파일에 남은 같은 인용을 지목하는 줄",
    "> | `0x1401ecece` | `0x1401ececb` | `mov qword ptr [rax + 0xaf0], 0x3f800000` | 범위 **시작** — 명령 내부(+3)였다 |":
        "particle-world-basis.md 정정 표",
    "> | `0x1401ecf1c` | `0x1401ecf20` | `mov dword ptr [rax + 0xb2c], 0x3f800000` | 범위 **끝** — 마지막 명령 내부(+6)였다 |":
        "particle-world-basis.md 정정 표",
    "> 종전 `0x1401872cb` → `0x1401872ca` · 종전 `0x140227539` → `0x140227535` · 종전 `0x1401ee98c` → `0x1401ee98a`":
        "camera-motion.md 부록 C 정정 기록",
    "> **[툼스톤] 종전 이 문서가 적던 값**(전부 disp32 필드 자리 — 명령 시작이 아니다): `0x140110cbe` `0x140111c76` `0x140112686` `0x1401c2d84` `0x1401c70a6` `0x1401d1773` `0x1401d2292` `0x14021c625` `0x1402268c1` `0x140237fb7` `0x140238a33` `0x14026f1b7` `0x1401a9d28` `0x140216102` · 그리고 명령 한복판(+1)이던 `0x1402cd760`.":
        "skeleton-animation.md 부록 A 툼스톤 줄",
}
SUFFIXES = (".swift", ".md", ".py", ".json")


def image_base(data):
    """PE 옵셔널 헤더의 ImageBase. `.pdata` 의 RUNTIME_FUNCTION 은 **RVA** 라 이게 필요하다.

    종전에는 섹션 표에서 `va - raw` 의 최솟값으로 어림했는데 그건 이미지 베이스가 아니다
    (`base + vaddr - rptr` 이다). 그 어림 때문에 조각 경계가 통째로 밀려 선형 디스어셈이
    쓰레기를 뱉었고, 그 쓰레기가 `add bl, dh` 같은 명령으로 보고서에 올라왔다.
    """
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    opt = pe + 4 + 20
    return struct.unpack_from("<Q", data, opt + 24)[0]


def pdata_functions(data, secs):
    """`.pdata` RUNTIME_FUNCTION 배열 → 정렬된 [(begin, end)]. 조각은 그대로 둔다."""
    sec = next((s for s in secs if s["name"] == ".pdata"), None)
    if sec is None:
        return []
    base = image_base(data)
    out = []
    o, end = sec["raw"], sec["rawEnd"]
    while o + 12 <= end:
        b, e, _u = struct.unpack_from("<III", data, o)
        o += 12
        if b == 0 and e == 0:
            continue
        out.append((base + b, base + e))
    out.sort()
    return out


def containing(funcs, va):
    """va 를 **포함하는** 조각. 앞 함수를 씌우지 않는다 — 그게 이 검사기의 상습 오탐이다."""
    lo, hi = 0, len(funcs) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        b, e = funcs[mid]
        if va < b:
            hi = mid - 1
        elif va >= e:
            lo = mid + 1
        else:
            return b, e
    return None


def main(argv):
    try:
        from capstone import Cs, CS_ARCH_X86, CS_MODE_64
    except ImportError:
        print("capstone 이 필요하다: pip install capstone")
        return 0
    import disasm

    if not os.path.exists(disasm.BIN):
        print(f"[va-citations] 바이너리가 없어 아무것도 검사하지 않았다: {disasm.BIN}")
        print("               WE_ROOT 로 WE 설치본을 가리켜라. (이 검사는 CI 게이트가 아니다)")
        return 0
    data, secs = disasm.load()
    funcs = pdata_functions(data, secs)
    if not funcs:
        print("[va-citations] .pdata 를 못 읽었다 — 바이너리가 예상과 다르다")
        return 1
    md = Cs(CS_ARCH_X86, CS_MODE_64)

    roots = argv[1:] or list(DEFAULT_TARGETS)
    files = []
    for r in roots:
        p = pathlib.Path(r)
        if p.is_file():
            files.append(p)
        elif p.is_dir():
            files += [q for q in sorted(p.rglob("*")) if q.suffix in SUFFIXES and q.is_file()]
    if not files:
        print("[va-citations] 검사할 파일이 없다 — 경로를 확인해라")
        return 1

    cited = collections.defaultdict(set)          # va -> {파일}
    corrections = collections.Counter()           # 정정 기록에만 나오는 va
    used_corrections = set()
    ends = collections.Counter()                  # va -> 범위의 **끝**으로 나온 횟수
    total = collections.Counter()                 # va -> 전체 등장 횟수
    mixed = {}                                    # 파일 -> 언급한 다른 바이너리
    for f in files:
        txt = f.read_text(encoding="utf-8", errors="replace")
        others = sorted({b for b in OTHER_BINARIES if b in txt})
        if others:
            mixed[str(f)] = others
        for line in txt.splitlines():
            stripped = line.strip()
            record = CORRECTION_MARKER in stripped or stripped in CORRECTION_LINES
            for m in VA_RE.finditer(line):
                va = int(m.group(0), 16)
                if record:
                    corrections[va] += 1
                    used_corrections.add(stripped)
                    continue
                cited[va].add(str(f))
                total[va] += 1
        # `A–B` / `A-B` / `A..B` 의 **B**, 그리고 `dis(A, B)` · `vdis2.py A B` 의 B 는
        # **범위의 끝**이다. 끝은 배타적이거나 마지막 명령의 주소라 명령 경계가 아닐 수 있다 —
        # 이걸 이탈로 세면 거짓 양성이 된다. **시작(A)은 반드시 경계여야 한다**(거기서 선형
        # 디스어셈을 시작하니까) — 그래서 시작은 그대로 검사한다.
        for m in RANGE_RE.finditer(txt):
            ends[int(m.group(2), 16)] += 1

    # 함수별로 한 번만 뜬다.
    by_fn = collections.defaultdict(list)
    data_or_leaf = []
    for va in sorted(cited):
        fn = containing(funcs, va)
        (by_fn[fn].append(va) if fn else data_or_leaf.append(va))

    # 조각 → 경계 집합 캐시. `-0xD0` 가설을 재려면 **다른 조각**을 떠야 하므로 캐시가 필요하다.
    boundary_cache = {}

    def boundaries_of(b, e):
        if (b, e) not in boundary_cache:
            o2 = disasm.off_of(b, secs)
            m = {}
            if o2 is not None:
                for i in md.disasm(data[o2:o2 + (e - b)], b):
                    m[i.address] = i
            boundary_cache[(b, e)] = m
        return boundary_cache[(b, e)]

    def is_boundary(va):
        fn = containing(funcs, va)
        return bool(fn) and va in boundaries_of(*fn)

    ok, off, unreached, range_end = 0, [], [], []
    for (b, e), vas in sorted(by_fn.items()):
        o = disasm.off_of(b, secs)
        if o is None:
            continue
        ins_at, cover = {}, []
        for ins in md.disasm(data[o:o + (e - b)], b):
            ins_at[ins.address] = ins
            cover.append(ins)
        # 선형 스트림이 조각 끝까지 못 갔으면(함수 안 점프 테이블 등) 그 뒤는 **판정 불가**다.
        # 종전엔 그것도 "명령 내부" 로 세어 거짓 양성이 무더기로 났다.
        reach = (cover[-1].address + cover[-1].size) if cover else b
        for va in vas:
            if va in ins_at:
                ok += 1
                continue
            if va >= reach:
                unreached.append((va, sorted(cited[va])))
                continue
            if ends[va] and ends[va] >= total[va]:
                range_end.append(va)          # 등장이 전부 범위의 끝이다 — 판정하지 않는다
                continue
            host = next((i for i in cover if i.address < va < i.address + i.size), None)
            if host is None:
                unreached.append((va, sorted(cited[va])))
                continue
            kind, hint = "명령 내부", ""
            if host is not None:
                delta = va - host.address
                m = re.search(r"\[rip [+-] 0x[0-9a-f]+\]", host.op_str)
                if m:
                    tgt_disp = None
                    mm = re.search(r"\[rip \+ (0x[0-9a-f]+)\]|\[rip - (0x[0-9a-f]+)\]", host.op_str)
                    d = int(mm.group(1), 16) if mm.group(1) else -int(mm.group(2), 16)
                    packed = struct.pack("<i", d)
                    k = bytes(host.bytes).find(packed)
                    if k >= 0 and delta == k:
                        kind = "disp32 위치(xref 스캔 결과를 그대로 적었다)"
                        tgt_disp = host.address + host.size + d
                    hint = f"  → 명령은 {host.address:#x} ({host.mnemonic} {host.op_str})"
                    if tgt_disp is not None:
                        hint += f" ; 가리키는 곳 {tgt_disp:#x}"
                else:
                    hint = f"  → 명령은 {host.address:#x} ({host.mnemonic} {host.op_str}), +{delta}"
            # **주입본 가설.** Ghidra 산출물은 rich header 가 주입된 이미지라 원본보다 +0xD0
            # 밀려 있다(`spec/engine/decompilation-provenance.json`). 디컴파일 창의 주소를 그대로
            # "어셈블리 0x…" 로 적으면 여기서 경계 이탈로 나온다. `va - 0xD0` 이 **경계면** 그게
            # 답이다 — 임의의 주소가 경계일 확률이 낮으므로(명령 평균 길이의 역수) 신호가 강하다.
            # **다만 disp32 설명이 이미 붙었으면 그쪽을 이긴다.** 두 가설이 동시에 성립할 수
            # 있는데(2026-08-21 실사례: `0x14015cc13` 은 `0x14015cc10 lea r8,[rip+…]` 의 disp32
            # 자리이면서 `-0xD0` = `0x14015cb43` 도 경계다), disp32 는 **어긋난 바이트 수까지**
            # 설명하므로 더 강한 설명이다. 실제로 그 자리의 원문 주장은 `"condition"` 로드였고
            # `0x14015cc10` 이 정확히 그것이다 — `0x14015cb43` 은 무관한 `jne` 다.
            if kind == "명령 내부" and is_boundary(va - GHIDRA_SHIFT):
                kind = f"주입본 주소(Ghidra, +{GHIDRA_SHIFT:#x})"
                hint = f"  → 원본은 {va - GHIDRA_SHIFT:#x}"
            off.append((va, kind, hint, sorted(cited[va])))

    if mixed:
        print("[va-citations] **다른 바이너리를 언급하는 파일** — 아래 결과에 오탐이 섞인다:")
        for f, bs in sorted(mixed.items()):
            print(f"    {f}  ({', '.join(bs)})")
        print()
    print(f"[va-citations] 고유 VA {len(cited)} · 데이터/리프 {len(data_or_leaf)} · "
          f"디스어셈 미도달 {len(unreached)}(함수 안 점프표 등 — 판정 불가) · "
          f"범위 끝 {len(range_end)}(판정 안 함) · "
          f"정정 기록 {len(corrections)}(판정 안 함) · "
          f"경계 OK {ok} · **경계 이탈 {len(off)}**")
    # 낡은-면제 검사는 **전수 스캔일 때만** 한다. 일부 파일만 지정해 돌리면 다른 파일의
    # 면제가 당연히 안 쓰이므로, 그걸 "낡았다" 고 찍으면 부분 스캔이 늘 붉어진다.
    full_scan = not argv[1:]
    stale = (set(CORRECTION_LINES) - used_corrections) if full_scan else set()
    if stale:
        print()
        print(f"  ※ 쓰이지 않는 정정 기록 면제 {len(stale)}건 — 낡았다. 지워라:")
        for line in sorted(stale):
            print(f"      | {line}")
    if not off:
        return 1 if stale else 0
    per_file = collections.defaultdict(list)
    for va, kind, hint, fs in off:
        for f in fs:
            per_file[f].append((va, kind, hint))
    print()
    for f in sorted(per_file, key=lambda k: (-len(per_file[k]), k)):
        tag = "  ※ 다른 바이너리 언급 — 오탐 가능" if f in mixed else ""
        print(f"  {f}  {len(per_file[f])}건{tag}")
        for va, kind, hint in sorted(per_file[f]):
            print(f"      {va:#x}  {kind}{hint}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
