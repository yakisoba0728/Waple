# WE 2D Point-Light PBR (P2a) Design

## Context

Waple's 2D `LIGHTING:1` path now matches Wallpaper Engine's `genericimage4` flat ambient and GLSL finite-light exponent attenuation, but the direct-light term is still Lambert-only. The native `genericimage4` path instead calls `PerformLighting_V1`, whose finite point-light implementation uses the Cook–Torrance BRDF from `common_pbr_2.h`.

The native material defaults and BRDF constants are source-confirmed:

- `roughness = 0.7`
- `metallic = 0`
- `specularTint = (1, 1, 1)`
- GGX distribution with `alpha = roughness²`
- Smith-Schlick geometry with `k = (roughness + 1)² / 8`
- Fresnel-Schlick with `F0 = mix(0.04, albedo, metallic)` and `pow(max(1 - cosTheta, 0.001), 5)`
- `kD = (1 - metallic) * (1 - F)` and Lambert diffuse `kD * albedo / pi`

The similarly documented `ComputeMaterialSpecularPower` and `ComputeMaterialSpecularStrength` functions belong to the legacy `generic`/`generic2` Blinn–Phong path. They do not modify `genericimage4` and are intentionally excluded.

## Goal

Replace the finite point-light Lambert term in the reachable orthographic 2D `f_lit` path with the exact `genericimage4` Cook–Torrance BRDF, while adding scalar material parameters and preserving the completed P1 attenuation behavior.

This slice is P2a. It deliberately does not claim full P2 light-type parity.

## Scope

### Included

- `genericimage4`-style Cook–Torrance direct lighting for the current finite point-light lane.
- Per-layer parsing and transport of `roughness`, `metallic`, and `speculartint` from `passes[0].constantshadervalues`.
- Native defaults `0.7`, `0`, and white when constants are absent or invalid.
- Raw finite material values without authoring-range clamps. The corpus contains `roughness = 5`.
- Orthographic view vector `V = (0, 0, 1)` and the existing flat layer normal `N = (0, 0, 1)`.
- Existing `color * intensity` radiance production, first-four scene-order selection, radius/distance guards, and GLSL hard-zero exponent attenuation.
- One explicit numerical-safety deviation for the GGX distribution denominator.

### Excluded

- Spot and directional specialization. Their native GPU calls are known, but JSON `angles` to normalized direction axis/sign and cone half-angle conversion are not source-confirmed.
- Tube lights. The 168-scene corpus contains zero tube lights and exposes no endpoint JSON schema.
- Perspective image lighting. `f_lit` is reachable only when `camera3D == nil`; perspective images use the separate unlit 3D billboard path and belong with P3.
- Normal maps, PBR component masks, emissive maps, reflection/SSR, cookies, rim/gradient/double-sided variants, and shadows.
- Native HDR `CombineLighting` overbright behavior and the separate global tone-map policy.
- Light parent transforms, animated light properties, and relevance-based light selection.

## Approaches Considered

### A. Exact point-light PBR only — selected

Add the confirmed BRDF and material data while leaving every light in the current finite point lane. This replaces a known wrong Lambert term without inventing direction or tube serialization rules. It is the smallest change that produces a source-backed fidelity improvement.

### B. Add spot and directional branches using inferred Euler directions

The shader-side formulas are known, but CPU production is not: local `-Z` versus another forward axis, parent transform composition, direction sign, and `cos(angle)` versus `cos(angle / 2)` remain unresolved. Implementing this now would make synthetic tests validate Waple's guess rather than Wallpaper Engine behavior.

### C. Combine P2 with perspective billboards and 3D PBR

This would make the view-vector branch reachable, but requires changes to `SceneRenderer3D`, `Mesh3DShaders`, world normals, camera uniforms, and the 3D material path. It is P3-sized and would materially increase regression and verification cost.

## Data Model and Parsing

`SceneLayer` gains three authored material fields with defaults:

```swift
public var roughness: Float = 0.7
public var metallic: Float = 0
public var specularTint: Vec3 = Vec3(x: 1, y: 1, z: 1)
```

`SceneDocument.parseLayer` reads the first material pass's `constantshadervalues` using the existing numeric/vector unwrapping helpers. Values remain raw and finite. Missing, nonnumeric, nonfinite, or Float-out-of-range values use the native defaults.

No PBR texture slots are added in P2a. `textures[1]` and `textures[2]` remain outside the current image-resource path.

## Renderer Transport

`GPULayer` stores a fixed 32-byte material payload matching two Metal `float4` values:

```text
scalar = (roughness, metallic, 0, 0)
specularTint = (r, g, b, 0)
```

The encoder binds this payload only for `layer.isLit` at fragment buffer `5`. Buffers `0...4` retain their current tint, rect, point/exponent, color/radius, and ambient meanings.

No scene-global light layout changes are needed for P2a.

## BRDF and Composition

For each active finite point light:

```text
Lraw = lightPosition - worldPosition
distance = length(Lraw)
L = Lraw / distance
H = normalize(V + L)

r2 = roughness²
r4 = r2²
NH = max(dot(N, H), 0)
ggxDenominator = max(NH² * (r4 - 1) + 1, 1e-4)
D = r4 / (pi * ggxDenominator²)

k = (roughness + 1)² / 8
SchlickGGX(x) = x / (x * (1 - k) + k)
G = SchlickGGX(max(dot(N, V), 0.001))
  * SchlickGGX(max(dot(N, L), 0.001))

F0 = mix(0.04, albedo, metallic)
F = F0 + (1 - F0) * pow(max(1 - dot(H, V), 0.001), 5)
kD = (1 - metallic) * (1 - F)

NL = max(dot(N, L), 0)
if NL == 0: contribution = 0
specular = (D * G * F) / max(4 * max(dot(N, V), 0) * NL, 0.001)
radiance = lightColor * finiteLightFalloff(distance, radius, exponent)
direct += (kD * albedo / pi + specular * specularTint) * radiance * NL
```

The final 2D non-HDR composition is:

```text
albedo = sampledTexture.rgb * tint.rgb
lit = ambientColor * albedo + direct
alpha = sampledTexture.a * tint.a
output = (lit * alpha, alpha)
```

Direct PBR already contains albedo in its diffuse term. The old `albedo * accumulatedLight` expression must not be reused or albedo will be multiplied twice. The renderer's single final premultiplication remains unchanged.

### GGX zero-roughness safety deviation

The native distribution has no denominator floor. At exactly `roughness = 0` and `NH = 1`, it evaluates `0 / 0`. P2a preserves the authored roughness value and floors only the intermediate GGX denominator to `1e-4` in both the Swift oracle and Metal helper. This makes the singular contribution zero while leaving values such as corpus-observed `roughness = 5` unclamped.

The deviation is documented as `[safety deviation]`; it must not be described as bit-exact native behavior.

The implementation also returns zero before constructing the half vector when `NL == 0`. In the selected non-gradient, single-sided path the final multiplier is already zero, so this preserves the defined result while preventing `normalize(V + L)` from producing NaN for an exactly back-facing light.

## Preserved P1 Behavior

- `radius <= 0` contributes zero before division.
- `distance < 1e-5` contributes zero before normalizing.
- `falloff < 6.103515625e-5` is hard-zero.
- `exponent == 0` remains one inside the radius and zero outside.
- Raw exponent values remain unclamped.
- Missing light slots remain inactive through zero radius.
- All light types continue through the existing finite point approximation until P2b.

## Tests

### Core

Focused `SceneForwardLightingTests` will prove:

- material constants parse from the first pass and missing constants use `0.7 / 0 / white`;
- roughness values above one are preserved;
- a hand-computed dielectric point-light case matches the Cook–Torrance result and differs from the old Lambert value;
- metallic changes F0 and the resulting color;
- `roughness = 0`, `N = H` returns finite values through the denominator-only guard;
- P1 exponent-zero, hard-zero, zero-radius, and first-four behavior remains covered.

Every production behavior is introduced test-first and its RED failure must be observed before implementation.

### Metal and mounted pipeline

Focused render tests will prove:

- the source contains the GGX, Smith, Fresnel, and material-buffer path, no longer performs the old Lambert accumulation, compiles, and resolves `f_lit`;
- two otherwise identical materials with metallic `0` and `1` produce different center pixels at a nonsaturating light intensity;
- the existing spatial point-light smoke test remains valid.

No full Swift suite or real render corpus will run. Implementation receives one whole-branch review after all code is complete, followed by the same focused verification on the feature branch and merged `main`.

## Completion Boundary

P2a is complete when the reachable orthographic point-light path consumes authored scalar PBR material values and uses the source-backed Cook–Torrance term with the documented zero-roughness safety deviation.

P2b remains blocked on native CPU-side direction/cone evidence. P3 remains responsible for perspective billboards and 3D mesh lighting; P4 remains responsible for shadow maps.
