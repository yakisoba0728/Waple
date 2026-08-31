import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

/// SceneDocument에 보존된 CP 위치/각도 트랙이 GPU 시스템의 최초 sim과 캡처/seek용 fresh sim까지
/// 도달하는지 검증한다. 시뮬레이터 단위 테스트만으로는 buildParticles의 드롭을 잡을 수 없다.
final class ParticleInstanceOverrideAnimationRenderTests: XCTestCase {
    private func package() -> ScenePackage {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"particle":"particles/dot.json","origin":"50 50 0",
           "instanceoverride":{"controlpoint1":{
             "animation":{"c0":[{"frame":0,"value":0},{"frame":1,"value":10}],
                          "c1":[{"frame":0,"value":0},{"frame":1,"value":0}],
                          "c2":[{"frame":0,"value":0},{"frame":1,"value":0}],
                          "options":{"fps":1,"length":1,"mode":"single"}},
             "value":"0 0 0"},
           "controlpointangle1":{
             "animation":{"c0":[{"frame":0,"value":0},{"frame":1,"value":0}],
                          "c1":[{"frame":0,"value":0},{"frame":1,"value":0}],
                          "c2":[{"frame":0,"value":0},{"frame":1,"value":1.5707963}],
                          "options":{"fps":1,"length":1,"mode":"single"}},
             "value":"0 0 0"}}}]}
        """
        let particle = """
        {"flags":1,
         "controlpoint":[{"offset":"0 0 0"},{"offset":"0 0 0"}],
         "emitter":[{"name":"sphererandom","controlpoint":1,
                      "directions":"1 0 0","sign":"1 0 0",
                      "distancemin":2,"distancemax":2,
                      "speedmin":4,"speedmax":4,"rate":0,"instantaneous":1}],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10}],
         "renderer":[{"name":"sprite"}],"maxcount":1,
         "material":"materials/dot.json"}
        """
        let material = #"{"passes":[{"textures":["dot"]}]}"#
        return ScenePackage.assemble([
            (name: "scene.json", data: Data(scene.utf8)),
            (name: "particles/dot.json", data: Data(particle.utf8)),
            (name: "materials/dot.json", data: Data(material.utf8)),
            (name: "materials/dot.tex", data: solidTex(255, 255, 255)),
        ])
    }

    func testBuildParticlesPreservesControlPointAnimationsInInitialAndFreshSimulator() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let package = package()
        let doc = try SceneDocument.parse(package: package)
        let renderer = SceneRenderer()
        let systems = renderer.buildParticles(doc: doc, package: package, device: device)
        XCTAssertEqual(systems.count, 1)

        var initial = systems[0].sim
        let first = initial.step(1)[0]
        XCTAssertEqual(first.pos.x, 10, accuracy: 1e-5)
        XCTAssertEqual(first.pos.y, 6, accuracy: 1e-5)

        var fresh = systems[0].freshSimulator()
        let replay = fresh.step(1)[0]
        XCTAssertEqual(replay.pos.x, 10, accuracy: 1e-5)
        XCTAssertEqual(replay.pos.y, 6, accuracy: 1e-5)
    }
}
