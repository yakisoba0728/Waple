import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

final class LDRBloomRendererTests: XCTestCase {
    private struct Capture {
        let image: NSBitmapImageRep
        let is3D: Bool
        let wantsLDRBloom: Bool
    }

    private func capture(scene: String, tag: String) throws -> Capture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("waple_ldr_bloom_\(tag)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/spot.json", Data(#"{"material":"materials/spot.json"}"#.utf8)),
            ("materials/spot.json", Data(#"{"passes":[{"textures":["spot"]}]}"#.utf8)),
            ("materials/spot.tex", solidTex(255, 255, 255, w: 2, h: 2))
        ]
        try encodePkg(files).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: tag,
            type: .scene,
            fileName: "scene.pkg",
            previewName: nil,
            title: tag,
            tags: [],
            contentRating: nil,
            workshopId: nil,
            dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(
            in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)),
            project: project)
        defer { renderer.teardown() }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = try XCTUnwrap(
            renderer.captureFrames(width: 64, height: 64, times: [0], toDir: output).first)
        let image = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        return Capture(
            image: image,
            is3D: renderer.is3D,
            wantsLDRBloom: renderer.sceneWantsLDRBloom)
    }

    private func scene2D(bloom: Bool, hdr: Bool) -> String {
        """
        {"general":{"orthogonalprojection":{"width":64,"height":64},
          "clearcolor":"0 0 0","bloom":\(bloom),"hdr":\(hdr),
          "bloomstrength":8,"bloomthreshold":0,"bloomtint":"1 1 1"},
         "objects":[{"id":1,"image":"models/spot.json","origin":"32 32 0",
                     "size":"4 4","color":"1 1 1","alpha":1,"brightness":1}]}
        """
    }

    private func scene3D(bloom: Bool) -> String {
        """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50,"nearz":0.05,"farz":50,
          "clearcolor":"0 0 0","bloom":\(bloom),"hdr":false,
          "bloomstrength":8,"bloomthreshold":0,"bloomtint":"1 1 1"},
         "objects":[
           {"id":1,"model":"models/missing.mdl"},
           {"id":2,"image":"models/spot.json","origin":"0 0 0","size":"1 1",
            "color":"1 1 1","alpha":1,"brightness":1}
         ]}
        """
    }

    private func halo(_ image: NSBitmapImageRep, exclusionRadius: Int) -> CGFloat {
        let centerX = image.pixelsWide / 2
        let centerY = image.pixelsHigh / 2
        var maximum: CGFloat = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide
            where abs(x - centerX) > exclusionRadius || abs(y - centerY) > exclusionRadius {
                guard let color = image.colorAt(x: x, y: y) else { continue }
                maximum = max(
                    maximum,
                    max(color.redComponent, max(color.greenComponent, color.blueComponent)))
            }
        }
        return maximum
    }

    func testHeadless2DBloomUsesExactGateAndPreservesBloomFalseAndHDRPaths() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let enabled = try capture(scene: scene2D(bloom: true, hdr: false), tag: "2d_on")
        let disabled = try capture(scene: scene2D(bloom: false, hdr: false), tag: "2d_off")
        let hdr = try capture(scene: scene2D(bloom: true, hdr: true), tag: "2d_hdr")

        XCTAssertFalse(enabled.is3D)
        XCTAssertTrue(enabled.wantsLDRBloom)
        XCTAssertFalse(disabled.wantsLDRBloom)
        XCTAssertFalse(hdr.wantsLDRBloom)
        XCTAssertGreaterThan(
            halo(enabled.image, exclusionRadius: 6),
            halo(disabled.image, exclusionRadius: 6) + 0.01)
        XCTAssertEqual(
            halo(hdr.image, exclusionRadius: 6),
            halo(disabled.image, exclusionRadius: 6),
            accuracy: 0.01)
    }

    func testHeadlessNonHDR3DCameraPassUsesTheSameBloomFinalizer() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let enabled = try capture(scene: scene3D(bloom: true), tag: "3d_on")
        let disabled = try capture(scene: scene3D(bloom: false), tag: "3d_off")

        XCTAssertTrue(enabled.is3D)
        XCTAssertTrue(disabled.is3D)
        XCTAssertTrue(enabled.wantsLDRBloom)
        XCTAssertFalse(disabled.wantsLDRBloom)
        XCTAssertGreaterThan(
            halo(enabled.image, exclusionRadius: 10),
            halo(disabled.image, exclusionRadius: 10) + 0.01)
    }

    func testDirectRemountFromHDRToLDRBloomResetsHDRStateAndSelectsBGRA8Bloom() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("waple_ldr_bloom_remount_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func project(scene: String, tag: String) throws -> WallpaperProject {
            let folder = root.appendingPathComponent(tag, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let files: [(String, Data)] = [
                ("scene.json", Data(scene.utf8)),
                ("models/spot.json", Data(#"{"material":"materials/spot.json"}"#.utf8)),
                ("materials/spot.json", Data(#"{"passes":[{"textures":["spot"]}]}"#.utf8)),
                ("materials/spot.tex", solidTex(255, 255, 255, w: 2, h: 2))
            ]
            try encodePkg(files).write(to: folder.appendingPathComponent("scene.pkg"))
            return WallpaperProject(
                id: tag,
                type: .scene,
                fileName: "scene.pkg",
                previewName: nil,
                title: tag,
                tags: [],
                contentRating: nil,
                workshopId: nil,
                dependency: nil,
                folderURL: folder)
        }

        let renderer = SceneRenderer()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        try renderer.mount(
            in: container,
            project: project(scene: scene2D(bloom: true, hdr: true), tag: "hdr"))
        XCTAssertTrue(renderer.hdrActive)
        XCTAssertEqual(renderer.accPixelFormat, .rgba16Float)
        XCTAssertFalse(renderer.sceneWantsLDRBloom)

        try renderer.mount(
            in: container,
            project: project(scene: scene2D(bloom: true, hdr: false), tag: "ldr"))
        defer { renderer.teardown() }

        XCTAssertFalse(renderer.sceneIsHDR)
        XCTAssertNil(renderer.hdrPost)
        XCTAssertFalse(renderer.hdrActive)
        XCTAssertEqual(renderer.accPixelFormat, .bgra8Unorm)
        XCTAssertTrue(renderer.sceneWantsLDRBloom)
    }
}
