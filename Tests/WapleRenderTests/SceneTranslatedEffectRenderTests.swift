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

    /// 디코드 가능한 .tex = TEXV0005 헤더(패딩) + 솔리드 PNG.
    private func solidTex(_ r: UInt8, _ g: UInt8, _ b: UInt8, w: Int = 8, h: Int = 8) -> Data {
        var px = [UInt8](); px.reserveCapacity(w * h * 4)
        for _ in 0..<(w * h) { px.append(contentsOf: [r, g, b, 255]) }
        let png = OffscreenCapture.png(rgba: px, width: w, height: h)!
        var tex = Data("TEXV0005".utf8)
        tex.append(Data(repeating: 0, count: 34))
        tex.append(png)
        return tex
    }

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
}
