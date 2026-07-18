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

    func testRotationInitializersPreserveRadiansEndToEnd() throws {
        let twoPi = Float.pi * 2
        let pi = Float.pi
        let source = """
        {"emitter":[{"name":"boxrandom","origin":"0 0 0","distancemax":"0 0 0","instantaneous":1}],
         "initializer":[
           {"name":"lifetimerandom","min":10,"max":10},
           {"name":"rotationrandom","min":"\(twoPi) 0 0","max":"\(twoPi) 0 0"},
           {"name":"angularvelocityrandom","min":"\(pi) 0 0","max":"\(pi) 0 0"}],
         "renderer":[{"name":"sprite"}],"maxcount":1}
        """
        let def = ParticleSystemDef.parse(json(source), material: nil)
        var simulator = ParticleSimulator(def: def, seed: 7)

        let particle = try XCTUnwrap(simulator.step(0).first)

        XCTAssertEqual(particle.rotation.x, twoPi, accuracy: 1e-6)
        XCTAssertEqual(particle.angularVel.x, pi, accuracy: 1e-6)
    }

    func testChangeOperatorsParseExplicitIntervals() {
        let def = ParticleSystemDef.parse([
            "operator": [
                ["name": "sizechange", "starttime": 0.2, "endtime": 0.6,
                 "startvalue": 0.4, "endvalue": 0.8],
                ["name": "colorchange", "starttime": 0.25, "endtime": 0.75,
                 "startvalue": "1 0.5 0.25", "endvalue": "0.2 1 0.75"],
                ["name": "alphachange", "starttime": 0.1, "endtime": 0.9,
                 "startvalue": 0.8, "endvalue": 0.3],
            ],
        ], material: nil)

        XCTAssertEqual(def.operators, [
            .sizeChange(startTime: 0.2, startValue: 0.4, endValue: 0.8, endTime: 0.6),
            .colorChange(startTime: 0.25,
                         startValue: Vec3(x: 1, y: 0.5, z: 0.25),
                         endValue: Vec3(x: 0.2, y: 1, z: 0.75),
                         endTime: 0.75),
            .alphaChange(startTime: 0.1, endTime: 0.9, startValue: 0.8, endValue: 0.3),
        ])
    }

    func testChangeOperatorsUseNativeDefaults() {
        let def = ParticleSystemDef.parse([
            "operator": [
                ["name": "sizechange"],
                ["name": "colorchange"],
                ["name": "alphachange"],
            ],
        ], material: nil)

        XCTAssertEqual(def.operators, [
            .sizeChange(startTime: 0, startValue: 1, endValue: 0, endTime: 1),
            .colorChange(startTime: 0,
                         startValue: Vec3(x: 1, y: 1, z: 1),
                         endValue: Vec3(x: 0, y: 0, z: 0),
                         endTime: 1),
            .alphaChange(startTime: 0, endTime: 1, startValue: 1, endValue: 0),
        ])
    }

    private func randomInitializerParticle(exponent: Float?) throws -> Particle {
        let exp = exponent.map { ",\"exponent\":\($0)" } ?? ""
        let source = """
        {"emitter":[{"name":"boxrandom","origin":"0 0 0","distancemax":"0 0 0","instantaneous":1}],
         "initializer":[
           {"name":"lifetimerandom","min":1,"max":2\(exp)},
           {"name":"sizerandom","min":0,"max":1\(exp)},
           {"name":"colorrandom","min":"0 0 0","max":"255 255 255"\(exp)},
           {"name":"alpharandom","min":0,"max":1\(exp)},
           {"name":"velocityrandom","min":"0 0 0","max":"1 1 1"\(exp)},
           {"name":"rotationrandom","min":"0 0 0","max":"1 1 1"\(exp)},
           {"name":"angularvelocityrandom","min":"0 0 0","max":"1 1 1"\(exp)}],
         "renderer":[{"name":"sprite"}],"maxcount":1}
        """
        let def = ParticleSystemDef.parse(json(source), material: nil)
        var simulator = ParticleSimulator(def: def, seed: 7)
        return try XCTUnwrap(simulator.step(0).first)
    }

    func testRandomInitializerExponentDefaultsToLinearSampling() throws {
        let p = try randomInitializerParticle(exponent: nil)

        XCTAssertEqual(p.lifetime, 1.5829303, accuracy: 1e-6)
        XCTAssertEqual(p.size, 0.45244187, accuracy: 1e-6)
        XCTAssertEqual(p.color.x, 0.24943149, accuracy: 1e-6)
        XCTAssertEqual(p.color.y, 0.24943149, accuracy: 1e-6)
        XCTAssertEqual(p.color.z, 0.24943149, accuracy: 1e-6)
        XCTAssertEqual(p.alpha, 0.46795297, accuracy: 1e-6)
        XCTAssertEqual(p.vel.x, 0.32807672, accuracy: 1e-6)
        XCTAssertEqual(p.vel.y, 0.13425827, accuracy: 1e-6)
        XCTAssertEqual(p.vel.z, 0.41314137, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.x, 0.10355991, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.y, 0.95987403, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.z, 0.91801953, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.x, 0.87133175, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.y, 0.86400765, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.z, 0.54828739, accuracy: 1e-6)
    }

    func testRandomInitializerExponentCurvesSeededSamplingAndPreservesAlpha() throws {
        let p = try randomInitializerParticle(exponent: 2)

        XCTAssertEqual(p.lifetime, 1.3398077, accuracy: 1e-6)
        XCTAssertEqual(p.size, 0.20470364, accuracy: 1e-6)
        XCTAssertEqual(p.color.x, 0.06221607, accuracy: 1e-6)
        XCTAssertEqual(p.color.y, 0.06221607, accuracy: 1e-6)
        XCTAssertEqual(p.color.z, 0.06221607, accuracy: 1e-6)
        XCTAssertEqual(p.alpha, 0.21897998, accuracy: 1e-6)
        XCTAssertEqual(p.vel.x, 0.10763434, accuracy: 1e-6)
        XCTAssertEqual(p.vel.y, 0.01802528, accuracy: 1e-6)
        XCTAssertEqual(p.vel.z, 0.17068580, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.x, 0.01072466, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.y, 0.92135817, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.z, 0.84275985, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.x, 0.75921905, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.y, 0.74650919, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.z, 0.30061907, accuracy: 1e-6)
    }

    func testRandomInitializerExponentRejectsNonnumericAndNonfiniteValues() {
        // JSONSerialization의 false는 __NSCFBoolean이며 `as? Double`로도 0.0에 브리지된다.
        let bridgedFalse = json(#"{"value":false}"#)["value"]!
        let invalidExponents: [Any] = [bridgedFalse, "2", Double.nan, Double.infinity]
        let expected: [Initializer] = [
            .lifetimeRandom(min: 1, max: 2, exponent: 1),
            .sizeRandom(min: 0, max: 1, exponent: 1),
            .colorRandom(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 255, y: 255, z: 255), exponent: 1),
            .alphaRandom(min: 0, max: 1, exponent: 1),
            .velocityRandom(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 1, y: 1, z: 1), exponent: 1),
            .rotationRandom(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 1, y: 1, z: 1), exponent: 1),
            .angularVelocityRandom(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 1, y: 1, z: 1), exponent: 1),
        ]

        for invalid in invalidExponents {
            let initializers: [[String: Any]] = [
                ["name": "lifetimerandom", "min": 1, "max": 2, "exponent": invalid],
                ["name": "sizerandom", "min": 0, "max": 1, "exponent": invalid],
                ["name": "colorrandom", "min": "0 0 0", "max": "255 255 255", "exponent": invalid],
                ["name": "alpharandom", "min": 0, "max": 1, "exponent": invalid],
                ["name": "velocityrandom", "min": "0 0 0", "max": "1 1 1", "exponent": invalid],
                ["name": "rotationrandom", "min": "0 0 0", "max": "1 1 1", "exponent": invalid],
                ["name": "angularvelocityrandom", "min": "0 0 0", "max": "1 1 1", "exponent": invalid],
            ]
            let def = ParticleSystemDef.parse(["initializer": initializers], material: nil)

            XCTAssertEqual(def.initializers, expected, "invalid exponent: \(invalid)")
        }
    }

    func testFixedWidthRandomInitializerStillConsumesItsDraw() throws {
        let source = """
        {"emitter":[{"name":"boxrandom","origin":"0 0 0","distancemax":"0 0 0","instantaneous":1}],
         "initializer":[
           {"name":"lifetimerandom","min":5,"max":5,"exponent":2},
           {"name":"sizerandom","min":0,"max":1,"exponent":2}],
         "renderer":[{"name":"sprite"}],"maxcount":1}
        """
        let def = ParticleSystemDef.parse(json(source), material: nil)
        var simulator = ParticleSimulator(def: def, seed: 7)
        let p = try XCTUnwrap(simulator.step(0).first)

        XCTAssertEqual(p.lifetime, 5, accuracy: 1e-6)
        XCTAssertEqual(p.size, 0.20470364, accuracy: 1e-6)
    }

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

    func testHugeNumericParticleValuesDefaultInsteadOfTrapping() {
        let d = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"sphererandom","instantaneous":1e300,"rate":1e300}],
         "renderer":[{"name":"rope","subdivision":1e300}],
         "maxcount":1e300,"starttime":1e300}
        """), material: nil)
        XCTAssertEqual(d.maxCount, 100)
        XCTAssertEqual(d.startTime, 0)
        guard case let .sphere(_, _, _, _, rate, burst, _) = d.emitters.first else {
            return XCTFail("no sphere")
        }
        XCTAssertEqual(rate, 0)
        XCTAssertEqual(burst, 0)
        XCTAssertEqual(d.renderer, .rope(subdivision: 0))
    }

    func testNegativeMaxCountClampsAndBurstStepNoTrap() {
        // 감사 V02: 음수 maxcount 가 버스트 스폰 Range 상한(0..<음수)으로 흘러 트랩하던 회귀.
        let d = ParticleSystemDef.parse(json(
            #"{"emitter":[{"name":"sphererandom","instantaneous":10}],"renderer":[{"name":"sprite"}],"maxcount":-1}"#),
            material: nil)
        XCTAssertEqual(d.maxCount, 0)
        var sim = ParticleSimulator(def: d, seed: 7)
        XCTAssertTrue(sim.step(0.1).isEmpty)  // 완주 자체가 무트랩 증명
    }

    func testOscillateFrequencyMaxDefaultsToFrequencyMin() {
        // 감사 V03: fmax 부재 시 0 대신 fmin 승계(scaleMax 패턴과 일치) — 역범위 랜덤 방지. 3종 모두.
        let d = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"oscillatesize","frequencymin":2.5},
                     {"name":"oscillatealpha","frequencymin":1.5},
                     {"name":"oscillateposition","frequencymin":3.5}],"maxcount":10}
        """), material: nil)
        guard case let .oscillateSize(sf0, sf1, _, _, _, _) = d.operators[0] else { return XCTFail("no oscillatesize") }
        XCTAssertEqual(sf0, 2.5); XCTAssertEqual(sf1, 2.5)
        guard case let .oscillateAlpha(af0, af1, _, _, _, _) = d.operators[1] else { return XCTFail("no oscillatealpha") }
        XCTAssertEqual(af0, 1.5); XCTAssertEqual(af1, 1.5)
        guard case let .oscillatePosition(pf0, pf1, _, _, _, _, _) = d.operators[2] else { return XCTFail("no oscillateposition") }
        XCTAssertEqual(pf0, 3.5); XCTAssertEqual(pf1, 3.5)
    }

    // F189/F190: scalemax 기본이 scalemin 승계(구현)가 아니라 1(비퇴화)이어야 — scale 전체 생략(데모
    // 시나리오)과 scalemin 단독 지정(코퍼스 다수: 0.2×9·0.3×4·0.1×4 등) 양쪽 모두 진폭이 죽지 않아야 한다.
    func testOscillateAlphaScaleMaxDefaultsToOneNotScaleMin() {
        let allOmitted = ParticleSystemDef.parse(json(#"{"operator":[{"name":"oscillatealpha","frequencymin":2}]}"#), material: nil)
        guard case let .oscillateAlpha(_, _, smin0, smax0, _, _) = allOmitted.operators[0] else { return XCTFail("no oscillatealpha") }
        XCTAssertEqual(smin0, 0); XCTAssertEqual(smax0, 1, "scale 생략 시 scalemax 는 scalemin(0) 이 아니라 1")

        let scaleMinOnly = ParticleSystemDef.parse(json(#"{"operator":[{"name":"oscillatealpha","scalemin":0.2}]}"#), material: nil)
        guard case let .oscillateAlpha(_, _, smin1, smax1, _, _) = scaleMinOnly.operators[0] else { return XCTFail("no oscillatealpha") }
        XCTAssertEqual(smin1, 0.2); XCTAssertEqual(smax1, 1, "scalemin 단독 지정 시 scalemax 승계(상수화) 대신 1")
    }

    // F184: phasemin/phasemax 가 파티클별 위상 range 로 파스돼야(fireworks 5씬 근동기 의도 복원 —
    // 종전엔 이 키 자체를 읽지 않아 항상 완전 랜덤 위상이었다). 기본은 자매 오퍼레이터와 동형으로 0.
    func testOscillateAlphaParsesPhaseRange() {
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"name":"oscillatealpha","frequencymin":1.5,"phasemin":0,"phasemax":0.1}]}"#), material: nil)
        guard case let .oscillateAlpha(_, _, _, _, pmin, pmax) = d.operators[0] else { return XCTFail("no oscillatealpha") }
        XCTAssertEqual(pmin, 0); XCTAssertEqual(pmax, 0.1)
    }

    func testOscillateAlphaPhaseDefaultsToZero() {
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"name":"oscillatealpha","frequencymin":1.5}]}"#), material: nil)
        guard case let .oscillateAlpha(_, _, _, _, pmin, pmax) = d.operators[0] else { return XCTFail("no oscillatealpha") }
        XCTAssertEqual(pmin, 0); XCTAssertEqual(pmax, 0)
    }

    func testControlPointAttractConsumesControlPointId() {
        // 감사 V04: controlpoint 키(CP id)가 controlpoint 배열의 offset 을 target 으로 소비.
        let d = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"controlpointattract","controlpoint":1,"scale":-750,"threshold":64}],
         "controlpoint":[{"id":1,"offset":"100 200 0"}],"maxcount":10}
        """), material: nil)
        XCTAssertTrue(d.operators.contains(
            .controlPointAttract(scale: -750, threshold: 64, target: Vec3(x: 100, y: 200, z: 0))))
    }

    // REFRACT 스크린 굴절 머티리얼 파싱(실측 refractiverain.json 구조): combos.REFRACT + textures[1] 노멀 +
    // constantshadervalues.ui_editor_properties_refract_amount. 노멀 유무가 굴절 경로 게이트.
    func testRefractMaterialParse() {
        let m = ParticleMaterial.parse(json("""
        {"passes":[{"blending":"translucent","combos":{"REFRACT":1},
          "constantshadervalues":{"ui_editor_properties_refract_amount":0.1},
          "shader":"genericparticle","textures":["particle/drop","particle/drop_normal"]}]}
        """))
        XCTAssertTrue(m.refract)
        XCTAssertEqual(m.textureName, "particle/drop")
        XCTAssertEqual(m.normalTextureName, "particle/drop_normal")
        XCTAssertEqual(m.refractAmount, 0.1, accuracy: 1e-6)
        XCTAssertEqual(m.blend, .translucent)
    }

    // 음수 refract_amount(rain_screen.json = -0.1)도 그대로 보존(반전 굴절).
    func testRefractNegativeAmount() {
        let m = ParticleMaterial.parse(json("""
        {"passes":[{"blending":"translucent","combos":{"CUTOUT":0,"REFRACT":1},
          "constantshadervalues":{"ui_editor_properties_refract_amount":-0.1},
          "textures":["a/sheet","a/sheet_normal"]}]}
        """))
        XCTAssertTrue(m.refract)
        XCTAssertEqual(m.refractAmount, -0.1, accuracy: 1e-6)
    }

    // 비굴절 머티리얼: refract=false, 노멀 nil, refract_amount 기본 0.05. + REFRACT 콤보라도 노멀 없으면 게이트 off.
    func testNonRefractAndRefractWithoutNormal() {
        let plain = ParticleMaterial.parse(json(#"{"passes":[{"blending":"additive","textures":["particle/snow"]}]}"#))
        XCTAssertFalse(plain.refract)
        XCTAssertNil(plain.normalTextureName)
        XCTAssertEqual(plain.refractAmount, 0.05, accuracy: 1e-6)
        XCTAssertEqual(plain.blend, .additive)

        // REFRACT=1 이지만 textures[1] 부재 → normalTextureName nil → refract 게이트 off(굴절 셰이더는 노멀 필수).
        let noNormal = ParticleMaterial.parse(json(#"{"passes":[{"combos":{"REFRACT":1},"textures":["only/albedo"]}]}"#))
        XCTAssertFalse(noNormal.refract)
        XCTAssertNil(noNormal.normalTextureName)
    }
}
