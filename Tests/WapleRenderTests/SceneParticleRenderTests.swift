import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

final class SceneParticleRenderTests: XCTestCase {
    /// 실제 .pkg 바이너리 인코드(ScenePackage.parse 와 동일 구조).
    private func encodePkg(_ files: [(String, Data)]) -> Data {
        func i32(_ n: Int) -> Data { var v = UInt32(n).littleEndian; return Data(bytes: &v, count: 4) }
        var out = Data()
        let version = "PKGV0001"
        out.append(i32(version.utf8.count)); out.append(version.data(using: .utf8)!)
        out.append(i32(files.count))
        var offset = 0
        for (name, data) in files {
            out.append(i32(name.utf8.count)); out.append(name.data(using: .utf8)!)
            out.append(i32(offset)); out.append(i32(data.count))
            offset += data.count
        }
        for (_, data) in files { out.append(data) }
        return out
    }

    private func snowScenePkg() -> Data {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0.1"},
         "objects":[{"id":1,"name":"snow","particle":"particles/snow.json","origin":"960 0 0","scale":"1 1 1"}]}
        """
        // starttime 0, 위(y큰=화면상단? 실측 대상)에서 방출, 아래로 떨어지는 속도.
        let particle = """
        {"emitter":[{"name":"sphererandom","origin":"0 -40 0","directions":"1 0.06 1","distancemin":10,"distancemax":700,"rate":80}],
         "initializer":[{"name":"lifetimerandom","min":4,"max":7},{"name":"sizerandom","min":18,"max":36},
           {"name":"velocityrandom","min":"-20 -160 0","max":"20 -200 0"},
           {"name":"colorrandom","min":"230 230 255","max":"255 255 255"}],
         "operator":[{"name":"movement","gravity":"0 0 0"},{"name":"alphafade","fadeintime":0.15,"fadeouttime":0.4}],
         "renderer":[{"name":"sprite"}],"maxcount":300,"starttime":0,"material":"materials/snow.json"}
        """
        let material = #"{"passes":[{"shader":"genericparticle","blending":"translucent","textures":["particle/snow"]}]}"#
        return encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("particles/snow.json", particle.data(using: .utf8)!),
            ("materials/snow.json", material.data(using: .utf8)!),
        ])
    }

    func testMountAndCaptureProducesPNG() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_sp4_smoke", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try snowScenePkg().write(to: dir.appendingPathComponent("scene.pkg"))

        let project = WallpaperProject(
            id: "smoke", type: .scene, fileName: "scene.pkg", previewName: nil, title: "smoke",
            tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let renderer = SceneRenderer()
        try renderer.mount(in: container, project: project)
        defer { renderer.teardown() }

        let outDir = URL(fileURLWithPath: "/tmp/waple_sp4")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let urls = renderer.captureFrames(width: 640, height: 360, times: [1.5, 3.0, 5.0], toDir: outDir)
        XCTAssertEqual(urls.count, 3)
        for u in urls {
            let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
            XCTAssertGreaterThan(size ?? 0, 100, "PNG too small: \(u.path)")
        }
        NSLog("%@", "[Waple] SP4 smoke PNGs: \(urls.map { $0.path })")
    }
}
