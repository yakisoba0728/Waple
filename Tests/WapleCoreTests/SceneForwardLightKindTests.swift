import Foundation
import simd
import XCTest
@testable import WapleCore

/// F800(S-9): 2D 포워드 라이팅 kind 분기 — ForwardUniforms 의 kind/axis/cone 팩 회귀.
/// axis = 모델회전(Rz·Ry·Rx) **red축(col0)**,
/// cone = spot 저작각(**광축 기준 반각**, 도) → 코사인(`SceneLight3D.forwardSpotConeCosines`,
/// 리포 단일 정본 — 3D 레인의 `Scene3DLighting.spotConeCosines` 가 이 함수로 위임한다).
/// 콘 산식 자체의 성질은 `SceneSpotConeTests` 가 따로 못박는다. 여기서는 **팩 배선**만 본다.
///
/// **[2026-09-01 정정 완료] 축이 3D PBR 레인과 다시 같다.** 세 레인(3D PBR
/// `Scene3DLighting.resolveLights` · 2D 포워드 `SceneLight3D.forwardUniforms` · 볼류메트릭
/// `SceneRenderer3D`)이 전부 모델행렬 **col0(+X red축)** 을 라이트 forward 로 쓴다.
/// 근거는 V1 PBR 유니폼 패커 `wallpaper64.exe FUN_140190c80` 이 `glm::column(M, 0)` 을 부르는
/// 것이다(directional `0x140191162 xor r8d,r8d`, spot `0x140192e79` 동일).
/// 종전 col2 는 스크립트 API `Mat4.forward()="Blue axis"` 를 근거로 삼았는데, 그 인용은 참이지만
/// **유니폼 패커가 고르는 열을 구속하지 않는다**(상세는 `forwardLightAxis` 선언부 주석).
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

    // MARK: red축(col0) axis

    func testAxisIdentityAnglesIsRedAxis() {
        // 항등 회전의 col0 = (1,0,0). 비유한 입력 폴백도 같은 값이다.
        let a = SceneLight3D.forwardLightAxis(angles: Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(a.x, 1, accuracy: 1e-6)
        XCTAssertEqual(a.y, 0, accuracy: 1e-6)
        XCTAssertEqual(a.z, 0, accuracy: 1e-6)
    }

    func testAxisZRotationSpinsRedAxisInXYPlane() {
        // 실물 3416122407/3047405322 의 lspot 은 angles 가 z-only. col0 = (cz·cy, sz·cy, −sy)
        // 이고 y=0 이므로 (cos z, sin z, 0) — **z 회전이 이제 실제로 축을 돌린다**.
        // (종전 col2 규약에서는 Rz 가 +Z 를 보존해 z-only 라이트의 방향이 회전과 무관했다.)
        let z: Float = -2.54682
        let a = SceneLight3D.forwardLightAxis(angles: Vec3(x: 0, y: 0, z: z))
        XCTAssertEqual(a.x, cos(z), accuracy: 1e-6)
        XCTAssertEqual(a.y, sin(z), accuracy: 1e-6)
        XCTAssertEqual(a.z, 0, accuracy: 1e-6)
    }

    func testAxisXRotationLeavesRedAxisUnchanged() {
        // Rx 는 col0 에 기여하지 않는다(R = Rz·Ry·Rx 에서 Rx 의 첫 열이 (1,0,0)).
        // 즉 pitch-only 라이트는 forward 가 +X 그대로다.
        let a = SceneLight3D.forwardLightAxis(angles: Vec3(x: Float.pi / 2, y: 0, z: 0))
        XCTAssertEqual(a.x, 1, accuracy: 1e-6)
        XCTAssertEqual(a.y, 0, accuracy: 1e-6)
        XCTAssertEqual(a.z, 0, accuracy: 1e-6)
    }

    func testAxisYRotationTurnsRedAxisToNegativeZ() {
        // Ry(+90°): col0 = (cz·cy, sz·cy, −sy) = (0, 0, −1).
        let a = SceneLight3D.forwardLightAxis(angles: Vec3(x: 0, y: Float.pi / 2, z: 0))
        XCTAssertEqual(a.x, 0, accuracy: 1e-6)
        XCTAssertEqual(a.y, 0, accuracy: 1e-6)
        XCTAssertEqual(a.z, -1, accuracy: 1e-6)
    }

    /// 이 함수가 `Scene3DMath.modelMatrix` 의 **col0 과 비트 동형**임을 잠근다(WapleCore 라
    /// 그 타입을 직접 참조할 수 없으므로 같은 회전 수식을 여기서 다시 세운다).
    /// 두 레인이 다시 갈리면 여기서 잡힌다.
    func testAxisMatchesModelMatrixColumnZeroForMixedRotations() {
        for angles in [Vec3(x: 0.3, y: -1.1, z: 2.0), Vec3(x: -2.7, y: 0.4, z: -0.9),
                       Vec3(x: 1.0, y: 1.0, z: 1.0)] {
            let (sy, cy) = (sin(angles.y), cos(angles.y))
            let (sz, cz) = (sin(angles.z), cos(angles.z))
            let expected = SIMD3<Float>(cz * cy, sz * cy, -sy)   // modelMatrix 의 r00/r10/r20
            let a = SceneLight3D.forwardLightAxis(angles: angles)
            XCTAssertEqual(a.x, expected.x, accuracy: 1e-6)
            XCTAssertEqual(a.y, expected.y, accuracy: 1e-6)
            XCTAssertEqual(a.z, expected.z, accuracy: 1e-6)
            // 회전 열이므로 단위벡터다.
            XCTAssertEqual(simd_length(a), 1, accuracy: 1e-6)
        }
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
        // 슬롯 0: point — kind 0, cone 0(미사용), axis 는 identity col0(셰이더가 kind 로 분기해 미소비).
        XCTAssertEqual(u.kindCone[0], SIMD4<Float>(0, 0, 0, 0))
        // 슬롯 1: directional — kind 1, cone 0. angles=Rx(90°) 인데 **col0 은 Rx 에 불변**이라
        // axis = (1,0,0) 이다(종전 col2 규약에서는 (0,-1,0) 이었다 — r2-H1 정정).
        XCTAssertEqual(u.kindCone[1].x, 1, accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[1].x, 1, accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[1].y, 0, accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[1].z, 0, accuracy: 1e-6)
        // 슬롯 2: spot — kind 2. z-only 회전이므로 col0 = (cos z, sin z, 0) 이다
        // (종전 col2 규약에서는 z 회전과 무관하게 (0,0,1) 이었다).
        // w = cone outer cos, inner cos = kindCone.y.
        // 콘 20/30 은 WE 라이트 생성자 기본값(0x1401904a8/0x1401904b2 = 20.0/30.0)이자 코퍼스
        // 실측 상단값이다(spec/corpus/scene-schema.json: innercone 범위 [10.63, 20.0] ·
        // outercone [14.28, 30.0], 5건/2씬). 기대값은 cos 30° = √3/2 = 0.8660254 처럼
        // **각도만으로 정해지는 수**로 적는다 — 산식을 다시 적으면 회귀를 못 잡는다.
        XCTAssertEqual(u.kindCone[2].x, 2, accuracy: 1e-6)
        XCTAssertEqual(u.kindCone[2].y, 0.9396926, accuracy: 1e-6)   // cos 20°
        XCTAssertEqual(u.axisCone[2].x, cos(Float(-2.54682)), accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[2].y, sin(Float(-2.54682)), accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[2].z, 0, accuracy: 1e-6)
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
        // z-only 회전의 col0 = (cos z, sin z, 0) — 파스→팩 경로가 같은 축 규약을 쓴다.
        XCTAssertEqual(u.axisCone[0].x, cos(Float(-2.54682)), accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[0].y, sin(Float(-2.54682)), accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[0].z, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(u.kindCone[0].y, u.axisCone[0].w)
    }
}
