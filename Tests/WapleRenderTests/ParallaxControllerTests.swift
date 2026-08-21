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

    /// 음수 delay 도 즉시(delay<=0 가드).
    func testNonPositiveDelayImmediate() {
        XCTAssertEqual(ParallaxController.smoothed(current: zero, target: tgt, dt: 0.016, delay: -1).x, tgt.x, accuracy: 1e-6)
    }

    /// **[정정 2026-08-21] `dt == 0` 은 target 이 아니라 current 다.**
    /// 실물엔 dt 가드가 없고 alpha 가 0 이 되어 제자리에 머문다(0x140189c43 `mulss xmm4, xmm6`).
    /// 종전 구현은 여기서 target 을 즉시 반환해 **시간이 안 흘렀는데 순간이동**했다.
    func testZeroDtHoldsCurrent() {
        let r = ParallaxController.smoothed(current: zero, target: tgt, dt: 0, delay: 0.1)
        XCTAssertEqual(r.x, zero.x, accuracy: 1e-6); XCTAssertEqual(r.y, zero.y, accuracy: 1e-6)
    }

    /// alpha 의 **정확한 값**을 못박는다 — `min(1, 10·(1 − delay/3)·dt)`.
    /// 종전 식 `1 − exp(−dt/delay)` 은 기본 0.1 에서 3.4% 밖에 안 갈려 우연히 맞아 보였으므로
    /// (그래서 이 결함이 오래 살아남았다) 근사 비교가 아니라 **닫힌 식 값**으로 고정한다.
    /// 실측(리눅스 Swift 6.0.3, 60fps): 0.1→0.1611111 · 0.3→0.15 · 1.0→0.1111111.
    func testAlphaMatchesEngineClosedForm() {
        let dt: Float = 1.0 / 60
        for (delay, expected) in [(Float(0.1), Float(0.1611111)), (0.3, 0.15), (1.0, 0.1111111)] {
            let r = ParallaxController.smoothed(current: zero, target: tgt, dt: dt, delay: delay)
            XCTAssertEqual(r.x, tgt.x * expected, accuracy: 1e-6, "delay=\(delay) 의 alpha")
            XCTAssertEqual(r.y, tgt.y * expected, accuracy: 1e-6, "delay=\(delay) 의 alpha(y)")
        }
    }

    /// **`delay == 3` 은 영구 정지.** alpha 가 정확히 0 이다. 실물은 `ja` 로 **상한 1 만** 걸고
    /// 하한 클램프가 없어서 그렇다(0x140189c47). 하한을 넣으면 그 지점에서 실물과 갈리므로 안 넣는다.
    func testDelayThreeFreezesForever() {
        var c = zero
        for _ in 0..<600 { c = ParallaxController.smoothed(current: c, target: tgt, dt: 1.0 / 60, delay: 3) }
        XCTAssertEqual(c.x, 0, accuracy: 1e-6, "delay 3 은 alpha 0 — 10초를 밟아도 안 움직인다")
    }

    /// **`delay > 3` 은 target 반대쪽으로 발산한다** — 실물 결함을 그대로 재현한 것이다.
    /// 동봉·설치본 도달 0건(값은 `0.1` 176건 · `1` 1건뿐)이라 닿는 자산이 없다.
    /// 이 테스트는 "언젠가 누가 하한 클램프를 넣으면 조용히 갈린다" 를 막는 자물쇠다.
    func testDelayAboveThreeDivergesLikeEngine() {
        var c = zero
        for _ in 0..<20 { c = ParallaxController.smoothed(current: c, target: tgt, dt: 1.0 / 60, delay: 4) }
        XCTAssertLessThan(c.x, -1.0, "alpha 가 음수라 target 에서 멀어져야 한다(실물 동형)")
    }

    /// alpha 상한 1 — 큰 dt 에서 오버슈트 금지(0x140189c47 `comiss xmm15, xmm4 / ja`).
    func testAlphaIsCappedAtOne() {
        let r = ParallaxController.smoothed(current: zero, target: tgt, dt: 1.0, delay: 0.1)
        XCTAssertEqual(r.x, tgt.x, accuracy: 1e-6, "alpha 가 1 을 넘어 오버슈트하면 안 된다")
    }

    /// delay>0 → 한 스텝은 target 에 못 미침(지연), 여러 스텝이면 단조 수렴 후 정착.
    func testStepwiseConvergence() {
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

    /// framerate **근사** 독립: 같은 총 시간을 큰/작은 dt 로 밟아도 결과가 가깝다.
    /// [정정 2026-08-21] 종전 주석은 "exp 성질" 로 **정확** 독립이라 적었는데, 실물 alpha 는
    /// dt 에 **선형**이라 엄밀히는 독립이 아니다. 스텝당 alpha 가 작을 때 둘 다 `e^{-kt}` 를
    /// 근사하므로 가까울 뿐이다 — 실측 1초 후 차이 2.8e-5(@120 vs @60, delay 0.3).
    func testFramerateIndependence() {
        var a = zero, b = zero
        for _ in 0..<120 { a = ParallaxController.smoothed(current: a, target: tgt, dt: 1.0 / 120, delay: 0.3) }  // 1s @120
        for _ in 0..<60  { b = ParallaxController.smoothed(current: b, target: tgt, dt: 1.0 / 60,  delay: 0.3) }  // 1s @60
        XCTAssertEqual(a.x, b.x, accuracy: 5e-3)
    }

    // MARK: - SceneRenderer teardown→resume 계약 (parallax monitor 재기동 방지)

    /// parallax 활성 씬을 teardown(scene→video 직접 remount 시 이전 렌더러 정리 경로)한 뒤
    /// resume 이 호출돼도 stale parallaxEnabled 로 mouseMoved 모니터를 되살리면 안 된다.
    /// resume(:1172) 게이트가 parallaxEnabled 를 보므로 teardown 이 이를 끄지 않으면 monitor 재기동.
    /// start() 가 emit() 을 동기 호출하므로 onOffset 발화로 run-loop 없이 관측 가능.
    func testTeardownClearsParallaxSoResumeDoesNotRearmMonitor() {
        let r = SceneRenderer()
        r.parallaxEnabled = true                  // parallax 활성 씬 mount 사후상태 모사
        r.teardown()
        var revived = false
        r.parallax.onOffset = { _ in revived = true }
        r.resume()
        XCTAssertFalse(revived, "teardown 후 resume 이 parallax monitor 를 재기동하면 안 됨")
    }
}
