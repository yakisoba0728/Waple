import XCTest
@testable import WapleCore

/// **JSON 타입 태그 5(boolean)가 숫자 자리로 새는 경로의 계약 잠금.**
///
/// 배경(2026-08-21 전수). jsoncpp 의 값 접근자는 불리언을 **받는다**:
///   · `asFloat` `0x140086220` — 태그 분기 `0x14008623e cmp edx,2` 가 태그 5 로 떨어지면
///     `0x140086243 cmp byte [rcx],0` → 거짓이면 `0x140086248 movss xmm0,[0x140492704]`(**1.0f**),
///     참이면 `0x1400862ad xorps xmm0,xmm0`(0.0f).
///   · `asInt` `0x140085ee0` — 태그 5 에서 `0x140085f05 cmp byte [rcx],al; setne al` → **0/1**.
///     `asUInt` `0x140085f70`(@`0x140085f95`)도 같다.
///   · 태그 4(string)·6·7 만 `0x1400862b8`("Value is not convertible to float.")로 abort.
///
/// > **[2026-08-21 정정] `asInt`/`asUInt` 의 VA 가 종전에 서로 바뀌어 있었다.**
/// > 판정은 실패 경로가 `_wassert` 로 넘기는 문자열이다 — `0x140085ee0` 은
/// > "Value is not convertible to **Int**."(`0x140478740`, json_value.cpp:719),
/// > `0x140085f70` 은 "Value is not convertible to **UInt**."(`0x1404787c8`, :741).
/// > 같은 이유로 `asInt64` = `0x1400860c0`(:769) · `asUInt64` = `0x140086000`(:790) 이다.
/// > 근거·파장은 `Sources/WapleCore/JSONNumerics.swift` 머리 표와
/// > `docs/re/json-number-tags.md` §9.
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
        XCTAssertEqual(strictInt(v("true")), 1, "asInt 태그 5 → setne (0x140085f05)")
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
        XCTAssertEqual(numericInt(v("2.5")), 2, "태그 3 → cvttsd2si rax(0 방향 절삭, asInt64 0x1400860f2)")
        XCTAssertEqual(numericInt(v("-2.5")), -2)
        XCTAssertNil(numericFloat(v("1e300")), "Float 범위 밖은 유한성 프리미티브가 따로 막는다")
    }

    // MARK: 폭 축 — 32비트 접근자 두 가지(`asInt` 부호 있음 / `asUInt` 부호 없음)

    /// **부호가 갈린다.** 실물의 게이트 35자리는 `asInt`(`0x140085ee0`)를 부르고, 그 태그 1/2 경로는
    /// `mov eax, dword [rcx]`(`0x140085f1e`)를 **`int` 반환**으로 쓴다 — 즉 `-2` 는 그대로 `-2` 다.
    /// 같은 비트를 부호 없이 읽는 것은 `asUInt`(`0x140085f70`, 태그 1/2 `0x140085faf`)뿐이다.
    func testInt32KeepsSignWhileUInt32Wraps() {
        XCTAssertEqual(strictInt32(v("-2")), -2, "asInt — mov eax,[rcx] 0x140085f1e, int 반환")
        XCTAssertEqual(strictInt32(v("-1")), -1)
        XCTAssertEqual(strictUInt32(v("-2")), 4_294_967_294, "asUInt — 같은 비트를 부호 없이")
        XCTAssertEqual(strictUInt32(v("-1")), 4_294_967_295)
        for lit in ["0", "7", "2147483647"] {
            XCTAssertEqual(strictInt32(v(lit)), strictUInt32(v(lit)), "\(lit): 양수 소범위는 같다")
        }
    }

    /// 두 판 모두 **하위 32비트만** 가져간다(`mov eax`, 32비트 레지스터).
    func testBoth32BitAccessorsTruncateIntegerToLow32Bits() {
        XCTAssertEqual(strictUInt32(v("4294967295")), 4_294_967_295, "경계 — 그대로")
        XCTAssertEqual(strictUInt32(v("4294967296")), 0, "2^32 는 하위 32비트가 0")
        XCTAssertEqual(strictUInt32(v("4294967297")), 1)
        XCTAssertEqual(strictInt32(v("2147483648")), -2_147_483_648, "2^31 은 부호 비트가 선다")
        XCTAssertEqual(strictInt32(v("4294967295")), -1)
        XCTAssertEqual(strictInt32(v("4294967296")), 0)
    }

    /// 태그 3 에서 **두 판이 갈린다** — `asInt` 는 `cvttsd2si eax`(32비트, `0x140085f12`),
    /// `asUInt` 는 `cvttsd2si rax`(64비트, `0x140085fa2`) 뒤 하위 32비트다.
    /// 그래서 Int32 범위 밖 실수를 `asUInt` 는 감아서 값을 내고 `asInt` 는 못 담는다.
    func testRealPathDivergesBetweenInt32AndUInt32() {
        XCTAssertEqual(strictInt32(v("2.9")), 2)
        XCTAssertEqual(strictInt32(v("-2.9")), -2, "0 방향 절삭")
        XCTAssertEqual(strictUInt32(v("2.9")), 2)
        XCTAssertEqual(strictUInt32(v("-2.9")), 4_294_967_294, "-2.9 → -2 → 0xFFFFFFFE")
        XCTAssertEqual(strictInt32(v("2147483647.5")), 2_147_483_647)
        XCTAssertNil(strictInt32(v("5000000000.5")), "cvttsd2si eax 가 32비트에 못 담는 구간")
        XCTAssertEqual(strictUInt32(v("5000000000.5")), 705_032_704,
                       "cvttsd2si rax → 0x12A05F200, eax = 0x2A05F200")
        XCTAssertEqual(strictUInt32(v("-5000000000.5")), 3_589_934_592)
    }

    /// 비유한·Int64 범위 밖·비숫자 태그는 의도적으로 nil(값을 지어내지 않는다).
    func testWideAccessorsRefuseIndefiniteAndNonNumericTags() {
        let accessors: [(String, (Any?) -> Int?)] = [("asInt", { strictInt32($0) }),
                                                     ("asUInt", { strictUInt32($0) })]
        for (name, f) in accessors {
            XCTAssertNil(f(v("1e300")), "\(name): Int64 범위 밖 — integer indefinite 구간(추정)")
            XCTAssertNil(f(v("\"7\"")), "\(name): 태그 4 — 실물은 abort, 우리는 nil")
            XCTAssertNil(f(v("null")), name)
            XCTAssertNil(f(v("[1]")), name)
            XCTAssertNil(f(nil), name)
        }
    }

    /// **[2026-08-21 발견] Foundation 과 jsoncpp 의 "정수 대 실수" 갈림이 다르다.**
    ///
    /// jsoncpp 는 **문법**으로 가른다 — `.` 나 `e` 가 있으면 태그 3(real)이다
    /// (그래서 실물의 `5e9` 는 `asInt` 의 `cvttsd2si eax` 경로라 32비트에 못 담는다).
    /// Foundation 은 **값**으로 가른다 — `5e9` 는 정수값이라 `NSNumber(Int)` 로 온다.
    /// 그래서 우리는 `mov eax,[rcx]` 쪽(하위 32비트)을 타게 된다.
    ///
    /// 코퍼스 도달 **0건**(동봉+설치본 3,655 파일 33,753개 숫자에 `|x| ≥ 2^31` 실수 0 ·
    /// Int32 범위 밖 정수 0 — `docs/re/json-number-tags.md` §8.1)이라 그대로 두고,
    /// **다음 사람이 "왜 nil 이 아니지" 로 헤매지 않게** 여기 값으로 못박는다.
    func testFoundationSplitsIntAndRealByValueNotBySyntax() {
        XCTAssertEqual(strictInt32(v("5e9")), 705_032_704,
                       "Foundation 은 5e9 를 정수로 준다 — 5000000000 의 하위 32비트")
        XCTAssertNil(strictInt32(v("5000000000.5")), "진짜 실수는 Int32 범위 밖이라 nil")
        XCTAssertEqual(strictUInt32(v("5e9")), 705_032_704, "asUInt 는 두 경로가 같은 값")
    }

    /// 게이트 **없는** 32비트 접근자는 불리언을 0/1 로 받는다
    /// (`asInt` `0x140085f07` · `asUInt` `0x140085f97` — 둘 다 `setne`).
    /// 게이트가 붙은 자리만 거부한다 — 폭이 아니라 **관용**이 갈리는 지점이다.
    func testWideAccessorBooleanFollowsTheGate() {
        XCTAssertEqual(strictInt32(v("true")), 1, "게이트 없는 asInt — setne 0x140085f07")
        XCTAssertEqual(strictInt32(v("false")), 0)
        XCTAssertEqual(strictUInt32(v("true")), 1, "게이트 없는 asUInt — setne 0x140085f97")
        XCTAssertEqual(strictUInt32(v("false")), 0)
        XCTAssertNil(numericInt32(v("true")), "게이트 있는 자리 — isNumeric 이 태그 5 를 막는다")
        XCTAssertNil(numericInt32(v("false")))
        XCTAssertNil(numericUInt32(v("true")))
        XCTAssertNil(numericUInt32(v("false")))
    }

    /// 사다리 순서 `numeric*32 ⊂ strict*32` — 게이트는 폭이 아니라 입력 집합만 좁힌다.
    func testWideLaddersAreSubsetRelations() {
        for lit in ["0", "7", "-2", "2.9", "-2.9", "4294967296", "true", "false", "\"7\"", "null", "[1]"] {
            for (strict, numeric) in [(strictInt32(v(lit)), numericInt32(v(lit))),
                                      (strictUInt32(v(lit)), numericUInt32(v(lit)))] {
                if let numeric {
                    XCTAssertEqual(numeric, strict, "\(lit): 게이트를 통과하면 값이 같아야 한다")
                }
                if strict == nil { XCTAssertNil(numeric, "\(lit): strict 가 못 읽으면 numeric 도 못 읽는다") }
            }
        }
    }

    /// `numericInt`(64비트) 와 `numericInt32` 는 **같은 게이트, 다른 폭**이다.
    /// 실물의 `orthogonalprojection.width/height`(게이트 `0x140187578`·`0x140187587`)는 게이트 뒤에
    /// **`asInt`**(`0x14018758f`)를 부르고 곧바로 `cvtdq2ps`(`0x14018759b`)로 **부호 있는**
    /// int→float 로 굽는다. 즉 음수 저작은 감기지 않고 음수 그대로 들어간다 —
    /// 종전에 이 자리를 "`asUInt` 라 음수가 감긴다" 고 적은 것은 접근자 오귀속이었다.
    func testNumericIntAndNumericInt32DivergeOnlyBeyondInt32() {
        XCTAssertEqual(numericInt(v("-2")), -2)
        XCTAssertEqual(numericInt32(v("-2")), -2, "부호 있는 32비트 — 감기지 않는다")
        XCTAssertEqual(numericInt(v("7")), numericInt32(v("7")))
        XCTAssertEqual(numericInt(v("4294967296")), 4_294_967_296, "64비트 판은 그대로")
        XCTAssertEqual(numericInt32(v("4294967296")), 0, "32비트 판만 감긴다")
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
