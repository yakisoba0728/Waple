import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

final class VolumetricLightTests: XCTestCase {
    /// H5: castVolumetrics 라이트가 있는 3D 씬에서 VolumetricLightPass 가 빌드된다.
    func testVolumetricLightPassBuildsForCastVolumetricsScene() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"fov":50},
         "camera":{"eye":"0 0 10","center":"0 0 0","up":"0 1 0"},
         "objects":[{"light":"point","origin":"0 5 5","color":"1 0.9 0.8","intensity":2,"radius":20,
                     "castvolumetrics":true,"density":2.5,"volumetricsexponent":1.5}]}
        """
        let files: [(String, Data)] = [("scene.json", scene.data(using: .utf8)!)]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h5_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        try Data(#"{"type":"scene","title":"h5","file":"scene.pkg"}"#.utf8).write(to: dir.appendingPathComponent("project.json"))
        let project = try XCTUnwrap(try? ProjectJSONParser.parse(folderURL: dir))
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        XCTAssertNotNil(r.volumetricLightPass)
    }

    /// H5: castVolumetrics 없는 3D 씬은 패스 미빌드.
    func testNoVolumetricLightPassWithoutCastVolumetrics() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"fov":50},
         "camera":{"eye":"0 0 10","center":"0 0 0","up":"0 1 0"},
         "objects":[{"light":"point","origin":"0 5 5","color":"1 0.9 0.8","intensity":2,"radius":20}]}
        """
        let files: [(String, Data)] = [("scene.json", scene.data(using: .utf8)!)]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h5_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        try Data(#"{"type":"scene","title":"h5","file":"scene.pkg"}"#.utf8).write(to: dir.appendingPathComponent("project.json"))
        let project = try XCTUnwrap(try? ProjectJSONParser.parse(folderURL: dir))
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        XCTAssertNil(r.volumetricLightPass)
    }
}
