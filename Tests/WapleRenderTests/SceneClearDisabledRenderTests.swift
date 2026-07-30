import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// general.clearenabled=false 소비 배선 검증(2026-07-28): 렌더러가 누적(acc) 버퍼를 매 프레임 지우지
/// 않아 프레임 누적(잔상)이 엔진 동작으로 재현되는지 캡처 시퀀스(captureFrames — 첫 프레임 1회 클리어로
/// 정의된 시작, 이후 .load 누적)로 단언한다. 코퍼스는 전건 clearenabled=true(161/161)라 실물 픽스처
/// 대신 합성 씬(좌→우 이동 레이어, SceneCompositeConventionTests 의 애니 픽스처 형상 차용)으로 검증.
final class SceneClearDisabledRenderTests: XCTestCase {
    private func capture(scene: String, id: String, times: [Float]) throws -> [URL] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: id, tags: [], contentRating: nil, workshopId: nil,
                                       dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(id + "_out", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return r.captureFrames(width: 64, height: 36, times: times, toDir: out)
    }

    /// 좌→우 이동(2초 single)하는 흰 사각형 씬. t=0: scene x 0..480(캡처 0..16), t=2: 1440..1920(캡처 48..64).
    private func scene(clearEnabled: Bool) -> String {
        """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0",
          "clearenabled":\(clearEnabled)},
         "objects":[{"id":1,"image":"models/w.json","size":"480 1080",
            "origin":{"animation":{"c0":[{"frame":0,"value":240},{"frame":60,"value":1680}],
                                    "options":{"fps":30,"length":60,"mode":"single"}},
                      "value":"240 540 0"},
            "visible":{"value":true}}]}
        """
    }

    private func red(_ url: URL, _ x: Int) -> Double {
        guard let rep = NSBitmapImageRep(data: try! Data(contentsOf: url)),
              let c = rep.colorAt(x: x, y: 18) else { return -1 }
        return c.redComponent
    }

    /// clearenabled=false: 시퀀스 두 번째 프레임(t=2)에 첫 프레임 위치(x=8)의 잔상이 남아야 한다
    /// (acc 미클리어 누적 = 엔진 동작). 첫 프레임(t=0)은 정의된 상태(좌 잉크/우 검정)로 시작해야 한다.
    func testClearDisabledAccumulatesFrames() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let urls = try capture(scene: scene(clearEnabled: false), id: "waple_clearoff", times: [0.0, 2.0])
        XCTAssertEqual(urls.count, 2)
        XCTAssertGreaterThan(red(urls[0], 8), 0.8, "t=0: 좌측 흰색(정의된 시작)")
        XCTAssertLessThan(red(urls[0], 56), 0.3, "t=0: 우측 검정(정의된 시작)")
        XCTAssertGreaterThan(red(urls[1], 56), 0.8, "t=2: 레이어의 현재 위치(우측) 흰색")
        XCTAssertGreaterThan(red(urls[1], 8), 0.8, "t=2: clearenabled=false — t=0 위치 잔상이 남아야(미클리어 누적)")
    }

    /// 컨트롤: clearenabled=true(코퍼스 전건 형상)면 매 프레임 클리어 — t=2 에 t=0 위치는 검정.
    func testClearEnabledClearsEachFrame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let urls = try capture(scene: scene(clearEnabled: true), id: "waple_clearon", times: [0.0, 2.0])
        XCTAssertEqual(urls.count, 2)
        XCTAssertGreaterThan(red(urls[1], 56), 0.8, "t=2: 레이어의 현재 위치(우측) 흰색")
        XCTAssertLessThan(red(urls[1], 8), 0.3, "t=2: clearenabled=true — t=0 위치는 클리어되어 검정")
    }
}
