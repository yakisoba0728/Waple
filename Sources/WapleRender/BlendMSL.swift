/// WE common_blending.h 의 `ApplyBlending` 전 모드 MSL 포트 — 실물 헤더(base-assets) 공식 1:1.
/// EffectShaders(틴트/펄스)와 QuadShaders(레이어 colorBlendMode 합성)가 공유하는 단일 소스.
/// 참고: f-변형 매크로가 클램프 없는 곳(LinearDodge 등)은 원본대로 두고 bgra8 쓰기 클램프에 맡긴다.
///
/// ## AJ-B1 도메인 확정 (2026-08-21) — **정수 범위는 0…32, 33개가 전부다**
///
/// 근거는 셋이고 서로 독립이다.
///
/// 1. **셰이더 원본** `assets/shaders/common_blending.h` 의 `ApplyBlending` 은 `#if BLENDMODE == n`
///    을 **n=1…32 로 정확히 32개** 갖고, 어느 것도 안 맞으면 마지막 줄
///    `return mix(A, BlendNormal(A,B), opacity)` 로 떨어진다. 즉 모드는 런타임 값이 아니라
///    **전처리기 콤보**이고, 함수 인자 `blendMode` 는 본문에서 한 번도 읽히지 않는다.
/// 2. **에디터 드롭다운** `wallpaperui.exe`(설치본 `bin/`, 12,742,640 B) 파일오프셋
///    `0x00ad2ee0`–`0x00ad33b7` 에 `isgrouptitle`
///    두 개(`ui_editor_blending_group_native` / `…_group_emulated`)와 **`ui_editor_blending_*`
///    라벨 33개**가 한 블록으로 놓여 있다(33 = 0…32). 같은 블록의 값 리터럴은
///    `2 3 4 5 6 9 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32` 이고
///    빠진 `0 1 7 8 10` 은 12MB 바이너리 어디서든 접히는 짧은 리터럴이다.
///    **라벨↔값 짝은 이 풀 순서로 짓지 마라** — 공통 브리프 함정 #16 그대로 한 칸씩 밀린다.
///    이름은 아래 표처럼 `common_blending.h` 의 매크로에서 읽는 게 유일하게 안전하다.
/// 3. **파서** `colorBlendMode` 는 리플렉션 int 주입기 `0x1401a4930` 이 태그 1/2 는 `mov`,
///    태그 3 은 `cvttsd2si`(`0x1401a4962`)로 **생짜 int32** 를 멤버 `+0x32c` 에 꽂는다.
///    **범위 검사도 클램프도 없다.** 생성자 기본값은 0(`0x1401e6a14` `mov [rbx+0x32c], eax`, eax=0).
///
/// ### 범위 밖 정수는 "클램프" 가 아니라 "Normal 로 흘러내림" 이다
///
/// `colorBlendMode` 는 머티리얼 `combos.BLENDMODE` 로 **그대로** 실린다
/// (`0x140206be0`·`0x1401ebc96`·`0x140257911` 세 자리 전건 `movsxd` 후 대입, 상한 검사 없음).
/// 그러면 셰이더는 `#define BLENDMODE 99` 로 컴파일되고 `ApplyBlending` 이 마지막 줄로 떨어져
/// **BlendNormal = `mix(A,B,opacity)`**, 즉 보통 알파 합성이 된다. 음수도 같다.
/// `SceneDocument.blendModeVal` 이 범위 밖을 32 로 자르지 않고 **0 으로 떨어뜨리는** 종전 선택이
/// 이것으로 실측 뒷받침된다(0 도 결국 같은 알파 합성이다 — 불투명 배경에서 화면 동일).
///
/// ### 0 과 31 은 이 표에 **도달하지 않는다**(WE 의 native 고속 경로)
///
/// 머티리얼 합성기 세 자리가 전건 같은 코드를 갖는다:
/// ```
/// mov  esi, [rdi+0x32c]      ; colorBlendMode          (0x140206be0)
/// test esi, esi / je  →0
/// cmp  esi, 0x1f / jne keep  ; 31 이면
/// mov  esi, r12d             ;   combos.BLENDMODE = 0
/// ```
/// 그리고 드로우 직전에 머티리얼의 blending 열거값을 갈아끼운다:
/// ```
/// cmp  dword [rbx+0x32c], 0x1f   (0x1401ea096, 사본 0x140208786)
/// jne  …
/// mov  al, 2                     ; 2 = additive
/// mov  [rdi+0x1f0], al           ; 머티리얼 blending (docs/re/material-blend.md §4.1)
/// ```
/// 즉 **31 = "하드웨어 additive"**(`SRC_ALPHA`/`ONE`), **0 = "머티리얼 blending 그대로"** 이고
/// 둘 다 `_rt_FullFrameBuffer` 를 **샘플하지 않는다**(`0x1401e8ef2`/`0x1401e8f44` 의 같은
/// `0 또는 31` 검사가 프레임버퍼 요청을 건너뛴다). 1…30·32 만 `genericimage2.frag` 의
/// `#if BLENDMODE` 블록으로 들어가 화면을 다시 샘플한다.
///
/// Waple 은 31 도 `f_blend`(스냅샷 경로)로 처리하는데 **수식은 같다** —
/// `case 31: A + B*o` = `dst + src.rgb*src.a` = additive 하드웨어 블렌드이고, 알파는 `d.a` 를
/// 되쓰므로 WE 의 `WriteMask 7`(알파 미기록)과 결과가 같다. 다르지 않은 대신 **비싸다**
/// (레이어마다 acc 전체 blit). 코퍼스 도달이 커서 최적화 후보다 — 보고서 참조.
///
/// ### 모드 표 (이름은 `common_blending.h` 매크로에서 읽었다)
///
/// | n | 식 | n | 식 |
/// | ---: | --- | ---: | --- |
/// | 0 | Normal `mix(A,B,o)`(fallthrough) | 17 | HardMix |
/// | 1 | Darken `min` | 18 | Difference |
/// | 2 | Multiply | 19 | Exclusion |
/// | 3 | ColorBurn | 20 | Substract(=4, 문자 그대로 중복) |
/// | 4 | Substract `max(A+B-1,0)` | 21 | Reflect |
/// | 5 | `min(A,B)` — **opacity 무시** | 22 | Glow `Reflect(B,A)` |
/// | 6 | Lighten `max` | 23 | Phoenix |
/// | 7 | Screen | 24 | Average |
/// | 8 | ColorDodge | 25 | Negation |
/// | 9 | Add `min(A+B,1)` | 26 | Hue |
/// | 10 | `max(A,B)` — **opacity 무시** | 27 | Saturation |
/// | 11 | Overlay | 28 | Color |
/// | 12 | SoftLight | 29 | Luminosity |
/// | 13 | HardLight `Overlay(B,A)` | 30 | Tint |
/// | 14 | VividLight | 31 | `A + B*o` — **opacity 믹스 없음** |
/// | 15 | LinearLight | 32 | `mix(A, A+A*B, o)` |
/// | 16 | PinLight | | |
///
/// ### 코퍼스 도달 (범위 라벨 필수)
///
/// * **워크샵 코퍼스**(정본 `spec/corpus/scene-schema.json` `scene.objects.colorBlendMode` 인용,
///   이 컨테이너에 코퍼스가 없어 재측정 안 했다): image 오브젝트 **782건/83씬** ·
///   text **41건/14씬**, 범위 밖 **0건**. 최다는 **31(image 447 · text 12)** 이고 그다음이
///   0(132/18) · 11(45/4) · 6(37) · 2(29) · 1(16) · 22(12) · 7(11) · 32(10) · 9(9) 순이다.
///   image 미도달 모드는 5·10·13·14·17·20·25·26·29, text 도달은 0·11·12·17·24·28·31 뿐이다.
/// * **동봉 WEAssets**(json 1698): `objects[].colorBlendMode` 42건/32파일 **전건 0**.
///   `passes[].combos.BLENDMODE` 10건/8파일 = {0:6, 2:2, 9:1, 23:1}.
/// * **설치본**(json 2143): `colorBlendMode` 66건/36파일 = {0:60, 11:5, 12:1}.
///   `passes[].combos.BLENDMODE` 12건/10파일 = {0:6, 2:2, 9:1, 12:1, 23:1, 30:1}.
/// * 셰이더 `[COMBO]` 선언의 `default` 실측(설치본 `*.frag`/`*.vert` 전수,
///   `"type":"imageblending"` **58줄**): 0×14 · 2×10 · 9×10 · 12×6 · 31×8 · 32×5 · 30×3 · 22×2
///   — 전부 0…32 안이다.
///
/// ### 알파 규약
///
/// WE 는 **straight(비-프리멀티) 알파**로 셰이더를 내고 블렌드 상태가 `SRC_ALPHA` 를 곱한다
/// (정본 `renderState.alpha.straightNotPremultiplied`). `genericimage2.frag` 의 BLENDMODE 블록도
/// `ApplyBlending(BLENDMODE, screen.rgb, gl_FragColor.rgb, gl_FragColor.a)` 로 **양변 다 straight**
/// 이고, 끝에서 `gl_FragColor.a = screen.a` 로 알파를 배경 것으로 되돌린다.
/// 그래서 이 표의 A·B 는 **절대 프리멀티가 아니다** — `QuadShaders.f_blend` 가 `f_main` 과 달리
/// `c.rgb` 에 알파를 곱하지 않고 넘기는 것이 정본이고, dst 로 쓰는 acc 스냅샷은 프리멀티 누적이지만
/// 누적 RGB 식이 `src*a + dst*(1-a)` 로 WE 프레임버퍼와 **동일**해 A 는 그대로 맞는다.
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
