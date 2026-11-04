import XCTest
import AVFoundation
@testable import WapleCore
@testable import WapleRender

/// [2026-08-25] `@MainActor` — `VideoRenderer`/`RendererFactory` 가 `@MainActor` 가 되면서
/// 필요해졌다. 그 타입들은 원래부터 "상태가 메인 큐 한정"(파일 머리말)이었고 이제 타입이 그걸 말한다.
@MainActor
final class VideoSettingsTests: XCTestCase {
    private let id = "audit-video-settings-\(UUID().uuidString)"
    override func tearDown() {
        VideoSettings.reset(id: id)
        super.tearDown()
    }

    func testDefaultsAndPersistence() {
        XCTAssertEqual(VideoSettings.volume(id: id), 0, "기본 음소거(보수적)")
        XCTAssertEqual(VideoSettings.rate(id: id), 1, "기본 1배속")
        VideoSettings.setVolume(0.75, id: id)
        VideoSettings.setRate(1.5, id: id)
        XCTAssertEqual(VideoSettings.volume(id: id), 0.75)
        XCTAssertEqual(VideoSettings.rate(id: id), 1.5)
        XCTAssertEqual(VideoSettings.volume(id: id + "-other"), 0, "배경별 독립")
    }

    /// mount 시 설정이 player 에 반영돼야 한다(volume/muted/defaultRate).
    func testRendererAppliesSettings() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_vset_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp4 = dir.appendingPathComponent("t.mp4")
        try makeTinyMP4(at: mp4)
        VideoSettings.setVolume(0.5, id: id)
        VideoSettings.setRate(2.0, id: id)
        let project = WallpaperProject(id: id, type: .video, fileName: "t.mp4", previewName: nil,
                                       title: "t", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = VideoRenderer()
        try r.mount(in: NSView(frame: .zero), project: project)
        defer { r.teardown() }
        let p = try XCTUnwrap(r.player)
        XCTAssertEqual(p.volume, 0.5, accuracy: 0.001)
        XCTAssertFalse(p.isMuted, "음량>0 이면 음소거 해제")
        XCTAssertEqual(p.defaultRate, 2.0, accuracy: 0.001, "루프에도 유지되는 배속")
    }
}
