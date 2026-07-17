import Metal
import simd
import WapleCore

/// HDR bloom(#22) 파라미터 — `hdr && bloom` 씬(코퍼스 8) 전용. LDR bloom 과 별개 레시피.
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
/// - 합성 = PS 29925 의 화면 순효과 `saturate(base+bloom)` (EOTF 디코드는 WE sRGB-뷰 스왑체인
///   인코드와 상쇄 — 합성 셰이더 주석의 실측 근거 참조). **ACES/톤커브 없음**
///   (Ultra float 경로 포함 5중 확증 — 이 경로에서 hdrPost 를 통째로 대체한다; hdrPost 도 이제 동일 클램프).
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
        guard [source, quarter, eighth, bloom].allSatisfy({
                  $0.textureType == .type2D && $0.pixelFormat == .rgba16Float
              }),
              destination.textureType == .type2D,
              destination.pixelFormat == .bgra8Unorm,
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

        var horizontalStep = SIMD2<Float>(1 / Float(quarter.width), 0)
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
        float3 c = max((
            source.sample(linearClamp, in.uv + t * float2(-1.5, -1.5)).rgb +
            source.sample(linearClamp, in.uv + t * float2( 1.5, -1.5)).rgb +
            source.sample(linearClamp, in.uv + t * float2(-1.5,  1.5)).rgb +
            source.sample(linearClamp, in.uv + t * float2( 1.5,  1.5)).rgb
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

    // PS 29925(라이브 Ultra 캡처) = C=base+bloom → EOTF_sRGB 디코드 → sRGB-뷰 스왑체인이 하드웨어
    // 재인코드. 디코드·인코드가 상쇄돼 **화면 순효과 = saturate(base+bloom)**. Waple 타깃은 비-sRGB
    // bgra8(디스플레이/PNG 가 값을 그대로 소비)이라 순효과만 이식한다 — 디코드만 옮기면 이중 감마
    // (실측 3299228616: EOTF 이식 p50 0.047 vs WE 골든 0.18, 클램프 p50 ≈0.19 — 골든 정합).
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
        return float4(saturate(C), base.a);
    }
    """
}
