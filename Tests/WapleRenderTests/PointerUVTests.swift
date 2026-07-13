import XCTest
import simd
@testable import WapleCore
@testable import WapleRender

final class PointerUVTests: XCTestCase {
    func testNormalizedToWEUV() {
        // 중앙(0,0) → (0.5,0.5); 좌상단(AppKit: x=-1, y=+1) → (0,0); 우하단(x=+1, y=-1) → (1,1).
        XCTAssertEqual(SceneRenderer.pointerUV(fromNormalized: .zero), SIMD2<Float>(0.5, 0.5))
        XCTAssertEqual(SceneRenderer.pointerUV(fromNormalized: CGPoint(x: -1, y: 1)), SIMD2<Float>(0, 0))
        XCTAssertEqual(SceneRenderer.pointerUV(fromNormalized: CGPoint(x: 1, y: -1)), SIMD2<Float>(1, 1))
    }
}

final class PuppetVerticesTests: XCTestCase {
    /// 퍼펫 메시 → NDC 매핑이 quadVertices 규약(씬 픽셀 y-down)과 일치.
    func testMeshToNDCMapping() {
        var m = PuppetModel(material: "m",
                            vertices: [.init(position: SIMD3(0, 0, 0), boneIndices: SIMD4(0, 0, 0, 0),
                                             weights: SIMD4(1, 0, 0, 0), uv: SIMD2(0.25, 0.75)),
                                       .init(position: SIMD3(100, 50, 0), boneIndices: SIMD4(0, 0, 0, 0),
                                             weights: SIMD4(1, 0, 0, 0), uv: SIMD2(1, 1))],
                            indices: [0, 1, 0])
        m.bones = []
        let v = SceneRenderer.puppetVertices(model: m, positions: m.vertices.map { $0.position },
                                             origin: Vec2(x: 960, y: 540), scale: Vec2(x: 2, y: 2), angleZ: 0,
                                             projW: 1920, projH: 1080)
        XCTAssertEqual(v.count, 3)
        // 정점0: 씬 (960,540) = 화면 중앙 → NDC (0,0); uv 보존
        XCTAssertEqual(v[0].x, 0, accuracy: 1e-4)
        XCTAssertEqual(v[0].y, 0, accuracy: 1e-4)
        XCTAssertEqual(v[0].z, 0.25)
        XCTAssertEqual(v[0].w, 0.75)
        // 정점1: 메시 y-up → 로컬(200,-100) → 씬(1160,440) → NDC
        XCTAssertEqual(v[1].x, (1160.0/1920)*2 - 1, accuracy: 1e-4)
        XCTAssertEqual(v[1].y, 1 - (440.0/1080)*2, accuracy: 1e-4)
    }

    /// A1 회귀: scene.json `angles` 는 이미 라디안(코퍼스 전부 ≤π 확정)이므로 quad/lit/puppetVertices 가
    /// 라디안 그대로 회전해야 한다. 종전 `*.pi/180` 은 라디안을 도(°)로 오인해 회전을 57× 축소했다.
    /// angleZ=π/2 면 로컬 (+x=100,0) 정점이 (0,+100) 으로 90° 회전 → NDC(-1,0). 버그였다면 ~0.9° 만
    /// 돌아 NDC(0,1) 근처(=angleZ 0 과 사실상 동일)에 머문다.
    func testAngleZIsRadiansNotDegrees() {
        var m = PuppetModel(material: "m",
                            vertices: [.init(position: SIMD3(100, 0, 0), boneIndices: SIMD4(0, 0, 0, 0),
                                             weights: SIMD4(1, 0, 0, 0), uv: SIMD2(0, 0))],
                            indices: [0])
        m.bones = []
        let v = SceneRenderer.puppetVertices(model: m, positions: [SIMD3(100, 0, 0)],
                                             origin: Vec2(x: 0, y: 0), scale: Vec2(x: 1, y: 1),
                                             angleZ: .pi / 2, projW: 200, projH: 200)
        XCTAssertEqual(v[0].x, -1, accuracy: 1e-3)
        XCTAssertEqual(v[0].y, 0, accuracy: 1e-3)
    }
}
