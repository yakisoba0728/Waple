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

    /// tube(kind 4): 세그먼트 최근접점을 광원점으로 하는 유한광 — WE PerformLighting_V1 tube 분기
    /// (A2-pbr-lighting.md §4.4: shadowFactor=1.0 무섀도우, radius=Color.w, exponent=OriginA.w).
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
    /// WE 2.8.42 HLSL lane finite-light falloff(#define HLSL 1 크로스컴파일 — wallpaper64.exe @0x485698):
    /// pow(falloff + 1.17549435e-38, exponent), 반경 컷오프 없음 — exponent=0 이면 반경 무관 1.0(전역 무감쇠).
    /// GPU MSL 2곳(Mesh3DShaders/QuadShaders)과 동일 수식(CPU↔GPU 비트 일치 규약).
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
