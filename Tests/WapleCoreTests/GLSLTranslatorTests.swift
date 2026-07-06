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

    func testCommaSeparatedUniformsParsed() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform float g_Amount, g_Offset; // {"material":"amount","default":0.5}
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * (g_Amount + g_Offset);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertEqual(t.materialParams.map(\.glslName), ["g_Amount", "g_Offset"])
        XCTAssertTrue(t.msl.contains("p[0].x + p[1].x"), t.msl)
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

    func testPiOverTwoMacroUsesStandardValue() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * M_PI_2;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("* 1.57079632679"), t.msl)
        XCTAssertFalse(t.msl.contains("6.28318530718"), t.msl)
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

    func testBareReturnWithNewlineRewritten() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
            if (gl_FragColor.a < 0.01) {
                return
                ;
            }
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("return gl_FragColor"), t.msl)
        XCTAssertFalse(t.msl.contains("return\n"), t.msl)
    }

    func testDialectExtras() throws {
        // GLSL atan(y,x) → MSL atan2 (1-인자 atan 은 유지), ddx/ddy → dfdx/dfdy, texSample2DLod → level().
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            float ang = atan(v_TexCoord.y, v_TexCoord.x);
            float one = atan(1.0);
            float dx = ddx(v_TexCoord.x);
            float dy = ddy(v_TexCoord.y);
            vec4 lod = texSample2DLod(g_Texture0, v_TexCoord, 0.0);
            gl_FragColor = lod * (ang + one + dx + dy);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("atan2(in.v_TexCoord.y, in.v_TexCoord.x)"), t.msl)
        XCTAssertTrue(t.msl.contains("atan(1.0)"), "1-인자 atan 유지: \(t.msl)")
        XCTAssertTrue(t.msl.contains("dfdx(in.v_TexCoord.x)"), t.msl)
        XCTAssertTrue(t.msl.contains("dfdy(in.v_TexCoord.y)"), t.msl)
        XCTAssertTrue(t.msl.contains("g_Texture0.sample(smp, we_uv(in.v_TexCoord), level(0.0))"), t.msl)
    }

    func testWhitespaceBeforeFunctionCallsRewritten() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            gl_FragColor = texSample2D (g_Texture0, v_TexCoord) + texSample2DLod
                (g_Texture0, v_TexCoord, 0.0);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("g_Texture0.sample(smp, we_uv(in.v_TexCoord))"), t.msl)
        XCTAssertTrue(t.msl.contains("g_Texture0.sample(smp, we_uv(in.v_TexCoord), level(0.0))"), t.msl)
        XCTAssertFalse(t.msl.contains("texSample2D"), t.msl)
    }

    func testDiscardTranslatedForMetal() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            if (v_TexCoord.x < 0.5) { discard; }
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("discard_fragment();"), t.msl)
        XCTAssertFalse(t.msl.contains("discard;"), t.msl)
    }

    func testVertexStageAudioParams() throws {
        // 실제 WE pulse 는 .vert 에서 CreateAudioResponse(오디오 배열 참조)를 호출한다 — vertex 에도 audio 파라미터 필요.
        let vert = """
        varying vec2 v_TexCoord;
        varying float v_Gain;
        float CreateAudioResponse() { return g_AudioSpectrum16Left[0] + g_AudioSpectrum16Right[0]; }
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
            v_Gain = CreateAudioResponse();
        }
        """
        let frag = """
        varying vec2 v_TexCoord;
        varying float v_Gain;
        uniform sampler2D g_Texture0;
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            c.rgb *= v_Gain;
            gl_FragColor = c;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.usesAudio)
        // ev_main 시그니처에 vertex 오디오 버퍼 파라미터가 있어야 한다.
        let evSig = try XCTUnwrap(t.msl.range(of: "vertex Vary ev_main").map { String(t.msl[$0.lowerBound...].prefix(300)) })
        XCTAssertTrue(evSig.contains("constant float* audioL [[buffer(2)]]"), evSig)
        XCTAssertTrue(evSig.contains("constant float* audioR [[buffer(3)]]"), evSig)
        XCTAssertTrue(t.msl.contains("CreateAudioResponse(audioL, audioR)"), t.msl)
        // fragment 는 오디오 미사용 → ef_main 시그니처에 audioL 없어야 한다.
        let efSig = try XCTUnwrap(t.msl.range(of: "fragment float4 ef_main").map { String(t.msl[$0.lowerBound...].prefix(300)) })
        XCTAssertFalse(efSig.contains("audioL"), efSig)
    }

    func testCommentsDoNotContaminateScans() throws {
        // 리뷰 지적: 주석 속 토큰이 본문 스캔에 오염되면 (1) 주석 속 오디오 참조 → usesAudio=true →
        // 불필요한 Screen-Recording TCC 프롬프트, (2) 주석 속 중괄호 → fileScopeConsts 깊이 카운터 붕괴.
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        // debug: g_AudioSpectrum16Left[0] { old code
        /* block comment with g_Time and a brace { */
        const float K = 2.0;
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * K;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertFalse(t.usesAudio, "주석 속 오디오 참조가 usesAudio 를 켜면 안 됨(TCC 프롬프트 유발)")
        XCTAssertTrue(t.msl.contains("constant float K = 2.0;"), "주석 속 { 가 const 스캔을 깨면 안 됨: \(t.msl)")
    }

    func testArrayVaryingsExpandToScalars() throws {
        // 실물 localcontrast/blur 계열: `varying vec2 v_TexCoord[13];` — Metal 은 stage-in/반환 구조체에
        // 배열 불가 → 스칼라 멤버(v_TexCoord_0..)로 확장하고 정수 인덱스 접근을 재작성한다.
        let vert = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord[3];
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_TexCoord[0] = a_TexCoord;
            v_TexCoord[1] = a_TexCoord + 0.1;
            v_TexCoord[2] = a_TexCoord + 0.2;
        }
        """
        let frag = """
        varying vec2 v_TexCoord[3];
        uniform sampler2D g_Texture0;
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord[0])
                         + texSample2D(g_Texture0, v_TexCoord[2]);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("float2 v_TexCoord_0;"), "Vary 는 스칼라 멤버: \(t.msl)")
        XCTAssertTrue(t.msl.contains("float2 v_TexCoord_2;"), t.msl)
        // 본문은 로컬 배열을 그대로 사용(변수 인덱스도 동작); vert 는 말미 복사, frag 는 진입 시 구성.
        XCTAssertTrue(t.msl.contains("float2 v_TexCoord[3];"), "vert 로컬 배열 선언: \(t.msl)")
        XCTAssertTrue(t.msl.contains("out.v_TexCoord_1 = v_TexCoord[1];"), "vert 복사-백: \(t.msl)")
        XCTAssertTrue(t.msl.contains("float2 v_TexCoord[3] = { in.v_TexCoord_0, in.v_TexCoord_1, in.v_TexCoord_2 };"),
                      "frag 로컬 배열 구성: \(t.msl)")
    }

    func testArrayVaryingVariableIndexLoop() throws {
        // 실물 localcontrast_downsample4 패턴: for 루프의 변수 인덱스 접근도 로컬 배열로 동작해야 한다.
        let vert = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord[4];
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_TexCoord[0] = a_TexCoord;
            v_TexCoord[1] = a_TexCoord + 0.1;
            v_TexCoord[2] = a_TexCoord + 0.2;
            v_TexCoord[3] = a_TexCoord + 0.3;
        }
        """
        let frag = """
        varying vec2 v_TexCoord[4];
        uniform sampler2D g_Texture0;
        void main() {
            vec4 result = CAST4(0.0);
            for (int i = 0; i < 4; ++i) {
                vec4 s = texSample2D(g_Texture0, v_TexCoord[i]);
                result += s;
            }
            gl_FragColor = result / 4.0;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("v_TexCoord[i]"), "변수 인덱스는 로컬 배열 접근으로 유지: \(t.msl)")
        XCTAssertTrue(t.msl.contains("float2 v_TexCoord[4] = {"), t.msl)
    }

    func testSampleUVImplicitTruncation() throws {
        // WE GLSL(HLSL 방언)은 vec4 를 sample UV 로 그냥 넘긴다(암시적 절단) — 오버로드 헬퍼로 절단.
        let frag = """
        varying vec4 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("g_Texture0.sample(smp, we_uv(in.v_TexCoord))"), t.msl)
        XCTAssertTrue(t.msl.contains("inline float2 we_uv(float4 v) { return v.xy; }"), t.msl)
    }

    func testArrayParamsBecomeConstantPointers() throws {
        // 실물 pulse.vert: `float CreateAudioResponse(float bufferLeft[16], float bufferRight[16])`.
        // MSL 은 값-배열 파라미터 불가 → constant 포인터로 변환해야 호출부(audioL/audioR)와 정합.
        let vert = """
        varying vec2 v_TexCoord;
        varying float v_Pulse;
        float CreateAudioResponse(float bufferLeft[16], float bufferRight[16]) {
            float r = 0.0;
            for (int a = 0; a < 16; ++a) { r += bufferLeft[a] + bufferRight[a]; }
            return r / 32.0;
        }
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
            v_Pulse = CreateAudioResponse(g_AudioSpectrum16Left, g_AudioSpectrum16Right);
        }
        """
        let frag = """
        varying vec2 v_TexCoord;
        varying float v_Pulse;
        uniform sampler2D g_Texture0;
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            gl_FragColor = c * v_Pulse;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.usesAudio)
        XCTAssertTrue(t.msl.contains("inline float CreateAudioResponse(constant float* bufferLeft, constant float* bufferRight)"), t.msl)
        XCTAssertTrue(t.msl.contains("CreateAudioResponse(audioL, audioR)"), t.msl)
    }

    func testHLSLTypeNamesAccepted() throws {
        // WE 방언은 GLSL(vec2)과 HLSL(float2) 타입명을 혼용한다(실물 contrast_based_sharpness:
        // `float rand_1_05(in float2 uv)`). 선언/헬퍼 시그니처 모두에서 수용해야 한다.
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform float2 g_Shift; // {"material":"shift","default":"0 0"}
        float rand_1_05(in float2 uv) {
            float2 noise = frac(sin(dot(uv.yx, float2(12.9898, 78.233) * 2.0)) * 43758.5453);
            return abs(noise.x + noise.y);
        }
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord + g_Shift) * rand_1_05(v_TexCoord);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertEqual(t.materialParams.first?.sceneKey, "shift")
        XCTAssertEqual(t.materialParams.first?.type, .vec2)
        XCTAssertTrue(t.msl.contains("inline float rand_1_05(float2 uv)"), t.msl)
    }

    func testInverseAndHiResAudioSpectrum() throws {
        // 실물 lightshafts: inverse(mat3) — MSL 미내장 → we_inverse 헬퍼. 오디오 바 효과: 32/64빈 스펙트럼.
        let vert = """
        varying vec2 v_TexCoord;
        void main() {
            mat3 m = mat3(1.0);
            mat3 inv = inverse(m);
            gl_Position = vec4(a_Position * inv[0][0], 1.0);
            v_TexCoord = a_TexCoord;
        }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            c.r *= g_AudioSpectrum64Left[int(v_TexCoord.x * 64.0)];
            c.g *= g_AudioSpectrum32Right[0];
            gl_FragColor = c;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.usesAudio)
        XCTAssertTrue(t.msl.contains("we_inverse("), "inverse → we_inverse 리네임: \(t.msl)")
        XCTAssertTrue(t.msl.contains("inline float3x3 we_inverse(float3x3"), "3x3 역행렬 헬퍼 방출")
        XCTAssertTrue(t.msl.contains("audioL64[int(in.v_TexCoord.x * 64.0)]"), t.msl)
        XCTAssertTrue(t.msl.contains("constant float* audioL64 [[buffer(7)]]"), t.msl)
        XCTAssertTrue(t.msl.contains("constant float* audioR32 [[buffer(6)]]"), t.msl)
        XCTAssertFalse(t.msl.contains("audioL [[buffer(2)]]"), "16빈 미사용이면 미방출: \(t.msl)")
    }

    func testGLSLModHelper() throws {
        // GLSL mod(x,y) = x - y*floor(x/y) (음수에서 fmod 와 다름) → we_mod 헬퍼.
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            vec2 uv = mod(v_TexCoord * 4.0, 1.0);
            gl_FragColor = texSample2D(g_Texture0, uv) * mod(3.0, 2.0);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("we_mod(in.v_TexCoord * 4.0, 1.0)"), t.msl)
        XCTAssertTrue(t.msl.contains("inline float we_mod(float x, float y)"), t.msl)
        XCTAssertTrue(t.msl.contains("we_mod(3.0, 2.0)"), "본문 호출도 리네임: \(t.msl)")
    }

    func testLocalShadowingOfVaryingsAndPointer() throws {
        // 실물 chromatic_aberration 패턴 3종:
        // ① 지역변수가 varying 을 섀도잉(vec4 timer = ...) — 치환하면 `float4 in.timer` 로 깨짐 → 맵에서 제외
        // ② fragment 에서 varying 에 대입(v_TexCoord +=) — stage_in 은 불변 → 로컬 사본으로 승격
        // ③ g_PointerPosition(마우스) 엔진 유니폼 — eng.timeAndPad.yz 매핑
        let frag = """
        varying vec4 v_TexCoord;
        varying vec4 timer;
        uniform sampler2D g_Texture0;
        void main() {
            vec4 timer = texSample2D(g_Texture0, v_TexCoord.xy);
            v_TexCoord += g_PointerPosition.x * 0.01;
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord.xy) * timer;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("float4 timer = g_Texture0.sample"), "섀도잉 지역은 원 이름 유지: \(t.msl)")
        XCTAssertFalse(t.msl.contains("in.timer"), "섀도잉된 varying 은 본문에서 미치환: \(t.msl)")
        XCTAssertTrue(t.msl.contains("float4 v_TexCoord = in.v_TexCoord;"), "대입되는 varying 은 로컬 사본: \(t.msl)")
        XCTAssertTrue(t.msl.contains("v_TexCoord +="), t.msl)
        XCTAssertTrue(t.msl.contains("eng.timeAndPad.yz"), "g_PointerPosition → eng 패딩 슬롯: \(t.msl)")
    }

    func testFileScopeConstWithEngineRefsDemotedToLocal() throws {
        // 실물: `const vec2 K = vec2(g_Texture0Resolution.x, ...)` — 전역 constant 는 eng 파라미터
        // 접근 불가 → main 로컬(const)로 강등돼야 한다(잔여 스킵 진단 클래스).
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        const vec2 K = vec2(g_Texture0Resolution.x * 0.5, 1.0);
        const float PLAIN = 2.0;
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord * K.x * PLAIN);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertFalse(t.msl.contains("constant float2 K"), "엔진 참조 const 는 전역 금지: \(t.msl)")
        XCTAssertTrue(t.msl.contains("const float2 K = float2(eng.texRes[0].x * 0.5, 1.0);"),
                      "main 로컬로 강등 + 엔진 매핑: \(t.msl)")
        XCTAssertTrue(t.msl.contains("constant float PLAIN = 2.0;"), "순수 const 는 기존대로 전역: \(t.msl)")
    }

    func testDefineValueTrailingCommentStripped() {
        // 실물 oscilloscope: `#define ampNormalizer 0.0625 // 1 / 16` — 주석이 치환값에 포함되면
        // `x * 0.0625 // ...;` 로 세미콜론이 삼켜진다.
        let src = """
        #define ampNormalizer 0.0625 // 1 / 16
        void main() { gl_FragColor = vec4(ampNormalizer); }
        """
        let out = ShaderPreprocessor.preprocess(src, combos: [:])
        XCTAssertTrue(out.contains("vec4(0.0625)"), out)
        XCTAssertFalse(out.contains("0.0625 //"), "치환값에 주석 금지: \(out)")
    }

    func testMultiLineFileScopeConst() throws {
        // 실물 tone_mapping: 여러 줄 mat3 const — 첫 줄만 캡처하면 constant 전역이 깨진다.
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        const mat3 m1 = mat3(
            0.5, 0.1, 0.0,
            0.0, 0.5, 0.0,
            0.0, 0.0, 0.5);
        void main() { gl_FragColor = vec4(m1 * vec3(v_TexCoord, 1.0), 1.0); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("constant float3x3 m1 = float3x3("), t.msl)
        XCTAssertTrue(t.msl.contains("0.0, 0.0, 0.5);"), "다중 줄 본문 포함: \(t.msl)")
    }

    func testReservedKeywordIdentifierRenamed() throws {
        // 실물 test_shader: 헬퍼 파라미터명이 `fragment`(MSL 예약어).
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        vec3 circleIllumination(vec2 fragment, float radius) {
            return vec3(fragment.x, fragment.y, radius);
        }
        void main() { gl_FragColor = vec4(circleIllumination(v_TexCoord, 0.5), 1.0); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertFalse(t.msl.contains("float2 fragment,"), "예약어 파라미터는 리네임: \(t.msl)")
        XCTAssertTrue(t.msl.contains("fragment float4 ef_main"), "본래 fragment 속성은 유지: \(t.msl)")
    }

    func testDemotedConstVisibleInHelpers() throws {
        // 실물 radial_blur: 엔진 참조 const 가 헬퍼에서도 사용 — main 로컬 강등만으론 헬퍼가 못 본다.
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        const vec2 kType = vec2(g_Texture0Resolution.x / g_Texture0Resolution.y, 1.0);
        vec2 computeUV(vec2 uv) {
            return (uv - 0.5) * kType;
        }
        void main() { gl_FragColor = texSample2D(g_Texture0, computeUV(v_TexCoord)); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        // 헬퍼 본문 안에서 kType 이 선언되거나(프렐류드) 파라미터로 공급돼야 — 미선언 참조가 없어야 한다.
        XCTAssertFalse(t.msl.contains("constant float2 kType"), "엔진 참조 const 는 전역 금지")
        let helperBody = t.msl.range(of: "computeUV").map { String(t.msl[$0.lowerBound...]) } ?? ""
        XCTAssertTrue(helperBody.contains("kType ="), "헬퍼에서 kType 가시(프렐류드 선언): \(t.msl)")
    }

    func testFuncMacroTrailingCommentAndCrossStageVaryingMismatch() throws {
        // 실물 oscilloscope: 함수형 매크로 본문 트레일링 주석이 ';' 를 삼킴.
        let pre = ShaderPreprocessor.preprocess("""
        #define avg(f) float(f * 0.5) //comment
        void main() { x = avg(3.0)
        ; }
        """, combos: [:])
        XCTAssertFalse(pre.contains("//comment"), pre)
        // 실물 test_shader: vert vec4 / frag vec2 동명 varying — frag 치환에 스위즐.
        let vert = """
        varying vec4 v_TexCoord;
        void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = vec4(a_TexCoord, 0.0, 1.0); }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { vec2 uv = v_TexCoord; gl_FragColor = texSample2D(g_Texture0, uv); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("float2 uv = (in.v_TexCoord).xy;"), "어댑터 절단 형태: \(t.msl.suffix(600))")
    }

    func testMinMaxIntLiteralPromotedToFloat() {
        // 실물 rounded_mask: MSL 은 max(1, float) 모호 — 정수 리터럴 승격.
        let out = GLSLTypeAdapter.adapt(body: "float s = max(1, a / b);",
                                        env: .init(vars: ["a": 1, "b": 1]))
        XCTAssertEqual(out, "float s = max(1.0, a / b);")
    }

    func testSameNameHelpersAcrossStagesRenamed() throws {
        // 실물 radial_blur: vert/frag 각자 동명 computeUV(다른 본문) — frag 쪽 리네임으로 공존.
        let vert = """
        varying vec2 v_TexCoord;
        vec2 tweak(vec2 uv) { return uv * 2.0; }
        void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = tweak(a_TexCoord); }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        vec2 tweak(vec2 uv) { return uv * 0.5; }
        void main() { gl_FragColor = texSample2D(g_Texture0, tweak(v_TexCoord)); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("tweak_f"), "frag 쪽 리네임: \(t.msl)")
        XCTAssertTrue(t.msl.contains("uv * 2.0") && t.msl.contains("uv * 0.5"), "두 정의 공존: \(t.msl)")
    }

    func testSameStageOverloadsFailGracefully() {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        float shape(float x) { return x; }
        vec2 shape(vec2 uv) { return uv; }
        void main() { gl_FragColor = texSample2D(g_Texture0, shape(v_TexCoord)); }
        """
        XCTAssertNil(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
    }

    func testReverseCrossStageVaryingMismatchUsesVertexSwizzleAndZeroInit() throws {
        let vert = """
        varying vec2 v_TexCoord;
        void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec4 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { vec4 uv = v_TexCoord; gl_FragColor = texSample2D(g_Texture0, uv.xy); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("Vary out = {};"), t.msl)
        XCTAssertTrue(t.msl.contains("out.v_TexCoord.xy = vin.a_TexCoord;"), t.msl)
        XCTAssertTrue(t.msl.contains("float4 uv = in.v_TexCoord;"), t.msl)
    }

    func testSamplerComboAnnotationsParsed() {
        // WE 규약: 샘플러 주석의 "combo":"MASK" 는 그 슬롯에 텍스처가 바인딩되면 콤보 자동 활성
        // (실물 reflection/waterwaves/shake 페인트 마스크 — 미적용 시 전화면 반사 사고).
        let src = """
        uniform sampler2D g_Texture0; // {"hidden":true}
        uniform sampler2D g_Texture1; // {"label":"mask","mode":"opacitymask","combo":"MASK","paintdefaultcolor":"0 0 0 1"}
        uniform sampler2D g_Texture2; // {"combo":"NOISE","default":"util/noise"}
        """
        let m = GLSLTranslator.samplerCombos(src)
        XCTAssertEqual(m[1], "MASK")
        // 실물은 CRLF — "\r\n" 은 Swift 단일 grapheme 이라 "\n" split 이 안 걸리는 함정 회귀 방지.
        let crlf = GLSLTranslator.samplerCombos(src.replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertEqual(crlf[1], "MASK")
        XCTAssertEqual(m[2], "NOISE")
        XCTAssertNil(m[0])
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
