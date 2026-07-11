import XCTest
@testable import WapleCore

/// 공용 숫자 파서(JSONNumerics)의 관용 폭 계약 잠금 — strict(문자열 거부) vs lenient(문자열 허용).
final class JSONNumericsTests: XCTestCase {
    func testStrictRejectsStringLenientAccepts() {
        XCTAssertNil(strictFloat("3.5"), "파티클·키프레임 규약: 문자열 스칼라 거부")
        XCTAssertNil(strictInt("35"))
        XCTAssertEqual(lenientFloat("3.5"), 3.5, "씬 규약: 문자열 숫자 허용")
        XCTAssertEqual(lenientInt("35"), 35)
    }

    func testFinitenessGate() {
        XCTAssertNil(strictFloat(Double.nan))
        XCTAssertNil(strictFloat(Double.infinity))
        XCTAssertNil(lenientFloat(1e39), "Float 범위 밖 Double → nil")
        XCTAssertNil(lenientFloat("inf"), "문자열 경로도 비유한 거부")
    }
}
