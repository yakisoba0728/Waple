import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// C8 잔여 갭 해소의 **렌더 측** 오라클 — 파스가 `hiddenByAncestor` 를 세워도 인코더가 그걸 안 보면
/// 아무 것도 달라지지 않는다(이 리포에서 안전망이 조용히 무력했던 사건과 같은 형태). 그래서 파스
/// 단언(SceneComboVisibleTests)과 **별개로** 실제 픽셀로 고정한다.
///
/// 무엇을 고정하는가
///  ① 비가시 조상 아래의 **스크립트-visible** 자식은 스크립트가 true 를 반환해도 안 그려진다.
///     종전 규약(initialVisible 시드)으로는 `evaluateBool(current:) ?? cur` 가 시드를 덮어써 못 막았다.
///  ② 대조군: 조상이 켜져 있으면 같은 자식이 그대로 그려진다(무회귀).
///  ③ 게이트는 **스크립트를 평가한 뒤** 드로우만 스킵한다 — 숨은 레이어의 컨트롤러가 세운 shared
///     사이드이펙트를 뒤 순서의 레이어가 그대로 소비한다(F219 가 스크립트 레이어를 살려 둔 이유 보존).
final class AncestorVisibilityGateRenderTests: XCTestCase {

    private func render(objects: String, tag: String) throws -> NSColor {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[\(objects)]}
        """
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/bg.json", Data(#"{"material":"materials/bg.json"}"#.utf8)),
            ("materials/bg.json", Data(#"{"passes":[{"textures":["bg"]}]}"#.utf8)),
            ("materials/bg.tex", solidTex(0, 255, 0)),
            ("models/fg.json", Data(#"{"material":"materials/fg.json"}"#.utf8)),
            ("materials/fg.json", Data(#"{"passes":[{"textures":["fg"]}]}"#.utf8)),
            ("materials/fg.tex", solidTex(255, 0, 0)),
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_ancestor_gate_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: "ancestor-gate-\(tag)", type: .scene, fileName: "scene.pkg", previewName: nil,
            title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir
        )
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { renderer.teardown() }
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_ancestor_gate_out_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        return try XCTUnwrap(rep.colorAt(x: 32, y: 18))
    }

    /// 초록 bg 위에 빨강 fg. fg 가 그려지면 중앙이 빨강, 가려지면 초록.
    private func bgOverlaidBy(groupVisible: Bool) -> String {
        """
        {"id":1,"name":"group","visible":\(groupVisible)},
        {"id":2,"name":"bg","image":"models/bg.json","origin":"960 540 0","size":"1920 1080"},
        {"id":3,"name":"fg","image":"models/fg.json","origin":"960 540 0","size":"1920 1080","parent":1,
         "visible":{"value":true,"script":"export function update(v){ return true; }"}}
        """
    }

    /// ① 비가시 조상 + true 를 반환하는 자기 visible 스크립트 → 그려지면 안 된다.
    func testScriptVisibleChildUnderInvisibleAncestorIsNotDrawn() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let color = try render(objects: bgOverlaidBy(groupVisible: false), tag: "hidden")
        XCTAssertLessThan(color.redComponent, 0.2,
                          "비가시 조상 아래 자식이 그려졌다 — 스크립트 반환값이 조상 AND 를 이겼다")
        XCTAssertGreaterThan(color.greenComponent, 0.8, "배경(초록)이 보여야")
    }

    /// ② 대조군: 조상이 가시면 같은 자식이 그대로 빨강으로 그려진다(무회귀).
    func testScriptVisibleChildUnderVisibleAncestorIsDrawn() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let color = try render(objects: bgOverlaidBy(groupVisible: true), tag: "shown")
        XCTAssertGreaterThan(color.redComponent, 0.8, "가시 조상의 자식은 그대로 그려져야")
        XCTAssertLessThan(color.greenComponent, 0.2)
    }

    /// ③ 게이트는 드로우만 막고 스크립트는 계속 평가한다. 숨은 fg 를 **먼저** 두고(objects 순서 =
    /// 인코드 순서) 그 visible 스크립트가 `shared.gateProbe` 를 세우면, 뒤 순서의 가시 bg 가 alpha
    /// 스크립트로 그걸 읽어 0.25 로 흐려진다(검은 clearcolor 위 premult-over → 초록 0.25).
    /// 게이트를 평가 **이전**에 걸었다면 fg 스크립트가 아예 안 돌아 bg 가 알파 1(초록 1.0)로 남는다.
    /// 이 배선이 결함이 아니라 픽스처 문제로 죽는 것을 가르려고 대조군(조상 가시)을 같이 잰다.
    func testHiddenChildStillRunsItsScriptForSharedSideEffects() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let objects = """
        {"id":1,"name":"group","visible":false},
        {"id":3,"name":"fg","image":"models/fg.json","origin":"960 540 0","size":"1920 1080","parent":1,
         "visible":{"value":true,"script":"export function update(v){ shared.gateProbe = 1; return true; }"}},
        {"id":2,"name":"bg","image":"models/bg.json","origin":"960 540 0","size":"1920 1080",
         "alpha":{"value":1,"script":"export function update(a){ return shared.gateProbe === 1 ? 0.25 : 1.0; }"}}
        """
        let control = try render(objects: objects.replacingOccurrences(of: "\"visible\":false",
                                                                       with: "\"visible\":true"),
                                 tag: "sideeffect-control")
        XCTAssertEqual(control.greenComponent, 0.25, accuracy: 0.08,
                       "픽스처 자체 확인 — 조상이 가시일 때 shared 소비가 동작해야(여기가 깨지면 픽스처 문제)")
        let color = try render(objects: objects, tag: "sideeffect")
        XCTAssertEqual(color.greenComponent, 0.25, accuracy: 0.08,
                       "숨은 자식의 스크립트가 안 돌았다 — 게이트가 스크립트 평가 이전에 잘랐다")
    }
}
