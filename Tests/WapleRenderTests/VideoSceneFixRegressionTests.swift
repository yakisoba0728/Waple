import XCTest
import AVFoundation
@testable import WapleCore
@testable import WapleRender

/// 비디오 그룹 씬 수정 회귀 테스트.
final class VideoSceneFixRegressionTests: XCTestCase {
    /// F600(S-1): hev1(hvcC 없는 HEVC) mp4 는 AVPlayerItem.status=.readyToPlay + 오디오 트랙 존재로
    /// 종전 실패 감지 2경로(.failed 관찰, tracks.isEmpty)를 모두 우회해 F550 ffmpeg 회복이 미발동했다
    /// (로드한 isPlayable 값을 _ 로 버린 게 직접 원인). 로드 헤더 검사로 재생 불가를 감지해 회복을
    /// 시도해야 한다. 코퍼스 실물 backgrounds/3448728208(hev1+aac): isPlayable=false, 트랙 2개,
    /// status=.readyToPlay 실측 — 아래 픽스처가 동일 특성을 재현한다.
    /// 또한 회복 진행 중 lastError 는 nil 이어야 한다(최종 실패 오인 방지 — RealVideosGroundTruthTests 가 폴).
    func testHev1WithoutHvcCTriggersFfmpegRecovery() throws {
        try XCTSkipUnless(FFmpegConverter.isAvailable, "ffmpeg not installed — cannot generate hev1 fixture")
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("hev1.mp4")
        try makeHev1MP4(at: source)

        var requestedConversion: URL?
        let renderer = VideoRenderer(
            converterAvailable: { true },
            convert: { url, _ in requestedConversion = url })
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        try renderer.mount(in: container, project: project(id: "hev1-no-hvcc", fileName: "hev1.mp4", dir: dir))

        let deadline = Date(timeIntervalSinceNow: 5)
        while requestedConversion == nil && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        XCTAssertEqual(requestedConversion, source,
                       "hev1(hvcC 없음) 소스는 재생 불가로 감지해 ffmpeg 회복을 시도해야 한다")
        XCTAssertNil(renderer.lastError, "회복 진행 중 lastError 는 nil 이어야 한다(최종 실패 아님)")
        renderer.teardown()
    }

    /// F600: 회복 불가(ffmpeg 부재)면 최종 실패 — lastError 기록 + F555 Notification 발행.
    func testHev1WithoutConverterRecordsTerminalFailure() throws {
        try XCTSkipUnless(FFmpegConverter.isAvailable, "ffmpeg not installed — cannot generate hev1 fixture")
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeHev1MP4(at: dir.appendingPathComponent("hev1.mp4"))

        let renderer = VideoRenderer(converterAvailable: { false }, convert: { _, _ in })
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let notified = expectation(forNotification: .wapleVideoPlaybackFailed, object: nil)
        try renderer.mount(in: container, project: project(id: "hev1-no-conv", fileName: "hev1.mp4", dir: dir))

        let deadline = Date(timeIntervalSinceNow: 5)
        while renderer.lastError == nil && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        XCTAssertEqual(renderer.lastError as? RendererError, .unsupportedCodec,
                       "회복 불가한 재생 불가 소스는 최종 실패로 기록돼야 한다")
        wait(for: [notified], timeout: 1)
        renderer.teardown()
    }

    /// F600: 회복(ffmpeg 변환) 자체가 실패하면 최종 실패 — lastError 기록 + F555 Notification 발행.
    func testHev1ConversionFailureRecordsTerminalFailure() throws {
        try XCTSkipUnless(FFmpegConverter.isAvailable, "ffmpeg not installed — cannot generate hev1 fixture")
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeHev1MP4(at: dir.appendingPathComponent("hev1.mp4"))

        var completion: ((URL?) -> Void)?
        let renderer = VideoRenderer(
            converterAvailable: { true },
            convert: { _, callback in completion = callback })
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let notified = expectation(forNotification: .wapleVideoPlaybackFailed, object: nil)
        try renderer.mount(in: container, project: project(id: "hev1-conv-fail", fileName: "hev1.mp4", dir: dir))

        let deadline = Date(timeIntervalSinceNow: 5)
        while completion == nil && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        completion?(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertEqual(renderer.lastError as? RendererError, .unsupportedCodec,
                       "회복 변환 실패는 최종 실패로 기록돼야 한다")
        wait(for: [notified], timeout: 1)
        renderer.teardown()
    }

    /// 대조군: 재생 가능한 h264 mp4 는 ffmpeg 회복을 시도하지 않아야 한다 — F600 오탐 방지.
    func testPlayableH264DoesNotTriggerFfmpegRecovery() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeTinyMP4(at: dir.appendingPathComponent("ok.mp4"))

        var requestedConversion: URL?
        let renderer = VideoRenderer(
            converterAvailable: { true },
            convert: { url, _ in requestedConversion = url })
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        try renderer.mount(in: container, project: project(id: "h264-ok", fileName: "ok.mp4", dir: dir))

        // 로드+판정 완료 여유를 두고 펌핑 — 재생 가능 소스는 끝까지 회복 미시도.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))

        XCTAssertNil(requestedConversion, "재생 가능한 h264 소스에 ffmpeg 회복을 시도하면 안 된다")
        XCTAssertNil(renderer.lastError)
        renderer.teardown()
    }

    /// hev1(hvcC 없는 HEVC)+aac mp4 생성 — 코퍼스 3448728208 과 동일 특성(상기 주석). libx265 부재 시 skip.
    private func makeHev1MP4(at url: URL) throws {
        let ff = FFmpegConverter.executableURL!
        let gen = Process(); gen.executableURL = ff
        gen.arguments = ["-y", "-loglevel", "error",
                         "-f", "lavfi", "-i", "testsrc=duration=1:size=64x64:rate=10",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                         "-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error",
                         "-tag:v", "hev1", "-c:a", "aac", url.path]
        gen.standardOutput = FileHandle.nullDevice; gen.standardError = FileHandle.nullDevice
        try gen.run(); gen.waitUntilExit()
        try XCTSkipUnless(gen.terminationStatus == 0, "ffmpeg hev1 fixture generation failed (libx265 missing?)")
    }
}
