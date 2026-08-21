#!/usr/bin/env python3
"""주석 속 **주소 범위 인용**이 성립하는지 본다 — 시작 < 끝.

왜 있는가
---------
`.rdata` 는 rva `0x426000` / rawptr `0x424e00` 이라 **파일 오프셋 + 0x1200 = RVA** 인데,
이 리포의 주석은 두 규약을 **똑같은 `@0x48XXXX` 표기**로 섞어 썼다. 커밋 `0c54f3b` 이
`scripts/dev/check-rdata-citations.py` 로 32건을 잡아 일괄 정정했다.

**그 일괄 정정이 범위의 시작만 고치고 끝을 남겼다.** 검사기가 단일 주소만 보게 돼 있어서,
`@0x48e1c0–0x48e2b8` 이 `@0x48f3c0–0x48e2b8` 이 되었다 — 시작은 RVA, 끝은 여전히 파일
오프셋이라 **시작 > 끝** 인 성립 불가능한 범위다. 8건이 그렇게 남았고, 어느 검사도 안 잡았다.

이 게이트는 그 부류만 본다. 판정이 **순수 산술**이라 WE 바이너리가 필요 없고, 그래서
리눅스 spec 레인에서 매 푸시 돈다 — 형제 `check-rdata-citations.py` 는 바이너리를 요구해
CI 게이트가 될 수 없다는 점이 이 파일이 따로 있는 이유다.

무엇을 못 잡는지도 분명히 해 둔다: **양쪽 다 파일 오프셋인 범위**는 시작 < 끝 이 성립하므로
여기서 안 걸린다. 그건 바이너리를 읽어야 알 수 있고 `check-rdata-citations.py` 의 몫이다.
이 검사는 "일괄 치환이 범위의 한쪽만 건드렸다" 는 **기계적 사고**를 잡는 그물이다.

**[2026-08-21] 그물을 `Sources`/`Tests` 밖으로 넓혔다.**
종전엔 `.swift` 만 훑었다. 그런데 같은 사고가 나는 자리는 코드보다 **문서와 정본이 더 많다** —
`docs/**/*.md` 379건 · `spec/**/*.json` 73건 · `scripts/**/*.py` 58건의 범위 인용이 어느
게이트에도 안 잡히고 있었다(코드 쪽 551건보다 적지만 같은 크기다). 일괄 치환은 파일 종류를
가리지 않으므로 이 그물도 가리면 안 된다. 실제로 이 확장을 하면서 `docs/dev/re-methodology.md`
의 인용 VA 15개가 **어떤 게이트에도 안 걸리는 상태**였다는 것을 확인했다.

**뺄셈식과 범위를 이 정규식은 구별하지 못한다.** `(0x14016b0d4-0x140169140)` 같은 길이 계산은
"큰 값이 앞" 이라 위반으로 보인다. 그런 줄은 `SUBTRACTION_ALLOWED_LINES` 에 **줄 문면**으로
면제한다 — 줄 번호로 걸면 무관한 편집이 막히고 조용히 낡는다(이 리포가 `check_spec_shrink_guard.py`
에서 실제로 당했고 `94045ac` 에서 전문 일치로 바꿨다). 면제가 실제로 쓰이는지도 매 실행 확인한다:
쓰이지 않는 면제는 그물에 난 구멍이 아니라 **낡은 흉터**이므로 실패로 처리한다.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

# (디렉터리, 훑을 확장자). `.swift` 밖으로 넓힌 이유는 머리말 참조.
SCAN = (
    ("Sources", (".swift",)),
    ("Tests", (".swift",)),
    ("docs", (".md",)),
    ("spec", (".json",)),
    ("scripts", (".py", ".sh")),
)

# 이 파일 자신은 건너뛴다 — selftest 픽스처가 **일부러** 성립 불가능한 범위를 담고 있다.
SELF = pathlib.Path(__file__).resolve()

# 범위가 아니라 **뺄셈식**인 줄. 키는 `line.strip()` 의 전문 일치다(줄 번호 금지).
SUBTRACTION_ALLOWED_LINES = {
    "o = pe.va2off(0x140169140); code = DATA[o:o+(0x14016b0d4-0x140169140)]":
        "재현 스니펫의 길이 계산 — `끝 - 시작` 이라 큰 값이 앞에 온다(docs/re/scene-lighting.md)",
}

# 범위 인용 수의 하한. 그물이 조용히 작아지는 것(경로 오타·확장자 누락으로 0건 대조)을 막는다.
MIN_RANGES = 900

# `0x48f3c0–0x48f4b8`(엔대시) · `0x48f3c0-0x48f4b8`(하이픈) · `0x1401bef00..0x1401bf2c6`(닷닷)
RANGE = re.compile(r"(0x[0-9a-fA-F]{5,9})\s*(?:–|-|\.\.)\s*(0x[0-9a-fA-F]{5,9})")


def violations(text: str, used_exemptions=None):
    """(시작, 끝, 줄번호, 줄) 중 시작 >= 끝 인 것. 면제 줄은 뺀다."""
    out = []
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        for m in RANGE.finditer(line):
            lo, hi = int(m.group(1), 16), int(m.group(2), 16)
            if lo < hi:
                continue
            if stripped in SUBTRACTION_ALLOWED_LINES:
                if used_exemptions is not None:
                    used_exemptions.add(stripped)
                continue
            out.append((m.group(1), m.group(2), lineno, stripped))
    return out


def selftest() -> None:
    """음성 대조 — 잡아야 할 것과 통과시켜야 할 것을 매 실행 확인한다.

    실패하면 본 검사를 **아예 돌리지 않는다**. 그물이 뚫린 채 초록을 내는 것이
    이 리포가 반복해서 당한 사고이기 때문이다."""
    must_catch = [
        "// 스트링 @0x48f3c0–0x48e2b8 (일괄정정이 시작만 고친 모양)",
        "/// 범위 0x491fd0-0x490eb0 하이픈",
        "// 핸들러 0x1401bef00..0x1401bee00 닷닷",
        "// 같은 주소 0x48f3c0–0x48f3c0",           # 시작 == 끝도 범위가 아니다
    ]
    must_pass = [
        "// 스트링 @0x48f3c0–0x48f4b8 (정상)",
        "/// 핸들러 0x1401bef00..0x1401bf2c6 (정상)",
        "// 단일 주소 0x48f3c0 하나만",
        "// 주소가 아닌 뺄셈: count-1, 0x10-0x20 은 4자리라 대상 아님",
        "// 버전 범위 v0004-v0014 는 16진 리터럴이 아니다",
        # 면제 줄은 통과해야 한다(뺄셈식이지 범위가 아니다).
        "o = pe.va2off(0x140169140); code = DATA[o:o+(0x14016b0d4-0x140169140)]",
    ]
    for src in must_catch:
        if not violations(src):
            print(f"selftest 실패: 잡아야 할 것을 놓쳤다 — {src!r}", file=sys.stderr)
            raise SystemExit(2)
    for src in must_pass:
        if violations(src):
            print(f"selftest 실패: 거짓 양성 — {src!r}", file=sys.stderr)
            raise SystemExit(2)
    # 면제가 **정확히 그 문면에만** 걸리는지 — 앞뒤 공백은 무시하고 내용이 바뀌면 안 잡혀야 한다.
    for src in SUBTRACTION_ALLOWED_LINES:
        if violations("    " + src + "  "):
            print("selftest 실패: 면제가 들여쓰기 때문에 안 걸렸다", file=sys.stderr)
            raise SystemExit(2)
        mutated = src.replace("0x140169140", "0x140169150")
        if mutated != src and not violations(mutated):
            print(f"selftest 실패: 면제가 주소가 바뀐 줄까지 덮는다 — {mutated!r}", file=sys.stderr)
            raise SystemExit(2)
    print("selftest: OK")


def main() -> int:
    selftest()
    bad = []
    scanned = 0
    ranges = 0
    used = set()
    per_dir = {}
    for d, sufs in SCAN:
        root = ROOT / d
        if not root.exists():
            print(f"[address-ranges] 경로가 없다: {d} — 그물이 조용히 작아진다", file=sys.stderr)
            return 1
        n = 0
        for p in sorted(root.rglob("*")):
            if p.suffix not in sufs or not p.is_file():
                continue
            if p.resolve() == SELF:      # 자기 자신의 selftest 픽스처는 건너뛴다
                continue
            text = p.read_text(encoding="utf-8", errors="replace")
            scanned += 1
            k = len(RANGE.findall(text))
            ranges += k
            n += k
            for lo, hi, lineno, line in violations(text, used):
                bad.append((p.relative_to(ROOT), lineno, lo, hi, line))
        per_dir[d] = n
    if bad:
        print(f"[address-ranges] 성립 불가능한 범위 인용 {len(bad)}건", file=sys.stderr)
        for rel, lineno, lo, hi, line in bad:
            fixed = int(hi, 16) + 0x1200
            print(f"  {rel}:{lineno}", file=sys.stderr)
            print(f"      {lo}–{hi}  ← 시작 > 끝. 끝이 파일 오프셋이면 RVA 는 {fixed:#x}.",
                  file=sys.stderr)
            print(f"      | {line[:120]}", file=sys.stderr)
        return 1
    stale = set(SUBTRACTION_ALLOWED_LINES) - used
    if stale:
        print(f"[address-ranges] 쓰이지 않는 면제 {len(stale)}건 — 낡았다. 지워라.", file=sys.stderr)
        for src in sorted(stale):
            print(f"  | {src}", file=sys.stderr)
        return 1
    if ranges < MIN_RANGES:
        print(f"[address-ranges] 범위 인용 {ranges}건 — 하한 {MIN_RANGES} 미만. "
              f"경로/확장자가 어긋나 그물이 작아졌을 가능성이 높다.", file=sys.stderr)
        return 1
    detail = " · ".join(f"{d} {n}" for d, n in per_dir.items())
    print(f"[address-ranges] {scanned}파일 · 범위 인용 {ranges}건({detail}) · "
          f"면제 {len(used)}건 · 위반 0건")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
