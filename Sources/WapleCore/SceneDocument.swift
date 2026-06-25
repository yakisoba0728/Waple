import Foundation

public struct SceneEffect: Equatable {
    public let name: String
    /// 원본 effect.json 경로(예: "effects/workshop/<wsid>/<Name>/effect.json"). GLSL 셰이더 해석에 필요 —
    /// 짧은 name 만으론 워크샵 wsid 경로가 유실된다. 스톡은 "effects/<name>/effect.json".
    public let file: String
    public let constants: [String: [Float]]
    /// object effect `textures[]` 슬롯 전체. slot0 은 보통 null(=framebuffer),
    /// 이후 슬롯이 마스크/노멀맵 등 보조 텍스처. 각 원소는 이름 또는 null.
    public let textureNames: [String?]
    /// passes[0].combos (예: AUDIOPROCESSING, BLENDMODE, PULSEALPHA, PULSECOLOR). 셰이더 변형 선택.
    public let combos: [String: Int]
    /// AUDIOPROCESSING 콤보(0=off,1=L,2=R,3=L+R). 오디오-반응 효과 식별.
    public var audioMode: Int { combos["AUDIOPROCESSING"] ?? 0 }

    public init(name: String, constants: [String: [Float]], textureNames: [String?], combos: [String: Int] = [:], file: String = "") {
        self.name = name; self.constants = constants; self.textureNames = textureNames; self.combos = combos; self.file = file
    }
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

/// 씬 내 파티클 시스템 인스턴스. def(파티클 정의) + 씬 배치(origin/scale, 씬 픽셀 좌표).
public struct SceneParticle: Equatable {
    public let def: ParticleSystemDef
    public let origin: Vec2
    public let scale: Vec2
}

public struct SceneDocument: Equatable {
    public let projectionWidth: Int
    public let projectionHeight: Int
    public let clearColor: Vec3
    public let parallaxEnabled: Bool
    public let parallaxAmount: Float
    public let parallaxMouseInfluence: Float
    public let layers: [SceneLayer]
    public let particles: [SceneParticle]
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
        var particles: [SceneParticle] = []
        for case let obj as [String: Any] in (scene["objects"] as? [Any] ?? []) {
            // `visible` 은 바인딩 객체 {"value": false} 또는 평문 불리언 false 두 형태로 온다.
            if (obj["visible"] as? Bool) == false { continue }
            if let vis = obj["visible"] as? [String: Any], (vis["value"] as? Bool) == false { continue }
            if let imagePath = obj["image"] as? String {
                guard let tex = resolveTexture(imagePath: imagePath, package: package) else {
                    NSLog("%@", "[Waple] image layer texture resolve failed: \(imagePath)")
                    continue
                }
                let angles = floats(obj["angles"] as? String)
                layers.append(SceneLayer(
                    textureEntryName: tex,
                    origin: vec2(obj["origin"] as? String) ?? Vec2(x: 0, y: 0),
                    size: vec2(obj["size"] as? String) ?? Vec2(x: Float(pw), y: Float(ph)),
                    scale: vec2(obj["scale"] as? String) ?? Vec2(x: 1, y: 1),
                    angleZ: angles.count >= 3 ? angles[2] : 0,
                    alpha: float(obj["alpha"]) ?? 1,
                    color: vec3(obj["color"] as? String) ?? Vec3(x: 1, y: 1, z: 1),
                    brightness: float(obj["brightness"]) ?? 1,
                    parallaxDepth: vec2(obj["parallaxDepth"] as? String) ?? Vec2(x: 1, y: 1),
                    effects: parseEffects(obj["effects"])
                ))
            } else if let particlePath = obj["particle"] as? String {
                if let p = parseParticle(particlePath, obj: obj, package: package) { particles.append(p) }
            }
        }
        return SceneDocument(projectionWidth: pw, projectionHeight: ph, clearColor: clear,
                             parallaxEnabled: parallaxEnabled, parallaxAmount: parallaxAmount,
                             parallaxMouseInfluence: parallaxMouseInfluence, layers: layers, particles: particles)
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
              // 텍스처 배열은 빈 슬롯을 null 로 표기할 수 있으므로(예: [null, "real.tex"]),
              // 첫 항목이 아니라 첫 non-null·non-empty 문자열을 사용한다.
              let name = textures.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) else { return nil }
        let candidate = name.contains("/") || name.hasSuffix(".tex") ? name : "materials/\(name).tex"
        // Prefer "materials/<name>.tex"; fall back to the raw name if that exact entry exists;
        // otherwise still return the preferred candidate so the texture name is resolved
        // (the renderer skips layers whose texture data is missing). See plan Task 3 test.
        if package.entries.contains(where: { $0.name == candidate }) { return candidate }
        if package.entries.contains(where: { $0.name == name }) { return name }
        return candidate
    }

    /// scene object 의 `particle` 경로 → particles/X.json + material → SceneParticle.
    /// origin/scale 은 씬 픽셀 좌표(첫 2성분). 로드/파싱 실패 → nil + 로그.
    private static func parseParticle(_ path: String, obj: [String: Any], package: ScenePackage) -> SceneParticle? {
        guard let pData = package.data(for: path),
              let pjson = (try? JSONSerialization.jsonObject(with: pData)) as? [String: Any] else {
            NSLog("%@", "[Waple] SP4 particle load failed: \(path)")
            return nil
        }
        var material: ParticleMaterial? = nil
        if let matPath = pjson["material"] as? String, let mData = package.data(for: matPath),
           let mjson = (try? JSONSerialization.jsonObject(with: mData)) as? [String: Any] {
            material = ParticleMaterial.parse(mjson)
        }
        let def = ParticleSystemDef.parse(pjson, material: material)
        return SceneParticle(def: def,
                             origin: vec2(obj["origin"] as? String) ?? Vec2(x: 0, y: 0),
                             scale: vec2(obj["scale"] as? String) ?? Vec2(x: 1, y: 1))
    }

    private static func parseEffects(_ raw: Any?) -> [SceneEffect] {
        guard let arr = raw as? [Any] else { return [] }
        var out: [SceneEffect] = []
        for case let e as [String: Any] in arr {
            let file = (e["file"] as? String) ?? ""
            // "effects/<name>/effect.json" → name
            let parts = file.split(separator: "/")
            let name = parts.count >= 2 ? String(parts[parts.count - 2]) : file
            var constants: [String: [Float]] = [:]
            var textureNames: [String?] = []
            var combos: [String: Int] = [:]
            if let passes = e["passes"] as? [Any], let pass0 = passes.first as? [String: Any] {
                if let cb = pass0["combos"] as? [String: Any] {
                    for (k, v) in cb {
                        if let i = v as? Int { combos[k] = i }
                        else if let d = v as? Double { combos[k] = Int(d) }
                    }
                }
                if let cs = pass0["constantshadervalues"] as? [String: Any] {
                    for (k, v) in cs {
                        if let d = v as? Double { constants[k] = [Float(d)] }
                        else if let i = v as? Int { constants[k] = [Float(i)] }
                        else if let s = v as? String {
                            let f = s.split(separator: " ").compactMap { Float($0) }
                            if !f.isEmpty { constants[k] = f }
                        }
                    }
                }
                // textures 배열 전체를 슬롯 순서로 캡처. JSON null → nil, 문자열 → 이름.
                if let texs = pass0["textures"] as? [Any] {
                    textureNames = texs.map { $0 as? String }
                }
            }
            out.append(SceneEffect(name: name, constants: constants, textureNames: textureNames, combos: combos, file: file))
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
