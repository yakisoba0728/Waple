import Foundation
import simd

/// `genericimage4` / `common_pbr_2.h`의 Cook-Torrance 코어를 Metal `f_lit`과 같은 순서로 미러한다.
///
/// ## "WE 의 라이팅 모델이 뭐냐" 에 대한 확정 답 (2026-08-21 자산 원문 대조)
/// **Cook-Torrance GGX 다. half-Lambert 도 Blinn-Phong 도 아니다** — 다만 그 둘도 **다른 레인에**
/// 실제로 존재한다. 답은 x86 이 아니라 셰이더 자산에 평문으로 있다:
/// - **D (법선분포)**: `Distribution_GGX`(`common_pbr_2.h:18-25`) — `α = roughness²`,
///   `α² / (π · ((N·H)²(α²−1)+1)²)`. 분모 하한 **없음**(우리는 `ggxDenominatorFloor` 를 더했다).
/// - **G (기하)**: `Schlick_GGX`(`:27-32`) `k = (roughness+1)² / 8` · `GeoSmith`(`:34-37`)가
///   `N·V`/`N·L` 을 각각 **`max(·, 0.001)`** 로 바닥 친 뒤 곱한다.
/// - **F (프레넬)**: `FresnelSchlick`(`:4-7`) `F0 + (1−F0)·pow(max(1−cosθ, 0.001), 5.0)`.
///   지수는 리터럴 **5.0**, 밑의 하한은 **0.001**. `F0 = mix(vec3(0.04), albedo, metallic)`
///   (`genericimage4.frag:136-137` — 유전체 기본반사율 0.04 고정).
/// - **스페큘러 항은 있다**: `numerator / max(4·max(N·V,0)·NL, 0.001)` 뒤 **`specularTint` 를 곱한다**
///   (`common_pbr_2.h:298-313`, 유니폼 `g_SpecularTint` — `genericimage4.frag:139`).
///   분모 하한 리터럴 **0.001**.
/// - **디퓨즈는 Lambert**: `(1−metallic)·(1−F)·albedo / π`(`:277`,`:313`). half-Lambert 아님.
/// - **radiance**: `lightColor · pow(saturate(1 − d/radius) + ε, exponent)`(`:263-270`) —
///   역제곱이 아니다. ε 은 HLSL 레인 `1.17549435e-38`, GLSL 레인 `6.103515625e-5`+하드제로.
/// - **N·L**: `max(dot(N,L)·shadowFactor, 0)`(`:301`). `#if DOUBLESIDEDLIGHTING` 이면 `abs`(`:281`).
///
/// **half-Lambert 가 나오는 자리는 둘, 둘 다 이 경로가 아니다.**
/// 1. `#ifdef GRADIENT_SAMPLER`(툰 셰이딩 콤보 `SHADINGGRADIENT`, `generic4.frag:6`)일 때만
///    `NL = max(min(shadowFactor, N·L)·0.5 + 0.5, 0)` 을 **그라디언트 텍스처 룩업의 U 좌표**로
///    쓴다(`common_pbr_2.h:284-290`) — 조명항 자체가 half-Lambert 로 바뀌는 게 아니라 램프 LUT 다.
/// 2. 비-PBR 레거시 레인 `common_fragment.h:68-81` `ComputeLightSpecular` 는 진짜
///    half-Lambert 블렌드(`mix(N·L, N·L·0.5+0.5, halfLambert)`) + Blinn 스페큘러
///    (`pow(max(0,dot(normalize(V+L),N)), specularPower)`)다. 상수도 거기 있다:
///    `ComputeMaterialSpecularPower = (1.01 − roughness)·mix(400, 250, metallic)`(`:51-54`),
///    `ComputeMaterialSpecularStrength = (0.5 + metallic·0.5)·(1 − roughness·0.9)`(`:56-59`),
///    감쇠 `saturate((radius − d)/radius)²`(`:64-65`,`:80`). **우리는 이 레인을 이식하지 않았다.**
/// 3. 그리고 `RIMLIGHTING` 콤보의 림 항(`:303-308`)이 `NL` 을 아래에서 밀어 올린다 —
///    `SceneWELightMath.rimTerm` 이 그 수식을 갖고 있다.
enum ScenePBRMath {
    /// [safety deviation] Native GGX has no floor and produces 0/0 at roughness=0, N·H=1.
    static let ggxDenominatorFloor: Float = 1e-4

    static func distributionGGX(normal: SIMD3<Float>, halfVector: SIMD3<Float>,
                                roughness: Float) -> Float {
        let r2 = roughness * roughness
        let r4 = r2 * r2
        let nh = max(simd_dot(normal, halfVector), 0)
        let rawDenominator = nh * nh * (r4 - 1) + 1
        let denominator = max(rawDenominator, ggxDenominatorFloor)
        return r4 / (Float.pi * denominator * denominator)
    }

    static func schlickGGX(_ nd: Float, roughness: Float) -> Float {
        let r = roughness + 1
        let k = r * r / 8
        return nd / (nd * (1 - k) + k)
    }

    static func geometry(normal: SIMD3<Float>, view: SIMD3<Float>, light: SIMD3<Float>,
                         roughness: Float) -> Float {
        let nv = max(simd_dot(normal, view), 0.001)
        let nl = max(simd_dot(normal, light), 0.001)
        return schlickGGX(nv, roughness: roughness)
            * schlickGGX(nl, roughness: roughness)
    }

    static func fresnel(cosTheta: Float, f0: SIMD3<Float>) -> SIMD3<Float> {
        let factor = powf(max(1 - cosTheta, 0.001), 5)
        return f0 + (SIMD3<Float>(repeating: 1) - f0) * factor
    }

    static func pointContribution(
        world: SIMD3<Float>,
        lightPosition: SIMD3<Float>,
        lightColor: SIMD3<Float>,
        radius: Float,
        exponent: Float,
        normal: SIMD3<Float>,
        view: SIMD3<Float>,
        albedo: SIMD3<Float>,
        roughness: Float,
        metallic: Float,
        specularTint: SIMD3<Float>
    ) -> SIMD3<Float> {
        guard radius > 0 else { return .zero }
        let delta = lightPosition - world
        return finiteContribution(delta: delta, lightColor: lightColor, radius: radius,
                                  exponent: exponent, normal: normal, view: view, albedo: albedo,
                                  roughness: roughness, metallic: metallic, specularTint: specularTint)
    }

    /// WE common_pbr.h:9-16 PointSegmentDelta 1:1 — 세그먼트 최근접점까지의 델타.
    /// A==B 퇴화(v==0)는 A-pos 반환(point 와 동치). saturate = clamp(x,0,1).
    static func pointSegmentDelta(_ pos: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        let delta = b - a
        let v = simd_dot(delta, delta)
        if v == 0 { return a - pos }
        let t = max(0, min(1, simd_dot(pos - a, delta) / v))
        return a + t * delta - pos
    }

    /// tube(kind 4): 세그먼트 최근접점을 광원점으로 하는 유한광 — WE PerformLighting_V1 tube 분기.
    /// 근거(2026-08-21 재확인): 엔진이 조립하는 스니펫 원문
    /// `lightDelta = PointSegmentDelta(worldPos, g_LTube_OriginA[i].xyz, g_LTube_OriginB[i].xyz)`
    /// (0x14048caa0) + `ComputePBRLightShadow(..., g_LTube_Color[i].w, g_LTube_OriginA[i].w, ..., 1.0)`
    /// (0x14048c9e0 — 마지막 인자 1.0 이 shadowFactor 라 tube 는 무섀도우).
    /// 유니폼 패커 0x140192a19–0x140192ab7 이 `Color=(color*intensity, radius[0x2e8])`,
    /// `OriginA=(worldPos, exponent[0x2ec])` 로 싣는 것까지 실측 — point 와 동형 패킹이다.
    /// (종전 인용 `A2-pbr-lighting.md §4.4` 는 리포에 존재하지 않는 문서였다.)
    /// pointContribution 과의 유일한 차이는 델타 산출 — QuadShaders f_lit tube 분기의 CPU 미러.
    static func tubeContribution(
        world: SIMD3<Float>,
        segmentA: SIMD3<Float>,
        segmentB: SIMD3<Float>,
        lightColor: SIMD3<Float>,
        radius: Float,
        exponent: Float,
        normal: SIMD3<Float>,
        view: SIMD3<Float>,
        albedo: SIMD3<Float>,
        roughness: Float,
        metallic: Float,
        specularTint: SIMD3<Float>
    ) -> SIMD3<Float> {
        guard radius > 0 else { return .zero }
        let delta = pointSegmentDelta(world, segmentA, segmentB)
        return finiteContribution(delta: delta, lightColor: lightColor, radius: radius,
                                  exponent: exponent, normal: normal, view: view, albedo: albedo,
                                  roughness: roughness, metallic: metallic, specularTint: specularTint)
    }

    /// point/tube 공통 유한광 BRDF 코어(f_lit 루프 본문의 CPU 미러 — 종전 pointContribution 본문 그대로).
    private static func finiteContribution(
        delta: SIMD3<Float>,
        lightColor: SIMD3<Float>,
        radius: Float,
        exponent: Float,
        normal: SIMD3<Float>,
        view: SIMD3<Float>,
        albedo: SIMD3<Float>,
        roughness: Float,
        metallic: Float,
        specularTint: SIMD3<Float>
    ) -> SIMD3<Float> {
        let distance = simd_length(delta)
        guard distance >= 1e-5 else { return .zero }

        let light = delta / distance
        let nl = max(simd_dot(normal, light), 0)
        // Back-facing selected-path output is already zero; avoid normalize(view + light) NaN.
        guard nl > 0 else { return .zero }
        let halfVector = simd_normalize(view + light)

        let d = distributionGGX(normal: normal, halfVector: halfVector, roughness: roughness)
        let g = geometry(normal: normal, view: view, light: light, roughness: roughness)
        let f0 = SIMD3<Float>(repeating: 0.04) * (1 - metallic) + albedo * metallic
        let f = fresnel(cosTheta: max(simd_dot(halfVector, view), 0), f0: f0)
        let kd = (SIMD3<Float>(repeating: 1) - f) * (1 - metallic)
        let denominator = max(4 * max(simd_dot(normal, view), 0) * nl, 0.001)
        let specular = (d * g / denominator) * f * specularTint
        let diffuse = kd * albedo / Float.pi
        let attenuation = SceneLight3D.finiteLightFalloff(
            distance: distance, radius: radius, exponent: exponent)
        return (diffuse + specular) * lightColor * attenuation * nl
    }
}

public extension SceneLight3D {
    /// WE 2.8.42 HLSL lane finite-light falloff(`#define HLSL 1` 크로스컴파일 프리앰블 —
    /// wallpaper64.exe 0x140486898–0x1404868bb `"#define HLSL 1\n#define HLSL_SM40 1\n"`):
    /// `common_pbr_2.h:263-266` `falloff = saturate(1 - d/r)`, `pow(falloff + 1.17549435e-38, exponent)`.
    /// 반경 컷오프 없음 — exponent=0 이면 반경 무관 1.0(전역 무감쇠).
    /// GPU MSL 2곳(Mesh3DShaders/QuadShaders)과 동일 수식(CPU↔GPU 비트 일치 규약).
    ///
    /// `radius <= 0 → 0` 은 **Waple 이 더한 가드**다. WE 원문에는 없고(`1 - d/0 = -inf → saturate → 0`
    /// → `pow(1.17549435e-38, exponent)`), exponent=0 이면 WE 는 1.0 을 낸다. 도달은 0 이다 —
    /// `Scene3DLighting.resolveLights` 가 비-directional 라이트의 `radius <= 1e-4` 를 이미 버린다.
    static func finiteLightFalloff(distance: Float, radius: Float, exponent: Float) -> Float {
        guard radius > 0 else { return 0 }
        let falloff = max(0, min(1, 1 - distance / radius))
        return powf(falloff + 1.17549435e-38, exponent)
    }

    /// Runtime-independent CPU oracle for the reachable orthographic `QuadShaders.f_lit` path.
    static func evaluateLighting(
        at world: SIMD3<Float>,
        _ uniforms: ForwardUniforms,
        normal: SIMD3<Float> = SIMD3(0, 0, 1),
        view: SIMD3<Float> = SIMD3(0, 0, 1),
        albedo: SIMD3<Float> = SIMD3(repeating: 1),
        roughness: Float = 0.7,
        metallic: Float = 0,
        specularTint: SIMD3<Float> = SIMD3(repeating: 1)
    ) -> SIMD3<Float> {
        var result = uniforms.ambientTerm * albedo
        // 상한은 ForwardUniforms.slotCount(2D 레인 슬롯 수) — 종전 리터럴 4 는 F660 이후 3D 와 어긋난
        // 2D 상한을 그대로 박아 둔 값이었다. init 이 count 를 네 배열의 실제 길이로 클램프하므로
        // 이 min 은 구형 호출부(짧은 배열 + 기본값)까지 포함해 범위 안을 보장한다.
        for i in 0..<min(uniforms.count, ForwardUniforms.slotCount) {
            let position = uniforms.positions[i]
            let colorRadius = uniforms.colorRadius[i]
            if Int(uniforms.kindCone[i].x + 0.5) == 4 {
                // tube(kind 4): 세그먼트 최근접점 유한광 — f_lit tube 분기의 CPU 미러.
                // (directional/spot 는 이 오라클이 kind 지원 이전부터 point 근사로 두는 기존 한계 유지 —
                //  여기서는 정본 수식이 확정된 tube 만 정식 경로로 싣는다.)
                result += ScenePBRMath.tubeContribution(
                    world: world,
                    segmentA: SIMD3(position.x, position.y, position.z),
                    segmentB: SIMD3(uniforms.axisCone[i].x, uniforms.axisCone[i].y, uniforms.axisCone[i].z),
                    lightColor: SIMD3(colorRadius.x, colorRadius.y, colorRadius.z),
                    radius: colorRadius.w,
                    exponent: position.w,
                    normal: normal,
                    view: view,
                    albedo: albedo,
                    roughness: roughness,
                    metallic: metallic,
                    specularTint: specularTint)
                continue
            }
            result += ScenePBRMath.pointContribution(
                world: world,
                lightPosition: SIMD3(position.x, position.y, position.z),
                lightColor: SIMD3(colorRadius.x, colorRadius.y, colorRadius.z),
                radius: colorRadius.w,
                exponent: position.w,
                normal: normal,
                view: view,
                albedo: albedo,
                roughness: roughness,
                metallic: metallic,
                specularTint: specularTint)
        }
        return result
    }
}

// MARK: - WE 라이팅 정본 상수/수식 (2026-08-21 x86 + 셰이더 원문 전수 대조)

/// WE 2.8.42 의 **메시 라이팅 정본 수식**을 인자만 받는 순수 함수로 고정한다.
///
/// 왜 여기(WapleCore)인가: 라이브 셰이딩은 `Mesh3DShaders.swift` 의 MSL 이고 리눅스에서 돌릴 수
/// 없다. 감쇠·프레넬·러프니스 매핑처럼 **텍스처가 없는 순수 산술**만 떼어 여기 두면 리눅스
/// 코어 테스트가 값을 못박아 두 구현이 갈라지는 것을 잡는다(ScenePBRMath 가 데드코드로 표류한
/// 전례 — spec/engine/deviations.json `deviation.finding.scenePBRMathIsDead`).
///
/// ## WE 의 라이팅 레인은 셋이고 감쇠식이 서로 다르다 — 이것이 이 파일의 요점이다
/// | 레인 | 소비 셰이더 | 함수 | radiance |
/// |---|---|---|---|
/// | V1 (현행 이식 대상) | `generic4`/`chroma4`/`fur4`/`foliage4`/`genericimage4` | `common_pbr_2.h:256` `ComputePBRLightShadow` | `color * pow(saturate(1-d/r), exponent)` |
/// | V0 (deprecated PBR) | `generic3`/`genericimage3` | `common_pbr.h:40` `ComputePBRLight` | `color * r * r / (d*d)` (역제곱, generic3.frag:152) |
/// | 레거시(비 PBR) | `generic`/`generic2` | `common_fragment.h:68` `ComputeLightSpecular` | `saturate((r-d)/r)^2` (diffuse) · `^1` (스페큘러) |
///
/// V1/V0 는 `#require LightingV1` 스니펫(엔진이 문자열로 조립 — wallpaper64.exe
/// **0x140169140–0x14016b0d4**, 조각 문자열 0x14048be50–0x14048cfd0) 대 `PerformLighting_Deprecated`
/// (generic3.frag:87-166) 로 갈린다. 우리 스톡 메시 셰이더는 V1 만 이식했다.
///
/// ⛔️ **정정(2026-08-21)**: 종전 표기는 **양쪽 끝이 다 틀렸다** — 시작은 생성기 **앞** 함수
/// (`0x140167e10–0x140169138`) 안, 끝은 **뒤** 함수(`0x14016b0e0–0x14016c3f8` — 라이팅 스니펫이
/// 아니라 전처리기 디렉티브 파서 `^\s*#\s*([a-z]+)\b\s*(.*)` 0x14048d048) 안이었고, 둘 다
/// 명령 경계조차 아니었다(옛 주소와 그것이 실제로 가리키던 명령은
/// `docs/re/scene-lighting.md` §2.1 정정 표). 생성기 본체는 정확히
/// **0x140169140–0x14016b0d4** 다(진입 `LIGHTING` 콤보 조회 0x1401691b8 · `LightingV1` 이름 비교
/// 0x1401691f5 · 머리 문자열 0x14048c070 방출 · 꼬리 `\treturn light;\n}` 0x14048ce30 · `ret` 0x14016b0cc).
/// HLSL 판 라이트 배열은 또 다른 함수 `0x1400f5cb0–0x1400f8520` 이다. 전문은
/// `docs/re/scene-lighting.md` §2.1/§8.
enum SceneWELightMath {
    /// V1 유한광 감쇠 지수의 밑에 더하는 하한. HLSL 레인 원문 상수
    /// (`common_pbr_2.h:266` `pow(falloff + 1.17549435e-38, exponent)` — `#if HLSL` 가지).
    /// GLSL 레인은 `6.103515625e-5`(half 최소 정규수) 를 쓰고 그 아래를 hard-zero 로 끊는다
    /// (`common_pbr_2.h:268-269`). 우리는 HLSL 레인을 채택했다(Mesh3DShaders/QuadShaders 동일).
    static let hlslFalloffEpsilon: Float = 1.17549435e-38
    /// GLSL 레인 하한(`common_pbr_2.h:268` `flt_min`). 채택하지 않았지만 두 레인이 갈리는
    /// 지점을 테스트로 못박기 위해 상수만 보존한다.
    static let glslFalloffEpsilon: Float = 6.103515625e-5

    /// V1 유한광(point/spot/tube) 감쇠 — `common_pbr_2.h:263-270`.
    /// `falloff = saturate(1 - d/r)`, `radiance = color * pow(falloff + eps, exponent)`.
    /// **반경 컷오프가 없다**: `exponent=0` 이면 `pow(x,0)=1` 이라 반경 밖도 감쇠 0 이 아니다.
    static func finiteFalloff(distance: Float, radius: Float, exponent: Float) -> Float {
        let falloff = max(0, min(1, 1 - distance / radius))
        return powf(falloff + hlslFalloffEpsilon, exponent)
    }

    /// GLSL 레인 감쇠(미채택 — 대조용). `common_pbr_2.h:268-269`:
    /// `mix(0.0, pow(falloff + flt_min, exponent), step(0.0, falloff - flt_min))`.
    /// `falloff < flt_min` 이면 지수와 무관하게 0 — HLSL 레인과 갈리는 유일한 지점이다.
    static func finiteFalloffGLSLLane(distance: Float, radius: Float, exponent: Float) -> Float {
        let falloff = max(0, min(1, 1 - distance / radius))
        guard falloff - glslFalloffEpsilon >= 0 else { return 0 }
        return powf(falloff + glslFalloffEpsilon, exponent)
    }

    /// V0(deprecated) 유한광 감쇠 — `common_pbr.h:84` `radiance = lightColor / (distance*distance)`
    /// 에 generic3.frag:132/145/152/160 이 실어 보내는 `color * radius * radius` 를 합친 값.
    /// 즉 반경은 컷오프가 아니라 **세기 배율**이고 감쇠는 순수 역제곱이다(반경 밖도 밝다).
    /// SHADERVERSION < 62 가지(generic3.frag:87-121)는 `radius*radius` 배율이 없다.
    static func deprecatedInverseSquareFalloff(distance: Float, radius: Float,
                                               legacyShaderVersion: Bool = false) -> Float {
        guard distance > 0 else { return 0 }
        let scale = legacyShaderVersion ? Float(1) : radius * radius
        return scale / (distance * distance)
    }

    /// 레거시(비 PBR) 레인 감쇠 계수 — `common_fragment.h:64,71` `saturate((radius - d) / radius)`.
    /// 확산은 이 값의 **제곱**(`common_fragment.h:65,80`), Blinn 스페큘러는 **1승**
    /// (`common_fragment.h:74`) 을 쓴다. 제곱 쪽은 V1 의 `exponent=2` 와 대수적으로 동치다
    /// (`saturate(1-d/r)^2`) — 두 레인을 잇는 유일한 접점이라 테스트로 못박는다.
    static func legacyAttenuation(distance: Float, radius: Float) -> Float {
        guard radius != 0 else { return 0 }
        return max(0, min(1, (radius - distance) / radius))
    }

    /// 레거시 레인 러프니스→스페큘러 지수 — `common_fragment.h:51-54`
    /// `(1.01 - roughness) * mix(400.0, 250.0, metallic)`.
    /// `Rough`/`Metal` 둘 다 기본 0(generic2.frag:6-9)이라 스톡 값은 **404** — 사실상 델타 함수다.
    static func legacySpecularPower(roughness: Float, metallic: Float) -> Float {
        (1.01 - roughness) * (400 + (250 - 400) * metallic)
    }

    /// 레거시 레인 스페큘러 세기 — `common_fragment.h:56-59`
    /// `(0.5 + metallic * 0.5) * (1.0 - roughness * 0.9)`.
    static func legacySpecularStrength(roughness: Float, metallic: Float) -> Float {
        (0.5 + metallic * 0.5) * (1 - roughness * 0.9)
    }

    /// GGX Smith-Schlick 의 러프니스→k 매핑 — `common_pbr.h:29-30`(= `common_pbr_2.h:29-30`)
    /// `k = (roughness + 1)^2 / 8`. 직접광 전용 매핑이다(IBL 의 `r^2/2` 가 아니다).
    static func schlickRoughnessK(_ roughness: Float) -> Float {
        let base = roughness + 1
        return base * base / 8
    }

    /// spot 콘 계수 — 엔진이 조립하는 V1 스니펫 원문
    /// (0x14048c960 `spotCookie = -dot(normalize(lightDelta), g_LSpot_Direction[i].xyz)`,
    ///  0x14048c900 `spotCookie = smoothstep(g_LSpot_Direction[i].w, g_LSpot_Origin[i].w, spotCookie)`).
    /// edge0 = `Direction.w` = cos(outercone), edge1 = `Origin.w` = cos(innercone).
    /// GLSL `smoothstep` 정의 그대로: `t = clamp((x-e0)/(e1-e0), 0, 1); t*t*(3-2t)`.
    static func spotCone(cosAngle: Float, cosInner: Float, cosOuter: Float) -> Float {
        let span = cosInner - cosOuter
        guard span != 0 else { return cosAngle < cosOuter ? 0 : 1 }
        let t = max(0, min(1, (cosAngle - cosOuter) / span))
        return t * t * (3 - 2 * t)
    }

    /// scene.json `innercone`/`outercone`(도) → 콘 코사인.
    /// **전각이 아니라 축 기준 반각이다** — V1 유니폼 패커가 `cos(각도 * π/180)` 을 그대로 싣는다
    /// (wallpaper64.exe 0x140192e64–0x140192e86 inner, 0x140192eaa–0x140192ebf outer;
    ///  deg2rad 상수 0.01745329238474369 @0x140492628 을 0x1401910bf 에서 xmm7 로 적재).
    /// 0.5 배가 **없다**는 것이 요점이다(종전 Waple 은 반각 해석으로 `* 0.5` 를 곱했다).
    static func coneCosine(degrees: Float) -> Float {
        cosf(degrees * (Float.pi / 180))
    }

    /// 반구 앰비언트 — `base/model_vertex_v1.h:207-210` `ApplyAmbientLighting`
    /// = `mix(g_LightSkylightColor, g_LightAmbientColor, dot(normal, vec3(0,1,0)) * 0.5 + 0.5)`.
    /// 법선이 **위**를 보면 `ambientcolor`, **아래**를 보면 `skylightcolor` 다(이름과 반대로 보이지만
    /// 원문 인자 순서가 그렇다 — generic.vert:77 / generic2.vert:73 / generic3.vert:171 /
    /// generic4.vert:168 네 곳이 같은 식이다). WE 는 정점에서 계산해 보간하고 우리는 픽셀에서 푼다.
    static func hemisphereAmbient(normal: SIMD3<Float>, ambient: SIMD3<Float>,
                                  skylight: SIMD3<Float>) -> SIMD3<Float> {
        let t = max(0, min(1, normal.y * 0.5 + 0.5))
        return skylight + (ambient - skylight) * t
    }

    /// `CombineLighting(light, ambient)` — `common_pbr_2.h:365-374`(= `common_pbr.h:88-96`).
    /// 비HDR: `ambient + light`. HDR: `saturate(ambient + light) + light * overbright`,
    /// `overbright = saturate(len(light) - 2.0) * 0.5 / max(0.01, len(light))`.
    /// HDR 가지는 **엔진이 주입하는 콤보**라 머티리얼 저작으로는 안 켜진다(scene `general.hdr`).
    static func combineLighting(light: SIMD3<Float>, ambient: SIMD3<Float>,
                                hdr: Bool) -> SIMD3<Float> {
        guard hdr else { return ambient + light }
        let lightLength = simd_length(light)
        let overbright = max(0, min(1, lightLength - 2)) * 0.5 / max(0.01, lightLength)
        let base = ambient + light
        let saturated = SIMD3<Float>(max(0, min(1, base.x)),
                                     max(0, min(1, base.y)),
                                     max(0, min(1, base.z)))
        return saturated + light * overbright
    }

    /// RIMLIGHTING 항 — `common_pbr_2.h:292-297`(유한광)/`:340-345`(무한광).
    /// `rimTerm = shadowFactor * pow(1 - max(dot(N,V),0), exponent) * amount * NL * step(0.001, ΣlightColor)`.
    /// 게이트 임계는 V1 레인이 **0.001**, 구경로 `common_pbr.h:64,75` 가 0.01 로 서로 다르다.
    /// 게이트가 보는 `lightColor` 는 spot 의 경우 **콘이 곱해진** 색이다(스니펫 0x14048c750:
    /// `g_LSpot_Color[i].rgb * spotCookie` 를 그대로 인자로 넘긴다).
    static func rimTerm(nDotV: Float, nDotL: Float, amount: Float, exponent: Float,
                        lightColor: SIMD3<Float>, shadowFactor: Float = 1) -> Float {
        let sum = lightColor.x + lightColor.y + lightColor.z
        let gate: Float = sum >= 0.001 ? 1 : 0
        return shadowFactor * powf(1 - max(nDotV, 0), exponent) * amount * nDotL * gate
    }
}

public extension SceneLight3D {
    /// WE 라이트 오브젝트의 **생성자 기본값**(scene.json 에 키가 없을 때 남는 값).
    /// wallpaper64.exe 0x140190441–0x1401904ef (오브젝트 크기 0x3a0, vtable 0x140491c38).
    /// 필드 오프셋은 에디터 프로퍼티 등록 테이블 0x14025da80–0x14025e9da 에서 키↔오프셋으로 확인.
    ///
    /// | 키 | 오프셋 | WE 기본값 | Waple `SceneDocument.parseLight` 기본값 |
    /// |---|---|---|---|
    /// | `light`(타입 enum) | 0x2c0 | 5 = `"point"`(레거시 레인) | — (미지 타입은 드롭) |
    /// | `color` | 0x2cc | (0,0,0) | (1,1,1) |
    /// | `controlpoint` | 0x2d8 | (2,0,0) | 미파스 |
    /// | `intensity` | 0x2e4 | 0 | 1 |
    /// | `radius` | 0x2e8 | **1.0** | **0** |
    /// | `exponent` | 0x2ec | **2.0** | **1** |
    /// | `innercone` | 0x2f0 | **20.0** | **0** |
    /// | `outercone` | 0x2f4 | **30.0** | **0** |
    /// | `density` | 0x2f8 | 2.0 | 2 ✓ |
    /// | `volumetricsexponent` | 0x2fc | 1.0 | 1 ✓ |
    /// | `cascadedistance0/1/2` | 0x300/0x304/0x308 | 3.0 / 10.0 / 100.0 | nil |
    /// | `lightsourcesize` | 0x30c | 0 | 미파스 |
    /// | `castshadow` | 0x2c4 **bit0** | false | false ✓ |
    /// | `usecookie` | 0x2c4 **bit1** | false | 미파스 |
    /// | `castvolumetrics` | 0x2c4 **bit2** | false | false ✓ |
    /// | `visible` | 0x120(공통) | true | true ✓ |
    ///
    /// 위 18키가 **라이트 프로퍼티 전수**다(등록 테이블 `0x14025da80`–`0x14025e9da`, 항목당
    /// `lea rdx,<이름>` → `mov [reg+0x34],<오프셋>` → `mov [reg+0x30],<타입>`; 타입 2=vec3
    /// 4=float 5=enum 6=bool). `+0x2c4` 세 비트는 세터에서 배타적으로 확정된다 —
    /// `usecookie` 세터 `0x14019b4e0` 이 `or ecx, 2`(`0x14019b51a`)/`and ~2`,
    /// `castvolumetrics` 세터 `0x14019bfa0` 이 `or ecx, 4`(`0x14019bfda`)/`and ~4`,
    /// 남는 bit0 이 `castshadow`(볼류메트릭 SHADOW 콤보 게이트 `0x1401981ea`
    /// `test byte [light+0x2c4], 1`, V1 point 패커 `0x14019326b`–`0x1401932ae`).
    /// `castvolumetrics` 는 **저작 키가 없으면 false** 이므로(`0x14019048d`
    /// `mov dword [rdi+0x2c4], 0`) 볼류메트릭 패스는 기본적으로 꺼져 있다.
    ///
    /// 굵은 넷(`radius`/`exponent`/`innercone`/`outercone`)이 실제로 화면을 가른다. 특히
    /// `exponent` 미저작 라이트는 WE 가 2 로 감쇠하는데 우리는 1 로 감쇠한다 — 동봉/설치본의
    /// `modeleditor` 씬 lpoint 2개가 정확히 그 경우다(`exponent` 키 없음).
    /// 파스는 `SceneDocument.swift` 소관이라 여기서는 **상수만 노출**한다(소비는 그 레인).
    enum WEDefaults {
        public static let color = SIMD3<Float>(0, 0, 0)
        public static let controlPoint = SIMD3<Float>(2, 0, 0)
        public static let intensity: Float = 0
        public static let radius: Float = 1
        // [2026-08-21] 이 값이 작업 중에 3 으로 바뀌어 있었다(근거 없음 · 위 표와 모순 ·
        // `SceneWELightMathTests:219` 를 깨뜨림). 생성자를 직접 떠서 **2.0 로 되돌린다** —
        //   0x14019049e  mov dword ptr [rdi+0x2ec], 0x40000000   ; = 2.0f
        // 같은 블록의 형제 상수도 한 번에 재확인했다(전건 아래 값과 일치):
        //   +0x2e8 0x3f800000 = 1.0  radius        +0x2f0 0x41a00000 = 20.0 innerCone
        //   +0x2f4 0x41f00000 = 30.0 outerCone     +0x2f8 0x40000000 = 2.0  density
        //   +0x2fc 0x3f800000 = 1.0  volumetricsExponent
        //   +0x2d8 qword 0x40000000 = controlPoint (2,0,·)  ·  +0x2c4 = 0 (플래그 3비트 전부 false)
        public static let exponent: Float = 2
        public static let innerConeDegrees: Float = 20
        public static let outerConeDegrees: Float = 30
        public static let density: Float = 2
        public static let volumetricsExponent: Float = 1
        public static let cascadeDistances = SIMD3<Float>(3, 10, 100)
        public static let lightSourceSize: Float = 0
    }
}

// MARK: - `general.lightconfig` 소비 — 슬롯 예산 (2026-08-21 x86 재확인)

/// `lightconfig` 예산이 관장하는 **V1 레인** 라이트 종류. `Scene3DLightKind`(WapleRender, MSL
/// `LightU.shadow.z` 와 rawValue 를 공유)와 달리 이쪽은 **씬 문자열 → V1 레인 여부** 판정이
/// 목적이라 Metal 비의존이고, 그래서 여기(WapleCore)에 둔다 — 리눅스 코어 테스트가 규약을 못박는다.
///
/// ## WE 실측: 문자열 표는 **5 엔트리**이고 `"point"` 는 V1 이 아니다
/// 정적 초기화 `0x14025e853`–`0x14025e9d0`(저장소 `0x1404e9cf0`, stride `0x28`, 값은 엔트리+0x20):
/// `"point"`→**5**(`0x14025e931`) · `"lpoint"`→0(BSS 0) · `"lspot"`→1(`0x14025e979`) ·
/// `"ltube"`→2(`0x14025e99d`) · `"ldirectional"`→3(`0x14025e9c9`). 표에 없는 문자열은 생성자
/// 기본값 `5`(`0x140190486` `mov byte [rdi+0x2c0], 5`)로 남는다.
///
/// `"lpoint"`→0 은 **두 번째 독립 증인**이 있다(2026-08-21): 볼류메트릭 렌더가 `POINTLIGHT`
/// 콤보를 `cmp byte [light+0x2c0], 0` / `jne`(`0x1401982fa`)로만 세운다 — 즉 엔진이 "point
/// 라이트" 로 취급하는 종은 값 0 하나뿐이고, 그 자리에 오는 씬 문자열이 `lpoint` 다.
///
/// V1 유니폼 패커(`0x140190c80`–`0x1401964b8`)는 `[obj+0x2c0]` 를 읽어(`0x1401910f2`) 0/1/2/3 만
/// 처리하고 **4·5 는 통째로 버린다**(`0x140191114` `cmp eax,1` / `jne 0x14019318c`). 즉 타입 5
/// (`"point"` 와 미지 문자열 전부)는 `lightconfig` 슬롯을 **먹지 않고** 레거시 4슬롯 레인
/// (`0x14025d1f6`, `g_LightsColorRadius[4]`)으로 간다.
///
/// **그래서 `init?(weLightType:)` 은 `l` 접두 4종만 받는다.** Waple 의 `Scene3DLightKind(type:)` 은
/// 접두 없는 `"point"`/`"spot"`/`"tube"`/`"directional"` 도 관용으로 받아 V1 근사로 그리는데
/// (레거시 Blinn 레인을 이식하지 않아 "빛 없음" 보다 낫다는 기존 정책), 그 관용을 **예산에까지
/// 들이면** `lightconfig` 를 가진 씬의 레거시 라이트가 통째로 사라져 화면이 검어질 수 있다.
/// 예산은 WE 가 실제로 버리는 것만 버린다 — 레거시 레인은 종전 그대로 통과시킨다.
public enum SceneLightSlotKind: Equatable, CaseIterable {
    case point, spot, tube, directional

    /// scene.json `"light"` 문자열 → V1 레인 종류. **레거시/미지 타입은 nil**(위 주석 참조).
    public init?(weLightType: String) {
        switch weLightType.lowercased() {
        case "lpoint": self = .point
        case "lspot": self = .spot
        case "ltube": self = .tube
        case "ldirectional": self = .directional
        default: return nil
        }
    }
}

/// `general.lightconfig` → 종류별/섀도우별 **슬롯 예산**. 저작 씬만 상한이 되고, 미저작(nil)은
/// 모든 `take` 가 성공한다(= 종전 폴백, 비트동일).
///
/// ## WE 실측 규약 (근거 VA — 2026-08-21 재확인)
/// 1. **파스**: 9키가 `[engine+0x121C]` 한 워드에 니블/2비트로 OR 된다. 폭 초과는 **클램프가 아니라
///    절단**이다 — `and eax,0xF` 뒤 `or [rcx+0x121c],eax`(point `0x140187b7a`), spot `shl 4`
///    (`0x140187bab`), tube `shl 8`(`0x140187bd7`), directional `shl 0xc`(`0x140187c03`);
///    2비트 계열은 `and eax,3` 뒤 spotcookie `shl 0x12`(`0x140187c32`), spotshadowcookie
///    `shl 0x14`(`0x140187c66`), spotshadow `shl 0x10`(`0x140187c93`), directionalshadow
///    `shl 0x16`(`0x140187cb9`), pointshadow `shl 0x18`(`0x140187d00`). 즉 `{"point":16}` 은
///    WE 에서 **0**, `{"point":17}` 은 **1** 이다. 절단은 `SceneLightConfig.parse` 가 이미 한다.
/// 2. **콤보**: 세터 `0x1401a5c40`–`0x1401a6c5d` 가 그 워드를 잘라 9 콤보를 무조건 세운다
///    (point `and 0xF` `0x1401a5e44` … pointshadow `shr 0x18` `0x1401a6220`). **9키 ↔ 9콤보 1:1,
///    변환 없음.**
/// 3. **셰이더 퍼뮤테이션**: 콤보 값이 배열 길이이자 루프 상한이다. V0 레인은 평문으로 남아 있어
///    직접 읽을 수 있다 — `uniform vec4 g_LPoint_Color[LIGHTS_POINT];`(generic3.frag:64) +
///    `for (uint l = 0u; l < CASTU(LIGHTS_POINT); ++l)`(:90). V1 레인은 셰이더 파일에 본문이 없고
///    생성기 `0x140169140`–`0x14016b0d4` 가 **완전 언롤**로 조립한다(`\tconst uint i = <상수>u;`
///    `0x14048c298`). 어느 쪽이든 **값 = 슬롯 수**다.
/// 4. **섀도우는 가산이 아니라 분할**: point 루프가 `ebx=0`→`LIGHTS_POINT_SHADOW`(`0x140169d23`)로
///    섀도우 블록을, 이어서 `ebx`→`LIGHTS_POINT`(`0x140169d42`)로 무섀도우 블록을 찍는다.
///    `{"point":1,"pointshadow":1}` 은 라이트 **1개**이고 그게 캐스터라는 뜻이다.
/// 5. **초과분은 드롭**: 유니폼 패커가 종별 잔여 카운터를 `test/je` 로 보고 0 이면 라이트를 통째로
///    버린다(point `[rsp+0x60]` `0x14019325f`, spot `[rbp-0x64]` `0x140192dbf`,
///    tube `[rbp-0x68]` `0x140192a19`, directional `[rbp-0x28]` `0x14019111d`). 섀도우 예산은 별도
///    카운터라(point `[rsp+0x6c]` `0x14019332b`, directional `[rbp+0x24]` `0x14019353a`) 소진되면
///    **그림자만 잃고 셰이딩은 남는다**(`0x140193331` 의 `je` 는 프로젝션 기록만 건너뛴다).
/// 6. **소비는 가시성 판정 뒤**(`IsVisible` `0x1401910d6` → 종 분기 `0x1401910f2` → `test/je`).
///
/// ## 우리 쪽 의도적 차이 셋
/// 1. 미저작 씬을 WE 처럼 "V1 라이트 0개"(`0x140190ca8` `test r9d,r9d; je`)로 만들지 **않는다**.
///    `arsenal`(ambientcolor 완전 검정)이 새까매지고 레거시 Blinn 레인을 이식하지 않았다.
/// 2. 소비 시점을 유한성/반경 가드 뒤로 미룬다(WE 는 그 가드가 없어 순서가 무의미).
/// 3. 셰이더 배열이 8 고정이라 **줄이는 방향만** 반영한다(늘리는 쪽은 `docs/re/scene-lighting.md` §9).
///
/// spot/tube 섀도우 예산은 여기서 다루지 않는다 — tube 는 WE 정본이 무섀도우(스니펫 `0x14048c9e0`
/// 의 마지막 인자가 리터럴 `1.0`)이고 spot 섀도우는 Waple 미이식이라 호출부가 애초에 후보로 안 준다.
public struct SceneLightSlotBudget: Equatable {
    /// nil = 미저작(`general.lightconfig` 부재/비객체) → 상한 없음(종전 폴백).
    private var authored: Bool
    private var point: Int
    private var spot: Int
    private var tube: Int
    private var directional: Int
    private var pointShadow: Int
    private var directionalShadow: Int

    /// `config == nil` 이면 모든 `take`/`takeShadow` 가 성공한다(= 종전 폴백, 비트동일).
    public init(_ config: SceneLightConfig?) {
        guard let config else {
            authored = false
            point = 0; spot = 0; tube = 0; directional = 0
            pointShadow = 0; directionalShadow = 0
            return
        }
        authored = true
        point = config.point
        spot = config.spot
        tube = config.tube
        directional = config.directional
        pointShadow = config.pointShadow
        directionalShadow = config.directionalShadow
    }

    /// 남은 슬롯 조회(테스트/진단용 — 소비하지 않는다). 미저작이면 nil.
    public func remaining(_ kind: SceneLightSlotKind) -> Int? {
        guard authored else { return nil }
        switch kind {
        case .point: return point
        case .spot: return spot
        case .tube: return tube
        case .directional: return directional
        }
    }

    /// 남은 섀도우 슬롯 조회(소비하지 않는다). 미저작이면 nil. spot/tube 는 항상 0.
    public func remainingShadow(_ kind: SceneLightSlotKind) -> Int? {
        guard authored else { return nil }
        switch kind {
        case .point: return pointShadow
        case .directional: return directionalShadow
        case .spot, .tube: return 0
        }
    }

    /// 종류별 슬롯 하나를 소비한다. 남은 슬롯이 없으면 false(= WE 가 그 라이트를 버리는 자리).
    public mutating func take(_ kind: SceneLightSlotKind) -> Bool {
        guard authored else { return true }
        switch kind {
        case .point: return Self.consume(&point)
        case .spot: return Self.consume(&spot)
        case .tube: return Self.consume(&tube)
        case .directional: return Self.consume(&directional)
        }
    }

    /// 섀도우 슬롯 하나를 소비한다. 실패해도 라이트 자체는 남는다(셰이딩 유지, 그림자만 상실).
    /// tube/spot 은 WE 에도 섀도우 판이 없어 항상 false.
    public mutating func takeShadow(_ kind: SceneLightSlotKind) -> Bool {
        switch kind {
        case .spot, .tube: return false
        case .point:
            guard authored else { return true }
            return Self.consume(&pointShadow)
        case .directional:
            guard authored else { return true }
            return Self.consume(&directionalShadow)
        }
    }

    private static func consume(_ slot: inout Int) -> Bool {
        guard slot > 0 else { return false }
        slot -= 1
        return true
    }
}

// MARK: - 볼류메트릭 라이트(라이트 샤프트) 정본 산술 (2026-08-21 셰이더 원문 전수 대조)

/// WE `shaders/volumetricsfront.frag` 의 **픽셀을 정하는 산술 전부**를 인자만 받는 순수 함수로
/// 고정한다. 복원 전문은 `docs/re/volumetric-light.md`.
///
/// ## 왜 여기(WapleCore)인가 — 2026-08-21 이관
/// 종전에는 이 enum 이 `Sources/WapleRender/VolumetricLightPass.swift` 안에 있었다. 그 파일은
/// `import Metal` 이라 **리눅스에서 실행할 수 없다** — `scripts/dev/linux-render-typecheck.sh` 가
/// `swiftc -typecheck` 는 해 주지만 값을 한 번도 계산하지 않는다. 즉 이식한 수식의 **숫자**를
/// 잠그는 것은 macOS 전용 `Tests/WapleRenderTests/VolumetricLightTests.swift` 하나뿐이었고,
/// 리눅스 대조는 "enum 블록만 잘라 따로 컴파일한다" 는 **수동 절차**로만 성립했다
/// (그 절차의 실행 기록이 `docs/re/volumetric-light.md` §6 이다).
///
/// 수동 절차는 회귀를 막지 못한다. 그래서 산술을 여기로 옮기고 `VolumetricMath` 는
/// `typealias` 로 남겼다 — WapleRender 호출부·macOS 테스트는 그대로 서고, 같은 코드가 이제
/// `Tests/WapleCoreTests/SceneVolumetricMathTests.swift` 에서 **리눅스 코어 테스트로 실행**된다.
///
/// ## `simd` 를 쓰지 않는다
/// `SIMD3<Float>` 는 표준 라이브러리 타입이지만 `simd_dot`/`simd_length`/`simd_normalize` 는
/// 애플 모듈이고 리눅스에서는 `linux-shim/` 대역이 붙는다(비트 동일 보장 없음).
/// 아래 `dot3`/`length3`/`normalize3` 로 직접 적어 **두 플랫폼이 같은 명령 순서**를 밟게 한다.
///
/// ## 덮는 범위: 프래그먼트 전체
/// 감쇠 항만 있던 시절엔 CPU 로 한 픽셀을 풀려면 호출자가 레이 재구성을 직접 다시 적어야 했고,
/// 그래서 "CPU 1.0 vs GPU 0.2235" 라는 유령 발산이 나왔다(`docs/re/volumetric-light.md` §6.1).
/// 프래그먼트에 있는 단계는 여기에도 있어야 한다.
///
/// ## 도달 (2026-08-21 이 컨테이너 실측)
/// 게이트 키 `castvolumetrics` 는 **동봉 172 ∪ 설치본 186 = distinct 186 씬에서 0건**이다
/// (동봉 `Sources/WapleRender/Resources/WEAssets` 172 파일이 설치본 `assets/` 172 와 경로·md5
/// 전수 동일 — 그래서 합이 358 이 아니라 186 이다). 문자열 자체가 자산 JSON 어디에도 없고
/// 실행파일(`wallpaper64.exe`·`wallpaper32.exe`·`wallpaperui.exe`)에만 있다. WE 기본값도 false
/// (`0x14019048d`). 즉 이 산술을 고쳐도 **두 트리의 어떤 씬도 화면이 바뀌지 않는다.**
/// 워크샵 코퍼스 162 씬에서만 4건/3씬(전부 true, `spec/corpus/scene-schema.json` 인용 —
/// 그 코퍼스는 이 컨테이너에 없다).
public enum SceneWEVolumetricMath {
    /// `volumetricsfront.frag:78-97` — QUALITY 콤보 → 레이마치 샘플 수.
    /// `SHADOW || COOKIE` 가지가 64/32/24/12(`:79`,`:81`,`:83`,`:85`), 아닌 가지가
    /// 8/5/3/2(`:89`,`:91`,`:93`,`:95`)다. QUALITY 는 앱 설정 바이트 `[renderCtx+0x1ad]`
    /// (`0x140198273`)이고 **씬 JSON 키가 아니다** — 저작자가 샘플 수를 지정하는 키는 WE 에 없다.
    public static func sampleCount(quality: Int, shadowed: Bool) -> Int {
        if shadowed {
            switch quality {
            case 4: return 64
            case 3: return 32
            case 2: return 24
            default: return 12
            }
        }
        switch quality {
        case 4: return 8
        case 3: return 5
        case 2: return 3
        default: return 2
        }
    }

    /// 라이트버퍼(`_rt_volumetricsLightBuffer`/`B`, `_rt_volumetricsSingle`)의 **다운스케일 분모**.
    /// `0x140196d79`–`0x140196d88`: `edi = (quality >= 3) ? 4 : 8` 이고 그 값이 RT 생성기
    /// `sub_1401aadb0` 의 4번째 인자로 간다 — 같은 인자가 `_rt_FullFrameBuffer`=1 ·
    /// `_rt_4FrameBuffer`=4 · `_rt_8FrameBuffer`=8 (`0x14017f585`–`0x14017f63d`)이라 분모가 맞다.
    /// `_rt_volumetricsBack` 만 1(풀해상도)이다(`0x140196dc4`).
    ///
    /// **복원 전용(현 경로 미소비)** — Waple 은 목적지에 풀해상도로 직접 합성한다.
    /// 라이트버퍼를 실제로 만들 때 이 규칙이 정본이다(AGENTS.md "보존 필드는 데드코드가 아니다").
    public static func lightBufferDivisor(quality: Int) -> Int { quality >= 3 ? 4 : 8 }

    /// blur3 h/v 체인을 태우는가. `0x140196ea0`–`0x140196ea4` 가 QUALITY≥3 이면
    /// `_rt_volumetricsLightBufferB` 와 blur 머티리얼 두 장을 **아예 만들지 않고**,
    /// 리졸브(`0x140198d21`)도 같은 조건으로 blur 두 패스를 건너뛴다.
    /// 즉 고품질일수록 샘플이 많아 블러가 필요 없다는 설계다.
    ///
    /// **복원 전용(현 경로 미소비)** — 위와 같은 이유.
    public static func blursLightBuffer(quality: Int) -> Bool { quality < 3 }

    /// `blur_k3` 가 쓰는 `blur3` 탭 가중치(`shaders/common_blur.h:25-30`) — (−1, 0, +1) 픽셀.
    /// **복원 전용(현 경로 미소비)**.
    public static let blur3Weights: [Float] = [0.25, 0.5, 0.25]

    /// `volumetricsfront.frag:132` — 반경 감쇠. 반경 밖은 **정확히 0**(무한 꼬리 없음).
    /// 원문: `pow(saturate(1.0 - (length(lightDelta) * invRadius)), VAR_EXPONENT)`.
    ///
    /// **역수 곱으로 적는다.** WE 도 `invRadius = 1/R` 을 한 번 잡아(`:116`) 곱하고,
    /// `VolumetricLightPass.metalSource` 도 `lightCone.z`(=`1/hull`)를 곱한다. 여기서만
    /// `distance / hullRadius` 로 나누면 마지막 자리가 GPU 와 갈린다 — 값이 눈에 띄게
    /// 달라지지는 않지만 **두 벌을 비트로 대조할 수 없게 되는 것**이 문제다.
    public static func radialFalloff(distance: Float, hullRadius: Float, exponent: Float) -> Float {
        guard hullRadius > 0 else { return 0 }
        let t = 1 - distance * (1 / hullRadius)
        let base = t < 0 ? 0 : (t > 1 ? 1 : t)
        if base <= 0 { return exponent <= 0 ? 1 : 0 }   // pow(0, 0) = 1 — GPU 와 같은 규약
        return powf(base, exponent)
    }

    /// `volumetricsfront.frag:140` — `smoothstep(VAR_SPOT_PARAMS_OUTER, VAR_SPOT_PARAMS_INNER, cos)`.
    /// GLSL/MSL 과 같은 3차 보간이다. 인자 `cos` 는 **뷰 레이가 아니라**
    /// `dot(normalize(샘플 − 라이트), VAR_SPOT_FORWARD)`(`:139`) — 그게 화면공간 갓레이와
    /// 볼륨 라이트를 가르는 지점이다.
    ///
    /// 호출부는 `inner > outer` 를 보장한다(`SceneDocument.swift` 의 콘 변환기가 `+1e-4` 로
    /// 벌려 둔다). `SceneWELightMath.spotCone`(메시 라이팅 V1 레인)과 **같은 식이되 퇴화 규약만
    /// 다르다** — 저쪽은 `span != 0` 만 막고 음수 span 에서 뒤집힌 보간을 계속하는데, 이쪽은
    /// 이진값으로 접는다. 둘 다 도달 0 인 자리라 값을 맞추지 않고 각자 문서화한다.
    public static func coneFalloff(cosAngle: Float, innerCos: Float, outerCos: Float) -> Float {
        let span = innerCos - outerCos
        guard span > 0 else { return cosAngle >= innerCos ? 1 : 0 }
        let raw = (cosAngle - outerCos) / span
        let t = raw < 0 ? 0 : (raw > 1 ? 1 : raw)
        return t * t * (3 - 2 * t)
    }

    /// `0x140198760`(f32=0.99) — 셰이더가 받는 `VAR_SPOT_PARAMS_RADIUS` 는 `radius × 0.99` 다
    /// (종 무관). 반경 미저작(0 이하)이면 WE 라이트 생성자 기본값 1.0(`0x140190494`)을 쓴다.
    ///
    /// ⚠️ `volumetricsfront.vert:13` 의 0.99 는 **다른 것**이다 — 헐 메시 정점의 **xy 만** 줄이고
    /// (`a_Position * vec3(0.99, 0.99, 1.0)`) `#if POINTLIGHT` 가지(`:11`)에는 **아예 없다**.
    /// 두 0.99 를 한 근거로 묶어 인용하면 안 된다(2026-08-21 셰이더 원문 재확인).
    public static func hullRadius(radius: Float) -> Float { (radius > 0 ? radius : 1) * 0.99 }

    /// `volumetricsfront.frag:119` vs `:121` — POINTLIGHT 만 `maxLightScale` 이 반이다.
    public static func pointLightScale(isPoint: Bool) -> Float { isPoint ? 0.5 : 1 }

    /// `volumetricsfront.frag:115-122` — `maxLightScale`. 곱셈 순서까지 `metalSource` 와 같다
    /// (`intensity × segment × (1/hull) × pointScale`) — `radialFalloff` 와 같은 이유로 역수 곱이다.
    public static func maxLightScale(intensity: Float, segmentLength: Float,
                                     hullRadius: Float, isPoint: Bool) -> Float {
        guard hullRadius > 0 else { return 0 }
        return intensity * segmentLength * (1 / hullRadius) * pointLightScale(isPoint: isPoint)
    }

    /// `volumetricsfront.frag:113` — k 번째 샘플이 구간 [0,1] 의 어디에 앉는가.
    /// 스텝이 `(end-start)/(N+1)` 이고 루프가 **먼저 더한 뒤** 샘플하므로 `(k+1)/(N+1)` 이다
    /// (0-based k). 끝점을 절대 안 밟는 것이 이 분할의 요점이다.
    public static func samplePosition(index: Int, count: Int) -> Float {
        guard count > 0 else { return 0 }
        return Float(index + 1) / Float(count + 1)
    }

    /// `volumetricsfront.frag:190` — 최종 스칼라(색 곱하기 전). `0.1` 이 WE 의 고정 스케일이다.
    /// `VAR_DENSITY` 는 **순수 배수**다(거리 감쇠가 아니다) — 0 이면 WE 도 아무것도 안 그린다.
    public static func finalScale(density: Float, maxLightScale: Float, meanFactor: Float) -> Float {
        density * maxLightScale * meanFactor * 0.1
    }

    // MARK: 프래그먼트 **전체**의 CPU 미러 (`VolumetricLightPass.metalSource` 와 1:1)

    /// `import simd` 없이 쓰는 3벡터 내적. `simd_dot` 은 애플 모듈이라 쓰지 않는다.
    public static func dot3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    /// 위와 같은 이유의 길이.
    public static func length3(_ a: SIMD3<Float>) -> Float { sqrtf(dot3(a, a)) }

    /// 위와 같은 이유의 정규화. 영벡터는 그대로 돌려준다(MSL `normalize` 는 NaN 이지만,
    /// 호출부가 영벡터를 만들 수 없는 자리라 방어값이 픽셀을 바꾸지 않는다).
    public static func normalize3(_ a: SIMD3<Float>) -> SIMD3<Float> {
        let n = length3(a)
        return n > 0 ? a * (1 / n) : a
    }

    /// 픽셀 (x, y) 중심의 NDC. `metalSource` 의 `volumetricVertex` uv 규약과 같은 값이다 —
    /// `uv = ((x+0.5)/W, (y+0.5)/H)`(y 는 **위가 0**), `ndc = (uv.x·2−1, 1−uv.y·2)`.
    ///
    /// > **광축 위에 앉는 픽셀은 없다.** 짝수 해상도(64×64 등)의 가장 가운데 픽셀도 반 픽셀
    /// > (`1/W`) 만큼 비껴 있다. 좁은 콘 + 작은 헐에서는 그 반 픽셀이 픽셀 값을 **몇 배**로
    /// > 바꾼다(§6.1 의 4.44배). GPU 를 검산할 때 `ndc = (0,0)` 을 쓰면 안 되는 이유다.
    /// > 광축 레이를 일부러 보고 싶으면 `width: 1, height: 1` 로 부르면 정확히 (0,0)이 나온다.
    public static func pixelNDC(x: Int, y: Int, width: Int, height: Int) -> (x: Float, y: Float) {
        guard width > 0, height > 0 else { return (0, 0) }
        let u = (Float(x) + 0.5) / Float(width)
        let v = (Float(y) + 0.5) / Float(height)
        return (u * 2 - 1, 1 - v * 2)
    }

    /// `metalSource` 의 `dir` 재구성 — `normalize(fwd + right·(ndc.x·tanHalf·aspect) + up·(ndc.y·tanHalf))`.
    /// `aspect` 가 **x 에만** 붙는 것은 `fov` 가 세로축이기 때문이고, 그 규약은
    /// `Scene3DMath.perspective`(`x = y / aspect`, `y = 1/tan(fovY/2)`)와 같은 출처다.
    ///
    /// WE 자신은 이 자리에서 역투영 행렬을 쓴다(`volumetricsfront.frag:105-111`
    /// `mul(vec4(screenUVDepth, 1.0), g_EffectModelMatrix)` 후 `w` 나눗셈). 우리는 헐 뎁스
    /// 두 패스를 갖고 있지 않아 카메라 기저로 레이를 세운다 — 같은 레이를 다른 경로로 만든다.
    public static func viewRayDirection(ndc: (x: Float, y: Float), fovYDegrees: Float, aspect: Float,
                                        forward: SIMD3<Float>, right: SIMD3<Float>,
                                        up: SIMD3<Float>) -> SIMD3<Float> {
        let tanHalf = tanf(fovYDegrees * Float.pi / 180 * 0.5)
        return normalize3(forward + right * (ndc.x * tanHalf * aspect) + up * (ndc.y * tanHalf))
    }

    /// `metalSource` 의 헐 구간 — 뷰 레이 ↔ 반경 구 교차 + 근/원 평면 클램프.
    /// WE 의 헐 뎁스 2패스(`volumetricsfront.frag:63-74`, `:105-111`)를 해석해로 대체한 자리다.
    ///
    /// **`direction` 이 단위벡터라는 가정**으로 `a = dot(d,d) = 1` 을 접은 축약형이다
    /// (`b = dot(oc,d)`, `c = |oc|² − R²`, `disc = b² − c`). `viewRayDirection` 이 정규화해
    /// 주므로 성립한다 — 정규화 안 된 방향을 넣으면 조용히 틀린다.
    ///
    /// nil = 그 픽셀 기여 0(교차 없음 `disc ≤ 0`, 또는 구간 없음 `exit ≤ enter`).
    /// MSL 쪽 `return float4(0.0)` 과 같은 뜻이고, 그 자리가 WE `:67`/`:70` 의 `clip()` 이다.
    ///
    /// **W-17 단계 1(씬 뎁스 클립)이 여기 들어와 있다.** WE 는 `exit` 을 씬 뎁스로 한 번 더
    /// 자른다(`volumetricsfront.frag:64` `limitDepth = texLoad2D(g_Texture3, …)` + `:71`
    /// `backDepth = min(backDepth, limitDepth)`). `sceneLimit` 이 그 `limitDepth` 를
    /// **레이 파라미터 t 로 환산한 값**이고, `metalSource` 의 `tExit = min(tExit, sceneLimit)`
    /// 과 같은 자리다. nil 이면 종전 그대로(가림 없음) — 클리어된 뎁스(=1.0)는 `farZ` 로 풀리고
    /// `exit` 이 이미 `farZ` 이하라 넣어도 무연산이다.
    public static func hullSpan(eye: SIMD3<Float>, direction: SIMD3<Float>,
                                lightPosition: SIMD3<Float>, hullRadius: Float,
                                nearZ: Float, farZ: Float,
                                sceneLimit: Float? = nil) -> (enter: Float, exit: Float)? {
        let oc = eye - lightPosition
        let b = dot3(oc, direction)
        let c = dot3(oc, oc) - hullRadius * hullRadius
        let disc = b * b - c
        guard disc > 0 else { return nil }
        let sq = sqrtf(disc)
        let enter = max(-b - sq, nearZ)
        var exit = min(-b + sq, farZ)
        if let sceneLimit, sceneLimit < exit { exit = sceneLimit }
        guard exit > enter else { return nil }
        return (enter, exit)
    }

    /// `depth32Float` 뎁스 버퍼 값(= Metal NDC z, `[0,1]`) → **카메라 전방축 거리**.
    /// `Scene3DMath.perspective` 의 역이다 — 그 행렬이 `zz = far/(near-far)` 로
    /// `clip.z = zz·vz + near·zz`, `clip.w = -vz` 를 만들므로 `d = -vz` 에 대해
    /// `ndc = zz·(near-d)/d` 이고, 이를 d 로 풀면 `d = near·far / (far - ndc·(far-near))` 다.
    /// 대수적 검산: `ndc = 0 → d = near`, `ndc = 1 → d = far`.
    ///
    /// **float32 정밀도는 `far/near` 비에 걸린다.** 분모가 `far − ndc·(far−near)` 라 원거리에서
    /// 소거가 심하다. 실측(2026-08-21): `near 1 / far 1000` 은 왕복 상대오차 0, 씬 기본값
    /// `near 0.1 / far 10000` 은 `ndc = 1` 에서 **10138.6**(+1.4%) 이 나온다. 그래도 오차가
    /// **먼 쪽**이라 `min(tExit, ·)` 이 조기 발동하지 않는다 — 이게 안전한 방향이다.
    ///
    /// **클리어값 1.0 이 `farZ` **이상**으로 풀리는 것이 이 함수의 안전성 근거다** — 지오메트리가
    /// 없는 픽셀은 클립이 무연산이 되고(`exit` 이 이미 `farZ` 이하), 그래서 이 기능을 켜도
    /// 지오메트리 없는 기존 픽스처의 골든 값이 한 자리도 안 움직인다.
    /// (`SceneWELightMathTests.testClearedDepthNeverResolvesNearerThanFarPlane` 이 잠근다.)
    public static func viewDepthDistance(ndcDepth: Float, nearZ: Float, farZ: Float) -> Float {
        let denominator = farZ - ndcDepth * (farZ - nearZ)
        guard denominator > 0, nearZ > 0, farZ > nearZ else { return farZ }
        return nearZ * farZ / denominator
    }

    /// 위 전방축 거리를 **뷰 레이 파라미터 t** 로 환산한다. 마치는 `eye + dir·t`(dir 은 단위)로
    /// 도는데 뎁스는 카메라 전방축 투영 거리라, 화면 가장자리 픽셀에서 `t > d` 다.
    /// `cosFromAxis = dot(dir, forward)`(둘 다 단위 → 광축에서 잰 각의 코사인).
    ///
    /// `cosFromAxis` 가 0 이하(뒤쪽/직교 — 정상 절두체에서는 생기지 않는다)면 `farZ` 로 접어
    /// 클립을 무연산으로 만든다. 자르는 쪽으로 틀리면 화면이 통째로 검어지므로, 퇴화는 항상
    /// **안 자르는 쪽**으로 접는다.
    public static func sceneDepthRayLimit(ndcDepth: Float, nearZ: Float, farZ: Float,
                                          cosFromAxis: Float) -> Float {
        let distance = viewDepthDistance(ndcDepth: ndcDepth, nearZ: nearZ, farZ: farZ)
        guard cosFromAxis > 1e-6 else { return farZ }
        return distance / cosFromAxis
    }

    /// `metalSource` 의 `VolumetricUniforms` 와 같은 내용을 CPU 쪽에 담는 입력.
    /// 필드 이름을 셰이더 슬롯에 맞춰 둬야 대조표(`docs/re/volumetric-light.md` §6.2)를
    /// 눈으로 따라갈 수 있다.
    public struct PixelInput {
        public var eye: SIMD3<Float>
        public var forward: SIMD3<Float>
        public var right: SIMD3<Float>
        public var up: SIMD3<Float>
        public var fovYDegrees: Float
        public var aspect: Float
        public var nearZ: Float
        public var farZ: Float
        public var lightPosition: SIMD3<Float>
        /// `VAR_SPOT_FORWARD` — 라이트 → 바깥. `SceneLight3D.forwardLightAxis` 산출물(단위벡터).
        public var lightForward: SIMD3<Float>
        public var density: Float
        public var exponent: Float
        public var intensity: Float
        /// **코사인**이다 — 도(度) 원값이 아니다.
        public var innerCos: Float
        public var outerCos: Float
        /// 씬 저작 `radius`. 0(무저작)이면 `hullRadius(radius:)` 가 WE 기본 1.0 을 대신 쓴다.
        public var radius: Float
        /// 기본값을 **두지 않는다** — 여기에 `VolumetricLightPass.marchSampleCount` 를 적으면
        /// 이 타입이 WapleRender 에 묶인다. 호출부가 그 상수를 그대로 넘기면 된다
        /// (그게 셰이더가 굽는 값이다).
        public var sampleCount: Int
        /// W-17 단계 1: 이 픽셀의 **씬 뎁스 버퍼 값**(`depth32Float` 원값 = Metal NDC z, `[0,1]`).
        /// `metalSource` 가 `sceneDepth.read(uint2(in.position.xy))` 로 읽는 그 수다.
        /// nil = 뎁스를 안 넘긴 호출(클립 없음). 지오메트리가 없는 픽셀의 클리어값 `1.0` 은
        /// `farZ` 로 풀려 클립이 무연산이 되므로, nil 과 1.0 은 결과가 같다.
        public var sceneDepth: Float?

        /// 인자 순서·라벨은 `VolumetricLightPass` 시절 메모버와이즈와 **동일**하다.
        /// (`Tests/WapleRenderTests/VolumetricLightTests.swift` 가 이 시그니처로 부른다 —
        ///  그 파일은 다른 레인 소관이라 소스 호환을 깨지 않는 것이 이관의 조건이었다.)
        /// `sceneDepth` 만 **기본값 있는 마지막 인자**로 뒤에 붙였다 — 기존 호출부는 한 글자도 안 바뀐다.
        public init(eye: SIMD3<Float>, forward: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                    fovYDegrees: Float, aspect: Float, nearZ: Float, farZ: Float,
                    lightPosition: SIMD3<Float>, lightForward: SIMD3<Float>,
                    density: Float, exponent: Float, intensity: Float,
                    innerCos: Float, outerCos: Float, radius: Float, sampleCount: Int,
                    sceneDepth: Float? = nil) {
            self.eye = eye
            self.forward = forward
            self.right = right
            self.up = up
            self.fovYDegrees = fovYDegrees
            self.aspect = aspect
            self.nearZ = nearZ
            self.farZ = farZ
            self.lightPosition = lightPosition
            self.lightForward = lightForward
            self.density = density
            self.exponent = exponent
            self.intensity = intensity
            self.innerCos = innerCos
            self.outerCos = outerCos
            self.radius = radius
            self.sampleCount = sampleCount
            self.sceneDepth = sceneDepth
        }

        /// `VolumetricLightParameters.isPointLight` 와 **같은 판정**(단일 규약).
        /// WE 의 진짜 판정은 종 하나다(`cmp byte [light+0x2c0], 0` `0x1401982fa` ⟺ `light == "lpoint"`) —
        /// Waple 호출부가 종을 안 넘겨 콘 코사인 퇴화값으로 근사한다.
        public var isPoint: Bool { outerCos <= -0.999 }
    }

    /// `volumetricsfront.frag:128-187` = `metalSource` 의 마치 루프. 반환값은 `shadowFactor / N`.
    ///
    /// **닫힌 꼴(`samplePosition`)로 계산하지 않고 `p += step` 으로 누산한다.** WE 도
    /// (`:130` `worldStart.xyz += worldStep`) MSL 도 누산이고, 누산은 반올림이 쌓인다 —
    /// N=8 에서 차이는 1e-7 수준이라 그림은 안 바뀌지만, **비트 대조를 하려면 같은 순서로
    /// 적어야 한다**. `samplePosition` 은 "k번째 샘플이 구간의 어디냐" 를 말하는 해석식으로
    /// 남기고, 실제 적분 경로는 이쪽이 정본이다.
    public static func marchMeanFactor(_ i: PixelInput, direction: SIMD3<Float>,
                                       span: (enter: Float, exit: Float), hullRadius: Float) -> Float {
        guard i.sampleCount > 0, hullRadius > 0 else { return 0 }
        let invHull = 1 / hullRadius
        // `VolumetricLightPass.encode` 가 유니폼에 싣기 전에 하는 클램프를 여기서도 한다 —
        // 음수 지수는 헐 경계(base=0)에서 +inf 가 되어 그 픽셀이 통째로 하얘진다. GPU 가 절대
        // 못 보는 값을 CPU 미러만 보면 그것부터가 두 벌이 갈리는 자리다. WE 자신은 클램프하지
        // 않지만 저작 파스가 무클램프라(`SceneDocument.swift` 의 `volumetricsexponent`) 도달 가능한 입력이다.
        let exponent = max(0, i.exponent)
        let segment = span.exit - span.enter
        let step = direction * (segment / (Float(i.sampleCount) + 1))
        var p = i.eye + direction * span.enter
        var shadowFactor: Float = 0
        for _ in 0..<i.sampleCount {
            p += step
            let lightDelta = p - i.lightPosition
            let dist = length3(lightDelta)
            // WE `:132` — 반경 밖은 정확히 0. `radialFalloff` 도 같은 역수 곱이다.
            let t = 1 - dist * invHull
            let base = t < 0 ? 0 : (t > 1 ? 1 : t)
            let radiusFalloff: Float = base <= 0 ? (exponent <= 0 ? 1 : 0) : powf(base, exponent)
            var spotCookie: Float = 1
            if !i.isPoint {
                // WE `:139-140` — dot(normalize(라이트→샘플), forward) 에 smoothstep(outer, inner, ·).
                // 나눗셈 형태까지 MSL 과 같게 적는다(역수 곱으로 바꾸면 마지막 자리가 갈린다).
                let cosAngle = dot3(lightDelta / max(dist, 1e-6), i.lightForward)
                spotCookie = coneFalloff(cosAngle: cosAngle, innerCos: i.innerCos, outerCos: i.outerCos)
            }
            shadowFactor += radiusFalloff * spotCookie
        }
        return shadowFactor * (1 / Float(i.sampleCount))   // WE `:187` — /= sampleCount
    }

    /// **한 픽셀의 최종 스칼라**(`VAR_COLOR` 를 곱하기 전). `metalSource` 의 `volumetricFragment`
    /// 를 줄 순서 그대로 옮긴 것이라, 두 벌이 갈리면 이 값이 갈린다 — GPU 없이 CPU 에서
    /// 같은 픽셀을 풀어 대조하는 것이 이 함수의 유일한 존재 이유다.
    ///
    /// 흰 라이트(`color = 1 1 1`)면 이 값이 곧 화면 채널값이고, 목적지가 `bgra8Unorm` 이면
    /// `round(saturate(v) × 255)` 가 캡처 PNG 의 바이트다(`writeFramePNG` 는 감마를 안 먹인다 —
    /// `OffscreenCapture.png` 가 `.deviceRGB` 로 원바이트를 그대로 싣는다).
    public static func pixelValue(_ i: PixelInput, x: Int, y: Int, width: Int, height: Int) -> Float {
        let hull = hullRadius(radius: i.radius)
        // `VolumetricLightPass.encode` 의 게이트와 동일.
        guard hull > 0, i.farZ > i.nearZ, i.nearZ > 0 else { return 0 }
        let ndc = pixelNDC(x: x, y: y, width: width, height: height)
        let dir = viewRayDirection(ndc: ndc, fovYDegrees: i.fovYDegrees, aspect: i.aspect,
                                   forward: i.forward, right: i.right, up: i.up)
        // W-17 단계 1 — `metalSource` 의 `tExit = min(tExit, sceneLimit)` 과 같은 순서로 푼다.
        let sceneLimit = i.sceneDepth.map {
            sceneDepthRayLimit(ndcDepth: $0, nearZ: i.nearZ, farZ: i.farZ,
                               cosFromAxis: dot3(dir, i.forward))
        }
        guard let span = hullSpan(eye: i.eye, direction: dir, lightPosition: i.lightPosition,
                                  hullRadius: hull, nearZ: i.nearZ, farZ: i.farZ,
                                  sceneLimit: sceneLimit) else { return 0 }
        let mls = maxLightScale(intensity: i.intensity, segmentLength: span.exit - span.enter,
                                hullRadius: hull, isPoint: i.isPoint)
        let mean = marchMeanFactor(i, direction: dir, span: span, hullRadius: hull)
        return finalScale(density: i.density, maxLightScale: mls, meanFactor: mean)
    }
}
