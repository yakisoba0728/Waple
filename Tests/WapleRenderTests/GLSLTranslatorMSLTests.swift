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

    /// builtin common_blending.h(확정 의미 — 이전 세션 실물 대조로 검증된 MSL 포트의 GLSL 판):
    /// ApplyBlending/BlendSoftLight 를 쓰는 효과(실물 tint/pulse)가 include 리졸버에 builtin 을 물리면 컴파일된다.
    func testBuiltinCommonBlendingUnblocksApplyBlending() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
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
            c.rgb = ApplyBlending(BLENDMODE, c.rgb, g_Color, 0.5);
            c.rgb = BlendSoftLight(c.rgb, g_Color);
            gl_FragColor = c;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: ["BLENDMODE": 2],
                                                       include: { BuiltinShaderIncludes.lookup($0) }))
        do {
            let lib = try device.makeLibrary(source: t.msl, options: nil)
            XCTAssertNotNil(lib.makeFunction(name: "ef_main"))
        } catch {
            XCTFail("builtin common_blending MSL failed: \(error)\n\(t.msl)")
        }
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

    func testRealAudioResponsiveOscilloscopeCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        // F397: 이 레인의 자매 코퍼스-게이트 테스트(RealPackagesGroundTruthTests 등 19개소)와 동일한
        // WAPLE_REAL_PKGS 관례 — 종전엔 개발자 1인 계정 절대경로가 박혀 있어 다른 사용자/머신에선
        // 코퍼스가 있어도 영구 XCTSkip 됐다.
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let url = URL(fileURLWithPath: base).appendingPathComponent("3629379075/scene.pkg")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("real wallpaper package not installed")
        }
        let package = try ScenePackage.parse(Data(contentsOf: url))
        func string(_ path: String) throws -> String {
            let data = try XCTUnwrap(package.data(for: path), "\(path) missing")
            return try XCTUnwrap(String(data: data, encoding: .utf8), "\(path) is not UTF-8")
        }
        let vert = try string("shaders/workshop/2799421411/effects/audio_responsive_oscilloscope.vert")
        let frag = try string("shaders/workshop/2799421411/effects/audio_responsive_oscilloscope.frag")
        let combos: [String: Int] = [:]
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: combos, include: { header in
            package.data(for: "shaders/\(header)").flatMap { String(data: $0, encoding: .utf8) }
                ?? package.data(for: header).flatMap { String(data: $0, encoding: .utf8) }
                ?? BuiltinShaderIncludes.lookup(header)
        }))
        do {
            let lib = try device.makeLibrary(source: t.msl, options: nil)
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = lib.makeFunction(name: "ev_main")
            pd.fragmentFunction = lib.makeFunction(name: "ef_main")
            let vd = MTLVertexDescriptor()
            vd.attributes[0].format = .float3
            vd.attributes[0].offset = 0
            vd.attributes[0].bufferIndex = 4
            vd.attributes[1].format = .float2
            vd.attributes[1].offset = 12
            vd.attributes[1].bufferIndex = 4
            vd.layouts[4].stride = 20
            pd.vertexDescriptor = vd
            pd.colorAttachments[0].pixelFormat = .rgba8Unorm
            _ = try device.makeRenderPipelineState(descriptor: pd)
        } catch {
            XCTFail("audio_responsive_oscilloscope pipeline failed: \(error)\n--- MSL ---\n\(t.msl)")
        }
    }

    /// F770: 스칼라 distance(float, float) — MSL 은 벡터 전용 오버로드라 모호 → abs(x-y) 재작성으로 컴파일.
    /// (hermetic 최소 축약 — 실물은 아래 testRealTextGradientScalarDistanceCompiles.)
    func testF770ScalarDistanceCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let frag = """
        varying vec2 v_TexCoord;
        uniform float g_Time;
        void main() {
            float l = v_TexCoord.x - 0.5;
            float p = distance(0.0, l);
            gl_FragColor = vec4(p + g_Time * 0.0);
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: opacityVert, fragment: frag, combos: [:]))
        XCTAssertFalse(t.msl.contains("distance(0.0"), t.msl)   // 스칼라 distance 잔존 금지
        do { _ = try device.makeLibrary(source: t.msl, options: nil) }
        catch { XCTFail("F770 scalar distance MSL failed: \(error)\n\(t.msl)") }
    }

    /// F770(실물 회귀): 2842323353·2885492021 의 텍스트 그라디언트 효과(workshop/2674029580) —
    /// `float p = distance(0.0, l);` 가 그대로 MSL 로 나가 모호 오버로드로 이펙트 폴터했다.
    func testRealTextGradientScalarDistanceCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let url = URL(fileURLWithPath: base).appendingPathComponent("2842323353/scene.pkg")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("real wallpaper package not installed")
        }
        let package = try ScenePackage.parse(Data(contentsOf: url))
        func string(_ path: String) throws -> String {
            let data = try XCTUnwrap(package.data(for: path), "\(path) missing")
            return try XCTUnwrap(String(data: data, encoding: .utf8), "\(path) is not UTF-8")
        }
        let base43 = "shaders/workshop/2674029580/effects/___________________________________________"
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: try string(base43 + ".vert"),
                                                       fragment: try string(base43 + ".frag"),
                                                       combos: [:]))
        do { _ = try device.makeLibrary(source: t.msl, options: nil) }
        catch { XCTFail("text gradient (scalar distance) MSL failed: \(error)\n--- MSL ---\n\(t.msl)") }
    }

    /// F771(실물 회귀): 3300031038·3396722575·3450697231·3479521040 의 shadow(workshop/3088030303) —
    /// 버텍스 `float atFactor = (… g_ParallaxPosition …)` 의 vec2 우변이 float 에 들어가 폴터.
    /// 크기 환경에 엔진 vec2 등재로 절단 삽입돼 컴파일돼야 한다.
    func testRealShadowEngineVec2SizeCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let url = URL(fileURLWithPath: base).appendingPathComponent("3300031038/scene.pkg")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("real wallpaper package not installed")
        }
        let package = try ScenePackage.parse(Data(contentsOf: url))
        func string(_ path: String) throws -> String {
            let data = try XCTUnwrap(package.data(for: path), "\(path) missing")
            return try XCTUnwrap(String(data: data, encoding: .utf8), "\(path) is not UTF-8")
        }
        let t = try XCTUnwrap(GLSLTranslator.translate(
            vertex: try string("shaders/workshop/3088030303/effects/shadow.vert"),
            fragment: try string("shaders/workshop/3088030303/effects/shadow.frag"),
            combos: [:],
            include: { header in
                // 렌더 경로(quietAssetData)와 동일 해석 순서: pkg → 베이스에셋 → 내장.
                for cand in ["shaders/\(header)", header] {
                    if let s = package.data(for: cand).flatMap({ String(data: $0, encoding: .utf8) }) { return s }
                }
                let assets = ProcessInfo.processInfo.environment["WAPLE_BASE_ASSETS"]
                    ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/assets")
                if let d = FileManager.default.contents(atPath: assets + "/shaders/" + header),
                   let s = String(data: d, encoding: .utf8) { return s }
                return BuiltinShaderIncludes.lookup(header)
            }))
        do { _ = try device.makeLibrary(source: t.msl, options: nil) }
        catch { XCTFail("shadow (engine vec2 size) MSL failed: \(error)\n--- MSL ---\n\(t.msl)") }
    }
}
