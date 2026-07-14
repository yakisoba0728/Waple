# WE 3D PBR + Point Shadow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Waple's unlit 3D mesh/perspective-billboard path with source-backed point-light Cook–Torrance PBR and add source-backed six-face point shadows with 9-tap PCF.

**Architecture:** One shared per-frame 3D light pack feeds both meshes and lit billboards. Static/skinned vertices emit world position and world normal; a single PBR fragment path consumes constant material values. Point shadows are rendered before the camera pass into one 2×3 depth-atlas array slice per shadowed light and sampled by the same direct-light loop.

**Tech Stack:** Swift 5.9, SwiftPM, XCTest, Metal/Metal Shading Language, simd, WapleCore scene/model parsers.

## Global Constraints

- Work only on `codex/p3-p4-point-shadows` in `.worktrees/p3-p4-point-shadows`; never edit or stage the user's main-worktree `.vscode/launch.json`.
- Support only source-confirmed `lpoint`; skip spot, directional, tube, and unknown types instead of approximating them as point.
- Preserve scene order and use at most four valid point lights.
- Use mesh defaults roughness `0.7`, metallic `0`, specular tint `(1,1,1)` and do not clamp authored roughness at the upper bound.
- Use actual perspective `V = normalize(cameraEye - worldPosition)`, hemisphere ambient for meshes, and flat ambient for lit billboards.
- Use the native 2×3 face order `+X,-X,+Y,-Y,+Z,-Z`, viewport compensation `0.49`, and 9-tap PCF offsets `0.81616`/`1.02323`.
- Only opaque/alpha-cutout meshes with object `castShadow=true` cast; billboards receive but do not cast.
- Shadow allocation/pipeline failure must fall back to unshadowed PBR without dropping the frame.
- Do not run the full Swift suite or full/render corpus. Run only named affected tests and two small deterministic GPU tests.
- Perform one whole-change review only after Tasks 1 and 2 are complete.
- Commit messages must contain no AI watermark.

---

## File Map

- Create `Sources/WapleRender/Scene3DLighting.swift`: pure material parsing, point-light resolution/uniform packing, and point-shadow face/atlas math.
- Modify `Sources/WapleRender/Scene3DMath.swift`: inverse-transpose normal-matrix helper with finite/singular fallback.
- Modify `Sources/WapleRender/Mesh3DShaders.swift`: world-space static/skinned PBR shaders plus static/skinned opaque/cutout shadow functions.
- Modify `Sources/WapleRender/SceneRenderer3D.swift`: material fields, light/billboard data, shadow resource creation/pass, and PBR bindings.
- Modify `Sources/WapleRender/SceneRenderer.swift`: persistent 3D light/shadow/pipeline state and teardown.
- Create `Tests/WapleRenderTests/Scene3DLightingTests.swift`: pure material/light/normal/face/layout tests.
- Modify `Tests/WapleRenderTests/Mesh3DShadersTests.swift`: PBR/shadow function and pipeline compilation tests.
- Modify `Tests/WapleRenderTests/Scene3DRenderCorrectnessTests.swift`: material state and lit-billboard state tests.
- Create `Tests/WapleRenderTests/Scene3DPBRShadowRenderTests.swift`: tiny deterministic material-response and point occluder/receiver GPU renders.

---

### Task 1: Shared P3 world-space PBR path

**Files:**
- Create: `Sources/WapleRender/Scene3DLighting.swift`
- Modify: `Sources/WapleRender/Scene3DMath.swift`
- Modify: `Sources/WapleRender/Mesh3DShaders.swift`
- Modify: `Sources/WapleRender/SceneRenderer3D.swift`
- Modify: `Sources/WapleRender/SceneRenderer.swift`
- Create: `Tests/WapleRenderTests/Scene3DLightingTests.swift`
- Modify: `Tests/WapleRenderTests/Mesh3DShadersTests.swift`
- Modify: `Tests/WapleRenderTests/Scene3DRenderCorrectnessTests.swift`

**Interfaces:**
- Produces: `Scene3DMaterialValues.parse(_:)`, `Scene3DLighting.resolvePointLights(_:nodes:)`, `Scene3DMath.normalMatrix4x4(_:)`, `Scene3DFrameUniform`, `Scene3DLightUniform`, expanded `SceneRenderer.MeshUniform`, and PBR-capable `mv_main`/`mv_skin`/`mf_main`.
- Consumes: `SceneLight3D`, `Scene3DMath.Node`, P2a's native finite-light formula, current `SceneLayer` PBR fields, and existing node/skin/camera evaluation.

- [x] **Step 1: Add failing pure tests for materials, transforms, and point-light selection**

Create `Scene3DLightingTests.swift` with these concrete assertions:

```swift
func testMaterialDefaultsAndAuthoredValuesArePreserved() {
    XCTAssertEqual(Scene3DMaterialValues.parse(nil),
                   .init(roughness: 0.7, metallic: 0, specularTint: SIMD3(1, 1, 1)))
    let v = Scene3DMaterialValues.parse([
        "roughness": 5.0, "metallic": 0.25, "speculartint": "0.2 0.4 0.6"
    ])
    XCTAssertEqual(v.roughness, 5)
    XCTAssertEqual(v.metallic, 0.25)
    XCTAssertEqual(v.specularTint, SIMD3(0.2, 0.4, 0.6))
}

func testNormalMatrixHandlesNonUniformScaleAndSingularFallback() {
    let m = Scene3DMath.modelMatrix(origin: .zero, angles: .zero, scale: SIMD3(2, 1, 1))
    let n = simd_normalize((Scene3DMath.normalMatrix4x4(m) * SIMD4<Float>(1, 1, 0, 0)).xyz)
    XCTAssertEqual(n.x, 0.4472136, accuracy: 1e-5)
    XCTAssertEqual(n.y, 0.8944272, accuracy: 1e-5)
    let singular = Scene3DMath.modelMatrix(origin: .zero, angles: .zero, scale: SIMD3(0, 1, 1))
    XCTAssertTrue(Scene3DMath.normalMatrix4x4(singular).columns.0.x.isFinite)
}

func testPointLightsApplyParentTransformSkipUnknownAndLimitFour() {
    let nodes: [Int: Scene3DMath.Node] = [
        9: .init(origin: SIMD3(10, 0, 0), angles: SIMD3(0, .pi / 2, 0),
                 scale: SIMD3(1, 1, 1), parent: nil, visible: true)
    ]
    let lights = [
        light(type: "lspot", origin: .zero, parent: nil),
        light(type: "lpoint", origin: SIMD3(1, 0, 0), parent: 9),
        light(type: "lpoint", origin: SIMD3(2, 0, 0), parent: nil),
        light(type: "lpoint", origin: SIMD3(3, 0, 0), parent: nil),
        light(type: "lpoint", origin: SIMD3(4, 0, 0), parent: nil),
        light(type: "lpoint", origin: SIMD3(5, 0, 0), parent: nil),
    ]
    let r = Scene3DLighting.resolvePointLights(lights, nodes: nodes)
    XCTAssertEqual(r.count, 4)
    XCTAssertEqual(r[0].position.x, 10, accuracy: 1e-5)
    XCTAssertEqual(r[0].position.z, -1, accuracy: 1e-5)
    XCTAssertEqual(r.map(\.position.x), [10, 2, 3, 4])
}
```

- [x] **Step 2: Run the pure tests and confirm RED**

Run:

```bash
swift test --filter Scene3DLightingTests
```

Expected: compilation fails because `Scene3DMaterialValues`, `Scene3DLighting`, and `normalMatrix4x4` do not exist.

- [x] **Step 3: Implement the pure P3 data/math boundary**

Create these exact public-to-target interfaces in `Scene3DLighting.swift`:

```swift
struct Scene3DMaterialValues: Equatable {
    var roughness: Float = 0.7
    var metallic: Float = 0
    var specularTint = SIMD3<Float>(1, 1, 1)
    static func parse(_ constants: [String: Any]?) -> Self
}

struct Scene3DResolvedLight: Equatable {
    var position: SIMD3<Float>
    var exponent: Float
    var colorRadius: SIMD4<Float>
    var castsShadow: Bool
}

struct Scene3DFrameUniform {
    var cameraEye: SIMD4<Float>
    var ambient: SIMD4<Float>
    var skylight: SIMD4<Float>
    var meta: SIMD4<Float> // x=count, y/z=shadow texel, w=receiver bias
}

struct Scene3DLightUniform {
    var positionExponent: SIMD4<Float>
    var colorRadius: SIMD4<Float>
    var shadow: SIMD4<Float> // x=array slice (-1 disabled), y=matrix base
}

enum Scene3DLighting {
    static let maximumLights = 4
    static func resolvePointLights(_ lights: [SceneLight3D],
                                   nodes: [Int: Scene3DMath.Node]) -> [Scene3DResolvedLight]
}
```

`resolvePointLights` must filter case-insensitive `lpoint`, require finite positive radius, resolve
`parent` through `Scene3DMath.worldMatrix`, skip an invalid/invisible parent, transform the local
origin with `w=1`, multiply color by intensity, preserve input order, and stop at four.

Add `Scene3DMath.normalMatrix4x4(_:)`: extract the upper 3×3, return identity for non-finite or
`abs(determinant) <= 1e-8`, otherwise embed `transpose(inverse(m3))` in a 4×4 with zero translation.

- [x] **Step 4: Run the pure tests and confirm GREEN**

Run `swift test --filter Scene3DLightingTests`.

Expected: all material, normal-matrix, parent transform, filtering, and four-light assertions pass.

- [x] **Step 5: Add failing PBR shader/parser integration tests**

Extend `Mesh3DShadersTests` to require `mv_main`, `mv_skin`, and `mf_main`, require both static and
skinned PBR color/depth pipelines to compile, and assert the source exposes world-position,
world-normal, GGX, and perspective-view-vector transport. Extend
`Scene3DRenderCorrectnessTests` to load this material:

```json
{"passes":[{"textures":["white"],"constantshadervalues":{
  "roughness":5,"metallic":0.25,"speculartint":"0.2 0.4 0.6"
}}]}
```

Assert the resulting `Mesh3DMaterialInfo` keeps those exact values, and assert a `LIGHTING:1`
billboard keeps `lighting=true` plus its layer material values.

- [x] **Step 6: Run shader/parser tests and confirm RED**

Run:

```bash
swift test --filter 'Mesh3DShadersTests|Scene3DRenderCorrectnessTests'
```

Expected: failures for missing PBR transport/material fields and missing billboard lighting state.

- [x] **Step 7: Implement P3 shader and renderer integration**

Expand `MeshUniform`/MSL `MeshU` in the same order:

```swift
struct MeshUniform {
    var mvp: simd_float4x4
    var model: simd_float4x4
    var normalMatrix: simd_float4x4
    var tint: SIMD4<Float>
    var material: SIMD4<Float>      // roughness, metallic, alphaCutoff, mode(0 unlit/1 mesh/2 flat)
    var specularTint: SIMD4<Float>
}
```

Static and skinned vertices output `worldPos` and a normalized world normal. Skin normals with the
same normalized weights using each bone matrix with `w=0`, then apply `normalMatrix`. Set mesh mode
to `1`; set billboard mode to `2` only for `SceneLayer.lighting`, otherwise `0`, and generate its
normal as `normalize(cameraEye-center)`.

Mirror the native P2a BRDF in MSL: GGX `r²/r⁴`, Schlick geometry, Fresnel pow5,
`F0=mix(0.04,albedo,metallic)`, finite falloff with the hard-zero/FLT_MIN guard, denominator floor
`0.001`, and non-HDR `ambient+direct`. Use flat ambient for mode 2 and
`mix(skylight,ambient,dot(N,+Y)*0.5+0.5)` for mode 1. Keep premultiplied output.

Store `doc.lights3D`, ambient, and skylight in renderer state during `build3D`; resolve the shared
light pack after per-frame node evaluation; bind frame/lights to every mesh/billboard encoder,
including an encoder recreated after a framebuffer billboard. Parse mesh PBR constants through
`Scene3DMaterialValues.parse` and propagate them to `GPU3DMesh`.

- [x] **Step 8: Run P3 affected tests and commit**

Run:

```bash
swift test --filter 'Scene3DLightingTests|Mesh3DShadersTests|Scene3DRenderCorrectnessTests|Scene3DMathTests'
```

Expected: all selected tests pass. Then commit only Task 1 files:

```bash
git add Sources/WapleRender Tests/WapleRenderTests
git commit -m '기능(lighting): 3D PBR 경로 구현'
```

---

### Task 2: Integrated P4 point-shadow pass

**Files:**
- Modify: `Sources/WapleRender/Scene3DLighting.swift`
- Modify: `Sources/WapleRender/Mesh3DShaders.swift`
- Modify: `Sources/WapleRender/SceneRenderer3D.swift`
- Modify: `Sources/WapleRender/SceneRenderer.swift`
- Modify: `Tests/WapleRenderTests/Scene3DLightingTests.swift`
- Modify: `Tests/WapleRenderTests/Mesh3DShadersTests.swift`
- Create: `Tests/WapleRenderTests/Scene3DPBRShadowRenderTests.swift`

**Interfaces:**
- Consumes: Task 1's resolved-light order, frame/light uniforms, mesh material/caster state, world matrices, prepared bone buffers, and PBR direct-light loop.
- Produces: `PointShadowMath`, `PointShadowPipelines`, persistent 2×3 depth-array resource, pre-camera shadow encoding, and per-light PCF visibility.

- [x] **Step 1: Add failing point-face/layout and shadow-selection tests**

Add assertions:

```swift
func testPointShadowFaceAndAtlasCellsMatchNativeOrder() {
    XCTAssertEqual(PointShadowMath.faceIndex(SIMD3(2, 1, 1)), 0)   // +X
    XCTAssertEqual(PointShadowMath.faceIndex(SIMD3(-2, 1, 1)), 1)  // -X
    XCTAssertEqual(PointShadowMath.faceIndex(SIMD3(1, 2, 1)), 2)   // +Y
    XCTAssertEqual(PointShadowMath.faceIndex(SIMD3(1, -2, 1)), 3)  // -Y
    XCTAssertEqual(PointShadowMath.faceIndex(SIMD3(1, 1, 2)), 4)   // +Z
    XCTAssertEqual(PointShadowMath.faceIndex(SIMD3(1, 1, -2)), 5)  // -Z
    XCTAssertEqual((0..<6).map(PointShadowMath.atlasCell),
                   [SIMD2(0,0), SIMD2(1,0), SIMD2(0,1),
                    SIMD2(1,1), SIMD2(0,2), SIMD2(1,2)])
}

func testShadowSlicesAreDenseOnlyForCastingLights() {
    let resolved = [resolved(casts: true), resolved(casts: false), resolved(casts: true)]
    let packed = Scene3DLighting.packLights(resolved)
    XCTAssertEqual(packed.map(\.shadow.x), [0, -1, 1, -1])
    XCTAssertEqual(packed.map(\.shadow.y), [0, -1, 6, -1])
}
```

- [x] **Step 2: Run point-shadow tests and confirm RED**

Run `swift test --filter Scene3DLightingTests`.

Expected: compilation fails because `PointShadowMath` and `packLights` do not exist.

- [x] **Step 3: Implement point-shadow math and packing**

Add:

```swift
enum PointShadowMath {
    static let faceResolution = 512
    static let atlasColumns = 2
    static let atlasRows = 3
    static let nearZ: Float = 0.05
    static let viewportCompensation: Float = 0.49
    static func faceIndex(_ delta: SIMD3<Float>) -> Int
    static func atlasCell(_ face: Int) -> SIMD2<Int>
    static func faceViewProjections(position: SIMD3<Float>, radius: Float) -> [simd_float4x4]
}
```

Use face directions/up vectors `(+X,-Y)`, `(-X,-Y)`, `(+Y,+Z)`, `(-Y,-Z)`, `(+Z,-Y)`,
`(-Z,-Y)` with `Scene3DMath.lookAt`, 90-degree aspect-1 projection, near
`min(0.05, radius*0.01)` bounded above by `radius*0.5`, and far `radius`.

`packLights` preserves the resolved order, fills four entries, gives dense shadow slices only to
`castsShadow`, and sets matrix base to `slice*6`.

- [x] **Step 4: Run point-shadow math tests and confirm GREEN**

Run `swift test --filter Scene3DLightingTests` and expect all selected tests to pass.

- [x] **Step 5: Add failing shadow pipeline and deterministic render tests**

Extend `Mesh3DShadersTests` to require `sv_main`, `sv_skin`, and `sf_cutout`, then require
depth-only static/skinned pipelines and alpha-cutout static/skinned pipelines to compile
against a `.depth32Float` attachment with no color attachment. Add two 32×32 GPU tests:

1. render a white +Z-facing receiver with point light/camera on +Z and assert metallic/roughness
   changes alter the center RGB while alpha remains opaque;
2. render one depth occluder into the +Z cell, render a receiver behind it, and assert the shadowed
   center luminance is lower than the same draw with `shadow.x=-1`.

Both tests use only generated buffers/textures and one command buffer; no package/render corpus.

- [x] **Step 6: Run pipeline/render tests and confirm RED**

Run:

```bash
swift test --filter 'Mesh3DShadersTests|Scene3DPBRShadowRenderTests'
```

Expected: missing shadow pipeline/resource functions or unshadowed output causes failure.

- [x] **Step 7: Implement the point shadow resource, caster pass, and 9-tap receiver sampling**

Add renderer state for opaque/cutout static/skinned shadow pipelines, the depth array texture,
current slice count, and 24 VP matrices. Create `.type2DArray`, `.depth32Float`, private,
`[.renderTarget,.shaderRead]`, width `1024`, height `1536`, array length `1...4`.

Before the camera pass, prepare each skinned model's bone buffer once. For each shadowed light,
open one depth encoder on its array slice, clear once, set six 512×512 viewports matching the 2×3
cells, and draw only visible `castShadow` opaque/cutout meshes. Reuse current cull mode and texture;
use `sv_main`/`sv_skin` and `sf_cutout` only when alpha cutoff is active.

In `mf_main`, select the face by dominant axis, project with `shadowVP[base+face]`, transform NDC xy
with `float2(0.49,-0.49)+0.5`, scale/offset into the 2×3 cell, and take nine compare samples at the
exact `0.81616`/`1.02323` offsets. Constrain sample UVs to the selected cell. Multiply only the
current point light's direct Cook–Torrance contribution by visibility. Use named raster/receiver
bias constants and label them Waple stability policy.

If resource/pipeline creation fails, set all packed shadow slices to `-1` and continue the camera
pass. Clear every new resource/state in `teardown()`.

- [x] **Step 8: Run P3/P4 affected tests and commit**

Run:

```bash
swift test --filter 'Scene3DLightingTests|Mesh3DShadersTests|Scene3DPBRShadowRenderTests|Scene3DRenderCorrectnessTests|Scene3DMathTests'
```

Expected: all selected tests pass. Then commit:

```bash
git add Sources/WapleRender Tests/WapleRenderTests
git commit -m '기능(lighting): point shadow map 및 PCF 구현'
```

---

### Task 3: One final review, focused verification, documentation, and local merge

**Files:**
- Modify: `docs/superpowers/specs/2026-07-14-we-3d-pbr-point-shadows-design.md` only if implementation evidence requires a factual correction.
- Modify: `docs/superpowers/plans/2026-07-14-we-3d-pbr-point-shadows.md` checkbox state.

**Interfaces:**
- Consumes: complete Task 1+2 branch diff and focused test evidence.
- Produces: one reviewed/verified branch merged locally into `main` without touching `.vscode/launch.json`.

- [x] **Step 1: Perform the single whole-branch review**

Review `git diff $(git merge-base main HEAD)..HEAD` for spec coverage, CPU/MSL layout equality,
static/skinned parity, encoder rebinds, shadow-slice/matrix indexing, face/view consistency,
failure fallback, teardown, and scope exclusion. Fix every Critical/Important finding in one wave,
then rerun only the covering focused tests.

- [x] **Step 2: Run final focused verification**

Run exactly:

```bash
swift test --filter 'Scene3DLightingTests|Mesh3DShadersTests|Scene3DPBRShadowRenderTests|Scene3DRenderCorrectnessTests|Scene3DMathTests'
git diff --check
git status --short --branch
```

Expected: selected tests pass, diff check is clean, and only intended branch files are present.
Do not run the full suite or full/render corpus.

- [ ] **Step 3: Commit any review/plan bookkeeping and merge locally**

If the review created changes, commit them with a factual Korean message. Then from the main
worktree verify `.vscode/launch.json` remains the only pre-existing change and merge:

```bash
git merge --no-ff codex/p3-p4-point-shadows
```

Run the same focused test filter once on `main`, verify `.vscode/launch.json` is still unstaged and
unchanged by this branch, remove the feature worktree, and delete the merged feature branch.
