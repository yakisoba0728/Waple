import Metal

extension SceneRenderer {
    /// Scene-global output selection for live and headless 2D/3D.
    /// The optional allocator is an internal test seam; production uses the existing frame pool.
    @discardableResult
    func finalizeScene(
        source: MTLTexture,
        destination: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        device: MTLDevice,
        allocateBloomTexture: ((Int, Int) -> MTLTexture?)? = nil
    ) -> Bool {
        // Existing HDR behavior is only relocated behind the common entry point.
        if hdrActive, let hdrPost {
            hdrPost.encode(cb: commandBuffer, src: source, dst: destination)
            return true
        }

        // Direct render into the readback target is the allocation-failure/raw path.
        guard source !== destination else { return true }

        func rawCopy() -> Bool {
            guard source.width == destination.width,
                  source.height == destination.height,
                  source.pixelFormat == destination.pixelFormat,
                  let blit = commandBuffer.makeBlitCommandEncoder() else {
                return false
            }
            blit.copy(from: source, to: destination)
            blit.endEncoding()
            return true
        }

        guard sceneWantsLDRBloom, let ldrBloomPass else {
            return rawCopy()
        }

        func allocate(_ width: Int, _ height: Int) -> MTLTexture? {
            if let allocateBloomTexture {
                return allocateBloomTexture(width, height)
            }
            return pooledOffscreen(width, height, device, bgra: true)
        }

        let quarterWidth = max(1, source.width / 4)
        let quarterHeight = max(1, source.height / 4)
        let eighthWidth = max(1, source.width / 8)
        let eighthHeight = max(1, source.height / 8)

        // Complete resource acquisition precedes the first bloom encoder.
        guard let quarter = allocate(quarterWidth, quarterHeight),
              let eighth = allocate(eighthWidth, eighthHeight),
              let bloom = allocate(eighthWidth, eighthHeight) else {
            return rawCopy()
        }

        guard ldrBloomPass.encode(
            commandBuffer: commandBuffer,
            source: source,
            quarter: quarter,
            eighth: eighth,
            bloom: bloom,
            destination: destination,
            parameters: ldrBloomParameters) else {
            return rawCopy()
        }
        return true
    }
}
