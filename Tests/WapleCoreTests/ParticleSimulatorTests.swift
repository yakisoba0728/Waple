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
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000)],
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

    func testColorNormalization() {
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000)],
            initializers: [.lifetimeRandom(min: 100, max: 100), .colorRandom(min: Vec3(x: 255, y: 0, z: 0), max: Vec3(x: 255, y: 0, z: 0))],
            operators: [], renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
        var sim = ParticleSimulator(def: def, seed: 7)
        let a = sim.step(0.1)
        XCTAssertEqual(a[0].color.x, 1.0, accuracy: 0.001)  // 255/255
        XCTAssertEqual(a[0].color.y, 0.0, accuracy: 0.001)
    }
}
