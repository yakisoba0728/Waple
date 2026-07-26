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

    func testHugeFiniteFreqRangeNoTrap() {
        // 감사 V05: ±1e19(Float 유한, Int 범위 밖)가 Int() 변환에서 트랩하던 회귀.
        let r = AudioResponse.compute(left: ones, right: ones, mode: 3, freqMin: -1e19, freqMax: 1e19,
                                      bounds: SIMD2(0, 1), power: 1, multiply: 1)
        XCTAssertTrue(r.isFinite)
        XCTAssertEqual(r, 1, accuracy: 1e-5, "클램프 후 전 빈 평균 = 1")
        // 전범위 위(lo > hi): 빈 구간 → 0, 무트랩.
        let r2 = AudioResponse.compute(left: ones, right: ones, mode: 3, freqMin: 1e19, freqMax: 1e19,
                                       bounds: SIMD2(0, 1), power: 1, multiply: 1)
        XCTAssertEqual(r2, 0, accuracy: 1e-5)
    }

    func testNaNFreqRangeNoTrap() {
        // 감사 V06: NaN 은 Swift min/max 를 통과해 bin() 의 Int() 변환 트랩 — 0번 빈 기본값.
        let bothNaN = AudioResponse.compute(left: ones, right: ones, mode: 3, freqMin: .nan, freqMax: .nan,
                                            bounds: SIMD2(0, 1), power: 1, multiply: 1)
        XCTAssertTrue(bothNaN.isFinite)
        XCTAssertEqual(bothNaN, 1, accuracy: 1e-5, "NaN/NaN → 0번 빈(값 1) 평균 = 1")
        let minNaN = AudioResponse.compute(left: ones, right: ones, mode: 3, freqMin: .nan, freqMax: 15,
                                           bounds: SIMD2(0, 1), power: 1, multiply: 1)
        XCTAssertEqual(minNaN, 1, accuracy: 1e-5, "NaN 하한은 0번 빈으로 — 전 구간 평균 = 1")
    }

    func testAsymmetricStereoDenominatorUsesSummedBins() {
        // 감사 V06: mode 3 비대칭(right < left) — denom 은 실제 합산 빈 수(16+8=24)여야 한다.
        // 종전 (hi-lo+1)×2 = 32 로 나눠 평균이 0.75 로 희석됐다(주석 :16 설계 목표와 불일치).
        let right8 = [Float](repeating: 1, count: 8)
        let r = AudioResponse.compute(left: ones, right: right8, mode: 3, freqMin: 0, freqMax: 15,
                                      bounds: SIMD2(0, 1), power: 1, multiply: 1)
        XCTAssertEqual(r, 1, accuracy: 1e-5, "합산 빈 전부 1 이면 평균 1 — 비대칭 희석 없음")
    }
}
