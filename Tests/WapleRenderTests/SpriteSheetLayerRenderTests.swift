import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 이미지 레이어 스프라이트시트 애니(SPRITESHEET 콤보 + .tex TEXS 프레임). 씬 시간으로 프레임 전진.
/// - 합성(항상 실행): 콤보 씬은 t=0 vs t>frametime 이 다르고, 콤보 없는 씬은 시간 무관 동일(무회귀 게이트).
/// - 실코퍼스(있을 때만): 효과+스프라이트가 전진하는지, 멀티페이지 아틀라스가 세로 스택으로 성공했는지.
final class SpriteSheetLayerRenderTests: XCTestCase {
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

    // MARK: 프레임 rect→UV 변환(유닛, Metal 불필요)

    /// spriteFrameTexture 의 아틀라스 서브렉트 추출 규약: (1) 정수 서브렉트 클램프(경계 밖 TEXS 렉트 방어),
    /// (2) 정규화 rect + v_spriteframe/f_spriteframe 의 텍셀중심 매핑이 dst 픽셀 i → 아틀라스 텍셀 sx+i 로
    /// 정확히 낙하하는지. 이게 **nearest 추출 = 종전 blit 텍셀 동일(비-BC bit-identical)** 의 근거 —
    /// half-texel inset 이 불필요한(그리고 있으면 bit-identity 를 깨는) 이유.
    func testSpriteSubrectAndTexelCenterMapping() {
        let aw = 3840, ah = 1080
        // (1) 아틀라스 절대 좌표(frame1 = 우측 절반).
        let f1 = TexImage.TexFrame(imageId: 0, time: 0.1, x: 1920, y: 0, width: 1920, height: 1080)
        let r1 = SceneRenderer.spriteSubrect(atlasW: aw, atlasH: ah, frame: f1)
        XCTAssertEqual([r1.x, r1.y, r1.w, r1.h], [1920, 0, 1920, 1080])
        // 경계 밖 렉트(x=4000>aw, y 음수): sx/sy 클램프 + fw/fh 축소로 항상 아틀라스 내(추출 크래시 방지).
        let f2 = TexImage.TexFrame(imageId: 0, time: 0.1, x: 4000, y: -50, width: 500, height: 500)
        let r2 = SceneRenderer.spriteSubrect(atlasW: aw, atlasH: ah, frame: f2)
        XCTAssertGreaterThanOrEqual(r2.x, 0); XCTAssertGreaterThanOrEqual(r2.y, 0)
        XCTAssertLessThanOrEqual(r2.x + r2.w, aw); XCTAssertLessThanOrEqual(r2.y + r2.h, ah)

        // (2) 텍셀중심 매핑: f_spriteframe 이 uv=rect.xy+in.uv*rect.zw(정규화), in.uv 는 v_spriteframe 의
        //     dst 픽셀중심. nearest 샘플이 아틀라스 텍셀 sx+i 로 떨어지고 경계서 ±0.5 여유(견고성).
        let (sx, sy, fw, fh) = r1
        let u0 = Float(sx) / Float(aw), du = Float(fw) / Float(aw)
        let v0 = Float(sy) / Float(ah), dv = Float(fh) / Float(ah)
        for i in [0, 1, fw / 2, fw - 1] {
            let atlasTexel = (u0 + ((Float(i) + 0.5) / Float(fw)) * du) * Float(aw)
            XCTAssertEqual(Int(atlasTexel.rounded(.down)), sx + i, "dst x=\(i) → 아틀라스 텍셀 sx+i")
            XCTAssertEqual(atlasTexel - Float(sx + i), 0.5, accuracy: 0.02, "텍셀중심(nearest 경계 여유)")
        }
        for j in [0, 1, fh / 2, fh - 1] {
            let atlasTexel = (v0 + ((Float(j) + 0.5) / Float(fh)) * dv) * Float(ah)
            XCTAssertEqual(Int(atlasTexel.rounded(.down)), sy + j, "dst y=\(j) → 아틀라스 텍셀 sy+j")
            XCTAssertEqual(atlasTexel - Float(sy + j), 0.5, accuracy: 0.02)
        }
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

    /// 합성 불균일 멀티페이지(page0 2×1, page1 1×1) — 실코퍼스 멀티페이지 테스트(gated)의 CI 안전 미러.
    /// stackedAtlas 가 max-width(2)×sum-height(2)로 스택하고 imageId=1 프레임에 누적 y-오프셋(page0
    /// 높이=1)을 주는지 확정. 종전 same-dims 가드였다면 nil 폴백 → atlasY=0 이 되어 실패(조용한 오프레임).
    func testStackedAtlasNonUniformPagesOffset() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        func f32(_ v: Float) -> Data { var b = v.bitPattern.littleEndian; return Data(bytes: &b, count: 4) }
        var tex = Data("TEXV0005".utf8); tex.append(0); tex.append(Data("TEXI0001".utf8)); tex.append(0)
        tex.append(i32(0)); tex.append(i32(0)); tex.append(i32(2)); tex.append(i32(1)); tex.append(i32(2)); tex.append(i32(1))  // fmt0, texW2 texH1 imgW2 imgH1
        tex.append(Data("TEXB0003".utf8)); tex.append(0); tex.append(i32(2)); tex.append(i32(-1))               // imageCount=2, imageFormat=-1(raw)
        tex.append(i32(1)); tex.append(i32(2)); tex.append(i32(1)); tex.append(i32(0)); tex.append(i32(8)); tex.append(i32(8))  // page0: mipCount1, w2 h1 isLZ4=0 dec8 comp8
        tex.append(Data([255, 0, 0, 255, 0, 0, 255, 255]))                                                       // page0 2×1: red, blue
        tex.append(i32(1)); tex.append(i32(1)); tex.append(i32(1)); tex.append(i32(0)); tex.append(i32(4)); tex.append(i32(4))  // page1: mipCount1, w1 h1 isLZ4=0 dec4 comp4
        tex.append(Data([0, 255, 0, 255]))                                                                       // page1 1×1: green
        tex.append(Data("TEXS0003".utf8)); tex.append(0)
        tex.append(i32(2)); tex.append(i32(2)); tex.append(i32(2))                                               // frameCount, gifW, gifH
        tex.append(i32(0)); tex.append(f32(0.2)); tex.append(f32(0)); tex.append(f32(0)); tex.append(f32(2)); tex.append(f32(0)); tex.append(f32(0)); tex.append(f32(1))  // f0 id0 x0y0 w2 h1
        tex.append(i32(1)); tex.append(f32(0.2)); tex.append(f32(0)); tex.append(f32(0)); tex.append(f32(1)); tex.append(f32(0)); tex.append(f32(0)); tex.append(f32(1))  // f1 id1 x0y0 w1 h1
        let package = try ScenePackage.parse(encodePkg([("materials/mp.tex", tex)]))
        let r = SceneRenderer()
        guard let res = r.resolveTextureWithFrames("materials/mp.tex", package: package, device: device) else {
            return XCTFail("resolveTextureWithFrames nil")
        }
        XCTAssertEqual(res.frames.count, 2)
        XCTAssertEqual(res.texture.width, 2, "maxW = max(2,1)")
        XCTAssertEqual(res.texture.height, 2, "sumH = 1+1")
        XCTAssertEqual(res.frames.first { $0.imageId == 1 }?.atlasY, 1, "page1 프레임 누적 y-오프셋 = page0 높이(1)")
        XCTAssertEqual(res.frames.first { $0.imageId == 0 }?.atlasY, 0, "page0 프레임은 오프셋 0")
    }

    /// 초대형 멀티페이지(스택 높이 20000 > Metal 16384): stackedAtlas 가 디코드 전 조기 거부 →
    /// resolveTextureWithFrames 가 **정지 폴백(frames=[])** 으로 "조용한 오프레임 애니" 대신 page 0
    /// 정지. 실코퍼스 6씬(3379048027 7페이지 sumH 52920 등)의 CI 안전 미러(1×10000 ×2페이지).
    func testTallMultipageFallsBackToStaticNotWrongFrames() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        func f32(_ v: Float) -> Data { var b = v.bitPattern.littleEndian; return Data(bytes: &b, count: 4) }
        let ph = 10000
        let page = Data(repeating: 128, count: ph * 4)   // 1×10000 raw RGBA
        var tex = Data("TEXV0005".utf8); tex.append(0); tex.append(Data("TEXI0001".utf8)); tex.append(0)
        tex.append(i32(0)); tex.append(i32(0)); tex.append(i32(1)); tex.append(i32(ph)); tex.append(i32(1)); tex.append(i32(ph))  // fmt0, 1×10000
        tex.append(Data("TEXB0003".utf8)); tex.append(0); tex.append(i32(2)); tex.append(i32(-1))                                  // imageCount=2
        for _ in 0..<2 {   // 2 페이지, 각 1×10000 → 스택 높이 20000
            tex.append(i32(1)); tex.append(i32(1)); tex.append(i32(ph)); tex.append(i32(0)); tex.append(i32(ph * 4)); tex.append(i32(ph * 4)); tex.append(page)
        }
        tex.append(Data("TEXS0003".utf8)); tex.append(0)
        tex.append(i32(2)); tex.append(i32(1)); tex.append(i32(ph))
        tex.append(i32(0)); tex.append(f32(0.2)); tex.append(f32(0)); tex.append(f32(0)); tex.append(f32(1)); tex.append(f32(0)); tex.append(f32(0)); tex.append(f32(Float(ph)))  // f0 id0
        tex.append(i32(1)); tex.append(f32(0.2)); tex.append(f32(0)); tex.append(f32(0)); tex.append(f32(1)); tex.append(f32(0)); tex.append(f32(0)); tex.append(f32(Float(ph)))  // f1 id1
        let package = try ScenePackage.parse(encodePkg([("materials/tall.tex", tex)]))
        let r = SceneRenderer()
        guard let res = r.resolveTextureWithFrames("materials/tall.tex", package: package, device: device) else {
            return XCTFail("resolveTextureWithFrames nil")
        }
        XCTAssertTrue(res.frames.isEmpty, "스택 높이>16384 → 정지 폴백(imageId≥1 조용한 오프레임 금지)")
        XCTAssertEqual(res.texture.height, ph, "폴백은 page 0 텍스처(정지 표시)")
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
