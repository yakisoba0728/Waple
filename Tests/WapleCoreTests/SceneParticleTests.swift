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

    /// 3D 씬 파티클 오브젝트: 전-성분 origin/scale(z 포함)·parent·visible 을 SceneParticle 이 보존해야
    /// 3D 마운트가 원근 배치를 할 수 있다(2D 는 origin/scale Vec2 만 사용 — 무영향). 실물 3706286085
    /// SpeedLine(origin z=-58, 3D scale)·3737268876 torch(parent=1203) 구조를 축약.
    func testParticle3DTransformFieldsPreserved() {
        let scene = """
        {"general":{"fov":50.0},"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "objects":[
           {"id":1,"model":"models/x.mdl"},
           {"id":50,"name":"root","origin":"0 1 0"},
           {"id":2,"name":"speedline","particle":"particles/p.json","parent":50,
            "origin":"0 0 -58","scale":"0.01 0.01 0.025","angles":"0 0 0","visible":true}
         ]}
        """
        let particle = d(#"{"renderer":[{"name":"sprite"}],"maxcount":10,"material":"materials/p.json"}"#)
        let material = d(#"{"passes":[{"shader":"genericparticle","blending":"additive","textures":["particle/dot"]}]}"#)
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)), ("particles/p.json", particle), ("materials/p.json", material),
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.particles.count, 1)
        let p = doc.particles[0]
        XCTAssertEqual(p.origin3D, Vec3(x: 0, y: 0, z: -58), "3D origin z 보존 실패")
        XCTAssertEqual(p.scale3D, Vec3(x: 0.01, y: 0.01, z: 0.025), "3D scale z 보존 실패")
        XCTAssertEqual(p.parent, 50, "parent 노드 id 보존 실패")
        XCTAssertTrue(p.visible)
        // 2D 경로 필드는 종전대로 첫 2성분(무회귀).
        XCTAssertEqual(p.origin, Vec2(x: 0, y: 0))
        XCTAssertEqual(p.scale, Vec2(x: 0.01, y: 0.01))
    }
}
