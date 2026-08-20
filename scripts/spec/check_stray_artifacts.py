#!/usr/bin/env python3
"""편집 잔재가 리포에 커밋되는 것을 막는다.

## 왜 있나

2026-08-20, 커밋 `2fe8683` 이 **`Sources/WapleCore/ParticleSystem.swift.orig`(91KB)** 를
같이 밀어 넣었다. 파일 편집을 파이썬/patch 로 하다 남은 백업인데, 커밋 흐름이
`git add -A` 라서 그대로 쓸려 들어갔다. 컴파일도 테스트도 안 건드리는 파일이라 CI 가
초록인 채로 며칠 남을 수 있다 — 실제로 아무도 못 봤다.

`.gitignore` 로 막을 수도 있지만 그건 **조용히 숨기는** 쪽이다. 이미 커밋된 것을 못 잡고,
"왜 안 보이지" 로 시간을 쓴다. 여기서는 **시끄럽게 실패**시킨다.

## 무엇을 잡나

추적 중인 파일 이름이 편집 잔재 패턴에 걸리면 실패한다:
  `*.orig` `*.rej` `*.bak` `*.tmp` `*.swp` `*.swo` `*~` `.DS_Store` `Thumbs.db`
  `*.pyc` `__pycache__/` `*.log`

의도적으로 커밋해야 하는 것이 생기면 `ALLOWED` 에 사유와 함께 등록하라 — 패턴을 넓히지 마라.
"""
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

PATTERNS = [
    (r"\.orig$", "patch/편집 백업"),
    (r"\.rej$", "patch 거절 조각"),
    (r"\.bak$", "백업"),
    (r"\.tmp$", "임시"),
    (r"\.sw[op]$", "vim 스왑"),
    (r"~$", "편집기 백업"),
    (r"(^|/)\.DS_Store$", "macOS 파인더 잔재"),
    (r"(^|/)Thumbs\.db$", "Windows 탐색기 잔재"),
    (r"\.pyc$", "파이썬 바이트코드"),
    (r"(^|/)__pycache__/", "파이썬 캐시"),
    (r"\.log$", "로그"),
]

# 의도적으로 추적하는 예외. (경로, 사유)
ALLOWED = {
    # 골든 기준선의 캡처 산출물. 확장자가 `.log` 지만 로그가 아니라 **기준선의 일부**이고
    # `GoldenBaselineOracleTests` 가 읽는다. 지우면 그 게이트가 근거를 잃는다.
    "spec/golden/snapshot/baseline-81098bb/sentinel.log",
}


def tracked_files():
    out = subprocess.run(["git", "-C", REPO, "ls-files", "-z"],
                         capture_output=True, text=True, check=True).stdout
    return [p for p in out.split("\0") if p]


def selftest():
    """패턴이 실제로 무엇을 잡는지 — 못 잡으면 이 검사는 무의미하다."""
    bad = []
    must_catch = ["Sources/WapleCore/ParticleSystem.swift.orig", "a/b.rej", "x.bak",
                  "notes.txt~", "scripts/__pycache__/x.cpython-311.pyc",
                  "Sources/.DS_Store", "build.log", ".vimrc.swp"]
    must_pass = ["Sources/WapleCore/ParticleSystem.swift", "docs/README.md",
                 "scripts/spec/validate.py", "spec/assets/manifest.json",
                 "Tests/WapleCoreTests/OriginalTests.swift",   # "orig" 를 포함하지만 잔재가 아니다
                 "docs/history/roadmap-h1-h8-closeout-2026-07-26.md"]
    for p in must_catch:
        if not any(re.search(rx, p) for rx, _ in PATTERNS):
            bad.append(f"selftest: 잡아야 하는데 통과 — {p}")
    for p in must_pass:
        hit = [why for rx, why in PATTERNS if re.search(rx, p)]
        if hit:
            bad.append(f"selftest: 통과해야 하는데 잡힘 — {p} ({hit})")
    return bad


def main():
    fails = selftest()
    if fails:
        for f in fails:
            print("  X " + f)
        print("[stray-artifacts] 패턴 자체가 틀렸다 — 검사를 신뢰할 수 없으므로 중단한다")
        return 1
    print("  . selftest 14건 통과")

    hits = []
    for path in tracked_files():
        if path in ALLOWED:
            continue
        for rx, why in PATTERNS:
            if re.search(rx, path):
                hits.append((path, why))
                break

    if hits:
        print(f"\n[stray-artifacts] 편집 잔재 {len(hits)}건이 추적되고 있다")
        for path, why in hits:
            print(f"  X {path}  ({why})")
        print("\n  `git rm --cached <경로>` 로 빼라. 의도적이면 ALLOWED 에 사유와 함께 등록하라.")
        print("  커밋 흐름이 `git add -A` 라면 특히 조심할 것 — 이 검사가 생긴 이유가 그것이다.")
        return 1
    print("[stray-artifacts] 통과")
    return 0


if __name__ == "__main__":
    sys.exit(main())
