import AppKit
import MetalKit
import simd
import WapleCore

/// F4: isGeometryFlipped 재적용 훅 — AppKit 이 백킹 레이어 지오메트리를 재동기화하는 시점(창 재부모화·
/// 스페이스 전이 등)에 mount 1회 대입이 유실될 수 있어, 이 뷰가 창에 (재)부착될 때마다 멱등 재확인한다
/// (draw(in:) 진입부의 매 프레임 재확인과 이중 방어 — 여기는 정지(paused) 상태에서도 즉시 반응).
final class WapleMTKView: MTKView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let want = SceneLivePresentationFix.needsDesktopFlipY
        if layer?.isGeometryFlipped != want {
            layer?.isGeometryFlipped = want
        }
    }
}

public final class SceneRenderer: NSObject, WallpaperRenderer, MTKViewDelegate {
    /// Metal `PBRMaterialUniforms`: exactly two float4 values (32 bytes).
    struct PBRMaterialUniforms {
        var scalars: SIMD4<Float>       // x=roughness, y=metallic
        var specularTint: SIMD4<Float>  // xyz=specular tint
    }
    /// attachment(이름 본-슬롯 부착) 스펙: 부모 퍼펫 모델 + 부착점 이름 + 부모 월드 정적 변환(베이크값 —
    /// 씬 델타 켤레 D = P∘(Y·A·Y)∘P⁻¹ 용) + 부모 animationlayers(부모 렌더와 포즈 클록 일치).
    struct PuppetAttach {
        let model: PuppetModel
        let name: String
        let parentOrigin: SIMD2<Float>
        let parentScale: SIMD2<Float>
        let parentAngle: Float
        let parentLayers: [AnimationLayer]
    }
    /// F722: 머티리얼 usertextures 의 시스템 미디어 키 요청 종류 — $mediaThumbnail(현재 트랙 아트워크) /
    /// $mediaPreviousThumbnail(직전 트랙 아트워크). buildDisplayTextures 가 레이어 base 를 라이브 텍스처로 교체.
    enum MediaArtworkKind { case none, current, previous }
    /// H1: 2D 레이어 커스텀 머티리얼 셰이더 파이프라인 + 바인드 플랜.
    struct CustomLayerShader {
        let pipeline: MTLRenderPipelineState
        let material: [SIMD4<Float>]                 // materialParams slot values
        let aux: [(slot: Int, tex: MTLTexture)]     // material texture slots > 0
        let texRes: [SIMD4<Float>]                   // 8 slots; slot 0 = layer texture
        let texWrap: [Float]                         // 8 × 1=clamp / 0=repeat
        let texFilter: [Float]                       // 8 × 1=nearest / 0=linear
        var scripts: [(slot: Int, engine: TextScriptEngine)]  // constant scripts
    }
    struct GPULayer { let texture: MTLTexture; let vertexBuffer: MTLBuffer; let tint: SIMD4<Float>; let parallaxDepth: SIMD2<Float>; let effects: [EffectGPU]; let texWidth: Int; let texHeight: Int; let order: Int; let uid: Int /* doc.layers 인덱스 기반 고유 키(scriptVisible 용 — order 는 중복 가능) */; let blendAdditive: Bool /* material passes[0].blending == "additive" */; var isFrameBuffer: Bool = false; var copyBackground: Bool = true /* B2-effects④: WE 컴포지션 레이어의 "배경 복사"(shim 기본 true, L1-project-scene-model.md:230) — false 면 runFrameBufferLayer 가 이펙트 체인 *입력*(chain src)만 acc(기존 누적 화면) 블릿 대신 투명에서 시작(Waple 은 compose 레이어별 자식 RT 가 없어 "자식 RT 대신 무(無)" 로 근사 — 필터형 체인엔 타당, 생성형 체인의 콘텐츠 손실까지 보장하진 않음, BACKLOG.md 참고). `_rt_FullFrameBuffer` aux 슬롯(godrays/shine COPYBG)은 이와 별개로 항상 실제 acc 스냅샷을 받는다(runFrameBufferLayer 의 fullFrame 분리) */; var def: SceneLayer? = nil /* 프로퍼티 애니메이션 있는 레이어만(per-frame 재평가용) */; var puppet: PuppetModel? = nil; var propScripts: [(key: String, engine: TextScriptEngine)] = []; var animLayerScripts: [(layerIndex: Int, key: String, engine: TextScriptEngine)] = [] /* animationlayers blend/visible/rate 바인딩 스크립트 — encodeLayer 가 per-frame 재평가해 캐스케이드에 반영. 훅 등록(buildAnimationEventTargets)도 이 인스턴스 재사용(중복 IIFE 방지) */; var materialScripts: [(key: String, engine: TextScriptEngine)] = [] /* material.constantshadervalue.scripted (roughness/metallic/speculartint) per-frame evaluation */; var initialVisible: Bool = true; var hiddenByAncestor: Bool = false /* SceneLayer.hiddenByAncestor — 영구 비가시 조상 상속. 스크립트 평가 **뒤** 드로우만 스킵(사이드이펙트 보존) */; var colorBlendMode: Int = 0 /* common_blending enum(0=normal) — !=0 이면 acc 스냅샷 블렌드 합성 */; var frames: [TexImage.TexFrame] = [] /* SPRITESHEET 콤보 레이어의 TEXS 프레임 — 비면 정지(무회귀). encodeLayer 가 씬 시간으로 프레임 UV 서브렉트 전진 */; var isLit: Bool = false /* 포워드 라이팅 대상(LIGHTING:1 + 씬 라이트). true 면 encodeLayer 가 litPipeline 사용 */; let pbrMaterial: PBRMaterialUniforms; var litRect: (SIMD4<Float>, SIMD4<Float>) = (.zero, .zero) /* [0]=(ox,oy,hw,hh) [1]=(cosA,sinA,z,0) — uv→월드 재구성용. 애니 레이어는 encodeLayer 가 per-frame 재계산 */; var video: SceneVideoLayer? = nil /* 비디오-텍스처 레이어면 프레임 공급자(그 외 nil) — buildDisplayTextures 가 프레임별 비디오 텍스처를 이 레이어에 공급 */; var attach: PuppetAttach? = nil /* attachment(이름 본-슬롯 부착) — 부모 퍼펫 부착점 프레임을 per-frame 씬 델타로 합성 */; var mediaArtwork: MediaArtworkKind = .none /* F722: 시스템 미디어 아트워크 요청 레이어 — buildDisplayTextures 가 base 교체(미수신 시 정적 placeholder 유지, 무회귀) */; var noInterp: Bool = false /* 감사 V07: 베이스 텍스처 NoInterpolation(TexImage flags bit0) — 무효과 레이어는 encodeLayer 가 nearest 변형 파이프라인으로 드로우 */; let scratchQuad = DynamicVertexBuffer() /* 애니 쿼드 per-frame 정점 재사용(스프라이트 UV 도 공용) */; let scratchSkin = DynamicVertexBuffer() /* 퍼펫 스킨 per-frame 정점 재사용 */; var customShader: CustomLayerShader? = nil /* H1: 커스텀 머티리얼 셰이더 — nil = QuadShaders 경로 */; var refract: LayerRefract = LayerRefract() /* H4: REFRACT 굴절 */ }
    var hasAnimations = false
    /// H4: REFRACT(스크린 굴절) 레이어 데이터 — 파티클 GPUParticleSystem.refract 와 동형.
    struct LayerRefract {
        var enabled: Bool = false
        var normalTexture: MTLTexture? = nil
        var amount: Float = 0.05
        var normalRG88: Bool = false
    }
    struct GPUParticleSystem {
        var sim: ParticleSimulator
        let def: ParticleSystemDef
        let seed: UInt64
        let texture: MTLTexture
        let blendAdditive: Bool
        let origin: SIMD2<Float>
        let scale: SIMD2<Float>
        /// 마우스 시차(parallax) 가중치(F200) — GPULayer.parallaxDepth/SceneParticle.parallaxDepth 와 동형,
        /// 2D 경로 전용(3D 는 cameraOffset 채널이 없어 무영향). 기본 1(균일 시차, 무회귀). pv_main 이
        /// cameraOffset×parallaxDepth 로 소비(encodeParticle/encodeRefractParticle 버퍼 2) — 헤드리스
        /// captureFrames 는 cameraOffset 이 항상 .zero 라 값과 무관하게 무변화(라이브 마우스 이동 전용).
        var parallaxDepth: SIMD2<Float> = SIMD2<Float>(1, 1)
        let texRatio: Float   // texH/texW (스프라이트 세로 비율)
        let order: Int        // scene objects[] 인덱스 — 레이어와 인터리브 z-순서
        let isTrail: Bool     // spritetrail/rope/ropetrail — 히스토리 리본으로 드로우
        /// C4-(iii): REFRACT 게이트 전용 판별(WapleCore RendererKind.isRopeTrail 위임) — rope/ropeTrail
        /// 만 배제, spriteTrail 은 REFRACT 정접 대상으로 포함.
        var isRopeTrail: Bool { def.renderer.isRopeTrail }
        /// 자식 링크(부모 particleSystems 인덱스, 링크 인덱스). 자식은 자체 sim 을 스텝하지 않고
        /// 부모 sim.childDisplay(link) 를 그린다(sim 필드는 미사용 더미 — 드로우 파이프라인 공용 위해 유지).
        var childOf: (parent: Int, link: Int)? = nil
        /// 스프라이트시트 프레임(TEXS). 비면 전체 텍스처 1프레임.
        var frames: [TexImage.TexFrame] = []
        /// mapsequence limitbehavior=mirror(시퀀스 → 시트 폴드 방식).
        var mapSeqMirror: Bool = false
        /// 3D 마운트 배치(camera3D 씬 전용 — 2D 경로 미사용). 부모 노드 id·전-성분 트랜스폼·정적 가시성.
        var parent3D: Int? = nil
        var origin3D: SIMD3<Float> = .zero
        var scale3D: SIMD3<Float> = SIMD3(1, 1, 1)
        var angles3D: SIMD3<Float> = .zero
        var visible3D: Bool = true
        /// REFRACT(스크린 굴절): 노멀맵 + refractAmount. refract && normalTexture != nil 일 때만 굴절 경로
        /// (encodeDrawPlan 이 acc 스냅샷을 떠 pf_refract 로 드로우). 그 외/실패는 identity 파티클 폴백.
        var refract: Bool = false
        var normalTexture: MTLTexture? = nil
        var refractAmount: Float = 0.05
        var normalRG88: Bool = false   // 노멀 텍스처가 WE RG88(2채널) 포맷 → 셰이더 언팩 분기
        /// 감사 V07: 알베도 NoInterpolation(TexImage flags bit0) — encodeParticle 이 nearest 변형 선택.
        var noInterp: Bool = false
        /// M(④): combos.FOG(기본 1) — 3D 파티클 렌더(pf3d_fog)가 씬 포그에 참여할지(encode3DParticles).
        /// 2D 파티클 경로는 씬 포그 개념이 없어 무영향(genericparticle.frag FOG 는 v_ViewDir 기반 3D 전용).
        var foggy: Bool = true
        /// C4-(ii): g_Overbright(genericparticle.frag, material 유니폼) — pf_main/pf_refract/pf3d_fog
        /// 출력 rgb 에 곱(알파 제외). 기본 1(무회귀). 2D/3D 파티클 공용(머티리얼 파스는 경로 무관).
        var overbright: Float = 1
        let scratch = DynamicVertexBuffer()  // per-frame 파티클 정점 재사용
        /// E1(④): 2D 정사영 경로의 초기 가시성(SceneParticle.visible — 정적 스크립트 없음이면 이 값이
        /// 종신, 무회귀). 3D 는 visible3D(별개 채널)를 계속 쓴다.
        var initialVisible: Bool = true
        /// SceneParticle.hiddenByAncestor — 영구 비가시 조상 상속(GPULayer 와 동일 규약).
        var hiddenByAncestor: Bool = false
        /// E1(④): visible 프로퍼티 스크립트 엔진(SceneParticle.visibleScript, F199) — encodeParticle 호출
        /// 전 per-frame 재평가로 draw 게이트. nil = 정적 visible(스크립트 없음, 무회귀).
        var visibleEngine: TextScriptEngine? = nil
    }
    /// 텍스트 레이어(시계/날짜/곡정보): 흰 글리프 텍스처 + tint. 콘텐츠 스크립트(engine)는 매 프레임 재평가
    /// (F724 — 변경 시에만 재래스터). 프로퍼티 스크립트(propScripts, F218/F219)는 재래스터 없이 encodeText 가
    /// per-frame 트랜스폼/알파/가시성만 갱신(GPULayer.propScripts 와 동형 — 별개 채널).
    struct GPUText {
        var texture: MTLTexture?
        var vertexBuffer: MTLBuffer?
        let tint: SIMD4<Float>
        let order: Int
        let engine: TextScriptEngine?
        var lastText: String
        let fontData: Data?
        let systemFontName: String?
        let def: SceneTextLayer
        /// doc.texts 인덱스 기반 고유 키(scriptTextVisible 용 — order 는 중복 가능. GPULayer.uid 와 동일 규약).
        let uid: Int
        /// 초기 가시성(visible 스크립트 있으면 정적 false 도 보존).
        var initialVisible: Bool = true
        /// SceneTextLayer.hiddenByAncestor — 영구 비가시 조상 상속(GPULayer 와 동일 규약).
        var hiddenByAncestor: Bool = false
        /// 프로퍼티 스크립트(origin/scale/alpha/color/angles/visible) — GPULayer.propScripts 와 동형.
        var propScripts: [(key: String, engine: TextScriptEngine)] = []
        /// rasterize() 가 채우는 원본(비-스케일) 글리프 픽셀 크기 — 스크립트 재래스터 없이 per-frame
        /// 지오메트리 재계산(Self.quadVertices 재사용)에 쓰인다.
        var rasterWidth: Float = 0
        var rasterHeight: Float = 0
        /// F741(S-13): 텍스트 effects[](F693 파스)의 GPU 체인 — buildTextDisplayTextures 가 래스터
        /// 텍스처에 applyEffect 체인을 적용(레이어 buildDisplayTextures 와 동일 경로). 비면 무회귀.
        var effects: [EffectGPU] = []
        /// 애니 쿼드 per-frame 정점 재사용(GPULayer.scratchQuad 와 동일 패턴).
        let scratchQuad = DynamicVertexBuffer()
    }
    var textLayers: [GPUText] = []
    var hasScriptedText = false

    /// 씬 공유 JSContext(mount 당 1개) — 모든 프로퍼티 스크립트가 `shared` 로 통신(주야 컨트롤러 등).
    var sceneScript: SceneScriptContext?
    /// F723: JS thisScene.layers 의 이미지 레이어 수(=doc.layers.count) — 텍스트 read-back 인덱스 오프셋
    /// (sceneScriptLayers 가 이미지 레이어 먼저, 텍스트를 뒤에 붙이는 순서와 동일).
    var sceneScriptImageLayerCount = 0
    /// F743(S-35): 마운트 시점 디스크립터 스냅샷(sceneScriptLayers) — 프레임 말 pushLiveSceneLayers 가
    /// 라이브 상태를 덮어써 updateSceneLayers 로 JS thisScene.layers 를 제자리 갱신하는 기준 배열.
    var sceneScriptBaseDescriptors: [SceneScriptLayerDescriptor] = []
    /// F743(S-35): 이번 프레임 encodeLayer/encodeText 가 기록한 레이어별 라이브 상태(JS layers 인덱스 →
    /// visible/alpha/origin/scale/angles). 프레임 말 pushLiveSceneLayers 가 소비하고 비운다.
    var liveLayerStates: [Int: ScriptLayerReadBack] = [:]
    /// visible 스크립트의 최근 평가값(레이어 고유 uid → 표시 여부). update(current) 에 이전 값을 전달.
    /// 키는 GPULayer.uid(doc.layers 인덱스) — order 는 씬에서 중복될 수 있어 키로 부적합(충돌).
    var scriptVisible: [Int: Bool] = [:]
    /// 이번 프레임 이펙트 체인의 **출력이 premultiplied** 인 레이어(GPULayer.uid) — 곧 DIRECTDRAW 패스가
    /// 체인의 마지막 실행 패스인 레이어다. buildDisplayTextures 가 매 프레임 재계산하고(X-⑥ 비가시
    /// continue·F532 break 를 그대로 반영) encodeLayer 가 f_main 대신 f_main_premul 을 고르는 데 쓴다.
    /// 키를 uid 로 두는 것은 scriptVisible 과 같은 근거(order 는 중복 가능).
    var premultipliedDisplayLayers: Set<Int> = []
    /// 텍스트 visible 스크립트의 최근 평가값(GPUText.uid → 표시 여부, F219). scriptVisible 과 별개
    /// 인덱스 공간(레이어/텍스트는 서로 다른 배열이라 uid 가 겹칠 수 있음).
    var scriptTextVisible: [Int: Bool] = [:]
    /// E1(④): 2D 파티클 visible 스크립트의 최근 평가값(particleSystems 인덱스 → 표시 여부).
    /// scriptVisible/scriptTextVisible 과 별개 인덱스 공간(파티클은 별도 배열).
    var scriptParticleVisible: [Int: Bool] = [:]
    /// WE `thisLayer.pause()`(IParticleSystem.pause) 방출 게이트 — visible 스크립트가 매 평가마다
    /// 남기는 재생 상태(particleSystems 인덱스 → 방출 정지 여부). 스텝 직전에 ParticleSimulator.
    /// emissionPaused 로 옮긴다(라이브 draw 는 particleSnapshot 클로저, 캡처는 웜업 루프 앞).
    /// 항목 부재 = 스크립트 미보유 또는 미호출 → 방출 유지(무회귀).
    var scriptParticleEmissionPaused: [Int: Bool] = [:]
    /// C④: 퍼펫 animationlayers 캐스케이드 중 rate 가 스크립트로 매프레임 재평가되는 레이어의 dt 적분
    /// 누적 위상(GPULayer.uid → 캐스케이드 순서 배열, 인덱스는 eff/resolved 와 동일). 레이어 수 변경
    /// (visible 토글로 캐스케이드 구성이 바뀜) 시 길이 불일치로 자동 무효화(재시딩).
    var puppetCascadePhase: [Int: [Float]] = [:]
    /// C④: 위 위상 적분의 dt 계산용 — 레이어가 마지막으로 encodeLayer 를 통과한 씬 시각.
    var puppetCascadeLastTime: [Int: Float] = [:]

    /// 프로퍼티 스크립트 엔진 생성: 씬 공유 컨텍스트 우선(IIFE 격리), 컨텍스트 부재 시 단독 폴백.
    /// 이벤트 훅(cursorClick/media*Changed)을 export 한 엔진은 배달 대상으로 등록.
    /// F743(S-34): currentLayerIndex = thisScene.layers 디스크립터 인덱스(doc.layers+doc.texts 순서) —
    /// thisLayer 를 스크립트 소유 오브젝트 자체로 직결(중복명/묘명 오바인딩 해소). nil = 종전 이름 조회.
    /// detachedLayer: 파티클처럼 thisScene.layers 에 실물이 없는 오브젝트 — 엔진 전용 thisLayer 심을
    /// 준다(TextScriptEngine.__wapleDetachedLayer 주석). 종전엔 그런 스크립트의 thisLayer 가 전역
    /// 기본값(layers[0])이어서 play/pause 상태가 남의 레이어와 뒤섞였다.
    /// G-C4-01: owner = 이 스크립트가 바인딩된 프로퍼티의 **소유 객체**(WE `thisObject`).
    /// 기본 .layer 는 종전과 동일하게 thisObject === thisLayer — 레이어/텍스트 프로퍼티 스크립트는
    /// 그게 WE 계약이므로 전 호출부가 무수정으로 남는다. 이펙트/패스 상수 빌더만 실소유자를 준다.
    func makeScriptEngine(_ src: String, layerName: String? = nil, currentLayerIndex: Int? = nil,
                          scriptPropsJSON: String? = nil, detachedLayer: Bool = false,
                          owner: TextScriptEngine.ScriptOwner = .layer) -> TextScriptEngine? {
        // 오디오 소비 스크립트 게이팅: 참조가 보이면 hasAudio 승격 → mount 말미의 provider 기동
        // (기존엔 셰이더 오디오 효과만 켰다). 모든 스크립트 로드는 mount 의 기동 검사보다 앞선다.
        if !hasAudio, Self.scriptWantsAudio(src) { hasAudio = true }
        let engine = sceneScript.map { TextScriptEngine(script: src, scene: $0, currentLayerName: layerName,
                                                        currentLayerIndex: currentLayerIndex,
                                                        scriptPropsJSON: scriptPropsJSON,
                                                        detachedLayer: detachedLayer, owner: owner) }
            ?? TextScriptEngine(script: src, scriptPropsJSON: scriptPropsJSON, owner: owner)
        guard let engine else { return nil }

        // Constructor evaluation is complete here. Every engine gets apply exactly once; only init-only
        // engines initialize now. Update-bearing engines retain init(currentValue) in evaluate*.
        engine.applyUserProperties(sceneUserPropertiesJSON)
        if !engine.hasUpdate { engine.callInitIfNeeded() }

        if !engine.hookNames.isEmpty {
            eventEngines.append(engine)
            // cursorEnter/Leave 는 엔진이 바인드 레이어를 히트테스트(WE 규약 — 스크립트는 반응만).
            // 레이어명을 기억했다가 mount 말미에 회전 히트 쿼드로 해석(buildHoverTargets).
            if let layerName,
               !engine.hookNames.isDisjoint(with: ["cursorEnter", "cursorLeave"]) {
                hoverEngineLayers.append((engine, layerName))
            }
            // U-W5b: 나머지 커서 훅 4종도 브로드캐스트가 아니다(§ pointerTargets 주석).
            // **이름이 아니라 디스크립터 인덱스로 잡는다** — 코퍼스에 무명 오브젝트가 흔하고
            // (합성 e2e 의 컨트롤 오브젝트도 무명이다) 중복명도 있어서 이름 키는 조용히 빗나간다.
            // `currentLayerIndex` 는 이미 thisLayer 직결(F743/S-34)에 쓰는 정본 키다.
            if !engine.hookNames.isDisjoint(with: Self.pointerDispatchHooks) {
                pointerEngineOwners.append((engine, currentLayerIndex))
            }
        }
        return engine
    }

    /// 스크립트 소스의 오디오 API 참조 스캔(문자열 contains — mount 시 스크립트당 1회).
    static func scriptWantsAudio(_ src: String) -> Bool {
        src.contains("engine.audio") || src.contains("audioBuffer")
            || src.contains("registerAudioBuffers") || src.contains("g_AudioSpectrum")
    }

    /// T-G15 배선(2026-08-21, 클러스터 U): `docs/re/scene-script-api.md` §9.1 이 전수로 세어 둔
    /// "문서에는 파스돼 있는데 디스크립터를 못 건너 JS 심 하드코딩 기본값이 저작값 대신 보이던"
    /// 필드 18개를 여기서 실값으로 채운다(그리고 §9.6 이 "파스에서 소실" 로 넘겼던 `scale.z` ·
    /// `angles.x/.y` · 텍스트 `parallaxDepth` 도 — 그 사이에 파스가 닫혀 §9.6 이 낡았다).
    /// 디스크립터 쪽 자리는 `fdc21e8` 이 이미 만들었고
    /// (기본값 있는 `var` — 그래서 그 커밋은 무회귀였고, 그래서 미완이었다) 남은 것이 이 대입이다.
    /// 화면은 안 바뀌므로 렌더 골든으로는 안 잡히고, `SceneScriptAPISurfaceTests` 도 디스크립터를
    /// **직접** 만들어 검증하므로 못 잡는다 — 잡히는 유일한 지점이 이 함수다.
    static func sceneScriptLayers(from doc: SceneDocument) -> [SceneScriptLayerDescriptor] {
        let imageLayers = doc.layers.map { layer -> SceneScriptLayerDescriptor in
            var d = SceneScriptLayerDescriptor(
                name: layer.name,
                visible: layer.initialVisible,
                alpha: layer.alpha,
                origin: SIMD3<Float>(layer.origin.x, layer.origin.y, layer.originZ),
                // T-G15 정정: `scene-script-api.md` §9.6 은 "`SceneLayer.scale` 이 `Vec2` 라 z 가
                // 소실된다 / `angleZ` 뿐이라 x·y 가 소실된다"고 적었는데 **그 문장은 이제 낡았다** —
                // 파스가 `scaleZ`/`angleX`/`angleY` 를 따로 보존한다(W-V①). 하드코딩 1 / 0,0 을
                // 그대로 두면 JS 가 여전히 틀린 값을 본다(코퍼스 scale.z≠1 이 동봉 71 · 설치본 92).
                // 세 성분 모두 라디안이다(파스가 이미 변환한다 — 선언부 주석).
                scale: SIMD3<Float>(layer.scale.x, layer.scale.y, layer.scaleZ),
                angles: SIMD3<Float>(layer.angleX, layer.angleY, layer.angleZ),
                size: SIMD2<Float>(layer.size.x, layer.size.y),
                // O-W5: `ILayer.solid` 는 오브젝트 플래그워드 `+0x120` **bit13**(등록 `0x1401e1283`,
                // ctor 기본 true — `0x1401ddc72` `mov word [r14+0x120], 0x2001`)이고 커서 히트테스트
                // 참가 게이트다(`0x14018a02d`). 종전 `textureEntryName.isEmpty` 는 근거 없는 추측이라
                // 스크립트가 읽는 `thisLayer.solid` 가 텍스처 유무를 되비추고 있었다.
                solid: layer.isSolid,
                // F743(S-36/S-33): JS getParent()/getAnimationLayerCount() 실값 배선(파스 필드 소비).
                id: layer.id, parentId: layer.parent,
                animationLayerCount: layer.animationLayers.count
            )
            // T-G15(이미지 4): 종전엔 자리가 없어 JS 가 심 기본값 — color 흰색 / parallaxDepth·
            // alignment 는 프로퍼티 자체가 없어 `undefined`(그 값을 쓴 산술이 통째로 NaN) /
            // perspective 항상 false — 을 봤다. 워크샵 코퍼스 도달 1,372 · 1,573 · 556 · 88건.
            d.color = SIMD3<Float>(layer.color.x, layer.color.y, layer.color.z)
            d.parallaxDepth = SIMD2<Float>(layer.parallaxDepth.x, layer.parallaxDepth.y)
            d.alignment = layer.alignment
            d.perspective = layer.perspective
            return d
        }
        let textLayers = doc.texts.map { text -> SceneScriptLayerDescriptor in
            var d = SceneScriptLayerDescriptor(
                name: text.name,
                // F537(F-68): 이미지 레이어(:138)와 동일하게 초기 가시성 존중 — visible 스크립트 바인딩된
                // 정적 비가시 텍스트의 최초 스크립트 판독(getLayer(name).visible)이 부정확하던 것을 수정.
                visible: text.initialVisible,
                alpha: text.alpha,
                // T-G15: `originZ`/`angleZ` 는 텍스트에도 파스돼 있는데 종전엔 리터럴 0 을 넣어
                // JS 가 늘 0 을 봤다(angles 도달 1,315). `angles` 는 라디안 — layersJSONArray 가
                // JS 경계에서 도로 바꾼다(단위 경계 주석 참조).
                origin: SIMD3<Float>(text.origin.x, text.origin.y, text.originZ),
                scale: SIMD3<Float>(text.scale.x, text.scale.y, text.scaleZ),
                angles: SIMD3<Float>(text.angleX, text.angleY, text.angleZ),
                size: SIMD2<Float>(0, 0),
                solid: text.isSolid,   // O-W5: 텍스트도 같은 bit13 — 종전엔 인자 누락으로 항상 false 였다
                text: text.text,
                // T-G15: `id`/`parent` 누락은 **두 곳을 동시에** 막았다 — `thisScene.getLayerByID`
                // 가 텍스트를 영영 못 찾고(공식 스니펫 `getLayerByID('{{ID}}')` 경로), 부모 체인
                // 배선(F711)에서도 텍스트가 통째로 빠져 `getParent()` 가 언제나 루트였다.
                // 워크샵 1,597 **전건**이 id 를 저작한다(parent 는 1,236).
                id: text.id, parentId: text.parent,
                // G15: `ITextLayer.pointsize`/`font`(d.ts:1606·1611)는 디스크립터 실값이어야 한다.
                // 종전엔 두 인자를 아예 안 넘겨 API 기본값(16 / "systemfont_arial")이 들어갔고,
                // 그래서 저작값이 무엇이든 `thisLayer.pointsize` 가 16 이었다. 파스 기본값이
                // WE 생성자대로 32 가 된 지금은 그 16 이 어느 쪽 규약도 아니다.
                // `SceneScriptAPISurfaceTests` 는 디스크립터를 **직접** 만들어 검증하므로
                // 이 배선 누락을 못 잡는다 — 그래서 여기 주석으로 못박아 둔다.
                pointSize: text.pointSize, font: text.font
            )
            // T-G15(텍스트 14): 도달은 §9.1 (b) — color 1,200 · horizontalalign/verticalalign/
            // padding 각 1,597(전건) · anchor 1,429 · opaquebackground/backgroundcolor 각 1,426 ·
            // limitrows/limitwidth 쌍 1,594.
            d.color = SIMD3<Float>(text.color.x, text.color.y, text.color.z)
            // T-G15 정정: §9.1 (b) 는 텍스트 `parallaxDepth` 를 "파스 없음" 으로 적었는데 **낡았다** —
            // W-V② 가 공통 오브젝트 디스크립터(`+0x170`, 태그 1 = vec2, 등록 `0x1401e082f`) 근거로
            // `SceneTextLayer.parallaxDepth` 를 파스한다. 워크샵 텍스트 1,597 중 956 이 저작한다.
            d.parallaxDepth = SIMD2<Float>(text.parallaxDepth.x, text.parallaxDepth.y)
            d.horizontalAlign = text.horizontalAlign
            d.verticalAlign = text.verticalAlign
            d.anchor = text.anchor
            d.padding = SIMD2<Float>(text.padding.x, text.padding.y)
            d.opaqueBackground = text.opaqueBackground
            d.backgroundColor = SIMD3<Float>(text.backgroundColor.x, text.backgroundColor.y,
                                             text.backgroundColor.z)
            // `limitrows`/`maxrows` 는 실물에서 **서로 다른 멤버**다 — 게이트는 플래그워드
            // `+0x594` bit3(등록 `0x140258ff7`, 타입 6), 값은 int `+0x510`(등록 `0x14025966d`,
            // 타입 0 = int 주입기 `0x1401a4930` 의 `mov [r14+rbp], eax`). `limitwidth` 는 같은
            // 워드 bit2(`0x140258f1e`), `maxwidth` 는 float `+0x508`(`0x14025959e`, 타입 4).
            // `SceneTextLayer` 는 둘을 `Int?`/`Float?` 하나로 접어 놓았으므로 여기서 되풀어야 한다.
            // nil 일 때 싣는 1 / 500 은 임의값이 아니라 **WE 텍스트 오브젝트 생성자의 멤버 기본값**
            // 이다 — `0x140256c2e` `mov dword [rdi+0x510], 1` · `0x140256c1a`
            // `mov dword [rdi+0x508], 0x43fa0000`(= 500.0f).
            // [미해결] 실물은 `limitrows: false` 라도 저작된 `maxrows` 를 멤버에 그대로 싣는다
            // (주입기가 게이트와 무관하게 키마다 따로 돈다). Waple 의 파스가 그 값을 접어 버려서
            // 미체크 시의 저작값은 복원할 수 없다 — `SceneDocument` 쪽 패치가 선행돼야 한다.
            d.limitRows = text.maxRows != nil
            d.maxRows = text.maxRows ?? 1
            d.limitWidth = text.maxWidth != nil
            d.maxWidth = text.maxWidth ?? 500
            return d
        }
        return imageLayers + textLayers
    }

    /// F535(F-50): 이 창이 프라이머리(NSScreen.screens.first = 메뉴 바) 화면에 있는지. 헤드리스
    /// (window == nil)는 false — 기존 캡처/테스트의 사운드 스킵(결정성) 계약과 동일. 멀티모니터 동일 씬
    /// 사운드의 N중 재생(시차 에코)을 프라이머리 화면 1개로 디듑하는 데 쓴다.
    /// F833: sceneAudio(재생, mount:1534) 게이트로만 남는다 — audioProvider(스펙트럼 읽기, mount:1569)는
    /// 겹쳐도 에코가 없어(SharedAudioCaptureCore 가 멀티-구독자) window != nil 만 검사한다. 여기서 다시
    /// 합치고 싶어지면 그 전에 F535/F536 주석부터 다시 읽을 것 — 재생과 읽기는 겹침 부작용이 다르다.
    static func isPrimaryScreenWindow(_ window: NSWindow?) -> Bool {
        guard let screen = window?.screen, let primary = NSScreen.screens.first else { return false }
        return screen == primary
    }

    // ── 씬 이벤트(클릭/미디어) ───────────────────────────────────────────────
    /// 이벤트 훅을 export 한 스크립트 엔진들(mount 중 수집). **오브젝트 스코프가 아닌** 훅
    /// (`media*Changed` 5종 · `animationEvent`)만 여기로 브로드캐스트한다 — 그건 실물도 같다.
    ///
    /// 커서 훅 5종(`cursorEnter`/`Move`/`Click`/`Down`/`Up`)은 **브로드캐스트가 아니다**:
    /// 엔진이 먼저 히트테스트를 하고 **히트한 오브젝트에 바인딩된 스크립트에만** 배달한다 —
    /// `cmp [inst+0x48], r15`(히트 오브젝트) `je` / `cmp [inst+8], 0` `jne skip`
    /// (`0x14018a709`–`0x14018a714`, 5개 훅 전건 동형). 무바인딩(`inst[8] == 0`) 인스턴스만 예외다.
    /// **U(2026-08-21)에 배선했다** — Enter/Leave 는 `hoverTargets`, 나머지 4종은 `pointerTargets`.
    var eventEngines: [TextScriptEngine] = []
    /// cursorEnter/Leave 훅을 export 한 (엔진, 바인드 레이어명) — mount 중 수집, buildHoverTargets 가 쿼드 해석.
    var hoverEngineLayers: [(engine: TextScriptEngine, layerName: String)] = []

    // ── U-W5b: 커서 훅 타겟팅 ────────────────────────────────────────────────
    /// `dispatchPointerEvent` 를 지나는 커서 훅. cursorEnter/Leave 는 여기 없다 — 그 둘은
    /// 경계 교차 전용이라 `hoverTargets`(:buildHoverTargets)가 따로 맡는다.
    static let pointerDispatchHooks: Set<String> = ["cursorMove", "cursorClick", "cursorDown", "cursorUp"]
    /// 커서 훅을 export 한 (엔진, 소유 오브젝트 디스크립터 인덱스) — mount 중 수집.
    /// 인덱스 nil = 오브젝트에 안 붙은 스크립트(이펙트 상수/카메라/사운드 볼륨 등) = 실물 `inst[8] == 0`.
    var pointerEngineOwners: [(engine: TextScriptEngine, descriptorIndex: Int?)] = []
    /// mount 말미에 해석한 배달 대상. `scope` 판정은 `WapleCore/PointerHit.DeliveryScope`.
    struct PointerTarget {
        let engine: TextScriptEngine
        let scope: PointerHit.DeliveryScope
        /// `.object` 일 때만 의미 있음 — 히트 판정 직전에 쿼드를 시차만큼 옮긴다(O-W7).
        let parallaxDepth: Vec2
    }
    var pointerTargets: [PointerTarget] = []
    /// cursorClick 은 **뗄 때** + 누를 때 잡았던 대상에서만(W-9). 홀드 맵은 실물 `scene+0x2c0`.
    var clickLatch = PointerClickLatch()
    /// 호버 히트테스트 타깃: 엔진 + 레이어 히트 쿼드(씬 픽셀, 회전 포함) + 그 레이어의 시차 깊이
    /// + 현재 내부 여부(경계 넘을 때만 발송).
    struct HoverTarget {
        let engine: TextScriptEngine
        let quad: PointerHit.Quad
        let parallaxDepth: Vec2
        var inside: Bool
    }
    var hoverTargets: [HoverTarget] = []
    var clickMonitor: Any?
    var mediaPoller: MediaPoller?
    /// F722: 라이브 미디어 아트워크 텍스처(MediaPoller onThumbnail 이 트랙 변경 시 갱신). current=현재 트랙,
    /// previous=직전 트랙(새 아트워크 도착 시 이월). nil=미수신 — 해당 레이어는 정적 placeholder 유지(무회귀).
    var mediaArtworkTexture: MTLTexture? = nil
    var mediaPreviousArtworkTexture: MTLTexture? = nil
    /// 테스트 주입용(mount 전에 설정). nil 이면 AppleScript(Music/Spotify) 프로바이더.
    public var nowPlayingProvider: NowPlayingProvider?
    /// 미디어 배달 횟수(테스트 동기화용).
    public var mediaDeliveryCountForTesting: Int { mediaPoller?.deliveryCount ?? 0 }

    /// 훅 이벤트 배달: eventJS 를 각 엔진 컨텍스트에서 평가해 호출 후 1회 재렌더 요청.
    func dispatchSceneEvent(_ hook: String, eventJS: String) {
        for e in eventEngines where e.hookNames.contains(hook) { e.callHook(hook, eventJS: eventJS) }
        mtkView?.needsDisplay = true
    }

    /// 포인터 이벤트 배달(씬 픽셀 좌표, 하단원점/y-up — pointerSceneCoords()→sceneCoords() 경유,
    /// W1-yaxis 정합. 스테일 정정: 종전 "상단 원점" 문구는 구 y-down pxToNDC 체제 잔재였음).
    /// event 필드는 실물 역추출: worldPosition(Vec3 — .x/.subtract 체이닝), button(0=좌).
    ///
    /// U-W5b: **브로드캐스트가 아니라 타겟팅이다.** `pointerTargets` 중 포인터가 실제로 덮는
    /// 대상에만 배달한다(무바인딩 스크립트와 히트 기하 미확정 대상은 예외 — `DeliveryScope`).
    /// `only` = cursorClick 전용 제한(홀드 맵을 통과한 대상만) — nil 이면 제한 없음.
    func dispatchPointerEvent(hook: String, x: Float, y: Float, only: Set<Int>? = nil) {
        // F743(S-31): input.cursorWorldPosition/cursorScreenPosition/cursorLeftDown 폴ling 실데이터화
        // (screen 좌표는 포인터 UV×프로젝션 픽셀 근사 — ponytail: WE screen 기준 실측 부재).
        // 커서 상태 폴링은 **타겟팅과 무관**하다 — `input.*` 는 오브젝트 스코프가 아니다.
        sceneScript?.setCursorState(worldX: x, worldY: y,
                                    screenX: pointerUV.x * projW, screenY: pointerUV.y * projH,
                                    leftDown: pointerDown)
        let p = SIMD2<Float>(x, y)
        let eventJS = "({ worldPosition: new Vec3(\(x), \(y), 0), button: 0 })"
        for i in pointerTargets.indices where pointerTargets[i].engine.hookNames.contains(hook) {
            if let only, !only.contains(i) { continue }
            guard pointerTargetCovers(i, p) else { continue }
            pointerTargets[i].engine.callHook(hook, eventJS: eventJS)
        }
        mtkView?.needsDisplay = true
    }

    /// 대상 `i` 를 포인터가 덮는가 — 히트 판정 직전에 시차 오프셋을 **쿼드 중심**에 더한다(O-W7,
    /// `0x14019dd79`. 광선이 아니라 쿼드가 움직인다 — 그래서 "그려진 자리 = 클릭되는 자리").
    func pointerTargetCovers(_ i: Int, _ p: SIMD2<Float>) -> Bool {
        let t = pointerTargets[i]
        return PointerHit.delivers(Self.shiftedScope(t.scope, by: hoverParallaxShift(t.parallaxDepth)), to: p)
    }

    static func shiftedScope(_ scope: PointerHit.DeliveryScope,
                             by d: SIMD2<Float>) -> PointerHit.DeliveryScope {
        if case .object(let quad) = scope { return .object(quad.translated(by: d)) }
        return scope
    }

    /// 지금 포인터가 덮는 대상 인덱스 전부(훅 보유 여부 **무관**). 실물 홀드 맵은 스크립트가 아니라
    /// **오브젝트**를 키로 하므로(`0x14018a79b` 이 히트 오브젝트 `r15` 를 넘긴다) 여기서도 훅으로
    /// 거르지 않는다 — `cursorDown` 을 export 하지 않은 스크립트도 `cursorClick` 은 받는다.
    func pointerTargetsCovering(_ p: SIMD2<Float>) -> [Int] {
        pointerTargets.indices.filter { pointerTargetCovers($0, p) }
    }

    /// cursorClick 시뮬레이션(테스트/헤드리스 e2e 용). **좌표가 대상 오브젝트를 덮어야 발화한다** —
    /// 실물이 그렇다(U-W5b). 눌림/뗌 왕복은 건너뛰고 클릭 훅만 직접 주입하는 seam 이라
    /// 홀드 맵(W-9)은 지나지 않는다 — 그 경로는 `deliverGlobalMouse` 가 쓴다.
    public func simulateCursorClick(x: Float, y: Float) {
        dispatchPointerEvent(hook: "cursorClick", x: x, y: y)
    }

    /// 테스트/진단용: `hook` 을 export 한 스크립트의 **소유 오브젝트 중심**(씬 픽셀, 시차 보정 포함).
    /// 배달이 타겟팅으로 바뀐 뒤로 e2e 가 클릭 좌표를 하드코딩하면 씬이 바뀔 때 조용히 빗나간다 —
    /// 좌표를 씬에서 되읽으라고 두는 seam 이다. 소유 오브젝트가 없거나(무바인딩) 기하 미확정이면 nil.
    public func pointerHookTargetCenter(hook: String) -> SIMD2<Float>? {
        for t in pointerTargets where t.engine.hookNames.contains(hook) {
            guard case .object(let quad) = t.scope else { continue }
            return quad.translated(by: hoverParallaxShift(t.parallaxDepth)).center
        }
        return nil
    }

    /// 포인터 버튼 상태 주입점(g_PointerState 로 전달 — 시뮬/헤드리스 e2e 용, pointerUV 위치 주입과 대칭).
    /// 임펄스(`.z`)는 다음 draw 의 프레임 꼬리(`pointerButton.endFrame()`)까지만 산다.
    public func setPointerButtonDown(_ down: Bool) { pointerButton.setDown(down) }

    // ── cursorEnter/cursorLeave (레이어 호버 — 코퍼스 47패키지) ────────────────────
    /// 레이어 히트 쿼드(씬 픽셀 y-up/하단원점, pointerSceneCoords 와 동일 공간).
    ///
    /// O-W6(실측 2026-08-21): 실물은 **축정렬 AABB 가 아니다.** `sub_14019dbb0` 이 오브젝트 4×4 로
    /// 코너 3점(`c0=−X−Y` · `c1=+X−Y` · `c2=−X+Y`, ±0.5 상수 `0x140493000`/`0x140492dd0`)을 만들고
    /// `sub_14019d5a0` 이 **평행사변형** 교차를 푼다(`u`·`v` 각각 `[0,det]` — 삼각형 `u+v` 검사 없음).
    /// 그래서 회전(`angleZ`)과 음수 `scale` 을 전부 존중한다. 판정 본체는 `WapleCore/PointerHit.swift`.
    ///
    /// `alignment` 도 여기서 반영한다(종전 AABB 는 origin=중심으로 가정해 9점 앵커 레이어에서 어긋났다).
    /// `scale` 은 mount 정적 스냅샷(퍼펫 합성 후 값) — 종전과 동일.
    static func layerHitQuad(origin: Vec2, size: Vec2, scale: Vec2, angleZ: Float,
                             alignment: String) -> PointerHit.Quad {
        let hw = size.x * scale.x * 0.5, hh = size.y * scale.y * 0.5
        let ca = cos(angleZ), sa = sin(angleZ)
        let c = Self.alignedCenter(origin: origin, alignment: alignment, hw: hw, hh: hh, ca: ca, sa: sa)
        return PointerHit.Quad.layer(center: SIMD2(c.x, c.y),
                                     size: SIMD2(size.x, size.y),
                                     scale: SIMD2(scale.x, scale.y), angleZ: angleZ)
    }

    /// mount 말미: 수집한 (엔진, 레이어명) → 레이어 히트 쿼드로 호버 타깃 구성(이름 매칭 레이어 없으면 드롭).
    /// `parallaxDepth` 를 같이 들고 있어야 O-W7(시차 보정)을 호버 시점에 적용할 수 있다.
    func buildHoverTargets(doc: SceneDocument) {
        guard !hoverEngineLayers.isEmpty else { return }
        var quads: [String: (quad: PointerHit.Quad, depth: Vec2)] = [:]
        // O-W5: 실물 순회의 **첫 관문**이 `solid`(bit13)다 — `0x14018a00b` `mov r8d,0x2000` →
        // `0x14018a02d` `test word [r15+0x120], r8w`, 아니면 `je` 로 다음 오브젝트. ctor 기본 true.
        for l in doc.layers where !l.name.isEmpty && l.isSolid {
            quads[l.name] = (Self.layerHitQuad(origin: l.origin, size: l.size, scale: l.scale,
                                               angleZ: l.angleZ, alignment: l.alignment),
                             l.parallaxDepth)
        }
        hoverTargets = hoverEngineLayers.compactMap { pair in
            quads[pair.layerName].map {
                HoverTarget(engine: pair.engine, quad: $0.quad, parallaxDepth: $0.depth, inside: false)
            }
        }
    }

    /// mount 말미: 수집한 (엔진, 디스크립터 인덱스) → 배달 범위(`PointerHit.DeliveryScope`).
    ///
    /// U-W5b(2026-08-21). 인덱스 규약은 `sceneScriptLayers(from:)` 의 배열 순서와 같다 —
    /// `[0, doc.layers.count)` 가 이미지 오브젝트, 그 뒤가 텍스트 오브젝트.
    ///
    /// **범위별 근거**:
    /// - `nil` 인덱스 → `.unbound`. 이펙트 상수/카메라/사운드 볼륨 스크립트처럼 오브젝트에 안 붙은
    ///   것들이고, 실물 `inst[8] == 0` 예외와 같은 자리다. 종전과 동일하게 전건 배달된다.
    /// - 이미지 오브젝트 → `solid`(bit13) 가 꺼졌으면 `.unhittable`(히트 순회의 첫 관문
    ///   `0x14018a02d` 가 아예 통과시키지 않는다), 켜졌으면 `.object(회전 쿼드)`.
    ///   쿼드 구성은 호버와 **같은** `layerHitQuad`(정렬 앵커 포함) — 두 경로가 갈리면 안 된다.
    /// - 텍스트 오브젝트 → `.geometryUnknown`. 실물 텍스트의 히트 상자는 **래스터된 픽셀 크기**인데
    ///   `SceneTextLayer` 에는 그 값이 없다(`scene-script-api.md` §9.1 (b) `size` [미해결]).
    ///   추측한 상자로 좁히면 텍스트 바인딩 스크립트가 통째로 죽으므로 종전 배달을 유지한다.
    func buildPointerTargets(doc: SceneDocument) {
        pointerTargets = pointerEngineOwners.map { pair -> PointerTarget in
            let none = Vec2(x: 0, y: 0)
            guard let i = pair.descriptorIndex else {
                return PointerTarget(engine: pair.engine, scope: .unbound, parallaxDepth: none)
            }
            guard i >= 0, i < doc.layers.count else {
                return PointerTarget(engine: pair.engine, scope: .geometryUnknown, parallaxDepth: none)
            }
            let l = doc.layers[i]
            guard l.isSolid else {
                return PointerTarget(engine: pair.engine, scope: .unhittable, parallaxDepth: none)
            }
            let quad = Self.layerHitQuad(origin: l.origin, size: l.size, scale: l.scale,
                                         angleZ: l.angleZ, alignment: l.alignment)
            return PointerTarget(engine: pair.engine, scope: .object(quad), parallaxDepth: l.parallaxDepth)
        }
    }

    /// 포인터가 바인드 레이어 경계를 넘을 때만 cursorEnter/Leave 발송(WE 규약 — 엔진이 히트테스트).
    /// p=nil(창 밖)이면 내부였던 타깃 전부 이탈. 상태 변화 없으면 no-op(프레임마다 폴링해도 저비용).
    ///
    /// O-W7(실측 2026-08-21): 실물은 히트 판정 전에 레이어 시차 오프셋을 **쿼드 중심에 더한다**
    /// (`0x14018a0b3`–`0x14018a115` 가 `(origin−focus)·amount·depth` 를 만들고 `0x14019dd79` 가
    /// 오브젝트 평행이동에 `addss` — 광선이 아니라 쿼드가 움직인다). 그래서 시차로 밀린 레이어도
    /// **눈에 보이는 자리**에서 클릭된다. Waple 의 등가물은 그리기와 같은 식
    /// `cameraOffset × parallaxDepth`(QuadShaders.swift:17)이며, 그 값은 NDC 단위라 씬 픽셀로 환산한다.
    func updateHover(at p: SIMD2<Float>?) {
        guard !hoverTargets.isEmpty else { return }
        var changed = false
        for i in hoverTargets.indices {
            let quad = hoverTargets[i].quad.translated(by: hoverParallaxShift(hoverTargets[i].parallaxDepth))
            let inside = p.map { PointerHit.contains(quad, $0) } ?? false
            guard inside != hoverTargets[i].inside else { continue }
            hoverTargets[i].inside = inside
            let pos = p ?? SIMD2<Float>(0, 0)
            hoverTargets[i].engine.callHook(inside ? "cursorEnter" : "cursorLeave",
                eventJS: "({ worldPosition: new Vec3(\(pos.x), \(pos.y), 0), button: 0 })")
            changed = true
        }
        if changed { mtkView?.needsDisplay = true }
    }

    /// 레이어 시차 오프셋(NDC) → 씬 픽셀. 시차가 꺼져 있으면 0(실물 게이트 `0x140189f17`,
    /// `scene[0xe0]` bit8 && bit3 = 시차 사용 && 2D 에 대응). 헤드리스 캡처는 cameraOffset 이 항상 0.
    func hoverParallaxShift(_ depth: Vec2) -> SIMD2<Float> {
        guard parallaxEnabled else { return .zero }
        return SIMD2(cameraOffset.x * depth.x * projW * 0.5, cameraOffset.y * depth.y * projH * 0.5)
    }

    /// cursorMove + cursorEnter/Leave 시뮬(테스트/헤드리스 — 씬 픽셀 좌표 직접 주입).
    public func simulateCursorMove(x: Float, y: Float) {
        updateHover(at: SIMD2<Float>(x, y))
        dispatchPointerEvent(hook: "cursorMove", x: x, y: y)
    }

    // ── animationEvent (발화원: 타임라인/퍼펫 마커 검출 — 코퍼스 5패키지) ────────────────
    /// 발화원 = tickAnimationEvents(라이브 draw 전용 — 캡처/헤드리스 경로는 미호출, 결정성 유지).
    /// 마커 저장 위치(실측 2026-07-10): ① scene.json 프로퍼티 애니 options.events{frame,name}
    /// (젤다 40지점 — origin/scale/angles + animationlayers blend), ② 퍼펫 .mdl MDLA0006 트레일러
    /// JSON cstring(젤다 talon/link, 3351179520/3396722575). 배달은 **오브젝트(레이어) 스코프** —
    /// 브로드캐스트면 젤다의 "open"(궤짝↔눈꺼풀)·"surprise"(게스트 다수) 이름 충돌이 오발화한다.
    /// 한계(코퍼스 근거): ① 프로퍼티-반환 의미(값 갱신) 미반영 — 발화 가능한 3패키지(젤다·3351179520·
    /// 3396722575)의 전 핸들러가 side-effect 전용(반환문 없음)이고, 반환값을 쓰는 2패키지(3596044309/
    /// 3641860575 mInfo/mTitleUpdate)는 패키지 내 발화원(마커 정의) 자체가 0 이라 사문 — callHook 반환
    /// 미사용 유지. ② startpaused/play()/pause() 런타임 제어 미구현: 값 평가와 동일 클록(마운트부터
    /// 전 타임라인 재생)으로 발화(일관 근사 — getAnimation(name).play() 는 심 상태만). ③ effect
    /// constantshadervalues·재질 JSON 애니 마커(젤다 4지점)는 해당 스크립트/애니 평가 자체가 미구현.
    func dispatchAnimationEvent(name: String) {
        dispatchSceneEvent("animationEvent", eventJS: Self.animationEventJS(name: name))
    }

    static func animationEventJS(name: String) -> String {
        let q = (try? String(data: JSONEncoder().encode(name), encoding: .utf8) ?? "\"\"") ?? "\"\""
        return "new AnimationEvent({ name: \(q) })"
    }

    /// animationEvent 시뮬(테스트/헤드리스 — 브로드캐스트 배달, 실 발화원은 오브젝트 스코프).
    public func simulateAnimationEvent(name: String) { dispatchAnimationEvent(name: name) }

    /// 마커 타임라인 1개: 클록 파라미터 + 마커들. lastF = 단조 누적 프레임(초×fps×rate)의 직전 틱 값 —
    /// 초기 -1 로 frame 0 마커가 최초 틱에 발화(PropertyAnimation.firedMarkers 규약).
    struct AnimEventTimeline {
        let events: [AnimationMarker]
        let fps: Float
        let length: Float
        let mode: String
        let rate: Float
        var lastF: Float = -1
    }
    /// 오브젝트(레이어) 단위 발화 타깃: 마커 타임라인들 + 같은 오브젝트의 animationEvent 훅 엔진들.
    struct AnimEventTarget {
        var timelines: [AnimEventTimeline]
        let engines: [TextScriptEngine]
    }
    var animEventTargets: [AnimEventTarget] = []

    /// mount 말미: 오브젝트별로 ① 이벤트 마커 타임라인(프로퍼티 애니 + animationlayers 바인딩 +
    /// 퍼펫/모델 .mdl 재생 클립 — 렌더 경로의 재생 클립 선택과 동일 규칙)과 ② animationEvent 훅 엔진
    /// (기존 스크립트 엔진 + animationlayers blend/visible 스크립트, 후자는 여기서 생성)을 수집.
    /// 2D(GPULayer)·3D(objects3D/Node3D/MeshRenderable) 양 경로 공용. 어느 한쪽이라도 없으면 타깃 제외.
    /// def(SceneLayer)의 이벤트 타임라인: 프로퍼티 애니(options.events) + animationlayers 바인딩.
    private func defEventTimelines(_ def: SceneLayer) -> [AnimEventTimeline] {
        var timelines: [AnimEventTimeline] = []
        for a in def.animations.values where !a.events.isEmpty {
            timelines.append(AnimEventTimeline(events: a.events, fps: a.fps, length: a.length,
                                               mode: a.mode, rate: 1))
        }
        for al in def.animationLayers {
            for a in al.eventTimelines {   // events 보유분만 파스됨(SceneDocument)
                timelines.append(AnimEventTimeline(events: a.events, fps: a.fps, length: a.length,
                                                   mode: a.mode, rate: 1))
            }
        }
        return timelines
    }

    /// def 의 animationlayers blend/visible 스크립트 → 엔진(여기서 생성 — Resources 는 layer 키만 취급).
    private func animLayerEngines(_ def: SceneLayer, currentLayerIndex: Int? = nil) -> [TextScriptEngine] {
        var engines: [TextScriptEngine] = []
        for al in def.animationLayers {
            for src in al.scripts.values {
                if let e = makeScriptEngine(src, layerName: def.name.isEmpty ? nil : def.name,
                                            currentLayerIndex: currentLayerIndex) {  // F743(S-34)
                    engines.append(e)
                }
            }
        }
        return engines
    }

    func buildAnimationEventTargets(doc: SceneDocument) {
        animEventTargets = []
        for gl in layers {
            guard let def = gl.def else { continue }
            var timelines = defEventTimelines(def)
            // 퍼펫 .mdl 클립 마커: 재생 중 클립만(FrameEncoder 규칙 — 2+ 활성 레이어면 이름 매칭
            // 캐스케이드(각자 rate), 0/1 이면 클립 0 고정). 클립 클록 = PuppetPose.frame 과 동일 파라미터.
            if let pm = gl.puppet, !pm.animations.isEmpty {
                let eff = def.animationLayers.enumerated().filter { $0.element.visible && $0.element.blend > 0 }
                let playing: [(clip: Int, rate: Float)] = eff.count >= 2
                    ? eff.map { (PuppetPose.clipIndex(model: pm, name: $0.element.name, fallback: $0.offset,
                                                      clipId: $0.element.clipId), $0.element.rate) }
                    : [(0, 1)]
                for (ci, rate) in playing {
                    guard ci >= 0, ci < pm.animations.count else { continue }
                    let clip = pm.animations[ci]
                    guard !clip.events.isEmpty else { continue }
                    timelines.append(AnimEventTimeline(events: clip.events, fps: clip.fps,
                                                       length: Float(clip.lengthFrames), mode: clip.mode, rate: rate))
                }
            }
            // 엔진: 레이어 propScripts + animationlayers 스크립트(buildLayers 인스턴스 재사용 —
            // 종전 animLayerEngines(def) 는 훅 등록용 별도 인스턴스를 만들어 IIFE 를 중복 실행했다).
            let engines = gl.propScripts.map(\.engine) + gl.animLayerScripts.map(\.engine)
            let hookEngines = engines.filter { $0.hookNames.contains("animationEvent") }
            guard !timelines.isEmpty, !hookEngines.isEmpty else { continue }
            animEventTargets.append(AnimEventTarget(timelines: timelines, engines: hookEngines))
        }
        // 3D 씬 빌보드(2D 이미지 레이어 — 실물 젤다 눈꺼풀 blink 가 이 경로): 록스텝 def 로 결속.
        for (i, bb) in billboards.enumerated() where i < billboardDefs.count {
            let def = billboardDefs[i]
            let timelines = defEventTimelines(def)
            let engines = bb.scripts.map(\.engine)
                + animLayerEngines(def, currentLayerIndex: doc.layers.firstIndex(of: def))  // F743(S-34)
            let hookEngines = engines.filter { $0.hookNames.contains("animationEvent") }
            guard !timelines.isEmpty, !hookEngines.isEmpty else { continue }
            animEventTargets.append(AnimEventTarget(timelines: timelines, engines: hookEngines))
        }
        // 3D 씬 모델(실물 젤다 게스트/워커): 오브젝트 id 로 노드 스크립트 엔진·활성 클립을 결속.
        guard !doc.objects3D.isEmpty else { return }
        let nodeScripts = Dictionary(nodes3D.map { ($0.id, $0.scripts) }, uniquingKeysWith: { a, _ in a })
        let renderableByID = Dictionary(meshRenderables.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for obj in doc.objects3D {
            var timelines: [AnimEventTimeline] = obj.eventTimelines.map {
                AnimEventTimeline(events: $0.events, fps: $0.fps, length: $0.length, mode: $0.mode, rate: 1)
            }
            for al in obj.animationLayers {
                for a in al.eventTimelines {
                    timelines.append(AnimEventTimeline(events: a.events, fps: a.fps, length: a.length,
                                                       mode: a.mode, rate: 1))
                }
            }
            // 모델 활성 클립 마커(.mdl MDLA0006 트레일러 — 젤다 talon snore, link Look Left/Right).
            if let mr = renderableByID[obj.id], let model = mr.model,
               mr.animIndex >= 0, mr.animIndex < model.animations.count {
                let clip = model.animations[mr.animIndex]
                if !clip.events.isEmpty {
                    timelines.append(AnimEventTimeline(events: clip.events, fps: clip.fps,
                                                       length: Float(clip.lengthFrames), mode: clip.mode,
                                                       rate: mr.animRate))
                }
            }
            var engines = nodeScripts[obj.id]?.map(\.engine) ?? []
            for al in obj.animationLayers {
                for src in al.scripts.values {
                    if let e = makeScriptEngine(src, layerName: obj.name.isEmpty ? nil : obj.name) {
                        engines.append(e)
                    }
                }
            }
            let hookEngines = engines.filter { $0.hookNames.contains("animationEvent") }
            guard !timelines.isEmpty, !hookEngines.isEmpty else { continue }
            animEventTargets.append(AnimEventTarget(timelines: timelines, engines: hookEngines))
        }
    }

    /// 라이브 draw 틱: 각 타임라인의 누적 프레임이 (직전, 현재] 로 전진하며 지나친 마커를
    /// **같은 오브젝트의** 훅 엔진에만 발송. 일시정지 중엔 호출부가 차단(needsDisplay 재드로 방어).
    func tickAnimationEvents(time: Float) {
        guard !animEventTargets.isEmpty else { return }
        var fired = false
        for ti in animEventTargets.indices {
            for li in animEventTargets[ti].timelines.indices {
                let tl = animEventTargets[ti].timelines[li]
                let prev = tl.lastF
                let f = time * tl.fps * tl.rate
                guard f > prev else { continue }
                animEventTargets[ti].timelines[li].lastF = f
                let names = PropertyAnimation.firedMarkers(events: tl.events, length: tl.length,
                                                           mode: tl.mode, prevF: prev, curF: f)
                for name in names {
                    fired = true
                    if ProcessInfo.processInfo.environment["WAPLE_ANIMEVT_LOG"] != nil {
                        NSLog("%@", "[WapleAnimEvt] t=\(time) target=\(ti) fired=\(name) (prev=\(prev) cur=\(f) fps=\(tl.fps) len=\(tl.length) mode=\(tl.mode))")
                    }
                    let js = Self.animationEventJS(name: name)
                    for e in animEventTargets[ti].engines { e.callHook("animationEvent", eventJS: js) }
                }
            }
        }
        if fired { mtkView?.needsDisplay = true }
    }

    /// 전역 leftMouseDown/Up 모니터(데스크탑 창은 ignoresMouseEvents=true — 클릭은 다른 앱으로 가고
    /// 전역 모니터가 관찰한다, ParallaxController 의 mouseMoved 와 동일 규약. 권한 불요).
    /// WE 규약: down 시 cursorDown+cursorClick(기존 e2e 검증 타이밍 유지), up 시 cursorUp.
    func startClickMonitorIfNeeded() {
        guard clickMonitor == nil else { return }
        // F725: g_PointerState(cursorripple/fluidsim) 를 쓰는 셰이더가 있는 씬도 JS 훅 없이 클릭 상태를
        // 받아야 한다. 이벤트 배달 자체는 dispatchPointerEvent 가 hook 보유 엔진으로만 하므로, 전역
        // 모니터를 항상 설치핻도 무해하고 비용이 낮다(ParallaxController 의 mouseMoved 와 동일 규약).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] ev in
            self?.deliverGlobalMouse(isDown: ev.type == .leftMouseDown)
        }
    }

    /// 화면 포인터 위치 → 뷰 좌표 → 씬(프로젝션) 좌표(FitMode 보정 포함). 창 밖/레터박스는 nil.
    /// 헤드리스(창 없음)는 배달 불가 — 테스트는 simulateCursorClick 사용.
    func pointerSceneCoords() -> SIMD2<Float>? {
        guard let view = mtkView, let win = view.window else { return nil }
        let inWindow = win.convertPoint(fromScreen: NSEvent.mouseLocation)
        let inView = view.convert(inWindow, from: nil)
        guard view.bounds.contains(inView) else { return nil }
        return SceneRenderer.sceneCoords(viewPoint: inView, viewSize: view.bounds.size,
                                         projW: projW, projH: projH,
                                         fitMode: SceneRenderSettings.fitMode,
                                         zoom: currentCameraZoom)
    }

    func deliverGlobalMouse(isDown: Bool) {
        pointerButton.setDown(isDown)  // g_PointerState 라이브 배관(위치 무관 물리 버튼 상태) — 헤드리스는 모니터 미설치라 미도달.
        guard let p = pointerSceneCoords() else {
            // 창 밖(레터박스 포함)에서는 히트 오브젝트가 없다 — 뗌은 클릭이 아니고, 누름도
            // 직전 눌림을 무효화한다(스테일 홀드 맵이 다음 뗌을 클릭으로 만들면 안 된다).
            clickLatch.cancel()
            return
        }
        let covering = pointerTargetsCovering(p)
        if isDown {
            clickLatch.press(covering)
            dispatchPointerEvent(hook: "cursorDown", x: p.x, y: p.y)
        } else {
            dispatchPointerEvent(hook: "cursorUp", x: p.x, y: p.y)
            // U-W9: `cursorClick` 은 **뗄 때**, 그것도 **누를 때 잡아 둔 오브젝트에서 떼었을 때만**이다
            // (`0x14018a787` `test dl,dl` → `je 0x14018a7aa` → 홀드 맵 `scene+0x2c0` find,
            //  end 면 스킵. 통과하면 `0x14018a833` `mov r9d, 0xb` = 훅 인덱스 11).
            // 종전 Waple 은 누를 때 cursorDown 과 함께 쐈다 — 눌렀다가 밖으로 끌고 나가서 떼도 클릭이었다.
            let clicked = clickLatch.release(covering)
            if !clicked.isEmpty {
                dispatchPointerEvent(hook: "cursorClick", x: p.x, y: p.y, only: Set(clicked))
            }
        }
    }

    /// 미디어 소비 스크립트(media*Changed export)가 있을 때만 폴링 시작(웹과 같은 5초 규약).
    /// F722: $mediaThumbnail/$mediaPreviousThumbnail 요청 레이어가 있어도 시작(아트워크 텍스처 공급 필요).
    /// X-③: 레이어 자신의 베이스 텍스처가 아니라 **이펙트 패스** usertextures 로만 $mediaThumbnail 을
    /// 요청하는 경우(레이어/텍스트 effects[] 의 mediaArtworkSlots)도 동일하게 폴링을 트리거해야 한다 —
    /// 그렇지 않으면 buildPassBindings 가 슬롯을 기록해도 mediaArtworkTexture 가 영원히 nil.
    func startMediaPollingIfNeeded() {
        let mediaHooks: Set<String> = ["mediaPlaybackChanged", "mediaPropertiesChanged",
                                       "mediaThumbnailChanged", "mediaTimelineChanged", "mediaStatusChanged"]
        func effectsWantArtwork(_ effects: [EffectGPU]) -> Bool {
            effects.contains { eff in
                guard case .translated(let passes, _, _) = eff.bind else { return false }
                return passes.contains { !$0.mediaArtworkSlots.isEmpty }
            }
        }
        let wantsArtwork = layers.contains(where: { $0.mediaArtwork != .none || effectsWantArtwork($0.effects) })
            || textLayers.contains(where: { effectsWantArtwork($0.effects) })
        guard mediaPoller == nil,
              wantsArtwork || eventEngines.contains(where: { !$0.hookNames.isDisjoint(with: mediaHooks) }) else { return }
        func q(_ s: String) -> String {
            (try? String(data: JSONEncoder().encode(s), encoding: .utf8) ?? "\"\"") ?? "\"\""
        }
        let poller = MediaPoller(provider: nowPlayingProvider ?? AppleScriptNowPlayingProvider())
        poller.onPlayback = { [weak self] info in
            self?.dispatchSceneEvent("mediaPlaybackChanged",
                                     eventJS: "new MediaPlaybackEvent({ state: \(info.state.rawValue) })")
            self?.dispatchSceneEvent("mediaStatusChanged",
                                     eventJS: "new MediaStatusEvent({ enabled: \(info.state != .stopped) })")
        }
        poller.onProperties = { [weak self] info in
            // albumArtist 는 별도 조회 불가(AppleScript 스코프) — artist 로 근사. subTitle=artist(WE 웹 규약과 동일).
            self?.dispatchSceneEvent("mediaPropertiesChanged", eventJS: """
                new MediaPropertiesEvent({ title: \(q(info.title)), artist: \(q(info.artist)), \
                subTitle: \(q(info.artist)), albumTitle: \(q(info.album)), albumArtist: \(q(info.artist)), \
                contentType: 'music' })
                """)
        }
        poller.onTimeline = { [weak self] info in
            self?.dispatchSceneEvent("mediaTimelineChanged",
                                     eventJS: "new MediaTimelineEvent({ position: \(info.position), duration: \(info.duration) })")
        }
        poller.onThumbnail = { [weak self] _, artwork in
            // F722: $mediaThumbnail/$mediaPreviousThumbnail 레이어용 라이브 아트워크 텍스처 갱신 —
            // 직전 트랙은 previous 로 이월. 온디맨드(정지) 씬도 새 아트워크가 보이도록 재드로 요청.
            if let self, wantsArtwork, let device = self.device,
               let tex = self.decodeArtworkTexture(artwork, device: device) {
                self.mediaPreviousArtworkTexture = self.mediaArtworkTexture
                self.mediaArtworkTexture = tex
                self.mtkView?.needsDisplay = true
            }
            // 주색 추출 실패(디코드 불가)도 이벤트 생략 — 색 없는 썸네일 이벤트는 실물 소비자에 무의미.
            guard let p = ArtworkColors.palette(imageData: artwork) else { return }
            func v(_ c: SIMD3<Float>) -> String { "new Vec3(\(c.x), \(c.y), \(c.z))" }
            self?.dispatchSceneEvent("mediaThumbnailChanged", eventJS: """
                new MediaThumbnailEvent({ primaryColor: \(v(p.primary)), secondaryColor: \(v(p.secondary)), \
                tertiaryColor: \(v(p.tertiary)), textColor: \(v(p.textColor)), \
                highContrastColor: \(v(p.highContrast)), hasThumbnail: true })
                """)
        }
        poller.start()
        mediaPoller = poller
    }

    /// 씬 오브젝트 순서의 병합 드로우 플랜(레이어/파티클/텍스트 인터리브). mount 에서 1회 구성.
    /// mesh3D: F721 ortho 하이브리드 — 2D(정사영) 씬의 .mdl 오브젝트를 씬 order 에 맞춰 인터리브 드로우.
    struct DrawItem { enum Kind { case layer, particle, text, mesh3D }; let kind: Kind; let idx: Int }
    var drawPlan: [DrawItem] = []
    /// F721(S-12): ortho(2D) 씬 + .mdl 오브젝트 하이브리드 모드 — build3D 로 메시/노드만 적재(빌보드는
    /// 2D 레이어와 중복이라 폐기)하고 encodeDrawPlan 의 .mesh3D 아이템이 ortho 투영 메시 패스로 그린다.
    var ortho3DHybrid = false

    /// 씬 내부 video-텍스처 레이어 존재 여부 — shouldAnimate 게이트(비디오는 연속 렌더 필요).
    /// 실제 프레임 공급자는 각 GPULayer.video 에 있고, pause/resume/teardown 은 layers 를 순회한다.
    var hasVideoLayer = false
    /// 비디오 레이어 라이브 재생이 기동됐는지(첫 draw 에서 1회) — 매 프레임 순회 회피 플래그.
    var videoLayersLive = false
    /// 씬 sound 레이어 재생기(라이브 mount 한정 — 헤드리스에선 미생성). pause/resume/teardown 에 연동.
    var sceneAudio: SceneAudioPlayer?
    var mtkView: MTKView?
    var device: MTLDevice?
    var queue: MTLCommandQueue?
    var pipeline: MTLRenderPipelineState?
    /// 일반 2D material additive용 v_main/f_main 파이프라인. nil이면 기본 over로 폴백.
    var layerAdditivePipeline: MTLRenderPipelineState?
    /// DIRECTDRAW 이펙트 체인 출력 전용(f_main_premul) — 블렌드 상태는 `pipeline` 과 동일한
    /// premultiplied-over(one, 1-srcA)이고 프래그먼트만 premultiply 를 생략한다.
    /// nil(컴파일 실패)이면 encodeLayer 가 f_main 폴백(종전 이중곱 동작 — 무크래시).
    var layerPremultipliedPipeline: MTLRenderPipelineState?
    var blendPipeline: MTLRenderPipelineState?
    /// 컴포지션(_rt_FullFrameBuffer) 레이어 파이프라인(f_compose) — 프레임버퍼를 화면좌표로 샘플.
    /// nil(컴파일 실패)이면 encodeLayer 가 f_main 폴백(종전 stretch 동작 — 무크래시).
    var composePipeline: MTLRenderPipelineState?
    /// 2D 포워드 라이팅 파이프라인(f_lit) — 라이트 씬의 LIGHTING:1 레이어 전용. nil 이면 미사용.
    var litPipeline: MTLRenderPipelineState?
    /// 감사 V07: NoInterpolation(GPULayer.noInterp) 무효과 레이어 전용 nearest 변형(f_main over/additive,
    /// f_blend, f_compose, f_lit — QuadShaders.nearestSource 동명 함수). noInterp 레이어가 있을 때만 빌드,
    /// nil(미빌드/컴파일 실패)이면 encodeLayer 가 대응 선형 파이프라인으로 폴터(무회귀·무크래시).
    var pipelineNearest: MTLRenderPipelineState?
    var layerAdditiveNearestPipeline: MTLRenderPipelineState?
    var blendNearestPipeline: MTLRenderPipelineState?
    var composeNearestPipeline: MTLRenderPipelineState?
    var litNearestPipeline: MTLRenderPipelineState?
    /// 스프라이트 프레임 추출 파이프라인(v_spriteframe/f_spriteframe) — 아틀라스 서브렉트를 프레임크기
    /// dst 로 nearest 1:1 복사(종전 blit.copy 대체 → BC 아틀라스 네이티브 상주 가능). nil 이면
    /// spriteFrameTexture 가 원본 아틀라스 그대로 폴백(무크래시).
    var spriteFramePipeline: MTLRenderPipelineState?
    /// A2 HDR: 씬 general.hdr && 톤맵 파이프라인 빌드 성공 시에만 true(빌드 실패 시 종전 LDR 폴백).
    /// 참이면 acc/합성 스냅샷을 float(rgba16Float)로, acc→타깃 blit 을 톤맵 패스로 대체한다.
    var sceneIsHDR = false
    /// HDR 최종 포스트 패스(float 합성 버퍼 → bgra8 saturate 클램프). sceneIsHDR 일 때만 존재.
    var hdrPost: HDRPostPass?
    /// Authored gate, kept separate from pass availability so construction failure can raw-fallback.
    var sceneWantsLDRBloom = false
    var ldrBloomParameters = LDRBloomParameters.defaults
    var ldrBloomPass: LDRBloomEncoding?
    /// #22 HDR bloom authored 게이트(hdr && bloom — 코퍼스 8씬). 패스 생성 실패 시 hdrPost(클램프) 폴백.
    var sceneWantsHDRBloom = false
    var hdrBloomParameters = HDRBloomParameters.defaults
    var hdrBloomPass: HDRBloomEncoding?
    /// H6: HDR bloom 8-레벨 피라미드(기존 단일 레벨 대비 글로우 반경 확장 — WE 실측 8단).
    var hdrBloomPyramidPass: HDRBloomPyramidEncoding?
    /// P③: 피라미드 전용 원본 저작값 — hdrBloomParameters.strength 는 단일레벨 HDRBloomPass 폴백을
    /// 위해 ×max(1,iterations) 로 보정돼 있어(HDRBloomPass.strengthScale 주석) 피라미드에 그대로
    /// 쓰면 N레벨 가산 누적과 겹쳐 이중 보정된다. 피라미드는 raw strength 와 저작
    /// bloomhdrscatter/bloomhdriterations 를 그대로 받는다(SceneRendererFinalizer 가 소비).
    var hdrBloomPyramidStrength: Float = 0
    var hdrBloomPyramidScatter: Float = HDRBloomPyramidParameters.defaults.scatter
    var hdrBloomPyramidLevels: Int = 8
    /// H5: 볼륨 라이트 샤프트 패스(castVolumetrics 라이트).
    var volumetricLightPass: VolumetricLightPass?
    /// HDR 경로 실효 게이트(2D·3D 공통). 3D 씬도 acc/메시/파티클 파이프라인이 accPixelFormat(float)로
    /// 승격되므로(mesh3DPipeline/particle3DPipeline) HDRBloomPass 에 도달 — 유일 HDR 골든(3470948192=3D) 대조 가능.
    /// P①: accPixelFormat(레이어/메시/파티클 파이프라인 어태치먼트 포맷)과 동일 조건으로 좁힘 —
    /// 종전엔 sceneIsHDR 단독이라 quality low/medium + hdr 씬에서 accPixelFormat 은 bgra8Unorm 인데
    /// pooledOffscreen(bgra:true)(:242)의 float 승격은 hdrActive 만 보고 rgba16Float 를 만들어
    /// 렌더 타깃-파이프라인 포맷이 불일치했다(감사 P① id 3/5/17/36/45, quality 키 보유 씬 0/460 —
    /// 잠복이었으나 구성 가능한 입력). 이제 hdrActive 는 accPixelFormat 이 실제로 float 일 때만 true —
    /// pooledOffscreen/finalizeScene(HDR 블룸·hdrPost 분기)이 전부 이 값 하나로 정합.
    var hdrActive: Bool { sceneIsHDR && accPixelFormat == .rgba16Float }
    /// acc 를 타깃으로 하는 파이프라인(f_main/f_blend/f_lit/particle/text)의 컬러 어태치먼트 포맷.
    /// HDR 이면 float(>1 보존) — mount 에서 sceneIsHDR 확정 후 파이프라인 생성에 사용.
    /// H7: 품질 설정 반영 — low/medium 은 hdr 여도 bgra8Unorm(성능 우선), high/ultra 는 hdr 시 rgba16Float.
    /// P①: 단일 소스 — hdrActive/pooledOffscreen 의 float 승격 판정이 이 계산을 그대로 미러링한다(위 참조).
    var accPixelFormat: MTLPixelFormat {
        switch sceneQuality {
        case .low, .medium: return .bgra8Unorm
        case .high, .ultra: return sceneIsHDR ? .rgba16Float : .bgra8Unorm
        }
    }
    /// H7: 품질 설정 스냅샷. **WE 키가 아니라 Waple 확장이다**(바이너리 전수에서 `quality` 는
    /// `uiquality` 하나뿐이고 씬 general 어휘 39종에 없다) — SceneDocument.Quality 주석 참조.
    var sceneQuality: SceneDocument.Quality = .ultra
    /// 씬당 라이트 유니폼(상수) — forwardLit=false(라이트 씬 아님)면 전 레이어 f_main(무회귀).
    var forwardLit = false
    // 길이 8 = SceneDocument.ForwardUniforms.slotCount = QuadShaders.f_lit 루프 상한(셋이 같은 계약).
    // 종전 4 는 F660 의 3D 8-라이트 상향이 2D 레인에 도달하지 않아 남아 있던 값이다.
    var lightPositions = [SIMD4<Float>](repeating: .zero, count: SceneLight3D.ForwardUniforms.slotCount)    // [8] xyz=world, w=exponent
    var lightColorRadius = [SIMD4<Float>](repeating: .zero, count: SceneLight3D.ForwardUniforms.slotCount)  // [8] rgb=color×intensity, w=radius
    // F800(S-9): kind/axis/cone — f_lit 버퍼 6/7. ForwardUniforms(WapleCore) 팩 그대로.
    var lightAxisCone = [SIMD4<Float>](repeating: .zero, count: SceneLight3D.ForwardUniforms.slotCount)     // [8] xyz=forward(blue축), w=cone outer cos
    var lightKindCone = [SIMD4<Float>](repeating: .zero, count: SceneLight3D.ForwardUniforms.slotCount)     // [8] x=kind(0/1/2), y=cone inner cos
    var lightAmbient = SIMD4<Float>(0, 0, 0, 0)                        // xyz=flat ambient (genericimage4)
    var layers: [GPULayer] = []
    var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    /// `general.clearenabled`(SceneDocument.clearEnabled) — false 면 2D acc 를 매 프레임 지우지 않고
    /// 누적한다(잔상 = 엔진 동작). 기본 true(무회귀 — 코퍼스 161/161 전건 true).
    var clearEnabled = true
    /// clearenabled=false 씬 전용 누적 버퍼 — 풀 텍스처(pooledOffscreen)는 체크아웃 순서 변동(이펙트
    /// 가시성 토글 등)으로 프레임 간 동일성이 깨질 수 있고 신규 할당분은 내용이 미정의라, 전용 유지 +
    /// 첫 프레임 1회 클리어(trailAccPrimed)로 정의된 시작을 보장한다. 마운트/리사이즈 시 재확보.
    var trailAcc: MTLTexture? = nil
    var trailAccPrimed = false
    var cameraOffset = SIMD2<Float>(0, 0)
    /// 마우스가 지정한 목표 시차 오프셋. cameraOffset 는 delay 시상수로 여기로 프레임마다 수렴(WE 스무딩).
    var targetCameraOffset = SIMD2<Float>(0, 0)
    var parallaxEnabled = false
    var parallaxAmount: Float = 1
    var parallaxMouseInfluence: Float = 1
    /// WE cameraparallaxdelay(초). 0 = 즉시. >0 = 프레임 dt 기반 지수 스무딩.
    var parallaxDelay: Float = 0
    let parallax = ParallaxController()
    /// WE 포인터 UV(0..1, 상단 원점). 마우스 미구동/헤드리스 = **`(0,0)`**.
    /// O-W1(실측 2026-08-21): renderState 생성자 `0x14017c6d0` 이 `xor eax,eax` 후
    /// `mov qword [rcx+0x8c], rax`(`0x14017c77d`) 로 두 float 을 0 으로 심는다 —
    /// 실물의 "커서가 아직 씬에 들어오지 않은" 상태는 화면 중앙이 아니라 **좌상단(=화면 밖 취급)** 이다.
    /// 종전 `(0.5,0.5)` 는 미구동 씬에서 `cursorripple` 파문을 화면 한복판에 앉혔다.
    /// (캡처 골든은 `SnapshotPipeline.capturePointerUV` 가 따로 핀하므로 이 값과 무관 — §보고서 넘길 것)
    var pointerUV = SIMD2<Float>(0, 0)
    /// 캡처 하네스용 포인터 핀 — 설정하면 mount 가 **마우스 모니터를 아예 켜지 않고** pointerUV 를
    /// 이 값으로 고정한다(nil = 라이브 커서, 기존 동작).
    ///
    /// 왜 필요한가(2026-08-02 실측, spec/golden/nondeterminism.json → oracle.nondet.rootCause):
    /// mount 가 `parallaxEnabled || hasEffects` 면 마우스 모니터를 켜고 그 콜백이 pointerUV 를
    /// 라이브 커서로 채우는데, 이 값이 이펙트 유니폼 g_PointerPosition 으로 들어간다. 캡처는 시각·
    /// 오디오·난수·fitMode 를 전부 핀하면서 포인터만 안 핀했고, 그래서 **캡처할 때 사람 커서가 어디
    /// 있었는지가 골든 픽셀에 구워졌다** — 전 코퍼스 170종 중 29종이 세션마다 다른 값을 냈고
    /// (커서가 제자리로 돌아오면 이전 값이 그대로 재현됐다) 셀프체크는 같은 프로세스라 못 봤다.
    /// pause() 는 monitor 를 멈추지만 이미 들어온 pointerUV 는 되돌리지 않는다 — 그래서 시작 자체를 막는다.
    /// nonisolated(unsafe): TextScriptEngine 의 캡처 결정성 핀 3종과 같은 계약이다 —
    /// SnapshotPipeline.pinRenderSettings 가 **마운트 전에 한 번 쓰고**(defer 로 복원) 그 뒤 캡처는
    /// 읽기만 한다. 마우스 모니터를 아예 켜지 않는 것이 이 핀의 목적이라, 캡처 중 이 값을 바꾸는
    /// 경로는 설계상 존재하지 않는다(존재하면 결정성 자체가 무너진다).
    nonisolated(unsafe) public static var capturePointerUV: SIMD2<Float>?
    /// 직전 draw 프레임의 포인터 UV(g_PointerPositionLast — cursorripple 이전 위치). draw 종료 시 이월.
    /// 기본값은 pointerUV 와 한 쌍이다 — 실물 ctor `0x14017c784` 도 같은 자리에서 qword 0 을 심는다.
    var pointerUVLast = SIMD2<Float>(0, 0)
    /// 포인터 좌버튼 상태 2비트(renderState `+0xa4`) — `g_PointerState` 합성원.
    /// O-W3: `.z`(클릭 힘)는 **누른 첫 프레임에만 1.0** 인 임펄스지 홀드가 아니다. 자세한 근거 VA 는
    /// `PointerButtonState`(WapleCore/PointerHit.swift) 주석. 미주입/헤드리스 = 무클릭.
    var pointerButton = PointerButtonState()
    /// 물리 버튼 눌림(레벨) — 스크립트 `input.cursorLeftDown` 용. `g_PointerState.z` 와 다르다.
    var pointerDown: Bool { pointerButton.isDown }
    /// 현재 프레임 dt 초(g_Frametime — fluidsim 시간적분). draw 가 갱신, 캡처는 1/30 고정(결정적).
    var frameDT: Float = 0
    /// cursorMove 훅 보유 씬만 이동 이벤트 배달(마운트 시 캐시 — 매 마우스무브 스캔 회피).
    var hasCursorMoveHook = false
    var lastCursorMoveAt: CFAbsoluteTime = 0

    /// 정규화 오프셋(중심 0, 가장자리 ±1, AppKit y-up) → WE 포인터 UV(0..1, y-down). (순수)
    static func pointerUV(fromNormalized off: CGPoint) -> SIMD2<Float> {
        SIMD2(Float(off.x + 1) / 2, 1 - Float(off.y + 1) / 2)
    }

    /// 프레임 dt(초) 계산(순수, F291). 정지 중(isPaused) 재드로는 완전 동결(0) — 종전엔 직전 라이브
    /// 프레임→pause 시점 간의 잔여 간격이 그대로 dt 가 돼, 정지 후 첫 재드로(호버/리사이즈)에서
    /// dt 구동 시뮬(파티클 sim.step 등)이 최대 50ms 전진했다("시간 동결" 재렌더 의도 위반). 아니면
    /// 직전 프레임과의 간격을 0…50ms 로 클램프(탭 전환 등 큰 델타 방지).
    static func frameDelta(nowT: CFAbsoluteTime, lastFrameTime: CFAbsoluteTime, isPaused: Bool) -> Float {
        guard !isPaused else { return 0 }
        return max(0, min(Float(nowT - lastFrameTime), 0.05))
    }

    /// FitMode 별 콘텐츠 NDC 배율(정점에 곱하는 값) — draw 와 클릭 역매핑의 단일 소스. (순수)
    static func aspectScale(projAspect: Float, viewAspect: Float, fitMode: FitMode) -> SIMD2<Float> {
        switch fitMode {
        case .stretch:
            return SIMD2(1, 1)
        case .fill:
            return projAspect > viewAspect
                ? SIMD2(projAspect / viewAspect, 1) : SIMD2(1, viewAspect / projAspect)
        case .fit:
            return projAspect > viewAspect
                ? SIMD2(1, viewAspect / projAspect) : SIMD2(projAspect / viewAspect, 1)
        }
    }

    /// 뷰 좌표(AppKit 하단원점) → 씬 픽셀(W1-yaxis: WE 도 하단원점/y-up — pxToNDC 의 역).
    /// aspectScale 역적용으로 fit 레터박스/fill 크롭 보정 — fit 레터박스 밖 클릭은 nil(대응하는
    /// 씬 좌표가 없음). **주의**: 이 좌표는 pointerSceneCoords()(스크립트 cursorMove/hover 히트
    /// 테스트, layerHitRect — 둘 다 layer.origin 그대로 비교)로만 흐른다. pointerUV(fromNormalized:,
    /// SceneRenderer.swift:723)는 g_PointerPosition(이펙트 셰이더 유니폼) 전용 별개 경로라
    /// 절대 건드리지 않는다(이펙트/합성 패스 UV 불변 제약). (순수)
    static func sceneCoords(viewPoint: CGPoint, viewSize: CGSize, projW: Float, projH: Float,
                            fitMode: FitMode, zoom: Float = 1) -> SIMD2<Float>? {
        guard viewSize.width > 0, viewSize.height > 0, projW > 0, projH > 0, zoom > 0 else { return nil }
        let s = aspectScale(projAspect: projW / projH,
                            viewAspect: Float(viewSize.width / viewSize.height), fitMode: fitMode)
        // zoom = camera 의사-오브젝트 뷰 스케일(draw 의 aspectScale×zoom 과 동일 공식 역적용).
        let nx = Float(viewPoint.x / viewSize.width * 2 - 1) / (s.x * zoom)
        let ny = Float(viewPoint.y / viewSize.height * 2 - 1) / (s.y * zoom)
        guard abs(nx) <= 1, abs(ny) <= 1 else { return nil }
        return SIMD2((nx + 1) / 2 * projW, (ny + 1) / 2 * projH)
    }
    let maxShift: Float = 0.1
    var projAspect: Float = 16.0 / 9.0
    var projW: Float = 1920
    var projH: Float = 1080

    // ── camera 의사-오브젝트(P0-2 파스)의 2D 뷰 줌 ─────────────────────────────
    // WE 시맨틱(클린룸 L19 봉인 + 코퍼스 37씬 실측): 2D 씬 투영은 orthogonalprojection dict 가
    // 지배 — fov 는 160/168 씬에서 50 상수(투영 선택자 아님)라 무효, zoom 만 뷰 스케일로 실효
    // (정적 0.75/2.87 + single 인트로 애니 9씬 — 전수 최종 키프레임 1.0 정착). origin.xy 팬은
    // 애니(실측 5씬 — zoom single 인트로와 연동)만 실효 — 정적 base(전수 중립≈0)·스크립트 바인딩
    // (19씬, 미평가 stale base)은 데드존/게이트로 중립 처리(A/B t=6 정착 중립 → 비트동일).
    // path 는 스크립트 파일 참조("scripts/camera_paths_*.json")라 인라인 웨이포인트 부재 → 미소비(YAGNI).
    // 3D 씬의 camera 오브젝트는 경로 웨이포인트(씬당 다수·큐 재생)라 미소비 — draw 3D 분기가
    // 이 상태를 아예 안 읽는다. 정적 비가시 카메라는 파스가 이미 드롭 → first = 첫 가시 카메라.
    var cameraZoomBase: Float = 1
    /// F744(S-18): general.zoom(F695 파스) — 씬 전역 줌 프레이밍. 1 = 무회귀(비기본 실측 7씬 1.006..1.08).
    var sceneZoom: Float = 1
    var cameraZoomAnim: PropertyAnimation?
    /// 마지막으로 그린 프레임의 zoom — 클릭/호버 역매핑(sceneCoords) 정합용.
    var currentCameraZoom: Float = 1
    /// camera origin.xy 팬(중심원점 씬픽셀, neutral=(0,0)). 정적 base 는 전수 중립/스크립트라 미소비 —
    /// 애니(originAnim, 5씬 zoom 인트로 연동)만 실효. single 끝 클램프로 t=6 중립 정착 → A/B 비트동일.
    var cameraOriginBase = SIMD2<Float>(0, 0)
    var cameraOriginAnim: PropertyAnimation?
    /// origin 이 스크립트 바인딩({"script":…} — 실측 19씬, value.x=slider×canvasSize=화면중심)이면 팬 미발화:
    /// 렌더러는 카메라 origin 스크립트를 평가하지 않아 base(직렬화 stale)가 무의미 → 중립 처리(회귀 방지).
    var cameraOriginIsScript = false

    /// mount: 씬 camera 의사-오브젝트 → 뷰 줌/origin 팬 상태. 카메라 없으면 중립 리셋(마운트 재사용 무회귀).
    func applyCameraObjects(_ cams: [SceneCameraObject]) {
        let cam = cams.first
        cameraZoomBase = cam?.zoom ?? 1
        cameraZoomAnim = cam?.zoomAnimation
        currentCameraZoom = cameraZoomBase
        cameraOriginBase = SIMD2<Float>(cam?.origin.x ?? 0, cam?.origin.y ?? 0)
        cameraOriginAnim = cam?.originAnimation
        cameraOriginIsScript = cam?.scripts["origin"] != nil
    }

    /// time(초) 시점의 카메라 줌(정적 값 + 키프레임 평가 — single 은 끝 클램프). 카메라 부재 = 1.
    func cameraZoom(at time: Float) -> Float {
        cameraZoomAnim?.value(component: 0, atTime: time, base: cameraZoomBase) ?? cameraZoomBase
    }

    /// time(초) 시점의 카메라 origin.xy(중심원점 씬픽셀). 스크립트 바인딩은 중립(미평가 → stale base 무시).
    /// 애니 없으면 정적 base(전수 중립 ≈0) — 팬 오프셋 단계의 데드존이 흡수. single 은 끝 클램프(t=6 정착).
    func cameraOrigin(at time: Float) -> SIMD2<Float> {
        guard !cameraOriginIsScript else { return .zero }
        guard let a = cameraOriginAnim else { return cameraOriginBase }
        return SIMD2<Float>(a.value(component: 0, atTime: time, base: cameraOriginBase.x),
                            a.value(component: 1, atTime: time, base: cameraOriginBase.y))
    }

    /// origin.xy(중심원점 씬픽셀) → 전역 투영-NDC 병진(shakeOffset 과 동일 공간: 씬 = −1..1, aspectScale×zoom
    /// 후단곱). 카메라 +x 이동 = 콘텐츠 −x. 2px 데드존(정착 잔차 3552064521≈(1,1)px·서브픽셀 저작오차 흡수
    /// → A/B t=6·정적·스크립트·카메라부재 씬 전수 .zero = 비트동일 가드).
    /// ponytail: y 부호는 캘리브 노브 — WE 팬 방향 실측 부재(클린룸; 게이트 t=6 중립이라 검증 불가). 인트로
    ///   t<3 병진 방향만 좌우하고, .zero 우회 씬엔 무영향. 교체 조건: WE 팬 부호 실측 확정 시 이 함수만 수정.
    /// W1-yaxis(pxToNDC 전역 y-up 반전) 재검토: 이 +2·y/projH 부호는 구 y-down pxToNDC 체제에서
    ///   유도됐으므로 산술적으로는 −2·y/projH 로 동반 반전해야 내부 일관 — 그러나 위 캘리브 노브 사유가
    ///   먼저 존재해 원래도 WE 실측 없이는 부호를 확정할 수 없었던 값이다. 실측 없이 방향만 뒤집는
    ///   추측 반전은 의도적으로 보류(2px 데드존 + 게이트 씬 전수 .zero 라 현재 실피해 없음 — 확인됨).
    ///   교체 조건은 위와 동일(WE 팬 부호 실측 확정 시 이 함수만 수정), y-up 전환은 별도 트리거 아님.
    static func cameraOriginPanOffset(originXY: SIMD2<Float>, projW: Float, projH: Float) -> SIMD2<Float> {
        if abs(originXY.x) < 2 && abs(originXY.y) < 2 { return .zero }
        return SIMD2<Float>(-2 * originXY.x / max(1, projW), 2 * originXY.y / max(1, projH))
    }

    // ── camerashake 전역 지터(D 재감사 #16, 코퍼스 활성 13씬 — 2D 11/3D 2) ────────────────────
    // 미보유 씬은 cameraShakeEnabled=false → frameShakeOffset 이 .zero 유지 → 셰이더 +0 = 비트동일(가드).
    // parallax(camOffset×parallaxDepth) 채널은 depth=0 레이어(활성 씬 다수)에서 소실되므로 미사용 —
    // 셰이더가 depth 무관 별도 항(shakeOffset)으로 전역 가산(v_main/pv_main 참조).
    var cameraShakeEnabled = false
    var cameraShakeAmplitude: Float = 0.5
    var cameraShakeRoughness: Float = 1
    var cameraShakeSpeed: Float = 3
    /// 이번 프레임 지터 오프셋(v.xy 공간, 깊이 무관 전역). draw/captureFrames 가 t 로 평가해
    /// encodeLayer/encodeText/encodeParticle 이 셰이더 버퍼로 바인드. 비활성 = .zero.
    var frameShakeOffset = SIMD2<Float>(0, 0)

    /// 진폭 1.0 → NDC(v.xy) 피크 ≈ shakeNDCScale. 코퍼스 진폭 0.04..1.0(기본 0.5)은 무차원 상대값
    /// (픽셀 아님 — 0.04px 는 비가시, 0.5 기본은 정규화 노브 특성). 잔잔한 앰비언스라 작게.
    /// ponytail: 캘리브 노브 — A/B 에서 과/소 흔들리면 여기만 조정(수식·바인딩 불변).
    static let shakeNDCScale: Float = 0.03

    /// camerashake 전역 지터 오프셋(v.xy 공간). t 결정적 — 같은 t → 같은 값(Date/random 미사용).
    /// ponytail: WE 확정 수식 부재(클린룸 — 바이너리 미열람; 문서 결론은 "전역 지터"만 §16). 코퍼스 13씬
    ///   값분포 기반 근사. 교체 조건: WE camerashake 수식이 실측 확정되면 이 함수만 축자 대체(호출부·바인딩
    ///   불변). 천장: 2주파 사인 합(진짜 Perlin/value-noise 아님) — 미세 규칙주기 잔존을 허용.
    static func cameraShakeOffset(time t: Float, amplitude: Float, roughness: Float, speed: Float) -> SIMD2<Float> {
        let w = speed
        // 저주파 기저 드리프트: x/y 비공약 주파수·위상으로 탈동기(뻔한 대각 왕복 회피).
        let baseX = sin(t * w * 1.00)
        let baseY = sin(t * w * 1.37 + 1.7)
        // roughness = 고주파 오버톤 혼합비(거칠기). 0=매끈 드리프트, ~1=지글거림.
        let rough = max(0, roughness)
        let roughX = sin(t * w * 5.30 + 0.6)
        let roughY = sin(t * w * 6.10 + 2.9)
        let norm = 1 / (1 + rough)   // 오버톤 추가해도 피크 ≈ amplitude 유지(발산 억제)
        let x = (baseX + rough * roughX) * norm
        let y = (baseY + rough * roughY) * norm
        // 성분별 곱으로 명시 — 구형 컴파일러(Swift 5.10, CI macos-14)가 SIMD×스칼라 연산자를 오해상.
        // (x,y)*s ≡ (x*s, y*s) 라 비트동일.
        let s = amplitude * SceneRenderer.shakeNDCScale
        return SIMD2<Float>(x * s, y * s)
    }

    /// 이번 프레임 지터 오프셋(비활성 = .zero → 비트동일 가드). cameraZoom(at:) 과 동형 디스패치.
    func shakeOffset(at t: Float) -> SIMD2<Float> {
        cameraShakeEnabled
            ? SceneRenderer.cameraShakeOffset(time: t, amplitude: cameraShakeAmplitude,
                                              roughness: cameraShakeRoughness, speed: cameraShakeSpeed)
            : .zero
    }
    var startTime = CFAbsoluteTimeGetCurrent()
    var lastFrameTime = CFAbsoluteTimeGetCurrent()
    var shouldAnimate = false
    var scenePausedAt: CFAbsoluteTime?
    /// 가림 draw-게이트가 애니메이션을 스킵하기 시작한 시각(F289/F290) — scenePausedAt 과 별개 트랙:
    /// 명시 pause()/resume() 없이도(기본 설정 경로) 창이 가려지는 것만으로 클록 동결·오디오 캡처
    /// 중지가 필요해서다. pause() 가 이미 진행 중인 가림 구간을 이어받으면 nil 로 정리한다.
    var drawGateOccludedSince: CFAbsoluteTime?
    var hasEffects = false
    var hasAudio = false
    var currentSpectrum = AudioSpectrum16.silent
    /// X-⑩: WE 소비단 스테이지(그룹 정규화 + 스무딩 + MAX 축약). 프레임 간 상태를 든다.
    var audioProcessor = AudioSpectrumProcessor()
    /// 오디오 콜백 간격 측정용(소비단 dt). 첫 프레임은 1/30 로 가정한다.
    var lastAudioFrameUptime: TimeInterval?
    // 고해상 스펙트럼(오디오 바 시각화). provider 프레임(64L+64R)에서 유지, 32빈은 쌍평균 파생.
    var left64 = [Float](repeating: 0, count: 64)
    var right64 = [Float](repeating: 0, count: 64)
    var left32 = [Float](repeating: 0, count: 32)
    var right32 = [Float](repeating: 0, count: 32)
    var audioProvider: SystemAudioSpectrumProvider?
    var effectVertexBuffer: MTLBuffer?
    var effectQuadInterleaved: MTLBuffer?   // 변환 효과용 인터리브드 풀스크린 쿼드(pos.xyz + uv.xy)
    // F1(flip①): 커스텀 2D 레이어 전용 인터리브드 쿼드 — effectQuadInterleaved 와 포지션은 동일하지만
    // uv 규약이 반대(local(-1,-1)→uv(0,0)=TL)다. 커스텀 레이어는 layerTransformMatrix(y-flip ortho)를
    // 타므로 ev_main 용 effectQuadInterleaved(local(-1,-1)→uv(0,1))를 재사용하면 상하 반전된다 — 절대
    // effectQuadInterleaved/이펙트 경로는 건드리지 않고 이 전용 버퍼만 커스텀 레이어 드로에 바인딩한다.
    var customLayerQuadInterleaved: MTLBuffer?
    var particleSystems: [GPUParticleSystem] = []
    var hasParticles = false
    /// WE 공유 에셋 폴백 루트 — **우선순위 순**(사용자 지정/자동 탐지 → 앱 동봉본).
    /// 패키지에 없는 `.tex`·셰이더 `#include`·이펙트 GLSL·머티리얼 JSON·폰트가 여기로 떨어진다.
    ///
    /// 종전엔 `baseAssetsDirectory` 단일 URL 이라 **동봉본이 이 경로에 닿지 않았다**. 동봉본은
    /// `searchRoots` 에만 있었고 그건 `SceneDocument.parse(sharedAssetProbe:)` 한 곳에서만 쓰인다
    /// — 즉 문서 파싱은 동봉본을 봤지만 셰이더 해석은 못 봤다. WE 미설치 머신에서 pkg 가 담지 않는
    /// `common_*.h`(코퍼스 전수 0건 동봉)가 조용히 드롭돼 심볼 부재로 컴파일이 깨졌다.
    ///
    /// F4: 이 값이 바뀌면 `assetProbeCache` 를 **반드시 함께** 버려야 한다 — 캐시 키가 (루트, 이름)
    /// 이라 루트 목록이 바뀌면 판정이 통째로 달라진다. 무효화를 `mount` 의 대입 한 곳에만 두면
    /// 테스트나 향후 호출부가 직접 대입할 때 조용히 스테일이 되므로, 호출부가 아니라 **상태에** 붙인다.
    var assetBaseRoots: [URL] = [] {
        didSet { assetProbeCache.removeAll(keepingCapacity: false) }
    }

    /// F4: `baseAssetURLProbe` 의 (루트, 이름) → 판정 메모. 수명은 **씬 빌드 1회**다
    /// (`mount` 가 `assetBaseRoots` 를 심는 순간 위 `didSet` 이 비운다 — 씬 간 누수 없음).
    ///
    /// 왜 필요한가: 프로브가 `fileExists` 1회로 끝나는 것은 **히트**일 때뿐이고, 빗나가면 경로
    /// 성분마다 `contentsOfDirectory` + `resolvingSymlinksInPath` 로 대소문자 무시 탐색을 한다.
    /// 즉 **미스가 히트보다 비싸다.** 그리고 조회의 절대다수가 미스다 — 4단 순서(pkg scoped →
    /// pkg plain → base scoped → base plain)의 앞 세 단은 설계상 대부분 빗나가고, `#include` 는
    /// pkg 가 헤더를 0건 동봉하므로(spec/corpus/workshop-shaders.json `pkgBundlesNoHeaders`)
    /// 전건 베이스 루트로 떨어지며, 같은 이름이 이펙트 인스턴스마다·번역 패스마다 다시 조회된다.
    /// 그래서 **미스도 캐시한다** — 그게 비싼 쪽이다.
    ///
    /// 격리 요건은 `assetBaseRoots` 와 **동일하다**(새 요건을 만들지 않는다): 둘 다 평범한 인스턴스
    /// 저장 프로퍼티이고, 읽고 쓰는 코드는 전부 `mount` 한 번의 동기 호출 체인(buildLayers/
    /// buildParticles/buildTexts/build3D) 안에 있다 — per-frame 경로에는 자산 조회가 없다.
    var assetProbeCache: [String: BaseAssetURLProbe] = [:]

    /// 악의 pkg 가 수만 개의 서로 다른 이름을 부르는 경우의 상한. 넘으면 **삽입만** 멈춘다 —
    /// 판정 경로는 그대로라 결과는 캐시 유무와 무관하게 같다.
    static let assetProbeCacheLimit = 8192

    /// mount 가 심는 값과 같은 소스 — 배선이 어긋나지 않게 한 곳에서만 만든다.
    public static func resolvedAssetBaseRoots() -> [URL] { BaseAssetsSettings.searchRoots }

    /// S5-2: `unique:true` FBO 가 붙들고 있는 지속 텍스처의 **렌더러 전역** 합계(바이트).
    ///
    /// 장부와 보유분은 항상 같은 줄에서 함께 움직인다 — 갱신 지점은
    /// `SceneRendererFrameEncoder.applyEffect` 의 fbo 획득 루프 세 곳(개수 불일치 리셋 · 규격
    /// 불일치 파기 · 신규 할당)과 `teardown`(모든 EffectGPU 보유자 = layers/textLayers/
    /// meshRenderables/billboards 를 비운 직후 0) 뿐이다. 세다 놓치는 방향은 **과대계상**이라
    /// 조기 폴백(안전)이 되고, 과소계상이 되는 경로는 없다.
    var uniqueFBOBytesInUse = 0

    public private(set) var hasMissingRequiredSharedAssets = false

    func markMissingRequiredSharedAsset() {
        hasMissingRequiredSharedAssets = true
    }

    static func sharedAssetProbe(_ name: String, root: URL?) -> SharedAssetProbeResult {
        guard let path = WallpaperPathSecurity.normalizedRelativePath(name) else {
            return .rejected
        }
        guard let root else { return .missing }
        let rootURL = root.standardizedFileURL
        let candidate = rootURL.appendingPathComponent(path).standardizedFileURL
        guard WallpaperPathSecurity.contains(candidate, in: rootURL),
              let contained = WallpaperPathSecurity.containedFileURL(path, root: root) else {
            return .rejected
        }
        guard FileManager.default.fileExists(atPath: candidate.path),
              let data = try? Data(contentsOf: contained) else {
            return .missing
        }
        return .data(data)
    }

    /// 여러 루트를 우선순위대로 훑는다. 첫 `.data` 를 반환.
    ///
    /// `.rejected`(경로 이탈)는 **즉시 반환한다** — 이건 보안 판정이지 "이 루트에 없음"이
    /// 아니다. 다음 루트로 흘려보내면 이탈 경로가 다른 루트에서 성공할 수 있다.
    static func sharedAssetProbe(_ name: String, roots: [URL]) -> SharedAssetProbeResult {
        for root in roots {
            switch sharedAssetProbe(name, root: root) {
            case .data(let d): return .data(d)
            case .rejected: return .rejected
            case .missing: continue
            }
        }
        return .missing
    }

    /// 조건 변형 텍스처(TEXB0004, 예 tuniccolor) 선택용 유효 프로퍼티 값(기본값+유저/프리셋 오버라이드).
    /// mount 시 스냅샷 — 프로퍼티 변경은 reapply(=remount)로 반영(LibraryViewModel.setProperty→onApply).
    var variantProperties: [String: PropertyValue] = [:]
    /// SceneScript applyUserProperties payload. Computed once per mount and reused by every engine.
    var sceneUserPropertiesJSON = "{}"
    var additivePipeline: MTLRenderPipelineState?
    var translucentPipeline: MTLRenderPipelineState?
    var refractParticlePipeline: MTLRenderPipelineState?   // REFRACT 스프라이트(pf_refract, translucent)
    /// C4-(iii): REFRACT 스프라이트 additive 블렌드 변형(pf_refract, additive — 코퍼스 additive+REFRACT
    /// 10씬 실측). translucent 변형(위)과 별개 파이프라인(블렌드 상태만 다름, 동일 프래그먼트 함수).
    var refractParticlePipelineAdditive: MTLRenderPipelineState?
    var refractLayerPipeline: MTLRenderPipelineState?     // H4: REFRACT 이미지 레이어(f_refract)
    /// 감사 V07: 알베도 NoInterpolation(GPUParticleSystem.noInterp) 전용 nearest 변형 — noInterp 시스템이
    /// 있을 때만 빌드, nil(미빌드/컴파일 실패)이면 encodeParticle 이 선형 폴터(무회귀·무크래시).
    var additiveNearestPipeline: MTLRenderPipelineState?
    var translucentNearestPipeline: MTLRenderPipelineState?
    var fullscreenQuad: [SIMD2<Float>] = [SIMD2(-1,-1), SIMD2(1,-1), SIMD2(-1,1), SIMD2(1,1)]

    // ── 3D 씬(camera3D + .mdl 메시) 상태 ─────────────────────────────────────────

    var camera3D: SceneCamera3D?
    /// F745: scene fog(F662) — fix-s7 은 extension 저장 프로퍼티 불가(SceneRenderer.swift 타 그룹 소유)라
    /// ObjectIdentifier 키 정적 저장소(Scene3DFogStore)로 우회했었다. 통합으로 정식 프로퍼티에 복귀.
    var scene3DFog = Scene3DFog()
    var is3D = false
    var has3DScripts = false
    var scene3DLights: [SceneLight3D] = []
    /// 씬 `general.lightconfig`(`SceneDocument.lightConfig`). **nil = 미저작** — 그때는 종전
    /// first-`Scene3DLighting.maximumLights` 폴백 그대로라 비트동일이다(동봉 172 씬 중 저작은
    /// `modeleditor`/`particleelementpreviews/collisionmodel` **2건**뿐이고, 그 둘은 저작 카운트가
    /// 실제 라이트 수와 같아 예산을 켜도 결과가 안 바뀐다 — `docs/re/scene-lighting.md` §6.3).
    /// 소비는 `Scene3DLighting.resolveLights(_:nodes:config:)` → `SceneLightSlotBudget`(WapleCore).
    var scene3DLightConfig: SceneLightConfig? = nil
    var scene3DAmbient = SIMD3<Float>(repeating: 0)
    var scene3DSkylight = SIMD3<Float>(repeating: 0)
    var nodes3D: [Node3D] = []                 // scene order(계층 합성 입력)
    var meshRenderables: [MeshRenderable] = []
    var billboards: [Billboard3D] = []
    /// billboards[i] 의 원본 SceneLayer(록스텝 — build3D 가 같은 지점에서 append). 이벤트 마커 타임라인
    /// (def.animations 의 options.events — 젤다 눈꺼풀 blink 등) 결속용. W-①: 이미지 빌보드(선행) 뒤에
    /// build3D 가 텍스트 빌보드도 billboards 에 append 하지만(3D 씬 text 배선) billboardDefs 엔 대응
    /// 항목이 없다(SceneLayer 가 없음, internal init) — billboards.count > billboardDefs.count 가 그 구간만
    /// 유효한 의도된 불변식 이완이며, 소비부(:443 근방)는 `i < billboardDefs.count` 가드로 안전.
    var billboardDefs: [SceneLayer] = []
    /// 3D 씬 text 오브젝트의 스크립트 컨트롤러(shared 사이드이펙트 재평가 + 텍스트 갱신용 last 보관).
    /// 실물 3470948192: text id=181 이 shared.vvv 를 세팅하고 Hollow Cylinder 스케일 스크립트가 소비
    /// (미실행 시 vvv 미정의 → 스케일 NaN → 워프 튜너 소실). 2D buildTexts 와 동일하게 엔진 로드(top-level
    /// + shared 통신). W-①: 픽셀 렌더도 이제 배선됨(billboards 에 append, world placement 정본 확정) —
    /// 여기 last 는 build3D 의 F309 프라이밍이 확정한 콘텐츠 문자열(텍스트 빌보드 최초 래스터 입력)이자,
    /// 이후 evaluate(current:) 재평가 입력(시계 등 값 구동 스크립트의 이전 표시값 — 동적 재래스터는 후속 과제).
    var text3DControllers: [(engine: TextScriptEngine, last: String)] = []
    /// per-frame 스크립트 평가 순서(씬 order — 컨트롤러(Main)가 이를 읽는 스크립트보다 먼저 실행).
    /// (order, isBillboard, idx). 스크립트 없는 노드/빌보드는 제외.
    var eval3DOrder: [(order: Int, bb: Bool, idx: Int)] = []
    /// 그리기 순서(메시+빌보드 인터리브, order 오름차순). (order, isBillboard, idx).
    var draw3DOrder: [(order: Int, bb: Bool, idx: Int)] = []
    /// 감사 V06: 스킨 버퍼 프레임 메모 — prepare3DSkinBuffers 주석상 '프레임당 정확히 한 번' 적재가 전제인데,
    /// ortho 하이브리드는 drawPlan 의 mesh3D 런이 2D 레이어와 인터리브되어 runOrtho3DMeshes 가 프레임당 2+회
    /// 호출(호출마다 boneRing 3슬롯 전진)된다. 링이 프레임 내에서 감기면 GPU in-flight 슬롯을 CPU 가 덮어쓴다.
    /// skin 행렬은 (model, anim, time, rate) 의 순수 함수라 같은 time 의 재호출은 직전 결과를 그대로 쓴다
    /// (정지 재드로의 동일 time 도 동일 행렬 — 무회귀). teardown 이 해제.
    var skinBuffersFrameMemo: (time: Float, buffers: [Int: MTLBuffer])? = nil
    /// H1 스키닝: 커스텀 셰이더 CPU 프리스킨 버퍼 프레임 메모(prepare3DCustomSkinBuffers — V06 과 동일 근거).
    var customSkinFrameMemo: (time: Float, buffers: [Int: [Int: MTLBuffer]])? = nil
    var meshPipelineOver: MTLRenderPipelineState?      // premultiplied over(normal/translucent)
    var meshPipelineAdditive: MTLRenderPipelineState?
    var meshPipelineSkin: MTLRenderPipelineState?      // GPU 스키닝(mv_skin) over
    var meshPipelineSkinAdditive: MTLRenderPipelineState?
    var meshPipelineNormal: MTLRenderPipelineState?    // M3: PBR 노멀맵/마스크(mf_normal)
    var meshPipelineNormalAdditive: MTLRenderPipelineState?
    var meshPipelineRefract: MTLRenderPipelineState?   // H4: REFRACT 메시(mf_refract, 정적 한정)
    var meshPipelineRefractAdditive: MTLRenderPipelineState?
    var meshPipelineReflect: MTLRenderPipelineState?   // M6(⑥): REFLECTION 메시(mf_reflect, 정적 한정)
    var meshPipelineReflectAdditive: MTLRenderPipelineState?
    // 3D 파티클(원근 빌보드) — bgra8+depth32 타깃용(2D additivePipeline 은 acc 포맷이라 별도).
    var particle3DAdditive: MTLRenderPipelineState?
    var particle3DTranslucent: MTLRenderPipelineState?
    /// M(④): 씬 포그 참여(GPUParticleSystem.foggy) 3D 파티클 전용 변형(pv3d_fog_main/pf3d_fog).
    var particle3DFogAdditive: MTLRenderPipelineState?
    var particle3DFogTranslucent: MTLRenderPipelineState?
    /// 3D 파티클 시뮬의 마지막 진행 시각(캡처 전용 — 라이브는 클램프 dt 로 구동하며 clock 미사용). mount/캡처 시작에서 0.
    var particle3DClock: Float = 0
    /// 직전 stepParticleSnapshots 가 밟은 서브스텝 수(테스트 관측 — 라이브 프레임당 유한 스텝 보장 검증, 감사 C1).
    var particle3DLastStepCount = 0
    var shadowPipelineStaticOpaque: MTLRenderPipelineState?
    var shadowPipelineStaticCutout: MTLRenderPipelineState?
    var shadowPipelineSkinOpaque: MTLRenderPipelineState?
    var shadowPipelineSkinCutout: MTLRenderPipelineState?
    var pointShadowDepthState: MTLDepthStencilState?
    var pointShadowAtlas: MTLTexture?
    var pointShadowAtlasSlices = 0
    /// 카메라 프로퍼티 스크립트(eye/center/up/fov). per-frame 재평가로 카메라 애니.
    var cameraScripts: [Script3D] = []
    var meshDepthStates: [String: MTLDepthStencilState] = [:]  // "test-write" 키
    var depthTextures: [String: MTLTexture] = [:]     // 크기별 재사용(.depth32Float)

    /// 프로세스 환경 **스냅샷 1회**. `ProcessInfo.processInfo.environment` 는 접근할 때마다 사전을
    /// 새로 구성하는데, 아래 debugFlag/environmentValue 는 draw 루프에서 매 프레임 호출된다
    /// (encode3D:1594 · encode3DParticles:2121 · runTranslatedEffect 의 WAPLE_MP_TRUNC).
    /// 비싼 것은 조회가 아니라 **딕셔너리 구성**이다. `ProcessInfo.processInfo.environment` 는
    /// 접근할 때마다 environ 전체를 훑어 [String: String] 을 새로 만든다 — 프레임마다 여러 번
    /// 부르면 그게 그대로 할당이 된다. getenv 는 그 구성을 건너뛴다.
    ///
    /// [정정 2026-08-19] 종전 수정은 이 자리를 `static let` 스냅샷으로 바꿨는데, 근거가
    /// "환경변수는 프로세스 수명 중 불변" 이었다. **이 코드베이스에서는 거짓이다** —
    /// 테스트가 런타임에 setenv 로 게이트를 켠다(AGENTS.md 의 env 게이트 규약, 21개 파일).
    /// 스냅샷이 먼저 뜨면 그 뒤 setenv 가 영영 안 보여서
    /// SceneRendererMeshCustomShaderTests.testBuiltinMeshShaderGateOnLoadsWhitelistedBaseAssetsSource
    /// 가 CI 에서 깨졌다. getenv 는 할당을 없애면서 런타임 변경도 그대로 반영한다.
    ///
    /// 디버그 env 플래그(`WAPLE_3D_*`).
    static func debugFlag(_ name: String) -> Bool {
        environmentValue(name) == "1"
    }

    /// 위와 같은 근거의 env 값 조회("1" 이 아닌 값을 파싱하는 디버그 스위치용).
    static func environmentValue(_ name: String) -> String? {
        guard let raw = getenv(name) else { return nil }
        return String(cString: raw)
    }

    public override init() { super.init() }

    /// teardown 미호출 경로 안전망(비대칭 해소 — ParallaxController/MediaPoller 는 자체 deinit 보유).
    /// 전역 클릭 모니터는 renderer 소멸 후에도 시스템에 남고(블록이 weak self 라 리테인 사이클은
    /// 없지만 모니터 등록 자체가 누수), 오디오 캡처 스트림도 stop 없이는 계속 돈다.
    deinit {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        mediaPoller?.stop()
        audioProvider?.stop()
        sceneAudio?.teardown()
    }

    public func mount(in container: NSView, project: WallpaperProject) throws {
        teardown()
        hasMissingRequiredSharedAssets = false
        scenePausedAt = nil
        drawGateOccludedSince = nil   // 마운트 재사용 대비 가림 게이트 추적 리셋(stale 시각으로 오보정 방지)
        shouldAnimate = false
        hasVideoLayer = false   // 마운트 재사용: 이전 비디오 상태가 비-비디오 씬으로 새지 않게.
        videoLayersLive = false
        sceneWantsLDRBloom = false
        ldrBloomParameters = .defaults
        ldrBloomPass = nil
        sceneWantsHDRBloom = false
        hdrBloomParameters = .defaults
        hdrBloomPass = nil
        // G-E3-01: 씬은 `.pkg` 로도, **언팩 폴더**로도 온다. WE 2.8.42 설치본 실측: `projects/` 의
        // 기본 배경 19종 + 템플릿 2종이 전부 언팩이고 `.pkg` 는 0개다. 에디터가 만드는 로컬
        // 프로젝트도 언팩이다. 폴더 백엔드는 지연 파일 읽기라 38 MB 짜리 기본 프로젝트를 통째로
        // 메모리에 올리지 않는다(ScenePackage.fromDirectory 주석 참조).
        //
        // [2026-08-21 정정 — docs/re/package-format.md §6·§7.1] 종전 이 줄은 `pkgURL(in:)` 으로
        // **파일 존재**를 보고 골랐다("pkg 를 우선하되"). WE 는 그렇게 하지 않는다 —
        // `project.json` 의 `file` 이 단독 결정자고 `.pkg` 는 그 파일이 디스크에 **없을 때만** 도는
        // 폴백이다. 갈리는 지점과 결과는 `ScenePackage.resolveMountSource(...)` 주석에 표로 적었다.
        // 가장 나쁜 쪽은 `file:"techno.json"` 이 없고 `techno.pkg` 만 있을 때로, 종전에는
        // `pkgURL` 이 nil → 폴더 마운트 → `techno.json` 없음 → `.noScene` 이라 **적용 자체가 실패**했다.
        //
        // 무회귀 근거: 설치본+동봉 `project.json` **361건 전수**로 바꾸기 전/후 결정을 대조했고
        // **차이 0건**이다(전건 `.directory`). 361건 모두 `file` 이 디스크에 실재하고, 두 루트
        // 9,078 파일에 `.pkg` 는 0개라 종전 선택자도 전건 nil 을 냈기 때문이다.
        let mountSource = ScenePackage.resolveMountSource(
            folderURL: project.folderURL,
            fileName: project.fileName,
            hasDependency: project.dependency != nil
        )
        let pkgURL: URL?
        switch mountSource {
        case .package(let url): pkgURL = url
        case .directory: pkgURL = nil
        }
        var data = Data()
        if let pkgURL {
            do {
                data = try WapleProfiler.time("pkgRead") { try Data(contentsOf: pkgURL) }
            } catch {
                NSLog("%@", "[Waple] scene mount: cannot read \(pkgURL.path): \(error)")
                throw RendererError.assetMissing
            }
        }
        let sourceDescription = pkgURL?.path ?? project.folderURL.path
        // C①: project.json 기본값을 doc 파스보다 먼저 확보 — {user,value} 바인딩 해석(resolveUserBindings)
        // 이 project.json 기본값도 유효값으로 보게 하려면 파스 시점 userProps 에 이미 실려 있어야 한다
        // (종전엔 유저가 변경한 키만 실려, 미변경 키는 저작 스냅샷 baked value 로 남아 아래
        // effectiveProperties/variantProperties 채널과 유효값 정의가 어긋났다).
        let baseProps = (try? WallpaperProperties.parse(folderURL: project.folderURL)) ?? []
        let package: ScenePackage
        let doc: SceneDocument
        do {
            if pkgURL != nil {
                package = try WapleProfiler.time("pkgParse") { try ScenePackage.parse(data) }
            } else {
                guard let folderPackage = WapleProfiler.time("dirScan", { ScenePackage.fromDirectory(project.folderURL) }) else {
                    // 결정은 이미 `resolveMountSource` 가 내렸다 — 여기까지 왔다는 건 "폴더 마운트"
                    // 였는데 폴더에 읽을 파일이 하나도 없다는 뜻이다(종전 메시지는 `.pkg` 두 이름을
                    // 들먹여 원인을 잘못 가리켰다).
                    NSLog("%@", "[Waple] scene mount: nothing to mount for file=\(project.fileName ?? "<none>") in \(project.folderURL.path)")
                    throw RendererError.assetMissing
                }
                package = folderPackage
            }
            // 공유(base-assets) 리졸버: pkg 에 없는 util 모델/머티리얼 JSON(솔리드 레이어 등) 폴백.
            doc = try WapleProfiler.time("docParse") {
                let assetRoots = BaseAssetsSettings.searchRoots
                return try SceneDocument.parse(package: package, sharedAssetProbe: { name in
                    Self.sharedAssetProbe(name, roots: assetRoots)
                }, onMissingRequiredAsset: { [weak self] in
                    self?.markMissingRequiredSharedAsset()
                }, userProps: UserPropertyStore.rawOverrides(
                    id: project.id,
                    projectDefaults: baseProps,
                    presetOverrides: project.presetOverrides,
                    presetResourceRoot: project.presetFolderURL
                ), sceneFileName: project.fileName)
            }
        } catch {
            NSLog("%@", "[Waple] scene mount: failed to parse \(sourceDescription): \(error)")
            throw error
        }
        // 조건 변형 텍스처(TEXB0004, 예 tuniccolor) 선택용 유효 프로퍼티 스냅샷:
        // project.json 기본값 + 유저/프리셋 오버라이드(LibraryViewModel 유효값 계산과 동형).
        // 값 부재/미매치는 기본 image 로 폴백 → 무회귀. 변경은 reapply(remount)로 새 스냅샷.
        let overrides = UserPropertyStore.overrides(
            id: project.id,
            presetOverrides: project.presetOverrides,
            presetResourceRoot: project.presetFolderURL
        )
        let effectiveProperties = WallpaperProperties.applying(overrides: overrides, to: baseProps)
        variantProperties = Dictionary(
            effectiveProperties.map { ($0.key, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        sceneUserPropertiesJSON = WallpaperProperties.weUserPropertiesJSON(effectiveProperties)
        // 비디오-텍스처 레이어는 씬을 통째로 VideoRenderer 로 스왑하지 않는다(형제 레이어 소실). buildLayers 가
        // 각 video 레이어를 SceneVideoLayer 공급자를 붙인 일반 GPULayer 로 만들고, draw/captureFrames 가
        // buildDisplayTextures 로 프레임을 합성한다(라이브 재생은 아래 container.window 게이트에서 기동).
        let (deviceOpt, queueOpt): (MTLDevice?, MTLCommandQueue?) = WapleProfiler.time("deviceInit") {
            let d = MTLCreateSystemDefaultDevice()
            return (d, d?.makeCommandQueue())
        }
        guard let device = deviceOpt, let queue = queueOpt else { throw RendererError.unsupportedType }
        self.device = device
        self.queue = queue
        self.assetBaseRoots = Self.resolvedAssetBaseRoots()

        // A2 HDR: 최종 클램프 파이프라인이 빌드돼야 sceneIsHDR 활성(실패 시 종전 LDR 폴백 = 무회귀).
        // 아래 파이프라인 생성보다 먼저 확정해야 accPixelFormat 이 float 로 잡힌다.
        if doc.hdr, let post = HDRPostPass(device: device, outputFormat: .bgra8Unorm) {
            self.sceneIsHDR = true
            self.hdrPost = post
        }
        // H7: 품질 설정 스냅샷(general.quality).
        self.sceneQuality = doc.quality
        // LDR bloom is authored-policy gated, not HDR-pipeline-availability gated.
        // 디버그: WAPLE_NO_BLOOM=1 → bloom 강제 OFF(백화 파리티 이분용).
        sceneWantsLDRBloom = doc.bloom && !doc.hdr
            && ProcessInfo.processInfo.environment["WAPLE_NO_BLOOM"] == nil
        ldrBloomParameters = LDRBloomParameters(
            strength: doc.bloomStrength,
            threshold: doc.bloomThreshold,
            tint: SIMD3(doc.bloomTint.x, doc.bloomTint.y, doc.bloomTint.z))
        if sceneWantsLDRBloom {
            ldrBloomPass = LDRBloomPass(device: device)
        }
        // #22 HDR bloom: hdr&&bloom 씬 — LDR 과 병행하는 별개 레시피(둘은 상호배타 게이트).
        // 실효 strength = 저작 × iterations × strengthScale(단일레벨의 피라미드 누적 보상 —
        // 골든/preview 2점 캘리브, HDRBloomPass.strengthScale 주석 참조).
        sceneWantsHDRBloom = doc.hdr && doc.bloom
            && ProcessInfo.processInfo.environment["WAPLE_NO_BLOOM"] == nil
        hdrBloomParameters = HDRBloomParameters(
            strength: doc.bloomHDRStrength * Float(max(1, doc.bloomHDRIterations))
                * HDRBloomPass.strengthScale,
            threshold: doc.bloomHDRThreshold,
            feather: doc.bloomHDRFeather,
            tint: SIMD3(doc.bloomTint.x, doc.bloomTint.y, doc.bloomTint.z))
        // P③: 피라미드는 raw strength(×iterations 보정 없음 — 피라미드 자체가 N레벨을 가산 누적)와
        // 저작 scatter/iterations 를 그대로 받는다(단일레벨 hdrBloomParameters 와 별개 소스).
        hdrBloomPyramidStrength = doc.bloomHDRStrength
        hdrBloomPyramidScatter = doc.bloomHDRScatter
        hdrBloomPyramidLevels = max(1, doc.bloomHDRIterations)
        if sceneWantsHDRBloom {
            hdrBloomPass = HDRBloomPass(device: device)
            hdrBloomPyramidPass = HDRBloomPyramidPass(device: device)
        }
        // H5: 볼륨 라이트 샤프트 패스(castVolumetrics 라이트가 있는 3D 씬).
        if doc.camera3D != nil, doc.lights3D.contains(where: { $0.castVolumetrics }) {
            volumetricLightPass = VolumetricLightPass(device: device)
        }

        let library = try WapleProfiler.compile(QuadShaders.source) { try device.makeLibrary(source: QuadShaders.source, options: nil) }
        // 감사 V07: nearest 변형 라이브러리(베이스 레이어 NoInterpolation). 실패는 마운트 중단 사유가 아님
        // (try?) — nearest 파이프라인 전부 nil 로 두고 encodeLayer 가 선형 폴터(무회귀·무크래시).
        let libraryNearest = try? WapleProfiler.compile(QuadShaders.nearestSource) { try device.makeLibrary(source: QuadShaders.nearestSource, options: nil) }
        let pdesc = MTLRenderPipelineDescriptor()
        pdesc.vertexFunction = library.makeFunction(name: "v_main")
        pdesc.fragmentFunction = library.makeFunction(name: "f_main")
        let att = pdesc.colorAttachments[0]!
        att.pixelFormat = accPixelFormat   // A2: HDR 씬은 float(>1 보존), 그 외 bgra8(무회귀)
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add; att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .one; att.sourceAlphaBlendFactor = .one
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha; att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.pipeline = try WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pdesc) }
        // DIRECTDRAW 이펙트 출력 전용: 블렌드 상태는 위와 동일(premultiplied-over)이고 프래그먼트만
        // premultiply 를 생략한 f_main_premul 로 바꾼다 — 이펙트 결과가 이미 색×커버리지이기 때문
        // (근거는 f_main_premul 주석). 아래 additive 는 다시 f_main 으로 되돌린 뒤 만든다.
        //
        // 왜 premultiplied-over 인가(WE 규약 추적 결과):
        //  - 확정: WE 머티리얼 blending 4종은 normal=블렌딩 OFF(RGB 덮어쓰기) / translucent=
        //    SRC_ALPHA·INV_SRC_ALPHA / additive=SRC_ALPHA·ONE / alphatocoverage 다
        //    (spec/engine/render-state.json `renderState.blend.byBlendingMode`, 바이너리 실측).
        //    **넷 중 어느 것도 premultiplied 소스를 옳게 합성하지 못한다** — translucent·additive 는
        //    src.rgb 에 src.a 를 다시 곱하므로 정확히 이 버그(fx²)를 재현하고, normal 은 배경을 지운다.
        //  - 확정: WE 는 그 밖에 상태 플래그 bit7(0x80) = SrcBlend ONE / DestBlend INV_SRC_ALPHA
        //    (프리멀티플라이드 오버 + 알파 누적)를 갖는다(같은 파일 `renderState.blend.flagBits`).
        //  - 정황: 그 비트의 **호출부**는 미추적이다(해당 항목 status=보고). 즉 "DIRECTDRAW 패스가
        //    bit7 을 켠다"는 것은 확정이 아니라, premultiplied 출력과 아귀가 맞는 유일한 WE 상태라는
        //    소거법 결론이다.
        //  - 실측 A/B(3690417937, WE 실기 스크린샷 대조): 기준선 정렬후 0.918·휘도비 0.885 →
        //    premult-over 0.917·1.005, additive(dst=ONE) 0.912·1.043. 두 지표 모두 premult-over 우세.
        pdesc.fragmentFunction = library.makeFunction(name: "f_main_premul")
        self.layerPremultipliedPipeline = try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pdesc) }
        pdesc.fragmentFunction = library.makeFunction(name: "f_main")
        // 같은 v_main/f_main + accPixelFormat. premultiplied source를 destination에 그대로 더한다.
        att.destinationRGBBlendFactor = .one
        att.destinationAlphaBlendFactor = .one
        self.layerAdditivePipeline = try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pdesc) }
        // colorBlendMode 레이어: dst 스냅샷 대비 블렌드를 셰이더에서 계산 → HW 블렌딩 OFF.
        let bdesc = MTLRenderPipelineDescriptor()
        bdesc.vertexFunction = library.makeFunction(name: "v_main")
        bdesc.fragmentFunction = library.makeFunction(name: "f_blend")
        bdesc.colorAttachments[0]!.pixelFormat = accPixelFormat
        self.blendPipeline = try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: bdesc) }
        // 컴포지션(f_compose): 프레임버퍼를 화면좌표로 샘플 — f_main 과 동일 프리멀티 오버 블렌드.
        let cdesc = MTLRenderPipelineDescriptor()
        cdesc.vertexFunction = library.makeFunction(name: "v_main")
        cdesc.fragmentFunction = library.makeFunction(name: "f_compose")
        let catt = cdesc.colorAttachments[0]!
        catt.pixelFormat = accPixelFormat   // HDR 씬은 float acc — f_main/f_blend/f_lit 와 동일 포맷(불일치=Metal 크래시/미정의). f_compose 는 float4 출력이라 LDR/HDR 양쪽 정상
        catt.isBlendingEnabled = true
        catt.rgbBlendOperation = .add; catt.alphaBlendOperation = .add
        catt.sourceRGBBlendFactor = .one; catt.sourceAlphaBlendFactor = .one
        catt.destinationRGBBlendFactor = .oneMinusSourceAlpha; catt.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.composePipeline = try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: cdesc) }
        // 포워드 라이팅(f_lit): f_main 과 동일 프리멀티 오버 블렌드 — 라이트 반응만 다르다.
        let ldesc = MTLRenderPipelineDescriptor()
        ldesc.vertexFunction = library.makeFunction(name: "v_main")
        ldesc.fragmentFunction = library.makeFunction(name: "f_lit")
        let latt = ldesc.colorAttachments[0]!
        latt.pixelFormat = accPixelFormat
        latt.isBlendingEnabled = true
        latt.rgbBlendOperation = .add; latt.alphaBlendOperation = .add
        latt.sourceRGBBlendFactor = .one; latt.sourceAlphaBlendFactor = .one
        latt.destinationRGBBlendFactor = .oneMinusSourceAlpha; latt.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.litPipeline = try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: ldesc) }
        // 스프라이트 프레임 추출(f_spriteframe): dst=makeOffscreen(rgba8Unorm), 블렌딩 없음(straight 덮어쓰기).
        let sfdesc = MTLRenderPipelineDescriptor()
        sfdesc.vertexFunction = library.makeFunction(name: "v_spriteframe")
        sfdesc.fragmentFunction = library.makeFunction(name: "f_spriteframe")
        sfdesc.colorAttachments[0]!.pixelFormat = .rgba8Unorm
        self.spriteFramePipeline = try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: sfdesc) }

        clearColor = MTLClearColor(red: Double(doc.clearColor.x), green: Double(doc.clearColor.y),
                                   blue: Double(doc.clearColor.z), alpha: 1)
        // clearenabled=false: acc 미클리어(잔상 누적) — 마운트마다 누적 버퍼 재확보(이전 씬 잔상 차단).
        clearEnabled = doc.clearEnabled
        // 마운트 재사용 시 풀·캐시 일괄 해제(teardown 과 같은 함수). 종전엔 여기서 trailAcc 만 비웠고
        // reflectionSnapshotPool 은 teardown·mount **양쪽 모두**에서 빠져 마운트마다 누적됐다.
        releasePooledGPUTextures()
        projW = Float(max(1, doc.projectionWidth)); projH = Float(max(1, doc.projectionHeight))
        projAspect = projW / projH
        // camera 의사-오브젝트 → 2D 뷰 줌(3D 는 미소비 — draw 3D 분기가 zoom 상태를 안 읽는다).
        applyCameraObjects(doc.cameraObjects)
        sceneZoom = doc.zoom   // F744(S-18): 씬 전역 줌(사용 지점에서 >0 새니타이즈)
        // 씬 공유 JSContext — 3D 오브젝트/빌보드 스크립트와 2D buildLayers/buildTexts/효과 스크립트가 공유.
        // **build3D 보다 먼저** 생성해야 3D 스크립트가 shared 통신 컨텍스트에 로드된다(태양계 Main 컨트롤러가
        // shared 궤도 파라미터를 세팅, 행성 origin 스크립트가 이를 읽음 — 공유 컨텍스트 없으면 shared 소실).
        let scriptLayerDescriptors = Self.sceneScriptLayers(from: doc)
        // F810(S-7 잔여): localStorage 디스크 영속은 라이브 마운트 한정(container.window != nil —
        // sceneAudio :1221 과 동일 판정). 헤드리스 캡처(스냅샷)는 환경 잔존 상태가 렌더를 오염시키지
        // 않게 인메모리 유지(결정성 계약). 멀티모니터는 같은 씬 id 파일을 공유(원자 쓰기, 최종자 승).
        sceneScript = SceneScriptContext(layers: scriptLayerDescriptors,
                                         soundNames: doc.sounds.map { $0.name },
                                         width: projW, height: projH,
                                         localStorageStore: container.window != nil
                                             ? ScriptLocalStorage(sceneId: project.id) : nil)
        sceneScriptBaseDescriptors = scriptLayerDescriptors  // F743(S-35): 라이브 갱신 기준 배열
        sceneScriptImageLayerCount = doc.layers.count  // F723: 텍스트 read-back 인덱스 오프셋(이미지→텍스트 순)
        forwardLit = false  // 마운트 재사용 대비 기본값(2D 브랜치에서만 활성화)
        // 3D 씬(camera3D + .mdl 오브젝트): 메시 + 빌보드(2D 이미지 레이어) + 오브젝트/그룹 프로퍼티 스크립트.
        // 메시/빌보드가 하나도 안 올라오면(로드 실패) 기존 2D 폴백 유지.
        if let cam = doc.camera3D, !doc.objects3D.isEmpty {
            // 3D 카메라는 camera 의사-오브젝트가 우선이다(게이트 통과 시) — scene.camera 는 WE 에디터의
            // 수동 카메라라 씬이 실제로 그리는 구도와 다르다. 근거·게이트·A/B 는 camera3DFromObject 주석.
            camera3D = Self.camera3DFromObject(doc.cameraObjects, base: cam) ?? cam
            build3D(doc: doc, package: package, device: device)
            is3D = !meshRenderables.isEmpty || !billboards.isEmpty
            // 3D 씬 파티클: 기존 CPU 시뮬(buildParticles 공용) 로 구동, encode3D 가 원근 빌보드로 렌더.
            // 종전엔 이 배선이 없어 3D 씬의 파티클 오브젝트가 전량 드롭됐다(B3 분석 §최중요 갭).
            if is3D {
                particleSystems = buildParticles(doc: doc, package: package, device: device)
                if !particleSystems.isEmpty {
                    hasParticles = true
                    particle3DClock = 0   // 시뮬 t=0 기준. encode3D 가 매 프레임 time 까지 서브스텝(캡처 단일 프레임 포함).
                    particle3DAdditive = particle3DPipeline(additive: true, device: device)
                    particle3DTranslucent = particle3DPipeline(additive: false, device: device)
                    particle3DFogAdditive = particle3DFogPipeline(additive: true, device: device)
                    particle3DFogTranslucent = particle3DFogPipeline(additive: false, device: device)
                }
            }
        }
        // F721(S-12): ortho(2D) 씬의 3D 모델 오브젝트 하이브리드. ortho 씬은 parseCamera 가 camera3D=nil
        // 을 반환해 종전엔 build3D 미진입 → .mdl 오브젝트가 조용히 드롭됐다(실물 3354366708 의 대형 링 3개).
        // 2D 경로(buildLayers/파티클/텍스트)를 그대로 유지하면서 build3D 로 메시/노드만 적재하고,
        // 2D 와 중복되는 부산물(빌보드=2D 레이어, 텍스트 컨트롤러=2D 텍스트)과 그 엔진의 훅 등록은 되돌린다
        // (이중 로드·이중 훅 발화 방지). 노드(3D 오브젝트/그룹) 엔진은 2D 대응물이 없어 유지.
        if doc.camera3D == nil, !doc.objects3D.isEmpty {
            build3D(doc: doc, package: package, device: device)
            if !meshRenderables.isEmpty {
                let dupEngines = Set((billboards.flatMap { $0.scripts.map(\.engine) }
                                      + text3DControllers.map(\.engine)).map { ObjectIdentifier($0) })
                if !dupEngines.isEmpty {
                    eventEngines.removeAll { dupEngines.contains(ObjectIdentifier($0)) }
                    hoverEngineLayers.removeAll { dupEngines.contains(ObjectIdentifier($0.engine)) }
                    pointerEngineOwners.removeAll { dupEngines.contains(ObjectIdentifier($0.engine)) }
                }
                eval3DOrder = eval3DOrder.filter { !$0.bb }   // 빌보드 평가 항목 제거(아래서 billboards 를 비움)
                draw3DOrder = []   // encode3D 는 하이브리드에서 미호출(ortho 메시 패스가 대신 그림)
                billboards = []; billboardDefs = []; text3DControllers = []
                ortho3DHybrid = true
                NSLog("%@", "[Waple] ortho 3D hybrid: \(meshRenderables.count) mesh renderables (2D scene + .mdl objects)")
            } else {
                // 메시가 하나도 안 올라오면(로드 실패) 3D 부산물 전량 폐기 — 종전 2D 전용 경로와 동일(무회귀).
                billboards = []; billboardDefs = []; text3DControllers = []
                nodes3D = []; eval3DOrder = []; draw3DOrder = []; has3DScripts = false
            }
        }
        if !is3D {
            camera3D = nil
            // 2D 포워드 라이팅: 씬 라이트 유니폼(상수) 산출. 게이트(forwardLit2D)=2D+라이트 존재.
            // buildLayers 보다 먼저 — 레이어별 litRect 산출 게이트가 이 값을 참조.
            forwardLit = doc.forwardLit2D && litPipeline != nil
            if forwardLit {
                let u = SceneLight3D.forwardUniforms(doc.lights3D, ambient: doc.ambientColor, skylight: doc.skylightColor)
                lightPositions = u.positions
                lightColorRadius = u.colorRadius
                lightAxisCone = u.axisCone      // F800(S-9)
                lightKindCone = u.kindCone      // F800(S-9)
                lightAmbient = SIMD4(u.ambientTerm.x, u.ambientTerm.y, u.ambientTerm.z, 0)
            }
            layers = buildLayers(doc: doc, package: package, device: device, sceneID: project.id)
            // 감사 V07: NoInterpolation 무효과 레이어가 있을 때만 nearest 변형 5종 빌드(동일 디스크립터,
            // frag 만 nearestSource 동명 함수로 교체 — 선형 본체와 1:1 대응). 미빌드/nil 이면 encodeLayer 선형 폴터.
            if let libN = libraryNearest, layers.contains(where: { $0.noInterp && $0.effects.isEmpty }) {
                pdesc.fragmentFunction = libN.makeFunction(name: "f_main")
                att.destinationRGBBlendFactor = .oneMinusSourceAlpha
                att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                pipelineNearest = try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pdesc) }
                att.destinationRGBBlendFactor = .one
                att.destinationAlphaBlendFactor = .one
                layerAdditiveNearestPipeline = try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pdesc) }
                bdesc.fragmentFunction = libN.makeFunction(name: "f_blend")
                blendNearestPipeline = try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: bdesc) }
                cdesc.fragmentFunction = libN.makeFunction(name: "f_compose")
                composeNearestPipeline = try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: cdesc) }
                ldesc.fragmentFunction = libN.makeFunction(name: "f_lit")
                litNearestPipeline = try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: ldesc) }
            }
            particleSystems = buildParticles(doc: doc, package: package, device: device)
            if !particleSystems.isEmpty {
                hasParticles = true
                additivePipeline = particlePipeline(additive: true, device: device)
                translucentPipeline = particlePipeline(additive: false, device: device)
                // 감사 V07: noInterp 시스템이 있을 때만 nearest 변형 빌드(미빌드 시 encodeParticle 선형 폴터).
                if particleSystems.contains(where: { $0.noInterp }) {
                    additiveNearestPipeline = particlePipeline(additive: true, nearest: true, device: device)
                    translucentNearestPipeline = particlePipeline(additive: false, nearest: true, device: device)
                }
                // REFRACT 시스템이 있으면 굴절 파이프라인 빌드(스냅샷 재샘플). 블렌드 변형은 실제 필요한
                // 쪽만(C4-(iii): additive+REFRACT 코퍼스 10씬 — translucent 뿐이던 종전 가정 반박).
                if particleSystems.contains(where: { $0.refract && $0.normalTexture != nil && !$0.blendAdditive }) {
                    refractParticlePipeline = refractParticlePipelineBuild(additive: false, device: device)
                }
                if particleSystems.contains(where: { $0.refract && $0.normalTexture != nil && $0.blendAdditive }) {
                    refractParticlePipelineAdditive = refractParticlePipelineBuild(additive: true, device: device)
                }
            }
            textLayers = buildTexts(doc: doc, package: package, device: device)
            // H4: REFRACT 이미지 레이어 파이프라인 빌드(레이어 중 하나라도 refract 활성 시).
            if layers.contains(where: { $0.refract.enabled && $0.refract.normalTexture != nil }) {
                refractLayerPipeline = refractLayerPipelineBuild(device: device)
            }
        }
        // 씬 오브젝트 순서(z-순서)대로 레이어·파티클·텍스트를 인터리브 드로우.
        // 안정 정렬(order 동률 시 삽입 순서 유지) — 파티클 자식이 부모 뒤에 오도록 보장
        // (자식 스냅샷은 같은 프레임에 부모가 먼저 스텝된 캐시를 읽는다).
        // F721: ortho 하이브리드의 3D 메시도 같은 order 로 인터리브(.mesh3D — encodeDrawPlan 이
        // 연속 런을 한 메시 패스로 묶어 뎁스 공유).
        drawPlan = (layers.enumerated().map { (i, l) in (l.order, DrawItem(kind: .layer, idx: i)) }
                    + particleSystems.enumerated().map { (i, p) in (p.order, DrawItem(kind: .particle, idx: i)) }
                    + textLayers.enumerated().map { (i, t) in (t.order, DrawItem(kind: .text, idx: i)) }
                    + (ortho3DHybrid ? meshRenderables.enumerated().map { (i, m) in (m.order, DrawItem(kind: .mesh3D, idx: i)) } : []))
            .enumerated()
            .sorted { ($0.1.0, $0.0) < ($1.1.0, $1.0) }
            .map { $0.1.1 }
        // F742(S-19): dependencies(F696) depLater 보정 — 의존 타깃이 후순위면 의존자 직전으로 이동.
        drawPlan = Self.applyingDependencies(drawPlan, layers: doc.layers)
        // 디버그: WAPLE_LAYER_TRUNC=n → z-정렬된 draw 앞 n개만(레이어 이분용, 백화 유발 레이어 특정).
        if let t = ProcessInfo.processInfo.environment["WAPLE_LAYER_TRUNC"], let n = Int(t), n >= 0, n < drawPlan.count {
            drawPlan = Array(drawPlan.prefix(n))
        }

        // ── 격리 계약(2026-08-19, 엄격 동시성) ───────────────────────────────────────
        // **이 뷰 생성 경로는 nonisolated 로 남겨야 한다. mount/captureFrames/teardown 에
        // @MainActor 를 붙이지 마라.** AppDelegate.captureSceneStill(F486)이 마운트(셰이더 컴파일)와
        // captureFrames(GPU 대기)를 백그라운드 큐에서 부르기 때문이다 — 종전에 그 둘을 main.sync 로
        // 돌려 무거운 씬에서 메뉴/라이브러리 창이 수 초 정지했던 것(F049)이 F486 이 고친 결함이고,
        // 여기에 격리를 붙이면 그 호출부(nonisolated)가 컴파일되지 않아 F486 이 자동으로 되돌아간다.
        // (AppDelegate 쪽은 NSView 할당만 메인에 잠깐 다녀오고 나머지는 큐에 남겨 두었다 —
        //  그 파일의 captureSceneStill 주석 "⚠️ 남는 긴장" 이 이 계약을 요청한 것이다.)
        //
        // 그래서 아래 MTKView 생성·프로퍼티 대입은 "메인 액터 API 를 비격리 컨텍스트에서 호출"
        // 진단을 계속 낸다. 그건 표기 누락이 아니라 **의도된 오프메인 경로**다. 안전 근거는 F486 의
        // 관찰 그대로다: 이 컨테이너는 어떤 창에도 속하지 않아 창 계층에 들어가지 않고, draw/이벤트가
        // 발생하지 않으며(isPaused=true + enableSetNeedsDisplay), 캡처는 커맨드 인코딩과 readback 뿐이다.
        // 라이브 데스크탑 경로는 반대로 항상 메인에서 마운트된다(AppDelegate.applyResolved).
        // 이 진단을 없애려면 표기가 아니라 설계를 바꿔야 한다 — 캡처 경로를 뷰 없는 오프스크린
        // 렌더 타깃으로 분리하는 것(그러면 AppKit 의존이 사라진다). 지금 규모의 변경은 별도 작업이다.
        let view = WapleMTKView(frame: container.bounds, device: device)
        view.autoresizingMask = [.width, .height]
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false  // 누적(acc) → drawable blit 대상이 되려면 필요(컴포지션 합성)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        // 라이브 데스크탑 프레젠트 상하 뒤집힘 보정(macOS 26+, 실기기 27 확인) — 캡처(readback)는
        // drawable 을 안 타 무영향, 클릭 역매핑도 물리 좌표 기반이라 무영향(근거: SceneLivePresentationFix 상단 주석).
        // F4: 조건부(true 일 때만) 대입 대신 항상 명시 대입 — 이후 재부모화/재동기화로 값이 되돌아가도
        // WapleMTKView.viewDidMoveToWindow + draw(in:) 진입부가 이 기대값을 멱등 재확인한다.
        view.layer?.isGeometryFlipped = SceneLivePresentationFix.needsDesktopFlipY
        container.wantsLayer = true
        container.addSubview(view)
        self.mtkView = view
        view.needsDisplay = true
        // 시차/포인터 정규화는 렌더 뷰가 실제 속한 화면 기준(보조 모니터 지원). 마운트 시점엔
        // window 가 아직 nil 일 수 있어 매 emit 시 지연 평가.
        parallax.screenProvider = { [weak view] in view?.window?.screen }

        parallaxEnabled = doc.parallaxEnabled
        parallaxAmount = doc.parallaxAmount
        parallaxMouseInfluence = doc.parallaxMouseInfluence
        parallaxDelay = doc.parallaxDelay
        cameraShakeEnabled = doc.cameraShake
        cameraShakeAmplitude = doc.cameraShakeAmplitude
        cameraShakeRoughness = doc.cameraShakeRoughness
        cameraShakeSpeed = doc.cameraShakeSpeed
        // 마우스 모니터는 시차 + 포인터 유니폼(g_PointerPosition — 커서 반응 효과) 공용.
        if parallaxEnabled || hasEffects { startPointerMonitor() }

        effectVertexBuffer = device.makeBuffer(bytes: fullscreenQuad, length: MemoryLayout<SIMD2<Float>>.stride * fullscreenQuad.count)
        // 변환 효과용 인터리브드 쿼드(triangleStrip): pos.xyz + uv.xy. uv 는 손-포팅 vert(ev_main)의
        // ((p+1)*0.5, 1-(p+1)*0.5) 매핑과 동일하게 매칭(오라클 픽셀 일치 보장).
        let interleaved: [Float] = [
            -1, -1, 0,  0, 1,
             1, -1, 0,  1, 1,
            -1,  1, 0,  0, 0,
             1,  1, 0,  1, 0,
        ]
        effectQuadInterleaved = device.makeBuffer(bytes: interleaved, length: MemoryLayout<Float>.stride * interleaved.count)
        // F1(flip①): 같은 포지션, uv 는 표준 quadVertices 규약(TL=uv(0,0))으로 반전 — 커스텀 2D 레이어 전용.
        let interleavedLayer: [Float] = [
            -1, -1, 0,  0, 0,
             1, -1, 0,  1, 0,
            -1,  1, 0,  0, 1,
             1,  1, 0,  1, 1,
        ]
        customLayerQuadInterleaved = device.makeBuffer(bytes: interleavedLayer, length: MemoryLayout<Float>.stride * interleavedLayer.count)
        shouldAnimate = hasEffects || hasParticles || hasScriptedText || hasAnimations || has3DScripts || hasVideoLayer
            || cameraZoomAnim != nil  // 카메라 줌 인트로(single)도 연속 재생 필요
            || cameraShakeEnabled     // camerashake 전역 지터는 t 의존 → 연속 재생 필요
        if shouldAnimate {
            view.isPaused = false
            view.enableSetNeedsDisplay = false
            // w5d-feature-gaps: 하드코딩 30 대신 사용자 설정(기본 30 — 무회귀). 비디오/웹은 자체
            // 페이싱이라 미적용 — 씬 렌더만 이 상한을 탄다.
            view.preferredFramesPerSecond = SceneRenderSettings.maxFPS.rawValue
            startTime = CFAbsoluteTimeGetCurrent()
            lastFrameTime = startTime
        }
        // 씬 이벤트 배선: cursorClick/Down/Up(전역 클릭 모니터) + cursorMove(마우스 모니터 공용,
        // 시차/효과 없어도 훅 있으면 기동) + 미디어(5초 폴링) — 소비 스크립트가 있을 때만.
        // buildAnimationEventTargets 가 animationlayers 스크립트 엔진을 새로 등록(eventEngines/
        // hoverEngineLayers 경유)하므로 아래 배선 스캔들보다 먼저 호출(의존 리소스는 위에서 이미 완성).
        buildAnimationEventTargets(doc: doc)  // 타임라인/퍼펫 마커 → animationEvent 발화 타깃(오브젝트 스코프)
        // 씬 sound 레이어 재생 — 라이브 한정. 헤드리스(캡처/테스트)는 container.window == nil → 스킵(결정성).
        // 음량은 VideoSettings(배경별) 재사용 → 동영상 설정 메뉴의 음소거/음량이 씬 오디오에도 적용.
        // F538(F-69): volume 프로퍼티 스크립트 엔진(makeScriptEngine)은 아래 이벤트 배선 스캔들과 오디오
        // 프로바이더 기동 게이트(:1129)보다 먼저 생성되어야 훅 등록(eventEngines/hoverEngineLayers)과
        // scriptWantsAudio 승격이 반영된다 — 종전에는 mount 말미 생성이라 훅 배달이 누락됐다.
        // F535(F-50): 멀티모니터에서 동일 씬이 여러 화면에 마운트되면 화멻다 SceneAudioPlayer 가 생겨
        // 같은 사운드가 마운트 시차만큼 어긋나 N중 재생(에코) — 프라이머리(메뉴 바) 화멻만 재생.
        if Self.isPrimaryScreenWindow(container.window), !doc.sounds.isEmpty {
            let audio = SceneAudioPlayer()
            // F214: volume 프로퍼티 스크립트(오디오/페이드 구동, 실측 12건) — 엔진은 씬 공유 컨텍스트에서
            // 생성(makeScriptEngine, top-level 사이드이펙트 즉시 실행). tick(time:) 이 draw 루프에서 재평가.
            audio.start(sounds: doc.sounds, package: package,
                        settingVolume: VideoSettings.volume(id: project.id),
                        volumeEngine: { [weak self] snd in
                            guard let src = snd.volumeScript else { return nil }
                            return self?.makeScriptEngine(src, layerName: snd.name.isEmpty ? nil : snd.name,
                                                          scriptPropsJSON: snd.volumeScriptProps)
                        })
            sceneAudio = audio
            // 씬 스크립트 사운드 트리거(getLayer(name).play()/isPlaying()/.volume)를 실제 트랜스포트에 배선.
            // 헤드리스(오디오 미생성)에선 미연결 → 브리지가 안전 no-op(트리거는 무시, 캡처 결정성 유지).
            sceneScript?.soundTransport = audio
        }
        startClickMonitorIfNeeded()
        hasCursorMoveHook = eventEngines.contains(where: { $0.hookNames.contains("cursorMove") })
        buildHoverTargets(doc: doc)   // cursorEnter/Leave 레이어 히트 쿼드 해석
        buildPointerTargets(doc: doc) // U-W5b: cursorMove/Click/Down/Up 배달 범위 해석
        if hasCursorMoveHook || !hoverTargets.isEmpty {
            startPointerMonitor()  // 이미 켜져 있으면 no-op(내부 nil 가드)
        }
        startMediaPollingIfNeeded()
        // 오디오-반응 효과가 있으면 시스템 오디오 스펙트럼 캡처 시작(Screen Recording 권한 필요).
        // E1(⑦): 형제 sceneAudio 블록(:1531)과 동일한 헤드리스 결정성 가드 — 종전엔 이 블록만 누락돼
        // 헤드리스(캡처/테스트) 경로에서도 SCStream 오디오 캡처가 무조건 기동됐다.
        // F833: sceneAudio 는 isPrimaryScreenWindow(프라이머리 1개만) 지만 여기는 window != nil(전 화면)로
        // 다르게 좁힌다 — sceneAudio 는 *재생*(BGM)이라 같은 씬이 여러 화면에 뜨면 사운드가 겹쳐 에코가
        // 나지만(F535), 이건 시스템 오디오를 *읽기*만 한다. 재생과 달리 겹쳐도 부작용이 없고, 그
        // SharedAudioCaptureCore(F536, 파일 말미)가 SCStream 캡처 1개를 여러 구독자가 공유하도록 이미
        // 멀티-구독자로 설계돼 있다 — 그런데 종전엔 프라이머리 게이트를 그대로 재사용해서 보조 모니터
        // SceneRenderer 인스턴스는 currentSpectrum 이 .silent 로 고정됐다(오디오-반응 씬이 보조 모니터에만
        // 있으면 프로세스 전체에서 provider 가 단 하나도 안 뜨는 최악의 경우까지 있었다). 형제
        // WebRenderer(:36,122)는 이 게이트 자체가 없이 마운트마다 무조건 provider 를 만든다 — 안전성의
        // 실증. window != nil 은 헤드리스(캡처/테스트, 위 sceneAudio 주석과 동일 계약) 배제 목적만 남긴다.
        if hasAudio, container.window != nil {
            let provider = SystemAudioSpectrumProvider()
            provider.onFrame = { [weak self] spec in
                // spec = 128(64L+64R, 채널별 FFT).
                if spec.count >= 128 {
                    // X-⑩: **소비단 스테이지를 태운다.** 프로듀서 출력은 절대 스케일이라 그대로 쓰면
                    // 레벨이 3.5~5배 모자란다 — 원본은 그룹 피크 정규화 + 1-pole 스무딩 + 슬루 제한을
                    // 거친 값을 셰이더 유니폼에 올린다(`AudioSpectrumProcessor` 주석 참조).
                    //
                    // dt 는 **오디오 콜백 간격**으로 잰다. 원본은 렌더 프레임 dt 를 쓰는데, 우리
                    // 콜백은 렌더 루프 밖(캡처 큐)이라 그 값을 들고 올 수 없다. 공급자가 ~30Hz 로
                    // 도는 것과 렌더가 보통 60Hz 인 것의 차이는 시상수를 2배 늘리는 정도이고,
                    // 헤드리스 캡처는 공급자를 아예 안 켜므로 골든 결정성에는 영향이 없다.
                    guard let renderer = self else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    let elapsed = now - (renderer.lastAudioFrameUptime ?? now - 1.0 / 30)
                    renderer.lastAudioFrameUptime = now
                    let out = renderer.audioProcessor.process(raw: spec,
                                                              dt: Float(min(max(elapsed, 1.0 / 240), 0.1)))
                    renderer.currentSpectrum = AudioSpectrum16(left: out.left16, right: out.right16)
                    // U/AA: 프로세서가 이미 MAX 로 접어 둔 32밴드를 그대로 싣는다(종전엔 64빈만
                    // 넘겨 호출부가 쌍평균으로 다시 접었다 — `0x1401128e0` 은 `maxss` 다).
                    renderer.setSpectrumBands(out)
                    renderer.sceneScript?.setAudio(left64: out.left64, right64: out.right64)
                } else {
                    guard let renderer = self else { return }
                    let bins = AudioSpectrum16.downsample16(spec)
                    renderer.currentSpectrum = AudioSpectrum16(left: bins, right: bins)
                    // U/AA: 이 가지는 종전에 32/64 유니폼을 **아예 안 채웠다**(g_AudioSpectrum32/64 가
                    // 0 으로 남았다). 축약은 여기서도 MAX 다 — `AudioSpectrum16.groupMax`.
                    let mono64 = AudioSpectrum16.groupMax(spec, binCount: 64)
                    let mono32 = AudioSpectrum16.groupMax(spec, binCount: 32)
                    renderer.setSpectrumBands(left64: mono64, right64: mono64,
                                              left32: mono32, right32: mono32)
                    renderer.sceneScript?.setAudio(left64: spec, right64: spec)  // 모노 폴백(64빈 미만은 JS 가 0 채움)
                }
            }
            provider.start()
            audioProvider = provider
        }
        // 마운트 상주 GPU 메모리(통합메모리이므로 phys_footprint 델타와 함께 리포트).
        if WapleProfiler.enabled { WapleProfiler.deviceAllocatedBytes = device.currentAllocatedSize }
    }


    /// command=copy 통과 파이프라인 캐시(빌드는 SceneRendererResources.passthroughEffectPipeline).
    /// X-⑧: 통과(copy) 파이프라인 캐시 — **포맷별**. 키는 MTLPixelFormat.rawValue.
    /// copy 패스의 타깃 fbo 포맷(r16f 등)에 맞춘 파이프라인이 필요해서 단일 캐시를 쪼갰다.
    var _passthroughPipelines: [UInt: MTLRenderPipelineState] = [:]


    // 효과 패스용 오프스크린 텍스처 풀: 매 프레임 신규 할당(30fps×효과수) 대신 크기별로 재사용.
    // 프레임 내에서는 checkout 을 단조 증가시켜 항상 distinct 텍스처를 보장(src/dst 충돌 방지).
    // 프레임 간 재사용은 비-heap tracked 텍스처라 Metal 자동 hazard tracking 이 동기화를 보장(무손상).
    var texturePool: [String: [MTLTexture]] = [:]
    /// 반사 스냅샷 전용 풀(밉체인 보유) — `texturePool` 과 분리한다.
    /// 이유는 `reflectionSnapshot(_:_:_:hdr:)` 주석 참조: 공용 풀에 밉을 켜면 그 풀을 쓰는
    /// 전 경로의 메모리가 1.33배가 되고 blit 정합 전제도 흔들린다.
    var reflectionSnapshotPool: [String: MTLTexture] = [:]
    var poolCheckout: [String: Int] = [:]

    // P⑦: colorBlendMode 레이어 전용 acc 스냅샷 캐시 — 풀에서 레이어마다 새 텍스처를 체크아웃하지 않고
    // 1장을 재사용한다(runBlendModeLayer 참조). 크기/포맷(acc 와 동형) 불일치 시에만 재할당.
    var blendModeSnapshotTexture: MTLTexture?


    /// 마우스 모니터 기동(mount 두 게이트 + resume 공용). 캡처 핀이 걸려 있으면 **아예 켜지 않는다** —
    /// `ParallaxController.start()` 가 즉시 emit() 해서 그 순간의 실제 커서를 pointerUV 로 밀어 넣기
    /// 때문이다(pause() 는 모니터를 멈출 뿐 이미 들어온 값을 되돌리지 않는다).
    /// 기동 지점이 셋이라 한 곳만 막으면 샌다 — 실제로 mount 의 두 번째 게이트(cursorMove/호버 씬)로
    /// 새고 있었다. 근거: spec/golden/nondeterminism.json → oracle.nondet.rootCause.
    func startPointerMonitor() {
        if let pinned = SceneRenderer.capturePointerUV {
            pointerUV = pinned
            pointerUVLast = pinned
            return
        }
        parallax.onOffset = { [weak self] off in self?.updateParallax(off) }
        parallax.start()
    }

    func updateParallax(_ off: CGPoint) {
        // 이중 안전망: 핀이 걸린 상태에서 어떤 경로로든 라이브 오프셋이 들어오면 무시한다.
        if let pinned = SceneRenderer.capturePointerUV {
            pointerUV = pinned
            pointerUVLast = pinned
            return
        }
        pointerUV = SceneRenderer.pointerUV(fromNormalized: off)
        if parallaxEnabled {
            let s = parallaxAmount * parallaxMouseInfluence * maxShift
            targetCameraOffset = SIMD2<Float>(Float(off.x) * s, Float(off.y) * s)
            // delay<=0 = 즉시(기존 동작 무회귀). delay>0 = draw() 가 프레임 dt 로 target 에 지수 수렴.
            if parallaxDelay <= 0 { cameraOffset = targetCameraOffset }
        }
        // cursorMove 훅 배달 — 30Hz 스로틀(웹 전달과 동일 규약, JS 평가 비용 절제).
        if hasCursorMoveHook {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastCursorMoveAt >= 1.0 / 30, let p = pointerSceneCoords() {
                lastCursorMoveAt = now
                dispatchPointerEvent(hook: "cursorMove", x: p.x, y: p.y)
            }
        }
        // cursorEnter/Leave: 경계 교차 시에만 발송(스로틀 불요 — 전이는 드물고 히트테스트는 저비용).
        if !hoverTargets.isEmpty { updateHover(at: pointerSceneCoords()) }
        mtkView?.needsDisplay = true
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

    /// 가림 draw-게이트 전이 처리(F289/F290) — draw() 가 매 프레임(가림 여부 재계산 후) 호출한다.
    /// 가림에 '막 진입'한 프레임에만 시작 시각을 기록하고 오디오를 정지한다(매 프레임 반복 호출 방지).
    /// 가림이 '막 해제'된 프레임엔 그 지속시간만큼 startTime 을 앞으로 보정해(resume() 의 pausedAt
    /// 보정과 동형 공식) time(=nowT−startTime) 이 가림 구간을 건너뛰지 않게 하고, 오디오를 재기동한다.
    /// stopAudio/startAudioIfNeeded 를 주입해 실제 SystemAudioSpectrumProvider(Metal/권한 필요) 없이도
    /// 전이 로직만 단위 테스트할 수 있게 한다.
    func handleOcclusionGate(
        occluded: Bool,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        stopAudio: () -> Void,
        startAudioIfNeeded: () -> Void
    ) {
        // F534(F-8): 명시 정지(scenePausedAt) 중엔 가림 전이를 처리하지 않는다 — pause() 가 정지 시작
        // 시각을 이미 소유(가림 추적도 이어받음)하고 resume() 이 전체 정지 구간을 단일 보정하므로, 여기서
        // 보정하면 겹친 만큼 씬 시간이 역행하고 startAudioIfNeeded 가 정지 중 캡처를 재기동한다.
        guard scenePausedAt == nil else { return }
        if occluded {
            guard drawGateOccludedSince == nil else { return }   // 이미 가림 추적 중 — 매 프레임 재발화 방지
            drawGateOccludedSince = now
            stopAudio()
        } else if let since = drawGateOccludedSince {
            startTime += max(0, now - since)
            drawGateOccludedSince = nil
            startAudioIfNeeded()
        }
    }

    /// F812: 가림 게이트의 오디오 정지/재기동을 씬 사운드(sceneAudio)까지 대칭화 — 종전엔 스펙트럼
    /// 캡처(audioProvider)만 정지해 가려진 동안 씬 사운드가 계속 재생되는 비대칭이었다. pause()/resume()
    /// 명시 경로(:1604/:1634)와 정합(SceneAudioPlayer.pause/resume 은 멱등 — 명시 정지와 겹쳐도 안전).
    /// 감사 V06: 비디오 레이어도 대칭 정지/재개 — 씬 클록은 가림 구간만큼 동결(F290)하는데 AVPlayer 만
    /// 실시간 진행하면 해제 시 씬 시간과 desync 된다. 헤드리스는 player=nil 이라 pause/resume 무영향
    /// (captureFrames 경로 불변). draw() 의 게이트 클로저가 위임하는 실제 배선(단위 테스트 대상).
    func occlusionStopAudio() {
        audioProvider?.stop()
        sceneAudio?.pause()
        for case let v? in layers.map(\.video) { v.pause() }
    }
    func occlusionStartAudioIfNeeded() {
        if hasAudio { audioProvider?.start() }
        sceneAudio?.resume()
        for case let v? in layers.map(\.video) { v.resume() }
    }

    /// F178(E1-③): idx 가 자식/손자(비루트, particleSystems[idx].childOf != nil)면 childOf 체인을
    /// 루트까지 거슬러 올라가 링크 경로(root→leaf 순)를 모은다. childOf 는 항상 "직계" 부모의 GPU
    /// 배열 인덱스만 담으므로(트리 구조 그대로 buildParticles 가 배선), 중간 자식의 sim 은 더미(step
    /// 미호출)라 경로 전체를 루트의 실제 스텝된 sim 에 물어야 한다(ParticleSimulator.descendantDisplay).
    /// 루트면 nil(호출자는 자기 sim.step 을 직접 쓴다 — 상태 변이는 루트 전용).
    func particleDescendantPath(from idx: Int) -> (root: Int, path: [Int])? {
        guard let firstC = particleSystems[idx].childOf else { return nil }
        var path = [firstC.link]
        var cur = firstC.parent
        while let cc = particleSystems[cur].childOf {
            path.insert(cc.link, at: 0)
            cur = cc.parent
        }
        return (root: cur, path: path)
    }

    /// E1(⑥): draw() 자원 실패 조기 return 경로의 진단 로그 — 원인별 1회만(60fps 루프에서 매프레임
    /// 재실패해도 로그 폭주 방지). 종전엔 이 경로들이 전부 조용히 프레임을 스킵해 "화면이 멈췄다/비었다"
    /// 증상의 원인 특정이 불가능했다.
    var loggedDrawFailureKeys: Set<String> = []
    func logDrawFailureOnce(_ key: String, _ message: String) {
        guard !loggedDrawFailureKeys.contains(key) else { return }
        loggedDrawFailureKeys.insert(key)
        WapleLog.warn("[Waple] draw() \(message)")
    }

    public func draw(in view: MTKView) {
        // F4: isGeometryFlipped 멱등 재확인 — WapleMTKView.viewDidMoveToWindow 가 놓칠 수 있는 경로
        // (예: 창 자체는 그대로인데 AppKit 이 백킹 프로퍼티만 재동기화하는 경우) 대비 매 프레임 방어.
        // 값이 이미 일치하면 대입을 건너뛰어(불일치 시에만 재대입) 매 프레임 비용을 최소화한다.
        let wantFlip = SceneLivePresentationFix.needsDesktopFlipY
        if view.layer?.isGeometryFlipped != wantFlip {
            view.layer?.isGeometryFlipped = wantFlip
        }
        // 가림 시 애니메이션 정지(배터리) + 오디오 캡처 중지(F289) + 클록 동결(F290).
        // drawable 획득 전에 검사해 drawable 낭비/stall 방지.
        let animGated = hasEffects || hasParticles || hasScriptedText || hasAnimations || has3DScripts
            || hasVideoLayer || cameraZoomAnim != nil || cameraShakeEnabled
        let occluded = animGated && view.window?.occlusionState.contains(.visible) == false
        handleOcclusionGate(occluded: occluded,
                            stopAudio: { [weak self] in self?.occlusionStopAudio() },
                            startAudioIfNeeded: { [weak self] in self?.occlusionStartAudioIfNeeded() })
        if occluded { return }
        guard let device, let queue, pipeline != nil,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else {
            logDrawFailureOnce("resources", "자원 확보 실패(device/queue/pipeline/drawable/commandBuffer 중 하나) — 프레임 스킵")
            return
        }
        // 비디오 레이어 라이브 재생 지연 기동: 첫 draw 도달 = 라이브 컨텍스트 확정(captureFrames 는 draw 를
        // 타지 않음 → 헤드리스 결정적 경로 유지). startLive 는 멱등이라 플래그로 매 프레임 순회만 회피.
        if hasVideoLayer, !videoLayersLive {
            for case let v? in layers.map(\.video) { v.startLive(device: device) }
            videoLayersLive = true
        }
        // 일시정지 중 재드로(호버/리사이즈/이벤트 needsDisplay)는 정지 시점 프레임을 재렌더(시간 동결 —
        // 미래 시간 렌더 후 resume 되감김 점프 방지).
        let nowT = scenePausedAt ?? CFAbsoluteTimeGetCurrent()
        let time = Float(nowT - startTime)
        let dt = SceneRenderer.frameDelta(nowT: nowT, lastFrameTime: lastFrameTime, isPaused: scenePausedAt != nil)
        lastFrameTime = nowT
        frameDT = dt  // g_Frametime(효과 유니폼) — 이번 프레임 전 패스 공용
        // g_PointerPositionLast: 이번 프레임 인코딩이 쓴 포인터를 함수 종료 시 다음 프레임의 '직전'으로 이월
        // (이후의 인코딩 실패 조기 return 포함. 이 지점 앞 가드 return(가림 등)은 프레임 자체가 없어 미이월 —
        // 히스토리는 '마지막으로 그린 프레임'의 포인터를 유지).
        // 프레임 꼬리 2종은 실물 `0x140181615`–`0x14018169e` 와 같은 자리다:
        // ① g_PointerPositionLast 이월 ② g_PointerState 의 "이미 소비했다" 비트(bit1) 갱신 —
        //    `if (s & 1) s |= 2; else s &= ~2;` 이것이 `.z` 를 한 프레임짜리 임펄스로 만든다.
        defer { pointerUVLast = pointerUV; pointerButton.endFrame() }

        // 애니메이션 이벤트 마커(라이브 재생 전용): 일시정지 중엔 발화 금지 —
        // pause() 후에도 needsDisplay 재드로(호버/리사이즈)가 여길 지나므로 명시 가드.
        if scenePausedAt == nil { tickAnimationEvents(time: time) }

        // 시차 지연 스무딩(WE cameraparallaxdelay): cameraOffset 를 target 으로 프레임 dt 기반 지수 수렴.
        // 온디맨드(비애니) 씬은 마우스 정지 후에도 정착 전까지 프레임을 스스로 요청(안 하면 lerp 중간 정지).
        if parallaxEnabled, parallaxDelay > 0 {
            cameraOffset = ParallaxController.smoothed(current: cameraOffset, target: targetCameraOffset,
                                                       dt: dt, delay: parallaxDelay)
            if !shouldAnimate {
                let d = targetCameraOffset - cameraOffset
                if d.x * d.x + d.y * d.y > 1e-10 { view.needsDisplay = true }
            }
        }

        // 3D 씬: 메시 + 빌보드 패스(뎁스, per-frame 스크립트) → scene-global finalizer.
        if is3D {
            beginFramePool()
            frameShakeOffset = shakeOffset(at: time)  // camerashake 3D 전역 지터(encode3D 가 viewProj 에 좌승). 비활성=.zero → 항등.
            guard let acc = pooledOffscreen(drawable.texture.width, drawable.texture.height, device, bgra: true),
                  encode3D(into: acc, cb: cb, device: device, time: time, particleDelta: dt) else {
                logDrawFailureOnce("3d-encode", "3D 오프스크린 확보 또는 encode3D 실패 — 프레임 스킵")
                cb.commit(); return
            }
            pushLiveSceneLayers()  // F811(S-35): 3D 빌보드 라이브 채널 소비(2D :1448 과 동일 — JS thisScene.layers 갱신)
            guard finalizeScene(
                source: acc,
                destination: drawable.texture,
                commandBuffer: cb,
                device: device) else {
                logDrawFailureOnce("3d-finalize", "3D finalizeScene 실패 — 프레임 스킵")
                cb.commit()
                return
            }
            cb.present(drawable)
            cb.commit()
            return
        }

        refreshScriptedTexts(device: device, time: time)  // 매 프레임 update() 재평가(F724 — 변경 시에만 재래스터)
        if ortho3DHybrid { evaluate3DScripts(time: time) }  // F721: ortho 3D 메시/노드 스크립트(encode3D 와 동일 1프레임 1회)
        sceneAudio?.tick(time: time)  // F214: volume 프로퍼티 스크립트 per-frame 재평가(헤드리스는 sceneAudio nil → no-op)
        // 효과 있는 레이어는 오프스크린 베이스→효과 패스 후 결과 텍스처로 교체.
        let displayTextures = buildDisplayTextures(device: device, time: time, cb: cb)
        let textTextures = buildTextDisplayTextures(device: device, time: time, cb: cb)  // F741(S-13)

        var camOffset = cameraOffset
        // 종횡비 보정 — FitMode 설정에 따라(클릭 역매핑과 동일 공식 = sceneCoords 정합 보장).
        let ds = view.drawableSize
        let viewAspect = Float(ds.width / max(1, ds.height))
        var aspectScale = SceneRenderer.aspectScale(projAspect: projAspect, viewAspect: viewAspect,
                                                    fitMode: SceneRenderSettings.fitMode)
        // camera 의사-오브젝트 zoom: 뷰 스케일(NDC 중심 기준 — 실효 카메라 origin 전수 중립과 일치).
        // 중립(1)/비정상(≤0)은 곱 자체를 스킵 → 카메라 없는 씬의 aspectScale 비트 불변(무회귀 가드).
        let camZoomRaw = cameraZoom(at: time)
        let camZoom = camZoomRaw > 0 ? camZoomRaw : 1
        if camZoom != 1 { aspectScale *= camZoom }
        // F744(S-18): general.zoom 씬 전역 프레이밍 — 침침 줌과 동일 채널(aspectScale 후단곱).
        // 중립(1)/비정상(≤0)은 곱 스킵 → 침침 없는 씬 비트 불변(무회귀 가드는 침침 줌과 동형).
        let sceneZoomEff = sceneZoom > 0 ? sceneZoom : 1
        if sceneZoomEff != 1 { aspectScale *= sceneZoomEff }
        currentCameraZoom = camZoom * sceneZoomEff   // 클릭 역매핑(sceneCoords) 정합 — 합산 줌
        frameShakeOffset = shakeOffset(at: time)  // camerashake 전역 지터(비활성 = .zero → 셰이더 +0 = 비트동일)
        frameShakeOffset += SceneRenderer.cameraOriginPanOffset(originXY: cameraOrigin(at: time), projW: projW, projH: projH)  // camera origin.xy 팬(중립/스크립트/정적 = .zero 데드존 → 비트동일)
        // 누적(acc) 합성: 컴포지션(_rt_) 레이어가 "그 시점까지의 화면"을 샘플할 수 있도록
        // 오프스크린에 합성 후 마지막에 drawable 로 blit(뷰는 mount 에서 framebufferOnly=false).
        // clearenabled=false 면 전용 누적 버퍼(trailAcc — 풀 체크아웃 순서 변동/미정의 초기내용 회피,
        // 프로퍼티 주석 참조)를 쓰고 클리어하지 않는다(프레임 누적 잔상 = 엔진 동작).
        let acc: MTLTexture
        if clearEnabled {
            guard let a = pooledOffscreen(drawable.texture.width, drawable.texture.height, device, bgra: true) else {
                logDrawFailureOnce("2d-acc", "2D 오프스크린(acc) 확보 실패 — 프레임 스킵")
                cb.commit(); return
            }
            acc = a
        } else {
            let dw = drawable.texture.width, dh = drawable.texture.height
            if trailAcc?.width != dw || trailAcc?.height != dh {
                trailAcc = hdrActive ? makeOffscreenHDR(dw, dh, device) : makeOffscreenBGRA(dw, dh, device)
                trailAccPrimed = false   // 신규 할당분은 내용 미정의 — 이번 프레임 1회 클리어로 정의된 시작
            }
            guard let a = trailAcc else {
                logDrawFailureOnce("2d-acc", "2D 오프스크린(acc) 확보 실패 — 프레임 스킵")
                cb.commit(); return
            }
            acc = a
        }
        let accPrime = !clearEnabled && !trailAccPrimed
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = acc
        rpd.colorAttachments[0].clearColor = clearColor
        rpd.colorAttachments[0].loadAction = (clearEnabled || accPrime) ? .clear : .load
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else {
            logDrawFailureOnce("2d-encoder", "렌더 커맨드 인코더 생성 실패 — 프레임 스킵")
            cb.commit(); return
        }
        if accPrime { trailAccPrimed = true }
        // 씬 오브젝트 순서대로 레이어·파티클·텍스트 인터리브(z-순서 — fg 레이어가 파티클을 가릴 수 있음).
        guard let finalEnc = encodeDrawPlan(startingWith: enc, acc: acc, cb: cb, device: device, time: time,
                                            displayTextures: displayTextures,
                                            textTextures: textTextures,
                                            particleSnapshot: { [self] idx in
                                                // 자식/손자는 루트 sim 캐시를 경로 기반으로 그린다(drawPlan 이
                                                // 루트를 먼저 스텝 — F178: 임의 깊이).
                                                if let (root, path) = particleDescendantPath(from: idx) {
                                                    return particleSystems[root].sim.descendantDisplay(path: path)
                                                }
                                                // 라이브 오디오반응: 신호 주입(무음이면 sim 이 스킵). 헤드리스 캡처는
                                                // captureFrames 의 별도 로컬 sims 라 이 경로 밖 → 무음 A/B 비트동일 유지.
                                                if hasAudio { particleSystems[idx].sim.currentAudio = currentSpectrum }
                                                // WE thisLayer.play/pause 방출 게이트 — 이 클로저는 encodeDrawPlan 이
                                                // particleScriptVisible(=평가) 직후에 부르므로 같은 프레임에 반영된다.
                                                particleSystems[idx].sim.emissionPaused = scriptParticleEmissionPaused[idx] ?? false
                                                return particleSystems[idx].sim.step(dt)
                                            },
                                            camOffset: &camOffset, aspectScale: &aspectScale) else {
            logDrawFailureOnce("2d-drawplan", "encodeDrawPlan 실패 — 프레임 스킵")
            cb.commit(); return
        }
        finalEnc.endEncoding()
        pushLiveSceneLayers()  // F743(S-35): JS thisScene.layers 라이브 갱신(다음 프레임 스크립트 독해용)
        guard finalizeScene(
            source: acc,
            destination: drawable.texture,
            commandBuffer: cb,
            device: device) else {
            logDrawFailureOnce("2d-finalize", "2D finalizeScene 실패 — 프레임 스킵")
            cb.commit()
            return
        }
        cb.present(drawable)
        cb.commit()
    }


    /// 합성 스펙트럼 주입(헤드리스 검증/테스트용). 라이브에선 provider 가 갱신.
    public func setSpectrum(_ spectrum: AudioSpectrum16) { currentSpectrum = spectrum }

    /// 프로세서 출력 그대로 밴드 유니폼에 싣는다 — **32밴드를 여기서 다시 접지 않는다.**
    ///
    /// U/AA(2026-08-21): 종전 `setSpectrum64(left:right:)` 는 64빈만 받아 32빈을 `(a+b)/2` 로
    /// **재계산**했는데 실물의 축약은 평균이 아니라 **MAX** 다:
    /// ```
    /// 0x1401128E0  f3 0f 5f 04 8b   maxss xmm0, [rbx+rcx*4]   ; spec32[j] = MAX(spec64[2j], spec64[2j+1])
    /// 0x140112B6F  f3 0f 5f 00      maxss xmm0, [rax]         ; spec16[j] = MAX(spec32[2j], spec32[2j+1])
    /// ```
    /// (32→16 은 `0x140112c94` 이후 완전 언롤 `maxss` 사슬이라 독립 증거가 하나 더 있다.)
    /// `AudioSpectrumProcessor.reduce` 는 이미 MAX 로 접은 `spec32` 를 들고 있는데 호출부가 그걸
    /// 버리고 있었던 것뿐이다 — 접근자가 생겼으니 잘라 쓰기만 한다.
    /// 좁은 피크(순음 저역)에서 평균은 MAX 의 **정확히 절반**이다.
    public func setSpectrumBands(_ out: AudioSpectrumProcessor.Output) {
        setSpectrumBands(left64: out.left64, right64: out.right64,
                         left32: out.left32, right32: out.right32)
    }

    /// 밴드 4배열 직접 주입(모노 폴백/테스트 seam). 길이는 잘라내고 0 으로 채운다.
    public func setSpectrumBands(left64 l64: [Float], right64 r64: [Float],
                                 left32 l32: [Float], right32 r32: [Float]) {
        func fit(_ v: [Float], _ n: Int) -> [Float] {
            Array(v.prefix(n)) + [Float](repeating: 0, count: max(0, n - v.count))
        }
        left64 = fit(l64, 64); right64 = fit(r64, 64)
        left32 = fit(l32, 32); right32 = fit(r32, 32)
    }

    /// 고해상(64빈/채널) 스펙트럼만 있는 주입 seam(테스트/헤드리스). 32빈은 여기서 파생하되
    /// **인접 2빈의 MAX** 다 — `0x1401128e0` 의 `maxss`. 종전 `(a+b)/2` 는 근거 없는 추측이었고,
    /// 좁은 피크에서 값이 절반으로 깎였다. 프로세서 출력이 있으면 `setSpectrumBands(_:)` 를 써라
    /// (그쪽은 파생조차 하지 않는다 — `reduce` 가 접어 둔 `spec32` 를 그대로 싣는다).
    public func setSpectrum64(left: [Float], right: [Float]) {
        let l64 = Array(left.prefix(64)) + [Float](repeating: 0, count: max(0, 64 - left.count))
        let r64 = Array(right.prefix(64)) + [Float](repeating: 0, count: max(0, 64 - right.count))
        setSpectrumBands(left64: l64, right64: r64,
                         left32: (0..<32).map { max(l64[$0 * 2], l64[$0 * 2 + 1]) },
                         right32: (0..<32).map { max(r64[$0 * 2], r64[$0 * 2 + 1]) })
    }

    /// 헤드리스 시각 검증: 레이어(베이스, 효과 제외) + 파티클을 오프스크린에 렌더해 각 time 의 PNG 를 저장.
    /// 시뮬은 t=0 에서 새로 시작해 1/30 스텝으로 각 time 까지 진행(재현 가능) — 2D 는 프레시 로컬 sims,
    /// 3D 는 라이브 sim 을 프레시로 리셋 후 복원(I1). 데스크탑 가림·라이브 재생 상태와 무관.
    @discardableResult
    public func captureFrames(width: Int, height: Int, times: [Float], toDir: URL) -> [URL] {
        // 비디오 레이어는 이제 일반 레이어로 합성된다(스왑 아님) — buildDisplayTextures 가 각 time 의
        // 비디오 프레임(헤드리스=AVAssetImageGenerator@scene-time, 결정적)을 형제 레이어와 함께 렌더한다.
        guard let device, let queue, pipeline != nil, let target = makeOffscreenBGRA(width, height, device) else { return [] }
        frameDT = 1.0 / 30.0  // g_Frametime: 캡처는 시뮬 스텝과 동일 고정 dt(결정적 — 라이브 dt 오염 차단)
        // 3D 씬: 메시 + 빌보드 패스(뎁스). per-frame 스크립트 평가로 각 time 마다 갱신(궤도/인트로 애니).
        if is3D {
            // 파티클 캡처는 라이브 sim 상태를 건드리지 않고 프레시(clock=0)에서 0→t 를 재현한다(감사 I1: 라이브
            // 렌더러 재사용 시 stale clock=T 로 t 가 아닌 현재 프레임이 잡히던 결함). struct 값복사로 저장·복원.
            let savedSims = particleSystems.map { $0.sim }
            let savedClock = particle3DClock
            for i in particleSystems.indices {
                particleSystems[i].sim = ParticleSimulator(def: particleSystems[i].def, seed: particleSystems[i].seed)
            }
            particle3DClock = 0
            defer {
                for i in particleSystems.indices { particleSystems[i].sim = savedSims[i] }
                particle3DClock = savedClock
            }
            var urls: [URL] = []
            for t in times.sorted() {
                guard let cb = queue.makeCommandBuffer() else { continue }
                beginFramePool()
                frameShakeOffset = shakeOffset(at: t)  // 라이브 draw 동형: A/B 캡처가 3D 지터 오프셋을 판독(비활성=.zero)
                // HDR bloom/LDR bloom 모두 readback(target)과 분리된 불변 소스 필요.
                // HDR 은 pooledOffscreen(bgra:true) 이 hdrActive 로 float(rgba16Float) 승격 → >1 보존해 골든 대조.
                // F531(F-5): HDR 씬에서 float 소스 할당 실패 시 target(bgra8) 폴백은 씬 파이프라인(accPixelFormat=
                // float) 포맷 불일치 + finalizer 의 hdrPost 자기샘플(src===dst)이 성립 — 그 프레임은 스킵한다
                // (라이브 draw :1279 와 동일 패턴). LDR bloom 은 target 폴백 안전(finalizer 의 src!==dst 가드).
                let source: MTLTexture
                if hdrActive {
                    guard let s = pooledOffscreen(width, height, device, bgra: true) else { continue }
                    source = s
                } else {
                    source = sceneWantsLDRBloom ? (pooledOffscreen(width, height, device, bgra: true) ?? target) : target
                }
                guard encode3D(into: source, cb: cb, device: device, time: t, particleDelta: nil) else { continue }
                pushLiveSceneLayers()  // F811(S-35): 라이브 draw 와 동일 — 캡처 프레임 간 스크립트 연속성(2D F743 과 동형)
                guard finalizeScene(
                    source: source,
                    destination: target,
                    commandBuffer: cb,
                    device: device) else {
                    cb.commit()
                    continue
                }
                cb.commit()
                cb.waitUntilCompleted()
                let url = toDir.appendingPathComponent("frame_t\(String(format: "%.1f", t)).png")
                if writeFramePNG(target, width: width, height: height, to: url) { urls.append(url) }
            }
            return urls
        }
        var sims = particleSystems.map { ParticleSimulator(def: $0.def, seed: $0.seed) }
        var simTime: Float = 0
        let dt: Float = 1.0 / 30.0
        var urls: [URL] = []
        var camOff = SIMD2<Float>(0, 0)
        let aspBase = SceneRenderer.aspectScale(projAspect: projAspect,
                                                viewAspect: Float(width) / Float(max(1, height)),
                                                fitMode: SceneRenderSettings.fitMode)
        // 자식 GPU 시스템의 로컬 sim 은 더미 — 부모 sim 이 자식을 구동하므로 웜업/스텝에서 제외.
        let rootIdxs = sims.indices.filter { particleSystems[$0].childOf == nil }
        // clearenabled=false: 캡처 시퀀스도 acc 를 프레임 간 누적(잔상 = 엔진 동작) — 단 첫 프레임은
        // 항상 클리어해 정의된 상태에서 시작(결정론 계약 — 누적 시작점이 미정의 내용이면 A/B 발산).
        var captureAccPrimed = false
        for t in times.sorted() {
            // 파티클 visible 스크립트를 **웜업 스텝 앞에서** t 로 1회 평가한다 — 그 스크립트가 같이
            // 남기는 WE thisLayer.play/pause 방출 게이트가 0→t 리플레이에 반영돼야 하기 때문이다.
            // (라이브 draw 는 encodeDrawPlan 이 시스템별로 "평가 → 스텝" 순이라 이미 같은 순서다.
            //  캡처는 웜업이 프레임 앞에 통째로 있어 여기서 순서를 맞춰준다.) 평가 결과는
            //  particleVisible 로 넘겨 encodeDrawPlan 이 재평가하지 않게 한다(프레임당 1회 계약).
            let capturedVisible = particleSystems.indices.map { particleScriptVisible($0, time: t) }
            for i in rootIdxs { sims[i].emissionPaused = scriptParticleEmissionPaused[i] ?? false }
            while simTime < t - 1e-4 { let s = min(dt, t - simTime); for i in rootIdxs { _ = sims[i].step(s) }; simTime += s }
            guard let cb = queue.makeCommandBuffer() else { continue }
            // 효과 패스(오디오 포함, currentSpectrum 사용) 적용한 표시 텍스처.
            let displayTextures = buildDisplayTextures(device: device, time: t, cb: cb)  // beginFramePool 포함
            let textTextures = buildTextDisplayTextures(device: device, time: t, cb: cb)  // F741(S-13)
            // HDR tone-map and LDR bloom both need an immutable scene source distinct from readback.
            // F531(F-5): HDR 씬의 float acc 할당 실패 시 target(bgra8) 폴백은 포맷 불일치/자기샘플 — 프레임 스킵.
            let acc: MTLTexture
            if hdrActive {
                guard let s = pooledOffscreen(width, height, device, bgra: true) else { continue }
                acc = s
            } else {
                acc = sceneWantsLDRBloom ? (pooledOffscreen(width, height, device, bgra: true) ?? target) : target
            }
            let accPrime = !clearEnabled && !captureAccPrimed
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = acc
            rpd.colorAttachments[0].loadAction = (clearEnabled || accPrime) ? .clear : .load
            rpd.colorAttachments[0].clearColor = clearColor
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            if accPrime { captureAccPrimed = true }
            // camera zoom: 라이브 draw 와 동일하게 t 에 평가(A/B 캡처가 줌 씬을 판독해야 한다).
            var asp = aspBase
            let capZoomRaw = cameraZoom(at: t)
            let capZoom = capZoomRaw > 0 ? capZoomRaw : 1
            if capZoom != 1 { asp *= capZoom }
            let capSceneZoom = sceneZoom > 0 ? sceneZoom : 1  // F744(S-18): 라이브 draw 와 동일 채널
            if capSceneZoom != 1 { asp *= capSceneZoom }
            frameShakeOffset = shakeOffset(at: t)  // 라이브 draw 와 동일: A/B 캡처가 t=6 지터 오프셋을 판독
            frameShakeOffset += SceneRenderer.cameraOriginPanOffset(originXY: cameraOrigin(at: t), projW: projW, projH: projH)  // origin 팬(t=6 정착 중립·정적/스크립트 = .zero → A/B 비트동일)
            if ortho3DHybrid { evaluate3DScripts(time: t) }  // F721: 라이브 draw 와 동일 — t 시점 노드 스크립트 평가
            // 라이브 draw 와 동일한 씬-순서 인터리브(encodeDrawPlan 공용 — 복제 루프 발산 방지).
            // 파티클은 로컬 sims 의 현재 스냅샷(step(0)) 사용.
            // (camOff=0 이라 parallaxDepth 는 무영향 — encodeLayer 공용 사용 가능.)
            // target 이 곧 누적(acc) — 컴포지션 레이어는 스냅샷 경유(runFrameBufferLayer).
            guard let finalEnc = encodeDrawPlan(startingWith: enc, acc: acc, cb: cb, device: device, time: t,
                                                displayTextures: displayTextures,
                                                textTextures: textTextures,
                                                particleSnapshot: { [self] idx in
                                                    // F178(E1-③): 임의 깊이 — 루트까지 경로를 모아 로컬 sims 배열에서 조회.
                                                    if let (root, path) = particleDescendantPath(from: idx) {
                                                        return sims[root].descendantDisplay(path: path)
                                                    }
                                                    return sims[idx].step(0)
                                                },
                                                particleVisible: { idx in
                                                    idx < capturedVisible.count ? capturedVisible[idx] : true
                                                },
                                                camOffset: &camOff, aspectScale: &asp) else { cb.commit(); continue }
            finalEnc.endEncoding()
            pushLiveSceneLayers()  // F743(S-35): 라이브 draw 와 동일 — 캡처 프레임 간 스크립트 연속성
            guard finalizeScene(
                source: acc,
                destination: target,
                commandBuffer: cb,
                device: device) else {
                cb.commit()
                continue
            }
            cb.commit()
            cb.waitUntilCompleted()
            let url = toDir.appendingPathComponent("frame_t\(String(format: "%.1f", t)).png")
            if writeFramePNG(target, width: width, height: height, to: url) { urls.append(url) }
        }
        return urls
    }


    public func pause() {
        for case let v? in layers.map(\.video) { v.pause() }
        sceneAudio?.pause()
        audioProvider?.stop()
        parallax.stop()
        // F289/F290: 가림 draw-게이트가 이미 이 순간을 추적 중이었다면(명시 정지 전부터 가려져 있던
        // 경우) 그 시작 시각을 채택 — resume() 의 단일 보정이 가림+명시정지 전체 구간을 커버하게 해
        // 이중 보정(가림 게이트 보정 + resume 보정이 같은 구간을 겹쳐 세는 것)을 막는다.
        if scenePausedAt == nil { scenePausedAt = drawGateOccludedSince ?? CFAbsoluteTimeGetCurrent() }
        drawGateOccludedSince = nil   // 가림 게이트 추적은 명시 정지가 이어받음
        mtkView?.isPaused = true
        mtkView?.enableSetNeedsDisplay = true
    }

    public func resume() {
        if let pausedAt = scenePausedAt {
            let now = CFAbsoluteTimeGetCurrent()
            startTime += now - pausedAt
            lastFrameTime = now
            scenePausedAt = nil
        }
        drawGateOccludedSince = nil   // 명시 재개가 가림 게이트 추적을 이어받음(여전히 가려져 있으면 다음 draw() 가 새로 시작)
        for case let v? in layers.map(\.video) { v.resume() }
        if shouldAnimate {
            mtkView?.isPaused = false
            mtkView?.enableSetNeedsDisplay = false
        } else {
            mtkView?.needsDisplay = true
        }
        if hasAudio { audioProvider?.start() }
        // mount 의 두 기동 게이트 합집합과 동일 — 호버/cursorMove 전용 씬도 pause 가 멈춘 마우스 모니터 재기동.
        if parallaxEnabled || hasEffects || hasCursorMoveHook || !hoverTargets.isEmpty { startPointerMonitor() }
        sceneAudio?.resume()
    }
    /// GPU 텍스처 풀·캐시 **일괄** 해제. teardown 과 mount 양쪽에서 부른다.
    ///
    /// 이 목록은 종전 teardown 의 긴 대입 나열 속에 손으로 유지돼 있었고, 그래서 같은 종류의 누락이
    /// 반복됐다 — 감사 V06·V07 태그가 각 라운드의 누락분(blendPipeline/composePipeline,
    /// nearest 변형, 효과 쿼드 버퍼 …)을 기록해 두었는데 이번 라운드에도 `reflectionSnapshotPool` 이
    /// 빠져 있었다(드로어블 크기 **mipmapped** 텍스처 — 4K rgba16Float 기준 엔트리당 ≈88MB,
    /// 게다가 mount 에서도 리셋되지 않아 플레이리스트 회전마다 그대로 쌓였다).
    /// 풀을 한 함수에 모아 호출 한 번으로 비운다 — 새 풀을 추가하는 사람은 여기만 보면 된다.
    func releasePooledGPUTextures() {
        texturePool.removeAll(); poolCheckout.removeAll()
        reflectionSnapshotPool.removeAll()
        blendModeSnapshotTexture = nil
        depthTextures.removeAll()
        trailAcc = nil; trailAccPrimed = false
    }

    public func teardown() {
        for case let v? in layers.map(\.video) { v.teardown() }   // layers = nil (하단) 전에 — 플레이어/텍스처캐시 정리
        hasVideoLayer = false; videoLayersLive = false
        sceneAudio?.teardown(); sceneAudio = nil
        parallax.stop()
        cameraOffset = .zero; targetCameraOffset = .zero  // 마운트 재사용 대비 시차 리셋(mount :656 과 일관)
        frameShakeOffset = .zero; cameraShakeEnabled = false  // 지터 리셋(mount 가 무조건 덮음 — 재사용 무회귀·stale 애니게이트 방지)
        parallaxEnabled = false  // teardown 후 resume(:1172 게이트)이 stale parallaxEnabled 로 monitor 를 재기동하지 않도록. mount(:836)이 무조건 덮으므로 재사용 무회귀.
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        mediaPoller?.stop(); mediaPoller = nil
        mediaArtworkTexture = nil; mediaPreviousArtworkTexture = nil  // F722: 마운트 재사용 시 이전 씬 아트워크 잔류 방지
        eventEngines = []
        hoverEngineLayers = []; hoverTargets = []
        pointerEngineOwners = []; pointerTargets = []; clickLatch.cancel()
        animEventTargets = []
        hasCursorMoveHook = false
        audioProvider?.stop(); audioProvider = nil; hasAudio = false; hasEffects = false
        mtkView?.removeFromSuperview()
        mtkView = nil; layers = []; particleSystems = []; hasParticles = false
        particle3DAdditive = nil; particle3DTranslucent = nil; particle3DClock = 0  // 3D 파티클 상태 리셋(마운트 재사용)
        particle3DFogAdditive = nil; particle3DFogTranslucent = nil   // M(④)
        forwardLit = false; litPipeline = nil; spriteFramePipeline = nil  // 라이트/스프라이트 추출 상태 리셋(마운트 간 스테일 방지)
        textLayers = []; hasScriptedText = false; hasAnimations = false
        sceneScript?.localStorageStore?.flush()  // F810: 마운트 해제 시 디바운스 대기분 즉시 기록(드래그 위치 유실 방지)
        sceneScript = nil; sceneScriptImageLayerCount = 0; sceneUserPropertiesJSON = "{}"; variantProperties = [:]
        sceneScriptBaseDescriptors = []; liveLayerStates.removeAll()  // F743(S-35): 마운트 재사용 stale 방지
        scriptVisible.removeAll()
        scriptTextVisible.removeAll()
        scriptParticleVisible.removeAll()
        // 형제 dict 와 같은 이유(마운트 재사용 stale 방지) + 이쪽은 더 고약하다: 스크립트 **없는**
        // 파티클은 이 항목을 다시 쓰지 않으므로, 남아 있으면 다음 씬의 같은 인덱스가 영구 무방출로 굳는다.
        scriptParticleEmissionPaused.removeAll()
        loggedDrawFailureKeys.removeAll()
        puppetCascadePhase.removeAll(); puppetCascadeLastTime.removeAll()  // C④: 마운트 재사용 stale 위상 방지
        additivePipeline = nil; translucentPipeline = nil; refractParticlePipeline = nil; _passthroughPipelines = [:]
        refractParticlePipelineAdditive = nil   // C4-(iii)
        additiveNearestPipeline = nil; translucentNearestPipeline = nil  // 감사 V07: nearest 변형 해제
        blendPipeline = nil; composePipeline = nil          // 감사 V06: 해제 누락분(마운트 반복 시 GPU 리소스 누적 방지)
        pipelineNearest = nil; layerAdditiveNearestPipeline = nil  // 감사 V07: nearest 변형 해제(동일 근거)
        blendNearestPipeline = nil; composeNearestPipeline = nil; litNearestPipeline = nil
        effectVertexBuffer = nil; effectQuadInterleaved = nil  // 감사 V06: 해제 누락분(효과 풀스크린 쿼드 버퍼)
        customLayerQuadInterleaved = nil  // F1(flip①): 커스텀 2D 레이어 전용 쿼드 버퍼
        camera3D = nil; is3D = false; has3DScripts = false; scene3DFog = Scene3DFog()  // F745
        ortho3DHybrid = false  // F721: 하이브리드 상태 리셋(마운트 재사용)
        scene3DLights = []; scene3DAmbient = .zero; scene3DSkylight = .zero
        scene3DLightConfig = nil   // 마운트 재사용 시 이전 씬 예산 잔류 방지(미저작 씬이 종전 폴백으로 복귀)
        nodes3D = []; meshRenderables = []; billboards = []; billboardDefs = []; cameraScripts = []
        text3DControllers = []
        eval3DOrder = []; draw3DOrder = []
        skinBuffersFrameMemo = nil   // 감사 V06: 스킨 버퍼 프레임 메모 해제(마운트 재사용 시 stale 본 버퍼 참조 방지)
        customSkinFrameMemo = nil    // H1: 커스텀 셰이더 CPU 프리스킨 메모도 같은 근거로 해제
        meshPipelineOver = nil; meshPipelineAdditive = nil
        meshPipelineSkin = nil; meshPipelineSkinAdditive = nil
        // 종전 누락(V06/V07 과 같은 종류의 반복): 메시 파이프라인 6종 + 레이어 굴절 파이프라인.
        meshPipelineNormal = nil; meshPipelineNormalAdditive = nil
        meshPipelineRefract = nil; meshPipelineRefractAdditive = nil
        meshPipelineReflect = nil; meshPipelineReflectAdditive = nil
        refractLayerPipeline = nil
        // 종전 누락: 패스 객체 2종(자체 파이프라인·중간 텍스처를 들고 있다 — hdrPost/ldrBloomPass 와 동급).
        volumetricLightPass = nil
        hdrBloomPyramidPass = nil
        shadowPipelineStaticOpaque = nil; shadowPipelineStaticCutout = nil
        shadowPipelineSkinOpaque = nil; shadowPipelineSkinCutout = nil
        pointShadowDepthState = nil; pointShadowAtlas = nil; pointShadowAtlasSlices = 0
        meshDepthStates.removeAll()
        // 풀·캐시는 releasePooledGPUTextures 하나로(texturePool/poolCheckout/reflectionSnapshotPool/
        // blendModeSnapshotTexture/depthTextures/trailAcc) — 함수 주석의 누락 재발 이력 참조.
        releasePooledGPUTextures()
        // S5-2: 위에서 layers/textLayers/meshRenderables/billboards 를 전부 비웠다 =
        // 살아 있는 UniqueFBOStore 가 하나도 없다. 장부도 같이 0 으로 돌린다(마운트 재사용 시
        // 스테일 누적으로 새 씬이 근거 없이 폴백되는 것을 막는다 — mount 는 teardown 을 먼저 부른다).
        uniqueFBOBytesInUse = 0
        sceneIsHDR = false
        hdrPost = nil
        sceneWantsLDRBloom = false
        ldrBloomParameters = .defaults
        ldrBloomPass = nil
        sceneWantsHDRBloom = false
        hdrBloomParameters = .defaults
        hdrBloomPass = nil
        premultipliedDisplayLayers.removeAll()   // DIRECTDRAW 체인 출력 플래그(프레임 상태) 해제
        pipeline = nil; layerAdditivePipeline = nil; layerPremultipliedPipeline = nil
        queue = nil; device = nil
    }
}
