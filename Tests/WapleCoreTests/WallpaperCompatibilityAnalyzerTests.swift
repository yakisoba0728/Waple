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
