import XCTest
import Foundation
import Accelerate
@testable import WapleCore
@testable import WapleRender

/// 오디오 입력 파이프라인(링버퍼 누적 + 무음 게이트/입력 볼륨) 테스트 — 신규.
/// 엔진 근거(WE 2.8.42 디컴파일 FUN_1400d0380, AudioProcessor 스레드):
/// - :260-274 패킷 누적(carry uVar14=local_3a0), :425 캐리 갱신, :449 창 충족 시에만 FFT.
/// - :376 게이트 활성 조건 threshold > FLT_EPSILON, :378-417 창 피크(raw max, 0 바닥),
///   :419-424 피크 < threshold → 무음. 어휘: strings/json-keys.txt:424-425(audioinputvolume/threshold).
final class AudioInputPipelineTests: XCTestCase {
    private let fftSize = 1024
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaultsSuiteName = "waple.audio-input-tests.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        AudioInputSettings.defaults = defaults
    }

    override func tearDownWithError() throws {
        AudioInputSettings.defaults = .standard
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    private func makeSetup() -> (FFTSetup, vDSP_Length)? {
        let log2n = vDSP_Length(round(log2(Double(fftSize))))
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        return (s, log2n)
    }

    // MARK: - 링버퍼 누적(FUN_1400d0380:260-274·:425·:449)

    /// 짧은 패킷 연속 투입: 창(1024) 미만에서는 방출 없음, 초과 시 제로패드 없이 순서대로 창 충족.
    /// 작은 창(8)으로 경계 정확도를 검증한다.
    func testShortPacketsAccumulateWithoutZeroPadding() {
        var acc = AudioWindowAccumulator(windowSize: 8)
        XCTAssertTrue(acc.append(left: [1, 1, 1], right: [10, 10, 10]).isEmpty)   // 3 < 8 → 분석 없음
        XCTAssertEqual(acc.pendingCount, 3)
        XCTAssertTrue(acc.append(left: [2, 2, 2], right: [20, 20, 20]).isEmpty)   // 6 < 8
        let out = acc.append(left: [3, 3, 3, 3], right: [30, 30, 30, 30])          // 10 → 창 1개 + 잔여 2
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].left, [1, 1, 1, 2, 2, 2, 3, 3])   // 제로패드 없이 패킷 경계를 이어서 채움
        XCTAssertEqual(out[0].right, [10, 10, 10, 20, 20, 20, 30, 30])
        XCTAssertEqual(acc.pendingCount, 2)
    }

    /// 정확히 창 크기 패킷은 즉시 창 1개(내용 비트 동일, 절단/패딩 없음).
    func testExactWindowPacketEmitsImmediately() {
        var acc = AudioWindowAccumulator(windowSize: fftSize)
        let l = (0..<fftSize).map { Float($0) }
        let r = (0..<fftSize).map { Float($0 + 10000) }
        let out = acc.append(left: l, right: r)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].left, l)
        XCTAssertEqual(out[0].right, r)
        XCTAssertEqual(acc.pendingCount, 0)
    }

    /// 창보다 큰 패킷은 완전 창을 모두 방출(순서 보존)하고 잔여를 남긴다(hop = 창 크기, 겹침 없음).
    func testOversizedPacketEmitsMultipleWindowsInOrder() {
        var acc = AudioWindowAccumulator(windowSize: fftSize)
        let l = (0..<2100).map { Float($0) }
        let out = acc.append(left: l, right: l)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].left, Array(l[0..<1024]))
        XCTAssertEqual(out[1].left, Array(l[1024..<2048]))
        XCTAssertEqual(acc.pendingCount, 52)
    }

    /// reset 은 미완성 창 잔여를 폐기 — 다음 누적에 이어지지 않는다(엔진 캐리 리셋 :184-185 대응).
    func testResetDiscardsPartialWindow() {
        var acc = AudioWindowAccumulator(windowSize: fftSize)
        _ = acc.append(left: [Float](repeating: 1, count: 400), right: [Float](repeating: 1, count: 400))
        acc.reset()
        XCTAssertEqual(acc.pendingCount, 0)
        XCTAssertTrue(acc.append(left: [Float](repeating: 2, count: 400),
                                 right: [Float](repeating: 2, count: 400)).isEmpty)   // 800 아닌 400
    }

    // MARK: - 무음 게이트(audioinputthreshold — FUN_1400d0380:376-424)

    /// 기본 0 = 비활성(무회귀): 피크 0 창도 무음 처리되지 않는다.
    func testGateDisabledAtDefaultThresholdZero() {
        XCTAssertFalse(SystemAudioSpectrumProvider.isSilenced(peak: 0, threshold: 0))
    }

    /// FLT_EPSILON 이하는 비활성(엔진 활성 조건 threshold > FLT_EPSILON, :376).
    func testGateInactiveAtOrBelowFloatEpsilon() {
        XCTAssertFalse(SystemAudioSpectrumProvider.isSilenced(peak: 0, threshold: Float.ulpOfOne))
        XCTAssertFalse(SystemAudioSpectrumProvider.isSilenced(peak: 0, threshold: 1e-9))
    }

    /// 활성 시 피크 < threshold → 무음, 피크 >= threshold → 통과(경계 == 는 통과 — 엔진 비교는 엄격 <:).
    func testGateBranchesAroundThreshold() {
        XCTAssertTrue(SystemAudioSpectrumProvider.isSilenced(peak: 0.4, threshold: 0.5))
        XCTAssertFalse(SystemAudioSpectrumProvider.isSilenced(peak: 0.6, threshold: 0.5))
        XCTAssertFalse(SystemAudioSpectrumProvider.isSilenced(peak: 0.5, threshold: 0.5))
    }

    /// 창 피크: **채널 0(왼쪽)만**, 부호 있는 raw max, 0 바닥(`0x1400d1a36` stride ·
    /// `0x1400d1a95` maxss — 절댓값 아님). 종전엔 L·R 합산이었다.
    /// 판정 본체의 전수 단언은 리눅스에서 도는 `WapleCoreTests/AudioCaptureParityTests` 에 있고,
    /// 여기서는 프로바이더 래퍼가 그쪽으로 위임하는지만 본다.
    func testWindowPeakIsChannelZeroRawMaxWithZeroFloor() {
        XCTAssertEqual(SystemAudioSpectrumProvider.windowPeak([-0.9, 0.3], [0.2, -0.4]), 0.3)
        XCTAssertEqual(SystemAudioSpectrumProvider.windowPeak([-0.9], [-0.4]), 0)
        XCTAssertEqual(SystemAudioSpectrumProvider.windowPeak([], []), 0)
        // 오른쪽만 큰 창은 원본에서 **무음**이다 — 종전 구현은 0.8 을 냈다.
        XCTAssertEqual(SystemAudioSpectrumProvider.windowPeak([-0.1], [0.8]), 0)
    }

    /// 게이트 통과 창은 nil(호출자가 0 스펙트럼 공급), 기본 threshold 에선 동일 창도 분석된다.
    func testAnalyzeWindowGateSilenceReturnsNilOtherwiseAnalyzes() throws {
        let (setup, log2n) = try XCTUnwrap(makeSetup())
        defer { vDSP_destroy_fftsetup(setup) }
        let quiet = [Float](repeating: 0.001, count: fftSize)   // 피크 0.001
        XCTAssertNil(SystemAudioSpectrumProvider.analyzeWindow(
            l: quiet, r: quiet, fftSize: fftSize, log2n: log2n, setup: setup, threshold: 0.5, volume: 1))
        let out = try XCTUnwrap(SystemAudioSpectrumProvider.analyzeWindow(
            l: quiet, r: quiet, fftSize: fftSize, log2n: log2n, setup: setup, threshold: 0, volume: 1))
        XCTAssertEqual(out.count, 128)
    }

    // MARK: - 입력 볼륨(audioinputvolume — json-keys.txt:424)

    /// volume 은 결과 스펙트럼 전체를 스케일한다.
    func testAnalyzeWindowVolumeScalesSpectrum() throws {
        let (setup, log2n) = try XCTUnwrap(makeSetup())
        defer { vDSP_destroy_fftsetup(setup) }
        let sine = (0..<fftSize).map { Float(sin(2.0 * .pi * 16.0 * Double($0) / Double(fftSize))) }
        let base = try XCTUnwrap(SystemAudioSpectrumProvider.analyzeWindow(
            l: sine, r: sine, fftSize: fftSize, log2n: log2n, setup: setup, threshold: 0, volume: 1))
        let doubled = try XCTUnwrap(SystemAudioSpectrumProvider.analyzeWindow(
            l: sine, r: sine, fftSize: fftSize, log2n: log2n, setup: setup, threshold: 0, volume: 2))
        XCTAssertEqual(doubled.count, base.count)
        for (a, b) in zip(base, doubled) { XCTAssertEqual(b, a * 2, accuracy: 1e-6) }
    }

    /// 무회귀: threshold=0/volume=1 에서 게이트·볼륨 없는 기존 계산 경로와 비트 동일.
    func testAnalyzeWindowDefaultsAreIdentityRegression() throws {
        let (setup, log2n) = try XCTUnwrap(makeSetup())
        defer { vDSP_destroy_fftsetup(setup) }
        let sine = (0..<fftSize).map { Float(sin(2.0 * .pi * 16.0 * Double($0) / Double(fftSize))) }
        let mags = try XCTUnwrap(SystemAudioSpectrumProvider.magnitudes(from: sine, fftSize: fftSize))
        // X-⑩: 프로덕션과 같은 정규화 규약으로 재구성한다 — vDSP packed-real 출력은 수학적
        // DFT 의 2배라 나눗수가 2N 이고, 소비 빈 수는 원본과 같은 상한 주파수까지다.
        // analyzeWindow 가 sampleRate 를 안 받으면 기본값(원본 기준 44100)을 쓰므로 여기도 같게 둔다.
        let norm = 1 / (2 * Float(fftSize))
        let bins = AudioSpectrum.binCount(fftLength: fftSize, sampleRate: AudioSpectrum.referenceRate)
        let one = AudioSpectrum.spectrum(normalizedMagnitudes: mags.map { $0 * norm }, binCount: bins)
        let manual = Array((one + one).prefix(128))
        let out = try XCTUnwrap(SystemAudioSpectrumProvider.analyzeWindow(
            l: sine, r: sine, fftSize: fftSize, log2n: log2n, setup: setup, threshold: 0, volume: 1))
        XCTAssertEqual(out, manual)   // ×1.0 은 IEEE 상 정확히 항등
    }

    // MARK: - 설정 영속(UserDefaults) — 저장 단위는 **WE 설정 단위**다

    /// 미저장 기본값이 배포 `config.json` 과 같고, 파생값이 종전 기본값과 **비트 동일**이다.
    ///
    /// 종전에는 `volume` 이 곱수(기본 1) · `threshold` 가 임계 그대로(기본 0)였다. 지금은
    /// 설정 정수/실수를 저장하고 곱수·임계는 `AudioSpectrum` 이 만든다. 기본 설정 50 이
    /// 정확히 곱수 1.0 을 만들기 때문에(50 × 0.02f, 오차 2.2e-8 < 반ULP 3.0e-8) **기본 설치의
    /// 관측 결과는 변하지 않는다** — 그 등식을 여기서 값으로 못 박는다.
    func testInputSettingDefaultsMatchShippedConfigAndDeriveTheOldDefaults() {
        XCTAssertEqual(AudioInputSettings.volumeSetting, 50)      // 배포 config.json
        XCTAssertEqual(AudioInputSettings.thresholdSetting, 0)
        XCTAssertEqual(AudioInputSettings.volume, 1)              // 종전 기본 곱수와 동일
        XCTAssertEqual(AudioInputSettings.threshold, 0)           // 종전 기본 임계와 동일
    }

    /// 라운드트립과 **변환**. 설정을 그대로 곱수로 쓰면 50배, 임계로 쓰면 1000배라는 것도 같이 잠근다.
    func testInputSettingRoundTripAppliesTheEngineScales() {
        AudioInputSettings.volumeSetting = 100
        AudioInputSettings.thresholdSetting = 10
        XCTAssertEqual(AudioInputSettings.volumeSetting, 100)
        XCTAssertEqual(AudioInputSettings.thresholdSetting, 10)
        XCTAssertEqual(AudioInputSettings.volume, 2.0, accuracy: 1e-6)      // 100 × 0.02
        XCTAssertEqual(AudioInputSettings.threshold, 0.01, accuracy: 1e-8)  // 10 × 0.001
        // 설정을 그대로 썼다면 각각 50배 · 1000배였다.
        XCTAssertEqual(Float(AudioInputSettings.volumeSetting) / AudioInputSettings.volume, 50, accuracy: 1e-4)
        XCTAssertEqual(AudioInputSettings.thresholdSetting / AudioInputSettings.threshold, 1000, accuracy: 1e-2)
        // 슬라이더 밖 값도 통과한다 — 실물 로더에 클램프가 없다(0x14006C741~0x14006C766 에
        // minss/maxss/comiss 가 0개).
        AudioInputSettings.volumeSetting = 500
        XCTAssertEqual(AudioInputSettings.volume, 10.0, accuracy: 1e-4)
    }

    /// **옛 키는 읽지 않는다.** 옛 키에 종전 의미의 값(곱수 1.5)이 남아 있어도 새 키가 비어 있으면
    /// 기본값이 나와야 한다 — 이름을 유지한 채 의미만 바꿨다면 여기서 1.5 가 **설정 1.5**로 읽혀
    /// 곱수가 0.03 이 됐을 것이다(그리고 반대 방향의 마이그레이션이었다면 50배).
    func testLegacyKeysAreNeverRead() {
        defaults.set(Float(1.5), forKey: AudioInputSettings.legacyVolumeKey)
        defaults.set(Float(0.25), forKey: AudioInputSettings.legacyThresholdKey)
        XCTAssertEqual(AudioInputSettings.volumeSetting, 50)
        XCTAssertEqual(AudioInputSettings.volume, 1)
        XCTAssertEqual(AudioInputSettings.thresholdSetting, 0)
        XCTAssertEqual(AudioInputSettings.threshold, 0)
        // 새 키에 쓴 값은 옛 키를 건드리지 않는다(옛 값은 남아 있고, 읽히지만 않는다).
        AudioInputSettings.volumeSetting = 75
        XCTAssertEqual(defaults.float(forKey: AudioInputSettings.legacyVolumeKey), 1.5)
        XCTAssertEqual(AudioInputSettings.volume, 1.5, accuracy: 1e-6)   // 75 × 0.02
    }

    /// 키 이름 자체를 못 박는다 — 새 키가 옛 키와 **다른 문자열**이어야 마이그레이션이 성립한다.
    func testSettingKeysAreDistinctFromLegacyKeys() {
        XCTAssertEqual(AudioInputSettings.legacyVolumeKey, "waple.audioInputVolume")
        XCTAssertEqual(AudioInputSettings.legacyThresholdKey, "waple.audioInputThreshold")
        XCTAssertEqual(AudioInputSettings.volumeSettingKey, "waple.audioInputVolumeSetting")
        XCTAssertEqual(AudioInputSettings.thresholdSettingKey, "waple.audioInputThresholdSetting")
        XCTAssertNotEqual(AudioInputSettings.legacyVolumeKey, AudioInputSettings.volumeSettingKey)
        XCTAssertNotEqual(AudioInputSettings.legacyThresholdKey, AudioInputSettings.thresholdSettingKey)
    }

    /// 테스트 주입점의 읽기·쓰기가 실제 고유 suite 로 향하는지 잠근다. 이 테스트를 포함해 클래스 어디도
    /// 사용자 단위 `UserDefaults.standard` 의 오디오 키를 읽거나 쓰지 않는다.
    func testInputSettingsUseInjectedDefaultsSuite() {
        defaults.set(321, forKey: AudioInputSettings.volumeSettingKey)
        defaults.set(Float(12.5), forKey: AudioInputSettings.thresholdSettingKey)
        XCTAssertEqual(AudioInputSettings.volumeSetting, 321)
        XCTAssertEqual(AudioInputSettings.thresholdSetting, 12.5)

        AudioInputSettings.volumeSetting = 88
        AudioInputSettings.thresholdSetting = 4.25
        XCTAssertEqual(defaults.integer(forKey: AudioInputSettings.volumeSettingKey), 88)
        XCTAssertEqual(defaults.float(forKey: AudioInputSettings.thresholdSettingKey), 4.25)
    }
}
