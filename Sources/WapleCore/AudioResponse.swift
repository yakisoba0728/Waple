import Foundation
import simd

/// WE 표준 오디오 응답 축약식(pulse.vert `CreateAudioResponse` 1:1).
/// 모든 스톡 오디오 효과가 공유하는 범용 reducer.
public enum AudioResponse {
    /// - left/right: 채널당 16빈 정규화 스펙트럼.
    /// - mode: AUDIOPROCESSING (1=L, 2=R, 3=L+R 평균; 그 외 0 반환).
    /// - freqMin/Max: 빈 범위(int 절단, 포함). - bounds: smoothstep 경계. - power: 지수. - multiply: 배율.
    public static func compute(left: [Float], right: [Float], mode: Int,
                               freqMin: Float, freqMax: Float,
                               bounds: SIMD2<Float>, power: Float, multiply: Float) -> Float {
        guard mode >= 1, mode <= 3 else { return 0 }
        let channels: Float = (mode == 3) ? 2 : 1
        let count = (mode == 2) ? right.count : left.count
        // 범위를 유효 빈으로 클램프해 denom 이 실제 합산 빈 수와 일치하도록 한다(범위 밖 빈으로 평균 희석 방지).
        let lo = max(0, Int(freqMin))
        let hi = min(count - 1, max(Int(freqMin), Int(freqMax)))
        var sum: Float = 0
        if lo <= hi {
            for a in lo...hi {
                if mode == 1 || mode == 3, a < left.count { sum += left[a] }
                if mode == 2 || mode == 3, a < right.count { sum += right[a] }
            }
        }
        let denom = Float(max(0, hi - lo + 1)) * channels
        var resp = denom > 0 ? sum / denom : 0
        resp = smoothstep(bounds.x, bounds.y, resp)
        resp = saturate(powf(max(0, resp), power)) * multiply
        return resp
    }
}

/// GLSL smoothstep(edge0, edge1, x).
private func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = saturate((x - e0) / max(1e-6, e1 - e0))
    return t * t * (3 - 2 * t)
}
private func saturate(_ x: Float) -> Float { max(0, min(1, x)) }
