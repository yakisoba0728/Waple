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


def entry(id, value, status, evidence):
    if status not in STATUSES:
        raise ValueError(f"알 수 없는 status: {status!r} (가능: {STATUSES})")
    if not evidence:
        raise ValueError(f"{id}: evidence 가 비어 있다")
    return {"id": id, "value": value, "status": status, "evidence": list(evidence)}


def ev(kind, ref, note=None):
    e = {"kind": kind, "ref": ref}
    if note:
        e["note"] = note
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


def dump(obj, path):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(obj, fh, indent=1, ensure_ascii=False, sort_keys=False)
        fh.write("\n")
