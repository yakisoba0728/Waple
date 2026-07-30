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
        // WebKit 유예 회피용 창 부착+가시 상태는 유지하되, 투명(alpha 0)으로 사용자 가시 출현은 제거.
        window.alphaValue = 0
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

    /// 재개 직후 "남은 지연이 아직 안 지났다" 는 negative 단언은 벽시계에 의존한다 — 러너 부하로 eval
    /// 왕복이 길어지면 일시정지 시점의 경과가 커지고(CI 실측 180~280ms), 남은 지연이 아래 스핀 창보다
    /// 짧아져 정상 동작이 조기 발화로 보인다(런 30541571683 에서 remaining 1 != 0 로 실패).
    /// 경과를 JS 로 실측해 창보다 확실히 여유가 있을 때만 단정한다. 일시정지 중 미발화(무조건)와
    /// 재개 후 정확히 1회 발화(무조건)는 그대로 잠근다.
    func testPausedCreationCrossClearAndRemainingDelay() throws {
        let keepDelayMS = 280.0
        let resumeSpin = 0.10
        let web = makeControllerWebView()
        _ = pumpEvalJS(web, """
        window.__fired = {
          timeout: 0, interval: 0, raf: 0, remaining: 0, stringHandler: 0
        };
        window.__meta = { t0: performance.now(), elapsedAtPause: -1 };
        var keep = setTimeout(function () { window.__fired.remaining += 1; }, \(Int(keepDelayMS)));
        """)
        spin(0.07)
        _ = pumpEvalJS(web, """
        window.__meta.elapsedAtPause = performance.now() - window.__meta.t0;
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
        let elapsedAtPause = try XCTUnwrap(object(web, "window.__meta")["elapsedAtPause"] as? Double)
        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(false);")
        spin(resumeSpin)
        let remainingMS = keepDelayMS - elapsedAtPause
        if remainingMS > resumeSpin * 1000 + 50 {
            XCTAssertEqual(try object(web, "window.__fired")["remaining"] as? Int, 0,
                           "남은 지연 \(remainingMS)ms > 스핀 \(resumeSpin * 1000)ms 이므로 아직 미발화여야")
        }
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

    func testOnlyRunningAudioContextsResumeAndPausedCreationResumesOnRelease() throws {
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
        // runningContext 와 (pause 중 생성·페이지가 resume 한) createdWhilePaused 둘 다 재개 대상.
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 2
        })
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "window.__runningContext.state") as? String == "running" &&
                pumpEvalJS(web, "window.__createdWhilePaused.state") as? String == "running"
        })
        XCTAssertEqual(
            pumpEvalJS(web, "window.__pageSuspendedContext.state") as? String,
            "suspended"
        )
    }

    func testAudioContextCreatedWhilePausedResumesOnRelease() throws {
        let web = makeControllerWebView(prelude: fakeAudioPrelude)
        _ = pumpEvalJS(web, """
        window.__audioInitialState = 'running';
        window.__wapleHardPauseController.setPaused(true);
        window.__createdWhilePaused = new AudioContext();
        """)
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        })
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "window.__createdWhilePaused.state") as? String == "suspended"
        }, "precondition: creation while paused must be suspended immediately")

        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(false);")
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        }, "release must enqueue a resume for the context created while paused")
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "window.__createdWhilePaused.state") as? String == "running"
        }, "context created while paused must not stay suspended forever")
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

    func testPendingPageSuspendSurvivesSameTurnHardPauseRoundTrip() throws {
        let web = makeControllerWebView(prelude: fakeAudioPrelude)
        _ = pumpEvalJS(web, """
        window.__context = new AudioContext();
        window.__pageSuspend = window.__context.suspend();
        window.__wapleHardPauseController.setPaused(true);
        window.__wapleHardPauseController.setPaused(false);
        """)

        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? 0) == 1
        }, "the page suspend must reach the native context")
        _ = pumpEvalJS(web, "window.__resolveAudio();")
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "window.__context.state") as? String == "suspended" &&
                (pumpEvalJS(web, "window.__audioPending.length") as? Int ?? -1) == 0
        })
        XCTAssertEqual(
            pumpEvalJS(web, "window.__context.operations") as? [String],
            ["suspend"],
            "Waple must neither supersede the page suspend nor claim a resume it did not own")
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

    func testExistingNodeAnimationStartedWhilePausedIsCapturedImmediately() throws {
        let web = makeControllerWebView(
            prelude: deterministicAnimationPrelude,
            html: "<html><body><div id='box'></div></body></html>")
        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(true);")

        let playState = pumpEvalJS(web, """
        window.__existingNodeAnimation = document.getElementById('box').animate(
          [{ opacity: 0 }, { opacity: 1 }],
          { duration: 1000, iterations: Infinity }
        );
        window.__existingNodeAnimation.playState;
        """) as? String
        XCTAssertEqual(playState, "paused")
        let frozen = pumpEvalJS(web, "window.__existingNodeAnimation.currentTime") as? Double ?? 0
        spin(0.15)
        XCTAssertEqual(
            pumpEvalJS(web, "window.__existingNodeAnimation.currentTime") as? Double ?? -1,
            frozen,
            accuracy: 3)

        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(false);")
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__existingNodeAnimation.currentTime") as? Double ?? 0) > frozen + 20
        })
    }

    func testKnownAnimationReplayedWhilePausedIsCapturedImmediately() throws {
        let web = makeControllerWebView(prelude: deterministicAnimationPrelude, html: """
        <html><body><div id="box"></div><script>
        window.__knownAnimation = document.getElementById('box').animate(
          [{ transform: 'translateX(0px)' }, { transform: 'translateX(100px)' }],
          { duration: 1000, iterations: Infinity }
        );
        window.__knownAnimation.pause();
        </script></body></html>
        """)
        XCTAssertEqual(
            pumpEvalJS(web, "window.__knownAnimation.playState") as? String,
            "paused")
        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(true);")

        XCTAssertEqual(
            pumpEvalJS(web, """
            window.__knownAnimation.play();
            window.__knownAnimation.playState;
            """) as? String,
            "paused")
        let frozen = pumpEvalJS(web, "window.__knownAnimation.currentTime") as? Double ?? 0
        spin(0.15)
        XCTAssertEqual(
            pumpEvalJS(web, "window.__knownAnimation.currentTime") as? Double ?? -1,
            frozen,
            accuracy: 3)

        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(false);")
        XCTAssertTrue(waitUntil {
            (pumpEvalJS(web, "window.__knownAnimation.currentTime") as? Double ?? 0) > frozen + 20
        })
    }

    func testMediaElementsPauseAndOnlyPlayingOnesResume() throws {
        // src 없는 <video>/<audio> 도 play() 가 paused 속성을 동기 false 로 전이시킨다(소스 선택 대기).
        // 실미디어 디코딩 없이 HTMLMediaElement 정지/재개 의미론을 검증하는 최소 재료.
        let web = makeControllerWebView(html: """
        <html><body>
        <video id="playing" muted></video>
        <video id="idle" muted></video>
        <audio id="playingAudio"></audio>
        </body></html>
        """)
        _ = pumpEvalJS(web, """
        window.__media = {
          playing: document.getElementById('playing'),
          idle: document.getElementById('idle'),
          audio: document.getElementById('playingAudio')
        };
        window.__media.playing.play().catch(function () {});
        window.__media.audio.play().catch(function () {});
        """)
        XCTAssertEqual(
            pumpEvalJS(web, """
            [window.__media.playing.paused, window.__media.idle.paused,
             window.__media.audio.paused].join(',')
            """) as? String,
            "false,true,false",
            "precondition: play() must transition paused synchronously even without a source"
        )

        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(true);")
        XCTAssertEqual(
            pumpEvalJS(web, """
            [window.__media.playing.paused, window.__media.idle.paused,
             window.__media.audio.paused].join(',')
            """) as? String,
            "true,true,true",
            "hard pause must pause playing media elements"
        )
        spin(0.15)
        XCTAssertEqual(
            pumpEvalJS(web, "window.__media.playing.paused") as? Bool, true,
            "media must stay paused for the whole hard pause"
        )

        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(false);")
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, """
            !window.__media.playing.paused && !window.__media.audio.paused
            """) as? Bool == true
        }, "resume must replay exactly the media Waple paused")
        XCTAssertEqual(
            pumpEvalJS(web, "window.__media.idle.paused") as? Bool, true,
            "media that was already paused by the page must stay paused after resume"
        )
    }

    func testMediaStartedWhilePausedIsCapturedAndResumed() throws {
        let web = makeControllerWebView(
            html: "<html><body><video id='box' muted></video></body></html>")
        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(true);")

        _ = pumpEvalJS(web, """
        window.__existing = document.getElementById('box');
        window.__existing.play().catch(function () {});
        window.__dynamic = document.createElement('video');
        window.__dynamic.muted = true;
        document.body.appendChild(window.__dynamic);
        window.__dynamic.play().catch(function () {});
        """)
        // 'play' 이벤트는 태스크 큐로 비동기 발화 — 캡처 후 강제 정지까지 waitUntil.
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, """
            window.__existing.paused && window.__dynamic.paused
            """) as? Bool == true
        }, "media started while hard-paused must be paused immediately")
        spin(0.15)
        XCTAssertEqual(
            pumpEvalJS(web, "window.__existing.paused && window.__dynamic.paused") as? Bool,
            true,
            "captured media must stay paused"
        )

        _ = pumpEvalJS(web, "window.__wapleHardPauseController.setPaused(false);")
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, """
            !window.__existing.paused && !window.__dynamic.paused
            """) as? Bool == true
        }, "media captured while paused must resume playback on release")
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
