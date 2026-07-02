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
        XCTAssertTrue(t.msl.contains("float4 gl_FragColor = float4(0.0);"), "gl_FragColor 로컬 변수(straight, no premult)")
        XCTAssertTrue(t.msl.contains("return gl_FragColor;"), "말미 return")
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

    func testPrecisionQualifiersStripped() throws {
        let vert = """
        precision highp float;
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute highp vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying mediump vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying mediump vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform lowp float g_UserAlpha; // {"material":"alpha","default":1.0}
        void main() { vec4 c = texSample2D(g_Texture0, v_TexCoord); c.a *= g_UserAlpha; gl_FragColor = c; }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertEqual(t.materialParams.count, 1, "lowp float uniform must still parse as material")
        XCTAssertEqual(t.materialParams[0].sceneKey, "alpha")
        XCTAssertTrue(t.msl.contains("float2 v_TexCoord"), "mediump varying must still parse: \(t.msl)")
        for q in ["highp", "mediump", "lowp", "precision "] { XCTAssertFalse(t.msl.contains(q), q) }
    }

    func testEngineSymbolsMappedWithoutDeclarations() throws {
        // 실제 WE 효과의 엔진 유니폼/attribute 선언은 common.h(베이스팩 전용, 보통 부재)에 있다.
        // 선언이 없어도 본문 출현만으로 매핑돼야 실제 워크샵 효과가 번역된다(Stage-2 gate 1).
        let vert = """
        #include "common.h"
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord * g_Texture1Resolution.zw;
        }
        """
        let frag = """
        #include "common.h"
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            c.rgb *= abs(sin(g_Time));
            c.rgb *= 1.0 + g_AudioSpectrum16Left[0];
            vec2 px = gl_FragCoord.xy;
            c.r += px.x * 0.0;
            gl_FragColor = c;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.usesAudio, "audio use detected from body occurrence")
        for expect in ["eng.mvp", "eng.timeAndPad.x", "vin.a_Position", "vin.a_TexCoord",
                       "eng.texRes[1]", "audioL[0]", "in.gl_Position.xy"] {
            XCTAssertTrue(t.msl.contains(expect), "\(expect) missing:\n\(t.msl)")
        }
        for absent in ["g_Time", "g_ModelViewProjectionMatrix", "g_AudioSpectrum16Left", "gl_FragCoord"] {
            XCTAssertFalse(t.msl.contains(absent), absent)
        }
    }

    func testUndeclaredTextureSlotRecognizedFromBody() throws {
        // 방어: 텍스처 샘플러 선언이 헤더에 있어 유실돼도 본문 g_TextureN 출현으로 슬롯 인식.
        let vert = "varying vec2 v_TexCoord;\nvoid main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }"
        let frag = """
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * texSample2D(g_Texture2, v_TexCoord); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertEqual(t.textureSlots, [0, 2])
    }

    func testFileScopeConstEmitted() throws {
        let vert = "varying vec2 v_TexCoord;\nvoid main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }"
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        const float SPEED = M_PI * 2.0;
        const vec2 DIR = vec2(1.0, 0.5);
        void main() {
            const float localConst = 1.0;
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord + DIR * SPEED * localConst * 0.0);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("constant float SPEED = 3.14159265359 * 2.0;"), t.msl)
        XCTAssertTrue(t.msl.contains("constant float2 DIR = float2(1.0, 0.5);"), t.msl)
        // 함수 내부 const 는 파일 스코프로 승격되면 안 된다.
        XCTAssertFalse(t.msl.contains("constant float localConst"), t.msl)
    }

    // MARK: - Stage 2: 헬퍼 함수 방출

    private let plainVert = "varying vec2 v_TexCoord;\nvoid main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }"

    func testPureHelperFunctionEmitted() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        vec2 rotateVec2(vec2 v, float a) {
            float s = sin(a); float c = cos(a);
            return vec2(v.x * c - v.y * s, v.x * s + v.y * c);
        }
        void main() {
            gl_FragColor = texSample2D(g_Texture0, rotateVec2(v_TexCoord, M_PI));
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("float2 rotateVec2(float2 v, float a)"), t.msl)
        XCTAssertTrue(t.msl.contains("rotateVec2(in.v_TexCoord, 3.14159265359)"), t.msl)
        XCTAssertTrue(t.msl.contains("return float2(v.x * c - v.y * s, v.x * s + v.y * c);"), t.msl)
    }

    func testInoutParamBecomesReference() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void shift(inout vec2 uv, in float k) { uv.x += k; }
        void main() {
            vec2 uv = v_TexCoord;
            shift(uv, 0.1);
            gl_FragColor = texSample2D(g_Texture0, uv);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("void shift(thread float2& uv, float k)"), t.msl)
    }

    func testVoidMainWordBoundary() throws {
        // "void mainImage" 가 main 으로 오인되면 안 된다(word-boundary).
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void mainImage(inout vec4 c) { c.r = 1.0; }
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            mainImage(c);
            gl_FragColor = c;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("void mainImage(thread float4& c)"), t.msl)
        XCTAssertTrue(t.msl.contains("mainImage(c);"), t.msl)
    }

    func testHelperCapturesEngineAndMaterial() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform float g_Strength; // {"material":"strength","default":1.0}
        float wobble(float x) { return sin(x * g_Time) * g_Strength; }
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            c.rgb *= wobble(2.0);
            gl_FragColor = c;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("inline float wobble(float x, float g_Strength, float g_Time)"), t.msl)
        XCTAssertTrue(t.msl.contains("wobble(2.0, p[0].x, eng.timeAndPad.x)"), t.msl)
    }

    func testTransitiveCaptureThroughCallGraph() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        float inner1() { return g_Time; }
        float outer1(float k) { return inner1() * k; }
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            c.rgb *= outer1(2.0);
            gl_FragColor = c;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("inline float outer1(float k, float g_Time)"), t.msl)
        XCTAssertTrue(t.msl.contains("inner1(g_Time) * k"), "헬퍼 내부 호출은 원 이름 전달: \(t.msl)")
        XCTAssertTrue(t.msl.contains("outer1(2.0, eng.timeAndPad.x)"), t.msl)
    }

    func testHelperCapturesTextureAndSampler() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        vec4 fetch(vec2 uv) { return texSample2D(g_Texture0, uv); }
        void main() { gl_FragColor = fetch(v_TexCoord); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("inline float4 fetch(float2 uv, texture2d<float> g_Texture0, sampler smp)"), t.msl)
        XCTAssertTrue(t.msl.contains("fetch(in.v_TexCoord, g_Texture0, smp)"), t.msl)
    }

    func testHelperCapturesAudioArray() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        float bass() { return g_AudioSpectrum16Left[0] + g_AudioSpectrum16Left[1]; }
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            c.rgb *= bass();
            gl_FragColor = c;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.usesAudio)
        XCTAssertTrue(t.msl.contains("inline float bass(constant float* g_AudioSpectrum16Left)"), t.msl)
        XCTAssertTrue(t.msl.contains("bass(audioL)"), t.msl)
    }

    func testHelperCapturesVarying() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        float vig() { return 1.0 - length(v_TexCoord - 0.5); }
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            c.rgb *= vig();
            gl_FragColor = c;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("inline float vig(float2 v_TexCoord)"), t.msl)
        XCTAssertTrue(t.msl.contains("vig(in.v_TexCoord)"), t.msl)
    }

    func testFragColorLocalVarScheme() throws {
        // 규약 전환(설계 §3): premult 주입 없음 + 다중 대입/스위즐 대입/조기 bare return 지원.
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
            gl_FragColor.rgb *= 0.5;
            if (gl_FragColor.a < 0.01) { return; }
            gl_FragColor.a *= 0.9;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("float4 gl_FragColor = float4(0.0);"), t.msl)
        XCTAssertTrue(t.msl.contains("if (gl_FragColor.a < 0.01) { return gl_FragColor; }"), "bare return → return gl_FragColor: \(t.msl)")
        XCTAssertTrue(t.msl.hasSuffix("return gl_FragColor;\n}\n") || t.msl.contains("return gl_FragColor;"), t.msl)
        XCTAssertFalse(t.msl.contains("_frag.rgb *= _frag.a"), "premult 주입 제거: \(t.msl)")
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
