import XCTest
import WebKit
@testable import WapleCore
@testable import WapleRender

/// WE 의미론: wallpaperPropertyListener 를 **문서 로드 후(async)에 등록해도** 속성을 받아야 한다.
/// (WE 는 등록 즉시 전달; 현 구현은 didFinish 1회 직접 호출이라 늦은 등록이 유실 — RED 재현.)
final class WebPropertyDeliveryTests: XCTestCase {
    func testLateRegisteredListenerReceivesProperties() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_web_late", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let html = """
        <html><body><script>
        window.__got = null;
        setTimeout(function() {
          window.wallpaperPropertyListener = {
            applyUserProperties: function(p) { window.__got = p; }
          };
        }, 300);
        </script></body></html>
        """
        try html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let projectJSON = """
        {"type":"web","file":"index.html","title":"late","general":{"properties":{"speed":{"type":"slider","value":7}}}}
        """
        try projectJSON.write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let project = try ProjectJSONParser.parse(folderURL: dir)
        let r = WebRenderer(mode: .web)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        try r.mount(in: container, project: project)
        defer { r.teardown() }
        guard let web = container.subviews.compactMap({ $0 as? WKWebView }).first else {
            XCTFail("no webview"); return
        }
        // 리스너는 300ms 후 등록 — 그 뒤에도 속성이 도착해야 한다(최대 5초 폴링).
        let deadline = Date(timeIntervalSinceNow: 5)
        var got: Any? = nil
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            let sem = DispatchSemaphore(value: 0)
            web.evaluateJavaScript("JSON.stringify(window.__got)") { v, _ in got = v; sem.signal() }
            _ = sem.wait(timeout: .now() + 1)
            if let s = got as? String, s != "null" { break }
        }
        let s = try XCTUnwrap(got as? String)
        XCTAssertTrue(s.contains("speed"), "늦게 등록한 리스너가 속성을 받아야: \(s)")
        XCTAssertTrue(s.contains("7"), s)
    }
}
