import XCTest
@testable import WapleCore

/// `Sources/WapleCore/BinaryReading.swift` 직접 테스트.
///
/// 이 파일은 `Model3D`·`PuppetModel`·`TexImage` 세 바이너리 파서가 공유하는 **경계검사 리더**인데
/// 테스트 참조가 **0건**이었다. 파서 테스트를 통해 간접적으로만 밟혔고, 그 경로는 정상 입력만
/// 지나간다 — 정작 이 함수의 존재 이유인 **경계**는 아무도 확인하지 않았다.
///
/// 여기서 잡으려는 것은 손상·악성 패키지다. `.pkg` 안의 오프셋은 파일이 시키는 값이므로
/// 버퍼 밖을 가리킬 수 있고, 그때 nil 을 주지 못하면 파서가 통째로 죽는다.
final class BinaryReadingTests: XCTestCase {

    // MARK: - readU32LE

    func testReadU32LEDecodesLittleEndian() {
        // 0x78563412 — 바이트 순서가 뒤집히면 0x12345678 이 나와 갈린다.
        XCTAssertEqual(readU32LE([0x12, 0x34, 0x56, 0x78], at: 0), 0x7856_3412)
        XCTAssertEqual(readU32LE([0xFF, 0xFF, 0xFF, 0xFF], at: 0), UInt32.max)
        XCTAssertEqual(readU32LE([0x00, 0x00, 0x00, 0x00], at: 0), 0)
        // 최상위 바이트가 부호로 새지 않는지 — Int 로 중간계산하면 여기서 갈린다.
        XCTAssertEqual(readU32LE([0x00, 0x00, 0x00, 0x80], at: 0), 0x8000_0000)
    }

    func testReadU32LERespectsOffset() {
        let b: [UInt8] = [0xAA, 0xBB, 0x12, 0x34, 0x56, 0x78]
        XCTAssertEqual(readU32LE(b, at: 2), 0x7856_3412)
    }

    func testReadU32LEBoundaries() {
        let b: [UInt8] = [1, 2, 3, 4]
        XCTAssertNotNil(readU32LE(b, at: 0), "정확히 맞는 4바이트는 읽혀야 한다")
        XCTAssertNil(readU32LE(b, at: 1), "1바이트 모자라면 nil")
        XCTAssertNil(readU32LE(b, at: 4), "버퍼 끝에서 시작하면 nil")
        XCTAssertNil(readU32LE(b, at: 5), "버퍼 밖에서 시작하면 nil")
        XCTAssertNil(readU32LE(b, at: -1), "음수 오프셋은 nil")
        XCTAssertNil(readU32LE([], at: 0), "빈 버퍼는 nil")
    }

    /// 경계검사가 **경계에서 죽지 않는지**.
    ///
    /// 종전 구현은 `at + 4 <= bytes.count` 였다. Swift 의 `+` 는 오버플로에서 감싸지 않고
    /// 트랩하므로 `at` 이 Int.max 근처면 경계검사 함수 자체가 크래시했다 — nil 을 주는 대신
    /// 프로세스를 죽이는 것이라, 이 함수가 하려던 일과 정확히 반대다.
    /// 지금은 `bytes.count - at >= 4` 라 `at >= 0` 선행 검사와 함께 오버플로가 불가능하다.
    func testReadU32LEDoesNotTrapOnExtremeOffsets() {
        let b: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        XCTAssertNil(readU32LE(b, at: Int.max))
        XCTAssertNil(readU32LE(b, at: Int.max - 3))
        XCTAssertNil(readU16LE(b, at: Int.max))
        XCTAssertNil(readU32LE(b, at: Int.min), "Int.min 은 음수 가드에서 걸린다")
    }

    // MARK: - readU16LE

    func testReadU16LEDecodesLittleEndian() {
        XCTAssertEqual(readU16LE([0x34, 0x12], at: 0), 0x1234)
        XCTAssertEqual(readU16LE([0xFF, 0xFF], at: 0), UInt16.max)
        XCTAssertEqual(readU16LE([0x00, 0x80], at: 0), 0x8000)
    }

    func testReadU16LEBoundaries() {
        let b: [UInt8] = [1, 2]
        XCTAssertNotNil(readU16LE(b, at: 0))
        XCTAssertNil(readU16LE(b, at: 1), "1바이트 모자라면 nil")
        XCTAssertNil(readU16LE(b, at: 2))
        XCTAssertNil(readU16LE(b, at: -1))
        XCTAssertNil(readU16LE([], at: 0))
    }

    // MARK: - readCString

    func testReadCStringReadsUntilNulAndReportsNext() throws {
        let b: [UInt8] = Array("abc".utf8) + [0] + Array("xyz".utf8) + [0]
        let first = try XCTUnwrap(readCString(b, at: 0))
        XCTAssertEqual(first.value, "abc")
        XCTAssertEqual(first.next, 4, "next 는 NUL **다음** 오프셋이어야 한다")
        let second = try XCTUnwrap(readCString(b, at: first.next))
        XCTAssertEqual(second.value, "xyz")
        XCTAssertEqual(second.next, 8)
    }

    func testReadCStringHandlesEmptyString() {
        let r = readCString([0, 0x41], at: 0)
        XCTAssertEqual(r?.value, "")
        XCTAssertEqual(r?.next, 1)
    }

    /// **UTF-8 고정의 이유를 고정한다.**
    ///
    /// 실물 머티리얼 경로에 CJK 가 들어온다(`materials/models/太空球/…`). 바이트별
    /// `UnicodeScalar`(Latin-1) 해석으로 되돌아가면 mojibake 가 되어 pkg 엔트리 조회가
    /// 조용히 실패한다 — 크래시도 예외도 없이 그 씬만 텍스처가 빠진다.
    /// 이 테스트가 그 회귀의 유일한 감시자다.
    func testReadCStringDecodesUTF8NotLatin1() {
        let path = "materials/models/太空球/tex.tex"
        let b: [UInt8] = Array(path.utf8) + [0]
        let r = readCString(b, at: 0)
        XCTAssertEqual(r?.value, path)
        XCTAssertEqual(r?.next, b.count)
        // Latin-1 해석이었다면 바이트 수만큼 스칼라가 생겨 문자 수가 부풀어 오른다.
        XCTAssertEqual(r?.value.count, path.count)
        XCTAssertNotEqual(r?.value.count, path.utf8.count, "CJK 가 들어 있으므로 문자 수 < 바이트 수")
    }

    func testReadCStringReturnsNilWhenUnterminated() {
        XCTAssertNil(readCString(Array("abc".utf8), at: 0), "NUL 없이 끝나면 nil")
        XCTAssertNil(readCString([], at: 0))
        XCTAssertNil(readCString([0x41], at: 5), "버퍼 밖 시작은 nil")
        XCTAssertNil(readCString([0x41, 0], at: -1), "음수 오프셋은 nil")
    }

    /// NUL 이 멀티바이트 문자 뒤에 바로 붙어도 경계가 어긋나지 않는지.
    func testReadCStringStopsExactlyAtNulAfterMultibyte() {
        let b: [UInt8] = Array("太".utf8) + [0] + [0xFF, 0xFF]
        let r = readCString(b, at: 0)
        XCTAssertEqual(r?.value, "太")
        XCTAssertEqual(r?.next, 4, "太 는 UTF-8 3바이트 — next 는 4")
    }
}
