import XCTest
@testable import WapleCore

final class ShaderPreprocessorTests: XCTestCase {
    // S5: `#if ((((…))))` 류 병리적 중첩이 재귀 파서를 스택 오버플로시키면 안 된다 — 캡(256) 초과는
    // 그레이스풀 0(미정의 취급)으로 폴백. 5000 중첩은 캡을 한참 넘어 안쪽 리터럴에 닿지 못하므로 0 이 맞다.
    func testExprEvalDeepNestingDoesNotCrash() {
        let deep = String(repeating: "(", count: 5000) + "1" + String(repeating: ")", count: 5000)
        XCTAssertEqual(ExprEval.eval(deep, defines: [:]), 0)   // 캡 초과 — 안쪽 리터럴 미도달, 그레이스풀 0
        // `!` 체인은 캡 경계에서 홀/짝 반전이 섞여 정확한 값은 구현 세부(오프바이원)에 민감 —
        // 여기선 "크래시 없이 반환"만 증명(값은 불문).
        let deepBang = String(repeating: "!", count: 5000) + "0"
        _ = ExprEval.eval(deepBang, defines: [:])
    }

    // S5: 정상 규모 중첩(≪ 256)은 캡의 영향을 받지 않고 그대로 평가돼야 한다(무회귀).
    func testExprEvalNormalNestingStillEvaluatesCorrectly() {
        let normal = String(repeating: "(", count: 10) + "1 + 2" + String(repeating: ")", count: 10)
        XCTAssertEqual(ExprEval.eval(normal, defines: [:]), 3)
        XCTAssertEqual(ExprEval.eval("((A))", defines: ["A": 5]), 5)
        XCTAssertEqual(ExprEval.eval("!!!!!0", defines: [:]), 1)   // 홀수 개 부정 — 0(거짓)의 반전은 1
    }

    // S5: 전체 파이프라인(`#if` → ExprEval) 레벨에서도 병리적 중첩이 크래시하지 않는다(티켓 예시 그대로).
    func testPreprocessDeepNestedIfDoesNotCrash() {
        let deep = "#if " + String(repeating: "(", count: 5000) + "1" + String(repeating: ")", count: 5000)
            + "\nyes\n#endif"
        let out = ShaderPreprocessor.preprocess(deep, combos: [:])
        XCTAssertFalse(out.contains("yes"), "캡 초과로 안쪽 리터럴 미도달 → 조건 거짓")
    }

    // T-B7: 악성 `#if` 리터럴의 오버플로가 트랩(크래시)하면 안 된다 — 랩 값이면 충분(분기 결정만 하면 됨).
    func testExprEvalOverflowDoesNotTrap() {
        XCTAssertEqual(ExprEval.eval("9223372036854775807 + 1", defines: [:]), Int.min)     // &+ 랩
        XCTAssertEqual(ExprEval.eval("9223372036854775807 * 2", defines: [:]), -2)          // &* 랩
        XCTAssertEqual(ExprEval.eval("0 - 9223372036854775807 - 2", defines: [:]), Int.max) // &- 랩
        XCTAssertEqual(ExprEval.eval("1 / 0", defines: [:]), 0)                             // 0 나눗셈 가드(기존)
        XCTAssertEqual(ExprEval.eval("A / -1", defines: ["A": Int.min]), 0)                 // Int.min / -1 가드
        XCTAssertEqual(ExprEval.eval("-A", defines: ["A": Int.min]), Int.min)               // 단항 랩
    }

    // T-B2: 지시문 줄의 트레일링 블록 주석이 ExprEval 에 `/`·`*` 로 새면 오평가된다.
    func testDirectiveTrailingBlockComment() {
        let src = "#if AUDIO /* mic */\nyes\n#else\nno\n#endif"
        let on = ShaderPreprocessor.preprocess(src, combos: ["AUDIO": 1])
        XCTAssertTrue(on.contains("yes"), on)
        XCTAssertFalse(on.contains("no"), on)
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["AUDIO": 0]).contains("no"))
    }

    func testIfElseEndifTakesActiveBranch() {
        let src = """
        a
        #if MASK
        masked
        #else
        unmasked
        #endif
        b
        """
        func lines(_ s: String) -> [String] { s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } }
        let off = lines(ShaderPreprocessor.preprocess(src, combos: ["MASK": 0]))
        XCTAssertTrue(off.contains("unmasked")); XCTAssertFalse(off.contains("masked"))
        let on = lines(ShaderPreprocessor.preprocess(src, combos: ["MASK": 1]))
        XCTAssertTrue(on.contains("masked")); XCTAssertFalse(on.contains("unmasked"))
        XCTAssertTrue(off.contains("a") && off.contains("b"))
    }

    func testComboDefaultUsedWhenUnspecified() {
        let src = """
        // [COMBO] {"material":"x","combo":"PERSPECTIVE","default":0}
        #if PERSPECTIVE == 1
        persp
        #else
        flat
        #endif
        """
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: [:]).contains("flat"))
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["PERSPECTIVE": 1]).contains("persp"))
    }

    func testEqualityAndLogicalExpr() {
        let src = "#if A == 2 && B\nyes\n#else\nno\n#endif"
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["A": 2, "B": 1]).contains("yes"))
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["A": 2, "B": 0]).contains("no"))
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["A": 3, "B": 1]).contains("no"))
    }

    func testDefinedOperatorInIfExpression() {
        let src = "#if defined(A) || defined B\nyes\n#else\nno\n#endif"
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["A": 1]).contains("yes"))
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["B": 1]).contains("yes"))
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: [:]).contains("no"))
    }

    func testNestedConditionals() {
        let src = "#if A\n#if B\nAB\n#endif\nAonly\n#endif\nbase"
        let r = ShaderPreprocessor.preprocess(src, combos: ["A": 1, "B": 0])
        XCTAssertTrue(r.contains("Aonly")); XCTAssertFalse(r.contains("AB")); XCTAssertTrue(r.contains("base"))
        let r2 = ShaderPreprocessor.preprocess(src, combos: ["A": 0, "B": 1])
        XCTAssertFalse(r2.contains("Aonly")); XCTAssertFalse(r2.contains("AB")); XCTAssertTrue(r2.contains("base"))
    }

    func testIncludeInlined() {
        let src = "#include \"common.h\"\nmain"
        let r = ShaderPreprocessor.preprocess(src, combos: [:]) { name in name == "common.h" ? "HEADER_BODY" : nil }
        XCTAssertTrue(r.contains("HEADER_BODY")); XCTAssertTrue(r.contains("main"))
        XCTAssertFalse(r.contains("#include"))
    }

    func testElifChain() {
        let src = "#if A == 1\none\n#elif A == 2\ntwo\n#else\nother\n#endif"
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["A": 2]).contains("two"))
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["A": 1]).contains("one"))
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["A": 9]).contains("other"))
    }

    func testNonIntegerDefineSubstitutedInBody() {
        let src = """
        #define AMOUNT 0.5
        #define OFFSET vec2(0.1, 0.2)
        float x = AMOUNT;
        vec2 o = OFFSET;
        float y = AMOUNTX;
        """
        let r = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertFalse(r.contains("#define"))
        XCTAssertTrue(r.contains("float x = 0.5;"), r)
        XCTAssertTrue(r.contains("vec2 o = vec2(0.1, 0.2);"), r)
        XCTAssertTrue(r.contains("float y = AMOUNTX;"), "whole-word only: \(r)")
    }

    func testNegativeNumericDefineDoesNotFuseWithMinusOperator() {
        // wallpaper_dev: `x-MACRO` with `#define MACRO -1.3` became `x--1.3`, which MSL parses as `--`.
        let src = """
        #define OFFSET -1.3
        float x = uv.x-OFFSET;
        """
        let r = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(r.contains("float x = uv.x-(-1.3);"), r)
        XCTAssertFalse(r.contains("--1.3"), r)
    }

    func testIntegerDefineAndComboSubstitutedInBody() {
        let src = "#define MODE 2\n#if MODE == 2\nyes\n#endif\nint m = MODE;\nint k = MASK;"
        let r = ShaderPreprocessor.preprocess(src, combos: ["MASK": 1])
        XCTAssertTrue(r.contains("yes"))
        XCTAssertTrue(r.contains("int m = 2;"), r)
        XCTAssertTrue(r.contains("int k = 1;"), "combos are macros in WE GLSL: \(r)")
    }

    func testChainedDefinesReachFixpoint() {
        let src = "#define A B\n#define B 2.0\nfloat v = A;"
        let r = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(r.contains("float v = 2.0;"), r)
    }

    func testFunctionLikeMacroExpands() {
        // 실물 common_blending.h 는 Blend* 를 전부 함수형 매크로로 정의한다 — 확장 필수.
        let src = "#define DOUBLE(x) ((x)*2.0)\nfloat v = DOUBLE(3.0);"
        let r = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertFalse(r.contains("#define"))
        XCTAssertTrue(r.contains("float v = ((3.0)*2.0);"), r)
    }

    func testFunctionLikeMacroChainsAndNesting() {
        // 실물 패턴: 매크로가 매크로를 호출(BlendLinearLightf→BlendLinearBurnf), 인자에 중첩 괄호/콤마,
        // 별칭(#define BlendDarken BlendDarkenf), 다인자.
        let src = """
        #define BlendLinearBurnf(base, blend) max(base + blend - 1.0, 0.0)
        #define BlendLinearLightf(base, blend) (blend < 0.5 ? BlendLinearBurnf(base, (2.0 * blend)) : (base + blend))
        #define BlendDarkenf(base, blend) min(blend, base)
        #define BlendDarken BlendDarkenf
        float a = BlendLinearLightf(x, y);
        vec3 d = BlendDarken(f(p, q), c.rgb);
        """
        let r = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(r.contains("float a = (y < 0.5 ? max(x + (2.0 * y) - 1.0, 0.0) : (x + y));"), r)
        XCTAssertTrue(r.contains("vec3 d = min(c.rgb, f(p, q));"), r)
        XCTAssertFalse(r.contains("Blend"), "매크로가 전부 확장돼야: \(r)")
    }

    func testCRLFLineEndingsHandled() {
        // 실물 WE 셰이더는 CRLF — `#endif\r` 이 인식 안 되면 조건부 스택이 안 닫혀 이후 전체가 소실된다
        // (실측 31씬 전 효과 translate-nil 의 근본 원인, 2026-07-02).
        let src = "#if MASK\r\nmasked\r\n#else\r\nunmasked\r\n#endif\r\nafter"
        let r = ShaderPreprocessor.preprocess(src, combos: ["MASK": 0])
        XCTAssertTrue(r.contains("unmasked"), r)
        XCTAssertTrue(r.contains("after"), r)
        // 종전 `!contains("masked\r")` 는 무효 단언이었다 — 아래 \r 검사가 참이면 자동 참이고, 정규화 회귀
        // 시엔 "unmasked\r" 가 부분문자열로 걸려 오탐. 줄 단위 비교(:201 과 같은 이유)로 비활성 분기
        // 누출을 직접 검증한다.
        XCTAssertFalse(r.split(separator: "\n").map(String.init).contains("masked"),
                       "비활성 분기 줄 누출 금지: \(r)")
        XCTAssertFalse(r.contains("\r"), "출력은 LF 정규화: \(r)")
    }

    func testDirectivesWithTrailingComments() {
        // 실물: `#endif // MASK` / `#else // foo` — 꼬리 주석이 있어도 지시문으로 인식돼야 한다.
        let src = "#if MASK\nmasked\n#else // fallback\nunmasked\n#endif // MASK\nafter"
        let r = ShaderPreprocessor.preprocess(src, combos: ["MASK": 0])
        XCTAssertTrue(r.contains("unmasked"), r)
        XCTAssertTrue(r.contains("after"), r)
        XCTAssertFalse(r.contains("#endif"), "지시문이 출력에 남으면 MSL 에서 '#endif without #if': \(r)")
        XCTAssertFalse(r.split(separator: "\n").map(String.init).contains("masked"),
                       "비활성 분기 줄 제외(‘unmasked’ 부분문자열 오탐 방지): \(r)")
    }

    func testExprEvalDirect() {
        XCTAssertEqual(ExprEval.eval("1 + 2 * 3", defines: [:]), 7)
        XCTAssertEqual(ExprEval.eval("(1 + 2) * 3", defines: [:]), 9)
        XCTAssertEqual(ExprEval.eval("X", defines: ["X": 5]), 5)
        XCTAssertEqual(ExprEval.eval("UNDEFINED", defines: [:]), 0)
        XCTAssertEqual(ExprEval.eval("!0", defines: [:]), 1)
        XCTAssertEqual(ExprEval.eval("A || B", defines: ["A": 0, "B": 1]), 1)
    }

    /// C 규약: #define 은 정의 이후 줄부터만 치환(실물 frame_builder — 정의 이전의 지역 `float res;` 가
    /// `#define res g_Texture0Resolution.xy` 로 오염되던 근본 원인).
    func testDefineAppliesOnlyAfterDefinition() {
        let src = """
        float res;
        res = 1.0;
        #define res g_Texture0Resolution.xy
        vec2 q = res;
        """
        let out = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(out.contains("float res;"), out)
        XCTAssertTrue(out.contains("res = 1.0;"), out)
        XCTAssertTrue(out.contains("vec2 q = g_Texture0Resolution.xy;"), out)
    }

    /// 재정의: 이전 정의는 재정의 줄까지만 유효.
    func testRedefinitionScopesRanges() {
        let src = """
        #define K 2.0
        float a = K;
        #define K 5.0
        float b = K;
        """
        let out = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(out.contains("float a = 2.0;"), out)
        XCTAssertTrue(out.contains("float b = 5.0;"), out)
    }

    func testUndefRemovesMacroForConditionalsAndSubstitution() {
        let src = """
        #define ENABLED 1
        float before = ENABLED;
        #undef ENABLED
        #ifdef ENABLED
        enabled
        #else
        disabled
        #endif
        float after = ENABLED;
        """
        let out = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(out.contains("float before = 1;"), out)
        XCTAssertTrue(out.contains("disabled"), out)
        XCTAssertFalse(out.contains("enabled\n"), out)
        XCTAssertTrue(out.contains("float after = ENABLED;"), out)
        XCTAssertFalse(out.contains("#undef"), out)
    }

    /// 함수형 매크로도 정의 이후부터.
    func testFuncMacroPositionAware() {
        let src = """
        float F;
        #define F(x) (x * 2.0)
        float y = F(3.0);
        """
        let out = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(out.contains("float F;"), out)
        XCTAssertTrue(out.contains("float y = (3.0 * 2.0);"), out)
    }

    // MARK: - F3: HLSL/HLSL_SM40 시딩(실물 WE composelayer.vert 화면공간 Y-플립 분기)

    /// WE 는 항상 HLSL(D3D11) 백엔드로 컴파일 — `#ifdef HLSL` 화면공간 Y-플립 보정이 살아남아야 한다.
    /// (실물 assets/shaders/composelayer.vert 발췌와 동일한 패턴.)
    func testHLSLDefineSeededSelectsScreenFlipBranch() {
        let src = """
        vec3 position = vec3(a_TexCoord, 0.0);
        #ifdef HLSL
        position.y = 1.0 - position.y;
        v_ScreenCoord.y = -v_ScreenCoord.y;
        #endif
        position.xy = position.xy * 2.0 - 1.0;
        """
        let out = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(out.contains("v_ScreenCoord.y = -v_ScreenCoord.y;"),
                      "HLSL 미시딩 — 화면공간 Y-플립 보정이 누락됨: \(out)")
        XCTAssertTrue(out.contains("position.y = 1.0 - position.y;"), out)
    }

    /// `#if HLSL`(defined 아닌 값 평가) 형태도 동일하게 참이어야 한다(실물 effectcomposebackground.vert).
    func testHLSLValueFormSelectsTrueBranch() {
        let src = """
        v_ScreenCoord = mul(vec4(a_Position, 1.0), g_EffectModelViewProjectionMatrix).xyw;
        #if HLSL
        v_ScreenCoord.y = -v_ScreenCoord.y;
        #endif
        """
        let out = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(out.contains("v_ScreenCoord.y = -v_ScreenCoord.y;"), out)
    }

    /// HLSL_SM30(구형 SM3.0 텍스처 채널 워크어라운드)는 대상 밖 — 시딩하지 않아 현대 GPU 분기(`.r`)가 유지돼야 한다.
    func testHLSLSM30NotSeededKeepsModernBranch() {
        let src = """
        float ConvertSampleR8(vec4 s) {
        #if HLSL_SM30
            return s.a;
        #else
            return s.r;
        #endif
        }
        """
        let out = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(out.contains("return s.r;"), out)
        XCTAssertFalse(out.contains("return s.a;"), out)
    }

    /// scene.json 콤보가 명시적으로 HLSL 을 지정해도(비정상 입력이나 방어) 엔진 확정값(HLSL=1)이 이긴다 —
    /// combos 는 var defines = combos 로 먼저 깔리지만 이후 강제 대입되므로 항상 1.
    func testHLSLCannotBeOverriddenByCombos() {
        let out = ShaderPreprocessor.preprocess("#if HLSL\nyes\n#else\nno\n#endif", combos: ["HLSL": 0])
        XCTAssertTrue(out.contains("yes"), out)
    }
}
