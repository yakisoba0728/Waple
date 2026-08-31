#!/usr/bin/env python3
"""Print the sum of top-level XCTest bundle summaries in a test log.

Swift toolchains disagree on whether `swift test` launches one aggregate xctest
bundle or several target bundles.  Both shapes contain a final summary for each
top-level `*.xctest` suite; class and `All tests` summaries are deliberately not
counted.
"""
from __future__ import annotations

import pathlib
import re
import sys


BUNDLE = re.compile(r"^Test Suite '([^']+\.xctest)' (?:passed|failed) at ")
EXECUTED = re.compile(r"^\s*Executed (\d+) tests?(?:,|$)")


def bundle_counts(text: str) -> list[tuple[str, int]]:
    counts: list[tuple[str, int]] = []
    pending: str | None = None
    for line in text.splitlines():
        bundle = BUNDLE.match(line)
        if bundle:
            pending = bundle.group(1)
            continue
        if line.startswith("Test Suite '"):
            pending = None
            continue
        if pending is None:
            continue
        executed = EXECUTED.match(line)
        if executed:
            counts.append((pending, int(executed.group(1))))
            pending = None
    return counts


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} TEST-OUTPUT.log|-", file=sys.stderr)
        return 2
    try:
        text = (sys.stdin.read() if argv[1] == "-" else
                pathlib.Path(argv[1]).read_text(encoding="utf-8", errors="replace"))
    except OSError as error:
        print(f"[xctest-census] 로그를 읽지 못했다: {error}", file=sys.stderr)
        return 2
    counts = bundle_counts(text)
    if not counts:
        print("[xctest-census] `*.xctest` 번들 완료 요약을 하나도 찾지 못했다", file=sys.stderr)
        return 1
    print(sum(count for _, count in counts))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
