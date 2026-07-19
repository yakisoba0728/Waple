import XCTest
@testable import WapleRender

/// 라이브 데스크탑 프레젠트 상하 뒤집힘 보정 게이트(macOS 26+)의 순수 판정 경계 고정.
final class SceneLivePresentationFixTests: XCTestCase {
    func testBelow26NoFlip() {
        XCTAssertFalse(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 14))
        XCTAssertFalse(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 15))
        XCTAssertFalse(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 25))
    }

    func test26AndAboveFlips() {
        XCTAssertTrue(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 26))
        XCTAssertTrue(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 27))
        XCTAssertTrue(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 30))
    }
}
