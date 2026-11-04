"""Native public-callback regression for the separately built Objective-C saver (macOS only)."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]

@unittest.skipUnless(sys.platform == "darwin", "requires native macOS ScreenSaver/AppKit")
class WapleSaverNativeTests(unittest.TestCase):
    def test_public_callbacks_and_bundle_localization(self):
        with tempfile.TemporaryDirectory(prefix="waple-saver-native-") as temporary:
            app = Path(temporary) / "SaverTest.app"
            macos = app / "Contents/MacOS"
            resources = app / "Contents/Resources"
            macos.mkdir(parents=True)
            resources.mkdir()
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "SaverTest", "CFBundleIdentifier": "kr.yaki.waple.saver.test",
                "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "ko",
            }))
            for language in ("ko", "en"):
                shutil.copytree(ROOT / f"Sources/WapleSaver/Resources/{language}.lproj", resources / f"{language}.lproj")
            binary = macos / "SaverTest"
            subprocess.run(["xcrun", "clang", "-fobjc-arc", "-mmacosx-version-min=13.0",
                            "-framework", "AppKit", "-framework", "AVFoundation", "-framework", "CoreMedia",
                            "-framework", "QuartzCore", "-framework", "ScreenSaver",
                            str(ROOT / "scripts/dev/tests/WapleSaverLifecycleDriver.m"), "-o", str(binary)],
                           check=True, capture_output=True, text=True)
            video = Path(temporary) / "fixture.mp4"
            video.write_bytes(b"controlled AVPlayer boundary")
            for language in ("ko", "en"):
                result = subprocess.run([str(binary), str(video), language, "-AppleLanguages", f"({language})"],
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f"SAVER_LIFECYCLE_OK {language}", result.stderr)
