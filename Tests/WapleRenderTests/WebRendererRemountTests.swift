import XCTest
import WebKit
@testable import WapleCore
@testable import WapleRender

/// 감사 V06 회귀: 같은 WebRenderer 인스턴스에 mount 를 2회 호출하면 선행 정리가 없어
/// 이전 WKWebView 가 container 에 잔존하고 occlusionObserver/mouseMonitor 핸들이 덮여
/// teardown 으로도 해제 불가능하게 누수됐다. SceneRenderer.mount(시작 시 teardown 호출)와
/// 대칭으로 mount 시작 시 이전 상태를 정리해야 한다.
final class WebRendererRemountTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
    }

    private func makeWebProject() throws -> WallpaperProject {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_web_remount_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        try "<html><body>remount</body></html>"
            .write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try #"{"type":"web","file":"index.html","title":"remount"}"#
            .write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        return try ProjectJSONParser.parse(folderURL: dir)
    }

    func testRemountReplacesPreviousWebView() throws {
        let project = try makeWebProject()
        let renderer = WebRenderer(mode: .web)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        try renderer.mount(in: container, project: project)
        let first = try XCTUnwrap(renderer.webViewForTesting)

        try renderer.mount(in: container, project: project)
        defer { renderer.teardown() }
        let second = try XCTUnwrap(renderer.webViewForTesting)

        XCTAssertFalse(first === second, "재마운트는 새 WKWebView 를 만든다")
        XCTAssertNil(first.superview, "이전 WKWebView 는 container 에서 제거돼야 한다")
        let webViews = container.subviews.compactMap { $0 as? WKWebView }
        XCTAssertEqual(webViews.count, 1, "container 에 WKWebView 는 하나만 남아야 한다")
        XCTAssertTrue(webViews.first === second)
    }
}
