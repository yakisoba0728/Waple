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
    /// P1 GLSL finite-light falloff. Radius boundary remains hard-zero even when exponent is zero.
    static func finiteLightFalloff(distance: Float, radius: Float, exponent: Float) -> Float {
        guard radius > 0 else { return 0 }
        let falloff = max(0, min(1, 1 - distance / radius))
        let epsilon: Float = 6.103515625e-5
        return falloff >= epsilon ? powf(falloff + epsilon, exponent) : 0
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
        for i in 0..<min(uniforms.count, 4) {
            let position = uniforms.positions[i]
            let colorRadius = uniforms.colorRadius[i]
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
