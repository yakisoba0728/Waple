import XCTest
import Compression
@testable import WapleRender
import WapleCore

/// TexDecoder 레벨별 디코드(rgbaLevels / nativeBC.levels) 검증: raw/LZ4/BC 각 포맷 + alloc/orig 크롭 규약의
/// 레벨별 적용(alloc/orig 둘 다 레벨마다 1/2 축소, 최소 1 — TexImage.mipChain 파스 규약과 정합).
/// 무회귀: 자격 외(mipCount==1/다중 image/keepFullAtlas/비-mip 페이로드)는 nil 또는 levels.count==1.
final class TexMipChainDecodeTests: XCTestCase {

    /// TEXB0003 다중 mip 합성(imageCount=1, imageFormat=-1). levels = (w, h, isLZ4, dec, payload).
    private func makeChainTex(format: Int, texW: Int, texH: Int, imgW: Int, imgH: Int,
                              levels: [(w: Int, h: Int, lz4: Int, dec: Int, payload: [UInt8])]) -> Data {
        var b = Data("TEXV0005".utf8) + Data([0]) + Data("TEXI0001".utf8) + Data([0])
        b += i32(format) + i32(0) + i32(texW) + i32(texH) + i32(imgW) + i32(imgH)
        b += Data("TEXB0003".utf8) + Data([0]) + i32(1) + i32(-1) + i32(levels.count)
        for l in levels {
            b += i32(l.w) + i32(l.h) + i32(l.lz4) + i32(l.dec) + i32(l.payload.count) + Data(l.payload)
        }
        return b
    }

    private func solidRGBA(_ w: Int, _ h: Int, _ px: (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(w * h * 4)
        for _ in 0..<(w * h) { out.append(contentsOf: [px.0, px.1, px.2, px.3]) }
        return out
    }

    /// LZ4_RAW 압축(TexDecoderTests 와 동일 패턴). 실패 시 nil.
    private func lz4Encode(_ raw: [UInt8]) -> [UInt8]? {
        let cap = raw.count * 2 + 64
        var comp = [UInt8](repeating: 0, count: cap)
        let n = Data(raw).withUnsafeBytes { srcp in
            comp.withUnsafeMutableBytes { dstp in
                compression_encode_buffer(dstp.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          srcp.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                                          nil, COMPRESSION_LZ4_RAW)
            }
        }
        return n > 0 ? Array(comp[0..<n]) : nil
    }

    /// 단색 BC3 블록(엔드포인트 동일 → 보간 없음; NativeBCUploadTests.bc3Solid565 와 동일 구조).
    private func bc3Solid(_ c: UInt16, alpha: UInt8 = 255) -> [UInt8] {
        [alpha, alpha, 0, 0, 0, 0, 0, 0, UInt8(c & 0xff), UInt8(c >> 8), UInt8(c & 0xff), UInt8(c >> 8), 0, 0, 0, 0]
    }

    // MARK: raw(fmt0, 비압축) — 레벨별 디코드 + 크롭

    /// alloc 8×8/orig 6×6 의 3레벨: 크롭 규약이 레벨마다 적용돼 (6,6)/(3,3)/(1,1).
    func testRawLevelsDecodeWithPerLevelCrop() throws {
        let l0 = solidRGBA(8, 8, (255, 0, 0, 255))
        let l1 = solidRGBA(4, 4, (0, 255, 0, 255))
        let l2 = solidRGBA(2, 2, (0, 0, 255, 255))
        let data = makeChainTex(format: 0, texW: 8, texH: 8, imgW: 6, imgH: 6, levels: [
            (8, 8, 0, l0.count, l0), (4, 4, 0, l1.count, l1), (2, 2, 0, l2.count, l2)])
        let tex = try XCTUnwrap(TexImage.parse(data))
        let levels = try XCTUnwrap(TexDecoder.rgbaLevels(from: tex, data: data), "체인 디코드")
        XCTAssertEqual(levels.count, 3)
        XCTAssertEqual([levels[0].width, levels[0].height], [6, 6], "L0: orig 6×6 크롭")
        XCTAssertEqual([levels[1].width, levels[1].height], [3, 3], "L1: orig 6>>1=3")
        XCTAssertEqual([levels[2].width, levels[2].height], [1, 1], "L2: orig 6>>2=1")
        XCTAssertEqual([UInt8](levels[0].pixels.prefix(4)), [255, 0, 0, 255])
        XCTAssertEqual([UInt8](levels[1].pixels.prefix(4)), [0, 255, 0, 255])
        XCTAssertEqual([UInt8](levels[2].pixels.prefix(4)), [0, 0, 255, 255])
        // 파리티: levels[0] == 기존 단일 디코드(rgba()).
        let single = try XCTUnwrap(TexDecoder.rgba(from: tex, data: data))
        XCTAssertEqual(levels[0].pixels, single.pixels, "levels[0] == rgba() (비트동일)")
        XCTAssertEqual([levels[0].width, levels[0].height], [single.width, single.height])
    }

    /// LZ4 압축 레벨 페이로드도 해제 후 동일하게 디코드된다.
    /// (dims 32/16/8 — LZ4_RAW 는 소형 입력에서 0 을 반환해 소형 픽스처 부적합, NativeBCUploadTests 주석 동일).
    func testLZ4LevelsRoundtrip() throws {
        let raws = [solidRGBA(32, 32, (200, 10, 10, 255)), solidRGBA(16, 16, (10, 200, 10, 255)),
                    solidRGBA(8, 8, (10, 10, 200, 255))]
        var levels: [(w: Int, h: Int, lz4: Int, dec: Int, payload: [UInt8])] = []
        for (i, raw) in raws.enumerated() {
            let comp = try XCTUnwrap(lz4Encode(raw), "L\(i) LZ4 인코드")
            let dim = 32 >> i
            levels.append((dim, dim, 1, raw.count, comp))
        }
        let data = makeChainTex(format: 0, texW: 32, texH: 32, imgW: 32, imgH: 32, levels: levels)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertTrue(tex.mipChain.allSatisfy { $0.lz4 })
        let out = try XCTUnwrap(TexDecoder.rgbaLevels(from: tex, data: data))
        XCTAssertEqual(out.count, 3)
        for (i, lv) in out.enumerated() {
            XCTAssertEqual([UInt8](lv.pixels), raws[i], "L\(i) LZ4 해제 내용 일치")
        }
    }

    // MARK: BC(fmt4=BC3) — 레벨별 디코드 + 크롭 + 네이티브 후보

    /// BC3 3레벨(alloc==orig 8/4/2): 레벨별 단색 블록 디코드.
    func testBC3LevelsDecode() throws {
        // 8×8=4블록, 4×4=1블록, 2×2=1블록(ceil(2/4)=1).
        let l0 = bc3Solid(0xF800) + bc3Solid(0xF800) + bc3Solid(0xF800) + bc3Solid(0xF800)   // red
        let l1 = bc3Solid(0x07E0)                                                            // green
        let l2 = bc3Solid(0x001F)                                                            // blue
        let data = makeChainTex(format: 4, texW: 8, texH: 8, imgW: 8, imgH: 8, levels: [
            (8, 8, 0, l0.count, l0), (4, 4, 0, l1.count, l1), (2, 2, 0, l2.count, l2)])
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.payload, .bc3)
        let levels = try XCTUnwrap(TexDecoder.rgbaLevels(from: tex, data: data))
        XCTAssertEqual(levels.count, 3)
        XCTAssertEqual([levels[0].width, levels[0].height], [8, 8])
        XCTAssertEqual([levels[1].width, levels[1].height], [4, 4])
        XCTAssertEqual([levels[2].width, levels[2].height], [2, 2])
        // 단색 블록 → 디코드 정확(보간 없음).
        XCTAssertEqual([UInt8](levels[0].pixels.prefix(4)), [255, 0, 0, 255])
        XCTAssertEqual([UInt8](levels[1].pixels.prefix(4)), [0, 255, 0, 255])
        XCTAssertEqual([UInt8](levels[2].pixels.prefix(4)), [0, 0, 255, 255])
    }

    /// BC3 크롭 규약 레벨별 적용: alloc 8×8/orig 6×6 → (6,6)/(3,3), 네이티브 후보 dims/stride 도 동일 규약.
    func testBC3CropPerLevelAndNativeCandidate() throws {
        let l0 = [UInt8](repeating: 0, count: 4 * 16)      // 8×8 → 2×2 블록
        let l1 = [UInt8](repeating: 0, count: 16)          // 4×4 → 1 블록
        let data = makeChainTex(format: 4, texW: 8, texH: 8, imgW: 6, imgH: 6, levels: [
            (8, 8, 0, l0.count, l0), (4, 4, 0, l1.count, l1)])
        let tex = try XCTUnwrap(TexImage.parse(data))
        let levels = try XCTUnwrap(TexDecoder.rgbaLevels(from: tex, data: data))
        XCTAssertEqual(levels.count, 2)
        XCTAssertEqual([levels[0].width, levels[0].height], [6, 6], "L0: orig 크롭")
        XCTAssertEqual([levels[1].width, levels[1].height], [3, 3], "L1: orig 6>>1=3 크롭")

        let bc = try XCTUnwrap(TexDecoder.nativeBC(from: tex, data: data))
        XCTAssertEqual(bc.levels.count, 2, "네이티브 후보도 전체 체인")
        XCTAssertEqual([bc.levels[0].width, bc.levels[0].height], [6, 6])
        XCTAssertEqual(bc.levels[0].bytesPerRow, 2 * 16, "L0 stride = decode 블록 폭(2블록)")
        XCTAssertEqual([bc.levels[1].width, bc.levels[1].height], [3, 3])
        XCTAssertEqual(bc.levels[1].bytesPerRow, 1 * 16, "L1 stride = decode 블록 폭(1블록)")
        XCTAssertEqual([bc.width, bc.height], [bc.levels[0].width, bc.levels[0].height], "플랫 필드 == levels[0]")
    }

    /// 네이티브 후보 레벨 블록 내용: LZ4 해제된 원본 BC 바이트 그대로(레벨별 payloadRange 분리).
    func testNativeBCLevelBlocksAreDistinctPayloads() throws {
        let l0 = bc3Solid(0xF800) + bc3Solid(0xF800) + bc3Solid(0xF800) + bc3Solid(0xF800)
        let l1 = bc3Solid(0x07E0)
        let data = makeChainTex(format: 4, texW: 8, texH: 8, imgW: 8, imgH: 8, levels: [
            (8, 8, 0, l0.count, l0), (4, 4, 0, l1.count, l1)])
        let tex = try XCTUnwrap(TexImage.parse(data))
        let bc = try XCTUnwrap(TexDecoder.nativeBC(from: tex, data: data))
        XCTAssertEqual(bc.levels.count, 2)
        XCTAssertEqual([UInt8](bc.levels[0].blocks), l0, "L0 블록 = L0 페이로드")
        XCTAssertEqual([UInt8](bc.levels[1].blocks), l1, "L1 블록 = L1 페이로드(레벨 오정렬 아님)")
    }

    // MARK: 무회귀 가드

    /// mipCount==1: rgbaLevels=nil(기존 단일 경로), nativeBC.levels=[mip0] 1개.
    func testSingleMipEligibilityUnchanged() throws {
        let l0 = bc3Solid(0xF800)
        let data = makeChainTex(format: 4, texW: 4, texH: 4, imgW: 4, imgH: 4, levels: [(4, 4, 0, l0.count, l0)])
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.mipChain.count, 1)
        XCTAssertNil(TexDecoder.rgbaLevels(from: tex, data: data), "단일 mip 은 신규 경로 미발동")
        let bc = try XCTUnwrap(TexDecoder.nativeBC(from: tex, data: data))
        XCTAssertEqual(bc.levels.count, 1)
    }

    /// keepFullAtlas(스프라이트 아틀라스)/다중 image/비-mip 페이로드는 신규 경로 미발동(기존 동작 무회귀).
    func testEligibilityGuards() throws {
        let l0 = solidRGBA(8, 8, (255, 0, 0, 255))
        let l1 = solidRGBA(4, 4, (0, 255, 0, 255))
        let data = makeChainTex(format: 0, texW: 8, texH: 8, imgW: 8, imgH: 8, levels: [
            (8, 8, 0, l0.count, l0), (4, 4, 0, l1.count, l1)])
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertNil(TexDecoder.rgbaLevels(from: tex, data: data, keepFullAtlas: true),
                     "keepFullAtlas 는 기존 full-atlas 단일 경로")

        // 다중 image: mips.count==2, mipChain==[] → nil(TexMipChainParseTests.testMultiImageLeavesChainEmpty 대응).
        func rec(_ w: Int, _ h: Int, _ v: UInt8) -> Data {
            i32(w) + i32(h) + i32(0) + i32(w * h * 4) + i32(w * h * 4) + Data([UInt8](repeating: v, count: w * h * 4))
        }
        var b = Data("TEXV0005".utf8) + Data([0]) + Data("TEXI0001".utf8) + Data([0])
        b += i32(0) + i32(0) + i32(4) + i32(4) + i32(4) + i32(4)
        b += Data("TEXB0003".utf8) + Data([0]) + i32(2) + i32(-1)
        b += i32(2) + rec(4, 4, 0x10) + rec(2, 2, 0x11)
        b += i32(2) + rec(4, 4, 0x20) + rec(2, 2, 0x21)
        let multiTex = try XCTUnwrap(TexImage.parse(b))
        XCTAssertNil(TexDecoder.rgbaLevels(from: multiTex, data: b), "다중 image 는 페이지 스택 경로")
        XCTAssertNil(TexDecoder.nativeBC(from: multiTex, data: b), "멀티페이지 네이티브 제외(기존)")

        // PNG 페이로드: 체인 부재 → nil.
        var pngB = Data("TEXV0005".utf8) + Data([0]) + Data("TEXI0001".utf8) + Data([0])
        pngB += i32(0) + i32(0) + i32(4) + i32(4) + i32(4) + i32(4)
        pngB += Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let pngTex = try XCTUnwrap(TexImage.parse(pngB))
        XCTAssertNil(TexDecoder.rgbaLevels(from: pngTex, data: pngB))
    }
}
