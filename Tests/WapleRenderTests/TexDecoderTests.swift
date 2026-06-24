import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Compression
@testable import WapleRender
import WapleCore

final class TexDecoderTests: XCTestCase {
    private func texHeader(format: Int, w: Int, h: Int) -> [UInt8] {
        func i32(_ v: Int) -> [UInt8] {
            let u = UInt32(truncatingIfNeeded: v)
            return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
        }
        return Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
            + i32(format) + i32(0) + i32(w) + i32(h) + i32(w) + i32(h)
            + Array("TEXB0001".utf8) + [0]
    }

    /// ImageIO로 2x2 PNG 생성(손으로 친 바이트 위험 회피).
    private func png2x2() -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let img = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testDecodesEmbeddedPNG() throws {
        let data = Data(texHeader(format: 0, w: 2, h: 2)) + png2x2()
        let tex = try XCTUnwrap(TexImage.parse(data))
        let out = try XCTUnwrap(TexDecoder.rgba(from: tex, data: data))
        XCTAssertEqual(out.width, 2); XCTAssertEqual(out.height, 2)
        XCTAssertEqual(out.pixels.count, 2 * 2 * 4)
    }

    func testDecodesRawRGBA() throws {
        let raw: [UInt8] = Array(repeating: 0, count: 1 * 1 * 4)  // 1x1
        let data = Data(texHeader(format: 0, w: 1, h: 1)) + Data(raw)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.payload, .rawRGBA8888)
        let out = try XCTUnwrap(TexDecoder.rgba(from: tex, data: data))
        XCTAssertEqual(out.pixels.count, 4)
    }

    func testBC3ReturnsNil() throws {
        let data = Data(texHeader(format: 9, w: 4, h: 4)) + Data(repeating: 0, count: 16)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertNil(TexDecoder.rgba(from: tex, data: data))
    }

    func testDecodesBC3ViaLZ4RoundTrip() throws {
        // 4x4 단색 흰 DXT5 블록(16B)을 LZ4_RAW로 압축해 BC3 .tex 합성 → 디코드.
        var block = [UInt8](repeating: 0, count: 16)
        block[0] = 255; block[1] = 255; block[8] = 0xFF; block[9] = 0xFF; block[10] = 0xFF; block[11] = 0xFF
        let raw = Data(block)
        var comp = [UInt8](repeating: 0, count: 256)
        let n = raw.withUnsafeBytes { srcp in
            comp.withUnsafeMutableBytes { dstp in
                compression_encode_buffer(dstp.bindMemory(to: UInt8.self).baseAddress!, 256,
                                          srcp.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        XCTAssertGreaterThan(n, 0)
        func i32(_ v: Int) -> [UInt8] { let u = UInt32(truncatingIfNeeded: v); return [UInt8(u & 0xff), UInt8((u>>8)&0xff), UInt8((u>>16)&0xff), UInt8((u>>24)&0xff)] }
        var b: [UInt8] = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(9) + i32(0) + i32(4) + i32(4) + i32(4) + i32(4)
        b += Array("TEXB0003".utf8) + [0] + i32(1) + i32(-1) + i32(1) + i32(4) + i32(4) + i32(1) + i32(16) + i32(n)
        b += Array(comp[0..<n])
        let data = Data(b)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.payload, .bc3)
        let out = try XCTUnwrap(TexDecoder.rgba(from: tex, data: data))
        XCTAssertEqual(out.width, 4); XCTAssertEqual(out.height, 4)
        XCTAssertEqual([UInt8](out.pixels)[0], 255)  // white
    }
}
