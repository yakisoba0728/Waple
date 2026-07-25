import Metal
import simd
import WapleCore

/// H6: HDR bloom 3-레벨 피라미드 — 기존 단일 레벨(quarter+eighth) 대비 글로우 반경 확장.
/// quarter 추출 → eighth blur → sixteenth blur → additive 업샘플(eighth→quarter→합성).
/// WE 8단 피라미드의 축소판(후속 8단 승격 예정). strength/scatter 캘리브는 HDRBloomPass 와 동일.
struct HDRBloomPyramidParameters: Equatable {
    let strength: Float
    let threshold: Float
    let feather: Float
    let tint: SIMD3<Float>
    let scatter: Float

    static let defaults = HDRBloomPyramidParameters(
        strength: 0, threshold: 1, feather: 0.1, tint: SIMD3(1, 1, 1), scatter: 1.619)
}

protocol HDRBloomPyramidEncoding {
    func encode(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        quarter: MTLTexture,
        eighth: MTLTexture,
        sixteenth: MTLTexture,
        bloom: MTLTexture,
        destination: MTLTexture,
        parameters: HDRBloomPyramidParameters
    ) -> Bool
}

final class HDRBloomPyramidPass: HDRBloomPyramidEncoding {
    private struct ExtractUniforms {
        var sourceTexelSize: SIMD2<Float>
        var blendParams: SIMD4<Float>
        var tintStrength: SIMD4<Float>
    }

    private let extractPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let combinePipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLRenderPipelineState
    private let upsamplePipeline: MTLRenderPipelineState

    init?(device: MTLDevice) {
        guard let library = try? WapleProfiler.compile(Self.metalSource, { try device.makeLibrary(source: Self.metalSource, options: nil) }),
              let vertex = library.makeFunction(name: "hdrBloomVertex"),
              let extract = library.makeFunction(name: "hdrBloomExtract"),
              let blur = library.makeFunction(name: "hdrBloomBlur"),
              let combine = library.makeFunction(name: "hdrBloomCombine"),
              let downsample = library.makeFunction(name: "hdrBloomDownsample"),
              let upsample = library.makeFunction(name: "hdrBloomUpsample") else {
            return nil
        }

        func makePipeline(_ fragment: MTLFunction, format: MTLPixelFormat) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0]!.pixelFormat = format
            return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: descriptor) }
        }

        guard let extractPipeline = makePipeline(extract, format: .rgba16Float),
              let blurPipeline = makePipeline(blur, format: .rgba16Float),
              let combinePipeline = makePipeline(combine, format: .bgra8Unorm),
              let downsamplePipeline = makePipeline(downsample, format: .rgba16Float),
              let upsamplePipeline = makePipeline(upsample, format: .rgba16Float) else {
            return nil
        }
        self.extractPipeline = extractPipeline
        self.blurPipeline = blurPipeline
        self.combinePipeline = combinePipeline
        self.downsamplePipeline = downsamplePipeline
        self.upsamplePipeline = upsamplePipeline
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
        sixteenth: MTLTexture,
        bloom: MTLTexture,
        destination: MTLTexture,
        parameters: HDRBloomPyramidParameters
    ) -> Bool {
        guard [source, quarter, eighth, sixteenth, bloom].allSatisfy({
                  $0.textureType == .type2D && $0.pixelFormat == .rgba16Float
              }),
              destination.textureType == .type2D,
              destination.pixelFormat == .bgra8Unorm,
              source !== destination,
              quarter !== eighth, quarter !== sixteenth, quarter !== bloom,
              eighth !== sixteenth, eighth !== bloom, sixteenth !== bloom,
              source.width == destination.width, source.height == destination.height,
              quarter.width == max(1, source.width / 4), quarter.height == max(1, source.height / 4),
              eighth.width == max(1, source.width / 8), eighth.height == max(1, source.height / 8),
              sixteenth.width == max(1, source.width / 16), sixteenth.height == max(1, source.height / 16),
              bloom.width == eighth.width, bloom.height == eighth.height else {
            return false
        }

        let knee = max(parameters.threshold * parameters.feather, 0)
        var extractUniforms = ExtractUniforms(
            sourceTexelSize: SIMD2(1 / Float(source.width), 1 / Float(source.height)),
            blendParams: SIMD4(parameters.threshold, parameters.threshold - knee, 2 * knee, 0.25 / (knee + 1e-5)),
            tintStrength: SIMD4(parameters.tint.x, parameters.tint.y, parameters.tint.z, parameters.strength))

        // 1) 추출 → quarter
        guard let extractEncoder = makeEncoder(commandBuffer: commandBuffer, target: quarter, pipeline: extractPipeline) else { return false }
        extractEncoder.setFragmentTexture(source, index: 0)
        extractEncoder.setFragmentBytes(&extractUniforms, length: MemoryLayout<ExtractUniforms>.stride, index: 0)
        extractEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        extractEncoder.endEncoding()

        // 2) quarter blur h → eighth
        var hStep = SIMD2<Float>(2 / Float(quarter.width), 0)
        guard let hEncoder = makeEncoder(commandBuffer: commandBuffer, target: eighth, pipeline: blurPipeline) else { return false }
        hEncoder.setFragmentTexture(quarter, index: 0)
        hEncoder.setFragmentBytes(&hStep, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        hEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        hEncoder.endEncoding()

        // 3) eighth blur v → bloom(1/8 임시)
        var vStep = SIMD2<Float>(0, 1 / Float(eighth.height))
        guard let vEncoder = makeEncoder(commandBuffer: commandBuffer, target: bloom, pipeline: blurPipeline) else { return false }
        vEncoder.setFragmentTexture(eighth, index: 0)
        vEncoder.setFragmentBytes(&vStep, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        vEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        vEncoder.endEncoding()

        // 4) bloom(1/8) downsample → sixteenth
        guard let dsEncoder = makeEncoder(commandBuffer: commandBuffer, target: sixteenth, pipeline: downsamplePipeline) else { return false }
        dsEncoder.setFragmentTexture(bloom, index: 0)
        dsEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        dsEncoder.endEncoding()

        // 5) sixteenth blur h → eighth(재사용, 업샘플 입력)
        var h16Step = SIMD2<Float>(1 / Float(sixteenth.width), 0)
        guard let h16Encoder = makeEncoder(commandBuffer: commandBuffer, target: eighth, pipeline: blurPipeline) else { return false }
        h16Encoder.setFragmentTexture(sixteenth, index: 0)
        h16Encoder.setFragmentBytes(&h16Step, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        h16Encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        h16Encoder.endEncoding()

        // 6) eighth blur v → sixteenth(재사용, 최종 블룸)
        var v16Step = SIMD2<Float>(0, 1 / Float(eighth.height))
        guard let v16Encoder = makeEncoder(commandBuffer: commandBuffer, target: sixteenth, pipeline: blurPipeline) else { return false }
        v16Encoder.setFragmentTexture(eighth, index: 0)
        v16Encoder.setFragmentBytes(&v16Step, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        v16Encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        v16Encoder.endEncoding()

        // 7) sixteenth upsample additive → eighth (bloom)
        var up1 = SIMD4<Float>(parameters.scatter * 0.25, 0, 0, 0)
        guard let up1Encoder = makeEncoder(commandBuffer: commandBuffer, target: eighth, pipeline: upsamplePipeline) else { return false }
        up1Encoder.setFragmentTexture(bloom, index: 0)      // 기존 1/8 블룸
        up1Encoder.setFragmentTexture(sixteenth, index: 1)  // 1/16 블룸
        up1Encoder.setFragmentBytes(&up1, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        up1Encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        up1Encoder.endEncoding()

        // 8) eighth upsample additive → quarter
        guard let up2Encoder = makeEncoder(commandBuffer: commandBuffer, target: quarter, pipeline: upsamplePipeline) else { return false }
        up2Encoder.setFragmentTexture(eighth, index: 0)
        up2Encoder.setFragmentTexture(quarter, index: 1)
        up2Encoder.setFragmentBytes(&up1, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        up2Encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        up2Encoder.endEncoding()

        // 9) 합성 quarter + source → destination
        guard let combineEncoder = makeEncoder(commandBuffer: commandBuffer, target: destination, pipeline: combinePipeline) else { return false }
        combineEncoder.setFragmentTexture(source, index: 0)
        combineEncoder.setFragmentTexture(quarter, index: 1)
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
        float2 p = float2(vertexID == 2 ? 3.0 : -1.0, vertexID == 1 ? 3.0 : -1.0);
        BloomVertexOut out;
        out.position = float4(p, 0.0, 1.0);
        out.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
        return out;
    }

    struct ExtractUniforms {
        float2 sourceTexelSize;
        float4 blendParams;
        float4 tintStrength;
    };

    fragment float4 hdrBloomExtract(BloomVertexOut in [[stage_in]],
                                    texture2d<float> source [[texture(0)]],
                                    constant ExtractUniforms &u [[buffer(0)]]) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float2 t = u.sourceTexelSize;
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

    float3 blur13(texture2d<float> source, float2 uv, float2 step) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float3 rgb = source.sample(linearClamp, uv).rgb * 0.171834;
        rgb += (source.sample(linearClamp, uv - step * 1.0).rgb + source.sample(linearClamp, uv + step * 1.0).rgb) * 0.156756;
        rgb += (source.sample(linearClamp, uv - step * 2.0).rgb + source.sample(linearClamp, uv + step * 2.0).rgb) * 0.119007;
        rgb += (source.sample(linearClamp, uv - step * 3.0).rgb + source.sample(linearClamp, uv + step * 3.0).rgb) * 0.075189;
        rgb += (source.sample(linearClamp, uv - step * 4.0).rgb + source.sample(linearClamp, uv + step * 4.0).rgb) * 0.039533;
        rgb += (source.sample(linearClamp, uv - step * 5.0).rgb + source.sample(linearClamp, uv + step * 5.0).rgb) * 0.017298;
        rgb += (source.sample(linearClamp, uv - step * 6.0).rgb + source.sample(linearClamp, uv + step * 6.0).rgb) * 0.006299;
        return rgb;
    }

    fragment float4 hdrBloomBlur(BloomVertexOut in [[stage_in]],
                                 texture2d<float> source [[texture(0)]],
                                 constant float2 &texelStep [[buffer(0)]]) {
        return float4(blur13(source, in.uv, texelStep), 1.0);
    }

    fragment float4 hdrBloomDownsample(BloomVertexOut in [[stage_in]],
                                       texture2d<float> source [[texture(0)]]) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float2 t = 1.0 / float2(source.get_width(), source.get_height());
        float3 c = (
            source.sample(linearClamp, in.uv + t * float2(-0.5, -0.5)).rgb +
            source.sample(linearClamp, in.uv + t * float2( 0.5, -0.5)).rgb +
            source.sample(linearClamp, in.uv + t * float2(-0.5,  0.5)).rgb +
            source.sample(linearClamp, in.uv + t * float2( 0.5,  0.5)).rgb
        ) * 0.25;
        return float4(c, 1.0);
    }

    fragment float4 hdrBloomUpsample(BloomVertexOut in [[stage_in]],
                                     texture2d<float> base [[texture(0)]],
                                     texture2d<float> add [[texture(1)]],
                                     constant float4 &params [[buffer(0)]]) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float3 b = base.sample(linearClamp, in.uv).rgb;
        float3 a = add.sample(linearClamp, in.uv).rgb * params.x;
        return float4(b + a, 1.0);
    }

    fragment float4 hdrBloomCombine(BloomVertexOut in [[stage_in]],
                                    texture2d<float> source [[texture(0)]],
                                    texture2d<float> bloom [[texture(1)]]) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float4 base = source.sample(linearClamp, in.uv);
        float3 C = base.rgb + bloom.sample(linearClamp, in.uv).rgb;
        return float4(saturate(C), 1.0);
    }
    """
}
