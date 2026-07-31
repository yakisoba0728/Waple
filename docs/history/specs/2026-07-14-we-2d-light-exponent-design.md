# WE 2D Light Exponent Design

## Context

Waple already parses each scene light's finite `exponent` into `SceneLight3D.exponent`, with an existing missing/invalid fallback of `1`. The 2D forward-lighting path drops that value: `forwardUniforms` writes a constant `1` into `positions[i].w`, and both the CPU oracle and `QuadShaders.f_lit` use a fixed `attn²` falloff.

The Wallpaper Engine `genericimage4` finite-light path instead computes a linear radius falloff and raises it to the authored exponent. The local exact-lighting report selects the GLSL-equivalent hard-zero form for the Metal port:

```text
falloff = saturate(1 - distance / radius)
attenuation = falloff >= 6.103515625e-5
    ? pow(falloff + 6.103515625e-5, exponent)
    : 0
```

The hard-zero branch prevents `0^0` from lighting pixels outside the radius. The exponent itself remains raw: the local corpus contains `exponent == 0`, which intentionally yields attenuation `1` inside the radius and `0` outside it.

## Goal

Carry the already-parsed per-light exponent into Waple's existing four-slot 2D forward-lighting payload and use it in both the CPU oracle and Metal fragment shader, without implementing PBR, light-type branches, shadows, or 3D lighting.

## Constraints

- Preserve the existing parser and its fallback `exponent = 1`; the WE editor's missing-field default is not locally proven and all observed corpus lights serialize the field.
- Preserve raw finite exponent values. Do not clamp negative, zero, or large values in this task.
- Preserve the current `radius <= 0` and `distance < 1e-5` contribution guards.
- Preserve the existing first-four, scene-order light selection and the current approximation that all 2D lights use the finite point-light lane. Directional/spot/tube specialization belongs to P2.
- Do not add Cook–Torrance, roughness/metallic, normal maps, cookies, or shadow maps.
- Run only focused forward-lighting tests; do not run the full Swift suite or render corpus.
- Perform one whole-change code review after implementation, not per-step reviews.
- Preserve the user-owned `.vscode/launch.json` modification and never stage it.

## Approaches Considered

### A. Reuse `positions[i].w` for exponent — selected

The shader consumes only `lightPos[i].xyz`; slot activity is already determined by `colorRadius[i].w > 0`. Packing the exponent in the unused position component adds no renderer property, fragment buffer, binding index, or pipeline-layout change. Unused slots remain all-zero and continue to be skipped by their zero radius.

This is also compatible with the native point-light convention that stores exponent alongside origin, while remaining an internal Waple layout rather than claiming type-specific native packing.

### B. Add a dedicated four-value exponent buffer

This makes the value explicit and keeps the old, unused active marker, but adds renderer state, a sixth fragment buffer, encoder wiring, and another layout that P2 will later replace. It provides no behavioral advantage in the current four-slot renderer.

### C. Keep fixed quadratic falloff or add a compatibility flag

This preserves old visuals for missing exponent fields but continues to ignore authored data or introduces a configuration surface with no corpus need. The existing parser already defines the fallback contract, so a compatibility flag is unnecessary.

## Data Flow

1. `SceneDocument.parseLight` continues to populate `SceneLight3D.exponent` unchanged.
2. `SceneLight3D.forwardUniforms` writes `(origin.x, origin.y, origin.z, exponent)` into `positions[i]`.
3. `SceneRenderer` and `SceneRendererFrameEncoder` continue copying and binding the same four `SIMD4<Float>` position entries at fragment buffer `2`; only the `.w` meaning changes.
4. `QuadShaders.f_lit` reads `lightPos[i].w` and applies the hard-zero finite-light falloff once.
5. `SceneLight3D.evaluateLighting` mirrors the exact same attenuation rule so unit tests remain a trustworthy shader oracle.

## Numerical and Error Behavior

- `radius <= 0`: contribution remains zero before division.
- `distance < 1e-5`: contribution remains zero because the current flat-normal path cannot form a stable light direction.
- `falloff < 6.103515625e-5`: attenuation is exactly zero.
- `exponent == 0`: attenuation is exactly one for pixels inside the radius.
- Negative exponent: preserved as authored; it may produce large values near the boundary. Changing that policy requires separate evidence and tests.
- Missing, nonnumeric, nonfinite, or Float-out-of-range exponent: existing parser behavior remains fallback `1`.

## Tests

### Core packing and oracle

`SceneForwardLightingTests` will prove:

- an explicit parsed exponent reaches `ForwardUniforms.positions[0].w`;
- exponent `3` at `distance/radius = 0.5` produces approximately `0.125` rather than the old fixed `0.25`;
- existing quadratic hand-computation fixtures explicitly request exponent `2`, preserving their established numeric oracles;
- unused slots and radius guards remain unchanged.

### Metal shader contract

`SceneForwardLightingRenderTests` will add one fast source/compile test that:

- confirms `f_lit` calls the finite falloff helper with `lightPos[i].w`;
- confirms the fixed `ndl * attn * attn` expression is gone;
- compiles `QuadShaders.source` and resolves `f_lit` on the available Metal device.

Final verification runs `SceneForwardLightingTests` plus only the new shader-contract test. One existing rendered-light smoke test is run after the merge to ensure the mounted pipeline still executes. No full suite or real render corpus is run.

## Scope Boundary

This completes lighting P1 together with the already-merged flat ambient correction. It does not make `f_lit` a full `genericimage4` implementation; P2 remains responsible for Cook–Torrance and light-type behavior, P3 for 3D lighting, and P4 for shadows.
