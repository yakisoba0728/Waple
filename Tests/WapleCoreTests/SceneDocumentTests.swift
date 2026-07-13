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

    /// A2: general.hdr/bloom + 블룸 파라미터 파싱(종전 조용히 폐기 — lane-04 §2.1).
    func testParsesHDRAndBloomFlags() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},
          "hdr":true,"bloom":true,"bloomstrength":3.37,"bloomthreshold":0.36,
          "bloomhdrstrength":1.4,"bloomhdrthreshold":0.70},"objects":[]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertTrue(doc.hdr)
        XCTAssertTrue(doc.bloom)
        XCTAssertEqual(doc.bloomStrength, 3.37, accuracy: 1e-4)
        XCTAssertEqual(doc.bloomThreshold, 0.36, accuracy: 1e-4)
        XCTAssertEqual(doc.bloomHDRStrength, 1.4, accuracy: 1e-4)
        XCTAssertEqual(doc.bloomHDRThreshold, 0.70, accuracy: 1e-4)
    }

    /// hdr/bloom 부재 시 기본 false(종전 LDR 경로 유지 = 무회귀).
    func testHDRBloomDefaultFalseWhenAbsent() throws {
        let scene = #"{"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[]}"#
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertFalse(doc.hdr)
        XCTAssertFalse(doc.bloom)
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

    /// 퍼펫 layer 의 animationlayers 다층 파스(additive/blend/rate/visible + 키프레임 dict 언랩).
    func testParsesPuppetAnimationLayers() throws {
        let puppetModel = #"{"width":100,"height":100,"material":"materials/m.json","puppet":"models/p.mdl"}"#
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
           "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":true,
           "animationlayers":[
             {"name":"Idle","animation":10,"additive":false,"blend":1.0,"rate":12.0,"visible":true},
             {"name":"Wave","animation":20,"additive":true,"blend":{"value":0.5,"animation":{}},"rate":1.0,"visible":true}
           ]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", puppetModel), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.layers.count, 1)
        let al = doc.layers[0].animationLayers
        XCTAssertEqual(al.count, 2)
        XCTAssertEqual(al[0].name, "Idle"); XCTAssertFalse(al[0].additive)
        XCTAssertEqual(al[0].blend, 1.0, accuracy: 1e-6); XCTAssertEqual(al[0].rate, 12.0, accuracy: 1e-6)
        XCTAssertTrue(al[1].additive)
        XCTAssertEqual(al[1].blend, 0.5, accuracy: 1e-6, "키프레임 dict {value} 언랩")
        XCTAssertTrue(al[0].scripts.isEmpty); XCTAssertTrue(al[0].eventTimelines.isEmpty)
    }

    /// animationlayers blend/visible 바인딩의 스크립트 + 이벤트 타임라인 파스
    /// (실물 3737268876 젤다 blend 핸들러/surprise 마커, 3396722575 visible 핸들러 축소판).
    func testParsesAnimationLayerScriptsAndEventTimelines() throws {
        let puppetModel = #"{"width":100,"height":100,"material":"materials/m.json","puppet":"models/p.mdl"}"#
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
           "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":true,
           "animationlayers":[
             {"name":"Surprise","animation":30,"additive":true,"rate":1.0,"visible":true,
              "blend":{"value":0,
                       "script":"export function animationEvent(e,v){}",
                       "animation":{"c0":[{"frame":0,"value":0},{"frame":30,"value":1}],
                                    "options":{"fps":30,"length":30,"mode":"single","name":"surprise",
                                               "events":[{"frame":0,"name":"surprise"},
                                                         {"frame":21,"name":"regular"}]}}}},
             {"name":"Head","animation":510,"additive":false,"rate":1.0,
              "visible":{"value":true,"script":"export function animationEvent(e,v){}"}}
           ]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", puppetModel), ("materials/m.json", material)])
        let al = try SceneDocument.parse(package: p).layers[0].animationLayers
        XCTAssertEqual(al.count, 2)
        XCTAssertNotNil(al[0].scripts["blend"], "젤다 패턴: blend 스크립트")
        XCTAssertEqual(al[0].eventTimelines.count, 1)
        XCTAssertEqual(al[0].eventTimelines[0].events,
                       [AnimationMarker(name: "surprise", frame: 0), AnimationMarker(name: "regular", frame: 21)])
        XCTAssertEqual(al[0].eventTimelines[0].mode, "single")
        XCTAssertEqual(al[0].blend, 0, accuracy: 1e-6, "정적 blend 초기값({value:0} 언랩) 무회귀")
        XCTAssertNotNil(al[1].scripts["visible"], "3396722575 패턴: visible 스크립트")
        XCTAssertTrue(al[1].eventTimelines.isEmpty, "events 없는 바인딩 애니는 미보관")
    }

    /// 비-퍼펫 이미지 레이어는 animationLayers 빈 배열(파스 오버헤드/오분류 없음).
    func testNonPuppetLayerHasNoAnimationLayers() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
           "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":true}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        XCTAssertTrue(try SceneDocument.parse(package: p).layers[0].animationLayers.isEmpty)
    }

    /// 실측 스키마(3629379075 등): sound[], volume {user,value} 또는 숫자, playbackmode, startsilent, min/maxtime.
    func testParsesSceneSoundFields() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[
           {"id":927,"sound":["sounds/a.mp3"],"volume":{"user":"p","value":0.6},
            "playbackmode":"loop","startsilent":true,"mintime":1.0,"maxtime":5.0},
           {"id":5,"sound":["sounds/b.wav"],"volume":0.5,"playbackmode":"single","startsilent":false}
         ]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.sounds.count, 2)
        let a = doc.sounds[0]
        XCTAssertEqual(a.id, 927)
        XCTAssertEqual(a.sounds, ["sounds/a.mp3"])
        XCTAssertEqual(a.volume, 0.6, accuracy: 1e-5)   // {value} 바인딩 언랩
        XCTAssertTrue(a.loop)                            // playbackmode == loop
        XCTAssertTrue(a.startSilent)
        XCTAssertEqual(a.maxTime, 5.0, accuracy: 1e-5)
        XCTAssertEqual(doc.sounds[1].volume, 0.5, accuracy: 1e-5)  // 숫자 볼륨
        XCTAssertFalse(doc.sounds[1].loop)               // single
    }

    /// 콘텐츠 키 없는 sound 오브젝트가 nodes3D 그룹으로 오분류되지 않아야 한다(회귀 가드).
    func testSoundObjectNotMisclassifiedAsNode() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"sound":["sounds/a.mp3"],"volume":0.5,"playbackmode":"loop"}]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.sounds.count, 1)
        XCTAssertTrue(doc.nodes3D.isEmpty)
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

    func testPreservesInvisibleImageLayerReferencedByRuntimeComposite() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":42,"image":"models/face.json","origin":"50 50 0","size":"10 10","visible":false},
           {"id":77,"image":"models/unused.json","origin":"50 50 0","size":"10 10","visible":false}
         ]}
        """
        let faceModel = #"{"material":"materials/face.json"}"#
        let faceMaterial = #"{"passes":[{"textures":["face"]}]}"#
        let consumerMaterial = #"{"passes":[{"textures":["_rt_imageLayerComposite_42_a"]}]}"#
        let p = try pkg([
            ("scene.json", scene),
            ("models/face.json", faceModel),
            ("models/unused.json", model),
            ("materials/face.json", faceMaterial),
            ("materials/face.tex", "tex"),
            ("materials/m.json", material),
            ("materials/consumer.json", consumerMaterial)
        ])

        let doc = try SceneDocument.parse(package: p)

        XCTAssertEqual(doc.layers.map(\.id), [42])
        XCTAssertFalse(doc.layers[0].initialVisible)
        XCTAssertEqual(doc.layers[0].textureEntryName, "materials/face.tex")
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

    func testUserTextureOverrideReplacesMaterialTextureSlot() throws {
        let materialUserTexture = #"{"passes":[{"shader":"genericimage2","textures":["pic"],"usertextures":["customimage"]}]}"#
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", materialUserTexture)])
        let doc = try SceneDocument.parse(package: p, userProps: ["customimage": "/tmp/yeezus.jpg"])

        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.layers[0].textureEntryName, "/tmp/yeezus.jpg")
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

    /// _rt_ 텍스처(프레임버퍼 참조) → isFrameBuffer 레이어. fullscreen 모델은 size 지정과 무관하게
    /// 프로젝션 전체를 덮는다(origin 중앙).
    func testFrameBufferTextureLayerParsed() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/util/fullscreenlayer.json","origin":"10 20 0","size":"5 5",
                     "alpha":1,"visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene)])
        let assets: [String: String] = [
            "models/util/fullscreenlayer.json": #"{"material":"materials/util/fullscreenlayer.json","fullscreen":true,"passthrough":true}"#,
            "materials/util/fullscreenlayer.json": #"{"passes":[{"shader":"passthrough","textures":["_rt_FullFrameBuffer"]}]}"#,
        ]
        let doc = try SceneDocument.parse(package: p, assets: { assets[$0].map { Data($0.utf8) } })
        XCTAssertEqual(doc.layers.count, 1, "_rt_ 레이어는 컴포지션 레이어로 파스돼야")
        let l = doc.layers[0]
        XCTAssertTrue(l.isFrameBuffer)
        XCTAssertEqual(l.textureEntryName, "")
        XCTAssertEqual(l.size, Vec2(x: 1920, y: 1080), "fullscreen → 프로젝션 전체")
        XCTAssertEqual(l.origin, Vec2(x: 960, y: 540), "fullscreen → 중앙")
    }

    /// composelayer(fullscreen 플래그 없음, size 있는 그룹 레이어)도 isFrameBuffer 로 파스, 지오메트리는 오브젝트 값 유지.
    func testComposeLayerKeepsObjectGeometry() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/util/composelayer.json","origin":"400 300 0","size":"800 600",
                     "visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene)])
        let assets: [String: String] = [
            "models/util/composelayer.json": #"{"material":"materials/util/composelayer.json"}"#,
            "materials/util/composelayer.json": #"{"passes":[{"shader":"composelayer","textures":["_rt_FullFrameBuffer"]}]}"#,
        ]
        let doc = try SceneDocument.parse(package: p, assets: { assets[$0].map { Data($0.utf8) } })
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertTrue(doc.layers[0].isFrameBuffer)
        XCTAssertEqual(doc.layers[0].size, Vec2(x: 800, y: 600))
        XCTAssertEqual(doc.layers[0].origin, Vec2(x: 400, y: 300))
    }

    /// 효과 상수의 바인딩 객체 {script/value} — 정적 value 언랩 + 스크립트 캡처(실물 3395777145 컬러 사이클).
    func testEffectConstantBindingObjectUnwrapped() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","visible":{"value":true},
           "effects":[{"file":"effects/e.json","passes":[{"constantshadervalues":
             {"color":{"script":"export function update(v){return v;}","value":"1.00000 0.00000 0.00000"},
              "alpha":0.5}}]}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        let e = try XCTUnwrap(doc.layers.first?.effects.first)
        XCTAssertEqual(e.constants["color"], [1, 0, 0], "바인딩 value 언랩")
        XCTAssertEqual(e.constants["alpha"], [0.5])
        XCTAssertTrue(e.passList.first?.constantScripts["color"]?.contains("update") == true, "스크립트 캡처")
    }

    /// 퍼펫 모델: model json 의 "puppet" 키가 SceneLayer.puppet 으로 전달돼야(SP6).
    func testPuppetPathParsed() throws {
        let puppetModel = #"{"autosize":true,"material":"materials/m.json","puppet":"models/x_puppet.mdl"}"#
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"960 540 0","size":"100 100","visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", puppetModel), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.layers[0].puppet, "models/x_puppet.mdl")
    }

    /// 텍스트 오브젝트: 평문 text 와 {"script": ...} 둘 다 SceneTextLayer 로 파스(씬 순서 order 공유).
    func testParsesTextObjects() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"image":"models/x.json","origin":"960 540 0","size":"1920 1080","visible":{"value":true}},
           {"text":"HELLO","name":"plain","font":"systemfont_arial","pointsize":32.0,
            "color":"1 0 0","alpha":0.8,"horizontalalign":"center","verticalalign":"center",
            "origin":"100 200 0","size":"365 121","scale":"2 2 1","visible":{"value":true}},
           {"text":{"script":"export function update(v){return 'X';}"},"name":"scripted",
            "font":"fonts/f.otf","pointsize":16.0,"origin":"5 6 0","visible":{"value":true}},
           {"text":"nope","visible":false}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.texts.count, 2, "visible=false 텍스트는 제외")
        let t0 = doc.texts[0]
        XCTAssertEqual(t0.text, "HELLO")
        XCTAssertNil(t0.script)
        XCTAssertEqual(t0.font, "systemfont_arial")
        XCTAssertEqual(t0.pointSize, 32)
        XCTAssertEqual(t0.color, Vec3(x: 1, y: 0, z: 0))
        XCTAssertEqual(t0.alpha, 0.8)
        XCTAssertEqual(t0.origin, Vec2(x: 100, y: 200))
        // 실물(2902406982 弹幕): size 는 레이아웃 박스(365×121px), 배율은 별도 scale 필드 —
        // size 를 배율로 오독하면 365배 거대 글리프(화면 백화 회귀의 원인).
        XCTAssertEqual(t0.scale, Vec2(x: 2, y: 2))
        XCTAssertEqual(t0.horizontalAlign, "center")
        XCTAssertEqual(t0.order, 1, "objects[] 인덱스(레이어와 공유 z-순서)")
        let t1 = doc.texts[1]
        XCTAssertEqual(t1.text, "")
        XCTAssertEqual(t1.script, "export function update(v){return 'X';}")
        XCTAssertEqual(t1.order, 2)
    }

    /// 애니메이션 바인딩 → SceneLayer.animations 캡처(base 는 기존 value 언랩 유지).
    func testCapturesPropertyAnimations() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json",
            "origin":{"animation":{"c0":[{"frame":0,"value":0},{"frame":60,"value":100}],
                                    "options":{"fps":30,"length":60,"mode":"loop"},"relative":true},
                      "value":"960 540 0"},
            "alpha":{"animation":{"c0":[{"frame":0,"value":1},{"frame":30,"value":0}],
                                   "options":{"fps":30,"length":30,"mode":"single"}},"value":1.0},
            "size":"10 10","visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.layers.count, 1)
        let l = doc.layers[0]
        XCTAssertEqual(l.origin, Vec2(x: 960, y: 540), "base 는 정적 value")
        XCTAssertNotNil(l.animations["origin"])
        XCTAssertEqual(l.animations["origin"]?.mode, "loop")
        XCTAssertEqual(l.animations["origin"]?.relative, true)
        XCTAssertNotNil(l.animations["alpha"])
        XCTAssertNil(l.animations["scale"])
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

    func testHugeNumericSceneValuesDefaultInsteadOfTrapping() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"text":"SAFE","pointsize":1e300,"origin":"0 0 0","visible":{"value":true}},
           {"image":"models/x.json","id":1e300,"colorBlendMode":1e300,
            "origin":"50 50 0","size":"10 10","visible":{"value":true},
            "effects":[{"file":"effects/tint/effect.json",
              "passes":[{"combos":{"AUDIOPROCESSING":1e300},
                         "constantshadervalues":{"bad":1e300}}]}]}
         ]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.texts.first?.pointSize, 16)
        let layer = try XCTUnwrap(doc.layers.first)
        XCTAssertEqual(layer.id, 0)
        XCTAssertEqual(layer.colorBlendMode, 0)
        let effect = try XCTUnwrap(layer.effects.first)
        XCTAssertEqual(effect.audioMode, 0)
        XCTAssertNil(effect.constants["bad"])
    }

    /// cameraparallax 가 {"user","value"} 바인딩 dict 인 씬(실물 21씬) — value 언랩해 활성화.
    func testCameraParallaxUserBindingDict() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},
          "cameraparallax":{"user":"k","value":true},"cameraparallaxamount":0.5},
         "objects":[]}
        """
        let p = try pkg([("scene.json", scene)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertTrue(doc.parallaxEnabled, "{user,value:true} dict 는 true 로 언랩")
        XCTAssertEqual(doc.parallaxAmount, 0.5, accuracy: 1e-6)
    }

    /// text 가 {"user","value"(,"script")} 바인딩 dict(실물 29씬/136오브젝트) — value 를 초기 표시값으로.
    func testTextUserValueBinding() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[
           {"text":{"user":"t","value":"Hello"},"origin":"0 0 0","visible":true},
           {"text":{"user":"u","value":"World","script":"return v;"},"origin":"0 0 0","visible":true}
         ]}
        """
        let p = try pkg([("scene.json", scene)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.texts.count, 2)
        XCTAssertEqual(doc.texts[0].text, "Hello")
        XCTAssertNil(doc.texts[0].script)
        XCTAssertEqual(doc.texts[1].text, "World", "script 와 value 동시 보유 시 둘 다 채움")
        XCTAssertEqual(doc.texts[1].script, "return v;")
    }

    /// 콘텐츠 키가 JSON null(NSNull) 인 오브젝트(실물 21오브젝트) — 트랜스폼-온리 노드로 계층 보존.
    func testNSNullContentKeyPreservesNode() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":7,"image":null,"origin":"5 6 0","angles":"0 0 0","scale":"1 1 1","visible":true}]}
        """
        let p = try pkg([("scene.json", scene)])
        let doc = try SceneDocument.parse(package: p)
        let node = try XCTUnwrap(doc.nodes3D.first(where: { $0.id == 7 }), "image:null 은 그룹 노드로 분류")
        XCTAssertEqual(node.origin, Vec3(x: 5, y: 6, z: 0))
        XCTAssertTrue(node.visible)
        XCTAssertTrue(doc.layers.isEmpty)
    }

    /// V06: 정적 visible:false 콘텐츠 부모(id 보유)의 트랜스폼이 비가시 노드로 남아
    /// 가시 자식의 parent 체인 합성이 끊기지 않는다(월드 좌표 반영).
    func testInvisibleContentParentChainPreserved() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[
           {"id":10,"image":"models/x.json","origin":"100 200 0","size":"10 10","scale":"2 2 1",
            "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":false},
           {"id":11,"parent":10,"image":"models/x.json","origin":"10 0 0","size":"10 10","scale":"1 1 1",
            "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":true}
         ]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.layers.count, 1, "비가시 부모는 렌더 레이어 미포함(무회귀)")
        let node = try XCTUnwrap(doc.nodes3D.first(where: { $0.id == 10 }), "비가시 부모 트랜스폼 노드 보존")
        XCTAssertFalse(node.visible)
        let child = doc.layers[0]
        XCTAssertEqual(child.origin, Vec2(x: 120, y: 200), "부모 origin(100,200)+scale(2)×로컬(10,0)")
        XCTAssertEqual(child.scale, Vec2(x: 2, y: 2))
    }

    /// H2 규명(2026-07-13, 무회귀 봉인). ortho=dict + camera{eye,center,up} + fov 는 WE 규약상
    /// 여전히 2D(직교) 씬이다 — 공식 ICamera 문서: fov="For 3D scenes only", 2D 카메라는 zoom 만
    /// (`lib.sceneScript.d.ts:1953-1962`). 코퍼스 170씬 실측: empty 24씬 전부 ortho=dict(2D 경로,
    /// camera3D=nil)이고 21/24는 카메라가 trivial — 즉 카메라는 emptiness 원인이 아니다.
    /// parseCamera 가 이 조합을 3D 카메라로 승격하면 (1) camera3D!=nil → forwardLit2D 게이트 소실 +
    /// 2D 레이어 미렌더, (2) 팬/원근으로 오브젝트가 화면 밖 이동(코퍼스 2955378002 콘텐츠가시 43%→15%)
    /// → 카메라 보유 ~160씬 대량 회귀. 이 테스트가 그 회귀를 봉인한다(제안된 오수정 시 RED).
    func testOrthoDictSceneWithCameraAndFovStays2D() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},
                    "fov":{"script":"cam","value":50.0},"nearz":0.01,"farz":10000.0,
                    "ambientcolor":"0.3 0.3 0.3"},
         "camera":{"eye":"293.217 -286.201 0.0","center":"293.217 -286.201 -1.0","up":"0.0 1.0 0.0"},
         "objects":[
           {"image":"models/x.json","origin":"960 540 0","size":"1920 1080","scale":"1 1 1",
            "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":true},
           {"light":"point","origin":"960 540 0","color":"1 1 1"}
         ]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertNil(doc.camera3D,
            "ortho=dict 는 2D 경로 — camera+fov 가 있어도 3D 카메라 승격 금지(WE: fov=3D 전용). 승격 시 RED")
        XCTAssertEqual(doc.layers.count, 1, "2D 이미지 레이어 그대로 렌더(3D 승격 시 소실)")
        XCTAssertFalse(doc.lights3D.isEmpty, "라이트 파스")
        XCTAssertTrue(doc.forwardLit2D, "2D 포워드 라이팅 게이트(camera3D==nil) 유지 — 3D 승격 시 소실")
    }
}
