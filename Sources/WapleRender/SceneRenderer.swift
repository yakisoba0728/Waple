import AppKit
import MetalKit
import simd
import WapleCore

public final class SceneRenderer: NSObject, WallpaperRenderer, MTKViewDelegate {
    private struct AudioParams { let mode: Int; let freqMin: Float; let freqMax: Float; let bounds: SIMD2<Float>; let power: Float; let multiply: Float }
    /// 효과 바인딩: 손-포팅(기존 규약: float* P buffer(0) + aux texture(1+) + audioResp buffer(1))
    /// 또는 GLSL→MSL 변환본(reflection 규약: float4* p buffer(0) + EngineU buffer(1) + slot 텍스처 + audioL/R buffer(2/3)).
    /// 변환 효과의 1개 패스(멀티패스: effect.json passes[] — target=fbo 인덱스(nil=효과 출력),
    /// binds=(슬롯, 소스: -1=previous(효과 입력)|fbo 인덱스)).
    private struct TranslatedPass {
        let pipeline: MTLRenderPipelineState
        let material: [SIMD4<Float>]
        let aux: [(slot: Int, tex: MTLTexture)]
        let binds: [(slot: Int, source: Int)]
        let target: Int?
        let usesAudio: Bool
        let texRes: [SIMD4<Float>]
        /// 상수 프로퍼티 스크립트(슬롯 → 엔진) — per-frame 평가로 material 갱신(컬러 사이클 등).
        var scripts: [(slot: Int, engine: TextScriptEngine)] = []
    }
    private enum EffectBind {
        case handPort(params: [Float], aux: [MTLTexture], audio: AudioParams?)
        // fboScales: 이름 있는 FBO 의 해상도 나눗수(effect.json fbos[].scale) — 실행 시 dst 크기/scale 로 풀 할당.
        case translated(passes: [TranslatedPass], fboScales: [Int])
    }
    private struct EffectGPU { let pipeline: MTLRenderPipelineState; let bind: EffectBind }
    private struct GPULayer { let texture: MTLTexture; let vertexBuffer: MTLBuffer; let tint: SIMD4<Float>; let parallaxDepth: SIMD2<Float>; let effects: [EffectGPU]; let texWidth: Int; let texHeight: Int; let order: Int; var isFrameBuffer: Bool = false; var def: SceneLayer? = nil /* 프로퍼티 애니메이션 있는 레이어만(per-frame 재평가용) */; var puppet: PuppetModel? = nil; var propScripts: [(key: String, engine: TextScriptEngine)] = []; var initialVisible: Bool = true }
    private var hasAnimations = false
    private struct GPUParticleSystem {
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
    }
    /// 텍스트 레이어(시계/날짜/곡정보): 흰 글리프 텍스처 + tint. 스크립트는 초당 재평가 → 변경 시 재래스터.
    private struct GPUText {
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
    private var textLayers: [GPUText] = []
    private var hasScriptedText = false
    private var lastTextRefreshSecond = 0

    /// 씬 공유 JSContext(mount 당 1개) — 모든 프로퍼티 스크립트가 `shared` 로 통신(주야 컨트롤러 등).
    private var sceneScript: SceneScriptContext?
    /// visible 스크립트의 최근 평가값(레이어 order → 표시 여부). update(current) 에 이전 값을 전달.
    private var scriptVisible: [Int: Bool] = [:]

    /// 프로퍼티 스크립트 엔진 생성: 씬 공유 컨텍스트 우선(IIFE 격리), 컨텍스트 부재 시 단독 폴백.
    private func makeScriptEngine(_ src: String) -> TextScriptEngine? {
        if let scene = sceneScript { return TextScriptEngine(script: src, scene: scene) }
        return TextScriptEngine(script: src)
    }

    /// 씬 오브젝트 순서의 병합 드로우 플랜(레이어/파티클/텍스트 인터리브). mount 에서 1회 구성.
    private struct DrawItem { enum Kind { case layer, particle, text }; let kind: Kind; let idx: Int }
    private var drawPlan: [DrawItem] = []

    private var videoRenderer: VideoRenderer?
    private var mtkView: MTKView?
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var layers: [GPULayer] = []
    private var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    private var cameraOffset = SIMD2<Float>(0, 0)
    private var parallaxEnabled = false
    private var parallaxAmount: Float = 1
    private var parallaxMouseInfluence: Float = 1
    private let parallax = ParallaxController()
    /// WE 포인터 UV(0..1, 상단 원점). 마우스 미구동/헤드리스 = 중앙(0.5,0.5).
    private var pointerUV = SIMD2<Float>(0.5, 0.5)

    /// 정규화 오프셋(중심 0, 가장자리 ±1, AppKit y-up) → WE 포인터 UV(0..1, y-down). (순수)
    static func pointerUV(fromNormalized off: CGPoint) -> SIMD2<Float> {
        SIMD2(Float(off.x + 1) / 2, 1 - Float(off.y + 1) / 2)
    }
    private let maxShift: Float = 0.1
    private var projAspect: Float = 16.0 / 9.0
    private var projW: Float = 1920
    private var projH: Float = 1080
    private var startTime = CFAbsoluteTimeGetCurrent()
    private var lastFrameTime = CFAbsoluteTimeGetCurrent()
    private var hasEffects = false
    private var hasAudio = false
    private var currentSpectrum = AudioSpectrum16.silent
    // 고해상 스펙트럼(오디오 바 시각화). provider 프레임(64L+64R)에서 유지, 32빈은 쌍평균 파생.
    private var left64 = [Float](repeating: 0, count: 64)
    private var right64 = [Float](repeating: 0, count: 64)
    private var left32 = [Float](repeating: 0, count: 32)
    private var right32 = [Float](repeating: 0, count: 32)
    private var audioProvider: SystemAudioSpectrumProvider?
    private var effectVertexBuffer: MTLBuffer?
    private var effectQuadInterleaved: MTLBuffer?   // 변환 효과용 인터리브드 풀스크린 쿼드(pos.xyz + uv.xy)
    private var particleSystems: [GPUParticleSystem] = []
    private var hasParticles = false
    private var assetBaseDir: URL?  // WE 공유 에셋 폴백 디렉터리(설정), 패키지에 없는 .tex 용
    private var additivePipeline: MTLRenderPipelineState?
    private var translucentPipeline: MTLRenderPipelineState?
    private var fullscreenQuad: [SIMD2<Float>] = [SIMD2(-1,-1), SIMD2(1,-1), SIMD2(-1,1), SIMD2(1,1)]

    // ── 3D 씬(camera3D + .mdl 메시) 상태 ─────────────────────────────────────────
    /// 서브메시 1개 = 드로우콜 1개. vbuf 는 pos3+normal3+uv2 인터리브(8 float/정점), ibuf 는 u16.
    private struct GPU3DMesh {
        let vbuf: MTLBuffer
        let ibuf: MTLBuffer
        let indexCount: Int
        let texture: MTLTexture
        let tint: SIMD4<Float>       // 머티리얼 Color × Alpha
        let alphaCutoff: Float       // alphatocoverage → 0.5 (컷아웃 discard 근사), 그 외 0
        let cullBack: Bool           // cullmode "normal" → 백페이스 컬, "nocull" → 양면
        let additive: Bool
        let depthTest: Bool
        let depthWrite: Bool
        let skinned: Bool            // true → 16f 스트라이드 + mv_skin(본행렬 버퍼)
    }
    /// MSL 쪽 MeshU 와 레이아웃 일치(float4x4 + float4 + float4 = 96B).
    private struct MeshUniform { var mvp: simd_float4x4; var tint: SIMD4<Float>; var misc: SIMD4<Float> }
    private struct Script3D { let key: String; let engine: TextScriptEngine }

    /// 3D 변환 계층의 한 노드(그룹 or 모델 오브젝트) — per-frame 스크립트 평가로 로컬 변환/가시성 갱신.
    /// id 로 부모 체인 합성(Scene3DMath.worldMatrix). 모델 오브젝트는 MeshRenderable 이 동일 id 로 지오메트리 참조.
    private final class Node3D {
        let id: Int
        let parent: Int?
        let baseOrigin, baseAngles, baseScale: SIMD3<Float>
        let baseVisible: Bool
        let order: Int
        var scripts: [Script3D] = []
        // per-frame 현재값(스크립트 없으면 base 고정)
        var origin, angles, scale: SIMD3<Float>
        var visible: Bool
        init(id: Int, parent: Int?, origin: SIMD3<Float>, angles: SIMD3<Float>, scale: SIMD3<Float>, visible: Bool, order: Int) {
            self.id = id; self.parent = parent; self.order = order
            baseOrigin = origin; baseAngles = angles; baseScale = scale; baseVisible = visible
            self.origin = origin; self.angles = angles; self.scale = scale; self.visible = visible
        }
        /// 변환은 매 프레임 base 에서 재계산(스크립트가 일부 성분만 덮어써도 결정적), visible 은 이전값을 이어 평가.
        func evaluateScripts(time: Float) {
            var o = baseOrigin, a = baseAngles, s = baseScale
            for sc in scripts {
                sc.engine.setRuntime(Double(time))
                switch sc.key {
                case "origin": if let v = sc.engine.evaluateVec(current: [o.x, o.y, o.z]), v.count >= 3 { o = SIMD3(v[0], v[1], v[2]) }
                case "angles": if let v = sc.engine.evaluateVec(current: [a.x, a.y, a.z]), v.count >= 3 { a = SIMD3(v[0], v[1], v[2]) }
                case "scale":  if let v = sc.engine.evaluateVec(current: [s.x, s.y, s.z]), v.count >= 3 { s = SIMD3(v[0], v[1], v[2]) }
                case "visible": visible = sc.engine.evaluateBool(current: visible) ?? visible
                default: break
                }
            }
            origin = o; angles = a; scale = s
        }
    }

    /// 렌더 가능한 3D 메시(모델) — 변환은 동일 id 의 Node3D 에서.
    /// 스키닝 모델은 model(본+애니) + animIndex(활성 애니, -1=바인드포즈) + boneBuffer(프레임당 갱신) 보유.
    private struct MeshRenderable {
        let id: Int
        let meshes: [GPU3DMesh]
        let order: Int
        let name: String
        let model: Model3D?          // 스키닝: 본/애니 소스(정적 모델은 nil)
        let animIndex: Int           // -1 = 정지(바인드 포즈)
        let animRate: Float
        let boneBuffer: MTLBuffer?   // boneCount×64B(skin=world×bindWorld⁻¹), 프레임당 memcpy
    }

    /// 3D 씬의 2D 이미지 레이어를 카메라-페이싱 쿼드로(빌보드). 로컬 변환 + 부모 계층 + per-frame 스크립트.
    private final class Billboard3D {
        let texture: MTLTexture
        let size: SIMD2<Float>           // 씬 픽셀 크기(월드 반경 = size×scale×부모스케일)
        let parent: Int?
        let order: Int
        let additive: Bool               // 머티리얼 blending=additive → 가산 파이프라인(플레어/글로우)
        let baseOrigin: SIMD3<Float>
        let baseScale: SIMD2<Float>
        let baseTint: SIMD4<Float>
        let baseVisible: Bool
        var scripts: [Script3D] = []
        // per-frame
        var origin: SIMD3<Float>
        var scale: SIMD2<Float>
        var tint: SIMD4<Float>
        var visible: Bool
        init(texture: MTLTexture, size: SIMD2<Float>, parent: Int?, order: Int, additive: Bool,
             origin: SIMD3<Float>, scale: SIMD2<Float>, tint: SIMD4<Float>, visible: Bool) {
            self.texture = texture; self.size = size; self.parent = parent; self.order = order
            self.additive = additive
            baseOrigin = origin; baseScale = scale; baseTint = tint; baseVisible = visible
            self.origin = origin; self.scale = scale; self.tint = tint; self.visible = visible
        }
        func evaluateScripts(time: Float) {
            var o = baseOrigin, s = baseScale, t = baseTint
            for sc in scripts {
                sc.engine.setRuntime(Double(time))
                switch sc.key {
                case "origin": if let v = sc.engine.evaluateVec(current: [o.x, o.y, o.z]), v.count >= 3 { o = SIMD3(v[0], v[1], v[2]) }
                case "scale":  if let v = sc.engine.evaluateVec(current: [s.x, s.y, 1]), v.count >= 2 { s = SIMD2(v[0], v[1]) }
                case "color":  if let v = sc.engine.evaluateVec(current: [t.x, t.y, t.z]), v.count >= 3 { t = SIMD4(v[0], v[1], v[2], t.w) }
                case "alpha":  if let v = sc.engine.evaluateVec(current: [t.w]), let a = v.first { t.w = a }
                case "visible": visible = sc.engine.evaluateBool(current: visible) ?? visible
                default: break
                }
            }
            origin = o; scale = s; tint = t
        }
    }

    private var camera3D: SceneCamera3D?
    private var is3D = false
    private var has3DScripts = false
    private var nodes3D: [Node3D] = []                 // scene order(계층 합성 입력)
    private var meshRenderables: [MeshRenderable] = []
    private var billboards: [Billboard3D] = []
    /// per-frame 스크립트 평가 순서(씬 order — 컨트롤러(Main)가 이를 읽는 스크립트보다 먼저 실행).
    /// (order, isBillboard, idx). 스크립트 없는 노드/빌보드는 제외.
    private var eval3DOrder: [(order: Int, bb: Bool, idx: Int)] = []
    /// 그리기 순서(메시+빌보드 인터리브, order 오름차순). (order, isBillboard, idx).
    private var draw3DOrder: [(order: Int, bb: Bool, idx: Int)] = []
    private var meshPipelineOver: MTLRenderPipelineState?      // premultiplied over(normal/translucent)
    private var meshPipelineAdditive: MTLRenderPipelineState?
    private var meshPipelineSkin: MTLRenderPipelineState?      // GPU 스키닝(mv_skin) over
    private var meshPipelineSkinAdditive: MTLRenderPipelineState?
    /// 카메라 프로퍼티 스크립트(eye/center/up/fov). per-frame 재평가로 카메라 애니.
    private var cameraScripts: [Script3D] = []
    private var meshDepthStates: [String: MTLDepthStencilState] = [:]  // "test-write" 키
    private var depthTextures: [String: MTLTexture] = [:]     // 크기별 재사용(.depth32Float)

    public override init() { super.init() }

    public func mount(in container: NSView, project: WallpaperProject) throws {
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
                guard let base = BaseAssetsSettings.baseAssetsDirectory else { return nil }
                return try? Data(contentsOf: base.appendingPathComponent(name))
            }, userProps: UserPropertyStore.rawOverrides(id: project.id))
        } catch {
            NSLog("%@", "[Waple] scene mount: failed to parse \(pkgURL.path): \(error)")
            throw error
        }
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

        clearColor = MTLClearColor(red: Double(doc.clearColor.x), green: Double(doc.clearColor.y),
                                   blue: Double(doc.clearColor.z), alpha: 1)
        projW = Float(max(1, doc.projectionWidth)); projH = Float(max(1, doc.projectionHeight))
        projAspect = projW / projH
        // 씬 공유 JSContext — 3D 오브젝트/빌보드 스크립트와 2D buildLayers/buildTexts/효과 스크립트가 공유.
        // **build3D 보다 먼저** 생성해야 3D 스크립트가 shared 통신 컨텍스트에 로드된다(태양계 Main 컨트롤러가
        // shared 궤도 파라미터를 세팅, 행성 origin 스크립트가 이를 읽음 — 공유 컨텍스트 없으면 shared 소실).
        sceneScript = SceneScriptContext()
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
        drawPlan = (layers.enumerated().map { (i, l) in (l.order, DrawItem(kind: .layer, idx: i)) }
                    + particleSystems.enumerated().map { (i, p) in (p.order, DrawItem(kind: .particle, idx: i)) }
                    + textLayers.enumerated().map { (i, t) in (t.order, DrawItem(kind: .text, idx: i)) })
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }

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
        if hasEffects || hasParticles || hasScriptedText || hasAnimations || has3DScripts {
            view.isPaused = false
            view.enableSetNeedsDisplay = false
            view.preferredFramesPerSecond = 30
            startTime = CFAbsoluteTimeGetCurrent()
            lastFrameTime = startTime
        }
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
    }

    private func pkgURL(in folder: URL) -> URL? {
        for name in ["scene.pkg", "gifscene.pkg"] {
            let u = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// 텍스처/에셋 바이트 로드: 패키지 우선, 없으면 공유 기본 에셋 디렉터리에서 폴백.
    /// 공유에서 찾거나 둘 다 없을 때만 로그(in-pkg 일반 경로는 조용히).
    private func assetData(_ name: String, package: ScenePackage) -> Data? {
        if let d = package.data(for: name) { return d }
        if let base = assetBaseDir {
            let u = base.appendingPathComponent(name)
            if let d = try? Data(contentsOf: u) {
                NSLog("%@", "[Waple] asset from shared base: \(name)")
                return d
            }
        }
        NSLog("%@", "[Waple] asset missing (pkg+shared): \(name)")
        return nil
    }

    /// 레이어를 후→전 순서(JSON 순서)로 GPU 리소스화. 디코드 실패 레이어는 스킵.
    private func buildLayers(doc: SceneDocument, package: ScenePackage, device: MTLDevice) -> [GPULayer] {
        let w = Float(doc.projectionWidth), h = Float(doc.projectionHeight)
        var out: [GPULayer] = []
        for layer in doc.layers {
            // 솔리드 마커(""): 무텍스처 flat 머티리얼 → 흰색 1x1 — 기존 tint 경로(color×brightness, alpha)가 필을 만든다.
            // 컴포지션(_rt_) 레이어: 텍스처는 런타임 스냅샷 — 여기선 placeholder + 효과 dims 를 프로젝션으로 근사
            // (효과 texRes 는 주로 텍셀 오프셋 용도; 화면 크기는 draw 시 결정 — 설계 §3).
            let decoded: (pixels: Data, width: Int, height: Int)
            if layer.textureEntryName.isEmpty {  // 솔리드/컴포지션 placeholder
                decoded = (Data([255, 255, 255, 255]), 1, 1)
            } else if let texData = assetData(layer.textureEntryName, package: package),
                      let tex = TexImage.parse(texData),
                      let d = TexDecoder.rgba(from: tex, data: texData) {
                decoded = d
            } else { continue }
            guard let mtl = makeTexture(decoded.pixels, decoded.width, decoded.height, device) else { continue }
            // 컴포지션 레이어의 효과 dims 는 화면(프로젝션) 근사 — 실제 src 는 draw 시 스냅샷.
            let effW = layer.isFrameBuffer ? Int(max(1, projW)) : decoded.width
            let effH = layer.isFrameBuffer ? Int(max(1, projH)) : decoded.height
            let verts = quadVertices(layer: layer, projW: w, projH: h)
            guard let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<SIMD4<Float>>.stride * verts.count) else { continue }
            let tint = SIMD4<Float>(layer.color.x * layer.brightness, layer.color.y * layer.brightness,
                                    layer.color.z * layer.brightness, layer.alpha)
            var effects: [EffectGPU] = []
            // 디버그: WAPLE_EFFECT_SKIP=이름,이름 → 해당 효과 제외(파리티 이분용, WAPLE_MP_TRUNC 와 세트).
            let skipNames = Set((ProcessInfo.processInfo.environment["WAPLE_EFFECT_SKIP"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            for eff in layer.effects {
                if skipNames.contains(eff.name) { continue }
                // 폴백 체인(Step 5, 2026-07-02 실물 검증 후 전환): **translated 우선** — pkg 동봉 GLSL 은
                // 실제 WE 셰이더라 손-포팅 근사보다 항상 정확(실측: 근사 shake 가 5중 체인에서 과대 팬).
                // GLSL 부재/번역·컴파일 실패 시 손-포팅(스톡 7종) 폴백 → 둘 다 실패 시 스킵+로그.
                if let translated = buildTranslatedEffect(eff, package: package, device: device,
                                                          texW: effW, texH: effH) {
                    effects.append(translated)
                } else if let handPort = buildHandPortEffect(eff, package: package, device: device) {
                    effects.append(handPort)
                } else {
                    NSLog("%@", "[Waple] effect skipped (no translatable GLSL, no hand-port): \(eff.name)")
                }
            }
            if !effects.isEmpty { hasEffects = true }
            if !layer.animations.isEmpty { hasAnimations = true }
            // 퍼펫(.mdl): 스키닝 메시 — 로드 실패 시 정지 쿼드 폴백(로그).
            var puppetModel: PuppetModel? = nil
            if let pp = layer.puppet {
                if let bytes = assetData(pp, package: package), let pm = PuppetModel.parse(bytes) {
                    puppetModel = pm
                    if !pm.animations.isEmpty { hasAnimations = true }
                } else {
                    NSLog("%@", "[Waple] puppet mdl load failed (static quad fallback): \(pp)")
                }
            }
            // 레이어 프로퍼티 스크립트(visible/color/alpha): 씬 공유 컨텍스트에서 per-frame 평가.
            // visible 을 먼저 로드 — 실물 컨트롤러(3394601417 'bt')의 top-level shared 초기화가
            // 같은 오브젝트의 다른 스크립트보다 앞서도록. update 없는 스크립트(사이드이펙트 전용)도
            // 로드는 하되 연속 렌더(hasAnimations)는 유발하지 않는다.
            var propScripts: [(key: String, engine: TextScriptEngine)] = []
            for key in ["visible", "color", "alpha"] {
                guard let src = layer.propertyScripts[key] else { continue }
                if let e = makeScriptEngine(src) {
                    propScripts.append((key, e))
                    if e.hasUpdate { hasAnimations = true }
                }
            }
            out.append(GPULayer(texture: mtl, vertexBuffer: vbuf, tint: tint,
                                parallaxDepth: SIMD2<Float>(layer.parallaxDepth.x, layer.parallaxDepth.y),
                                effects: effects, texWidth: effW, texHeight: effH,
                                order: layer.order, isFrameBuffer: layer.isFrameBuffer,
                                def: (layer.animations.isEmpty && puppetModel == nil && propScripts.isEmpty) ? nil : layer,
                                puppet: puppetModel, propScripts: propScripts,
                                initialVisible: layer.initialVisible))
        }
        return out
    }

    /// 손-포팅 효과(검증된 스톡 7종) 빌드. 미지원 이름이면 nil(→ 변환 경로 시도).
    private func buildHandPortEffect(_ eff: SceneEffect, package: ScenePackage, device: MTLDevice) -> EffectGPU? {
        guard let src = EffectShaders.source(for: eff.name),
              let params = EffectShaders.params(for: eff.name, constants: eff.constants, combos: eff.combos),
              let pipe = effectPipeline(source: src, device: device) else { return nil }
        let audio = audioParams(for: eff)
        if audio != nil { hasAudio = true }
        // slot0 은 framebuffer → aux 는 slot1.. 디코드. 디코드 실패는 흰색 1x1 폴백.
        // 레거시 frag(mask=texture(1)) 와 waterripple(normal=1, mask=2) 모두 위해
        // 최소 2개 슬롯을 흰색으로 채워 미바인드 텍스처를 방지한다.
        var aux: [MTLTexture] = []
        let auxNames = eff.textureNames.count > 1 ? Array(eff.textureNames[1...]) : []
        for name in auxNames {
            guard let t = resolveTexture(name, package: package, device: device) else { continue }
            aux.append(t)
        }
        while aux.count < 2, let white = makeTexture(Data([255, 255, 255, 255]), 1, 1, device) {
            aux.append(white)
        }
        return EffectGPU(pipeline: pipe, bind: .handPort(params: params, aux: aux, audio: audio))
    }

    /// GLSL→MSL 변환 효과 빌드(멀티패스): effect.json 매니페스트(passes/fbos) → 패스별 셰이더 로드 →
    /// translate → 파이프라인 → 바인드 플랜. 어느 단계든 실패하면 nil(→ 손-포팅 폴백 → 스킵). 무회귀.
    private func buildTranslatedEffect(_ eff: SceneEffect, package: ScenePackage, device: MTLDevice,
                                       texW: Int, texH: Int) -> EffectGPU? {
        // 디버그 바이섹션 스위치: 실물 씬에서 번역 효과만 끄고 A/B 비교(시각 아티팩트 책임 분리).
        if ProcessInfo.processInfo.environment["WAPLE_DISABLE_TRANSLATED"] == "1" { return nil }
        // #include 리졸버: pkg→베이스에셋→내장(확정-의미 서브셋, common_blending.h) 순.
        let include: (String) -> String? = { header in
            for cand in ["shaders/\(header)", header] {
                if let d = self.quietAssetData(cand, package: package), let s = String(data: d, encoding: .utf8) { return s }
            }
            return BuiltinShaderIncludes.lookup(header)
        }
        // 매니페스트: effect.json 이 없으면 관례 단일 패스("effects/<name>" 셰이더).
        let effectJSONPath = eff.file.isEmpty ? "effects/\(eff.name)/effect.json" : eff.file
        let manifest: EffectManifest
        if let d = quietAssetData(effectJSONPath, package: package), let m = EffectManifest.parse(d) {
            manifest = m
        } else {
            manifest = EffectManifest(passes: [.init(material: nil, shader: nil, target: nil, binds: [])], fbos: [])
        }
        let fboIndex = Dictionary(uniqueKeysWithValues: manifest.fbos.enumerated().map { ($1.name, $0) })
        let lw = Float(max(1, texW)), lh = Float(max(1, texH))
        var passes: [TranslatedPass] = []
        var anyAudio = false
        for (i, mp) in manifest.passes.enumerated() {
            // 명령 패스(셰이더 없음): "copy" = source fbo → target fbo 지속(실물 motionblur 의 누적 버퍼).
            // 통과(passthrough) 파이프라인으로 합성해 기존 멀티패스 실행 경로를 그대로 재사용(루프 무변경).
            if mp.command == "copy" {
                guard let srcName = mp.source, let srcIdx = fboIndex[srcName],
                      let tgtName = mp.target, let tgtIdx = fboIndex[tgtName],
                      let pipe = passthroughEffectPipeline(device: device) else {
                    NSLog("%@", "[Waple] unresolved copy pass in \(eff.name)"); return nil
                }
                let dims = SIMD4<Float>(lw, lh, lw, lh)
                passes.append(TranslatedPass(pipeline: pipe, material: [], aux: [],
                                             binds: [(0, srcIdx)], target: tgtIdx, usesAudio: false,
                                             texRes: [SIMD4<Float>](repeating: dims, count: 8), scripts: []))
                continue
            }
            // 셰이더 이름 + 머티리얼 메타(combos/textures) 해석.
            var shaderName = mp.shader
            var matCombos: [String: Int] = [:]
            var matTextures: [String?] = []
            if shaderName == nil, let matPath = mp.material,
               let mData = quietAssetData(matPath, package: package),
               let mjson = (try? JSONSerialization.jsonObject(with: mData)) as? [String: Any],
               let mp0 = (mjson["passes"] as? [Any])?.first as? [String: Any] {
                shaderName = mp0["shader"] as? String
                for (k, v) in (mp0["combos"] as? [String: Any]) ?? [:] {
                    if let n = v as? Int { matCombos[k] = n }
                    else if let d = v as? Double { matCombos[k] = Int(d) }
                }
                if let texs = mp0["textures"] as? [Any] { matTextures = texs.map { $0 as? String } }
            }
            let base = shaderName ?? "effects/\(eff.name)"
            guard let vData = quietAssetData("shaders/\(base).vert", package: package),
                  let fData = quietAssetData("shaders/\(base).frag", package: package),
                  let vert = String(data: vData, encoding: .utf8),
                  let frag = String(data: fData, encoding: .utf8) else { return nil }
            let scenePass = i < eff.passList.count ? eff.passList[i] : SceneEffectPass()
            // 콤보 우선순위: 머티리얼 기본 < scene 패스 지정.
            var combos = matCombos
            for (k, v) in scenePass.combos { combos[k] = v }
            // WE 규약: 샘플러 주석의 "combo":"X" 는 그 슬롯에 텍스처가 바인딩되면 자동 활성
            // (실물 reflection/waterwaves/shake 의 페인트 마스크 — 미적용 시 마스크 무시 = 전화면 적용 사고).
            for (slot, comboName) in GLSLTranslator.samplerCombos(frag) where combos[comboName] == nil {
                let sceneBound = slot < scenePass.textureNames.count && scenePass.textureNames[slot] != nil
                let matBound = slot < matTextures.count && matTextures[slot] != nil
                if sceneBound || matBound { combos[comboName] = 1 }
            }
            guard let t = GLSLTranslator.translate(vertex: vert, fragment: frag, combos: combos, include: include) else {
                NSLog("%@", "[Waple] GLSL translate failed: \(eff.name) pass \(i)")
                return nil
            }
            guard let pipe = translatedPipeline(msl: t.msl, device: device) else {
                NSLog("%@", "[Waple] translated MSL compile failed: \(eff.name) pass \(i)")
                return nil
            }
            let constants = scenePass.constants
            let material: [SIMD4<Float>] = t.materialParams.map { p in
                let v = constants[p.sceneKey] ?? p.defaultValue
                return SIMD4<Float>(v.count > 0 ? v[0] : 0, v.count > 1 ? v[1] : 0,
                                    v.count > 2 ? v[2] : 0, v.count > 3 ? v[3] : 0)
            }
            var passScripts: [(slot: Int, engine: TextScriptEngine)] = []
            for (slot, p) in t.materialParams.enumerated() {
                if let src = scenePass.constantScripts[p.sceneKey], let engine = makeScriptEngine(src) {
                    passScripts.append((slot, engine))
                    if engine.hasUpdate { hasAnimations = true }  // 스크립트 상수는 시간 함수 — 연속 렌더 필요
                }
            }
            // 바인드: previous → -1, 이름 → fbo 인덱스(미지 이름은 전체 실패 → 폴백). 부재 시 관례 previous@0.
            var binds: [(slot: Int, source: Int)] = []
            for b in mp.binds {
                if b.name == "previous" { binds.append((b.index, -1)) }
                else if let idx = fboIndex[b.name] { binds.append((b.index, idx)) }
                else { NSLog("%@", "[Waple] unknown bind '\(b.name)' in \(eff.name)"); return nil }
            }
            if binds.isEmpty { binds = [(0, -1)] }
            let bindSlots = Set(binds.map { $0.slot })
            // texRes + 정적 aux: 바인드 슬롯은 소스 dims(fbo = 레이어/scale), 그 외 선언 슬롯은 텍스처 해석.
            // WE 규약: g_TextureXResolution = (paddedW, paddedH, imageW, imageH) — .zw 는 역수가 아니라 실치수
            // (gaussian 등이 g_Scale/…Resolution.z 로 텍셀 오프셋 계산; 역수면 오프셋 폭주 → 화면 백화).
            var texRes = [SIMD4<Float>](repeating: SIMD4(lw, lh, lw, lh), count: 8)
            for (slot, source) in binds where slot < 8 && source >= 0 {
                let s = Float(manifest.fbos[source].scale)
                texRes[slot] = SIMD4(lw / s, lh / s, lw / s, lh / s)
            }
            var aux: [(slot: Int, tex: MTLTexture)] = []
            for slot in t.textureSlots where slot > 0 && !bindSlots.contains(slot) {
                var name = slot < scenePass.textureNames.count ? scenePass.textureNames[slot] : nil
                if name == nil, slot < matTextures.count { name = matTextures[slot] }
                if let n = name, n.hasPrefix("_rt_") { continue }
                if let tex = resolveTexture(name, package: package, device: device) {
                    aux.append((slot, tex))
                    if slot < 8 {
                        let w = Float(max(1, tex.width)), h = Float(max(1, tex.height))
                        texRes[slot] = SIMD4(w, h, w, h)
                    }
                }
            }
            let target: Int? = mp.target.flatMap { fboIndex[$0] }
            if mp.target != nil && target == nil { NSLog("%@", "[Waple] unknown target in \(eff.name)"); return nil }
            if t.usesAudio { anyAudio = true }
            passes.append(TranslatedPass(pipeline: pipe, material: material, aux: aux,
                                         binds: binds, target: target, usesAudio: t.usesAudio, texRes: texRes,
                                         scripts: passScripts))
        }
        // 출력(타깃 없는 패스)이 하나도 없으면 화면에 아무것도 못 쓴다 → 폴백.
        guard passes.contains(where: { $0.target == nil }) else { return nil }
        if anyAudio { hasAudio = true }
        NSLog("%@", "[Waple] effect via GLSL→MSL translator: \(eff.name) (passes=\(passes.count) fbos=\(manifest.fbos.count) audio=\(anyAudio))")
        return EffectGPU(pipeline: passes[0].pipeline,
                         bind: .translated(passes: passes, fboScales: manifest.fbos.map { $0.scale }))
    }

    /// assetData 의 조용한 버전: pkg→베이스에셋 조회하되 미스에 로그 없음(소스 프로브는 미스가 정상).
    private func quietAssetData(_ name: String, package: ScenePackage) -> Data? {
        if let d = package.data(for: name) { return d }
        if let base = assetBaseDir { return try? Data(contentsOf: base.appendingPathComponent(name)) }
        return nil
    }

    /// 변환 효과 파이프라인. 정점 디스크립터: a_Position float3@0, a_TexCoord float2@12, stride 20,
    /// 버퍼 인덱스 4(p=buffer0 / eng=buffer1 와 충돌 회피 — 스파이크 증명 규약).
    /// command=copy 패스용 통과 파이프라인(g_Texture0 을 그대로 target 에 기록). translated 실행 규약과
    /// 동일한 버텍스 디스크립터/버퍼 인덱스를 쓰도록 GLSL 통과 셰이더를 번역해 캐시.
    private var _passthroughPipeline: MTLRenderPipelineState?
    private func passthroughEffectPipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        if let p = _passthroughPipeline { return p }
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
        """
        guard let t = GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]),
              let p = translatedPipeline(msl: t.msl, device: device) else { return nil }
        _passthroughPipeline = p
        return p
    }

    private func translatedPipeline(msl: String, device: MTLDevice) -> MTLRenderPipelineState? {
        let lib: MTLLibrary
        do {
            lib = try device.makeLibrary(source: msl, options: nil)
        } catch {
            // 실패 원인 진단용: 첫 에러 줄만(대개 undefined identifier = common.h 함수 부재).
            let first = "\(error)".split(separator: "\n").first(where: { $0.contains("error:") }) ?? ""
            NSLog("%@", "[Waple] translated MSL compile error: \(first)")
            return nil
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "ev_main")
        pd.fragmentFunction = lib.makeFunction(name: "ef_main")
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 4
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 4
        vd.layouts[4].stride = 20
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        return try? device.makeRenderPipelineState(descriptor: pd)
    }

    /// EngineU 버퍼: mvp(항등) + timeAndPad(time,0,0,0) + texRes[8](슬롯별 실제 dims — 빌드 시 계산).
    private func engineUniform(time: Float, texRes: [SIMD4<Float>]) -> [Float] {
        var e = [Float](repeating: 0, count: 16 + 4 + 32)
        e[0] = 1; e[5] = 1; e[10] = 1; e[15] = 1   // identity mvp
        e[16] = time; e[17] = pointerUV.x; e[18] = pointerUV.y  // timeAndPad = (time, pointerX, pointerY, 0)
        for n in 0..<8 {
            let r = n < texRes.count ? texRes[n] : SIMD4<Float>(1, 1, 1, 1)
            let o = 20 + n * 4
            e[o] = r.x; e[o + 1] = r.y; e[o + 2] = r.z; e[o + 3] = r.w
        }
        return e
    }

    /// 효과 보조 텍스처 슬롯 이름 → MTLTexture. 이름 nil/디코드 실패 → 흰색 1x1 폴백
    /// (마스크는 흰색=효과 전체 적용, 노멀맵은 흰색=무왜곡에 가까움).
    /// "effects/X"/"masks/X" 같은 상대 이름은 "materials/<name>.tex" 로 해석, raw 이름도 시도.
    private func resolveTexture(_ name: String?, package: ScenePackage, device: MTLDevice) -> MTLTexture? {
        if let name {
            let cand = name.hasSuffix(".tex") ? name : "materials/\(name).tex"
            if let d = assetData(cand, package: package) ?? assetData(name, package: package),
               let tex = TexImage.parse(d), let dec = TexDecoder.rgba(from: tex, data: d),
               let m = makeTexture(dec.pixels, dec.width, dec.height, device) { return m }
        }
        return makeTexture(Data([255, 255, 255, 255]), 1, 1, device)
    }

    /// 효과의 AUDIOPROCESSING 콤보 + 오디오 상수 → AudioParams(없으면 nil). draw 시 audioResponse 계산에 사용.
    private func audioParams(for eff: SceneEffect) -> AudioParams? {
        let mode = eff.audioMode
        guard mode >= 1, mode <= 3 else { return nil }
        let c = eff.constants
        let bounds = c["audiobounds"] ?? [0.5, 1.0]
        return AudioParams(
            mode: mode,
            freqMin: c["frequencymin"]?.first ?? 0,
            freqMax: c["frequencymax"]?.first ?? 15,
            bounds: SIMD2<Float>(bounds.count > 0 ? bounds[0] : 0.5, bounds.count > 1 ? bounds[1] : 1.0),
            power: c["audioexponent"]?.first ?? 1,
            multiply: c["audioamount"]?.first ?? 1)
    }

    /// 파티클 시스템별 텍스처/시뮬/블렌드 준비. 텍스처는 material 의 첫 텍스처(없으면 흰색 폴백).
    private func buildParticles(doc: SceneDocument, package: ScenePackage, device: MTLDevice) -> [GPUParticleSystem] {
        var out: [GPUParticleSystem] = []
        for (i, sp) in doc.particles.enumerated() {
            let tex = resolveTexture(sp.def.material?.textureName, package: package, device: device)
                ?? makeTexture(Data([255, 255, 255, 255]), 1, 1, device)
            guard let tex else { continue }
            let ratio = Float(tex.height) / Float(max(1, tex.width))
            let seed = UInt64(0x9E37_79B9_7F4A_7C15 &+ UInt64(i))
            out.append(GPUParticleSystem(
                sim: ParticleSimulator(def: sp.def, seed: seed), def: sp.def, seed: seed,
                texture: tex, blendAdditive: sp.def.material?.blend == .additive,
                origin: SIMD2<Float>(sp.origin.x, sp.origin.y),
                scale: SIMD2<Float>(sp.scale.x, sp.scale.y), texRatio: ratio, order: sp.order,
                isTrail: sp.def.renderer.isTrail))
        }
        return out
    }

    /// 파티클 파이프라인. frag 가 premultiplied-alpha 출력 → src=one.
    /// additive: dst=one(가산), translucent: dst=oneMinusSrcAlpha(일반 over).
    private func particlePipeline(additive: Bool, device: MTLDevice) -> MTLRenderPipelineState? {
        guard let lib = try? device.makeLibrary(source: ParticleShaders.source, options: nil) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "pv_main")
        pd.fragmentFunction = lib.makeFunction(name: "pf_main")
        let a = pd.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: pd)
    }

    // ── 3D 씬(메시) 경로 ─────────────────────────────────────────────────────────

    /// .mdl 로드 → 서브메시별 버퍼/텍스처 → MeshRenderable, 2D 이미지 레이어 → Billboard3D,
    /// 그룹/모델 → Node3D(변환 계층). 프로퍼티 스크립트 엔진은 **씬 order** 로 로드(컨트롤러 top-level
    /// 사이드이펙트가 이를 읽는 스크립트보다 먼저) 후 per-frame 평가. 실패 오브젝트는 스킵+로그.
    private func build3D(doc: SceneDocument, package: ScenePackage, device: MTLDevice) {
        guard let lib = try? device.makeLibrary(source: Mesh3DShaders.source, options: nil) else {
            NSLog("%@", "[Waple] 3D: mesh shader compile failed")
            return
        }
        meshPipelineOver = mesh3DPipeline(lib: lib, vertex: "mv_main", additive: false, device: device)
        meshPipelineAdditive = mesh3DPipeline(lib: lib, vertex: "mv_main", additive: true, device: device)
        meshPipelineSkin = mesh3DPipeline(lib: lib, vertex: "mv_skin", additive: false, device: device)
        meshPipelineSkinAdditive = mesh3DPipeline(lib: lib, vertex: "mv_skin", additive: true, device: device)
        guard meshPipelineOver != nil else { return }

        // 카메라 프로퍼티 스크립트(eye/center/up/fov) 로드 — per-frame 재평가로 카메라 애니(젤다 fov 등).
        for key in ["eye", "center", "up", "fov"] {
            guard let src = doc.cameraScripts[key], let e = makeScriptEngine(src) else { continue }
            cameraScripts.append(Script3D(key: key, engine: e))
        }

        // ── 변환 계층 노드(그룹 + 모델 오브젝트). 모델도 다른 모델/빌보드의 부모가 될 수 있다. ──
        for g in doc.nodes3D {
            let n = Node3D(id: g.id, parent: g.parent,
                           origin: SIMD3(g.origin.x, g.origin.y, g.origin.z),
                           angles: SIMD3(g.angles.x, g.angles.y, g.angles.z),
                           scale: SIMD3(g.scale.x, g.scale.y, g.scale.z),
                           visible: g.visible, order: 0)
            attachScripts(n, sources: g.propertyScripts)
            nodes3D.append(n)
        }
        for o in doc.objects3D {
            let n = Node3D(id: o.id, parent: o.parent,
                           origin: SIMD3(o.origin.x, o.origin.y, o.origin.z),
                           angles: SIMD3(o.angles.x, o.angles.y, o.angles.z),
                           scale: SIMD3(o.scale.x, o.scale.y, o.scale.z),
                           visible: true, order: o.order)
            attachScripts(n, sources: o.propertyScripts)
            nodes3D.append(n)
        }

        // ── 메시 지오메트리(모델). 정적 비가시(조상 그룹) 판정은 base 트랜스폼 기준으로 프리컬 — 스크립트로
        //    다시 켜지는 서브트리는 드묾(젤다 link_adult 는 그룹 visible=false 고정). ──
        var loaded = 0, skipped = 0
        for obj in doc.objects3D {
            guard let mdlData = assetData(obj.model, package: package),
                  let model = Model3D.parse(mdlData) else {
                NSLog("%@", "[Waple] 3D: mdl load failed: \(obj.model)")
                skipped += 1
                continue
            }
            let boneCount = model.bones.count
            var meshes: [GPU3DMesh] = []
            var anySkinned = false
            for mesh in model.meshes {
                guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty else { continue }
                // 스키닝 메시(v3): pos3+normal3+uv2+boneIdx4+weight4(16f) — GPU 정점 스키닝(mv_skin).
                // 정적 메시: pos3+normal3+uv2(8f). 본 인덱스는 boneCount-1 로 clamp(셰이더 OOB 방지).
                let skinned = mesh.skinned && boneCount > 0
                var packed = [Float]()
                packed.reserveCapacity(mesh.vertices.count * (skinned ? 16 : 8))
                for v in mesh.vertices {
                    packed.append(contentsOf: [v.position.x, v.position.y, v.position.z,
                                               v.normal.x, v.normal.y, v.normal.z,
                                               v.uv.x, v.uv.y])
                    if skinned {
                        let mx = UInt32(max(0, boneCount - 1))
                        packed.append(contentsOf: [Float(min(v.boneIndices.x, mx)), Float(min(v.boneIndices.y, mx)),
                                                   Float(min(v.boneIndices.z, mx)), Float(min(v.boneIndices.w, mx)),
                                                   v.weights.x, v.weights.y, v.weights.z, v.weights.w])
                    }
                }
                guard let vbuf = device.makeBuffer(bytes: packed, length: MemoryLayout<Float>.stride * packed.count),
                      let ibuf = mesh.indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
                else { continue }
                let mat = loadMesh3DMaterial(mesh.material, package: package, device: device)
                if skinned { anySkinned = true }
                meshes.append(GPU3DMesh(vbuf: vbuf, ibuf: ibuf, indexCount: mesh.indices.count,
                                        texture: mat.texture, tint: mat.tint, alphaCutoff: mat.alphaCutoff,
                                        cullBack: mat.cullBack, additive: mat.additive,
                                        depthTest: mat.depthTest, depthWrite: mat.depthWrite, skinned: skinned))
            }
            guard !meshes.isEmpty else { skipped += 1; continue }
            // 활성 애니(animationlayers) → 인덱스. 스키닝 모델만 bone 버퍼/모델 참조 보유.
            var animIndex = -1
            var boneBuffer: MTLBuffer? = nil
            var keepModel: Model3D? = nil
            if anySkinned {
                keepModel = model
                boneBuffer = device.makeBuffer(length: max(1, boneCount) * MemoryLayout<simd_float4x4>.stride,
                                               options: .storageModeShared)
                // WAPLE3D_BINDPOSE=1 → 애니 무시(skin=항등, 바인드 포즈) — 스키닝 배선 정합 게이트(v2 정적과 비교).
                let bindPoseOnly = ProcessInfo.processInfo.environment["WAPLE3D_BINDPOSE"] == "1"
                animIndex = (!bindPoseOnly && obj.animation != nil)
                    ? Model3DPose.resolveAnimation(model: model, layerName: obj.animation?.name)
                    : -1
            }
            meshRenderables.append(MeshRenderable(id: obj.id, meshes: meshes, order: obj.order, name: obj.name,
                                                  model: keepModel, animIndex: animIndex,
                                                  animRate: obj.animation?.rate ?? 1, boneBuffer: boneBuffer))
            loaded += 1
        }

        // ── 빌보드(2D 이미지 레이어). 텍스처 로딩은 2D 경로와 동일(assetData→TexImage→TexDecoder). ──
        var bbLoaded = 0, bbSkipped = 0
        for layer in doc.layers {
            guard !layer.textureEntryName.isEmpty,
                  let texData = assetData(layer.textureEntryName, package: package),
                  let tex = TexImage.parse(texData),
                  let dec = TexDecoder.rgba(from: tex, data: texData),
                  let mtl = makeTexture(dec.pixels, dec.width, dec.height, device) else {
                bbSkipped += 1; continue
            }
            let tint = SIMD4<Float>(layer.color.x * layer.brightness, layer.color.y * layer.brightness,
                                    layer.color.z * layer.brightness, layer.alpha)
            let bb = Billboard3D(texture: mtl, size: SIMD2(layer.size.x, layer.size.y),
                                 parent: layer.parent, order: layer.order,
                                 additive: layer.blendMode == "additive",
                                 origin: SIMD3(layer.origin.x, layer.origin.y, layer.originZ),
                                 scale: SIMD2(layer.scale.x, layer.scale.y), tint: tint,
                                 visible: layer.initialVisible)
            attachScripts(bb, sources: layer.propertyScripts)
            billboards.append(bb)
            bbLoaded += 1
        }

        // ── per-frame 평가/그리기 순서(씬 order). 평가는 스크립트 보유 노드/빌보드만. ──
        var evalItems: [(order: Int, bb: Bool, idx: Int)] = []
        for (i, n) in nodes3D.enumerated() where !n.scripts.isEmpty { evalItems.append((n.order, false, i)) }
        for (i, b) in billboards.enumerated() where !b.scripts.isEmpty { evalItems.append((b.order, true, i)) }
        eval3DOrder = evalItems.sorted { $0.order < $1.order }
        var drawItems: [(order: Int, bb: Bool, idx: Int)] = []
        for (i, m) in meshRenderables.enumerated() { drawItems.append((m.order, false, i)) }
        for (i, b) in billboards.enumerated() { drawItems.append((b.order, true, i)) }
        draw3DOrder = drawItems.sorted { $0.order < $1.order }
        // 카메라 스크립트 또는 활성 애니(스키닝) 가 있으면 연속 렌더 필요.
        let hasSkinAnim = meshRenderables.contains { $0.animIndex >= 0 }
        has3DScripts = !eval3DOrder.isEmpty || !cameraScripts.isEmpty || hasSkinAnim

        NSLog("%@", "[Waple] 3D scene: \(loaded) meshes (\(skipped) skipped), \(bbLoaded) billboards (\(bbSkipped) skipped), " +
              "\(nodes3D.count) nodes, \(eval3DOrder.count) scripted, lights=\(doc.lights3D.count)")
    }

    /// 노드/빌보드에 프로퍼티 스크립트 엔진 부착(씬 공유 컨텍스트 — top-level 사이드이펙트가 로드 시점에 실행).
    private func attachScripts(_ n: Node3D, sources: [String: String]) {
        for key in ["visible", "origin", "angles", "scale"] {
            guard let src = sources[key], let e = makeScriptEngine(src) else { continue }
            n.scripts.append(Script3D(key: key, engine: e))
        }
    }
    private func attachScripts(_ b: Billboard3D, sources: [String: String]) {
        for key in ["visible", "origin", "scale", "color", "alpha"] {
            guard let src = sources[key], let e = makeScriptEngine(src) else { continue }
            b.scripts.append(Script3D(key: key, engine: e))
        }
    }

    private struct Mesh3DMaterialInfo {
        let texture: MTLTexture
        let tint: SIMD4<Float>
        let alphaCutoff: Float
        let cullBack: Bool
        let additive: Bool
        let depthTest: Bool
        let depthWrite: Bool
    }

    /// 머티리얼 JSON(passes[0]) → 텍스처/블렌드/컬/뎁스 플래그. 로드 실패 → 흰 텍스처 + 기본 플래그.
    /// 규약: textures[] 첫 non-null 이름 → "materials/<이름>.tex"(resolveTexture 폴백 포함).
    private func loadMesh3DMaterial(_ path: String, package: ScenePackage, device: MTLDevice) -> Mesh3DMaterialInfo {
        var texName: String? = nil
        var color = SIMD3<Float>(1, 1, 1)
        var alpha: Float = 1
        var cullBack = true
        var additive = false
        var alphaCutoff: Float = 0
        var depthTest = true, depthWrite = true
        if let d = quietAssetData(path, package: package),
           let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let p0 = (j["passes"] as? [Any])?.first as? [String: Any] {
            texName = (p0["textures"] as? [Any])?.compactMap { $0 as? String }.first { !$0.isEmpty }
            cullBack = (p0["cullmode"] as? String) != "nocull"
            let blend = (p0["blending"] as? String) ?? "normal"
            additive = blend == "additive"
            if blend == "alphatocoverage" { alphaCutoff = 0.5 }  // MSAA 없는 컷아웃 근사(discard)
            depthTest = (p0["depthtest"] as? String) != "disabled"
            depthWrite = (p0["depthwrite"] as? String) != "disabled"
            if let csv = p0["constantshadervalues"] as? [String: Any] {
                func fvec(_ any: Any?) -> [Float]? {
                    if let s = any as? String { return s.split(separator: " ").compactMap { Float($0) } }
                    if let n = any as? Double { return [Float(n)] }
                    if let i = any as? Int { return [Float(i)] }
                    if let d = any as? [String: Any] { return fvec(d["value"]) }  // 스크립트 바인딩 → 초기값
                    return nil
                }
                if let c = fvec(csv["Color"] ?? csv["color"]), c.count >= 3 { color = SIMD3(c[0], c[1], c[2]) }
                if let a = fvec(csv["Alpha"] ?? csv["alpha"])?.first { alpha = a }
            }
        } else {
            NSLog("%@", "[Waple] 3D: material json missing: \(path)")
        }
        let tex = resolveTexture(texName, package: package, device: device)
            ?? makeTexture(Data([255, 255, 255, 255]), 1, 1, device)!
        return Mesh3DMaterialInfo(texture: tex, tint: SIMD4(color.x, color.y, color.z, alpha),
                                  alphaCutoff: alphaCutoff, cullBack: cullBack, additive: additive,
                                  depthTest: depthTest, depthWrite: depthWrite)
    }

    /// 메시 파이프라인(bgra8 + depth32Float). 프래그먼트가 premultiplied 출력 → src=one,
    /// over: dst=1-srcAlpha, additive: dst=one(가산). vertex = "mv_main"(정적) | "mv_skin"(GPU 스키닝).
    private func mesh3DPipeline(lib: MTLLibrary, vertex: String, additive: Bool, device: MTLDevice) -> MTLRenderPipelineState? {
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: vertex)
        pd.fragmentFunction = lib.makeFunction(name: "mf_main")
        pd.depthAttachmentPixelFormat = .depth32Float
        let a = pd.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: pd)
    }

    private func meshDepthState(test: Bool, write: Bool, device: MTLDevice) -> MTLDepthStencilState? {
        let key = "\(test)-\(write)"
        if let s = meshDepthStates[key] { return s }
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = test ? .less : .always
        d.isDepthWriteEnabled = write
        guard let s = device.makeDepthStencilState(descriptor: d) else { return nil }
        meshDepthStates[key] = s
        return s
    }

    /// 뎁스 텍스처(크기별 캐시). 메시 패스 전용 — 컬러 풀(pooledOffscreen)과 분리.
    private func pooledDepth(_ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let key = "\(max(w, 1))x\(max(h, 1))"
        if let t = depthTextures[key] { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                         width: max(w, 1), height: max(h, 1), mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        depthTextures[key] = t
        return t
    }

    /// 3D 메시 패스: target 에 clearColor 로 클리어 + 뎁스(.less) 붙여 씬 순서대로 드로우.
    /// 실측 확정 규약(3737268876/3662790108/3706286085 A/B 캡처 vs preview, 2026-07-03):
    ///   • 와인딩: front = CCW — 우수(RH) lookAt/proj 아래 CW 는 젤다 회랑이 인사이드아웃
    ///     (근접 벽 컬링 → 뒤 외벽 노출), CCW 는 벽/바닥/아치가 preview 와 일치
    ///   • UV 원점: 상단(v 플립 없음) — 플립 시 담쟁이/이끼가 벽 상단으로 감(Mesh3DShaders 주석)
    ///   • fov: 세로축 — 젤다 회랑 상하 구도가 정합(가로 해석은 세로 화각 29° 로 좁아져 아치 잘림).
    ///     코퍼스 3씬 전부 fov 50 이라 축 구분 실물 반례는 없음(표준 규약 채택)
    ///   • 오일러: Rz·Ry·Rx (Scene3DMath.modelMatrix 주석 — 짐벌 동치 실측)
    private func encode3D(into target: MTLTexture, cb: MTLCommandBuffer, device: MTLDevice, time: Float) -> Bool {
        guard let cam = camera3D, let over = meshPipelineOver,
              let depthTex = pooledDepth(target.width, target.height, device) else { return false }
        // per-frame 스크립트 평가(씬 order — 컨트롤러가 이를 읽는 스크립트보다 먼저) → 현재 로컬 변환/가시성.
        for e in eval3DOrder {
            if e.bb { billboards[e.idx].evaluateScripts(time: time) }
            else { nodes3D[e.idx].evaluateScripts(time: time) }
        }
        // 현재 로컬 변환으로 계층 노드 맵 재구성(월드행렬 합성 입력).
        var nmap: [Int: Scene3DMath.Node] = [:]
        nmap.reserveCapacity(nodes3D.count)
        for n in nodes3D {
            nmap[n.id] = Scene3DMath.Node(origin: n.origin, angles: n.angles, scale: n.scale,
                                          parent: n.parent, visible: n.visible)
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clearColor
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return false }
        let aspect = Float(target.width) / Float(max(1, target.height))
        // 카메라 프로퍼티 스크립트 per-frame 재평가(eye/center/up → Vec3, fov → 스칼라). 무스크립트면 base 고정.
        var eye = SIMD3(cam.eye.x, cam.eye.y, cam.eye.z)
        var ctr = SIMD3(cam.center.x, cam.center.y, cam.center.z)
        var upv = SIMD3(cam.up.x, cam.up.y, cam.up.z)
        var fov = cam.fov
        for sc in cameraScripts {
            sc.engine.setRuntime(Double(time))
            switch sc.key {
            case "eye":    if let v = sc.engine.evaluateVec(current: [eye.x, eye.y, eye.z]), v.count >= 3 { eye = SIMD3(v[0], v[1], v[2]) }
            case "center": if let v = sc.engine.evaluateVec(current: [ctr.x, ctr.y, ctr.z]), v.count >= 3 { ctr = SIMD3(v[0], v[1], v[2]) }
            case "up":     if let v = sc.engine.evaluateVec(current: [upv.x, upv.y, upv.z]), v.count >= 3 { upv = SIMD3(v[0], v[1], v[2]) }
            case "fov":    if let v = sc.engine.evaluateVec(current: [fov]), let f = v.first, f > 0 { fov = f }
            default: break
            }
        }
        let view = Scene3DMath.lookAt(eye: eye, center: ctr, up: upv)
        let proj = Scene3DMath.perspective(fovYDegrees: fov, aspect: aspect,
                                           nearZ: cam.nearZ, farZ: cam.farZ)
        let viewProj = proj * view
        // 빌보드 카메라-페이싱 축(월드): right/up(lookAt 과 동일 규약).
        let fwd = simd_normalize(ctr - eye)
        let right = simd_normalize(simd_cross(fwd, upv))
        let camUp = simd_cross(right, fwd)
        // 와인딩: front = CCW(A/B 실측 — CW 는 젤다 회랑이 인사이드아웃: 근접 벽이 컬링되어
        // 뒤쪽 외벽이 보임). cullmode "normal" 메시가 CCW-front 백페이스 컬에서 preview 와 일치.
        enc.setFrontFacing(.counterClockwise)
        let debug3D = ProcessInfo.processInfo.environment["WAPLE3D_DEBUG"] == "1"
        for item in draw3DOrder {
            if item.bb {
                encodeBillboard(billboards[item.idx], viewProj: viewProj, right: right, up: camUp,
                                nmap: nmap, into: enc, device: device, over: over)
            } else {
                let mr = meshRenderables[item.idx]
                guard let w = Scene3DMath.worldMatrix(id: mr.id, nodes: nmap), w.visible else { continue }
                if debug3D {
                    let c = viewProj * w.matrix * SIMD4<Float>(0, 0, 0, 1)
                    NSLog("%@", "[Waple3D] draw '\(mr.name)' ndc=\(c.w != 0 ? SIMD3(c.x, c.y, c.z) / c.w : .zero) w=\(c.w)")
                }
                var u = MeshUniform(mvp: viewProj * w.matrix, tint: SIMD4(1, 1, 1, 1), misc: SIMD4(0, 0, 0, 0))
                // 스키닝 모델: 프레임당 본행렬(skin=world(t)×bindWorld⁻¹) 계산 → boneBuffer memcpy(정적 애니는 항등).
                var skinReady = false
                if let model = mr.model, let bb = mr.boneBuffer, !model.bones.isEmpty {
                    let mats = Model3DPose.skinMatrices(model: model, animation: mr.animIndex, time: time, rate: mr.animRate)
                    if !mats.isEmpty {
                        let bytes = min(bb.length, mats.count * MemoryLayout<simd_float4x4>.stride)
                        mats.withUnsafeBytes { memcpy(bb.contents(), $0.baseAddress!, bytes) }
                        skinReady = true
                    }
                }
                for mesh in mr.meshes {
                    // 스키닝 메시(16f 패킹)는 반드시 스키닝 파이프라인 필요 — 본버퍼 미준비면 스킵(8f 셰이더로 오독 방지).
                    if mesh.skinned && !skinReady { continue }
                    u.tint = mesh.tint
                    u.misc.x = mesh.alphaCutoff
                    let useSkin = mesh.skinned && skinReady
                    let pipe: MTLRenderPipelineState
                    if useSkin { pipe = mesh.additive ? (meshPipelineSkinAdditive ?? meshPipelineSkin ?? over) : (meshPipelineSkin ?? over) }
                    else { pipe = mesh.additive ? (meshPipelineAdditive ?? over) : over }
                    enc.setRenderPipelineState(pipe)
                    if let ds = meshDepthState(test: mesh.depthTest, write: mesh.depthWrite, device: device) {
                        enc.setDepthStencilState(ds)
                    }
                    enc.setCullMode(mesh.cullBack ? .back : .none)
                    enc.setVertexBuffer(mesh.vbuf, offset: 0, index: 0)
                    enc.setVertexBytes(&u, length: MemoryLayout<MeshUniform>.stride, index: 1)
                    if useSkin, let bb = mr.boneBuffer { enc.setVertexBuffer(bb, offset: 0, index: 2) }
                    enc.setFragmentBytes(&u, length: MemoryLayout<MeshUniform>.stride, index: 1)
                    enc.setFragmentTexture(mesh.texture, index: 0)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                              indexType: .uint16, indexBuffer: mesh.ibuf, indexBufferOffset: 0)
                }
            }
        }
        enc.endEncoding()
        return true
    }

    /// 카메라-페이싱 빌보드 1장: 월드 위치 = (부모월드 · 로컬변환) 원점, 반경 = size/2 × 합성 스케일.
    /// 쿼드 4코너를 카메라 right/up 축으로 전개(월드 좌표) → mvp=viewProj. 뎁스 테스트 유지·미기록(투명),
    /// 양면, over(premult) 블렌드. 부모 서브트리 비가시/자기 비가시면 스킵.
    private func encodeBillboard(_ bb: Billboard3D, viewProj: simd_float4x4,
                                 right: SIMD3<Float>, up: SIMD3<Float>, nmap: [Int: Scene3DMath.Node],
                                 into enc: MTLRenderCommandEncoder, device: MTLDevice, over: MTLRenderPipelineState) {
        var pWorld = matrix_identity_float4x4
        if let pid = bb.parent {
            guard let pw = Scene3DMath.worldMatrix(id: pid, nodes: nmap), pw.visible else { return }
            pWorld = pw.matrix
        }
        if !bb.visible { return }
        // 로컬: 이동(origin) + 스케일(빌보드는 카메라-페이싱이라 로컬 회전은 무시). 부모월드가 나머지 계층 폴드.
        let local = Scene3DMath.modelMatrix(origin: bb.origin, angles: SIMD3<Float>(0, 0, 0),
                                            scale: SIMD3(bb.scale.x, bb.scale.y, 1))
        let m = pWorld * local
        let center = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        // 합성 스케일 크기(부모 스케일 포함) — 열 벡터 길이가 회전 무관하게 축별 배율을 준다.
        let sx = simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let sy = simd_length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        let hw = bb.size.x * 0.5 * sx
        let hh = bb.size.y * 0.5 * sy
        guard hw > 0, hh > 0, hw.isFinite, hh.isFinite else { return }
        let r = right * hw, u = up * hh
        // UV 상단 원점: 상단 = +up. TL(0,0) TR(1,0) BR(1,1) BL(0,1).
        let tl = center - r + u, tr = center + r + u, br = center + r - u, bl = center - r - u
        func vtx(_ p: SIMD3<Float>, _ uu: Float, _ vv: Float) -> [Float] { [p.x, p.y, p.z, 0, 0, 0, uu, vv] }
        var verts: [Float] = []
        verts.reserveCapacity(48)
        verts += vtx(tl, 0, 0); verts += vtx(tr, 1, 0); verts += vtx(br, 1, 1)
        verts += vtx(tl, 0, 0); verts += vtx(br, 1, 1); verts += vtx(bl, 0, 1)
        guard let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<Float>.stride * verts.count) else { return }
        var u2 = MeshUniform(mvp: viewProj, tint: bb.tint, misc: SIMD4(0, 0, 0, 0))
        // 머티리얼 blending=additive → 가산 파이프라인(플레어/글로우 광량 복원). 그 외 premult-over.
        enc.setRenderPipelineState(bb.additive ? (meshPipelineAdditive ?? over) : over)
        if let ds = meshDepthState(test: true, write: false, device: device) { enc.setDepthStencilState(ds) }
        enc.setCullMode(.none)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&u2, length: MemoryLayout<MeshUniform>.stride, index: 1)
        enc.setFragmentBytes(&u2, length: MemoryLayout<MeshUniform>.stride, index: 1)
        enc.setFragmentTexture(bb.texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }


    /// 파티클 스냅샷 → 인터리브드 버텍스(정점당 8 float: ndc.xy, uv, rgba).
    /// sprite = 빌보드 쿼드. trail = 위치 히스토리 폴리라인을 두께 있는 리본(삼각 스트립)으로.
    private func particleVertices(_ snapshot: [Particle], _ sys: GPUParticleSystem) -> [Float] {
        var verts: [Float] = []
        verts.reserveCapacity(snapshot.count * (sys.isTrail ? 200 : 48))
        func toNDC(_ x: Float, _ y: Float) -> (Float, Float) { (x / projW * 2 - 1, 1 - y / projH * 2) }
        func appendQuad(_ p: Particle) {
            let wx = sys.origin.x + sys.scale.x * p.pos.x
            let wy = sys.origin.y - sys.scale.y * p.pos.y
            let sizePx = p.size * sys.scale.x
            let hw = sizePx * 0.5, hh = sizePx * sys.texRatio * 0.5
            let ca = cos(p.rotation.z), sa = sin(p.rotation.z)
            func ndc(_ lx: Float, _ ly: Float) -> (Float, Float) {
                return toNDC(wx + lx * ca - ly * sa, wy + lx * sa + ly * ca)
            }
            let tl = ndc(-hw, -hh), tr = ndc(hw, -hh), br = ndc(hw, hh), bl = ndc(-hw, hh)
            let r = p.color.x, g = p.color.y, b = p.color.z, al = p.alpha
            func v(_ pt: (Float, Float), _ u: Float, _ vv: Float) {
                verts.append(contentsOf: [pt.0, pt.1, u, vv, r, g, b, al])
            }
            v(tl, 0, 0); v(tr, 1, 0); v(br, 1, 1)
            v(tl, 0, 0); v(br, 1, 1); v(bl, 0, 1)
        }
        for p in snapshot {
            if sys.isTrail {
                // 리본이 붕괴(정지 rope 등)면 false → 쿼드 폴백. inout verts 를 클로저와 동시
                // 접근하지 않도록 순차 호출(Swift 배타적 접근 위반 방지).
                if !appendRibbon(p, sys, into: &verts) { appendQuad(p) }
            } else {
                appendQuad(p)
            }
        }
        return verts
    }

    /// 파티클 위치 히스토리(oldest→newest) → 두께 있는 리본. 폭 = size_px, 텍스처 u 는 길이 방향,
    /// v 는 가로. 알파는 tail(oldest)=0 → head(newest)=full 로 코멧 페이드. 세그먼트 접선의 수직으로
    /// ±half-width 오프셋해 삼각 스트립을 만든다.
    /// 붕괴(정지 rope, mouse-follow 헤드리스) 시 false 반환 → 호출자가 쿼드 폴백(NaN/블랭크 방지).
    private func appendRibbon(_ p: Particle, _ sys: GPUParticleSystem, into verts: inout [Float]) -> Bool {
        func toNDC(_ x: Float, _ y: Float) -> (Float, Float) { (x / projW * 2 - 1, 1 - y / projH * 2) }
        let h = p.history
        // 월드 px 로 변환.
        var pts: [(Float, Float)] = []
        pts.reserveCapacity(h.count)
        for q in h { pts.append((sys.origin.x + sys.scale.x * q.x, sys.origin.y - sys.scale.y * q.y)) }
        // 유효 스팬 판정: bbox 대각선이 1px 미만이면 붕괴 → 쿼드.
        guard pts.count >= 2 else { return false }
        var minX = pts[0].0, maxX = pts[0].0, minY = pts[0].1, maxY = pts[0].1
        for pt in pts { minX = min(minX, pt.0); maxX = max(maxX, pt.0); minY = min(minY, pt.1); maxY = max(maxY, pt.1) }
        if (maxX - minX) + (maxY - minY) < 1 { return false }

        let n = pts.count
        let hw = max(0.5, p.size * sys.scale.x * 0.5)  // 리본 반폭(px)
        let r = p.color.x, g = p.color.y, b = p.color.z
        // 접선(중앙차분, 끝은 편차). 0-길이는 직전 유효 접선 계승(NaN 방지 — normalizeSafe 미러).
        var lastT: (Float, Float) = (1, 0)
        func tangent(_ i: Int) -> (Float, Float) {
            let a = pts[max(0, i - 1)], c = pts[min(n - 1, i + 1)]
            let dx = c.0 - a.0, dy = c.1 - a.1
            let len = sqrtf(dx * dx + dy * dy)
            if len > 1e-4 { lastT = (dx / len, dy / len) }
            return lastT
        }
        // 각 히스토리 포인트의 좌/우 엣지 정점(ndc, u, alpha).
        var edges: [(a: (Float, Float), bEdge: (Float, Float), u: Float, alpha: Float)] = []
        edges.reserveCapacity(n)
        for i in 0..<n {
            let t = tangent(i)
            let nx = -t.1 * hw, ny = t.0 * hw            // 수직 오프셋(px)
            let A = toNDC(pts[i].0 + nx, pts[i].1 + ny)
            let B = toNDC(pts[i].0 - nx, pts[i].1 - ny)
            let u = Float(i) / Float(n - 1)
            edges.append((A, B, u, p.alpha * u))          // tail(u=0)=투명 → head=불투명
        }
        func push(_ pt: (Float, Float), _ u: Float, _ vv: Float, _ al: Float) {
            verts.append(contentsOf: [pt.0, pt.1, u, vv, r, g, b, al])
        }
        for i in 0..<(n - 1) {
            let e0 = edges[i], e1 = edges[i + 1]
            // 쿼드 (A0,B0,B1,A1) → 삼각 2개. u 는 길이, v 는 가로(0/1).
            push(e0.a, e0.u, 0, e0.alpha); push(e0.bEdge, e0.u, 1, e0.alpha); push(e1.bEdge, e1.u, 1, e1.alpha)
            push(e0.a, e0.u, 0, e0.alpha); push(e1.bEdge, e1.u, 1, e1.alpha); push(e1.a, e1.u, 0, e1.alpha)
        }
        return true
    }

    private func effectPipeline(source: String, device: MTLDevice) -> MTLRenderPipelineState? {
        guard let lib = try? device.makeLibrary(source: source, options: nil) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "ev_main")
        pd.fragmentFunction = lib.makeFunction(name: "ef_main")
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        return try? device.makeRenderPipelineState(descriptor: pd)
    }

    private func makeOffscreen(_ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: max(w,1), height: max(h,1), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: d)
    }

    // 효과 패스용 오프스크린 텍스처 풀: 매 프레임 신규 할당(30fps×효과수) 대신 크기별로 재사용.
    // 프레임 내에서는 checkout 을 단조 증가시켜 항상 distinct 텍스처를 보장(src/dst 충돌 방지).
    // 프레임 간 재사용은 비-heap tracked 텍스처라 Metal 자동 hazard tracking 이 동기화를 보장(무손상).
    private var texturePool: [String: [MTLTexture]] = [:]
    private var poolCheckout: [String: Int] = [:]

    private func pooledOffscreen(_ w: Int, _ h: Int, _ device: MTLDevice, bgra: Bool = false) -> MTLTexture? {
        let key = "\(bgra ? "b" : "")\(max(w,1))x\(max(h,1))"
        let idx = poolCheckout[key, default: 0]
        if idx < (texturePool[key]?.count ?? 0) {
            poolCheckout[key] = idx + 1
            return texturePool[key]![idx]
        }
        guard let t = bgra ? makeOffscreenBGRA(w, h, device) : makeOffscreen(w, h, device) else { return nil }
        texturePool[key, default: []].append(t)
        poolCheckout[key] = idx + 1
        return t
    }

    /// 컴포지션(_rt_) 레이어 실행: 현재 encoder 를 닫고, acc 스냅샷(blit — 진행 중 타깃은 샘플 불가)에
    /// 레이어의 효과 체인을 적용한 뒤, 새 encoder(.load)로 레이어 지오메트리에 결과를 그린다.
    /// 반환된 encoder 로 나머지 drawPlan 을 계속한다. 실패 시 기존 흐름 유지 위해 새 encoder 만 연다.
    private func runFrameBufferLayer(_ layer: GPULayer, acc: MTLTexture, cb: MTLCommandBuffer,
                                     ending enc: MTLRenderCommandEncoder, device: MTLDevice, time: Float,
                                     camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) -> MTLRenderCommandEncoder? {
        enc.endEncoding()
        var srcTex: MTLTexture? = nil
        if let snap = pooledOffscreen(acc.width, acc.height, device, bgra: true),
           let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: acc, to: snap)
            blit.endEncoding()
            var current: MTLTexture = snap
            for eff in layer.effects {
                guard let next = pooledOffscreen(acc.width, acc.height, device) else { break }
                applyEffect(eff, src: current, dst: next, time: time, cb: cb)
                current = next
            }
            srcTex = current
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = acc
        rpd.colorAttachments[0].loadAction = .load
        guard let next = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        if let srcTex {
            // NOTE: acc 는 premultiplied 누적이라 스냅샷도 premult — straight 규약과의 미세 오차는
            // 불투명 배경(일반 씬)에선 없음(설계 §4). fit/fill 시 aspectScale 이중 적용 에지도 §3 참고.
            encodeLayer(layer, texture: srcTex, into: next, camOffset: &camOffset, aspectScale: &aspectScale)
        }
        return next
    }

    /// 헤드리스 캡처용 bgra8 타겟(라이브 파이프라인과 동일 포맷, getBytes 가능하도록 .shared).
    private func makeOffscreenBGRA(_ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: max(w,1), height: max(h,1), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    private func makeTexture(_ rgba: Data, _ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        rgba.withUnsafeBytes { ptr in
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: w * 4)
        }
        return t
    }

    /// 씬 픽셀 좌표(좌상단 원점, Y-down 가정) → NDC. Y-flip은 Task 7에서 실측 보정.
    private func quadVertices(layer: SceneLayer, projW: Float, projH: Float) -> [SIMD4<Float>] {
        quadVertices(origin: layer.origin, size: layer.size, scale: layer.scale, angleZ: layer.angleZ,
                     projW: projW, projH: projH)
    }

    /// 명시 파라미터 변형 — 프로퍼티 애니메이션의 per-frame 재계산용.
    private func quadVertices(origin: Vec2, size: Vec2, scale: Vec2, angleZ: Float,
                              projW: Float, projH: Float) -> [SIMD4<Float>] {
        let hw = size.x * scale.x * 0.5
        let hh = size.y * scale.y * 0.5
        let a = angleZ * .pi / 180
        let ca = cos(a), sa = sin(a)
        func corner(_ lx: Float, _ ly: Float) -> SIMD2<Float> {
            let rx = lx * ca - ly * sa, ry = lx * sa + ly * ca
            return SIMD2<Float>(origin.x + rx, origin.y + ry)
        }
        func ndc(_ p: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2<Float>(p.x / projW * 2 - 1, 1 - p.y / projH * 2)
        }
        let tl = ndc(corner(-hw, -hh)), tr = ndc(corner(hw, -hh))
        let br = ndc(corner(hw, hh)), bl = ndc(corner(-hw, hh))
        // uv: TL(0,0) TR(1,0) BR(1,1) BL(0,1)
        return [
            SIMD4<Float>(tl.x, tl.y, 0, 0), SIMD4<Float>(tr.x, tr.y, 1, 0), SIMD4<Float>(br.x, br.y, 1, 1),
            SIMD4<Float>(tl.x, tl.y, 0, 0), SIMD4<Float>(br.x, br.y, 1, 1), SIMD4<Float>(bl.x, bl.y, 0, 1),
        ]
    }

    /// 퍼펫 스킨 정점 → NDC 삼각형 리스트(quadVertices 와 동일 규약: 씬 픽셀 y-down, uv 그대로).
    /// 메시 좌표는 레이어 로컬 픽셀(원점 중심)·**y-up**(실측: 2809885105 프리뷰 대비 반전 확인) —
    /// y 부호 반전 후 origin/scale/angleZ 적용, NDC 변환.
    static func puppetVertices(model: PuppetModel, positions: [SIMD3<Float>],
                               origin: Vec2, scale: Vec2, angleZ: Float,
                               projW: Float, projH: Float) -> [SIMD4<Float>] {
        let a = angleZ * .pi / 180
        let ca = cos(a), sa = sin(a)
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(model.indices.count)
        for idx in model.indices {
            let i = Int(idx)
            guard i < positions.count else { continue }
            let p = positions[i]
            let lx = p.x * scale.x, ly = -p.y * scale.y
            let sx = origin.x + lx * ca - ly * sa
            let sy = origin.y + lx * sa + ly * ca
            out.append(SIMD4<Float>(sx / projW * 2 - 1, 1 - sy / projH * 2,
                                    model.vertices[i].uv.x, model.vertices[i].uv.y))
        }
        return out
    }

    private func updateParallax(_ off: CGPoint) {
        pointerUV = SceneRenderer.pointerUV(fromNormalized: off)
        if parallaxEnabled {
            let s = parallaxAmount * parallaxMouseInfluence * maxShift
            cameraOffset = SIMD2<Float>(Float(off.x) * s, Float(off.y) * s)
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

        // 3D 씬: 메시 + 빌보드 패스(뎁스, per-frame 스크립트) → drawable blit.
        if is3D {
            poolCheckout.removeAll(keepingCapacity: true)
            guard let acc = pooledOffscreen(drawable.texture.width, drawable.texture.height, device, bgra: true),
                  encode3D(into: acc, cb: cb, device: device, time: time) else { return }
            if let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: acc, to: drawable.texture)
                blit.endEncoding()
            }
            cb.present(drawable)
            cb.commit()
            return
        }

        refreshScriptedTexts(device: device)  // 초당 1회 update() 재평가(시계 등)
        // 효과 있는 레이어는 오프스크린 베이스→효과 패스 후 결과 텍스처로 교체.
        let displayTextures = buildDisplayTextures(device: device, queue: queue, time: time, cb: cb)

        var camOffset = cameraOffset
        // 종횡비 보정 — FitMode 설정에 따라.
        let ds = view.drawableSize
        let viewAspect = Float(ds.width / max(1, ds.height))
        var aspectScale: SIMD2<Float>
        switch SceneRenderSettings.fitMode {
        case .stretch:
            aspectScale = SIMD2<Float>(1, 1)
        case .fill:
            aspectScale = projAspect > viewAspect
                ? SIMD2<Float>(projAspect / viewAspect, 1) : SIMD2<Float>(1, viewAspect / projAspect)
        case .fit:
            aspectScale = projAspect > viewAspect
                ? SIMD2<Float>(1, viewAspect / projAspect) : SIMD2<Float>(projAspect / viewAspect, 1)
        }
        // 누적(acc) 합성: 컴포지션(_rt_) 레이어가 "그 시점까지의 화면"을 샘플할 수 있도록
        // 오프스크린에 합성 후 마지막에 drawable 로 blit(뷰는 mount 에서 framebufferOnly=false).
        guard let acc = pooledOffscreen(drawable.texture.width, drawable.texture.height, device, bgra: true) else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = acc
        rpd.colorAttachments[0].clearColor = clearColor
        rpd.colorAttachments[0].loadAction = .clear
        guard var enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        // 씬 오브젝트 순서대로 레이어·파티클·텍스트 인터리브(z-순서 — fg 레이어가 파티클을 가릴 수 있음).
        for item in drawPlan {
            switch item.kind {
            case .particle:
                let snapshot = particleSystems[item.idx].sim.step(dt)
                encodeParticle(particleSystems[item.idx], snapshot: snapshot, into: enc, device: device,
                               camOffset: &camOffset, aspectScale: &aspectScale)
            case .text:
                encodeText(textLayers[item.idx], into: enc, camOffset: &camOffset, aspectScale: &aspectScale)
            case .layer where layers[item.idx].isFrameBuffer:
                guard let next = runFrameBufferLayer(layers[item.idx], acc: acc, cb: cb, ending: enc,
                                                     device: device, time: time,
                                                     camOffset: &camOffset, aspectScale: &aspectScale) else { return }
                enc = next
            case .layer:
                encodeLayer(layers[item.idx], texture: displayTextures[item.idx], into: enc,
                            camOffset: &camOffset, aspectScale: &aspectScale, time: time, device: device)
            }
        }
        enc.endEncoding()
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: acc, to: drawable.texture)
            blit.endEncoding()
        }
        cb.present(drawable)
        cb.commit()
    }

    /// 이미지 레이어 1개 드로우(메인 컴포지트 파이프라인). time/device 는 프로퍼티 애니메이션 평가용
    /// (def 있는 레이어만 per-frame 재계산 — origin/scale/angles → 쿼드, alpha/color → tint).
    private func encodeLayer(_ layer: GPULayer, texture: MTLTexture, into enc: MTLRenderCommandEncoder,
                             camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>,
                             time: Float = 0, device: MTLDevice? = nil) {
        guard let pipeline else { return }
        var tint = layer.tint
        var vbuf = layer.vertexBuffer
        if let def = layer.def, let device {
            func animValue(_ key: String, _ comp: Int, _ base: Float) -> Float {
                def.animations[key]?.value(component: comp, atTime: time, base: base) ?? base
            }
            let origin = Vec2(x: animValue("origin", 0, def.origin.x), y: animValue("origin", 1, def.origin.y))
            let scale = Vec2(x: animValue("scale", 0, def.scale.x), y: animValue("scale", 1, def.scale.y))
            let angle = animValue("angles", 2, def.angleZ)
            if def.animations["origin"] != nil || def.animations["scale"] != nil || def.animations["angles"] != nil {
                let verts = quadVertices(origin: origin, size: def.size, scale: scale, angleZ: angle,
                                         projW: projW, projH: projH)
                if let b = device.makeBuffer(bytes: verts, length: MemoryLayout<SIMD4<Float>>.stride * verts.count) {
                    vbuf = b
                }
            }
            if def.animations["alpha"] != nil || def.animations["color"] != nil {
                let a = animValue("alpha", 0, def.alpha)
                let c = Vec3(x: animValue("color", 0, def.color.x), y: animValue("color", 1, def.color.y), z: animValue("color", 2, def.color.z))
                tint = SIMD4(c.x * def.brightness, c.y * def.brightness, c.z * def.brightness, a)
            }
        }
        // 프로퍼티 스크립트: update(현재값) → visible/color/alpha 갱신(미디어 컬러 전환 등 — 이벤트
        // 없으면 스크립트 초기 상태값이 정답: 실물 ColorTinter 는 Vec3(0,0,0) 시작 = 다크).
        // 모든 스크립트를 먼저 평가(shared 사이드이펙트 보존)한 뒤 visible 이 거짓이면 draw 스킵.
        for sc in layer.propScripts {
            sc.engine.setRuntime(Double(time))
            if sc.key == "color", let v = sc.engine.evaluateVec(current: [tint.x, tint.y, tint.z]), v.count >= 3 {
                let b = layer.def?.brightness ?? 1
                tint = SIMD4(v[0] * b, v[1] * b, v[2] * b, tint.w)
            } else if sc.key == "alpha", let v = sc.engine.evaluateVec(current: [tint.w]), let a = v.first {
                tint.w = a
            } else if sc.key == "visible" {
                let cur = scriptVisible[layer.order] ?? layer.initialVisible
                scriptVisible[layer.order] = sc.engine.evaluateBool(current: cur) ?? cur
            }
        }
        // visible 스크립트 평가값(또는 정적 초기값)이 거짓 → draw 스킵(레이어는 유지 — 런타임 토글 가능).
        if !(scriptVisible[layer.order] ?? layer.initialVisible) { return }
        var vertexCount = 6
        // 퍼펫: per-frame CPU 스키닝 → 메시 삼각형 리스트로 쿼드 대체.
        if let pm = layer.puppet, let def = layer.def, let device {
            let mats = PuppetPose.skinMatrices(model: pm, animation: 0, time: time)
            let pos = PuppetPose.skinnedPositions(model: pm, matrices: mats)
            let verts = SceneRenderer.puppetVertices(model: pm, positions: pos,
                                                     origin: def.origin, scale: def.scale, angleZ: def.angleZ,
                                                     projW: projW, projH: projH)
            if !verts.isEmpty,
               let b = device.makeBuffer(bytes: verts, length: MemoryLayout<SIMD4<Float>>.stride * verts.count) {
                vbuf = b
                vertexCount = verts.count
            }
        }
        var depth = layer.parallaxDepth
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.setVertexBytes(&depth, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        enc.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }

    /// 텍스트 오브젝트 준비: 폰트 바이트(pkg→base-assets) + 스크립트 엔진 + 초기 텍스트 래스터.
    private func buildTexts(doc: SceneDocument, package: ScenePackage, device: MTLDevice) -> [GPUText] {
        var out: [GPUText] = []
        for t in doc.texts {
            let isSystem = t.font.hasPrefix("systemfont_") || t.font.isEmpty
            let fontData = isSystem ? nil : quietAssetData(t.font, package: package)
            if !isSystem && fontData == nil { NSLog("%@", "[Waple] text font missing (system fallback): \(t.font)") }
            // 씬 공유 컨텍스트 로드(top-level 사이드이펙트 실행). update 없는 스크립트는 텍스트 갱신에
            // 못 쓰므로 엔진 nil 취급(정적 텍스트 유지) — 로드 자체는 shared 통신을 위해 수행.
            let loaded = t.script.flatMap { makeScriptEngine($0) }
            if t.script != nil && loaded == nil { NSLog("%@", "[Waple] text script failed to load (empty text): \(t.script!.prefix(60))") }
            let engine = (loaded?.hasUpdate == true) ? loaded : nil
            let initial = engine != nil ? (engine!.evaluate(current: t.text) ?? "") : t.text
            var g = GPUText(texture: nil, vertexBuffer: nil,
                            tint: SIMD4(t.color.x, t.color.y, t.color.z, t.alpha),
                            order: t.order, engine: engine, lastText: initial,
                            fontData: fontData, systemFontName: isSystem ? t.font : nil, def: t)
            rasterize(&g, device: device)
            if engine != nil { hasScriptedText = true }
            out.append(g)
        }
        return out
    }

    /// 텍스트 재래스터: lastText → 텍스처 + 앵커 정렬 쿼드. 빈 텍스트 → 텍스처 nil(드로우 스킵).
    private func rasterize(_ g: inout GPUText, device: MTLDevice) {
        guard let r = TextRasterizer.render(text: g.lastText, fontData: g.fontData,
                                            systemFontName: g.systemFontName, pointSize: g.def.pointSize) else {
            g.texture = nil; g.vertexBuffer = nil
            return
        }
        g.texture = makeTexture(r.rgba, r.width, r.height, device)
        let w = Float(r.width) * g.def.scale.x, h = Float(r.height) * g.def.scale.y
        let x0: Float
        switch g.def.horizontalAlign {
        case "left": x0 = g.def.origin.x
        case "right": x0 = g.def.origin.x - w
        default: x0 = g.def.origin.x - w / 2
        }
        let y0: Float
        switch g.def.verticalAlign {
        case "top": y0 = g.def.origin.y
        case "bottom": y0 = g.def.origin.y - h
        default: y0 = g.def.origin.y - h / 2
        }
        func ndc(_ px: Float, _ py: Float) -> SIMD2<Float> { SIMD2(px / projW * 2 - 1, 1 - py / projH * 2) }
        let tl = ndc(x0, y0), tr = ndc(x0 + w, y0), br = ndc(x0 + w, y0 + h), bl = ndc(x0, y0 + h)
        let verts: [SIMD4<Float>] = [
            SIMD4(tl.x, tl.y, 0, 0), SIMD4(tr.x, tr.y, 1, 0), SIMD4(br.x, br.y, 1, 1),
            SIMD4(tl.x, tl.y, 0, 0), SIMD4(br.x, br.y, 1, 1), SIMD4(bl.x, bl.y, 0, 1),
        ]
        g.vertexBuffer = device.makeBuffer(bytes: verts, length: MemoryLayout<SIMD4<Float>>.stride * verts.count)
    }

    /// 스크립트 텍스트 초당 재평가(시계 등). 변경 시에만 재래스터.
    private func refreshScriptedTexts(device: MTLDevice) {
        guard hasScriptedText else { return }
        let sec = Int(CFAbsoluteTimeGetCurrent())
        guard sec != lastTextRefreshSecond else { return }
        lastTextRefreshSecond = sec
        for i in textLayers.indices {
            guard let e = textLayers[i].engine else { continue }
            let newText = e.evaluate(current: textLayers[i].lastText) ?? ""
            if newText != textLayers[i].lastText {
                textLayers[i].lastText = newText
                rasterize(&textLayers[i], device: device)
            }
        }
    }

    /// 텍스트 1개 드로우(메인 컴포지트 파이프라인, parallaxDepth=1).
    private func encodeText(_ t: GPUText, into enc: MTLRenderCommandEncoder,
                            camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) {
        guard let pipeline, let tex = t.texture, let vbuf = t.vertexBuffer else { return }
        var tint = t.tint
        var depth = SIMD2<Float>(1, 1)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.setVertexBytes(&depth, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        enc.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// 파티클 시스템 1개의 스냅샷을 빌보드 쿼드로 드로우(additive/translucent).
    private func encodeParticle(_ sys: GPUParticleSystem, snapshot: [Particle], into enc: MTLRenderCommandEncoder,
                                device: MTLDevice, camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) {
        guard !snapshot.isEmpty,
              let pipe = sys.blendAdditive ? additivePipeline : translucentPipeline else { return }
        let verts = particleVertices(snapshot, sys)
        // 트레일은 파티클당 정점 수가 가변(붕괴 시 0) — 빈 버텍스면 드로우 스킵.
        let vertexCount = verts.count / 8
        guard vertexCount > 0,
              let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<Float>.stride * verts.count) else { return }
        enc.setRenderPipelineState(pipe)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        enc.setFragmentTexture(sys.texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }

    /// 효과가 있는 레이어는 원본 텍스처를 첫 src 로 삼아 효과 패스 체인을 적용한 결과 텍스처를, 없으면 원본을 반환.
    /// 라이브 draw 와 헤드리스 captureFrames 가 공유.
    private func buildDisplayTextures(device: MTLDevice, queue: MTLCommandQueue, time: Float, cb: MTLCommandBuffer) -> [MTLTexture] {
        poolCheckout.removeAll(keepingCapacity: true)  // 프레임 시작: 모든 풀 텍스처를 재사용 가능 상태로
        var out: [MTLTexture] = []
        for layer in layers {
            // 컴포지션 레이어의 효과는 사전 계산 불가(src = 그 시점 프레임버퍼 스냅샷) — draw 루프에서 처리.
            if layer.effects.isEmpty || layer.isFrameBuffer { out.append(layer.texture); continue }
            // 베이스 복사 불필요: 원본 텍스처를 직접 첫 src 로 사용(아래 루프는 항상 새 dst 로 출력).
            var current = layer.texture
            for eff in layer.effects {
                guard let next = pooledOffscreen(layer.texWidth, layer.texHeight, device) else { break }
                applyEffect(eff, src: current, dst: next, time: time, cb: cb)
                current = next
            }
            out.append(current)
        }
        return out
    }

    private func applyEffect(_ eff: EffectGPU, src: MTLTexture, dst: MTLTexture, time: Float, cb: MTLCommandBuffer) {
        switch eff.bind {
        case .handPort(let params, let aux, let audio):
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = dst
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
            enc.setRenderPipelineState(eff.pipeline)
            enc.setVertexBuffer(effectVertexBuffer, offset: 0, index: 0)
            enc.setFragmentTexture(src, index: 0)  // g_Texture0 = framebuffer
            for (i, t) in aux.enumerated() { enc.setFragmentTexture(t, index: i + 1) }  // aux slot i → texture(i+1)
            let buf = [time] + params
            buf.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            // 오디오 응답(현재 스펙트럼 + 효과 오디오 파라미터) → buffer(1). pulse 등 오디오 효과가 소비.
            var audioResp: Float = 0
            if let a = audio {
                audioResp = AudioResponse.compute(left: currentSpectrum.left, right: currentSpectrum.right,
                                                  mode: a.mode, freqMin: a.freqMin, freqMax: a.freqMax,
                                                  bounds: a.bounds, power: a.power, multiply: a.multiply)
            }
            enc.setFragmentBytes(&audioResp, length: MemoryLayout<Float>.stride, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()

        case .translated(var passes, let fboScales):
            // 디버그: WAPLE_MP_TRUNC=n → 앞 n개 패스만 실행(마지막은 dst 로 강제) — 패스별 이분용.
            if let t = ProcessInfo.processInfo.environment["WAPLE_MP_TRUNC"], let n = Int(t), n > 0, n < passes.count {
                passes = Array(passes.prefix(n))
                let last = passes.removeLast()
                passes.append(TranslatedPass(pipeline: last.pipeline, material: last.material, aux: last.aux,
                                             binds: last.binds, target: nil, usesAudio: last.usesAudio,
                                             texRes: last.texRes, scripts: last.scripts))
            }
            // 멀티패스: 이름 있는 FBO(다운스케일)를 풀에서 할당하고, 각 패스를 target(fbo|dst)에 순차 실행.
            let baseW = max(1, dst.width), baseH = max(1, dst.height)
            var fboTex: [MTLTexture] = []
            for s in fboScales {
                guard let t = pooledOffscreen(max(1, baseW / s), max(1, baseH / s), device!) else { return }
                fboTex.append(t)
            }
            for pass in passes {
                let target = pass.target.map { fboTex[$0] } ?? dst
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = target
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
                enc.setRenderPipelineState(pass.pipeline)
                // 변환본 규약: 인터리브드 쿼드 buffer(4), p buffer(0)·EngineU buffer(1) 는 vert+frag 양쪽.
                enc.setVertexBuffer(effectQuadInterleaved, offset: 0, index: 4)
                if !pass.material.isEmpty {
                    var mat = pass.material
                    // 상수 프로퍼티 스크립트: update(현재값) → 슬롯 갱신(컬러 사이클 등 시간 함수).
                    for sc in pass.scripts {
                        sc.engine.setRuntime(Double(time))
                        let cur = mat[sc.slot]
                        if let v = sc.engine.evaluateVec(current: [cur.x, cur.y, cur.z]) {
                            if v.count >= 3 { mat[sc.slot] = SIMD4(v[0], v[1], v[2], cur.w) }
                            else if v.count == 1 { mat[sc.slot] = SIMD4(v[0], cur.y, cur.z, cur.w) }
                        }
                    }
                    mat.withUnsafeBytes {
                        enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
                        enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
                    }
                }
                let eng = engineUniform(time: time, texRes: pass.texRes)
                eng.withUnsafeBytes {
                    enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                    enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
                }
                for (slot, source) in pass.binds {
                    enc.setFragmentTexture(source == -1 ? src : fboTex[source], index: slot)
                }
                for (slot, tex) in pass.aux { enc.setFragmentTexture(tex, index: slot) }
                if pass.usesAudio {  // 스펙트럼 버퍼(16:2/3, 32:5/6, 64:7/8).
                    func bind(_ arr: [Float], _ idx: Int) {
                        arr.withUnsafeBytes {
                            enc.setVertexBytes($0.baseAddress!, length: $0.count, index: idx)
                            enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: idx)
                        }
                    }
                    bind(currentSpectrum.left, 2); bind(currentSpectrum.right, 3)
                    bind(left32, 5); bind(right32, 6)
                    bind(left64, 7); bind(right64, 8)
                }
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.endEncoding()
            }
        }
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
                poolCheckout.removeAll(keepingCapacity: true)
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
        var asp = SIMD2<Float>(1, 1)  // 타겟이 proj 비율과 같다고 가정 → 왜곡 없음
        for t in times.sorted() {
            while simTime < t - 1e-4 { let s = min(dt, t - simTime); for i in sims.indices { _ = sims[i].step(s) }; simTime += s }
            guard let cb = queue.makeCommandBuffer() else { continue }
            // 효과 패스(오디오 포함, currentSpectrum 사용) 적용한 표시 텍스처.
            let displayTextures = buildDisplayTextures(device: device, queue: queue, time: t, cb: cb)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = clearColor
            guard var enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            // 라이브 draw 와 동일한 씬-순서 인터리브. 파티클은 로컬 sims 의 현재 스냅샷(step(0)) 사용.
            // (camOff=0 이라 parallaxDepth 는 무영향 — encodeLayer 공용 사용 가능.)
            // target 이 곧 누적(acc) — 컴포지션 레이어는 스냅샷 경유(runFrameBufferLayer).
            var aborted = false
            for item in drawPlan {
                switch item.kind {
                case .particle:
                    let snap = sims[item.idx].step(0)
                    encodeParticle(particleSystems[item.idx], snapshot: snap, into: enc, device: device,
                                   camOffset: &camOff, aspectScale: &asp)
                case .text:
                    encodeText(textLayers[item.idx], into: enc, camOffset: &camOff, aspectScale: &asp)
                case .layer where layers[item.idx].isFrameBuffer:
                    guard let next = runFrameBufferLayer(layers[item.idx], acc: target, cb: cb, ending: enc,
                                                         device: device, time: t,
                                                         camOffset: &camOff, aspectScale: &asp) else { aborted = true; break }
                    enc = next
                case .layer:
                    encodeLayer(layers[item.idx], texture: displayTextures[item.idx], into: enc,
                                camOffset: &camOff, aspectScale: &asp, time: t, device: device)
                }
            }
            if aborted { cb.commit(); continue }
            enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            let url = toDir.appendingPathComponent("frame_t\(String(format: "%.1f", t)).png")
            if writeFramePNG(target, width: width, height: height, to: url) { urls.append(url) }
        }
        return urls
    }

    /// bgra8 타겟 readback(BGRA→RGBA 스왑) → PNG 저장. 성공 여부 반환.
    private func writeFramePNG(_ target: MTLTexture, width: Int, height: Int, to url: URL) -> Bool {
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        raw.withUnsafeMutableBytes { ptr in
            target.getBytes(ptr.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        for j in stride(from: 0, to: raw.count, by: 4) { raw.swapAt(j, j + 2) }
        guard let png = OffscreenCapture.png(rgba: raw, width: width, height: height) else { return false }
        return (try? png.write(to: url)) != nil
    }

    public func pause() { videoRenderer?.pause() }
    public func resume() {
        if let videoRenderer { videoRenderer.resume() } else { mtkView?.needsDisplay = true }
    }
    public func teardown() {
        videoRenderer?.teardown(); videoRenderer = nil
        parallax.stop()
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
