import XCTest
@testable import WapleCore

/// `docs/re/unimplemented-json-keys.md` §5 의 7개 키 파스 검증(2026-08-21).
///
/// | # | 키 | 스키마 | 착지 |
/// | ---: | --- | --- | --- |
/// | 3 | `schemecolor` | project `general.properties`(값 채널은 `userProps`) | `SceneDocument.schemeColor` |
/// | 12 | `nopadding` | model 루트 | `SceneLayer.noPadding` |
/// | 13 | `transparentsorting` | scene `general` | `SceneDocument.transparentSorting` |
/// | 14 | `auto` | scene `general.orthogonalprojection` | `SceneDocument.orthoAuto` + pw/ph 판정 |
/// | 15 | `spritesheetrefreshsync` | scene `general` | `SceneDocument.spritesheetRefreshSync` |
/// | 17/22 | `lightconfig`/`pointshadow` | scene `general` | `SceneDocument.lightConfig` |
/// | 19 | `keepaspect` | material `passes[].usertextures[]` | `SceneLayer.materialUserTextureKeepAspect` |
///
/// 이 파일이 지키는 두 축:
///  1. **WE 규약** — 태그 검사(bool 은 태그 5, lightconfig 값은 `isUInt`)를 그대로 재현하는가.
///     문자열 `"true"`·숫자 `1` 이 참으로 새면 원본과 갈린다.
///  2. **무회귀** — 키가 없는 씬(동봉 대다수)의 파스 결과가 종전과 완전히 같은가.
///     특히 `orthogonalprojection.auto` 는 `projectionWidth/Height` 를 만지는 유일한 신규 분기다.
///
/// 합성 씬뿐 아니라 **동봉 실물 씬**으로도 건다 — 도달 수치(각 2건)가 회귀 감시 대상이다.
final class SceneGeneralKeysTests: XCTestCase {

    private func doc(_ scene: String, _ extra: [(String, String)] = [],
                     userProps: [String: Any] = [:]) throws -> SceneDocument {
        try SceneDocument.parse(package: pkg([("scene.json", scene)] + extra), userProps: userProps)
    }

    /// `general` 딕셔너리만 갈아 끼우는 최소 씬(오브젝트 0 — general 파스만 본다).
    private func general(_ body: String) -> String {
        """
        {"general":{"orthogonalprojection":{"width":100,"height":100}\(body.isEmpty ? "" : ",")\(body)},
         "objects":[]}
        """
    }

    // MARK: - #13 transparentsorting / #15 spritesheetrefreshsync

    /// 씬 플래그 워드 `scene+0xE0` 의 bit12(`0x14019C1F9` `bts ecx,0xc`) / bit6(`0x140187674`).
    /// 생성자가 그 워드를 `0x26`(bits 1·2·5)으로 깔므로(`0x140186D1F`) **둘 다 부재 시 false**.
    func testSceneFlagBoolsParse() throws {
        let on = try doc(general(#""transparentsorting":true,"spritesheetrefreshsync":true"#))
        XCTAssertTrue(on.transparentSorting)
        XCTAssertTrue(on.spritesheetRefreshSync)

        let off = try doc(general(#""transparentsorting":false,"spritesheetrefreshsync":false"#))
        XCTAssertFalse(off.transparentSorting)
        XCTAssertFalse(off.spritesheetRefreshSync)
    }

    /// 부재 → false(종전 동작과 동치, 동봉 172씬 중 170씬이 이 경로).
    func testSceneFlagBoolsDefaultFalseWhenAbsent() throws {
        let d = try doc(general(""))
        XCTAssertFalse(d.transparentSorting)
        XCTAssertFalse(d.spritesheetRefreshSync)
    }

    /// WE 는 `cmp byte [node+8], 5` 로 **태그 5(booleanValue)만** 통과시킨다 —
    /// 문자열 `"true"` 도 숫자 `1` 도 참이 아니다. 여기서 관용을 늘리면 원본과 갈린다.
    ///
    /// 숫자 `1`/`1.0` 이 이 그물의 핵심이다: `JSONSerialization` 이 `true` 와 `1` 을 똑같이
    /// `NSNumber` 로 주고 `NSNumber(1) as? Bool` 이 **참**이라, 맨 `as? Bool` 로 읽으면
    /// 조용히 샌다(`weBool` 이 `CFGetTypeID` 로 막는 자리). JSON 을 거쳐야 재현된다 —
    /// 스위프트 리터럴 `["x": 1]` 로는 이 경로가 안 만들어진다.
    func testSceneFlagBoolsRejectNonBooleanTags() throws {
        for form in [#""true""#, "1", "1.0", "\"1\"", "null", "{}", "[true]"] {
            let d = try doc(general(#""transparentsorting":\#(form),"spritesheetrefreshsync":\#(form)"#))
            XCTAssertFalse(d.transparentSorting, "transparentsorting=\(form) 은 태그 5 가 아니다")
            XCTAssertFalse(d.spritesheetRefreshSync, "spritesheetrefreshsync=\(form) 은 태그 5 가 아니다")
        }
    }

    /// `{"user":…,"value":true}` 바인딩은 다른 씬 bool 키와 동일하게 언랩된다(파스 전
    /// `resolveUserBindings` 가 못 푸는 형태도 `unwrap` 이 정적 value 를 꺼낸다).
    func testSceneFlagBoolsUnwrapValueBinding() throws {
        let d = try doc(general(#""transparentsorting":{"user":"ts","value":true}"#))
        XCTAssertTrue(d.transparentSorting)
    }

    // MARK: - #14 orthogonalprojection.auto

    /// 핵심 규약: `auto == true` 면 WE 는 `width`/`height` **값을 읽지 않는다**
    /// (`0x140187565` `or [scene+0xE0],0x18` 직후 `0x14018756D` 이 값 저장 블록을 건너뛴다).
    /// 그래서 둘이 저작돼 있어도 정사영 크기는 씬이 아니라 출력이 정한다.
    func testOrthoAutoIgnoresAuthoredWidthHeight() throws {
        let d = try doc("""
        {"general":{"orthogonalprojection":{"auto":true,"width":256,"height":256}},"objects":[]}
        """)
        XCTAssertTrue(d.orthoAuto)
        XCTAssertEqual(d.projectionWidth, 1920)
        XCTAssertEqual(d.projectionHeight, 1080)
    }

    /// `auto` 만 있는 형태(동봉 저작 2씬이 정확히 이 형태) — 폴백과 값이 같아 **무회귀**.
    func testOrthoAutoAloneKeepsFallbackSize() throws {
        let d = try doc(#"{"general":{"orthogonalprojection":{"auto":true}},"objects":[]}"#)
        XCTAssertTrue(d.orthoAuto)
        XCTAssertEqual(d.projectionWidth, 1920)
        XCTAssertEqual(d.projectionHeight, 1080)
    }

    /// `auto` 가 태그 5 가 아니면(문자열/숫자) width/height 경로로 내려간다 —
    /// `check_ortho_projection_census.py` 의 음성 대조와 같은 판정이다.
    func testOrthoAutoNonBooleanFallsThroughToWidthHeight() throws {
        for form in [#""auto""#, #""true""#, "1", "1.0", "null"] {
            let d = try doc("""
            {"general":{"orthogonalprojection":{"auto":\(form),"width":256,"height":256}},"objects":[]}
            """)
            XCTAssertFalse(d.orthoAuto, "auto=\(form)")
            XCTAssertEqual(d.projectionWidth, 256, "auto=\(form)")
            XCTAssertEqual(d.projectionHeight, 256, "auto=\(form)")
        }
    }

    /// `auto:false` 는 width/height 경로(항등) — 신규 분기가 종전 동작을 가리지 않는지.
    func testOrthoAutoFalseReadsWidthHeight() throws {
        let d = try doc("""
        {"general":{"orthogonalprojection":{"auto":false,"width":640,"height":480}},"objects":[]}
        """)
        XCTAssertFalse(d.orthoAuto)
        XCTAssertEqual(d.projectionWidth, 640)
        XCTAssertEqual(d.projectionHeight, 480)
    }

    /// `orthogonalprojection` 이 태그 7 이 아니면(3D 씬은 `null`) `auto` 자체가 없다 — 종전과 동치.
    func testOrthoAutoFalseWhenProjectionNotObject() throws {
        let d = try doc(#"{"general":{"orthogonalprojection":null},"objects":[]}"#)
        XCTAssertFalse(d.orthoAuto)
        XCTAssertEqual(d.projectionWidth, 1920)
        XCTAssertEqual(d.projectionHeight, 1080)
    }

    // MARK: - #17/#22 lightconfig + pointshadow

    /// 동봉 실측 두 형태. 저작 안 된 키는 0, 저작 안 된 씬은 nil.
    func testLightConfigParsesAuthoredCounts() throws {
        let a = try XCTUnwrap(try doc(general(#""lightconfig":{"point":2}"#)).lightConfig)
        XCTAssertEqual(a.point, 2)
        XCTAssertEqual(a.spot, 0)
        XCTAssertEqual(a.pointShadow, 0)

        let b = try XCTUnwrap(try doc(general(#""lightconfig":{"point":1,"pointshadow":1}"#)).lightConfig)
        XCTAssertEqual(b.point, 1)
        XCTAssertEqual(b.pointShadow, 1)
    }

    /// 아홉 키 전부가 각자 필드로 간다(동봉 도달은 두 개뿐이라 나머지 일곱은 여기서만 검증된다).
    func testLightConfigAllNineFields() throws {
        // JSON 경유로 만든다 — WE 가 읽는 것도 jsoncpp 노드이고, 태그 판정(`isUInt`)이
        // 스위프트 네이티브 Int 가 아니라 `NSNumber` 브리지를 타는 게 실제 경로다.
        let c = try XCTUnwrap(SceneLightConfig.parse(json("""
        {"point":3,"spot":4,"tube":5,"directional":6,
         "pointshadow":1,"spotshadow":2,"spotcookie":3,
         "spotshadowcookie":1,"directionalshadow":2}
        """)))
        XCTAssertEqual(c.point, 3)
        XCTAssertEqual(c.spot, 4)
        XCTAssertEqual(c.tube, 5)
        XCTAssertEqual(c.directional, 6)
        XCTAssertEqual(c.pointShadow, 1)
        XCTAssertEqual(c.spotShadow, 2)
        XCTAssertEqual(c.spotCookie, 3)
        XCTAssertEqual(c.spotShadowCookie, 1)
        XCTAssertEqual(c.directionalShadow, 2)
    }

    /// 저장 폭은 **절단**이지 클램프가 아니다(`and eax,0xF` / `and eax,3`).
    /// `point:16` → 0, `point:17` → 1, `pointshadow:4` → 0. 신뢰 경계 밖 숫자가 배열 길이로
    /// 새지 않는다는 보증이기도 하다.
    func testLightConfigTruncatesRatherThanClamps() throws {
        func lc(_ body: String) throws -> SceneLightConfig {
            try XCTUnwrap(SceneLightConfig.parse(json("{\(body)}")))
        }
        XCTAssertEqual(try lc(#""point":16"#).point, 0)
        XCTAssertEqual(try lc(#""point":17"#).point, 1)
        XCTAssertEqual(try lc(#""pointshadow":4"#).pointShadow, 0)
        XCTAssertEqual(try lc(#""pointshadow":3"#).pointShadow, 3)
        // 2³² 이상은 isUInt 자체가 탈락(`0x1400887DE` `cmp rdx, 0xFFFFFFFF`) → 절단 전에 0.
        XCTAssertEqual(try lc(#""point":4294967296"#).point, 0)
    }

    /// `isUInt`(`0x140088760`) 게이트 — bool·문자열·null·객체·음수·소수는 전부 0.
    /// 정수인 real(`2.0`)은 통과한다(`modf` 잔여가 0 이면 허용, `0x1400887A1`).
    func testLightConfigIsUIntGate() throws {
        let d = try doc(general("""
        "lightconfig":{"point":true,"spot":"2","tube":null,"directional":{"value":3},
                       "pointshadow":-1,"spotshadow":1.5,"spotcookie":2.0}
        """))
        let c = try XCTUnwrap(d.lightConfig)
        XCTAssertEqual(c.point, 0, "bool 은 태그 5 — isUInt 탈락")
        XCTAssertEqual(c.spot, 0, "문자열은 태그 4 — isUInt 탈락")
        XCTAssertEqual(c.tube, 0, "null 은 태그 0 — isUInt 탈락")
        XCTAssertEqual(c.directional, 0, "{value:…} 바인딩은 태그 7 — WE 도 언랩하지 않는다")
        XCTAssertEqual(c.pointShadow, 0, "음수는 isUInt 탈락")
        XCTAssertEqual(c.spotShadow, 0, "소수부가 있으면 isUInt 탈락")
        XCTAssertEqual(c.spotCookie, 2, "정수인 real 은 통과")
    }

    /// 태그 7 이 아니면 WE 는 아홉 키를 `find` 조차 하지 않는다(`0x140187732`) → nil.
    func testLightConfigNilWhenNotObject() throws {
        XCTAssertNil(SceneLightConfig.parse(nil))
        XCTAssertNil(SceneLightConfig.parse("point"))
        XCTAssertNil(SceneLightConfig.parse([1, 2] as [Any]))
        XCTAssertNil(try doc(general("")).lightConfig, "미저작 씬은 nil(저작 여부를 구분해 남긴다)")
        XCTAssertNil(try doc(general(#""lightconfig":null"#)).lightConfig)
    }

    /// 빈 객체는 nil 이 아니라 "전건 0 으로 저작됨" 이다 — 소비 시점의 폴백 선택이 달라진다.
    func testLightConfigEmptyObjectIsAuthoredZero() throws {
        let c = try XCTUnwrap(try doc(general(#""lightconfig":{}"#)).lightConfig)
        XCTAssertEqual(c, SceneLightConfig())
    }

    // MARK: - #3 schemecolor

    /// 값 채널은 `userProps`(project.json 기본값 < preset < 유저 오버라이드가 이미 합쳐진 것).
    /// WE 는 `"r g b"` 를 `strtod` 세 번으로 읽어 `[wallpaper+0x31B0/4/8]` 에 담는다.
    func testSchemeColorFromUserProps() throws {
        let d = try doc(general(""), userProps: ["schemecolor": "0.8 0.4 0.05"])
        XCTAssertEqual(d.schemeColor.x, 0.8, accuracy: 1e-6)
        XCTAssertEqual(d.schemeColor.y, 0.4, accuracy: 1e-6)
        XCTAssertEqual(d.schemeColor.z, 0.05, accuracy: 1e-6)
    }

    /// 부재 → (0,0,0)(생성자 실측 `0x140110BD1`·`0x14012B9C8`). 동봉 preview 161건의 저작값
    /// `"0 0 0"` 과도 동치라 그 씬들의 파스 결과가 달라지지 않는다.
    func testSchemeColorDefaultsToZero() throws {
        XCTAssertEqual(try doc(general("")).schemeColor, Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(try doc(general(""), userProps: ["schemecolor": "0 0 0"]).schemeColor,
                       Vec3(x: 0, y: 0, z: 0))
    }

    /// 태그 4(stringValue) 검사(`0x14018222B`)와 동형 — 문자열이 아니면 슬롯을 안 건드린다.
    func testSchemeColorIgnoresNonStringValue() throws {
        for raw in [1 as Any, true as Any, ["r": 1] as Any] {
            XCTAssertEqual(try doc(general(""), userProps: ["schemecolor": raw]).schemeColor,
                           Vec3(x: 0, y: 0, z: 0))
        }
    }

    /// 성분이 모자라면 **남은 성분은 0**(`strtod` 가 빈 꼬리에서 0 을 준다). 숫자가 아닌 토큰도 0
    /// 이고 **자리는 유지된다** — 이 파일의 `vec3()`(3성분 미만 nil, 실패 항목 드롭)와 다른 규약이다.
    func testSchemeColorPadsMissingComponentsWithZero() throws {
        XCTAssertEqual(try doc(general(""), userProps: ["schemecolor": "1 0.5"]).schemeColor,
                       Vec3(x: 1, y: 0.5, z: 0))
        XCTAssertEqual(try doc(general(""), userProps: ["schemecolor": ""]).schemeColor,
                       Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(try doc(general(""), userProps: ["schemecolor": "0.25 zz 0.75"]).schemeColor,
                       Vec3(x: 0.25, y: 0, z: 0.75))
    }

    // MARK: - #12 nopadding / #19 keepaspect (레이어 경로)

    private static let sceneWithImage = """
    {"general":{"orthogonalprojection":{"width":100,"height":100}},
     "objects":[{"id":1,"image":"models/x.json","origin":"50 50 0","size":"8 8"}]}
    """

    /// 모델 **루트**의 `nopadding`(`0x1401FAE56` `or [model+0x304], 4`). 오브젝트의 `config` 가
    /// 아니라 model json 루트다 — 두 자리를 헷갈리면 동봉 4개 자산이 전부 어긋난다.
    func testModelRootNoPaddingParses() throws {
        let mat = #"{"passes":[{"shader":"genericimage","textures":["pic"]}]}"#
        let on = try doc(Self.sceneWithImage, [
            ("models/x.json", #"{"material":"materials/m.json","nopadding":true,"autosize":true}"#),
            ("materials/m.json", mat)])
        XCTAssertEqual(on.layers.first?.noPadding, true)

        let off = try doc(Self.sceneWithImage, [
            ("models/x.json", #"{"material":"materials/m.json"}"#), ("materials/m.json", mat)])
        XCTAssertEqual(off.layers.first?.noPadding, false, "부재 → false(항등)")

        // 태그 5 만 통과 — 문자열 "true" 는 참이 아니다.
        let str = try doc(Self.sceneWithImage, [
            ("models/x.json", #"{"material":"materials/m.json","nopadding":"true"}"#),
            ("materials/m.json", mat)])
        XCTAssertEqual(str.layers.first?.noPadding, false)
    }

    /// 오브젝트 `config.autosize`/`config.passthrough` 는 **다른 키다** — model 루트 플래그가
    /// 그쪽으로 새거나 그 반대가 되지 않는지 못박는다.
    func testNoPaddingIsNotObjectConfigFlag() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"50 50 0","size":"8 8",
                     "config":{"autosize":true,"passthrough":true}}]}
        """
        let d = try doc(scene, [("models/x.json", #"{"material":"materials/m.json"}"#),
                                ("materials/m.json", #"{"passes":[{"textures":["pic"]}]}"#)])
        let l = try XCTUnwrap(d.layers.first)
        XCTAssertFalse(l.noPadding, "config.autosize 가 noPadding 으로 새면 안 된다")
        XCTAssertTrue(l.configAutosize)
        XCTAssertTrue(l.configPassthrough)
    }

    /// 머티리얼 패스 `usertextures` 슬롯 — 딕셔너리 형태의 `keepaspect`(`0x1401548A0`
    /// `cmovne r12d,1`)와 슬롯 이름이 **같은 인덱스**로 보존되는가. 동봉 유일 도달 자산
    /// (`scenes/videoplayer/materials/background.json`)과 같은 형태다.
    func testMaterialUserTextureKeepAspectParses() throws {
        let d = try doc(Self.sceneWithImage, [
            ("models/x.json", #"{"material":"materials/m.json"}"#),
            ("materials/m.json", """
             {"passes":[{"shader":"genericimage","textures":["util/black"],
               "usertextures":[{"name":"videotex","keepaspect":true},
                               "plainkey",
                               {"name":"other","keepaspect":false},
                               {"name":"noflag"}]}]}
             """)])
        let l = try XCTUnwrap(d.layers.first)
        XCTAssertEqual(l.materialUserTextureNames, ["videotex", "plainkey", "other", "noflag"])
        XCTAssertEqual(l.materialUserTextureKeepAspect, [true, false, false, false],
                       "평문 문자열 슬롯은 keepaspect 를 읽지 않는다(항상 false)")
    }

    /// `usertextures` 가 없는 머티리얼(동봉 대다수) → 두 배열 모두 비어 있음(항등).
    func testMaterialUserTextureAbsentKeepsEmptyArrays() throws {
        let d = try doc(Self.sceneWithImage, [
            ("models/x.json", #"{"material":"materials/m.json"}"#),
            ("materials/m.json", #"{"passes":[{"textures":["pic"]}]}"#)])
        let l = try XCTUnwrap(d.layers.first)
        XCTAssertTrue(l.materialUserTextureNames.isEmpty)
        XCTAssertTrue(l.materialUserTextureKeepAspect.isEmpty)
    }

    // MARK: - 동봉 실물 코퍼스

    /// 동봉 실물 씬 5개의 파스 결과. 합성 JSON 이 아니라 **WE 가 저작한 바이트**로 건다.
    func testBundledScenesCarryTheNewKeys() throws {
        guard let root = AssetJSONLenientTests.bundledAssetsRoot() else {
            throw XCTSkip("WAPLE_WE_ASSETS 미지정 — 동봉 자산 트리를 못 찾았다")
        }
        func parse(_ rel: String) throws -> SceneDocument {
            let url = root.appendingPathComponent(rel)
            let text = try XCTUnwrap(String(data: try Data(contentsOf: url), encoding: .utf8), rel)
            return try SceneDocument.parse(package: pkg([("scene.json", text)]))
        }
        // #13 transparentsorting + #17 lightconfig(point:2) — 코퍼스의 원근 씬 2개 중 하나.
        let modelEditor = try parse("scenes/modeleditor/scene.json")
        XCTAssertTrue(modelEditor.transparentSorting)
        XCTAssertEqual(modelEditor.lightConfig?.point, 2)
        XCTAssertEqual(modelEditor.lightConfig?.pointShadow, 0)
        XCTAssertFalse(modelEditor.orthoAuto, "orthogonalprojection:null 은 태그 7 이 아니다")

        let particleEditor = try parse("scenes/particleeditor3dscale/scene.json")
        XCTAssertTrue(particleEditor.transparentSorting)

        // #14 auto + #15 spritesheetrefreshsync — GIF/동영상 템플릿 2씬.
        for rel in ["scenes/gifs/gifscene.json", "scenes/videoplayer/scene.json"] {
            let d = try parse(rel)
            XCTAssertTrue(d.orthoAuto, rel)
            XCTAssertTrue(d.spritesheetRefreshSync, rel)
            XCTAssertEqual(d.projectionWidth, 1920, rel)
            XCTAssertEqual(d.projectionHeight, 1080, rel)
        }

        // #22 pointshadow — 동봉 유일 도달(preview).
        let collision = try parse("scenes/particleelementpreviews/collisionmodel/scene.json")
        XCTAssertEqual(collision.lightConfig?.point, 1)
        XCTAssertEqual(collision.lightConfig?.pointShadow, 1)
        XCTAssertEqual(collision.projectionWidth, 256, "auto 없는 씬은 width/height 경로")
    }

    /// #12/#19 동봉 실물 경로 — `scenes/videoplayer` 의 model 루트 `nopadding` 과
    /// material `usertextures[0].keepaspect` 가 레이어까지 살아 오는가.
    func testBundledVideoPlayerLayerCarriesNoPaddingAndKeepAspect() throws {
        guard let root = AssetJSONLenientTests.bundledAssetsRoot() else {
            throw XCTSkip("WAPLE_WE_ASSETS 미지정")
        }
        func text(_ rel: String) throws -> String {
            try XCTUnwrap(String(data: try Data(contentsOf: root.appendingPathComponent(rel)),
                                 encoding: .utf8), rel)
        }
        let d = try SceneDocument.parse(package: pkg([
            ("scene.json", try text("scenes/videoplayer/scene.json")),
            ("models/background.json", try text("scenes/videoplayer/models/background.json")),
            ("materials/background.json", try text("scenes/videoplayer/materials/background.json")),
        ]))
        let l = try XCTUnwrap(d.layers.first)
        XCTAssertTrue(l.noPadding, "models/background.json 루트 nopadding:true")
        XCTAssertEqual(l.materialUserTextureNames, ["videotex"])
        XCTAssertEqual(l.materialUserTextureKeepAspect, [true])
    }

    /// **도달 인구조사** — 동봉 씬 전수에서 각 키를 저작한 파일 수를 못박는다.
    /// 이 수가 바뀌면(자산이 늘거나 파스 규약이 바뀌면) 여기서 먼저 걸린다.
    /// 파스 계층이 아니라 원문 JSON 을 세므로, 위 파스 테스트와 **독립적인** 두 번째 그물이다.
    func testBundledReachCensus() throws {
        guard let root = AssetJSONLenientTests.bundledAssetsRoot() else {
            throw XCTSkip("WAPLE_WE_ASSETS 미지정")
        }
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("자산 트리를 못 훑었다")
        }
        var scenes = 0
        var transparentSorting = 0, refreshSync = 0, orthoAuto = 0, lightConfig = 0, pointShadow = 0
        var models = 0, noPadding = 0
        var keepAspect = 0
        for case let url as URL in en where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = AssetJSON.dictionary(data) else { continue }
            if let g = obj["general"] as? [String: Any], obj["objects"] != nil {
                scenes += 1
                if g["transparentsorting"] as? Bool == true { transparentSorting += 1 }
                if g["spritesheetrefreshsync"] as? Bool == true { refreshSync += 1 }
                if let p = g["orthogonalprojection"] as? [String: Any], p["auto"] as? Bool == true {
                    orthoAuto += 1
                }
                if let lc = g["lightconfig"] as? [String: Any] {
                    lightConfig += 1
                    if lc["pointshadow"] != nil { pointShadow += 1 }
                }
            }
            if obj["material"] is String {
                models += 1
                if obj["nopadding"] as? Bool == true { noPadding += 1 }
            }
            for pass in (obj["passes"] as? [Any] ?? []) {
                for slot in ((pass as? [String: Any])?["usertextures"] as? [Any] ?? []) {
                    if (slot as? [String: Any])?["keepaspect"] as? Bool == true { keepAspect += 1 }
                }
            }
        }
        XCTAssertGreaterThan(scenes, 150, "씬 트리가 비었다 — 경로가 틀린 것")
        XCTAssertGreaterThan(models, 100, "모델 트리가 비었다 — 경로가 틀린 것")
        XCTAssertEqual(transparentSorting, 2, "modeleditor + particleeditor3dscale")
        XCTAssertEqual(refreshSync, 2, "gifs + videoplayer")
        XCTAssertEqual(orthoAuto, 2, "gifs + videoplayer")
        XCTAssertEqual(lightConfig, 2, "modeleditor + collisionmodel")
        XCTAssertEqual(pointShadow, 1, "collisionmodel 만")
        XCTAssertEqual(noPadding, 2, "gifs/models + videoplayer/models")
        XCTAssertEqual(keepAspect, 1, "videoplayer/materials/background.json")
    }
}
