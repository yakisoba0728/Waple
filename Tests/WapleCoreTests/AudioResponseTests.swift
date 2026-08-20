import XCTest
import simd
@testable import WapleCore

final class AudioResponseTests: XCTestCase {
    private let zeros = [Float](repeating: 0, count: 16)
    private let ones = [Float](repeating: 1, count: 16)

    func testSilenceIsZero() {
        let r = AudioResponse.compute(left: zeros, right: zeros, mode: 3, freqMin: 0, freqMax: 15,
                                      bounds: SIMD2(0, 1), power: 1, multiply: 1)
        XCTAssertEqual(r, 0, accuracy: 1e-6)
    }

    func testFullIsOne() {
        // all-ones, bounds(0,1): sum/denom=1 → smoothstep(0,1,1)=1 → pow/saturate/×1 = 1.
        let r = AudioResponse.compute(left: ones, right: ones, mode: 3, freqMin: 0, freqMax: 15,
                                      bounds: SIMD2(0, 1), power: 1, multiply: 1)
        XCTAssertEqual(r, 1, accuracy: 1e-6)
    }

    func testModeOffReturnsZero() {
        XCTAssertEqual(AudioResponse.compute(left: ones, right: ones, mode: 0, freqMin: 0, freqMax: 15,
                                             bounds: SIMD2(0, 1), power: 1, multiply: 1), 0)
    }

    func testInclusiveSingleBinAverage() {
        // mode 1(L), freq 2..2 inclusive → avg of L[2] only. L[2]=0.5, bounds(0,1) → smoothstep=0.5.
        var l = zeros; l[2] = 0.5
        let r = AudioResponse.compute(left: l, right: zeros, mode: 1, freqMin: 2, freqMax: 2,
                                      bounds: SIMD2(0, 1), power: 1, multiply: 1)
        XCTAssertEqual(r, 0.5, accuracy: 1e-5)
    }

    func testStereoAverage() {
        // mode 3, freq 0..1: L=[1,1...], R=[0...] → sum=(1+0)+(1+0)=2, denom=(2)*2=4 → 0.5.
        var l = zeros; l[0] = 1; l[1] = 1
        let r = AudioResponse.compute(left: l, right: zeros, mode: 3, freqMin: 0, freqMax: 1,
                                      bounds: SIMD2(0, 1), power: 1, multiply: 1)
        XCTAssertEqual(r, 0.5, accuracy: 1e-5)
    }

    func testMultiplyAndExponent() {
        // resp 0.5, power 2 → 0.25, ×2 → 0.5.
        var l = zeros; for i in 0..<16 { l[i] = 0.5 }
        let r = AudioResponse.compute(left: l, right: l, mode: 3, freqMin: 0, freqMax: 15,
                                      bounds: SIMD2(0, 1), power: 2, multiply: 2)
        XCTAssertEqual(r, 0.5, accuracy: 1e-5)
    }

    func testBoundsClampLow() {
        // resp 0.3 < bounds.x 0.5 → smoothstep=0.
        var l = zeros; for i in 0..<16 { l[i] = 0.3 }
        let r = AudioResponse.compute(left: l, right: l, mode: 3, freqMin: 0, freqMax: 15,
                                      bounds: SIMD2(0.5, 1), power: 1, multiply: 1)
        XCTAssertEqual(r, 0, accuracy: 1e-5)
    }

    /// 감사 V05: ±1e19(Float 유한, Int 범위 밖)가 Int() 변환에서 트랩하던 회귀. **무트랩이 계약이고,
    /// 값은 이제 셰이더 규약을 따른다** — 분모가 원시 float `(max − min + 1)×2` 라 ±1e19 범위에서는
    /// 4e19 가 되어 응답이 0 으로 눌린다. WE 도 같은 나눗셈을 하므로 이쪽이 오히려 원문에 가깝다.
    /// (실제 도달은 없다 — 셰이더 어노테이션이 `"int":true, "range":[0,15]` 로 못박는다.)
    func testHugeFiniteFreqRangeNoTrap() {
        let r = AudioResponse.compute(left: ones, right: ones, mode: 3, freqMin: -1e19, freqMax: 1e19,
                                      bounds: SIMD2(0, 1), power: 1, multiply: 1)
        XCTAssertTrue(r.isFinite, "무트랩·유한이 이 테스트의 계약이다")
        XCTAssertEqual(r, 0, accuracy: 1e-5, "분모 4e19 — WE 도 같은 나눗셈을 한다")
        // 전범위 위(lo > hi): 빈 구간 → 0, 무트랩.
        let r2 = AudioResponse.compute(left: ones, right: ones, mode: 3, freqMin: 1e19, freqMax: 1e19,
                                       bounds: SIMD2(0, 1), power: 1, multiply: 1)
        XCTAssertEqual(r2, 0, accuracy: 1e-5)
    }

    /// 감사 V06: NaN 은 Swift min/max 를 통과해 bin() 의 Int() 변환 트랩 — 그 방어는 유지한다.
    /// **다만 값은 0 이다.** 분모 `(max − min + 1)` 에 NaN 이 들어가면 비유한이 되고, 우리는 그때
    /// 나눗셈을 하지 않고 0 으로 떨어뜨린다. WE 는 그 자리에서 NaN 을 만들고 `smoothstep`/`saturate`
    /// 로 흘려보내는데 GLSL 상 미정의다 — 미정의 동작을 흉내 내는 대신 **무응답**을 고른다.
    func testNaNFreqRangeNoTrap() {
        let bothNaN = AudioResponse.compute(left: ones, right: ones, mode: 3, freqMin: .nan, freqMax: .nan,
                                            bounds: SIMD2(0, 1), power: 1, multiply: 1)
        XCTAssertTrue(bothNaN.isFinite, "무트랩·유한이 계약")
        XCTAssertEqual(bothNaN, 0, accuracy: 1e-5, "분모가 NaN — 미정의 대신 무응답")
        let minNaN = AudioResponse.compute(left: ones, right: ones, mode: 3, freqMin: .nan, freqMax: 15,
                                           bounds: SIMD2(0, 1), power: 1, multiply: 1)
        XCTAssertEqual(minNaN, 0, accuracy: 1e-5)
    }

    /// **정정(2026-08-20).** 종전 이 테스트는 "분모는 실제 합산 빈 수여야 한다" 를 계약으로 걸었다.
    /// 동봉 셰이더 원문이 그걸 반증한다 — `effects/pulse/shaders/effects/pulse.vert`:
    ///
    ///     audioResponse /= (g_AudioFrequencyMax - g_AudioFrequencyMin + 1.0) * 2.0;   // 모드 3
    ///
    /// 분모는 **선언된 범위**이지 실제 합산 개수가 아니다. 종전 근거였던 "mode 3 비대칭(right < left)"
    /// 은 애초에 프로덕션에 존재하지 않는다 — `AudioSpectrum16.downsample16` 이 항상 16/16 을 낸다.
    /// **일어나지 않는 경우를 고치려다 실재하는 규약을 깬 것**이었다.
    func testAsymmetricStereoUsesDeclaredRangeAsDenominator() {
        let right8 = [Float](repeating: 1, count: 8)
        let r = AudioResponse.compute(left: ones, right: right8, mode: 3, freqMin: 0, freqMax: 15,
                                      bounds: SIMD2(0, 1), power: 1, multiply: 1)
        // sum = 16(L) + 8(R) = 24, denom = (15−0+1)×2 = 32 → 0.75 → smoothstep(0,1,0.75) = 0.84375
        XCTAssertEqual(r, 0.84375, accuracy: 1e-5, "선언 범위로 나눈다 — 셰이더 원문 그대로")
    }

    /// `audioFrequencyEnd = max(min, max)` 는 셰이더에서 **계산만 하고 루프가 쓰지 않는 죽은 변수**다.
    /// 루프 상한은 `g_AudioFrequencyMax` 하나이므로 `min > max` 면 루프가 0회 → 응답 0.
    /// 종전 구현은 그 죽은 변수를 살려 `hi = max(bin(min), bin(max))` 로 썼고, 그래서 이 경우에
    /// min 쪽 빈을 읽어 0 이 아닌 값을 냈다.
    func testInvertedRangeYieldsNoResponse() {
        let r = AudioResponse.compute(left: ones, right: ones, mode: 3, freqMin: 5, freqMax: 2,
                                      bounds: SIMD2(0, 1), power: 1, multiply: 1)
        XCTAssertEqual(r, 0, accuracy: 1e-5, "역전 범위는 루프 0회 — 응답 없음")
    }
}
