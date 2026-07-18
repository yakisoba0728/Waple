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
        // F394: 종전엔 XCTAssert 가 0개라 "크래시 없음"만이 유일한 오라클이었다 — 기본(교체 전) 핸들러를
        // 원본으로 감싸는 스파이로 바꿔치기해 warn() 이 정확히 그 핸들러를 1회 거쳐가는지, 원본(NSLog
        // 경로)도 실제로 호출되며 크래시 없이 통과하는지, 메시지가 그대로 전달되는지를 단언한다
        // (NSLog 자체의 시스템 로그 출력은 XCTest 에서 직접 가로챌 수 없어 이 정도가 실질적 상한).
        let original = savedHandler!
        var callCount = 0
        var lastMessage: String?
        WapleLog.warnHandler = { msg in
            callCount += 1
            lastMessage = msg
            original(msg)   // 기본 NSLog 경로도 실제로 호출 — 크래시 없이 통과해야 함
        }
        WapleLog.warn("[Waple] test default sink")
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(lastMessage, "[Waple] test default sink")
    }
}
