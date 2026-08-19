import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// Premultiply 규약(설계 §3): 이펙트 패스는 straight-in/straight-out, premultiply 는 최종 컴포지트에서 단 한 번.
/// - 반투명 텍스처 레이어(무-이펙트)가 올바르게 합성되는지 (기존엔 straight 출력 + src=one 이라 과다 밝음)
/// - 알파 감소 효과 체인이 이중 premult 없이 곱해지는지 (0.7×0.7 → 0.49; 기존 버그 0.343)
final class SceneCompositeConventionTests: XCTestCase {

    /// 프로세스 스코프 임시 경로. **입력과 출력이 같은 규약을 써야 한다.**
    ///
    /// F148-sweep: 종전에는 입력이 `NSTemporaryDirectory()`(macOS 에서 프로세스별)인데
    /// 출력만 리터럴 `/tmp/waple_cc_<tag>` 였다 — 11쌍 전부. 같은 리포가
    /// `SnapshotCompare.swift:59` 에서 이미 PID 스코프(F148)를 도입해 두고 이 파일로
    /// 전파되지 않았다. 귀결은 조용한 오통과가 아니라 **오실패/플레이크**이고,
    /// `AGENTS.md` 가 병렬 실행에서 3/3 실패를 실측해 뒀다.
    private static func scratchDir(_ name: String) -> URL {
        let pid = ProcessInfo.processInfo.processIdentifier
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_cc_\(pid)_\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func renderLuma(scene: String, texAlpha: UInt8 = 255, extraFiles: [(String, Data)] = [], tag: String) throws -> Double {
        var files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255, alpha: texAlpha)),
        ]
        files.append(contentsOf: extraFiles)
        let dir = Self.scratchDir("\(tag)")
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let outDir = Self.scratchDir("\(tag)_out")
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
        let dir = Self.scratchDir("fbtint")
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
        let out = Self.scratchDir("fbtint_out")
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let c = try XCTUnwrap(rep.colorAt(x: 32, y: 18))
        NSLog("%@", "[Waple] framebuffer tint px=(\(c.redComponent),\(c.greenComponent),\(c.blueComponent))")
        XCTAssertGreaterThan(c.redComponent, 0.8, "컴포지션 tint 가 화면을 빨강으로")
        XCTAssertLessThan(c.greenComponent, 0.2, "미지원이면 흰색(green=1)")
    }

    /// B2-effects④: copybackground:false 컴포지션 레이어 — WE 실물(3629379075 "可调整组合层" blur,
    /// copybackground:false)에서 Waple 이 이 플래그를 무시하고 항상 acc(누적 화면)를 블릿·이펙트에
    /// 흘려 화면 전체가 이펙트(tint→빨강)로 뒤덮였다(풀프레임 워시). copybackground:false 는 acc 를
    /// 복사하지 않고 투명에서 시작해야(WE 컴포지션 레이어의 "배경 복사 끔") 하므로 흰 배경이 그대로
    /// 남아야 한다 — 미수정이면 testFrameBufferLayerAppliesEffectToScene 과 동형으로 화면이 빨강이 된다.
    func testFrameBufferCopyBackgroundFalseDoesNotWashScene() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/util/fullscreenlayer.json","origin":"960 540 0","size":"1920 1080",
            "copybackground":false,
            "effects":[{"file":"effects/tint/effect.json","passes":[{"combos":{"BLENDMODE":2},
              "constantshadervalues":{"color":"1 0 0","alpha":1}}]}],
            "visible":{"value":true}}]}
        """
        let dir = Self.scratchDir("fbnobg")
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("models/util/fullscreenlayer.json", #"{"material":"materials/util/fullscreenlayer.json","fullscreen":true,"passthrough":true}"#.data(using: .utf8)!),
            ("materials/util/fullscreenlayer.json", #"{"passes":[{"shader":"passthrough","textures":["_rt_FullFrameBuffer"]}]}"#.data(using: .utf8)!),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "fbnobg", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "fbnobg", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = Self.scratchDir("fbnobg_out")
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let c = try XCTUnwrap(rep.colorAt(x: 32, y: 18))
        NSLog("%@", "[Waple] fb copybackground:false px=(\(c.redComponent),\(c.greenComponent),\(c.blueComponent))")
        XCTAssertGreaterThan(c.greenComponent, 0.8, "copybackground:false 면 컴포지션 레이어가 화면을 뒤덮지 않고 흰 배경이 남아야")
        XCTAssertGreaterThan(c.blueComponent, 0.8, "위와 동일 근거 — 미수정이면 순수 빨강(green/blue 낮음)으로 워시")
    }

    /// P⑤: isFrameBuffer(_rt_) + colorBlendMode 동시 저작 레이어(코퍼스 13씬 실측) — 종전엔
    /// encodeDrawPlan 이 isFrameBuffer 를 colorBlendMode 보다 먼저 매치해 저작 블렌드 모드가 통째로
    /// 무시되고 f_compose(그냥 tint 결과 통과)로만 그려졌다. 흰 배경 + 컴포지션 레이어(tint 효과로
    /// srcTex 를 빨강으로 변환) + colorBlendMode=difference(18): 미수정이면 화면이 그냥 빨강(효과
    /// 결과 그대로), 수정되면 difference(흰 배경, 빨강) = 시안이어야 한다.
    func testFrameBufferLayerAppliesColorBlendModeAgainstBackdrop() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/util/fullscreenlayer.json","origin":"960 540 0","size":"1920 1080",
            "colorBlendMode":18,
            "effects":[{"file":"effects/tint/effect.json","passes":[{"combos":{"BLENDMODE":2},
              "constantshadervalues":{"color":"1 0 0","alpha":1}}]}],
            "visible":{"value":true}}]}
        """
        let dir = Self.scratchDir("fbblend")
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("models/util/fullscreenlayer.json", #"{"material":"materials/util/fullscreenlayer.json","fullscreen":true,"passthrough":true}"#.data(using: .utf8)!),
            ("materials/util/fullscreenlayer.json", #"{"passes":[{"shader":"passthrough","textures":["_rt_FullFrameBuffer"]}]}"#.data(using: .utf8)!),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "fbblend", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "fbblend", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = Self.scratchDir("fbblend_out")
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let c = try XCTUnwrap(rep.colorAt(x: 32, y: 18))
        NSLog("%@", "[Waple] fb+colorBlendMode px=(\(c.redComponent),\(c.greenComponent),\(c.blueComponent))")
        XCTAssertLessThan(c.redComponent, 0.3, "difference(흰,빨강)=시안 이어야(빨강 채널 낮음) — 미수정이면 순수 빨강으로 남음")
        XCTAssertGreaterThan(c.greenComponent, 0.7, "difference(흰,빨강)=시안(초록 채널 높음)")
        XCTAssertGreaterThan(c.blueComponent, 0.7, "difference(흰,빨강)=시안(파랑 채널 높음)")
    }

    /// 컴포지션 방향 보존: 상단 절반만 빨간 씬 + passthrough 컴포지션 → 빨강은 상단에 남아야(Y-플립 회귀 방지).
    func testFrameBufferPreservesOrientation() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0.2"},
         "objects":[
           {"id":1,"image":"models/w.json","origin":"960 810 0","size":"1920 540"},
           {"id":2,"image":"models/util/fullscreenlayer.json","origin":"960 540 0","size":"1920 1080",
            "effects":[{"file":"effects/tint/effect.json","passes":[{"combos":{"BLENDMODE":2},
              "constantshadervalues":{"color":"1 0 0","alpha":1}}]}],
            "visible":{"value":true}}]}
        """
        let dir = Self.scratchDir("fbflip")
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
        let out = Self.scratchDir("fbflip_out")
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
        let dir = Self.scratchDir("fbpartial")
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
        let out = Self.scratchDir("fbpartial_out")
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
        let dir = Self.scratchDir("animA")
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
        let out = Self.scratchDir("animA_out")
        let urls = r.captureFrames(width: 64, height: 36, times: [0.0, 1.0, 2.0], toDir: out)
        XCTAssertEqual(urls.count, 3)
        // captureFrames 는 times 오름차순으로 반환(재정렬 불필요 — 파일명 사전순은 t≥10 에서 깨진다).
        let lumas = urls.map { avgLuma($0) }
        // 순서: t0.0, t1.0, t2.0
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
        let dir = Self.scratchDir("animO")
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
        let out = Self.scratchDir("animO_out")
        // captureFrames 는 times 오름차순으로 반환(재정렬 불필요 — 파일명 사전순은 t≥10 에서 깨진다).
        let urls = r.captureFrames(width: 64, height: 36, times: [0.0, 2.0], toDir: out)
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
        let dir = Self.scratchDir("text")
        try encodePkg([("scene.json", scene.data(using: .utf8)!)]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "text", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "text", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 72)), project: project)
        defer { r.teardown() }
        let out = Self.scratchDir("text_out")
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

    /// 캡처 fit/fill 종횡비 규약. **두 모드를 한 테스트에서 순차로 본다.**
    ///
    /// 종전엔 `testCaptureFramesUsesFitAspectScale` / `…FillAspectScale` 두 개였고, 각각
    /// `SceneRenderSettings.fitMode` 를 자기 값으로 바꾼 뒤 defer 로 되돌렸다. `fitMode` 는
    /// **프로세스 전역**이라 두 테스트가 같은 프로세스에서 동시에 돌면 서로의 모드를 덮는다 —
    /// 2026-08-19 CI 실측(run 32245…, `--parallel --num-workers 6`, 3회): 1회차는 fit 이,
    /// 2회차는 fill 이, 3회차는 다시 fit 이 실패했다. **어느 쪽이 지는지가 매번 달라지는 것**이
    /// 경합의 서명이다.
    ///
    /// 순차 실행에서는 둘 다 통과했으므로 종전 코드가 "틀린" 것은 아니었다 — 병렬에서
    /// 판정 불가였을 뿐이다. 그래서 `AGENTS.md` 가 오래 "`--parallel` 은 판정에 쓰지 마라" 로
    /// 남아 있었다. 하나로 합치면 그 제약 없이 두 모드를 다 검사한다.
    ///
    /// 전역을 끄는 더 깊은 수정(캡처 인자로 모드 주입)은 프로덕션 API 변경이라 하지 않았다 —
    /// 이 테스트가 유일한 소비자가 아니다(`SceneRenderSettingsTests` 가 왕복을 따로 검사한다).
    func testCaptureFramesUsesFitAndFillAspectScale() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let oldMode = SceneRenderSettings.fitMode
        defer { SceneRenderSettings.fitMode = oldMode }

        // ── fit: 16:9 씬을 정사각 캡처에 넣으면 위아래가 레터박스여야 한다.
        SceneRenderSettings.fitMode = .fit
        let fitScene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"}]}
        """
        let fitDir = Self.scratchDir("capturefit")
        try encodePkg([
            ("scene.json", fitScene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
        ]).write(to: fitDir.appendingPathComponent("scene.pkg"))
        let fitProject = WallpaperProject(id: "capturefit", type: .scene, fileName: "scene.pkg", previewName: nil,
                                          title: "capturefit", tags: [], contentRating: nil, workshopId: nil,
                                          dependency: nil, folderURL: fitDir)
        do {
            let r = SceneRenderer()
            try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: fitProject)
            defer { r.teardown() }
            let url = try XCTUnwrap(r.captureFrames(width: 64, height: 64, times: [0.1],
                                                    toDir: Self.scratchDir("capturefit_out")).first)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
            XCTAssertLessThan(try XCTUnwrap(rep.colorAt(x: 32, y: 2)).redComponent, 0.1,
                              "fit should letterbox a 16:9 scene in a square capture")
            XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x: 32, y: 32)).redComponent, 0.9,
                                 "fit content center remains visible")
        }

        // ── fill: 같은 정사각 캡처에서 좌측 끝 스트라이프가 잘려 나가야 한다.
        SceneRenderSettings.fitMode = .fill
        let fillScene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/red.json","origin":"120 540 0","size":"240 1080"}]}
        """
        let fillDir = Self.scratchDir("capturefill")
        try encodePkg([
            ("scene.json", fillScene.data(using: .utf8)!),
            ("models/red.json", #"{"material":"materials/red.json"}"#.data(using: .utf8)!),
            ("materials/red.json", #"{"passes":[{"textures":["red"]}]}"#.data(using: .utf8)!),
            ("materials/red.tex", solidTex(255, 0, 0)),
        ]).write(to: fillDir.appendingPathComponent("scene.pkg"))
        let fillProject = WallpaperProject(id: "capturefill", type: .scene, fileName: "scene.pkg", previewName: nil,
                                           title: "capturefill", tags: [], contentRating: nil, workshopId: nil,
                                           dependency: nil, folderURL: fillDir)
        do {
            let r = SceneRenderer()
            try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: fillProject)
            defer { r.teardown() }
            let url = try XCTUnwrap(r.captureFrames(width: 64, height: 64, times: [0.1],
                                                    toDir: Self.scratchDir("capturefill_out")).first)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
            XCTAssertLessThan(try XCTUnwrap(rep.colorAt(x: 2, y: 32)).redComponent, 0.1,
                              "fill should crop the far-left scene stripe in a square capture")
        }
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

    /// DIRECTDRAW 패스는 straight-alpha 규약의 **예외**다 — albedo=0 에서 시작해
    /// ApplyBlending(31,·)=A+B·opacity 로 색×커버리지(=premultiplied)를 직접 낸다. 합성서가 규약대로
    /// 알파를 한 번 더 곱하면 기여분이 제곱돼(실물 lightshafts 는 fx≤0.0314 → fx²<1/255) 8비트에서
    /// 통째로 소멸한다. 여기서는 그 제곱을 판별 가능한 크기로 재현한다: 이펙트가 rgb=0.5·a=0.5 를
    /// 내면 검정 위 결과는 premultiplied 규약에서 0.5, 이중 곱이면 0.25 다.
    func testDirectDrawEffectOutputIsNotPremultipliedTwice() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        // lightshafts 와 같은 구조: DIRECTDRAW 면 g_Texture0 을 읽지 않고 0 에서 가산(BLENDMODE 31).
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
        #if DIRECTDRAW
            vec4 albedo = vec4(0.0, 0.0, 0.0, 0.0);
            albedo.rgb = albedo.rgb + vec3(1.0, 1.0, 1.0) * 0.5;
            albedo.a = max(albedo.a, 0.5);
        #else
            vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
        #endif
            gl_FragColor = albedo;
        }
        """
        // 이미지 없는 shape:quad — 코퍼스 DIRECTDRAW 41건 전부가 이 형태다.
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"shape":"quad","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/ddpremul/effect.json","passes":[{"combos":{"DIRECTDRAW":1}}]}]}]}
        """
        let luma = try renderLuma(scene: scene, extraFiles: [
            ("shaders/effects/ddpremul.vert", vert.data(using: .utf8)!),
            ("shaders/effects/ddpremul.frag", frag.data(using: .utf8)!),
        ], tag: "ddpremul")
        NSLog("%@", "[Waple] DIRECTDRAW premultiplied luma=\(luma)")
        XCTAssertEqual(luma, 0.5, accuracy: 0.05, "DIRECTDRAW 출력은 이미 premultiplied — 이중 곱이면 0.25")
    }

    /// 위 판별의 반대편: DIRECTDRAW 콤보가 없으면 종전 straight 규약 그대로여야 한다(무회귀).
    /// g_Texture0 통과 이펙트 + alpha 0.5 텍스처 → 0.5(합성서가 이중 곱을 하면 0.25).
    func testNonDirectDrawEffectKeepsStraightAlphaConvention() throws {
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
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080",
           "effects":[{"file":"effects/ddpass/effect.json","passes":[{}]}]}]}
        """
        let luma = try renderLuma(scene: scene, texAlpha: 128, extraFiles: [
            ("shaders/effects/ddpass.vert", vert.data(using: .utf8)!),
            ("shaders/effects/ddpass.frag", frag.data(using: .utf8)!),
        ], tag: "ddpass")
        NSLog("%@", "[Waple] non-DIRECTDRAW passthrough luma=\(luma)")
        XCTAssertEqual(luma, 0.5, accuracy: 0.05, "비-DIRECTDRAW 체인은 straight-alpha 규약 유지")
    }
}
