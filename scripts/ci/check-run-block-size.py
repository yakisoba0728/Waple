#!/usr/bin/env python3
"""워크플로 `run:` 블록이 GitHub Actions 의 템플릿 길이 한도를 넘지 않는지 본다.

**왜 이게 있나 — 실제로 당했다.**

`.github/workflows/ci.yml` 의 `Skip / execution census` 스텝이 커지다가 한도를 넘겼고,
그 결과 워크플로가 **파싱 자체에 실패**했다. 증상이 고약하다:

  · 실행은 `conclusion: failure` 로 뜬다 — 그런데 **잡이 0개**라 로그가 없다.
  · `rerun` 은 `403 This workflow run cannot be retried` 로 거절된다(재시도할 잡이 없다).
  · 다른 워크플로(`spec.yml`, ubuntu)는 멀쩡히 초록이라 신호가 가려진다.
  · API 로 `run_workflow` 를 직접 때려야 비로소 진짜 사유가 보인다:
      `failed to parse workflow: (Line: 338, Col: 14): Exceeded max expression length 21000`

그래서 **macOS 레인 전체가 조용히 꺼진 채 커밋 셋이 지나갔다**(런 #355·#356·#357).

**함정의 핵심은 단위다.** 한도는 문자가 아니라 **바이트**다. 문제의 블록은 문자로는
16,830 이라 한도 안처럼 보였지만, 이 리포의 주석이 한국어라 UTF-8 3바이트씩 먹어
실제로는 **24,117바이트**였다. 그중 87%(21,164B / 232줄)가 주석이었다 — 즉 **근거를
성실히 적은 것이 게이트를 껐다.** 근거를 줄이는 게 답이 아니라 자리를 옮기는 게 답이다:
YAML 주석(`run:` 스칼라 **밖**)은 템플릿에 안 들어가므로 한도와 무관하다.

한도 21,000 은 GitHub 이 정한 값이라 우리가 못 바꾼다. 여기서는 **16,000 을 경보선**으로
둔다 — 남은 5,000바이트는 한국어 주석 기준 약 55줄이고, 그 정도 여유가 있어야 "한 줄
더 적었더니 CI 가 통째로 꺼졌다" 가 안 난다.

사용:
    python3 scripts/ci/check-run-block-size.py            # 리포의 워크플로 전부
    python3 scripts/ci/check-run-block-size.py --selftest # 검출력 자체를 검사
"""
from __future__ import annotations

import pathlib
import re
import sys

# GitHub 이 정한 하드 한도(바이트). 우리가 못 바꾼다.
HARD_LIMIT = 21_000
# 경보선. 한도까지 남은 여유가 이보다 적어지면 미리 잡는다.
WARN_LIMIT = 16_000

# `run:` 은 두 가지로 쓴다 — 자기 줄(`        run: |`)과 대시와 같은 줄(`      - run: |`).
# 후자를 빼먹으면 게이트가 조용히 절반만 본다(셀프테스트 ①③ 이 실제로 그 상태를 잡았다).
# 들여쓰기 기준은 **대시 열**이라야 다음 스텝에서 정확히 끊긴다.
RUN_RE = re.compile(r"^(\s*)(?:-\s+)?run:\s*[|>]")


def run_blocks(text: str):
    """(시작줄 1-based, 본문 바이트 수) 목록. 블록 스칼라 `run: |` 만 본다."""
    lines = text.split("\n")
    out = []
    for i, line in enumerate(lines):
        m = RUN_RE.match(line)
        if not m:
            continue
        indent = len(m.group(1))
        j, body = i + 1, []
        while j < len(lines):
            cur = lines[j]
            if cur.strip() and len(cur) - len(cur.lstrip()) <= indent:
                break
            body.append(cur)
            j += 1
        out.append((i + 1, len("\n".join(body).encode("utf-8"))))
    return out


def check(paths) -> int:
    worst = 0
    bad = []
    for p in paths:
        text = p.read_text(encoding="utf-8")
        for line_no, size in run_blocks(text):
            worst = max(worst, size)
            if size > WARN_LIMIT:
                bad.append((p, line_no, size))
    for p, line_no, size in bad:
        over = "한도 초과 — 워크플로가 파싱되지 않는다" if size > HARD_LIMIT else "경보선 초과"
        print(f"::error::{p}:{line_no} `run:` 블록 {size:,}바이트 — {over}")
        print(f"  → 주석을 `run:` **밖**(스텝 위 YAML 주석)으로 옮겨라. 지우지 말고 옮겨라.")
    print(f"[run-block-size] 최대 {worst:,}B / 경보선 {WARN_LIMIT:,}B / 하드 한도 {HARD_LIMIT:,}B"
          f" — {'위반 없음' if not bad else f'위반 {len(bad)}건'}")
    return 1 if bad else 0


def selftest() -> int:
    """검출력 자체를 본다 — 게이트가 통과하는 이유가 '아무것도 안 봐서' 면 안 된다."""
    ok = True

    # ① 한도를 넘는 블록을 실제로 잡는가 (한국어 = 3바이트라 문자 수로는 못 잡는다)
    padding = "\n".join("          # " + "근거" * 20 for _ in range(300))
    over = f"jobs:\n  a:\n    steps:\n      - run: |\n{padding}\n"
    hits = [s for _, s in run_blocks(over) if s > HARD_LIMIT]
    if not hits:
        print("::error::selftest ① 실패 — 한도 초과 블록을 못 잡는다")
        ok = False
    elif len(padding) <= HARD_LIMIT:
        # 이 표본이 '문자로는 안 넘고 바이트로만 넘는' 진짜 함정인지 확인
        print(f"  selftest ①: 문자 {len(padding):,} ≤ 한도 < 바이트 {hits[0]:,} — 단위 함정 재현")

    # ② 짧은 블록을 오탐하지 않는가
    small = "jobs:\n  a:\n    steps:\n      - run: |\n          echo hi\n"
    if any(s > WARN_LIMIT for _, s in run_blocks(small)):
        print("::error::selftest ② 실패 — 짧은 블록을 오탐한다")
        ok = False

    # ③ 블록 경계를 지키는가 — 뒤따르는 다른 스텝을 삼키면 안 된다
    two = ("jobs:\n  a:\n    steps:\n      - run: |\n          echo one\n"
           "      - name: next\n        run: |\n          echo two\n")
    if len(run_blocks(two)) != 2:
        print(f"::error::selftest ③ 실패 — 블록을 {len(run_blocks(two))}개로 셌다(2 여야 한다)")
        ok = False

    print("selftest: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    root = pathlib.Path(__file__).resolve().parents[2]
    paths = sorted((root / ".github" / "workflows").glob("*.yml"))
    if not paths:
        print("::error::워크플로 파일을 못 찾았다 — 게이트가 아무것도 안 보고 통과할 뻔했다")
        return 1
    return selftest() or check(paths)


if __name__ == "__main__":
    raise SystemExit(main())
