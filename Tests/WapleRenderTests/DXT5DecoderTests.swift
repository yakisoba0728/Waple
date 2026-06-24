import XCTest
@testable import WapleRender

final class DXT5DecoderTests: XCTestCase {
    /// 4x4 단색 블록: alpha=255, color0=color1=white → 전부 흰색 불투명.
    func testDecodesSolidWhiteBlock() {
        var block = [UInt8](repeating: 0, count: 16)
        block[0] = 255; block[1] = 255            // alpha endpoints a0=a1=255 → 모든 알파 255
        // alpha indices(6B)=0 → index0 → a0=255
        block[8] = 0xFF; block[9] = 0xFF          // color0 = 565 white
        block[10] = 0xFF; block[11] = 0xFF        // color1 = 565 white
        // color indices(4B)=0 → color0
        let out = DXT5Decoder.decode(Data(block), width: 4, height: 4)
        XCTAssertEqual(out?.count, 4 * 4 * 4)
        let px = [UInt8](out!)
        XCTAssertEqual(px[0], 255); XCTAssertEqual(px[1], 255); XCTAssertEqual(px[2], 255); XCTAssertEqual(px[3], 255)
    }

    func testWrongSizeReturnsNil() {
        XCTAssertNil(DXT5Decoder.decode(Data([0, 1, 2]), width: 4, height: 4))
    }
}
