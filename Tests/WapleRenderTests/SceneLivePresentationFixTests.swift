import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 라이브 데스크탑 프레젠트 상하 뒤집힘 보정 게이트(macOS 26+)의 순수 판정 경계 고정.
final class SceneLivePresentationFixTests: XCTestCase {
    func testBelow26NoFlip() {
        XCTAssertFalse(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 14))
        XCTAssertFalse(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 15))
        XCTAssertFalse(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 25))
    }

    func test26AndAboveFlips() {
        XCTAssertTrue(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 26))
        XCTAssertTrue(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 27))
        XCTAssertTrue(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 30))
    }

    // MARK: - F4: WAPLE_LIVE_FLIP_FIX 환경변수 오버라이드(0/1/미설정)

    func testEnvOverrideZeroForcesNoFlipRegardlessOfVersion() {
        XCTAssertFalse(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 26, envOverride: "0"))
        XCTAssertFalse(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 30, envOverride: "0"))
    }

    func testEnvOverrideOneForcesFlipRegardlessOfVersion() {
        XCTAssertTrue(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 14, envOverride: "1"))
        XCTAssertTrue(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 25, envOverride: "1"))
    }

    func testEnvOverrideUnsetOrInvalidFallsBackToVersionGate() {
        XCTAssertFalse(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 25, envOverride: nil))
        XCTAssertTrue(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 26, envOverride: nil))
        // 미지원 값("2", "true" 등)도 안전하게 버전 판정으로 폴백(오분기 방지).
        XCTAssertFalse(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 25, envOverride: "true"))
        XCTAssertTrue(SceneLivePresentationFix.needsDesktopFlipY(majorVersion: 26, envOverride: "garbage"))
    }

    // MARK: - F4: isGeometryFlipped 멱등 재적용(창 부착 후 기대값 단언)

    private func minimalProject(id: String) throws -> WallpaperProject {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_f4_\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scene = #"{"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},"objects":[]}"#
        try encodePkg([("scene.json", scene.data(using: .utf8)!)]).write(to: dir.appendingPathComponent("scene.pkg"))
        try Data(#"{"type":"scene","title":"f4","file":"scene.pkg"}"#.utf8).write(to: dir.appendingPathComponent("project.json"))
        return try XCTUnwrap(try? ProjectJSONParser.parse(folderURL: dir))
    }

    /// mount 가 WapleMTKView 를 생성하는지, 그리고 창 부착(재부모화) 후 isGeometryFlipped 가
    /// SceneLivePresentationFix.needsDesktopFlipY 기대값과 일치하는지(멱등 재확인이 실제로 동작하는지)
    /// 직접 단언 — mount 직후 값을 고의로 반대로 뒤집어 "AppKit 이 되돌린" 상황을 시뮬레이션한다.
    func testGeometryFlippedReappliedOnWindowAttach() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let r = SceneRenderer()
        try r.mount(in: container, project: try minimalProject(id: "attach"))
        defer { r.teardown() }
        guard let view = r.mtkView as? WapleMTKView else {
            XCTFail("mtkView 가 WapleMTKView 서브클래스가 아님"); return
        }
        // 유실 시뮬레이션: AppKit 재동기화가 값을 반대로 되돌렸다고 가정.
        view.layer?.isGeometryFlipped = !SceneLivePresentationFix.needsDesktopFlipY
        // 창 부착(재부모화 트리거) → viewDidMoveToWindow 가 전 서브뷰에 전파돼 재확인해야 한다.
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                           styleMask: [], backing: .buffered, defer: false)
        win.contentView = container
        XCTAssertEqual(view.layer?.isGeometryFlipped, SceneLivePresentationFix.needsDesktopFlipY,
                       "F4: 창 부착 시 viewDidMoveToWindow 가 isGeometryFlipped 를 기대값으로 재확인해야 한다")
    }

    /// draw(in:) 진입부도 같은 방식으로 불일치를 재확인한다(뷰가 이미 창에 있는 상태에서의 방어선).
    func testGeometryFlippedReappliedOnDrawEntry() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                           styleMask: [], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        win.contentView = container
        let r = SceneRenderer()
        try r.mount(in: container, project: try minimalProject(id: "drawentry"))
        defer { r.teardown() }
        guard let view = r.mtkView else { XCTFail("no mtkView"); return }
        view.layer?.isGeometryFlipped = !SceneLivePresentationFix.needsDesktopFlipY
        r.draw(in: view)
        XCTAssertEqual(view.layer?.isGeometryFlipped, SceneLivePresentationFix.needsDesktopFlipY,
                       "F4: draw(in:) 진입부가 isGeometryFlipped 를 기대값으로 재확인해야 한다")
    }
}
