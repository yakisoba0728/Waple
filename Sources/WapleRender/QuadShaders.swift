enum QuadShaders {
    // verts buffer: float4 per vertex = (ndc.x, ndc.y, uv.x, uv.y)
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut v_main(uint vid [[vertex_id]], const device float4* verts [[buffer(0)]]) {
        float4 v = verts[vid];
        VOut o; o.pos = float4(v.x, v.y, 0.0, 1.0); o.uv = float2(v.z, v.w); return o;
    }
    fragment float4 f_main(VOut in [[stage_in]],
                           texture2d<float> tex [[texture(0)]],
                           constant float4 &tint [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        return float4(c.rgb * tint.rgb, c.a * tint.a);
    }
    """
}
