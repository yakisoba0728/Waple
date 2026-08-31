"""linux-core-tests.sh 작업 디렉터리 삭제 경계 회귀 테스트.

실행: ``cd scripts/dev/tests && python3 -m unittest test_linux_core_tests_safety``
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


class LinuxCoreTestsWorkspaceSafetyTests(unittest.TestCase):
    def setUp(self) -> None:
        source_script = Path(__file__).resolve().parents[1] / "linux-core-tests.sh"
        self.temp = tempfile.TemporaryDirectory()
        raw_temp = Path(self.temp.name)
        self.repo = raw_temp / "fixture-repo"
        self.script = self.repo / "scripts" / "dev" / "linux-core-tests.sh"
        shim = self.repo / "scripts" / "dev" / "linux-shim"
        self.source_sentinel = self.repo / "Sources" / "WapleCore" / "sentinel.swift"
        self.test_sentinel = self.repo / "Tests" / "WapleCoreTests" / "sentinel.swift"
        self.fake_bin = raw_temp / "fake-swift-bin"
        fake_swift = self.fake_bin / "swift"

        shim.mkdir(parents=True)
        self.source_sentinel.parent.mkdir(parents=True)
        self.test_sentinel.parent.mkdir(parents=True)
        self.fake_bin.mkdir(parents=True)
        shutil.copy2(source_script, self.script)
        (shim / "simd.swift").write_text("// fixture\n", encoding="utf-8")
        (shim / "corefoundation.swift").write_text("// fixture\n", encoding="utf-8")
        self.source_sentinel.write_text("// source must survive\n", encoding="utf-8")
        self.test_sentinel.write_text("// test must survive\n", encoding="utf-8")
        fake_swift.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.script.chmod(self.script.stat().st_mode | stat.S_IXUSR)
        fake_swift.chmod(fake_swift.stat().st_mode | stat.S_IXUSR)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_script(self, work: Path) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "WAPLE_CORETESTS_LOCKED": "1",
                "WAPLE_LINUX_TEST_DIR": str(work),
                "WAPLE_SWIFT_BIN": str(self.fake_bin),
            }
        )
        return subprocess.run(
            [str(self.script)],
            cwd=self.repo,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_repository_root_cannot_be_used_as_destructive_workspace(self) -> None:
        result = self.run_script(self.repo)

        self.assertNotEqual(
            result.returncode,
            0,
            "저장소 루트를 WORK로 지정한 실행은 삭제 전에 거부돼야 한다",
        )
        self.assertTrue(self.source_sentinel.exists(), "실제 Sources 트리가 삭제됐다")
        self.assertTrue(self.test_sentinel.exists(), "실제 Tests 트리가 삭제됐다")

    def test_empty_owned_workspace_still_runs_and_can_be_reused(self) -> None:
        work = Path(self.temp.name) / "workspace"
        first = self.run_script(work)
        second = self.run_script(work)

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        marker = work / ".waple-linux-core-tests-workspace"
        self.assertEqual(marker.read_text(encoding="utf-8").strip(), "Waple linux core tests workspace v1")
        self.assertTrue(self.source_sentinel.exists())
        self.assertTrue(self.test_sentinel.exists())


if __name__ == "__main__":
    unittest.main()
