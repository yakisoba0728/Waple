# SceneScript Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver one deterministic `applyUserProperties → init → update` lifecycle per SceneScript engine on every mount, without breaking lazy property initialization, shared JavaScriptCore state, or chain-safe compatibility shims.

**Architecture:** `TextScriptEngine` will own dedicated, gated lifecycle functions that are deliberately absent from the generic event-hook dictionary; update-bearing engines retain lazy `init(currentValue)`, while init-only engines gain a no-argument entrypoint. `SceneRenderer` will cache one effective-property JSON snapshot per mount and feed it through the single `makeScriptEngine` factory before either init or update can run, while remount begins with teardown so stale engines and event collections cannot survive.

**Tech Stack:** Swift 5.9, macOS 14, SwiftPM, XCTest, JavaScriptCore, AppKit/MetalKit, WapleCore `WallpaperProperties`, WapleRender `SceneRenderer`.

## Global Constraints

- Preserve the lifecycle order exactly: top-level evaluation → `applyUserProperties(effectiveProps)` → `init` → `update`.
- An update-bearing property script still calls `init(currentValue)` immediately before its first `update(currentValue)` and never again; a shared-context init-only SceneScript calls `init()` with zero arguments immediately after load.
- `applyUserProperties` fires at most once per engine per mount. Set both lifecycle gates before invoking JavaScript so a throwing function is logged but never retried automatically.
- Remove `init` and `applyUserProperties` from generic `hookFns`; `callHook("init", ...)` and `callHook("applyUserProperties", ...)` must be no-ops and cannot bypass either gate.
- A missing lifecycle function is a no-op. Capture and log each engine's exception, restore the shared JavaScriptCore exception handler, and continue creating/calling other engines in the same context.
- Compute project defaults + preset overrides + user overrides once per mount. Serialize that effective `[WallpaperProperty]` once with `WallpaperProperties.weUserPropertiesJSON`; pass `{}` when the list is empty.
- Every successful `makeScriptEngine` call receives the same cached snapshot, including engines created late by `buildAnimationEventTargets` for `animationlayers`.
- Property editing remains remount-based; do not add an in-place property-change stream.
- A direct second `SceneRenderer.mount` must tear down the previous mount before parsing/building the next one, so stale event engines, views, hover targets, media pollers, and shared contexts are not reused.
- Add exactly these concrete engine methods: `isWallpaper() == true`, `isDesktopDevice() == true`, `isMobileDevice() == false`, `isScreensaver() == false`, `isRunningInEditor() == false`, `isPortrait() == height > width`, and `isLandscape() == width >= height`.
- Keep unknown engine members backed by the existing chain-safe Proxy. JavaScript objects remain truthy; do not add a fake `valueOf=false` or otherwise try to make the generic Proxy falsy.
- Preserve existing `shared` communication, defensive Vec2/Vec3 init copies, all `update` return-value behavior, and generic cursor/media/animation hooks.
- Do not synchronize arbitrary script mutations of `thisScene`/`thisLayer` back into native GPU objects in this wave.
- Do not edit `Sources/WapleCore/WallpaperProperties.swift`; its existing typed, sorted serializer is the implementation dependency. Validate its behavior through focused lifecycle tests and the existing `WallpaperPropertiesTests`.
- Do not edit `SceneRenderer3D.swift`, `SceneRendererResources.swift`, or `SceneRendererFrameEncoder.swift`; their engine creation/evaluation already flows through `SceneRenderer.makeScriptEngine` and `TextScriptEngine.evaluate*`.
- Do not edit, stage, revert, or otherwise disturb `.vscode/launch.json` or any unrelated pre-existing worktree changes.
- Do not perform additional native/corpus research. Do not run the full Swift test suite, render corpus, real-package ground truth, or snapshot lanes.
- Do not perform task-by-task or lane reviews. This lane ends after focused verification; the Wave integration plan performs the single review after all four lanes are merged.

---

## File Map

| File | Responsibility in this change |
| --- | --- |
| `Sources/WapleRender/TextScriptEngine.swift:131-245,294-310,679-809` | Store/gate dedicated lifecycle functions, exclude them from generic hooks, expose explicit apply/init entrypoints, preserve lazy update init, and add the seven concrete boolean engine capabilities. |
| `Sources/WapleRender/SceneRenderer.swift:51-74,112-128,246-325,542-544,601-641,1088-1118` | Cache one effective-property JSON snapshot, deliver it centrally to every engine (including late animation-layer engines), invoke init-only engines, and make direct remount begin with teardown/reset. |
| `Tests/WapleRenderTests/SceneEventHookTests.swift:248-268` | Replace the old generic-lifecycle expectation with deterministic ordering, exactly-once gates, and generic bypass protection while retaining real event-hook coverage. |
| `Tests/WapleRenderTests/SceneSharedScriptTests.swift:10-159,242+` | Cover init-only shared state, throwing lifecycle isolation/no retry, effective property delivery, late-engine snapshot stability, empty `{}`, and stale-engine cleanup across direct remount. |
| `Tests/WapleRenderTests/TextEngineTests.swift:175-193` | Lock the exact seven capability booleans for landscape/portrait/square canvases and preserve generic Proxy truthiness. |
| `Sources/WapleCore/WallpaperProperties.swift:142-167` | **Reuse unchanged:** `applying(overrides:to:)` produces effective properties and `weUserPropertiesJSON(_:)` preserves typed `false`, `0`, `""`, and `{}`. |
| `Sources/WapleRender/SceneRenderer3D.swift`, `Sources/WapleRender/SceneRendererResources.swift`, `Sources/WapleRender/SceneRendererFrameEncoder.swift` | **Reuse unchanged:** all script construction already calls `makeScriptEngine`; per-frame evaluation already calls the lazy `evaluate*` entrypoints. |

### Task 1: Dedicated, gated lifecycle entrypoints

**Files:**
- Modify: `Tests/WapleRenderTests/SceneEventHookTests.swift:248-268`
- Modify: `Tests/WapleRenderTests/SceneSharedScriptTests.swift:79-99`
- Modify: `Sources/WapleRender/TextScriptEngine.swift:131-245,294-310`

**Interfaces:**
- Consumes: `TextScriptEngine.withExceptionCapture(_:_:); TextScriptEngine.evaluate(current:); evaluateBool(current:); evaluateVec(current:)` and the existing shared-context IIFE export mechanism.
- Produces: `public func applyUserProperties(_ propertiesJSON: String)`, `public func callInitIfNeeded()`, private shared `didCallInit`/`didApplyUserProperties` gates, and `hookNames` containing only generic cursor/media/animation hooks.
- Invariant for Task 3: after construction, a renderer may call `applyUserProperties(snapshot)` on every engine and `callInitIfNeeded()` only when `hasUpdate == false`; update-bearing engines continue to initialize lazily with their current value.

- [ ] **Step 1: Replace the generic lifecycle-hook test with an ordering and bypass regression**

Replace `testWallpaperEngineLifecycleAndAnimationHooksCaptured()` in `Tests/WapleRenderTests/SceneEventHookTests.swift` with:

```swift
    func testLifecycleEntrypointsAreGatedAndExcludedFromGenericHooks() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: """
        var trace = ['top'];
        export function applyUserProperties(props) {
            trace.push('apply:' + props.enabled.value + ':' + props.amount.value + ':' + props.label.value);
        }
        export function init(value) { trace.push('init:' + value); }
        export function update(value) {
            trace.push('update:' + value);
            return trace.join('|');
        }
        export function cursorEnter(event) { trace.push('enter'); }
        export function animationEvent(event) { trace.push('animation:' + event.name + ':' + event.frame); }
        """))

        XCTAssertEqual(e.hookNames, Set(["cursorEnter", "animationEvent"]))
        XCTAssertFalse(e.hookNames.contains("init"))
        XCTAssertFalse(e.hookNames.contains("applyUserProperties"))

        e.applyUserProperties(#"{"enabled":{"value":false},"amount":{"value":0},"label":{"value":""}}"#)
        XCTAssertEqual(
            e.evaluate(current: "first"),
            "top|apply:false:0:|init:first|update:first"
        )

        e.applyUserProperties(#"{"enabled":{"value":true},"amount":{"value":99},"label":{"value":"again"}}"#)
        e.callHook("applyUserProperties", eventJS: #"({"enabled":{"value":true}})"#)
        e.callHook("init", eventJS: "'generic-bypass'")
        e.callHook("cursorEnter", eventJS: "({ worldPosition: new Vec3(1, 2, 0) })")
        e.callHook("animationEvent", eventJS: "new AnimationEvent({ name: 'intro', frame: 2 })")

        XCTAssertEqual(
            e.evaluate(current: "second"),
            "top|apply:false:0:|init:first|update:first|enter|animation:intro:2|update:second"
        )
    }
```

- [ ] **Step 2: Add init-only and throwing-lifecycle shared-context regressions**

Insert these methods in `SceneSharedScriptTests`, immediately after `testInitRunsOnceBeforeFirstUpdateInSharedContext()`:

```swift
    func testInitOnlyEngineRunsOnceWithoutArgumentsAndPublishesSharedState() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let initOnly = try XCTUnwrap(TextScriptEngine(script: """
        export function applyUserProperties(props) { shared.theme = props.theme.value; }
        export function init() {
            shared.initCount = (shared.initCount || 0) + 1;
            shared.initArgumentCount = arguments.length;
        }
        """, scene: scene))

        XCTAssertFalse(initOnly.hasUpdate)
        initOnly.applyUserProperties(#"{"theme":{"type":"text","value":"dark"}}"#)
        initOnly.callInitIfNeeded()
        initOnly.callInitIfNeeded()
        initOnly.callHook("init", eventJS: "'generic-bypass'")
        initOnly.callHook("applyUserProperties", eventJS: #"({"theme":{"value":"light"}})"#)

        let probe = try XCTUnwrap(TextScriptEngine(script: """
        export function update(value) {
            return shared.theme + '/' + shared.initCount + '/' + shared.initArgumentCount;
        }
        """, scene: scene))
        XCTAssertEqual(probe.evaluate(current: ""), "dark/1/0")
    }

    func testThrowingLifecycleFunctionsAreNotRetriedOrCrossContaminateSharedContext() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let throwing = try XCTUnwrap(TextScriptEngine(script: """
        shared.applyAttempts = 0;
        shared.initAttempts = 0;
        export function applyUserProperties(props) {
            shared.applyAttempts += 1;
            throw new Error('apply boom');
        }
        export function init() {
            shared.initAttempts += 1;
            throw new Error('init boom');
        }
        """, scene: scene))

        throwing.applyUserProperties(#"{"mode":{"value":"first"}}"#)
        throwing.applyUserProperties(#"{"mode":{"value":"second"}}"#)
        throwing.callInitIfNeeded()
        throwing.callInitIfNeeded()
        throwing.callHook("applyUserProperties", eventJS: #"({"mode":{"value":"generic"}})"#)
        throwing.callHook("init", eventJS: "({})")

        let lazy = try XCTUnwrap(TextScriptEngine(script: """
        shared.lazyInitAttempts = 0;
        export function init(value) {
            shared.lazyInitAttempts += 1;
            throw new Error('lazy init boom');
        }
        export function update(value) {
            return shared.lazyInitAttempts + '/' + value;
        }
        """, scene: scene))
        XCTAssertNil(lazy.evaluate(current: "first"))
        XCTAssertEqual(lazy.evaluate(current: "second"), "1/second")

        let healthy = try XCTUnwrap(TextScriptEngine(script: """
        export function update(value) {
            return shared.applyAttempts + '/' + shared.initAttempts + '/healthy';
        }
        """, scene: scene))
        XCTAssertEqual(healthy.evaluate(current: ""), "1/1/healthy")
    }
```

- [ ] **Step 3: Run the new lifecycle tests and confirm RED**

Run:

```bash
swift test --filter SceneEventHookTests/testLifecycleEntrypointsAreGatedAndExcludedFromGenericHooks
swift test --filter SceneSharedScriptTests/testInitOnlyEngineRunsOnceWithoutArgumentsAndPublishesSharedState
swift test --filter SceneSharedScriptTests/testThrowingLifecycleFunctionsAreNotRetriedOrCrossContaminateSharedContext
```

Expected before production changes: test-target compilation fails with `value of type 'TextScriptEngine' has no member 'applyUserProperties'` and no zero-argument `callInitIfNeeded`; the old implementation also exposes both lifecycle names through `hookNames`.

- [ ] **Step 4: Commit the RED lifecycle tests**

```bash
git add Tests/WapleRenderTests/SceneEventHookTests.swift Tests/WapleRenderTests/SceneSharedScriptTests.swift
git diff --cached --check
git commit -m "테스트(scene): lifecycle 순서와 once gate 고정"
```

Expected: the commit contains only the two focused WapleRender test files; `.vscode/launch.json` remains unstaged and untouched.

- [ ] **Step 5: Separate lifecycle storage from generic event hooks in both initializers**

In `TextScriptEngine`, replace the lifecycle/event stored-property block and hook-name list with:

```swift
    private let context: JSContext
    private let updateFn: JSValue?
    private let initFn: JSValue?
    private let applyUserPropertiesFn: JSValue?
    private var didCallInit = false
    private var didApplyUserProperties = false
    /// Generic event hooks only. Lifecycle functions have dedicated storage and gates.
    private var hookFns: [String: JSValue] = [:]

    private static let lifecycleFunctionNames = ["init", "applyUserProperties"]
    static let eventHookNames = ["cursorClick", "cursorDown", "cursorUp", "cursorMove",
                                 "cursorEnter", "cursorLeave", "animationEvent",
                                 "mediaPlaybackChanged", "mediaPropertiesChanged", "mediaThumbnailChanged",
                                 "mediaTimelineChanged", "mediaStatusChanged"]
```

In the standalone initializer, keep the existing requirement that `update` exist, then replace lifecycle/event extraction with:

```swift
        updateFn = fn
        let i = ctx.objectForKeyedSubscript("init")
        initFn = (i?.isObject == true) ? i : nil
        let apply = ctx.objectForKeyedSubscript("applyUserProperties")
        applyUserPropertiesFn = (apply?.isObject == true) ? apply : nil
        for name in Self.eventHookNames {
            if let f = ctx.objectForKeyedSubscript(name), f.isObject { hookFns[name] = f }
        }
```

In the shared-context initializer, export lifecycle names explicitly without putting them in `eventHookNames`:

```swift
        let exports = (["update"] + Self.lifecycleFunctionNames + Self.eventHookNames)
            .map { "\($0): (typeof \($0) !== 'undefined') ? \($0) : null" }
            .joined(separator: ", ")
```

Replace the shared result extraction with:

```swift
        if let out, out.isObject {
            let u = out.objectForKeyedSubscript("update")
            updateFn = (u?.isObject == true) ? u : nil
            let i = out.objectForKeyedSubscript("init")
            initFn = (i?.isObject == true) ? i : nil
            let apply = out.objectForKeyedSubscript("applyUserProperties")
            applyUserPropertiesFn = (apply?.isObject == true) ? apply : nil
            for name in Self.eventHookNames {
                if let f = out.objectForKeyedSubscript(name), f.isObject { hookFns[name] = f }
            }
        } else {
            updateFn = nil
            initFn = nil
            applyUserPropertiesFn = nil
        }
```

This keeps update-less shared SceneScripts loadable while ensuring `hookNames` cannot report either lifecycle function.

- [ ] **Step 6: Add the two dedicated gated entrypoints and share the existing init gate**

Insert the public methods after `callHook(_:eventJS:)`, then replace the existing private `callInitIfNeeded(argument:)` implementation with the shared gate helper below:

```swift
    /// Deliver the mount's effective WallpaperProperty JSON once. The gate is set before JSON evaluation/call,
    /// so malformed JSON or a throwing script is logged and never retried automatically.
    public func applyUserProperties(_ propertiesJSON: String) {
        guard !didApplyUserProperties else { return }
        didApplyUserProperties = true
        guard let applyUserPropertiesFn else { return }
        _ = withExceptionCapture("applyUserProperties hook exception") { failed -> JSValue? in
            guard let properties = context.evaluateScript("(\(propertiesJSON))"), !failed() else { return nil }
            let result = applyUserPropertiesFn.call(withArguments: [properties])
            return failed() ? nil : result
        }
    }

    /// Initialize an init-only SceneScript once with zero arguments.
    public func callInitIfNeeded() {
        guard let initFn = takeInitFunctionIfNeeded() else { return }
        _ = withExceptionCapture("init hook exception") { failed -> JSValue? in
            let result = initFn.call(withArguments: [])
            return failed() ? nil : result
        }
    }

    private func takeInitFunctionIfNeeded() -> JSValue? {
        guard !didCallInit else { return nil }
        didCallInit = true
        return initFn
    }

    private func callInitIfNeeded(argument: Any) {
        guard let initFn = takeInitFunctionIfNeeded() else { return }
        initFn.call(withArguments: [initArgument(from: argument)])
    }
```

Do not add a second exception wrapper around the argument-bearing private method: all three `evaluate*` callers already run it inside their update-specific `withExceptionCapture`, so a thrown init makes that first update return `nil`, restores the shared handler, and remains gated on later updates.

- [ ] **Step 7: Run the focused lifecycle regressions and existing lazy-init gates**

Run:

```bash
swift test --filter SceneEventHookTests/testLifecycleEntrypointsAreGatedAndExcludedFromGenericHooks
swift test --filter SceneSharedScriptTests/testInitOnlyEngineRunsOnceWithoutArgumentsAndPublishesSharedState
swift test --filter SceneSharedScriptTests/testThrowingLifecycleFunctionsAreNotRetriedOrCrossContaminateSharedContext
swift test --filter SceneSharedScriptTests/testInitRunsOnceBeforeFirstUpdateInSharedContext
swift test --filter ConstantScriptTests/testInitReceivesCopiedVecAndRunsOnceBeforeFirstStandaloneUpdate
```

Expected after implementation: every command reports `0 failures`; the two existing init tests retain copied-vector values and exactly-once lazy behavior.

- [ ] **Step 8: Commit the lifecycle engine implementation**

```bash
git add Sources/WapleRender/TextScriptEngine.swift
git diff --cached --check
git commit -m "기능(scene): lifecycle 전용 once entrypoint 추가"
```

Expected: only `TextScriptEngine.swift` is committed.

### Task 2: Concrete boolean engine capabilities without falsifying the Proxy

**Files:**
- Modify: `Tests/WapleRenderTests/TextEngineTests.swift:175-193`
- Modify: `Sources/WapleRender/TextScriptEngine.swift:725-809`

**Interfaces:**
- Consumes: shared `__canvasSize`, updated in place by `__setCanvasSize(w,h)`, and the existing `engine` Proxy fallback to `__noopProxy()`.
- Produces: seven concrete zero-argument JavaScript functions on `__engineState`; no Swift API changes.
- Preserves: any unknown `engine.*` chain still returns an object/function Proxy and therefore remains truthy under JavaScript `ToBoolean`.

- [ ] **Step 1: Add exact landscape, portrait, square, and unknown-Proxy assertions**

Insert this method in `TextEngineTests`, immediately after `testCanvasSizeReflectsInjectedProjectionSize()`:

```swift
    func testEngineBooleanCapabilitiesAreConcreteAndUnknownProxyRemainsTruthy() throws {
        let script = """
        export function update(value) {
            return [
                engine.isWallpaper(),
                engine.isDesktopDevice(),
                engine.isMobileDevice(),
                engine.isScreensaver(),
                engine.isRunningInEditor(),
                engine.isPortrait(),
                engine.isLandscape(),
                engine.unknownCapability().stillChains
            ].map(function(v) { return v ? '1' : '0'; }).join('');
        }
        """

        func flags(width: Float, height: Float) throws -> String {
            let scene = try XCTUnwrap(SceneScriptContext(width: width, height: height))
            let engine = try XCTUnwrap(TextScriptEngine(script: script, scene: scene))
            return try XCTUnwrap(engine.evaluate(current: ""))
        }

        XCTAssertEqual(try flags(width: 1920, height: 1080), "11000011")
        XCTAssertEqual(try flags(width: 600, height: 800), "11000101")
        XCTAssertEqual(try flags(width: 900, height: 900), "11000011")
    }
```

Bit order is wallpaper, desktop, mobile, screensaver, editor, portrait, landscape, unknown Proxy. The final `1` explicitly proves that only known boolean capabilities become concrete; the generic Proxy remains truthy.

- [ ] **Step 2: Run the capability test and confirm RED**

Run:

```bash
swift test --filter TextEngineTests/testEngineBooleanCapabilitiesAreConcreteAndUnknownProxyRemainsTruthy
```

Expected before the shim change: FAIL because all seven names fall through to truthy no-op Proxies, producing `11111111` instead of the three expected strings.

- [ ] **Step 3: Commit the RED capability test**

```bash
git add Tests/WapleRenderTests/TextEngineTests.swift
git diff --cached --check
git commit -m "테스트(scene): engine boolean capability 계약 고정"
```

Expected: only `TextEngineTests.swift` is committed.

- [ ] **Step 4: Add exactly seven concrete functions to `__engineState`**

In the `TextScriptEngine.shims` JavaScript string, add these members immediately after `canvasSize: __canvasSize,` and before `setTimeout`:

```javascript
                          isWallpaper: function() { return true; },
                          isDesktopDevice: function() { return true; },
                          isMobileDevice: function() { return false; },
                          isScreensaver: function() { return false; },
                          isRunningInEditor: function() { return false; },
                          isPortrait: function() { return __canvasSize.y > __canvasSize.x; },
                          isLandscape: function() { return __canvasSize.x >= __canvasSize.y; },
```

Leave `__noopProxy()` and the `engine` Proxy get trap byte-for-byte unchanged:

```javascript
    var engine = new Proxy(__engineState, {
        get: function(t, k) { if (k in t) { return t[k]; } return __noopProxy(); },
        set: function(t, k, v) { t[k] = v; return true; }
    });
```

- [ ] **Step 5: Run the capability test and adjacent shim regression**

Run:

```bash
swift test --filter TextEngineTests/testEngineBooleanCapabilitiesAreConcreteAndUnknownProxyRemainsTruthy
swift test --filter TextEngineTests/testEngineAPIShimsDoNotCrash
swift test --filter TextEngineTests/testCanvasSizeReflectsInjectedProjectionSize
```

Expected after implementation: all three commands report `0 failures`; portrait uses strict `height > width`, and a square reports landscape.

- [ ] **Step 6: Commit the capability implementation**

```bash
git add Sources/WapleRender/TextScriptEngine.swift
git diff --cached --check
git commit -m "기능(scene): engine boolean capability 구체화"
```

Expected: only `TextScriptEngine.swift` is committed; there is no `valueOf` or Proxy coercion change.

### Task 3: Mount snapshot delivery, init-only dispatch, and remount cleanup

**Files:**
- Modify: `Tests/WapleRenderTests/SceneSharedScriptTests.swift:242+`
- Modify: `Sources/WapleRender/SceneRenderer.swift:51-74,542-544,601-641,1088-1118`

**Interfaces:**
- Consumes: Task 1's `TextScriptEngine.applyUserProperties(_:)`, `callInitIfNeeded()`, and `hasUpdate`; `WallpaperProperties.parse(folderURL:)`, `applying(overrides:to:)`, `weUserPropertiesJSON(_:)`; `UserPropertyStore.overrides(id:presetOverrides:presetResourceRoot:)`.
- Produces: internal `var sceneUserPropertiesJSON = "{}"`, deterministic `makeScriptEngine` lifecycle delivery, and a `mount` precondition enforced by calling `teardown()` first.
- Central factory guarantee: `build3D`, `attachScripts`, `buildLayers`, translated-effect constants, `buildTexts`, and late `animLayerEngines` continue using `makeScriptEngine`, so no companion renderer file needs lifecycle code.

- [ ] **Step 1: Add focused synthetic mount/remount tests with typed property fixtures**

Append this exact test class to `Tests/WapleRenderTests/SceneSharedScriptTests.swift`:

```swift
final class SceneScriptMountLifecycleTests: XCTestCase {
    private var propertyStoreIDs: [String] = []

    override func tearDown() {
        for id in propertyStoreIDs { UserPropertyStore.reset(id: id) }
        super.tearDown()
    }

    private func makeProject(
        id: String,
        marker: String,
        properties: [String: Any],
        presetOverrides: [String: PropertyValue] = [:]
    ) throws -> WallpaperProject {
        UserPropertyStore.reset(id: id)
        propertyStoreIDs.append(id)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waple-scene-lifecycle-\(id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let script = """
        function propertyValue(props, key) {
            return Object.prototype.hasOwnProperty.call(props, key)
                ? String(props[key].value) : 'missing';
        }
        shared.order = ['top:\(marker)'];
        export function applyUserProperties(props) {
            shared.payload = [
                propertyValue(props, 'enabled'),
                propertyValue(props, 'amount'),
                propertyValue(props, 'label'),
                propertyValue(props, 'mode'),
                propertyValue(props, 'baseOnly')
            ].join('|');
            shared.order.push('apply:' + Object.keys(props).length);
        }
        export function init() {
            shared.order.push('init:' + arguments.length + ':' + shared.payload);
        }
        export function cursorClick(event) {
            shared.clicks = (shared.clicks || 0) + 1;
        }
        """
        let sceneObject: [String: Any] = [
            "general": [
                "orthogonalprojection": ["width": 320, "height": 180],
                "clearcolor": "0 0 0"
            ],
            "objects": [[
                "name": "lifecycle-\(marker)",
                "text": ["value": "", "script": script],
                "font": "systemfont_arial",
                "pointsize": 16,
                "origin": "10 10 0",
                "scale": "1 1",
                "visible": ["value": true]
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: sceneObject, options: [.sortedKeys])
        try encodePkg([("scene.json", sceneData)]).write(to: dir.appendingPathComponent("scene.pkg"))

        let projectObject: [String: Any] = [
            "type": "scene",
            "file": "scene.pkg",
            "general": ["properties": properties]
        ]
        let projectData = try JSONSerialization.data(withJSONObject: projectObject, options: [.sortedKeys])
        try projectData.write(to: dir.appendingPathComponent("project.json"))

        return WallpaperProject(
            id: id,
            type: .scene,
            fileName: "scene.pkg",
            previewName: nil,
            title: id,
            tags: [],
            contentRating: nil,
            workshopId: nil,
            dependency: nil,
            folderURL: dir,
            presetOverrides: presetOverrides
        )
    }

    private func state(in scene: SceneScriptContext) throws -> String {
        let probe = try XCTUnwrap(TextScriptEngine(script: """
        export function update(value) {
            return shared.order.join(',') + '/' + String(shared.payload) + '/' + String(shared.clicks || 0);
        }
        """, scene: scene))
        return try XCTUnwrap(probe.evaluate(current: ""))
    }

    func testMountDeliversOneEffectiveSnapshotToInitialAndLateEngines() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let id = "scene-lifecycle-effective-\(UUID().uuidString)"
        let project = try makeProject(
            id: id,
            marker: "first",
            properties: [
                "enabled": ["type": "bool", "value": true],
                "amount": ["type": "slider", "value": 9.0],
                "label": ["type": "text", "value": "default"],
                "mode": ["type": "text", "value": "default"],
                "baseOnly": ["type": "text", "value": "base"]
            ],
            presetOverrides: [
                "enabled": .bool(false),
                "amount": .number(5),
                "mode": .string("preset")
            ]
        )
        UserPropertyStore.set(.number(0), key: "amount", id: id)
        UserPropertyStore.set(.string(""), key: "label", id: id)
        UserPropertyStore.set(.string("user"), key: "mode", id: id)

        let renderer = SceneRenderer()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        try renderer.mount(in: container, project: project)
        defer { renderer.teardown() }

        let mountedScene = try XCTUnwrap(renderer.sceneScript)
        XCTAssertEqual(
            try state(in: mountedScene),
            "top:first,apply:5,init:0:false|0||user|base/false|0||user|base/0"
        )

        // Mutating persistence after mount must not change the cached snapshot delivered to later engines.
        UserPropertyStore.set(.bool(true), key: "enabled", id: id)
        UserPropertyStore.set(.number(8), key: "amount", id: id)
        UserPropertyStore.set(.string("changed"), key: "label", id: id)
        UserPropertyStore.set(.string("changed"), key: "mode", id: id)

        let late = try XCTUnwrap(renderer.makeScriptEngine("""
        var trace = ['top'];
        var delivered = '';
        export function applyUserProperties(props) {
            delivered = [props.enabled.value, props.amount.value, props.label.value,
                         props.mode.value, props.baseOnly.value].join('|');
            trace.push('apply');
        }
        export function init(value) { trace.push('init:' + value); }
        export function update(value) {
            trace.push('update:' + value);
            return trace.join(',') + '/' + delivered;
        }
        """))
        XCTAssertEqual(late.evaluate(current: "A"), "top,apply,init:A,update:A/false|0||user|base")
        XCTAssertEqual(late.evaluate(current: "B"), "top,apply,init:A,update:A,update:B/false|0||user|base")
    }

    func testDirectRemountUsesEmptyObjectAndDoesNotDispatchToStaleEngine() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let oldProject = try makeProject(
            id: "scene-lifecycle-old-\(UUID().uuidString)",
            marker: "old",
            properties: ["mode": ["type": "text", "value": "old"]]
        )
        let newProject = try makeProject(
            id: "scene-lifecycle-new-\(UUID().uuidString)",
            marker: "new",
            properties: [:]
        )
        let renderer = SceneRenderer()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        try renderer.mount(in: container, project: oldProject)
        defer { renderer.teardown() }

        let oldScene = try XCTUnwrap(renderer.sceneScript)
        let stale = try XCTUnwrap(renderer.eventEngines.first)
        XCTAssertEqual(renderer.eventEngines.count, 1)

        // No explicit teardown: mount itself owns remount cleanup.
        try renderer.mount(in: container, project: newProject)
        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertEqual(renderer.eventEngines.count, 1)
        XCTAssertFalse(renderer.eventEngines.contains { $0 === stale })

        renderer.simulateCursorClick(x: 1, y: 1)
        let newScene = try XCTUnwrap(renderer.sceneScript)
        XCTAssertEqual(
            try state(in: newScene),
            "top:new,apply:0,init:0:missing|missing|missing|missing|missing/missing|missing|missing|missing|missing/1"
        )
        XCTAssertEqual(
            try state(in: oldScene),
            "top:old,apply:1,init:0:missing|missing|missing|old|missing/missing|missing|missing|old|missing/0"
        )
    }
}
```

The first test proves default < preset < user priority, exact preservation of `false`, `0`, and `""`, apply-before-init, lazy init-before-update, and snapshot reuse after persistence changes. The second proves `{}` delivery (`Object.keys == 0`), automatic remount teardown, fresh engine identity, and no stale event dispatch.

- [ ] **Step 2: Run the mount tests and confirm RED**

Run:

```bash
swift test --filter SceneScriptMountLifecycleTests/testMountDeliversOneEffectiveSnapshotToInitialAndLateEngines
swift test --filter SceneScriptMountLifecycleTests/testDirectRemountUsesEmptyObjectAndDoesNotDispatchToStaleEngine
```

Expected before renderer changes: the first test fails because `makeScriptEngine` does not deliver properties or initialize update-less engines; the second fails because a direct remount retains old `eventEngines`/views and dispatches to stale engines.

- [ ] **Step 3: Commit the RED renderer lifecycle tests**

```bash
git add Tests/WapleRenderTests/SceneSharedScriptTests.swift
git diff --cached --check
git commit -m "테스트(scene): mount property lifecycle와 remount 격리 고정"
```

Expected: only `SceneSharedScriptTests.swift` is committed.

- [ ] **Step 4: Cache and deliver the effective property snapshot centrally**

Add the cached JSON beside `variantProperties` in `SceneRenderer`:

```swift
    /// SceneScript applyUserProperties payload. Computed once per mount and reused by every engine.
    var sceneUserPropertiesJSON = "{}"
```

Replace `makeScriptEngine(_:,layerName:)` with this lifecycle-aware factory body while retaining its current audio scan and hover registration behavior:

```swift
    func makeScriptEngine(_ src: String, layerName: String? = nil) -> TextScriptEngine? {
        if !hasAudio, Self.scriptWantsAudio(src) { hasAudio = true }
        let engine = sceneScript.map { TextScriptEngine(script: src, scene: $0, currentLayerName: layerName) }
            ?? TextScriptEngine(script: src)
        guard let engine else { return nil }

        // Constructor evaluation is complete here. Every engine gets apply exactly once; only init-only
        // engines initialize now. Update-bearing engines retain init(currentValue) in evaluate*.
        engine.applyUserProperties(sceneUserPropertiesJSON)
        if !engine.hasUpdate { engine.callInitIfNeeded() }

        if !engine.hookNames.isEmpty {
            eventEngines.append(engine)
            if let layerName,
               !engine.hookNames.isDisjoint(with: ["cursorEnter", "cursorLeave"]) {
                hoverEngineLayers.append((engine, layerName))
            }
        }
        return engine
    }
```

In `mount`, replace the current first lines with an enforced teardown precondition:

```swift
    public func mount(in container: NSView, project: WallpaperProject) throws {
        teardown()
        scenePausedAt = nil
        shouldAnimate = false
        videoTextureMP4URL = nil
```

Then replace the effective-property calculation at current lines 634-641 with one shared list:

```swift
        let baseProps = (try? WallpaperProperties.parse(folderURL: project.folderURL)) ?? []
        let overrides = UserPropertyStore.overrides(
            id: project.id,
            presetOverrides: project.presetOverrides,
            presetResourceRoot: project.presetFolderURL
        )
        let effectiveProperties = WallpaperProperties.applying(overrides: overrides, to: baseProps)
        variantProperties = Dictionary(
            effectiveProperties.map { ($0.key, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        sceneUserPropertiesJSON = WallpaperProperties.weUserPropertiesJSON(effectiveProperties)
```

This code must remain before the video-texture early return and before `SceneScriptContext`/any script engine is created.

- [ ] **Step 5: Reset both snapshots during teardown**

Expand the existing scene-script reset line in `teardown()` to:

```swift
        textLayers = []; hasScriptedText = false; hasAnimations = false
        sceneScript = nil; sceneUserPropertiesJSON = "{}"; variantProperties = [:]
        scriptVisible.removeAll()
```

Do not add lifecycle calls to `SceneRenderer3D.swift`, `SceneRendererResources.swift`, or `SceneRendererFrameEncoder.swift`. Their current call graph reaches the updated factory, including `animLayerEngines(_:)` at mount end.

- [ ] **Step 6: Run the renderer tests and focused cross-layer regressions**

Run:

```bash
swift test --filter SceneScriptMountLifecycleTests/testMountDeliversOneEffectiveSnapshotToInitialAndLateEngines
swift test --filter SceneScriptMountLifecycleTests/testDirectRemountUsesEmptyObjectAndDoesNotDispatchToStaleEngine
swift test --filter SceneEventHookTests/testLifecycleEntrypointsAreGatedAndExcludedFromGenericHooks
swift test --filter SceneSharedScriptTests/testSharedStateFlowsBetweenEngines
swift test --filter SceneSharedScriptTests/testInitRunsOnceBeforeFirstUpdateInSharedContext
swift test --filter UserPropertyStoreTests/testPresetOverridesMergeBeforeUserOverrides
swift test --filter WallpaperPropertiesTests/testWEUserPropertiesJSONNumberAndEmpty
```

Expected after implementation: every command reports `0 failures`; the new mount tests observe the cached effective values and fresh remount engine only, while existing shared/update and property-priority behavior remains green.

- [ ] **Step 7: Commit the renderer lifecycle implementation**

```bash
git add Sources/WapleRender/SceneRenderer.swift
git diff --cached --check
git commit -m "기능(scene): mount lifecycle snapshot 전달"
```

Expected: only `SceneRenderer.swift` is committed.

## Lane Verification and Handoff

This section verifies the lane but does not review it. The only code review occurs after all four Wave 1 lanes are integrated.

- [ ] **Step 1: Run every affected focused class, without the full suite or corpus**

Run these as separate commands:

```bash
swift test --filter TextEngineTests
swift test --filter ConstantScriptTests
swift test --filter SceneEventHookTests
swift test --filter SceneSharedScriptTests
swift test --filter SceneScriptMountLifecycleTests
swift test --filter UserPropertyStoreTests
swift test --filter WallpaperPropertiesTests
```

Expected: each command finishes with `0 failures`; Metal-dependent synthetic mount tests may report an XCTest skip only when `MTLCreateSystemDefaultDevice()` is unavailable.

- [ ] **Step 2: Validate the six-commit implementation range and protected files**

Run:

```bash
git diff --check HEAD~6..HEAD
git diff --name-only HEAD~6..HEAD
git log --oneline -6
git status --short
```

Expected implementation file list, and no others:

```text
Sources/WapleRender/SceneRenderer.swift
Sources/WapleRender/TextScriptEngine.swift
Tests/WapleRenderTests/SceneEventHookTests.swift
Tests/WapleRenderTests/SceneSharedScriptTests.swift
Tests/WapleRenderTests/TextEngineTests.swift
```

Expected log: three RED test commits alternating with their three production commits. `git status --short` may still show unrelated changes that predated execution, including `.vscode/launch.json`; none may be staged, reverted, or changed by these six commits.

- [ ] **Step 3: Record the lane evidence**

The implementation handoff must name the five changed files, the seven focused class commands and their outcomes, the branch HEAD, and the clean lane status. Do not start a reviewer and do not claim a full-suite, corpus, ground-truth, or native-engine verification run.
