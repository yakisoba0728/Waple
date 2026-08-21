import XCTest
@testable import WapleCore

/// `SceneCameraMath` — WE 카메라 모션 산술의 닫힌 식 자물쇠.
///
/// 기대값은 전부 `wallpaper64.exe` 실측 수식을 float32 로 그대로 밟아 얻은 것이다
/// (근거 VA 는 `Sources/WapleCore/SceneGeometry.swift` 와 `docs/re/camera-motion.md`).
/// "그럴듯한 근사" 가 아니라 **실물 수치**라서, 수식을 조금이라도 바꾸면 반드시 깨진다.
final class SceneGeometryCameraMathTests: XCTestCase {

    // MARK: - camerashake

    /// 위상은 **속도의 제곱** — speed 2배면 위상 4배(0x1401995f7 `mulss xmm6, xmm6`).
    func testShakePhaseIsSpeedSquared() {
        XCTAssertEqual(SceneCameraMath.shakePhase(speed: 3, time: 2), 18, accuracy: 1e-6)
        let a = SceneCameraMath.shakePhase(speed: 2, time: 1)
        let b = SceneCameraMath.shakePhase(speed: 4, time: 1)
        XCTAssertEqual(b, a * 4, accuracy: 1e-6, "speed 2배 → 위상 4배")
    }

    /// roughness = 1.0(코퍼스 저작 전건)은 **완전 무연산**이다 — 리매핑 블록을 건너뛴다.
    /// 즉 결과가 `(cos φ, sin 1.333φ, sin φ) · scale` 그대로여야 한다.
    /// **비트동일**로 잠근다. `k == 1` 게이트를 지우고 리매핑을 태우면 `(v/|v|)·|v|` 가
    /// 1 ulp 어긋나는 t 가 나온다(실측 t=1.7 의 z, t=0.4 의 y) — 정밀도 허용치를 주면
    /// 그 이탈이 조용히 통과하므로 여기서는 `accuracy` 를 쓰지 않는다.
    func testRoughnessOneIsExactlyNoOp() {
        let speed: Float = 3, amp: Float = 0.5
        let s = amp * 0.1
        for t in [Float(1.7), 0.4, 2.3, 3.25, 5.0, 0.9] {
            let phi = speed * speed * t
            let d = SceneCameraMath.shakeDelta(time: t, speed: speed, amplitude: amp, roughness: 1,
                                               orthographic: false, orthoHeight: 0)
            XCTAssertEqual(d.x, cosf(phi) * s, "t=\(t) x")
            XCTAssertEqual(d.y, sinf(phi * 1.3329999446868896) * s, "t=\(t) y")
            XCTAssertEqual(d.z, sinf(phi) * s, "t=\(t) z")
        }
    }

    /// 성분 배치: x = cos, y = **1.333배 주파수** sin, z = sin. 셋이 같은 사인이면 안 된다.
    func testComponentLayout() {
        let d = SceneCameraMath.shakeDelta(time: 1, speed: 1, amplitude: 10, roughness: 1,
                                           orthographic: false, orthoHeight: 0)
        XCTAssertEqual(d.x, cosf(1) * 1, accuracy: 1e-6)
        XCTAssertEqual(d.z, sinf(1) * 1, accuracy: 1e-6)
        XCTAssertNotEqual(d.y, d.z, accuracy: 1e-3, "y 는 1.333φ 라 z(=sin φ)와 달라야 한다")
    }

    /// 2D(정사영) 진폭은 **정사영 픽셀** `amplitude·H/100` 이고 z 성분은 0 이다.
    /// NDC 상수 배율(0.03 같은 것)이 아니다 — 이게 Waple C-3 갭의 핵심.
    func testOrthographicScaleIsPixelsAndZIsZero() {
        let d = SceneCameraMath.shakeDelta(time: 2, speed: 3, amplitude: 0.5, roughness: 1,
                                           orthographic: true, orthoHeight: 256)
        XCTAssertEqual(d.z, 0, "정사영 씬은 z 성분이 0(0x140199644 xorps)")
        // scale = 256·0.1·(0.5·0.1) = 1.28 → 피크 진폭이 1.28 정사영 단위
        XCTAssertEqual(d.x, 0.8452054, accuracy: 1e-5)
        XCTAssertEqual(d.y, -1.1623775, accuracy: 1e-5)
        let peak = 256 * Float(0.1) * (Float(0.5) * 0.1)
        XCTAssertLessThanOrEqual(abs(d.x), peak + 1e-4)
    }

    /// 3D(원근) 진폭은 **월드 단위** `amplitude·0.1`.
    func testPerspectiveScaleIsWorldUnits() {
        let d = SceneCameraMath.shakeDelta(time: 0, speed: 3, amplitude: 0.5, roughness: 1,
                                           orthographic: false, orthoHeight: 256)
        // t=0 → φ=0 → (cos0, sin0, sin0) = (1,0,0), scale = 0.05
        XCTAssertEqual(d.x, 0.05, accuracy: 1e-7)
        XCTAssertEqual(d.y, 0, accuracy: 1e-7)
        XCTAssertEqual(d.z, 0, accuracy: 1e-7)
    }

    /// 설치본 유일한 `camerashake:true` 실물(`ricepod`: speed 5 · amplitude 0.01 · roughness 0.1, 3D)을
    /// 오라클로 고정한다. `0.1³` 이 비교 상수 `0x140492608`(=0.001f)과 **같은 float 로 반올림**되어
    /// `jbe` 가 성립 → 거칠기 리매핑을 건너뛴다.
    func testRicepodOracle() {
        let d = SceneCameraMath.shakeDelta(time: 1, speed: 5, amplitude: 0.01, roughness: 0.1,
                                           orthographic: false, orthoHeight: 0)
        XCTAssertEqual(d.x, 0.0009912029, accuracy: 1e-6)
        XCTAssertEqual(d.y, 0.0009433289, accuracy: 1e-6)
        XCTAssertEqual(d.z, -0.00013235176, accuracy: 1e-6)
    }

    /// roughness 가 리매핑을 **실제로** 탈 때(0.001 < r³ < 1) 크기가 `|v|^(r³)` 로 바뀐다.
    func testRoughnessRemapChangesMagnitudeOnly() {
        let t: Float = 0.7, speed: Float = 3, amp: Float = 0.5, r: Float = 0.5
        let d = SceneCameraMath.shakeDelta(time: t, speed: speed, amplitude: amp, roughness: r,
                                           orthographic: false, orthoHeight: 0)
        let phi = speed * speed * t
        let v = (cosf(phi), sinf(phi * 1.3329999446868896), sinf(phi))
        let len = sqrtf(v.0 * v.0 + v.1 * v.1 + v.2 * v.2)
        let m = powf(len, powf(r, 3))
        let s = amp * 0.1
        XCTAssertEqual(d.x, (v.0 / len) * m * s, accuracy: 1e-7)
        XCTAssertEqual(d.y, (v.1 / len) * m * s, accuracy: 1e-7)
        XCTAssertEqual(d.z, (v.2 / len) * m * s, accuracy: 1e-7)
        // 방향은 보존, 크기만 바뀐다.
        let raw = (v.0 * s, v.1 * s, v.2 * s)
        XCTAssertEqual(d.x / raw.0, d.z / raw.2, accuracy: 1e-5, "성분별 배율이 같아야 한다(= 순수 크기 리매핑)")
    }

    /// 결정적이다 — 같은 t 면 같은 값. 난수원이 없다는 성질을 자물쇠로 건다
    /// (`SnapshotPipeline.captureRandomSeed` 캡처 결정성 보호).
    func testShakeIsDeterministic() {
        for _ in 0..<3 {
            let d = SceneCameraMath.shakeDelta(time: 3.25, speed: 3, amplitude: 0.5, roughness: 1,
                                               orthographic: true, orthoHeight: 256)
            XCTAssertEqual(d.x, -0.71758926, accuracy: 1e-4)
        }
    }

    // MARK: - cameraparallax 초점

    /// `mouseinfluence = 0` 이면 마우스가 어디에 있든 초점은 **캔버스 중앙**이다.
    /// (게인이 아니라 보간 계수라는 것 — Waple W-2 갭의 핵심.)
    func testFocusWithZeroInfluenceIsCanvasCentre() {
        for p in [Vec2(x: 0, y: 0), Vec2(x: 1, y: 1), Vec2(x: 0.3, y: 0.9)] {
            let f = SceneCameraMath.parallaxFocus(pointer: p, mouseInfluence: 0, projW: 256, projH: 256)
            XCTAssertEqual(f.x, 128, accuracy: 1e-4)
            XCTAssertEqual(f.y, 128, accuracy: 1e-4)
        }
    }

    /// `mouseinfluence = 1` 이면 초점이 마우스 위치 그대로. **y 는 뒤집힌다**(`1 − pointer.y`).
    func testFocusWithFullInfluenceFollowsPointerWithFlippedY() {
        let f = SceneCameraMath.parallaxFocus(pointer: Vec2(x: 0.25, y: 0.75),
                                              mouseInfluence: 1, projW: 600, projH: 600)
        XCTAssertEqual(f.x, 150, accuracy: 1e-4)
        XCTAssertEqual(f.y, 150, accuracy: 1e-4, "y 는 1−p.y (0x140189b95 subss)")
    }

    /// 중앙↔마우스 **선형보간**임을 못박는다.
    func testFocusIsLinearInterpolation() {
        let p = Vec2(x: 1, y: 0)
        let half = SceneCameraMath.parallaxFocus(pointer: p, mouseInfluence: 0.5, projW: 256, projH: 256)
        XCTAssertEqual(half.x, 128 * 0.5 + 256 * 0.5, accuracy: 1e-4)
        XCTAssertEqual(half.y, 128 * 0.5 + 256 * 0.5, accuracy: 1e-4)
    }

    /// 포인터는 0..1 로 클램프된다(`maxss`/`minss`).
    func testPointerIsClamped() {
        let f = SceneCameraMath.parallaxFocus(pointer: Vec2(x: 5, y: -5), mouseInfluence: 1,
                                              projW: 256, projH: 256)
        XCTAssertEqual(f.x, 256, accuracy: 1e-4)
        XCTAssertEqual(f.y, 256, accuracy: 1e-4)
    }

    /// eye(shake 가 이미 가산된 런타임 카메라)가 초점에 더해진다 — 2D 에서 shake 를 켜면
    /// `g_ParallaxPosition` 도 함께 떤다는 성질의 근거.
    func testEyeLeaksIntoFocus() {
        let f = SceneCameraMath.parallaxFocus(pointer: Vec2(x: 0.5, y: 0.5), mouseInfluence: 0,
                                              projW: 256, projH: 256, eye: Vec2(x: 3, y: -4))
        XCTAssertEqual(f.x, 131, accuracy: 1e-4)
        XCTAssertEqual(f.y, 124, accuracy: 1e-4)
    }

    // MARK: - cameraparallaxdelay

    /// α = min(1, 10·(1 − delay/3)·dt). 닫힌 식 값으로 고정한다.
    func testAlphaClosedForm() {
        let dt: Float = 1.0 / 60
        XCTAssertEqual(SceneCameraMath.parallaxAlpha(dt: dt, delay: 0.1), 0.1611111, accuracy: 1e-6)
        XCTAssertEqual(SceneCameraMath.parallaxAlpha(dt: dt, delay: 0.3), 0.15, accuracy: 1e-6)
        XCTAssertEqual(SceneCameraMath.parallaxAlpha(dt: dt, delay: 1.0), 0.1111111, accuracy: 1e-6)
    }

    /// 상한만 있다 — 하한 클램프 없음. delay 3 은 정지, delay > 3 은 발산(실물 결함 그대로).
    func testAlphaHasUpperClampOnly() {
        XCTAssertEqual(SceneCameraMath.parallaxAlpha(dt: 1, delay: 0.1), 1, accuracy: 1e-6, "상한 1")
        XCTAssertEqual(SceneCameraMath.parallaxAlpha(dt: 1.0 / 60, delay: 3), 0, accuracy: 1e-7)
        XCTAssertLessThan(SceneCameraMath.parallaxAlpha(dt: 1.0 / 60, delay: 4), 0, "delay>3 은 음수 = 발산")
    }

    /// **프레임률 독립이 아니다.** α 가 dt 에 선형이라 60Hz 와 120Hz 가 엄밀히는 다르다.
    /// 지수형(`1−exp(−dt/τ)`)으로 되돌리면 이 테스트가 깨진다.
    func testAlphaIsLinearInDtNotExponential() {
        let d: Float = 0.3
        let a60 = SceneCameraMath.parallaxAlpha(dt: 1.0 / 60, delay: d)
        let a120 = SceneCameraMath.parallaxAlpha(dt: 1.0 / 120, delay: d)
        XCTAssertEqual(a60, a120 * 2, accuracy: 1e-7, "dt 선형이면 정확히 2배")
        // 지수형이라면 a60 < 2·a120 이어야 한다 — 그 성질이 없음을 확인.
        var v60 = Vec2(x: 0, y: 0), v120 = Vec2(x: 0, y: 0)
        let tgt = Vec2(x: 1, y: 0)
        for _ in 0..<60 { v60 = SceneCameraMath.parallaxSmoothed(current: v60, target: tgt, dt: 1.0 / 60, delay: d) }
        for _ in 0..<120 { v120 = SceneCameraMath.parallaxSmoothed(current: v120, target: tgt, dt: 1.0 / 120, delay: d) }
        XCTAssertNotEqual(v60.x, v120.x, "선형 α 는 프레임률 의존이라 완전히 같을 수 없다")
        XCTAssertEqual(v60.x, v120.x, accuracy: 1e-3, "그래도 1초 후 차이는 1e-3 미만")
    }

    /// delay ≤ 0 은 스무딩 분기 자체를 건너뛰어 즉시 스냅.
    func testNonPositiveDelaySnaps() {
        let t = Vec2(x: 7, y: -3)
        XCTAssertEqual(SceneCameraMath.parallaxSmoothed(current: .init(x: 0, y: 0), target: t, dt: 0.016, delay: 0), t)
        XCTAssertEqual(SceneCameraMath.parallaxSmoothed(current: .init(x: 0, y: 0), target: t, dt: 0.016, delay: -1), t)
    }

    /// dt == 0 이면 α = 0 → **current 유지**(실물에 dt 가드가 없다).
    func testZeroDtHoldsCurrent() {
        let c = Vec2(x: 2, y: 2)
        XCTAssertEqual(SceneCameraMath.parallaxSmoothed(current: c, target: .init(x: 9, y: 9), dt: 0, delay: 0.1), c)
    }

    // MARK: - 레이어 시차 오프셋 / 유니폼

    /// `(origin − focus) × amount × depth`, z 는 **항상 0**.
    func testLayerOffsetFormula() {
        let off = SceneCameraMath.parallaxLayerOffset(origin: Vec2(x: 200, y: 50),
                                                      focus: Vec2(x: 128, y: 128),
                                                      amount: 0.5, depth: Vec2(x: 1, y: 0.25))
        XCTAssertEqual(off.x, 0.5 * 72 * 1, accuracy: 1e-4)
        XCTAssertEqual(off.y, 0.5 * -78 * 0.25, accuracy: 1e-4)
        XCTAssertEqual(off.z, 0, "시차는 화면 평면 안에서만 일어난다(0x14018a0ef)")
    }

    /// `parallaxDepth = 0` 이면 그 레이어는 안 움직인다 — 동봉 유일한 parallax 실물
    /// (`effects/depthparallax/preview`)이 정확히 이 경우라 레이어 채널 도달이 0건이다.
    func testZeroDepthLayerDoesNotMove() {
        let off = SceneCameraMath.parallaxLayerOffset(origin: Vec2(x: 500, y: 0),
                                                      focus: Vec2(x: 300, y: 300),
                                                      amount: 0.5, depth: Vec2(x: 0, y: 0))
        XCTAssertEqual(off.x, 0); XCTAssertEqual(off.y, 0); XCTAssertEqual(off.z, 0)
    }

    /// 무저작 2D 씬의 `g_ParallaxPosition` 은 정확히 (0.5, 0.5) — 셰이더 중립점.
    func testUniformNeutralIsHalf() {
        let focus = SceneCameraMath.parallaxFocus(pointer: Vec2(x: 0.9, y: 0.1), mouseInfluence: 0,
                                                  projW: 256, projH: 256)
        let u = SceneCameraMath.parallaxUniform(focus: focus, projW: 256, projH: 256)
        XCTAssertEqual(u.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(u.y, 0.5, accuracy: 1e-6)
    }

    func testUniformIsClamped() {
        let u = SceneCameraMath.parallaxUniform(focus: Vec2(x: 900, y: -40), projW: 256, projH: 256)
        XCTAssertEqual(u.x, 1, accuracy: 1e-6)
        XCTAssertEqual(u.y, 0, accuracy: 1e-6)
    }

    // MARK: - 레이어 perspective 플래그

    /// 카메라 거리 `d = H / (2·tan(fov/2))` — 저작 기본 `fov 95° · H 256` → 117.29.
    func testLayerPerspectiveDistance() {
        XCTAssertEqual(SceneCameraMath.layerPerspectiveDistance(orthoHeight: 256, fovDegrees: 95),
                       117.29039, accuracy: 1e-3)
        XCTAssertEqual(SceneCameraMath.layerPerspectiveDistance(orthoHeight: 1080, fovDegrees: 95),
                       494.81885, accuracy: 1e-2)
        // 동봉 6씬이 저작한 비기본 fov.
        XCTAssertEqual(SceneCameraMath.layerPerspectiveDistance(orthoHeight: 256, fovDegrees: 90.760002),
                       126.31329, accuracy: 1e-3)
        // 닫힌 식과의 동치(전치 오류 방지).
        let d = SceneCameraMath.layerPerspectiveDistance(orthoHeight: 256, fovDegrees: 95)
        XCTAssertEqual(d, 256 / (2 * tanf(95 * .pi / 180 / 2)), accuracy: 1e-3)
    }

    /// **z = 0 은 정사영과 픽셀 동일**(배율 1). 코퍼스 유일 저작 사례가 z=0 이라 실피해가 0인 근거.
    func testZeroDepthIsIdenticalToOrthographic() {
        XCTAssertEqual(SceneCameraMath.layerPerspectiveScale(z: 0, orthoHeight: 256, fovDegrees: 95),
                       1, accuracy: 1e-6)
    }

    /// 카메라 쪽(+z)으로 갈수록 커지고 멀어질수록 작아진다 — `s(z) = d/(d − z)`.
    func testPerspectiveScaleGrowsTowardCamera() {
        let up = SceneCameraMath.layerPerspectiveScale(z: 10, orthoHeight: 256, fovDegrees: 95)
        let down = SceneCameraMath.layerPerspectiveScale(z: -10, orthoHeight: 256, fovDegrees: 95)
        XCTAssertEqual(up, 1.093205, accuracy: 1e-4)
        XCTAssertGreaterThan(up, 1)
        XCTAssertLessThan(down, 1)
        XCTAssertEqual(down, 117.29039 / (117.29039 + 10), accuracy: 1e-4)
    }

    /// near = 5, far = max(15000, d + 1000).
    func testLayerPerspectiveClip() {
        let small = SceneCameraMath.layerPerspectiveClip(distance: 117.29039)
        XCTAssertEqual(small.near, 5)
        XCTAssertEqual(small.far, 15000, accuracy: 1e-3, "d+1000 이 15000 미만이면 15000 바닥")
        let big = SceneCameraMath.layerPerspectiveClip(distance: 20000)
        XCTAssertEqual(big.far, 21000, accuracy: 1e-3)
    }
}
