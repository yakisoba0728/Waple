import XCTest
@testable import WapleCore

final class WallpaperPropertiesTests: XCTestCase {
    func testParsesColorBoolSliderCombo() {
        let general: [String: Any] = [
            "bg":   ["type": "color",  "value": "0.6 0.4 0.3", "order": 0],
            "flag": ["type": "bool",   "value": true,          "order": 1],
            "amt":  ["type": "slider", "value": 0.5,           "order": 2],
            "mode": ["type": "combo",  "value": "a",           "order": 3],
        ]
        let props = WallpaperProperties.parse(generalProperties: general)
        let byKey = Dictionary(uniqueKeysWithValues: props.map { ($0.key, $0) })
        XCTAssertEqual(byKey["bg"]?.value, .string("0.6 0.4 0.3"))
        XCTAssertEqual(byKey["flag"]?.value, .bool(true))
        XCTAssertEqual(byKey["amt"]?.value, .number(0.5))
        XCTAssertEqual(byKey["mode"]?.value, .string("a"))
    }

    func testSortsByOrderThenKey() {
        let general: [String: Any] = [
            "z": ["type": "bool", "value": false, "order": 0],
            "a": ["type": "bool", "value": false, "order": 1],
        ]
        let props = WallpaperProperties.parse(generalProperties: general)
        XCTAssertEqual(props.map(\.key), ["z", "a"])
    }

    func testPreservesFractionalOrderAndSortsByIt() {
        let general: [String: Any] = [
            "whole": ["type": "bool", "value": false, "order": 1],
            "fraction": ["type": "bool", "value": false, "order": 0.5],
            "none": ["type": "bool", "value": false],
        ]
        let props = WallpaperProperties.parse(generalProperties: general)
        XCTAssertEqual(props.map(\.key), ["fraction", "whole", "none"])
        XCTAssertEqual(props.first { $0.key == "fraction" }?.order, 0.5)
    }

    func testParsesIntegerSliderValuesAsNumbers() {
        let props = WallpaperProperties.parse(generalProperties: [
            "amount": ["type": "slider", "value": 2, "order": 0]
        ])
        XCTAssertEqual(props.first?.value, .number(2))
    }

    func testJSONBooleansAreNotCoercedIntoNumericFields() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WPPropsBoolNumber-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        {"type":"web","general":{"properties":{
          "amount":{"type":"slider","value":true,"order":true,"min":false,"max":true,"step":true,"index":true}
        }}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("project.json"))

        let prop = try XCTUnwrap(WallpaperProperties.parse(folderURL: dir).first)

        XCTAssertEqual(prop.value, .number(0))
        XCTAssertNil(prop.order)
        XCTAssertNil(prop.min)
        XCTAssertNil(prop.max)
        XCTAssertNil(prop.step)
        XCTAssertNil(prop.index)
    }

    // C1: 네이티브 숫자/Bool 값은 기존과 동일하게 파싱돼야 한다(무회귀) — 문자열 관용 폴백을 타지 않음.
    // flagNum(숫자 1)이 bool 로 true 가 되는 것은 NSNumber 의 기존 `as? Bool` 브리징 동작(이 수정과 무관, 불변).
    func testSliderAndBoolNumericValuesUnchanged() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WPPropsNumUnchanged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        {"type":"web","general":{"properties":{
          "amt":{"type":"slider","value":0.5,"order":0},
          "flagTrue":{"type":"bool","value":true,"order":1},
          "flagNum":{"type":"bool","value":1,"order":2}
        }}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("project.json"))
        let props = try WallpaperProperties.parse(folderURL: dir)
        let byKey = Dictionary(uniqueKeysWithValues: props.map { ($0.key, $0) })
        XCTAssertEqual(byKey["amt"]?.value, .number(0.5))
        XCTAssertEqual(byKey["flagTrue"]?.value, .bool(true))
        XCTAssertEqual(byKey["flagNum"]?.value, .bool(true))
    }

    // C1: WE project.json 은 슬라이더/불 값을 문자열로 싣기도 한다("value":"0.5"/"1"/"true") — 수정 전엔
    // parseNumber/`as? Bool` 이 String 을 거부해 0/false 로 붕괴했다.
    func testSliderAndBoolStringEncodedValuesParse() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WPPropsStrEncoded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        {"type":"web","general":{"properties":{
          "amt":{"type":"slider","value":"0.5","order":0},
          "flagOne":{"type":"bool","value":"1","order":1},
          "flagTrue":{"type":"checkbox","value":"true","order":2},
          "flagFalse":{"type":"bool","value":"false","order":3},
          "flagZero":{"type":"bool","value":"0","order":4}
        }}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("project.json"))
        let props = try WallpaperProperties.parse(folderURL: dir)
        let byKey = Dictionary(uniqueKeysWithValues: props.map { ($0.key, $0) })
        XCTAssertEqual(byKey["amt"]?.value, .number(0.5))
        XCTAssertEqual(byKey["flagOne"]?.value, .bool(true))
        XCTAssertEqual(byKey["flagTrue"]?.value, .bool(true))
        XCTAssertEqual(byKey["flagFalse"]?.value, .bool(false))
        XCTAssertEqual(byKey["flagZero"]?.value, .bool(false))
    }

    func testPreservesCorpusPropertyTypes() {
        let general: [String: Any] = [
            "file": ["type": "file", "value": "image.png", "order": 0],
            "dir": ["type": "directory", "value": "/tmp/images", "order": 1, "mode": "fetchall"],
            "tex": ["type": "scenetexture", "value": "user.tex", "order": 2],
            "shortcut": ["type": "usershortcut", "value": "", "order": 3],
            "group": ["type": "group", "text": "Group", "order": 4],
            "label": ["type": "label", "text": "Label", "order": 5],
            "title": ["type": "", "text": "Title", "order": 6],
            "upper": ["type": "Text", "text": "Upper", "order": 7],
        ]
        let props = WallpaperProperties.parse(generalProperties: general)
        let byKey = Dictionary(uniqueKeysWithValues: props.map { ($0.key, $0) })
        XCTAssertEqual(byKey["file"]?.value, .string("image.png"))
        XCTAssertEqual(byKey["dir"]?.value, .string("/tmp/images"))
        XCTAssertEqual(byKey["tex"]?.value, .string("user.tex"))
        XCTAssertEqual(byKey["shortcut"]?.value, .string(""))
        XCTAssertEqual(byKey["group"]?.text, "Group")
        XCTAssertEqual(byKey["label"]?.text, "Label")
        XCTAssertEqual(byKey["title"]?.type, "")
        XCTAssertEqual(byKey["upper"]?.type, "Text")
    }

    func testPreservesResourcePropertyMetadata() {
        let general: [String: Any] = [
            "file": ["type": "file", "value": "image.png", "order": 0, "fileType": "image"],
            "dir": ["type": "directory", "value": "slides", "order": 1, "mode": "fetchall"],
            "tex": ["type": "scenetexture", "value": "custom.png", "order": 2, "index": 4],
        ]
        let props = WallpaperProperties.parse(generalProperties: general)
        let byKey = Dictionary(uniqueKeysWithValues: props.map { ($0.key, $0) })

        XCTAssertEqual(byKey["file"]?.fileType, "image")
        XCTAssertEqual(byKey["dir"]?.mode, "fetchall")
        XCTAssertEqual(byKey["tex"]?.index, 4)
    }

    func testAppliesLocalizationToTextAndOptionLabels() {
        let props = WallpaperProperties.parse(
            generalProperties: [
                "mode": [
                    "type": "combo",
                    "text": "ui_mode",
                    "value": 1,
                    "options": [
                        ["label": "ui_mode_0", "value": 0],
                        ["label": "ui_mode_1", "value": 1],
                    ],
                ]
            ],
            localization: [
                "en-us": [
                    "ui_mode": "Mode",
                    "ui_mode_0": "Off",
                    "ui_mode_1": "On",
                ]
            ],
            localeIdentifier: "en-US"
        )

        XCTAssertEqual(props.first?.text, "Mode")
        XCTAssertEqual(props.first?.options?.map(\.label), ["Off", "On"])
    }

    func testPreservesCondition() {
        let general: [String: Any] = [
            "x": ["type": "bool", "value": true, "condition": "y.value == true"]
        ]
        let props = WallpaperProperties.parse(generalProperties: general)
        XCTAssertEqual(props.first?.condition, "y.value == true")
    }

    func testWEUserPropertiesJSONIsDeterministicAndTyped() {
        let props = [
            WallpaperProperty(key: "bg", type: "color", value: .string("0.6 0.4 0.3"), order: 0, condition: nil),
            WallpaperProperty(key: "x", type: "bool", value: .bool(true), order: 1, condition: nil),
        ]
        let json = WallpaperProperties.weUserPropertiesJSON(props)
        XCTAssertEqual(json, #"{"bg":{"type":"color","value":"0.6 0.4 0.3"},"x":{"type":"bool","value":true}}"#)
    }

    func testWEUserPropertiesJSONNumberAndEmpty() {
        let json = WallpaperProperties.weUserPropertiesJSON([
            WallpaperProperty(key: "amt", type: "slider", value: .number(0.5), order: 0, condition: nil)
        ])
        XCTAssertEqual(json, #"{"amt":{"type":"slider","value":0.5}}"#)
        XCTAssertEqual(WallpaperProperties.weUserPropertiesJSON([]), "{}")
    }

    /// .none 값은 "value" 키 없이 type 만 직렬화돼야 한다(null 을 내보내면 WE 가 오해할 수 있음).
    func testWEUserPropertiesJSONNoneOmitsValueKey() {
        let json = WallpaperProperties.weUserPropertiesJSON([
            WallpaperProperty(key: "x", type: "color", value: .none, order: 0, condition: nil)
        ])
        XCTAssertEqual(json, #"{"x":{"type":"color"}}"#)
    }

    func testParseFolderReadsGeneralProperties() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WPProps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"type":"web","general":{"properties":{"bg":{"type":"color","value":"1 0 0","order":0}}}}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("project.json"))
        let props = try WallpaperProperties.parse(folderURL: dir)
        XCTAssertEqual(props.first?.key, "bg")
        XCTAssertEqual(props.first?.value, .string("1 0 0"))
    }

    // MARK: - schemecolor (docs/re/scheme-color.md)

    /// `schemecolor` 는 WE 가 유일하게 **이름으로 특수 취급**하는 사용자 속성이지만
    /// (`0x1401821F9` → `wallpaper+0x31B0/B4/B8` 전용 float3 슬롯), 그 슬롯의 소비처는
    /// 이미지 전수 스캔에서 **배경 클리어 색 한 곳**뿐이고(`0x14017FC58`·`0x14018033A`),
    /// 그마저 `wallpaper+0x124`(= 브라우저 주입 사용자 속성 `alignment`)가 0/2 가 **아닐 때만**
    /// 쓰인다(`0x14017FC4C` `test dword [rsi+0x124], 0xFFFFFFFD`). `alignment` 는 project.json
    /// 키가 아니고(설치본 191 project.json 중 0건) 생성자·UI 기본값이 둘 다 0(cover)이라
    /// **Waple 에서 그 경로는 도달 불가**다. 그래서 Waple 은 이 키를 특수 처리하지 **않고**
    /// 제네릭 사용자 속성으로만 통과시킨다 — 아래 네 테스트가 그 결정을 잠근다.
    ///
    /// 값은 8비트 sRGB 헥스를 그냥 255 로 나눈 **0–1 3성분 문자열**이다(UI 의
    /// `convertHexToVec3 = e.r/255+" "+e.g/255+" "+e.b/255`). 감마 변환도 0–255 유지도 없으므로
    /// **원문 그대로 보존**하는 것이 원본 동작이다.
    func testSchemeColorStaysAPlainUserProperty() {
        // 동봉 WEAssets 161건이 전건 이 형태다(값도 전건 "0 0 0").
        let props = WallpaperProperties.parse(generalProperties: [
            "schemecolor": ["order": 0, "text": "ui_browse_properties_scheme_color",
                            "type": "color", "value": "0 0 0"],
            "other": ["type": "bool", "value": true, "order": 1],
        ])
        // 필터링되지 않는다 — 두 속성 모두 나온다.
        XCTAssertEqual(props.map(\.key), ["schemecolor", "other"])
        let scheme = props[0]
        XCTAssertEqual(scheme.type, "color")
        XCTAssertEqual(scheme.value, .string("0 0 0"))   // 원문 보존: Vec3 로 접히지 않는다
        XCTAssertEqual(scheme.text, "ui_browse_properties_scheme_color")
        XCTAssertEqual(scheme.order, 0)
    }

    /// 설치본 `projects/defaultprojects/` 실측 비영값(16건 중 대표 5건)이 **바이트 그대로** 남아야
    /// 한다. 255 곱하기·나누기나 sRGB↔선형 변환을 끼워 넣으면 여기서 깨진다.
    func testSchemeColorNonBlackValuesSurviveVerbatim() {
        let measured = [
            "1 0 0",                                     // demon_core
            "0.8 0.4 0.05",                              // shimmering_particles
            "0.72 0.64 0.42",                            // retro
            "0.075 0.125 0.180",                         // razer_vortex — 후행 0 도 보존
            "0.2823529411764706 0.5019607843137255 0.09411764705882353",  // dino_run
        ]
        for raw in measured {
            let props = WallpaperProperties.parse(generalProperties: [
                "schemecolor": ["type": "color", "value": raw]
            ])
            XCTAssertEqual(props.first?.value, .string(raw), "schemecolor 값이 변형됐다: \(raw)")
        }
    }

    /// `weUserPropertiesJSON` 이 `schemecolor` 를 빼먹으면 두 가지가 동시에 깨진다:
    /// material `passes[].usershadervalues.schemecolor`(설치본 29건 · 동봉 1건
    /// `materials/util/fade.json` → 셰이더 `material` 토큰 `"tint"`) 바인딩과, 씬 스크립트의
    /// 사용자 속성 조회. 그래서 **제네릭 통과가 곧 계약**이다.
    func testSchemeColorIsCarriedIntoWEUserPropertiesJSON() {
        let props = WallpaperProperties.parse(generalProperties: [
            "schemecolor": ["type": "color", "value": "1 0 0", "order": 0]
        ])
        XCTAssertEqual(WallpaperProperties.weUserPropertiesJSON(props),
                       #"{"schemecolor":{"type":"color","value":"1 0 0"}}"#)
    }

    /// 무회귀 — `schemecolor` 가 없는 프로젝트의 파스는 한 값도 달라지지 않는다.
    func testProjectWithoutSchemeColorIsUnaffected() {
        let general: [String: Any] = [
            "bg":   ["type": "color",  "value": "0.6 0.4 0.3", "order": 0],
            "amt":  ["type": "slider", "value": 0.5,           "order": 1],
            "flag": ["type": "bool",   "value": true,          "order": 2],
        ]
        let props = WallpaperProperties.parse(generalProperties: general)
        XCTAssertEqual(props.map(\.key), ["bg", "amt", "flag"])
        XCTAssertEqual(props.map(\.value), [.string("0.6 0.4 0.3"), .number(0.5), .bool(true)])
        XCTAssertEqual(WallpaperProperties.weUserPropertiesJSON(props),
                       #"{"amt":{"type":"slider","value":0.5},"bg":{"type":"color","value":"0.6 0.4 0.3"},"flag":{"type":"bool","value":true}}"#)
    }
}
