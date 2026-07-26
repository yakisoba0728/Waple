import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

/// E1(③)/F178: children[]는 파스/시뮬 모두 깊이4 재귀를 지원하나, 종전엔 buildParticles(GPU화)가
/// 직계 자식(1단)만 순회해 손자 이상은 CPU/RNG 시뮬 비용만 내고 화면에 전혀 그려지지 않았다.
final class ParticleGrandchildRenderTests: XCTestCase {
    private func material() -> ParticleMaterial {
        ParticleMaterial.parse(["passes": [["textures": ["particle/snow"]]]])
    }

    private func pkg() -> ScenePackage {
        ScenePackage.assemble([
            ("materials/particle/snow.tex", solidTex(255, 255, 255)),
        ])
    }

    /// 루트→자식→손자 3단 트리를 buildParticles 에 태우면 GPU 시스템 3개가 나와야 하고(종전엔 2개 —
    /// 손자 드롭), 손자의 childOf.parent 는 "직계" 부모(자식)의 GPU 인덱스를 가리켜야 한다.
    func testBuildParticlesRecursesIntoGrandchildren() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let grandDef = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 10, burst: 0)],
            initializers: [.lifetimeRandom(min: 10, max: 10)],
            operators: [], renderer: .sprite, maxCount: 4, startTime: 0, material: material())
        let grandLink = ChildLink(def: grandDef, trigger: .always, maxInstances: 1,
                                  probability: 1, origin: Vec3(x: 0, y: 0, z: 0))
        let childDef = ParticleSystemDef(
            emitters: [], initializers: [.lifetimeRandom(min: 10, max: 10)],
            operators: [], renderer: .sprite, maxCount: 4, startTime: 0, material: material(),
            children: [grandLink])
        let childLink = ChildLink(def: childDef, trigger: .always, maxInstances: 1,
                                  probability: 1, origin: Vec3(x: 0, y: 0, z: 0))
        let rootDef = ParticleSystemDef(
            emitters: [], initializers: [], operators: [], renderer: .sprite,
            maxCount: 4, startTime: 0, material: material(), children: [childLink])

        let sp = SceneParticle(def: rootDef, origin: Vec2(x: 0, y: 0), scale: Vec2(x: 1, y: 1))
        let doc = SceneDocument(projectionWidth: 100, projectionHeight: 100, clearColor: Vec3(x: 0, y: 0, z: 0),
                                parallaxEnabled: false, parallaxAmount: 0, parallaxMouseInfluence: 0,
                                parallaxDelay: 0, layers: [], particles: [sp])
        let renderer = SceneRenderer()
        let built = renderer.buildParticles(doc: doc, package: pkg(), device: device)

        XCTAssertEqual(built.count, 3, "루트+자식+손자 = 3개 GPU 시스템이 생성돼야(종전엔 손자 드롭 → 2개)")
        XCTAssertNil(built[0].childOf, "루트는 childOf 없음")
        XCTAssertEqual(built[1].childOf?.parent, 0, "자식의 직계 부모 = 루트(인덱스 0)")
        XCTAssertEqual(built[1].childOf?.link, 0)
        XCTAssertEqual(built[2].childOf?.parent, 1, "손자의 직계 부모 = 자식(인덱스 1) — 루트 아님")
        XCTAssertEqual(built[2].childOf?.link, 0)

        // 경로 워크: 손자에서 루트까지 [자식링크, 손자링크] 순으로 거슬러 올라가야 한다.
        renderer.particleSystems = built
        let resolved = try XCTUnwrap(renderer.particleDescendantPath(from: 2))
        XCTAssertEqual(resolved.root, 0)
        XCTAssertEqual(resolved.path, [0, 0])
    }

    /// 손자 이미터가 실제로 파티클을 방출하면, 루트 sim 을 스텝한 뒤 경로 기반 조회로 그 파티클이
    /// 보여야 한다(렌더 소비 배선 확인 — 시뮬만 돌고 화면 기여 0 이던 결함의 핵심 재현).
    func testGrandchildParticlesAreReachableAfterStep() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let grandDef = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 7, y: 3, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 500, burst: 0)],
            initializers: [.lifetimeRandom(min: 10, max: 10)],
            operators: [], renderer: .sprite, maxCount: 20, startTime: 0, material: material())
        let grandLink = ChildLink(def: grandDef, trigger: .always, maxInstances: 1,
                                  probability: 1, origin: Vec3(x: 0, y: 0, z: 0))
        let childDef = ParticleSystemDef(
            emitters: [], initializers: [.lifetimeRandom(min: 10, max: 10)],
            operators: [], renderer: .sprite, maxCount: 4, startTime: 0, material: material(),
            children: [grandLink])
        let childLink = ChildLink(def: childDef, trigger: .always, maxInstances: 1,
                                  probability: 1, origin: Vec3(x: 0, y: 0, z: 0))
        let rootDef = ParticleSystemDef(
            emitters: [], initializers: [], operators: [], renderer: .sprite,
            maxCount: 4, startTime: 0, material: material(), children: [childLink])

        let sp = SceneParticle(def: rootDef, origin: Vec2(x: 0, y: 0), scale: Vec2(x: 1, y: 1))
        let doc = SceneDocument(projectionWidth: 100, projectionHeight: 100, clearColor: Vec3(x: 0, y: 0, z: 0),
                                parallaxEnabled: false, parallaxAmount: 0, parallaxMouseInfluence: 0,
                                parallaxDelay: 0, layers: [], particles: [sp])
        let renderer = SceneRenderer()
        renderer.particleSystems = renderer.buildParticles(doc: doc, package: pkg(), device: device)
        XCTAssertEqual(renderer.particleSystems.count, 3)

        _ = renderer.particleSystems[0].sim.step(0.1)  // 루트 스텝 — 재귀적으로 자식/손자 sim 도 함께 진행
        let resolved = try XCTUnwrap(renderer.particleDescendantPath(from: 2))
        let grandParticles = renderer.particleSystems[resolved.root].sim.descendantDisplay(path: resolved.path)
        XCTAssertFalse(grandParticles.isEmpty, "손자 이미터가 방출한 파티클이 경로 기반 조회로 보여야 함")
        for p in grandParticles {
            XCTAssertEqual(p.pos.x, 7, accuracy: 0.01)
            XCTAssertEqual(p.pos.y, 3, accuracy: 0.01)
        }
    }
}
