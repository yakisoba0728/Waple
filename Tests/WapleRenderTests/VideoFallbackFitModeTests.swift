import XCTest
@testable import WapleCore
@testable import WapleRender

/// 감사 V06 회귀: 비디오 폴터(<video> 태그) 경로가 object-fit 을 cover 로 하드코드해
/// SceneRenderSettings.fitMode(정상 경로 VideoRenderer 의 videoGravity 와 같은 설정)를 무시했다.
final class VideoFallbackFitModeTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
    }

    /// 매핑은 정상 경로 VideoRenderer.mount 의 videoGravity 분기와 대응:
    /// .fit → contain(.resizeAspect), .fill → cover(.resizeAspectFill), .stretch → fill(.resize).
    func testFitModeMapsToObjectFit() {
        XCTAssertTrue(VideoFallbackHTML.html(forVideoFile: "c.webm", fitMode: .fit)
            .contains("object-fit:contain"), ".fit 은 contain")
        XCTAssertTrue(VideoFallbackHTML.html(forVideoFile: "c.webm", fitMode: .fill)
            .contains("object-fit:cover"), ".fill 은 cover")
        XCTAssertTrue(VideoFallbackHTML.html(forVideoFile: "c.webm", fitMode: .stretch)
            .contains("object-fit:fill"), ".stretch 는 fill")
    }

    /// 호출부(WebRenderer.videoFallback)가 현재 SceneRenderSettings.fitMode 를 전달하는지 —
    /// 마운트 후 실제 DOM 의 계산된 object-fit 으로 검증한다.
    func testMountAppliesCurrentFitMode() throws {
        let oldFit = SceneRenderSettings.fitMode
        SceneRenderSettings.fitMode = .stretch
        defer { SceneRenderSettings.fitMode = oldFit }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_fallback_fit_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        try Data("dummy".utf8).write(to: dir.appendingPathComponent("wallpaper.mp4"))
        try #"{"type":"video","file":"wallpaper.mp4","title":"fit"}"#
            .write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let project = try ProjectJSONParser.parse(folderURL: dir)
        let renderer = WebRenderer(mode: .videoFallback)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        try renderer.mount(in: container, project: project)
        defer { renderer.teardown() }
        let web = try XCTUnwrap(renderer.webViewForTesting)

        var ready = false
        let deadline = Date(timeIntervalSinceNow: 5)
        while !ready, Date() < deadline {
            ready = pumpEvalJS(web, "document.querySelector('video') !== null") as? Bool == true
        }
        XCTAssertTrue(ready, "폴터 문서 로드 실패")
        XCTAssertEqual(
            pumpEvalJS(web, "getComputedStyle(document.querySelector('video')).objectFit") as? String,
            "fill", ".stretch 설정이 object-fit:fill 로 반영돼야 한다")
    }
}
