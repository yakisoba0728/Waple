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
    /// scene.json objects[] 내 인덱스 — WE 는 오브젝트 순서대로 그린다(파티클과 인터리브).
    public var order: Int = 0
    /// 컴포지션 레이어(_rt_FullFrameBuffer): 이 레이어의 소스는 "그 시점까지 합성된 프레임버퍼".
    /// textureEntryName 은 "" 이고 렌더러가 스냅샷을 src 로 바인드한다(설계 2026-07-02 컴포지션).
    public var isFrameBuffer: Bool = false
}

/// 씬 내 파티클 시스템 인스턴스. def(파티클 정의) + 씬 배치(origin/scale, 씬 픽셀 좌표).
public struct SceneParticle: Equatable {
    public let def: ParticleSystemDef
    public let origin: Vec2
    public let scale: Vec2
    /// scene.json objects[] 내 인덱스(레이어와 공유하는 z-순서).
    public var order: Int = 0
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
    /// - assets: 공유(base-assets) 리졸버 — pkg 에 없는 모델/머티리얼 JSON(models/util/solidlayer.json 등)의
    ///   폴백. WapleCore 는 순수하므로 파일 IO 는 호출자가 클로저로 주입한다(렌더러: BaseAssetsSettings 디렉터리).
    public static func parse(package: ScenePackage, assets: ((String) -> Data?)? = nil) throws -> SceneDocument {
        guard let sceneData = package.data(for: "scene.json") ?? package.data(for: "gifscene.json"),
              let scene = (try? JSONSerialization.jsonObject(with: sceneData)) as? [String: Any] else {
            throw SceneDocumentError.noScene
        }
        let general = scene["general"] as? [String: Any] ?? [:]
        let proj = general["orthogonalprojection"] as? [String: Any] ?? [:]
        let pw = (proj["width"] as? Int) ?? 1920
        let ph = (proj["height"] as? Int) ?? 1080
        let clear = vec3(general["clearcolor"]) ?? Vec3(x: 0, y: 0, z: 0)
        let parallaxEnabled = (general["cameraparallax"] as? Bool) ?? false
        let parallaxAmount = float(general["cameraparallaxamount"]) ?? 1
        let parallaxMouseInfluence = float(general["cameraparallaxmouseinfluence"]) ?? 1

        var layers: [SceneLayer] = []
        var particles: [SceneParticle] = []
        for (order, any) in (scene["objects"] as? [Any] ?? []).enumerated() {
            guard let obj = any as? [String: Any] else { continue }
            // `visible` 은 바인딩 객체 {"value": false} 또는 평문 불리언 false 두 형태로 온다.
            if (obj["visible"] as? Bool) == false { continue }
            if let vis = obj["visible"] as? [String: Any], (vis["value"] as? Bool) == false { continue }
            if let imagePath = obj["image"] as? String {
                guard let resolved = resolveLayerTexture(imagePath: imagePath, package: package, assets: assets) else {
                    continue  // 사유별 로그는 resolveLayerTexture 내부에서.
                }
                let angles = floats(obj["angles"])
                var origin = vec2(obj["origin"]) ?? Vec2(x: 0, y: 0)
                var size = vec2(obj["size"]) ?? Vec2(x: Float(pw), y: Float(ph))
                var scale = vec2(obj["scale"]) ?? Vec2(x: 1, y: 1)
                let entryName: String
                var isFB = false
                switch resolved {
                case .entry(let name): entryName = name
                case .solid: entryName = ""
                case .frameBuffer(let fullscreen):
                    entryName = ""; isFB = true
                    if fullscreen {  // fullscreen 모델은 오브젝트 size 와 무관하게 프로젝션 전체.
                        origin = Vec2(x: Float(pw) / 2, y: Float(ph) / 2)
                        size = Vec2(x: Float(pw), y: Float(ph))
                        scale = Vec2(x: 1, y: 1)
                    }
                }
                layers.append(SceneLayer(
                    textureEntryName: entryName,
                    origin: origin,
                    size: size,
                    scale: scale,
                    angleZ: angles.count >= 3 ? angles[2] : 0,
                    alpha: float(obj["alpha"]) ?? 1,
                    color: vec3(obj["color"]) ?? Vec3(x: 1, y: 1, z: 1),
                    brightness: float(obj["brightness"]) ?? 1,
                    parallaxDepth: vec2(obj["parallaxDepth"]) ?? Vec2(x: 1, y: 1),
                    effects: parseEffects(obj["effects"]),
                    order: order,
                    isFrameBuffer: isFB
                ))
            } else if let particlePath = obj["particle"] as? String {
                if var p = parseParticle(particlePath, obj: obj, package: package) {
                    p.order = order
                    particles.append(p)
                }
            }
        }
        return SceneDocument(projectionWidth: pw, projectionHeight: ph, clearColor: clear,
                             parallaxEnabled: parallaxEnabled, parallaxAmount: parallaxAmount,
                             parallaxMouseInfluence: parallaxMouseInfluence, layers: layers, particles: particles)
    }

    /// 레이어 소스 해석 결과.
    private enum LayerTexture {
        case entry(String)                    // 일반 텍스처 엔트리
        case solid                            // 무텍스처 머티리얼(flat) → 솔리드 필
        case frameBuffer(fullscreen: Bool)    // _rt_FullFrameBuffer → 컴포지션 레이어
    }

    /// image(model) → material → texture name → "materials/<name>.tex". nil = 해석 실패(드롭+로그).
    private static func resolveLayerTexture(imagePath: String, package: ScenePackage,
                                            assets: ((String) -> Data?)? = nil) -> LayerTexture? {
        func data(_ name: String) -> Data? { package.data(for: name) ?? assets?(name) }
        guard let modelData = data(imagePath),
              let model = (try? JSONSerialization.jsonObject(with: modelData)) as? [String: Any],
              let materialPath = model["material"] as? String,
              let materialData = data(materialPath),
              let material = (try? JSONSerialization.jsonObject(with: materialData)) as? [String: Any],
              let passes = material["passes"] as? [Any],
              let pass0 = passes.first as? [String: Any] else {
            NSLog("%@", "[Waple] image layer texture resolve failed: \(imagePath)")
            return nil
        }
        // 텍스처 배열은 빈 슬롯을 null 로 표기할 수 있으므로(예: [null, "real.tex"]),
        // 첫 항목이 아니라 첫 non-null·non-empty 문자열을 사용한다.
        let textures = pass0["textures"] as? [Any] ?? []
        guard let name = textures.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) else {
            // 무텍스처 머티리얼(예: util/solidlayer 의 shader "flat") → 솔리드 필.
            return .solid
        }
        if name.hasPrefix("_rt_") {
            // 프레임버퍼 참조(fullscreen/compose/project layer) → 컴포지션 레이어.
            let fullscreen = (model["fullscreen"] as? Bool) ?? (model["autosize"] as? Bool) ?? false
            return .frameBuffer(fullscreen: fullscreen)
        }
        // 머티리얼의 텍스처 이름은 materials/ 상대 + 무확장("util/white" → "materials/util/white.tex").
        // pkg 에 실제로 있는 후보를 우선하고, 없으면 관례 경로를 반환(렌더러가 base-assets 폴백 시도).
        let candidates = name.hasSuffix(".tex") ? [name] : ["materials/\(name).tex", name]
        for c in candidates where package.entries.contains(where: { $0.name == c }) { return .entry(c) }
        return .entry(candidates[0])
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
                             origin: vec2(obj["origin"]) ?? Vec2(x: 0, y: 0),
                             scale: vec2(obj["scale"]) ?? Vec2(x: 1, y: 1))
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

    /// 바인딩 객체 {"animation":..., "value": X} → X(정적 값), 아니면 원값.
    /// 실물 씬은 origin/alpha 등 대부분의 프로퍼티에 이 형태를 쓴다(애니메이션 재생은 후속 기능).
    private static func unwrap(_ v: Any?) -> Any? {
        if let d = v as? [String: Any], let inner = d["value"] { return inner }
        return v
    }
    private static func floats(_ v: Any?) -> [Float] {
        ((unwrap(v) as? String) ?? "").split(separator: " ").compactMap { Float($0) }
    }
    private static func float(_ v: Any?) -> Float? {
        let u = unwrap(v)
        if let d = u as? Double { return Float(d) }
        if let i = u as? Int { return Float(i) }
        return nil
    }
    private static func vec2(_ v: Any?) -> Vec2? {
        let f = floats(v); return f.count >= 2 ? Vec2(x: f[0], y: f[1]) : nil
    }
    private static func vec3(_ v: Any?) -> Vec3? {
        let f = floats(v); return f.count >= 3 ? Vec3(x: f[0], y: f[1], z: f[2]) : nil
    }
}
