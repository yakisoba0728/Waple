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
        // targetRes 는 이 테스트와 무관(g_PointerState 만 확인) — 명시 필수 인자라 더미값 전달.
        let noTarget = SIMD4<Float>(1, 1, 1, 1)
        XCTAssertEqual(r.engineUniform(time: 0, texRes: [], targetRes: noTarget)[22], 0, "기본 무클릭 → 0(캡처 가드)")
        r.setPointerButtonDown(true)
        XCTAssertEqual(r.engineUniform(time: 0, texRes: [], targetRes: noTarget)[22], 1, "버튼 다운 → g_PointerState.z 슬롯 1")
        r.setPointerButtonDown(false)
        XCTAssertEqual(r.engineUniform(time: 0, texRes: [], targetRes: noTarget)[22], 0, "버튼 업 → 0")
    }
}

final class PuppetVerticesTests: XCTestCase {
    /// 퍼펫 메시 → NDC 매핑. puppetVertices 자체는 W1-yaxis 로 손대지 않음(§5: 제거 시 정상 3씬
    /// 파괴 확인됨) — 이 테스트는 그 함수의 (불변) 내부 산술에 새 pxToNDC(y-up) 만 반영해 갱신한다.
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
        // 정점0: 씬 (960,540) = 화면 중앙 → NDC (0,0)(중앙은 y-flip 과 무관, 무회귀); uv 보존
        XCTAssertEqual(v[0].x, 0, accuracy: 1e-4)
        XCTAssertEqual(v[0].y, 0, accuracy: 1e-4)
        XCTAssertEqual(v[0].z, 0.25)
        XCTAssertEqual(v[0].w, 0.75)
        // 정점1: 메시 y-up → 로컬(200,-100) → 씬(1160,440) → NDC(새 pxToNDC: y/H·2−1, 1−y/H·2 아님)
        XCTAssertEqual(v[1].x, (1160.0/1920)*2 - 1, accuracy: 1e-4)
        XCTAssertEqual(v[1].y, (440.0/1080)*2 - 1, accuracy: 1e-4)
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
    // NDC → 씬픽셀 역변환(W1-yaxis: pxToNDC 의 역, y-up): x=(ndcX+1)/2·proj, y=(ndcY+1)/2·proj.
    private func scenePixels(_ v: [SIMD4<Float>], proj: Float) -> (xs: [Float], ys: [Float]) {
        (v.map { ($0.x + 1) / 2 * proj }, v.map { ($0.y + 1) / 2 * proj })
    }

    /// D2: alignment="bottomleft" 는 origin 이 좌하단 앵커여야 한다 — 사각형이 origin 기준 우측(+x)·
    /// 위쪽(y-up 에서 +y)으로만 뻗는다(오디오 이퀄라이저 바: y=하단선 고정한 채 위로만 자람).
    /// W1-yaxis: y-up 확정으로 "위=+y" — origin.y 가 최솟값(하단), origin.y+h 가 최댓값(상단).
    func testBottomLeftAnchorsOriginAtBottomLeft() {
        let v = SceneRenderer.quadVertices(origin: Vec2(x: 100, y: 200), size: Vec2(x: 40, y: 80),
                                           scale: Vec2(x: 1, y: 1), angleZ: 0, alignment: "bottomleft",
                                           projW: 1000, projH: 1000)
        let (xs, ys) = scenePixels(v, proj: 1000)
        XCTAssertEqual(xs.min()!, 100, accuracy: 1e-2)   // 좌변 = origin.x (우측으로만)
        XCTAssertEqual(xs.max()!, 140, accuracy: 1e-2)   // origin.x + w
        XCTAssertEqual(ys.min()!, 200, accuracy: 1e-2)   // 하단 = origin.y (위로만 자람)
        XCTAssertEqual(ys.max()!, 280, accuracy: 1e-2)   // 상단 = origin.y + h
    }

    /// 반대 부호 가지(right→+hw, top→+hh) 잠금 — topright 는 origin 이 우상단 앵커여야:
    /// 사각형이 좌측(−x)·아래(y-up 에서 −y)로만 뻗는다(bottomleft 와 대칭).
    func testTopRightAnchorsOriginAtTopRight() {
        let v = SceneRenderer.quadVertices(origin: Vec2(x: 100, y: 200), size: Vec2(x: 40, y: 80),
                                           scale: Vec2(x: 1, y: 1), angleZ: 0, alignment: "topright",
                                           projW: 1000, projH: 1000)
        let (xs, ys) = scenePixels(v, proj: 1000)
        XCTAssertEqual(xs.min()!, 60, accuracy: 1e-2)    // origin.x − w
        XCTAssertEqual(xs.max()!, 100, accuracy: 1e-2)   // 우변 = origin.x (좌측으로만)
        XCTAssertEqual(ys.min()!, 120, accuracy: 1e-2)   // 하단 = origin.y − h
        XCTAssertEqual(ys.max()!, 200, accuracy: 1e-2)   // 상단 = origin.y (아래로만 뻗음)
    }

    /// alignment="center"(기본) 는 origin=중심 — y-flip 과 무관하게 대칭이라 정점 min/max 가
    /// 종전 y-down 구현과 완전 동일(무회귀 불변 — advisor 도출: 대칭 박스는 재배치 없음).
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

/// W1-yaxis 핵심 불변식: origin.y == projH/2 **이고 angleZ == 0** 인 레이어는 새/구 pxToNDC 가 부호만
/// 반대인 대칭식 + quadVertices 의 hh 재페어링이 정확히 상쇄되어 정점이 **비트동일**해야 한다
/// (2325500626 무회귀 게이트와 동형 — 회전이 있으면 y-flip 이 회전 센스 자체를 켤레하므로 이 등식은
/// 성립하지 않는다: 아래 testRotationIsCounterClockwiseInYUp 참고. 이 불변이 깨지면 hh 재페어링
/// 누락 — 화면 중앙 레이어의 콘텐츠가 상하반전된 채로 남는다).
final class QuadVerticesYUpInvariantTests: XCTestCase {
    func testScreenCenteredUnrotatedLayerMatchesLegacyYDownOutput() {
        let projW: Float = 1920, projH: Float = 1080
        let legacy: (Float, Float) -> SIMD2<Float> = { x, y in SIMD2(x / projW * 2 - 1, 1 - y / projH * 2) }
        func legacyQuad(origin: Vec2, size: Vec2) -> [SIMD4<Float>] {
            let hw = size.x * 0.5, hh = size.y * 0.5
            let tl = legacy(origin.x - hw, origin.y - hh), tr = legacy(origin.x + hw, origin.y - hh)
            let br = legacy(origin.x + hw, origin.y + hh), bl = legacy(origin.x - hw, origin.y + hh)
            return [SIMD4(tl.x, tl.y, 0, 0), SIMD4(tr.x, tr.y, 1, 0), SIMD4(br.x, br.y, 1, 1),
                    SIMD4(tl.x, tl.y, 0, 0), SIMD4(br.x, br.y, 1, 1), SIMD4(bl.x, bl.y, 0, 1)]
        }
        let origin = Vec2(x: 733, y: projH / 2)
        let size = Vec2(x: 120, y: 64)
        let new = SceneRenderer.quadVertices(origin: origin, size: size, scale: Vec2(x: 1, y: 1),
                                             angleZ: 0, alignment: "center", projW: projW, projH: projH)
        let old = legacyQuad(origin: origin, size: size)
        for i in 0..<new.count {
            XCTAssertEqual(new[i].x, old[i].x, accuracy: 1e-4, "idx=\(i)")
            XCTAssertEqual(new[i].y, old[i].y, accuracy: 1e-4, "idx=\(i)")
        }
    }

    /// W1-yaxis: y-up 세계에서 angleZ 양수는 CCW(반시계) 여야 WE 규약과 일치(문서 §3-C2: "WE 양수=CCW").
    /// 오른쪽을 가리키는 로컬 벡터(+x)를 +90° 돌리면 위(+y, 화면 상단)를 가리켜야 한다 — hh=0 퇴화
    /// 박스로 tl/bl·tr/br 가 겹치게 만들어 회전 후 코너 하나의 화면상 상하 위치만 순수 검증.
    func testRotationIsCounterClockwiseInYUp() {
        let projW: Float = 1000, projH: Float = 1000
        let origin = Vec2(x: 500, y: 500)
        let v = SceneRenderer.quadVertices(origin: origin, size: Vec2(x: 200, y: 0),
                                           scale: Vec2(x: 1, y: 1), angleZ: .pi / 2,
                                           alignment: "center", projW: projW, projH: projH)
        // v[1] = tr = corner(+hw, +hh=0) 회전 전 로컬(100,0)(→ 오른쪽) → +90°CCW 후 로컬(0,100)(→ 위).
        // 화면 중앙(NDC 0,0) 대비 y 가 양수(위)여야 한다 — 시계방향이었다면 음수(아래)로 나온다.
        XCTAssertEqual(v[1].x, 0, accuracy: 1e-3)
        XCTAssertGreaterThan(v[1].y, 0.05, "angleZ=+π/2 는 CCW 여야(오른쪽 로컬점이 화면 위로 회전)")
    }
}
