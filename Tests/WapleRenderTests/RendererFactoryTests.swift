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

    func testUnsupportedCodecVideoRoutesByFFmpegAvailability() {
        for ext in ["webm", "mkv", "avi", "wmv", "flv", "ogv", "mpg"] {
            let r = RendererFactory.makeRenderer(for: project(type: .video, file: "a.\(ext)"))
            if FFmpegConverter.isAvailable {
                XCTAssertTrue(r is VideoRenderer, "\(ext) should route to VideoRenderer for ffmpeg conversion")
            } else {
                XCTAssertTrue(r is WebRenderer, "\(ext) should fall back to WebRenderer when ffmpeg is unavailable")
            }
        }
    }

    func testSceneAlwaysReturnsSceneRenderer() {
        XCTAssertTrue(RendererFactory.makeRenderer(for: project(type: .scene, file: "scene.json")) is SceneRenderer)
    }

    func testVideoWithNilFileNameIsUnsupported() {
        XCTAssertNil(RendererFactory.makeRenderer(for: project(type: .video, file: nil)))
    }

    func testTraversalVideoFileIsUnsupported() {
        XCTAssertNil(RendererFactory.makeRenderer(for: project(type: .video, file: "../outside.mp4")))
    }

    func testOtherUnsupportedReturnNil() {
        XCTAssertNil(RendererFactory.makeRenderer(for: project(type: .preset, file: nil)))
        XCTAssertNil(RendererFactory.makeRenderer(for: project(type: .unknown("z"), file: nil)))
        XCTAssertNil(RendererFactory.makeRenderer(for: project(type: .application, file: "app.exe")))
    }

    func testSupportedContainers() {
        XCTAssertTrue(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.mp4")))
        XCTAssertTrue(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.m4v")))
        XCTAssertTrue(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.mov")))
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.webm")))
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.mkv")))
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.avi")))
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.wmv")))
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.flv")))
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.ogv")))
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.mpg")))
    }
}
