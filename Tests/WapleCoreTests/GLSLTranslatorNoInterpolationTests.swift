import XCTest
@testable import WapleCore

/// 감사 V07 회귀: TexImage.noInterpolation(flags bit0, WE NoInterpolation)의 GLSL 변환(translated)
/// 이펙트 경로 소비 — clampUVs(F162/F163)의 texWrap 3종 세트(buildPassBindings texWrap → EngineU
/// 레이아웃 → translator 삼항 샘플러)와 동형의 texFilter 3종 세트. 번역 출력은 런타임 분기이므로
/// 씬 자산 없이 순수 단위 테스트 가능(렌더 end-to-end 는 WapleRenderTests).
final class GLSLTranslatorNoInterpolationTests: XCTestCase {
    private let vert = """
    uniform mat4 g_ModelViewProjectionMatrix;
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    varying vec2 v_TexCoord;
    void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
    """
    private let frag = """
    varying vec2 v_TexCoord;
    uniform sampler2D g_Texture0;
    uniform sampler2D g_Texture1;
    void main() {
        vec4 a = texSample2D(g_Texture0, v_TexCoord);
        vec4 b = texSample2D(g_Texture1, v_TexCoord);
        gl_FragColor = mix(a, b, 0.5);
    }
    """

    /// EngineU 레이아웃 확장: texWrap[2] 직후 texFilter[2](슬롯별 1=nearest/0=linear) — Swift 측 단일
    /// 빌더(SceneRendererFrameEncoder.engineUniform)와 레이아웃 동기 필수.
    func testEngineUDeclaresTexFilter() throws {
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("float4 texWrap[2]; float4 texFilter[2];"), t.msl)
    }

    /// nearest 샘플러 쌍 방출: min/mag 필터만 point, 어드레스 모드·mip 필터(linear — 1단계 mip 활성화,
    /// 단일레벨은 LOD 클램프로 무연산)는 보존(WE 의미론 — NoInterpolation 은 mag/min 만 nearest).
    func testNearestSamplerTwinsDeclared() throws {
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("constexpr sampler smpNearest(filter::nearest, mip_filter::linear, address::clamp_to_edge);"), t.msl)
        XCTAssertTrue(t.msl.contains("constexpr sampler smpRepeatNearest(filter::nearest, mip_filter::linear, address::repeat);"), t.msl)
    }

    /// 최상위 texSample2D 는 슬롯별 2×2 런타임 삼항(바깥=filter, 안쪽=wrap)으로 번역 — 슬롯 0/1 각각.
    func testPerTextureSamplerExprIsFilterWrapTernary() throws {
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains(
            "g_Texture0.sample((eng.texFilter[0][0] > 0.5 ? (eng.texWrap[0][0] > 0.5 ? smpNearest : smpRepeatNearest) : (eng.texWrap[0][0] > 0.5 ? smp : smpRepeat))"), t.msl)
        XCTAssertTrue(t.msl.contains(
            "g_Texture1.sample((eng.texFilter[0][1] > 0.5 ? (eng.texWrap[0][1] > 0.5 ? smpNearest : smpRepeatNearest) : (eng.texWrap[0][1] > 0.5 ? smp : smpRepeat))"), t.msl)
    }

    /// 슬롯 미상 식(헬퍼 로컬 별칭)은 기존 폴터 smp(선형 clamp) 유지 — 캡처 매커니즘의 단일 제네릭
    /// `sampler smp` threading 절대 불변(F162/F163 와 동일, 무회귀).
    func testHelperAliasSamplingKeepsGenericSmp() throws {
        let f = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        vec4 pick(sampler2D tex, vec2 uv) { return texSample2D(tex, uv); }
        void main() { gl_FragColor = pick(g_Texture0, v_TexCoord); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: f, combos: [:]))
        XCTAssertTrue(t.msl.contains("tex.sample(smp,"), t.msl)
        XCTAssertFalse(t.msl.contains("tex.sample((eng.texFilter"), "별칭 샘플에 런타임 삼항이 붙으면 안 됨")
    }
}
