import XCTest
@testable import Waple
import WapleCore
import WaplePolicy

/// stage 2c — 전역 사유(`PauseGate`)와 재생정책 판정의 합류, 그리고 엣지 추적.
///
/// 여기 있는 것이 **합류 규칙 전부**다. `AppDelegate` 는 이 결정을 적용만 하므로,
/// "어느 화면이 왜 멈추는가" 는 이 파일이 단독으로 정한다.
final class PlaybackPolicyCompositionTests: XCTestCase {

    private func verdict(stop: Bool = false, muted: Bool = false, pauseMask: UInt32 = 0) -> PlaybackVerdict {
        PlaybackVerdict(stop: stop, muted: muted, pauseMask: pauseMask)
    }

    /// 아무 축도 선언하지 않은 벽지 — 전역 정책이 그대로 적용된다
    /// (`PlaybackPolicyResolver.effective` 는 선언 없는 축을 전역값으로 남긴다).
    private func project(_ id: String) -> WallpaperProject {
        WallpaperProject(id: id, type: .scene, fileName: nil, previewName: nil,
                         title: id, tags: [], contentRating: nil, workshopId: nil,
                         dependency: nil, folderURL: URL(fileURLWithPath: "/tmp/\(id)"))
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

    /// 두 차원이 결정에 **이름으로 남는다.** `policyWantsMute` 는 stage 3① 부터 실제로
    /// 적용되고(`AppDelegate` 가 전 렌더러에 민다), `policyWantsStop` 은 의도적 축소를 센다.
    /// 어느 쪽이든 판정이 결정으로 넘어오는 길에서 사라지면 안 된다.
    func testPolicyDimensionsSurviveIntoTheDecision() {
        let d = RenderPauseComposition.decide(globallyPaused: false,
                                              verdict: verdict(stop: true, muted: true),
                                              monitorIndex: 0)
        XCTAssertTrue(d.policyWantsStop, "stop 요구가 사라지면 축소를 셀 수 없다")
        XCTAssertTrue(d.policyWantsMute, "음소거 요구가 사라지면 적용할 것이 없어진다")
        XCTAssertTrue(d.paused, "stop 은 정지로 축소된다 — 근거는 stopIsReducedToPause 블록")
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

    // MARK: 전역 음소거 접기 (stage 3①)

    /// **화면마다 벽지가 다르면 판정도 갈리는데 WE 의 음소거는 전역이다.** OR 로 접는다 —
    /// AND 로 접으면 화면 하나가 `run` 이라는 이유로 나머지 전부의 음소거가 사라진다.
    func testGlobalMuteIsOrAcrossMonitors() {
        let asks = RenderPauseComposition.decide(globallyPaused: false,
                                                 verdict: verdict(muted: true), monitorIndex: 0)
        let quiet = RenderPauseComposition.decide(globallyPaused: false,
                                                  verdict: .running, monitorIndex: 1)
        XCTAssertTrue(RenderPauseComposition.wantsGlobalMute([asks, quiet]))
        XCTAssertTrue(RenderPauseComposition.wantsGlobalMute([quiet, asks]), "순서에 의존하지 않는다")
        XCTAssertFalse(RenderPauseComposition.wantsGlobalMute([quiet, quiet]))
    }

    /// 렌더러가 없으면 음소거할 것도 없다 — `AppDelegate` 가 빈 배열로 부르는 경로가 있다.
    func testGlobalMuteOfNothingIsFalse() {
        XCTAssertFalse(RenderPauseComposition.wantsGlobalMute([]))
    }

    /// **음소거는 정지를 부르지 않는다** — 접는 함수 쪽에서도 같은 계약이 서야 한다.
    /// `testMuteAloneNeverPauses` 가 결정 하나를 보는 반면 여기는 배열 전체를 본다.
    func testGlobalMuteDoesNotPauseAnything() {
        let all = RenderPauseComposition.decideAll(globallyPaused: false,
                                                    verdict: verdict(muted: true), rendererCount: 3)
        XCTAssertTrue(RenderPauseComposition.wantsGlobalMute(all))
        XCTAssertEqual(all.map(\.paused), [false, false, false])
    }

    // MARK: `stop` 을 정지로 접는다 — 그 근거 (stage 3②)

    /// **왜 `stop` 을 해제·재마운트로 만들지 않았는가 — 그 판단의 근거를 오라클로 못 박는다.**
    ///
    /// WE 기본값은 `playbacksleep = stop` 이고 평가기는 절전 래치에서 실제로 `stop` 을 낸다.
    /// 즉 진짜 해제를 넣으면 **디스플레이가 절전에 들 때마다** 전 화면이 해제되고 깨어날
    /// 때마다 재마운트된다 — 하루에 수십 번, `mount` 가 `throws` 인 경로에서.
    /// 이 단언이 깨지면(예: 기본값이 바뀌어 절전이 더는 stop 이 아니면) 그 판단의 전제가
    /// 사라진 것이므로 `stopIsReducedToPause` 를 다시 검토해야 한다.
    func testWEDefaultStopIsDrivenByDisplaySleep() {
        let asleep = PlaybackEvaluator.evaluate(.weDefault, PlaybackConditions(displayAsleep: true))
        XCTAssertTrue(asleep.stop, "WE 기본값 playbacksleep=stop — 절전마다 stop 이 뜬다")

        XCTAssertFalse(PlaybackEvaluator.evaluate(.weDefault, PlaybackConditions()).stop,
                       "깨어 있으면 stop 이 아니다")
        // 창 상태 축의 WE 기본값은 `pause` 라 최대화·전체화면만으로는 stop 이 뜨지 않는다.
        // 그래서 stop 의 지배적 발동원은 사용자가 아무것도 안 해도 도는 **절전**이다.
        let covered = PlaybackEvaluator.evaluate(
            .weDefault, PlaybackConditions(allMonitorsMask: 0b1, maximizedMask: 0b1, fullscreenMask: 0b1))
        XCTAssertFalse(covered.stop)
        XCTAssertTrue(covered.isPaused(monitorIndex: 0))
    }

    /// 축소는 **결론**이지 미결이 아니다 — 상수와 동작이 같은 말을 하는지 본다.
    func testStopIsDeliberatelyReducedToPause() {
        XCTAssertTrue(RenderPauseComposition.stopIsReducedToPause,
                      "축소를 걷으려면 stopIsReducedToPause 블록의 실기 수치 둘을 먼저 재라")
        let d = RenderPauseComposition.decide(globallyPaused: false,
                                              verdict: verdict(stop: true), monitorIndex: 0)
        XCTAssertTrue(d.paused, "축소되는 동안에도 화면은 반드시 멈춘다 — 무회귀 바닥")
        XCTAssertTrue(d.policyWantsStop, "무엇을 축소했는지는 계속 셀 수 있어야 한다")
    }

    /// **정지 판정은 음소거를 요구하지 않는다.** WE 에서 stop 은 인스턴스 해제라 음소거가
    /// 무의미하고, 평가기도 `muted: false` 를 낸다. 축소된 우리 쪽에서는 `pause()` 가 소리를
    /// 멈추므로 결과가 같다 — 그 등가가 깨지면 절전 중에 소리만 남는다.
    func testStopVerdictNeverRequestsMute() {
        let v = PlaybackEvaluator.evaluate(.weDefault, PlaybackConditions(displayAsleep: true))
        XCTAssertTrue(v.stop)
        XCTAssertFalse(v.muted)
        let all = RenderPauseComposition.decideAll(globallyPaused: false, verdict: v, rendererCount: 2)
        XCTAssertEqual(all.map(\.paused), [true, true])
        XCTAssertFalse(RenderPauseComposition.wantsGlobalMute(all))
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

    // MARK: 전역 1비트 엣지 추적 (stage 3①)

    /// **첫 호출은 무조건 적용한다** — `false` 로 시작하면 새 렌더러(정책을 모르는 상태)에
    /// 아무것도 안 밀어서 음소거가 조용히 사라진다. 초기값이 `nil` 인 것이 그 계약이다.
    func testAppliedFlagAppliesTheFirstValueEvenWhenFalse() {
        var flag = AppliedFlag()
        XCTAssertNil(flag.appliedValue, "아직 아무것도 적용하지 않았다")
        XCTAssertEqual(flag.change(to: false), false, "첫 호출은 값과 무관하게 적용한다")
        XCTAssertNil(flag.change(to: false), "같은 값이면 부를 필요가 없다")
    }

    func testAppliedFlagReportsOnlyEdges() {
        var flag = AppliedFlag()
        _ = flag.change(to: false)
        XCTAssertEqual(flag.change(to: true), true)
        XCTAssertNil(flag.change(to: true))
        XCTAssertEqual(flag.change(to: false), false)
    }

    /// 렌더러 세트가 갈리면 리셋한다 — 새 렌더러는 정책을 모른 채 태어나므로 다시 밀어야 한다.
    func testAppliedFlagResetForcesReapply() {
        var flag = AppliedFlag()
        _ = flag.change(to: true)
        XCTAssertNil(flag.change(to: true))
        flag.reset()
        XCTAssertEqual(flag.change(to: true), true, "리셋 뒤에는 같은 값도 다시 적용한다")
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
        XCTAssertFalse(RenderPauseComposition.wantsGlobalMute(all))
    }

    /// **사용자가 `mute` 를 고르면 아무 화면도 멈추지 않고 소리만 꺼진다.** stage 3① 이
    /// 배선한 축의 끝에서 끝까지 오라클 — 정책·평가기·합류·전역 접기가 전부 이 성질을 지켜야
    /// 소리만 줄이려던 사용자의 벽지가 얼어붙지 않는다.
    func testMuteAxisSilencesWithoutPausingEndToEnd() {
        var policy = PlaybackPolicy.weDefault
        policy.maximized = .mute
        let conditions = PlaybackConditions(allMonitorsMask: 0b11, maximizedMask: 0b10)
        let v = PlaybackEvaluator.evaluate(policy, conditions)
        let all = RenderPauseComposition.decideAll(globallyPaused: false, verdict: v, rendererCount: 2)
        XCTAssertEqual(all.map(\.paused), [false, false], "음소거 축은 아무것도 멈추지 않는다")
        XCTAssertTrue(RenderPauseComposition.wantsGlobalMute(all), "그리고 전 화면이 음소거된다")
    }

    // MARK: 프로덕션이 실제로 부르는 오버로드 — 빈 슬롯 레이아웃 (2026-08-30)
    //
    // **여기 셋이 없던 동안 스큐가 배송됐다.** 위 통합 오라클들은 전부
    // `decideAll(verdict:rendererCount:)` 를 쓰는데 그 오버로드에서는 인덱스 == 배열 위치가
    // 정의상 참이다. 프로덕션이 부르는 것은 `decideAll(projects:conditions:global:)` 하나뿐이고
    // 그쪽에는 오라클이 0건이었다 — 실측: 그 오버로드의 `monitorIndex` 를 전부 0 으로 굳히는
    // 회귀를 넣어도 WapleAppTests 458개가 통째로 통과했다.

    /// **렌더러 배열 위치는 모니터 인덱스가 아니다 — 빈 슬롯 레이아웃을 모델링한다.**
    ///
    /// 화면 2개(`allMonitorsMask: 0b11`), 그중 **화면 1만 마운트**된 상태다. 전역 선택 없이
    /// 화면별 할당만 쓰면(`global == nil` → `MonitorMapping.resolveProjectSlots` 가 nil 슬롯을
    /// 낸다 → `applyResolved` 의 `compactMap` 이 그 화면을 떨어뜨린다) 렌더러가 하나뿐인 이
    /// 레이아웃이 나온다. 그 하나는 **화면 1** 에 있다.
    ///
    /// 다른 앱이 화면 1을 전체화면으로 덮었다(`fullscreenMask: 0b10` — 비트 자리는
    /// `NSScreen.screens` 위치다). WE 기본값 `playbackfullscreen = pause` 이므로 그 렌더러는
    /// **반드시 멈춘다.** 종전에는 배열 위치 0 을 `monitorIndex` 로 먹여 `isPaused(0)` → 비트 0 →
    /// false 를 받아 계속 디코드했다(이 단언이 그때 실패한다 — `[false]` vs `[true]`).
    func testPerProjectDecideAllUsesRealMonitorIndexNotArrayPosition() {
        let conditions = PlaybackConditions(allMonitorsMask: 0b11, fullscreenMask: 0b10)
        let all = RenderPauseComposition.decideAll(
            globallyPaused: false,
            projects: [(monitorIndex: 1, project: project("mounted-on-screen-1"))],
            conditions: conditions,
            global: .weDefault)
        XCTAssertEqual(all.map(\.paused), [true],
                       "빈 슬롯으로 재인덱싱된 배열 위치(0)가 아니라 실제 화면 인덱스(1)로 판정해야 한다")
    }

    /// **대칭 실패도 막는다** — 보이는 화면이 남의 비트를 물려받아 멈추는 쪽.
    /// 위와 같은 레이아웃에서 덮인 것이 화면 0(마운트되지 않은 화면)이면, 살아 있는
    /// 화면 1의 렌더러는 **돌아야 한다.** 배열 위치로 판정하면 `isPaused(0)` → true 로
    /// 아무 일도 없는 화면이 멈춘다.
    func testPerProjectDecideAllDoesNotInheritAnotherScreensPauseBit() {
        let conditions = PlaybackConditions(allMonitorsMask: 0b11, fullscreenMask: 0b01)
        let all = RenderPauseComposition.decideAll(
            globallyPaused: false,
            projects: [(monitorIndex: 1, project: project("mounted-on-screen-1"))],
            conditions: conditions,
            global: .weDefault)
        XCTAssertEqual(all.map(\.paused), [false],
                       "덮인 것은 화면 0(미마운트)이다 — 화면 1의 렌더러가 남의 비트로 멈추면 안 된다")
    }

    /// 인덱스가 배열 위치와 무관하다는 것을 **순서를 뒤집어** 못 박는다. 반환 배열의 순서·길이는
    /// 입력 그대로여야 한다(적용부 `PerRendererPauseState` 가 렌더러 배열 위치로 짝짓는다).
    func testPerProjectDecideAllRespectsGivenIndicesRegardlessOfOrder() {
        let conditions = PlaybackConditions(allMonitorsMask: 0b111, fullscreenMask: 0b100)
        let all = RenderPauseComposition.decideAll(
            globallyPaused: false,
            projects: [(monitorIndex: 2, project: project("A")),
                       (monitorIndex: 0, project: project("B"))],
            conditions: conditions,
            global: .weDefault)
        XCTAssertEqual(all.map(\.paused), [true, false],
                       "덮인 것은 화면 2다 — 첫 항목이 멈추고 순서는 입력 그대로다")
    }
}
