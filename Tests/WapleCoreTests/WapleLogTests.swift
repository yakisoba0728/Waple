import XCTest
@testable import WapleCore

final class WapleLogTests: XCTestCase {
    private var savedHandler: ((String) -> Void)!

    override func setUp() {
        super.setUp()
        savedHandler = WapleLog.warnHandler
    }

    override func tearDown() {
        WapleLog.warnHandler = savedHandler  // 프로세스 전역 static — 반드시 원복(다른 테스트 오염 방지).
        super.tearDown()
    }

    func testWarnRoutesToHandler() {
        var captured: [String] = []
        WapleLog.warnHandler = { captured.append($0) }
        WapleLog.warn("hello")
        WapleLog.warn("world \(42)")
        XCTAssertEqual(captured, ["hello", "world 42"])
    }

    func testDefaultHandlerIsInstalled() {
        // 교체하지 않은 상태에서 warn 호출이 크래시 없이 통과(기본 NSLog 경로).
        WapleLog.warn("[Waple] test default sink")
    }
}
