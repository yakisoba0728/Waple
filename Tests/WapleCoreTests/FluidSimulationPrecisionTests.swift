import XCTest
@testable import WapleCore

/// **`r16f`/`rg16f`/`rgba8888` 반올림이 유체 솔버에 무엇을 하는가.**
///
/// `docs/re/fluid-simulation.md` §9-4 가 `[미해결]` 로 남긴 항목이다 —
/// *"`r16f`/`rg16f` 반올림이 §2.13 의 수치에 미치는 영향. …실물이 더 나쁠 것은 확실하나
/// 얼마나인지는 재지 않았다."* 여기서 재고, 답은 **"출하 설정에서는 사실상 0"** 이다.
/// 대신 반올림이 물리는 자리가 정확히 하나 있고(`u_Pressure = 1.0` 의 따뜻한 시작),
/// 그 자리는 그림에 안 닿는 대신 **염료 버퍼의 `rgba8888`** 이 훨씬 크게 문다.
///
/// 격자 실험은 실물 256×144 가 아니라 작은 격자로 돈다(디버그 빌드 시간). 결론은 규모에
/// 의존하지 않는 **부호와 자릿수**만 쓴다 — 절대값을 잠그지 않는다.
final class FluidSimulationPrecisionTests: XCTestCase {

    private func assertClose(_ a: Double, _ b: Double, _ tol: Double = 1e-12,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a, b, accuracy: tol, message, file: file, line: line)
    }

    // MARK: - P-1 binary16 자체

    func testBinary16RoundTripsKnownValues() {
        let q = FluidSimulationPrecision.binary16Quantize
        assertClose(q(1.0), 1.0, 0)
        assertClose(q(0.0), 0.0, 0)
        assertClose(q(-2.5), -2.5, 0)
        // 0.1 은 binary16 에 없다 — 가장 가까운 값은 0.0999755859375 다.
        assertClose(q(0.1), 0.0999755859375, 0)
        // 최대 정규수와 그 너머
        assertClose(q(65504), 65504, 0)
        XCTAssertTrue(q(70000).isInfinite)
        // 최소 준정규 2^-24, 그 절반은 짝수 쪽인 0 으로 접힌다(RTNE).
        assertClose(q(0x1p-24), 0x1p-24, 0)
        assertClose(q(0x1p-25), 0, 0)
        assertClose(q(0x1p-25 * 1.5), 0x1p-24, 0)
    }

    /// **반올림은 최근접-짝수다.** 정확히 반 ulp 떨어진 값은 짝수 가수 쪽으로 붙는다.
    /// 이게 아래 "정체" 의 기구다.
    func testBinary16RoundsHalfwayCasesToEven() {
        let q = FluidSimulationPrecision.binary16Quantize
        let ulp = FluidSimulationPrecision.binary16Ulp(1.0)
        assertClose(ulp, 0x1p-10, 0)
        // 1.0 의 가수는 짝수(0) → 정확히 반 ulp 위는 1.0 으로 내려붙는다.
        assertClose(q(1.0 + ulp / 2), 1.0, 0)
        // 1 + ulp 의 가수는 홀수(1) → 반 ulp 위는 1 + 2·ulp 로 올라붙는다.
        assertClose(q(1.0 + ulp + ulp / 2), 1.0 + 2 * ulp, 0)
    }

    /// **정규 구간에서 살아남는 가장 작은 상대 증분은 `2^-11`** 이다.
    /// Jacobi 가 정체하는 이유가 이 한 줄이다 — 갱신량이 반 ulp 아래로 떨어지면
    /// 저장이 그것을 통째로 버린다.
    func testUpdatesBelowHalfAnUlpVanishOnStore() {
        let q = FluidSimulationPrecision.binary16Quantize
        let step = FluidSimulationPrecision.binary16SmallestResolvableRelativeStep
        assertClose(step, 0x1p-11, 0)
        // 반 ulp 미만은 사라진다 — 1000번 더해도 값이 안 움직인다.
        var x = 1.0
        for _ in 0..<1000 { x = q(x + step / 2) }
        assertClose(x, 1.0, 0, "반 ulp 미만 증분은 몇 번을 더해도 저장에서 사라진다")
        // 반 ulp 를 확실히 넘기면 움직인다.
        var y = 1.0
        for _ in 0..<4 { y = q(y + 3 * step / 2) }
        XCTAssertGreaterThan(y, 1.0)
    }

    func testBinary16UlpMatchesTheFormat() {
        let u = FluidSimulationPrecision.binary16Ulp
        assertClose(u(1.0), 0x1p-10, 0)
        assertClose(u(1023.5), 0x1p-1, 0)      // [512, 1024) → ulp 0.5
        assertClose(u(1024.0), 0x1p0, 0)
        assertClose(u(0), 0x1p-24, 0)          // 준정규 구간은 간격이 균일하다
        assertClose(u(0x1p-15), 0x1p-24, 0)
    }

    // MARK: - P-2 §2.13(b) 를 binary16 으로 다시 — **차이가 없다**

    /// 실물 반복수 9회에서는 float64 와 binary16 의 잔존 발산이 **0.01 pp 안**에서 같다.
    /// 이유는 §2.13(a) 다 — 9회는 큰 규모 오차를 손도 못 대므로 **절단 오차가 반올림 오차를
    /// 세 자릿수 압도한다**. 즉 §2.13 의 float64 표는 실물에서 그대로 유효하다.
    ///
    /// **되돌리면 깨진다**: 이 단언이 실패하면 "반올림이 §2.13 을 흔든다" 는 뜻이고
    /// 그때는 문서의 표를 다시 재야 한다.
    func testNineJacobiIterationsAreInsensitiveToHalfPrecision() {
        let (vx, vy) = FluidSimulationGrid.gaussianVelocityField(width: 64, height: 36,
                                                                 sigma: 6, amplitude: 40)
        let f64 = FluidSimulationGrid.projectionResidualPercent(
            velocityX: vx, velocityY: vy, width: 64, height: 36, iterations: 9,
            precision: .float64)
        let f16 = FluidSimulationGrid.projectionResidualPercent(
            velocityX: vx, velocityY: vy, width: 64, height: 36, iterations: 9,
            precision: .binary16)
        XCTAssertEqual(f64, f16, accuracy: 0.01,
                       "9회에서는 절단 오차가 반올림 오차를 압도한다 (f64 \(f64)% · f16 \(f16)%)")
        XCTAssertGreaterThan(f64, 50, "9회는 이 규모의 발산을 대부분 못 지운다 — §2.13(a)")
    }

    /// §2.13(c) 의 재현: `gradientsubtract` 에 0.5 를 넣은 "이론적으로 옳은" 변종은
    /// **반복 9회에서 원본보다 나쁘다**. 계수와 반복수가 한 쌍이라는 것의 값 증거.
    /// **되돌리면 깨진다**: 원본 계수를 0.5 로 바꾸면 부등호가 뒤집힌다.
    func testOriginalGradientCoefficientBeatsTheHalvedVariantAtNineIterations() {
        let (vx, vy) = FluidSimulationGrid.gaussianVelocityField(width: 64, height: 36,
                                                                 sigma: 6, amplitude: 40)
        let original = FluidSimulationGrid.projectionResidualPercent(
            velocityX: vx, velocityY: vy, width: 64, height: 36, iterations: 9,
            coefficient: FluidSimulationGrid.originalGradientCoefficient)
        let halved = FluidSimulationGrid.projectionResidualPercent(
            velocityX: vx, velocityY: vy, width: 64, height: 36, iterations: 9,
            coefficient: 0.5)
        XCTAssertLessThan(original, halved,
                          "원본(계수 1.0) \(original)% 이 0.5 변종 \(halved)% 을 이겨야 한다")
        XCTAssertEqual(FluidSimulationGrid.originalGradientCoefficient, 1.0)
    }

    // MARK: - P-3 반올림이 실제로 무는 자리 — `u_Pressure = 1.0` 의 따뜻한 시작

    /// **`u_Pressure` 가 1.0 이면 binary16 이 float64 를 못 따라간다.**
    /// 압력이 프레임을 넘어 무한히 누적되는데, 누적이 커질수록 한 번의 Jacobi 갱신이
    /// 반 ulp 아래로 내려가 사라지기 때문이다(P-1). 감쇠가 조금이라도 있으면
    /// 누적 상한이 생겨 이 한계에 닿기 전에 멈춘다 — 아래 두 케이스가 그 대비다.
    func testHalfPrecisionStallsOnlyWhenPressureCarriesOverWithoutDecay() {
        let w = 32, h = 18
        let (vx, vy) = FluidSimulationGrid.gaussianVelocityField(width: w, height: h,
                                                                 sigma: 3, amplitude: 40)
        let divergence = FluidSimulationGrid.divergenceField(velocityX: vx, velocityY: vy,
                                                             width: w, height: h)
        // (a) 감쇠 없음(u_Pressure = 1.0) — 정밀도가 갈린다.
        let noDecay64 = FluidSimulationGrid.warmStartResidualPercent(
            divergence: divergence, width: w, height: h, frames: 200,
            pressureDecay: 1.0, precision: .float64)
        let noDecay16 = FluidSimulationGrid.warmStartResidualPercent(
            divergence: divergence, width: w, height: h, frames: 200,
            pressureDecay: 1.0, precision: .binary16)
        XCTAssertGreaterThan(noDecay16, noDecay64 * 3,
                             "binary16 \(noDecay16)% 가 float64 \(noDecay64)% 보다 몇 배 나빠야 한다")
        XCTAssertLessThan(noDecay64, 2.0)

        // (b) 기본값 0.8 — 정밀도가 안 갈린다. **감쇠가 r16f 한계를 가린다.**
        let decayed64 = FluidSimulationGrid.warmStartResidualPercent(
            divergence: divergence, width: w, height: h, frames: 60,
            pressureDecay: 0.8, precision: .float64)
        let decayed16 = FluidSimulationGrid.warmStartResidualPercent(
            divergence: divergence, width: w, height: h, frames: 60,
            pressureDecay: 0.8, precision: .binary16)
        XCTAssertEqual(decayed64, decayed16, accuracy: 0.1,
                       "감쇠 0.8 이면 누적 상한이 생겨 반올림이 안 문다")
        XCTAssertGreaterThan(decayed64, 20, "0.8 은 따뜻한 시작으로 거의 벌지 못한다 — §2.13(d)")
    }

    // MARK: - P-4 진짜로 그림에 닿는 반올림 — LDR 염료 (신규)

    /// **비 HDR 씬에서 정지한 염료는 0 으로 안 내려간다.**
    ///
    /// `_rt_SmokeDye1/2` 는 `rgba_backbuffer` 라 씬 HDR 비트가 꺼지면 `rgba8888` 이다
    /// (설치본 씬 184개 중 `general.hdr` 참은 3개뿐이고, **이 이펙트의 preview 씬도 거짓**이다).
    /// 흐름이 멎으면 염료 패스는 `dye ← dye/(decay + lowPass)` 한 줄이 되는데, 60 fps 기본값에서
    /// 프레임당 감소가 0.66 % 라 **레벨 75 아래로는 반 레벨을 못 채워** 그대로 얼어붙는다.
    ///
    /// 이것이 §4.3 의 정정이다 — 그 절은 `clearDye`(실제로는 속도장을 비운다) 뒤에 염료가
    /// "제자리에서 지수 감쇠만 한다" 고 적었는데, LDR 에서는 **29 % 밝기에서 영구히 멈춘다.**
    func testStaticDyeFreezesPartWayDownInAnLDRBuffer() {
        let stall = FluidSimulationPrecision.ldrDyeDecayFixedPoint(
            startLevel: 255, dissipationFactor: 1.0, materialDissipation: 0.4,
            lifetime: 0.1, frameTime: 1.0 / 60)
        XCTAssertNotNil(stall, "0 까지 내려가면 안 된다 — 8비트 저장이 막는다")
        XCTAssertEqual(stall?.level, 75)
        XCTAssertEqual(FluidSimulationPrecision.unorm8Load(75), 75.0 / 255, accuracy: 1e-15)
    }

    /// **정체 레벨은 프레임률에 따라 올라간다** — 프레임당 감소가 1/fps 로 줄어드는데
    /// 반올림 문턱은 0.5/255 로 고정이기 때문이다. 즉 **화면이 빠를수록 잔상이 밝다.**
    /// 20 fps 이하는 `dt` 상한(1/20)에 걸려 더 나빠지지 않는다.
    func testTheLDRStallLevelRisesWithFrameRateAndSaturatesAtTheDtCap() {
        func stall(_ fps: Double) -> Int? {
            FluidSimulationPrecision.ldrDyeDecayFixedPoint(
                startLevel: 255, dissipationFactor: 1.0, materialDissipation: 0.4,
                lifetime: 0.1, frameTime: 1.0 / fps).map { Int($0.level) }
        }
        XCTAssertEqual(stall(10), 25, "dt 가 1/20 에서 잘리므로 20 fps 와 같아야 한다")
        XCTAssertEqual(stall(20), 25)
        XCTAssertEqual(stall(30), 37)
        XCTAssertEqual(stall(60), 75)
        XCTAssertEqual(stall(120), 150)
        XCTAssertEqual(stall(144), 180)
    }

    /// `u_Lifetime` 을 키우면 `lowPass`(÷1.5) 가 정체 레벨 위까지 올라와 염료가 빠져나간다 —
    /// 다만 **60 fps 에서는 preview 값 0.32 로도 부족하다**(lowPass 대역 47 < 정체 75).
    /// 30 fps 에서는 대역 47 > 정체 37 이라 통과해 1/255 까지 내려간다.
    /// 이 갈림이 "같은 씬이 모니터에 따라 다르게 보인다" 의 정확한 기구다.
    func testLowPassOnlyRescuesTheDyeWhenItsBandReachesAboveTheStallLevel() {
        func stall(_ fps: Double, _ lifetime: Double) -> Int? {
            FluidSimulationPrecision.ldrDyeDecayFixedPoint(
                startLevel: 255, dissipationFactor: 1.0, materialDissipation: 0.4,
                lifetime: lifetime, frameTime: 1.0 / fps).map { Int($0.level) }
        }
        XCTAssertEqual(stall(60, 0.32), 75, "60 fps 에서는 preview 의 0.32 로도 못 구한다")
        XCTAssertEqual(stall(30, 0.32), 1, "30 fps 에서는 lowPass 대역이 정체 레벨을 덮는다")
    }

    /// unorm8 저장은 최근접-짝수다(0.5 레벨 경계 확인).
    func testUnorm8StoreRoundsToNearestEven() {
        XCTAssertEqual(FluidSimulationPrecision.unorm8Store(0), 0)
        XCTAssertEqual(FluidSimulationPrecision.unorm8Store(1), 255)
        XCTAssertEqual(FluidSimulationPrecision.unorm8Store(-5), 0)
        XCTAssertEqual(FluidSimulationPrecision.unorm8Store(5), 255)
        XCTAssertEqual(FluidSimulationPrecision.unorm8Store(0.5 / 255), 0, "짝수 쪽으로")
        XCTAssertEqual(FluidSimulationPrecision.unorm8Store(1.5 / 255), 2, "짝수 쪽으로")
        XCTAssertEqual(FluidSimulationPrecision.unorm8Store(1.4 / 255), 1)
    }
}
