import XCTest
@testable import WapleCore

final class TexImageTests: XCTestCase {
    /// TEX 헤더 + 임의 페이로드로 합성 .tex 생성.
    static func makeTex(format: Int, w: Int, h: Int, payload: [UInt8]) -> Data {
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

    /// LZ4 페이로드에 우연히 낀 0xFFD8FF 가 .jpeg 로 오라우팅되면 안 된다(실측 assets sharp_halo.tex 클래스:
    /// TEXB0004, imageFormat=-1, isLZ4=1, fmt0 — 압축 바이트가 512B 스캔 윈도우에서 JPEG 시그니처 흉내).
    /// 컨테이너 파스 성공 + imageFormat=-1 → format 기반(.lz4RGBA)이 정답.
    func testLZ4PayloadWithFakeJPEGSignatureIsNotEmbeddedJPEG() {
        let lz4ish: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x11, count: 16)  // 압축 스트림 흉내
        var b: [UInt8] = Array("TEXV0005".utf8)+[0]+Array("TEXI0001".utf8)+[0]
        b += i32(0)+i32(0)+i32(8)+i32(8)+i32(8)+i32(8)                    // format=0
        b += Array("TEXB0004".utf8)+[0]+i32(1)+i32(-1)+i32(0)+i32(1)      // imageCount, imageFormat=-1, v4, mipCount
        b += i32(8)+i32(8)+i32(1)+i32(256)+i32(lz4ish.count)+lz4ish       // w,h,isLZ4=1,dec=8*8*4,comp,payload
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.payload, .lz4RGBA, "imageFormat=-1 raw 컨테이너는 시그니처 스캔을 타면 안 됨")
        XCTAssertEqual(t?.mip?.lz4, true)
    }
    func testRejectsNonTex() {
        XCTAssertNil(TexImage.parse(Data("nope".utf8)))
    }

    /// TEXB0003 비디오 텍스처(실측 2958411739/materials/Untitled.tex 클래스): imageFormat=-1 이지만
    /// flags bit5(IsVideoTexture) 세트 + payload 가 raw mp4(ftyp). format 기반 디코드(.lz4RGBA)로
    /// 떨어지면 크기 불일치로 실패한다 — 플래그 직독으로 .video 라우팅이 정답.
    func testVideoFlagWithRawContainerRoutesToVideo() {
        let mp4ish: [UInt8] = [0,0,0,0x20] + Array("ftypisom".utf8) + Array(repeating: 0, count: 8)
        var b: [UInt8] = Array("TEXV0005".utf8)+[0]+Array("TEXI0001".utf8)+[0]
        b += i32(0)+i32(0x22)+i32(8)+i32(8)+i32(8)+i32(8)                 // format=0, flags=ClampUV|IsVideoTexture
        b += Array("TEXB0003".utf8)+[0]+i32(1)+i32(-1)+i32(1)             // imageCount, imageFormat=-1, mipCount
        b += i32(8)+i32(8)+i32(0)+i32(0)+i32(mp4ish.count)+mp4ish         // w,h,isLZ4=0,dec=0,comp,payload
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.payload, .video)
        XCTAssertEqual(t?.isVideoTexture, true)
    }

    /// flags@22(RePKG TexFlags): bit0 NoInterp, bit1 ClampUV, bit2 IsGif, bit5 IsVideoTexture.
    func testParsesFlags() {
        // flags = 0x25 = bit0(NoInterp) | bit2(Gif) | bit5(Video)
        var b: [UInt8] = Array("TEXV0005".utf8)+[0]+Array("TEXI0001".utf8)+[0]
        b += i32(0) + i32(0x25) + i32(4) + i32(4) + i32(4) + i32(4)
        b += Array("TEXB0001".utf8)+[0] + [0,0,0,0]
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.flags, 0x25)
        XCTAssertEqual(t?.noInterpolation, true)
        XCTAssertEqual(t?.clampUVs, false)         // bit1 미설정
        XCTAssertEqual(t?.isGif, true)
        XCTAssertEqual(t?.isVideoTexture, true)
    }

    /// 다중 mip(TEXB0004, 실측 DJK_1.tex mip 9개 클래스): mip0 payload 는 EOF 가 아니라
    /// compressedSize 만큼 — 종전 EOF-스캔 휴리스틱은 이 클래스에서 nil(흰색 폴백)이었다.
    func testParsesMultiMipTEXB0004() {
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

    /// 조건 변형 단일(실측 link_f01/p_tex01 클래스, 코퍼스 sweep 확정 레이아웃):
    /// [imageCount][fmt=-1][v4=변형수 1] | [1][idx=1][0][json NUL] | mipCount | mip.
    func testParsesTEXB0004WithConditionJSONBeforeMipTable() {
        let payload: [UInt8] = Array(repeating: 0x44, count: 20)
        let condition = #"{"condition":{"condition":"3","name":"tuniccolor"}}"#
        var b: [UInt8] = []
        b += Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(4) + i32(0) + i32(8) + i32(8) + i32(8) + i32(8)
        b += Array("TEXB0004".utf8) + [0]
        b += i32(1) + i32(-1) + i32(1)                             // imageCount, fmt, v4(변형수 1)
        b += i32(1) + i32(1) + i32(0) + Array(condition.utf8) + [0]  // 변형 블록: [1][idx][0][json]
        b += i32(1)                                                // mipCount
        b += i32(8) + i32(8) + i32(1) + i32(64) + i32(payload.count) + payload
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.payload, .bc3)
        XCTAssertEqual(t?.mip?.decompressedSize, 64)
        XCTAssertEqual(t?.mip?.payloadRange.count, payload.count)
        XCTAssertEqual(t?.mip?.lz4, true)
    }

    /// 조건 변형 다중(실측 childlink_01.tex: v4=3, tuniccolor 1/2/3): 변형 블록 3개 연속 후 mipCount.
    /// 종전 프레이밍(블록 선두 [1] 을 mipCount 로 오독)은 다변형에서 붕괴 → unknown-fmt4 0/8 의 마지막 1페이지.
    func testParsesTEXB0004MultiVariantConditionChain() {
        let payload: [UInt8] = Array(repeating: 0x24, count: 2048)     // 64×32 BC3 = 2048B
        func cond(_ v: Int) -> [UInt8] { Array(#"{"condition":{"condition":"\#(v)","name":"tuniccolor"}}"#.utf8) }
        var b: [UInt8] = []
        b += Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(4) + i32(0) + i32(64) + i32(32) + i32(64) + i32(32)
        b += Array("TEXB0004".utf8) + [0]
        b += i32(1) + i32(-1) + i32(3)                                 // imageCount, fmt=-1, v4(변형수 3)
        b += i32(1) + i32(1) + i32(0) + cond(2) + [0]                  // 변형1
        b += i32(1) + i32(2) + i32(0) + cond(1) + [0]                  // 변형2
        b += i32(1) + i32(3) + i32(0) + cond(3) + [0]                  // 변형3
        b += i32(1)                                                    // mipCount(변형1의 mip 세트)
        b += i32(64) + i32(32) + i32(0) + i32(0) + i32(payload.count) + payload  // isLZ4=0
        b += Array(repeating: 0xEE, count: 64)                         // 변형2/3 mip 세트 잔재(무시 대상)
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.payload, .bc3, "fmt4 → BC3 (변형 체인 스킵 후 첫 변형 mip 파스)")
        XCTAssertEqual(t?.mip?.decodeWidth, 64)
        XCTAssertEqual(t?.mip?.lz4, false)
        XCTAssertEqual(t?.mip?.decompressedSize, 2048)
        XCTAssertEqual(t?.mip?.payloadRange.count, 2048)
    }

    /// 다중 image = 아틀라스 페이지(RePKG ConvertToGif): 각 image 의 mip0 을 순차 수집.
    /// imageCount=2, 각 1 mip → mips.count==2, 페이지별 payloadRange 가 서로 다름.
    func testParsesMultiImagePages() {
        let page0: [UInt8] = [10, 20, 30, 40]
        let page1: [UInt8] = [200, 150, 100, 50]
        var b: [UInt8] = Array("TEXV0005".utf8)+[0]+Array("TEXI0001".utf8)+[0]
        b += i32(0) + i32(0) + i32(1) + i32(1) + i32(1) + i32(1)      // fmt0, 1x1
        b += Array("TEXB0003".utf8)+[0] + i32(2) + i32(-1)           // imageCount=2, imageFormat=-1
        b += i32(1) + i32(1) + i32(1) + i32(0) + i32(4) + i32(4) + page0   // image0: mipCount1, w,h,isLZ4=0,dec,comp,payload
        b += i32(1) + i32(1) + i32(1) + i32(0) + i32(4) + i32(4) + page1   // image1
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.payload, .lz4RGBA)
        XCTAssertEqual(t?.imageCount, 2)
        XCTAssertEqual(t?.mips.count, 2)
        XCTAssertNotEqual(t?.mips[0].payloadRange, t?.mips[1].payloadRange, "페이지별 mip0 분리")
        XCTAssertEqual(t?.mip?.payloadRange, t?.mips[0].payloadRange, "mip == 페이지0(호환)")
    }

    /// format=7 은 DXT1(BC1, 4bpp) — 태양계 스카이박스/태양/8k_earth 실측.
    func testParsesFormat7AsBC1() {
        let bc1 = ((8 + 3) / 4) * ((8 + 3) / 4) * 8
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

    func testRejectsNegativeTEXSFrameTime() {
        // F690: frametime==0 은 유효(RePKG 관용 — 별도 회귀 테스트)로 바뀌었고, 음수만 폐기 대상으로 남는다.
        var texs: [UInt8] = Array("TEXS0003".utf8) + [0]
        texs += i32(1) + i32(4) + i32(4)
        texs += i32(0) + f32(-1) + f32(0) + f32(0) + f32(4) + f32(0) + f32(0) + f32(4)
        let t = TexImage.parse(Self.makeTex(format: 0, w: 4, h: 4, payload: [0, 0, 0, 0] + texs))
        XCTAssertEqual(t?.frames, [])
    }
}
