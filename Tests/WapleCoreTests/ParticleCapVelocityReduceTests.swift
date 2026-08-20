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

    /// 퇴화 케이스 재현: ctor 0x1401cd38d 는 outer==inner 에 역폭 −0.0(= t 항상 0)을 심고,
    /// 0x1401cd3b9 는 redOut==redIn 에 델타 0 이 아니라 **1.0** 을 심는다. 후자는 t 가 0 으로
    /// 죽어 있으면 관측되지 않으므로, 여기선 전자만(= r = redIn·dt) 확인한다.
    func testReduceMovementDegenerateRangeUsesInnerReductionEverywhere() {
        let v = ParticleSimulatorProbe.velocityAfterOneStep(
            def: makeDef(initializers: [.velocityRandom(min: Vec3(x: 100, y: 0, z: 0),
                                                        max: Vec3(x: 100, y: 0, z: 0))],
                         operators: [.reduceMovementNearControlPoint(
                             distanceInner: 10, distanceOuter: 10, reductionInner: 30,
                             reductionOuter: 0, target: Vec3(x: 9999, y: 0, z: 0))]), seed: 15,
            dt: 1.0 / 60)
        XCTAssertEqual(v.x, 50, accuracy: 0.05)     // 거리 무관 r = 30/60 = 0.5
    }

    // MARK: - 아직 드롭되는 나머지(범위 못박기)

    /// G-C2-01 잔여 9종은 이 커밋에서 손대지 않는다 — 파스가 여전히 드롭(연산자 0개)함을 고정해
    /// 다음 라운드가 이 테스트를 깨며 들어오게 한다.
    func testRemainingUnsupportedOperatorsStillDropped() {
        // **[2026-08-20]** `maintaindistancetocontrolpoint` 와 `boids` 를 목록에서 뺐다 — 둘 다 착지했다.
        // `collisionbox` 는 남긴다: WE 자신이 no-op 이라(opcode 0x17 핸들러가 VM 의 명령어 전진
        // 라벨) 구현하면 오히려 원본과 어긋난다.
        for name in ["maintaindistancebetweencontrolpoints",
                     "collisionplane", "collisionsphere", "collisionbox", "collisionbounds",
                     "collisionquad", "collisionmodel", "inheritvaluefromevent"] {
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
