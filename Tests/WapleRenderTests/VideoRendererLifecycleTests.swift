import XCTest
import AVFoundation
@testable import WapleCore
@testable import WapleRender

/// [2026-08-25]  —  가  가 되면서 필요해졌다.
/// 그 타입은 원래부터 "상태가 메인 큐 한정"(파일 머리말)이었고 이제 타입이 그걸 말한다.
@MainActor
final class VideoRendererLifecycleTests: XCTestCase {
    func testMountingAgainReplacesExistingPlayerLayer() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeTinyMP4(at: dir.appendingPathComponent("one.mp4"))
        try makeTinyMP4(at: dir.appendingPathComponent("two.mp4"))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let renderer = VideoRenderer()
        try renderer.mount(in: container, project: project(id: "one", fileName: "one.mp4", dir: dir))
        let firstLayers = playerLayers(in: container)
        XCTAssertEqual(firstLayers.count, 1)

        try renderer.mount(in: container, project: project(id: "two", fileName: "two.mp4", dir: dir))
        let secondLayers = playerLayers(in: container)

        XCTAssertEqual(secondLayers.count, 1, "remount should remove the old AVPlayerLayer before adding a new one")
        XCTAssertFalse(secondLayers[0] === firstLayers[0], "remount should install a fresh layer for the new player")
        XCTAssertEqual(renderer.projectId, "two")
        renderer.teardown()
    }

    func testStaleConversionCompletionAfterRemountIsIgnored() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0x01]).write(to: dir.appendingPathComponent("old.webm"))
        try makeTinyMP4(at: dir.appendingPathComponent("old-converted.mp4"))
        try makeTinyMP4(at: dir.appendingPathComponent("current.mp4"))

        var staleCompletion: ((URL?) -> Void)?
        let renderer = VideoRenderer(
            converterAvailable: { true },
            convert: { _, completion in staleCompletion = completion })
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))

        try renderer.mount(in: container, project: project(id: "old", fileName: "old.webm", dir: dir))
        XCTAssertNotNil(staleCompletion)
        try renderer.mount(in: container, project: project(id: "current", fileName: "current.mp4", dir: dir))
        let currentPlayer = try XCTUnwrap(renderer.player)

        staleCompletion?(dir.appendingPathComponent("old-converted.mp4"))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertTrue(renderer.player === currentPlayer, "late conversion from an older mount must not replace the current player")
        XCTAssertEqual(renderer.projectId, "current")
        XCTAssertEqual(playerLayers(in: container).count, 1)
        renderer.teardown()
    }

    func testPauseDuringConversionKeepsConvertedPlayerPaused() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0x01]).write(to: dir.appendingPathComponent("movie.webm"))
        try makeTinyMP4(at: dir.appendingPathComponent("movie.mp4"))

        var completion: ((URL?) -> Void)?
        let renderer = VideoRenderer(
            converterAvailable: { true },
            convert: { _, callback in completion = callback })
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))

        try renderer.mount(in: container, project: project(id: "movie", fileName: "movie.webm", dir: dir))
        renderer.pause()
        completion?(dir.appendingPathComponent("movie.mp4"))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let player = try XCTUnwrap(renderer.player)
        XCTAssertEqual(player.timeControlStatus, .paused, "a pause requested while conversion is pending must survive attach")
        renderer.teardown()
    }

    func testCommonNonNativeContainersStartConversionInsteadOfNativePlayer() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        for ext in ["webm", "mkv", "avi", "wmv", "flv", "ogv", "mpg"] {
            let fileName = "movie.\(ext)"
            let source = dir.appendingPathComponent(fileName)
            try Data([0x01]).write(to: source)
            var requestedConversion: URL?
            let renderer = VideoRenderer(
                converterAvailable: { true },
                convert: { url, _ in requestedConversion = url })
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))

            try renderer.mount(in: container, project: project(id: ext, fileName: fileName, dir: dir))

            XCTAssertEqual(requestedConversion, source, "\(ext) should enter the ffmpeg conversion path")
            XCTAssertNil(renderer.player, "\(ext) should not attach AVFoundation before conversion completes")
            XCTAssertTrue(playerLayers(in: container).isEmpty)
            renderer.teardown()
        }
    }

    func testConversionFailureIsRecordedAndDoesNotAttachLayer() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0x01]).write(to: dir.appendingPathComponent("broken.webm"))

        var completion: ((URL?) -> Void)?
        let renderer = VideoRenderer(
            converterAvailable: { true },
            convert: { _, callback in completion = callback })
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))

        try renderer.mount(in: container, project: project(id: "broken", fileName: "broken.webm", dir: dir))
        completion?(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(renderer.lastError as? RendererError, .unsupportedCodec)
        XCTAssertNil(renderer.player)
        XCTAssertTrue(playerLayers(in: container).isEmpty)
        renderer.teardown()
    }

    func testNativePlayerItemFailureIsRecorded() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0x00, 0x01, 0x02]).write(to: dir.appendingPathComponent("broken.mp4"))

        let renderer = VideoRenderer()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        try renderer.mount(in: container, project: project(id: "broken-native", fileName: "broken.mp4", dir: dir))

        let deadline = Date(timeIntervalSinceNow: 5)
        while renderer.lastError == nil && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        XCTAssertNotNil(renderer.lastError, "async AVPlayerItem failures must be exposed through lastError")
        renderer.teardown()
    }

    func testNativePlayerItemFailureAttemptsFfmpegRecovery() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("broken.mp4")
        try Data([0x00, 0x01, 0x02]).write(to: source)

        var requestedConversion: URL?
        let renderer = VideoRenderer(
            converterAvailable: { true },
            convert: { url, _ in requestedConversion = url })
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        try renderer.mount(in: container, project: project(id: "broken-native-recover", fileName: "broken.mp4", dir: dir))

        let deadline = Date(timeIntervalSinceNow: 5)
        while requestedConversion == nil && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        XCTAssertEqual(requestedConversion, source)
        renderer.teardown()
    }

    private func playerLayers(in view: NSView) -> [AVPlayerLayer] {
        view.layer?.sublayers?.compactMap { $0 as? AVPlayerLayer } ?? []
    }
}
