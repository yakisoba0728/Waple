# WE Particle Rotation and 2D Ambient Fidelity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve Wallpaper Engine particle rotation values as radians and make 2D forward lighting use flat ambient color without skylight mixing.

**Architecture:** Keep both fixes inside their existing WapleCore ownership boundaries. Particle JSON continues to parse into `Initializer` unchanged, while `ParticleSimulator` stops applying an extra unit conversion; 2D lighting continues to use `SceneLight3D.ForwardUniforms`, but its ambient term becomes the scene ambient color. Tests cover parser-to-simulator behavior, uniform packing, and Metal-rendered skylight invariance.

**Tech Stack:** Swift 5.9+, Swift Package Manager, XCTest, Metal offscreen rendering, WapleCompat snapshot regression.

## Global Constraints

- Support macOS 14 or newer and Apple Silicon.
- Add no dependencies and change no public enum case signatures.
- Keep `skylightColor` parsing and 3D lighting data intact.
- Do not implement particle exponent/endtime, PBR, bloom, ACES, web pause, or 3D particle changes.
- Preserve the user's existing `.vscode/launch.json` modification.
- Follow TDD: observe each new test fail before changing production code.

---

## File Map

- `Sources/WapleCore/ParticleSystem.swift`: documents initializer unit contracts.
- `Sources/WapleCore/ParticleSimulator.swift`: applies rotation and angular velocity initializers.
- `Tests/WapleCoreTests/ParticleSystemTests.swift`: verifies JSON-to-simulator radian preservation.
- `Sources/WapleCore/SceneDocument.swift`: packs 2D forward-lighting uniforms and provides the CPU lighting oracle.
- `Tests/WapleCoreTests/SceneForwardLightingTests.swift`: verifies flat ambient uniform packing.
- `Tests/WapleRenderTests/SceneForwardLightingRenderTests.swift`: verifies rendered 2D output is invariant to skylight changes.

### Task 0: Capture the Pre-change Pixel Baseline

**Files:**
- Create outside repository: `/Users/yakisoba/Downloads/wallpaper_dev/.waple-snapshots/pre-we-fidelity-c25baf6/`

**Interfaces:**
- Consumes: current renderer at design commit `c25baf6` and corpus `/Users/yakisoba/Downloads/wallpaper_dev`.
- Produces: a pre-change manifest and thumbnails for final comparison.

- [ ] **Step 1: Confirm only the design commit and the user's existing file are present**

Run:

```bash
git status --short
```

Expected: only ` M .vscode/launch.json`; no source or test changes.

- [ ] **Step 2: Capture a fresh pre-change baseline**

Run:

```bash
swift run -c release WapleCompat --capture \
  /Users/yakisoba/Downloads/wallpaper_dev/.waple-snapshots \
  --label pre-we-fidelity-c25baf6 \
  /Users/yakisoba/Downloads/wallpaper_dev
```

Expected: `manifest.json` exists under the new label, mount failures are zero, and deterministic captures complete. Do not commit generated snapshots.

### Task 1: Preserve Particle Rotation Radians End to End

**Files:**
- Modify: `Tests/WapleCoreTests/ParticleSystemTests.swift`
- Modify: `Sources/WapleCore/ParticleSystem.swift:34-35`
- Modify: `Sources/WapleCore/ParticleSimulator.swift:423-426`

**Interfaces:**
- Consumes: `ParticleSystemDef.parse(_:material:resolveChild:)`, `ParticleSimulator.init(def:seed:)`, and `ParticleSimulator.step(_:)`.
- Produces: `Particle.rotation` in radians and `Particle.angularVel` in radians per second without post-parse conversion.

- [ ] **Step 1: Add the failing parser-to-simulator test**

Add to `ParticleSystemTests`:

```swift
func testRotationInitializersPreserveRadiansEndToEnd() throws {
    let twoPi = Float.pi * 2
    let pi = Float.pi
    let source = """
    {"emitter":[{"name":"boxrandom","origin":"0 0 0","distancemax":"0 0 0","instantaneous":1}],
     "initializer":[
       {"name":"lifetimerandom","min":10,"max":10},
       {"name":"rotationrandom","min":"\(twoPi) 0 0","max":"\(twoPi) 0 0"},
       {"name":"angularvelocityrandom","min":"\(pi) 0 0","max":"\(pi) 0 0"}],
     "renderer":[{"name":"sprite"}],"maxcount":1}
    """
    let def = ParticleSystemDef.parse(json(source), material: nil)
    var simulator = ParticleSimulator(def: def, seed: 7)

    let particle = try XCTUnwrap(simulator.step(0).first)

    XCTAssertEqual(particle.rotation.x, twoPi, accuracy: 1e-6)
    XCTAssertEqual(particle.angularVel.x, pi, accuracy: 1e-6)
}
```

- [ ] **Step 2: Run the test and verify the old conversion fails it**

Run:

```bash
swift test --filter ParticleSystemTests/testRotationInitializersPreserveRadiansEndToEnd
```

Expected: FAIL because rotation is about `0.10966` and angular velocity about `0.05483`.

- [ ] **Step 3: Remove the extra degree conversion and correct unit comments**

In `ParticleSystem.swift`, change the contracts to:

```swift
case rotationRandom(min: Vec3, max: Vec3)          // radians
case angularVelocityRandom(min: Vec3, max: Vec3)   // radians/s
```

In `ParticleSimulator.apply(_:to:)`, use the sampled values directly:

```swift
case let .rotationRandom(mn, mx):
    p.rotation = SIMD3(rng.range(mn.x, mx.x), rng.range(mn.y, mx.y), rng.range(mn.z, mx.z))
case let .angularVelocityRandom(mn, mx):
    p.angularVel = SIMD3(rng.range(mn.x, mx.x), rng.range(mn.y, mx.y), rng.range(mn.z, mx.z))
```

- [ ] **Step 4: Run particle tests**

Run:

```bash
swift test --filter ParticleSystemTests
swift test --filter ParticleSimulatorTests
```

Expected: PASS for both suites.

- [ ] **Step 5: Commit the particle correction**

```bash
git add Sources/WapleCore/ParticleSystem.swift \
  Sources/WapleCore/ParticleSimulator.swift \
  Tests/WapleCoreTests/ParticleSystemTests.swift
git commit -m "수정(particle): 회전 initializer 라디안 이중변환 제거"
```

### Task 2: Use Flat Ambient for 2D Forward Lighting

**Files:**
- Modify: `Tests/WapleCoreTests/SceneForwardLightingTests.swift`
- Modify: `Tests/WapleRenderTests/SceneForwardLightingRenderTests.swift`
- Modify: `Sources/WapleCore/SceneDocument.swift:282-311`
- Modify comments only as needed: `Sources/WapleRender/SceneRenderer.swift:464`, `Sources/WapleRender/QuadShaders.swift:70`

**Interfaces:**
- Consumes: `SceneLight3D.forwardUniforms(_:ambient:skylight:)` and the existing `f_lit` ambient buffer.
- Produces: `ForwardUniforms.ambientTerm == SIMD3(ambient.x, ambient.y, ambient.z)` for 2D lighting.

- [ ] **Step 1: Change the unit-test expectation to the WE flat-ambient contract**

In `testForwardUniformsPacking`, replace the old averaged expectation with:

```swift
XCTAssertEqual(u.ambientTerm, SIMD3<Float>(0.3, 0.2, 0.1))   // genericimage4: flat ambient only
```

- [ ] **Step 2: Extend the render helper and add a failing skylight-invariance test**

Extend the `capture` helper signature:

```swift
private func capture(lightColor: String?, lighting: Bool, tag: String,
                     ambient: String = "0.3 0.3 0.3",
                     skylight: String = "0.3 0.3 0.3") throws -> NSBitmapImageRep
```

Use those values in the generated scene JSON:

```swift
"ambientcolor":"\(ambient)","skylightcolor":"\(skylight)"
```

Add this test:

```swift
func testSkylightDoesNotAffectFlat2DAmbient() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
    let darkSky = try capture(lightColor: "0 0 0", lighting: true, tag: "flat_ambient_dark_sky",
                              ambient: "0.2 0.3 0.4", skylight: "0 0 0")
    let brightSky = try capture(lightColor: "0 0 0", lighting: true, tag: "flat_ambient_bright_sky",
                                ambient: "0.2 0.3 0.4", skylight: "1 1 1")
    var maxDiff = 0.0
    for y in 0..<36 {
        for x in 0..<64 {
            let a = rgb(darkSky, x, y), b = rgb(brightSky, x, y)
            maxDiff = max(maxDiff, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
        }
    }
    XCTAssertLessThan(maxDiff, 0.01, "2D genericimage4 ambient must ignore skylight")
}
```

- [ ] **Step 3: Run both tests and verify they fail under averaged ambient**

Run:

```bash
swift test --filter SceneForwardLightingTests/testForwardUniformsPacking
swift test --filter SceneForwardLightingRenderTests/testSkylightDoesNotAffectFlat2DAmbient
```

Expected: both FAIL because current code averages ambient and skylight.

- [ ] **Step 4: Implement flat ambient and correct stale comments**

In `SceneLight3D.forwardUniforms`, retain the signature and explicitly ignore the 2D-irrelevant parameter:

```swift
static func forwardUniforms(_ lights: [SceneLight3D], ambient: Vec3, skylight _: Vec3) -> ForwardUniforms {
    var pos = [SIMD4<Float>](repeating: .zero, count: 4)
    var cr = [SIMD4<Float>](repeating: .zero, count: 4)
    let used = lights.prefix(4)
    for (i, l) in used.enumerated() {
        pos[i] = SIMD4(l.origin.x, l.origin.y, l.origin.z, 1)
        cr[i] = SIMD4(l.color.x * l.intensity, l.color.y * l.intensity, l.color.z * l.intensity, l.radius)
    }
    let amb = SIMD3(ambient.x, ambient.y, ambient.z)
    return ForwardUniforms(positions: pos, colorRadius: cr, ambientTerm: amb, count: used.count)
}
```

Update nearby comments in `SceneDocument.swift`, `SceneRenderer.swift`, and `QuadShaders.swift` from `(skylight+ambient)/2` or hemisphere wording to `flat ambient (genericimage4)`.

- [ ] **Step 5: Run lighting tests**

Run:

```bash
swift test --filter SceneForwardLightingTests
swift test --filter SceneForwardLightingRenderTests
```

Expected: PASS for both suites.

- [ ] **Step 6: Commit the ambient correction**

```bash
git add Sources/WapleCore/SceneDocument.swift \
  Sources/WapleRender/SceneRenderer.swift \
  Sources/WapleRender/QuadShaders.swift \
  Tests/WapleCoreTests/SceneForwardLightingTests.swift \
  Tests/WapleRenderTests/SceneForwardLightingRenderTests.swift
git commit -m "수정(render): 2D 라이팅 ambient를 flat 색으로 교정"
```

### Task 3: Full Verification and Snapshot Triage

**Files:**
- Read only: source/test changes from Tasks 1-2.
- Read outside repository: `/Users/yakisoba/Downloads/wallpaper_dev/.waple-snapshots/pre-we-fidelity-c25baf6/`

**Interfaces:**
- Consumes: the two committed corrections and the pre-change snapshot manifest.
- Produces: evidence that tests pass and pixel differences are limited to the intended fidelity changes.

- [ ] **Step 1: Run formatting and diff hygiene checks**

Run:

```bash
git diff --check HEAD~2..HEAD
git status --short
```

Expected: no diff-check errors; status contains only the user's ` M .vscode/launch.json`.

- [ ] **Step 2: Run the full test suite**

Run:

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 3: Compare the corrected renderer with the pre-change baseline**

Run:

```bash
swift run -c release WapleCompat --compare \
  /Users/yakisoba/Downloads/wallpaper_dev/.waple-snapshots/pre-we-fidelity-c25baf6 \
  /Users/yakisoba/Downloads/wallpaper_dev
```

Expected: no mount failures or rendered-to-empty regressions. Pixel differences may be reported for scenes that use particle rotation/angular velocity or 2D `LIGHTING`; inspect every reported scene and reject unexplained changes.

- [ ] **Step 4: Record the verification result**

If no source change is needed, do not create an empty commit. Report the test totals, snapshot counts, and each intentional changed scene in the final handoff.
