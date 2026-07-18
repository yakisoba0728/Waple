import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

/// F201 후속: parseEffects 가 visible={value:false,script} 이펙트를 SceneEffect[] 에 보존하지만(72733ad),
/// per-frame 소비(런타임 토글)가 아직 없어 그대로 GPU 이펙트 체인에 태우면 "항상 미적용"이던 구 동작이
/// "항상 적용"으로 뒤집힌다 — 실 코퍼스 17씬(2902406982·3113287126·3538758087 등)의 이벤트-훅 이펙트가
/// 구 정적 상태(OFF)와 우연히 일치했었는데, 파스 보존만으로 그 상태가 깨진다. 소비 배선 전까지는
/// initialVisible==false 인 이펙트를 buildLayers(빌드/적용 단계)에서 게이트해 구 시각 거동을 복원한다 —
/// 파스 구조체엔 여전히 보존(데이터 무손실, 향후 소비 배선 시 이 게이트만 풀면 됨).
final class EffectVisibleScriptRenderTests: XCTestCase {
    private let model = #"{"width":100,"height":100,"material":"materials/m.json"}"#
    private let material = #"{"passes":[{"textures":["pic"]}]}"#

    private func pkg(scene: String) -> ScenePackage {
        ScenePackage.assemble([
            (name: "scene.json", data: Data(scene.utf8)),
            (name: "models/x.json", data: Data(model.utf8)),
            (name: "materials/m.json", data: Data(material.utf8)),
            (name: "materials/pic.tex", data: solidTex(255, 255, 255)),
        ])
    }

    /// visible={value:false,script} 이펙트는 파스에는 남지만(F201 보존, 회귀 재확인) 빌드된 GPU 레이어의
    /// 실제 이펙트 체인에는 태워지면 안 된다(소비 배선 전 구 거동 복원).
    func testFalseInitialScriptEffectParsedButNotAppliedInRenderChain() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"50 50 0","size":"10 10",
           "effects":[{"file":"effects/tint/effect.json","passes":[{"combos":{"BLENDMODE":2},
             "constantshadervalues":{"color":"1 0 0","alpha":1}}],
             "visible":{"value":false,"script":"export function update(v){ return true; }"}}]}]}
        """
        let p = pkg(scene: scene)
        let doc = try SceneDocument.parse(package: p)
        // 파스 보존 재확인(F201 원 수정, 회귀 방지) — 이 단정은 이번 수정으로도 계속 성립해야 한다.
        XCTAssertEqual(doc.layers[0].effects.count, 1, "파스는 여전히 보존해야(F201)")
        XCTAssertFalse(doc.layers[0].effects[0].initialVisible)
        XCTAssertNotNil(doc.layers[0].effects[0].visibleScript)

        // 빌드된 실제 GPU 이펙트 체인엔 적용되면 안 됨(소비 배선 전 구 거동).
        let built = SceneRenderer().buildLayers(doc: doc, package: p, device: device, sceneID: "eff-gate-false")
        XCTAssertEqual(built.count, 1)
        XCTAssertTrue(built[0].effects.isEmpty, "initialVisible=false 스크립트 이펙트는 소비 배선 전까지 렌더 체인에서 빠져야")
    }

    /// 가드: 정적 visible:true(스크립트 없음) 이펙트는 그대로 렌더 체인에 남아야(무회귀).
    func testStaticTrueVisibleEffectStillAppliedInRenderChain() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"50 50 0","size":"10 10",
           "effects":[{"file":"effects/tint/effect.json","passes":[{"combos":{"BLENDMODE":2},
             "constantshadervalues":{"color":"1 0 0","alpha":1}}]}]}]}
        """
        let p = pkg(scene: scene)
        let doc = try SceneDocument.parse(package: p)
        let built = SceneRenderer().buildLayers(doc: doc, package: p, device: device, sceneID: "eff-gate-static")
        XCTAssertEqual(built[0].effects.count, 1, "정적 visible 이펙트는 계속 적용돼야(무회귀)")
    }

    /// 가드: visible={value:true,script} 로 시작하는 이펙트는 initialVisible=true 라 계속 적용돼야 —
    /// 게이트는 initialVisible==false 만 막는다(스크립트 유무 자체로 막지 않음).
    func testTrueInitialScriptEffectStillAppliedInRenderChain() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"50 50 0","size":"10 10",
           "effects":[{"file":"effects/tint/effect.json","passes":[{"combos":{"BLENDMODE":2},
             "constantshadervalues":{"color":"1 0 0","alpha":1}}],
             "visible":{"value":true,"script":"export function update(v){ return false; }"}}]}]}
        """
        let p = pkg(scene: scene)
        let doc = try SceneDocument.parse(package: p)
        let built = SceneRenderer().buildLayers(doc: doc, package: p, device: device, sceneID: "eff-gate-true-start")
        XCTAssertEqual(built[0].effects.count, 1,
                       "initialVisible=true 로 시작하면 스크립트가 향후 false 를 반환해도(미소비) 현재는 계속 적용돼야")
    }
}
