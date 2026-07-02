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

    /// 실물(3147346398): origin/alpha 가 애니메이션 바인딩 객체 {"animation":{...},"value":X} 로 온다.
    /// 정적 value 를 언랩해야 배치/투명도가 맞는다(애니메이션 재생은 후속 기능).
    func testBindingObjectValueUnwrapped() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json",
                     "origin":{"animation":{"fps":30},"value":"1920.5 673.6 0"},
                     "size":"1000 256","scale":{"value":"1 0.5 1"},
                     "alpha":{"animation":{},"value":0.25},"color":{"value":"0 1 0"},
                     "brightness":1,"visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.layers.count, 1)
        let l = doc.layers[0]
        XCTAssertEqual(l.origin.x, 1920.5, accuracy: 0.01)
        XCTAssertEqual(l.origin.y, 673.6, accuracy: 0.01)
        XCTAssertEqual(l.scale, Vec2(x: 1, y: 0.5))
        XCTAssertEqual(l.alpha, 0.25)
        XCTAssertEqual(l.color, Vec3(x: 0, y: 1, z: 0))
    }

    /// 공유(base-assets) 모델/머티리얼 JSON 폴백: pkg 에 없는 models/util/solidlayer.json 을 assets 리졸버가
    /// 제공하면 레이어가 살아난다. 무텍스처 머티리얼(flat) → textureEntryName "" (솔리드 마커).
    func testSolidLayerResolvedFromAssetsFallback() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/util/solidlayer.json","origin":"960 540 0","size":"1920 1080",
                     "alpha":0.5,"color":"0 0 0","visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene)])
        let assets: [String: String] = [
            "models/util/solidlayer.json": #"{"material":"materials/util/solidlayer.json","solidlayer":true}"#,
            "materials/util/solidlayer.json": #"{"passes":[{"shader":"flat","blending":"translucent"}]}"#,
        ]
        let doc = try SceneDocument.parse(package: p, assets: { assets[$0].map { Data($0.utf8) } })
        XCTAssertEqual(doc.layers.count, 1, "solidlayer 는 assets 폴백으로 해석돼야")
        XCTAssertEqual(doc.layers[0].textureEntryName, "", "무텍스처 머티리얼 → 솔리드 마커")
        XCTAssertEqual(doc.layers[0].alpha, 0.5)
    }

    /// solid_instance 패턴: 모델은 pkg, 머티리얼은 assets(genericimage2 + util/white).
    func testInstanceMaterialFromAssetsResolvesTexture() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/solid_instance_model_x.json","origin":"960 540 0","size":"256 256",
                     "visible":{"value":true}}]}
        """
        let p = try pkg([
            ("scene.json", scene),
            ("models/solid_instance_model_x.json", #"{"instanced":true,"material":"materials/util/solidlayer_instance.json","solidlayer":true}"#),
        ])
        let assets: [String: String] = [
            "materials/util/solidlayer_instance.json": #"{"passes":[{"shader":"genericimage2","textures":["util/white"]}]}"#,
        ]
        let doc = try SceneDocument.parse(package: p, assets: { assets[$0].map { Data($0.utf8) } })
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.layers[0].textureEntryName, "materials/util/white.tex")
    }

    /// _rt_ 텍스처(프레임버퍼 참조 = 컴포지션 의미론)는 이번 단계 미지원 — 명시 스킵.
    func testFrameBufferTextureLayerSkipped() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/util/fullscreenlayer.json","origin":"960 540 0","size":"1920 1080",
                     "visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene)])
        let assets: [String: String] = [
            "models/util/fullscreenlayer.json": #"{"material":"materials/util/fullscreenlayer.json","fullscreen":true}"#,
            "materials/util/fullscreenlayer.json": #"{"passes":[{"shader":"passthrough","textures":["_rt_FullFrameBuffer"]}]}"#,
        ]
        let doc = try SceneDocument.parse(package: p, assets: { assets[$0].map { Data($0.utf8) } })
        XCTAssertEqual(doc.layers.count, 0, "_rt_ 레이어는 컴포지션 SP 전까지 스킵")
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
