import Foundation
import WapleRender

enum Report {
    static func pct(_ n: Int, _ d: Int) -> String {
        guard d > 0 else { return "n/a" }
        return String(format: "%.1f%%", Double(n) * 100.0 / Double(d))
    }

    static func render(agg: DeepAgg, root: URL, assetsDir: URL?, projectCount: Int,
                       translateElapsed: TimeInterval, elapsed: TimeInterval) -> String {
        var L: [String] = []
        func p(_ s: String) { L.append(s) }

        p("# Waple Deep Compatibility Report")
        p("")
        p("- root: `\(root.path)`")
        p("- base assets: `\(assetsDir?.path ?? "none")`")
        p("- projects scanned: \(projectCount)")
        p("- wall clock: \(String(format: "%.1fs", elapsed)) (translate+decode \(String(format: "%.1fs", translateElapsed)), compile \(String(format: "%.1fs", elapsed - translateElapsed)))")
        p("")

        // ---- project-level ----
        p("## Project-level support")
        let types = Set(agg.projTypeTotal.keys).union(agg.projTypeSupported.keys).sorted()
        var totalAll = 0, supAll = 0
        p("| type | total | supported | rate |")
        p("|------|------:|----------:|-----:|")
        for t in types {
            let tot = agg.projTypeTotal[t] ?? 0
            let sup = agg.projTypeSupported[t] ?? 0
            totalAll += tot; supAll += sup
            p("| \(t) | \(tot) | \(sup) | \(pct(sup, tot)) |")
        }
        p("| **ALL** | **\(totalAll)** | **\(supAll)** | **\(pct(supAll, totalAll))** |")
        p("")
        p("project.json parsed: \(agg.projectJSONOK)/\(agg.projectJSONTotal) (\(pct(agg.projectJSONOK, agg.projectJSONTotal)))")
        p("properties parsed: \(agg.propsOK)/\(agg.propsProjects); display conditions evaluable: \(agg.conditionsEvaluable)/\(agg.conditionsTotal) (\(pct(agg.conditionsEvaluable, agg.conditionsTotal)))")
        p("")

        // ---- scenes ----
        p("## Scenes")
        p("- SceneDocument parsed: \(agg.sceneParseOK)/\(agg.sceneAttempt) (\(pct(agg.sceneParseOK, agg.sceneAttempt)))")
        p("- scenes fully supported (parse + all tex/model/particle ok): \(agg.sceneSupported)/\(agg.sceneAttempt) (\(pct(agg.sceneSupported, agg.sceneAttempt)))")
        p("- layers: \(agg.layerCount) (puppet: \(agg.puppetLayers), with-effects: \(agg.effectLayers)); particle objs: \(agg.particleObjs); text: \(agg.textObjs); 3D objs: \(agg.model3DObjs); lights: \(agg.lightObjs); sound objs: \(agg.soundObjs)")
        p("")

        // ---- TEX ----
        p("## Textures (.tex, pkg-internal)")
        p("- entries parsed by TexImage: \(agg.texParseOK)/\(agg.texAttempt) (\(pct(agg.texParseOK, agg.texAttempt)))")
        p("- image pages RGBA-decoded: \(agg.texPageOK)/\(agg.texPageAttempt) (\(pct(agg.texPageOK, agg.texPageAttempt)))")
        p("- TEXS sheets: \(agg.texWithFrames) tex, \(agg.framesTotal) frames (rotated: \(agg.framesRotated)); multi-image atlases: \(agg.atlasMulti); IsGif flagged: \(agg.gifFlagged); video-tex: \(agg.videoTex)")
        p("")
        p("| format bucket | pages | decoded | rate |")
        p("|---------------|------:|--------:|-----:|")
        for k in agg.texByFormat.keys.sorted() {
            let e = agg.texByFormat[k]!
            p("| \(k) | \(e.att) | \(e.ok) | \(pct(e.ok, e.att)) |")
        }
        p("")
        if !agg.texFailSamples.isEmpty {
            p("### TEX decode failures (samples)")
            for k in agg.texFailSamples.keys.sorted() {
                p("- **\(k)**: \(agg.texFailSamples[k]!.joined(separator: " | "))")
            }
            p("")
        }

        // ---- stock asset textures ----
        p("## Stock asset textures (assets/**/*.tex)")
        p("- parsed: \(agg.assetTexParseOK)/\(agg.assetTexAttempt) (\(pct(agg.assetTexParseOK, agg.assetTexAttempt))); pages decoded: \(agg.assetTexPageOK)")
        p("| format bucket | pages | decoded | rate |")
        p("|---------------|------:|--------:|-----:|")
        for k in agg.assetTexByFormat.keys.sorted() {
            let e = agg.assetTexByFormat[k]!
            p("| \(k) | \(e.att) | \(e.ok) | \(pct(e.ok, e.att)) |")
        }
        p("")

        // ---- shaders ----
        p("## Effect shaders (GLSL -> Metal translate path)")
        p("- effect instances referenced by scenes: \(agg.effectInstances)")
        p("- resolved via hand-port stock effect: \(agg.effectHandPort)")
        p("- shader files missing (skipped): \(agg.effectShaderMissing)")
        p("- **GLSL translate**: \(agg.translateOK)/\(agg.translateAttempt) (\(pct(agg.translateOK, agg.translateAttempt)))")
        p("- **Metal compile** (unique MSL): \(agg.compileOK)/\(agg.compileAttempt) (\(pct(agg.compileOK, agg.compileAttempt)))")
        p("")
        if !agg.translateFailSamples.isEmpty {
            p("### translate failures (samples)")
            for s in agg.translateFailSamples.prefix(20) { p("- \(s)") }
            p("")
        }
        if !agg.compileFailClusters.isEmpty {
            p("### Metal compile failure clusters")
            for k in agg.compileFailClusters.keys.sorted(by: { agg.compileFailClusters[$0]!.count > agg.compileFailClusters[$1]!.count }) {
                p("- **\(k)**")
                for s in agg.compileFailClusters[k]! { p("    - \(s)") }
            }
            p("")
        }

        // ---- models ----
        p("## Models (.mdl)")
        p("- parsed (Model3D or PuppetModel): \(agg.mdlOK)/\(agg.mdlAttempt) (\(pct(agg.mdlOK, agg.mdlAttempt)))")
        p("| magic | files | parsed | rate |")
        p("|-------|------:|-------:|-----:|")
        for k in agg.mdlByMagic.keys.sorted() {
            let e = agg.mdlByMagic[k]!
            p("| \(k) | \(e.att) | \(e.ok) | \(pct(e.ok, e.att)) |")
        }
        if !agg.mdlFailSamples.isEmpty {
            p("")
            p("### model parse failures (samples)")
            for k in agg.mdlFailSamples.keys.sorted() { p("- **\(k)**: \(agg.mdlFailSamples[k]!.joined(separator: " | "))") }
        }
        p("")

        // ---- particles ----
        p("## Particles (particles/*.json)")
        p("- parsed: \(agg.particleParseOK)/\(agg.particleFileAttempt) (\(pct(agg.particleParseOK, agg.particleFileAttempt)))")
        p("- ParticleSimulator built: \(agg.particleSimOK)/\(agg.particleFileAttempt) (\(pct(agg.particleSimOK, agg.particleFileAttempt)))")
        if !agg.particleFailSamples.isEmpty { p("- failures: \(agg.particleFailSamples.joined(separator: " | "))") }
        p("")

        // ---- videos ----
        p("## Videos")
        p("- total: \(agg.videoTotal)")
        p("- native container + AVFoundation playable: \(agg.videoNativePlayable) (\(pct(agg.videoNativePlayable, agg.videoTotal)))")
        p("- native container but not playable: \(agg.videoNativeUnplayable)")
        p("- non-native (webm/... -> FFmpegConverter, supported-in-principle): \(agg.videoConvertible)")
        p("- unknown container: \(agg.videoUnknownContainer)")
        p("- ffmpeg present on this machine: \(FFmpegConverter.isAvailable)")
        if !agg.videoFailSamples.isEmpty { p("- fail/unknown samples: \(agg.videoFailSamples.joined(separator: " | "))") }
        p("")

        // ---- web ----
        p("## Web")
        p("- total: \(agg.webTotal); index present: \(agg.webIndexPresent) (\(pct(agg.webIndexPresent, agg.webTotal)))")
        p("- randomFile bridge usage: \(agg.webRandomFile); serviceWorker: \(agg.webServiceWorker)")
        p("")

        // ---- audio ----
        p("## Scene audio (sound layers)")
        p("- referenced sound files present in pkg: \(agg.soundPresent)/\(agg.soundRefs) (\(pct(agg.soundPresent, agg.soundRefs)))")
        p("- by extension: " + agg.soundByExt.keys.sorted().map { "\($0)=\(agg.soundByExt[$0]!)" }.joined(separator: ", "))
        if agg.oggRefs > 0 {
            p("- ogg(Vorbis) pure-Swift decode: \(agg.oggDecodeOK)/\(agg.oggRefs) OK (\(pct(agg.oggDecodeOK, agg.oggRefs))), fail=\(agg.oggDecodeFail), NaN/Inf=\(agg.oggNaN), silent=\(agg.oggSilent)")
            p("  - channels: " + agg.oggChannels.keys.sorted().map { "\($0)ch=\(agg.oggChannels[$0]!)" }.joined(separator: ", ")
              + " | rates: " + agg.oggRates.keys.sorted().map { "\($0)=\(agg.oggRates[$0]!)" }.joined(separator: ", "))
            if !agg.oggFailSamples.isEmpty { p("  - flagged: " + agg.oggFailSamples.joined(separator: ", ")) }
        }
        p("")

        // ---- properties ----
        p("## Property types (across all projects)")
        p("- " + agg.propertyTypeCounts.keys.sorted().map { "\($0)=\(agg.propertyTypeCounts[$0]!)" }.joined(separator: ", "))
        if !agg.unsupportedPropertyTypes.isEmpty {
            p("- not editable by Waple panel: " + agg.unsupportedPropertyTypes.keys.sorted().map { "\($0)=\(agg.unsupportedPropertyTypes[$0]!)" }.joined(separator: ", "))
        }
        p("")

        return L.joined(separator: "\n")
    }
}
