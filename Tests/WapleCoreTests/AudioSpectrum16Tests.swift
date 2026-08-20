import XCTest
@testable import WapleCore

final class AudioSpectrum16Tests: XCTestCase {
    func testSilent() {
        XCTAssertEqual(AudioSpectrum16.silent.left.count, 16)
        XCTAssertTrue(AudioSpectrum16.silent.left.allSatisfy { $0 == 0 })
    }

    /// **정정(2026-08-20): 평균이 아니라 MAX 다.**
    /// 원본은 64 → 32 → 16 을 인접 2개씩 `maxss` 로 두 번 접는다(`0x1401128e0`, `0x140112b6f`).
    /// 종전 이 테스트는 평균을 계약으로 걸고 있었다 — 순음 저역에서 최대 4배가 갈리는 자리다.
    func testDownsample128to16TakesGroupMax() {
        // 128 빈, 값 = index → 각 16빈은 연속 8개 중 최댓값.
        let spec = (0..<128).map { Float($0) }
        let out = AudioSpectrum16.downsample16(spec)
        XCTAssertEqual(out.count, 16)
        XCTAssertEqual(out[0], 7, accuracy: 1e-4)      // max(0..7)   — 평균이었다면 3.5
        XCTAssertEqual(out[15], 127, accuracy: 1e-4)   // max(120..127) — 평균이었다면 123.5
    }

    func testDownsampleEmpty() {
        XCTAssertEqual(AudioSpectrum16.downsample16([]).count, 16)
    }

    func testDownsampleShorterThan16() {
        let out = AudioSpectrum16.downsample16([1, 1, 1, 1])
        XCTAssertEqual(out.count, 16)
        XCTAssertTrue(out.allSatisfy { $0 == 1 })  // 모든 빈이 같은 값으로 매핑
    }

    /// `downsample16` 은 `groupMax(_, 16)` 이다 — 인덱스 산술은 `AudioSpectrum.bin` 과 같고 축약만 다르다.
    /// 두 함수가 **같은 그룹 경계**를 쓰는지 전 입력에서 확인한다(경계가 갈리면 밴드가 통째로 밀린다).
    func testDownsample16IsGroupMaxWithBinIndexArithmetic() {
        let cases: [[Float]] = [[], [1, 1, 1, 1], (0..<128).map { Float($0) },
                                (1...5).map { Float($0) }, (0..<200).map { Float($0 % 7) }]
        for spec in cases {
            XCTAssertEqual(AudioSpectrum16.downsample16(spec), AudioSpectrum16.groupMax(spec, binCount: 16))
            // 그룹 경계 동일성: 상수 입력이면 max 와 mean 이 같아야 한다.
            let flat = [Float](repeating: 2, count: spec.count)
            XCTAssertEqual(AudioSpectrum16.groupMax(flat, binCount: 16),
                           AudioSpectrum.bin(flat, binCount: 16),
                           "상수 입력에서 max 와 mean 이 다르면 그룹 경계가 갈린 것이다")
        }
        // max ≥ mean 이 전 입력에서 성립해야 한다.
        for spec in cases where !spec.isEmpty {
            let mx = AudioSpectrum16.groupMax(spec, binCount: 16)
            let mn = AudioSpectrum.bin(spec, binCount: 16)
            for i in 0..<16 { XCTAssertGreaterThanOrEqual(mx[i], mn[i]) }
        }
    }

    func testBinEdgeCases() {
        XCTAssertTrue(AudioSpectrum.bin([1, 2, 3], binCount: 0).isEmpty)        // binCount<=0 → []
        XCTAssertEqual(AudioSpectrum.bin([], binCount: 8), [Float](repeating: 0, count: 8))  // 빈 입력 → 0
        XCTAssertEqual(AudioSpectrum.bin([2, 4, 6, 8], binCount: 2), [3, 7])   // 그룹 평균, 정규화 없음
    }
}
