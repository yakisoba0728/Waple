import XCTest
@testable import WapleCore

/// WE 임베디드 GLSL→HLSL 심(wallpaper64.exe, analysis/strings/shader-strings.txt)과의 갭 6종 핀.
/// 전부 종전엔 번역 실패 → 손-포팅 폴터이던 입력이라 기존 성공 셰이더 출력은 불변이어야 한다
/// (무회귀 입증 = 기존 GLSLTranslatorTests 무수정 통과).
final class GLSLShimGapTests: XCTestCase {
    /// 최소 vertex(모든 테스트 공용) — varying v_TexCoord 하나만 넘긴다.
    private let vert = """
    uniform mat4 g_ModelViewProjectionMatrix;
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    varying vec2 v_TexCoord;
    void main() {
        gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
        v_TexCoord = a_TexCoord;
    }
    """

    // MARK: 1. texLoad2D (RE :66 `#define texLoad2D(s, u, r) s.Load(int3((u) * (r), 0))`)

    func testTexLoad2DRewritesToTextureRead() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform vec4 g_Texture0Resolution;
        void main() {
            vec4 c = texLoad2D(g_Texture0, v_TexCoord, g_Texture0Resolution.xy);
            gl_FragColor = c;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("g_Texture0.read(uint2((in.v_TexCoord) * (eng.texRes[0].xy)))"),
                      "texLoad2D → .read(uint2((u)*(r))): \(t.msl)")
        XCTAssertFalse(t.msl.contains("texLoad2D"))
    }

    // MARK: 2. texSample2DBackBuffer → 비MS 변형 texSample2D 하강 (RE :22, :70-71)

    func testTexSample2DBackBufferLowersToSample() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2DBackBuffer g_Texture0;
        uniform vec4 g_Texture0Resolution;
        void main() {
            vec4 c = texSample2DBackBuffer(g_Texture0, v_TexCoord, g_Texture0Resolution.xy);
            gl_FragColor = c;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertEqual(t.textureSlots, [0], "sampler2DBackBuffer 선언도 texture2d<float> 슬롯으로")
        XCTAssertTrue(t.msl.contains("texture2d<float> g_Texture0"), t.msl)
        XCTAssertTrue(t.msl.contains("g_Texture0.sample("), "비MS 변형 texSample2D(s, u) 하강: \(t.msl)")
        XCTAssertTrue(t.msl.contains("we_uv(in.v_TexCoord))"), t.msl)
        XCTAssertFalse(t.msl.contains("texSample2DBackBuffer"))
        XCTAssertFalse(t.msl.contains("read(uint2"), "MS Load 변형(RE :70)이 아니라 sample 하강(RE :71)")
        XCTAssertFalse(t.msl.contains("texRes[0].xy"), "r 인자는 비MS 변형에서 소비되지 않음")
    }

    // MARK: 3. DECLARE_SAMPLER2D_PARAMETER / MAKE_SAMPLER2D_ARGUMENT (+COMPARE) (RE :59-62)

    func testSamplerParameterMacrosInjectedByPreprocessor() {
        let src = """
        vec4 fetch(DECLARE_SAMPLER2D_PARAMETER(g_Texture0), vec2 uv) {
            return texSample2D(MAKE_SAMPLER2D_ARGUMENT(g_Texture0), uv);
        }
        vec4 fetchCmp(DECLARE_SAMPLER2D_COMPARE_PARAMETER(g_Texture1), vec2 uv) {
            return texSample2D(MAKE_SAMPLER2D_COMPARE_ARGUMENT(g_Texture1), uv);
        }
        """
        let pp = ShaderPreprocessor.preprocess(src, combos: [:])
        // 전개 결과는 Waple 의 텍스처/샘플러 쌍 규약에서 유효한 선언: `sampler2D t` / `t`.
        XCTAssertTrue(pp.contains("vec4 fetch(sampler2D g_Texture0, vec2 uv)"), pp)
        XCTAssertTrue(pp.contains("texSample2D(g_Texture0, uv)"), pp)
        // [2026-08-21] COMPARE 계열은 `sampler2DComparison` 으로 전개된다(종전 `sampler2D`).
        // texSample2DCompare 재작성이 들어오면서 헬퍼 파라미터가 `depth2d<float>` 여야
        // `sample_compare` 가 유효해졌다 — mslType("sampler2DComparison") 참조.
        XCTAssertTrue(pp.contains("vec4 fetchCmp(sampler2DComparison g_Texture1, vec2 uv)"), pp)
        XCTAssertTrue(pp.contains("texSample2D(g_Texture1, uv)"), pp)
        XCTAssertFalse(pp.contains("DECLARE_SAMPLER2D"))
        XCTAssertFalse(pp.contains("MAKE_SAMPLER2D"))
        XCTAssertFalse(pp.contains("SamplerState"), "HLSL 쌍 네이밍(t##SamplerState)은 Waple 조립에 없음")
    }

    /// 소스가 자체 정의하면 주입하지 않는다(CAST* 주입과 같은 우선 규칙).
    func testSamplerParameterMacroRespectsSourceDefinition() {
        let src = """
        #define MAKE_SAMPLER2D_ARGUMENT(t) t, customState
        vec4 fetch(sampler2D s) { return texSample2D(MAKE_SAMPLER2D_ARGUMENT(s), uv); }
        """
        let pp = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(pp.contains("texSample2D(s, customState, uv)"), pp)
    }

    func testSamplerParameterMacroHelperTranslatesToValidMSL() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        vec4 fetch(DECLARE_SAMPLER2D_PARAMETER(g_Texture0), vec2 uv) {
            return texSample2D(MAKE_SAMPLER2D_ARGUMENT(g_Texture0), uv);
        }
        void main() { gl_FragColor = fetch(g_Texture0, v_TexCoord); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("inline float4 fetch(texture2d<float> g_Texture0, float2 uv, sampler smp)"),
                      "sampler2D 파라미터 + 공용 smp 캡처: \(t.msl)")
        XCTAssertTrue(t.msl.contains("g_Texture0.sample(smp, we_uv(uv))"), t.msl)
        XCTAssertTrue(t.msl.contains("fetch(g_Texture0, in.v_TexCoord, smp)"), t.msl)
    }

    // MARK: 4. uvec4→uint4 / ivec4→int4 (2/3 성분 포함, RE :44)

    func testIntegerVectorTypesRenamed() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uvec4 helper(ivec4 v) { return uvec4(v); }
        void main() {
            uvec4 a = uvec4(1, 2, 3, 4);
            ivec2 b = ivec2(2, 3);
            uvec3 c3 = uvec3(a.xyz);
            uvec4 hv = helper(ivec4(1));
            gl_FragColor = vec4(float(a.x + c3.y) + float(b.y) + float(hv.z));
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("uint4 a = uint4(1, 2, 3, 4);"), t.msl)
        XCTAssertTrue(t.msl.contains("int2 b = int2(2, 3);"), t.msl)
        XCTAssertTrue(t.msl.contains("uint3 c3 = uint3(a.xyz);"), t.msl)
        XCTAssertTrue(t.msl.contains("inline uint4 helper(int4 v)"), "헬퍼 시그니처도 mslType 경유: \(t.msl)")
        XCTAssertFalse(t.msl.contains("uvec"))
        XCTAssertFalse(t.msl.contains("ivec"))
    }

    // MARK: 5. mat4x3→float4x3 (RE :46)

    func testMat4x3MapsToFloat4x3() throws {
        let frag = """
        varying vec2 v_TexCoord;
        mat4x3 basis() { return mat4x3(1.0); }
        void main() {
            mat4x3 m = basis();
            vec3 p3 = vec3(1.0, 2.0, 3.0);
            gl_FragColor = m * p3;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("inline float4x3 basis()"), t.msl)
        XCTAssertTrue(t.msl.contains("return float4x3(1.0);"), t.msl)
        XCTAssertTrue(t.msl.contains("float4x3 m = basis();"), t.msl)
        XCTAssertFalse(t.msl.contains("mat4x3"))
    }

    // MARK: 6. frag 측 gl_Position → in.gl_Position (WE PS_INPUT = 픽셀 좌표)

    func testFragmentGlPositionMapsToInGlPosition() throws {
        let frag = """
        varying vec2 v_TexCoord;
        void main() {
            vec2 px = gl_Position.xy;
            gl_FragColor = vec4(px, 0.0, 1.0);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("float2 px = in.gl_Position.xy;"),
                      "frag 측 gl_Position 은 in.gl_Position(픽셀 좌표): \(t.msl)")
    }
}
