import XCTest
@testable import WapleCore

/// **`#require` · `#if` 식 확장 · 콤보 키 대문자화** 회귀 가드(G1/G2/G3).
///
/// 왜 따로 있는가
/// -------------
/// 세 갭 모두 "동봉 코퍼스에서는 오늘 아무것도 안 바뀐다"는 성질을 공유한다 —
/// `#require` 는 번역기가 우연히 삼키고 있었고(아래 `testRequireLineIsConsumed…` 의 주석),
/// `#if` 의 비트·시프트·`%`·16진은 동봉 등장 0회이며, 콤보 선언 이름은 동봉 전건 대문자다.
/// 그래서 `GLSLBundledShaderRegressionTests` 스윕은 **셋 다 초록으로 통과한다**(실측: 동봉
/// 239쌍 × 3구성 = 717 구성의 MSL 지문이 변경 전후 전건 동일). 계약을 잡아 두는 곳이 필요하다.
final class ShaderPreprocessorRequireTests: XCTestCase {

    private static let requireDirectiveRe = try! NSRegularExpression(
        pattern: "^[ \t]*#[ \t]*require\\b", options: [.anchorsMatchLines])

    // MARK: - G1: `#require`

    /// 실물 규약(`wallpaper64.exe`, imagebase 0x140000000):
    /// 지시문 인식 0x14016c0ec → 생성기 0x140169140 → 비어 있지 않으면 그 줄 자리에 insert
    /// (0x14016c15c) → 어느 경우든 줄은 공백 memset(0x14016bc63, `bl=1`@0x14016c1cc).
    /// Waple 은 주입을 안 하므로 남는 계약은 **"줄은 반드시 사라진다"** 하나다.
    func testRequireLineIsConsumedRegardlessOfName() {
        let cases = [
            "#require LightingV1\nbody;",
            "#require SomethingUnknown\nbody;",
            "  #require LightingV1\nbody;",     // 실물 정규식 `^\s*#\s*([a-z]+)` 은 선행 공백 허용
            "#require\nbody;",                  // 인자 없음
            "#require\tLightingV1\nbody;",
        ]
        for src in cases {
            let out = ShaderPreprocessor.preprocess(src, combos: [:])
            XCTAssertFalse(out.contains("require"), "지시문 줄이 남았다: \(src) → \(out)")
            XCTAssertTrue(out.contains("body;"), out)
        }
    }

    /// 실물은 `#require` 경로에 **emitting 가드가 없다**(형제 `#define`@0x14016b8f7 ·
    /// `#undef`@0x14016c215 는 `test r13b,r13b` 를 갖는데 require 는 없다). 어느 쪽이든
    /// 비활성 분기의 줄은 출력에서 사라지므로 결과는 같다 — 그 형태를 못 박는다.
    func testRequireInsideInactiveBranchIsAlsoConsumed() {
        let src = "#if 0\n#require LightingV1\ndead;\n#else\nlive;\n#endif"
        let out = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertFalse(out.contains("require"), out)
        XCTAssertFalse(out.contains("dead"), out)
        XCTAssertTrue(out.contains("live"), out)
    }

    /// 생성기 게이트: 이름 == `LightingV1` **그리고** `LIGHTING` 이 정의되고 값이 0 이 아닐 때만
    /// 실물이 코드를 주입한다(0x1401691eb 이름 · 0x1401691b8/0x14016920c 존재 · 0x140169223 값).
    /// Waple 은 그 자리에서 주입 대신 경고를 낸다 — **경고가 곧 "여기서 실물과 갈린다"는 표시**다.
    /// 게이트가 닫힌 경우(대부분)는 실물도 아무것도 안 하므로 조용해야 한다.
    func testWarnsOnlyWhenEngineWouldHaveInjected() {
        func warnings(_ src: String, _ combos: [String: Int]) -> [String] {
            var captured: [String] = []
            let saved = WapleLog.warnHandler
            WapleLog.warnHandler = { captured.append($0) }
            defer { WapleLog.warnHandler = saved }
            _ = ShaderPreprocessor.preprocess(src, combos: combos)
            return captured.filter { $0.contains("#require") }
        }
        let req = "#require LightingV1\nbody;"
        XCTAssertEqual(warnings(req, ["LIGHTING": 1]).count, 1, "LIGHTING!=0 이면 실물은 주입한다")
        XCTAssertEqual(warnings(req, ["LIGHTING": 0]).count, 0, "LIGHTING==0 → 실물도 주입 안 함")
        XCTAssertEqual(warnings(req, [:]).count, 0, "LIGHTING 미정의 → 실물도 주입 안 함")
        XCTAssertEqual(warnings("#require Other\nbody;", ["LIGHTING": 1]).count, 0,
                       "이름이 LightingV1 이 아니면 실물도 빈 문자열 반환")
        // 소스 `#define LIGHTING 1` 로도 게이트가 열린다(실물은 같은 매크로맵을 본다).
        XCTAssertEqual(warnings("#define LIGHTING 1\n" + req, [:]).count, 1)
    }

    /// 동봉 실물 도달. `#require LightingV1` 은 8곳에 있고 그중 **GLSL 번역 레인을 타는 것은
    /// `fluidsimulation_combine.frag` 하나**다(나머지는 모델·파티클 네이티브 레인).
    /// 그 파일의 `LIGHTING` 기본값이 0 이라 실물도 주입하지 않는다 = 소비만으로 정확히 일치한다.
    func testBundledFluidSimulationCombineLosesRequireLine() throws {
        guard let root = GLSLBundledShaderRegressionTests.assetsRoot() else { throw XCTSkip("WAPLE_WE_ASSETS 미지정") }
        let path = root.appendingPathComponent(
            "effects/fluidsimulation/shaders/effects/fluidsimulation_combine.frag")
        guard let data = FileManager.default.contents(atPath: path.path),
              let src = String(data: data, encoding: .utf8) else {
            return XCTFail("동봉 fluidsimulation_combine.frag 를 못 읽었다")
        }
        XCTAssertTrue(src.contains("#require LightingV1"), "자산이 바뀌었다 — 이 테스트의 전제가 사라졌다")
        XCTAssertEqual(ShaderPreprocessor.parseComboDefaults(src)["LIGHTING"], 0,
                       "LIGHTING 기본값이 0 이 아니면 위 '소비만으로 일치' 논거가 깨진다")
        let out = ShaderPreprocessor.preprocess(src, combos: ["LIGHTING": 0])
        XCTAssertFalse(out.isEmpty, "전처리가 거부됐다 — 아래 단정이 공허해진다")
        XCTAssertFalse(out.contains("#require"), "전처리 결과에 지시문이 남았다")
        XCTAssertFalse(out.contains("PerformLighting_V1"),
                       "LIGHTING=0 이면 호출부도 #if 로 잘려 나간다 — 실물과 같은 그림")
    }

    /// 동봉 자산에서 `#require` 를 쓰는 **전건**을 찾아 어떤 콤보 구성에서도 지시문이 살아남지
    /// 않는지 본다. 형제 게이트(`GLSLBundledShaderRegressionTests.testNoEngineDirectiveSurvivesPreprocessing`)
    /// 는 비용 때문에 선언 기본값 한 구성만 보므로, **depth 1 에 있는 두 건**
    /// (`genericparticle.frag:68` · `genericropeparticle.frag:56` — 둘 다 기본값에서 `#if` 로 잘린다)
    /// 은 여기서만 덮인다. 대상이 8건이라 전 구성을 돌려도 비용이 없다.
    ///
    /// 되돌림 실측(2026-08-21): 소비 분기를 없애면 8 파일 × (LIGHTING 0/1) 중 **14 조합**이 걸린다
    /// — depth 0 인 6 파일은 양쪽 다, depth 1 인 둘(`#if LIGHTING` 안)은 LIGHTING=1 에서만.
    ///
    /// **주의: `^` 는 다중행 앵커가 필요하다.** `String.range(of:options:.regularExpression)` 은
    /// `.anchorsMatchLines` 를 못 켜서 `^` 가 **문자열 시작**만 뜻한다 — 그렇게 쓰면 이 테스트가
    /// 되돌림에서도 통과한다(실제로 그렇게 썼다가 당했다). 아래는 명시 `NSRegularExpression` 이다.
    func testAllBundledRequireFilesLoseTheDirective() throws {
        guard let root = GLSLBundledShaderRegressionTests.assetsRoot() else { throw XCTSkip("WAPLE_WE_ASSETS 미지정") }
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("자산 트리를 못 훑었다")
        }
        var withRequire: [(String, String)] = []
        for case let url as URL in en where ["vert", "frag", "h", "geom"].contains(url.pathExtension) {
            guard let d = fm.contents(atPath: url.path), let s = String(data: d, encoding: .utf8),
                  s.contains("#require") else { continue }
            withRequire.append((url.lastPathComponent, s))
        }
        XCTAssertEqual(withRequire.count, 8,
                       "동봉 `#require` 도달이 8건이 아니다: \(withRequire.map(\.0).sorted())")
        for (name, src) in withRequire {
            for lighting in [0, 1] {
                let out = ShaderPreprocessor.preprocess(src, combos: ["LIGHTING": lighting])
                XCTAssertFalse(out.isEmpty, "\(name)[LIGHTING=\(lighting)] 전처리가 거부됐다")
                let ns = out as NSString
                XCTAssertNil(Self.requireDirectiveRe.firstMatch(
                    in: out, range: NSRange(location: 0, length: ns.length)),
                    "\(name)[LIGHTING=\(lighting)] 에 지시문이 남았다")
            }
        }
    }

    /// **"소비만 하면 조용히 틀린 그림이 되는가" 에 대한 반대 방향 못박기.**
    ///
    /// 걱정의 형태는 이렇다 — 지시문 줄을 삼키면 `PerformLighting_V1(...)` **호출부만 남고 정의가
    /// 없어진다**. 그래서 여기서 정확히 그것을 단정한다: `LIGHTING != 0` 이면 호출부는 방출
    /// MSL 에 **그대로 남아야 한다.** 남아 있으면 Metal 컴파일이 확정 실패하고 이펙트가 폴백한다
    /// = 조용하지 않다. 호출부가 사라지는 쪽이야말로 조용한 오답이다(라이팅이 통째로 빠진 그림이
    /// 컴파일에 성공한다) — 이 테스트는 그 퇴행을 막는다.
    ///
    /// 실측 근거 둘:
    ///  1. 소비 분기 도입 전후로 동봉 239쌍 × 3구성 = **717 구성의 MSL 지문이 전건 동일**하다
    ///     (FNV-1a). 즉 소비는 오늘의 방출물에 대해 **무동작**이라 새 오답을 만들 수 없다.
    ///     (`#require` 줄은 종전에도 MSL 에 안 갔다 — `GLSLTranslator.swift:2059` 의 조립부가
    ///     파스된 선언·함수만 싣기 때문. 전처리 출력에는 남아 있었고 그건 형제 게이트가 잡는다.)
    ///  2. `GLSLBundledShaderRegressionTests.knownGapsSweep["엔진 주입 함수"]` 가 8 셰이더를
    ///     **양방향 집합 일치**로 못 박는다 — 호출부가 조용히 사라지면 그쪽이 먼저 터진다.
    func testLightingCallSiteSurvivesSoTheFailureStaysLoud() throws {
        guard let root = GLSLBundledShaderRegressionTests.assetsRoot() else { throw XCTSkip("WAPLE_WE_ASSETS 미지정") }
        let base = "effects/fluidsimulation/shaders/effects/fluidsimulation_combine"
        let fm = FileManager.default
        func read(_ rel: String) -> String? {
            guard let d = fm.contents(atPath: root.appendingPathComponent(rel).path) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        guard let vert = read(base + ".vert"), let frag = read(base + ".frag") else {
            return XCTFail("동봉 fluidsimulation_combine 쌍을 못 읽었다")
        }
        let include: (String) -> String? = { h in
            read("effects/fluidsimulation/shaders/" + h) ?? read("shaders/" + h) ?? BuiltinShaderIncludes.lookup(h)
        }
        // LIGHTING=0 — 실물도 주입하지 않는다. 호출부도 `#if` 로 잘려 나가므로 그림이 완전히 일치한다.
        let off = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag,
                                                         combos: ["LIGHTING": 0], include: include))
        XCTAssertFalse(off.msl.contains("PerformLighting_V1"), "LIGHTING=0 에서는 호출부 자체가 없어야 한다")
        // LIGHTING=1 — 실물은 여기서 씬 라이트 수만큼 언롤한 본문을 주입한다. 우리는 못 한다.
        // 그러면 호출부는 **반드시 남아 있어야** 컴파일이 실패하고 폴백한다.
        let on = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag,
                                                        combos: ["LIGHTING": 1], include: include))
        XCTAssertTrue(on.msl.contains("PerformLighting_V1("),
                      "LIGHTING=1 인데 호출부가 사라졌다 — 라이팅 없는 그림이 조용히 컴파일된다")
        XCTAssertFalse(on.msl.contains("float3 PerformLighting_V1("),
                       "정의를 주입하기 시작했다면 이 테스트와 knownGaps 를 같이 고쳐라")
    }

    // MARK: - G2: `#if` 식 문법 8종

    /// `%` · 단일 `&`/`|`/`^` · `~` · 시프트 · 16진/접미 리터럴 — 종전 전량 거부(nil)에서 평가로.
    func testPreviouslyRefusedOperatorsNowEvaluate() {
        XCTAssertEqual(ExprEval.evalChecked("A % 2", defines: ["A": 7]), 1)
        XCTAssertEqual(ExprEval.evalChecked("A & 6", defines: ["A": 3]), 2)
        XCTAssertEqual(ExprEval.evalChecked("A | 8", defines: ["A": 3]), 11)
        XCTAssertEqual(ExprEval.evalChecked("A ^ 1", defines: ["A": 3]), 2)
        XCTAssertEqual(ExprEval.evalChecked("~A", defines: ["A": 0]), -1)
        XCTAssertEqual(ExprEval.evalChecked("A << 3", defines: ["A": 1]), 8)
        XCTAssertEqual(ExprEval.evalChecked("A >> 1", defines: ["A": 8]), 4)
        XCTAssertEqual(ExprEval.evalChecked("-8 >> 1", defines: [:]), -4, "실물은 `sar` = 산술 시프트")
        XCTAssertEqual(ExprEval.evalChecked("0x10", defines: [:]), 16)
        XCTAssertEqual(ExprEval.evalChecked("0X1f", defines: [:]), 31)
        XCTAssertEqual(ExprEval.evalChecked("1u", defines: [:]), 1)
        XCTAssertEqual(ExprEval.evalChecked("2UL", defines: [:]), 2)
        XCTAssertEqual(ExprEval.evalChecked("3f", defines: [:]), 3, "실물 접미 집합은 u/f/l 셋이다")
        XCTAssertEqual(ExprEval.evalChecked("+5", defines: [:]), 5, "실물 단항 `+`(0x140167c29)")
    }

    /// 우선순위 사슬이 실물(=C)과 같은가. 각 줄은 **뭉쳐 있으면 다른 답이 나오는** 식이다.
    func testPrecedenceChainMatchesEngine() {
        // `|` < `^` < `&` < `==` — 뭉치면 (1|2)^(3&1) 같은 오결합이 난다.
        XCTAssertEqual(ExprEval.evalChecked("1 | 2 ^ 3 & 1", defines: [:]), 1 | (2 ^ (3 & 1)))
        // `==`/`!=` 가 비교보다 **느슨**하다(0x140167680 이 0x140167850 을 부른다).
        // 종전 Waple 은 둘을 한 단계로 뭉쳐 좌결합했다 — 이 식이 정확히 갈리는 자리다:
        //   종전: ((2 == 1) < 1) = (0 < 1) = 1     실물/C: 2 == (1 < 1) = 2 == 0 = 0
        XCTAssertEqual(ExprEval.evalChecked("2 == 1 < 1", defines: [:]), 0)
        // 시프트가 비교보다 촘촘하고 덧셈보다 느슨하다(0x1401679d0 → 0x140167ad0).
        XCTAssertEqual(ExprEval.evalChecked("1 << 2 + 1", defines: [:]), 8, "1 << (2+1)")
        XCTAssertEqual(ExprEval.evalChecked("1 << 2 < 8", defines: [:]), 1, "(1<<2) < 8")
        // `&&`/`||` 는 비트 연산보다 느슨하다.
        XCTAssertEqual(ExprEval.evalChecked("0 || 1 & 2", defines: [:]), 0, "0 || (1&2) → 0")
        XCTAssertEqual(ExprEval.evalChecked("A % 3 == 1", defines: ["A": 7]), 1)
    }

    /// 실물 32비트 규약: 시프트량은 **부호 없는** `cmp ebp,0x1f; ja` 로 걸러 31 초과·음수면 0
    /// (0x140167a8e). 비트 연산·`~` 는 `eax` 폭이라 절단된다. 0 나눗셈/나머지는 0(0x140167bcc).
    func testEngine32BitAndGuardSemantics() {
        XCTAssertEqual(ExprEval.evalChecked("1 << 32", defines: [:]), 0)
        XCTAssertEqual(ExprEval.evalChecked("1 << 31", defines: [:]), Int(Int32.min))
        XCTAssertEqual(ExprEval.evalChecked("1 << -1", defines: [:]), 0, "음수 시프트량도 0(부호 없는 비교)")
        XCTAssertEqual(ExprEval.evalChecked("1 >> 64", defines: [:]), 0)
        XCTAssertEqual(ExprEval.evalChecked("A % 0", defines: ["A": 7]), 0)
        XCTAssertEqual(ExprEval.evalChecked("A / 0", defines: ["A": 7]), 0)
        XCTAssertEqual(ExprEval.evalChecked("0xFFFFFFFF", defines: [:]), -1, "32비트 누적 랩(`esi`)")
        XCTAssertEqual(ExprEval.evalChecked("~0xFFFFFFFF", defines: [:]), 0)
    }

    /// **거부 규약은 유지된다** — 넓힌 것은 "아는 문법"이지 "모르면 아무거나"가 아니다.
    func testStillRefusesWhatEngineGrammarDoesNotCover() {
        // 실물 렉서에도 삼항이 없다(`?`/`:` 는 "그 외 문자" 코드 0x19).
        XCTAssertNil(ExprEval.evalChecked("A ? 1 : 0", defines: ["A": 1]))
        XCTAssertNil(ExprEval.evalChecked("1 0", defines: [:]), "잔여 토큰")
        XCTAssertNil(ExprEval.evalChecked("1e5", defines: [:]), "수 + 식별자 = 잔여 토큰")
        XCTAssertNil(ExprEval.evalChecked("1.5", defines: [:]), "`.` 는 모르는 문자로 남긴다([미해결])")
        XCTAssertNil(ExprEval.evalChecked("A @ 1", defines: ["A": 1]))
        // 파이프라인 레벨: 활성 분기의 미지원 식은 전처리 거부(= 번역 실패 → 폴백).
        XCTAssertNil(ShaderPreprocessor.preprocessStrict("#if A ? 1 : 0\nyes\n#endif", combos: ["A": 1]))
    }

    /// `#define X 0x10` 은 이제 suspect 가 아니라 **값**이다 — 종전엔 이 define 을 참조하는
    /// `#if` 가 통째로 거부돼 셰이더 하나가 폴백했다. 본문 텍스트 치환은 종전 그대로.
    func testHexAndSuffixDefinesEvaluateInIf() {
        let src = """
        #define MASK 0x0C
        #define ONE 1u
        #define PAREN (0x10)
        #if (MASK & 8) && ONE && PAREN == 16
        yes
        #else
        no
        #endif
        int m = MASK;
        """
        let r = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(r.contains("yes"), r)
        XCTAssertFalse(r.contains("\nno\n"), r)
        XCTAssertTrue(r.contains("int m = 0x0C;"), "본문 치환은 원문 텍스트 그대로: \(r)")
        // 소수 리터럴 define 은 여전히 거부 대상(위 [미해결]).
        XCTAssertNil(ShaderPreprocessor.preprocessStrict("#define K 1.5\n#if K\nyes\n#endif", combos: [:]))
    }

    /// 워크샵 시나리오 — G2 가 없으면 이 셰이더는 번역 nil 이 되어 이펙트가 통째로 사라진다.
    func testWorkshopStyleBitmaskShaderTranslates() throws {
        let vert = "varying vec2 v_TexCoord;\nvoid main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }"
        let frag = """
        varying vec2 v_TexCoord;
        void main() {
        #if (FLAGS & 2) != 0
            gl_FragColor = vec4(0.3359375);
        #else
            gl_FragColor = vec4(v_TexCoord, 0.0, 1.0);
        #endif
        }
        """
        let on = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: ["FLAGS": 3]))
        XCTAssertTrue(on.msl.contains("0.3359375"), on.msl)
        let off = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: ["FLAGS": 1]))
        XCTAssertFalse(off.msl.contains("0.3359375"), off.msl)
    }

    // MARK: - G3: 콤보 키 대문자화

    private var uppercaseProbeVert: String {
        "varying vec2 v_TexCoord;\nvoid main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }"
    }
    private var uppercaseProbeFrag: String {
        """
        varying vec2 v_TexCoord;
        void main() {
        #ifdef NORMALMAP
            gl_FragColor = vec4(0.1015625);
        #elif SPRITESHEET == 2
            gl_FragColor = vec4(0.2265625);
        #else
            gl_FragColor = vec4(v_TexCoord, 0.0, 1.0);
        #endif
        }
        """
    }

    /// 실물 0x140154599 는 **선언 유무와 무관하게** 콤보 키를 대문자화한다. 위 프래그먼트에는
    /// `[COMBO]` 선언이 하나도 없다 — 종전 `resolvePassCombos.canonical()` 의 "선언 집합 안에서만
    /// 접기" 근사가 정확히 못 잡던 형태이고, 저작된 소문자 15종 중 14종이 이 형태다.
    func testLowercaseAuthoredComboKeysReachUppercaseDirectives() throws {
        let a = try XCTUnwrap(GLSLTranslator.translate(vertex: uppercaseProbeVert, fragment: uppercaseProbeFrag,
                                                       combos: ["normalmap": 1]))
        XCTAssertTrue(a.msl.contains("0.1015625"), a.msl)
        let b = try XCTUnwrap(GLSLTranslator.translate(vertex: uppercaseProbeVert, fragment: uppercaseProbeFrag,
                                                       combos: ["SpriteSheet": 2]))
        XCTAssertTrue(b.msl.contains("0.2265625"), b.msl)
    }

    /// 이미 대문자로 저작된 키는 **비트동일**이어야 한다(무회귀의 형태).
    func testUppercaseKeysAreUnchanged() {
        XCTAssertEqual(GLSLTranslator.uppercasedComboKeys(["NORMALMAP": 1, "TEX1FORMAT": 8]),
                       ["NORMALMAP": 1, "TEX1FORMAT": 8])
    }

    /// 충돌 규약: 접었을 때 대문자 철자가 이미 있으면 그쪽이 이긴다.
    /// 근거는 실물 `#define` 방출 순서(값 콤보 0x14016c400 → 텍스처 유래 0x14016c800, 뒤가 승)이고
    /// Waple 에서 텍스처 유래 키는 셰이더 어노테이션 철자(전건 대문자)로 들어온다.
    func testUppercaseKeyWinsOnFold() {
        XCTAssertEqual(GLSLTranslator.uppercasedComboKeys(["normalmap": 0, "NORMALMAP": 1]), ["NORMALMAP": 1])
        XCTAssertEqual(GLSLTranslator.uppercasedComboKeys(["normalmap": 0]), ["NORMALMAP": 0])
    }

    /// 동봉 자산에는 소문자 선언이 **한 건도 없다** — G3 이 동봉 번역 결과를 바꾸지 않는다는
    /// 주장의 근거를 자산에서 직접 확인한다(자산이 바뀌면 여기서 먼저 터진다).
    func testBundledComboDeclarationsAreAllUppercase() throws {
        guard let root = GLSLBundledShaderRegressionTests.assetsRoot() else { throw XCTSkip("WAPLE_WE_ASSETS 미지정") }
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("자산 트리를 못 훑었다")
        }
        var declared = Set<String>()
        var sampler = Set<String>()
        for case let url as URL in en where ["vert", "frag", "h", "geom"].contains(url.pathExtension) {
            guard let d = fm.contents(atPath: url.path), let s = String(data: d, encoding: .utf8) else { continue }
            declared.formUnion(ShaderPreprocessor.parseComboDefaults(s).keys)
            sampler.formUnion(GLSLTranslator.samplerCombos(s).values)
        }
        XCTAssertGreaterThan(declared.count, 50, "선언을 이만큼도 못 모으면 경로가 틀린 것(2026-08-21 실측 67종)")
        let lowDecl = declared.filter { $0 != $0.uppercased() }
        let lowSampler = sampler.filter { $0 != $0.uppercased() }
        XCTAssertTrue(lowDecl.isEmpty, "소문자 [COMBO] 선언이 생겼다: \(lowDecl.sorted())")
        XCTAssertTrue(lowSampler.isEmpty, "소문자 샘플러 combo 어노테이션이 생겼다: \(lowSampler.sorted())")
    }
}
