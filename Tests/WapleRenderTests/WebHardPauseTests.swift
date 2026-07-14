import XCTest
import WebKit
@testable import WapleCore
@testable import WapleRender

final class WebHardPauseTests: XCTestCase {
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private(set) var finished = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true
        }
    }

    private var webViews: [WKWebView] = []
    private var windows: [NSWindow] = []
    private var navigationWaiters: [NavigationWaiter] = []

    private let deterministicRAFPrelude = #"""
    (function () {
      var nextID = 1;
      var handles = Object.create(null);
      var nativeSetTimeout = window.setTimeout.bind(window);
      var nativeClearTimeout = window.clearTimeout.bind(window);
      window.requestAnimationFrame = function (callback) {
        var id = nextID++;
        handles[id] = nativeSetTimeout(function () {
          delete handles[id];
          callback(performance.now());
        }, 16);
        return id;
      };
      window.cancelAnimationFrame = function (id) {
        if (!handles[id]) { return; }
        nativeClearTimeout(handles[id]);
        delete handles[id];
      };
    })();
    """#

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

    private func makeControllerWebView(
        prelude: String? = nil,
        html: String = "<html><body>ready</body></html>"
    ) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        if let prelude {
            controller.addUserScript(WKUserScript(
                source: prelude,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }
        controller.addUserScript(WKUserScript(
            source: WebHardPauseJS.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController = controller
        let web = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 128, height: 72),
            configuration: configuration
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 128, height: 72),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFront(nil)
        let navigationWaiter = NavigationWaiter()
        web.navigationDelegate = navigationWaiter
        navigationWaiters.append(navigationWaiter)
        windows.append(window)
        webViews.append(web)
        web.loadHTMLString(html, baseURL: nil)
        XCTAssertTrue(waitUntil {
            navigationWaiter.finished &&
                pumpEvalJS(web, "document.readyState === 'complete'") as? Bool == true
        })
        return web
    }

    private func object(_ web: WKWebView, _ expression: String) throws -> [String: Any] {
        let raw = try XCTUnwrap(
            pumpEvalJS(web, "JSON.stringify(\(expression))") as? String
        )
        let data = try XCTUnwrap(raw.data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    func testSchedulersFreezeAndResumeExactlyOnce() throws {
        let web = makeControllerWebView(prelude: deterministicRAFPrelude)
        _ = pumpEvalJS(web, """
        window.__counts = { raf: 0, timeout: 0, interval: 0 };
        window.__rafLoop = function () {
          window.__counts.raf += 1;
          requestAnimationFrame(window.__rafLoop);
        };
        requestAnimationFrame(window.__rafLoop);
        setTimeout(function () { window.__counts.timeout += 1; }, 500);
        setInterval(function () { window.__counts.interval += 1; }, 60);
        """)
        XCTAssertTrue(waitUntil {
            let counts = try? self.object(web, "window.__counts")
            return (counts?["raf"] as? Int ?? 0) >= 2 &&
                (counts?["interval"] as? Int ?? 0) >= 1
        })

        _ = pumpEvalJS(web, """
        window.__pauseClock = performance.now();
        window.__wapleHardPauseController.setPaused(true);
        """)
        let frozen = try object(web, """
        ({ counts: window.__counts, now: performance.now() })
        """)
        spin(0.30)
        let stillFrozen = try object(web, """
        ({ counts: window.__counts, now: performance.now() })
        """)
        XCTAssertEqual(
            (frozen["counts"] as? [String: Any])?["raf"] as? Int,
            (stillFrozen["counts"] as? [String: Any])?["raf"] as? Int
        )
        XCTAssertEqual(
            (frozen["counts"] as? [String: Any])?["interval"] as? Int,
            (stillFrozen["counts"] as? [String: Any])?["interval"] as? Int
        )
        XCTAssertEqual(
            (frozen["counts"] as? [String: Any])?["timeout"] as? Int,
            (stillFrozen["counts"] as? [String: Any])?["timeout"] as? Int
        )
        XCTAssertGreaterThan(
            stillFrozen["now"] as? Double ?? 0,
            (frozen["now"] as? Double ?? 0) + 200,
            "hard pause must not virtualize performance.now()"
        )

        _ = pumpEvalJS(web, """
        window.__wapleHardPauseController.setPaused(false);
        window.__wapleHardPauseController.setPaused(false);
        """)
        XCTAssertTrue(waitUntil(timeout: 2) {
            let counts = try? self.object(web, "window.__counts")
            return (counts?["timeout"] as? Int) == 1 &&
                (counts?["raf"] as? Int ?? 0) >
                ((frozen["counts"] as? [String: Any])?["raf"] as? Int ?? 0) &&
                (counts?["interval"] as? Int ?? 0) >
                ((frozen["counts"] as? [String: Any])?["interval"] as? Int ?? 0)
        })
        XCTAssertEqual(try object(web, "window.__counts")["timeout"] as? Int, 1)
    }

    func testPausedCreationCrossClearAndRemainingDelay() throws {
        let web = makeControllerWebView()
        _ = pumpEvalJS(web, """
        window.__fired = {
          timeout: 0, interval: 0, raf: 0, remaining: 0, stringHandler: 0
        };
        var keep = setTimeout(function () { window.__fired.remaining += 1; }, 280);
        """)
        spin(0.07)
        _ = pumpEvalJS(web, """
        window.__wapleHardPauseController.setPaused(true);
        var timeoutID = setTimeout(function () { window.__fired.timeout += 1; }, 20);
        var intervalID = setInterval(function () { window.__fired.interval += 1; }, 20);
        var rafID = requestAnimationFrame(function () { window.__fired.raf += 1; });
        setTimeout("window.__fired.stringHandler += 1;", 20);
        clearInterval(timeoutID);
        clearTimeout(intervalID);
        cancelAnimationFrame(rafID);
        """)
        spin(0.30)
        XCTAssertEqual(try object(web, "window.__fired")["remaining"] as? Int, 0)
        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(false);")
        spin(0.10)
        XCTAssertEqual(try object(web, "window.__fired")["remaining"] as? Int, 0)
        XCTAssertTrue(waitUntil {
            (try? self.object(web, "window.__fired")["remaining"] as? Int) == 1
        })
        let fired = try object(web, "window.__fired")
        XCTAssertEqual(fired["timeout"] as? Int, 0)
        XCTAssertEqual(fired["interval"] as? Int, 0)
        XCTAssertEqual(fired["raf"] as? Int, 0)
        XCTAssertEqual(fired["stringHandler"] as? Int, 1)
    }

    func testIntervalResumesAtRemainingPhaseThenUsesOriginalPeriod() throws {
        let web = makeControllerWebView()
        _ = pumpEvalJS(web, """
        window.__intervalFires = [];
        setInterval(function () {
          window.__intervalFires.push(performance.now());
        }, 240);
        """)
        spin(0.08)
        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(true);")
        spin(0.25)
        let resumedAt = try XCTUnwrap(
            pumpEvalJS(web, """
            window.__wapleHardPauseController.setPaused(false);
            performance.now();
            """) as? Double
        )
        XCTAssertTrue(waitUntil(timeout: 1.2) {
            (pumpEvalJS(web, "window.__intervalFires.length") as? Int ?? 0) >= 2
        })
        let times = try XCTUnwrap(pumpEvalJS(web, "window.__intervalFires") as? [Double])
        XCTAssertGreaterThan(times[0] - resumedAt, 80)
        XCTAssertLessThan(times[0] - resumedAt, 230)
        XCTAssertGreaterThan(times[1] - times[0], 180)
        XCTAssertLessThan(times[1] - times[0], 330)
    }
}
