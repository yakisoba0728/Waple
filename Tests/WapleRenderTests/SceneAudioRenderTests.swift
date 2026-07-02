import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

final class SceneAudioRenderTests: XCTestCase {
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

    /// 디코드 가능한 .tex = TEXV0005 헤더(패딩) + 솔리드 PNG(시그니처 경로 → CGImageSource).
    private func solidTex(_ r: UInt8, _ g: UInt8, _ b: UInt8, w: Int = 8, h: Int = 8) -> Data {
        var px = [UInt8](); px.reserveCapacity(w * h * 4)
        for _ in 0..<(w * h) { px.append(contentsOf: [r, g, b, 255]) }
        let png = OffscreenCapture.png(rgba: px, width: w, height: h)!
        var tex = Data("TEXV0005".utf8)
        tex.append(Data(repeating: 0, count: 34))  // → 오프셋 42, PNG 시그니처는 limit 512 내
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
}
