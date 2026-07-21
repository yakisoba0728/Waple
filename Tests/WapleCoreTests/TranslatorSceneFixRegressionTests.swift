import XCTest
@testable import WapleCore

/// 씬 구현 갭 수정 회귀 — WapleCore 번역기(전처리기/타입어댑터/번역기), F610~F618.
/// 각 테스트는 수정 전 red(실패)임을 확인한 뒤 수정으로 그린화했다.
final class TranslatorSceneFixRegressionTests: XCTestCase {
    private let plainVert = """
    attribute vec3 a_Position;
    void main() { gl_Position = vec4(a_Position, 1.0); }
    """

    private func env(_ vars: [String: Int]) -> GLSLTypeAdapter.Env {
        GLSLTypeAdapter.Env(vars: vars)
    }

    // MARK: - F610 (S-14): 미지원 #if 식이라도 양 분기가 텍스트로 동일하면 관용

    // 실물 lens_distorsion#0(2904908532): `#if g_Texture0Resolution.x < g_Texture0Resolution.y` 는
    // uniform 멤버 참조라 전처리 평가 불가(ExprEval `.` 미지원) — 그러나 양 분기가 완전 동일해
    // 어느 분기든 출력이 같다. 종전엔 전처리 거부로 이펙트 전체 폐기(순손해).
    func testF610UnsupportedIfWithIdenticalBranchesTolerated() {
        let src = """
        uniform vec4 g_Texture0Resolution;
        #if g_Texture0Resolution.x < g_Texture0Resolution.y
        #define ratioDiff (vec2(g_ratio, 1.0))
        #else
        #define ratioDiff (vec2(g_ratio, 1.0))
        #endif
        vec2 t = ratioDiff;
        """
        let out = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertFalse(out.isEmpty, "동일 분기 #if 는 거부(폐기)하면 안 된다")
        XCTAssertFalse(out.contains("#if"), out)
        XCTAssertTrue(out.contains("(vec2(g_ratio, 1.0))"), out)   // 매크로 확장 결과 잔존
    }

    // 분기가 다륵면 어떤 분기든 오역 가능 — 종전대로 거부 유지("오역보다 폴터").
    func testF610UnsupportedIfWithDifferentBranchesStillRefused() {
        let src = """
        #if g_Texture0Resolution.x < g_Texture0Resolution.y
        #define ratioDiff (vec2(g_ratio, 1.0))
        #else
        #define ratioDiff vec2(1.0)
        #endif
        """
        XCTAssertNil(ShaderPreprocessor.preprocessStrict(src, combos: [:]))
        XCTAssertEqual(ShaderPreprocessor.preprocess(src, combos: [:]), "")
    }

    // 다분기(#elif)는 비교 범위가 복잡해 보수적 거부 유지.
    func testF610UnsupportedIfWithElifStillRefused() {
        let src = """
        #if g_Texture0Resolution.x < g_Texture0Resolution.y
        a
        #elif FOO
        a
        #else
        a
        #endif
        """
        XCTAssertNil(ShaderPreprocessor.preprocessStrict(src, combos: [:]))
    }

    // MARK: - F611 (S-15): #if/#elif 식 후행 `;` 절단

    // 실물 simple_gradient_audio_bar(3409595232·3417957645·3461168300): `#elif AUDIOSAMPLES == 32;`
    // 후행 세미콜론 — C/WE 전처리기는 관용하나 ExprEval 이 미지원 문자로 거부해 셰이더 폐기였음.
    func testF611TrailingSemicolonInElif() {
        let src = """
        #if AUDIOSAMPLES == 16
        float inv = 0.0625;
        #elif AUDIOSAMPLES == 32;
        float inv = 0.03125;
        #elif AUDIOSAMPLES == 64;
        float inv = 0.015625;
        #endif
        """
        let out32 = ShaderPreprocessor.preprocess(src, combos: ["AUDIOSAMPLES": 32])
        XCTAssertTrue(out32.contains("0.03125"), out32)
        XCTAssertFalse(out32.contains("0.0625"), out32)
        let out64 = ShaderPreprocessor.preprocess(src, combos: ["AUDIOSAMPLES": 64])
        XCTAssertTrue(out64.contains("0.015625"), out64)
        let out16 = ShaderPreprocessor.preprocess(src, combos: ["AUDIOSAMPLES": 16])
        XCTAssertTrue(out16.contains("0.0625"), out16)
    }

    func testF611TrailingSemicolonInIf() {
        let src = "#if MASK == 1;\nyes\n#else\nno\n#endif"
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["MASK": 1]).contains("yes"))
        XCTAssertTrue(ShaderPreprocessor.preprocess(src, combos: ["MASK": 0]).contains("no"))
    }

    // MARK: - F612 (S-16): 삼항 스칼라:벡터는 스플랫(무개입) — 절단 금지

    // `flag ? 0.0 : v3` — HLSL/MSL 모두 스칼라를 벡터로 스플랫(결과 vec3, MSL 실기 컴파일 확인).
    // 종전엔 큰 쪽을 무조건 절단해 `flag ? 0.0 : (v3).x` 로 오역 — 컴파일 성공·값 조용히 틀어지는
    // 유일한 silent 오역 클래스.
    func testF612TernaryScalarVectorNotTruncated() {
        let e = env(["flag": 1, "v3": 3])
        XCTAssertEqual(GLSLTypeAdapter.adapt(body: "vec3 c = flag ? 0.0 : v3;", env: e),
                       "vec3 c = flag ? 0.0 : v3;")
        XCTAssertEqual(GLSLTypeAdapter.adapt(body: "vec3 c = flag ? v3 : 0.0;", env: e),
                       "vec3 c = flag ? v3 : 0.0;")
    }

    // 스칼라 목표 절단은 외부 coerce 가 담당(HLSL 과 동일하게 .x) — 삼항 자체는 벡터 유지.
    func testF612TernaryVectorResultTruncatedByOuterContext() {
        let out = GLSLTypeAdapter.adapt(body: "float f = flag ? 0.0 : v3;", env: env(["flag": 1, "v3": 3]))
        XCTAssertEqual(out, "float f = (flag ? 0.0 : v3).x;")
    }

    // 벡터:벡터 크기 불일치는 종전 규칙(큰 쪽 절단) 유지 — 무회귀.
    func testF612TernaryVectorVectorStillTruncates() {
        let out = GLSLTypeAdapter.adapt(body: "vec2 r = flag ? big : small;",
                                        env: env(["flag": 1, "big": 4, "small": 2]))
        XCTAssertEqual(out, "vec2 r = flag ? (big).xy : small;")
    }

    // MARK: - F613 (S-73): g_Color4 엔진 중립 기본값 봉인

    // g_Color4 = WE 레이어 상수(g_Color 의 vec4 변형) — 엔진 주입값인데 engineNeutralDefault 미등재라
    // 번역 경로 진입 시 padDefault (0,0,0,0) → color*=0 즉시 검정 클래스. 중립값(1,1,1,1)으로 봉인.
    func testF613Color4NeutralDefault() throws {
        let frag = """
        uniform vec4 g_Color4;
        void main() { gl_FragColor = g_Color4; }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        let m = try XCTUnwrap(t.materialParams.first { $0.glslName == "g_Color4" })
        XCTAssertEqual(m.defaultValue, [1, 1, 1, 1])
    }

    // MARK: - F614 (S-74): g_Screen 엔진 심볼 분류 봉인

    // g_Screen = (width, height, width/height) — 미분류 시 머티리얼 팬텀 슬롯(padDefault 0) 강등.
    // g_TexelSize 와 동일하게 texRes[0](이펙트 패스의 tex0=framebuffer=타깃) 근사로 봉인.
    func testF614ScreenClassifiedAsEngine() throws {
        let frag = """
        uniform vec3 g_Screen;
        void main() { gl_FragColor = vec4(g_Screen, 1.0); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertFalse(t.materialParams.contains { $0.glslName == "g_Screen" }, "엔진 분류돼 머티리얼 슬롯에서 빠져야 함")
        XCTAssertTrue(t.msl.contains("eng.texRes[0]"), t.msl)
    }

    // MARK: - F615 (S-77): min/max/clamp 음수 정수 리터럴 승격

    // `max(-1, q)` — `-` 미포함 isIntLiteral 이라 음수 정수가 실수로 승격되지 않아 MSL 혼합
    // 오버로드 모호 LOUD 폴 fallback 클래스.
    func testF615NegativeIntLiteralPromotedInMinMaxClamp() {
        XCTAssertEqual(GLSLTypeAdapter.adapt(body: "float r = max(-1, q);", env: env(["q": 1])),
                       "float r = max(-1.0, q);")
        XCTAssertEqual(GLSLTypeAdapter.adapt(body: "float r = clamp(q, -2, 1);", env: env(["q": 1])),
                       "float r = clamp(q, -2.0, 1.0);")
    }

    // MARK: - F616 (S-78): 본문 내 배열 생성자 `TYPE[N](...)` 재작성

    // 종전엔 파일스코프 const 만 재작성 — 함수 본문 사용은 MSL 문법 오류 LOUD 폴 fallback.
    func testF616InBodyArrayConstructorRewritten() throws {
        let frag = """
        void main() {
            float k[2] = float[2](1.0, 2.0);
            gl_FragColor = vec4(k[0], k[1], 0.0, 1.0);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("float k[2] = { 1.0, 2.0 };"), t.msl)
    }

    // 배열 인덱싱(`k[0]`)은 `]` 뒤 `(` 가 아니라 재작성되지 않아야 함(무회귀).
    func testF616ArrayIndexingNotRewritten() throws {
        let frag = """
        void main() {
            float k[2] = float[2](1.0, 2.0);
            float s = k[0] + k[1];
            gl_FragColor = vec4(s);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("k[0] + k[1]"), t.msl)
    }

    // MARK: - F617 (S-79): 본문 스캔 팬텀 텍스처 슬롯 가드

    // g_Texture3MipMapInfo·g_Texture0Rotation 류 엔진 유니폼 토큰이 본문에 나오면 textureIndex 가
    // 접두 숫자만 읽어 팬텀 슬롯(3/0)이 등록됐다 — 숫자부 전체가 숫자인 g_TextureN 만 슬롯 인정.
    func testF617PhantomTextureSlotNotRegistered() throws {
        let frag = """
        uniform sampler2D g_Texture0;
        uniform vec4 g_Texture3MipMapInfo;
        void main() {
            gl_FragColor = texSample2D(g_Texture0, vec2(g_Texture3MipMapInfo.x, 0.0));
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertEqual(t.textureSlots, [0])
    }

    // MARK: - F618 (S-80): g_PointerState 어댑터 크기 환경 등재

    // replacement/capture 타입은 float4 로 정합이나 어댑터 크기 환경에 없어(0=불투명) 절단 추론 물력.
    // `vec3 c = g_PointerState;` 가 절단 삽입되려면 크기 4 등재가 필요.
    func testF618PointerStateSizeKnownToAdapter() throws {
        let frag = """
        uniform vec4 g_PointerState;
        void main() { vec3 c = g_PointerState; gl_FragColor = vec4(c, 1.0); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("eng.pointerLastAndPad.z, 0.0)).xyz"), t.msl)
    }
}
