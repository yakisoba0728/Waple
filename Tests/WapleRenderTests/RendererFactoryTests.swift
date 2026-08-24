import XCTest
@testable import WapleRender
import WapleCore

/// [2026-08-25] `@MainActor` — `VideoRenderer`/`RendererFactory` 가 `@MainActor` 가 되면서
/// 필요해졌다. 그 타입들은 원래부터 "상태가 메인 큐 한정"(파일 머리말)이었고 이제 타입이 그걸 말한다.
@MainActor
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

    /// ffmpeg 유무로 갈리는 라우팅. else 분기의 종전 단언(7종 전부 WebRenderer)은 F556 이전 규약이었고,
    /// ffmpeg 가 깔린 개발 머신에서는 이 분기 자체를 타지 않아 낡은 채로 남아 있었다(CI 러너에 ffmpeg
    /// 부재 → 6종 실패로 노출). 현 규약: ffmpeg 없으면 WKWebView 가 실제 재생 가능한 webm 만 폴백하고,
    /// 나머지는 nil — 검은 화면을 apply 성공으로 오표시하지 않기 위해 지원 불가로 표면화한다.
    /// (컨테이너 판정 자체의 결정론적 커버리지는 MediaFixRegressionTests 의 F556 회귀 테스트.)
    func testUnsupportedCodecVideoRoutesByFFmpegAvailability() {
        for ext in ["webm", "mkv", "avi", "wmv", "flv", "ogv", "mpg"] {
            let r = RendererFactory.makeRenderer(for: project(type: .video, file: "a.\(ext)"))
            if FFmpegConverter.isAvailable {
                XCTAssertTrue(r is VideoRenderer, "\(ext) should route to VideoRenderer for ffmpeg conversion")
            } else if RendererFactory.webViewPlayableContainer(ext) {
                XCTAssertTrue(r is WebRenderer, "\(ext) should fall back to WebRenderer when ffmpeg is unavailable")
            } else {
                XCTAssertNil(r, "\(ext) is unplayable without ffmpeg — must surface as unsupported, not a black WebRenderer")
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
