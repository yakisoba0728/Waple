import Foundation

public struct SceneEffect: Equatable {
    public let name: String
    public let constants: [String: Float]
    public let maskTextureName: String?
}

public struct SceneLayer: Equatable {
    public let textureEntryName: String
    public let origin: Vec2
    public let size: Vec2
    public let scale: Vec2
    public let angleZ: Float
    public let alpha: Float
    public let color: Vec3
    public let brightness: Float
    public let parallaxDepth: Vec2
    public let effects: [SceneEffect]
}

public struct SceneDocument: Equatable {
    public let projectionWidth: Int
    public let projectionHeight: Int
    public let clearColor: Vec3
    public let parallaxEnabled: Bool
    public let parallaxAmount: Float
    public let parallaxMouseInfluence: Float
    public let layers: [SceneLayer]
}

public enum SceneDocumentError: Error, Equatable { case noScene }

extension SceneDocument {
    public static func parse(package: ScenePackage) throws -> SceneDocument {
        guard let sceneData = package.data(for: "scene.json") ?? package.data(for: "gifscene.json"),
              let scene = (try? JSONSerialization.jsonObject(with: sceneData)) as? [String: Any] else {
            throw SceneDocumentError.noScene
        }
        let general = scene["general"] as? [String: Any] ?? [:]
        let proj = general["orthogonalprojection"] as? [String: Any] ?? [:]
        let pw = (proj["width"] as? Int) ?? 1920
        let ph = (proj["height"] as? Int) ?? 1080
        let clear = vec3(general["clearcolor"] as? String) ?? Vec3(x: 0, y: 0, z: 0)
        let parallaxEnabled = (general["cameraparallax"] as? Bool) ?? false
        let parallaxAmount = float(general["cameraparallaxamount"]) ?? 1
        let parallaxMouseInfluence = float(general["cameraparallaxmouseinfluence"]) ?? 1

        var layers: [SceneLayer] = []
        for case let obj as [String: Any] in (scene["objects"] as? [Any] ?? []) {
            guard let imagePath = obj["image"] as? String else { continue }
            // `visible` 은 바인딩 객체 {"value": false} 또는 평문 불리언 false 두 형태로 온다.
            if (obj["visible"] as? Bool) == false { continue }
            if let vis = obj["visible"] as? [String: Any], (vis["value"] as? Bool) == false { continue }
            guard let tex = resolveTexture(imagePath: imagePath, package: package) else { continue }
            layers.append(SceneLayer(
                textureEntryName: tex,
                origin: vec2(obj["origin"] as? String) ?? Vec2(x: 0, y: 0),
                size: vec2(obj["size"] as? String) ?? Vec2(x: Float(pw), y: Float(ph)),
                scale: vec2(obj["scale"] as? String) ?? Vec2(x: 1, y: 1),
                angleZ: floats(obj["angles"] as? String).count >= 3 ? floats(obj["angles"] as? String)[2] : 0,
                alpha: float(obj["alpha"]) ?? 1,
                color: vec3(obj["color"] as? String) ?? Vec3(x: 1, y: 1, z: 1),
                brightness: float(obj["brightness"]) ?? 1,
                parallaxDepth: vec2(obj["parallaxDepth"] as? String) ?? Vec2(x: 1, y: 1),
                effects: parseEffects(obj["effects"])
            ))
        }
        return SceneDocument(projectionWidth: pw, projectionHeight: ph, clearColor: clear,
                             parallaxEnabled: parallaxEnabled, parallaxAmount: parallaxAmount,
                             parallaxMouseInfluence: parallaxMouseInfluence, layers: layers)
    }

    /// image(model) → material → texture name → "materials/<name>.tex".
    private static func resolveTexture(imagePath: String, package: ScenePackage) -> String? {
        guard let modelData = package.data(for: imagePath),
              let model = (try? JSONSerialization.jsonObject(with: modelData)) as? [String: Any],
              let materialPath = model["material"] as? String,
              let materialData = package.data(for: materialPath),
              let material = (try? JSONSerialization.jsonObject(with: materialData)) as? [String: Any],
              let passes = material["passes"] as? [Any],
              let pass0 = passes.first as? [String: Any],
              let textures = pass0["textures"] as? [Any],
              let name = textures.first as? String, !name.isEmpty else { return nil }
        let candidate = name.contains("/") || name.hasSuffix(".tex") ? name : "materials/\(name).tex"
        // Prefer "materials/<name>.tex"; fall back to the raw name if that exact entry exists;
        // otherwise still return the preferred candidate so the texture name is resolved
        // (the renderer skips layers whose texture data is missing). See plan Task 3 test.
        if package.entries.contains(where: { $0.name == candidate }) { return candidate }
        if package.entries.contains(where: { $0.name == name }) { return name }
        return candidate
    }

    private static func parseEffects(_ raw: Any?) -> [SceneEffect] {
        guard let arr = raw as? [Any] else { return [] }
        var out: [SceneEffect] = []
        for case let e as [String: Any] in arr {
            let file = (e["file"] as? String) ?? ""
            // "effects/<name>/effect.json" → name
            let parts = file.split(separator: "/")
            let name = parts.count >= 2 ? String(parts[parts.count - 2]) : file
            var constants: [String: Float] = [:]
            var mask: String? = nil
            if let passes = e["passes"] as? [Any], let pass0 = passes.first as? [String: Any] {
                if let cs = pass0["constantshadervalues"] as? [String: Any] {
                    for (k, v) in cs { if let f = float(v) { constants[k] = f } }
                }
                if let texs = pass0["textures"] as? [Any], texs.count >= 2, let m = texs[1] as? String { mask = m }
            }
            out.append(SceneEffect(name: name, constants: constants, maskTextureName: mask))
        }
        return out
    }

    private static func floats(_ s: String?) -> [Float] {
        (s ?? "").split(separator: " ").compactMap { Float($0) }
    }
    private static func float(_ v: Any?) -> Float? {
        if let d = v as? Double { return Float(d) }
        if let i = v as? Int { return Float(i) }
        return nil
    }
    private static func vec2(_ s: String?) -> Vec2? {
        let f = floats(s); return f.count >= 2 ? Vec2(x: f[0], y: f[1]) : nil
    }
    private static func vec3(_ s: String?) -> Vec3? {
        let f = floats(s); return f.count >= 3 ? Vec3(x: f[0], y: f[1], z: f[2]) : nil
    }
}
