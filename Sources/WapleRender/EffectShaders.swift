import Foundation
import WapleCore   // F530-sweep: safeInt(_:) — 신뢰 경계 밖 상수의 정수 좁힘 가드(정본 하나로 모은다)

enum EffectShaders {
    /// 효과 이름 → MSL(공유 vert ev_main + 효과 frag ef_main).
    /// frag uniform: constant float* P (P[0]=time, P[1..]=params, 효과별 순서).
    /// fbNearest(감사 V06): texture(0)(fb=체인 첫 src, 레이어 베이스 텍스처) 샘플만 nearest — TexImage
    /// .noInterpolation(flags bit0, WE NoInterpolation) 소비. false 면 기존 소스와 비트동일(무회귀).
    static func source(for name: String, fbNearest: Bool = false) -> String? {
        guard let frag = frags[name] else { return nil }
        return header + vert + (fbNearest ? nearestFB(frag) : frag)
    }

    /// fb.sample(<sampler>, …) 사이트의 샘플러만 nearest 쌍생(어드레스 모드 보존 — NoInterpolation 은
    /// 필터만 point, 랩은 WE 그대로)으로 치환한다. aux 등 다른 텍스처의 동일 샘플러 사용은 불변.
    /// 선언/사이트를 찾지 못하면 원문 그대로(폴터=기존 선형 — 무회귀·무크래시 우선).
    private static func nearestFB(_ frag: String) -> String {
        guard let siteRe = try? NSRegularExpression(pattern: #"fb\.sample\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,"#) else { return frag }
        let ns = frag as NSString
        var samplers: [String] = []   // 첫 등장 순서 수집(치환은 식별자별 독립 — 결정성 유지용)
        for m in siteRe.matches(in: frag, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range(at: 1))
            if !samplers.contains(s) { samplers.append(s) }
        }
        var out = frag
        for s in samplers {
            // 선언문 `constexpr sampler <s>(filter::linear, …);` 을 찾아 nearest 쌍생을 직후에 삽입.
            let anchor = "constexpr sampler \(s)(filter::linear,"
            guard let aStart = out.range(of: anchor),
                  let semi = out[aStart.lowerBound...].firstIndex(of: ";") else { continue }
            let decl = String(out[aStart.lowerBound...semi])
            let twin = decl
                .replacingOccurrences(of: "sampler \(s)(", with: "sampler \(s)NearestFB(")
                .replacingOccurrences(of: "filter::linear", with: "filter::nearest")
            out.insert(contentsOf: "\n    " + twin, at: out.index(after: semi))
            // fb 샘플 사이트만 쌍생으로(다른 텍스처의 <s> 사용은 그대로).
            guard let sRe = try? NSRegularExpression(
                pattern: #"fb\.sample\(\s*"# + NSRegularExpression.escapedPattern(for: s) + #"\s*,"#) else { continue }
            out = sRe.stringByReplacingMatches(
                in: out, range: NSRange(location: 0, length: (out as NSString).length),
                withTemplate: "fb.sample(\(s)NearestFB,")
        }
        return out
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
            // BLENDMODE 은 콤보(0..32). (구버전 constants["blendmode"] 도 폴백.)
            // F672: 기본 = WE tint.frag [COMBO] default:30(Tint, 휘도보존 컬러라이즈) — 구 0(Normal)은
            // blendmode 키 부재 폴터에서 mix(A,B,o) 단색 워시였다.
            // F530-sweep: constantshadervalues 는 신뢰 경계 밖이라 맨 `Int(Float)` 는 트랩이었다.
            let mode = Float(cb["BLENDMODE"] ?? safeInt(Double(c["blendmode"]?.first ?? 30)) ?? 30)
            return [r, g, b, f("alpha", 1), mode]
        case "pulse":
            // [speed,phase,amount,power,threshLo,threshHi, blendmode, pulseColor, pulseAlpha, audioMode, tintLo(3), tintHi(3),
            //  noiseSpeed, noiseAmount, maskCombo]
            // F830: noise 계열 키는 WE pulse.frag 주석 확정(noisespeed 기본 0.5 / noiseamount 기본 0).
            // F831: MASK 콤보(g_Texture2 의 combo:"MASK") — 씬 JSON combos["MASK"]!=0 이면 마스크 분기.
            let bounds = c["bounds"] ?? [0, 1]
            let tLo = c["tintlow"] ?? [1, 1, 1], tHi = c["tinthigh"] ?? [1, 1, 1]
            func v3(_ a: [Float], _ i: Int) -> Float { i < a.count ? a[i] : 1 }
            return [f("speed", 3), f("phase", 0), f("amount", 1), f("power", 1),
                    bounds.count > 0 ? bounds[0] : 0, bounds.count > 1 ? bounds[1] : 1,
                    Float(cb["BLENDMODE"] ?? 9), Float(cb["PULSECOLOR"] ?? 1), Float(cb["PULSEALPHA"] ?? 0),
                    Float(cb["AUDIOPROCESSING"] ?? 0),
                    v3(tLo, 0), v3(tLo, 1), v3(tLo, 2), v3(tHi, 0), v3(tHi, 1), v3(tHi, 2),
                    f("noisespeed", 0.5), f("noiseamount", 0), Float(cb["MASK"] ?? 0)]
        case "waterripple":
            // F-X8: 실코퍼스 material 키(스톡 waterripple.frag/.vert 주석 확정) = ripplestrength/scale/
            // animationspeed(구동원, 기본 0.15) — 구코드는 ripple_strength/ripple_scale/scrollspeed 를
            // 조회해 전건 미스했다(실키와 구분자·이름 모두 불일치). scrollspeed(기본 0)는 별도 실키지만
            // 이 손포팅의 단일탭 모델에서는 애니메이션 구동원 슬롯(P[3])을 animationspeed 가 맡는다(WE
            // vert: v_TexCoordRipple = coords + g_Time*g_AnimationSpeed² + scroll — scroll 은 scrollspeed
            // 이지만 통상 0이라 animationspeed 가 주 구동). 구 키는 폴백으로 유지(무회귀).
            // (Float 명시: 구형 컴파일러(Swift 5.10)는 ?? 체인의 리터럴을 오추론해 에러 — CI macos-14 대응)
            let strength: Float = c["ripplestrength"]?.first ?? c["ripple_strength"]?.first ?? c["strength"]?.first ?? 0.1
            let scale: Float = c["scale"]?.first ?? c["ripple_scale"]?.first ?? 1
            let scrollSpeed: Float = c["animationspeed"]?.first ?? c["scrollspeed"]?.first ?? c["speed"]?.first ?? 0.15
            return [strength, scale, scrollSpeed]
        case "scroll":
            // F267: WE scroll 머티리얼명은 repeat(g_Scale)·speedx/speedy(g_ScrollX/Y, 별도 스칼라 키, 기본
            // 0.2/0.2) — 구코드는 scale/speed(배열) 로 오독해 실씬 커스터마이즈가 무시되고 손포팅 기본
            // ([0.05,0],[1,1])으로 되돌아갔다(scroll.json 대조 확정). WE scroll.vert:19
            // `scroll = sign(scroll) * pow(scroll, 2.0)`(부호보존 제곱, 시간 무관 상수라 여기서 1 회 적용)
            // 도 미반영이었음. 실키 불확실(에디터 라벨 케이싱 잔여) 대비 구 키(scale/speed/scrollspeed)를
            // 폴백으로 유지(무회귀).
            let sc = c["repeat"] ?? c["scale"] ?? [1, 1]
            let legacySpeed = c["speed"] ?? c["scrollspeed"]
            let sxRaw: Float = c["speedx"]?.first ?? legacySpeed?.first ?? 0.2
            let syRaw: Float = c["speedy"]?.first ?? ((legacySpeed?.count ?? 0) > 1 ? legacySpeed![1] : 0.2)
            func signSq(_ v: Float) -> Float { (v < 0 ? -1 : 1) * v * v }
            let sx = sc.count > 0 ? sc[0] : 1, sy = sc.count > 1 ? sc[1] : sx
            return [sx, sy, signSq(sxRaw), signSq(syRaw)]
        case "waterwaves":
            // F268/F269: WE waterwaves.vert:48 `v_Direction = rotateVec2(vec2(0,1), g_Direction)` — 기준벡터
            // (0,1)(세로) 회전. 구 코드는 기준벡터 (1,0)(가로) 이라 direction=0(기본)에서 dir 이 90° 어긋났다
            // (rotateVec2 정의 common.h:28 대조: rotate((0,1),a)=(-sin a, cos a)).
            //
            // G-B4-02: 그때 "단위(rad/deg) 미확정" 으로 남겨 둔 `* .pi / 180` 을 **제거한다 — 저장 단위는
            // 라디안이다.** 근거 셋:
            //  · `rotateVec2(v, r)` 가 `cos(r)`/`sin(r)` 에 **인자를 그대로** 넣는다(common.h:28-32).
            //  · 어노테이션이 `"range":[0,6.28]` 이다(도였다면 [0,360]). 그리고 같은 계열 유니폼의
            //    `"default"` 가 `3.14159265358` / `3.141593` — π 를 기본 방향으로 저작한 것이지
            //    3.14도가 아니다.
            //  · `"conversion":"rad2deg"` 어노테이션이 존재한다 = "이 **라디안** 값을 도로 **표시**하라".
            //    에디터 JS 의 `degreeConverter` 도 `$formatters=toDegrees` / `$parsers=toRadians` 로
            //    표시만 도이고 저장은 라디안이다.
            // 종전 동작은 UI 90°(=1.5708 저장)를 1.5708**도**(≈0.0274 rad)로 읽어 89.4° 어긋났다.
            let a = f("direction", 0)
            return [-sin(a), cos(a), f("speed", 5), f("scale", 200), f("strength", 0.1), f("perspective", 0)]
        case "shake":
            // 단순화: flow/noise combo 없이 시간 기반 흔들림. amp/speed 키는 게이트서 확인.
            // F-X8: WE shake.frag g_Speed 실 기본값은 1(구코드 폴백 5 는 실물과 5배 어긋남 — 코퍼스
            // 실측: speed 미지정 씬이 상례). bounds(g_Bounds, 기본 "0 1")는 문턱 리매핑
            // (offset = saturate((offset-bounds.x)/(bounds.y-bounds.x)))용 슬롯 추가 — P[2]/P[3].
            let amp: Float = c["amplitude"]?.first ?? c["amount"]?.first ?? c["strength"]?.first ?? 0.006
            let spd: Float = c["speed"]?.first ?? c["roughness"]?.first ?? 1
            let bounds = c["bounds"] ?? [0, 1]
            let boundsLo = bounds.count > 0 ? bounds[0] : 0
            let boundsHi = bounds.count > 1 ? bounds[1] : 1
            return [amp, spd, boundsLo, boundsHi]
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
            int mode = int(P[5] + 0.5);
            // BLENDMODE(P[5]) 은 WE 전체 enum(0..32). applyBlending 이 opacity(P[4]*mask) 로 믹스.
            c.rgb = applyBlending(mode, c.rgb, float3(P[1], P[2], P[3]), P[4] * m);
            // F672: WE tint.frag `#if BLENDMODE == 0 → albedo.a = 1.0`(Normal 모드는 출력 불투명 강제).
            if (mode == 0) { c.a = 1.0; }
            return c;
        }
        """,
        "waterripple": """
        fragment float4 ef_main(EOut in [[stage_in]], texture2d<float> fb [[texture(0)]],
                                texture2d<float> normalMap [[texture(1)]], texture2d<float> mask [[texture(2)]],
                                constant float* P [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::repeat);
            constexpr sampler sc(filter::linear, address::clamp_to_edge);
            // P[0]=time, P[1]=strength, P[2]=scale, P[3]=scrollSpeed(≈animationspeed).
            // F412: 노멀맵 미바인드 폴터는 중립 (128,128,255)(SceneRendererResources) — 흰색이면
            // 언팩 후 n=(1,1,1) 이라 마스크 유효 영역이 상시 대각 변위.
            // F-X8: WE waterripple.frag `texCoord += normal.xy * g_Strength * g_Strength * mask` — 강도
            // 제곱(선형이면 기본값에서 10배 과대 변위, 자매 waterwaves 는 이미 제곱 적용 — 파일내 정합).
            float2 nUV = in.uv * P[2] + float2(P[0] * P[3], P[0] * P[3] * 0.5);
            float3 n = normalMap.sample(s, nUV).rgb * 2.0 - 1.0;
            float maskV = mask.sample(sc, in.uv).r;
            float2 distort = n.xy * (P[1] * P[1]) * maskV;
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
                                texture2d<float> noiseTex [[texture(1)]], texture2d<float> maskTex [[texture(2)]],
                                constant float* P [[buffer(0)]], constant float& audio [[buffer(1)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            constexpr sampler sr(filter::linear, address::repeat);
            // P[0]=time, P[1]=speed,P[2]=phase,P[3]=amount,P[4]=power,P[5]=threshLo,P[6]=threshHi,
            //   P[7]=blendmode,P[8]=pulseColor,P[9]=pulseAlpha,P[10]=audioMode,P[11..13]=tintLo,P[14..16]=tintHi,
            //   P[17]=noiseSpeed,P[18]=noiseAmount,P[19]=MASK콤보.
            float4 c = fb.sample(s, in.uv);
            float pulse;
            if (P[10] > 0.5) {
                pulse = audio;  // audioResponse (CPU 계산, buffer1)
            } else {
                // F674: WE pulse.frag `sin(g_Time*g_PulseSpeed + (g_PulsePhase - 1.57079632679))` —
                // phase 는 radian [0,6.282] 직접(구 (P[2]-0.25)×2π 는 phase=0 에서만 일치했다).
                pulse = smoothstep(P[5], P[6], sin(P[0] * P[1] + (P[2] - 1.57079632679)) * 0.5 + 0.5) * P[3];
                // F830: WE pulse.frag:39-41 — noise = tex(g_Texture1, (t/12, t/36)*noiseSpeed).r * noiseAmount,
                // pulse 에 합산 후 power(WE 순서: 합산→pow). 시간 스크롤 UV 라 repeat 랩(util/noise.tex-json
                // clampuvs:false). AUDIOPROCESSING==0 분기 안(WE 와 동일 — 오디오 모드는 noise/power 미적용).
                pulse += noiseTex.sample(sr, float2(P[0] * 0.08333333, P[0] * 0.02777777) * P[17]).r * P[18];
                pulse = pow(max(pulse, 0.0), P[4]);
            }
            float3 albedo = c.rgb;
            if (P[8] > 0.5) {
                albedo = applyBlending(int(P[7] + 0.5), c.rgb * float3(P[11], P[12], P[13]), c.rgb * float3(P[14], P[15], P[16]), pulse);
            }
            float a = c.a;
            if (P[9] > 0.5) { a *= pulse; }
            float4 outC = float4(albedo, a);
            // F831: WE pulse.frag:53-56 MASK 콤보 — albedo = mix(sample, albedo, mask.r)(알파 포함 믹스).
            // mask UV 는 vert 의 a_TexCoord*(res.z/res.x, res.w/res.y) 인데 Waple 엔진 texRes 규약이
            // SIMD4(w,h,w,h)(Resources texRes)라 비율=1 → in.uv 와 동일(tint/opacity 손포팅과 같은 근거).
            if (P[19] > 0.5) {
                float m = maskTex.sample(s, in.uv).r;
                outC = mix(c, outC, m);
            }
            // straight 출력(설계 §3): premultiply 는 최종 컴포지트(f_main)에서 1회.
            // WE pulse.frag:58 — rgb max(0) 클램프는 mask 믹스 후(WE 순서 그대로).
            return float4(max(float3(0.0), outC.rgb), outC.a);
        }
        """,
        "shake": """
        fragment float4 ef_main(EOut in [[stage_in]], texture2d<float> fb [[texture(0)]],
                                texture2d<float> flow [[texture(1)]], texture2d<float> mask [[texture(2)]],
                                constant float* P [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            // P[0]=time, P[1]=amplitude, P[2]=speed, P[3]=bounds.x, P[4]=bounds.y. F265: WE shake.frag:82
            // `texCoordOffset = offset*g_Amp*g_Amp*flowMask` 대조 — 진폭 제곱(선형이면 5~10배 과대) +
            // flow map(g_Texture1, buildHandPortEffect 가 미바인드 시 중립(0.498,0.498)로 폴백 —
            // WE 기본 util/noflow 와 정합해 flowMask≈0) 방향 구동. 시간 오실레이터(offset 스칼라)는
            // WE 의 friction/DIRECTION 콤보 전체까진 미포팅 — sin(t) 로 단순화(정성적 근사).
            // F-X8: WE shake.frag:56 `offset = saturate((offset - v_Bounds.x) * v_Bounds.y)`(v_Bounds.y =
            // 1/(bounds.y-bounds.x)) 문턱 리매핑 — [0,1] 오실레이터 값을 bounds 구간으로 재배치한 뒤
            // DIRECTION==0 관례대로 *2-1 로 부호 복원. bounds=[0,1](기본)이면 항등(sin(t) 그대로, 무회귀).
            float m = mask.sample(s, in.uv).r;
            float t = P[0] * P[2];
            float2 flowMask = (flow.sample(s, in.uv).rg - float2(0.498, 0.498)) * 2.0;
            float raw = sin(t) * 0.5 + 0.5;
            float span = P[4] - P[3];
            float inv = span == 0.0 ? 0.0 : 1.0 / span;
            float remapped = saturate((raw - P[3]) * inv) * 2.0 - 1.0;
            float2 off = remapped * (P[1] * P[1]) * flowMask * m;
            return fb.sample(s, in.uv + off);
        }
        """,
    ]
}
