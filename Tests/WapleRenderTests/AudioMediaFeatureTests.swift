import XCTest
import ScreenCaptureKit
@testable import WapleRender

@MainActor
final class AudioMediaFeatureTests: XCTestCase {
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        func read() -> Value { lock.lock(); defer { lock.unlock() }; return stored }
        func update(_ change: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; change(&stored) }
    }

    private final class Capture: AudioCaptureSubscribing {
        func add(_ provider: SystemAudioSpectrumProvider) {}
        func remove(_ provider: SystemAudioSpectrumProvider) {}
    }

    private final class Session: AudioCaptureSession, @unchecked Sendable {
        let stopped: XCTestExpectation
        init(stopped: XCTestExpectation) { self.stopped = stopped }
        func stop() async { stopped.fulfill() }
        func owns(_ stream: SCStream) -> Bool { false }
    }

    func testCaptureErrorDelegateIsExposedToObjectiveC() {
        let core = SharedAudioCaptureCore()
        XCTAssertTrue(core.responds(to: NSSelectorFromString("stream:didStopWithError:")),
                      "optional delegate callback must be discoverable by SCStream")
    }

    func testStarvedCaptureEmitsSilenceAtOneSecondAndDiscardsItsPartialWindow() {
        let clock = Box(10.0)
        let provider = SystemAudioSpectrumProvider(capture: Capture(), uptime: { clock.read() }, automaticWatchdog: false)
        var frames: [[Float]] = []
        provider.onFrame = { frames.append($0) }
        provider.start()
        defer { provider.stop() }
        let signal = (0..<1365).map { Float(sin(Double($0) * 0.2)) }
        provider.process(left: signal, right: signal, sampleRate: 48000)
        drainMainQueue()
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames[0].contains { $0 > 0 })
        provider.process(left: Array(signal.prefix(100)), right: Array(signal.prefix(100)), sampleRate: 48000)
        clock.update { $0 = 10.999 }
        provider.checkForStarvation()
        drainMainQueue()
        XCTAssertEqual(frames.count, 1)
        clock.update { $0 = 11 }
        provider.checkForStarvation()
        drainMainQueue()
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[1], [Float](repeating: 0, count: 128))
        provider.checkForStarvation()
        provider.process(left: Array(signal.prefix(1265)), right: Array(signal.prefix(1265)), sampleRate: 48000)
        drainMainQueue()
        XCTAssertEqual(frames.count, 2, "pre-timeout partial samples must not complete the new window")
    }

    func testQueuedSpectrumFromPreviousCaptureSessionCannotReachNewSession() {
        let provider = SystemAudioSpectrumProvider(capture: Capture(), automaticWatchdog: false)
        var frames = 0
        provider.onFrame = { _ in frames += 1 }
        provider.start()
        provider.process(left: [Float](repeating: 1, count: 1365), right: [Float](repeating: 1, count: 1365), sampleRate: 48000)
        provider.stop()
        provider.start()
        drainMainQueue()
        XCTAssertEqual(frames, 0)
        provider.stop()
    }

    func testCaptureFormatChangeDoesNotMixDifferentRateWindows() {
        let provider = SystemAudioSpectrumProvider(capture: Capture(), automaticWatchdog: false)
        var frames = 0
        provider.onFrame = { _ in frames += 1 }
        provider.start()
        defer { provider.stop() }
        provider.process(left: [Float](repeating: 1, count: 100), right: [Float](repeating: 1, count: 100), sampleRate: 48000)
        provider.process(left: [Float](repeating: 1, count: 1265), right: [Float](repeating: 1, count: 1265), sampleRate: 44100)
        drainMainQueue()
        XCTAssertEqual(frames, 0)
        provider.process(left: [Float](repeating: 1, count: 100), right: [Float](repeating: 1, count: 100), sampleRate: 44100)
        drainMainQueue()
        XCTAssertEqual(frames, 1)
    }

    func testTransientCaptureFailureRetriesAndSharesRecoveredSession() {
        let attempts = Box(0)
        let retry = Box<(@Sendable () -> Void)?>(nil)
        let scheduled = expectation(description: "retry scheduled")
        let recovered = expectation(description: "capture recovered")
        let stopped = expectation(description: "last subscriber stops session")
        let session = Session(stopped: stopped)
        let core = SharedAudioCaptureCore(starter: { _, _ in
            attempts.update { $0 += 1 }
            if attempts.read() == 1 { throw NSError(domain: "test.capture", code: 1) }
            recovered.fulfill()
            return session
        }, scheduleRetry: { delay, action in
            XCTAssertEqual(delay, 1)
            retry.update { $0 = action }
            scheduled.fulfill()
        })
        let a = SystemAudioSpectrumProvider(capture: core, automaticWatchdog: false)
        let b = SystemAudioSpectrumProvider(capture: core, automaticWatchdog: false)
        a.start(); b.start()
        wait(for: [scheduled], timeout: 3)
        retry.read()?()
        wait(for: [recovered], timeout: 3)
        a.stop(); b.stop()
        wait(for: [stopped], timeout: 3)
        XCTAssertEqual(attempts.read(), 2)
    }

    func testPermissionDenialStaysSilentUntilExplicitRetry() {
        let attempts = Box(0)
        let denied = expectation(description: "denied capture feeds silence")
        let recovered = expectation(description: "explicit retry recovers")
        let stopped = expectation(description: "stop recovered session")
        let session = Session(stopped: stopped)
        let core = SharedAudioCaptureCore(starter: { _, _ in
            attempts.update { $0 += 1 }
            if attempts.read() == 1 {
                throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
            }
            recovered.fulfill()
            return session
        }, scheduleRetry: { _, _ in XCTFail("user denial must never automatically retry") })
        let provider = SystemAudioSpectrumProvider(capture: core, automaticWatchdog: false)
        provider.onFrame = { frame in
            XCTAssertTrue(frame.allSatisfy { $0 == 0 })
            denied.fulfill()
        }
        provider.start()
        wait(for: [denied], timeout: 3)
        XCTAssertEqual(attempts.read(), 1)
        core.retry()
        wait(for: [recovered], timeout: 3)
        provider.stop()
        wait(for: [stopped], timeout: 3)
    }

    func testRuntimeFailureSchedulesRecoveryAndStaleSessionErrorIsIgnored() {
        let started = expectation(description: "session started")
        let stopped = expectation(description: "failed session stopped")
        let scheduled = expectation(description: "runtime retry")
        let session = Session(stopped: stopped)
        let retries = Box(0)
        let core = SharedAudioCaptureCore(starter: { _, _ in
            started.fulfill()
            return session
        }, scheduleRetry: { _, _ in retries.update { $0 += 1 }; scheduled.fulfill() })
        let provider = SystemAudioSpectrumProvider(capture: core, automaticWatchdog: false)
        provider.start()
        wait(for: [started], timeout: 3)
        let deadline = Date().addingTimeInterval(3)
        while !core.hasActiveSession, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(core.hasActiveSession)
        core.sessionFailed(session, error: NSError(domain: "test.capture", code: 2))
        wait(for: [scheduled, stopped], timeout: 3)
        core.sessionFailed(session, error: NSError(domain: "test.capture", code: 2))
        XCTAssertEqual(retries.read(), 1)
        provider.stop()
    }

    func testPausedSeekAndOptionalMetadataChangesReachMediaConsumers() {
        let poller = MediaPoller(provider: FixedProvider())
        var timeline: [Double] = []
        var properties: [NowPlayingInfo] = []
        poller.onTimeline = { timeline.append($0.position) }
        poller.onProperties = { properties.append($0) }
        let first = NowPlayingInfo(state: .paused, title: "A", position: 10, duration: 100, albumArtist: "First")
        poller.deliver(first, artwork: nil, trackKey: "track")
        var next = first
        next.position = 25
        next.albumArtist = "Second"
        next.genres = "Jazz"
        poller.deliver(next, artwork: nil, trackKey: "track")
        poller.deliver(next, artwork: nil, trackKey: "track")
        XCTAssertEqual(timeline, [10, 25])
        XCTAssertEqual(properties.map(\.albumArtist), ["First", "Second"])
        XCTAssertEqual(properties.last?.genres, "Jazz")
    }

    func testMediaStatusIsIndependentFromStoppedPlayback() {
        let poller = MediaPoller(provider: FixedProvider())
        var states: [Bool] = []
        poller.onStatus = { states.append($0) }
        poller.start()
        poller.deliver(NowPlayingInfo(state: .stopped), artwork: nil, trackKey: "")
        poller.setIntegrationEnabled(false)
        poller.setIntegrationEnabled(true)
        poller.stop()
        XCTAssertEqual(states, [true, false, true], "suspending polling does not disable integration")
    }

    func testJSONMetadataPreservesDelimitersAndDefinedProperties() throws {
        let object: [String: Any] = ["state": 1, "title": "A\tB\n曲", "artist": "Artist", "album": "Album",
                                     "position": 12.5, "duration": 120.0, "albumArtist": "Various",
                                     "genres": "Jazz,Blues", "trackID": "persistent-1"]
        let text = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
        let info = try XCTUnwrap(AppleScriptNowPlayingProvider.parse(text, app: "Music"))
        XCTAssertEqual(info.title, "A\tB\n曲")
        XCTAssertEqual(info.position, 12.5)
        XCTAssertEqual(info.albumArtist, "Various")
        XCTAssertEqual(info.trackID, "persistent-1")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(info.propertiesJSON.utf8)) as? [String: String])
        XCTAssertEqual(payload["albumArtist"], "Various")
        XCTAssertEqual(payload["genres"], "Jazz,Blues")
        XCTAssertEqual(payload["title"], "A\tB\n曲")
    }

    func testProviderPrefersPlayingMusicOverStoppedSpotifyWithoutLaunchingApps() throws {
        let scripts = Box<[String]>([])
        let provider = AppleScriptNowPlayingProvider(runningBundleIDs: { ["com.spotify.client", "com.apple.Music"] }, executeScript: { script in
            scripts.update { $0.append(script) }
            if script.contains("tell application \"Spotify\"") { return "0" }
            return "1\tMusic title\tArtist\tAlbum\t10\t100"
        })
        let info = try XCTUnwrap(provider.fetch())
        XCTAssertEqual(info.title, "Music title")
        XCTAssertEqual(info.sessionID, "Music")
        XCTAssertEqual(scripts.read().count, 2)
        _ = provider.fetchArtwork(for: info)
        XCTAssertTrue(try XCTUnwrap(scripts.read().last).contains("tell application \"Music\""))
    }

    func testArtworkIdentityDoesNotAliasDisplayDelimitersOrDifferentSources() {
        let a = NowPlayingInfo(state: .playing, title: "A|B", artist: "C", album: "D")
        let b = NowPlayingInfo(state: .playing, title: "A", artist: "B|C", album: "D")
        XCTAssertNotEqual(a.artworkKey, b.artworkKey)
        var source = a
        source.sessionID = "Music"
        var otherSource = source
        otherSource.sessionID = "Spotify"
        XCTAssertNotEqual(source.artworkKey, otherSource.artworkKey)
    }

    func testArtworkTransientFailureRetriesThenDeduplicatesSuccessfulBytes() {
        let provider = RetryingArtworkProvider()
        let poller = MediaPoller(provider: provider)
        defer { poller.stop() }
        var thumbnails = 0
        poller.onThumbnail = { _, bytes in
            XCTAssertEqual(bytes, Data([9, 8, 7]))
            thumbnails += 1
        }
        let first = expectation(description: "first metadata")
        poller.onTimeline = { _ in first.fulfill() }
        poller.start()
        wait(for: [first], timeout: 3)
        XCTAssertEqual(provider.artworkCalls.read(), 1)
        XCTAssertEqual(thumbnails, 0)
        for index in 0..<13 {
            let tick = expectation(description: "poll \(index)")
            poller.onTimeline = { _ in tick.fulfill() }
            poller.poll()
            wait(for: [tick], timeout: 3)
        }
        XCTAssertEqual(provider.artworkCalls.read(), 3, "retry succeeds, then periodic refresh remains bounded")
        XCTAssertEqual(thumbnails, 1, "same successful bytes must not emit repeated thumbnail events")
    }

    private final class RetryingArtworkProvider: NowPlayingProvider, SessionArtworkProviding {
        let artworkCalls = Box(0)
        func fetch() -> NowPlayingInfo? { NowPlayingInfo(state: .playing, title: "Track", sessionID: "Music", trackID: "1") }
        func fetchArtwork() -> Data? { XCTFail("poller must bind artwork to fetched session"); return nil }
        func fetchArtwork(for info: NowPlayingInfo) -> Data? {
            XCTAssertEqual(info.sessionID, "Music")
            artworkCalls.update { $0 += 1 }
            return artworkCalls.read() == 1 ? nil : Data([9, 8, 7])
        }
    }

    private struct FixedProvider: NowPlayingProvider {
        func fetch() -> NowPlayingInfo? { NowPlayingInfo(state: .stopped) }
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 3)
    }
}
