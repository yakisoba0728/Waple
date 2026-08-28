"""spec/ 정본 문서의 공통 포맷.

정본은 사람이 읽고 기계가 검사한다. 그래서 (a) UTF-8 그대로 두고
(b) 들여쓰기를 얕게 해서 diff 가 읽히게 하고 (c) 항목마다 근거를 강제한다.
"""
import json
import os

WE_VERSION = "2.8.42"

# 확정 = 직접 측정했고 재현 스크립트가 있다
# 보고 = 정찰 에이전트가 보고했고 아직 재현하지 않았다
# 추정 = 근거가 불충분하다
STATUSES = ("확정", "보고", "추정")

# 확정 항목이 반드시 하나 이상 가져야 하는 근거 종류 — 재현 가능한 것들
REPRODUCIBLE_KINDS = ("corpus", "binary", "asset", "shader", "script", "file")

# evidence.kind 의 **전체 열거**. `spec/schema.json` 의 `evidence.kind` 와 같아야 한다.
#
# **[2026-08-28] 이 열거가 코드에 없어서 강제되지 않았다.** `validate.py` 는 `kind` 가 비었는지만
# 보고 값은 안 봤고, 그 틈으로 열거 밖의 `note` 가 2건 통과하고 있었다(script-api 의
# `script.dts.unbacked`, uniform-feed 의 `engine.uniformFeed.unknowns` — 둘 다 참조가 아니라
# 방법의 한계를 적은 산문이라 `doc` 이 맞다). 열거는 문서에만 적혀 있으면 열거가 아니다.
EVIDENCE_KINDS = ("corpus", "binary", "asset", "shader", "script", "file", "recon", "doc")


def entry(id, value, status, evidence):
    if status not in STATUSES:
        raise ValueError(f"알 수 없는 status: {status!r} (가능: {STATUSES})")
    if not evidence:
        raise ValueError(f"{id}: evidence 가 비어 있다")
    return {"id": id, "value": value, "status": status, "evidence": list(evidence)}


def ev(kind, ref, note=None, population=None):
    """근거 하나.

    `population` 은 **선택**이다 — 값이 도수(개수·비율)일 때 "무엇을 세었는가" 를 적는다.
    [2026-08-28] 이 필드를 넣는 이유: 정본이 반복해서 당한 병이 "수치만 있고 모집단이 없다" 이고
    (동봉+설치본을 같이 세어 172 씬을 두 번 센 `corpusScenes: 358` 이 대표 사례),
    도수 옆에 모집단 이름이 없으면 두 문서의 같은 이름 도수를 섞어 산술하게 된다.
    **기존 항목에 소급 강제하지 않는다** — 강제하면 전건이 실패한다. 채워 넣을 자리를 여는
    선택 필드다.
    """
    if kind not in EVIDENCE_KINDS:
        raise ValueError(f"알 수 없는 evidence kind: {kind!r} (가능: {EVIDENCE_KINDS})")
    e = {"kind": kind, "ref": ref}
    if note:
        e["note"] = note
    if population:
        e["population"] = population
    return e


def doc(generated_by, entries, extra=None):
    d = {"weVersion": WE_VERSION, "generatedBy": generated_by}
    if extra:
        d.update(extra)
    d["entries"] = entries
    return d


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


class SpecShrinkError(RuntimeError):
    """정본을 덮어쓰면 근거가 줄어드는 상황."""


# 근거는 조용히 줄어들지 않는다.
#
# 생성기 대부분은 입력(설치본·워크샵 코퍼스·바이너리)이 없으면 exit(1) 로 막는다. 그런데
# 막지 않는 생성기가 둘 있었고, 그것들은 **입력 0건에서 측정한 결과를 `확정` 으로 기록하며
# 성공했다**. 2026-08-20 실측:
#   · measure_binaries.py  — entries 32 → 0. "0 항목" 을 찍고도 rc=0, 근거 706줄 삭제
#   · measure_mdl_deep.py  — entries 는 15 그대로인데 파일수/메시수 451/986 → 0/0,
#                            관측버전 {} , 근거 ref 가 "전수 451개" → "전수 0개"
# 30개 생성기에 가드를 하나씩 다는 대신 정본을 쓰는 **단일 관문**에서 막는다. 앞으로 추가될
# 생성기도 자동으로 보호된다(그게 이 위치를 고른 이유다).
#
# 규칙 둘. 둘 다 "있던 근거가 사라지는 것"만 잡고 늘어나는 쪽은 통과시킨다 —
# 재측정으로 수치가 커지거나 항목이 추가되는 것은 정상이다.
#   1) entries 의 id 집합에서 **빠지는 id** 가 있으면 거부      (binaries 32→0 을 잡는다)
#   2) 값이 **양수 → 0** 이거나 **비지 않은 컨테이너 → 빔** 이면 거부  (mdl-deep 을 잡는다)
#
# 진짜로 줄여야 할 때(항목 폐기, 코퍼스 축소)는 사람이 명시한다:
#   dump(..., allow_shrink=True) 또는 환경변수 WAPLE_SPEC_ALLOW_SHRINK=1
def _kind(v):
    """축소 판정용 형(型). int/float 은 한 형으로 본다 — 451 → 451.0 은 축소가 아니다."""
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, (int, float)):
        return "num"
    if isinstance(v, str):
        return "str"
    if isinstance(v, dict):
        return "dict"
    if isinstance(v, list):
        return "list"
    return "null"                        # None 과 그 밖 전부


def _shrinks(old, new, path=""):
    """old 에 있던 근거가 new 에서 사라진 자리를 모은다. 커진 쪽은 보지 않는다.

    **[2026-08-20] 부분 축소를 놓치던 구멍 셋을 막았다.** 이 가드의 위협 모델은 스스로
    "입력이 **아예 없을 때**보다 **부분적으로만 있을 때**가 더 위험하다" 인데, 구현이 잡는
    것은 "완전히 비었을 때" 뿐이었다:

      · dict — `for k in old: if k in new` 라 **new 에서 사라진 키를 순회조차 않았다**
      · list — `zip(old, new)` 라 new 가 짧으면 꼬리를 안 봤다(길이 자체는 아래 이유로
        여전히 세지 않는다 — 갭 목록이 줄어드는 것은 정상이다)
      · 형 변경 — int→None, list→int, dict→null 은 어느 `isinstance` 쌍에도 안 걸려 `[]` 였다
        (`dict.get()` 이 자연히 내는 모양이 바로 int→None 이다)

    실측: 커밋된 `spec/engine/render-pass.json` 을 40,064 → 8,191 바이트로 깎아도 통과했다.
    형 변경을 축소로 세는 것이 세 구멍 중 가장 넓은 자리를 막는다.
    """
    out = []
    ko, kn = _kind(old), _kind(new)
    if ko == "bool" or kn == "bool":
        return out                       # bool 은 측정량이 아니라 스위치다
    if ko != kn:
        # 형이 바뀌면 값 비교가 성립하지 않는다 — 근거가 다른 것으로 대체된 것이므로 축소로 본다.
        # (측정량이 진짜로 형을 바꿔야 하면 allow_shrink 로 명시하라.)
        out.append(f"{path}: {ko} → {kn}")
        return out
    if ko == "num":
        if old > 0 and new == 0:
            out.append(f"{path}: {old} → 0")
        return out
    if ko == "dict":
        if old and not new:
            out.append(f"{path}: {len(old)}개 키 → 빔")
            return out
        gone = [k for k in old if k not in new]
        if gone:
            shown = ", ".join(map(str, gone[:6])) + (f" 외 {len(gone) - 6}개" if len(gone) > 6 else "")
            out.append(f"{path}: 키 {len(gone)}개 소멸({shown})")
        for k in old:
            if k in new:
                out += _shrinks(old[k], new[k], f"{path}.{k}" if path else str(k))
        return out
    if ko == "list":
        if old and not new:
            out.append(f"{path}: {len(old)}개 원소 → 빔")
            return out
        # 리스트 **길이 축소는 일부러 세지 않는다.** 이 리포에서 리스트는 갭 목록·미해결 목록이
        # 흔하고, 그게 줄어드는 것이 곧 일이 끝났다는 뜻이다(음성 대조 `gap-list-shrinks-not-empty`).
        # 부분 입력이 내는 진짜 축소는 키 소멸과 형 변경으로 잡힌다 — 실측으로 확인했다.
        for i, (o, n) in enumerate(zip(old, new)):
            out += _shrinks(o, n, f"{path}[{i}]")
        return out
    if ko == "str":
        if old and not new:
            out.append(f"{path}: 문자열 → 빔")
    return out


def shrink_report(new_doc, path):
    """`new_doc` 으로 `path` 를 덮어쓸 때 사라지는 근거를 열거한다.

    파일이 아직 없거나 정본 형태가 아니면 검사할 이전 상태가 없으므로 빈 목록.
    """
    try:
        old = load(path)
    except (FileNotFoundError, ValueError):
        return []
    if not isinstance(old, dict) or not isinstance(new_doc, dict):
        return []
    old_entries, new_entries = old.get("entries"), new_doc.get("entries")
    if not isinstance(old_entries, list):
        return []                        # 이전 상태가 정본 형태가 아니면 비교 대상이 없다
    # **[2026-08-20]** 종전엔 여기서도 `[]` 를 돌려줬다 — 즉 정본을 `{}` 로 통째 덮어써도
    # 통과했다. 이전이 정본이었는데 새 문서에 entries 가 없다면 그것이야말로 최악의 축소다.
    if not isinstance(new_entries, list):
        return [f"entries: {len(old_entries)}개 항목이 있던 자리에 entries 리스트가 없다"]
    out = []
    old_by = {e.get("id"): e for e in old_entries if isinstance(e, dict)}
    new_by = {e.get("id"): e for e in new_entries if isinstance(e, dict)}
    gone = sorted(str(i) for i in old_by if i not in new_by)
    if gone:
        shown = ", ".join(gone[:8]) + (f" 외 {len(gone) - 8}건" if len(gone) > 8 else "")
        out.append(f"사라진 항목 {len(gone)}개: {shown}")
    for i, oe in old_by.items():
        ne = new_by.get(i)
        if ne is not None:
            out += _shrinks(oe.get("value"), ne.get("value"), str(i))
            # **[2026-08-20]** 이름이 "근거가 줄어들지 않는다" 인데 종전엔 `value` 만 봤다.
            # evidence 도 같은 규칙(키 소멸·형 변경·양수→0)으로 본다.
            out += _shrinks(oe.get("evidence"), ne.get("evidence"), f"{i}.evidence")
    return out


def dump(obj, path, allow_shrink=False):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    if not allow_shrink and os.environ.get("WAPLE_SPEC_ALLOW_SHRINK") != "1":
        problems = shrink_report(obj, path)
        if problems:
            head = problems[:20]
            tail = f"\n  … 외 {len(problems) - 20}건" if len(problems) > 20 else ""
            raise SpecShrinkError(
                f"{path}: 근거가 줄어든다 — 입력이 빠진 채로 측정했을 가능성이 높다.\n"
                + "\n".join("  · " + p for p in head) + tail
                + "\n  먼저 WE_ROOT / WE_WORKSHOP 이 설정돼 있는지 확인하라."
                + "\n  정말 줄이는 게 맞으면 dump(..., allow_shrink=True) 또는"
                  " WAPLE_SPEC_ALLOW_SHRINK=1."
            )
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(obj, fh, indent=1, ensure_ascii=False, sort_keys=False)
        fh.write("\n")
