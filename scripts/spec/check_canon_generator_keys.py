#!/usr/bin/env python3
"""정본을 **다시 만들 수 있는지** 본다 — 생성기의 키 집합 == 정본의 키 집합.

왜 있는가
---------
정본(`spec/**/*.json`)은 생성기(`scripts/spec/measure_*.py`)의 산출물이다. 그런데 사실이
바뀌면 손으로 고치는 일이 생긴다 — 생성기가 코퍼스(`WE_WORKSHOP`)나 SDK 를 요구해서
이 컨테이너에서 못 돌 때가 특히 그렇다.

손으로 고친 정본과 생성기가 갈리면 **재생성이 축소 가드에 막힌다.** `specfmt.dump` 는
키가 사라지는 쓰기를 `SpecShrinkError` 로 거절하는데, 생성기가 손으로 더한 키를 모르니
재생성이 곧 축소가 된다. 즉 정본이 **고아**가 된다 — 다시 만들 수 없는 산출물.

이 상태는 조용하다. `validate.py` 는 `generatedBy` 가 실재하는지만 보고, 축소 가드는
**쓸 때** 발동하므로 아무도 재생성을 시도하지 않으면 영영 안 드러난다.

실제로 두 건이 그 상태였다:
  · `spec/formats/mdl-deep.json` — `format.mdl.indexWidth` 의 `경계` 키를 생성기가 안 냈다.
  · `spec/assets/material-schema.json` — `3a369eb` 가 갭 5건을 "해소" 로 손으로 다시 쓰면서
    `Waple`/`영향(추정)` → `해소`/`종전 상태`/`위치` 로 키가 통째로 바뀌었는데 생성기는 그대로였다.

무엇을 못 잡는가
----------------
값이 아니라 **키 집합만** 본다. 생성기가 f-string 으로 만드는 값이 낡았는지는 여기서 안 잡힌다
(그건 재생성으로만 잡힌다). 그리고 `specfmt.entry(...)` 의 인자가 리터럴이 아니면
(id 가 변수·f-string 이거나 값이 dict 리터럴이 아니면) **건너뛴다** — 건너뛴 수를 화면에 찍어
그물의 크기를 숨기지 않는다.
"""
import ast
import collections
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
GEN_DIR = ROOT / "scripts" / "spec"
SPEC_DIR = ROOT / "spec"

# 대조된 항목 수의 하한. 그물이 조용히 작아지는 것을 막는다(패턴이 안 맞게 되면 0건 대조로
# 통과해 버리는 것이 이 리포의 상습 실패 양식이다).
MIN_COMPARED = 270


def literal_entries(src: str):
    """`specfmt.entry("<id>", {<리터럴 키>...}, ...)` 만 뽑는다. 나머지는 세어서 돌려준다."""
    out, skipped = {}, collections.Counter()
    try:
        tree = ast.parse(src)
    except SyntaxError:
        skipped["생성기 파스 실패"] += 1
        return out, skipped
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "entry" and len(node.args) >= 2):
            continue
        a0, a1 = node.args[0], node.args[1]
        if not (isinstance(a0, ast.Constant) and isinstance(a0.value, str)):
            skipped["id 비리터럴"] += 1
            continue
        if not isinstance(a1, ast.Dict):
            skipped["값 비리터럴"] += 1
            continue
        keys = [k.value for k in a1.keys
                if isinstance(k, ast.Constant) and isinstance(k.value, str)]
        if len(keys) != len(a1.keys):
            skipped["키 비리터럴"] += 1
            continue
        out[a0.value] = keys
    return out, skipped


def selftest() -> None:
    """음성 대조 — 잡아야 할 것과 통과시켜야 할 것을 매 실행 확인한다.

    실패하면 본 검사를 **아예 돌리지 않는다**. 검사기가 뚫린 채 초록을 내는 것이
    이 리포가 반복해서 당한 사고이기 때문이다(`b8efa2d` 에서 넷이 한꺼번에 드러났다)."""
    src_ok = 'specfmt.entry("a.b", {"x": 1, "y": 2}, "확정", [])'
    got, sk = literal_entries(src_ok)
    if got != {"a.b": ["x", "y"]}:
        print(f"selftest 실패: 리터럴 추출이 틀렸다 — {got}", file=sys.stderr)
        raise SystemExit(2)
    if list(got["a.b"]) == ["y", "x"]:
        print("selftest 실패: 키 순서를 보존하지 않는다", file=sys.stderr)
        raise SystemExit(2)

    # 비리터럴은 잡지 말고 **세어야** 한다 — 조용히 빠지면 그물이 작아진 것을 모른다.
    for src, want in (('specfmt.entry(f"a.{i}", {"x": 1}, "확정", [])', "id 비리터럴"),
                      ('specfmt.entry("a.b", make(), "확정", [])', "값 비리터럴"),
                      ('specfmt.entry("a.b", {k: 1}, "확정", [])', "키 비리터럴")):
        _, sk = literal_entries(src)
        if sk.get(want) != 1:
            print(f"selftest 실패: {want} 를 세지 않았다 — {dict(sk)}", file=sys.stderr)
            raise SystemExit(2)

    # `entry` 가 아닌 호출은 무시해야 한다(거짓 양성 방지).
    got, _ = literal_entries('specfmt.doc("s", {"x": 1})')
    if got:
        print(f"selftest 실패: entry 아닌 호출을 주웠다 — {got}", file=sys.stderr)
        raise SystemExit(2)
    print("selftest: OK")


def main() -> int:
    selftest()
    compared = 0
    skipped = collections.Counter()
    bad = []
    for gen in sorted(GEN_DIR.glob("measure_*.py")):
        lits, sk = literal_entries(gen.read_text(encoding="utf-8"))
        skipped.update(sk)
        if not lits:
            continue
        want = f"scripts/spec/{gen.name}"
        for cf in sorted(SPEC_DIR.rglob("*.json")):
            try:
                doc = json.loads(cf.read_text(encoding="utf-8"))
            except (ValueError, OSError):
                continue
            if not isinstance(doc, dict) or doc.get("generatedBy") != want:
                continue
            for e in doc.get("entries", []):
                eid = e.get("id")
                val = e.get("value")
                if eid not in lits or not isinstance(val, dict):
                    continue
                compared += 1
                if list(val) != lits[eid]:
                    bad.append((cf.relative_to(ROOT), eid, list(val), lits[eid]))

    if bad:
        print(f"[canon-generator-keys] 정본↔생성기 키 불일치 {len(bad)}건 — "
              f"이 정본은 재생성하면 축소 가드에 막힌다", file=sys.stderr)
        for rel, eid, ck, gk in bad:
            print(f"  {rel} :: {eid}", file=sys.stderr)
            only_c, only_g = [k for k in ck if k not in gk], [k for k in gk if k not in ck]
            if only_c:
                print(f"      정본에만  : {only_c}", file=sys.stderr)
            if only_g:
                print(f"      생성기에만: {only_g}", file=sys.stderr)
            if not only_c and not only_g:
                print(f"      순서만 다름: 정본 {ck} / 생성기 {gk}", file=sys.stderr)
        return 1

    if compared < MIN_COMPARED:
        print(f"[canon-generator-keys] 대조 {compared}건 — 하한 {MIN_COMPARED} 미만. "
              f"추출 패턴이 더 이상 안 맞는다(그물이 조용히 작아졌다).", file=sys.stderr)
        return 1

    tail = " · ".join(f"{k} {v}" for k, v in sorted(skipped.items())) or "없음"
    print(f"[canon-generator-keys] 대조 {compared}건 · 불일치 0건 · 건너뜀: {tail}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
