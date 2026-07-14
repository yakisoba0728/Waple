import Metal
import simd
import WapleCore

struct LDRBloomParameters: Equatable {
    let strength: Float
    let threshold: Float
    let tint: SIMD3<Float>

    static let defaults = LDRBloomParameters(
        strength: 2,
        threshold: 0.65,
        tint: SIMD3(1, 1, 1))
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
            sourceTexelSize: SIMD2(1 / Float(source.width), 1 / Float(source.height)),
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
        float3 rgb = (
            source.sample(linearClamp, in.uv + t * float2(-1.5, -1.5)).rgb +
            source.sample(linearClamp, in.uv + t * float2( 1.5, -1.5)).rgb +
            source.sample(linearClamp, in.uv + t * float2(-1.5,  1.5)).rgb +
            source.sample(linearClamp, in.uv + t * float2( 1.5,  1.5)).rgb
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
