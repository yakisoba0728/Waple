import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 이미지 레이어 스프라이트시트 애니(SPRITESHEET 콤보 + .tex TEXS 프레임). 씬 시간으로 프레임 전진.
/// - 합성(항상 실행): 콤보 씬은 t=0 vs t>frametime 이 다르고, 콤보 없는 씬은 시간 무관 동일(무회귀 게이트).
/// - 실코퍼스(있을 때만): 효과+스프라이트가 전진하는지, 멀티페이지 아틀라스가 세로 스택으로 성공했는지.
final class SpriteSheetLayerRenderTests: XCTestCase {
    private func i32(_ n: Int) -> Data { var v = UInt32(truncatingIfNeeded: n).littleEndian; return Data(bytes: &v, count: 4) }

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

    /// 2프레임 가로 스프라이트시트 .tex: 2×1 아틀라스(픽셀0=빨강 프레임, 픽셀1=초록 프레임) + TEXS0003.
    /// 프레임0 서브렉트=(0,0,1,1) 빨강, 프레임1=(1,0,1,1) 초록, frametime=ft. blit 이 1×1 프레임을 추출.
    private func twoFrameSpriteTex(ft: Float = 0.2) -> Data {
        let png = OffscreenCapture.png(rgba: [255, 0, 0, 255, 0, 255, 0, 255], width: 2, height: 1)!
        var tex = Data("TEXV0005".utf8)
        tex.append(Data(repeating: 0, count: 34))   // 헤더(dims 0 — PNG 시그니처 스캔 경로, 실dims 는 PNG)
        tex.append(png)
        // TEXS0003: frameCount | gifW | gifH | [i32 id, f32 time, f32 x,y,w,widthY,heightX,h] × N
        func f32(_ v: Float) -> Data { var b = v.bitPattern.littleEndian; return Data(bytes: &b, count: 4) }
        tex.append(Data("TEXS0003".utf8)); tex.append(0)
        tex.append(i32(2)); tex.append(i32(2)); tex.append(i32(1))                    // count, gifW, gifH
        tex.append(i32(0)); tex.append(f32(ft)); tex.append(f32(0)); tex.append(f32(0))   // f0 id,t,x,y
        tex.append(f32(1)); tex.append(f32(0)); tex.append(f32(0)); tex.append(f32(1))    // f0 w,wy,hx,h
        tex.append(i32(0)); tex.append(f32(ft)); tex.append(f32(1)); tex.append(f32(0))   // f1 id,t,x,y
        tex.append(f32(1)); tex.append(f32(0)); tex.append(f32(0)); tex.append(f32(1))    // f1 w,wy,hx,h
        return tex
    }

    private func scenePkg(combo: Bool) -> Data {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","size":"1920 1080","origin":"960 540 0",
                     "visible":{"value":true}}]}
        """
        let combos = combo ? #","combos":{"SPRITESHEET":1}"# : ""
        let material = #"{"passes":[{"shader":"genericimage2","textures":["w"]"# + combos + "}]}"
        return encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", material.data(using: .utf8)!),
            ("materials/w.tex", twoFrameSpriteTex()),
        ])
    }

    private func mountAndCapture(_ pkg: Data, id: String, times: [Float]) throws -> [URL] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_ss_\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pkg.write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: id, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        addTeardownBlock { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_ss_\(id)")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return r.captureFrames(width: 64, height: 36, times: times, toDir: out)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// (redAvg, greenAvg) 화면 평균 — 프레임 판별용.
    private func rg(_ url: URL) -> (Double, Double) {
        guard let rep = NSBitmapImageRep(data: try! Data(contentsOf: url)) else { return (-1, -1) }
        var r = 0.0, g = 0.0, n = 0.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 20)) {
            for x in stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 20)) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                r += c.redComponent; g += c.greenComponent; n += 1
            }
        }
        return n > 0 ? (r / n, g / n) : (-1, -1)
    }

    // MARK: 합성(항상 실행)

    /// 콤보 씬: t=0 은 프레임0(빨강), t=0.3(>frametime 0.2, total 0.4 내)은 프레임1(초록) → 다름.
    func testSpriteComboLayerAdvancesFrames() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let urls = try mountAndCapture(scenePkg(combo: true), id: "combo", times: [0.0, 0.3])
        XCTAssertEqual(urls.count, 2)
        let t0 = rg(urls[0]), t1 = rg(urls[1])
        XCTAssertGreaterThan(t0.0, 0.6, "t=0 프레임0: 빨강 우세")
        XCTAssertLessThan(t0.1, 0.4, "t=0: 초록 낮음")
        XCTAssertGreaterThan(t1.1, 0.6, "t=0.3 프레임1: 초록 우세")
        XCTAssertLessThan(t1.0, 0.4, "t=0.3: 빨강 낮음")
    }

    /// 콤보 없는 씬(같은 .tex): 프레임 전진 없음 → 시간 무관 동일. TEXS 프레임이 있어도 게이트가 막는다.
    func testNoComboLayerIsStaticAcrossTime() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let urls = try mountAndCapture(scenePkg(combo: false), id: "nocombo", times: [0.0, 0.3])
        XCTAssertEqual(urls.count, 2)
        let a = try Data(contentsOf: urls[0]), b = try Data(contentsOf: urls[1])
        XCTAssertEqual(a, b, "콤보 없으면 t=0 과 t=0.3 픽셀 동일(정지)")
    }

    // MARK: 실코퍼스(폴더 있을 때만 — CI 안전 skip)

    private func realScene(_ id: String) throws -> WallpaperProject {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let folder = URL(fileURLWithPath: base).appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("scene.pkg").path) else {
            throw XCTSkip("no real pkg: \(id)")
        }
        return try ProjectJSONParser.parse(folderURL: folder)
    }

    /// 효과+스프라이트(Planeta, effSprite 레이어 70프레임 ft0.04): 스프라이트 레이어에 frames 가 실리고
    /// 효과 체인을 통과해도 시간 전진한다(피벗의 핵심 — UV-쿼드가 아닌 "프레임 추출 → 효과" 아키텍처가
    /// 동작하는지, 크래시 없이). 실측 코퍼스 37씬 중 17씬이 효과+스프라이트라 이 경로가 다수.
    func testRealEffectSpriteLayerAdvances() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let project = try realScene("3616389236")   // 비디오 아님 + 효과+스프라이트 레이어 보유
        let r = SceneRenderer()
        r.nowPlayingProvider = StoppedNowPlayingProvider()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)), project: project)
        addTeardownBlock { r.teardown() }
        XCTAssertTrue(r.layers.contains { $0.frames.count > 1 && !$0.effects.isEmpty },
                      "효과+스프라이트 레이어(frames>1 + effects)가 실물에 존재(피벗 대상)")
        let out = URL(fileURLWithPath: "/tmp/waple_ss_planeta")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let urls = r.captureFrames(width: 320, height: 180, times: [0.5, 1.5, 2.5], toDir: out)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipIf(urls.count < 3, "capture 실패(환경)")
        let distinct = Set(try urls.map { try Data(contentsOf: $0) })
        XCTAssertGreaterThan(distinct.count, 1, "효과+스프라이트: 시간에 따라 화면 변화(프레임 전진, 크래시 없음)")
    }

    /// 멀티페이지 불균일 아틀라스(鸟_00020, imageCount=2, page0 7680×7920 / page1 5760×2880): stackedAtlas
    /// 가 max-width×sum-height 로 성공해 page1(imageId==1) 프레임이 누적 y-오프셋을 받았는지 확정.
    /// 실패(nil 폴백)면 imageId=1 프레임이 page-relative y(0) 그대로 → blit 이 page0 좌표를 읽는 조용한
    /// 오프레임 — advisor #1 이 지목한 정확히 그 함정을 잡는 결정적 체크. resolveTextureWithFrames 를 직접
    /// 호출(전체 씬 마운트 회피 — 45레이어 디코드 대신 이 .tex 만).
    func testRealMultipageAtlasStacked() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let pkgURL = URL(fileURLWithPath: base).appendingPathComponent("3486806915/scene.pkg")
        guard FileManager.default.fileExists(atPath: pkgURL.path) else { throw XCTSkip("no real pkg: 3486806915") }
        let pkg = try ScenePackage.parse(Data(contentsOf: pkgURL))
        let r = SceneRenderer()
        guard let result = r.resolveTextureWithFrames("materials/鸟_00020.tex", package: pkg, device: device) else {
            return XCTFail("resolveTextureWithFrames nil")
        }
        XCTAssertGreaterThan(result.frames.count, 1, "멀티프레임 시트(디코드 성공)")
        let page1 = result.frames.first { $0.imageId == 1 }
        XCTAssertNotNil(page1, "imageId==1 프레임 존재")
        XCTAssertGreaterThan(page1?.atlasY ?? 0, 0, "page1 프레임은 세로 스택 누적 오프셋을 받아야(stackedAtlas 비-nil 성공)")
        for f in result.frames {  // 모든 프레임이 스택 텍스처 경계 내(blit 이 클램프 없이 정확히 맞물림)
            XCTAssertLessThanOrEqual(Int(f.atlasY + f.atlasHeight), result.texture.height, "프레임이 스택 아틀라스 높이 내")
        }
    }
}
