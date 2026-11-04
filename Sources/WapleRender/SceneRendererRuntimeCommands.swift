import Foundation
import Metal
import QuartzCore
import WapleCore

/// An independent sprite clock is created only after a script takes control. `join` removes it.
struct SceneRuntimeTextureAnimationState {
    var anchorTime: Float = 0
    var anchorPosition: Float = 0
    var rate: Float = 1
    var playing = true

    func position(at time: Float) -> Float {
        anchorPosition + (playing ? (time - anchorTime) * rate : 0)
    }

    mutating func anchor(at time: Float) { anchorPosition = position(at: time); anchorTime = time }
}

extension SceneRenderer {
    func prepareSceneScriptRuntime(package: ScenePackage, sceneFileName: String?, document: SceneDocument) {
        guard let sceneScript else { return }
        sceneScript.installModules(package: package)
        let source = [sceneFileName, "scene.json", "gifscene.json"].compactMap { $0 }
            .compactMap { package.data(for: $0) }.first.flatMap(AssetJSON.dictionary)
        let objects = source?["objects"] as? [[String: Any]] ?? []
        var configurations: [[String: Any]] = []
        for (index, layer) in document.layers.enumerated() where objects.indices.contains(layer.order) {
            configurations.append(["slot": index, "configuration": objects[layer.order]])
        }
        for (index, text) in document.texts.enumerated() where objects.indices.contains(text.order) {
            configurations.append(["slot": document.layers.count + index, "configuration": objects[text.order]])
        }
        if let json = SceneScriptRuntime.json(configurations) {
            sceneScript.context.evaluateScript("__wapleSetInitialConfigurations(\(json));")
        }
        var settings: [String: Any] = ["clearenabled": document.clearEnabled,
            "clearcolor": ["x": document.clearColor.x, "y": document.clearColor.y, "z": document.clearColor.z],
            "zoom": document.zoom, "bloom": document.bloom,
            "bloomstrength": document.bloomStrength, "bloomthreshold": document.bloomThreshold]
        if let camera = document.sceneCamera {
            settings["camera"] = ["eye": [camera.eye.x, camera.eye.y, camera.eye.z],
                "center": [camera.center.x, camera.center.y, camera.center.z],
                "up": [camera.up.x, camera.up.y, camera.up.z]]
        }
        if let json = SceneScriptRuntime.json(settings) { sceneScript.context.evaluateScript("__wapleConfigureScene(\(json));") }
    }

    func resizeSceneScripts(width: Float, height: Float) {
        sceneScript?.setScreenResolution(width: width, height: height)
        let event = "new Vec2(\(TextScriptEngine.jsNumber(width)),\(TextScriptEngine.jsNumber(height)))"
        for engine in eventEngines where engine.hookNames.contains("resizeScreen") { engine.callHook("resizeScreen", eventJS: event) }
    }

    func destroySceneScripts() {
        for engine in eventEngines where engine.hookNames.contains("destroy") { engine.callHook("destroy") }
    }

    public func applyScriptGeneralSettings(language: String) {
        guard let json = SceneScriptRuntime.json(["language": language]) else { return }
        for engine in eventEngines where engine.hookNames.contains("applyGeneralSettings") {
            engine.callHook("applyGeneralSettings", eventJS: json)
        }
    }

    public func setScriptUserShortcutHandler(names: Set<String>, handler: @escaping (String) -> Void) {
        runtimeBoundUserShortcutNames = names
        runtimeUserShortcutHandler = handler
        sceneScript?.installBoundUserShortcuts(names)
        sceneScript?.onOpenUserShortcut = handler
    }

    func consumeSceneRuntimeCommands() {
        guard let sceneScript else { return }
        let time = Float(sceneScript.context.evaluateScript("engine.runtime")?.toDouble() ?? 0)
        for command in sceneScript.drainRuntimeCommands() {
            if apply3DRuntimeCommand(command) { runtimeScriptCommandsApplied += 1; continue }
            let applied: Bool
            switch command.operation {
            case .create: applied = createRuntimeLayer(command)
            case .destroy: applied = destroyRuntimeLayer(slot: command.slot)
            case .sort: applied = sortRuntimeLayer(command)
            case .textureAnimation: applied = applyRuntimeTextureAnimation(command, time: time)
            case .video:
                if let video = layers.first(where: { $0.uid == command.slot })?.video,
                   let action = command.arguments["action"] as? String {
                    applied = video.applyRuntime(action: action, value: command.arguments["value"])
                } else { applied = false }
            case .particle: applied = applyRuntimeParticle(command)
            case .camera: applied = applyRuntimeCamera(command)
            case .scene: applied = applyRuntimeScene(command)
            default: applied = false
            }
            if applied { runtimeScriptCommandsApplied += 1 }
            else {
                let key = command.operation.rawValue + ":" + String(describing: command.arguments["action"] ?? "")
                if runtimeCommandWarnings.count < 64, runtimeCommandWarnings.insert(key).inserted {
                    WapleLog.warn("[Waple] SceneScript command has no compatible target: " + key)
                }
            }
        }
    }

    func publishSceneRuntimeSnapshots(time: Float) {
        let snapshots = layers.compactMap { layer -> SceneScriptRuntimeLayerSnapshot? in
            var values: [String: Any] = [:]
            if !layer.frames.isEmpty {
                let position = runtimeTextureAnimations[layer.uid]?.position(at: time) ?? time
                values["textureAnimation"] = [
                    "frame": TexImage.spriteFrameIndex(frames: layer.frames, time: position),
                    "frameCount": layer.frames.count,
                    "duration": runtimeSpriteDurations(layer.frames).reduce(0, +),
                    "rate": runtimeTextureAnimations[layer.uid]?.rate ?? 1,
                    "playing": runtimeTextureAnimations[layer.uid]?.playing ?? true
                ] as [String: Any]
            }
            if let video = layer.video { values["videoTexture"] = video.runtimeSnapshot }
            return values.isEmpty ? nil : SceneScriptRuntimeLayerSnapshot(slot: layer.uid, values: values)
        }
        let particles = particleSystems.compactMap { system -> SceneScriptRuntimeLayerSnapshot? in
            guard system.childOf == nil, let slot = system.visibleEngine?.layerRuntimeSlot else { return nil }
            return SceneScriptRuntimeLayerSnapshot(slot: slot, values: ["particle": ["playing": system.sim.isPlaying]])
        }
        sceneScript?.publishRuntimeLayers(snapshots + particles)
    }

    private func applyRuntimeParticle(_ command: SceneScriptRuntimeCommand) -> Bool {
        guard let index = particleSystems.firstIndex(where: { $0.childOf == nil && $0.visibleEngine?.layerRuntimeSlot == command.slot }),
              let action = command.arguments["action"] as? String else { return false }
        switch action {
        case "play": particleSystems[index].sim.play()
        case "pause": particleSystems[index].sim.emissionPaused = true
        case "stop": particleSystems[index].sim.stop()
        default: return false
        }
        return true
    }

    func runtimeSpriteFrameIndex(_ layer: GPULayer, time: Float) -> Int {
        TexImage.spriteFrameIndex(frames: layer.frames,
                                  time: runtimeTextureAnimations[layer.uid]?.position(at: time) ?? time)
    }

    private func runtimeSpriteDurations(_ frames: [TexImage.TexFrame]) -> [Float] {
        let useFallback = frames.reduce(Float(0)) { $0 + max(0, $1.time.isFinite ? $1.time : 0) } <= 0.0001
        return frames.map { useFallback ? TexImage.fallbackFrameTime : max(0.0001, $0.time.isFinite ? $0.time : 0.0001) }
    }

    private func applyRuntimeTextureAnimation(_ command: SceneScriptRuntimeCommand, time: Float) -> Bool {
        guard let layer = layers.first(where: { $0.uid == command.slot }), !layer.frames.isEmpty,
              let action = command.arguments["action"] as? String, time.isFinite else { return false }
        if action == "join" { runtimeTextureAnimations.removeValue(forKey: command.slot); return true }
        var state = runtimeTextureAnimations[command.slot]
            ?? SceneRuntimeTextureAnimationState(anchorTime: time, anchorPosition: time)
        state.anchor(at: time)
        switch action {
        case "play": state.playing = true
        case "pause": state.playing = false
        case "stop": state.playing = false; state.anchorPosition = 0
        case "setRate":
            guard let value = command.arguments["value"] as? NSNumber, value.floatValue.isFinite else { return false }
            state.rate = value.floatValue
        case "setFrame":
            guard let value = command.arguments["value"] as? NSNumber, value.doubleValue.isFinite else { return false }
            let bounded = max(0, min(Double(layer.frames.count - 1), value.doubleValue))
            guard let frame = safeInt(bounded) else { return false }
            let durations = runtimeSpriteDurations(layer.frames)
            state.anchorPosition = durations.prefix(frame).reduce(0, +)
        default: return false
        }
        runtimeTextureAnimations[command.slot] = state
        return true
    }

    private func runtimeDrawItem(slot: Int) -> DrawItem? {
        if let index = layers.firstIndex(where: { $0.uid == slot }) { return DrawItem(kind: .layer, idx: index) }
        if let index = textLayers.firstIndex(where: { sceneScriptImageLayerCount + $0.uid == slot }) {
            return DrawItem(kind: .text, idx: index)
        }
        return nil
    }

    private func destroyRuntimeLayer(slot: Int) -> Bool {
        guard let item = runtimeDrawItem(slot: slot) else { return false }
        switch item.kind {
        case .layer:
            layers[item.idx].video?.teardown()
            layers.remove(at: item.idx)
            scriptVisible.removeValue(forKey: slot)
            runtimeTextureAnimations.removeValue(forKey: slot)
        case .text:
            scriptTextVisible.removeValue(forKey: textLayers[item.idx].uid)
            textLayers.remove(at: item.idx)
        default: return false
        }
        drawPlan = drawPlan.compactMap { existing in
            guard existing.kind == item.kind else { return existing }
            if existing.idx == item.idx { return nil }
            return DrawItem(kind: existing.kind, idx: existing.idx > item.idx ? existing.idx - 1 : existing.idx)
        }
        return true
    }

    private func sortRuntimeLayer(_ command: SceneScriptRuntimeCommand) -> Bool {
        guard let item = runtimeDrawItem(slot: command.slot),
              let value = command.arguments["index"] as? NSNumber,
              value.doubleValue.isFinite,
              let previous = drawPlan.firstIndex(where: { $0.kind == item.kind && $0.idx == item.idx }) else { return false }
        guard let index = safeInt(max(0, min(Double(drawPlan.count - 1), value.doubleValue))) else { return false }
        drawPlan.remove(at: previous)
        drawPlan.insert(item, at: index)
        return true
    }

    private func createRuntimeLayer(_ command: SceneScriptRuntimeCommand) -> Bool {
        guard command.slot >= 0, command.slot < 4096, runtimeDrawItem(slot: command.slot) == nil,
              let device, let package = runtimePackage,
              var configuration = command.arguments["configuration"] as? [String: Any] else { return false }
        if let asset = configuration["asset"] as? String {
            guard let path = WallpaperPathSecurity.normalizedRelativePath(asset) else { return false }
            if let data = quietAssetData(path, package: package), let assetConfiguration = AssetJSON.dictionary(data) {
                configuration = assetConfiguration.merging(configuration) { _, override in override }
            } else { return false }
        }
        configuration.removeValue(forKey: "asset")
        // Vec objects serialize with x/y/z members; the scene parser accepts authored vector strings.
        for key in ["origin", "angles", "scale", "color", "size", "parallaxDepth", "padding", "backgroundcolor"] {
            if let vector = configuration[key] as? [String: Any] {
                let components = ["x", "y", "z", "w"].compactMap { vector[$0] as? NSNumber }
                configuration[key] = components.map { $0.stringValue }.joined(separator: " ")
            } else if let vector = configuration[key] as? [NSNumber] {
                configuration[key] = vector.map { $0.stringValue }.joined(separator: " ")
            }
        }
        let scene: [String: Any] = ["general": ["orthogonalprojection": ["width": projW, "height": projH]], "objects": [configuration]]
        guard let data = try? JSONSerialization.data(withJSONObject: scene) else { return false }
        let documentPackage = ScenePackage.assemble([("scene.json", data)])
        guard let document = try? SceneDocument.parse(package: documentPackage, assets: { [weak self] name in
            package.data(for: name) ?? self?.quietAssetData(name, package: package)
        }) else { return false }
        if !document.texts.isEmpty {
            guard var text = buildTexts(doc: document, package: package, device: device).first else { return false }
            text.uid = command.slot - sceneScriptImageLayerCount
            textLayers.append(text)
            drawPlan.append(DrawItem(kind: .text, idx: textLayers.count - 1))
        } else if !document.layers.isEmpty {
            guard var layer = buildLayers(doc: document, package: package, device: device, sceneID: "runtime").first else { return false }
            layer.uid = command.slot
            layer.def = document.layers.first
            layers.append(layer)
            drawPlan.append(DrawItem(kind: .layer, idx: layers.count - 1))
        } else { return false }
        hasAnimations = true
        shouldAnimate = true
        mtkView?.isPaused = false
        mtkView?.enableSetNeedsDisplay = false
        return true
    }

    private func applyRuntimeCamera(_ command: SceneScriptRuntimeCommand) -> Bool {
        guard let values = command.arguments["transforms"] as? [String: Any] else { return false }
        func vector(_ value: Any?) -> SIMD3<Float>? {
            guard let fields = value as? [String: NSNumber] else { return nil }
            let result = SIMD3(fields["x"]?.floatValue ?? 0, fields["y"]?.floatValue ?? 0, fields["z"]?.floatValue ?? 0)
            return result.x.isFinite && result.y.isFinite && result.z.isFinite ? result : nil
        }
        guard let eye = vector(values["eye"]), let center = vector(values["center"]), let up = vector(values["up"]) else { return false }
        if let camera = camera3D {
            camera3D = SceneCamera3D(eye: Vec3(x: eye.x, y: eye.y, z: eye.z),
                                    center: Vec3(x: center.x, y: center.y, z: center.z),
                                    up: Vec3(x: up.x, y: up.y, z: up.z),
                                    fov: camera.fov, nearZ: camera.nearZ, farZ: camera.farZ)
        } else { sceneCameraEye2D = SIMD2(eye.x, eye.y) }
        return true
    }

    private func applyRuntimeScene(_ command: SceneScriptRuntimeCommand) -> Bool {
        guard let name = command.arguments["property"] as? String else { return false }
        switch name {
        case "clearenabled":
            guard let value = command.arguments["value"] as? Bool else { return false }
            clearEnabled = value
        case "clearcolor":
            guard let value = command.arguments["value"] as? [String: NSNumber],
                  let r = value["x"]?.doubleValue, let g = value["y"]?.doubleValue, let b = value["z"]?.doubleValue,
                  r.isFinite, g.isFinite, b.isFinite else { return false }
            clearColor = MTLClearColor(red: r, green: g, blue: b, alpha: 1)
        case "zoom":
            guard let value = command.arguments["value"] as? NSNumber, value.floatValue.isFinite, value.floatValue > 0 else { return false }
            sceneZoom = value.floatValue
        default: return false
        }
        return true
    }
}
