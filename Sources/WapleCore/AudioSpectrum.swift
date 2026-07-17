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

    /// FFT 크기 배열을 binCount 개로 평균 후 고정게인 `gain` 을 곱한다(정규화 없음). WE audio listener 입력용(채널당 64빈).
    /// 이전엔 배열별 /max 정규화였으나, 이는 진폭을 소거(반응밴드 소실)하고 채널별 호출 시 L/R 밸런스를 파괴(#17)했다.
    /// raw×gain 은 진폭 선형·채널 독립을 보존한다.
    public static func spectrum(fromMagnitudes magnitudes: [Float], binCount: Int = 64) -> [Float] {
        return bin(magnitudes, binCount: binCount).map { $0 * gain }
    }

    /// 스펙트럼 고정게인 — 풀스케일 브로드밴드 노이즈 평균64(≈32.2446)를 소비식 유효구간(코퍼스 최빈 bounds 0.5..1.0) 중앙 0.75 에 사상.
    // ponytail: G는 최선근거 캘리브 노브 — WE 절대스케일 실측치 확보 시 핀(윈도우 L5b 프롬프트 존재)
    static let gain: Float = 0.75 / 32.2446   // ≈ 0.023260
}
