import XCTest
@testable import WapleCore
@testable import WapleRender

final class UserPropertyStoreTests: XCTestCase {
    override func tearDown() { UserPropertyStore.reset(id: "upt1"); super.tearDown() }

    func testRoundTripAndReset() {
        XCTAssertTrue(UserPropertyStore.overrides(id: "upt1").isEmpty)
        UserPropertyStore.set(.bool(false), key: "on", id: "upt1")
        UserPropertyStore.set(.number(2.5), key: "amt", id: "upt1")
        UserPropertyStore.set(.string("1 0 0"), key: "tint", id: "upt1")
        let o = UserPropertyStore.overrides(id: "upt1")
        XCTAssertEqual(o["on"], .bool(false))
        XCTAssertEqual(o["amt"], .number(2.5))
        XCTAssertEqual(o["tint"], .string("1 0 0"))
        // 씬 파서용 raw 딕셔너리
        let raw = UserPropertyStore.rawOverrides(id: "upt1")
        XCTAssertEqual(raw["on"] as? Bool, false)
        XCTAssertEqual(raw["amt"] as? Double, 2.5)
        UserPropertyStore.reset(id: "upt1")
        XCTAssertTrue(UserPropertyStore.overrides(id: "upt1").isEmpty)
    }
}
