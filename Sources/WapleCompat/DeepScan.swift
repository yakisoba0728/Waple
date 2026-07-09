import Foundation
import Metal
import AVFoundation
import WapleCore
import WapleRender

// Deep compatibility scanner: runs the *real* Waple parse/decode/translate/compile code paths
// over an entire Wallpaper Engine corpus and reports how much actually works.
//
// Design (see deep-compat report): we orchestrate the public parsers (ScenePackage, TexImage,
// TexDecoder, SceneDocument, GLSLTranslator, Model3D, PuppetModel, ParticleSystemDef, ...) and the
// real Metal makeLibrary. We do NOT instantiate the GPU renderer — that allocates a texture per
// layer (thousands of 4K textures = OOM). Shader translation is done inline (CPU, parallel);
// Metal compilation is deferred and deduped by MSL so identical stock effects compile once.

// MARK: - Aggregator

final class DeepAgg {
    private let lock = NSLock()
    func sync<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    // project-level
    var projTypeTotal: [String: Int] = [:]
    var projTypeSupported: [String: Int] = [:]
    var projectJSONTotal = 0, projectJSONOK = 0
    var propsProjects = 0, propsOK = 0
    var conditionsTotal = 0, conditionsEvaluable = 0
    var propertyTypeCounts: [String: Int] = [:]
    var unsupportedPropertyTypes: [String: Int] = [:]

    // TEX (pkg-internal + scene-referenced)
    var texAttempt = 0, texParseOK = 0                     // .tex entries parsed by TexImage.parse
    var texPageAttempt = 0, texPageOK = 0                  // image pages actually RGBA-decoded
    var texByFormat: [String: (att: Int, ok: Int)] = [:]   // bucket -> attempts/decoded (page-level)
    var texFailSamples: [String: [String]] = [:]
    var framesTotal = 0, framesRotated = 0, atlasMulti = 0, gifFlagged = 0, videoTex = 0
    var texWithFrames = 0

    // stock assets/*.tex
    var assetTexAttempt = 0, assetTexParseOK = 0, assetTexPageOK = 0
    var assetTexByFormat: [String: (att: Int, ok: Int)] = [:]

    // shaders (effect translate path)
    var effectInstances = 0, effectHandPort = 0, effectShaderMissing = 0
    var translateAttempt = 0, translateOK = 0
    var translateFailSamples: [String] = []
    var mslJobs: [String: String] = [:]                    // unique MSL -> representative provenance
    // filled after compile pass:
    var compileAttempt = 0, compileOK = 0
    var compileFailClusters: [String: [String]] = [:]      // first error token -> sample provenances

    // scenes
    var sceneAttempt = 0, sceneParseOK = 0
    var layerCount = 0, puppetLayers = 0, effectLayers = 0
    var particleObjs = 0, textObjs = 0, model3DObjs = 0, lightObjs = 0, soundObjs = 0

    // models (.mdl)
    var mdlAttempt = 0, mdlOK = 0
    var mdlByMagic: [String: (att: Int, ok: Int)] = [:]
    var mdlFailSamples: [String: [String]] = [:]

    // particles (particles/*.json)
    var particleFileAttempt = 0, particleParseOK = 0, particleSimOK = 0
    var particleFailSamples: [String] = []

    // videos
    var videoTotal = 0, videoNativePlayable = 0, videoNativeUnplayable = 0
    var videoConvertible = 0, videoUnknownContainer = 0
    var videoFailSamples: [String] = []

    // web
    var webTotal = 0, webIndexPresent = 0, webRandomFile = 0, webServiceWorker = 0

    // audio / sounds
    var soundRefs = 0, soundPresent = 0
    var soundByExt: [String: Int] = [:]

    // presets
    var presetTotal = 0, presetResolved = 0

    // scene-level support tally
    var sceneSupported = 0

    func addSample(_ dict: inout [String: [String]], _ key: String, _ path: String, cap: Int = 4) {
        if dict[key] == nil { dict[key] = [] }
        if dict[key]!.count < cap { dict[key]!.append(path) }
    }
}

// MARK: - Per-package asset resolution (mirrors SceneRendererResources.quietAssetData/baseAssetURL)

struct PkgAssets {
    let package: ScenePackage
    let assetsDir: URL?

    func pkgData(_ name: String) -> Data? {
        if let d = package.data(for: name) { return d }
        guard let e = package.entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return package.data(for: e.name)
    }

    // Case-insensitive component walk under assetsDir, identical to the renderer's baseAssetURL.
    func baseAssetURL(_ name: String) -> URL? {
        guard let root = assetsDir, let path = WallpaperPathSecurity.normalizedRelativePath(name) else { return nil }
        if let exact = WallpaperPathSecurity.containedFileURL(path, root: root),
           FileManager.default.fileExists(atPath: exact.path) { return exact }
        let rootURL = root.standardizedFileURL
        var current = rootURL
        for part in path.split(separator: "/").map(String.init) {
            guard let children = try? FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil),
                  let match = children.first(where: { $0.lastPathComponent.caseInsensitiveCompare(part) == .orderedSame })
            else { return nil }
            current = match.standardizedFileURL
            guard WallpaperPathSecurity.contains(current, in: rootURL) else { return nil }
        }
        guard FileManager.default.fileExists(atPath: current.path) else { return nil }
        return current
    }

    func assetData(_ name: String) -> Data? {
        if let d = pkgData(name) { return d }
        if let u = baseAssetURL(name) { return try? Data(contentsOf: u) }
        return nil
    }

    // #include resolver: pkg shaders/<h> -> pkg <h> -> base-assets -> builtin (mirrors buildTranslatedEffect).
    func include(_ header: String) -> String? {
        for cand in ["shaders/\(header)", header] {
            if let d = assetData(cand), let s = String(data: d, encoding: .utf8) { return s }
        }
        return BuiltinShaderIncludes.lookup(header)
    }
}

// MARK: - Deep scanner

enum DeepScan {
    static let handPortNames: Set<String> = ["opacity", "tint", "pulse", "waterripple", "scroll", "waterwaves", "shake"]

    static func run(rootPath: String, only: String?) -> String {
        let root = URL(fileURLWithPath: NSString(string: rootPath).expandingTildeInPath, isDirectory: true).standardizedFileURL
        let assetsDir = firstExisting([root.appendingPathComponent("assets"),
                                       root.deletingLastPathComponent().appendingPathComponent("assets")])
        let container = projectContainer(root)
        var folders = projectFolders(container)
        let knownIDs = Set(folders.map { $0.lastPathComponent })
        if let only { folders = folders.filter { $0.lastPathComponent == only } }

        let agg = DeepAgg()
        let started = Date()

        DispatchQueue.concurrentPerform(iterations: folders.count) { i in
            autoreleasepool {
                scanProject(folders[i], assetsDir: assetsDir, knownIDs: knownIDs, agg: agg)
            }
        }

        // stock assets/*.tex (WE official texture library)
        if let assetsDir {
            scanAssetTextures(assetsDir, agg: agg)
        }

        let translateElapsed = Date().timeIntervalSince(started)

        // Deferred Metal compile pass (deduped by MSL).
        compileShaders(agg: agg)

        let elapsed = Date().timeIntervalSince(started)
        return Report.render(agg: agg, root: root, assetsDir: assetsDir,
                             projectCount: folders.count, translateElapsed: translateElapsed, elapsed: elapsed)
    }

    // MARK: project dispatch

    static func scanProject(_ folder: URL, assetsDir: URL?, knownIDs: Set<String>, agg: DeepAgg) {
        guard let raw = rawJSON(folder.appendingPathComponent("project.json")) else {
            agg.sync { agg.projectJSONTotal += 1; agg.projTypeTotal["invalid", default: 0] += 1 }
            return
        }
        let project: WallpaperProject
        do { project = try ProjectJSONParser.parse(data: JSONSerialization.data(withJSONObject: raw), folderURL: folder) }
        catch {
            agg.sync { agg.projectJSONTotal += 1; agg.projTypeTotal["invalid", default: 0] += 1 }
            return
        }
        let type = project.type.storageString
        agg.sync { agg.projectJSONTotal += 1; agg.projectJSONOK += 1; agg.projTypeTotal[type, default: 0] += 1 }

        scanProperties(raw: raw, agg: agg)

        var supported = false
        switch project.type {
        case .scene:
            supported = scanScene(folder, project: project, assetsDir: assetsDir, agg: agg)
        case .video:
            supported = scanVideo(folder, project: project, agg: agg)
        case .web:
            supported = scanWeb(folder, project: project, agg: agg)
        case .preset:
            let ok = (project.dependency.map { knownIDs.contains($0) } ?? false)
            agg.sync { agg.presetTotal += 1; if ok { agg.presetResolved += 1 } }
            supported = ok
        case .application, .unknown:
            supported = false
        }
        if supported { agg.sync { agg.projTypeSupported[type, default: 0] += 1 } }
    }

    static func scanProperties(raw: [String: Any], agg: DeepAgg) {
        guard let general = raw["general"] as? [String: Any],
              let props = general["properties"] as? [String: Any] else { return }
        let parsed = WallpaperProperties.parse(generalProperties: props)
        var values: [String: PropertyValue] = [:]
        for p in parsed { values[p.key] = p.value }
        var condTotal = 0, condOK = 0
        var typeCounts: [String: Int] = [:]
        var unsupported: [String: Int] = [:]
        let known: Set<String> = ["bool", "checkbox", "slider", "combo", "color", "textinput", "text",
                                  "file", "directory", "scenetexture", "texture", "usershortcut", "group", "label"]
        for p in parsed {
            let t = p.type.lowercased()
            if !t.isEmpty { typeCounts[t, default: 0] += 1; if !known.contains(t) { unsupported[t, default: 0] += 1 } }
            if let c = p.condition, !c.isEmpty {
                condTotal += 1
                if PropertyConditionEvaluator.canEvaluate(c), PropertyConditionEvaluator.evaluate(c, values: values) != nil { condOK += 1 }
            }
        }
        agg.sync {
            agg.propsProjects += 1; agg.propsOK += 1
            agg.conditionsTotal += condTotal; agg.conditionsEvaluable += condOK
            for (k, v) in typeCounts { agg.propertyTypeCounts[k, default: 0] += v }
            for (k, v) in unsupported { agg.unsupportedPropertyTypes[k, default: 0] += v }
        }
    }

    // MARK: scene

    static func scanScene(_ folder: URL, project: WallpaperProject, assetsDir: URL?, agg: DeepAgg) -> Bool {
        agg.sync { agg.sceneAttempt += 1 }
        guard let pkgURL = firstExisting([folder.appendingPathComponent("scene.pkg"),
                                          folder.appendingPathComponent("gifscene.pkg")]),
              // memory-map: a 700MB pkg stays paged instead of resident, so N concurrent scenes don't OOM.
              let pkgData = try? Data(contentsOf: pkgURL, options: .mappedIfSafe),
              let package = try? ScenePackage.parse(pkgData) else {
            return false
        }
        let res = PkgAssets(package: package, assetsDir: assetsDir)

        // 1) scene parse (real code path, with base-assets resolution)
        let doc: SceneDocument
        do { doc = try SceneDocument.parse(package: package, assets: { res.baseAssetURL($0).flatMap { try? Data(contentsOf: $0) } }) }
        catch { return false }
        agg.sync {
            agg.sceneParseOK += 1
            agg.layerCount += doc.layers.count
            agg.puppetLayers += doc.layers.filter { $0.puppet != nil }.count
            agg.effectLayers += doc.layers.filter { !$0.effects.isEmpty }.count
            agg.particleObjs += doc.particles.count
            agg.textObjs += doc.texts.count
            agg.model3DObjs += doc.objects3D.count
            agg.lightObjs += doc.lights3D.count
            agg.soundObjs += doc.sounds.count
        }

        // 2) TEX: every .tex entry in the package (decode all image pages)
        var texAllOK = true
        for entry in package.entries where entry.name.lowercased().hasSuffix(".tex") {
            if !decodeTex(name: entry.name, data: pkgData, res: res, provenance: "\(project.id)/\(entry.name)", agg: agg, asset: false) {
                texAllOK = false
            }
        }

        // 3) shaders (effect translate path)
        scanEffects(doc: doc, res: res, projectID: project.id, agg: agg)

        // 4) models: every .mdl entry
        var modelsAllOK = true
        for entry in package.entries where entry.name.lowercased().hasSuffix(".mdl") {
            if !parseModel(name: entry.name, package: package, provenance: "\(project.id)/\(entry.name)", agg: agg) {
                modelsAllOK = false
            }
        }

        // 5) particles: every particles/*.json entry
        var particlesAllOK = true
        for entry in package.entries where entry.name.lowercased().hasPrefix("particles/") && entry.name.lowercased().hasSuffix(".json") {
            if !parseParticle(name: entry.name, package: package, provenance: "\(project.id)/\(entry.name)", agg: agg) {
                particlesAllOK = false
            }
        }

        // 6) scene sounds present + format
        scanSceneSounds(doc: doc, package: package, agg: agg)

        // scene "supported" (strict): parse ok + all attempted core assets decode/parse.
        let ok = texAllOK && modelsAllOK && particlesAllOK
        if ok { agg.sync { agg.sceneSupported += 1 } }
        return ok
    }

    // MARK: TEX decode

    /// Returns true if TexImage.parse succeeded AND every image page decoded. Buckets by format.
    static func decodeTex(name: String, data pkgData: Data, res: PkgAssets, provenance: String, agg: DeepAgg, asset: Bool) -> Bool {
        return autoreleasepool { () -> Bool in
            guard let texData = asset ? try? Data(contentsOf: URL(fileURLWithPath: name)) : res.pkgData(name) else {
                return false
            }
            guard let tex = TexImage.parse(texData) else {
                agg.sync {
                    if asset { agg.assetTexAttempt += 1 } else { agg.texAttempt += 1; agg.addSample(&agg.texFailSamples, "parse-fail", provenance) }
                }
                return false
            }
            let bucket = formatBucket(tex)
            // frame / atlas / gif accounting
            agg.sync {
                if asset { agg.assetTexAttempt += 1; agg.assetTexParseOK += 1 }
                else {
                    agg.texAttempt += 1; agg.texParseOK += 1
                    if !tex.frames.isEmpty { agg.texWithFrames += 1; agg.framesTotal += tex.frames.count
                        agg.framesRotated += tex.frames.filter { $0.rotationQuarters != 0 }.count }
                    if tex.imageCount > 1 { agg.atlasMulti += 1 }
                    if tex.isGif { agg.gifFlagged += 1 }
                    if tex.payload == .video || tex.isVideoTexture { agg.videoTex += 1 }
                }
            }
            // Video-texture container (TEXB0004 mp4): played through the AVFoundation/video path, never
            // RGBA-decoded. It is a supported asset by design, so don't score it against the decode rate.
            if tex.payload == .video { return true }
            // decode each image page (mip0). .unknown = genuinely unsupported format → counts as a failure.
            let pages = max(1, tex.imageCount)
            var allOK = true
            for page in 0..<pages {
                let decoded = TexDecoder.rgba(from: tex, data: texData, imageIndex: page) != nil
                if !decoded { allOK = false }
                agg.sync {
                    if asset {
                        agg.assetTexPageOK += decoded ? 1 : 0
                        var e = agg.assetTexByFormat[bucket] ?? (0, 0); e.att += 1; if decoded { e.ok += 1 }; agg.assetTexByFormat[bucket] = e
                    } else {
                        agg.texPageAttempt += 1; if decoded { agg.texPageOK += 1 }
                        var e = agg.texByFormat[bucket] ?? (0, 0); e.att += 1; if decoded { e.ok += 1 }; agg.texByFormat[bucket] = e
                        if !decoded { agg.addSample(&agg.texFailSamples, bucket, provenance) }
                    }
                }
            }
            return allOK
        }
    }

    static func formatBucket(_ tex: TexImage) -> String {
        switch tex.payload {
        case .png: return "embedded-png"
        case .jpeg: return "embedded-jpeg"
        case .embeddedImage: return "embedded-image(fmt\(tex.format))"
        case .rawRGBA8888: return "raw-rgba"
        case .lz4RGBA: return "fmt0-lz4rgba"
        case .bc3: return "fmt4-bc3"
        case .bc2: return "fmt6-bc2"
        case .bc1: return "fmt7-bc1"
        case .rg88: return "fmt8-rg88"
        case .r8: return "fmt9-r8"
        case .video: return "video-mp4"
        case .unknown: return "unknown-fmt\(tex.format)"
        }
    }

    static func scanAssetTextures(_ assetsDir: URL, agg: DeepAgg) {
        guard let en = FileManager.default.enumerator(at: assetsDir, includingPropertiesForKeys: nil) else { return }
        var texFiles: [URL] = []
        for case let u as URL in en where u.pathExtension.lowercased() == "tex" { texFiles.append(u) }
        DispatchQueue.concurrentPerform(iterations: texFiles.count) { i in
            _ = decodeTex(name: texFiles[i].path, data: Data(), res: PkgAssets(package: ScenePackage.assemble([]), assetsDir: nil),
                          provenance: texFiles[i].lastPathComponent, agg: agg, asset: true)
        }
    }

    // MARK: effect shader translate path (mirrors buildTranslatedEffect enumeration)

    static func scanEffects(doc: SceneDocument, res: PkgAssets, projectID: String, agg: DeepAgg) {
        var effects: [SceneEffect] = []
        for l in doc.layers { effects.append(contentsOf: l.effects) }
        for o in doc.objects3D { effects.append(contentsOf: o.effects) }
        for eff in effects {
            agg.sync { agg.effectInstances += 1 }
            if handPortNames.contains(eff.name) {   // stock effects Waple renders via hand-ported MSL (buildHandPortEffect)
                agg.sync { agg.effectHandPort += 1 }
                continue
            }
            let manifest = loadManifest(eff, res: res)
            for (i, mp) in manifest.passes.enumerated() {
                if mp.command == "copy" { continue }   // shader-less command pass
                let meta = resolveShaderMeta(mp, eff: eff, res: res)
                guard let vData = res.assetData("shaders/\(meta.base).vert"),
                      let fData = res.assetData("shaders/\(meta.base).frag"),
                      let vert = String(data: vData, encoding: .utf8),
                      let frag = String(data: fData, encoding: .utf8) else {
                    agg.sync { agg.effectShaderMissing += 1 }
                    continue
                }
                let scenePass = i < eff.passList.count ? eff.passList[i] : SceneEffectPass()
                let combos = resolveCombos(frag: frag, scenePass: scenePass, matCombos: meta.matCombos, matTextures: meta.matTextures)
                let provenance = "\(projectID)/\(eff.name)#\(i) [\(meta.base)]"
                agg.sync { agg.translateAttempt += 1 }
                if let t = GLSLTranslator.translate(vertex: vert, fragment: frag, combos: combos, include: res.include) {
                    agg.sync {
                        agg.translateOK += 1
                        if agg.mslJobs[t.msl] == nil { agg.mslJobs[t.msl] = provenance }
                    }
                } else {
                    agg.sync { if agg.translateFailSamples.count < 40 { agg.translateFailSamples.append(provenance) } }
                }
            }
        }
    }

    static func loadManifest(_ eff: SceneEffect, res: PkgAssets) -> EffectManifest {
        let path = eff.file.isEmpty ? "effects/\(eff.name)/effect.json" : eff.file
        if let d = res.assetData(path), let m = EffectManifest.parse(d) { return m }
        return EffectManifest(passes: [.init(material: nil, shader: nil, target: nil, binds: [])], fbos: [])
    }

    static func resolveShaderMeta(_ mp: EffectManifest.Pass, eff: SceneEffect, res: PkgAssets)
        -> (base: String, matCombos: [String: Int], matTextures: [String?]) {
        var shaderName = mp.shader
        var matCombos: [String: Int] = [:]
        var matTextures: [String?] = []
        if shaderName == nil, let matPath = mp.material,
           let mData = res.assetData(matPath),
           let mjson = (try? JSONSerialization.jsonObject(with: mData)) as? [String: Any],
           let mp0 = (mjson["passes"] as? [Any])?.first as? [String: Any] {
            shaderName = mp0["shader"] as? String
            for (k, v) in (mp0["combos"] as? [String: Any]) ?? [:] {
                if let n = v as? Int { matCombos[k] = n } else if let d = v as? Double { matCombos[k] = Int(d) }
            }
            if let texs = mp0["textures"] as? [Any] { matTextures = texs.map { $0 as? String } }
        }
        return (shaderName ?? "effects/\(eff.name)", matCombos, matTextures)
    }

    static func resolveCombos(frag: String, scenePass: SceneEffectPass, matCombos: [String: Int], matTextures: [String?]) -> [String: Int] {
        var combos = matCombos
        for (k, v) in scenePass.combos { combos[k] = v }
        for (slot, comboName) in GLSLTranslator.samplerCombos(frag) where combos[comboName] == nil {
            let sceneBound = slot < scenePass.textureNames.count && scenePass.textureNames[slot] != nil
            let matBound = slot < matTextures.count && matTextures[slot] != nil
            if sceneBound || matBound { combos[comboName] = 1 }
        }
        return combos
    }

    // MARK: deferred Metal compile

    static func compileShaders(agg: DeepAgg) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let jobs = Array(agg.mslJobs)   // [(msl, provenance)]
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            autoreleasepool {
                let (msl, prov) = jobs[i]
                agg.sync { agg.compileAttempt += 1 }
                do {
                    let lib = try device.makeLibrary(source: msl, options: nil)
                    let ok = lib.makeFunction(name: "ev_main") != nil && lib.makeFunction(name: "ef_main") != nil
                    agg.sync {
                        if ok { agg.compileOK += 1 }
                        else { agg.addSample(&agg.compileFailClusters, "missing-entrypoint", prov) }
                    }
                } catch {
                    let token = firstErrorToken("\(error)")
                    agg.sync { agg.addSample(&agg.compileFailClusters, token, prov) }
                }
            }
        }
    }

    static func firstErrorToken(_ s: String) -> String {
        // Grab the compiler diagnostic after "error:", strip file/line/column noise, keep the message head.
        for line in s.split(separator: "\n") where line.contains("error:") {
            let msg = line.range(of: "error:").map { String(line[$0.upperBound...]) } ?? String(line)
            let trimmed = msg.trimmingCharacters(in: .whitespaces)
            return String(trimmed.prefix(80))
        }
        return "unknown"
    }

    // MARK: models

    static func parseModel(name: String, package: ScenePackage, provenance: String, agg: DeepAgg) -> Bool {
        return autoreleasepool { () -> Bool in
            guard let data = package.data(for: name) else { return false }
            let magic = data.count >= 8 ? String(data: data.prefix(8), encoding: .utf8) ?? "non-ascii" : "short"
            let ok = Model3D.parse(data) != nil || PuppetModel.parse(data) != nil
            agg.sync {
                agg.mdlAttempt += 1; if ok { agg.mdlOK += 1 }
                var e = agg.mdlByMagic[magic] ?? (0, 0); e.att += 1; if ok { e.ok += 1 }; agg.mdlByMagic[magic] = e
                if !ok { agg.addSample(&agg.mdlFailSamples, magic, provenance) }
            }
            return ok
        }
    }

    // MARK: particles

    static func parseParticle(name: String, package: ScenePackage, provenance: String, agg: DeepAgg) -> Bool {
        return autoreleasepool { () -> Bool in
            guard let data = package.data(for: name),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                agg.sync { agg.particleFileAttempt += 1; if agg.particleFailSamples.count < 8 { agg.particleFailSamples.append(provenance) } }
                return false
            }
            var material: ParticleMaterial? = nil
            if let matPath = json["material"] as? String, let mData = package.data(for: matPath),
               let mjson = (try? JSONSerialization.jsonObject(with: mData)) as? [String: Any] {
                material = ParticleMaterial.parse(mjson)
            }
            let def = ParticleSystemDef.parse(json, material: material) { childPath in
                (package.data(for: childPath)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                    .map { ParticleSystemDef.parse($0, material: nil) }
            }
            // ParticleSystemDef.parse always returns a def; treat "has an emitter or initializer" as a real parse.
            let parseOK = !def.emitters.isEmpty || !def.initializers.isEmpty || !def.operators.isEmpty
            let sim = ParticleSimulator(def: def, seed: 0x9E3779B97F4A7C15)
            let simOK = sim.liveCount >= 0   // constructing the simulator did not trap
            agg.sync {
                agg.particleFileAttempt += 1
                if parseOK { agg.particleParseOK += 1 }
                if simOK { agg.particleSimOK += 1 }
                if !parseOK && agg.particleFailSamples.count < 8 { agg.particleFailSamples.append(provenance) }
            }
            return parseOK
        }
    }

    // MARK: sounds

    static func scanSceneSounds(doc: SceneDocument, package: ScenePackage, agg: DeepAgg) {
        for sound in doc.sounds {
            for path in sound.sounds {
                let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                let present = package.data(for: path) != nil
                agg.sync {
                    agg.soundRefs += 1; if present { agg.soundPresent += 1 }
                    if !ext.isEmpty { agg.soundByExt[ext, default: 0] += 1 }
                }
            }
        }
    }

    // MARK: video

    static func scanVideo(_ folder: URL, project: WallpaperProject, agg: DeepAgg) -> Bool {
        guard let file = project.fileName else {
            agg.sync { agg.videoTotal += 1; agg.videoUnknownContainer += 1 }
            return false
        }
        let ext = URL(fileURLWithPath: file).pathExtension.lowercased()
        let url = folder.appendingPathComponent(file)
        if VideoRenderer.nativeVideoExtensions.contains(ext) {
            // header-only probe: AVURLAsset.isPlayable reads container headers, not the whole file.
            let asset = AVURLAsset(url: url)
            let playable = asset.isPlayable && !asset.tracks(withMediaType: .video).isEmpty
            agg.sync {
                agg.videoTotal += 1
                if playable { agg.videoNativePlayable += 1 } else { agg.videoNativeUnplayable += 1; agg.addSample2(&agg.videoFailSamples, "\(project.id)/\(file)") }
            }
            return playable
        } else if VideoRenderer.unsupportedExtensions.contains(ext) {
            agg.sync { agg.videoTotal += 1; agg.videoConvertible += 1 }
            return true   // supported-in-principle via FFmpegConverter (availability reported separately)
        } else {
            agg.sync { agg.videoTotal += 1; agg.videoUnknownContainer += 1; agg.addSample2(&agg.videoFailSamples, "\(project.id)/\(file)") }
            return false
        }
    }

    // MARK: web

    static func scanWeb(_ folder: URL, project: WallpaperProject, agg: DeepAgg) -> Bool {
        let present = project.fileName.flatMap { WallpaperPathSecurity.containedFileURL($0, root: folder) }
            .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        var randomFile = false, serviceWorker = false
        if let entry = project.fileName, let url = WallpaperPathSecurity.containedFileURL(entry, root: folder),
           let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            randomFile = text.contains("wallpaperRequestRandomFileForProperty")
            serviceWorker = text.range(of: "serviceWorker", options: .caseInsensitive) != nil
        }
        agg.sync {
            agg.webTotal += 1
            if present { agg.webIndexPresent += 1 }
            if randomFile { agg.webRandomFile += 1 }
            if serviceWorker { agg.webServiceWorker += 1 }
        }
        return present
    }

    // MARK: helpers

    static func projectContainer(_ root: URL) -> URL {
        let bg = root.appendingPathComponent("backgrounds", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: bg.appendingPathComponent("project.json").path) { return root }
        if FileManager.default.fileExists(atPath: bg.path, isDirectory: &isDir), isDir.boolValue { return bg.standardizedFileURL }
        return root
    }

    static func projectFolders(_ container: URL) -> [URL] {
        if FileManager.default.fileExists(atPath: container.appendingPathComponent("project.json").path) { return [container] }
        let entries = (try? FileManager.default.contentsOfDirectory(at: container, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("project.json").path)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func rawJSON(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func firstExisting(_ urls: [URL]) -> URL? {
        for u in urls where FileManager.default.fileExists(atPath: u.path) { return u }
        return nil
    }
}

extension DeepAgg {
    func addSample2(_ arr: inout [String], _ path: String, cap: Int = 8) {
        if arr.count < cap { arr.append(path) }
    }
}
