import XCTest
import simd
@testable import WapleRender

/// F315: fullscreenlayer 신설 커밋(3b10c73)이 남기지 않은 전용 정확성 테스트 — 자매 커밋(cb9b80c HDR
/// bloom, daf09e3 camerashake)은 각각 Scene3DHDRBloomTests/Scene3DCameraShakeTests 로 파이프라인/기하를
/// XCTAssert 로 잠갔는데 이 커밋만 SingleSceneProbeTests 캡처 해상도 오버라이드뿐이었다(신규 어설션 0건).
/// 기능 자체는 코퍼스 검증(7개 3D 씬 전부 models/util/fullscreenlayer.json 참조)됐고 코드도 올바르나,
/// 회귀 방지용 자동 잠금이 없었다 — encodeFullscreenComposite 에서 뽑은 순수 함수
/// SceneRenderer.fullscreenCompositeVertices() 를 직접 단언한다(인코딩 로직 자체는 무변경).
final class Scene3DFullscreenCompositeGeometryTests: XCTestCase {
    private func vertex(_ verts: [Float], _ i: Int) -> (pos: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>) {
        let b = i * 8
        return (SIMD3(verts[b], verts[b + 1], verts[b + 2]),
                SIMD3(verts[b + 3], verts[b + 4], verts[b + 5]),
                SIMD2(verts[b + 6], verts[b + 7]))
    }

    // MARK: 6정점(삼각형 2개) × 8-float(pos3+normal3+uv2) = GPU3DMesh 정적 정점 레이아웃과 동일 스트라이드
    func testVertexCountMatchesTwoTrianglesWithMeshLayoutStride() {
        let verts = SceneRenderer.fullscreenCompositeVertices()
        XCTAssertEqual(verts.count, 48, "6 정점 × 8 float(pos3+normal3+uv2) — mv_main 이 페치하는 정적 스트라이드와 동일해야 함")
    }

    // MARK: 정점 위치가 정확히 화면정렬 -1..1 NDC 코너(카메라 프로젝션 완전 우회 — mvp=identity 로 그대로 클립공간)
    func testVerticesAreScreenAlignedNDCCorners() {
        let verts = SceneRenderer.fullscreenCompositeVertices()
        // TL, TR, BR, TL, BR, BL(두 삼각형이 화면 전체를 덮는 표준 쿼드 분할).
        let expectedPositions: [SIMD3<Float>] = [
            SIMD3(-1, 1, 0), SIMD3(1, 1, 0), SIMD3(1, -1, 0),
            SIMD3(-1, 1, 0), SIMD3(1, -1, 0), SIMD3(-1, -1, 0),
        ]
        for i in 0..<6 {
            let v = vertex(verts, i)
            XCTAssertEqual(v.pos, expectedPositions[i], "정점 \(i): 화면정렬 -1..1 NDC 코너(카메라 프로젝션 우회)")
        }
    }

    // MARK: UV 상단 원점(v=0=상단) — encodeBillboard 의 프레임버퍼 비플립 규약과 동일해야 후처리 결과가 안 뒤집힘
    func testUVsUseTopOriginMatchingEncodeBillboardConvention() {
        let verts = SceneRenderer.fullscreenCompositeVertices()
        let expectedUVs: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1),
            SIMD2(0, 0), SIMD2(1, 1), SIMD2(0, 1),
        ]
        for i in 0..<6 {
            let v = vertex(verts, i)
            XCTAssertEqual(v.uv, expectedUVs[i], "정점 \(i): UV 상단원점(y=-1 쪽 NDC 코너가 v=1) — 비플립")
        }
    }

    // MARK: normal(0,0,1) 고정 — mf_main 라이팅 경로에서 안 쓰이지만(material.w=0 unlit) worldNormal 페치 자체는 유효해야 함
    func testNormalsAreFixedForwardVector() {
        let verts = SceneRenderer.fullscreenCompositeVertices()
        for i in 0..<6 {
            XCTAssertEqual(vertex(verts, i).normal, SIMD3(0, 0, 1), "정점 \(i): normal 고정(unlit 이라 셰이딩엔 미사용, 페치 유효성만 보장)")
        }
    }

    // MARK: 두 삼각형의 신발끈 공식 면적 합 = 2×2 NDC 정사각형(화면 100% 커버, 갭/오버랩 없음)
    func testTrianglesExactlyTileFullNDCSquareWithoutGapOrOverlap() {
        let verts = SceneRenderer.fullscreenCompositeVertices()
        func xy(_ i: Int) -> SIMD2<Float> { let v = vertex(verts, i); return SIMD2(v.pos.x, v.pos.y) }
        func triangleArea(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
            abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
        }
        let area1 = triangleArea(xy(0), xy(1), xy(2))
        let area2 = triangleArea(xy(3), xy(4), xy(5))
        XCTAssertEqual(area1 + area2, 4.0, accuracy: 1e-6,
            "두 삼각형 면적 합 = 2×2 NDC 정사각형(화면 전체) — 부분 커버면 godrays 류 풀스크린 효과가 가장자리에서 잘림")
    }
}
