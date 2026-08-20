import XCTest
import simd
@testable import WapleCore

/// G-C2-01(오퍼레이터 미구현) 중 **바이너리로 완전히 고정된 둘**:
/// `capvelocity`(실물 VM op 0x12 @0x1402446fd, 주입기 0x1401bfab0) ·
/// `reducemovementnearcontrolpoint`(op 0x0d @0x14024268f, ctor 0x1401cd1bd–0x1401cd407,
/// 주입기 0x1401be810). 나머지(boids·maintaindistance* 2종·충돌 5종·operator 자리
/// inheritvaluefromevent)는 이 커밋 범위 밖 — 아래 마지막 테스트가 그 사실을 못박는다.
final class ParticleCapVelocityReduceTests: XCTestCase {

    private func makeDef(initializers extraInits: [Initializer] = [],
                         operators extra: [ParticleOperator] = [],
                         lifetime: Float = 100) -> ParticleSystemDef {
        ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
                            rate: 0, burst: 1)],
            initializers: [.lifetimeRandom(min: lifetime, max: lifetime),
                           .sizeRandom(min: 1, max: 1),
                           .alphaRandom(min: 1, max: 1, exponent: 1)] + extraInits,
            operators: extra,
            renderer: .sprite, maxCount: 16, startTime: 0, material: nil)
    }

    // MARK: - capvelocity

    /// 주입기 0x1401bfab0 은 `maxspeed` **부재에만** 100 을 심는다(0x1404928f8; 월드 단위 경로는
    /// 1.0 @0x140492704). 명시값은 그대로 통과.
    func testCapVelocityParse_injectsMaxSpeed100WhenAbsent() {
        let absent = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"sprite"}],
         "operator":[{"name":"capvelocity"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(absent.operators, [.capVelocity(maxSpeed: 100)])

        // 동봉 thunderbolt_child_spawner 저작값(blendin* 는 G-C2-03 몫이라 여기선 파스만 통과).
        let explicit = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"sprite"}],
         "operator":[{"name":"capvelocity","maxspeed":50,"blendinstart":0.2,"blendinend":0.2}],
         "maxcount":10}
        """), material: nil)
        XCTAssertEqual(explicit.operators, [.capVelocity(maxSpeed: 50)])
    }

    /// `s = min(1, maxspeed/|v|)` — 상한 초과분만 방향 보존 축소, 미만은 무동작.
    func testCapVelocityClampsMagnitudeAndPreservesDirection() {
        let fast = ParticleSimulatorProbe.velocityAfterOneStep(
            def: makeDef(initializers: [.velocityRandom(min: Vec3(x: 300, y: 400, z: 0),
                                                        max: Vec3(x: 300, y: 400, z: 0))],
                         operators: [.capVelocity(maxSpeed: 100)]), seed: 11)
        XCTAssertEqual(simd_length(fast), 100, accuracy: 0.01)     // |v|=500 → 100
        XCTAssertEqual(fast.x / fast.y, 300.0 / 400.0, accuracy: 1e-4)   // 방향 보존

        let slow = ParticleSimulatorProbe.velocityAfterOneStep(
            def: makeDef(initializers: [.velocityRandom(min: Vec3(x: 30, y: 40, z: 0),
                                                        max: Vec3(x: 30, y: 40, z: 0))],
                         operators: [.capVelocity(maxSpeed: 100)]), seed: 11)
        XCTAssertEqual(slow.x, 30, accuracy: 1e-4)                 // |v|=50 ≤ 100 → 산술 무변화
        XCTAssertEqual(slow.y, 40, accuracy: 1e-4)
    }

    /// 상한은 **movement 뒤**다 — 중력이 상한을 넘기면 같은 스텝에서 다시 잘린다.
    func testCapVelocityAppliesAfterMovementGravity() {
        let v = ParticleSimulatorProbe.velocityAfterOneStep(
            def: makeDef(operators: [.movement(gravity: Vec3(x: 0, y: -1000, z: 0), drag: 0),
                                     .capVelocity(maxSpeed: 100)]), seed: 12)
        XCTAssertEqual(simd_length(v), 100, accuracy: 0.01)        // 1000·1s = 1000 → 100
    }

    // MARK: - reducemovementnearcontrolpoint

    /// 주입기 0x1401be810: controlpoint=0(정수) · distanceinner=100 · distanceouter=350 ·
    /// reductioninner=100(0x140492840) · reductionouter=0. CP 는 attract 와 같은 자리에서 굽는다.
    func testReduceMovementParse_injectedDefaultsAndControlPointBake() {
        let bare = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"sprite"}],
         "operator":[{"name":"reducemovementnearcontrolpoint"}],
         "controlpoint":[{"id":0,"offset":"7 8 9"},{"id":1,"offset":"50 0 0"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(bare.operators, [.reduceMovementNearControlPoint(
            distanceInner: 100, distanceOuter: 350, reductionInner: 100, reductionOuter: 0,
            target: Vec3(x: 7, y: 8, z: 9))])                      // 키 부재 = CP0 바인딩

        // 동봉 thunderbolt.json 의 두 번째 인스턴스(controlpoint:1) 저작값.
        let cp1 = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"sprite"}],
         "operator":[{"name":"reducemovementnearcontrolpoint","controlpoint":1,
                      "distanceinner":20,"distanceouter":50,"reductioninner":1000}],
         "controlpoint":[{"id":0,"offset":"0 0 0"},{"id":1,"offset":"0 -450 0"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(cp1.operators, [.reduceMovementNearControlPoint(
            distanceInner: 20, distanceOuter: 50, reductionInner: 1000, reductionOuter: 0,
            target: Vec3(x: 0, y: -450, z: 0))])
    }

    /// 램프: `t = clamp01((|p−cp| − distIn)·1/(distOut−distIn))`, `r = clamp01((redIn + t·Δred)·dt)`,
    /// `v ×= (1−r)`. distIn 안쪽은 r=redIn·dt, distOut 바깥은 r=redOut·dt.
    func testReduceMovementFreezesInsideAndIsInertOutside() {
        // thunderbolt 값(inner 20 / outer 50 / redIn 1000 / redOut 0), CP 는 원점.
        let op = ParticleOperator.reduceMovementNearControlPoint(
            distanceInner: 20, distanceOuter: 50, reductionInner: 1000, reductionOuter: 0,
            target: Vec3(x: 0, y: 0, z: 0))

        // 스폰 위치 = 원점(=CP) → 첫 스텝에서 r = min(1, 1000·dt) = 1 → 속도 완전 정지.
        let inside = ParticleSimulatorProbe.velocityAfterOneStep(
            def: makeDef(initializers: [.velocityRandom(min: Vec3(x: 100, y: 0, z: 0),
                                                        max: Vec3(x: 100, y: 0, z: 0))],
                         operators: [op]), seed: 13, dt: 1.0 / 60)
        XCTAssertEqual(simd_length(inside), 0, accuracy: 1e-5)

        // CP 를 멀리 두면(파티클은 원점) |p−cp| = 400 > outer → t=1 → r = redOut·dt = 0 → 무동작.
        let outside = ParticleSimulatorProbe.velocityAfterOneStep(
            def: makeDef(initializers: [.velocityRandom(min: Vec3(x: 100, y: 0, z: 0),
                                                        max: Vec3(x: 100, y: 0, z: 0))],
                         operators: [.reduceMovementNearControlPoint(
                             distanceInner: 20, distanceOuter: 50, reductionInner: 1000,
                             reductionOuter: 0, target: Vec3(x: 400, y: 0, z: 0))]), seed: 13,
            dt: 1.0 / 60)
        XCTAssertEqual(outside.x, 100, accuracy: 1e-4)
    }

    /// 중간대 선형 램프 — inner 0 / outer 100 / redIn 0 / redOut 60 이면 |p−cp|=50 에서
    /// r = (0 + 0.5·60)·dt = 30·(1/60) = 0.5 → v ×= 0.5.
    func testReduceMovementLinearRampBetweenInnerAndOuter() {
        let v = ParticleSimulatorProbe.velocityAfterOneStep(
            def: makeDef(initializers: [.velocityRandom(min: Vec3(x: 100, y: 0, z: 0),
                                                        max: Vec3(x: 100, y: 0, z: 0))],
                         operators: [.reduceMovementNearControlPoint(
                             distanceInner: 0, distanceOuter: 100, reductionInner: 0,
                             reductionOuter: 60, target: Vec3(x: 50, y: 0, z: 0))]), seed: 14,
            dt: 1.0 / 60)
        XCTAssertEqual(v.x, 50, accuracy: 0.05)
    }

    /// 퇴화 케이스 재현. ctor 0x1401cd38d 는 `distanceouter == distanceinner` 이면 `rcpps` 대신
    /// **xmm15** 를 역폭에 심고(0x1401cd3a7 `movaps xmm0, xmm15`), 0x1401cd3b9 는
    /// `reductionouter == reductioninner` 이면 델타에 0 이 아니라 1.0 을 심는다(0x140492704).
    ///
    /// **그 xmm15 는 −0.0 이 아니라 (1,1,1,1) 이다.** 오퍼레이터 루프 프리헤더 0x1401cb184 가
    /// `movdqa xmm15, [0x140492e30]`(=1,1,1,1)을 심고, 백에지(0x1401cc476 → 0x1401cb1a0)가 그
    /// 값을 유지한다. 같은 함수 앞쪽 **이미터** 구간의 `movss xmm15, [0x140492ff0]`(=−0.0,
    /// 0x1401c5bac)은 프리헤더가 덮어써 죽고, `movaps xmm15, [rsp+0x2230]`(0x1401cc4a0)은
    /// **루프가 끝난 뒤**의 복원이다(0x1401c552b 프롤로그 저장과 짝). 자매 원소 vortex 의 같은
    /// 분기(0x1401cdcd1)도 같은 xmm15 를 읽고 그쪽은 이미 1.0 로 고쳐져 있다.
    ///
    /// 그래서 퇴화 폭은 "t 를 0 으로 죽인다" 가 아니라 **inner 에서 시작하는 폭 1 램프**다.
    /// 종전 −0.0 모델은 세 지점 전부 50 을 내므로, 이 세 값이 그 모델을 배제한다.
    /// redIn 30 · redOut 0 · dt 1/60 · v₀ 100:
    ///   len 0      → t 0    → r = 30/60 = 0.5   → 50
    ///   len 10.5   → t 0.5  → r = 15/60 = 0.25  → 75
    ///   len 9999   → t 1    → r = 0             → 100
    func testReduceMovementDegenerateRangeIsUnitWidthRamp() {
        func velX(targetX: Float) -> Float {
            ParticleSimulatorProbe.velocityAfterOneStep(
                def: makeDef(initializers: [.velocityRandom(min: Vec3(x: 100, y: 0, z: 0),
                                                            max: Vec3(x: 100, y: 0, z: 0))],
                             operators: [.reduceMovementNearControlPoint(
                                 distanceInner: 10, distanceOuter: 10, reductionInner: 30,
                                 reductionOuter: 0, target: Vec3(x: targetX, y: 0, z: 0))]), seed: 15,
                dt: 1.0 / 60).x
        }
        XCTAssertEqual(velX(targetX: 0), 50, accuracy: 0.05, "inner 안쪽 — t=0, redIn 이 걸린다")
        XCTAssertEqual(velX(targetX: 10.5), 75, accuracy: 0.05, "폭 1 램프의 한가운데 — t=0.5")
        XCTAssertEqual(velX(targetX: 9999), 100, accuracy: 0.05, "inner+1 바깥 — t=1, redOut(0) 이라 무동작")
    }

    // MARK: - 아직 드롭되는 나머지(범위 못박기)

    // MARK: - maintaindistancebetweencontrolpoints

    /// 키는 둘뿐이고 주입 기본은 start=0 / end=1 이다(주입기 0x1401be5d0 — `mov [rax], r14`(r14=0)
    /// @0x1401be5f1 · `mov qword [rax], 1` @0x1401be71a). 클램프는 **부호 없는** `cmp eax,7 / jae`
    /// 라 음수도 7 이 된다(0x1401ccfed · 0x1401cd0c1).
    func testMaintainDistanceBetweenControlPointsParsesKeysAndDefaults() {
        let d0 = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"sprite"}],
         "operator":[{"name":"maintaindistancebetweencontrolpoints"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(d0.operators, [.maintainDistanceBetweenControlPoints(start: 0, end: 1)])

        let d1 = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"sprite"}],
         "operator":[{"name":"maintaindistancebetweencontrolpoints",
                      "controlpointstart":2,"controlpointend":-1}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(d1.operators, [.maintainDistanceBetweenControlPoints(start: 2, end: 7)],
                       "음수는 부호 없는 비교로 7 이 된다")
    }

    /// 기하: 두 CP 를 잇는 선분의 **축 성분만** [0, L] 로 가두고 수직 성분은 보존한다.
    /// 배치는 동봉 `presets/lightning/…/thunderbolt.json` 실물 그대로 — CP0 (0,0,0), CP1 (0,−450,0).
    func testMaintainDistanceBetweenControlPointsClampsAlongSegmentOnly() {
        func run(_ start: SIMD3<Float>, cp1: Vec3) -> SIMD3<Float> {
            var def = ParticleSystemDef(
                emitters: [.box(origin: Vec3(x: start.x, y: start.y, z: start.z),
                                distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000, burst: 0)],
                initializers: [.lifetimeRandom(min: 1000, max: 1000)],
                operators: [.maintainDistanceBetweenControlPoints(start: 0, end: 1)],
                renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
            def.controlPoints[0] = Vec3(x: 0, y: 0, z: 0)
            def.controlPoints[1] = cp1
            var sim = ParticleSimulator(def: def, seed: 3)
            return sim.step(1.0 / 60.0)[0].pos
        }
        let far = Vec3(x: 0, y: -450, z: 0)
        XCTAssertEqual(run(SIMD3(0, 100, 0), cp1: far), SIMD3(0, 0, 0), "선분 앞쪽 밖 → 시작점")
        XCTAssertEqual(run(SIMD3(0, -600, 0), cp1: far), SIMD3(0, -450, 0), "선분 뒤쪽 밖 → 끝점")
        XCTAssertEqual(run(SIMD3(50, -200, 0), cp1: far), SIMD3(50, -200, 0),
                       "선분 안이면 수직 오프셋까지 그대로 — 회전시키지 않는다")
        // 퇴화 선분은 스킵한다(실물 `comiss` vs 2⁻⁴⁶ @0x1402421ff). 동봉
        // `thunderbolt_beam_child` 가 CP0 ≡ CP1 ≡ 원점이라 정확히 이 경로다.
        XCTAssertEqual(run(SIMD3(0, 100, 0), cp1: Vec3(x: 0, y: 0, z: 0)), SIMD3(0, 100, 0),
                       "퇴화 선분은 무변화")
    }

    /// G-C2-01 잔여 9종은 이 커밋에서 손대지 않는다 — 파스가 여전히 드롭(연산자 0개)함을 고정해
    /// 다음 라운드가 이 테스트를 깨며 들어오게 한다.
    func testRemainingUnsupportedOperatorsStillDropped() {
        // **[2026-08-20]** `maintaindistancetocontrolpoint` 와 `boids` 를 목록에서 뺐다 — 둘 다 착지했다.
        // `collisionbox` 는 남긴다: WE 자신이 no-op 이라(opcode 0x17 핸들러가 VM 의 명령어 전진
        // 라벨) 구현하면 오히려 원본과 어긋난다.
        // **[2026-08-20 섹션 오귀속 정정]** `inheritvaluefromevent` 도 뺐다 — 드롭이 맞는 동작이
        // 아니라 **잘못된 섹션에 있어서** 드롭됐던 것이다. 이 이름은 오퍼레이터이므로 이제
        // `ParticleOperator.inheritValueFromEvent` 로 보존된다(시뮬은 여전히 무시). 이 테스트와
        // ParticleExtendedKeysTests 가 서로 반대 섹션을 못박고 있었고, 이쪽이 옳았다.
        // **[2026-08-20]** `maintaindistancebetweencontrolpoints` 도 뺐다 — 착지했다(위 두 테스트).
        for name in ["collisionplane", "collisionsphere", "collisionbox", "collisionbounds",
                     "collisionquad", "collisionmodel"] {
            let d = ParticleSystemDef.parse(json("""
            {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"sprite"}],
             "operator":[{"name":"\(name)"}],"maxcount":10}
            """), material: nil)
            XCTAssertTrue(d.operators.isEmpty, "\(name) 는 아직 드롭 대상")
        }
    }
}

/// 첫 스텝 뒤 0번 파티클의 저장 속도만 꺼내는 얇은 프로브(테스트 가독성용).
enum ParticleSimulatorProbe {
    static func velocityAfterOneStep(def: ParticleSystemDef, seed: UInt64,
                                     dt: Float = 1.0) -> SIMD3<Float> {
        var sim = ParticleSimulator(def: def, seed: seed)
        let out = sim.step(dt)
        precondition(!out.isEmpty, "파티클이 방출되지 않았다")
        return out[0].vel
    }
}
