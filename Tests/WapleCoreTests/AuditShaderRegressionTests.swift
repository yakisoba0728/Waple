import XCTest
@testable import WapleCore

final class AuditShaderRegressionTests: XCTestCase {
    private let vertex = "void main() { gl_Position = vec4(a_Position, 1.0); }"

    private func helperBody(_ msl: String) throws -> String {
        let start = try XCTUnwrap(msl.range(of: "float value(", options: .backwards))
        let opening = try XCTUnwrap(msl[start.upperBound...].firstIndex(of: "{"))
        var depth = 0
        var closing: String.Index?
        for index in msl[opening...].indices {
            if msl[index] == "{" { depth += 1 }
            if msl[index] == "}" {
                depth -= 1
                if depth == 0 { closing = index; break }
            }
        }
        let end = try XCTUnwrap(closing)
        return String(msl[start.lowerBound...end])
    }

    func testFragmentWrapperChainUsesFragmentCallee() throws {
        let vertex = """
        float stageValue() { return 0.25; }
        float sharedValue() { return stageValue(); }
        float outerValue() { return sharedValue(); }
        void main() { gl_Position = vec4(a_Position * outerValue(), 1.0); }
        """
        let fragment = """
        float stageValue() { return 0.75; }
        float sharedValue() { return stageValue(); }
        float outerValue() { return sharedValue(); }
        void main() { gl_FragColor = vec4(outerValue()); }
        """
        let msl = try XCTUnwrap(GLSLTranslator.translate(vertex: vertex, fragment: fragment, combos: [:])).msl
        XCTAssertTrue(msl.contains("return stageValue_f();"), msl)
        XCTAssertTrue(msl.contains("return sharedValue_f();"), msl)
        XCTAssertTrue(msl.contains("float4(outerValue_f())"), msl)
        XCTAssertTrue(msl.contains("return stageValue();"), "Vertex wrapper must keep its own callee: \(msl)")
    }

    func testStageHelperRenameDoesNotCollideWithAuthoredSuffix() throws {
        let vertex = """
        float stageValue() { return 0.25; }
        float stageValue_f() { return 0.5; }
        void main() { gl_Position = vec4(a_Position * stageValue_f(), 1.0); }
        """
        let fragment = """
        float stageValue() { return 0.75; }
        void main() { gl_FragColor = vec4(stageValue()); }
        """
        let msl = try XCTUnwrap(GLSLTranslator.translate(vertex: vertex, fragment: fragment, combos: [:])).msl
        XCTAssertTrue(msl.contains("stageValue_f2"), msl)
        XCTAssertTrue(msl.contains("return 0.5;"), msl)
        XCTAssertTrue(msl.contains("return 0.75;"), msl)
    }

    func testHelperReceivesTransitiveRuntimeConstDeclarationsInSourceOrder() throws {
        let fragment = """
        const float A = g_Time;
        const float B = A + 1.0;
        const float C = B * 2.0;
        float value() { return C; }
        void main() { gl_FragColor = vec4(value()); }
        """
        let msl = try XCTUnwrap(GLSLTranslator.translate(vertex: vertex, fragment: fragment, combos: [:])).msl
        let helper = try helperBody(msl)
        let a = try XCTUnwrap(helper.range(of: "float A ="))
        let b = try XCTUnwrap(helper.range(of: "float B ="))
        let c = try XCTUnwrap(helper.range(of: "float C ="))
        XCTAssertLessThan(a.lowerBound, b.lowerBound)
        XCTAssertLessThan(b.lowerBound, c.lowerBound)
    }

    func testTransitiveRuntimeConstDoesNotCollideWithHelperParameter() throws {
        let fragment = """
        const float A = g_Time;
        const float B = A + 1.0;
        float value(float A) { return B; }
        void main() { gl_FragColor = vec4(value(42.0)); }
        """
        let msl = try XCTUnwrap(GLSLTranslator.translate(vertex: vertex, fragment: fragment, combos: [:])).msl
        let helper = try helperBody(msl)
        XCTAssertTrue(helper.contains("const float we_const_A ="), helper)
        XCTAssertTrue(helper.contains("const float B = we_const_A + 1.0;"), helper)
        XCTAssertFalse(helper.contains("const float A ="), helper)
    }

    func testTransitiveRuntimeConstDoesNotCaptureHelperLocal() throws {
        let fragment = """
        const float A = g_Time;
        const float B = A + 1.0;
        float value() { float A = 42.0; return B + A; }
        void main() { gl_FragColor = vec4(value()); }
        """
        let msl = try XCTUnwrap(GLSLTranslator.translate(vertex: vertex, fragment: fragment, combos: [:])).msl
        let helper = try helperBody(msl)
        XCTAssertTrue(helper.contains("const float A ="), helper)
        XCTAssertTrue(helper.contains("const float B = A + 1.0;"), helper)
        XCTAssertTrue(helper.contains("float A = 42.0;"), helper)
        XCTAssertTrue(helper.contains("return B + A;"), helper)
    }

    func testRuntimeConstRemainsVisibleOutsideNestedLocalShadow() throws {
        let fragment = """
        const float A = g_Time;
        float value() { float result = A; { float A = 10.0; result += A; } return result; }
        void main() { gl_FragColor = vec4(value()); }
        """
        let msl = try XCTUnwrap(GLSLTranslator.translate(vertex: vertex, fragment: fragment, combos: [:])).msl
        let helper = try helperBody(msl)
        XCTAssertTrue(helper.contains("const float A ="), helper)
        XCTAssertTrue(helper.contains("float result = A;"), helper)
        XCTAssertTrue(helper.contains("float A = 10.0;"), helper)
        XCTAssertTrue(helper.contains("return result;"), helper)
    }

    func testShadowedGlobalConstIsNotInjectedForAParameterReference() throws {
        let fragment = """
        const float A = g_Time;
        float value(float A) { return A; }
        void main() { gl_FragColor = vec4(value(42.0)); }
        """
        let msl = try XCTUnwrap(GLSLTranslator.translate(vertex: vertex, fragment: fragment, combos: [:])).msl
        let helper = try helperBody(msl)
        XCTAssertTrue(helper.contains("return A;"), helper)
        XCTAssertFalse(helper.contains("const float"), helper)
        XCTAssertFalse(helper.contains("g_Time"), helper)
    }

    func testAmbientHelperCaptureKeepsVec3Type() throws {
        let fragment = """
        uniform vec3 g_LightAmbientColor;
        uniform vec3 g_LightSkylightColor;
        vec3 ambient() { return g_LightAmbientColor + g_LightSkylightColor; }
        void main() { gl_FragColor = vec4(ambient(), 1.0); }
        """
        let msl = try XCTUnwrap(GLSLTranslator.translate(vertex: vertex, fragment: fragment, combos: [:])).msl
        XCTAssertTrue(msl.contains("float3 g_LightAmbientColor"), msl)
        XCTAssertTrue(msl.contains("float3 g_LightSkylightColor"), msl)
        XCTAssertFalse(msl.contains("float g_LightAmbientColor"), msl)
        XCTAssertFalse(msl.contains("float g_LightSkylightColor"), msl)
    }

    func testRedefinedIntegerMacroUsesNewAliasInConditionAndBody() {
        let out = ShaderPreprocessor.preprocess("""
        #define FLAG 1
        #define OFF 0
        #define FLAG OFF
        #if FLAG
        stale_branch;
        #else
        selected = FLAG;
        #endif
        """, combos: [:])
        XCTAssertFalse(out.contains("stale_branch;"), out)
        XCTAssertTrue(out.contains("selected = 0;"), out)
    }

    func testRedefinitionReplacesFunctionAndSuspectState() {
        let out = ShaderPreprocessor.preprocess("""
        #define FLAG 1
        #define FLAG(x) x
        #if FLAG
        stale_integer;
        #endif
        #define FLAG 1e5
        #define FLAG 0
        #if FLAG
        stale_suspect;
        #else
        selected;
        #endif
        """, combos: [:])
        XCTAssertTrue(out.contains("selected;"), out)
        XCTAssertFalse(out.contains("stale_integer;") || out.contains("stale_suspect;"), out)
    }

    func testFlagRedefinitionEndsPriorValueSubstitution() {
        let out = ShaderPreprocessor.preprocess("#define K 2\nbefore = K;\n#define K\nafter = K;", combos: [:])
        XCTAssertTrue(out.contains("before = 2;"), out)
        XCTAssertTrue(out.contains("after = K;"), out)
    }

    func testIfExpressionSplicesMacroTokensWithoutAddingParentheses() {
        let out = ShaderPreprocessor.preprocess("""
        #define ONE 1
        #define VALUE ONE + 2
        #if VALUE * 3 == 7
        ungrouped;
        #endif
        #define VALUE (ONE + 2)
        #if VALUE * 3 == 9
        grouped;
        #endif
        """, combos: [:])
        XCTAssertTrue(out.contains("ungrouped;"), out)
        XCTAssertTrue(out.contains("grouped;"), out)
    }

    func testNumericLeadingExpressionMacroKeepsTextualPrecedence() {
        let out = ShaderPreprocessor.preprocess("#define VALUE 1 + 2\n#if VALUE * 3 == 7\nselected;\n#endif", combos: [:])
        XCTAssertTrue(out.contains("selected;"), out)
    }

    func testExpressionMacroPreservesDefinedCyclesAndStrictRefusal() {
        XCTAssertEqual(ExprEval.evalChecked("defined(A) && !defined(B)", defines: [:],
                                          definedNames: ["A"], textDefines: ["A": "B"]), 1)
        XCTAssertEqual(ExprEval.evalChecked("A", defines: [:], textDefines: ["A": "B", "B": "A"]), 0)
        XCTAssertEqual(ExprEval.evalChecked("A", defines: [:], textDefines: ["A": "vec3(1.0)"]), 0)
        XCTAssertNil(ExprEval.evalChecked("A", defines: [:], suspect: ["A"], textDefines: ["A": "1e5"]))
        XCTAssertNil(ExprEval.evalChecked("ALIAS", defines: [:], suspect: ["A"],
                                        textDefines: ["ALIAS": "A", "A": "1e5"]))
        XCTAssertNil(ExprEval.evalChecked("A ? 1 : 0", defines: [:], textDefines: ["A": "1 + 2"]))
    }

    func testExpressionMacroExpansionHasATotalTokenBudget() {
        var macros = ["A0": "1"]
        for n in 1...16 { macros["A\(n)"] = "A\(n - 1) + A\(n - 1)" }
        XCTAssertNil(ExprEval.evalChecked("A16", defines: [:], textDefines: macros))
    }

    func testMalformedMacroBranchesConsumeTheSharedExpansionBudget() {
        var macros = ["A0": "1"]
        for n in 1...4 { macros["A\(n)"] = "A\(n - 1) A\(n - 1)" }
        // 1 root + 2*(1+2+4+8) branch tokens + 16 literal tokens = 47 visits, despite a one-token result.
        XCTAssertEqual(ExprEval.evalChecked("A4", defines: [:], textDefines: macros, expansionBudget: 47), 0)
        XCTAssertNil(ExprEval.evalChecked("A4", defines: [:], textDefines: macros, expansionBudget: 46))
    }
}
