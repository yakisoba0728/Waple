import XCTest
@testable import WapleRender

final class VorbisFloor0Tests: XCTestCase {
    func testEvenOrderFloor0DecodesToIndependentAnalyticalPCM() throws {
        try assertReference(Floor0OggFixture.order2, Floor0OggFixture.reference2)
    }

    func testOddOrderFloor0DecodesToIndependentAnalyticalPCM() throws {
        try assertReference(Floor0OggFixture.order3, Floor0OggFixture.reference3)
    }

    func testFloor0AfterFloor1UsesItsOwnConfiguration() throws {
        try assertReference(Floor0OggFixture.mixedFloorIndex, Floor0OggFixture.reference2)
    }

    func testZeroAmplitudeAndWideAmplitudeFieldsRemainSafe() throws {
        for data in [Floor0OggFixture.zeroAmplitude, Floor0OggFixture.wideZeroAmplitude] {
            let audio = try OggVorbisDecoder.decode(data)
            XCTAssertEqual(audio.frameCount, 128)
            XCTAssertTrue(audio.samples.allSatisfy { $0 == 0 })
        }
        let wide = try OggVorbisDecoder.decode(Floor0OggFixture.widePositiveAmplitude)
        XCTAssertEqual(wide.frameCount, 128)
        XCTAssertTrue(wide.samples.allSatisfy(\.isFinite))
        XCTAssertTrue(wide.samples.contains { abs($0) > 1e-4 })
    }

    func testFloor0RejectsInvalidOrderAndScalarOnlyBook() {
        for data in [Floor0OggFixture.invalidOrder, Floor0OggFixture.nonVQBook] {
            XCTAssertThrowsError(try OggVorbisDecoder.decode(data)) { error in
                guard case VorbisError.corrupt = error else { return XCTFail("expected invalid floor0 setup, got \(error)") }
            }
        }
    }

    private func assertReference(_ data: Data, _ reference: [Float], file: StaticString = #filePath, line: UInt = #line) throws {
        for fast in [true, false] {
            let decoded = try OggVorbisDecoder.decode(data, useFastIMDCT: fast)
            XCTAssertEqual(decoded.channels, 1, file: file, line: line)
            XCTAssertEqual(decoded.sampleRate, 8000, file: file, line: line)
            XCTAssertEqual(decoded.samples.count, reference.count, file: file, line: line)
            for (actual, expected) in zip(decoded.samples, reference) {
                XCTAssertEqual(actual, expected, accuracy: 1e-6, file: file, line: line)
            }
            XCTAssertTrue(decoded.samples.contains { abs($0) > 1e-4 }, file: file, line: line)
        }
    }
}
