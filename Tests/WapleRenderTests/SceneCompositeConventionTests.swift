import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// Premultiply 규약(설계 §3): 이펙트 패스는 straight-in/straight-out, premultiply 는 최종 컴포지트에서 단 한 번.
/// - 반투명 텍스처 레이어(무-이펙트)가 올바르게 합성되는지 (기존엔 straight 출력 + src=one 이라 과다 밝음)
/// - 알파 감소 효과 체인이 이중 premult 없이 곱해지는지 (0.7×0.7 → 0.49; 기존 버그 0.343)
final class SceneCompositeConventionTests: XCTestCase {
    private func avgLuma(_ url: URL) -> Double {
        guard let rep = NSBitmapImageRep(data: try! Data(contentsOf: url)) else { return -1 }
        var sum = 0.0; var n = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 40)) {
            for x in stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 40)) {
                if let c = rep.colorAt(x: x, y: y) {
                    sum += (c.redComponent + c.greenComponent + c.blueComponent) / 3.0; n += 1
                }
            }
        }
        return n > 0 ? sum / Double(n) : -1
    }

    private func renderLuma(scene: String, texAlpha: UInt8 = 255, extraFiles: [(String, Data)] = [], tag: String) throws -> Double {
        var files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255, alpha: texAlpha)),
        ]
        files.append(contentsOf: extraFiles)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_cc_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let outDir = URL(fileURLWithPath: "/tmp/waple_cc_\(tag)")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let urls = r.captureFrames(width: 64, height: 36, times: [0.1], toDir: outDir)
        return avgLuma(try XCTUnwrap(urls.first))
    }

    private let plainScene = """
    {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
     "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"}]}
    """

    /// 컴포지션(_rt_FullFrameBuffer) 레이어: 흰 bg + fullscreen 컴포지션 레이어에 tint(빨강, multiply) 효과
    /// → 화면 전체가 빨강으로 물들어야(알파 1 유지 = 완전 교체). 미지원이면 흰색 유지.
    /// (opacity 류는 컴포지션에선 수학적 항등 — 화면 복사본을 화면 위에 반투명 합성 = 원본. WE 동일.)
    func testFrameBufferLayerAppliesEffectToScene() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/util/fullscreenlayer.json","origin":"960 540 0","size":"1920 1080",
            "effects":[{"file":"effects/tint/effect.json","passes":[{"combos":{"BLENDMODE":2},
              "constantshadervalues":{"color":"1 0 0","alpha":1}}]}],
            "visible":{"value":true}}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_cc_fbtint", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("models/util/fullscreenlayer.json", #"{"material":"materials/util/fullscreenlayer.json","fullscreen":true,"passthrough":true}"#.data(using: .utf8)!),
            ("materials/util/fullscreenlayer.json", #"{"passes":[{"shader":"passthrough","textures":["_rt_FullFrameBuffer"]}]}"#.data(using: .utf8)!),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "fbtint", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "fbtint", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_cc_fbtint")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let c = try XCTUnwrap(rep.colorAt(x: 32, y: 18))
        NSLog("%@", "[Waple] framebuffer tint px=(\(c.redComponent),\(c.greenComponent),\(c.blueComponent))")
        XCTAssertGreaterThan(c.redComponent, 0.8, "컴포지션 tint 가 화면을 빨강으로")
        XCTAssertLessThan(c.greenComponent, 0.2, "미지원이면 흰색(green=1)")
    }

    /// 컴포지션 방향 보존: 상단 절반만 빨간 씬 + passthrough 컴포지션 → 빨강은 상단에 남아야(Y-플립 회귀 방지).
    func testFrameBufferPreservesOrientation() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0.2"},
         "objects":[
           {"id":1,"image":"models/w.json","origin":"960 270 0","size":"1920 540"},
           {"id":2,"image":"models/util/fullscreenlayer.json","origin":"960 540 0","size":"1920 1080",
            "effects":[{"file":"effects/tint/effect.json","passes":[{"combos":{"BLENDMODE":2},
              "constantshadervalues":{"color":"1 0 0","alpha":1}}]}],
            "visible":{"value":true}}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_cc_fbflip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("models/util/fullscreenlayer.json", #"{"material":"materials/util/fullscreenlayer.json","fullscreen":true}"#.data(using: .utf8)!),
            ("materials/util/fullscreenlayer.json", #"{"passes":[{"shader":"passthrough","textures":["_rt_FullFrameBuffer"]}]}"#.data(using: .utf8)!),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "fbflip", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "fbflip", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_cc_fbflip")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let top = try XCTUnwrap(rep.colorAt(x: 32, y: 5))
        let bottom = try XCTUnwrap(rep.colorAt(x: 32, y: 30))
        NSLog("%@", "[Waple] fb orientation top=(\(top.redComponent)) bottom=(\(bottom.redComponent))")
        XCTAssertGreaterThan(top.redComponent, 0.8, "상단 빨강 유지(플립이면 하단으로 감)")
        XCTAssertLessThan(bottom.redComponent, 0.3, "하단은 어두워야")
    }

    /// 무효과 컴포지션 레이어(passthrough)는 화면을 그대로 유지해야 한다(이중 그리기/화이트아웃 없음).
    func testFrameBufferPassthroughIsIdentity() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/util/fullscreenlayer.json","origin":"960 540 0","size":"1920 1080",
            "visible":{"value":true}}]}
        """
        let luma = try renderLuma(scene: scene, extraFiles: [
            ("models/util/fullscreenlayer.json", #"{"material":"materials/util/fullscreenlayer.json","fullscreen":true,"passthrough":true}"#.data(using: .utf8)!),
            ("materials/util/fullscreenlayer.json", #"{"passes":[{"shader":"passthrough","textures":["_rt_FullFrameBuffer"]}]}"#.data(using: .utf8)!),
        ], tag: "fbpass")
        NSLog("%@", "[Waple] framebuffer passthrough luma=\(luma)")
        XCTAssertEqual(luma, 1.0, accuracy: 0.03, "passthrough 컴포지션은 항등이어야")
    }

    /// 부분(비-fullscreen) 컴포지션 레이어(_rt_FullFrameBuffer)는 프레임버퍼를 **화면좌표**로 샘플해야 —
    /// 전체 acc 를 레이어 쿼드에 로컬 UV(0-1)로 stretch 하면 안 됨(E1 회색-삼각형-덩어리 원인).
    /// 씬: 좌측 25% 흰띠 + 나머지 검정. 컴포지션 레이어(passthrough, 무효과)는 **우측 절반**(전부 검정 bg 위).
    /// - 올바름(화면좌표): 컴포지션 영역은 뒤 검정을 1:1 로 통과 → 검정 유지.
    /// - 버그(stretch): 전체 화면(흰띠+검정)을 우측 절반 쿼드에 눌러담음 → 쿼드 좌측 가장자리에 흰띠가 나타남.
    func testFrameBufferPartialLayerSamplesScreenSpaceNotStretched() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/w.json","origin":"240 540 0","size":"480 1080"},
           {"id":2,"image":"models/util/composelayer.json","origin":"1440 540 0","size":"960 1080",
            "visible":{"value":true}}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_cc_fbpartial", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("models/util/composelayer.json", #"{"material":"materials/util/composelayer.json","passthrough":true}"#.data(using: .utf8)!),
            ("materials/util/composelayer.json", #"{"passes":[{"shader":"composelayer","textures":["_rt_FullFrameBuffer"]}]}"#.data(using: .utf8)!),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "fbpartial", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "fbpartial", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_cc_fbpartial")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        // 컨트롤: 좌측(캡처 x=8 = 화면 240) = 흰띠 → 씬이 실제로 렌더됐음을 보증.
        let control = try XCTUnwrap(rep.colorAt(x: 8, y: 18))
        // 판별자: 캡처 x=34(화면 x≈1020, 컴포지션 영역 좌측·검정 bg 위).
        //   stretch 버그면 쿼드 로컬 UV.x≈0.06 → srcTex x≈120 = 흰띠 샘플 → 흰색.
        //   화면좌표 샘플이면 뒤 검정 통과 → 검정.
        let inside = try XCTUnwrap(rep.colorAt(x: 34, y: 18))
        NSLog("%@", "[Waple] fb partial control(x8)=\(control.redComponent) inside(x34)=\(inside.redComponent)")
        XCTAssertGreaterThan(control.redComponent, 0.8, "좌측 흰띠(씬 렌더 컨트롤)")
        XCTAssertLessThan(inside.redComponent, 0.3, "컴포지션 영역은 화면좌표로 뒤 검정을 통과해야(stretch면 흰띠가 눌려 나타남)")
    }

    /// 프로퍼티 애니메이션(alpha 1→0, 2초 single): t=0 luma 1 → t=1 ≈0.5 → t=2 ≈0.
    func testAlphaAnimationPlaysBack() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
            "alpha":{"animation":{"c0":[{"frame":0,"value":1},{"frame":60,"value":0}],
                                   "options":{"fps":30,"length":60,"mode":"single"}},"value":1.0},
            "visible":{"value":true}}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_cc_animA", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "animA", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "animA", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_cc_animA")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let urls = r.captureFrames(width: 64, height: 36, times: [0.0, 1.0, 2.0], toDir: out)
        XCTAssertEqual(urls.count, 3)
        let lumas = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { avgLuma($0) }
        // 파일명 정렬: t0.0, t1.0, t2.0
        XCTAssertEqual(lumas[0], 1.0, accuracy: 0.03, "t=0 → alpha 1")
        XCTAssertEqual(lumas[1], 0.5, accuracy: 0.1, "t=1 → 중점 ≈0.5")
        XCTAssertEqual(lumas[2], 0.0, accuracy: 0.03, "t=2 → alpha 0 (single 클램프)")
    }

    /// origin 애니메이션: 작은 사각형이 좌→우 이동(절대 키프레임). t=0 좌측 흰/우측 검, t=2 반대.
    func testOriginAnimationMovesLayer() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","size":"480 1080",
            "origin":{"animation":{"c0":[{"frame":0,"value":240},{"frame":60,"value":1680}],
                                    "options":{"fps":30,"length":60,"mode":"single"}},
                      "value":"240 540 0"},
            "visible":{"value":true}}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_cc_animO", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "animO", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "animO", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_cc_animO")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let urls = r.captureFrames(width: 64, height: 36, times: [0.0, 2.0], toDir: out).sorted { $0.lastPathComponent < $1.lastPathComponent }
        func px(_ url: URL, _ x: Int) -> Double {
            guard let rep = NSBitmapImageRep(data: try! Data(contentsOf: url)), let c = rep.colorAt(x: x, y: 18) else { return -1 }
            return c.redComponent
        }
        XCTAssertGreaterThan(px(urls[0], 8), 0.8, "t=0: 좌측(x=8/64) 흰색")
        XCTAssertLessThan(px(urls[0], 56), 0.2, "t=0: 우측 검정")
        XCTAssertGreaterThan(px(urls[1], 56), 0.8, "t=2: 우측 흰색")
        XCTAssertLessThan(px(urls[1], 8), 0.2, "t=2: 좌측 검정")
    }

    /// 텍스트 레이어: 검정 bg 중앙에 큰 흰색 "HELLO" → 중앙 행에 밝은 픽셀 존재(미지원이면 전부 검정).
    func testTextLayerRendersGlyphs() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"text":"HELLO","font":"systemfont_arial","pointsize":300.0,"color":"1 1 1","alpha":1,
            "horizontalalign":"center","verticalalign":"center","origin":"960 540 0","size":"1 1",
            "visible":{"value":true}}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_cc_text", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([("scene.json", scene.data(using: .utf8)!)]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "text", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "text", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 72)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_cc_text")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 128, height: 72, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        var bright = 0
        for x in stride(from: 0, to: 128, by: 2) {
            if let c = rep.colorAt(x: x, y: 36), c.redComponent > 0.7 { bright += 1 }
        }
        NSLog("%@", "[Waple] text bright-px(center row)=\(bright) | \(url.path)")
        XCTAssertGreaterThan(bright, 3, "중앙 행에 글리프 픽셀이 있어야(미지원이면 0)")
    }

    /// 솔리드 레이어(무텍스처 flat 머티리얼): 흰 bg 위 검정 α0.5 솔리드 → luma ≈ 0.5.
    /// (솔리드 미지원이면 레이어 드롭 → 1.0.)
    func testSolidLayerRendersColorFill() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/util/solidlayer.json","origin":"960 540 0","size":"1920 1080",
            "alpha":0.5,"color":"0 0 0","visible":{"value":true}}]}
        """
        let luma = try renderLuma(scene: scene, extraFiles: [
            ("models/util/solidlayer.json", #"{"material":"materials/util/solidlayer.json","solidlayer":true}"#.data(using: .utf8)!),
            ("materials/util/solidlayer.json", #"{"passes":[{"shader":"flat","blending":"translucent"}]}"#.data(using: .utf8)!),
        ], tag: "solid")
        NSLog("%@", "[Waple] solid layer luma=\(luma)")
        XCTAssertEqual(luma, 0.5, accuracy: 0.06, "검정 α0.5 솔리드가 흰 bg 를 절반 디밍해야 (드롭이면 1.0)")
    }

    func testCaptureFramesUsesFitAspectScale() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let oldMode = SceneRenderSettings.fitMode
        SceneRenderSettings.fitMode = .fit
        defer { SceneRenderSettings.fitMode = oldMode }

        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_cc_capturefit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "capturefit", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "capturefit", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_cc_capturefit")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 64, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        XCTAssertLessThan(try XCTUnwrap(rep.colorAt(x: 32, y: 2)).redComponent, 0.1, "fit should letterbox a 16:9 scene in a square capture")
        XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x: 32, y: 32)).redComponent, 0.9, "fit content center remains visible")
    }

    func testCaptureFramesUsesFillAspectScale() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let oldMode = SceneRenderSettings.fitMode
        SceneRenderSettings.fitMode = .fill
        defer { SceneRenderSettings.fitMode = oldMode }

        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/red.json","origin":"120 540 0","size":"240 1080"}]}
        """
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_cc_capturefill", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/red.json", #"{"material":"materials/red.json"}"#.data(using: .utf8)!),
            ("materials/red.json", #"{"passes":[{"textures":["red"]}]}"#.data(using: .utf8)!),
            ("materials/red.tex", solidTex(255, 0, 0)),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "capturefill", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "capturefill", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_cc_capturefill")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 64, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        XCTAssertLessThan(try XCTUnwrap(rep.colorAt(x: 2, y: 32)).redComponent, 0.1, "fill should crop the far-left scene stripe in a square capture")
    }

    /// 알파 0.5 흰색 레이어(무-이펙트) over 검정 → luma ≈ 0.5. (straight 출력 + src=one 이면 1.0 이 됨.)
    func testSemiTransparentLayerCompositesCorrectly() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let luma = try renderLuma(scene: plainScene, texAlpha: 128, tag: "semitransparent")
        NSLog("%@", "[Waple] semi-transparent layer luma=\(luma)")
        XCTAssertEqual(luma, 0.5, accuracy: 0.06, "a=0.5 white over black must composite to ~0.5")
    }

    /// 손-포팅 opacity 0.7 두 번 체인 → 0.49 (이중 premult 버그면 0.343).
    func testChainedOpacityHandPortNoDoublePremult() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/opacity/effect.json","passes":[{"constantshadervalues":{"alpha":0.7}}]},
                      {"file":"effects/opacity/effect.json","passes":[{"constantshadervalues":{"alpha":0.7}}]}]}]}
        """
        let luma = try renderLuma(scene: scene, tag: "chainhand")
        NSLog("%@", "[Waple] chained hand-port opacity luma=\(luma)")
        XCTAssertEqual(luma, 0.49, accuracy: 0.05, "0.7 × 0.7 = 0.49, not double-premult 0.343")
    }

    /// 변환 경로(비-스톡 이름) 0.7 두 번 체인 → 0.49.
    func testChainedOpacityTranslatedNoDoublePremult() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
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
           "effects":[{"file":"effects/dim70a/effect.json","passes":[{"constantshadervalues":{"alpha":0.7}}]},
                      {"file":"effects/dim70b/effect.json","passes":[{"constantshadervalues":{"alpha":0.7}}]}]}]}
        """
        let luma = try renderLuma(scene: scene, extraFiles: [
            ("shaders/effects/dim70a.vert", vert.data(using: .utf8)!),
            ("shaders/effects/dim70a.frag", frag.data(using: .utf8)!),
            ("shaders/effects/dim70b.vert", vert.data(using: .utf8)!),
            ("shaders/effects/dim70b.frag", frag.data(using: .utf8)!),
        ], tag: "chaintrans")
        NSLog("%@", "[Waple] chained translated opacity luma=\(luma)")
        XCTAssertEqual(luma, 0.49, accuracy: 0.05, "translated chain 0.7 × 0.7 = 0.49")
    }
}
