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
        let count = (mode == 2) ? right.count : left.count
        // **분모는 실제 합산 빈 수가 아니라 `(max − min + 1)`(모드 3 은 ×2) 이다.**
        // 종전엔 "mode 3 비대칭(right < left)에서 응답이 절반으로 희석된다" 는 이유로 실제 항 수
        // (`terms`)를 썼는데, 그건 **일어나지 않는 경우를 고치려다 실재하는 규약을 깬 것**이었다 —
        // `AudioSpectrum16` 은 항상 16/16 을 내므로 비대칭은 프로덕션에 없다. 동봉 셰이더 원문이
        // 명시적이다(`effects/pulse/shaders/effects/pulse.vert`):
        //
        //     audioResponse /= (g_AudioFrequencyMax - g_AudioFrequencyMin + 1.0);        // 모드 1·2
        //     audioResponse /= (g_AudioFrequencyMax - g_AudioFrequencyMin + 1.0) * 2.0;  // 모드 3
        //
        // 그리고 그 분모는 **원시 float** 이지 클램프된 빈 인덱스가 아니다. 코퍼스 실측 차이:
        // `0.5..5` 는 우리 12 vs WE 11(응답 8.3% 과소), `0..0.25` 는 우리 2 vs WE 2.5(25% 과대).
        //
        // 같은 셰이더에서 `audioFrequencyEnd = max(min, max)` 는 **계산만 하고 루프가 쓰지 않는
        // 죽은 변수**다. 종전 구현은 그걸 살려 `hi = max(bin(min), bin(max))` 로 썼는데, 그러면
        // `freqMin > freqMax` 일 때 WE 는 루프가 0회라 응답 0 인데 우리는 min 쪽 빈을 읽어 0 이
        // 아닌 값을 낸다. 루프 상한은 `freqMax` 하나다.
        //
        // Int 변환은 Float 도메인에서 [-1, count] 클램프 후 — 1e19 같은 유한 거대값 변환 트랩 방지(감사 V05).
        // NaN 은 Swift min/max 를 통과해 Int() 변환 트랩 — 비유한 입력은 0번 빈 기본값(감사 V06).
        let fcount = Float(count)
        func bin(_ x: Float) -> Int { x.isNaN ? 0 : Int(min(max(x, -1), fcount)) }
        let lo = max(0, bin(freqMin))
        let hi = min(count - 1, bin(freqMax))
        var sum: Float = 0
        if lo <= hi {
            for a in lo...hi {
                if mode == 1 || mode == 3 { sum += left[a] }
                // 인덱스 가드는 남긴다 — 배열 길이가 갈리면 WE 는 UB, 우리는 트랩이라 더 나쁘다.
                if mode == 2 || mode == 3, a < right.count { sum += right[a] }
            }
        }
        // 원시 float 분모. 0 이나 비유한이면 나눗셈을 하지 않는다(WE 는 그 자리에서 inf/NaN 을
        // 만들고 saturate 로 뭉개지만, 우리는 그 전에 0 으로 떨어뜨린다 — 관측 결과는 같다).
        let rawDenom = (freqMax - freqMin + 1) * (mode == 3 ? 2 : 1)
        var resp = (rawDenom.isFinite && rawDenom != 0) ? sum / rawDenom : 0
        if !resp.isFinite { resp = 0 }
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
