import XCTest
@testable import WapleCore

/// F201: parseEffects 의 오브젝트 effects[] visible 판정이 정적 value 만 보고 스크립트를 고려하지 않아,
/// visible={value:false,script:...} 로 시작하는 이펙트가 SceneEffect[] 에서 영구 제외된다. 상위
/// 오브젝트 레벨(visible 게이트: visibleScript!=nil 이면 정적 false 여도 보존)이 이미 구축한 패턴을
/// 이 중첩된 effects[] 처리에 이식 — 파스 보존만(런타임 토글 소비는 TODO, 코퍼스 저빈도).
final class EffectVisibleScriptTests: XCTestCase {
    private func pkg(_ files: [(String, String)]) throws -> ScenePackage {
        try ScenePackage.parse(ScenePackageTests.makePkg(files.map { ($0.0, Data($0.1.utf8)) }))
    }
    private let model = #"{"width":100,"height":100,"material":"materials/m.json"}"#
    private let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#

    /// visible={value:false,script:...} 인 이펙트는 드롭되지 않고 initialVisible=false + visibleScript 로 보존.
    func testScriptBoundFalseVisibleEffectIsPreserved() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"50 50 0","size":"10 10",
           "effects":[{"file":"effects/foo/effect.json","passes":[{"combos":{}}],
                       "visible":{"value":false,"script":"export function update(v){ return true; }"}}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.layers[0].effects.count, 1, "스크립트 바인딩 이펙트는 정적 false 라도 영구 제외되면 안 됨")
        XCTAssertEqual(doc.layers[0].effects[0].initialVisible, false)
        XCTAssertEqual(doc.layers[0].effects[0].visibleScript, "export function update(v){ return true; }")
    }

    /// 가드: 스크립트 없는 정적 visible:false 이펙트는 기존대로 드롭(무회귀 — halftone 3489263099 류).
    func testStaticFalseVisibleWithoutScriptStillDropped() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"50 50 0","size":"10 10",
           "effects":[{"file":"effects/foo/effect.json","passes":[{"combos":{}}],"visible":{"value":false}}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.layers[0].effects.count, 0)
    }

    /// 가드: visible:true(스크립트 없음) 이펙트는 기존대로 포함 + initialVisible=true.
    func testStaticTrueVisibleEffectIncluded() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"50 50 0","size":"10 10",
           "effects":[{"file":"effects/foo/effect.json","passes":[{"combos":{}}]}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.layers[0].effects.count, 1)
        XCTAssertEqual(doc.layers[0].effects[0].initialVisible, true)
        XCTAssertNil(doc.layers[0].effects[0].visibleScript)
    }
}
