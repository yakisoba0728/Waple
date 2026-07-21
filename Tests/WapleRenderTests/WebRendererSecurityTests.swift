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

    /// 감사 S1: 서브프레임(isMainFrame == false)은 톱프레임과 별도로 게이팅해야 한다 — 아니면
    /// <iframe src="https://…"> 가 무검증 로드된다. 실제 http(s) 도메인은 도달 불가/도달 시 모두
    /// about:blank 로 남아 차단 여부를 구분 못 하므로(네트워크 비결정), 같은 waple-asset 스킴의
    /// 다른 호스트로 대신한다 — isAllowedSubframeURL 이 검사하는 것과 동일한 불허 분기이며 로컬/결정적.
    func testWebRendererBlocksSubframeNavigationToDisallowedHost() throws {
        let html = """
        <html><body>top<iframe id="f" src="waple-asset://evil/other.html"></iframe></body></html>
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

        // 차단되면 서브프레임은 최초 about:blank 그대로(동일 출처라 .href 읽기 가능). 차단되지 않으면
        // waple-asset://evil/... 로 커밋되어(스킴핸들러가 호스트 불일치로 404 를 주더라도 내비게이션
        // 자체는 커밋) 교차 출처가 되므로 .href 읽기가 실패(nil)하거나 다른 값이 되어 단언이 깨진다.
        let href = pumpEvalJS(web, "document.getElementById('f').contentWindow.location.href")
        XCTAssertEqual(href as? String, "about:blank")
    }

    /// 감사 S1 짝: 허용된 로컬(에셋) 서브프레임 내비게이션은 여전히 정상 로드돼야 한다(과차단 방지).
    func testWebRendererAllowsLocalAssetSubframeNavigation() throws {
        let html = """
        <html><body>top<iframe id="f" src="waple-asset://wallpaper/other.html"></iframe></body></html>
        """
        let dir = try makeWebProject(html: html, extraFiles: ["other.html": "<html><body id=\"ok\">subframe-ok</body></html>"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = try ProjectJSONParser.parse(folderURL: dir)
        let renderer = WebRenderer(mode: .web)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))

        try renderer.mount(in: container, project: project)
        defer { renderer.teardown() }
        let web = try XCTUnwrap(renderer.webViewForTesting)

        let deadline = Date(timeIntervalSinceNow: 3)
        var text: String?
        while text != "subframe-ok", Date() < deadline {
            text = pumpEvalJS(web, """
                document.getElementById('f').contentDocument && \
                document.getElementById('f').contentDocument.getElementById('ok') && \
                document.getElementById('f').contentDocument.getElementById('ok').textContent
                """) as? String
        }
        XCTAssertEqual(text, "subframe-ok")
    }

    /// isAllowedSubframeURL 순수 함수 단위 검증(WebKit 불요, 결정적) — 특히 이번에 새로 추가된
    /// data: 분기는 위 통합 테스트로는 커버되지 않는 유일한 신규 로직이라 여기서 직접 확인한다.
    func testIsAllowedSubframeURLGate() {
        XCTAssertFalse(WebRenderer.isAllowedSubframeURL(URL(string: "https://attacker.example/evil.html")))
        XCTAssertFalse(WebRenderer.isAllowedSubframeURL(URL(string: "wss://attacker.example/socket")))
        XCTAssertFalse(WebRenderer.isAllowedSubframeURL(URL(string: "waple-asset://evil/other.html")))
        XCTAssertFalse(WebRenderer.isAllowedSubframeURL(nil))
        XCTAssertTrue(WebRenderer.isAllowedSubframeURL(URL(string: "data:text/plain,hi")))
        XCTAssertTrue(WebRenderer.isAllowedSubframeURL(URL(string: "about:blank")))
        XCTAssertTrue(WebRenderer.isAllowedSubframeURL(URL(string: "waple-asset://wallpaper/index.html")))
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

    /// <video> 미디어 로더는 Range 요청을 보낸다 — 206 + Content-Range + 해당 바이트만 응답해야
    /// 소스 선택이 성공한다(전체 200 만 주면 networkState=NO_SOURCE 로 로드 실패).
    func testSchemeHandlerServesPartialContentForRangeRequest() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("waple-web-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let payload = Data((0..<100_000).map { UInt8($0 % 251) })  // 위치 판별 가능한 패턴
        try payload.write(to: root.appendingPathComponent("pv.webm"))

        let handler = WallpaperSchemeHandler(rootURL: root)
        let task = FakeSchemeTask(url: URL(string: "waple-asset://wallpaper/pv.webm")!, range: "bytes=1000-1999")
        handler.webView(WKWebView(), start: task)
        waitForTask(task)

        XCTAssertEqual(task.statusCode, 206)
        XCTAssertEqual(task.receivedData, payload.subdata(in: 1000..<2000))
        XCTAssertEqual(task.responseHeaders["Content-Type"], "video/webm")
        XCTAssertEqual(task.responseHeaders["Content-Range"], "bytes 1000-1999/100000")
        XCTAssertEqual(task.responseHeaders["Content-Length"], "1000")
        XCTAssertEqual(task.responseHeaders["Accept-Ranges"], "bytes")
    }

    /// 첫 프로브가 흔히 보내는 open-ended Range(bytes=0-)도 206 전체로 서빙돼야 한다.
    func testSchemeHandlerServesOpenEndedRange() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("waple-web-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let payload = Data(repeating: 0x42, count: 5_000)
        try payload.write(to: root.appendingPathComponent("pv.webm"))

        let handler = WallpaperSchemeHandler(rootURL: root)
        let task = FakeSchemeTask(url: URL(string: "waple-asset://wallpaper/pv.webm")!, range: "bytes=0-")
        handler.webView(WKWebView(), start: task)
        waitForTask(task)

        XCTAssertEqual(task.statusCode, 206)
        XCTAssertEqual(task.receivedData, payload)
        XCTAssertEqual(task.responseHeaders["Content-Range"], "bytes 0-4999/5000")
    }

    /// 무회귀: Range 없는 요청(정적 에셋 경로)은 종전대로 200 전체 — 이제 Content-Length 도 정확해야 한다.
    func testSchemeHandlerFullResponseWithoutRangeUnchanged() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("waple-web-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let payload = Data(repeating: 0x41, count: 12_345)
        try payload.write(to: root.appendingPathComponent("app.js"))

        let handler = WallpaperSchemeHandler(rootURL: root)
        let task = FakeSchemeTask(url: URL(string: "waple-asset://wallpaper/app.js")!)
        handler.webView(WKWebView(), start: task)
        waitForTask(task)

        XCTAssertEqual(task.statusCode, 200)
        XCTAssertEqual(task.receivedData, payload)
        XCTAssertEqual(task.responseHeaders["Content-Length"], "12345")
        XCTAssertEqual(task.responseHeaders["Accept-Ranges"], "bytes")
    }

    /// 파일 끝 이후에서 시작하는 Range 는 416 + 빈 바디.
    func testSchemeHandlerRejectsUnsatisfiableRange() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("waple-web-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(repeating: 0x41, count: 100).write(to: root.appendingPathComponent("pv.webm"))

        let handler = WallpaperSchemeHandler(rootURL: root)
        let task = FakeSchemeTask(url: URL(string: "waple-asset://wallpaper/pv.webm")!, range: "bytes=100-")
        handler.webView(WKWebView(), start: task)
        waitForTask(task)

        XCTAssertEqual(task.statusCode, 416)
        XCTAssertEqual(task.receivedData, Data())
        XCTAssertEqual(task.responseHeaders["Content-Range"], "bytes */100")
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
    // 핸들러의 io 큐(쓰기)와 테스트 스레드(읽기)가 교차하므로 모든 상태 접근을 lock 으로 동기화한다.
    private let lock = NSLock()
    private var _response: URLResponse?
    private var _receivedData = Data()
    private var _dataEventCount = 0
    private var _finished = false
    private var _failedError: Error?

    var response: URLResponse? { lock.withLock { _response } }
    var receivedData: Data { lock.withLock { _receivedData } }
    var dataEventCount: Int { lock.withLock { _dataEventCount } }
    var finished: Bool { lock.withLock { _finished } }
    var failedError: Error? { lock.withLock { _failedError } }

    var statusCode: Int? { (response as? HTTPURLResponse)?.statusCode }
    var responseHeaders: [String: String] {
        (response as? HTTPURLResponse)?.allHeaderFields.reduce(into: [String: String]()) { out, item in
            if let key = item.key as? String, let value = item.value as? String {
                out[key] = value
            }
        } ?? [:]
    }

    init(url: URL, range: String? = nil) {
        var request = URLRequest(url: url)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        self.request = request
        super.init()
    }

    func didReceive(_ response: URLResponse) {
        lock.withLock { _response = response }
    }

    func didReceive(_ data: Data) {
        lock.withLock {
            _dataEventCount += 1
            _receivedData.append(data)
        }
    }

    func didFinish() {
        lock.withLock { _finished = true }
    }

    func didFailWithError(_ error: Error) {
        lock.withLock {
            _failedError = error
            _finished = true
        }
    }
}
