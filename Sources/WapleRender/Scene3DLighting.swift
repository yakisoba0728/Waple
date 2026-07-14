import Foundation
import simd
import WapleCore

/// `generic4`의 상수형 metallic/roughness 머티리얼 값.
/// PBR mask/normal map은 별도 후속 범위이며 여기서는 네이티브 기본값을 보존한다.
struct Scene3DMaterialValues: Equatable {
    var roughness: Float = 0.7
    var metallic: Float = 0
    var specularTint = SIMD3<Float>(1, 1, 1)

    static func parse(_ constants: [String: Any]?) -> Self {
        guard let constants else { return Self() }
        let values = Dictionary(uniqueKeysWithValues: constants.map { ($0.key.lowercased(), $0.value) })
        var result = Self()
        if let roughness = numbers(values["roughness"])?.first { result.roughness = roughness }
        if let metallic = numbers(values["metallic"])?.first { result.metallic = metallic }
        if let tint = numbers(values["speculartint"]), tint.count >= 3 {
            result.specularTint = SIMD3(tint[0], tint[1], tint[2])
        }
        return result
    }

    private static func numbers(_ value: Any?) -> [Float]? {
        switch value {
        case let value as Float:
            return [value]
        case let value as Double:
            return [Float(value)]
        case let value as Int:
            return [Float(value)]
        case let value as NSNumber:
            return [value.floatValue]
        case let value as String:
            let parsed = value.split(whereSeparator: { $0.isWhitespace }).compactMap { Float($0) }
            return parsed.isEmpty ? nil : parsed
        case let value as [Any]:
            let parsed = value.compactMap { numbers($0)?.first }
            return parsed.isEmpty ? nil : parsed
        case let value as [String: Any]:
            return numbers(value["value"])
        default:
            return nil
        }
    }
}

struct Scene3DResolvedLight: Equatable {
    var position: SIMD3<Float>
    var exponent: Float
    var colorRadius: SIMD4<Float>
    var castsShadow: Bool
}

/// MSL `FrameU`와 필드/정렬이 같은 per-frame 3D 라이팅 상수(4×float4).
struct Scene3DFrameUniform {
    var cameraEye: SIMD4<Float>
    var ambient: SIMD4<Float>
    var skylight: SIMD4<Float>
    /// x=활성 라이트 수, y/z=shadow atlas texel 크기, w=receiver depth bias.
    var meta: SIMD4<Float>
}

/// MSL `LightU`와 필드/정렬이 같은 라이트 1개 상수(3×float4).
struct Scene3DLightUniform {
    var positionExponent: SIMD4<Float>
    var colorRadius: SIMD4<Float>
    /// x=shadow array slice(-1이면 비활성), y=shadow VP 시작 인덱스.
    var shadow: SIMD4<Float>
}

enum Scene3DLighting {
    static let maximumLights = 4

    /// 현 시점에 CPU 규약이 확정된 point만 월드 공간으로 해석한다.
    /// 입력 순서를 보존하고, 부모가 있으면 그 부모의 현재 월드행렬/가시성을 적용한다.
    static func resolvePointLights(_ lights: [SceneLight3D],
                                   nodes: [Int: Scene3DMath.Node]) -> [Scene3DResolvedLight] {
        var result: [Scene3DResolvedLight] = []
        result.reserveCapacity(maximumLights)

        for light in lights where result.count < maximumLights {
            guard light.type.caseInsensitiveCompare("lpoint") == .orderedSame,
                  light.radius.isFinite, light.radius > 0,
                  light.exponent.isFinite, light.intensity.isFinite,
                  light.origin.x.isFinite, light.origin.y.isFinite, light.origin.z.isFinite,
                  light.color.x.isFinite, light.color.y.isFinite, light.color.z.isFinite else { continue }

            let local = SIMD4<Float>(light.origin.x, light.origin.y, light.origin.z, 1)
            let world: SIMD4<Float>
            if let parent = light.parent {
                guard let transform = Scene3DMath.worldMatrix(id: parent, nodes: nodes),
                      transform.visible else { continue }
                world = transform.matrix * local
            } else {
                world = local
            }
            guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { continue }

            result.append(Scene3DResolvedLight(
                position: SIMD3(world.x, world.y, world.z),
                exponent: light.exponent,
                colorRadius: SIMD4(
                    light.color.x * light.intensity,
                    light.color.y * light.intensity,
                    light.color.z * light.intensity,
                    light.radius),
                castsShadow: light.castShadow))
        }
        return result
    }
}
