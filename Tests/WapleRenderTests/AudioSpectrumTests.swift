import XCTest
@testable import WapleRender

final class AudioSpectrumTests: XCTestCase {
    func testEmptyInputYieldsZeroFilledBins() {
        let out = AudioSpectrum.spectrum(fromMagnitudes: [], binCount: 128)
        XCTAssertEqual(out.count, 128)
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }

    func testZeroBinCountYieldsEmpty() {
        XCTAssertTrue(AudioSpectrum.spectrum(fromMagnitudes: [1, 2, 3], binCount: 0).isEmpty)
    }

    func testOutputLengthMatchesBinCount() {
        let mags = (0..<256).map { Float($0) }
        XCTAssertEqual(AudioSpectrum.spectrum(fromMagnitudes: mags, binCount: 128).count, 128)
    }

    // 구 testNormalizedToMaxOne 대체(계약 반전): /max 정규화 제거 → raw×gain.
    // (1) 스케일 선형: 입력 k배 → 출력 k배. (2) 채널 독립(#17): 채널별 호출이 L/R 레벨비를 보존.
    func testScaleLinearAndChannelIndependent() {
        let base = (1...256).map { Float($0) }
        let a = AudioSpectrum.spectrum(fromMagnitudes: base, binCount: 64)
        let a2 = AudioSpectrum.spectrum(fromMagnitudes: base.map { $0 * 2 }, binCount: 64)
        for i in a.indices { XCTAssertEqual(a2[i], a[i] * 2, accuracy: 1e-3, "스케일 선형") }
        // /max 였다면 loud·quiet 둘 다 max=1 로 소거됐을 것 — raw×gain 은 레벨비를 살린다.
        let quiet = AudioSpectrum.spectrum(fromMagnitudes: base.map { $0 * 0.25 }, binCount: 64)
        XCTAssertEqual((quiet.max() ?? 0) / max(1e-9, a.max() ?? 0), 0.25, accuracy: 1e-3, "채널 레벨비 보존(#17)")
        XCTAssertTrue(a.allSatisfy { $0 >= 0 }, "진폭 비음수")
    }

    // t=6 정적 캡처(무음) 동일성: 무음(비영 길이 0배열)은 구(/max: max=0→정규화 스킵)·신(×gain: 0×g)
    // 둘 다 영벡터 → 코퍼스 A/B 비트동일.
    func testSilentInputYieldsZeros() {
        let out = AudioSpectrum.spectrum(fromMagnitudes: [Float](repeating: 0, count: 512), binCount: 64)
        XCTAssertEqual(out.count, 64)
        XCTAssertTrue(out.allSatisfy { $0 == 0 }, "무음 입력 → 영벡터(구/신 동일)")
    }
}
