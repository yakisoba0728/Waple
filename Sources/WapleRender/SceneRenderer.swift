import AppKit
import MetalKit
import WapleCore

public final class SceneRenderer: NSObject, WallpaperRenderer, MTKViewDelegate {
    private struct AudioParams { let mode: Int; let freqMin: Float; let freqMax: Float; let bounds: SIMD2<Float>; let power: Float; let multiply: Float }
    private struct EffectGPU { let pipeline: MTLRenderPipelineState; let auxTextures: [MTLTexture]; let params: [Float]; let audio: AudioParams? }
    private struct GPULayer { let texture: MTLTexture; let vertexBuffer: MTLBuffer; let tint: SIMD4<Float>; let parallaxDepth: SIMD2<Float>; let effects: [EffectGPU]; let texWidth: Int; let texHeight: Int }
    private struct GPUParticleSystem {
        var sim: ParticleSimulator
        let def: ParticleSystemDef
        let seed: UInt64
        let texture: MTLTexture
        let blendAdditive: Bool
        let origin: SIMD2<Float>
        let scale: SIMD2<Float>
        let texRatio: Float   // texH/texW (스프라이트 세로 비율)
    }

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
    private let maxShift: Float = 0.1
    private var projAspect: Float = 16.0 / 9.0
    private var projW: Float = 1920
    private var projH: Float = 1080
    private var startTime = CFAbsoluteTimeGetCurrent()
    private var lastFrameTime = CFAbsoluteTimeGetCurrent()
    private var hasEffects = false
    private var hasAudio = false
    private var currentSpectrum = AudioSpectrum16.silent
    private var audioProvider: SystemAudioSpectrumProvider?
    private var effectVertexBuffer: MTLBuffer?
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
            doc = try SceneDocument.parse(package: package)
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

        let view = MTKView(frame: container.bounds, device: device)
        view.autoresizingMask = [.width, .height]
        view.colorPixelFormat = .bgra8Unorm
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
        if parallaxEnabled {
            parallax.onOffset = { [weak self] off in self?.updateParallax(off) }
            parallax.start()
        }

        effectVertexBuffer = device.makeBuffer(bytes: fullscreenQuad, length: MemoryLayout<SIMD2<Float>>.stride * fullscreenQuad.count)
        if hasEffects || hasParticles {
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
            guard let texData = assetData(layer.textureEntryName, package: package),
                  let tex = TexImage.parse(texData),
                  let decoded = TexDecoder.rgba(from: tex, data: texData),
                  let mtl = makeTexture(decoded.pixels, decoded.width, decoded.height, device) else { continue }
            let verts = quadVertices(layer: layer, projW: w, projH: h)
            guard let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<SIMD4<Float>>.stride * verts.count) else { continue }
            let tint = SIMD4<Float>(layer.color.x * layer.brightness, layer.color.y * layer.brightness,
                                    layer.color.z * layer.brightness, layer.alpha)
            var effects: [EffectGPU] = []
            for eff in layer.effects {
                guard let src = EffectShaders.source(for: eff.name),
                      let params = EffectShaders.params(for: eff.name, constants: eff.constants, combos: eff.combos),
                      let pipe = effectPipeline(source: src, device: device) else { continue }
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
                effects.append(EffectGPU(pipeline: pipe, auxTextures: aux, params: params, audio: audio))
            }
            if !effects.isEmpty { hasEffects = true }
            out.append(GPULayer(texture: mtl, vertexBuffer: vbuf, tint: tint,
                                parallaxDepth: SIMD2<Float>(layer.parallaxDepth.x, layer.parallaxDepth.y),
                                effects: effects, texWidth: decoded.width, texHeight: decoded.height))
        }
        return out
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
                scale: SIMD2<Float>(sp.scale.x, sp.scale.y), texRatio: ratio))
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

    private func pooledOffscreen(_ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let key = "\(max(w,1))x\(max(h,1))"
        let idx = poolCheckout[key, default: 0]
        if idx < (texturePool[key]?.count ?? 0) {
            poolCheckout[key] = idx + 1
            return texturePool[key]![idx]
        }
        guard let t = makeOffscreen(w, h, device) else { return nil }
        texturePool[key, default: []].append(t)
        poolCheckout[key] = idx + 1
        return t
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
        let hw = layer.size.x * layer.scale.x * 0.5
        let hh = layer.size.y * layer.scale.y * 0.5
        let a = layer.angleZ * .pi / 180
        let ca = cos(a), sa = sin(a)
        func corner(_ lx: Float, _ ly: Float) -> SIMD2<Float> {
            let rx = lx * ca - ly * sa, ry = lx * sa + ly * ca
            return SIMD2<Float>(layer.origin.x + rx, layer.origin.y + ry)
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

    private func updateParallax(_ off: CGPoint) {
        let s = parallaxAmount * parallaxMouseInfluence * maxShift
        cameraOffset = SIMD2<Float>(Float(off.x) * s, Float(off.y) * s)
        mtkView?.needsDisplay = true
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

    public func draw(in view: MTKView) {
        // 가림 시 애니메이션 정지(배터리). drawable 획득 전에 검사해 drawable 낭비/stall 방지.
        if hasEffects || hasParticles, view.window?.occlusionState.contains(.visible) == false { return }
        guard let device, let queue, let pipeline,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let nowT = CFAbsoluteTimeGetCurrent()
        let time = Float(nowT - startTime)
        var dt = Float(nowT - lastFrameTime); lastFrameTime = nowT
        dt = max(0, min(dt, 0.05))  // 큰 델타(탭 전환 등) 클램프

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
        rpd.colorAttachments[0].clearColor = clearColor
        rpd.colorAttachments[0].loadAction = .clear
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        for (i, layer) in layers.enumerated() {
            var tint = layer.tint
            var depth = layer.parallaxDepth
            enc.setVertexBuffer(layer.vertexBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            enc.setVertexBytes(&depth, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            enc.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
            enc.setFragmentTexture(displayTextures[i], index: 0)
            enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        encodeParticles(into: enc, device: device, dt: dt, camOffset: &camOffset, aspectScale: &aspectScale)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    /// 각 파티클 시스템을 dt 만큼 진행 후 빌보드 쿼드로 그린다(레이어 위, additive/translucent).
    private func encodeParticles(into enc: MTLRenderCommandEncoder, device: MTLDevice, dt: Float,
                                 camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) {
        guard hasParticles else { return }
        for i in particleSystems.indices {
            let snapshot = particleSystems[i].sim.step(dt)
            guard !snapshot.isEmpty else { continue }
            let sys = particleSystems[i]
            guard let pipe = sys.blendAdditive ? additivePipeline : translucentPipeline else { continue }
            let verts = particleVertices(snapshot, sys)
            guard let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<Float>.stride * verts.count) else { continue }
            enc.setRenderPipelineState(pipe)
            enc.setVertexBuffer(vbuf, offset: 0, index: 0)
            enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            enc.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            enc.setFragmentTexture(sys.texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: snapshot.count * 6)
        }
    }

    /// 효과가 있는 레이어는 원본 텍스처를 첫 src 로 삼아 효과 패스 체인을 적용한 결과 텍스처를, 없으면 원본을 반환.
    /// 라이브 draw 와 헤드리스 captureFrames 가 공유.
    private func buildDisplayTextures(device: MTLDevice, queue: MTLCommandQueue, time: Float, cb: MTLCommandBuffer) -> [MTLTexture] {
        poolCheckout.removeAll(keepingCapacity: true)  // 프레임 시작: 모든 풀 텍스처를 재사용 가능 상태로
        var out: [MTLTexture] = []
        for layer in layers {
            if layer.effects.isEmpty { out.append(layer.texture); continue }
            guard let evb = effectVertexBuffer else { out.append(layer.texture); continue }
            // 베이스 복사 불필요: 원본 텍스처를 직접 첫 src 로 사용(아래 루프는 항상 새 dst 로 출력).
            var current = layer.texture
            for eff in layer.effects {
                guard let next = pooledOffscreen(layer.texWidth, layer.texHeight, device) else { break }
                applyEffect(eff, src: current, dst: next, evb: evb, time: time, cb: cb)
                current = next
            }
            out.append(current)
        }
        return out
    }

    private func applyEffect(_ eff: EffectGPU, src: MTLTexture, dst: MTLTexture, evb: MTLBuffer, time: Float, cb: MTLCommandBuffer) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(eff.pipeline)
        enc.setVertexBuffer(evb, offset: 0, index: 0)
        enc.setFragmentTexture(src, index: 0)  // g_Texture0 = framebuffer
        for (i, aux) in eff.auxTextures.enumerated() {
            enc.setFragmentTexture(aux, index: i + 1)  // aux slot i → texture(i+1)
        }
        let buf = [time] + eff.params
        buf.withUnsafeBytes { ptr in
            enc.setFragmentBytes(ptr.baseAddress!, length: ptr.count, index: 0)
        }
        // 오디오 응답(현재 스펙트럼 + 효과 오디오 파라미터) → buffer(1). pulse 등 오디오 효과가 소비.
        var audioResp: Float = 0
        if let a = eff.audio {
            audioResp = AudioResponse.compute(left: currentSpectrum.left, right: currentSpectrum.right,
                                              mode: a.mode, freqMin: a.freqMin, freqMax: a.freqMax,
                                              bounds: a.bounds, power: a.power, multiply: a.multiply)
        }
        enc.setFragmentBytes(&audioResp, length: MemoryLayout<Float>.stride, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    /// 합성 스펙트럼 주입(헤드리스 검증/테스트용). 라이브에선 provider 가 갱신.
    public func setSpectrum(_ spectrum: AudioSpectrum16) { currentSpectrum = spectrum }

    /// 헤드리스 시각 검증: 레이어(베이스, 효과 제외) + 파티클을 오프스크린에 렌더해 각 time 의 PNG 를 저장.
    /// 시뮬은 t=0 에서 새로 시작해 1/30 스텝으로 각 time 까지 진행(재현 가능). 데스크탑 가림과 무관.
    @discardableResult
    public func captureFrames(width: Int, height: Int, times: [Float], toDir: URL) -> [URL] {
        guard let device, let queue, let pipeline, let target = makeOffscreenBGRA(width, height, device) else { return [] }
        var sims = particleSystems.map { ParticleSimulator(def: $0.def, seed: $0.seed) }
        var simTime: Float = 0
        let dt: Float = 1.0 / 30.0
        var urls: [URL] = []
        var camOff = SIMD2<Float>(0, 0)
        var asp = SIMD2<Float>(1, 1)  // 타겟이 proj 비율과 같다고 가정 → 왜곡 없음
        let depthOne = SIMD2<Float>(1, 1)
        for t in times.sorted() {
            while simTime < t - 1e-4 { let s = min(dt, t - simTime); for i in sims.indices { _ = sims[i].step(s) }; simTime += s }
            guard let cb = queue.makeCommandBuffer() else { continue }
            // 효과 패스(오디오 포함, currentSpectrum 사용) 적용한 표시 텍스처.
            let displayTextures = buildDisplayTextures(device: device, queue: queue, time: t, cb: cb)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = clearColor
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            enc.setRenderPipelineState(pipeline)
            for (i, layer) in layers.enumerated() {
                var tint = layer.tint, depth = depthOne
                enc.setVertexBuffer(layer.vertexBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&camOff, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                enc.setVertexBytes(&depth, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
                enc.setVertexBytes(&asp, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
                enc.setFragmentTexture(displayTextures[i], index: 0)
                enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            // 파티클(현재 스냅샷 — step(0) 으로 진행 없이 표시값만).
            for i in sims.indices {
                let snap = sims[i].step(0)
                guard !snap.isEmpty else { continue }
                let sys = particleSystems[i]
                guard let pipe = sys.blendAdditive ? additivePipeline : translucentPipeline else { continue }
                let verts = particleVertices(snap, sys)
                guard let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<Float>.stride * verts.count) else { continue }
                enc.setRenderPipelineState(pipe)
                enc.setVertexBuffer(vbuf, offset: 0, index: 0)
                enc.setVertexBytes(&camOff, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                enc.setVertexBytes(&asp, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
                enc.setFragmentTexture(sys.texture, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: snap.count * 6)
            }
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
        additivePipeline = nil; translucentPipeline = nil
        texturePool.removeAll(); poolCheckout.removeAll()
        pipeline = nil; queue = nil; device = nil
    }
}
