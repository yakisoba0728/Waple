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
            return [r, g, b, f("alpha", 1), blendMode(c)]
        case "waterripple":
            // strength/scale 키: ui_editor_properties_* → 실제 씬 키(ripple_*) → 단축 키 → 기본값.
            // 설계 문서 §2 정찰: 실제 오브젝트 constants 는 ratio, ripple_scale, ripple_strength.
            let strength = c["ui_editor_properties_ripple_strength"]?.first ?? c["ripple_strength"]?.first ?? c["strength"]?.first ?? 0.1
            let scale = c["ui_editor_properties_ripple_scale"]?.first ?? c["ripple_scale"]?.first ?? c["scale"]?.first ?? 1
            let scrollSpeed = c["scrollspeed"]?.first ?? c["speed"]?.first ?? 0.05
            return [strength, scale, scrollSpeed]
        case "scroll":
            let sc = c["scale"] ?? [1, 1]
            let sp = c["speed"] ?? c["scrollspeed"] ?? [0.05, 0]
            let sx = sc.count > 0 ? sc[0] : 1, sy = sc.count > 1 ? sc[1] : sx
            let vx = sp.count > 0 ? sp[0] : 0.05, vy = sp.count > 1 ? sp[1] : 0
            return [sx, sy, vx, vy]
        case "waterwaves":
            let a = f("direction", 0) * .pi / 180
            return [cos(a), sin(a), f("speed", 5), f("scale", 200), f("strength", 0.1), f("perspective", 0)]
        case "shake":
            // 단순화: flow/noise combo 없이 시간 기반 흔들림. amp/speed 키는 게이트서 확인.
            let amp = c["amplitude"]?.first ?? c["amount"]?.first ?? c["strength"]?.first ?? 0.006
            let spd = c["speed"]?.first ?? c["roughness"]?.first ?? 5
            return [amp, spd]
        default:
            return nil
        }
    }

    /// tint 블렌드 모드 인덱스. 지원: 0=normal,1=multiply,2=add,3=screen,4=overlay. 미지원/미지정→0.
    /// NOTE: WE 의 정확한 BLENDMODE enum 정수 매핑은 시각 게이트에서 확인 필요(현재는 인덱스 패스스루).
    private static func blendMode(_ c: [String: [Float]]) -> Float {
        let raw = c["blendmode"]?.first ?? c["ui_editor_properties_blend_mode"]?.first ?? 0
        let idx = Int(raw.rounded())
        return (0...4).contains(idx) ? Float(idx) : 0
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
                                texture2d<float> mask [[texture(1)]], texture2d<float> t2 [[texture(2)]],
                                constant float* P [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float4 c = fb.sample(s, in.uv);
            float m = mask.sample(s, in.uv).r;
            float3 base = c.rgb;
            float3 tint = float3(P[1], P[2], P[3]);
            // 블렌드 모드(P[5]): 0=normal,1=multiply,2=add,3=screen,4=overlay.
            int mode = int(P[5] + 0.5);
            float3 blended;
            if (mode == 1) { blended = base * tint; }
            else if (mode == 2) { blended = base + tint; }
            else if (mode == 3) { blended = 1.0 - (1.0 - base) * (1.0 - tint); }
            else if (mode == 4) {
                blended = select(2.0 * base * tint, 1.0 - 2.0 * (1.0 - base) * (1.0 - tint), base >= 0.5);
            } else { blended = tint; }
            c.rgb = mix(base, blended, P[4] * m);
            return c;
        }
        """,
        "waterripple": """
        fragment float4 ef_main(EOut in [[stage_in]], texture2d<float> fb [[texture(0)]],
                                texture2d<float> normalMap [[texture(1)]], texture2d<float> mask [[texture(2)]],
                                constant float* P [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::repeat);
            constexpr sampler sc(filter::linear, address::clamp_to_edge);
            // P[0]=time, P[1]=strength, P[2]=scale, P[3]=scrollSpeed.
            float2 nUV = in.uv * P[2] + float2(P[0] * P[3], P[0] * P[3] * 0.5);
            float3 n = normalMap.sample(s, nUV).rgb * 2.0 - 1.0;
            float maskV = mask.sample(sc, in.uv).r;
            float2 distort = n.xy * P[1] * maskV;
            return fb.sample(sc, in.uv + distort);
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
        "shake": """
        fragment float4 ef_main(EOut in [[stage_in]], texture2d<float> fb [[texture(0)]],
                                texture2d<float> flow [[texture(1)]], texture2d<float> mask [[texture(2)]],
                                constant float* P [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            // P[0]=time, P[1]=amplitude, P[2]=speed. flow map 은 단순화로 미사용.
            float m = mask.sample(s, in.uv).r;
            float t = P[0] * P[2];
            float2 off = P[1] * float2(sin(t), cos(t * 1.37)) * m;
            return fb.sample(s, in.uv + off);
        }
        """,
    ]
}
