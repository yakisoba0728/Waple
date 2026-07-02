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
}
