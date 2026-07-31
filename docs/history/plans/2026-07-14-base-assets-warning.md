# Base-Assets Missing Warning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 실제 필수 공유 에셋 해석이 끝까지 실패해 Scene이 저하된 경우에만, 현재 base-assets 설정별로 앱 세션당 한 번 설정 경로를 안내하는 비차단 StatusBanner를 표시한다.

**Architecture:** `SceneRenderer`가 mount마다 하나의 공개 read-only boolean 진단을 소유하고, 최종 required-loader 실패와 `SceneDocument.parse`의 모델/머티리얼 전체 해석 실패만 그 진단을 세운다. 성공한 renderer swap만 `BaseAssetsWarningGate`에 새 Scene 진단을 전달하며, gate는 설정 fingerprint와 실제 배너 표시 성공 여부를 기준으로 중복을 제어한다. 기존 `notify`는 NSLog를 항상 남기되 보이는 메인창에 배너를 올렸을 때만 `true`를 반환한다.

**Tech Stack:** Swift 5.9, SwiftPM, XCTest, macOS 14, AppKit, SwiftUI, WapleCore, WapleRender

## Global Constraints

- Work only in `.worktrees/base-assets-warning` on branch `codex/base-assets-warning`; never modify, stage, or commit the user's `.vscode/launch.json`.
- Do not warn merely because `BaseAssetsSettings.baseAssetsDirectory == nil`; a missing or deleted configured directory must be diagnosed through a real required lookup miss.
- Package data, shared-base data, or a later raw/package candidate that succeeds must leave `hasMissingRequiredSharedAssets == false`.
- Low-level `assetData`, individual candidate probes, `quietAssetData`, rejected traversal, and invalid relative paths must not set the public diagnostic.
- Keep individual missing filenames in the existing NSLog/WapleLog output only; the public renderer diagnostic is one boolean.
- Show exactly `공유 기본 에셋을 찾지 못해 일부 씬 요소가 표시되지 않습니다 — 설정 > 에셋·도구에서 폴더를 지정하세요.` only after a successful renderer swap.
- Allow one presented banner per base-assets setting fingerprint per app session; an NSLog-only notification while the main window is hidden must not consume the allowance, and only a different selected base-assets folder resets it.
- Aggregate multi-monitor and multi-file misses into one banner. A self-contained Scene, web/video renderer, or failed mount must not show this warning.
- Do not vendor a base-assets bundle, enlarge built-in shader headers, add a blocking alert, auto-open Settings, or add first-run onboarding.
- Preserve the existing `StatusBannerModelTests` behavior and run only the named focused tests below; do not run unfiltered `swift test` or any render corpus.
- This lane includes red/green tests and commits but no lane-level code review. The single final review happens only after all Wave 1 lanes are integrated.
- Commit messages must contain no AI watermark.

---

## File Map

- Modify `Sources/WapleRender/SceneRenderer.swift`: own/reset the mount-scoped diagnostic and bridge the Core parse callback.
- Modify `Sources/WapleRender/SceneRendererResources.swift`: add a final-candidate required loader and use it only at required texture/model consumption sites.
- Modify `Sources/WapleRender/SceneRenderer3D.swift`: route required 3D model and billboard texture loads through the diagnostic-aware loader.
- Modify `Tests/WapleRenderTests/SceneRendererPathFallbackTests.swift`: cover package/base success, later-candidate success, real/repeated miss, quiet miss, and traversal rejection.
- Modify `Sources/WapleCore/SceneDocument.swift`: report missing required model/material bytes only after package plus injected shared resolver both fail.
- Modify `Tests/WapleCoreTests/SceneDocumentTests.swift`: cover self-contained success, shared resolver success, actual miss, and invalid-path rejection.
- Modify `Sources/WapleRender/BaseAssetsSettings.swift`: expose a stable fingerprint of the selected setting without changing automatic discovery.
- Create `Sources/Waple/BaseAssetsWarningGate.swift`: isolate successful-swap aggregation, fingerprint dedupe, and presentation-consumption policy.
- Create `Tests/WapleAppTests/BaseAssetsWarningGateTests.swift`: cover self-contained/non-Scene/failed swaps, multi-monitor aggregation, same-setting suppression, changed-setting reset, and hidden-window retry.
- Modify `Sources/Waple/AppDelegate.swift`: invoke the gate only in the successful swap branch and make `notify` report whether it presented a banner.
- Preserve `Sources/Waple/Shell/StatusBanner.swift` and `Tests/WapleAppTests/StatusBannerModelTests.swift` unchanged.
- Modify `BACKLOG.md`: mark P3/P4 3D lighting complete and record the remaining onboarding/hidden-window base-assets productization work.

---

### Task 1: Mount-Scoped Renderer Required-Asset Diagnostic

**Files:**
- Modify: `Sources/WapleRender/SceneRenderer.swift:541,589-603`
- Modify: `Sources/WapleRender/SceneRendererResources.swift:49-65,88-106,502-522`
- Modify: `Sources/WapleRender/SceneRenderer3D.swift:211-215,277-290`
- Test: `Tests/WapleRenderTests/SceneRendererPathFallbackTests.swift`

**Interfaces:**
- Consumes: `assetData(_:package:)`, `quietAssetData(_:package:)`, `WallpaperPathSecurity.normalizedRelativePath(_:)`, and the existing package → shared-base lookup order.
- Produces: `public private(set) var hasMissingRequiredSharedAssets: Bool`, `func markMissingRequiredSharedAsset()`, and generic `resolveRequiredAsset(_:package:decode:alternate:)`. The generic wrapper owns the complete required lookup, decode, and valid alternate boundary before it may diagnose a miss.

- [ ] **Step 1: Add failing renderer diagnostic tests**

Keep the existing path tests and add these assertions/methods to `SceneRendererPathFallbackTests`:

```swift
func testRequiredAssetPackageAndBaseSuccessStayUndiagnosed() throws {
    let package = ScenePackage.assemble([
        (name: "materials/in-package.bin", data: Data("package".utf8)),
    ])
    let renderer = SceneRenderer()

    XCTAssertEqual(
        renderer.resolveRequiredAsset(
            ["materials/in-package.bin"], package: package, decode: { $0 }),
        Data("package".utf8)
    )
    XCTAssertFalse(renderer.hasMissingRequiredSharedAssets)

    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("waple-required-base-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: base.appendingPathComponent("materials", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: base) }
    try Data("base".utf8).write(to: base.appendingPathComponent("materials/in-base.bin"))
    renderer.assetBaseDir = base

    XCTAssertEqual(
        renderer.resolveRequiredAsset(
            ["materials/in-base.bin"], package: ScenePackage.assemble([]), decode: { $0 }),
        Data("base".utf8)
    )
    XCTAssertFalse(renderer.hasMissingRequiredSharedAssets)
}

func testRequiredAssetWaitsForAllCandidatesAndCollapsesRepeatedMisses() {
    let package = ScenePackage.assemble([
        (name: "raw-name.tex", data: Data("raw".utf8)),
    ])
    let renderer = SceneRenderer()

    XCTAssertEqual(
        renderer.resolveRequiredAsset(
            ["materials/raw-name.tex", "raw-name.tex"], package: package, decode: { $0 }),
        Data("raw".utf8),
        "a later raw/package candidate must prevent the diagnostic"
    )
    XCTAssertFalse(renderer.hasMissingRequiredSharedAssets)

    XCTAssertEqual(
        renderer.resolveRequiredAsset(
            ["materials/missing-but-bitmap-exists.tex"],
            package: package,
            decode: { $0 },
            alternate: { Data("bitmap".utf8) }
        ),
        Data("bitmap".utf8),
        "a successful high-level bitmap/raw alternate must prevent the diagnostic"
    )
    XCTAssertFalse(renderer.hasMissingRequiredSharedAssets)

    renderer.assetBaseDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("waple-deleted-base-\(UUID().uuidString)", isDirectory: true)
    XCTAssertNil(renderer.resolveRequiredAsset(
        ["materials/missing.tex", "missing.tex"], package: package, decode: { $0 }))
    XCTAssertTrue(renderer.hasMissingRequiredSharedAssets, "a selected but deleted base directory is a real miss")
    XCTAssertNil(renderer.resolveRequiredAsset(
        ["materials/missing-again.tex"], package: package, decode: { $0 }))
    XCTAssertTrue(renderer.hasMissingRequiredSharedAssets, "repeated misses remain one boolean diagnostic")
}

func testLowLevelQuietAndRejectedLookupsStayUndiagnosed() {
    let renderer = SceneRenderer()
    let package = ScenePackage.assemble([])

    XCTAssertNil(renderer.assetData("materials/probe.bin", package: package))
    XCTAssertNil(renderer.quietAssetData("materials/quiet.bin", package: package))
    XCTAssertNil(renderer.resolveRequiredAsset(
        ["../secret.bin"], package: package, decode: { $0 }))
    XCTAssertFalse(renderer.hasMissingRequiredSharedAssets)
}
```

- [ ] **Step 2: Run the renderer tests to verify the red state**

Run:

```bash
swift test --filter SceneRendererPathFallbackTests
```

Expected: compilation fails because `SceneRenderer` has no `resolveRequiredAsset` or `hasMissingRequiredSharedAssets` member.

- [ ] **Step 3: Add the boolean, reset it per mount, and implement final-candidate loading**

Add the state and internal setter beside `assetBaseDir` in `SceneRenderer.swift`:

```swift
var assetBaseDir: URL?  // WE 공유 에셋 폴백 디렉터리(설정), 패키지에 없는 .tex 용

public private(set) var hasMissingRequiredSharedAssets = false

func markMissingRequiredSharedAsset() {
    hasMissingRequiredSharedAssets = true
}
```

Reset it before any mount work so reusing a renderer cannot leak a previous mount's result:

```swift
public func mount(in container: NSView, project: WallpaperProject) throws {
    hasMissingRequiredSharedAssets = false
    scenePausedAt = nil
    shouldAnimate = false
    videoTextureMP4URL = nil
```

Add this wrapper immediately after `assetData` in `SceneRendererResources.swift`. It probes every candidate, attempts its decode, then attempts the high-level valid alternate. Bytes that exist but fail decoding are malformed rather than missing and therefore also do not produce a base-assets warning. Any invalid candidate makes the whole miss a security rejection:

```swift
func resolveRequiredAsset<T>(
    _ candidates: [String],
    package: ScenePackage,
    decode: (Data) -> T?,
    alternate: () -> T? = { nil }
) -> T? {
    var foundBytes = false
    for candidate in candidates {
        if let data = assetData(candidate, package: package) {
            foundBytes = true
            if let value = decode(data) { return value }
        }
    }
    if let value = alternate() { return value }
    guard !foundBytes,
          !candidates.isEmpty,
          candidates.allSatisfy({ WallpaperPathSecurity.normalizedRelativePath($0) != nil }) else {
        return nil
    }
    markMissingRequiredSharedAsset()
    return nil
}
```

Do not add diagnostic mutation to `assetData` or `quietAssetData`.

- [ ] **Step 4: Route only required renderer loads through the wrapper**

Wrap the complete 2D layer decode plus bitmap fallback, so neither a later package candidate nor a raw bitmap success can be diagnosed as missing:

```swift
} else if let loaded: (texture: MTLTexture, width: Int, height: Int) = resolveRequiredAsset(
    [layer.textureEntryName],
    package: package,
    decode: { data in
        guard let tex = TexImage.parse(data),
              let decoded = TexDecoder.rgba(from: tex, data: data, properties: variantProperties),
              let texture = makeTexture(decoded.pixels, decoded.width, decoded.height, device) else {
            return nil
        }
        return (texture, decoded.width, decoded.height)
    },
    alternate: {
        guard let decoded = bitmapRGBAFile(layer.textureEntryName),
              let texture = makeTexture(decoded.pixels, decoded.width, decoded.height, device) else {
            return nil
        }
        return (texture, decoded.width, decoded.height)
    }
) {
    mtl = loaded.texture
    effW = loaded.width
    effH = loaded.height
} else {
    continue
}
```

Use the same high-level boundary for the 3D model and billboard. Existing bytes that fail parsing are malformed, not missing. The 3D path has no separate bitmap-file alternate today, so do not add one in this diagnostics change:

```swift
guard let model: Model3D = resolveRequiredAsset(
    [obj.model], package: package, decode: { Model3D.parse($0) }
) else {
    NSLog("%@", "[Waple] 3D: mdl load failed: \(obj.model)")
    skipped += 1
    continue
}

// In the non-solid billboard branch:
guard let resolved: (pixels: Data, width: Int, height: Int) = resolveRequiredAsset(
    [layer.textureEntryName],
    package: package,
    decode: { data in
        guard let tex = TexImage.parse(data) else { return nil }
        return TexDecoder.rgba(from: tex, data: data, properties: variantProperties)
    }
) else {
    bbSkipped += 1
    continue
}
decoded = resolved
```

Replace the candidate/raw pair inside `resolveTextureWithFrames` with one complete decode boundary. The white texture remains a degraded fallback and therefore is created only after a valid named source truly missed:

```swift
if let name {
    let candidates = name.hasSuffix(".tex")
        ? [name]
        : ["materials/\(name).tex", name]
    if let resolved: (texture: MTLTexture, frames: [TexImage.TexFrame]) = resolveRequiredAsset(
        candidates,
        package: package,
        decode: { d in
            guard let tex = TexImage.parse(d) else { return nil }
            let multipage = tex.imageCount > 1
            if multipage, !tex.frames.isEmpty,
               let stacked = stackedAtlas(tex: tex, data: d, device: device) {
                return stacked
            }
            if let dec = TexDecoder.rgba(from: tex, data: d, properties: variantProperties),
               let texture = makeTexture(dec.pixels, dec.width, dec.height, device) {
                return (texture, multipage ? [] : tex.frames)
            }
            return nil
        }
    ) {
        return resolved
    }
}
return makeTexture(Data([255, 255, 255, 255]), 1, 1, device).map { ($0, []) }
```

Keep shader includes, effect metadata, puppet probes, mesh material JSON, and fonts on `quietAssetData`; those optional/fallback paths must not raise this warning.

- [ ] **Step 5: Run the focused renderer tests and commit**

Run:

```bash
swift test --filter SceneRendererPathFallbackTests
```

Expected: all `SceneRendererPathFallbackTests` pass, including case-insensitive base fallback and traversal/symlink rejection.

Commit only the task files:

```bash
git add -- Sources/WapleRender/SceneRenderer.swift Sources/WapleRender/SceneRendererResources.swift Sources/WapleRender/SceneRenderer3D.swift Tests/WapleRenderTests/SceneRendererPathFallbackTests.swift
git commit -m '기능(render): 필수 공유 에셋 누락 진단 추가'
```

---

### Task 2: SceneDocument Required Shared-Resolver Boundary

**Files:**
- Modify: `Sources/WapleCore/SceneDocument.swift:402-408,484-505,546-553,875-919`
- Modify: `Sources/WapleRender/SceneRenderer.swift:617-631`
- Test: `Tests/WapleCoreTests/SceneDocumentTests.swift`

**Interfaces:**
- Consumes: Task 1's `markMissingRequiredSharedAsset()` and the existing injected `assets: ((String) -> Data?)?` resolver.
- Produces: `SceneDocument.parse(package:assets:onMissingRequiredAsset:userProps:)` where `onMissingRequiredAsset: (() -> Void)?` fires only for a valid relative model/material path whose package and shared resolver both return nil.

- [ ] **Step 1: Add failing Core boundary tests**

Add these methods to `SceneDocumentTests`:

```swift
func testSelfContainedRequiredLayerDoesNotReportSharedMiss() throws {
    let scene = """
    {"general":{"orthogonalprojection":{"width":100,"height":100}},
     "objects":[{"image":"models/x.json","visible":true}]}
    """
    let package = try pkg([
        ("scene.json", scene),
        ("models/x.json", model),
        ("materials/m.json", material),
    ])
    var misses = 0

    let document = try SceneDocument.parse(
        package: package,
        assets: { _ in nil },
        onMissingRequiredAsset: { misses += 1 }
    )

    XCTAssertEqual(document.layers.count, 1)
    XCTAssertEqual(misses, 0)
}

func testRequiredLayerResolvedBySharedAssetsDoesNotReportMiss() throws {
    let scene = """
    {"general":{"orthogonalprojection":{"width":100,"height":100}},
     "objects":[{"image":"models/util/solidlayer.json","visible":true}]}
    """
    let package = try pkg([("scene.json", scene)])
    let shared: [String: String] = [
        "models/util/solidlayer.json": #"{"material":"materials/util/solidlayer.json"}"#,
        "materials/util/solidlayer.json": #"{"passes":[{"shader":"flat"}]}"#,
    ]
    var misses = 0

    let document = try SceneDocument.parse(
        package: package,
        assets: { shared[$0].map { Data($0.utf8) } },
        onMissingRequiredAsset: { misses += 1 }
    )

    XCTAssertEqual(document.layers.count, 1)
    XCTAssertEqual(misses, 0)
}

func testMissingRequiredLayerReportsButInvalidPathDoesNot() throws {
    let missingScene = """
    {"general":{"orthogonalprojection":{"width":100,"height":100}},
     "objects":[{"image":"models/missing.json","visible":true}]}
    """
    var misses = 0
    let missingDocument = try SceneDocument.parse(
        package: try pkg([("scene.json", missingScene)]),
        assets: { _ in nil },
        onMissingRequiredAsset: { misses += 1 }
    )
    XCTAssertTrue(missingDocument.layers.isEmpty)
    XCTAssertEqual(misses, 1)

    let rejectedScene = """
    {"general":{"orthogonalprojection":{"width":100,"height":100}},
     "objects":[{"image":"../outside.json","visible":true}]}
    """
    var rejectedMisses = 0
    let rejectedDocument = try SceneDocument.parse(
        package: try pkg([("scene.json", rejectedScene)]),
        assets: { _ in
            XCTFail("invalid relative paths must not reach the shared resolver")
            return nil
        },
        onMissingRequiredAsset: { rejectedMisses += 1 }
    )
    XCTAssertTrue(rejectedDocument.layers.isEmpty)
    XCTAssertEqual(rejectedMisses, 0)
}
```

- [ ] **Step 2: Run the Core tests to verify the red state**

Run:

```bash
swift test --filter SceneDocumentTests
```

Expected: compilation fails with an extra argument error for `onMissingRequiredAsset`.

- [ ] **Step 3: Thread the missing-only callback through parsing**

Extend the public signature without breaking existing callers:

```swift
public static func parse(
    package: ScenePackage,
    assets: ((String) -> Data?)? = nil,
    onMissingRequiredAsset: (() -> Void)? = nil,
    userProps: [String: Any] = [:]
) throws -> SceneDocument {
```

Pass `onMissingRequiredAsset` from the image-object branch into `parseLayer`, and from there into `resolveLayerTexture`:

```swift
if let layer = parseLayer(
    obj,
    imagePath: imagePath,
    order: order,
    pw: pw,
    ph: ph,
    package: package,
    assets: assets,
    missingRequiredAsset: onMissingRequiredAsset,
    userProps: userProps,
    visibleScript: visibleScript,
    initialVisible: initialVisible
) {
    layers.append(layer)
}
```

```swift
private static func parseLayer(
    _ obj: [String: Any],
    imagePath: String,
    order: Int,
    pw: Int,
    ph: Int,
    package: ScenePackage,
    assets: ((String) -> Data?)?,
    missingRequiredAsset: (() -> Void)?,
    userProps: [String: Any],
    visibleScript: String?,
    initialVisible: Bool
) -> SceneLayer? {
    guard let resolved = resolveLayerTexture(
        imagePath: imagePath,
        package: package,
        assets: assets,
        missingRequiredAsset: missingRequiredAsset,
        userProps: userProps
    ) else {
        return nil
    }
```

Keep the rest of `parseLayer` unchanged.

- [ ] **Step 4: Mark only missing bytes at the complete model/material resolution boundary**

Replace `resolveLayerTexture` with this implementation. Invalid paths, malformed JSON, missing `material`, and malformed material schemas still log/drop the layer but do not masquerade as a base-assets miss:

```swift
private static func resolveLayerTexture(
    imagePath: String,
    package: ScenePackage,
    assets: ((String) -> Data?)? = nil,
    missingRequiredAsset: (() -> Void)? = nil,
    userProps: [String: Any] = [:]
) -> LayerTexture? {
    func requiredData(_ name: String) -> Data? {
        if let data = package.data(for: name) {
            return data
        }
        guard WallpaperPathSecurity.normalizedRelativePath(name) != nil else {
            return nil
        }
        if let data = assets?(name) {
            return data
        }
        missingRequiredAsset?()
        return nil
    }

    guard let modelData = requiredData(imagePath),
          let model = (try? JSONSerialization.jsonObject(with: modelData)) as? [String: Any],
          let materialPath = model["material"] as? String,
          let materialData = requiredData(materialPath),
          let material = (try? JSONSerialization.jsonObject(with: materialData)) as? [String: Any],
          let passes = material["passes"] as? [Any],
          let pass0 = passes.first as? [String: Any] else {
        WapleLog.warn("[Waple] image layer texture resolve failed: \(imagePath)")
        return nil
    }

    var textures = pass0["textures"] as? [Any] ?? []
    if let userTextures = pass0["usertextures"] as? [Any] {
        for (slot, rawUserKey) in userTextures.enumerated() {
            guard let userKey = rawUserKey as? String,
                  let override = userProps[userKey] as? String,
                  !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            while textures.count <= slot {
                textures.append(NSNull())
            }
            textures[slot] = override
        }
    }
    guard let name = textures.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) else {
        return .solid
    }
    if name.hasPrefix("_rt_") {
        let fullscreen = (model["fullscreen"] as? Bool) ?? (model["autosize"] as? Bool) ?? false
        return .frameBuffer(fullscreen: fullscreen)
    }
    if name.hasPrefix("/") {
        return .entry(name)
    }
    let candidates = name.hasSuffix(".tex") ? [name] : ["materials/\(name).tex", name]
    for candidate in candidates where package.data(for: candidate) != nil {
        return .entry(candidate)
    }
    return .entry(candidates[0])
}
```

Do not pass the callback into `composeParentTransforms`' puppet probe; missing puppets remain an intentional quiet fallback.

- [ ] **Step 5: Bridge the Core callback to the renderer boolean**

In `SceneRenderer.mount`, add the callback between `assets` and `userProps`:

```swift
doc = try SceneDocument.parse(
    package: package,
    assets: { name in
        guard let base = BaseAssetsSettings.baseAssetsDirectory,
              let url = WallpaperPathSecurity.containedFileURL(name, root: base) else {
            return nil
        }
        return try? Data(contentsOf: url)
    },
    onMissingRequiredAsset: { [weak self] in
        self?.markMissingRequiredSharedAsset()
    },
    userProps: UserPropertyStore.rawOverrides(
        id: project.id,
        presetOverrides: project.presetOverrides,
        presetResourceRoot: project.presetFolderURL
    )
)
```

- [ ] **Step 6: Run both affected test classes and commit**

Run:

```bash
swift test --filter 'SceneDocumentTests|SceneRendererPathFallbackTests'
```

Expected: all selected tests pass; self-contained/shared successes remain false, actual valid-path misses report, and invalid paths remain security-only failures.

Commit only the task files:

```bash
git add -- Sources/WapleCore/SceneDocument.swift Sources/WapleRender/SceneRenderer.swift Tests/WapleCoreTests/SceneDocumentTests.swift
git commit -m '기능(core): Scene 필수 공유 리졸버 누락 전달'
```

---

### Task 3: Successful-Swap Warning Gate and App Wiring

**Files:**
- Create: `Sources/Waple/BaseAssetsWarningGate.swift`
- Modify: `Sources/WapleRender/BaseAssetsSettings.swift:7-29`
- Modify: `Sources/Waple/AppDelegate.swift:8-46,255-303,476-481`
- Create: `Tests/WapleAppTests/BaseAssetsWarningGateTests.swift`
- Preserve: `Sources/Waple/Shell/StatusBanner.swift`
- Preserve: `Tests/WapleAppTests/StatusBannerModelTests.swift`

**Interfaces:**
- Consumes: Task 1's `SceneRenderer.hasMissingRequiredSharedAssets`, `RendererSwap.apply`'s `Result<[R], Error>`, and `BaseAssetsSettings`' persisted selection.
- Produces: `BaseAssetsSettings.fingerprint: String`; `BaseAssetsWarningGate.message`; `BaseAssetsWarningGate.presentIfNeeded(after:fingerprint:missingRequiredSharedAssets:present:)`; and `AppDelegate.notify(_:) -> Bool`.

- [ ] **Step 1: Add failing warning-policy tests**

Create `Tests/WapleAppTests/BaseAssetsWarningGateTests.swift`:

```swift
import XCTest
@testable import Waple

final class BaseAssetsWarningGateTests: XCTestCase {
    private enum Diagnostic {
        case scene(Bool)
        case web
        case video
    }

    private enum SwapFailure: Error {
        case mount
    }

    private func sceneDiagnostic(_ diagnostic: Diagnostic) -> Bool? {
        guard case .scene(let missing) = diagnostic else {
            return nil
        }
        return missing
    }

    func testFailedSwapSelfContainedSceneAndNonSceneRenderersDoNotPresent() {
        var gate = BaseAssetsWarningGate()
        var presented: [String] = []
        let failure: Result<[Diagnostic], Error> = .failure(SwapFailure.mount)
        gate.presentIfNeeded(
            after: failure,
            fingerprint: "<automatic>",
            missingRequiredSharedAssets: sceneDiagnostic,
            present: { presented.append($0); return true }
        )

        let noMiss: Result<[Diagnostic], Error> = .success([.scene(false), .web, .video])
        gate.presentIfNeeded(
            after: noMiss,
            fingerprint: "<automatic>",
            missingRequiredSharedAssets: sceneDiagnostic,
            present: { presented.append($0); return true }
        )

        XCTAssertTrue(presented.isEmpty)
    }

    func testMultiMonitorMissPresentsOnceUntilFingerprintChanges() {
        var gate = BaseAssetsWarningGate()
        var presented: [String] = []
        let misses: Result<[Bool], Error> = .success([true, true, false])

        gate.presentIfNeeded(
            after: misses,
            fingerprint: "/assets/a",
            missingRequiredSharedAssets: { $0 },
            present: { presented.append($0); return true }
        )
        gate.presentIfNeeded(
            after: misses,
            fingerprint: "/assets/a",
            missingRequiredSharedAssets: { $0 },
            present: { presented.append($0); return true }
        )
        XCTAssertEqual(presented, [BaseAssetsWarningGate.message])
        XCTAssertEqual(
            BaseAssetsWarningGate.message,
            "공유 기본 에셋을 찾지 못해 일부 씬 요소가 표시되지 않습니다 — 설정 > 에셋·도구에서 폴더를 지정하세요."
        )

        gate.presentIfNeeded(
            after: misses,
            fingerprint: "/assets/b",
            missingRequiredSharedAssets: { $0 },
            present: { presented.append($0); return true }
        )
        XCTAssertEqual(presented, [BaseAssetsWarningGate.message, BaseAssetsWarningGate.message])
    }

    func testHiddenWindowDoesNotConsumePresentationAllowance() {
        var gate = BaseAssetsWarningGate()
        let miss: Result<[Bool], Error> = .success([true])
        var windowVisible = false
        var notifyCalls = 0
        var bannerCount = 0

        gate.presentIfNeeded(
            after: miss,
            fingerprint: "/assets/a",
            missingRequiredSharedAssets: { $0 },
            present: { _ in
                notifyCalls += 1
                if windowVisible { bannerCount += 1 }
                return windowVisible
            }
        )
        windowVisible = true
        gate.presentIfNeeded(
            after: miss,
            fingerprint: "/assets/a",
            missingRequiredSharedAssets: { $0 },
            present: { _ in
                notifyCalls += 1
                if windowVisible { bannerCount += 1 }
                return windowVisible
            }
        )
        gate.presentIfNeeded(
            after: miss,
            fingerprint: "/assets/a",
            missingRequiredSharedAssets: { $0 },
            present: { _ in
                notifyCalls += 1
                if windowVisible { bannerCount += 1 }
                return windowVisible
            }
        )

        XCTAssertEqual(notifyCalls, 2, "the hidden attempt is retried, then a visible banner consumes the gate")
        XCTAssertEqual(bannerCount, 1)
    }
}
```

- [ ] **Step 2: Run the gate tests to verify the red state**

Run:

```bash
swift test --filter BaseAssetsWarningGateTests
```

Expected: compilation fails because `BaseAssetsWarningGate` does not exist.

- [ ] **Step 3: Implement the successful-swap/fingerprint/presentation gate**

Create `Sources/Waple/BaseAssetsWarningGate.swift`:

```swift
import Foundation

struct BaseAssetsWarningGate {
    static let message = "공유 기본 에셋을 찾지 못해 일부 씬 요소가 표시되지 않습니다 — 설정 > 에셋·도구에서 폴더를 지정하세요."

    private var fingerprint: String?
    private var didPresent = false

    init() {}

    mutating func presentIfNeeded<R>(
        after swap: Result<[R], Error>,
        fingerprint currentFingerprint: String,
        missingRequiredSharedAssets: (R) -> Bool?,
        present: (String) -> Bool
    ) {
        guard case .success(let renderers) = swap else {
            return
        }
        if fingerprint != currentFingerprint {
            fingerprint = currentFingerprint
            didPresent = false
        }
        guard !didPresent,
              renderers.compactMap(missingRequiredSharedAssets).contains(true) else {
            return
        }
        if present(Self.message) {
            didPresent = true
        }
    }
}
```

This signature makes failed swaps a no-op, folds all Scene booleans into one decision, and lets `nil` exclude web/video renderers without teaching the gate about renderer classes.

- [ ] **Step 4: Expose a stable selected-setting fingerprint**

Add this property to `BaseAssetsSettings`. It fingerprints the persisted selection rather than the auto-detected effective folder, so automatic filesystem changes cannot reset the session gate; selecting the same normalized folder also remains the same fingerprint:

```swift
public static var fingerprint: String {
    guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else {
        return "<automatic>"
    }
    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
}
```

Do not change `baseAssetsDirectory` discovery or persistence.

- [ ] **Step 5: Wire the gate after the successful renderer swap**

Add one session-owned gate beside `bannerModel`:

```swift
private let bannerModel = StatusBannerModel()
private var baseAssetsWarningGate = BaseAssetsWarningGate()
```

At the end of `.success(let newRenderers)`, after state has been swapped and before returning `true`, add:

```swift
baseAssetsWarningGate.presentIfNeeded(
    after: result,
    fingerprint: BaseAssetsSettings.fingerprint,
    missingRequiredSharedAssets: { renderer in
        (renderer as? SceneRenderer)?.hasMissingRequiredSharedAssets
    },
    present: { [weak self] message in
        guard let self else { return false }
        return self.notify(message)
    }
)
return true
```

Leave `.failure` unchanged so a mount failure only produces its existing `적용 실패` notification. Because `RendererFactory` returns `WebRenderer`/`VideoRenderer` for those project types, the cast returns nil and they cannot enter this warning policy.

Change `notify` to report actual banner presentation while preserving logging and all existing callers:

```swift
@discardableResult
private func notify(_ message: String) -> Bool {
    NSLog("%@", "[Waple] \(message)")
    guard let window = libraryWindow, window.isVisible else {
        return false
    }
    bannerModel.show(message)
    return true
}
```

- [ ] **Step 6: Run focused gate/banner tests and commit**

Run:

```bash
swift test --filter 'BaseAssetsWarningGateTests|StatusBannerModelTests'
```

Expected: all selected tests pass. Existing StatusBanner show/dismiss/generation behavior remains unchanged; hidden-window attempts do not consume the new gate.

Commit only the task files:

```bash
git add -- Sources/Waple/BaseAssetsWarningGate.swift Sources/WapleRender/BaseAssetsSettings.swift Sources/Waple/AppDelegate.swift Tests/WapleAppTests/BaseAssetsWarningGateTests.swift
git commit -m '기능(app): base-assets 누락 배너 중복 제어'
```

---

### Task 4: Backlog Update and Integrated Lane Verification

**Files:**
- Modify: `BACKLOG.md:25-32,52-58`
- Test only: `Tests/WapleCoreTests/SceneDocumentTests.swift`
- Test only: `Tests/WapleRenderTests/SceneRendererPathFallbackTests.swift`
- Test only: `Tests/WapleAppTests/BaseAssetsWarningGateTests.swift`
- Test only: `Tests/WapleAppTests/StatusBannerModelTests.swift`

**Interfaces:**
- Consumes: Tasks 1-3's renderer boolean, Core callback, stable fingerprint, successful-swap gate, and exact warning copy.
- Produces: current product/backlog wording plus a clean, focused-test-green `codex/base-assets-warning` branch for Wave 1 integration.

- [ ] **Step 1: Update the two stale BACKLOG entries with exact current status**

Replace the `3D 메시 라이팅` row with:

```markdown
| ~~3D 메시 라이팅~~ | **완료(P3/P4)** | 3D 메시·`LIGHTING` 원근 빌보드 Cook–Torrance PBR, 최대 4 `lpoint`, 6면 point-shadow atlas + 9-tap PCF 완료([Scene3DLighting.swift](Sources/WapleRender/Scene3DLighting.swift), [SceneRenderer3D.swift](Sources/WapleRender/SceneRenderer3D.swift)); 비-LIGHTING 빌보드는 기존 unlit 유지 |
```

Replace productization item 2 with:

```markdown
2. 최초 실행 온보딩 + base-assets/ffmpeg 미설정 안내 → **base-assets 조용한 저하 부분 해소**: 실제 필수 공유 에셋 miss 때 설정 경로를 StatusBanner로 앱 세션·설정 fingerprint당 1회 안내. 잔여: 최초 실행 onboarding, ffmpeg 미설정 안내, 메인창 닫힘 상태의 base-assets NSLog-only 안내
```

- [ ] **Step 2: Run the complete lane-focused filter**

Run exactly:

```bash
swift test --filter 'SceneDocumentTests|SceneRendererPathFallbackTests|BaseAssetsWarningGateTests|StatusBannerModelTests'
```

Expected: every selected test passes. Do not broaden this to the full Swift suite or any render corpus.

- [ ] **Step 3: Check the lane diff mechanically and commit documentation**

Run:

```bash
git diff --check
git status --short
```

Expected before the documentation commit: no whitespace errors; `BACKLOG.md` is the only uncommitted path and `.vscode/launch.json` is absent from lane status.

Commit:

```bash
git add -- BACKLOG.md
git commit -m '문서: 3D P3/P4 및 base-assets 안내 현행화'
```

- [ ] **Step 4: Hand off the tested lane without a lane review**

Run:

```bash
git status --short
git log -4 --oneline
```

Expected: clean lane worktree and four task commits at HEAD. Report the focused test command/result and HEAD hash to the Wave 1 integrator. Do not request or perform a per-lane code review; the integration plan performs the single whole-diff review after all lanes merge.
