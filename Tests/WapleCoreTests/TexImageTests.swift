import XCTest
@testable import WapleCore

final class TexImageTests: XCTestCase {
    /// TEX 헤더 + 임의 페이로드로 합성 .tex 생성.
    static func makeTex(format: Int, w: Int, h: Int, payload: [UInt8]) -> Data {
        func i32(_ v: Int) -> [UInt8] {
            let u = UInt32(truncatingIfNeeded: v)
            return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
        }
        var b: [UInt8] = []
        b += Array("TEXV0005".utf8) + [0]
        b += Array("TEXI0001".utf8) + [0]
        b += i32(format) + i32(0) + i32(w) + i32(h) + i32(w) + i32(h)
        b += Array("TEXB0001".utf8) + [0]
        b += payload
        return Data(b)
    }

    func testDetectsPNG() {
        let t = TexImage.parse(Self.makeTex(format: 0, w: 4, h: 4, payload: [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
        XCTAssertEqual(t?.payload, .png)
        XCTAssertEqual(t?.width, 4); XCTAssertEqual(t?.height, 4)
    }
    func testDetectsJPEG() {
        XCTAssertEqual(TexImage.parse(Self.makeTex(format: 0, w: 2, h: 2, payload: [0xFF, 0xD8, 0xFF, 0xE0]))?.payload, .jpeg)
    }
    func testDetectsVideo() {
        // mp4 box: [size 4][ftyp][...]
        let p: [UInt8] = [0,0,0,0x18] + Array("ftypisom".utf8)
        XCTAssertEqual(TexImage.parse(Self.makeTex(format: 0, w: 8, h: 8, payload: p))?.payload, .video)
    }
    func testDetectsBC3ByFormatEnum() {
        XCTAssertEqual(TexImage.parse(Self.makeTex(format: 9, w: 8, h: 8, payload: [0,0,0,0]))?.payload, .bc3)
    }
    func testDefaultsToRawRGBA() {
        XCTAssertEqual(TexImage.parse(Self.makeTex(format: 0, w: 2, h: 2, payload: [0,0,0,0]))?.payload, .rawRGBA8888)
    }
    func testRejectsNonTex() {
        XCTAssertNil(TexImage.parse(Data("nope".utf8)))
    }
}
