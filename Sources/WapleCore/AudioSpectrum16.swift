import Foundation

/// 채널당 16빈 정규화 스펙트럼(WE g_AudioSpectrum16Left/Right 대응).
public struct AudioSpectrum16: Equatable {
    public var left: [Float]
    public var right: [Float]
    public init(left: [Float], right: [Float]) { self.left = left; self.right = right }
    public static let silent = AudioSpectrum16(left: [Float](repeating: 0, count: 16),
                                               right: [Float](repeating: 0, count: 16))

    /// 임의 길이 스펙트럼 → 16빈(연속 그룹 평균). 라이브 모노 FFT(128빈) → 16빈 L=R 근사에 사용.
    public static func downsample16(_ spectrum: [Float]) -> [Float] {
        guard !spectrum.isEmpty else { return [Float](repeating: 0, count: 16) }
        var out = [Float](repeating: 0, count: 16)
        let n = spectrum.count
        for b in 0..<16 {
            let lo = b * n / 16, hi = max(lo + 1, (b + 1) * n / 16)
            var s: Float = 0
            for i in lo..<min(hi, n) { s += spectrum[i] }
            out[b] = s / Float(max(1, min(hi, n) - lo))
        }
        return out
    }
}
