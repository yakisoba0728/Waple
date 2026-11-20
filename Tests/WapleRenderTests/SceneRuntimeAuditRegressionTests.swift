import AppKit
import Metal
import XCTest
@testable import WapleCore
@testable import WapleRender

final class SceneRuntimeAuditRegressionTests: XCTestCase {
    private func makeProject(_ scene: String, extraFiles: [(String, Data)] = []) throws -> WallpaperProject {
        let directory = try tempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try encodePkg([("scene.json", Data(scene.utf8))] + extraFiles).write(to: directory.appendingPathComponent("scene.pkg"))
        return WallpaperProject(id: UUID().uuidString, type: .scene, fileName: "scene.pkg", previewName: nil,
            title: "scene audit", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: directory)
    }

    @MainActor func testCustomMeshDrawBindsTypedCameraUniformAndVertexSampler() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let assets: [(String, Data)] = [
            ("models/plane.mdl", planeModel()),
            ("materials/plane.json", Data(#"{"passes":[{"shader":"auditmesh","textures":[null,"red"]}]}"#.utf8)),
            ("materials/red.tex", solidTex(255, 0, 0)),
            ("shaders/auditmesh.vert", Data("""
            uniform mat4 g_ModelViewProjectionMatrix;
            uniform vec3 g_EyePosition;
            uniform sampler2D g_Texture1;
            attribute vec3 a_Position;
            varying vec4 v_Color;
            void main() {
                gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
                vec4 pixel = texSample2DLod(g_Texture1, vec2(0.5), 0.0);
                v_Color = vec4(pixel.r, step(5.0, g_EyePosition.z), pixel.b, 1.0);
            }
            """.utf8)),
            ("shaders/auditmesh.frag", Data("varying vec4 v_Color;\nvoid main() { gl_FragColor = v_Color; }".utf8))
        ]
        for orthographic in [false, true] {
            let projection = orthographic ? #","orthogonalprojection":{"width":64,"height":36}"# : ""
            let transform = orthographic ? #","origin":"32 18 0","scale":"7 7 1""# : ""
            let project = try makeProject("""
            {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
             "general":{"fov":50,"clearcolor":"0 0 0"\(projection)},
             "objects":[{"id":1,"model":"models/plane.mdl"\(transform)}]}
            """, extraFiles: assets)
            let renderer = SceneRenderer()
            defer { renderer.teardown() }
            try renderer.mount(in: NSView(frame: CGRect(x: 0, y: 0, width: 64, height: 36)), project: project)
            XCTAssertNotNil(renderer.meshRenderables.first?.meshes.first?.customShader)
            let frame = try XCTUnwrap(renderer.captureFrames(width: 64, height: 36, times: [0], toDir: project.folderURL).first)
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: frame)))
            var pixel = [Int](repeating: 0, count: image.samplesPerPixel)
            pixel.withUnsafeMutableBufferPointer { image.getPixel($0.baseAddress!, atX: 32, y: 18) }
            XCTAssertGreaterThan(pixel[0], 245, "Vertex stage sampled the red input.")
            XCTAssertGreaterThan(pixel[1], 245, "Typed uniform carried the camera's Z coordinate.")
            XCTAssertLessThan(pixel[2], 10)
        }
    }

    @MainActor func testBlankTextGetsEffectsWhenHeadlessScriptProducesContent() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let project = try makeProject(#"""
        {"general":{"orthogonalprojection":{"width":128,"height":72}},
         "objects":[{"id":1,"origin":"64 36 0","pointsize":12,"text":{"value":"",
             "script":"export function update(value) { return engine.runtime > 0.5 ? 'READY' : ''; }"},
             "effects":[{"file":"effects/blur/effect.json"}]}]}
        """#)
        let renderer = SceneRenderer()
        defer { renderer.teardown() }
        try renderer.mount(in: NSView(frame: CGRect(x: 0, y: 0, width: 128, height: 72)), project: project)
        XCTAssertNil(renderer.textLayers.first?.texture)
        let times: [Float] = [1.01, 1.02]
        let frames = renderer.captureFrames(width: 128, height: 72, times: times, toDir: project.folderURL)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(Set(frames).count, 2)
        XCTAssertTrue(frames.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(renderer.textLayers.first?.lastText, "READY")
        XCTAssertNotNil(renderer.textLayers.first?.texture)
        XCTAssertEqual(renderer.textLayers.first?.effects.count, 1)
    }

    @MainActor func testDenyingSceneScriptsKeepsAuthoredStaticText() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let project = try makeProject(#"""
        {"general":{"orthogonalprojection":{"width":64,"height":36}},
         "objects":[{"id":1,"origin":"32 18 0","pointsize":12,"text":{"value":"authored",
             "script":"export function update(value) { return 'script'; }"}}]}
        """#)
        let renderer = SceneRenderer()
        renderer.allowsSceneScripts = false
        defer { renderer.teardown() }
        try renderer.mount(in: NSView(frame: CGRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        XCTAssertNil(renderer.sceneScript)
        XCTAssertNil(renderer.textLayers[0].engine)
        XCTAssertEqual(renderer.textLayers[0].lastText, "authored")
        XCTAssertNotNil(renderer.textLayers[0].texture)
    }

    @MainActor func testRuntimeLayerDeletionReleasesUniqueFramebufferBudget() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let project = try makeProject(#"""
        {"general":{"orthogonalprojection":{"width":64,"height":36}},
         "objects":[{"id":1,"name":"trail","image":"models/image.json","origin":"32 18 0","size":"64 36",
             "effects":[{"file":"effects/motionblur/effect.json"}]}]}
        """#, extraFiles: [
            ("models/image.json", Data(#"{"material":"materials/image.json"}"#.utf8)),
            ("materials/image.json", Data(#"{"passes":[{"textures":["image"]}]}"#.utf8)),
            ("materials/image.tex", solidTex(255, 255, 255))
        ])
        let renderer = SceneRenderer()
        defer { renderer.teardown() }
        try renderer.mount(in: NSView(frame: CGRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        XCTAssertEqual(renderer.captureFrames(width: 64, height: 36, times: [0], toDir: project.folderURL).count, 1)
        XCTAssertGreaterThan(renderer.uniqueFBOBytesInUse, 0)
        renderer.sceneScript?.context.evaluateScript("thisScene.destroyLayer(thisScene.getLayer('trail'));")
        renderer.consumeSceneRuntimeCommands()
        XCTAssertTrue(renderer.layers.isEmpty)
        XCTAssertEqual(renderer.uniqueFBOBytesInUse, 0)
    }

    @MainActor func testSceneMarksMountedResourceGrantStaleWhenUserRemovesIt() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let project = try makeProject(#"""
        {"general":{"orthogonalprojection":{"width":64,"height":36}},"objects":[]}
        """#).with(userStateID: UUID().uuidString)
        let resource = project.folderURL.appendingPathComponent("picked.png")
        try solidTex(255, 255, 255).write(to: resource)
        defer { UserPropertyStore.reset(id: project.userStateID) }
        UserPropertyStore.setResourceGrant(absolutePath: resource.path, key: "image", id: project.userStateID)

        let renderer = SceneRenderer()
        defer { renderer.teardown() }
        try renderer.mount(in: NSView(frame: CGRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        XCTAssertFalse(renderer.hasStaleResourceGrants(id: project.userStateID))
        UserPropertyStore.setResourceGrant(absolutePath: nil, key: "image", id: project.userStateID)
        XCTAssertTrue(renderer.hasStaleResourceGrants(id: project.userStateID))
    }
}
