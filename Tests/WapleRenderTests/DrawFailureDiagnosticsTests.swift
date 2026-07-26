import XCTest
@testable import WapleCore
@testable import WapleRender

/// E1(⑥): draw() 자원 실패 조기 return 경로의 1회성 진단 로그. 종전엔 device/queue/pipeline/drawable/
/// commandBuffer 확보 실패, encode3D/encodeDrawPlan/finalizeScene 실패가 전부 조용히 프레임을 스킵해
/// "화면이 멈췄다/비었다" 증상의 원인 특정이 불가능했다. 60fps 루프에서 매프레임 재실패해도 로그가
/// 폭주하지 않도록 원인별(key) 1회만 로깅한다.
final class DrawFailureDiagnosticsTests: XCTestCase {
    private var savedHandler: ((String) -> Void)!

    override func setUp() {
        super.setUp()
        savedHandler = WapleLog.warnHandler
    }

    override func tearDown() {
        WapleLog.warnHandler = savedHandler  // 프로세스 전역 static — 반드시 원복(다른 테스트 오염 방지).
        super.tearDown()
    }

    func testLogDrawFailureOnceDedupesByKeyButLogsDistinctKeys() {
        var captured: [String] = []
        WapleLog.warnHandler = { captured.append($0) }
        let r = SceneRenderer()

        r.logDrawFailureOnce("resources", "자원 확보 실패")
        r.logDrawFailureOnce("resources", "자원 확보 실패")  // 동일 키 — 재로깅 금지(60fps 스팸 방지)
        r.logDrawFailureOnce("resources", "자원 확보 실패")
        r.logDrawFailureOnce("2d-acc", "2D 오프스크린 확보 실패")  // 다른 키 — 독립적으로 1회 로깅

        XCTAssertEqual(captured.count, 2, "같은 키는 1회만, 다른 키는 각각 1회 로깅돼야")
        XCTAssertTrue(captured[0].contains("자원 확보 실패"))
        XCTAssertTrue(captured[1].contains("2D 오프스크린 확보 실패"))
    }

    /// unmount()는 상태를 리셋해 재마운트 후 동일 원인이 다시 발생하면 다시 1회 진단 로깅한다
    /// (스테일 dedup 키가 새 마운트의 진단을 영구 억제하면 안 됨).
    func testUnmountResetsLoggedDrawFailureKeys() {
        var captured: [String] = []
        WapleLog.warnHandler = { captured.append($0) }
        let r = SceneRenderer()

        r.logDrawFailureOnce("resources", "1차 마운트 실패")
        XCTAssertEqual(captured.count, 1)
        r.teardown()
        r.logDrawFailureOnce("resources", "재마운트 후 실패")
        XCTAssertEqual(captured.count, 2, "teardown 후 동일 키라도 다시 로깅돼야")
    }
}
