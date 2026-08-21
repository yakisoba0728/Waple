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

    // MARK: - AngularJS 1.6.10 문법과 갈리는 자리 (전부 실물 코퍼스 도달 0)
    //
    // 문법의 정체와 우선순위 사슬은 실물에서 직접 떴다 — `ui/dist/scripts/vendor.js`
    // (`full:"1.6.10"` @byte 98389)의 재귀하강 파서 @byte 167616 이하:
    //   logicalOR → logicalAND → **equality**(@167616) → **relational**(@167789)
    //             → additive(@167960) → multiplicative(@168124) → unary(@168262) → primary
    // UI 가 그 파서를 `$eval` 로 부른다(`scripts.js` @byte 106657 · 375400 · 613938).
    //
    // 아래 셋은 "지금 이렇게 동작한다" 를 못박는 것이지 "이게 옳다" 가 아니다.
    // 문법을 Angular 에 맞추면 이 테스트들이 깨져야 한다 — 그때 **의도적으로** 갱신해라.

    /// §1 — equality/relational 이 한 레벨이고 반복하지 않는다.
    /// Angular 는 `a == b == c` 를 `(a==b)==c` 로 읽는다. 여기서는 남은 토큰 때문에
    /// `isAtEnd` 가 거짓이 되어 **파스 실패(nil)** 다 → `isVisible` 은 관용적으로 표시한다.
    /// 실물 조건 22건에 비교 연산자 연쇄는 0건이다(전부 `&&` 로만 이어진다).
    func testComparisonChainsAreParseFailuresNotAngularLeftAssociation() {
        let values: [String: PropertyValue] = ["a": .number(1), "b": .number(1), "c": .bool(true)]
        for chain in ["a.value == b.value == c.value",
                      "a.value > b.value == c.value",
                      "a.value == b.value > b.value"] {
            XCTAssertNil(PropertyConditionEvaluator.evaluate(chain, values: values),
                         "\(chain): 연쇄는 파스 실패로 흘린다(Angular 는 좌결합 반복)")
            XCTAssertFalse(PropertyConditionEvaluator.canEvaluate(chain),
                           "\(chain): 분석기가 '평가 불가' 경고를 내야 한다")
        }
        // 실패 방향은 "숨김" 이 아니라 "표시" 다 — 조건을 못 읽어도 토글이 사라지지 않는다.
        let prop = WallpaperProperty(key: "x", type: "bool", value: .bool(true), order: 0,
                                     condition: "a.value == b.value == c.value")
        XCTAssertTrue(PropertyConditionEvaluator.isVisible(prop, in: [prop]))
    }

    /// §2 — 산술 연산자(`+ - * / %`)와 단항 부호가 없다. 토크나이저가 미지 연산자를 만나면
    /// 부분 평가 대신 전체를 파스 실패로 흘린다. 실물 코퍼스 도달 0.
    func testArithmeticOperatorsAreParseFailures() {
        let values: [String: PropertyValue] = ["a": .number(3), "b": .number(4)]
        for expr in ["a.value + b.value > 5", "a.value * 2 == 6", "a.value % 2 == 1"] {
            XCTAssertNil(PropertyConditionEvaluator.evaluate(expr, values: values), expr)
        }
    }

    /// §3 — `==` 와 `===` 를 구분하지 않는다. `equals()` 가 먼저 수치화하므로
    /// `'1' === 1` 이 **true**(JS/Angular 는 strict 라 false)이고, 거꾸로 `'' == 0` 은
    /// JS 가 true 인데 여기서는 `Double("")` 이 nil 이라 false 다.
    /// 실물 `===`/`!==` 12건은 전건 "문자열 vs 문자열 리터럴" 또는 "bool vs bool" 이라 도달 0.
    func testStrictAndLooseEqualityAreNotDistinguished() {
        let values: [String: PropertyValue] = ["s": .string("1"), "e": .string("")]
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("s.value === 1", values: values), true,
                       "JS 라면 false — 수치화 후 비교라 true 다")
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("s.value == 1", values: values), true,
                       "느슨한 쪽은 JS 와 같은 답")
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("e.value == 0", values: values), false,
                       "JS 라면 true — `Double(\"\")` 이 nil 이라 false 다")
        // 코퍼스가 실제로 쓰는 모양(문자열 vs 문자열 리터럴)은 두 규약이 같은 답을 낸다.
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("s.value === '1'", values: values), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("s.value !== '2'", values: values), true)
    }

    /// `!` 는 Angular 와 **같이** 비교보다 강하게 묶인다(`unary` 레벨 @vendor.js byte 168262 —
    /// `unary → ("+"|"-"|"!") unary | primary`). 여기가 갈리지 **않는다**는 것을 못박는다.
    ///
    /// `n = 2` 가 두 묶음을 가르는 조합이다:
    /// `(!2) == 1` → `false == 1` → 0 == 1 → **false** / `!(2 == 1)` → `!false` → **true**.
    func testUnaryNotBindsTighterThanComparisonLikeAngular() {
        let values: [String: PropertyValue] = ["n": .number(2)]
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("!n.value == 1", values: values), false,
                       "(!2) == 1 — `!(2 == 1)` 로 묶였다면 true 였다")
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("!(n.value == 1)", values: values), true,
                       "괄호로 묶으면 반대")
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("!!n.value", values: values), true,
                       "단항은 자기재귀 — Angular 도 `unary → … unary`")
    }
}
