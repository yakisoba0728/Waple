import XCTest
import simd
@testable import WapleCore

final class ParticleSimulatorTests: XCTestCase {
    /// 결정적 스폰을 위한 def: box 이미터(distanceMax 0 → 정확히 origin), 고정 속도/수명.
    private func linearDef(velocity: Vec3 = Vec3(x: 10, y: 0, z: 0),
                           lifetime: Float = 100, maxCount: Int = 1,
                           gravity: Vec3 = Vec3(x: 0, y: 0, z: 0), drag: Float = 0,
                           operators extra: [ParticleOperator] = []) -> ParticleSystemDef {
        ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: lifetime, max: lifetime),
                           .sizeRandom(min: 5, max: 5),
                           .velocityRandom(min: velocity, max: velocity),
                           .alphaRandom(min: 1, max: 1, exponent: 1)],
            operators: [.movement(gravity: gravity, drag: drag)] + extra,
            renderer: .sprite, maxCount: maxCount, startTime: 0, material: nil)
    }

    func testMovementTrajectory() {
        var sim = ParticleSimulator(def: linearDef(), seed: 1)
        let a = sim.step(1.0)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].pos.x, 10, accuracy: 0.001)  // spawn@0 → integrate vel*1
        XCTAssertEqual(a[0].pos.y, 0, accuracy: 0.001)
        let b = sim.step(1.0)
        XCTAssertEqual(b[0].pos.x, 20, accuracy: 0.001)
    }

    func testVelocityInitializerMovesWithoutMovementOperator() {
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100),
                           .velocityRandom(min: Vec3(x: 10, y: 0, z: 0), max: Vec3(x: 10, y: 0, z: 0))],
            operators: [], renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
        var sim = ParticleSimulator(def: def, seed: 1)

        let parts = sim.step(1.0)

        XCTAssertEqual(parts[0].pos.x, 10, accuracy: 0.001)
    }

    func testMultipleMovementOperatorsIntegratePositionOnce() {
        let def = linearDef(operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0)])
        var sim = ParticleSimulator(def: def, seed: 1)

        let parts = sim.step(1.0)

        XCTAssertEqual(parts[0].pos.x, 10, accuracy: 0.001)
    }

    func testGravityAccelerates() {
        var sim = ParticleSimulator(def: linearDef(velocity: Vec3(x: 0, y: 0, z: 0), gravity: Vec3(x: 0, y: -10, z: 0)), seed: 2)
        let a = sim.step(1.0)            // vel.y = -10, pos.y = -10
        XCTAssertEqual(a[0].pos.y, -10, accuracy: 0.001)
        let b = sim.step(1.0)            // vel.y = -20, pos.y = -30
        XCTAssertEqual(b[0].pos.y, -30, accuracy: 0.001)
    }

    func testMaxCountCap() {
        var sim = ParticleSimulator(def: linearDef(lifetime: 100, maxCount: 5), seed: 3)
        for _ in 0..<20 { let parts = sim.step(0.1); XCTAssertLessThanOrEqual(parts.count, 5) }
        XCTAssertEqual(sim.liveCount, 5)
    }

    func testCullInvariant() {
        // 수명 1, 계속 방출 — 항상 age<=lifetime 이어야(컬 동작 증명).
        var sim = ParticleSimulator(def: linearDef(lifetime: 1, maxCount: 10), seed: 4)
        for _ in 0..<60 {
            let parts = sim.step(0.1)
            XCTAssertTrue(parts.allSatisfy { $0.age <= $0.lifetime + 1e-4 })
        }
    }

    func testAlphaFadeIn() {
        // fadeInTime=1(전체 수명), lifetime=10 → age=5(n=0.5)에서 alpha≈0.5.
        var sim = ParticleSimulator(def: linearDef(velocity: Vec3(x: 0, y: 0, z: 0), lifetime: 10, maxCount: 1,
                                                   operators: [.alphaFade(fadeInTime: 1, fadeOutTime: 0)]), seed: 5)
        var last: [Particle] = []
        for _ in 0..<5 { last = sim.step(1.0) }  // age = 5
        XCTAssertEqual(last[0].age, 5, accuracy: 0.001)
        XCTAssertEqual(last[0].alpha, 0.5, accuracy: 0.02)
    }

    func testSizeChange() throws {
        // initialSize 5, startValue 0.2 → endValue 1.0 over life(10). n=0.5 → mult 0.6 → size 3.
        var sim = ParticleSimulator(def: linearDef(velocity: Vec3(x: 0, y: 0, z: 0), lifetime: 10, maxCount: 1,
                                                   operators: [.sizeChange(startTime: 0, startValue: 0.2, endValue: 1)]), seed: 6)
        let a = sim.step(0.01)  // acc=0.01*1000=10 → 1 spawn; n≈0 → size≈5*0.2=1
        XCTAssertEqual(a[0].size, 1.0, accuracy: 0.1)
        var last: [Particle] = []
        for _ in 0..<50 { last = sim.step(0.1) }  // age≈5.01, n≈0.5
        let s = try XCTUnwrap(last.first)
        XCTAssertEqual(s.age, 5.01, accuracy: 0.05)
        XCTAssertEqual(s.size, 3.0, accuracy: 0.15)
    }

    func testChangeIntervalsUseNormalizedLifetime() {
        let operators: [ParticleOperator] = [
            .sizeChange(startTime: 0.2, startValue: 0.2, endValue: 0.8, endTime: 0.6),
            .colorChange(startTime: 0.2,
                         startValue: Vec3(x: 1, y: 0.5, z: 0.25),
                         endValue: Vec3(x: 0.2, y: 1, z: 0.75),
                         endTime: 0.6),
            .alphaChange(startTime: 0.2, endTime: 0.6, startValue: 1, endValue: 0),
        ]
        var short = ParticleSimulator(def: linearDef(velocity: Vec3(x: 0, y: 0, z: 0),
                                                      lifetime: 10, operators: operators), seed: 7)
        var long = ParticleSimulator(def: linearDef(velocity: Vec3(x: 0, y: 0, z: 0),
                                                     lifetime: 20, operators: operators), seed: 7)

        let a = short.step(4)[0]
        let b = long.step(8)[0]
        for p in [a, b] {
            XCTAssertEqual(p.size, 2.5, accuracy: 1e-5)
            XCTAssertEqual(p.color.x, 0.6, accuracy: 1e-5)
            XCTAssertEqual(p.color.y, 0.75, accuracy: 1e-5)
            XCTAssertEqual(p.color.z, 0.5, accuracy: 1e-5)
            XCTAssertEqual(p.alpha, 0.5, accuracy: 1e-5)
        }
    }

    func testChangeEndTimeBeyondLifetimeRemainsIncompleteAtDeath() {
        let operators: [ParticleOperator] = [
            .sizeChange(startTime: 0, startValue: 1, endValue: 0, endTime: 2),
            .colorChange(startTime: 0,
                         startValue: Vec3(x: 1, y: 1, z: 1),
                         endValue: Vec3(x: 0, y: 0, z: 0),
                         endTime: 2),
            .alphaChange(startTime: 0, endTime: 2, startValue: 1, endValue: 0),
        ]
        var sim = ParticleSimulator(def: linearDef(velocity: Vec3(x: 0, y: 0, z: 0),
                                                    lifetime: 10, operators: operators), seed: 8)

        let p = sim.step(10)[0]
        XCTAssertEqual(p.size, 2.5, accuracy: 1e-5)
        XCTAssertEqual(p.color.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(p.color.y, 0.5, accuracy: 1e-5)
        XCTAssertEqual(p.color.z, 0.5, accuracy: 1e-5)
        XCTAssertEqual(p.alpha, 0.5, accuracy: 1e-5)
    }

    func testChangeZeroLengthIntervalStepsAtStart() {
        let operators: [ParticleOperator] = [
            .sizeChange(startTime: 0.5, startValue: 1, endValue: 0.2, endTime: 0.5),
            .colorChange(startTime: 0.5,
                         startValue: Vec3(x: 1, y: 1, z: 1),
                         endValue: Vec3(x: 0.2, y: 0.3, z: 0.4),
                         endTime: 0.5),
            .alphaChange(startTime: 0.5, endTime: 0.5, startValue: 1, endValue: 0.25),
        ]
        var sim = ParticleSimulator(def: linearDef(velocity: Vec3(x: 0, y: 0, z: 0),
                                                    lifetime: 10, operators: operators), seed: 9)

        let before = sim.step(4)[0]
        XCTAssertEqual(before.size, 5, accuracy: 1e-5)
        XCTAssertEqual(before.color.x, 1, accuracy: 1e-5)
        XCTAssertEqual(before.alpha, 1, accuracy: 1e-5)

        let at = sim.step(1)[0]
        XCTAssertEqual(at.size, 1, accuracy: 1e-5)
        XCTAssertEqual(at.color.x, 0.2, accuracy: 1e-5)
        XCTAssertEqual(at.color.y, 0.3, accuracy: 1e-5)
        XCTAssertEqual(at.color.z, 0.4, accuracy: 1e-5)
        XCTAssertEqual(at.alpha, 0.25, accuracy: 1e-5)
    }

    func testChangeReverseIntervalUsesSignedSpan() {
        let op = ParticleOperator.sizeChange(startTime: 0.8, startValue: 1, endValue: 0, endTime: 0.2)
        var sim = ParticleSimulator(def: linearDef(velocity: Vec3(x: 0, y: 0, z: 0),
                                                    lifetime: 10, operators: [op]), seed: 10)

        XCTAssertEqual(sim.step(1)[0].size, 0, accuracy: 1e-5)
        XCTAssertEqual(sim.step(4)[0].size, 2.5, accuracy: 1e-5)
        XCTAssertEqual(sim.step(3)[0].size, 5, accuracy: 1e-5)
    }

    func testMultipleChangeOperatorsMultiplyAllFactors() {
        let operators: [ParticleOperator] = [
            .sizeChange(startTime: 0, startValue: 0.5, endValue: 0.5),
            .sizeChange(startTime: 0, startValue: 0.4, endValue: 0.4),
            .colorChange(startTime: 0,
                         startValue: Vec3(x: 0.5, y: 0.8, z: 0.6),
                         endValue: Vec3(x: 0.5, y: 0.8, z: 0.6)),
            .colorChange(startTime: 0,
                         startValue: Vec3(x: 0.4, y: 0.5, z: 0.25),
                         endValue: Vec3(x: 0.4, y: 0.5, z: 0.25)),
            .alphaChange(startTime: 0, endTime: 1, startValue: 0.5, endValue: 0.5),
            .alphaChange(startTime: 0, endTime: 1, startValue: 0.4, endValue: 0.4),
        ]
        var sim = ParticleSimulator(def: linearDef(velocity: Vec3(x: 0, y: 0, z: 0),
                                                    lifetime: 10, operators: operators), seed: 11)

        let p = sim.step(0.01)[0]
        XCTAssertEqual(p.size, 1, accuracy: 1e-5)
        XCTAssertEqual(p.color.x, 0.2, accuracy: 1e-5)
        XCTAssertEqual(p.color.y, 0.4, accuracy: 1e-5)
        XCTAssertEqual(p.color.z, 0.15, accuracy: 1e-5)
        XCTAssertEqual(p.alpha, 0.2, accuracy: 1e-5)
    }

    func testDeterministic() {
        let def = linearDef(velocity: Vec3(x: 3, y: 7, z: 0), maxCount: 50)
        var a = ParticleSimulator(def: def, seed: 99)
        var b = ParticleSimulator(def: def, seed: 99)
        for _ in 0..<30 {
            let pa = a.step(0.1), pb = b.step(0.1)
            XCTAssertEqual(pa.count, pb.count)
            if let x = pa.first, let y = pb.first {
                XCTAssertEqual(x.pos.x, y.pos.x, accuracy: 1e-5)
                XCTAssertEqual(x.age, y.age, accuracy: 1e-5)
            }
        }
    }

    // MARK: - 트레일 히스토리 / 힘 오퍼레이터

    private func trailDef(renderer: RendererKind, velocity: Vec3 = Vec3(x: 100, y: 0, z: 0),
                          operators extra: [ParticleOperator] = [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0)]) -> ParticleSystemDef {
        ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100), .sizeRandom(min: 5, max: 5),
                           .velocityRandom(min: velocity, max: velocity), .alphaRandom(min: 1, max: 1, exponent: 1)],
            operators: extra, renderer: renderer, maxCount: 1, startTime: 0, material: nil)
    }

    func testTrailHistoryAccumulatesAndCaps() {
        // rope → 16 샘플. 이동하는 파티클의 히스토리가 궤적을 따라 쌓이고 상한에서 클램프.
        var sim = ParticleSimulator(def: trailDef(renderer: .rope(subdivision: 0)), seed: 1)
        var last: [Particle] = []
        for _ in 0..<30 { last = sim.step(1.0 / 30.0) }
        let p = last[0]
        XCTAssertEqual(p.history.count, 16)                 // 상한 클램프
        // oldest→newest 정렬, 마지막=현재 위치.
        XCTAssertEqual(p.history.last!.x, p.pos.x, accuracy: 1e-4)
        XCTAssertLessThan(p.history.first!.x, p.history.last!.x)  // 이동 방향(+x) 으로 단조 증가
    }

    func testSpriteRendererHasNoHistory() {
        var sim = ParticleSimulator(def: trailDef(renderer: .sprite), seed: 1)
        var last: [Particle] = []
        for _ in 0..<10 { last = sim.step(0.1) }
        XCTAssertTrue(last[0].history.isEmpty)  // 스프라이트는 히스토리 미기록
    }

    func testStepZeroDoesNotDuplicateHistory() {
        var sim = ParticleSimulator(def: trailDef(renderer: .rope(subdivision: 0)), seed: 1)
        _ = sim.step(1.0 / 30.0)
        let a = sim.step(1.0 / 30.0)[0].history.count
        let b = sim.step(0)[0].history.count   // step(0) 는 히스토리 미기록
        XCTAssertEqual(a, b)
    }

    func testControlPointAttractPullsTowardTarget() {
        // 대상=원점, 파티클을 +x 로 스폰(velocityrandom 로 이동해 원점에서 멀어짐) 대신
        // 원점에서 velocity 0, scale>0 인력 → 원점에 붙어 있으면 힘 0. 오프셋 스폰이 필요하므로
        // box origin 을 x=100 에 두고 대상=0(기본) → -x 로 당겨져야.
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 100, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100)],
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0),
                        .controlPointAttract(scale: 1000, threshold: 0, target: Vec3(x: 0, y: 0, z: 0))],
            renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
        var sim = ParticleSimulator(def: def, seed: 1)
        var last: [Particle] = []
        for _ in 0..<10 { last = sim.step(0.05) }
        XCTAssertLessThan(last[0].vel.x, 0)       // 원점(-x) 방향으로 가속
        XCTAssertLessThan(last[0].pos.x, 100)     // 실제로 원점 쪽으로 이동
    }

    func testControlPointAttractRepelsWithNegativeScale() {
        // scale<0 → 대상에서 밀려남(원점 근처 스폰 → +로 밀림). 유계(속도 상한 미붕괴).
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 10, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100)],
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0),
                        .controlPointAttract(scale: -800, threshold: 64, target: Vec3(x: 0, y: 0, z: 0))],
            renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
        var sim = ParticleSimulator(def: def, seed: 1)
        var last: [Particle] = []
        for _ in 0..<50 { last = sim.step(0.05) }
        XCTAssertGreaterThan(last[0].pos.x, 10)                    // 대상에서 멀어짐(+x)
        XCTAssertLessThan(simd_length(last[0].vel), 5001)         // 속도 상한으로 유계
        XCTAssertFalse(last[0].pos.x.isNaN)
    }

    func testVortexAddsTangentialVelocity() {
        // z축 소용돌이, 중심=원점, x=50 에 스폰(반경 50). speedInner=200 → +y 접선(axis×radial).
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 50, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100)],
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0),
                        .vortex(axis: Vec3(x: 0, y: 0, z: 1), distanceInner: 0, distanceOuter: 0,
                                speedInner: 200, speedOuter: 0, offset: Vec3(x: 0, y: 0, z: 0))],
            renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
        var sim = ParticleSimulator(def: def, seed: 1)
        let a = sim.step(0.05)
        XCTAssertGreaterThan(a[0].vel.y, 0)  // cross(z, +x) = +y → 접선 속도 +y
    }

    // MARK: - 난류(turbulence)

    /// 정적 파티클(vel 0, gravity 0)에 turbulence 만 작용 — 이류 격리용. origin 은 격자 밖(0.25,0.25) 좌표.
    private func turbDef(speedMin: Float = 100, speedMax: Float = 100, scale: Float = 0.01, timeScale: Float = 0,
                         mask: Vec3 = Vec3(x: 1, y: 1, z: 1), phaseMin: Float = 0, phaseMax: Float = 0,
                         origin: Vec3 = Vec3(x: 25, y: 25, z: 0), maxCount: Int = 1) -> ParticleSystemDef {
        ParticleSystemDef(
            emitters: [.box(origin: origin, distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: 1000, max: 1000)],
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0),
                        .turbulence(speedMin: speedMin, speedMax: speedMax, scale: scale, timeScale: timeScale,
                                    mask: mask, phaseMin: phaseMin, phaseMax: phaseMax)],
            renderer: .sprite, maxCount: maxCount, startTime: 0, material: nil)
    }

    func testTurbulenceMovesStaticParticle() {
        // vel/gravity 0 → turbulence 만이 유일한 이동원(ember 실물 패턴). 위치가 스폰에서 벗어나야.
        var sim = ParticleSimulator(def: turbDef(speedMin: 100, speedMax: 100), seed: 1)
        var last: [Particle] = []
        for _ in 0..<30 { last = sim.step(1.0 / 30.0) }
        let d = simd_length(last[0].pos - SIMD3<Float>(25, 25, 0))
        XCTAssertGreaterThan(d, 1.0)  // 눈에 띄게 이동
        XCTAssertFalse(last[0].pos.x.isNaN)
    }

    func testTurbulenceZeroSpeedIsNoOp() {
        var sim = ParticleSimulator(def: turbDef(speedMin: 0, speedMax: 0), seed: 1)
        var last: [Particle] = []
        for _ in 0..<30 { last = sim.step(1.0 / 30.0) }
        XCTAssertEqual(last[0].pos.x, 25, accuracy: 1e-4)  // 이동 없음
        XCTAssertEqual(last[0].pos.y, 25, accuracy: 1e-4)
    }

    func testTurbulenceMaskGatesAxes() {
        // mask (1,0,0) → x 만 섭동, y·z 는 스폰값 유지(ember mask "1 0 0" 실물).
        var sim = ParticleSimulator(def: turbDef(speedMin: 150, speedMax: 150, mask: Vec3(x: 1, y: 0, z: 0)), seed: 2)
        var last: [Particle] = []
        for _ in 0..<30 { last = sim.step(1.0 / 30.0) }
        XCTAssertEqual(last[0].pos.y, 25, accuracy: 1e-4)   // y 고정
        XCTAssertEqual(last[0].pos.z, 0, accuracy: 1e-4)    // z 고정
        XCTAssertNotEqual(last[0].pos.x, 25, accuracy: 0.5) // x 이동
    }

    func testTurbulenceDeterministic() {
        let def = turbDef(speedMin: 50, speedMax: 200, timeScale: 50, phaseMin: 2, phaseMax: 8, maxCount: 20)
        var a = ParticleSimulator(def: def, seed: 42)
        var b = ParticleSimulator(def: def, seed: 42)
        for _ in 0..<40 {
            let pa = a.step(1.0 / 30.0), pb = b.step(1.0 / 30.0)
            XCTAssertEqual(pa.count, pb.count)
            if let x = pa.first, let y = pb.first {
                XCTAssertEqual(x.pos.x, y.pos.x, accuracy: 1e-6)
                XCTAssertEqual(x.pos.y, y.pos.y, accuracy: 1e-6)
            }
        }
    }

    func testTurbulenceBoundedBySpeed() {
        // 이류는 vel 에 누적하지 않음 → 총 변위 ≤ speed·√3·T. 폭주/NaN 없음(유계성 증명).
        let speed: Float = 300, T: Float = 5.0
        var sim = ParticleSimulator(def: turbDef(speedMin: speed, speedMax: speed, timeScale: 200), seed: 3)
        var last: [Particle] = []
        let steps = 150
        for _ in 0..<steps { last = sim.step(T / Float(steps)) }
        let disp = simd_length(last[0].pos - SIMD3<Float>(25, 25, 0))
        XCTAssertLessThanOrEqual(disp, speed * sqrtf(3) * T * 1.01)
        XCTAssertFalse(last[0].pos.x.isNaN)
        XCTAssertFalse(last[0].pos.y.isNaN)
    }

    func testTurbulenceSpeedScalesDisplacement() {
        // 짧은 구간(경로 발산 전)에서 큰 speed → 큰 변위(파라미터 영향 증명).
        func disp(_ s: Float) -> Float {
            var sim = ParticleSimulator(def: turbDef(speedMin: s, speedMax: s), seed: 7)
            var last: [Particle] = []
            for _ in 0..<3 { last = sim.step(1.0 / 30.0) }
            return simd_length(last[0].pos - SIMD3<Float>(25, 25, 0))
        }
        XCTAssertGreaterThan(disp(500), disp(20))
    }

    func testColorNormalization() {
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100), .colorRandom(min: Vec3(x: 255, y: 0, z: 0), max: Vec3(x: 255, y: 0, z: 0))],
            operators: [], renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
        var sim = ParticleSimulator(def: def, seed: 7)
        let a = sim.step(0.1)
        XCTAssertEqual(a[0].color.x, 1.0, accuracy: 0.001)  // 255/255
        XCTAssertEqual(a[0].color.y, 0.0, accuracy: 0.001)
    }

    /// colorrandom 은 단일 난수 t 로 3채널 동시 보간(min→max 직선). min=(255,0,0)→max=(0,255,0)
    /// 이면 모든 파티클이 c.x+c.y==1, c.z==0 (채널독립 박스였다면 합이 1 에서 벗어난다).
    func testColorRandomSingleTStaysOnLine() {
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100),
                           .colorRandom(min: Vec3(x: 255, y: 0, z: 0), max: Vec3(x: 0, y: 255, z: 0))],
            operators: [], renderer: .sprite, maxCount: 64, startTime: 0, material: nil)
        var sim = ParticleSimulator(def: def, seed: 99)
        let ps = sim.step(0.1)
        XCTAssertGreaterThan(ps.count, 4)
        for p in ps {
            XCTAssertEqual(p.color.x + p.color.y, 1.0, accuracy: 0.001)   // min→max 직선 위
            XCTAssertEqual(p.color.z, 0.0, accuracy: 0.001)
        }
    }

    // MARK: - oscillatealpha (F184/F189/F190)

    /// 자매 oscillateSize 와 동형 직접보간 — peak=scaleMax, trough=scaleMin(구 감산식
    /// "1-scale*osc" 대비: peak 는 항상 1 로 고정되고 trough 만 scale 로 눌리는 비대칭 수식이었다).
    func testOscillateAlphaLerpsBetweenScaleMinAndMax() {
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100), .alphaRandom(min: 1, max: 1, exponent: 1)],
            operators: [.oscillateAlpha(frequencyMin: 2, frequencyMax: 2, scaleMin: 0.2, scaleMax: 0.9)],
            renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
        var sim = ParticleSimulator(def: def, seed: 3)
        var minA: Float = 1, maxA: Float = 0
        for _ in 0..<120 {   // 2Hz·1.2s ≥ 2 주기(랜덤 위상과 무관하게 극값을 커버)
            let ps = sim.step(0.01)
            if let a = ps.first?.alpha { minA = min(minA, a); maxA = max(maxA, a) }
        }
        XCTAssertEqual(minA, 0.2, accuracy: 0.02, "trough 는 scaleMin")
        XCTAssertEqual(maxA, 0.9, accuracy: 0.02, "peak 는 scaleMax")
    }

    /// F189 종단검증: 파서 기본값(scalemin 0, scalemax 1)이 시뮬까지 살아남아 0..1 전 구간을
    /// 진동해야 한다(WE 데모: frequency 만 지정해도 가시 트윙클).
    func testOscillateAlphaScaleOmittedDefaultsStillOscillate() {
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100), .alphaRandom(min: 1, max: 1, exponent: 1)],
            operators: [.oscillateAlpha(frequencyMin: 2, frequencyMax: 2, scaleMin: 0, scaleMax: 1)],
            renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
        var sim = ParticleSimulator(def: def, seed: 4)
        var minA: Float = 1, maxA: Float = 0
        for _ in 0..<120 {
            let ps = sim.step(0.01)
            if let a = ps.first?.alpha { minA = min(minA, a); maxA = max(maxA, a) }
        }
        XCTAssertLessThan(minA, 0.05, "0 근접까지 어두워져야")
        XCTAssertGreaterThan(maxA, 0.95, "1 근접까지 밝아져야")
    }
}
