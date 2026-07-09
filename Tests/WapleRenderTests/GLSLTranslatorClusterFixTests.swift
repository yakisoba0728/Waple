import XCTest
import Metal
@testable import WapleCore

/// 실물 코퍼스 심층 스캔에서 드러난 Metal 컴파일 실패 7클러스터의 최소 재현 스니펫.
/// 각 테스트: translate → device.makeLibrary(실컴파일) 로 ev_main/ef_main 이 나오는지 확인.
/// 스니펫은 해당 이펙트가 아니라 실패 *구문* 만 담는다(하드코딩 회귀 방지).
final class GLSLTranslatorClusterFixTests: XCTestCase {

    /// translate + 실 Metal 컴파일. 실패 시 방출 MSL 을 첨부해 XCTFail.
    private func assertCompiles(vertex: String, fragment: String, combos: [String: Int] = [:],
                                include: (String) -> String? = { _ in nil },
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }  // Metal 부재 환경 = 스킵
        guard let t = GLSLTranslator.translate(vertex: vertex, fragment: fragment, combos: combos, include: include) else {
            XCTFail("translate returned nil", file: file, line: line); return
        }
        do {
            let lib = try device.makeLibrary(source: t.msl, options: nil)
            XCTAssertNotNil(lib.makeFunction(name: "ev_main"), "ev_main missing", file: file, line: line)
            XCTAssertNotNil(lib.makeFunction(name: "ef_main"), "ef_main missing", file: file, line: line)
        } catch {
            XCTFail("MSL failed to compile: \(error)\n--- MSL ---\n\(t.msl)", file: file, line: line)
        }
    }

    private let trivialVert = """
    varying vec2 v_TexCoord;
    void main() {
        gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
        v_TexCoord = a_TexCoord;
    }
    """

    // MARK: Cluster 3 — "unterminated conditional directive"
    // 실물 halftone: `#if(GRID_TYPE == GRID_TYPE_SQ)` — `#if` 뒤 공백 없이 `(` 가 오면 전처리기가
    // 지시문으로 인식 못 해 `#if(1 == 1)` 을 MSL 에 방출하고 짝 `#endif` 는 소비 → 미종결.
    func testHashIfNoSpaceBeforeParen() {
        let frag = """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
        #if(GRIDX == 1)
            c.rgb *= 0.5;
        #endif
            gl_FragColor = c;
        }
        """
        assertCompiles(vertex: trivialVert, fragment: frag, combos: ["GRIDX": 1])
    }

    // MARK: Cluster 6 — "use of undeclared identifier 'radians'"
    // MSL 엔 radians()/degrees() 가 없다(실물 color_grading 의 cos(radians(u_hueShift))). 헬퍼/메인 양쪽에서.
    func testRadiansAndDegrees() {
        let frag = """
        uniform sampler2D g_Texture0;
        uniform float u_hue; // {"material":"hue","default":45.0}
        varying vec2 v_TexCoord;
        vec3 rotate(vec3 color, float deg) {
            float a = radians(deg);
            return color * cos(a);
        }
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            c.rgb = rotate(c.rgb, u_hue);
            c.r = degrees(u_hue) * 0.001;
            gl_FragColor = c;
        }
        """
        assertCompiles(vertex: trivialVert, fragment: frag)
    }

    // MARK: Cluster 5 — "implicit conversions between vector types (float2 vs float4)"
    // 실물 pixelate: round(v_PixelCoord /*vec2*/) * v_PixelSize /*vec4*/. round 가 크기표에 없어
    // 결과 크기 미지(0) → 곱셈 절단이 안 걸려 float2*float4 가 그대로 방출됐다.
    func testRoundResultKnownSizeTruncatesMul() {
        let frag = """
        varying vec2 v_PixelCoord;
        varying vec4 v_PixelSize;
        uniform sampler2D g_Texture0;
        void main() {
            vec2 uv = round(v_PixelCoord) * v_PixelSize;
            gl_FragColor = texSample2D(g_Texture0, uv);
        }
        """
        assertCompiles(vertex: trivialVert, fragment: frag)
    }

    // MARK: Cluster 2 — "no matching function for call to 'mix'"
    // 실물 shift_hue/hue_shift/old_film: mix(albedo /*vec4*/, newAlbedo /*vec3*/, mask). broadcast 빌트인의
    // 벡터 인자 크기 불일치를 최소 벡터 크기로 절단(HLSL 관용)해야 MSL 오버로드가 매칭된다.
    func testMixMismatchedVectorArgs() {
        let frag = """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() {
            vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
            vec3 tint = vec3(1.0, 0.5, 0.0);
            albedo.rgb = mix(albedo, tint, 0.5);
            gl_FragColor = albedo;
        }
        """
        assertCompiles(vertex: trivialVert, fragment: frag)
    }

    // MARK: Cluster 4 — "call to 'max' is ambiguous"
    // 실물 multistage_wave: int unfeatheredMask = max(overflowable /*int 파라미터*/, step()*step() /*float*/).
    // MSL 은 max(int,float) 오버로드가 모호. int 파라미터 인자를 float() 로 캐스트해 해소.
    func testMaxIntParamMixedWithFloat() {
        let frag = """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        float computeMask(int overflowable, float e) {
            int unfeatheredMask = max(overflowable, step(0.5, e) * step(e, 0.9));
            return float(unfeatheredMask);
        }
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            c.rgb *= computeMask(0, c.r);
            gl_FragColor = c;
        }
        """
        assertCompiles(vertex: trivialVert, fragment: frag)
    }

    // MARK: Cluster 1 — "array initializer must be an initializer list" (+ "array subscript is not an integer")
    // 실물 simple_gradient_audio_bar: float left[32] = g_AudioSpectrum32Left;(전체 배열 복사 — MSL 은 오디오
    // 버퍼가 constant float* 라 리스트 초기화 필요) + float i 로 left[i] 첨자(MSL 은 정수 첨자 요구).
    func testArrayCopyInitAndFloatIndex() {
        let frag = """
        uniform sampler2D g_Texture0;
        uniform float g_AudioSpectrum32Left[32];
        uniform float g_AudioSpectrum32Right[32];
        varying vec2 v_TexCoord;
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            float left[32] = g_AudioSpectrum32Left;
            float right[32] = g_AudioSpectrum32Right;
            float i = floor(v_TexCoord.x * 32.0);
            float l = mix(left[i], right[i], 0.5);
            c.rgb *= l;
            gl_FragColor = c;
        }
        """
        assertCompiles(vertex: trivialVert, fragment: frag)
    }

    // MARK: Cluster 7 — "cannot have global constructors"
    // 실물 audio_responsive_oscilloscope: const float x = pow(...); 이 파일 스코프 constant 로 방출되면
    // pow 는 컴파일타임 상수가 아니라 전역 생성자가 필요 → makeLibrary 링크 거부. 함수 스코프로 강등해야 한다.
    func testGlobalConstWithRuntimeCallDemoted() {
        let frag = """
        uniform sampler2D g_Texture0;
        uniform float u_x; // {"material":"x","default":2.0}
        const float resolution = float(32);
        const float ratio = pow(resolution / 16.0, 2.0);
        varying vec2 v_TexCoord;
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            c.rgb *= ratio * u_x;
            gl_FragColor = c;
        }
        """
        assertCompiles(vertex: trivialVert, fragment: frag)
    }
}
