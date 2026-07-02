import XCTest
@testable import WapleCore

/// Stage-3 phase 2: HLSL-관용 벡터 크기 혼합을 MSL 이 허용하도록 절단/브로드캐스트 삽입(실물 4클래스).
final class GLSLTypeAdapterTests: XCTestCase {
    private func env(_ vars: [String: Int] = [:], fns: [String: Int] = [:]) -> GLSLTypeAdapter.Env {
        GLSLTypeAdapter.Env(vars: vars, functions: fns)
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

    func testDotLengthScalarAndTernary() {
        let out = GLSLTypeAdapter.adapt(body: "float d = dot(a, b);", env: env(["a": 3, "b": 3]))
        XCTAssertEqual(out, "float d = dot(a, b);")
        // 삼항 분기 크기 불일치 → 큰 쪽 절단.
        let out2 = GLSLTypeAdapter.adapt(body: "vec2 r = flag ? big : small;",
                                         env: env(["flag": 1, "big": 4, "small": 2]))
        XCTAssertEqual(out2, "vec2 r = flag ? (big).xy : small;")
    }
}
