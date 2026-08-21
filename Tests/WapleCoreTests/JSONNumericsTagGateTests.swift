import XCTest
@testable import WapleCore

/// **JSON 타입 태그 5(boolean)가 숫자 자리로 새는 경로의 계약 잠금.**
///
/// 배경(2026-08-21 전수). jsoncpp 의 값 접근자는 불리언을 **받는다**:
///   · `asFloat` `0x140086220` — 태그 분기 `0x14008623e cmp edx,2` 가 태그 5 로 떨어지면
///     `0x140086243 cmp byte [rcx],0` → 거짓이면 `0x140086248 movss xmm0,[0x140492704]`(**1.0f**),
///     참이면 `0x1400862ad xorps xmm0,xmm0`(0.0f).
///   · `asInt` `0x140085f70` — 태그 5 에서 `0x140085f95 cmp byte [rcx],al; setne al` → **0/1**.
///   · 태그 4(string)·6·7 만 `0x1400862b8`("Value is not convertible to float.")로 abort.
///
/// 즉 **게이트가 없는 자리에서는 `{"k":true}` → 1.0 이 실물 동작**이다. 태그를 1/2/3 으로
/// 좁히는 것은 호출부가 `Json::Value::isNumeric()`(`0x140088880`)을 먼저 부를 때뿐이다.
/// 그래서 `strictFloat` 는 관용을 유지하고, 게이트가 실재하는 자리만 `numericFloat` 를 쓴다.
final class JSONNumericsTagGateTests: XCTestCase {
    /// 이 테스트 파일 전용 규약 — **반드시 `JSONSerialization` 을 거쳐야 재현된다**.
    /// Swift 리터럴 `true` 는 `Bool` 로 남아 `as? Double` 이 nil 이므로 누수가 일어나지 않는다.
    /// (리눅스 실측: `["t": true]["t"]` 는 `Bool`, `JSONSerialization` 의 `true` 는 `__NSCFBoolean`.)
    private func v(_ literal: String) -> Any? {
        json("{\"k\":\(literal)}")["k"]
    }

    func testJSONBoolBridgesIntoTheNumericCastsAtAll() {
        XCTAssertNotNil(v("true") as? Double, "JSONSerialization 의 true 는 NSNumber 라 Double 캐스트가 성공한다")
        XCTAssertNotNil(v("true") as? Int)
        XCTAssertNil(true as Any as? Double, "Swift 리터럴 Bool 은 브리지되지 않는다 — 테스트 함정")
    }

    /// `strict*` 는 **일부러** 불리언을 통과시킨다 — 게이트 없는 `asFloat`/`asInt` 와 같은 값.
    func testStrictKeepsBooleanLeniencyToMatchUngatedAsFloat() {
        XCTAssertEqual(strictFloat(v("true")), 1.0, "asFloat 태그 5 → 1.0f (0x140086248)")
        XCTAssertEqual(strictFloat(v("false")), 0.0, "asFloat 태그 5 값 0 → 0.0f (0x1400862ad)")
        XCTAssertEqual(strictInt(v("true")), 1, "asInt 태그 5 → setne (0x140085f95)")
        XCTAssertEqual(strictInt(v("false")), 0)
    }

    /// `numeric*` 은 `isNumeric` 게이트 그대로 — 태그 1/2/3 만 통과.
    func testNumericGateRejectsBooleanAndStringAndNull() {
        XCTAssertNil(numericFloat(v("true")))
        XCTAssertNil(numericFloat(v("false")))
        XCTAssertNil(numericInt(v("true")))
        XCTAssertNil(numericInt(v("false")))
        XCTAssertNil(numericFloat(v("\"3.5\"")), "태그 4(string) — isNumeric 거짓")
        XCTAssertNil(numericFloat(v("null")), "태그 0(null) — dec eax 가 언더플로해 ja 로 빠진다")
        XCTAssertNil(numericFloat(v("[1,2]")), "태그 6(array)")
        XCTAssertNil(numericFloat(v("{\"a\":1}")), "태그 7(object)")
    }

    /// 게이트를 통과하는 값은 `strict*` 와 **완전히 같은 값**이어야 한다(게이트는 폭만 좁힌다).
    func testNumericGatePassesRealNumbersUnchanged() {
        XCTAssertEqual(numericFloat(v("2.5")), 2.5)
        XCTAssertEqual(numericFloat(v("3")), 3.0)
        XCTAssertEqual(numericInt(v("3")), 3)
        XCTAssertEqual(numericInt(v("2.5")), 2, "태그 3 → cvttsd2si(0 방향 절삭, 0x140085fa2)")
        XCTAssertEqual(numericInt(v("-2.5")), -2)
        XCTAssertNil(numericFloat(v("1e300")), "Float 범위 밖은 유한성 프리미티브가 따로 막는다")
    }

    func testIsJSONNumericPredicateItself() {
        XCTAssertTrue(isJSONNumeric(v("0")))
        XCTAssertTrue(isJSONNumeric(v("-1.5")))
        XCTAssertFalse(isJSONNumeric(v("true")))
        XCTAssertFalse(isJSONNumeric(v("false")))
        XCTAssertFalse(isJSONNumeric(v("\"1\"")))
        XCTAssertFalse(isJSONNumeric(nil))
        XCTAssertFalse(isJSONNumeric(true), "브리지되지 않은 Swift Bool 도 막는다")
        XCTAssertTrue(isJSONNumeric(3), "브리지되지 않은 Swift Int 는 통과")
        XCTAssertTrue(isJSONNumeric(3.5))
    }
}
