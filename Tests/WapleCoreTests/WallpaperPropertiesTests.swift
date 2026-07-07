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
}
