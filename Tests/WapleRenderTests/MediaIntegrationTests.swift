import XCTest
import WebKit
import WapleCore
@testable import WapleRender

final class NowPlayingParseTests: XCTestCase {
    func testParsePlayingMusic() {
        let out = "1\tSong A\tArtist B\tAlbum C\t12.5\t240.0\n"
        let i = AppleScriptNowPlayingProvider.parse(out, app: "Music")
        XCTAssertEqual(i, NowPlayingInfo(state: .playing, title: "Song A", artist: "Artist B",
                                         album: "Album C", position: 12.5, duration: 240.0))
    }

    func testParseSpotifyDurationMs() {
        let i = AppleScriptNowPlayingProvider.parse("2\tT\tA\tAl\t3.0\t185000", app: "Spotify")
        XCTAssertEqual(i?.state, .paused)
        XCTAssertEqual(i?.duration ?? 0, 185, accuracy: 0.001, "Spotify 는 ms → 초")
    }

    func testParseStoppedAndGarbage() {
        XCTAssertEqual(AppleScriptNowPlayingProvider.parse("0", app: "Music")?.state, .stopped)
        XCTAssertNil(AppleScriptNowPlayingProvider.parse("", app: "Music"))
        XCTAssertNil(AppleScriptNowPlayingProvider.parse("xyz\ta", app: "Music"))
    }

    func testRunningPlayerPreference() {
        XCTAssertEqual(AppleScriptNowPlayingProvider.runningPlayer(
            bundleIds: ["com.apple.Music", "com.spotify.client"]), "Spotify", "둘 다 실행 → Spotify 우선")
        XCTAssertEqual(AppleScriptNowPlayingProvider.runningPlayer(bundleIds: ["com.apple.Music"]), "Music")
        XCTAssertNil(AppleScriptNowPlayingProvider.runningPlayer(bundleIds: ["com.other.app"]))
    }
}

/// 정적 프로바이더 주입 → 웹 페이지의 미디어 리스너가 상태/속성/타임라인을 실제로 수신하는지.
final class WebMediaDeliveryTests: XCTestCase {
    private struct FakeProvider: NowPlayingProvider {
        func fetch() -> NowPlayingInfo? {
            NowPlayingInfo(state: .playing, title: "T1", artist: "A1", album: "L1", position: 7, duration: 100)
        }
    }

    func testListenersReceiveMedia() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_web_media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let html = """
        <html><body><script>
        window.__got = {};
        window.wallpaperRegisterMediaStatusListener(function(e) { window.__got.state = e.state; });
        window.wallpaperRegisterMediaPropertiesListener(function(e) { window.__got.title = e.title; window.__got.artist = e.artist; });
        window.wallpaperRegisterMediaTimelineListener(function(e) { window.__got.pos = e.position; });
        </script></body></html>
        """
        try html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try #"{"title":"m","type":"web","file":"index.html"}"#
            .write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let project = try ProjectJSONParser.parse(folderURL: dir)
        let r = WebRenderer(mode: .web)
        r.nowPlayingProvider = FakeProvider()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200)), project: project)
        defer { r.teardown() }

        // mediaListen 메시지 → 폴링 시작 → 첫 배달까지 스핀 대기.
        let deadline = Date().addingTimeInterval(10)
        var got: [String: Any] = [:]
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let sem = expectation(description: "js")
            r.webViewForTesting?.evaluateJavaScript("JSON.stringify(window.__got)") { v, _ in
                if let s = v as? String, let d = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { got = obj }
                sem.fulfill()
            }
            wait(for: [sem], timeout: 2)
            if got["state"] != nil, got["title"] != nil, got["pos"] != nil { break }
        }
        XCTAssertEqual(got["state"] as? Int, 1)
        XCTAssertEqual(got["title"] as? String, "T1")
        XCTAssertEqual(got["artist"] as? String, "A1")
        XCTAssertEqual(got["pos"] as? Double ?? -1, 7, accuracy: 0.001)
    }
}
