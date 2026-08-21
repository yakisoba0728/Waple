import Foundation
import Metal
import simd
import WapleCore

/// HDR bloom 피라미드 — **WE 평문 셰이더 구조 그대로**(2026-08-02 교체).
/// hdr_downsample.frag 하나를 콤보로 3역할에 쓰는 듀얼 필터: 추출(BLOOM 콤보) → 절반씩 4탭
/// 다운샘플 → 4탭 x scatter 업샘플 가산 → combine_hdr 의 ±텍셀 4탭 평균 가산.
/// 탭 반경은 패스마다 다르다 — 추출·다운샘플은 **±1.0 소스 텍셀**(소스 4×4 박스), 업샘플만
/// **±0.5 소스 텍셀**(소스 2×2 박스)이고 **가우시안 패스는 없다**. 가장 깊은 두 업샘플 단은 BICUBIC.
/// 종전 구현과의 차이 5건(추출 ±1.0 텍셀 · 레벨별 blur13 h/v · 단일탭 업샘플 · 단일탭 합성 ·
/// 최상위 가중 반전)은 **오차 부호가 서로 반대라 상쇄**되고 있었다 — 그래서 한 건씩 고치면
/// 회귀한다(정본 spec/engine/hdr-bloom.json: `filterShapeDeviations.orderingConstraint`).
/// 한 단위로 교체했다.
/// 레벨 수는 WE 와 같은 **min(W,H) 기준** `min(8, floor(log2(min(W,H))))` 를 저작
/// `bloomhdriterations` 와 min 한 값이고(W-25, 2026-08-21 해소), 2단 미만은 거부한다
/// (호출부의 단일레벨 HDRBloomPass 폴터). strength/scatter 캘리브는 HDRBloomPass 와 동일.
/// 탭 산술 본체는 `WapleCore.HDRBloomMath` 다 — 여기 `static` 은 위임뿐이다.
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
        /// WE `g_RenderVar0.xy` — **UV 단위** 4탭 코너 오프셋. 추출(i=0)은 기저 `(1/W, 1/H)` 를
        /// 배율 없이 그대로 쓴다(`0x1401836a0`). 소스가 풀 프레임버퍼라 **±1.0 소스 텍셀**이다.
        /// (종전 주석은 이 자리를 "미사용" 으로 적어 두고 셰이더가 텍스처 크기에서 되짚게 했는데,
        ///  그 되짚기가 업샘플 항등식이라 다운샘플 반경이 절반이 됐다 — W-1 의 발원지.)
        var tapOffset: SIMD2<Float>
        var blendParams: SIMD4<Float>
        var tintStrength: SIMD4<Float>
    }

    /// 다운샘플/업샘플 공용 유니폼. 탭 오프셋을 **Swift 가 계산해 싣는다** — 셰이더가 소스
    /// 텍스처 크기에서 되짚으면 두 계열이 같은 반경으로 뭉개진다(공유 헬퍼 함정, W-1).
    private struct TapUniforms {
        var tapOffset: SIMD2<Float>
        /// 업샘플 전용(`g_BloomScatter`, hdr_downsample.frag:61). 다운샘플 패스는 읽지 않는다.
        var scatter: Float
        var padding: Float
    }

    private let extractPipeline: MTLRenderPipelineState
    private let combinePipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLRenderPipelineState
    private let upsamplePipeline: MTLRenderPipelineState
    /// `hdr_upsample_cubic`(BICUBIC=1) 전용 — 가장 깊은 두 업샘플 단만 이걸 쓴다.
    private let upsampleCubicPipeline: MTLRenderPipelineState

    init?(device: MTLDevice) {
        guard let library = try? WapleProfiler.compile(Self.metalSource, { try device.makeLibrary(source: Self.metalSource, options: nil) }),
              let vertex = library.makeFunction(name: "hdrBloomVertex"),
              let extract = library.makeFunction(name: "hdrBloomExtract"),
              let combine = library.makeFunction(name: "hdrBloomCombine"),
              let downsample = library.makeFunction(name: "hdrBloomDownsample"),
              let upsample = library.makeFunction(name: "hdrBloomUpsample"),
              let upsampleCubic = library.makeFunction(name: "hdrBloomUpsampleCubic") else {
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
              let upsamplePipeline = makePipeline(upsample, format: .rgba16Float),
              let upsampleCubicPipeline = makePipeline(upsampleCubic, format: .rgba16Float) else {
            return nil
        }
        self.extractPipeline = extractPipeline
        self.combinePipeline = combinePipeline
        self.downsamplePipeline = downsamplePipeline
        self.upsamplePipeline = upsamplePipeline
        self.upsampleCubicPipeline = upsampleCubicPipeline
    }

    // MARK: - 탭 산술 위임 (본체는 `WapleCore.HDRBloomMath`)
    //
    // **[2026-08-21] 본체를 `Sources/WapleCore/HDRBloomMath.swift` 로 옮겼다.** 이 모듈은
    // `import Metal` 이라 리눅스에서 테스트가 한 줄도 안 돌아, 탭 반경(`b19db5b`)·레벨 수(W-25)
    // 두 이탈이 전부 macOS CI 왕복으로만 잡혔다. 순수 산술은 `WapleCore` 에 두고
    // `Tests/WapleCoreTests/HDRBloomMathTests.swift` 가 리눅스에서 덮는다
    // (선례: `SceneLightSlotBudget` `4eb61f1` · `PointerHit` `aebf586`).
    // 아래는 **얇은 위임**이다 — 기존 호출부(`SceneRendererFinalizer`)와 macOS 테스트가
    // `HDRBloomPyramidPass.<이름>` 으로 그대로 부른다. 근거 VA·유도는 전부 그 파일 주석에 있다.

    /// WE 가 추출 단계에 먹이는 **정규화된 블룸 강도**:
    /// `bloomhdrstrength / (bloomhdrscatter^(max(N,2)-2) + 1)`
    /// (`powf 0x14017f85e` → `+1.0 0x14017f86b` → `divss 0x14017f88f`).
    public static func normalizedStrength(strength: Float, scatter: Float, levels: Int) -> Float {
        HDRBloomMath.normalizedStrength(strength: strength, scatter: scatter, levels: levels)
    }

    /// 정수 배율 → UV 오프셋. `baseWidth`/`baseHeight` = **풀 프레임버퍼** 크기
    /// (`0x1401836a0`–`0x1401836ba`).
    static func tapOffsetUV(scale: Int, baseWidth: Int, baseHeight: Int) -> SIMD2<Float> {
        HDRBloomMath.tapOffsetUV(scale: scale, baseWidth: baseWidth, baseHeight: baseHeight)
    }

    /// 추출(level 0)·다운샘플(level ≥ 1) 배율 `1 << i` (`0x14018374a`–`0x14018375c`).
    static func downsampleTapScale(level: Int) -> Int {
        HDRBloomMath.downsampleTapScale(level: level)
    }

    /// 업샘플 배율 `2 << (i−1)` (`0x140183856`–`0x14018386b`).
    static func upsampleTapScale(sourceLevel: Int) -> Int {
        HDRBloomMath.upsampleTapScale(sourceLevel: sourceLevel)
    }

    /// 검산용 — UV 오프셋을 **소스 텍셀 수**로 환산한다(W-1 의 판정식).
    static func tapRadiusInSourceTexels(offsetUV: Float, sourceWidth: Int) -> Float {
        HDRBloomMath.tapRadiusInSourceTexels(offsetUV: offsetUV, sourceWidth: sourceWidth)
    }

    /// 가장 깊은 두 단만 BICUBIC (`0x140183810`–`0x140183822`).
    static func upsampleUsesBicubic(sourceLevel: Int, levelCount: Int) -> Bool {
        HDRBloomMath.upsampleUsesBicubic(sourceLevel: sourceLevel, levelCount: levelCount)
    }

    /// `g_BloomBlendParams` 패킹 (`0x14017f8bc`–`0x14017f900`).
    static func blendParams(threshold: Float, feather: Float) -> SIMD4<Float> {
        HDRBloomMath.blendParams(threshold: threshold, feather: feather)
    }

    /// 피라미드 레벨 수 — **WE 와 같은 `min(W,H)` 기준** `min(8, floor(log2(min(W,H))))`
    /// 를 저작 `bloomhdriterations` 와 min 한 값이다(`cmovg 0x14017f363` → `sar 0x14017f376`
    /// → `jle 0x14017f37d` → `inc [rsi+0x310c] 0x14017f383`, 상한 `cmp ebx,8 0x14017f541`;
    /// 실효 N 은 `0x14017f7f7`–`0x14017f84c` → `obj+0x3108`).
    ///
    /// **[2026-08-21] W-25 해소.** 종전에는 `w > 1 || h > 1` 로 도는 **max 기준**이라
    /// 짧은 변이 256 미만이고 두 변의 2-거듭제곱 구간이 다르면 한 단 더 셌다(64×32 → 6, WE 5).
    /// N 은 `normalizedStrength` 의 지수로 직행하므로 강도가 통째로 갈리는 축이다.
    /// 풀스크린(짧은 변 ≥ 256)에서는 양쪽 다 상한 8 이라 차이가 없지만, 이 리포의 골든
    /// 썸네일(256×144)과 64×32 렌더 테스트는 갈린다.
    static func levelCount(requested: Int, sourceWidth: Int, sourceHeight: Int) -> Int {
        HDRBloomMath.levelCount(
            requested: requested, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
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

        var extractUniforms = ExtractUniforms(
            tapOffset: Self.tapOffsetUV(scale: Self.downsampleTapScale(level: 0),
                                        baseWidth: source.width, baseHeight: source.height),
            blendParams: Self.blendParams(threshold: parameters.threshold,
                                          feather: parameters.feather),
            tintStrength: SIMD4(parameters.tint.x, parameters.tint.y, parameters.tint.z,
                                Self.normalizedStrength(strength: parameters.strength,
                                                        scatter: parameters.scatter, levels: n)))

        // 1) 추출 → L[0] (1/2) — WE hdr_downsample + BLOOM 콤보(4탭 x0.25 + 소프트-니).
        // 탭은 기저 그대로 = ±1 풀 텍셀(`0x1401836a0`).
        guard draw(extractPipeline, to: L[0], { e in
            e.setFragmentTexture(source, index: 0)
            e.setFragmentBytes(&extractUniforms, length: MemoryLayout<ExtractUniforms>.stride, index: 0)
        }) else { return false }

        // 2) 이후 레벨: 매 단계 절반으로 4탭 다운샘플(가우시안 패스 없음 — WE 는 순수 듀얼 필터).
        // 탭 배율 `1 << i` 라 **±1 소스 텍셀** = 소스 4×4 박스다(업샘플의 ±0.5 와 다르다).
        for i in 1..<n {
            var tap = TapUniforms(
                tapOffset: Self.tapOffsetUV(scale: Self.downsampleTapScale(level: i),
                                            baseWidth: source.width, baseHeight: source.height),
                scatter: 0, padding: 0)
            guard draw(downsamplePipeline, to: L[i], { e in
                e.setFragmentTexture(L[i - 1], index: 0)
                e.setFragmentBytes(&tap, length: MemoryLayout<TapUniforms>.stride, index: 0)
            }) else { return false }
        }

        // 3) 업샘플 체인(심층 → 천층): S[i] = L[i] + scatter x 4탭평균(acc).
        // WE 는 hdr_upsample 머티리얼의 blending:additive 로 **고운 레벨 위에 가산**한다 —
        // 규칙이 모든 레벨에 동일하다(최상위만 뒤집혀 추출 레벨이 감쇠되던 S1 결함 해소).
        // 탭 배율 `2 << (i−1)` 이지만 소스가 한 단 더 작아 **±0.5 소스 텍셀**이고,
        // 가장 깊은 두 단(소스레벨 ≥ n−2)만 hdr_upsample_cubic = BICUBIC 이다.
        var acc = L[n - 1]
        for i in stride(from: n - 2, through: 0, by: -1) {
            let sourceLevel = i + 1        // WE 루프 변수 ebp = 업샘플의 소스 레벨
            var tap = TapUniforms(
                tapOffset: Self.tapOffsetUV(scale: Self.upsampleTapScale(sourceLevel: sourceLevel),
                                            baseWidth: source.width, baseHeight: source.height),
                scatter: parameters.scatter, padding: 0)
            let pipeline = Self.upsampleUsesBicubic(sourceLevel: sourceLevel, levelCount: n)
                ? upsampleCubicPipeline : upsamplePipeline
            guard draw(pipeline, to: S[i], { e in
                e.setFragmentTexture(L[i], index: 0)
                e.setFragmentTexture(acc, index: 1)
                e.setFragmentBytes(&tap, length: MemoryLayout<TapUniforms>.stride, index: 0)
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
        float2 tapOffset;      // WE g_RenderVar0.xy (UV 단위)
        float4 blendParams;
        float4 tintStrength;
    };

    struct TapUniforms {
        float2 tapOffset;      // WE g_RenderVar0.xy (UV 단위)
        float scatter;         // 업샘플 전용 g_BloomScatter
        float padding;
    };

    /// WE hdr_downsample.frag:71-74 의 4탭. 오프셋은 `g_RenderVar0.xy/.zw`(= ±t) 그대로다.
    ///
    /// **t 를 셰이더가 계산하지 않는다.** 소스 텍스처 크기에서 되짚는 종전 구현은 BICUBIC
    /// 분기의 `texSize = 0.5 / g_RenderVar0.xy`(:22) 항등식을 근거로 삼았는데, 그 항등식은
    /// BICUBIC 이 켜지는 **업샘플에서만** 성립한다. 엔진이 싣는 실제 배율은
    /// 다운샘플 `1 << i`(0x14018374a) · 업샘플 `2 << (i−1)`(0x140183856) 로 같은데
    /// **소스 레벨이 한 단 다르기 때문에** 다운샘플은 ±1 소스 텍셀(4×4 박스), 업샘플은
    /// ±0.5 소스 텍셀(2×2 박스)이 된다. 항등식을 다운샘플에 일반화하면 반경이 절반이 됐다.
    float3 weBox4(texture2d<float> src, float2 uv, float2 t) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        return (src.sample(linearClamp, uv + float2(-t.x, -t.y)).rgb +
                src.sample(linearClamp, uv + float2( t.x, -t.y)).rgb +
                src.sample(linearClamp, uv + float2(-t.x,  t.y)).rgb +
                src.sample(linearClamp, uv + float2( t.x,  t.y)).rgb) * 0.25;
    }

    /// WE hdr_downsample.frag:8-17 `cubic()` — 3차 B-스플라인 가중 4개(합 1).
    float4 weCubicWeights(float v) {
        float4 n = float4(1.0, 2.0, 3.0, 4.0) - v;
        float4 s = n * n * n;
        float x = s.x;
        float y = s.y - 4.0 * s.x;
        float z = s.z - 4.0 * s.y + 6.0 * s.x;
        float w = 6.0 - x - y - z;
        return float4(x, y, z, w) * (1.0 / 6.0);
    }

    /// WE hdr_downsample.frag:19-51 `textureBicubic()` 축자 — 4×4 B-스플라인을 **바이리니어
    /// 4탭**으로 재구성한다(가중 중심으로 샘플 좌표를 밀어 하드웨어 보간에 태우는 정석 형태).
    /// 소스 크기를 `texSize = 0.5 / g_RenderVar0.xy`(:22) 로 탭 오프셋에서 되짚는 것까지
    /// 그대로 옮겼다 — 업샘플 t = 0.5 x 소스 텍셀이므로 이 자리에서는 항등이다.
    float3 weBicubic(texture2d<float> src, float2 uv, float2 t) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float2 texSize = 0.5 / t;
        float2 invTexSize = t / 0.5;
        float2 tc = uv * texSize - 0.5;
        float2 fxy = fract(tc);
        tc -= fxy;
        float4 xc = weCubicWeights(fxy.x);
        float4 yc = weCubicWeights(fxy.y);
        float4 c = float4(tc.x, tc.x, tc.y, tc.y) + float4(-0.5, 1.5, -0.5, 1.5);
        float4 s = float4(xc.xz + xc.yw, yc.xz + yc.yw);
        float4 offset = c + float4(xc.y, xc.w, yc.y, yc.w) / s;
        offset *= float4(invTexSize.x, invTexSize.x, invTexSize.y, invTexSize.y);
        float3 s0 = src.sample(linearClamp, float2(offset.x, offset.z)).rgb;
        float3 s1 = src.sample(linearClamp, float2(offset.y, offset.z)).rgb;
        float3 s2 = src.sample(linearClamp, float2(offset.x, offset.w)).rgb;
        float3 s3 = src.sample(linearClamp, float2(offset.y, offset.w)).rgb;
        float sx = s.x / (s.x + s.y);
        float sy = s.z / (s.z + s.w);
        return mix(mix(s3, s2, sx), mix(s1, s0, sx), sy);
    }

    fragment float4 hdrBloomExtract(BloomVertexOut in [[stage_in]],
                                    texture2d<float> source [[texture(0)]],
                                    constant ExtractUniforms &u [[buffer(0)]]) {
        // WE 의 hdr_downsample + BLOOM 콤보 = 같은 4탭 다운샘플 뒤에 소프트-니 임계.
        float3 c = max(weBox4(source, in.uv, u.tapOffset), 0.0);
        float4 P = u.blendParams;
        float m = max(c.r, max(c.g, c.b));
        float soft = clamp(m - P.y, 0.0, P.z);
        soft = soft * soft * P.w;
        float q = max(m - P.x, soft);
        float3 rgb = c * (u.tintStrength.w * q / max(m, 1e-5)) * u.tintStrength.rgb;
        return float4(rgb, 1.0);
    }

    fragment float4 hdrBloomDownsample(BloomVertexOut in [[stage_in]],
                                       texture2d<float> source [[texture(0)]],
                                       constant TapUniforms &u [[buffer(0)]]) {
        return float4(weBox4(source, in.uv, u.tapOffset), 1.0);
    }

    /// WE hdr_downsample + UPSAMPLE 콤보 = 같은 4탭에 `x0.25 x g_BloomScatter`,
    /// 머티리얼(hdr_upsample.json)이 blending:additive 라 **더 고운 레벨 위에 가산**된다.
    /// 여기서는 별도 타깃에 쓰므로 base(고운 레벨)를 그대로 읽어 더한다 — 결과 동일.
    ///
    /// **[2026-08-20] 이 자리의 미해결은 닫혔다.** 종전 주석은 *"저작값 scatter 가 셰이더의
    /// `g_BloomScatter` 로 그대로 들어가는지 미확인이라 발산하지 않는 종전 가중을 유지한다"* 였는데,
    /// 셋이 서로 맞물려 답을 준다:
    ///
    ///   ① **동봉 셰이더 원문**이 직접 말한다 — `assets/shaders/hdr_downsample.frag:61`
    ///      `uniform float g_BloomScatter; // {"material":"scatter","default":1}` 이고 본문은
    ///      `albedo *= 0.25 * g_BloomScatter`(4탭 합 기준). 즉 **0.25 는 4탭 평균**이고 scatter 는
    ///      그 위에 곱하는 별개 항이다. 둘은 애초에 경쟁 후보가 아니었다.
    ///   ② **엔진이 무엇을 싣는지**: `0x14017f807` `movss xmm6,[rbx+0x3d0]` 로 저작 `bloomhdrscatter`
    ///      를 읽어 **변형 없이** `setMaterialParam(mat,"scatter",xmm6,1)` 두 번(`0x14017f967` ·
    ///      `0x14017f988`, 대상은 `[rsi+0x31a0]`·`[rsi+0x31a8]` = hdr_upsample 계열 2개).
    ///      중간의 `movaps xmm0,xmm6`(`0x14017f854`)는 아래 ③ 의 `powf` 입력이지 xmm6 를 바꾸지 않는다.
    ///   ③ **발산이 안 나는 이유**: 위 `normalizedStrength` 가 추출 강도를 `scatter^(max(N,2)−2)+1` 로
    ///      나눈다. 업샘플의 `scatter^k` 누적과 **한 쌍**이라 서로 상쇄한다. 종전에 백화가 났던 것은
    ///      가중만 옮기고 이 나눗셈을 안 옮겼기 때문이다 — 가중이 틀렸던 게 아니다.
    ///
    /// 그래서 아래는 `weBox4`(이미 4탭 평균) × 생 scatter = 셰이더 문면과 **동일**하다.
    /// 정본: spec/engine/uniform-feed.json — engine.uniformFeed.hdrBloom.materialParams(확정).
    fragment float4 hdrBloomUpsample(BloomVertexOut in [[stage_in]],
                                     texture2d<float> base [[texture(0)]],
                                     texture2d<float> add [[texture(1)]],
                                     constant TapUniforms &u [[buffer(0)]]) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float3 b = base.sample(linearClamp, in.uv).rgb;
        float3 a = weBox4(add, in.uv, u.tapOffset) * u.scatter;   // weBox4 가 이미 4탭 평균(x0.25)
        return float4(b + a, 1.0);
    }

    /// WE `hdr_upsample_cubic`(UPSAMPLE=1, **BICUBIC=1**) — 위와 같은 4탭·같은 `x0.25 x scatter`
    /// 인데 탭 하나하나가 바이리니어가 아니라 `textureBicubic` 이다(hdr_downsample.frag:66-69).
    ///
    /// 선택 규칙은 드로우 루프에 있다(`0x140183810`–`0x140183822`): 업샘플 소스 레벨 `ebp` 가
    /// `N−2` 이상, 즉 **가장 깊은 두 단**만 이 머티리얼을 쓴다(`0x31a8`), 나머지는 `0x31a0`.
    /// 깊은 단은 확대 배율이 가장 커서 바이리니어면 블록 계단이 그대로 헤일로에 실린다.
    fragment float4 hdrBloomUpsampleCubic(BloomVertexOut in [[stage_in]],
                                          texture2d<float> base [[texture(0)]],
                                          texture2d<float> add [[texture(1)]],
                                          constant TapUniforms &u [[buffer(0)]]) {
        constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
        float3 b = base.sample(linearClamp, in.uv).rgb;
        float2 t = u.tapOffset;
        float3 a = (weBicubic(add, in.uv + float2(-t.x, -t.y), t) +
                    weBicubic(add, in.uv + float2( t.x, -t.y), t) +
                    weBicubic(add, in.uv + float2(-t.x,  t.y), t) +
                    weBicubic(add, in.uv + float2( t.x,  t.y), t)) * 0.25 * u.scatter;
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
