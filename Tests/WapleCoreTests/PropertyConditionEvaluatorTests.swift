import XCTest
@testable import WapleCore

final class PropertyConditionEvaluatorTests: XCTestCase {
    // S5: `Parser.parsePrimary` 는 괄호와 `!` 양쪽으로 자기재귀한다 — 병리적 중첩(조건 문자열은
    // 유저가 아니라 project.json 작성자가 채우므로 사실상 신뢰 불가 입력)이 스택 오버플로 없이
    // 그레이스풀 nil(기존 파스실패 경로)로 떨어져야 한다. 5000 은 캡(256) 을 한참 초과.
    func testDeepNestingDoesNotCrash() {
        let deepParen = String(repeating: "(", count: 5000) + "true" + String(repeating: ")", count: 5000)
        XCTAssertNil(PropertyConditionEvaluator.evaluate(deepParen, values: [:]))
        let deepBang = String(repeating: "!", count: 5000) + "false"
        XCTAssertNil(PropertyConditionEvaluator.evaluate(deepBang, values: [:]))
    }

    // S5: 정상 규모 중첩(≪ 256)은 캡의 영향을 받지 않고 그대로 평가돼야 한다(무회귀).
    func testModerateNestingStillEvaluatesCorrectly() {
        let normal = String(repeating: "(", count: 10) + "true" + String(repeating: ")", count: 10)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate(normal, values: [:]), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("!!!!!false", values: [:]), true)   // 홀수 개 부정
    }

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
