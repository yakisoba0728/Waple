import Foundation
import Metal
import simd
import WapleCore

/// H5: 볼류메트릭 라이트 샤프트 — WE `shaders/volumetricsfront.frag` 의 **깊이 기반 레이마치**를 이식한다.
///
/// ## WE 실물 구조(복원 근거는 `docs/re/volumetric-light.md`)
/// WE 는 라이트 하나당 두 패스 + 프레임당 리졸브 세 패스로 굴린다.
/// 1. `volumetrics_back` → `_rt_volumetricsBack`(**컬러 없음·뎁스 전용**, 풀해상도). 라이트 헐의
///    백페이스 깊이 = 레이의 **출구**. (`volumetricsback.frag` 는 본문이 비어 있다 — 뎁스만 남긴다.)
/// 2. `volumetrics_front`(카메라가 헐 안이면 `volumetrics_fullscreen`) → `_rt_volumetricsLightBuffer`,
///    additive. 헐 프론트페이스(=**입구**)에서 출구까지 N 샘플 레이마치. 출구는 씬 뎁스
///    (`_rt_volumetricsSingle`)로 한 번 더 잘려 **지오메트리에 가려진다**.
/// 3~5. `blur_k3`(h→v, QUALITY<3 에서만) → `passthrough` additive 합성.
///
/// ## Waple 의 이식 형태 — 무엇을 옮겼고 무엇이 남았나
/// - **옮겼다**: 레이마치 자체(샘플 수 규칙·스텝 분할·반경 감쇠·콘 스무드스텝·최종 `×0.1` 스케일).
///   픽셀 값을 결정하는 부분은 전부 실물 수식이다.
/// - **해석해로 대체**: 헐 입·출구 두 뎁스 패스 → **뷰 레이 ↔ 반경 구(球) 교차**. WE 의 헐 메시가
///   포인트라이트에선 반경 구, 스팟에선 콘이고 프론트 vert 가 xy 를 0.99 배 하며
///   (`volumetricsfront.vert:13`) 셰이더가 쓰는 반경도 `radius×0.99`(`0x140198760`)라, 구 교차가
///   포인트라이트에 대해서는 동치다. 스팟 콘 헐은 구로 감싸고 콘 감쇠가 바깥을 0 으로 눌러 근사한다.
/// - **남은 구멍(W-17 잔여)**: **씬 뎁스 클립이 없다.** 호출부(`SceneRenderer3D.swift:1466`)의
///   `depthTex` 는 `usage=[.renderTarget]`·`storeAction=.dontCare` 라 샘플할 수 없다. 그래서 샤프트가
///   아직 지오메트리를 통과한다. 이걸 닫으려면 그 뎁스 텍스처에 `.shaderRead` 를 주고 저장해야 하는데
///   그 파일은 이번 담당 범위 밖이다.
/// - **의도적 이탈**: 라이트버퍼 다운스케일(1/4·1/8)과 blur3 h/v 체인을 두지 않고 목적지에 풀해상도로
///   직접 합성한다. WE 자신도 QUALITY≥3 에서는 blur 를 **아예 건너뛴다**(`0x140198d21`) — 즉
///   "풀해상도·무블러" 는 WE 고품질 경로의 모양이고, 저품질 경로의 1/8 다운샘플은 성능 아티팩트다.
///   동봉 코퍼스 도달 0(아래) 인 기능에 RT 두 장 + 파이프라인 셋을 새로 짓지 않는다.
///   복원한 규칙 자체는 `lightBufferDivisor`/`blursLightBuffer` 에 남겨 둔다.
///
/// ## 도달 수 (2026-08-21 실측)
/// `castvolumetrics` — 동봉 172 + 설치본 186 = **358 씬에서 0건**(문자열 자체가 자산 JSON 어디에도
/// 없다. 실행파일에만 있다). 워크샵 코퍼스 162 씬에서 3 씬 / 라이트 4개(전부 true,
/// `spec/corpus/scene-schema.json`). `density` 27건/11씬 · `volumetricsexponent` 27건/11씬 —
/// 다만 `castvolumetrics` 없이는 WE 도 이 패스를 켜지 않는다(기본값 false, `0x14019048d`).
struct VolumetricLightParameters: Equatable {
    /// `VAR_COLOR` = `g_RenderVar4.xyz` (`0x1401987df`–`0x1401987ed`, 씬 키 `color`).
    let color: SIMD3<Float>
    /// `VAR_LIGHT_ORIGIN` = `g_RenderVar2.xyz` (`0x140198797`–`0x1401987a9`, 씬 키 `origin`).
    let position: SIMD3<Float>
    /// `VAR_SPOT_FORWARD` = `g_RenderVar3.xyz` (`0x140198716`–`0x14019871d`). 라이트 → 바깥 방향.
    let direction: SIMD3<Float>
    /// `VAR_DENSITY` = `g_RenderVar2.w` (`0x1401987b2`, 씬 키 `density`, WE 기본 2.0 `0x1401904bc`).
    /// **순수 배수**다 — 거리 감쇠가 아니다(`volumetricsfront.frag:190`). 0 이면 화면에 아무것도 안 나온다.
    let density: Float
    /// `VAR_EXPONENT` = `g_RenderVar4.w` (`0x1401987f5`, 씬 키 `volumetricsexponent`,
    /// WE 기본 1.0 `0x1401904c6`). **반경 감쇠 곡선의 지수**다(`:132`).
    let exponent: Float
    /// `VAR_SPOT_PARAMS_INTENSITY` = `g_RenderVar1.w` (`0x140198780`, 씬 키 `intensity`).
    let intensity: Float
    /// `VAR_SPOT_PARAMS_INNER` = `g_RenderVar1.y`. **코사인**이다 — WE 는 저작 각(도)을
    /// `cos(deg × π/180)` 로 굽는다(`0x1401986ac` f32=0.0174532924, `0x140198770`).
    /// 호출부가 `SceneLight3D.forwardSpotConeCosines` 로 이미 코사인화해 넘긴다.
    let innerCone: Float
    /// `VAR_SPOT_PARAMS_OUTER` = `g_RenderVar1.z` (`0x140198778`). 위와 동일하게 코사인.
    /// 콘 데이터가 없는 라이트는 호출부가 `(inner:1, outer:-1)` 을 준다
    /// (`SceneDocument.swift:734`) — 그게 POINTLIGHT 콤보의 신호다(아래 `isPointLight`).
    let outerCone: Float
    /// `VAR_SPOT_PARAMS_RADIUS` = `g_RenderVar1.x` (`0x140198768`, 씬 키 `radius`).
    /// WE 는 여기에 `radius × 0.99` 를 넣는다(`0x140198760` f32=0.99).
    ///
    /// **[2026-08-21 정정] 호출부는 배선돼 있다** — `SceneRenderer3D.swift:1934` 가
    /// `radius: light.radius` 를 넘긴다. 종전 주석은 "아직 안 넘긴다" 고 적혀 있었는데
    /// 그건 배선 전의 사실이었다. 이 기본값 0 이 남아 있는 것은 **씬이 `radius` 를
    /// 저작하지 않은 경우**(파스가 `?? 0`, `SceneDocument.swift:1916`) 때문이고, 그때
    /// `hullRadius` 가 WE 라이트 생성자 기본 1.0(`0x140190494`)을 대신 써서
    /// **헐 반경 0.99** 로 마치한다 — `encode` 가 한 번만 경고한다.
    ///
    /// 이 퇴화가 그냥 "어둡다" 로 끝나지 않는다는 것을 기록해 둔다. 헐이 0.99 면 샘플이
    /// 라이트에서 0.1~0.8 밖에 안 떨어져 앉고, 그 거리에서는 **반 픽셀 각도 차가 콘
    /// 안팎을 가른다**. 같은 픽스처가 `radius` 유무로 0.5062 ↔ 0.2254 로 갈린 실측이
    /// `docs/re/volumetric-light.md` §6.1 에 있다.
    var radius: Float = 0

    /// POINTLIGHT 콤보 여부. WE 는 라이트 종(`[light+0x2c0]`, `0x140198568`)으로 가르고
    /// 그때 `spotCookie = 1.0`(`:137`) · `maxLightScale ×0.5`(`:119`) 로 간다.
    /// Waple 호출부는 종을 넘기지 않으므로 콘 코사인의 퇴화값으로 판정한다 —
    /// `forwardSpotConeCosines` 는 콘 없는 라이트에만 `outer = -1` 을 낸다(`SceneDocument.swift:734`).
    var isPointLight: Bool { outerCone <= -0.999 }
}

final class VolumetricLightPass {
    /// 셰이더/Swift 가 공유하는 유니폼. 필드 순서·크기가 `metalSource` 의 동명 구조체와 1:1 이어야 한다.
    private struct VolumetricUniforms {
        var cameraEye: SIMD4<Float>
        var cameraFwd: SIMD4<Float>
        var cameraRight: SIMD4<Float>
        var cameraUp: SIMD4<Float>
        /// x=fovY(rad) y=aspect z=nearZ w=farZ
        var projParams: SIMD4<Float>
        /// rgb=`VAR_COLOR`
        var lightColor: SIMD4<Float>
        /// xyz=`VAR_LIGHT_ORIGIN`
        var lightPosition: SIMD4<Float>
        /// xyz=`VAR_SPOT_FORWARD`, w=POINTLIGHT(1) / 스팟(0)
        var lightDirection: SIMD4<Float>
        /// x=`VAR_DENSITY` y=`VAR_EXPONENT` z=`VAR_SPOT_PARAMS_INTENSITY` w=`VAR_SPOT_PARAMS_INNER`
        var lightParams: SIMD4<Float>
        /// x=`VAR_SPOT_PARAMS_OUTER` y=헐 반경(=radius×0.99) z=1/헐반경 w=POINTLIGHT 반감 계수(0.5/1)
        var lightCone: SIMD4<Float>
        /// x=샘플 수 y=1/샘플 수 z,w=예약(0)
        var marchParams: SIMD4<Float>
    }

    private let pipeline: MTLRenderPipelineState
    /// P④: HDR 3D 씬(acc=rgba16Float — accPixelFormat 단일소스, SceneRenderer.swift accPixelFormat 참조)의
    /// float 타깃용 별도 파이프라인. 생성 실패(희귀)는 nil 유지 — HDR 씬에서만 encode 가 false 로 폴백,
    /// bgra8 타깃(LDR/저품질) 경로는 무영향.
    private let pipelineHDR: MTLRenderPipelineState?
    /// `radius` 미배선 경고를 프레임마다 쏟지 않기 위한 1회 래치(`WapleLog.warn` 은 디듀프하지 않는다).
    private var warnedMissingRadius = false

    init?(device: MTLDevice) {
        guard let library = try? WapleProfiler.compile(Self.metalSource, { try device.makeLibrary(source: Self.metalSource, options: nil) }),
              let vertex = library.makeFunction(name: "volumetricVertex"),
              let fragment = library.makeFunction(name: "volumetricFragment") else {
            return nil
        }
        func makeDescriptor(_ format: MTLPixelFormat) -> MTLRenderPipelineDescriptor {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0]!.pixelFormat = format
            // WE `materials/util/volumetrics_front.json`: blending "additive", depthtest/depthwrite disabled.
            descriptor.colorAttachments[0]!.isBlendingEnabled = true
            descriptor.colorAttachments[0]!.rgbBlendOperation = .add
            descriptor.colorAttachments[0]!.alphaBlendOperation = .add
            descriptor.colorAttachments[0]!.sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0]!.sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0]!.destinationRGBBlendFactor = .one
            descriptor.colorAttachments[0]!.destinationAlphaBlendFactor = .one
            return descriptor
        }
        let pipeline: MTLRenderPipelineState?
        do {
            pipeline = try WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: makeDescriptor(.bgra8Unorm)) }
        } catch {
            return nil
        }
        guard let pipeline else { return nil }
        self.pipeline = pipeline
        self.pipelineHDR = try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: makeDescriptor(.rgba16Float)) }
    }

    func encode(
        commandBuffer: MTLCommandBuffer,
        destination: MTLTexture,
        cameraEye: SIMD3<Float>,
        cameraFwd: SIMD3<Float>,
        cameraRight: SIMD3<Float>,
        cameraUp: SIMD3<Float>,
        fovY: Float,
        aspect: Float,
        nearZ: Float,
        farZ: Float,
        light: VolumetricLightParameters
    ) -> Bool {
        guard destination.textureType == .type2D else { return false }
        let selectedPipeline: MTLRenderPipelineState
        switch destination.pixelFormat {
        case .bgra8Unorm: selectedPipeline = pipeline
        case .rgba16Float:
            guard let pipelineHDR else { return false }  // HDR 파이프라인 생성 실패(희귀) — 폴백 없이 스킵.
            selectedPipeline = pipelineHDR
        default: return false
        }
        if light.radius <= 0 { warnMissingRadiusOnce(light) }
        let hull = Self.hullRadius(radius: light.radius)
        // 헐이 0 이거나 카메라 절두체가 퇴화면 마치할 구간 자체가 없다 — 그릴 게 없으므로 성공으로 접는다
        // (additive 항등). false 는 "파이프라인이 없다" 는 별개의 사실에만 쓴다.
        guard hull > 0, farZ > nearZ, nearZ > 0 else { return true }

        let isPoint = light.isPointLight
        // `pow(base, exp)` 의 base 는 셰이더에서 saturate 로 이미 [0,1] 이라 NaN 은 못 나오지만,
        // **음수 지수**면 base=0 인 헐 경계에서 +inf 가 되어 그 픽셀이 통째로 하얘진다.
        // 저작값은 무클램프 파스(`SceneDocument.swift:1919`)고 코퍼스 실측 범위는 1.0–3.04라
        // (`spec/corpus/scene-schema.json`) 이 클램프는 정상 씬을 바꾸지 않는다.
        let exponent = max(0, light.exponent)
        let sampleCount = Float(Self.marchSampleCount)
        var uniforms = VolumetricUniforms(
            cameraEye: SIMD4(cameraEye.x, cameraEye.y, cameraEye.z, 1),
            cameraFwd: SIMD4(cameraFwd.x, cameraFwd.y, cameraFwd.z, 0),
            cameraRight: SIMD4(cameraRight.x, cameraRight.y, cameraRight.z, 0),
            cameraUp: SIMD4(cameraUp.x, cameraUp.y, cameraUp.z, 0),
            projParams: SIMD4(fovY * .pi / 180, aspect, nearZ, farZ),
            lightColor: SIMD4(light.color.x, light.color.y, light.color.z, 1),
            lightPosition: SIMD4(light.position.x, light.position.y, light.position.z, 1),
            lightDirection: SIMD4(light.direction.x, light.direction.y, light.direction.z, isPoint ? 1 : 0),
            lightParams: SIMD4(light.density, exponent, light.intensity, light.innerCone),
            lightCone: SIMD4(light.outerCone, hull, 1 / hull, Self.pointLightScale(isPoint: isPoint)),
            marchParams: SIMD4(sampleCount, 1 / sampleCount, 0, 0))

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return false
        }
        encoder.setRenderPipelineState(selectedPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VolumetricUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func warnMissingRadiusOnce(_ light: VolumetricLightParameters) {
        guard !warnedMissingRadius else { return }
        warnedMissingRadius = true
        WapleLog.warn("[Waple] 볼류메트릭 라이트에 radius 가 없다(density=\(light.density)) — "
            + "WE 라이트 기본 반경 1.0 으로 마치한다(사실상 비가시). "
            + "SceneRenderer3D 의 VolumetricLightParameters 생성에 `radius: light.radius` 를 배선할 것.")
    }

    // MARK: - 복원한 순수 산술 (리눅스 단독 컴파일 대조 대상 — docs/re/volumetric-light.md §6)

    /// Waple 이 사용하는 WE QUALITY 티어. WE 는 앱 설정 바이트 `[renderCtx+0x1ad]` 를 그대로
    /// `QUALITY` 콤보로 넣는다(`0x140198273`). Waple 엔 대응 설정이 없어 최고 티어로 고정한다 —
    /// 이 패스는 셰도우/쿠키 텍스처를 바인딩하지 않으므로 `SHADOW||COOKIE` 가 아닌 가지로 간다.
    static let qualityTier = 4
    /// 실제로 셰이더에 굽는 샘플 수. 티어 4 · 셰도우 없음 → **8**(`volumetricsfront.frag:88-96`).
    static let marchSampleCount = VolumetricMath.sampleCount(quality: qualityTier, shadowed: false)

    /// `VAR_SPOT_PARAMS_RADIUS` (`0x140198760`) — WE 는 셰이더에 `radius × 0.99` 를 넘긴다.
    /// 반경 미저작(=0)이면 WE 라이트 생성자 기본값 1.0(`0x140190494`)을 대신 쓴다.
    static func hullRadius(radius: Float) -> Float { VolumetricMath.hullRadius(radius: radius) }

    /// POINTLIGHT 는 `maxLightScale` 에 0.5 를 더 곱한다(`volumetricsfront.frag:119` vs `:121`).
    static func pointLightScale(isPoint: Bool) -> Float { VolumetricMath.pointLightScale(isPoint: isPoint) }

    static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    // WE `volumetricsfront.frag:78-97` 의 QUALITY 콤보를 컴파일 상수로 굽는다(WE 도 콤보별 변형을 굽는다).
    #define WE_VOL_SAMPLES \(VolumetricLightPass.marchSampleCount)u
    #define WE_VOL_SAMPLES_F \(VolumetricLightPass.marchSampleCount).0

    struct VolumetricVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VolumetricVertexOut volumetricVertex(uint vertexID [[vertex_id]]) {
        float2 p = float2(vertexID == 2 ? 3.0 : -1.0, vertexID == 1 ? 3.0 : -1.0);
        VolumetricVertexOut out;
        out.position = float4(p, 0.0, 1.0);
        out.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
        return out;
    }

    struct VolumetricUniforms {
        float4 cameraEye;
        float4 cameraFwd;
        float4 cameraRight;
        float4 cameraUp;
        float4 projParams;     // x=fovY(rad) y=aspect z=near w=far
        float4 lightColor;     // rgb = VAR_COLOR
        float4 lightPosition;  // xyz = VAR_LIGHT_ORIGIN
        float4 lightDirection; // xyz = VAR_SPOT_FORWARD, w = POINTLIGHT
        float4 lightParams;    // x=VAR_DENSITY y=VAR_EXPONENT z=INTENSITY w=INNER(cos)
        float4 lightCone;      // x=OUTER(cos) y=hullRadius z=1/hullRadius w=pointScale
        float4 marchParams;    // x=sampleCount y=1/sampleCount
    };

    fragment float4 volumetricFragment(
        VolumetricVertexOut in [[stage_in]],
        constant VolumetricUniforms &u [[buffer(0)]]
    ) {
        // 픽셀 뷰 레이(월드) — fovY/aspect 로부터 perspective 재구성.
        float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
        float tanHalf = tan(u.projParams.x * 0.5);
        float3 dir = normalize(
            u.cameraFwd.xyz +
            u.cameraRight.xyz * (ndc.x * tanHalf * u.projParams.y) +
            u.cameraUp.xyz * (ndc.y * tanHalf));

        // WE 의 두 뎁스 패스(_rt_volumetricsBack 백페이스 = 출구, 프론트페이스 = 입구)를
        // 뷰 레이 ↔ 반경 구 교차로 대체한다. 근평면 클램프는 WE 의 FULLSCREEN 콤보
        // (카메라가 헐 안 → 근평면에서 마치 시작, volumetricsfront.vert:16-22)와 같은 뜻이다.
        float3 oc = u.cameraEye.xyz - u.lightPosition.xyz;
        float b = dot(oc, dir);
        float c = dot(oc, oc) - u.lightCone.y * u.lightCone.y;
        float disc = b * b - c;
        if (disc <= 0.0) { return float4(0.0); }          // WE `:67,70` 의 clip() 자리
        float sq = sqrt(disc);
        float tEnter = max(-b - sq, u.projParams.z);
        float tExit = min(-b + sq, u.projParams.w);        // WE 는 여기서 씬 뎁스로 한 번 더 자른다(미보유)
        if (!(tExit > tEnter)) { return float4(0.0); }

        float3 worldStart = u.cameraEye.xyz + dir * tEnter;
        float segment = tExit - tEnter;
        // WE `:113` — 스텝은 구간을 (N+1) 로 나누고, 루프가 **더한 뒤** 샘플하므로 끝점을 안 밟는다.
        float3 worldStep = dir * (segment / (WE_VOL_SAMPLES_F + 1.0));

        // WE `:115-122` — maxLightScale = intensity × |구간| / radius (POINTLIGHT 은 ×0.5).
        float maxLightScale = u.lightParams.z * segment * u.lightCone.z * u.lightCone.w;

        float shadowFactor = 0.0;
        float3 p = worldStart;
        for (uint s = 0u; s < WE_VOL_SAMPLES; ++s) {
            p += worldStep;
            float3 lightDelta = p - u.lightPosition.xyz;
            float dist = length(lightDelta);
            // WE `:132` — pow(saturate(1 - dist/radius), VAR_EXPONENT). 반경 밖은 정확히 0 이다.
            float radiusFalloff = pow(saturate(1.0 - dist * u.lightCone.z), u.lightParams.y);
            float spotCookie = 1.0;
            if (u.lightDirection.w < 0.5) {
                // WE `:139-140` — dot(normalize(라이트→샘플), forward) 에 smoothstep(outer, inner, ·).
                float cosAngle = dot(lightDelta / max(dist, 1e-6), u.lightDirection.xyz);
                spotCookie = smoothstep(u.lightCone.x, u.lightParams.w, cosAngle);
            }
            shadowFactor += radiusFalloff * spotCookie;   // WE `:167,180` (셰도우/쿠키 미바인딩 가지)
        }
        shadowFactor *= u.marchParams.y;                  // WE `:187` — /= sampleCount

        // WE `:190` — VAR_DENSITY × maxLightScale × shadowFactor × VAR_COLOR × 0.1
        float3 rgb = u.lightParams.x * maxLightScale * shadowFactor * u.lightColor.rgb * 0.1;
        return float4(rgb, 1.0);                          // WE `:191` — a = 1
    }
    """
}

/// WE 볼류메트릭의 **순수 산술만** 모은 자리. `import Foundation` 하나로 서므로 이 블록만
/// 잘라 리눅스에서 단독 컴파일·실행해 값을 대조할 수 있다(`docs/re/volumetric-light.md` §6).
/// 셰이더가 GPU 에서 하는 계산과 같은 식을 CPU 에 한 벌 더 두는 이유가 그 대조다.
///
/// **`Metal` 도 `simd` 모듈도 쓰지 않는다.** `SIMD3<Float>` 는 표준 라이브러리 타입이라
/// 리눅스에서 그대로 서지만 `simd_dot`/`simd_length`/`simd_normalize` 는 macOS 전용 모듈이다 —
/// 그래서 벡터 산술은 아래 `dot3`/`length3`/`normalize3` 로 직접 적었다. 여기에 `simd` 나
/// `Metal` 심볼을 들이면 위 추출 절차가 그 자리에서 죽는다.
///
/// **덮는 범위: `metalSource` 프래그먼트 전체다.** 감쇠 항만 있던 시절엔 CPU 로 한 픽셀을
/// 풀려면 호출자가 레이 재구성을 직접 다시 적어야 했고, 그래서 "CPU 1.0 vs GPU 0.2235" 라는
/// 유령 발산이 나왔다(§6.1). 프래그먼트에 있는 단계는 여기에도 있어야 한다.
enum VolumetricMath {
    /// `volumetricsfront.frag:78-97` — QUALITY 콤보 → 레이마치 샘플 수.
    /// `SHADOW || COOKIE` 가지가 12~64, 아닌 가지가 2~8 이다. QUALITY 는 앱 설정
    /// `[renderCtx+0x1ad]`(`0x140198273`)이고 씬 JSON 키가 아니다.
    static func sampleCount(quality: Int, shadowed: Bool) -> Int {
        if shadowed {
            switch quality {
            case 4: return 64
            case 3: return 32
            case 2: return 24
            default: return 12
            }
        }
        switch quality {
        case 4: return 8
        case 3: return 5
        case 2: return 3
        default: return 2
        }
    }

    /// 라이트버퍼(`_rt_volumetricsLightBuffer`/`B`, `_rt_volumetricsSingle`)의 **다운스케일 분모**.
    /// `0x140196d79`–`0x140196d88`: `edi = (quality >= 3) ? 4 : 8` 이고 그 값이 RT 생성기
    /// `sub_1401aadb0` 의 4번째 인자로 간다 — 같은 인자가 `_rt_FullFrameBuffer`=1 ·
    /// `_rt_4FrameBuffer`=4 · `_rt_8FrameBuffer`=8 (`0x14017f585`–`0x14017f63d`)이라 분모가 맞다.
    /// `_rt_volumetricsBack` 만 1(풀해상도)이다(`0x140196dc4`).
    ///
    /// **복원 전용(현 경로 미소비)** — Waple 은 목적지에 풀해상도로 직접 합성한다(위 클래스 주석의
    /// "의도적 이탈"). 라이트버퍼를 실제로 만들 때 이 규칙이 정본이다.
    static func lightBufferDivisor(quality: Int) -> Int { quality >= 3 ? 4 : 8 }

    /// blur3 h/v 체인을 태우는가. `0x140196ea0`–`0x140196ea4` 가 QUALITY≥3 이면
    /// `_rt_volumetricsLightBufferB` 와 blur 머티리얼 두 장을 **아예 만들지 않고**,
    /// 리졸브(`0x140198d21`)도 같은 조건으로 blur 두 패스를 건너뛴다.
    /// 즉 고품질일수록 샘플이 많아 블러가 필요 없다는 설계다.
    ///
    /// **복원 전용(현 경로 미소비)** — 위와 같은 이유.
    static func blursLightBuffer(quality: Int) -> Bool { quality < 3 }

    /// `blur_k3` 가 쓰는 `blur3` 탭 가중치(`shaders/common_blur.h:25-30`) — (−1, 0, +1) 픽셀.
    /// **복원 전용(현 경로 미소비)**.
    static let blur3Weights: [Float] = [0.25, 0.5, 0.25]

    /// `volumetricsfront.frag:132` — 반경 감쇠. 반경 밖은 **정확히 0**(무한 꼬리 없음).
    ///
    /// **역수 곱으로 적는다.** WE 도 `invRadius = 1/R` 을 한 번 잡아 `length(lightDelta) * invRadius`
    /// 로 곱하고(`:116`,`:132`), `metalSource` 도 `lightCone.z`(=`1/hull`, `encode` 가 채운다)를
    /// 곱한다. 여기서만 `distance / hullRadius` 로 나누면 마지막 자리가 GPU 와 갈린다 — 값이
    /// 눈에 띄게 달라지지는 않지만, **두 벌을 비트로 대조할 수 없게 되는 것**이 문제다.
    static func radialFalloff(distance: Float, hullRadius: Float, exponent: Float) -> Float {
        guard hullRadius > 0 else { return 0 }
        let t = 1 - distance * (1 / hullRadius)
        let base = t < 0 ? 0 : (t > 1 ? 1 : t)
        if base <= 0 { return exponent <= 0 ? 1 : 0 }   // pow(0, 0) = 1 — GPU 와 같은 규약
        return powf(base, exponent)
    }

    /// `volumetricsfront.frag:140` — `smoothstep(outer, inner, cos)`. GLSL/MSL 과 같은 3차 보간이다.
    /// 호출부는 `inner > outer` 를 보장한다(`SceneDocument.swift:739` 가 `+1e-4` 로 벌려 둔다).
    static func coneFalloff(cosAngle: Float, innerCos: Float, outerCos: Float) -> Float {
        let span = innerCos - outerCos
        guard span > 0 else { return cosAngle >= innerCos ? 1 : 0 }
        let raw = (cosAngle - outerCos) / span
        let t = raw < 0 ? 0 : (raw > 1 ? 1 : raw)
        return t * t * (3 - 2 * t)
    }

    /// `volumetricsfront.vert:13` + `0x140198760` — 셰이더가 받는 헐 반경은 `radius × 0.99`.
    /// 반경 미저작(0 이하)이면 WE 라이트 생성자 기본값 1.0(`0x140190494`)을 쓴다.
    static func hullRadius(radius: Float) -> Float { (radius > 0 ? radius : 1) * 0.99 }

    /// `volumetricsfront.frag:119` vs `:121` — POINTLIGHT 만 최종 스케일이 반이다.
    static func pointLightScale(isPoint: Bool) -> Float { isPoint ? 0.5 : 1 }

    /// `volumetricsfront.frag:115-122` — `maxLightScale`. 곱셈 순서까지 `metalSource` 와 같다
    /// (`intensity × segment × (1/hull) × pointScale`) — `radialFalloff` 와 같은 이유로 역수 곱이다.
    static func maxLightScale(intensity: Float, segmentLength: Float, hullRadius: Float, isPoint: Bool) -> Float {
        guard hullRadius > 0 else { return 0 }
        return intensity * segmentLength * (1 / hullRadius) * pointLightScale(isPoint: isPoint)
    }

    /// `volumetricsfront.frag:113` — k 번째 샘플이 구간 [0,1] 의 어디에 앉는가.
    /// 스텝이 `(end-start)/(N+1)` 이고 루프가 **먼저 더한 뒤** 샘플하므로 `(k+1)/(N+1)` 이다
    /// (0-based k). 끝점을 절대 안 밟는 것이 이 분할의 요점이다.
    static func samplePosition(index: Int, count: Int) -> Float {
        guard count > 0 else { return 0 }
        return Float(index + 1) / Float(count + 1)
    }

    /// `volumetricsfront.frag:190` — 최종 스칼라(색 곱하기 전). `0.1` 이 WE 의 고정 스케일이다.
    static func finalScale(density: Float, maxLightScale: Float, meanFactor: Float) -> Float {
        density * maxLightScale * meanFactor * 0.1
    }

    // MARK: - 프래그먼트 **전체**의 CPU 미러 (`metalSource` 와 1:1)
    //
    // [2026-08-21] 이 아래가 왜 생겼는지 남긴다. 위쪽 함수들은 **감쇠 항만** 갖고 있었다 —
    // 레이 방향 재구성 · 구 교차 · `tEnter`/`tExit` 클램프 · 마치 루프는 `metalSource`
    // **안에만** 있었고, CPU 로 한 픽셀을 풀려면 호출자(테스트·검산 스크립트)가 그 네
    // 단계를 **직접 다시 적어야** 했다. 그래서 "CPU 는 1.0 인데 GPU 는 0.2235, 4.5배 차"
    // 라는 보고가 나왔다. 실제로는 두 벌이 갈린 게 아니라 **검산 쪽이 광축(ndc=0) 레이를
    // 풀고 GPU 는 픽셀 중심(ndc=±1/W) 레이를 푼 것**이었다(전말은
    // `docs/re/volumetric-light.md` §6.1). 재구성 단계가 CPU 쪽에 없었던 것이 그 사고의
    // 물리적 원인이므로, 여기서 그 구멍을 메운다.
    //
    // **아래는 `import Foundation` 하나로 선다.** `SIMD3<Float>` 는 표준 라이브러리 타입이고
    // (`simd` 모듈이 아니다), 벡터 산술은 `dot3`/`length3`/`normalize3` 로 직접 적었다 —
    // 그래야 이 enum 블록만 잘라 리눅스에서 컴파일·실행하는 §6 대조 절차가 계속 성립한다.

    /// `import simd` 없이 쓰는 3벡터 내적. `simd_dot` 은 macOS 전용 모듈이라 쓰지 않는다.
    static func dot3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }

    /// 위와 같은 이유의 길이.
    static func length3(_ a: SIMD3<Float>) -> Float { sqrtf(dot3(a, a)) }

    /// 위와 같은 이유의 정규화. 영벡터는 그대로 돌려준다(MSL `normalize` 는 NaN 이지만,
    /// 호출부가 영벡터를 만들 수 없는 자리라 방어값이 픽셀을 바꾸지 않는다).
    static func normalize3(_ a: SIMD3<Float>) -> SIMD3<Float> {
        let n = length3(a)
        return n > 0 ? a * (1 / n) : a
    }

    /// 픽셀 (x, y) 중심의 NDC. `metalSource` 의 `volumetricVertex` uv 규약과 같은 값이다 —
    /// `uv = ((x+0.5)/W, (y+0.5)/H)`(y 는 **위가 0**), `ndc = (uv.x·2−1, 1−uv.y·2)`.
    ///
    /// > **광축 위에 앉는 픽셀은 없다.** 짝수 해상도(64×64 등)의 가장 가운데 픽셀도 반 픽셀
    /// > (`1/W`) 만큼 비껴 있다. 좁은 콘 + 작은 헐에서는 그 반 픽셀이 픽셀 값을 **몇 배**로
    /// > 바꾼다(§6.1 의 4.44배). GPU 를 검산할 때 `ndc = (0,0)` 을 쓰면 안 되는 이유다.
    /// > 광축 레이를 일부러 보고 싶으면 `width: 1, height: 1` 로 부르면 정확히 (0,0)이 나온다.
    static func pixelNDC(x: Int, y: Int, width: Int, height: Int) -> (x: Float, y: Float) {
        guard width > 0, height > 0 else { return (0, 0) }
        let u = (Float(x) + 0.5) / Float(width)
        let v = (Float(y) + 0.5) / Float(height)
        return (u * 2 - 1, 1 - v * 2)
    }

    /// `metalSource` 의 `dir` 재구성 — `normalize(fwd + right·(ndc.x·tanHalf·aspect) + up·(ndc.y·tanHalf))`.
    /// `aspect` 가 **x 에만** 붙는 것은 `fov` 가 세로축이기 때문이고, 그 규약은
    /// `Scene3DMath.perspective`(`x = y / aspect`, `y = 1/tan(fovY/2)`)와 같은 출처다.
    static func viewRayDirection(ndc: (x: Float, y: Float), fovYDegrees: Float, aspect: Float,
                                 forward: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>) -> SIMD3<Float> {
        let tanHalf = tanf(fovYDegrees * Float.pi / 180 * 0.5)
        return normalize3(forward + right * (ndc.x * tanHalf * aspect) + up * (ndc.y * tanHalf))
    }

    /// `metalSource` 의 헐 구간 — 뷰 레이 ↔ 반경 구 교차 + 근/원 평면 클램프.
    /// WE 의 헐 뎁스 2패스(`volumetricsfront.frag:105-113`)를 해석해로 대체한 자리다.
    ///
    /// **`direction` 이 단위벡터라는 가정**으로 `a = dot(d,d) = 1` 을 접은 축약형이다
    /// (`b = dot(oc,d)`, `c = |oc|² − R²`, `disc = b² − c`). `viewRayDirection` 이 정규화해
    /// 주므로 성립한다 — 정규화 안 된 방향을 넣으면 조용히 틀린다.
    ///
    /// nil = 그 픽셀 기여 0(교차 없음 `disc ≤ 0`, 또는 구간 없음 `exit ≤ enter`).
    /// MSL 쪽 `return float4(0.0)` 과 같은 뜻이고, 그 자리가 WE `:67,70` 의 `clip()` 이다.
    static func hullSpan(eye: SIMD3<Float>, direction: SIMD3<Float>, lightPosition: SIMD3<Float>,
                         hullRadius: Float, nearZ: Float, farZ: Float) -> (enter: Float, exit: Float)? {
        let oc = eye - lightPosition
        let b = dot3(oc, direction)
        let c = dot3(oc, oc) - hullRadius * hullRadius
        let disc = b * b - c
        guard disc > 0 else { return nil }
        let sq = sqrtf(disc)
        let enter = max(-b - sq, nearZ)
        let exit = min(-b + sq, farZ)          // WE 는 여기서 씬 뎁스로 한 번 더 자른다(미보유)
        guard exit > enter else { return nil }
        return (enter, exit)
    }

    /// `metalSource` 의 `VolumetricUniforms` 와 같은 내용을 CPU 쪽에 담는 입력.
    /// 필드 이름을 셰이더 슬롯에 맞춰 둬야 대조표(§6.2)를 눈으로 따라갈 수 있다.
    struct PixelInput {
        var eye: SIMD3<Float>
        var forward: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var fovYDegrees: Float
        var aspect: Float
        var nearZ: Float
        var farZ: Float
        var lightPosition: SIMD3<Float>
        /// `VAR_SPOT_FORWARD` — 라이트 → 바깥. `SceneLight3D.forwardLightAxis` 산출물(단위벡터).
        var lightForward: SIMD3<Float>
        var density: Float
        var exponent: Float
        var intensity: Float
        /// **코사인**이다(`SceneLight3D.forwardSpotConeCosines`) — 도(度) 원값이 아니다.
        var innerCos: Float
        var outerCos: Float
        /// 씬 저작 `radius`. 0(무저작)이면 `hullRadius(radius:)` 가 WE 기본 1.0 을 대신 쓴다.
        var radius: Float
        /// 기본값을 **두지 않는다** — 여기에 `VolumetricLightPass.marchSampleCount` 를 적으면
        /// 이 enum 이 클래스에 묶여 §6 의 "블록만 잘라 리눅스에서 컴파일" 이 깨진다.
        /// 모듈 안 호출부는 그 상수를 그대로 넘기면 된다(그게 셰이더가 굽는 값이다).
        var sampleCount: Int
        /// `VolumetricLightParameters.isPointLight` 와 **같은 판정**(단일 규약).
        var isPoint: Bool { outerCos <= -0.999 }
    }

    /// `volumetricsfront.frag:128-187` = `metalSource` 의 마치 루프. 반환값은 `shadowFactor / N`.
    ///
    /// **닫힌 꼴(`samplePosition`)로 계산하지 않고 `p += step` 으로 누산한다.** WE 도
    /// (`:130` `worldStart.xyz += worldStep`) MSL 도 누산이고, 누산은 반올림이 쌓인다 —
    /// N=8 에서 차이는 1e-7 수준이라 그림은 안 바뀌지만, **비트 대조를 하려면 같은 순서로
    /// 적어야 한다**. `samplePosition` 은 "k번째 샘플이 구간의 어디냐" 를 말하는 해석식으로
    /// 남기고, 실제 적분 경로는 이쪽이 정본이다.
    static func marchMeanFactor(_ i: PixelInput, direction: SIMD3<Float>,
                                span: (enter: Float, exit: Float), hullRadius: Float) -> Float {
        guard i.sampleCount > 0, hullRadius > 0 else { return 0 }
        let invHull = 1 / hullRadius
        // `encode` 가 유니폼에 싣기 전에 하는 클램프를 여기서도 한다 — 음수 지수는 헐 경계
        // (base=0)에서 +inf 가 되어 그 픽셀이 통째로 하얘진다. GPU 가 절대 못 보는 값을
        // CPU 미러만 보면 그것부터가 두 벌이 갈리는 자리다.
        let exponent = max(0, i.exponent)
        let segment = span.exit - span.enter
        let step = direction * (segment / (Float(i.sampleCount) + 1))
        var p = i.eye + direction * span.enter
        var shadowFactor: Float = 0
        for _ in 0..<i.sampleCount {
            p += step
            let lightDelta = p - i.lightPosition
            let dist = length3(lightDelta)
            // WE `:132` — 반경 밖은 정확히 0. `radialFalloff` 도 같은 역수 곱이다.
            let t = 1 - dist * invHull
            let base = t < 0 ? 0 : (t > 1 ? 1 : t)
            let radiusFalloff: Float = base <= 0 ? (exponent <= 0 ? 1 : 0) : powf(base, exponent)
            var spotCookie: Float = 1
            if !i.isPoint {
                // WE `:139-140` — dot(normalize(라이트→샘플), forward) 에 smoothstep(outer, inner, ·).
                // 나눗셈 형태까지 MSL 과 같게 적는다(역수 곱으로 바꾸면 마지막 자리가 갈린다).
                let cosAngle = dot3(lightDelta / max(dist, 1e-6), i.lightForward)
                spotCookie = coneFalloff(cosAngle: cosAngle, innerCos: i.innerCos, outerCos: i.outerCos)
            }
            shadowFactor += radiusFalloff * spotCookie
        }
        return shadowFactor * (1 / Float(i.sampleCount))   // WE `:187` — /= sampleCount
    }

    /// **한 픽셀의 최종 스칼라**(`VAR_COLOR` 를 곱하기 전). `metalSource` 의 `volumetricFragment`
    /// 를 줄 순서 그대로 옮긴 것이라, 두 벌이 갈리면 이 값이 갈린다 — GPU 없이 CPU 에서
    /// 같은 픽셀을 풀어 대조하는 것이 이 함수의 유일한 존재 이유다.
    ///
    /// 흰 라이트(`color = 1 1 1`)면 이 값이 곧 화면 채널값이고, 목적지가 `bgra8Unorm` 이면
    /// `round(saturate(v) × 255)` 가 캡처 PNG 의 바이트다(`writeFramePNG` 는 감마를 안 먹인다 —
    /// `OffscreenCapture.png` 가 `.deviceRGB` 로 원바이트를 그대로 싣는다).
    static func pixelValue(_ i: PixelInput, x: Int, y: Int, width: Int, height: Int) -> Float {
        let hull = hullRadius(radius: i.radius)
        guard hull > 0, i.farZ > i.nearZ, i.nearZ > 0 else { return 0 }   // `encode` 의 게이트와 동일
        let ndc = pixelNDC(x: x, y: y, width: width, height: height)
        let dir = viewRayDirection(ndc: ndc, fovYDegrees: i.fovYDegrees, aspect: i.aspect,
                                   forward: i.forward, right: i.right, up: i.up)
        guard let span = hullSpan(eye: i.eye, direction: dir, lightPosition: i.lightPosition,
                                  hullRadius: hull, nearZ: i.nearZ, farZ: i.farZ) else { return 0 }
        let mls = maxLightScale(intensity: i.intensity, segmentLength: span.exit - span.enter,
                                hullRadius: hull, isPoint: i.isPoint)
        let mean = marchMeanFactor(i, direction: dir, span: span, hullRadius: hull)
        return finalScale(density: i.density, maxLightScale: mls, meanFactor: mean)
    }
}
