import Foundation
import simd

/// LDR(=`hdr:false`) 블룸 3패스의 **순수 산술** — WE `wallpaper64.exe`(imagebase `0x140000000`)
/// 와 동봉 셰이더 평문 실측을 그대로 옮긴 것.
///
/// 왜 `WapleCore` 에 있는가
/// -----------------------
/// `LDRBloomPass`(WapleRender)는 `import Metal` 이라 리눅스에서 **타입만** 검사된다
/// (`scripts/dev/linux-render-typecheck.sh`). 최근 이탈 두 건(F670 추출 탭 반경 ±1.5→±1,
/// F671 수평 블러 스트라이드 1→2 quarter-텍셀)이 전부 이 산술에서 나왔으므로, 값 산출은 여기에
/// 두고 `LDRBloomPass` 에는 인코딩만 남긴다. 선례: `HDRBloomMath` · `PointerHit`.
///
/// 실물 경로(전부 직접 디스어셈블해 확인 — 남의 표를 베끼지 않았다)
/// --------------------------------------------------------------
///  · `Composite::allocateTargets` `0x14017f1b0`–`0x14017fa6f`
///     - RT 이름: `_rt_4FrameBuffer` `0x14017f5c6` → 슬롯 `[composite+0x30a0]`(`0x14017f618`),
///       `_rt_8FrameBuffer` `0x14017f62a` → `[+0x30a8]`(`0x14017f65c`),
///       `_rt_Bloom` `0x14017f66e` → `[+0x30b0]`(`0x14017f686`).
///     - LDR 파라미터 피드 `0x14017f994`–`0x14017fa44`(게이트 `0x14017f99b`: 머티리얼 슬롯
///       `[+0x3160]` 또는 씬 포인터가 null 이면 통째로 스킵).
///  · `Composite::drawBloomChain` `0x140183610`–`0x140183a61`, LDR 분기 `0x140183949`–`0x140183a5d`
///    (진입 게이트 `0x140183618` `test dword [rcx+0x128], 0x2000` = `hdr` 비트13, `je` → LDR).
///  · `Scene::Scene` `0x140186c90`–`0x1401872ba` — 저작 생략 시 기본값.
///
/// **비트13 소비 지점은 넷이다**(전부 같은 플래그, 같은 비트):
/// 포맷 선택 `0x14017f328`+`0x14017f33d` · 파라미터 급전 `0x14017f7cb`(`je 0x14017f994` → LDR 피드) ·
/// 머티리얼 로드 `0x14017fb79` · 드로우 루프 `0x140183618`. 비트13 을 **세우는** 자리는 아직
/// 열려 있다 — `[composite+0x128]` 은 `0x140115b5d`–`0x140115b67` 의 범용
/// `flags = (set | flags) & ~clear` 헬퍼로만 갱신되고, 즉치 `0x2000` 을 그 필드에 or/and 하는
/// 자리는 이미지 전수 스캔에서 0건이다(정본 `spec/engine/tonemapping.json`
/// `engine.bloom.pathDivergence.openQuestion`).
///
/// **[확정] LDR 체인은 8비트 UNORM 위에서 돈다.**
/// 컴포지트가 만드는 컬러 타깃의 포맷은 한 자리에서 정해진다 — `0x14017f317 mov edi,1`(LDR) ·
/// `0x14017f323 mov ecx,0xf`(HDR) · `0x14017f33d cmovne edi,ecx` · `0x14017f340 mov [rbp+0x130],edi`.
/// enum 1 → DXGI 28 `R8G8B8A8_UNORM`, enum 0xf → DXGI 10 `R16G16B16A16_FLOAT`
/// (`sub_1400d2a20` 점프표 `0x1400d2aa4`). 그 값이 `_rt_FullFrameBuffer`·`_rt_4FrameBuffer`·
/// `_rt_8FrameBuffer`·`_rt_Bloom` 넷에 같이 실린다(`0x14017f5a3` · `0x14017f5ea` 외).
/// → 추출·블러 결과가 **매 패스 [0,1] 로 잘린다.** `bloomstrength` 2.0 을 곱해 1 을 넘긴 부분은
/// 그 자리에서 소실된다. 이식하며 이 버퍼를 float 로 올리면 "정밀도 개선" 처럼 보이지만
/// WE 보다 밝아진다 — 올리지 마라. (뎁스 인자는 넷 다 enum `0x1b` = 없음.)
///
/// **[확정] LDR 은 HDR 과 달리 강도 정규화가 없다.** HDR 경로는
/// `bloomhdrstrength / (powf(scatter, max(N,2)-2) + 1)`(`0x14017f85e`–`0x14017f893`)로 나눠서
/// 넣지만, LDR 경로는 씬 저작값을 **그대로** 머티리얼 상수로 넘긴다:
/// ```
/// 0x14017f9b0  movss xmm0, [scene+0x3bc]      ; general.bloomstrength
/// 0x14017f9cd  lea   rdx, "bloomstrength"     ; 0x14048e380,  r9d=1 (float 1개)
/// 0x14017f9d4  call  0x14017e920              ; Material::setConstant(mat, name, &val, n)
/// 0x14017f9f7  movss xmm0, [scene+0x3c0]      ; general.bloomthreshold
/// 0x14017f9ea  lea   rdx, "bloomthreshold"    ; 0x14048e3a8,  r9d=1
/// 0x14017fa28  movsd xmm0, [scene+0x3d8]      ; general.bloomtint.xy
/// 0x14017fa30  mov   eax,  [scene+0x3e0]      ; general.bloomtint.z
/// 0x14017fa1b  lea   rdx, "bloomtint"         ; 0x14048e368,  r9d=3
/// ```
/// **[2026-08-21 정정]** `0x14017fa30` 은 종전 `0x14017fa2f` 로 **한 바이트 앞**이었다  [VA-정정]
/// (`0x14017fa28 movsd` 의 한복판 +7). `scripts/re/va_citations.py` 전수 대조로 잡았다.
///
/// 셋 다 rcx = `[composite+0x3160]` = **추출(quarter) 머티리얼 한 곳뿐**이다. 블러 두 패스
/// (`[+0x3170]`·`[+0x3178]`)에는 어떤 상수도 실리지 않는다.
///
/// 기본값(`Scene::Scene` 즉시값): `bloomstrength` 2.0(`0x1401870ac`),
/// `bloomthreshold` 0.6499999761581421(`0x1401870b7`), `bloomtint` (1,1,1).
/// 셰이더 애노테이션도 같다 — `downsample_quarter_bloom.frag:6-8`.
public enum LDRBloomMath {

    // MARK: - 저작값 기본치

    /// `general.bloomstrength` 기본값 — `Scene::Scene` `0x1401870ac` 즉시값 `0x40000000`.
    public static let defaultStrength: Float = 2
    /// `general.bloomthreshold` 기본값 — `0x1401870b7` 즉시값 `0x3f266666`.
    public static let defaultThreshold: Float = 0.65
    /// `general.bloomtint` 기본값. 동봉+설치본 358 씬 중 저작 154건이 **전건** `"1 1 1"` 이다.
    public static let defaultTint = SIMD3<Float>(1, 1, 1)

    // MARK: - 탭 기하

    /// `g_TexelSize` = **풀해상도 프레임버퍼 1텍셀**(UV). LDR 체인 3패스가 전부 이 값을 쓴다.
    ///
    /// **근거(셰이더 평문만으로 확정 — 바이너리 불필요, 함정 #7)**:
    ///  1. *목적지 텍셀이 아니다.* `downsample_quarter.vert:12-15` 와
    ///     `downsample_quarter_linear.vert:11-14` 는 **완전히 같은 4탭 박스**인데(두 `.frag` 도
    ///     동일한 `합/4`), 전자는 `g_Texture0Texel.xy * 2`, 후자는 `g_TexelSize * 2` 를 쓴다.
    ///     두 머티리얼의 텍스처0 은 둘 다 `_rt_FullFrameBuffer` 이고 목적지는 1/4 이다. 곧 저자는
    ///     `g_TexelSize` 와 `g_Texture0Texel.xy` 를 **호환으로 썼다** — 목적지 해석이면 두 셰이더가
    ///     4배 다른 결과를 낸다.
    ///  2. *소스 텍셀도 아니다.* 소스 해석이면 X 블러(소스=1/4)의 σ 는 풀해상도 80텍셀,
    ///     Y 블러(소스=1/8)는 160텍셀이 되어 **분리형 가우시안이 비등방**이 된다.
    ///     풀해상도 해석에서만 두 축이 8 풀텍셀 스트라이드로 같아진다.
    ///  · `drawBloomChain` LDR 분기는 탭 유니폼을 **한 번도 쓰지 않는다**(`0x140183949`–`0x140183a5d`
    ///    전체에 `[rsi+0xb8..0xc4]` 스토어 0건 — HDR 분기의 `0x1401836a0`–`0x1401836ba` 와 대조).
    ///    곧 LDR 의 `g_TexelSize` 는 엔진 공통 유니폼 바인더가 채운다.
    ///
    /// [미해결] 엔진 바인더가 그 값을 만드는 **바이너리 지점**은 특정하지 못했다. 위 두 논거는
    /// 셰이더 평문 기반이다.
    public static func fullFrameTexelUV(width: Int, height: Int) -> SIMD2<Float> {
        SIMD2(1 / Float(max(1, width)), 1 / Float(max(1, height)))
    }

    /// 추출 패스(`downsample_quarter_bloom`) 4탭의 대각 오프셋 기저 = 풀해상도 ±1텍셀.
    ///
    /// `downsample_quarter_bloom.vert:11-14` = `a_TexCoord ± g_TexelSize`. 목적지(1/4) 픽셀 중심은
    /// 소스 텍셀좌표 `4i+2` 이므로 ±1 소스텍셀 두 점(`4i+1`, `4i+3`)의 bilinear 는 각각 소스텍셀
    /// `4i..4i+1`, `4i+2..4i+3` 을 0.5:0.5 로 섞는다 — 대각 4탭 평균이 **4×4 박스 정확 평균**이다.
    /// (구 ±1.5 는 코너 4텍셀 점샘플이라 풋프린트 내측 2×2 를 통째로 놓쳤다 — F670.)
    public static func extractTapOffsetUV(sourceWidth: Int, sourceHeight: Int) -> SIMD2<Float> {
        fullFrameTexelUV(width: sourceWidth, height: sourceHeight)
    }

    /// 수평(X) 13탭 블러의 탭 스트라이드(UV). 소스 = 1/4 버퍼, 목적지 = 1/8 버퍼.
    ///
    /// `downsample_eighth_blur_v.vert:12` `float localTexel = g_TexelSize.x * 8.0`
    /// = 풀해상도 8텍셀 = **quarter 2텍셀**. quarter 폭만 알면 되므로 그것으로 표현한다.
    /// (F671 전에는 quarter 1텍셀이라 합성 σ 가 WE 대비 ~21% 좁았다.)
    public static func horizontalStepUV(quarterWidth: Int) -> SIMD2<Float> {
        SIMD2(2 / Float(max(1, quarterWidth)), 0)
    }

    /// 수직(Y) 13탭 블러의 탭 스트라이드(UV). 소스 = 목적지 = 1/8 버퍼.
    ///
    /// `blur_h_bloom.vert:12` `float localTexel = g_TexelSize.y * 8.0`
    /// = 풀해상도 8텍셀 = **eighth 1텍셀**. X 와 같은 8 풀텍셀이라 두 축이 등방이다.
    public static func verticalStepUV(eighthHeight: Int) -> SIMD2<Float> {
        SIMD2(0, 1 / Float(max(1, eighthHeight)))
    }

    /// 13탭 가중치(중앙 → 바깥). `downsample_eighth_blur_v.frag:7-19` ·
    /// `blur_h_bloom.frag:7-19` 두 파일이 **같은 7개 값**을 쓴다.
    /// `common_blur.h` 의 `blur13`(7탭 bilinear 최적화)과는 **다른 커널**이니 섞지 마라.
    public static let blur13HalfWeights: [Float] = [
        0.171834, 0.156756, 0.119007, 0.075189, 0.039533, 0.017298, 0.006299
    ]

    /// 위를 좌우 대칭으로 편 13개 — `[w6 … w1, w0, w1 … w6]`.
    public static var blur13Weights: [Float] {
        let leading: [Float] = Array(blur13HalfWeights.dropFirst().reversed())
        return leading + blur13HalfWeights
    }

    // MARK: - 추출 산술 (CPU 정본)

    /// `downsample_quarter_bloom.frag:15-25` 를 그대로 옮긴 것. 입력은 **4탭 박스 평균 이후**의 색.
    ///
    /// ```glsl
    /// float scale = max(max(albedo.x, albedo.y), albedo.z);
    /// albedo *= saturate(scale - g_BloomThreshold);
    /// float grayscale = dot(vec3(0.2989, 0.5870, 0.1140), albedo);
    /// float sat = 1.0;
    /// albedo = -grayscale * sat + albedo * (1.0 + sat);      // = 2*albedo - grayscale
    /// gl_FragColor = vec4(max(CAST3(0), albedo * g_BloomStrength * g_BloomTint), 1.0);
    /// ```
    /// `sat` 은 셰이더에 **리터럴 1.0 으로 박혀 있다**(유니폼이 아니다) — 그래서 `2*c - gray` 로
    /// 접힌다. 임계 게이트는 `saturate(max−T)` 라 **비율이 아니라 초과분 자체**가 감쇠 계수다.
    public static func extract(
        boxAverage rgb: SIMD3<Float>,
        threshold: Float,
        strength: Float,
        tint: SIMD3<Float>
    ) -> SIMD3<Float> {
        let scale: Float = max(rgb.x, max(rgb.y, rgb.z))
        let gate: Float = min(max(scale - threshold, 0), 1)
        let gated: SIMD3<Float> = rgb * gate
        let gray: Float = 0.2989 * gated.x + 0.5870 * gated.y + 0.1140 * gated.z
        let saturated: SIMD3<Float> = 2 * gated - SIMD3(repeating: gray)
        let scaled: SIMD3<Float> = saturated * strength * tint
        return SIMD3(max(scaled.x, 0), max(scaled.y, 0), max(scaled.z, 0))
    }

    /// 최종 합성 — `combine.frag:10-15` 는 **순수 가산**이다(감마 변환도 톤커브도 없다).
    /// 클램프는 셰이더가 아니라 `R8G8B8A8_UNORM` 타깃이 한다.
    public static func composite(scene: SIMD3<Float>, glow: SIMD3<Float>) -> SIMD3<Float> {
        scene + glow
    }
}
