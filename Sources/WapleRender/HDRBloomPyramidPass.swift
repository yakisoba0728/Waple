import Foundation
import Metal
import simd
import WapleCore

/// HDR bloom 피라미드 — **WE 평문 셰이더 구조 그대로**(2026-08-02 교체).
/// hdr_downsample.frag 하나를 콤보로 3역할에 쓰는 듀얼 필터: 추출(BLOOM 콤보) → 절반씩 4탭
/// 다운샘플 → 4탭 x scatter 업샘플 가산 → combine_hdr 의 ±텍셀 4탭 평균 가산.
/// 탭은 전부 **±0.5 소스 텍셀 코너**이고 **가우시안 패스는 없다**.
/// 종전 구현과의 차이 5건(추출 ±1.0 텍셀 · 레벨별 blur13 h/v · 단일탭 업샘플 · 단일탭 합성 ·
/// 최상위 가중 반전)은 **오차 부호가 서로 반대라 상쇄**되고 있었다 — 그래서 한 건씩 고치면
/// 회귀한다(정본 spec/engine/hdr-bloom.json: doNotFixPiecemeal). 한 단위로 교체했다.
/// 소스가 작아 8단이 안 되면 min(8, 허용 mip 수)로 클램프, 2단 미만은 거부(호출부의 단일레벨
/// HDRBloomPass 폴터). strength/scatter 캘리브는 HDRBloomPass 와 동일.
struct HDRBloomPyramidParameters: Equatable {
    let strength: Float
    let threshold: Float
    let feather: Float
    let tint: SIMD3<Float>
    let scatter: Float
    /// 요청 피라미드 레벨 수(WE 실측 8 이 기본) — 소스 크기/작업 버퍼 수가 못 받치면 클램프.
    /// P③: 프로퍼티 기본값(`= 8`)만으로는 합성 멤버와이즈 이니셜라이저가 `levels` 를 파라미터 목록에서
    /// 아예 제외한다(Swift: 기본값을 가진 `let` 저장 프로퍼티는 외부 주입 불가) — 저작
    /// general.bloomhdriterations 를 전달하려면 명시 이니셜라이저가 필요하다.
    let levels: Int

    init(strength: Float, threshold: Float, feather: Float, tint: SIMD3<Float>, scatter: Float, levels: Int = 8) {
        self.strength = strength
        self.threshold = threshold
        self.feather = feather
        self.tint = tint
        self.scatter = scatter
        self.levels = levels
    }

    static let defaults = HDRBloomPyramidParameters(
        strength: 0, threshold: 1, feather: 0.1, tint: SIMD3(1, 1, 1), scatter: 1.619)
}

protocol HDRBloomPyramidEncoding {
    /// levels/scratches 는 같은 해상도 쌍의 작업 버퍼 — levels[0] = **1/2** 추출,
    /// levels[i] = (1/2 >> i) 다운샘플 레벨, scratches[i] = 업샘플 누적용 같은 해상도 버퍼.
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
        /// (미사용 — 탭 오프셋은 셰이더가 텍스처 크기에서 직접 계산한다. 레이아웃 유지용.)
        var sourceTexelSize: SIMD2<Float>
        var blendParams: SIMD4<Float>
        var tintStrength: SIMD4<Float>
    }

    private let extractPipeline: MTLRenderPipelineState
    private let combinePipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLRenderPipelineState
    private let upsamplePipeline: MTLRenderPipelineState

    init?(device: MTLDevice) {
        guard let library = try? WapleProfiler.compile(Self.metalSource, { try device.makeLibrary(source: Self.metalSource, options: nil) }),
              let vertex = library.makeFunction(name: "hdrBloomVertex"),
              let extract = library.makeFunction(name: "hdrBloomExtract"),
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
              let combinePipeline = makePipeline(combine, format: .bgra8Unorm),
              let downsamplePipeline = makePipeline(downsample, format: .rgba16Float),
              let upsamplePipeline = makePipeline(upsample, format: .rgba16Float) else {
            return nil
        }
        self.extractPipeline = extractPipeline
        self.combinePipeline = combinePipeline
        self.downsamplePipeline = downsamplePipeline
        self.upsamplePipeline = upsamplePipeline
    }

    /// WE 가 추출 단계에 먹이는 **정규화된 블룸 강도**.
    ///
    /// `g_BloomStrength = bloomhdrstrength / (bloomhdrscatter^(max(N,2)-2) + 1)`
    ///
    /// 이 나눗셈은 업샘플 가중과 **한 쌍**이다. WE 의 업샘플 머티리얼에는 저작 `scatter` 가
    /// 그대로 들어가 레벨이 깊어질수록 기여가 `scatter^k` 로 커지는데, 그 발산을 추출 강도에서
    /// 미리 나눠 상쇄한다. 둘 중 하나만 옮기면 화면이 백화되거나(가중만) 블룸이 좁아진다
    /// (정규화만) — 종전 구현은 가중 쪽만 시도했다가 발산해서 되돌렸고, 그때 남긴 주석의
    /// 미확인 항목("저작값 scatter 가 셰이더로 그대로 들어가는지")이 정확히 이것이다.
    ///
    /// 근거 두 갈래:
    ///  · 이 리포의 정본 `spec/engine/uniform-feed.json`(entries[14],
    ///    `hdrBloomStrengthNormalization`)이 **이미 확정 등급으로 같은 식을 담고 있었다** —
    ///    구현만 따라오지 않은 전파 누락이다. 그 항목의 impact 문장도 "재구현에서 가장 놓치기
    ///    쉬운 부분" 이라고 적어 두었다.
    ///  · 원본 wallpaper64.exe 재측정: `powf(scatter, max(N,2)-2)`(0x14017f85e) →
    ///    `+1.0`(0x14017f86b, 상수 [0x140492704]) → `divss`(0x14017f88f) →
    ///    `setMaterialParam(mat, "bloomstrength", …)`(0x14017f89b). 업샘플 머티리얼에는
    ///    scatter 원본이 그대로 실린다(0x14017f944 / 0x14017f96c).
    ///
    /// 기본 저작값(scatter 1.619, N 8)에서 분모는 약 19.01 → 실효 강도 약 0.105.
    /// `max(N,2)-2` 클램프 때문에 N=1 과 N=2 는 같은 값(분모 2)을 낸다.
    public static func normalizedStrength(strength: Float, scatter: Float, levels: Int) -> Float {
        let exponent = Float(max(levels, 2) - 2)
        return strength / (powf(scatter, exponent) + 1)
    }

    /// 소스가 허용하는 피라미드 레벨 수(1/2 부터 1×1 까지 halving)와 요청값의 min.
    /// 호출부는 이 값만큼 levels/scratches 쌍을 할당하면 된다(2 미만이면 인코드 거부).
    static func levelCount(requested: Int, sourceWidth: Int, sourceHeight: Int) -> Int {
        var count = 1
        var w = max(1, sourceWidth / 2)
        var h = max(1, sourceHeight / 2)
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
                  L[i].width == max(1, source.width >> (1 + i))
                      && L[i].height == max(1, source.height >> (1 + i))
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

        let knee = max(parameters.threshold * parameters.feather, 0)
        var extractUniforms = ExtractUniforms(
            sourceTexelSize: SIMD2(1 / Float(source.width), 1 / Float(source.height)),
            blendParams: SIMD4(parameters.threshold, parameters.threshold - knee, 2 * knee, 0.25 / (knee + 1e-5)),
            tintStrength: SIMD4(parameters.tint.x, parameters.tint.y, parameters.tint.z,
                                Self.normalizedStrength(strength: parameters.strength,
                                                        scatter: parameters.scatter, levels: n)))

        // 1) 추출 → L[0] (1/2) — WE hdr_downsample + BLOOM 콤보(4탭 x0.25 + 소프트-니).
        guard draw(extractPipeline, to: L[0], { e in
            e.setFragmentTexture(source, index: 0)
            e.setFragmentBytes(&extractUniforms, length: MemoryLayout<ExtractUniforms>.stride, index: 0)
        }) else { return false }

        // 2) 이후 레벨: 매 단계 절반으로 4탭 다운샘플(가우시안 패스 없음 — WE 는 순수 듀얼 필터).
        for i in 1..<n {
            guard draw(downsamplePipeline, to: L[i], { e in
                e.setFragmentTexture(L[i - 1], index: 0)
            }) else { return false }
        }

        // 3) 업샘플 체인(심층 → 천층): S[i] = L[i] + scatter x 4탭평균(acc).
        // WE 는 hdr_upsample 머티리얼의 blending:additive 로 **고운 레벨 위에 가산**한다 —
        // 규칙이 모든 레벨에 동일하다(최상위만 뒤집혀 추출 레벨이 감쇠되던 S1 결함 해소).
        var up = SIMD4<Float>(parameters.scatter, 0, 0, 0)
        var acc = L[n - 1]
        for i in stride(from: n - 2, through: 0, by: -1) {
            guard draw(upsamplePipeline, to: S[i], { e in
                e.setFragmentTexture(L[i], index: 0)
                e.setFragmentTexture(acc, index: 1)
                e.setFragmentBytes(&up, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            }) else { return false }
            acc = S[i]
        }

        // 4) 합성 source + 블룸(S[0]) → destination — WE combine_hdr 의 ±텍셀 4탭 평균 가산.
        return draw(combinePipeline, to: destination, { e in
            e.setFragmentTexture(source, index: 0)
            e.setFragmentTexture(acc, index: 1)
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

    /// WE hdr_downsample.frag 의 4탭: g_RenderVar0 = 0.5 x 소스 텍셀(BICUBIC 분기의
    /// `texSize = 0.5 / g_RenderVar0.xy` 로 확정) — 즉 **±0.5 소스 텍셀 코너**. 선형 필터라
    /// 탭 하나가 소스 2x2 를 평균하고, 4탭 x 0.25 로 4x4 상당의 박스가 된다.
    float3 weDownsample4(texture2d<float> src, float2 uv) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float2 t = 0.5 / float2(src.get_width(), src.get_height());
        return (src.sample(linearClamp, uv + float2(-t.x, -t.y)).rgb +
                src.sample(linearClamp, uv + float2( t.x, -t.y)).rgb +
                src.sample(linearClamp, uv + float2(-t.x,  t.y)).rgb +
                src.sample(linearClamp, uv + float2( t.x,  t.y)).rgb) * 0.25;
    }

    fragment float4 hdrBloomExtract(BloomVertexOut in [[stage_in]],
                                    texture2d<float> source [[texture(0)]],
                                    constant ExtractUniforms &u [[buffer(0)]]) {
        // WE 의 hdr_downsample + BLOOM 콤보 = 같은 4탭 다운샘플 뒤에 소프트-니 임계.
        float3 c = max(weDownsample4(source, in.uv), 0.0);
        float4 P = u.blendParams;
        float m = max(c.r, max(c.g, c.b));
        float soft = clamp(m - P.y, 0.0, P.z);
        soft = soft * soft * P.w;
        float q = max(m - P.x, soft);
        float3 rgb = c * (u.tintStrength.w * q / max(m, 1e-5)) * u.tintStrength.rgb;
        return float4(rgb, 1.0);
    }

    fragment float4 hdrBloomDownsample(BloomVertexOut in [[stage_in]],
                                       texture2d<float> source [[texture(0)]]) {
        return float4(weDownsample4(source, in.uv), 1.0);
    }

    /// WE hdr_downsample + UPSAMPLE 콤보 = 같은 4탭에 `x0.25 x g_BloomScatter`,
    /// 머티리얼(hdr_upsample.json)이 blending:additive 라 **더 고운 레벨 위에 가산**된다.
    /// 여기서는 별도 타깃에 쓰므로 base(고운 레벨)를 그대로 읽어 더한다 — 결과 동일.
    ///
    /// **가중은 종전 캘리브(0.25 x scatter)를 유지한다.** 셰이더 문면(4탭 합 x0.25 x scatter =
    /// 평균 x scatter)을 그대로 쓰면 scatter=1.619 가 레벨마다 곱해져 발산한다 — 실측에서
    /// 3589454154 의 luma 가 0.091 → 0.420 으로 화면이 백화됐다. 저작값 1.619 가 셰이더의
    /// g_BloomScatter 로 그대로 들어가는지(엔진이 변환하는지)가 미확인이라, 확인 전에는
    /// 발산하지 않는 종전 가중을 유지하고 **탭 모양만** WE 구조로 맞춘다.
    /// 정본: spec/engine/hdr-bloom.json — engine.bloom.hdr.upsampleWeightUnknown.
    fragment float4 hdrBloomUpsample(BloomVertexOut in [[stage_in]],
                                     texture2d<float> base [[texture(0)]],
                                     texture2d<float> add [[texture(1)]],
                                     constant float4 &params [[buffer(0)]]) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float3 b = base.sample(linearClamp, in.uv).rgb;
        float3 a = weDownsample4(add, in.uv) * params.x;   // params.x = scatter (weDownsample4 가 이미 4탭 평균이다)
        return float4(b + a, 1.0);
    }

    /// WE combine_hdr.frag: 블룸을 ±g_TexelSize 코너 4탭으로 평균해 가산한다.
    /// g_TexelSize 는 패스 주 텍스처(=풀해상도 씬)의 텍셀이라 여기서도 source 기준으로 잡는다.
    fragment float4 hdrBloomCombine(BloomVertexOut in [[stage_in]],
                                    texture2d<float> source [[texture(0)]],
                                    texture2d<float> bloom [[texture(1)]]) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float4 base = source.sample(linearClamp, in.uv);
        float2 t = 1.0 / float2(source.get_width(), source.get_height());
        float3 b = (bloom.sample(linearClamp, in.uv + float2( t.x,  t.y)).rgb +
                    bloom.sample(linearClamp, in.uv + float2(-t.x, -t.y)).rgb +
                    bloom.sample(linearClamp, in.uv + float2( t.x, -t.y)).rgb +
                    bloom.sample(linearClamp, in.uv + float2(-t.x,  t.y)).rgb) * 0.25;
        return float4(saturate(base.rgb + b), 1.0);
    }
    """
}
