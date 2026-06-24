import AppKit
import MetalKit
import WapleCore

private struct EffectUniforms { var direction: SIMD2<Float>; var time: Float; var speed: Float; var scale: Float; var strength: Float; var perspective: Float }

public final class SceneRenderer: NSObject, WallpaperRenderer, MTKViewDelegate {
    private struct EffectGPU { let pipeline: MTLRenderPipelineState; let mask: MTLTexture; let constants: [String: Float] }
    private struct GPULayer { let texture: MTLTexture; let vertexBuffer: MTLBuffer; let tint: SIMD4<Float>; let parallaxDepth: SIMD2<Float>; let effects: [EffectGPU]; let texWidth: Int; let texHeight: Int }

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
    private var startTime = CFAbsoluteTimeGetCurrent()
    private var hasEffects = false
    private var effectVertexBuffer: MTLBuffer?
    private var fullscreenQuad: [SIMD2<Float>] = [SIMD2(-1,-1), SIMD2(1,-1), SIMD2(-1,1), SIMD2(1,1)]

    public override init() { super.init() }

    public func mount(in container: NSView, project: WallpaperProject) throws {
        let pkgURL = pkgURL(in: project.folderURL)
        guard let pkgURL, let data = try? Data(contentsOf: pkgURL),
              let package = try? ScenePackage.parse(data),
              let doc = try? SceneDocument.parse(package: package) else {
            throw RendererError.assetMissing
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
        projAspect = Float(doc.projectionWidth) / Float(max(1, doc.projectionHeight))
        layers = buildLayers(doc: doc, package: package, device: device)

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
        if hasEffects {
            view.isPaused = false
            view.enableSetNeedsDisplay = false
            view.preferredFramesPerSecond = 30
            startTime = CFAbsoluteTimeGetCurrent()
        }
    }

    private func pkgURL(in folder: URL) -> URL? {
        for name in ["scene.pkg", "gifscene.pkg"] {
            let u = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// 레이어를 후→전 순서(JSON 순서)로 GPU 리소스화. 디코드 실패 레이어는 스킵.
    private func buildLayers(doc: SceneDocument, package: ScenePackage, device: MTLDevice) -> [GPULayer] {
        let w = Float(doc.projectionWidth), h = Float(doc.projectionHeight)
        var out: [GPULayer] = []
        for layer in doc.layers {
            guard let texData = package.data(for: layer.textureEntryName),
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
                      let mask = effectMask(eff.maskTextureName, package: package, device: device),
                      let pipe = effectPipeline(source: src, device: device) else { continue }
                effects.append(EffectGPU(pipeline: pipe, mask: mask, constants: eff.constants))
            }
            if !effects.isEmpty { hasEffects = true }
            out.append(GPULayer(texture: mtl, vertexBuffer: vbuf, tint: tint,
                                parallaxDepth: SIMD2<Float>(layer.parallaxDepth.x, layer.parallaxDepth.y),
                                effects: effects, texWidth: decoded.width, texHeight: decoded.height))
        }
        return out
    }

    private func effectMask(_ name: String?, package: ScenePackage, device: MTLDevice) -> MTLTexture? {
        // 마스크 없거나 디코드 실패 → 흰색 1x1(=효과 전체 적용).
        if let name {
            let cand = name.hasSuffix(".tex") ? name : "materials/\(name).tex"
            if let d = package.data(for: cand) ?? package.data(for: name),
               let tex = TexImage.parse(d), let dec = TexDecoder.rgba(from: tex, data: d),
               let m = makeTexture(dec.pixels, dec.width, dec.height, device) { return m }
        }
        return makeTexture(Data([255, 255, 255, 255]), 1, 1, device)
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
        guard let device, let queue, let pipeline,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        // 가림 시 애니메이션 정지(배터리).
        if hasEffects, view.window?.occlusionState.contains(.visible) == false { return }
        let time = Float(CFAbsoluteTimeGetCurrent() - startTime)

        // 효과 있는 레이어는 오프스크린 베이스→효과 패스 후 결과 텍스처로 교체.
        var displayTextures: [MTLTexture] = []
        for layer in layers {
            if layer.effects.isEmpty { displayTextures.append(layer.texture); continue }
            guard var current = makeOffscreen(layer.texWidth, layer.texHeight, device),
                  let evb = effectVertexBuffer else { displayTextures.append(layer.texture); continue }
            blit(layer.texture, to: current, device: device, queue: queue)  // 베이스 복사
            for eff in layer.effects {
                guard let next = makeOffscreen(layer.texWidth, layer.texHeight, device) else { break }
                applyEffect(eff, src: current, dst: next, evb: evb, time: time, cb: cb)
                current = next
            }
            displayTextures.append(current)
        }

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
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    private func blit(_ src: MTLTexture, to dst: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) {
        guard let cb = queue.makeCommandBuffer(), let b = cb.makeBlitCommandEncoder() else { return }
        let w = min(src.width, dst.width), h = min(src.height, dst.height)
        b.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
               sourceSize: MTLSize(width: w, height: h, depth: 1),
               to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    }

    private func applyEffect(_ eff: EffectGPU, src: MTLTexture, dst: MTLTexture, evb: MTLBuffer, time: Float, cb: MTLCommandBuffer) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(eff.pipeline)
        enc.setVertexBuffer(evb, offset: 0, index: 0)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentTexture(eff.mask, index: 1)
        var u = effectUniforms(eff.constants, time: time)
        enc.setFragmentBytes(&u, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    private func effectUniforms(_ c: [String: Float], time: Float) -> EffectUniforms {
        let dirDeg = c["direction"] ?? 0
        let a = dirDeg * .pi / 180
        return EffectUniforms(direction: SIMD2<Float>(cos(a), sin(a)), time: time,
                              speed: c["speed"] ?? 5, scale: c["scale"] ?? 200,
                              strength: c["strength"] ?? 0.1, perspective: c["perspective"] ?? 0)
    }

    public func pause() { videoRenderer?.pause() }
    public func resume() {
        if let videoRenderer { videoRenderer.resume() } else { mtkView?.needsDisplay = true }
    }
    public func teardown() {
        videoRenderer?.teardown(); videoRenderer = nil
        parallax.stop()
        mtkView?.removeFromSuperview()
        mtkView = nil; layers = []; pipeline = nil; queue = nil; device = nil
    }
}
