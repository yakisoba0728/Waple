import XCTest
@testable import WapleCore

/// 감사 2차 라운드 fix-g1 그룹 회귀 가드: GLSLTranslator varying 캡처(F420/F-10),
/// ShaderPreprocessor #if 안전 거부(F421/F-11)·괄호 정수 define(F422/F-54),
/// PropertyConditionEvaluator 최상위 삼항(F423/F-16),
/// WallpaperCompatibilityAnalyzer 웹 피처 경로(F424/F-65).
final class TranslationEvalFixRegressionTests: XCTestCase {
    // MARK: - F420 (F-10): vertex 헬퍼의 varying 쓰기 — 참조 캡처

    private let fragReadUV = """
    varying vec2 v_TexCoord;
    void main() { gl_FragColor = vec4(v_TexCoord, 0.0, 1.0); }
    """

    /// 종전엔 varying 캡처가 by-value(`float2 v_TexCoord`)라 `setupUV` 의 대입이 호출부의
    /// `out.v_TexCoord` 에 반영되지 않았다(컴파일 성공·오렌더). 쓰는 varying 은 thread& 로 승격.
    func testVertexHelperVaryingWriteCapturedByReference() throws {
        let vert = """
        varying vec2 v_TexCoord;
        void setupUV() { v_TexCoord = a_TexCoord; }
        void main() { setupUV(); gl_Position = vec4(a_Position, 1.0); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: fragReadUV, combos: [:]))
        XCTAssertTrue(t.msl.contains("inline void setupUV(thread float2& v_TexCoord"), t.msl)
        XCTAssertTrue(t.msl.contains("setupUV(out.v_TexCoord"), t.msl)
    }

    /// 쓰기 전이 폐쇄: A→B 호출 시 B 가 쓰는 varying 은 A 도 참조로 받아야 물려줄 때 유실이 없다.
    func testTransitiveVaryingWriteCapturedByReference() throws {
        let vert = """
        varying vec2 v_TexCoord;
        void inner() { v_TexCoord = a_TexCoord; }
        void outer() { inner(); }
        void main() { outer(); gl_Position = vec4(a_Position, 1.0); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: fragReadUV, combos: [:]))
        XCTAssertTrue(t.msl.contains("inline void inner(thread float2& v_TexCoord"), t.msl)
        XCTAssertTrue(t.msl.contains("inline void outer(thread float2& v_TexCoord"), t.msl)
        XCTAssertTrue(t.msl.contains("outer(out.v_TexCoord"), t.msl)
    }

    /// 읽기 전용 varying 캡처는 기존 by-value 유지(무관 변경 방지 — testHelperCapturesVarying 과 쌍).
    func testReadOnlyVaryingCaptureStaysByValue() throws {
        let frag = """
        varying vec2 v_TexCoord;
        float vig() { return 1.0 - length(v_TexCoord - 0.5); }
        void main() { gl_FragColor = vec4(vec3(vig()), 1.0); }
        """
        let vert = "varying vec2 v_TexCoord;\nvoid main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }"
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("inline float vig(float2 v_TexCoord)"), t.msl)
        XCTAssertFalse(t.msl.contains("thread float2& v_TexCoord"), t.msl)
    }

    // MARK: - F421 (F-11): #if 미지원 패턴 — 안전 거부(폴터)

    /// 렉서·파서가 모르는 식은 조용한 오분기 대신 전처리 거부.
    ///
    /// **[G2 2026-08-21] 이 목록이 크게 줄었다.** 종전에는 `%`·비트(`& | ^ ~`)·시프트·16진/접미
    /// 리터럴도 여기 있었는데, 실물 렉서(0x140166a90-0x1401670ba)와 파서 사슬
    /// (0x1401670d0 `||` → … → 0x140167b80 `*`/`/`/`%` → 0x140167c00 원자)이 **전부 지원**함을
    /// 디스어셈으로 확정하고 `ExprEval` 을 그만큼 넓혔다. 그 계약은
    /// `ShaderPreprocessorRequireTests` 의 G2 절이 갖는다.
    /// 여기 남은 것은 **실물에도 없거나 우리가 일부러 안 받는 것**뿐이다:
    ///  · 삼항 `?:` — 실물 렉서가 "그 외 문자"(코드 0x19)로 떨어뜨린다.
    ///  · 잔여 토큰 — 실물은 관용이지만 우리는 "오역보다 폴터" 규약대로 거부한다.
    ///
    /// **[2026-08-21] 소수 리터럴은 이 목록에서 빠졌다.** 종전엔 `#if 1.5` 와
    /// `#define K 1.5` 가 여기 있었고 위 주석도 "미구현" 이라고 적고 있었다. 실물은
    /// `0x140167021` 에서 `.` 을 isdigit 검사 **전에** 무조건 소비하고
    /// `0x140167031`-`0x140167046` 이 소수부를 읽되 누적기를 안 건드린다 → `#if 1.5` = 1.
    /// 16진 분기도 `0x140166ff1` 로 같은 자리에 합류한다 → `#if 0x10.5` = 16.
    /// "오역보다 폴터" 를 뒤집는 자리라 근거는 `ShaderPreprocessor` 주석에 적혀 있고,
    /// 지금 그 계약을 잠그는 것은 `ShaderPreprocessorConformanceTests` 와
    /// `ShaderPreprocessorRequireTests` 다. 여기서는 **아래 대조군**으로만 남긴다.
    func testUnsupportedIfExpressionsAreRefused() {
        let cases = [
            "#if A ? 1 : 0\nyes\n#endif",
            "#if 1 0\nyes\n#endif",
            "#if A == 1\none\n#elif A ? 1 : 0\ntwo\n#endif",
            "#if A @ 1\nyes\n#endif",
        ]
        for src in cases {
            XCTAssertNil(ShaderPreprocessor.preprocessStrict(src, combos: ["A": 3]), src)
            XCTAssertEqual(ShaderPreprocessor.preprocess(src, combos: ["A": 3]), "", src)
        }
    }

    /// 위 목록에서 빠진 두 입력이 **실물대로 평가된다**는 대조군. 이게 없으면 소수 리터럴이
    /// 어느 쪽으로 가는지 이 파일만 봐서는 알 수 없다(종전 문면은 거부라고 적고 있었다).
    func testDecimalLiteralsInIfEvaluateInsteadOfRefusing() {
        for src in ["#if 1.5\nyes\n#endif", "#define K 1.5\n#if K\nyes\n#endif"] {
            XCTAssertNotNil(ShaderPreprocessor.preprocessStrict(src, combos: ["A": 3]), src)
            XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["A": 3]).contains("yes"), src)
        }
        // 소수부는 **버린다** — 0.5 는 거짓이어야 한다(정수부 0).
        XCTAssertFalse(ShaderPreprocessor.preprocess("#if 0.5\nyes\n#endif", combos: [:]).contains("yes"))
    }

    /// 거부 오발 방지: 지원 문법(비교·논리·defined·괄호·10진 정수·콤보)은 기존과 동일하게 평가.
    func testSupportedIfExpressionsStillEvaluate() {
        let src = "#if COMBO == 1\none\n#elif defined(X) && !defined(Y)\ntwo\n#else\nother\n#endif"
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["COMBO": 1]).contains("one"))
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["COMBO": 0, "X": 1]).contains("two"))
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["COMBO": 0]).contains("other"))
        XCTAssertTrue(ShaderPreprocessor.preprocess("#if 1 + 2 * 3 == 7\nyes\n#endif", combos: [:]).contains("yes"))
        XCTAssertTrue(ShaderPreprocessor.preprocess("#if (A > 2) && !(B <= 1)\nyes\n#endif",
                                                    combos: ["A": 3, "B": 2]).contains("yes"))
        XCTAssertEqual(ExprEval.evalChecked("1 + 2 * 3", defines: [:]), 7)
        // [G2] `%`·16진은 이제 평가된다(실물과 같게) — 거부로 남은 것은 잔여 토큰·삼항뿐.
        XCTAssertEqual(ExprEval.evalChecked("A % 2", defines: ["A": 3]), 1)
        XCTAssertEqual(ExprEval.evalChecked("0x10", defines: [:]), 16)
        XCTAssertNil(ExprEval.evalChecked("1 0", defines: [:]))
        XCTAssertNil(ExprEval.evalChecked("A ? 1 : 0", defines: ["A": 1]))
    }

    /// 비활성 부모 안쪽의 미지원 #if 는 출력에 무영향 — 거부하지 않고 나머지를 정상 처리한다.
    func testUnsupportedIfInsideInactiveBlockIsTolerated() {
        let src = "#if 0\n#if BAD ? 1 : 0\ndead\n#endif\n#else\nlive\n#endif"   // [G2] `%` 는 이제 지원 — 여전히 미지원인 삼항으로
        let r = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(r.contains("live"), r)
        XCTAssertFalse(r.contains("dead"), r)
    }

    /// 번역 파이프라인 통합: 거부된 전처리 → 번역 nil → 호출부(SceneRendererResources) 폴터 폴백.
    func testTranslateRefusesShaderWithUnsupportedIf() {
        let vert = "varying vec2 v_TexCoord;\nvoid main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }"
        let frag = """
        varying vec2 v_TexCoord;
        void main() {
        #if A ? 1 : 0
            gl_FragColor = vec4(1.0);
        #else
            gl_FragColor = vec4(v_TexCoord, 0.0, 1.0);
        #endif
        }
        """
        XCTAssertNil(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
    }

    // MARK: - F422 (F-54): 괄호 감싼 정수 define 의 #if 평가

    /// `#define MODE (2)` — 종전엔 Int("(2)") == nil 이라 #if MODE 가 0 평가(본문 치환과 불일치).
    func testParenthesizedIntegerDefineEvaluatesInIf() {
        let src = "#define MODE (2)\n#if MODE == 2\nyes\n#else\nno\n#endif\nint m = MODE;"
        let r = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(r.contains("yes"), r)
        XCTAssertFalse(r.contains("\nno\n"), r)
        XCTAssertTrue(r.contains("int m = (2);"), r)   // 본문 치환은 기존 그대로 — 이제 #if 와 일치
        let nested = "#define N ((3))\n#if N == 3\nyes\n#endif"
        XCTAssertTrue(ShaderPreprocessor.preprocess(nested, combos: [:]).contains("yes"))
    }

    // MARK: - F423 (F-16): 최상위 삼항 조건식

    /// 갈래를 둘 다 평가할 수 있으면 실제 삼항 결과 — 종전엔 guard 부분만 평가해 truthiness 가
    /// guard 와 다른 분기에서 표시 여부가 반대로 됐다.
    func testTopLevelTernaryFullyEvaluatedWhenBranchesParseable() {
        let values: [String: PropertyValue] = ["a": .number(1), "b": .number(1), "c": .number(3)]
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("a.value == 1 ? b.value == 2 : c.value == 3", values: values), false)  // guard 참 → then(b==2)=false
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("a.value == 2 ? b.value == 2 : c.value == 3", values: values), true)   // guard 거짓 → else(c==3)=true
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("a.value == 1 ? 0 : 1", values: values), false)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("a.value == 2 ? 0 : 1", values: values), true)
        // 중첩 삼항(우결합): 짝 `:` 추적
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("a.value == 2 ? 1 : b.value == 1 ? 2 : 0", values: values), true)
        XCTAssertEqual(PropertyConditionEvaluator.evaluate("a.value == 1 ? b.value == 2 ? 1 : 0 : 3", values: values), false)
        XCTAssertTrue(PropertyConditionEvaluator.canEvaluate("a.value == 1 ? b.value == 2 : c.value == 3"))
    }

    /// 갈래가 미지원 문법(실물 corpus 의 대입식)이면 종전 guard-only 관용을 유지하되,
    /// canEvaluate=false — analyzer 의 propertyDisplayCondition 경고 우회를 막는다.
    func testTernaryWithUnparseableBranchesFallsBackToGuardAndCannotEvaluate() {
        let values: [String: PropertyValue] = ["en": .bool(true), "t": .number(2)]
        XCTAssertEqual(
            PropertyConditionEvaluator.evaluate("en.value && !(t.value == 1) ? e.text = 'x' : false", values: values),
            true   // guard-only 관용값(기존 동작 유지)
        )
        XCTAssertFalse(PropertyConditionEvaluator.canEvaluate("en.value && !(t.value == 1) ? e.text = 'x' : false"))
    }

    func testIsVisibleUsesFullTernaryResult() {
        let props = [
            WallpaperProperty(key: "mode", type: "combo", value: .number(1), order: 0, condition: nil),
            WallpaperProperty(key: "sub", type: "slider", value: .number(1), order: 1,
                              condition: "mode.value == 1 ? 0 : 1"),
        ]
        XCTAssertEqual(PropertyConditionEvaluator.visibleIndices(in: props), [0])
    }

    // MARK: - F424 (F-65): 웹 피처 경고의 relativePath = 실제 탐지 파일

    /// include 된 JS 에서 serviceWorker 를 탐지하면 경고는 그 JS 를 가리켜야 한다
    /// (종전엔 항상 엔트리 index.html).
    func testWebFeatureIssuePointsAtDetectingFile() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeProject(
            id: "web-paths",
            in: root,
            json: #"{"type":"web","file":"index.html"}"#,
            files: [
                "index.html": #"<script src="js/runtime.js"></script><script>wallpaperRegisterAudioListener(function(){});</script>"#,
                "js/runtime.js": "navigator.serviceWorker.register('sw.js');",
            ]
        )

        let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: root)
        let project = try XCTUnwrap(report.projects.first { $0.id == "web-paths" })
        let serviceWorker = try XCTUnwrap(project.issues.first { $0.code == .webServiceWorker })
        XCTAssertEqual(serviceWorker.relativePath, "js/runtime.js")
        let audio = try XCTUnwrap(project.issues.first { $0.code == .webAudioListener })
        XCTAssertEqual(audio.relativePath, "index.html")   // 엔트리에서 직접 탐지된 경우는 종전과 동일
    }

    // MARK: - 픽스처 헬퍼(WallpaperCompatibilityAnalyzerTests 와 동형 — private 이라 복제)

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WapleFixG1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeProject(id: String, in root: URL, json: String, files: [String: String]) throws {
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
        for (relativePath, contents) in files {
            let url = folder.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
    }
}
