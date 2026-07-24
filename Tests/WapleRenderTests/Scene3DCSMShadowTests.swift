import XCTest
import simd
@testable import WapleCore
@testable import WapleRender

/// F780(S-47): directional CSM 3-스플릿 회귀.
///   - `cascadedistance0-2`(F750 파스·보존)가 resolve → pack → VP 산출까지 소비되는 경로를 고정.
///   - 유효 게이트(엄격 상승·양·유한, directional + castShadow 한정)와 무효 시 단일 오소 폴터를 고정.
///   - 실측값: 3737268876 젤다 "Main Light" (3, 14.34, 100), 3706286085 소닉 "SunLight" (25, 50, 200).
final class Scene3DCSMShadowTests: XCTestCase {

    private func directionalLight(castsShadow: Bool = true,
                                  cascades: Vec3? = Vec3(x: 3, y: 14.34, z: 100)) -> SceneLight3D {
        SceneLight3D(
            id: 1, name: "Main Light", type: "ldirectional",
            origin: Vec3(x: 0, y: 10, z: 0), angles: Vec3(x: 0.3, y: 0.1, z: 0),
            color: Vec3(x: 1, y: 1, z: 1), radius: 0, intensity: 2, exponent: 1,
            castShadow: castsShadow, parent: nil, cascadeDistances: cascades)
    }

    private func camera(eye: SIMD3<Float> = SIMD3(0, 0, -10)) -> DirectionalShadowMath.ShadowCamera {
        DirectionalShadowMath.ShadowCamera(
            eye: eye, forward: SIMD3(0, 0, 1), right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
            tanHalfFovY: tan(25 * .pi / 180), aspect: 16.0 / 9.0, nearZ: 0.01)
    }

    // MARK: 유효성 게이트

    func testValidCascadesRequiresStrictlyAscendingPositiveFinite() {
        XCTAssertEqual(DirectionalShadowMath.validCascades(SIMD3(3, 14.34, 100)), SIMD3(3, 14.34, 100))
        // 실측 근등치 상승(3470948192: 400/400.10001/400.20001)도 엄격 상승이면 유효.
        XCTAssertNotNil(DirectionalShadowMath.validCascades(SIMD3(400, 400.10001, 400.20001)))
        XCTAssertNil(DirectionalShadowMath.validCascades(nil))
        XCTAssertNil(DirectionalShadowMath.validCascades(SIMD3(100, 14.34, 3)), "역전")
        XCTAssertNil(DirectionalShadowMath.validCascades(SIMD3(3, 3, 100)), "동치")
        XCTAssertNil(DirectionalShadowMath.validCascades(SIMD3(0, 14.34, 100)), "0 시작")
        XCTAssertNil(DirectionalShadowMath.validCascades(SIMD3(-3, 14.34, 100)), "음수")
        XCTAssertNil(DirectionalShadowMath.validCascades(SIMD3(3, .nan, 100)), "비유한")
        XCTAssertNil(DirectionalShadowMath.validCascades(SIMD3(3, .infinity, 100)), "무한")
    }

    // MARK: resolve → pack 소비 경로

    func testResolveLightsPreservesCascadeDistances() {
        let resolved = Scene3DLighting.resolveLights([directionalLight()], nodes: [:])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].cascadeDistances, SIMD3(3, 14.34, 100))
    }

    func testPackLightsMarksCSMOnlyForCastingDirectionalWithValidCascades() {
        let csm = Scene3DLighting.packLights(
            Scene3DLighting.resolveLights([directionalLight()], nodes: [:]))
        XCTAssertEqual(csm[0].cascades, SIMD4(3, 14.34, 100, 3))
        XCTAssertEqual(csm[0].shadow.y, csm[0].shadow.x * 6, "VP 시작 슬롯은 slice*6 패턴 유지")

        // 파스만 된 비캐스터(실측 3470948192 castshadow:false)는 미소비.
        let notCasting = Scene3DLighting.packLights(
            Scene3DLighting.resolveLights([directionalLight(castsShadow: false)], nodes: [:]))
        XCTAssertEqual(notCasting[0].cascades, .zero)

        // 경계 부재/무효는 단일 오소 폴터(w=0).
        let noCascades = Scene3DLighting.packLights(
            Scene3DLighting.resolveLights([directionalLight(cascades: nil)], nodes: [:]))
        XCTAssertEqual(noCascades[0].cascades, .zero)
        let reversed = SceneLight3D(
            id: 1, name: "", type: "ldirectional",
            origin: Vec3(x: 0, y: 0, z: 0), angles: Vec3(x: 0, y: 0, z: 0),
            color: Vec3(x: 1, y: 1, z: 1), radius: 0, intensity: 1, exponent: 1,
            castShadow: true, parent: nil,
            cascadeDistances: Vec3(x: 100, y: 14.34, z: 3))
        let invalid = Scene3DLighting.packLights(
            Scene3DLighting.resolveLights([reversed], nodes: [:]))
        XCTAssertEqual(invalid[0].cascades, .zero)

        // point 는 유효 경계를 들고 있어도 CSM 미적용(셰이더 경로 자체가 다름).
        let point = SceneLight3D(
            id: 2, name: "", type: "lpoint",
            origin: Vec3(x: 0, y: 0, z: 0), angles: Vec3(x: 0, y: 0, z: 0),
            color: Vec3(x: 1, y: 1, z: 1), radius: 20, intensity: 1, exponent: 1,
            castShadow: true, parent: nil,
            cascadeDistances: Vec3(x: 1152, y: 2304, z: 4224))
        let packedPoint = Scene3DLighting.packLights(
            Scene3DLighting.resolveLights([point], nodes: [:]))
        XCTAssertEqual(packedPoint[0].cascades, .zero)
    }

    // MARK: 캐스케이드 VP 수학

    func testCascadeViewProjectionsRejectInvalidInput() {
        let light = SIMD3<Float>(0.3, -1, 0.2)
        XCTAssertNil(DirectionalShadowMath.cascadeViewProjections(
            forward: light, camera: camera(), distances: SIMD3(100, 14.34, 3),
            minBound: SIMD3(-5, -2, -5), maxBound: SIMD3(5, 2, 15)), "경계 역전")
        XCTAssertNil(DirectionalShadowMath.cascadeViewProjections(
            forward: .zero, camera: camera(), distances: SIMD3(3, 14.34, 100),
            minBound: SIMD3(-5, -2, -5), maxBound: SIMD3(5, 2, 15)), "영벡터 forward")
        XCTAssertNil(DirectionalShadowMath.cascadeViewProjections(
            forward: light, camera: camera(), distances: SIMD3(3, 14.34, 100),
            minBound: SIMD3(5, -2, -5), maxBound: SIMD3(-5, 2, 15)), "min>max AABB")
    }

    func testCascadeViewProjectionsFitFrustumSlicesTightly() throws {
        // 젤다 실측 경계. 라이트는 비스듬한 하향(평행 up 퇴화 회피).
        let distances = SIMD3<Float>(3, 14.34, 100)
        let lightForward = SIMD3<Float>(0.3, -1, 0.2)
        let cam = camera()
        let vps = try XCTUnwrap(DirectionalShadowMath.cascadeViewProjections(
            forward: lightForward, camera: cam, distances: distances,
            minBound: SIMD3(-60, -30, -60), maxBound: SIMD3(60, 30, 160)))
        XCTAssertEqual(vps.count, 3)

        // 슬라이스 중심점은 자기 캐스케이드 맵 안(|ndc| ≤ 1).
        let dNear = max(cam.nearZ, Float(1e-3))
        var prev = dNear
        for (i, vp) in vps.enumerated() {
            let far = distances[i]
            let mid = cam.eye + cam.forward * (prev + far) * 0.5
            let ndc = ndc3(vp, mid)
            XCTAssertLessThanOrEqual(abs(ndc.x), 1, "cascade \(i) 중심 x")
            XCTAssertLessThanOrEqual(abs(ndc.y), 1, "cascade \(i) 중심 y")
            prev = far
        }

        // 프러스텀 에지 점(마지막 슬라이스 95% 거리, half-width 90% 측방)은
        // 자기 캐스케이드(2)엔 들어가고 타이트한 캐스케이드 0 에선 밖.
        let edgeDist = distances.z * 0.95
        let lateral = cam.tanHalfFovY * edgeDist * cam.aspect * 0.9
        let edge = cam.eye + cam.forward * edgeDist + cam.right * lateral
        let ndcFar = ndc3(vps[2], edge)
        XCTAssertLessThanOrEqual(abs(ndcFar.x), 1, "자기 캐스케이드 안")
        let ndcNear = ndc3(vps[0], edge)
        XCTAssertGreaterThan(max(abs(ndcNear.x), abs(ndcNear.y)), 1.5,
                             "캐스케이드 0 은 타이트 — 원거리 점은 상자 밖(해상도 이득의 핵심)")

        // 깊이: 프러스텀 밖 캐스터(씬 AABB 코너)도 전 캐스케이드에서 z ∈ [0,1].
        let caster = SIMD3<Float>(-60, 30, 160)
        for (i, vp) in vps.enumerated() {
            let ndc = ndc3(vp, caster)
            XCTAssertGreaterThanOrEqual(ndc.z, 0, "cascade \(i) 캐스터 z 하한")
            XCTAssertLessThanOrEqual(ndc.z, 1, "cascade \(i) 캐스터 z 상한")
        }
    }

    func testCascadeViewProjectionsDifferPerCascadeAndUseSliceSlots() throws {
        let vps = try XCTUnwrap(DirectionalShadowMath.cascadeViewProjections(
            forward: SIMD3(0.3, -1, 0.2), camera: camera(), distances: SIMD3(25, 50, 200),
            minBound: SIMD3(-60, -30, -60), maxBound: SIMD3(60, 30, 160)))
        XCTAssertNotEqual(vps[0], vps[1])
        XCTAssertNotEqual(vps[1], vps[2])
    }

    // MARK: 셰이더 계약

    func testMeshShaderCarriesCSMSliceSelection() {
        // LightU 5번째 float4 + 카메라 거리 슬라이스 선택 + 셀 매핑이 소스에 존재해야 한다.
        XCTAssertTrue(Mesh3DShaders.source.contains("float4 cascades;"))
        XCTAssertTrue(Mesh3DShaders.source.contains("light.cascades.w > 2.5"))
        XCTAssertTrue(Mesh3DShaders.source.contains("pointShadowCell(cascade)"))
        XCTAssertTrue(Mesh3DShaders.source.contains("light.cascades.z"))
    }

    private func ndc3(_ vp: simd_float4x4, _ world: SIMD3<Float>) -> SIMD3<Float> {
        let p = vp * SIMD4<Float>(world.x, world.y, world.z, 1)
        return SIMD3(p.x / p.w, p.y / p.w, p.z / p.w)
    }
}
