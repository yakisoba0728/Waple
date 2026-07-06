import XCTest
import simd
@testable import WapleRender

/// 클릭/포인터 뷰좌표 → 씬좌표 역매핑(순수): draw 의 aspectScale 과 동일 공식을 공유해
/// fit 레터박스/fill 크롭에서도 클릭이 정확한 씬 픽셀에 떨어진다. AppKit 하단원점 → WE 상단원점.
final class SceneInputMappingTests: XCTestCase {

    // MARK: aspectScale (draw 와 단일 소스)

    func testAspectScale_stretch_isIdentity() {
        XCTAssertEqual(SceneRenderer.aspectScale(projAspect: 16.0/9, viewAspect: 1, fitMode: .stretch),
                       SIMD2<Float>(1, 1))
    }

    func testAspectScale_fit_wideSceneInSquareView_shrinksY() {
        let s = SceneRenderer.aspectScale(projAspect: 16.0/9, viewAspect: 1, fitMode: .fit)
        XCTAssertEqual(s.x, 1, accuracy: 1e-6)
        XCTAssertEqual(s.y, 9.0/16, accuracy: 1e-6)
    }

    func testAspectScale_fill_wideSceneInSquareView_expandsX() {
        let s = SceneRenderer.aspectScale(projAspect: 16.0/9, viewAspect: 1, fitMode: .fill)
        XCTAssertEqual(s.x, 16.0/9, accuracy: 1e-6)
        XCTAssertEqual(s.y, 1, accuracy: 1e-6)
    }

    // MARK: sceneCoords — stretch (기존 근사와 동일해야 함)

    func testSceneCoords_stretch_centerAndCorners() {
        let size = CGSize(width: 800, height: 600)
        let c = SceneRenderer.sceneCoords(viewPoint: CGPoint(x: 400, y: 300), viewSize: size,
                                          projW: 1920, projH: 1080, fitMode: .stretch)
        XCTAssertEqual(c?.x ?? -1, 960, accuracy: 0.01)
        XCTAssertEqual(c?.y ?? -1, 540, accuracy: 0.01)
        // AppKit 하단-좌측 (0,0) → WE 상단원점에선 좌하단 = (0, projH)
        let bl = SceneRenderer.sceneCoords(viewPoint: .zero, viewSize: size,
                                           projW: 1920, projH: 1080, fitMode: .stretch)
        XCTAssertEqual(bl?.x ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(bl?.y ?? -1, 1080, accuracy: 0.01)
    }

    // MARK: sceneCoords — fit (레터박스)

    func testSceneCoords_fit_letterboxClickReturnsNil() {
        // 16:9 씬을 1:1 뷰에 fit → 상하 레터박스. 최하단 클릭은 씬 밖.
        let r = SceneRenderer.sceneCoords(viewPoint: CGPoint(x: 500, y: 50),
                                          viewSize: CGSize(width: 1000, height: 1000),
                                          projW: 1920, projH: 1080, fitMode: .fit)
        XCTAssertNil(r)
    }

    func testSceneCoords_fit_contentTopEdgeMapsToSceneTop() {
        // 콘텐츠 상단 경계: ndc'y=1 ⇔ ndc y=9/16 ⇔ v=(9/16+1)/2 → y=781.25
        let r = SceneRenderer.sceneCoords(viewPoint: CGPoint(x: 500, y: 781.25),
                                          viewSize: CGSize(width: 1000, height: 1000),
                                          projW: 1920, projH: 1080, fitMode: .fit)
        XCTAssertEqual(r?.x ?? -1, 960, accuracy: 0.01)
        XCTAssertEqual(r?.y ?? -1, 0, accuracy: 0.1)
    }

    // MARK: sceneCoords — fill (크롭: 뷰 가장자리가 씬 내부에 대응)

    func testSceneCoords_fill_viewEdgeMapsInsideScene() {
        // 16:9 씬을 1:1 뷰에 fill → 좌우 크롭, 보이는 폭은 씬 x 420..1500.
        let right = SceneRenderer.sceneCoords(viewPoint: CGPoint(x: 1000, y: 500),
                                              viewSize: CGSize(width: 1000, height: 1000),
                                              projW: 1920, projH: 1080, fitMode: .fill)
        XCTAssertEqual(right?.x ?? -1, 1500, accuracy: 0.01)
        XCTAssertEqual(right?.y ?? -1, 540, accuracy: 0.01)
        let left = SceneRenderer.sceneCoords(viewPoint: CGPoint(x: 0, y: 500),
                                             viewSize: CGSize(width: 1000, height: 1000),
                                             projW: 1920, projH: 1080, fitMode: .fill)
        XCTAssertEqual(left?.x ?? -1, 420, accuracy: 0.01)
    }

    func testSceneCoords_degenerateSizesReturnNil() {
        XCTAssertNil(SceneRenderer.sceneCoords(viewPoint: .zero, viewSize: .zero,
                                               projW: 1920, projH: 1080, fitMode: .stretch))
        XCTAssertNil(SceneRenderer.sceneCoords(viewPoint: .zero, viewSize: CGSize(width: 100, height: 100),
                                               projW: 0, projH: 0, fitMode: .stretch))
    }
}
