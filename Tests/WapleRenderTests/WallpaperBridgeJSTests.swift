import XCTest
@testable import WapleRender

/// 주입 JS 브리지의 문자열 규약 스모크(이전 커버리지 0). WE 리스너 등록 함수·미디어 상수·디스패치
/// 진입점이 소스에 존재하는지 확인 — 리팩터 중 규약 유실을 조기 감지(런타임 WKWebView 불요).
final class WallpaperBridgeJSTests: XCTestCase {
    func testSourceIsIIFEAndDeclaresContract() {
        let s = WallpaperBridgeJS.source
        XCTAssertTrue(s.contains("(function"), "즉시실행 함수(IIFE) 래핑")

        let requiredTokens = [
            // WE 리스너 등록 API
            "wallpaperRegisterAudioListener",
            "wallpaperPropertyListener",
            "applyUserProperties",
            "applyGeneralProperties",
            "wallpaperRequestRandomFileForProperty",
            "wallpaperRegisterMediaStatusListener",
            "wallpaperRegisterMediaPropertiesListener",
            "wallpaperRegisterMediaThumbnailListener",
            "wallpaperRegisterMediaTimelineListener",
            "wallpaperRegisterMediaPlaybackListener",
            "wallpaperReady",
            "__wapleDirectoryFilesAddedOrChanged",
            // 미디어 상수
            "wallpaperMediaIntegration",
            "PLAYBACK_STOPPED", "PLAYBACK_PLAYING", "PLAYBACK_PAUSED",
            // 네이티브→JS 디스패치 진입점
            "__wapleAudio", "__wapleApplyProps", "__wapleMouse", "__wapleMedia",
        ]
        for token in requiredTokens {
            XCTAssertTrue(s.contains(token), "브리지 JS 규약 누락: \(token)")
        }
    }

    func testMediaPlaybackConstantsMatchNativeEnum() {
        // JS 상수 값이 NowPlayingInfo.State rawValue 와 일치해야 웹 미디어 상태가 올바르다.
        let s = WallpaperBridgeJS.source
        XCTAssertTrue(s.contains("PLAYBACK_STOPPED: \(NowPlayingInfo.State.stopped.rawValue)"))
        XCTAssertTrue(s.contains("PLAYBACK_PLAYING: \(NowPlayingInfo.State.playing.rawValue)"))
        XCTAssertTrue(s.contains("PLAYBACK_PAUSED: \(NowPlayingInfo.State.paused.rawValue)"))
    }

    func testBridgeShimsCorpusWebFeatures() {
        let s = WallpaperBridgeJS.source
        XCTAssertTrue(s.contains("audioListen"))
        XCTAssertTrue(s.contains("audioUnlisten"))
        XCTAssertTrue(s.contains("lastMedia"))
        XCTAssertTrue(s.contains("serviceWorker"))
        XCTAssertTrue(s.contains("register: function"))
    }

    func testBridgeContainsLifecycleCallbackNames() {
        let s = WallpaperBridgeJS.source
        XCTAssertTrue(s.contains("wallpaperWillGoBackground"))
        XCTAssertTrue(s.contains("wallpaperWillGoForeground"))
    }
}

extension WallpaperBridgeJSTests {
    /// 클릭 재게시 진입점 존재(데스크탑 창은 실이벤트 차단 — 합성 click 규약).
    func testClickDispatchEntryPointExists() {
        XCTAssertTrue(WallpaperBridgeJS.source.contains("__wapleEvent"))
        XCTAssertTrue(WallpaperBridgeJS.source.contains("__wapleClick"))  // 하위 호환
        XCTAssertTrue(WallpaperBridgeJS.source.contains("elementFromPoint"))
    }
}
