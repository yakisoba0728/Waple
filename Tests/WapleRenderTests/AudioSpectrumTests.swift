import XCTest
@testable import WapleCore
@testable import WapleRender

/// 렌더 레인의 스펙트럼 계약. 알고리즘 자체(밴드 매핑·틸트·축약·게인)의 WE 파리티는
/// `WapleCoreTests/AudioSpectrumWEParityTests` 가 본다 — 여기서는 **소비 형식**만 고정한다.
final class AudioSpectrumTests: XCTestCase {

    func testOutputIsAlwaysSixtyFourBands() {
        XCTAssertEqual(AudioSpectrum.spectrum(normalizedMagnitudes: []).count, 64)
        XCTAssertEqual(AudioSpectrum.spectrum(normalizedMagnitudes: (0..<640).map { Float($0) }).count, 64)
        XCTAssertEqual(AudioSpectrum.spectrum(normalizedMagnitudes: (0..<64).map { Float($0) }).count, 64,
                       "빈이 밴드보다 적어도 출력 길이는 64 다(빈 밴드는 0)")
    }

    func testSilentInputYieldsZeros() {
        let out = AudioSpectrum.spectrum(normalizedMagnitudes: [Float](repeating: 0, count: 640))
        XCTAssertTrue(out.allSatisfy { $0 == 0 }, "무음 입력 → 영벡터")
    }

    /// 프로바이더가 쓰는 (FFT 길이, 레이트) 조합에서 소비 빈 수가 진폭 배열 길이(N/2)를
    /// 넘지 않아야 한다 — 넘으면 인덱스가 밖으로 나간다.
    func testBinCountNeverExceedsAvailableMagnitudes() {
        for n in [256, 512, 1024, 2048, 4096] {
            for rate in [44100.0, 48000.0, 96000.0] {
                let b = AudioSpectrum.binCount(fftLength: n, sampleRate: rate)
                XCTAssertLessThanOrEqual(b, n / 2, "N=\(n) rate=\(rate)")
                XCTAssertGreaterThanOrEqual(b, 2)
            }
        }
    }

    /// 창 누적기가 FFT 길이가 아니라 **창 길이**로 잡혀야 제로패딩이 성립한다.
    func testProviderWindowIsTwoThirdsOfFFTLength() {
        XCTAssertEqual(AudioSpectrum.windowLength(fftLength: 2048), 1365)   // 1366 → 1365: 절삭이 몫이 아니라 차에 걸린다(0x1400d149b-0x1400d14a0)
        XCTAssertLessThan(AudioSpectrum.windowLength(fftLength: 2048), 2048,
                          "창이 FFT 길이와 같으면 제로패딩이 0 이다")
    }

    /// 캡처 레이트는 스펙트럼 빈 폭 산출과 **단일 소스**여야 한다 — 갈리면 밴드가 통째로 밀린다.
    func testCaptureSampleRateIsTheOneUsedForBinning() {
        XCTAssertEqual(SystemAudioSpectrumProvider.captureSampleRate, 48000)
        XCTAssertEqual(AudioSpectrum.binCount(fftLength: 2048,
                                              sampleRate: SystemAudioSpectrumProvider.captureSampleRate),
                       627)
    }
}
