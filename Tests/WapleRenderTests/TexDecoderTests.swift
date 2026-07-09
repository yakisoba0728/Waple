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

    /// ImageIO로 PNG 생성(손으로 친 바이트 위험 회피).
    private func png(width: Int = 2, height: Int = 2) -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let img = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testDecodesEmbeddedPNG() throws {
        let data = Data(texHeader(format: 0, w: 2, h: 2)) + png()
        let tex = try XCTUnwrap(TexImage.parse(data))
        let out = try XCTUnwrap(TexDecoder.rgba(from: tex, data: data))
        XCTAssertEqual(out.width, 2); XCTAssertEqual(out.height, 2)
        XCTAssertEqual(out.pixels.count, 2 * 2 * 4)
    }

    func testRejectsOversizedEmbeddedPNGDecode() throws {
        let data = Data(texHeader(format: 0, w: 8193, h: 1)) + png(width: 8193, height: 1)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.payload, .png)
        XCTAssertNil(TexDecoder.rgba(from: tex, data: data))
    }

    /// 이슈2: imageFormat=13(PNG) 이고 mip 이 LZ4 압축된 임베디드 PNG. fast-path 512B 스캔은
    /// 압축된(누출) 시그니처를 오검하므로 imageFormat 라우팅이 우선 → .embeddedImage → LZ4 해제 후 디코드.
    func testDecodesLZ4WrappedEmbeddedPNG() throws {
        let raw = [UInt8](png())                         // 2x2 PNG 파일 바이트
        let cap = raw.count * 2 + 64
        var comp = [UInt8](repeating: 0, count: cap)
        let n = Data(raw).withUnsafeBytes { srcp in
            comp.withUnsafeMutableBytes { dstp in
                compression_encode_buffer(dstp.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          srcp.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        XCTAssertGreaterThan(n, 0)
        var b: [UInt8] = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32bytes(0) + i32bytes(0) + i32bytes(2) + i32bytes(2) + i32bytes(2) + i32bytes(2)  // texFormat 무시됨
        b += Array("TEXB0003".utf8) + [0] + i32bytes(1) + i32bytes(13) + i32bytes(1)            // imageCount, imageFormat=PNG, mipCount
        b += i32bytes(2) + i32bytes(2) + i32bytes(1) + i32bytes(raw.count) + i32bytes(n)        // w,h,isLZ4=1,dec,comp
        b += Array(comp[0..<n])
        let data = Data(b)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.payload, .embeddedImage)      // fast-path .png 오라우팅이 아님
        let out = try XCTUnwrap(TexDecoder.rgba(from: tex, data: data))
        XCTAssertEqual(out.width, 2); XCTAssertEqual(out.height, 2)
        XCTAssertEqual(out.pixels.count, 2 * 2 * 4)
    }

    /// 이슈2 실물 검증: 코퍼스에 v4 임베디드 PNG 서브레이아웃이 둘 있다 — splash_*(표준 mip → imageFormat
    /// 라우팅 .embeddedImage) 와 lut/*(mip 에 여분 int → parseMip 실패 → fast-path .png). 둘 다 정상 디코드
    /// 해야 무회귀(재정렬로 어느 것도 흰 폴백이 되지 않음). 코퍼스 부재 시 skip(Real* 하네스 규약).
    func testDecodesRealEmbeddedImages() throws {
        let base = NSHomeDirectory() + "/Downloads/wallpaper_dev/assets/materials/"
        let splash = base + "particle/water/splash_5.tex"
        guard FileManager.default.fileExists(atPath: splash) else { throw XCTSkip("no corpus: \(splash)") }
        // splash_5: imageFormat 라우팅 → .embeddedImage 로 실물 경로를 직접 검증.
        let sData = try Data(contentsOf: URL(fileURLWithPath: splash))
        let sTex = try XCTUnwrap(TexImage.parse(sData))
        XCTAssertEqual(sTex.payload, .embeddedImage, "표준 v4 임베디드 PNG → imageFormat 라우팅")
        let sOut = try XCTUnwrap(TexDecoder.rgba(from: sTex, data: sData), "splash 디코드 실패(흰 폴백)")
        XCTAssertGreaterThan(sOut.width, 0); XCTAssertEqual(sOut.pixels.count, sOut.width * sOut.height * 4)
        // lut/westernf: 여분-int v4 레이아웃 → parseMip 실패 → fast-path .png. 그래도 디코드 성공(무회귀).
        let lut = base + "lut/lutx32_westernf.tex"
        if FileManager.default.fileExists(atPath: lut) {
            let lData = try Data(contentsOf: URL(fileURLWithPath: lut))
            let lTex = try XCTUnwrap(TexImage.parse(lData))
            let lOut = try XCTUnwrap(TexDecoder.rgba(from: lTex, data: lData), "LUT 디코드 실패(흰 폴백)")
            XCTAssertGreaterThan(lOut.width, 0); XCTAssertEqual(lOut.pixels.count, lOut.width * lOut.height * 4)
        }
    }

    func testDecodesRawRGBA() throws {
        let raw: [UInt8] = Array(repeating: 0, count: 1 * 1 * 4)  // 1x1
        let data = Data(texHeader(format: 0, w: 1, h: 1)) + Data(raw)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.payload, .rawRGBA8888)
        let out = try XCTUnwrap(TexDecoder.rgba(from: tex, data: data))
        XCTAssertEqual(out.pixels.count, 4)
    }

    /// format=9 R8(단일채널) → 그레이스케일 RGBA(v,v,v,255). 실측: 3598808038 opacity 비네트 마스크.
    /// 종전(fmt9→BC3 오분류)엔 전백(全白)으로 디코드돼 마스크가 무효화→전화면 흑화면이었다.
    func testDecodesR8AsGrayscale() throws {
        func i32(_ v: Int) -> [UInt8] {
            let u = UInt32(truncatingIfNeeded: v)
            return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
        }
        let r8: [UInt8] = (0..<64).map { UInt8($0 * 4) }   // 8x8 램프(0,4,8,…,252)
        var b: [UInt8] = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(9) + i32(0) + i32(8) + i32(8) + i32(8) + i32(8)
        b += Array("TEXB0004".utf8) + [0] + i32(1) + i32(-1) + i32(0) + i32(1)
        b += i32(8) + i32(8) + i32(0) + i32(64) + i32(r8.count) + r8   // isLZ4=0(비압축), dec=64
        let data = Data(b)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.payload, .r8)
        let out = try XCTUnwrap(TexDecoder.rgba(from: tex, data: data))
        XCTAssertEqual(out.width, 8); XCTAssertEqual(out.height, 8)
        let px = [UInt8](out.pixels)
        // 픽셀0: 값 0 → (0,0,0,255)
        XCTAssertEqual([px[0], px[1], px[2], px[3]], [0, 0, 0, 255])
        // 픽셀10: 값 40 → (40,40,40,255) — r=g=b, alpha 불투명
        XCTAssertEqual([px[40], px[41], px[42], px[43]], [40, 40, 40, 255])
    }

    /// mip 컨테이너가 없는(TEXB0001 헤더만) 압축 포맷은 .unknown → 디코드 nil(폴백은 호출부가 처리).
    func testMalformedCompressedReturnsNil() throws {
        let data = Data(texHeader(format: 9, w: 4, h: 4)) + Data(repeating: 0, count: 16)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertNil(TexDecoder.rgba(from: tex, data: data))
    }

    private func i32bytes(_ v: Int) -> [UInt8] {
        let u = UInt32(truncatingIfNeeded: v)
        return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
    }

    /// format-0 LZ4 RGBA .tex 합성: decode dims dw×dh, image dims iw×ih, LZ4_RAW 압축 body.
    private func makeLZ4RGBATex(dw: Int, dh: Int, iw: Int, ih: Int, raw: [UInt8]) -> Data {
        let cap = raw.count * 2 + 64
        var comp = [UInt8](repeating: 0, count: cap)
        let n = Data(raw).withUnsafeBytes { srcp in
            comp.withUnsafeMutableBytes { dstp in
                compression_encode_buffer(dstp.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          srcp.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        var b: [UInt8] = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32bytes(0) + i32bytes(0) + i32bytes(dw) + i32bytes(dh) + i32bytes(iw) + i32bytes(ih)
        b += Array("TEXB0003".utf8) + [0] + i32bytes(1) + i32bytes(-1) + i32bytes(1)
            + i32bytes(dw) + i32bytes(dh) + i32bytes(1) + i32bytes(dw * dh * 4) + i32bytes(n)
        b += Array(comp[0..<n])
        return Data(b)
    }

    /// format-0 lz4RGBA 경로를 end-to-end 디코드 + 크롭(padding) 검증.
    func testDecodesLZ4RGBAWithCrop() throws {
        let dw = 4, dh = 4, iw = 3, ih = 2
        var raw = [UInt8](repeating: 0, count: dw * dh * 4)
        raw[0] = 10; raw[1] = 20; raw[2] = 30; raw[3] = 40  // top-left 픽셀
        let data = makeLZ4RGBATex(dw: dw, dh: dh, iw: iw, ih: ih, raw: raw)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.payload, .lz4RGBA)
        let out = try XCTUnwrap(TexDecoder.rgba(from: tex, data: data))
        XCTAssertEqual(out.width, iw); XCTAssertEqual(out.height, ih)
        XCTAssertEqual(out.pixels.count, iw * ih * 4)
        let px = [UInt8](out.pixels)
        XCTAssertEqual([px[0], px[1], px[2], px[3]], [10, 20, 30, 40])  // 패딩 stride 에서 올바로 복사
    }

    /// BC3 페이로드가 손상돼 LZ4 디코드가 decompressedSize 와 다른 길이를 내면 nil.
    func testBC3WithCorruptLZ4ReturnsNil() throws {
        var b: [UInt8] = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32bytes(4) + i32bytes(0) + i32bytes(4) + i32bytes(4) + i32bytes(4) + i32bytes(4)  // format=4=DXT5
        // decompressedSize=16 선언, 압축 body 는 디코드해도 16B 가 되지 않는 가비지.
        let garbage: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11]
        b += Array("TEXB0003".utf8) + [0] + i32bytes(1) + i32bytes(-1) + i32bytes(1)
            + i32bytes(4) + i32bytes(4) + i32bytes(1) + i32bytes(16) + i32bytes(garbage.count)
        b += garbage
        let data = Data(b)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.payload, .bc3)
        XCTAssertNil(TexDecoder.rgba(from: tex, data: data))
    }

    /// fmt6=BC2 → .bc2 매핑 + LZ4 라운드트립 디코드를 end-to-end 검증(코퍼스 없이도 CI 에서 배선 보증).
    func testDecodesBC2ViaLZ4RoundTrip() throws {
        // 4x4 BC2 블록: 픽셀0 알파 니블 8(→136), 컬러 c0=c1=white → 픽셀0=(255,255,255,136).
        var block = [UInt8](repeating: 0, count: 16)
        block[0] = 0x08                                            // 픽셀0 알파 니블 = 8
        block[8] = 0xFF; block[9] = 0xFF; block[10] = 0xFF; block[11] = 0xFF  // c0=c1=white
        let raw = Data(block)
        var comp = [UInt8](repeating: 0, count: 256)
        let n = raw.withUnsafeBytes { srcp in
            comp.withUnsafeMutableBytes { dstp in
                compression_encode_buffer(dstp.bindMemory(to: UInt8.self).baseAddress!, 256,
                                          srcp.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        XCTAssertGreaterThan(n, 0)
        var b: [UInt8] = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32bytes(6) + i32bytes(0) + i32bytes(4) + i32bytes(4) + i32bytes(4) + i32bytes(4)   // format=6=DXT3/BC2
        b += Array("TEXB0003".utf8) + [0] + i32bytes(1) + i32bytes(-1) + i32bytes(1) + i32bytes(4) + i32bytes(4) + i32bytes(1) + i32bytes(16) + i32bytes(n)
        b += Array(comp[0..<n])
        let data = Data(b)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.payload, .bc2)
        let out = try XCTUnwrap(TexDecoder.rgba(from: tex, data: data))
        XCTAssertEqual(out.width, 4); XCTAssertEqual(out.height, 4)
        let px = [UInt8](out.pixels)
        XCTAssertEqual([px[0], px[1], px[2], px[3]], [255, 255, 255, 136])  // white, 명시 알파 136
    }

    /// 실물 태양계 씬(3662790108)의 fmt6 텍스처 sun-1.tex 를 실제로 디코드 — 흰 폴백(nil) 회귀 방지.
    /// 코퍼스 부재 시 skip(Real* 하네스와 동일 규약). 하드 어서션: fmt6→.bc2, 비-nil, 실 이미지 치수,
    /// 픽셀 변이(단색 폴백 아님). 알파 어서션은 실측값에 맞춰 확정(BC2 컬러맵은 대개 불투명).
    func testDecodesRealSunFmt6BC2() throws {
        let pkgPath = NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds/3662790108/scene.pkg"
        guard FileManager.default.fileExists(atPath: pkgPath) else { throw XCTSkip("no corpus: \(pkgPath)") }
        let pkg = try ScenePackage.parse(Data(contentsOf: URL(fileURLWithPath: pkgPath)))
        let texData = try XCTUnwrap(pkg.data(for: "materials/sun-1.tex"), "sun-1.tex 부재")
        let tex = try XCTUnwrap(TexImage.parse(texData))
        XCTAssertEqual(tex.format, 6)
        XCTAssertEqual(tex.payload, .bc2)
        let out = try XCTUnwrap(TexDecoder.rgba(from: tex, data: texData), "fmt6 디코드 실패(흰 폴백)")
        XCTAssertEqual(out.width, 501); XCTAssertEqual(out.height, 489)   // imgW/H 로 크롭
        let px = [UInt8](out.pixels)
        XCTAssertEqual(px.count, 501 * 489 * 4)
        // 실 이미지 변이(단색 폴백이면 전부 동일). RGB 다양성 + 알파 범위 측정.
        var aMin = 255, aMax = 0
        var firstRGB = (px[0], px[1], px[2]); var rgbVaries = false
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Int(px[i + 3]); aMin = min(aMin, a); aMax = max(aMax, a)
            if (px[i], px[i + 1], px[i + 2]) != firstRGB { rgbVaries = true }
        }
        NSLog("%@", "[BC2 sun-1] alpha=[\(aMin)..\(aMax)] rgbVaries=\(rgbVaries)")
        XCTAssertTrue(rgbVaries, "디코드가 단색(폴백류)")
        XCTAssertLessThan(aMin, 255, "불투명 아님 — BC2 명시 알파 존재(실측 alpha=[0..255])")
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
        b += i32(4) + i32(0) + i32(4) + i32(4) + i32(4) + i32(4)   // format=4=DXT5
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
