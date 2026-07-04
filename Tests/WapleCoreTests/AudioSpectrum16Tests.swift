import XCTest
@testable import WapleCore

final class AudioSpectrum16Tests: XCTestCase {
    func testSilent() {
        XCTAssertEqual(AudioSpectrum16.silent.left.count, 16)
        XCTAssertTrue(AudioSpectrum16.silent.left.allSatisfy { $0 == 0 })
    }

    func testDownsample128to16AveragesGroupsOf8() {
        // 128 빈, 값 = index → 각 16빈은 연속 8개 평균.
        let spec = (0..<128).map { Float($0) }
        let out = AudioSpectrum16.downsample16(spec)
        XCTAssertEqual(out.count, 16)
        XCTAssertEqual(out[0], 3.5, accuracy: 1e-4)    // mean(0..7)
        XCTAssertEqual(out[15], 123.5, accuracy: 1e-4) // mean(120..127)
    }

    func testDownsampleEmpty() {
        XCTAssertEqual(AudioSpectrum16.downsample16([]).count, 16)
    }

    func testDownsampleShorterThan16() {
        let out = AudioSpectrum16.downsample16([1, 1, 1, 1])
        XCTAssertEqual(out.count, 16)
        XCTAssertTrue(out.allSatisfy { $0 == 1 })  // 모든 빈이 같은 값으로 매핑
    }

    /// downsample16 은 공용 프리미티브 AudioSpectrum.bin(_, 16) 로 위임 — 전 입력에서 비트 동일해야 한다.
    func testDownsample16DelegatesToBin() {
        let cases: [[Float]] = [[], [1, 1, 1, 1], (0..<128).map { Float($0) },
                                (1...5).map { Float($0) }, (0..<200).map { Float($0 % 7) }]
        for spec in cases {
            XCTAssertEqual(AudioSpectrum16.downsample16(spec), AudioSpectrum.bin(spec, binCount: 16))
        }
    }

    func testBinEdgeCases() {
        XCTAssertTrue(AudioSpectrum.bin([1, 2, 3], binCount: 0).isEmpty)        // binCount<=0 → []
        XCTAssertEqual(AudioSpectrum.bin([], binCount: 8), [Float](repeating: 0, count: 8))  // 빈 입력 → 0
        XCTAssertEqual(AudioSpectrum.bin([2, 4, 6, 8], binCount: 2), [3, 7])   // 그룹 평균, 정규화 없음
    }
}
