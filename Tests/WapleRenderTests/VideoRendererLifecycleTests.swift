import XCTest
import AVFoundation
@testable import WapleCore
@testable import WapleRender

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

    private func project(id: String, fileName: String, dir: URL) -> WallpaperProject {
        WallpaperProject(id: id, type: .video, fileName: fileName, previewName: nil,
                         title: id, tags: [], contentRating: nil, workshopId: nil,
                         dependency: nil, folderURL: dir)
    }

    private func playerLayers(in view: NSView) -> [AVPlayerLayer] {
        view.layer?.sublayers?.compactMap { $0 as? AVPlayerLayer } ?? []
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTinyMP4(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<4 {
            while !input.isReadyForMoreMediaData {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
    }
}
