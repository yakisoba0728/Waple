#!/usr/bin/env python3
"""파티클 도수 정본이 실제 동봉 자산과 일치하는지 본다.

`measure_particle_corpus.py` 가 만든 `spec/assets/particle-corpus.json` 을 **다시 세어**
대조한다. 입력이 리포 안(`Sources/WapleRender/Resources/WEAssets`)에만 있으므로 CI 에서
그대로 돈다 — WE 설치본이나 워크샵 코퍼스가 필요 없다.

## 왜 필요한가

소스 주석이 "동봉 N건 중 M건" 을 인용하는데 그 숫자가 **범위 표기 없이** 쓰여 서로
어긋났다(`controlpointattract` "35" 는 all 34 · unique 29 중 어느 쪽도 아니었다).
정본으로 옮겨도 자산이 바뀌면 또 낡는다. 그래서 도수를 **강제되는 값**으로 만든다.

실패하면 둘 중 하나다:
  · 자산이 바뀌었다 → 생성기를 다시 돌리고 커밋에 무엇이 왜 바뀌었는지 남겨라
  · 정본이 손으로 편집됐다 → 되돌려라

## 모집단 하한과 셀프테스트 (2026-09-01)

**종전 이 스크립트는 `fails` 가 비면 무조건 `rc=0` 을 냈다.** `gen.scan()` 이 빈 리스트를
내도(에셋 루트 오지정 · 글롭 패턴 드리프트 · 자산 삭제) 루프가 0회 돌아 `fails` 가 비고
"[particle-census] 통과" 가 찍혔다. 정본 항목이 통째로 없어도 `checked` 가 0 인 채로
같은 결과였다 — 즉 **아무것도 대조하지 않은 실행과 전부 통과한 실행이 구분되지 않았다.**
(형제 `check_int_narrowing.py` 와 같은 결함이다. `AUDIT` 이 그 전칭을 반증한 자리.)

그래서 둘을 더한다:
  ·  **모집단 하한** — 스캔한 문서 수와 대조한 원소 수가 하한 아래면 실패. 하한은 판정
     임계가 아니라 **스캔 온전성** 기준이라 현재값(문서 1,667 · 원소 22)보다 한참 낮게
     잡아도 잡으려는 것(0/한 자리)을 놓치지 않는다.
  ·  **`--selftest`** — 빈 코퍼스/정본 결손 두 음성 대조. 재계산 로직을 건드린 커밋이
     "모집단 0 초록" 을 되살리면 여기서 잡힌다.

    python3 scripts/spec/check_particle_corpus_census.py
    python3 scripts/spec/check_particle_corpus_census.py --selftest
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import measure_particle_corpus as gen  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))

# ── 모집단 하한(2026-09-01) ─────────────────────────────────────────────────
# 현재값은 문서 1,667(중복 포함) · 대조 원소 22 다. 하한은 한참 아래로 둔다 — 잡으려는 것은
# "스캔이 깨져 0/한 자리" 이지 "자산이 조금 줄었다" 가 아니다.
MIN_DOCS = 200
MIN_CHECKED = 10


def census(docs, canon):
    """(fails, checked) — 정본과 실측을 원소 단위로 대조한다. main/셀프테스트 공용."""
    fails, checked = [], 0
    for section, elements in gen.WATCH.items():
        key = f"particleCorpus.{section}"
        recorded = canon.get(key)
        if recorded is None:
            fails.append(f"정본에 {key} 가 없다")
            continue
        for name, keys in sorted(elements.items()):
            total = {"all": 0, "unique": 0}
            absent = {k: {"all": 0, "unique": 0} for k in keys}
            for doc, dup in docs:
                for e in (doc.get(section) or []):
                    if not isinstance(e, dict) or str(e.get("name", "")).lower() != name:
                        continue
                    total["all"] += 1
                    if not dup:
                        total["unique"] += 1
                    for k in keys:
                        if k not in e:
                            absent[k]["all"] += 1
                            if not dup:
                                absent[k]["unique"] += 1
            got = {"instances": total, "keyAbsent": absent}
            checked += 1
            if recorded.get(name) != got:
                fails.append(f"{section}.{name}: 정본 {recorded.get(name)} vs 실측 {got}")
    return fails, checked


def selftest():
    """음성 대조 — 모집단이 비면 **반드시** 불일치가 나와야 한다."""
    with open(gen.OUT, encoding="utf-8") as fh:
        canon = {e["id"]: e["value"] for e in json.load(fh)["entries"]}
    problems = []
    empty_fails, empty_checked = census([], canon)
    if not empty_fails:
        problems.append("빈 코퍼스(docs=[])인데 불일치가 0건 — 재계산이 정본을 보지 않는다")
    if empty_checked == 0:
        problems.append("빈 코퍼스에서 checked=0 — 대조 자체가 돌지 않았다")
    missing_fails, _ = census([], {})
    if not missing_fails:
        problems.append("정본이 비었는데 불일치가 0건 — 결손 검사가 죽었다")
    if problems:
        print("[particle-census] --selftest 실패")
        for p in problems:
            print("  X " + p)
        return 1
    print(f"[particle-census] --selftest 통과 — 빈 코퍼스에서 불일치 {len(empty_fails)}건 검출")
    return 0


def main():
    if "--selftest" in sys.argv:
        return selftest()
    if not os.path.isfile(gen.OUT):
        print(f"[particle-census] 정본이 없다: {os.path.relpath(gen.OUT, REPO)}")
        print("  scripts/spec/measure_particle_corpus.py 를 돌려 생성하라.")
        return 1
    with open(gen.OUT, encoding="utf-8") as fh:
        canon = {e["id"]: e["value"] for e in json.load(fh)["entries"]}

    docs = list(gen.scan())
    fails, checked = census(docs, canon)

    print(f"  . 원소 {checked}종 대조 · 파일 {len(docs)}개(중복 포함)")
    # 모집단 하한 — 위 doc 참조. `fails` 가 비었다는 것만으로는 통과를 낼 수 없다.
    if len(docs) < MIN_DOCS:
        print(f"\n[particle-census] 스캔한 자산 문서가 {len(docs)}개 — 하한 {MIN_DOCS} 미만.")
        print(f"  에셋 루트({os.path.relpath(gen.ASSETS, REPO)})가 비었거나 "
              f"스캔 패턴이 자산 구조 변화를 못 따라갔다.")
        print("  이 상태의 '통과' 는 아무것도 대조하지 않았다는 뜻이다.")
        return 1
    if checked < MIN_CHECKED:
        print(f"\n[particle-census] 대조한 원소가 {checked}종 — 하한 {MIN_CHECKED} 미만.")
        print("  gen.WATCH 가 비었거나 정본에 해당 섹션이 없다.")
        return 1
    if fails:
        print(f"\n[particle-census] 불일치 {len(fails)}건")
        for f in fails:
            print("  X " + f)
        print("\n  자산이 바뀌었으면 measure_particle_corpus.py 를 다시 돌리고 커밋에 사유를 남겨라.")
        return 1
    print("[particle-census] 통과")
    return 0


if __name__ == "__main__":
    sys.exit(main())
