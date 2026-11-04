import XCTest
@testable import WapleCore

final class PlaylistScreenConfigurationTests: XCTestCase {
    func testDifferentScreensUseTheirOwnTimeAndWeekdaySlots() {
        var runtime = PlaylistRuntime()
        runtime.setActiveScreens(["day", "week"])
        runtime.apply(settings: PlaylistSettings(mode: .daytime), items: [
            PlaylistItem(file: "morning", daytimeEnd: 0.5),
            PlaylistItem(file: "evening", daytimeEnd: 1)
        ], screenKey: "day")
        runtime.apply(settings: PlaylistSettings(mode: .dayOfWeek),
            items: (0..<7).map { PlaylistItem(file: "day-\($0)") }, screenKey: "week")
        let mondayAfternoon = PlaylistClockReading(hour: 14, minute: 0, weekday: 1, firstDayOfWeek: 0)
        XCTAssertEqual(runtime.nextCandidate(screenKey: "day", now: mondayAfternoon), 1)
        XCTAssertEqual(runtime.nextCandidate(screenKey: "week", now: mondayAfternoon), 0)
        runtime.commit(index: 1, screenKey: "day")
        runtime.commit(index: 0, screenKey: "week")
        XCTAssertTrue(runtime.tick(deltaSeconds: 1, isPaused: false, now: mondayAfternoon).isEmpty)
    }

    func testRestoredSelectionKeepsElapsedClockAndSortedOrder() {
        var runtime = PlaylistRuntime(settings: PlaylistSettings(order: .sorted),
            items: [PlaylistItem(file: "a"), PlaylistItem(file: "b"), PlaylistItem(file: "c")])
        runtime.setActiveScreens(["screen"])
        runtime.restoreElapsed(["screen": 19])
        runtime.restoreSelection(index: 1, screenKey: "screen")
        XCTAssertEqual(runtime.elapsedByScreen["screen"], 19)
        XCTAssertEqual(runtime.nextCandidate(screenKey: "screen", now:
            PlaylistClockReading(hour: 0, minute: 0, weekday: 0, firstDayOfWeek: 0)), 2)
    }
}
