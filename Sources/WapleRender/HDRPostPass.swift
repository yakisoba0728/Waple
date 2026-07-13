import Metal

/// A2 HDR 톤맵 포스트 패스 — float(rgba16Float) 누적 버퍼의 >1.0 합을 [0,1] LDR 로 압축(백화 방지).
///
/// 배경(lane-04 §1): WE `hdr:true` 씬은 float HDR 버퍼에 합성 후 combine 단계에서 톤맵으로 >1 합을
/// 압축한다. Waple 은 종전 bgra8 누적이라 >1 합이 [0,1] 하드클램프 = 밝은 영역 순백("백화").
/// 이 패스가 그 압축(= "clamp the sum" → "tonemap the sum", lane-04 §3 D1)을 담당한다. 최종 blit 대체.
///
/// **톤맵 커브: ACES filmic (Narkowicz 2015 근사), per-channel + exposure.**
/// ⚠️ WE 의 정확한 톤맵 커브는 참조본(exe/dll/scripts.js)에서 복원 불가 — tonemap/reinhard/aces/filmic
/// 문자열 전무(lane-04 §1.3). ACES 는 게임 HDR 파이프라인의 사실상 표준 근사이며 0→0 을 유지하고
/// >1 을 <1 로 매끄럽게 압축해 순백 plateau 를 제거한다. WE 실측 커브 확보 시 커브만 교체하면 된다.
/// exposure 유니폼 = 튜닝 노브(ponytail: 미니멀 모델이 못 보는 물리 캘리브레이션 여지, 기본 1.0).
///
/// sRGB 인코드는 의도적으로 미포함 — 추가 시 전 미드톤이 이동해 기존 LDR 베이스라인과 불일치(별개 관심사).
final class HDRPostPass {
    private let pipeline: MTLRenderPipelineState
    /// 노출 배율(씬 밝기 튜닝). 톤맵 입력에 곱한다.
    var exposure: Float = 1

    /// outputFormat 은 최종 LDR 타깃 포맷(drawable/캡처 = .bgra8Unorm). 파이프라인 생성 실패 시 nil.
    init?(device: MTLDevice, outputFormat: MTLPixelFormat) {
        guard let lib = try? device.makeLibrary(source: HDRPostPass.source, options: nil),
              let vf = lib.makeFunction(name: "hdrpost_v"),
              let ff = lib.makeFunction(name: "hdrpost_f") else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vf
        pd.fragmentFunction = ff
        pd.colorAttachments[0].pixelFormat = outputFormat
        guard let ps = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }
        self.pipeline = ps
    }

    /// float `src`(HDR 누적) 를 톤맵해 LDR `dst` 로 그린다. 풀스크린 삼각형 — 최종 blit 대체.
    /// 현재 command buffer 에 자체 render encoder 를 open/close(호출부는 그 전에 씬 encoder 를 닫아야 한다).
    func encode(cb: MTLCommandBuffer, src: MTLTexture, dst: MTLTexture) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .dontCare   // 풀스크린 삼각형이 전 픽셀 덮음
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(src, index: 0)
        var exp = exposure
        enc.setFragmentBytes(&exp, length: MemoryLayout<Float>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
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
    // ACES filmic (Narkowicz 2015) per-channel. 0→0, >1 을 <1 로 압축(순백 plateau 제거). 단조증가라 hue 순서 보존.
    float3 acesFilmic(float3 x) {
        const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
        return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
    }
    fragment float4 hdrpost_f(VOut in [[stage_in]],
                              texture2d<float> hdrTex [[texture(0)]],
                              constant float &exposure [[buffer(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);   // acc 는 dst 와 1:1 해상 = 보간 불요
        float4 c = hdrTex.sample(s, in.uv);
        return float4(acesFilmic(max(c.rgb, 0.0) * exposure), c.a);
    }
    """
}
