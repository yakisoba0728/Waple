import XCTest
import simd
@testable import WapleCore

/// 자식 파티클 시스템(실물 children[] 107링크): eventfollow 49(부모 파티클 추종),
/// 무type/static 40(상시 앰비언트 — 링크 origin 고정), eventspawn 12(스폰 지점 1회 버스트),
/// eventdeath 6(사망 지점 1회 버스트 — rain splash). 부모 sim 이 자식 sim 들을 구동하고
/// childDisplay(linkIndex) 로 링크별 표시 스냅샷을 노출한다(렌더러가 링크별 머티리얼로 드로우).
final class ParticleChildrenTests: XCTestCase {
    private func childDef(burst: Int = 0, rate: Float = 200, lifetime: Float = 0.5,
                          maxCount: Int = 8) -> ParticleSystemDef {
        ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
                            rate: rate, burst: burst)],
            initializers: [.lifetimeRandom(min: lifetime, max: lifetime)],
            operators: [],
            renderer: .sprite, maxCount: maxCount, startTime: 0, material: nil)
    }

    private func parentDef(children: [ChildLink], emitters: [Emitter],
                           velocity: Vec3 = Vec3(x: 0, y: 0, z: 0),
                           lifetime: Float = 10, maxCount: Int = 4) -> ParticleSystemDef {
        ParticleSystemDef(
            emitters: emitters,
            initializers: [.lifetimeRandom(min: lifetime, max: lifetime),
                           .velocityRandom(min: velocity, max: velocity)],
            operators: [.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0)],
            renderer: .sprite, maxCount: maxCount, startTime: 0, material: nil,
            children: children)
    }

    private func burstEmitter(_ n: Int) -> Emitter {
        .box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 0, burst: n)
    }

    func testFollowChild_trailsMovingParent() {
        let link = ChildLink(def: childDef(), trigger: .follow, maxInstances: 5,
                             probability: 1, origin: Vec3(x: 0, y: 0, z: 0))
        var sim = ParticleSimulator(def: parentDef(children: [link], emitters: [burstEmitter(1)],
                                                   velocity: Vec3(x: 100, y: 0, z: 0)),
                                    seed: 31)
        // maxCount 캡이 스폰을 배치 동기화 → lifetime 주기마다 전멸 비트가 있다.
        // 특정 스텝이 아니라 말미 3스텝 합집합으로 단언(비트 공진 회피).
        var kids: [Particle] = []
        for i in 0..<20 {
            _ = sim.step(0.05)   // t=1: 부모 x≈100
            if i >= 17 { kids.append(contentsOf: sim.childDisplay(0)) }
        }
        XCTAssertFalse(kids.isEmpty, "follow 자식이 방출돼야 함")
        // 트레일: 자식은 스폰 시점의 부모 위치에 남는다 — 전부 이동 경로(0..100) 위.
        for k in kids {
            XCTAssertGreaterThanOrEqual(k.pos.x, -0.01)
            XCTAssertLessThanOrEqual(k.pos.x, 100.01)
        }
        // 최신 스폰은 부모 현재 위치 부근(자식 수명 0.5 → 최근 0.5s 내 스폰만 생존 = x≥95-ε... 보수적으로 >50)
        XCTAssertGreaterThan(kids.map(\.pos.x).max() ?? -1, 50)
    }

    func testAlwaysChild_runsAtLinkOriginWithoutParentParticles() {
        let link = ChildLink(def: childDef(), trigger: .always, maxInstances: 1,
                             probability: 1, origin: Vec3(x: 500, y: -20, z: 0))
        var sim = ParticleSimulator(def: parentDef(children: [link], emitters: []), seed: 32)
        var kids: [Particle] = []
        for i in 0..<10 {
            _ = sim.step(0.05)
            if i >= 7 { kids.append(contentsOf: sim.childDisplay(0)) }   // 전멸 비트 공진 회피(말미 합집합)
        }
        XCTAssertFalse(kids.isEmpty, "부모 파티클이 없어도 상시 자식은 동작")
        for k in kids {
            XCTAssertEqual(k.pos.x, 500, accuracy: 0.01)
            XCTAssertEqual(k.pos.y, -20, accuracy: 0.01)
        }
    }

    func testSpawnBurstChild_firesOnceThenDrains() {
        let link = ChildLink(def: childDef(burst: 3, rate: 0, lifetime: 0.2, maxCount: 10),
                             trigger: .spawnBurst, maxInstances: 4,
                             probability: 1, origin: Vec3(x: 0, y: 0, z: 0))
        var sim = ParticleSimulator(def: parentDef(children: [link], emitters: [burstEmitter(1)],
                                                   lifetime: 10), seed: 33)
        _ = sim.step(0.05)
        XCTAssertEqual(sim.childDisplay(0).count, 3, "스폰 버스트 3개")
        for _ in 0..<10 { _ = sim.step(0.05) }   // 자식 수명 0.2 소진
        XCTAssertTrue(sim.childDisplay(0).isEmpty, "원샷 — 재버스트 없이 소진 유지")
    }

    func testDeathBurstChild_firesAtDeathPosition() {
        // 부모: 버스트 1, vel(10,0,0), 수명 0.5 → t=0.75 스텝에서 컬(사망 위치 x≈7.5).
        let link = ChildLink(def: childDef(burst: 4, rate: 0, lifetime: 5, maxCount: 10),
                             trigger: .deathBurst, maxInstances: 4,
                             probability: 1, origin: Vec3(x: 0, y: 0, z: 0))
        var sim = ParticleSimulator(def: parentDef(children: [link], emitters: [burstEmitter(1)],
                                                   velocity: Vec3(x: 10, y: 0, z: 0),
                                                   lifetime: 0.5, maxCount: 1), seed: 34)
        _ = sim.step(0.25)   // age .25
        _ = sim.step(0.25)   // age .50 (생존: 컬은 age>lifetime)
        _ = sim.step(0.25)   // age .75 → 컬, 사망 x=7.5
        let kids = sim.childDisplay(0)
        XCTAssertEqual(kids.count, 4, "사망 버스트 4개")
        for k in kids { XCTAssertEqual(k.pos.x, 7.5, accuracy: 0.26) }
    }

    func testProbabilityZero_spawnsNoChildren() {
        let link = ChildLink(def: childDef(), trigger: .follow, maxInstances: 5,
                             probability: 0, origin: Vec3(x: 0, y: 0, z: 0))
        var sim = ParticleSimulator(def: parentDef(children: [link], emitters: [burstEmitter(2)]),
                                    seed: 35)
        for _ in 0..<10 { _ = sim.step(0.05) }
        XCTAssertTrue(sim.childDisplay(0).isEmpty)
    }

    func testMaxInstancesCap() {
        // 부모 4개 동시 생존, 링크 캡 2 → 자식 인스턴스는 2개 부모에만 붙는다.
        let link = ChildLink(def: childDef(rate: 20, lifetime: 5), trigger: .follow,
                             maxInstances: 2, probability: 1, origin: Vec3(x: 0, y: 0, z: 0))
        var sim = ParticleSimulator(def: parentDef(children: [link], emitters: [burstEmitter(4)],
                                                   lifetime: 10, maxCount: 4), seed: 36)
        for _ in 0..<20 { _ = sim.step(0.05) }
        // rate 20/s × 1s × 2인스턴스 ≈ 40 총이지만 수명 5s 라 전부 생존 → 인스턴스별 maxCount 8 캡 × 2 = 16 상한.
        // F389: 상한(<=16)과 비어있지 않음만으론 링크 캡이 2→1로 붕괴해도(각 인스턴스 8 캡 그대로 <=8<=16)
        // green 을 유지한다 — 하한(>8)을 추가해 "2개 인스턴스가 실제로 기여했다"를 직접 단언.
        let count = sim.childDisplay(0).count
        XCTAssertLessThanOrEqual(count, 16)
        XCTAssertGreaterThan(count, 8, "2개 인스턴스(각 캡 8)가 기여해야 함 — 8 이하면 링크 캡이 1로 붕괴")
    }

    func testParse_childLinksRealKeys() {
        let stub = childDef()
        let json: [String: Any] = [
            "emitter": [["name": "boxrandom", "rate": 10, "distancemax": 0]],
            "renderer": [["name": "sprite"]],
            "maxcount": 85,
            "children": [
                ["id": 10, "name": "particles/a.json", "maxcount": 85, "type": "eventfollow"],
                ["id": 11, "name": "particles/b.json"],                          // 무type → always
                ["id": 12, "name": "particles/c.json", "type": "eventdeath", "probability": 0.5],
                ["id": 13, "name": "particles/d.json", "type": "eventspawn",
                 "origin": "10 20 0"],
                ["id": 14, "name": "particles/missing.json", "type": "eventfollow"],  // 리졸브 실패 → 드롭
            ],
        ]
        let def = ParticleSystemDef.parse(json, material: nil) { path in
            path == "particles/missing.json" ? nil : stub
        }
        XCTAssertEqual(def.children.count, 4)
        XCTAssertEqual(def.children[0].trigger, .follow)
        XCTAssertEqual(def.children[0].maxInstances, 85)
        XCTAssertEqual(def.children[0].probability, 1)
        XCTAssertEqual(def.children[1].trigger, .always)
        XCTAssertEqual(def.children[2].trigger, .deathBurst)
        XCTAssertEqual(def.children[2].probability, 0.5)
        XCTAssertEqual(def.children[3].trigger, .spawnBurst)
        XCTAssertEqual(def.children[3].origin, Vec3(x: 10, y: 20, z: 0))
        // 링크 maxcount 부재: always → 1, 이벤트류 → 부모 maxcount.
        XCTAssertEqual(def.children[1].maxInstances, 1)
        XCTAssertEqual(def.children[2].maxInstances, 85)
    }

    func testNoChildren_childDisplayOutOfRangeIsEmpty() {
        var sim = ParticleSimulator(def: parentDef(children: [], emitters: [burstEmitter(1)]), seed: 37)
        _ = sim.step(0.1)
        XCTAssertTrue(sim.childDisplay(0).isEmpty)   // 방어적 — 크래시 금지
    }
}
