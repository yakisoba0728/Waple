import Metal
import simd
import WapleCore

/// WE LDR(`hdr:false`) 블룸의 저작 파라미터. **씬 저작값이 그대로 들어간다** — HDR 경로와 달리
/// 정규화·스케일이 없다(`Composite::allocateTargets` `0x14017f9b0`–`0x14017fa44`, 근거 전문은
/// `WapleCore.LDRBloomMath` 헤더). 셋 다 추출(quarter) 머티리얼 한 곳에만 실린다.
struct LDRBloomParameters: Equatable {
    let strength: Float
    let threshold: Float
    let tint: SIMD3<Float>

    /// `Scene::Scene` 즉시값 — strength `0x1401870ac`(2.0) · threshold `0x1401870b7`(0.65) ·
    /// tint (1,1,1). 셰이더 애노테이션(`downsample_quarter_bloom.frag:6-8`)과도 일치.
    static let defaults = LDRBloomParameters(
        strength: LDRBloomMath.defaultStrength,
        threshold: LDRBloomMath.defaultThreshold,
        tint: LDRBloomMath.defaultTint)
}

protocol LDRBloomEncoding {
    func encode(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        quarter: MTLTexture,
        eighth: MTLTexture,
        bloom: MTLTexture,
        destination: MTLTexture,
        parameters: LDRBloomParameters
    ) -> Bool
}

/// `hdr:false` 씬(설치본 `assets/ + projects/` 단일 모집단 186 씬 중 183)의 블룸 —
/// 그중 `bloom:true` 5 씬에서 WE `Composite::drawBloomChain` LDR 분기
/// (`0x140183949`–`0x140183a5d`)를 그대로 옮긴 **3패스**다. HDR 피라미드(`HDRBloomPyramidPass`)와
/// 완전히 다른 경로이고, 진입 게이트는 `0x140183618` `test dword [composite+0x128], 0x2000`
/// (= `general.hdr` 비트13) 의 `je` 쪽이다.
///
/// | # | 목적지 RT(슬롯) | 머티리얼(슬롯) | 셰이더 |
/// |---|---|---|---|
/// | 1 | `_rt_4FrameBuffer` `[+0x30a0]` | `[+0x3160]` | `downsample_quarter_bloom`(추출 4탭 박스 + 임계) |
/// | 2 | `_rt_8FrameBuffer` `[+0x30a8]` | `[+0x3170]` | `downsample_eighth_blur_v`(X 13탭) |
/// | 3 | `_rt_Bloom` `[+0x30b0]` | `[+0x3178]` | `blur_h_bloom`(Y 13탭) |
///
/// 합성은 이 패스가 아니라 `Composite::frame` 의 슬롯 `[+0x3150]` = `combine_ldr.json`
/// (`combine.frag`, 텍스처 `_rt_FullFrameBuffer` + `_rt_Bloom`)이 `scene + bloom` **순수 가산**으로
/// 한다 — **감마 변환도 톤커브도 없다**(`0x140180b45`–`0x140180b62`). Waple 은 그 합성까지
/// 이 패스 안(`ldrBloomComposite`)에서 끝낸다.
///
/// `bloom:false` 인 LDR 씬은 **최종 패스 자체가 없다**(씬이 이미 타깃에 그려져 있다).
final class LDRBloomPass: LDRBloomEncoding {
    private struct ExtractUniforms {
        var sourceTexelSize: SIMD2<Float>
        var threshold: Float
        var strength: Float
        var tint: SIMD4<Float>
    }

    private let extractPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState

    init?(device: MTLDevice) {
        guard let library = try? WapleProfiler.compile(Self.metalSource, { try device.makeLibrary(source: Self.metalSource, options: nil) }),
              let vertex = library.makeFunction(name: "ldrBloomVertex"),
              let extract = library.makeFunction(name: "ldrBloomExtract"),
              let blur = library.makeFunction(name: "ldrBloomBlur"),
              let composite = library.makeFunction(name: "ldrBloomComposite") else {
            return nil
        }

        func makePipeline(_ fragment: MTLFunction) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0]!.pixelFormat = .bgra8Unorm
            return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: descriptor) }
        }

        guard let extractPipeline = makePipeline(extract),
              let blurPipeline = makePipeline(blur),
              let compositePipeline = makePipeline(composite) else {
            return nil
        }
        self.extractPipeline = extractPipeline
        self.blurPipeline = blurPipeline
        self.compositePipeline = compositePipeline
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
        parameters: LDRBloomParameters
    ) -> Bool {
        let textures = [source, quarter, eighth, bloom, destination]
        guard textures.allSatisfy({
                  $0.textureType == .type2D && $0.pixelFormat == .bgra8Unorm
              }),
              source !== destination,
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

        var extractUniforms = ExtractUniforms(
            sourceTexelSize: LDRBloomMath.extractTapOffsetUV(
                sourceWidth: source.width,
                sourceHeight: source.height),
            threshold: parameters.threshold,
            strength: parameters.strength,
            tint: SIMD4(parameters.tint.x, parameters.tint.y, parameters.tint.z, 0))
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

        // F671: WE downsample_eighth_blur_v.vert:12/blur_h_bloom.vert:12 `localTexel = g_TexelSize*8.0`
        // 이고 `g_TexelSize` = **풀해상도 텍셀**이라 8 풀텍셀 = 2 quarter-texel 스트라이드다.
        // "풀해상도"의 근거는 LDRBloomMath.fullFrameTexelUV 헤더에 전문으로 옮겼다(셰이더 평문
        // 두 논거 — downsample_quarter{,_linear}.vert 쌍이 dst 해석을 반증하고, X/Y 등방성이
        // source 해석을 반증한다). 구 스트라이드 1 은 합성 σ 가 WE 대비 ~21% 좁은 글로우였다.
        var horizontalStep = LDRBloomMath.horizontalStepUV(quarterWidth: quarter.width)
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

        var verticalStep = LDRBloomMath.verticalStepUV(eighthHeight: eighth.height)
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

        // Destination is untouched until this final encoder exists. There are no failable
        // operations after creation, so a false return is safe for raw fallback.
        guard let compositeEncoder = makeEncoder(
            commandBuffer: commandBuffer,
            target: destination,
            pipeline: compositePipeline) else {
            return false
        }
        compositeEncoder.setFragmentTexture(source, index: 0)
        compositeEncoder.setFragmentTexture(bloom, index: 1)
        compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        compositeEncoder.endEncoding()
        return true
    }

    static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct BloomVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex BloomVertexOut ldrBloomVertex(uint vertexID [[vertex_id]]) {
        float2 p = float2(vertexID == 2 ? 3.0 : -1.0,
                          vertexID == 1 ? 3.0 : -1.0);
        BloomVertexOut out;
        out.position = float4(p, 0.0, 1.0);
        out.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
        return out;
    }

    struct ExtractUniforms {
        float2 sourceTexelSize;
        float threshold;
        float strength;
        float4 tint;
    };

    fragment float4 ldrBloomExtract(
        BloomVertexOut in [[stage_in]],
        texture2d<float> source [[texture(0)]],
        constant ExtractUniforms &u [[buffer(0)]]
    ) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float2 t = u.sourceTexelSize;
        // F670: WE downsample_quarter_bloom.vert `a_TexCoord ± g_TexelSize` — ±1텍셀 대각 4탭은
        // bilinear 결합으로 풋프린트 4×4(16텍셀) 전량 평균. 구 ±1.5 는 코너 4텍셀 점샘플(4/16
        // 서브샘플)이라 풋프린트 내측 2×2 고휘도 피처를 완전 누락(에일리어싱/쉬머).
        float3 rgb = (
            source.sample(linearClamp, in.uv + t * float2(-1.0, -1.0)).rgb +
            source.sample(linearClamp, in.uv + t * float2( 1.0, -1.0)).rgb +
            source.sample(linearClamp, in.uv + t * float2(-1.0,  1.0)).rgb +
            source.sample(linearClamp, in.uv + t * float2( 1.0,  1.0)).rgb
        ) * 0.25;
        float scale = max(rgb.r, max(rgb.g, rgb.b));
        rgb *= saturate(scale - u.threshold);
        float gray = dot(float3(0.2989, 0.5870, 0.1140), rgb);
        rgb = 2.0 * rgb - gray;
        rgb = max(float3(0.0), rgb * u.strength * u.tint.rgb);
        return float4(rgb, 1.0);
    }

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

    fragment float4 ldrBloomBlur(
        BloomVertexOut in [[stage_in]],
        texture2d<float> source [[texture(0)]],
        constant float2 &texelStep [[buffer(0)]]
    ) {
        return float4(blur13(source, in.uv, texelStep), 1.0);
    }

    fragment float4 ldrBloomComposite(
        BloomVertexOut in [[stage_in]],
        texture2d<float> source [[texture(0)]],
        texture2d<float> bloom [[texture(1)]]
    ) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float3 scene = source.sample(linearClamp, in.uv).rgb;
        float3 glow = bloom.sample(linearClamp, in.uv).rgb;
        return float4(scene + glow, 1.0);
    }
    """
}
