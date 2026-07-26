import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 레이어 colorBlendMode(common_blending.h ApplyBlending 1-32) 오라클:
/// 흰 배경 × 빨강 multiply(2) → 빨강 / 흰 배경 vs 흰 difference(18) → 검정.
/// 미구현이면 일반 알파 합성이라 두 경우 모두 오답(각각 빨강이지만 difference 는 흰색 유지)이 된다.
final class BlendModeLayerTests: XCTestCase {
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

    /// P⑦: colorBlendMode 레이어 N개가 pooledOffscreen(프레임 내 단조 체크아웃)이 아니라 전용 캐시
    /// 1장(blendModeSnapshotTexture)을 재사용하는지 직접 확인. 종전 구현은 이 씬에서 레이어당 1장씩
    /// 드로어블 크기 텍스처를 텍스처풀에 상주시켰다(코퍼스 최대 366개 실측) — 수정 후에는 blend 경로가
    /// pooledOffscreen 을 아예 거치지 않으므로 그 풀 키("b"/"h" 접두)가 아예 생기지 않는다.
    /// 동시에 순차 재사용이 각 레이어의 "그 시점까지의" acc 를 정확히 샘플하는지(비트동일 합성)도
    /// 마지막 픽셀 값으로 검증 — 흰 배경에 multiply(mode 2) 회색(128) 오버레이를 8회 누적하면
    /// (128/255)^8 ≈ 0.0057 로 사실상 검정.
    func testManyBlendLayersReuseSingleSnapshotTexture() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let layerCount = 8
        var objects = """
        {"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"}
        """
        for i in 0..<layerCount {
            objects += """
            ,{"id":\(i + 2),"image":"models/o.json","origin":"960 540 0","size":"1920 1080",
             "alpha":1,"colorBlendMode":2}
            """
        }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[\(objects)]}
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("models/o.json", #"{"material":"materials/o.json"}"#.data(using: .utf8)!),
            ("materials/o.json", #"{"passes":[{"textures":["o"]}]}"#.data(using: .utf8)!),
            ("materials/o.tex", solidTex(128, 128, 128)),
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_bm_many", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "many", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "many", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_bm_many")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)

        // 전용 캐시 1장만 상주 — 종전 pooledOffscreen 경로가 남기던 "b"/"h" 접두 풀 키가 없어야 한다.
        XCTAssertFalse(r.texturePool.keys.contains { $0.hasPrefix("b") || $0.hasPrefix("h") },
                       "colorBlendMode 레이어가 여전히 프레임풀 오프스크린을 체크아웃 중(레이어수만큼 상주)")
        let snap = try XCTUnwrap(r.blendModeSnapshotTexture, "전용 스냅샷 캐시가 채워지지 않음")
        XCTAssertEqual(snap.width, 64)
        XCTAssertEqual(snap.height, 36)

        // 순차 재사용이 각 레이어의 시점별 acc 를 정확히 반영하는지(비트동일 합성) 최종 픽셀로 확인.
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let c = try XCTUnwrap(rep.colorAt(x: 32, y: 18))
        let expected = pow(128.0 / 255.0, Double(layerCount))
        XCTAssertEqual(Double(c.redComponent), expected, accuracy: 0.02)
    }

    // MARK: - C⑥ 텍스트 colorBlendMode(파스도 소비도 없어 항상 Normal 합성되던 결함)

    /// 흰 배경 위 빨강 불투명 텍스트 × difference(18) → 글리프 안쪽은 |흰-빨강|=시안(0,1,1).
    /// 미구현(항상 Normal 합성)이면 불투명 빨강 텍스트가 그대로(1,0,0) 그려져 시안이 전혀 안 나온다 —
    /// multiply 처럼 배경이 흰색이라 결과가 우연히 같아지는 모드는 오라클로 못 써서 difference 사용.
    func testTextColorBlendMode_differenceOnWhiteBackgroundYieldsCyanGlyph() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"},
           {"text":"HELLO","font":"systemfont_arial","pointsize":300.0,"color":"1 0 0","alpha":1,
            "horizontalalign":"center","verticalalign":"center","origin":"960 540 0","size":"1 1",
            "colorBlendMode":18,"visible":{"value":true}}]}
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_bm_text_diff", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "textdiff", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "textdiff", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 72)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_bm_text_diff")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 128, height: 72, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        // 중앙 행에서 가장 짙은(빨강 최소) 픽셀 = 글리프 내부(안티에일리어싱 경계 배제).
        var minRed: CGFloat = 1
        var atMinRed: NSColor? = nil
        for x in stride(from: 0, to: 128, by: 1) {
            guard let c = rep.colorAt(x: x, y: 36) else { continue }
            if c.redComponent < minRed { minRed = c.redComponent; atMinRed = c }
        }
        let c = try XCTUnwrap(atMinRed)
        NSLog("%@", "[Waple] text diff-blend darkest-red px = r=\(c.redComponent) g=\(c.greenComponent) b=\(c.blueComponent)")
        XCTAssertLessThan(c.redComponent, 0.3, "difference(흰-빨강) → 글리프 내부는 red 성분이 낮아야(시안)")
        XCTAssertGreaterThan(c.greenComponent, 0.7, "difference(흰-빨강) → green 성분은 높아야(시안)")
        XCTAssertGreaterThan(c.blueComponent, 0.7, "difference(흰-빨강) → blue 성분은 높아야(시안)")
    }

    /// colorBlendMode 미지정(기본 0/normal)은 종전과 동일 — 텍스트가 정상 불투명으로 그려져야(무회귀).
    func testTextColorBlendMode_defaultZeroRendersNormalOpaque() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"},
           {"text":"HELLO","font":"systemfont_arial","pointsize":300.0,"color":"1 0 0","alpha":1,
            "horizontalalign":"center","verticalalign":"center","origin":"960 540 0","size":"1 1",
            "visible":{"value":true}}]}
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_bm_text_normal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "textnormal", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "textnormal", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 72)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_bm_text_normal")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 128, height: 72, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        var maxRed: CGFloat = 0
        for x in stride(from: 0, to: 128, by: 1) {
            guard let c = rep.colorAt(x: x, y: 36) else { continue }
            if c.redComponent > maxRed { maxRed = c.redComponent }
        }
        XCTAssertGreaterThan(maxRed, 0.7, "colorBlendMode 미지정 → 정상 불투명 빨강 텍스트(무회귀)")
    }
}
