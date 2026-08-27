import XCTest
@testable import WapleCore

/// `bin/playliststatetime.bin` 코덱의 계약 잠금.
///
/// **실측 파일 하나가 근거의 전부다**(95바이트, `docs/re/playlist-transition.md` §7).
/// 그래서 그 파일의 바이트를 여기 그대로 세우고 양방향으로 맞춘다 — 우리 인코더가 만든
/// 바이트가 WE 가 쓴 바이트와 **같아야** 한다. 산수로도 닫힌다:
/// `4+8 + 4 + 4 + 4 + (4+15) + 4 + 3*(4+8+4) = 95`.
final class PlaylistStateTimeTests: XCTestCase {

    /// 실측 파일 그대로. 타임스탬프 `0x6A8302BA` = 1786970810, 값 `0x4969FC40` = 958404.0f.
    private var measuredFile: Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func str(_ s: String) { u32(UInt32(clamping: s.utf8.count)); data.append(contentsOf: Array(s.utf8)) }
        str("PLPV0005")
        u32(1_786_970_810)
        u32(0)
        u32(1)
        str("wallpaperconfig")
        u32(3)
        str("Monitor0"); u32(0x0000_0000)
        str("Monitor1"); u32(0x4969_FC40)
        str("Monitor2"); u32(0x4969_FC40)
        return data
    }

    func testMeasuredFileIsNinetyFiveBytes() {
        XCTAssertEqual(measuredFile.count, 95, "실측 파일 크기 — 레이아웃이 산술로 닫힌다")
    }

    func testDecodesTheMeasuredFile() throws {
        let contents = try XCTUnwrap(PlaylistStateTimeFile.decode(measuredFile))
        XCTAssertEqual(contents.timestamp, 1_786_970_810)
        XCTAssertEqual(contents.sections.count, 1)
        XCTAssertEqual(contents.sections[0].key, PlaylistStateTimeFile.defaultSection)
        XCTAssertEqual(contents.sections[0].values,
                       [.init(name: "Monitor0", seconds: 0),
                        .init(name: "Monitor1", seconds: 958_404),
                        .init(name: "Monitor2", seconds: 958_404)])
    }

    /// **우리가 쓰는 바이트가 WE 가 쓴 바이트와 같다.** 디코드만 맞으면 "읽을 줄만 아는"
    /// 상태라 다음 라운드에 설치본과 주고받을 때 조용히 갈린다.
    func testEncodesByteIdenticalToTheMeasuredFile() {
        let rebuilt = PlaylistStateTimeFile.encode(
            elapsedByName: ["Monitor0": 0, "Monitor1": 958_404, "Monitor2": 958_404],
            timestamp: 1_786_970_810)
        XCTAssertEqual(rebuilt, measuredFile)
    }

    func testRoundTripPreservesOrderAndValues() throws {
        let original = PlaylistStateTimeFile.Contents(
            timestamp: 42,
            sections: [.init(key: "wallpaperconfig",
                             values: [.init(name: "display-1", seconds: 0.5),
                                      .init(name: "display-2", seconds: 12_345.75)])])
        let back = try XCTUnwrap(PlaylistStateTimeFile.decode(PlaylistStateTimeFile.encode(original)))
        XCTAssertEqual(back, original)
        XCTAssertEqual(back.elapsedByName, ["display-1": 0.5, "display-2": 12_345.75])
    }

    /// 같은 상태가 **같은 바이트**여야 한다. `Dictionary` 순회 순서는 실행마다 다르므로
    /// 정렬하지 않으면 내용이 그대로인데도 파일이 매번 달라진다.
    func testEncodingIsDeterministicForTheSameMap() {
        let map: [String: Float] = ["z": 1, "a": 2, "m": 3]
        let first = PlaylistStateTimeFile.encode(elapsedByName: map, timestamp: 7)
        for _ in 0..<20 {
            XCTAssertEqual(PlaylistStateTimeFile.encode(elapsedByName: map, timestamp: 7), first)
        }
    }

    // MARK: - 파일은 신뢰 경계 밖이다

    func testRejectsUnknownMagic() {
        var bytes = Array(measuredFile)
        bytes[4] = UInt8(ascii: "X")
        XCTAssertNil(PlaylistStateTimeFile.decode(Data(bytes)),
                     "모르는 버전은 관용 파스하지 않는다 — 잘못 읽느니 처음부터 세는 게 낫다")
    }

    func testRejectsTruncationAtEveryLength() {
        let full = measuredFile
        for cut in 0..<full.count {
            XCTAssertNil(PlaylistStateTimeFile.decode(full.prefix(cut)),
                         "\(cut)바이트에서 잘린 파일이 통과했다")
        }
        XCTAssertNotNil(PlaylistStateTimeFile.decode(full))
    }

    func testRejectsAbsurdLengthFieldInsteadOfAllocating() {
        var bytes = Array(measuredFile)
        // "wallpaperconfig" 의 길이 필드(오프셋 24 — 4 매직길이 + 8 매직 + 4 시각 + 4 예약 + 4 섹션수)
        // 를 0xFFFFFFFF 로 바꾼다.
        bytes[24] = 0xFF; bytes[25] = 0xFF; bytes[26] = 0xFF; bytes[27] = 0xFF
        XCTAssertNil(PlaylistStateTimeFile.decode(Data(bytes)))
    }

    func testRejectsAbsurdEntryCountInsteadOfReservingHugeCapacity() {
        var bytes = Array(measuredFile)
        // 섹션 수(오프셋 20)를 0x7FFFFFFF 로 바꾼다 — 남은 바이트 상한에 걸려야 한다.
        bytes[20] = 0xFF; bytes[21] = 0xFF; bytes[22] = 0xFF; bytes[23] = 0x7F
        XCTAssertNil(PlaylistStateTimeFile.decode(Data(bytes)))
    }

    func testEmptyDataIsRejected() {
        XCTAssertNil(PlaylistStateTimeFile.decode(Data()))
    }

    /// `Data` 슬라이스는 `startIndex` 가 0 이 아니다 — 정수 첨자를 그대로 쓰면 조용히 어긋난다.
    func testDecodesFromANonZeroBasedSlice() throws {
        var padded = Data([0xAA, 0xBB, 0xCC])
        padded.append(measuredFile)
        let slice = padded[3...]
        XCTAssertNotEqual(slice.startIndex, 0)
        let contents = try XCTUnwrap(PlaylistStateTimeFile.decode(slice))
        XCTAssertEqual(contents.timestamp, 1_786_970_810)
    }
}
