import XCTest
@testable import WapleCore

final class SceneDocumentTests: XCTestCase {
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
          "bloomhdrstrength":1.4,"bloomhdrthreshold":0.70,
          "bloomhdrfeather":0.25,"bloomhdriterations":6,"bloomhdrscatter":2.0},"objects":[]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertTrue(doc.hdr)
        XCTAssertTrue(doc.bloom)
        XCTAssertEqual(doc.bloomStrength, 3.37, accuracy: 1e-4)
        XCTAssertEqual(doc.bloomThreshold, 0.36, accuracy: 1e-4)
        XCTAssertEqual(doc.bloomTint, Vec3(x: 1, y: 1, z: 1))
        XCTAssertEqual(doc.bloomHDRStrength, 1.4, accuracy: 1e-4)
        XCTAssertEqual(doc.bloomHDRThreshold, 0.70, accuracy: 1e-4)
        XCTAssertEqual(doc.bloomHDRFeather, 0.25, accuracy: 1e-4)
        XCTAssertEqual(doc.bloomHDRIterations, 6)
        XCTAssertEqual(doc.bloomHDRScatter, 2.0, accuracy: 1e-4)
    }

    /// hdr/bloom 및 블룸 파라미터의 **키 부재 기본값** — 전부 WE 씬 생성자(`0x140186c90`–`0x1401872ba`)
    /// 실측치다. `hdr` 은 flags bit10 이라 생성자 `0x26` 에서 clear = false(`0x140186d1f`).
    /// `bloom`(bit1)만 WE 가 true 인데 여기서는 의도적 이탈로 false 다 —
    /// 근거와 되돌리는 법은 `SceneDocument.bloom` 선언부 주석 / §7 W-4.
    func testHDRBloomDefaultsWhenAbsent() throws {
        let scene = #"{"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[]}"#
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertFalse(doc.hdr)
        XCTAssertFalse(doc.bloom, "WE 는 true — 렌더 픽스처 동반 수정이 가능한 레인에서 뒤집을 것")
        XCTAssertEqual(doc.bloomStrength, 2, accuracy: 1e-6)
        XCTAssertEqual(doc.bloomThreshold, 0.65, accuracy: 1e-6)
        XCTAssertEqual(doc.bloomTint, Vec3(x: 1, y: 1, z: 1))
        // strength 2.0 = `0x1401870c2`(`scene+0x3c4` ← `0x40000000`) — LDR 짝 `bloomstrength` 와 같은 값.
        XCTAssertEqual(doc.bloomHDRStrength, 2, accuracy: 1e-6)
        // HDR 기본값 = WE 클린룸 확정치(A3 §0: threshold 1.0 · feather 0.1 · scatter 1.619 · iterations 8).
        XCTAssertEqual(doc.bloomHDRThreshold, 1, accuracy: 1e-6)
        XCTAssertEqual(doc.bloomHDRFeather, 0.1, accuracy: 1e-6)
        XCTAssertEqual(doc.bloomHDRIterations, 8)
        XCTAssertEqual(doc.bloomHDRScatter, 1.619, accuracy: 1e-6)
    }

    /// 명시 저작 `bloom` 은 평문/바인딩 양쪽 다 그대로 읽힌다 — 동봉 172씬이 전건 이 경로를 탄다.
    /// (기본값을 WE 쪽 true 로 뒤집더라도 이 축은 그대로여야 한다.)
    func testExplicitBloomFlagIsParsedBothWays() throws {
        func bloom(_ literal: String) throws -> Bool {
            let scene = #"{"general":{"orthogonalprojection":{"width":100,"height":100},"bloom":\#(literal)},"objects":[]}"#
            return try SceneDocument.parse(package: try pkg([("scene.json", scene)])).bloom
        }
        XCTAssertFalse(try bloom("false"))
        XCTAssertTrue(try bloom("true"))
        XCTAssertFalse(try bloom(#"{"value":false}"#))
        XCTAssertTrue(try bloom(#"{"user":"u","value":true}"#))
    }

    /// D 재감사 #16: general.camerashake 전역 지터 파스(bool enable + amplitude/roughness/speed 형제 키).
    /// 실측 활성 13/168씬 — 실코퍼스 값(2800248288: amp 0.35 rough 0.0 speed 1.0)으로 파스 확증.
    func testParsesCameraShakeFields() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},
          "camerashake":true,"camerashakeamplitude":0.34999999,"camerashakeroughness":0.0,"camerashakespeed":1.0},"objects":[]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertTrue(doc.cameraShake)
        XCTAssertEqual(doc.cameraShakeAmplitude, 0.35, accuracy: 1e-4)
        XCTAssertEqual(doc.cameraShakeRoughness, 0.0, accuracy: 1e-4)
        XCTAssertEqual(doc.cameraShakeSpeed, 1.0, accuracy: 1e-4)
    }

    /// camerashake 부재 → false + 코퍼스 편집기 기본값(0.5/1/3). 비활성 = 무영향(비트동일 가드 입력).
    func testCameraShakeDefaultsWhenAbsent() throws {
        let scene = #"{"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[]}"#
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertFalse(doc.cameraShake)
        XCTAssertEqual(doc.cameraShakeAmplitude, 0.5, accuracy: 1e-6)
        XCTAssertEqual(doc.cameraShakeRoughness, 1, accuracy: 1e-6)
        XCTAssertEqual(doc.cameraShakeSpeed, 3, accuracy: 1e-6)
    }

    /// 실코퍼스 바인딩 형태: camerashake 는 {"user"/"value"} 로 저작될 수 있음(클린룸 15씬) — unwrap 공통.
    func testCameraShakeAcceptsValueWrappedAndStringForms() throws {
        let scene = #"{"general":{"orthogonalprojection":{"width":16,"height":16},"camerashake":{"value":true},"camerashakeamplitude":"0.15000001","camerashakespeed":{"value":7.0}},"objects":[]}"#
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertTrue(doc.cameraShake)
        XCTAssertEqual(doc.cameraShakeAmplitude, 0.15, accuracy: 1e-4)
        XCTAssertEqual(doc.cameraShakeSpeed, 7.0, accuracy: 1e-4)
    }

    func testBloomParserAcceptsNumericStringAndValueFormsWithoutClamping() throws {
        func parse(_ fields: String) throws -> SceneDocument {
            let scene = """
            {"general":{"orthogonalprojection":{"width":16,"height":16},\(fields)},"objects":[]}
            """
            return try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        }

        let numeric = try parse(
            #""bloom":true,"bloomstrength":20,"bloomthreshold":-0.5,"bloomtint":"0.2 0.4 0.8","bloomhdrstrength":1.4,"bloomhdrthreshold":0.7"#)
        XCTAssertEqual(numeric.bloomStrength, 20, accuracy: 1e-6)
        XCTAssertEqual(numeric.bloomThreshold, -0.5, accuracy: 1e-6)
        XCTAssertEqual(numeric.bloomTint, Vec3(x: 0.2, y: 0.4, z: 0.8))
        XCTAssertEqual(numeric.bloomHDRStrength, 1.4, accuracy: 1e-6)
        XCTAssertEqual(numeric.bloomHDRThreshold, 0.7, accuracy: 1e-6)

        let strings = try parse(
            #""bloomstrength":"6.25","bloomthreshold":"1.25","bloomtint":"0.9 0.7 0.5""#)
        XCTAssertEqual(strings.bloomStrength, 6.25, accuracy: 1e-6)
        XCTAssertEqual(strings.bloomThreshold, 1.25, accuracy: 1e-6)
        XCTAssertEqual(strings.bloomTint, Vec3(x: 0.9, y: 0.7, z: 0.5))

        let values = try parse(
            #""bloomstrength":{"value":"4.5"},"bloomthreshold":{"value":0.2},"bloomtint":{"value":"1 0.5 0.25"}"#)
        XCTAssertEqual(values.bloomStrength, 4.5, accuracy: 1e-6)
        XCTAssertEqual(values.bloomThreshold, 0.2, accuracy: 1e-6)
        XCTAssertEqual(values.bloomTint, Vec3(x: 1, y: 0.5, z: 0.25))

        // 실코퍼스 형태(3470948192/3589454154): bloomhdr* 가 {"user":...,"value":...} 바인딩으로 저작된다.
        let userBound = try parse(
            #""bloomhdrstrength":{"user":"hdr","value":0.30000001},"bloomhdriterations":{"user":"hdr2","value":6},"bloomhdrscatter":{"user":"hdr1","value":2.0},"bloomhdrfeather":"0.4""#)
        XCTAssertEqual(userBound.bloomHDRStrength, 0.3, accuracy: 1e-4)
        XCTAssertEqual(userBound.bloomHDRIterations, 6)
        XCTAssertEqual(userBound.bloomHDRScatter, 2.0, accuracy: 1e-6)
        XCTAssertEqual(userBound.bloomHDRFeather, 0.4, accuracy: 1e-6)
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

    /// animationlayers rate 바인딩 스크립트 캡처(실물 2955378002/3448290956 오디오 배속 축소판).
    /// base 결함: 파서 키 루프가 ["blend","visible"] 만 훑어 rate 스크립트를 조용히 폐기.
    /// 정적 초기값({value} 언랩)은 종전대로 보존돼야 한다(무회귀).
    func testCapturesAnimationLayerRateScript() throws {
        let puppetModel = #"{"width":100,"height":100,"material":"materials/m.json","puppet":"models/p.mdl"}"#
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
           "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":true,
           "animationlayers":[
             {"name":"Animation 2","additive":false,"blend":1.0,"visible":true,
              "rate":{"value":1.1,"script":"export function update(v){return 0;}"}}
           ]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", puppetModel), ("materials/m.json", material)])
        let al = try SceneDocument.parse(package: p).layers[0].animationLayers
        XCTAssertEqual(al.count, 1)
        XCTAssertNotNil(al[0].scripts["rate"], "rate 바인딩 스크립트가 캡처돼야(base: 파스에서 폐기)")
        XCTAssertEqual(al[0].rate, 1.1, accuracy: 1e-6, "정적 rate 초기값({value} 언랩) 무회귀")
        XCTAssertTrue(al[0].eventTimelines.isEmpty, "events 없는 rate 바인딩은 타임라인 미보관")
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

    /// P1 solid_instance: 레이어 obj 의 instance.textures 가 base material 슬롯(전건 util/white)을
    /// 치환해야 한다(실측 53씬/324오브젝트 — 미병합 시 흰 솔리드/공백). instance 부재 시 base 유지는
    /// 위 testInstanceMaterialFromAssetsResolvesTexture 가 커버(무회귀).
    func testInstanceBlockTexturesReplaceBaseMaterialSlot() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/solid_instance_model_x.json","origin":"960 540 0","size":"256 256",
                     "visible":{"value":true},
                     "instance":{"combos":{"version":2},"id":7,"textures":["photo1"]}}]}
        """
        let p = try pkg([
            ("scene.json", scene),
            ("models/solid_instance_model_x.json", #"{"instanced":true,"material":"materials/util/solidlayer_instance.json","solidlayer":true}"#),
            ("materials/photo1.tex", "tex"),
        ])
        let assets: [String: String] = [
            "materials/util/solidlayer_instance.json": #"{"passes":[{"shader":"genericimage2","textures":["util/white"]}]}"#,
        ]
        let doc = try SceneDocument.parse(package: p, assets: { assets[$0].map { Data($0.utf8) } })
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.layers[0].textureEntryName, "materials/photo1.tex")
    }

    /// instance.usertextures 는 {name,type} 딕셔너리(실측 usershortcut 164/system 22)와 평문 문자열
    /// (실측 14) 두 형태 — name 이 userProps 키. 값 설정 시 instance.textures 보다 우선, 미설정 슬롯은
    /// instance.textures 유지.
    func testInstanceUserTexturesOverrideInstanceTextures() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"image":"models/solid_instance_model_x.json","origin":"1 1 0","size":"8 8","visible":{"value":true},
            "instance":{"textures":["photo1"],"usertextures":[{"name":"launcher1","type":"usershortcut"}]}},
           {"image":"models/solid_instance_model_x.json","origin":"2 2 0","size":"8 8","visible":{"value":true},
            "instance":{"textures":["photo1"],"usertextures":["plainkey"]}},
           {"image":"models/solid_instance_model_x.json","origin":"3 3 0","size":"8 8","visible":{"value":true},
            "instance":{"textures":["photo1"],"usertextures":[{"name":"unsetkey","type":"usershortcut"}]}}]}
        """
        let p = try pkg([
            ("scene.json", scene),
            ("models/solid_instance_model_x.json", #"{"instanced":true,"material":"materials/util/solidlayer_instance.json","solidlayer":true}"#),
            ("materials/photo1.tex", "tex"),
        ])
        let assets: [String: String] = [
            "materials/util/solidlayer_instance.json": #"{"passes":[{"shader":"genericimage2","textures":["util/white"]}]}"#,
        ]
        let doc = try SceneDocument.parse(package: p, assets: { assets[$0].map { Data($0.utf8) } },
                                          userProps: ["launcher1": "/tmp/icon1.png", "plainkey": "/tmp/icon2.png"])
        XCTAssertEqual(doc.layers.count, 3)
        XCTAssertEqual(doc.layers[0].textureEntryName, "/tmp/icon1.png", "딕셔너리형 usertexture 오버라이드")
        XCTAssertEqual(doc.layers[1].textureEntryName, "/tmp/icon2.png", "문자열형 usertexture 오버라이드")
        XCTAssertEqual(doc.layers[2].textureEntryName, "materials/photo1.tex", "미설정 키 → instance.textures 유지")
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

    /// 스칼라 효과 상수 {value:<수>, script} — 상류 float 언랩 short-circuit 결함 수정: 스크립트가
    /// 캡처되고 초기값(정적 value)이 정확해야(실물 audioamount/alpha/multiply 63씬 패턴).
    func testScalarConstantScriptCaptured() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10",
           "effects":[{"file":"effects/e.json","passes":[{"constantshadervalues":
             {"alpha":{"script":"export function update(v){return v*0.5;}","value":0.8}}}]}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let e = try XCTUnwrap(try SceneDocument.parse(package: p).layers.first?.effects.first)
        XCTAssertEqual(e.constants["alpha"], [0.8], "스칼라 초기값 정확(언랩)")
        XCTAssertTrue(e.passList.first?.constantScripts["alpha"]?.contains("update") == true,
                      "스칼라 스크립트 캡처(종전 float 언랩에 삼켜지던 결함)")
    }

    /// 무회귀: 정적 스칼라 {value} 만(스크립트 없음) → 종전대로 언랩, 스크립트 미기록.
    func testScalarStaticConstantNoScriptNoRegression() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10",
           "effects":[{"file":"effects/e.json","passes":[{"constantshadervalues":
             {"alpha":{"value":0.75},"plain":0.25}}]}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let pass = try XCTUnwrap(try SceneDocument.parse(package: p).layers.first?.effects.first?.passList.first)
        XCTAssertEqual(pass.constants["alpha"], [0.75], "정적 {value} 언랩")
        XCTAssertEqual(pass.constants["plain"], [0.25], "평문 스칼라")
        XCTAssertNil(pass.constantScripts["alpha"], "스크립트 없는 정적 상수는 미기록")
        XCTAssertNil(pass.constantScripts["plain"], "평문 스칼라도 미기록")
    }

    /// scriptproperties 오버라이드가 스칼라 상수에도 주입돼야(종전 스칼라는 스크립트째 삼켜져 같이 죽었음).
    func testScalarConstantScriptPropertiesInjected() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10",
           "effects":[{"file":"effects/e.json","passes":[{"constantshadervalues":
             {"multiply":{"script":"export function update(v){return v;}","value":1,
                          "scriptproperties":{"gain":0.4}}}}]}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let pass = try XCTUnwrap(try SceneDocument.parse(package: p).layers.first?.effects.first?.passList.first)
        let json = try XCTUnwrap(pass.constantScriptProps["multiply"], "스칼라 scriptproperties 보존")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((obj["gain"] as? NSNumber)?.doubleValue ?? 0, 0.4, accuracy: 1e-6)
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
        // [2026-08-21] 씬 생성자 실측 기본값 — amount `scene+0x334`=0.5(`0x140186fa5`),
        // mouseinfluence `scene+0x33c`=0.5(`0x140186fbb`), delay `scene+0x338`=0.1(`0x140186fb0`).
        // 종전 1/1/0 은 이동량·마우스 추종 2배 + 즉시 스냅이었다.
        XCTAssertEqual(doc.parallaxAmount, 0.5, accuracy: 1e-6)
        XCTAssertEqual(doc.parallaxMouseInfluence, 0.5, accuracy: 1e-6)
        XCTAssertEqual(doc.parallaxDelay, 0.1, accuracy: 1e-6)
        // 레이어별 시차 깊이는 별 키(`SceneLayer.parallaxDepth`)라 기본 (1,1) 그대로다.
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

    /// 위 테스트가 덮지 못한 **정수·문자열** 경로.
    ///
    /// `1e300` 은 Double 이라 `lenientInt` → `safeInt` 에서 이미 걸렸다. 그런데 JSON 이
    /// `2147483648`(Int) 이나 `"99999999999"`(문자열)로 주면 `lenientInt` 는 그대로 통과시키고,
    /// 소비처인 `SceneRendererFrameEncoder:1450/:1629` 의 `Int32(...)` 좁힘에서 **트랩**했다.
    /// 유효 범위는 `common_blending.h` ApplyBlending enum 의 0…32 뿐이다.
    func testColorBlendModeOutOfRangeFallsBackToNormal() throws {
        func mode(_ raw: String) throws -> Int {
            let scene = """
            {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
             "objects":[{"image":"models/x.json","id":1,"colorBlendMode":\(raw),
                         "origin":"50 50 0","size":"10 10","visible":{"value":true}},
                        {"text":"T","colorBlendMode":\(raw),"origin":"0 0 0","visible":{"value":true}}]}
            """
            let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
            let doc = try SceneDocument.parse(package: p)
            let l = try XCTUnwrap(doc.layers.first).colorBlendMode
            let t = try XCTUnwrap(doc.texts.first).colorBlendMode
            XCTAssertEqual(l, t, "이미지·텍스트 두 소비처가 같은 파스 규약을 써야 한다(raw \(raw))")
            return l
        }
        // Int32 를 넘는 정수 — 종전 트랩 지점.
        XCTAssertEqual(try mode("2147483648"), 0)
        XCTAssertEqual(try mode("-2147483649"), 0)
        XCTAssertEqual(try mode("9223372036854775807"), 0)
        // 문자열 숫자(실물 씬이 숫자를 문자열로 싣는 사례 — intVal 주석 참조).
        XCTAssertEqual(try mode("\"99999999999\""), 0)
        // Int32 안이지만 enum 밖 — 셰이더 switch default 로 새는 대신 파스에서 정규화한다.
        XCTAssertEqual(try mode("33"), 0)
        XCTAssertEqual(try mode("-1"), 0)
        // 유효 범위는 그대로 보존돼야 한다(정규화가 정상 값을 먹으면 안 된다).
        XCTAssertEqual(try mode("0"), 0)
        XCTAssertEqual(try mode("2"), 2)
        XCTAssertEqual(try mode("32"), 32)
        XCTAssertEqual(try mode("\"18\""), 18, "문자열이어도 유효 범위면 통과")
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

    // MARK: - C①: {user,value} 바인딩이 project.json 기본값(미변경 키)으로 해석돼야 하는지 종단 검증
    // (UserPropertyStoreTests 는 raw 딕셔너리 계층만 확인 — 여기는 그 결과가 실제로 SceneDocument.parse
    // 를 거쳐 파싱값에 반영되는지, 타입별(색상 문자열/불리언) 형태 불일치 없이 흐르는지를 확인한다.)

    /// 색상 바인딩: baked "1 1 1"(흰색) 이지만 project.json 기본값(userProps 로 공급)이 다른 색이면
    /// 그 값이 반영돼야 한다 — 발산 최다빈도 필드(color 76건/코퍼스, id=11 finding).
    func testUserBindingResolvesToProjectDefaultColor() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"text":"hi","color":{"user":"tintcolor","value":"1 1 1"},
           "origin":"0 0 0","visible":true}]}
        """
        let p = try pkg([("scene.json", scene)])
        // userProps 는 UserPropertyStore.rawOverrides 가 project.json 기본값을 시딩한 형태를 모사
        // (project.json "color" 타입은 WallpaperProperties.parseValue 에서 .string 그대로 보존 — 그
        // rawDictionary 변환도 String 을 그대로 옮긴다).
        let doc = try SceneDocument.parse(package: p, userProps: ["tintcolor": "0.8 0.4 0.05"])
        XCTAssertEqual(doc.texts.count, 1)
        XCTAssertEqual(doc.texts[0].color.x, 0.8, accuracy: 1e-6, "baked 흰색이 아니라 project 기본값을 반영해야")
        XCTAssertEqual(doc.texts[0].color.y, 0.4, accuracy: 1e-6)
        XCTAssertEqual(doc.texts[0].color.z, 0.05, accuracy: 1e-6)
    }

    /// 불리언 바인딩(visible): baked true 지만 project.json 기본값이 false 면 오브젝트가 드롭돼야
    /// (truthiness 반전 6건 실측 — id=11 finding). WallpaperProperties.parseValue 의 bool 타입은
    /// 네이티브 Swift Bool 을 만들어 rawDictionary 를 거쳐도 Bool 그대로 남는다(NSNumber 둔갑 없음).
    func testUserBindingResolvesToProjectDefaultVisibility() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"text":"hidden by default","visible":{"user":"showtext","value":true},
           "origin":"0 0 0"}]}
        """
        let p = try pkg([("scene.json", scene)])
        let doc = try SceneDocument.parse(package: p, userProps: ["showtext": false])
        XCTAssertTrue(doc.texts.isEmpty, "baked true 가 아니라 project 기본값 false 를 반영해 드롭돼야")
    }

    /// 무회귀: userProps 에 해당 키가 전혀 없으면(프로젝트에 그 프로퍼티 자체가 없는 씬) 종전대로
    /// baked value 를 유지한다 — resolveUserBindings 의 "미스=미해석" 폴백은 이 항목이 건드리지 않았다.
    func testUserBindingKeepsBakedValueWhenKeyAbsentFromUserProps() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"text":"hi","color":{"user":"tintcolor","value":"1 1 1"},
           "origin":"0 0 0","visible":true}]}
        """
        let p = try pkg([("scene.json", scene)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        XCTAssertEqual(doc.texts.count, 1)
        XCTAssertEqual(doc.texts[0].color, Vec3(x: 1, y: 1, z: 1), "userProps 미공급 시 baked 값 유지(무회귀)")
    }

    /// P2: 텍스트 limit 필드(WE 에디터 라벨 실측: Limit width/Max width/Limit rows/Max rows/
    /// Overflow ellipsis/Justify text=blockalign) — 체크 시에만 유효값, 미체크/부재는 nil=무제한(무회귀).
    func testParsesTextLimitFields() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[
           {"text":"L","limitwidth":true,"maxwidth":390.0,"limitrows":true,"maxrows":2,
            "limituseellipsis":true,"blockalign":true,"origin":"0 0 0","visible":true},
           {"text":"U","limitwidth":false,"maxwidth":500.0,"limitrows":false,"maxrows":1,
            "limituseellipsis":false,"blockalign":false,"origin":"0 0 0","visible":true},
           {"text":"D","origin":"0 0 0","visible":true},
           {"text":"B","limitwidth":true,"maxwidth":{"user":"p","value":260.0},"limitrows":true,
            "origin":"0 0 0","visible":true}]}
        """
        let p = try pkg([("scene.json", scene)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.texts.count, 4)
        let l = doc.texts[0]
        XCTAssertEqual(l.maxWidth, 390)
        XCTAssertEqual(l.maxRows, 2)
        XCTAssertTrue(l.overflowEllipsis)
        XCTAssertTrue(l.justify)
        let u = doc.texts[1]
        XCTAssertNil(u.maxWidth, "limitwidth=false 면 maxwidth 무시")
        XCTAssertNil(u.maxRows, "limitrows=false 면 maxrows 무시")
        XCTAssertFalse(u.overflowEllipsis)
        XCTAssertFalse(u.justify)
        let d = doc.texts[2]
        XCTAssertNil(d.maxWidth, "부재 시 무제한(무회귀)")
        XCTAssertNil(d.maxRows)
        XCTAssertFalse(d.overflowEllipsis)
        XCTAssertFalse(d.justify)
        let b = doc.texts[3]
        XCTAssertEqual(b.maxWidth, 260, "바인딩 dict maxwidth 는 {value} 언랩(실물 32건)")
        XCTAssertEqual(b.maxRows, 1, "maxrows 부재 시 실측 기본 1")
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

    func testSelfContainedRequiredLayerDoesNotReportSharedMiss() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"image":"models/x.json","visible":true}]}
        """
        let package = try pkg([
            ("scene.json", scene),
            ("models/x.json", model),
            ("materials/m.json", material),
        ])
        var misses = 0

        let document = try SceneDocument.parse(
            package: package,
            assets: { _ in nil },
            onMissingRequiredAsset: { misses += 1 }
        )

        XCTAssertEqual(document.layers.count, 1)
        XCTAssertEqual(misses, 0)
    }

    func testRequiredLayerResolvedBySharedAssetsDoesNotReportMiss() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"image":"models/util/solidlayer.json","visible":true}]}
        """
        let package = try pkg([("scene.json", scene)])
        let shared: [String: String] = [
            "models/util/solidlayer.json": #"{"material":"materials/util/solidlayer.json"}"#,
            "materials/util/solidlayer.json": #"{"passes":[{"shader":"flat"}]}"#,
        ]
        var misses = 0

        let document = try SceneDocument.parse(
            package: package,
            assets: { shared[$0].map { Data($0.utf8) } },
            onMissingRequiredAsset: { misses += 1 }
        )

        XCTAssertEqual(document.layers.count, 1)
        XCTAssertEqual(misses, 0)
    }

    func testSharedRawTextureCandidateIsSelectedWithoutMissingDiagnostic() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"image":"models/x.json","visible":true}]}
        """
        let package = try pkg([
            ("scene.json", scene),
            ("models/x.json", #"{"material":"materials/m.json"}"#),
            ("materials/m.json", #"{"passes":[{"textures":["raw-name"]}]}"#),
        ])
        let shared = ["raw-name": Data("raw".utf8)]
        var misses = 0

        let document = try SceneDocument.parse(
            package: package,
            assets: { shared[$0] },
            onMissingRequiredAsset: { misses += 1 }
        )

        XCTAssertEqual(document.layers.map(\.textureEntryName), ["raw-name"])
        XCTAssertEqual(misses, 0)
    }

    func testMissingRequiredLayerReportsButInvalidPathDoesNot() throws {
        let missingScene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"image":"models/missing.json","visible":true}]}
        """
        var misses = 0
        let missingDocument = try SceneDocument.parse(
            package: try pkg([("scene.json", missingScene)]),
            assets: { _ in nil },
            onMissingRequiredAsset: { misses += 1 }
        )
        XCTAssertTrue(missingDocument.layers.isEmpty)
        XCTAssertEqual(misses, 1)

        let rejectedScene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"image":"../outside.json","visible":true}]}
        """
        var rejectedMisses = 0
        let rejectedDocument = try SceneDocument.parse(
            package: try pkg([("scene.json", rejectedScene)]),
            assets: { _ in
                XCTFail("invalid relative paths must not reach the shared resolver")
                return nil
            },
            onMissingRequiredAsset: { rejectedMisses += 1 }
        )
        XCTAssertTrue(rejectedDocument.layers.isEmpty)
        XCTAssertEqual(rejectedMisses, 0)
    }

    // MARK: parseNode 콘텐츠키 디스패치 누수 (shape:"quad" 이펙트 캐리어 · camera 의사-오브젝트)

    /// shape:"quad" + effects 오브젝트(실측 23씬/41오브젝트 — 전건 lightshafts 갓레이)는 콘텐츠 키가
    /// 없어 종전 parseNode 가 트랜스폼-노드로 흡수(통째 미표시). 솔리드 이펙트 레이어로 승격.
    /// isFrameBuffer 면 렌더러가 효과 체인을 스킵하므로 솔리드 캔버스(FB 아님)여야 한다.
    /// **2026-08-17 갱신**: 종전 이 테스트는 "풀스크린 승격"(origin=프로젝션 중심, size=프로젝션,
    /// scale=1, parent=nil, visibilityParent=저작 parent)을 고정했다. 그건 WE 의 shape 기본 크기를
    /// 모르던 시절의 임시 규약이고, 크기가 바이트로 확정돼(spec/engine/shape-quad.json:
    /// `"size"`→멤버 0x2F0 리플렉션 + vfunc+0x40 이 (float)(int)ortho.height 를 두 성분에 write)
    /// 저작 트랜스폼을 되살렸다. 이 씬은 ortho 1080 높이라 기본 크기가 1080×1080 정사각이다.
    func testEffectQuadPromotedToFullscreenEffectLayer() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[
           {"image":"models/x.json","origin":"960 540 0"},
           {"id":18661,"name":"dusk6","shape":"quad","origin":"266.3 -1671.7 0.0","parent":18660,
            "scale":"2.96 2.0 1.0","angles":"0 0 -2.92","castshadow":false,
            "effects":[{"file":"effects/lightshafts/effect.json","id":18662,"visible":true,
                        "passes":[{"combos":{"DIRECTDRAW":1,"RAYMODE":1},
                                   "constantshadervalues":{"rayspeed":0.31}}]}]}
         ]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.layers.count, 2, "이미지 + 승격된 이펙트 쿼드")
        let quad = doc.layers[1]
        XCTAssertEqual(quad.textureEntryName, "", "솔리드 캔버스")
        XCTAssertFalse(quad.isFrameBuffer)
        XCTAssertEqual(quad.origin, Vec2(x: 266.3, y: -1671.7), "저작 origin — 승격이 아니라 그대로")
        XCTAssertEqual(quad.size, Vec2(x: 1080, y: 1080),
                       "WE shape 기본 크기 = (orthoHeight, orthoHeight) 정사각 — width(1920) 가 아니다")
        XCTAssertEqual(quad.scale, Vec2(x: 2.96, y: 2.0), "저작 scale — 최종 크기는 size × scale")
        XCTAssertEqual(quad.angleZ, -2.92, accuracy: 1e-5, "angles[2] 라디안 그대로")
        XCTAssertEqual(quad.parent, 18660,
                       "지오메트리·가시성을 한 필드로 — visibilityParent 는 parent 에 흡수돼 사라졌다")
        XCTAssertEqual(quad.id, 18661)
        XCTAssertEqual(quad.name, "dusk6")
        XCTAssertEqual(quad.order, 1, "z-순서(objects[] 인덱스) 보존")
        XCTAssertEqual(quad.effects.count, 1)
        XCTAssertEqual(quad.effects[0].name, "lightshafts")
        XCTAssertEqual(quad.effects[0].combos["DIRECTDRAW"], 1)
        XCTAssertEqual(quad.effects[0].constants["rayspeed"], [0.31])
        XCTAssertFalse(doc.nodes3D.contains { $0.id == 18661 }, "트랜스폼-노드로 흡수되면 안 됨")
    }

    /// `size` 는 **기본값이지 고정값이 아니다** — 저작되면 그 값이 이긴다.
    ///
    /// 리플렉션 표가 `"size"` 를 오프셋 0x2F0 에 이름으로 묶어 둔 저작 가능 프로퍼티다
    /// (`spec/engine/shape-quad.json` §shape.sizeIsProperty0x2F0). vfunc+0x40 이 그 슬롯에
    /// (orthoH, orthoH) 를 써 두는 것은 저작 키가 없을 때의 초기값일 뿐이다.
    ///
    /// 처음 이식할 때 초기값만 옮기고 저작 경로를 빼먹었고, 그래서 `size:"1920 1080"` 을 쓰던
    /// `SceneCompositeConventionTests.testDirectDrawEffectOutputIsNotPremultipliedTwice` 가
    /// 1080 정사각으로 그려져 화면의 56% 만 덮었다(기하 예측 0.5625 · 실측 휘도비 0.5647).
    /// **증상이 "DIRECTDRAW 이중 곱 회귀" 와 똑같이 보였다** — 그 테스트가 재는 값이 0.5 → 0.28 로
    /// 떨어져 이중 곱 값 0.25 에 가까웠기 때문이다. 원인은 합성이 아니라 기하였다.
    /// 코퍼스 도달은 0건이라(shape 오브젝트 전수에 size 키 없음) 실사용 픽셀은 안 변한다.
    func testEffectQuadHonorsAuthoredSize() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[
           {"id":1,"shape":"quad","origin":"960 540 0","size":"1920 1080",
            "effects":[{"file":"effects/lightshafts/effect.json","id":2,
                        "passes":[{"combos":{"DIRECTDRAW":1}}]}]},
           {"id":3,"shape":"quad","origin":"100 200 0",
            "effects":[{"file":"effects/lightshafts/effect.json","id":4,
                        "passes":[{"combos":{"DIRECTDRAW":1}}]}]}
         ]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.layers.count, 2)
        XCTAssertEqual(doc.layers[0].size, Vec2(x: 1920, y: 1080),
                       "저작 size 가 기본 정사각을 이긴다")
        XCTAssertEqual(doc.layers[1].size, Vec2(x: 1080, y: 1080),
                       "저작 없으면 (orthoHeight, orthoHeight) 정사각 — width 가 아니다")
    }

    /// 정적 비가시 이펙트 쿼드는 종전 규약대로 렌더 대상에서 제외하되 비가시 노드로 계층만 보존(V06).
    func testEffectQuadStaticInvisiblePreservedAsNode() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"id":7,"shape":"quad","visible":false,
                     "effects":[{"file":"effects/lightshafts/effect.json","passes":[{}]}]}]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertTrue(doc.layers.isEmpty)
        XCTAssertTrue(doc.nodes3D.contains { $0.id == 7 && !$0.visible })
    }

    /// effects 없는 shape 오브젝트(코퍼스 0건)는 승격하지 않는다 — 종전 트랜스폼-노드 유지(무회귀).
    func testShapeWithoutEffectsRemainsTransformNode() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"id":9,"shape":"quad","origin":"1 2 3"}]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertTrue(doc.layers.isEmpty)
        XCTAssertTrue(doc.nodes3D.contains { $0.id == 9 })
    }

    /// camera 의사-오브젝트(실측 37씬/58오브젝트: fov/zoom/origin/path) — parseCamera 는 scene.camera 만
    /// 봐서 종전 parseNode 가 노드로 흡수. fov/zoom({user,value} 언랩)·origin(script+value)을 보존한다.
    func testCameraObjectParsedWithFovZoom() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[
           {"id":1297271,"camera":"default","name":"","fov":62.5,
            "zoom":{"user":"newproperty30","value":1.4},
            "origin":{"script":"export function update(v){return v;}","value":"2434.4 725.3 500.0"},
            "path":"scripts/camera_paths_1297271.json","queuemode":"random"}
         ]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.cameraObjects.count, 1)
        let cam = doc.cameraObjects[0]
        XCTAssertEqual(cam.id, 1297271)
        XCTAssertEqual(cam.fov, 62.5)
        XCTAssertEqual(cam.zoom, 1.4)
        XCTAssertEqual(cam.origin, Vec3(x: 2434.4, y: 725.3, z: 500.0))
        XCTAssertEqual(cam.scripts["origin"], "export function update(v){return v;}")
        XCTAssertNil(cam.zoomAnimation)
        XCTAssertTrue(doc.nodes3D.isEmpty, "카메라 의사-오브젝트가 트랜스폼-노드로 새면 안 됨")
        XCTAssertTrue(doc.layers.isEmpty)
    }

    /// zoom 키프레임 애니({animation,value} — 실측 9씬)는 PropertyAnimation 으로 보존, 정적 zoom 은 value.
    func testCameraObjectZoomAnimationCaptured() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[
           {"id":5,"camera":"default","fov":50.0,
            "zoom":{"animation":{"c0":[{"frame":0,"value":3},{"frame":36,"value":1}],
                                 "options":{"fps":12,"length":60,"mode":"single"}},
                    "value":3.0}}
         ]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.cameraObjects.count, 1)
        let cam = doc.cameraObjects[0]
        XCTAssertEqual(cam.zoom, 3.0)
        XCTAssertNotNil(cam.zoomAnimation)
        XCTAssertEqual(cam.zoomAnimation?.fps, 12)
    }

    /// M7: 이미지/텍스트/파티클 오브젝트-레벨 렌더 플래그 파싱.
    func testParsesObjectLevelRenderFlags() throws {
        let scene = #"{"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[{"id":1,"image":"models/x.json","origin":"0 0 0","disablepropagation":true,"copybackground":true,"clampuvs":true,"nointerpolation":true,"spacing":2.5,"locktransforms":true,"solid":true,"ledsource":true}]}"#
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        let layer = try XCTUnwrap(doc.layers.first)
        XCTAssertTrue(layer.disablePropagation)
        XCTAssertTrue(layer.copyBackground)
        XCTAssertTrue(layer.clampUVs)
        XCTAssertTrue(layer.noInterpolation)
        // spacing 은 vec2 다(WE 텍스트 디스크립터 0x1402594f4, 타입 1 `+0x4f8`). 숫자 저작은
        // 실물 vec2 주입기 0x1401a3fc0 가 **두 성분에 브로드캐스트**한다(0x1401a40a4–0x1401a40aa).
        XCTAssertEqual(try XCTUnwrap(layer.spacing).x, Float(2.5), accuracy: Float(1e-4))
        XCTAssertEqual(try XCTUnwrap(layer.spacing).y, Float(2.5), accuracy: Float(1e-4))
        XCTAssertTrue(layer.lockTransforms)
        XCTAssertTrue(layer.isSolid)
        XCTAssertTrue(layer.ledSource)
    }

    /// M5: composelayer config.passthrough 및 config 하위 플래그 파싱.
    func testParsesImageConfigFlags() throws {
        let scene = #"{"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[{"id":1,"image":"models/x.json","origin":"0 0 0","config":{"passthrough":true,"autosize":true,"solidlayer":true,"projectlayer":true,"instanced":true}}]}"#
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        let layer = try XCTUnwrap(doc.layers.first)
        XCTAssertTrue(layer.configPassthrough)
        XCTAssertTrue(layer.configAutosize)
        XCTAssertTrue(layer.configIsSolidLayer)
        XCTAssertTrue(layer.configIsProjectLayer)
        XCTAssertTrue(layer.configIsInstanced)
    }

    /// M9: camera 의사-오브젝트 path/queuemode 파싱.
    func testParsesCameraObjectPathAndQueueMode() throws {
        let scene = #"{"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[{"id":7,"camera":"default","fov":60,"path":"scripts/cam.json","queuemode":"sequential","disablepropagation":true,"locktransforms":true,"solid":true}]}"#
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        let cam = try XCTUnwrap(doc.cameraObjects.first)
        XCTAssertEqual(cam.path, "scripts/cam.json")
        XCTAssertEqual(cam.queueMode, "sequential")
        XCTAssertTrue(cam.disablePropagation)
        XCTAssertTrue(cam.lockTransforms)
        XCTAssertTrue(cam.isSolid)
    }

    /// M7: 텍스트 오브젝트 플래그 파싱.
    func testParsesTextObjectFlags() throws {
        let scene = #"{"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[{"id":1,"text":"hello","font":"systemfont_arial","pointsize":16,"origin":"0 0 0","disablepropagation":true,"copybackground":true,"clampuvs":true,"nointerpolation":true,"spacing":1.5,"locktransforms":true,"solid":true}]}"#
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        let t = try XCTUnwrap(doc.texts.first)
        XCTAssertTrue(t.disablePropagation)
        XCTAssertTrue(t.copyBackground)
        XCTAssertTrue(t.clampUVs)
        XCTAssertTrue(t.noInterpolation)
        XCTAssertEqual(try XCTUnwrap(t.spacing).x, Float(1.5), accuracy: Float(1e-4))
        XCTAssertEqual(try XCTUnwrap(t.spacing).y, Float(1.5), accuracy: Float(1e-4))   // 숫자 → 브로드캐스트
        XCTAssertTrue(t.lockTransforms)
        XCTAssertTrue(t.isSolid)
    }

    /// C⑨: 텍스트 outline/outlinecolor/outlinethickness/opaquebackground/backgroundcolor 파싱(실물
    /// 스키마 3737268876 "VHS Time and Date"/3047405322 "README" 그대로).
    func testParsesTextOutlineAndBackgroundFields() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"text":"hello","font":"systemfont_arial","pointsize":16,"origin":"0 0 0",
           "outline":true,"outlinecolor":"0.15294 0.15294 0.15294","outlinethickness":9.72,
           "opaquebackground":true,"backgroundcolor":"0 0 0"}]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        let t = try XCTUnwrap(doc.texts.first)
        XCTAssertTrue(t.outline)
        XCTAssertEqual(t.outlineColor.x, 0.15294, accuracy: 1e-4)
        XCTAssertEqual(t.outlineColor.y, 0.15294, accuracy: 1e-4)
        XCTAssertEqual(t.outlineColor.z, 0.15294, accuracy: 1e-4)
        XCTAssertEqual(t.outlineThickness, 9.72, accuracy: 1e-4)
        XCTAssertTrue(t.opaqueBackground)
        XCTAssertEqual(t.backgroundColor, Vec3(x: 0, y: 0, z: 0))
    }

    /// C⑨ 무회귀: 미저작 시 기본값(전부 off/검정) — 종전 동작과 동일.
    func testTextOutlineAndBackgroundFieldsDefaultOff() throws {
        let scene = #"{"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[{"id":1,"text":"hello","font":"systemfont_arial","pointsize":16,"origin":"0 0 0"}]}"#
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        let t = try XCTUnwrap(doc.texts.first)
        XCTAssertFalse(t.outline)
        XCTAssertFalse(t.opaqueBackground)
        // F4-polish①: 무저작 기본값 — anchor="none"/padding=(0,0)/backgroundBrightness=1(0 아님 — 부재 시
        // 0 이면 향후 소비부에서 검정 박스로 오염되는 잠재 함정).
        XCTAssertEqual(t.anchor, "none")
        XCTAssertEqual(t.padding, Vec2(x: 0, y: 0))
        XCTAssertEqual(t.backgroundBrightness, 1)
    }

    /// F4-polish①: anchor/padding/backgroundbrightness 파싱 — 실측 코퍼스 스키마 그대로(3526096300/
    /// 3538758087 등). padding 은 **혼합 타입**(스칼라 정수/실수 vs "x y" 벡터 문자열) 둘 다 저작되므로
    /// 두 형태를 모두 커버(스칼라 케이스가 결함 포착 지점 — vec2()/float() 개별로는 어느 한쪽만 처리).
    func testParsesTextAnchorPaddingBackgroundBrightness() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[
           {"id":1,"text":"a","font":"systemfont_arial","pointsize":16,"origin":"0 0 0",
             "anchor":"center","padding":32,"backgroundbrightness":1.0},
           {"id":2,"text":"b","font":"systemfont_arial","pointsize":16,"origin":"0 0 0",
             "anchor":"topright","padding":"24.00000 48.00000","backgroundbrightness":0.5}
         ]}
        """
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.texts.count, 2)
        let scalar = doc.texts[0]
        XCTAssertEqual(scalar.anchor, "center")
        XCTAssertEqual(scalar.padding, Vec2(x: 32, y: 32))   // 스칼라 → 양축 확장
        XCTAssertEqual(scalar.backgroundBrightness, 1.0, accuracy: 1e-4)
        let vector = doc.texts[1]
        XCTAssertEqual(vector.anchor, "topright")
        XCTAssertEqual(vector.padding, Vec2(x: 24, y: 48))   // "x y" 벡터 문자열
        XCTAssertEqual(vector.backgroundBrightness, 0.5, accuracy: 1e-4)
    }

    /// H1: 머티리얼 passes[0] 의 shader/combos/constantshadervalues/textures 파스 보존.
    func testParsesMaterialCustomShaderFields() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"image":"models/x.json","origin":"960 540","size":"1920 1080","scale":"1 1",
                     "angles":"0 0 0","alpha":0.8,"color":"1 0.5 0.5","brightness":0.9,"visible":true}]}
        """
        let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
        let material = #"{"passes":[{"shader":"genericimage2","textures":["pic",null,"mask"],"combos":{"LIGHTING":1,"SPRITESHEET":0},"constantshadervalues":{"roughness":0.5,"metallic":{"value":0.2},"color":{"script":"return [1,0,0];","value":"1 1 1","scriptproperties":{"foo":1}}}}]}"#
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        let layer = doc.layers[0]
        XCTAssertEqual(layer.materialShader, "genericimage2")
        XCTAssertEqual(layer.materialCombos["LIGHTING"], 1)
        XCTAssertEqual(layer.materialCombos["SPRITESHEET"], 0)
        XCTAssertEqual(layer.materialConstants["roughness"], [0.5])
        XCTAssertEqual(layer.materialConstants["metallic"], [0.2])
        XCTAssertEqual(layer.materialConstants["color"], [1, 1, 1])
        XCTAssertEqual(layer.materialConstantScripts["color"], "return [1,0,0];")
        XCTAssertNotNil(layer.materialConstantScriptProps["color"])
        XCTAssertEqual(layer.materialTextureNames, ["pic", nil, "mask"])
        // 기존 PBR 필드도 유지(폴터 경로).
        XCTAssertEqual(layer.roughness, 0.5)
        XCTAssertEqual(layer.metallic, 0.2)
    }

    /// H1: shader 필드 부재 시 nil — 기존 고정 경로(무회귀).
    func testMaterialShaderAbsentLeavesNil() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"image":"models/x.json","origin":"960 540","size":"1920 1080","scale":"1 1",
                     "angles":"0 0 0","alpha":1.0,"color":"1 1 1","brightness":1.0,"visible":true}]}
        """
        let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
        let material = #"{"passes":[{"textures":["pic"]}]}"#
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertNil(doc.layers[0].materialShader)
        XCTAssertTrue(doc.layers[0].materialCombos.isEmpty)
        XCTAssertTrue(doc.layers[0].materialConstants.isEmpty)
    }

    /// H2/C⑦a: usershadervalues 가 머티리얼 상수를 user property 로 오버라이드.
    /// 실물 규약(fantasticcar body.json)은 {JSON 키=user property 키, JSON 값=셰이더 상수 토큰} —
    /// "tintcolor"(유저프로퍼티) → "color"(셰이더 상수 토큰) 처럼 서로 다른 이름일 때만 방향 결함이
    /// 드러난다(같은 이름 roughness/metallic 은 방향이 반대여도 우연히 일치해 무증상이었다).
    func testParsesMaterialUserShaderValues() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"image":"models/x.json","origin":"960 540","size":"1920 1080","scale":"1 1",
                     "angles":"0 0 0","alpha":1.0,"color":"1 1 1","brightness":1.0,"visible":true}]}
        """
        let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
        let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"],"constantshadervalues":{"roughness":0.5,"metallic":0.2,"color":"1 1 1"},"usershadervalues":{"roughness":"roughness","metallic":"metallic","tintcolor":"color"}}]}"#
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let userProps: [String: Any] = ["roughness": 0.9, "metallic": 0.7, "tintcolor": "0.1 0.2 0.3"]
        let doc = try SceneDocument.parse(package: p, userProps: userProps)
        let layer = doc.layers[0]
        XCTAssertEqual(layer.materialUserShaderValues["roughness"], "roughness")
        XCTAssertEqual(layer.materialUserShaderValues["metallic"], "metallic")
        XCTAssertEqual(layer.materialUserShaderValues["color"], "tintcolor")
        // usershadervalues 오버라이드 반영.
        XCTAssertEqual(layer.materialConstants["roughness"], [0.9])
        XCTAssertEqual(layer.materialConstants["metallic"], [0.7])
        XCTAssertEqual(layer.materialConstants["color"], [0.1, 0.2, 0.3])
        // 기존 PBR 필드도 usershadervalues 반영.
        XCTAssertEqual(layer.roughness, 0.9)
        XCTAssertEqual(layer.metallic, 0.7)
    }

    /// H2: user property 부재 시 constantshadervalues 폴터(무회귀).
    func testMaterialUserShaderValuesFallbackToConstants() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"image":"models/x.json","origin":"960 540","size":"1920 1080","scale":"1 1",
                     "angles":"0 0 0","alpha":1.0,"color":"1 1 1","brightness":1.0,"visible":true}]}
        """
        let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
        let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"],"constantshadervalues":{"roughness":0.5,"metallic":0.2},"usershadervalues":{"roughness":"roughness","metallic":"metallic"}}]}"#
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        let layer = doc.layers[0]
        XCTAssertEqual(layer.materialConstants["roughness"], [0.5])
        XCTAssertEqual(layer.materialConstants["metallic"], [0.2])
        XCTAssertEqual(layer.roughness, 0.5)
        XCTAssertEqual(layer.metallic, 0.2)
    }

    /// H4: REFRACT 콤보 + 노멀맵 + refractAmount 파싱.
    func testParsesMaterialRefractFields() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"image":"models/x.json","origin":"960 540","size":"1920 1080","scale":"1 1",
                     "angles":"0 0 0","alpha":1.0,"color":"1 1 1","brightness":1.0,"visible":true}]}
        """
        let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
        let material = #"{"passes":[{"shader":"genericimage2","textures":["albedo","normal"],"combos":{"REFRACT":1},"constantshadervalues":{"ui_editor_properties_refract_amount":0.15}}]}"#
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        let layer = doc.layers[0]
        XCTAssertTrue(layer.refract)
        XCTAssertEqual(layer.normalTextureName, "normal")
        XCTAssertEqual(layer.refractAmount, 0.15, accuracy: 1e-4)
    }

    /// H4: REFRACT=1 이지만 노멀맵(textures[1]) 없으면 refract=false.
    func testMaterialRefractRequiresNormalMap() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"image":"models/x.json","origin":"960 540","size":"1920 1080","scale":"1 1",
                     "angles":"0 0 0","alpha":1.0,"color":"1 1 1","brightness":1.0,"visible":true}]}
        """
        let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
        let material = #"{"passes":[{"shader":"genericimage2","textures":["albedo"],"combos":{"REFRACT":1}}]}"#
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertFalse(doc.layers[0].refract)
        XCTAssertNil(doc.layers[0].normalTextureName)
    }

    /// H7: 품질 설정(general.quality) 파싱.
    func testParsesQualitySetting() throws {
        let scene = #"{"general":{"orthogonalprojection":{"width":100,"height":100},"quality":"high"},"objects":[]}"#
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.quality, .high)
    }

    /// H7: 품질 설정 부재 시 ultra(무회귀).
    func testQualityDefaultsToUltra() throws {
        let scene = #"{"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[]}"#
        let doc = try SceneDocument.parse(package: try pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.quality, .ultra)
    }
}
