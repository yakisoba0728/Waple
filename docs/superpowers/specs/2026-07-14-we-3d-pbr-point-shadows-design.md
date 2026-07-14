# WE 3D PBR + Point Shadow (P3/P4) Design

**Date:** 2026-07-14  
**Status:** Approved scope, implementation pending  
**Branch:** `codex/p3-p4-point-shadows`

## 1. Goal

Waple의 3D 경로를 현재 `texture × tint` unlit 출력에서 Wallpaper Engine의
`generic4` 계열과 같은 Cook–Torrance PBR 경로로 전환하고, 근거가 확정된 point light에
대해 6면 shadow map과 9-tap PCF를 함께 이식한다.

이번 작업은 P3와 P4를 별도 마이크로 단계로 나누지 않는다. 하나의 런타임 데이터 흐름과
하나의 기능 브랜치에서 구현하고, 전체 구현 후 한 번만 최종 리뷰한다.

## 2. Scope

### Included

- 3D static/skinned mesh PBR lighting
- perspective billboard PBR lighting when the layer enables lighting
- world position and inverse-transpose world normal transport
- skinned normal transport using the same normalized bone weights as position
- perspective view vector `normalize(cameraEye - worldPosition)`
- `roughness`, `metallic`, and `specularTint` scalar/vector material values
- mesh defaults: roughness `0.7`, metallic `0`, specular tint `(1,1,1)`
- flat ambient for image billboards and hemisphere ambient for 3D meshes
- first four valid `lpoint` lights in scene order
- parent-node transforms for point-light world positions
- finite-light attenuation and Cook–Torrance core already established by P2a
- point-light shadows for `castShadow=true`
- six shadow faces in the native 2×3 point-cube layout
- native 1-tap/9-tap PCF structure, using 9 taps for the normal quality path
- static and skinned mesh shadow casters
- opaque and alpha-cutout casters; billboards receive shadows but do not cast them
- graceful fallback to unshadowed PBR if shadow resources cannot be created

### Excluded

- spot and directional lighting/shadows: JSON `angles` to forward-axis/sign and spot cone
  conversion are not yet source-confirmed
- tube lights: endpoint schema is absent
- normal maps and PBR-mask textures: this pass uses confirmed constant material values
- billboard shadow casting: no source `castShadow` property exists for image layers
- additive/translucent mesh casting: native caster semantics are not confirmed
- 3D HDR/tone-map policy, cookies, SSR, fog, and MSAA alpha-to-coverage
- full Swift test suite and full/render corpus

Unknown light types are skipped. They are never silently treated as point lights.

## 3. Evidence Boundary

The native shader sources confirm:

- GGX distribution with `alpha = roughness²`
- Schlick-GGX geometry with `k = (roughness + 1)² / 8`
- Fresnel-Schlick and `F0 = mix(0.04, albedo, metallic)`
- finite attenuation `pow(saturate(1 - distance/radius) + FLT_MIN, exponent)`
- direct term multiplied by the per-light shadow factor
- 3D hemisphere ambient and image flat ambient
- point light cube-face projection and a 2×3 unwrapped layout
- one-tap or nine-tap shadow comparison filtering

The sources do not establish the CPU serialization rules needed to build correct spot or
directional light directions. Those paths remain deferred rather than inferred.

## 4. Runtime Design

### 4.1 Shared 3D frame data

`SceneRenderer3D` builds one per-frame light pack after evaluating node scripts:

- transform each supported point origin by its parent node's current world matrix
- preserve scene order and keep at most four valid point lights
- pack world position plus exponent, color × intensity plus radius, and shadow metadata
- pack camera eye, ambient, skylight, and active-light count once

The same pack is bound for mesh and billboard draws, including after framebuffer billboards
split and recreate the Metal command encoder.

### 4.2 Material and vertex transport

The mesh uniform carries model/view-projection data, a normal matrix, material values, and
existing alpha-cutoff/tint values. Static vertices output world position and transformed world
normal. Skinned vertices first blend both position and normal using the existing bone indices and
normalized weights, then apply the object world/normal transform.

Billboard vertices already exist in world space. Their receiver normal points from the billboard
toward the camera (`normalize(cameraEye - center)`), independent of the generated triangle winding,
and their material values come from `SceneLayer`. Only billboards
whose source layer enables lighting use the PBR fragment path; all others retain the current unlit
output.

### 4.3 Lighting

The Metal implementation mirrors the established P2a CPU oracle and native source layout instead
of introducing a second approximation:

1. sample albedo and apply tint/alpha cutoff;
2. normalize `N`, compute `V = normalize(eye - worldPosition)`;
3. compute ambient (hemisphere for meshes, flat for billboards);
4. accumulate each finite point-light Cook–Torrance contribution;
5. multiply only the direct contribution by that light's shadow visibility;
6. combine ambient and direct light, then emit premultiplied alpha.

The GGX denominator receives only a small lower guard to prevent the `roughness=0`, `N·H=1`
`0/0` corner. Authored roughness is otherwise not upper-clamped.

## 5. Point Shadow Design

### 5.1 Resource and layout

Use a persistent private depth texture array with one slice per shadowed point light. Each slice is
a complete 2×3 face atlas, so the native point-cube UV layout remains intact while different lights
cannot bleed into each other. Each face has a fixed resolution; the slice dimensions are therefore
`2 × faceResolution` by `3 × faceResolution`.

The texture uses `.depth32Float` and `[.renderTarget, .shaderRead]`. At most four slices are needed.
It is independent of drawable size and is recreated only when the required slice count changes.

### 5.2 Pass order

Per frame:

1. evaluate scripts and construct current world transforms;
2. resolve active point lights;
3. prepare each skinned model's bone matrices once;
4. render six depth viewports for every shadowed point light into its 2×3 slice;
5. render the existing camera color/depth pass while sampling the shadow texture.

Each face uses a 90-degree projection with the light radius as far distance. The near plane and
depth bias are named Waple stability-policy values because their native CPU constants are not
source-confirmed. Static/skinned opaque
and alpha-cutout meshes with object `castShadow=true` are rendered. Existing visibility, world
transform, culling, texture, and alpha-cutoff behavior is preserved.

### 5.3 Sampling and bias

The receiver selects the cube face by the dominant light-to-fragment axis and maps it to the native
2×3 cell. Nine comparison samples use the native PCF offset structure (`0.81616` and `1.02323`
kernel offsets). Sampling is constrained to
the selected cell so a kernel cannot cross into another cube face.

Native sources do not establish Waple's required Metal depth bias constants. Raster and receiver
biases are therefore named Waple anti-acne policy constants, kept minimal, and covered by focused
synthetic rendering. They are not documented as WE-exact values.

## 6. Failure and Compatibility

- A missing/invalid material texture retains the existing white fallback.
- A singular/non-finite normal transform falls back to a safe normalized geometric normal path.
- Lights with non-positive radius or invalid transforms are skipped.
- A failed shadow allocation/pipeline disables shadows for the frame but retains PBR lighting.
- Existing unlit behavior remains for billboards without the lighting flag.
- Existing blend, depth-test/write, cull, alpha-cutout, animation, and framebuffer-billboard behavior
  remains in force.

## 7. Verification

No full suite or full render corpus will be run. Focused verification covers:

- normal matrix, point-face selection, 2×3 mapping, parented light position, and shadow selection
  unit tests
- material parsing defaults/overrides
- Metal compilation for static/skinned PBR and opaque/cutout shadow pipelines
- one small deterministic PBR material-response render
- one small occluder/receiver point-shadow render
- existing affected 3D math/render-correctness tests
- one final whole-diff review after all implementation is complete

## 8. Delivery

Implementation, focused verification, and the single final review stay on this branch. After they
pass, the branch is merged locally into `main`. The user-owned `.vscode/launch.json` change in the
main worktree is not touched or staged.
