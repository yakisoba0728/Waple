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
///   포인트라이트에선 반경 구, 스팟에선 콘이고, 셰이더가 쓰는 반경(`VAR_SPOT_PARAMS_RADIUS`)이
///   `radius × 0.99`(`0x140198760` f32=0.99, 종 무관)라 구 교차가 포인트라이트에 대해서는 동치다.
///   스팟 콘 헐은 구로 감싸고 콘 감쇠가 바깥을 0 으로 눌러 근사한다.
///   **[2026-08-21 정정] `volumetricsfront.vert:13` 의 0.99 는 이것과 다른 0.99 다.** 그건 헐 메시
///   정점의 **xy 만** 줄이고(`a_Position * vec3(0.99, 0.99, 1.0)`) `#if POINTLIGHT` 가지(`:11`)에는
///   **아예 없다** — 즉 콘 헐 단면을 살짝 좁혀 경계 새는 것을 막는 지오메트리 보정이지,
///   유니폼 반경 스케일이 아니다. 두 0.99 를 한 근거로 묶어 인용하면 안 된다.
/// - **[2026-08-21 닫힘] 씬 뎁스 클립(W-17 단계 1)**: 종전엔 호출부의 pooled depth 가
///   `usage = [.renderTarget]` · `storeAction = .dontCare` 라 샘플조차 못 했고 샤프트가
///   지오메트리를 통과했다. 지금은 `SceneRenderer3D.pooledDepth` 가 `.shaderRead` 를 함께 주고,
///   `encode3D` 의 `needsDepthStore` 게이트에 볼류메트릭 라이트 유무가 들어가며(`hasVolumetrics`),
///   그 텍스처가 `encode(sceneDepth:)` 로 넘어와 아래 `tExit = min(tExit, limit)` 에 쓰인다.
///   지오메트리가 없는 픽셀(클리어 뎁스 1.0)에서는 무연산이라 종전 픽셀값이 그대로 보존된다.
/// - **의도적 이탈**: 라이트버퍼 다운스케일(1/4·1/8)과 blur3 h/v 체인을 두지 않고 목적지에 풀해상도로
///   직접 합성한다. WE 자신도 QUALITY≥3 에서는 blur 를 **아예 건너뛴다**(`0x140198d21`) — 즉
///   "풀해상도·무블러" 는 WE 고품질 경로의 모양이고, 저품질 경로의 1/8 다운샘플은 성능 아티팩트다.
///   동봉 코퍼스 도달 0(아래) 인 기능에 RT 두 장 + 파이프라인 셋을 새로 짓지 않는다.
///   복원한 규칙 자체는 `lightBufferDivisor`/`blursLightBuffer` 에 남겨 둔다.
///
/// ## 도달 수 (2026-08-21 실측)
/// `castvolumetrics` — 설치본 `assets/ + projects/` 단일 모집단 **186 씬에서 0건**
/// (문자열 자체가 자산 JSON 어디에도
/// 없다. 실행파일에만 있다). 워크샵 코퍼스 162 씬에서 3 씬 / 라이트 4개(전부 true,
/// `spec/corpus/scene-schema.json`). `density` 27건/11씬 · `volumetricsexponent` 27건/11씬 —
/// 다만 `castvolumetrics` 없이는 WE 도 이 패스를 켜지 않는다(기본값 false, `0x14019048d`).
struct VolumetricLightParameters: Equatable {
    /// `VAR_COLOR` = `g_RenderVar4.xyz` (`0x1401987df`–`0x1401987ed`, 씬 키 `color`).
    let color: SIMD3<Float>
    /// `VAR_LIGHT_ORIGIN` = `g_RenderVar2.xyz` (`0x140198797`–`0x1401987a9`, 씬 키 `origin`).
    let position: SIMD3<Float>
    /// `VAR_SPOT_FORWARD` = `g_RenderVar3.xyz` (`0x140198680`–`0x140198687`: `[light+0x320]` →
    /// 상수블록 `+0xd8`). 라이트 → 바깥 방향.
    /// **[2026-08-21 정정] 종전 인용 `0x140198716`–`0x14019871d` 는 한 칸 밀린 값이다** — 그 두
    /// 명령은 `[light+0x310]` 을 `+0xa8`(= `g_RenderVar0` = `VAR_SHADOWMAP_TRANSFORMS`)에 싣는
    /// 다른 쌍이다. 상수블록은 `+0xa8`부터 stride 0x10 이므로 `+0xd8` 이 `g_RenderVar3` 이고,
    /// 그 자리에 실리는 것은 `0x140198680`(load `[rsi+0x320]`)/`0x140198687`(store)다.
    let direction: SIMD3<Float>
    /// `VAR_DENSITY` = `g_RenderVar2.w` (`0x1401987b2`, 씬 키 `density`, WE 기본 2.0 `0x1401904bc`).
    /// **순수 배수**다 — 거리 감쇠가 아니다(`volumetricsfront.frag:190`). 0 이면 화면에 아무것도 안 나온다.
    let density: Float
    /// `VAR_EXPONENT` = `g_RenderVar4.w` (`0x1401987f5`, 씬 키 `volumetricsexponent`,
    /// WE 기본 1.0 `0x1401904c6`). **반경 감쇠 곡선의 지수**다(`:132`).
    let exponent: Float
    /// `VAR_SPOT_PARAMS_INTENSITY` = `g_RenderVar1.w` (`0x140198780`, 씬 키 `intensity`).
    let intensity: Float
    /// `VAR_SPOT_PARAMS_INNER` = `g_RenderVar1.y`. **코사인**이다 — WE 는 저작 각(도)에
    /// deg2rad 만 곱해 `cosf` 에 넣는다: `0x140198724` load `[light+0x2f0]` → `0x14019872c`
    /// `mulss xmm6`(= `0x140492628` f32=0.0174532924) → `0x140198730` `call 0x14041a2e0`
    /// → `0x140198770` store `+0xbc`. `0x14041a2e0` 이 `cosf` 라는 근거: 소인수 경로가
    /// `1.0 - x²·0.5`(상수 `0x140471bb0`=1.0 / `0x140471bc0`=0.5, `0x14041a340`–`0x14041a348`)이고
    /// 극소 |x| 에서 `1.0`(`0x140471cb8`)을 반환한다.
    ///
    /// **⚠️ 즉 `innercone`/`outercone` 은 광축에서 잰 반각(도)이고, `× 0.5` 는 없다.**
    /// V1 PBR 패커도 같다(`0x140192e64`/`0x140192e6d`/`0x140192e71` → `0x140192e86`,
    /// `0x140192eaa`/`0x140192eb3`/`0x140192eb7` → `0x140192ebf`).
    ///
    /// **[2026-08-21 닫힘]** 종전엔 이 자리에 "호출부가 `* 0.5` 를 곱하는 2D 포트를 써서
    /// 볼류메트릭 콘이 WE 의 절반 폭" 이라는 미결 항목이 있었다. 지금은 콘 변환이
    /// `SceneLight3D.forwardSpotConeCosines` **한 벌**뿐이고 `* 0.5` 가 없다 —
    /// `Scene3DLighting.spotConeCosines` 는 그 함수로 위임하는 이름일 뿐이라, 갓레이와
    /// 3D 포워드가 같은 라이트에 대해 같은 콘을 본다.
    let innerCone: Float
    /// `VAR_SPOT_PARAMS_OUTER` = `g_RenderVar1.z` (`0x140198778`). 위와 동일하게 코사인
    /// (load `0x140198738` → `mulss` `0x140198740` → `cosf` `0x140198744`).
    /// 콘 데이터가 없는 라이트는 호출부가 `(inner:1, outer:-1)` 을 준다
    /// (`forwardSpotConeCosines` 의 `guard outer.isFinite, outer > 0 else { return (1, -1) }`)
    /// — 그게 아래 `isPointLight` 프록시의 신호다.
    let outerCone: Float
    /// `VAR_SPOT_PARAMS_RADIUS` = `g_RenderVar1.x` (`0x140198768`, 씬 키 `radius`).
    /// WE 는 여기에 `radius × 0.99` 를 넣는다(`0x140198760` f32=0.99).
    ///
    /// **[2026-08-21 정정] 호출부는 배선돼 있다** — `SceneRenderer3D.encode3D` 의
    /// `VolumetricLightParameters(...)` 생성이 `radius: light.radius` 를 넘긴다. 종전 주석은 "아직 안 넘긴다" 고 적혀 있었는데
    /// 그건 배선 전의 사실이었다. 이 기본값 0 이 남아 있는 것은 **씬이 `radius` 를
    /// 저작하지 않은 경우**(`parseLight` 의 `radius: float(obj["radius"]) ?? 0`) 때문이고, 그때
    /// `hullRadius` 가 WE 라이트 생성자 기본 1.0(`0x140190494`)을 대신 써서
    /// **헐 반경 0.99** 로 마치한다 — `encode` 가 한 번만 경고한다.
    ///
    /// 이 퇴화가 그냥 "어둡다" 로 끝나지 않는다는 것을 기록해 둔다. 헐이 0.99 면 샘플이
    /// 라이트에서 0.1~0.8 밖에 안 떨어져 앉고, 그 거리에서는 **반 픽셀 각도 차가 콘
    /// 안팎을 가른다**. 같은 픽스처가 `radius` 유무로 0.5062 ↔ 0.2254 로 갈린 실측이
    /// `docs/re/volumetric-light.md` §6.1 에 있다.
    var radius: Float = 0

    /// POINTLIGHT 콤보 여부. **WE 의 판정은 라이트 종 하나다** — `0x1401982fa`
    /// `cmp byte [light+0x2c0], 0` / `jne 0x140198445`(콤보 설정 블록을 건너뜀), 콤보 이름
    /// 문자열 `"POINTLIGHT"` 는 SSO 라 `lea` 가 아니라 `movsd 0x140491a90` + `movzx 0x140491a98`
    /// 로 온다. `[light+0x2c0]` 은 `"lpoint"`=0 이므로 **POINTLIGHT ⟺ `light == "lpoint"`** 다.
    /// 그때 셰이더가 `spotCookie = 1.0`(`:137`) · `maxLightScale ×0.5`(`:119`) 로 간다.
    /// (종전 인용 `0x140198568` 은 명령 경계도 아니다 — `0x140198563 call` 중간이다.)
    ///
    /// Waple 호출부는 종을 넘기지 않으므로 콘 코사인의 퇴화값으로 **근사 판정**한다.
    /// 코퍼스에서는 일치한다(콘을 저작하는 라이트는 `lspot` 5개뿐 — 워크샵 162 씬 실측).
    /// **다만 정확하지는 않다**: `ldirectional`(종 3)은 콘 미저작이라 여기서 point 로 잡히는데
    /// WE 는 `#else` 가지(스팟 스무드스텝, 기본 콘 20°/30°)로 간다. 도달 0건이라 화면 영향은
    /// 없지만 종 문자열을 넘기면 프록시 없이 닫힌다 — 호출부 소관이라 보고서로 넘긴다.
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

    /// - Parameter sceneDepth: 방금 그린 3D 씬의 뎁스 텍스처(`depth32Float`, `destination` 과 동일 해상도).
    ///   W-17 단계 1 — 레이마치의 **출구**를 이 뎁스로 한 번 더 자른다(WE `volumetricsfront.frag:64,71`
    ///   `backDepth = min(backDepth, limitDepth)`). 호출부가 `.shaderRead` 사용 플래그와
    ///   `storeAction = .store` 를 보장해야 한다 — `.dontCare` 로 넘어오면 내용이 미정의라
    ///   샤프트가 임의로 잘린다.
    ///
    ///   **옵셔널이 아니다.** MSL 이 선언한 텍스처 인자를 바인딩하지 않으면 Metal 검증이
    ///   "missing texture binding" 으로 잡고 검증을 끈 빌드에서는 미정의 읽기가 된다. 그래서
    ///   텍스처는 **항상** 바인딩하고, 쓸지 말지는 `marchParams.z` 플래그로만 가른다
    ///   (해상도가 안 맞으면 0 → 셰이더가 `read` 를 아예 실행하지 않는다).
    func encode(
        commandBuffer: MTLCommandBuffer,
        destination: MTLTexture,
        sceneDepth: MTLTexture,
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
        // 저작값은 무클램프 파스(`parseLight` 의 `volumetricsExponent: float(obj["volumetricsexponent"]) ?? 1`)고
        // 코퍼스 실측 범위는 1.0–3.04라
        // (`spec/corpus/scene-schema.json`) 이 클램프는 정상 씬을 바꾸지 않는다.
        let exponent = max(0, light.exponent)
        let sampleCount = Float(Self.marchSampleCount)
        // W-17 단계 1 게이트. `read(uint2)` 는 범위 밖이 미정의라 해상도가 어긋나면 클립을 끈다
        // (`destination` 과 pooled depth 는 같은 크기로 잡히므로 정상 경로는 항상 1이다).
        // 뎁스 포맷도 확인한다 — MSL 이 `depth2d<float>` 로 선언했으므로 다른 포맷이 오면 클립을 끈다.
        let depthUsable = sceneDepth.width == destination.width
            && sceneDepth.height == destination.height
            && sceneDepth.pixelFormat == .depth32Float
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
            marchParams: SIMD4(sampleCount, 1 / sampleCount, depthUsable ? 1 : 0, 0))

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return false
        }
        encoder.setRenderPipelineState(selectedPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VolumetricUniforms>.stride, index: 0)
        encoder.setFragmentTexture(sceneDepth, index: 0)
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

    // MARK: - 복원한 순수 산술 (정본은 WapleCore `SceneWEVolumetricMath` — 리눅스 코어 테스트가 값을 잠근다)

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
        float4 marchParams;    // x=sampleCount y=1/sampleCount z=씬뎁스클립 on/off
    };

    fragment float4 volumetricFragment(
        VolumetricVertexOut in [[stage_in]],
        constant VolumetricUniforms &u [[buffer(0)]],
        depth2d<float> sceneDepth [[texture(0)]]
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
        float tExit = min(-b + sq, u.projParams.w);
        // W-17 단계 1 — WE `:64` `limitDepth` + `:71` `min(backDepth, limitDepth)`.
        // 뎁스 버퍼는 `Scene3DMath.perspective`(Metal NDC z 0..1, 뷰 -near→0 / -far→1)로 쓰였으므로
        // `d = near·far / (far - ndc·(far-near))` 가 카메라 **전방축** 거리다. 마치는 단위 dir 을
        // 따라 도니까 `t = d / dot(dir, forward)` 로 환산해서 자른다.
        // 지오메트리가 없는 픽셀의 클리어값 1.0 은 d=far 로 풀리고 tExit 이 이미 far 이하라 무연산이다.
        if (u.marchParams.z > 0.5) {
            float ndcDepth = sceneDepth.read(uint2(in.position.xy));
            float denom = u.projParams.w - ndcDepth * (u.projParams.w - u.projParams.z);
            float cosAxis = dot(dir, u.cameraFwd.xyz);
            if (denom > 0.0 && cosAxis > 1e-6) {
                float limit = (u.projParams.z * u.projParams.w / denom) / cosAxis;
                tExit = min(tExit, limit);
            }
        }
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

/// WE 볼류메트릭의 **순수 산술** 정본은 이제 `WapleCore` 에 있다 —
/// `SceneWEVolumetricMath`(`Sources/WapleCore/ScenePBRLighting.swift`).
///
/// **[2026-08-21 이관] 왜 옮겼나.** 이 파일은 `import Metal` 이라 리눅스에서 **실행**할 수 없다.
/// `scripts/dev/linux-render-typecheck.sh` 가 `swiftc -typecheck` 는 해 주지만 값을 한 번도
/// 계산하지 않는다 — 즉 이식한 수식의 **숫자**를 잠그는 것은 macOS 전용
/// `Tests/WapleRenderTests/VolumetricLightTests.swift` 하나뿐이었고, 리눅스 대조는
/// "이 enum 블록만 잘라 따로 컴파일한다" 는 **수동 절차**로만 성립했다
/// (그 절차의 실행 기록이 `docs/re/volumetric-light.md` §6 이다). 수동 절차는 회귀를 막지 못한다.
///
/// 산술을 `WapleCore` 로 옮기고 이름만 여기 남긴다. 호출부(`marchSampleCount`·`hullRadius`·
/// `pointLightScale`)와 macOS 테스트는 **한 글자도 안 바뀌고**, 같은 코드가 이제
/// `Tests/WapleCoreTests/SceneVolumetricMathTests.swift` 에서 리눅스 코어 테스트로 **실행**된다.
/// (AGENTS.md / 공통 브리프 §3.2: "순수 계산 로직은 `Sources/WapleCore/` 로 빼서 리눅스
///  테스트로 덮어라. 이게 정석이다.")
///
/// `metalSource` 의 MSL 문자열은 이 이관에서 **한 줄도 건드리지 않았다** — 두 벌 대조표
/// (`docs/re/volumetric-light.md` §6.2)의 GPU 쪽 열이 그대로 유효하다.
typealias VolumetricMath = SceneWEVolumetricMath
