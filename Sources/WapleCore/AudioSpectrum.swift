import Foundation

/// WE 2.8.42 의 64밴드 오디오 스펙트럼 파이프라인.
///
/// 종전 구현은 **네 군데가 전부 달랐다** — 등폭 비닝 + 평균 + 틸트 없음 + 실측 캘리브 게인.
/// 증상은 베이스 두 바만 크게 흔들리고 62바가 거의 정지, 상위 22바는 항상 0 이었다.
/// 넷을 따로 고치면 악화된다: 현행 게인이 나머지 셋의 부재를 흡수하도록 맞춰져 있어서다.
///
/// 아래 규약은 전부 원본 `wallpaper64.exe` 디스어셈블에서 왔다(주소는 원본 VA 기준).
///
/// ## 원본 파이프라인
/// ```
///   PCM s
///    → ×127, +127            (시간영역 상수만 — **창 함수 없음**, 사각창)
///    → 제로패딩 (window → N)
///    → 복소 FFT (정규화 없음)
///    → power = Re²+Im²        (bin 0 = DC 제외, bin 1..B-1)
///    → sqrt(w · power)        ← 틸트: 진폭에 sqrt(w)
///    → band[b] = MAX(...)     ← 축약: 평균이 아니라 최댓값 (`maxss` 0x1400d1d04)
///    → band[] *= gain         ← 게인: 맨 마지막, 일괄
/// ```
///
/// ## 우리 쪽 한 가지 의도적 이탈 — FFT 길이
/// 원본은 `N = int(max(rate/44100, 1) · 1920)`, `B = 640` 고정이다. N 을 레이트에 비례시키고
/// B 를 고정해서 **빈 폭이 항상 ≈22.97 Hz, 상한이 항상 ≈14677 Hz** 가 되게 만든 설계다.
/// 문제는 그 N 이 2의 거듭제곱이 아니라는 것이다 — 원본은 FFTS mixed-radix 를 쓰고,
/// 48 kHz 에서는 N = 2089(소수)까지 나온다. vDSP 는 임의 길이 실수 FFT 를 못 한다.
///
/// 그래서 **길이를 맞추는 대신 주파수 축을 맞춘다.** 2의 거듭제곱 N 을 쓰되, 원본과 같은
/// 상한 주파수까지의 빈 개수를 B 로 잡는다.
///
/// **맞는 것은 소비 구간의 상한이지 밴드 경계가 아니다.** 상한은 원본 14677.03 Hz 대비
/// 48 kHz·N=2048 에서 14671.88 Hz(−0.035%), 44.1 kHz 에서 14685.64 Hz(+0.059%) — 여기까지가
/// 설계로 보장되는 부분이다. 경계는 그만큼 정밀하지 않다: 원본도 우리도 밴드 경계를 **자기
/// 빈 격자의 정수 인덱스**에 거는데 그 격자 폭이 서로 다르므로(22.96875 vs 23.4375 Hz),
/// 원본 대비 경계 이동이 48 kHz 에서 최대 21.6 Hz(0.92빈, B=627), 44.1 kHz 에서 최대
/// 43.1 Hz(2.00빈, B=683)다. 정규화 좌표로는 max|Δt| = 1.33e-3 · 2.96e-3 이고 64밴드 중
/// 58~60개가 1e-4 를 넘는다.
///
/// **종전 주석의 "밴드당 1e-4 미만 / 빈 하나의 몇 %" 는 13~30배 과장이었다**(`bandOfBin` 의
/// 밴드별 첫 빈을 B=640 기준과 대조한 실측). 요점은 저역 밴드가 통째로 밀리던 종전 1024
/// (빈 폭 1.88배)와 비교할 크기가 아니라는 것이고, 빈 단위 정합은 애초에 2의 거듭제곱 N 으로는
/// 얻을 수 없다.
/// 응답 속도도 원본과 같게 유지한다 — 원본의 창 길이 규약 `N − N/3`(1920→1280, 29 ms)을
/// 그대로 써서 나머지 1/3 은 제로패딩이다.
public enum AudioSpectrum {

    // MARK: 원본 상수

    /// 밴드 수. 셰이더 유니폼 `g_AudioSpectrum64Left/Right` 와 같은 수.
    /// 근거: 밴드 배열 초기화가 `memset(0, 0x200)` = 512B = 128 float = 2ch × 64,
    /// 게인 루프가 `cmp ecx, 0x40`(0x1400d1df3).
    public static let bandCount = 64

    /// 밴드 매핑 지수. AudioProcessor `+0xE4`, 생성자 immediate(`0x1400c0d59`).
    /// 바이너리 전체에서 이 필드에 쓰는 지점이 생성자 말고는 없다 — 씬 프로퍼티
    /// `audioprocessingexponent` 는 **이 경로에 도달하지 않는다**(프로젝트 JSON 기본값 작성기에만 등장).
    public static let exponent: Float = 0.25

    /// 스펙트럴 틸트 상수. AudioProcessor `+0xE8` = `0x3f004189` = 0.50099998712539673f
    /// (`0x1400c0d63`). 짝인 0.499 는 **리터럴이 아니라** 런타임에 `1.0 - C` 로 만든다
    /// (`0x1400d1c12: subss xmm9, xmm12`) — 그래서 바이너리에서 0.499 를 찾으면 안 나온다.
    public static let tiltC: Float = 0.50099998712539673

    /// 원본 FFT 길이 계수(AudioProcessor `+0xEC` = 30.0)와 빈 개수 계수(`+0xF0` = 10.0),
    /// 그리고 둘에 공통으로 곱해지는 64.0(`0x1404928e4`). 즉 44.1 kHz 에서 N=1920, B=640.
    public static let referenceRate: Double = 44100
    public static let referenceFFTLength = 1920
    public static let referenceBinCount = 640

    /// 원본이 실제로 소비하는 최고 주파수. 44.1 kHz 에서 bin 639 × (44100/1920) 이다.
    /// 레이트가 바뀌어도 N 이 비례하므로 이 값은 상수다 — 그게 원본 설계의 요점이다.
    public static let topFrequency: Double =
        Double(referenceBinCount - 1) * (referenceRate / Double(referenceFFTLength))   // 14677.03125

    /// 최종 게인. 1/N 정규화 진폭(`|DFT|/N`)에 곱한다.
    /// `127 × 0.001 × 2 × 640 = 162.56`. 원본 코드상으로는
    /// `AP[0x0C](=1.0) × 0.001 × B / (N/2)`(0x1400d1d44-0x1400d1d5d)를 **비정규화 DFT 진폭**에
    /// 곱하고, 시간영역에서 이미 샘플에 127 을 곱해 뒀다(`0x1400d15dd`). 두 규약을 합치면 위 값이다.
    /// B 가 레이트 무관 640 고정이라 N 이 상쇄돼 **모든 샘플레이트에서 같은 상수**가 된다.
    public static let gain: Float = 162.56

    // MARK: 창/길이 규약

    /// 원본의 창 길이 규약 `N − int(N × 10/30)` (`0x1400d1491`-`0x1400d14a0`).
    /// 나머지는 제로패딩이고 **오버랩은 없다**(FFT 직후 `xor r13d, r13d` 로 카운터 리셋).
    public static func windowLength(fftLength n: Int) -> Int {
        max(1, n - n / 3)
    }

    /// 이 FFT 길이/샘플레이트에서 원본과 **같은 상한 주파수**까지 덮는 빈 개수.
    /// 반환값 B 에 대해 소비 구간은 `1 ..< B` 다(bin 0 = DC 는 원본도 안 쓴다 — 루프가 `ebx=1`).
    public static func binCount(fftLength n: Int, sampleRate: Double) -> Int {
        let half = max(1, n / 2)
        guard n > 0, sampleRate.isFinite, sampleRate > 0 else { return min(half, referenceBinCount) }
        let binWidth = sampleRate / Double(n)
        guard binWidth.isFinite, binWidth > 0 else { return min(half, referenceBinCount) }
        // **정본 가드 `safeInt(_:)` 를 태운다.** `Int(_:)` 는 범위 밖에서 클램프가 아니라 **트랩**이라,
        // 낮은 sampleRate 나 큰 n 이 들어오면 몫이 Int 범위를 넘고 그 한 줄이 프로세스를 죽인다.
        // 직접 클램프를 적을 수도 있지만 그러지 않는다 — F530 스윕이 확인한 지배적 실패 방식은
        // "가드가 없다" 가 아니라 **"가드가 넷인데 아무도 안 거친다"** 였다(JSONNumerics 주석).
        let raw = (topFrequency / binWidth).rounded()
        guard let widened = safeInt(raw), widened >= 0 else { return min(half, referenceBinCount) }
        return max(2, min(half, min(widened, half) + 1))
    }

    // MARK: 밴드 매핑

    /// 빈 인덱스 → 밴드 인덱스. 길이 `binCount`, `[0]` 은 미사용(DC).
    ///
    /// ```
    ///   t    = (i-1) / (B-1)
    ///   raw  = int(powf(t, 0.25) · 64)      // 절삭(cvttss2si) — 반올림 아님
    ///   band = min(raw % 64, prev + 1)      // 빈당 최대 1밴드씩만 전진
    /// ```
    /// **저역에서 밴드가 빈 1개씩 1:1 이 되는 것은 별도의 선형 구간이 있어서가 아니라**
    /// 이 `prev+1` 클램프의 결과다. `pow(t, 0.25)` 가 저역에서 급격히 커지는 걸 클램프가 막는다.
    /// 그 구간의 **길이는 B 에 따라 변한다**. 흔히 인용하는 "하위 29밴드" 는 `B ∈ 623...688`
    /// 에서만 성립한다(실측: 622→30, 689→28, 314→37, 940→26). 원본 B=640 과 우리 48 kHz
    /// B=627 · 44.1 kHz B=683 이 전부 그 안이라 테스트가 29 를 고정할 수 있는 것이지,
    /// 매핑의 불변식이 아니다 — 32 kHz(B=940)나 96 kHz(B=314)에서는 깨진다.
    /// `% 64` 는 기본 지수 0.25 에서는 발동하지 않지만(raw ≤ 63) 원본에 있으므로 남긴다.
    public static func bandOfBin(binCount B: Int) -> [Int] {
        guard B >= 2 else { return [Int](repeating: 0, count: max(B, 0)) }
        var out = [Int](repeating: 0, count: B)
        let denom = Float(B - 1)
        var prev = 0
        for i in 1..<B {
            let t = Float(i - 1) / denom
            // 기본 지수 0.25 와 t < 1 에서는 곱이 항상 64 미만이라 좁힘이 안전하다. 그래도 정본
            // 가드를 태우는 이유: `exponent` 가 public 상수라 0 이하로 바뀌면 pow 가 발산하고
            // `Int(_:)` 는 그때 트랩한다. `safeInt` 는 절삭 후 범위 밖이면 nil 이라, 원본의
            // 절삭(`cvttss2si`) → 부호 있는 나머지(`and ecx, 0x8000003f`) 순서를 그대로 보존한다.
            let scaled = powf(t, exponent) * Float(bandCount)
            guard let truncated = safeInt(Double(scaled)) else { continue }
            var raw = truncated % bandCount
            if raw < 0 { raw += bandCount }
            let band = min(raw, prev + 1)
            prev = band
            out[i] = band
        }
        return out
    }

    /// 빈별 틸트 **진폭** 가중치 `sqrt(w)`, `w = C − (1−C)·cos(π·t)`.
    ///
    /// **t 는 밴드 인덱스가 아니라 빈 인덱스의 정규화값이다** — 이걸 밴드로 잘못 잡으면
    /// 빈이 30~39개씩 들어가는 상위 밴드에서 값이 크게 달라진다. 원본은 cos 인자를
    /// `(float)k · π · 1/(B−1)` 로 만들고(`0x1400d1cb0`,`0x1400d1cc2`) 그 k 는 밴드 매핑에
    /// 쓴 것과 **같은** `i−1` 이다(xmm7 이 non-volatile 이라 powf 호출을 넘어 살아남는다).
    ///
    /// 결과적으로 한 밴드 안의 빈들이 서로 다른 가중치를 갖고, MAX 가 그 뒤에 오므로
    /// 넓은 밴드에서는 상단 빈이 뽑히는 편향이 생긴다 — 그게 원본 동작이다.
    /// 최저↔최고 감쇠비는 `sqrt(1.0)/sqrt(0.002)` = 22.36배다.
    public static func tiltAmplitudeWeights(binCount B: Int) -> [Float] {
        guard B >= 2 else { return [Float](repeating: 0, count: max(B, 0)) }
        var out = [Float](repeating: 0, count: B)
        let denom = Float(B - 1)
        let oneMinusC = 1 - tiltC
        for i in 1..<B {
            let t = Float(i - 1) / denom
            let w = tiltC - oneMinusC * cosf(.pi * t)
            out[i] = w > 0 ? sqrtf(w) : 0
        }
        return out
    }

    // MARK: 본 파이프라인

    /// `1/N` 정규화 진폭(`|DFT(i)| / N`) 배열 → 64밴드.
    ///
    /// 호출자는 FFT 백엔드의 스케일 규약을 여기 맞춰서 넘겨야 한다. vDSP 의 packed-real
    /// `vDSP_fft_zrip` 출력은 수학적 DFT 의 2배이므로 `|X_vDSP| / (2N)` 이다.
    public static func spectrum(normalizedMagnitudes mags: [Float],
                                binCount B: Int? = nil) -> [Float] {
        let n = mags.count
        let bins = min(B ?? n, n)
        guard bins >= 2 else { return [Float](repeating: 0, count: bandCount) }
        let bandOf = bandOfBin(binCount: bins)
        let tilt = tiltAmplitudeWeights(binCount: bins)
        // 밴드 배열은 매 프레임 0 으로 시작한다(원본도 memset) — 즉 축약은 max(0, …) 이다.
        var out = [Float](repeating: 0, count: bandCount)
        for i in 1..<bins {
            let m = mags[i]
            guard m.isFinite else { continue }   // 원본도 Inf/NaN 빈을 0 으로 친다(0x1400d1c62)
            let v = m * tilt[i]
            let b = bandOf[i]
            if b >= 0, b < bandCount, v > out[b] { out[b] = v }
        }
        for i in 0..<bandCount { out[i] *= gain }
        return out
    }

    /// 임의 길이 배열 → binCount 개 연속 그룹 **평균**. WE 파이프라인이 아니라 일반 비닝
    /// 프리미티브다(다른 소비처 호환용). 스펙트럼 경로는 `spectrum(normalizedMagnitudes:)` 를 쓴다.
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
}
