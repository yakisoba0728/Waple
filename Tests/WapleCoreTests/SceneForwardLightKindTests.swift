import Foundation
import XCTest
@testable import WapleCore

/// F800(S-9): 2D 포워드 라이팅 kind 분기 — ForwardUniforms 의 kind/axis/cone 팩 회귀.
/// axis = 모델회전(Rz·Ry·Rx) blue축(col2) = WE 스크립트 API Mat4.forward 규약(3D 경로와 동일),
/// cone = spot 저작각(**광축 기준 반각**, 도) → 코사인(`SceneLight3D.forwardSpotConeCosines`,
/// 리포 단일 정본 — 3D 레인의 `Scene3DLighting.spotConeCosines` 가 이 함수로 위임한다).
/// 콘 산식 자체의 성질은 `SceneSpotConeTests` 가 따로 못박는다. 여기서는 **팩 배선**만 본다.
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
        // ltube 는 정식 tube 경로(kind 4 — WE genericimage3.frag PointSegmentDelta 소비).
        // 미지 type 만 point 폴터 — 종전 전원 point 처리와 동일(무회귀).
        XCTAssertEqual(SceneLight3D.forwardLightKind("ltube"), 4)
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

    /// 저작각은 **광축에서 잰 반각(도)** 이고 변환은 `cos(도 × π/180)` 이다 — `× 0.5` 가 없다.
    /// 기대값을 `cos(도 × 배율)` 로 다시 적으면 배율이 회귀해도 기대값이 같이 움직여 무의미해지므로,
    /// **각도와 무관하게 알려진 코사인 값**으로 적는다(60° → 1/2, 90° → 0). 종전 `× 0.5` 해석이면
    /// 같은 입력이 각각 cos30° = 0.8660254 / cos45° = 0.7071068 이라 두 자리 모두 갈린다.
    func testSpotConeUsesAuthoredDegreesDirectly() {
        let cone = SceneLight3D.forwardSpotConeCosines(inner: 60, outer: 90)
        XCTAssertEqual(cone.inner, 0.5, accuracy: 1e-6)   // cos 60° = 1/2
        XCTAssertEqual(cone.outer, 0, accuracy: 1e-6)     // cos 90° = 0
        XCTAssertGreaterThan(cone.inner, cone.outer)      // inner 가 좁을수록 코사인 큼
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
                  innerCone: 20, outerCone: 30, radius: 2048),
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
        // 콘 20/30 은 WE 라이트 생성자 기본값(0x1401904a8/0x1401904b2 = 20.0/30.0)이자 코퍼스
        // 실측 상단값이다(spec/corpus/scene-schema.json: innercone 범위 [10.63, 20.0] ·
        // outercone [14.28, 30.0], 5건/2씬). 기대값은 cos 30° = √3/2 = 0.8660254 처럼
        // **각도만으로 정해지는 수**로 적는다 — 산식을 다시 적으면 회귀를 못 잡는다.
        XCTAssertEqual(u.kindCone[2].x, 2, accuracy: 1e-6)
        XCTAssertEqual(u.kindCone[2].y, 0.9396926, accuracy: 1e-6)   // cos 20°
        XCTAssertEqual(u.axisCone[2].z, 1, accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[2].w, 0.8660254, accuracy: 1e-6)   // cos 30° = √3/2
        // 슬롯 3: 미사용 — 제로(종전 radius 0 스킵 규약과 동일하게 kind 0+radius 0).
        XCTAssertEqual(u.kindCone[3], .zero)
        XCTAssertEqual(u.axisCone[3], .zero)
    }

    func testPackKeepsLegacySlotsBitIdentical() {
        // 기존 positions/colorRadius/ambientTerm/count 는 kind 확장과 무관하게 동일 값(무회귀).
        let lights = [light("lspot", origin: Vec3(x: 4134.5, y: 2319.7, z: 565),
                            innerCone: 20, outerCone: 30, radius: 2048, intensity: 4.87)]
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
            "innercone":20,"outercone":30}
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
