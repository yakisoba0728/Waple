import XCTest
@testable import WapleCompatCore
import WapleCore

final class AuditCompatRegressionTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("waple-compat-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func scene(in root: URL, conventionalScene: String? = nil) throws -> URL {
        let folder = root.appendingPathComponent("custom-scene", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type":"scene","file":"ricepod.json"}"#.utf8)
            .write(to: folder.appendingPathComponent("project.json"))
        try Data(#"{"general":{"orthogonalprojection":{"width":100,"height":100},"hdr":true},"objects":[]}"#.utf8)
            .write(to: folder.appendingPathComponent("ricepod.json"))
        if let conventionalScene {
            try Data(conventionalScene.utf8).write(to: folder.appendingPathComponent("scene.json"))
        }
        return folder
    }

    func testCaptureRefusesExistingBaselineBeforeStartingHelper() throws {
        let root = try temporaryDirectory()
        let folder = try scene(in: root)
        let output = root.appendingPathComponent("captures", isDirectory: true)
        let baseline = output.appendingPathComponent("known-good", isDirectory: true)
        let thumbs = baseline.appendingPathComponent("thumbs", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        let manifest = Data("original manifest".utf8)
        let png = Data("original pixels".utf8)
        try manifest.write(to: baseline.appendingPathComponent("manifest.json"))
        try png.write(to: thumbs.appendingPathComponent("custom-scene.png"))
        let marker = root.appendingPathComponent("helper-ran")
        let helper = root.appendingPathComponent("fail-helper.sh")
        try Data("""
        #!/bin/sh
        : > "$(dirname "$0")/helper-ran"
        exit 1
        """.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let oldHelper = ProcessInfo.processInfo.environment["WAPLE_SNAPSHOT_HELPER"]
        setenv("WAPLE_SNAPSHOT_HELPER", helper.path, 1)
        defer {
            if let oldHelper { setenv("WAPLE_SNAPSHOT_HELPER", oldHelper, 1) }
            else { unsetenv("WAPLE_SNAPSHOT_HELPER") }
        }

        XCTAssertEqual(SnapshotPipeline.runCapture(root: folder.path, outDir: output, label: "known-good"), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try Data(contentsOf: baseline.appendingPathComponent("manifest.json")), manifest)
        XCTAssertEqual(try Data(contentsOf: thumbs.appendingPathComponent("custom-scene.png")), png)
    }

    func testCaptureDestinationIsExclusivelyClaimed() throws {
        let root = try temporaryDirectory()
        let destination = try SnapshotPipeline.prepareCaptureDestination(outDir: root, label: "new")
        let marker = destination.appendingPathComponent("keep")
        try Data([1, 2, 3]).write(to: marker)

        XCTAssertThrowsError(try SnapshotPipeline.prepareCaptureDestination(outDir: root, label: "new"))
        XCTAssertEqual(try Data(contentsOf: marker), Data([1, 2, 3]))
    }

    func testCaptureDestinationRejectsLabelsOutsideOneDirectoryComponent() throws {
        let root = try temporaryDirectory()
        for label in ["", ".", "..", "../escape", "nested/label"] {
            XCTAssertThrowsError(try SnapshotPipeline.prepareCaptureDestination(outDir: root, label: label), label)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testInventoryParsesDeclaredSceneInsteadOfConventionalName() throws {
        let root = try temporaryDirectory()
        let folder = try scene(in: root, conventionalScene: #"{"general":{"hdr":false},"objects":[]}"#)
        let csv = root.appendingPathComponent("inventory.csv")

        XCTAssertEqual(ProfilePipeline.runInventory(root: folder.path, outCSV: csv), 0)
        let rows = try String(contentsOf: csv, encoding: .utf8).split(whereSeparator: \.isNewline)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last?.split(separator: ",").dropLast().last, "1", "hdr must come from ricepod.json")
    }

    func testVisibilityScanParsesDeclaredSceneWhenConventionalJSONIsBroken() throws {
        let root = try temporaryDirectory()
        let folder = try scene(in: root, conventionalScene: "not JSON")
        let csv = root.appendingPathComponent("visibility.csv")

        XCTAssertEqual(ProfilePipeline.runVisBlast(root: folder.path, outCSV: csv), 0)
        XCTAssertEqual(try String(contentsOf: csv, encoding: .utf8),
                       "id,layersHidden,textsHidden,particlesHidden,total\n")
    }

    func testProfileCaptureRejectsMissingFrame() {
        XCTAssertThrowsError(try ProfilePipeline.measureCapture(width: 100, height: 100, capture: { [] }))
    }

    func testProfileCaptureRejectsMissingOrEmptyOutputFiles() throws {
        let root = try temporaryDirectory()
        let output = root.appendingPathComponent("frame.png")
        XCTAssertThrowsError(try ProfilePipeline.measureCapture(width: 100, height: 100, capture: { [output] }))
        try Data().write(to: output)
        XCTAssertThrowsError(try ProfilePipeline.measureCapture(width: 100, height: 100, capture: { [output] }))
        XCTAssertThrowsError(try ProfilePipeline.measureCapture(width: 100, height: 100, capture: { [root] }))
    }

    func testProfileCaptureAcceptsOnlyTheRequestedSingleOutput() throws {
        let root = try temporaryDirectory()
        let output = root.appendingPathComponent("frame.png")
        try Data([1]).write(to: output)
        XCTAssertGreaterThanOrEqual(try ProfilePipeline.measureCapture(width: 100, height: 100,
                                                                      capture: { [output] }), 0)
        XCTAssertThrowsError(try ProfilePipeline.measureCapture(width: 100, height: 100,
                                                               capture: { [output, output] }))
    }

    func testProfileCaptureReadsCurrentSizeWhenSameURLIsOverwritten() throws {
        let root = try temporaryDirectory()
        let output = root.appendingPathComponent("frame.png")
        try Data().write(to: output)
        XCTAssertThrowsError(try ProfilePipeline.measureCapture(width: 100, height: 100, capture: { [output] }))
        try Data([1]).write(to: output)
        XCTAssertGreaterThanOrEqual(try ProfilePipeline.measureCapture(width: 100, height: 100,
                                                                     capture: { [output] }), 0)
        try Data().write(to: output)
        XCTAssertThrowsError(try ProfilePipeline.measureCapture(width: 100, height: 100, capture: { [output] }))
    }

    func testProfileCaptureRejectsInvalidDimensionsBeforeCallingRenderer() {
        for (width, height) in [(0, 100), (100, 0), (-1, 100), (Int.max, Int.max)] {
            var captured = false
            XCTAssertThrowsError(try ProfilePipeline.measureCapture(width: width, height: height, capture: {
                captured = true
                return []
            }))
            XCTAssertFalse(captured)
        }
    }
}
