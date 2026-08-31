import Metal
import simd
import WapleCore

/// HDR bloom(#22) 파라미터 — `hdr && bloom` 씬(설치본 assets+projects 186 중 3) 전용.
/// LDR bloom 과 별개 레시피.
/// `strength` 는 실효값(마운트에서 `HDRBloomPass.strengthScale` 캘리브 적용 후) — 패스는 그대로 소비.
struct HDRBloomParameters: Equatable {
    let strength: Float
    let threshold: Float
    /// knee = threshold × feather (feather 단독 아님 — 윈도우 L1 라이브 cbuffer 확증, SYNTHESIS #22).
    let feather: Float
    let tint: SIMD3<Float>

    static let defaults = HDRBloomParameters(
        strength: 0,
        threshold: 1,
        feather: 0.1,
        tint: SIMD3(1, 1, 1))
}

protocol HDRBloomEncoding {
    func encode(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        quarter: MTLTexture,
        eighth: MTLTexture,
        bloom: MTLTexture,
        destination: MTLTexture,
        parameters: HDRBloomParameters
    ) -> Bool
}

/// WE HDR bloom — float(rgba16Float) 경로의 추출→블러→합성(LDRBloomPass 3-패스 구조 미러).
///
/// 수식 근거(전건 라이브 RenderDoc 확증, `re-audit-2026-07/_SYNTHESIS-F-MASTER.md` #22):
/// - 추출 = PS 29931 soft-knee QuadraticThreshold 축자:
///   `c=max(4tap평균,0)` · `m=max(c.rgb)` · `soft=clamp(m−P.y,0,P.z)²·P.w` · `q=max(m−P.x,soft)`
///   · `out=c·(strength·q/max(m,1e-5))·tint`, `P=(thr, thr−knee, 2·knee, 0.25/(knee+1e-5))`.
/// - 합성 = 화면 순효과 `saturate(base+bloom)`. **ACES/톤커브 없음**
///   (Ultra float 경로 포함 5중 확증 — 이 경로에서 hdrPost 를 통째로 대체한다; hdrPost 도 이제 동일 클램프).
///
///   **[2026-08-21 근거 정정 — W-20]** 종전 이 줄은 *"EOTF 디코드는 WE sRGB-뷰 스왑체인 인코드와
///   상쇄"* 를 근거로 들었는데 **그 전제가 실측으로 반증됐다**: 포맷 enum→DXGI 사상 28 arm 에
///   `_SRGB` 값이 0건이고(`Format::toDXGI` `0x1400d2a20`, 점프표 `0x1400d2aa4`),
///   `DXGI_SWAP_CHAIN_DESC` 를 채우는 유일한 자리가 `R8G8B8A8_UNORM`(28)이다
///   (`0x140008146` → `0x140008172` `CreateSwapChain`). 상쇄해 줄 하드웨어 인코드는 없다.
///   결론(디코드 미이식)은 그대로이고 근거만 둘로 갈린다:
///   ① WE 의 `lin()` 은 `hdr:true` 경로에만 있다 — **설치본 assets/ + projects/ 186 씬**
///      (이름 글롭 `{scene,gifscene}.json`) 중 **183 씬**은 `combine.frag`(감마 변환 없음)이거나
///      최종 패스 자체가 없다(실측 178 + 5).
///   ② **`hdr:true` 3 씬**에 대해서는 아래 합성부 주석의 골든 실측이 디코드 미적용 쪽을 지지한다.
///
///   **[정정 2026-08-30] 종전 이 두 줄의 모집단이 이중계수였다.** 종전 서술:
///   > ① … 동봉+설치본 **358** 씬 중 **354** 씬은 … (실측 **348 + 6**).
///   > ② `hdr:true` **4** 씬에 대해서는 …
///   `5d6cba8b`·`83da9851`(2026-08-28)이 그 358 을 이중계수로 판정하고 정본을 186 ·
///   reach {178,5,3,0} · 고유 HDR 3씬으로 고쳤는데 **이 주석이 안 따라왔다**. 동봉
///   `Sources/WapleRender/Resources/WEAssets/` 는 설치본 `assets/` 의 **사본**이라
///   172 씬을 두 번 센 것이다(358 = 172 + 186). 이 컨테이너에서 직접 센 값이 172 다 —
///   세는 명령: `find Sources/WapleRender/Resources/WEAssets -name 'scene.json' -o
///   -name 'gifscene.json' | wc -l`. 단일 모집단 산술도 그만큼 갈린다:
///   348 = 178+170 · 6 = 5+1 · 4 = 3+1. 재계산: 186 − 3 = **183** = 178 + 5.
///   정본은 `spec/engine/tonemapping.json` 의 `corpusPopulation`·`corpusScenes`·
///   `corpusReach`·`hdrScenesNote` 이고, `ToneMappingCanonTests` 가 186 을 못박는다.
///   **[동기화 2026-08-31]** 같은 수를 인용하던 `HDRPostPass`·`LDRBloomPass`·
///   `LDRBloomMath`·`VolumetricLightPass`·`Mesh3DShaders`와 `docs/re/` 도 단일 모집단
///   186 씬(reach 178/5/3/0, bloomtint 저작 77)으로 함께 고쳤다.
///   전문: `docs/re/tonemapping.md` §1.1·§1.2·§2.6·§9 W-20 ·
///   정본 `spec/engine/tonemapping.json` `engine.tonemap.transferFunctionSites`.
///
/// ponytail: 단일 레벨(1/4 추출→1/8 blur13 h/v→가산 합성 — LDR 선례와 동일 형상). WE 실물은
/// 듀얼-필터 피라미드 `bloomhdriterations`단(실측 8단, 1800×1130→14×8) + 레벨당 ×0.25×scatter
/// additive 업샘플 — 글로우 반경이 골든 대비 가시적으로 좁으면 그때 피라미드로 승격
/// (SceneDocument.bloomHDRIterations/Scatter 가 그 입력, upsample blend state 는 여전히 RE 미결).
final class HDRBloomPass: HDRBloomEncoding {
    /// ★캘리브레이션 노브: 실효 strength = 저작 strength × iterations × strengthScale.
    /// WE 내부값 역산이 아니라(라이브 관측 0.3→0.00461 의 CPU 규칙은 RE 미결 — 단일 관측 일반화 금지)
    /// **골든/작가 출력 대비 2점 실증**: 3299228616(it=8) WE 골든 sat% 3.88 ↔ ×8 캡처 3.76 정합,
    /// 3147346398(it=2) 작가 preview 화염 구조 ↔ ×2 정합(×8 은 블롭화). iterations 비례 = 단일
    /// 레벨이 WE N단 피라미드의 가산 누적 에너지를 단수만큼 보상하는 형태. 피라미드 승격 시 재캘리브 필수.
    static let strengthScale: Float = 1

    private struct ExtractUniforms {
        var sourceTexelSize: SIMD2<Float>
        /// (threshold, threshold−knee, 2·knee, 0.25/(knee+1e-5)) — WE g_BloomBlendParams 패킹 그대로.
        var blendParams: SIMD4<Float>
        /// rgb = tint, w = strength.
        var tintStrength: SIMD4<Float>
    }

    private let extractPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let combinePipeline: MTLRenderPipelineState

    init?(device: MTLDevice) {
        guard let library = try? WapleProfiler.compile(Self.metalSource, { try device.makeLibrary(source: Self.metalSource, options: nil) }),
              let vertex = library.makeFunction(name: "hdrBloomVertex"),
              let extract = library.makeFunction(name: "hdrBloomExtract"),
              let blur = library.makeFunction(name: "hdrBloomBlur"),
              let combine = library.makeFunction(name: "hdrBloomCombine") else {
            return nil
        }

        func makePipeline(_ fragment: MTLFunction, format: MTLPixelFormat) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0]!.pixelFormat = format
            return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: descriptor) }
        }

        // 중간(추출/블러)은 float(>1 보존), 합성만 최종 LDR 타깃(bgra8 — drawable/캡처 공통).
        guard let extractPipeline = makePipeline(extract, format: .rgba16Float),
              let blurPipeline = makePipeline(blur, format: .rgba16Float),
              let combinePipeline = makePipeline(combine, format: .bgra8Unorm) else {
            return nil
        }
        self.extractPipeline = extractPipeline
        self.blurPipeline = blurPipeline
        self.combinePipeline = combinePipeline
    }

    private func makeEncoder(
        commandBuffer: MTLCommandBuffer,
        target: MTLTexture,
        pipeline: MTLRenderPipelineState
    ) -> MTLRenderCommandEncoder? {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return nil
        }
        encoder.setRenderPipelineState(pipeline)
        return encoder
    }

    func encode(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        quarter: MTLTexture,
        eighth: MTLTexture,
        bloom: MTLTexture,
        destination: MTLTexture,
        parameters: HDRBloomParameters
    ) -> Bool {
        // 격리 가드: 이 패스는 float 씬 소스 전용 — LDR(bgra8) 텍스처 유입은 인코드 전 거부(hdrPost 클램프 폴백).
        // 배열 리터럴을 guard 조건 안에 두면 타입체커가 조건 전체와 함께 풀어 185ms 를 태운다 — 지역 상수로 분리.
        let floatInputs: [MTLTexture] = [source, quarter, eighth, bloom]
        guard floatInputs.allSatisfy({
                  $0.textureType == .type2D && $0.pixelFormat == .rgba16Float
              }),
              destination.textureType == .type2D,
              destination.pixelFormat == .bgra8Unorm,
              source !== destination,   // F540(F-72): 자기샘플 거부(LDRBloomPass:96 과 대칭 — 향후 dst float 화 대비)
              quarter !== eighth,
              quarter !== bloom,
              eighth !== bloom,
              source.width == destination.width,
              source.height == destination.height,
              quarter.width == max(1, source.width / 4),
              quarter.height == max(1, source.height / 4),
              eighth.width == max(1, source.width / 8),
              eighth.height == max(1, source.height / 8),
              bloom.width == eighth.width,
              bloom.height == eighth.height else {
            return false
        }

        // WE CPU 패킹 그대로: knee=thr×feather(음수 방어만 추가), .w 는 WE 자체가 +1e-5 가드(knee=0 안전).
        let knee = max(parameters.threshold * parameters.feather, 0)
        var extractUniforms = ExtractUniforms(
            sourceTexelSize: SIMD2(1 / Float(source.width), 1 / Float(source.height)),
            blendParams: SIMD4(parameters.threshold,
                               parameters.threshold - knee,
                               2 * knee,
                               0.25 / (knee + 1e-5)),
            tintStrength: SIMD4(parameters.tint.x, parameters.tint.y, parameters.tint.z,
                                parameters.strength))
        guard let extractEncoder = makeEncoder(
            commandBuffer: commandBuffer,
            target: quarter,
            pipeline: extractPipeline) else {
            return false
        }
        extractEncoder.setFragmentTexture(source, index: 0)
        extractEncoder.setFragmentBytes(
            &extractUniforms,
            length: MemoryLayout<ExtractUniforms>.stride,
            index: 0)
        extractEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        extractEncoder.endEncoding()

        // F671-sweep: LDR 형제(`LDRBloomPass.swift:134`)가 2026-08 에 1 → 2 로 고친 것이
        // 이 자리로 오지 않았다. WE 1차 근거를 직접 재확인했다 —
        // `WEAssets/shaders/downsample_eighth_blur_v.vert:12` 와 `blur_h_bloom.vert:12` 가 둘 다
        // `float localTexel = g_TexelSize.{x,y} * 8.0` 이고, `g_TexelSize` 는 **풀해상도** 텍셀이다.
        // quarter 텍셀 = 풀 4텍셀이므로 8풀텍셀 = **2 quarter-텍셀**. 종전 1 은 정확히 절반이라
        // 글로우가 WE 보다 좁았다.
        //
        // 골든 위험 없음: 이 패스는 **폴백 전용**이다(`SceneRendererFinalizer.swift:31-70` —
        // 8-레벨 피라미드가 먼저 시도되고 성공하면 `return true`). 커밋된 기준선은 피라미드
        // 경로로 떴으므로 이 줄은 그 픽셀에 관여하지 않는다.
        // `strengthScale`(:53) 은 현재 1(항등)이고 **강도** 배수라 이 공간 스트라이드와 별개다.
        // 둘째 블러(`verticalStep`, 아래)는 eighth 1텍셀 = 8 풀텍셀로 원래부터 WE 와 일치한다.
        var horizontalStep = SIMD2<Float>(2 / Float(quarter.width), 0)
        guard let horizontalEncoder = makeEncoder(
            commandBuffer: commandBuffer,
            target: eighth,
            pipeline: blurPipeline) else {
            return false
        }
        horizontalEncoder.setFragmentTexture(quarter, index: 0)
        horizontalEncoder.setFragmentBytes(
            &horizontalStep,
            length: MemoryLayout<SIMD2<Float>>.stride,
            index: 0)
        horizontalEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        horizontalEncoder.endEncoding()

        var verticalStep = SIMD2<Float>(0, 1 / Float(eighth.height))
        guard let verticalEncoder = makeEncoder(
            commandBuffer: commandBuffer,
            target: bloom,
            pipeline: blurPipeline) else {
            return false
        }
        verticalEncoder.setFragmentTexture(eighth, index: 0)
        verticalEncoder.setFragmentBytes(
            &verticalStep,
            length: MemoryLayout<SIMD2<Float>>.stride,
            index: 0)
        verticalEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        verticalEncoder.endEncoding()

        // Destination 은 이 마지막 인코더 전까지 무접촉 — false 반환 시 호출부의 hdrPost(클램프) 폴백이 안전.
        guard let combineEncoder = makeEncoder(
            commandBuffer: commandBuffer,
            target: destination,
            pipeline: combinePipeline) else {
            return false
        }
        combineEncoder.setFragmentTexture(source, index: 0)
        combineEncoder.setFragmentTexture(bloom, index: 1)
        combineEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        combineEncoder.endEncoding()
        return true
    }

    static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct BloomVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex BloomVertexOut hdrBloomVertex(uint vertexID [[vertex_id]]) {
        float2 p = float2(vertexID == 2 ? 3.0 : -1.0,
                          vertexID == 1 ? 3.0 : -1.0);
        BloomVertexOut out;
        out.position = float4(p, 0.0, 1.0);
        out.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
        return out;
    }

    struct ExtractUniforms {
        float2 sourceTexelSize;
        float4 blendParams;    // (thr, thr-knee, 2*knee, 0.25/(knee+1e-5))
        float4 tintStrength;   // rgb=tint, w=strength
    };

    // PS 29931(라이브 확증) — soft-knee QuadraticThreshold 축자.
    fragment float4 hdrBloomExtract(
        BloomVertexOut in [[stage_in]],
        texture2d<float> source [[texture(0)]],
        constant ExtractUniforms &u [[buffer(0)]]
    ) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float2 t = u.sourceTexelSize;
        // F673: ±1텍셀 대각 4탭 — bilinear 결합 시 4×4 풋프린트 전량 커버(LDR F670 과 동일 클래스).
        // WE hdr_downsample 은 2× 단계 피라미드(±0.5텍셀 = 2×2 박스)라 quarter 단일 단계의 동치는
        // ±1텍셀(WE 자체의 full→quarter 다운샘플 downsample_quarter_bloom 과 동일 탭). 구 ±1.5 는
        // 코너 4/16 서브샘플(내측 2×2 누락).
        float3 c = max((
            source.sample(linearClamp, in.uv + t * float2(-1.0, -1.0)).rgb +
            source.sample(linearClamp, in.uv + t * float2( 1.0, -1.0)).rgb +
            source.sample(linearClamp, in.uv + t * float2(-1.0,  1.0)).rgb +
            source.sample(linearClamp, in.uv + t * float2( 1.0,  1.0)).rgb
        ) * 0.25, 0.0);
        float4 P = u.blendParams;
        float m = max(c.r, max(c.g, c.b));
        float soft = clamp(m - P.y, 0.0, P.z);
        soft = soft * soft * P.w;
        float q = max(m - P.x, soft);
        float3 rgb = c * (u.tintStrength.w * q / max(m, 1e-5)) * u.tintStrength.rgb;
        return float4(rgb, 1.0);
    }

    // LDRBloomPass.blur13 그대로(수식 float-safe — 포맷만 rgba16Float).
    float3 blur13(texture2d<float> source, float2 uv, float2 step) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float3 rgb = source.sample(linearClamp, uv).rgb * 0.171834;
        rgb += (source.sample(linearClamp, uv - step * 1.0).rgb +
                source.sample(linearClamp, uv + step * 1.0).rgb) * 0.156756;
        rgb += (source.sample(linearClamp, uv - step * 2.0).rgb +
                source.sample(linearClamp, uv + step * 2.0).rgb) * 0.119007;
        rgb += (source.sample(linearClamp, uv - step * 3.0).rgb +
                source.sample(linearClamp, uv + step * 3.0).rgb) * 0.075189;
        rgb += (source.sample(linearClamp, uv - step * 4.0).rgb +
                source.sample(linearClamp, uv + step * 4.0).rgb) * 0.039533;
        rgb += (source.sample(linearClamp, uv - step * 5.0).rgb +
                source.sample(linearClamp, uv + step * 5.0).rgb) * 0.017298;
        rgb += (source.sample(linearClamp, uv - step * 6.0).rgb +
                source.sample(linearClamp, uv + step * 6.0).rgb) * 0.006299;
        return rgb;
    }

    fragment float4 hdrBloomBlur(
        BloomVertexOut in [[stage_in]],
        texture2d<float> source [[texture(0)]],
        constant float2 &texelStep [[buffer(0)]]
    ) {
        return float4(blur13(source, in.uv, texelStep), 1.0);
    }

    // 화면 순효과 = **saturate(base+bloom)**. Waple 타깃은 비-sRGB bgra8(디스플레이/PNG 가 값을
    // 그대로 소비)이라 순효과만 이식한다 — 디코드만 옮기면 이중 감마가 된다
    // (실측 3299228616: EOTF 이식 p50 0.047 vs WE 골든 0.18, 클램프 p50 ≈0.19 — 골든 정합).
    //
    // [2026-08-21 근거 정정 — W-20] 종전 이 자리는 "EOTF_sRGB 디코드 → sRGB-뷰 스왑체인이
    // 하드웨어 재인코드" 로 상쇄를 설명했는데 **sRGB 뷰도 sRGB 스왑체인도 없다**(위 헤더 참조:
    // `0x1400d2a20` 28 arm 에 `_SRGB` 0건 · `0x140008146` 스왑체인 `R8G8B8A8_UNORM`).
    // 남는 근거는 위 골든 실측과, WE 의 `lin()` 이 `hdr:true` 경로에만 있다는 사실이다.
    //
    // 참고: WE 의 SDR HDR 경로는 `combine_hdr.frag` 에서 `saturate(lin(albedo)) * g_RenderVar0.x`
    // 다. `lin()` 을 건너뛰는 분기(`#if LINEAR == 1`)는 그 콤보를 거는 머티리얼
    // `materials/util/combine_hdr_upsample_linear.json` 의 **경로 문자열이 이미지에 없어**
    // 런타임에 도달하지 않는다 — 곧 WE 쪽에서 디코드가 꺼지는 경우는 없다.
    // ★ACES/필믹 숄더·토우 등 톤커브 없음(5중 확증, "톤맵 곡선없음=saturate클램프") — 이 경로
    // 한정으로 hdrPost 대체(hdrPost 도 이제 동일 saturate 클램프).
    fragment float4 hdrBloomCombine(
        BloomVertexOut in [[stage_in]],
        texture2d<float> source [[texture(0)]],
        texture2d<float> bloom [[texture(1)]]
    ) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float4 base = source.sample(linearClamp, in.uv);
        float3 C = base.rgb + bloom.sample(linearClamp, in.uv).rgb;
        // F675: 최종 알파 1.0 강제(LDR composite 와 동일 규약) — base.a 통과는 캡처 PNG 투명 픽셀
        // (디스플레이 drawable 은 알파 무시라 화면 무차, 위생).
        return float4(saturate(C), 1.0);
    }
    """
}
