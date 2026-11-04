import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

final class CompositionRenderTargetRegressionTests: XCTestCase {
    private func render(blend: Int = 0, nested: Bool = false) throws -> (SIMD3<Float>, SceneRenderer) {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("waple-composite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let extraGroup = nested ? #",{"id":3,"parent":2,"image":"models/rt.json","origin":"0 0 0","size":"64 36","copybackground":false}"# : ""
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":36},"clearcolor":"0 0 0"},"objects":[
          {"id":1,"image":"models/w.json","origin":"32 18 0","size":"64 36","color":"0 0 1"},
          {"id":2,"image":"models/rt.json","origin":"32 18 0","size":"64 36","copybackground":false,"colorBlendMode":\(blend)}
          \(extraGroup),
          {"id":4,"parent":\(nested ? 3 : 2),"image":"models/w.json","origin":"0 0 0","size":"64 36","color":"1 0 0","alpha":0.5}]}
        """
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/w.json", Data(#"{"material":"materials/w.json"}"#.utf8)),
            ("materials/w.json", Data(#"{"passes":[{"textures":["w"]}]}"#.utf8)),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("models/rt.json", Data(#"{"material":"materials/rt.json","passthrough":true}"#.utf8)),
            ("materials/rt.json", Data(#"{"passes":[{"shader":"composelayer","textures":["_rt_FullFrameBuffer"]}]}"#.utf8))
        ]
        try encodePkg(files).write(to: directory.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: UUID().uuidString, type: .scene, fileName: "scene.pkg", previewName: nil,
            title: "composition", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: directory)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        let result = try XCTUnwrap(renderer.captureFrames(width: 64, height: 36, times: [0.1], toDir: directory).first)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: result)))
        // Test stored render channels; NSColor conversion applies the display ICC profile to these bytes.
        var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        pixel.withUnsafeMutableBufferPointer { bitmap.getPixel($0.baseAddress!, atX: 32, y: 18) }
        let color = SIMD3(Float(pixel[0]), Float(pixel[1]), Float(pixel[2])) / 255
        return (color, renderer)
    }

    func testCompositionOwnsChildrenAndDoesNotDrawThemTwice() throws {
        let (color, renderer) = try render()
        defer { renderer.teardown() }
        XCTAssertEqual(renderer.compositionDrawPlan(rootID: nil).count, 2)
        XCTAssertEqual(renderer.compositionDrawPlan(rootID: 2).count, 1)
        XCTAssertNotNil(renderer.compositeLayerTextures[2])
        XCTAssertEqual(color.x, 0.5, accuracy: 0.025)
        XCTAssertEqual(color.z, 0.5, accuracy: 0.025)
    }

    func testCopyBackgroundFalseBlendUsesActualParentScene() throws {
        let (color, renderer) = try render(blend: 18)
        defer { renderer.teardown() }
        XCTAssertEqual(color.x, 0.5, accuracy: 0.025)
        XCTAssertEqual(color.z, 1, accuracy: 0.025)
    }

    func testNestedCompositionPreservesCoverageThroughEachTarget() throws {
        let (color, renderer) = try render(nested: true)
        defer { renderer.teardown() }
        XCTAssertEqual(renderer.compositionDrawPlan(rootID: 2).count, 1)
        XCTAssertEqual(renderer.compositionDrawPlan(rootID: 3).count, 1)
        XCTAssertEqual(color.x, 0.5, accuracy: 0.025)
        XCTAssertEqual(color.z, 0.5, accuracy: 0.025)
    }
}
