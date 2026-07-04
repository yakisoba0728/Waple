import Foundation

/// 오디오 스펙트럼 비닝 유틸(코어 일원화). WapleRender 는 이 타입을 재수출해 사용한다.
public enum AudioSpectrum {
    /// 임의 길이 배열 → binCount 개 연속 그룹 평균(정규화 없음). 공용 비닝 프리미티브.
    /// - binCount <= 0 → 빈 배열, 입력 비었으면 0 배열.
    public static func bin(_ magnitudes: [Float], binCount: Int) -> [Float] {
        guard binCount > 0 else { return [] }
        guard !magnitudes.isEmpty else { return [Float](repeating: 0, count: binCount) }
        let n = magnitudes.count
        var out = [Float](repeating: 0, count: binCount)
        for i in 0..<binCount {
            let lo = i * n / binCount
            let hi = max(lo + 1, (i + 1) * n / binCount)
            var sum: Float = 0
            var count = 0
            for j in lo..<min(hi, n) { sum += magnitudes[j]; count += 1 }
            out[i] = count > 0 ? sum / Float(count) : 0
        }
        return out
    }

    /// FFT 크기 배열을 binCount 개로 평균·정규화(최댓값=1)한다. WE audio listener 입력용.
    public static func spectrum(fromMagnitudes magnitudes: [Float], binCount: Int = 128) -> [Float] {
        var out = bin(magnitudes, binCount: binCount)
        if let m = out.max(), m > 0 {
            for i in 0..<out.count { out[i] /= m }
        }
        return out
    }
}
