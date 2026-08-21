import XCTest
@testable import WapleCore

/// **실물 전처리기와의 규약 재대조(2026-08-21).** 여기 걸린 세 건은 전부 동봉·설치본 자산에
/// **도달 0건**인 잠복 갭이다 — 워크샵 셰이더가 밟는다. 근거는 전부 원본 디스어셈블이고,
/// 각 테스트 주석에 VA 를 적었다. 자산 도달이 0 이라는 것도 명시한다(범위 라벨).
///
/// 대조한 실물 구성요소:
/// - 줄 인식 정규식 `^\s*#\s*([a-z]+)\b\s*(.*)` — 원본 파일오프셋 `0x48be48`, 바로 뒤에
///   `SHADERVERSION`·`69`·`ifndef`·`ifdef`·`define`·`elif`·`if`·`endif`·`else`·`undef`·`require`
///   문자열이 이어진다(= 인식 이름 9종의 출처).
/// - `#if` 식 렉서 `0x140166a90`–`0x1401670ba`(`primary()` 확인).
/// - `#if` 식 파서 사슬 `0x1401670c0`(`||`) … `0x140167c00`(단항·원자).
final class ShaderPreprocessorConformanceTests: XCTestCase {

    private func pre(_ src: String, _ combos: [String: Int] = [:]) -> String {
        ShaderPreprocessor.preprocess(src, combos: combos)
    }

    // MARK: 1. `# if` — `#` 와 키워드 사이의 공백

    /// 실물 정규식이 `#\s*([a-z]+)` 라 `# if` 도 지시문이다. 종전 Waple 은 `hasPrefix("#if ")` 라
    /// 못 알아보고 **지시문 줄을 본문으로 흘려보냈고**, 짝 `#endif` 는 (같은 이유로) 역시 흘러
    /// 조건부가 통째로 무시됐다 — 거짓 분기의 코드까지 전부 방출된다.
    /// 동봉·설치본 자산 도달: **0건**(`^\s*#[ \t]+<kw>` 실측 0).
    func testSpaceBetweenHashAndKeywordIsStillADirective() {
        let src = """
        keep_before;
        # if MODE
        taken;
        # else
        not_taken;
        # endif
        keep_after;
        """
        let on = pre(src, ["MODE": 1])
        XCTAssertTrue(on.contains("taken;"))
        XCTAssertFalse(on.contains("not_taken;"), "거짓 분기가 방출됐다: \(on)")
        XCTAssertFalse(on.contains("#"), "지시문 줄이 본문에 남았다: \(on)")
        let off = pre(src, ["MODE": 0])
        XCTAssertTrue(off.contains("not_taken;"))
        XCTAssertFalse(off.contains("\ntaken;"), "참 분기가 방출됐다: \(off)")
    }

    /// `# ifdef`/`# ifndef`/`# elif`/`# undef`/`# define` 도 같다(9종 전부).
    func testAllNineDirectiveNamesFoldTheSpace() {
        let src = """
        # define K 3
        # ifdef K
        a;
        # endif
        # ifndef K
        b;
        # endif
        # undef K
        # ifdef K
        c;
        # endif
        # if 0
        d;
        # elif 1
        e;
        # endif
        """
        let out = pre(src)
        XCTAssertTrue(out.contains("a;") && out.contains("e;"), out)
        XCTAssertFalse(out.contains("b;") || out.contains("c;") || out.contains("d;"), out)
        XCTAssertFalse(out.contains("#"), "지시문이 남았다: \(out)")
    }

    /// **대조군 — 미지의 지시문은 접지 않는다.** 실물은 `#version`/`#extension`/`#pragma` 를
    /// 지시문으로 인식하지 못해(0x14016c1f8 → 0x14016bbb0) 본문에 **그대로** 남긴다.
    /// 공백을 접어 버리면 우리만 텍스트를 바꾸는 셈이라 안 한다.
    func testUnknownDirectiveSpacingIsLeftAlone() {
        let out = pre("# version 120\n# pragma once\nkeep;")
        XCTAssertTrue(out.contains("# version 120"), "미지 지시문을 건드렸다: \(out)")
        XCTAssertTrue(out.contains("# pragma once"), out)
    }

    // MARK: 2. `#if` 식 안의 매크로 확장(재귀)

    /// 실물은 **렉서**가 매크로를 확장한다 — 본문 포인터를 스택에 밀고(0x140166cc1-0x140166db7,
    /// `inc dword [rbx+0x40]`) 그 자리에서 재렉싱, 끝나면 팝(0x140166ada-0x140166af7 `dec`).
    /// 그래서 별칭 사슬이 통한다. 종전 Waple 은 정수 맵만 봐서 **0** 으로 읽었다.
    /// 동봉·설치본 자산 도달: **0건**(`#if` 가 비-정수 object-like 매크로를 참조하는 사례 0).
    func testIfExpressionExpandsAliasChain() {
        let out = pre("#define B 1\n#define A B\n#if A\nyes;\n#else\nno;\n#endif")
        XCTAssertTrue(out.contains("yes;"), "별칭 사슬이 확장되지 않았다: \(out)")
        XCTAssertFalse(out.contains("no;"), out)
    }

    /// 괄호식 매크로도 같다 — 실물은 본문을 그대로 재렉싱하므로 연산자 우선순위가 보존된다.
    func testIfExpressionExpandsParenthesizedExpressionMacro() {
        let out = pre("#define SUM (2 + 3)\n#if SUM > 4\nbig;\n#else\nsmall;\n#endif")
        XCTAssertTrue(out.contains("big;"), "괄호식 매크로가 확장되지 않았다: \(out)")
        XCTAssertFalse(out.contains("small;"), out)
    }

    /// 깊이 캡(실물 0x63 = 99)과 자기 참조 방어 — `#define A A` 로 무한 재귀에 빠지면 안 된다.
    /// 실물은 캡을 넘기면 그냥 식별자로 떨어뜨려 0 이 된다. 우리는 자기 이름을 맵에서 지워
    /// 한 번만 펼치고 0 으로 떨어진다(같은 결말, 스택 안전).
    func testSelfReferentialMacroTerminatesAsZero() {
        let out = pre("#define A A\n#if A\nyes;\n#else\nno;\n#endif")
        XCTAssertTrue(out.contains("no;"), "자기 참조 매크로는 0 이어야 한다: \(out)")
    }

    /// 식으로 안 읽히는 본문은 **0**(거부가 아니다) — 실물도 미지 식별자를 0 으로 보고
    /// 잔여 토큰을 버린다. 거부하면 셰이더 전체가 폴백해 실물보다 더 많이 잃는다.
    func testNonExpressionMacroBodyEvaluatesToZeroNotRefusal() {
        let out = pre("#define A vec3(1.0)\n#if A\nyes;\n#else\nno;\n#endif\ntail;")
        XCTAssertTrue(out.contains("tail;"), "전처리가 거부돼 전부 사라졌다: \(out)")
        XCTAssertTrue(out.contains("no;"), out)
    }

    /// 대조군 — 정수 `#define` 은 종전 경로(정수 맵) 그대로다.
    func testIntegerDefineStillResolvesThroughIntegerMap() {
        let out = pre("#define K 5\n#if K == 5\nyes;\n#endif")
        XCTAssertTrue(out.contains("yes;"), out)
    }

    /// **[2026-08-21 규약 반전]** 종전 이름은 `testFractionalDefineStillRefusesTheShader` 였고
    /// "소수 리터럴 define 은 여전히 거부" 를 잠갔다. 그 거부가 실물과 갈리는 쪽이었다 —
    /// 렉서(`0x140167021` `cmp byte ptr [rax], 0x2e` → `0x140167026` `inc rax` → `0x140167031`-
    /// `0x140167046`)가 `.` 과 소수부를 읽고 **버리므로** `#if 1.5` 는 실물에서 **1** 이다.
    /// 이제 우리도 1 로 본다. 거부 규약 자체는 남아 있고 그건 형제 테스트
    /// `testDecimalIsNotABlanketPass` 가 잡는다.
    func testFractionalDefineNowEvaluatesLikeTheEngine() {
        let out = pre("#define K 1.5\n#if K\nyes;\n#else\nno;\n#endif")
        XCTAssertTrue(out.contains("yes;"), out)
        XCTAssertFalse(out.contains("no;"), out)
        // 0.x 는 정수부가 0 이라 **거짓**이다(소수부를 버리므로 0.9 도 0).
        let zero = pre("#define K 0.9\n#if K\nyes;\n#else\nno;\n#endif")
        XCTAssertTrue(zero.contains("no;"), zero)
    }

    /// 위 확장이 "숫자로 시작하면 뭐든 받는다"가 아님을 못 박는다 — 지수 표기는 실물도 수를
    /// `1` 에서 끊고 `e5` 를 식별자로 내며, 우리는 그 **잔여 토큰**을 거부한다(의도적 이탈).
    func testDecimalIsNotABlanketPass() {
        XCTAssertNil(ShaderPreprocessor.preprocessStrict("#define K 1e5\n#if K\nyes;\n#endif", combos: [:]))
    }

    // MARK: 3. `defined` — 실물에 **있다**(문자열이 아니라 즉치 비교라 안 보였을 뿐)

    /// 원본에 `"defined"` 문자열이 없어서 "미지원" 으로 오독하기 쉽다. 실제로는 **즉치 비교**다:
    /// 파서 원자(0x140167c90-0x140167cbf)와 렉서(0x140166c09-0x140166c33) 둘 다
    /// `길이==7` + `dword 0x69666564`("defi") + `word 0x656e`("ne") + `byte 0x64`('d') 로 검사한다.
    /// (브리프 함정 10 의 변형 — 짧은 문자열은 `lea` 가 아니라 즉치로 온다.)
    /// 렉서 쪽 검사가 따로 있는 이유는 `defined` **뒤 식별자를 확장하지 않기** 위해서다
    /// (플래그 `[rbx+0x44]`, 0x140167cc8 에서 1, 0x140167d0a/0x140167d17 에서 0).
    /// 괄호는 선택이다(0x140167cd1 `cmp [rbx+8], 3` → `(`, 0x140167d24 `cmp …, 4` → `)`).
    func testDefinedOperatorMatchesTheEngine() {
        let src = "#if defined(A) && !defined(B)\nyes;\n#else\nno;\n#endif"
        XCTAssertTrue(pre(src, ["A": 0]).contains("yes;"), "값 0 이어도 defined 는 참이다")
        XCTAssertTrue(pre(src, ["A": 0, "B": 7]).contains("no;"))
        XCTAssertTrue(pre(src).contains("no;"), "미정의면 거짓")
        // 괄호 없는 형태도 실물이 받는다.
        XCTAssertTrue(pre("#if defined A\nyes;\n#endif", ["A": 0]).contains("yes;"))
    }

    /// `defined` 피연산자는 **확장되면 안 된다** — 확장되면 숫자 토큰이 되어 실물은 0 을 낸다.
    /// (플래그 `[rbx+0x44]` 가 정확히 그것을 막는다.)
    func testDefinedOperandIsNotMacroExpanded() {
        let out = pre("#define A 1\n#if defined(A)\nyes;\n#else\nno;\n#endif")
        XCTAssertTrue(out.contains("yes;"), "defined 피연산자가 확장돼 버렸다: \(out)")
    }

    // MARK: 4. 이미 맞던 것들의 회귀 방지(대조군)

    /// 값 0 인 콤보도 `#ifdef` 는 참 — 실물이 `#define <NAME> 0` 을 텍스트로 주입하기 때문이다
    /// (0x14016c400 `#define ` + 10진). 자산 도달: `#ifdef NORMALMAP`(generic3/4·chroma4·fur4·
    /// foliage4) 등 68건.
    func testZeroValuedComboIsStillDefined() {
        let out = pre("#ifdef MASK\nyes;\n#endif", ["MASK": 0])
        XCTAssertTrue(out.contains("yes;"), out)
    }

    /// 미정의 식별자는 0(0x140167dbe) — `#if GLSL` 이 동봉에 10건, 어디에도 `#define GLSL` 이 없다.
    func testUndefinedIdentifierIsZero() {
        XCTAssertTrue(pre("#if GLSL\nyes;\n#else\nno;\n#endif").contains("no;"))
    }
}
