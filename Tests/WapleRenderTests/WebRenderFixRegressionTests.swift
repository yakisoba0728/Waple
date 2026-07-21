import XCTest
import WebKit
@testable import WapleCore
@testable import WapleRender

/// 감사 2차 라운드 fix-g5 회귀 모음.
/// F570 Range end=Int64.max 오버플로 / F572 납비게이션 후 오디오·미디어 리셋 /
/// F573 디렉터리 재귀 열거 백그라운드화 / F574 pause 중 페이지 resume() 재개 /
/// F575 스킴 태스크 stop 경합 원자화 / F576 폴터 <video> 음량 적용.
/// (F571 서브리소스 egress 는 정책 문서화 주석이라 테스트 없음.)
final class WebRenderFixRegressionTests: XCTestCase {
    private var webViews: [WKWebView] = []
    private var windows: [NSWindow] = []
    private var navigationWaiters: [NavigationWaiter] = []

    override func tearDown() {
        for web in webViews {
            web.stopLoading()
            web.removeFromSuperview()
        }
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        webViews.removeAll()
        windows.removeAll()
        navigationWaiters.removeAll()
        super.tearDown()
    }

    // MARK: - F570: Range 헤더 end=Int64.max → end+1 산술 오버플로 트랩

    func testRangeHeaderInt64MaxEndClampsWithoutOverflow() {
        // 종전 min(end + 1, fileSize) 은 end=Int64.max 에서 트랩. 클램프 결과는 파일 크기.
        XCTAssertEqual(
            WallpaperSchemeHandler.parseRangeHeader("bytes=0-9223372036854775807", fileSize: 100),
            .partial(0..<100)
        )
        XCTAssertEqual(
            WallpaperSchemeHandler.parseRangeHeader("bytes=50-9223372036854775807", fileSize: 100),
            .partial(50..<100)
        )
        XCTAssertEqual(
            WallpaperSchemeHandler.parseRangeHeader("bytes=0-9223372036854775806", fileSize: 100),
            .partial(0..<100)
        )
    }

    // MARK: - F572: 인페이지 납비게이션 후 오디오 캡처/미디어 폴섹 리셋

    private final class FakeAudioProvider: AudioSpectrumProviding {
        var onFrame: (([Float]) -> Void)?
        private(set) var running = false
        func start() { running = true }
        func stop() { running = false }
    }

    private struct NilNowPlayingProvider: NowPlayingProvider {
        func fetch() -> NowPlayingInfo? { nil }
    }

    /// 새 문서는 이전 문서의 audioListen/mediaListen 등록을 잃는다 — 네이티브가 리셋하지
    /// 않으면 캡처+FFT+폴섹이 계속 소모된다. 리스너 없는 페이지로 이동하면 둘 다 멈춰야 한다.
    func testInPageNavigationStopsAudioCaptureAndMediaPolling() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_web_navreset_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        <html><body><script>
        wallpaperRegisterAudioListener(function () {});
        wallpaperRegisterMediaStatusListener(function () {});
        </script></body></html>
        """.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        // 이동 대상 문서는 리스너를 등록하지 않는다 — 리셋 후 다시 살아나면 안 된다.
        try "<html><body>second</body></html>"
            .write(to: dir.appendingPathComponent("second.html"), atomically: true, encoding: .utf8)
        try #"{"type":"web","file":"index.html","title":"navreset"}"#
            .write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let provider = FakeAudioProvider()
        let renderer = WebRenderer(mode: .web)
        renderer.audioProviderFactory = { provider }
        renderer.nowPlayingProvider = NilNowPlayingProvider()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
                           project: ProjectJSONParser.parse(folderURL: dir))
        defer { renderer.teardown() }
        let web = try XCTUnwrap(renderer.webViewForTesting)

        let startDeadline = Date(timeIntervalSinceNow: 5)
        while Date() < startDeadline, !(provider.running && renderer.mediaPollingForTesting) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertTrue(provider.running, "전제: 오디오 캡처 시작")
        XCTAssertTrue(renderer.mediaPollingForTesting, "전제: 미디어 폴섹 시작")

        web.evaluateJavaScript("window.location.href = 'second.html';", completionHandler: nil)
        let stopDeadline = Date(timeIntervalSinceNow: 5)
        while Date() < stopDeadline, provider.running || renderer.mediaPollingForTesting {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertFalse(provider.running, "F572: 새 문서 로드 후 오디오 캡처가 멈춰야 한다")
        XCTAssertFalse(renderer.mediaPollingForTesting, "F572: 새 문서 로드 후 미디어 폴섹이 멈춰야 한다")
        // 리스너 미등록 문서이므로 잠시 더 지켜봐도 재시작되지 않아야 한다.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertFalse(provider.running)
        XCTAssertFalse(renderer.mediaPollingForTesting)
    }

    // MARK: - F573: 재귀 열거 백그라운드화 후에도 fetchall/randomFile 전달은 동작해야

    /// 백그라운드 열거로 옮긴 뒤에도 fetchall 초기 파일 목록이 페이지에 도착하는지(기능 회귀).
    /// 스레드 분리 자체는 계측 없이는 관측 불가 — regularFiles 주석(F573)으로 계약을 고정했다.
    func testFetchAllDirectoryStillDeliversAfterBackgroundMove() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_web_fetchall_bg_\(UUID().uuidString)", isDirectory: true)
        let assets = dir.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = assets.appendingPathComponent("first.txt").resolvingSymlinksInPath().path
        let second = assets.appendingPathComponent("second.txt").resolvingSymlinksInPath().path
        try "a".write(to: URL(fileURLWithPath: first), atomically: true, encoding: .utf8)
        try "b".write(to: URL(fileURLWithPath: second), atomically: true, encoding: .utf8)
        try """
        <html><body><script>
        window.__directory = null;
        window.wallpaperPropertyListener = {
          userDirectoryFilesAddedOrChanged: function(name, files) {
            window.__directory = { name: name, files: files };
          }
        };
        </script></body></html>
        """.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try """
        {"type":"web","file":"index.html","title":"fetchall","general":{"properties":{"images":{"type":"directory","value":"assets","mode":"fetchall"}}}}
        """.write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let renderer = WebRenderer(mode: .web)
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
                           project: ProjectJSONParser.parse(folderURL: dir))
        defer { renderer.teardown() }

        let got = try waitForJSON(renderer.webViewForTesting,
                                  script: "JSON.stringify(window.__directory)") { obj in
            let files = obj["files"] as? [String] ?? []
            return files.contains(first) && files.contains(second)
        }
        XCTAssertEqual(got["name"] as? String, "images")
        XCTAssertEqual(got["files"] as? [String], [first, second])
    }

    /// directory 형식 randomFile 도 비동기 해석 후 requestId 매칭 응답이 도착해야 한다.
    func testRandomFileFromDirectoryStillRespondsAfterBackgroundMove() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_web_random_bg_\(UUID().uuidString)", isDirectory: true)
        let assets = dir.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let only = assets.appendingPathComponent("only.txt").resolvingSymlinksInPath().path
        try "ok".write(to: URL(fileURLWithPath: only), atomically: true, encoding: .utf8)
        try """
        <html><body><script>
        window.__random = null;
        window.addEventListener('load', function () {
          wallpaperRequestRandomFileForProperty('images', function(name, filePath) {
            window.__random = { name: name, filePath: filePath };
          });
        });
        </script></body></html>
        """.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try """
        {"type":"web","file":"index.html","title":"random","general":{"properties":{"images":{"type":"directory","value":"assets"}}}}
        """.write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let renderer = WebRenderer(mode: .web)
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
                           project: ProjectJSONParser.parse(folderURL: dir))
        defer { renderer.teardown() }

        let got = try waitForJSON(renderer.webViewForTesting,
                                  script: "JSON.stringify(window.__random)") { obj in
            obj["filePath"] as? String == only
        }
        XCTAssertEqual(got["name"] as? String, "images")
        XCTAssertEqual(got["filePath"] as? String, only)
    }

    // MARK: - F574: pause 중 페이지가 호출한 AudioContext.resume() 은 해제 시 재개돼야

    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private(set) var finished = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true
        }
    }

    /// WebHardPauseTests 와 같은 페이크 — resume/suspend 가 pending resolver 로 큐잉되는 컨텍스트.
    private let fakeAudioPrelude = #"""
    (function () {
      window.__audioContexts = [];
      window.__audioPending = [];
      window.__audioInitialState = 'running';

      function transition(context, state, operation) {
        return new Promise(function (resolve) {
          window.__audioPending.push(function () {
            context.state = state;
            context.operations.push(operation);
            resolve();
          });
        });
      }

      function FakeAudioContext() {
        this.state = window.__audioInitialState;
        this.operations = [];
        window.__audioContexts.push(this);
      }

      FakeAudioContext.prototype.suspend = function () {
        return transition(this, 'suspended', 'suspend');
      };
      FakeAudioContext.prototype.resume = function () {
        return transition(this, 'running', 'resume');
      };
      FakeAudioContext.prototype.close = function () {
        this.state = 'closed';
        return Promise.resolve();
      };

      window.__resolveAudio = function () {
        var resolver = window.__audioPending.shift();
        if (resolver) { resolver(); }
        return window.__audioPending.length;
      };
      window.AudioContext = FakeAudioContext;
      window.webkitAudioContext = FakeAudioContext;
    })();
    """#

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func waitUntil(timeout: TimeInterval = 3, _ predicate: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if predicate() { return true }
            spin(0.02)
        }
        return predicate()
    }

    private func makeControllerWebView(prelude: String) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: prelude, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        controller.addUserScript(WKUserScript(
            source: WebHardPauseJS.source, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        configuration.userContentController = controller
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 128, height: 72),
                            configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 128, height: 72),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFront(nil)
        let waiter = NavigationWaiter()
        web.navigationDelegate = waiter
        navigationWaiters.append(waiter)
        windows.append(window)
        webViews.append(web)
        web.loadHTMLString("<html><body>ready</body></html>", baseURL: nil)
        XCTAssertTrue(waitUntil {
            waiter.finished &&
                (pumpEvalJS(web, "document.readyState === 'complete'") as? Bool == true)
        })
        return web
    }

    /// 자동재생 정책 등으로 suspended 상태에서 pause 에 들어간 컨텍스트가 pause 중 페이지의
    /// resume() 호출을 받으면, 해제 시 재개 대상이어야 한다(종전엔 resumeAfterPause 미설정으로
    /// 영구 suspended).
    func testPageResumeDuringHardPauseResumesOnRelease() {
        let web = makeControllerWebView(prelude: fakeAudioPrelude)
        _ = pumpEvalJS(web, """
        window.__audioInitialState = 'suspended';
        window.__ctx = new AudioContext();
        window.__wapleHardPauseController.setPaused(true);
        """)
        // suspended 진입이라 pauseAudioContexts 는 이 컨텍스트를 건드리지 않는다.
        XCTAssertEqual(pumpEvalJS(web, "window.__audioPending.length") as? Int, 0)

        // pause 중 페이지가 resume() 호출 — 래핑 경로는 nativeResume 후 즉시 nativeSuspend.
        _ = pumpEvalJS(web, "window.__ctx.resume();")
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        })
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        })
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "window.__ctx.state") as? String == "suspended"
        }, "전제: pause 중 resume() 은 다시 suspend 로 귀결")

        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(false);")
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        }, "F574: 해제 시 페이지가 resume 한 컨텍스트에 재개가 큐잉돼야 한다")
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "window.__ctx.state") as? String == "running"
        }, "F574: pause 해제 후 컨텍스트가 영구 suspended 로 남으면 안 된다")
    }

    // MARK: - F575: stop 이 반환된 뒤에는 태스크 메서드가 호출되지 않아야 한다

    /// didReceive 가 stop 플래그 이후에도 들어오는지 기록하는 WKURLSchemeTask 목.
    /// (목은 예외를 던지지 않으므로 계약 위반 크래시 자체는 재현 불가 — 불변식만 검증.)
    private final class StopRecordingSchemeTask: NSObject, WKURLSchemeTask {
        let request: URLRequest
        private let guardLock = NSLock()
        private(set) var stopped = false
        private(set) var dataEvents = 0
        private(set) var receivedAfterStop = false

        init(url: URL) {
            self.request = URLRequest(url: url)
            super.init()
        }

        func markStopped() {
            guardLock.lock()
            stopped = true
            guardLock.unlock()
        }

        private func record() {
            guardLock.lock()
            if stopped { receivedAfterStop = true }
            guardLock.unlock()
        }

        var liveDataEvents: Int {
            guardLock.lock()
            defer { guardLock.unlock() }
            return dataEvents
        }

        func didReceive(_ response: URLResponse) { record() }
        func didReceive(_ data: Data) {
            guardLock.lock()
            dataEvents += 1
            if stopped { receivedAfterStop = true }
            guardLock.unlock()
        }
        func didFinish() { record() }
        func didFailWithError(_ error: Error) { record() }
    }

    func testNoSchemeTaskCallsAfterStopReturns() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("wp-stop-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        // 64KB 청크 수십 개가 되는 크기 — 스트리밍 중 stop 경합 조건.
        let payload = Data((0..<5_000_000).map { UInt8($0 % 251) })
        try payload.write(to: root.appendingPathComponent("pv.webm"))

        let handler = WallpaperSchemeHandler(rootURL: root)
        let task = StopRecordingSchemeTask(url: URL(string: "waple-asset://wallpaper/pv.webm")!)
        handler.webView(WKWebView(), start: task)
        XCTAssertTrue(waitUntil { task.liveDataEvents >= 1 }, "스트리밍 시작 전제")

        handler.webView(WKWebView(), stop: task)
        task.markStopped()
        spin(0.5)  // 잔여 청크가 전달될 시간을 충분히 준다
        XCTAssertFalse(task.receivedAfterStop,
                       "F575: stop 반환 후 didReceive 가 호출되면 WKURLSchemeTask 계약 위반")
    }

    // MARK: - F576: 폴터 <video> 에 배경별 음량 적용

    func testFallbackVideoVolumeApplied() {
        // 0(기본)은 muted 고정 — autoplay 보장이 우선.
        let muted = VideoFallbackHTML.html(forVideoFile: "clip.webm", volume: 0)
        XCTAssertTrue(muted.contains(" muted"))
        XCTAssertFalse(muted.contains(".volume="))
        // 디폴트 인자 경로도 동일(기존 호출부 호환).
        XCTAssertTrue(VideoFallbackHTML.html(forVideoFile: "clip.webm").contains(" muted"))

        // 양수 음량이면 muted 해제 + volume 프로퍼티 스크립트.
        let audible = VideoFallbackHTML.html(forVideoFile: "clip.webm", volume: 0.7)
        XCTAssertFalse(audible.contains(" muted"))
        XCTAssertTrue(audible.contains(".volume=0.700"))

        // 클램프: 1 초과 → 1.000, 음수 → muted.
        XCTAssertTrue(VideoFallbackHTML.html(forVideoFile: "c.webm", volume: 2)
            .contains(".volume=1.000"))
        XCTAssertTrue(VideoFallbackHTML.html(forVideoFile: "c.webm", volume: -1)
            .contains(" muted"))
    }

    // MARK: - 공용 헬퍼

    private func waitForJSON(_ web: WKWebView?, script: String,
                             timeout: TimeInterval = 5,
                             until predicate: ([String: Any]) -> Bool) throws -> [String: Any] {
        let web = try XCTUnwrap(web)
        let deadline = Date(timeIntervalSinceNow: timeout)
        var last: [String: Any] = [:]
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            let sem = DispatchSemaphore(value: 0)
            web.evaluateJavaScript(script) { value, _ in
                if let string = value as? String,
                   let data = string.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    last = obj
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 1)
            if predicate(last) { return last }
        }
        return last
    }
}
