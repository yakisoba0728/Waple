"""CI/release workflow contracts that can be checked without GitHub or a macOS build.

Run from the repository root:

    python3 -m unittest scripts.dev.tests.test_workflow_contracts

The helpers consume synthetic XCTest/GitHub API data, so this suite is the fast
feedback loop for workflow edits that would otherwise need an expensive remote run.
"""
import json
import pathlib
import re
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
CI = ROOT / ".github" / "workflows" / "ci.yml"
RELEASE = ROOT / ".github" / "workflows" / "release.yml"
SPEC = ROOT / ".github" / "workflows" / "spec.yml"
CENSUS = ROOT / "scripts" / "dev" / "xctest-census.py"
RELEASE_GATE = ROOT / "scripts" / "dev" / "check-release-ci.py"
SHA = "a" * 40


def step_block(text: str, name: str) -> str:
    marker = f"      - name: {name}"
    start = text.index(marker)
    end = text.find("\n      - name: ", start + len(marker))
    return text[start:] if end < 0 else text[start:end]


class TestXCTestCensus(unittest.TestCase):
    def run_census(self, log: str):
        return subprocess.run(
            ["python3", str(CENSUS), "-"], input=log, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=ROOT,
        )

    def test_sums_only_xctest_bundle_summaries(self):
        log = """
Test Suite 'AClass' passed at 2026-08-31 00:00:00.
     Executed 3 tests, with 0 failures (0 unexpected)
Test Suite 'A.xctest' passed at 2026-08-31 00:00:00.
     Executed 3 tests, with 0 failures (0 unexpected)
Test Suite 'BClass' passed at 2026-08-31 00:00:00.
     Executed 4 tests, with 0 failures (0 unexpected)
Test Suite 'B.xctest' passed at 2026-08-31 00:00:00.
     Executed 4 tests, with 0 failures (0 unexpected)
Test Suite 'Empty.xctest' passed at 2026-08-31 00:00:00.
     Executed 0 tests, with 0 failures (0 unexpected)
"""
        p = self.run_census(log)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(), "7")

    def test_refuses_a_log_without_bundle_summaries(self):
        p = self.run_census("Test Suite 'AClass' passed\n Executed 3 tests\n")
        self.assertNotEqual(p.returncode, 0)


class TestReleaseCIGate(unittest.TestCase):
    def run_gate(self, runs):
        return subprocess.run(
            ["python3", str(RELEASE_GATE), SHA, "-"],
            input=json.dumps({"workflow_runs": runs}), text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=ROOT,
        )

    @staticmethod
    def run_item(path=".github/workflows/ci.yml", name="CI", **kw):
        value = {
            "name": name, "path": path,
            "head_sha": SHA, "status": "completed", "conclusion": "success",
            "id": 10, "html_url": "https://example.invalid/run/10",
        }
        value.update(kw)
        return value

    def test_accepts_successful_ci_and_spec_runs_for_exact_sha(self):
        p = self.run_gate([
            self.run_item(),
            self.run_item(path=".github/workflows/spec.yml", name="spec", id=11),
        ])
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_terminal_failure_is_immediate_failure(self):
        runs = [
            self.run_item(),
            self.run_item(path=".github/workflows/spec.yml", name="spec",
                          id=11, conclusion="failure"),
        ]
        self.assertEqual(self.run_gate(runs).returncode, 1)

    def test_missing_or_pending_run_requests_a_bounded_wait(self):
        ci = self.run_item()
        pending_spec = self.run_item(path=".github/workflows/spec.yml", name="spec", id=11,
                                     status="in_progress", conclusion=None)
        for runs in ([], [ci], [ci, pending_spec],
                     [self.run_item(head_sha="b" * 40)]):
            with self.subTest(runs=runs):
                self.assertEqual(self.run_gate(runs).returncode, 2)

    def test_pending_tag_race_can_become_success_on_next_poll(self):
        ci = self.run_item()
        pending = self.run_item(path=".github/workflows/spec.yml", name="spec", id=11,
                                status="queued", conclusion=None)
        passed = dict(pending, status="completed", conclusion="success")
        self.assertEqual(self.run_gate([ci, pending]).returncode, 2)
        self.assertEqual(self.run_gate([ci, passed]).returncode, 0)

    def test_uses_exact_workflow_paths_and_latest_reruns(self):
        spec_ok = self.run_item(path=".github/workflows/spec.yml", name="spec", id=20)
        wrong_ci = self.run_item(path=".github/workflows/not-ci.yml", name="CI", id=21)
        self.assertEqual(self.run_gate([wrong_ci, spec_ok]).returncode, 2)

        old_ci_ok = self.run_item(id=10)
        new_ci_failed = self.run_item(id=30, conclusion="cancelled")
        self.assertEqual(self.run_gate([old_ci_ok, new_ci_failed, spec_ok]).returncode, 1)

        old_ci_failed = self.run_item(id=10, conclusion="failure")
        new_ci_ok = self.run_item(id=30)
        self.assertEqual(self.run_gate([old_ci_failed, new_ci_ok, spec_ok]).returncode, 0)

        # GitHub workflow re-runs retain the workflow run id and increment run_attempt.
        first_attempt = self.run_item(id=40, run_attempt=1, conclusion="failure")
        second_attempt = self.run_item(id=40, run_attempt=2, conclusion="success")
        self.assertEqual(self.run_gate([first_attempt, second_attempt, spec_ok]).returncode, 0)


class TestWorkflowWiring(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ci = CI.read_text(encoding="utf-8")
        cls.release = RELEASE.read_text(encoding="utf-8")
        cls.spec = SPEC.read_text(encoding="utf-8")

    def test_ci_uses_bundle_census_instead_of_last_summary(self):
        census = step_block(self.ci, "Skip / execution census")
        self.assertIn("python3 scripts/dev/xctest-census.py test-output.log", census)
        self.assertNotIn("tail -1", census)

    def test_source_warning_census_has_a_non_increasing_ceiling(self):
        census = step_block(self.ci, "Concurrency diagnostics census")
        self.assertIn("SOURCE_WARNINGS=", census)
        # [정정 2026-09-01] 종전엔 `-gt 25` **리터럴**을 단언했다. 그러면 상한을 **낮추는**
        # 커밋이 이 테스트를 깨뜨린다 — census 스텝 자신의 주석이 "진단을 고친 커밋은 아래
        # 상한도 함께 낮춘다" 고 규정하는데, 그 규정을 따르면 반드시 빨개지는 구조였다.
        # "증가 금지 ceiling" 을 잠근다면서 **감소까지** 막고 있었다. 숫자를 파싱해
        # "상한이 존재하고 기준선 25 이하" 만 본다.
        match = re.search(r'\$\{SOURCE_WARNINGS:-0\}"\s*-gt\s*(\d+)', census)
        self.assertIsNotNone(match, "SOURCE_WARNINGS 상한 비교(`-gt <n>`)가 사라졌다")
        self.assertLessEqual(int(match.group(1)), 25,
                             "Swift 6 전환 기준선 25 위로는 올릴 수 없다(증가 금지 래칫)")
        self.assertIn("Sources warning", census)

    def test_source_warning_census_has_a_positive_control_for_its_grep(self):
        """상한만 있으면 `0` 이 '고쳤다' 인지 '패턴이 깨져 못 본다' 인지 구분되지 않는다."""
        census = step_block(self.ci, "Concurrency diagnostics census")
        self.assertIn("PROBE=", census)
        self.assertIn('"${PROBE:-0}" -ne 1', census)

    def test_golden_bootstrap_captures_debug_then_validates_same_files_in_release(self):
        self.assertIn("golden-bootstrap:", self.ci)
        job = self.ci[self.ci.index("  golden-bootstrap:"):]
        capture = job.index("name: Capture synthetic golden baseline (debug)")
        validate = job.index("name: Validate synthetic golden baseline (release)")
        upload = job.index("name: Upload synthetic golden baseline")
        self.assertLess(capture, validate)
        self.assertLess(validate, upload)
        self.assertIn('WAPLE_GOLDEN_BOOTSTRAP: "1"', job[capture:validate])
        self.assertIn('WAPLE_GOLDEN_BOOTSTRAP: "0"', job[validate:upload])
        matrix_test = step_block(self.ci, "Test")
        self.assertNotIn("inputs.golden_bootstrap", matrix_test)

    def test_release_preflights_ci_and_distribution_approval_before_packaging(self):
        ci_gate = self.release.index("name: Require successful CI and spec for this commit")
        rights = self.release.index("name: Require distribution approval")
        package = self.release.index("name: Package app (Waple.app + Waple.dmg)")
        self.assertLess(ci_gate, package)
        self.assertLess(rights, package)
        self.assertIn("python3 scripts/dev/check-release-ci.py", self.release)
        gate = step_block(self.release, "Require successful CI and spec for this commit")
        self.assertIn("for attempt in", gate)
        self.assertIn("sleep 20", gate)
        self.assertIn("WAPLE_WE_ASSETS_DISTRIBUTION_APPROVED", self.release)

    def test_signing_detection_requires_all_six_secrets(self):
        block = step_block(self.release, "Detect signing configuration")
        names = (
            "DEVELOPER_ID_APPLICATION", "DEVELOPER_ID_CERT_P12",
            "DEVELOPER_ID_CERT_PASSWORD", "NOTARY_APPLE_ID",
            "NOTARY_TEAM_ID", "NOTARY_PASSWORD",
        )
        for name in names:
            self.assertIn(f"secrets.{name}", block)
        for var in ("DEV_ID", "CERT", "CERT_PASSWORD", "NOTARY_APPLE_ID",
                    "NOTARY_TEAM_ID", "NOTARY_PASSWORD"):
            self.assertIn(f'-n "${var}"', block)

    def test_gatekeeper_verification_is_not_ignored(self):
        block = step_block(self.release, "Notarize DMG")
        spctl = next(line for line in block.splitlines() if "spctl " in line)
        self.assertNotIn("|| true", spctl)

    def test_cited_address_census_is_wired_into_spec(self):
        self.assertIn("python3 scripts/spec/check_cited_address_census.py", self.spec)

    def test_fast_developer_tool_regressions_are_wired_into_spec(self):
        block = step_block(self.spec, "Developer tool self-tests")
        for module in (
            "scripts.dev.tests.test_workflow_contracts",
            "scripts.dev.tests.test_ci_status",
            "scripts.dev.tests.test_linux_core_tests_safety",
            "scripts.dev.tests.test_waple_saver_lifecycle",
        ):
            self.assertIn(module, block)
        spec_self_tests = step_block(self.spec, "Spec self-tests")
        self.assertIn("scripts/spec/tests/test_measure_prerequisites.py", spec_self_tests)
        self.assertIn("scripts/spec/measure_workshop_shaders.py --selftest", spec_self_tests)

    def test_macos_typecheck_fails_closed_on_unmatched_driver_diagnostics(self):
        script = (ROOT / "scripts" / "dev" / "macos-test-typecheck.sh").read_text(encoding="utf-8")
        self.assertIn('if [ "$rc" -ne 0 ] && [ "$n" -eq 0 ]; then', script)
        self.assertIn("잘못된 트리플", script)
        self.assertIn("매치 0", script)
        self.assertNotIn("잘못된 트리플 · 없는 입력 파일 = 전부 매치 ≥1", script)

    def test_no_temporary_diagnostic_xctest_source_is_left_in_target(self):
        self.assertEqual(list((ROOT / "Tests").glob("**/ZZTemp*.swift")), [])


if __name__ == "__main__":
    unittest.main()
