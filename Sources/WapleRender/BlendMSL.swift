/// WE common_blending.h 의 ApplyBlending 전 모드(1-32) MSL 포트 — 실물 헤더(base-assets) 공식 1:1.
/// EffectShaders(틴트/펄스)와 QuadShaders(레이어 colorBlendMode 합성)가 공유하는 단일 소스.
/// 참고: f-변형 매크로가 클램프 없는 곳(LinearDodge 등)은 원본대로 두고 bgra8 쓰기 클램프에 맡긴다.
enum BlendMSL {
    static let source = """
    inline float3 we_overlay(float3 b, float3 s) { return select(2.0*b*s, 1.0-2.0*(1.0-b)*(1.0-s), b >= 0.5); }
    // F542(F-74): 경계 등호를 GLSL 내장본(BuiltinShaderIncludes.commonBlending step)과 일치 — colorburn 은
    // s≤0(step(s,0)), colordodge 는 s≥1(step(1,s))에서 상수 선택(HDR 슈퍼브라이트/음수 틴트 발산 해소).
    //
    // [의도적 이탈 — 유지 확정 2026-08-01] WE common_blending.h:114,115,119 는 **정확 비교**다:
    //   (blend == 1.0) ? blend : min(base/(1.0-blend), 1.0)
    // 여기는 범위 비교(s >= 1.0)라 s in [0,1] 에서는 동일하고 s>1 또는 s<0 에서만 갈린다.
    // s=2.0 이면 WE 는 min(base/(1-2), 1) = -base 로 **음수**를 내고 여기는 1.0 으로 클램프한다.
    // A/B(release) 화면 영향 0. 단 [0,1] 밖 입력을 만드는 표본이 HDR 1종뿐이라 근거는 얇다.
    //
    // 참고: max(s,1e-5) 엡실론 자체는 **무해하다** — 발동 구간이 이미 min(...,1)/max(...,0) 으로
    // 클램프되는 영역이라 결과가 같다. 진짜 이탈은 가드 조건의 범위 쪽이다.
    // 근거·A/B·재검토 조건: spec/engine/deviations.json (deviation.D3, deviation.decision)
    inline float3 we_colorburn(float3 b, float3 s) { return select(max(1.0-(1.0-b)/max(s,1e-5), 0.0), float3(0.0), s <= 0.0); }
    inline float3 we_colordodge(float3 b, float3 s) { return select(min(b/max(1.0-s,1e-5), 1.0), float3(1.0), s >= 1.0); }
    inline float3 we_softlight(float3 b, float3 s) { return select(2.0*b*s + b*b*(1.0-2.0*s), sqrt(max(b,0.0))*(2.0*s-1.0)+2.0*b*(1.0-s), s >= 0.5); }
    inline float3 we_linearlight(float3 b, float3 s) { return select(max(b+2.0*s-1.0, 0.0), b+2.0*(s-0.5), s >= 0.5); }
    inline float3 we_vividlight(float3 b, float3 s) { return select(we_colorburn(b, 2.0*s), we_colordodge(b, 2.0*(s-0.5)), s >= 0.5); }
    inline float3 we_pinlight(float3 b, float3 s) { return select(min(b, 2.0*s), max(b, 2.0*(s-0.5)), s >= 0.5); }
    inline float3 we_hardmix(float3 b, float3 s) { return select(float3(0.0), float3(1.0), we_vividlight(b, s) >= 0.5); }
    inline float3 we_reflect(float3 b, float3 s) { return select(min(b*b/max(1.0-s,1e-5), 1.0), float3(1.0), s >= 1.0); }

    // RGB↔HSL (common_blending.h 1:1 — Hue/Saturation/Color/Luminosity 모드용)
    inline float3 we_rgb2hsl(float3 c) {
        // F676: WE common_blending.h RGBToHSL 의 `#ifdef HDR color = saturate(color)` — Waple 은
        // LDR/HDR 단일 소스라 무조건 적용(LDR UNORM ≤1 에선 항등이라 묵시 무차). HDR >1 입력의
        // HSL 왜곡 봉인(colorBlendMode 26-29, 현 코퍼스 HDR 활성 0건 잠복).
        c = saturate(c);
        float3 hsl;
        float fmin = min(min(c.r, c.g), c.b), fmax = max(max(c.r, c.g), c.b);
        float delta = fmax - fmin;
        hsl.z = (fmax + fmin) / 2.0;
        if (delta == 0.0) { hsl.x = 0.0; hsl.y = 0.0; }
        else {
            hsl.y = hsl.z < 0.5 ? delta / (fmax + fmin) : delta / (2.0 - fmax - fmin);
            float dR = (((fmax - c.r) / 6.0) + (delta / 2.0)) / delta;
            float dG = (((fmax - c.g) / 6.0) + (delta / 2.0)) / delta;
            float dB = (((fmax - c.b) / 6.0) + (delta / 2.0)) / delta;
            if (c.r == fmax) hsl.x = dB - dG;
            else if (c.g == fmax) hsl.x = (1.0 / 3.0) + dR - dB;
            else hsl.x = (2.0 / 3.0) + dG - dR;
            if (hsl.x < 0.0) hsl.x += 1.0; else if (hsl.x > 1.0) hsl.x -= 1.0;
        }
        return hsl;
    }
    inline float we_hue2rgb(float f1, float f2, float hue) {
        if (hue < 0.0) hue += 1.0; else if (hue > 1.0) hue -= 1.0;
        if ((6.0 * hue) < 1.0) return f1 + (f2 - f1) * 6.0 * hue;
        if ((2.0 * hue) < 1.0) return f2;
        if ((3.0 * hue) < 2.0) return f1 + (f2 - f1) * ((2.0 / 3.0) - hue) * 6.0;
        return f1;
    }
    inline float3 we_hsl2rgb(float3 hsl) {
        if (hsl.y == 0.0) return float3(hsl.z);
        float f2 = hsl.z < 0.5 ? hsl.z * (1.0 + hsl.y) : (hsl.z + hsl.y) - (hsl.y * hsl.z);
        float f1 = 2.0 * hsl.z - f2;
        return float3(we_hue2rgb(f1, f2, hsl.x + (1.0/3.0)),
                      we_hue2rgb(f1, f2, hsl.x),
                      we_hue2rgb(f1, f2, hsl.x - (1.0/3.0)));
    }

    // applyBlending(mode, A=base(dst), B=blend(src), o=opacity) — common_blending.h ApplyBlending 1:1.
    inline float3 applyBlending(int mode, float3 A, float3 B, float o) {
        float3 r;
        switch (mode) {
            case 1:  r = min(A, B); break;                     // Darken
            case 2:  r = A * B; break;                         // Multiply
            case 3:  r = we_colorburn(A, B); break;            // ColorBurn
            case 4:  r = max(A + B - 1.0, 0.0); break;         // Subtract
            case 5:  return min(A, B);                         // Min (no opacity)
            case 6:  r = max(A, B); break;                     // Lighten
            case 7:  r = 1.0 - (1.0 - A) * (1.0 - B); break;   // Screen
            case 8:  r = we_colordodge(A, B); break;           // ColorDodge
            case 9:  r = min(A + B, 1.0); break;               // Add
            case 10: return max(A, B);                         // Max (no opacity)
            case 11: r = we_overlay(A, B); break;              // Overlay
            case 12: r = we_softlight(A, B); break;            // SoftLight
            case 13: r = we_overlay(B, A); break;              // HardLight
            case 14: r = we_vividlight(A, B); break;           // VividLight
            case 15: r = we_linearlight(A, B); break;          // LinearLight
            case 16: r = we_pinlight(A, B); break;             // PinLight
            case 17: r = we_hardmix(A, B); break;              // HardMix
            case 18: r = abs(A - B); break;                    // Difference
            case 19: r = A + B - 2.0 * A * B; break;           // Exclusion
            case 20: r = max(A + B - 1.0, 0.0); break;         // Substract(=4)
            case 21: r = we_reflect(A, B); break;              // Reflect
            case 22: r = we_reflect(B, A); break;              // Glow
            case 23: r = min(A, B) - max(A, B) + 1.0; break;   // Phoenix
            case 24: r = (A + B) / 2.0; break;                 // Average
            case 25: r = 1.0 - abs(1.0 - A - B); break;        // Negation
            case 26: { float3 h = we_rgb2hsl(A); r = we_hsl2rgb(float3(we_rgb2hsl(B).x, h.y, h.z)); break; }  // Hue
            case 27: { float3 h = we_rgb2hsl(A); r = we_hsl2rgb(float3(h.x, we_rgb2hsl(B).y, h.z)); break; }  // Saturation
            case 28: { float3 h = we_rgb2hsl(B); r = we_hsl2rgb(float3(h.x, h.y, we_rgb2hsl(A).z)); break; }  // Color
            case 29: { float3 h = we_rgb2hsl(A); r = we_hsl2rgb(float3(h.x, h.y, we_rgb2hsl(B).z)); break; }  // Luminosity
            case 30: r = max(A.x, max(A.y, A.z)) * B; break;   // Tint
            case 31: return A + B * o;                         // A+B·o (no mix)
            case 32: r = A + A * B; break;                     // mix(A, A+A·B, o)
            default: r = B; break;                             // 0 = Normal
        }
        return mix(A, r, o);
    }

    """
}
