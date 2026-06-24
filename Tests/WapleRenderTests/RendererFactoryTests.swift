import XCTest
@testable import WapleRender
import WapleCore

final class RendererFactoryTests: XCTestCase {
    private func project(type: WallpaperType, file: String?) -> WallpaperProject {
        WallpaperProject(id: "x", type: type, fileName: file, previewName: nil,
                         title: "t", tags: [], contentRating: nil, workshopId: nil,
                         dependency: nil, folderURL: URL(fileURLWithPath: "/tmp/x", isDirectory: true))
    }

    func testWebTypeReturnsWebRenderer() {
        XCTAssertTrue(RendererFactory.makeRenderer(for: project(type: .web, file: "index.html")) is WebRenderer)
    }

    func testSupportedVideoReturnsVideoRenderer() {
        XCTAssertTrue(RendererFactory.makeRenderer(for: project(type: .video, file: "a.mp4")) is VideoRenderer)
    }

    func testUnsupportedCodecVideoReturnsWebRenderer() {
        XCTAssertTrue(RendererFactory.makeRenderer(for: project(type: .video, file: "a.webm")) is WebRenderer)
    }

    func testSceneAndOthersReturnNil() {
        XCTAssertNil(RendererFactory.makeRenderer(for: project(type: .scene, file: "scene.json")))
        XCTAssertNil(RendererFactory.makeRenderer(for: project(type: .preset, file: nil)))
        XCTAssertNil(RendererFactory.makeRenderer(for: project(type: .unknown("z"), file: nil)))
    }

    func testSupportedContainers() {
        XCTAssertTrue(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.mp4")))
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.webm")))
    }
}
