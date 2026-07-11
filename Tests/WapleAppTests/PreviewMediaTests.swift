import XCTest
@testable import Waple

final class PreviewMediaTests: XCTestCase {
    func testGifDetectionByExtension() {
        XCTAssertTrue(PreviewMedia.isAnimated(URL(fileURLWithPath: "/a/preview.GIF")))
        XCTAssertTrue(PreviewMedia.isAnimated(URL(fileURLWithPath: "/a/preview.gif")))
        XCTAssertFalse(PreviewMedia.isAnimated(URL(fileURLWithPath: "/a/preview.jpg")))
        XCTAssertFalse(PreviewMedia.isAnimated(URL(fileURLWithPath: "/a/previewgif")))
    }
}
