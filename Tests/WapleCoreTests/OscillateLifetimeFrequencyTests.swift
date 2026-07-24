import XCTest
import simd
@testable import WapleCore

/// F832 회귀: oscillate 계열(position/alpha/size) frequency 단위 = "수명당 진동 횟수"
/// (WE 공식 디자이너 문서 operator.html: "The minimum/maximum number of oscillations per
/// particle lifetime" — 3종 동일 문구). 종전 age·Hz 해석은 수명이 긴 파티클에서 과속 진동했다.
final class OscillateLifetimeFrequencyTests: XCTestCase {
    private func makeDef(lifetime: Float, operators: [ParticleOperator]) -> ParticleSystemDef {
        ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
                            rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: lifetime, max: lifetime),
                           .sizeRandom(min: 5, max: 5),
                           .velocityRandom(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 0, y: 0, z: 0)),
                           .alphaRandom(min: 1, max: 1, exponent: 1)],
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0)] + operators,
            renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
    }

    /// freq=1 은 수명 전체에서 정확히 1주기 — age·Hz 해석이었다면 lifetime=4 에서 age≈4 시 4주기.
    func testOscillateSizeOneCyclePerLifetime() {
        let op = ParticleOperator.oscillateSize(frequencyMin: 1, frequencyMax: 1,
                                                scaleMin: 0.5, scaleMax: 1.5, phaseMin: 0, phaseMax: 0)
        var sim = ParticleSimulator(def: makeDef(lifetime: 4, operators: [op]), seed: 7)
        let s0 = sim.step(0.01)[0].size          // n≈0: sin(0)=0 → factor 1.0
        XCTAssertEqual(s0, 5.0, accuracy: 0.05)
        _ = sim.step(0.99)                        // age≈1
        let s1 = sim.step(0.0)[0].size            // n=0.25: peak
        XCTAssertEqual(s1, 7.5, accuracy: 0.05)
        _ = sim.step(1.0)                         // age≈2
        let s2 = sim.step(0.0)[0].size            // n=0.5: 다시 중간
        XCTAssertEqual(s2, 5.0, accuracy: 0.05)
        _ = sim.step(1.0)                         // age≈3
        let s3 = sim.step(0.0)[0].size            // n=0.75: trough
        XCTAssertEqual(s3, 2.5, accuracy: 0.05)
    }

    /// 같은 freq 여도 lifetime 이 서로 다른 경우 → 같은 age 에서 진행도가 달라야(수명 비례 단위의 직접 증거).
    /// Hz 해석이면 lifetime 에 무관하게 같은 속도라 두 곡선이 일치한다.
    func testOscillateSpeedScalesWithLifetime() {
        let op = ParticleOperator.oscillateSize(frequencyMin: 1, frequencyMax: 1,
                                                scaleMin: 0.5, scaleMax: 1.5, phaseMin: 0, phaseMax: 0)
        var simShort = ParticleSimulator(def: makeDef(lifetime: 4, operators: [op]), seed: 8)
        var simLong = ParticleSimulator(def: makeDef(lifetime: 40, operators: [op]), seed: 8)
        _ = simShort.step(1.0)
        _ = simLong.step(1.0)
        let short = simShort.step(0.0)[0].size   // n=0.25 → peak 7.5
        let long = simLong.step(0.0)[0].size     // n=0.025 → sin(0.157)≈0.156 → factor≈1.078 → ≈5.39
        XCTAssertEqual(short, 7.5, accuracy: 0.05)
        XCTAssertEqual(long, 5.39, accuracy: 0.05)
        XCTAssertGreaterThan(short - long, 2.0, "lifetime 이 길수록 같은 age 에서 덜 진행해야(F832)")
    }

    /// position 오프셋도 동일 단위 — freq=1, lifetime=4, age1(n=0.25) 에서 최대 변위 scale.
    func testOscillatePositionOffsetUsesLifetimeUnit() {
        let op = ParticleOperator.oscillatePosition(frequencyMin: 1, frequencyMax: 1,
                                                    scaleMin: 50, scaleMax: 50, phaseMin: 0, phaseMax: 0,
                                                    mask: Vec3(x: 0, y: 1, z: 0))
        var sim = ParticleSimulator(def: makeDef(lifetime: 4, operators: [op]), seed: 9)
        _ = sim.step(1.0)
        let p = sim.step(0.0)[0]
        XCTAssertEqual(p.pos.y, 50, accuracy: 0.5, "n=0.25 → sin(π/2)=1 → offset=scale(F832)")
    }
}
