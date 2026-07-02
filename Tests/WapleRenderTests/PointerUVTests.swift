import XCTest
@testable import WapleRender

final class PointerUVTests: XCTestCase {
    func testNormalizedToWEUV() {
        // 중앙(0,0) → (0.5,0.5); 좌상단(AppKit: x=-1, y=+1) → (0,0); 우하단(x=+1, y=-1) → (1,1).
        XCTAssertEqual(SceneRenderer.pointerUV(fromNormalized: .zero), SIMD2<Float>(0.5, 0.5))
        XCTAssertEqual(SceneRenderer.pointerUV(fromNormalized: CGPoint(x: -1, y: 1)), SIMD2<Float>(0, 0))
        XCTAssertEqual(SceneRenderer.pointerUV(fromNormalized: CGPoint(x: 1, y: -1)), SIMD2<Float>(1, 1))
    }
}
