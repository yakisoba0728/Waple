import XCTest
@testable import WapleCore
@testable import WapleRender

final class SceneRendererPathFallbackTests: XCTestCase {
    func testBaseAssetFallbackLoadsRelativeAssetInsideBaseDirectory() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("waple-base-\(UUID().uuidString)", isDirectory: true)
        let nested = base.appendingPathComponent("materials", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try Data("inside".utf8).write(to: nested.appendingPathComponent("ok.bin"))

        let renderer = SceneRenderer()
        renderer.assetBaseDir = base
        let package = ScenePackage.assemble([])

        XCTAssertEqual(renderer.assetData("materials/ok.bin", package: package), Data("inside".utf8))
        XCTAssertEqual(renderer.quietAssetData("materials/ok.bin", package: package), Data("inside".utf8))
    }

    func testBaseAssetFallbackRejectsTraversalOutsideBaseDirectory() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent("waple-parent-\(UUID().uuidString)", isDirectory: true)
        let base = parent.appendingPathComponent("base", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }
        try Data("outside".utf8).write(to: parent.appendingPathComponent("secret.bin"))

        let renderer = SceneRenderer()
        renderer.assetBaseDir = base
        let package = ScenePackage.assemble([])

        XCTAssertNil(renderer.assetData("../secret.bin", package: package))
        XCTAssertNil(renderer.quietAssetData("../secret.bin", package: package))
    }

    func testBaseAssetFallbackRejectsSymlinkEscape() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent("waple-parent-\(UUID().uuidString)", isDirectory: true)
        let base = parent.appendingPathComponent("base", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.bin"))
        try fm.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: outside)

        let renderer = SceneRenderer()
        renderer.assetBaseDir = base
        let package = ScenePackage.assemble([])

        XCTAssertNil(renderer.assetData("link/secret.bin", package: package))
        XCTAssertNil(renderer.quietAssetData("link/secret.bin", package: package))
    }

    func testScenePackageDiscoveryIsCaseInsensitive() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("waple-scene-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let packageURL = folder.appendingPathComponent("Scene.pkg")
        try Data("pkg".utf8).write(to: packageURL)

        let found = try XCTUnwrap(SceneRenderer().pkgURL(in: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: found.path))
        XCTAssertEqual(found.lastPathComponent.lowercased(), "scene.pkg")
    }

    func testRequiredAssetPackageAndBaseSuccessStayUndiagnosed() throws {
        let package = ScenePackage.assemble([
            (name: "materials/in-package.bin", data: Data("package".utf8)),
        ])
        let renderer = SceneRenderer()

        XCTAssertEqual(
            renderer.resolveRequiredAsset(
                ["materials/in-package.bin"], package: package, decode: { $0 }),
            Data("package".utf8)
        )
        XCTAssertFalse(renderer.hasMissingRequiredSharedAssets)

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("waple-required-base-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("materials", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("base".utf8).write(to: base.appendingPathComponent("materials/in-base.bin"))
        renderer.assetBaseDir = base

        XCTAssertEqual(
            renderer.resolveRequiredAsset(
                ["materials/in-base.bin"], package: ScenePackage.assemble([]), decode: { $0 }),
            Data("base".utf8)
        )
        XCTAssertFalse(renderer.hasMissingRequiredSharedAssets)
    }

    func testRequiredAssetWaitsForAllCandidatesAndCollapsesRepeatedMisses() {
        let package = ScenePackage.assemble([
            (name: "raw-name.tex", data: Data("raw".utf8)),
        ])
        let renderer = SceneRenderer()

        XCTAssertEqual(
            renderer.resolveRequiredAsset(
                ["materials/raw-name.tex", "raw-name.tex"], package: package, decode: { $0 }),
            Data("raw".utf8),
            "a later raw/package candidate must prevent the diagnostic"
        )
        XCTAssertFalse(renderer.hasMissingRequiredSharedAssets)

        XCTAssertEqual(
            renderer.resolveRequiredAsset(
                ["materials/missing-but-bitmap-exists.tex"],
                package: package,
                decode: { $0 },
                alternate: { Data("bitmap".utf8) }
            ),
            Data("bitmap".utf8),
            "a successful high-level bitmap/raw alternate must prevent the diagnostic"
        )
        XCTAssertFalse(renderer.hasMissingRequiredSharedAssets)

        renderer.assetBaseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waple-deleted-base-\(UUID().uuidString)", isDirectory: true)
        XCTAssertNil(renderer.resolveRequiredAsset(
            ["materials/missing.tex", "missing.tex"], package: package, decode: { $0 }))
        XCTAssertTrue(renderer.hasMissingRequiredSharedAssets, "a selected but deleted base directory is a real miss")
        XCTAssertNil(renderer.resolveRequiredAsset(
            ["materials/missing-again.tex"], package: package, decode: { $0 }))
        XCTAssertTrue(renderer.hasMissingRequiredSharedAssets, "repeated misses remain one boolean diagnostic")
    }

    func testLowLevelQuietAndRejectedLookupsStayUndiagnosed() {
        let renderer = SceneRenderer()
        let package = ScenePackage.assemble([])

        XCTAssertNil(renderer.assetData("materials/probe.bin", package: package))
        XCTAssertNil(renderer.quietAssetData("materials/quiet.bin", package: package))
        XCTAssertNil(renderer.resolveRequiredAsset(
            ["../secret.bin"], package: package, decode: { $0 }))
        XCTAssertFalse(renderer.hasMissingRequiredSharedAssets)
    }
}
