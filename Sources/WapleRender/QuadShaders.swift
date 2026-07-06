enum QuadShaders {
    // verts buffer: float4 per vertex = (ndc.x, ndc.y, uv.x, uv.y)
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };

    """ + BlendMSL.source + """
    vertex VOut v_main(uint vid [[vertex_id]],
                       const device float4* verts [[buffer(0)]],
                       constant float2& cameraOffset [[buffer(1)]],
                       constant float2& parallaxDepth [[buffer(2)]],
                       constant float2& aspectScale [[buffer(3)]]) {
        float4 v = verts[vid];
        float2 p = (v.xy + cameraOffset * parallaxDepth) * aspectScale;
        VOut o; o.pos = float4(p.x, p.y, 0.0, 1.0); o.uv = float2(v.z, v.w); return o;
    }
    fragment float4 f_main(VOut in [[stage_in]],
                           texture2d<float> tex [[texture(0)]],
                           constant float4 &tint [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        // 파이프라인 규약(설계 §3): 입력(텍스처/이펙트 결과)은 straight-alpha.
        // 블렌드가 src=one(premultiplied-over)이므로 여기서 단 한 번 premultiply 한다.
        float a = c.a * tint.a;
        return float4(c.rgb * tint.rgb * a, a);
    }
    // 레이어 colorBlendMode 합성: dst = acc 스냅샷(화면좌표 샘플), src = 레이어 텍스처×tint.
    // 블렌딩은 셰이더에서 계산(HW 블렌딩 OFF, 결과 rgb 직기록·dst 알파 보존).
    // acc 는 premultiplied 누적 — 불투명 배경(일반 씬)에선 straight 와 동일(컴포지션과 같은 전제).
    fragment float4 f_blend(VOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            texture2d<float> dst [[texture(1)]],
                            constant float4 &tint [[buffer(0)]],
                            constant int &mode [[buffer(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        float2 duv = float2(in.pos.x / float(dst.get_width()), in.pos.y / float(dst.get_height()));
        float4 d = dst.sample(s, duv);
        float o = c.a * tint.a;
        float3 r = applyBlending(mode, d.rgb, c.rgb * tint.rgb, o);
        return float4(r, d.a);
    }
    """
}
