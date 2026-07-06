import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 레이어 colorBlendMode(common_blending.h ApplyBlending 1-32) 오라클:
/// 흰 배경 × 빨강 multiply(2) → 빨강 / 흰 배경 vs 흰 difference(18) → 검정.
/// 미구현이면 일반 알파 합성이라 두 경우 모두 오답(각각 빨강이지만 difference 는 흰색 유지)이 된다.
final class BlendModeLayerTests: XCTestCase {
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

    private func solidTex(_ r: UInt8, _ g: UInt8, _ b: UInt8, alpha: UInt8 = 255) -> Data {
        var px = [UInt8]()
        for _ in 0..<64 { px.append(contentsOf: [r, g, b, alpha]) }
        let png = OffscreenCapture.png(rgba: px, width: 8, height: 8)!
        var tex = Data("TEXV0005".utf8)
        tex.append(Data(repeating: 0, count: 34))
        tex.append(png)
        return tex
    }

    /// 흰 bg + (컬러, colorBlendMode) 오버레이 렌더 → 중앙 픽셀.
    private func centerPixel(mode: Int, overlay: (UInt8, UInt8, UInt8), alpha: Float = 1,
                             tag: String) throws -> NSColor {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/o.json","origin":"960 540 0","size":"1920 1080",
            "alpha":\(alpha),"colorBlendMode":\(mode)}]}
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("models/o.json", #"{"material":"materials/o.json"}"#.data(using: .utf8)!),
            ("materials/o.json", #"{"passes":[{"textures":["o"]}]}"#.data(using: .utf8)!),
            ("materials/o.tex", solidTex(overlay.0, overlay.1, overlay.2)),
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_bm_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_bm_\(tag)")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        return try XCTUnwrap(rep.colorAt(x: 32, y: 18))
    }

    func testMultiplyBlend_whiteTimesRedIsRed() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let c = try centerPixel(mode: 2, overlay: (255, 0, 0), tag: "mul")
        XCTAssertGreaterThan(c.redComponent, 0.9)
        XCTAssertLessThan(c.greenComponent, 0.1)
        XCTAssertLessThan(c.blueComponent, 0.1)
    }

    func testDifferenceBlend_whiteMinusWhiteIsBlack() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // 일반 합성이면 흰색 유지(1.0) — difference 구현 시에만 검정.
        let c = try centerPixel(mode: 18, overlay: (255, 255, 255), tag: "diff")
        XCTAssertLessThan(c.redComponent, 0.1)
        XCTAssertLessThan(c.greenComponent, 0.1)
    }

    func testBlendOpacity_halfAlphaMixes() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // multiply 검정 × 흰 bg, alpha 0.5 → mix(white, black, 0.5) = 0.5 회색.
        let c = try centerPixel(mode: 2, overlay: (0, 0, 0), alpha: 0.5, tag: "half")
        XCTAssertEqual(c.redComponent, 0.5, accuracy: 0.06)
        XCTAssertEqual(c.greenComponent, 0.5, accuracy: 0.06)
    }
}
