#!/usr/bin/env python3
"""정본이 **조용히 줄어드는 것**을 막는 가드의 회귀 검사.

## 왜 있나

`spec/` 아래 정본은 재현 스크립트(`measure_*.py`)가 만든다. 그 스크립트들은 WE 설치본과
워크샵 코퍼스를 입력으로 받는데, 입력이 없으면 대부분 `exit(1)` 로 막는다. 그런데 막지
않는 것들이 있었고, 그것들은 **입력 0건에서 측정한 결과를 `확정` 으로 기록하며 성공**했다.
2026-08-20 실측(WE_ROOT 만 있고 WE_WORKSHOP 이 없는 환경):

  · measure_binaries.py   — entries 32 → 0. "0 항목" 을 찍고도 rc=0, 근거 706줄 삭제
  · measure_mdl_deep.py   — entries 15 는 유지한 채 파일수/메시수 451/986 → 0/0,
                            관측버전 {} , 근거 ref 가 "전수 451개" → "전수 0개"
  · measure_render_pass.py — d3d11Slots 9개 키 → 빔

입력이 **아예 없을 때**보다 **부분적으로만 있을 때**가 더 위험하다. 전자는 파일 열기에서
죽지만 후자는 끝까지 돌아 성공을 보고한다. `WE_ROOT 가 설정됐는가` 같은 조건으로는 못 잡는다.

## 무엇을 검사하나

가드는 정본을 쓰는 단일 관문 `specfmt.dump` 에 있다(생성기 33개가 전부 이 문을 지난다).
이 검사는 그 가드가 살아 있는지를 본다:

  1. 양성 대조 — 줄어드는 쓰기는 반드시 `SpecShrinkError` 여야 한다
  2. 음성 대조 — 늘어나거나 그대로인 쓰기는 반드시 통과해야 한다(가드가 과잉이면 안 된다)
  3. 실사 대조 — 위 두 생성기가 실제로 낸 열화를 **커밋된 정본에서 재구성**해 잡히는지 본다
  4. 관문 우회 — 생성기가 `specfmt.dump` 를 거치지 않고 정본을 쓰지 않는지 정적 검사

쓰기는 전부 임시 디렉터리로 간다 — 이 검사는 리포의 정본을 건드리지 않는다.
"""
import copy
import json
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import specfmt  # noqa: E402

# `json.dump` 를 직접 부르지만 **정본이 아닌** 곳. 새로 생기면 검사가 실패하므로
# 반드시 사람이 보고 등록해야 한다 — 휴리스틱(문자열 포함 검사)으로 걸러내면 진짜 우회를
# 놓친다. 각 항목은 "무엇을 쓰는가 / 왜 정본이 아닌가"를 적는다.
RAW_DUMP_ALLOWED = {
    # 사용자가 `--json <path>` 로 지정한 임시 산출물. spec/ 아래로 가지 않고
    # 정본 스키마도 아니다(entries 없는 원시 측정 덤프).
    ("measure_mip_luma.py", 269),
    # tex 사이드카를 임시 디렉터리(`tmp`)에 풀어 놓고 되읽는 중간 산출물.
    ("measure_tex_deep.py", 493),
}

FAILS = []


def fail(msg):
    FAILS.append(msg)
    print(f"  X {msg}")


def ok(msg):
    print(f"  . {msg}")


def writes(doc, path, **kw):
    """쓰기가 통과하면 True, 가드에 막히면 False."""
    try:
        specfmt.dump(doc, path, **kw)
        return True
    except specfmt.SpecShrinkError:
        return False


def doc(entries):
    return {"weVersion": specfmt.WE_VERSION, "generatedBy": "test", "entries": entries}


def entry(id, value):
    return {"id": id, "value": value, "status": "확정",
            "evidence": [{"kind": "binary", "ref": "test"}]}


def must_block(tmp, name, before, after):
    p = os.path.join(tmp, name + ".json")
    specfmt.dump(before, p)                      # 초기 상태는 비교 대상이 없으니 통과한다
    if writes(after, p):
        fail(f"[양성] {name}: 줄어드는 쓰기가 통과했다")
    else:
        ok(f"[양성] {name} 차단")


def must_pass(tmp, name, before, after, **kw):
    p = os.path.join(tmp, name + ".json")
    specfmt.dump(before, p)
    if not writes(after, p, **kw):
        fail(f"[음성] {name}: 정상 쓰기가 막혔다")
    else:
        ok(f"[음성] {name} 통과")


def zero_numbers(obj):
    """양수를 전부 0 으로, 컨테이너를 전부 비운다 — 입력 0건 측정의 형태."""
    if isinstance(obj, bool):
        return obj
    if isinstance(obj, (int, float)):
        return 0
    if isinstance(obj, dict):
        return {} if obj else obj
    if isinstance(obj, list):
        return [] if obj else obj
    return obj


def degrade(obj):
    """entries 의 value 안쪽 수치만 0 으로 눌러 measure_mdl_deep 의 열화를 흉내낸다."""
    if isinstance(obj, dict):
        return {k: degrade(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [degrade(v) for v in obj]
    return zero_numbers(obj)


def main():
    tmp = tempfile.mkdtemp(prefix="spec-shrink-")
    try:
        print("[1] 양성 대조 — 줄어드는 쓰기는 막혀야 한다")
        must_block(tmp, "id-removal",
                   doc([entry("a", 1), entry("b", 2)]), doc([entry("a", 1)]))
        must_block(tmp, "all-entries-gone",
                   doc([entry("a", 1)]), doc([]))
        must_block(tmp, "positive-to-zero",
                   doc([entry("a", {"n": 451})]), doc([entry("a", {"n": 0})]))
        must_block(tmp, "dict-emptied",
                   doc([entry("a", {"m": {"x": 1}})]), doc([entry("a", {"m": {}})]))
        must_block(tmp, "list-emptied",
                   doc([entry("a", {"m": [1, 2]})]), doc([entry("a", {"m": []})]))
        must_block(tmp, "string-emptied",
                   doc([entry("a", {"s": "451개"})]), doc([entry("a", {"s": ""})]))
        must_block(tmp, "nested-deep",
                   doc([entry("a", {"x": {"y": {"z": 5}}})]),
                   doc([entry("a", {"x": {"y": {"z": 0}}})]))

        print("[2] 음성 대조 — 정상 쓰기는 통과해야 한다")
        must_pass(tmp, "unchanged", doc([entry("a", 1)]), doc([entry("a", 1)]))
        must_pass(tmp, "grew-value",
                  doc([entry("a", {"n": 5})]), doc([entry("a", {"n": 9})]))
        must_pass(tmp, "added-entry",
                  doc([entry("a", 1)]), doc([entry("a", 1), entry("b", 2)]))
        must_pass(tmp, "zero-stays-zero",
                  doc([entry("a", {"n": 0})]), doc([entry("a", {"n": 0})]))
        must_pass(tmp, "gap-list-shrinks-not-empty",   # missing 목록이 줄어드는 건 갭이 닫힌 것
                  doc([entry("a", {"missing": ["x", "y"]})]),
                  doc([entry("a", {"missing": ["x"]})]))
        must_pass(tmp, "bool-flip",                    # bool 은 측정량이 아니다
                  doc([entry("a", {"b": True})]), doc([entry("a", {"b": False})]))
        must_pass(tmp, "explicit-allow",
                  doc([entry("a", 1), entry("b", 2)]), doc([entry("a", 1)]),
                  allow_shrink=True)

        # 새 파일(비교 대상 없음)은 항상 통과해야 한다
        fresh = os.path.join(tmp, "brand-new.json")
        if not writes(doc([]), fresh):
            fail("[음성] 새 파일 쓰기가 막혔다")
        else:
            ok("[음성] 새 파일 통과")

        print("[3] 환경변수 탈출구")
        os.environ["WAPLE_SPEC_ALLOW_SHRINK"] = "1"
        p = os.path.join(tmp, "envesc.json")
        specfmt.dump(doc([entry("a", 1), entry("b", 2)]), p)
        escaped = writes(doc([entry("a", 1)]), p)
        os.environ.pop("WAPLE_SPEC_ALLOW_SHRINK", None)
        if not escaped:
            fail("[탈출구] WAPLE_SPEC_ALLOW_SHRINK=1 이 듣지 않는다")
        else:
            ok("[탈출구] WAPLE_SPEC_ALLOW_SHRINK=1 동작")
        # 탈출구를 치우면 다시 막혀야 한다 — 환경 오염으로 가드가 죽는 일이 없게
        specfmt.dump(doc([entry("a", 1), entry("b", 2)]), p, allow_shrink=True)
        if writes(doc([entry("a", 1)]), p):
            fail("[탈출구] 환경변수를 치웠는데도 가드가 죽어 있다")
        else:
            ok("[탈출구] 치운 뒤 가드 복귀")

        print("[4] 실사 대조 — 커밋된 정본으로 과거 열화를 재구성한다")
        cases = [
            ("spec/binaries.json", lambda d: {**d, "entries": []},
             "measure_binaries: entries 32 → 0"),
            ("spec/formats/mdl-deep.json",
             lambda d: {**d, "entries": [{**e, "value": degrade(e.get("value"))}
                                         for e in d["entries"]]},
             "measure_mdl_deep: 파일수/메시수 → 0"),
            ("spec/engine/render-pass.json",
             lambda d: {**d, "entries": [{**e, "value": degrade(e.get("value"))}
                                         for e in d["entries"]]},
             "measure_render_pass: d3d11Slots → 빔"),
        ]
        for rel, wreck, label in cases:
            src = os.path.join(REPO, rel)
            if not os.path.isfile(src):
                fail(f"[실사] 정본이 없다: {rel}")
                continue
            good = json.load(open(src, encoding="utf-8"))
            if not good.get("entries"):
                fail(f"[실사] {rel}: entries 가 비어 있다 — 이미 지워진 것 아닌가")
                continue
            dst = os.path.join(tmp, rel.replace("/", "_"))
            specfmt.dump(copy.deepcopy(good), dst)
            if writes(wreck(copy.deepcopy(good)), dst):
                fail(f"[실사] {label} 가 통과했다")
            else:
                ok(f"[실사] {label} 차단")

        print("[5] 관문 우회 — 생성기가 specfmt.dump 를 건너뛰지 않는가")
        for path in sorted(os.listdir(HERE)):
            if not path.startswith("measure_") or not path.endswith(".py"):
                continue
            src = open(os.path.join(HERE, path), encoding="utf-8").read()
            # `json.dump(` 로 정본 경로에 직접 쓰는 곳이 있으면 가드를 우회한다.
            # (`json.dumps` 는 문자열이라 무관하고, `--json` 같은 사용자 지정 출력도 정본이 아니다.)
            for m in re.finditer(r"json\.dump\(", src):
                line = src[:m.start()].count("\n") + 1
                body = src.splitlines()[line - 1].strip()
                if (path, line) in RAW_DUMP_ALLOWED:
                    continue
                fail(f"[우회] {path}:{line} 이 specfmt.dump 없이 json.dump 한다 — {body}\n"
                     f"        정본이 아니면 RAW_DUMP_ALLOWED 에 사유와 함께 등록하라.")
        if not any(f.startswith("[우회]") for f in FAILS):
            ok("[우회] 모든 생성기가 관문을 지난다")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print()
    if FAILS:
        print(f"[spec-shrink-guard] 실패 {len(FAILS)}건")
        return 1
    print("[spec-shrink-guard] 통과")
    return 0


if __name__ == "__main__":
    sys.exit(main())
