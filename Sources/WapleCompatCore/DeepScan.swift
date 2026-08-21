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

/// WapleRender 의 SemaphoreResultBox(internal)는 모듈 밖이라 못 쓰므로 로컬 사본 —
/// Swift 5.10 @Sendable Task 캡처 var 변경 에러(CI macos-14) 대응. signal→wait 가 직렬화를 보장.
private final class SemaphoreResultBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// `@unchecked Sendable` 근거: **모든 가변 필드는 `sync {}`(NSLock) 안에서만 만진다.**
/// 이 집계기는 `DispatchQueue.concurrentPerform` 워커 수십 개가 동시에 두드리는 유일한 공유
/// 상태이고, 그래서 애초에 락을 들고 태어났다(`sync` 가 그 락이다). 락 밖에서 필드를 읽는 곳은
/// 병렬 구간이 **전부 끝난 뒤**의 집계·리포트뿐이다(`DeepScan.run` 의 reduce, `Report.render`).
/// 컴파일러는 그 규율을 볼 수 없다 — 새 필드를 더할 때도 접근은 반드시 `sync {}` 를 거칠 것.
final class DeepAgg: @unchecked Sendable {
    private let lock = NSLock()
    func sync<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    // project-level
    var projTypeTotal: [String: Int] = [:]
    var projTypeSupported: [String: Int] = [:]
    var projectJSONTotal = 0, projectJSONOK = 0
    var propsProjects = 0
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
    // F140: GPU 디바이스가 없어 컴파일 패스 자체가 통째로 스킵됐는지(0/0="n/a" 를 "미실행"과 구분).
    var metalDeviceUnavailable = false

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
    // ogg(Vorbis) 순수 Swift 디코드 전수 검증(참조 파일별): 에러 0 / 헤더 정합 / 비무음 / NaN 없음.
    var oggRefs = 0, oggDecodeOK = 0, oggDecodeFail = 0, oggSilent = 0, oggNaN = 0
    var oggChannels: [Int: Int] = [:], oggRates: [Int: Int] = [:]
    var oggFailSamples: [String] = []
    // F681: ogg 전수 디코드가 스캔 벽시계를 지배(실측 wall 2522s 중 translate+decode 2519s) — 누적 디코드
    // 시간이 예산(DeepScan.oggDecodeTimeBudget)을 넘으면 나머지는 디코드 없이 refs 만 센다(실패 아님).
    var oggSkippedBudget = 0
    var oggDecodeSeconds = 0.0

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
        // 렌더러 baseAssetURL 과 동일한 realpath 재검증 — 심링크 경유 탈출 차단(사본 간 divergence 해소).
        let realRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let realCurrent = current.resolvingSymlinksInPath().standardizedFileURL
        guard WallpaperPathSecurity.contains(realCurrent, in: realRoot) else { return nil }
        return current
    }

    func assetData(_ name: String) -> Data? {
        if let d = pkgData(name) { return d }
        if let u = baseAssetURL(name) { return try? Data(contentsOf: u) }
        return nil
    }

    /// 이펙트-로컬 자산 루트 우선 조회 — 렌더러 `SceneRenderer.effectScopedData` 와 **동형**이어야 한다.
    /// 스톡 이펙트 46/46 이 자기 `shaders/`·`materials/` 를 갖고 팩 루트엔 `shaders/effects/` 가 아예
    /// 없으므로, 스코프를 안 하면 스캐너는 렌더러가 실제로 번역하는 46종을 전부 "셰이더 없음" 으로
    /// 보고한다. 순서도 같다 — pkg 가 베이스를 **항상** 이기고, 각 출처 안에서만 로컬이 앞선다.
    func scopedData(_ name: String, root: String?) -> Data? {
        let scoped: String? = (root?.isEmpty == false) ? "\(root!)/\(name)" : nil
        if let s = scoped, let d = pkgData(s) { return d }
        if let d = pkgData(name) { return d }
        if let s = scoped, let u = baseAssetURL(s), let d = try? Data(contentsOf: u) { return d }
        if let u = baseAssetURL(name) { return try? Data(contentsOf: u) }
        return nil
    }

    /// `SceneRenderer.effectLocalRoot` 와 동형(백슬래시 정규화 포함).
    static func effectLocalRoot(_ eff: SceneEffect) -> String? {
        if !eff.file.isEmpty {
            let normalized = eff.file.replacingOccurrences(of: "\\", with: "/")
            guard let slash = normalized.lastIndex(of: "/") else { return nil }
            let dir = String(normalized[normalized.startIndex..<slash])
            return dir.isEmpty ? nil : dir
        }
        return eff.name.isEmpty ? nil : "effects/\(eff.name)"
    }

    // #include resolver: pkg shaders/<h> -> pkg <h> -> base-assets -> builtin (mirrors buildTranslatedEffect).
    func include(_ header: String) -> String? { scopedInclude(header, root: nil) }

    /// 렌더러의 include 클로저와 동형 — 이펙트-로컬 루트를 먼저 본다.
    /// 동봉 팩에 이펙트-로컬 `.h` 는 0개라 지금은 결과가 같지만, 스캐너가 렌더러와 **다른 규약**으로
    /// 도는 것 자체가 오라클을 못 믿게 만든다.
    func scopedInclude(_ header: String, root: String?) -> String? {
        for cand in ["shaders/\(header)", header] {
            if let d = scopedData(cand, root: root), let s = String(data: d, encoding: .utf8) { return s }
        }
        return BuiltinShaderIncludes.lookup(header)
    }
}

// MARK: - Deep scanner

/// 병렬 스캔 워커에 넘기는 **읽기 전용** 입력 묶음.
///
/// `@unchecked Sendable` 근거: 세 필드 모두 스캔이 시작되기 전에 확정되고 그 뒤로는 아무도
/// 변형하지 않는다(워커는 읽기만 한다). `WallpaperType` 은 연관값 없는 enum 이고 `URL` 은 이미
/// Sendable 이지만, WapleCore 의 public 타입이라 자동 `Sendable` 추론을 받지 못해 컴파일러가
/// 그 사실을 볼 수 없다 — `@preconcurrency import WapleCore` 로 모듈 전체를 덮는 대신 실제로
/// 큐를 넘는 이 값들만 국소적으로 표시한다(WapleCore 가 나중에 Sendable 을 선언해도 무해).
private struct DeepScanInputs: @unchecked Sendable {
    let folders: [URL]
    let knownTypes: [String: WallpaperType]
    let assetsDir: URL?
}

public enum DeepScan {
    static let handPortNames: Set<String> = ["opacity", "tint", "pulse", "waterripple", "scroll", "waterwaves", "shake"]

    /// F681: ogg 디코드 누적 시간 예산(초). 순수 Swift Vorbis 디코드는 Debug 빌드에서 0.9MB ≈ 21s 라
    /// 음악 다수 씬에서 전수 디코드가 스캔 벽시계를 지배한다(실측 2522s 중 2519s). 예산 초과분은
    /// 디코드 없이 참조 존재만 집계(oggSkippedBudget — 실패가 아니라 시간 상한에 의한 걸러넘김).
    /// WAPLE_DEEP_OGG_BUDGET 환경변수로 오버라이드 가능(예산 경로 검증 등 디버그 게이트).
    /// AVAsset 로드 한 건의 상한. `SceneVideoLayer.assetLoadTimeoutSeconds`(5초)와 같은 값·같은 이유다 —
    /// 손상 미디어에서 로드가 반환하지 않는 경우가 있고, 여기는 워커 스레드라 그 하나가 잡을 세운다.
    static let assetLoadTimeoutSeconds: Double = 5

    static let oggDecodeTimeBudget: TimeInterval = {
        if let s = ProcessInfo.processInfo.environment["WAPLE_DEEP_OGG_BUDGET"],
           let v = Double(s), v >= 0 { return v }
        return 120
    }()

    /// - Returns: (마크다운 리포트, 프로젝트-레벨 미지원 건수 — F151 `--deep --strict` 게이트용. "미지원" 은
    ///   DeepReport 의 프로젝트-레벨 표(ALL 행)와 동일 기준: 핵심 에셋 파싱 실패, 위 리포트 각주 참고,
    ///   프로젝트 발견 여부 — false 면 루트/--only 오지정으로 스캔이 무의미, 호출측은 비정상 종료할 것.)
    public static func run(rootPath: String, only: String?) -> (report: String, unsupported: Int, projectsFound: Bool) {
        let root = URL(fileURLWithPath: NSString(string: rootPath).expandingTildeInPath, isDirectory: true).standardizedFileURL
        let assetsDir = firstExisting([root.appendingPathComponent("assets"),
                                       root.deletingLastPathComponent().appendingPathComponent("assets")])
        let container = projectContainer(root)
        var folders = projectFolders(container)
        // F137: id 멤버십뿐 아니라 각 프로젝트의 실제 type 도 미리 색인 — preset 의존 검증이 "존재하는가"
        // 뿐 아니라 "마운트 가능한 타입인가"(scene/video/web)까지 확인하게 한다(런타임 PresetResolver/
        // RendererFactory 는 application/unknown/preset 의존을 지원 안 함).
        //
        // **[3차 웨이브 AB] 색인 키가 폴더명 하나뿐이라 F411 과 같은 거짓 미해소를 냈다.**
        // 런타임 `PresetResolver` 와 형제 스캐너(`WallpaperCompatibilityAnalyzer.knownProjectIDs`)는
        // **id ∪ 폴더명** 합집합으로 찾는다 — F194 이후 project id 는 `workshopid ?? 폴더명` 이라
        // 워크샵에서 받은 폴더는 둘이 다르고, `dependency` 는 workshopid 를 가리킨다. 여기만 폴더명
        // 으로 찾아서 그런 preset 을 전건 "미해소" 로 셌다. 타입도 `raw["type"]` 원문 대신 파서 결과를
        // 쓴다 — `type` 생략 시 확장자 추론(G-E3-03)이 실제 마운트 타입을 정하고, 아래 집계
        // (`projTypeTotal`)도 이미 그 값을 쓰기 때문이다(같은 프로젝트가 두 이름으로 세지던 자리).
        // 설치본 도달 0건(type:"preset" 이 0건) — 워크샵 코퍼스에서만 움직인다.
        var knownTypes: [String: WallpaperType] = [:]
        for f in folders {
            if let raw = rawJSON(f.appendingPathComponent("project.json")) {
                let parsed = ProjectJSONParser.parse(json: raw, folderURL: f)
                knownTypes[f.lastPathComponent] = parsed.type
                knownTypes[parsed.id] = parsed.type
            }
        }
        if let only { folders = folders.filter { $0.lastPathComponent == only } }

        // 감사 V06: 프로젝트 0개(루트 오타·--only id 오지정)면 "0건 리포트 + exit 0" 으로 CI 가 성공 오인
        // — 형제 모드 F520 가드(SnapshotPipeline/ProfilePipeline/SnapshotCompare)와 동일하게 경고 후 비정상 종료 신호.
        guard !folders.isEmpty else {
            fputs("[deep] ⚠️ 프로젝트 0개 — root(개발 루트/backgrounds/단일 씬 폴더)와 --only id 확인: \(rootPath)\n", stderr)
            return ("", 0, false)
        }

        let agg = DeepAgg()
        let started = Date()

        // 병렬 워커에 넘기는 읽기 전용 입력을 상자 하나로 묶는다. `folders`/`knownTypes` 는 위에서
        // `var` 로 조립되지만 여기서부터는 **아무도 고치지 않는다** — 상자에 담으면서 `let` 으로
        // 굳어져 "동시 실행 코드에서 캡처된 var" 진단도 함께 사라진다.
        let inputs = DeepScanInputs(folders: folders, knownTypes: knownTypes, assetsDir: assetsDir)
        DispatchQueue.concurrentPerform(iterations: inputs.folders.count) { i in
            autoreleasepool {
                scanProject(inputs.folders[i], assetsDir: inputs.assetsDir,
                            knownTypes: inputs.knownTypes, agg: agg)
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
        let report = Report.render(agg: agg, root: root, assetsDir: assetsDir,
                                   projectCount: folders.count, translateElapsed: translateElapsed, elapsed: elapsed)
        let totalAll = agg.projTypeTotal.values.reduce(0, +)
        let supAll = agg.projTypeSupported.values.reduce(0, +)
        return (report, totalAll - supAll, true)
    }

    // MARK: project dispatch

    static func scanProject(_ folder: URL, assetsDir: URL?, knownTypes: [String: WallpaperType], agg: DeepAgg) {
        guard let raw = rawJSON(folder.appendingPathComponent("project.json")) else {
            agg.sync { agg.projectJSONTotal += 1; agg.projTypeTotal["invalid", default: 0] += 1 }
            return
        }
        // **[3차 웨이브 AB]** `raw` 는 이미 이 폴더의 project.json 을 파싱한 결과다 — 다시 직렬화해
        // 다시 파싱하지 않는다(형제 스캐너의 F231 과 같은 정리). 부수 이득: `JSONSerialization.data`
        // 가 던질 수 있는 유일한 경로(NaN/Inf 같은 비직렬화 값)가 사라져 "invalid" 오분류가 없어진다.
        let project = ProjectJSONParser.parse(json: raw, folderURL: folder)
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
            // F137: 의존 대상이 코퍼스에 존재할 뿐 아니라 실제로 마운트 가능한 타입(scene/video/web)일 때만
            // "resolved" — application/unknown/또다른 preset 은 존재해도 런타임에서 "지원하지 않는 타입"으로
            // 실패한다(AppLogic.PresetResolver target.type != .preset 요구 + RendererFactory default:nil).
            let ok: Bool
            if let dep = project.dependency, let depType = knownTypes[dep] {
                switch depType {
                case .scene, .video, .web: ok = true
                default: ok = false
                }
            } else {
                ok = false
            }
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
        let known = WallpaperCompatibilityAnalyzer.currentPropertyTypes   // 단일 소스(analyzer 와 일치)
        for p in parsed {
            let t = p.type.lowercased()
            if !t.isEmpty { typeCounts[t, default: 0] += 1; if !known.contains(t) { unsupported[t, default: 0] += 1 } }
            if let c = p.condition, !c.isEmpty {
                condTotal += 1
                if PropertyConditionEvaluator.canEvaluate(c), PropertyConditionEvaluator.evaluate(c, values: values) != nil { condOK += 1 }
            }
        }
        agg.sync {
            agg.propsProjects += 1
            agg.conditionsTotal += condTotal; agg.conditionsEvaluable += condOK
            for (k, v) in typeCounts { agg.propertyTypeCounts[k, default: 0] += v }
            for (k, v) in unsupported { agg.unsupportedPropertyTypes[k, default: 0] += v }
        }
    }

    // MARK: scene

    static func scanScene(_ folder: URL, project: WallpaperProject, assetsDir: URL?, agg: DeepAgg) -> Bool {
        agg.sync { agg.sceneAttempt += 1 }
        // **[3차 웨이브 AB] 종전 이 자리는 `scene.pkg`/`gifscene.pkg` 가 없으면 곧장 `false` 였다 —
        // 즉 언팩 씬을 한 건도 스캔하지 않고 전건 "미지원" 으로 셌다.** WE 2.8.42 설치본 실측:
        // 씬 프로젝트 **188/188 이 언팩**이고 두 루트 전체에 `.pkg` 가 **0개**다(형제 스캐너의
        // `WallpaperCompatibilityCorpusAuditTests` 가 그 분포를 고정한다). 그래서 `--deep` 을
        // 설치본에 겨누면 `projTypeSupported["scene"] = 0` → `--strict` 가 188건을 미지원으로 세는데,
        // **렌더러는 그 188건을 정상 마운트한다**(SceneRenderer.swift:1485 `ScenePackage.fromDirectory`).
        // 형제 스캐너는 G-E3-01 에서 이미 고쳤고 여기만 남아 있었다.
        //
        // 마운트 **선택자**도 렌더러와 같은 함수를 쓴다(`ScenePackage.resolveMountSource` —
        // `project.json` 의 `file` 이 단독 결정자, `.pkg` 는 그 파일이 디스크에 없을 때의 폴백).
        let package: ScenePackage
        switch ScenePackage.resolveMountSource(folderURL: folder,
                                               fileName: project.fileName,
                                               hasDependency: project.dependency != nil) {
        case .package(let pkgURL):
            // memory-map: a 700MB pkg stays paged instead of resident, so N concurrent scenes don't OOM.
            guard let pkgData = try? Data(contentsOf: pkgURL, options: .mappedIfSafe),
                  let parsed = try? ScenePackage.parse(pkgData) else { return false }
            package = parsed
        case .directory:
            // 폴더 백엔드는 지연 파일 읽기라 큰 프로젝트도 통째로 메모리에 올리지 않는다.
            guard let folderPackage = ScenePackage.fromDirectory(folder) else { return false }
            package = folderPackage
        }
        let res = PkgAssets(package: package, assetsDir: assetsDir)

        // 1) scene parse (real code path, with base-assets resolution)
        // **[3차 웨이브 AB]** 씬 문서 이름은 `project.json` 의 `file` 이 정한다 — 렌더러가 넘기는
        // `sceneFileName:`(SceneRenderer.swift:1500)을 여기서도 넘긴다. 안 넘기면 `scene.json`/
        // `gifscene.json` 관례로만 폴백해, 설치본의 `ricepod.json` `fantasticcar.json`
        // `techno.json` `audiophile.json` 4건이 위 언팩 수정 직후 `.noScene` 으로 떨어진다
        // (형제 스캐너가 G-E3-02 에서 같은 이유로 같이 고친 자리다).
        let doc: SceneDocument
        do {
            doc = try SceneDocument.parse(package: package,
                                          assets: { res.baseAssetURL($0).flatMap { try? Data(contentsOf: $0) } },
                                          sceneFileName: project.fileName)
        } catch { return false }
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
            if !decodeTex(name: entry.name, res: res, provenance: "\(project.id)/\(entry.name)", agg: agg, asset: false) {
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
    static func decodeTex(name: String, res: PkgAssets, provenance: String, agg: DeepAgg, asset: Bool) -> Bool {
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
        var collected: [URL] = []
        for case let u as URL in en where u.pathExtension.lowercased() == "tex" { collected.append(u) }
        // 열거가 끝난 뒤로는 목록이 바뀌지 않는다 — `let` 으로 굳혀 병렬 클로저가 `var` 를 캡처하지
        // 않게 한다(URL 은 Sendable 이라 이 한 줄로 충분하다).
        let texFiles = collected
        DispatchQueue.concurrentPerform(iterations: texFiles.count) { i in
            _ = decodeTex(name: texFiles[i].path, res: PkgAssets(package: ScenePackage.assemble([]), assetsDir: nil),
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
            let effectRoot = PkgAssets.effectLocalRoot(eff)
            // **G-B2-06 정정(2026-08-20).** 종전 주석은 "씬 패스 배열은 셰이더 패스만 담는다" 였고
            // 그에 맞춰 셰이더 패스만 세는 커서를 뒀다. 원본 파서를 뜯어 보니 반대다 — 씬 오버라이드는
            // 매니페스트 `passes[]` 의 **원본 배열 인덱스**로 정렬되고 명령 패스도 슬롯을 하나 쓴다
            // (`0x1401e7a6e` 의 `mov edx, ebx`, 루프 증가는 `0x1401e814e` 하나뿐).
            // 렌더러는 `SceneRenderer.sceneOverride(forRawPassIndex:in:)` 로 고쳤다. 스캐너가 안 따라오면
            // **렌더러가 실제로 컴파일하는 것과 다른 셰이더를 검사하는 오라클**이 된다.
            for (i, mp) in manifest.passes.enumerated() {
                if mp.command == "copy" || mp.command == "swap" { continue }   // shader-less command pass
                let meta = resolveShaderMeta(mp, eff: eff, res: res, root: effectRoot)
                guard let vData = res.scopedData("shaders/\(meta.base).vert", root: effectRoot),
                      let fData = res.scopedData("shaders/\(meta.base).frag", root: effectRoot),
                      let vert = String(data: vData, encoding: .utf8),
                      let frag = String(data: fData, encoding: .utf8) else {
                    agg.sync { agg.effectShaderMissing += 1 }
                    continue
                }
                let scenePass = i < eff.passList.count ? eff.passList[i] : SceneEffectPass()
                let combos = resolveCombos(frag: frag, scenePass: scenePass, matCombos: meta.matCombos, matTextures: meta.matTextures)
                let provenance = "\(projectID)/\(eff.name)#\(i) [\(meta.base)]"
                agg.sync { agg.translateAttempt += 1 }
                if let t = GLSLTranslator.translate(vertex: vert, fragment: frag, combos: combos,
                                                    include: { res.scopedInclude($0, root: effectRoot) }) {
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

    static func resolveShaderMeta(_ mp: EffectManifest.Pass, eff: SceneEffect, res: PkgAssets,
                                  root: String? = nil)
        -> (base: String, matCombos: [String: Int], matTextures: [String?]) {
        var shaderName = mp.shader
        var matCombos: [String: Int] = [:]
        var matTextures: [String?] = []
        if shaderName == nil, let matPath = mp.material,
           let mData = res.scopedData(matPath, root: root),
           let mjson = AssetJSON.dictionary(mData),
           let mp0 = (mjson["passes"] as? [Any])?.first as? [String: Any] {
            shaderName = mp0["shader"] as? String
            for (k, v) in (mp0["combos"] as? [String: Any]) ?? [:] {
                if let n = v as? Int { matCombos[k] = n } else if let d = v as? Double, let g = safeInt(d) { matCombos[k] = g }
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
        guard let device = MTLCreateSystemDefaultDevice() else {
            // F140: 조용한 스킵 대신 명시 표식 — DeepReport 가 "n/a" 대신 이유를 밝힌다.
            agg.sync { agg.metalDeviceUnavailable = true }
            return
        }
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
                  let json = AssetJSON.dictionary(data) else {
                agg.sync { agg.particleFileAttempt += 1; if agg.particleFailSamples.count < 8 { agg.particleFailSamples.append(provenance) } }
                return false
            }
            var material: ParticleMaterial? = nil
            if let matPath = json["material"] as? String, let mData = package.data(for: matPath),
               let mjson = AssetJSON.dictionary(mData) {
                material = ParticleMaterial.parse(mjson)
            }
            let def = ParticleSystemDef.parse(json, material: material) { childPath in
                (package.data(for: childPath)).flatMap { AssetJSON.dictionary($0) }
                    .map { ParticleSystemDef.parse($0, material: nil) }
            }
            // ParticleSystemDef.parse always returns a def; treat "has an emitter or initializer" as a real parse.
            let parseOK = !def.emitters.isEmpty || !def.initializers.isEmpty || !def.operators.isEmpty
            // F142: 예전엔 sim.liveCount>=0 (Array.count 라 항상 참인 죽은 검사)로 "빌드됨"을 셌다. 실제로
            // 한 스텝 시뮬레이션해 방출된 파티클(있다면)의 상태가 전부 유한한지 확인 — 렌더러가 매 프레임
            // 호출하는 것과 동일 경로(step)를 태워 트랩/NaN 을 잡는다. 방출 타이밍상 t=1/30 에 아직 미방출인
            // 시스템(지연 스폰 등)은 vacuous true(정상 — 실패로 오분류하지 않음).
            var sim = ParticleSimulator(def: def, seed: 0x9E3779B97F4A7C15)
            let stepped = sim.step(1.0 / 30.0)
            let simOK = stepped.allSatisfy { p in
                p.pos.x.isFinite && p.pos.y.isFinite && p.pos.z.isFinite
                    && p.size.isFinite && p.alpha.isFinite
                    && p.color.x.isFinite && p.color.y.isFinite && p.color.z.isFinite
            }
            agg.sync {
                agg.particleFileAttempt += 1
                if parseOK { agg.particleParseOK += 1 }
                if simOK { agg.particleSimOK += 1 } else if agg.particleFailSamples.count < 8 {
                    agg.particleFailSamples.append("simNaN:\(provenance)")
                }
                // F141: emitters/initializers/operators 가 모두 비어 JSON 자체는 유효하나 "내용 없는" 정의는
                // 별도 라벨(empty:)로 표시 — 실제 파싱 실패(위 guard, 라벨 없음)와 구분해 오분류를 막는다.
                if !parseOK && agg.particleFailSamples.count < 8 { agg.particleFailSamples.append("empty:\(provenance)") }
            }
            return parseOK
        }
    }

    // MARK: sounds

    static func scanSceneSounds(doc: SceneDocument, package: ScenePackage, agg: DeepAgg) {
        for sound in doc.sounds {
            for path in sound.sounds {
                let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                let data = package.data(for: path)
                let present = data != nil
                agg.sync {
                    agg.soundRefs += 1; if present { agg.soundPresent += 1 }
                    if !ext.isEmpty { agg.soundByExt[ext, default: 0] += 1 }
                }
                // ogg(Vorbis) 전수 디코드 검증 — 순수 Swift 디코더로 실제 PCM 화까지 확인.
                if ext == "ogg", let data {
                    verifyOgg(data, path: path, agg: agg)
                }
            }
        }
    }

    /// ogg 1개를 실제 디코드해 정합성 집계: 에러 0 / 채널·레이트 기록 / RMS 비무음 / NaN·Inf 없음.
    static func verifyOgg(_ data: Data, path: String, agg: DeepAgg) {
        // F681: 누적 디코드 시간이 예산을 넘으면 이 파일은 디코드하지 않는다(스캔 시간 상한 — 실패 아님).
        if agg.sync({ agg.oggDecodeSeconds >= oggDecodeTimeBudget }) {
            agg.sync { agg.oggRefs += 1; agg.oggSkippedBudget += 1 }
            return
        }
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            let dt = CFAbsoluteTimeGetCurrent() - started
            agg.sync { agg.oggDecodeSeconds += dt }
        }
        guard let audio = try? OggVorbisDecoder.decode(data), audio.frameCount > 0 else {
            agg.sync { agg.oggRefs += 1; agg.oggDecodeFail += 1; agg.addSample2(&agg.oggFailSamples, "decode:\(path)") }
            return
        }
        var sumSq = 0.0
        var bad = false
        for s in audio.samples { if s.isNaN || s.isInfinite { bad = true; break }; sumSq += Double(s) * Double(s) }
        let rms = bad ? 0 : (audio.samples.isEmpty ? 0 : (sumSq / Double(audio.samples.count)).squareRoot())
        agg.sync {
            agg.oggRefs += 1; agg.oggDecodeOK += 1
            agg.oggChannels[audio.channels, default: 0] += 1
            agg.oggRates[audio.sampleRate, default: 0] += 1
            if bad { agg.oggNaN += 1; agg.addSample2(&agg.oggFailSamples, "NaN:\(path)") }
            else if rms < 1e-6 { agg.oggSilent += 1; agg.addSample2(&agg.oggFailSamples, "silent:\(path)") }
        }
    }

    // MARK: video

    static func scanVideo(_ folder: URL, project: WallpaperProject, agg: DeepAgg) -> Bool {
        guard let file = project.fileName else {
            agg.sync { agg.videoTotal += 1; agg.videoUnknownContainer += 1 }
            return false
        }
        let ext = URL(fileURLWithPath: file).pathExtension.lowercased()
        // F840-sweep: 형제 `scanWeb`(:741,744)은 `WallpaperPathSecurity.containedFileURL` 로 realpath
        // 재검증을 하는데 여기만 `appendingPathComponent` 로 그대로 열었다. `..`·절대경로는 파스 단계
        // (`ProjectJSONParser.swift:42`)에서 이미 막히므로 남는 것은 **패키지 안 심링크**뿐이고,
        // `WapleCompat` 은 반출 경로 없는 CLI 라 귀결은 좁다 — 그래도 형제와 규약을 맞춘다.
        // 검증 실패는 "알 수 없는 컨테이너" 로 집계한다(스캐너 판정과 같은 방향).
        guard let url = WallpaperPathSecurity.containedFileURL(file, root: folder) else {
            agg.sync { agg.videoTotal += 1; agg.videoUnknownContainer += 1
                       agg.addSample2(&agg.videoFailSamples, "\(project.id)/\(file) (경로 봉쇄)") }
            return false
        }
        if VideoRenderer.nativeVideoExtensions.contains(ext) {
            // header-only probe: isPlayable/트랙 목록은 컨테이너 헤더만 읽는다(파일 전체 X).
            // F525: deprecated 동기 API(isPlayable/tracks(withMediaType:)) → load(_:) 계열로 국소 교체
            // (loadTracks(withMediaType:) 는 macOS 15+ 라 deployment target 14 에서 load(.tracks)+필터).
            // scanVideo 는 concurrentPerform 워커의 동기 호출이므로 FFmpegConverter.isReusableConvertedOutput
            // 과 같은 세마포어 브리지로 기다린다. 행위 보존: 로드 실패/예외는 unplayable 취급.
            let asset = AVURLAsset(url: url)
            let sem = DispatchSemaphore(value: 0)
            let playable = SemaphoreResultBox(false)   // Swift 5.10 캡처 var 에러 대응(아래 정의)
            Task {
                let ok = (try? await asset.load(.isPlayable)) ?? false
                let hasVideo = ((try? await asset.load(.tracks)) ?? []).contains { $0.mediaType == .video }
                playable.value = ok && hasVideo
                sem.signal()
            }
            // F840-sweep: 무한 대기 금지. 형제 3곳(SceneVideoLayer:109,209 · FFmpegConverter:156)은
            // 전부 타임아웃을 쓰는데 여기만 남아 있었다. 이 호출은 concurrentPerform 워커 안이라
            // 하나가 걸리면 그 워커 슬롯이 영구히 죽고, CLI 스캔 잡 전체가 끝나지 않는다.
            // 손상 mp4 의 AVAsset 로드는 실제로 반환하지 않을 수 있다 — 그게 이 스캐너의 입력이다.
            if sem.wait(timeout: .now() + Self.assetLoadTimeoutSeconds) != .success {
                playable.value = false   // 시간 초과 = 재생 불가로 집계(스캐너 판정과 같은 방향)
            }
            agg.sync {
                agg.videoTotal += 1
                if playable.value { agg.videoNativePlayable += 1 } else { agg.videoNativeUnplayable += 1; agg.addSample2(&agg.videoFailSamples, "\(project.id)/\(file)") }
            }
            return playable.value
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

    /// **[3차 웨이브 AB] 관용 파스 배선.** 종전 이 함수와 머티리얼·파티클 리더 4곳이 맨
    /// `JSONSerialization` 이었다 — 즉 **스캐너가 렌더러보다 엄격했다**. WE 는 jsoncpp 의
    /// `allowComments`/`allowTrailingCommas` 를 둘 다 켜고(`0x140091fe2`·`0x1400920b3`) WE 자기
    /// 자산이 실제로 그 관용에 의존한다: 3,655개 자산 JSON 중 **63개가 JSONC** 이고, 그중
    /// `defaultprojects/fantasticcar/materials/car/glass.json` 은 **머티리얼**(줄 주석)이다.
    /// 엄격 파스가 실패하면 그 메시의 `textures`·`blending`·`constantshadervalues` 가 통째로
    /// 유실되므로, 스캐너는 렌더러가 정상 처리하는 자산을 "실패" 로 셌다.
    ///
    /// `check_lenient_json_reach.py` 의 `WIRED` 표에 **이 파일이 없다** — 그 게이트는 코어·렌더의
    /// 6파일만 세므로 스캐너의 이 공백을 잡지 못했다(그 스크립트는 이 과제 소유가 아니다.
    /// 항목 추가안은 보고서로 넘긴다).
    static func rawJSON(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return AssetJSON.dictionary(d)
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
