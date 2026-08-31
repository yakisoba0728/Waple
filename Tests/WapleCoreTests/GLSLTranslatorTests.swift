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
        // F162/F163: 최상위 본문 texSample2D 는 슬롯별 eng.texWrap 런타임 삼항(clamp smp/repeat smpRepeat)으로 번역.
        XCTAssertTrue(t.msl.contains("g_Texture0.sample((eng.texFilter[0][0] > 0.5 ? (eng.texWrap[0][0] > 0.5 ? smpNearest : smpRepeatNearest) : (eng.texWrap[0][0] > 0.5 ? smp : smpRepeat))"), "texSample2D → .sample")
        XCTAssertTrue(t.msl.contains("eng.mvp"), "MVP engine uniform")
        XCTAssertTrue(t.msl.contains("float mask = 1.0;"), "MASK=0 branch")
        XCTAssertFalse(t.msl.contains("texSample2D"))
        XCTAssertFalse(t.msl.contains("g_UserAlpha"))  // 전부 치환됨
        XCTAssertFalse(t.msl.contains("vec4"))         // 타입 치환됨
    }

    func testMaskComboOnSelectsBranch() throws {
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: ["MASK": 1]))
        // F162/F163: 최상위 본문 texSample2D 는 슬롯별 eng.texWrap 런타임 삼항(clamp smp/repeat smpRepeat).
        XCTAssertTrue(t.msl.contains("g_Texture1.sample((eng.texFilter[0][1] > 0.5 ? (eng.texWrap[0][1] > 0.5 ? smpNearest : smpRepeatNearest) : (eng.texWrap[0][1] > 0.5 ? smp : smpRepeat))"), "MASK=1 uses g_Texture1: \(t.msl)")
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

    // uint 시그니처 헬퍼는 MSL 네이티브 uint 로 그대로 방출되어야 한다. uint 파라미터 헬퍼는
    // helperSignature nil 로 스킵(:349 continue)되고, uint 반환 헬퍼는 parseFunctions 의 반환타입
    // 인식(mslType) 자체가 실패해 누락된다 — 둘 다 호출부만 남아 MSL 컴파일 실패 → 효과 전체 폴터.
    func testUintSignatureHelpersEmitted() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        float brighten(uint k) {
            return float(k) / 255.0;
        }
        uint quantize(float v) {
            return uint(v * 255.0);
        }
        void main() {
            uint k = quantize(v_TexCoord.x);
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * brighten(k);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("float brighten(uint k)"), t.msl)   // uint 파라미터 헬퍼 방출
        XCTAssertTrue(t.msl.contains("uint quantize(float v)"), t.msl)   // uint 반환 헬퍼 방출
        XCTAssertTrue(t.msl.contains("brighten(k)"), t.msl)              // 호출부와 정의 정합
    }

    func testPiTwoMacroIsTwoPi() throws {
        // WE 관용: 실물 common.h 는 `#define M_PI_2 6.28318530718`(2π) — π/2 는 M_PI_HALF.
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * M_PI_2;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("* 6.28318530718"), t.msl)
        XCTAssertFalse(t.msl.contains("M_PI_2"), t.msl)
    }

    // T-B1: frag 가 varying 에 대입(→로컬 승격)한 뒤 그 varying 을 읽는 헬퍼를 호출하면,
    // 캡처 인자는 `in.<n>`(대입 전 보간값)이 아니라 로컬 사본이어야 한다.
    func testPromotedVaryingPassedToHelperAsLocal() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        vec2 warp() { return v_TexCoord * 2.0; }
        void main() {
            v_TexCoord = fract(v_TexCoord + 0.5);
            gl_FragColor = texSample2D(g_Texture0, warp());
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("float2 v_TexCoord = in.v_TexCoord;"), t.msl)  // 승격 프리앰블
        XCTAssertTrue(t.msl.contains("warp(v_TexCoord)"), t.msl)                    // 로컬 사본 전달
        XCTAssertFalse(t.msl.contains("warp(in.v_TexCoord)"), t.msl)
    }

    // T-B4: 블록 주석 속 죽은 선언은 실선언으로 파싱되면 안 되고(usesAudio 오점화/유령 슬롯),
    // `//` JSON 어노테이션 파스는 계속 살아야 한다.
    func testBlockCommentedDeclarationsIgnored() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        /*
        uniform float g_AudioSpectrum16Left[16];
        uniform float g_Dead; // {"material":"dead","default":0.5}
        */
        uniform float g_Alive; // {"material":"alive","default":0.25}
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_Alive;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertFalse(t.usesAudio, "블록 주석 속 g_AudioSpectrum16Left 가 usesAudio 를 켜면 안 됨")
        XCTAssertEqual(t.materialParams.map(\.glslName), ["g_Alive"], "유령 슬롯(g_Dead) 금지")
        XCTAssertEqual(t.materialParams[0].sceneKey, "alive")
        XCTAssertEqual(t.materialParams[0].defaultValue, [0.25])
    }

    // T-B10: 비인용 지수 표기 기본값(`1e-3`)이 1000× 오독되면 안 된다.
    func testExponentDefaultAnnotation() {
        let us = GLSLTranslator.parseUniforms(#"uniform float g_Eps; // {"material":"eps","default":1e-3}"#)
        XCTAssertEqual(us.first?.annotationDefault, [0.001])
        let us2 = GLSLTranslator.parseUniforms(#"uniform float g_Big; // {"material":"big","default":2E+2}"#)
        XCTAssertEqual(us2.first?.annotationDefault, [200.0])
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

    func testTexelSizeIsEngineUniformNotMaterial() throws {
        // 실물 bokeh.vert: `uniform vec2 g_TexelSize;` 선언 + `ratio = g_TexelSize * g_Texture0Resolution.xy`.
        // 머티리얼 파라미터로 오인되면 기본값 (0,0) → ratio.y/ratio.x = 0/0 = NaN → NaN UV 샘플 → 검정
        // (3544152633 bokeh 패스 ×0.4 luma 손실의 근원). 엔진 유니폼: 타깃 texel 크기 ≈ 1/tex0 해상도.
        let vert = """
        uniform vec2 g_TexelSize;
        uniform vec4 g_Texture0Resolution;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        varying vec2 v_PixelSize;
        void main() {
            vec2 ratio = g_TexelSize * g_Texture0Resolution.xy;
            v_PixelSize = (g_TexelSize + g_TexelSizeHalf) * ratio;
            gl_Position = vec4(a_Position, 1.0);
            v_TexCoord = a_TexCoord;
        }
        """
        let frag = """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        varying vec2 v_PixelSize;
        vec2 texel(int x, int y) {
            return vec2(x, y) * vec2(1.0 / g_TexelSize.x, 1.0 / g_TexelSize.y);
        }
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord + v_PixelSize + texel(1, 1) * 0.0);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        // X-⑤: g_TexelSize 정본은 이펙트 출력(dst) 해상도 기준(eng.targetRes) — 종전 tex0 근사(texRes[0])에서 변경.
        XCTAssertTrue(t.msl.contains("(1.0 / eng.targetRes.xy)"), "g_TexelSize → 1/dst 해상도:\n\(t.msl)")
        XCTAssertTrue(t.msl.contains("(0.5 / eng.targetRes.xy)"), "g_TexelSizeHalf → 0.5/dst 해상도:\n\(t.msl)")
        // 헬퍼 캡처 파라미터는 float2 로 선언돼야 한다(실물 contrast_based_sharpness 의
        // `1./g_TexelSize.x` — float 폴백이면 .x 멤버 참조로 MSL 컴파일 실패).
        XCTAssertTrue(t.msl.contains("float2 g_TexelSize"), "캡처 파라미터 타입 float2:\n\(t.msl)")
        XCTAssertTrue(t.materialParams.isEmpty, "머티리얼 파라미터로 오인 금지: \(t.materialParams.map(\.glslName))")
    }

    func testTextureNTexelIsEngineUniformNotMaterial() throws {
        // g_TexelSize 동족(텍스처별 텍셀 크기, 실물 downsample_quarter.vert `a_TexCoord ± g_Texture0Texel.xy*2`).
        // 머티리얼 오인 시 (0,0,0,0) → 커널 오프셋 0 = 블러/다운샘플 무력화. WE 규약 vec4 = (1/w, 1/h, w, h) —
        // 모프 코드(model_vertex_v1.h `% morphTexel.z`)가 .zw(=dims)를 쓰므로 vec4 전체 치환이어야 한다.
        // g_Texture4Texel 은 선언 없이 본문만(실물 fluidsimulation_combine — 선언이 공용 헤더인 패턴):
        // bodyIds 인식 + 헬퍼 캡처 + 팬텀 텍스처 슬롯 가드를 함께 검증.
        let vert = """
        uniform vec4 g_Texture0Texel;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        varying vec2 v_Dims;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_TexCoord = a_TexCoord + g_Texture0Texel.xy * 2.0;
            v_Dims = g_Texture0Texel.zw;
        }
        """
        let frag = """
        uniform sampler2D g_Texture0;
        uniform vec4 g_Texture1Texel;
        varying vec2 v_TexCoord;
        varying vec2 v_Dims;
        vec2 shadowStep(float s) {
            return g_Texture4Texel.xy * s;
        }
        void main() {
            vec2 halfTexel = g_Texture1Texel * 0.5;
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord + halfTexel + shadowStep(2.0)) + vec4(v_Dims, 0.0, 0.0);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        // vec4 전체 치환: xy = 1/dims(텍셀), zw = dims.
        XCTAssertTrue(t.msl.contains("float4(1.0 / eng.texRes[0].xy, eng.texRes[0].xy)"),
                      "g_Texture0Texel → texRes[0] vec4 치환:\n\(t.msl)")
        XCTAssertTrue(t.msl.contains("float4(1.0 / eng.texRes[4].xy, eng.texRes[4].xy)"),
                      "g_Texture4Texel(본문만) → texRes[4] vec4 치환:\n\(t.msl)")
        // 헬퍼 캡처 파라미터 float4(float 폴백이면 .xy 멤버 참조로 MSL 컴파일 실패).
        XCTAssertTrue(t.msl.contains("float4 g_Texture4Texel"), "캡처 파라미터 타입 float4:\n\(t.msl)")
        // sizeEnv 컴포넌트 4: vec2 = vec4*스칼라 혼합을 타입어댑터가 절단(.xy)해야 MSL 유효.
        XCTAssertTrue(t.msl.contains("(float4(1.0 / eng.texRes[1].xy, eng.texRes[1].xy) * 0.5).xy"),
                      "sizeEnv=4 → 절단 삽입:\n\(t.msl)")
        XCTAssertTrue(t.materialParams.isEmpty, "머티리얼 파라미터로 오인 금지: \(t.materialParams.map(\.glslName))")
        // 팬텀 텍스처 슬롯 금지: Texel 토큰이 textureIndex 본문 스캔에 잡히면 [0,1,4] 로 오염된다.
        XCTAssertEqual(t.textureSlots, [0], "팬텀 슬롯 금지: \(t.textureSlots)")
    }

    func testParallaxPositionIsEngineUniformNotMaterial() throws {
        // 실물 depthparallax: bare `uniform vec2 g_ParallaxPosition;` — 머티리얼로 오인되면
        // 기본값 (0,0) 영구고정 → 시차 왜곡/중앙정지 실패. 포인터와는 별도 엔진 유니폼이다.
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform vec2 g_ParallaxPosition;
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord + g_ParallaxPosition * 0.01);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("eng.parallaxAndPad.xy"),
                      "g_ParallaxPosition → 독립 시차 슬롯:\n\(t.msl)")
        XCTAssertFalse(t.msl.contains("eng.timeAndPad.yz"),
                       "시차 위치가 g_PointerPosition 슬롯에 alias 되면 안 됨:\n\(t.msl)")
        XCTAssertTrue(t.materialParams.isEmpty, "머티리얼 파라미터로 오인 금지: \(t.materialParams.map(\.glslName))")
    }

    func testPointerStateIsEngineUniformNotMaterial() throws {
        // 실물 cursorripple/fluidsim: bare `uniform vec4 g_PointerState;` — .z = 클릭 버튼 힘.
        // 머티리얼로 오인되면 클릭 배관이 끊겨 미클릭 0 영구고정. 엔진 유니폼: pointerLastAndPad.z alias.
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform vec4 g_PointerState;
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_PointerState.z;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("eng.pointerLastAndPad.z"), "g_PointerState.z → 클릭힘 슬롯:\n\(t.msl)")
        XCTAssertTrue(t.materialParams.isEmpty, "머티리얼 파라미터로 오인 금지: \(t.materialParams.map(\.glslName))")
    }

    func testLightAmbientColorIsEngineUniformWithWhiteDefault() throws {
        // F744: bare `g_LightAmbientColor` 가 머티리얼로 오인되면 기본값 0 으로 레이어가 검게 나온다.
        // 엔진 유니폼으로 인식 + 흰색 중립값이어야 한다.
        //
        // G-A2/A4/B2: **타입은 vec3 다.** 종전 픽스처는 `uniform vec4` 를 선언하고 방출이
        // `float4(1,1,1,1)` 인지 봤는데, 동봉 WEAssets 에 vec4 선언은 **0건**이고 vec3 선언이
        // **12건**이다(generic{,2,3,4}.vert · genericimage{2,3,4}.frag · genericparticle.frag ·
        // genericropeparticle.frag · base/model_vertex_v1.h · fluidsimulation_combine.frag ×2).
        // 즉 그 픽스처는 실물에 없는 형태였고, float4 를 주입하면 실제 소비처가 전부 타입
        // 불일치로 MSL 컴파일에 실패한다. 실물 선언·실물 소비 형태로 바꾼다.
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform vec3 g_LightAmbientColor;
        uniform vec3 g_LightSkylightColor;
        void main() {
            vec3 ambient = mix(g_LightSkylightColor, g_LightAmbientColor, 0.5);
            gl_FragColor = vec4(texSample2D(g_Texture0, v_TexCoord).rgb * ambient, 1.0);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("float3(1.0, 1.0, 1.0)"), "g_LightAmbientColor → vec3 흰색 중립값:\n\(t.msl)")
        XCTAssertFalse(t.msl.contains("float4(1.0, 1.0, 1.0, 1.0)"),
                       "vec4 주입 재유입 금지 — 실물 선언은 전건 vec3 다:\n\(t.msl)")
        XCTAssertTrue(t.materialParams.isEmpty, "머티리얼 파라미터로 오인 금지: \(t.materialParams.map(\.glslName))")
    }

    /// F4-polish②: Forward+ 라이팅 유니폼(g_LPoint_*/g_LSpot_*/g_LTube_*/g_LDirectional_*/
    /// g_LFeature_Shadow*, 실물 assets/shaders/generic3.frag `#if LIGHTS_POINT` 등 블록 — 로컬 코퍼스는
    /// 콤보 참조 0건이라 오늘 시점 이 블록이 커스텀 경로에 도달하진 않지만, 콤보 가드 없이 직접
    /// 선언하는 셰이더가 나타나도 g_TexelSize 급 오분류(머티리얼 sceneKey 편입 → 팬텀 슬롯)는 막아야
    /// 한다는 것이 이 테스트의 요지 — **인식(비-머티리얼) + 중립값**만 검증, 인덱스 `[l]` 구독 안전성은
    /// 스코프 밖(위 isEngine 주석 "잔여 한계" 참조, 배열 아닌 스칼라 참조로 케이스를 단순화).
    func testForwardLightingUniformsAreEngineNotMaterial() throws {
        let frag = """
        varying vec3 v_WorldPos;
        uniform sampler2D g_Texture0;
        uniform vec4 g_LPoint_Color;
        uniform vec4 g_LPoint_Origin;
        uniform vec4 g_LSpot_Color;
        uniform vec4 g_LSpot_Origin;
        uniform vec4 g_LSpot_Direction;
        uniform vec4 g_LTube_Color;
        uniform vec4 g_LTube_OriginA;
        uniform vec4 g_LTube_OriginB;
        uniform vec4 g_LDirectional_Color;
        uniform vec4 g_LDirectional_Direction;
        uniform vec4 g_LFeature_ShadowPointProjection;
        uniform vec4 g_LFeature_ShadowProjectionTransform;
        uniform mat4 g_LFeature_ShadowProjection;
        varying vec2 v_TexCoord;
        void main() {
            vec3 lightDelta = g_LPoint_Origin.xyz - v_WorldPos;
            vec3 projected = (g_LFeature_ShadowProjection * vec4(lightDelta, 1.0)).xyz + g_LFeature_ShadowProjectionTransform.xyz
                + g_LFeature_ShadowPointProjection.xyz;
            vec3 light = g_LPoint_Color.rgb + g_LSpot_Color.rgb + g_LSpot_Origin.xyz + g_LSpot_Direction.xyz
                + g_LTube_Color.rgb + g_LTube_OriginA.xyz + g_LTube_OriginB.xyz
                + g_LDirectional_Color.rgb + g_LDirectional_Direction.xyz + projected;
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * vec4(light, 1.0);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.materialParams.isEmpty, "머티리얼 파라미터로 오인 금지: \(t.materialParams.map(\.glslName))")
        XCTAssertTrue(t.msl.contains("float4(0.0, 0.0, 0.0, 0.0)"), "vec4 계열 → 0 벡터 중립값:\n\(t.msl)")
        XCTAssertTrue(t.msl.contains("float4x4(1.0)"), "g_LFeature_ShadowProjection(mat4) → 항등:\n\(t.msl)")
    }

    func testFrametimeAndPointerLastAreEngineUniforms() throws {
        // 실물 fluidsim/cursorripple: bare g_Frametime(dt 시간적분) + g_PointerPositionLast(이전 프레임 포인터).
        // 머티리얼-0 고정이면 시간적분 동결/유령 링플. ★두 유니폼은 짝 — dt 없이 last 만 주면 발산.
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform float g_Frametime;
        uniform vec2 g_PointerPositionLast;
        void main() {
            vec2 d = (g_PointerPosition - g_PointerPositionLast) * g_Frametime;
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord + d);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("eng.timeAndPad.w"), "g_Frametime → dt 슬롯:\n\(t.msl)")
        XCTAssertTrue(t.msl.contains("eng.pointerLastAndPad.xy"), "g_PointerPositionLast → 히스토리 슬롯:\n\(t.msl)")
        XCTAssertTrue(t.msl.contains("float4 pointerLastAndPad;"), "EngineU 에 히스토리 필드:\n\(t.msl)")
        XCTAssertTrue(t.materialParams.isEmpty, "머티리얼 파라미터로 오인 금지: \(t.materialParams.map(\.glslName))")
    }

    func testFrametimeHelperCaptureTypedFloat() throws {
        // 헬퍼 캡처 파라미터 타입: g_Frametime=float, g_PointerPositionLast/g_ParallaxPosition=float2
        // (float 폴백이면 .x 멤버 참조 컴파일 실패 — g_TexelSize 와 동일 클래스).
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        vec2 drift() { return g_PointerPositionLast * g_Frametime + g_ParallaxPosition.yx * 0.0; }
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord + drift());
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("float2 g_PointerPositionLast"), "캡처 파라미터 float2:\n\(t.msl)")
        XCTAssertTrue(t.msl.contains("float2 g_ParallaxPosition"), "캡처 파라미터 float2:\n\(t.msl)")
        XCTAssertTrue(t.msl.contains("float g_Frametime"), "캡처 파라미터 float:\n\(t.msl)")
    }

    func testTextureReductionScaleNeutralDefaultOne() throws {
        // 실물 blend.vert:75 TRANSFORMUV: `... / g_TextureReductionScale` — bare 선언이 기본값 0 이면
        // ÷0 NaN(+skew ×0 no-op). 엔진 주입값은 아니지만 중립값은 1.0(항등 배율).
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform vec2 g_TextureReductionScale;
        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord / g_TextureReductionScale);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        let p = try XCTUnwrap(t.materialParams.first(where: { $0.glslName == "g_TextureReductionScale" }),
                              "머티리얼 파라미터 유지(엔진 승격 아님): \(t.materialParams.map(\.glslName))")
        XCTAssertEqual(p.defaultValue, [1.0, 1.0], "중립값 1.0(0=÷0 NaN)")
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
        // F162/F163: 최상위 본문 texSample2D 는 슬롯별 eng.texWrap 런타임 삼항(clamp smp/repeat smpRepeat).
        XCTAssertTrue(t.msl.contains("g_Texture0.sample((eng.texFilter[0][0] > 0.5 ? (eng.texWrap[0][0] > 0.5 ? smpNearest : smpRepeatNearest) : (eng.texWrap[0][0] > 0.5 ? smp : smpRepeat)), we_uv(in.v_TexCoord), level(0.0))"), t.msl)
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
        // F162/F163: 최상위 본문 texSample2D 는 슬롯별 eng.texWrap 런타임 삼항(clamp smp/repeat smpRepeat).
        XCTAssertTrue(t.msl.contains("g_Texture0.sample((eng.texFilter[0][0] > 0.5 ? (eng.texWrap[0][0] > 0.5 ? smpNearest : smpRepeatNearest) : (eng.texWrap[0][0] > 0.5 ? smp : smpRepeat)), we_uv(in.v_TexCoord))"), t.msl)
        XCTAssertTrue(t.msl.contains("g_Texture0.sample((eng.texFilter[0][0] > 0.5 ? (eng.texWrap[0][0] > 0.5 ? smpNearest : smpRepeatNearest) : (eng.texWrap[0][0] > 0.5 ? smp : smpRepeat)), we_uv(in.v_TexCoord), level(0.0))"), t.msl)
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
        // F162/F163: 최상위 본문 texSample2D 는 슬롯별 eng.texWrap 런타임 삼항(clamp smp/repeat smpRepeat).
        XCTAssertTrue(t.msl.contains("g_Texture0.sample((eng.texFilter[0][0] > 0.5 ? (eng.texWrap[0][0] > 0.5 ? smpNearest : smpRepeatNearest) : (eng.texWrap[0][0] > 0.5 ? smp : smpRepeat)), we_uv(in.v_TexCoord))"), t.msl)
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

    func testSameStageHelperOverloadsAreMangledAndCallsRewritten() throws {
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        float noise(float x) { return x; }
        float noise(vec2 uv) { return uv.x + uv.y; }
        float TnSin(float x) { return sin(x); }
        vec4 TnSin(vec4 v) { return vec4(TnSin(v.x), TnSin(v.y), TnSin(v.z), TnSin(v.w)); }
        void main() {
            float n = noise(v_TexCoord);
            vec4 wave = TnSin(vec4(n));
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * wave;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: plainVert, fragment: frag, combos: [:]))
        for expect in ["noise_float", "noise_vec2", "TnSin_float", "TnSin_vec4",
                       "noise_vec2(in.v_TexCoord)", "TnSin_vec4(float4(n))",
                       "TnSin_float(v.x)"] {
            XCTAssertTrue(t.msl.contains(expect), "\(expect) missing:\n\(t.msl)")
        }
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

    func testBuiltinCommonBlendingModes14to29() throws {
        // 내장 common_blending.h 의 14-29 모드(VividLight~Luminosity) — 이전엔 default 로 흘러 조용히
        // Normal 이 되던 갭. 정본은 WapleRender/BlendMSL.swift(파리티는 식 대조로 유지, 감사 O2).
        let vert = """
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        let frag = """
        #include "common_blending.h"
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform vec3 g_Color; // {"material":"color","default":"1 0 0"}
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            c.rgb = ApplyBlending(15, c.rgb, g_Color, 0.5);
            c.rgb = ApplyBlending(26, c.rgb, g_Color, 1.0);
            gl_FragColor = c;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:],
                                                       include: { BuiltinShaderIncludes.lookup($0) }))
        // 신규 헬퍼가 MSL 로 방출됐는지(시그니처) + 체인이 29까지 확장됐는지.
        for sig in ["inline float3 BlendVividLightEx(float3", "inline float3 BlendLinearLightEx(float3",
                    "inline float3 BlendPinLightEx(float3", "inline float3 BlendHardMixEx(float3",
                    "inline float3 BlendReflectEx(float3", "inline float3 rgb2hsl(float3",
                    "inline float hue2rgb(float", "inline float3 hsl2rgb(float3"] {
            XCTAssertTrue(t.msl.contains(sig), "방출 MSL 에 없음: \(sig)")
        }
        XCTAssertTrue(t.msl.contains("mode == 29"), "ApplyBlending 체인에 29 모드 없음")
    }

    func testBareEngineBuiltinAlphaColorNeutralDefault() throws {
        // WE 엔진 빌트인 g_Alpha(레이어 알파)·g_Color(틴트)를 머티리얼 어노테이션 없이(bare) 선언한 실물
        // (assets/shaders/flat.frag) — isEngine 화이트리스트 밖이라 머티리얼로 분류되고 default 가
        // padDefault=0 으로 떨어져 레이어가 투명(alpha=0)/검정(color=0,0,0)이 되던 갭.
        // bare 엔진 빌트인은 WE 중립값으로 폴백: g_Alpha=1(불투명), g_Color=(1,1,1)(무-틴트).
        let vert = """
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        // (A) 실물 flat.frag 본문 — g_Alpha + g_Color 둘 다 bare.
        let bareFrag = """
        uniform mediump float g_Alpha;
        uniform mediump vec3 g_Color;
        void main() { gl_FragColor = vec4(g_Color, g_Alpha); }
        """
        let tBare = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: bareFrag, combos: [:]))
        let bareAlpha = try XCTUnwrap(tBare.materialParams.first { $0.glslName == "g_Alpha" }, "g_Alpha 미분류")
        let bareColor = try XCTUnwrap(tBare.materialParams.first { $0.glslName == "g_Color" }, "g_Color 미분류")
        XCTAssertEqual(bareAlpha.defaultValue, [1], "bare g_Alpha 중립 default 는 1(불투명) — 0 이면 레이어 투명")
        XCTAssertEqual(bareColor.defaultValue, [1, 1, 1], "bare g_Color 중립 default 는 (1,1,1) 무-틴트 — 0 이면 검정")

        // (B) 경계 잠금: 어노테이션이 있으면 여전히 머티리얼(어노테이션 default 우선, 중립 아님).
        let annFrag = """
        uniform vec3 g_Color; // {"material":"color","default":"1 0 0"}
        void main() { gl_FragColor = vec4(g_Color, 1.0); }
        """
        let tAnn = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: annFrag, combos: [:]))
        let annColor = try XCTUnwrap(tAnn.materialParams.first { $0.glslName == "g_Color" }, "g_Color 미분류")
        XCTAssertEqual(annColor.defaultValue, [1, 0, 0], "어노테이션 default 가 중립값에 우선해야 함")
        XCTAssertEqual(annColor.sceneKey, "color", "어노테이션 material 키 유지")
    }

    // MARK: - 번역 메모이즈 (프로세스 전역 캐시; 마운트 41%·중복 최악 763회 실측 대응)

    func testMemoizeSameInputsTranslateOnce() throws {
        GLSLTranslator._resetTranslationMemoForTesting()
        let c0 = GLSLTranslator.memoComputeCount
        let t1 = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: ["MASK": 0]))
        let t2 = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: ["MASK": 0]))
        XCTAssertEqual(GLSLTranslator.memoComputeCount - c0, 1, "동일 (소스,combos) 2회 → 실번역 1회")
        XCTAssertEqual(t1, t2, "캐시 히트 = 동일 출력(TranslatedShader Equatable)")
        XCTAssertEqual(t1.msl, t2.msl)
    }

    func testMemoizeDifferentCombosTranslateSeparately() throws {
        GLSLTranslator._resetTranslationMemoForTesting()
        let c0 = GLSLTranslator.memoComputeCount
        let on = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: ["MASK": 1]))
        let off = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: ["MASK": 0]))
        XCTAssertEqual(GLSLTranslator.memoComputeCount - c0, 2, "다른 combos → 별도 번역")
        XCTAssertNotEqual(on.msl, off.msl, "MASK 분기가 다른 MSL 산출")
        // 동일 재요청은 각각 히트(추가 번역 0).
        _ = GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: ["MASK": 1])
        _ = GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: ["MASK": 0])
        XCTAssertEqual(GLSLTranslator.memoComputeCount - c0, 2, "동일 재요청은 캐시 히트")
    }

    func testMemoizeKeysOnResolvedIncludeContent() throws {
        // 동일 (vertex, fragment, combos) 라도 #include 가 다른 내용으로 리졸브되면 별도 번역·다른 출력.
        // → base-assets 교체/패키지별 인클루드 상이 시 스테일 히트 방지의 순수성 회귀 가드.
        GLSLTranslator._resetTranslationMemoForTesting()
        let vert = "attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }"
        let frag = "#include \"col.h\"\nvoid main() { gl_FragColor = COLOR; }"
        let incRed: (String) -> String? = { _ in "#define COLOR vec4(1.0, 0.0, 0.0, 1.0)" }
        let incGreen: (String) -> String? = { _ in "#define COLOR vec4(0.0, 1.0, 0.0, 1.0)" }
        let c0 = GLSLTranslator.memoComputeCount
        let tRed = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:], include: incRed))
        let tGreen = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:], include: incGreen))
        XCTAssertEqual(GLSLTranslator.memoComputeCount - c0, 2, "다른 인클루드 내용 → 별도 번역(내용 기반 키)")
        XCTAssertNotEqual(tRed.msl, tGreen.msl, "다른 인클루드 → 다른 MSL(스테일 히트 없음)")
        XCTAssertTrue(tRed.msl.contains("float4(1.0, 0.0, 0.0, 1.0)"))
        XCTAssertTrue(tGreen.msl.contains("float4(0.0, 1.0, 0.0, 1.0)"))
        // 동일 인클루드 재요청 → 히트(추가 번역 0).
        _ = GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:], include: incRed)
        XCTAssertEqual(GLSLTranslator.memoComputeCount - c0, 2, "동일 인클루드 내용은 히트")
    }

    func testMemoizeCrossStageComboInIncludeNotAliased() throws {
        // 완전성 회귀: 교차스테이지 콤보 union 은 raw 소스에서 parseComboDefaults 로 만들어진다(_translate).
        // 프래그먼트가 #include 로 들여온 [COMBO] 는 raw 엔 없어(=#include 줄) union 에 안 들어가지만,
        // 인라인 소스엔 있다 → 인라인만으로 키를 잡으면 (인라인 동일, raw 상이) 두 씬이 aliasing 되어
        // vertex 의 #if 분기가 뒤바뀐다. raw 소스도 키에 포함해야 한다.
        GLSLTranslator._resetTranslationMemoForTesting()
        let vert = """
        attribute vec3 a_Position;
        void main() {
        #if FOO
            gl_Position = vec4(1.0, 0.0, 0.0, 1.0);
        #else
            gl_Position = vec4(0.0, 1.0, 0.0, 1.0);
        #endif
        }
        """
        let comboLine = "// [COMBO] {\"combo\":\"FOO\",\"default\":1}"
        let fragViaInclude = "#include \"foo.h\"\nvoid main() { gl_FragColor = vec4(1.0); }"
        let fragInline = comboLine + "\nvoid main() { gl_FragColor = vec4(1.0); }"
        // X: 프래그먼트가 foo.h(=[COMBO] FOO) 를 include. Y: 동일 [COMBO] 를 인라인. 인라인 결과는 동일.
        let tX = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: fragViaInclude, combos: [:],
                                                        include: { $0 == "foo.h" ? comboLine : nil }))
        let tY = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: fragInline, combos: [:]))
        // 인클루드-내 [COMBO] 는 교차스테이지 union 에 안 들어가므로 X 는 #if FOO 거짓(green), Y 는 참(red).
        XCTAssertTrue(tX.msl.contains("float4(0.0, 1.0, 0.0, 1.0)"), "X: 인클루드 [COMBO] 미전파 → #else")
        XCTAssertTrue(tY.msl.contains("float4(1.0, 0.0, 0.0, 1.0)"), "Y: 인라인 [COMBO] 전파 → #if")
        XCTAssertNotEqual(tX.msl, tY.msl, "raw 상이 → 별도 번역(aliasing 금지)")
        XCTAssertEqual(GLSLTranslator.memoComputeCount, 2, "두 입력은 별도 실번역(스테일 히트 없음)")
    }

    /// mul(a,b) → (b*a) — **인자 순서를 뒤집어야** WE(HLSL) 와 같은 사상이 된다. HLSL 은 m[행][열],
    /// MSL 은 m[열][행]이라 같은 소스 대입문이 만드는 행렬은 서로 전치이고, 그래서 HLSL `mul(v,M)`
    /// (행벡터)의 MSL 등가식은 `M*v` 다. 종전 (a*b) 는 전치 오역이라 squareToQuad 원근이 뒤집혔고
    /// lightshafts 41패스 중 19패스가 mask≡0(fx≡0)으로 소등돼 있었다.
    /// 판별은 아래 testMulReproducesSquareToQuadCorners 가 수치로 한다 — 이 테스트는 방출 순서만 고정.
    func testMulPreservesOrderForPerspective() throws {
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform vec2 g_Point0; // {"material":"point0","default":"0 0"}
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec3 v_Fx;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            mat3 xform = mat3(1.0, 0.0, 0.0, 0.8, 1.0, 0.0, 0.0, 0.0, 1.0);
            v_Fx = mul(vec3(a_TexCoord.xy, 1.0), xform);
        }
        """
        let frag = """
        varying vec3 v_Fx;
        void main() { gl_FragColor = vec4(v_Fx.xy / v_Fx.z, 0.0, 1.0); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        // F388: vertex 스테이지 struct 존재만 전제조건으로 확인(과거엔 이 결과로 얻은 Range 를
        // 실제로 쓰지 않고 즉시 버렸다 — 아래 실제 어서션은 t.msl 전체를 다시 검색해 독립 계산됨).
        guard t.msl.contains("vertex Vary ev_main") else {
            return XCTFail("ev_main 미발견:\n\(t.msl)")
        }
        // v_Fx 대입식에서 xform 이 a_TexCoord 보다 먼저 나와야 (b*a) 순서 = M·v.
        let vfx = try XCTUnwrap(t.msl.range(of: "out.v_Fx = ("))
        let tail = String(t.msl[vfx.upperBound...]).prefix(120)
        let aPos = try XCTUnwrap(tail.range(of: "a_TexCoord"), "v_Fx 대입식에 a_TexCoord 토큰 부재:\n\(tail)")
        let mPos = try XCTUnwrap(tail.range(of: "xform"), "v_Fx 대입식에 xform 토큰 부재:\n\(tail)")
        XCTAssertLessThan(mPos.lowerBound, aPos.lowerBound,
                          "mul(vec, M) 은 (M * vec) 로 방출돼야 — (vec * M) 이면 원근이 전치된다:\n\(tail)")
        // MVP(항등) 경로는 순서와 무관하게 항상 정상(가드).
        XCTAssertTrue(t.msl.contains("eng.mvp"))
    }

    /// 판별식: `squareToQuad` 는 **정의상** 단위정사각형 코너를 (p0,p1,p2,p3) 로 보내야 한다.
    /// common_perspective.h 를 그대로 인라인해 번역한 뒤, 방출된 곱셈 순서와 동일한 규약으로
    /// CPU 에서 코너 4점을 통과시켜 저작 점열과 일치하는지 본다 — 순서가 뒤집히면(전치) 코너가
    /// 전혀 다른 곳으로 간다(실물 3690417937 점열에서 (0,0)→(-0.031,-0.757), p0 는 (0.677,0.013)).
    ///
    /// 텍스트 어서션이 아니라 수치 어서션인 이유: 방출 순서만 보는 테스트는 "어느 쪽이 맞는가" 를
    /// 판정하지 못한다(d45c259 가 정확히 그렇게 반대 방향을 고정했다). 이 함수는 이름이 곧 계약이다.
    func testMulReproducesSquareToQuadCorners() throws {
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec3 v_Fx;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            mat3 m = mat3(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0);
            m[0][0] = 0.1; m[0][1] = 0.2; m[0][2] = 0.3;
            m[1][0] = 0.4; m[1][1] = 0.5; m[1][2] = 0.6;
            m[2][0] = 0.7; m[2][1] = 0.8; m[2][2] = 1.0;
            v_Fx = mul(vec3(a_TexCoord.xy, 1.0), m);
        }
        """
        let frag = """
        varying vec3 v_Fx;
        void main() { gl_FragColor = vec4(v_Fx, 1.0); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("(m * float3(vin.a_TexCoord.xy, 1.0))"),
                      "mul(v, m) → (m * v) 로 방출돼야 한다:\n\(t.msl)")

        // 방출식과 같은 규약(M·v, MSL 열-우선 m[열][행])을 CPU 로 재현해 squareToQuad 계약을 검산한다.
        // p0=(0.67728,0.01297) p1=(0.76007,0.14043) p2=(0.46654,1.09592) p3=(0.16363,0.44881) 은
        // lightshafts.vert 의 실제 어노테이션 기본값이다.
        let p0 = (x: 0.67728, y: 0.01297), p1 = (x: 0.76007, y: 0.14043)
        let p2 = (x: 0.46654, y: 1.09592), p3 = (x: 0.16363, y: 0.44881)
        // common_perspective.h squareToQuad 의 그대로: dx2/dy2 는 p3, dx3/dy3 는 p2.
        let (dx0, dy0, dx1, dy1) = (p0.x, p0.y, p1.x, p1.y)
        let (dx2, dy2, dx3, dy3) = (p3.x, p3.y, p2.x, p2.y)
        let diffx1 = dx1 - dx3, diffy1 = dy1 - dy3
        let diffx2 = dx2 - dx3, diffy2 = dy2 - dy3
        let det = diffx1 * diffy2 - diffx2 * diffy1
        let sumx = dx0 - dx1 + dx3 - dx2, sumy = dy0 - dy1 + dy3 - dy2
        XCTAssertNotEqual(det, 0, "실물 점열은 비퇴화 — 퇴화 분기를 타면 이 검산이 무의미하다")
        let ovdet = 1.0 / det
        let g = (sumx * diffy2 - diffx2 * sumy) * ovdet
        let h = (diffx1 * sumy - sumx * diffy1) * ovdet
        // m[열][행] — GLSL/MSL 규약 그대로.
        let m: [[Double]] = [[dx1 - dx0 + g * dx1, dy1 - dy0 + g * dy1, g],
                             [dx2 - dx0 + h * dx2, dy2 - dy0 + h * dy2, h],
                             [dx0, dy0, 1.0]]
        // 방출식 (m * v): result[행] = Σ_열 m[열][행]·v[열].
        func apply(_ u: Double, _ v: Double) -> (x: Double, y: Double) {
            let vec = [u, v, 1.0]
            var r = [0.0, 0.0, 0.0]
            for row in 0..<3 { r[row] = (0..<3).reduce(0) { $0 + m[$1][row] * vec[$1] } }
            return (r[0] / r[2], r[1] / r[2])
        }
        let corners = [((0.0, 0.0), p0), ((1.0, 0.0), p1), ((1.0, 1.0), p2), ((0.0, 1.0), p3)]
        for ((u, v), want) in corners {
            let got = apply(u, v)
            XCTAssertEqual(got.x, want.x, accuracy: 1e-6, "squareToQuad(\(u),\(v)).x")
            XCTAssertEqual(got.y, want.y, accuracy: 1e-6, "squareToQuad(\(u),\(v)).y")
        }
        // 네거티브: 전치 규약(v·M)이면 같은 행렬이 코너를 전혀 다른 곳으로 보낸다 — 검산이 유효함을 보증.
        func applyTransposed(_ u: Double, _ v: Double) -> (x: Double, y: Double) {
            let vec = [u, v, 1.0]
            var r = [0.0, 0.0, 0.0]
            for col in 0..<3 { r[col] = (0..<3).reduce(0) { $0 + m[col][$1] * vec[$1] } }
            return (r[0] / r[2], r[1] / r[2])
        }
        let bad = applyTransposed(0, 0)
        XCTAssertGreaterThan(abs(bad.x - p0.x) + abs(bad.y - p0.y), 0.5,
                             "전치 규약이 우연히 같은 답을 내면 이 검산은 판별력이 없다")
    }

    func testPremultiplyOutputWrapsFragment() throws {
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: [:], premultiplyOutput: true))
        XCTAssertTrue(t.msl.contains("float4 layerTint;"), "EngineU must include layerTint")
        XCTAssertTrue(t.msl.contains("gl_FragColor.rgb *= eng.layerTint.rgb;"))
        XCTAssertTrue(t.msl.contains("gl_FragColor.a *= eng.layerTint.a;"))
        XCTAssertTrue(t.msl.contains("return float4(gl_FragColor.rgb * gl_FragColor.a, gl_FragColor.a);"))
        XCTAssertFalse(t.msl.contains("return gl_FragColor;"))
    }

    func testDefaultNoPremultiplyKeepsStraightAlpha() throws {
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: [:]))
        XCTAssertTrue(t.msl.contains("return gl_FragColor;"))
        XCTAssertFalse(t.msl.contains("gl_FragColor.rgb *= eng.layerTint.rgb;"))
        XCTAssertTrue(t.msl.contains("float4 layerTint;"), "EngineU always includes layerTint")
    }

    // MARK: - [2026-08-21] 정점 attribute 화이트리스트 (docs/re/shader-uniforms.md §7.6)

    /// **무회귀 기준선**: `a_Normal` 을 안 쓰는 셰이더의 `VIn` 방출 문자열은 **글자 그대로**
    /// 종전과 같아야 한다. 이 단언이 깨지면 2D 레이어/이펙트 쿼드 파이프라인이 통째로 위험하다
    /// (그 정점 디스크립터는 attribute 0·1 만 선언한다).
    func testVInIsUnchangedForShadersThatDoNotReferenceExtraAttributes() throws {
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: opacityFrag, combos: [:]))
        XCTAssertEqual(t.vertexAttributes, ["a_Position", "a_TexCoord"])
        XCTAssertTrue(t.msl.contains(
            "struct VIn { float3 a_Position [[attribute(0)]]; float2 a_TexCoord [[attribute(1)]]; };"),
            "종전 방출과 글자 그대로 같아야 한다")
        XCTAssertFalse(t.msl.contains("a_Normal"))
    }

    /// **참조하면 싣는다.** 종전에는 `a_Normal` 을 선언한 셰이더가 `VIn` 에 없는 멤버
    /// (`vin.a_Normal`)를 읽어 MSL 컴파일이 **확정 실패**했다(→ 폴백). 설치본 실측 도달은
    /// `a_Normal` 17파일, 그중 저작레인 8(§7.6 의 표).
    func testVInLoadsNormalAttributeWhenReferenced() throws {
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        attribute vec3 a_Normal;
        varying vec2 v_TexCoord;
        varying vec3 v_Normal;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
            v_Normal = a_Normal;
        }
        """
        let frag = """
        varying vec2 v_TexCoord;
        varying vec3 v_Normal;
        uniform sampler2D g_Texture0;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * vec4(v_Normal, 1.0); }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertEqual(t.vertexAttributes, ["a_Position", "a_TexCoord", "a_Normal"])
        XCTAssertTrue(t.msl.contains("float3 a_Normal [[attribute(2)]];"),
                      "슬롯 2 는 정점 디스크립터와의 계약이다(메시 8f 정점의 오프셋 12)")
        XCTAssertTrue(t.msl.contains("vin.a_Normal"), "본문 참조는 그대로 남는다")
    }

    /// **선언만 있고 `#if` 로 잘려 나간 참조는 안 싣는다.** 선언을 기준으로 실으면 2D 쿼드
    /// 파이프라인(법선 없는 정점 버퍼)이 파이프라인 생성 단계에서 통째로 깨진다 —
    /// 컴파일 실패가 파이프라인 실패로 바뀔 뿐이라 아무것도 안 나아지고 진단만 나빠진다.
    func testDeclaredButUnreferencedNormalIsNotLoaded() throws {
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        attribute vec3 a_Normal;
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        #if LIGHTING
            v_TexCoord += a_Normal.xy;
        #endif
        }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
        """
        let off = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: ["LIGHTING": 0]))
        XCTAssertEqual(off.vertexAttributes, ["a_Position", "a_TexCoord"],
                       "`#if` 로 잘린 참조는 세면 안 된다")
        XCTAssertFalse(off.msl.contains("a_Normal"))
        // 대조군 — 같은 소스를 콤보만 켜면 실린다(테스트가 그냥 항상 false 를 재는 것이 아님을 보인다).
        let on = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: ["LIGHTING": 1]))
        XCTAssertEqual(on.vertexAttributes, ["a_Position", "a_TexCoord", "a_Normal"])
    }

    /// 화이트리스트 **밖**의 attribute 는 여전히 안 싣는다 — 정점 버퍼에 그 데이터가 없기
    /// 때문이다(`a_Color` 9파일 · `a_Tangent4` 8 · 스키닝 10/9). 싣기만 하면 컴파일 실패가
    /// 파이프라인 실패로 바뀔 뿐이고, 둘 다 폴백이다. 버퍼 레이아웃 확장이 선행돼야 한다.
    func testNonWhitelistedAttributesStayUnloaded() throws {
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        attribute vec4 a_Color;
        varying vec4 v_Color;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_Color = a_Color;
        }
        """
        let frag = """
        varying vec4 v_Color;
        void main() { gl_FragColor = v_Color; }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertEqual(t.vertexAttributes, ["a_Position", "a_TexCoord"])
        XCTAssertFalse(t.msl.contains("a_Color [[attribute("),
                       "화이트리스트 밖은 VIn 에 안 실린다 — 실리면 파이프라인 생성이 깨진다")
        XCTAssertTrue(t.msl.contains("vin.a_Color"), "참조는 남아 MSL 컴파일이 실패한다(= 폴백, 의도)")
        XCTAssertEqual(GLSLTranslator.vertexAttributeWhitelist.map({ $0.name }),
                       ["a_Position", "a_TexCoord", "a_Normal"],
                       "화이트리스트를 넓히려면 정점 디스크립터 세 자리를 같이 봐야 한다")
    }

    /// **(a)와 (b)는 함께 가야 한다.** `GLSLTranslator` 가 `a_Normal` 을 싣는데 정점
    /// 디스크립터가 `attribute(2)` 를 안 꽂으면 MSL **컴파일 실패**가 **파이프라인 생성 실패**로
    /// 바뀔 뿐이다(둘 다 폴백이지만 진단이 나빠지고, 반대로 디스크립터만 꽂으면 무의미하다).
    /// 리눅스에서 `WapleRender` 를 실행할 수 없으므로 소스를 직접 읽어 잠근다.
    func testMeshVertexDescriptorWiresNormalUnderTheSameCondition() throws {
        // `#filePath` 를 그대로 쓰면 안 되는 이유는 `TexSpriteSheetBlendTests.repoRoot()` 주석 참조
        // (리눅스 하네스는 테스트 파일을 심볼릭 링크로 건다).
        let root = try TexSpriteSheetBlendTests.repoRoot()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/WapleRender/SceneRenderer3D.swift"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("t.vertexAttributes.contains(\"a_Normal\")"),
                      "정점 디스크립터가 번역기와 **같은 조건**을 봐야 한다")
        XCTAssertTrue(src.contains("vd.attributes[2].format = .float3; vd.attributes[2].offset = 12"),
                      "법선은 메시 8f 정점의 오프셋 12 에 이미 있다 — 새 버퍼가 필요 없다")
    }

    /// 참조 판정은 **낱말 단위**다 — `a_TexCoord` 는 실물 `a_TexCoordVec4`/`a_TexCoordC2` 의
    /// 접두라 단순 `contains` 는 화이트리스트가 넓어지는 날 조용히 틀린다.
    func testAttributeReferenceCheckIsWordAccurate() {
        XCTAssertTrue(GLSLTranslator.referencesVertexAttribute("a_Normal", in: "out.v = vin.a_Normal;"))
        XCTAssertTrue(GLSLTranslator.referencesVertexAttribute("a_Normal", in: "vin.a_Normal"))
        XCTAssertTrue(GLSLTranslator.referencesVertexAttribute("a_Normal", in: "f(vin.a_Normal.xy)"))
        XCTAssertFalse(GLSLTranslator.referencesVertexAttribute("a_Normal", in: "out.v = vin.a_NormalMap;"))
        XCTAssertFalse(GLSLTranslator.referencesVertexAttribute("a_TexCoord", in: "vin.a_TexCoordVec4"))
        XCTAssertTrue(GLSLTranslator.referencesVertexAttribute("a_TexCoord", in: "vin.a_TexCoordVec4; vin.a_TexCoord;"),
                      "접두 오탐을 피하느라 진짜 참조를 놓치면 안 된다")
    }
}
