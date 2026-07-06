import XCTest
import simd
@testable import WapleCore

/// Stage A 파티클 연산자/이니셜라이저(실물 스키마 실측 기반):
/// oscillatesize(크기 진동), alphachange(초 단위 알파 램프 — 长2.json lifetime3/endtime2 로 단위 확정),
/// remapvalue(노이즈→velocity 덮어쓰기 / speed 비파괴 배수), colorlist(0..1 색 목록),
/// instantaneous 버스트 이미터(rate 0 — 현재 0스폰이던 유성/스플래시 계열), sign 방향 클램프.
final class ParticleStageATests: XCTestCase {
    private func makeDef(emitters: [Emitter]? = nil,
                         initializers extraInits: [Initializer] = [],
                         velocity: Vec3 = Vec3(x: 0, y: 0, z: 0),
                         lifetime: Float = 100, maxCount: Int = 1,
                         operators extra: [ParticleOperator] = []) -> ParticleSystemDef {
        ParticleSystemDef(
            emitters: emitters ?? [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
                                        rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: lifetime, max: lifetime),
                           .sizeRandom(min: 5, max: 5),
                           .velocityRandom(min: velocity, max: velocity),
                           .alphaRandom(min: 1, max: 1, exponent: 1)] + extraInits,
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0)] + extra,
            renderer: .sprite, maxCount: maxCount, startTime: 0, material: nil)
    }

    // MARK: - oscillatesize

    func testOscillateSize_peaksAndTroughs() {
        // freq 0.25Hz(주기 4s), phase 0, 배율 0.5..1.5, initialSize 5.
        let op = ParticleOperator.oscillateSize(frequencyMin: 0.25, frequencyMax: 0.25,
                                                scaleMin: 0.5, scaleMax: 1.5, phaseMin: 0, phaseMax: 0)
        var sim = ParticleSimulator(def: makeDef(lifetime: 100, operators: [op]), seed: 11)
        let a = sim.step(1.0)   // age1: sin(π/2)=1 → factor=1.5
        XCTAssertEqual(a[0].size, 7.5, accuracy: 0.01)
        _ = sim.step(1.0)
        let c = sim.step(1.0)   // age3: sin(3π/2)=-1 → factor=0.5
        XCTAssertEqual(c[0].size, 2.5, accuracy: 0.01)
    }

    // MARK: - alphachange (초 단위)

    func testAlphaChange_rampInSeconds_holdsAfterEnd() {
        // sv1→ev0, st0, et2(초). lifetime 10 — 정규화가 아니라 초 단위임을 고정.
        let op = ParticleOperator.alphaChange(startTime: 0, endTime: 2, startValue: 1, endValue: 0)
        var sim = ParticleSimulator(def: makeDef(lifetime: 10, operators: [op]), seed: 12)
        let a = sim.step(1.0)   // age1 → t=0.5 → alpha 0.5
        XCTAssertEqual(a[0].alpha, 0.5, accuracy: 0.01)
        let b = sim.step(1.0)   // age2 → t=1 → 0
        XCTAssertEqual(b[0].alpha, 0, accuracy: 0.01)
        let c = sim.step(1.0)   // age3 → 끝값 유지
        XCTAssertEqual(c[0].alpha, 0, accuracy: 0.01)
    }

    func testAlphaChange_beforeStartHoldsStartValue() {
        let op = ParticleOperator.alphaChange(startTime: 2, endTime: 4, startValue: 0.8, endValue: 0)
        var sim = ParticleSimulator(def: makeDef(lifetime: 10, operators: [op]), seed: 13)
        let a = sim.step(1.0)   // age1 < st2 → sv 유지
        XCTAssertEqual(a[0].alpha, 0.8, accuracy: 0.01)
    }

    // MARK: - remapvalue

    func testRemapValue_velocityOverwrite_degenerateRange() {
        // min==max → 노이즈와 무관하게 vel 을 매 스텝 그 값으로 덮어쓴다.
        let op = ParticleOperator.remapValue(output: .velocity(min: Vec3(x: 3, y: -7, z: 0),
                                                               max: Vec3(x: 3, y: -7, z: 0)),
                                             fbm: false, inputScale: 10)
        var sim = ParticleSimulator(def: makeDef(velocity: Vec3(x: 100, y: 100, z: 0),
                                                 lifetime: 100, operators: [op]), seed: 14)
        let a = sim.step(1.0)
        XCTAssertEqual(a[0].vel.x, 3, accuracy: 0.001)
        XCTAssertEqual(a[0].vel.y, -7, accuracy: 0.001)
        XCTAssertEqual(a[0].pos.x, 3, accuracy: 0.01)   // 스폰 즉시 덮어쓰기 → 초기 100 은 무시
        XCTAssertEqual(a[0].pos.y, -7, accuracy: 0.01)
    }

    func testRemapValue_velocityBoundedByRange() {
        let mn = Vec3(x: -50, y: -100, z: 0), mx = Vec3(x: 50, y: -10, z: 0)
        let op = ParticleOperator.remapValue(output: .velocity(min: mn, max: mx), fbm: true, inputScale: 8)
        var sim = ParticleSimulator(def: makeDef(lifetime: 100, maxCount: 20, operators: [op]), seed: 15)
        for _ in 0..<30 {
            for p in sim.step(0.1) {
                XCTAssertTrue((mn.x...mx.x).contains(p.vel.x), "vel.x \(p.vel.x) out of range")
                XCTAssertTrue((mn.y...mx.y).contains(p.vel.y), "vel.y \(p.vel.y) out of range")
                XCTAssertEqual(p.vel.z, 0, accuracy: 1e-5)
            }
        }
    }

    func testRemapValue_speedIsNonDestructiveMultiplier() {
        // speed min==max=2: 적분 속도만 2배(저장 vel 은 불변 → 복리 폭주 없음).
        let op = ParticleOperator.remapValue(output: .speed(min: 2, max: 2), fbm: false, inputScale: 1)
        var sim = ParticleSimulator(def: makeDef(velocity: Vec3(x: 10, y: 0, z: 0),
                                                 lifetime: 100, operators: [op]), seed: 16)
        let a = sim.step(1.0)
        XCTAssertEqual(a[0].pos.x, 20, accuracy: 0.01)
        XCTAssertEqual(a[0].vel.x, 10, accuracy: 0.001)  // 저장 속도 원본 유지
        let b = sim.step(1.0)
        XCTAssertEqual(b[0].pos.x, 40, accuracy: 0.01)   // 매 스텝 ×2 (복리 아님)
    }

    // MARK: - colorlist

    func testColorList_picksFromList() {
        let colors = [Vec3(x: 1, y: 0, z: 0), Vec3(x: 0, y: 0, z: 1)]
        var sim = ParticleSimulator(def: makeDef(emitters: nil,
                                                 initializers: [.colorList(colors: colors)],
                                                 lifetime: 100, maxCount: 30), seed: 17)
        var seen = Set<String>()
        for _ in 0..<30 { _ = sim.step(0.01) }
        for p in sim.step(0.01) {
            let c = p.color
            let isRed = abs(c.x - 1) < 1e-5 && abs(c.z) < 1e-5
            let isBlue = abs(c.z - 1) < 1e-5 && abs(c.x) < 1e-5
            XCTAssertTrue(isRed || isBlue, "color \(c) not in list")
            seen.insert(isRed ? "r" : "b")
        }
        XCTAssertEqual(seen, ["r", "b"], "30개면 두 색 모두 나와야 함(시드 고정)")
    }

    // MARK: - instantaneous 버스트

    func testInstantaneousBurst_spawnsCountAtOnce_andRebursts() {
        // rate 0 + burst 4: 즉시 4개, 생존 중 추가 스폰 없음, 전멸 후 재버스트.
        let def = makeDef(emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0),
                                          distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 0, burst: 4)],
                          lifetime: 1, maxCount: 10)
        var sim = ParticleSimulator(def: def, seed: 18)
        XCTAssertEqual(sim.step(0.01).count, 4)
        XCTAssertEqual(sim.step(0.5).count, 4)      // 생존 중 재버스트 없음
        XCTAssertEqual(sim.step(0.6).count, 0)      // age>1 전멸(이 스텝 말 컬)
        XCTAssertEqual(sim.step(0.01).count, 4)     // 재버스트
    }

    func testInstantaneousBurst_cappedByMaxCount() {
        let def = makeDef(emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0),
                                          distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 0, burst: 100)],
                          lifetime: 1, maxCount: 6)
        var sim = ParticleSimulator(def: def, seed: 19)
        XCTAssertEqual(sim.step(0.01).count, 6)
    }

    // MARK: - sign 방향 클램프 (rain splash "sign": "0 1 0")

    func testSphereSign_forcesUpwardHemisphere() {
        let def = makeDef(emitters: [.sphere(origin: Vec3(x: 0, y: 0, z: 0),
                                             directions: Vec3(x: 1, y: 1, z: 0),
                                             distanceMin: 10, distanceMax: 10, rate: 1000, burst: 0,
                                             sign: Vec3(x: 0, y: 1, z: 0))],
                          lifetime: 100, maxCount: 40)
        var sim = ParticleSimulator(def: def, seed: 20)
        for _ in 0..<3 { _ = sim.step(0.05) }
        for p in sim.step(0.01) {
            XCTAssertGreaterThanOrEqual(p.pos.y, -1e-4, "sign +y 인데 아래로 스폰: \(p.pos)")
        }
    }

    // MARK: - 파싱 (실물 키)

    func testParse_stageAOperatorsAndBurst() {
        let json: [String: Any] = [
            "emitter": [["name": "sphererandom", "rate": 0, "instantaneous": 7,
                         "distancemin": 0, "distancemax": 10, "sign": "0 1 0"]],
            "initializer": [["name": "colorlist",
                             "colors": ["0.25 0.5 0.75", "1 0 0"]]],
            "operator": [
                ["name": "oscillatesize", "frequencymin": 1, "frequencymax": 2,
                 "scalemin": 0.2, "scalemax": 0.8, "phasemax": 2],
                ["name": "alphachange", "endtime": 2],
                ["name": "remapvalue", "output": "velocity", "transformfunction": "simplexnoise",
                 "outputrangemin": "-200 -100 0", "outputrangemax": "200 -1000 0",
                 "transforminputscale": 10],
                ["name": "remapvalue", "output": "speed", "transformfunction": "fbmnoise",
                 "outputrangemin": -5, "outputrangemax": 7, "transforminputscale": 8],
            ],
            "renderer": [["name": "sprite"]],
            "maxcount": 7,
        ]
        let def = ParticleSystemDef.parse(json, material: nil)
        guard case let .sphere(_, _, _, _, rate, burst, sign) = def.emitters[0] else {
            return XCTFail("sphere 파스 실패")
        }
        XCTAssertEqual(rate, 0); XCTAssertEqual(burst, 7); XCTAssertEqual(sign, Vec3(x: 0, y: 1, z: 0))
        XCTAssertEqual(def.initializers.count, 1)
        if case let .colorList(colors) = def.initializers[0] {
            XCTAssertEqual(colors.count, 2)
            XCTAssertEqual(colors[0].y, 0.5, accuracy: 1e-5)
        } else { XCTFail("colorlist 파스 실패") }
        XCTAssertEqual(def.operators.count, 4)
        XCTAssertTrue(def.operators.contains {
            if case .oscillateSize(1, 2, 0.2, 0.8, 0, 2) = $0 { return true }; return false
        })
        XCTAssertTrue(def.operators.contains {
            // 기본값: st0, sv0→ev1 (WE 에디터 관례 추정 — ponytail 천장)
            if case .alphaChange(0, 2, 0, 1) = $0 { return true }; return false
        })
        XCTAssertTrue(def.operators.contains {
            if case let .remapValue(output, fbm, scale) = $0,
               case let .velocity(mn, mx) = output, !fbm, scale == 10,
               mn.y == -100, mx.y == -1000 { return true }
            return false
        })
        XCTAssertTrue(def.operators.contains {
            if case let .remapValue(output, fbm, scale) = $0,
               case let .speed(mn, mx) = output, fbm, scale == 8,
               mn == -5, mx == 7 { return true }
            return false
        })
    }
}
