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
        XCTAssertFalse(report.containsIssue(.fractionalPropertyOrder, projectID: "100", propertyKey: "amount"))
        XCTAssertFalse(report.containsIssue(.propertyDisplayCondition, projectID: "100", propertyKey: "amount"))
        XCTAssertFalse(report.containsIssue(.localizedProperties, projectID: "100"))
        XCTAssertFalse(report.containsIssue(.directoryFetchAll, projectID: "100", propertyKey: "gallery"))
        XCTAssertFalse(report.containsIssue(.webServiceWorker, projectID: "100"))
        XCTAssertTrue(report.containsIssue(.webRandomFileBridge, projectID: "100"))
        XCTAssertFalse(report.containsIssue(.presetOverridesNotApplied, projectID: "300"))
        XCTAssertTrue(report.containsIssue(.nonNativeVideoContainer, projectID: "400"))

        let markdown = report.markdown()
        XCTAssertTrue(markdown.contains("Wallpaper Compatibility Report"))
        XCTAssertTrue(markdown.contains("unsupportedApplicationType"))
        XCTAssertFalse(markdown.contains("presetOverridesNotApplied"))
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
        let path = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS_ROOT"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no wallpaper_dev corpus at \(path)")
        }

        let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: URL(fileURLWithPath: path, isDirectory: true))

        XCTAssertGreaterThan(report.summary.totalProjects, 0)
        XCTAssertGreaterThan(report.summary.typeCounts["web"] ?? 0, 0)
        XCTAssertGreaterThan(report.summary.typeCounts["scene"] ?? 0, 0)
        XCTAssertGreaterThan(report.summary.typeCounts["video"] ?? 0, 0)
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
