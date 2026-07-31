import XCTest
@testable import WapleCore

/// visible 프로퍼티 스크립트(실물 3394601417 'bt' — shared 컨트롤러가 visible 스크립트에 산다):
/// 파스는 스크립트가 있으면 레이어를 드롭하지 않고 수집하고, 정적 value 는 초기 표시로 남긴다.
final class SceneVisibleScriptTests: XCTestCase {

    private let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
    private let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#

    /// visible {"value":true,"script":...} → 레이어 유지 + 스크립트 수집 + initialVisible=true.
    func testVisibleScriptCollected() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,
                     "visible":{"value":true,"script":"export function update(v){ return !v; }"}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.layers[0].propertyScripts["visible"], "export function update(v){ return !v; }")
        XCTAssertTrue(doc.layers[0].initialVisible)
    }

    /// 정적 false 라도 스크립트가 있으면 드롭하지 않는다(런타임 토글 가능) — initialVisible=false.
    func testStaticFalseWithScriptKeepsLayer() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,
                     "visible":{"value":false,"script":"export function update(v){ return true; }"}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertFalse(doc.layers[0].initialVisible)
        XCTAssertNotNil(doc.layers[0].propertyScripts["visible"])
    }

    /// 스크립트 없는 정적 false 는 기존대로 드롭(회귀 방지).
    func testStaticFalseWithoutScriptStillDropped() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":false}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        XCTAssertEqual(try SceneDocument.parse(package: p).layers.count, 0)
    }
}
