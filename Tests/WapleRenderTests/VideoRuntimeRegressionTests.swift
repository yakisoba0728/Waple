import XCTest
import AppKit
import AVFoundation
import Metal
@testable import WapleCore
@testable import WapleRender

@MainActor
final class VideoRuntimeRegressionTests: XCTestCase {
    private func fixture() throws -> (URL, WallpaperProject) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("waple-video-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try makeTinyMP4(at: directory.appendingPathComponent("video.mp4"))
        return (directory, WallpaperProject(id: UUID().uuidString, type: .video, fileName: "video.mp4",
            previewName: nil, title: "runtime", tags: [], contentRating: nil,
            workshopId: nil, dependency: nil, folderURL: directory))
    }

    func testNaturalPlaybackCyclePublishesActiveRendererAndProject() throws {
        let (directory, project) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = VideoRenderer()
        let ended = expectation(description: "real local video completed a cycle")
        var identities: [Bool] = []
        let observer = NotificationCenter.default.addObserver(forName: VideoRenderer.playbackCycleEndedNotification,
            object: renderer, queue: .main) { notification in
                identities.append((notification.object as? VideoRenderer) === renderer
                    && notification.userInfo?["projectId"] as? String == project.id)
                ended.fulfill()
            }
        defer { NotificationCenter.default.removeObserver(observer); renderer.teardown() }
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        wait(for: [ended], timeout: 5)
        renderer.teardown()
        XCTAssertFalse(identities.isEmpty)
        XCTAssertTrue(identities.allSatisfy { $0 })
    }

    func testPauseRampFadesBeforePhysicalPauseAndResumeRestoresIntent() throws {
        let (directory, project) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory); VideoSettings.reset(id: project.id) }
        VideoSettings.setVolume(1, id: project.id)
        let renderer = VideoRenderer()
        defer { renderer.teardown() }
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        let player = try XCTUnwrap(renderer.player)
        renderer.pause()
        XCTAssertEqual(player.volume, 1)
        for _ in 0..<19 { renderer.applyVolumeRampStep() }
        XCTAssertGreaterThan(player.volume, 0)
        for _ in 0..<2 { renderer.applyVolumeRampStep() }
        XCTAssertEqual(player.volume, 0)
        XCTAssertEqual(player.rate, 0)
        renderer.resume()
        renderer.applyVolumeRampStep()
        XCTAssertGreaterThan(player.volume, 0)
        XCTAssertEqual(VideoSettings.volume(id: project.id), 1, "ramp never overwrites authored volume")
        renderer.setAudioOutputEnabled(false)
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.volume, 0)
        XCTAssertFalse(renderer.isPlayingAudio)
    }

    func testNativeVideoRuntimeCommandsAffectTransportAndRejectInvalidValues() throws {
        let (directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = SceneVideoLayer(mp4URL: directory.appendingPathComponent("video.mp4"))
        defer { video.teardown() }
        XCTAssertTrue(video.applyRuntime(action: "pause", value: nil))
        XCTAssertEqual(video.runtimeSnapshot["playing"] as? Bool, false)
        XCTAssertTrue(video.applyRuntime(action: "setCurrentTime", value: 0.2))
        XCTAssertEqual(video.runtimeSnapshot["currentTime"] as? Double, 0.2)
        XCTAssertTrue(video.applyRuntime(action: "setLoop", value: false))
        XCTAssertEqual(video.runtimeSnapshot["loop"] as? Bool, false)
        XCTAssertFalse(video.applyRuntime(action: "setRate", value: Double.nan))
        XCTAssertTrue(video.applyRuntime(action: "stop", value: nil))
        XCTAssertEqual(video.runtimeSnapshot["currentTime"] as? Double, 0)
    }

    func testLiveSettingsDuringAStillRunningPauseFadeStopTransport() throws {
        let (directory, project) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory); VideoSettings.reset(id: project.id) }
        VideoSettings.setVolume(1, id: project.id)
        let renderer = VideoRenderer()
        defer { renderer.teardown() }
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        let player = try XCTUnwrap(renderer.player)
        let deadline = Date().addingTimeInterval(3)
        while player.rate == 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        renderer.pause()
        XCTAssertNotEqual(player.rate, 0)
        VideoSettings.setVolume(0.5, id: project.id)
        VideoSettings.setRate(1.5, id: project.id)
        renderer.applyLiveVideoSettings()
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(player.volume, 0)
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.defaultRate, 1.5)
        renderer.resume()
        XCTAssertEqual(player.rate, 1.5)
    }

    func testSceneVideoRateSetWhilePausedSurvivesResumeAndLoop() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let (directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = SceneVideoLayer(mp4URL: directory.appendingPathComponent("video.mp4"))
        defer { video.teardown() }
        video.startLive(device: device)
        let player = try XCTUnwrap(video.player)
        video.pause()
        XCTAssertTrue(video.applyRuntime(action: "setRate", value: 2))
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(player.defaultRate, 2)
        video.resume()
        XCTAssertEqual(player.rate, 2)
        let deadline = Date().addingTimeInterval(3)
        while video.runtimeSnapshot["endedGeneration"] as? UInt64 == 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThan(video.runtimeSnapshot["endedGeneration"] as? UInt64 ?? 0, 0)
        XCTAssertEqual(player.rate, 2)
    }

    func testHeadlessSceneVideoPublishesBoundedTimeAndSingleNonLoopingEnd() throws {
        let (directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = SceneVideoLayer(mp4URL: directory.appendingPathComponent("video.mp4"))
        XCTAssertTrue(video.applyRuntime(action: "loop", value: false))
        let initial = video.runtimeSnapshot(at: 0)
        let duration = try XCTUnwrap(initial["duration"] as? Double)
        XCTAssertGreaterThan(duration, 0)
        XCTAssertEqual(initial["playing"] as? Bool, true)
        let ended = video.runtimeSnapshot(at: Float(duration + 1))
        XCTAssertEqual(ended["currentTime"] as? Double, duration)
        XCTAssertEqual(ended["playing"] as? Bool, false)
        XCTAssertEqual(ended["endedGeneration"] as? UInt64, 1)
        let later = video.runtimeSnapshot(at: Float(duration + 2))
        XCTAssertEqual(later["currentTime"] as? Double, duration)
        XCTAssertEqual(later["endedGeneration"] as? UInt64, 1)
    }
}
