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
    /// 모르는 이름은 `pulse` 쪽으로 떨어뜨린다. 이 폴백은 **셰이더 원문이 없을 때만** 쓴다 —
    /// 원문이 있으면 `declaredDefaults(shaderSource:)` 가 어노테이션을 실제로 읽는다(아래).
    ///
    /// [해소 2026-08-21] 종전 주석의 "우리는 어노테이션을 파싱하지 않으므로 어차피 추정이고 …
    /// 정공법은 셰이더 어노테이션을 실제로 파싱하는 것이다 — **[미해결]**" 은 닫혔다.
    public static func declaredDefaults(effectName: String) -> ShaderDefaults {
        effectName.lowercased() == "shake" ? shakeDefaults : pulseDefaults
    }

    /// 오디오 어노테이션 다섯 키. **유니폼 이름이 아니라 `"material"` 값으로 건다**(함정 8) —
    /// 씬의 `constantshadervalues` 도 이 이름으로 붙는다. 유니폼 이름은 딴판이다:
    /// `audioexponent → g_AudioPower`, `audioamount → g_AudioMultiply`
    /// (`g_AudioExponent`/`g_AudioAmount` 는 두 코퍼스 전수에서 **0건**이다 — 이름으로 걸었으면
    /// 다섯 중 둘을 놓쳤다).
    public static let audioAnnotationMaterialKeys = [
        "frequencymin", "frequencymax", "audioexponent", "audiobounds", "audioamount"
    ]

    /// 셰이더 원문의 `uniform … ; // {"material":…,"default":…}` 어노테이션에서 선언 기본값을 읽는다.
    ///
    /// 다섯 키 중 **하나도 없으면 `nil`** 이다(= 오디오 어노테이션이 없는 셰이더). 일부만 있으면
    /// 나머지는 `pulseDefaults` 로 채운다 — 스톡 셋은 항상 다섯을 다 선언하지만 워크샵 셰이더가
    /// 일부만 적을 수 있고, WE 도 없는 어노테이션은 유니폼 초기값(사실상 0)이 아니라 머티리얼
    /// 기본값 경로를 탄다.
    ///
    /// **도달(2026-08-21 실측).** 오디오 어노테이션 줄은 설치본(`ui/` 제외) **3파일 15줄**
    /// (`assets/effects/pulse` · `assets/effects/shake` · `projects/defaultprojects/razer_bedroom`),
    /// 동봉 `WEAssets` **2파일 10줄**(앞의 pulse·shake)이다. 워크샵은 미측정.
    /// 다섯 키 × 파일 수로 정확히 나누어떨어진다 — 부분 선언은 두 코퍼스에 없다.
    ///
    /// **파스 규약은 코퍼스에서 재서 정했다.**
    /// - 값 형태는 숫자(`"default":0`, `"default":1.0`)와 **따옴표 문자열**(`"default":"0.5 1.0"`)
    ///   둘뿐이다. 배열형 `"default":[…]` 은 동봉·설치 셰이더 전수에서 **0건**이라 지원하지 않는다.
    /// - 문자열 벡터의 구분자는 **공백과 쉼표 둘 다**다. 오디오 키는 전부 공백이지만
    ///   같은 코퍼스의 다른 어노테이션에 `"default":"0.0, 1.0"` · `"default":"0.02, 0.02"` ·
    ///   `"default":"0.0, 360.0"` · `"default":"0.315, 0.135, 0.1125"`(동봉 2파일 4건)이 있고,
    ///   공백만으로 쪼개면 `Float("0.0,")` 가 nil 이라 성분이 **소리 없이 사라진다**.
    /// - `//` 앞이 `uniform` 으로 시작하는 줄만 본다 — 주석 처리된 선언
    ///   (`//uniform float g_AudioSpectrum16[16];`, 동봉 2건)을 집지 않기 위해서다.
    public static func declaredDefaults(shaderSource: String) -> ShaderDefaults? {
        var out = pulseDefaults
        var found = false
        for rawLine in shaderSource.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let slashes = rawLine.range(of: "//") else { continue }
            let code = rawLine[rawLine.startIndex..<slashes.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            guard code.hasPrefix("uniform ") else { continue }
            let ann = String(rawLine[slashes.upperBound...])
            guard let material = audioAnnString(ann, "material"),
                  audioAnnotationMaterialKeys.contains(material),
                  let values = audioAnnFloats(ann, "default"), !values.isEmpty else { continue }
            found = true
            switch material {
            case "frequencymin":  out.freqMin = values[0]
            case "frequencymax":  out.freqMax = values[0]
            case "audioexponent": out.power = values[0]
            case "audioamount":   out.multiply = values[0]
            case "audiobounds":
                out.bounds = SIMD2<Float>(values[0], values.count > 1 ? values[1] : out.bounds.y)
            default: break
            }
        }
        return found ? out : nil
    }

    /// 원문이 있으면 그것을, 없으면 이름표를 쓴다. 호출부가 쓰기 좋은 형태.
    public static func declaredDefaults(effectName: String, shaderSource: String?) -> ShaderDefaults {
        if let src = shaderSource, let parsed = declaredDefaults(shaderSource: src) { return parsed }
        return declaredDefaults(effectName: effectName)
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

/// 어노테이션 `{"key":"값"}` 의 문자열 값. 없으면 nil.
private func audioAnnString(_ s: String, _ key: String) -> String? {
    guard let r = s.range(of: "\"\(key)\"") else { return nil }
    let rest = s[r.upperBound...]
    guard let colon = rest.firstIndex(of: ":") else { return nil }
    let after = rest[rest.index(after: colon)...].drop(while: { $0.isWhitespace })
    guard after.first == "\"" else { return nil }
    let body = after.dropFirst()
    guard let end = body.firstIndex(of: "\"") else { return nil }
    return String(body[body.startIndex..<end])
}

/// 어노테이션 `{"key":숫자}` 또는 `{"key":"a b"}`/`{"key":"a, b"}` 의 성분들.
///
/// **`GLSLTranslator.jsonFloats` 와 갈리는 자리가 하나 있다** — 저쪽은 문자열을 `split(separator: " ")`
/// 로만 쪼개서 `"0.0, 1.0"` 이 `["0.0,", "1.0"]` → `Float("0.0,") == nil` → `[1.0]` 한 성분이 된다.
/// 여기서는 쉼표도 구분자로 본다. (오디오 다섯 키는 전부 공백 구분이라 이 경로가 오디오에서
/// 발동하지는 않는다 — 파서를 일반 규약으로 맞춰 두는 것이고, 저쪽 정정안은 보고서로 넘긴다.)
private func audioAnnFloats(_ s: String, _ key: String) -> [Float]? {
    guard let r = s.range(of: "\"\(key)\"") else { return nil }
    let rest = s[r.upperBound...]
    guard let colon = rest.firstIndex(of: ":") else { return nil }
    let after = rest[rest.index(after: colon)...].drop(while: { $0.isWhitespace })
    if after.first == "\"" {
        let body = after.dropFirst()
        guard let end = body.firstIndex(of: "\"") else { return nil }
        let out = body[body.startIndex..<end]
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" })
            .compactMap { Float($0) }
        return out.isEmpty ? nil : out
    }
    // 숫자 리터럴. `,` 나 `}` 에서 끊는다. 지수 표기 허용(`1e-3`).
    var num = ""
    for ch in after {
        if ch == "," || ch == "}" { break }
        if ch.isNumber || ch == "." || ch == "-"
            || ((ch == "e" || ch == "E") && (num.last?.isNumber ?? false))
            || (ch == "+" && (num.last == "e" || num.last == "E")) { num.append(ch) }
        else if !ch.isWhitespace { break }
    }
    return Float(num).map { [$0] }
}

/// GLSL smoothstep(edge0, edge1, x).
private func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = saturate((x - e0) / max(1e-6, e1 - e0))
    return t * t * (3 - 2 * t)
}
private func saturate(_ x: Float) -> Float { max(0, min(1, x)) }
