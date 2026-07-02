import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// Premultiply 규약(설계 §3): 이펙트 패스는 straight-in/straight-out, premultiply 는 최종 컴포지트에서 단 한 번.
/// - 반투명 텍스처 레이어(무-이펙트)가 올바르게 합성되는지 (기존엔 straight 출력 + src=one 이라 과다 밝음)
/// - 알파 감소 효과 체인이 이중 premult 없이 곱해지는지 (0.7×0.7 → 0.49; 기존 버그 0.343)
final class SceneCompositeConventionTests: XCTestCase {
    private func i32(_ n: Int) -> Data { var v = UInt32(n).littleEndian; return Data(bytes: &v, count: 4) }

    private func encodePkg(_ files: [(String, Data)]) -> Data {
        var out = Data()
        let version = "PKGV0001"
        out.append(i32(version.utf8.count)); out.append(version.data(using: .utf8)!)
        out.append(i32(files.count))
        var offset = 0
        for (name, data) in files {
            out.append(i32(name.utf8.count)); out.append(name.data(using: .utf8)!)
            out.append(i32(offset)); out.append(i32(data.count)); offset += data.count
        }
        for (_, data) in files { out.append(data) }
        return out
    }

    private func solidTex(_ r: UInt8, _ g: UInt8, _ b: UInt8, alpha: UInt8 = 255, w: Int = 8, h: Int = 8) -> Data {
        var px = [UInt8](); px.reserveCapacity(w * h * 4)
        for _ in 0..<(w * h) { px.append(contentsOf: [r, g, b, alpha]) }
        let png = OffscreenCapture.png(rgba: px, width: w, height: h)!
        var tex = Data("TEXV0005".utf8)
        tex.append(Data(repeating: 0, count: 34))
        tex.append(png)
        return tex
    }

    private func avgLuma(_ url: URL) -> Double {
        guard let rep = NSBitmapImageRep(data: try! Data(contentsOf: url)) else { return -1 }
        var sum = 0.0; var n = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 40)) {
            for x in stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 40)) {
                if let c = rep.colorAt(x: x, y: y) {
                    sum += (c.redComponent + c.greenComponent + c.blueComponent) / 3.0; n += 1
                }
            }
        }
        return n > 0 ? sum / Double(n) : -1
    }

    private func renderLuma(scene: String, texAlpha: UInt8 = 255, extraFiles: [(String, Data)] = [], tag: String) throws -> Double {
        var files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255, alpha: texAlpha)),
        ]
        files.append(contentsOf: extraFiles)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_cc_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let outDir = URL(fileURLWithPath: "/tmp/waple_cc_\(tag)")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let urls = r.captureFrames(width: 64, height: 36, times: [0.1], toDir: outDir)
        return avgLuma(try XCTUnwrap(urls.first))
    }

    private let plainScene = """
    {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
     "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"}]}
    """

    /// 알파 0.5 흰색 레이어(무-이펙트) over 검정 → luma ≈ 0.5. (straight 출력 + src=one 이면 1.0 이 됨.)
    func testSemiTransparentLayerCompositesCorrectly() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let luma = try renderLuma(scene: plainScene, texAlpha: 128, tag: "semitransparent")
        NSLog("%@", "[Waple] semi-transparent layer luma=\(luma)")
        XCTAssertEqual(luma, 0.5, accuracy: 0.06, "a=0.5 white over black must composite to ~0.5")
    }

    /// 손-포팅 opacity 0.7 두 번 체인 → 0.49 (이중 premult 버그면 0.343).
    func testChainedOpacityHandPortNoDoublePremult() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/opacity/effect.json","passes":[{"constantshadervalues":{"alpha":0.7}}]},
                      {"file":"effects/opacity/effect.json","passes":[{"constantshadervalues":{"alpha":0.7}}]}]}]}
        """
        let luma = try renderLuma(scene: scene, tag: "chainhand")
        NSLog("%@", "[Waple] chained hand-port opacity luma=\(luma)")
        XCTAssertEqual(luma, 0.49, accuracy: 0.05, "0.7 × 0.7 = 0.49, not double-premult 0.343")
    }

    /// 변환 경로(비-스톡 이름) 0.7 두 번 체인 → 0.49.
    func testChainedOpacityTranslatedNoDoublePremult() throws {
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
           "effects":[{"file":"effects/dim70a/effect.json","passes":[{"constantshadervalues":{"alpha":0.7}}]},
                      {"file":"effects/dim70b/effect.json","passes":[{"constantshadervalues":{"alpha":0.7}}]}]}]}
        """
        let luma = try renderLuma(scene: scene, extraFiles: [
            ("shaders/effects/dim70a.vert", vert.data(using: .utf8)!),
            ("shaders/effects/dim70a.frag", frag.data(using: .utf8)!),
            ("shaders/effects/dim70b.vert", vert.data(using: .utf8)!),
            ("shaders/effects/dim70b.frag", frag.data(using: .utf8)!),
        ], tag: "chaintrans")
        NSLog("%@", "[Waple] chained translated opacity luma=\(luma)")
        XCTAssertEqual(luma, 0.49, accuracy: 0.05, "translated chain 0.7 × 0.7 = 0.49")
    }
}
