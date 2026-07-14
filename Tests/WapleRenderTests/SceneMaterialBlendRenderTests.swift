import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// material passes[0].blending 고정기능 상태 오라클.
/// 불투명 초록 dst + alpha 0.5 빨강 src:
/// additive = (0.5, 1.0, 0), over = (0.5, 0.5, 0).
final class SceneMaterialBlendRenderTests: XCTestCase {
    private func centerPixel(blending: String?, hdr: Bool = false, tag: String) throws -> NSColor {
        let blendField = blending.map { ",\"blending\":\"\($0)\"" } ?? ""
        let foregroundMaterial = "{\"passes\":[{\"textures\":[\"fg\"]\(blendField)}]}"
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0","hdr":\(hdr)},
         "objects":[
           {"id":1,"image":"models/bg.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/fg.json","origin":"960 540 0","size":"1920 1080","alpha":0.5}]}
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/bg.json", #"{"material":"materials/bg.json"}"#.data(using: .utf8)!),
            ("materials/bg.json", #"{"passes":[{"textures":["bg"]}]}"#.data(using: .utf8)!),
            ("materials/bg.tex", solidTex(0, 255, 0)),
            ("models/fg.json", #"{"material":"materials/fg.json"}"#.data(using: .utf8)!),
            ("materials/fg.json", foregroundMaterial.data(using: .utf8)!),
            ("materials/fg.tex", solidTex(255, 0, 0)),
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_material_blend_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: "material-blend-\(tag)", type: .scene, fileName: "scene.pkg", previewName: nil,
            title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir
        )
        let renderer = SceneRenderer()
        try renderer.mount(
            in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
            project: project
        )
        defer { renderer.teardown() }
        if hdr {
            XCTAssertTrue(renderer.hdrActive, "fixture must exercise rgba16Float accumulation")
        }
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_material_blend_out_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(
            renderer.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first
        )
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        return try XCTUnwrap(rep.colorAt(x: 32, y: 18))
    }

    func testAdditiveMaterialAddsPremultipliedSourceInLDR() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let color = try centerPixel(blending: "additive", tag: "additive-ldr")
        XCTAssertEqual(color.redComponent, 0.5, accuracy: 0.06)
        XCTAssertEqual(color.greenComponent, 1.0, accuracy: 0.06)
        XCTAssertEqual(color.blueComponent, 0.0, accuracy: 0.06)
    }

    func testNormalTranslucentAndOmittedMaterialsKeepOverInLDR() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let modes: [String?] = ["normal", "translucent", nil]
        for mode in modes {
            let name = mode ?? "omitted"
            let color = try centerPixel(blending: mode, tag: "over-\(name)")
            XCTAssertEqual(color.redComponent, 0.5, accuracy: 0.06, name)
            XCTAssertEqual(color.greenComponent, 0.5, accuracy: 0.06, name)
            XCTAssertEqual(color.blueComponent, 0.0, accuracy: 0.06, name)
        }
    }

    func testAdditiveMaterialUsesHDRAccumulatorFormat() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let color = try centerPixel(blending: "additive", hdr: true, tag: "additive-hdr")
        XCTAssertGreaterThan(color.redComponent, 0.45)
        XCTAssertGreaterThan(color.greenComponent, color.redComponent + 0.10)
        XCTAssertLessThan(color.blueComponent, 0.05)
    }
}
