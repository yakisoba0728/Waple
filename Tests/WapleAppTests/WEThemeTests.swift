import XCTest
@testable import Waple

final class WEThemeTests: XCTestCase {
    /// weHex 이니셜라이저가 RGB 성분을 정확히 복원하는지(토큰 전체가 이 경로를 탄다).
    func testHexColorRoundTrip() {
        let ns = NSColor(WETheme.color(0x2A6EE0)).usingColorSpace(.sRGB)!
        XCTAssertEqual(Int((ns.redComponent * 255).rounded()), 0x2A)
        XCTAssertEqual(Int((ns.greenComponent * 255).rounded()), 0x6E)
        XCTAssertEqual(Int((ns.blueComponent * 255).rounded()), 0xE0)
    }

    /// 토큰이 최소한 서로 구분되는 값인지(복붙 실수 방어).
    func testTokensDistinct() {
        XCTAssertNotEqual(WETheme.Metrics.titlebarH, 0)
        XCTAssertNotEqual(WETheme.Metrics.rightPanelW, 0)
    }
}
