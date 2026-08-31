"""`ci-status.py` 의 **종료코드 계약**을 스텁 API 로 못박는다.

이 도구는 사람이 읽는 화면과 기계가 읽는 종료코드가 **다른 말을 하고 있었다**:

  · 브랜치에 워크플로 실행이 하나도 없다            → 화면 `(실행 없음)`,      rc **0**
  · HEAD 에 코드 변경이 있는데 CI 실행이 없다        → 화면 `⚠ CI 없음인데…`,   rc **0**
  · 잡 결론은 success 인데 테스트는 실패            → 화면 `← …continue-on-error`, rc **0**

셋 다 이 도구가 막겠다고 명시한 사고 그 자체다(`branches: [main]` 로 8커밋 무검증,
release 레인이 가리는 테스트 실패). `until python3 scripts/dev/ci-status.py; do …; done`
관용구가 그 자리에서 성공으로 빠져나온다 — 사람이 화면을 읽을 때만 보이는 경고는
게이트가 아니다.

실행: `cd scripts/dev/tests && python3 -m unittest test_ci_status`
(네트워크를 타지 않는다 — `api`/`head_sha`/`test_tally` 를 전부 스텁으로 바꾼다.)
"""
import contextlib
import importlib.util
import io
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "ci-status.py")
SHA = "a" * 40


def load():
    """모듈 전역(HIDDEN 등)이 케이스 사이에 새지 않도록 매번 새로 적재한다."""
    spec = importlib.util.spec_from_file_location("ci_status_under_test", TOOL)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def run(runs, jobs=None, tally=None, docs_only=False, argv=("--tests",)):
    m = load()
    m.head_sha = lambda: SHA

    def api(path, raw=False):
        if "/jobs" in path:
            return {"jobs": jobs or []}
        if "head_sha=" in path:
            return {"workflow_runs": [r for r in runs if r["head_sha"] in path]}
        if "/commits/" in path:
            return {"files": [{"filename": "README.md"}] if docs_only
                    else [{"filename": "Sources/a.swift"}]}
        return {"workflow_runs": runs}

    m.api = api
    m.test_tally = lambda repo, job_id: tally
    m.docs_only_commit = lambda repo, sha: docs_only
    saved, sys.argv = sys.argv, ["ci-status.py", *argv]
    try:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = m.main()
        return rc, buf.getvalue()
    finally:
        sys.argv = saved


def wf(**kw):
    base = dict(head_sha=SHA, name="CI", status="completed", conclusion="success",
                id=1, created_at="2026-08-20T00:00:00Z")
    base.update(kw)
    return base


CI_OK = wf()
SPEC_OK = wf(name="spec", id=2)


class TestExitCodeContract(unittest.TestCase):
    # ── 종전에 rc=0 이던 자리 셋 ────────────────────────────────────────────
    def test_no_runs_at_all_is_failure(self):
        rc, out = run([])
        self.assertEqual(rc, 1, out)
        self.assertIn("검증된 것이 없다", out)

    def test_head_has_code_changes_but_no_ci_run_is_failure(self):
        rc, out = run([SPEC_OK], docs_only=False)
        self.assertEqual(rc, 1, out)
        self.assertIn("검증 0", out)

    def test_job_success_with_failing_tests_is_failure(self):
        rc, out = run([CI_OK, SPEC_OK],
                      jobs=[dict(name="swift · release", id=9, status="completed",
                                 conclusion="success", steps=[])],
                      tally=(2417, 46, 1), argv=("--tests", "--jobs"))
        self.assertEqual(rc, 1, out)
        self.assertIn("continue-on-error", out)

    def test_default_mode_finds_release_failure_hidden_by_successful_job(self):
        rc, out = run([CI_OK, SPEC_OK],
                      jobs=[dict(name="swift · release", id=9, status="completed",
                                 conclusion="success", steps=[])],
                      tally=(2417, 46, 1), argv=())
        self.assertEqual(rc, 1, out)
        self.assertIn("continue-on-error", out)

    def test_watch_mode_finds_release_failure_hidden_by_successful_job(self):
        rc, out = run([CI_OK, SPEC_OK],
                      jobs=[dict(name="swift · release", id=9, status="completed",
                                 conclusion="success", steps=[])],
                      tally=(2417, 46, 2), argv=("--watch", "--interval", "0"))
        self.assertEqual(rc, 1, out)
        self.assertIn("continue-on-error", out)

    def test_log_excerpt_keeps_typecheck_observation(self):
        m = load()
        log = (b"2026-08-31 normal line\n"
               b"2026-08-31 TYPECHECK_OBSERVATION rc=0 toolchain=Swift 6.3.3\n")
        m.api = lambda path, raw=False: log if raw else {}
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            m.show_log("owner/repo", 9, 40)
        self.assertIn("TYPECHECK_OBSERVATION rc=0", out.getvalue())

    def test_tally_sums_bundle_failures_instead_of_reading_only_last_bundle(self):
        m = load()
        log = b"""Test Suite 'A.xctest' failed at 2026-08-31 00:00:00.
 Executed 3 tests, with 1 failure (0 unexpected)
Test Suite 'B.xctest' passed at 2026-08-31 00:00:00.
 Executed 4 tests, with 0 failures (0 unexpected)
"""
        m.api = lambda path, raw=False: log if raw else {}
        self.assertEqual(m.test_tally("owner/repo", 9), (7, 0, 1))

    # ── 종전 동작을 그대로 지켜야 하는 자리 ─────────────────────────────────
    def test_all_success_is_zero(self):
        self.assertEqual(run([CI_OK, SPEC_OK])[0], 0)

    def test_ci_failure_is_one(self):
        self.assertEqual(run([wf(conclusion="failure"), SPEC_OK])[0], 1)

    def test_in_progress_is_two(self):
        """대기 루프가 이 값으로 계속 돈다 — 1 로 바꾸면 루프가 실패로 끝난다."""
        self.assertEqual(run([wf(status="in_progress", conclusion=None), SPEC_OK])[0], 2)

    def test_docs_only_commit_skipping_ci_is_not_a_failure(self):
        """`.md` 만 바꾼 커밋은 paths-ignore 로 CI 가 영영 안 뜬다 — 그건 정상이다."""
        rc, out = run([SPEC_OK], docs_only=True)
        self.assertEqual(rc, 0, out)
        self.assertIn("정상 스킵", out)

    def test_job_success_with_zero_failures_stays_zero(self):
        rc, out = run([CI_OK, SPEC_OK],
                      jobs=[dict(name="swift · debug", id=9, status="completed",
                                 conclusion="success", steps=[])],
                      tally=(2417, 46, 0), argv=("--tests", "--jobs"))
        self.assertEqual(rc, 0, out)


if __name__ == "__main__":
    unittest.main()
