import XCTest
@testable import WapleCore

/// `user.audioinputvolume` / `user.audioinputthreshold` → AudioProcessor `+0x0C` / `+0x10`.
///
/// 이 문서가 잠그는 것은 **게인이 상수가 아니라는 사실**이다. `AudioSpectrum.gain = 162.56` 은
/// 배포 `config.json` 의 `audioinputvolume = 50` 에서의 값이고, 슬라이더가 `floor:0, ceil:200`
/// 이라 실사용 게인은 `0 … 650.24` 를 돈다.
///
/// 근거 사슬(전부 `wallpaper64.exe`, imagebase `0x140000000`):
/// - 설정 로더 `0x14006c72c`(키 `lea`) → `0x14006c741`(`asInt`) → `0x14006c75e`
///   (`mulss [0x14049262c]`, = 0.019999999552965164f) → `0x14006c766`(`movss [0x1404e55b4]`).
///   그 사이에 **클램프 명령이 없다**.
/// - 전역 AudioProcessor: `0x140064d0f  lea rcx,[0x1404e55a0]` → `0x140064d28  call 0x1400c0c80`
///   (생성자). 스레드 베이스는 `+8`(`0x1400c0ca6  lea rbx,[rcx+8]`) 이라 `0x1404e55a8`,
///   따라서 `0x1404e55b4 = AP+0x0C` · `0x1404e55b8 = AP+0x10`.
/// - 캡처 스레드는 `{this=0x1404e55a8, fn=0x1400d02b0}` 클로저로 뜬다
///   (`0x14006e525`/`0x14006e52f`; 재시도 분기 `0x14006e5ac`/`0x14006e5b6`). 직접 호출 자리는 0곳.
/// - 소비: 게인 `0x1400d1d3f  movss xmm2,[rdi+0xc]` (스레드 안에서 `AP+0x0C` 를 읽는 유일한 자리),
///   무음 임계 `0x1400d1a15  movss xmm5,[r14+0x10]`.
/// - 상수 `0x14049262c` 의 적재 자리는 이미지 전체 **4곳**, 오디오 경로는 그중 `0x14006c75e` 하나.
final class AudioInputSettingsParityTests: XCTestCase {

    // MARK: 볼륨 설정 → AP+0x0C

    /// **계수는 1/100 이 아니라 1/50 이다.** 슬라이더가 0…200 이고 중립점이 50 이라 그렇다.
    /// 0…100 슬라이더라고 짐작해 `설정/100` 을 쓰면 기본값에서 곱수가 0.5 가 되어 **6 dB 낮다**.
    func testInputVolumeSettingMapsByOneFiftiethNotOneHundredth() {
        // float32 에서 정확히 떨어지는 점들(50×0.02f 의 오차 2.2e-8 < 반ULP 3.0e-8).
        XCTAssertEqual(AudioSpectrum.inputVolumeGain(setting: 0), 0)
        XCTAssertEqual(AudioSpectrum.inputVolumeGain(setting: 25), 0.5)
        XCTAssertEqual(AudioSpectrum.inputVolumeGain(setting: 50), 1.0)
        XCTAssertEqual(AudioSpectrum.inputVolumeGain(setting: 100), 2.0)
        XCTAssertEqual(AudioSpectrum.inputVolumeGain(setting: 150), 3.0)
        XCTAssertEqual(AudioSpectrum.inputVolumeGain(setting: 200), 4.0)
        // `설정/100` 이었다면 기본값이 0.5 였을 것 — 그 가설을 값으로 배제한다.
        XCTAssertNotEqual(AudioSpectrum.inputVolumeGain(setting: 50), 0.5)
    }

    /// 상수 자체를 고정한다 — `0x14049262c` 의 실제 바이트가 `0.02` 의 float32 반올림값이다.
    func testScaleFactorIsTheFloat32RoundingOfTwoHundredths() {
        XCTAssertEqual(AudioSpectrum.inputVolumeScaleFactor, Float(0.02))
        XCTAssertEqual(Double(AudioSpectrum.inputVolumeScaleFactor), 0.019999999552965164, accuracy: 1e-17)
        XCTAssertEqual(AudioSpectrum.inputThresholdScaleFactor, Float(0.001))
    }

    /// 배포 기본값과 슬라이더 도메인. `ceil` 이 100 이 아니라 **200** 이다.
    func testShippedDefaultAndSliderDomain() {
        XCTAssertEqual(AudioSpectrum.defaultInputVolumeSetting, 50)
        XCTAssertEqual(AudioSpectrum.inputVolumeSettingRange, 0...200)
        XCTAssertEqual(AudioSpectrum.defaultInputThresholdSetting, 0)
    }

    // MARK: 게인

    /// `gain` 상수는 **설정 50 에서의 값**이라는 것을 못 박는다.
    func testConstantGainIsTheDefaultSettingNotASettingIndependentConstant() {
        XCTAssertEqual(AudioSpectrum.gain(inputVolumeSetting: AudioSpectrum.defaultInputVolumeSetting),
                       AudioSpectrum.gain)
        XCTAssertEqual(AudioSpectrum.gain, 162.56)
    }

    /// 설정을 따라 선형으로 움직인다. 이 네 값이 "게인은 상수" 라는 종전 서술을 배제한다.
    func testGainSpansZeroToSixHundredFiftyAcrossTheSliderDomain() {
        XCTAssertEqual(AudioSpectrum.gain(inputVolumeSetting: 0), 0)
        XCTAssertEqual(AudioSpectrum.gain(inputVolumeSetting: 25), 81.28, accuracy: 1e-3)
        XCTAssertEqual(AudioSpectrum.gain(inputVolumeSetting: 100), 325.12, accuracy: 1e-3)
        XCTAssertEqual(AudioSpectrum.gain(inputVolumeSetting: 200), 650.24, accuracy: 1e-3)
        // 슬라이더 양 끝이 정확히 16배 차이(0 제외) — 0.02 × 200 = 4.0 이므로.
        XCTAssertEqual(AudioSpectrum.gain(inputVolumeSetting: 200)
                        / AudioSpectrum.gain(inputVolumeSetting: 50), 4.0, accuracy: 1e-5)
    }

    /// 실물은 **클램프하지 않는다** — `asInt` 와 저장 사이에 `minss`/`maxss`/`comiss` 가 없다.
    /// 슬라이더 밖 값(직접 편집한 config)은 그대로 통과한다.
    func testSettingIsNotClamped() {
        XCTAssertEqual(AudioSpectrum.inputVolumeGain(setting: 500), 10.0, accuracy: 1e-5)
        XCTAssertEqual(AudioSpectrum.inputVolumeGain(setting: -50), -1.0, accuracy: 1e-5)
    }

    // MARK: 비정규화 진폭 규약과의 항등식

    /// `engineRawBandGain` 이 이제 `AP+0x0C` 를 **인자로** 받는다. 종전엔 리터럴 1.0 이었다.
    /// 항등식 `sampleBias × engineRawBandGain(B, N, apVolume:v) × N == gain(설정)` 이 설정을
    /// 넣어도 성립해야 한다(B = 640 고정, N 은 상쇄).
    func testRawBandGainIdentityCarriesTheVolumeField() {
        let B = AudioSpectrum.referenceBinCount
        for setting in [0, 25, 50, 100, 200] {
            let v = AudioSpectrum.inputVolumeGain(setting: setting)
            for n in [1920, 2048, 2089, 4179] {
                let raw = AudioSpectrum.engineRawBandGain(binCount: B, fftLength: n, apVolume: v)
                let normalized = AudioSpectrum.sampleBias * raw * Float(n)
                XCTAssertEqual(normalized, AudioSpectrum.gain(inputVolumeSetting: setting),
                               accuracy: max(1e-3, AudioSpectrum.gain * 1e-4),
                               "setting=\(setting) N=\(n)")
            }
        }
    }

    /// 기본 인자가 생성자 기본값 1.0 이라 기존 호출부는 무회귀.
    func testRawBandGainDefaultArgumentIsTheConstructorDefault() {
        XCTAssertEqual(AudioSpectrum.engineRawBandGain(binCount: 640, fftLength: 1920),
                       AudioSpectrum.engineRawBandGain(binCount: 640, fftLength: 1920, apVolume: 1.0))
    }

    // MARK: 무음 임계

    /// 임계는 `설정 × 0.001` 이고 슬라이더가 `floor:0, ceil:10, step:.1` 이라 도메인이 `[0, 0.01]` 이다.
    /// **설정값을 그대로 임계로 쓰면 1000배** — 어떤 실신호도 무음으로 판정된다.
    func testThresholdMapsByOneThousandthAndDefaultDisablesTheGate() {
        XCTAssertEqual(AudioSpectrum.inputThreshold(setting: 0), 0)
        XCTAssertEqual(AudioSpectrum.inputThreshold(setting: 1), 0.001, accuracy: 1e-9)
        XCTAssertEqual(AudioSpectrum.inputThreshold(setting: 10), 0.01, accuracy: 1e-8)
        // 기본 0 은 게이트 비활성(`threshold <= FLT_EPSILON`, 0x1400d1a1b).
        XCTAssertFalse(AudioCaptureGate.isSilenced(
            peak: 1e-9, threshold: AudioSpectrum.inputThreshold(setting: AudioSpectrum.defaultInputThresholdSetting)))
        // 슬라이더 최대에서도 0.01 이라, 0.02 짜리 조용한 신호는 통과한다.
        XCTAssertFalse(AudioCaptureGate.isSilenced(peak: 0.02,
                                                   threshold: AudioSpectrum.inputThreshold(setting: 10)))
        // 설정을 그대로 썼다면(0.001 을 빼먹었다면) 같은 신호가 무음으로 뭉개진다.
        XCTAssertTrue(AudioCaptureGate.isSilenced(peak: 0.02, threshold: 10))
    }

    // MARK: 우리 쪽 단위와의 발산

    /// **`SystemAudioSpectrumProvider.AudioInputSettings.volume` 은 곱수(기본 1)이고 WE 설정은
    /// 0…200 정수(기본 50)다.** WE 값을 그대로 곱수로 넣으면 정확히 50배가 된다.
    /// 이 자리는 소유 밖이라 코어에 변환기만 두고 값으로 잠근다.
    func testRawWEsettingUsedAsAMultiplierIsFiftyTimesTooLoud() {
        let weSetting = Float(AudioSpectrum.defaultInputVolumeSetting)   // 50
        let correct = AudioSpectrum.inputVolumeGain(setting: AudioSpectrum.defaultInputVolumeSetting)
        XCTAssertEqual(correct, 1.0)
        XCTAssertEqual(weSetting / correct, 50.0, accuracy: 1e-5)
    }
}
