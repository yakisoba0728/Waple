import XCTest
@testable import WapleCore

final class SceneParticleTests: XCTestCase {
    private func d(_ s: String) -> Data { s.data(using: .utf8)! }

    func testSceneSurfacesParticleObject() {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[
           {"id":1,"name":"snow","particle":"particles/snow.json","origin":"128 128 0","scale":"0.5 0.5 0.5"}
         ]}
        """
        let particle = """
        {"emitter":[{"name":"sphererandom","distancemax":1000,"rate":25,"origin":"150 550 0"}],
         "initializer":[{"name":"sizerandom","min":2,"max":30},{"name":"velocityrandom","min":"-10 -50 0","max":"-37 -90 0"}],
         "operator":[{"name":"movement","gravity":"0 0 0"},{"name":"alphafade","fadeintime":0.1}],
         "renderer":[{"name":"sprite"}],"maxcount":360,"starttime":15,
         "material":"materials/snow.json"}
        """
        let material = #"{"passes":[{"shader":"genericparticle","blending":"additive","textures":["particle/snow"]}]}"#
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("particles/snow.json", d(particle)),
            ("materials/snow.json", d(material)),
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.layers.count, 0)
        XCTAssertEqual(doc.particles.count, 1)
        let p = doc.particles[0]
        XCTAssertEqual(p.origin, Vec2(x: 128, y: 128))
        XCTAssertEqual(p.scale, Vec2(x: 0.5, y: 0.5))
        XCTAssertEqual(p.def.maxCount, 360)
        XCTAssertEqual(p.def.material?.blend, .additive)
        XCTAssertEqual(p.def.material?.textureName, "particle/snow")
        XCTAssertEqual(p.def.renderer, .sprite)
    }

    func testInvisibleParticleSkipped() {
        let scene = """
        {"objects":[{"id":1,"particle":"particles/x.json","visible":false}]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("particles/x.json", d(#"{"renderer":[{"name":"sprite"}],"maxcount":1}"#)),
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.particles.count, 0)
    }

    func testMissingParticleFileDropped() {
        let scene = #"{"objects":[{"id":1,"particle":"particles/missing.json"}]}"#
        let pkg = ScenePackage.assemble([("scene.json", d(scene))])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.particles.count, 0)  // 로드 실패 → 드롭(무크래시)
    }
}
