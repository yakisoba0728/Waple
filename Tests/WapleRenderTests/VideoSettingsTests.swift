import XCTest
import AVFoundation
@testable import WapleCore
@testable import WapleRender

final class VideoSettingsTests: XCTestCase {
    override func tearDown() {
        VideoSettings.reset(id: "vtest1")
        super.tearDown()
    }

    func testDefaultsAndPersistence() {
        XCTAssertEqual(VideoSettings.volume(id: "vtest1"), 0, "기본 음소거(보수적)")
        XCTAssertEqual(VideoSettings.rate(id: "vtest1"), 1, "기본 1배속")
        VideoSettings.setVolume(0.75, id: "vtest1")
        VideoSettings.setRate(1.5, id: "vtest1")
        XCTAssertEqual(VideoSettings.volume(id: "vtest1"), 0.75)
        XCTAssertEqual(VideoSettings.rate(id: "vtest1"), 1.5)
        XCTAssertEqual(VideoSettings.volume(id: "other"), 0, "배경별 독립")
    }

    /// mount 시 설정이 player 에 반영돼야 한다(volume/muted/defaultRate).
    func testRendererAppliesSettings() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_vset", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mp4 = dir.appendingPathComponent("t.mp4")
        try makeTinyMP4(at: mp4)
        VideoSettings.setVolume(0.5, id: "vtest1")
        VideoSettings.setRate(2.0, id: "vtest1")
        let project = WallpaperProject(id: "vtest1", type: .video, fileName: "t.mp4", previewName: nil,
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
