import XCTest
import Metal
@testable import WapleCore

final class GLSLTranslatorMSLTests: XCTestCase {
    let opacityVert = """
    uniform mat4 g_ModelViewProjectionMatrix;
    uniform vec4 g_Texture1Resolution;
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    varying vec4 v_TexCoord;
    void main() {
        gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
        v_TexCoord.xy = a_TexCoord;
        v_TexCoord.zw = vec2(v_TexCoord.x * g_Texture1Resolution.z / g_Texture1Resolution.x,
                            v_TexCoord.y * g_Texture1Resolution.w / g_Texture1Resolution.y);
    }
    """
    let opacityFrag = """
    varying vec4 v_TexCoord;
    uniform sampler2D g_Texture0; // {"hidden":true}
    uniform sampler2D g_Texture1; // {"combo":"MASK"}
    uniform float g_UserAlpha; // {"material":"alpha","default":1.0}
    void main() {
        vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
    #if MASK
        float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
    #else
        float mask = 1.0;
    #endif
        albedo.a *= mask * g_UserAlpha;
        gl_FragColor = albedo;
    }
    """

    func testTranslatedOpacityCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: ["MASK": 0]))
        do {
            let lib = try device.makeLibrary(source: t.msl, options: nil)
            XCTAssertNotNil(lib.makeFunction(name: "ev_main"))
            XCTAssertNotNil(lib.makeFunction(name: "ef_main"))
        } catch {
            XCTFail("translated MSL failed to compile: \(error)\n--- MSL ---\n\(t.msl)")
        }
    }

    func testTranslatedOpacityMaskOnCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: ["MASK": 1]))
        do { _ = try device.makeLibrary(source: t.msl, options: nil) }
        catch { XCTFail("MASK=1 MSL failed: \(error)\n\(t.msl)") }
    }

    /// Stage 2 총집합: common.h 스타일(선언 부재) + 헬퍼(순수/캡처/전이/텍스처/오디오/varying) + 파일 스코프 const
    /// + #define — 방출 MSL 이 실제 Metal 에서 컴파일돼야 한다.
    func testStage2HelperCaptureShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let vert = """
        #include "common.h"
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        let frag = """
        #include "common.h"
        #define BASE_GAIN 0.75
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0; // {"hidden":true}
        uniform float g_Strength; // {"material":"strength","default":1.0}
        const float TWO_PI = M_PI * 2.0;

        vec2 rotateVec2(vec2 v, float a) {
            float s = sin(a); float c = cos(a);
            return vec2(v.x * c - v.y * s, v.x * s + v.y * c);
        }
        float bass() { return g_AudioSpectrum16Left[0] + g_AudioSpectrum16Right[0]; }
        float pulseGain() { return BASE_GAIN + bass() * g_Strength * sin(g_Time); }
        vec4 fetchRotated(float ang) {
            return texSample2D(g_Texture0, rotateVec2(v_TexCoord - 0.5, ang) + 0.5);
        }
        void main() {
            vec4 c = fetchRotated(TWO_PI * 0.0);
            c.rgb *= pulseGain();
            gl_FragColor = c;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.usesAudio)
        XCTAssertEqual(t.materialParams.map(\.sceneKey), ["strength"])
        do {
            let lib = try device.makeLibrary(source: t.msl, options: nil)
            XCTAssertNotNil(lib.makeFunction(name: "ev_main"))
            XCTAssertNotNil(lib.makeFunction(name: "ef_main"))
        } catch {
            XCTFail("Stage-2 MSL failed to compile: \(error)\n--- MSL ---\n\(t.msl)")
        }
    }
}
