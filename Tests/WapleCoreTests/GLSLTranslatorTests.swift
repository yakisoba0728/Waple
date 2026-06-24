import XCTest
@testable import WapleCore

final class GLSLTranslatorTests: XCTestCase {
    // 실제 WE effects/opacity 소스.
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
    uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity_mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}
    uniform float g_UserAlpha; // {"material":"alpha","label":"ui_editor_properties_alpha","default":1.0,"range":[0.01, 1]}
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

    func testOpacityReflection() throws {
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: ["MASK": 0]))
        XCTAssertEqual(t.materialParams.count, 1)
        let p = t.materialParams[0]
        XCTAssertEqual(p.glslName, "g_UserAlpha")
        XCTAssertEqual(p.type, .float)
        XCTAssertEqual(p.sceneKey, "alpha")
        XCTAssertEqual(p.defaultValue, [1.0])
        XCTAssertEqual(t.textureSlots, [0, 1])
        XCTAssertFalse(t.usesAudio)
    }

    func testOpacityMSLStructure() throws {
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: ["MASK": 0]))
        XCTAssertTrue(t.msl.contains("vertex Vary ev_main"))
        XCTAssertTrue(t.msl.contains("fragment float4 ef_main"))
        XCTAssertTrue(t.msl.contains("p[0].x"), "g_UserAlpha → p[0].x")
        XCTAssertTrue(t.msl.contains("_frag.rgb *= _frag.a"), "premultiplied inject")
        XCTAssertTrue(t.msl.contains("g_Texture0.sample(smp"), "texSample2D → .sample")
        XCTAssertTrue(t.msl.contains("eng.mvp"), "MVP engine uniform")
        XCTAssertTrue(t.msl.contains("float mask = 1.0;"), "MASK=0 branch")
        XCTAssertFalse(t.msl.contains("texSample2D"))
        XCTAssertFalse(t.msl.contains("g_UserAlpha"))  // 전부 치환됨
        XCTAssertFalse(t.msl.contains("vec4"))         // 타입 치환됨
    }

    func testMaskComboOnSelectsBranch() throws {
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: ["MASK": 1]))
        XCTAssertTrue(t.msl.contains("g_Texture1.sample(smp"), "MASK=1 uses g_Texture1")
        XCTAssertFalse(t.msl.contains("float mask = 1.0;"))
    }

    func testMulRewrite() {
        let r = GLSLTranslator.rewriteCall("mul(a, b)", "mul") { $0.count == 2 ? "(\($0[1]) * \($0[0]))" : nil }
        XCTAssertEqual(r, "(b * a)")
    }

    func testIdentifierReplaceWholeWord() {
        // g_UserAlpha → p[0].x 이지만 g_UserAlphaX 같은 건 안 바뀜
        let r = GLSLTranslator.replaceIdentifiers("g_UserAlpha + g_UserAlphaX", ["g_UserAlpha": "p[0].x"])
        XCTAssertEqual(r, "p[0].x + g_UserAlphaX")
    }
}
