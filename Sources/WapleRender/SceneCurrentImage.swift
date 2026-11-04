import AppKit
import Metal

extension SceneRenderer: WallpaperFrameCapturing {
    /// Copies the last presented Metal frame without evaluating scripts, advancing simulation or writing files.
    @MainActor public func captureCurrentImage(completion: @escaping @MainActor (NSImage?) -> Void) {
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
        command.addCompletedHandler { [weak self] buffer in
            DispatchQueue.main.async {
                guard let self, self.sceneMountGeneration == generation,
                      buffer.status == .completed else { completion(nil); return }
                var pixels = [UInt8](repeating: 0, count: copy.width * copy.height * 4)
                pixels.withUnsafeMutableBytes { raw in
                    copy.getBytes(raw.baseAddress!, bytesPerRow: copy.width * 4,
                        from: MTLRegionMake2D(0, 0, copy.width, copy.height), mipmapLevel: 0)
                }
                for index in stride(from: 0, to: pixels.count, by: 4) { pixels.swapAt(index, index + 2) }
                let image = OffscreenCapture.png(rgba: pixels, width: copy.width, height: copy.height).flatMap(NSImage.init(data:))
                completion(image)
            }
        }
        command.commit()
    }
}
