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


def squash(text: str) -> str:
    """공백/줄바꿈만 단일 스페이스로 정규화 — 구문의 **모양**을 한 문자열로 잠그기 위한 것."""
    return " ".join(text.split())


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

    # [정정 2026-09-01] **이 스위트는 게이트를 부정으로 뒤집어도 통과했다.**
    # 종전 단언은 부분문자열을 서로 **따로** 봤다(`isEqualToString:self.loadedVideoPath`,
    # `self.player != nil`, `return;`, `[self loadContentForPath:path]`). 그 넷은
    # `reloadContentIfNeeded` 의 조기반환 게이트를 `if (!(... && ... && ...)) { return; }`
    # 로 뒤집어도 소스에 그대로 남는다 — 재적재 조건이 정확히 반대가 되는데 초록이었다.
    # (`.m` 을 SwiftPM 타깃으로 인스턴스화할 수 없다는 사정은 그대로다. 그래서 텍스트
    #  검사 자체는 유지하되, **구문의 모양 전체**를 공백만 정규화한 하나의 연속 문자열로
    #  잠근다. 극성·피연산자·폴스루가 한 덩어리라 뒤집으면 반드시 깨진다.)

    def test_start_reuses_content_when_configuration_is_unchanged(self) -> None:
        start = method_body(self.source, "- (void)startAnimation")
        self.assertIn("[self reloadContentIfNeeded]", start)
        self.assertNotIn("[self loadContent]", start)

        reload = squash(method_body(self.source, "- (void)reloadContentIfNeeded"))
        # 조기반환 게이트 — 네 조건의 **논리곱**이고, 부정이 붙지 않는다.
        self.assertIn(
            "if (self.hasLoadedContent && samePath && sameIdentity && contentMatchesState) "
            "{ return; }",
            reload,
        )
        # 피연산자의 정의까지 함께 잠근다 — 이름만 남기고 뜻을 뒤집으면 위 게이트는 그대로다.
        self.assertIn(
            "BOOL samePath = (path == nil && self.loadedVideoPath == nil) "
            "|| [path isEqualToString:self.loadedVideoPath];",
            reload,
        )
        self.assertIn("BOOL playable = [self isPlayableVideoPath:path];", reload)
        self.assertIn(
            "BOOL contentMatchesState = (playable && self.player != nil) "
            "|| (!playable && self.player == nil);",
            reload,
        )
        # 게이트를 빠져나가면 **무조건** 재적재한다(메서드의 마지막 문장) — 조건부로 감싸면
        # 설정이 바뀌었는데도 조용히 옛 콘텐츠가 남는다.
        self.assertTrue(
            reload.endswith("[self loadContentForPath:path];"),
            f"reloadContentIfNeeded 가 무조건 재적재로 끝나지 않는다: ...{reload[-80:]!r}",
        )

    def test_same_path_replacement_invalidates_the_cached_player(self) -> None:
        """stable workshop reimport는 경로를 유지한 채 파일을 교체할 수 있다."""
        reload = squash(method_body(self.source, "- (void)reloadContentIfNeeded"))
        load = squash(method_body(self.source, "- (void)loadContentForPath:(NSString *)path"))
        teardown = squash(method_body(self.source, "- (void)tearDownContent"))

        # 정체성 비교의 모양 — `!playable` 단락과 nil 가드가 함께 있어야 "정체성을 못 읽으면
        # 다시 적재한다" 가 성립한다. 종전엔 세 토큰을 따로 봐서 어떤 배치든 통과했다.
        self.assertIn(
            "NSDictionary *videoIdentity = playable ? [self videoFileIdentityForPath:path] : nil;",
            reload,
        )
        self.assertIn(
            "BOOL sameIdentity = !playable || (videoIdentity != nil "
            "&& [videoIdentity isEqual:self.loadedVideoIdentity]);",
            reload,
        )
        # 적재는 정체성을 **기록**하고, 해제는 **버린다** — 둘 중 하나만 빠져도 같은 경로의
        # 파일 교체가 영원히 캐시된 플레이어로 재생된다.
        self.assertIn("self.loadedVideoIdentity = [self videoFileIdentityForPath:path];", load)
        self.assertIn("self.loadedVideoIdentity = nil;", teardown)
        self.assertIn("self.hasLoadedContent = NO;", teardown)


if __name__ == "__main__":
    unittest.main()
