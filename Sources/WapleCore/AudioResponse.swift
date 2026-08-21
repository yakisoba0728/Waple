import Foundation
import simd

/// WE 표준 오디오 응답 축약식(pulse.vert `CreateAudioResponse` 1:1).
/// 모든 스톡 오디오 효과가 공유하는 범용 reducer.
public enum AudioResponse {
    /// - left/right: 채널당 16빈 정규화 스펙트럼.
    /// - mode: AUDIOPROCESSING (1=L, 2=R, 3=L+R 평균; 그 외 0 반환).
    /// - freqMin/Max: 빈 범위(int 절단, 포함). - bounds: smoothstep 경계. - power: 지수. - multiply: 배율.
    /// 구간 축약 방식. **경로마다 다르다** — 셰이더와 파티클이 같은 파라미터를 다르게 접는다.
    ///
    /// · `.average` — 셰이더 경로. `effects/pulse/shaders/effects/pulse.vert` 원문이
    ///   `audioResponse /= (g_AudioFrequencyMax - g_AudioFrequencyMin + 1.0)`(모드 3 은 ×2)로
    ///   명시한다.
    /// · `.peak` — **CPU 파티클/이미터 경로**. 실물 `0x14022a8a0` 은 구간을 돌며
    ///   `comiss`/`movaps` 로 **러닝 MAX** 를 잡고(모드 3 은 레인마다 `L[i] + R[i]`,
    ///   0x14022a903–0x14022a90e) **나눗셈이 없다**. 모드 3 만 마지막에 ×0.5
    ///   (`mulss xmm3, [0x1404926c0]` @0x14022a97c).
    ///
    /// 실측 발산: 베이스만 뜬 스펙트럼(L=[1.0, 0.15, 0.05 …], 모드 1, 구간 0..15)에서
    /// `.peak` 는 1.0 인데 `.average` 는 0.0 이다. 평탄 0.9 브로드밴드에서는 `.peak` 0.9 ·
    /// `.average` 0.9 로 같다 — **좁은 피크가 있을 때만 갈린다.** 이 리포는 파티클 경로에도
    /// 셰이더 규약을 쓰고 있었다.
    public enum Reduction {
        case average
        case peak
    }

    /// 오디오 반응 셰이더가 **선언부 어노테이션으로** 들고 있는 기본값 한 벌.
    ///
    /// 씬은 `constantshadervalues` 로만 값을 채우고 우리는 셰이더 어노테이션을 파싱하지 않으므로,
    /// 이 표가 곧 실효 기본값이다. 종전에는 호출부(`SceneRendererResources.audioParams(for:)`)가
    /// `pulse` 의 값을 상수로 박아 두었는데 **`shake` 는 `audiobounds` 가 다르다**.
    public struct ShaderDefaults: Equatable, Sendable {
        public var freqMin: Float
        public var freqMax: Float
        public var power: Float
        public var bounds: SIMD2<Float>
        public var multiply: Float
        public init(freqMin: Float, freqMax: Float, power: Float,
                    bounds: SIMD2<Float>, multiply: Float) {
            self.freqMin = freqMin; self.freqMax = freqMax
            self.power = power; self.bounds = bounds; self.multiply = multiply
        }
    }

    /// `assets/effects/pulse/shaders/effects/pulse.vert:28-32` 및
    /// `projects/defaultprojects/razer_bedroom/shaders/effects/pulse.vert:21-25` 의 선언값.
    /// 두 파일의 다섯 줄은 문자 단위로 같다.
    public static let pulseDefaults = ShaderDefaults(
        freqMin: 0, freqMax: 1, power: 1,
        bounds: SIMD2<Float>(0.5, 1.0), multiply: 1)

    /// `assets/effects/shake/shaders/effects/shake.vert:26-30`. `audiobounds` 만 다르다 —
    /// `"0.0 1.2"` 라 `smoothstep` 의 하한이 0 이고 기울기가 1/1.2 다. `pulse` 값을 그대로 쓰면
    /// 작은 신호에서 실물은 반응하는데 우리는 0 이 된다.
    public static let shakeDefaults = ShaderDefaults(
        freqMin: 0, freqMax: 1, power: 1,
        bounds: SIMD2<Float>(0.0, 1.2), multiply: 1)

    /// 이펙트 이름 → 선언 기본값.
    ///
    /// **`audiobounds` 를 선언하는 파일은 설치본(`ui/` 제외) 전수에서 3개, 동봉 `WEAssets` 에서
    /// 2개뿐이다**(2026-08-21 실측: `grep -rn '"audiobounds"' --include=*.vert --include=*.frag
    /// --include=*.h` → 설치본 3줄 = `assets/effects/pulse` · `assets/effects/shake` ·
    /// `projects/defaultprojects/razer_bedroom`(pulse 사본), 동봉 2줄 = 앞의 pulse·shake).
    /// `uniform vec2 g_AudioBounds` 선언 자체도 같은 3줄이라 다른 이름의 형제 키는 없다.
    /// 그래서 표가 두 줄로 닫힌다.
    ///
    /// 모르는 이름은 `pulse` 쪽으로 떨어뜨린다 — 워크샵 이펙트가 자기 어노테이션을 갖고 올 수
    /// 있으나 우리는 그걸 파싱하지 않으므로 어차피 추정이고, 스톡 다수가 `pulse` 값이다.
    /// 정공법은 셰이더 어노테이션을 실제로 파싱하는 것이다 — **[미해결]**.
    public static func declaredDefaults(effectName: String) -> ShaderDefaults {
        effectName.lowercased() == "shake" ? shakeDefaults : pulseDefaults
    }

    public static func compute(left: [Float], right: [Float], mode: Int,
                               freqMin: Float, freqMax: Float,
                               bounds: SIMD2<Float>, power: Float, multiply: Float,
                               reduction: Reduction = .average) -> Float {
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
        var resp: Float = 0
        switch reduction {
        case .average:
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
            resp = (rawDenom.isFinite && rawDenom != 0) ? sum / rawDenom : 0
        case .peak:
            // 실물 0x14022a8a0: xmm3 를 0 으로 두고 구간을 돌며 러닝 MAX. 구간이 비면(start > end)
            // 루프가 0회라 peak 는 0 그대로다(`cmp ecx,r8d` / `ja` @0x14022a8de).
            var peak: Float = 0
            if lo <= hi {
                for a in lo...hi {
                    var v: Float = 0
                    if mode == 1 || mode == 3 { v += left[a] }
                    if mode == 2 || mode == 3, a < right.count { v += right[a] }
                    if v > peak { peak = v }
                }
            }
            resp = mode == 3 ? peak * 0.5 : peak   // 0x14022a97c
        }
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
