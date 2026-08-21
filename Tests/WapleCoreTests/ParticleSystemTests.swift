import XCTest
@testable import WapleCore

final class ParticleSystemTests: XCTestCase {

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
        {"emitter":[{"name":"boxrandom","rate":0,"origin":"0 0 0","distancemax":"0 0 0","instantaneous":1}],
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
        {"emitter":[{"name":"boxrandom","rate":0,"origin":"0 0 0","distancemax":"0 0 0","instantaneous":1}],
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

        // [2026-08-21] 스폰 VM **서두의 무조건 1드로**(0x14023b372)를 이식하면서 시퀀스가 한 칸씩
        // 밀렸다. 아래 숫자는 그 자리를 반영해 다시 뽑은 것이고, 이 테스트가 지키려던 성질
        // (지수 곡선이 시드 샘플을 실제로 굽히고 alpha 를 보존한다 / 고정폭 range 도 드로를 소비한다)
        // 는 그대로다 — 값들은 Waple 의 SplitMix64 시퀀스 핀이지 WE 실측이 아니다
        // (WE 는 MT19937 + 벽시계 시드라 실행 간 재현되지 않는다).
        XCTAssertEqual(p.lifetime, 1.4524419, accuracy: 1e-6)
        XCTAssertEqual(p.size, 0.24943149, accuracy: 1e-6)
        XCTAssertEqual(p.color.x, 0.46795297, accuracy: 1e-6)
        XCTAssertEqual(p.color.y, 0.46795297, accuracy: 1e-6)
        XCTAssertEqual(p.color.z, 0.46795297, accuracy: 1e-6)
        XCTAssertEqual(p.alpha, 0.32807672, accuracy: 1e-6)
        XCTAssertEqual(p.vel.x, 0.13425827, accuracy: 1e-6)
        XCTAssertEqual(p.vel.y, 0.41314137, accuracy: 1e-6)
        XCTAssertEqual(p.vel.z, 0.10355991, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.x, 0.95987403, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.y, 0.91801953, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.z, 0.87133175, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.x, 0.86400765, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.y, 0.5482874, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.z, 0.8796137, accuracy: 1e-6)
    }

    func testRandomInitializerExponentCurvesSeededSamplingAndPreservesAlpha() throws {
        let p = try randomInitializerParticle(exponent: 2)

        // [2026-08-21] 스폰 VM **서두의 무조건 1드로**(0x14023b372)를 이식하면서 시퀀스가 한 칸씩
        // 밀렸다. 아래 숫자는 그 자리를 반영해 다시 뽑은 것이고, 이 테스트가 지키려던 성질
        // (지수 곡선이 시드 샘플을 실제로 굽히고 alpha 를 보존한다 / 고정폭 range 도 드로를 소비한다)
        // 는 그대로다 — 값들은 Waple 의 SplitMix64 시퀀스 핀이지 WE 실측이 아니다
        // (WE 는 MT19937 + 벽시계 시드라 실행 간 재현되지 않는다).
        XCTAssertEqual(p.lifetime, 1.2047037, accuracy: 1e-6)
        XCTAssertEqual(p.size, 0.06221607, accuracy: 1e-6)
        XCTAssertEqual(p.color.x, 0.21897998, accuracy: 1e-6)
        XCTAssertEqual(p.color.y, 0.21897998, accuracy: 1e-6)
        XCTAssertEqual(p.color.z, 0.21897998, accuracy: 1e-6)
        XCTAssertEqual(p.alpha, 0.107634336, accuracy: 1e-6)
        XCTAssertEqual(p.vel.x, 0.018025283, accuracy: 1e-6)
        XCTAssertEqual(p.vel.y, 0.1706858, accuracy: 1e-6)
        XCTAssertEqual(p.vel.z, 0.010724655, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.x, 0.92135817, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.y, 0.84275985, accuracy: 1e-6)
        XCTAssertEqual(p.rotation.z, 0.75921905, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.x, 0.7465092, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.y, 0.30061907, accuracy: 1e-6)
        XCTAssertEqual(p.angularVel.z, 0.77372026, accuracy: 1e-6)
    }

    /// **[2026-08-21 정정] 불리언은 여기서 "무효" 가 아니다.**
    ///
    /// 종전 이 테스트는 `bridgedFalse` 를 무효 목록에 넣어 exponent 1(부재 기본)을 기대했다.
    /// 그 전제는 바이너리로 확인된 적이 없었고, 확인해 보니 **틀렸다** — 초기화자 일곱의
    /// `exponent` 리더는 전부 `operator[]`(`0x140087640`) 직후 `mov rcx,rax; call asFloat`
    /// (`0x1401c720f`·`0x1401c73e6`·`0x1401c7798`·`0x1401c8011`·`0x1401c82df`·`0x1401c901b`·
    /// `0x1401c967f`)이고 앞에 `isNumeric`(`0x140088880`) 호출이 **없다**.
    /// 게이트가 없으면 `asFloat` 가 태그 5 를 1.0/0.0 으로 내므로 `false` → **0.0** 이다.
    /// 문자열(태그 4)·비유한은 그대로 무효다(실물은 태그 4 에서 abort — Waple 은 기본값으로 접는다).
    /// 자세한 전수는 `docs/re/json-number-tags.md`.
    func testRandomInitializerExponentRejectsNonnumericAndNonfiniteValues() {
        let invalidExponents: [Any] = ["2", Double.nan, Double.infinity]
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

        // JSONSerialization 의 false 는 `__NSCFBoolean` 이라 `as? Double` 이 **0.0 으로 성공**한다.
        // 게이트가 없는 자리이므로 그 0.0 이 실물과 같은 값이다 — 부재 기본 1 로 접으면 안 된다.
        let bridgedFalse = json(#"{"value":false}"#)["value"]!
        let bridgedTrue = json(#"{"value":true}"#)["value"]!
        for (raw, want) in [(bridgedFalse, Float(0)), (bridgedTrue, Float(1))] {
            let def = ParticleSystemDef.parse(
                ["initializer": [["name": "sizerandom", "min": 0, "max": 1, "exponent": raw]]],
                material: nil)
            XCTAssertEqual(def.initializers, [.sizeRandom(min: 0, max: 1, exponent: want)],
                           "asFloat 태그 5 → 1.0/0.0 (0x140086243–0x140086248)")
        }
    }

    func testFixedWidthRandomInitializerStillConsumesItsDraw() throws {
        let source = """
        {"emitter":[{"name":"boxrandom","rate":0,"origin":"0 0 0","distancemax":"0 0 0","instantaneous":1}],
         "initializer":[
           {"name":"lifetimerandom","min":5,"max":5,"exponent":2},
           {"name":"sizerandom","min":0,"max":1,"exponent":2}],
         "renderer":[{"name":"sprite"}],"maxcount":1}
        """
        let def = ParticleSystemDef.parse(json(source), material: nil)
        var simulator = ParticleSimulator(def: def, seed: 7)
        let p = try XCTUnwrap(simulator.step(0).first)

        // [2026-08-21] 스폰 VM 서두 드로(0x14023b372) 이식으로 한 칸 밀렸다. 이 테스트의 요점은
        // "min==max 인 range 도 드로를 소비한다" 이고, 그 성질은 그대로다.
        XCTAssertEqual(p.lifetime, 5, accuracy: 1e-6)
        XCTAssertEqual(p.size, 0.06221607, accuracy: 1e-6)
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
        // [2026-08-20] fadeouttime 부재 기본값이 0 → **0.5** 로 바뀌었다(원본 주입기 0x1401bce50).
        XCTAssertTrue(d.operators.contains(.alphaFade(fadeInTime: 0.1, fadeOutTime: 0.5)))
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

        // `length` 부재는 0 이 아니라 주입 0.05 다(0x1401c0b55).
        let spriteTrail = ParticleSystemDef.parse(json(#"{"renderer":[{"name":"spritetrail","maxlength":20}],"maxcount":24}"#), material: nil)
        XCTAssertEqual(spriteTrail.renderer, .spriteTrail(maxLength: 20, length: 0.05, minLength: 0))
        XCTAssertEqual(spriteTrail.renderer.trailSampleCount, 20)

        let ropeTrail = ParticleSystemDef.parse(json(#"{"renderer":[{"name":"ropetrail","length":0.4,"subdivision":2}],"maxcount":10}"#), material: nil)
        XCTAssertEqual(ropeTrail.renderer, .ropeTrail(length: 0.4, subdivision: 2))
        XCTAssertEqual(ropeTrail.renderer.trailSampleCount, 12)  // 0.4s × 30fps

        // maxlength 부재는 0 이 아니라 주입 **10.0**(0x1401c0c13) 이므로 샘플도 10 이다 —
        // 종전의 `?? 8` 폴백은 maxLength ≤ 0 일 때만 서는데, 그 상태가 이제 안 나온다.
        let bare = ParticleSystemDef.parse(json(#"{"renderer":[{"name":"spritetrail"}],"maxcount":10}"#), material: nil)
        XCTAssertEqual(bare.renderer.trailSampleCount, 10)
        XCTAssertFalse(RendererKind.sprite.isTrail)
        XCTAssertEqual(RendererKind.sprite.trailSampleCount, 0)
    }

    /// C4-(iii): REFRACT 디스패치가 소비하는 isRopeTrail — spriteTrail 은 sprite 와 동형 쿼드 지오메트리라
    /// REFRACT 정접 대상(false), rope/ropeTrail(히스토리 리본)만 배제(true). isTrail(위 테스트)과 대조적으로
    /// spriteTrail 에서 갈린다.
    func testIsRopeTrailExcludesOnlyHistoryRibbonRenderers() {
        XCTAssertFalse(RendererKind.sprite.isRopeTrail)
        XCTAssertFalse(RendererKind.spriteTrail(maxLength: 20, length: 0, minLength: 0).isRopeTrail)
        XCTAssertTrue(RendererKind.rope(subdivision: 0).isRopeTrail)
        XCTAssertTrue(RendererKind.ropeTrail(length: 0.4, subdivision: 2).isRopeTrail)
    }

    /// **[2026-08-20] 세 번째이자 마지막 정정 — 이번엔 실측이다.**
    ///
    /// 이 값은 두 번 뒤집혔다. C4-(i) 가 1 → 0 으로 바꿨고(bokeh 백화 원인으로 지목), W2-① 이
    /// 0 → 1 로 되돌렸다("같은 스위치의 관례상 부재 기본값은 중립값"). 둘 다 **자산에서 유추**한
    /// 것이고 둘 다 틀렸다. 원본은 원소 팩토리 직전에 기본값 주입기를 돌리는데
    /// (`if (!json.find(k)) json[k] = C;`), `alpharandom` 주입기 0x1401baa10 이
    /// min = **0.05**(0x1401baa70) · max = 1.0(0x1401baaec) 를 심는다.
    ///
    /// 상수는 코드에만 있고 자산에는 절대 나타나지 않는다 — 그래서 자산 통계로는 원리적으로
    /// 복원할 수 없었고, 두 번의 유추가 모두 빗나간 것이다.
    ///
    /// W2-① 이 든 반증들은 여전히 유효하되 이 값과 무관하다: `wind-blur.json {"min":0.8}` 은
    /// min 이 명시돼 있고, 양쪽 부재는 동봉 34건 중 **1건**뿐이다. 그 1건이 [1,1] 고정에서
    /// [0.05,1] 범위로 바뀐다.
    func testAlphaRandomMissingMinMaxUsesInjectorConstants() {
        let d = ParticleSystemDef.parse(json(#"{"initializer":[{"name":"alpharandom"}]}"#), material: nil)
        XCTAssertTrue(d.initializers.contains(.alphaRandom(min: 0.05, max: 1, exponent: 1)),
                      "주입기 0x1401baa10 — 유추한 1,1 도 0,0 도 아니다")
    }

    /// 기본값 변경이 "알파만" 바꾸고 그 뒤를 잇는 다른 랜덤 이니셜라이저의 RNG 시퀀스는
    /// 건드리지 않는지 확인한다. 부재든 명시든 alpharandom 은 **드로우를 한 번 소비**하므로
    /// (스킵이 아니다) 이후 velocityrandom 결과가 두 케이스에서 같아야 하고, 그래야 "값만"
    /// 바뀐 표적 수정임이 증명된다 — RNG 캐스케이드가 있었다면 이후 값이 갈렸을 것이다.
    /// [2026-08-20] 대조군을 새 주입기 상수(0.05, 1)로 맞췄다. 종전 (1,1) 은 고정폭이라
    /// "드로우를 소비하는가" 를 증명하지 못했다 — 값이 같아 range 호출이 생략돼도 통과했다.
    func testAlphaRandomDefaultChangeDoesNotShiftDownstreamRNG() throws {
        func lastVelocity(alphaJSON: String) throws -> SIMD3<Float> {
            let source = """
            {"emitter":[{"name":"boxrandom","rate":0,"origin":"0 0 0","distancemax":"0 0 0","instantaneous":1}],
             "initializer":[\(alphaJSON)
               {"name":"velocityrandom","min":"0 0 0","max":"1 1 1"}],
             "renderer":[{"name":"sprite"}],"maxcount":1}
            """
            let def = ParticleSystemDef.parse(json(source), material: nil)
            var simulator = ParticleSimulator(def: def, seed: 7)
            return try XCTUnwrap(simulator.step(0).first).vel
        }
        let omitted = try lastVelocity(alphaJSON: #"{"name":"alpharandom"},"#)
        let explicitDefault = try lastVelocity(alphaJSON: #"{"name":"alpharandom","min":0.05,"max":1},"#)
        XCTAssertEqual(omitted.x, explicitDefault.x, accuracy: 1e-6)
        XCTAssertEqual(omitted.y, explicitDefault.y, accuracy: 1e-6)
        XCTAssertEqual(omitted.z, explicitDefault.z, accuracy: 1e-6)
    }

    /// S5④: hsvcolorrandom 전 필드 명시(실물 particleelementpreviews/hsvcolorrandom 예제) 파스.
    func testHSVColorRandomParsesExplicitFields() {
        let d = ParticleSystemDef.parse(json(
            #"{"initializer":[{"name":"hsvcolorrandom","huemin":0,"huemax":1,"saturationmin":1,"saturationmax":1,"valuemin":1,"valuemax":1}]}"#
        ), material: nil)
        XCTAssertTrue(d.initializers.contains(.hsvColorRandom(hueMin: 0, hueMax: 1, satMin: 1, satMax: 1, valMin: 1, valMax: 1, hueSteps: 6)))
    }

    /// magic_color_sparkle 실물: saturationmin/valuemin 만 있고 max 부재 → max=min(고정폭) 채택.
    /// **[2026-08-20] 개명·재조준. 이 테스트는 통과하고 있었지만 계약이 거짓이었다.**
    /// 종전 픽스처가 `saturationmin:1, valuemin:1` 이라 주입 상수 1.0 과 값이 **우연히 일치**해,
    /// "max 는 min 을 승계한다" 는 틀린 규칙이 통과했다. min 을 1 이 아닌 값으로 바꾸면 갈린다 —
    /// 승계면 0.2/0.3, 상수면 1.0/1.0 이다. 원본은 후자다(주입기 0x1401ba3e0).
    func testHSVColorRandomMaxDoesNotInheritMin() {
        let d = ParticleSystemDef.parse(json(
            #"{"initializer":[{"name":"hsvcolorrandom","huemin":0.49150327,"huemax":0.93267971,"saturationmin":0.2,"valuemin":0.3}]}"#
        ), material: nil)
        XCTAssertTrue(d.initializers.contains(.hsvColorRandom(hueMin: 0.49150327, hueMax: 0.93267971,
                                                              satMin: 0.2, satMax: 1, valMin: 0.3, valMax: 1, hueSteps: 6)),
                      "승계였다면 satMax 0.2 · valMax 0.3 — 실제 파스: \(d.initializers)")
    }

    /// **[2026-08-20 정정] "데모 예제 = 기본값" 전제가 반증됐다.**
    /// 채택. 종전엔 case 미인식으로 initializer 자체가 통째 drop 됐다(무색 랜덤 = 백색 고정).
    /// 주입기 0x1401ba3e0(게이트 stricmp 0x1401c783a)이 `saturationmin`/`valuemin` 에 **0.5** 를,
    /// `saturationmax`/`valuemax` 에 1.0 을 심는다. 데모 예제가 s/v=1 을 **명시**하고 있었을 뿐이다.
    func testHSVColorRandomAllFieldsMissingUsesInjectorDefaults() {
        let d = ParticleSystemDef.parse(json(#"{"initializer":[{"name":"hsvcolorrandom"}]}"#), material: nil)
        XCTAssertTrue(d.initializers.contains(.hsvColorRandom(hueMin: 0, hueMax: 1, satMin: 0.5, satMax: 1,
                                                              valMin: 0.5, valMax: 1, hueSteps: 6)),
                      "주입기 0x1401ba3e0 — 실제 파스: \(d.initializers)")
    }

    // F188: drag 파싱 — movement 의 선형 drag(:497-498행)와 대칭. 실물 45/47 회귀·2/47 drag 실사용.
    func testAngularMovementParsesDrag() {
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"name":"angularmovement","force":"0 0 2","drag":0.5}]}"#), material: nil)
        XCTAssertTrue(d.operators.contains(.angularMovement(force: Vec3(x: 0, y: 0, z: 2), drag: 0.5)))
    }

    func testAngularMovementDragDefaultsToZero() {
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"name":"angularmovement","force":"1 0 0"}]}"#), material: nil)
        XCTAssertTrue(d.operators.contains(.angularMovement(force: Vec3(x: 1, y: 0, z: 0), drag: 0)))
    }

    func testParseVortex() {
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"name":"vortex","axis":"0 0 1","distanceinner":0,"distanceouter":50,"speedinner":300,"speedouter":0,"offset":"0 0 0"}],"renderer":[{"name":"sprite"}],"maxcount":10}"#), material: nil)
        XCTAssertTrue(d.operators.contains(.vortex(axis: Vec3(x: 0, y: 0, z: 1), distanceInner: 0, distanceOuter: 50,
                                                   speedInner: 300, speedOuter: 0, offset: Vec3(x: 0, y: 0, z: 0))))
    }

    func testParseTurbulence() {
        // 실물 ember 인스턴스(2905844074): mask/phasemax/scale/speedmin/speedmax.
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"id":9,"mask":"1 0 0","name":"turbulence","phasemax":5,"scale":0.002,"speedmax":150,"speedmin":100}],"renderer":[{"name":"sprite"}],"maxcount":40}"#), material: nil)
        // [2026-08-20] 이 픽스처는 `timescale` 을 생략한다 — 부재 기본값이 0 이 아니라 20 이다
        // (주입기 0x1401beb80 직교 분기). 실물 ember 저작이 timescale 을 안 적었다는 사실은
        // 그대로고, 그 자리에 원본이 넣는 값이 달랐던 것이다.
        XCTAssertTrue(d.operators.contains(.turbulence(speedMin: 100, speedMax: 150, scale: 0.002, timeScale: 20,
                                                       mask: Vec3(x: 1, y: 0, z: 0), phaseMin: 0, phaseMax: 5)))
    }

    /// **[2026-08-20 정정] 종전 주석 "speed 0(무동작), timescale 0(정적장)" 은 반증됐다.**
    /// `turbulence` 주입기는 0x1401beb80 이고(게이트 stricmp 0x1401cd423 → 호출 0x1401cd45c),
    /// 직교투영 분기에서 speedmin 500 · speedmax 1000 · timescale 20 · mask "1 1 0" 을 심는다.
    /// 원근 분기는 1.0 / 5.0 / 1.0 / "1 1 1" 이다 — **0 은 어느 쪽도 아니다.**
    ///
    /// 종전 코드는 `scale 0.01`(직교 분기와 일치)과 `mask (1,1,1)`(원근 분기와 일치)을 섞어
    /// 쓰고 있었다 — 자기모순이었다. 직교가 실물 씬의 대부분이다(동봉 트리 169/171,
    /// 두 트리+설치본 347/355 — 아래 분기 주석의 범위 표기 참조).
    func testParseTurbulenceDefaults() {
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"id":8,"name":"turbulence"}],"renderer":[{"name":"sprite"}],"maxcount":10}"#), material: nil)
        XCTAssertTrue(d.operators.contains(.turbulence(speedMin: 500, speedMax: 1000, scale: 0.01, timeScale: 20,
                                                       mask: Vec3(x: 1, y: 1, z: 0), phaseMin: 0, phaseMax: 0)),
                      "주입기 0x1401beb80 직교 분기 — 실제 파스: \(d.operators)")
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

    /// E1(②): layerimage(레이어 이미지 픽셀 방출) — 케이스 부재로 무조건 드롭돼 이 이미터만 가진
    /// 시스템은 emitters=[] 로 파티클을 0개도 생성하지 못했다(cluster 64/251/321). 픽셀 분포 샘플링은
    /// WapleRender 전용 디코드 텍스처가 필요해 파스 단계에서 불가 — boxrandom 과 동일한 공용 필드로
    /// 균등 박스 방출 폴백(캐비엇: 알파 마스크 미반영).
    func testLayerImageEmitterFallsBackToBoxDistribution() {
        let d = ParticleSystemDef.parse(json("""
        {"emitter":[{"id":5,"name":"layerimage","rate":5000}],
         "renderer":[{"name":"sprite"}],"maxcount":10000}
        """), material: nil)
        XCTAssertEqual(d.emitters.count, 1, "종전엔 드롭돼 emitters=[] — 유일 이미터가 소실되면 파티클 0개")
        guard case let .box(origin, dmax, rate, burst) = d.emitters.first else { return XCTFail("box 아님") }
        XCTAssertEqual(origin, Vec3(x: 0, y: 0, z: 0), "실물 프리뷰(n=1)는 origin 미관측 — 원점 폴백")
        XCTAssertEqual(dmax, Vec3(x: 0, y: 0, z: 0), "distancemax 미관측 — 원점 스폰(무크래시, 0개보다 개선)")
        XCTAssertEqual(rate, 5000)
        XCTAssertEqual(burst, 0)
    }

    /// layerimage 도 sphererandom/boxrandom과 동일한 공용 필드(origin/distancemax/instantaneous)를
    /// 제공하면 그대로 반영해야 한다(향후 실물 코퍼스가 더 풍부한 필드를 쓰는 경우 대비).
    func testLayerImageEmitterHonorsProvidedFieldsLikeBoxrandom() {
        let d = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"layerimage","origin":"10 20 0","distancemax":"5 5 0","rate":100,"instantaneous":3}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        guard case let .box(origin, dmax, rate, burst) = d.emitters.first else { return XCTFail("box 아님") }
        XCTAssertEqual(origin, Vec3(x: 10, y: 20, z: 0))
        XCTAssertEqual(dmax, Vec3(x: 5, y: 5, z: 0))
        XCTAssertEqual(rate, 100)
        XCTAssertEqual(burst, 3)
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

    /// **`renderer` 키 부재는 "미지원" 이 아니라 sprite 다.** 파서가 `isArray`(0x1400888a0)에
    /// 실패하면 그 자리에서 오브젝트(태그 7)를 만들어 `{name:"sprite"}` 를 **주입한다**
    /// (0x1401c58a9 `jne` → 0x1401c58af `mov edx,7` → 0x1401c58c0 `"sprite"`).
    ///
    /// **빈 배열 `[]` 은 다르다** — isArray 를 통과하므로 주입이 걸리지 않고 렌더러가 0개로
    /// 남는다. 종전엔 둘을 `.unsupported("none")` 하나로 뭉갰다(동봉 부재 6건 · 빈 배열 4건).
    func testAbsentRendererInjectsSpriteButEmptyArrayDoesNot() {
        func renderer(_ src: String) -> RendererKind {
            ParticleSystemDef.parse(json(src), material: nil).renderer
        }
        XCTAssertEqual(renderer(#"{"maxcount":10}"#), .sprite, "키 부재 → 주입")
        XCTAssertEqual(renderer(#"{"renderer":"sprite","maxcount":10}"#), .sprite,
                       "배열이 아니어도 isArray 실패 → 주입")
        XCTAssertEqual(renderer(#"{"renderer":[],"maxcount":10}"#), .unsupported("none"),
                       "빈 배열은 isArray 를 통과한다 — 주입이 안 걸려 렌더러 0개")
    }

    func testHugeNumericParticleValuesDefaultInsteadOfTrapping() {
        let d = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"sphererandom","instantaneous":1e300,"rate":1e300}],
         "renderer":[{"name":"rope","subdivision":1e300}],
         "maxcount":1e300,"starttime":1e300}
        """), material: nil)
        // **[2026-08-20]** 기대값이 실측 기본값으로 바뀌었다. 이 테스트의 요지("거대값은
        // 트랩 대신 기본값") 는 그대로고, 그 "기본값" 이 무엇인지가 정정된 것이다.
        //   · maxcount 부재/판독불가 → **0**(주입기 없음, `isNumeric` 실패 시 0 @0x1401c579b)
        //   · rope.subdivision      → **4**(주입 0x1401c0d00, 핸들러 clamp [0,32])
        XCTAssertEqual(d.maxCount, 0)
        XCTAssertEqual(d.startTime, 0)
        guard case let .sphere(_, _, _, _, rate, burst, _) = d.emitters.first else {
            return XCTFail("no sphere")
        }
        XCTAssertEqual(rate, 0)
        XCTAssertEqual(burst, 0)
        XCTAssertEqual(d.renderer, .rope(subdivision: 4))
    }

    func testNegativeMaxCountClampsAndBurstStepNoTrap() {
        // 감사 V02: 음수 maxcount 가 버스트 스폰 Range 상한(0..<음수)으로 흘러 트랩하던 회귀.
        let d = ParticleSystemDef.parse(json(
            #"{"emitter":[{"name":"sphererandom","rate":0,"instantaneous":10}],"renderer":[{"name":"sprite"}],"maxcount":-1}"#),
            material: nil)
        XCTAssertEqual(d.maxCount, 0)
        var sim = ParticleSimulator(def: d, seed: 7)
        XCTAssertTrue(sim.step(0.1).isEmpty)  // 완주 자체가 무트랩 증명
    }

    func testHugeCountOverrideSaturatesInsteadOfTrapping() {
        // 감사 V06: maxcount/instantaneous 1e9 × override count 1e12 = 1e21 > Int.max — Int() 변환
        // SIGTRAP 회귀(실재현). 포화 클램프로 Int.max 에 포화돼야 한다.
        // 감사 M8: maxcount 는 최종 65536 상한으로 CPU 시뮬 과부하 방지.
        var ov = ParticleInstanceOverride()
        ov.count = 1e12
        let d = ParticleSystemDef.parse(json(
            #"{"emitter":[{"name":"sphererandom","instantaneous":1000000000,"rate":1}],"renderer":[{"name":"sprite"}],"maxcount":1000000000}"#),
            material: nil, instanceOverride: ov)
        XCTAssertEqual(d.maxCount, 65536)
        guard case let .sphere(_, _, _, _, _, burst, _) = d.emitters.first else { return XCTFail("no sphere") }
        XCTAssertEqual(burst, Int.max)
    }

    func testNaNCountOverrideDefaultsToZeroInsteadOfTrapping() {
        // 감사 V06: NaN 배수도 Int() 변환 트랩 — 안전 기본값 0(음수 클램프와 동일 정책).
        var ov = ParticleInstanceOverride()
        ov.count = .nan
        let d = ParticleSystemDef.parse(json(
            #"{"emitter":[{"name":"sphererandom","instantaneous":10,"rate":1}],"renderer":[{"name":"sprite"}],"maxcount":10}"#),
            material: nil, instanceOverride: ov)
        XCTAssertEqual(d.maxCount, 0)
        guard case let .sphere(_, _, _, _, _, burst, _) = d.emitters.first else { return XCTFail("no sphere") }
        XCTAssertEqual(burst, 0)
    }

    /// **[2026-08-20] 정정: 승계가 아니라 고정 상수다.**
    ///
    /// 종전 이 테스트는 "fmax 부재 시 fmin 승계(역범위 랜덤 방지)" 를 계약으로 걸었다. 그건
    /// 자산 관찰에서 유추한 것이고, 원본은 그렇게 하지 않는다 — 원소 팩토리 직전의 기본값
    /// 주입기가 `frequencymax` 에 **상수**를 심는다:
    ///   · oscillatealpha    0x1401bda2f → 10.0
    ///   · oscillatesize     0x1401bdd0f → 10.0
    ///   · oscillateposition 0x1401bd7cc → **5.0**
    ///
    /// position 만 5.0 인 것이 이 정정의 반증 가능한 증거다 — 승계였다면 세 값이 fmin 을 따라
    /// 2.5/1.5/3.5 로 갈렸을 것이고, 공통 상수였다면 셋이 같았을 것이다. 둘 다 아니다.
    /// 역범위 걱정도 사라진다: fmin 기본값도 1.0 상수라 fmin > fmax 가 되려면 저작이 fmin 을
    /// 명시적으로 크게 적어야 하는데, 그건 원본에서도 같은 결과다.
    func testOscillateFrequencyMaxUsesInjectedConstantNotFrequencyMin() {
        let d = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"oscillatesize","frequencymin":2.5},
                     {"name":"oscillatealpha","frequencymin":1.5},
                     {"name":"oscillateposition","frequencymin":3.5}],"maxcount":10}
        """), material: nil)
        guard case let .oscillateSize(sf0, sf1, _, _, _, _) = d.operators[0] else { return XCTFail("no oscillatesize") }
        XCTAssertEqual(sf0, 2.5); XCTAssertEqual(sf1, 10, "승계였다면 2.5")
        guard case let .oscillateAlpha(af0, af1, _, _, _, _) = d.operators[1] else { return XCTFail("no oscillatealpha") }
        XCTAssertEqual(af0, 1.5); XCTAssertEqual(af1, 10, "승계였다면 1.5")
        guard case let .oscillatePosition(pf0, pf1, _, _, _, _, _) = d.operators[2] else { return XCTFail("no oscillateposition") }
        XCTAssertEqual(pf0, 3.5); XCTAssertEqual(pf1, 5, "position 만 5.0 — 승계도 공통상수도 아니다")
    }

    /// frequency 를 아예 생략하면 셋 다 fmin = 1.0 이다(주입기 0x1401bd979/0x1401bdc59/0x1401bd716).
    /// 종전 기본 0 은 `sin(2π·0·n + φ)` 를 상수로 만들어 연산자를 **무력화**했다 — 동봉에서
    /// oscillatealpha 3건 · oscillatesize 2건이 그렇게 죽어 있었다.
    func testOscillateFrequencyMinDefaultsToOneNotZero() {
        let d = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"oscillatesize"},{"name":"oscillatealpha"},{"name":"oscillateposition"}],"maxcount":10}
        """), material: nil)
        guard case let .oscillateSize(sf0, _, ssmin, ssmax, _, _) = d.operators[0] else { return XCTFail("no oscillatesize") }
        XCTAssertEqual(sf0, 1)
        XCTAssertEqual(ssmin, 0.8, "주입기 0x1401bddc5"); XCTAssertEqual(ssmax, 1.2, "주입기 0x1401bde6f — 크기 ±20% 맥동")
        guard case let .oscillateAlpha(af0, _, _, _, _, _) = d.operators[1] else { return XCTFail("no oscillatealpha") }
        XCTAssertEqual(af0, 1)
        guard case let .oscillatePosition(pf0, _, _, _, _, _, _) = d.operators[2] else { return XCTFail("no oscillateposition") }
        XCTAssertEqual(pf0, 1)
    }

    /// **위상은 [0, 2π) 로 흩어진다 — 전 파티클 동위상이 아니다.**
    /// 세 오퍼레이터 전부 `phasemax = 6.2831855` 를 주입한다(0x1401bd8de · 0x1401bdbe3 ·
    /// 0x1401bdecd, 전부 실수 주입 헬퍼 0x1401d7d30 경유). 종전 기본 0 은 위상 폭이 0 이라
    /// 모든 파티클이 같은 순간에 같은 값으로 흔들렸다 — 눈에 보이는 차이다.
    /// (`reducemovementnearcontrolpoint` 만 phasemax 0 을 주입한다 — 0x1401beeed.)
    func testOscillatePhaseSpreadsOverFullTurnByDefault() {
        let d = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"oscillatesize"},{"name":"oscillatealpha"},{"name":"oscillateposition"}],"maxcount":10}
        """), material: nil)
        guard case let .oscillateSize(_, _, _, _, spmin, spmax) = d.operators[0] else { return XCTFail("no size") }
        XCTAssertEqual(spmin, 0); XCTAssertEqual(spmax, 2 * .pi, accuracy: 1e-5)
        guard case let .oscillateAlpha(_, _, _, _, apmin, apmax) = d.operators[1] else { return XCTFail("no alpha") }
        XCTAssertEqual(apmin, 0); XCTAssertEqual(apmax, 2 * .pi, accuracy: 1e-5)
        guard case let .oscillatePosition(_, _, _, psmax, ppmin, ppmax, pmask) = d.operators[2] else {
            return XCTFail("no position")
        }
        XCTAssertEqual(ppmin, 0); XCTAssertEqual(ppmax, 2 * .pi, accuracy: 1e-5)
        // 같은 원소의 나머지 둘도 함께 못 박는다 — 셋 다 같은 주입기에서 나온다.
        // **[2026-08-20 재정정]** 이 값은 내가 한 번 0.5 로 잘못 넣었다. 분기 조건이 파티클 json 의
        // `flags` 키가 아니라 **씬의 직교투영 활성 여부**(엔진 오브젝트 `[+0x118]` bit10)였고,
        // 그 비트는 `general.orthogonalprojection` 의 auto 또는 width·height 로 세워진다
        // (0x1401874ec 키 읽기 → 0x14018768a `or [r13+0x118], 0x400`).
        // **[2026-08-20 범위 명시]** 이 자리에 세 숫자가 범위 표기 없이 돌아다녔다.
        // 게이트를 다시 읽고(0x1401874fe `cmp byte [rax+8], 7` = objectValue →
        // `auto` 는 0x140187550 `cmp …,5` = booleanValue → 0x140187565 `or …,0x18`,
        // 아니면 width·height → 0x1401875df `or …,8` → 최종 0x14018768a `or [r13+0x118],0x400`)
        // 그 규칙 그대로 세니 **범위마다 값이 다르다**:
        //   · 동봉 트리 단독            ortho 169 / 원근 2 / 171 = **98.8%**
        //   · 두 트리 + 설치본 projects  ortho 347 / 원근 8 / 355 = **97.7%**
        // 둘 다 맞는 값이고, 섞어 쓴 `347/355 = 98.8%` 만 틀렸다. (`343/347` 은 어느 범위로도
        // 재현되지 않았다 — 근거 불명으로 폐기한다.)
        //
        // **더 강한 사실**: 원근 판정 씬은 **전부 키 자체가 없는** 씬이고(키를 가진 씬은 전건
        // ortho), 그중 조건부 상수를 쓰는 오퍼레이터를 가진 것이 **하나도 없다**
        // (modeleditor·particleeditor3dscale·demon_core·neon_sunset·dna_fragment·arsenal).
        // 즉 직교 분기 채택은 백분율과 무관하게 **전건 안전**하다.
        // 이 불변식은 `scripts/spec/check_ortho_projection_census.py` 가 강제한다 —
        // 주석에만 두면 또 갈라진다.
        XCTAssertEqual(psmax, 10, "0x1401bd899 직교 분기(원근은 0.5) — `?? scalemin` 승계는 어느 쪽도 아니다")
        XCTAssertEqual(pmask, Vec3(x: 1, y: 1, z: 0), "주입 문자열 \"1 1 0\" @0x14048f488 — (1,1,1) 아님")
    }

    /// 주기 방출 다섯 키도 **주입 대상**이다(이미터 주입기 진입 0x1401b8df0 의 꼬리
    /// 0x1401b907d-0x1401b90f5). 직전 커밋이 "주입 없음(전부 0)" 이라고 정반대로 적었던 자리다 —
    /// 고정 바이트 창으로 디스어셈블해 체인된 `.pdata` 조각에서 꼬리를 놓친 것이 원인이었다.
    func testPeriodicDefaultsComeFromInjectorNotZero() {
        let d = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":0,"maxtoemitperperiod":6}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        let pe = d.emitterPeriodic.first ?? nil
        XCTAssertEqual(pe?.durationMin, 2, "0x1401b907d"); XCTAssertEqual(pe?.durationMax, 3, "0x1401b9094")
        XCTAssertEqual(pe?.delayMin, 1, "0x1401b90ab"); XCTAssertEqual(pe?.delayMax, 2, "0x1401b90c2")
        XCTAssertEqual(pe?.maxPerPeriod, 6)
    }

    /// 이니셜라이저 기본값도 같은 주입기 규약이다 — "중립값" 유추가 아니다.
    ///
    /// **[2026-08-20] 커버리지 확장.** 종전엔 여덟 종 중 넷만 봤고, 빠진 둘이 실제로 틀려 있었다:
    /// `sizerandom` 1/1 → ortho 5.0/50.0, `velocityrandom` (0,0,0)/(0,0,0) → ortho
    /// "-32 -32 0"/"32 32 0". 둘 다 어느 분기에도 없는 "중립값" 유추였고, `injected()` 를 거치지
    /// 않아 이 테스트의 그물 밖에 있었다. 여덟 종을 전부 본다.
    func testInitializerDefaultsComeFromInjectorConstants() {
        let d = ParticleSystemDef.parse(json("""
        {"initializer":[{"name":"angularvelocityrandom"},{"name":"alpharandom"},
                        {"name":"colorrandom"},{"name":"lifetimerandom"},
                        {"name":"sizerandom"},{"name":"velocityrandom"}],"maxcount":10}
        """), material: nil)
        guard case let .angularVelocityRandom(amin, amax, _) = d.initializers[0] else { return XCTFail("no angularvelocityrandom") }
        XCTAssertEqual(amin, Vec3(x: 0, y: 0, z: -5), "주입기 0x1401bba1e — 종전 (0,0,0) 은 회전이 아예 없다")
        XCTAssertEqual(amax, Vec3(x: 0, y: 0, z: 5), "주입기 0x1401bbafe")
        guard case let .alphaRandom(pmin, pmax, _) = d.initializers[1] else { return XCTFail("no alpharandom") }
        XCTAssertEqual(pmin, 0.05, "주입기 0x1401baa70 — WE 의 중립은 불투명(1)이 아니다")
        XCTAssertEqual(pmax, 1)
        guard case let .colorRandom(cmin, cmax, _) = d.initializers[2] else { return XCTFail("no colorrandom") }
        XCTAssertEqual(cmin, Vec3(x: 0, y: 0, z: 0), "주입기 0x1401ba16e")
        XCTAssertEqual(cmax, Vec3(x: 255, y: 255, z: 255))
        guard case let .lifetimeRandom(lmin, lmax, _) = d.initializers[3] else { return XCTFail("no lifetimerandom") }
        XCTAssertEqual(lmin, 0, "주입기 0x1401b9c40 은 min 에 상수를 심지 않는다 = 0")
        XCTAssertEqual(lmax, 1)
        // 주입기 0x1401b9e70 — `test dl,dl`/`test sil,sil` 로 ortho 를 고른다.
        guard case let .sizeRandom(smin, smax, _) = d.initializers[4] else { return XCTFail("no sizerandom") }
        XCTAssertEqual(smin, 5, "0x1401b9e96 ortho 5.0(0x140492858) — 원근은 0.001. 1 은 어느 쪽도 아니다")
        XCTAssertEqual(smax, 50, "0x1401b9f6a ortho 50.0(0x1404928cc) — 원근은 1.0")
        // 주입기 0x1401bac50 — 문자열 주입 + `cmovne`.
        guard case let .velocityRandom(vmin, vmax, _) = d.initializers[5] else { return XCTFail("no velocityrandom") }
        XCTAssertEqual(vmin, Vec3(x: -32, y: -32, z: 0), "0x1401bac6d ortho \"-32 -32 0\" — 원근은 \"-1 -1 -1\"")
        XCTAssertEqual(vmax, Vec3(x: 32, y: 32, z: 0), "0x1401bac93 ortho \"32 32 0\" — 원근은 \"1 1 1\"")
    }

    /// **주입은 "키 부재" 에만 일어난다 — "키는 있는데 못 읽음" 은 주입 대상이 아니다.**
    ///
    /// 이 구분이 없으면 `pfloat(d[k]) ?? C` 가 둘을 뭉뚱그려 **신뢰불가 입력이 오히려 엔진
    /// 기본값으로 승격**된다. 실제로 그렇게 넣었다가 `1e300` 회귀 테스트가 잡았다 —
    /// 원본도 `find` 가 노드를 찾으면 주입을 건너뛰고 그 노드의 `asFloat` 결과를 쓴다.
    func testInjectedDefaultsApplyOnlyToAbsentKeysNotUnreadableOnes() {
        // rate 는 있지만 Float 범위 밖 → 주입(10) 이 아니라 0
        let huge = ParticleSystemDef.parse(json(
            #"{"emitter":[{"name":"boxrandom","rate":1e300}],"renderer":[{"name":"sprite"}],"maxcount":10}"#),
            material: nil)
        guard case let .box(_, _, hugeRate, _) = huge.emitters.first else { return XCTFail("no box") }
        XCTAssertEqual(hugeRate, 0, "키가 있으므로 주입기가 안 돈다")

        // 같은 규약이 연산자·이니셜라이저에도 걸린다.
        let ops = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"alphafade","fadeouttime":1e300}],"maxcount":10}"#), material: nil)
        guard case let .alphaFade(_, fadeOut) = ops.operators.first else { return XCTFail("no alphafade") }
        XCTAssertEqual(fadeOut, 0, "0.5 로 승격되면 안 된다")

        let ini = ParticleSystemDef.parse(json(
            #"{"initializer":[{"name":"alpharandom","min":"nonsense"}],"maxcount":10}"#), material: nil)
        guard case let .alphaRandom(amin, _, _) = ini.initializers.first else { return XCTFail("no alpharandom") }
        XCTAssertEqual(amin, 0, "0.05 로 승격되면 안 된다")
    }

    /// 이미터 `rate` 부재 기본값도 주입기 상수다(0x1401b8e09 → 10.0 @0x1401b8e59).
    /// 종전 0 은 연속 방출을 통째로 끈다 — 실물 293건 중 4건이 그 상태였다.
    func testEmitterRateDefaultsToTenNotZero() {
        let d = ParticleSystemDef.parse(json(
            #"{"emitter":[{"name":"boxrandom","origin":"0 0 0"}],"renderer":[{"name":"sprite"}],"maxcount":10}"#),
            material: nil)
        guard case let .box(_, _, rate, _) = d.emitters.first else { return XCTFail("no box") }
        XCTAssertEqual(rate, 10, "주입기 상수 — 종전 0 은 연속 방출 없음")
    }

    /// 주기 방출은 **min 을 max 로 클램프**한다(이미터 base 파서 꼬리 0x1401c1deb-0x1401c1e0c:
    /// `[+0x18] = minss([+0x1c], [+0x18])`, delay 도 동형). max 는 건드리지 않는다.
    /// 부재 키는 0 이다 — 주기 키에는 기본값 주입이 없다(주입기는 rate/duration 만 다룬다).
    /// 동봉 도달 0(주기 이미터 5건 전건 min 명시 · 전건 min ≤ max)이라 워크샵 역범위 전용 가드다.
    func testPeriodicEmissionClampsMinToMax() {
        let inverted = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":0,"minperiodicduration":5,"maxperiodicduration":2,
                     "minperiodicdelay":9,"maxperiodicdelay":1}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        let pe = inverted.emitterPeriodic.first ?? nil
        XCTAssertNotNil(pe, "주기 키가 있으면 PeriodicEmission 이 조립된다")
        XCTAssertEqual(pe?.durationMin, 2, "min 이 max 로 내려간다")
        XCTAssertEqual(pe?.durationMax, 2, "max 는 그대로")
        XCTAssertEqual(pe?.delayMin, 1)
        XCTAssertEqual(pe?.delayMax, 1)

        // 정상 범위는 손대지 않는다(실물 water_droplets_periodic 값).
        let normal = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":0,"minperiodicduration":0.5,"maxperiodicduration":1,
                     "minperiodicdelay":0.5,"maxperiodicdelay":1}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        let pn = normal.emitterPeriodic.first ?? nil
        XCTAssertNotNil(pn)
        XCTAssertEqual(pn?.durationMin, 0.5); XCTAssertEqual(pn?.durationMax, 1)
        XCTAssertEqual(pn?.delayMin, 0.5); XCTAssertEqual(pn?.delayMax, 1)
    }

    /// `alphafade` 는 이번 라운드 최고 도달이다 — 동봉 177건 중 97건이 `fadeouttime` 을 생략한다.
    /// 0 이면 페이드가 통째로 꺼져 수명 끝에 팝 한다. 원본은 0.5(수명의 마지막 절반에 걸쳐 소멸).
    func testAlphaFadeDefaultsToHalfLifetimeNotZero() {
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"name":"alphafade"}],"maxcount":10}"#), material: nil)
        XCTAssertTrue(d.operators.contains(.alphaFade(fadeInTime: 0.5, fadeOutTime: 0.5)),
                      "주입기 0x1401bce50 이 두 키 모두에 0.5(0x1401bce71)를 심는다")
    }

    // F189/F190: scalemax 기본이 scalemin 승계(구현)가 아니라 1(비퇴화)이어야 — scale 전체 생략(데모
    // 시나리오)과 scalemin 단독 지정(코퍼스 다수: 0.2×9·0.3×4·0.1×4 등) 양쪽 모두 진폭이 죽지 않아야 한다.
    func testOscillateAlphaScaleMaxDefaultsToOneNotScaleMin() {
        // [2026-08-20] 이 결론은 살아남았다 — 주입기 0x1401bdb85 가 실제로 scalemax = 1.0 을 심고
        // scalemin 에는 상수를 심지 않는다(= 0). F189/F190 의 자산 기반 추론이 실측과 일치했다.
        let allOmitted = ParticleSystemDef.parse(json(#"{"operator":[{"name":"oscillatealpha","frequencymin":2}]}"#), material: nil)
        guard case let .oscillateAlpha(_, _, smin0, smax0, _, _) = allOmitted.operators[0] else { return XCTFail("no oscillatealpha") }
        XCTAssertEqual(smin0, 0); XCTAssertEqual(smax0, 1, "scale 생략 시 scalemax 는 scalemin(0) 이 아니라 1")

        let scaleMinOnly = ParticleSystemDef.parse(json(#"{"operator":[{"name":"oscillatealpha","scalemin":0.2}]}"#), material: nil)
        guard case let .oscillateAlpha(_, _, smin1, smax1, _, _) = scaleMinOnly.operators[0] else { return XCTFail("no oscillatealpha") }
        XCTAssertEqual(smin1, 0.2); XCTAssertEqual(smax1, 1, "scalemin 단독 지정 시 scalemax 승계(상수화) 대신 1")
    }

    // F184: phasemin/phasemax 가 파티클별 위상 range 로 파스돼야(fireworks 5씬 근동기 의도 복원 —
    // 종전엔 이 키 자체를 읽지 않아 항상 완전 랜덤 위상이었다).
    // [2026-08-20] "기본은 자매 오퍼레이터와 동형으로 0" 은 틀렸다 — 아래 개명된 테스트 참조.
    func testOscillateAlphaParsesPhaseRange() {
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"name":"oscillatealpha","frequencymin":1.5,"phasemin":0,"phasemax":0.1}]}"#), material: nil)
        guard case let .oscillateAlpha(_, _, _, _, pmin, pmax) = d.operators[0] else { return XCTFail("no oscillatealpha") }
        XCTAssertEqual(pmin, 0); XCTAssertEqual(pmax, 0.1)
    }

    /// **[2026-08-20] 개명·정정.** 종전 이름은 `...PhaseDefaultsToZero` 였고 계약도 그랬는데,
    /// **이름 자체가 틀린 계약**이었다. 주입기가 `phasemax = 6.2831855`(2π)를 심는다
    /// (oscillatealpha 0x1401bdbe3 — 실수 주입 헬퍼 0x1401d7d30 경유). phasemin 만 0 이다
    /// (0x1401bdbbd).
    ///
    /// 차이는 눈에 보인다: 위상 폭 0 은 **전 파티클 동위상**이라 한 몸처럼 깜빡이고,
    /// [0, 2π) 는 개별 파티클이 제 위상으로 흔들린다. F184 가 되살리려던 게 바로 그것이다.
    func testOscillateAlphaPhaseMaxDefaultsToFullTurn() {
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"name":"oscillatealpha","frequencymin":1.5}]}"#), material: nil)
        guard case let .oscillateAlpha(_, _, _, _, pmin, pmax) = d.operators[0] else { return XCTFail("no oscillatealpha") }
        XCTAssertEqual(pmin, 0, "phasemin 은 0 — 0x1401bdbbd")
        XCTAssertEqual(pmax, 2 * .pi, accuracy: 1e-5, "phasemax 는 2π — 0x1401bdbe3")
    }

    func testControlPointAttractConsumesControlPointId() {
        // 감사 V04: controlpoint 키(CP id)가 controlpoint 배열의 offset 을 target 으로 소비.
        let d = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"controlpointattract","controlpoint":1,"scale":-750,"threshold":64}],
         "controlpoint":[{},{"offset":"100 200 0"}],"maxcount":10}
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

    // C⑦a: usershadervalues 가 refract_amount 를 user property 로 오버라이드 — 실물 규약은
    // {JSON 키=user property 키, JSON 값=셰이더 상수 토큰}(SceneDocument 이미지 레이어 경로와 동일 방향).
    // 이전 구현은 usv[토큰]으로 조회해(방향 반대) 사용자가 고른 굴절 강도가 항상 무시됐다.
    func testRefractAmountOverriddenByUserShaderValue() {
        let m = ParticleMaterial.parse(json("""
        {"passes":[{"blending":"translucent","combos":{"REFRACT":1},
          "constantshadervalues":{"ui_editor_properties_refract_amount":0.1},
          "usershadervalues":{"refractStrength":"ui_editor_properties_refract_amount"},
          "textures":["particle/drop","particle/drop_normal"]}]}
        """), userProps: ["refractStrength": 0.42])
        XCTAssertEqual(m.refractAmount, 0.42, accuracy: 1e-6, "user property 오버라이드가 반영돼야")
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

    // C4-(ii): overbright(genericparticle.frag g_Overbright, material 유니폼) — refract_amount 와 동일
    // constantshadervalues 파스 패턴(실물 dischargearc.json: ui_editor_properties_overbright=1.0).
    func testOverbrightParsedFromConstantShaderValues() {
        let m = ParticleMaterial.parse(json("""
        {"passes":[{"blending":"additive",
          "constantshadervalues":{"ui_editor_properties_overbright":2.5},
          "textures":["particle/beam"]}]}
        """))
        XCTAssertEqual(m.overbright, 2.5, accuracy: 1e-6)
    }

    // 미명시 시 WE 기본 1.0 — 기존 씬(overbright 키 없음) 무회귀의 근거(색 곱 항등원).
    func testOverbrightDefaultsToOneWhenAbsent() {
        let m = ParticleMaterial.parse(json(#"{"passes":[{"blending":"translucent","textures":["particle/snow"]}]}"#))
        XCTAssertEqual(m.overbright, 1, accuracy: 1e-6)
        let empty = ParticleMaterial.parse(json("{}"))
        XCTAssertEqual(empty.overbright, 1, accuracy: 1e-6)
    }
}
