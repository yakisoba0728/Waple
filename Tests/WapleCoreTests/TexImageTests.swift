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
    /// format=9 는 R8(단일채널 8bit) — 실측 근거 3598808038 opacity 마스크. mip 있는 fmt9 는 .r8.
    func testParsesFormat9AsR8() {
        func i32(_ v: Int) -> [UInt8] { let u = UInt32(truncatingIfNeeded: v); return [UInt8(u&0xff),UInt8((u>>8)&0xff),UInt8((u>>16)&0xff),UInt8((u>>24)&0xff)] }
        let r8: [UInt8] = (0..<64).map { UInt8($0 * 4) }               // 8x8 그레이스케일 램프
        var b: [UInt8] = Array("TEXV0005".utf8)+[0]+Array("TEXI0001".utf8)+[0]
        b += i32(9)+i32(0)+i32(8)+i32(8)+i32(8)+i32(8)                 // format=9
        b += Array("TEXB0004".utf8)+[0]+i32(1)+i32(-1)+i32(0)+i32(1)   // imageCount, fmt, v4, mipCount
        b += i32(8)+i32(8)+i32(0)+i32(64)+i32(r8.count)+r8            // w,h,isLZ4=0,dec=64,comp,payload
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.payload, .r8)
        XCTAssertEqual(t?.mip?.decompressedSize, 64)                   // 8*8*1B
    }
    func testDefaultsToRawRGBA() {
        XCTAssertEqual(TexImage.parse(Self.makeTex(format: 0, w: 2, h: 2, payload: [0,0,0,0]))?.payload, .rawRGBA8888)
    }
    func testRejectsNonTex() {
        XCTAssertNil(TexImage.parse(Data("nope".utf8)))
    }

    /// 다중 mip(TEXB0004, 실측 DJK_1.tex mip 9개 클래스): mip0 payload 는 EOF 가 아니라
    /// compressedSize 만큼 — 종전 EOF-스캔 휴리스틱은 이 클래스에서 nil(흰색 폴백)이었다.
    func testParsesMultiMipTEXB0004() {
        func i32(_ v: Int) -> [UInt8] { let u = UInt32(truncatingIfNeeded: v); return [UInt8(u & 0xff), UInt8((u>>8)&0xff), UInt8((u>>16)&0xff), UInt8((u>>24)&0xff)] }
        let mip0: [UInt8] = Array(repeating: 7, count: 24)
        let mip1: [UInt8] = Array(repeating: 9, count: 12)
        var b: [UInt8] = []
        b += Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(4) + i32(0) + i32(8) + i32(8) + i32(8) + i32(8)      // format=4
        b += Array("TEXB0004".utf8) + [0]
        b += i32(1) + i32(-1) + i32(0)                                // imageCount, imageFormat, v4 필드
        b += i32(2)                                                   // mipCount=2
        b += i32(8) + i32(8) + i32(1) + i32(64) + i32(mip0.count) + mip0  // mip0
        b += i32(4) + i32(4) + i32(1) + i32(16) + i32(mip1.count) + mip1  // mip1
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.payload, .bc3)
        XCTAssertEqual(t?.mip?.decompressedSize, 64)
        XCTAssertEqual(t?.mip?.payloadRange.count, mip0.count, "mip0 만 — EOF 까지 아님")
        XCTAssertEqual(t?.mip?.lz4, true)
    }

    /// format=7 은 DXT1(BC1, 4bpp) — 태양계 스카이박스/태양/8k_earth 실측.
    func testParsesFormat7AsBC1() {
        let bc1 = ((8 + 3) / 4) * ((8 + 3) / 4) * 8
        func i32(_ v: Int) -> [UInt8] { let u = UInt32(truncatingIfNeeded: v); return [UInt8(u & 0xff), UInt8((u>>8)&0xff), UInt8((u>>16)&0xff), UInt8((u>>24)&0xff)] }
        var b: [UInt8] = []
        b += Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(7) + i32(0) + i32(8) + i32(8) + i32(8) + i32(8)
        b += Array("TEXB0004".utf8) + [0]
        b += i32(1) + i32(-1) + i32(0) + i32(1)                    // imageCount, fmt, v4, mipCount
        b += i32(8) + i32(8) + i32(0) + i32(0) + i32(bc1)          // w, h, isLZ4=0(비압축), dec, comp
        b += [UInt8](repeating: 0xAB, count: bc1)
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.payload, .bc1)
        XCTAssertEqual(t?.mip?.lz4, false, "isLZ4=0 비압축(실물 2k_Sun surface map)")
        XCTAssertEqual(t?.mip?.decompressedSize, bc1)
    }

    /// format=4 도 DXT5(BC3) — 3D 모델 텍스처 실측(250/252 가 fmt4, decompressedSize 8bpp 전수 일치).
    func testParsesFormat4AsBC3() {
        let t = TexImage.parse(makeBC3Tex(w: 8, h: 8, payload: Array(0..<40), format: 4))
        XCTAssertEqual(t?.payload, .bc3)
        XCTAssertEqual(t?.mip?.decompressedSize, 64)
    }

    /// BC3 .tex 합성: TEX 헤더 + "TEXB0003" + mipCount + 7 ints(decompressedSize 포함) + payload.
    /// 기본 format=4(정본 DXT5) — fmt9 는 R8(단일채널)이라 별도 테스트.
    private func makeBC3Tex(w: Int, h: Int, payload: [UInt8], format: Int = 4) -> Data {
        func i32(_ v: Int) -> [UInt8] { let u = UInt32(truncatingIfNeeded: v); return [UInt8(u & 0xff), UInt8((u>>8)&0xff), UInt8((u>>16)&0xff), UInt8((u>>24)&0xff)] }
        let dxt5 = ((w + 3) / 4) * ((h + 3) / 4) * 16
        var b: [UInt8] = []
        b += Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(format) + i32(0) + i32(w) + i32(h) + i32(w) + i32(h)
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
