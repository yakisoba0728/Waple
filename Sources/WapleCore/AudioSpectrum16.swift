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

    /// 임의 길이 스펙트럼 → 16빈(연속 그룹 평균). 라이브 모노 FFT(128빈) → 16빈 L=R 근사에 사용.
    /// 공용 비닝 프리미티브(AudioSpectrum.bin)로 위임 — 인덱스/평균 공식은 비트 동일.
    public static func downsample16(_ spectrum: [Float]) -> [Float] {
        AudioSpectrum.bin(spectrum, binCount: 16)
    }
}
