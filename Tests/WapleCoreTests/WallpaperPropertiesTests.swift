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
