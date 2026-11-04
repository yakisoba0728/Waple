"""Run destructive-tool regressions only inside disposable fixture repositories."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]


def executable(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)


class AuditToolSafetyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        WAPLE_REPO=str(self.repo), WAPLE_DEV_ROOT=str(self.base / "corpus"),
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        for name in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
                     "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"]:
            self.env.pop(name, None)
        executable(self.bin / "launchctl", '#!/bin/sh\nshift 2\nexec "$@"\n')

    def tearDown(self) -> None:
        self.temp.cleanup()

    def copy_script(self, relative: str) -> Path:
        script = self.repo / relative
        script.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, script)
        return script

    def run_script(self, script: Path, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(script)], cwd=self.repo,
                              env=dict(self.env, **env), capture_output=True,
                              text=True, timeout=15)

    def pointer_fixture(self) -> Path:
        script = self.copy_script("scripts/mac-session/probe-pointer-uniform.sh")
        executable(self.bin / "swiftc", '''#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then shift; output="$1"; fi
  shift
done
printf '#!/bin/sh\nprintf "100 200\\n"\n' > "$output"
chmod +x "$output"
''')
        executable(self.repo / ".build/release/WapleCompat", '''#!/usr/bin/env python3
import json, os, pathlib, sys
mode = os.environ.get("CAPTURE_MODE", "valid")
if mode == "failure": sys.exit(7)
out = pathlib.Path(sys.argv[sys.argv.index("--capture") + 1])
label = sys.argv[sys.argv.index("--label") + 1]
target = out / label
target.mkdir(parents=True, exist_ok=True)
digest = {"empty_hash": "", "bad_hash": "not-a-hash", "short_hash": "f"}.get(mode, "0123456789abcdef")
entries = [] if mode == "empty" else [{"hash": digest}]
(target / "manifest.json").write_text(json.dumps({"entries": entries}))
''')
        return script

    def test_pointer_preserves_existing_output_root(self) -> None:
        script = self.pointer_fixture()
        output = self.base / "existing results"
        output.mkdir()
        sentinel = output / "baseline.txt"
        sentinel.write_text("old baseline")
        result = self.run_script(script, WAPLE_VERIFY_OUT=str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sentinel.read_text(), "old baseline")
        self.assertEqual(len(list(output.glob("pointer.*/orig/manifest.json"))), 1)

    def test_pointer_rejects_failed_or_empty_captures(self) -> None:
        script = self.pointer_fixture()
        for mode in ["failure", "empty", "empty_hash", "bad_hash"]:
            with self.subTest(mode=mode):
                result = self.run_script(script, CAPTURE_MODE=mode,
                                         WAPLE_VERIFY_OUT=str(self.base / mode))
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("포인터 무영향", result.stdout)

    def test_pointer_accepts_unpadded_fnv_hashes(self) -> None:
        script = self.pointer_fixture()
        result = self.run_script(script, CAPTURE_MODE="short_hash",
                                 WAPLE_VERIFY_OUT=str(self.base / "short-hash"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("포인터 무영향", result.stdout)

    def tsweep_fixture(self) -> Path:
        script = self.copy_script("scripts/mac-session/capture-tsweep.sh")
        spec = self.repo / "spec/golden/nondeterminism.json"
        spec.parent.mkdir(parents=True, exist_ok=True)
        spec.write_text('{"entries":[{"id":"oracle.nondet.unstableSet","value":{"ids":["123","456"]}}]}')
        executable(self.repo / ".build/release/WapleCompat", r'''#!/usr/bin/env python3
import base64, os, pathlib, sys
mode = os.environ.get("CAPTURE_MODE", "valid")
if mode == "failure": sys.exit(7)
out = pathlib.Path(sys.argv[sys.argv.index("--capture") + 1])
label = sys.argv[sys.argv.index("--label") + 1]
if mode == "missing_scene" and label == "456": sys.exit(0)
thumbs = out / label / "thumbs"
thumbs.mkdir(parents=True, exist_ok=True)
png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
if mode == "empty_png": png = b""
if mode == "bad_png": png = b"not png"
for name in [label, label + "_t0.0", label + "_t0.1", label + "_t1.0"]:
    if mode == "missing_frame" and name.endswith("_t0.1"): continue
    (thumbs / (name + ".png")).write_bytes(png)
''')
        return script

    def run_tsweep(self, script: Path, label: str, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(script), label], cwd=self.repo,
                              env=dict(self.env, **env), capture_output=True,
                              text=True, timeout=15)

    def test_tsweep_preserves_existing_results_and_symlink_targets(self) -> None:
        script = self.tsweep_fixture()
        for kind in ["directory", "label-symlink", "root-symlink"]:
            with self.subTest(kind=kind):
                output = self.base / f"existing tsweep {kind}"
                if kind == "root-symlink":
                    root_target = self.base / "root-target"
                    root_target.mkdir()
                    output.symlink_to(root_target, target_is_directory=True)
                else:
                    output.mkdir()
                baseline = output / "tsweep-F"
                if kind == "label-symlink":
                    target = self.base / "baseline-target"
                    target.mkdir()
                    baseline.symlink_to(target, target_is_directory=True)
                else:
                    baseline.mkdir()
                sentinel = baseline / "hashes.json"
                sentinel.write_text("old baseline")
                result = self.run_tsweep(script, "F", WAPLE_TSWEEP_OUT=str(output))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(sentinel.read_text(), "old baseline")
                if kind == "label-symlink": self.assertTrue(baseline.is_symlink())
                if kind == "root-symlink": self.assertTrue(output.is_symlink())
                reports = list(output.glob("tsweep-F.*/hashes.json"))
                self.assertEqual(len(reports), 1)
                report = json.loads(reports[0].read_text())
                self.assertEqual(set(report["frames"]), {"123", "456"})
                self.assertEqual(set(report["frames"]["123"]), {"canon", "t0.0", "t0.1", "t1.0"})

    def test_tsweep_rejects_failed_incomplete_and_empty_png_captures(self) -> None:
        script = self.tsweep_fixture()
        for mode in ["failure", "missing_scene", "missing_frame", "empty_png", "bad_png"]:
            with self.subTest(mode=mode):
                output = self.base / mode
                result = self.run_tsweep(script, "F", CAPTURE_MODE=mode,
                                         WAPLE_TSWEEP_OUT=str(output))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(list(output.glob("**/hashes.json")), [])

    def test_tsweep_rejects_unsafe_labels_and_empty_scene_sets(self) -> None:
        script = self.tsweep_fixture()
        for index, label in enumerate(["../baseline", "F/../../baseline", "", ".."]):
            output = self.base / f"invalid-label-{index}"
            with self.subTest(label=label):
                result = self.run_tsweep(script, label, WAPLE_TSWEEP_OUT=str(output))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())
        output = self.base / "empty-scenes"
        (self.repo / "spec/golden/nondeterminism.json").write_text(
            '{"entries":[{"id":"oracle.nondet.unstableSet","value":{"ids":[]}}]}')
        result = self.run_tsweep(script, "F", WAPLE_TSWEEP_OUT=str(output))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(output.glob("**/hashes.json")), [])

    def typecheck_fixture(self) -> Path:
        script = self.copy_script("scripts/dev/linux-render-typecheck.sh")
        executable(self.bin / "swiftc", "#!/bin/sh\nexit 0\n")
        return script

    def run_typecheck(self, script: Path, work: Path) -> subprocess.CompletedProcess[str]:
        return self.run_script(script, WAPLE_TYPECHECK_LOCKED="1",
                               WAPLE_SWIFT_BIN=str(self.bin),
                               WAPLE_LINUX_TYPECHECK_DIR=str(work))

    def test_typecheck_refuses_unowned_existing_source_directory(self) -> None:
        script = self.typecheck_fixture()
        work = self.base / "other-project"
        source = work / "core/sentinel.swift"
        source.parent.mkdir(parents=True)
        source.write_text("// do not delete")
        result = self.run_typecheck(script, work)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("소유 마커", result.stderr)
        self.assertEqual(source.read_text(), "// do not delete")

    def test_typecheck_refuses_symlink_workspace_and_owned_children(self) -> None:
        script = self.typecheck_fixture()
        external = self.base / "external"
        external.mkdir()
        sentinel = external / "sentinel.swift"
        sentinel.write_text("// outside workspace")
        work_link = self.base / "work-link"
        work_link.symlink_to(external, target_is_directory=True)
        result = self.run_typecheck(script, work_link)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("심링크", result.stderr)
        for child in ["core", "mods"]:
            with self.subTest(child=child):
                work = self.base / f"owned-{child}"
                work.mkdir()
                (work / ".waple-linux-render-typecheck-workspace").write_text(
                    "Waple linux render typecheck workspace v1\n")
                (work / child).symlink_to(external, target_is_directory=True)
                result = self.run_typecheck(script, work)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("심링크", result.stderr)
        self.assertEqual(sentinel.read_text(), "// outside workspace")

    def ab_fixture(self) -> tuple[Path, Path]:
        script = self.copy_script("scripts/ab-deviations/02-capture-ab.sh")
        for relative in ["Sources/WapleCore/ScenePBRLighting.swift",
                         "Sources/WapleRender/Mesh3DShaders.swift",
                         "Sources/WapleRender/BlendMSL.swift"]:
            target = self.repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)
        unrelated = self.repo / "Sources/Waple/Unrelated.swift"
        unrelated.parent.mkdir(parents=True)
        unrelated.write_text("// original\n")
        # Only this throwaway repository gets a commit; the real worktree is untouched.
        for args in [["init", "-q"], ["add", "."],
                     ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                      "commit", "-qm", "fixture"]]:
            subprocess.run(["git", *args], cwd=self.repo, check=True,
                           capture_output=True, env=self.env)
        executable(self.bin / "swift", '''#!/bin/sh
if [ "$1" = build ]; then
  printf '// edited during build\\n' >> "$EDIT_SENTINEL"
  pwd > "$BUILD_CWD"
  exit "${BUILD_EXIT:-0}"
fi
exit 0
''')
        return script, unrelated

    def test_ab_cleanup_preserves_edits_made_during_build_on_success_and_failure(self) -> None:
        for status in ["0", "7"]:
            with self.subTest(build_exit=status):
                # A fresh committed fixture is needed for each clean-tree preflight.
                if self.repo.exists(): shutil.rmtree(self.repo)
                script, unrelated = self.ab_fixture()
                cwd_file = self.base / f"build-cwd-{status}"
                result = self.run_script(script, EDIT_SENTINEL=str(unrelated),
                                         BUILD_CWD=str(cwd_file), BUILD_EXIT=status,
                                         WAPLE_AB_OUT=str(self.base / f"ab-{status}"))
                self.assertEqual(result.returncode, 0 if status == "0" else 1, result.stderr)
                self.assertIn("edited during build", unrelated.read_text())
                self.assertNotEqual(Path(cwd_file.read_text().strip()), self.repo)
                self.assertFalse(Path(cwd_file.read_text().strip()).exists())
                worktrees = subprocess.run(["git", "worktree", "list", "--porcelain"],
                                          cwd=self.repo, env=self.env, check=True,
                                          capture_output=True, text=True)
                self.assertEqual(worktrees.stdout.count("worktree "), 1)


if __name__ == "__main__":
    unittest.main()
