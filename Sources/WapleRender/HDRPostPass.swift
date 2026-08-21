import Metal
import WapleCore

/// float(rgba16Float) HDR 누적 버퍼를 표시 포맷(bgra8)으로 확정하는 최종 포스트 패스. 최종 blit 대체.
///
/// 압축 커브 = saturate 클램프. **WE 에 톤매핑 연산자는 없다** — 동봉 셰이더 137파일 전수에
/// `ACES`/`Reinhard`/`Uncharted`/`filmic`/`Hable`/`tonemap`/`whitepoint`/`exposure`/`luminance`/
/// `histogram` 이 **0건**이고(유일한 `aces` 1건은 `HLSL/dx11playlisttransition.vert:87` 의 오타
/// 주석 `"Move pieaces up and down"`), 바이너리 문자열에도 `gamma`/`tonemap`/`exposure` 가
/// ASCII·UTF-16LE 양쪽 0건이다. 곧 어깨도 발끝도 화이트포인트도 존재하지 않는다.
/// 최종 식은 LDR `scene+bloom`(`combine.frag:13-15`) 또는 HDR `saturate(lin(scene+bloom))`
/// (`combine_hdr.frag:43`) — `saturate` 는 곡선이 아니라 **클램프**다. >1 은 1.0(순백은 WE-충실
/// 결과이며 결함 아님), [0,1] 저역은 항등. 종전 ACES filmic 은 저역까지 곡선변형해 이탈했다(제거).
///
/// **EOTF(sRGB) 디코드 `lin()` 미이식 — 근거 정정(W-20).** 종전 주석은 *"WE 는 sRGB-뷰 스왑체인이라
/// 하드웨어 인코드와 상쇄되는 쌍"* 을 근거로 들었는데 **그 전제는 실측으로 반증됐다**:
/// 포맷 enum→DXGI 사상 28 arm 에 `_SRGB` 값이 0건이고(`Format::toDXGI` `0x1400d2a20`),
/// `DXGI_SWAP_CHAIN_DESC` 를 채우는 유일한 자리가 `R8G8B8A8_UNORM`(28) 이다(`0x140008146`).
/// 상쇄해 줄 하드웨어 인코드는 애초에 없다. 그래도 결론은 그대로인데, 근거가 둘로 갈린다:
///  1. WE 의 `lin()` 은 **`hdr:true` 경로에만 있다**(`combine_hdr.frag` · `passthroughsrgb.frag`,
///     머티리얼 로드 게이트 `0x14017fb45`–`0x14017fb9f`). 358 씬 중 354 씬은 `combine.frag`
///     (감마 변환 없음)이거나 최종 패스 자체가 없다 — LDR 에서 디코드 없음이 **정확**하다.
///  2. `hdr:true` 4 씬에 대해서는 골든 실측(EOTF 이식 p50 0.047 vs WE 골든 0.18, 클램프 p50 ≈0.19)이
///     디코드 미적용 쪽을 지지한다. 정적 측정과 골든이 갈리는 지점은 `docs/re/tonemapping.md`
///     §2.6 [미해결 C] 로 남아 있다.
/// 전문: `docs/re/tonemapping.md` §1.1·§1.2·§2.4·§3·§9 W-20.
///
/// exposure 유니폼 = **WE 에 대응물이 없는 Waple 확장 노브**다(W-27). WE 의 밝기 축은 정적
/// 두 개뿐이고(`g_RenderVar0.x` 디스플레이 질의값 · 앱 설정 `wec_brs`), 씬 내용에 반응하는
/// 자동노출·휘도적응은 없다. 기본 1.0 = 항등이라 무해하지만 정본으로 오인하면 안 된다.
final class HDRPostPass {
    private let pipeline: MTLRenderPipelineState
    /// 노출 배율(씬 밝기 튜닝). 클램프 입력에 곱한다(기본 1.0 = 항등).
    var exposure: Float = 1

    /// outputFormat 은 최종 LDR 타깃 포맷(drawable/캡처 = .bgra8Unorm). 파이프라인 생성 실패 시 nil.
    init?(device: MTLDevice, outputFormat: MTLPixelFormat) {
        guard let lib = try? WapleProfiler.compile(HDRPostPass.source, { try device.makeLibrary(source: HDRPostPass.source, options: nil) }),
              let vf = lib.makeFunction(name: "hdrpost_v"),
              let ff = lib.makeFunction(name: "hdrpost_f") else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vf
        pd.fragmentFunction = ff
        pd.colorAttachments[0].pixelFormat = outputFormat
        guard let ps = try? WapleProfiler.pipe({ try device.makeRenderPipelineState(descriptor: pd) }) else { return nil }
        self.pipeline = ps
    }

    /// float `src`(HDR 누적) 를 saturate 클램프해 LDR `dst` 로 그린다. 풀스크린 삼각형 — 최종 blit 대체.
    /// 현재 command buffer 에 자체 render encoder 를 open/close(호출부는 그 전에 씬 encoder 를 닫아야 한다).
    /// F539(F-71): 인코더 생성 실패를 삼키지 않고 false 반환 — 미기록 dst present/캡처를 호출부가 스킵 가능.
    @discardableResult
    func encode(cb: MTLCommandBuffer, src: MTLTexture, dst: MTLTexture) -> Bool {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .dontCare   // 풀스크린 삼각형이 전 픽셀 덮음
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(src, index: 0)
        var exp = exposure
        enc.setFragmentBytes(&exp, length: MemoryLayout<Float>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        return true
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    // 풀스크린 삼각형(vertex buffer 불요). uv 는 텍스처 공간(y-down) 정합 — blit 대체라 상하반전 금지:
    // NDC top(y=+1) → uv.y=0(텍스처 top). vid0=(-1,-1), vid1=(-1,3), vid2=(3,-1).
    vertex VOut hdrpost_v(uint vid [[vertex_id]]) {
        float2 p = float2(vid == 2 ? 3.0 : -1.0, vid == 1 ? 3.0 : -1.0);
        VOut o;
        o.pos = float4(p, 0.0, 1.0);
        o.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
        return o;
    }
    fragment float4 hdrpost_f(VOut in [[stage_in]],
                              texture2d<float> hdrTex [[texture(0)]],
                              constant float &exposure [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);    // WE combine.frag 는 linear 샘플러 가정
        float4 c = hdrTex.sample(s, in.uv);
        // WE 최종 = saturate 클램프(셰이더 137파일 전수에 톤커브 식별자 0건 — 상단 주석).
        // >1 → 1.0(순백), [0,1] 저역은 항등(ACES 는 저역도 곡선변형). exposure = Waple 확장 노브.
        // F675: 최종 알파 1.0 강제 — c.a 통과는 캡처 PNG 투명 픽셀(디스플레이는 알파 무시라 묵시 무차).
        return float4(saturate(c.rgb * exposure), 1.0);
    }
    """
}
