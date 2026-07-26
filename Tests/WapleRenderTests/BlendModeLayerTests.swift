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
}
