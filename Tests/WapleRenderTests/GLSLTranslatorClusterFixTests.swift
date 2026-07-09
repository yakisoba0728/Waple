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
}
