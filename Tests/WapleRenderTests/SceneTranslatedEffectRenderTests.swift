import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// Step 4: GLSL→MSL 변환기를 SceneRenderer 효과 경로에 통합 검증.
/// 두 테스트 모두 **비-스톡 효과 이름**을 써서 폴백-프루프:
/// 번역/컴파일/바인딩이 깨지면 → 핸드포팅 없음 → 스킵 → 레이어 풀밝기(luma≈1) → 실패.
/// translated 경로가 실제로 실행돼야만 dim(luma≈0.4)이 나온다.
final class SceneTranslatedEffectRenderTests: XCTestCase {
    private func renderLuma(scene: String, extraFiles: [(String, Data)], tag: String) throws -> Double {
        var files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
        ]
        files.append(contentsOf: extraFiles)
        let pkg = encodePkg(files)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_tr_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pkg.write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let outDir = URL(fileURLWithPath: "/tmp/waple_tr_\(tag)")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let urls = r.captureFrames(width: 64, height: 36, times: [0.1], toDir: outDir)
        return avgLuma(try XCTUnwrap(urls.first))
    }

    /// 비-스톡 효과 "dim40"(GLSL 임베드, 핸드포팅 없음): translated 경로가 alpha=0.4 로 dim.
    /// 스킵되면 풀밝기(~1.0)가 되므로 0.4 가 나오면 변환 경로 실행 증명.
    func testCustomEffectRendersViaTranslator() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform float g_UserAlpha; // {"material":"alpha","default":1.0}
        void main() {
            vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
            albedo.a *= g_UserAlpha;
            gl_FragColor = albedo;
        }
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/dim40/effect.json","passes":[{"constantshadervalues":{"alpha":0.4}}]}]}]}
        """
        let luma = try renderLuma(scene: scene, extraFiles: [
            ("shaders/effects/dim40.vert", vert.data(using: .utf8)!),
            ("shaders/effects/dim40.frag", frag.data(using: .utf8)!),
        ], tag: "dim40")
        NSLog("%@", "[Waple] translated custom-effect luma=\(luma)")
        XCTAssertLessThan(luma, 0.7, "translated path must run (skip → ~1.0)")
        XCTAssertEqual(luma, 0.4, accuracy: 0.1, "alpha 0.4 → ~40% over black via translated shader")
    }

    /// 워크샵 효과 레이아웃(실측 확인): scene 의 effect file = "effects/workshop/<wsid>/<Name>/effect.json",
    /// material = "materials/workshop/<wsid>/effects/<Name>.json"(shader="workshop/<wsid>/effects/<Name>"),
    /// 셰이더 = "shaders/workshop/<wsid>/effects/<Name>.{vert,frag}". 짧은 이름만으론 wsid 경로 유실 → 발견 실패.
    /// effect.json→material→shader 체인을 file 경로 기준으로 해석해야 translated 경로가 동작.
    func testWorkshopEffectRendersViaTranslator() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform float g_UserAlpha; // {"material":"alpha","default":1.0}
        void main() {
            vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
            albedo.a *= g_UserAlpha;
            gl_FragColor = albedo;
        }
        """
        let ws = "2084198056", name = "Dimmer"
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/workshop/\(ws)/\(name)/effect.json","passes":[{"constantshadervalues":{"alpha":0.4}}]}]}]}
        """
        let effectJSON = #"{"passes":[{"material":"materials/workshop/\#(ws)/effects/\#(name).json"}]}"#
        let materialJSON = #"{"passes":[{"shader":"workshop/\#(ws)/effects/\#(name)"}]}"#
        let luma = try renderLuma(scene: scene, extraFiles: [
            ("effects/workshop/\(ws)/\(name)/effect.json", effectJSON.data(using: .utf8)!),
            ("materials/workshop/\(ws)/effects/\(name).json", materialJSON.data(using: .utf8)!),
            ("shaders/workshop/\(ws)/effects/\(name).vert", vert.data(using: .utf8)!),
            ("shaders/workshop/\(ws)/effects/\(name).frag", frag.data(using: .utf8)!),
        ], tag: "workshop")
        NSLog("%@", "[Waple] translated workshop-effect luma=\(luma)")
        XCTAssertLessThan(luma, 0.7, "workshop translated path must run (skip → ~1.0)")
        XCTAssertEqual(luma, 0.4, accuracy: 0.1, "workshop effect dims via GLSL→MSL translator (resolved from file path)")
    }

    /// Step 5(2026-07-02, 실물 검증 후 전환): 스톡 이름 효과도 pkg 가 GLSL 을 동봉하면 **translated 우선**.
    /// 동봉 GLSL(고정 빨강)과 hand-port(디밍)가 다르게 렌더되도록 하여 어느 경로가 이겼는지 판별.
    /// hand-port 가 이기면 흰색 계열, translated 가 이기면 빨강.
    func testShippedGLSLWinsOverHandPort() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            gl_FragColor = vec4(c.a, 0.0, 0.0, c.a);
        }
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/opacity/effect.json","passes":[{"constantshadervalues":{"alpha":1.0}}]}]}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_tr_flip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pkg = encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("shaders/effects/opacity.vert", vert.data(using: .utf8)!),
            ("shaders/effects/opacity.frag", frag.data(using: .utf8)!),
        ])
        try pkg.write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "flip", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "flip", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let outDir = URL(fileURLWithPath: "/tmp/waple_tr_flip")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: outDir).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let c = try XCTUnwrap(rep.colorAt(x: 32, y: 18))
        NSLog("%@", "[Waple] flip test px=(\(c.redComponent),\(c.greenComponent),\(c.blueComponent))")
        XCTAssertGreaterThan(c.redComponent, 0.8, "동봉 GLSL(빨강)이 이겨야 — hand-port(흰색)가 이기면 게이트 미전환")
        XCTAssertLessThan(c.greenComponent, 0.2, "hand-port 가 이기면 초록≈1")
    }

    /// 멀티패스(fbos/target/bind — 실물 localcontrast 구조): 1패스가 fbo 에 순빨강을 쓰고
    /// 2패스(타깃 없음=출력)가 fbo×0.5 를 출력 → 최종 (0.5,0,0). 단일패스(pass0만)면 순빨강 → 실패.
    func testMultiPassEffectWithFBO() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        let fragRed = """
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }
        """
        let fragHalf = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * vec4(0.5, 0.5, 0.5, 1.0); }
        """
        let effectJSON = """
        {"passes":[
           {"material":"materials/effects/mp_red.json","target":"_rt_Half",
            "bind":[{"name":"previous","index":0}]},
           {"material":"materials/effects/mp_half.json",
            "bind":[{"name":"_rt_Half","index":0}]}],
         "fbos":[{"name":"_rt_Half","scale":2,"format":"rgba8888"}]}
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/mptest/effect.json","passes":[{},{}]}]}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_tr_mp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("effects/mptest/effect.json", effectJSON.data(using: .utf8)!),
            ("materials/effects/mp_red.json", #"{"passes":[{"shader":"effects/mp_red"}]}"#.data(using: .utf8)!),
            ("materials/effects/mp_half.json", #"{"passes":[{"shader":"effects/mp_half"}]}"#.data(using: .utf8)!),
            ("shaders/effects/mp_red.vert", vert.data(using: .utf8)!),
            ("shaders/effects/mp_red.frag", fragRed.data(using: .utf8)!),
            ("shaders/effects/mp_half.vert", vert.data(using: .utf8)!),
            ("shaders/effects/mp_half.frag", fragHalf.data(using: .utf8)!),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "mp", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "mp", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_tr_mp")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let c = try XCTUnwrap(rep.colorAt(x: 32, y: 18))
        NSLog("%@", "[Waple] multipass px=(\(c.redComponent),\(c.greenComponent),\(c.blueComponent))")
        XCTAssertEqual(Double(c.redComponent), 0.5, accuracy: 0.06, "2패스 결과 = fbo(빨강)×0.5 (pass0만 실행이면 1.0)")
        XCTAssertLessThan(c.greenComponent, 0.1)
    }

    /// texRes per-slot(설계 §4): g_Texture1Resolution 은 aux 슬롯 1 텍스처의 실제 dims 여야 한다
    /// (레이어 dims 8x8 근사가 아니라). frag 가 x==4 를 검사해 백/흑으로 표출 — 4x2 aux 면 luma 1.
    func testAuxTextureResolutionPerSlot() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            float ok = step(3.5, g_Texture1Resolution.x) * step(g_Texture1Resolution.x, 4.5);
            gl_FragColor = vec4(c.rgb * ok, c.a);
        }
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/resprobe/effect.json","passes":[{"textures":[null,"m4"]}]}]}]}
        """
        let luma = try renderLuma(scene: scene, extraFiles: [
            ("shaders/effects/resprobe.vert", vert.data(using: .utf8)!),
            ("shaders/effects/resprobe.frag", frag.data(using: .utf8)!),
            ("materials/m4.tex", solidTex(255, 255, 255, w: 4, h: 2)),
        ], tag: "resprobe")
        NSLog("%@", "[Waple] aux texRes probe luma=\(luma)")
        XCTAssertGreaterThan(luma, 0.9, "g_Texture1Resolution must be aux dims 4x2 (layer-dims 근사면 0)")
    }

    /// _rt_ 컴포지션 레이어의 g_Texture0Resolution 은 프로젝트 크기가 아니라 실제 누적 framebuffer 크기여야 한다.
    func testFrameBufferResolutionUniformUsesCaptureTargetSize() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            float ok = step(63.5, g_Texture0Resolution.x) * step(g_Texture0Resolution.x, 64.5);
            gl_FragColor = vec4(c.rgb * ok, c.a);
        }
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/util/fullscreenlayer.json","origin":"960 540 0","size":"1920 1080",
            "effects":[{"file":"effects/fbres/effect.json","passes":[{}]}]}]}
        """
        let luma = try renderLuma(scene: scene, extraFiles: [
            ("models/util/fullscreenlayer.json", #"{"material":"materials/util/fullscreenlayer.json","fullscreen":true}"#.data(using: .utf8)!),
            ("materials/util/fullscreenlayer.json", #"{"passes":[{"shader":"passthrough","textures":["_rt_FullFrameBuffer"]}]}"#.data(using: .utf8)!),
            ("shaders/effects/fbres.vert", vert.data(using: .utf8)!),
            ("shaders/effects/fbres.frag", frag.data(using: .utf8)!),
        ], tag: "fbres")
        NSLog("%@", "[Waple] framebuffer texRes probe luma=\(luma)")
        XCTAssertGreaterThan(luma, 0.9, "g_Texture0Resolution.x must be actual capture width 64, not projection width 1920")
    }

    /// 갓레이 각도 회귀(#): vertex mul(vec, 비대칭행렬) 원근 전개. 종전 (b*a) 전치 오역은 fxCoord.y 를
    /// 스크린 x 와 무관하게 만들어 가로띠로 렌더했다(lightshafts squareToQuad 실증). 순서보존(a*b) 이면
    /// fxCoord.y = 0.8·u + w → 같은 행에서 좌<우(슬랜트). 셰이더 자족(인클루드 불요)이라 CI 이식.
    func testVertexPerspectiveMulSlantsNotHorizontal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // GLSL column-major mat3: 열 c0=(1,0,0) c1=(0.8,1,0) c2=(0,0,1). 비대칭 → 전치 판별 가능.
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
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
        void main() {
            float y = clamp(v_Fx.y / v_Fx.z, 0.0, 1.0);
            gl_FragColor = vec4(y, y, y, 1.0);
        }
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/slanttest/effect.json","passes":[{}]}]}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_tr_slant", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("shaders/effects/slanttest.vert", vert.data(using: .utf8)!),
            ("shaders/effects/slanttest.frag", frag.data(using: .utf8)!),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "slant", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "slant", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_tr_slant")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        // 상단부 같은 행에서 좌/우 밝기(fxCoord.y = 0.8·u + w). 순서보존이면 우>좌, 전치면 동일(가로띠).
        let yRow = rep.pixelsHigh / 8
        let left = try XCTUnwrap(rep.colorAt(x: 3, y: yRow)).brightnessComponent
        let right = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide - 4, y: yRow)).brightnessComponent
        NSLog("%@", "[Waple] perspective-mul slant left=\(left) right=\(right)")
        XCTAssertGreaterThan(right - left, 0.3,
                             "vertex mul(vec, 비대칭M) 슬랜트: 우(\(right)) - 좌(\(left)) > 0.3 — 전치 오역이면 ≈0(가로띠)")
    }

    /// 실제 WE opacity GLSL 을 비-스톡 이름 "opacitytest" 로 변환·렌더 → 핸드포팅 오라클(alpha 0.4 → ~0.4)과 수치 일치.
    /// 비-스톡 이름이라 번역이 깨지면 폴백이 가리지 못하고 ~1.0 → 실패.
    func testTranslatedOpacityMatchesHandPort() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
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
        let frag = """
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
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/opacitytest/effect.json","passes":[{"combos":{"MASK":0},"constantshadervalues":{"alpha":0.4}}]}]}]}
        """
        let luma = try renderLuma(scene: scene, extraFiles: [
            ("shaders/effects/opacitytest.vert", vert.data(using: .utf8)!),
            ("shaders/effects/opacitytest.frag", frag.data(using: .utf8)!),
        ], tag: "opacitytest")
        NSLog("%@", "[Waple] translated opacity luma=\(luma)")
        XCTAssertLessThan(luma, 0.7, "translated path must run (skip → ~1.0)")
        XCTAssertEqual(luma, 0.4, accuracy: 0.1, "translated opacity matches hand-port oracle (alpha 0.4)")
    }

    /// X-⑤: g_TexelSize 는 이펙트 **출력(dst)** 해상도 기준(WE gaussian.vert `ratio = g_TexelSize *
    /// g_Texture0Resolution` 실측 — bokeh_blur 최종 패스가 tex0=scale4 다운샘플 fbo 를 bind 해도 그 결과가
    /// 소스/타깃 스케일비(1/4)가 되려면 g_TexelSize=1/dst 여야 성립). scale:4 다운샘플 fbo 를 거친 뒤
    /// 최종(타깃 없음=dst) 패스가 g_TexelSize.x 를 직접 색으로 인코딩 — dst(레이어 텍스처 8×8) 기준이면
    /// 0.125, 옛 tex0(다운샘플 fbo 2×2) 근사면 4× 과대(0.5)가 나온다.
    func testTexelSizeUsesEffectOutputNotDownscaledSource() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        let fragFill = """
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = vec4(1.0, 1.0, 1.0, 1.0); }
        """
        let fragProbe = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0; // {"hidden":true}
        void main() { gl_FragColor = vec4(g_TexelSize.x, 0.0, 0.0, 1.0); }
        """
        let effectJSON = """
        {"passes":[
           {"material":"materials/effects/tx_down.json","target":"_rt_Q",
            "bind":[{"name":"previous","index":0}]},
           {"material":"materials/effects/tx_probe.json",
            "bind":[{"name":"_rt_Q","index":0}]}],
         "fbos":[{"name":"_rt_Q","scale":4,"format":"rgba8888"}]}
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/txtest/effect.json","passes":[{},{}]}]}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_tr_tx", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("effects/txtest/effect.json", effectJSON.data(using: .utf8)!),
            ("materials/effects/tx_down.json", #"{"passes":[{"shader":"effects/tx_down"}]}"#.data(using: .utf8)!),
            ("materials/effects/tx_probe.json", #"{"passes":[{"shader":"effects/tx_probe"}]}"#.data(using: .utf8)!),
            ("shaders/effects/tx_down.vert", vert.data(using: .utf8)!),
            ("shaders/effects/tx_down.frag", fragFill.data(using: .utf8)!),
            ("shaders/effects/tx_probe.vert", vert.data(using: .utf8)!),
            ("shaders/effects/tx_probe.frag", fragProbe.data(using: .utf8)!),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "tx", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "tx", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_tr_tx")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let c = try XCTUnwrap(rep.colorAt(x: 32, y: 18))
        NSLog("%@", "[Waple] g_TexelSize probe R=\(c.redComponent)")
        // 레이어 베이스 텍스처(w.tex, solidTex 기본 8×8) = 효과 dst 크기. dst 기준(1/8=0.125)이 정답 —
        // 다운샘플 소스(scale4→2×2, 1/2=0.5) 근사로 되돌아가면 4× 과대돼 이 어서션이 실패한다.
        XCTAssertEqual(Double(c.redComponent), 0.125, accuracy: 0.05,
                      "g_TexelSize 는 다운스케일 소스(1/2)가 아니라 이펙트 dst(1/8) 기준이어야 함 — 4× 과대면 결함 재현")
    }
}
