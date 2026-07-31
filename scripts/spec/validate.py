"""spec/ 정본 검증기 — 스키마, 근거 필드, 내부 정합성.

생성기(measure_*.py)와 분리해 둔다. 같은 코드가 만들고 검사하면
생성기의 버그를 검사기가 그대로 통과시킨다.
"""
import glob
import json
import os
import re
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


# 확정 항목의 value 안에 이런 말이 있으면 검토 대상이다. 실패는 아니다 —
# "단위는 확정, 의미는 추정" 처럼 하위 주장을 정직하게 분리한 경우가 대부분이라
# 자동 판정이 불가능하다. 사람이 보라고 띄우기만 한다.
# crossRef/supersedes 값이 순수 id 인지 산문인지 규약을 안 정해뒀더니 양쪽 다 쓰였다.
# 산문에서 "a.b.c" 꼴 토큰을 뽑아낸다(점 2개 이상 = spec id 관례).
ID_IN_PROSE = re.compile(r"[a-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+){2,}")

HEDGE_WORDS = ("미확인", "추정", "로 보인다", "역산", "확인하지 못", "미독", "미조사", "미상")


def _walk_strings(v):
    if isinstance(v, str):
        yield v
    elif isinstance(v, dict):
        for k, x in v.items():
            yield str(k)
            yield from _walk_strings(x)
    elif isinstance(v, list):
        for x in v:
            yield from _walk_strings(x)


def hedge_triage(entries, path):
    """확정 항목 value 안의 헤지 표현을 찾아 보고 문자열 목록으로 낸다."""
    out = []
    p = os.path.basename(path)
    for e in entries:
        if e.get("status") != "확정":
            continue
        for s in _walk_strings(e.get("value")):
            for w in HEDGE_WORDS:
                if w in s:
                    out.append(f"{p}:{e.get('id')}: 확정인데 '{w}' 가 들어 있다 — {s[:80]}")
                    break
            else:
                continue
            break
    return out


def cross_document_checks(docs):
    """문서 하나만 봐서는 못 잡는 것들.

    검증기가 이걸 안 봐서 영역 간 모순 4건이 오류 0 을 통과한 채 영속했다
    (g_TexelSize 오기, 죽은 unknown, 같은 주장 다른 상태, mdl 레이아웃 오기).

    - 같은 id 가 두 파일에 있으면 어느 쪽이 정본인지 모른다
    - crossRef/supersedes 가 없는 id 를 가리키면 링크가 끊긴 것이다
    """
    warns = []
    owner = {}
    for path, d in sorted(docs.items()):
        for e in d.get("entries", []):
            eid = e.get("id")
            if not eid:
                continue
            if eid in owner:
                warns.append(f"id 중복 소유: {eid!r} 가 {owner[eid]} 와 "
                             f"{os.path.basename(path)} 양쪽에 있다 — 정본을 하나로 정해라")
            else:
                owner[eid] = os.path.basename(path)

    for path, d in sorted(docs.items()):
        p = os.path.basename(path)
        for e in d.get("entries", []):
            v = e.get("value")
            if not isinstance(v, dict):
                continue
            for key in ("crossRef", "supersedes", "canonicalIn"):
                target = v.get(key)
                for t in ([target] if isinstance(target, str) else (target or [])):
                    if not isinstance(t, str):
                        continue
                    # 값이 순수 id 일 수도 있고 산문 안에 id 가 섞여 있을 수도 있다
                    # (규약을 안 정해둬서 양쪽 다 쓰였다). 산문이면 id 를 추출해
                    # 하나라도 해석되면 통과로 본다 — 그래야 검사가 오탐으로 죽지 않는다.
                    cands = ID_IN_PROSE.findall(t) or ([t] if "." in t else [])
                    if not cands:
                        continue
                    if not any(c in owner for c in cands):
                        warns.append(f"{p}:{e.get('id')}: {key} 가 없는 id 를 가리킨다 — "
                                     f"{cands if len(cands) > 1 else cands[0]!r}")
    return warns


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
    docs = {}
    hedges = []
    for p in paths:
        try:
            d = specfmt.load(p)
        except json.JSONDecodeError as e:
            print(f"FAIL {p}: JSON 파싱 실패 — {e}")
            total_err += 1
            continue
        docs[p] = d
        errs = validate_doc(d, p)
        entries = d.get("entries", [])
        for e in entries:
            if e.get("status") in stats:
                stats[e["status"]] += 1
        hedges += hedge_triage(entries, p)
        if errs:
            print(f"FAIL {p}")
            for e in errs:
                print(f"   {e}")
            total_err += len(errs)
        else:
            print(f"ok   {p}  ({len(entries)} 항목)")

    # 문서 하나만 봐서는 못 잡는 것 — 이게 없어서 모순 4건이 오류 0 을 통과했었다.
    cross = cross_document_checks(docs)
    if cross:
        print()
        print(f"--- 문서 간 경고 {len(cross)}건 (실패는 아니다) ---")
        for w in cross:
            print(f"   {w}")

    if hedges:
        print()
        print(f"--- 확정 항목 헤지 표현 {len(hedges)}건 (검토 대상, 실패는 아니다) ---")
        for h in hedges[:15]:
            print(f"   {h}")
        if len(hedges) > 15:
            print(f"   ... 외 {len(hedges) - 15}건")

    print()
    print("상태 분포: " + " / ".join(f"{k} {v}" for k, v in stats.items()))
    print(f"오류 {total_err} 건 · 문서간 경고 {len(cross)}건 · 헤지 {len(hedges)}건")
    return 0 if total_err == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
