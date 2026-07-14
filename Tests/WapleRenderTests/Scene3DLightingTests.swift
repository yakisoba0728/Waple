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
                       castsShadow: Bool = false) -> SceneLight3D {
        SceneLight3D(
            id: id,
            name: "light-\(id)",
            type: type,
            origin: Vec3(x: origin.x, y: origin.y, z: origin.z),
            angles: Vec3(x: 0, y: 0, z: 0),
            color: Vec3(x: 0.25, y: 0.5, z: 0.75),
            radius: radius,
            intensity: intensity,
            exponent: exponent,
            castShadow: castsShadow,
            parent: parent)
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

    func testPointLightsApplyParentTransformSkipUnknownAndLimitFour() {
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
            light(id: 2, type: "LPOINT", origin: SIMD3(2, 0, 0), parent: nil),
            light(id: 3, type: "lpoint", origin: SIMD3(3, 0, 0), parent: nil),
            light(id: 4, type: "lpoint", origin: SIMD3(4, 0, 0), parent: nil),
            light(id: 5, type: "lpoint", origin: SIMD3(5, 0, 0), parent: nil),
        ]

        let resolved = Scene3DLighting.resolvePointLights(lights, nodes: nodes)

        XCTAssertEqual(resolved.count, 4)
        XCTAssertEqual(resolved[0].position.x, 10, accuracy: 1e-5)
        XCTAssertEqual(resolved[0].position.y, 0, accuracy: 1e-5)
        XCTAssertEqual(resolved[0].position.z, -1, accuracy: 1e-5)
        XCTAssertEqual(resolved.map { $0.position.x }, [10, 2, 3, 4])
        XCTAssertEqual(resolved[0].colorRadius, SIMD4(0.5, 1, 1.5, 20))
        XCTAssertEqual(resolved[0].exponent, 3)
        XCTAssertTrue(resolved[0].castsShadow)
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

        let resolved = Scene3DLighting.resolvePointLights(lights, nodes: nodes)

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

    func testPointShadowNearPlaneAlwaysPrecedesAcceptedRadius() {
        XCTAssertNil(PointShadowMath.nearPlane(radius: PointShadowMath.minimumRadius))
        let radius = PointShadowMath.minimumRadius * 2
        let near = try! XCTUnwrap(PointShadowMath.nearPlane(radius: radius))
        XCTAssertGreaterThan(near, 0)
        XCTAssertLessThan(near, radius)

        let tiny = light(
            id: 10, type: "lpoint", origin: .zero, parent: nil,
            radius: PointShadowMath.minimumRadius)
        XCTAssertTrue(Scene3DLighting.resolvePointLights([tiny], nodes: [:]).isEmpty)
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
