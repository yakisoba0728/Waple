import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

/// H1 검증: 커스텀 머티리얼 셰이더가 실제로 렌더에 적용되는지(픽셀 출력으로 확인).
final class SceneCustomShaderRenderTests: XCTestCase {
    private func project(files: [(String, Data)], id: String) throws -> WallpaperProject {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h1v_\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        try Data(#"{"type":"scene","title":"h1v","file":"scene.pkg"}"#.utf8).write(to: dir.appendingPathComponent("project.json"))
        return try XCTUnwrap(try? ProjectJSONParser.parse(folderURL: dir))
    }

    /// 커스텀 셰이더(빨간 반전)가 적용되면 출력이 빨간색이 아닌 반전색이어야 한다.
    /// 폴터(QuadShaders)면 원본 빨간 텍스처가 그대로 나온다.
    func testCustomShaderAppliesToRender() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"32 32","size":"64 64","scale":"1 1",
                     "angles":"0 0 0","alpha":1.0,"color":"1 1 1","brightness":1.0,"visible":true}]}
        """
        let model = #"{"width":64,"height":64,"material":"materials/m.json"}"#
        let material = #"{"passes":[{"shader":"invert","textures":["pic"]}]}"#
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            gl_FragColor = vec4(1.0 - c.r, 1.0 - c.g, 1.0 - c.b, c.a);
        }
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/x.json", model.data(using: .utf8)!),
            ("materials/m.json", material.data(using: .utf8)!),
            ("materials/pic.tex", solidTex(255, 0, 0)),  // 빨간 텍스처
            ("shaders/invert.vert", vert.data(using: .utf8)!),
            ("shaders/invert.frag", frag.data(using: .utf8)!),
        ]
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)),
                    project: try project(files: files, id: "invert"))
        defer { r.teardown() }
        // 커스텀 셰이더가 빌드됐는지 확인.
        XCTAssertNotNil(r.layers[0].customShader)
        // 캡처로 실제 픽셀 확인.
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h1v_out", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let urls = r.captureFrames(width: 64, height: 64, times: [0.1], toDir: outDir)
        guard let url = urls.first,
              let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("capture failed"); return
        }
        var px = [UInt8](repeating: 0, count: 64 * 64 * 4)
        guard let ctx = CGContext(data: &px, width: 64, height: 64, bitsPerComponent: 8,
                                  bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            XCTFail("context failed"); return
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        // 중앙 픽셀 확인 — 반전 셰이더면 빨강(255,0,0)이 아닌 시안(0,255,255)에 가까워야 한다.
        let center = (32 * 64 + 32) * 4
        let rVal = px[center], gVal = px[center + 1], bVal = px[center + 2]
        // 반전이면 r < 50, g > 200, b > 200. 폴터면 r > 200, g < 50, b < 50.
        XCTAssertTrue(rVal < 100 && gVal > 150 && bVal > 150,
                      "custom invert shader not applied (r=\(rVal), g=\(gVal), b=\(bVal))")
    }

    /// 회전 레이어의 커스텀 셰이더 변환: 번역 셰이더는 mul(v, eng.mvp)=v·M 계약이라 M·v 규약의
    /// layerTransformMatrix 를 전치해 바인딩해야 한다(무전치면 Dᵀ 회전 — 90° 회전 64×16 쿼드가
    /// 세로 스트립 대신 가로 스트립으로 그려진다). 무회전 레이어는 D=Dᵀ 이라 기존 테스트에서 잠복.
    func testCustomShaderRotatedLayerTransform() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"32 32","size":"64 16","scale":"1 1",
                     "angles":"0 0 1.5707963","alpha":1.0,"color":"1 1 1","brightness":1.0,"visible":true}]}
        """
        let model = #"{"width":64,"height":16,"material":"materials/m.json"}"#
        let material = #"{"passes":[{"shader":"invert","textures":["pic"]}]}"#
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            vec4 c = texSample2D(g_Texture0, v_TexCoord);
            gl_FragColor = vec4(1.0 - c.r, 1.0 - c.g, 1.0 - c.b, c.a);
        }
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/x.json", model.data(using: .utf8)!),
            ("materials/m.json", material.data(using: .utf8)!),
            ("materials/pic.tex", solidTex(255, 0, 0)),
            ("shaders/invert.vert", vert.data(using: .utf8)!),
            ("shaders/invert.frag", frag.data(using: .utf8)!),
        ]
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)),
                    project: try project(files: files, id: "invert_rot"))
        defer { r.teardown() }
        try XCTUnwrap(r.layers.first?.customShader)
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h1v_out_rot", isDirectory: true)
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let urls = r.captureFrames(width: 64, height: 64, times: [0.1], toDir: outDir)
        guard let url = urls.first,
              let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("capture failed"); return
        }
        var px = [UInt8](repeating: 0, count: 64 * 64 * 4)
        guard let ctx = CGContext(data: &px, width: 64, height: 64, bitsPerComponent: 8,
                                  bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            XCTFail("context failed"); return
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        // 64×16 쿼드 90° 회전 → 중심 (32,32) 의 세로 스트립(x∈[24,40], y∈[0,64]) 덮개.
        func isCyan(_ x: Int, _ y: Int) -> Bool {
            let o = (y * 64 + x) * 4
            return px[o] < 100 && px[o + 1] > 150 && px[o + 2] > 150
        }
        XCTAssertTrue(isCyan(32, 4), "세로 스트립 날린 위치(32,4)가 커버돼야 함(무전치면 가로 스트립이라 미커버)")
        XCTAssertFalse(isCyan(4, 32), "스트립 밖(4,32)은 배경(검정)이어야 함(무전치면 가로 스트립이라 칠해짐)")
    }
}
