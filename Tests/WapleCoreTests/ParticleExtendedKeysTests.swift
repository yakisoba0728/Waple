import XCTest
import simd
@testable import WapleCore

/// 파티클 확장 키(wallpaper64.exe 스트링 테이블 정본 대조 갭):
/// periodic 방출(@0x48e1c0–0x48e2b8), remapvalue 전어휘(@0x490c78–0x490eb0),
/// controlpointattract deletethreshold(@0x48e788), vortex 확장/vortex_v2 ring(@0x48e7c8–0x48e8e0),
/// rope/ropetrail 렌더러 키(@0x48e9b0–0x48ea18), positionoffsetrandom(@0x48e380/398),
/// hsvcolorrandom huesteps/노이즈 3종(@0x48e3c0–0x48e3e0).
/// 시뮬 의미론은 WE 에디터 어휘 규약에 따른 [추정] — 각 테스트는 파스(키/기본값) + 행동을 단언한다.
final class ParticleExtendedKeysTests: XCTestCase {

    private func makeDef(emitters: [Emitter]? = nil,
                         initializers extraInits: [Initializer] = [],
                         lifetime: Float = 100, maxCount: Int = 64,
                         operators extra: [ParticleOperator] = []) -> ParticleSystemDef {
        ParticleSystemDef(
            emitters: emitters ?? [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
                                        rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: lifetime, max: lifetime),
                           .sizeRandom(min: 4, max: 4),
                           .alphaRandom(min: 1, max: 1, exponent: 1)] + extraInits,
            operators: extra,
            renderer: .sprite, maxCount: maxCount, startTime: 0, material: nil)
    }

    // MARK: - 1. periodic 방출

    func testPeriodicParse_fullAndDefaultsAndAbsent() {
        let full = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":5,"minperiodicduration":1,"maxperiodicduration":3,
                     "minperiodicdelay":2,"maxperiodicdelay":4,"maxtoemitperperiod":7}],
         "renderer":[{"name":"sprite"}],"maxcount":100}
        """), material: nil)
        let p = full.emitterPeriodic[0]
        XCTAssertEqual(p?.durationMin, 1); XCTAssertEqual(p?.durationMax, 3)
        XCTAssertEqual(p?.delayMin, 2); XCTAssertEqual(p?.delayMax, 4)
        XCTAssertEqual(p?.maxPerPeriod, 7)

        // maxtoemitperperiod 단독 → duration 기본 1/1, delay 0/0(중립), quota 6.
        let partial = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"sphererandom","rate":1,"maxtoemitperperiod":6}],
         "renderer":[{"name":"sprite"}],"maxcount":100}
        """), material: nil)
        let q = partial.emitterPeriodic[0]
        XCTAssertEqual(q?.durationMin, 1); XCTAssertEqual(q?.durationMax, 1)
        XCTAssertEqual(q?.delayMin, 0); XCTAssertEqual(q?.delayMax, 0)
        XCTAssertEqual(q?.maxPerPeriod, 6)

        // 키 전부 부재 → nil(기존 방출 경로 비트동일).
        let none = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":5}],"renderer":[{"name":"sprite"}],"maxcount":100}
        """), material: nil)
        XCTAssertEqual(none.emitterPeriodic.count, 1)
        XCTAssertNil(none.emitterPeriodic[0])
    }

    func testPeriodicEmission_windowCountsAndDelayGate() {
        // duration 1s / delay 1s / quota 4, rate 0 → 창당 4개, 딜레이 중 0개. dt=0.25.
        var def = makeDef(emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
                                          rate: 0, burst: 0)],
                          lifetime: 100, maxCount: 32)
        def.emitterPeriodic = [PeriodicEmission(durationMin: 1, durationMax: 1,
                                                delayMin: 1, delayMax: 1, maxPerPeriod: 4)]
        var sim = ParticleSimulator(def: def, seed: 7)
        for _ in 0..<4 { _ = sim.step(0.25) }          // t=1.0: 창1 종료
        XCTAssertEqual(sim.liveCount, 4)               // 창 내 quota 만큼 방출
        for _ in 0..<4 { _ = sim.step(0.25) }          // t=2.0: 딜레이 구간
        XCTAssertEqual(sim.liveCount, 4)               // 딜레이 중 신규 방출 0(전멸도 없음)
        for _ in 0..<4 { _ = sim.step(0.25) }          // t=3.0: 창2 종료
        XCTAssertEqual(sim.liveCount, 8)               // 두 번째 창 quota 누적
    }

    func testPeriodicEmission_burstCappedByQuotaPerWindow() {
        // burst 8 + quota 4 → 창 진입 버스트가 quota 로 상한(창당 4).
        var def = makeDef(emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
                                          rate: 0, burst: 8)],
                          lifetime: 100, maxCount: 32)
        def.emitterPeriodic = [PeriodicEmission(durationMin: 1, durationMax: 1,
                                                delayMin: 1, delayMax: 1, maxPerPeriod: 4)]
        var sim = ParticleSimulator(def: def, seed: 8)
        _ = sim.step(0.25)
        XCTAssertEqual(sim.liveCount, 4)               // 버스트 8 이 quota 4 로 상한
        for _ in 0..<7 { _ = sim.step(0.25) }          // t=2.0(창2 진입은 t=2.0 전이 시점)
        _ = sim.step(0.25)                             // 창2 첫 방출 스텝
        XCTAssertEqual(sim.liveCount, 8)
    }

    // MARK: - 2. remapvalue 확장

    func testRemapValueExParse_fullVocabulary() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],
         "operator":[{"name":"remapvalue","output":"multiplysize","input":"lifetimefraction",
                      "operation":"square","transformfunction":"triangle","transformoctaves":5,
                      "transforminputscale":2,"outputrangemin":0.5,"outputrangemax":3,
                      "blendinstart":0.1,"blendinend":0.3,"blendoutstart":0.7,"blendoutend":0.9,
                      "inputcontrolpoint0":2,"inputcontrolpoint1":3,
                      "outputcontrolpoint0":4,"outputcontrolpoint1":5,"component":"y"}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        guard case let .remapValueEx(spec) = def.operators.first else {
            return XCTFail("확장 키 보유 remapvalue 는 remapValueEx 로 파스되어야 한다")
        }
        XCTAssertEqual(spec.verb, .multiplySize)
        XCTAssertEqual(spec.input, .lifetimeFraction)
        XCTAssertEqual(spec.operation, .square)
        XCTAssertEqual(spec.transform, .triangle)
        XCTAssertEqual(spec.octaves, 5)
        XCTAssertEqual(spec.inputScale, 2)
        XCTAssertEqual(spec.outMin, Vec3(x: 0.5, y: 0.5, z: 0.5))   // 스칼라 브로드캐스트
        XCTAssertEqual(spec.outMax, Vec3(x: 3, y: 3, z: 3))
        XCTAssertEqual(spec.blendInStart, 0.1); XCTAssertEqual(spec.blendInEnd, 0.3)
        XCTAssertEqual(spec.blendOutStart, 0.7); XCTAssertEqual(spec.blendOutEnd, 0.9)
        XCTAssertEqual(spec.inputCP0, 2); XCTAssertEqual(spec.inputCP1, 3)
        XCTAssertEqual(spec.outputCP0, 4); XCTAssertEqual(spec.outputCP1, 5)
        XCTAssertEqual(spec.component, 1)                            // "y"
    }

    func testRemapValueParse_legacyOutputsStayLegacyWithoutExtKeys() {
        // 확장 키 부재 + velocity/speed 출력 → 기존 .remapValue(시뮬 비트동일 무회귀).
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],
         "operator":[{"name":"remapvalue","output":"velocity","transformfunction":"fbmnoise",
                      "transforminputscale":8,"outputrangemin":"-1 -2 0","outputrangemax":"1 2 0"},
                     {"name":"remapvalue","output":"speed","outputrangemin":0,"outputrangemax":2}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        guard case let .remapValue(out0, fbm0, scale0) = def.operators[0],
              case let .remapValue(out1, _, _) = def.operators[1] else {
            return XCTFail("확장 키 부재 velocity/speed 는 레거시 remapValue 여야 한다")
        }
        XCTAssertTrue(fbm0); XCTAssertEqual(scale0, 8)
        XCTAssertEqual(out0, .velocity(min: Vec3(x: -1, y: -2, z: 0), max: Vec3(x: 1, y: 2, z: 0)))
        XCTAssertEqual(out1, .speed(min: 0, max: 2))
    }

    func testRemapValueParse_verbStringsAndLegacyWithExtKeysRouteToEx() {
        // 엔진 동사형 문자열(setvelocity/addvelocity/…) 및 레거시 출력+확장 키 조합은 Ex 경로.
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],
         "operator":[{"name":"remapvalue","output":"setvelocity","outputrangemin":"0 0 0","outputrangemax":"1 1 1"},
                     {"name":"remapvalue","output":"addangularvelocity"},
                     {"name":"remapvalue","output":"speed","input":"particlesystemtime"}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        guard case let .remapValueEx(s0) = def.operators[0],
              case let .remapValueEx(s1) = def.operators[1],
              case let .remapValueEx(s2) = def.operators[2] else {
            return XCTFail("동사형/확장 키 조합은 remapValueEx 여야 한다")
        }
        XCTAssertEqual(s0.verb, .setVelocity)
        XCTAssertEqual(s1.verb, .addAngularVelocity)
        XCTAssertEqual(s2.verb, .multiplySpeed)          // 레거시 "speed" → multiplyspeed 매핑
        XCTAssertEqual(s2.input, .particleSystemTime)
    }

    func testRemapValueEx_setVelocityOverwrites_degenerateRange() {
        // Ex setvelocity min==max → 노이즈 무관 덮어쓰기(레거시 velocity 경로와 동형 행동).
        let spec = RemapSpec(verb: .setVelocity, input: nil, operation: .remap, transform: .fbmnoise,
                             octaves: 3, inputScale: 10,
                             outMin: Vec3(x: 3, y: -7, z: 0), outMax: Vec3(x: 3, y: -7, z: 0),
                             blendInStart: 0, blendInEnd: 0, blendOutStart: 0, blendOutEnd: 0,
                             inputCP0: 0, inputCP1: 1, outputCP0: 0, outputCP1: 1, component: 0)
        var sim = ParticleSimulator(def: makeDef(operators: [.remapValueEx(spec: spec)]), seed: 21)
        let a = sim.step(1.0)
        XCTAssertEqual(a[0].vel.x, 3, accuracy: 0.001)
        XCTAssertEqual(a[0].vel.y, -7, accuracy: 0.001)
        XCTAssertEqual(a[0].pos.x, 3, accuracy: 0.01)
        XCTAssertEqual(a[0].pos.y, -7, accuracy: 0.01)
    }

    func testRemapValueEx_multiplyOpacityLifetimeFraction() {
        // input=lifetimefraction, 변환 없음 → alpha = n(수명 비율) 배수.
        let spec = RemapSpec(verb: .multiplyOpacity, input: .lifetimeFraction, operation: .remap,
                             transform: nil, octaves: 3, inputScale: 1,
                             outMin: Vec3(x: 0, y: 0, z: 0), outMax: Vec3(x: 1, y: 1, z: 1),
                             blendInStart: 0, blendInEnd: 0, blendOutStart: 0, blendOutEnd: 0,
                             inputCP0: 0, inputCP1: 1, outputCP0: 0, outputCP1: 1, component: 0)
        var sim = ParticleSimulator(def: makeDef(lifetime: 1, operators: [.remapValueEx(spec: spec)]), seed: 22)
        let a = sim.step(0.5)                    // age 0.5 → n 0.5
        XCTAssertEqual(a[0].alpha, 0.5, accuracy: 0.01)
        let b = sim.step(0.4)                    // age 0.9 → n 0.9
        XCTAssertEqual(b[0].alpha, 0.9, accuracy: 0.01)
    }

    func testRemapValueEx_addVelocityIsNonDestructive() {
        // addvelocity min==max=(10,0,0) → 저장 vel 불변, 적분 위치만 +10·t.
        let spec = RemapSpec(verb: .addVelocity, input: .lifetimeFraction, operation: .remap,
                             transform: nil, octaves: 3, inputScale: 1,
                             outMin: Vec3(x: 10, y: 0, z: 0), outMax: Vec3(x: 10, y: 0, z: 0),
                             blendInStart: 0, blendInEnd: 0, blendOutStart: 0, blendOutEnd: 0,
                             inputCP0: 0, inputCP1: 1, outputCP0: 0, outputCP1: 1, component: 0)
        var sim = ParticleSimulator(def: makeDef(lifetime: 100, operators: [.remapValueEx(spec: spec)]), seed: 23)
        _ = sim.step(1.0)
        let b = sim.step(1.0)
        XCTAssertEqual(b[0].vel.x, 0, accuracy: 0.001)   // 저장 vel 비파괴
        XCTAssertEqual(b[0].pos.x, 20, accuracy: 0.01)   // 적분엔 매 스텝 +10
    }

    func testRemapValueEx_blendWindowScalesEffect() {
        // multiplysize min==max=2, blendin 0→0.5: n=0.25 → w=0.5 → factor 1.5; n=0.5 → w=1 → factor 2.
        let spec = RemapSpec(verb: .multiplySize, input: .lifetimeFraction, operation: .remap,
                             transform: nil, octaves: 3, inputScale: 1,
                             outMin: Vec3(x: 2, y: 2, z: 2), outMax: Vec3(x: 2, y: 2, z: 2),
                             blendInStart: 0, blendInEnd: 0.5, blendOutStart: 0, blendOutEnd: 0,
                             inputCP0: 0, inputCP1: 1, outputCP0: 0, outputCP1: 1, component: 0)
        var sim = ParticleSimulator(def: makeDef(lifetime: 1, operators: [.remapValueEx(spec: spec)]), seed: 24)
        let a = sim.step(0.25)                   // n 0.25 → w 0.5 → size 4×1.5
        XCTAssertEqual(a[0].size, 6, accuracy: 0.01)
        let b = sim.step(0.25)                   // n 0.5 → w 1 → size 4×2
        XCTAssertEqual(b[0].size, 8, accuracy: 0.01)
    }

    // MARK: - 3. controlpointattract deletethreshold

    func testDeleteThresholdParse() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],
         "operator":[{"name":"controlpointattract","scale":100,"threshold":12,"deletethreshold":1}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        XCTAssertTrue(def.operators.contains(
            .controlPointAttract(scale: 100, threshold: 12, target: Vec3(x: 0, y: 0, z: 0), deleteThreshold: true)))
    }

    func testDeleteThreshold_deletesWithinThreshold_legacyKeepsResiding() {
        let near = Emitter.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 5, y: 0, z: 0),
                               rate: 0, burst: 4)   // 전원 dist ≤ 5 < threshold 10
        // 키 보유: 근접 전원 삭제.
        var simDel = ParticleSimulator(
            def: makeDef(emitters: [near], operators: [
                .controlPointAttract(scale: 0, threshold: 10, target: Vec3(x: 0, y: 0, z: 0), deleteThreshold: true)]),
            seed: 31)
        _ = simDel.step(0.1)
        XCTAssertEqual(simDel.liveCount, 0)
        // 키 부재(기존 경로 무회귀): 영구 잔류.
        var simKeep = ParticleSimulator(
            def: makeDef(emitters: [near], operators: [
                .controlPointAttract(scale: 0, threshold: 10, target: Vec3(x: 0, y: 0, z: 0))]),
            seed: 31)
        for _ in 0..<5 { _ = simKeep.step(0.1) }
        XCTAssertEqual(simKeep.liveCount, 4)
    }

    // MARK: - 4. vortex 확장 / vortex_v2 ring

    func testVortexExtendedKeysParse() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],
         "operator":[{"name":"vortex","centerforce":50,"variablestrength":2,
                      "reductioninner":10,"reductionouter":20}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        guard case let .vortex(_, _, _, _, _, _, cf, vs, ri, ro, ring) = def.operators.first else {
            return XCTFail("vortex 가 파스되어야 한다")
        }
        XCTAssertEqual(cf, 50)
        XCTAssertEqual(vs, 2)        // 파스·보존(의미 보류)
        XCTAssertEqual(ri, 10)       // 파스·보존(의미 보류)
        XCTAssertEqual(ro, 20)       // 파스·보존(의미 보류)
        XCTAssertNil(ring)
    }

    func testVortexV2RingParse() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],
         "operator":[{"name":"vortex_v2","speedinner":30,"ringradius":120,"ringpulldistance":300,
                      "ringpullforce":80,"ringwidth":24}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        guard case let .vortex(_, _, _, sIn, sOut, _, _, _, _, _, ring) = def.operators.first else {
            return XCTFail("vortex_v2 가 vortex 매핑되어야 한다")
        }
        XCTAssertEqual(sIn, 30); XCTAssertEqual(sOut, 30)   // speedouter 부재 = inner 승계(F631)
        XCTAssertEqual(ring, VortexRing(radius: 120, pullDistance: 300, pullForce: 80, width: 24))
    }

    func testVortexCenterForcePullsTowardAxis() {
        // 축 z, 중심 원점, 접선 속도 0, centerforce 100 — (100,0,0) 파티클은 −x(축 방향)로 가속.
        let op = ParticleOperator.vortex(axis: Vec3(x: 0, y: 0, z: 1),
                                         distanceInner: 0, distanceOuter: 0,
                                         speedInner: 0, speedOuter: 0,
                                         offset: Vec3(x: 0, y: 0, z: 0), centerForce: 100)
        let def = makeDef(emitters: [.box(origin: Vec3(x: 100, y: 0, z: 0),
                                          distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 0, burst: 1)],
                          maxCount: 4, operators: [op])
        var sim = ParticleSimulator(def: def, seed: 41)
        let a = sim.step(0.1)
        XCTAssertEqual(a[0].vel.x, -10, accuracy: 0.001)   // centerForce·dt
        XCTAssertEqual(a[0].pos.x, 99, accuracy: 0.01)     // 축을 향해 이동
    }

    func testVortexRingPullsIntoBandAndLeavesBandAlone() {
        func ringSim(originX: Float) -> ParticleSimulator {
            let op = ParticleOperator.vortex(axis: Vec3(x: 0, y: 0, z: 1),
                                             distanceInner: 0, distanceOuter: 0,
                                             speedInner: 0, speedOuter: 0,
                                             offset: Vec3(x: 0, y: 0, z: 0),
                                             ring: VortexRing(radius: 50, pullDistance: 100,
                                                              pullForce: 200, width: 10))
            return ParticleSimulator(
                def: makeDef(emitters: [.box(origin: Vec3(x: originX, y: 0, z: 0),
                                             distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 0, burst: 1)],
                             maxCount: 4, operators: [op]),
                seed: 42)
        }
        var outside = ringSim(originX: 100)                 // 링 바깥(δ=+50>5, 범위 내) → 안쪽으로
        let a = outside.step(0.1)
        XCTAssertEqual(a[0].vel.x, -20, accuracy: 0.001)
        var inside = ringSim(originX: 20)                   // 링 안쪽(δ=−30) → 바깥쪽으로
        let b = inside.step(0.1)
        XCTAssertEqual(b[0].vel.x, 20, accuracy: 0.001)
        var inBand = ringSim(originX: 52)                   // 대역 내(|δ|=2 ≤ width/2=5) → 묵영향
        let c = inBand.step(0.1)
        XCTAssertEqual(c[0].vel.x, 0, accuracy: 0.001)
    }

    // MARK: - 5. rope/ropetrail 렌더러 키(모델 노출 전용 — 렌더 소비 보류)

    func testRopeRenderOptionsParse() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],
         "renderer":[{"name":"ropetrail","length":2,"fadealpha":0.5,"fadesize":0.2,"uvscale":2,
                      "uvscrolling":1.5,"uvsmoothing":1,"segments":8}],
         "maxcount":10}
        """), material: nil)
        let opts = def.ropeOptions
        XCTAssertEqual(opts?.fadeAlpha, 0.5)
        XCTAssertEqual(opts?.fadeSize, 0.2)
        XCTAssertEqual(opts?.uvScale, 2)
        XCTAssertEqual(opts?.uvScrolling, 1.5)
        XCTAssertEqual(opts?.uvSmoothing, true)
        XCTAssertEqual(opts?.segments, 8)

        // 키 부재 rope → nil(기본값 미확정 — 보존 전용). sprite 는 대상 아님.
        let bare = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"rope","subdivision":4}],"maxcount":10}
        """), material: nil)
        XCTAssertNil(bare.ropeOptions)
        let sprite = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"sprite","fadealpha":0.5}],"maxcount":10}
        """), material: nil)
        XCTAssertNil(sprite.ropeOptions)
    }

    // MARK: - 6. positionoffsetrandom + 파스 전용 이니셜라이저

    func testPositionOffsetRandomParseAndDistribution() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":0,"instantaneous":32}],
         "initializer":[{"name":"positionoffsetrandom","offsetmin":"0 -2 0","offsetmax":"10 2 0"}],
         "renderer":[{"name":"sprite"}],"maxcount":32}
        """), material: nil)
        XCTAssertTrue(def.initializers.contains(
            .positionOffsetRandom(offsetMin: Vec3(x: 0, y: -2, z: 0), offsetMax: Vec3(x: 10, y: 2, z: 0))))
        var sim = ParticleSimulator(def: def, seed: 51)
        let ps = sim.step(0.1)
        XCTAssertEqual(ps.count, 32)
        var minX = Float.greatestFiniteMagnitude, maxX: Float = 0
        for p in ps {
            XCTAssertGreaterThanOrEqual(p.pos.x, 0); XCTAssertLessThanOrEqual(p.pos.x, 10)
            XCTAssertGreaterThanOrEqual(p.pos.y, -2); XCTAssertLessThanOrEqual(p.pos.y, 2)
            XCTAssertEqual(p.pos.z, 0)
            minX = min(minX, p.pos.x); maxX = max(maxX, p.pos.x)
        }
        XCTAssertGreaterThan(maxX - minX, 1)   // 실제 분포(단일값 아님)
    }

    func testEventLinkedInitializersParseOnly_simIgnores() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":0,"instantaneous":2}],
         "initializer":[{"name":"inheritcontrolpointvelocity","controlpoint":3,"scale":0.5},
                        {"name":"inheritinitialvaluefromevent","value":"size"},
                        {"name":"inheritvaluefromevent"},
                        {"name":"remapinitialvalue","output":"size","min":0,"max":2}],
         "renderer":[{"name":"sprite"}],"maxcount":4}
        """), material: nil)
        XCTAssertTrue(def.initializers.contains(.inheritControlPointVelocity(controlPoint: 3, scale: 0.5)))
        XCTAssertTrue(def.initializers.contains(.inheritValueFromEvent(name: "inheritinitialvaluefromevent",
                                                                       valueName: "size")))
        XCTAssertTrue(def.initializers.contains(.inheritValueFromEvent(name: "inheritvaluefromevent",
                                                                       valueName: nil)))
        XCTAssertTrue(def.initializers.contains(.remapInitialValue(output: "size",
                                                                   min: Vec3(x: 0, y: 0, z: 0),
                                                                   max: Vec3(x: 2, y: 2, z: 2))))
        // 시뮬은 무시(이벤트 시스템 연동 보류) — 스폰/스텝 정상, 무드로.
        var sim = ParticleSimulator(def: def, seed: 52)
        let ps = sim.step(0.1)
        XCTAssertEqual(ps.count, 2)
    }

    // MARK: - 7. hsvcolorrandom 확장

    func testHsvExtendedKeysParse() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],
         "initializer":[{"name":"hsvcolorrandom","huemin":0,"huemax":1,"huesteps":4,
                         "huenoise":0.1,"saturationnoise":0.2,"valuenoise":0.3}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        guard case let .hsvColorRandom(_, _, _, _, _, _, steps, hn, sn, vn) = def.initializers.first else {
            return XCTFail("hsvcolorrandom 가 파스되어야 한다")
        }
        XCTAssertEqual(steps, 4)
        XCTAssertEqual(hn, 0.1, accuracy: 1e-6)
        XCTAssertEqual(sn, 0.2, accuracy: 1e-6)
        XCTAssertEqual(vn, 0.3, accuracy: 1e-6)
    }

    func testHsvHueSteps_discreteHuesOnly() {
        // hue 0..0.5, steps 2 → hue ∈ {0, 0.5} → 빨강(1,0,0)/시안(0,1,1) 두 색만.
        let def = makeDef(emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0),
                                          distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 0, burst: 32)],
                          initializers: [.hsvColorRandom(hueMin: 0, hueMax: 0.5, satMin: 1, satMax: 1,
                                                         valMin: 1, valMax: 1, hueSteps: 2)],
                          maxCount: 32)
        var sim = ParticleSimulator(def: def, seed: 61)
        let ps = sim.step(0.1)
        XCTAssertEqual(ps.count, 32)
        var sawRed = false, sawCyan = false
        for p in ps {
            let isRed = simd_distance(p.color, SIMD3<Float>(1, 0, 0)) < 0.01
            let isCyan = simd_distance(p.color, SIMD3<Float>(0, 1, 1)) < 0.01
            XCTAssertTrue(isRed || isCyan, "huesteps=2 는 이산 2색만 허용 — got \(p.color)")
            sawRed = sawRed || isRed; sawCyan = sawCyan || isCyan
        }
        XCTAssertTrue(sawRed && sawCyan)
    }

    func testHsvNoise_deterministicAndSpatiallyVarying() {
        // huenoise 보유: rng 대신 스폰 위치 노이즈 — 같은 시드/같은 def → 비트동일, 위치 따라 변화.
        func run() -> [SIMD3<Float>] {
            let def = makeDef(emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0),
                                              distanceMax: Vec3(x: 100, y: 100, z: 0), rate: 0, burst: 32)],
                              initializers: [.hsvColorRandom(hueMin: 0, hueMax: 1, satMin: 1, satMax: 1,
                                                             valMin: 1, valMax: 1, hueNoise: 0.05)],
                              maxCount: 32)
            var sim = ParticleSimulator(def: def, seed: 62)
            return sim.step(0.1).map { $0.color }
        }
        let a = run(), b = run()
        XCTAssertEqual(a, b)                                  // 결정적(위치 노이즈)
        XCTAssertGreaterThan(Set(a.map { "\($0)" }).count, 1) // 전 파티클 동일색 아님
    }

    // MARK: - 8. 무키 씬 무회귀(비트동일)

    /// 새 키가 없는 레거시 def — 같은 시드 두 실행이 비트동일(RNG 드로 순서 불변의 빌드 내 증명;
    /// 빌드 간 비트동일은 기존 ParticleSimulator/ParticleSystem 스위트의 정확값 단언 무수정 통과가 입증).
    func testLegacySceneWithoutNewKeys_bitwiseDeterministic() {
        func run() -> [[Float]] {
            let def = makeDef(emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0),
                                              distanceMax: Vec3(x: 50, y: 50, z: 0), rate: 50, burst: 5)],
                              initializers: [.velocityRandom(min: Vec3(x: -10, y: -10, z: 0),
                                                             max: Vec3(x: 10, y: 10, z: 0)),
                                             .hsvColorRandom(hueMin: 0, hueMax: 1, satMin: 1, satMax: 1,
                                                             valMin: 1, valMax: 1)],
                              maxCount: 200,
                              operators: [.movement(gravity: Vec3(x: 0, y: -20, z: 0), drag: 0),
                                          .remapValue(output: .velocity(min: Vec3(x: -5, y: -30, z: 0),
                                                                        max: Vec3(x: 5, y: -10, z: 0)),
                                                      fbm: true, inputScale: 8),
                                          .controlPointAttract(scale: -100, threshold: 20,
                                                               target: Vec3(x: 0, y: 0, z: 0)),
                                          .vortex(axis: Vec3(x: 0, y: 0, z: 1), distanceInner: 10,
                                                  distanceOuter: 100, speedInner: 50, speedOuter: 10,
                                                  offset: Vec3(x: 0, y: 0, z: 0))])
            var sim = ParticleSimulator(def: def, seed: 99)
            var out: [[Float]] = []
            for _ in 0..<10 {
                out.append(sim.step(0.033).flatMap {
                    [$0.pos.x, $0.pos.y, $0.pos.z, $0.vel.x, $0.vel.y, $0.size, $0.alpha,
                     $0.color.x, $0.color.y, $0.color.z, $0.rotation.z]
                })
            }
            return out
        }
        XCTAssertEqual(run(), run())
    }
}
