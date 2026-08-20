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
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import measure_particle_corpus as gen  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))


def main():
    if not os.path.isfile(gen.OUT):
        print(f"[particle-census] 정본이 없다: {os.path.relpath(gen.OUT, REPO)}")
        print("  scripts/spec/measure_particle_corpus.py 를 돌려 생성하라.")
        return 1
    with open(gen.OUT, encoding="utf-8") as fh:
        canon = {e["id"]: e["value"] for e in json.load(fh)["entries"]}

    docs = list(gen.scan())
    fails = []
    checked = 0
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
            want = recorded.get(name)
            checked += 1
            if want != got:
                fails.append(f"{section}.{name}: 정본 {want} vs 실측 {got}")

    print(f"  . 원소 {checked}종 대조 · 파일 {len(docs)}개(중복 포함)")
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
