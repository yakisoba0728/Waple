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

    func testNormalizedToMaxOne() {
        let mags = (1...256).map { Float($0) }
        let out = AudioSpectrum.spectrum(fromMagnitudes: mags, binCount: 64)
        XCTAssertEqual(out.max() ?? 0, 1.0, accuracy: 1e-5)
        XCTAssertTrue(out.allSatisfy { $0 >= 0 && $0 <= 1.0001 })
    }
}
