import XCTest
@testable import WapleCore

/// TEX 전체 mip 체인 수집(TexImage.mipChain) 파스 검증: 레벨 수/레벨별 alloc·orig 크기/데이터 오프셋 단언.
/// 실물 근거: DJK_1.tex 클래스(TEXB 가 mip 9개 보유) — 종전은 mip0 만 수집하고 나머지를 스킵했다.
/// 무회귀: mipCount==1·PNG/JPEG/임베디드·다중 image 는 mipChain 이 1개 이하/빈 값(소비처 no-op).
final class TexMipChainParseTests: XCTestCase {

    /// TEXB0003 다중 mip 합성(imageCount=1, imageFormat=-1). levels = (w, h, isLZ4, dec, payload).
    private func makeChainTex(format: Int, texW: Int, texH: Int, imgW: Int, imgH: Int,
                              levels: [(w: Int, h: Int, lz4: Int, dec: Int, payload: [UInt8])],
                              declaredMipCount: Int? = nil) -> Data {
        var b: [UInt8] = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(format) + i32(0) + i32(texW) + i32(texH) + i32(imgW) + i32(imgH)
        b += Array("TEXB0003".utf8) + [0]
        b += i32(1) + i32(-1)                       // imageCount=1, imageFormat=-1(raw)
        b += i32(declaredMipCount ?? levels.count)  // mipCount
        for l in levels {
            b += i32(l.w) + i32(l.h) + i32(l.lz4) + i32(l.dec) + i32(l.payload.count) + l.payload
        }
        return Data(b)
    }

    /// 3레벨 fmt0(비압축): 레벨 수/dims/orig dims/dec/오프셋 전수 단언.
    func testCollectsFullChainWithOffsets() throws {
        let l0 = [UInt8](repeating: 0x11, count: 8 * 8 * 4)
        let l1 = [UInt8](repeating: 0x22, count: 4 * 4 * 4)
        let l2 = [UInt8](repeating: 0x33, count: 2 * 2 * 4)
        let data = makeChainTex(format: 0, texW: 8, texH: 8, imgW: 8, imgH: 8, levels: [
            (8, 8, 0, l0.count, l0), (4, 4, 0, l1.count, l1), (2, 2, 0, l2.count, l2)])
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.payload, .lz4RGBA)
        XCTAssertEqual(tex.imageCount, 1)
        XCTAssertEqual(tex.mipChain.count, 3, "전체 mip 체인 수집")
        XCTAssertEqual(tex.mipChain[0], tex.mip, "체인[0] == mip0(호환)")
        XCTAssertEqual(tex.mips.count, 1)

        // 레벨별 alloc(decode)/orig(image) dims — fmt0 은 alloc==orig.
        XCTAssertEqual([tex.mipChain[0].decodeWidth, tex.mipChain[0].decodeHeight], [8, 8])
        XCTAssertEqual([tex.mipChain[1].decodeWidth, tex.mipChain[1].decodeHeight], [4, 4])
        XCTAssertEqual([tex.mipChain[2].decodeWidth, tex.mipChain[2].decodeHeight], [2, 2])
        XCTAssertEqual([tex.mipChain[0].imageWidth, tex.mipChain[0].imageHeight], [8, 8])
        XCTAssertEqual([tex.mipChain[1].imageWidth, tex.mipChain[1].imageHeight], [4, 4])
        XCTAssertEqual([tex.mipChain[2].imageWidth, tex.mipChain[2].imageHeight], [2, 2])
        XCTAssertEqual(tex.mipChain.map { $0.decompressedSize }, [256, 64, 16])
        XCTAssertFalse(tex.mipChain[0].lz4)

        // 데이터 오프셋: 헤더 42 + TEXB0003\0 9 + imageCount/imageFormat/mipCount 12 = 63 에서 레코드 연속.
        // 레코드 헤더 20B(w,h,isLZ4,dec,comp) + payload.
        XCTAssertEqual(tex.mipChain[0].payloadRange, 83..<339)
        XCTAssertEqual(tex.mipChain[1].payloadRange, 359..<423)
        XCTAssertEqual(tex.mipChain[2].payloadRange, 443..<459)
        XCTAssertEqual(tex.mipChain[2].payloadRange.upperBound, data.count, "마지막 레벨이 EOF 에 닿음")
    }

    /// orig dims 축소 규약: 레벨 L 의 image dims = max(1, imgW/imgH >> L) — 홀수/비2의제곱 포함.
    func testPerLevelImageDimsFloorHalving() throws {
        // alloc 8×8, orig 7×7 → L1 orig 3×3, L2 orig 1×1.
        let l0 = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let l1 = [UInt8](repeating: 0, count: 4 * 4 * 4)
        let l2 = [UInt8](repeating: 0, count: 2 * 2 * 4)
        let data = makeChainTex(format: 0, texW: 8, texH: 8, imgW: 7, imgH: 7, levels: [
            (8, 8, 0, l0.count, l0), (4, 4, 0, l1.count, l1), (2, 2, 0, l2.count, l2)])
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.mipChain.count, 3)
        XCTAssertEqual([tex.mipChain[0].imageWidth, tex.mipChain[0].imageHeight], [7, 7], "mip0 orig = 헤더")
        XCTAssertEqual([tex.mipChain[1].imageWidth, tex.mipChain[1].imageHeight], [3, 3], "7>>1 = 3")
        XCTAssertEqual([tex.mipChain[2].imageWidth, tex.mipChain[2].imageHeight], [1, 1], "7>>2 = 1")
        // alloc dims 는 파일 기록 그대로.
        XCTAssertEqual([tex.mipChain[1].decodeWidth, tex.mipChain[1].decodeHeight], [4, 4])
    }

    /// mipCount==1 무회귀: 체인은 [mip0] 1개(소비처는 count>1 에서만 발동).
    func testSingleMipChainIsJustMip0() throws {
        let l0 = [UInt8](repeating: 7, count: 8 * 8 * 4)
        let data = makeChainTex(format: 0, texW: 8, texH: 8, imgW: 8, imgH: 8, levels: [(8, 8, 0, l0.count, l0)])
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.mipChain.count, 1)
        XCTAssertEqual(tex.mipChain[0], tex.mip)
    }

    /// 다중 image(아틀라스 페이지): 페이지 스택 경로가 레이아웃을 바꾸므로 mipChain=[] — 페이지별 mip0 수집과
    /// 다음 image 오프셋 전진은 종전과 동일(각 image 의 나머지 레벨은 건너뛴다).
    func testMultiImageLeavesChainEmpty() throws {
        func rec(_ w: Int, _ h: Int, _ v: UInt8) -> [UInt8] {
            i32(w) + i32(h) + i32(0) + i32(w * h * 4) + i32(w * h * 4) + [UInt8](repeating: v, count: w * h * 4)
        }
        var b: [UInt8] = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(0) + i32(0) + i32(4) + i32(4) + i32(4) + i32(4)
        b += Array("TEXB0003".utf8) + [0]
        b += i32(2) + i32(-1)                       // imageCount=2, imageFormat=-1
        b += i32(2) + rec(4, 4, 0x10) + rec(2, 2, 0x11)   // image0: mipCount=2
        b += i32(2) + rec(4, 4, 0x20) + rec(2, 2, 0x21)   // image1: mipCount=2
        let data = Data(b)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.imageCount, 2)
        XCTAssertEqual(tex.mips.count, 2, "페이지별 mip0 수집(종전 동작)")
        XCTAssertTrue(tex.mipChain.isEmpty, "다중 image 는 체인 미수집(무회귀)")
        // image1 의 mip0 오프셋: 42+9+8(imgCount+fmt) +4(mipCount) + (20+64)+(20+16) +4(mipCount) +20 = 207.
        XCTAssertEqual(tex.mips[1].payloadRange, 207..<271, "체인 레벨을 건너뛴 전진 오프셋(종전과 동일)")
    }

    /// 선언 mipCount 보다 레코드가 모자라면(절단) 체인 폐기 — 파스 자체는 mip0 로 성공(종전 동작 그대로).
    func testTruncatedChainDiscardsCollection() throws {
        let l0 = [UInt8](repeating: 0x11, count: 8 * 8 * 4)
        let l1 = [UInt8](repeating: 0x22, count: 4 * 4 * 4)
        let data = makeChainTex(format: 0, texW: 8, texH: 8, imgW: 8, imgH: 8,
                                levels: [(8, 8, 0, l0.count, l0), (4, 4, 0, l1.count, l1)],
                                declaredMipCount: 3)   // 3 선언, 2개만 존재
        let tex = try XCTUnwrap(TexImage.parse(data), "절단돼도 mip0 파스는 성공(무회귀)")
        XCTAssertEqual(tex.mip?.decodeWidth, 8)
        XCTAssertTrue(tex.mipChain.isEmpty, "불완전 체인은 폐기 → 단일 레벨 경로")
    }

    /// PNG/JPEG/임베디드 페이로드는 단일 인코딩 이미지 — 저장 mip 자체가 없으므로 mipChain=[] (무회귀).
    func testEncodedPayloadsHaveNoChain() throws {
        // fast-path .png(컨테이너 파스 실패 → 시그니처 라우팅).
        var pngB: [UInt8] = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        pngB += i32(0) + i32(0) + i32(4) + i32(4) + i32(4) + i32(4)
        pngB += [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]
        let pngTex = try XCTUnwrap(TexImage.parse(Data(pngB)))
        XCTAssertEqual(pngTex.payload, .png)
        XCTAssertTrue(pngTex.mipChain.isEmpty)

        // imageFormat=13(PNG) 임베디드(컨테이너 파스 성공, 인코딩 파일 라우팅).
        let payload: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 9, 9]
        var embB: [UInt8] = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        embB += i32(0) + i32(0) + i32(4) + i32(4) + i32(4) + i32(4)
        embB += Array("TEXB0003".utf8) + [0] + i32(1) + i32(13) + i32(1)   // imageCount, imageFormat=PNG, mipCount
        embB += i32(4) + i32(4) + i32(0) + i32(payload.count) + i32(payload.count) + payload
        let embTex = try XCTUnwrap(TexImage.parse(Data(embB)))
        XCTAssertEqual(embTex.payload, .embeddedImage)
        XCTAssertTrue(embTex.mipChain.isEmpty, "임베디드 인코딩 이미지는 체인 없음")
    }

    /// TEXB0001(v1 — isLZ4/dec 필드 부재, w|h|comp|payload) 다중 mip 도 체인 수집.
    func testTEXB0001Chain() throws {
        var b: [UInt8] = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(4) + i32(0) + i32(8) + i32(8) + i32(8) + i32(8)      // fmt4(BC3)
        b += Array("TEXB0001".utf8) + [0]
        b += i32(1)                                                  // imageCount
        b += i32(2)                                                  // mipCount=2
        b += i32(8) + i32(8) + i32(64) + [UInt8](repeating: 0x5A, count: 64)   // L0: w,h,comp,payload
        b += i32(4) + i32(4) + i32(16) + [UInt8](repeating: 0x6B, count: 16)   // L1
        let tex = try XCTUnwrap(TexImage.parse(Data(b)))
        XCTAssertEqual(tex.payload, .bc3)
        XCTAssertEqual(tex.mipChain.count, 2)
        XCTAssertEqual([tex.mipChain[1].decodeWidth, tex.mipChain[1].decodeHeight], [4, 4])
        XCTAssertEqual(tex.mipChain[1].decompressedSize, 16, "v1 은 dec=comp")
        XCTAssertFalse(tex.mipChain[1].lz4)
    }
}
