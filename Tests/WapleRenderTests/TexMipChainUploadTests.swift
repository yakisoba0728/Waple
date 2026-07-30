import XCTest
import Metal
@testable import WapleRender
import WapleCore

/// mipCount>1 텍스처의 Metal 업로드 검증(NativeBCUploadTests 접근 패턴 — SceneRenderer() + @testable 난부 팩토리):
/// mipmapLevelCount 전체 할당 + 레벨별 내용(readback) 단언, mipCount==1 은 mipmapLevelCount==1 무회귀 단언.
final class TexMipChainUploadTests: XCTestCase {

    private func makeChainTex(format: Int, texW: Int, texH: Int, imgW: Int, imgH: Int,
                              levels: [(w: Int, h: Int, lz4: Int, dec: Int, payload: [UInt8])]) -> Data {
        var b = bytes(tag("TEXV0005"), tag("TEXI0001"))
        b += bytes(i32b(format), i32b(0), i32b(texW), i32b(texH), i32b(imgW), i32b(imgH))
        b += bytes(tag("TEXB0003"), i32b(1), i32b(-1), i32b(levels.count))
        for l in levels {
            b += bytes(i32b(l.w), i32b(l.h), i32b(l.lz4), i32b(l.dec), i32b(l.payload.count), l.payload)
        }
        return Data(b)
    }

    private func solidRGBA(_ w: Int, _ h: Int, _ px: (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(w * h * 4)
        for _ in 0..<(w * h) { out.append(contentsOf: [px.0, px.1, px.2, px.3]) }
        return out
    }

    private func bc3Solid(_ c: UInt16, alpha: UInt8 = 255) -> [UInt8] {
        [alpha, alpha, 0, 0, 0, 0, 0, 0, UInt8(c & 0xff), UInt8(c >> 8), UInt8(c & 0xff), UInt8(c >> 8), 0, 0, 0, 0]
    }

    private func readback(_ tex: MTLTexture, level: Int, w: Int, h: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: level)
        return px
    }

    // MARK: rgba8(CPU 디코드) 경로

    /// mipCount=3 raw RGBA: mipmapLevelCount==3 + 레벨별 내용이 업로드한 솔리드와 일치.
    func testRGBAUploadsAllLevels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let l0 = solidRGBA(8, 8, (255, 0, 0, 255))
        let l1 = solidRGBA(4, 4, (0, 255, 0, 255))
        let l2 = solidRGBA(2, 2, (0, 0, 255, 255))
        let data = makeChainTex(format: 0, texW: 8, texH: 8, imgW: 8, imgH: 8, levels: [
            (8, 8, 0, l0.count, l0), (4, 4, 0, l1.count, l1), (2, 2, 0, l2.count, l2)])
        let tex = try XCTUnwrap(TexImage.parse(data))
        let r = SceneRenderer()
        let up = try XCTUnwrap(r.makeImageTexture(tex: tex, data: data, device: device))
        XCTAssertEqual(up.texture.mipmapLevelCount, 3, "mipCount>1 → 전체 레벨 할당")
        XCTAssertEqual([up.width, up.height], [8, 8], "반환 dims = mip0(파리티)")
        XCTAssertEqual([UInt8](readback(up.texture, level: 0, w: 8, h: 8).prefix(4)), [255, 0, 0, 255])
        XCTAssertEqual([UInt8](readback(up.texture, level: 1, w: 4, h: 4).prefix(4)), [0, 255, 0, 255],
                       "레벨 1 내용 = L1 페이로드")
        XCTAssertEqual([UInt8](readback(up.texture, level: 2, w: 2, h: 2).prefix(4)), [0, 0, 255, 255],
                       "레벨 2 내용 = L2 페이로드")
    }

    /// mipCount==1 무회귀: mipmapLevelCount==1(신규 경로 미발동).
    func testRGBASingleMipNoRegression() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let l0 = solidRGBA(4, 4, (9, 9, 9, 255))
        let data = makeChainTex(format: 0, texW: 4, texH: 4, imgW: 4, imgH: 4, levels: [(4, 4, 0, l0.count, l0)])
        let tex = try XCTUnwrap(TexImage.parse(data))
        let r = SceneRenderer()
        let up = try XCTUnwrap(r.makeImageTexture(tex: tex, data: data, device: device))
        XCTAssertEqual(up.texture.mipmapLevelCount, 1, "mipCount==1 → 단일 레벨(무회귀)")
        XCTAssertEqual([UInt8](readback(up.texture, level: 0, w: 4, h: 4).prefix(4)), [9, 9, 9, 255])
    }

    // MARK: 네이티브 BC 경로

    /// BC3 2레벨(alloc 8×8/orig 6×6 크롭): mipmapLevelCount==2 + 레벨 1 내용을 명시 LOD 샘플로 CPU 디코드와 대조.
    func testBCUploadsAllLevels() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsBCTextureCompression else {
            throw XCTSkip("no Metal / no BC")
        }
        let l0 = bc3Solid(0xF800) + bc3Solid(0xF800) + bc3Solid(0xF800) + bc3Solid(0xF800)   // red 8×8(4블록)
        let l1 = bc3Solid(0x07E0)                                                            // green 4×4(1블록)
        let data = makeChainTex(format: 4, texW: 8, texH: 8, imgW: 6, imgH: 6, levels: [
            (8, 8, 0, l0.count, l0), (4, 4, 0, l1.count, l1)])
        let tex = try XCTUnwrap(TexImage.parse(data))
        let r = SceneRenderer()
        let up = try XCTUnwrap(r.makeImageTexture(tex: tex, data: data, device: device))
        XCTAssertEqual(up.texture.mipmapLevelCount, 2, "mipCount>1 → 전체 레벨 할당")
        XCTAssertEqual([up.width, up.height], [6, 6], "크롭 규약: orig dims(파리티)")
        // 레벨 1(3×3, green)을 명시 level(1.0) 샘플로 렌더백 — CPU 디코드(rgbaLevels[1])와 대조.
        let gpu = try renderAtExplicitLevel(up.texture, level: 1, outW: 3, outH: 3, device: device)
        let cpu = try XCTUnwrap(TexDecoder.rgbaLevels(from: tex, data: data), "CPU 체인 디코드")[1]
        XCTAssertEqual([cpu.width, cpu.height], [3, 3])
        var maxD = 0
        for i in 0..<(3 * 3 * 4) { maxD = max(maxD, abs(Int(gpu[i]) - Int([UInt8](cpu.pixels)[i]))) }
        XCTAssertEqual(maxD, 0, "단색 블록 레벨 1 은 GPU/CPU 정확 일치")
    }

    /// mipCount==1 BC 무회귀: mipmapLevelCount==1.
    func testBCSingleMipNoRegression() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsBCTextureCompression else {
            throw XCTSkip("no Metal / no BC")
        }
        let l0 = bc3Solid(0xF800)
        let data = makeChainTex(format: 4, texW: 4, texH: 4, imgW: 4, imgH: 4, levels: [(4, 4, 0, l0.count, l0)])
        let tex = try XCTUnwrap(TexImage.parse(data))
        let r = SceneRenderer()
        let up = try XCTUnwrap(r.makeImageTexture(tex: tex, data: data, device: device))
        XCTAssertEqual(up.texture.mipmapLevelCount, 1, "mipCount==1 → 단일 레벨(무회귀)")
    }

    /// 손상 체인(레벨 dims 진행 위반 — 선언 레벨 dims 가 기대 max(1,base>>L) 와 불일치)는 단일 레벨 폴백.
    func testMalformedChainFallsBackToSingleLevel() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        // L1 을 4×4 대신 3×3 으로 기록(기대는 8>>1=4) → 검증 실패 → 단일 레벨.
        let l0 = solidRGBA(8, 8, (255, 0, 0, 255))
        let l1 = solidRGBA(3, 3, (0, 255, 0, 255))
        let data = makeChainTex(format: 0, texW: 8, texH: 8, imgW: 8, imgH: 8, levels: [
            (8, 8, 0, l0.count, l0), (3, 3, 0, l1.count, l1)])
        let tex = try XCTUnwrap(TexImage.parse(data))
        let r = SceneRenderer()
        let up = try XCTUnwrap(r.makeImageTexture(tex: tex, data: data, device: device))
        XCTAssertEqual(up.texture.mipmapLevelCount, 1, "비정상 체인은 단일 레벨 업로드(무회귀)")
        XCTAssertEqual([up.width, up.height], [8, 8])
    }

    /// 명시 LOD 렌더백: texture 의 level 을 outW×outH rgba8 타깃에 1:1 샘플(NativeBCUploadTests.renderNativeBC 변형).
    private func renderAtExplicitLevel(_ tex: MTLTexture, level: Int, outW: Int, outH: Int,
                                       device: MTLDevice) throws -> [UInt8] {
        let sh = """
        #include <metal_stdlib>
        using namespace metal;
        struct VO { float4 pos [[position]]; float2 uv; };
        vertex VO v(uint i [[vertex_id]]) {
          float2 p[6] = {{-1,-1},{1,-1},{-1,1},{1,-1},{1,1},{-1,1}};
          float2 u[6] = {{0,1},{1,1},{0,0},{1,1},{1,0},{0,0}};
          VO o; o.pos = float4(p[i],0,1); o.uv = u[i]; return o;
        }
        fragment float4 f(VO i [[stage_in]], texture2d<float> t [[texture(0)]],
                          constant float& lod [[buffer(0)]]) {
          // mip_filter::nearest 명시 — 디폴트(mip_filter::none)는 명시 level() 이 level 0 으로 클램프되는
          // 동작을 보여(실측, 2026-07-28) LOD 지정 샘플이 무효했다.
          constexpr sampler s(filter::nearest, mip_filter::nearest, address::clamp_to_edge);
          return t.sample(s, i.uv, level(lod));
        }
        """
        let lib = try device.makeLibrary(source: sh, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "v")
        pd.fragmentFunction = lib.makeFunction(name: "f")
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipe = try device.makeRenderPipelineState(descriptor: pd)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: outW, height: outH,
                                                          mipmapped: false)
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
        var lod = Float(level)
        enc.setFragmentBytes(&lod, length: 4, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: outW * outH * 4)
        rt.getBytes(&px, bytesPerRow: outW * 4, from: MTLRegionMake2D(0, 0, outW, outH), mipmapLevel: 0)
        return px
    }
}
