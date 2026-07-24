import XCTest
import simd
@testable import WapleRender
@testable import WapleCore

/// F801(S-20 후속): cropoffset 런타임 적용 기각 확정 — 쿼드 배치가 cropOffset 을 소비하지 않음을 고정.
/// 근거(실물 2827816001 크롭 6조각 재조립 분석): origin == 원본배치중심+cropoffset 이 4/6 비트정합
/// (2/6 은 크롭 후 사용자 미세이동) → WE 에디터가 베이크 시 origin 에 이미 합성. 무적용 시 조각이
/// 원본 크롭 영역에 정확히 붙고, ±어느 부호로든 추가 적용하면 이중 이동으로 재조립 파열.
final class SceneCropOffsetQuadTests: XCTestCase {
    private func layer(cropOffset: Vec2?) -> SceneLayer {
        var l = SceneLayer(textureEntryName: "t.tex", origin: Vec2(x: 1581.5, y: 1080),
                           size: Vec2(x: 2069, y: 2160), scale: Vec2(x: 1, y: 1), angleZ: 0,
                           alpha: 1, color: Vec3(x: 1, y: 1, z: 1), brightness: 1,
                           parallaxDepth: Vec2(x: 1, y: 1), effects: [])
        l.cropOffset = cropOffset
        return l
    }

    /// cropOffset 유무와 무관하게 쿼드 정점이 비트동일 — 배치 경로는 cropOffset 을 읽지 않는다(무회귀).
    func testQuadVerticesIgnoresCropOffset() {
        let plain = SceneRenderer.quadVertices(layer: layer(cropOffset: nil), projW: 3840, projH: 2160)
        let cropped = SceneRenderer.quadVertices(layer: layer(cropOffset: Vec2(x: -338.5, y: 0)),
                                                 projW: 3840, projH: 2160)
        XCTAssertEqual(cropped, plain, "F801: cropOffset 은 origin 에 이미 합성 — 이중 적용 금지")
    }

    /// 실물 2827816001 id=18 기준: 무적용 쿼드 사각형이 원본 크롭 영역(x [547,2616])에 정합.
    /// origin(1581.5,1080) = 원본배치중심(1920,1080)+cropoffset(-338.5,0), size=크롭 영역 2069×2160.
    func testRealScenePieceBoundsMatchOriginalCropRegion() {
        let verts = SceneRenderer.quadVertices(layer: layer(cropOffset: Vec2(x: -338.5, y: 0)),
                                               projW: 3840, projH: 2160)
        // NDC → 씬 픽셀 역산(x 만): px = (ndc+1)/2 * projW. 좌변=TL/BL, 우변=TR/BR.
        let xs = verts.map { ($0.x + 1) * 0.5 * 3840 }
        XCTAssertEqual(xs.min()!, 547, accuracy: 1e-3)   // 1581.5 − 2069/2
        XCTAssertEqual(xs.max()!, 2616, accuracy: 1e-3)  // 1581.5 + 2069/2
    }
}
