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

    /// 프로덕션과 같은 **씬 공유 JSContext** 위에서 파티클을 빌드한다(mount 가 하는 일의 축소판).
    /// 공유 컨텍스트를 안 깔면 엔진마다 단독 JSContext + 단독 전역 thisLayer 라 "파티클끼리 thisLayer
    /// 를 공유하는가" 를 아예 관측할 수 없다 — play/pause 격리 테스트가 공짜로 통과해 버린다.
    private func renderer(for doc: SceneDocument, package: ScenePackage, device: MTLDevice) -> SceneRenderer {
        let r = SceneRenderer()
        r.sceneScript = SceneScriptContext(layers: SceneRenderer.sceneScriptLayers(from: doc),
                                           width: Float(doc.projectionWidth), height: Float(doc.projectionHeight))
        r.particleSystems = r.buildParticles(doc: doc, package: package, device: device)
        return r
    }

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

    /// 실물 3690417937 bubbleclick 축소판. 종전에는 `thisLayer.play/pause/stop` 이 레이어 심에 아예
    /// 없어서(playAnimation/pauseAnimation/stopAnimation 만 있었다) 호출 즉시
    /// `TypeError: thisLayer.pause is not a function` 이 나고, evaluateBool 이 nil 을 반환해 "현상
    /// 유지"로 삼켜졌다 — 정적 value:true 가 남아 클릭이 없어도 파티클이 계속 방출됐다.
    /// WE 는 init 에서 pause 하므로 무클릭 = 무방출이어야 한다.
    func testThisLayerPauseStopsParticleEmission() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"particle":"particles/snow.json","origin":"10 10 0",
           "visible":{"value":true,"script":
             "export function update(v){ if (input.cursorLeftDown) thisLayer.play(); else thisLayer.pause(); return v; }\\nexport function init(){ thisLayer.pause(); }"}}]}
        """
        let p = pkg(scene: scene)
        let doc = try SceneDocument.parse(package: p)
        let renderer = renderer(for: doc, package: p, device: device)
        XCTAssertEqual(renderer.particleSystems.count, 1)
        XCTAssertTrue(renderer.particleScriptVisible(0, time: 0),
                      "visible 은 value 를 그대로 돌려주므로 계속 true — 게이트는 방출 쪽이다")
        XCTAssertEqual(renderer.scriptParticleEmissionPaused[0], true,
                       "thisLayer.pause() 가 방출 게이트를 꺼야(종전엔 TypeError 로 스크립트 전체가 죽었다)")
    }

    /// 대조군: 같은 스크립트라도 play() 로 끝나면 방출이 유지돼야 한다(플래그가 한 방향으로만 굳지 않음).
    func testThisLayerPlayResumesParticleEmission() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"particle":"particles/snow.json","origin":"10 10 0",
           "visible":{"value":true,"script":
             "export function update(v){ thisLayer.pause(); thisLayer.play(); return v; }"}}]}
        """
        let p = pkg(scene: scene)
        let doc = try SceneDocument.parse(package: p)
        let renderer = renderer(for: doc, package: p, device: device)
        _ = renderer.particleScriptVisible(0, time: 0)
        XCTAssertEqual(renderer.scriptParticleEmissionPaused[0], false)
    }

    /// 파티클마다 thisLayer 가 분리돼야 한다 — 종전 thisLayer 는 전역 기본값(thisScene.layers[0])이라
    /// 한 씬의 두 파티클이 같은 객체를 밟았다. 한쪽만 pause 하면 다른 쪽은 영향이 없어야 한다.
    func testPlaybackStateIsPerParticleSystem() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[
           {"id":1,"particle":"particles/snow.json","origin":"10 10 0",
            "visible":{"value":true,"script":"export function update(v){ thisLayer.pause(); return v; }"}},
           {"id":2,"particle":"particles/snow.json","origin":"20 20 0",
            "visible":{"value":true,"script":"export function update(v){ return v; }"}}]}
        """
        let p = pkg(scene: scene)
        let doc = try SceneDocument.parse(package: p)
        let renderer = renderer(for: doc, package: p, device: device)
        XCTAssertEqual(renderer.particleSystems.count, 2)
        _ = renderer.particleScriptVisible(0, time: 0)
        _ = renderer.particleScriptVisible(1, time: 0)
        XCTAssertEqual(renderer.scriptParticleEmissionPaused[0], true)
        XCTAssertEqual(renderer.scriptParticleEmissionPaused[1], false,
                       "다른 시스템의 pause() 가 넘어오면 안 됨(thisLayer 공유 결함)")
    }

    /// teardown 이 방출 게이트를 비워야 한다(형제 scriptVisible/scriptTextVisible/scriptParticleVisible
    /// 과 같은 규약). 이쪽은 남으면 더 고약하다 — 스크립트 **없는** 파티클은 이 항목을 다시 쓰지 않으므로
    /// 다음 마운트에서 같은 인덱스가 영구 무방출로 굳는다.
    func testTeardownClearsEmissionGate() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"particle":"particles/snow.json","origin":"10 10 0",
           "visible":{"value":true,"script":"export function update(v){ thisLayer.pause(); return v; }"}}]}
        """
        let p = pkg(scene: scene)
        let doc = try SceneDocument.parse(package: p)
        let renderer = renderer(for: doc, package: p, device: device)
        _ = renderer.particleScriptVisible(0, time: 0)
        XCTAssertEqual(renderer.scriptParticleEmissionPaused[0], true)
        renderer.teardown()
        XCTAssertNil(renderer.scriptParticleEmissionPaused[0],
                     "마운트 재사용 stale 방지 — teardown 이 비워야")
    }
}
