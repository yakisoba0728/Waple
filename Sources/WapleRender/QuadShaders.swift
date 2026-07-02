enum QuadShaders {
    // verts buffer: float4 per vertex = (ndc.x, ndc.y, uv.x, uv.y)
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
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
    """
}
