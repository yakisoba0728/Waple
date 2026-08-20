#!/usr/bin/env python3
"""CI 상태를 **한 화면**으로 본다.

왜 있는가
---------
GitHub MCP 의 `actions_list` 는 워크플로 실행 하나마다 리포지터리 객체 전체를 실어
보내서 응답이 400 KB 를 넘는다(실측). 필요한 건 (SHA, 워크플로, 결론) 세 컬럼인데
매번 파일로 떨어뜨려 파싱해야 했다. REST 를 직접 치고 필요한 것만 찍는다.

사용
----
  scripts/dev/ci-status.py                  현재 브랜치 최근 실행
  scripts/dev/ci-status.py --branch X       특정 브랜치
  scripts/dev/ci-status.py --jobs           실패(없으면 최신) 실행의 잡 + 실패 스텝
  scripts/dev/ci-status.py --watch          완료될 때까지 폴링(기본 30초 간격)
  scripts/dev/ci-status.py --log JOB_ID     그 잡 로그에서 실패 신호 줄만

인증은 `GITHUB_TOKEN`/`GH_TOKEN` 환경변수. 없으면 2번으로 종료한다.

종료 코드: 0 = 최신 SHA 전건 성공 · 1 = 하나라도 실패 · 2 = 진행 중.
그래서 `until python3 scripts/dev/ci-status.py; do ...; done` 로 대기에 쓸 수 있다.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"
MARK = {"success": "OK ", "failure": "FAIL", "cancelled": "CANC", "skipped": "SKIP",
        "timed_out": "TIME", "startup_failure": "BOOM", None: "... "}


def token():
    t = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not t:
        print("GITHUB_TOKEN/GH_TOKEN 이 없다", file=sys.stderr)
        raise SystemExit(2)
    return t


class _StripAuthOnRedirect(urllib.request.HTTPRedirectHandler):
    """리다이렉트에서 Authorization 헤더를 뗀다.

    잡 로그 엔드포인트는 302 로 Azure Blob 에 넘긴다. urllib 기본 동작은 원 요청 헤더를
    그대로 들고 따라가는데, Azure 는 GitHub 토큰이 붙은 요청을 401
    `InvalidAuthenticationInfo` 로 거절한다. 서명이 이미 URL 쿼리에 들어 있으므로
    헤더는 떼는 게 맞다."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            for h in ("Authorization", "authorization"):
                new.headers.pop(h, None)
                new.unredirected_hdrs.pop(h, None)
        return new


_OPENER = urllib.request.build_opener(_StripAuthOnRedirect)


def api(path, raw=False):
    req = urllib.request.Request(
        API + "/" + path,
        headers={"Authorization": "Bearer " + token(),
                 "Accept": "application/vnd.github+json",
                 "User-Agent": "waple-ci-status"})
    try:
        with _OPENER.open(req, timeout=60) as r:
            body = r.read()
    except urllib.error.HTTPError as e:
        detail = e.read()[:200].decode("utf-8", "replace")
        print("HTTP %d: %s" % (e.code, detail), file=sys.stderr)
        raise SystemExit(1)
    return body if raw else json.loads(body)


def current_branch():
    try:
        out = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"],
                             capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except Exception:
        return "main"


def show_runs(repo, branch, limit):
    d = api("repos/%s/actions/runs?branch=%s&per_page=%d" % (repo, branch, limit))
    runs = d.get("workflow_runs", [])
    print("== %s @ %s ==" % (repo, branch))
    if not runs:
        print("  (실행 없음)")
    for r in runs:
        c = r.get("conclusion")
        mark = "... " if r["status"] != "completed" else MARK.get(c, "?   ")
        state = c or r["status"]
        print("[%s] %s  %-5s %-12s run=%s  %sZ"
              % (mark, r["head_sha"][:7], r["name"], state, r["id"], r["created_at"][11:19]))
    return runs


TEST_SUMMARY = re.compile(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?")


def test_tally(repo, job_id):
    """잡 로그의 마지막 `Executed N tests, ... M failures` 요약.

    왜 필요한가: release 레인은 `continue-on-error` 라 **테스트가 실패해도 잡 결론이
    success** 다(의도된 보고 전용 — debug 가 차단 게이트다). 잡 결론만 보면 그 실패가
    보이지 않아, "release 는 통과했는데 debug 만 빨갛다" 는 잘못된 그림이 나온다.
    실제로 그렇게 두 번 오독했다."""
    try:
        text = api("repos/%s/actions/jobs/%s/logs" % (repo, job_id), raw=True).decode("utf-8", "replace")
    except SystemExit:
        return None
    last = None
    for m in TEST_SUMMARY.finditer(text):
        last = m
    if not last:
        return None
    return (int(last.group(1)), int(last.group(2) or 0), int(last.group(3)))


def show_jobs(repo, run_id, tests=False):
    d = api("repos/%s/actions/runs/%s/jobs?per_page=30" % (repo, run_id))
    print("\n== run %s ==" % run_id)
    for j in d.get("jobs", []):
        c = j.get("conclusion") or j["status"]
        line = "  [%s] %s   job=%s" % (MARK.get(c, c), j["name"], j["id"])
        if tests and j["status"] == "completed":
            t = test_tally(repo, j["id"])
            if t:
                executed, skipped, failures = t
                note = "실행 %d · 스킵 %d · 실패 %d" % (executed, skipped, failures)
                if failures and c == "success":
                    note += "  ← 잡은 success 인데 테스트는 실패(continue-on-error)"
                line += "\n       %s" % note
        print(line)
        for s in j.get("steps", []):
            sc = s.get("conclusion") or s["status"]
            if sc not in ("success", "skipped"):
                print("       -> %s: %s" % (sc, s["name"]))


def show_log(repo, job_id, keep):
    """잡 로그에서 실패 신호만 — 전문은 수 MB 라 컨텍스트를 먹는다."""
    text = api("repos/%s/actions/jobs/%s/logs" % (repo, job_id), raw=True).decode("utf-8", "replace")
    needles = ("error:", "failed", "FAILED", "XCTAssert", "TEST FAILED",
               "Executed ", "위반", "실패", "Traceback", "executed=")
    # 워크플로 **소스**가 그대로 에코되는 줄(`[36;1m` = 명령 에코)은 뺀다 — 스크립트 본문에
    # "실패"·"Executed" 같은 단어가 들어 있어서, 안 빼면 발췌가 자기 소스로 가득 찬다.
    lines = [l for l in text.splitlines()
             if any(n in l for n in needles) and "[36;1m" not in l]
    print("\n== job %s 로그 발췌 (%d줄 중 마지막 %d) ==" % (job_id, len(lines), keep))
    for l in lines[-keep:]:
        print("  " + l[:700])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=os.environ.get("WAPLE_CI_REPO", "yakisoba0728/Waple"))
    ap.add_argument("--branch", default=None)
    ap.add_argument("--limit", type=int, default=8)
    ap.add_argument("--jobs", action="store_true", help="실패(없으면 최신) 실행의 잡/실패 스텝")
    ap.add_argument("--tests", action="store_true",
                    help="--jobs 에 잡별 테스트 집계를 붙인다(release 의 숨은 실패를 드러낸다)")
    ap.add_argument("--log", type=int, default=None, metavar="JOB_ID")
    ap.add_argument("--keep", type=int, default=40, help="--log 가 남길 줄 수")
    ap.add_argument("--watch", action="store_true", help="완료까지 폴링")
    ap.add_argument("--interval", type=int, default=30)
    ap.add_argument("--timeout", type=int, default=1800)
    a = ap.parse_args()
    branch = a.branch or current_branch()

    if a.log is not None:
        show_log(a.repo, a.log, a.keep)
        return 0

    deadline = time.time() + a.timeout
    runs = []
    while True:
        runs = show_runs(a.repo, branch, a.limit)
        head = runs[0]["head_sha"] if runs else None
        pending = [r for r in runs if r["head_sha"] == head and r["status"] != "completed"]
        if not a.watch or not pending or time.time() > deadline:
            break
        print("  ... %d개 진행 중, %ds 후 재확인" % (len(pending), a.interval), flush=True)
        time.sleep(a.interval)

    if (a.jobs or a.tests) and runs:
        failed = next((r for r in runs if r.get("conclusion") == "failure"), runs[0])
        show_jobs(a.repo, failed["id"], tests=a.tests)

    if not runs:
        return 0
    head = runs[0]["head_sha"]
    same = [r for r in runs if r["head_sha"] == head]
    if any(r["status"] != "completed" for r in same):
        return 2
    return 0 if all(r.get("conclusion") == "success" for r in same) else 1


if __name__ == "__main__":
    raise SystemExit(main())
