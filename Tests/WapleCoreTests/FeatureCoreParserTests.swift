import XCTest
@testable import WapleCore

final class FeatureCoreParserTests: XCTestCase {
    private func document(_ objects: String) throws -> SceneDocument {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":\(objects)}
        """
        return try SceneDocument.parse(package: ScenePackage.assemble([("scene.json", Data(scene.utf8))]))
    }

    func testTextStyleDefaultsComeFromOriginalConstructor() throws {
        let t = try XCTUnwrap(document(#"[{"id":1,"text":"test"}]"#).texts.first)
        XCTAssertFalse(t.msdf)
        XCTAssertFalse(t.blur)
        XCTAssertFalse(t.dropShadow)
        XCTAssertEqual(t.blurSize, 6)
        XCTAssertEqual(t.dropShadowSize, 6)
        XCTAssertEqual(t.dropShadowOpacity, 1)
        XCTAssertEqual(t.dropShadowColor, Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(t.dropShadowOffset, Vec2(x: 4, y: 4))
    }

    func testTextStyleFieldsPreserveAuthoredValuesAndBooleanTags() throws {
        let t = try XCTUnwrap(document(#"[{"id":1,"text":"test","msdf":true,"blur":{"value":true},"dropshadow":true,"blursize":9,"dropshadowsize":12,"dropshadowopacity":0.25,"dropshadowcolor":"0.2 0.4 0.6","dropshadowoffset":"3 7"}]"#).texts.first)
        XCTAssertTrue(t.msdf)
        XCTAssertTrue(t.blur)
        XCTAssertTrue(t.dropShadow)
        XCTAssertEqual(t.blurSize, 9)
        XCTAssertEqual(t.dropShadowSize, 12)
        XCTAssertEqual(t.dropShadowOpacity, 0.25)
        XCTAssertEqual(t.dropShadowColor, Vec3(x: 0.2, y: 0.4, z: 0.6))
        XCTAssertEqual(t.dropShadowOffset, Vec2(x: 3, y: 7))
        let wrong = try XCTUnwrap(document(#"[{"id":1,"text":"test","blur":1,"dropshadow":"true"}]"#).texts.first)
        XCTAssertFalse(wrong.blur)
        XCTAssertFalse(wrong.dropShadow)
    }

    func testTextVec2DistinguishesStringPrefixFromNumericBroadcast() throws {
        let string = try XCTUnwrap(document(#"[{"id":1,"text":"test","spacing":"3px","padding":"5"}]"#).texts.first)
        XCTAssertEqual(string.spacing, Vec2(x: 3, y: 0))
        XCTAssertEqual(string.padding, Vec2(x: 5, y: 0))
        let numeric = try XCTUnwrap(document(#"[{"id":1,"text":"test","spacing":3,"padding":5}]"#).texts.first)
        XCTAssertEqual(numeric.spacing, Vec2(x: 3, y: 3))
        XCTAssertEqual(numeric.padding, Vec2(x: 5, y: 5))
        let pair = try XCTUnwrap(document(#"[{"id":1,"text":"test","spacing":"3px 7px","padding":true}]"#).texts.first)
        XCTAssertEqual(pair.spacing, Vec2(x: 3, y: 7))
        XCTAssertEqual(pair.padding, Vec2(x: 32, y: 32))
    }

    func testSoundPreservesLocalTransformAndParentForSpatialConsumer() throws {
        let sound = try XCTUnwrap(document(#"[{"id":1,"sound":["sounds/a.wav"],"origin":"2 3 4","angles":"0.1 0.2 0.3","scale":"2 4 6","parent":9}]"#).sounds.first)
        XCTAssertEqual(sound.origin, Vec3(x: 2, y: 3, z: 4))
        XCTAssertEqual(sound.angles, Vec3(x: 0.1, y: 0.2, z: 0.3))
        XCTAssertEqual(sound.scale, Vec3(x: 2, y: 4, z: 6))
        XCTAssertEqual(sound.parent, 9)
        let defaults = try XCTUnwrap(document(#"[{"id":1,"sound":"sounds/a.wav"}]"#).sounds.first)
        XCTAssertEqual(defaults.origin, Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(defaults.scale, Vec3(x: 1, y: 1, z: 1))
        XCTAssertNil(defaults.parent)
    }

    func testTubeLightUsesOriginalControlPointAndConstructorDefault() throws {
        let defaults = try XCTUnwrap(document(#"[{"id":1,"light":"ltube"}]"#).lights3D.first)
        XCTAssertEqual(defaults.originB, Vec3(x: 2, y: 0, z: 0))
        let authored = try XCTUnwrap(document(#"[{"id":1,"light":"ltube","controlpoint":"4 5 6","originb":"7 8 9"}]"#).lights3D.first)
        XCTAssertEqual(authored.originB, Vec3(x: 4, y: 5, z: 6))
    }

    func testModelNodeLightAndAnimationLayerKeepCurvesWithoutEvents() throws {
        func binding(_ value: Any, _ end: Float) -> [String: Any] {
            ["value": value, "animation": ["c0": [["frame": 0, "value": 0, "frontenabled": false],
                                                 ["frame": 30, "value": end, "backenabled": false]],
                                           "options": ["fps": 30, "length": 30, "mode": "single"]]]
        }
        let objects: [[String: Any]] = [
            ["id": 1, "model": "models/m.mdl", "origin": binding("0 0 0", 10), "color": "0.2 0.4 0.6", "alpha": 0.25,
             "visible": binding(false, 1),
             "animationlayers": [["name": "pose", "blend": binding(0, 1)]]],
            ["id": 2, "origin": binding("0 0 0", 20)],
            ["id": 3, "light": "lpoint", "intensity": binding(0, 30)]
        ]
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: objects), encoding: .utf8))
        let doc = try document(json)
        let model = try XCTUnwrap(doc.objects3D.first)
        XCTAssertFalse(model.initialVisible, "A future visibility curve must keep the model in the scene")
        XCTAssertEqual(model.color, Vec3(x: 0.2, y: 0.4, z: 0.6))
        XCTAssertEqual(model.alpha, 0.25)
        XCTAssertEqual(try XCTUnwrap(model.propertyAnimations["origin"]).value(component: 0, atTime: 1, base: 0), 10)
        XCTAssertEqual(try XCTUnwrap(model.animationLayers.first?.propertyAnimations["blend"]).value(component: 0, atTime: 1, base: 0), 1)
        XCTAssertEqual(try XCTUnwrap(doc.nodes3D.first(where: { $0.id == 2 })?.propertyAnimations["origin"]).value(component: 0, atTime: 1, base: 0), 20)
        XCTAssertEqual(try XCTUnwrap(doc.lights3D.first?.propertyAnimations["intensity"]).value(component: 0, atTime: 1, base: 0), 30)
    }
}
