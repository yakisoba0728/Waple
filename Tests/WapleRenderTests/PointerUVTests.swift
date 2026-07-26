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

    /// g_PointerState 클릭 배관: setPointerButtonDown → EngineU pointerLastAndPad.z(e[22]).
    /// 미주입(헤드리스/캡처)은 0 유지 = 무클릭 = 170씬 A/B 무변화 가드.
    func testPointerButtonStateFlowsToEngineU() {
        let r = SceneRenderer()
        // targetRes 는 이 테스트가 다루는 e[22](g_PointerState.z)와 무관 — P⑥×X-⑤ 교차배치 수정으로
        // engineUniform 의 targetRes 가 필수 인자가 돼 임의값(1,1,1,1)을 명시.
        let noTarget = SIMD4<Float>(1, 1, 1, 1)
        XCTAssertEqual(r.engineUniform(time: 0, texRes: [], targetRes: noTarget)[22], 0, "기본 무클릭 → 0(캡처 가드)")
        r.setPointerButtonDown(true)
        XCTAssertEqual(r.engineUniform(time: 0, texRes: [], targetRes: noTarget)[22], 1, "버튼 다운 → g_PointerState.z 슬롯 1")
        r.setPointerButtonDown(false)
        XCTAssertEqual(r.engineUniform(time: 0, texRes: [], targetRes: noTarget)[22], 0, "버튼 업 → 0")
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

final class QuadAlignmentTests: XCTestCase {
    // NDC → 씬픽셀 역변환(pxToNDC 의 역): x=(ndcX+1)/2·proj, y=(1−ndcY)/2·proj.
    private func scenePixels(_ v: [SIMD4<Float>], proj: Float) -> (xs: [Float], ys: [Float]) {
        (v.map { ($0.x + 1) / 2 * proj }, v.map { (1 - $0.y) / 2 * proj })
    }

    /// D2: alignment="bottomleft" 는 origin 이 좌하단 앵커여야 한다 — 사각형이 origin 기준 우측(+x)·
    /// 위쪽(y-down 에서 −y)으로만 뻗는다(오디오 이퀄라이저 바: y=하단선 고정한 채 위로만 자람).
    /// 종전(미반영)엔 origin 이 항상 중심이라 좌·아래로도 절반 편이 → 이 assert 가 red.
    func testBottomLeftAnchorsOriginAtBottomLeft() {
        let v = SceneRenderer.quadVertices(origin: Vec2(x: 100, y: 200), size: Vec2(x: 40, y: 80),
                                           scale: Vec2(x: 1, y: 1), angleZ: 0, alignment: "bottomleft",
                                           projW: 1000, projH: 1000)
        let (xs, ys) = scenePixels(v, proj: 1000)
        XCTAssertEqual(xs.min()!, 100, accuracy: 1e-2)   // 좌변 = origin.x (우측으로만)
        XCTAssertEqual(xs.max()!, 140, accuracy: 1e-2)   // origin.x + w
        XCTAssertEqual(ys.min()!, 120, accuracy: 1e-2)   // 상단 = origin.y − h
        XCTAssertEqual(ys.max()!, 200, accuracy: 1e-2)   // 하변 = origin.y (위로만)
    }

    /// 반대 부호 가지(right→+hw, top→−hh) 잠금 — topright 는 origin 이 우상단 앵커여야:
    /// 사각형이 좌측(−x)·아래(y-down 에서 +y)로만 뻗는다(bottomleft 와 대칭).
    func testTopRightAnchorsOriginAtTopRight() {
        let v = SceneRenderer.quadVertices(origin: Vec2(x: 100, y: 200), size: Vec2(x: 40, y: 80),
                                           scale: Vec2(x: 1, y: 1), angleZ: 0, alignment: "topright",
                                           projW: 1000, projH: 1000)
        let (xs, ys) = scenePixels(v, proj: 1000)
        XCTAssertEqual(xs.min()!, 60, accuracy: 1e-2)    // origin.x − w
        XCTAssertEqual(xs.max()!, 100, accuracy: 1e-2)   // 우변 = origin.x (좌측으로만)
        XCTAssertEqual(ys.min()!, 200, accuracy: 1e-2)   // 상단 = origin.y (아래로만)
        XCTAssertEqual(ys.max()!, 280, accuracy: 1e-2)   // origin.y + h
    }

    /// alignment="center"(기본) 는 origin=중심 — 앵커 도입 전 정점과 완전 동일(무회귀).
    func testCenterAlignmentUnchanged() {
        let v = SceneRenderer.quadVertices(origin: Vec2(x: 100, y: 200), size: Vec2(x: 40, y: 80),
                                           scale: Vec2(x: 1, y: 1), angleZ: 0, alignment: "center",
                                           projW: 1000, projH: 1000)
        let (xs, ys) = scenePixels(v, proj: 1000)
        XCTAssertEqual(xs.min()!, 80, accuracy: 1e-2)    // 중심 ± hw(20)
        XCTAssertEqual(xs.max()!, 120, accuracy: 1e-2)
        XCTAssertEqual(ys.min()!, 160, accuracy: 1e-2)   // 중심 ± hh(40)
        XCTAssertEqual(ys.max()!, 240, accuracy: 1e-2)
    }
}
