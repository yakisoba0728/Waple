import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// F201 후속 + X-⑥(소비 배선 완료): parseEffects 가 visible={value:false,script} 이펙트를 SceneEffect[]
/// 에 보존한다(72733ad). buildEffectChain 은 이제 스크립트를 update 유무로 분류한다:
///  · hasUpdate(시간/오디오 등 매 프레임 값이 바뀔 수 있는 진짜 동적 스크립트) → per-frame 게이트로 렌더
///    체인에 상시 보존(EffectGPU.visibleGate) — 매 프레임 재평가해 켜고 끈다.
///  · update 없음(init-only, 이벤트 훅만 있고 update 없는 경우 포함) → 빌드 시점 1 회 정적 해석
///    (engine.evaluateBool). 결과가 세션 내내 불변이므로 게이트 없이 곧바로 적용/드롭 확정 —
///    구 "소비 배선 전" 거동과 완전히 동형(비트동일: false 로 해석되면 여전히 렌더 체인에서 빠지고
///    noInterp 레이어의 nearest 파이프라인 판정(effects.isEmpty 참조)도 종전대로 유지된다).
/// 실 코퍼스 17씬(2902406982·3113287126·3538758087 등)의 이벤트-훅 이펙트는 update 도 의미있는 init
/// 반환도 없어(hook 함수만 export) 정적 해석이 eff.initialVisible(false)로 폴백 — 구 드롭과 동치.
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

    /// init-only(update 없는) 스크립트는 standalone TextScriptEngine(비-shared 컨텍스트, sceneScript 없이
    /// buildLayers 를 직접 호출하는 위 헬퍼가 쓰는 생성자)이 `update` 함수 존재를 강제하는 탓에 여기선
    /// 아예 nil 로 생성 실패한다 — 공유 씬 컨텍스트(mount() 가 buildLayers 이전에 sceneScript 를 채움,
    /// SceneRenderer.swift:1144→1208)에서만 init-only 스크립트가 정상 구성된다. 따라서 정적 해석
    /// 분기(update 없음)를 검증하는 아래 두 테스트만 실 mount() 경로를 쓴다.
    private func mountForInspection(scene: String, tag: String) throws -> SceneRenderer? {
        guard MTLCreateSystemDefaultDevice() != nil else { return nil }
        let pkgData = encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/x.json", model.data(using: .utf8)!),
            ("materials/m.json", material.data(using: .utf8)!),
            ("materials/pic.tex", solidTex(255, 255, 255)),
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_insp_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pkgData.write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        return r
    }

    /// hasUpdate(진짜 동적) 스크립트는 initialVisible=false 로 시작해도 이제 렌더 체인에 남아
    /// per-frame 게이트로 판정된다(X-⑥ 신규 배선) — 게이트의 현재값은 빌드 시점엔 initial 그대로(false).
    func testFalseInitialUpdateScriptEffectStaysInChainViaGate() throws {
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
        // 파스 보존 재확인(F201 원 수정, 회귀 방지).
        guard let parsedEff = doc.layers.first?.effects.first else {
            return XCTFail("파스는 여전히 보존해야(F201)")
        }
        XCTAssertFalse(parsedEff.initialVisible)
        XCTAssertNotNil(parsedEff.visibleScript)

        let built = SceneRenderer().buildLayers(doc: doc, package: p, device: device, sceneID: "eff-gate-dyn-false")
        guard let builtEff = built.first?.effects.first else {
            return XCTFail("hasUpdate 스크립트는 X-⑥ 배선 후 렌더 체인에 남아야(게이트가 판정)")
        }
        XCTAssertNotNil(builtEff.visibleGate, "동적(hasUpdate) 스크립트는 게이트가 결속돼야")
        XCTAssertEqual(builtEff.visibleGate?.current, false, "게이트 현재값은 빌드 시점엔 initialVisible 그대로")
    }

    /// init-only(update 없음) 스크립트가 정적으로 false 로 해석되면 — 구 "소비 배선 전" 거동과 완전히
    /// 동형으로 렌더 체인에서 빠져야 한다(비트동일: 게이트 없이 build 시점에 완전히 드롭 — effects.isEmpty
    /// 의미가 noInterp nearest 판정 등 다른 소비처에도 그대로 보존된다).
    func testFalseInitialInitOnlyScriptEffectStaysDroppedFromRenderChain() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"50 50 0","size":"10 10",
           "effects":[{"file":"effects/tint/effect.json","passes":[{"combos":{"BLENDMODE":2},
             "constantshadervalues":{"color":"1 0 0","alpha":1}}],
             "visible":{"value":false,"script":"function init(){ return false; }"}}]}]}
        """
        guard let r = try mountForInspection(scene: scene, tag: "static-false") else { throw XCTSkip("no Metal") }
        defer { r.teardown() }
        XCTAssertEqual(r.layers.count, 1)
        XCTAssertTrue(r.layers[0].effects.isEmpty,
                      "init-only 스크립트가 false 로 정적 해석되면 구 거동과 동형으로 렌더 체인에서 빠져야")
    }

    /// init-only 스크립트가 정적으로 true 로 해석되면 렌더 체인에 남되, 값이 세션 내내 불변이므로
    /// 게이트(visibleGate) 없이 곧바로 확정 적용된다(effects.isEmpty 의미 보존 — noInterp 소비처가
    /// "이번 프레임 무이펙트"를 여전히 정확히 판정할 수 있다).
    func testFalseInitialInitOnlyScriptEffectResolvingTrueAppliesStaticallyNoGate() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"50 50 0","size":"10 10",
           "effects":[{"file":"effects/tint/effect.json","passes":[{"combos":{"BLENDMODE":2},
             "constantshadervalues":{"color":"1 0 0","alpha":1}}],
             "visible":{"value":false,"script":"function init(){ return true; }"}}]}]}
        """
        guard let r = try mountForInspection(scene: scene, tag: "static-true") else { throw XCTSkip("no Metal") }
        defer { r.teardown() }
        XCTAssertEqual(r.layers.count, 1)
        XCTAssertEqual(r.layers[0].effects.count, 1, "init-only 스크립트가 true 로 정적 해석되면 적용돼야")
        XCTAssertNil(r.layers[0].effects.first?.visibleGate, "정적 해석 결과는 불변이므로 게이트가 불요")
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
        guard let builtEff = built.first?.effects.first else {
            return XCTFail("정적 visible 이펙트는 계속 적용돼야(무회귀)")
        }
        XCTAssertNil(builtEff.visibleGate, "스크립트 없는 정적 이펙트는 게이트가 불요")
    }

    /// 가드: visible={value:true,script} 로 시작하는 hasUpdate 스크립트는 initialVisible=true 라
    /// 계속 적용돼야(게이트가 존재하되 초기값은 true) — X-⑥ 이전엔 initialVisible==false 만 막는
    /// 게이트였고, 지금도 hasUpdate 스크립트는 항상 렌더 체인에 남되(게이트로 판정) initial=true 라
    /// 이 시점(빌드 직후)엔 여전히 켜져 있다.
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
        guard let builtEff = built.first?.effects.first else {
            return XCTFail("initialVisible=true 로 시작하면 빌드 직후(게이트 initial=true) 계속 적용돼야")
        }
        XCTAssertNotNil(builtEff.visibleGate, "hasUpdate 스크립트는 게이트가 결속돼야(향후 프레임에 false 로 꺼질 수 있음)")
    }
}
