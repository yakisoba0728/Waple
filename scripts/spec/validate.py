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
#  - golden/snapshot/ : WapleCompat 이 만든 캡처 산출물(스냅샷 매니페스트). 스키마가 다르다
#  - schema.json      : 정본의 형식을 기술한 문서지 정본 항목이 아니다
# 이걸 정본으로 검사하면 오탐이 쏟아진다(실제로 512건 났다).
#
# [2026-08-01] 종전엔 `golden` 디렉터리를 **통째로** 뺐다. 그 바람에 같은 디렉터리에 사는
# 진짜 정본 문서(gate-analysis.json)가 한 번도 검사된 적이 없었는데, 건너뛴 개수만 세고
# 무엇을 건너뛰는지는 안 찍어서 아무도 몰랐다. 캡처 산출물이 사는 golden/snapshot/ 만 뺀다.
NON_CANON_PATH_PAIRS = (("golden", "snapshot"),)
NON_CANON_FILES = ("schema.json",)


def is_canon_path(path):
    parts = path.replace("\\", "/").split("/")
    if parts[-1] in NON_CANON_FILES:
        return False
    for a, b in NON_CANON_PATH_PAIRS:
        if any(parts[i] == a and parts[i + 1] == b for i in range(len(parts) - 1)):
            return False
    return True


# 리포 안을 가리키는 근거는 실제로 그 자리에 있어야 한다.
#
# 이 검사가 없어서 `spec/golden/gate-analysis.json` 이 `baseline-618d16f/manifest.json` 을
# 근거로 인용한 채 오류 0 으로 통과했다 — 재베이스라인하며 그 디렉터리를 지웠는데 문서를
# 다시 뜨지 않았기 때문이다. 정본에서 가장 위험한 종류의 거짓말이다: 등급은 '확정' 인데
# 근거를 따라가 보면 없다. 사람이 열어보기 전까지 아무 것도 실패하지 않는다.
#
# 리포 밖 참조(설치본 `Z:\...`, 코퍼스, wallpaper64.exe)는 머신마다 다르므로 검사 대상이
# 아니다 — 리포 최상위 이름으로 시작하는 경로만 본다.
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REPO_PREFIXES = ("spec/", "Sources/", "Tests/", "scripts/", "docs/", ".github/", "Package.swift")
# 줄 인용을 벗긴다. 정본에 실재하는 형태가 여럿이다:
#   "f.swift:12" · "f.swift:12-34" · "f.h:114,115,119" · "f.swift:1254-1257,"
REF_LINE_SUFFIX = re.compile(r":[\d,\-]+,?$")
# 글로브 메타문자. 이게 있으면 경로 자체는 존재할 수 없으므로 매칭이 아니라
# **글로브가 아닌 최장 접두 디렉터리**가 있는지만 본다. 브레이스 확장(`{a,b}`)까지
# 흉내내면 검사기 쪽이 오히려 틀리기 쉬워서, 확실히 판정되는 선까지만 검사한다.
GLOB_CHARS = "*?[{"


def ref_max_line(ref):
    """근거 ref 에 붙은 줄 인용에서 **가장 큰 줄 번호**를 뽑는다. 줄 인용이 없으면 None.

    `f.swift:12` · `f.swift:12-34` · `f.h:114,115,119` · `f.swift:1254-1257,` 전부 받는다.
    """
    if not isinstance(ref, str):
        return None
    s = ref.replace("\\", "/").strip().split(" ", 1)[0].split("#", 1)[0]
    m = REF_LINE_SUFFIX.search(s)
    if not m:
        return None
    nums = [int(n) for n in re.findall(r"\d+", m.group(0))]
    return max(nums) if nums else None


def repo_ref_path(ref):
    """근거 ref 에서 검사할 리포 상대 경로를 뽑는다. 리포 밖을 가리키면 None."""
    if not isinstance(ref, str):
        return None
    # ref 는 "경로 설명문" 처럼 뒤에 산문이 붙기도 하고 "#앵커" 가 붙기도 한다.
    s = ref.replace("\\", "/").strip().split(" ", 1)[0].split("#", 1)[0]
    s = REF_LINE_SUFFIX.sub("", s)
    if not s.startswith(REPO_PREFIXES):
        return None
    if any(c in s for c in GLOB_CHARS):
        # 글로브 앞의 마지막 디렉터리 경계까지만 남긴다. 남는 게 없으면 검사 포기.
        cut = min(s.index(c) for c in GLOB_CHARS if c in s)
        s = s[:cut].rsplit("/", 1)[0]
        if not s.startswith(REPO_PREFIXES):
            return None
    return s or None


def validate_doc(d, path):
    errs = []
    p = os.path.basename(path)

    if "weVersion" not in d:
        errs.append(f"{p}: weVersion 필드가 없다")
    elif d["weVersion"] != specfmt.WE_VERSION:
        errs.append(f"{p}: weVersion 이 {d['weVersion']!r} — {specfmt.WE_VERSION!r} 이어야 한다")

    gen = d.get("generatedBy")
    if not gen:
        errs.append(f"{p}: generatedBy 가 없다 — 재현 방법을 알 수 없다")
    elif gen.endswith(".py") and not os.path.exists(os.path.join(REPO_ROOT, gen)):
        # evidence 의 ref 는 :127-128 에서 os.path.exists 로 검사하는데 generatedBy 는 "비어있지
        # 않음" 만 봤다 — 강도 비대칭이다. 스크립트 이름이 바뀌거나 지워지면 그 문서는 재생성
        # 방법을 잃는데 아무도 울지 않았다. `.py` 로 끝나는 것만 본다: 손 작성 문서는
        # "손 작성 — …" 처럼 경로가 아닌 설명을 싣는 것이 이 리포의 관례다(spec/engine/deviations.json).
        errs.append(f"{p}: generatedBy 가 가리키는 스크립트가 없다 — {gen}")

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
            # **[2026-08-28] 종전엔 `kind` 가 비었는지만 봤다.** 스키마가 열거를 적어 두었는데도
            # 검사기가 화이트리스트를 안 걸어서, 열거 밖의 `note` 가 2건 조용히 통과했다
            # (script.dts.unbacked · engine.uniformFeed.unknowns — 둘 다 참조가 아니라 방법의
            # 한계를 적은 산문이었다). 열거는 강제되지 않으면 열거가 아니고, `확정` 등급 판정이
            # `REPRODUCIBLE_KINDS` 포함 여부로 갈리므로 오탈자 하나가 등급을 조용히 바꾼다.
            if not x.get("kind"):
                errs.append(f"{where}: evidence[{j}] 에 kind 가 없다")
            elif x["kind"] not in specfmt.EVIDENCE_KINDS:
                errs.append(f"{where}: evidence[{j}] 의 kind 가 {x['kind']!r} — "
                            f"{specfmt.EVIDENCE_KINDS} 중 하나여야 한다")
            # `population` 은 선택 필드다(모집단 이름). 있으면 비어 있지 않은 문자열이어야 한다 —
            # **없다고 실패시키지 않는다.** 소급 강제하면 전건이 실패하고, 그러면 아무도 채우지
            # 않는다. 도수를 담은 항목부터 자발적으로 붙이게 여는 자리다.
            pop = x.get("population")
            if pop is not None and not (isinstance(pop, str) and pop.strip()):
                errs.append(f"{where}: evidence[{j}] 의 population 이 비어 있거나 문자열이 아니다 — "
                            f"{pop!r} (모집단 이름을 적거나 필드를 빼라)")
            if not x.get("ref"):
                errs.append(f"{where}: evidence[{j}] 에 ref 가 없다")
            else:
                rel = repo_ref_path(x["ref"])
                if rel is not None and not os.path.exists(os.path.join(REPO_ROOT, rel)):
                    errs.append(f"{where}: evidence[{j}] 의 ref 가 리포에 없다 — {rel!r} "
                                f"(근거를 따라갈 수 없는 정본이다)")
                # **[2026-08-20]** 종전엔 `:숫자` 를 잘라내고 **파일 존재만** 봤다. 그래서
                # 153줄짜리 `SnapshotCompare.swift` 에 `:204` 를 달아도 오류 0 으로 통과했고,
                # 확정 등급 항목 셋이 없는 줄을 가리키고 있었다(생성기가 줄 번호는 A 파일에서
                # 뽑고 파일명은 B 를 붙였다). 파일이 존재하는데 그 줄이 없으면 그것도 "근거를
                # 따라갈 수 없는 정본" 이다 — 오히려 파일이 없는 경우보다 발견이 늦다.
                elif rel is not None:
                    line = ref_max_line(x["ref"])
                    if line is not None:
                        full = os.path.join(REPO_ROOT, rel)
                        if os.path.isfile(full):
                            try:
                                with open(full, "rb") as fh:
                                    total = sum(1 for _ in fh)
                            except OSError:
                                total = None
                            if total is not None and line > total:
                                errs.append(
                                    f"{where}: evidence[{j}] 의 ref 가 없는 줄을 가리킨다 — "
                                    f"{rel}:{line} 인데 그 파일은 {total}줄이다")
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


def superseded_ids(docs):
    """다른 항목이 `supersedes` 로 가리키는 id 집합 = **묘비(tombstone)**.

    묘비는 답이 나온 뒤에도 **당시 서술을 지우지 않고 남긴** 항목이다(예:
    `engine.bloom.hdr.upsampleWeightUnknown`). 지우지 않는 이유가 이 리포에 적혀 있다 —
    근거 축소 가드가 항목·키 소멸을 잡는데 하나를 통과시키려고 `allow_shrink` 를 켜면
    그 파일의 가드가 영구히 꺼지고, 게다가 소스·히스토리 문서가 그 id 를 인용한다.

    그래서 묘비 안에는 "미확인" 같은 헤지가 **정당하게** 남는다. 그걸 계속 신고하면
    헤지 목록이 영구 오탐을 달고 다니게 되고, 목록 전체가 무시당한다 — 실제 헤지가 그
    소음에 묻힌다. 여기서 걸러내되 **개수는 반드시 보고**한다(조용히 빼면 그게 더 나쁘다).

    이 면제는 스위치가 아니다 — 면제를 받으려면 **다른 항목이 실제로 이 id 를
    `supersedes` 로 대체**해야 한다. 대체 항목 없이 헤지만 지우는 길은 없다.
    """
    out = set()
    for d in docs.values():
        for e in d.get("entries", []):
            sup = (e.get("value") or {}).get("supersedes") if isinstance(e.get("value"), dict) else None
            if isinstance(sup, str):
                out.add(sup)
            elif isinstance(sup, list):
                out.update(x for x in sup if isinstance(x, str))
    return out


def hedge_triage(entries, path, tombstones=frozenset()):
    """확정 항목 value 안의 헤지 표현을 찾아 (보고 문자열 목록, 묘비 면제 수) 를 낸다."""
    out, exempt = [], 0
    p = os.path.basename(path)
    for e in entries:
        if e.get("status") != "확정":
            continue
        hit = None
        for s in _walk_strings(e.get("value")):
            for w in HEDGE_WORDS:
                if w in s:
                    hit = f"{p}:{e.get('id')}: 확정인데 '{w}' 가 들어 있다 — {s[:80]}"
                    break
            if hit:
                break
        if hit is None:
            continue
        if e.get("id") in tombstones:
            exempt += 1          # 대체 항목이 있는 묘비 — 당시 서술이라 정당하다
            continue
        out.append(hit)
    return out, exempt


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
        print(f"(정본 아님으로 건너뜀 {skipped}개 — golden/snapshot/ 캡처 산출물, schema.json)")
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
        if errs:
            print(f"FAIL {p}")
            for e in errs:
                print(f"   {e}")
            total_err += len(errs)
        else:
            print(f"ok   {p}  ({len(entries)} 항목)")

    # 헤지 매기기는 **문서를 다 읽은 뒤**다 — 묘비 판정에 다른 문서의 `supersedes` 가 필요하다.
    tombs = superseded_ids(docs)
    hedge_exempt = 0
    for p, d in sorted(docs.items()):
        hs, ex = hedge_triage(d.get("entries", []), p, tombs)
        hedges += hs
        hedge_exempt += ex

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

    # 조용히 빼지 않는다 — 면제한 개수를 항상 찍는다(0 이어도).
    print(f"   (묘비 면제 {hedge_exempt}건 — 다른 항목이 supersedes 로 대체한 id 라 "
          f"당시 서술의 헤지는 정당하다)")

    print()
    print("상태 분포: " + " / ".join(f"{k} {v}" for k, v in stats.items()))
    print(f"오류 {total_err} 건 · 문서간 경고 {len(cross)}건 · "
          f"헤지 {len(hedges)}건(묘비 면제 {hedge_exempt}건 별도)")
    return 0 if total_err == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
