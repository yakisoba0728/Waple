import AppKit
import MetalKit
import WapleCore

public final class SceneRenderer: NSObject, WallpaperRenderer, MTKViewDelegate {
    private struct GPULayer { let texture: MTLTexture; let vertexBuffer: MTLBuffer; let tint: SIMD4<Float> }

    private var videoRenderer: VideoRenderer?
    private var mtkView: MTKView?
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var layers: [GPULayer] = []
    private var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

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
            out.append(GPULayer(texture: mtl, vertexBuffer: vbuf, tint: tint))
        }
        return out
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

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

    public func draw(in view: MTKView) {
        guard let queue, let pipeline,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        rpd.colorAttachments[0].clearColor = clearColor
        rpd.colorAttachments[0].loadAction = .clear
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        for layer in layers {
            var tint = layer.tint
            enc.setVertexBuffer(layer.vertexBuffer, offset: 0, index: 0)
            enc.setFragmentTexture(layer.texture, index: 0)
            enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    public func pause() { videoRenderer?.pause() }
    public func resume() {
        if let videoRenderer { videoRenderer.resume() } else { mtkView?.needsDisplay = true }
    }
    public func teardown() {
        videoRenderer?.teardown(); videoRenderer = nil
        mtkView?.removeFromSuperview()
        mtkView = nil; layers = []; pipeline = nil; queue = nil; device = nil
    }
}
