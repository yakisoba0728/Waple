import XCTest
@testable import WapleCore

/// D1: combo 프로퍼티로 전환되는 오브젝트 가시성은 nested `{"user":{"condition":"<옵션값>","name":"<키>"}}`
/// 문법으로 인코딩된다(bare-string bool 바인딩과 별개). resolveUserBindings 가 nested 를 스킵하면
/// 저작 시점 default variant 가 영구 고착 — 유저가 콤보를 바꿔도 화면이 안 바뀐다.
final class SceneComboVisibleTests: XCTestCase {
    private func pkg(_ files: [(String, String)]) throws -> ScenePackage {
        try ScenePackage.parse(ScenePackageTests.makePkg(files.map { ($0.0, Data($0.1.utf8)) }))
    }
    private let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
    private let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#

    /// 유저가 combo `style`="1" 을 고르면 condition="1" variant 는 보이고 "2" variant 는 숨는다.
    /// 저작 스냅샷은 반대(A=false, B=true)라, nested 미해석이면 A 드롭·B 유지로 red.
    func testComboVisibleNestedSelectsChosenVariant() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"variantA","image":"models/x.json","origin":"50 50 0","size":"10 10",
            "visible":{"user":{"condition":"1","name":"style"},"value":false}},
           {"id":2,"name":"variantB","image":"models/x.json","origin":"50 50 0","size":"10 10",
            "visible":{"user":{"condition":"2","name":"style"},"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p, userProps: ["style": "1"])
        XCTAssertTrue(doc.layers.contains { $0.name == "variantA" }, "선택한 콤보값(1) variant 표시")
        XCTAssertFalse(doc.layers.contains { $0.name == "variantB" }, "비선택 콤보값(2) variant 숨김")
    }

    /// 회귀: bare-string user 바인딩(bool)은 기존대로 override 로 갱신된다(if 분기 불변).
    /// toggle=false 오버라이드 → 스크립트 없는 정적 false → 레이어 드롭.
    func testBareStringUserBindingStillResolves() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"toggled","image":"models/x.json","origin":"50 50 0","size":"10 10",
            "visible":{"user":"toggle","value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        XCTAssertEqual(try SceneDocument.parse(package: p, userProps: ["toggle": false]).layers.count, 0)
    }

    /// 효과 visible=false(정적 bool + 사용자 토글 OFF)는 미적용(WE 규약). 종전엔 무시 → 꺼진
    /// post-process(3489263099 halftone=bwhalftone OFF)가 적용돼 전화면 흑화. {user,value} 는
    /// resolveUserBindings 가 정적 value 로 해석하므로 파스 시점 필터가 정답.
    func testDisabledEffectsAreDroppedAtParse() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"L","image":"models/x.json","origin":"50 50 0","size":"10 10",
            "effects":[
              {"file":"effects/on1/effect.json"},
              {"file":"effects/off1/effect.json","visible":false},
              {"file":"effects/on2/effect.json","visible":true},
              {"file":"effects/off2/effect.json","visible":{"user":"bwhalftone","value":false}}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let layer = try XCTUnwrap(doc.layers.first { $0.name == "L" })
        XCTAssertEqual(layer.effects.count, 2, "visible=false 효과 2개(off1 정적·off2 유저OFF) 제외")
        XCTAssertTrue(layer.effects.contains { $0.file.contains("on1") }, "visible 부재=활성")
        XCTAssertTrue(layer.effects.contains { $0.file.contains("on2") }, "visible=true 유지")
        XCTAssertFalse(layer.effects.contains { $0.file.contains("off") }, "꺼진 효과는 미적용")
    }

    /// color 프로퍼티 스크립트의 저장 `scriptproperties`(사용자 오버라이드)를 파스가 보존하는지 —
    /// 미보존 시 스크립트가 소스 기본값(흰색 fallback)을 반환해 전화면 백화(3300031038). {user,value}
    /// 바인딩은 정적 value 로 해석(스크립트는 정적 값을 기대 — resolveUserBindings 규약).
    func testColorScriptPropertiesPreservedAtParse() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"L","image":"models/x.json","origin":"50 50 0","size":"10 10",
            "color":{"script":"export function update(v){return v;}","value":"0.3 0.2 0.4",
                     "scriptproperties":{"fallbackColor":"0.3 0.2 0.4","useFallbackColor":false,
                                         "enabled":{"user":"musicplayer","value":true}}}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let layer = try XCTUnwrap(doc.layers.first { $0.name == "L" })
        let json = try XCTUnwrap(layer.propertyScriptProps["color"], "color scriptproperties 보존")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["fallbackColor"] as? String, "0.3 0.2 0.4")
        XCTAssertEqual(obj["useFallbackColor"] as? Bool, false)
        XCTAssertEqual(obj["enabled"] as? Bool, true, "{user,value} 바인딩 → 정적 value 로 해석")
    }
}
