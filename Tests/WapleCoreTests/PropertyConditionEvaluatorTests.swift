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

    // MARK: - 문자열 메서드 조건 (실물 corsair_collection/project.json — 조건 22건 중 9건)

    /// `condition` 은 AngularJS `$eval` 표현식이라 `String.prototype` 메서드가 그대로 성립한다
    /// (`scripts.js` 의 `evalCondition(e) { return scope.$eval(e, properties) }`).
    /// 종전에는 `effect.value.endsWith` 가 통째 식별자로 토큰화되고 남은 `('pulse')` 때문에
    /// 파스 실패 → 조건 무시(항상 표시)였다.
    func testEvaluatesStringMethodConditionsFromRealCorpus() {
        let values: [String: PropertyValue] = [
            "effect": .string("rainbowpulse"),
            "pulseanimation": .string("static"),
            "scene": .string("ram"),
        ]
        XCTAssertEqual(PropertyConditionEvaluator.evaluate(
            "effect.value.endsWith('pulse') === true", values: values), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate(
            "effect.value.startsWith('rainbow') === false", values: values), false)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate(
            "effect.value.endsWith('pulse') === true && pulseanimation.value === 'static'",
            values: values), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate(
            "effect.value.endsWith('pulse') === true && pulseanimation.value !== 'static'",
            values: values), false)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate(
            "effect.value.endsWith('spiral') === true && scene.value === 'ram'", values: values), false)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate(
            "effect.value.includes('bowpul')", values: values), true)
        // 문법이 인식되므로 analyzer 경고(propertyDisplayCondition)도 더는 나가지 않는다.
        XCTAssertTrue(PropertyConditionEvaluator.canEvaluate("effect.value.endsWith('pulse') === true"))
    }

    /// 좌변이 문자열이 아니면 손대지 않는다 — JS 에서도 숫자·불리언에는 그 메서드가 없다.
    func testStringMethodOnNonStringLeavesConditionUnevaluable() {
        let values: [String: PropertyValue] = ["n": .number(12), "b": .bool(true)]
        XCTAssertNil(PropertyConditionEvaluator.evaluate("n.value.startsWith('1')", values: values))
        XCTAssertNil(PropertyConditionEvaluator.evaluate("b.value.endsWith('e')", values: values))
    }

    /// 배열 리터럴 `[a,b].includes(x)` 경로(종전 기능)와 충돌하지 않는다 — 식별자 형태만 잡는다.
    func testArrayIncludesStillTakesTheArrayPath() {
        let values: [String: PropertyValue] = ["n": .number(12), "s": .string("abc")]
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("[10, 11, 12].includes(n.value)", values: values), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate(
            "[10, 11].includes(n.value) || s.value.startsWith('ab')", values: values), true)
    }

    /// 실물 코퍼스에 있는 나머지 형태들(맨 숫자 리터럴 · 빈 문자열 · 문자열 비교).
    func testEvaluatesRemainingRealCorpusConditionShapes() {
        let values: [String: PropertyValue] = [
            "style": .string("1"), "showbottom": .number(2), "rainbowscheme": .bool(false),
            "scene": .string("cartoon"),
        ]
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("1", values: values), true, "맨 숫자 리터럴")
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("0", values: values), false)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("style.value=='1'", values: values), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("showbottom.value > 0", values: values), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("rainbowscheme.value", values: values), false)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate(
            "scene.value !== 'cartoon' && scene.value !== 'ram'", values: values), false)
    }
}
