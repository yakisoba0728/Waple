import Foundation
import simd

/// `genericimage4` / `common_pbr_2.h`의 Cook-Torrance 코어를 Metal `f_lit`과 같은 순서로 미러한다.
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
/// 0x140168000–0x14016b154, 조각 문자열 0x14048be50–0x14048cfd0) 대 `PerformLighting_Deprecated`
/// (generic3.frag:87-166) 로 갈린다. 우리 스톡 메시 셰이더는 V1 만 이식했다.
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
        public static let exponent: Float = 2
        public static let innerConeDegrees: Float = 20
        public static let outerConeDegrees: Float = 30
        public static let density: Float = 2
        public static let volumetricsExponent: Float = 1
        public static let cascadeDistances = SIMD3<Float>(3, 10, 100)
        public static let lightSourceSize: Float = 0
    }
}
