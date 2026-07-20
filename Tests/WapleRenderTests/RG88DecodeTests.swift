import XCTest
@testable import WapleCore
@testable import WapleRender

/// WE fmt8(RG88) 디코드: 실물 규약 .rrrg (r=루마, g=알파 — common_fragment.h ConvertTexture0Format).
/// rain_drops_sheet 류가 이 포맷 — 종전 미디코드로 흰 1×1 폴백(비 화면의 흰 사각형 원인).
final class RG88DecodeTests: XCTestCase {
    private func container(format: Int, w: Int, h: Int, payload: [UInt8]) -> Data {
        var b = [UInt8]()
        b.append(contentsOf: Array("TEXV0005".utf8)); b.append(0)
        b.append(contentsOf: Array("TEXI0001".utf8)); b.append(0)
        b.append(contentsOf: i32(format))       // 18: format
        b.append(contentsOf: i32(0))            // 22
        b.append(contentsOf: i32(w)); b.append(contentsOf: i32(h))   // 26/30: texW/H
        b.append(contentsOf: i32(w)); b.append(contentsOf: i32(h))   // 34/38: imgW/H
        b.append(contentsOf: Array("TEXB0003".utf8)); b.append(0)
        b.append(contentsOf: i32(1))            // imageCount
        b.append(contentsOf: i32(-1))           // imageFormat (v3)
        b.append(contentsOf: i32(1))            // mipCount
        b.append(contentsOf: i32(w)); b.append(contentsOf: i32(h))
        b.append(contentsOf: i32(0))            // isLZ4
        b.append(contentsOf: i32(payload.count))    // decompressedSize
        b.append(contentsOf: i32(payload.count))    // compressed size
        b.append(contentsOf: payload)
        return Data(b)
    }

    func testRG88_decodesLumaAlpha() throws {
        let data = container(format: 8, w: 2, h: 1, payload: [255, 0, 128, 255])
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.payload, .rg88)
        let dec = try XCTUnwrap(TexDecoder.rgba(from: tex, data: data))
        XCTAssertEqual(dec.width, 2); XCTAssertEqual(dec.height, 1)
        XCTAssertEqual([UInt8](dec.pixels), [255, 255, 255, 0, 128, 128, 128, 255])
    }
}
