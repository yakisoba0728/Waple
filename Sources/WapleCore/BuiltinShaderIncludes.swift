import Foundation

/// 내장 셰이더 인클루드 — **의미가 실물로 확정된 것만** 제공한다(마지막 폴백; pkg/base-assets 의 실제
/// 헤더가 있으면 그쪽이 우선). common.h 는 의도적으로 제공하지 않는다: 헬퍼(rotateVec2 등) 의미를 검증할
/// 실물 없이 추측 구현하면 "조용히 틀린 그림"이 된다(설계 2026-07-02 §의도적 미구현).
///
/// common_blending.h 는 예외 — BLENDMODE enum/함수 의미가 실물 대조로 확정됐고(메모리 2026-06-25,
/// EffectShaders.applyBlending MSL 포트와 동일 소스-오브-트루스), 실물 tint/pulse GLSL 이 이것만으로 풀린다.
public enum BuiltinShaderIncludes {
    public static func lookup(_ name: String) -> String? {
        switch name {
        case "common_blending.h": return commonBlending
        default: return nil
        }
    }

    /// WE common_blending.h 의 전 모드 포트(GLSL, 본 번역기 방언) — 수치 정본은 WapleRender/BlendMSL.swift
    /// (실물 헤더 1:1 MSL)이며 식 단위로 일치를 유지한다(select ↔ mix/step 관용 차이만 존재).
    /// 모드: 0=Normal, 1=Darken, 2=Multiply, 3=ColorBurn, 4=Subtract, 5=Min, 6=Lighten, 7=Screen, 8=ColorDodge,
    /// 9=Add, 10=Max, 11=Overlay, 12=SoftLight, 13=HardLight, 14=VividLight, 15=LinearLight, 16=PinLight,
    /// 17=HardMix, 18=Difference, 19=Exclusion, 20=Substract(=4), 21=Reflect, 22=Glow, 23=Phoenix, 24=Average,
    /// 25=Negation, 26=Hue, 27=Saturation, 28=Color, 29=Luminosity, 30=Tint, 31=A+B·o, 32=mix(A, A+A·B, o).
    /// 5/10/31 은 opacity 미적용(return), 나머지는 mix(A, r, o).
    static let commonBlending = """
    vec3 BlendOverlayEx(vec3 b, vec3 s) {
        return mix(2.0 * b * s, 1.0 - 2.0 * (1.0 - b) * (1.0 - s), step(vec3(0.5), b));
    }
    vec3 BlendColorBurnEx(vec3 b, vec3 s) {
        return mix(max(1.0 - (1.0 - b) / max(s, vec3(0.00001)), vec3(0.0)), vec3(0.0), step(s, vec3(0.0)));
    }
    vec3 BlendColorDodgeEx(vec3 b, vec3 s) {
        return mix(min(b / max(1.0 - s, vec3(0.00001)), vec3(1.0)), vec3(1.0), step(vec3(1.0), s));
    }
    vec3 BlendSoftLight(vec3 b, vec3 s) {
        return mix(2.0 * b * s + b * b * (1.0 - 2.0 * s),
                   sqrt(max(b, vec3(0.0))) * (2.0 * s - 1.0) + 2.0 * b * (1.0 - s),
                   step(vec3(0.5), s));
    }
    vec3 BlendLinearLightEx(vec3 b, vec3 s) {
        return mix(max(b + 2.0 * s - 1.0, vec3(0.0)), b + 2.0 * (s - 0.5), step(vec3(0.5), s));
    }
    vec3 BlendVividLightEx(vec3 b, vec3 s) {
        return mix(BlendColorBurnEx(b, 2.0 * s), BlendColorDodgeEx(b, 2.0 * (s - 0.5)), step(vec3(0.5), s));
    }
    vec3 BlendPinLightEx(vec3 b, vec3 s) {
        return mix(min(b, 2.0 * s), max(b, 2.0 * (s - 0.5)), step(vec3(0.5), s));
    }
    vec3 BlendHardMixEx(vec3 b, vec3 s) {
        return step(vec3(0.5), BlendVividLightEx(b, s));  // select(0,1,v>=0.5) == step(0.5,v)
    }
    vec3 BlendReflectEx(vec3 b, vec3 s) {
        return mix(min(b * b / max(1.0 - s, vec3(0.00001)), vec3(1.0)), vec3(1.0), step(vec3(1.0), s));
    }
    vec3 rgb2hsl(vec3 c) {
        // F676 정합(BlendMSL we_rgb2hsl 과 식 단위 일치): WE 원본의 `#ifdef HDR color = saturate(color)`
        // — 단일 소스라 무조건 적용(LDR ≤1 에선 항등). HDR >1 입력의 모드 26-29 경로별 색 차이 봉인(감사 V06).
        c = saturate(c);
        vec3 hsl;
        float fmin = min(min(c.r, c.g), c.b);
        float fmax = max(max(c.r, c.g), c.b);
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
    float hue2rgb(float f1, float f2, float hue) {
        if (hue < 0.0) hue += 1.0; else if (hue > 1.0) hue -= 1.0;
        if ((6.0 * hue) < 1.0) return f1 + (f2 - f1) * 6.0 * hue;
        if ((2.0 * hue) < 1.0) return f2;
        if ((3.0 * hue) < 2.0) return f1 + (f2 - f1) * ((2.0 / 3.0) - hue) * 6.0;
        return f1;
    }
    vec3 hsl2rgb(vec3 hsl) {
        if (hsl.y == 0.0) return vec3(hsl.z);
        float f2 = hsl.z < 0.5 ? hsl.z * (1.0 + hsl.y) : (hsl.z + hsl.y) - (hsl.y * hsl.z);
        float f1 = 2.0 * hsl.z - f2;
        return vec3(hue2rgb(f1, f2, hsl.x + (1.0 / 3.0)),
                    hue2rgb(f1, f2, hsl.x),
                    hue2rgb(f1, f2, hsl.x - (1.0 / 3.0)));
    }
    vec3 ApplyBlending(int mode, vec3 A, vec3 B, float o) {
        vec3 r = B;
        if (mode == 1) { r = min(A, B); }
        else if (mode == 2) { r = A * B; }
        else if (mode == 3) { r = BlendColorBurnEx(A, B); }
        else if (mode == 4) { r = max(A + B - 1.0, vec3(0.0)); }
        else if (mode == 5) { return min(A, B); }
        else if (mode == 6) { r = max(A, B); }
        else if (mode == 7) { r = 1.0 - (1.0 - A) * (1.0 - B); }
        else if (mode == 8) { r = BlendColorDodgeEx(A, B); }
        else if (mode == 9) { r = min(A + B, vec3(1.0)); }
        else if (mode == 10) { return max(A, B); }
        else if (mode == 11) { r = BlendOverlayEx(A, B); }
        else if (mode == 12) { r = BlendSoftLight(A, B); }
        else if (mode == 13) { r = BlendOverlayEx(B, A); }
        else if (mode == 14) { r = BlendVividLightEx(A, B); }
        else if (mode == 15) { r = BlendLinearLightEx(A, B); }
        else if (mode == 16) { r = BlendPinLightEx(A, B); }
        else if (mode == 17) { r = BlendHardMixEx(A, B); }
        else if (mode == 18) { r = abs(A - B); }
        else if (mode == 19) { r = A + B - 2.0 * A * B; }
        else if (mode == 20) { r = max(A + B - 1.0, vec3(0.0)); }
        else if (mode == 21) { r = BlendReflectEx(A, B); }
        else if (mode == 22) { r = BlendReflectEx(B, A); }
        else if (mode == 23) { r = min(A, B) - max(A, B) + 1.0; }
        else if (mode == 24) { r = (A + B) / 2.0; }
        else if (mode == 25) { r = 1.0 - abs(1.0 - A - B); }
        else if (mode == 26) { vec3 h = rgb2hsl(A); r = hsl2rgb(vec3(rgb2hsl(B).x, h.y, h.z)); }
        else if (mode == 27) { vec3 h = rgb2hsl(A); r = hsl2rgb(vec3(h.x, rgb2hsl(B).y, h.z)); }
        else if (mode == 28) { vec3 h = rgb2hsl(B); r = hsl2rgb(vec3(h.x, h.y, rgb2hsl(A).z)); }
        else if (mode == 29) { vec3 h = rgb2hsl(A); r = hsl2rgb(vec3(h.x, h.y, rgb2hsl(B).z)); }
        else if (mode == 30) { r = max(A.x, max(A.y, A.z)) * B; }
        else if (mode == 31) { return A + B * o; }
        else if (mode == 32) { return mix(A, A + A * B, o); }
        return mix(A, r, o);
    }
    """
}
