enum ParticleShaders {
    /// 버텍스 버퍼: 정점당 인터리브드 8 float = [ndc.x, ndc.y, u, v, r, g, b, a].
    /// frag 는 premultiplied-alpha 를 출력하므로 additive/translucent 둘 다 src=one 으로 합성 가능
    /// (translucent: dst=oneMinusSrcAlpha, additive: dst=one).
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct PVOut { float4 pos [[position]]; float2 uv; float4 color; };

    vertex PVOut pv_main(uint vid [[vertex_id]],
                         const device float* v [[buffer(0)]],
                         constant float2& cameraOffset [[buffer(1)]],
                         constant float2& aspectScale [[buffer(2)]]) {
        uint b = vid * 8;
        float2 pos = float2(v[b + 0], v[b + 1]);
        float2 uv  = float2(v[b + 2], v[b + 3]);
        float4 col = float4(v[b + 4], v[b + 5], v[b + 6], v[b + 7]);
        float2 p = (pos + cameraOffset) * aspectScale;
        PVOut o; o.pos = float4(p.x, p.y, 0.0, 1.0); o.uv = uv; o.color = col; return o;
    }

    // 3D 씬 파티클: 월드 위치(카메라-페이싱 빌보드로 CPU 전개) → viewProj 원근 투영. 정점당 9 float =
    // [world.xyz, u, v, r, g, b, a]. frag(pf_main)·블렌드는 2D 와 공유(premult α).
    vertex PVOut pv3d_main(uint vid [[vertex_id]],
                           const device float* v [[buffer(0)]],
                           constant float4x4& viewProj [[buffer(1)]]) {
        uint b = vid * 9;
        float3 wp  = float3(v[b + 0], v[b + 1], v[b + 2]);
        float2 uv  = float2(v[b + 3], v[b + 4]);
        float4 col = float4(v[b + 5], v[b + 6], v[b + 7], v[b + 8]);
        PVOut o; o.pos = viewProj * float4(wp, 1.0); o.uv = uv; o.color = col; return o;
    }

    fragment float4 pf_main(PVOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 t = tex.sample(s, in.uv);
        float A = t.a * in.color.a;
        return float4(t.rgb * in.color.rgb * A, A);
    }
    """
}
