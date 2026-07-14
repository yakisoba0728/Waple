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

    private let deterministicAnimationPrelude = #"""
    (function () {
      var nativeSetInterval = window.setInterval.bind(window);
      nativeSetInterval(function () {
        if (document.visibilityState !== 'hidden' ||
            typeof document.getAnimations !== 'function') {
          return;
        }
        document.getAnimations().forEach(function (animation) {
          if (animation.playState !== 'running' && animation.playState !== 'pending') {
            return;
          }
          animation.currentTime = Number(animation.currentTime || 0) + 16;
        });
      }, 16);
    })();
    """#

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

    func testOnlyRunningAudioContextsResumeAndPausedCreationStaysSuspended() throws {
        let web = makeControllerWebView(prelude: fakeAudioPrelude)
        XCTAssertEqual(
            pumpEvalJS(web, "window.AudioContext === window.webkitAudioContext") as? Bool,
            true,
            "constructor aliases must preserve identity"
        )
        _ = pumpEvalJS(web, """
        window.__audioInitialState = 'running';
        window.__runningContext = new AudioContext();
        window.__audioInitialState = 'suspended';
        window.__pageSuspendedContext = new webkitAudioContext();
        window.__wapleHardPauseController.setPaused(true);
        """)
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        })
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "window.__runningContext.state") as? String == "suspended"
        })

        _ = pumpEvalJS(web, """
        window.__audioInitialState = 'running';
        window.__createdWhilePaused = new AudioContext();
        """)
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        })
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "window.__createdWhilePaused.state") as? String == "suspended"
        })

        _ = pumpEvalJS(web, "window.__createdWhilePaused.resume();")
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        })
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        })
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "window.__createdWhilePaused.state") as? String == "suspended"
        }, "resume() during hard pause must be followed immediately by suspend()")

        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(false);")
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        })
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "window.__runningContext.state") as? String == "running"
        })
        XCTAssertEqual(
            pumpEvalJS(web, "window.__pageSuspendedContext.state") as? String,
            "suspended"
        )
        XCTAssertEqual(
            pumpEvalJS(web, "window.__createdWhilePaused.state") as? String,
            "suspended"
        )
    }

    func testLateAudioPromisesCannotReverseLatestPauseState() throws {
        let web = makeControllerWebView(prelude: fakeAudioPrelude)
        _ = pumpEvalJS(web, """
        window.__context = new AudioContext();
        window.__wapleHardPauseController.setPaused(true);
        """)
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        })

        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(false);")
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        })
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "window.__context.state") as? String == "running"
        }, "late suspend must be followed by the latest resume")

        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(true);")
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        })
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "window.__context.state") as? String == "suspended"
        })
        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(false);")
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        })
        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(true);")
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        })
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "window.__context.state") as? String == "suspended"
        }, "late resume must be followed by the latest suspend")
    }

    func testWAAPIAndCSSAnimationsFreezeIncludingAnimationsAddedWhilePaused() throws {
        let web = makeControllerWebView(prelude: deterministicAnimationPrelude, html: """
        <html><head><style>
        @keyframes waplePulse { from { opacity: 0; } to { opacity: 1; } }
        #cssBox { animation: waplePulse 1s linear infinite; }
        </style></head><body><div id="box"></div><div id="cssBox"></div><script>
        window.__animation = document.getElementById('box').animate(
          [{ transform: 'translateX(0px)' }, { transform: 'translateX(100px)' }],
          { duration: 1000, iterations: Infinity }
        );
        void document.body.offsetWidth;
        window.__cssAnimation = document.getElementById('cssBox').getAnimations()[0];
        </script></body></html>
        """)
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__animation.currentTime") as? Double ?? 0) > 30 &&
                (pumpEvalJS(web, "window.__cssAnimation.currentTime") as? Double ?? 0) > 30
        })
        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(true);")
        let frozen = pumpEvalJS(web, "window.__animation.currentTime") as? Double ?? 0
        let frozenCSS = pumpEvalJS(web, "window.__cssAnimation.currentTime") as? Double ?? 0
        spin(0.20)
        XCTAssertEqual(
            pumpEvalJS(web, "window.__animation.currentTime") as? Double ?? -1,
            frozen,
            accuracy: 3
        )
        XCTAssertEqual(
            pumpEvalJS(web, "window.__cssAnimation.currentTime") as? Double ?? -1,
            frozenCSS,
            accuracy: 3
        )
        _ = pumpEvalJS(web, """
        var dynamic = document.createElement('div');
        document.body.appendChild(dynamic);
        window.__dynamicAnimation = dynamic.animate(
          [{ opacity: 0 }, { opacity: 1 }],
          { duration: 1000, iterations: Infinity }
        );
        """)
        spin(0.20)
        let dynamicFrozen = pumpEvalJS(web, "window.__dynamicAnimation.currentTime") as? Double ?? 0
        spin(0.15)
        XCTAssertEqual(
            pumpEvalJS(web, "window.__dynamicAnimation.currentTime") as? Double ?? -1,
            dynamicFrozen,
            accuracy: 3
        )
        XCTAssertEqual(
            pumpEvalJS(web, """
            document.documentElement.classList.contains('__waple-hard-paused')
            """) as? Bool,
            true
        )
        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(false);")
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__animation.currentTime") as? Double ?? 0) > frozen + 20 &&
                (pumpEvalJS(web, "window.__cssAnimation.currentTime") as? Double ?? 0) > frozenCSS + 20 &&
                (pumpEvalJS(web, "window.__dynamicAnimation.currentTime") as? Double ?? 0) > dynamicFrozen + 20
        })
    }

    func testControllerFailureDoesNotBlockCooperativeLifecycle() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_hard_pause_error_\(UUID().uuidString)",
                                  isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        <html><body><script>
        window.__hardCalls = 0;
        window.__background = 0;
        window.__pausedLog = [];
        window.wallpaperWillGoBackground = function () { window.__background += 1; };
        window.wallpaperPropertyListener = {
          setPaused: function (value) { window.__pausedLog.push(value); }
        };
        </script></body></html>
        """.write(to: dir.appendingPathComponent("index.html"),
                  atomically: true, encoding: .utf8)
        try #"{"type":"web","file":"index.html","title":"controller-error"}"#
            .write(to: dir.appendingPathComponent("project.json"),
                   atomically: true, encoding: .utf8)

        let renderer = WebRenderer(mode: .web)
        try renderer.mount(
            in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
            project: ProjectJSONParser.parse(folderURL: dir)
        )
        defer { renderer.teardown() }
        let web = try XCTUnwrap(renderer.webViewForTesting)
        XCTAssertTrue(waitUntil(timeout: 5) {
            pumpEvalJS(web, """
            !!window.__wapleHardPauseController &&
            Array.isArray(window.__pausedLog)
            """) as? Bool == true
        })
        _ = pumpEvalJS(web, """
        window.__wapleHardPauseController.setPaused = function () {
          window.__hardCalls += 1;
          throw new Error('expected controller failure');
        };
        """)
        renderer.pause()
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, """
            window.__hardCalls === 1 &&
            window.__background === 1 &&
            window.__pausedLog.length === 1 &&
            window.__pausedLog[0] === true
            """) as? Bool == true
        })
    }

    func testFramesCreatedWhilePausedInheritStateAndResumeOnce() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "waple_hard_pause_frames_\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let child = """
        <html><body><script>
        parent.postMessage({ wapleFrame: 'same', kind: 'ready' }, '*');
        setInterval(function () {
          parent.postMessage({ wapleFrame: 'same', kind: 'tick' }, '*');
        }, 100);
        </script></body></html>
        """
        let dataChild = """
        <html><body><script>
        parent.postMessage({ wapleFrame: 'data', kind: 'ready' }, '*');
        setInterval(function () {
          parent.postMessage({ wapleFrame: 'data', kind: 'tick' }, '*');
        }, 100);
        </script></body></html>
        """
        let dataURL = "data:text/html;charset=utf-8," +
            (dataChild.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        let dataURLLiteral = try XCTUnwrap(
            String(data: JSONEncoder().encode(dataURL), encoding: .utf8)
        )
        try child.write(
            to: dir.appendingPathComponent("child.html"),
            atomically: true,
            encoding: .utf8
        )
        try """
        <html><body><script>
        window.__frameEvents = {
          same: { ready: 0, tick: 0 },
          data: { ready: 0, tick: 0 }
        };
        window.addEventListener('message', function (event) {
          var body = event.data || {};
          if (!window.__frameEvents[body.wapleFrame]) { return; }
          window.__frameEvents[body.wapleFrame][body.kind] += 1;
        });
        window.__spawnPausedFrames = function () {
          var same = document.createElement('iframe');
          same.src = 'child.html';
          document.body.appendChild(same);
          var data = document.createElement('iframe');
          data.src = \(dataURLLiteral);
          document.body.appendChild(data);
        };
        </script></body></html>
        """.write(
            to: dir.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"type":"web","file":"index.html","title":"frames"}"#
            .write(
                to: dir.appendingPathComponent("project.json"),
                atomically: true,
                encoding: .utf8
            )

        let renderer = WebRenderer(mode: .web)
        try renderer.mount(
            in: NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 72)),
            project: ProjectJSONParser.parse(folderURL: dir)
        )
        defer { renderer.teardown() }
        let web = try XCTUnwrap(renderer.webViewForTesting)
        XCTAssertTrue(waitUntil(timeout: 5) {
            pumpEvalJS(web, "typeof window.__spawnPausedFrames === 'function'") as? Bool == true
        })

        renderer.pause()
        _ = pumpEvalJS(web, "window.__spawnPausedFrames();")
        XCTAssertTrue(waitUntil(timeout: 5) {
            let events = try? self.object(web, "window.__frameEvents")
            let same = events?["same"] as? [String: Any]
            let data = events?["data"] as? [String: Any]
            return same?["ready"] as? Int == 1 && data?["ready"] as? Int == 1
        })
        spin(0.30)
        var events = try object(web, "window.__frameEvents")
        XCTAssertEqual((events["same"] as? [String: Any])?["tick"] as? Int, 0)
        XCTAssertEqual((events["data"] as? [String: Any])?["tick"] as? Int, 0)

        renderer.resume()
        XCTAssertTrue(waitUntil(timeout: 2) {
            let current = try? self.object(web, "window.__frameEvents")
            return ((current?["same"] as? [String: Any])?["tick"] as? Int ?? 0) >= 1 &&
                ((current?["data"] as? [String: Any])?["tick"] as? Int ?? 0) >= 1
        })
        events = try object(web, "window.__frameEvents")
        XCTAssertLessThanOrEqual((events["same"] as? [String: Any])?["tick"] as? Int ?? 99, 5)
        XCTAssertLessThanOrEqual((events["data"] as? [String: Any])?["tick"] as? Int ?? 99, 5)
    }

    func testReloadReplaysEffectivePauseBeforePropertyDelivery() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "waple_hard_pause_reload_\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        <html><body><script>
        sessionStorage.loads = String(Number(sessionStorage.loads || '0') + 1);
        window.__ticks = 0;
        window.__pauseEvents = [];
        setInterval(function () { window.__ticks += 1; }, 50);
        window.wallpaperPropertyListener = {
          setPaused: function (value) { window.__pauseEvents.push(value); }
        };
        </script></body></html>
        """.write(
            to: dir.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"type":"web","file":"index.html","title":"reload"}"#
            .write(
                to: dir.appendingPathComponent("project.json"),
                atomically: true,
                encoding: .utf8
            )

        let renderer = WebRenderer(mode: .web)
        try renderer.mount(
            in: NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 72)),
            project: ProjectJSONParser.parse(folderURL: dir)
        )
        defer { renderer.teardown() }
        let web = try XCTUnwrap(renderer.webViewForTesting)
        XCTAssertTrue(waitUntil(timeout: 5) {
            (pumpEvalJS(web, "window.__ticks") as? Int ?? 0) >= 1
        })
        renderer.pause()
        _ = pumpEvalJS(web, "window.location.reload();")
        XCTAssertTrue(waitUntil(timeout: 5) {
            pumpEvalJS(web, """
            Number(sessionStorage.loads || '0') === 2 &&
            Array.isArray(window.__pauseEvents) &&
            window.__pauseEvents.length === 1 &&
            window.__pauseEvents[0] === true
            """) as? Bool == true
        })
        let frozen = pumpEvalJS(web, "window.__ticks") as? Int ?? -1
        spin(0.25)
        XCTAssertEqual(pumpEvalJS(web, "window.__ticks") as? Int, frozen)
        renderer.resume()
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__ticks") as? Int ?? 0) > frozen
        })
        XCTAssertEqual(pumpEvalJS(web, "window.__pauseEvents") as? [Bool], [true, false])
    }
}
