import Foundation

enum EffectShaders {
    /// 효과 이름 → MSL(공유 vert ev_main + 효과 frag ef_main).
    /// frag uniform: constant float* P (P[0]=time, P[1..]=params, 효과별 순서).
    static func source(for name: String) -> String? {
        guard let frag = frags[name] else { return nil }
        return header + vert + frag
    }

    /// constantshadervalues → 효과별 파라미터 슬롯(기본값 포함). 미지원 nil.
    static func params(for name: String, constants c: [String: [Float]]) -> [Float]? {
        func f(_ k: String, _ d: Float) -> Float { c[k]?.first ?? d }
        switch name {
        case "opacity":
            return [f("alpha", 1)]
        case "tint":
            let col = c["color"] ?? [1, 0, 0]
            let r = col.count > 0 ? col[0] : 1, g = col.count > 1 ? col[1] : 0, b = col.count > 2 ? col[2] : 0
            return [r, g, b, f("alpha", 1)]
        case "scroll":
            let sc = c["scale"] ?? [1, 1]
            let sp = c["speed"] ?? c["scrollspeed"] ?? [0.05, 0]
            let sx = sc.count > 0 ? sc[0] : 1, sy = sc.count > 1 ? sc[1] : sx
            let vx = sp.count > 0 ? sp[0] : 0.05, vy = sp.count > 1 ? sp[1] : 0
            return [sx, sy, vx, vy]
        case "waterwaves":
            let a = f("direction", 0) * .pi / 180
            return [cos(a), sin(a), f("speed", 5), f("scale", 200), f("strength", 0.1), f("perspective", 0)]
        default:
            return nil
        }
    }

    private static let header = """
    #include <metal_stdlib>
    using namespace metal;
    struct EOut { float4 pos [[position]]; float2 uv; };

    """
    private static let vert = """
    vertex EOut ev_main(uint vid [[vertex_id]], const device float2* verts [[buffer(0)]]) {
        float2 p = verts[vid];
        EOut o; o.pos = float4(p, 0.0, 1.0); o.uv = float2((p.x + 1) * 0.5, 1.0 - (p.y + 1) * 0.5); return o;
    }

    """
    private static let frags: [String: String] = [
        "waterwaves": """
        fragment float4 ef_main(EOut in [[stage_in]], texture2d<float> fb [[texture(0)]],
                                texture2d<float> mask [[texture(1)]], constant float* P [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float2 dir = float2(P[1], P[2]);
            float maskV = mask.sample(s, in.uv).r;
            float2 tc = in.uv;
            float pos = abs(dot(tc - 0.5, dir));
            float distance = P[0] * P[3] + dot(tc, dir) * (P[4] + P[6] * pos);
            float2 offset = float2(dir.y, -dir.x);
            float strength = P[5] * P[5] + P[6] * pos;
            tc += sin(distance) * offset * strength * maskV;
            return fb.sample(s, tc);
        }
        """,
        "opacity": """
        fragment float4 ef_main(EOut in [[stage_in]], texture2d<float> fb [[texture(0)]],
                                texture2d<float> mask [[texture(1)]], constant float* P [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float4 c = fb.sample(s, in.uv);
            c.a *= mask.sample(s, in.uv).r * P[1];
            return c;
        }
        """,
        "tint": """
        fragment float4 ef_main(EOut in [[stage_in]], texture2d<float> fb [[texture(0)]],
                                texture2d<float> mask [[texture(1)]], constant float* P [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float4 c = fb.sample(s, in.uv);
            float m = mask.sample(s, in.uv).r;
            float3 tint = float3(P[1], P[2], P[3]);
            c.rgb = mix(c.rgb, tint, P[4] * m);
            return c;
        }
        """,
        "scroll": """
        fragment float4 ef_main(EOut in [[stage_in]], texture2d<float> fb [[texture(0)]],
                                texture2d<float> mask [[texture(1)]], constant float* P [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::repeat);
            float2 uv = fract((in.uv + P[0] * float2(P[3], P[4])) * float2(P[1], P[2]));
            return fb.sample(s, uv);
        }
        """,
    ]
}
