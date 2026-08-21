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

    // MARK: - 축약 방식은 경로마다 다르다

    /// 셰이더 경로는 **구간평균**(`pulse.vert` 의 `/= (max−min+1)`)이고, CPU 파티클/이미터
    /// 경로는 **구간 MAX** 다 — 실물 `0x14022a8a0` 이 구간을 돌며 `comiss`/`movaps` 로 러닝
    /// MAX 를 잡고(모드 3 은 레인마다 `L[i]+R[i]`, 0x14022a903–0x14022a90e) **나눗셈이 없다**.
    /// 모드 3 만 마지막에 ×0.5(`mulss xmm3, [0x1404926c0]` @0x14022a97c).
    ///
    /// 종전엔 파티클 경로도 셰이더 규약을 그대로 재사용했다. 베이스만 뜬 스펙트럼에서
    /// WE 1.0 vs Waple 0.0 으로 갈린다 — 좁은 피크가 있을 때만 드러나는 부류다.
    func testPeakReductionIsNotAverage() {
        var bass = [Float](repeating: 0, count: 16)
        bass[0] = 1.0; bass[1] = 0.15; bass[2] = 0.05
        func resp(_ r: AudioResponse.Reduction, mode: Int = 1) -> Float {
            AudioResponse.compute(left: bass, right: bass, mode: mode, freqMin: 0, freqMax: 15,
                                  bounds: SIMD2(0.8, 1.0), power: 2, multiply: 1, reduction: r)
        }
        // peak = 1.0 → t = (1.0−0.8)/0.2 = 1 → smoothstep 1 → pow 1 → 1.0
        XCTAssertEqual(resp(.peak), 1, accuracy: 1e-5, "구간 MAX 는 베이스 피크를 그대로 본다")
        // average = (1.0+0.15+0.05)/16 = 0.075 → t < 0 → 0
        XCTAssertEqual(resp(.average), 0, accuracy: 1e-5, "구간평균은 같은 스펙트럼에서 0 이다")
        // 모드 3 은 L+R 을 접고 ×0.5 하므로 좌우가 같으면 모드 1 과 같은 값이 나온다.
        XCTAssertEqual(resp(.peak, mode: 3), resp(.peak, mode: 1), accuracy: 1e-5,
                       "모드 3 의 ×0.5 는 L+R 을 다시 접는 것 — 좌우 동일 신호면 모드 1 과 같다")
    }

    /// 평탄한 스펙트럼에서는 두 축약이 같아야 한다 — 갈리는 것은 좁은 피크일 때뿐이라는 뜻이다.
    /// (이게 성립하지 않으면 위 테스트가 잡은 것이 축약 차이가 아니라 다른 회귀다.)
    func testFlatSpectrumAgreesBetweenReductions() {
        let flat = [Float](repeating: 0.9, count: 16)
        func resp(_ r: AudioResponse.Reduction) -> Float {
            AudioResponse.compute(left: flat, right: flat, mode: 1, freqMin: 0, freqMax: 15,
                                  bounds: SIMD2(0.8, 1.0), power: 2, multiply: 1, reduction: r)
        }
        XCTAssertEqual(resp(.peak), resp(.average), accuracy: 1e-4)
    }

    // MARK: - 마지막 두 줄의 순서 (2026-08-21 재대조)

    /// 셰이더 원문의 마지막 줄은
    ///
    ///     audioResponse = saturate(pow(audioResponse, g_AudioPower)) * g_AudioMultiply;
    ///
    /// 이고 **`saturate` 가 `× multiply` 안쪽**이다. 그래서 결과는 1 을 넘을 수 있다 —
    /// `g_AudioMultiply` 의 선언 범위가 `[0,2]`(`"material":"audioamount"` 어노테이션)라
    /// 상한이 정확히 **2.0** 이다. 곱을 saturate 안으로 옮기면 이 단언이 깨진다.
    ///
    /// 범위 라벨: 이 식은 설치본에서 `CreateAudioResponse` 를 담은 셰이더 **3파일 전건**
    /// (`assets/effects/pulse`, `assets/effects/shake`, `projects/defaultprojects/razer_bedroom`)
    /// 이 **바이트 동일**하게 갖고 있다(함수 본문 md5 3건 일치, 2026-08-21 실측).
    func testMultiplyIsAppliedOutsideSaturateSoOutputCanExceedOne() {
        let r = AudioResponse.compute(left: ones, right: ones, mode: 1, freqMin: 0, freqMax: 15,
                                      bounds: SIMD2(0, 1), power: 1, multiply: 2)
        XCTAssertEqual(r, 2.0, accuracy: 1e-5, "saturate 는 pow 만 감싼다 — 곱은 그 바깥이다")
        // 곱이 saturate 안쪽이었다면 1.0 이 나온다. 그 회귀를 명시적으로 배제한다.
        XCTAssertGreaterThan(r, 1.0)
    }

    /// **루프 경계는 `int()` 절삭인데 분모는 원시 float 이다.** 셰이더 원문:
    ///
    ///     for (int a = int(g_AudioFrequencyMin); a <= int(g_AudioFrequencyMax); ++a) …
    ///     audioResponse /= (g_AudioFrequencyMax - g_AudioFrequencyMin + 1.0);
    ///
    /// 두 줄이 같은 유니폼을 **서로 다른 도메인**에서 읽는다. `0.5 … 5` 면 합산 항은 6개
    /// (`a = 0…5`)인데 분모는 `5 − 0.5 + 1 = 5.5` 다. 실사용에서는 어노테이션이
    /// `"int":true` 라 정수만 들어와 둘이 일치하지만, 규약 자체는 이렇게 어긋나 있고
    /// 우리 구현이 그 어긋남까지 재현한다.
    func testFractionalRangeSumsByTruncationButDividesByRawFloat() {
        let frac = AudioResponse.compute(left: ones, right: ones, mode: 1, freqMin: 0.5, freqMax: 5,
                                         bounds: SIMD2(0, 2), power: 1, multiply: 1)
        let int0 = AudioResponse.compute(left: ones, right: ones, mode: 1, freqMin: 0, freqMax: 5,
                                         bounds: SIMD2(0, 2), power: 1, multiply: 1)
        // frac: 합산 6항 / 분모 5.5 = 1.090909 → smoothstep(0,2,·) = 0.567994
        XCTAssertEqual(frac, 0.567994, accuracy: 1e-5)
        // int : 합산 6항 / 분모 6.0   = 1.0      → smoothstep(0,2,·) = 0.5
        XCTAssertEqual(int0, 0.5, accuracy: 1e-5)
        // 합산 항 수가 같은데도 값이 갈린다는 것이 요점이다(분모만 다르다).
        XCTAssertGreaterThan(frac, int0)
    }

    // MARK: 셰이더 선언 기본값

    /// `shake` 의 `audiobounds` 는 `pulse` 와 다르다 — `"0.0 1.2"` vs `"0.5 1.0"`
    /// (`assets/effects/shake/shaders/effects/shake.vert:29` · `.../pulse/…/pulse.vert:31`).
    /// 호출부가 `pulse` 값을 상수로 박아 두면 작은 신호에서 실물은 반응하는데 우리는 0 이다.
    func testShakeDeclaresDifferentAudioBoundsThanPulse() {
        let pulse = AudioResponse.declaredDefaults(effectName: "pulse")
        let shake = AudioResponse.declaredDefaults(effectName: "shake")
        XCTAssertEqual(pulse.bounds, SIMD2<Float>(0.5, 1.0))
        XCTAssertEqual(shake.bounds, SIMD2<Float>(0.0, 1.2))
        // 나머지 넷은 같다.
        XCTAssertEqual(pulse.freqMin, shake.freqMin)
        XCTAssertEqual(pulse.freqMax, shake.freqMax)
        XCTAssertEqual(pulse.power, shake.power)
        XCTAssertEqual(pulse.multiply, shake.multiply)
        // 대소문자 무관, 모르는 이름은 pulse 로.
        XCTAssertEqual(AudioResponse.declaredDefaults(effectName: "Shake"), shake)
        XCTAssertEqual(AudioResponse.declaredDefaults(effectName: "bloom"), pulse)
    }

    /// 그 차이가 실제 응답에서 갈리는 것을 고정한다. 밴드 0..1 평균이 0.3 인 약한 신호는
    /// `pulse` 경계(0.5–1.0)에서는 `smoothstep` 하한 아래라 정확히 0 이고, `shake` 경계
    /// (0.0–1.2)에서는 0 이 아니다.
    func testShakeBoundsRespondToSignalsThatPulseBoundsFloorToZero() {
        let left = [Float](repeating: 0.3, count: 16)
        let right = [Float](repeating: 0.3, count: 16)
        func resp(_ d: AudioResponse.ShaderDefaults) -> Float {
            AudioResponse.compute(left: left, right: right, mode: 1,
                                  freqMin: d.freqMin, freqMax: d.freqMax,
                                  bounds: d.bounds, power: d.power, multiply: d.multiply)
        }
        let pulse = resp(AudioResponse.declaredDefaults(effectName: "pulse"))
        let shake = resp(AudioResponse.declaredDefaults(effectName: "shake"))
        XCTAssertEqual(pulse, 0, accuracy: 1e-6, "0.3 은 0.5 하한 아래 — smoothstep 이 0 으로 뭉갠다")
        XCTAssertGreaterThan(shake, 0.05)
    }
}
