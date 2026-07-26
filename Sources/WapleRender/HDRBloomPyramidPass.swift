import Metal
import simd
import WapleCore

/// H6: HDR bloom 8-레벨 피라미드 — WE 실물 피라미드(bloomhdriterations 실측 8단,
/// 1800×1130→14×8, HDRBloomPass 헤더 주석 참조) 이식. 3-레벨 축소판의 승격 — 넓은 소프트 헤일로 복원.
/// quarter 추출 → 레벨별 blur13 h/v(1/8 은 h 블러에 2× 다운샘플 융합, 1/16 이하는 box 다운샘플 선행)
/// → ×0.25×scatter additive 업샘플 체인(심층 레벨은 지나는 단계마다 가중이 누적 곱해짐 — 3-레벨
/// 코드의 eighth/sixteenth 합성 규칙의 일반화) → saturate(base+bloom) 합성.
/// 소스가 작아 8단이 안 되면 min(8, 허용 mip 수)로 클램프, 2단 미만은 거부(호출부의 단일레벨
/// HDRBloomPass 폴터). strength/scatter 캘리브는 HDRBloomPass 와 동일.
struct HDRBloomPyramidParameters: Equatable {
    let strength: Float
    let threshold: Float
    let feather: Float
    let tint: SIMD3<Float>
    let scatter: Float
    /// 요청 피라미드 레벨 수(WE 실측 8 이 기본) — 소스 크기/작업 버퍼 수가 못 받치면 클램프.
    let levels: Int = 8

    static let defaults = HDRBloomPyramidParameters(
        strength: 0, threshold: 1, feather: 0.1, tint: SIMD3(1, 1, 1), scatter: 1.619)
}

protocol HDRBloomPyramidEncoding {
    /// levels/scratches 는 같은 해상도 쌍의 ping-pong 작업 버퍼 — levels[0] = 1/4 추출,
    /// levels[i] = (1/4 >> i) 블러 레벨, scratches[i] = 같은 해상도 스크래치(합성 누적에 재사용).
    /// 실제 사용 레벨 수 n = min(parameters.levels, 소스 허용 mip 수, 배열 길이), n ≥ 2 필요.
    func encode(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        levels: [MTLTexture],
        scratches: [MTLTexture],
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

    /// 소스가 허용하는 피라미드 레벨 수(1/4 부터 1×1 까지 halving)와 요청값의 min.
    /// 호출부는 이 값만큼 levels/scratches 쌍을 할당하면 된다(2 미만이면 인코드 거부).
    static func levelCount(requested: Int, sourceWidth: Int, sourceHeight: Int) -> Int {
        var count = 1
        var w = max(1, sourceWidth / 4)
        var h = max(1, sourceHeight / 4)
        while w > 1 || h > 1 {
            w = max(1, w / 2)
            h = max(1, h / 2)
            count += 1
        }
        return min(max(requested, 1), count)
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
        levels: [MTLTexture],
        scratches: [MTLTexture],
        destination: MTLTexture,
        parameters: HDRBloomPyramidParameters
    ) -> Bool {
        let n = min(
            Self.levelCount(
                requested: parameters.levels,
                sourceWidth: source.width,
                sourceHeight: source.height),
            levels.count, scratches.count)
        guard n >= 2 else { return false }
        let L = Array(levels.prefix(n))
        let S = Array(scratches.prefix(n))
        // 격리 가드(단일레벨 HDRBloomPass 와 동일 규약): float 씬 소스 전용, 작업 버퍼 전량 별개.
        guard source.textureType == .type2D, source.pixelFormat == .rgba16Float,
              destination.textureType == .type2D,
              destination.pixelFormat == .bgra8Unorm,
              source !== destination,
              source.width == destination.width,
              source.height == destination.height,
              (L + S).allSatisfy({ $0.textureType == .type2D && $0.pixelFormat == .rgba16Float }),
              (0..<n).allSatisfy({ i in
                  L[i].width == max(1, source.width >> (2 + i))
                      && L[i].height == max(1, source.height >> (2 + i))
                      && S[i].width == L[i].width
                      && S[i].height == L[i].height
              }) else {
            return false
        }
        let work = L + S
        for i in 0..<work.count {
            for j in (i + 1)..<work.count where work[i] === work[j] { return false }
        }

        // 드로우 헬퍼: 인코더 생성·바인드·풀스크린 트라이앵글·종료. 실패는 즉시 false(호출부 폴터).
        func draw(
            _ pipeline: MTLRenderPipelineState,
            to target: MTLTexture,
            _ bind: (MTLRenderCommandEncoder) -> Void
        ) -> Bool {
            guard let encoder = makeEncoder(
                commandBuffer: commandBuffer, target: target, pipeline: pipeline) else { return false }
            bind(encoder)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            return true
        }

        // 분리형 blur13 h/v — fusedDownsample 시 h 단계가 2× 다운샘플을 융합(입력이 2배 해상도).
        func blur(_ src: MTLTexture, _ tmp: MTLTexture, _ dst: MTLTexture, fusedDownsample: Bool) -> Bool {
            var hStep = SIMD2<Float>((fusedDownsample ? 2 : 1) / Float(src.width), 0)
            guard draw(blurPipeline, to: tmp, { e in
                e.setFragmentTexture(src, index: 0)
                e.setFragmentBytes(&hStep, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            }) else { return false }
            var vStep = SIMD2<Float>(0, 1 / Float(tmp.height))
            return draw(blurPipeline, to: dst, { e in
                e.setFragmentTexture(tmp, index: 0)
                e.setFragmentBytes(&vStep, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            })
        }

        let knee = max(parameters.threshold * parameters.feather, 0)
        var extractUniforms = ExtractUniforms(
            sourceTexelSize: SIMD2(1 / Float(source.width), 1 / Float(source.height)),
            blendParams: SIMD4(parameters.threshold, parameters.threshold - knee, 2 * knee, 0.25 / (knee + 1e-5)),
            tintStrength: SIMD4(parameters.tint.x, parameters.tint.y, parameters.tint.z, parameters.strength))

        // 1) 추출 → L[0] (1/4)
        guard draw(extractPipeline, to: L[0], { e in
            e.setFragmentTexture(source, index: 0)
            e.setFragmentBytes(&extractUniforms, length: MemoryLayout<ExtractUniforms>.stride, index: 0)
        }) else { return false }

        // 2) 1/8 레벨: h 블러에 2× 다운샘플 융합(기존 3-레벨 코드의 quarter→eighth 단계).
        guard blur(L[0], S[1], L[1], fusedDownsample: true) else { return false }

        // 3) 1/16 이하 레벨: box 다운샘플 → blur13 h/v.
        for i in 2..<n {
            guard draw(downsamplePipeline, to: L[i], { e in
                e.setFragmentTexture(L[i - 1], index: 0)
            }) else { return false }
            guard blur(L[i], S[i], L[i], fusedDownsample: false) else { return false }
        }

        // 4) 가중 합성(심층 → 천층): S[i] = L[i] + w·acc — w = 0.25×scatter, 단계마다 누적 곱.
        var up = SIMD4<Float>(parameters.scatter * 0.25, 0, 0, 0)
        var acc = L[n - 1]
        if n > 2 {
            for i in stride(from: n - 2, through: 1, by: -1) {
                let base = L[i]
                let add = acc
                guard draw(upsamplePipeline, to: S[i], { e in
                    e.setFragmentTexture(base, index: 0)
                    e.setFragmentTexture(add, index: 1)
                    e.setFragmentBytes(&up, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                }) else { return false }
                acc = S[i]
            }
        }

        // 5) 최상위: 추출 레벨(L[0]) 가산 → S[0] (기존 3-레벨 코드의 eighth→quarter 단계와 동일 규칙).
        let top = acc
        guard draw(upsamplePipeline, to: S[0], { e in
            e.setFragmentTexture(top, index: 0)
            e.setFragmentTexture(L[0], index: 1)
            e.setFragmentBytes(&up, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        }) else { return false }

        // 6) 합성 source + S[0] → destination
        return draw(combinePipeline, to: destination, { e in
            e.setFragmentTexture(source, index: 0)
            e.setFragmentTexture(S[0], index: 1)
        })
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
