import Metal
import WapleCore

/// float(rgba16Float) HDR 누적 버퍼를 표시 포맷(bgra8)으로 확정하는 최종 포스트 패스. 최종 blit 대체.
///
/// 압축 커브 = saturate 클램프. WE 2.8 의 최종 처리는 saturate 뿐(무-ACES 5중확증)이라
/// HDRBloomPass 합성부(saturate(base+bloom))와 동일 규약 — >1 은 1.0 으로 클램프(밝은 영역 순백은
/// WE-충실 결과이며 결함 아님), [0,1] 저역은 항등. 종전 ACES filmic 은 저역까지 곡선변형해 이탈했다(제거).
/// EOTF(sRGB) 인코드는 미이식 — sRGB-뷰 스왑체인의 하드웨어 인코드와 상쇄되는 쌍이라 비-sRGB(bgra8)
/// 타깃엔 이중감마가 된다(근거: SceneRendererFinalizer #22 · HDRBloomPass 합성 셰이더 주석).
/// exposure 유니폼 = 밝기 튜닝 노브(ponytail: 미니멀 모델이 못 보는 캘리브레이션 여지, 기본 1.0 = 항등).
final class HDRPostPass {
    private let pipeline: MTLRenderPipelineState
    /// 노출 배율(씬 밝기 튜닝). 클램프 입력에 곱한다(기본 1.0 = 항등).
    var exposure: Float = 1

    /// outputFormat 은 최종 LDR 타깃 포맷(drawable/캡처 = .bgra8Unorm). 파이프라인 생성 실패 시 nil.
    init?(device: MTLDevice, outputFormat: MTLPixelFormat) {
        guard let lib = try? WapleProfiler.compile(HDRPostPass.source, { try device.makeLibrary(source: HDRPostPass.source, options: nil) }),
              let vf = lib.makeFunction(name: "hdrpost_v"),
              let ff = lib.makeFunction(name: "hdrpost_f") else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vf
        pd.fragmentFunction = ff
        pd.colorAttachments[0].pixelFormat = outputFormat
        guard let ps = try? WapleProfiler.pipe({ try device.makeRenderPipelineState(descriptor: pd) }) else { return nil }
        self.pipeline = ps
    }

    /// float `src`(HDR 누적) 를 saturate 클램프해 LDR `dst` 로 그린다. 풀스크린 삼각형 — 최종 blit 대체.
    /// 현재 command buffer 에 자체 render encoder 를 open/close(호출부는 그 전에 씬 encoder 를 닫아야 한다).
    /// F539(F-71): 인코더 생성 실패를 삼키지 않고 false 반환 — 미기록 dst present/캡처를 호출부가 스킵 가능.
    @discardableResult
    func encode(cb: MTLCommandBuffer, src: MTLTexture, dst: MTLTexture) -> Bool {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .dontCare   // 풀스크린 삼각형이 전 픽셀 덮음
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(src, index: 0)
        var exp = exposure
        enc.setFragmentBytes(&exp, length: MemoryLayout<Float>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        return true
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    // 풀스크린 삼각형(vertex buffer 불요). uv 는 텍스처 공간(y-down) 정합 — blit 대체라 상하반전 금지:
    // NDC top(y=+1) → uv.y=0(텍스처 top). vid0=(-1,-1), vid1=(-1,3), vid2=(3,-1).
    vertex VOut hdrpost_v(uint vid [[vertex_id]]) {
        float2 p = float2(vid == 2 ? 3.0 : -1.0, vid == 1 ? 3.0 : -1.0);
        VOut o;
        o.pos = float4(p, 0.0, 1.0);
        o.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
        return o;
    }
    fragment float4 hdrpost_f(VOut in [[stage_in]],
                              texture2d<float> hdrTex [[texture(0)]],
                              constant float &exposure [[buffer(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);   // acc 는 dst 와 1:1 해상 = 보간 불요
        float4 c = hdrTex.sample(s, in.uv);
        // WE 최종 = saturate 클램프(무-ACES 5중확증, HDRBloomPass 합성부와 동일 규약).
        // >1 → 1.0(순백), [0,1] 저역은 항등(ACES 는 저역도 곡선변형). exposure = 밝기 노브.
        // F675: 최종 알파 1.0 강제 — c.a 통과는 캡처 PNG 투명 픽셀(디스플레이는 알파 무시라 묵시 무차).
        return float4(saturate(c.rgb * exposure), 1.0);
    }
    """
}
