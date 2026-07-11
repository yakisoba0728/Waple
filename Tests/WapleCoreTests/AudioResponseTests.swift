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
}
