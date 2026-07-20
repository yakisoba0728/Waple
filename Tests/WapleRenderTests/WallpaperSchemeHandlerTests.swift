import XCTest
import WebKit
@testable import WapleRender

final class WallpaperSchemeHandlerTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/wp", isDirectory: true)

    func testResolvesNormalPath() {
        let u = WallpaperSchemeHandler.fileURL(forRequestPath: "/index.html", root: root)
        XCTAssertEqual(u?.path, "/tmp/wp/index.html")
    }

    func testResolvesNestedPath() {
        let u = WallpaperSchemeHandler.fileURL(forRequestPath: "/js/a.js", root: root)
        XCTAssertEqual(u?.path, "/tmp/wp/js/a.js")
    }

    func testRejectsPathTraversal() {
        XCTAssertNil(WallpaperSchemeHandler.fileURL(forRequestPath: "/../etc/passwd", root: root))
        XCTAssertNil(WallpaperSchemeHandler.fileURL(forRequestPath: "/../../secret", root: root))
    }

    /// URL.path 는 이미 퍼센트 디코딩되어 들어오므로 %2e%2e 도 ../ 로 풀려 거부돼야 한다.
    func testRejectsPercentEncodedTraversal() {
        let p1 = URL(string: "waple-asset://wallpaper/%2e%2e/secret")!.path
        XCTAssertNil(WallpaperSchemeHandler.fileURL(forRequestPath: p1, root: root))
        let p2 = URL(string: "waple-asset://wallpaper/%2e%2e%2fsecret")!.path
        XCTAssertNil(WallpaperSchemeHandler.fileURL(forRequestPath: p2, root: root))
    }

    /// 빈/루트 경로는 루트 자신으로 해석돼야 한다.
    func testRootItselfResolves() {
        XCTAssertEqual(WallpaperSchemeHandler.fileURL(forRequestPath: "/", root: root)?.path, "/tmp/wp")
    }

    /// 루트와 이름 접두사를 공유하는 형제 디렉터리는 거부돼야 한다(가드의 "+ /" 가 막는다).
    func testRejectsSiblingPrefix() {
        XCTAssertNil(WallpaperSchemeHandler.fileURL(forRequestPath: "/../wp-evil/x", root: root))
    }

    // MARK: - MIME (미디어 확장자는 LaunchServices 무관 고정 — webm 이 octet-stream 이면 <video> 소스 선택 실패)

    func testMediaExtensionsMapToExactMIME() {
        XCTAssertEqual(WallpaperSchemeHandler.mimeType(for: URL(fileURLWithPath: "/a/pv.webm")), "video/webm")
        XCTAssertEqual(WallpaperSchemeHandler.mimeType(for: URL(fileURLWithPath: "/a/B.MP4")), "video/mp4")
        XCTAssertEqual(WallpaperSchemeHandler.mimeType(for: URL(fileURLWithPath: "/a/c.m4v")), "video/x-m4v")
        XCTAssertEqual(WallpaperSchemeHandler.mimeType(for: URL(fileURLWithPath: "/a/c.ogv")), "video/ogg")
        XCTAssertEqual(WallpaperSchemeHandler.mimeType(for: URL(fileURLWithPath: "/a/c.ogg")), "audio/ogg")
    }

    func testNonMediaMIMEUnchanged() {
        XCTAssertEqual(WallpaperSchemeHandler.mimeType(for: URL(fileURLWithPath: "/a/index.html")), "text/html")
        XCTAssertEqual(WallpaperSchemeHandler.mimeType(for: URL(fileURLWithPath: "/a/img.png")), "image/png")
        XCTAssertEqual(WallpaperSchemeHandler.mimeType(for: URL(fileURLWithPath: "/a/blob.zzznope")), "application/octet-stream")
    }

    // MARK: - Range 파싱 (RFC 7233 단일 범위; <video> 미디어 로더가 보냄)

    func testRangeAbsentIsFull() {
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader(nil, fileSize: 100), .full)
    }

    func testRangeOpenEnded() {
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader("bytes=0-", fileSize: 100), .partial(0..<100))
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader("bytes=40-", fileSize: 100), .partial(40..<100))
    }

    func testRangeBounded() {
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader("bytes=10-19", fileSize: 100), .partial(10..<20))
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader("bytes=0-0", fileSize: 100), .partial(0..<1))
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader("Bytes=0-9", fileSize: 100), .partial(0..<10))
    }

    func testRangeEndClampsToFileSize() {
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader("bytes=50-1000", fileSize: 100), .partial(50..<100))
    }

    func testRangeSuffix() {
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader("bytes=-10", fileSize: 100), .partial(90..<100))
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader("bytes=-200", fileSize: 100), .partial(0..<100))
    }

    func testRangeUnsatisfiableWhenStartBeyondEOF() {
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader("bytes=100-", fileSize: 100), .unsatisfiable)
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader("bytes=0-", fileSize: 0), .unsatisfiable)
    }

    func testRangeMalformedFallsBackToFull() {
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader("items=0-10", fileSize: 100), .full)
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader("bytes=10-5", fileSize: 100), .full)
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader("bytes=abc-", fileSize: 100), .full)
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader("bytes=0-1,5-9", fileSize: 100), .full)
        XCTAssertEqual(WallpaperSchemeHandler.parseRangeHeader("bytes=", fileSize: 100), .full)
    }

    /// 패키지 안 심볼릭 링크가 루트 밖을 가리키면 거부돼야 한다(실디스크 검증).
    func testRejectsSymlinkEscape() throws {
        let fm = FileManager.default
        let realRoot = fm.temporaryDirectory.appendingPathComponent("wp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: realRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: realRoot) }
        let outside = fm.temporaryDirectory.appendingPathComponent("secret-\(UUID().uuidString).txt")
        try Data("topsecret".utf8).write(to: outside)
        defer { try? fm.removeItem(at: outside) }
        let link = realRoot.appendingPathComponent("leak")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(WallpaperSchemeHandler.fileURL(forRequestPath: "/leak", root: realRoot))
    }

    // MARK: - 감사 H 회귀 (didReceive 를 io 큐에서 직접 — main.sync 왕복 결합 해소)

    /// 응답 헤더와 데이터 청크가 메인 스레드가 아닌 백그라운드 io 큐에서 전달돼야 한다.
    /// main.sync 왕복이면 메인 큐가 바쁠 때 스트리밍 처리량이 같이 멈춘다.
    func testSchemeHandlerDeliversResponseAndChunksOffMainThread() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wp-io-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })  // 64KB 청크 여러 개가 되는 크기
        try payload.write(to: root.appendingPathComponent("pv.webm"))

        let handler = WallpaperSchemeHandler(rootURL: root)
        let task = ThreadRecordingSchemeTask(url: URL(string: "waple-asset://wallpaper/pv.webm")!)
        handler.webView(WKWebView(), start: task)
        let deadline = Date(timeIntervalSinceNow: 3)
        while !task.finished, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        XCTAssertTrue(task.finished)
        XCTAssertEqual((task.response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(task.receivedData, payload)
        XCTAssertGreaterThan(task.dataEvents, 1)  // 청크 스트리밍 경로를 실제로 탔는지
        XCTAssertEqual(task.responseOnMainThread, false)
        XCTAssertFalse(task.anyDataOnMainThread)
    }
}

/// didReceive 호출 스레드를 기록하는 WKURLSchemeTask 목 — 감사 H 회귀 테스트 전용.
private final class ThreadRecordingSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var response: URLResponse?
    private(set) var receivedData = Data()
    private(set) var dataEvents = 0
    private(set) var finished = false
    private(set) var responseOnMainThread: Bool?
    private(set) var anyDataOnMainThread = false

    init(url: URL) {
        self.request = URLRequest(url: url)
        super.init()
    }

    func didReceive(_ response: URLResponse) {
        responseOnMainThread = Thread.isMainThread
        self.response = response
    }

    func didReceive(_ data: Data) {
        if Thread.isMainThread { anyDataOnMainThread = true }
        dataEvents += 1
        receivedData.append(data)
    }

    func didFinish() {
        finished = true
    }

    func didFailWithError(_ error: Error) {
        finished = true
    }
}
