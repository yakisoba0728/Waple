import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

/// E1(④): 2D 파티클 오브젝트 visible(정적+스크립트) 평가 — 종전엔 buildParticles/encodeDrawPlan
/// 어디서도 SceneParticle.visible/visibleScript 를 읽지 않아, 저작자가 숨긴 파티클 시스템이 항상
/// 렌더되거나(초기 true 인데 스크립트가 false 로 꺼야 하는 경우) 스크립트로 다시 켜야 할 파티클이
/// 영원히 안 보였다(초기 false 로 파스를 통과한 경우, F199/cluster 66·116·342).
final class ParticleVisibleScriptRenderTests: XCTestCase {
    private let particle = #"{"renderer":[{"name":"sprite"}],"maxcount":1,"material":"materials/snow.json"}"#
    private let material = #"{"passes":[{"textures":["particle/snow"]}]}"#

    private func pkg(scene: String) -> ScenePackage {
        ScenePackage.assemble([
            (name: "scene.json", data: Data(scene.utf8)),
            (name: "particles/snow.json", data: Data(particle.utf8)),
            (name: "materials/snow.json", data: Data(material.utf8)),
            (name: "materials/particle/snow.tex", data: solidTex(255, 255, 255)),
        ])
    }

    /// 정적 visible:true(스크립트 없음)는 종전과 동일하게 항상 표시(무회귀) — visibleEngine 미배선.
    func testStaticVisibleTrueHasNoScriptEngineAndStaysVisible() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"particle":"particles/snow.json","origin":"10 10 0"}]}
        """
        let p = pkg(scene: scene)
        let doc = try SceneDocument.parse(package: p)
        let renderer = SceneRenderer()
        renderer.particleSystems = renderer.buildParticles(doc: doc, package: p, device: device)
        XCTAssertEqual(renderer.particleSystems.count, 1)
        XCTAssertNil(renderer.particleSystems[0].visibleEngine)
        XCTAssertTrue(renderer.particleScriptVisible(0, time: 0))
    }

    /// visible={value:true,script} 로 시작해 스크립트가 false 를 반환하면 draw 게이트가 즉시 꺼져야 한다
    /// (종전엔 이 검사가 전무해 숨겨야 할 파티클이 항상 렌더됐다).
    func testScriptCanHideInitiallyVisibleParticleSystem() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"particle":"particles/snow.json","origin":"10 10 0",
           "visible":{"value":true,"script":"export function update(v){ return false; }"}}]}
        """
        let p = pkg(scene: scene)
        let doc = try SceneDocument.parse(package: p)
        let renderer = SceneRenderer()
        renderer.particleSystems = renderer.buildParticles(doc: doc, package: p, device: device)
        XCTAssertEqual(renderer.particleSystems.count, 1)
        XCTAssertNotNil(renderer.particleSystems[0].visibleEngine, "visible 스크립트 엔진이 배선돼야")
        XCTAssertTrue(renderer.particleSystems[0].initialVisible, "초기값은 value:true 보존")
        XCTAssertFalse(renderer.particleScriptVisible(0, time: 0),
                       "스크립트가 false 를 반환하면 draw 게이트가 꺼져야")
    }

    /// visible={value:false,script} 로 시작해 스크립트가 true 를 반환하면 다시 켜져야 한다(3D 대칭 결함:
    /// "영원히 안 보임" 대응 — 2D 는 정적 false 라도 스크립트가 있으면 파스를 통과한다, F199).
    func testScriptCanRevealInitiallyHiddenParticleSystem() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"particle":"particles/snow.json","origin":"10 10 0",
           "visible":{"value":false,"script":"export function update(v){ return true; }"}}]}
        """
        let p = pkg(scene: scene)
        let doc = try SceneDocument.parse(package: p)
        let renderer = SceneRenderer()
        renderer.particleSystems = renderer.buildParticles(doc: doc, package: p, device: device)
        XCTAssertEqual(renderer.particleSystems.count, 1, "정적 false 라도 스크립트가 있으면 파스를 통과해야(F199)")
        XCTAssertFalse(renderer.particleSystems[0].initialVisible)
        XCTAssertTrue(renderer.particleScriptVisible(0, time: 0),
                      "스크립트가 true 를 반환하면 draw 게이트가 켜져야")
    }
}
