import XCTest
import WebKit
@testable import WapleCore
@testable import WapleRender

/// 감사 W-B1 회귀: 가림 → 복귀 시 JS 가 재개돼야 한다. 종전에는 복귀 분기가 resume() 을 불렀지만
/// resume() 은 수동 pause 전제(guard pausedManually)라 즉시 반환 → setPausedJS(false) 가 영원히
/// 호출되지 않아 웹 월페이퍼가 영구 정지했다. 수동 pause 는 가림 복귀로 풀리면 안 된다(resume() 전용).
final class WebRendererOcclusionTests: XCTestCase {
    func testOcclusionRoundTripResumesJSAndManualPauseWins() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_web_occlusion_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = """
        <html><body><script>
        window.__pausedLog = [];
        window.wallpaperPropertyListener = { setPaused: function (p) { window.__pausedLog.push(p ? 1 : 0); } };
        </script></body></html>
        """
        try html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try #"{"type":"web","file":"index.html","title":"occlusion"}"#
            .write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let project = try ProjectJSONParser.parse(folderURL: dir)
        let renderer = WebRenderer(mode: .web)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        try renderer.mount(in: container, project: project)
        defer { renderer.teardown() }
        let web = try XCTUnwrap(renderer.webViewForTesting)

        var ready = false
        let deadline = Date(timeIntervalSinceNow: 5)
        while !ready, Date() < deadline {
            ready = pumpEvalJS(web, "Array.isArray(window.__pausedLog)") as? Bool == true
        }
        XCTAssertTrue(ready, "테스트 페이지 로드 실패")

        // setPausedJS 는 fire-and-forget — WKWebView JS 평가는 FIFO 이므로 다음 pumpEvalJS 왕복이
        // 앞선 pause/resume JS 의 실행 완료를 보장한다.
        func pausedLog() -> [Int] { pumpEvalJS(web, "window.__pausedLog") as? [Int] ?? [] }

        renderer.occlusionChanged(visible: false)   // 가림 → 정지
        renderer.occlusionChanged(visible: true)    // 복귀 → 재개(버그 시 아무 일도 일어나지 않았다)
        XCTAssertEqual(pausedLog(), [1, 0], "가림 복귀가 JS 를 재개해야(W-B1)")
        XCTAssertFalse(renderer.pausedByOcclusion)

        renderer.pause()                            // 수동 정지
        renderer.occlusionChanged(visible: false)   // 가림 — 같은 상태(true) 재전송은 브리지가 dedupe
        renderer.occlusionChanged(visible: true)    // 복귀 — 수동 정지 유지: false 가 나가면 로그에 0 추가됨
        XCTAssertEqual(pausedLog(), [1, 0, 1], "수동 pause 중 가림 복귀가 재개(false)를 보내면 안 됨")
        renderer.resume()                           // 수동 해제로만 재개
        XCTAssertEqual(pausedLog(), [1, 0, 1, 0], "resume() 이 재개를 전달해야")
    }

    func testManualResumeWaitsForOcclusionBeforeRestartingAllConsumers() throws {
        final class FakeAudioProvider: AudioSpectrumProviding {
            var onFrame: (([Float]) -> Void)?
            private(set) var running = false
            private(set) var startCount = 0
            private(set) var stopCount = 0
            func start() {
                guard !running else { return }
                running = true
                startCount += 1
            }
            func stop() {
                guard running else { return }
                running = false
                stopCount += 1
            }
        }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_web_effective_pause_\(UUID().uuidString)",
                                  isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        <html><body><script>
        window.__pausedLog = [];
        window.wallpaperPropertyListener = {
          setPaused: function (value) { window.__pausedLog.push(value ? 1 : 0); }
        };
        wallpaperRegisterAudioListener(function () {});
        wallpaperRegisterMediaStatusListener(function () {});
        </script></body></html>
        """.write(to: dir.appendingPathComponent("index.html"),
                  atomically: true, encoding: .utf8)
        try #"{"type":"web","file":"index.html","title":"effective"}"#
            .write(to: dir.appendingPathComponent("project.json"),
                   atomically: true, encoding: .utf8)

        let provider = FakeAudioProvider()
        let renderer = WebRenderer(mode: .web)
        renderer.audioProviderFactory = { provider }
        try renderer.mount(
            in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
            project: ProjectJSONParser.parse(folderURL: dir)
        )
        defer { renderer.teardown() }
        let web = try XCTUnwrap(renderer.webViewForTesting)
        let readyDeadline = Date(timeIntervalSinceNow: 5)
        while Date() < readyDeadline,
              (!provider.running || !renderer.mediaPollingForTesting) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertTrue(provider.running)
        XCTAssertTrue(renderer.mediaPollingForTesting)

        renderer.pause()
        renderer.occlusionChanged(visible: false)
        renderer.resume()
        _ = pumpEvalJS(web, "window.__pausedLog")
        XCTAssertFalse(provider.running)
        XCTAssertFalse(renderer.mediaPollingForTesting)
        XCTAssertEqual(pumpEvalJS(web, "window.__pausedLog") as? [Int], [1])

        renderer.occlusionChanged(visible: true)
        XCTAssertTrue(provider.running)
        XCTAssertTrue(renderer.mediaPollingForTesting)
        XCTAssertEqual(pumpEvalJS(web, "window.__pausedLog") as? [Int], [1, 0])
        XCTAssertEqual(provider.startCount, 2, "initial start plus one effective resume")
        XCTAssertEqual(provider.stopCount, 1, "only the active-to-paused edge stops")
    }
}
