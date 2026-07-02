import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 파티클 z-순서(설계 §4): WE 는 씬 오브젝트 순서대로 그린다 — bg 레이어 → 파티클 → fg 레이어면
/// fg 가 파티클을 가려야 한다. (기존: 파티클이 항상 전 레이어 위 → fg 위에 빨강이 뜸.)
final class SceneZOrderRenderTests: XCTestCase {
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

    private func solidTex(_ r: UInt8, _ g: UInt8, _ b: UInt8, w: Int = 8, h: Int = 8) -> Data {
        var px = [UInt8](); px.reserveCapacity(w * h * 4)
        for _ in 0..<(w * h) { px.append(contentsOf: [r, g, b, 255]) }
        let png = OffscreenCapture.png(rgba: px, width: w, height: h)!
        var tex = Data("TEXV0005".utf8)
        tex.append(Data(repeating: 0, count: 34))
        tex.append(png)
        return tex
    }

    func testParticleInterleavesBetweenLayers() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // 오브젝트 순서: bg 흰색(전체) → 빨강 파티클(x=300 부근, 30px 사각) → fg 초록(중앙 960x540).
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/bg.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"name":"reddot","particle":"particles/dot.json","origin":"300 540 0","scale":"1 1 1"},
           {"id":3,"image":"models/fg.json","origin":"960 540 0","size":"960 540"}
         ]}
        """
        let particle = """
        {"emitter":[{"name":"sphererandom","origin":"0 0 0","distancemin":0,"distancemax":1,"rate":200}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100},{"name":"sizerandom","min":900,"max":900},
           {"name":"colorrandom","min":"255 0 0","max":"255 0 0"}],
         "operator":[{"name":"movement","gravity":"0 0 0"}],
         "renderer":[{"name":"sprite"}],"maxcount":100,"starttime":0,"material":"materials/dot.json"}
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/bg.json", #"{"material":"materials/bg.json"}"#.data(using: .utf8)!),
            ("materials/bg.json", #"{"passes":[{"textures":["bg"]}]}"#.data(using: .utf8)!),
            ("materials/bg.tex", solidTex(255, 255, 255)),
            ("models/fg.json", #"{"material":"materials/fg.json"}"#.data(using: .utf8)!),
            ("materials/fg.json", #"{"passes":[{"textures":["fg"]}]}"#.data(using: .utf8)!),
            ("materials/fg.tex", solidTex(0, 255, 0)),
            ("particles/dot.json", particle.data(using: .utf8)!),
            ("materials/dot.json", #"{"passes":[{"blending":"translucent","textures":[]}]}"#.data(using: .utf8)!),
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_zorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "zorder", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "zorder", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_zorder")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.5], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))

        func px(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
            let c = rep.colorAt(x: x, y: y)!
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        // 파티클 중심 px x = 300/1920*64 = 10, 반폭 900/2/1920*64 = 15 → x -5..25. fg 는 x 16..48.
        let particleOnly = px(10, 18)   // fg 밖, 파티클 안 → 빨강(파티클이 그려짐을 증명)
        let overlap = px(20, 18)        // fg 안, 파티클과 겹침 → fg(초록)가 가려야 함
        let bgOnly = px(60, 4)          // 배경만 → 흰색
        NSLog("%@", "[Waple] zorder px particleOnly=\(particleOnly) overlap=\(overlap) bg=\(bgOnly) | \(url.path)")
        XCTAssertGreaterThan(particleOnly.r, 0.8, "파티클 자체는 그려져야(빨강)")
        XCTAssertLessThan(particleOnly.g, 0.3, "파티클 영역은 초록 아님")
        XCTAssertGreaterThan(overlap.g, 0.8, "fg 레이어가 파티클을 가려야(초록) — 씬 순서 인터리브")
        XCTAssertLessThan(overlap.r, 0.3, "fg 위에 파티클이 뜨면 안 됨(빨강이면 z-순서 버그)")
        XCTAssertGreaterThan(bgOnly.r, 0.8)
        XCTAssertGreaterThan(bgOnly.g, 0.8)
    }
}
