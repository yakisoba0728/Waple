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
///    → 패딩 (window → N)      (원본은 0 이 아니라 무음값 127 로 채운다 — bin 0 에만 떨어지므로
///                              소비 빈에서는 우리의 0 패딩과 등가. `sampleBias` 주석 참조)
///    → 복소 FFT (정규화 없음)  (허수부는 0 이 아니라 `1/(127·s+127)` — 잔차 ≤ −85 dB, §2.5)
///    → power = Re²+Im²        (bin 0 = DC 제외, bin 1..B-1)
///    → sqrt(w · power)        ← 틸트: 진폭에 sqrt(w)
///    → band[b] = MAX(...)     ← 축약: 평균이 아니라 최댓값 (`maxss` 0x1400d1d04)
///    → band[] *= gain         ← 게인: 맨 마지막, 일괄
/// ```
///
/// ## 우리 쪽 한 가지 의도적 이탈 — FFT 길이
/// 원본은 `N = int(max(rate/44100, 1) · 1920)`, `B = 640` 고정이다. N 을 레이트에 비례시키고
/// B 를 고정해서 **빈 폭이 항상 ≈22.97 Hz, 상한이 항상 ≈14677 Hz** 가 되게 만든 설계다 —
/// 단 그 불변식은 `max(…, 1)` 클램프 때문에 **44.1 kHz 이상에서만** 성립한다(32 kHz 면
/// N 이 1920 에 묶여 상한이 10650 Hz 로 내려간다). 그래서 `binCount(fftLength:sampleRate:)` 는
/// 상수 `topFrequency` 가 아니라 `engineTopFrequency(sampleRate:)` 를 쓴다.
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

    /// 원본이 44.1 kHz 에서 실제로 소비하는 최고 주파수 — bin 639 × (44100/1920).
    ///
    /// **레이트 무관 상수가 아니다.** N 이 레이트에 비례하는 것은 `max(rate/44100, 1)`
    /// 때문에 **44.1 kHz 이상에서만**이고(`0x1400cf5f4` 의 `comiss`/`ja`), 그 아래에서는
    /// N 이 1920 에 고정돼 상한이 함께 내려간다 — 32 kHz 면 639 × (32000/1920) = 10650 Hz 로
    /// 27% 낮다. 레이트를 아는 자리는 `engineTopFrequency(sampleRate:)` 를 써라.
    /// 이 상수는 "44.1 kHz 기준값" 이라는 뜻으로만 남는다.
    public static let topFrequency: Double =
        Double(referenceBinCount - 1) * (referenceRate / Double(referenceFFTLength))   // 14677.03125

    // MARK: 캡처단 — 원본이 레이트에서 N·B·W 를 뽑는 식

    /// 시간영역 DC 바이어스 겸 게인 `s → 127·s + 127`(`0x1400d15dd` `mulss` · `0x1400d15e2` `addss`).
    ///
    /// 두 몫이 다르다. `×127` 은 진짜 게인이라 아래 `gain` 에 흡수돼 있고, `+127` 은
    /// **패딩 기준선 맞춤**이다 — 원본은 창 뒤 `[W, N)` 을 0 이 아니라 무음 값 127 로 채우므로
    /// (`0x1400d141d` 가 `0x42FE0000`=127.0f, `0x1400d1425` 가 `0x3C010204`=1/127 을 심는다)
    /// 버퍼 전체가 `127 + 127·s(t)·1[t<W]` 이고, 상수 127 은 길이 N 전 구간에 걸려 **bin 0 에만**
    /// 떨어진다. 소비 구간이 `i ≥ 1` 이라 우리의 0 패딩과 소비 빈에서 정확히 등가다.
    /// 자세한 것은 `docs/re/audio-capture.md` §2.4.
    public static let sampleBias: Float = 127

    /// 원본 FFT 길이 `N = int(max(rate/44100, 1) · 64 · 30)`(`0x1400cf5e4`-`0x1400cf619`).
    ///
    /// float32 연산 순서까지 원본 그대로다 — `cvttss2si` 는 반올림이 아니라 **절삭**이고,
    /// 48 kHz 에서 2089.7959 → 2089 처럼 소수까지 걸린다. 실무 레이트에서 이 N 은
    /// **한 번도 2의 거듭제곱이 아니라서**(1920·2089·3840·4179·8359) 원본은 항상 Bluestein
    /// 경로를 탄다(`0x1400d05e9` 의 `test r12, r12-1`).
    public static func engineFFTLength(sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return referenceFFTLength }
        var scale = Float(sampleRate) / Float(referenceRate)
        if !(scale > 1) { scale = 1 }
        let n = scale * engineFactorScale * engineFFTLengthFactor
        // 정본 가드. 기본 경로에서는 절대 안 걸리지만(192 kHz 도 8359), 레이트가 오염돼
        // 오면 `Int(_:)` 는 클램프가 아니라 트랩이다.
        guard let widened = safeInt(Double(n)), widened >= 2 else { return referenceFFTLength }
        return widened
    }

    /// 그 N 에서의 원본 창 길이. `engineFFTLength` 과 `windowLength` 의 합성이다.
    public static func engineWindowLength(sampleRate: Double) -> Int {
        windowLength(fftLength: engineFFTLength(sampleRate: sampleRate))
    }

    /// 이 레이트에서 원본이 실제로 소비하는 최고 주파수 = `bin(B−1) = (B−1)·rate/N`.
    /// 44.1 kHz 이상이면 14677~14683 Hz 로 거의 상수고, 그 아래에서는 레이트에 비례해 내려간다.
    public static func engineTopFrequency(sampleRate: Double) -> Double {
        let n = engineFFTLength(sampleRate: sampleRate)
        guard n > 0, sampleRate.isFinite, sampleRate > 0 else { return topFrequency }
        return Double(referenceBinCount - 1) * (sampleRate / Double(n))
    }

    /// 원본 게인식 그대로 — `AP[0x0C] · 0.001 · B / (N/2)`(`0x1400d1d3f`-`0x1400d1d5d`).
    /// 이건 **비정규화 DFT 진폭**에 걸리는 값이라 우리 `gain`(1/N 정규화 진폭 기준)과 규약이 다르다.
    /// 둘의 관계는 `sampleBias × engineRawBandGain(B, N) × N == gain`(B=640 에서) 이고,
    /// `AudioSpectrumWEParityTests` 가 그 항등식을 고정한다.
    ///
    /// **`apVolume` 은 상수가 아니다 — 사용자 설정이다.** 종전에는 이 자리에 리터럴 `1.0` 이
    /// 박혀 있었고 주석도 `AP[0x0C](=1.0)` 이라고 단정했는데, 그 1.0 은 **생성자 기본값**이지
    /// 실행값이 아니다. 실행값은 `config.json` 의 `user.audioinputvolume` 에서 온다 —
    /// `inputVolumeGain(setting:)` 참조. 기본 설정 50 이 정확히 1.0 을 만들기 때문에
    /// 둘이 우연히 같아 보였던 것이다.
    public static func engineRawBandGain(binCount b: Int, fftLength n: Int,
                                         apVolume: Float = 1.0) -> Float {
        guard n > 0 else { return 0 }
        return apVolume * 0.001 * Float(b) / (Float(n) * 0.5)
    }

    // MARK: 입력 설정 — `user.audioinputvolume` / `user.audioinputthreshold`

    /// `config.json` 의 `user.audioinputvolume` 정수를 AP `+0x0C`(게인 곱수)로 바꾸는 계수.
    ///
    /// **확정.** 설정 로더 `0x14006c722`-`0x14006c766` 의 다섯 명령이 전부다:
    ///
    /// ```
    ///   0x14006c72c  lea   rdx, "audioinputvolume"      ; rdx=begin, r8=end(+0x10) → 길이 16
    ///   0x14006c739  call  0x140086de0                  ; Json::Value 조회
    ///   0x14006c741  call  0x140085ee0                  ; asInt (태그 5 는 1/0 — 함정 18)
    ///   0x14006c757  movd  xmm0, eax
    ///   0x14006c75b  cvtdq2ps xmm0, xmm0
    ///   0x14006c75e  mulss xmm0, [0x14049262c]          ; = 0.019999999552965164f
    ///   0x14006c766  movss [0x1404e55b4], xmm0
    /// ```
    ///
    /// **클램프가 없다** — asInt 와 저장 사이에 `minss`/`maxss`/`comiss` 가 한 개도 없다.
    /// 상수 `0x14049262c` 의 적재 자리는 이미지 전체에서 **4곳**뿐이고
    /// (`0x14006c75e`·`0x1401020f5`·`0x140180e9a`·`0x1401bf730`), 오디오 경로의 것은 첫 번째뿐이다.
    ///
    /// **소비까지 짚었다**(함정 3). 저장 주소 `0x1404e55b4` 는 전역 AudioProcessor 의 `+0x0C` 다:
    /// 생성자 `0x1400c0c80` 은 `0x140064d0f: lea rcx, [0x1404e55a0]` / `0x140064d28: call` 로
    /// **그 전역에** 대해 불리고, 스레드 기준 베이스는 `+8` 이라 `0x1404e55a8` 이며
    /// (`0x1400c0ca6: lea rbx,[rcx+8]`), `0x1404e55a8 + 0x0C = 0x1404e55b4` 다. 그리고 캡처
    /// 스레드 `0x1400d02b0` 은 `{this=0x1404e55a8, fn=0x1400d02b0}` 클로저로 뜬다
    /// (`0x14006e525`/`0x14006e52f`, 재시도 분기 `0x14006e5ac`/`0x14006e5b6`). 스레드 안에서
    /// `AP+0x0C` 를 읽는 자리는 **게인 한 곳뿐**이다(`0x1400d1d3f  movss xmm2,[rdi+0xc]`).
    /// 교차 확인: 같은 호출이 넘기는 `rcx=0x1404e568c` 가 정확히 `AP+0xE4`(상수 4개 묶음)다.
    ///
    /// 스칼라가 곱해지는 **위치**는 우리와 다르지만(실물은 비정규화 진폭에, 우리는 밴드 출력에)
    /// 곱셈은 결합적이라 관측 결과는 같다.
    public static let inputVolumeScaleFactor: Float = 0.019999999552965164

    /// `user.audioinputvolume` 의 UI 슬라이더 범위 — `floor:0, ceil:200`
    /// (`ui/dist/scripts/scripts.js` 의 `audioSlider={hideLimitLabels:!0,floor:0,ceil:200,…}`).
    /// **0…100 이 아니다.** 곱수 도메인은 `[0, 4]` 이고 중립점이 50 이다.
    public static let inputVolumeSettingRange: ClosedRange<Int> = 0...200

    /// 배포 `config.json` 의 `user.audioinputvolume` 값. `50 × 0.02f` 는 float32 에서
    /// **정확히 1.0** 이라(반올림 오차 2.2e-8 < 반ULP 3.0e-8) 기본 설치에서 게인이 `162.56` 이다.
    public static let defaultInputVolumeSetting: Int = 50

    /// `user.audioinputthreshold` → AP `+0x10`(무음 게이트 임계) 계수.
    /// `0x14006c776  call 0x140086220`(asFloat) → `0x14006c77b  mulss xmm0,[0x140492608]`(=0.001)
    /// → `0x14006c794  movss [0x1404e55b8]`, 그리고 `0x1404e55a8 + 0x10 = 0x1404e55b8` 이다.
    /// 읽는 자리는 `0x1400d1a15  movss xmm5,[r14+0x10]` 하나뿐이다(`r14 = [rbp+0x330] = this`).
    /// 슬라이더는 `floor:0, ceil:10, step:.1` 이라 임계 도메인은 `[0, 0.01]`, 기본 0 = 비활성.
    public static let inputThresholdScaleFactor: Float = 0.0010000000474974513

    /// 배포 `config.json` 의 `user.audioinputthreshold` 값(0 = 게이트 비활성).
    public static let defaultInputThresholdSetting: Float = 0

    /// 설정 정수 → AP `+0x0C` 곱수. 실물처럼 **클램프하지 않는다**(위 주석의 명령 다섯 개가 전부).
    /// 정수 변환은 `asInt` 가 이미 끝낸 것이므로 여기 입력은 정수다.
    public static func inputVolumeGain(setting: Int) -> Float {
        Float(setting) * inputVolumeScaleFactor
    }

    /// 설정 실수 → AP `+0x10` 무음 임계.
    public static func inputThreshold(setting: Float) -> Float {
        setting * inputThresholdScaleFactor
    }

    /// 그 설정에서의 최종 게인(1/N 정규화 진폭 기준). `gain` 은 `setting = 50` 인 경우다.
    ///
    /// 실측 대응표 — float32 에서 전부 정확히 떨어진다:
    /// `0 → 0` · `25 → 81.28` · `50 → 162.56` · `100 → 325.12` · `200 → 650.24`.
    public static func gain(inputVolumeSetting setting: Int) -> Float {
        gain * inputVolumeGain(setting: setting)
    }

    /// AudioProcessor `+0xEC`(생성자 `0x1400c0d6d`) — N 계수 30.0.
    /// **오프셋 기준선 주의**: 생성자의 `this` 와 오디오 스레드의 `rdi` 는 8 어긋나 있다
    /// (생성자가 `lea rbx,[rcx+8]` 로 밴드 버퍼를 심는다 — `0x1400c0cb4`). 여기 적은 오프셋은
    /// 스레드 기준(정본 `spec/engine/effect-fbo-audio.json` 과 같은 기준)이라 생성자 즉시값
    /// VA 에서 보이는 오프셋보다 8 작다.
    public static let engineFFTLengthFactor: Float = 30
    /// AudioProcessor `+0xF0`(생성자 `0x1400c0d77`) — B 계수 10.0. `B = int(10 × 64) = 640` 고정.
    public static let engineBinCountFactor: Float = 10
    /// 두 계수에 공통으로 곱해지는 64.0(`0x1404928e4`).
    public static let engineFactorScale: Float = 64

    /// 최종 게인. 1/N 정규화 진폭(`|DFT|/N`)에 곱한다.
    /// `127 × 0.001 × 2 × 640 = 162.56`. 원본 코드상으로는
    /// `AP[0x0C] × 0.001 × B / (N/2)`(0x1400d1d44-0x1400d1d5d)를 **비정규화 DFT 진폭**에
    /// 곱하고, 시간영역에서 이미 샘플에 127 을 곱해 뒀다(`0x1400d15dd`). 두 규약을 합치면 위 값이다.
    /// B 가 레이트 무관 640 고정이라 N 이 상쇄돼 **모든 샘플레이트에서 같은 상수**가 된다.
    ///
    /// **이 상수는 `user.audioinputvolume = 50`(배포 기본값)에서의 값이다.** `AP[0x0C]` 는
    /// 생성자 기본값 1.0 을 갖지만 설정 로더가 `설정 × 0.02` 로 덮어쓰고, 슬라이더가 0…200 이라
    /// 실사용 게인은 `0 … 650.24` 범위를 돈다. 레이트 무관인 것과 **설정 무관인 것은 다르다** —
    /// 설정을 아는 자리는 `gain(inputVolumeSetting:)` 을 써라.
    public static let gain: Float = 162.56

    // MARK: 창/길이 규약

    /// 원본의 창 길이 규약 (`0x1400d1491`-`0x1400d14a0`). 명령 넷이 전부다:
    ///
    /// ```
    ///   divss xmm10, xmm12   ; 10.0f / 30.0f = 0.33333334f
    ///   mulss xmm10, xmm11   ; × (float)N
    ///   subss xmm11, xmm10   ; (float)N − 위
    ///   cvttss2si edi, xmm11 ; **절삭**
    /// ```
    ///
    /// **절삭이 몫이 아니라 차에 걸린다.** 종전 구현은 `n - n/3`(정수 나눗셈)이었는데,
    /// 그건 `N − int(N/3)` 이라 절삭 위치가 한 단계 앞이다. `N % 3 == 0` 이면 같지만
    /// 아니면 1 씩 어긋난다 — 48 kHz(N=2089)에서 1393 vs 실물 **1392**, 우리 N=2048 에서
    /// 1366 vs **1365**. 한 샘플이라 관측 차이는 0.07% 지만, 원본이 float 로 재는 것을
    /// 정수로 바꿔 적을 이유는 없다.
    ///
    /// 나머지 `[W, N)` 은 패딩이고 **오버랩은 없다**(FFT 직후 `xor r13d, r13d` — `0x1400d1e21`).
    public static func windowLength(fftLength n: Int) -> Int {
        guard n > 0 else { return 1 }
        let length = Float(n)
        let dropped = (engineBinCountFactor / engineFFTLengthFactor) * length   // 10/30 = 0.33333334f
        guard let widened = safeInt(Double(length - dropped)) else { return max(1, n - n / 3) }
        return max(1, widened)
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
        // **상수 `topFrequency` 가 아니라 레이트별 상한**을 쓴다. 44.1 kHz 이상에서는 둘이
        // 0.04% 안쪽이라 48/44.1/96 kHz 의 B(627/683/314)가 그대로지만, 그 아래에서는
        // 원본이 N 을 1920 에 묶어 상한을 함께 낮춘다 — 32 kHz 에서 상수를 쓰면 B=940 이 되어
        // 원본의 10650 Hz 대신 14672 Hz 까지 덮고 64밴드가 통째로 밀린다.
        let raw = (engineTopFrequency(sampleRate: sampleRate) / binWidth).rounded()
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
    ///
    /// **32·16밴드 경계는 여기서 유도된다.** 소비단이 인접 2개씩 `maxss` 로 두 번 접으므로
    /// (`AudioSpectrumProcessor` 참조) 32밴드 j 는 64밴드 2j·2j+1 의 빈 합집합, 16밴드 j 는
    /// 4j…4j+3 의 합집합이다. B=640·44.1 kHz 기준 전체 표는 `docs/re/audio-capture.md` §8.4 에
    /// 있고, 요점은 **16밴드 0…6 이 정확히 등간격 91.875 Hz(각 4빈)** 이고 그 위가 급격히
    /// 벌어진다는 것이다(밴드 15 는 빈 145개, 11.4–14.7 kHz). 그 등간격은 위 `prev+1` 클램프의
    /// 1:1 구간(밴드 0…28)이 만든 그림자라 `B` 를 따라 변한다.
    /// `AudioSpectrumWEParityTests.testThirtyTwoAndSixteenBandBinBoundariesMatchTheDocumentedTable`
    /// 이 그 표를 고정한다.
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

/// 채널별 링버퍼 — 콜백 패킷을 누적해 정확히 `windowSize` 개가 채워질 때만 창을 방출한다
/// (홉 = 창 크기, 겹침 없음). 제로패드 없음 — 창 미만 잔여는 다음 패킷에 이어진다.
///
/// **`WapleRender` 에서 여기로 옮겨 왔다**(동작 무변경). 캡처 API 가 하나도 안 들어가는 순수
/// 값 타입인데 macOS 전용 모듈에 있어서 리눅스 테스트가 못 봤다. `WapleRender` 는 타입
/// 별칭으로 재수출하므로 호출부는 그대로다.
///
/// 실물 대응(`0x1400d02b0` 오디오 스레드):
/// - 채움 카운터 `r13d` 가 창 길이 `W` 에 닿을 때만 FFT(`0x1400d1b6b` 의 `cmp r13d, edi`).
/// - FFT 커밋 직후 카운터를 0 으로(`0x1400d1e21` `xor r13d, r13d`) — 오버랩 없음.
/// - 무음/실패 패킷도 카운터를 0 으로(`0x1400d1f58`) — 우리 `reset()` 이 그 자리다.
///
/// **한 가지는 일부러 다르다.** 원본은 창이 찬 뒤 남은 프레임을 캐리에 넣지 않고 버린다 —
/// `ReleaseBuffer(numFramesAvailable)`(`0x1400d1b19`)가 소비량이 아니라 **패킷 전체**를
/// 반납하기 때문이다. 그래서 원본의 실효 홉은 창 길이가 아니라 폴 간격 33 ms 이고
/// 매 폴마다 ~4 ms 를 버린다. 우리는 푸시 콜백이라 버릴 이유가 없어 전량 캐리한다
/// (시간 지터만 다르고 샘플은 안 잃는다 — `docs/re/audio-capture.md` §4 #5).
public struct AudioWindowAccumulator {
    public let windowSize: Int
    private var bufL: [Float] = []
    private var bufR: [Float] = []

    public init(windowSize: Int) {
        self.windowSize = Swift.max(1, windowSize)
        bufL.reserveCapacity(self.windowSize * 2)
        bufR.reserveCapacity(self.windowSize * 2)
    }

    /// 아직 창을 이루지 못한 잔여 샘플 수(진단/테스트용).
    public var pendingCount: Int { bufL.count }

    /// 패킷(L/R 동일 길이)을 누적하고, 채워진 완전 창을 선두부터 모두 방출(0개 이상, 순서 보존).
    public mutating func append(left l: [Float], right r: [Float]) -> [(left: [Float], right: [Float])] {
        bufL.append(contentsOf: l)
        bufR.append(contentsOf: r)
        // F840: 길이 어긋남 정렬. 종전에는 잔여 길이가 갈리면 짧은 쪽이 영원히 창을 못 채워
        // 긴 쪽이 무한 증가한다(캡처 세션 내내 누적 = OOM). 어긋난 시점에서 이미 L/R 동일 길이
        // 계약이 깨진 것이므로 긴 쪽의 꼬리(최신 샘플)를 버려 다시 맞춘다 — 앞쪽 정렬은 보존된다.
        if bufL.count != bufR.count {
            let aligned = Swift.min(bufL.count, bufR.count)
            bufL.removeLast(bufL.count - aligned)
            bufR.removeLast(bufR.count - aligned)
        }
        var out: [(left: [Float], right: [Float])] = []
        // F840: 종전 조건은 bufL 만 봤는데 removeFirst(windowSize) 는 bufR 에도 걸린다 —
        // 호출부가 `r.isEmpty` 만 특수 처리하므로 **길이가 다른** 스테레오 패킷
        // (non-interleaved 버퍼 두 개의 mDataByteSize 가 갈리는 경우)이 오면 트랩이었다.
        while bufL.count >= windowSize && bufR.count >= windowSize {
            out.append((Array(bufL.prefix(windowSize)), Array(bufR.prefix(windowSize))))
            bufL.removeFirst(windowSize)
            bufR.removeFirst(windowSize)
        }
        return out
    }

    /// 미완성 창 잔여 폐기(캡처 세션 경계 — 실물의 무음/실패 경로 카운터 리셋 `0x1400d1f58` 대응).
    public mutating func reset() {
        bufL.removeAll(keepingCapacity: true)
        bufR.removeAll(keepingCapacity: true)
    }
}

/// 캡처 앞단의 **순수 판정부** — 무음 게이트와 폴 규약 상수.
///
/// 캡처 API(WASAPI ↔ ScreenCaptureKit)는 플랫폼마다 다르지만 여기 있는 것은 전부
/// 산술이라 리눅스에서 돈다. 근거는 `docs/re/audio-capture.md` §1.5, §3.6.
public enum AudioCaptureGate {

    /// 실물이 창 피크를 재는 방식: **채널 0 만**, 부호 있는 max, 0 바닥.
    ///
    /// `0x1400d1a36` 이 stride 를 `nChannels · 4` 로 잡고 `[base + idx·stride]` 를 훑는다 —
    /// 즉 프레임마다 **첫 채널** 하나다. 시작값은 `xorps xmm4, xmm4`(0)이고 비교는 `maxss`
    /// (`0x1400d1a95`)라 절댓값이 아니다. 우리는 종전에 L·R 둘 다 봤는데, 그러면 하드
    /// 우측 팬 신호에서 판정이 갈린다(실물은 무음, 우리는 통과). 기본 threshold 가 0
    /// (비활성)이라 실사용 영향은 없지만 파리티는 파리티다.
    ///
    /// 비유한 샘플은 무시한다 — 실물은 `maxss` 라 NaN 을 그냥 흘리지만 우리 쪽에서 그러면
    /// 비교가 전부 false 가 되어 게이트가 조용히 열린다.
    public static func windowPeak(_ channel0: [Float]) -> Float {
        var peak: Float = 0
        for s in channel0 where s.isFinite && s > peak { peak = s }
        return peak
    }

    /// 무음 판정. 활성 조건은 `threshold > FLT_EPSILON`(`0x1400d1a1b` 의 `comiss`/`jbe`),
    /// 활성 시 `threshold > peak` 이면 그 창은 무음이다(`0x1400d1ad6`). 경계 `==` 는 통과.
    /// 기본 threshold 0 이면 항상 비활성이라 무회귀다.
    public static func isSilenced(peak: Float, threshold: Float) -> Bool {
        threshold > Float.ulpOfOne && peak < threshold
    }

    /// 오디오 스레드의 폴 간격(ms). AudioProcessor `+0x14`, 생성자 `0x1400c0ccf` 의 `0x21`,
    /// 소비는 `0x1400d0404`-`0x1400d0407` 의 `Sleep`. 우리는 푸시 콜백이라 폴링하지 않는다 —
    /// 실물의 실효 프레임 간격을 기술하는 값으로만 둔다.
    public static let pollIntervalMilliseconds = 33

    /// 패킷이 한 건도 안 오는 상태가 이만큼 이어지면 실물은 출력 128 float 을 0 으로 지운다
    /// (`0x1400d14ac` 의 `comiss xmm7, 1000.0` → `0x1400d1f5b` 의 memset). 누산기는 폴
    /// 간격을 더하고(`0x1400d14c8`), 패킷이 하나라도 오면 0 으로 리셋된다(`0x1400d14ce`).
    public static let idleSilenceTimeoutMilliseconds: Double = 1000

    /// 실물이 요구하는 샘플 폭 — `wBitsPerSample == 32`(`0x1400cf5bb`). 아니면
    /// "WASAPI processor requires 32 bit per sample."(`0x140486660`)를 **로그만 하고 진행**한다.
    public static let requiredBitsPerSample = 32
}
