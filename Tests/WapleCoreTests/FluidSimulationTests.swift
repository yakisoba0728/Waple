import XCTest
@testable import WapleCore

/// **`effects/fluidsimulation` 의 패스별 산술 — 원본과 갈리는 자리만 값으로 잠근다.**
///
/// 이 스위트의 규율 하나: **"순진한 이식" 과 원본이 같은 답을 내는 자리는 테스트하지 않는다.**
/// 둘 다 통과하는 테스트는 아무것도 잠그지 않기 때문이다. 그래서 케이스마다 "무엇을 되돌리면
/// 이 테스트가 깨지는가" 를 주석에 적는다.
///
/// 출처는 전부 동봉 `WEAssets/effects/fluidsimulation/shaders/effects/*.frag|vert` 이고
/// 설명은 `docs/re/fluid-simulation.md` §2 · §5 다.
final class FluidSimulationTests: XCTestCase {

    private typealias V = FluidSimulation.Vec2

    private func assertClose(_ a: Double, _ b: Double, _ tol: Double = 1e-12,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a, b, accuracy: tol, message, file: file, line: line)
    }

    // MARK: - F-1 시간 규약 (§2.12)

    /// `dt = min(1/20, g_Frametime)` — 20 fps 아래에서 한 스텝이 50 ms 를 못 넘는다.
    /// **되돌리면 깨진다**: 상한을 없애거나 1/30 으로 바꾸면.
    func testSimulationTimeStepIsCappedAtFiftyMilliseconds() {
        assertClose(FluidSimulation.simulationTimeStep(frameTime: 1.0 / 60), 1.0 / 60)
        assertClose(FluidSimulation.simulationTimeStep(frameTime: 1.0 / 10), 1.0 / 20)
        assertClose(FluidSimulation.simulationTimeStep(frameTime: 10), 0.05)
    }

    /// **압력 감쇠만 생 `g_Frametime`** 을 쓴다(`clear.vert`: `pow(u_Pressure, 60 * g_Frametime)`).
    /// 10 fps 에서 클램프된 `dt` 를 쓰면 지수가 3, 생 프레임타임이면 6 이라 값이 두 배 갈린다.
    /// **되돌리면 깨진다**: `simulationTimeStep` 을 여기 끼워 넣으면 0.512 가 나온다.
    func testPressureDecayUsesRawFrameTimeNotTheClampedStep() {
        assertClose(FluidSimulation.pressureDecayFactor(pressure: 0.8, frameTime: 1.0 / 60), 0.8, 1e-12)
        let tenFps = FluidSimulation.pressureDecayFactor(pressure: 0.8, frameTime: 0.1)
        assertClose(tenFps, pow(0.8, 6), 1e-12)
        assertClose(tenFps, 0.262144, 1e-9)
        XCTAssertNotEqual(tenFps, pow(0.8, 3), "클램프된 dt 를 쓰면 0.512 다 — 그건 틀렸다")
    }

    // MARK: - F-2 curl 의 스위즐 (§2.2)

    /// `curl` 은 L/R 을 속도의 **y 성분**에서, T/B 를 **x 성분**에서 읽고
    /// `R - L - T + B` 를 만든다. 주석 처리된 대안 `R - L - B + T` 가 원본에 남아 있어서
    /// 부호를 뒤집기 쉬운 자리다.
    /// **되돌리면 깨진다**: `- T + B` 를 `- B + T` 로 바꾸면 부호가 뒤집힌다.
    func testCurlSignFollowsTheShippedExpressionNotTheCommentedAlternative() {
        let c = FluidSimulation.curl(velocityYLeft: 1, velocityYRight: 5,
                                     velocityXTop: 2, velocityXBottom: 8)
        assertClose(c, 0.5 * (5 - 1 - 2 + 8))
        assertClose(c, 5.0)
        XCTAssertNotEqual(c, 0.5 * (5 - 1 - 8 + 2))
    }

    // MARK: - F-3 와도 구속의 성분 뒤집기 (§2.3)

    /// `force = 0.5 * vec2(abs(T) - abs(B), abs(R) - abs(L))` — **x 성분이 세로 차분**,
    /// **y 성분이 가로 차분**이다. 그 뒤 `force.y *= -1` 이 2차원 외적을 만든다.
    /// **되돌리면 깨진다**: 성분 순서를 "정상" 으로 되돌리거나 `force.y *= -1` 을 지우면.
    func testVorticityForceSwapsComponentsAndNegatesY() {
        // |T|=4, |B|=0, |R|=0, |L|=0 → 정규화 전 (2, 0) → 정규화 후 ≈ (1, 0)
        let f = FluidSimulation.vorticityConfinementForce(
            curlLeft: 0, curlRight: 0, curlTop: 4, curlBottom: 0,
            curlCenter: 1, curlStrength: 30)
        // 세로 차분만 있는데 결과가 x 성분에 실린다 — 순서가 뒤바뀌었다는 증거.
        XCTAssertGreaterThan(f.x, 29.9)
        assertClose(f.y, 0, 1e-12)

        // |R|=4 만 있으면 결과는 y 에 실리고 **음수**여야 한다(force.y *= -1).
        let g = FluidSimulation.vorticityConfinementForce(
            curlLeft: 0, curlRight: 4, curlTop: 0, curlBottom: 0,
            curlCenter: 1, curlStrength: 30)
        assertClose(g.x, 0, 1e-12)
        XCTAssertLessThan(g.y, -29.9, "force.y *= -1 이 빠지면 +30 이 된다")
    }

    /// 0-나눗셈 가드 `+0.0001` — 컬이 완전히 평평하면 힘이 정확히 0 이어야 하고
    /// NaN 이 나오면 안 된다.
    func testVorticityForceIsFiniteOnAFlatCurlField() {
        let f = FluidSimulation.vorticityConfinementForce(
            curlLeft: 0, curlRight: 0, curlTop: 0, curlBottom: 0,
            curlCenter: 7, curlStrength: 30)
        XCTAssertTrue(f.x.isFinite && f.y.isFinite)
        assertClose(f.x, 0); assertClose(f.y, 0)
    }

    // MARK: - F-4 ±1000 클램프의 **위치** (§2.3 · §5.2 · §5.4)

    /// 셰이더는 와도 구속 직후 한 번만 클램프하고, **에미터와 커서 임펄스는 그 뒤에** 더한다.
    /// 즉 이 패스의 출력은 ±1000 을 넘을 수 있다.
    /// **되돌리면 깨진다**: "마지막에 한 번 클램프" 로 옮기면 아래 합이 1000 으로 잘린다.
    func testVelocityClampAppliesBeforeEmittersAndCursorNotAfter() {
        let clamped = FluidSimulation.applyVorticityConfinement(
            velocity: V(5000, 0), force: V(0, 0), dt: 1.0 / 60)
        assertClose(clamped.x, 1000)

        // 이제 에미터가 그 위에 더해진다 — 셰이더에는 재클램프가 없다.
        let emitter = FluidSimulation.pointEmitterVelocity(
            uv: V(0.5, 0.5), position: V(0.5, 0.5), angle: .pi / 2,
            size: 0.05, speed: 1000, frameTime: 1.0 / 60)
        let total = clamped.x + emitter.x
        XCTAssertGreaterThan(total, 1000, "재클램프가 없어야 1000 을 넘는다")
        assertClose(total, 1000 + 1000.0 / 60, 1e-9)
    }

    // MARK: - F-5 발산의 반사 경계 (§2.4)

    /// 네 개의 `if` 가 솔버 전체에서 **유일한 명시 경계조건**이다.
    /// **되돌리면 깨진다**: `if` 넷을 지우면 경계 셀 값이 내부 규칙과 같아진다.
    func testDivergenceReflectsTheNormalComponentOnlyAtTheOuterRing() {
        let center = V(3, 0)
        // 최외곽 왼쪽 열: vL.x < 0 → L = -C.x = -3
        let edge = FluidSimulation.divergence(
            velocityXLeft: 7, velocityXRight: 1, velocityYTop: 0, velocityYBottom: 0,
            center: center,
            neighborLeftU: -0.001, neighborRightU: 0.5, neighborTopV: 0.5, neighborBottomV: 0.5)
        assertClose(edge, 0.5 * (1 - (-3)))
        assertClose(edge, 2.0)

        // 내부: 반사 없음
        let inner = FluidSimulation.divergence(
            velocityXLeft: 7, velocityXRight: 1, velocityYTop: 0, velocityYBottom: 0,
            center: center,
            neighborLeftU: 0.25, neighborRightU: 0.5, neighborTopV: 0.5, neighborBottomV: 0.5)
        assertClose(inner, 0.5 * (1 - 7))
        assertClose(inner, -3.0)
        XCTAssertNotEqual(edge, inner)
    }

    /// 접선 성분은 **손대지 않는다**(자유 미끄럼). 왼쪽 벽에서 `T`/`B` 는 그대로다.
    func testDivergenceLeavesTheTangentialComponentToSamplerClamp() {
        let a = FluidSimulation.divergence(
            velocityXLeft: 0, velocityXRight: 0, velocityYTop: 9, velocityYBottom: 1,
            center: V(3, 5),
            neighborLeftU: -0.001, neighborRightU: 0.5, neighborTopV: 0.5, neighborBottomV: 0.5)
        // L 만 -3 으로 바뀌고 T/B 는 9/1 그대로 → 0.5*(0-(-3)+9-1)
        assertClose(a, 0.5 * (0 + 3 + 9 - 1))
    }

    // MARK: - F-6 Jacobi 와 경사 제거의 계수 (§2.6 · §2.7)

    func testJacobiUsesAlphaMinusOneAndBetaFour() {
        assertClose(FluidSimulation.jacobiPressure(left: 1, right: 2, top: 3, bottom: 4,
                                                   divergence: 10),
                    (1 + 2 + 4 + 3 - 10) * 0.25)
        XCTAssertEqual(FluidSimulation.pressureIterationCount, 9)
    }

    /// **`gradientsubtract` 에는 0.5 가 없다** — 이 이펙트에서 가장 베끼기 쉬운 오류다.
    /// curl/divergence 에는 0.5 가 있으니 "일관성" 을 이유로 넣기 쉽다.
    /// **되돌리면 깨진다**: `0.5 *` 를 붙이면 아래 값이 정확히 절반이 된다.
    func testPressureGradientSubtractionHasNoHalfCoefficient() {
        let v = FluidSimulation.subtractPressureGradient(
            velocity: V(10, 20),
            pressureLeft: 1, pressureRight: 5, pressureTop: 9, pressureBottom: 3)
        assertClose(v.x, 10 - (5 - 1))
        assertClose(v.y, 20 - (9 - 3))
        assertClose(v.x, 6); assertClose(v.y, 14)
        // 0.5 를 넣은 변종은 (8, 17) 이다 — 다른 값이어야 한다.
        XCTAssertNotEqual(v.x, 10 - 0.5 * (5 - 1))
    }

    // MARK: - F-7 이류의 소산과 lowPass (§2.8 · §2.9)

    /// `lowPass` 는 분모에 **더해진다**(곱이 아니다) → 발화하면 `÷1.5` 다.
    /// 그리고 `step(length, lifetime)` 이라 **같을 때도 발화**한다.
    /// **되돌리면 깨진다**: 곱으로 바꾸거나(`decay * 1.5`) 부등호를 엄격하게 바꾸면.
    func testAdvectionLowPassAddsToTheDenominatorAndFiresOnEquality() {
        let decay = FluidSimulation.advectionDecay(decayFactor: 1.0, materialDissipation: 0.2,
                                                   dt: 1.0 / 60)
        assertClose(decay, 1 + 0.2 / 60, 1e-15)

        XCTAssertEqual(FluidSimulation.advectionLowPass(sampleMagnitude: 0.05, lifetime: 0.1), 0.5)
        XCTAssertEqual(FluidSimulation.advectionLowPass(sampleMagnitude: 0.1, lifetime: 0.1), 0.5,
                       "step(edge, x) 는 x == edge 에서 1 이다")
        XCTAssertEqual(FluidSimulation.advectionLowPass(sampleMagnitude: 0.2, lifetime: 0.1), 0.0)

        let quiet = 1.0 / (decay + 0.5)
        let loud = 1.0 / decay
        XCTAssertLessThan(quiet, loud * 0.68, "발화하면 대략 ÷1.5 여야 한다 — 곱으로 바꾸면 이 비가 안 나온다")
    }

    /// `boundaryMask` 는 **염료 패스에만** 있고 `[0,1]` 양 끝을 포함한다.
    func testDyeBoundaryMaskIsInclusiveAtBothEnds() {
        XCTAssertEqual(FluidSimulation.dyeBoundaryMask(V(0.0, 0.0)), 1)
        XCTAssertEqual(FluidSimulation.dyeBoundaryMask(V(1.0, 1.0)), 1)
        XCTAssertEqual(FluidSimulation.dyeBoundaryMask(V(-1e-9, 0.5)), 0)
        XCTAssertEqual(FluidSimulation.dyeBoundaryMask(V(0.5, 1.0 + 1e-9)), 0)
    }

    /// 역추적 거리는 **속도 그리드의 텍셀 크기**로 UV 화한다. 속도 단위가 "텍셀/초" 라는
    /// 규약이 여기 한 줄에 걸려 있다.
    func testAdvectionBacktraceScalesVelocityByTheVelocityGridTexelSize() {
        // 256×144 그리드에서 x 로 256 텍셀/초, dt = 1/60 → UV 로 정확히 1/60 만큼 뒤로.
        let coord = FluidSimulation.advectionSourceCoordinate(
            uv: V(0.5, 0.5), velocity: V(256, 0), dt: 1.0 / 60,
            texelSize: V(1.0 / 256, 1.0 / 144))
        assertClose(coord.x, 0.5 - 1.0 / 60, 1e-15)
        assertClose(coord.y, 0.5)
    }

    // MARK: - F-8 중력만 생 프레임타임 · aspect 는 y 에만 (§2.8)

    /// `u_ConstantVelocityAngle` 기본값 π 는 `(sin π, -cos π) = (0, +1)` = UV +y = 화면 아래.
    /// `aspect` 는 **y 성분에만** 곱하고, 프레임타임은 **클램프되지 않은 생 값**이다.
    /// **되돌리면 깨진다**: `dt` 로 바꾸면 10 fps 에서 절반이 되고, aspect 를 빼면 세로 성분이
    /// 1.78배가 된다(= W1 의 재발).
    func testConstantForceUsesRawFrameTimeAndAppliesAspectToYOnly() {
        let aspect = 144.0 / 256.0
        let f = FluidSimulation.constantForce(angle: .pi, strength: 100,
                                              aspect: aspect, frameTime: 0.1)
        assertClose(f.x, 0, 1e-12)
        assertClose(f.y, 100 * aspect * 0.1, 1e-12)
        assertClose(f.y, 5.625, 1e-12)
        XCTAssertNotEqual(f.y, 100 * aspect * 0.05, "클램프된 dt 를 쓰면 절반이다")
        XCTAssertNotEqual(f.y, 100 * 0.1, "aspect 를 빼면 10 이다")
    }

    // MARK: - F-9 에미터의 aspect 비대칭 (§5.4)

    /// **속도 에미터는 `aspect` 를 안 쓰고(주석 처리) 염료 에미터는 쓴다.**
    /// 그래서 같은 `size` 에서 힘의 디스크는 UV 원(화면 타원)이고 색의 디스크는 화면 원이다.
    /// **되돌리면 깨진다**: 속도 쪽에 aspect 를 "복원" 하면 아래 두 값이 같아진다.
    func testVelocityEmitterIgnoresAspectWhileDyeEmitterUsesIt() {
        let aspect = 144.0 / 256.0
        let size = 0.05
        // 중심에서 y 로 0.07 떨어진 점: UV 거리 0.07 > size → 속도는 0.
        let uv = V(0.5, 0.56)
        let center = V(0.5, 0.5)

        let velocity = FluidSimulation.pointEmitterVelocity(
            uv: uv, position: center, angle: 0, size: size, speed: 100, frameTime: 1.0 / 60)
        assertClose(velocity.x, 0); assertClose(velocity.y, 0)

        // 같은 점을 염료 에미터로 재면 aspect 가 곱해져 유효 거리가 0.07*0.5625 = 0.039 < size
        // → **0 이 아니다**. 이 갈림이 원본 비대칭의 전부다.
        let dye = FluidSimulation.pointEmitterDyeAmount(uv: uv, position: center,
                                                        size: size, aspect: aspect)
        XCTAssertGreaterThan(dye, 0.2)
    }

    /// **문서 정정 (2026-08-21).** `docs/re/fluid-simulation.md` §5.4 는
    /// "`smoothstep(size, 0, x)` 를 `1 - smoothstep(0, size, x)` 로 고치면 안 된다 —
    /// 감쇠 곡선이 다르다" 고 적고 있었다. **대수적으로 같다.**
    /// `t = clamp(1 - x/size)` 라 두면 앞은 `t²(3-2t)`, 뒤는 `1 - (1-t)²(1+2t) = t²(3-2t)` 다.
    /// 즉 well-defined 형태로 바꿔도 그림이 바뀌지 않는다 — 오히려 `edge0 > edge1` 의
    /// 명세상 미정의 호출을 피할 수 있다.
    func testReverseSmoothstepEqualsOneMinusForwardSmoothstep() {
        for size in [0.02, 0.05, 0.3] {
            for i in 0...200 {
                let x = Double(i) / 100.0 * size          // 0 … 2*size
                let reverse = FluidSimulation.smoothstep(size, 0.0, x)
                let forward = 1.0 - FluidSimulation.smoothstep(0.0, size, x)
                XCTAssertEqual(reverse, forward, accuracy: 1e-15,
                               "size=\(size) x=\(x) 에서 갈렸다")
            }
        }
        // 중심 1 · 반경 0 이라는 경계값도 확인한다.
        assertClose(FluidSimulation.smoothstep(0.05, 0.0, 0.0), 1)
        assertClose(FluidSimulation.smoothstep(0.05, 0.0, 0.05), 0)
    }

    /// 선 에미터의 노이즈 게이트는 **성분별**이다 — x 는 켜지고 y 는 꺼질 수 있다.
    /// **되돌리면 깨진다**: 스칼라 게이트(`step(0.5, length(noise))`)로 바꾸면.
    func testLineEmitterNoiseGateIsPerComponent() {
        let f = FluidSimulation.lineEmitterVelocity(
            uv: V(0.2, 0.1), a: V(0.1, 0.1), b: V(0.4, 0.1),
            angle: .pi / 2, size: 0.02, speed: 1000, frameTime: 1.0 / 60,
            noise: V(0.9, 0.1))                   // x 통과, y 차단
        XCTAssertGreaterThan(f.x, 0)
        assertClose(f.y, 0, 1e-15)
    }

    // MARK: - F-10 커서 임펄스 (§5.1 · §5.2)

    /// 감쇠 반경의 역수 쌍은 `(60/c, (H/W)·60/c)` 이고 **둘 다 양수**다
    /// (`v_PointerUV.w` 가 `H/-W` 로 시작해 `*= -v_PointDelta.y` 로 부호가 두 번 뒤집힌다).
    /// **되돌리면 깨진다**: 부호를 한 번만 뒤집으면 y 스케일이 음수가 되어 원뿔이 뒤집힌다.
    func testCursorFalloffScaleIsPositiveOnBothAxesAndAspectCorrected() {
        let s = FluidSimulation.cursorImpulseFalloffScale(cursorInfluence: 1,
                                                          resolutionWidth: 256,
                                                          resolutionHeight: 144)
        assertClose(s.x, 60, 1e-12)
        assertClose(s.y, 60 * (144.0 / 256.0), 1e-12)
        XCTAssertGreaterThan(s.y, 0)
        // UV 반경 × 화면 픽셀 = x·y 가 같아야 한다(= 화면상 원).
        assertClose((1 / s.x) * 1920, (1 / s.y) * 1080, 1e-9)
    }

    /// 세기의 상수항은 **항상 0.5** 다 — `step(0, moveAmt)` 의 인자가 길이라 늘 ≥ 0 이다.
    func testCursorStrengthConstantTermIsAlwaysHalf() {
        assertClose(FluidSimulation.cursorImpulseStrengthScalar(
            pointerMove: 0, cursorInfluence: 1, pointerButtonForce: 0), 0.5)
        assertClose(FluidSimulation.cursorImpulseStrengthScalar(
            pointerMove: 0.01, cursorInfluence: 4, pointerButtonForce: 0), 0.5 + 0.01 * 10 * 4)
    }

    /// **커서가 멈춰 있으면 힘이 0 이다** — 세기에 상수항 0.5 와 클릭 항이 남아 있어도
    /// 방향 `lDelta` 가 0 이라 곱이 0 이 된다. 이걸 모르고 "정지 시에도 밀어야지" 하고
    /// 방향을 보정하면 커서 아래가 영구히 끓는다.
    func testStationaryCursorProducesNoImpulseEvenWhileClicking() {
        let p = V(0.5, 0.5)
        let f = FluidSimulation.cursorImpulse(
            uv: V(0.5, 0.5), pointer: p, pointerLast: p,
            cursorInfluence: 1, pointerButtonForce: 1, pointerMove: 0,
            resolutionWidth: 256, resolutionHeight: 144)
        assertClose(f.x, 0, 1e-9)
        assertClose(f.y, 0, 1e-9)
    }

    /// 움직이는 커서는 **이동 방향으로** 300 배 임펄스를 준다.
    func testMovingCursorPushesAlongTheMotionDirectionWithGain300() {
        let last = V(0.40, 0.50), now = V(0.42, 0.50)
        let move = (now - last).length
        let f = FluidSimulation.cursorImpulse(
            uv: now, pointer: now, pointerLast: last,
            cursorInfluence: 1, pointerButtonForce: 0, pointerMove: move,
            resolutionWidth: 256, resolutionHeight: 144)
        XCTAssertGreaterThan(f.x, 0)
        assertClose(f.y, 0, 1e-9)
        // 커서 위치에서는 rayMask 1 · 원뿔값이 1 에 아주 가까우므로
        // 300·(0.5 + 10·move) = 210 의 바로 아래여야 한다. **배율 300 이 빠지면 0.7 근처가 된다.**
        let naive = 300 * (0.5 + move * 10)
        XCTAssertGreaterThan(f.x, naive * 0.95)
        XCTAssertLessThanOrEqual(f.x, naive)
    }

    // MARK: - F-11 염료 α → 노멀 (§2.10)

    /// 클램프가 `×refAlpha` **앞**이라, 염료가 옅으면 경사가 아무리 가팔라도 평평해진다.
    /// **되돌리면 깨진다**: 순서를 바꾸면(곱하고 나서 클램프) 아래 값이 달라진다.
    func testDyeNormalClampsBeforeMultiplyingByAlpha() {
        // 경사 20 · 게인 25*0.5 = 12.5 → base = 250 → 클램프 1 → ×0.2 = 0.2
        let n = FluidSimulation.dyeNormalPacked(refAlpha: 0.2, alphaRight: 20.2, alphaTop: 0.2,
                                                depth: 0.5)
        assertClose(n.r, -0.2 * 0.5 + 0.5, 1e-12)     // normal.x = -base.x
        assertClose(n.g, 0.5, 1e-12)
        // 곱하고 나서 클램프하는 변종이면 base.x = 250*0.2 = 50 → 클램프 1 → r = 0.0 이다.
        XCTAssertNotEqual(n.r, 0.0, accuracy: 1e-9)
    }

    /// 염료가 없는 곳은 정확히 `(0,0,1)` 패킹 = `(0.5, 0.5, 1.0)`.
    func testDyeNormalIsFlatWhereThereIsNoDye() {
        let n = FluidSimulation.dyeNormalPacked(refAlpha: 0, alphaRight: 1, alphaTop: 1, depth: 1)
        assertClose(n.r, 0.5); assertClose(n.g, 0.5); assertClose(n.b, 1.0)
    }

    // MARK: - F-13 격자 배선 — 반사 `if` 가 최외곽 한 줄에서만 발화하는가

    /// 균일한 오른쪽 흐름 `v = (c, 0)` 을 넣으면 발산은 **왼쪽 열 `+c` · 오른쪽 열 `−c` ·
    /// 나머지 전부 0** 이어야 한다. 위/아래 행은 법선 성분이 `vy = 0` 이라 반사해도 0 이다.
    ///
    /// `FluidSimulationGrid.divergenceField` 가 이웃 좌표를 어떻게 만들어 `divergence(...)` 의
    /// 네 `if` 를 켜는지를 잠근다. **되돌리면 깨진다**: 조건을 내부값으로 고정하면 전부 0 이 된다.
    func testGridDivergenceFiresTheReflectionOnlyOnTheOuterColumns() {
        let w = 5, h = 4, c = 3.0
        let vx = [Double](repeating: c, count: w * h)
        let vy = [Double](repeating: 0, count: w * h)
        let d = FluidSimulationGrid.divergenceField(velocityX: vx, velocityY: vy,
                                                    width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let expected: Double = (x == 0) ? c : (x == w - 1 ? -c : 0)
                XCTAssertEqual(d[y * w + x], expected, accuracy: 1e-12,
                               "(\(x), \(y)) 에서 갈렸다")
            }
        }
        XCTAssertGreaterThan(FluidSimulationGrid.meanAbsolute(d), 0)
    }

    // MARK: - F-12 `functions` 소비 결함 (§4.2)

    /// `clearDye` 는 인덱스 `[6,7]` 로 **정확히 파스되지만** 소비 루프가 개수만 써서
    /// `fbos[0..1]`(= 속도장)을 비운다. `clearVelocity` 는 인덱스가 우연히 `[0,1]` 이라 맞는다.
    /// Waple 은 이 결함을 **재현하지 않는다**(§4.6) — 이 함수는 문서적 사실을 값으로 남길 뿐이다.
    func testMaterialFunctionClearIgnoresParsedIndicesAndTakesThePrefix() {
        let dye = FluidSimulation.materialFunctionClearedIndicesWE(declaredCount: 2, fboCount: 9)
        XCTAssertEqual(dye.indices, [0, 1], "이름은 Dye1/Dye2(=6,7) 인데 앞 두 장이 비워진다")
        XCTAssertEqual(dye.outOfRange, 0)

        // §4.5 의 범위 밖 접근: 중복 이름 20개를 선언하면 n=20 > |fbos|=9.
        let overflow = FluidSimulation.materialFunctionClearedIndicesWE(declaredCount: 20, fboCount: 9)
        XCTAssertEqual(overflow.indices.count, 20)
        XCTAssertEqual(overflow.outOfRange, 11, "경계 검사가 없어 11장이 배열 밖이다")
    }
}
