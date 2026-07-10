import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 포워드 라이팅(2D) 렌더 반응성 + 무회귀. 합성 씬: 흰 배경(LIGHTING:1) + 점광원 1개.
/// - 색 반응: 라이트 색을 바꾸면 캡처가 그 색으로 반응.
/// - 공간 풀: 광원 xy 근처가 먼 구석보다 밝다(per-fragment 월드 재구성 검증).
/// - 무회귀: 라이트 없으면 LIGHTING:1 이어도 f_main 과 픽셀 동일(게이트 = 라이트 존재).
final class SceneForwardLightingRenderTests: XCTestCase {
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
        var px = [UInt8]()
        for _ in 0..<(w * h) { px.append(contentsOf: [r, g, b, 255]) }
        var tex = Data("TEXV0005".utf8)
        tex.append(Data(repeating: 0, count: 34))
        tex.append(OffscreenCapture.png(rgba: px, width: w, height: h)!)
        return tex
    }

    /// lightColor=nil → 라이트 오브젝트 없음. lighting → 머티리얼 LIGHTING 콤보.
    private func capture(lightColor: String?, lighting: Bool, tag: String) throws -> NSBitmapImageRep {
        var objs = #"{"id":1,"image":"models/bg.json","origin":"960 540 0","size":"1920 1080"}"#
        if let lc = lightColor {
            objs += #",{"id":2,"light":"lpoint","origin":"960 540 100","color":"\#(lc)","intensity":3.0,"radius":2000.0}"#
        }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0",
          "ambientcolor":"0.3 0.3 0.3","skylightcolor":"0.3 0.3 0.3"},
         "objects":[\(objs)]}
        """
        let combos = lighting ? #","combos":{"LIGHTING":1}"# : ""
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/bg.json", #"{"material":"materials/bg.json"}"#.data(using: .utf8)!),
            ("materials/bg.json", "{\"passes\":[{\"textures\":[\"bg\"]\(combos)}]}".data(using: .utf8)!),
            ("materials/bg.tex", solidTex(255, 255, 255)),
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_fl_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "fl_\(tag)", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "fl", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_fl_out_\(tag)")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [6.0], toDir: out).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    private func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
        let c = rep.colorAt(x: x, y: y)!
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    func testLightColorReactivity() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let red = try capture(lightColor: "1 0 0", lighting: true, tag: "red")
        let green = try capture(lightColor: "0 1 0", lighting: true, tag: "green")
        let rc = rgb(red, 32, 18), gc = rgb(green, 32, 18)   // 중앙(광원 xy)
        NSLog("%@", "[Waple] FL reactivity center red=\(rc) green=\(gc)")
        // 빨강 라이트 → 중앙 R 우세, 초록 라이트 → 중앙 G 우세(색 반응성).
        XCTAssertGreaterThan(rc.r, rc.g + 0.3, "빨강 라이트: 중앙 R>G")
        XCTAssertGreaterThan(gc.g, gc.r + 0.3, "초록 라이트: 중앙 G>R")
    }

    func testSpatialPoolBrighterAtLight() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let red = try capture(lightColor: "1 0 0", lighting: true, tag: "pool")
        let center = rgb(red, 32, 18)   // 광원 xy(960,540→중앙)
        let corner = rgb(red, 2, 2)     // 먼 구석 → 감쇠+각도로 어두워야
        NSLog("%@", "[Waple] FL pool center=\(center) corner=\(corner)")
        XCTAssertGreaterThan(center.r, corner.r + 0.3, "광원 근처가 구석보다 밝다(월드 재구성 풀)")
    }

    func testNoLightIsPixelIdenticalToUnlit() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // 라이트 없음: LIGHTING:1 이어도(게이트 off) LIGHTING 부재와 픽셀 동일 = 무회귀 근거.
        let litCombo = try capture(lightColor: nil, lighting: true, tag: "nolight_lit")
        let plain = try capture(lightColor: nil, lighting: false, tag: "nolight_plain")
        var maxDiff = 0.0
        for y in stride(from: 0, to: 36, by: 4) {
            for x in stride(from: 0, to: 64, by: 4) {
                let a = rgb(litCombo, x, y), b = rgb(plain, x, y)
                maxDiff = max(maxDiff, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
            }
        }
        NSLog("%@", "[Waple] FL no-light maxDiff=\(maxDiff)")
        XCTAssertLessThan(maxDiff, 0.01, "라이트 없으면 LIGHTING 콤보 유무와 무관하게 동일(게이트=라이트 존재)")
        // 그리고 그 무광 배경은 흰색(albedo×tint, 라이팅 미적용).
        let c = rgb(plain, 32, 18)
        XCTAssertGreaterThan(min(c.r, c.g, c.b), 0.9, "무광 배경 = 흰색")
    }

    func testLightDarkensThenTintsVsUnlit() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // 라이트 있는 lit 배경은 무광(흰색)과 달라야 한다(기능이 픽셀을 바꿈).
        let lit = try capture(lightColor: "1 0 0", lighting: true, tag: "diff_lit")
        let plain = try capture(lightColor: nil, lighting: false, tag: "diff_plain")
        let lc = rgb(lit, 32, 18), pc = rgb(plain, 32, 18)
        NSLog("%@", "[Waple] FL lit-vs-unlit center lit=\(lc) plain=\(pc)")
        XCTAssertGreaterThan(abs(lc.g - pc.g) + abs(lc.b - pc.b), 0.3, "라이트가 픽셀을 바꿔야(무광 대비)")
    }
}
