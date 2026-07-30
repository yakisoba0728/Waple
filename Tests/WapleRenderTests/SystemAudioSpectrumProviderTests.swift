import XCTest
import Foundation
@testable import WapleRender

/// FFT 진폭 계산부(SystemAudioSpectrumProvider.magnitudes) 단위 테스트 — 이전엔 커버리지 0.
/// SCStream 없이 순수 함수만 검증(길이·무음·정현파 피크 위치).
final class SystemAudioSpectrumProviderTests: XCTestCase {
    private let fftSize = 1024

    func testMagnitudesLengthIsHalfFFTSize() {
        let out = SystemAudioSpectrumProvider.magnitudes(from: [Float](repeating: 0, count: fftSize), fftSize: fftSize)
        XCTAssertEqual(out?.count, fftSize / 2)
    }

    func testSilenceYieldsZeroMagnitudes() throws {
        let out = try XCTUnwrap(SystemAudioSpectrumProvider.magnitudes(from: [Float](repeating: 0, count: fftSize), fftSize: fftSize))
        XCTAssertTrue(out.allSatisfy { $0 < 1e-4 })
    }

    func testShortInputIsZeroPaddedNotCrashing() throws {
        // fftSize 보다 짧은 입력은 제로패딩 — 길이만 보장(크래시 없음).
        let out = try XCTUnwrap(SystemAudioSpectrumProvider.magnitudes(from: [1, 2, 3], fftSize: fftSize))
        XCTAssertEqual(out.count, fftSize / 2)
    }

    /// 정확히 k 사이클/윈도우인 정현파는 bin k 에서 최대(무윈도우라 누설 없이 피크는 정확히 k — WE 는 테이퍼 미적용).
    func testSineWavePeaksAtItsBin() throws {
        for k in [16, 64, 128] {
            let samples = (0..<fftSize).map { Float(sin(2.0 * Double.pi * Double(k) * Double($0) / Double(fftSize))) }
            let mags = try XCTUnwrap(SystemAudioSpectrumProvider.magnitudes(from: samples, fftSize: fftSize))
            let argmax = mags.enumerated().max(by: { $0.element < $1.element })!.offset
            XCTAssertEqual(argmax, k, "정현파 \(k)cyc 의 피크 bin 은 \(k) 여야 함(실측 \(argmax))")
        }
    }
}
