import XCTest
import simd
@testable import WapleCore
@testable import WapleRender

final class Scene3DLightingTests: XCTestCase {
    private func resolved(castsShadow: Bool,
                          position: SIMD3<Float> = .zero) -> Scene3DResolvedLight {
        Scene3DResolvedLight(
            position: position,
            exponent: 2,
            colorRadius: SIMD4(1, 0.5, 0.25, 10),
            castsShadow: castsShadow)
    }

    private func light(id: Int,
                       type: String,
                       origin: SIMD3<Float>,
                       parent: Int?,
                       radius: Float = 20,
                       intensity: Float = 2,
                       exponent: Float = 3,
                       angles: SIMD3<Float> = .zero,
                       innerCone: Float = 0,
                       outerCone: Float = 0,
                       castsShadow: Bool = false) -> SceneLight3D {
        SceneLight3D(
            id: id,
            name: "light-\(id)",
            type: type,
            origin: Vec3(x: origin.x, y: origin.y, z: origin.z),
            angles: Vec3(x: angles.x, y: angles.y, z: angles.z),
            color: Vec3(x: 0.25, y: 0.5, z: 0.75),
            radius: radius,
            intensity: intensity,
            exponent: exponent,
            innerCone: innerCone,
            outerCone: outerCone,
            castShadow: castsShadow,
            parent: parent)
    }

    private func assertVec(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>,
                           _ file: StaticString = #filePath, _ line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: 1e-5, file: file, line: line)
    }

    func testMaterialDefaultsAndAuthoredValuesArePreserved() {
        XCTAssertEqual(
            Scene3DMaterialValues.parse(nil),
            Scene3DMaterialValues(roughness: 0.7, metallic: 0, specularTint: SIMD3(1, 1, 1)))

        let authored = Scene3DMaterialValues.parse([
            "roughness": 5.0,
            "metallic": 0.25,
            "speculartint": "0.2 0.4 0.6",
        ])
        XCTAssertEqual(authored.roughness, 5)
        XCTAssertEqual(authored.metallic, 0.25)
        XCTAssertEqual(authored.specularTint, SIMD3(0.2, 0.4, 0.6))
    }

    func testMaterialParserUnwrapsScriptValueObjects() {
        let authored = Scene3DMaterialValues.parse([
            "roughness": ["value": 0.35],
            "metallic": ["value": 0.6],
            "speculartint": ["value": "0.9 0.8 0.7"],
        ])
        XCTAssertEqual(authored.roughness, 0.35)
        XCTAssertEqual(authored.metallic, 0.6)
        XCTAssertEqual(authored.specularTint, SIMD3(0.9, 0.8, 0.7))
    }

    func testMaterialParserMergesCaseOnlyDuplicateKeysDeterministically() {
        // 실코퍼스 3470948192 DefaultMaterial: "Alpha"+"alpha", "Color"+"color" 공존.
        // 수정 전엔 lowercased 후 중복 키로 Dictionary(uniqueKeysWithValues:)가 SIGTRAP(exit 133).
        let corpus = Scene3DMaterialValues.parse([
            "Alpha": 1,
            "Color": "1.00000 1.00000 1.00000",
            "alpha": 1,
            "color": "0.00000 0.00000 0.00000",
            "metallic": 1,
            "roughness": 0.6,
        ])
        XCTAssertEqual(corpus.roughness, 0.6, accuracy: 1e-6)
        XCTAssertEqual(corpus.metallic, 1)
        XCTAssertEqual(corpus.specularTint, SIMD3(1, 1, 1))

        // 결정성 잠금: 읽는 키가 case-only 중복이고 값이 다르면 정렬상 첫 원본 키("Roughness")를 채택.
        let tie = Scene3DMaterialValues.parse(["Roughness": 0.2, "roughness": 0.9])
        XCTAssertEqual(tie.roughness, 0.2, accuracy: 1e-6)
    }

    func testNormalMatrixHandlesNonUniformScaleAndSingularFallback() {
        let model = Scene3DMath.modelMatrix(
            origin: .zero,
            angles: .zero,
            scale: SIMD3(2, 1, 1))
        let transformed = Scene3DMath.normalMatrix4x4(model) * SIMD4<Float>(1, 1, 0, 0)
        let normal = simd_normalize(SIMD3(transformed.x, transformed.y, transformed.z))
        XCTAssertEqual(normal.x, 0.4472136, accuracy: 1e-5)
        XCTAssertEqual(normal.y, 0.8944272, accuracy: 1e-5)

        let singular = Scene3DMath.modelMatrix(
            origin: .zero,
            angles: .zero,
            scale: SIMD3(0, 1, 1))
        let fallback = Scene3DMath.normalMatrix4x4(singular)
        XCTAssertTrue(fallback.columns.0.x.isFinite)
        XCTAssertEqual(fallback, matrix_identity_float4x4)
    }

    func testLightsApplyParentTransformClassifyTypesAndLimitFour() {
        let nodes: [Int: Scene3DMath.Node] = [
            9: .init(
                origin: SIMD3(10, 0, 0),
                angles: SIMD3(0, .pi / 2, 0),
                scale: SIMD3(1, 1, 1),
                parent: nil,
                visible: true),
        ]
        let lights = [
            light(id: 0, type: "lspot", origin: .zero, parent: nil),
            light(id: 1, type: "lpoint", origin: SIMD3(1, 0, 0), parent: 9, castsShadow: true),
            light(id: 2, type: "LDIRECTIONAL", origin: SIMD3(2, 0, 0), parent: nil),
            light(id: 3, type: "lpoint", origin: SIMD3(3, 0, 0), parent: nil),
            light(id: 4, type: "lpoint", origin: SIMD3(4, 0, 0), parent: nil),
            light(id: 5, type: "lpoint", origin: SIMD3(5, 0, 0), parent: nil),
        ]

        let resolved = Scene3DLighting.resolveLights(lights, nodes: nodes)

        // 모든 타입이 씬 순서대로 분류되고 첫 4개만 통과.
        XCTAssertEqual(resolved.count, 4)
        XCTAssertEqual(resolved.map { $0.kind }, [.spot, .point, .directional, .point])
        // 부모 회전(Ry90°)이 point 위치에 적용: (1,0,0) → (10,0,-1).
        XCTAssertEqual(resolved[1].position.x, 10, accuracy: 1e-5)
        XCTAssertEqual(resolved[1].position.y, 0, accuracy: 1e-5)
        XCTAssertEqual(resolved[1].position.z, -1, accuracy: 1e-5)
        XCTAssertEqual(resolved.map { $0.position.x }, [0, 10, 2, 3])
        // point 만 섀도우 캐스트(directional/spot 은 스코프 밖 → false).
        XCTAssertTrue(resolved[1].castsShadow)
        XCTAssertFalse(resolved[0].castsShadow)
        XCTAssertEqual(resolved[0].colorRadius, SIMD4(0.5, 1, 1.5, 20))
    }

    func testPointLightsSkipInvalidRadiusAndInvisibleOrMissingParents() {
        let nodes: [Int: Scene3DMath.Node] = [
            1: .init(origin: .zero, angles: .zero, scale: SIMD3(repeating: 1), parent: nil, visible: false),
        ]
        let lights = [
            light(id: 1, type: "lpoint", origin: .zero, parent: nil, radius: 0),
            light(id: 2, type: "lpoint", origin: .zero, parent: 1),
            light(id: 3, type: "lpoint", origin: .zero, parent: 999),
            light(id: 4, type: "lpoint", origin: SIMD3(4, 5, 6), parent: nil),
        ]

        let resolved = Scene3DLighting.resolveLights(lights, nodes: nodes)

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].position, SIMD3(4, 5, 6))
    }

    func testPointShadowFaceAndAtlasCellsMatchNativeOrder() {
        XCTAssertEqual(PointShadowMath.faceIndex(SIMD3(2, 1, 1)), 0)
        XCTAssertEqual(PointShadowMath.faceIndex(SIMD3(-2, 1, 1)), 1)
        XCTAssertEqual(PointShadowMath.faceIndex(SIMD3(1, 2, 1)), 2)
        XCTAssertEqual(PointShadowMath.faceIndex(SIMD3(1, -2, 1)), 3)
        XCTAssertEqual(PointShadowMath.faceIndex(SIMD3(1, 1, 2)), 4)
        XCTAssertEqual(PointShadowMath.faceIndex(SIMD3(1, 1, -2)), 5)
        XCTAssertEqual(
            (0..<6).map(PointShadowMath.atlasCell),
            [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1),
             SIMD2(1, 1), SIMD2(0, 2), SIMD2(1, 2)])
    }

    func testPointShadowDominantAxisTiesMatchNativePriority() {
        XCTAssertEqual(PointShadowMath.faceIndex(SIMD3(1, 1, 1)), 0, "X wins an XYZ tie")
        XCTAssertEqual(PointShadowMath.faceIndex(SIMD3(0, 1, 1)), 2, "Y wins a YZ tie")
    }

    func testShadowSlicesAreDenseOnlyForCastingLights() {
        let packed = Scene3DLighting.packLights([
            resolved(castsShadow: true, position: SIMD3(1, 0, 0)),
            resolved(castsShadow: false, position: SIMD3(2, 0, 0)),
            resolved(castsShadow: true, position: SIMD3(3, 0, 0)),
        ])

        XCTAssertEqual(packed.map { $0.shadow.x }, [0, -1, 1, -1])
        XCTAssertEqual(packed.map { $0.shadow.y }, [0, -1, 6, -1])
        XCTAssertEqual(packed[0].positionExponent, SIMD4(1, 0, 0, 2))
        XCTAssertEqual(packed[1].colorRadius, SIMD4(1, 0.5, 0.25, 10))
        XCTAssertEqual(Scene3DLighting.shadowSliceCount(packed), 2)
    }

    func testFailedShadowLightCanBeDisabledWithoutAffectingOtherSlices() {
        var packed = Scene3DLighting.packLights([
            resolved(castsShadow: true, position: SIMD3(1, 0, 0)),
            resolved(castsShadow: true, position: SIMD3(2, 0, 0)),
        ])

        Scene3DLighting.disableShadow(at: 0, in: &packed)

        XCTAssertEqual(packed[0].shadow, SIMD4(-1, -1, 0, 0))
        XCTAssertEqual(packed[1].shadow.x, 1)
        XCTAssertEqual(packed[1].shadow.y, 6)
    }

    func testPointShadowNearPlaneAlwaysPrecedesAcceptedRadius() throws {
        XCTAssertNil(PointShadowMath.nearPlane(radius: PointShadowMath.minimumRadius))
        let radius = PointShadowMath.minimumRadius * 2
        let near = try XCTUnwrap(PointShadowMath.nearPlane(radius: radius))
        XCTAssertGreaterThan(near, 0)
        XCTAssertLessThan(near, radius)

        let tiny = light(
            id: 10, type: "lpoint", origin: .zero, parent: nil,
            radius: PointShadowMath.minimumRadius)
        XCTAssertTrue(Scene3DLighting.resolveLights([tiny], nodes: [:]).isEmpty)
    }

    func testLightForwardIsBlueAxisOfEulerRotation() {
        // 방향 규약 잠금: forward = 월드행렬 blue축(+Z, R=Rz·Ry·Rx). WE Mat4.forward()="Blue axis".
        func forward(_ angles: SIMD3<Float>) -> SIMD3<Float> {
            let d = light(id: 1, type: "ldirectional", origin: .zero, parent: nil,
                          radius: 0, angles: angles)
            let resolved = Scene3DLighting.resolveLights([d], nodes: [:])
            XCTAssertEqual(resolved.count, 1)  // directional 은 무감쇠 → radius 0 이어도 통과
            return resolved[0].forward
        }
        assertVec(forward(.zero), SIMD3(0, 0, 1))                 // 회전 없음 → +Z
        assertVec(forward(SIMD3(0, .pi / 2, 0)), SIMD3(1, 0, 0))  // yaw +90°(Y) → +X
        assertVec(forward(SIMD3(.pi / 2, 0, 0)), SIMD3(0, -1, 0)) // pitch +90°(X) → -Y
    }

    func testDirectionalRadianceIsColorTimesIntensityWithoutRadius() {
        let d = light(id: 1, type: "ldirectional", origin: .zero, parent: nil,
                      radius: 0, intensity: 5)
        let resolved = Scene3DLighting.resolveLights([d], nodes: [:])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].kind, .directional)
        // radiance(rgb) = color × intensity; 무감쇠라 셰이더가 colorRadius.w(반경) 를 안 쓴다.
        XCTAssertEqual(resolved[0].colorRadius.x, 0.25 * 5, accuracy: 1e-5)
        XCTAssertEqual(resolved[0].colorRadius.y, 0.5 * 5, accuracy: 1e-5)
        XCTAssertEqual(resolved[0].colorRadius.z, 0.75 * 5, accuracy: 1e-5)
    }

    func testSpotConeCosinesMapFullConeAnglesToHalfAngleCosines() {
        let cone = Scene3DLighting.spotConeCosines(inner: 20, outer: 30)
        // 전각 30°→half 15°, 20°→half 10°.
        XCTAssertEqual(cone.outer, cos(15 * .pi / 180), accuracy: 1e-5)
        XCTAssertEqual(cone.inner, cos(10 * .pi / 180), accuracy: 1e-5)
        XCTAssertGreaterThan(cone.inner, cone.outer)  // inner 가 좁아 코사인 큼
        // 축에서 10°(half-inner) 방향은 inner 콘 안 → 완전 조명(코사인 ≥ inner).
        XCTAssertGreaterThanOrEqual(cos(10 * Float.pi / 180), cone.inner - 1e-6)
        // 축에서 20°(> half-outer 15°) 방향은 outer 콘 밖 → 무조명(코사인 < outer).
        XCTAssertLessThan(cos(20 * Float.pi / 180), cone.outer)
        // 콘 데이터 없음(0) → (1,-1): 셰이더 (cosAngle+1)/2 반구 그라디언트 폴백 곡선을 이 유닛이 잠금.
        // 콘 게이팅 없는 광역 조명(가장자리 도달)은 픽셀로도 회귀 가드 —
        // Scene3DPBRShadowRenderTests.testSpotWithoutConeDataUsesHemisphereGradientFallback.
        let none = Scene3DLighting.spotConeCosines(inner: 0, outer: 0)
        XCTAssertEqual(none.inner, 1)
        XCTAssertEqual(none.outer, -1)
    }

    func testPackLightsEncodesKindForwardAndCone() {
        let spot = Scene3DResolvedLight(
            position: SIMD3(1, 2, 3), exponent: 2, colorRadius: SIMD4(1, 1, 1, 10),
            castsShadow: false, kind: .spot, forward: SIMD3(0, 0, 1),
            coneInnerCos: 0.98, coneOuterCos: 0.96)
        let directional = Scene3DResolvedLight(
            position: .zero, exponent: 1, colorRadius: SIMD4(2, 2, 2, 0),
            castsShadow: false, kind: .directional, forward: SIMD3(1, 0, 0))
        let packed = Scene3DLighting.packLights([spot, directional])
        // spot: kind=2, inner cos in shadow.w, forward+outer cos in axis.
        XCTAssertEqual(packed[0].shadow.z, Scene3DLightKind.spot.rawValue)
        XCTAssertEqual(packed[0].shadow.w, 0.98, accuracy: 1e-6)
        XCTAssertEqual(packed[0].axis, SIMD4(0, 0, 1, 0.96))
        XCTAssertEqual(packed[0].shadow.x, -1)  // 비캐스트
        // directional: kind=1, forward in axis.xyz.
        XCTAssertEqual(packed[1].shadow.z, Scene3DLightKind.directional.rawValue)
        XCTAssertEqual(packed[1].axis.x, 1, accuracy: 1e-6)
    }

    func testPointShadowViewProjectionsAreFiniteAndMapFaceCenters() {
        let position = SIMD3<Float>(3, 4, 5)
        let matrices = PointShadowMath.faceViewProjections(position: position, radius: 20)
        XCTAssertEqual(matrices.count, 6)
        let directions: [SIMD3<Float>] = [
            SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0),
            SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1),
        ]
        for (index, direction) in directions.enumerated() {
            let clip = matrices[index] * SIMD4<Float>(position + direction, 1)
            XCTAssertTrue(clip.x.isFinite && clip.y.isFinite && clip.z.isFinite && clip.w.isFinite)
            XCTAssertEqual(clip.x / clip.w, 0, accuracy: 1e-5)
            XCTAssertEqual(clip.y / clip.w, 0, accuracy: 1e-5)
        }
    }
}
