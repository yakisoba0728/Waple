import Metal
import WapleCore

extension SceneRenderer {
    func requiresLiveComposite(_ effect: EffectGPU) -> Bool {
        if case .translated(let passes, _, _) = effect.bind {
            return passes.contains { !$0.compositeSlots.isEmpty || !$0.fullFrameSlots.isEmpty }
        }
        return false
    }

    func drawItemOrder(_ item: DrawItem) -> Int? {
        switch item.kind {
        case .layer: return layers.indices.contains(item.idx) ? layers[item.idx].order : nil
        case .text: return textLayers.indices.contains(item.idx) ? textLayers[item.idx].order : nil
        case .particle: return particleSystems.indices.contains(item.idx) ? particleSystems[item.idx].order : nil
        case .mesh3D: return meshRenderables.indices.contains(item.idx) ? meshRenderables[item.idx].order : nil
        }
    }

    /// A composition consumes its own descendants; those objects must not also be drawn into the parent target.
    func compositionDrawPlan(rootID: Int?) -> [DrawItem] {
        guard let document = runtimeSceneDocument else { return rootID == nil ? drawPlan : [] }
        let objects = Dictionary(document.parallaxObjects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byOrder = Dictionary(document.parallaxObjects.map { ($0.order, $0) }, uniquingKeysWith: { first, _ in first })
        let compositions = Set(document.layers.filter(\.isFrameBuffer).map(\.id).filter { $0 != 0 })
        guard !compositions.isEmpty else { return rootID == nil ? drawPlan : [] }
        return drawPlan.filter { item in
            guard let order = drawItemOrder(item), let object = byOrder[order] else { return rootID == nil }
            if object.id == rootID { return false }
            var parent = object.parent
            var seen = Set<Int>()
            while let id = parent, seen.insert(id).inserted {
                if compositions.contains(id) { return id == rootID }
                parent = objects[id]?.parent
            }
            return rootID == nil
        }
    }

    func compositionID(for layer: GPULayer) -> Int? {
        guard let document = runtimeSceneDocument, document.layers.indices.contains(layer.uid) else { return nil }
        let id = document.layers[layer.uid].id
        return id == 0 ? nil : id
    }

    func liveEffectTexture(_ layer: GPULayer, source: MTLTexture, background: MTLTexture,
                           commandBuffer: MTLCommandBuffer, device: MTLDevice, time: Float) -> MTLTexture {
        var current = source
        var premultiplied = false
        for effect in layer.effects {
            guard effectVisible(effect, time: time) else { continue }
            guard let next = pooledOffscreen(current.width, current.height, device),
                  applyEffect(effect, src: current, dst: next, time: time, cb: commandBuffer,
                              fullFrameSnapshot: background) else { break }
            current = next
            premultiplied = effect.outputPremultiplied
        }
        if premultiplied { premultipliedDisplayLayers.insert(layer.uid) }
        if let id = compositionID(for: layer) { compositeLayerTextures[id] = current }
        return current
    }
}

extension SceneRenderer {
    /// Child draws accumulate premultiplied coverage; effect inputs and final composition sample straight RGB.
    func straightCompositeTexture(_ source: MTLTexture, commandBuffer: MTLCommandBuffer,
                                  device: MTLDevice) -> MTLTexture? {
        let pipeline: MTLRenderPipelineState
        if let cached = straightCompositePipelines[source.pixelFormat] { pipeline = cached }
        else {
            let code = """
            #include <metal_stdlib>
            using namespace metal;
            struct O { float4 position [[position]]; float2 uv; };
            vertex O cv(uint id [[vertex_id]]) {
                float2 p = float2((id << 1) & 2, id & 2);
                return { float4(p * 2.0 - 1.0, 0, 1), float2(p.x, 1.0 - p.y) };
            }
            fragment float4 cf(O in [[stage_in]], texture2d<float> source [[texture(0)]]) {
                constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
                float4 value = source.sample(nearest, in.uv);
                return float4(value.a > 0.0 ? value.rgb / value.a : float3(0), value.a);
            }
            """
            guard let library = try? device.makeLibrary(source: code, options: nil) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "cv")
            descriptor.fragmentFunction = library.makeFunction(name: "cf")
            descriptor.colorAttachments[0].pixelFormat = source.pixelFormat
            guard let compiled = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            pipeline = compiled
            straightCompositePipelines[source.pixelFormat] = compiled
        }
        guard let target = pooledOffscreen(source.width, source.height, device, bgra: true) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return target
    }
}
