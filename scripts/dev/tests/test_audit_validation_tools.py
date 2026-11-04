"""검증 도구의 실패·빈 입력·마지막 레코드 회귀. 외부 바이너리/서비스는 쓰지 않는다."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shlex
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]


def load(relative):
    spec = importlib.util.spec_from_file_location(Path(relative).stem.replace("-", "_"), ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestCompleteXCTestLog(unittest.TestCase):
    def setUp(self):
        self.tool = load("scripts/dev/xctest-census.py")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / ".github/workflows").mkdir(parents=True)
        (self.root / ".github/workflows/ci.yml").write_text('if [ "${EXECUTED:-0}" -lt 14 ]; then\n')
        (self.root / "Package.swift").write_text("\n".join(
            f'.testTarget(name: "T{i}")' for i in range(7)))

    @staticmethod
    def case(i, outcome="passed"):
        return f"Test Case '-[T{i}.ExampleTests testOne]' {outcome} (0.001 seconds).\n"

    @staticmethod
    def summary(name, count, failures=0):
        return (f"Test Suite '{name}.xctest' {'failed' if failures else 'passed'} at now.\n"
                f" Executed {count} tests, with 0 tests skipped and {failures} failures (0 unexpected)\n")

    def check(self, text):
        with contextlib.redirect_stderr(io.StringIO()):
            return self.tool.check_complete(text, self.tool.bundle_counts(text), self.root)

    def test_aggregate_and_separate_target_bundles_both_pass(self):
        cases = "".join(self.case(i) for i in range(7))
        self.assertTrue(self.check(cases + self.summary("WaplePackageTests", 14)))
        self.assertTrue(self.check(cases + "".join(self.summary(f"T{i}", 2) for i in range(7))))

    def test_truncated_failed_and_skipped_target_logs_do_not_pass(self):
        cases = "".join(self.case(i) for i in range(7))
        for text in (cases, cases + self.summary("All", 13),
                     cases + self.summary("All", 14, 1),
                     "".join(self.case(i) for i in range(6)) + self.case(6, "skipped")
                     + self.summary("All", 14)):
            with self.subTest(text=text):
                self.assertFalse(self.check(text))

    def test_check_cli_preserves_count_stdout(self):
        path = self.root / "test.log"
        path.write_text("".join(self.case(i) for i in range(7)) + self.summary("All", 14))
        for args in ([str(path)], ["--check", str(path)]):
            output = io.StringIO()
            with mock.patch.object(self.tool, "ROOT", self.root), contextlib.redirect_stdout(output):
                self.assertEqual(self.tool.main(["census", *args]), 0)
            self.assertEqual(output.getvalue(), "14\n")

    def test_both_local_scripts_use_the_gate_and_preserve_process_failure(self):
        targets = re.findall(r'\.testTarget\(\s*name:\s*"([A-Za-z0-9_]+)"',
                             (ROOT / "Package.swift").read_text())
        floor = int(re.search(r'"\$\{EXECUTED:-0\}"\s*-lt\s+(\d+)',
                              (ROOT / ".github/workflows/ci.yml").read_text())[1])
        cases = "".join(f"Test Case '-[{name}.ExampleTests testOne]' passed (0.001 seconds).\n"
                        for name in targets)
        for script, log in (("verify-plan-b12.sh", "full-suite.log"),
                            ("verify-embedded-mips.sh", "full.log")):
            (self.root / log).write_text(cases + self.summary("All", floor))
            source = (ROOT / "scripts/mac-session" / script).read_text()
            start = source.index("if TESTS=$(python3 scripts/dev/xctest-census.py --check")
            block = source[start:source.index("\nfi", start) + 4]
            for code in (0, 1):
                with self.subTest(script=script, process_code=code):
                    shell = (f"OUT={shlex.quote(str(self.root))}\nSUITE_RC={code}\nT0=0\n"
                             "ok() { :; }\nbad() { exit 1; }\n" + block)
                    result = subprocess.run(["bash", "-c", shell], cwd=ROOT, capture_output=True, text=True)
                    self.assertEqual(result.returncode, code, result.stderr)


class TestTransitionLocale(unittest.TestCase):
    def test_missing_numeric_or_special_locale_key_fails(self):
        tool = load("scripts/re/playlist_transition.py")
        keys = [tool.PREFIX + x for x in ("fade", "none", "random", "default")]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shader = root / "shader"
            shader.write_text("#if FADEEFFECT == 0\n// Fade\n#endif\n")
            js = root / "ui.js"
            js.write_text('getTransitionOptions=function(){return[' + ",".join(
                '{label:"%s",value:"%s"}' % pair
                for pair in zip(keys, ("0", "none", "random", "-2"))) + "]}")
            locale = root / "locale.json"
            paths = dict(FRAG=str(shader), GEOM=str(shader), VERT=str(shader), JS=str(js), LOC=str(locale))
            for missing in (*keys, None):
                locale.write_text(json.dumps({k: "label" for k in keys if k != missing}))
                with self.subTest(missing=missing), mock.patch.multiple(tool, **paths), \
                        contextlib.redirect_stdout(io.StringIO()):
                    if missing is None:
                        tool.main()
                    else:
                        with self.assertRaises(SystemExit) as error:
                            tool.main()
                        self.assertEqual(error.exception.code, 1)


class TestLocalCaptureRuns(unittest.TestCase):
    def capture_block(self, script):
        source = (ROOT / "scripts/mac-session" / script).read_text()
        start = source.index('CAPTURE_ROOT=$(mktemp -d "$OUT/capture.XXXXXX")')
        end = (source.index('\nhr; echo "7. 골든 게이트', start)
               if script == "verify-plan-b12.sh" else source.index("\nhr\n", start))
        return source[start:end]

    def fixture(self, root):
        bin_dir = root / "bin"
        bin_dir.mkdir()
        tools = {
            "launchctl": '#!/bin/sh\nshift 2\nexec "$@"\n',
            "git": '#!/bin/sh\nprintf "fixture-sha\\n"\n',
            "swift": f"#!{sys.executable}\n" + '''import json, os, pathlib, sys
args = sys.argv
destination = pathlib.Path(args[args.index('--capture') + 1]) / args[args.index('--label') + 1]
with open(os.environ['FAKE_CAPTURE_TRACE'], 'a') as trace:
    trace.write(str(destination) + '\\n')
rc = int(os.environ['FAKE_CAPTURE_RC'])
if rc:
    sys.exit(rc)
if destination.exists():
    sys.exit(2)
destination.mkdir()
(destination / 'manifest.json').write_text(json.dumps({'fresh': True}))
''',
            "python3": f"#!{sys.executable}\n" + '''import json, os, pathlib, sys
destination = pathlib.Path(sys.argv[3])
assert json.loads((destination / 'manifest.json').read_text()) == {'fresh': True}
with open(os.environ['FAKE_COMPARE_TRACE'], 'a') as trace:
    trace.write(str(destination) + '\\n')
''',
        }
        for name, body in tools.items():
            path = bin_dir / name
            path.write_text(body)
            path.chmod(0o700)
        out = root / "output"
        out.mkdir()
        pre = root / "baseline"
        (pre / "thumbs").mkdir(parents=True)
        return bin_dir, out, pre

    def run_capture(self, script, root, rc):
        shell = ("set -uo pipefail\n"
                 f"PATH={shlex.quote(str(root / 'bin'))}:$PATH\nexport PATH\n"
                 f"OUT={shlex.quote(str(root / 'output'))}\n"
                 f"PRE={shlex.quote(str(root / 'baseline'))}\n"
                 f"ROOT={shlex.quote(str(root / 'corpus'))}\n"
                 'WAPLE_REAL_PKGS="$ROOT/backgrounds"\nWAPLE_BASE_ASSETS="$ROOT/assets"\n'
                 'SKIP_GOLDEN_DIFF=0\nbad() { printf "%s\\n" "$1"; }\nok() { :; }\nwarn() { :; }\n'
                 f"export FAKE_CAPTURE_TRACE={shlex.quote(str(root / 'captures'))}\n"
                 f"export FAKE_COMPARE_TRACE={shlex.quote(str(root / 'comparisons'))}\n"
                 f"export FAKE_CAPTURE_RC={rc}\n" + self.capture_block(script))
        return subprocess.run(["bash", "-c", shell], cwd=ROOT, capture_output=True, text=True)

    def test_reruns_capture_and_compare_fresh_artifacts_without_touching_existing_label(self):
        for script, prefix in (("verify-plan-b12.sh", "verify"), ("verify-embedded-mips.sh", "mips")):
            with self.subTest(script=script), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                _, out, _ = self.fixture(root)
                old = out / f"{prefix}-fixture-sha"
                old.mkdir()
                sentinel = old / "manifest.json"
                sentinel.write_text('{"legacy": true}')
                for _ in range(2):
                    result = self.run_capture(script, root, 0)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                captures = (root / "captures").read_text().splitlines()
                self.assertEqual(len(set(captures)), 2)
                self.assertEqual((root / "comparisons").read_text().splitlines(), captures)
                self.assertTrue(all(Path(path).name == old.name and Path(path).parent.parent == out
                                    for path in captures))
                self.assertEqual(sentinel.read_text(), '{"legacy": true}')

    def test_capture_failure_preserves_rc_and_never_compares_old_manifest(self):
        for script, prefix in (("verify-plan-b12.sh", "verify"), ("verify-embedded-mips.sh", "mips")):
            with self.subTest(script=script), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                _, out, _ = self.fixture(root)
                old = out / f"{prefix}-fixture-sha"
                old.mkdir()
                sentinel = old / "manifest.json"
                sentinel.write_text('{"legacy": true}')
                result = self.run_capture(script, root, 17)
                self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
                self.assertFalse((root / "comparisons").exists())
                self.assertEqual(sentinel.read_text(), '{"legacy": true}')


class TestCaptureProbeScripts(unittest.TestCase):
    scripts = ("rebaseline-golden.sh", "probe-nondeterminism.sh",
               "probe-session-nondeterminism.sh", "probe-scene-repeat.sh")

    def fixture(self, root):
        repo, output, tools = root / "repo", root / "output", root / "bin"
        for directory in (repo, output, tools, root / "corpus"):
            directory.mkdir()
        payload = {"entries": [{"id": "fixture", "hash": "fixed", "meanLuma": 1,
                                "selfMaxDiff": 0, "deterministic": True}],
                   "empties": [], "failures": []}
        known = repo / "spec/golden/snapshot/nondet-2026-08-01/stateA"
        known.mkdir(parents=True)
        (known / "manifest.json").write_text(json.dumps(payload))
        capture = f"#!{sys.executable}\n" + r'''import json, os, pathlib, sys
if '--capture' not in sys.argv:
    sys.exit(0)
args = sys.argv
out = pathlib.Path(args[args.index('--capture') + 1]) / args[args.index('--label') + 1]
trace = pathlib.Path(os.environ['FAKE_CAPTURE_TRACE'])
prior = trace.read_text().splitlines() if trace.exists() else []
with trace.open('a') as stream:
    stream.write(str(out) + '\n')
if len(prior) + 1 == int(os.environ['FAKE_CAPTURE_FAIL_AT']):
    sys.exit(17)
if out.exists():
    sys.exit(2)
(out / 'thumbs').mkdir(parents=True)
payload = {'entries': [{'id': 'fixture', 'hash': 'fixed', 'meanLuma': 1,
                       'selfMaxDiff': 0, 'deterministic': True}], 'empties': [], 'failures': []}
(out / 'manifest.json').write_text(json.dumps(payload))
(out / 'thumbs/fixture.png').write_bytes(b'fixture pixels')
'''
        executable = repo / ".build/release/WapleCompat"
        executable.parent.mkdir(parents=True)
        executable.write_text(capture)
        executable.chmod(0o700)
        (tools / "swift").write_text(capture)
        (tools / "launchctl").write_text('#!/bin/sh\nshift 2\nexec "$@"\n')
        (tools / "git").write_text('#!/bin/sh\n[ "$1" = status ] || printf "fixture-sha\\n"\n')
        (tools / "swiftc").write_text(f"#!{sys.executable}\n" + r'''import pathlib, sys
out = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
out.write_text('#!/bin/sh\nprintf "0 0\\n"\n')
out.chmod(0o700)
''')
        (tools / "python3").symlink_to(sys.executable)
        for tool in tools.iterdir():
            if not tool.is_symlink():
                tool.chmod(0o700)
        pil = root / "PIL"
        pil.mkdir()
        (pil / "__init__.py").write_text("")
        (pil / "Image.py").write_text(
            "class Image:\n    size = (1, 1)\n"
            "    def convert(self, mode): return self\n"
            "    def getdata(self): return [(1, 2, 3)]\n"
            "def open(path): return Image()\n")
        return repo, output, tools

    def run_script(self, script, root, fail_at=0):
        env = dict(os.environ, WAPLE_REPO=str(root / "repo"),
                   WAPLE_DEV_ROOT=str(root / "corpus"), WAPLE_VERIFY_OUT=str(root / "output"),
                   WAPLE_PROBE_SCENES="fixture", FAKE_CAPTURE_TRACE=str(root / "captures"),
                   FAKE_CAPTURE_FAIL_AT=str(fail_at), PYTHONPATH=str(root),
                   PATH=str(root / "bin") + os.pathsep + os.environ["PATH"])
        args = ([str(root / "output")] if script == "rebaseline-golden.sh" else
                ["fixture", "2", str(root / "output")] if script == "probe-scene-repeat.sh" else [])
        return subprocess.run(["bash", str(ROOT / "scripts/mac-session" / script), *args],
                              env=env, capture_output=True, text=True, timeout=20)

    def test_full_scripts_rerun_in_new_roots_and_preserve_captures_and_baseline(self):
        for script in self.scripts:
            with self.subTest(script=script), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                repo, output, _ = self.fixture(root)
                legacy = output / "runA"
                legacy.mkdir()
                (legacy / "sentinel").write_text("keep")
                first = self.run_script(script, root)
                self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
                if script == "rebaseline-golden.sh":
                    installed = repo / "spec/golden/snapshot/baseline-fixture-sha"
                    (installed / "sentinel").write_text("keep baseline")
                second = self.run_script(script, root)
                self.assertEqual(second.returncode, 1 if script == "rebaseline-golden.sh" else 0,
                                 second.stdout + second.stderr)
                captures = [Path(path) for path in (root / "captures").read_text().splitlines()]
                self.assertGreaterEqual(len(captures), 4)
                self.assertEqual(len(set(captures)), len(captures))
                run_roots = {path.relative_to(output).parts[0] for path in captures}
                self.assertEqual(len(run_roots), 2)
                self.assertTrue(all(path.name.startswith("run.") for path in output.iterdir() if path != legacy))
                self.assertEqual((legacy / "sentinel").read_text(), "keep")
                self.assertTrue(all((path / "manifest.json").is_file() for path in captures))
                if script == "rebaseline-golden.sh":
                    self.assertEqual((installed / "sentinel").read_text(), "keep baseline")

    def test_full_scripts_stop_on_capture_error_without_reusing_old_manifests(self):
        for script in self.scripts:
            failures = (2, 15) if script == "probe-session-nondeterminism.sh" else (2,)
            for fail_at in failures:
                with self.subTest(script=script, fail_at=fail_at), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    repo, output, _ = self.fixture(root)
                    legacy = output / "runA"
                    legacy.mkdir()
                    (legacy / "manifest.json").write_text("legacy sentinel")
                    result = self.run_script(script, root, fail_at=fail_at)
                    self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
                    captures = (root / "captures").read_text().splitlines()
                    self.assertEqual(len(captures), fail_at)
                    self.assertEqual((legacy / "manifest.json").read_text(), "legacy sentinel")
                    self.assertFalse(list(output.rglob("nondet.json")))
                    self.assertFalse(list(output.rglob("session-compare.json")))
                    self.assertFalse((repo / "spec/golden/snapshot/baseline-fixture-sha").exists())


class TestXrefSectionEnds(unittest.TestCase):
    def setUp(self):
        self.tool = load("scripts/re/xref.py")
        self.base = 0x140000000
        self.target = self.base + 0x10000

    def section(self, data, name=".text"):
        return [dict(name=name, raw=0, rawEnd=len(data), va=self.base)]

    def instruction(self, prefix, size):
        offset = size - len(prefix) - 4
        instruction = prefix + struct.pack("<i", self.target - (self.base + size))
        return b"\x90" * offset + instruction, offset

    def test_last_aligned_pointer_in_minimum_and_full_sections(self):
        for size in (8, 16, 512):
            data = b"\0" * (size - 8) + struct.pack("<Q", self.target)
            self.assertEqual(self.tool.ptr_refs(data, self.section(data, ".rdata"), [self.target]),
                             [(self.base + size - 8, self.target, ".rdata")])

    def test_last_complete_lea_and_mov_variants(self):
        prefixes = (b"\x8b\x05", b"\x48\x8b\x05", b"\x0f\xb6\x05", b"\x48\x0f\xb7\x05")
        for prefix in prefixes:
            for size in (len(prefix) + 4, 512):
                with self.subTest(prefix=prefix, size=size):
                    data, offset = self.instruction(prefix, size)
                    refs = self.tool.mov_refs(data, self.section(data), {self.target: "target"})
                    self.assertEqual([ref[:2] for ref in refs], [(self.base + offset, self.target)])
                    truncated = data[:-1]
                    self.assertEqual(self.tool.mov_refs(truncated, self.section(truncated), {self.target: "target"}), [])
        for size in (7, 512):
            data, offset = self.instruction(b"\x48\x8d\x05", size)
            self.assertEqual(self.tool.lea_refs(data, self.section(data), [self.target]),
                             [(self.base + offset, self.target)])
            truncated = data[:-1]
            self.assertEqual(self.tool.lea_refs(truncated, self.section(truncated), [self.target]), [])


class TestExplicitVACitationBinary(unittest.TestCase):
    def test_explicit_binary_is_loaded_without_default_image(self):
        tool = load("scripts/re/va_citations.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary = root / "explicit.exe"
            binary.write_bytes(b"fixture")
            doc = root / "notes.md"
            doc.write_text("fixture without citations\n")
            disasm = types.SimpleNamespace(BIN=str(root / "missing-default.exe"))
            disasm.load = mock.Mock(return_value=(b"", []))
            capstone = types.SimpleNamespace(Cs=lambda *args: object(), CS_ARCH_X86=1, CS_MODE_64=2)
            with mock.patch.dict(sys.modules, capstone=capstone, disasm=disasm), \
                    mock.patch.object(tool, "pdata_functions", return_value=[(1, 2)]), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(tool.main(["va", "--binary", str(binary), str(doc)]), 0)
            self.assertEqual(disasm.BIN, str(binary))
            disasm.load.assert_called_once_with()

    def test_missing_explicit_binary_fails_before_optional_prerequisites(self):
        tool = load("scripts/re/va_citations.py")
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(sys.modules, capstone=None), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(tool.main(["va", "--binary", str(Path(tmp) / "missing.exe")]), 1)


if __name__ == "__main__":
    unittest.main()
