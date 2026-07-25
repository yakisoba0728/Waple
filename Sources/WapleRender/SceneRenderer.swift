import AppKit
import MetalKit
import simd
import WapleCore


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
    struct GPULayer { let texture: MTLTexture; let vertexBuffer: MTLBuffer; let tint: SIMD4<Float>; let parallaxDepth: SIMD2<Float>; let effects: [EffectGPU]; let texWidth: Int; let texHeight: Int; let order: Int; let uid: Int /* doc.layers 인덱스 기반 고유 키(scriptVisible 용 — order 는 중복 가능) */; let blendAdditive: Bool /* material passes[0].blending == "additive" */; var isFrameBuffer: Bool = false; var def: SceneLayer? = nil /* 프로퍼티 애니메이션 있는 레이어만(per-frame 재평가용) */; var puppet: PuppetModel? = nil; var propScripts: [(key: String, engine: TextScriptEngine)] = []; var animLayerScripts: [(layerIndex: Int, key: String, engine: TextScriptEngine)] = [] /* animationlayers blend/visible/rate 바인딩 스크립트 — encodeLayer 가 per-frame 재평가해 캐스케이드에 반영. 훅 등록(buildAnimationEventTargets)도 이 인스턴스 재사용(중복 IIFE 방지) */; var materialScripts: [(key: String, engine: TextScriptEngine)] = [] /* material.constantshadervalue.scripted (roughness/metallic/speculartint) per-frame evaluation */; var initialVisible: Bool = true; var colorBlendMode: Int = 0 /* common_blending enum(0=normal) — !=0 이면 acc 스냅샷 블렌드 합성 */; var frames: [TexImage.TexFrame] = [] /* SPRITESHEET 콤보 레이어의 TEXS 프레임 — 비면 정지(무회귀). encodeLayer 가 씬 시간으로 프레임 UV 서브렉트 전진 */; var isLit: Bool = false /* 포워드 라이팅 대상(LIGHTING:1 + 씬 라이트). true 면 encodeLayer 가 litPipeline 사용 */; let pbrMaterial: PBRMaterialUniforms; var litRect: (SIMD4<Float>, SIMD4<Float>) = (.zero, .zero) /* [0]=(ox,oy,hw,hh) [1]=(cosA,sinA,z,0) — uv→월드 재구성용. 애니 레이어는 encodeLayer 가 per-frame 재계산 */; var video: SceneVideoLayer? = nil /* 비디오-텍스처 레이어면 프레임 공급자(그 외 nil) — buildDisplayTextures 가 프레임별 비디오 텍스처를 이 레이어에 공급 */; var attach: PuppetAttach? = nil /* attachment(이름 본-슬롯 부착) — 부모 퍼펫 부착점 프레임을 per-frame 씬 델타로 합성 */; var mediaArtwork: MediaArtworkKind = .none /* F722: 시스템 미디어 아트워크 요청 레이어 — buildDisplayTextures 가 base 교체(미수신 시 정적 placeholder 유지, 무회귀) */; var noInterp: Bool = false /* 감사 V07: 베이스 텍스처 NoInterpolation(TexImage flags bit0) — 무효과 레이어는 encodeLayer 가 nearest 변형 파이프라인으로 드로우 */; let scratchQuad = DynamicVertexBuffer() /* 애니 쿼드 per-frame 정점 재사용(스프라이트 UV 도 공용) */; let scratchSkin = DynamicVertexBuffer() /* 퍼펫 스킨 per-frame 정점 재사용 */; var customShader: CustomLayerShader? = nil /* H1: 커스텀 머티리얼 셰이더 — nil = QuadShaders 경로 */ }
    var hasAnimations = false
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
        let scratch = DynamicVertexBuffer()  // per-frame 파티클 정점 재사용
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
    /// 텍스트 visible 스크립트의 최근 평가값(GPUText.uid → 표시 여부, F219). scriptVisible 과 별개
    /// 인덱스 공간(레이어/텍스트는 서로 다른 배열이라 uid 가 겹칠 수 있음).
    var scriptTextVisible: [Int: Bool] = [:]

    /// 프로퍼티 스크립트 엔진 생성: 씬 공유 컨텍스트 우선(IIFE 격리), 컨텍스트 부재 시 단독 폴백.
    /// 이벤트 훅(cursorClick/media*Changed)을 export 한 엔진은 배달 대상으로 등록.
    /// F743(S-34): currentLayerIndex = thisScene.layers 디스크립터 인덱스(doc.layers+doc.texts 순서) —
    /// thisLayer 를 스크립트 소유 오브젝트 자체로 직결(중복명/묘명 오바인딩 해소). nil = 종전 이름 조회.
    func makeScriptEngine(_ src: String, layerName: String? = nil, currentLayerIndex: Int? = nil,
                          scriptPropsJSON: String? = nil) -> TextScriptEngine? {
        // 오디오 소비 스크립트 게이팅: 참조가 보이면 hasAudio 승격 → mount 말미의 provider 기동
        // (기존엔 셰이더 오디오 효과만 켰다). 모든 스크립트 로드는 mount 의 기동 검사보다 앞선다.
        if !hasAudio, Self.scriptWantsAudio(src) { hasAudio = true }
        let engine = sceneScript.map { TextScriptEngine(script: src, scene: $0, currentLayerName: layerName,
                                                        currentLayerIndex: currentLayerIndex,
                                                        scriptPropsJSON: scriptPropsJSON) }
            ?? TextScriptEngine(script: src, scriptPropsJSON: scriptPropsJSON)
        guard let engine else { return nil }

        // Constructor evaluation is complete here. Every engine gets apply exactly once; only init-only
        // engines initialize now. Update-bearing engines retain init(currentValue) in evaluate*.
        engine.applyUserProperties(sceneUserPropertiesJSON)
        if !engine.hasUpdate { engine.callInitIfNeeded() }

        if !engine.hookNames.isEmpty {
            eventEngines.append(engine)
            // cursorEnter/Leave 는 엔진이 바인드 레이어를 히트테스트(WE 규약 — 스크립트는 반응만).
            // 레이어명을 기억했다가 mount 말미에 AABB 로 해석(buildHoverTargets).
            if let layerName,
               !engine.hookNames.isDisjoint(with: ["cursorEnter", "cursorLeave"]) {
                hoverEngineLayers.append((engine, layerName))
            }
        }
        return engine
    }

    /// 스크립트 소스의 오디오 API 참조 스캔(문자열 contains — mount 시 스크립트당 1회).
    static func scriptWantsAudio(_ src: String) -> Bool {
        src.contains("engine.audio") || src.contains("audioBuffer")
            || src.contains("registerAudioBuffers") || src.contains("g_AudioSpectrum")
    }

    static func sceneScriptLayers(from doc: SceneDocument) -> [SceneScriptLayerDescriptor] {
        let imageLayers = doc.layers.map { layer in
            SceneScriptLayerDescriptor(
                name: layer.name,
                visible: layer.initialVisible,
                alpha: layer.alpha,
                origin: SIMD3<Float>(layer.origin.x, layer.origin.y, layer.originZ),
                scale: SIMD3<Float>(layer.scale.x, layer.scale.y, 1),
                angles: SIMD3<Float>(0, 0, layer.angleZ),
                size: SIMD2<Float>(layer.size.x, layer.size.y),
                solid: layer.textureEntryName.isEmpty,
                // F743(S-36/S-33): JS getParent()/getAnimationLayerCount() 실값 배선(파스 필드 소비).
                id: layer.id, parentId: layer.parent,
                animationLayerCount: layer.animationLayers.count
            )
        }
        let textLayers = doc.texts.map { text in
            SceneScriptLayerDescriptor(
                name: text.name,
                // F537(F-68): 이미지 레이어(:138)와 동일하게 초기 가시성 존중 — visible 스크립트 바인딩된
                // 정적 비가시 텍스트의 최초 스크립트 판독(getLayer(name).visible)이 부정확하던 것을 수정.
                visible: text.initialVisible,
                alpha: text.alpha,
                origin: SIMD3<Float>(text.origin.x, text.origin.y, 0),
                scale: SIMD3<Float>(text.scale.x, text.scale.y, 1),
                size: SIMD2<Float>(0, 0),
                text: text.text
            )
        }
        return imageLayers + textLayers
    }

    /// F535(F-50): 이 창이 프라이머리(NSScreen.screens.first = 메뉴 바) 화면에 있는지. 헤드리스
    /// (window == nil)는 false — 기존 캡처/테스트의 사운드 스킵(결정성) 계약과 동일. 멀티모니터 동일 씬
    /// 사운드의 N중 재생(시차 에코)을 프라이머리 화면 1개로 디듑하는 데 쓴다.
    static func isPrimaryScreenWindow(_ window: NSWindow?) -> Bool {
        guard let screen = window?.screen, let primary = NSScreen.screens.first else { return false }
        return screen == primary
    }

    // ── 씬 이벤트(클릭/미디어) ───────────────────────────────────────────────
    /// 이벤트 훅을 export 한 스크립트 엔진들(mount 중 수집). 훅 이벤트는 전 엔진 브로드캐스트
    /// (WE 규약 — 스크립트가 worldPosition 으로 스스로 히트테스트한다: 실물 2902406982 드래그).
    var eventEngines: [TextScriptEngine] = []
    /// cursorEnter/Leave 훅을 export 한 (엔진, 바인드 레이어명) — mount 중 수집, buildHoverTargets 가 AABB 해석.
    var hoverEngineLayers: [(engine: TextScriptEngine, layerName: String)] = []
    /// 호버 히트테스트 타깃: 엔진 + 레이어 스크린 AABB(씬 픽셀) + 현재 내부 여부(경계 넘을 때만 발송).
    struct HoverTarget { let engine: TextScriptEngine; let bounds: CGRect; var inside: Bool }
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

    /// 포인터 이벤트 배달(씬 픽셀 좌표, 상단 원점 — WE worldPosition 규약).
    /// event 필드는 실물 역추출: worldPosition(Vec3 — .x/.subtract 체이닝), button(0=좌).
    func dispatchPointerEvent(hook: String, x: Float, y: Float) {
        // F743(S-31): input.cursorWorldPosition/cursorScreenPosition/cursorLeftDown 폴ling 실데이터화
        // (screen 좌표는 포인터 UV×프로젝션 픽셀 근사 — ponytail: WE screen 기준 실측 부재).
        sceneScript?.setCursorState(worldX: x, worldY: y,
                                    screenX: pointerUV.x * projW, screenY: pointerUV.y * projH,
                                    leftDown: pointerDown)
        dispatchSceneEvent(hook, eventJS: "({ worldPosition: new Vec3(\(x), \(y), 0), button: 0 })")
    }

    /// cursorClick 시뮬레이션(테스트/헤드리스 e2e 용).
    public func simulateCursorClick(x: Float, y: Float) {
        dispatchPointerEvent(hook: "cursorClick", x: x, y: y)
    }

    /// 포인터 버튼 상태 주입점(g_PointerState.z 로 전달 — 시뮬/헤드리스 e2e 용, pointerUV 위치 주입과 대칭).
    public func setPointerButtonDown(_ down: Bool) { pointerDown = down }

    // ── cursorEnter/cursorLeave (레이어 호버 — 코퍼스 47패키지) ────────────────────
    /// 레이어 스크린 AABB(씬 픽셀 y-down, pointerSceneCoords 와 동일 공간). origin=중심, 반너비=|size×scale|/2.
    /// 회전(angleZ)은 무시 — 축정렬 근사(호버 존은 대개 축정렬 UI). scale 은 mount 정적 스냅샷(퍼펫 합성 후 값).
    static func layerHitRect(origin: Vec2, size: Vec2, scale: Vec2) -> CGRect {
        let hw = abs(size.x * scale.x) * 0.5, hh = abs(size.y * scale.y) * 0.5
        return CGRect(x: Double(origin.x - hw), y: Double(origin.y - hh), width: Double(2 * hw), height: Double(2 * hh))
    }

    /// mount 말미: 수집한 (엔진, 레이어명) → 레이어 AABB 로 호버 타깃 구성(이름 매칭 레이어 없으면 드롭).
    func buildHoverTargets(doc: SceneDocument) {
        guard !hoverEngineLayers.isEmpty else { return }
        var rects: [String: CGRect] = [:]
        for l in doc.layers where !l.name.isEmpty {
            rects[l.name] = Self.layerHitRect(origin: l.origin, size: l.size, scale: l.scale)
        }
        hoverTargets = hoverEngineLayers.compactMap { pair in
            rects[pair.layerName].map { HoverTarget(engine: pair.engine, bounds: $0, inside: false) }
        }
    }

    /// 포인터가 바인드 레이어 경계를 넘을 때만 cursorEnter/Leave 발송(WE 규약 — 엔진이 히트테스트).
    /// p=nil(창 밖)이면 내부였던 타깃 전부 이탈. 상태 변화 없으면 no-op(프레임마다 폴링해도 저비용).
    func updateHover(at p: SIMD2<Float>?) {
        guard !hoverTargets.isEmpty else { return }
        var changed = false
        for i in hoverTargets.indices {
            let inside = p.map { hoverTargets[i].bounds.contains(CGPoint(x: Double($0.x), y: Double($0.y))) } ?? false
            guard inside != hoverTargets[i].inside else { continue }
            hoverTargets[i].inside = inside
            let pos = p ?? SIMD2<Float>(0, 0)
            hoverTargets[i].engine.callHook(inside ? "cursorEnter" : "cursorLeave",
                eventJS: "({ worldPosition: new Vec3(\(pos.x), \(pos.y), 0), button: 0 })")
            changed = true
        }
        if changed { mtkView?.needsDisplay = true }
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
                    ? eff.map { (PuppetPose.clipIndex(model: pm, name: $0.element.name, fallback: $0.offset), $0.element.rate) }
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
        pointerDown = isDown  // g_PointerState.z 라이브 배관(위치 무관 물리 버튼 상태) — 헤드리스는 모니터 미설치라 미도달.
        guard let p = pointerSceneCoords() else { return }
        if isDown {
            dispatchPointerEvent(hook: "cursorDown", x: p.x, y: p.y)
            dispatchPointerEvent(hook: "cursorClick", x: p.x, y: p.y)
        } else {
            dispatchPointerEvent(hook: "cursorUp", x: p.x, y: p.y)
        }
    }

    /// 미디어 소비 스크립트(media*Changed export)가 있을 때만 폴링 시작(웹과 같은 5초 규약).
    /// F722: $mediaThumbnail/$mediaPreviousThumbnail 요청 레이어가 있어도 시작(아트워크 텍스처 공급 필요).
    func startMediaPollingIfNeeded() {
        let mediaHooks: Set<String> = ["mediaPlaybackChanged", "mediaPropertiesChanged",
                                       "mediaThumbnailChanged", "mediaTimelineChanged", "mediaStatusChanged"]
        let wantsArtwork = layers.contains(where: { $0.mediaArtwork != .none })
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
    /// HDR 경로 실효 게이트(2D·3D 공통). 3D 씬도 acc/메시/파티클 파이프라인이 accPixelFormat(float)로
    /// 승격되므로(mesh3DPipeline/particle3DPipeline) HDRBloomPass 에 도달 — 유일 HDR 골든(3470948192=3D) 대조 가능.
    var hdrActive: Bool { sceneIsHDR }
    /// acc 를 타깃으로 하는 파이프라인(f_main/f_blend/f_lit/particle/text)의 컬러 어태치먼트 포맷.
    /// HDR 이면 float(>1 보존) — mount 에서 sceneIsHDR 확정 후 파이프라인 생성에 사용.
    var accPixelFormat: MTLPixelFormat { sceneIsHDR ? .rgba16Float : .bgra8Unorm }
    /// 씬당 라이트 유니폼(상수) — forwardLit=false(라이트 씬 아님)면 전 레이어 f_main(무회귀).
    var forwardLit = false
    var lightPositions = [SIMD4<Float>](repeating: .zero, count: 4)    // [4] xyz=world, w=exponent
    var lightColorRadius = [SIMD4<Float>](repeating: .zero, count: 4)  // [4] rgb=color×intensity, w=radius
    // F800(S-9): kind/axis/cone — f_lit 버퍼 6/7. ForwardUniforms(WapleCore) 팩 그대로.
    var lightAxisCone = [SIMD4<Float>](repeating: .zero, count: 4)     // [4] xyz=forward(blue축), w=cone outer cos
    var lightKindCone = [SIMD4<Float>](repeating: .zero, count: 4)     // [4] x=kind(0/1/2), y=cone inner cos
    var lightAmbient = SIMD4<Float>(0, 0, 0, 0)                        // xyz=flat ambient (genericimage4)
    var layers: [GPULayer] = []
    var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    var cameraOffset = SIMD2<Float>(0, 0)
    /// 마우스가 지정한 목표 시차 오프셋. cameraOffset 는 delay 시상수로 여기로 프레임마다 수렴(WE 스무딩).
    var targetCameraOffset = SIMD2<Float>(0, 0)
    var parallaxEnabled = false
    var parallaxAmount: Float = 1
    var parallaxMouseInfluence: Float = 1
    /// WE cameraparallaxdelay(초). 0 = 즉시. >0 = 프레임 dt 기반 지수 스무딩.
    var parallaxDelay: Float = 0
    let parallax = ParallaxController()
    /// WE 포인터 UV(0..1, 상단 원점). 마우스 미구동/헤드리스 = 중앙(0.5,0.5).
    var pointerUV = SIMD2<Float>(0.5, 0.5)
    /// 직전 draw 프레임의 포인터 UV(g_PointerPositionLast — cursorripple 이전 위치). draw 종료 시 이월.
    var pointerUVLast = SIMD2<Float>(0.5, 0.5)
    /// 포인터 좌버튼 다운 상태(g_PointerState.z — cursorripple/fluidsim 클릭 힘). 미주입/헤드리스 = false(무클릭).
    var pointerDown = false
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

    /// 뷰 좌표(AppKit 하단원점) → 씬 픽셀(WE 상단원점). aspectScale 역적용으로 fit 레터박스/
    /// fill 크롭 보정 — fit 레터박스 밖 클릭은 nil(대응하는 씬 좌표가 없음). (순수)
    static func sceneCoords(viewPoint: CGPoint, viewSize: CGSize, projW: Float, projH: Float,
                            fitMode: FitMode, zoom: Float = 1) -> SIMD2<Float>? {
        guard viewSize.width > 0, viewSize.height > 0, projW > 0, projH > 0, zoom > 0 else { return nil }
        let s = aspectScale(projAspect: projW / projH,
                            viewAspect: Float(viewSize.width / viewSize.height), fitMode: fitMode)
        // zoom = camera 의사-오브젝트 뷰 스케일(draw 의 aspectScale×zoom 과 동일 공식 역적용).
        let nx = Float(viewPoint.x / viewSize.width * 2 - 1) / (s.x * zoom)
        let ny = Float(viewPoint.y / viewSize.height * 2 - 1) / (s.y * zoom)
        guard abs(nx) <= 1, abs(ny) <= 1 else { return nil }
        return SIMD2((nx + 1) / 2 * projW, (1 - (ny + 1) / 2) * projH)
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
        return SIMD2<Float>(x, y) * (amplitude * SceneRenderer.shakeNDCScale)
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
    // 고해상 스펙트럼(오디오 바 시각화). provider 프레임(64L+64R)에서 유지, 32빈은 쌍평균 파생.
    var left64 = [Float](repeating: 0, count: 64)
    var right64 = [Float](repeating: 0, count: 64)
    var left32 = [Float](repeating: 0, count: 32)
    var right32 = [Float](repeating: 0, count: 32)
    var audioProvider: SystemAudioSpectrumProvider?
    var effectVertexBuffer: MTLBuffer?
    var effectQuadInterleaved: MTLBuffer?   // 변환 효과용 인터리브드 풀스크린 쿼드(pos.xyz + uv.xy)
    var particleSystems: [GPUParticleSystem] = []
    var hasParticles = false
    var assetBaseDir: URL?  // WE 공유 에셋 폴백 디렉터리(설정), 패키지에 없는 .tex 용

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

    /// 조건 변형 텍스처(TEXB0004, 예 tuniccolor) 선택용 유효 프로퍼티 값(기본값+유저/프리셋 오버라이드).
    /// mount 시 스냅샷 — 프로퍼티 변경은 reapply(=remount)로 반영(LibraryViewModel.setProperty→onApply).
    var variantProperties: [String: PropertyValue] = [:]
    /// SceneScript applyUserProperties payload. Computed once per mount and reused by every engine.
    var sceneUserPropertiesJSON = "{}"
    var additivePipeline: MTLRenderPipelineState?
    var translucentPipeline: MTLRenderPipelineState?
    var refractParticlePipeline: MTLRenderPipelineState?   // REFRACT 스프라이트(pf_refract, translucent)
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
    var scene3DAmbient = SIMD3<Float>(repeating: 0)
    var scene3DSkylight = SIMD3<Float>(repeating: 0)
    var nodes3D: [Node3D] = []                 // scene order(계층 합성 입력)
    var meshRenderables: [MeshRenderable] = []
    var billboards: [Billboard3D] = []
    /// billboards[i] 의 원본 SceneLayer(록스텝 — build3D 가 같은 지점에서 append).
    /// 이벤트 마커 타임라인(def.animations 의 options.events — 젤다 눈꺼풀 blink 등) 결속용.
    var billboardDefs: [SceneLayer] = []
    /// 3D 씬 text 오브젝트의 스크립트 컨트롤러(shared 사이드이펙트 전용 — 렌더 미배선).
    /// 실물 3470948192: text id=181 이 shared.vvv 를 세팅하고 Hollow Cylinder 스케일 스크립트가 소비
    /// (미실행 시 vvv 미정의 → 스케일 NaN → 워프 튜너 소실). 2D buildTexts 와 동일하게 엔진 로드(top-level
    /// + shared 통신)하되, 3D 텍스트의 스크린 오버레이 위치/크기 규약이 미확정이라 픽셀 렌더는 미배선.
    /// (last 는 evaluate(current:) 재평가 입력 — 시계 등 값 구동 스크립트의 이전 표시값).
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
    var meshPipelineOver: MTLRenderPipelineState?      // premultiplied over(normal/translucent)
    var meshPipelineAdditive: MTLRenderPipelineState?
    var meshPipelineSkin: MTLRenderPipelineState?      // GPU 스키닝(mv_skin) over
    var meshPipelineSkinAdditive: MTLRenderPipelineState?
    // 3D 파티클(원근 빌보드) — bgra8+depth32 타깃용(2D additivePipeline 은 acc 포맷이라 별도).
    var particle3DAdditive: MTLRenderPipelineState?
    var particle3DTranslucent: MTLRenderPipelineState?
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

    /// 디버그 env 플래그(`WAPLE_3D_*`).
    static func debugFlag(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment[name] == "1"
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
        guard let pkgURL = pkgURL(in: project.folderURL) else {
            NSLog("%@", "[Waple] scene mount: no scene.pkg/gifscene.pkg in \(project.folderURL.path)")
            throw RendererError.assetMissing
        }
        let data: Data
        do {
            data = try WapleProfiler.time("pkgRead") { try Data(contentsOf: pkgURL) }
        } catch {
            NSLog("%@", "[Waple] scene mount: cannot read \(pkgURL.path): \(error)")
            throw RendererError.assetMissing
        }
        let package: ScenePackage
        let doc: SceneDocument
        do {
            package = try WapleProfiler.time("pkgParse") { try ScenePackage.parse(data) }
            // 공유(base-assets) 리졸버: pkg 에 없는 util 모델/머티리얼 JSON(솔리드 레이어 등) 폴백.
            doc = try WapleProfiler.time("docParse") {
                try SceneDocument.parse(package: package, sharedAssetProbe: { name in
                    Self.sharedAssetProbe(name, root: BaseAssetsSettings.baseAssetsDirectory)
                }, onMissingRequiredAsset: { [weak self] in
                    self?.markMissingRequiredSharedAsset()
                }, userProps: UserPropertyStore.rawOverrides(
                    id: project.id,
                    presetOverrides: project.presetOverrides,
                    presetResourceRoot: project.presetFolderURL
                ))
            }
        } catch {
            NSLog("%@", "[Waple] scene mount: failed to parse \(pkgURL.path): \(error)")
            throw error
        }
        // 조건 변형 텍스처(TEXB0004, 예 tuniccolor) 선택용 유효 프로퍼티 스냅샷:
        // project.json 기본값 + 유저/프리셋 오버라이드(LibraryViewModel 유효값 계산과 동형).
        // 값 부재/미매치는 기본 image 로 폴백 → 무회귀. 변경은 reapply(remount)로 새 스냅샷.
        let baseProps = (try? WallpaperProperties.parse(folderURL: project.folderURL)) ?? []
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
        self.assetBaseDir = BaseAssetsSettings.baseAssetsDirectory

        // A2 HDR: 최종 클램프 파이프라인이 빌드돼야 sceneIsHDR 활성(실패 시 종전 LDR 폴백 = 무회귀).
        // 아래 파이프라인 생성보다 먼저 확정해야 accPixelFormat 이 float 로 잡힌다.
        if doc.hdr, let post = HDRPostPass(device: device, outputFormat: .bgra8Unorm) {
            self.sceneIsHDR = true
            self.hdrPost = post
        }
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
        if sceneWantsHDRBloom {
            hdrBloomPass = HDRBloomPass(device: device)
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
            camera3D = cam
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
                // REFRACT 시스템이 하나라도 있으면 굴절 파이프라인 빌드(스냅샷 재샘플). 없으면 미빌드.
                if particleSystems.contains(where: { $0.refract && $0.normalTexture != nil }) {
                    refractParticlePipeline = refractParticlePipelineBuild(device: device)
                }
            }
            textLayers = buildTexts(doc: doc, package: package, device: device)
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

        let view = MTKView(frame: container.bounds, device: device)
        view.autoresizingMask = [.width, .height]
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false  // 누적(acc) → drawable blit 대상이 되려면 필요(컴포지션 합성)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        // 라이브 데스크탑 프레젠트 상하 뒤집힘 보정(macOS 26+, 실기기 27 확인) — 캡처(readback)는
        // drawable 을 안 타 무영향, 클릭 역매핑도 물리 좌표 기반이라 무영향(근거: SceneLivePresentationFix 상단 주석).
        if SceneLivePresentationFix.needsDesktopFlipY {
            view.layer?.isGeometryFlipped = true
        }
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
        if parallaxEnabled || hasEffects {
            parallax.onOffset = { [weak self] off in self?.updateParallax(off) }
            parallax.start()
        }

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
        buildHoverTargets(doc: doc)   // cursorEnter/Leave 레이어 AABB 해석
        if hasCursorMoveHook || !hoverTargets.isEmpty {
            parallax.onOffset = { [weak self] off in self?.updateParallax(off) }
            parallax.start()  // 이미 켜져 있으면 no-op(내부 nil 가드)
        }
        startMediaPollingIfNeeded()
        // 오디오-반응 효과가 있으면 시스템 오디오 스펙트럼 캡처 시작(Screen Recording 권한 필요).
        if hasAudio {
            let provider = SystemAudioSpectrumProvider()
            provider.onFrame = { [weak self] spec in
                // spec = 128(64L+64R, 채널별 FFT) — 16빈도 채널 분리 다운샘플.
                if spec.count >= 128 {
                    let l = Array(spec[0..<64]), r = Array(spec[64..<128])
                    self?.currentSpectrum = AudioSpectrum16(left: AudioSpectrum16.downsample16(l),
                                                            right: AudioSpectrum16.downsample16(r))
                    self?.setSpectrum64(left: l, right: r)
                    self?.sceneScript?.setAudio(left64: l, right64: r)  // 씬 스크립트 engine.audio 실데이터
                } else {
                    let bins = AudioSpectrum16.downsample16(spec)
                    self?.currentSpectrum = AudioSpectrum16(left: bins, right: bins)
                    self?.sceneScript?.setAudio(left64: spec, right64: spec)  // 모노 폴백(64빈 미만은 JS 가 0 채움)
                }
            }
            provider.start()
            audioProvider = provider
        }
        // 마운트 상주 GPU 메모리(통합메모리이므로 phys_footprint 델타와 함께 리포트).
        if WapleProfiler.enabled { WapleProfiler.deviceAllocatedBytes = device.currentAllocatedSize }
    }


    /// command=copy 통과 파이프라인 캐시(빌드는 SceneRendererResources.passthroughEffectPipeline).
    var _passthroughPipeline: MTLRenderPipelineState?


    // 효과 패스용 오프스크린 텍스처 풀: 매 프레임 신규 할당(30fps×효과수) 대신 크기별로 재사용.
    // 프레임 내에서는 checkout 을 단조 증가시켜 항상 distinct 텍스처를 보장(src/dst 충돌 방지).
    // 프레임 간 재사용은 비-heap tracked 텍스처라 Metal 자동 hazard tracking 이 동기화를 보장(무손상).
    var texturePool: [String: [MTLTexture]] = [:]
    var poolCheckout: [String: Int] = [:]


    func updateParallax(_ off: CGPoint) {
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

    public func draw(in view: MTKView) {
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
              let cb = queue.makeCommandBuffer() else { return }
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
        defer { pointerUVLast = pointerUV }

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
                  encode3D(into: acc, cb: cb, device: device, time: time, particleDelta: dt) else { cb.commit(); return }
            pushLiveSceneLayers()  // F811(S-35): 3D 빌보드 라이브 채널 소비(2D :1448 과 동일 — JS thisScene.layers 갱신)
            guard finalizeScene(
                source: acc,
                destination: drawable.texture,
                commandBuffer: cb,
                device: device) else {
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
        guard let acc = pooledOffscreen(drawable.texture.width, drawable.texture.height, device, bgra: true) else { cb.commit(); return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = acc
        rpd.colorAttachments[0].clearColor = clearColor
        rpd.colorAttachments[0].loadAction = .clear
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { cb.commit(); return }
        // 씬 오브젝트 순서대로 레이어·파티클·텍스트 인터리브(z-순서 — fg 레이어가 파티클을 가릴 수 있음).
        guard let finalEnc = encodeDrawPlan(startingWith: enc, acc: acc, cb: cb, device: device, time: time,
                                            displayTextures: displayTextures,
                                            textTextures: textTextures,
                                            particleSnapshot: { [self] idx in
                                                // 자식은 부모 sim 캐시를 그린다(drawPlan 이 부모를 먼저 스텝).
                                                if let c = particleSystems[idx].childOf {
                                                    return particleSystems[c.parent].sim.childDisplay(c.link)
                                                }
                                                // 라이브 오디오반응: 신호 주입(무음이면 sim 이 스킵). 헤드리스 캡처는
                                                // captureFrames 의 별도 로컬 sims 라 이 경로 밖 → 무음 A/B 비트동일 유지.
                                                if hasAudio { particleSystems[idx].sim.currentAudio = currentSpectrum }
                                                return particleSystems[idx].sim.step(dt)
                                            },
                                            camOffset: &camOffset, aspectScale: &aspectScale) else { cb.commit(); return }
        finalEnc.endEncoding()
        pushLiveSceneLayers()  // F743(S-35): JS thisScene.layers 라이브 갱신(다음 프레임 스크립트 독해용)
        guard finalizeScene(
            source: acc,
            destination: drawable.texture,
            commandBuffer: cb,
            device: device) else {
            cb.commit()
            return
        }
        cb.present(drawable)
        cb.commit()
    }


    /// 합성 스펙트럼 주입(헤드리스 검증/테스트용). 라이브에선 provider 가 갱신.
    public func setSpectrum(_ spectrum: AudioSpectrum16) { currentSpectrum = spectrum }

    /// 고해상(64빈/채널) 스펙트럼 주입 — 32빈은 쌍평균 파생(오디오 바 효과용).
    public func setSpectrum64(left: [Float], right: [Float]) {
        left64 = Array(left.prefix(64)) + [Float](repeating: 0, count: max(0, 64 - left.count))
        right64 = Array(right.prefix(64)) + [Float](repeating: 0, count: max(0, 64 - right.count))
        left32 = (0..<32).map { (left64[$0 * 2] + left64[$0 * 2 + 1]) / 2 }
        right32 = (0..<32).map { (right64[$0 * 2] + right64[$0 * 2 + 1]) / 2 }
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
        for t in times.sorted() {
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
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = acc
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = clearColor
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { continue }
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
                                                    if let c = particleSystems[idx].childOf {
                                                        return sims[c.parent].childDisplay(c.link)
                                                    }
                                                    return sims[idx].step(0)
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
        if parallaxEnabled || hasEffects || hasCursorMoveHook || !hoverTargets.isEmpty { parallax.start() }
        sceneAudio?.resume()
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
        animEventTargets = []
        hasCursorMoveHook = false
        audioProvider?.stop(); audioProvider = nil; hasAudio = false; hasEffects = false
        mtkView?.removeFromSuperview()
        mtkView = nil; layers = []; particleSystems = []; hasParticles = false
        particle3DAdditive = nil; particle3DTranslucent = nil; particle3DClock = 0  // 3D 파티클 상태 리셋(마운트 재사용)
        forwardLit = false; litPipeline = nil; spriteFramePipeline = nil  // 라이트/스프라이트 추출 상태 리셋(마운트 간 스테일 방지)
        textLayers = []; hasScriptedText = false; hasAnimations = false
        sceneScript?.localStorageStore?.flush()  // F810: 마운트 해제 시 디바운스 대기분 즉시 기록(드래그 위치 유실 방지)
        sceneScript = nil; sceneScriptImageLayerCount = 0; sceneUserPropertiesJSON = "{}"; variantProperties = [:]
        sceneScriptBaseDescriptors = []; liveLayerStates.removeAll()  // F743(S-35): 마운트 재사용 stale 방지
        scriptVisible.removeAll()
        scriptTextVisible.removeAll()
        additivePipeline = nil; translucentPipeline = nil; refractParticlePipeline = nil; _passthroughPipeline = nil
        additiveNearestPipeline = nil; translucentNearestPipeline = nil  // 감사 V07: nearest 변형 해제
        blendPipeline = nil; composePipeline = nil          // 감사 V06: 해제 누락분(마운트 반복 시 GPU 리소스 누적 방지)
        pipelineNearest = nil; layerAdditiveNearestPipeline = nil  // 감사 V07: nearest 변형 해제(동일 근거)
        blendNearestPipeline = nil; composeNearestPipeline = nil; litNearestPipeline = nil
        effectVertexBuffer = nil; effectQuadInterleaved = nil  // 감사 V06: 해제 누락분(효과 풀스크린 쿼드 버퍼)
        camera3D = nil; is3D = false; has3DScripts = false; scene3DFog = Scene3DFog()  // F745
        ortho3DHybrid = false  // F721: 하이브리드 상태 리셋(마운트 재사용)
        scene3DLights = []; scene3DAmbient = .zero; scene3DSkylight = .zero
        nodes3D = []; meshRenderables = []; billboards = []; billboardDefs = []; cameraScripts = []
        text3DControllers = []
        eval3DOrder = []; draw3DOrder = []
        skinBuffersFrameMemo = nil   // 감사 V06: 스킨 버퍼 프레임 메모 해제(마운트 재사용 시 stale 본 버퍼 참조 방지)
        meshPipelineOver = nil; meshPipelineAdditive = nil
        meshPipelineSkin = nil; meshPipelineSkinAdditive = nil
        shadowPipelineStaticOpaque = nil; shadowPipelineStaticCutout = nil
        shadowPipelineSkinOpaque = nil; shadowPipelineSkinCutout = nil
        pointShadowDepthState = nil; pointShadowAtlas = nil; pointShadowAtlasSlices = 0
        meshDepthStates.removeAll(); depthTextures.removeAll()
        texturePool.removeAll(); poolCheckout.removeAll()
        sceneIsHDR = false
        hdrPost = nil
        sceneWantsLDRBloom = false
        ldrBloomParameters = .defaults
        ldrBloomPass = nil
        sceneWantsHDRBloom = false
        hdrBloomParameters = .defaults
        hdrBloomPass = nil
        pipeline = nil; layerAdditivePipeline = nil; queue = nil; device = nil
    }
}
