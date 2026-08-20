import Foundation

/// 채널당 16빈 정규화 스펙트럼(WE g_AudioSpectrum16Left/Right 대응).
/// Sendable: 저장 프로퍼티가 `[Float]` 둘뿐인 값 타입(전부 Sendable) — `silent` 상수를 오디오
/// 콜백 스레드에서도 안전하게 읽는다(엄격 동시성이 `static let` 의 타입에 Sendable 을 요구한다).
public struct AudioSpectrum16: Equatable, Sendable {
    public var left: [Float]
    public var right: [Float]
    public init(left: [Float], right: [Float]) { self.left = left; self.right = right }
    public static let silent = AudioSpectrum16(left: [Float](repeating: 0, count: 16),
                                               right: [Float](repeating: 0, count: 16))

    /// 전 빈이 0 = 무신호(캡처 무음/공급자 부재 폴백). 오디오반응 스킵 판정용 — 신호가 있을 때만 변조.
    public var isSilent: Bool {
        !left.contains(where: { $0 != 0 }) && !right.contains(where: { $0 != 0 })
    }

    /// 임의 길이 스펙트럼 → 16빈(연속 그룹 **최댓값**).
    ///
    /// **평균이 아니다.** 원본은 64 → 32 → 16 을 인접 2개씩 `maxss` 로 두 번 접는다
    /// (`0x1401128e0`, `0x140112b6f`) — 64→16 은 곧 4개 중 최댓값이다. 종전엔 평균이었는데,
    /// 순음 저역에서 최대 4배가 갈린다(4밴드 중 하나만 뜨면 평균은 1/4). 게인 상수를 소수점까지
    /// 유도해 놓고 마지막 축약을 추정으로 두면 그 정밀도가 전부 소거된다.
    ///
    /// 정식 경로는 `AudioSpectrumProcessor`(그룹 정규화 + 스무딩 + 2단 MAX)다. 이 함수는 그
    /// 앞단을 거치지 않는 호출부(모노 폴백, 테스트 주입)를 위한 축약 전용 프리미티브다.
    public static func downsample16(_ spectrum: [Float]) -> [Float] {
        groupMax(spectrum, binCount: 16)
    }

    /// 연속 그룹 최댓값. 인덱스 산술은 `AudioSpectrum.bin` 과 동일하고 축약만 max 다.
    public static func groupMax(_ spectrum: [Float], binCount: Int) -> [Float] {
        guard binCount > 0 else { return [] }
        guard !spectrum.isEmpty else { return [Float](repeating: 0, count: binCount) }
        let n = spectrum.count
        var out = [Float](repeating: 0, count: binCount)
        for i in 0..<binCount {
            let lo = i * n / binCount
            let hi = Swift.max(lo + 1, (i + 1) * n / binCount)
            var m = -Float.greatestFiniteMagnitude
            for j in lo..<Swift.min(hi, n) where spectrum[j] > m { m = spectrum[j] }
            out[i] = m > -Float.greatestFiniteMagnitude ? m : 0
        }
        return out
    }
}
