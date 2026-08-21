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
OTHER_BINARIES = ("webwallpaper64.exe", "scenescript64.dll", "wallpaperui.exe",
                  "mediaextensions64.dll", "resourceutil64.dll", "resourcecompiler64.exe",
                  "cloneextensions64.dll", "winrtutil64.exe", "wallpaper32.exe")
DEFAULT_TARGETS = ("Sources", "Tests", "docs/re", "docs/dev", "scripts/spec", "spec")
SUFFIXES = (".swift", ".md", ".py", ".json")


def pdata_functions(data, secs):
    """`.pdata` RUNTIME_FUNCTION 배열 → 정렬된 [(begin, end)]. 조각은 그대로 둔다."""
    sec = next((s for s in secs if s["name"] == ".pdata"), None)
    if sec is None:
        return []
    base = min(s["va"] - (s["raw"] if s["raw"] else 0) for s in secs if s["raw"])
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
    mixed = {}                                    # 파일 -> 언급한 다른 바이너리
    for f in files:
        txt = f.read_text(encoding="utf-8", errors="replace")
        others = sorted({b for b in OTHER_BINARIES if b in txt})
        if others:
            mixed[str(f)] = others
        for m in VA_RE.findall(txt):
            cited[int(m, 16)].add(str(f))

    # 함수별로 한 번만 뜬다.
    by_fn = collections.defaultdict(list)
    data_or_leaf = []
    for va in sorted(cited):
        fn = containing(funcs, va)
        (by_fn[fn].append(va) if fn else data_or_leaf.append(va))

    ok, off, unreached = 0, [], []
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
            off.append((va, kind, hint, sorted(cited[va])))

    if mixed:
        print("[va-citations] **다른 바이너리를 언급하는 파일** — 아래 결과에 오탐이 섞인다:")
        for f, bs in sorted(mixed.items()):
            print(f"    {f}  ({', '.join(bs)})")
        print()
    print(f"[va-citations] 고유 VA {len(cited)} · 데이터/리프 {len(data_or_leaf)} · "
          f"디스어셈 미도달 {len(unreached)}(함수 안 점프표 등 — 판정 불가) · "
          f"경계 OK {ok} · **경계 이탈 {len(off)}**")
    if not off:
        return 0
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
