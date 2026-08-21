#!/usr/bin/env python3
"""정본이 **산문 안에서 가리키는 다른 항목**이 실제로 있는지 본다.

왜 있는가
---------
`spec/**/*.json` 의 항목은 서로를 산문으로 가리킨다 — "상세는 `format.mdl.mdlaTrackFraming`",
"§`shape.corpusUsage.scaledQuads`" 처럼. 그 대상이 없어도 **아무도 안 잡는다**:

  · `validate.py` 는 `crossRef`/`supersedes`/`canonicalIn` **세 키만** 보고, 그마저
    실패가 아니라 경고다. 산문 한복판의 참조는 아예 안 본다.
  · `check_canon_generator_keys.py` 는 정본과 생성기에 **둘 다 있는** id 만 대조한다
    (`if eid not in lits ... continue`) — 생성기가 만드는데 **정본에 없는 항목**은
    조용히 건너뛴다.
  · `specfmt.dump` 의 축소 가드는 있던 것이 사라질 때만 운다. 애초에 안 들어간 항목은 모른다.

그래서 실제로 이런 상태가 살아 있었다(2026-08-21 이 게이트를 만들며 발견):
`spec/formats/mdl-deep.json` 의 `format.mdl.parseCoverage` 가 "MDLA: 클립별 본 트랙 프레이밍
(format.mdl.mdlaTrackFraming)" 이라고 적는데 **그 항목이 정본에 없었다** — 생성기
(`measure_mdl_deep.py`)는 만들고 있었고, 코퍼스가 필요해 이 컨테이너에서 재생성이 안 되니
아무도 눈치채지 못했다. 읽는 사람은 있지도 않은 항목을 찾으러 간다.

무엇을 보는가
-------------
항목의 `value` 와 `evidence` 안의 모든 문자열에서 **spec id 꼴 토큰**을 뽑는다
(`validate.py` 와 같은 관례: 점 2개 이상 = `a.b.c`). 그중 **네임스페이스가 실재하는 것만**
참조로 본다 — 앞 두 마디(`format.mdl` 처럼)를 공유하는 정본 id 가 하나라도 있어야 한다.
이 좁힘이 오탐을 막는 유일한 장치다. 실측: 정본 전체에서 id 꼴 토큰 124종 중 미해결이 64종인데
그 62종은 `lib.es2015.core.d.ts` · `ec601.0.299` · `dshow.lav.vmr9` 같은 **참조가 아닌 산문**이고
네임스페이스가 없다.

해석되는 경우는 셋이다:
  1. 토큰이 그대로 정본 id 다.
  2. 토큰의 **점 접두**가 정본 id 다 — `engine.particle.flagBitMeaning.notVerified` 처럼
     "항목 + 그 안의 키" 를 가리키는 관례(실물 2건).
  3. 토큰이 어떤 정본 id 의 **점 접두**다 — 네임스페이스만 가리키는 경우.

무엇을 못 잡는가
----------------
네임스페이스 자체가 아직 없는 참조(첫 항목을 만들기 전에 미리 적어 둔 경우)는 오탐을 피하려고
일부러 안 잡는다. 그리고 **id 가 맞는데 내용이 다른 곳을 가리키는** 것은 사람의 몫이다.
"""
import collections
import glob
import io
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

# `validate.py` 의 ID_IN_PROSE 와 같은 관례(점 2개 이상 = spec id). 두 곳이 갈리지 않게
# 정규식을 그대로 맞춘다 — 갈리면 한쪽이 보는 것을 다른 쪽이 못 본다.
ID_IN_PROSE = re.compile(r"[a-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+){2,}")

# 훑은 참조 수의 하한. 패턴이 안 맞게 되어 0건 대조로 통과하는 것이 이 리포의 상습 실패 양식이다
# (형제 게이트들도 같은 이유로 하한을 둔다). CI 가 초록으로 실제 측정한 수에만 맞춰 올려라.
MIN_SCANNED = 40


def walk_strings(v):
    if isinstance(v, str):
        yield v
    elif isinstance(v, dict):
        for k, x in v.items():
            yield str(k)
            yield from walk_strings(x)
    elif isinstance(v, list):
        for x in v:
            yield from walk_strings(x)


def dot_prefixes(t):
    """`a.b.c.d` → `a.b.c`, `a.b` (자기 자신 제외)."""
    parts = t.split(".")
    for n in range(len(parts) - 1, 1, -1):
        yield ".".join(parts[:n])


def unresolved(ids, entries):
    """(파일, 항목 id, 못 찾은 토큰) 목록과 훑은 참조 수."""
    namespaces = {".".join(i.split(".")[:2]) for i in ids}
    bad, scanned = [], 0
    for path, eid, value in entries:
        seen = set()
        for s in walk_strings(value):
            for t in ID_IN_PROSE.findall(s):
                if t in seen:
                    continue
                seen.add(t)
                if ".".join(t.split(".")[:2]) not in namespaces:
                    continue                      # 참조가 아닌 산문 — 네임스페이스가 없다
                scanned += 1
                if t in ids:
                    continue
                if any(p in ids for p in dot_prefixes(t)):
                    continue                      # 항목 + 그 안의 키
                if any(i.startswith(t + ".") for i in ids):
                    continue                      # 네임스페이스만 가리킨다
                bad.append((path, eid, t))
    return bad, scanned


def canon_entries():
    """(파일 상대경로, 항목 id, 검사 대상 값) 목록과 정본 id 집합."""
    ids, out = set(), []
    for p in sorted(glob.glob(str(ROOT / "spec" / "**" / "*.json"), recursive=True)):
        try:
            doc = json.load(io.open(p, encoding="utf-8"))
        except (ValueError, OSError):
            continue
        if not isinstance(doc, dict) or not isinstance(doc.get("entries"), list):
            continue
        rel = pathlib.Path(p).relative_to(ROOT)
        for e in doc["entries"]:
            if not isinstance(e, dict) or not isinstance(e.get("id"), str):
                continue
            ids.add(e["id"])
            out.append((rel, e["id"], {"value": e.get("value"), "evidence": e.get("evidence")}))
    return ids, out


def selftest() -> None:
    """음성 대조 — 잡아야 할 것과 통과시켜야 할 것을 매 실행 확인한다.

    실패하면 본 검사를 **아예 돌리지 않는다**. 검사기가 뚫린 채 초록을 내는 것이
    이 리포가 반복해서 당한 사고이기 때문이다."""
    ids = {"format.mdl.parseCoverage", "format.mdl.header", "engine.particle.flagBitMeaning"}
    cases = [
        # (설명, 값, 잡혀야 하는 토큰들)
        ("있는 항목을 가리킨다", {"a": "상세는 format.mdl.header 참조"}, []),
        ("없는 항목을 가리킨다", {"a": "상세는 format.mdl.mdlaTrackFraming 참조"},
         ["format.mdl.mdlaTrackFraming"]),
        ("항목 + 그 안의 키", {"a": "(engine.particle.flagBitMeaning.notVerified)"}, []),
        ("네임스페이스가 없는 산문은 참조가 아니다",
         {"a": "lib.es2015.core.d.ts · ec601.0.299 · dshow.lav.vmr9"}, []),
        ("evidence 안도 본다", {"evidence": [{"ref": "format.mdl.noSuchThing"}]},
         ["format.mdl.noSuchThing"]),
        ("키 이름도 본다", {"format.mdl.alsoMissing": 1}, ["format.mdl.alsoMissing"]),
    ]
    for why, value, want in cases:
        bad, _ = unresolved(ids, [(pathlib.Path("t.json"), "t.x", value)])
        got = [t for _, _, t in bad]
        if got != want:
            print(f"selftest 실패({why}): {got!r} != {want!r}", file=sys.stderr)
            raise SystemExit(2)
    # 같은 토큰이 한 항목에 여러 번 나와도 한 번만 센다(보고가 시끄러워지지 않게).
    bad, scanned = unresolved(ids, [(pathlib.Path("t.json"), "t.x",
                                     {"a": "format.mdl.header format.mdl.header"})])
    if bad or scanned != 1:
        print(f"selftest 실패(중복 토큰): bad={bad!r} scanned={scanned}", file=sys.stderr)
        raise SystemExit(2)
    print("selftest: OK")


def main() -> int:
    selftest()
    ids, entries = canon_entries()
    if not entries:
        print("[canon-entry-refs] 정본 항목을 하나도 못 찾았다 — 경로가 어긋났다", file=sys.stderr)
        return 1
    bad, scanned = unresolved(ids, entries)

    if bad:
        print(f"[canon-entry-refs] 정본이 **없는 항목**을 가리킨다 {len(bad)}건 — "
              f"읽는 사람이 찾으러 갔다가 못 찾는다", file=sys.stderr)
        for path, eid, tok in bad:
            print(f"  {path} :: {eid}", file=sys.stderr)
            print(f"      가리키는 id: {tok}", file=sys.stderr)
        print("  → 생성기(scripts/spec/measure_*.py)가 그 항목을 만들고 있으면 정본이 낡은 것이다."
              " 손으로 채우되 **생성기 리터럴과 값이 일치해야** 형제 게이트가 통과한다.",
              file=sys.stderr)
        print("  → 참조 쪽이 낡았으면 그 문장을 고쳐라. 지우지 말고 툼스톤으로 남겨라.",
              file=sys.stderr)
        return 1

    if scanned < MIN_SCANNED:
        print(f"[canon-entry-refs] 훑은 참조 {scanned}건 — 하한 {MIN_SCANNED} 미만. "
              f"추출 패턴이 더 이상 안 맞는다(그물이 조용히 작아졌다).", file=sys.stderr)
        return 1

    ns = collections.Counter(".".join(i.split(".")[:2]) for i in ids)
    print(f"[canon-entry-refs] 정본 항목 {len(ids)}개 · 네임스페이스 {len(ns)}개 · "
          f"항목 간 참조 {scanned}건 · 끊긴 참조 0건")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
