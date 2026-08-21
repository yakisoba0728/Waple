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

    /// X-① → **W-FIT 로 정정(2026-08-21, `990aa2a`)**: `fit:N` 은 N×N 정사각이 **아니다**.
    /// "긴 변을 N 에 맞추고 종횡비를 보존하며 확대하지 않는다"(원본 `0x1401eb2cc`–`0x1401eb381`,
    /// 규약 전문은 `EffectManifest.FBO.fittedBox`). 이 테스트는 종전에 **정사각을 못 박고 있었고**
    /// 그게 옛(틀린) 규약이었다.
    ///
    /// **base 는 캡처 해상도가 아니라 레이어 텍스처 크기다.** 이펙트 체인의 dst 는
    /// `pooledOffscreen(layer.texWidth, layer.texHeight)`(FrameEncoder:1935)이고
    /// `baseW/baseH = dst.width/height`(FrameEncoder:2006)다. `layer.texWidth` 는
    /// `effW`(= 프레임버퍼 레이어면 프로젝션, 아니면 **자산 텍스처 폭**)라
    /// `solidTex` 의 기본값 8×8 을 그대로 쓰면 `fit:32` 가 **확대 금지**에 걸려 8×8 이 된다
    /// (그래서 이 테스트는 텍스처를 64×36 으로 만든다 — 첫 수정에서 이걸 놓쳐 한 번 더 빨갰다).
    ///
    /// base 64×36 에서 `fit:32` 는
    ///   w0,h0 = (64, 36) · 긴 변 = w · fittedMajor = min(32, 64) = 32
    ///   fittedMinor = trunc(Float(36)/Float(64) × Float(32)) = trunc(18.0) = 18
    /// 즉 **32×18** 이다. 프로브는 x·y 를 따로 본다 — y 까지 32 를 요구하면 정사각 규약으로
    /// 되돌아간 것이고, 반대로 (64,36)이 나오면 `fit` 이 통째로 무시돼 scale 기본값 1 로
    /// 낙하한 것이다(옛 회귀). 둘 다 8 이면 base 가 다시 자산 텍스처 기본값으로 돌아간 것이다.
    ///
    /// **[미해결]** Waple 의 base(레이어 텍스처/프로젝션)가 원본의 "이펙트 dst 서피스"
    /// (`[vtable+0x128]` @`0x1401ea5b1`)와 같은 값인지는 `990aa2a` 가 미해결로 남긴 별건이다.
    /// 이 테스트는 **Waple 의 base 정의를 못 박을 뿐** 그 동치성을 주장하지 않는다.
    ///
    /// 프레임 시점의 `g_Texture0Resolution` 은 `runtimeTexRes`(FrameEncoder:69)가 **실제 할당된
    /// 텍스처 치수**로 덮으므로, 이 프로브는 빌드 시점 `texRes` 가 아니라 **진짜 FBO 크기**를 본다.
    func testMultiPassEffectFBOFitPreservesAspect() throws {
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
        void main() { gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); }
        """
        let fragProbe = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            float okx = step(31.5, g_Texture0Resolution.x) * step(g_Texture0Resolution.x, 32.5);
            float oky = step(17.5, g_Texture0Resolution.y) * step(g_Texture0Resolution.y, 18.5);
            // r=x 만족, g=y 만족 — 실패했을 때 어느 축이 틀렸는지 픽셀로 읽는다.
            gl_FragColor = vec4(okx, oky, 0.0, 1.0);
        }
        """
        let effectJSON = """
        {"passes":[
           {"material":"materials/effects/fit_fill.json","target":"_rt_Sq",
            "bind":[{"name":"previous","index":0}]},
           {"material":"materials/effects/fit_probe.json",
            "bind":[{"name":"_rt_Sq","index":0}]}],
         "fbos":[{"name":"_rt_Sq","fit":32,"format":"rgba8888"}]}
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/fittest/effect.json","passes":[{},{}]}]}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_tr_fit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            // 64×36 — base 가 이 텍스처 크기다(위 주석). 기본값 8×8 이면 확대 금지로 8×8 이 된다.
            ("materials/w.tex", solidTex(255, 255, 255, w: 64, h: 36)),
            ("effects/fittest/effect.json", effectJSON.data(using: .utf8)!),
            ("materials/effects/fit_fill.json", #"{"passes":[{"shader":"effects/fit_fill"}]}"#.data(using: .utf8)!),
            ("materials/effects/fit_probe.json", #"{"passes":[{"shader":"effects/fit_probe"}]}"#.data(using: .utf8)!),
            ("shaders/effects/fit_fill.vert", vert.data(using: .utf8)!),
            ("shaders/effects/fit_fill.frag", fragFill.data(using: .utf8)!),
            ("shaders/effects/fit_probe.vert", vert.data(using: .utf8)!),
            ("shaders/effects/fit_probe.frag", fragProbe.data(using: .utf8)!),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "fit", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "fit", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_tr_fit")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let c = try XCTUnwrap(rep.colorAt(x: 32, y: 18))
        NSLog("%@", "[Waple] fbo fit:32 probe r(x축)=\(c.redComponent) g(y축)=\(c.greenComponent)")
        XCTAssertGreaterThan(c.redComponent, 0.9,
                             "긴 변이 32 가 아니다 — fit 이 무시돼 scale 폴백(dst 64)으로 떨어졌을 때 나는 모양")
        XCTAssertGreaterThan(c.greenComponent, 0.9,
                             "짧은 변이 18 이 아니다 — 정사각(32×32) 옛 규약으로 되돌아갔거나 dst(36)가 그대로 실렸다. "
                             + "둘 다 0 이면 base 가 레이어 텍스처가 아닌 값으로 바뀐 것이다(8×8 자산 기본값 등)")
    }

    /// X-⑦: constantshadervalues 의 {animation:{...}} 키프레임(55씬/287건) — 종전엔 파스 자체가
    /// 없어 정적 초기값(여기선 value:1.0)에 영구 고정됐다. c0 트랙이 frame0=0.1→frame30=1.0(fps30,
    /// single) 이므로 t=0 은 alpha≈0.1(어둡게), t=1.0초(=30프레임)는 alpha≈1.0(밝게) — 정적이면 두
    /// 시점 모두 luma≈1.0(value 그대로)이라 단일 프레임으로는 "애니 vs 정적"을 구분 못 함(advisor 지적) —
    /// 두 시점을 모두 캡처해 서로 달라야 함을 단언.
    func testConstantShaderValueAnimationKeyframesEvaluatePerFrame() throws {
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
        {"general": {"orthogonalprojection": {"width": 1920, "height": 1080}, "clearcolor": "0 0 0"}, "objects": [{"id": 1, "image": "models/w.json", "origin": "960 540 0", "size": "1920 1080", "effects": [{"file": "effects/animtest/effect.json", "passes": [{"constantshadervalues": {"alpha": {"value": 1.0, "animation": {"c0": [{"frame": 0, "value": 0.1, "front": {"enabled": false, "x": 0, "y": 0}, "back": {"enabled": false, "x": 0, "y": 0}}, {"frame": 30, "value": 1.0, "front": {"enabled": false, "x": 0, "y": 0}, "back": {"enabled": false, "x": 0, "y": 0}}], "options": {"fps": 30, "mode": "single"}}}}}]}]}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_tr_anim", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("shaders/effects/animtest.vert", vert.data(using: .utf8)!),
            ("shaders/effects/animtest.frag", frag.data(using: .utf8)!),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "anim", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "anim", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_tr_anim")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let urls = r.captureFrames(width: 64, height: 36, times: [0.0, 1.0], toDir: out)
        XCTAssertEqual(urls.count, 2)
        let lumaAtT0 = avgLuma(urls[0])
        let lumaAtT1 = avgLuma(urls[1])
        NSLog("%@", "[Waple] constantshadervalue animation lumaAtT0=\(lumaAtT0) lumaAtT1=\(lumaAtT1)")
        XCTAssertEqual(lumaAtT0, 0.1, accuracy: 0.1, "t=0(frame0) → alpha≈0.1(어두움)")
        XCTAssertEqual(lumaAtT1, 1.0, accuracy: 0.1, "t=1.0초(frame30) → alpha≈1.0(밝음)")
        XCTAssertGreaterThan(lumaAtT1 - lumaAtT0, 0.5,
                             "정적 고정(value:1.0)이면 두 시점 모두 luma≈1.0 이라 차이가 거의 0 — 애니가 실제로 평가돼야 함")
    }

    /// X-②: effect.json `command:"swap"`(실물 fluidsimulation velocity/dye 더블버퍼) — 종전엔 셰이더
    /// 패스로 오해석돼(material/shader 부재 → "effects/<name>" 관례 조회 실패) 효과 전체가 드롭됐다.
    /// pass0 이 _rt_A 에 빨강을 채우고, swap(A,B) 로 포인터를 교환한 뒤, pass2 가 _rt_B 를 읽어 그대로
    /// 출력 — swap 이 실제 포인터 교환이면 빨강(luma≈0.33), 효과가 드롭되면 베이스(흰색, luma≈1.0).
    func testSwapCommandPassSwapsBufferIdentity() throws {
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
        let fragPassthrough = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
        """
        let effectJSON = """
        {"passes":[
           {"material":"materials/effects/swap_red.json","target":"_rt_A",
            "bind":[{"name":"previous","index":0}]},
           {"command":"swap","source":"_rt_A","target":"_rt_B"},
           {"material":"materials/effects/swap_read.json",
            "bind":[{"name":"_rt_B","index":0}]}],
         "fbos":[{"name":"_rt_A","scale":1,"format":"rgba8888"},{"name":"_rt_B","scale":1,"format":"rgba8888"}]}
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/swaptest/effect.json","passes":[{},{},{}]}]}]}
        """
        let luma = try renderLuma(scene: scene, extraFiles: [
            ("effects/swaptest/effect.json", effectJSON.data(using: .utf8)!),
            ("materials/effects/swap_red.json", #"{"passes":[{"shader":"effects/swap_red"}]}"#.data(using: .utf8)!),
            ("materials/effects/swap_read.json", #"{"passes":[{"shader":"effects/swap_read"}]}"#.data(using: .utf8)!),
            ("shaders/effects/swap_red.vert", vert.data(using: .utf8)!),
            ("shaders/effects/swap_red.frag", fragRed.data(using: .utf8)!),
            ("shaders/effects/swap_read.vert", vert.data(using: .utf8)!),
            ("shaders/effects/swap_read.frag", fragPassthrough.data(using: .utf8)!),
        ], tag: "swaptest")
        NSLog("%@", "[Waple] swap command luma=\(luma)")
        XCTAssertLessThan(luma, 0.6, "swap 이 실제 포인터 교환이면 _rt_A 의 빨강이 _rt_B 를 통해 나와야 함(드롭되면 흰 베이스)")
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

    /// 갓레이 각도 회귀(#): vertex mul(vec, 비대칭행렬) 원근 전개. mul(a,b)→(b*a)=M·v 가 WE(HLSL)
    /// 규약이며(GLSLTranslator translateBody ① 주석의 코너 항등 판별식), 이 규약에서만 fxCoord.y 가
    /// 스크린 x 에 의존한다 — 전치 규약(v·M)이면 y=v 로 스크린 x 와 무관해져 가로띠가 된다.
    /// 셰이더 자족(인클루드 불요)이라 CI 이식.
    func testVertexPerspectiveMulSlantsNotHorizontal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // GLSL column-major mat3: 열 c0=(1,0.8,0) c1=(0,1,0) c2=(0,0,1) → m[0][1]=0.8.
        // M·v 이면 y = 0.8·u + v(슬랜트), v·M 이면 y = v(가로띠). 비대칭이라 전치 판별 가능.
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec3 v_Fx;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            mat3 xform = mat3(1.0, 0.8, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0);
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
        // 상단부 같은 행에서 좌/우 밝기(fxCoord.y = 0.8·u + v). M·v 면 우>좌, 전치(v·M)면 동일(가로띠).
        let yRow = rep.pixelsHigh / 8
        let left = try XCTUnwrap(rep.colorAt(x: 3, y: yRow)).brightnessComponent
        let right = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide - 4, y: yRow)).brightnessComponent
        NSLog("%@", "[Waple] perspective-mul slant left=\(left) right=\(right)")
        XCTAssertGreaterThan(right - left, 0.3,
                             "vertex mul(vec, 비대칭M) 슬랜트: 우(\(right)) - 좌(\(left)) > 0.3 — 전치 오역이면 ≈0(가로띠)")
    }

    /// lightshafts 소등 회귀: **실물 squareToQuad + 실물 점열**로 `mask` 를 그대로 계산해, 화면 어딘가에
    /// 반드시 0 보다 큰 값이 나오는지 본다. 전치 규약에서는 이 점열의 `v_TexCoordFx.z` 가 화면 전역에서
    /// 음수라 `step(0,z)` 가 0 → **fx ≡ 0** 이 되고, 8비트 출력이 통째로 검게 나온다(실측: 코퍼스
    /// DIRECTDRAW 41패스 중 렌더되는 34패스의 19패스가 이 상태였다 — GPU 알파 리드백 max=0).
    ///
    /// 점열은 3299228616 의 저작값(0.4 0.25 / 0.6 0.25 / 0.8 0.8 / 0.2 0.8)이고, 이 씬은 6패스 전부가
    /// 소등돼 있었다. common_perspective.h 는 pkg 에 동봉해 자족(인클루드 탐색 무의존, CI 이식).
    func testLightshaftsMaskIsNotIdenticallyZero() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        #include "common_perspective.h"
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform vec2 g_Point0; // {"material":"point0","default":"0.4 0.25"}
        uniform vec2 g_Point1; // {"material":"point1","default":"0.6 0.25"}
        uniform vec2 g_Point2; // {"material":"point2","default":"0.8 0.8"}
        uniform vec2 g_Point3; // {"material":"point3","default":"0.2 0.8"}
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec3 v_TexCoordFx;
        void main() {
            mat3 xform = inverse(squareToQuad(g_Point0, g_Point1, g_Point2, g_Point3));
            v_TexCoordFx = mul(vec3(a_TexCoord.xy, 1.0), xform);
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
        }
        """
        // lightshafts.frag 의 mask 체인(RAYMODE 0)만 발췌 — 노이즈·색은 빼고 커버리지만 본다.
        let frag = """
        varying vec3 v_TexCoordFx;
        void main() {
            vec2 fxCoord = v_TexCoordFx.xy / v_TexCoordFx.z;
            float mask = step(0.0, v_TexCoordFx.z);
            mask *= smoothstep(0.50001, 0.5 - 0.31, abs(fxCoord.x - 0.5));
            mask *= smoothstep(0.50001, 0.5 - 0.31, abs(fxCoord.y - 0.5));
            mask *= 1.0 - fxCoord.y;
            mask = clamp(mask, 0.0, 1.0);
            gl_FragColor = vec4(mask, mask, mask, 1.0);
        }
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/lstest/effect.json","passes":[{}]}]}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_tr_lsmask", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("shaders/effects/lstest.vert", vert.data(using: .utf8)!),
            ("shaders/effects/lstest.frag", frag.data(using: .utf8)!),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "lsmask", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "lsmask", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 72)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_tr_lsmask")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 128, height: 72, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        var peak = 0.0
        var lit = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let b = Double(try XCTUnwrap(rep.colorAt(x: x, y: y)).brightnessComponent)
                if b > peak { peak = b }
                if b > 0.02 { lit += 1 }
            }
        }
        let total = rep.pixelsHigh * rep.pixelsWide
        let coverage = Double(lit) / Double(total)
        NSLog("%@", "[Waple] lightshafts mask peak=\(peak) coverage=\(coverage)")
        // CPU 검산(129² 격자): peak 0.700, coverage 12.3%. 전치 규약이면 둘 다 정확히 0.
        XCTAssertGreaterThan(peak, 0.4, "mask 가 화면 전역 0 이면 fx≡0 — 원근 전치 회귀")
        XCTAssertGreaterThan(coverage, 0.02, "커버리지 2% 미만은 소등과 다름없다")
        // 상한은 **폴백 감지**다: 번역/인클루드가 깨져 이펙트가 통째로 스킵되면 흰 레이어가 그대로
        // 나와 peak≈1·coverage≈1 이 된다 — 그걸 통과로 세지 않는다.
        XCTAssertLessThan(peak, 0.95, "peak≈1 이면 이펙트가 스킵돼 베이스 흰 레이어를 본 것이다")
        XCTAssertLessThan(coverage, 0.40, "coverage≈1 이면 이펙트가 스킵된 것(마스크는 화면 일부만 덮는다)")
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

    /// X-④a: 셰이더 샘플러 주석의 `"default":"경로"`(예: util/greenmark) 가 씬/머티리얼 어느 쪽도 슬롯을
    /// 지정하지 않을 때 실제 자산으로 해석돼야 한다. 종전엔 어노테이션이 통째로 버려져 흰색 1×1(luma 1.0)
    /// 이었다 — 초록 자산이 실제로 바인드되면 luma 는 초록의 (0+1+0)/3≈0.33.
    func testSamplerDefaultAnnotationResolvesRealAsset() throws {
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
        uniform sampler2D g_Texture0; // {"hidden":true}
        uniform sampler2D g_Texture1; // {"hidden":true,"default":"util/greenmark"}
        void main() {
            gl_FragColor = texSample2D(g_Texture1, v_TexCoord);
        }
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/defaulttex/effect.json","passes":[{}]}]}]}
        """
        let luma = try renderLuma(scene: scene, extraFiles: [
            ("shaders/effects/defaulttex.vert", vert.data(using: .utf8)!),
            ("shaders/effects/defaulttex.frag", frag.data(using: .utf8)!),
            ("materials/util/greenmark.tex", solidTex(0, 255, 0)),
        ], tag: "defaulttex")
        NSLog("%@", "[Waple] sampler default-annotation luma=\(luma)")
        XCTAssertLessThan(luma, 0.6, "default 어노테이션이 해석되면 초록(luma≈0.33) — 미해석이면 흰색 폴백(luma≈1.0)")
    }

    /// X-④b: godrays/shine 의 COPYBG 콤보(`_rt_FullFrameBuffer` aux 슬롯)가 씬 컬러 스냅샷으로 실제
    /// 바인드돼야 한다 — 컴포지션(fullscreenlayer) 레이어의 효과 체인에서 배경 레이어의 색이 그대로
    /// 나와야 하고(luma≈0.33, 빨강), 미바인드면 흰색 1×1 폴백(luma≈1.0).
    func testFullFrameBufferAuxSlotBindsSceneSnapshot() throws {
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
        uniform sampler2D g_Texture0; // {"hidden":true}
        uniform sampler2D g_Texture1; // {"hidden":true,"default":"_rt_FullFrameBuffer"}
        void main() {
            gl_FragColor = texSample2D(g_Texture1, v_TexCoord);
        }
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/bg.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/util/fullscreenlayer.json","origin":"960 540 0","size":"1920 1080",
            "effects":[{"file":"effects/copybg/effect.json","passes":[{}]}]}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_tr_copybg", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/bg.json", #"{"material":"materials/bg.json"}"#.data(using: .utf8)!),
            ("materials/bg.json", #"{"passes":[{"textures":["bg"]}]}"#.data(using: .utf8)!),
            ("materials/bg.tex", solidTex(255, 0, 0)),
            ("models/util/fullscreenlayer.json", #"{"material":"materials/util/fullscreenlayer.json","fullscreen":true}"#.data(using: .utf8)!),
            ("materials/util/fullscreenlayer.json", #"{"passes":[{"shader":"passthrough","textures":["_rt_FullFrameBuffer"]}]}"#.data(using: .utf8)!),
            ("shaders/effects/copybg.vert", vert.data(using: .utf8)!),
            ("shaders/effects/copybg.frag", frag.data(using: .utf8)!),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "copybg", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "copybg", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_tr_copybg")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
        let luma = avgLuma(url)
        NSLog("%@", "[Waple] COPYBG fullframe-snapshot luma=\(luma)")
        XCTAssertLessThan(luma, 0.6, "_rt_FullFrameBuffer 가 씬 스냅샷에 바인드되면 배경(빨강, luma≈0.33) — 미바인드면 흰색 폴백(luma≈1.0)")
    }

    /// B2-effects④ 지적: copybackground:false 로 이 컴포지션 레이어의 이펙트 체인 *입력*(chain src)이
    /// 투명으로 시작해도, `_rt_FullFrameBuffer` aux 슬롯(godrays/shine COPYBG)은 chain src 와 별개 요청이라
    /// 여전히 실제 씬 컬러를 바인드해야 한다(runFrameBufferLayer 의 fullFrame 분리) — 위 테스트와 동일
    /// 씬에 copybackground:false 만 추가. frag 가 alpha 를 1로 강제해(원문과 달리) 결과를 acc 위에 항상
    /// 불투명으로 덮어써 판독을 결정적으로 만든다(alpha 를 aux 그대로 두면 회귀해도 aux 가 투명이라
    /// draw 자체가 무-기여가 되어 밑에 깔린 배경 레이어 색과 우연히 같아 보이는 위양성 통과가 생긴다 —
    /// 최초 버전은 이 함정에 걸려 되돌린 소스로도 luma≈0.33 이 나와 회귀를 못 잡았다). 회귀 시(aux 가
    /// chain src 와 같은 투명 텍스처를 공유하면) RGB=0(검정, luma≈0)이 된다.
    func testFullFrameBufferAuxSlotBindsSceneSnapshotEvenWhenCopyBackgroundFalse() throws {
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
        uniform sampler2D g_Texture0; // {"hidden":true}
        uniform sampler2D g_Texture1; // {"hidden":true,"default":"_rt_FullFrameBuffer"}
        void main() {
            vec3 c = texSample2D(g_Texture1, v_TexCoord).rgb;
            gl_FragColor = vec4(c, 1.0);
        }
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/bg.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/util/fullscreenlayer.json","origin":"960 540 0","size":"1920 1080",
            "copybackground":false,
            "effects":[{"file":"effects/copybg/effect.json","passes":[{}]}]}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_tr_copybg_nocopy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/bg.json", #"{"material":"materials/bg.json"}"#.data(using: .utf8)!),
            ("materials/bg.json", #"{"passes":[{"textures":["bg"]}]}"#.data(using: .utf8)!),
            ("materials/bg.tex", solidTex(255, 0, 0)),
            ("models/util/fullscreenlayer.json", #"{"material":"materials/util/fullscreenlayer.json","fullscreen":true}"#.data(using: .utf8)!),
            ("materials/util/fullscreenlayer.json", #"{"passes":[{"shader":"passthrough","textures":["_rt_FullFrameBuffer"]}]}"#.data(using: .utf8)!),
            ("shaders/effects/copybg.vert", vert.data(using: .utf8)!),
            ("shaders/effects/copybg.frag", frag.data(using: .utf8)!),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "copybg_nocopy", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "copybg_nocopy", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_tr_copybg_nocopy")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
        let luma = avgLuma(url)
        NSLog("%@", "[Waple] COPYBG fullframe-snapshot(copybackground:false) luma=\(luma)")
        XCTAssertGreaterThan(luma, 0.2, "copybackground:false 라도 _rt_FullFrameBuffer aux 슬롯은 실제 씬 컬러(빨강, alpha 강제 1 이라 luma≈0.33)를 받아야 함 — chain src(투명)와 공유되면 검정(luma≈0)이 되어 이 하한을 못 넘는다")
        XCTAssertLessThan(luma, 0.6, "흰색 1×1 폴백(aux 자체가 미바인드, luma≈1.0)도 아니어야 함")
    }

    /// X-⑤: g_TexelSize 를 이펙트 **출력(dst)** 해상도 기준으로 채택한 규약을 코드가 실제로 그렇게
    /// 구현했는지 고정(pin)하는 회귀 테스트다 — 채택 근거(WE gaussian.vert `ratio = g_TexelSize *
    /// g_Texture0Resolution`)는 정적으로는 판별력이 없어 "실측으로 확정"된 사실이 아니라 **라이브
    /// A/B 재검증 대기 중인 채택안**임을 GLSLTranslator.swift 의 g_TexelSize 치환부 주석에 남겼다.
    /// scale:4 다운샘플 fbo 를 거친 뒤 최종(타깃 없음=dst) 패스가 g_TexelSize.x 를 직접 색으로
    /// 인코딩 — 이 규약(dst 기준, 레이어 텍스처 8×8)이면 0.125, 구 tex0(다운샘플 fbo 2×2) 근사면
    /// 4× 과대(0.5)가 나온다.
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
        // 레이어 베이스 텍스처(w.tex, solidTex 기본 8×8) = 효과 dst 크기. 채택 규약(dst 기준, 1/8=0.125)
        // 을 코드가 지키는지 고정 — 다운샘플 소스(scale4→2×2, 1/2=0.5) 근사로 되돌아가면 4× 과대돼
        // 이 어서션이 실패한다(규약 자체의 최종 확정은 라이브 A/B, BACKLOG.md 시각 충실도 표 참조).
        XCTAssertEqual(Double(c.redComponent), 0.125, accuracy: 0.05,
                      "g_TexelSize 는 다운스케일 소스(1/2)가 아니라 채택된 이펙트 dst(1/8) 규약을 따라야 함 — 4× 과대면 회귀")
    }

    /// X-⑥: 이펙트 `visible` 스크립트가 per-frame 재평가돼야 한다. value:false 로 시작해도 script 가
    /// true 를 반환하면 켜지고(구: 파스 단계 initialVisible==false 로 SceneEffect 자체는 보존되지만
    /// buildEffectChain 이 무조건 드롭 — 영구 미적용), value:false+script:false 는 계속 꺼진 채(감사가
    /// 지목한 실 코퍼스 17씬 이벤트-훅 회귀 방지 — 스크립트가 실제로 true 를 반환할 때만 켜져야 한다).
    func testEffectVisibleScriptTogglesPerFrame() throws {
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
            vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
            albedo.rgb *= 0.4;
            gl_FragColor = albedo;
        }
        """
        func luma(visible: String, tag: String) throws -> Double {
            let scene = """
            {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
             "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
               "effects":[{"file":"effects/vistoggle/effect.json","visible":\(visible),"passes":[{}]}]}]}
            """
            return try renderLuma(scene: scene, extraFiles: [
                ("shaders/effects/vistoggle.vert", vert.data(using: .utf8)!),
                ("shaders/effects/vistoggle.frag", frag.data(using: .utf8)!),
            ], tag: "vis_\(tag)")
        }
        let onLuma = try luma(visible: #"{"value":false,"script":"function init(){ return true; }"}"#, tag: "on")
        let offLuma = try luma(visible: #"{"value":false,"script":"function init(){ return false; }"}"#, tag: "off")
        NSLog("%@", "[Waple] visible-script on=\(onLuma) off=\(offLuma)")
        XCTAssertEqual(onLuma, 0.4, accuracy: 0.1, "script 가 true 를 반환하면 이펙트가 켜져야(dim 40%)")
        XCTAssertGreaterThan(offLuma, 0.7, "script 가 false 를 반환하면 계속 꺼진 채(17씬 이벤트훅 회귀 방지)")

        // hasUpdate(동적) 경로 — 위 두 케이스는 init-only(정적 해석, buildEffectChain 이 빌드 시점에
        // 게이트 없이 확정)만 실증한다. update 함수가 있는 스크립트는 EffectVisibleGate 로 렌더 체인에
        // 남아 SceneRendererFrameEncoder.effectVisible(_:time:) 이 매 프레임 실제로 재평가해야 반영된다
        // — 이 두 단정이 실패하면 effectVisible 헬퍼/5개 적용지점의 guard 가 죽은 코드라는 뜻.
        let dynamicOnLuma = try luma(visible: #"{"value":false,"script":"export function update(v){ return true; }"}"#, tag: "dyn_on")
        let dynamicOffLuma = try luma(visible: #"{"value":true,"script":"export function update(v){ return false; }"}"#, tag: "dyn_off")
        NSLog("%@", "[Waple] visible-script dynamic on=\(dynamicOnLuma) off=\(dynamicOffLuma)")
        XCTAssertEqual(dynamicOnLuma, 0.4, accuracy: 0.1,
                      "게이트 initial=false 라도 update 가 true 를 반환하면 켜져야(게이트가 실제로 실행됨을 증명)")
        XCTAssertGreaterThan(dynamicOffLuma, 0.7,
                             "게이트 initial=true 라도 update 가 false 를 반환하면 꺼져야(continue 스킵 경로 실증)")
    }

    /// B2-effects③: waterwaves 완전 no-op 의혹(2947302287) 회귀 가드 — 직전 라운드가 SKIP 과 픽셀 동일을
    /// 실증했으나, 재조사 결과 현재 main(y-up 전환 이후) 에서는 이미 정상 변위가 관측됨(원인 미확정 —
    /// 과거 라운드 대비 좌표계/버텍스 경로 변화로 추정, 재추적은 보류). 실물 waterwaves.frag/vert(WE
    /// shaders/effects/waterwaves) 를 #include 없이 직접 임베드(rotateVec2 인라인, MASK/TIMEOFFSET/
    /// PERSPECTIVE/DUALWAVES 콤보 전부 기본 0) — direction=0(기본) → v_Direction=(0,1) → offset=(1,0)
    /// (가로 변위), scale=0 으로 공간항 제거해 distance=time*speed 만 남긴다. 가로 그라디언트 배경에서
    /// 화면 중앙 픽셀을 두 시각(t=0.1/0.35, sin(distance) 부호가 반대)에 샘플 — 변위가 0 이면(no-op
    /// 회귀) 두 시각 모두 그라디언트 중앙색(동일)이 나오고, 정상이면 서로 다른 색이 나온다.
    func testWaterwavesProducesTimeVaryingDisplacementNotNoOp() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec4 v_TexCoord;
        varying vec2 v_Direction;
        uniform float g_Direction;
        vec2 rotateVec2(vec2 v, float r) {
            vec2 cs = vec2(cos(r), sin(r));
            return vec2(v.x * cs.x - v.y * cs.y, v.x * cs.y + v.y * cs.x);
        }
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord.xyxy;
            v_Direction = rotateVec2(vec2(0, 1), g_Direction);
        }
        """
        let frag = """
        varying vec4 v_TexCoord;
        varying vec2 v_Direction;
        uniform sampler2D g_Texture0;
        uniform float g_Time;
        uniform float g_Speed;
        uniform float g_Scale;
        uniform float g_Exponent;
        uniform float g_Strength;
        void main() {
            float mask = 1.0;
            vec2 texCoord = v_TexCoord.xy;
            vec2 texCoordMotion = texCoord;
            float distance = g_Time * g_Speed + dot(texCoordMotion, v_Direction) * g_Scale;
            float strength = g_Strength * g_Strength;
            vec2 offset = vec2(v_Direction.y, -v_Direction.x);
            float val1 = sin(distance);
            float s1 = sign(val1);
            val1 = pow(abs(val1), g_Exponent);
            texCoord += val1 * s1 * offset * strength * mask;
            gl_FragColor = texSample2D(g_Texture0, texCoord);
        }
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/g.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/waterwaves/effect.json",
             "passes":[{"constantshadervalues":{"speed":10,"scale":0,"strength":0.5,"exponent":1}}]}]}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_tr_ww", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/g.json", #"{"material":"materials/g.json"}"#.data(using: .utf8)!),
            ("materials/g.json", #"{"passes":[{"textures":["g"]}]}"#.data(using: .utf8)!),
            ("materials/g.tex", horizontalGradientTex(left: (0, 0, 0), right: (255, 255, 255), w: 64, h: 8)),
            ("shaders/effects/waterwaves.vert", vert.data(using: .utf8)!),
            ("shaders/effects/waterwaves.frag", frag.data(using: .utf8)!),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "ww", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "ww", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let outDir = URL(fileURLWithPath: "/tmp/waple_tr_ww")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let urls = r.captureFrames(width: 64, height: 36, times: [0.1, 0.35], toDir: outDir)
        XCTAssertEqual(urls.count, 2)
        let rep0 = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: urls[0])))
        let rep1 = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: urls[1])))
        let c0 = try XCTUnwrap(rep0.colorAt(x: 32, y: 18))
        let c1 = try XCTUnwrap(rep1.colorAt(x: 32, y: 18))
        NSLog("%@", "[Waple] waterwaves t=0.1 red=\(c0.redComponent) t=0.35 red=\(c1.redComponent)")
        XCTAssertGreaterThan(abs(c0.redComponent - c1.redComponent), 0.15,
                             "waterwaves 가 no-op 이면(회귀) 두 시각 모두 그라디언트 중앙색으로 동일 — 변위가 살아있어야 시각별로 달라진다")
    }

    /// B2-effects③ 지적 보강: 위 가드는 MASK/TIMEOFFSET 콤보를 전부 0(미바인드)으로 둔 채 변위 유무만
    /// 봐서, 감사가 실제로 지적한 결함("waterwaves TIMEOFFSET 마스크 오바인드" — dig-effects-b.md §3,
    /// 실물 waterwaves.frag:11-13 `g_Texture1`=`combo:"MASK"`, `g_Texture2`=`combo:"TIMEOFFSET"` 샘플러
    /// 어노테이션)이 다시 깨져도 잡지 못한다. 이 테스트는 실물 waterwaves.frag/vert(#include 만 제거, MASK
    /// 분기는 원문 그대로)를 그대로 번역해 MASK 텍스처가 실제로 읽혀 displacement 를 게이팅하는지 단언한다
    /// — mask=1(흰 텍스처)은 기존 무마스크 가드와 동일하게 시간에 따라 변위해야 하고, mask=0(검정 텍스처)은
    /// 완전히 정지해야 한다(둘 다 같은 값이면 g_Texture1 이 콘텐츠와 무관하게 상수로 오바인드된 것).
    func testWaterwavesMaskComboGatesDisplacement() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        // [COMBO] {"material":"ui_editor_properties_perspective","combo":"PERSPECTIVE","type":"options","default":0}
        // [COMBO] {"material":"ui_editor_properties_dual_waves","combo":"DUALWAVES","type":"options","default":0}

        vec2 rotateVec2(vec2 v, float r) {
            vec2 cs = vec2(cos(r), sin(r));
            return vec2(v.x * cs.x - v.y * cs.y, v.x * cs.y + v.y * cs.x);
        }

        uniform mat4 g_ModelViewProjectionMatrix;
        uniform vec4 g_Texture1Resolution;
        uniform vec4 g_Texture2Resolution;
        uniform float g_Direction;

        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;

        varying vec4 v_TexCoord;
        varying vec2 v_Direction;

        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord.xyxy;
        #if MASK
            v_TexCoord.z *= g_Texture1Resolution.z / g_Texture1Resolution.x;
            v_TexCoord.w *= g_Texture1Resolution.w / g_Texture1Resolution.y;
        #else
        #if TIMEOFFSET
            v_TexCoord.z *= g_Texture2Resolution.z / g_Texture2Resolution.x;
            v_TexCoord.w *= g_Texture2Resolution.w / g_Texture2Resolution.y;
        #endif
        #endif
            v_Direction = rotateVec2(vec2(0, 1), g_Direction);
        }
        """
        let frag = """
        varying vec4 v_TexCoord;
        varying vec2 v_Direction;
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1; // {"combo":"MASK"}
        uniform sampler2D g_Texture2; // {"combo":"TIMEOFFSET"}
        uniform float g_Time;
        uniform float g_Speed;
        uniform float g_Scale;
        uniform float g_Exponent;
        uniform float g_Strength;
        #define M_PI_2 6.28318530718
        void main() {
        #if MASK
            float mask = texSample2D(g_Texture1, v_TexCoord.zw).r;
        #else
            float mask = 1.0;
        #endif
            vec2 texCoord = v_TexCoord.xy;
            vec2 texCoordMotion = texCoord;
            float distance = g_Time * g_Speed + dot(texCoordMotion, v_Direction) * g_Scale;
        #if TIMEOFFSET
            float timeOffset = texSample2D(g_Texture2, v_TexCoord.zw).r * M_PI_2;
            distance += timeOffset;
        #endif
            float strength = g_Strength * g_Strength;
            vec2 offset = vec2(v_Direction.y, -v_Direction.x);
            float val1 = sin(distance);
            float s1 = sign(val1);
            val1 = pow(abs(val1), g_Exponent);
            texCoord += val1 * s1 * offset * strength * mask;
            gl_FragColor = texSample2D(g_Texture0, texCoord);
        }
        """
        func sample(maskTexName: String, at times: [Float]) throws -> [NSColor] {
            let scene = """
            {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
             "objects":[{"id":1,"image":"models/g.json","origin":"960 540 0","size":"1920 1080",
               "effects":[{"file":"effects/waterwaves/effect.json",
                 "passes":[{"constantshadervalues":{"speed":10,"scale":0,"strength":0.5,"exponent":1},
                            "textures":[null,"\(maskTexName)"]}]}]}]}
            """
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("waple_tr_ww_mask_\(maskTexName)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try encodePkg([
                ("scene.json", scene.data(using: .utf8)!),
                ("models/g.json", #"{"material":"materials/g.json"}"#.data(using: .utf8)!),
                ("materials/g.json", #"{"passes":[{"textures":["g"]}]}"#.data(using: .utf8)!),
                ("materials/g.tex", horizontalGradientTex(left: (0, 0, 0), right: (255, 255, 255), w: 64, h: 8)),
                ("shaders/effects/waterwaves.vert", vert.data(using: .utf8)!),
                ("shaders/effects/waterwaves.frag", frag.data(using: .utf8)!),
                ("materials/\(maskTexName).tex", maskTexName == "wwmaskwhite" ? solidTex(255, 255, 255) : solidTex(0, 0, 0)),
            ]).write(to: dir.appendingPathComponent("scene.pkg"))
            let project = WallpaperProject(id: "ww_\(maskTexName)", type: .scene, fileName: "scene.pkg", previewName: nil,
                                           title: "ww", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
            let r = SceneRenderer()
            try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
            defer { r.teardown() }
            let outDir = URL(fileURLWithPath: "/tmp/waple_tr_ww_mask_\(maskTexName)")
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let urls = r.captureFrames(width: 64, height: 36, times: times, toDir: outDir)
            XCTAssertEqual(urls.count, times.count)
            return try urls.map {
                let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: $0)))
                return try XCTUnwrap(rep.colorAt(x: 32, y: 18))
            }
        }
        let white = try sample(maskTexName: "wwmaskwhite", at: [0.1, 0.35])
        let black = try sample(maskTexName: "wwmaskblack", at: [0.1, 0.35])
        NSLog("%@", "[Waple] waterwaves MASK white t=0.1/0.35 red=\(white[0].redComponent)/\(white[1].redComponent) " +
                     "black t=0.1/0.35 red=\(black[0].redComponent)/\(black[1].redComponent)")
        XCTAssertGreaterThan(abs(white[0].redComponent - white[1].redComponent), 0.15,
                             "mask=1(흰 텍스처)은 무마스크와 동형으로 시간에 따라 변위해야 함 — 동일하면 g_Texture1 미반영")
        XCTAssertLessThan(abs(black[0].redComponent - black[1].redComponent), 0.02,
                          "mask=0(검정 텍스처)은 변위가 완전히 0이어야 함 — 값이 남으면 MASK 콤보가 켜졌는데도 g_Texture1 내용이 무시된 것(오바인드)")
    }

    /// B2-effects③ 지적 보강(TIMEOFFSET 짝): 실물 waterwaves.frag `g_Texture2`(combo:"TIMEOFFSET")가 실제로
    /// 위상 오프셋을 더하는지 단언 — 동일 시각에서 오프셋 텍스처 유무만 다른 두 렌더를 비교, 오프셋이
    /// 절반 주기(≈π)를 더하면 sin(distance) 부호가 뒤집혀 변위 방향이 반대가 되고 색이 크게 갈린다.
    /// 오프셋 텍스처가 오바인드(미반영/엉뚱한 슬롯)되면 두 렌더가 같은 색을 낸다.
    func testWaterwavesTimeOffsetComboShiftsPhase() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        vec2 rotateVec2(vec2 v, float r) {
            vec2 cs = vec2(cos(r), sin(r));
            return vec2(v.x * cs.x - v.y * cs.y, v.x * cs.y + v.y * cs.x);
        }
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform float g_Direction;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec4 v_TexCoord;
        varying vec2 v_Direction;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord.xyxy;
            v_Direction = rotateVec2(vec2(0, 1), g_Direction);
        }
        """
        let frag = """
        varying vec4 v_TexCoord;
        varying vec2 v_Direction;
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture2; // {"combo":"TIMEOFFSET"}
        uniform float g_Time;
        uniform float g_Speed;
        uniform float g_Scale;
        uniform float g_Exponent;
        uniform float g_Strength;
        #define M_PI_2 6.28318530718
        void main() {
            float mask = 1.0;
            vec2 texCoord = v_TexCoord.xy;
            vec2 texCoordMotion = texCoord;
            float distance = g_Time * g_Speed + dot(texCoordMotion, v_Direction) * g_Scale;
        #if TIMEOFFSET
            float timeOffset = texSample2D(g_Texture2, v_TexCoord.zw).r * M_PI_2;
            distance += timeOffset;
        #endif
            float strength = g_Strength * g_Strength;
            vec2 offset = vec2(v_Direction.y, -v_Direction.x);
            float val1 = sin(distance);
            float s1 = sign(val1);
            val1 = pow(abs(val1), g_Exponent);
            texCoord += val1 * s1 * offset * strength * mask;
            gl_FragColor = texSample2D(g_Texture0, texCoord);
        }
        """
        func sample(textures: String) throws -> NSColor {
            let scene = """
            {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
             "objects":[{"id":1,"image":"models/g.json","origin":"960 540 0","size":"1920 1080",
               "effects":[{"file":"effects/waterwaves/effect.json",
                 "passes":[{"constantshadervalues":{"speed":10,"scale":0,"strength":0.5,"exponent":1}\(textures)}]}]}]}
            """
            let tag = textures.isEmpty ? "off" : "on"
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_tr_ww_toff_\(tag)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try encodePkg([
                ("scene.json", scene.data(using: .utf8)!),
                ("models/g.json", #"{"material":"materials/g.json"}"#.data(using: .utf8)!),
                ("materials/g.json", #"{"passes":[{"textures":["g"]}]}"#.data(using: .utf8)!),
                ("materials/g.tex", horizontalGradientTex(left: (0, 0, 0), right: (255, 255, 255), w: 64, h: 8)),
                ("shaders/effects/waterwaves.vert", vert.data(using: .utf8)!),
                ("shaders/effects/waterwaves.frag", frag.data(using: .utf8)!),
                ("materials/wwoffset.tex", solidTex(128, 128, 128)),
            ]).write(to: dir.appendingPathComponent("scene.pkg"))
            let project = WallpaperProject(id: "ww_toff_\(tag)", type: .scene, fileName: "scene.pkg", previewName: nil,
                                           title: "ww", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
            let r = SceneRenderer()
            try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
            defer { r.teardown() }
            let outDir = URL(fileURLWithPath: "/tmp/waple_tr_ww_toff_\(tag)")
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let urls = r.captureFrames(width: 64, height: 36, times: [0.2], toDir: outDir)
            XCTAssertEqual(urls.count, 1)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: urls[0])))
            return try XCTUnwrap(rep.colorAt(x: 32, y: 18))
        }
        let noOffset = try sample(textures: "")
        let withOffset = try sample(textures: #","textures":[null,null,"wwoffset"]"#)
        NSLog("%@", "[Waple] waterwaves TIMEOFFSET off red=\(noOffset.redComponent) on red=\(withOffset.redComponent)")
        XCTAssertGreaterThan(abs(noOffset.redComponent - withOffset.redComponent), 0.15,
                             "TIMEOFFSET 텍스처(회색=반주기 오프셋)가 반영되면 변위 부호가 뒤집혀 색이 크게 갈라져야 함 — 같으면 g_Texture2 오바인드")
    }
}
