import XCTest
@testable import WapleCore

final class PropertyConditionEvaluatorTests: XCTestCase {
    func testEvaluatesWallpaperEngineStyleConditions() {
        let values: [String: PropertyValue] = [
            "enabled": .bool(true),
            "mode": .number(3),
            "theme": .string("custom"),
            "empty": .string("")
        ]

        XCTAssertEqual(PropertyConditionEvaluator.evaluate("enabled.value == true", values: values), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("enabled.value && mode.value == 3", values: values), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("theme.value === \"custom\"", values: values), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("(empty.value == '' || mode.value >= 3) && enabled.value;", values: values), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("mode.value > 5 || enabled.value == false", values: values), false)
    }

    func testVisibleIndicesHideFalseConditionsAndFallbackVisibleForInvalidSyntax() {
        let props = [
            WallpaperProperty(key: "enabled", type: "bool", value: .bool(false), order: 0, condition: nil),
            WallpaperProperty(key: "hidden", type: "slider", value: .number(1), order: 1, condition: "enabled.value == true"),
            WallpaperProperty(key: "shown", type: "slider", value: .number(1), order: 2, condition: "enabled.value == false"),
            WallpaperProperty(key: "fallback", type: "slider", value: .number(1), order: 3, condition: "enabled.value =="),
        ]

        XCTAssertEqual(PropertyConditionEvaluator.visibleIndices(in: props), [0, 2, 3])
        XCTAssertTrue(PropertyConditionEvaluator.canEvaluate("enabled.value == true"))
        XCTAssertFalse(PropertyConditionEvaluator.canEvaluate("enabled.value =="))
    }

    func testEvaluatesCorpusConditionExtensions() {
        let values: [String: PropertyValue] = [
            "kg": .bool(true),
            "party": .bool(false),
            "background_type": .number(2),
            "newproperty16": .number(12),
            "background_enable": .bool(true),
            "background_effect": .bool(false),
        ]

        XCTAssertEqual(PropertyConditionEvaluator.evaluate("kg.value == true && [10, 11, 12,].includes(newproperty16.value)", values: values), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("kg.value == true && [1, 2, 3].includes(newproperty16.value)", values: values), false)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("custombool.value == false && !party.value", values: values), false)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("background_enable.value && !(background_type.value == 1)", values: values), true)
        XCTAssertEqual(
            PropertyConditionEvaluator.evaluate("background_enable.value && !(background_type.value == 1) ? background_effect.value ? background_effect.text = 'x' : background_effect.text = 'y' : false", values: values),
            true
        )
    }
}
