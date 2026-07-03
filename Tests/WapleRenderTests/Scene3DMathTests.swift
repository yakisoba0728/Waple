import XCTest
import simd
@testable import WapleRender
@testable import WapleCore

/// 3D 카메라/변환 순수 함수 — Metal NDC(z 0..1) 규약 검증.
final class Scene3DMathTests: XCTestCase {
    private func xform(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = m * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3(v.x, v.y, v.z) / v.w
    }
    private func assertVec(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 1e-4,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "y", file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, "z", file: file, line: line)
    }

    // MARK: lookAt

    /// 원점에서 -Z 를 보는 표준 자세 → 항등.
    func testLookAtIdentity() {
        let m = Scene3DMath.lookAt(eye: .zero, center: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
        assertVec(xform(m, SIMD3(1, 2, -3)), SIMD3(1, 2, -3))
    }

    /// eye 는 원점으로, center 는 -Z 축(거리 보존)으로 사상. 우수 규약: 전방=-Z.
    func testLookAtMapsEyeAndCenter() {
        let eye = SIMD3<Float>(10.05, 1.08, 0.02)     // 실물 젤다 카메라
        let center = SIMD3<Float>(9.05, 1.05, 0.06)
        let m = Scene3DMath.lookAt(eye: eye, center: center, up: SIMD3(0, 1, 0))
        assertVec(xform(m, eye), .zero)
        let d = simd_length(center - eye)
        assertVec(xform(m, center), SIMD3(0, 0, -d))
    }

    /// up 방향의 점은 뷰 +y 쪽으로 사상(상하 반전 없음).
    func testLookAtUpIsPlusY() {
        let m = Scene3DMath.lookAt(eye: SIMD3(0, 0, 5), center: .zero, up: SIMD3(0, 1, 0))
        let p = xform(m, SIMD3(0, 1, 5))
        XCTAssertEqual(p.y, 1, accuracy: 1e-4)
        // 우측(+X 월드)은 뷰 +x (우수: right = forward × up = (-z)×(+y) → +x... cross(f,up)).
        let r = xform(m, SIMD3(1, 0, 5))
        XCTAssertEqual(r.x, 1, accuracy: 1e-4)
    }

    // MARK: perspective (Metal z 0..1)

    func testPerspectiveDepthRange() {
        let m = Scene3DMath.perspective(fovYDegrees: 50, aspect: 16.0 / 9, nearZ: 0.01, farZ: 10000)
        assertVec(xform(m, SIMD3(0, 0, -0.01)), SIMD3(0, 0, 0), accuracy: 1e-5)   // near → 0
        XCTAssertEqual(xform(m, SIMD3(0, 0, -10000)).z, 1, accuracy: 1e-3)        // far → 1
    }

    /// fov 는 세로축: z=-d 에서 y=±d·tan(fov/2) 가 ndc y=±1, x 는 aspect 로 나눠 사상.
    func testPerspectiveVerticalFov() {
        let fov: Float = 90
        let m = Scene3DMath.perspective(fovYDegrees: fov, aspect: 2, nearZ: 0.1, farZ: 100)
        let top = xform(m, SIMD3(0, 1, -1))      // tan(45°)=1
        XCTAssertEqual(top.y, 1, accuracy: 1e-4)
        let right = xform(m, SIMD3(2, 0, -1))    // 가로 반화각 = fov/2 × aspect (tan 공간)
        XCTAssertEqual(right.x, 1, accuracy: 1e-4)
    }

    // MARK: modelMatrix (T·R·S, R = Rz·Ry·Rx)

    func testModelMatrixTRSOrder() {
        // scale 2 → (2,0,0); Rz 90° → (0,2,0); T(5,0,0) → (5,2,0). S→R→T 적용 순서 검증.
        let m = Scene3DMath.modelMatrix(origin: SIMD3(5, 0, 0), angles: SIMD3(0, 0, .pi / 2),
                                        scale: SIMD3(2, 2, 2))
        assertVec(xform(m, SIMD3(1, 0, 0)), SIMD3(5, 2, 0))
    }

    func testModelMatrixEulerOrderZYX() {
        // R = Rz·Ry·Rx — X 먼저 적용. (0,0,1): Rx(90°) → (0,-1,0); Ry(90°) → (0,-1,0)(y축 상 불변);
        // 순서가 반대(Rx·Ry·Rz = Z 먼저)면 (0,0,1)→Rz 불변→Ry(90°)→(1,0,0)→Rx(90°)→(1,0,0) 로 달라진다.
        let m = Scene3DMath.modelMatrix(origin: .zero, angles: SIMD3(.pi / 2, .pi / 2, 0),
                                        scale: SIMD3(1, 1, 1))
        assertVec(xform(m, SIMD3(0, 0, 1)), SIMD3(0, -1, 0))
    }

    /// 실물 젤다 짐벌 표현 (π, θ, -π) 는 순수 yaw(π-θ)와 동치여야 한다(Rupee Root 2001).
    func testGimbalPiThetaPiEqualsPureYaw() {
        let theta: Float = -1.15609
        let g = Scene3DMath.modelMatrix(origin: .zero, angles: SIMD3(3.14159, theta, -3.14159),
                                        scale: SIMD3(1, 1, 1))
        let y = Scene3DMath.modelMatrix(origin: .zero, angles: SIMD3(0, .pi - theta, 0),
                                        scale: SIMD3(1, 1, 1))
        for c in 0..<4 {
            assertVec(SIMD3(g[c].x, g[c].y, g[c].z), SIMD3(y[c].x, y[c].y, y[c].z), accuracy: 1e-4)
        }
    }

    // MARK: hierarchy

    func testWorldMatrixParentComposition() {
        // parent: T(0,10,0) · 자기 R/S 없음, child: T(1,0,0) → 월드 (1,10,0) + 자식 로컬 점.
        let nodes: [Int: Scene3DMath.Node] = [
            1: .init(origin: SIMD3(0, 10, 0), angles: .zero, scale: SIMD3(1, 1, 1), parent: nil, visible: true),
            2: .init(origin: SIMD3(1, 0, 0), angles: .zero, scale: SIMD3(2, 2, 2), parent: 1, visible: true),
        ]
        let w = try! XCTUnwrap(Scene3DMath.worldMatrix(id: 2, nodes: nodes))
        XCTAssertTrue(w.visible)
        assertVec(xform(w.matrix, SIMD3(1, 0, 0)), SIMD3(3, 10, 0))  // 1*2(스케일)+1(로컬T), 부모 +10y
    }

    /// 부모 회전이 자식 위치에 적용된다(피벗 공전 — 태양계 행성 배치의 핵심).
    func testParentRotationOrbitsChild() {
        let nodes: [Int: Scene3DMath.Node] = [
            1: .init(origin: .zero, angles: SIMD3(0, .pi / 2, 0), scale: SIMD3(1, 1, 1), parent: nil, visible: true),
            2: .init(origin: SIMD3(1, 0, 0), angles: .zero, scale: SIMD3(1, 1, 1), parent: 1, visible: true),
        ]
        let w = try! XCTUnwrap(Scene3DMath.worldMatrix(id: 2, nodes: nodes))
        // Ry(90°): +X → -Z
        assertVec(xform(w.matrix, .zero), SIMD3(0, 0, -1))
    }

    func testInvisibleAncestorPropagates() {
        let nodes: [Int: Scene3DMath.Node] = [
            1: .init(origin: .zero, angles: .zero, scale: SIMD3(1, 1, 1), parent: nil, visible: false),
            2: .init(origin: .zero, angles: .zero, scale: SIMD3(1, 1, 1), parent: 1, visible: true),
        ]
        XCTAssertEqual(Scene3DMath.worldMatrix(id: 2, nodes: nodes)?.visible, false)
    }

    func testCycleGuardTerminates() {
        let nodes: [Int: Scene3DMath.Node] = [
            1: .init(origin: SIMD3(1, 0, 0), angles: .zero, scale: SIMD3(1, 1, 1), parent: 2, visible: true),
            2: .init(origin: SIMD3(0, 1, 0), angles: .zero, scale: SIMD3(1, 1, 1), parent: 1, visible: true),
        ]
        // 종료만 보장하면 됨(사이클에서 무한루프 금지). 1→2 까지 합성 후 중단.
        XCTAssertNotNil(Scene3DMath.worldMatrix(id: 1, nodes: nodes))
    }

    func testUnknownParentTreatedAsRoot() {
        let nodes: [Int: Scene3DMath.Node] = [
            5: .init(origin: SIMD3(1, 2, 3), angles: .zero, scale: SIMD3(1, 1, 1), parent: 999, visible: true),
        ]
        let w = try! XCTUnwrap(Scene3DMath.worldMatrix(id: 5, nodes: nodes))
        assertVec(xform(w.matrix, .zero), SIMD3(1, 2, 3))
    }

    func testNodeMapMergesObjectsAndGroups() {
        let objs = [SceneObject3D(id: 10, name: "m", model: "a.mdl", origin: Vec3(x: 1, y: 0, z: 0),
                                  angles: Vec3(x: 0, y: 0, z: 0), scale: Vec3(x: 1, y: 1, z: 1),
                                  castShadow: false, parent: 20, effects: [])]
        let groups = [SceneNode3D(id: 20, origin: Vec3(x: 0, y: 5, z: 0), angles: Vec3(x: 0, y: 0, z: 0),
                                  scale: Vec3(x: 1, y: 1, z: 1), parent: nil, visible: true)]
        let map = Scene3DMath.nodeMap(objects: objs, groups: groups)
        XCTAssertEqual(map.count, 2)
        let w = try! XCTUnwrap(Scene3DMath.worldMatrix(id: 10, nodes: map))
        assertVec(xform(w.matrix, .zero), SIMD3(1, 5, 0))
    }
}
