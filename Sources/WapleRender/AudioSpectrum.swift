import Foundation

public enum AudioSpectrum {
    /// FFT 크기 배열을 binCount 개로 평균·정규화(최댓값=1)한다. WE audio listener 입력용.
    public static func spectrum(fromMagnitudes magnitudes: [Float], binCount: Int = 128) -> [Float] {
        guard binCount > 0 else { return [] }
        guard !magnitudes.isEmpty else { return Array(repeating: 0, count: binCount) }

        let n = magnitudes.count
        var out = [Float](repeating: 0, count: binCount)
        for i in 0..<binCount {
            let start = i * n / binCount
            let end = max(start + 1, (i + 1) * n / binCount)
            var sum: Float = 0
            var count = 0
            for j in start..<min(end, n) { sum += magnitudes[j]; count += 1 }
            out[i] = count > 0 ? sum / Float(count) : 0
        }
        if let m = out.max(), m > 0 {
            for i in 0..<binCount { out[i] /= m }
        }
        return out
    }
}
