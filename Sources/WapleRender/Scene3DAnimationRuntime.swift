import Foundation
import simd
import WapleCore

extension SceneRenderer {
    struct ModelAnimationScript {
        let layerIndex: Int
        let key: String
        let engine: TextScriptEngine
    }

    final class ModelAnimationState {
        let model: Model3D
        let baseLayers: [Int: AnimationLayer]
        var layers: [AnimationLayer]
        var layerIDs: [Int]
        var scripts: [ModelAnimationScript] = []
        var phases: [Int: Float] = [:]
        var playing: [Int: Bool] = [:]
        var lastTime: Float?
        var time: Float = 0
        var localOverrides: [Int: simd_float4x4] = [:]
        var poseLayers: [(anim: Int, additive: Bool, weight: Float, rate: Float)] = []
        var poseFrames: [Float?] = []
        var skinMatrices: [simd_float4x4] = []
        var worldMatrices: [simd_float4x4] = []

        init(model: Model3D, layers: [AnimationLayer]) {
            self.model = model; self.baseLayers = Dictionary(uniqueKeysWithValues: layers.enumerated().map { ($0.offset, $0.element) }); self.layers = layers
            self.layerIDs = Array(layers.indices)
            refreshPose()
        }

        func evaluate(time: Float) {
            let dt = lastTime.map { max(0, time - $0) } ?? 0
            if let lastTime, time < lastTime { phases.removeAll() }
            self.time = time; lastTime = time
            for index in layers.indices {
                if let base = baseLayers[layerIDs[index]] {
                    for (key, animation) in base.propertyAnimations {
                        switch key {
                        case "blend": layers[index].blend = animation.value(component: 0, atTime: time, base: base.blend)
                        case "rate": layers[index].rate = animation.value(component: 0, atTime: time, base: base.rate)
                        case "visible": layers[index].visible = animation.value(component: 0, atTime: time, base: base.visible ? 1 : 0) >= 0.5
                        default: break
                        }
                    }
                }
                for script in scripts where script.layerIndex == index {
                    script.engine.setRuntime(Double(time))
                    switch script.key {
                    case "blend": layers[index].blend = script.engine.evaluateVec(current: [layers[index].blend])?.first ?? layers[index].blend
                    case "rate": layers[index].rate = script.engine.evaluateVec(current: [layers[index].rate])?.first ?? layers[index].rate
                    case "visible": layers[index].visible = script.engine.evaluateBool(current: layers[index].visible) ?? layers[index].visible
                    default: break
                    }
                }
                let clip = Model3DPose.resolveAnimation(model: model, layerName: layers[index].name, clipId: layers[index].clipId)
                let id = layerIDs[index]
                let frame = Model3DPose.integratedCascadeFrame(model: model, anim: clip,
                    rate: playing[id] == false ? 0 : layers[index].rate,
                    time: time, dt: dt, previousPhase: phases[id])
                phases[id] = frame.phase
            }
            refreshPose()
        }

        func refreshPose() {
            poseLayers = []; poseFrames = []
            for (index, layer) in layers.enumerated() where layer.visible && layer.blend != 0 {
                let clip = Model3DPose.resolveAnimation(model: model, layerName: layer.name, clipId: layer.clipId)
                guard model.animations.indices.contains(clip) else { continue }
                poseLayers.append((clip, layer.additive, layer.blend, layer.rate))
                poseFrames.append(phases[layerIDs[index]].map {
                    Model3DPose.integratedCascadeFrame(model: model, anim: clip, rate: 0,
                        time: time, dt: 0, previousPhase: $0).frame
                })
            }
            worldMatrices = Model3DPose.worldMatrices(model: model, layers: poseLayers, time: time,
                                                      overrideFrames: poseFrames, localOverrides: localOverrides)
            skinMatrices = Model3DPose.blendedSkinMatrices(model: model, layers: poseLayers, time: time,
                                                          overrideFrames: poseFrames, localOverrides: localOverrides)
        }

        func attachment(_ name: String) -> simd_float4x4? {
            Model3DPose.attachmentFrame(model: model, name: name, layers: poseLayers, time: time,
                                        overrideFrames: poseFrames, localOverrides: localOverrides)
        }

        func snapshot(slot: Int, objectWorld: simd_float4x4) -> SceneScriptRuntimeLayerSnapshot {
            let bones: [[String: Any]] = model.bones.enumerated().map { index, bone in
                let pose = worldMatrices.indices.contains(index) ? worldMatrices[index] : bone.bind
                let parent = Int(clamping: bone.parent)
                let local = parent >= 0 && worldMatrices.indices.contains(parent)
                    ? PuppetPose.safeInverse(worldMatrices[parent]) * pose : pose
                return ["name": bone.name, "parent": parent,
                        "transform": Scene3DMath.matrixElements(objectWorld * pose),
                        "localTransform": Scene3DMath.matrixElements(local),
                        "origin": [local.columns.3.x, local.columns.3.y, local.columns.3.z]]
            }
            let attachments: [[String: Any]] = model.attachments.compactMap { attachment in
                guard let transform = self.attachment(attachment.name) else { return nil }
                return ["name": attachment.name, "transform": Scene3DMath.matrixElements(objectWorld * transform)]
            }
            let animations: [[String: Any]] = layers.enumerated().map { index, layer in
                let clipIndex = Model3DPose.resolveAnimation(model: model, layerName: layer.name, clipId: layer.clipId)
                let clip = model.animations.indices.contains(clipIndex) ? model.animations[clipIndex] : nil
                let fps = clip?.fps ?? 0
                let frame = Model3DPose.integratedCascadeFrame(model: model, anim: clipIndex,
                    rate: 0, time: time, dt: 0, previousPhase: phases[layerIDs[index]]).frame
                return ["id": layerIDs[index], "name": layer.name, "rate": layer.rate, "blend": layer.blend,
                        "visible": layer.visible, "playing": playing[layerIDs[index]] ?? true,
                        "fps": fps, "frame": frame, "frameCount": clip?.lengthFrames ?? 0,
                        "duration": fps > 0 ? Float(clip?.lengthFrames ?? 0) / fps : 0]
            }
            return SceneScriptRuntimeLayerSnapshot(slot: slot,
                values: ["bones": bones, "attachments": attachments, "animationLayers": animations])
        }
    }

    func make3DAnimationState(model: Model3D, object: SceneObject3D) -> ModelAnimationState {
        let state = ModelAnimationState(model: model, layers: object.animationLayers)
        let slot = nodes3D.first(where: { $0.id == object.id })?.scriptLayerIndex
        if let slot { sceneScript?.publishRuntimeLayers([state.snapshot(slot: slot, objectWorld: matrix_identity_float4x4)]) }
        for (index, layer) in object.animationLayers.enumerated() {
            for key in ["blend", "rate", "visible"] {
                guard let source = layer.scripts[key],
                      let engine = makeScriptEngine(source, currentLayerIndex: slot) else { continue }
                state.scripts.append(ModelAnimationScript(layerIndex: index, key: key, engine: engine))
            }
        }
        return state
    }

    func publish3DRuntimeSnapshots() {
        let nodes = make3DNodeMap()
        let snapshots = meshRenderables.compactMap { renderable -> SceneScriptRuntimeLayerSnapshot? in
            guard let state = renderable.animationState,
                  let slot = nodes3D.first(where: { $0.id == renderable.id })?.scriptLayerIndex,
                  let world = Scene3DMath.worldMatrix(id: renderable.id, nodes: nodes) else { return nil }
            return state.snapshot(slot: slot, objectWorld: world.matrix)
        }
        sceneScript?.publishRuntimeLayers(snapshots)
    }

    func make3DNodeMap() -> [Int: Scene3DMath.Node] {
        var result: [Int: Scene3DMath.Node] = [:]
        for node in nodes3D {
            var value = Scene3DMath.Node(origin: node.origin, angles: node.angles, scale: node.scale,
                                          parent: node.parent, visible: node.visible)
            if let name = node.attachment, let parent = node.parent,
               let animation = meshRenderables.first(where: { $0.id == parent })?.animationState,
               let attachment = animation.attachment(name) {
                value.localMatrix = attachment * Scene3DMath.modelMatrix(origin: node.origin,
                                                                           angles: node.angles, scale: node.scale)
            }
            result[node.id] = value
        }
        for bb in billboards where bb.id != 0 {
            result[bb.id] = Scene3DMath.Node(origin: bb.origin, angles: .zero,
                                              scale: SIMD3(bb.scale.x, bb.scale.y, 1),
                                              parent: bb.parent, visible: bb.visible)
        }
        return result
    }
}

extension SceneRenderer {
    func apply3DRuntimeCommand(_ command: SceneScriptRuntimeCommand) -> Bool {
        if apply3DTransformCommand(command) { return true }
        guard let node = nodes3D.first(where: { $0.scriptLayerIndex == command.slot }),
              let state = meshRenderables.first(where: { $0.id == node.id })?.animationState else { return false }
        let arguments = command.arguments
        let action = arguments["action"] as? String ?? ""
        func number(_ value: Any?) -> Float? {
            guard let number = value as? NSNumber, number.doubleValue.isFinite,
                  abs(number.doubleValue) <= Double(Float.greatestFiniteMagnitude) else { return nil }
            return number.floatValue
        }
        func vector(_ value: Any?) -> SIMD3<Float>? {
            if let values = value as? [NSNumber], values.count >= 3,
               let x = number(values[0]), let y = number(values[1]), let z = number(values[2]) { return SIMD3(x, y, z) }
            if let values = value as? [String: Any], let x = number(values["x"]),
               let y = number(values["y"]), let z = number(values["z"]) { return SIMD3(x, y, z) }
            return nil
        }
        func matrix(_ value: Any?) -> simd_float4x4? {
            guard let values = value as? [NSNumber], values.count == 16 else { return nil }
            let floats = values.compactMap(number)
            guard floats.count == 16 else { return nil }
            return simd_float4x4(columns: (SIMD4(floats[0], floats[1], floats[2], floats[3]),
                SIMD4(floats[4], floats[5], floats[6], floats[7]),
                SIMD4(floats[8], floats[9], floats[10], floats[11]),
                SIMD4(floats[12], floats[13], floats[14], floats[15])))
        }
        switch command.operation {
        case .animation:
            if action == "create" {
                let configuration = arguments["configuration"] as? [String: Any] ?? [:]
                let animation = arguments["animation"]
                let name = animation as? String ?? (animation as? [String: Any])?["name"] as? String ?? ""
                guard !name.isEmpty, state.model.animations.contains(where: {
                    $0.name.range(of: name, options: .caseInsensitive) != nil
                }) else {
                    WapleLog.warn("[Waple] model animation not found: \(name)"); return true
                }
                guard state.layers.count < 4096 else { return true }
                let id = (arguments["layerID"] as? NSNumber).flatMap { safeInt($0.doubleValue) }
                    ?? ((state.layerIDs.max() ?? -1) + 1)
                state.layers.append(AnimationLayer(name: name, additive: configuration["additive"] as? Bool ?? false,
                    blend: number(configuration["blend"]) ?? 1, rate: number(configuration["rate"]) ?? 1,
                    visible: configuration["visible"] as? Bool ?? true))
                state.layerIDs.append(id); state.phases[id] = 0
                state.refreshPose(); publish3DRuntimeSnapshots(); return true
            }
            let index: Int? = {
                if let id = (arguments["layerID"] as? NSNumber).flatMap({ safeInt($0.doubleValue) }) {
                    return state.layerIDs.firstIndex(of: id)
                }
                if let name = arguments["selector"] as? String { return state.layers.firstIndex(where: { $0.name == name }) }
                if let value = arguments["selector"] as? NSNumber, let index = safeInt(value.doubleValue),
                   state.layers.indices.contains(index) { return index }
                return nil
            }()
            guard let index else { return true }
            let id = state.layerIDs[index]
            switch action {
            case "play": state.playing[id] = true
            case "pause": state.playing[id] = false
            case "stop": state.playing[id] = false; state.phases[id] = 0
            case "setFrame": if let value = number(arguments["value"]) { state.phases[id] = value }
            case "setRate": if let value = number(arguments["value"]) { state.layers[index].rate = value }
            case "setBlend": if let value = number(arguments["value"]) { state.layers[index].blend = value }
            case "setVisible": if let value = arguments["value"] as? Bool { state.layers[index].visible = value }
            case "destroy":
                state.layers.remove(at: index); state.layerIDs.remove(at: index)
                state.scripts.removeAll { $0.layerIndex == index }
                state.scripts = state.scripts.map { script in
                    ModelAnimationScript(layerIndex: script.layerIndex > index ? script.layerIndex - 1 : script.layerIndex,
                                          key: script.key, engine: script.engine)
                }
                state.phases[id] = nil; state.playing[id] = nil
            default: return false
            }
            state.refreshPose(); publish3DRuntimeSnapshots(); return true
        case .bone:
            let index: Int? = {
                if let name = arguments["selector"] as? String { return state.model.bones.firstIndex(where: { $0.name == name }) }
                if let value = arguments["selector"] as? NSNumber, let index = safeInt(value.doubleValue),
                   state.model.bones.indices.contains(index) { return index }
                return nil
            }()
            guard let index, state.worldMatrices.indices.contains(index) else { return true }
            let bone = state.model.bones[index]
            let parent = Int(clamping: bone.parent)
            let parentPose = parent >= 0 && state.worldMatrices.indices.contains(parent)
                ? state.worldMatrices[parent] : matrix_identity_float4x4
            let local = state.localOverrides[index] ?? (PuppetPose.safeInverse(parentPose) * state.worldMatrices[index])
            switch action {
            case "setLocalTransform":
                guard let value = matrix(arguments["value"]) else { return true }
                state.localOverrides[index] = value
            case "setTransform":
                guard let value = matrix(arguments["value"]),
                      let world = Scene3DMath.worldMatrix(id: node.id, nodes: make3DNodeMap()) else { return true }
                state.localOverrides[index] = PuppetPose.safeInverse(world.matrix * parentPose) * value
            case "setLocalOrigin":
                guard let origin = vector(arguments["value"]) else { return true }
                state.localOverrides[index] = Model3DPose.replacingLocalOrigin(in: local, origin: origin)
            case "setLocalAngles":
                guard let angles = vector(arguments["value"]),
                      let changed = Model3DPose.replacingLocalAngles(in: local, anglesRadians: angles * (.pi / 180)) else { return true }
                state.localOverrides[index] = changed
            default: return false
            }
            state.refreshPose(); publish3DRuntimeSnapshots(); return true
        default: return false
        }
    }
}

extension SceneRenderer {
    private func apply3DTransformCommand(_ command: SceneScriptRuntimeCommand) -> Bool {
        guard command.operation == .setProperty || command.operation == .reparent else { return false }
        let node = nodes3D.first { $0.scriptLayerIndex == command.slot }
        let billboard = billboards.first { $0.layerIndex == command.slot }
        guard node != nil || billboard != nil else { return false }
        func vector(_ value: Any?) -> SIMD3<Float>? {
            if let dictionary = value as? [String: Any],
               let x = Scene3DEnvironmentRuntime.components(dictionary["x"]).first,
               let y = Scene3DEnvironmentRuntime.components(dictionary["y"]).first,
               let z = Scene3DEnvironmentRuntime.components(dictionary["z"]).first { return SIMD3(x, y, z) }
            let values = Scene3DEnvironmentRuntime.components(value)
            return values.count >= 3 ? SIMD3(values[0], values[1], values[2]) : nil
        }
        let arguments = command.arguments
        var values: [String: Any] = [:]
        if command.operation == .reparent {
            let slot = (arguments["parentSlot"] as? NSNumber).flatMap { safeInt($0.doubleValue) } ?? -1
            let parent = nodes3D.first { $0.scriptLayerIndex == slot }?.id ?? billboards.first { $0.layerIndex == slot }?.id
            guard slot < 0 || parent != nil else { return false }
            node?.parent = parent; billboard?.parent = parent
            if let name = arguments["attachment"] as? String { node?.attachment = name.isEmpty ? nil : name }
            values = arguments["transforms"] as? [String: Any] ?? [:]
        } else if let property = arguments["property"] as? String {
            values = property == "transforms" ? arguments["value"] as? [String: Any] ?? [:]
                : [property: arguments["value"] ?? NSNull()]
        }
        var handled = command.operation == .reparent
        for (property, raw) in values {
            switch property {
            case "origin":
                if let value = vector(raw) { node?.baseOrigin = value; node?.origin = value; billboard?.baseOrigin = value; billboard?.origin = value; handled = true }
            case "angles":
                if let value = vector(raw) {
                    let radians = value * (.pi / 180)
                    node?.baseAngles = radians; node?.angles = radians
                    billboard?.baseAngleZ = radians.z; billboard?.angleZ = radians.z; handled = true
                }
            case "scale":
                if let value = vector(raw) {
                    node?.baseScale = value; node?.scale = value
                    billboard?.baseScale = SIMD2(value.x, value.y); billboard?.scale = SIMD2(value.x, value.y); handled = true
                }
            case "visible":
                if let value = raw as? Bool { node?.baseVisible = value; node?.visible = value; billboard?.baseVisible = value; billboard?.visible = value; handled = true }
            case "color":
                if let value = vector(raw) {
                    if let node { node.baseTint = SIMD4(value, node.baseTint.w); node.tint = SIMD4(value, node.tint.w) }
                    if let billboard { billboard.baseTint = SIMD4(value, billboard.baseTint.w); billboard.tint = SIMD4(value, billboard.tint.w) }
                    handled = true
                }
            case "alpha":
                if let value = Scene3DEnvironmentRuntime.components(raw).first {
                    node?.baseTint.w = value; node?.tint.w = value; billboard?.baseTint.w = value; billboard?.tint.w = value; handled = true
                }
            default: break
            }
        }
        return handled
    }

    func model3DTint(for id: Int) -> SIMD4<Float> {
        nodes3D.first(where: { $0.id == id })?.tint ?? SIMD4(repeating: 1)
    }
}
