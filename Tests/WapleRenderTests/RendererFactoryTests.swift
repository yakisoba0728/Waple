import XCTest
@testable import WapleRender
import WapleCore

final class RendererFactoryTests: XCTestCase {
    func testFactoryReturnsVideoRendererForVideoType() {
        let renderer = RendererFactory.makeRenderer(for: .video)
        XCTAssertTrue(renderer is VideoRenderer)
    }

    func testFactoryReturnsNilForUnsupportedTypes() {
        XCTAssertNil(RendererFactory.makeRenderer(for: .scene))
        XCTAssertNil(RendererFactory.makeRenderer(for: .web))
        XCTAssertNil(RendererFactory.makeRenderer(for: .preset))
        XCTAssertNil(RendererFactory.makeRenderer(for: .application))
        XCTAssertNil(RendererFactory.makeRenderer(for: .unknown("flux")))
    }

    func testSupportedContainers() {
        XCTAssertTrue(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.mp4")))
        XCTAssertTrue(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.MP4")))
        XCTAssertTrue(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.mov")))
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.webm")))
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.mkv")))
    }
}
