# WE 2D Light Exponent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carry each parsed 2D scene-light exponent into the existing four-slot forward-light payload and use the WE finite-light falloff in both the CPU oracle and Metal shader.

**Architecture:** Reuse `ForwardUniforms.positions[i].w`, which is currently an unused active marker, as the per-light exponent. Radius already gates inactive slots. Keep the renderer's existing fragment-buffer layout, and mirror the same hard-zero epsilon falloff in `SceneLight3D.evaluateLighting` and `QuadShaders.f_lit`.

**Tech Stack:** Swift 6, XCTest, Metal Shading Language, Swift Package Manager.

## Global Constraints

- Use `falloff = saturate(1 - distance / radius)` and `falloff >= 6.103515625e-5 ? pow(falloff + 6.103515625e-5, exponent) : 0`.
- Preserve raw finite exponent values, including `0`; do not add an exponent clamp.
- Preserve the existing parser fallback `exponent = 1` and do not change JSON parsing in this task.
- Preserve `radius <= 0` and `distance < 1e-5` contribution guards.
- Preserve first-four scene-order selection and current finite-point approximation for all 2D light types.
- Do not implement Cook–Torrance, light-type branching, 3D lighting, cookies, or shadows.
- Run only `SceneForwardLightingTests`, the new shader-contract test, and one existing rendered-light smoke test. Do not run the full Swift suite or render corpus.
- Perform one whole-branch review after all implementation; do not review each task separately.
- Preserve the user-owned `.vscode/launch.json` modification and never stage it.
- Commit messages must not contain an AI watermark.

---

### Task 1: Pack exponent and update the CPU lighting oracle

**Files:**
- Modify: `Tests/WapleCoreTests/SceneForwardLightingTests.swift`
- Modify: `Sources/WapleCore/SceneDocument.swift:281-332`

**Interfaces:**
- Consumes: `SceneDocument.parse(package:)`, `SceneLight3D.exponent`, `SceneLight3D.forwardUniforms(_:ambient:skylight:)`, and `SceneLight3D.evaluateLighting(at:_:normal:)`.
- Produces: `ForwardUniforms.positions[i].w == SceneLight3D.exponent` and a CPU oracle using the hard-zero finite-light exponent falloff.

- [ ] **Step 1: Parameterize the test light helper and preserve quadratic fixtures explicitly**

Change the helper to:

```swift
    private func light(_ o: Vec3, _ c: Vec3, intensity: Float, radius: Float,
                       exponent: Float = 1) -> SceneLight3D {
        SceneLight3D(id: 0, name: "", type: "lpoint", origin: o, angles: Vec3(x: 0, y: 0, z: 0),
                     color: c, radius: radius, intensity: intensity, exponent: exponent,
                     castShadow: false, parent: nil)
    }
```

In `testAttenuationMatchesHandComputation` and both lights in `testColorAndSummation`, pass `exponent: 2`. This keeps the existing quadratic hand calculations as explicit fixtures instead of relying on the old hardcoded square.

- [ ] **Step 2: Add the parser-to-forward-payload RED test**

Add:

```swift
    func testParsedExponentReachesPackedForwardUniform() throws {
        let scene = #"{"objects":[{"id":1,"light":"lpoint","origin":"0 0 5","color":"1 1 1","intensity":1,"radius":10,"exponent":3}]}"#
        let pkg = ScenePackage.assemble([("scene.json", d(scene))])
        let doc = try SceneDocument.parse(package: pkg)
        let parsed = try XCTUnwrap(doc.lights3D.first)
        XCTAssertEqual(parsed.exponent, 3)

        let u = SceneLight3D.forwardUniforms(
            doc.lights3D,
            ambient: Vec3(x: 0, y: 0, z: 0),
            skylight: Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(u.positions[0], SIMD4<Float>(0, 0, 5, 3))
        XCTAssertEqual(u.positions[1], .zero)
    }
```

- [ ] **Step 3: Add the exponent attenuation RED test**

Add `import Foundation` beside the existing XCTest import, then add:

```swift
    func testAttenuationUsesPackedLightExponent() {
        let u = SceneLight3D.forwardUniforms(
            [light(Vec3(x: 0, y: 0, z: 5), Vec3(x: 1, y: 1, z: 1),
                   intensity: 1, radius: 10, exponent: 3)],
            ambient: Vec3(x: 0, y: 0, z: 0),
            skylight: Vec3(x: 0, y: 0, z: 0))

        let c = SceneLight3D.evaluateLighting(at: SIMD3(0, 0, 0), u)
        let eps: Float = 6.103515625e-5
        XCTAssertEqual(c.x, powf(0.5 + eps, 3), accuracy: 1e-5)
        XCTAssertEqual(c.y, c.x, accuracy: 1e-6)
        XCTAssertEqual(c.z, c.x, accuracy: 1e-6)
    }
```

- [ ] **Step 4: Run the core class and verify RED**

Run:

```bash
swift test --filter SceneForwardLightingTests
```

Expected: the two new tests fail for the intended reasons. The parsed value is `3` but packed `.w` is `1`; the CPU oracle returns the old fixed-square value near `0.25` instead of the exponent-3 value near `0.125`. Existing tests pass because their quadratic fixtures now explicitly use exponent `2`.

- [ ] **Step 5: Pack exponent into the existing position payload**

Update `ForwardUniforms` documentation:

```swift
        public var positions: [SIMD4<Float>]   // xyz=world, w=finite-light exponent
```

Update the packing loop:

```swift
            pos[i] = SIMD4(l.origin.x, l.origin.y, l.origin.z, l.exponent)
```

Unused slots remain `.zero`; `colorRadius[i].w == 0` remains the inactive-slot gate.

- [ ] **Step 6: Replace the CPU fixed square with the exact finite-light falloff**

Replace the attenuation portion of `evaluateLighting` with:

```swift
            let falloff = max(0, min(1, 1 - dist / radius))
            let eps: Float = 6.103515625e-5
            let attenuation = falloff >= eps ? powf(falloff + eps, lp.w) : 0
            let nd = delta / dist
            let d = max(0, nd.x * normal.x + nd.y * normal.y + nd.z * normal.z)
            let c = SIMD3(u.colorRadius[i].x, u.colorRadius[i].y, u.colorRadius[i].z)
            light += c * (d * attenuation)
```

Update the nearby comment from quadratic attenuation to per-light exponent attenuation. Do not change the radius or zero-distance guards.

- [ ] **Step 7: Run the core class and verify GREEN**

Run:

```bash
swift test --filter SceneForwardLightingTests
```

Expected: all 11 `SceneForwardLightingTests` pass with zero failures.

- [ ] **Step 8: Commit the core payload and oracle**

```bash
git add Sources/WapleCore/SceneDocument.swift Tests/WapleCoreTests/SceneForwardLightingTests.swift
git diff --cached --check
git commit -m "수정(lighting): 2D 라이트 exponent를 포워드 팩에 연결"
```

Expected: only the two listed files are committed.

---

### Task 2: Apply exponent falloff in the Metal shader

**Files:**
- Modify: `Tests/WapleRenderTests/SceneForwardLightingRenderTests.swift`
- Modify: `Sources/WapleRender/QuadShaders.swift:57-90`
- Modify: `Sources/WapleRender/SceneRenderer.swift:464`
- Modify: `Sources/WapleRender/SceneRendererFrameEncoder.swift:511`

**Interfaces:**
- Consumes: fragment buffer `2` as four `SIMD4<Float>` entries whose `.xyz` is light position and `.w` is exponent; fragment buffer `3` remains color/radius.
- Produces: `f_lit` using the same hard-zero finite-light falloff as the CPU oracle, with no fragment-buffer layout change.

- [ ] **Step 1: Add a shader source-and-compile RED test**

Add to `SceneForwardLightingRenderTests`:

```swift
    func testForwardLightShaderUsesPackedExponent() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let source = QuadShaders.source
        XCTAssertTrue(source.contains("finiteLightFalloff(dist, radius, lightPos[i].w)"))
        XCTAssertFalse(source.contains("ndl * attn * attn"))

        let library = try device.makeLibrary(source: source, options: nil)
        XCTAssertNotNil(library.makeFunction(name: "f_lit"))
    }
```

- [ ] **Step 2: Run the new shader test and verify RED**

Run:

```bash
swift test --filter 'SceneForwardLightingRenderTests/testForwardLightShaderUsesPackedExponent'
```

Expected: FAIL because the source has no `finiteLightFalloff(... lightPos[i].w)` call and still contains `ndl * attn * attn`.

- [ ] **Step 3: Add the Metal finite-light helper**

Add inside `QuadShaders.source`, before `f_lit`:

```metal
    inline float finiteLightFalloff(float dist, float radius, float exponent) {
        float falloff = clamp(1.0 - dist / radius, 0.0, 1.0);
        constexpr float eps = 6.103515625e-5;
        return falloff >= eps ? pow(falloff + eps, exponent) : 0.0;
    }
```

Replace the loop's fixed attenuation with:

```metal
            float attenuation = finiteLightFalloff(dist, radius, lightPos[i].w);
            float ndl = max(0.0, dot(delta / dist, N));
            light += lightCol[i].xyz * (ndl * attenuation);
```

Update `f_lit` comments to describe `pow(falloff + eps, exponent)` and document `lightPos[i].w` as exponent.

- [ ] **Step 4: Correct renderer-side layout comments**

In `SceneRenderer.swift`, change the `lightPositions` comment to:

```swift
    var lightPositions = [SIMD4<Float>](repeating: .zero, count: 4)    // [4] xyz=world, w=exponent
```

In `SceneRendererFrameEncoder.swift`, change the binding comment to mention `라이트 위치·exponent/색·반경`.

- [ ] **Step 5: Run the shader contract and one mounted-pipeline smoke test**

Run:

```bash
swift test --filter 'SceneForwardLightingRenderTests/testForwardLightShaderUsesPackedExponent'
swift test --filter 'SceneForwardLightingRenderTests/testSpatialPoolBrighterAtLight'
```

Expected: both pass. The first compiles `QuadShaders.source` and resolves `f_lit`; the second mounts the real 2D light pipeline and confirms the spatial pool still renders.

- [ ] **Step 6: Run the complete focused core class again**

Run:

```bash
swift test --filter SceneForwardLightingTests
```

Expected: all 11 tests pass with zero failures.

- [ ] **Step 7: Commit the Metal implementation**

```bash
git add Sources/WapleRender/QuadShaders.swift \
  Sources/WapleRender/SceneRenderer.swift \
  Sources/WapleRender/SceneRendererFrameEncoder.swift \
  Tests/WapleRenderTests/SceneForwardLightingRenderTests.swift
git diff --cached --check
git commit -m "수정(lighting): 2D 감쇠에 광원 exponent 적용"
```

Expected: only the four listed files are committed.

---

### Task 3: Whole-change review, focused verification, and local merge

**Files:**
- Review: all changes from the feature branch merge base through HEAD
- Preserve: `.vscode/launch.json`

**Interfaces:**
- Consumes: the completed Core and Metal commits from Tasks 1 and 2.
- Produces: one whole-branch review, fresh focused verification on the feature branch and merged `main`, then worktree cleanup.

- [ ] **Step 1: Request one whole-branch read-only code review**

Use the merge base and feature HEAD with `superpowers:requesting-code-review`. The reviewer must check:

- exact hard-zero epsilon parity between CPU and Metal;
- raw exponent preservation, especially exponent `0`;
- `.w` layout consistency across packing, renderer comments, encoder, and shader;
- no P2/P3/P4 scope expansion;
- focused tests prove parsing, packing, arithmetic, Metal compilation, and mounted-pipeline smoke behavior.

Fix all Critical and Important findings in one wave, with a failing test first for any behavioral fix. Record Minor findings without expanding scope unless they reveal a correctness issue.

- [ ] **Step 2: Run fresh feature-branch verification**

Run:

```bash
swift test --filter SceneForwardLightingTests
swift test --filter 'SceneForwardLightingRenderTests/testForwardLightShaderUsesPackedExponent'
swift test --filter 'SceneForwardLightingRenderTests/testSpatialPoolBrighterAtLight'
git diff --check <merge-base>..HEAD
git status --short
```

Expected: 11 core tests, one shader-contract test, and one rendered smoke test pass with zero failures; diff check is clean; feature worktree status is empty.

- [ ] **Step 3: Fast-forward merge into local `main`**

From the main checkout, verify that the only pre-existing worktree change is `.vscode/launch.json`, then run:

```bash
git merge --ff-only codex/we-2d-light-exponent
```

Expected: `main` advances to the feature HEAD without touching `.vscode/launch.json`.

- [ ] **Step 4: Re-run the same focused verification on merged `main`**

Run:

```bash
swift test --filter SceneForwardLightingTests
swift test --filter 'SceneForwardLightingRenderTests/testForwardLightShaderUsesPackedExponent'
swift test --filter 'SceneForwardLightingRenderTests/testSpatialPoolBrighterAtLight'
```

Expected: the same 13 focused tests pass with zero failures. Do not run the full suite or render corpus.

- [ ] **Step 5: Clean up the owned feature worktree and branch**

From the main checkout:

```bash
git worktree remove /Users/yakisoba/Documents/GitHub/Waple/.worktrees/we-2d-light-exponent
git worktree prune
git branch -d codex/we-2d-light-exponent
```

Expected: only the main worktree remains, `main` points at the feature HEAD, and `git status --short` still reports only the user-owned `.vscode/launch.json` modification.
