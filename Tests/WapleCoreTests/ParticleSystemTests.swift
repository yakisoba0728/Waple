import XCTest
@testable import WapleCore

final class ParticleSystemTests: XCTestCase {
    private func json(_ s: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: s.data(using: .utf8)!) as! [String: Any]
    }

    // 실제 presets/snow/.../snowperspective.json 구조.
    private let snow = """
    {"emitter":[{"directions":"1 0.03 1","distancemax":1000,"distancemin":10,"name":"sphererandom","origin":"150 550 0","rate":25,"sign":"0 0 1"}],
     "initializer":[{"max":20,"min":8,"name":"lifetimerandom"},{"max":30,"min":2,"name":"sizerandom"},
       {"max":"-37 -90 0","min":"-10 -50 0","name":"velocityrandom"},{"max":"95 98 100","min":"255 255 255","name":"colorrandom"}],
     "operator":[{"gravity":"0 0 0","name":"movement"},{"frequencymax":1.0,"frequencymin":0.8,"mask":"1 0.5 0","name":"oscillateposition","phasemax":1,"phasemin":0,"scalemax":35,"scalemin":20},{"fadeintime":0.1,"name":"alphafade"}],
     "renderer":[{"name":"sprite"}],"maxcount":360,"starttime":15}
    """

    private let ember = """
    {"emitter":[{"distancemax":32,"name":"sphererandom","rate":1}],
     "initializer":[{"max":5,"min":3,"name":"lifetimerandom"},{"max":1000,"min":500,"name":"sizerandom"},
       {"max":"255 221 155","min":"255 196 175","name":"colorrandom"},
       {"exponent":2,"max":0.2,"min":0.1,"name":"alpharandom"},
       {"name":"turbulentvelocityrandom","offset":-0.1,"scale":0.3,"speedmax":50,"speedmin":0}],
     "operator":[{"gravity":"0 0 0","name":"movement"},{"fadeintime":0.5,"name":"alphafade"},
       {"name":"controlpointattract","controlpoint":1,"scale":-750,"threshold":64}],
     "renderer":[{"name":"sprite"}],"maxcount":500,"starttime":3}
    """

    func testParseSnow() {
        let d = ParticleSystemDef.parse(json(snow), material: nil)
        XCTAssertEqual(d.maxCount, 360)
        XCTAssertEqual(d.startTime, 15)
        XCTAssertEqual(d.renderer, .sprite)
        guard case let .sphere(_, dirs, dmin, dmax, rate, _, _) = d.emitters.first else { return XCTFail("no sphere") }
        XCTAssertEqual(rate, 25); XCTAssertEqual(dmin, 10); XCTAssertEqual(dmax, 1000)
        XCTAssertEqual(dirs, Vec3(x: 1, y: 0.03, z: 1))
        XCTAssertTrue(d.initializers.contains(.lifetimeRandom(min: 8, max: 20)))
        XCTAssertTrue(d.initializers.contains(.sizeRandom(min: 2, max: 30)))
        XCTAssertTrue(d.initializers.contains(.velocityRandom(min: Vec3(x: -10, y: -50, z: 0), max: Vec3(x: -37, y: -90, z: 0))))
        // movement / oscillateposition / alphafade 존재
        XCTAssertTrue(d.operators.contains(.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0)))
        XCTAssertTrue(d.operators.contains(.alphaFade(fadeInTime: 0.1, fadeOutTime: 0)))
        guard case let .oscillatePosition(fmin, fmax, smin, smax, _, _, mask)? = d.operators.first(where: {
            if case .oscillatePosition = $0 { return true }; return false
        }) else { return XCTFail("no oscillateposition") }
        XCTAssertEqual(fmin, 0.8); XCTAssertEqual(fmax, 1.0); XCTAssertEqual(smin, 20); XCTAssertEqual(smax, 35)
        XCTAssertEqual(mask, Vec3(x: 1, y: 0.5, z: 0))
    }

    func testParseEmber() {
        let d = ParticleSystemDef.parse(json(ember), material: nil)
        XCTAssertEqual(d.maxCount, 500)
        XCTAssertTrue(d.initializers.contains(.alphaRandom(min: 0.1, max: 0.2, exponent: 2)))
        XCTAssertTrue(d.initializers.contains(.turbulentVelocityRandom(speedMin: 0, speedMax: 50, scale: 0.3, offset: -0.1)))
        // movement/alphafade/controlpointattract 3종 모두 파싱.
        XCTAssertEqual(d.operators.count, 3)
        XCTAssertTrue(d.operators.contains(.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0)))
        XCTAssertTrue(d.operators.contains(.controlPointAttract(scale: -750, threshold: 64, target: Vec3(x: 0, y: 0, z: 0))))
    }

    // 실물 trail_1.json(rope) / wind-blur.json(spritetrail) / Shooting_Star(ropetrail) 스키마.
    func testParseTrailRenderers() {
        let rope = ParticleSystemDef.parse(json(#"{"renderer":[{"name":"rope","subdivision":0}],"maxcount":128}"#), material: nil)
        XCTAssertEqual(rope.renderer, .rope(subdivision: 0))
        XCTAssertTrue(rope.renderer.isTrail)
        XCTAssertEqual(rope.renderer.trailSampleCount, 16)

        let spriteTrail = ParticleSystemDef.parse(json(#"{"renderer":[{"name":"spritetrail","maxlength":20}],"maxcount":24}"#), material: nil)
        XCTAssertEqual(spriteTrail.renderer, .spriteTrail(maxLength: 20, length: 0))
        XCTAssertEqual(spriteTrail.renderer.trailSampleCount, 20)

        let ropeTrail = ParticleSystemDef.parse(json(#"{"renderer":[{"name":"ropetrail","length":0.4,"subdivision":2}],"maxcount":10}"#), material: nil)
        XCTAssertEqual(ropeTrail.renderer, .ropeTrail(length: 0.4, subdivision: 2))
        XCTAssertEqual(ropeTrail.renderer.trailSampleCount, 12)  // 0.4s × 30fps

        // maxlength 없는 spritetrail → 기본 8샘플. sprite 는 트레일 아님.
        let bare = ParticleSystemDef.parse(json(#"{"renderer":[{"name":"spritetrail"}],"maxcount":10}"#), material: nil)
        XCTAssertEqual(bare.renderer.trailSampleCount, 8)
        XCTAssertFalse(RendererKind.sprite.isTrail)
        XCTAssertEqual(RendererKind.sprite.trailSampleCount, 0)
    }

    func testParseVortex() {
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"name":"vortex","axis":"0 0 1","distanceinner":0,"distanceouter":50,"speedinner":300,"speedouter":0,"offset":"0 0 0"}],"renderer":[{"name":"sprite"}],"maxcount":10}"#), material: nil)
        XCTAssertTrue(d.operators.contains(.vortex(axis: Vec3(x: 0, y: 0, z: 1), distanceInner: 0, distanceOuter: 50,
                                                   speedInner: 300, speedOuter: 0, offset: Vec3(x: 0, y: 0, z: 0))))
    }

    func testParseTurbulence() {
        // 실물 ember 인스턴스(2905844074): mask/phasemax/scale/speedmin/speedmax.
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"id":9,"mask":"1 0 0","name":"turbulence","phasemax":5,"scale":0.002,"speedmax":150,"speedmin":100}],"renderer":[{"name":"sprite"}],"maxcount":40}"#), material: nil)
        XCTAssertTrue(d.operators.contains(.turbulence(speedMin: 100, speedMax: 150, scale: 0.002, timeScale: 0,
                                                       mask: Vec3(x: 1, y: 0, z: 0), phaseMin: 0, phaseMax: 5)))
    }

    func testParseTurbulenceDefaults() {
        // 최소 인스턴스({"name":"turbulence"}): speed 0(무동작), scale 0.01, timescale 0, mask (1,1,1).
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"id":8,"name":"turbulence"}],"renderer":[{"name":"sprite"}],"maxcount":10}"#), material: nil)
        XCTAssertTrue(d.operators.contains(.turbulence(speedMin: 0, speedMax: 0, scale: 0.01, timeScale: 0,
                                                       mask: Vec3(x: 1, y: 1, z: 1), phaseMin: 0, phaseMax: 0)))
    }

    func testBoxEmitter() {
        let d = ParticleSystemDef.parse(json("""
        {"emitter":[{"distancemax":"950 100 0","origin":"0 700 0","name":"boxrandom","rate":1}],
         "renderer":[{"name":"sprite"}],"maxcount":50}
        """), material: nil)
        guard case let .box(origin, dmax, rate, _) = d.emitters.first else { return XCTFail("no box") }
        XCTAssertEqual(origin, Vec3(x: 0, y: 700, z: 0))
        XCTAssertEqual(dmax, Vec3(x: 950, y: 100, z: 0))
        XCTAssertEqual(rate, 1)
    }

    func testMaterialBlend() {
        let add = ParticleMaterial.parse(json(#"{"passes":[{"blending":"additive","textures":["particle/snow"]}]}"#))
        XCTAssertEqual(add.blend, .additive); XCTAssertEqual(add.textureName, "particle/snow")
        let tr = ParticleMaterial.parse(json(#"{"passes":[{"blending":"translucent","textures":["particle/halo"]}]}"#))
        XCTAssertEqual(tr.blend, .translucent)
        let def = ParticleMaterial.parse(json("{}"))  // 없음 → translucent 기본
        XCTAssertEqual(def.blend, .translucent); XCTAssertNil(def.textureName)
    }

    func testUnsupportedRendererSurvives() {
        // rope 는 이제 지원 → 진짜 미지원(예: 존재하지 않는 렌더러)만 unsupported.
        let d = ParticleSystemDef.parse(json(#"{"renderer":[{"name":"bogusrenderer"}],"maxcount":10}"#), material: nil)
        XCTAssertEqual(d.renderer, .unsupported("bogusrenderer"))
    }
}
