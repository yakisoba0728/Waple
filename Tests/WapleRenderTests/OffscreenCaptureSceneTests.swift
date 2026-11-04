import XCTest
import Metal
import AppKit
import WapleCore
@testable import WapleRender

final class OffscreenCaptureSceneTests: XCTestCase {
    @MainActor func testCanonicalCaptureMatchesAcrossCallerSettingsAndRestoresThem() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canonical-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"type":"scene","file":"scene.json"}"#.utf8).write(to: root.appendingPathComponent("project.json"))
        try Data(#"{"general":{"orthogonalprojection":{"width":320,"height":240},"clearcolor":"0.4 0.2 0.6"},"objects":[]}"#.utf8)
            .write(to: root.appendingPathComponent("scene.json"))
        let project = try ProjectJSONParser.parse(folderURL: root)
        let oldDefaults = SceneRenderSettings.defaults
        let suite = "waple.capture.conditions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        SceneRenderSettings.defaults = defaults
        defer {
            SceneRenderSettings.defaults = oldDefaults
            defaults.removePersistentDomain(forName: suite)
        }
        let oldFit = SceneRenderSettings.fitMode
        let oldEpoch = TextScriptEngine.captureDateEpochMillis
        let oldSeed = TextScriptEngine.captureRandomSeed
        defer {
            SceneRenderSettings.fitMode = oldFit
            TextScriptEngine.captureDateEpochMillis = oldEpoch
            TextScriptEngine.captureRandomSeed = oldSeed
        }
        SceneRenderSettings.fitMode = .fit
        TextScriptEngine.captureDateEpochMillis = nil
        TextScriptEngine.captureRandomSeed = nil
        let first = try XCTUnwrap(OffscreenCapture.scene(project: project, toDir: root).first)
        let before = try Data(contentsOf: first)
        XCTAssertEqual(SceneRenderSettings.fitMode, .fit)
        XCTAssertNil(TextScriptEngine.captureDateEpochMillis)
        XCTAssertNil(TextScriptEngine.captureRandomSeed)
        let image = try XCTUnwrap(NSImage(contentsOf: first))
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, OffscreenCapture.sceneWidth)
        XCTAssertEqual(cg.height, OffscreenCapture.sceneHeight)
        SceneRenderSettings.fitMode = .stretch
        TextScriptEngine.captureDateEpochMillis = 123
        TextScriptEngine.captureRandomSeed = 456
        let second = try XCTUnwrap(OffscreenCapture.scene(project: project, toDir: root).first)
        XCTAssertEqual(try Data(contentsOf: second), before)
        XCTAssertEqual(SceneRenderSettings.fitMode, .stretch)
        XCTAssertEqual(TextScriptEngine.captureDateEpochMillis, 123)
        XCTAssertEqual(TextScriptEngine.captureRandomSeed, 456)
        try Data("not scene JSON".utf8).write(to: root.appendingPathComponent("scene.json"))
        XCTAssertThrowsError(try OffscreenCapture.scene(project: project, toDir: root))
        XCTAssertEqual(SceneRenderSettings.fitMode, .stretch)
        XCTAssertEqual(TextScriptEngine.captureDateEpochMillis, 123)
        XCTAssertEqual(TextScriptEngine.captureRandomSeed, 456)
    }
}
