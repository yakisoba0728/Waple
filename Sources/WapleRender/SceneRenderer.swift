import AppKit
import MetalKit
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
    }
    private enum EffectBind {
        case handPort(params: [Float], aux: [MTLTexture], audio: AudioParams?)
        // fboScales: 이름 있는 FBO 의 해상도 나눗수(effect.json fbos[].scale) — 실행 시 dst 크기/scale 로 풀 할당.
        case translated(passes: [TranslatedPass], fboScales: [Int])
    }
    private struct EffectGPU { let pipeline: MTLRenderPipelineState; let bind: EffectBind }
    private struct GPULayer { let texture: MTLTexture; let vertexBuffer: MTLBuffer; let tint: SIMD4<Float>; let parallaxDepth: SIMD2<Float>; let effects: [EffectGPU]; let texWidth: Int; let texHeight: Int; let order: Int; var isFrameBuffer: Bool = false; var def: SceneLayer? = nil /* 프로퍼티 애니메이션 있는 레이어만(per-frame 재평가용) */; var puppet: PuppetModel? = nil }
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
        layers = buildLayers(doc: doc, package: package, device: device)
        particleSystems = buildParticles(doc: doc, package: package, device: device)
        if !particleSystems.isEmpty {
            hasParticles = true
            additivePipeline = particlePipeline(additive: true, device: device)
            translucentPipeline = particlePipeline(additive: false, device: device)
        }
        textLayers = buildTexts(doc: doc, package: package, device: device)
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
        if hasEffects || hasParticles || hasScriptedText || hasAnimations {
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
                let bins = AudioSpectrum16.downsample16(spec)
                self?.currentSpectrum = AudioSpectrum16(left: bins, right: bins)
                if spec.count >= 128 {
                    self?.setSpectrum64(left: Array(spec[0..<64]), right: Array(spec[64..<128]))
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
            for eff in layer.effects {
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
            out.append(GPULayer(texture: mtl, vertexBuffer: vbuf, tint: tint,
                                parallaxDepth: SIMD2<Float>(layer.parallaxDepth.x, layer.parallaxDepth.y),
                                effects: effects, texWidth: effW, texHeight: effH,
                                order: layer.order, isFrameBuffer: layer.isFrameBuffer,
                                def: (layer.animations.isEmpty && puppetModel == nil) ? nil : layer,
                                puppet: puppetModel))
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
                                         binds: binds, target: target, usesAudio: t.usesAudio, texRes: texRes))
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
                scale: SIMD2<Float>(sp.scale.x, sp.scale.y), texRatio: ratio, order: sp.order))
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

    /// 파티클 스냅샷 → 인터리브드 쿼드 버텍스(정점당 8 float: ndc.xy, uv, rgba).
    /// 빌보드: world_px = origin + scale⊙local(로컬 Y-up → 픽셀 Y-down 부호 반전), half=size_px/2.
    private func particleVertices(_ snapshot: [Particle], _ sys: GPUParticleSystem) -> [Float] {
        var verts: [Float] = []
        verts.reserveCapacity(snapshot.count * 48)
        for p in snapshot {
            let wx = sys.origin.x + sys.scale.x * p.pos.x
            let wy = sys.origin.y - sys.scale.y * p.pos.y
            let sizePx = p.size * sys.scale.x
            let hw = sizePx * 0.5, hh = sizePx * sys.texRatio * 0.5
            let ca = cos(p.rotation.z), sa = sin(p.rotation.z)
            func ndc(_ lx: Float, _ ly: Float) -> (Float, Float) {
                let x = wx + lx * ca - ly * sa, y = wy + lx * sa + ly * ca
                return (x / projW * 2 - 1, 1 - y / projH * 2)
            }
            let tl = ndc(-hw, -hh), tr = ndc(hw, -hh), br = ndc(hw, hh), bl = ndc(-hw, hh)
            let r = p.color.x, g = p.color.y, b = p.color.z, al = p.alpha
            func v(_ pt: (Float, Float), _ u: Float, _ vv: Float) {
                verts.append(contentsOf: [pt.0, pt.1, u, vv, r, g, b, al])
            }
            v(tl, 0, 0); v(tr, 1, 0); v(br, 1, 1)
            v(tl, 0, 0); v(br, 1, 1); v(bl, 0, 1)
        }
        return verts
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
            let engine = t.script.flatMap { TextScriptEngine(script: $0) }
            if t.script != nil && engine == nil { NSLog("%@", "[Waple] text script failed to load (empty text): \(t.script!.prefix(60))") }
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
        guard let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<Float>.stride * verts.count) else { return }
        enc.setRenderPipelineState(pipe)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        enc.setFragmentTexture(sys.texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: snapshot.count * 6)
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
                                             binds: last.binds, target: nil, usesAudio: last.usesAudio, texRes: last.texRes))
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
                    pass.material.withUnsafeBytes {
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
            // readback (BGRA → RGBA) → PNG.
            var raw = [UInt8](repeating: 0, count: width * height * 4)
            raw.withUnsafeMutableBytes { ptr in
                target.getBytes(ptr.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            for j in stride(from: 0, to: raw.count, by: 4) { raw.swapAt(j, j + 2) }
            if let png = OffscreenCapture.png(rgba: raw, width: width, height: height) {
                let url = toDir.appendingPathComponent("frame_t\(String(format: "%.1f", t)).png")
                if (try? png.write(to: url)) != nil { urls.append(url) }
            }
        }
        return urls
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
        additivePipeline = nil; translucentPipeline = nil
        texturePool.removeAll(); poolCheckout.removeAll()
        pipeline = nil; queue = nil; device = nil
    }
}
