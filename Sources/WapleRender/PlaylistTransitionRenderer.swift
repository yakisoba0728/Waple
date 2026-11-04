import AppKit
import MetalKit
import simd
import WapleCore

/// Draws only the outgoing frame into a transparent premultiplied target.
@MainActor
final class PlaylistTransitionRenderer {
    enum Failure: Error { case unsupportedKind, missingAssets, missingImage, allocation }
    struct Uniforms {
        var progressHash: SIMD4<Float>
        var resolution: SIMD4<Float>
        var viewProjection: simd_float4x4
        var viewProjectionInv: simd_float4x4
    }
    private struct PipelineKey: Hashable { var device: UInt64; var effect: Int }
    private static var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    let device: MTLDevice
    let kind: PlaylistTransitionKind
    private let hash: Float
    private let hash2: Float
    private let meshSeed: UInt32
    private let pipeline: MTLRenderPipelineState
    private let old: MTLTexture
    private let noise: MTLTexture
    private let clouds: MTLTexture
    private let depthState: MTLDepthStencilState
    private var depth: MTLTexture?
    private var mesh: MTLBuffer?
    private var meshAspect: Float = 0
    private var meshCount = 0

    init(device: MTLDevice, oldImage: NSImage, kind: PlaylistTransitionKind,
         hash: Float = Float.random(in: 0...1), hash2: Float = Float.random(in: 0...1),
         meshSeed: UInt32 = UInt32.random(in: .min ... .max)) throws {
        guard let effect = kind.effectID ?? (kind == .noTransitionReduceFlicker ? 0 : nil) else {
            throw Failure.unsupportedKind
        }
        guard let assets = BaseAssetsSettings.bundledAssetsDirectory else { throw Failure.missingAssets }
        guard let image = oldImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Failure.missingImage }
        self.device = device; self.kind = kind; self.hash = hash; self.hash2 = hash2; self.meshSeed = meshSeed
        let key = PipelineKey(device: device.registryID, effect: effect)
        if let cached = Self.pipelines[key] { pipeline = cached }
        else {
            let library = try device.makeLibrary(source: PlaylistTransitionShader.source(effectID: effect, assets: assets), options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "playlistVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "playlistFragment")
            descriptor.depthAttachmentPixelFormat = .depth32Float
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .one; color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            Self.pipelines[key] = pipeline
        }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft,
            .generateMipmaps: true, .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)]
        old = try loader.newTexture(cgImage: image, options: options)
        // The resource names are the original t1/t2 bindings, not substitute procedural textures.
        // Keep the complete shipped resource set available; the compiler removes unused slots.
        noise = try loader.newTexture(URL: assets.appendingPathComponent("materials/util/noise.png"), options: options)
        clouds = try loader.newTexture(URL: assets.appendingPathComponent("materials/util/clouds_256.png"), options: options)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = kind == .glassShatter ? .lessEqual : .always
        depthDescriptor.isDepthWriteEnabled = kind == .glassShatter
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { throw Failure.allocation }
        self.depthState = depthState
    }

    func encode(to target: MTLTexture, progress: Float, commandBuffer: MTLCommandBuffer) throws {
        guard target.width > 0, target.height > 0, target.pixelFormat == .bgra8Unorm else { throw Failure.allocation }
        if depth?.width != target.width || depth?.height != target.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                width: target.width, height: target.height, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = .renderTarget
            depth = device.makeTexture(descriptor: descriptor)
        }
        guard let depth else { throw Failure.allocation }
        let aspect = Float(target.width) / Float(target.height)
        if kind == .glassShatter, mesh == nil || meshAspect != aspect {
            let vertices = Self.shatterVertices(aspect: aspect, seed: meshSeed)
            meshCount = vertices.count / 11
            mesh = vertices.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress else { return nil }
                return device.makeBuffer(bytes: address, length: bytes.count, options: .storageModeShared)
            }
            meshAspect = aspect
            guard mesh != nil, meshCount > 0 else { throw Failure.allocation }
        }
        let matrix = Self.projection(aspect: aspect)
        var uniforms = Uniforms(progressHash: SIMD4(kind == .noTransitionReduceFlicker ? 0 : min(1, max(0, progress)), hash, hash2, 0),
            resolution: SIMD4(aspect, Float(target.width), Float(target.height), 0),
            viewProjection: matrix, viewProjectionInv: matrix.inverse)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.allocation }
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setVertexTexture(old, index: 0)
        encoder.setFragmentTexture(old, index: 0); encoder.setFragmentTexture(noise, index: 1); encoder.setFragmentTexture(clouds, index: 2)
        encoder.setVertexBuffer(mesh, offset: 0, index: 1)
        if kind == .glassShatter { encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: meshCount) }
        else { encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: kind == .bricks ? 28 : 1) }
        encoder.endEncoding()
    }

    /// Original RH camera: pi/2 FOV, near0.1/far100, view scale(2,2,1), translate Z=-2.
    /// This maps the aspect-scaled front plane exactly onto NDC [-1,1] at progress zero.
    static func projection(aspect: Float) -> simd_float4x4 {
        let near: Float = 0.1, far: Float = 100
        let perspective = simd_float4x4(columns: (
            SIMD4(1 / aspect, 0, 0, 0), SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)))
        let view = simd_float4x4(columns: (SIMD4(2, 0, 0, 0), SIMD4(0, 2, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, -2, 1)))
        return perspective * view
    }

    /// FUN_14005cd80: 35...45 random Voronoi cells, bbox center, 0.006-thick front/back/sides.
    /// Half-plane clipping replaces the Windows Voronoi provider while preserving its cell geometry.
    static func shatterVertices(aspect: Float, seed: UInt32) -> [Float] {
        var state = seed
        func random() -> Float {
            state = state &* 214013 &+ 2531011
            return Float((state >> 16) & 0x7fff) / 32767
        }
        let count = min(45, max(35, (safeInt(Double(random() * 11 + 35)) ?? 35)))
        let points = (0..<count).map { _ -> SIMD2<Float> in
            let y = random() * 2 - 1, x = random() * 2 - 1
            return SIMD2(x, y)
        }
        var result: [Float] = []
        for index in points.indices {
            var polygon: [SIMD2<Float>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)]
            for other in points.indices where other != index {
                let normal = points[other] - points[index]
                if simd_length_squared(normal) < 1e-12 { continue }
                let limit = (simd_length_squared(points[other]) - simd_length_squared(points[index])) * 0.5
                var clipped: [SIMD2<Float>] = []
                for edge in polygon.indices {
                    let a = polygon[edge], b = polygon[(edge + 1) % polygon.count]
                    let da = simd_dot(a, normal) - limit, db = simd_dot(b, normal) - limit
                    if da <= 0 { clipped.append(a) }
                    if (da <= 0) != (db <= 0) { clipped.append(a + (b - a) * (da / (da - db))) }
                }
                polygon = clipped
                if polygon.isEmpty { break }
            }
            guard polygon.count >= 3 else { continue }
            // Provider polygons wind clockwise; front fan (0,next,current) faces +Z.
            polygon.reverse()
            var low = polygon[0], high = polygon[0]
            for point in polygon { low = simd_min(low, point); high = simd_max(high, point) }
            let middle = (low + high) * 0.5
            let center = SIMD3(middle.x * aspect, middle.y, -0.003)
            func vertex(_ point: SIMD2<Float>, _ z: Float, _ normal: SIMD3<Float>) {
                result += [point.x * aspect, point.y, z, point.x * 0.5 + 0.5, 0.5 - point.y * 0.5,
                           center.x, center.y, center.z, normal.x, normal.y, normal.z]
            }
            for index in 1..<(polygon.count - 1) {
                for point in [polygon[0], polygon[index + 1], polygon[index]] { vertex(point, 0, SIMD3(0, 0, 1)) }
                for point in [polygon[0], polygon[index], polygon[index + 1]] { vertex(point, -0.006, SIMD3(0, 0, -1)) }
            }
            for index in polygon.indices {
                let a = polygon[index], b = polygon[(index + 1) % polygon.count], delta = b - a
                guard simd_length_squared(delta) > 1e-12 else { continue }
                let edgeNormal = simd_normalize(SIMD3(-delta.y, delta.x, 0))
                vertex(a, 0, edgeNormal); vertex(b, -0.006, edgeNormal); vertex(a, -0.006, edgeNormal)
                vertex(a, 0, edgeNormal); vertex(b, 0, edgeNormal); vertex(b, -0.006, edgeNormal)
            }
        }
        return result
    }
}
