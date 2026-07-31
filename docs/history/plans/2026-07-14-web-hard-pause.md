# Web Hard Pause Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a web wallpaper actually stop rAF, timers, WebAudio, CSS/WAAPI animation, native audio capture, and media polling while either manual pause or occlusion is active, then resume each owned activity exactly once after both causes clear.

**Architecture:** Inject one origin-independent `WebHardPauseJS` controller at document start in every frame before `WallpaperBridgeJS`. The controller virtualizes browser schedulers, owns only the audio/animation state that Waple changed, and exchanges a versioned pause state between parent and child frames; the existing bridge calls it before preserving the current cooperative callbacks. `WebRenderer` reduces manual and occlusion inputs to one effective Boolean and applies every JS/native transition through one synchronizer.

**Tech Stack:** Swift 5.9, macOS 14, WebKit/`WKWebView`, JavaScript injected with `WKUserScript`, XCTest, Swift Package Manager

## Global Constraints

- Inject `WebHardPauseJS.source` before `WallpaperBridgeJS.source` with `injectionTime: .atDocumentStart` and `forMainFrameOnly: false`.
- Install the hard-pause controller outside the bridge's `waple-asset:` origin gate so allowed `data:` frames receive it too; continue to reject remote subframes through the existing native navigation policy.
- Preserve the cooperative callback order after the new controller call: `wallpaperPropertyListener.setPaused`, background/foreground callback, then existing child-frame propagation. A controller exception must not suppress these callbacks.
- Treat `pausedManually || pausedByOcclusion` as the only effective native state. Manual resume while occluded must not resume JS, audio capture, or the media poller.
- Keep `performance.now`, `Date`, and all page clock sources untouched. A resumed callback may observe a timestamp jump.
- String timer handlers must use indirect global evaluation when they fire. Do not catch their page exception; CSP or evaluation failures remain visible as page errors.
- Resume only WebAudio contexts that were running before Waple suspended them. Resume animations that were running/pending at the pause edge or first appeared during hard pause; contexts the page had already suspended and contexts created while paused remain suspended on native resume. If `AudioContext` and `webkitAudioContext` initially reference the same constructor, both names must receive the same wrapper.
- HTML media-element auto-pause, service workers, network cancellation, page-clock virtualization, and cross-origin remote-frame support remain excluded.
- Run only `WebHardPauseTests`, `WallpaperBridgeJSTests`, `WebPropertyDeliveryTests`, and `WebRendererOcclusionTests`. Do not run unfiltered `swift test`, all `WapleRenderTests`, or any render corpus.
- Preserve the user's existing `.vscode/launch.json` and unrelated dirty specs. Every `git add` below names only this lane's files.
- This implementation lane includes its focused tests and commits but no code-review pass. Run one final review only after all lanes have integrated.

---

## File Map

- Create `Sources/WapleRender/WebHardPauseJS.swift` — one all-frame IIFE that owns scheduler virtualization, WebAudio/animation suspension, diagnostics, and versioned parent/child state exchange.
- Modify `Sources/WapleRender/WallpaperBridgeJS.swift:83-84,151-163` — retain cooperative dedupe and callbacks while invoking the hard controller first on each actual transition.
- Modify `Sources/WapleRender/WebRenderer.swift:23-25,50-53,161-184,204-215,375-455` — inject scripts in order and route navigation, listener registration, manual pause, and occlusion through one effective-state synchronizer.
- Modify `Sources/WapleRender/MediaPoller.swift:12-34` — expose an internal read-only running flag for deterministic focused state tests; production start/stop behavior stays unchanged.
- Create `Tests/WapleRenderTests/WebHardPauseTests.swift` — real `WKWebView` scheduler, fake-AudioContext race/ownership, WAAPI, dynamic-frame, `data:`-frame, and reload coverage.
- Modify `Tests/WapleRenderTests/WallpaperBridgeJSTests.swift:8-60` — pin the new source contract and controller-before-cooperative ordering.
- Modify `Tests/WapleRenderTests/WebRendererOcclusionTests.swift:9-59` — cover the combined manual/occlusion sequence and native consumer gating.
- Verify without editing `Tests/WapleRenderTests/WebPropertyDeliveryTests.swift:397-558` — retain lifecycle, dedupe, pre-load replay, and same-origin propagation behavior.

## Stable Interfaces

`WebHardPauseJS.source` installs this page-visible controller in every frame:

```text
window.__wapleHardPauseController.version: 1
window.__wapleHardPauseController.isPaused(): boolean
window.__wapleHardPauseController.setPaused(next: boolean): void
```

Only `version`, `isPaused() -> Bool`, and `setPaused(Bool) -> Void` are bridge/test contracts. Scheduler records, audio ownership, animation records, and frame messages remain private to the IIFE.

The Swift side adds these internal interfaces:

```swift
private var isEffectivelyPaused: Bool { pausedManually || pausedByOcclusion }
private func synchronizeEffectivePause(forceJavaScript: Bool = false)
var mediaPollingForTesting: Bool { mediaPoller?.isRunningForTesting ?? false }
```

The frame protocol is exact and versioned:

```javascript
{ channel: "waple-hard-pause", version: 1, type: "requestState" }
{ channel: "waple-hard-pause", version: 1, type: "state", paused: true }
```

### Task 1: Virtualize rAF and timers with preserved deadlines

**Files:**
- Create: `Sources/WapleRender/WebHardPauseJS.swift`
- Create: `Tests/WapleRenderTests/WebHardPauseTests.swift`

**Interfaces:**
- Consumes: native bound `requestAnimationFrame`, `cancelAnimationFrame`, `setTimeout`, `clearTimeout`, `setInterval`, `clearInterval`, and `performance.now`.
- Produces: `WebHardPauseJS.source` and `window.__wapleHardPauseController.version/isPaused/setPaused`; later tasks extend the same IIFE without changing these names.

- [ ] **Step 1: Write real-WKWebView scheduler tests first**

Create the shared harness and tests with these concrete shapes. The final test file can factor repeated fixture setup, but keep each timing assertion independent so one scheduler contract identifies its own failure.

```swift
import XCTest
import WebKit
@testable import WapleCore
@testable import WapleRender

final class WebHardPauseTests: XCTestCase {
    private var webViews: [WKWebView] = []
    private var windows: [NSWindow] = []

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

    private func makeControllerWebView(prelude: String? = nil,
                                       html: String = "<html><body>ready</body></html>") -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        if let prelude {
            controller.addUserScript(WKUserScript(
                source: prelude, injectionTime: .atDocumentStart, forMainFrameOnly: false
            ))
        }
        controller.addUserScript(WKUserScript(
            source: WebHardPauseJS.source, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        configuration.userContentController = controller
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 128, height: 72),
                            configuration: configuration)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 128, height: 72),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFront(nil)
        windows.append(window)
        webViews.append(web)
        web.loadHTMLString(html, baseURL: nil)
        XCTAssertTrue(waitUntil {
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
        let web = makeControllerWebView()
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
```

- [ ] **Step 2: Run one scheduler test and verify RED**

Run:

```bash
swift test --filter WebHardPauseTests/testSchedulersFreezeAndResumeExactlyOnce
```

Expected: compilation fails with `cannot find 'WebHardPauseJS' in scope`. This confirms the test is exercising the missing controller rather than the old cooperative bridge.

- [ ] **Step 3: Implement the scheduler controller**

Create `WebHardPauseJS.swift` as one raw Swift string. Preserve native functions as bound references, allocate numeric virtual IDs, use one record table, and implement intervals as chained native timeouts so the first post-resume firing can use `remaining` before returning to `period`.

```swift
enum WebHardPauseJS {
    static let source = #"""
    (function () {
      'use strict';
      if (window.__wapleHardPauseController) { return; }

      var nativeRAF = window.requestAnimationFrame.bind(window);
      var nativeCancelRAF = window.cancelAnimationFrame.bind(window);
      var nativeSetTimeout = window.setTimeout.bind(window);
      // Preserve the bound original; virtual intervals deliberately re-arm native timeouts.
      var nativeSetInterval = window.setInterval.bind(window);
      var nativeClearTimeout = window.clearTimeout.bind(window);
      var nativeClearInterval = window.clearInterval.bind(window);
      var monotonicNow = window.performance.now.bind(window.performance);
      var paused = false;
      var nextVirtualID = 1073741824;
      var records = Object.create(null);

      function report(error) {
        try { window.console.error('[Waple hard pause]', error); } catch (_) {}
      }

      function safely(action) {
        try { action(); } catch (error) { report(error); }
      }

      function allocateID() {
        nextVirtualID += 1;
        if (nextVirtualID >= 2147483647) { nextVirtualID = 1073741824; }
        while (records[nextVirtualID]) { nextVirtualID += 1; }
        return nextVirtualID;
      }

      function normalizedDelay(value) {
        var number = Number(value);
        if (!isFinite(number) || number < 0) { return 0; }
        return number;
      }

      function invokeTimer(record) {
        if (typeof record.handler === 'function') {
          record.handler.apply(window, record.arguments);
        } else {
          (0, eval)(String(record.handler));
        }
      }

      function armRAF(record) {
        if (paused || record.nativeHandle !== null) { return; }
        record.nativeHandle = nativeRAF(function (timestamp) {
          var current = records[record.id];
          if (!current) { return; }
          current.nativeHandle = null;
          delete records[current.id];
          current.callback(timestamp);
        });
      }

      function armTimer(record, delay) {
        if (paused || record.nativeHandle !== null) { return; }
        record.remaining = delay;
        record.deadline = monotonicNow() + delay;
        record.nativeHandle = nativeSetTimeout(function () {
          var current = records[record.id];
          if (!current || paused) { return; }
          current.nativeHandle = null;
          if (current.kind === 'timeout') {
            delete records[current.id];
          } else {
            armTimer(current, current.period);
          }
          invokeTimer(current);
        }, delay);
      }

      function clearTimerRecord(id) {
        var record = records[id];
        if (!record || (record.kind !== 'timeout' && record.kind !== 'interval')) {
          nativeClearTimeout(id);
          nativeClearInterval(id);
          return;
        }
        if (record.nativeHandle !== null) {
          nativeClearTimeout(record.nativeHandle);
          nativeClearInterval(record.nativeHandle);
        }
        delete records[id];
      }

      window.requestAnimationFrame = function (callback) {
        if (typeof callback !== 'function') {
          throw new TypeError('requestAnimationFrame callback must be a function');
        }
        var record = {
          id: allocateID(), kind: 'raf', callback: callback, nativeHandle: null
        };
        records[record.id] = record;
        armRAF(record);
        return record.id;
      };

      window.cancelAnimationFrame = function (id) {
        var record = records[id];
        if (!record || record.kind !== 'raf') {
          nativeCancelRAF(id);
          return;
        }
        if (record.nativeHandle !== null) { nativeCancelRAF(record.nativeHandle); }
        delete records[id];
      };

      window.setTimeout = function (handler, delay) {
        var record = {
          id: allocateID(),
          kind: 'timeout',
          handler: handler,
          arguments: Array.prototype.slice.call(arguments, 2),
          nativeHandle: null,
          deadline: 0,
          remaining: normalizedDelay(delay),
          period: 0
        };
        records[record.id] = record;
        armTimer(record, record.remaining);
        return record.id;
      };

      window.setInterval = function (handler, delay) {
        var period = normalizedDelay(delay);
        var record = {
          id: allocateID(),
          kind: 'interval',
          handler: handler,
          arguments: Array.prototype.slice.call(arguments, 2),
          nativeHandle: null,
          deadline: 0,
          remaining: period,
          period: period
        };
        records[record.id] = record;
        armTimer(record, period);
        return record.id;
      };

      window.clearTimeout = clearTimerRecord;
      window.clearInterval = clearTimerRecord;

      function pauseSchedulers() {
        var now = monotonicNow();
        Object.keys(records).forEach(function (id) {
          var record = records[id];
          if (record.nativeHandle === null) { return; }
          if (record.kind === 'raf') {
            nativeCancelRAF(record.nativeHandle);
          } else {
            record.remaining = Math.max(0, record.deadline - now);
            nativeClearTimeout(record.nativeHandle);
          }
          record.nativeHandle = null;
        });
      }

      function resumeSchedulers() {
        Object.keys(records).forEach(function (id) {
          var record = records[id];
          if (record.nativeHandle !== null) { return; }
          if (record.kind === 'raf') {
            armRAF(record);
          } else {
            armTimer(record, record.remaining);
          }
        });
      }

      var controller = {
        version: 1,
        isPaused: function () { return paused; },
        setPaused: function (next) {
          next = !!next;
          if (next === paused) { return; }
          paused = next;
          if (paused) {
            safely(pauseSchedulers);
          } else {
            safely(resumeSchedulers);
          }
        }
      };

      try {
        Object.defineProperty(window, '__wapleHardPauseController', {
          value: controller, writable: false, configurable: false
        });
      } catch (error) {
        window.__wapleHardPauseController = controller;
      }
    })();
    """#
}
```

Do not add a catch around `invokeTimer`: function-handler and indirect-eval exceptions must surface in the page. The controller catches only its own transition bookkeeping and reports it through `console.error`.

- [ ] **Step 4: Run all scheduler tests and verify GREEN**

Run:

```bash
swift test --filter WebHardPauseTests
```

Expected: the three scheduler tests pass; counts remain fixed during pause, `performance.now()` advances, cross-cleared paused IDs never fire, the timeout retains its remaining delay, and the interval's second post-resume gap returns to its original period.

- [ ] **Step 5: Commit the scheduler slice**

```bash
git add Sources/WapleRender/WebHardPauseJS.swift Tests/WapleRenderTests/WebHardPauseTests.swift
git commit -m "feat: hard pause web schedulers"
```

### Task 2: Suspend owned WebAudio and animations without stale async reversal

**Files:**
- Modify: `Sources/WapleRender/WebHardPauseJS.swift`
- Modify: `Tests/WapleRenderTests/WebHardPauseTests.swift`

**Interfaces:**
- Consumes: Task 1's private `paused` state, `report(error)`, `safely(action)`, and controller transition.
- Produces: wrapped `window.AudioContext`/`window.webkitAudioContext` constructors with native prototypes preserved; per-context `desiredState`, `generation`, serialized `chain`, and `resumeAfterPause` ownership; document-root `__waple-hard-paused` class and recorded WAAPI animations.

- [ ] **Step 1: Add fake-AudioContext race/ownership tests and a real-WAAPI test**

Add a controllable fake constructor as the first user script, before `WebHardPauseJS.source`. Manual resolvers make both stale-completion directions deterministic and avoid timers that are intentionally frozen.

```swift
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
    let web = makeControllerWebView(html: """
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
```

- [ ] **Step 2: Run the new tests and verify RED**

Run:

```bash
swift test --filter WebHardPauseTests/testOnlyRunningAudioContextsResumeAndPausedCreationStaysSuspended
swift test --filter WebHardPauseTests/testWAAPIAndCSSAnimationsFreezeIncludingAnimationsAddedWhilePaused
```

Expected: the audio test fails because no constructor is wrapped and no fake transition is pending; the animation test fails because `currentTime` continues advancing and the root pause class is absent.

- [ ] **Step 3: Add serialized AudioContext ownership**

Inside the same IIFE, add these private operations before the controller is created. Keep each context's transitions on one Promise chain, supersede queued work with `generation`, and clear Waple ownership only after an owned resume is still current and reaches `running`.

```javascript
var audioEntries = [];

function removeAudioEntry(entry) {
  var index = audioEntries.indexOf(entry);
  if (index >= 0) { audioEntries.splice(index, 1); }
}

function enqueueAudio(entry, desiredState, transition, onCurrentCompletion) {
  entry.desiredState = desiredState;
  var generation = ++entry.generation;
  entry.chain = entry.chain.catch(function (error) {
    report(error);
  }).then(function () {
    if (entry.context.state === 'closed') {
      removeAudioEntry(entry);
      return;
    }
    if (generation !== entry.generation) { return; }
    return Promise.resolve().then(transition).then(function () {
      if (entry.context.state === 'closed') {
        removeAudioEntry(entry);
        return;
      }
      if (generation === entry.generation && onCurrentCompletion) {
        onCurrentCompletion();
      }
    });
  }).catch(function (error) {
    report(error);
  });
  return entry.chain;
}

function requestAudioState(entry, desiredState, ownedResume) {
  return enqueueAudio(entry, desiredState, function () {
    if (entry.context.state === desiredState) { return; }
    return desiredState === 'running'
      ? entry.nativeResume()
      : entry.nativeSuspend();
  }, function () {
    if (ownedResume && !paused && entry.context.state === 'running') {
      entry.resumeAfterPause = false;
    }
  });
}

function trackAudioContext(context) {
  var entry = {
    context: context,
    nativeResume: context.resume.bind(context),
    nativeSuspend: context.suspend.bind(context),
    desiredState: context.state,
    generation: 0,
    chain: Promise.resolve(),
    resumeAfterPause: false
  };
  audioEntries.push(entry);

  try {
    Object.defineProperty(context, 'resume', {
      configurable: true,
      value: function () {
        return enqueueAudio(entry, paused ? 'suspended' : 'running', function () {
          return Promise.resolve(entry.nativeResume()).then(function () {
            if (paused) { return entry.nativeSuspend(); }
          });
        });
      }
    });
    Object.defineProperty(context, 'suspend', {
      configurable: true,
      value: function () {
        entry.resumeAfterPause = false;
        return enqueueAudio(entry, 'suspended', entry.nativeSuspend);
      }
    });
  } catch (error) {
    report(error);
  }

  if (paused) { requestAudioState(entry, 'suspended', false); }
  return context;
}

var audioConstructorWrappers = [];

function wrapperForAudioConstructor(Original, name) {
  for (var index = 0; index < audioConstructorWrappers.length; index += 1) {
    if (audioConstructorWrappers[index].original === Original) {
      return audioConstructorWrappers[index].wrapper;
    }
  }
  function WrappedAudioContext() {
    if (!new.target) { throw new TypeError(name + ' requires new'); }
    var args = Array.prototype.slice.call(arguments);
    var target = new.target === WrappedAudioContext ? Original : new.target;
    return trackAudioContext(Reflect.construct(Original, args, target));
  }
  Object.setPrototypeOf(WrappedAudioContext, Original);
  WrappedAudioContext.prototype = Original.prototype;
  audioConstructorWrappers.push({ original: Original, wrapper: WrappedAudioContext });
  return WrappedAudioContext;
}

function wrapAudioConstructor(name) {
  var Original = window[name];
  if (typeof Original !== 'function') { return; }
  var WrappedAudioContext = wrapperForAudioConstructor(Original, name);
  try {
    Object.defineProperty(window, name, {
      value: WrappedAudioContext, writable: true, configurable: true
    });
  } catch (error) {
    window[name] = WrappedAudioContext;
  }
}

function pauseAudioContexts() {
  audioEntries.slice().forEach(function (entry) {
    if (entry.context.state === 'closed') {
      removeAudioEntry(entry);
      return;
    }
    if (entry.context.state === 'running') {
      entry.resumeAfterPause = true;
      requestAudioState(entry, 'suspended', false);
    } else if (entry.desiredState === 'running') {
      requestAudioState(entry, 'suspended', false);
    }
  });
}

function resumeAudioContexts() {
  audioEntries.slice().forEach(function (entry) {
    if (entry.context.state === 'closed') {
      removeAudioEntry(entry);
    } else if (entry.resumeAfterPause) {
      requestAudioState(entry, 'running', true);
    }
  });
}

safely(function () { wrapAudioConstructor('AudioContext'); });
safely(function () { wrapAudioConstructor('webkitAudioContext'); });
```

If either constructor is absent, leave it absent. If its native Promise rejects, `enqueueAudio` logs the diagnostic and keeps its chain usable; it does not turn the rejection into a page lifecycle failure.

- [ ] **Step 4: Record only Waple-owned animations and add the pseudo-element fallback**

Add one persistent style and root class, snapshot running/pending animations before applying the class, and treat animations first observed during hard pause as Waple-owned unless already idle/finished. Use a microtask for mutation/event follow-up because wrapped page timers are intentionally stopped.

```javascript
var pauseClass = '__waple-hard-paused';
var animationStyleID = '__waple-hard-pause-style';
var knownAnimations = [];
var animationsToResume = [];
var animationObserver = null;

function allAnimations() {
  if (typeof document.getAnimations !== 'function') { return []; }
  return document.getAnimations();
}

function rememberAnimation(animation) {
  if (animationsToResume.indexOf(animation) < 0) {
    animationsToResume.push(animation);
  }
  try { animation.pause(); } catch (error) { report(error); }
}

function ensureAnimationStyle() {
  if (document.getElementById(animationStyleID)) { return; }
  var parent = document.head || document.documentElement;
  if (!parent) { return; }
  var style = document.createElement('style');
  style.id = animationStyleID;
  style.textContent =
    'html.' + pauseClass + ', html.' + pauseClass + ' *, ' +
    'html.' + pauseClass + '::before, html.' + pauseClass + '::after, ' +
    'html.' + pauseClass + ' *::before, html.' + pauseClass + ' *::after {' +
    'animation-play-state: paused !important;}';
  parent.appendChild(style);
}

function pauseAnimations() {
  ensureAnimationStyle();
  knownAnimations = allAnimations();
  knownAnimations.forEach(function (animation) {
    if (animation.playState === 'running' || animation.playState === 'pending') {
      rememberAnimation(animation);
    }
  });
  if (document.documentElement) {
    document.documentElement.classList.add(pauseClass);
  }
}

function captureAnimationsCreatedWhilePaused() {
  if (!paused) { return; }
  allAnimations().forEach(function (animation) {
    if (knownAnimations.indexOf(animation) >= 0) { return; }
    knownAnimations.push(animation);
    if (animation.playState !== 'idle' && animation.playState !== 'finished') {
      rememberAnimation(animation);
    }
  });
}

function queueAnimationCapture() {
  Promise.resolve().then(captureAnimationsCreatedWhilePaused);
}

function installAnimationObservation() {
  if (animationObserver || !document.documentElement || !window.MutationObserver) { return; }
  animationObserver = new MutationObserver(queueAnimationCapture);
  animationObserver.observe(document.documentElement, {
    childList: true, subtree: true, attributes: true
  });
}

function resumeAnimations() {
  if (document.documentElement) {
    document.documentElement.classList.remove(pauseClass);
  }
  var recorded = animationsToResume.slice();
  animationsToResume = [];
  knownAnimations = [];
  recorded.forEach(function (animation) {
    if (animation.playState !== 'idle' && animation.playState !== 'finished') {
      try { animation.play(); } catch (error) { report(error); }
    }
  });
}

document.addEventListener('animationstart', queueAnimationCapture, true);
document.addEventListener('transitionrun', queueAnimationCapture, true);
document.addEventListener('transitionstart', queueAnimationCapture, true);
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', function () {
    installAnimationObservation();
    if (paused) { pauseAnimations(); }
  });
} else {
  installAnimationObservation();
}
```

Update only the controller's transition body to invoke every subsystem independently:

```javascript
if (paused) {
  safely(pauseSchedulers);
  safely(pauseAudioContexts);
  safely(pauseAnimations);
} else {
  safely(resumeAnimations);
  safely(resumeAudioContexts);
  safely(resumeSchedulers);
}
```

- [ ] **Step 5: Run audio/animation tests and the scheduler regression, then commit**

Run:

```bash
swift test --filter WebHardPauseTests
```

Expected: all Task 1 and Task 2 tests pass. In particular, both rapid async orderings settle at the latest requested state, page-suspended and pause-created contexts do not resume, and both existing and dynamically added WAAPI `currentTime` values stay fixed while paused.

Commit:

```bash
git add Sources/WapleRender/WebHardPauseJS.swift Tests/WapleRenderTests/WebHardPauseTests.swift
git commit -m "feat: suspend web audio and animations"
```

### Task 3: Integrate the bridge and one Swift effective-pause transition

**Files:**
- Modify: `Sources/WapleRender/WallpaperBridgeJS.swift:83-84,151-163`
- Modify: `Sources/WapleRender/WebRenderer.swift:23-25,50-53,161-184,204-215,375-455`
- Modify: `Sources/WapleRender/MediaPoller.swift:12-34`
- Modify: `Tests/WapleRenderTests/WebHardPauseTests.swift`
- Modify: `Tests/WapleRenderTests/WallpaperBridgeJSTests.swift:8-60`
- Modify: `Tests/WapleRenderTests/WebRendererOcclusionTests.swift:9-59`

**Interfaces:**
- Consumes: `WebHardPauseJS.source` and its exact controller interface; existing `AudioSpectrumProviding.start/stop` and `MediaPoller.start/stop` are idempotent.
- Produces: `isEffectivelyPaused`, `synchronizeEffectivePause(forceJavaScript:)`, `MediaPoller.isRunningForTesting`, and `WebRenderer.mediaPollingForTesting`.

- [ ] **Step 1: Add bridge-order and combined-state tests**

Pin the source-level call order without coupling the test to the full controller implementation:

```swift
func testBridgeCallsHardPauseBeforeCooperativeLifecycle() throws {
    let source = WallpaperBridgeJS.source
    let hard = try XCTUnwrap(
        source.range(of: "window.__wapleHardPauseController.setPaused(paused)")
    )
    let listener = try XCTUnwrap(
        source.range(of: "if (listener && listener.setPaused)")
    )
    let lifecycle = try XCTUnwrap(
        source.range(of: "var lifecycle = paused ?")
    )
    XCTAssertLessThan(
        source.distance(from: source.startIndex, to: hard.lowerBound),
        source.distance(from: source.startIndex, to: listener.lowerBound)
    )
    XCTAssertLessThan(
        source.distance(from: source.startIndex, to: listener.lowerBound),
        source.distance(from: source.startIndex, to: lifecycle.lowerBound)
    )
}

func testHardPauseSourceDeclaresStableControllerContract() {
    let source = WebHardPauseJS.source
    for token in [
        "__wapleHardPauseController",
        "version: 1",
        "isPaused: function",
        "setPaused: function",
        "AudioContext",
        "webkitAudioContext",
        "document.getAnimations"
    ] {
        XCTAssertTrue(source.contains(token), "missing hard-pause contract: \(token)")
    }
}
```

In `WebHardPauseTests`, also prove that the bridge invokes the controller and still reaches the cooperative callbacks when that invocation throws:

```swift
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
```

Add one deterministic native-consumer test to `WebRendererOcclusionTests`. The fake audio provider must make `start()`/`stop()` idempotent, matching the production provider, so duplicate registration synchronization does not inflate counts.

```swift
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
```

- [ ] **Step 2: Run the combined-state test and verify RED**

Run:

```bash
swift test --filter WebRendererOcclusionTests/testManualResumeWaitsForOcclusionBeforeRestartingAllConsumers
swift test --filter WebHardPauseTests/testControllerFailureDoesNotBlockCooperativeLifecycle
```

Expected: the first command initially fails to compile because `mediaPollingForTesting` does not exist. After adding only that probe but before changing state flow, it fails because current `resume()` sends `setPaused(false)` and restarts audio while `pausedByOcclusion` is still true. The controller-error test fails with `__hardCalls === 0` until the bridge invokes the new hook.

- [ ] **Step 3: Invoke the hard controller first while preserving cooperative callbacks**

Add one local bridge helper and call it immediately after transition dedupe. Its own catch is required even though controller subsystems diagnose themselves: a page can replace/mutate the exposed method, and cooperative lifecycle must still run.

```javascript
function setHardPaused(paused) {
  try {
    if (window.__wapleHardPauseController &&
        typeof window.__wapleHardPauseController.setPaused === 'function') {
      window.__wapleHardPauseController.setPaused(paused);
    }
  } catch (error) {
    try { window.console.error('[Waple hard pause bridge]', error); } catch (_) {}
  }
}

defineBridge('__wapleSetPaused', function (paused) {
  paused = !!paused;
  if (lastPaused === paused) { return; }
  lastPaused = paused;
  setHardPaused(paused);
  if (listener && listener.setPaused) {
    try { listener.setPaused(paused); } catch (e) {}
  }
  var lifecycle = paused ? window.wallpaperWillGoBackground : window.wallpaperWillGoForeground;
  if (typeof lifecycle === 'function') {
    try { lifecycle(); } catch (e) {}
  }
  propagatePaused(paused);
});
```

- [ ] **Step 4: Inject in order and centralize Swift transitions**

Add the hard controller before the bridge:

```swift
let ucc = WKUserContentController()
ucc.addUserScript(WKUserScript(source: WebHardPauseJS.source,
                               injectionTime: .atDocumentStart,
                               forMainFrameOnly: false))
ucc.addUserScript(WKUserScript(source: WallpaperBridgeJS.source,
                               injectionTime: .atDocumentStart,
                               forMainFrameOnly: false))
ucc.add(self, name: "waple")
```

Add the state fields and one synchronizer. Initial `effectivePauseApplied = false` is deliberate: an initially active page must not receive a synthetic foreground lifecycle event merely because it finished loading.

```swift
private var pausedManually = false
private(set) var pausedByOcclusion = false
private var effectivePauseApplied = false
private var isEffectivelyPaused: Bool { pausedManually || pausedByOcclusion }

private func setPausedJS(_ paused: Bool) {
    webView?.evaluateJavaScript("""
        if (window.__wapleSetPaused) {
          window.__wapleSetPaused(\(paused));
        } else {
          if (window.__wapleHardPauseController) {
            window.__wapleHardPauseController.setPaused(\(paused));
          }
          if (window.wallpaperPropertyListener &&
              window.wallpaperPropertyListener.setPaused) {
            window.wallpaperPropertyListener.setPaused(\(paused));
          }
        }
        """) { _, error in
            if let error {
                NSLog("%@", "[Waple] pause injection failed: \(error)")
            }
        }
}

private func synchronizeEffectivePause(forceJavaScript: Bool = false) {
    let effective = isEffectivelyPaused
    let changed = effectivePauseApplied != effective
    effectivePauseApplied = effective
    if changed || forceJavaScript {
        setPausedJS(effective)
    }

    if effective || !hasAudioListener {
        audioProvider?.stop()
    } else {
        audioProvider?.start()
    }
    if effective {
        mediaPoller?.stop()
    } else {
        mediaPoller?.start()
    }
}
```

Call it from every branch:

```swift
public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard Self.isAllowedTopFrameURL(webView.url) else { return }
    synchronizeEffectivePause(forceJavaScript: isEffectivelyPaused)
    guard let json = userPropertiesJSON else { return }
    let js = "window.__wapleApplyProps(\(json), { fps: 30 });"
    webView.evaluateJavaScript(js) { _, error in
        if let error { NSLog("%@", "[Waple] property injection failed: \(error)") }
    }
    deliverFetchAllDirectories()
}

if type == "audioListen" {
    hasAudioListener = true
    synchronizeEffectivePause()
} else if type == "audioUnlisten" {
    hasAudioListener = false
    synchronizeEffectivePause()
} else if type == "mediaListen" {
    startMediaPolling()
    synchronizeEffectivePause()
}

public func pause() {
    guard !pausedManually else { return }
    pausedManually = true
    synchronizeEffectivePause()
}

public func resume() {
    guard pausedManually else { return }
    pausedManually = false
    synchronizeEffectivePause()
}

func occlusionChanged(visible: Bool) {
    let occluded = !visible
    guard pausedByOcclusion != occluded else { return }
    pausedByOcclusion = occluded
    synchronizeEffectivePause()
}
```

Remove the direct start from `startMediaPolling()`; it now creates/configures the poller and assigns `mediaPoller = poller`, while the caller immediately invokes the synchronizer. This prevents registration while either pause source is active from starting a poll.

Expose only the internal read probes:

```swift
// MediaPoller.swift
var isRunningForTesting: Bool { timer != nil }

// WebRenderer.swift, beside webViewForTesting
var mediaPollingForTesting: Bool {
    mediaPoller?.isRunningForTesting ?? false
}
```

Reset `effectivePauseApplied`, `pausedManually`, and `pausedByOcclusion` to `false` in `teardown()` after stopping native consumers, so a deliberately reused renderer cannot inherit a previous mount's effective edge.

Putting the forced paused replay before `guard let json` is mandatory. Passing `forceJavaScript: isEffectivelyPaused` replays true into a new paused document while preserving the current no-initial-foreground lifecycle behavior for an active document.

- [ ] **Step 5: Run focused Swift/bridge tests and commit**

Run:

```bash
swift test --filter WebRendererOcclusionTests
swift test --filter WallpaperBridgeJSTests
swift test --filter WebHardPauseTests/testControllerFailureDoesNotBlockCooperativeLifecycle
swift test --filter WebPropertyDeliveryTests/testRepeatedPauseResumeOnlyDispatchesLifecycleOnStateChanges
swift test --filter WebPropertyDeliveryTests/testPauseBeforeLoadIsReplayedAfterDocumentReady
```

Expected: all selected tests pass. The sequence manual pause → occluded → manual resume → visible emits exactly `[true, false]` at the effective edges and does not restart native consumers before the visible edge. Existing lifecycle callbacks still dedupe.

Commit:

```bash
git add Sources/WapleRender/WebHardPauseJS.swift Sources/WapleRender/WallpaperBridgeJS.swift Sources/WapleRender/WebRenderer.swift Sources/WapleRender/MediaPoller.swift Tests/WapleRenderTests/WebHardPauseTests.swift Tests/WapleRenderTests/WallpaperBridgeJSTests.swift Tests/WapleRenderTests/WebRendererOcclusionTests.swift
git commit -m "feat: unify web pause transitions"
```

### Task 4: Inherit pause across dynamic frames and navigation, then run the focused matrix

**Files:**
- Modify: `Sources/WapleRender/WebHardPauseJS.swift`
- Modify: `Tests/WapleRenderTests/WebHardPauseTests.swift`
- Verify without editing: `Tests/WapleRenderTests/WebPropertyDeliveryTests.swift`

**Interfaces:**
- Consumes: Task 3's all-frame injection, native subframe allowlist, and forced paused navigation replay.
- Produces: version-1 `requestState`/`state` messaging accepted only from a direct parent/direct child, recursive child broadcast, dynamic same-origin and allowed `data:` inheritance.

- [ ] **Step 1: Add dynamic same-origin/data-frame and paused-reload tests**

Use child-to-parent test messages for `data:` because its opaque origin prevents direct state inspection. A synchronous `ready` proves the document loaded; a 100 ms interval proves whether the injected controller paused it after the versioned request/response exchange.

```swift
func testFramesCreatedWhilePausedInheritStateAndResumeOnce() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("waple_hard_pause_frames_\(UUID().uuidString)",
                              isDirectory: true)
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
    try child.write(to: dir.appendingPathComponent("child.html"),
                    atomically: true, encoding: .utf8)
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
    """.write(to: dir.appendingPathComponent("index.html"),
              atomically: true, encoding: .utf8)
    try #"{"type":"web","file":"index.html","title":"frames"}"#
        .write(to: dir.appendingPathComponent("project.json"),
               atomically: true, encoding: .utf8)

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
        .appendingPathComponent("waple_hard_pause_reload_\(UUID().uuidString)",
                              isDirectory: true)
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
    """.write(to: dir.appendingPathComponent("index.html"),
              atomically: true, encoding: .utf8)
    try #"{"type":"web","file":"index.html","title":"reload"}"#
        .write(to: dir.appendingPathComponent("project.json"),
               atomically: true, encoding: .utf8)

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
```

If the helpers from Task 1 are scoped on `WebHardPauseTests`, use them directly as above. The mounted-renderer tests must append their `WKWebView` to `webViews` or rely on `renderer.teardown()`, but never leave a live view after the test.

- [ ] **Step 2: Run the dynamic-frame test and verify RED**

Run:

```bash
swift test --filter WebHardPauseTests/testFramesCreatedWhilePausedInheritStateAndResumeOnce
```

Expected: FAIL because at least one child `tick` count becomes nonzero during parent pause. Task 3 injected the controller into the child but did not yet tell a newly created frame the current parent state.

- [ ] **Step 3: Add versioned, source-checked frame state exchange**

Add these private helpers after the controller object exists but before the IIFE returns. `postMessage("*")` is required for opaque `data:` origins; source-window checks, direct-child checks, channel, and version provide the trust boundary.

```javascript
var frameChannel = 'waple-hard-pause';
var frameVersion = 1;

function frameMessage(type) {
  return {
    channel: frameChannel,
    version: frameVersion,
    type: type,
    paused: paused
  };
}

function isDirectChild(source) {
  for (var index = 0; index < window.frames.length; index += 1) {
    try {
      if (window.frames[index] === source) { return true; }
    } catch (_) {}
  }
  return false;
}

function postStateToChildren() {
  for (var index = 0; index < window.frames.length; index += 1) {
    try {
      window.frames[index].postMessage(frameMessage('state'), '*');
    } catch (error) {
      report(error);
    }
  }
}

window.addEventListener('message', function (event) {
  var message = event.data;
  if (!message ||
      message.channel !== frameChannel ||
      message.version !== frameVersion) {
    return;
  }
  if (message.type === 'requestState' && isDirectChild(event.source)) {
    try {
      event.source.postMessage(frameMessage('state'), '*');
    } catch (error) {
      report(error);
    }
    return;
  }
  if (message.type === 'state' &&
      window.parent !== window &&
      event.source === window.parent) {
    controller.setPaused(!!message.paused);
  }
}, false);

if (window.parent !== window) {
  try {
    window.parent.postMessage({
      channel: frameChannel,
      version: frameVersion,
      type: 'requestState'
    }, '*');
  } catch (error) {
    report(error);
  }
}

window.addEventListener('load', postStateToChildren, true);
```

Add `safely(postStateToChildren);` at the end of both the pause and resume sides of `controller.setPaused`. Each child dedupes through its own `setPaused`, so direct same-origin bridge propagation and versioned hard-state propagation cannot double-arm records or double-resume owned resources.

- [ ] **Step 4: Run the new integration tests and all allowed focused regressions**

Run exactly:

```bash
swift test --filter WebHardPauseTests
swift test --filter WallpaperBridgeJSTests
swift test --filter WebPropertyDeliveryTests
swift test --filter WebRendererOcclusionTests
```

Expected: all four commands pass with zero failures. Do not broaden this to `swift test` or a render test target. The checks jointly cover scheduler phase/IDs, AudioContext ownership and stale Promises, WAAPI, dynamic same-origin/`data:` frames, reload replay, cooperative lifecycle/dedupe, and the manual/occlusion/native-consumer state machine.

- [ ] **Step 5: Commit the frame/navigation slice and stop at the lane boundary**

```bash
git add Sources/WapleRender/WebHardPauseJS.swift Tests/WapleRenderTests/WebHardPauseTests.swift
git commit -m "feat: inherit web pause across frames"
```

Record the four focused test results for the integration owner. Do not start a code-review subagent in this lane; wait until all implementation lanes are integrated, then run the single final review required by the integration workflow.
