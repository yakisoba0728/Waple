import AppKit
import Metal

// The texture is written only by the preceding GPU blit. The command's one completion callback
// is its sole CPU reader; only copied Sendable pixels leave that callback.
private final class CompletedMetalFrame: @unchecked Sendable {
    private let texture: MTLTexture
    init(_ texture: MTLTexture) { self.texture = texture }
    func rgba() -> (pixels: [UInt8], width: Int, height: Int) {
        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        for index in stride(from: 0, to: pixels.count, by: 4) { pixels.swapAt(index, index + 2) }
        return (pixels, width, height)
    }
}

extension SceneRenderer: WallpaperFrameCapturing {
    /// Copies the last presented Metal frame without evaluating scripts, advancing simulation or writing files.
    @MainActor public func captureCurrentImage(completion: @escaping @MainActor @Sendable (NSImage?) -> Void) {
        guard let source = lastPresentedTexture, let device, let queue,
              source.pixelFormat == .bgra8Unorm,
              let command = queue.makeCommandBuffer() else { completion(nil); return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: source.width, height: source.height, mipmapped: false)
        descriptor.storageMode = .shared
        guard let copy = device.makeTexture(descriptor: descriptor),
              let blit = command.makeBlitCommandEncoder() else { completion(nil); return }
        blit.copy(from: source, to: copy); blit.endEncoding()
        let generation = sceneMountGeneration
        let readback = CompletedMetalFrame(copy)
        command.addCompletedHandler { [weak self] buffer in
            let succeeded = buffer.status == .completed
            let pixels = succeeded ? readback.rgba() : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sceneMountGeneration == generation,
                      let pixels else { completion(nil); return }
                let image = OffscreenCapture.png(rgba: pixels.pixels, width: pixels.width, height: pixels.height)
                    .flatMap(NSImage.init(data:))
                completion(image)
            }
        }
        command.commit()
    }
}
