import XCTest
import AVFoundation
@testable import WapleCore
@testable import WapleRender

/// F820: 음량/배속 라이브 반영 — apply() 전체 리마운트 없이 실행 중인 AVPlayer 에 직접 반영돼야 한다.
final class VideoLiveSettingsTests: XCTestCase {
    private let projectId = "vlive1"
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        VideoSettings.reset(id: projectId)   // UserDefaults 공유 — 테스트 간 격리
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waple_vlive_\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        VideoSettings.reset(id: projectId)
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    /// 마운트 후 설정 변경 → applyLiveVideoSettings() 가 같은 플레이어에 즉시 반영(리마운트 아님).
    func testLiveVolumeAndRateAppliedWithoutRemount() throws {
        let r = try mountedRenderer()
        let p = try XCTUnwrap(r.player)
        XCTAssertEqual(p.volume, 0, "마운트 시 기본 음소거")
        XCTAssertTrue(p.isMuted)
        XCTAssertEqual(p.defaultRate, 1, accuracy: 0.001)

        VideoSettings.setVolume(0.6, id: projectId)
        VideoSettings.setRate(1.5, id: projectId)
        r.applyLiveVideoSettings()

        XCTAssertTrue(r.player === p, "리마운트 없이 같은 플레이어 인스턴스여야 한다")
        XCTAssertEqual(p.volume, 0.6, accuracy: 0.001, "라이브 음량 반영")
        XCTAssertFalse(p.isMuted, "음량>0 이면 음소거 해제")
        XCTAssertEqual(p.defaultRate, 1.5, accuracy: 0.001, "라이브 배속 반영(defaultRate)")
    }

    /// 라이브로 음량을 0 으로 되돌리면 다시 음소거.
    func testLiveVolumeZeroMutes() throws {
        let r = try mountedRenderer()
        VideoSettings.setVolume(0.8, id: projectId)
        r.applyLiveVideoSettings()
        let p = try XCTUnwrap(r.player)
        XCTAssertFalse(p.isMuted)

        VideoSettings.setVolume(0, id: projectId)
        r.applyLiveVideoSettings()
        XCTAssertTrue(p.isMuted, "라이브 음량 0 = 음소거")
        XCTAssertEqual(p.volume, 0, accuracy: 0.001)
    }

    /// 마운트 전(플레이어 없음) 호출은 no-op — 크래시 없이 무시.
    func testLiveSettingsWithoutPlayerIsNoOp() {
        let r = VideoRenderer()
        r.applyLiveVideoSettings()
        XCTAssertNil(r.player)
        XCTAssertNil(r.lastError)
    }

    /// 라이브 반영 후 새 설정은 그대로 저장돼 있어, 이후 재마운트도 새 값을 읽는다(저장 경로 무회귀).
    func testLiveSettingsPersistForNextMount() throws {
        let r = try mountedRenderer()
        VideoSettings.setVolume(0.4, id: projectId)
        VideoSettings.setRate(2.0, id: projectId)
        r.applyLiveVideoSettings()
        r.teardown()

        let r2 = try mountedRenderer()
        let p2 = try XCTUnwrap(r2.player)
        XCTAssertEqual(p2.volume, 0.4, accuracy: 0.001)
        XCTAssertEqual(p2.defaultRate, 2.0, accuracy: 0.001)
        r2.teardown()
    }

    private func mountedRenderer() throws -> VideoRenderer {
        let mp4 = tempDir.appendingPathComponent("t.mp4")
        try makeTinyMP4(at: mp4)
        let project = WallpaperProject(id: projectId, type: .video, fileName: "t.mp4", previewName: nil,
                                       title: "t", tags: [], contentRating: nil, workshopId: nil,
                                       dependency: nil, folderURL: tempDir)
        let r = VideoRenderer()
        try r.mount(in: NSView(frame: .zero), project: project)
        addTeardownBlock { r.teardown() }
        return r
    }
}
