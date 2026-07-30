import XCTest
import Foundation
import Accelerate
@testable import WapleRender

/// 오디오 입력 파이프라인(링버퍼 누적 + 무음 게이트/입력 볼륨) 테스트 — 신규.
/// 엔진 근거(WE 2.8.42 디컴파일 FUN_1400d0380, AudioProcessor 스레드):
/// - :260-274 패킷 누적(carry uVar14=local_3a0), :425 캐리 갱신, :449 창 충족 시에만 FFT.
/// - :376 게이트 활성 조건 threshold > FLT_EPSILON, :378-417 창 피크(raw max, 0 바닥),
///   :419-424 피크 < threshold → 무음. 어휘: strings/json-keys.txt:424-425(audioinputvolume/threshold).
final class AudioInputPipelineTests: XCTestCase {
    private let fftSize = 1024

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

    /// 창 피크: 채널 합산, 부호 있는 raw max, 0 바닥(:378-417 — 절댓값 아님).
    func testWindowPeakIsRawMaxAcrossChannelsWithZeroFloor() {
        XCTAssertEqual(SystemAudioSpectrumProvider.windowPeak([-0.9, 0.3], [0.2, -0.4]), 0.3)
        XCTAssertEqual(SystemAudioSpectrumProvider.windowPeak([-0.9], [-0.4]), 0)
        XCTAssertEqual(SystemAudioSpectrumProvider.windowPeak([], []), 0)
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
        let manual = Array((AudioSpectrum.spectrum(fromMagnitudes: mags, binCount: 64)
                            + AudioSpectrum.spectrum(fromMagnitudes: mags, binCount: 64)).prefix(128))
        let out = try XCTUnwrap(SystemAudioSpectrumProvider.analyzeWindow(
            l: sine, r: sine, fftSize: fftSize, log2n: log2n, setup: setup, threshold: 0, volume: 1))
        XCTAssertEqual(out, manual)   // ×1.0 은 IEEE 상 정확히 항등
    }

    // MARK: - 설정 영속(UserDefaults)

    /// 기본값 threshold 0(비활성)/volume 1(무회귀)과 라운드트립. 키는 `waple.` 접두 관례.
    func testInputSettingsDefaultsAndRoundTrip() {
        let d = UserDefaults.standard
        d.removeObject(forKey: AudioInputSettings.thresholdKey)
        d.removeObject(forKey: AudioInputSettings.volumeKey)
        XCTAssertEqual(AudioInputSettings.threshold, 0)
        XCTAssertEqual(AudioInputSettings.volume, 1)
        AudioInputSettings.threshold = 0.25
        AudioInputSettings.volume = 1.5
        defer {
            d.removeObject(forKey: AudioInputSettings.thresholdKey)
            d.removeObject(forKey: AudioInputSettings.volumeKey)
        }
        XCTAssertEqual(AudioInputSettings.threshold, 0.25)
        XCTAssertEqual(AudioInputSettings.volume, 1.5)
    }
}
