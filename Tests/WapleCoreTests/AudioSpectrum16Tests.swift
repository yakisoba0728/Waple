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
}
