import XCTest
@testable import WapleCore

/// 캡처 앞단(레이트 → N·W·B, 게인 유도, 창 누적, 무음 게이트) WE 파리티.
///
/// 왜 별도 파일인가 — `AudioSpectrumWEParityTests` 는 **밴드 산출**(매핑·틸트·축약·게인)을 본다.
/// 이 파일은 그 **앞단**, 즉 "레이트가 주어졌을 때 무엇이 정해지는가" 를 고정한다. 종전에는
/// 이 계층이 통째로 `WapleRender`(macOS 전용)에 있어서 리눅스 레인이 0건을 통과했다.
///
/// 근거는 전부 원본 `wallpaper64.exe` 디스어셈블이다. 전표는 `docs/re/audio-capture.md`.
/// 캡처 API 자체(SCStream/WASAPI 호출)는 여기 없다 — 그건 macOS `swift test` 의 몫이다.
final class AudioCaptureParityTests: XCTestCase {

    // MARK: N · W · 상한 (0x1400cf5e4-0x1400cf630, 0x1400d1491-0x1400d14a0)

    /// `N = int(max(rate/44100, 1) · 64 · 30)` — float32 절삭까지 그대로.
    /// 48 kHz 의 2089 는 반올림(2090)이 아니라 절삭이라는 증거다.
    func testEngineFFTLengthPerSampleRate() {
        let expected: [(Double, Int)] = [
            (22050, 1920),   // 44.1 kHz 미만 → 클램프로 1920 고정
            (32000, 1920),
            (44100, 1920),
            (48000, 2089),   // 2089.7959… 절삭
            (88200, 3840),
            (96000, 4179),
            (192000, 8359),
        ]
        for (rate, n) in expected {
            XCTAssertEqual(AudioSpectrum.engineFFTLength(sampleRate: rate), n, "rate=\(rate)")
        }
    }

    /// 실무 레이트에서 원본 N 은 **한 번도 2의 거듭제곱이 아니다** — 그래서 원본은 항상
    /// Bluestein 경로를 탄다(`0x1400d05e9` 의 `test r12, r12-1`). 우리가 길이를 그대로 못
    /// 따라가는 이유가 여기 있다.
    func testEngineFFTLengthIsNeverAPowerOfTwoAtRealRates() {
        for rate in [22050.0, 32000, 44100, 48000, 88200, 96000, 192000] {
            let n = AudioSpectrum.engineFFTLength(sampleRate: rate)
            XCTAssertNotEqual(n & (n - 1), 0, "rate=\(rate) N=\(n) 이 2의 거듭제곱이면 전제가 깨진다")
        }
    }

    /// 창은 항상 N 의 2/3, 물리 시간으로는 44.1 kHz 이상에서 ≈29 ms.
    func testEngineWindowIsTwoThirdsAndAboutTwentyNineMilliseconds() {
        XCTAssertEqual(AudioSpectrum.engineWindowLength(sampleRate: 44100), 1280)
        XCTAssertEqual(AudioSpectrum.engineWindowLength(sampleRate: 48000), 1392,
                       "정수 나눗셈 `N - N/3` 이면 1393 이 나온다 — 절삭이 차에 걸린다는 증거")
        XCTAssertEqual(AudioSpectrum.engineWindowLength(sampleRate: 96000), 2786)
        for rate in [44100.0, 48000, 88200, 96000, 192000] {
            let ms = Double(AudioSpectrum.engineWindowLength(sampleRate: rate)) / rate * 1000
            XCTAssertEqual(ms, 29.0, accuracy: 0.1, "rate=\(rate) 창 길이 \(ms) ms")
        }
        // 44.1 kHz 미만은 N 이 고정이라 창이 **길어진다** — 32 kHz 에서 40 ms.
        XCTAssertEqual(Double(AudioSpectrum.engineWindowLength(sampleRate: 32000)) / 32000 * 1000,
                       40.0, accuracy: 0.01)
    }

    /// 상한 주파수는 44.1 kHz 이상에서만 거의 상수다. 종전 주석이 "레이트 무관 상수" 라고
    /// 단정했는데 32 kHz 에서 27% 낮다 — 이 테스트가 그 단정을 막는다.
    func testEngineTopFrequencyIsOnlyConstantAtOrAboveReferenceRate() {
        for rate in [44100.0, 48000, 88200, 96000, 192000] {
            XCTAssertEqual(AudioSpectrum.engineTopFrequency(sampleRate: rate), 14677.03125,
                           accuracy: 14677.03125 * 5e-4, "rate=\(rate)")
        }
        XCTAssertEqual(AudioSpectrum.engineTopFrequency(sampleRate: 32000), 10650.0, accuracy: 0.5)
        XCTAssertEqual(AudioSpectrum.engineTopFrequency(sampleRate: 22050), 7338.5, accuracy: 0.5)
        XCTAssertEqual(AudioSpectrum.engineTopFrequency(sampleRate: 44100), AudioSpectrum.topFrequency,
                       accuracy: 1e-9, "44.1 kHz 에서는 상수와 같아야 한다")
    }

    /// 우리 `binCount` 는 그 레이트별 상한을 써야 한다. 48/44.1/96 kHz 는 종전과 같고
    /// (상수와 0.04% 안쪽이라), **32 kHz 만 940 → 683 으로 바뀐다** — 이게 이번 정정이다.
    func testBinCountFollowsRateCorrectTopFrequency() {
        XCTAssertEqual(AudioSpectrum.binCount(fftLength: 2048, sampleRate: 48000), 627, "무회귀")
        XCTAssertEqual(AudioSpectrum.binCount(fftLength: 2048, sampleRate: 44100), 683, "무회귀")
        XCTAssertEqual(AudioSpectrum.binCount(fftLength: 2048, sampleRate: 96000), 314, "무회귀")
        XCTAssertEqual(AudioSpectrum.binCount(fftLength: 2048, sampleRate: 32000), 683,
                       "상수 상한을 쓰면 940 이 나오고 밴드가 통째로 밀린다")
        // 실제로 덮는 상한이 원본과 맞는지 — 이게 이 함수의 계약이다.
        for rate in [22050.0, 32000, 44100, 48000, 96000] {
            let b = AudioSpectrum.binCount(fftLength: 2048, sampleRate: rate)
            let covered = Double(b - 1) * rate / 2048
            XCTAssertEqual(covered, AudioSpectrum.engineTopFrequency(sampleRate: rate),
                           accuracy: rate / 2048, "rate=\(rate) 상한 \(covered) Hz")
        }
    }

    // MARK: 게인 유도 (0x1400d1d3f-0x1400d1d5d)

    /// 원본 게인은 `1.0 · 0.001 · B / (N/2)` 이고 **비정규화 DFT 진폭**에 걸린다.
    /// 우리 `gain`(1/N 정규화 진폭 기준)과의 관계가 이 항등식이다:
    ///
    ///     sampleBias(127) × engineRawBandGain(B, N) × N == gain(162.56)      (B = 640)
    ///
    /// N 이 상쇄되므로 **모든 레이트에서** 성립해야 한다 — 그게 162.56 을 상수로 둘 수 있는 근거다.
    func testAbsoluteGainDerivationHoldsAtEveryRate() {
        for rate in [44100.0, 48000, 88200, 96000, 192000] {
            let n = AudioSpectrum.engineFFTLength(sampleRate: rate)
            let raw = AudioSpectrum.engineRawBandGain(binCount: AudioSpectrum.referenceBinCount,
                                                      fftLength: n)
            let normalized = AudioSpectrum.sampleBias * raw * Float(n)
            XCTAssertEqual(normalized, AudioSpectrum.gain, accuracy: AudioSpectrum.gain * 1e-5,
                           "rate=\(rate) N=\(n)")
        }
    }

    /// 게인식이 우리 `B`(627/683)에서 재유도되면 안 된다 — 원본의 B 는 언제나 640 이고
    /// 우리 B 는 "같은 구간을 다른 격자로 덮는 개수" 라 의미가 다르다. 2% 어긋난다.
    func testGainMustNotBeRederivedFromOurBinCount() {
        let n = 2048
        let wrong = AudioSpectrum.sampleBias
            * AudioSpectrum.engineRawBandGain(binCount: 627, fftLength: n) * Float(n)
        XCTAssertEqual(wrong, 159.258, accuracy: 0.01)
        XCTAssertNotEqual(wrong, AudioSpectrum.gain)
    }

    /// 계수 셋이 실물 즉시값 그대로인지(생성자 `0x1400c0d6d`·`0x1400c0d77`, 상수 `0x1404928e4`).
    func testEngineFactorsMatchConstructorImmediates() {
        XCTAssertEqual(AudioSpectrum.engineFFTLengthFactor, 30)
        XCTAssertEqual(AudioSpectrum.engineBinCountFactor, 10)
        XCTAssertEqual(AudioSpectrum.engineFactorScale, 64)
        XCTAssertEqual(AudioSpectrum.sampleBias, 127)
        // B = int(10 × 64) 이고 레이트에 안 딸린다.
        XCTAssertEqual(Int(AudioSpectrum.engineBinCountFactor * AudioSpectrum.engineFactorScale),
                       AudioSpectrum.referenceBinCount)
        // N(44.1k) = int(1 × 64 × 30)
        XCTAssertEqual(Int(AudioSpectrum.engineFactorScale * AudioSpectrum.engineFFTLengthFactor),
                       AudioSpectrum.referenceFFTLength)
    }

    /// 퇴화 레이트에서 트랩하지 않고 기준값으로 떨어진다.
    func testDegenerateSampleRates() {
        for bad in [0.0, -1, .nan, .infinity, 1e300] {
            XCTAssertEqual(AudioSpectrum.engineFFTLength(sampleRate: bad),
                           AudioSpectrum.referenceFFTLength, "rate=\(bad)")
        }
        XCTAssertGreaterThanOrEqual(AudioSpectrum.binCount(fftLength: 2048, sampleRate: .nan), 2)
        XCTAssertEqual(AudioSpectrum.engineRawBandGain(binCount: 640, fftLength: 0), 0)
    }

    // MARK: 창 누적기 (0x1400d1b6b · 0x1400d1e21)

    /// 창 미만은 방출 없이 이어 붙고, 창을 넘으면 완전 창만 순서대로 나온다(제로패드 없음).
    func testAccumulatorEmitsOnlyCompleteWindowsInOrder() {
        var acc = AudioWindowAccumulator(windowSize: 8)
        XCTAssertTrue(acc.append(left: [1, 1, 1], right: [10, 10, 10]).isEmpty)
        XCTAssertEqual(acc.pendingCount, 3)
        let out = acc.append(left: [2, 2, 2, 3, 3, 3, 3], right: [20, 20, 20, 30, 30, 30, 30])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].left, [1, 1, 1, 2, 2, 2, 3, 3])
        XCTAssertEqual(out[0].right, [10, 10, 10, 20, 20, 20, 30, 30])
        XCTAssertEqual(acc.pendingCount, 2)
    }

    /// 홉 = 창 크기(겹침 0). 원본이 커밋 직후 카운터를 0 으로 되돌리는 것과 같다.
    func testHopEqualsWindowSizeWithNoOverlap() {
        var acc = AudioWindowAccumulator(windowSize: 4)
        let x = (0..<12).map { Float($0) }
        let out = acc.append(left: x, right: x)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].left, [0, 1, 2, 3])
        XCTAssertEqual(out[1].left, [4, 5, 6, 7])
        XCTAssertEqual(out[2].left, [8, 9, 10, 11])
        XCTAssertEqual(acc.pendingCount, 0)
    }

    /// F840 회귀: L/R 길이가 갈려도 긴 쪽이 무한히 자라지 않고, `removeFirst` 가 트랩하지 않는다.
    func testMismatchedChannelLengthsRealign() {
        var acc = AudioWindowAccumulator(windowSize: 4)
        let out = acc.append(left: [1, 2, 3, 4, 5, 6], right: [1, 2, 3])
        XCTAssertEqual(out.count, 0, "정렬 후 3 개뿐이라 창을 못 채운다")
        XCTAssertEqual(acc.pendingCount, 3)
        XCTAssertEqual(acc.append(left: [7], right: [7]).count, 1)
    }

    /// reset 은 잔여를 버린다(원본 무음/실패 경로의 카운터 리셋 대응).
    func testResetDiscardsPartialWindow() {
        var acc = AudioWindowAccumulator(windowSize: 4)
        _ = acc.append(left: [1, 2, 3], right: [1, 2, 3])
        acc.reset()
        XCTAssertEqual(acc.pendingCount, 0)
        XCTAssertTrue(acc.append(left: [4, 5, 6], right: [4, 5, 6]).isEmpty)
    }

    /// 창 크기 0/음수는 1 로 올린다 — `removeFirst(0)` 무한 루프 방지.
    func testDegenerateWindowSize() {
        var acc = AudioWindowAccumulator(windowSize: 0)
        XCTAssertEqual(acc.windowSize, 1)
        XCTAssertEqual(acc.append(left: [1, 2], right: [1, 2]).count, 2)
    }

    // MARK: 무음 게이트 (0x1400d1a36 · 0x1400d1a95 · 0x1400d1ad6)

    /// 피크는 **채널 0 만**, 부호 있는 max, 0 바닥. 절댓값이 아니다.
    func testWindowPeakIsChannelZeroOnlySignedMaxWithZeroFloor() {
        XCTAssertEqual(AudioCaptureGate.windowPeak([-0.9, 0.3]), 0.3)
        XCTAssertEqual(AudioCaptureGate.windowPeak([-0.9, -0.4]), 0, "부호 있는 max 라 음수는 0 바닥")
        XCTAssertEqual(AudioCaptureGate.windowPeak([]), 0)
        XCTAssertEqual(AudioCaptureGate.windowPeak([0.2, .nan, 0.5]), 0.5, "비유한은 무시")
        XCTAssertEqual(AudioCaptureGate.windowPeak([.infinity]), 0, "Inf 도 무시 — 게이트가 열리면 안 된다")
    }

    /// 활성 조건은 `threshold > FLT_EPSILON`, 경계 `==` 는 통과(엄격 `<`).
    func testGateActivationAndBoundary() {
        XCTAssertFalse(AudioCaptureGate.isSilenced(peak: 0, threshold: 0), "기본 0 = 비활성")
        XCTAssertFalse(AudioCaptureGate.isSilenced(peak: 0, threshold: Float.ulpOfOne))
        XCTAssertTrue(AudioCaptureGate.isSilenced(peak: 0.4, threshold: 0.5))
        XCTAssertFalse(AudioCaptureGate.isSilenced(peak: 0.5, threshold: 0.5))
        XCTAssertFalse(AudioCaptureGate.isSilenced(peak: 0.6, threshold: 0.5))
    }

    /// 폴 규약 상수 — 실물 값을 그대로 기술한다(우리는 푸시 콜백이라 폴링하지 않는다).
    func testPollingConstantsMatchTheEngine() {
        XCTAssertEqual(AudioCaptureGate.pollIntervalMilliseconds, 33)          // 생성자 0x1400c0ccf
        XCTAssertEqual(AudioCaptureGate.idleSilenceTimeoutMilliseconds, 1000)  // 0x1400d14ac
        XCTAssertEqual(AudioCaptureGate.requiredBitsPerSample, 32)             // 0x1400cf5bb
    }
}
