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

/// DXT1(BC1) — 4바이트 색상 팔레트 + 2비트 인덱스, c0<=c1 이면 인덱스 3 = 투명 검정.
final class DXT1DecoderTests: XCTestCase {
    /// 단색 블록: c0=c1=적색(565), 인덱스 전부 0 → 전 픽셀 불투명 적색... 단 c0==c1 은 3-색 모드.
    func testSolidRedBlockOpaque() throws {
        // c0 > c1 (4-색 모드): c0=적(0xF800), c1=흑(0x0000), 인덱스 전부 0 → 적색.
        var block: [UInt8] = [0x00, 0xF8, 0x00, 0x00] + [0, 0, 0, 0]
        let out = try XCTUnwrap(DXT5Decoder.decodeBC1(Data(block), width: 4, height: 4))
        XCTAssertEqual(out.count, 64)
        XCTAssertEqual(out[0], 255); XCTAssertEqual(out[1], 0); XCTAssertEqual(out[2], 0); XCTAssertEqual(out[3], 255)
        // 3-색 모드(c0 <= c1): 인덱스 3 → 투명 검정.
        block = [0x00, 0x00, 0x00, 0xF8] + [0xFF, 0xFF, 0xFF, 0xFF]  // 모든 인덱스 = 3
        let t = try XCTUnwrap(DXT5Decoder.decodeBC1(Data(block), width: 4, height: 4))
        XCTAssertEqual(t[3], 0, "3-색 모드 인덱스 3 은 투명")
    }

    func testBC1SizeGuard() {
        XCTAssertNil(DXT5Decoder.decodeBC1(Data([0, 0]), width: 4, height: 4))  // 블록 부족
        XCTAssertNil(DXT5Decoder.decodeBC1(Data(count: 8), width: 0, height: 4))
    }
}

/// DXT3(BC2) — 앞 8B 픽셀당 4bit 명시 알파(v*17), 뒤 8B 컬러(항상 4-색).
final class BC2DecoderTests: XCTestCase {
    /// 명시 알파 니블 + 4-색 컬러 보간을 동시 실측. 컬러 팔레트는 BC3(decode)와 동일 공식이므로
    /// RGB 기댓값은 기존 testDecodesInterpolatedColors 와 일치, 여기선 알파 니블 확장이 핵심.
    func testDecodesAlphaNibblesAndColor() throws {
        var block = [UInt8](repeating: 0, count: 16)
        // 알파(8B, 픽셀당 4bit LE): 픽셀0=0(→0), 픽셀1=15(→255), 픽셀2=8(→136), 픽셀3=1(→17).
        block[0] = 0xF0   // 픽셀0=low nibble 0, 픽셀1=high nibble F
        block[1] = 0x18   // 픽셀2=low nibble 8, 픽셀3=high nibble 1
        // 컬러(8B): c0=red 565(0xF800 LE), c1=blue 565(0x001F LE)
        block[8] = 0x00; block[9] = 0xF8
        block[10] = 0x1F; block[11] = 0x00
        block[12] = 0xE4  // color indices: 픽셀0=0,1=1,2=2,3=3
        let out = try XCTUnwrap(DXT5Decoder.decodeBC2(Data(block), width: 4, height: 4))
        XCTAssertEqual(out.count, 4 * 4 * 4)
        let px = [UInt8](out)
        // 픽셀0 = red,   알파 0
        XCTAssertEqual([px[0], px[1], px[2], px[3]], [255, 0, 0, 0])
        // 픽셀1 = blue,  알파 255
        XCTAssertEqual([px[4], px[5], px[6], px[7]], [0, 0, 255, 255])
        // 픽셀2 = lerp1/3, 알파 136(=8*17)
        XCTAssertEqual([px[8], px[9], px[10], px[11]], [170, 0, 85, 136])
        // 픽셀3 = lerp2/3, 알파 17(=1*17)
        XCTAssertEqual([px[12], px[13], px[14], px[15]], [85, 0, 170, 17])
    }

    /// BC2 는 color0<=color1 이어도 항상 4-색 모드(BC1 의 3색+투명 없음). c0=blue<=c1=red 로
    /// 인덱스3 을 찍어, BC1 이라면 투명 검정(0,0,0,0)이 될 자리가 불투명 보간색인지 확인.
    func testAlwaysFourColorWhenC0LessEqualC1() throws {
        var block = [UInt8](repeating: 0xFF, count: 16)  // 알파 전부 255
        block[8] = 0x1F; block[9] = 0x00   // c0 = blue 565 (0x001F)
        block[10] = 0x00; block[11] = 0xF8 // c1 = red 565  (0xF800) → c0 <= c1
        block[12] = 0x03; block[13] = 0; block[14] = 0; block[15] = 0  // 픽셀0 인덱스=3, 나머지 0
        let out = try XCTUnwrap(DXT5Decoder.decodeBC2(Data(block), width: 4, height: 4))
        let px = [UInt8](out)
        // 4-색 palette[3] = lerp2/3 blue→red = (170,0,85), 알파 255(투명 아님 — BC1 이면 0).
        XCTAssertEqual([px[0], px[1], px[2], px[3]], [170, 0, 85, 255])
    }

    func testSizeGuard() {
        XCTAssertNil(DXT5Decoder.decodeBC2(Data([0, 0]), width: 4, height: 4))   // 블록 부족(<16)
        XCTAssertNil(DXT5Decoder.decodeBC2(Data(count: 16), width: 0, height: 4))
    }
}
