import XCTest
import Metal
@testable import WapleCore

/// 잔여 스킵 소탕 회귀 가드: GLSL→MSL 번역기가 실물에서 컴파일 실패했던 구문을 재현·컴파일한다.
/// (depthparallax 의 CAST3X3(mat4), bokeh 의 전역 const 배열 생성자.)
final class TranslatorResidualsTests: XCTestCase {
    private func compile(_ msl: String) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        _ = try device.makeLibrary(source: msl, options: nil)
    }

    /// depthparallax: g_EffectTextureProjectionMatrixInverse(mat4) 는 엔진 행렬로 분류되어야 하고
    /// (float4 머티리얼 파라미터 아님), CAST3X3 → we_cast3x3(절단 헬퍼) 로 MSL 컴파일 성공.
    func testCast3x3OfMat4EngineUniform() throws {
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform mat4 g_EffectTextureProjectionMatrixInverse;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_Dir;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            mat3 rot = CAST3X3(g_EffectTextureProjectionMatrixInverse);
            v_Dir = normalize(mul(vec3(1.0, 0.0, 0.0), rot).xy);
        }
        """
        let frag = """
        varying vec2 v_Dir;
        uniform sampler2D g_Texture0; // {"hidden":true}
        void main() { gl_FragColor = texSample2D(g_Texture0, v_Dir * 0.5 + 0.5); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertFalse(t.materialParams.contains { $0.glslName == "g_EffectTextureProjectionMatrixInverse" },
                       "엔진 행렬이 float4 머티리얼 파라미터로 오분류됨")
        XCTAssertTrue(t.msl.contains("we_cast3x3"), "CAST3X3 이 절단 헬퍼로 위임되지 않음")
        try compile(t.msl)
    }

    /// bokeh: 전역 const 배열 `vec2[N](...)` 생성자는 MSL brace-init `{ ... }` 로 변환되어야 컴파일된다.
    func testGlobalConstArrayConstructor() throws {
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        const vec2 kern[3] = vec2[3](vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0));
        void main() {
            vec2 acc = vec2(0.0);
            for (int i = 0; i < 3; i++) { acc += kern[i]; }
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord + acc * 0.01);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertFalse(t.msl.contains("float2[3]("), "GLSL 배열 생성자 구문이 남아있음")
        XCTAssertTrue(t.msl.contains("constant float2"), "전역 const 배열이 방출되지 않음")
        try compile(t.msl)
    }

    /// 회귀 가드: CAST3X3(스칼라) = 대각 mat3(GLSL 단일 스칼라 생성자) 도 컴파일된다.
    func testCast3x3OfScalar() throws {
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        varying float v_X;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            mat3 m = CAST3X3(1.0);
            v_X = m[0][0];
        }
        """
        let frag = """
        varying float v_X;
        void main() { gl_FragColor = vec4(v_X); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        try compile(t.msl)
    }
}
