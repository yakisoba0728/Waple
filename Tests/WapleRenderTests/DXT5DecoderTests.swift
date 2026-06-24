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

    /// 4-color 팔레트 보간(palette[2]/palette[3])을 실측. color0=red 565, color1=blue 565.
    /// 기댓값은 디코더의 정수 lerp((x*(3-t)+y*t)/3)로 산출.
    func testDecodesInterpolatedColors() throws {
        var block = [UInt8](repeating: 0, count: 16)
        block[0] = 255; block[1] = 255          // alpha a0=a1=255 → 알파 255
        block[8] = 0x00; block[9] = 0xF8        // color0 = red 565 (0xF800, LE)
        block[10] = 0x1F; block[11] = 0x00      // color1 = blue 565 (0x001F, LE)
        // color indices(4B): 픽셀0=0, 픽셀1=1, 픽셀2=2, 픽셀3=3 → 0xE4
        block[12] = 0xE4
        let out = try XCTUnwrap(DXT5Decoder.decode(Data(block), width: 4, height: 4))
        let px = [UInt8](out)
        // 픽셀0 = palette[0] = red
        XCTAssertEqual([px[0], px[1], px[2]], [255, 0, 0])
        // 픽셀1 = palette[1] = blue
        XCTAssertEqual([px[4], px[5], px[6]], [0, 0, 255])
        // 픽셀2 = palette[2] = lerp 1/3 = (170, 0, 85)
        XCTAssertEqual([px[8], px[9], px[10]], [170, 0, 85])
        // 픽셀3 = palette[3] = lerp 2/3 = (85, 0, 170)
        XCTAssertEqual([px[12], px[13], px[14]], [85, 0, 170])
    }

    /// 8-value 알파 램프(a0>a1)를 실측. a0=255, a1=0 → alpha[i] = ((7-i)*255 + i*0)/7.
    func testDecodesEightValueAlphaRamp() throws {
        var block = [UInt8](repeating: 0, count: 16)
        block[0] = 255; block[1] = 0            // a0>a1 → 8-value 램프
        // alpha indices(6B): 픽셀0..5 = ai 2,3,4,5,6,7
        block[2] = 26; block[3] = 235; block[4] = 3
        block[8] = 0xFF; block[9] = 0xFF        // color0 = white
        block[10] = 0xFF; block[11] = 0xFF      // color1 = white (color index 0 → 흰색)
        let out = try XCTUnwrap(DXT5Decoder.decode(Data(block), width: 4, height: 4))
        let px = [UInt8](out)
        // alpha[2..7] = 218,182,145,109,72,36 (정수 나눗셈)
        XCTAssertEqual([px[3], px[7], px[11], px[15], px[19], px[23]], [218, 182, 145, 109, 72, 36])
        // 색은 모두 흰색
        XCTAssertEqual([px[0], px[1], px[2]], [255, 255, 255])
    }
}
