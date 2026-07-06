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
        // mkv/avi/webm: ffmpeg 있으면 네이티브 변환(VideoRenderer), 없으면 WKWebView 폴백(WebRenderer).
        let r = RendererFactory.makeRenderer(for: project(type: .video, file: "a.webm"))
        if FFmpegConverter.isAvailable {
            XCTAssertTrue(r is VideoRenderer)
        } else {
            XCTAssertTrue(r is WebRenderer)
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
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.webm")))
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.mkv")))
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.avi")))  // ffmpeg 변환 대상
    }
}
