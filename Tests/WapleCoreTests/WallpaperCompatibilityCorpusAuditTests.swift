import XCTest
@testable import WapleCore

/// `WallpaperCompatibilityAnalyzer` 를 **실물 코퍼스에 통째로 돌려** 판정 분포를 못박는다.
///
/// 왜 있는가
/// ---------
/// 이 분석기의 계약은 "이슈 없음 = 렌더 가능" 이고, 그 판정이 UI 의 호환성 배지로 그대로 나간다.
/// 그런데 종전 스위트는 **합성 픽스처 6~8건**만 봤다 — 규칙 하나가 실물 191개 프로젝트 중 몇 건을
/// 건드리는지(= 판정을 바꾸는 변경의 폭발 반경)를 아무도 못 재는 상태였다. 그래서 다른 클러스터가
/// 이 파일을 "함께 움직인다" 며 계속 미뤘다.
///
/// 여기서 고정하는 것은 **분포**다. 규칙을 고치면 이 숫자가 움직이고, 움직인 만큼이 도달 건수다.
///
/// 코퍼스: WE 설치본(`WE_ROOT`, 기본 `/home/user/Waple-wallpaper-source/wallpaper_engine`)의
/// `assets/` + `projects/` 아래 `project.json` 을 가진 폴더 전부. **CI(ubuntu)에는 이 트리가
/// 없으므로 조용히 스킵된다** — `check_lenient_json_reach.py` 가 같은 이유로 같은 스킵을 한다.
///
/// 폴더마다 `scan(rootURL:)` 을 1건 모드로 부른다(컨테이너 자체에 `project.json` 이 있으면
/// `projectFolders` 가 `[container]` 를 돌려준다). 그래서 `knownProjectIDs` 는 자기 자신뿐인데,
/// 이 코퍼스에 `type:"preset"` 이 **0건**이라 preset 의존 판정에 왜곡이 없다(아래 typeCounts 로
/// 함께 고정한다 — preset 이 생기면 이 테스트가 먼저 깨져서 알려 준다).
final class WallpaperCompatibilityCorpusAuditTests: XCTestCase {

    private static func installRoot() -> URL? {
        let path = ProcessInfo.processInfo.environment["WE_ROOT"]
            ?? "/home/user/Waple-wallpaper-source/wallpaper_engine"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 트리 아래 `project.json` 을 가진 폴더 전부(정렬).
    private static func projectFolders(under root: URL) -> [URL] {
        var out: [URL] = []
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in en {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) {
                out.append(url.standardizedFileURL)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    private struct Census {
        var projects = 0
        var blocked = 0
        var types: [String: Int] = [:]
        var issues: [String: Int] = [:]
        var severities: [String: Int] = [:]
        var features: [String: Int] = [:]
        var propertyTypes: [String: Int] = [:]
        var blockedIDs: [String] = []
        var issueSamples: [String: [String]] = [:]
    }

    private static func census(_ folders: [URL]) throws -> Census {
        var c = Census()
        for folder in folders {
            let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: folder)
            XCTAssertEqual(report.projects.count, 1, "1건 모드가 깨졌다: \(folder.path)")
            guard let p = report.projects.first else { continue }
            c.projects += 1
            c.types[p.type, default: 0] += 1
            if p.isBlocked { c.blocked += 1; c.blockedIDs.append(p.id) }
            for (t, n) in p.propertyTypes { c.propertyTypes[t, default: 0] += n }
            for f in p.detectedFeatures { c.features[f, default: 0] += 1 }
            for issue in p.issues {
                c.issues[issue.code.rawValue, default: 0] += 1
                c.severities[issue.severity.rawValue, default: 0] += 1
                var s = c.issueSamples[issue.code.rawValue] ?? []
                if s.count < 6 { s.append("\(p.id)\(issue.relativePath.map { "/\($0)" } ?? "")\(issue.propertyKey.map { " [\($0)]" } ?? "")") }
                c.issueSamples[issue.code.rawValue] = s
            }
        }
        return c
    }

    private static func dump(_ label: String, _ c: Census) {
        print("== \(label): 프로젝트 \(c.projects)건 · blocked \(c.blocked)건 ==")
        print("   types: \(c.types.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        print("   severities: \(c.severities.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        print("   issues:")
        for (k, v) in c.issues.sorted(by: { $0.key < $1.key }) {
            print("      \(k)=\(v)  예: \((c.issueSamples[k] ?? []).joined(separator: ", "))")
        }
        print("   features: \(c.features.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        print("   propertyTypes: \(c.propertyTypes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        if !c.blockedIDs.isEmpty { print("   blockedIDs: \(c.blockedIDs.sorted().joined(separator: ", "))") }
    }

    /// 설치본 전수(191개) 판정 분포.
    func testInstallCorpusVerdictCensus() throws {
        guard let root = Self.installRoot() else { throw XCTSkip("WE 설치본 트리 없음(WE_ROOT)") }
        let folders = Self.projectFolders(under: root.appendingPathComponent("assets", isDirectory: true))
            + Self.projectFolders(under: root.appendingPathComponent("projects", isDirectory: true))
        guard !folders.isEmpty else { throw XCTSkip("설치본에 project.json 폴더가 없다") }

        let c = try Self.census(folders)
        Self.dump("설치본 assets/+projects/", c)

        XCTAssertEqual(c.projects, 191, "설치본 project.json 폴더 수 — 코퍼스가 바뀌면 아래 수치 전부 재측정")
        XCTAssertEqual(c.types["scene"], 188)
        XCTAssertEqual(c.types["web"], 2)
        XCTAssertEqual(c.types["application"], 1)
        XCTAssertNil(c.types["preset"], "preset 이 생기면 1건 모드의 preset 의존 판정이 왜곡된다")

        // **판정 분포 전체를 고정한다.** 19종 이슈코드 중 이 코퍼스에 도달하는 것은 3종뿐이다 —
        // 나머지 16종은 도달 0건이라 이 코퍼스로는 아무것도 검증되지 않는다는 사실 자체가 기록이다.
        //   · unsupportedApplicationType: `sheep`(sheep.exe) 1건 — 유일한 치명 이슈.
        //   · webAudioListener: `corsair_o_tron/js/main.js` 의 `wallpaperRegisterAudioListener` 1건.
        //   · webPluginBridge: 웹 2건 **전건**(`wallpaperPluginListener` — Waple 브리지 미구현).
        //     3차 웨이브 AB 에서 새로 배선한 규칙이고, 이 2건이 그 도달 건수다(종전 0건 = 거짓 음성).
        // remoteNetworkReference 는 3차 웨이브 AB 전까지 2건이었고 **2건 전부 거짓 양성**이었다
        // (라이선스 배너 · XML 네임스페이스 URI). 요청 자리 한정으로 좁혀 0건이 됐다.
        XCTAssertEqual(c.issues, ["unsupportedApplicationType": 1, "webAudioListener": 1,
                                  "webPluginBridge": 2],
                       "판정 분포가 움직였다 — 규칙을 고쳤다면 그 도달 건수가 바로 이 차이다")
        XCTAssertEqual(c.severities, ["error": 1, "warning": 3])
        XCTAssertEqual(c.blockedIDs, ["sheep"])
        // 씬 188건이 **전건 마운트돼 실제로 검사됐다**(언팩 폴더 마운트 · pkg 0개).
        XCTAssertEqual(c.features["scenePackage"], 188)
        // 등장하는 프로퍼티 타입은 넷뿐 — currentPropertyTypes 의 양방향 차이 7종은 전부 도달 0이다.
        XCTAssertEqual(Set(c.propertyTypes.keys), ["color", "slider", "combo", "bool"])
        XCTAssertNil(c.issues["unsupportedPropertyType"])
        XCTAssertNil(c.issues["propertyDisplayCondition"])
    }

    /// 동봉 트리(`Sources/WapleRender/Resources/WEAssets`) 판정 분포 — 설치본 `assets/` 와
    /// 바이트 동일이라 같은 수치가 나와야 한다. 갈리면 동봉본이 낡았다는 신호다.
    func testBundledTreeMatchesInstallAssets() throws {
        guard let root = Self.installRoot() else { throw XCTSkip("WE 설치본 트리 없음(WE_ROOT)") }
        guard let bundled = Self.bundledAssetsRoot() else { throw XCTSkip("동봉 WEAssets 트리 없음") }

        let installAssets = try Self.census(Self.projectFolders(under: root.appendingPathComponent("assets", isDirectory: true)))
        let bundledCensus = try Self.census(Self.projectFolders(under: bundled))
        Self.dump("동봉 WEAssets", bundledCensus)

        XCTAssertEqual(bundledCensus.projects, installAssets.projects)
        XCTAssertEqual(bundledCensus.issues, installAssets.issues)
        XCTAssertEqual(bundledCensus.types, installAssets.types)
    }

    private static func bundledAssetsRoot() -> URL? {
        if let p = ProcessInfo.processInfo.environment["WAPLE_WE_ASSETS"], !p.isEmpty {
            let u = URL(fileURLWithPath: p, isDirectory: true)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Sources/WapleRender/Resources/WEAssets", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// `propertyDisplayCondition` 규칙의 **도달**을 실측으로 못박는다.
    ///
    /// `PropertyConditionEvaluator` 타입 주석은 "설치본 조건 22건 / 고유 16종" 이라고 적고 있는데,
    /// 그 22건은 `project.json` 의 `general.properties[*].condition`(= `canEvaluate` 소비처가 보는 키)
    /// **17건**에 `scene.json` 의 `visible.user.condition` **5건**을 합친 수다. 뒤쪽은 Angular 식이
    /// 아니라 콤보 옵션값 **문자열 동등비교**이고(`SceneDocument.resolveUserBindings`), 평가기를
    /// 아예 타지 않는다. 이 테스트가 보는 것은 **평가기가 실제로 보는 키 하나**다.
    func testPropertyConditionReachOnInstallCorpus() throws {
        guard let root = Self.installRoot() else { throw XCTSkip("WE 설치본 트리 없음(WE_ROOT)") }
        let folders = Self.projectFolders(under: root.appendingPathComponent("assets", isDirectory: true))
            + Self.projectFolders(under: root.appendingPathComponent("projects", isDirectory: true))
        guard !folders.isEmpty else { throw XCTSkip("설치본에 project.json 폴더가 없다") }

        var total = 0, nonEmpty = 0, evaluable = 0
        var deepTotal = 0, deepEvaluable = 0
        var uniq: Set<String> = []
        var notEvaluable: [String] = []
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
                  let raw = AssetJSON.dictionary(data),
                  let general = raw["general"] as? [String: Any],
                  let props = general["properties"] as? [String: Any] else { continue }
            for key in props.keys.sorted() {
                guard let p = props[key] as? [String: Any],
                      let condition = p["condition"] as? String else { continue }
                total += 1
                if condition.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                nonEmpty += 1
                uniq.insert(condition)
                if PropertyConditionEvaluator.canEvaluate(condition) { evaluable += 1 }
                else { notEvaluable.append("\(folder.lastPathComponent)[\(key)] \(condition)") }
            }
            // **DeepScan:343 의 술어를 글자 그대로 복제한다.** 그쪽은 `WapleCompatCore`(Metal 의존)라
            // 리눅스에서 못 돌지만, 술어 자체는 `WapleCore` 함수 둘의 합성이므로 여기서 같은 수치를 낸다.
            //   `if canEvaluate(c), evaluate(c, values: values) != nil { condOK += 1 }`
            // values 조립도 DeepScan.scanProperties 와 같다(WallpaperProperties.parse → key→value).
            let parsed = WallpaperProperties.parse(generalProperties: props)
            var values: [String: PropertyValue] = [:]
            for p in parsed { values[p.key] = p.value }
            for p in parsed {
                guard let c = p.condition, !c.isEmpty else { continue }
                deepTotal += 1
                if PropertyConditionEvaluator.canEvaluate(c),
                   PropertyConditionEvaluator.evaluate(c, values: values) != nil { deepEvaluable += 1 }
            }
        }
        print("== condition 도달: 총 \(total)건(빈 문자열 포함) · 비어있지 않음 \(nonEmpty)건 · "
              + "고유 \(uniq.count)종 · canEvaluate 참 \(evaluable)건 "
              + "| DeepScan 술어: \(deepEvaluable)/\(deepTotal) ==")
        for c in uniq.sorted() { print("   \(c)") }
        for n in notEvaluable { print("   NOT-EVALUABLE \(n)") }

        XCTAssertEqual(total, 17, "설치본 project.json 의 condition 키 총수(빈 문자열 1건 포함)")
        XCTAssertEqual(nonEmpty, 16)
        XCTAssertEqual(uniq.count, 13, "고유 조건식")
        XCTAssertEqual(evaluable, 16, "전건 평가 가능 — 그래서 이 코퍼스에 propertyDisplayCondition 경고는 0건이다")
        XCTAssertTrue(PropertyConditionEvaluator.canEvaluate(""), "빈 조건은 경고 대상이 아니다")
        // 두 소비처가 **이미 포화**돼 있다: analyzer 는 16/16 이 canEvaluate=true 라 경고 0,
        // DeepScan 은 16/16 이 evaluable 이라 비율 100%. `canEvaluate` 를 **넓히는** 어떤 변경도
        // 이 코퍼스 위에서는 두 수치를 못 움직인다(위로 올릴 자리가 없다) — 25459c5 의 "움직이는
        // 수치가 없다" 주장을 문법 열거가 아니라 포화로 확인한 것이다.
        XCTAssertEqual(deepTotal, 16)
        XCTAssertEqual(deepEvaluable, 16, "DeepScan conditionsEvaluable 도 이미 100% — 넓혀도 안 움직인다")
    }

    /// 위 사슬(①②③)이 **합성 폴더**에서도 도는지 — 코퍼스 없이 CI 에서도 도는 양성 대조.
    /// `Tests/WapleCompatCoreTests` 는 `import Metal` 이라 리눅스에서 못 도는데, 그쪽이 실제로
    /// 부르는 것이 이 세 함수다. 여기가 깨지면 DeepScan 의 언팩 경로도 같이 깨진 것이다.
    func testUnpackedFolderMountChainUsedByDeepScan() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WapleDeepMount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"type":"scene","file":"ricepod.json"}"#.utf8)
            .write(to: root.appendingPathComponent("project.json"))
        try Data("""
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"image":"models/layer.json"},{"particle":"particles/rain.json"}]}
        """.utf8).write(to: root.appendingPathComponent("ricepod.json"))

        let project = ProjectJSONParser.parse(
            json: try XCTUnwrap(AssetJSON.dictionary(Data(contentsOf: root.appendingPathComponent("project.json")))),
            folderURL: root)
        XCTAssertEqual(ScenePackage.resolveMountSource(folderURL: root, fileName: project.fileName,
                                                       hasDependency: project.dependency != nil),
                       .directory)
        let package = try XCTUnwrap(ScenePackage.fromDirectory(root))
        XCTAssertNotNil(try? SceneDocument.parse(package: package, sceneFileName: project.fileName),
                        "파일명을 넘기면 열린다")
        XCTAssertNil(try? SceneDocument.parse(package: package),
                     "관례 이름만으로는 못 연다 — sceneFileName 전달이 실제로 필요하다는 음성 대조")
    }

    /// **`DeepScan.scanScene` 수정의 폭발 반경**을 `WapleCore` 만으로 실측한다.
    ///
    /// `WapleCompatCore` 는 `import Metal`/`WapleRender` 라 리눅스에서 **빌드도 테스트도 안 된다**
    /// (`scripts/dev/linux-render-typecheck.sh` 의 커버는 `Sources/WapleRender/**` 뿐이다). 그래서
    /// 그쪽 수정의 도달 건수는 여기서 **같은 함수 조합을 직접 태워** 잰다:
    ///   ① 마운트 결정 `ScenePackage.resolveMountSource`
    ///   ② 폴더 마운트 `ScenePackage.fromDirectory`
    ///   ③ 문서 파스 `SceneDocument.parse(package:assets:sceneFileName:)`
    /// 종전 DeepScan 은 ①② 없이 `scene.pkg`/`gifscene.pkg` 존재만 보고 없으면 곧장 미지원이었고,
    /// ③ 에 `sceneFileName:` 을 안 넘겼다. 아래 수치가 그 두 결함의 도달 건수다.
    func testDeepScanSceneMountReachOnInstallCorpus() throws {
        guard let root = Self.installRoot() else { throw XCTSkip("WE 설치본 트리 없음(WE_ROOT)") }
        let assetsDir = root.appendingPathComponent("assets", isDirectory: true)
        let folders = Self.projectFolders(under: assetsDir)
            + Self.projectFolders(under: root.appendingPathComponent("projects", isDirectory: true))
        guard !folders.isEmpty else { throw XCTSkip("설치본에 project.json 폴더가 없다") }

        var scenes = 0, packageMount = 0, directoryMount = 0
        var parsedWithFileName = 0, parsedConventionOnly = 0
        var needsFileName: [String] = []
        var parseFailures: [String] = []
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
                  let raw = AssetJSON.dictionary(data) else { continue }
            let project = ProjectJSONParser.parse(json: raw, folderURL: folder)
            guard project.type == .scene else { continue }
            scenes += 1

            let package: ScenePackage?
            switch ScenePackage.resolveMountSource(folderURL: folder, fileName: project.fileName,
                                                   hasDependency: project.dependency != nil) {
            case .package(let url):
                packageMount += 1
                package = (try? Data(contentsOf: url)).flatMap { try? ScenePackage.parse($0) }
            case .directory:
                directoryMount += 1
                package = ScenePackage.fromDirectory(folder)
            }
            guard let package else { parseFailures.append("\(folder.lastPathComponent): 마운트 실패"); continue }
            let assets: (String) -> Data? = { name in
                WallpaperPathSecurity.containedFileURL(name, root: assetsDir).flatMap { try? Data(contentsOf: $0) }
            }
            let withName = try? SceneDocument.parse(package: package, assets: assets,
                                                    sceneFileName: project.fileName)
            let conventionOnly = try? SceneDocument.parse(package: package, assets: assets)
            if withName != nil { parsedWithFileName += 1 } else { parseFailures.append(folder.lastPathComponent) }
            if conventionOnly != nil { parsedConventionOnly += 1 }
            if withName != nil, conventionOnly == nil { needsFileName.append(folder.lastPathComponent) }
        }

        print("== DeepScan 씬 경로 도달: 씬 \(scenes)건 · pkg 마운트 \(packageMount) · 폴더 마운트 \(directoryMount) "
              + "| SceneDocument 파스 \(parsedWithFileName)(파일명 전달) vs \(parsedConventionOnly)(관례만) ==")
        print("   파일명 전달이 있어야만 열리는 씬 \(needsFileName.count)건: \(needsFileName.sorted())")
        if !parseFailures.isEmpty { print("   파스 실패 \(parseFailures.count)건: \(parseFailures.prefix(8))") }

        XCTAssertEqual(scenes, 188)
        XCTAssertEqual(packageMount, 0, "설치본에 .pkg 는 0개 — 종전 DeepScan 은 여기서 전건 미지원을 냈다")
        XCTAssertEqual(directoryMount, 188, "폴더 마운트 추가의 도달 건수")
        XCTAssertEqual(parsedWithFileName, 188, "폴더 마운트 + 파일명 전달이면 188/188 이 SceneDocument 로 열린다")
        XCTAssertEqual(needsFileName.sorted(), ["audiophile", "fantasticcar", "ricepod", "techno"],
                       "sceneFileName 미전달의 도달 건수 — 관례 이름이 아닌 4건")
    }
}
