import XCTest
@testable import WapleCore

final class WallpaperPropertiesMetaTests: XCTestCase {
    func testParsesEditMeta() {
        let general: [String: Any] = [
            "spd": ["type": "slider", "value": 2.5, "text": "Speed", "min": 0.5, "max": 10.0, "step": 0.5, "order": 1],
            "mode": ["type": "combo", "value": "b", "text": "Mode", "order": 2,
                     "options": [["label": "First", "value": "a"], ["label": "Second", "value": "b"]]],
        ]
        let props = WallpaperProperties.parse(generalProperties: general)
        let spd = props.first { $0.key == "spd" }!
        XCTAssertEqual(spd.text, "Speed")
        XCTAssertEqual(spd.min, 0.5); XCTAssertEqual(spd.max, 10.0); XCTAssertEqual(spd.step, 0.5)
        let mode = props.first { $0.key == "mode" }!
        XCTAssertEqual(mode.options?.count, 2)
        XCTAssertEqual(mode.options?[1].label, "Second")
        XCTAssertEqual(mode.options?[1].value, .string("b"))
    }

    func testApplyingOverridesReplacesValues() {
        let general: [String: Any] = [
            "on": ["type": "bool", "value": true],
            "amt": ["type": "slider", "value": 1.0],
        ]
        let props = WallpaperProperties.parse(generalProperties: general)
        let eff = WallpaperProperties.applying(overrides: ["on": .bool(false)], to: props)
        XCTAssertEqual(eff.first { $0.key == "on" }?.value, .bool(false))
        XCTAssertEqual(eff.first { $0.key == "amt" }?.value, .number(1.0), "미오버라이드는 기본값")
        let json = WallpaperProperties.weUserPropertiesJSON(eff)
        XCTAssertTrue(json.contains("\"on\":{\"type\":\"bool\",\"value\":false}"), json)
    }
}

final class SceneUserBindingTests: XCTestCase {
    private func pkg(_ files: [(String, String)]) throws -> ScenePackage {
        try ScenePackage.parse(ScenePackageTests.makePkg(files.map { ($0.0, Data($0.1.utf8)) }))
    }
    private let model = #"{"material":"materials/m.json"}"#
    private let material = #"{"passes":[{"textures":["pic"]}]}"#

    /// 실물 패턴: `"visible": {"user": "showX", "value": true}` — 유저 오버라이드가 표시/숨김을 결정.
    func testUserBoundVisibleOverride() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10",
                     "visible":{"user":"showX","value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        XCTAssertEqual(try SceneDocument.parse(package: p).layers.count, 1, "오버라이드 없음 → 기본 true")
        let hidden = try SceneDocument.parse(package: p, userProps: ["showX": false])
        XCTAssertEqual(hidden.layers.count, 0, "유저가 껐으면 숨김")
    }

    /// 수치/색 바인딩: `"alpha": {"user": "op", "value": 1.0}` → 오버라이드 값 사용.
    func testUserBoundAlphaAndColorOverride() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10",
                     "alpha":{"user":"op","value":1.0},
                     "color":{"user":"tintc","value":"1 1 1"},
                     "visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p, userProps: ["op": 0.3, "tintc": "1 0 0"])
        XCTAssertEqual(doc.layers[0].alpha, 0.3, accuracy: 0.001)
        XCTAssertEqual(doc.layers[0].color, Vec3(x: 1, y: 0, z: 0))
    }
}
