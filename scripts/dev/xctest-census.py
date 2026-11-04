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
ROOT = pathlib.Path(__file__).resolve().parents[2]


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


def check_complete(text: str, counts: list[tuple[str, int]], root: pathlib.Path) -> bool:
    """물리 번들 수 대신 CI 하한과 타깃의 실제 실행으로 완주를 확인한다."""
    ci = (root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    floor = re.search(r'"\$\{EXECUTED:-0\}"\s*-lt\s+(\d+)', ci)
    manifest = (root / "Package.swift").read_text(encoding="utf-8")
    targets = set(re.findall(r'\.testTarget\(\s*name:\s*"([A-Za-z0-9_]+)"', manifest))
    ran = set(re.findall(r"Test Case '-\[([A-Za-z0-9_]+)\.\w+ \w+\]' (?:passed|failed)", text))
    ran |= set(re.findall(r"Test Case '([A-Za-z0-9_]+)\.\w+\.\w+' (?:passed|failed)", text))
    failures = re.findall(r"^\s*Executed \d+ tests?, with (?:\d+ tests? skipped and )?([1-9]\d*) failures?", text, re.M)
    if (not floor or not targets or targets - ran or failures
            or sum(count for _, count in counts) < int(floor.group(1))):
        print(f"[xctest-census] 완주 검증 실패 — 실행 하한 {floor.group(1) if floor else '없음'}, "
              f"미실행 타깃 {sorted(targets - ran)}, 실패 요약 {len(failures)}개", file=sys.stderr)
        return False
    return True


def main(argv: list[str]) -> int:
    check = len(argv) > 1 and argv[1] == "--check"
    args = argv[2:] if check else argv[1:]
    if len(args) != 1:
        print(f"usage: {argv[0]} [--check] TEST-OUTPUT.log|-", file=sys.stderr)
        return 2
    try:
        text = (sys.stdin.read() if args[0] == "-" else
                pathlib.Path(args[0]).read_text(encoding="utf-8", errors="replace"))
    except OSError as error:
        print(f"[xctest-census] 로그를 읽지 못했다: {error}", file=sys.stderr)
        return 2
    counts = bundle_counts(text)
    if not counts:
        print("[xctest-census] `*.xctest` 번들 완료 요약을 하나도 찾지 못했다", file=sys.stderr)
        return 1
    if check:
        try:
            if not check_complete(text, counts, ROOT):
                return 1
        except OSError as error:
            print(f"[xctest-census] 검증 기준을 읽지 못했다: {error}", file=sys.stderr)
            return 2
    print(sum(count for _, count in counts))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
