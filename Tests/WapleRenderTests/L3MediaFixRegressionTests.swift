import XCTest
@testable import WapleRender

/// L3 라운드에서 고친 동작 세 건의 오라클(전부 순수 함수 — 창·GPU·플레이어 불요).
///
/// 파일을 새로 만든 이유는 단순하다: 같은 라운드에서 여러 레인이 동시에 고치는 중이라
/// 기존 스위트 끝에 붙이면 그 자리가 전부 충돌한다. 내용상 형제는
/// `MediaFixRegressionTests`(디헤드럴) · `VideoFallbackHTMLTests`(폴백 HTML) 다.
@MainActor
final class L3MediaFixRegressionTests: XCTestCase {

    // MARK: r3-M13 — 미러 + 90°/270° 분류가 뒤바뀌어 있었다
    //
    // 소스 수정(`VideoTrackOrientation.classify` 의 미러 두 행 교환)은 이 라운드에서 했지만
    // **오라클은 여기 없다.** 같은 라운드에 다른 레인이
    // `MediaFixRegressionTests.testVideoTrackOrientationClassifiesDihedralTransforms` 를
    // 8원소 전수 + 단사성까지 확장하며 같은 값을 독립적으로 잠갔다(두 유도가 일치한다).
    // 같은 단언을 두 벌 두면 갈라지므로 여기서는 중복하지 않는다.

    // MARK: r3-M14 — videoFallback 이 배속을 한 번도 적용하지 않았다

    /// 등속(1×)은 종전과 **바이트 동일**이어야 한다 — 스크립트를 넣지 않는다(무회귀).
    func testFallbackHTMLOmitsRateScriptAtUnitRate() {
        let html = VideoFallbackHTML.html(forVideoFile: "clip.webm", rate: 1)
        XCTAssertFalse(html.contains("playbackRate"))
        XCTAssertEqual(html, VideoFallbackHTML.html(forVideoFile: "clip.webm"))
    }

    /// 등속이 아니면 `playbackRate` 와 `defaultPlaybackRate` 를 **둘 다** 심는다 —
    /// watchdog 의 `onerror` 가 `src` 를 재설정하면 전자는 후자로 리셋되기 때문이다.
    func testFallbackHTMLEmbedsBothRateProperties() {
        let html = VideoFallbackHTML.html(forVideoFile: "clip.webm", rate: 1.5)
        XCTAssertTrue(html.contains("v.playbackRate=1.500"))
        XCTAssertTrue(html.contains("v.defaultPlaybackRate=1.500"))
    }

    // MARK: r2-H8 — 라이브 반영 주입문

    /// 정책 음소거 중에는 `muted` 를 직접 쓰지 않고 `__wapleWasMuted`(정책 이전 값)만 갱신한다 —
    /// `muteJS` 가 해제 시 그 값으로 되돌리므로, 두 층이 같은 비트를 다투면 방금 올린 음량이
    /// 정책 해제와 함께 사라진다.
    func testLiveMediaJSKeepsPolicyMuteLayerSeparate() {
        let muted = WebRenderer.liveMediaJS(volume: 0.5, rate: 1, policyMuted: true)
        XCTAssertTrue(muted.contains("el.volume = 0.500"))
        XCTAssertTrue(muted.contains("el.__wapleWasMuted = false"))
        XCTAssertTrue(muted.contains("el.muted = true"))

        let audible = WebRenderer.liveMediaJS(volume: 0.5, rate: 2, policyMuted: false)
        XCTAssertTrue(audible.contains("el.__wapleWasMuted = undefined"))
        XCTAssertTrue(audible.contains("el.muted = false"))
        XCTAssertTrue(audible.contains("el.playbackRate = 2.000"))

        // 사용자 음량 0 = 사용자가 고른 음소거. 정책과 무관하게 그 의도가 보존돼야 한다.
        XCTAssertTrue(WebRenderer.liveMediaJS(volume: 0, rate: 1, policyMuted: false)
            .contains("el.muted = true"))
    }
}
