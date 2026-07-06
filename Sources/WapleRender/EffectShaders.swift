import Foundation

enum EffectShaders {
    /// 효과 이름 → MSL(공유 vert ev_main + 효과 frag ef_main).
    /// frag uniform: constant float* P (P[0]=time, P[1..]=params, 효과별 순서).
    static func source(for name: String) -> String? {
        guard let frag = frags[name] else { return nil }
        return header + vert + frag
    }

    /// constantshadervalues(+combos) → 효과별 파라미터 슬롯(기본값 포함). 미지원 nil.
    static func params(for name: String, constants c: [String: [Float]], combos cb: [String: Int] = [:]) -> [Float]? {
        func f(_ k: String, _ d: Float) -> Float { c[k]?.first ?? d }
        switch name {
        case "opacity":
            return [f("alpha", 1)]
        case "tint":
            let col = c["color"] ?? [1, 0, 0]
            let r = col.count > 0 ? col[0] : 1, g = col.count > 1 ? col[1] : 0, b = col.count > 2 ? col[2] : 0
            // BLENDMODE 은 콤보(0..32). 없으면 0=Normal. (구버전 constants["blendmode"] 도 폴백.)
            let mode = Float(cb["BLENDMODE"] ?? Int(c["blendmode"]?.first ?? 0))
            return [r, g, b, f("alpha", 1), mode]
        case "pulse":
            // [speed,phase,amount,power,threshLo,threshHi, blendmode, pulseColor, pulseAlpha, audioMode, tintLo(3), tintHi(3)]
            let bounds = c["bounds"] ?? [0, 1]
            let tLo = c["tintlow"] ?? [1, 1, 1], tHi = c["tinthigh"] ?? [1, 1, 1]
            func v3(_ a: [Float], _ i: Int) -> Float { i < a.count ? a[i] : 1 }
            return [f("speed", 3), f("phase", 0), f("amount", 1), f("power", 1),
                    bounds.count > 0 ? bounds[0] : 0, bounds.count > 1 ? bounds[1] : 1,
                    Float(cb["BLENDMODE"] ?? 9), Float(cb["PULSECOLOR"] ?? 1), Float(cb["PULSEALPHA"] ?? 0),
                    Float(cb["AUDIOPROCESSING"] ?? 0),
                    v3(tLo, 0), v3(tLo, 1), v3(tLo, 2), v3(tHi, 0), v3(tHi, 1), v3(tHi, 2)]
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

    private static let header = """
    #include <metal_stdlib>
    using namespace metal;
    struct EOut { float4 pos [[position]]; float2 uv; };

    """ + BlendMSL.source
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
            float a = c.a * mask.sample(s, in.uv).r * P[1];
            // straight 출력(설계 §3): premultiply 는 최종 컴포지트(f_main)에서 1회 — 체인 이중적용 방지.
            return float4(c.rgb, a);
        }
        """,
        "tint": """
        fragment float4 ef_main(EOut in [[stage_in]], texture2d<float> fb [[texture(0)]],
                                texture2d<float> mask [[texture(1)]], texture2d<float> t2 [[texture(2)]],
                                constant float* P [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float4 c = fb.sample(s, in.uv);
            float m = mask.sample(s, in.uv).r;
            // BLENDMODE(P[5]) 은 WE 전체 enum(0..32). applyBlending 이 opacity(P[4]*mask) 로 믹스.
            c.rgb = applyBlending(int(P[5] + 0.5), c.rgb, float3(P[1], P[2], P[3]), P[4] * m);
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
        "pulse": """
        fragment float4 ef_main(EOut in [[stage_in]], texture2d<float> fb [[texture(0)]],
                                constant float* P [[buffer(0)]], constant float& audio [[buffer(1)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            // P[0]=time, P[1]=speed,P[2]=phase,P[3]=amount,P[4]=power,P[5]=threshLo,P[6]=threshHi,
            //   P[7]=blendmode,P[8]=pulseColor,P[9]=pulseAlpha,P[10]=audioMode,P[11..13]=tintLo,P[14..16]=tintHi.
            float4 c = fb.sample(s, in.uv);
            float pulse;
            if (P[10] > 0.5) {
                pulse = audio;  // audioResponse (CPU 계산, buffer1)
            } else {
                pulse = smoothstep(P[5], P[6], sin(P[0] * P[1] + (P[2] - 0.25) * 6.28318530718) * 0.5 + 0.5) * P[3];
                pulse = pow(max(pulse, 0.0), P[4]);
            }
            float3 albedo = c.rgb;
            if (P[8] > 0.5) {
                albedo = applyBlending(int(P[7] + 0.5), c.rgb * float3(P[11], P[12], P[13]), c.rgb * float3(P[14], P[15], P[16]), pulse);
            }
            float a = c.a;
            if (P[9] > 0.5) { a *= pulse; }
            // straight 출력(설계 §3): premultiply 는 최종 컴포지트(f_main)에서 1회.
            return float4(max(float3(0.0), albedo), a);
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
