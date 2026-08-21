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

    // MARK: 폭 축 — `asUInt`(`0x140085ee0`) 하위 32비트

    /// 태그 1/2 는 `mov eax, dword [rcx]`(`0x140085f1e`) — 64비트 슬롯의 하위 32비트만 가져간다.
    /// **음수에서만 눈에 보인다**: `-2` → `0xFFFFFFFE`.
    func testUInt32TruncatesIntegerToLow32Bits() {
        XCTAssertEqual(strictUInt32(v("-2")), 4_294_967_294, "mov eax,[rcx] — 0x140085f1e")
        XCTAssertEqual(strictUInt32(v("-1")), 4_294_967_295)
        XCTAssertEqual(strictUInt32(v("0")), 0)
        XCTAssertEqual(strictUInt32(v("7")), 7)
        XCTAssertEqual(strictUInt32(v("4294967295")), 4_294_967_295, "경계 — 그대로")
        XCTAssertEqual(strictUInt32(v("4294967296")), 0, "2^32 는 하위 32비트가 0")
        XCTAssertEqual(strictUInt32(v("4294967297")), 1)
    }

    /// 태그 3 은 `cvttsd2si eax`(`0x140085f12`) — 0 방향 절삭 후 32비트.
    func testUInt32TruncatesRealTowardZeroThenTo32Bits() {
        XCTAssertEqual(strictUInt32(v("2.9")), 2)
        XCTAssertEqual(strictUInt32(v("-2.9")), 4_294_967_294, "-2.9 → -2 → 0xFFFFFFFE")
        XCTAssertEqual(strictUInt32(v("2147483647.5")), 2_147_483_647)
    }

    /// Int32 범위 밖·비유한 **실수**는 의도적으로 nil(값을 지어내지 않는다).
    func testUInt32RefusesOutOfInt32RangeReals() {
        XCTAssertNil(strictUInt32(v("5000000000.5")), "cvttsd2si 가 32비트에 못 담는 구간")
        XCTAssertNil(strictUInt32(v("-5000000000.5")))
        XCTAssertNil(strictUInt32(v("1e300")))
        XCTAssertNil(strictUInt32(v("\"7\"")), "태그 4 — 실물은 abort, 우리는 nil")
        XCTAssertNil(strictUInt32(v("null")))
        XCTAssertNil(strictUInt32(v("[1]")))
        XCTAssertNil(strictUInt32(nil))
    }

    /// **[2026-08-21 발견] Foundation 과 jsoncpp 의 "정수 대 실수" 갈림이 다르다.**
    ///
    /// jsoncpp 는 **문법**으로 가른다 — `.` 나 `e` 가 있으면 태그 3(real)이다
    /// (그래서 `5e9` 는 `cvttsd2si eax` 경로이고 32비트에 못 담긴다).
    /// Foundation 은 **값**으로 가른다 — `5e9` 는 정수값이라 `NSNumber(Int)` 로 온다.
    /// 그래서 우리는 `mov eax,[rcx]` 쪽(하위 32비트)을 타게 된다.
    ///
    /// 코퍼스 도달 **0건**(동봉+설치본 3,655 파일 33,753개 숫자에 `|x| ≥ 2^31` 실수 0 ·
    /// Int32 범위 밖 정수 0 — `docs/re/json-number-tags.md` §8.1)이라 그대로 두고,
    /// **다음 사람이 "왜 nil 이 아니지" 로 헤매지 않게** 여기 값으로 못박는다.
    func testFoundationSplitsIntAndRealByValueNotBySyntax() {
        XCTAssertEqual(strictUInt32(v("5e9")), 705_032_704,
                       "Foundation 은 5e9 를 정수로 준다 — 5000000000 mod 2^32")
        XCTAssertEqual(strictUInt32(v("-5e9")), 3_589_934_592)
        XCTAssertNil(strictUInt32(v("5000000000.5")), "진짜 실수는 Int32 범위 밖이라 nil")
    }

    /// 게이트 **없는** `asUInt` 자리는 불리언을 0/1 로 받는다(`0x140085f07 setne`).
    /// 게이트가 붙은 자리만 거부한다 — 폭이 아니라 **관용**이 갈리는 지점이다.
    func testUInt32BooleanFollowsTheGate() {
        XCTAssertEqual(strictUInt32(v("true")), 1, "게이트 없는 asUInt — setne 0x140085f07")
        XCTAssertEqual(strictUInt32(v("false")), 0)
        XCTAssertNil(numericUInt32(v("true")), "게이트 있는 자리 — isNumeric 이 태그 5 를 막는다")
        XCTAssertNil(numericUInt32(v("false")))
    }

    /// 사다리 순서 `numericUInt32 ⊂ strictUInt32` — 게이트는 폭이 아니라 입력 집합만 좁힌다.
    func testUInt32LadderIsASubsetRelation() {
        for lit in ["0", "7", "-2", "2.9", "-2.9", "4294967296", "true", "false", "\"7\"", "null", "[1]"] {
            let strict = strictUInt32(v(lit))
            let numeric = numericUInt32(v(lit))
            if let numeric {
                XCTAssertEqual(numeric, strict, "\(lit): 게이트를 통과하면 값이 같아야 한다")
            }
            if strict == nil { XCTAssertNil(numeric, "\(lit): strict 가 못 읽으면 numeric 도 못 읽는다") }
        }
    }

    /// `numericInt` 와 `numericUInt32` 는 **같은 게이트, 다른 폭**이다.
    /// 실물의 `orthogonalprojection.width/height`(`0x140187578`·`0x140187587`)는 게이트 뒤에
    /// `asUInt`(`0x14018758f`)를 부르므로 음수 저작은 32비트로 감긴다.
    func testNumericIntAndNumericUInt32DivergeOnlyOnWidth() {
        XCTAssertEqual(numericInt(v("-2")), -2, "Int 판은 64비트라 그대로")
        XCTAssertEqual(numericUInt32(v("-2")), 4_294_967_294, "UInt32 판은 감긴다")
        XCTAssertEqual(numericInt(v("7")), numericUInt32(v("7")), "양수 소범위는 두 판이 같다")
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
