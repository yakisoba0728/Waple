import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

final class SceneParticleRenderTests: XCTestCase {
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
            // [2026-08-26] 종전엔 `(try? … as? Int) ?? 0` 이었는데 그 `??` 는 좌변이 이미
            // 비옵셔널로 접혀 **우변이 죽은 자리**였다(경고만 나고 빌드는 섰다). 여기서는
            // 뒤의 `size ?? 0` 이 한 번 더 받아 단언이 정상 실패했으므로 무해했지만,
            // 같은 관용구가 `acab27c` 에서는 실제 회귀를 만들었다 — 복제되기 전에 지운다.
            let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
            let size = attrs?[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 100, "PNG too small: \(u.path)")
        }
        NSLog("%@", "[Waple] SP4 smoke PNGs: \(urls.map { $0.path })")
    }
}
