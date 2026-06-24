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

    func testExprEvalDirect() {
        XCTAssertEqual(ExprEval.eval("1 + 2 * 3", defines: [:]), 7)
        XCTAssertEqual(ExprEval.eval("(1 + 2) * 3", defines: [:]), 9)
        XCTAssertEqual(ExprEval.eval("X", defines: ["X": 5]), 5)
        XCTAssertEqual(ExprEval.eval("UNDEFINED", defines: [:]), 0)
        XCTAssertEqual(ExprEval.eval("!0", defines: [:]), 1)
        XCTAssertEqual(ExprEval.eval("A || B", defines: ["A": 0, "B": 1]), 1)
    }
}
