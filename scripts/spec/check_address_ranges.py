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
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCAN_DIRS = ("Sources", "Tests")

# `0x48f3c0–0x48f4b8`(엔대시) · `0x48f3c0-0x48f4b8`(하이픈) · `0x1401bef00..0x1401bf2c6`(닷닷)
RANGE = re.compile(r"(0x[0-9a-fA-F]{5,9})\s*(?:–|-|\.\.)\s*(0x[0-9a-fA-F]{5,9})")


def violations(text: str):
    """(시작, 끝, 줄번호, 줄) 중 시작 >= 끝 인 것."""
    out = []
    for lineno, line in enumerate(text.splitlines(), 1):
        for m in RANGE.finditer(line):
            lo, hi = int(m.group(1), 16), int(m.group(2), 16)
            if lo >= hi:
                out.append((m.group(1), m.group(2), lineno, line.strip()))
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
    ]
    for src in must_catch:
        if not violations(src):
            print(f"selftest 실패: 잡아야 할 것을 놓쳤다 — {src!r}", file=sys.stderr)
            raise SystemExit(2)
    for src in must_pass:
        if violations(src):
            print(f"selftest 실패: 거짓 양성 — {src!r}", file=sys.stderr)
            raise SystemExit(2)
    print("selftest: OK")


def main() -> int:
    selftest()
    bad = []
    scanned = 0
    ranges = 0
    for d in SCAN_DIRS:
        for p in sorted((ROOT / d).rglob("*.swift")):
            text = p.read_text(encoding="utf-8")
            scanned += 1
            ranges += len(RANGE.findall(text))
            for lo, hi, lineno, line in violations(text):
                bad.append((p.relative_to(ROOT), lineno, lo, hi, line))
    if bad:
        print(f"[address-ranges] 성립 불가능한 범위 인용 {len(bad)}건", file=sys.stderr)
        for rel, lineno, lo, hi, line in bad:
            fixed = int(hi, 16) + 0x1200
            print(f"  {rel}:{lineno}", file=sys.stderr)
            print(f"      {lo}–{hi}  ← 시작 > 끝. 끝이 파일 오프셋이면 RVA 는 {fixed:#x}.",
                  file=sys.stderr)
            print(f"      | {line[:120]}", file=sys.stderr)
        return 1
    print(f"[address-ranges] .swift {scanned}파일 · 범위 인용 {ranges}건 · 위반 0건")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
