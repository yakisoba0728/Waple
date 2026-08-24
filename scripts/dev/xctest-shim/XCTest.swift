// XCTest 대역 모듈 — **타입체크 전용**.
//
// 이 머신에는 Xcode 가 없어(CommandLineTools 만) XCTest 모듈이 없다. 그래서 `swift test` 는
// 물론 테스트 타깃의 **타입체크조차** 안 된다. AGENTS.md 가 "`swiftc -parse` 의 rc=0 을 검증
// 근거로 쓰지 마라 — `-parse` 는 타입체크를 하지 않는다" 고 못 박아 둔 그 공백이 여기서도 그대로다.
//
// 리포가 `scripts/dev/linux-shim/` 에서 Metal/AppKit 을 대역 모듈로 세워 리눅스 타입체크를
// 돌리는 것과 **같은 방법론**을 XCTest 에 적용한다. 심이 실물과 다르면 거짓 통과/실패가 나므로
// **최종 판정자는 여전히 macOS CI** 다 — 이건 CI 사이클(12분)을 낭비하지 않기 위한 앞단 게이트다.
@_exported import Foundation
// 실물 XCTest(macOS)는 ObjC 엄브렐라 헤더가 AppKit 을 끌어와 `NSView`·`NSBitmapImageRep` 은 물론
// **`MTLCreateSystemDefaultDevice` 까지** 보이게 만든다(실측: `import AppKit` 한 줄만으로 둘 다 해결).
// 그래서 심도 같은 가시성을 준다 — 이걸 빼면 `import Metal` 을 안 적은 테스트가 거짓 실패한다.
@_exported import AppKit

open class XCTestCase: NSObject {
    public override init() { super.init() }
    // 실물 SDK 의 인스턴스 setUp/tearDown 계열은 `@MainActor` 다 — `@MainActor final class …:
    // XCTestCase` 가 이 넷을 override 하는 자리(리포에 5개)가 그 근거다. 표기를 빼면 그 override 가
    // nonisolated 로 잡혀 본문의 메인 액터 프로퍼티 접근이 거짓 실패한다(실측: WorkshopPagingTests).
    @MainActor open func setUp() {}
    @MainActor open func tearDown() {}
    @MainActor open func setUpWithError() throws {}
    @MainActor open func tearDownWithError() throws {}
    @MainActor open func setUp() async throws {}
    @MainActor open func tearDown() async throws {}
    open class func setUp() {}
    open class func tearDown() {}
    public var continueAfterFailure: Bool = true
    public func addTeardownBlock(_ block: @escaping () -> Void) {}
    public func measure(_ block: () -> Void) {}
    public func measure(metrics: [Any], block: () -> Void) {}
    public func expectation(description: String) -> XCTestExpectation { XCTestExpectation() }
    @discardableResult
    public func expectation(forNotification name: NSNotification.Name, object: Any?,
                            handler: ((Notification) -> Bool)? = nil) -> XCTestExpectation {
        XCTestExpectation()
    }
    @discardableResult
    public func keyValueObservingExpectation(for object: Any, keyPath: String,
                                             handler: ((Any, [AnyHashable: Any]) -> Bool)? = nil) -> XCTestExpectation {
        XCTestExpectation()
    }
    public func wait(for expectations: [XCTestExpectation], timeout: TimeInterval) {}
    public func wait(for expectations: [XCTestExpectation], timeout: TimeInterval, enforceOrder: Bool) {}
    public func fulfillment(of expectations: [XCTestExpectation], timeout: TimeInterval,
                            enforceOrder: Bool = false) async {}
    public func XCTAssertNoThrow<T>(_ e: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "",
                                    file: StaticString = #filePath, line: UInt = #line) {}
}

open class XCTestExpectation {
    public init(description: String = "") {}
    public var expectedFulfillmentCount: Int = 1
    public var isInverted: Bool = false
    public func fulfill() {}
}

public struct XCTSkip: Error {
    public init(_ message: @autoclosure () -> String? = nil,
                file: StaticString = #filePath, line: UInt = #line) {}
}
public func XCTSkipIf(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String? = nil,
                      file: StaticString = #filePath, line: UInt = #line) throws {}
public func XCTSkipUnless(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String? = nil,
                          file: StaticString = #filePath, line: UInt = #line) throws {}

public func XCTFail(_ m: String = "", file: StaticString = #filePath, line: UInt = #line) {}

public func XCTAssert(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "",
                      file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertTrue(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "",
                          file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertFalse(_ e: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "",
                           file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertNil(_ e: @autoclosure () throws -> Any?, _ m: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertNotNil(_ e: @autoclosure () throws -> Any?, _ m: @autoclosure () -> String = "",
                            file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                         _ m: @autoclosure () -> String = "",
                                         file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                             accuracy: T, _ m: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertEqual<T: Numeric>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                       accuracy: T, _ m: @autoclosure () -> String = "",
                                       file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                            _ m: @autoclosure () -> String = "",
                                            file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertNotEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                                accuracy: T, _ m: @autoclosure () -> String = "",
                                                file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertNotEqual<T: Numeric>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                          accuracy: T, _ m: @autoclosure () -> String = "",
                                          file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                                _ m: @autoclosure () -> String = "",
                                                file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                                       _ m: @autoclosure () -> String = "",
                                                       file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                             _ m: @autoclosure () -> String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                                    _ m: @autoclosure () -> String = "",
                                                    file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertIdentical(_ a: @autoclosure () throws -> AnyObject?, _ b: @autoclosure () throws -> AnyObject?,
                               _ m: @autoclosure () -> String = "",
                               file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertThrowsError<T>(_ e: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "",
                                    file: StaticString = #filePath, line: UInt = #line,
                                    _ handler: (Error) -> Void = { _ in }) {}
public func XCTAssertNoThrow<T>(_ e: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "",
                                file: StaticString = #filePath, line: UInt = #line) {}
public func XCTUnwrap<T>(_ e: @autoclosure () throws -> T?, _ m: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let v = try e() else { throw XCTSkip() }
    return v
}
