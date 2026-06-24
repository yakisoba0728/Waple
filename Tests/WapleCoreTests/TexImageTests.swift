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
    func testDetectsBC3WithValidMip() {
        XCTAssertEqual(TexImage.parse(makeBC3Tex(w: 8, h: 8, payload: Array(0..<40)))?.payload, .bc3)
    }
    func testFormat9WithoutMipIsUnknown() {
        XCTAssertEqual(TexImage.parse(Self.makeTex(format: 9, w: 8, h: 8, payload: [0,0,0,0]))?.payload, .unknown)
    }
    func testDefaultsToRawRGBA() {
        XCTAssertEqual(TexImage.parse(Self.makeTex(format: 0, w: 2, h: 2, payload: [0,0,0,0]))?.payload, .rawRGBA8888)
    }
    func testRejectsNonTex() {
        XCTAssertNil(TexImage.parse(Data("nope".utf8)))
    }

    /// format=9 BC3 .tex: TEX 헤더 + "TEXB0003" + mipCount + 7 ints(decompressedSize 포함) + payload.
    private func makeBC3Tex(w: Int, h: Int, payload: [UInt8]) -> Data {
        func i32(_ v: Int) -> [UInt8] { let u = UInt32(truncatingIfNeeded: v); return [UInt8(u & 0xff), UInt8((u>>8)&0xff), UInt8((u>>16)&0xff), UInt8((u>>24)&0xff)] }
        let dxt5 = ((w + 3) / 4) * ((h + 3) / 4) * 16
        var b: [UInt8] = []
        b += Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(9) + i32(0) + i32(w) + i32(h) + i32(w) + i32(h)   // format=9, dims
        b += Array("TEXB0003".utf8) + [0]
        b += i32(1)                       // mipCount
        b += i32(-1) + i32(1) + i32(w) + i32(h) + i32(1)  // leading ints
        b += i32(dxt5) + i32(payload.count)               // decompressedSize, compressedSize
        b += payload
        return Data(b)
    }

    func testParsesBC3Mip() {
        let payload: [UInt8] = Array(0..<40)
        let t = TexImage.parse(makeBC3Tex(w: 8, h: 8, payload: payload))
        XCTAssertEqual(t?.payload, .bc3)
        let mip = t?.mip
        XCTAssertEqual(mip?.decodeWidth, 8); XCTAssertEqual(mip?.decodeHeight, 8)
        XCTAssertEqual(mip?.decompressedSize, 64)             // (8/4)*(8/4)*16 = 64
        XCTAssertEqual(mip?.payloadRange.count, payload.count)
    }

    /// format=0 LZ4 RGBA(패딩): tex≠img.
    private func makeLZ4RGBATex(texW: Int, texH: Int, imgW: Int, imgH: Int, payload: [UInt8]) -> Data {
        func i32(_ v: Int) -> [UInt8] { let u = UInt32(truncatingIfNeeded: v); return [UInt8(u&0xff),UInt8((u>>8)&0xff),UInt8((u>>16)&0xff),UInt8((u>>24)&0xff)] }
        var b: [UInt8] = Array("TEXV0005".utf8)+[0]+Array("TEXI0001".utf8)+[0]
        b += i32(0)+i32(0)+i32(texW)+i32(texH)+i32(imgW)+i32(imgH)   // format=0
        b += Array("TEXB0003".utf8)+[0]+i32(1)+i32(-1)+i32(1)+i32(texW)+i32(texH)+i32(1)+i32(texW*texH*4)+i32(payload.count)
        b += payload
        return Data(b)
    }
    func testParsesLZ4RGBAWithPadding() {
        let payload: [UInt8] = Array(repeating: 7, count: 20)
        let t = TexImage.parse(makeLZ4RGBATex(texW: 4, texH: 4, imgW: 3, imgH: 2, payload: payload))
        XCTAssertEqual(t?.payload, .lz4RGBA)
        XCTAssertEqual(t?.mip?.decodeWidth, 4)
        XCTAssertEqual(t?.mip?.imageWidth, 3); XCTAssertEqual(t?.mip?.imageHeight, 2)
        XCTAssertEqual(t?.mip?.decompressedSize, 4 * 4 * 4)
        XCTAssertEqual(t?.mip?.payloadRange.count, payload.count)
    }
}
