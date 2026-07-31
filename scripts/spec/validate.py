"""spec/ 정본 검증기 — 스키마, 근거 필드, 내부 정합성.

생성기(measure_*.py)와 분리해 둔다. 같은 코드가 만들고 검사하면
생성기의 버그를 검사기가 그대로 통과시킨다.
"""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import specfmt


# spec/ 아래에 정본이 아닌 것도 산다:
#  - golden/  : WapleCompat 이 만든 캡처 산출물(스냅샷 매니페스트). 스키마가 다르다
#  - schema.json : 정본의 형식을 기술한 문서지 정본 항목이 아니다
# 이걸 정본으로 검사하면 오탐이 쏟아진다(실제로 512건 났다).
NON_CANON_DIRS = ("golden",)
NON_CANON_FILES = ("schema.json",)


def is_canon_path(path):
    parts = path.replace("\\", "/").split("/")
    if parts[-1] in NON_CANON_FILES:
        return False
    return not any(seg in NON_CANON_DIRS for seg in parts)


def validate_doc(d, path):
    errs = []
    p = os.path.basename(path)

    if "weVersion" not in d:
        errs.append(f"{p}: weVersion 필드가 없다")
    elif d["weVersion"] != specfmt.WE_VERSION:
        errs.append(f"{p}: weVersion 이 {d['weVersion']!r} — {specfmt.WE_VERSION!r} 이어야 한다")

    if not d.get("generatedBy"):
        errs.append(f"{p}: generatedBy 가 없다 — 재현 방법을 알 수 없다")

    entries = d.get("entries")
    if not isinstance(entries, list):
        errs.append(f"{p}: entries 가 배열이 아니다")
        return errs

    seen = set()
    for i, e in enumerate(entries):
        where = f"{p}[{i}]"
        eid = e.get("id")
        if not eid:
            errs.append(f"{where}: id 가 없다")
        elif eid in seen:
            errs.append(f"{where}: id 중복 — {eid!r}")
        else:
            seen.add(eid)
            where = f"{p}:{eid}"

        if "value" not in e:
            errs.append(f"{where}: value 가 없다")

        status = e.get("status")
        if status not in specfmt.STATUSES:
            errs.append(f"{where}: status 가 {status!r} — {specfmt.STATUSES} 중 하나여야 한다")

        evs = e.get("evidence")
        if not isinstance(evs, list) or not evs:
            errs.append(f"{where}: evidence 가 비어 있다 — 근거 없는 정본은 허용하지 않는다")
            continue

        kinds = []
        for j, x in enumerate(evs):
            if not isinstance(x, dict):
                errs.append(f"{where}: evidence[{j}] 가 객체가 아니다")
                continue
            if not x.get("kind"):
                errs.append(f"{where}: evidence[{j}] 에 kind 가 없다")
            if not x.get("ref"):
                errs.append(f"{where}: evidence[{j}] 에 ref 가 없다")
            kinds.append(x.get("kind"))

        if status == "확정" and not any(k in specfmt.REPRODUCIBLE_KINDS for k in kinds):
            errs.append(
                f"{where}: status 가 '확정' 인데 재현 가능한 근거가 없다 "
                f"(필요: {specfmt.REPRODUCIBLE_KINDS} 중 하나, 현재: {kinds})"
            )

    return errs


def main(argv):
    root = argv[1] if len(argv) > 1 else "spec"
    found = sorted(glob.glob(os.path.join(root, "**", "*.json"), recursive=True))
    paths = [p for p in found if is_canon_path(p)]
    skipped = len(found) - len(paths)
    if skipped:
        print(f"(정본 아님으로 건너뜀 {skipped}개 — golden/ 캡처 산출물, schema.json)")
    if not paths:
        print(f"검사 대상 없음: {root}")
        return 1

    total_err = 0
    stats = {s: 0 for s in specfmt.STATUSES}
    for p in paths:
        try:
            d = specfmt.load(p)
        except json.JSONDecodeError as e:
            print(f"FAIL {p}: JSON 파싱 실패 — {e}")
            total_err += 1
            continue
        errs = validate_doc(d, p)
        for e in d.get("entries", []):
            if e.get("status") in stats:
                stats[e["status"]] += 1
        if errs:
            print(f"FAIL {p}")
            for e in errs:
                print(f"   {e}")
            total_err += len(errs)
        else:
            print(f"ok   {p}  ({len(d.get('entries', []))} 항목)")

    print()
    print("상태 분포: " + " / ".join(f"{k} {v}" for k, v in stats.items()))
    print(f"오류 {total_err} 건")
    return 0 if total_err == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
