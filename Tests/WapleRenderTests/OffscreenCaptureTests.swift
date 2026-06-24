import XCTest
import AppKit
@testable import WapleRender

final class OffscreenCaptureTests: XCTestCase {
    func testEncodesRGBAToReadablePNG() throws {
        // 2×1: 빨강, 초록 (RGBA8)
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255]
        let png = try XCTUnwrap(OffscreenCapture.png(rgba: rgba, width: 2, height: 1))
        XCTAssertGreaterThan(png.count, 8)
        // PNG 시그니처
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        // 디코드 후 픽셀[0]=빨강 확인
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        let c = try XCTUnwrap(rep.colorAt(x: 0, y: 0))
        XCTAssertEqual(c.redComponent, 1.0, accuracy: 0.02)
        XCTAssertEqual(c.greenComponent, 0.0, accuracy: 0.02)
    }

    func testRejectsBadInput() {
        XCTAssertNil(OffscreenCapture.png(rgba: [1, 2, 3], width: 4, height: 4))  // too small
        XCTAssertNil(OffscreenCapture.png(rgba: [], width: 0, height: 0))
    }
}
