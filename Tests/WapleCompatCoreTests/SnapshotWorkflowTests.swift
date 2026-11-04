import XCTest
import AppKit
import Metal
import WapleCore
import WapleSnapshot
import WapleRender
@testable import WapleCompatCore

final class SnapshotWorkflowTests: XCTestCase {
    private var settingsSuite: String!
    override func setUpWithError() throws {
        settingsSuite = "waple.snapshot.workflow.\(UUID().uuidString)"
        SceneRenderSettings.defaults = try XCTUnwrap(UserDefaults(suiteName: settingsSuite))
    }
    override func tearDownWithError() throws {
        SceneRenderSettings.defaults.removePersistentDomain(forName: settingsSuite)
        SceneRenderSettings.defaults = .standard
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-workflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func scene(_ root: URL, id: String, packed: Bool = false) throws -> WallpaperProject {
        let folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = Data(#"{"general":{"orthogonalprojection":{"width":256,"height":144},"clearcolor":"0.5 0.5 0.5"},"objects":[]}"#.utf8)
        let file = packed ? "scene.pkg" : "custom.json"
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": file]).write(to: folder.appendingPathComponent("project.json"))
        if packed {
            func integer(_ value: Int) -> Data {
                var value = UInt32(value).littleEndian
                return withUnsafeBytes(of: &value) { Data($0) }
            }
            let name = Data("scene.json".utf8)
            var data = integer(8)
            data.append(Data("PKGV0001".utf8)); data.append(integer(1))
            data.append(integer(name.count)); data.append(name); data.append(integer(0)); data.append(integer(json.count)); data.append(json)
            try data.write(to: folder.appendingPathComponent(file))
        } else { try json.write(to: folder.appendingPathComponent(file)) }
        return try ProjectJSONParser.parse(folderURL: folder)
    }

    private func writePNG(_ pixels: [UInt8], to url: URL) throws {
        let w = SnapshotPipeline.thumbW, h = SnapshotPipeline.thumbH
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32))
        let destination = try XCTUnwrap(rep.bitmapData)
        pixels.withUnsafeBufferPointer { source in destination.update(from: source.baseAddress!, count: pixels.count) }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private func helper(in root: URL, images: [String: URL]) throws -> URL {
        let fixtures = root.appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        for (id, image) in images { try FileManager.default.copyItem(at: image, to: fixtures.appendingPathComponent("\(id).png")) }
        let helper = root.appendingPathComponent("helper.sh")
        try Data("""
        #!/bin/sh
        for image in "$(dirname "$0")"/fixtures/*.png; do
          [ -f "$image" ] || continue
          cp "$image" "$3/" || exit 1
        done
        """.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper
    }

    private func withHelper(_ helper: URL, body: () throws -> Void) rethrows {
        let old = ProcessInfo.processInfo.environment["WAPLE_SNAPSHOT_HELPER"]
        setenv("WAPLE_SNAPSHOT_HELPER", helper.path, 1)
        defer {
            if let old { setenv("WAPLE_SNAPSHOT_HELPER", old, 1) }
            else { unsetenv("WAPLE_SNAPSHOT_HELPER") }
        }
        try body()
    }

    private func baseline(in root: URL, pixels: [UInt8], deterministic: Bool) throws -> URL {
        let baseline = root.appendingPathComponent("baseline")
        let thumbs = baseline.appendingPathComponent("thumbs")
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        try writePNG(pixels, to: thumbs.appendingPathComponent("subject.png"))
        let entry = SnapshotEntry(id: "subject", width: SnapshotPipeline.thumbW, height: SnapshotPipeline.thumbH,
                                  hash: fnv1a(pixels), meanLuma: meanLuma(rgba: pixels), deterministic: deterministic, selfMaxDiff: 0)
        try SnapshotManifest(gitSHA: "fixture", label: "fixture", thumbWidth: SnapshotPipeline.thumbW,
            thumbHeight: SnapshotPipeline.thumbH, captureTime: SnapshotPipeline.primaryCaptureTime,
            createdAt: "fixture", entries: [entry], empties: [], failures: [], activeDebugGates: [])
            .encoded().write(to: baseline.appendingPathComponent("manifest.json"))
        return baseline
    }

    @MainActor func testPublicCaptureIncludesMixedProjectsAndProducesReadableManifestAndPNGs() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let root = try root(), corpus = root.appendingPathComponent("corpus")
        let packed = try scene(corpus, id: "packed", packed: true)
        let loose = try scene(corpus, id: "loose")
        let frames = root.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        var images: [String: URL] = [:]
        for project in [packed, loose] {
            guard case let .pixels(_, png) = try SnapshotPipeline.captureFrame(project: project, into: frames) else {
                return XCTFail("synthetic scene must render")
            }
            let saved = root.appendingPathComponent("\(project.id).png")
            try FileManager.default.copyItem(at: png, to: saved); images[project.id] = saved
        }
        let helper = try helper(in: root, images: images)
        try withHelper(helper) {
            let output = root.appendingPathComponent("captures")
            XCTAssertEqual(SnapshotPipeline.runCapture(root: corpus.path, outDir: output, label: "new"), 0)
            let captured = output.appendingPathComponent("new")
            let manifest = try SnapshotManifest.decode(Data(contentsOf: captured.appendingPathComponent("manifest.json")))
            XCTAssertEqual(manifest.entries.map(\.id), ["loose", "packed"])
            XCTAssertTrue(manifest.failures.isEmpty)
            for entry in manifest.entries {
                let rgba = try XCTUnwrap(SnapshotPipeline.pngToRGBA(captured.appendingPathComponent("thumbs/\(entry.id).png"),
                    width: manifest.thumbWidth, height: manifest.thumbHeight))
                XCTAssertEqual(entry.hash, fnv1a(rgba))
            }
            XCTAssertEqual(SnapshotPipeline.runCompare(root: corpus.path, baselineDir: captured), 0)
        }
    }

    @MainActor func testPublicCompareFailsWhenCurrentBuildLosesDeterminism() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let root = try root(), corpus = root.appendingPathComponent("corpus")
        let project = try scene(corpus, id: "subject")
        guard case let .pixels(pixels, _) = try SnapshotPipeline.captureFrame(project: project, into: root) else {
            return XCTFail("synthetic scene must render")
        }
        let baseline = try baseline(in: root, pixels: pixels, deterministic: true)
        var changed = pixels
        for index in changed.indices where index % 4 != 3 { changed[index] = pixels[index] > 223 ? 0 : pixels[index] + 32 }
        let second = root.appendingPathComponent("second.png")
        try writePNG(changed, to: second)
        let helper = try helper(in: root, images: ["subject": second])
        withHelper(helper) { XCTAssertEqual(SnapshotPipeline.runCompare(root: corpus.path, baselineDir: baseline), 1) }
    }

    @MainActor func testPublicCompareTightensHistoricNondeterministicEntryAndRejectsMissingSelfCheck() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let root = try root(), corpus = root.appendingPathComponent("corpus")
        let project = try scene(corpus, id: "subject")
        guard case let .pixels(pixels, png) = try SnapshotPipeline.captureFrame(project: project, into: root) else {
            return XCTFail("synthetic scene must render")
        }
        let second = root.appendingPathComponent("second.png")
        try FileManager.default.copyItem(at: png, to: second)
        var changed = pixels
        for index in changed.indices where index % 4 != 3 { changed[index] = pixels[index] > 251 ? pixels[index] - 4 : pixels[index] + 4 }
        let baseline = try baseline(in: root, pixels: changed, deterministic: false)
        XCTAssertTrue(goldenVerdict(diffRGBA(pixels, changed), baselineMeanLuma: meanLuma(rgba: changed), deterministic: false).pass,
                      "fixture must expose the old lax-only false success")
        let helper = try helper(in: root, images: ["subject": second])
        withHelper(helper) { XCTAssertEqual(SnapshotPipeline.runCompare(root: corpus.path, baselineDir: baseline), 1) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("fixtures/subject.png"))
        withHelper(helper) { XCTAssertEqual(SnapshotPipeline.runCompare(root: corpus.path, baselineDir: baseline), 2) }
    }
}
