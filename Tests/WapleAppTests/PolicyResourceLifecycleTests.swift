import XCTest
import WaplePolicy
import WapleRender
import AppKit
@testable import Waple

final class PolicyResourceLifecycleTests: XCTestCase {
    func testPersistedSecondarySelectionCannotOverrideGlobalPrimaryAfterRestart() {
        let saved = ["primary": "old-selection", "secondary": "secondary-selection"]
        XCTAssertNil(MonitorMapping.playlistOverride(screenKey: "primary", primaryScreenKey: "primary", overrides: saved))
        XCTAssertEqual(MonitorMapping.playlistOverride(screenKey: "secondary", primaryScreenKey: "primary", overrides: saved),
                       "secondary-selection")
        XCTAssertNil(MonitorMapping.playlistOverride(screenKey: "secondary", primaryScreenKey: "secondary", overrides: saved),
                     "a promoted secondary now follows the global selection")
    }
    func testOutgoingFrameBatchWaitsForAllScreensAndCompletesOnlyOnce() {
        var batch = RendererCaptureBatch<String>(screenKeys: ["left", "right", "unavailable"])
        XCTAssertNil(batch.record(screenKey: "right", image: "right-frame"))
        XCTAssertNil(batch.record(screenKey: "right", image: "duplicate"))
        XCTAssertNil(batch.record(screenKey: "unavailable", image: nil))
        XCTAssertEqual(batch.record(screenKey: "left", image: "left-frame"),
                       ["left": "left-frame", "right": "right-frame"])
        XCTAssertNil(batch.record(screenKey: "left", image: "late-frame"))
    }
    @MainActor func testSpanningFrameIncludesNegativeOriginAndMixedHeightDisplays() {
        let frames = [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                      CGRect(x: -1280, y: 200, width: 1280, height: 1440)]
        XCTAssertEqual(DesktopWindowController.spanningFrame(frames),
                       CGRect(x: -1280, y: 0, width: 3200, height: 1640))
        XCTAssertNil(DesktopWindowController.spanningFrame([]))
    }

    func testShortcutDispatchRechecksBindingAndNeverOpensStaleOrUnboundName() {
        let target = URL(string: "https://example.com")!
        var opened: [URL] = []
        let opener: (URL) -> Bool = { opened.append($0); return true }
        XCTAssertFalse(UserShortcutDispatch.open(name: "site", isCurrent: false,
            bindings: { ["site": target] }, opener: opener))
        XCTAssertFalse(UserShortcutDispatch.open(name: "site", isCurrent: true,
            bindings: { [:] }, opener: opener))
        XCTAssertTrue(UserShortcutDispatch.open(name: "site", isCurrent: true,
            bindings: { ["site": target] }, opener: opener))
        XCTAssertEqual(opened, [target])
    }
    func testUserWallpaperOverrideWinsWithoutChangingOtherAuthoredAxes() {
        let policy = PlaybackPolicyResolver.effective(global: .weDefault,
            declaring: ["playbackfocus": "pause", "playbackaudio": "mute"],
            userOverrides: ["playbackfocus": "run"])
        XCTAssertEqual(policy.focus, .run)
        XCTAssertEqual(policy.audio, .mute)
        XCTAssertEqual(policy.fullscreen, .pause)
    }
    func testStopReleasesOnceAndRestoreRunsOnceWhenConditionClears() {
        var loaded = true
        var calls: [String] = []
        for stop in [true, true, false, false] {
            RenderPauseComposition.reconcileResources(wantsStop: stop, isLoaded: loaded,
                release: { loaded = false; calls.append("release") },
                restore: { loaded = true; calls.append("restore") })
        }
        XCTAssertEqual(calls, ["release", "restore"])
        XCTAssertTrue(loaded)
    }

    func testFailedRestoreKeepsEmptySlotAndCanRetry() {
        enum Failure: Error { case mount }
        var loaded = false
        XCTAssertThrowsError(try RenderPauseComposition.reconcileResources(wantsStop: false,
            isLoaded: loaded, release: { XCTFail("already released") }, restore: { throw Failure.mount }))
        XCTAssertFalse(loaded)
        RenderPauseComposition.reconcileResources(wantsStop: false, isLoaded: loaded,
            release: {}, restore: { loaded = true })
        XCTAssertTrue(loaded)
    }

    @MainActor func testPressureDoesNotClearUntilNormalAndIgnoresDuplicateEvents() {
        let observer = ResourcePressureObserver()
        var changes = 0
        observer.onChange = { changes += 1 }
        observer.accept(.warning)
        observer.accept(.critical)
        observer.accept([])
        XCTAssertTrue(observer.isPressured)
        XCTAssertEqual(changes, 1)
        observer.accept(.normal)
        XCTAssertFalse(observer.isPressured)
        XCTAssertEqual(changes, 2)
    }
}
