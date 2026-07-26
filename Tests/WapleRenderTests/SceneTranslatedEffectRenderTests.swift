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

    /// X-①: effect.json fbos[].fit(실물 cursorripple `_rt_EightBuffer1/2` fit:512) 는 dst 비례(scale)가
    /// 아니라 절대 정사각 크기여야 한다. dst 는 64×36(테스트 캡처 해상도)인데 fbo fit:32 이면 그 fbo 는
    /// 항상 32×32 — scale 기반으로 잘못 낙하하면(과거: fit 무시 → scale 기본값 1 → dst 크기) 프로브가 실패.
    func testMultiPassEffectFBOFitIsAbsoluteSize() throws {
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
            float ok = step(31.5, g_Texture0Resolution.x) * step(g_Texture0Resolution.x, 32.5)
                     * step(31.5, g_Texture0Resolution.y) * step(g_Texture0Resolution.y, 32.5);
            gl_FragColor = vec4(ok, ok, ok, 1.0);
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
            ("materials/w.tex", solidTex(255, 255, 255)),
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
        let luma = avgLuma(url)
        NSLog("%@", "[Waple] fbo fit:32 resolution-probe luma=\(luma)")
        XCTAssertGreaterThan(luma, 0.9, "fit:32 는 dst(64x36)와 무관하게 절대 32x32 여야 함(스케일 폴백이면 g_Texture0Resolution 불일치 → 검정)")
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
         "fbos":[{"name":"_rt_A","scale":1},{"name":"_rt_B","scale":1}]}
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
}
