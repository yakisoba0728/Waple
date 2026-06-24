import Foundation

/// 결정적 시드 RNG(SplitMix64). 테스트 재현성 + 파티클별 변주에 사용.
/// Swift 의 SystemRandomNumberGenerator 는 시드 불가하므로 직접 구현.
public struct SplitMix64 {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func nextUInt() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// [0, 1) 균등 Float (상위 24비트 → 2^-24 해상도).
    public mutating func nextFloat() -> Float {
        Float(nextUInt() >> 40) * (1.0 / 16_777_216.0)
    }

    /// [lo, hi) 균등.
    public mutating func range(_ lo: Float, _ hi: Float) -> Float {
        lo + (hi - lo) * nextFloat()
    }
}
