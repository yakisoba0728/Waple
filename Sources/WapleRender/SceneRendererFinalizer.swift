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
        if hdrActive {
            // #22 HDR bloom(hdr && bloom, 2D 7씬): soft-knee 추출→blur13→saturate(base+bloom) —
            // EOTF 디코드는 이식하지 않는다(WE sRGB-뷰 스왑체인의 하드웨어 인코드와 상쇄되는 쌍이라
            // 비-sRGB 타깃엔 이중감마가 된다 — 근거·실측은 HDRBloomPass 헤더/합성부 주석).
            // 이 분기(블룸)와 아래 hdrPost 폴백은 이제 동일 saturate 규약 — hdr&&!bloom 은
            // hdrPost(클램프)로 확정, 블룸 실패 폴백도 같은 클램프라 폴백 시각 점프 없음.
            // 3D HDR 씬도 이 경로 도달(hdrActive=sceneIsHDR): acc·메시·파티클 파이프라인이 accPixelFormat(float)
            // 로 승격돼 소스가 float — 골든 3470948192(3D)의 bloom 지상검증이 여기서 성립.
            // 자원/인코드 실패는 hdrPost(saturate 클램프)로 폴백(무크래시·동일 규약). pooledOffscreen(bgra:true)는 hdrActive
            // 에서 float(rgba16Float)로 자동 승격된다(중간 버퍼가 소스와 동일 float 계약).
            // 비-HDR 씬은 hdrActive=false 로 이 블록 자체에 도달 불가(격리 — 148씬 무접촉).
            if sceneWantsHDRBloom, let hdrBloomPass,
               let quarter = pooledOffscreen(
                   max(1, source.width / 4), max(1, source.height / 4), device, bgra: true),
               let eighth = pooledOffscreen(
                   max(1, source.width / 8), max(1, source.height / 8), device, bgra: true),
               let bloom = pooledOffscreen(
                   max(1, source.width / 8), max(1, source.height / 8), device, bgra: true),
               hdrBloomPass.encode(
                   commandBuffer: commandBuffer,
                   source: source,
                   quarter: quarter,
                   eighth: eighth,
                   bloom: bloom,
                   destination: destination,
                   parameters: hdrBloomParameters) {
                return true
            }
            if let hdrPost {
                hdrPost.encode(cb: commandBuffer, src: source, dst: destination)
                return true
            }
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
