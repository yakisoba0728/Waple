import XCTest
@testable import Waple

/// 렌더 일시정지 사유 합성(PauseGate) 검증. AppDelegate 의 가림·수동·슬립 세 경로가 모두 이
/// 타입을 실제로 호출한다(병렬 사본 아님) — 여기서 통과하면 세 사유가 서로를 덮어쓰지 않음이 보장된다.
final class PauseGateTests: XCTestCase {

    // MARK: - 단일 사유 엣지(none↔some 경계에서만 pause/resume)

    func testSleep_pausesOnEnter_resumesOnExit() {
        var g = PauseGate()
        XCTAssertEqual(g.set(.sleep, active: true), .pause, "무사유→슬립 = 정지")
        XCTAssertEqual(g.set(.sleep, active: false), .resume, "슬립 해제(다른 사유 없음) = 재개")
    }

    func testOcclusion_regression_pausesAndResumes() {
        var g = PauseGate()
        XCTAssertEqual(g.set(.occlusion, active: true), .pause)
        XCTAssertEqual(g.set(.occlusion, active: false), .resume)
    }

    func testRedundantSet_isNoOp() {
        var g = PauseGate()
        XCTAssertEqual(g.set(.sleep, active: true), .pause)
        XCTAssertEqual(g.set(.sleep, active: true), .none, "이미 정지 중 같은 사유 재설정 = 무동작")
        XCTAssertEqual(g.set(.sleep, active: false), .resume)
        XCTAssertEqual(g.set(.sleep, active: false), .none, "이미 재생 중 해제 = 무동작")
    }

    // MARK: - 상태 충돌(핵심): 수동 일시정지 중 슬립→웨이크가 수동을 덮어쓰지 않는다

    func testManualPause_survivesSleepWakeCycle() {
        var g = PauseGate()
        XCTAssertEqual(g.set(.manual, active: true), .pause, "수동 일시정지")
        XCTAssertEqual(g.set(.sleep, active: true), .none, "이미 정지 중 슬립 = 렌더 무동작")
        XCTAssertEqual(g.set(.sleep, active: false), .none, "웨이크했지만 수동이 남아 재개 안 함")
        XCTAssertTrue(g.isPaused, "여전히 정지")
        XCTAssertTrue(g.isActive(.manual), "수동 상태 보존")
    }

    /// 종전 pairwise 가드 버그(resumeFromOcclusion 이 sleep 을 몰랐음)의 회귀 방지:
    /// 슬립 중 가림이 해제돼도 재개하면 안 된다.
    func testOcclusionCleared_whileSleeping_staysPaused() {
        var g = PauseGate()
        _ = g.set(.sleep, active: true)
        XCTAssertEqual(g.set(.occlusion, active: true), .none)
        XCTAssertEqual(g.set(.occlusion, active: false), .none, "슬립이 남아 있으면 재개 금지")
        XCTAssertTrue(g.isPaused)
    }

    func testMultipleReasons_resumeOnlyWhenLastCleared() {
        var g = PauseGate()
        XCTAssertEqual(g.set(.manual, active: true), .pause)
        XCTAssertEqual(g.set(.occlusion, active: true), .none)
        XCTAssertEqual(g.set(.manual, active: false), .none, "가림이 남아 정지 유지")
        XCTAssertEqual(g.set(.occlusion, active: false), .resume, "마지막 사유 해제 = 재개")
    }

    // MARK: - 토글(수동 일시정지 메뉴/하단 바)

    func testToggleManual_flipsAndActs() {
        var g = PauseGate()
        var r = g.toggle(.manual)
        XCTAssertTrue(r.active); XCTAssertEqual(r.action, .pause)
        r = g.toggle(.manual)
        XCTAssertFalse(r.active); XCTAssertEqual(r.action, .resume)
    }

    func testToggleManual_whileOccluded_noRenderAction() {
        var g = PauseGate()
        _ = g.set(.occlusion, active: true)
        var r = g.toggle(.manual)
        XCTAssertTrue(r.active); XCTAssertEqual(r.action, .none, "이미 가림 정지 중 = 렌더 무동작")
        r = g.toggle(.manual)
        XCTAssertFalse(r.active); XCTAssertEqual(r.action, .none, "가림이 남아 재개 안 함")
        XCTAssertTrue(g.isPaused)
    }

    // MARK: - F040: UI 미러는 사유별 플래그가 아니라 isPaused(전체)를 봐야 한다

    /// 트레이/하단 바가 종전처럼 `isActive(.manual)`(또는 toggle 의 `active`)만 보고 "정지 여부"를
    /// 판단하면, 가림으로 실제 정지 중인데도 수동 사유가 꺼져 있다는 이유만으로 "재생 중"이라고
    /// 오표시한다. AppDelegate.menuNeedsUpdate/toggleGlobalPause 는 이제 `isPaused`(사유 무관)를 쓴다 —
    /// 이 테스트는 그 근거인 두 신호의 괴리를 명시적으로 고정한다.
    func testIsPaused_diverges_fromManualOnlySignal_whileOccludedAndManualOff() {
        var g = PauseGate()
        _ = g.set(.occlusion, active: true)     // 가림으로 정지(사유: occlusion)
        _ = g.toggle(.manual)                   // 수동 켬(렌더 무동작 — 이미 정지 중)
        let r = g.toggle(.manual)               // 수동 다시 끔 → manual 사유는 이제 off
        XCTAssertFalse(r.active, "manual 사유 자체는 꺼짐")
        XCTAssertFalse(g.isActive(.manual), "isActive(.manual) 만 보면 '정지 아님'으로 오판(F040 구버전 버그)")
        XCTAssertTrue(g.isPaused, "그러나 가림 사유가 남아 실제로는 계속 정지 — UI 미러는 이 값을 써야 한다")
    }
}
