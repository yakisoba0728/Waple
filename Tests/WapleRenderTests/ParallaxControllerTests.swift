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

    // MARK: - 시차 지연 스무딩(cameraparallaxdelay)

    private let zero = SIMD2<Float>(0, 0)
    private let tgt = SIMD2<Float>(1, 0.5)

    /// delay=0 → 즉시 target(기존 즉시 반영 = 무회귀).
    func testDelayZeroIsImmediate() {
        let r = ParallaxController.smoothed(current: zero, target: tgt, dt: 1.0 / 60, delay: 0)
        XCTAssertEqual(r.x, tgt.x, accuracy: 1e-6); XCTAssertEqual(r.y, tgt.y, accuracy: 1e-6)
    }

    /// 음수 delay / dt<=0 도 즉시(가드).
    func testNonPositiveInputsImmediate() {
        XCTAssertEqual(ParallaxController.smoothed(current: zero, target: tgt, dt: 0.016, delay: -1).x, tgt.x, accuracy: 1e-6)
        XCTAssertEqual(ParallaxController.smoothed(current: zero, target: tgt, dt: 0, delay: 0.1).x, tgt.x, accuracy: 1e-6)
    }

    /// delay>0 → 한 스텝은 target 에 못 미침(지연), 여러 스텝이면 단조 수렴 후 정착.
    func testExponentialConvergence() {
        var c = zero
        let one = ParallaxController.smoothed(current: c, target: tgt, dt: 1.0 / 60, delay: 0.3)
        XCTAssertGreaterThan(one.x, 0)              // 움직임 시작
        XCTAssertLessThan(one.x, tgt.x)             // 한 스텝은 지연 — target 미달
        var prev: Float = -1
        for _ in 0..<600 {                          // 10초(60fps) → 정착
            c = ParallaxController.smoothed(current: c, target: tgt, dt: 1.0 / 60, delay: 0.3)
            XCTAssertGreaterThanOrEqual(c.x, prev)  // 단조 증가(오버슈트 없음)
            XCTAssertLessThanOrEqual(c.x, tgt.x + 1e-4)
            prev = c.x
        }
        XCTAssertEqual(c.x, tgt.x, accuracy: 1e-3)  // 수렴
        XCTAssertEqual(c.y, tgt.y, accuracy: 1e-3)
    }

    /// 큰 delay = 느린 수렴(같은 dt 에서 진행량이 작다).
    func testLargerDelayConvergesSlower() {
        let fast = ParallaxController.smoothed(current: zero, target: tgt, dt: 1.0 / 60, delay: 0.1)
        let slow = ParallaxController.smoothed(current: zero, target: tgt, dt: 1.0 / 60, delay: 1.0)
        XCTAssertGreaterThan(fast.x, slow.x)
    }

    /// framerate 독립: 같은 총 시간을 큰/작은 dt 로 밟아도 결과 근사 일치(exp 성질).
    func testFramerateIndependence() {
        var a = zero, b = zero
        for _ in 0..<120 { a = ParallaxController.smoothed(current: a, target: tgt, dt: 1.0 / 120, delay: 0.3) }  // 1s @120
        for _ in 0..<60  { b = ParallaxController.smoothed(current: b, target: tgt, dt: 1.0 / 60,  delay: 0.3) }  // 1s @60
        XCTAssertEqual(a.x, b.x, accuracy: 5e-3)
    }
}
