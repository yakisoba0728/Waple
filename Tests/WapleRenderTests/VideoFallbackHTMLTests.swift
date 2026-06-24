import XCTest
@testable import WapleRender

final class VideoFallbackHTMLTests: XCTestCase {
    func testContainsLoopingMutedVideoTag() {
        let html = VideoFallbackHTML.html(forVideoFile: "clip.webm")
        XCTAssertTrue(html.contains("<video"))
        XCTAssertTrue(html.contains("autoplay"))
        XCTAssertTrue(html.contains("loop"))
        XCTAssertTrue(html.contains("muted"))
        XCTAssertTrue(html.contains("object-fit:cover") || html.contains("object-fit: cover"))
    }

    func testUsesSchemeURLWithPercentEncodedName() {
        let html = VideoFallbackHTML.html(forVideoFile: "my clip.webm")
        XCTAssertTrue(html.contains("waple-asset://wallpaper/my%20clip.webm"))
    }
}
