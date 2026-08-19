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
        // F138/F139/F143: 헤드라인 "supported" 는 핵심 에셋(tex/model/particle) 파싱 + 컨테이너 프로브
        // 기준이다 — 이펙트 셰이더 번역/컴파일과 사운드 디코드는 별도 절(아래)로만 보고되고 이 열에는
        // 반영되지 않는다. 비-네이티브 비디오(webm/mkv 등)는 확장자만으로 "supported-in-principle" 처리되며
        // 실제 ffmpeg 가용성/디코드 프로브는 하지 않는다 — "ffmpeg present" 값을 함께 봐야 한다.
        p("> **참고(집계 기준)**: 이 표의 `supported` 는 프로젝트 타입별 *핵심 에셋 파싱 성공* 기준입니다 —")
        p(">   scene = tex/model/particle 전부 파싱·디코드 성공(이펙트 셰이더 번역/컴파일·사운드 디코드는")
        p(">   미포함, 아래 'Effect shaders'/'Scene audio' 절 참고); video = 네이티브 컨테이너는 AVFoundation")
        p(">   프로브, 비-네이티브(webm/mkv 등)는 확장자만으로 in-principle 처리(디코드 프로브 없음, 아래")
        p(">   'ffmpeg present' 값 참고); web = index 파일 존재 여부만. 즉 이 열은 '렌더 정확도'가 아니라")
        p(">   '파싱 가능성'의 상한입니다.")
        p("")
        p("project.json parsed: \(agg.projectJSONOK)/\(agg.projectJSONTotal) (\(pct(agg.projectJSONOK, agg.projectJSONTotal)))")
        p("properties parsed: \(agg.propsProjects); display conditions evaluable: \(agg.conditionsEvaluable)/\(agg.conditionsTotal) (\(pct(agg.conditionsEvaluable, agg.conditionsTotal)))")
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
        if agg.metalDeviceUnavailable {
            // F140: 조용한 0/0="n/a" 대신 이유를 명시 — 헤드리스/무-Metal 환경에서 컴파일 검증이
            // 전혀 수행되지 않았음을 눈에 띄게 알린다(exit code 는 여전히 0 — 별도 셸 게이트 필요).
            p("- **Metal compile**: SKIPPED — no Metal-capable GPU device on this host (compile verification NOT performed, not the same as 0%)")
        } else {
            p("- **Metal compile** (unique MSL): \(agg.compileOK)/\(agg.compileAttempt) (\(pct(agg.compileOK, agg.compileAttempt)))")
        }
        // F139: 위 두 수치는 패스 단위 집계다 — 실제 렌더러(SceneRendererResources.buildTranslatedEffect)는
        // 화면-출력 패스가 0개이거나 bind/target 이름이 해석되지 않으면 *이펙트 전체*를 nil 로 폐기한다.
        // 이 스캔은 그 이펙트-단위 게이트를 미러링하지 않으므로, 개별 패스가 전부 번역/컴파일에 성공해도
        // 실제로는 화면에 그려지지 않을 이펙트가 위 비율에 포함될 수 있다.
        p("> 참고: 위 비율은 *패스* 단위이며, 렌더러가 이펙트 전체를 폐기하는 조건(출력 패스 0개, bind/target")
        p("> 이름 미해석)은 반영하지 않습니다 — 실제 화면 출력 성공률의 상한치로 읽으세요.")
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
        // F143: 위 non-native 건수는 위 'ALL' 헤드라인 표에 supported 로 그대로 합산되지만, 확장자만
        // 보고 판정하며 실제 디코드 프로브는 없다(ffmpeg 미가용/파일손상이어도 supported). 아래 값이
        // false 면 이 non-native 건들은 이 머신에서 실제로는 재생 불가하다.
        p("- unknown container: \(agg.videoUnknownContainer)")
        p("- ffmpeg present on this machine: \(FFmpegConverter.isAvailable)\(FFmpegConverter.isAvailable ? "" : "  ⚠️ non-native \(agg.videoConvertible)건은 이 머신에서 실제로는 재생 불가(위 헤드라인엔 supported 로 집계됨)")")
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
            // F681: 시간 예산으로 걸러넘긴 파일은 시도 분모에서 제외하고 별도 표기(실패로 오분류 금지).
            let oggAttempted = agg.oggRefs - agg.oggSkippedBudget
            let oggSkipNote = agg.oggSkippedBudget > 0
                ? ", skipped(time-budget, 누적 \(Int(DeepScan.oggDecodeTimeBudget))s 상한)=\(agg.oggSkippedBudget)"
                : ""
            p("- ogg(Vorbis) pure-Swift decode: \(agg.oggDecodeOK)/\(oggAttempted) OK (\(pct(agg.oggDecodeOK, oggAttempted))), fail=\(agg.oggDecodeFail), NaN/Inf=\(agg.oggNaN), silent=\(agg.oggSilent)\(oggSkipNote)")
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
