import XCTest
@testable import Waple
import WaplePolicy

/// stage 2c — 전역 사유(`PauseGate`)와 재생정책 판정의 합류, 그리고 엣지 추적.
///
/// 여기 있는 것이 **합류 규칙 전부**다. `AppDelegate` 는 이 결정을 적용만 하므로,
/// "어느 화면이 왜 멈추는가" 는 이 파일이 단독으로 정한다.
final class PlaybackPolicyCompositionTests: XCTestCase {

    private func verdict(stop: Bool = false, muted: Bool = false, pauseMask: UInt32 = 0) -> PlaybackVerdict {
        PlaybackVerdict(stop: stop, muted: muted, pauseMask: pauseMask)
    }

    // MARK: 합류 규칙

    /// 둘 다 조용하면 아무것도 안 멈춘다 — stage 2c 의 무회귀 바닥이다.
    func testNeitherLayerPausesMeansRunning() {
        let d = RenderPauseComposition.decide(globallyPaused: false, verdict: .running, monitorIndex: 0)
        XCTAssertFalse(d.paused)
        XCTAssertFalse(d.policyWantsStop)
        XCTAssertFalse(d.policyWantsMute)
    }

    /// 전역 사유(가림·수동·슬립)는 정책과 무관하게 전 화면을 멈춘다 — 기존 동작 보존.
    func testGlobalReasonPausesEveryMonitorRegardlessOfPolicy() {
        for index in 0..<4 {
            XCTAssertTrue(RenderPauseComposition.decide(globallyPaused: true,
                                                       verdict: .running,
                                                       monitorIndex: index).paused)
        }
    }

    /// 정책은 **해당 화면만** 멈춘다. ③ 안을 고른 이유가 이 단언이다 —
    /// `PauseGate` 의 다섯째 사유로 접었다면 여기서 두 화면이 다 멈춘다.
    func testPolicyPausesOnlyItsOwnMonitor() {
        let v = verdict(pauseMask: 0b10)
        XCTAssertFalse(RenderPauseComposition.decide(globallyPaused: false, verdict: v, monitorIndex: 0).paused)
        XCTAssertTrue(RenderPauseComposition.decide(globallyPaused: false, verdict: v, monitorIndex: 1).paused)
    }

    /// `stop` 은 모니터 마스크와 무관하게 전부를 멈춘다(그 타입이 다른 둘을 가린다).
    func testStopPausesEveryMonitorEvenWithEmptyMask() {
        let v = verdict(stop: true, pauseMask: 0)
        XCTAssertTrue(RenderPauseComposition.decide(globallyPaused: false, verdict: v, monitorIndex: 0).paused)
        XCTAssertTrue(RenderPauseComposition.decide(globallyPaused: false, verdict: v, monitorIndex: 3).paused)
    }

    /// **아직 못 하는 것을 못 한다고 센다.** `stop`·`muted` 는 `WallpaperRenderer` 에 표면이
    /// 없어 적용하지 않는다 — `stop` 은 정지로 축소되고 `muted` 는 아무 일도 안 한다.
    /// 그 격차를 결정이 이름으로 들고 있어야 배선할 때 셀 수 있다.
    func testUnappliedPolicyDimensionsAreReportedNotSilentlyDropped() {
        let d = RenderPauseComposition.decide(globallyPaused: false,
                                              verdict: verdict(stop: true, muted: true),
                                              monitorIndex: 0)
        XCTAssertTrue(d.policyWantsStop, "stop 요구가 사라지면 격차를 셀 수 없다")
        XCTAssertTrue(d.policyWantsMute)
        XCTAssertTrue(d.paused, "지금은 정지로 축소된다 — WE 보다 약하되 무회귀")
    }

    /// 음소거만 요구하는 판정은 **아무것도 멈추지 않는다.** 음소거를 정지로 바꿔치면
    /// 소리만 줄이려던 사용자의 벽지가 얼어붙는다.
    func testMuteAloneNeverPauses() {
        let d = RenderPauseComposition.decide(globallyPaused: false,
                                              verdict: verdict(muted: true),
                                              monitorIndex: 0)
        XCTAssertFalse(d.paused)
        XCTAssertTrue(d.policyWantsMute)
    }

    func testDecideAllMapsIndexToMonitorBit() {
        let all = RenderPauseComposition.decideAll(globallyPaused: false,
                                                   verdict: verdict(pauseMask: 0b101),
                                                   rendererCount: 3)
        XCTAssertEqual(all.map(\.paused), [true, false, true])
    }

    func testDecideAllHandlesZeroRenderers() {
        XCTAssertTrue(RenderPauseComposition.decideAll(globallyPaused: true,
                                                       verdict: .running,
                                                       rendererCount: 0).isEmpty)
    }

    // MARK: 엣지 추적

    /// 폴링이 1초마다 도는데 매번 `pause()` 를 부르면 렌더러가 초당 한 번씩 같은 요청을
    /// 받는다. `PauseGate` 가 경계만 보고하는 것과 같은 이유로 여기도 바뀐 것만 낸다.
    func testUnchangedStateProducesNoCalls() {
        var s = PerRendererPauseState()
        XCTAssertEqual(s.changes([false, false]).count, 2, "첫 호출은 전부 적용")
        XCTAssertTrue(s.changes([false, false]).isEmpty, "같은 상태면 무동작")
    }

    func testOnlyChangedIndicesAreReported() {
        var s = PerRendererPauseState()
        _ = s.changes([false, false, false])
        let c = s.changes([false, true, false])
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.first?.index, 1)
        XCTAssertEqual(c.first?.paused, true)
    }

    /// **렌더러 수가 바뀌면 전부 다시 적용한다.** 모니터 착탈·재적용 뒤에는 같은 인덱스가
    /// 같은 화면을 가리킨다는 보장이 없다 — diff 하면 엉뚱한 화면이 멈춘 채 남는다.
    func testRendererCountChangeForcesFullReapply() {
        var s = PerRendererPauseState()
        _ = s.changes([true, true])
        let c = s.changes([true, true, true])
        XCTAssertEqual(c.count, 3, "수가 바뀌면 diff 하지 않는다")
    }

    func testResetForcesFullReapply() {
        var s = PerRendererPauseState()
        _ = s.changes([true, false])
        s.reset()
        XCTAssertEqual(s.changes([true, false]).count, 2)
    }

    func testShrinkingToZeroIsHandled() {
        var s = PerRendererPauseState()
        _ = s.changes([true, true])
        XCTAssertTrue(s.changes([]).isEmpty)
        XCTAssertEqual(s.appliedCount, 0)
    }

    // MARK: 통합 — 정책부터 렌더러 결정까지

    /// WE 기본값 + "다른 앱이 화면 B 를 전체화면으로 덮음" → B 만 멈춘다.
    /// stage 2a·2b 가 만든 것이 여기까지 이어지는지 한 번에 본다.
    func testWEDefaultsPauseOnlyTheCoveredMonitorEndToEnd() {
        let conditions = PlaybackConditions(allMonitorsMask: 0b11, fullscreenMask: 0b10)
        let v = PlaybackEvaluator.evaluate(.weDefault, conditions)
        let all = RenderPauseComposition.decideAll(globallyPaused: false, verdict: v, rendererCount: 2)
        XCTAssertEqual(all.map(\.paused), [false, true])
    }

    /// 그리고 아무것도 선언하지 않은 사용자가 전역을 전 축 run 으로 두면 무동작이다 —
    /// "정책을 껐다" 가 실제로 꺼짐을 뜻하는지의 오라클.
    func testAllRunGlobalNeverPausesAnything() {
        let conditions = PlaybackConditions(allMonitorsMask: 0b11,
                                            unfocusedMask: 0b11, maximizedMask: 0b11,
                                            fullscreenMask: 0b11, audioPlaying: true,
                                            displayAsleep: true, onBattery: true)
        let v = PlaybackEvaluator.evaluate(.allRun, conditions)
        let all = RenderPauseComposition.decideAll(globallyPaused: false, verdict: v, rendererCount: 2)
        XCTAssertEqual(all.map(\.paused), [false, false])
    }
}
