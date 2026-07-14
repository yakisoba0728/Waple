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

/// 3D 라이트 종류. rawValue 는 MSL `LightU.shadow.z` 타입 플래그와 동일 규약(0/1/2).
enum Scene3DLightKind: Float, Equatable {
    case point = 0, directional = 1, spot = 2
    init?(type: String) {
        switch type.lowercased() {
        case "lpoint": self = .point
        case "ldirectional": self = .directional
        case "lspot": self = .spot
        default: return nil
        }
    }
}

struct Scene3DResolvedLight: Equatable {
    var position: SIMD3<Float>
    var exponent: Float
    var colorRadius: SIMD4<Float>
    var castsShadow: Bool
    var kind: Scene3DLightKind = .point
    /// 월드 forward(+Z blue축 = 광자 진행 방향). directional/spot 만 유효. point 는 미사용.
    var forward: SIMD3<Float> = SIMD3(0, 0, 1)
    /// spot 콘 코사인(축 기준). point/directional 미사용(기본 0 → 셰이더가 kind 로 분기).
    var coneInnerCos: Float = 0
    var coneOuterCos: Float = 0
}

/// MSL `FrameU`와 필드/정렬이 같은 per-frame 3D 라이팅 상수(4×float4).
struct Scene3DFrameUniform {
    var cameraEye: SIMD4<Float>
    var ambient: SIMD4<Float>
    var skylight: SIMD4<Float>
    /// x=활성 라이트 수, y/z=shadow atlas texel 크기, w=receiver depth bias.
    var meta: SIMD4<Float>
}

/// MSL `LightU`와 필드/정렬이 같은 라이트 1개 상수(4×float4).
struct Scene3DLightUniform {
    var positionExponent: SIMD4<Float>
    var colorRadius: SIMD4<Float>
    /// x=shadow array slice(-1이면 비활성), y=shadow VP 시작 인덱스, z=kind(0/1/2), w=spot 콘 inner cos.
    var shadow: SIMD4<Float>
    /// xyz=월드 forward(+Z blue축), w=spot 콘 outer cos. directional/spot 전용.
    var axis: SIMD4<Float>
}

enum Scene3DLighting {
    static let maximumLights = 4

    /// lpoint / ldirectional / lspot 을 월드 공간으로 해석한다. 입력 순서를 보존하고(첫 4개 정책),
    /// 부모가 있으면 그 부모의 현재 월드행렬/가시성을 적용한다.
    ///
    /// 방향 규약(2026-07 확정): scene.json `angles`(라디안) → Scene3DMath 모델행렬(T·Rz·Ry·Rx·S,
    /// 오브젝트와 동일 규약)의 **blue축(+Z, col2)** 이 라이트 forward. 근거: WE 스크립트 API
    /// (`lib.sceneScript.d.ts`) `Mat4.forward() = Blue axis`, `right=Red(+X)`, `up=Green(+Y)`,
    /// `compose = T*R*S`. directional 은 무감쇠(radiance=color×intensity), L=-forward.
    /// directional/spot 섀도우는 스코프 밖 → castShadow 는 point 만 존중(무회귀).
    static func resolveLights(_ lights: [SceneLight3D],
                              nodes: [Int: Scene3DMath.Node]) -> [Scene3DResolvedLight] {
        var result: [Scene3DResolvedLight] = []
        result.reserveCapacity(maximumLights)

        for light in lights where result.count < maximumLights {
            guard let kind = Scene3DLightKind(type: light.type),
                  light.intensity.isFinite,
                  light.exponent.isFinite,
                  light.origin.x.isFinite, light.origin.y.isFinite, light.origin.z.isFinite,
                  light.angles.x.isFinite, light.angles.y.isFinite, light.angles.z.isFinite,
                  light.color.x.isFinite, light.color.y.isFinite, light.color.z.isFinite else { continue }
            // point/spot 은 유한 감쇠 반경 필요. directional 은 무감쇠라 반경 무관.
            if kind != .directional {
                guard light.radius.isFinite, light.radius > PointShadowMath.minimumRadius else { continue }
            }

            // 라이트 자체 회전 포함 로컬행렬(scale=1: 위치·방향에 스케일 오염 방지) → 부모 체인 합성.
            // col3=위치, col2=forward. point 위치는 회전 무관(T·R·S 의 col3 = origin)이라 무회귀.
            let localMatrix = Scene3DMath.modelMatrix(
                origin: SIMD3(light.origin.x, light.origin.y, light.origin.z),
                angles: SIMD3(light.angles.x, light.angles.y, light.angles.z),
                scale: SIMD3(1, 1, 1))
            let worldMatrix: simd_float4x4
            if let parent = light.parent {
                guard let transform = Scene3DMath.worldMatrix(id: parent, nodes: nodes),
                      transform.visible else { continue }
                worldMatrix = transform.matrix * localMatrix
            } else {
                worldMatrix = localMatrix
            }
            let position = SIMD3(worldMatrix.columns.3.x, worldMatrix.columns.3.y, worldMatrix.columns.3.z)
            let forward = normalizedOr(
                SIMD3(worldMatrix.columns.2.x, worldMatrix.columns.2.y, worldMatrix.columns.2.z),
                SIMD3(0, 0, 1))
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite,
                  forward.x.isFinite, forward.y.isFinite, forward.z.isFinite else { continue }

            var resolved = Scene3DResolvedLight(
                position: position,
                exponent: light.exponent,
                colorRadius: SIMD4(
                    light.color.x * light.intensity,
                    light.color.y * light.intensity,
                    light.color.z * light.intensity,
                    light.radius),
                // directional/spot 섀도우는 스코프 밖 → point 만 캐스트.
                castsShadow: kind == .point && light.castShadow,
                kind: kind,
                forward: forward)
            if kind == .spot {
                let cone = spotConeCosines(inner: light.innerCone, outer: light.outerCone)
                resolved.coneInnerCos = cone.inner
                resolved.coneOuterCos = cone.outer
            }
            result.append(resolved)
        }
        return result
    }

    /// spot innercone/outercone(전각, 도) → 축 기준 half-angle 코사인.
    /// half-angle 규약(cone/2) 채택: WE 에디터 라벨은 단위 미명시라 표준 전각 해석.
    // ponytail: half vs full 미확정(코퍼스 spot 은 전부 지오메트리 범위 밖이라 육안 보정 불가).
    //           full-angle 이면 `* 0.5` 를 제거. 지오메트리 도달 spot 실물 확보 시 3477054430 로 보정.
    static func spotConeCosines(inner: Float, outer: Float) -> (inner: Float, outer: Float) {
        guard outer.isFinite, outer > 0 else { return (1, -1) }  // 콘 데이터 없음 → 반구 그라디언트(셰이더 (cosAngle+1)/2 → 축상 1·수직 0.5·후방 0). 전방향 통과 아님.
        let toHalfRadians = Float.pi / 180 * 0.5
        let cosOuter = cos(max(0, outer) * toHalfRadians)
        let cosInnerRaw = inner.isFinite && inner > 0 ? cos(inner * toHalfRadians) : 1
        // inner 는 outer 보다 좁아야(코사인 큼) 스무드스텝이 0→1 로 증가.
        return (max(cosInnerRaw, cosOuter + 1e-4), cosOuter)
    }

    /// 영벡터/비유한 방어 정규화(셰이더 normalizedOr 과 동일 시맨틱).
    private static func normalizedOr(_ value: SIMD3<Float>, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(value)
        return lengthSquared > 1e-12 && lengthSquared.isFinite ? value / sqrt(lengthSquared) : fallback
    }

    /// 활성 라이트 순서를 유지하면서 shadow caster에만 조밀한 array slice를 부여한다.
    static func packLights(_ lights: [Scene3DResolvedLight]) -> [Scene3DLightUniform] {
        var packed = [Scene3DLightUniform](repeating: Scene3DLightUniform(
            positionExponent: .zero,
            colorRadius: .zero,
            shadow: SIMD4(-1, -1, 0, 0),
            axis: SIMD4(0, 0, 1, 0)), count: maximumLights)
        var nextShadowSlice: Float = 0
        for (index, light) in lights.prefix(maximumLights).enumerated() {
            let slice = light.castsShadow ? nextShadowSlice : -1
            if light.castsShadow { nextShadowSlice += 1 }
            packed[index] = Scene3DLightUniform(
                positionExponent: SIMD4(light.position.x, light.position.y, light.position.z, light.exponent),
                colorRadius: light.colorRadius,
                shadow: SIMD4(slice, slice >= 0 ? slice * 6 : -1, light.kind.rawValue, light.coneInnerCos),
                axis: SIMD4(light.forward.x, light.forward.y, light.forward.z, light.coneOuterCos))
        }
        return packed
    }

    static func shadowSliceCount(_ packed: [Scene3DLightUniform]) -> Int {
        packed.reduce(into: 0) { count, light in
            if light.shadow.x >= 0 { count = max(count, Int(light.shadow.x) + 1) }
        }
    }

    /// shadow slice/VP 만 끈다(x/y). kind/cone(z/w)·axis 는 보존해야 directional/spot 셰이딩이 유지된다.
    static func disableShadow(at index: Int, in lights: inout [Scene3DLightUniform]) {
        guard lights.indices.contains(index) else { return }
        lights[index].shadow.x = -1
        lights[index].shadow.y = -1
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
