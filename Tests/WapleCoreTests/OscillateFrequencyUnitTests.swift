import XCTest
import simd
@testable import WapleCore

/// oscillate 계열(position/alpha/size)의 **주파수·위상 단위**를 고정한다.
///
/// **F832 반증.** 종전 스위트(`OscillateLifetimeFrequencyTests`)는 WE 공식 디자이너 문서
/// (operator.html — "The minimum/maximum number of oscillations per particle lifetime")를 근거로
/// `frequency` 를 "수명당 진동 횟수" 로 보고 `sin(2π·f·age/lifetime + φ)` 를 고정하고 있었다.
/// 바이너리는 다르게 말한다 — `ParticleSimulator.oscPositionOffset` 주석의 두 증거 참조:
/// 핸들러가 age 배열을 위상에 **더한 뒤** freq 를 곱하고(0x140240f75 → 0x140240f7a), 파스
/// 브랜치(0x1401cc655–0x1401cc7a0)에 `frequencymin/max` 를 2π 로 곱하는 명령이 **없다**.
///
///     θ = f · (age + φ)      f [rad/s] · age [s] · φ [s]
///
/// 문서가 라벨을 그렇게 설명할 뿐 런타임 단위는 rad/s 라는 뜻이다.
final class OscillateFrequencyUnitTests: XCTestCase {
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

    private static let sizeOp = ParticleOperator.oscillateSize(
        frequencyMin: 1, frequencyMax: 1, scaleMin: 0.5, scaleMax: 1.5, phaseMin: 0, phaseMax: 0)

    /// 주기는 **초 단위 2π/f** 다. f=1 rad/s 이면 age=π/2 에서 최대, π 에서 중간, 3π/2 에서 최소.
    /// 수명당 횟수 해석이었다면 이 시각들은 아무 의미가 없다(수명 20 에서 n=0.0785·0.157·0.236).
    func testPeriodIsTwoPiOverFrequencyInSeconds() {
        var sim = ParticleSimulator(def: makeDef(lifetime: 20, operators: [Self.sizeOp]), seed: 7)
        func particleAt(_ age: Float, from prev: Float) -> Particle {
            _ = sim.step(age - prev)
            return sim.step(0)[0]
        }
        // 첫 스텝은 0.01 — rate·dt < 1 이면 파티클이 아직 안 나온다(rate 1000 × 0.01 = 10).
        let start = sim.step(0.01)[0]
        XCTAssertEqual(start.size, 5 * (0.5 + start.sharedRandom * 0.5 * (1 + sin(start.age))),
                       accuracy: 0.05, "age≈0 → 공용 난수로 줄인 중간 진폭")
        let peak = particleAt(.pi / 2, from: 0.01)
        XCTAssertEqual(peak.size, 5 * (0.5 + peak.sharedRandom), accuracy: 0.05, "sin=1")
        let middle = particleAt(.pi, from: .pi / 2)
        XCTAssertEqual(middle.size, 5 * (0.5 + middle.sharedRandom * 0.5), accuracy: 0.05, "sin=0")
        XCTAssertEqual(particleAt(3 * .pi / 2, from: .pi).size, 2.5, accuracy: 0.05, "sin=−1")
    }

    /// **수명에 무관하다.** 같은 freq·같은 age 면 수명이 10배 달라도 같은 값이어야 한다 —
    /// 종전 해석의 직접 반증이다(그쪽이면 수명 200 쪽이 10배 덜 진행해야 했다).
    func testProgressIsIndependentOfLifetime() {
        var short = ParticleSimulator(def: makeDef(lifetime: 20, operators: [Self.sizeOp]), seed: 8)
        var long = ParticleSimulator(def: makeDef(lifetime: 200, operators: [Self.sizeOp]), seed: 8)
        _ = short.step(.pi / 2); _ = long.step(.pi / 2)
        let s = short.step(0)[0], l = long.step(0)[0]
        XCTAssertEqual(s.size, 5 * (0.5 + s.sharedRandom), accuracy: 0.05)
        XCTAssertEqual(l.size, 5 * (0.5 + l.sharedRandom), accuracy: 0.05)
        XCTAssertEqual(s.size, l.size, accuracy: 1e-4, "수명은 진행 속도에 영향을 주지 않는다")
    }

    /// 위상은 **초** 다 — φ 를 주면 파형이 시간축에서 φ 초 앞당겨진다. f=1, φ=π/2 면 age=0 에서
    /// 이미 마루에 있어야 한다(θ(0)=π/2).
    func testPhaseIsInSecondsNotTurns() {
        let op = ParticleOperator.oscillateSize(frequencyMin: 1, frequencyMax: 1,
                                                scaleMin: 0.5, scaleMax: 1.5,
                                                phaseMin: .pi / 2, phaseMax: .pi / 2)
        var sim = ParticleSimulator(def: makeDef(lifetime: 20, operators: [op]), seed: 9)
        let p = sim.step(0.01)[0]
        let expected = 5 * (0.5 + p.sharedRandom * 0.5 * (1 + sin(p.age + .pi / 2)))
        XCTAssertEqual(p.size, expected, accuracy: 0.05,
                       "θ(0)=f·φ=π/2 → 공용 난수로 줄인 마루")
    }

    /// 위치 오프셋은 `scale·(sin θ(t) − sin θ(0))` 이라 **스폰 순간 정확히 0** 이다.
    /// 실물이 매 프레임 `sin θ(t) − sin θ(t−dt)` 를 위치에 누적하기 때문이다(텔레스코핑).
    /// 종전 구현은 위상이 0 이 아니면 스폰에서 `scale·sin(2πφ)` 만큼 튀었다.
    func testPositionOffsetIsZeroAtSpawnEvenWithPhase() {
        let op = ParticleOperator.oscillatePosition(
            frequencyMin: 1, frequencyMax: 1, scaleMin: 50, scaleMax: 50,
            phaseMin: .pi / 2, phaseMax: .pi / 2, mask: Vec3(x: 0, y: 1, z: 0))
        var sim = ParticleSimulator(def: makeDef(lifetime: 20, operators: [op]), seed: 11)
        // 첫 스텝을 짧게 — age≈0 이면 오프셋도 ≈0 이어야 한다(실측 −0.0025).
        XCTAssertEqual(sim.step(0.01)[0].pos.y, 0, accuracy: 0.05, "스폰 오프셋은 0")
        // 그 뒤에는 실제로 흔들려야 한다(단언이 공허해지지 않게).
        _ = sim.step(.pi / 2)
        XCTAssertGreaterThan(abs(sim.step(0)[0].pos.y), 10, "이후에는 진동이 보여야 한다")
    }

    /// position 오프셋의 시간 규약도 초 단위 — f=1, φ=0 이면 age=π/2 에서 변위 = scale.
    func testPositionOffsetUsesSecondsUnit() {
        let op = ParticleOperator.oscillatePosition(
            frequencyMin: 1, frequencyMax: 1, scaleMin: 50, scaleMax: 50,
            phaseMin: 0, phaseMax: 0, mask: Vec3(x: 0, y: 1, z: 0))
        var sim = ParticleSimulator(def: makeDef(lifetime: 20, operators: [op]), seed: 12)
        _ = sim.step(.pi / 2)
        XCTAssertEqual(sim.step(0)[0].pos.y, 50, accuracy: 0.5, "sin(π/2)=1 → offset = scale")
    }
}
