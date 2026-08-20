import XCTest
import simd
@testable import WapleCore

/// 파티클 확장 키(wallpaper64.exe 스트링 테이블 정본 대조 갭):
/// periodic 방출(@0x48f3c0–0x48f4b8), remapvalue 전어휘(@0x491e78–0x4920b0 — 입력 소스
/// 0x491e78–0x491f60 과 출력 동사 0x491fd0–0x4920b0 이 인접),
/// controlpointattract deletethreshold(RVA **0x48f988**), vortex 확장/vortex_v2 ring
/// (centerforce **0x48f9f8** · ring **0x48faa8/0x48fab8/0x48fad0/0x48fae0**),
/// — [2026-08-20] 종전 주소(0x48e788·0x48e7c8–0x48e8e0)는 전부 포그·카메라 키를 가리켰다.
/// rope/ropetrail 렌더러 키(@0x48fbb0–0x48fc18),
/// hsvcolorrandom huesteps/노이즈 3종(@0x48f5c0–0x48f5e0).
///
/// **[2026-08-20 2차 정정 — 범위의 끝이 안 고쳐져 있었다]** 위 네 범위는 `0c54f3b` 의 일괄
/// 정정이 **시작만** RVA 로 옮기고 끝을 파일 오프셋으로 남겨 둔 것이었다 — 시작 `0x48f3c0`
/// 에 끝 `0x48e2b8` 이 붙어 **시작 > 끝** 인 성립 불가능한 범위가 됐다(두 주소를 나란히 적으면
/// 아래 게이트가 이 문장 자체를 위반으로 잡으므로 일부러 떼어 쓴다 — 인용된 옛값과 진짜 인용이
/// 구별되지 않는 것이 애초에 일괄 정정을 망친 함정이다). 그 검사기가 단일 주소만 보게 돼 있어
/// 아무도 안 잡았다 —
/// 이제 `scripts/spec/check_address_ranges.py` 가 이 산술 불변식을 매 푸시 강제한다.
///
/// **[2026-08-20 귀속 정정]** 종전에 여기 적혀 있던 `positionoffsetrandom(@0x48f580/398)` 은
/// 틀렸다. 그 두 주소는 `offsetmin`/`offsetmax` 이고 **`layerimage` 이미터의 키**다(`adf9674`).
/// `positionoffsetrandom` 의 실제 키는 scale·distance·timescale·directions·sign·octaves 이며
/// 균일난수 오프셋이 아니라 fBm 노이즈 변위다 — `Initializer.positionOffsetRandom` 주석 참조.
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

        // **[2026-08-20 정정] `maxtoemitperperiod` 단독이면 duration 2/3 · delay 1/2 다.**
        // 종전 1/1·0/0 은 "중립값" 추정이었고, 그 사이에 내가 "주입 없음(전부 0)" 으로 한 번 더
        // 틀렸다. 다섯 키 전부 주입 대상이다 — 이미터 주입기 진입 0x1401b8df0 의 꼬리
        // 0x1401b907d-0x1401b90f5 가 2.0/3.0/1.0/2.0 을 심고 maxtoemitperperiod 는 정수 0 이다.
        // 실물 도달 0: 주기 키를 쓰는 이미터 5건이 네 min/max 를 전건 명시한다.
        let partial = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"sphererandom","rate":1,"maxtoemitperperiod":6}],
         "renderer":[{"name":"sprite"}],"maxcount":100}
        """), material: nil)
        let q = partial.emitterPeriodic[0]
        XCTAssertEqual(q?.durationMin, 2); XCTAssertEqual(q?.durationMax, 3)
        XCTAssertEqual(q?.delayMin, 1); XCTAssertEqual(q?.delayMax, 2)
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

    /// 페이드 창의 **활성화 게이트와 퇴화 구간**을 못박는다(G-C2-03).
    /// 종전 구현엔 게이트가 없었고 `blendinend <= blendinstart` 를 통째로 건너뛰었다.
    func testBlendWindowGateAndDegenerateRamp() {
        // 기본값 0/0/1/1 → 첫 조건 `(bie > 0.01 || bos < 0.99)` 에서 탈락 → 가중 없음(w ≡ 1).
        let dflt = BlendWindow(inStart: 0, inEnd: 0, outStart: 1, outEnd: 1)
        XCTAssertFalse(dflt.active, "0x1401c2deb–0x1401c2e33 게이트")
        XCTAssertEqual(dflt.weight(lifeFraction: 0), 1)
        XCTAssertEqual(dflt.weight(lifeFraction: 0.5), 1)
        XCTAssertEqual(dflt.weight(lifeFraction: 1), 1)

        // 동봉 `thunderbolt_child_spawner` 의 capvelocity: blendin 0.2/0.2 = 퇴화 구간.
        // 실물은 `inStart = min(0.2, 0.2 − 1e-4)` 로 클램프해 **하드 스텝**을 만든다.
        // 종전 구현은 `bie > bis` 가 거짓이라 in 램프를 통째로 건너뛰어 w ≡ 1 이었다.
        let step = BlendWindow(inStart: 0.2, inEnd: 0.2, outStart: 1, outEnd: 1)
        XCTAssertTrue(step.active, "bie 0.2 > 0.01 이고 bos − bie = 0.8 > 0.01")
        XCTAssertEqual(step.weight(lifeFraction: 0.1), 0, accuracy: 1e-5, "스텝 이전은 0")
        XCTAssertEqual(step.weight(lifeFraction: 0.3), 1, accuracy: 1e-5, "스텝 이후는 1")

        // 세 번째 파라미터는 outStart 가 아니라 **outEnd** 다 — 여기를 틀리면 페이드아웃이 뒤집힌다.
        let fade = BlendWindow(inStart: 0, inEnd: 0, outStart: 0.5, outEnd: 1)
        XCTAssertTrue(fade.active, "bos 0.5 < 0.99")
        XCTAssertEqual(fade.weight(lifeFraction: 0.5), 1, accuracy: 1e-4, "페이드아웃 시작점")
        XCTAssertEqual(fade.weight(lifeFraction: 0.75), 0.5, accuracy: 1e-4, "절반")
        XCTAssertEqual(fade.weight(lifeFraction: 1.0), 0, accuracy: 1e-4, "끝점")
    }

    /// 파스 기본값이 0/0/**1**/**1** 인지 — 종전엔 넷 다 0 이었다.
    func testRemapBlendDefaultsAreZeroZeroOneOne() {
        let d = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"remapvalue","output":"multiplysize"}],"maxcount":10}
        """), material: nil)
        guard case let .remapValueEx(spec) = d.operators[0] else { return XCTFail("no remapvalue") }
        XCTAssertEqual(spec.blendInStart, 0); XCTAssertEqual(spec.blendInEnd, 0)
        XCTAssertEqual(spec.blendOutStart, 1, "0x1401c2c26 movabs 1.0")
        XCTAssertEqual(spec.blendOutEnd, 1, "0x140492778 f64 1.0")
        XCTAssertFalse(spec.blendWindow.active, "기본값은 게이트를 통과하지 않는다")
    }

    func testRemapValueEx_blendWindowScalesEffect() {
        // multiplysize min==max=2, blendin 0→0.5: n=0.25 → w=0.5 → factor 1.5; n=0.5 → w=1 → factor 2.
        let spec = RemapSpec(verb: .multiplySize, input: .lifetimeFraction, operation: .remap,
                             transform: nil, octaves: 3, inputScale: 1,
                             outMin: Vec3(x: 2, y: 2, z: 2), outMax: Vec3(x: 2, y: 2, z: 2),
                             // **[2026-08-20]** out 쪽 기본은 0 이 아니라 **1.0** 이다. 0/0 으로 두면
                             // 실물에선 `outEnd = 0 + 1e-4` 라 수명 거의 전체가 페이드아웃 뒤가 되어
                             // w 가 항상 0 이 된다 — 종전 기본값이 만든 비현실적 픽스처였다.
                             blendInStart: 0, blendInEnd: 0.5, blendOutStart: 1, blendOutEnd: 1,
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
        // 키 보유 **+ flags bit0**: 근접 전원 삭제.
        // **[2026-08-20 계약 정정]** 삭제는 키만으로 켜지지 않는다 — 실물은 `flags & 1`
        // (0x14024193d)을 지나야 삭제 패스를 돈다. 주입 기본 flags 는 **2** 라 bit0 이 없고,
        // 동봉 35인스턴스 중 flags 를 적는 것도 `magic_vortex_orb`(0) 하나뿐이라
        // **실코퍼스에서는 삭제가 한 번도 일어나지 않는다**. 픽스처에 3(=bit0|bit1)을 명시한다.
        var simDel = ParticleSimulator(
            def: makeDef(emitters: [near], operators: [
                .controlPointAttract(scale: 0, threshold: 10, target: Vec3(x: 0, y: 0, z: 0),
                                     deleteThreshold: true, flags: 3)]),
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

        // flags 기본(2)이면 키가 있어도 삭제되지 않는다 — 게이트 자체를 못박는다.
        var simGated = ParticleSimulator(
            def: makeDef(emitters: [near], operators: [
                .controlPointAttract(scale: 0, threshold: 10, target: Vec3(x: 0, y: 0, z: 0),
                                     deleteThreshold: true)]),
            seed: 31)
        for _ in 0..<5 { _ = simGated.step(0.1) }
        XCTAssertEqual(simGated.liveCount, 4, "flags 기본 2 에는 bit0 이 없다")
    }

    /// 페이드 창이 **remapvalue 밖의 원소에도** 걸리는지. 대상 13종 중 실코퍼스 도달이 있는
    /// 넷(turbulence·capvelocity·oscillatealpha·oscillateposition)을 배선했다.
    /// 여기서는 `capvelocity` 로 확인한다 — 동봉 `thunderbolt_child_spawner` 가 그 경로다.
    func testBlendWindowAppliesToCapVelocity() {
        func speedAfter(blendIn: (Float, Float)?) -> Float {
            let blend = blendIn.map { #""blendinstart":\#($0.0),"blendinend":\#($0.1),"# } ?? ""
            let d = ParticleSystemDef.parse(json("""
            {"emitter":[{"name":"boxrandom","rate":0,"instantaneous":1}],
             "initializer":[{"name":"lifetimerandom","min":1,"max":1},
                            {"name":"velocityrandom","min":"100 0 0","max":"100 0 0"}],
             "operator":[{"name":"capvelocity",\(blend)"maxspeed":10}],
             "renderer":[{"name":"sprite"}],"maxcount":4}
            """), material: nil)
            var sim = ParticleSimulator(def: d, seed: 7)
            return sim.step(0.1)[0].vel.x     // n = 0.1
        }
        // 창 없음: 그대로 상한 10 으로 잘린다.
        XCTAssertEqual(speedAfter(blendIn: nil), 10, accuracy: 0.01)
        // blendin 0→1: n = 0.1 에서 w = 0.1 → s = 1 + 0.1·(0.1 − 1) = 0.91 → 100·0.91 = 91.
        // 창이 안 걸리면 10 이 나온다 — 그 차이가 이 테스트의 요지다.
        XCTAssertEqual(speedAfter(blendIn: (0, 1)), 91, accuracy: 0.5)
    }

    // MARK: - 4. vortex 확장 / vortex_v2 ring

    /// **네 키 모두 `vortex` 의 키가 아니다.** 각 문자열을 집는 `lea` 를 전 바이너리에서 전수로
    /// 보면: `centerforce`@0x14048f9f8 은 2곳(주입기 0x1401bf5f5 ∈ 0x1401bf2d0 = **vortex_v2**
    /// 주입기, ctor 0x1401ce07a ∈ vortex_v2 구간) — v1 주입기 0x1401bef00 에도 v1 ctor
    /// 0x1401cd8e6 에도 없다. `variablestrength`@0x14048fa08 은 주입기 0x1401be2a0 과 ctor
    /// 0x1401ccf0b, 즉 **maintaindistancetocontrolpoint** 전용이다. `reductioninner`@0x14048fa40 ·
    /// `reductionouter`@0x14048f9c8 은 주입기 0x1401be810 과 ctor 0x1401cd252/0x1401cd285,
    /// 즉 **reducemovementnearcontrolpoint** 전용이다.
    ///
    /// 종전엔 이 넷을 vortex 가 파스해 보존했고, `centerforce` 는 시뮬레이터가 실제로 **힘으로
    /// 썼다** — 주석은 "v1 에는 없다" 고 적어 놓고 코드가 키를 읽는 상태였다. 넷 다 들어내고,
    /// 이 테스트가 "적어도 WE 는 무시한다" 를 못박는다.
    func testVortexIgnoresKeysThatBelongToOtherElements() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],
         "operator":[{"name":"vortex","centerforce":50,"variablestrength":2,
                      "reductioninner":10,"reductionouter":20}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        guard case let .vortex(_, _, _, _, _, _, cf, ring, _) = def.operators.first else {
            return XCTFail("vortex 가 파스되어야 한다")
        }
        XCTAssertEqual(cf, 0, "centerforce 는 vortex_v2 의 키다 — v1 은 적혀 있어도 무시한다")
        XCTAssertNil(ring)
    }

    func testVortexV2RingParse() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],
         "operator":[{"name":"vortex_v2","speedinner":30,"flags":4,"ringradius":120,
                      "ringpulldistance":300,"ringpullforce":80,"ringwidth":24}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        guard case let .vortex(_, _, _, sIn, sOut, _, _, ring, _) = def.operators.first else {
            return XCTFail("vortex_v2 가 vortex 매핑되어야 한다")
        }
        XCTAssertEqual(sIn, 30)
        // **[2026-08-20 계약 정정]** 종전엔 `sOut == sIn`(승계)을 단언했는데 WE 에 그 규칙이 없다 —
        // 주입기가 0x1401bf5e0 `xorps xmm2,xmm2` 로 0.0 을 심고 플래그와도 무관하다.
        XCTAssertEqual(sOut, 0, "speedouter 부재 → 승계가 아니라 0.0")
        // ring 은 `flags & 4` 없이는 만들어지지 않는다(런타임 `test byte [r14+0x110],4` @0x1402434eb).
        // 그래서 픽스처에 flags:4 를 명시했다.
        XCTAssertEqual(ring, VortexRing(radius: 120, pullDistance: 300, pullForce: 80, width: 24))
    }

    /// **[2026-08-20 계약 전면 교체]** `centerforce` 는 "축을 향한 등가속 인력" 이 아니다.
    /// 실측(0x14024345c–0x140243988)은
    ///   `vel += radial(pos + vel·dt) · ((dist/|radial′| − 1) · centerforce/dt)`
    /// 로, `dist/dist′ − 1 ≈ −v_r·dt/dist` 이므로 **`Δv ≈ −centerforce · v_r · n`** —
    /// dt 가 상쇄되는 무차원 **반경속도 감쇠**다(매 스텝 `v_radial *= 1 − cf`).
    ///
    /// 종전 테스트는 정지한 파티클이 `−centerforce·dt` 로 가속된다고 단언했는데, 실물은
    /// 정지 입자(v = 0 → dist′ = dist)에 **아무 작용도 하지 않는다**. 그 단언이 통과하던 것은
    /// 구현과 테스트가 같은 오해를 공유했기 때문이다.
    func testVortexCenterForceDampsRadialVelocityNotAConstantPull() {
        func run(cf: Float, radialSpeed: Float) -> Float {
            let op = ParticleOperator.vortex(axis: Vec3(x: 0, y: 0, z: 1),
                                             distanceInner: 0, distanceOuter: 0,
                                             speedInner: 0, speedOuter: 0,
                                             offset: Vec3(x: 0, y: 0, z: 0), centerForce: cf)
            let def = makeDef(emitters: [.box(origin: Vec3(x: 100, y: 0, z: 0),
                                              distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 0, burst: 1)],
                              initializers: [.velocityRandom(min: Vec3(x: radialSpeed, y: 0, z: 0),
                                                             max: Vec3(x: radialSpeed, y: 0, z: 0))],
                              maxCount: 4, operators: [op])
            var sim = ParticleSimulator(def: def, seed: 41)
            return sim.step(0.1)[0].vel.x
        }
        // 정지 입자: 실물은 무작용. 종전 모델이면 −cf·dt = −10 이 나왔을 자리다.
        XCTAssertEqual(run(cf: 100, radialSpeed: 0), 0, accuracy: 1e-4,
                       "정지 입자에는 아무 작용도 하지 않는다")
        // 바깥으로 +50 으로 움직이는 입자에 cf = 1 → 반경 속도가 거의 완전히 죽는다.
        let damped = run(cf: 1, radialSpeed: 50)
        XCTAssertLessThan(damped, 50, "반경 속도가 줄어야 한다")
        // 손계산: dist 100, dist′ = |100 + 50·0.1| = 105 → (100/105 − 1)·1/0.1 = −0.47619,
        // delta = 105·(−0.47619) = −50 → vel 50 − 50 = **정확히 0**.
        XCTAssertEqual(damped, 0, accuracy: 0.01, "cf = 1 은 반경 속도를 통째로 죽인다(궤도 반경 고정)")
        // cf = 0.5 면 절반만 죽는다 — 감쇠 계수라는 것을 못박는다(등가속이면 cf 에 비례해 커진다).
        let half = run(cf: 0.5, radialSpeed: 50)
        // 같은 계산에 cf 0.5 → delta = −25 → vel 25. **cf 에 선형**이라는 게 감쇠 계수의 표식이다.
        XCTAssertEqual(half, 25, accuracy: 0.01, "cf 는 감쇠 비율이지 가속 크기가 아니다")
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

    /// 네 키는 **실수량이 아니라 불리언 체크박스**다(주입 태그 5, 소비는 비트 세팅). 동봉 자산도
    /// 전건 JSON 리터럴이다 — `uvscrolling: true` 8건 · `uvsmoothing: false` 12건 ·
    /// `fadealpha: true` 4건. 종전엔 `Float?` 라 `strictFloat(true)` 의 1.0 이 들어앉아
    /// "페이드량 1.0" 처럼 보였다.
    ///
    /// **렌더러마다 읽는 키가 다르다** — 각 키 문자열의 lea 를 세 핸들러 구간으로 갈라 확인했다:
    /// rope = subdivision·uvscale·uvscrolling·**uvsmoothing**, ropetrail = length·segments·
    /// subdivision·uvscale·uvscrolling·**fadealpha·fadesize**. 종전엔 여섯 키를 두 렌더러에
    /// 뭉뚱그려 읽었다.
    func testRopeRenderOptionsParse() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],
         "renderer":[{"name":"ropetrail","length":2,"fadealpha":true,"fadesize":true,"uvscale":2,
                      "uvscrolling":true,"segments":8}],
         "maxcount":10}
        """), material: nil)
        let opts = def.ropeOptions
        XCTAssertEqual(opts?.fadeAlpha, true)
        XCTAssertEqual(opts?.fadeSize, true)
        XCTAssertEqual(opts?.uvScale, 2)
        XCTAssertEqual(opts?.uvScrolling, true)
        XCTAssertEqual(opts?.segments, 8)

        // 부재는 "값 없음" 이 아니라 **엔진 기본값**이다 — 주입기가 심는다.
        // rope: uvsmoothing **true**(태그 5 값 1 @0x1401c0dd3) · uvscrolling false · uvscale 1.
        let bare = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"rope","subdivision":4}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(bare.ropeOptions?.uvSmoothing, true, "동봉 rope 부재 13/25 건이 이 값을 탄다")
        XCTAssertEqual(bare.ropeOptions?.uvScrolling, false)
        XCTAssertEqual(bare.ropeOptions?.uvScale, 1)
        // ropetrail: segments **4**(0x1401c119c, clamp [2,32]) · fade* false · uvscale 1.
        let bareTrail = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"ropetrail"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(bareTrail.ropeOptions?.segments, 4, "동봉 ropetrail 부재 14/18 건")
        XCTAssertEqual(bareTrail.ropeOptions?.fadeAlpha, false)
        XCTAssertEqual(bareTrail.ropeOptions?.fadeSize, false)
        // sprite/spritetrail 은 이 키들의 대상이 아니다.
        let sprite = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"sprite","fadealpha":true}],"maxcount":10}
        """), material: nil)
        XCTAssertNil(sprite.ropeOptions)
    }

    /// 렌더러 부재 기본값은 주입기 실측이다 — 종전엔 넷 다 0 이었다.
    ///   · spritetrail length 0.05(0x1401c0b55) · maxlength 10.0(0x1401c0c13) · minlength **미주입**
    ///   · rope subdivision 4(0x1401c0d00, clamp [0,32])
    ///   · ropetrail length 1.0(0x1401c10da, 하한 `maxss 0.001`) · subdivision 1(0x1401c128a)
    func testRendererDefaultsComeFromInjectorConstants() {
        func renderer(_ name: String) -> RendererKind {
            ParticleSystemDef.parse(json("""
            {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"\(name)"}],"maxcount":10}
            """), material: nil).renderer
        }
        guard case let .spriteTrail(maxLength, length, minLength) = renderer("spritetrail") else {
            return XCTFail("no spritetrail")
        }
        XCTAssertEqual(length, 0.05, accuracy: 1e-6, "0x1401c0b55 — 종전 0 은 신장을 항등으로 죽였다")
        XCTAssertEqual(maxLength, 10, accuracy: 1e-6, "0x1401c0c13")
        XCTAssertEqual(minLength, 0, "주입기에 minlength lea 가 없다 — 부재는 하한 없음")
        XCTAssertEqual(renderer("rope"), .rope(subdivision: 4), "0x1401c0d00")
        guard case let .ropeTrail(rtLength, rtSub) = renderer("ropetrail") else { return XCTFail("no ropetrail") }
        XCTAssertEqual(rtLength, 1, accuracy: 1e-6, "0x1401c10da")
        XCTAssertEqual(rtSub, 1, "0x1401c128a")
    }

    // MARK: - 6. positionoffsetrandom + 파스 전용 이니셜라이저

    /// `positionoffsetrandom` 은 **fBm 노이즈 변위**다 — 균일난수 오프셋이 아니다.
    ///
    /// **[2026-08-20 전면 정정]** 종전 픽스처는 `offsetmin`/`offsetmax` 를 넣고 그 범위 안에
    /// 분포하는지 봤다. 그 두 키는 이 원소의 것이 **아니라 `layerimage` 이미터**의 것이다 —
    /// 두 문자열(0x14048f580 / 0x14048f598)을 참조하는 `lea` 중 파서 쪽(0x1401c6ba7 / 0x1401c6cde)이
    /// 게이트 `stricmp` vs `"layerimage"`(0x1401c6ae4) 뒤 `speedmin`/`speedmax` 와 같은 블록에 있고,
    /// `positionoffsetrandom` 브랜치(게이트 0x1401c9041)에는 그 `lea` 가 하나도 없다.
    /// 즉 종전 테스트는 **WE 가 내보내지 않는 JSON 모양**을 회귀로 고정하고 있었다.
    func testPositionOffsetRandomParsesRealKeysWithInjectedDefaults() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":0,"instantaneous":8,"distancemax":"0 0 0"}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100},
                        {"name":"positionoffsetrandom","distance":100,"scale":0,"timescale":5}],
         "renderer":[{"name":"sprite"}],"maxcount":8}
        """), material: nil)
        // 생략한 세 키는 주입 기본값으로 뜬다 — directions "1 1 0"(직교 분기, 0x1401bb672–684),
        // sign "0 0 0", octaves 부재 0 → [1,8] 클램프로 1.
        XCTAssertTrue(def.initializers.contains(
            .positionOffsetRandom(directions: Vec3(x: 1, y: 1, z: 0), sign: Vec3(x: 0, y: 0, z: 0),
                                  scale: 0, distance: 100, timescale: 5, octaves: 1)),
            "\(def.initializers)")
    }

    /// `octaves` 클램프는 **부호 없는** 비교다 — `cmp eax,8 / jae → 8`(0x1401c9387) 이라 음수도 8.
    func testPositionOffsetRandomOctavesClampIsUnsigned() {
        func octaves(_ v: String) -> Int? {
            let d = ParticleSystemDef.parse(json("""
            {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"sprite"}],
             "initializer":[{"name":"positionoffsetrandom","octaves":\(v)}],"maxcount":4}
            """), material: nil)
            for i in d.initializers { if case let .positionOffsetRandom(_, _, _, _, _, o) = i { return o } }
            return nil
        }
        XCTAssertEqual(octaves("0"), 1, "부재/0 → 1")
        XCTAssertEqual(octaves("3"), 3)
        XCTAssertEqual(octaves("9"), 8, "8 이상은 8")
        XCTAssertEqual(octaves("-1"), 8, "부호 없는 비교라 음수도 8")
    }

    /// **RNG 를 한 번도 뽑지 않는다.** 핸들러 0x14023c09a–0x14023c3a1 전 구간에 난수 호출
    /// (0x1401f87a0)이 없다 — 노이즈 3회(0x14027b170)와 abs 2회(0x1401e2880)뿐이다.
    /// 종전 구현은 파티클당 3드로를 썼다. 뒤따르는 이니셜라이저의 결과가 **비트동일**한지로 본다.
    func testPositionOffsetRandomConsumesNoRandomDraws() {
        func sizes(withElement: Bool) -> [Float] {
            let inits = withElement
                ? #"[{"name":"lifetimerandom","min":1,"max":9},{"name":"positionoffsetrandom","distance":100,"timescale":5},{"name":"sizerandom","min":1,"max":9}]"#
                : #"[{"name":"lifetimerandom","min":1,"max":9},{"name":"sizerandom","min":1,"max":9}]"#
            let def = ParticleSystemDef.parse(json("""
            {"emitter":[{"name":"boxrandom","rate":0,"instantaneous":6,"distancemax":"0 0 0"}],
             "initializer":\(inits),"renderer":[{"name":"sprite"}],"maxcount":6}
            """), material: nil)
            var sim = ParticleSimulator(def: def, seed: 11)
            return sim.step(0.01).map { $0.initialSize }
        }
        XCTAssertEqual(sizes(withElement: true), sizes(withElement: false),
                       "이 원소가 난수를 소비하면 뒤 이니셜라이저 결과가 밀린다")
    }

    /// 변위가 실제로 생기고, 스폰 **시각**에 따라 달라진다(`timescale` 이 시간항을 돌린다).
    /// 종전 구현에서는 동봉 5건 전건이 `offsetmin`/`offsetmax` 를 갖지 않아 오프셋이 **정확히 0**
    /// 이었다 — 즉 이 원소가 시각적으로 통째로 죽어 있었다.
    func testPositionOffsetRandomDisplacesAndVariesWithSpawnTime() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","origin":"0 0 0","distancemax":"0 0 0","rate":50}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100},
                        {"name":"positionoffsetrandom","distance":100,"scale":0,"timescale":5}],
         "renderer":[{"name":"sprite"}],"maxcount":40}
        """), material: nil)
        var sim = ParticleSimulator(def: def, seed: 7)
        var last: [Particle] = []
        for _ in 0..<20 { last = sim.step(0.05) }
        XCTAssertGreaterThan(last.count, 10)
        let xs = last.map { $0.pos.x }
        XCTAssertGreaterThan(xs.map { abs($0) }.max() ?? 0, 1, "변위가 0 이면 안 된다")
        XCTAssertGreaterThan((xs.max() ?? 0) - (xs.min() ?? 0), 10,
                             "스폰 시각이 다르면 오프셋도 달라야 한다")
    }

    func testEventLinkedInitializersParseOnly_simIgnores() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":0,"instantaneous":2}],
         "initializer":[{"name":"inheritcontrolpointvelocity","controlpoint":3,"min":0.5},
                        {"name":"inheritinitialvaluefromevent","input":"setsize"},
                        {"name":"remapinitialvalue","output":"size","min":0,"max":2}],
         "operator":[{"name":"inheritvaluefromevent"}],
         "renderer":[{"name":"sprite"}],"maxcount":4}
        """), material: nil)
        // **[2026-08-20 키 정정]** `scale` 은 이 원소의 키가 아니다(유령 필드였다) — 주입기
        // 0x1401bad80 에도 핸들러 0x14023bc32 에도 "scale" 참조가 없다. 실물은 `min`(0.1)/`max`(0.2)
        // 로 **CP 속도에 곱할 균일 난수 배율의 범위**를 준다. 픽스처의 `scale` 을 `min` 으로 바꿨고,
        // `max` 는 생략해 주입 기본 0.2 가 뜨는지 함께 본다.
        XCTAssertTrue(def.initializers.contains(
            .inheritControlPointVelocity(controlPoint: 3, min: 0.5, max: 0.2)),
            "min 0.5 명시 · max 부재 → 주입 0.2 (0x1401baea3)")
        // **[2026-08-20 섹션 오귀속 정정]** 종전 픽스처는 두 이름을 **둘 다 `initializer[]`** 에
        // 넣고 둘 다 거기 들어오는지 단언했다 — WE 가 절대 내보내지 않는 JSON 모양을 회귀
        // 테스트로 고정하고 있었던 것이다. 실물 섹션은 갈린다(자산·로케일·x86 세 갈래 일치):
        //   inheritinitialvaluefromevent → initializer[]  게이트 stricmp@0x1401cb069
        //   inheritvaluefromevent        → operator[]     게이트 stricmp@0x1401cf157
        // 하위 키도 `value` 가 아니라 `input` 이고(0x1401cb09d/0x1401cf192), 주입 기본이 서로
        // 다르다 — setcolor(슬롯 0) vs setcoloropacity(슬롯 4).
        XCTAssertTrue(def.initializers.contains(.inheritInitialValueFromEvent(input: .setSize)),
                      "input:\"setsize\" → .setSize (매퍼 0x1402611f0 테이블 슬롯 8)")
        XCTAssertTrue(def.operators.contains(.inheritValueFromEvent(input: .setColorOpacity)),
                      "오퍼레이터이고, input 부재 시 주입 기본은 setcoloropacity (0x1401c0080 → 슬롯 4)")
        // 반대쪽 섹션에 넣으면 받지 않는다 — WE 가 내보내지 않는 모양이므로 드롭이 옳다.
        let wrongSection = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":0,"instantaneous":1}],
         "initializer":[{"name":"inheritvaluefromevent"}],
         "renderer":[{"name":"sprite"}],"maxcount":1}
        """), material: nil)
        XCTAssertTrue(wrongSection.initializers.isEmpty,
                      "operator 전용 이름을 initializer[] 에서 받으면 오귀속이 되돌아온 것이다")
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
