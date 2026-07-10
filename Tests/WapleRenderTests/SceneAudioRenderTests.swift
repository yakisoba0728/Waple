import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

final class SceneAudioRenderTests: XCTestCase {
    private func avgLuma(_ url: URL) -> Double {
        guard let rep = NSBitmapImageRep(data: try! Data(contentsOf: url)) else { return -1 }
        var sum = 0.0; var n = 0
        let stepX = max(1, rep.pixelsWide / 40), stepY = max(1, rep.pixelsHigh / 40)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                if let c = rep.colorAt(x: x, y: y) {
                    sum += (c.redComponent + c.greenComponent + c.blueComponent) / 3.0; n += 1
                }
            }
        }
        return n > 0 ? sum / Double(n) : -1
    }

    /// opacity 효과(premultiplied 수정 검증): alpha 0.4 → 풀 대비 ~40% 밝기.
    func testOpacityFades() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func render(_ alpha: Double, _ name: String) throws -> Double {
            let scene = """
            {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
             "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
               "effects":[{"file":"effects/opacity/effect.json","passes":[{"constantshadervalues":{"alpha":\(alpha)}}]}]}]}
            """
            let pkg = encodePkg([
                ("scene.json", scene.data(using: .utf8)!),
                ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
                ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
                ("materials/w.tex", solidTex(255, 255, 255)),
            ])
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_op_\(name)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try pkg.write(to: dir.appendingPathComponent("scene.pkg"))
            let project = WallpaperProject(id: name, type: .scene, fileName: "scene.pkg", previewName: nil,
                                           title: name, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
            let r = SceneRenderer()
            try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
            defer { r.teardown() }
            let outDir = URL(fileURLWithPath: "/tmp/waple_op_\(name)")
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let urls = r.captureFrames(width: 64, height: 36, times: [0.1], toDir: outDir)
            return avgLuma(try XCTUnwrap(urls.first))
        }
        let full = try render(1.0, "full")
        let dim = try render(0.4, "dim")
        NSLog("%@", "[Waple] opacity luma full=\(full) dim=\(dim)")
        XCTAssertGreaterThan(full, 0.8, "alpha 1 → near white")
        XCTAssertEqual(dim, full * 0.4, accuracy: 0.1, "alpha 0.4 → ~40% over black")
    }

    /// 2단계 효과 체인(opacity×2)이 풀에서 distinct 텍스처를 받아 올바르게 합성되는지(src/dst aliasing 없음).
    /// 흰색 × 0.7 × 0.7 = 0.49. 같은 텍스처를 src=dst 로 재사용하면 결과가 깨진다.
    func testMultiEffectChainCorrectViaPool() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[
             {"file":"effects/opacity/effect.json","passes":[{"constantshadervalues":{"alpha":0.7}}]},
             {"file":"effects/opacity/effect.json","passes":[{"constantshadervalues":{"alpha":0.7}}]}
           ]}]}
        """
        let pkg = encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_pool_chain", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pkg.write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "pool", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "pool", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let outDir = URL(fileURLWithPath: "/tmp/waple_pool_chain"); try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // 두 번 캡처(풀 프레임 간 재사용) — 둘 다 동일·올바른 결과여야(재사용이 stale 을 남기지 않음).
        let a = avgLuma(try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: outDir).first))
        let b = avgLuma(try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.2], toDir: outDir).first))
        NSLog("%@", "[Waple] pool chain luma a=\(a) b=\(b)")
        // chain 통과(두 번 디밍) → 0.7×0.7 = 0.49 (straight 규약, 설계 §3 — 이중 premult 아님). 손상 없음.
        XCTAssertEqual(a, 0.49, accuracy: 0.05)
        XCTAssertEqual(a, b, accuracy: 0.01, "pool reuse across frames must reproduce same result")
    }

    func testPulseAlphaRespondsToSpectrum() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // 풀스크린 빨강 레이어 + pulse(PULSEALPHA, AUDIOPROCESSING=3). 무음→alpha0(어두운 배경), 최대→alpha1(빨강).
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/red.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/pulse/effect.json","passes":[{
              "combos":{"AUDIOPROCESSING":3,"PULSEALPHA":1,"PULSECOLOR":0},
              "constantshadervalues":{"audiobounds":"0 1","audioamount":1}}]}]}]}
        """
        let pkg = encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/red.json", #"{"material":"materials/red.json"}"#.data(using: .utf8)!),
            ("materials/red.json", #"{"passes":[{"textures":["red"]}]}"#.data(using: .utf8)!),
            ("materials/red.tex", solidTex(220, 30, 30)),
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_sp5_ctrl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pkg.write(to: dir.appendingPathComponent("scene.pkg"))

        let project = WallpaperProject(id: "ctrl", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "ctrl", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let r = SceneRenderer()
        try r.mount(in: container, project: project)
        defer { r.teardown() }

        let out = URL(fileURLWithPath: "/tmp/waple_sp5_ctrl")
        let loDir = out.appendingPathComponent("silent", isDirectory: true)
        let hiDir = out.appendingPathComponent("full", isDirectory: true)
        try? FileManager.default.createDirectory(at: loDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: hiDir, withIntermediateDirectories: true)

        r.setSpectrum(.silent)
        let lo = r.captureFrames(width: 320, height: 180, times: [1.0], toDir: loDir)
        r.setSpectrum(AudioSpectrum16(left: [Float](repeating: 1, count: 16), right: [Float](repeating: 1, count: 16)))
        let hi = r.captureFrames(width: 320, height: 180, times: [1.0], toDir: hiDir)

        let loURL = try XCTUnwrap(lo.first), hiURL = try XCTUnwrap(hi.first)
        let loLuma = avgLuma(loURL), hiLuma = avgLuma(hiURL)
        NSLog("%@", "[Waple] SP5 ctrl luma silent=\(loLuma) full=\(hiLuma) | \(loURL.path) \(hiURL.path)")
        // 무음: alpha 0 → 거의 검정(낮은 luma). 최대: 빨강 보임(높은 luma).
        XCTAssertLessThan(loLuma, 0.1, "silent should be dark")
        XCTAssertGreaterThan(hiLuma, loLuma + 0.15, "full spectrum should brighten via pulse alpha")
    }

    /// 변환 경로 vertex 오디오 end-to-end: 비-스톡 효과의 .vert 가 오디오 배열을 읽어 varying 으로 전달,
    /// frag 가 곱한다(실제 WE pulse.vert 의 CreateAudioResponse 패턴). 렌더러가 vertex 스테이지에
    /// buffer(2/3) 을 바인드하지 않으면 무음/최대 차이가 나지 않는다.
    func testTranslatedVertexAudioEndToEnd() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        varying vec2 v_TexCoord;
        varying float v_Gain;
        float CreateAudioResponse() { return g_AudioSpectrum16Left[0]; }
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
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/vaud/effect.json","passes":[{}]}]}]}
        """
        let pkg = encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("shaders/effects/vaud.vert", vert.data(using: .utf8)!),
            ("shaders/effects/vaud.frag", frag.data(using: .utf8)!),
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_vaud", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pkg.write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "vaud", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "vaud", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_vaud")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        r.setSpectrum(.silent)
        let lo = avgLuma(try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first))
        r.setSpectrum(AudioSpectrum16(left: [Float](repeating: 1, count: 16), right: [Float](repeating: 1, count: 16)))
        let hi = avgLuma(try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.2], toDir: out).first))
        NSLog("%@", "[Waple] vertex-audio luma silent=\(lo) full=\(hi)")
        XCTAssertLessThan(lo, 0.1, "silent → gain 0 → black (변환 경로가 스킵되면 1.0)")
        XCTAssertGreaterThan(hi, 0.8, "full spectrum → gain 1 → white")
    }

    /// 64빈 스펙트럼(오디오 바 시각화) end-to-end: frag 가 g_AudioSpectrum64Left 로 밝기 결정.
    func testHiResSpectrumEndToEnd() throws {
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
            c.rgb *= g_AudioSpectrum64Left[10] * g_AudioSpectrum32Right[5];
            gl_FragColor = c;
        }
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/bars/effect.json","passes":[{}]}]}]}
        """
        let pkg = encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("shaders/effects/bars.vert", vert.data(using: .utf8)!),
            ("shaders/effects/bars.frag", frag.data(using: .utf8)!),
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_hires", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pkg.write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "hires", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "hires", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_hires")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let lo = avgLuma(try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first))
        r.setSpectrum64(left: [Float](repeating: 1, count: 64), right: [Float](repeating: 1, count: 64))
        let hi = avgLuma(try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.2], toDir: out).first))
        NSLog("%@", "[Waple] hi-res spectrum luma silent=\(lo) full=\(hi)")
        XCTAssertLessThan(lo, 0.1, "무음 → 검정 (미지원이면 스킵 → 1.0)")
        XCTAssertGreaterThan(hi, 0.8, "풀 스펙트럼 → 흰색")
    }
}
