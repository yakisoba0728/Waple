import AppKit
import MetalKit
import simd
import WapleCore


public final class SceneRenderer: NSObject, WallpaperRenderer, MTKViewDelegate {
    struct GPULayer { let texture: MTLTexture; let vertexBuffer: MTLBuffer; let tint: SIMD4<Float>; let parallaxDepth: SIMD2<Float>; let effects: [EffectGPU]; let texWidth: Int; let texHeight: Int; let order: Int; let uid: Int /* doc.layers 인덱스 기반 고유 키(scriptVisible 용 — order 는 중복 가능) */; var isFrameBuffer: Bool = false; var def: SceneLayer? = nil /* 프로퍼티 애니메이션 있는 레이어만(per-frame 재평가용) */; var puppet: PuppetModel? = nil; var propScripts: [(key: String, engine: TextScriptEngine)] = []; var initialVisible: Bool = true; var colorBlendMode: Int = 0 /* common_blending enum(0=normal) — !=0 이면 acc 스냅샷 블렌드 합성 */; let scratchQuad = DynamicVertexBuffer() /* 애니 쿼드 per-frame 정점 재사용 */; let scratchSkin = DynamicVertexBuffer() /* 퍼펫 스킨 per-frame 정점 재사용 */ }
    var hasAnimations = false
    struct GPUParticleSystem {
        var sim: ParticleSimulator
        let def: ParticleSystemDef
        let seed: UInt64
        let texture: MTLTexture
        let blendAdditive: Bool
        let origin: SIMD2<Float>
        let scale: SIMD2<Float>
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
        let scratch = DynamicVertexBuffer()  // per-frame 파티클 정점 재사용
    }
    /// 텍스트 레이어(시계/날짜/곡정보): 흰 글리프 텍스처 + tint. 스크립트는 초당 재평가 → 변경 시 재래스터.
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
    }
    var textLayers: [GPUText] = []
    var hasScriptedText = false
    var lastTextRefreshSecond = 0

    /// 씬 공유 JSContext(mount 당 1개) — 모든 프로퍼티 스크립트가 `shared` 로 통신(주야 컨트롤러 등).
    var sceneScript: SceneScriptContext?
    /// visible 스크립트의 최근 평가값(레이어 고유 uid → 표시 여부). update(current) 에 이전 값을 전달.
    /// 키는 GPULayer.uid(doc.layers 인덱스) — order 는 씬에서 중복될 수 있어 키로 부적합(충돌).
    var scriptVisible: [Int: Bool] = [:]

    /// 프로퍼티 스크립트 엔진 생성: 씬 공유 컨텍스트 우선(IIFE 격리), 컨텍스트 부재 시 단독 폴백.
    /// 이벤트 훅(cursorClick/media*Changed)을 export 한 엔진은 배달 대상으로 등록.
    func makeScriptEngine(_ src: String, layerName: String? = nil) -> TextScriptEngine? {
        let engine = sceneScript.map { TextScriptEngine(script: src, scene: $0, currentLayerName: layerName) }
            ?? TextScriptEngine(script: src)
        if let e = engine, !e.hookNames.isEmpty { eventEngines.append(e) }
        return engine
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
                solid: layer.textureEntryName.isEmpty
            )
        }
        let textLayers = doc.texts.map { text in
            SceneScriptLayerDescriptor(
                name: text.name,
                visible: true,
                alpha: text.alpha,
                origin: SIMD3<Float>(text.origin.x, text.origin.y, 0),
                scale: SIMD3<Float>(text.scale.x, text.scale.y, 1),
                size: SIMD2<Float>(0, 0),
                text: text.text
            )
        }
        return imageLayers + textLayers
    }

    // ── 씬 이벤트(클릭/미디어) ───────────────────────────────────────────────
    /// 이벤트 훅을 export 한 스크립트 엔진들(mount 중 수집). 훅 이벤트는 전 엔진 브로드캐스트
    /// (WE 규약 — 스크립트가 worldPosition 으로 스스로 히트테스트한다: 실물 2902406982 드래그).
    var eventEngines: [TextScriptEngine] = []
    var clickMonitor: Any?
    var mediaPoller: MediaPoller?
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
        dispatchSceneEvent(hook, eventJS: "({ worldPosition: new Vec3(\(x), \(y), 0), button: 0 })")
    }

    /// cursorClick 시뮬레이션(테스트/헤드리스 e2e 용).
    public func simulateCursorClick(x: Float, y: Float) {
        dispatchPointerEvent(hook: "cursorClick", x: x, y: y)
    }

    /// 전역 leftMouseDown/Up 모니터(데스크탑 창은 ignoresMouseEvents=true — 클릭은 다른 앱으로 가고
    /// 전역 모니터가 관찰한다, ParallaxController 의 mouseMoved 와 동일 규약. 권한 불요).
    /// WE 규약: down 시 cursorDown+cursorClick(기존 e2e 검증 타이밍 유지), up 시 cursorUp.
    func startClickMonitorIfNeeded() {
        let hooks: Set<String> = ["cursorClick", "cursorDown", "cursorUp"]
        guard clickMonitor == nil,
              eventEngines.contains(where: { !$0.hookNames.isDisjoint(with: hooks) }) else { return }
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
                                         fitMode: SceneRenderSettings.fitMode)
    }

    func deliverGlobalMouse(isDown: Bool) {
        guard let p = pointerSceneCoords() else { return }
        if isDown {
            dispatchPointerEvent(hook: "cursorDown", x: p.x, y: p.y)
            dispatchPointerEvent(hook: "cursorClick", x: p.x, y: p.y)
        } else {
            dispatchPointerEvent(hook: "cursorUp", x: p.x, y: p.y)
        }
    }

    /// 미디어 소비 스크립트(media*Changed export)가 있을 때만 폴링 시작(웹과 같은 5초 규약).
    func startMediaPollingIfNeeded() {
        let mediaHooks: Set<String> = ["mediaPlaybackChanged", "mediaPropertiesChanged",
                                       "mediaThumbnailChanged", "mediaTimelineChanged", "mediaStatusChanged"]
        guard mediaPoller == nil,
              eventEngines.contains(where: { !$0.hookNames.isDisjoint(with: mediaHooks) }) else { return }
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
    struct DrawItem { enum Kind { case layer, particle, text }; let kind: Kind; let idx: Int }
    var drawPlan: [DrawItem] = []

    var videoRenderer: VideoRenderer?
    /// 씬 sound 레이어 재생기(라이브 mount 한정 — 헤드리스에선 미생성). pause/resume/teardown 에 연동.
    var sceneAudio: SceneAudioPlayer?
    var mtkView: MTKView?
    var device: MTLDevice?
    var queue: MTLCommandQueue?
    var pipeline: MTLRenderPipelineState?
    var blendPipeline: MTLRenderPipelineState?
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
    /// cursorMove 훅 보유 씬만 이동 이벤트 배달(마운트 시 캐시 — 매 마우스무브 스캔 회피).
    var hasCursorMoveHook = false
    var lastCursorMoveAt: CFAbsoluteTime = 0

    /// 정규화 오프셋(중심 0, 가장자리 ±1, AppKit y-up) → WE 포인터 UV(0..1, y-down). (순수)
    static func pointerUV(fromNormalized off: CGPoint) -> SIMD2<Float> {
        SIMD2(Float(off.x + 1) / 2, 1 - Float(off.y + 1) / 2)
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
                            fitMode: FitMode) -> SIMD2<Float>? {
        guard viewSize.width > 0, viewSize.height > 0, projW > 0, projH > 0 else { return nil }
        let s = aspectScale(projAspect: projW / projH,
                            viewAspect: Float(viewSize.width / viewSize.height), fitMode: fitMode)
        let nx = Float(viewPoint.x / viewSize.width * 2 - 1) / s.x
        let ny = Float(viewPoint.y / viewSize.height * 2 - 1) / s.y
        guard abs(nx) <= 1, abs(ny) <= 1 else { return nil }
        return SIMD2((nx + 1) / 2 * projW, (1 - (ny + 1) / 2) * projH)
    }
    let maxShift: Float = 0.1
    var projAspect: Float = 16.0 / 9.0
    var projW: Float = 1920
    var projH: Float = 1080
    var startTime = CFAbsoluteTimeGetCurrent()
    var lastFrameTime = CFAbsoluteTimeGetCurrent()
    var shouldAnimate = false
    var scenePausedAt: CFAbsoluteTime?
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
    /// 조건 변형 텍스처(TEXB0004, 예 tuniccolor) 선택용 유효 프로퍼티 값(기본값+유저/프리셋 오버라이드).
    /// mount 시 스냅샷 — 프로퍼티 변경은 reapply(=remount)로 반영(LibraryViewModel.setProperty→onApply).
    var variantProperties: [String: PropertyValue] = [:]
    var additivePipeline: MTLRenderPipelineState?
    var translucentPipeline: MTLRenderPipelineState?
    var fullscreenQuad: [SIMD2<Float>] = [SIMD2(-1,-1), SIMD2(1,-1), SIMD2(-1,1), SIMD2(1,1)]

    // ── 3D 씬(camera3D + .mdl 메시) 상태 ─────────────────────────────────────────

    var camera3D: SceneCamera3D?
    var is3D = false
    var has3DScripts = false
    var nodes3D: [Node3D] = []                 // scene order(계층 합성 입력)
    var meshRenderables: [MeshRenderable] = []
    var billboards: [Billboard3D] = []
    /// per-frame 스크립트 평가 순서(씬 order — 컨트롤러(Main)가 이를 읽는 스크립트보다 먼저 실행).
    /// (order, isBillboard, idx). 스크립트 없는 노드/빌보드는 제외.
    var eval3DOrder: [(order: Int, bb: Bool, idx: Int)] = []
    /// 그리기 순서(메시+빌보드 인터리브, order 오름차순). (order, isBillboard, idx).
    var draw3DOrder: [(order: Int, bb: Bool, idx: Int)] = []
    var meshPipelineOver: MTLRenderPipelineState?      // premultiplied over(normal/translucent)
    var meshPipelineAdditive: MTLRenderPipelineState?
    var meshPipelineSkin: MTLRenderPipelineState?      // GPU 스키닝(mv_skin) over
    var meshPipelineSkinAdditive: MTLRenderPipelineState?
    /// 카메라 프로퍼티 스크립트(eye/center/up/fov). per-frame 재평가로 카메라 애니.
    var cameraScripts: [Script3D] = []
    var meshDepthStates: [String: MTLDepthStencilState] = [:]  // "test-write" 키
    var depthTextures: [String: MTLTexture] = [:]     // 크기별 재사용(.depth32Float)

    /// 디버그 env 플래그: 신규 `WAPLE_3D_*` 표기 우선, 구 `WAPLE3D_*` 병행 인식(전환기 호환 — 추후 제거).
    static func debugFlag(_ names: String...) -> Bool {
        let env = ProcessInfo.processInfo.environment
        return names.contains { env[$0] == "1" }
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
        scenePausedAt = nil
        shouldAnimate = false
        guard let pkgURL = pkgURL(in: project.folderURL) else {
            NSLog("%@", "[Waple] scene mount: no scene.pkg/gifscene.pkg in \(project.folderURL.path)")
            throw RendererError.assetMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: pkgURL)
        } catch {
            NSLog("%@", "[Waple] scene mount: cannot read \(pkgURL.path): \(error)")
            throw RendererError.assetMissing
        }
        let package: ScenePackage
        let doc: SceneDocument
        do {
            package = try ScenePackage.parse(data)
            // 공유(base-assets) 리졸버: pkg 에 없는 util 모델/머티리얼 JSON(솔리드 레이어 등) 폴백.
            doc = try SceneDocument.parse(package: package, assets: { name in
                guard let base = BaseAssetsSettings.baseAssetsDirectory,
                      let url = WallpaperPathSecurity.containedFileURL(name, root: base) else { return nil }
                return try? Data(contentsOf: url)
            }, userProps: UserPropertyStore.rawOverrides(
                id: project.id,
                presetOverrides: project.presetOverrides,
                presetResourceRoot: project.presetFolderURL
            ))
        } catch {
            NSLog("%@", "[Waple] scene mount: failed to parse \(pkgURL.path): \(error)")
            throw error
        }
        // 조건 변형 텍스처(TEXB0004, 예 tuniccolor) 선택용 유효 프로퍼티 스냅샷:
        // project.json 기본값 + 유저/프리셋 오버라이드(LibraryViewModel 유효값 계산과 동형).
        // 값 부재/미매치는 기본 image 로 폴백 → 무회귀. 변경은 reapply(remount)로 새 스냅샷.
        let baseProps = (try? WallpaperProperties.parse(folderURL: project.folderURL)) ?? []
        let overrides = UserPropertyStore.overrides(id: project.id, presetOverrides: project.presetOverrides,
                                                    presetResourceRoot: project.presetFolderURL)
        variantProperties = Dictionary(WallpaperProperties.applying(overrides: overrides, to: baseProps)
            .map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        // 비디오-텍스처 씬 → 내장 MP4 추출 후 VideoRenderer 위임.
        if let videoName = VideoTextureExtractor.videoLayer(in: doc, package: package),
           let mp4URL = VideoTextureExtractor.extractMP4(textureEntryName: videoName, package: package,
                                                         sceneID: project.id, cacheDir: VideoTextureExtractor.defaultCacheDir()) {
            let synthetic = WallpaperProject(
                id: project.id, type: .video, fileName: mp4URL.lastPathComponent, previewName: nil,
                title: project.title, tags: [], contentRating: nil, workshopId: nil, dependency: nil,
                folderURL: mp4URL.deletingLastPathComponent())
            let vr = VideoRenderer()
            try vr.mount(in: container, project: synthetic)
            self.videoRenderer = vr
            return
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw RendererError.unsupportedType }
        self.device = device
        self.queue = queue
        self.assetBaseDir = BaseAssetsSettings.baseAssetsDirectory

        let library = try device.makeLibrary(source: QuadShaders.source, options: nil)
        let pdesc = MTLRenderPipelineDescriptor()
        pdesc.vertexFunction = library.makeFunction(name: "v_main")
        pdesc.fragmentFunction = library.makeFunction(name: "f_main")
        let att = pdesc.colorAttachments[0]!
        att.pixelFormat = .bgra8Unorm
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add; att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .one; att.sourceAlphaBlendFactor = .one
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha; att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.pipeline = try device.makeRenderPipelineState(descriptor: pdesc)
        // colorBlendMode 레이어: dst 스냅샷 대비 블렌드를 셰이더에서 계산 → HW 블렌딩 OFF.
        let bdesc = MTLRenderPipelineDescriptor()
        bdesc.vertexFunction = library.makeFunction(name: "v_main")
        bdesc.fragmentFunction = library.makeFunction(name: "f_blend")
        bdesc.colorAttachments[0]!.pixelFormat = .bgra8Unorm
        self.blendPipeline = try? device.makeRenderPipelineState(descriptor: bdesc)

        clearColor = MTLClearColor(red: Double(doc.clearColor.x), green: Double(doc.clearColor.y),
                                   blue: Double(doc.clearColor.z), alpha: 1)
        projW = Float(max(1, doc.projectionWidth)); projH = Float(max(1, doc.projectionHeight))
        projAspect = projW / projH
        // 씬 공유 JSContext — 3D 오브젝트/빌보드 스크립트와 2D buildLayers/buildTexts/효과 스크립트가 공유.
        // **build3D 보다 먼저** 생성해야 3D 스크립트가 shared 통신 컨텍스트에 로드된다(태양계 Main 컨트롤러가
        // shared 궤도 파라미터를 세팅, 행성 origin 스크립트가 이를 읽음 — 공유 컨텍스트 없으면 shared 소실).
        sceneScript = SceneScriptContext(layers: Self.sceneScriptLayers(from: doc))
        // 3D 씬(camera3D + .mdl 오브젝트): 메시 + 빌보드(2D 이미지 레이어) + 오브젝트/그룹 프로퍼티 스크립트.
        // 메시/빌보드가 하나도 안 올라오면(로드 실패) 기존 2D 폴백 유지.
        if let cam = doc.camera3D, !doc.objects3D.isEmpty {
            camera3D = cam
            build3D(doc: doc, package: package, device: device)
            is3D = !meshRenderables.isEmpty || !billboards.isEmpty
        }
        if !is3D {
            camera3D = nil
            layers = buildLayers(doc: doc, package: package, device: device)
            particleSystems = buildParticles(doc: doc, package: package, device: device)
            if !particleSystems.isEmpty {
                hasParticles = true
                additivePipeline = particlePipeline(additive: true, device: device)
                translucentPipeline = particlePipeline(additive: false, device: device)
            }
            textLayers = buildTexts(doc: doc, package: package, device: device)
        }
        // 씬 오브젝트 순서(z-순서)대로 레이어·파티클·텍스트를 인터리브 드로우.
        // 안정 정렬(order 동률 시 삽입 순서 유지) — 파티클 자식이 부모 뒤에 오도록 보장
        // (자식 스냅샷은 같은 프레임에 부모가 먼저 스텝된 캐시를 읽는다).
        drawPlan = (layers.enumerated().map { (i, l) in (l.order, DrawItem(kind: .layer, idx: i)) }
                    + particleSystems.enumerated().map { (i, p) in (p.order, DrawItem(kind: .particle, idx: i)) }
                    + textLayers.enumerated().map { (i, t) in (t.order, DrawItem(kind: .text, idx: i)) })
            .enumerated()
            .sorted { ($0.1.0, $0.0) < ($1.1.0, $1.0) }
            .map { $0.1.1 }

        let view = MTKView(frame: container.bounds, device: device)
        view.autoresizingMask = [.width, .height]
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false  // 누적(acc) → drawable blit 대상이 되려면 필요(컴포지션 합성)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        container.wantsLayer = true
        container.addSubview(view)
        self.mtkView = view
        view.needsDisplay = true

        parallaxEnabled = doc.parallaxEnabled
        parallaxAmount = doc.parallaxAmount
        parallaxMouseInfluence = doc.parallaxMouseInfluence
        parallaxDelay = doc.parallaxDelay
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
        shouldAnimate = hasEffects || hasParticles || hasScriptedText || hasAnimations || has3DScripts
        if shouldAnimate {
            view.isPaused = false
            view.enableSetNeedsDisplay = false
            view.preferredFramesPerSecond = 30
            startTime = CFAbsoluteTimeGetCurrent()
            lastFrameTime = startTime
        }
        // 씬 이벤트 배선: cursorClick/Down/Up(전역 클릭 모니터) + cursorMove(마우스 모니터 공용,
        // 시차/효과 없어도 훅 있으면 기동) + 미디어(5초 폴링) — 소비 스크립트가 있을 때만.
        startClickMonitorIfNeeded()
        hasCursorMoveHook = eventEngines.contains(where: { $0.hookNames.contains("cursorMove") })
        if hasCursorMoveHook {
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
                } else {
                    let bins = AudioSpectrum16.downsample16(spec)
                    self?.currentSpectrum = AudioSpectrum16(left: bins, right: bins)
                }
            }
            provider.start()
            audioProvider = provider
        }
        // 씬 sound 레이어 재생 — 라이브 한정. 헤드리스(캡처/테스트)는 container.window == nil → 스킵(결정성).
        // 음량은 VideoSettings(배경별) 재사용 → 동영상 설정 메뉴의 음소거/음량이 씬 오디오에도 적용.
        if container.window != nil, !doc.sounds.isEmpty {
            let audio = SceneAudioPlayer()
            audio.start(sounds: doc.sounds, package: package,
                        settingVolume: VideoSettings.volume(id: project.id))
            sceneAudio = audio
        }
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
        mtkView?.needsDisplay = true
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

    public func draw(in view: MTKView) {
        // 가림 시 애니메이션 정지(배터리). drawable 획득 전에 검사해 drawable 낭비/stall 방지.
        if hasEffects || hasParticles || hasScriptedText || hasAnimations, view.window?.occlusionState.contains(.visible) == false { return }
        guard let device, let queue, pipeline != nil,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let nowT = CFAbsoluteTimeGetCurrent()
        let time = Float(nowT - startTime)
        var dt = Float(nowT - lastFrameTime); lastFrameTime = nowT
        dt = max(0, min(dt, 0.05))  // 큰 델타(탭 전환 등) 클램프

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

        // 3D 씬: 메시 + 빌보드 패스(뎁스, per-frame 스크립트) → drawable blit.
        if is3D {
            beginFramePool()
            guard let acc = pooledOffscreen(drawable.texture.width, drawable.texture.height, device, bgra: true),
                  encode3D(into: acc, cb: cb, device: device, time: time) else { cb.commit(); return }
            if let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: acc, to: drawable.texture)
                blit.endEncoding()
            }
            cb.present(drawable)
            cb.commit()
            return
        }

        refreshScriptedTexts(device: device, time: time)  // 초당 1회 update() 재평가(시계 등)
        // 효과 있는 레이어는 오프스크린 베이스→효과 패스 후 결과 텍스처로 교체.
        let displayTextures = buildDisplayTextures(device: device, queue: queue, time: time, cb: cb)

        var camOffset = cameraOffset
        // 종횡비 보정 — FitMode 설정에 따라(클릭 역매핑과 동일 공식 = sceneCoords 정합 보장).
        let ds = view.drawableSize
        let viewAspect = Float(ds.width / max(1, ds.height))
        var aspectScale = SceneRenderer.aspectScale(projAspect: projAspect, viewAspect: viewAspect,
                                                    fitMode: SceneRenderSettings.fitMode)
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
                                            particleSnapshot: { [self] idx in
                                                // 자식은 부모 sim 캐시를 그린다(drawPlan 이 부모를 먼저 스텝).
                                                if let c = particleSystems[idx].childOf {
                                                    return particleSystems[c.parent].sim.childDisplay(c.link)
                                                }
                                                return particleSystems[idx].sim.step(dt)
                                            },
                                            camOffset: &camOffset, aspectScale: &aspectScale) else { cb.commit(); return }
        finalEnc.endEncoding()
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: acc, to: drawable.texture)
            blit.endEncoding()
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
    /// 시뮬은 t=0 에서 새로 시작해 1/30 스텝으로 각 time 까지 진행(재현 가능). 데스크탑 가림과 무관.
    @discardableResult
    public func captureFrames(width: Int, height: Int, times: [Float], toDir: URL) -> [URL] {
        guard let device, let queue, pipeline != nil, let target = makeOffscreenBGRA(width, height, device) else { return [] }
        // 3D 씬: 메시 + 빌보드 패스(뎁스). per-frame 스크립트 평가로 각 time 마다 갱신(궤도/인트로 애니).
        if is3D {
            var urls: [URL] = []
            for t in times.sorted() {
                guard let cb = queue.makeCommandBuffer() else { continue }
                beginFramePool()
                guard encode3D(into: target, cb: cb, device: device, time: t) else { continue }
                cb.commit(); cb.waitUntilCompleted()
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
        var asp = SceneRenderer.aspectScale(projAspect: projAspect,
                                            viewAspect: Float(width) / Float(max(1, height)),
                                            fitMode: SceneRenderSettings.fitMode)
        // 자식 GPU 시스템의 로컬 sim 은 더미 — 부모 sim 이 자식을 구동하므로 웜업/스텝에서 제외.
        let rootIdxs = sims.indices.filter { particleSystems[$0].childOf == nil }
        for t in times.sorted() {
            while simTime < t - 1e-4 { let s = min(dt, t - simTime); for i in rootIdxs { _ = sims[i].step(s) }; simTime += s }
            guard let cb = queue.makeCommandBuffer() else { continue }
            // 효과 패스(오디오 포함, currentSpectrum 사용) 적용한 표시 텍스처.
            let displayTextures = buildDisplayTextures(device: device, queue: queue, time: t, cb: cb)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = clearColor
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            // 라이브 draw 와 동일한 씬-순서 인터리브(encodeDrawPlan 공용 — 복제 루프 발산 방지).
            // 파티클은 로컬 sims 의 현재 스냅샷(step(0)) 사용.
            // (camOff=0 이라 parallaxDepth 는 무영향 — encodeLayer 공용 사용 가능.)
            // target 이 곧 누적(acc) — 컴포지션 레이어는 스냅샷 경유(runFrameBufferLayer).
            guard let finalEnc = encodeDrawPlan(startingWith: enc, acc: target, cb: cb, device: device, time: t,
                                                displayTextures: displayTextures,
                                                particleSnapshot: { [self] idx in
                                                    if let c = particleSystems[idx].childOf {
                                                        return sims[c.parent].childDisplay(c.link)
                                                    }
                                                    return sims[idx].step(0)
                                                },
                                                camOffset: &camOff, aspectScale: &asp) else { cb.commit(); continue }
            finalEnc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            let url = toDir.appendingPathComponent("frame_t\(String(format: "%.1f", t)).png")
            if writeFramePNG(target, width: width, height: height, to: url) { urls.append(url) }
        }
        return urls
    }


    public func pause() {
        videoRenderer?.pause()
        sceneAudio?.pause()
        audioProvider?.stop()
        parallax.stop()
        if scenePausedAt == nil { scenePausedAt = CFAbsoluteTimeGetCurrent() }
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
        if let videoRenderer {
            videoRenderer.resume()
        } else if shouldAnimate {
            mtkView?.isPaused = false
            mtkView?.enableSetNeedsDisplay = false
        } else {
            mtkView?.needsDisplay = true
        }
        if hasAudio { audioProvider?.start() }
        if parallaxEnabled || hasEffects { parallax.start() }
        sceneAudio?.resume()
    }
    public func teardown() {
        videoRenderer?.teardown(); videoRenderer = nil
        sceneAudio?.teardown(); sceneAudio = nil
        parallax.stop()
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        mediaPoller?.stop(); mediaPoller = nil
        eventEngines = []
        hasCursorMoveHook = false
        audioProvider?.stop(); audioProvider = nil; hasAudio = false
        mtkView?.removeFromSuperview()
        mtkView = nil; layers = []; particleSystems = []; hasParticles = false
        textLayers = []; hasScriptedText = false; hasAnimations = false
        sceneScript = nil; scriptVisible.removeAll()
        additivePipeline = nil; translucentPipeline = nil
        camera3D = nil; is3D = false; has3DScripts = false
        nodes3D = []; meshRenderables = []; billboards = []; cameraScripts = []
        eval3DOrder = []; draw3DOrder = []
        meshPipelineOver = nil; meshPipelineAdditive = nil
        meshPipelineSkin = nil; meshPipelineSkinAdditive = nil
        meshDepthStates.removeAll(); depthTextures.removeAll()
        texturePool.removeAll(); poolCheckout.removeAll()
        pipeline = nil; queue = nil; device = nil
    }
}
