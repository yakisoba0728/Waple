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
a_repo = [None]   # main() 이 채운다(종료 코드 판정이 repo 를 알아야 한다)
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


def head_sha():
    try:
        out = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except Exception:
        return None


def current_branch():
    try:
        out = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"],
                             capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except Exception:
        return "main"


# ci.yml 의 paths-ignore. 전 변경이 이 목록에 들면 macOS 잡이 **정상적으로** 안 돈다
# (spec.yml 은 paths-ignore 가 없어 항상 돈다). 이 목록과 실제 워크플로가 갈리면
# 아래 판정이 거짓이 되므로, ci.yml 을 고칠 때 여기도 같이 고칠 것.
DOCS_ONLY = (".md", "LICENSE", "NOTICE", ".gitignore", ".gitattributes")


def docs_only_commit(repo, sha):
    """이 커밋이 문서/무시 경로만 건드렸는가. 판정 불가면 None."""
    try:
        d = api("repos/%s/commits/%s" % (repo, sha))
    except SystemExit:
        return None
    files = [f["filename"] for f in d.get("files", [])]
    if not files:
        return None
    def ignored(f):
        return f.endswith(".md") or f.startswith("docs/") or f in DOCS_ONLY
    return all(ignored(f) for f in files)


def show_runs(repo, branch, limit):
    d = api("repos/%s/actions/runs?branch=%s&per_page=%d" % (repo, branch, limit))
    runs = d.get("workflow_runs", [])
    print("== %s @ %s ==" % (repo, branch))
    if not runs:
        print("  (실행 없음)")
        HIDDEN["no_runs"] = True
    seen_workflows = {}
    for r in runs:
        c = r.get("conclusion")
        mark = "... " if r["status"] != "completed" else MARK.get(c, "?   ")
        state = c or r["status"]
        print("[%s] %s  %-5s %-12s run=%s  %sZ"
              % (mark, r["head_sha"][:7], r["name"], state, r["id"], r["created_at"][11:19]))
        seen_workflows.setdefault(r["head_sha"], set()).add(r["name"])
    # **CI 가 없는 SHA 를 조용히 넘기지 않는다.** 문서 전용이라 paths-ignore 로 스킵된 것과
    # 트리거가 깨져 안 돈 것은 화면상 구분이 안 되는데, 후자는 "검증 0" 이라 치명적이다
    # (ci.yml 주석의 `branches: [main]` 사고가 정확히 그것이었다 — 8커밋을 검증 없이 푸시).
    for sha, names in seen_workflows.items():
        if "CI" in names:
            continue
        # **페이지 잘림에 속지 않는다.** 위 목록은 최근 N개일 뿐이라, 오래된 SHA 의 CI 실행이
        # 화면 밖에 있을 수 있다. 그 상태로 경고하면 늑대소년이 된다(실제로 첫 판에 오탐이 났다).
        # 그 SHA 로 한정해 한 번 더 물어 확인한 뒤에만 판정한다.
        try:
            byname = api("repos/%s/actions/runs?head_sha=%s&per_page=20" % (repo, sha))
            if any(r["name"] == "CI" for r in byname.get("workflow_runs", [])):
                continue
        except SystemExit:
            continue
        verdict = docs_only_commit(repo, sha)
        if verdict is True:
            print("     %s: CI 없음 — 문서 전용이라 paths-ignore 로 **정상 스킵**(spec 은 돌았다)" % sha[:7])
        elif verdict is False:
            print("     %s: ⚠ CI 없음인데 코드 변경이 있다 — 트리거를 확인할 것" % sha[:7])
            # 로컬 HEAD 에 대해서만 종료코드로 올린다. 창 안의 옛 SHA 까지 실패로 치면
            # 이미 지나간 이력 때문에 영영 붉어져 아무도 안 보게 된다.
            if sha == head_sha():
                HIDDEN["ci_missing_for_head"] = True
        else:
            print("     %s: CI 없음 — 사유 판정 불가(아직 큐잉 중일 수 있다)" % sha[:7])
    return runs


TEST_SUMMARY = re.compile(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?")
BUNDLE_SUMMARY = re.compile(r"Test Suite '([^']+\.xctest)' (?:passed|failed) at ")


def test_tally(repo, job_id):
    """잡 로그의 최상위 xctest 번들 요약을 합산한다.

    왜 필요한가: release 레인은 `continue-on-error` 라 **테스트가 실패해도 잡 결론이
    success** 다(의도된 보고 전용 — debug 가 차단 게이트다). 잡 결론만 보면 그 실패가
    보이지 않아, "release 는 통과했는데 debug 만 빨갛다" 는 잘못된 그림이 나온다.
    실제로 그렇게 두 번 오독했다."""
    try:
        text = api("repos/%s/actions/jobs/%s/logs" % (repo, job_id), raw=True).decode("utf-8", "replace")
    except SystemExit:
        return None
    # Swift 툴체인에 따라 타깃별 xctest 번들을 따로 실행한다. 마지막 요약만 읽으면 앞 번들의
    # 실패가 사라지므로 최상위 `*.xctest` 완료 요약을 합산한다. CI 구형 로그처럼 번들 이름이
    # 없는 형태는 아래 기존 last-summary 폴백으로 유지한다.
    bundles, pending = [], False
    for line in text.splitlines():
        if BUNDLE_SUMMARY.search(line):
            pending = True
            continue
        if "Test Suite '" in line:
            pending = False
            continue
        if pending:
            match = TEST_SUMMARY.search(line)
            if match:
                bundles.append((int(match.group(1)), int(match.group(2) or 0), int(match.group(3))))
                pending = False
    if bundles:
        return tuple(sum(values) for values in zip(*bundles))

    last = None
    for m in TEST_SUMMARY.finditer(text):
        last = m
    if not last:
        return None
    return (int(last.group(1)), int(last.group(2) or 0), int(last.group(3)))


# 화면에는 찍히지만 종료코드에는 안 실리던 것들을 여기 모은다.
#
# **[2026-08-20]** 이 도구가 막겠다고 명시한 사고(`branches: [main]` 로 8커밋 무검증)와,
# 이 도구가 유일하게 드러내는 사고(release 레인 `continue-on-error` 가 가리는 테스트 실패)가
# 둘 다 **기계적으로는 초록**이었다. `until python3 scripts/dev/ci-status.py; do …; done` 이
# 그 자리에서 성공으로 빠져나온다 — 사람이 화면을 읽을 때만 보이는 경고는 게이트가 아니다.
HIDDEN = {"test_failures": 0, "ci_missing_for_head": False, "no_runs": False,
          "inspected_test_jobs": set()}


def inspect_hidden_test_failures(repo, run_id):
    """Inspect successful release jobs whose `continue-on-error` can hide tests.

    This is part of the exit-code contract, not an opt-in display feature.  The
    default and `--watch` paths both call it once the HEAD workflows complete.
    """
    d = api("repos/%s/actions/runs/%s/jobs?per_page=30" % (repo, run_id))
    for j in d.get("jobs", []):
        if (j.get("status") != "completed" or j.get("conclusion") != "success"
                or "release" not in j.get("name", "").lower()
                or j.get("id") in HIDDEN["inspected_test_jobs"]):
            continue
        HIDDEN["inspected_test_jobs"].add(j.get("id"))
        tally = test_tally(repo, j["id"])
        if not tally:
            continue
        _, _, failures = tally
        if failures:
            HIDDEN["test_failures"] += failures
            print("     ⚠ %s: 잡은 success 인데 테스트 실패 %d건(continue-on-error)"
                  % (j.get("name", "release"), failures))


def show_jobs(repo, run_id, tests=False):
    d = api("repos/%s/actions/runs/%s/jobs?per_page=30" % (repo, run_id))
    print("\n== run %s ==" % run_id)
    for j in d.get("jobs", []):
        c = j.get("conclusion") or j["status"]
        line = "  [%s] %s   job=%s" % (MARK.get(c, c), j["name"], j["id"])
        if tests and j["status"] == "completed":
            HIDDEN["inspected_test_jobs"].add(j["id"])
            t = test_tally(repo, j["id"])
            if t:
                executed, skipped, failures = t
                note = "실행 %d · 스킵 %d · 실패 %d" % (executed, skipped, failures)
                if failures:
                    HIDDEN["test_failures"] += failures
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
               "Executed ", "위반", "실패", "Traceback", "executed=",
               "TYPECHECK_OBSERVATION")
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
                    help="--jobs 에 잡별 테스트 집계를 붙인다(숨은 release 실패 판정은 기본값도 수행)")
    ap.add_argument("--sha", default=None,
                    help="이 커밋의 실행을 본다(앞 7자 이상). 새 푸시가 목록을 밀어낸 뒤에도 "
                         "과거 실패를 열어볼 수 있다 — 없으면 실패→CI→맨위 순으로 고른다")
    ap.add_argument("--run", type=int, default=None, metavar="RUN_ID",
                    help="실행 ID 를 직접 지목한다(--sha 보다 우선)")
    ap.add_argument("--log", type=int, default=None, metavar="JOB_ID")
    ap.add_argument("--keep", type=int, default=40, help="--log 가 남길 줄 수")
    ap.add_argument("--watch", action="store_true", help="완료까지 폴링")
    ap.add_argument("--interval", type=int, default=30)
    ap.add_argument("--timeout", type=int, default=1800)
    a = ap.parse_args()
    a_repo[0] = a.repo
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

    if (a.jobs or a.tests) and (runs or a.run):
        # 지목이 있으면 그것을, 없으면 실패 → CI → 맨 위 순으로 고른다. 기본값이 runs[0]
        # (대개 spec)이면 잡 상세가 파이썬 게이트 한 줄뿐이라 쓸모가 없다.
        #
        # --sha/--run 이 필요한 이유: 새 커밋을 밀면 그 실행이 목록 맨 위로 와서 "실패가 있으면
        # 그것" 규칙이 **진행 중인 새 실행**에 가려진다. 방금 무엇이 깨졌는지 보려던 참에
        # 정확히 못 보게 되는 자리다(실제로 겪었다).
        if a.run:
            show_jobs(a.repo, a.run, tests=a.tests)
        else:
            pick = None
            if a.sha:
                pick = next((r for r in runs if r["head_sha"].startswith(a.sha)
                             and r["name"] == "CI"), None) \
                    or next((r for r in runs if r["head_sha"].startswith(a.sha)), None)
                if pick is None:
                    print("  --sha %s 에 해당하는 실행이 최근 %d건 안에 없다 — --limit 을 키워라"
                          % (a.sha, a.limit))
            if pick is None and not a.sha:
                pick = (next((r for r in runs if r.get("conclusion") == "failure"), None)
                        or next((r for r in runs if r["name"] == "CI"), None)
                        or runs[0])
            if pick:
                show_jobs(a.repo, pick["id"], tests=a.tests)

    if HIDDEN["no_runs"] or not runs:
        # 브랜치에 실행이 하나도 없다 = 검증 0. 종전엔 0(성공)이었다.
        print("\n[ci-status] 이 브랜치에 워크플로 실행이 없다 — 검증된 것이 없다")
        return 1
    # **로컬 HEAD 를 기준으로 판정한다.** 목록의 맨 위(runs[0])를 쓰면 푸시 직후 새 실행이
    # 아직 안 뜬 창에서 **직전 커밋의 결과**를 보고 "끝났다" 고 답한다 — 대기 루프가
    # 그 자리에서 빠져나온다(실제로 당했다). HEAD 의 실행이 하나도 없으면 "진행 중"(2)이다.
    local = head_sha()
    if local and not any(r["head_sha"] == local for r in runs):
        # 단, 문서 전용 커밋은 CI 가 영영 안 뜬다 — 그 경우 spec 만 보고 판정한다.
        by_sha = api("repos/%s/actions/runs?head_sha=%s&per_page=20" % (a_repo[0], local))
        mine = by_sha.get("workflow_runs", [])
        if not mine:
            print("     %s: 아직 실행이 뜨지 않았다(진행 중으로 본다)" % local[:7])
            return 2
        runs = mine
        head = local
    else:
        head = local or runs[0]["head_sha"]
    same = [r for r in runs if r["head_sha"] == head]
    if not same:
        return 2
    if any(r["status"] != "completed" for r in same):
        return 2
    if any(r.get("conclusion") != "success" for r in same):
        return 1
    # release `Test` 는 continue-on-error 이므로 workflow/job 이 success 여도 테스트가 실패할
    # 수 있다. 사람이 `--tests` 를 붙였을 때만 보던 정보를 기본/--watch 종료코드에도 넣는다.
    for run in same:
        if run.get("name") == "CI":
            inspect_hidden_test_failures(a.repo, run["id"])
    if HIDDEN["ci_missing_for_head"]:
        print("\n[ci-status] HEAD 에 코드 변경이 있는데 CI 실행이 없다 — 검증 0")
        return 1
    if HIDDEN["test_failures"]:
        # release 레인은 `continue-on-error` 라 잡이 success 로 끝나면서 테스트는 실패한다.
        # 기본/--watch 경로에서도 자동으로 읽는다. `--tests` 는 잡별 상세 표시 옵션일 뿐이다.
        print("\n[ci-status] 잡 결론은 success 인데 테스트 실패 %d건 — continue-on-error 가 가린 것이다"
              % HIDDEN["test_failures"])
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
