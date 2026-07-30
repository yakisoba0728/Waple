import XCTest
import Metal
@testable import WapleRender
import WapleCore

/// 네이티브 BC(DXT) 업로드 경로 검증: TexDecoder.nativeBC 판정/dims/stride(유닛) + 합성 BC 블록의
/// GPU 네이티브 디코드 vs CPU DXT5Decoder 파리티(보간 팔레트·BC1 punch-through 로 라운딩 차이 실측).
final class NativeBCUploadTests: XCTestCase {
    /// 단일-image BC .tex 합성(format 4=BC3/6=BC2/7=BC1). decode dims dw×dh, image dims iw×ih.
    /// mip 은 비압축 저장(isLZ4=0) — LZ4_RAW 는 소형/비압축 블록에서 0 을 반환하므로 픽스처엔 부적합.
    private func makeBCTex(format: Int, dw: Int, dh: Int, iw: Int, ih: Int, blocks: [UInt8]) -> Data {
        var b = bytes(tag("TEXV0005"), tag("TEXI0001"))
        b += bytes(i32b(format), i32b(0), i32b(dw), i32b(dh), i32b(iw), i32b(ih))
        b += bytes(tag("TEXB0003"), i32b(1), i32b(-1), i32b(1),
                   i32b(dw), i32b(dh), i32b(0), i32b(blocks.count), i32b(blocks.count))   // isLZ4=0, dec, comp
        b += blocks
        return Data(b)
    }

    /// 2-image(멀티페이지) BC3 .tex — nativeBC 가 거부해야(CPU 스택 필요).
    private func makeMultipageBCTex(dw: Int, dh: Int, block: [UInt8]) -> Data {
        var b = bytes(tag("TEXV0005"), tag("TEXI0001"))
        b += bytes(i32b(4), i32b(0), i32b(dw), i32b(dh), i32b(dw), i32b(dh))
        b += bytes(tag("TEXB0003"), i32b(2), i32b(-1))   // imageCount=2
        for _ in 0..<2 {
            b += bytes(i32b(1), i32b(dw), i32b(dh), i32b(0), i32b(block.count), i32b(block.count), block)
        }
        return Data(b)
    }

    /// 단색 BC3 블록(엔드포인트 동일 → 보간 없음): 판정/dims 유닛용.
    private func bc3Solid565(_ c: UInt16, alpha: UInt8 = 255) -> [UInt8] {
        [alpha, alpha, 0, 0, 0, 0, 0, 0, UInt8(c & 0xff), UInt8(c >> 8), UInt8(c & 0xff), UInt8(c >> 8), 0, 0, 0, 0]
    }

    // MARK: 판정/dims/stride (Metal 불필요)

    func testFormatMappingAndBytesPerRow() throws {
        let block16 = bc3Solid565(0xFFFF)
        for (fmt, expect, bpp) in [(4, TexDecoder.BCFormat.bc3, 16), (6, .bc2, 16)] {
            let data = makeBCTex(format: fmt, dw: 4, dh: 4, iw: 4, ih: 4, blocks: block16)
            let tex = try XCTUnwrap(TexImage.parse(data))
            let bc = try XCTUnwrap(TexDecoder.nativeBC(from: tex, data: data), "fmt \(fmt) → 네이티브 후보")
            XCTAssertEqual(bc.format, expect)
            XCTAssertEqual(bc.bytesPerRow, ((4 + 3) / 4) * bpp)   // 1 블록/행 × 16B
        }
        // BC1(8B/블록): decode 8×4 = 2블록/행 × 1행 = 2블록 = 16B.
        let d1 = makeBCTex(format: 7, dw: 8, dh: 4, iw: 8, ih: 4, blocks: [UInt8](repeating: 0, count: 2 * 1 * 8))
        let t1 = try XCTUnwrap(TexImage.parse(d1))
        let bc1 = try XCTUnwrap(TexDecoder.nativeBC(from: t1, data: d1))
        XCTAssertEqual(bc1.format, .bc1)
        XCTAssertEqual(bc1.bytesPerRow, ((8 + 3) / 4) * 8)       // 2 블록/행 × 8B = 16
    }

    func testRejectsNonBC() throws {
        // RGBA(fmt0) raw
        let rgba = Data(bytes(tag("TEXV0005"), tag("TEXI0001"),
                              i32b(0), i32b(0), i32b(1), i32b(1), i32b(1), i32b(1),
                              [0, 0, 0, 0]))
        let tRGBA = try XCTUnwrap(TexImage.parse(rgba))
        XCTAssertNil(TexDecoder.nativeBC(from: tRGBA, data: rgba), "RGBA 는 네이티브 대상 아님")
        // R8(fmt9)
        var r8b = bytes(tag("TEXV0005"), tag("TEXI0001"))
        r8b += bytes(i32b(9), i32b(0), i32b(4), i32b(4), i32b(4), i32b(4))
        r8b += bytes(tag("TEXB0003"), i32b(1), i32b(-1), i32b(1),
                     i32b(4), i32b(4), i32b(0), i32b(16), i32b(16))
        r8b += [UInt8](repeating: 0, count: 16)
        let tR8 = try XCTUnwrap(TexImage.parse(Data(r8b)))
        XCTAssertEqual(tR8.payload, .r8)
        XCTAssertNil(TexDecoder.nativeBC(from: tR8, data: Data(r8b)), "R8 은 네이티브 대상 아님")
    }

    func testRejectsMultipage() throws {
        let data = makeMultipageBCTex(dw: 4, dh: 4, block: bc3Solid565(0xFFFF))
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.imageCount, 2)
        XCTAssertNil(TexDecoder.nativeBC(from: tex, data: data), "멀티페이지는 CPU 스택 필요 → 네이티브 제외")
    }

    func testCropVsNoCropDims() throws {
        // 블록정렬 크롭: decode 8×8, image 4×8. 타깃 dims=image, stride=decode(2블록×16=32).
        let blocks = [UInt8](repeating: 0, count: 2 * 2 * 16)
        let crop = makeBCTex(format: 4, dw: 8, dh: 8, iw: 4, ih: 8, blocks: blocks)
        let tc = try XCTUnwrap(TexImage.parse(crop))
        let bcC = try XCTUnwrap(TexDecoder.nativeBC(from: tc, data: crop))
        XCTAssertEqual([bcC.width, bcC.height], [4, 8], "크롭: image dims")
        XCTAssertEqual(bcC.bytesPerRow, 2 * 16, "stride = decode 블록 폭")
        // 비정렬 크롭: decode 8×8, image 6×5(홀수). 타깃=6×5, stride 여전히 decode.
        let nb = makeBCTex(format: 4, dw: 8, dh: 8, iw: 6, ih: 5, blocks: blocks)
        let tn = try XCTUnwrap(TexImage.parse(nb))
        let bcN = try XCTUnwrap(TexDecoder.nativeBC(from: tn, data: nb))
        XCTAssertEqual([bcN.width, bcN.height], [6, 5], "비정렬 크롭도 image dims")
        XCTAssertEqual(bcN.bytesPerRow, 2 * 16)
        // 무크롭: image==decode.
        let full = makeBCTex(format: 4, dw: 8, dh: 8, iw: 8, ih: 8, blocks: blocks)
        let tf = try XCTUnwrap(TexImage.parse(full))
        let bcF = try XCTUnwrap(TexDecoder.nativeBC(from: tf, data: full))
        XCTAssertEqual([bcF.width, bcF.height], [8, 8], "무크롭: decode dims")
    }

    func testRejectsShortBlocks() throws {
        // dec 선언 64(4×4 BC3=1블록=16... 실제 decode 4×8=2블록=32 필요)인데 블록 1개만 → 부족 nil.
        let oneBlock = bc3Solid565(0xFFFF)          // 16B = 1블록, but decode 4×8 = 2블록 필요
        let data = makeBCTex(format: 4, dw: 4, dh: 8, iw: 4, ih: 8, blocks: oneBlock)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertNil(TexDecoder.nativeBC(from: tex, data: data), "블록 부족 → nil(rgba 폴백)")
    }

    // MARK: GPU 네이티브 vs CPU DXT5Decoder 파리티

    /// bc.blocks 를 bc.format/dims/stride 로 Metal BC 텍스처에 올리고 rgba8 로 렌더백.
    private func renderNativeBC(_ bc: TexDecoder.NativeBCUpload, device: MTLDevice) throws -> [UInt8] {
        let pf: MTLPixelFormat = bc.format == .bc1 ? .bc1_rgba : (bc.format == .bc2 ? .bc2_rgba : .bc3_rgba)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pf, width: bc.width, height: bc.height, mipmapped: false)
        let tex = try XCTUnwrap(device.makeTexture(descriptor: d))
        bc.blocks.withUnsafeBytes { p in
            tex.replace(region: MTLRegionMake2D(0, 0, bc.width, bc.height), mipmapLevel: 0,
                        withBytes: p.baseAddress!, bytesPerRow: bc.bytesPerRow)
        }
        let sh = """
        #include <metal_stdlib>
        using namespace metal;
        struct VO { float4 pos [[position]]; float2 uv; };
        vertex VO v(uint i [[vertex_id]]) {
          float2 p[6] = {{-1,-1},{1,-1},{-1,1},{1,-1},{1,1},{-1,1}};
          float2 u[6] = {{0,1},{1,1},{0,0},{1,1},{1,0},{0,0}};
          VO o; o.pos = float4(p[i],0,1); o.uv = u[i]; return o;
        }
        fragment float4 f(VO i [[stage_in]], texture2d<float> t [[texture(0)]]) {
          constexpr sampler s(filter::nearest, address::clamp_to_edge);
          return t.sample(s, i.uv);
        }
        """
        let lib = try device.makeLibrary(source: sh, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "v")
        pd.fragmentFunction = lib.makeFunction(name: "f")
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipe = try device.makeRenderPipelineState(descriptor: pd)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: bc.width, height: bc.height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        let rt = try XCTUnwrap(device.makeTexture(descriptor: td))
        let q = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(q.makeCommandBuffer())
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = rt
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        let enc = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: rp))
        enc.setRenderPipelineState(pipe); enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: bc.width * bc.height * 4)
        rt.getBytes(&px, bytesPerRow: bc.width * 4, from: MTLRegionMake2D(0, 0, bc.width, bc.height), mipmapLevel: 0)
        return px
    }

    private func diffStats(_ a: [UInt8], _ b: [UInt8]) -> (maxDiff: Int, meanDiff: Double) {
        precondition(a.count == b.count)
        var maxD = 0, sum = 0
        for i in 0..<a.count { let d = abs(Int(a[i]) - Int(b[i])); maxD = max(maxD, d); sum += d }
        return (maxD, Double(sum) / Double(a.count))
    }

    /// BC3 보간 팔레트(4색) + 보간 알파(8단): GPU 하드웨어 디코드가 CPU 정수 보간과 근사하는지 측정.
    func testBC3InterpolatedParity() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsBCTextureCompression else {
            throw XCTSkip("no Metal / no BC")
        }
        // color c0=red565(0xF800) > c1=blue565(0x001F) → 4색 모드, palette[2]/[3] 보간.
        // alpha a0=200 > a1=50 → 8단 보간. 인덱스로 4색·여러 알파 슬롯을 픽셀에 배치.
        var block = [UInt8](repeating: 0, count: 16)
        block[0] = 200; block[1] = 50                       // a0,a1
        // 알파 인덱스 3bit×16 = 48bit(6바이트). 픽셀0=0,1=1,2=2,…순환.
        var abits: UInt64 = 0
        for i in 0..<16 { abits |= UInt64(i % 8) << (3 * i) }
        for i in 0..<6 { block[2 + i] = UInt8((abits >> (8 * i)) & 0xff) }
        block[8] = 0x00; block[9] = 0xF8                    // c0 = 0xF800 (red)
        block[10] = 0x1F; block[11] = 0x00                  // c1 = 0x001F (blue)
        var cbits: UInt32 = 0
        for i in 0..<16 { cbits |= UInt32(i % 4) << (2 * i) } // 색 인덱스 0,1,2,3 순환
        block[12] = UInt8(cbits & 0xff); block[13] = UInt8((cbits >> 8) & 0xff)
        block[14] = UInt8((cbits >> 16) & 0xff); block[15] = UInt8((cbits >> 24) & 0xff)

        let data = makeBCTex(format: 4, dw: 4, dh: 4, iw: 4, ih: 4, blocks: block)
        let tex = try XCTUnwrap(TexImage.parse(data))
        let cpu = try XCTUnwrap(TexDecoder.rgba(from: tex, data: data)).pixels
        let bc = try XCTUnwrap(TexDecoder.nativeBC(from: tex, data: data))
        let gpu = try renderNativeBC(bc, device: device)
        XCTAssertEqual(gpu.count, [UInt8](cpu).count)
        let (maxD, meanD) = diffStats([UInt8](cpu), gpu)
        NSLog("%@", "[BC3 parity] maxDiff=\(maxD) meanDiff=\(String(format: "%.2f", meanD)) (GPU hw vs CPU int 보간)")
        // 파리티는 측정 — 정확 일치 요구 아님(하드웨어 보간 라운딩). 단색 폴백(전역 상이)만 배제하는 느슨한 상한.
        XCTAssertLessThan(maxD, 24, "GPU/CPU BC3 보간 차이가 예상(±소)보다 큼 — 조사 필요")
        XCTAssertLessThan(meanD, 8, "평균 차이 과대")
    }

    /// BC1 punch-through(c0<=c1): 인덱스3 = 투명 검정. GPU 가 1비트 알파 규약을 CPU 와 동일 처리하는지.
    func testBC1PunchThroughParity() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsBCTextureCompression else {
            throw XCTSkip("no Metal / no BC")
        }
        // c0 <= c1 → 3색 + 투명. c0=green565(0x07E0), c1=blue565... green(0x07E0) > blue(0x001F) 이므로
        // punch-through 를 위해 c0<c1 필요: c0=0x0001, c1=0x07E0.
        var block = [UInt8](repeating: 0, count: 8)
        block[0] = 0x01; block[1] = 0x00                    // c0 = 0x0001 (거의 검정, 파랑 1)
        block[2] = 0xE0; block[3] = 0x07                    // c1 = 0x07E0 (green) → c0<c1
        var cbits: UInt32 = 0
        for i in 0..<16 { cbits |= UInt32(i % 4) << (2 * i) } // 0,1,2,3 순환(3=투명)
        block[4] = UInt8(cbits & 0xff); block[5] = UInt8((cbits >> 8) & 0xff)
        block[6] = UInt8((cbits >> 16) & 0xff); block[7] = UInt8((cbits >> 24) & 0xff)

        let data = makeBCTex(format: 7, dw: 4, dh: 4, iw: 4, ih: 4, blocks: block)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.payload, .bc1)
        let cpu = [UInt8](try XCTUnwrap(TexDecoder.rgba(from: tex, data: data)).pixels)
        let bc = try XCTUnwrap(TexDecoder.nativeBC(from: tex, data: data))
        let gpu = try renderNativeBC(bc, device: device)
        let (maxD, meanD) = diffStats(cpu, gpu)
        NSLog("%@", "[BC1 punch-through parity] maxDiff=\(maxD) meanDiff=\(String(format: "%.2f", meanD))")
        // 인덱스3 픽셀들의 알파=0 인지 확인(punch-through 규약 동일). 픽셀3,7,11,15 가 index3.
        for pi in [3, 7, 11, 15] { XCTAssertEqual(gpu[pi * 4 + 3], 0, "index3 픽셀 GPU 알파=0(투명)") }
        XCTAssertLessThan(maxD, 24, "GPU/CPU BC1 차이 과대")
        XCTAssertLessThan(meanD, 8)
    }

    /// 비정렬 크롭(image 6×6 ⊂ decode 8×8)이 GPU 에서 CPU cropped() 와 일치하는지 — stride 경로 end-to-end.
    func testNonAlignedCropParity() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsBCTextureCompression else {
            throw XCTSkip("no Metal / no BC")
        }
        // 4블록(2×2) 각기 다른 단색: [red green / blue white]. image 6×6 는 4블록 모두 부분 접근.
        func solid(_ c: UInt16) -> [UInt8] { bc3Solid565(c) }
        let red = solid(0xF800), green = solid(0x07E0), blue = solid(0x001F), white = solid(0xFFFF)
        let blocks = red + green + blue + white
        let data = makeBCTex(format: 4, dw: 8, dh: 8, iw: 6, ih: 6, blocks: blocks)
        let tex = try XCTUnwrap(TexImage.parse(data))
        let cpu = [UInt8](try XCTUnwrap(TexDecoder.rgba(from: tex, data: data)).pixels)  // 6×6 크롭
        let bc = try XCTUnwrap(TexDecoder.nativeBC(from: tex, data: data))
        XCTAssertEqual([bc.width, bc.height], [6, 6])
        let gpu = try renderNativeBC(bc, device: device)
        let (maxD, _) = diffStats(cpu, gpu)
        NSLog("%@", "[비정렬 크롭 parity] maxDiff=\(maxD)")
        // 단색 블록이라 보간 없음 → GPU/CPU 정확 일치 기대(패딩 스킵이 맞으면 0).
        XCTAssertEqual(maxD, 0, "단색 블록 비정렬 크롭은 stride 로 정확 일치해야")
    }
}
