import XCTest
@testable import WapleCore

final class AuditPlaylistPauseRegressionTests: XCTestCase {
    func testPolicyPausedScreenFreezesWhileOtherScreenAdvances() {
        var runtime = PlaylistRuntime(settings: PlaylistSettings(delayMinutes: 1, order: .sorted, mode: .timer),
                                      items: [PlaylistItem(file: "a"), PlaylistItem(file: "b")])
        runtime.setActiveScreens(["paused", "playing"])
        runtime.restoreElapsed(["paused": 59, "playing": 59])
        let now = PlaylistClockReading(hour: 12, minute: 0, weekday: 1, firstDayOfWeek: 0)
        let advanced = runtime.tick(deltaSeconds: 1, isPaused: { $0 == "paused" }, now: now)
        XCTAssertEqual(advanced, ["playing"])
        XCTAssertEqual(runtime.elapsedByScreen["paused"], 59)
        XCTAssertEqual(runtime.elapsedByScreen["playing"], 60)
    }
}
