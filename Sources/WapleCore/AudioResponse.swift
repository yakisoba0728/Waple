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
        // Int 변환은 Float 도메인에서 [-1, count] 클램프 후 — 1e19 같은 유한 거대값 변환 트랩 방지(감사 V05).
        // -1 하한이라 전음수 범위는 여전히 빈 구간(hi < lo)으로 떨어져 기존 의미 보존.
        let fcount = Float(count)
        func bin(_ x: Float) -> Int { Int(min(max(x, -1), fcount)) }
        let lo = max(0, bin(freqMin))
        let hi = min(count - 1, max(bin(freqMin), bin(freqMax)))
        var sum: Float = 0
        if lo <= hi {
            for a in lo...hi {
                // hi 는 기준 채널(count) 크기로 클램프됨 — left 는 mode 1/3 모두 기준 채널이라 추가 가드 불필요.
                // right 는 mode 3 에서 비대칭 입력(right < left)이 가능해 가드 유지.
                if mode == 1 || mode == 3 { sum += left[a] }
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
