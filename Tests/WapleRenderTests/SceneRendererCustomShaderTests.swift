import XCTest
@testable import WapleCore
@testable import WapleRender

final class SceneRendererCustomShaderTests: XCTestCase {
    private func project(files: [(String, Data)], id: String) throws -> WallpaperProject {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h1_\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        return WallpaperProject(id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
                                title: id, tags: [], contentRating: nil, workshopId: nil,
                                dependency: nil, folderURL: dir)
    }

    private let scene = """
    {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
     "objects":[{"image":"models/x.json","origin":"960 540","size":"1920 1080","scale":"1 1",
                 "angles":"0 0 0","alpha":1.0,"color":"1 1 1","brightness":1.0,"visible":true}]}
    """
    private let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#

    func testCustomShaderLayerBuildsPipeline() throws {
        let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/x.json", model.data(using: .utf8)!),
            ("materials/m.json", material.data(using: .utf8)!),
            ("materials/pic.tex", solidTex(255, 0, 0)),
            ("shaders/genericimage2.vert", vert.data(using: .utf8)!),
            ("shaders/genericimage2.frag", frag.data(using: .utf8)!),
        ]
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
                    project: try project(files: files, id: "custom"))
        defer { r.teardown() }
        XCTAssertEqual(r.layers.count, 1)
        XCTAssertNotNil(r.layers[0].customShader)
    }

    func testCustomShaderFallbackOnMissingShader() throws {
        let material = #"{"passes":[{"shader":"missing_shader","textures":["pic"]}]}"#
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/x.json", model.data(using: .utf8)!),
            ("materials/m.json", material.data(using: .utf8)!),
            ("materials/pic.tex", solidTex(255, 0, 0)),
        ]
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
                    project: try project(files: files, id: "fallback"))
        defer { r.teardown() }
        XCTAssertEqual(r.layers.count, 1)
        XCTAssertNil(r.layers[0].customShader, "missing shader must fall back to QuadShaders")
    }
}
