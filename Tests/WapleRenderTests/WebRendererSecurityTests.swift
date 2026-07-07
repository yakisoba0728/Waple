import XCTest
import WebKit
@testable import WapleCore
@testable import WapleRender

final class WebRendererSecurityTests: XCTestCase {
    func testWebRendererUsesNonPersistentDataStore() throws {
        let dir = try makeWebProject(html: "<html><body>ok</body></html>")
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = try ProjectJSONParser.parse(folderURL: dir)
        let renderer = WebRenderer(mode: .web)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))

        try renderer.mount(in: container, project: project)
        defer { renderer.teardown() }

        let web = try XCTUnwrap(renderer.webViewForTesting)
        XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
    }

    func testWebRendererBlocksExternalTopFrameNavigation() throws {
        let html = """
        <html><body id="body">original<script>
        setTimeout(function() { window.location.href = 'waple-asset://evil/other.html'; }, 50);
        </script></body></html>
        """
        let dir = try makeWebProject(html: html, extraFiles: ["other.html": "<html><body>evil</body></html>"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = try ProjectJSONParser.parse(folderURL: dir)
        let renderer = WebRenderer(mode: .web)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))

        try renderer.mount(in: container, project: project)
        defer { renderer.teardown() }
        let web = try XCTUnwrap(renderer.webViewForTesting)

        let deadline = Date(timeIntervalSinceNow: 3)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        XCTAssertEqual(web.url?.scheme, WallpaperSchemeHandler.scheme)
        XCTAssertEqual(web.url?.host, WallpaperSchemeHandler.host)
    }

    func testSchemeHandlerRejectsUnexpectedHost() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("waple-web-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("secret".utf8).write(to: root.appendingPathComponent("secret.txt"))

        let handler = WallpaperSchemeHandler(rootURL: root)
        let task = FakeSchemeTask(url: URL(string: "waple-asset://evil/secret.txt")!)
        handler.webView(WKWebView(), start: task)
        waitForTask(task)

        XCTAssertEqual(task.statusCode, 404)
        XCTAssertEqual(task.receivedData, Data())
    }

    func testSchemeHandlerDoesNotReturnWildcardCORSForAssetOrigin() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("waple-web-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("ok".utf8).write(to: root.appendingPathComponent("index.html"))

        let handler = WallpaperSchemeHandler(rootURL: root)
        let task = FakeSchemeTask(url: URL(string: "waple-asset://wallpaper/index.html")!)
        handler.webView(WKWebView(), start: task)
        waitForTask(task)

        XCTAssertEqual(task.statusCode, 200)
        XCTAssertNotEqual(task.responseHeaders["Access-Control-Allow-Origin"], "*")
    }

    func testSchemeHandlerStreamsLargeFilesInChunks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("waple-web-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let payload = Data(repeating: 0x7a, count: 200_000)
        try payload.write(to: root.appendingPathComponent("large.bin"))

        let handler = WallpaperSchemeHandler(rootURL: root)
        let task = FakeSchemeTask(url: URL(string: "waple-asset://wallpaper/large.bin")!)
        handler.webView(WKWebView(), start: task)
        waitForTask(task)

        XCTAssertEqual(task.statusCode, 200)
        XCTAssertEqual(task.receivedData, payload)
        XCTAssertGreaterThan(task.dataEventCount, 1)
    }

    private func makeWebProject(html: String, extraFiles: [String: String] = [:]) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("waple-web-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        for (name, contents) in extraFiles {
            try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try #"{"type":"web","file":"index.html","title":"security"}"#.write(
            to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8
        )
        return dir
    }

    private func waitForTask(_ task: FakeSchemeTask, timeout: TimeInterval = 3) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !task.finished, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }
}

private final class FakeSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var response: URLResponse?
    private(set) var receivedData = Data()
    private(set) var dataEventCount = 0
    private(set) var finished = false
    private(set) var failedError: Error?

    var statusCode: Int? { (response as? HTTPURLResponse)?.statusCode }
    var responseHeaders: [String: String] {
        (response as? HTTPURLResponse)?.allHeaderFields.reduce(into: [String: String]()) { out, item in
            if let key = item.key as? String, let value = item.value as? String {
                out[key] = value
            }
        } ?? [:]
    }

    init(url: URL) {
        self.request = URLRequest(url: url)
        super.init()
    }

    func didReceive(_ response: URLResponse) {
        self.response = response
    }

    func didReceive(_ data: Data) {
        dataEventCount += 1
        receivedData.append(data)
    }

    func didFinish() {
        finished = true
    }

    func didFailWithError(_ error: Error) {
        failedError = error
        finished = true
    }
}
