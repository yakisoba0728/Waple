import XCTest
import JavaScriptCore
@testable import WapleRender

final class VideoFallbackHTMLTests: XCTestCase {
    func testContainsMutedVideoTagWithExplicitLoopAtEnd() {
        let html = VideoFallbackHTML.html(forVideoFile: "clip.webm")
        XCTAssertTrue(html.contains("<video"))
        XCTAssertTrue(html.contains("autoplay"))
        XCTAssertFalse(html.contains(" autoplay loop"))
        XCTAssertTrue(html.contains("v.onended=function()"))
        XCTAssertTrue(html.contains("v.play()"))
        XCTAssertTrue(html.contains("window.wallpaperOnVideoEnded()"))
        XCTAssertTrue(html.contains("muted"))
        XCTAssertTrue(html.contains("object-fit:cover") || html.contains("object-fit: cover"))
    }

    func testUsesSchemeURLWithPercentEncodedName() {
        let html = VideoFallbackHTML.html(forVideoFile: "my clip.webm")
        XCTAssertTrue(html.contains("waple-asset://wallpaper/my%20clip.webm"))
    }

    func testEndReloadsPlaybackAndPublishesEachCycle() throws {
        let html = VideoFallbackHTML.html(forVideoFile: "clip.webm")
        let open = try XCTUnwrap(html.range(of: "<script>"))
        let close = try XCTUnwrap(html.range(of: "</script>"))
        let script = String(html[open.upperBound..<close.lowerBound])
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            var cycles = 0, starts = 0;
            var video = { currentTime: 1, load: function() { this.currentTime = 0; }, play: function() {
                if (this.currentTime === 0) { starts++; }
                return Promise.resolve();
            }};
            var window = { wallpaperOnVideoEnded: function() { cycles++; }};
            var document = { getElementsByTagName: function() { return [video]; }};
            """)
        context.evaluateScript(script)
        context.evaluateScript("video.onended(); video.currentTime=1; video.onended();")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("starts")?.toInt32(), 2)
        XCTAssertEqual(context.evaluateScript("cycles")?.toInt32(), 2)
    }
}
