import XCTest
@testable import WapleCore

final class ShaderPreprocessorTests: XCTestCase {
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
        XCTAssertFalse(r.contains("masked\r"), r)
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
}
