#!/usr/bin/env python3
"""Require completed successful CI and spec runs for an exact release SHA.

The workflow downloads the Actions API response.  Keeping the decision here
makes the fail-closed policy unit-testable without contacting GitHub.
"""
from __future__ import annotations

import json
import pathlib
import sys


REQUIRED = {
    ".github/workflows/ci.yml": "CI",
    ".github/workflows/spec.yml": "spec",
}


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} COMMIT_SHA RUNS.json|-", file=sys.stderr)
        return 2
    sha, source = argv[1], argv[2]
    try:
        raw = sys.stdin.read() if source == "-" else pathlib.Path(source).read_text(encoding="utf-8")
        document = json.loads(raw)
    except (OSError, json.JSONDecodeError) as error:
        print(f"[release-ci] Actions 응답을 읽지 못했다: {error}", file=sys.stderr)
        return 2

    runs = document.get("workflow_runs", []) if isinstance(document, dict) else []
    waiting, failed, passed = [], [], []
    for path, label in REQUIRED.items():
        candidates = [run for run in runs
                      if isinstance(run, dict)
                      and run.get("path") == path
                      and run.get("head_sha") == sha]
        if not candidates:
            waiting.append(f"{label}=missing")
            continue
        # A rerun supersedes the older attempt (`run_attempt` grows while id stays fixed).
        # This lets a successful rerun repair a failure, while a fresh tag-triggered queued run
        # (newer id) cannot be bypassed by an older green run.
        latest = max(candidates, key=lambda value: (
            int(value.get("id") or 0), int(value.get("run_attempt") or 1)
        ))
        status, conclusion = latest.get("status"), latest.get("conclusion")
        detail = f"{label} run {latest.get('id')}={status}/{conclusion}"
        if status != "completed":
            waiting.append(detail)
        elif conclusion != "success":
            failed.append(detail)
        else:
            passed.append(detail)

    if failed:
        print(f"[release-ci] {sha[:12]} 릴리스 거부 — " + ", ".join(failed), file=sys.stderr)
        return 1
    if waiting:
        print(f"[release-ci] {sha[:12]} 검증 대기 — " + ", ".join(waiting), file=sys.stderr)
        return 2
    print(f"[release-ci] {sha[:12]} 검증 성공 — " + ", ".join(passed))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
