import WapleCore

extension SceneRenderer {
    struct AnimationClipClock {
        let layer: Int
        let clip: Int
        let phase: Float
        var revision: Int = 0
    }

    struct PuppetFramePose {
        let layers: [(anim: Int, additive: Bool, weight: Float, rate: Float)]
        let frames: [Float?]
        let clocks: [AnimationClipClock]
    }

    /// One authored playback evaluation per frame shared by the parent, its attachments and event delivery.
    func puppetFramePose(_ layer: GPULayer, model: PuppetModel, time: Float) -> PuppetFramePose {
        if let cached = puppetFramePoses[layer.uid] { return cached }
        let pose = resolvePuppetFramePose(model: model, uid: layer.uid,
            authored: layer.def?.animationLayers ?? [], scripts: layer.animLayerScripts, time: time)
        puppetFramePoses[layer.uid] = pose
        return pose
    }

    func resolvePuppetFramePose(model: PuppetModel, uid: Int, authored: [AnimationLayer],
                                scripts: [(layerIndex: Int, key: String, engine: TextScriptEngine)] = [],
                                time: Float) -> PuppetFramePose {
        var evaluated = authored
        for (index, base) in authored.enumerated() {
            for (key, animation) in base.propertyAnimations {
                switch key {
                case "blend": evaluated[index].blend = animation.value(component: 0, atTime: time, base: base.blend)
                case "rate": evaluated[index].rate = animation.value(component: 0, atTime: time, base: base.rate)
                case "visible": evaluated[index].visible = animation.value(component: 0, atTime: time, base: base.visible ? 1 : 0) >= 0.5
                default: break
                }
            }
        }
        for script in scripts where evaluated.indices.contains(script.layerIndex) {
            let index = script.layerIndex
            script.engine.setRuntime(Double(time))
            switch script.key {
            case "visible":
                let visible = evaluated[index].visible
                evaluated[index].visible = script.engine.evaluateBool(current: visible) ?? visible
            case "rate":
                if let rate = script.engine.evaluateVec(current: [evaluated[index].rate])?.first {
                    evaluated[index].rate = rate
                }
            case "blend":
                if let blend = script.engine.evaluateVec(current: [evaluated[index].blend])?.first {
                    evaluated[index].blend = blend
                }
            default: break
            }
        }

        var layers: [(anim: Int, additive: Bool, weight: Float, rate: Float)] = []
        var frames: [Float?] = []
        var clocks: [AnimationClipClock] = []
        let previousTime = puppetCascadeLastTime[uid]
        let dt = previousTime.map { max(0, time - $0) } ?? 0
        let previousPhases = (previousTime ?? time) <= time ? (puppetCascadePhase[uid] ?? [:]) : [:]
        var phases: [Int: Float] = [:]
        for (index, entry) in evaluated.enumerated() {
            let clip = PuppetPose.clipIndex(model: model, name: entry.name, fallback: index, clipId: entry.clipId)
            guard model.animations.indices.contains(clip) else { continue }
            let isDynamic = entry.propertyAnimations["rate"] != nil
                || scripts.contains { $0.layerIndex == index && $0.key == "rate" }
            let phase = PuppetPose.integratedCascadeFrame(model: model, anim: clip, rate: entry.rate,
                time: time, dt: dt, previousPhase: isDynamic ? previousPhases[index] : nil)
            if isDynamic { phases[index] = phase.phase }
            guard entry.visible, entry.blend > 0 else { continue }
            layers.append((clip, entry.additive, entry.blend, entry.rate))
            frames.append(isDynamic ? phase.frame : nil)
            clocks.append(AnimationClipClock(layer: index, clip: clip, phase: phase.phase))
        }
        puppetCascadePhase[uid] = phases
        puppetCascadeLastTime[uid] = time

        if authored.isEmpty, let first = model.animations.first {
            layers.append((0, false, 1, 1))
            frames.append(nil)
            clocks.append(AnimationClipClock(layer: -1, clip: 0, phase: time * first.fps))
        }
        return PuppetFramePose(layers: layers, frames: frames, clocks: clocks)
    }
}
