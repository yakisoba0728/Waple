"""WapleSaver 재시작 수명주기 계약.

WapleSaver는 SwiftPM 밖에서 ``package-app.sh``가 직접 컴파일하므로 XCTest 타깃으로
인스턴스화할 수 없다. 이 테스트는 번들 소스의 start/stop 계약을 고정한다: 같은 설정으로
``startAnimation``이 반복돼도 AVPlayer를 다시 만들지 않고, 경로·재생 가능 상태·같은
경로의 파일 정체성이 바뀐 경우에만 콘텐츠를 다시 적재해야 한다.

실행: ``python3 -m unittest scripts.dev.tests.test_waple_saver_lifecycle``
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "Sources" / "WapleSaver" / "WapleSaverView.m"


def method_body(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"unterminated Objective-C method: {signature}")


class WapleSaverLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_start_reuses_content_when_configuration_is_unchanged(self) -> None:
        start = method_body(self.source, "- (void)startAnimation")
        self.assertIn("[self reloadContentIfNeeded]", start)
        self.assertNotIn("[self loadContent]", start)

        reload = method_body(self.source, "- (void)reloadContentIfNeeded")
        self.assertIn("isEqualToString:self.loadedVideoPath", reload)
        self.assertIn("self.player != nil", reload)
        self.assertIn("return;", reload)
        self.assertIn("[self loadContentForPath:path]", reload)

    def test_same_path_replacement_invalidates_the_cached_player(self) -> None:
        """stable workshop reimport는 경로를 유지한 채 파일을 교체할 수 있다."""
        reload = method_body(self.source, "- (void)reloadContentIfNeeded")
        load = method_body(self.source, "- (void)loadContentForPath:(NSString *)path")
        teardown = method_body(self.source, "- (void)tearDownContent")

        self.assertIn("videoFileIdentityForPath", reload)
        self.assertIn("loadedVideoIdentity", reload)
        self.assertIn("isEqual:", reload)
        self.assertIn("loadedVideoIdentity", load)
        self.assertIn("loadedVideoIdentity = nil", teardown)


if __name__ == "__main__":
    unittest.main()
