import XCTest
@testable import WapleRender
import WapleCore

/// stage 3① — `WallpaperRenderer` 의 음량면(`setPolicyMuted(_:)` · `isPlayingAudio`).
///
/// 여기서 검증하는 것은 **순수 규칙과 마운트 전 안전성**뿐이다. 실제 소리가 나는지, JS 가
/// 페이지에서 먹는지는 이 컨테이너에서도 CI 러너에서도 볼 수 없다 — 그 경계를 흐리지 않으려고
/// 파일을 따로 둔다. `SceneAudioPlayer` 의 실제 재생 경로는 `SceneAudioPlayerTests` 가 본다.
///
/// `@MainActor`: 세 렌더러가 전부 메인 액터로 격리돼 있어(명시 표기 또는 `@MainActor` 프로토콜
/// 적합에 의한 추론) static 멤버까지 격리된다. **`override func setUp()/tearDown()` 을 넣지 마라** —
/// 리눅스 swift-corelibs-xctest 에서 그 오버라이드가 nonisolated 로 고정돼 타입체크가 깨진다
/// (`RENDER_TEST_EXCLUDED` 의 `VideoLiveSettingsTests` 와 같은 부류).
@MainActor
final class PlaybackMuteSurfaceTests: XCTestCase {

    // MARK: - VideoRenderer — 사용자 음량과 정책 음소거의 합성

    /// **정책 음소거는 사용자 음량을 덮지 않는다.** 두 층이라 합성만 하고, 정책을 풀면
    /// 사용자 값이 그대로 돌아온다. 이 규칙이 값 하나를 덮어쓰는 구현으로 바뀌면
    /// 음소거 해제가 "사용자가 0으로 둔 배경을 소리 나게" 만든다.
    func testPolicyMuteComposesWithUserVolumeWithoutOverwritingIt() {
        XCTAssertTrue(VideoRenderer.effectiveMute(volume: 0.8, policyMuted: true),
                      "정책이 요구하면 음량이 있어도 음소거")
        XCTAssertFalse(VideoRenderer.effectiveMute(volume: 0.8, policyMuted: false),
                       "정책을 풀면 사용자 음량이 그대로 살아난다")
    }

    /// 사용자가 0(기본값)으로 둔 배경은 **정책과 무관하게** 계속 음소거다 —
    /// 음소거 해제가 소리를 켜는 스위치가 되면 안 된다(바탕화면이 예고 없이 소리 내는 부류).
    func testUserMutedWallpaperStaysMutedWhenPolicyReleasesMute() {
        XCTAssertTrue(VideoRenderer.effectiveMute(volume: 0, policyMuted: false))
        XCTAssertTrue(VideoRenderer.effectiveMute(volume: 0, policyMuted: true))
        XCTAssertTrue(VideoRenderer.effectiveMute(volume: -0.1, policyMuted: false), "음수도 무음")
    }

    // MARK: - 마운트 전 안전성
    //
    // `AppDelegate` 는 렌더러 교체 직후에도 정책을 밀고(엣지 추적 리셋), 조건 폴링은 1초마다
    // `isPlayingAudio` 를 읽는다. 두 경로 다 **마운트되지 않은 렌더러**를 만날 수 있다.

    func testUnmountedVideoRendererIsSilentAndAcceptsMute() {
        let renderer = VideoRenderer()
        XCTAssertFalse(renderer.isPlayingAudio, "플레이어가 없으면 소리를 낼 수 없다")
        renderer.setPolicyMuted(true)
        XCTAssertFalse(renderer.isPlayingAudio)
        renderer.setPolicyMuted(false)
        XCTAssertFalse(renderer.isPlayingAudio, "마운트 전에는 음소거를 풀어도 여전히 무음이다")
    }

    func testUnmountedWebRendererIsSilentAndAcceptsMute() {
        let renderer = WebRenderer(mode: .web)
        XCTAssertFalse(renderer.isPlayingAudio, "webView 가 없으면 소리를 낼 수 없다")
        renderer.setPolicyMuted(true)
        XCTAssertFalse(renderer.isPlayingAudio)
        renderer.teardown()
    }

    func testUnmountedSceneRendererIsSilentAndAcceptsMute() {
        let renderer = SceneRenderer()
        XCTAssertFalse(renderer.isPlayingAudio, "sceneAudio 가 없으면(헤드리스 포함) 무음이다")
        renderer.setPolicyMuted(true)
        XCTAssertFalse(renderer.isPlayingAudio)
    }

    /// **음소거는 멱등이어야 한다.** 조건 폴링이 1초마다 도는데, 호출부의 엣지 추적이
    /// 실패해도 같은 값을 두 번 받는 것으로 상태가 흔들리면 안 된다.
    func testRepeatedMuteCallsAreIdempotent() {
        let renderer = VideoRenderer()
        renderer.setPolicyMuted(true)
        renderer.setPolicyMuted(true)
        renderer.setPolicyMuted(false)
        renderer.setPolicyMuted(false)
        XCTAssertFalse(renderer.isPlayingAudio)
    }

    // MARK: - WebRenderer 음소거 주입
    //
    // 실제 페이지에서 먹는지는 여기서 볼 수 없다(WKWebView 도 문서도 없다). 볼 수 있는 것은
    // **주입 문자열이 무엇을 약속하는가** 이고, 그 약속 셋이 사라지면 조용히 안 먹는다.

    func testMuteJSCarriesTheRequestedState() {
        XCTAssertTrue(WebRenderer.muteJS(true).contains("window.__wapleMuted = true"))
        XCTAssertTrue(WebRenderer.muteJS(false).contains("window.__wapleMuted = false"))
    }

    /// `<video>` 와 `<audio>` **둘 다** 본다. 하나만 보면 오디오 전용 벽지가 정책을 무시한다.
    func testMuteJSTargetsBothMediaElementKinds() {
        let js = WebRenderer.muteJS(true)
        XCTAssertTrue(js.contains("querySelectorAll('video, audio')"))
        XCTAssertTrue(js.contains("el.muted = true"))
    }

    /// **우리가 켠 음소거만 우리가 끈다.**
    ///
    /// 폴백 HTML 은 사용자 음량이 0 이면 `<video muted>` 로 심는다. 정책 해제가 그 비트를
    /// 그냥 지우면 사용자가 음소거해 둔 배경이 **최대 음량으로** 소리를 낸다(`<video>` 의
    /// `volume` 기본값은 1 이다). 그래서 요소마다 정책 이전 값을 적어 두고 그 값으로 되돌린다.
    func testMuteJSRestoresTheAuthoredMutedStateInsteadOfUnmutingBlindly() {
        for js in [WebRenderer.muteJS(true), WebRenderer.muteJS(false)] {
            XCTAssertTrue(js.contains("__wapleWasMuted"),
                          "정책 이전 값을 기록하지 않으면 해제가 사용자 음소거를 지운다")
            XCTAssertTrue(js.contains("el.muted = el.__wapleWasMuted"),
                          "해제는 기록한 값으로 되돌려야 한다")
            XCTAssertFalse(js.contains("el.muted = false"),
                           "무조건 false 대입은 사용자가 음소거해 둔 배경을 소리 나게 만든다")
        }
    }

    /// **나중에 생기는 요소까지 따라가야 한다.** 웹 벽지는 `<video>` 를 스크립트로 붙이는 것이
    /// 흔하고, 폴백 HTML 조차 `onerror` 에서 `src` 를 재설정한다. 한 번 훑고 끝내면 그 뒤에
    /// 생긴 요소가 정책을 무시한 채 소리를 낸다.
    func testMuteJSInstallsAMutationObserverForLateElements() {
        let js = WebRenderer.muteJS(true)
        XCTAssertTrue(js.contains("MutationObserver"))
        XCTAssertTrue(js.contains("subtree: true"))
    }

    /// **`volume` 을 건드리지 않는다.** 사용자 음량은 페이지가 들고 있으므로(폴백 HTML 의
    /// volumeScript, 웹 벽지의 자체 설정) 정책이 그 값을 덮으면 음소거를 풀 때 되돌릴 원본이
    /// 없다. `muted` 는 그 위에 겹치는 별개 비트라 정확히 우리가 원하는 층이다.
    func testMuteJSNeverWritesPageVolume() {
        XCTAssertFalse(WebRenderer.muteJS(true).contains(".volume ="))
        XCTAssertFalse(WebRenderer.muteJS(false).contains(".volume ="))
    }
}
