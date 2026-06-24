import XCTest
@testable import WapleCore

final class SceneEffectCombosTests: XCTestCase {
    private func d(_ s: String) -> Data { s.data(using: .utf8)! }

    func testParsesCombosAndAudioMode() {
        // image layer 객체에 pulse 효과(AUDIOPROCESSING/BLENDMODE 콤보) — 텍스처 누락이어도 effects 는 파싱.
        let scene = """
        {"objects":[{"id":1,"image":"models/x.json","origin":"0 0 0",
          "effects":[{"file":"effects/pulse/effect.json","passes":[{
             "combos":{"AUDIOPROCESSING":3,"BLENDMODE":9,"PULSEALPHA":1},
             "constantshadervalues":{"audioamount":1,"audiobounds":"0 1","amount":1.5}}]}]}]}
        """
        // image 가 디코드 실패하면 layer 가 스킵되므로, model+material+tex 엔트리를 갖춰 layer 생성.
        let model = #"{"material":"materials/x.json"}"#
        let material = #"{"passes":[{"textures":["x"]}]}"#
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("models/x.json", d(model)),
            ("materials/x.json", d(material)),
            ("materials/x.tex", d("not-a-real-tex")),  // 엔트리 존재 → textureEntryName 해석됨(렌더 시 디코드 실패는 무관)
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        let eff = try! XCTUnwrap(doc.layers.first?.effects.first)
        XCTAssertEqual(eff.name, "pulse")
        XCTAssertEqual(eff.audioMode, 3)
        XCTAssertEqual(eff.combos["BLENDMODE"], 9)
        XCTAssertEqual(eff.combos["PULSEALPHA"], 1)
        XCTAssertEqual(eff.constants["amount"], [1.5])
        XCTAssertEqual(eff.constants["audiobounds"], [0, 1])
    }

    func testNoCombosDefaultsEmpty() {
        let e = SceneEffect(name: "x", constants: [:], textureNames: [])
        XCTAssertEqual(e.audioMode, 0)
        XCTAssertTrue(e.combos.isEmpty)
    }
}
