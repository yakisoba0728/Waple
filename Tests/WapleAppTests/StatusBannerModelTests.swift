import XCTest
@testable import Waple

final class StatusBannerModelTests: XCTestCase {
    func testShowSetsMessageAndBumpsGeneration() {
        let m = StatusBannerModel()
        XCTAssertNil(m.message)
        m.show("적용 실패")
        XCTAssertEqual(m.message, "적용 실패")
        let g1 = m.generation
        m.show("두 번째")   // 연속 표시 → 세대 증가(자동소멸 타이머 리셋 근거)
        XCTAssertEqual(m.message, "두 번째")
        XCTAssertGreaterThan(m.generation, g1)
    }

    func testDismissClears() {
        let m = StatusBannerModel()
        m.show("x")
        m.dismiss()
        XCTAssertNil(m.message)
    }
}
