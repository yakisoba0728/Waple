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
}
