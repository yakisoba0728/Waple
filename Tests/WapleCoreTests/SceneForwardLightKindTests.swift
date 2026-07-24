import Foundation
import XCTest
@testable import WapleCore

/// F800(S-9): 2D 포워드 라이팅 kind 분기 — ForwardUniforms 의 kind/axis/cone 팩 회귀.
/// axis = 모델회전(Rz·Ry·Rx) blue축(col2) = WE 스크립트 API Mat4.forward 규약(3D 경로와 동일),
/// cone = spot 전각(도) → half-angle 코사인(Scene3DLighting.spotConeCosines 동일 변환).
final class SceneForwardLightKindTests: XCTestCase {
    private func light(_ type: String, origin: Vec3 = Vec3(x: 0, y: 0, z: 250),
                       angles: Vec3 = Vec3(x: 0, y: 0, z: 0),
                       innerCone: Float = 0, outerCone: Float = 0,
                       radius: Float = 100, intensity: Float = 1) -> SceneLight3D {
        SceneLight3D(id: 0, name: "", type: type, origin: origin, angles: angles,
                     color: Vec3(x: 1, y: 1, z: 1), radius: radius, intensity: intensity,
                     exponent: 2, innerCone: innerCone, outerCone: outerCone,
                     castShadow: false, parent: nil)
    }

    private func pack(_ lights: [SceneLight3D]) -> SceneLight3D.ForwardUniforms {
        SceneLight3D.forwardUniforms(lights, ambient: Vec3(x: 0, y: 0, z: 0), skylight: Vec3(x: 0, y: 0, z: 0))
    }

    // MARK: kind 매핑

    func testLightKindMapping() {
        XCTAssertEqual(SceneLight3D.forwardLightKind("lpoint"), 0)
        XCTAssertEqual(SceneLight3D.forwardLightKind("ldirectional"), 1)
        XCTAssertEqual(SceneLight3D.forwardLightKind("lspot"), 2)
        // 미지 type 은 point 폴터 — 종전 f_lit 전원 point 처리와 동일(무회귀).
        XCTAssertEqual(SceneLight3D.forwardLightKind("ltube"), 0)
        XCTAssertEqual(SceneLight3D.forwardLightKind(""), 0)
    }

    // MARK: blue축 axis

    func testAxisIdentityAnglesIsBlueAxis() {
        let a = SceneLight3D.forwardLightAxis(angles: Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(a.x, 0, accuracy: 1e-6)
        XCTAssertEqual(a.y, 0, accuracy: 1e-6)
        XCTAssertEqual(a.z, 1, accuracy: 1e-6)
    }

    func testAxisZRotationOnlyKeepsBlueAxis() {
        // 실물 3416122407/3047405322 의 lspot 은 angles 가 z-only — Rz 는 +Z 축을 보존하므로
        // blue축 규약상 forward 는 (0,0,1) 이다(회전 z 각도와 무관).
        let a = SceneLight3D.forwardLightAxis(angles: Vec3(x: 0, y: 0, z: -2.54682))
        XCTAssertEqual(a.x, 0, accuracy: 1e-6)
        XCTAssertEqual(a.y, 0, accuracy: 1e-6)
        XCTAssertEqual(a.z, 1, accuracy: 1e-6)
    }

    func testAxisXRotationPitchesBlueAxisDown() {
        // Rx(+90°): +Z → -Y (Rz·Ry·Rx 의 col2 = (0,-sin x, cos x)).
        let a = SceneLight3D.forwardLightAxis(angles: Vec3(x: Float.pi / 2, y: 0, z: 0))
        XCTAssertEqual(a.x, 0, accuracy: 1e-6)
        XCTAssertEqual(a.y, -1, accuracy: 1e-6)
        XCTAssertEqual(a.z, 0, accuracy: 1e-6)
    }

    func testAxisYRotationTurnsBlueAxisToX() {
        // Ry(+90°): +Z → +X (col2 x = cz·sy·cx + sz·sx = sy).
        let a = SceneLight3D.forwardLightAxis(angles: Vec3(x: 0, y: Float.pi / 2, z: 0))
        XCTAssertEqual(a.x, 1, accuracy: 1e-6)
        XCTAssertEqual(a.y, 0, accuracy: 1e-6)
        XCTAssertEqual(a.z, 0, accuracy: 1e-6)
    }

    // MARK: spot cone 코사인

    func testSpotConeHalfAngleCosines() {
        // 실물 3047405322 의 lspot 값(innercone 44.830605 / outercone 67.129997, 전각 도).
        let cone = SceneLight3D.forwardSpotConeCosines(inner: 44.830605, outer: 67.129997)
        let half = Float.pi / 180 * 0.5
        XCTAssertEqual(cone.inner, cos(44.830605 * half), accuracy: 1e-6)
        XCTAssertEqual(cone.outer, cos(67.129997 * half), accuracy: 1e-6)
        XCTAssertGreaterThan(cone.inner, cone.outer)  // inner 가 좁을수록 코사인 큼
    }

    func testSpotConeDegenerateOuterFallsBackToHemisphere() {
        // outercone 부재/0 → (1, -1) 반구 그라디언트(3D 경로와 동일 폴터).
        let cone = SceneLight3D.forwardSpotConeCosines(inner: 0, outer: 0)
        XCTAssertEqual(cone.inner, 1, accuracy: 1e-6)
        XCTAssertEqual(cone.outer, -1, accuracy: 1e-6)
    }

    // MARK: 팩 통합

    func testPackCarriesKindAxisConePerSlot() {
        let u = pack([
            light("lpoint"),
            light("ldirectional", angles: Vec3(x: Float.pi / 2, y: 0, z: 0), radius: 0),
            light("lspot", angles: Vec3(x: 0, y: 0, z: -2.54682),
                  innerCone: 44.830605, outerCone: 67.129997, radius: 2048),
        ])
        XCTAssertEqual(u.count, 3)
        // 슬롯 0: point — kind 0, cone 0(미사용), axis 는 identity blue축(셰이더가 kind 로 분기해 미소비).
        XCTAssertEqual(u.kindCone[0], SIMD4<Float>(0, 0, 0, 0))
        // 슬롯 1: directional — kind 1, cone 0, axis = Rx(90°) blue축 = (0,-1,0).
        XCTAssertEqual(u.kindCone[1].x, 1, accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[1].x, 0, accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[1].y, -1, accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[1].z, 0, accuracy: 1e-6)
        // 슬롯 2: spot — kind 2, axis = (0,0,1) (z-only 회전), w = cone outer cos, inner cos = kindCone.y.
        XCTAssertEqual(u.kindCone[2].x, 2, accuracy: 1e-6)
        let half = Float.pi / 180 * 0.5
        XCTAssertEqual(u.kindCone[2].y, cos(44.830605 * half), accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[2].z, 1, accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[2].w, cos(67.129997 * half), accuracy: 1e-6)
        // 슬롯 3: 미사용 — 제로(종전 radius 0 스킵 규약과 동일하게 kind 0+radius 0).
        XCTAssertEqual(u.kindCone[3], .zero)
        XCTAssertEqual(u.axisCone[3], .zero)
    }

    func testPackKeepsLegacySlotsBitIdentical() {
        // 기존 positions/colorRadius/ambientTerm/count 는 kind 확장과 무관하게 동일 값(무회귀).
        let lights = [light("lspot", origin: Vec3(x: 4134.5, y: 2319.7, z: 565),
                            innerCone: 44.830605, outerCone: 67.129997, radius: 2048, intensity: 4.87)]
        let u = pack(lights)
        XCTAssertEqual(u.positions[0], SIMD4<Float>(4134.5, 2319.7, 565, 2))
        XCTAssertEqual(u.colorRadius[0], SIMD4<Float>(4.87, 4.87, 4.87, 2048))
        XCTAssertEqual(u.count, 1)
        // 구형 이니셜라이저(기존 호출부)는 axisCone/kindCone 기본값(.zero) — 소스 호환.
        let legacy = SceneLight3D.ForwardUniforms(positions: u.positions, colorRadius: u.colorRadius,
                                                  ambientTerm: u.ambientTerm, count: u.count)
        XCTAssertEqual(legacy.axisCone, [SIMD4<Float>](repeating: .zero, count: 4))
        XCTAssertEqual(legacy.kindCone, [SIMD4<Float>](repeating: .zero, count: 4))
    }

    func testParseLightKindSurvivesIntoPack() throws {
        // scene.json "light":"lspot" 파스 → kind 2 까지의 전체 경로(파스↔팩 정합).
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[
           {"id":1,"light":"lspot","origin":"100 100 250","angles":"0 0 -2.54682",
            "color":"1 1 1","intensity":4.87,"radius":2048,"exponent":2,
            "innercone":44.830605,"outercone":67.129997}
         ]}
        """
        let pkg = ScenePackage.assemble([("scene.json", scene.data(using: .utf8)!)])
        let doc = try SceneDocument.parse(package: pkg)
        let u = pack(doc.lights3D)
        XCTAssertEqual(u.kindCone[0].x, 2, accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[0].z, 1, accuracy: 1e-6)
        XCTAssertGreaterThan(u.kindCone[0].y, u.axisCone[0].w)
    }
}
