#!/usr/bin/env python3
"""`decomp.citedAddressClassification` 이 **인용 전수**를 세고 있는지 본다.

왜 있는가
---------
그 항목은 스스로를 "리포가 인용하는 `FUN_140xxxxxx` 주소 전수의 census" 로 제시한다 —
어느 인용이 −0xD0 이 필요하고 어느 것이 이미 참 VA 인지 가리는 것이 그 존재 이유다.
그런데 그 도수는 **정본이 낡아도 조용하다**:

  · `check_canon_generator_values.py` 는 생성기의 **리터럴** 값만 대조한다. 이 값은
    `len(raw_ok) + len(shifted) + len(indeterminate)` 라 동적이고, 그 게이트가 스스로
    적어 둔 한계가 이것이다 — "동적 값이 낡은 것은 **재생성으로만** 잡힌다."
  · `check_canon_generator_keys.py` 는 키 집합만 본다. 도수는 키가 아니다.
  · `specfmt.dump` 의 축소 가드는 양수 → 0 만 잡는다. 39 → 62 는 축소가 아니다.
  · 재생성은 **원본 바이너리와 재생성 코퍼스**를 요구한다(`WE_BINARY`·`WE_DECOMPILED`).
    둘 다 짝 저장소(삭제 예정)에만 있으므로 CI 에서는 영영 돌지 않는다.

그래서 실제로 이 상태가 살아 있었다(2026-08-30 실측): 정본은 `total: 39`
(27 + 7 + 5)를 전수 census 로 적는데 같은 레시피를 HEAD 에서 돌리면 **62** 였다.
23건이 census 밖인데 문서는 빈틈이 없는 것처럼 읽혔고, 그 23건 중 하나가 `0x140261880` —
`spec/README.md` 가 "정정된 참 VA" 로 소개하는 바로 그 주소였다. 즉 "어느 인용에 보정이
필요한가" 를 답하려고 존재하는 항목이 대표 사례에 대해 무판정이면서 빈틈 0 을 보고했다.

무엇을 보는가
-------------
**세는 절반만** 본다. 분류하는 절반(어느 인용이 변위인가)은 바이너리가 필요하지만,
**모집단의 크기**는 리포 안 grep 만으로 정해진다. 그래서 이 게이트는 CI 에서 돈다.

  · 생성기의 `cited_addresses()` 를 그대로 불러 인용 주소를 다시 센다(레시피 중복을
    만들지 않는다 — 같은 수를 두 군데서 다르게 세는 것이 이 리포의 상습 결함이다).
  · 정본의 `total` 과 대조한다.
  · `total == correctAsIs + needsMinus0xD0 + indeterminate` 인지도 본다(내부 산술).
  · 두 목록의 원소가 실제 인용 집합 안에 있는지 본다 — 인용이 사라졌는데 목록에만
    남은 주소는 다음 사람이 찾으러 갔다가 0 hits 를 본다.

실패하면 둘 중 하나다:
  · 인용이 늘거나 줄었다 → 원본 바이너리와 재생성 코퍼스가 있는 자리에서 생성기를
    다시 돌려라(그 명령은 생성기 머리말 「재실행」 에 있다). 분류까지 갱신된다.
  · 정본이 손으로 편집됐다 → 되돌려라.

무엇을 못 잡는가
----------------
**분류가 틀린 것**은 여기서 안 잡힌다 — 모집단 크기만 본다. 셋으로 갈린 몫이 맞는지는
바이너리와 코퍼스가 있는 자리에서 재생성해야 안다. 그리고 생성기와 정본이 **똑같이**
낡은 경우(인용이 안 바뀌었는데 판정 규칙이 틀린 경우)도 못 잡는다 — 실제로 신호 ③ 이
뒤집혀 있던 것이 그 부류였고, 그건 사실 확인의 몫이다.
"""
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import measure_decompilation_provenance as gen  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
CANON = os.path.join(REPO, "spec", "engine", "decompilation-provenance.json")
ENTRY = "decomp.citedAddressClassification"

# 인용 수의 하한. 그물이 조용히 작아지는 것을 막는다 — grep 이 안 맞게 되거나 경로가
# 어긋나 **0건 대조로 통과**하는 것이 이 리포의 상습 실패 양식이다(형제 게이트들도 같은
# 이유로 하한을 둔다). 실측 62 에 맞춰 두지 않고 여유를 둔다 — 인용이 정상적으로 줄 수도
# 있고, 그때 막아야 할 것은 "인용이 하나도 안 잡히는 상태" 다.
MIN_CITED = 20


def canon_value():
    with io.open(CANON, encoding="utf-8") as fh:
        doc = json.load(fh)
    for e in doc.get("entries") or []:
        if isinstance(e, dict) and e.get("id") == ENTRY:
            return e.get("value")
    return None


def check(cited, value):
    """(불일치 목록, 대조한 항목 수). 순수 함수 — selftest 가 이걸 직접 부른다."""
    fails, checked = [], 0
    total = value.get("total")
    parts = {k: value.get(k) for k in ("correctAsIs", "needsMinus0xD0", "indeterminate")}

    checked += 1
    if total != len(cited):
        fails.append(
            f"total: 정본 {total} vs 실측 {len(cited)} — "
            f"인용 전수가 정본의 census 와 어긋난다")

    if all(isinstance(v, int) for v in parts.values()):
        checked += 1
        s = sum(parts.values())
        if total != s:
            fails.append(
                f"total {total} != correctAsIs {parts['correctAsIs']} + "
                f"needsMinus0xD0 {parts['needsMinus0xD0']} + "
                f"indeterminate {parts['indeterminate']} = {s}")
    else:
        fails.append(f"세 몫 중 정수가 아닌 것이 있다: {parts}")

    # 목록의 원소가 실제 인용인지. 인용이 사라졌는데 목록에만 남으면 독자가 0 hits 를 본다.
    for key in ("needsMinus0xD0List", "indeterminateList"):
        lst = value.get(key)
        if not isinstance(lst, list):
            fails.append(f"{key} 가 리스트가 아니다: {type(lst).__name__}")
            continue
        count_key = key[:-4]                      # …List -> …
        recorded = value.get(count_key)
        checked += 1
        if isinstance(recorded, int) and len(lst) != recorded:
            fails.append(f"{key}: 원소 {len(lst)}개 vs {count_key} {recorded}")
        for tok in lst:
            checked += 1
            try:
                rva = int(str(tok), 16) - gen.IMAGE_BASE
            except ValueError:
                fails.append(f"{key}: 주소로 읽히지 않는다 — {tok!r}")
                continue
            if rva not in cited:
                fails.append(
                    f"{key}: {tok} 를 리포가 더 이상 인용하지 않는다 — "
                    f"목록에만 남은 주소다")
    return fails, checked


def selftest():
    """음성 대조 — 잡아야 할 것과 통과시켜야 할 것을 매 실행 확인한다.

    실패하면 본 검사를 **아예 돌리지 않는다**. 그물이 뚫린 채 초록을 내는 것이
    이 리포가 반복해서 당한 사고이기 때문이다.
    """
    ok_value = {
        "total": 3, "correctAsIs": 1, "needsMinus0xD0": 1, "indeterminate": 1,
        "needsMinus0xD0List": ["0x140000020"],
        "indeterminateList": ["0x140000030"],
    }
    cited = [0x10, 0x20, 0x30]
    fails, checked = check(cited, ok_value)
    if fails:
        print(f"selftest 실패: 정상 입력을 거부한다 — {fails!r}", file=sys.stderr)
        raise SystemExit(2)
    if checked < 5:
        print(f"selftest 실패: 대조 건수가 {checked} 다(5 이상이어야 한다)", file=sys.stderr)
        raise SystemExit(2)

    # ① total 이 모집단과 어긋나면 잡아야 한다(39 vs 62 가 그 부류다)
    fails, _ = check(cited + [0x40], ok_value)
    if not any("total: 정본 3 vs 실측 4" in f for f in fails):
        print(f"selftest 실패: 모집단 불일치를 못 잡는다 — {fails!r}", file=sys.stderr)
        raise SystemExit(2)

    # ② 내부 산술이 안 맞으면 잡아야 한다
    bad = dict(ok_value, total=4, indeterminate=1)
    fails, _ = check(cited + [0x40], bad)
    if not any("!=" in f for f in fails):
        print(f"selftest 실패: 세 몫 합 검사가 안 먹는다 — {fails!r}", file=sys.stderr)
        raise SystemExit(2)

    # ③ 목록에만 남은 주소를 잡아야 한다
    bad = dict(ok_value, needsMinus0xD0List=["0x1400000ff"])
    fails, _ = check(cited, bad)
    if not any("목록에만 남은" in f for f in fails):
        print(f"selftest 실패: 유령 주소를 못 잡는다 — {fails!r}", file=sys.stderr)
        raise SystemExit(2)

    # ④ 목록 길이와 도수가 갈리면 잡아야 한다
    bad = dict(ok_value, needsMinus0xD0List=["0x140000020", "0x140000030"])
    fails, _ = check(cited, bad)
    if not any("원소 2개 vs needsMinus0xD0 1" in f for f in fails):
        print(f"selftest 실패: 목록 길이 검사가 안 먹는다 — {fails!r}", file=sys.stderr)
        raise SystemExit(2)
    print("  . selftest 5건 통과")


def main():
    selftest()
    if not os.path.isfile(CANON):
        print(f"[cited-address-census] 정본이 없다: {os.path.relpath(CANON, REPO)}", file=sys.stderr)
        return 1
    value = canon_value()
    if not isinstance(value, dict):
        print(f"[cited-address-census] 정본에 {ENTRY} 가 없다(또는 dict 가 아니다)", file=sys.stderr)
        return 1

    # 생성기의 레시피를 그대로 쓴다 — 같은 수를 두 군데서 다르게 세지 않는다.
    cited = gen.cited_addresses()
    if len(cited) < MIN_CITED:
        print(f"[cited-address-census] 인용이 {len(cited)}건뿐이다(하한 {MIN_CITED}) — "
              f"grep 이 안 맞게 됐거나 경로가 어긋났다. 0건 대조로 통과하지 않는다.",
              file=sys.stderr)
        return 1

    fails, checked = check(cited, value)
    print(f"  . 인용 고유 주소 {len(cited)}개 · 대조 {checked}건")
    if fails:
        print(f"\n[cited-address-census] 불일치 {len(fails)}건", file=sys.stderr)
        for f in fails:
            print("  X " + f, file=sys.stderr)
        print("\n  인용이 바뀌었으면 원본 바이너리와 재생성 코퍼스가 있는 자리에서", file=sys.stderr)
        print("  scripts/spec/measure_decompilation_provenance.py 를 다시 돌려라"
              "(머리말 「재실행」).", file=sys.stderr)
        print("  정본을 손으로 고친 것이면 되돌려라.", file=sys.stderr)
        return 1
    print("[cited-address-census] 통과")
    return 0


if __name__ == "__main__":
    sys.exit(main())
