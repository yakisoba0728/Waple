enum EffectShaders {
    /// 효과 이름 → MSL(vert: ev_main, frag: ef_main). framebuffer=texture0, mask=texture1.
    /// uniforms(buffer0): {float2 direction; float time; float speed; float scale; float strength; float perspective;}
    static func source(for name: String) -> String? {
        switch name {
        case "waterwaves": return waterwaves
        default: return nil
        }
    }

    private static let waterwaves = """
    #include <metal_stdlib>
    using namespace metal;
    struct EUniforms { float2 direction; float time; float speed; float scale; float strength; float perspective; };
    struct EOut { float4 pos [[position]]; float2 uv; };
    vertex EOut ev_main(uint vid [[vertex_id]], const device float2* verts [[buffer(0)]]) {
        // 풀스크린 트라이앵글 스트립 4점: (-1,-1)(1,-1)(-1,1)(1,1), uv=(0,1)(1,1)(0,0)(1,0)
        float2 p = verts[vid];
        EOut o; o.pos = float4(p, 0.0, 1.0); o.uv = float2((p.x + 1) * 0.5, 1.0 - (p.y + 1) * 0.5); return o;
    }
    fragment float4 ef_main(EOut in [[stage_in]],
                            texture2d<float> fb [[texture(0)]],
                            texture2d<float> mask [[texture(1)]],
                            constant EUniforms& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 dir = u.direction;
        float maskV = mask.sample(s, in.uv).r;
        float2 tc = in.uv;
        float pos = abs(dot(tc - 0.5, dir));
        float distance = u.time * u.speed + dot(tc, dir) * (u.scale + u.perspective * pos);
        float2 offset = float2(dir.y, -dir.x);
        float strength = u.strength * u.strength + u.perspective * pos;
        tc += sin(distance) * offset * strength * maskV;
        return fb.sample(s, tc);
    }
    """
}
