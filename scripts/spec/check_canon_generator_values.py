#!/usr/bin/env python3
"""정본을 **다시 만들면 같은 글이 나오는지** 본다 — 생성기의 리터럴 값 == 정본의 값.

왜 있는가
---------
형제 게이트 `check_canon_generator_keys.py` 는 **키 집합**만 본다. 그 파일이 스스로 적어 둔
한계가 이것이다: "값이 아니라 키 집합만 본다. 생성기가 만드는 값이 낡았는지는 여기서 안 잡힌다."

그 구멍은 조용하다. 정본은 손으로 고칠 수 있고(생성기가 코퍼스를 요구해 이 컨테이너에서 못
돌 때가 특히 그렇다), 손으로 고친 문장이 생성기에 안 들어가면 **재생성이 그 정정을 되돌린다.**
키는 그대로이므로 형제 게이트는 초록이고, 축소 가드도 키가 안 사라졌으니 초록이다.
아무도 재생성을 시도하지 않으면 영영 안 드러난다.

실제로 두 건이 그 상태였다(2026-08-21 이 게이트를 만들며 발견):
  · `waple.gap.strictJSON` 의 `note` — 정본은 갭 해소에 맞춰 시제를 과거로 고쳐 뒀는데
    (`발현하지 않았다`/`잠재 결함이었다`) 생성기는 현재형이었다.
  · `waple.gap.composeAndConditions` 의 `갭 아님` — 정본은 `replacementkey` 가 `fafcd21` 로
    **소비된다**고 고쳐 뒀는데 생성기는 그것을 여전히 "미소비가 정상" 쪽에 묶고 있었다.
둘 다 재생성하면 조용히 되돌아갔을 정정이다.

무엇을 보는가
-------------
`specfmt.entry("<id>", {...})` 의 **값이 리터럴인 키만** 본다(`ast.literal_eval` 이 성립하는
것). f-string·변수·컴프리헨션 같은 동적 값은 코퍼스가 있어야 알 수 있으므로 건너뛴다 —
건너뛴 수를 화면에 찍어 그물의 크기를 숨기지 않는다.

정본에 없는 id 는 건너뛴다. 조건부로만 발행되는 엔트리가 있기 때문이다
(`binary.fingerprints.missing` · `weInstall.missing` 처럼 "빠진 게 있을 때만" 나오는 것들).

무엇을 못 잡는가
----------------
동적 값이 낡은 것은 **재생성으로만** 잡힌다. 그리고 생성기와 정본이 **똑같이** 낡은 경우도
여기서는 안 잡힌다 — 그건 사실 확인의 몫이다.
"""
import ast
import collections
import glob
import importlib.util
import io
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

# 리터럴 비교 건수의 하한. 패턴이 안 맞게 되어 0건 대조로 통과하는 것이 이 리포의 상습
# 실패 양식이다(형제 게이트도 같은 이유로 `MIN_COMPARED` 를 둔다).
MIN_COMPARED = 900

# 생성기와 정본이 **일부러** 다른 자리. 키는 `(엔트리 id, 키 이름)`, 값은 사유.
# 지금은 비어 있다 — 비어 있는 것이 정상이고, 넣을 때는 사유가 반드시 있어야 한다.
# (줄 번호로 걸지 않는 이유는 `check_spec_shrink_guard.py` 머리말 참조.)
ALLOWED_DIVERGENCE = {}


def canon_entries():
    """id -> (정본 경로, value)"""
    out = {}
    for p in sorted(glob.glob(str(ROOT / "spec" / "**" / "*.json"), recursive=True)):
        try:
            doc = json.load(io.open(p, encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(doc, dict):
            continue
        for e in (doc.get("entries") or []):
            if isinstance(e, dict) and isinstance(e.get("id"), str):
                out[e["id"]] = (pathlib.Path(p).relative_to(ROOT), e.get("value"))
    return out


def generator_literals(src: str, skipped: collections.Counter):
    """id -> {키: 리터럴값}. 비리터럴은 세기만 한다."""
    out = {}
    try:
        tree = ast.parse(src)
    except SyntaxError:
        skipped["생성기 파스 실패"] += 1
        return out
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "entry" and len(node.args) >= 2):
            continue
        a0, a1 = node.args[0], node.args[1]
        if not (isinstance(a0, ast.Constant) and isinstance(a0.value, str)):
            skipped["id 비리터럴"] += 1
            continue
        if not isinstance(a1, ast.Dict):
            skipped["값 비딕셔너리"] += 1
            continue
        d = {}
        for k, v in zip(a1.keys, a1.values):
            if not (isinstance(k, ast.Constant) and isinstance(k.value, str)):
                skipped["키 비리터럴"] += 1
                continue
            try:
                d[k.value] = ast.literal_eval(v)
            except Exception:
                skipped["값 동적(f-string·변수 등)"] += 1
        out[a0.value] = d
    return out


def compare(gen_by_id, canon, used):
    """(id, 키, 생성기값, 정본값) 불일치 목록."""
    bad, compared = [], 0
    for eid, keys in gen_by_id.items():
        if eid not in canon:          # 조건부 발행 엔트리 — 정본에 없어도 정상
            continue
        _, cv = canon[eid]
        if not isinstance(cv, dict):
            continue
        for k, lit in keys.items():
            if k not in cv:           # 키 소실은 형제 게이트(check_canon_generator_keys)의 몫
                continue
            compared += 1
            if cv[k] == lit:
                continue
            if (eid, k) in ALLOWED_DIVERGENCE:
                used.add((eid, k))
                continue
            bad.append((eid, k, lit, cv[k]))
    return bad, compared


def particle_source_ref_mismatches(doc, expected_site, expected_ref, expected_comment):
    """Dynamic particle fields that can be recomputed without the external corpus."""
    entries = {e.get("id"): e for e in doc.get("entries", []) if isinstance(e, dict)}
    entry = entries.get("engine.particle.systemFlagsUnused", {})
    value = entry.get("value", {}) if isinstance(entry, dict) else {}
    refs = [ev.get("ref") for ev in entry.get("evidence", [])
            if isinstance(ev, dict) and ev.get("kind") == "file"]
    bad = []
    if value.get("consumeSite") != expected_site:
        bad.append(("consumeSite", value.get("consumeSite"), expected_site))
    if value.get("staleComment") != expected_comment:
        bad.append(("staleComment", value.get("staleComment"), expected_comment))
    if refs != [expected_ref]:
        bad.append(("evidence.file.ref", refs, [expected_ref]))
    return bad


def selftest() -> None:
    """음성 대조 — 잡아야 할 것과 통과시켜야 할 것을 매 실행 확인한다.

    실패하면 본 검사를 **아예 돌리지 않는다**. 그물이 뚫린 채 초록을 내는 것이
    이 리포가 반복해서 당한 사고이기 때문이다."""
    src = (
        'specfmt.entry("x.same", {"a": "그대로"}, "확정", [])\n'
        'specfmt.entry("x.diff", {"a": "생성기 판"}, "확정", [])\n'
        'specfmt.entry("x.dyn",  {"a": f"{n}건"}, "확정", [])\n'
        'specfmt.entry("x.absent", {"a": "정본에 없는 엔트리"}, "확정", [])\n'
    )
    skipped = collections.Counter()
    gen = generator_literals(src, skipped)
    canon = {
        "x.same": (pathlib.Path("t.json"), {"a": "그대로"}),
        "x.diff": (pathlib.Path("t.json"), {"a": "정본 판"}),
        "x.dyn": (pathlib.Path("t.json"), {"a": "3건"}),
    }
    used = set()
    bad, compared = compare(gen, canon, used)
    if [(e, k) for e, k, _, _ in bad] != [("x.diff", "a")]:
        print(f"selftest 실패: 불일치 검출이 어긋난다 — {bad!r}", file=sys.stderr)
        raise SystemExit(2)
    if compared != 2:                       # same + diff. dyn 은 동적, absent 는 정본에 없다
        print(f"selftest 실패: 비교 건수가 {compared} 다(2 여야 한다)", file=sys.stderr)
        raise SystemExit(2)
    if skipped["값 동적(f-string·변수 등)"] != 1:
        print(f"selftest 실패: 동적 값 집계가 어긋난다 — {dict(skipped)}", file=sys.stderr)
        raise SystemExit(2)
    particle_bad = particle_source_ref_mismatches(
        {"entries": [{"id": "engine.particle.systemFlagsUnused",
                      "value": {"consumeSite": "old", "staleComment": "old"},
                      "evidence": [{"kind": "file", "ref": "old:1"}]}]},
        "new", "new:2", "current")
    if [item[0] for item in particle_bad] != ["consumeSite", "staleComment", "evidence.file.ref"]:
        print(f"selftest 실패: 파티클 동적 근거 드리프트를 못 잡는다 — {particle_bad!r}",
              file=sys.stderr)
        raise SystemExit(2)
    # 면제가 실제로 먹는지, 그리고 먹은 것이 기록되는지
    ALLOWED_DIVERGENCE[("x.diff", "a")] = "selftest"
    try:
        used2 = set()
        bad2, _ = compare(gen, canon, used2)
        if bad2 or used2 != {("x.diff", "a")}:
            print(f"selftest 실패: 면제가 안 먹는다 — {bad2!r} / {used2!r}", file=sys.stderr)
            raise SystemExit(2)
    finally:
        del ALLOWED_DIVERGENCE[("x.diff", "a")]
    print("selftest: OK")


def main() -> int:
    selftest()
    canon = canon_entries()
    skipped = collections.Counter()
    bad, compared, used = [], 0, set()
    gens = sorted(glob.glob(str(ROOT / "scripts" / "spec" / "measure_*.py")))
    if not gens:
        print("[canon-generator-values] 생성기를 하나도 못 찾았다 — 경로가 어긋났다", file=sys.stderr)
        return 1
    for g in gens:
        gen = generator_literals(io.open(g, encoding="utf-8").read(), skipped)
        b, c = compare(gen, canon, used)
        compared += c
        bad += [(pathlib.Path(g).name,) + t for t in b]

    # `particle-fields.json` 의 이 세 값은 코퍼스 없이도 현재 소스에서 다시 만들 수 있다.
    # 리터럴 검사에서 동적 값으로 빠지므로 별도로 대조한다.
    particle_path = ROOT / "spec" / "engine" / "particle-fields.json"
    generator_path = ROOT / "scripts" / "spec" / "measure_particle_fields.py"
    try:
        particle_doc = json.loads(particle_path.read_text(encoding="utf-8"))
        module_spec = importlib.util.spec_from_file_location("particle_fields_generator", generator_path)
        particle = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(particle)
        line = particle._flags_consume_lineno()
        if line is None:
            particle_dynamic_bad = [("source", None, "`(sys.def.flags & 1)` 조건식")]
        else:
            particle_dynamic_bad = particle_source_ref_mismatches(
                particle_doc, particle.flags_consume_site(), f"{particle.RSRC}:{line}",
                particle.flags_comment_staleness())
    except (OSError, ValueError, AttributeError) as error:
        particle_dynamic_bad = [("검사 자체", str(error), "성공")]

    if particle_dynamic_bad:
        print("[canon-generator-values] particle-fields 동적 소스 근거가 정본과 갈린다.",
              file=sys.stderr)
        for key, current, expected in particle_dynamic_bad:
            print(f"  {key}\n      정본: {str(current)[:240]}\n      생성: {str(expected)[:240]}",
                  file=sys.stderr)
        return 1

    if bad:
        print(f"[canon-generator-values] 생성기와 정본의 값이 갈린다 {len(bad)}건 — "
              f"재생성하면 정본 쪽 문면이 조용히 되돌아간다.", file=sys.stderr)
        for gname, eid, k, lit, cur in bad:
            print(f"  {gname}  {eid} / {k}", file=sys.stderr)
            print(f"      생성기: {str(lit)[:200]}", file=sys.stderr)
            print(f"      정본  : {str(cur)[:200]}", file=sys.stderr)
        print("  → 정본 쪽이 최신이면 그 문면을 **생성기로 되가져와라**(이 리포의 관례다).",
              file=sys.stderr)
        print("  → 일부러 갈라 둔 것이면 ALLOWED_DIVERGENCE 에 사유와 함께 넣어라.", file=sys.stderr)
        return 1

    stale = set(ALLOWED_DIVERGENCE) - used
    if stale:
        print(f"[canon-generator-values] 쓰이지 않는 면제 {len(stale)}건 — 낡았다. 지워라.",
              file=sys.stderr)
        for t in sorted(stale):
            print(f"  | {t}", file=sys.stderr)
        return 1

    if compared < MIN_COMPARED:
        print(f"[canon-generator-values] 리터럴 대조 {compared}건 — 하한 {MIN_COMPARED} 미만. "
              f"패턴이 안 맞게 되어 그물이 작아졌을 가능성이 높다.", file=sys.stderr)
        return 1

    note = " · ".join(f"{k} {v}" for k, v in sorted(skipped.items())) or "없음"
    print(f"[canon-generator-values] 생성기 {len(gens)}개 · 리터럴 대조 {compared}건 · "
          f"불일치 0건 (비교 못 한 값: {note})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
