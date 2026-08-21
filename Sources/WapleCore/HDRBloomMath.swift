import Foundation
import simd

/// HDR 블룸 피라미드의 **순수 산술** — WE `wallpaper64.exe` 실측을 그대로 옮긴 것.
///
/// 왜 `WapleCore` 에 있는가
/// -----------------------
/// 종전에는 이 함수 전부가 `HDRBloomPyramidPass`(WapleRender)의 `static` 이었다. 그 모듈은
/// `import Metal` 이라 **리눅스에서 한 줄도 테스트가 안 됐고**(`scripts/dev/linux-render-typecheck.sh`
/// 는 타입만 본다), 유일한 검증 수단이 macOS 전용 `Tests/WapleRenderTests/HDRBloomTests.swift` 였다.
/// 탭 반경(`b19db5b`)·레벨 수(W-25) 두 이탈이 전부 이 산술에서 나왔으므로 본체를 여기로 옮긴다.
/// `HDRBloomPyramidPass` 쪽에는 **얇은 위임만** 남아 기존 호출부와 macOS 테스트가 그대로 돈다.
/// 선례: `SceneLightSlotBudget`(`4eb61f1`) · `PointerHit`(`aebf586`).
///
/// 실물 경로(imagebase `0x140000000`)
/// ---------------------------------
///  · `Composite::allocateTargets` `0x14017f1b0`–`0x14017fa6f` — 레벨 버퍼 생성, N 산출, 강도 정규화
///  · `Composite::drawBloomChain`   `0x140183610`–`0x140183a61` — `g_RenderVar0` 기저·패스별 배율·BICUBIC 선택
///
/// 정본: `spec/engine/hdr-bloom.json` · `spec/engine/uniform-feed.json` ·
/// 문서: `docs/re/scene-postprocessing.md` §5.
public enum HDRBloomMath {

    // MARK: - 레벨 수

    /// 피라미드 레벨 수 `N` — **WE 와 같은 min(W,H) 기준**이다.
    ///
    /// WE 실물(재확인 2026-08-21, 직접 디스어셈블):
    /// ```
    /// 0x14017f1ec  cmovg r15d, edx      ; W' = max(W, 2)
    /// 0x14017f200  cmovg r12d, r8d      ; H' = max(H, 2)
    /// 0x14017f352  mov [rsi+0x310c], 0  ; 생성단수 = 0
    /// 0x14017f363  cmovg r14d, r12d     ; d = min(W', H')      ← **min 이다**
    /// 0x14017f370  loop:
    /// 0x14017f376    sar eax, 1         ; d /= 2
    /// 0x14017f37d    jle 0x14017f51a    ; d <= 0 이면 이 단은 만들지 않는다(있던 것은 해제)
    /// 0x14017f383    inc [rsi+0x310c]   ; 생성단수 += 1
    /// 0x14017f541  cmp ebx, 8 ; jl loop ; 루프 상한 8
    /// ```
    /// 즉 **생성단수 = `min(8, floor(log2(min(W,H))))`**.
    ///
    /// 실효 `N` 은 저작값과의 min 을 한 번 더 거친다(`0x14017f7f7`–`0x14017f84c`, 결과 `obj+0x3108`):
    /// ```
    /// 0x14017f7f7  movd  xmm1, [rsi+0x310c]   ; 생성단수
    /// 0x14017f7ff  movd  xmm0, [rbx+0x3d4]    ; general.bloomhdriterations
    /// 0x14017f815  comiss xmm1, xmm0          ; xmm2 = min(생성단수, iterations)
    /// 0x14017f822  comiss xmm8, xmm2          ; xmm8 = 1.0
    /// 0x14017f82d  mov [rsi+0x3108], eax      ; 하한 1
    /// 0x14017f841  mov [rsi+0x3108], eax      ; 그 외
    /// ```
    /// = `N = max(1, min(bloomhdriterations, 생성단수))`.
    ///
    /// **[2026-08-21 정정]** 종전 구현은 `w > 1 || h > 1` 로 돌아 **max 기준**
    /// `max(1, floor(log2(max(W,H))))` 를 셌다(`ceil` 이라고 적혀 있었으나 실제로는 `floor` 다 —
    /// 독립 검산으로 확인했다). 두 산식은 **두 변이 서로 다른 2의 거듭제곱 구간에 있고 짧은 변이
    /// 256 미만일 때** 갈린다. `N` 은 `normalizedStrength` 의 지수 `max(N,2)-2` 로 직행하므로
    /// 틀리면 반경이 아니라 **강도가 통째로** 틀린다.
    ///
    /// 도달(실측):
    ///  · 풀스크린 실사용(짧은 변 ≥ 256)에서는 양쪽 다 상한 8 — **차이 0**.
    ///  · 이 리포의 골든 썸네일 파이프라인은 **256×144**(`SnapshotPipeline.thumbW/thumbH`)라
    ///    `8 → 7` 로 갈린다. 64×32 계열 렌더 테스트도 `6 → 5` 다.
    ///
    /// 여기 클램프는 `max(1, ·)` 이고 WE 는 `max(2, ·)` 지만 결과는 전 정수 입력에서 같다
    /// (`min(W,H) ≤ 1` 이면 양쪽 다 1단).
    public static func levelCount(requested: Int, sourceWidth: Int, sourceHeight: Int) -> Int {
        var count = 0
        var d = min(max(1, sourceWidth), max(1, sourceHeight))
        while count < 8 {
            d /= 2
            if d <= 0 { break }
            count += 1
        }
        return min(max(requested, 1), max(count, 1))
    }

    // MARK: - 강도 정규화

    /// WE 가 추출 단계에 먹이는 **정규화된 블룸 강도**.
    ///
    /// `g_BloomStrength = bloomhdrstrength / (bloomhdrscatter^(max(N,2)-2) + 1)`
    ///
    /// 이 나눗셈은 업샘플 가중과 **한 쌍**이다. WE 의 업샘플 머티리얼에는 저작 `scatter` 가
    /// 그대로 들어가 레벨이 깊어질수록 기여가 `scatter^k` 로 커지는데, 그 발산을 추출 강도에서
    /// 미리 나눠 상쇄한다. 둘 중 하나만 옮기면 화면이 백화되거나(가중만) 블룸이 좁아진다(정규화만).
    ///
    /// 근거: `powf(scatter, max(N,2)-2)`(`0x14017f85e`) → `+1.0`(`0x14017f86b`, 상수
    /// `[0x140492704]`) → `divss`(`0x14017f88f`) → `setMaterialParam(mat, "bloomstrength", …)`
    /// (`0x14017f89b`). 업샘플 머티리얼에는 scatter 원본이 그대로 실린다
    /// (`0x14017f967` / `0x14017fa40`). 정본 `spec/engine/uniform-feed.json`
    /// (`engine.uniformFeed.wapleGaps.hdrBloomStrengthNormalization`)이 같은 식을 담는다.
    ///
    /// 기본 저작값(scatter 1.619, N 8)에서 분모는 약 19.01 → 실효 강도 약 0.105.
    /// `max(N,2)-2` 클램프 때문에 N=1 과 N=2 는 같은 값(분모 2)을 낸다.
    public static func normalizedStrength(strength: Float, scatter: Float, levels: Int) -> Float {
        let exponent = Float(max(levels, 2) - 2)
        return strength / (powf(scatter, exponent) + 1)
    }

    // MARK: - 탭 오프셋 (`Composite::drawBloomChain` 0x140183610–0x140183948)
    //
    // 피라미드 전 패스가 쓰는 `g_RenderVar0` 의 **기저**는 `(1/W, 1/H, −1/W, −1/H)` 이고
    // `W`=obj+0x84 · `H`=obj+0x88 = **풀 프레임버퍼** 크기다 — 그 패스의 소스 크기가 아니다
    // (`0x14018367c` `divss xmm9,xmm1` · `0x140183690` · `0x140183694` · `0x140183699` →
    //  4성분 저장 `0x1401836a0`–`0x1401836ba`). 각 패스는 여기에 **정수 배율**만 곱한다.
    //
    // 그래서 같은 UV 오프셋이 패스마다 다른 "소스 텍셀 수" 가 된다. level[i] 폭이 `W >> (i+1)`
    // 이므로:
    //   추출(i=0)         배율 1          소스 = 풀(W)       → ±1.0 소스 텍셀 (4×4 박스)
    //   다운샘플 i≥1      배율 1 << i     소스 = level[i−1]  → ±1.0 소스 텍셀 (4×4 박스)
    //   업샘플 소스레벨 i 배율 2 << (i−1) 소스 = level[i]    → ±0.5 소스 텍셀 (2×2 박스)
    // `hdr_downsample.frag:22` 의 `texSize = 0.5 / g_RenderVar0.xy` 항등식은 **업샘플에서만**
    // 성립한다(BICUBIC 콤보가 `hdr_upsample_cubic` 하나에만 걸려 있어 조건이 항상 맞는다).
    // 그 항등식을 다운샘플에 일반화하면 반경이 정확히 절반이 된다(`b19db5b` 가 되돌린 결함).

    /// 정수 배율을 실제 UV 오프셋으로. `baseWidth`/`baseHeight` = **풀 프레임버퍼** 크기.
    public static func tapOffsetUV(scale: Int, baseWidth: Int, baseHeight: Int) -> SIMD2<Float> {
        SIMD2(Float(scale) / Float(max(1, baseWidth)), Float(scale) / Float(max(1, baseHeight)))
    }

    /// 추출(level 0)·다운샘플(level ≥ 1) 배율. 추출은 기저를 배율 없이 저장하고(`0x1401836a0`),
    /// 다운샘플 i 는 `mov eax,1 ; shl eax,cl`(cl=i)로 만든 `1 << i` 를 곱한다
    /// (`0x14018374a`–`0x14018375c`).
    public static func downsampleTapScale(level: Int) -> Int { 1 << max(0, level) }

    /// 업샘플(소스 레벨 i → 목적 레벨 i−1) 배율 — `mov eax,2 ; shl eax,cl`(cl=i−1) =
    /// `2 << (i−1)` (`0x140183856`–`0x14018386b`). 숫자는 `1 << i` 와 같지만 소스가 한 단
    /// 더 작은 level[i] 라 반경이 절반이 된다 — **배율이 아니라 소스 레벨이 차이를 만든다**.
    public static func upsampleTapScale(sourceLevel: Int) -> Int { 2 << max(0, sourceLevel - 1) }

    /// 검산용 — UV 오프셋을 **소스 텍셀 수**로 환산한다. 소스 폭이 2의 거듭제곱이면 다운샘플
    /// 계열은 정확히 1.0, 업샘플은 0.5 가 나온다(W-1 의 판정식).
    public static func tapRadiusInSourceTexels(offsetUV: Float, sourceWidth: Int) -> Float {
        offsetUV * Float(max(1, sourceWidth))
    }

    /// 업샘플 단의 BICUBIC 선택 — WE `0x140183810`–`0x140183822`:
    /// `mov ecx,0x31a8`(hdr_upsample_cubic) · `eax = [obj+0x3108] − 2` · `cmp ebp, eax` ·
    /// `cmovl rcx, r15`(r15=0x31a0 = hdr_upsample). `ebp` 는 업샘플의 **소스 레벨**이고
    /// N−1 → 1 로 내려가므로 `소스레벨 ≥ N−2` 인 **가장 깊은 두 단**만 큐빅이다.
    public static func upsampleUsesBicubic(sourceLevel: Int, levelCount: Int) -> Bool {
        sourceLevel >= levelCount - 2
    }

    /// WE `g_BloomBlendParams` 패킹(`0x14017f8bc`–`0x14017f900`):
    /// `K = threshold × feather`(`0x14017f8cd`) · `P = (threshold, threshold − K, 2K,
    /// 0.25 / (K + 1e-5))`. 상수는 `0.25`=`[0x14049268c]` · `1e-5`=`[0x1404925ec]`.
    /// 음수 knee 방어 `max(K, 0)` 만 Waple 추가(WE 는 음수 feather 를 막지 않는다).
    public static func blendParams(threshold: Float, feather: Float) -> SIMD4<Float> {
        let knee = max(threshold * feather, 0)
        return SIMD4(threshold, threshold - knee, 2 * knee, 0.25 / (knee + 1e-5))
    }
}
