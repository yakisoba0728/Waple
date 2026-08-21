import XCTest
@testable import WapleCore

final class WallpaperCompatibilityAnalyzerTests: XCTestCase {
    func testScansWallpaperDevLayoutAndReportsCompatibilityRisks() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let backgrounds = root.appendingPathComponent("backgrounds", isDirectory: true)
        try FileManager.default.createDirectory(at: backgrounds, withIntermediateDirectories: true)

        try writeProject(
            id: "100",
            in: backgrounds,
            json: """
            {
              "type": "web",
              "file": "index.html",
              "preview": "preview.jpg",
              "general": {
                "localization": {"ui_pick": "Pick file"},
                "properties": {
                  "amount": {"type": "slider", "value": 0.5, "order": 0.5, "condition": "enabled.value == true"},
                  "pick": {"type": "file", "value": "default.png", "order": 1},
                  "gallery": {"type": "directory", "mode": "fetchall", "order": 2}
                }
              }
            }
            """,
            files: [
                "index.html": "<script>navigator.serviceWorker.register('sw.js'); wallpaperRequestRandomFileForProperty('gallery', console.log);</script>",
                "preview.jpg": ""
            ]
        )

        try writeProject(
            id: "200",
            in: backgrounds,
            json: #"{"type":"application","file":"app.exe","title":"App"}"#,
            files: ["app.exe": ""]
        )

        try writeProject(
            id: "300",
            in: backgrounds,
            json: #"{"type":"preset","dependency":"100","preset":{"amount":1.0}}"#,
            files: [:]
        )

        try writeProject(
            id: "400",
            in: backgrounds,
            json: #"{"type":"video","file":"clip.webm","title":"Video"}"#,
            files: ["clip.webm": ""]
        )

        let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: root)

        XCTAssertEqual(report.summary.totalProjects, 4)
        XCTAssertEqual(report.summary.typeCounts["web"], 1)
        XCTAssertEqual(report.summary.typeCounts["application"], 1)
        XCTAssertEqual(report.summary.typeCounts["preset"], 1)
        XCTAssertEqual(report.summary.typeCounts["video"], 1)
        XCTAssertEqual(report.projects.map(\.id), ["100", "200", "300", "400"])

        XCTAssertTrue(report.containsIssue(.unsupportedApplicationType, projectID: "200"))
        XCTAssertFalse(report.containsIssue(.unsupportedPropertyType, projectID: "100", propertyKey: "pick"))
        XCTAssertFalse(report.containsIssue(.unsupportedPropertyType, projectID: "100", propertyKey: "gallery"))
        XCTAssertFalse(report.containsIssue(.propertyDisplayCondition, projectID: "100", propertyKey: "amount"))
        // F235: serviceWorker 는 이제 탐지 즉시 .warning 으로 승격된다(종전엔 features 에만 남고 issue
        // 미생성 — 이 픽스처의 index.html 이 실제로 navigator.serviceWorker.register(...) 를 포함하는데도
        // "보고 안 됨"을 단언하던 게 F393 이 지적한 회귀 감지력 0인 지점이었다).
        XCTAssertTrue(report.containsIssue(.webServiceWorker, projectID: "100"))
        XCTAssertTrue(report.containsIssue(.webRandomFileBridge, projectID: "100"))
        XCTAssertTrue(report.containsIssue(.nonNativeVideoContainer, projectID: "400"))
        // (F232/F235: fractionalPropertyOrder/localizedProperties/directoryFetchAll/presetOverridesNotApplied
        // 는 재조사 결과 실재 갭이 아님이 확인돼 이슈코드 자체를 제거했다 — 이 픽스처가 그 트리거 조건을
        // 그대로 갖고 있었는데도(order:0.5·localization 블록·gallery mode:fetchall·preset 오버라이드)
        // 이슈가 안 나는 게 회귀가 아니라 설계였다는 근거가 바로 이 4개 필드다.)

        let markdown = report.markdown()
        XCTAssertTrue(markdown.contains("Wallpaper Compatibility Report"))
        XCTAssertTrue(markdown.contains("unsupportedApplicationType"))
    }

    func testReportsMissingRequiredFilesAndDependencies() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeProject(
            id: "missing-web",
            in: root,
            json: #"{"type":"web","file":"missing.html","preview":"missing.jpg"}"#,
            files: [:]
        )
        try writeProject(
            id: "orphan-preset",
            in: root,
            json: #"{"type":"preset","dependency":"does-not-exist"}"#,
            files: [:]
        )

        let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: root)

        XCTAssertTrue(report.containsIssue(.missingWallpaperFile, projectID: "missing-web"))
        XCTAssertTrue(report.containsIssue(.missingPreviewFile, projectID: "missing-web"))
        XCTAssertTrue(report.containsIssue(.missingPresetDependency, projectID: "orphan-preset"))
        XCTAssertEqual(report.summary.blockedProjects, 2)
    }

    /// F411: 대상 프로젝트의 폴터명 ≠ workshopid 일 때(F194: id = workshopid 우선) dependency 가
    /// workshopid 를 가리키는 preset 은 런타임 PresetResolver 가 정상 해소하는데, 종전 analyzer 는
    /// 폴터명 집합과만 비교해 거짓 missingPresetDependency 를 냈다. id ∪ 폴터명 합집합 매칭 회귀 가드.
    func testPresetDependencyMatchesParsedIdWhenFolderNameDiffers() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeProject(
            id: "wrapper-folder",
            in: root,
            json: #"{"type":"web","file":"index.html","workshopid":12345}"#,
            files: ["index.html": ""]
        )
        try writeProject(
            id: "preset-by-workshopid",
            in: root,
            json: #"{"type":"preset","dependency":"12345"}"#,
            files: [:]
        )
        try writeProject(
            id: "preset-by-folder",
            in: root,
            json: #"{"type":"preset","dependency":"wrapper-folder"}"#,
            files: [:]
        )

        let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: root)

        XCTAssertFalse(report.containsIssue(.missingPresetDependency, projectID: "preset-by-workshopid"))
        XCTAssertFalse(report.containsIssue(.missingPresetDependency, projectID: "preset-by-folder"))
    }

    func testReportsUnsafeMainFilePathSeparatelyFromMissingFile() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeProject(
            id: "unsafe-web",
            in: root,
            json: #"{"type":"web","file":"../outside.html"}"#,
            files: [:]
        )

        let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: root)

        XCTAssertTrue(report.containsIssue(.unsafeWallpaperFilePath, projectID: "unsafe-web"))
        XCTAssertFalse(report.containsIssue(.missingWallpaperFile, projectID: "unsafe-web"))
    }

    func testSceneReportsUnsafeRawFilePathEvenWhenScenePackageExists() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("unsafe-scene", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type":"scene","file":"../outside.json"}"#.utf8)
            .write(to: folder.appendingPathComponent("project.json"))
        try ScenePackageTests.makePkg([("scene.json", Data(#"{"objects":[]}"#.utf8))])
            .write(to: folder.appendingPathComponent("scene.pkg"))

        let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: root)

        XCTAssertTrue(report.containsIssue(.unsafeWallpaperFilePath, projectID: "unsafe-scene"))
    }

    func testMalformedScenePackageBlocksProject() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("bad-scene", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type":"scene","file":"scene.pkg"}"#.utf8)
            .write(to: folder.appendingPathComponent("project.json"))
        try Data("not-a-pkg".utf8).write(to: folder.appendingPathComponent("scene.pkg"))

        let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: root)

        XCTAssertTrue(report.containsIssue(.missingScenePackage, projectID: "bad-scene"))
        XCTAssertEqual(report.summary.blockedProjects, 1)
    }

    func testWebFeatureScanFollowsLocalScripts() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeProject(
            id: "linked-web",
            in: root,
            json: #"{"type":"web","file":"index.html"}"#,
            files: [
                "index.html": #"<script src="js/runtime.js"></script>"#,
                "js/runtime.js": """
                navigator.serviceWorker.register('sw.js');
                window.wallpaperPropertyListener = {};
                window.wallpaperWillGoBackground = function() {};
                wallpaperRegisterAudioListener(function(){});
                wallpaperRequestRandomFileForProperty('gallery', function(){});
                wallpaperRegisterMediaStatusListener(function(){});
                document.createElement('canvas').getContext('webgl');
                var local = 'file:///tmp/picked.png';
                fetch('https://example.invalid/data.json');
                """
            ]
        )

        let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: root)
        let features = try XCTUnwrap(report.projects.first { $0.id == "linked-web" }?.detectedFeatures)

        XCTAssertTrue(features.contains("propertyListener"), features.description)
        XCTAssertTrue(features.contains("webLifecycle"), features.description)
        XCTAssertTrue(features.contains("serviceWorker"), features.description)
        XCTAssertTrue(features.contains("audioListener"), features.description)
        XCTAssertTrue(features.contains("randomFile"), features.description)
        XCTAssertTrue(features.contains("mediaIntegration"), features.description)
        XCTAssertTrue(features.contains("webGL"), features.description)
        XCTAssertTrue(features.contains("fileURL"), features.description)
        XCTAssertTrue(features.contains("remoteNetwork"), features.description)
        XCTAssertTrue(report.containsIssue(.webRandomFileBridge, projectID: "linked-web"))
        // F393: 대응하는 detectedFeatures 만 양성 테스트되고 issue 승격 여부는 무단정이던 비대칭을
        // 메움(F235 가 이 4종을 detect 시 .warning 으로 배선) — features.contains 와 쌍을 이루는
        // containsIssue 어서션.
        XCTAssertTrue(report.containsIssue(.webServiceWorker, projectID: "linked-web"))
        XCTAssertTrue(report.containsIssue(.webAudioListener, projectID: "linked-web"))
        XCTAssertTrue(report.containsIssue(.webMediaIntegration, projectID: "linked-web"))
        XCTAssertTrue(report.containsIssue(.remoteNetworkReference, projectID: "linked-web"))
    }

    func testWebFeatureScanFollowsStaticImportsAfterOversizedAssets() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeProject(
            id: "module-web",
            in: root,
            json: #"{"type":"web","file":"index.html"}"#,
            files: [
                "index.html": #"""
                <script src="vendor/p5.js"></script>
                <script type="module" src="js/main.js"></script>
                """#,
                "vendor/p5.js": String(repeating: "/* vendor */\n", count: 220_000),
                "js/main.js": #"import "./feature.js";"#,
                "js/feature.js": #"wallpaperRequestRandomFileForProperty("gallery", function() {});"#
            ]
        )

        let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: root)
        let features = try XCTUnwrap(report.projects.first { $0.id == "module-web" }?.detectedFeatures)

        XCTAssertTrue(features.contains("randomFile"), features.description)
        XCTAssertTrue(report.containsIssue(.webRandomFileBridge, projectID: "module-web"))
    }

    func testScenePackageFeaturesAreDetected() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("scene-rich", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type":"scene","file":"scene.json"}"#.utf8).write(to: folder.appendingPathComponent("project.json"))
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[
           {"image":"models/layer.json","effects":[{"file":"effects/shake/effect.json"}]},
           {"particle":"particles/rain.json"},
           {"text":{"script":"return 'clock';"}},
           {"sound":["sounds/a.mp3"]},
           {"model":"models/ship.mdl"},
           {"light":"lpoint"}
         ]}
        """
        let pkg = ScenePackageTests.makePkg([("scene.json", Data(scene.utf8))])
        try pkg.write(to: folder.appendingPathComponent("scene.pkg"))

        let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: root)
        let features = try XCTUnwrap(report.projects.first { $0.id == "scene-rich" }?.detectedFeatures)

        XCTAssertTrue(features.contains("scenePackage"), features.description)
        XCTAssertTrue(features.contains("sceneLayer"), features.description)
        XCTAssertTrue(features.contains("sceneEffect"), features.description)
        XCTAssertTrue(features.contains("sceneParticle"), features.description)
        XCTAssertTrue(features.contains("sceneText"), features.description)
        XCTAssertTrue(features.contains("sceneScript"), features.description)
        XCTAssertTrue(features.contains("sceneSound"), features.description)
        XCTAssertTrue(features.contains("scene3DModel"), features.description)
        XCTAssertTrue(features.contains("sceneLight"), features.description)
    }

    func testRealWallpaperDevCorpusCanBeSummarizedWhenAvailable() throws {
        // F392: 이 스위트의 다른 ~25개 실코퍼스 게이트는 전부 WAPLE_REAL_PKGS(기본 .../backgrounds)를
        // 읽는데 이 테스트만 별개 이름·별개 기본값(WAPLE_REAL_PKGS_ROOT, .../wallpaper_dev)을 썼다 —
        // 표준 코퍼스 재지정으로는 이 테스트만 못 따라옴. WallpaperCompatibilityAnalyzer.scan(rootURL:)
        // 은 backgrounds/ 상위·backgrounds/ 자체 둘 다 올바르게 처리하므로(projectContainerURL 자동판정)
        // 표준 변수·표준 기본값으로 갈아타도 동작은 동일하다.
        let path = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no wallpaper_dev corpus at \(path)")
        }

        let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: URL(fileURLWithPath: path, isDirectory: true))

        XCTAssertGreaterThan(report.summary.totalProjects, 0)
        XCTAssertGreaterThan(report.summary.typeCounts["web"] ?? 0, 0)
        XCTAssertGreaterThan(report.summary.typeCounts["scene"] ?? 0, 0)
        XCTAssertGreaterThan(report.summary.typeCounts["video"] ?? 0, 0)
    }

    /// **[3차 웨이브 AB]** `remoteNetworkReference` 는 "요청을 만드는 자리"의 URL 만 본다.
    ///
    /// 종전 규칙(`https?://` 맨 부분일치)은 설치본 191 프로젝트에서 **2건 전건 거짓 양성**이었다:
    /// GreenSock 라이선스 배너(`corsair_o_tron/js/TweenMax.min.js`)와 XML/SVG 네임스페이스 이름·
    /// Angular 문서 링크(`corsair_collection/main.*.js`). 아래 음성군이 **그 실물 문자열 그대로**다.
    func testRemoteRequestURLIgnoresNonRequestOccurrences() {
        // 음성 — 설치본에서 실제로 오탐을 만들던 형태
        let negatives = [
            "/*! VERSION: 2.1.3 * DATE: 2019-05-06 * UPDATES AND DOCS AT: http://greensock.com */",
            #"var e=t.createElementNS("http://www.w3.org/2000/svg","svg")"#,
            #"throw new Error("see https://angular.io/docs/ts/latest/api/common/index/NgFor-directive.html")"#,
            #"{"xmlns":"http://www.w3.org/1999/xhtml"}"#,
            "// 자세한 내용: https://example.com/readme",
        ]
        for n in negatives {
            XCTAssertNil(WallpaperCompatibilityAnalyzer.remoteRequestURL(in: n), n)
        }

        // 양성 — 브라우저가 실제로 로드를 시작하는 자리
        let positives: [(String, String)] = [
            (#"fetch('https://example.invalid/data.json');"#, "https://example.invalid/data.json"),
            (#"<script src="https://cdn.example.com/lib.js"></script>"#, "https://cdn.example.com/lib.js"),
            (#"<link rel="stylesheet" href="https://fonts.example.com/x.css">"#, "https://fonts.example.com/x.css"),
            (#"img.src = "http://example.com/a.png";"#, "http://example.com/a.png"),
            (#"new WebSocket("wss://x") ; new EventSource('https://example.com/sse')"#, "https://example.com/sse"),
            (#"x.open("GET", "https://api.example.com/v1")"#, "https://api.example.com/v1"),
            (#"import * as m from "https://esm.sh/pkg";"#, "https://esm.sh/pkg"),
            (#"@font-face { src: url(https://fonts.example.com/f.woff2); }"#, "https://fonts.example.com/f.woff2"),
            (#"@import "https://example.com/base.css";"#, "https://example.com/base.css"),
        ]
        for (source, expected) in positives {
            XCTAssertEqual(WallpaperCompatibilityAnalyzer.remoteRequestURL(in: source), expected, source)
        }
    }

    /// 위 규칙이 **프로젝트 단위 판정**까지 그대로 이어지는지 — 음성 프로젝트는 경고가 없어야 한다.
    func testLicenseBannerURLDoesNotRaiseRemoteNetworkWarning() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeProject(
            id: "banner-only",
            in: root,
            json: #"{"type":"web","file":"index.html"}"#,
            files: [
                "index.html": #"<script src="js/vendor.js"></script>"#,
                "js/vendor.js": """
                /*! TweenMax 2.1.3 — DOCS AT: http://greensock.com */
                var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
                """
            ]
        )

        let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: root)
        XCTAssertFalse(report.containsIssue(.remoteNetworkReference, projectID: "banner-only"))
        let features = try XCTUnwrap(report.projects.first { $0.id == "banner-only" }?.detectedFeatures)
        XCTAssertFalse(features.contains("remoteNetwork"), features.description)
    }

    /// **[3차 웨이브 AB]** `wallpaperPluginListener` — WE 웹 브리지 13종 중 Waple 이 정의하지 않는
    /// 유일한 이름(근거는 `WallpaperCompatibilityIssueCode.webPluginBridge` 선언부). 설치본 web 2/2
    /// 도달이라 코퍼스 감사 테스트가 개수를 고정하고, 여기서는 규칙 자체의 양성 대조를 둔다.
    func testPluginListenerRaisesWebPluginBridgeWarning() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeProject(
            id: "icue-web",
            in: root,
            json: #"{"type":"web","file":"index.html"}"#,
            files: [
                "index.html": #"<script src="js/main.js"></script>"#,
                "js/main.js": "window.wallpaperPluginListener = { onPluginLoaded: function(){} };"
            ]
        )

        let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: root)
        XCTAssertTrue(report.containsIssue(.webPluginBridge, projectID: "icue-web"))
        let features = try XCTUnwrap(report.projects.first { $0.id == "icue-web" }?.detectedFeatures)
        XCTAssertTrue(features.contains("pluginBridge"), features.description)
        // 렌더 자체는 되므로 치명이 아니다.
        XCTAssertFalse(try XCTUnwrap(report.projects.first { $0.id == "icue-web" }).isBlocked)
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WapleCompat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeProject(id: String, in root: URL, json: String, files: [String: String]) throws {
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
        for (relativePath, contents) in files {
            let url = folder.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
    }
}

private extension WallpaperCompatibilityReport {
    func containsIssue(_ code: WallpaperCompatibilityIssueCode, projectID: String, propertyKey: String? = nil) -> Bool {
        projects.contains { project in
            project.id == projectID && project.issues.contains { issue in
                issue.code == code && (propertyKey == nil || issue.propertyKey == propertyKey)
            }
        }
    }
}
