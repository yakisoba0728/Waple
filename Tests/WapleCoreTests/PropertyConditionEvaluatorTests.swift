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
    // 아래 둘(§2·§3)은 "지금 이렇게 동작한다" 를 못박는 것이지 "이게 옳다" 가 아니다.
    // 문법을 Angular 에 맞추면 그 테스트들이 깨져야 한다 — 그때 **의도적으로** 갱신해라.
    // §1(비교 연산자 레벨·결합)은 2026-08-21 클러스터 Q 에서 **닫았다** — 아래는 그 반대 방향,
    // 즉 "Angular 와 같아졌다" 를 못박는 테스트다.

    /// §1(닫힘) — `equality`(@vendor.js byte 167616)와 `relational`(@167789)이 **두 레벨**이고
    /// 각각 **좌결합 반복**이다. 종전 Waple 은 여덟 연산자를 한 레벨로 묶고 한 번만 소비해
    /// 연쇄를 전부 파스 실패(nil)로 흘렸다.
    ///
    /// 세 형태의 Angular 해석과 여기 결과가 일치해야 한다(a=1 · b=1 · c=true):
    ///   `a == b == c` → `(1==1)==true` → **true**
    ///   `a > b == c`  → `(1>1)==true`  → **false**
    ///   `a == b > b`  → `1==(1>1)`     → **false**
    /// 실물 조건 22건 / 고유 16종에 비교 연산자 연쇄는 **0건**이라(전부 `&&` 로만 이어진다)
    /// 이 확장은 설치본 코퍼스 위에서 `canEvaluate`·`evaluate` 를 한 건도 움직이지 않는다.
    func testComparisonChainsFollowAngularTwoLevelLeftAssociation() {
        let values: [String: PropertyValue] = ["a": .number(1), "b": .number(1), "c": .bool(true)]
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("a.value == b.value == c.value", values: values),
                       true, "(a==b)==c — equality 는 좌결합 반복")
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("a.value > b.value == c.value", values: values),
                       false, "(a>b)==c — relational 이 equality 보다 강하게 묶인다")
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("a.value == b.value > b.value", values: values),
                       false, "a==(b>b) — 우변도 relational 레벨로 내려간다")
        for chain in ["a.value == b.value == c.value",
                      "a.value > b.value == c.value",
                      "a.value == b.value > b.value"] {
            XCTAssertTrue(PropertyConditionEvaluator.canEvaluate(chain),
                          "\(chain): 이제 문법이 인식되므로 분석기 경고가 나가지 않는다")
        }
        // **좌결합**이지 우결합이 아니다 — 이 값에서만 둘이 갈린다.
        // 좌: `(1==2)==0` → `false==0` → true · 우: `1==(2==0)` → `1==false` → false.
        let discriminator: [String: PropertyValue] = ["a": .number(1), "b": .number(2), "c": .number(0)]
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("a.value == b.value == c.value",
                                                           values: discriminator),
                       true, "좌결합이면 true — 우결합이면 false 가 나온다")
        // 연쇄가 아닌 식은 종전 그대로다(단조 확대 — 회귀 없음).
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("a.value == b.value", values: values), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("a.value > b.value", values: values), false)
        XCTAssertNil(PropertyConditionEvaluator.evaluate("a.value ==", values: values), "미완성은 여전히 실패")
        // 표시 판정까지 이어진다.
        let props = [
            WallpaperProperty(key: "a", type: "slider", value: .number(1), order: 0, condition: nil),
            WallpaperProperty(key: "b", type: "slider", value: .number(1), order: 1, condition: nil),
            WallpaperProperty(key: "c", type: "bool", value: .bool(true), order: 2, condition: nil),
            WallpaperProperty(key: "x", type: "bool", value: .bool(true), order: 3,
                              condition: "a.value == b.value == c.value"),
            WallpaperProperty(key: "y", type: "bool", value: .bool(true), order: 4,
                              condition: "a.value > b.value == c.value"),
        ]
        XCTAssertEqual(PropertyConditionEvaluator.visibleIndices(in: props), [0, 1, 2, 3],
                       "x 는 (a==b)==c = true 라 표시, y 는 (a>b)==c = false 라 숨김")
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

    // MARK: - 설치본 실물 조건 전수 (2026-08-21 클러스터 AF)

    /// WE 설치본 `projects/**/project.json` 의 `general.properties.*.condition` **17건 전수**를
    /// 그 파일의 **실제 기본값** 위에서 평가한다. 고유 11종(빈 문자열 1 포함)이고
    /// 네 파일에서 나온다: `corsair_collection` 13 · `corsair_o_tron` 2 · `dino_run` 1 ·
    /// `shimmering_particles` 1.
    ///
    /// **종전 문서가 적은 "22건 / 고유 16종" 은 두 개의 다른 키를 합산한 수였다.** 나머지 5건은
    /// `shimmering_particles/scene.json` 의 `/objects/N/visible/user/condition`(값 `"0"`×1 ·
    /// `"1"`×4)인데, 그건 **AngularJS 식이 아니라 콤보 값 동등비교**다 — 파스 자리도 다르고
    /// (`wallpaper64.exe` 0x1401a4f1b `Json::Value::find("condition")`, `user` 객체 안)
    /// 소비처도 다르다(`SceneDocument.resolveUserBindings`). 에디터 라벨이
    /// `ui_editor_user_properties_combo_value` = *"Selected combo value for this link:"* 이고
    /// 후보가 그 콤보의 `options[].value` 드롭리스트로 제한된다(scripts.js char@621236/@621718).
    /// 이 평가기는 그 문법을 **다루지 않아야 맞다**.
    func testInstalledProjectConditionCorpusEvaluatesAsAuthored() {
        // corsair_collection — 기본값 effect="rainbowpulse" · scene="circuit" · pulseanimation="random".
        let corsair: [String: PropertyValue] = [
            "effect": .string("rainbowpulse"), "scene": .string("circuit"),
            "pulseanimation": .string("random"),
        ]
        let corsairCases: [(String, Bool)] = [
            ("scene.value !== 'cartoon' && scene.value !== 'ram'", true),               // logo/logox/logoy ×3
            ("effect.value.startsWith('rainbow') === false", false),                    // maincolor/secondarycolor ×2
            ("effect.value.endsWith('pulse') === true", true),                          // pulseanimation
            ("effect.value.endsWith('pulse') === true && pulseanimation.value !== 'static'", true),   // pulsescale
            ("effect.value.endsWith('pulse') === true && pulseanimation.value === 'static'", false),  // pulsesize
            ("effect.value.endsWith('spiral') === true", false),                        // spiraldirection
            ("effect.value.endsWith('spiral') === true && scene.value !== 'ram'", false),      // spiralposition
            ("effect.value.endsWith('spiral') === true && scene.value === 'ram'", false),      // spiralpositionram
            ("effect.value === 'visor'", false),                                        // visordirection
            ("effect.value.endsWith('wave') === true", false),                          // wavedirection
        ]
        for (expr, want) in corsairCases {
            XCTAssertEqual(PropertyConditionEvaluator.evaluate(expr, values: corsair), want, expr)
            XCTAssertTrue(PropertyConditionEvaluator.canEvaluate(expr), "문법 미지원이면 안 된다: \(expr)")
        }

        // corsair_o_tron — `showbottom` 은 **슬라이더인데 값이 문자열 "150"** 이다(실물 그대로).
        // `WallpaperProperties.parse` 가 lenient 경로로 .number(150) 을 만든다 — JS 의
        // `"150" > 0` (ToNumber) 과 같은 답이다.
        let oTron = WallpaperProperties.parse(generalProperties: [
            "showbottom": ["type": "slider", "value": "150", "min": 0, "max": 300],
            "rainbowscheme": ["type": "bool", "value": false],
            "bottomcolor": ["type": "color", "value": "1 1 1", "condition": "showbottom.value > 0"],
            "cyclerainbow": ["type": "bool", "value": true, "condition": "rainbowscheme.value"],
        ])
        let byKey = Dictionary(uniqueKeysWithValues: oTron.map { ($0.key, $0) })
        XCTAssertEqual(byKey["showbottom"]?.value, .number(150), "슬라이더 문자열 값 관용")
        let visibleKeys = Set(PropertyConditionEvaluator.visibleIndices(in: oTron).map { oTron[$0].key })
        XCTAssertTrue(visibleKeys.contains("bottomcolor"), "showbottom 150 > 0 → 표시")
        XCTAssertFalse(visibleKeys.contains("cyclerainbow"), "rainbowscheme 기본값 false → 숨김")

        // dino_run — `"condition": ""`. 브라우저 템플릿은 `ng-if="!property.condition || …"` 라
        // 빈 문자열이 falsy → **조건 자체가 없는 것과 같다**(scripts.js char@750308).
        XCTAssertTrue(PropertyConditionEvaluator.isVisible(
            WallpaperProperty(key: "god_rays", type: "bool", value: .bool(true), order: 0, condition: ""),
            in: []))

        // shimmering_particles — style 콤보 기본값 "0".
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("style.value=='1'",
                                                           values: ["style": .string("0")]), false)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("style.value=='1'",
                                                           values: ["style": .string("1")]), true)
    }

    /// **엔진이 직접 저작하는 조건**도 코퍼스다. `wallpaper64.exe` 의 프로퍼티 주입기
    /// `0x140104b60–0x140108c17` 이 브라우저 패널에 얹는 내장 프로퍼티(volume · rate ·
    /// cameraparallax · alignment · alignment{position,x,y,z} · alignmentfliph · wcc_v · wcc_amt ·
    /// wec_e · wec_{brs,con,sa,hue})에 `condition` 을 **10자리**에서 쓴다(고유 5종).
    /// 이미지 전체 disp32 스캔으로 `"condition"`(0x140474a60) xref **16자리** 중 10 이 이 함수다
    /// **[2026-08-21 정정]** 이 절의 주소 넷은 종전 `0x14001f39b`·`0x140134c81`·`0x14015cc13`·  [VA-정정]
    /// `0x14015cd74` 였다 — 전부 xref 스캔이 준 `disp32` 위치(명령보다 3바이트 뒤)다.  [VA-정정]
    /// (나머지: 씬 `user` 바인딩 파서 0x1401a4f1b · 0x14017512c · TEXB 변형 0x14015cc10/0x14015cd71 ·
    ///  0x14001f398 · 0x140134c7e). **이 바이너리 어디에도 이 식을 평가하는 자리는 없다** —
    /// `checkPositionVisibility()` 는 브라우저 스코프 함수이기 때문이다(scripts.js char@106119).
    ///
    /// 그래서 이 다섯은 우리 파서가 **닿을 일이 없다**(project.json 도달 0). 다만 문법 커버리지의
    /// 상한을 보여준다: `<` · `&&` · `||` · `==` 는 되고 **함수 호출은 안 된다**.
    func testEngineInjectedConditionsShowGrammarCeiling() {
        let v: [String: PropertyValue] = ["alignment": .number(4), "wcc_v": .string("none"), "wec_e": .bool(true)]
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("alignment.value==3||alignment.value==4", values: v), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("alignment.value==4", values: v), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("wcc_v.value", values: v), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("wec_e.value", values: v), true)
        // 함수 호출은 미지원 — 부분 평가 대신 **전체 파스 실패**로 흘러 관용적으로 표시된다.
        let call = "alignment.value<2&&checkPositionVisibility()"
        XCTAssertNil(PropertyConditionEvaluator.evaluate(call, values: v),
                     "함수 호출 토큰이 남아 isAtEnd 가 거짓 → 파스 실패")
        XCTAssertFalse(PropertyConditionEvaluator.canEvaluate(call))
        XCTAssertTrue(PropertyConditionEvaluator.isVisible(
            WallpaperProperty(key: "alignmentposition", type: "slider", value: .number(0),
                              order: 0, condition: call),
            in: []), "파스 실패는 표시로 폴백")
    }

    /// **없는 프로퍼티 참조는 `undefined` 이고 falsy 다** — 그리고 우리 규약과 일치한다.
    /// 브라우저는 `ta.$eval(expr, currentSelection.properties[location])` 로 평가한다
    /// (scripts.js char@106464) — 즉 **locals = 프로퍼티 맵**이다. AngularJS 1.6 의 컴파일된
    /// 게터는 멤버 접근이 null-safe 라(`a === undefined ? undefined : a.value`) 없는 키를
    /// 던지지 않고 `undefined` 를 낸다. 그래서:
    ///   `missing.value` → undefined(falsy) · `== 'x'` → false · `> 0` → false ·
    ///   `!missing.value` → true · `missing.value == other.value`(둘 다 부재) → true.
    /// 우리 `ConditionValue.none` 이 정확히 이 다섯을 낸다.
    func testMissingPropertyReferenceIsUndefinedLikeAngular() {
        let v: [String: PropertyValue] = ["known": .number(1)]
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("missing.value", values: v), false)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("missing.value == 'x'", values: v), false)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("missing.value > 0", values: v), false)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("missing.value < 0", values: v), false,
                       "JS 도 undefined 비교는 양방향 false 다(NaN)")
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("!missing.value", values: v), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("missing.value == alsoMissing.value", values: v), true,
                       "undefined == undefined → true")
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("known.value && missing.value", values: v), false)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("known.value || missing.value", values: v), true)
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
