"""Corpus-backed generators must fail clearly before writing a canon.

These checks deliberately point every external input at a missing path and run
from an empty directory.  A prerequisite regression therefore cannot touch the
repository's ``spec/**/*.json`` files.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
SPEC_SCRIPTS = ROOT / "scripts" / "spec"

# Corpus-backed scripts covered by the 2026-08-31 missing-input census. Values
# are the configuration names the diagnostic must mention so that a caller knows
# how to repair the invocation.
CASES = {
    "measure_binaries.py": ("WE_ROOT",),
    "measure_composite_refs.py": ("WE_WORKSHOP",),
    "measure_corpus.py": ("WE_WORKSHOP", "WE_ROOT"),
    "measure_deviation_reach.py": ("WE_WORKSHOP",),
    "measure_engine_symbols.py": ("WE_ROOT",),
    "measure_hdr_bloom.py": ("WE_ROOT", "WE_WORKSHOP"),
    "measure_material_schema.py": ("WE_ROOT", "WE_WORKSHOP"),
    "measure_media.py": ("WE_ROOT", "WE_WORKSHOP"),
    "measure_mip_luma.py": ("WE_WORKSHOP",),
    "measure_misc_assets.py": ("WE_ROOT", "WE_WORKSHOP"),
    "measure_particle_fields.py": ("WE_WORKSHOP",),
    "measure_render_state.py": ("WE_ROOT", "WE_WORKSHOP"),
    "measure_scene_schema.py": ("WE_WORKSHOP",),
    "measure_script_api.py": ("WE_ROOT",),
    "measure_shape_quad.py": ("WE_BIN", "WE_WORKSHOP"),
    "measure_texture_filtering.py": ("WE_BIN", "WE_WORKSHOP"),
    "measure_uniform_feed.py": ("WE_ROOT",),
    "measure_workshop_shaders.py": ("WE_WORKSHOP",),
}


class MeasurePrerequisiteTests(unittest.TestCase):
    def test_missing_inputs_are_explicit_and_never_write_a_canon(self) -> None:
        for filename, hints in CASES.items():
            # 생성기마다 빈 작업 디렉터리를 준다. 앞선 생성기가 만든 `spec/`이
            # 다음 subTest의 "부분 canon"으로 오인되는 것을 막는다.
            with self.subTest(script=filename), tempfile.TemporaryDirectory() as raw:
                sandbox = Path(raw)
                missing = sandbox / "missing"
                env = os.environ.copy()
                env.update({
                    "WE_ROOT": str(missing / "we-root"),
                    "WE_WORKSHOP": str(missing / "workshop"),
                    "WE_BINARY": str(missing / "wallpaper64.exe"),
                    "WE_BIN": str(missing / "wallpaper64.exe"),
                    "WAPLE_REAL_PKGS": str(missing / "real-pkgs"),
                })

                result = subprocess.run(
                    [sys.executable, str(SPEC_SCRIPTS / filename)],
                    cwd=sandbox,
                    env=env,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=10,
                    check=False,
                )
                output = result.stdout + result.stderr
                self.assertNotEqual(result.returncode, 0, output)
                self.assertNotIn("Traceback (most recent call last):", output)
                for hint in hints:
                    self.assertIn(hint, output)
                self.assertFalse(
                    (sandbox / "spec").exists(),
                    f"{filename} wrote a partial canon before rejecting missing input",
                )

    def test_measure_binaries_rejects_an_existing_but_empty_we_root(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            sandbox = Path(raw)
            empty_root = sandbox / "empty-we-root"
            empty_root.mkdir()
            env = os.environ.copy()
            env["WE_ROOT"] = str(empty_root)

            result = subprocess.run(
                [sys.executable, str(SPEC_SCRIPTS / "measure_binaries.py")],
                cwd=sandbox,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
                check=False,
            )
            output = result.stdout + result.stderr
            self.assertNotEqual(result.returncode, 0, output)
            self.assertIn("WE_ROOT", output)
            self.assertIn("wallpaper64.exe", output)
            self.assertFalse(
                (sandbox / "spec").exists(),
                "measure_binaries.py wrote a zero-entry canon from an empty WE_ROOT",
            )

    def test_measure_binaries_rejects_non_pe_target_files_before_writing(self) -> None:
        targets = (
            "wallpaper64.exe",
            "bin/scenescript64.dll",
            "bin/mediaextensions64.dll",
            "bin/resourcecompiler64.exe",
            "bin/resourceutil64.dll",
            "bin/cloneextensions64.dll",
            "bin/webwallpaper64.exe",
            "bin/wallpaperui.exe",
        )
        with tempfile.TemporaryDirectory() as raw:
            sandbox = Path(raw)
            corrupt_root = sandbox / "corrupt-we-root"
            for rel in targets:
                path = corrupt_root / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"")
            env = os.environ.copy()
            env["WE_ROOT"] = str(corrupt_root)

            result = subprocess.run(
                [sys.executable, str(SPEC_SCRIPTS / "measure_binaries.py")],
                cwd=sandbox,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
                check=False,
            )
            output = result.stdout + result.stderr
            self.assertNotEqual(result.returncode, 0, output)
            self.assertIn("PE", output)
            self.assertIn("wallpaper64.exe", output)
            self.assertFalse(
                (sandbox / "spec").exists(),
                "measure_binaries.py wrote a zero-entry canon from non-PE target files",
            )


if __name__ == "__main__":
    unittest.main()
