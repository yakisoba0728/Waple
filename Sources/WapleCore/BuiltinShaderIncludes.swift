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

    /// WE common_blending.h 의 확정-의미 서브셋(GLSL, 본 번역기 방언). 모드: 0=Normal, 1=Darken, 2=Multiply,
    /// 3=ColorBurn, 4=Subtract, 5=Min, 6=Lighten, 7=Screen, 8=ColorDodge, 9=Add, 10=Max, 11=Overlay,
    /// 12=SoftLight, 13=HardLight, 30=Tint, 31=A+B·o, 32=mix(A, A+A·B, o).
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
        else if (mode == 30) { r = max(A.x, max(A.y, A.z)) * B; }
        else if (mode == 31) { return A + B * o; }
        else if (mode == 32) { return mix(A, A + A * B, o); }
        return mix(A, r, o);
    }
    """
}
