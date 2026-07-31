# H1: 2D/3D Material Custom Shader Path Design

Date: 2026-07-25
Status: Approved for Phase 1 (2D layers)

## 1. Problem

2D image layers and 3D meshes always render through fixed pipelines (`QuadShaders` / `Mesh3DShaders`). When a scene material JSON specifies a custom `shader` field (e.g. `genericimage2`, `genericimage4`, or a user shader), that field is ignored. Scenes such as `eagleflag`, `dna_fragment`, and `fantasticcar` therefore render with the wrong material.

The GLSL→MSL translation infrastructure (`GLSLTranslator`) already exists for **effects** (`SceneRendererResources.buildTranslatedEffect`). H1 extends that same infrastructure to **materials**.

## 2. Goal

- **Phase 1 (this spec):** implement the 2D layer material custom-shader path end-to-end: parse → model → pipeline build → encode → fallback.
- **Phase 2 (follow-up):** implement the 3D mesh material custom-shader path. Phase 2 is explicitly out of scope here.

Success criterion: a 2D layer whose material JSON has `passes[0].shader` renders with the translated custom shader instead of `QuadShaders.f_main`, while all existing scenes without a custom shader remain bit-identical.

## 3. Non-Goals

- 3D mesh custom shaders (`Mesh3DShaders` replacement)
- Particle / text-layer custom shaders
- `usershadervalues` runtime user-property binding (H2 — separate item)
- New blending modes beyond the existing `normal`/`additive` layer pipelines
- Shader hot-reload or runtime shader switching

## 4. Current State (verified 2026-07-25)

- `SceneDocument.parseLayer` reads material `passes[0]` but only extracts `blending`, `depthtest`, `depthwrite`, `combos`, `constantshadervalues` (only `roughness`/`metallic`/`speculartint`), and `usershadervalues` (same three keys). It does **not** read `shader` or generic constants/textures.
- `SceneLayer` has no field for a custom material shader.
- 2D layers always render via `QuadShaders` (`f_main`, `f_lit`, `f_blend`, `f_compose`, plus `nearest` variants).
- Effects already use `GLSLTranslator.translate(vertex:fragment:combos:include:)`, an `EngineU` uniform block, and an interleaved fullscreen quad (`effectQuadInterleaved`).
- `EngineU` layout (must stay in sync with `GLSLTranslator.assemble`):
  - `float4x4 mvp` (identity for effects)
  - `float4 timeAndPad` = (time, pointerUV.x, pointerUV.y, dt)
  - `float4 pointerLastAndPad` = (lastPointerUV.x, lastPointerUV.y, clickState, 0)
  - `float4 texRes[8]` = per-slot (paddedW, paddedH, imageW, imageH)
  - `float4 texWrap[2]` = 8 × (1=clamp / 0=repeat)
  - `float4 texFilter[2]` = 8 × (1=nearest / 0=linear)
  - `float4 layerTint` = (color.rgb × brightness, alpha) — **new for H1**; effects leave it as `(1,1,1,1)` so existing translated effects are unaffected.

## 5. Phase 1 Design — 2D Layer Custom Shader

### 5.1 Parsing (`SceneDocument.parseLayer`)

For image/model layers that load a material JSON (`materials/<name>.json` via `mj["material"]`), additionally parse from `passes[0]`:

| JSON field | Swift field on `SceneLayer` | Notes |
|---|---|---|
| `shader` | `materialShader: String?` | Shader base name, e.g. `genericimage2`. |
| `combos` | `materialCombos: [String: Int]` | Full combo map (not just SPRITESHEET/LIGHTING). |
| `constantshadervalues` | `materialConstants: [String: [Float]]` | All scalar/vector constants. |
| `constantshadervalues[*].script` | `materialConstantScripts: [String: String]` | Per-constant JS source. |
| `constantshadervalues[*].scriptproperties` | `materialConstantScriptProps: [String: String]` | Per-constant script properties JSON. |
| `textures` | `materialTextureNames: [String?]` | Texture slot names (slot 0 is the layer texture; others are aux). |

Existing fields (`blendMode`, `roughness`, `metallic`, `specularTint`, `materialScripts`, `materialScriptProps`) remain unchanged so the fixed-PBR path and fallback keep working.

### 5.2 Pipeline Build (`SceneRenderer.buildLayers`)

When `layer.materialShader != nil`:

1. Load shader sources from package/base-assets:
   - `shaders/<shader>.vert`
   - `shaders/<shader>.frag`
   - Missing source → log and fall back to `QuadShaders`.
2. Resolve combos with effect-path precedence:
   - Start with `materialCombos`.
   - Override with scene-pass combos (none for layers today; reserved).
   - Auto-enable sampler combos declared in the fragment source when a texture is bound to that slot (`GLSLTranslator.samplerCombos`).
3. Translate:
   - `GLSLTranslator.translate(vertex:frag:combos:include:)`
   - The `include` resolver uses the same package → base-assets → `BuiltinShaderIncludes` chain as effects.
4. Build an `MTLRenderPipelineState` using the translated `ev_main` / `ef_main` with the same color-attachment configuration as the layer’s effective blending mode:
   - `normal` → premultiplied-over (`src=one`, `dst=oneMinusSourceAlpha`)
   - `additive` → additive (`src=one`, `dst=one`)
5. Build material-constant buffer contents from `materialConstants` mapped through `TranslatedShader.materialParams` (same logic as `buildPassMaterial`).
6. Resolve aux textures from `materialTextureNames` (slots > 0) via `resolveTexture`, and compute `texRes`, `texWrap`, `texFilter` for each slot (same logic as `buildPassBindings`).
7. Cache the result on the layer as `GPULayer.customShader: CustomLayerShader?`.
   - Any failure (missing source, translate failure, pipeline compile failure) → `customShader = nil` → fallback to existing `QuadShaders` path. This is the no-regression contract.

### 5.3 GPU Data Structures

```swift
struct CustomLayerShader {
    let pipeline: MTLRenderPipelineState
    let material: [SIMD4<Float>]                 // materialParams slot values
    let aux: [(slot: Int, tex: MTLTexture)]     // material texture slots > 0
    let texRes: [SIMD4<Float>]                   // 8 slots; slot 0 = layer texture
    let texWrap: [Float]                         // 8 × 1=clamp / 0=repeat
    let texFilter: [Float]                       // 8 × 1=nearest / 0=linear
    var scripts: [(slot: Int, engine: TextScriptEngine)]  // constant scripts
}
```

Add to `GPULayer`:
- `var customShader: CustomLayerShader? = nil`

### 5.4 Encoding (`SceneRendererFrameEncoder.encodeLayer`)

Insert a new branch **before** the existing pipeline selection:

```swift
if let custom = layer.customShader {
    // 1. Compute layer transform matrix M such that
    //    NDC = M * float4(a_Position.xy, 0, 1)
    //    This replaces quadVertices() for this layer.
    // 2. Encode with custom.pipeline.
    // 3. Bind vertex buffer: effectQuadInterleaved (buffer 4).
    // 4. Bind EngineU (buffer 1) with mvp = M, time, pointer, texRes, texWrap, texFilter.
    // 5. Bind material constants (buffer 0) with per-frame script evaluation.
    // 6. Bind layer texture to g_Texture0 (texture 0).
    // 7. Bind aux textures to their declared slots.
    // 8. Draw triangleStrip (4 vertices).
    return
}
```

**Transform matrix M** must reproduce the existing `quadVertices` + `v_main` behavior:

```
alignedOrigin = alignedOrigin(origin, size, scale, angleZ, alignment)
M = aspectScale * translate(cameraOffset * parallaxDepth + shakeOffset)
    * ortho(projW, projH)          // pixel → NDC, Y-flip (same as sceneToNDC)
    * translate(alignedOrigin) * rotateZ(angleZ) * scale(size * scale * 0.5)
```

The rightmost `scale(size * scale * 0.5)` maps the unit quad (-1…1) to the layer rectangle in pixel space; `ortho(projW, projH)` then maps pixels to NDC.

The `EngineU` fields are populated as for effects, except:
- `mvp = M` instead of identity.
- `texRes[0]` = layer texture dimensions.
- `texWrap[0]` / `texFilter[0]` = layer texture clamp/nearest flags.

Material constant scripts are evaluated per frame with the same `TextScriptEngine` pattern used for effect constants (`buildPassMaterial` / `applyEffect`).

### 5.5 Alpha / Premultiplication

The existing accumulator is premultiplied. `QuadShaders.f_main` premultiplies once (`c.rgb * a`). Translated material shaders must follow the same contract.

`GLSLTranslator` will gain an optional `premultiplyOutput: Bool = false` parameter. When `true`, the generated fragment function wraps the translated `main` body with:

```metal
float4 c = <translated_main>();
c.rgb *= eng.layerTint.rgb;
c.a   *= eng.layerTint.a;
return float4(c.rgb * c.a, c.a);
```

`buildLayers` passes `premultiplyOutput: true` for layer materials and sets `eng.layerTint = (color.rgb × brightness, alpha)` each frame. Effects keep the default `(1,1,1,1)` so existing translated effects are bit-identical. This preserves the premultiplied accumulator invariant and restores the layer-tint behavior that `f_main` currently provides.

### 5.6 Fallback Rules

| Failure | Behavior |
|---|---|
| Material JSON missing | Existing behavior (no custom shader). |
| `shader` field absent | Existing behavior. |
| Shader source missing | Log once; use `QuadShaders`. |
| `GLSLTranslator.translate` returns nil | Log once; use `QuadShaders`. |
| Pipeline compile failure | Log once; use `QuadShaders`. |
| Aux texture missing | `resolveTexture` white-1×1 fallback (same as effects). |

No scene that renders today may change output.

## 6. Phase 2 Design — 3D Mesh Custom Shader (Deferred)

Phase 2 will follow the same pattern for `SceneRenderer3D.loadMesh3DMaterial`:

1. Parse `shader` from material `passes[0]`.
2. Attempt translation with `GLSLTranslator`.
3. Supply mesh-specific uniforms (`MeshU`, `FrameU`, `LightU`, bone matrices, shadow maps) via additional buffer indices.
4. Fall back to `Mesh3DShaders` on any failure.

Phase 2 requires its own spec because 3D shaders use different vertex inputs (position/normal/uv/bones), need skinning variants, and consume shadow/fog resources that 2D layers do not.

## 7. Testing

- **Unit tests (WapleCoreTests):**
  - `SceneDocumentTests`: verify `materialShader`, `materialCombos`, `materialConstants`, `materialTextureNames` parse correctly from a minimal material JSON.
  - `GLSLTranslatorTests`: verify `premultiplyOutput: true` wraps the fragment output.
- **Render tests (WapleRenderTests):**
  - Build a layer with a custom `genericimage2`-style shader and assert `GPULayer.customShader != nil`.
  - Force translate failure and assert fallback to `QuadShaders`.
- **Regression:**
  - All existing test suites (`WapleCoreTests`, `WapleRenderTests`, `WapleAppTests`, `WapleLibraryTests`, `WapleSnapshotTests`) must pass unchanged.
  - Manual verification on `eagleflag` and `dna_fragment` scenes to confirm visual fix.

## 8. Risks / Open Questions

| Risk | Mitigation |
|---|---|
| Custom shader expects straight-alpha output, breaking the premultiplied accumulator. | `premultiplyOutput: true` wrapper enforces the contract. |
| Layer tint (`color`/`alpha`/`brightness`) lost when custom shader replaces `f_main`. | `EngineU.layerTint` added; wrapper multiplies by it; effects default to white. |
| `EngineU` layout change breaks existing translated effects. | `layerTint` appended at the end; effects set it to `(1,1,1,1)`; all translation is rebuilt at mount. |
| Transform matrix M does not exactly match `quadVertices` for all alignment/rotation cases. | Unit-test matrix against `quadVertices` for representative layers. |
| Material shader uses uniforms not present in `EngineU`. | Document unsupported uniforms; shader falls back to `QuadShaders` if translation fails. |
| Performance: per-layer pipeline cache misses. | Pipelines are built once at mount; translation is memoized by `GLSLTranslator`. |
