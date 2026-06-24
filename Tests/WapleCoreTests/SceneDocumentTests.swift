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
        XCTAssertEqual(eff.constants["speed"], 3.97)
        XCTAssertEqual(eff.constants["scale"], 34.66)
        XCTAssertEqual(eff.maskTextureName, "masks/wmask")
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
