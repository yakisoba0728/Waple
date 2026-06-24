import XCTest
@testable import WapleCore

final class SceneDocumentTests: XCTestCase {
    private func pkg(_ files: [(String, String)]) throws -> ScenePackage {
        try ScenePackage.parse(ScenePackageTests.makePkg(files.map { ($0.0, Data($0.1.utf8)) }))
    }

    private let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
    private let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#

    func testParsesSingleImageLayer() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0.7 0.7 0.7"},
         "objects":[{"image":"models/x.json","origin":"960 540 0","size":"1920 1080","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1.0,"color":"1 1 1","brightness":1.0,"visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.projectionWidth, 1920)
        XCTAssertEqual(doc.clearColor, Vec3(x: 0.7, y: 0.7, z: 0.7))
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.layers[0].textureEntryName, "materials/pic.tex")
        XCTAssertEqual(doc.layers[0].origin, Vec2(x: 960, y: 540))
        XCTAssertEqual(doc.layers[0].size, Vec2(x: 1920, y: 1080))
    }

    func testSkipsSoundAndInvisibleObjects() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"sound":["sounds/a.mp3"],"origin":"0 0 0"},
                    {"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":false}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        XCTAssertEqual(try SceneDocument.parse(package: p).layers.count, 0)
    }

    /// `visible` 이 평문 불리언 false(바인딩 객체가 아님)일 때도 레이어를 숨겨야 한다.
    func testSkipsLayerWithLiteralBoolVisibleFalse() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":false}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        XCTAssertEqual(try SceneDocument.parse(package: p).layers.count, 0)
    }

    /// 베이스 머티리얼의 첫 텍스처 슬롯이 null 이어도 첫 non-null 텍스처로 레이어를 해석해야 한다.
    func testResolvesTextureWhenFirstSlotIsNull() throws {
        let materialNullFirst = #"{"passes":[{"shader":"genericimage2","textures":[null,"pic"]}]}"#
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", materialNullFirst)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.layers[0].textureEntryName, "materials/pic.tex")
    }

    func testSkipsLayerWithMissingModel() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/missing.json","origin":"0 0 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene)])
        XCTAssertEqual(try SceneDocument.parse(package: p).layers.count, 0)
    }

    func testNoSceneThrows() throws {
        let p = try pkg([("other.json", "{}")])
        XCTAssertThrowsError(try SceneDocument.parse(package: p)) { e in
            XCTAssertEqual(e as? SceneDocumentError, .noScene)
        }
    }

    /// angleZ 는 angles[2](Z 회전), scale 은 size 에 곱해지는 2D 스케일을 파싱해야 한다.
    func testParsesAngleZAndScale() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"2 3 1",
                     "angles":"10 20 30","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let layer = try XCTUnwrap(try SceneDocument.parse(package: p).layers.first)
        XCTAssertEqual(layer.angleZ, 30, accuracy: 1e-6)
        XCTAssertEqual(layer.scale, Vec2(x: 2, y: 3))
    }

    func testParsesParallaxDepthAndGeneral() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0",
                    "cameraparallax":true,"cameraparallaxamount":0.5,"cameraparallaxmouseinfluence":0.25},
         "objects":[{"image":"models/x.json","origin":"960 540 0","size":"1920 1080","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,
                     "parallaxDepth":"1.5 0.5","visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertTrue(doc.parallaxEnabled)
        XCTAssertEqual(doc.parallaxAmount, 0.5, accuracy: 1e-6)
        XCTAssertEqual(doc.parallaxMouseInfluence, 0.25, accuracy: 1e-6)
        XCTAssertEqual(doc.layers.first?.parallaxDepth, Vec2(x: 1.5, y: 0.5))
    }

    func testParsesObjectEffects() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true},
                     "effects":[{"file":"effects/waterwaves/effect.json",
                       "passes":[{"constantshadervalues":{"speed":3.97,"scale":34.66},
                                  "textures":[null,"masks/wmask"]}]}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let eff = try XCTUnwrap(try SceneDocument.parse(package: p).layers.first?.effects.first)
        XCTAssertEqual(eff.name, "waterwaves")
        XCTAssertEqual(eff.constants["speed"], [3.97])
        XCTAssertEqual(eff.constants["scale"], [34.66])
        // slot0 = null (framebuffer), slot1 = mask
        XCTAssertEqual(eff.textureNames, [nil, "masks/wmask"])
    }

    /// 3개 슬롯 효과: [null(framebuffer), "effects/x", "util/white"] 전체를 textureNames 로 캡처.
    func testParsesThreeSlotEffectTextures() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true},
                     "effects":[{"file":"effects/waterripple/effect.json",
                       "passes":[{"constantshadervalues":{"ripple_strength":0.2},
                                  "textures":[null,"effects/x","util/white"]}]}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let eff = try XCTUnwrap(try SceneDocument.parse(package: p).layers.first?.effects.first)
        XCTAssertEqual(eff.name, "waterripple")
        XCTAssertEqual(eff.textureNames, [nil, "effects/x", "util/white"])
    }

    func testParsesVectorEffectConstants() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true},
                     "effects":[{"file":"effects/tint/effect.json",
                       "passes":[{"constantshadervalues":{"color":"1 0 0","alpha":0.5}}]}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let eff = try XCTUnwrap(try SceneDocument.parse(package: p).layers.first?.effects.first)
        XCTAssertEqual(eff.name, "tint")
        XCTAssertEqual(eff.constants["color"], [1, 0, 0])
        XCTAssertEqual(eff.constants["alpha"], [0.5])
    }

    func testLayerWithoutEffectsHasEmptyArray() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        XCTAssertEqual(try SceneDocument.parse(package: p).layers.first?.effects.count, 0)
    }

    func testParallaxDefaultsWhenAbsent() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertFalse(doc.parallaxEnabled)
        XCTAssertEqual(doc.parallaxAmount, 1, accuracy: 1e-6)
        XCTAssertEqual(doc.layers.first?.parallaxDepth, Vec2(x: 1, y: 1))
    }
}
