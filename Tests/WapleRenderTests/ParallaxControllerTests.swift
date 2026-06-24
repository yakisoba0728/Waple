import XCTest
@testable import WapleRender

final class ParallaxControllerTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 800) // center (500,400)

    func testCenterIsZero() {
        let o = ParallaxController.normalizedOffset(mouse: CGPoint(x: 500, y: 400), screenFrame: frame)
        XCTAssertEqual(o.x, 0, accuracy: 1e-6); XCTAssertEqual(o.y, 0, accuracy: 1e-6)
    }
    func testEdgesAreUnit() {
        XCTAssertEqual(ParallaxController.normalizedOffset(mouse: CGPoint(x: 1000, y: 400), screenFrame: frame).x, 1, accuracy: 1e-6)
        XCTAssertEqual(ParallaxController.normalizedOffset(mouse: CGPoint(x: 0, y: 400), screenFrame: frame).x, -1, accuracy: 1e-6)
        XCTAssertEqual(ParallaxController.normalizedOffset(mouse: CGPoint(x: 500, y: 800), screenFrame: frame).y, 1, accuracy: 1e-6)
    }
    func testClampsOutside() {
        let o = ParallaxController.normalizedOffset(mouse: CGPoint(x: 5000, y: -5000), screenFrame: frame)
        XCTAssertEqual(o.x, 1, accuracy: 1e-6); XCTAssertEqual(o.y, -1, accuracy: 1e-6)
    }
    func testZeroFrameSafe() {
        let o = ParallaxController.normalizedOffset(mouse: CGPoint(x: 10, y: 10), screenFrame: .zero)
        XCTAssertEqual(o.x, 0); XCTAssertEqual(o.y, 0)
    }
}
