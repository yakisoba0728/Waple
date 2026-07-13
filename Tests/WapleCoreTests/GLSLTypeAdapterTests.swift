import XCTest
@testable import WapleCore

/// Stage-3 phase 2: HLSL-관용 벡터 크기 혼합을 MSL 이 허용하도록 절단/브로드캐스트 삽입(실물 4클래스).
final class GLSLTypeAdapterTests: XCTestCase {
    private func env(_ vars: [String: Int] = [:], fns: [String: Int] = [:],
                     params: [String: [Int]] = [:]) -> GLSLTypeAdapter.Env {
        GLSLTypeAdapter.Env(vars: vars, functions: fns, functionParams: params)
    }

    func testDeclarationTruncation() {
        // 실물: vec3 finalColor = vec4(...) — 초기화 절단.
        let out = GLSLTypeAdapter.adapt(body: "vec3 c = vec4(r, g, b, 0.1);", env: env())
        XCTAssertEqual(out, "vec3 c = (vec4(r, g, b, 0.1)).xyz;")
        // 실물: float pointer = vec2식 — 스칼라 절단.
        let out2 = GLSLTypeAdapter.adapt(body: "float p = pt * spd;", env: env(["pt": 2, "spd": 1]))
        XCTAssertEqual(out2, "float p = (pt * spd).x;")
    }

    func testBinaryMismatchTruncatesLarger() {
        // 실물 clipping_mask: vec2식 - vec4식 → HLSL 은 작은 쪽으로.
        let out = GLSLTypeAdapter.adapt(body: "vec2 uv = a.xy - (k * t + p);",
                                        env: env(["a": 4, "k": 1, "t": 4, "p": 1]))
        XCTAssertEqual(out, "vec2 uv = a.xy - ((k * t + p)).xy;")
        // 브로드캐스트(스칼라×벡터)는 무변경.
        let out2 = GLSLTypeAdapter.adapt(body: "vec2 q = uv * 2.0;", env: env(["uv": 2]))
        XCTAssertEqual(out2, "vec2 q = uv * 2.0;")
    }

    func testSwizzleLvalueAndAssignment() {
        let out = GLSLTypeAdapter.adapt(body: "c.rgb = s;", env: env(["c": 4, "s": 4]))
        XCTAssertEqual(out, "c.rgb = (s).xyz;")
        let out2 = GLSLTypeAdapter.adapt(body: "u += v;", env: env(["u": 2, "v": 4]))
        XCTAssertEqual(out2, "u += (v).xy;")
    }

    func testKnownCallsAndLocals() {
        // texSample2D → vec4; 지역 선언이 env 에 등록돼 후속 문장에 반영.
        let body = """
        vec4 s = texSample2D(g_Texture0, uv);
        vec2 d = s;
        """
        let out = GLSLTypeAdapter.adapt(body: body, env: env(["uv": 2]))
        XCTAssertTrue(out.contains("vec2 d = (s).xy;"), out)
        // 헬퍼 반환 크기.
        let out2 = GLSLTypeAdapter.adapt(body: "vec2 q = noise3(x);", env: env(["x": 1], fns: ["noise3": 3]))
        XCTAssertEqual(out2, "vec2 q = (noise3(x)).xy;")
    }

    func testCutoutVignetteVectorCoercions() {
        // wallpaper_dev cutout_vignette: sample vec4 assigned to vec3, then vec3 mixed with vec2 arithmetic.
        let body = """
        vec3 color = texSample2D(g_Texture0, uv);
        vec2 delta = color - uv;
        """
        let out = GLSLTypeAdapter.adapt(body: body, env: env(["uv": 2]))
        XCTAssertTrue(out.contains("vec3 color = (texSample2D(g_Texture0, uv)).xyz;"), out)
        XCTAssertTrue(out.contains("vec2 delta = (color).xy - uv;"), out)
    }

    func testControlFlowAndUnknownsPassThrough() {
        // 미지 심볼(크기 0)은 무개입; for/if 구조 보존.
        let body = """
        for (int i = 0; i < 4; ++i) {
            if (mystery(i) > 0.5) { total += weights[i]; }
        }
        return total;
        """
        let out = GLSLTypeAdapter.adapt(body: body, env: env(["total": 1, "weights": 0]))
        XCTAssertEqual(out, body)
    }

    func testFloatModRewrittenToFmod() {
        // MSL % 는 정수 전용 — float 피연산자는 fmod 로(실물 Simple_Audio_Bars).
        let out = GLSLTypeAdapter.adapt(body: "float y = x % 4;", env: env(["x": 1]))
        XCTAssertEqual(out, "float y = fmod(x, 4.0);")
        // 확실한 int 끼리는 유지.
        let out2 = GLSLTypeAdapter.adapt(body: "int i = 5;\nint j = i % 2;", env: env())
        XCTAssertTrue(out2.contains("i % 2"), out2)
    }

    func testCallArgsCoercedToParamSizes() {
        // 실물 shimmer: rotateVec2(vec2 uv, float a) 에 vec4 varying 전달 — HLSL 은 절단.
        let out = GLSLTypeAdapter.adapt(body: "vec2 r = rotateVec2(v_TexCoord, 1.0);",
                                        env: env(["v_TexCoord": 4], fns: ["rotateVec2": 2],
                                                 params: ["rotateVec2": [2, 1]]))
        XCTAssertEqual(out, "vec2 r = rotateVec2((v_TexCoord).xy, 1.0);")
    }

    func testSwizzleChainCollapsed() {
        // 실물 water_caustics: v_TexCoord.xy.zw — 직전 스위즐을 대체(.zw 를 원본에 적용).
        let out = GLSLTypeAdapter.adapt(body: "float m = tex(v_TexCoord.xy.zw);",
                                        env: env(["v_TexCoord": 4]))
        XCTAssertEqual(out, "float m = tex(v_TexCoord.zw);")
    }

    func testTruncatedInputDoesNotCrash() {
        // 잘린 셰이더(for-init 에서 토큰 소진) → advance() 가 EOF 를 넘어 인덱싱하던 배열 범위 밖 트랩.
        // 번역기는 제3자(신뢰 불가) 셰이더를 파싱하므로 마운트 중 앱 크래시로 이어졌다.
        XCTAssertEqual(GLSLTypeAdapter.adapt(body: "for(", env: env()), "for(")
        XCTAssertEqual(GLSLTypeAdapter.adapt(body: "vec2 a = b +", env: env(["b": 2])), "vec2 a = b +")
    }

    func testOverlongSwizzleDoesNotCrash() {
        // 5성분 스위즐(비정상 GLSL)을 vec4 로 절단 시 ["",".x",".xy",".xyz"][want=4] 가 범위 밖 트랩하던 회귀.
        let out = GLSLTypeAdapter.adapt(body: "vec4 d = foo.xyzwx;", env: env(["foo": 4]))
        XCTAssertTrue(out.contains("foo.xyzwx"), out)  // 크래시 없이 통과
    }

    // S5: Pratt 파서는 세 갈래로 재귀한다 — 괄호/함수인자/첨자(primary↔expression), 단항 체인(unary
    // 자기재귀), 삼항 체인(ternary 자기재귀). 셋 다 병리적 중첩에서 스택 오버플로 없이 그레이스풀해야
    // 한다(캡 256, exprDepth 공유). 5000 은 캡을 한참 초과하므로 각 케이스 모두 크래시만 없으면 통과.
    func testDeepParenNestingDoesNotCrash() {
        let deep = String(repeating: "(", count: 5000) + "x" + String(repeating: ")", count: 5000) + ";"
        _ = GLSLTypeAdapter.adapt(body: deep, env: env(["x": 1]))
    }

    func testDeepUnaryChainDoesNotCrash() {
        let deep = String(repeating: "!", count: 5000) + "x;"
        _ = GLSLTypeAdapter.adapt(body: deep, env: env(["x": 1]))
    }

    func testDeepTernaryChainDoesNotCrash() {
        let deep = String(repeating: "x?y:", count: 5000) + "z;"
        _ = GLSLTypeAdapter.adapt(body: deep, env: env(["x": 1, "y": 1, "z": 1]))
    }

    // S5(문장 레벨): statements ⇄ statement 상호재귀도 병리적 `{{{…}}}` 중첩에서 스택 오버플로 없이
    // 끝나야 한다(식 파서와 별개 벡터). 캡 초과 시 한 토큰씩 소비하며 전진하므로 크래시도 무한루프도 없다
    // — 이 테스트는 반환하기만 하면(행 없음) 통과.
    func testDeepBlockNestingDoesNotCrash() {
        let deep = String(repeating: "{", count: 5000) + String(repeating: "}", count: 5000)
        _ = GLSLTypeAdapter.adapt(body: deep, env: env())
    }

    // S5(문장 무전진 폴백): 253~255개 `{` 뒤 비선언 식 토큰(` x`) — statement 자체 캡(depth≥257)은
    // 통과하나, 그 토큰을 소비하는 primary 가 식 캡(depth≥257)에 걸려 무소비 폴백 → statement 가
    // 아무 토큰도 못 삼키고 반환 → statements 루프가 같은 토큰을 영원히 재시도하던 행(hang, CPU 폭주).
    // statements 의 무전진 감지 강제소비로 종료 보장(전 브레이스 테스트는 매 statement 가 `{`/`}` 를
    // 소비하므로 이 창을 못 잡는다). 종료 자체가 요점.
    func testDeepBlockThenBareExpressionTerminates() {
        let input = String(repeating: "{", count: 255) + " x"
        let out = GLSLTypeAdapter.adapt(body: input, env: env(["x": 1]))
        XCTAssertFalse(out.isEmpty)   // 여기 도달 = 행 없이 종료(값은 베스트에포트 패스스루)
    }

    // S5(문장 레벨): 정상 2중 블록(≪ 256)은 캡의 영향 없이 내부 선언 절단이 그대로 삽입돼야 한다(무회귀).
    func testModerateBlockNestingStillTranslates() {
        let out = GLSLTypeAdapter.adapt(body: "{ { vec2 a = vec4(1.0, 2.0, 3.0, 4.0); } }", env: env())
        XCTAssertEqual(out, "{ { vec2 a = (vec4(1.0, 2.0, 3.0, 4.0)).xy; } }")
    }

    // S5: 정상 규모 중첩(≪ 256)은 캡의 영향을 받지 않고 절단이 정확히 삽입돼야 한다(무회귀).
    func testModerateNestingStillAdaptsCorrectly() {
        let out = GLSLTypeAdapter.adapt(body: "vec2 r = (((a)));", env: env(["a": 4]))
        XCTAssertEqual(out, "vec2 r = ((((a)))).xy;")   // coerce 가 절단용 괄호 한 겹을 더 씌운다
        let out2 = GLSLTypeAdapter.adapt(body: String(repeating: "!", count: 5) + "x;", env: env(["x": 1]))
        XCTAssertEqual(out2, String(repeating: "!", count: 5) + "x;")
    }

    func testDotLengthScalarAndTernary() {
        let out = GLSLTypeAdapter.adapt(body: "float d = dot(a, b);", env: env(["a": 3, "b": 3]))
        XCTAssertEqual(out, "float d = dot(a, b);")
        // 삼항 분기 크기 불일치 → 큰 쪽 절단.
        let out2 = GLSLTypeAdapter.adapt(body: "vec2 r = flag ? big : small;",
                                         env: env(["flag": 1, "big": 4, "small": 2]))
        XCTAssertEqual(out2, "vec2 r = flag ? (big).xy : small;")
    }
}
