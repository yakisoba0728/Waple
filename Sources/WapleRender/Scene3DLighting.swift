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
        // case-only 중복 키(예: "Alpha"+"alpha")는 원본 키 정렬 후 첫 키를 채택해 결정적으로 병합한다.
        // (uniquingKeysWith 클로저는 값만 받으므로 정렬 없이는 dict 순회 비결정성이 런마다 결과를 가른다.)
        let values = Dictionary(
            constants.sorted { $0.key < $1.key }.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first })
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
                  light.radius.isFinite, light.radius > PointShadowMath.minimumRadius,
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

    /// 활성 라이트 순서를 유지하면서 shadow caster에만 조밀한 array slice를 부여한다.
    static func packLights(_ lights: [Scene3DResolvedLight]) -> [Scene3DLightUniform] {
        var packed = [Scene3DLightUniform](repeating: Scene3DLightUniform(
            positionExponent: .zero,
            colorRadius: .zero,
            shadow: SIMD4(-1, -1, 0, 0)), count: maximumLights)
        var nextShadowSlice: Float = 0
        for (index, light) in lights.prefix(maximumLights).enumerated() {
            let slice = light.castsShadow ? nextShadowSlice : -1
            if light.castsShadow { nextShadowSlice += 1 }
            packed[index] = Scene3DLightUniform(
                positionExponent: SIMD4(light.position.x, light.position.y, light.position.z, light.exponent),
                colorRadius: light.colorRadius,
                shadow: SIMD4(slice, slice >= 0 ? slice * 6 : -1, 0, 0))
        }
        return packed
    }

    static func shadowSliceCount(_ packed: [Scene3DLightUniform]) -> Int {
        packed.reduce(into: 0) { count, light in
            if light.shadow.x >= 0 { count = max(count, Int(light.shadow.x) + 1) }
        }
    }

    static func disableShadow(at index: Int, in lights: inout [Scene3DLightUniform]) {
        guard lights.indices.contains(index) else { return }
        lights[index].shadow = SIMD4(-1, -1, 0, 0)
    }
}

/// point shadow cube의 네이티브 dominant-axis face 순서와 2×3 셀 배치.
enum PointShadowMath {
    /// 이 이하 반경은 안정적인 depth 범위를 만들 수 없는 퇴화 광원으로 취급한다.
    static let minimumRadius: Float = 1e-4
    static let faceResolution = 512
    static let atlasColumns = 2
    static let atlasRows = 3
    static let viewportCompensation: Float = 0.49

    static func faceIndex(_ delta: SIMD3<Float>) -> Int {
        let absolute = simd_abs(delta)
        if absolute.x >= absolute.y && absolute.x >= absolute.z {
            return delta.x >= 0 ? 0 : 1
        }
        if absolute.y >= absolute.x && absolute.y >= absolute.z {
            return delta.y >= 0 ? 2 : 3
        }
        return delta.z >= 0 ? 4 : 5
    }

    static func atlasCell(_ face: Int) -> SIMD2<Int> {
        switch face {
        case 0: return SIMD2(0, 0)
        case 1: return SIMD2(1, 0)
        case 2: return SIMD2(0, 1)
        case 3: return SIMD2(1, 1)
        case 4: return SIMD2(0, 2)
        default: return SIMD2(1, 2)
        }
    }

    static func faceViewProjections(position: SIMD3<Float>, radius: Float) -> [simd_float4x4] {
        guard let near = nearPlane(radius: radius) else { return [] }
        let directions: [SIMD3<Float>] = [
            SIMD3(1, 0, 0), SIMD3(-1, 0, 0),
            SIMD3(0, 1, 0), SIMD3(0, -1, 0),
            SIMD3(0, 0, 1), SIMD3(0, 0, -1),
        ]
        let up: [SIMD3<Float>] = [
            SIMD3(0, -1, 0), SIMD3(0, -1, 0),
            SIMD3(0, 0, 1), SIMD3(0, 0, -1),
            SIMD3(0, -1, 0), SIMD3(0, -1, 0),
        ]
        let projection = Scene3DMath.perspective(fovYDegrees: 90, aspect: 1, nearZ: near, farZ: radius)
        return zip(directions, up).map { direction, upVector in
            projection * Scene3DMath.lookAt(eye: position, center: position + direction, up: upVector)
        }
    }

    static func nearPlane(radius: Float) -> Float? {
        guard radius.isFinite, radius > minimumRadius else { return nil }
        // [Waple stability policy] native CPU near 값은 미확정. 반경에 비례시키되 항상 far보다 작게 둔다.
        let preferred = max(minimumRadius, min(0.05, radius * 0.01))
        return min(preferred, radius * 0.5)
    }
}
