import XCTest
import WapleCore
import WapleLibrary
@testable import Waple

@MainActor
final class PlaylistFeatureRuntimeTests: XCTestCase {
    private func withDriver(_ body: (PlaylistDriver) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(PlaylistDriver(stateTime: PlaylistStateTimeStore(baseDirectory: root)))
    }

    func testPerScreenFractionalAndUpdateOnPauseSettingsReachTheScheduler() {
        withDriver { driver in
            driver.sync(settingsByScreen: [
                "fast": PlaylistSettings(delayMinutes: 0.01, order: .sorted, updateOnPause: true),
                "slow": PlaylistSettings(delayMinutes: 1, order: .sorted)
            ], itemsByScreen: ["fast": [PlaylistItem(file: "a"), PlaylistItem(file: "b")],
                               "slow": [PlaylistItem(file: "x"), PlaylistItem(file: "y")]],
                screenKeys: ["fast", "slow"], currentEntryIds: [:])
            let now = Date(timeIntervalSince1970: 1000)
            _ = driver.tick(now: now, isPaused: true)
            XCTAssertEqual(driver.tick(now: now.addingTimeInterval(1), isPaused: true), ["fast"])
            XCTAssertEqual(driver.elapsedByScreen["slow"], 0)
            var applied: [String] = []
            XCTAssertEqual(driver.requestAdvance(screenKey: "fast", now: now) { id, _ in
                applied.append(id); return .applied
            }, .applied)
            XCTAssertEqual(applied, ["a"])
        }
    }

    func testPendingBeginningLatchesIntroOnlyAfterSuccessfulMount() {
        withDriver { driver in
            driver.sync(settingsByScreen: ["screen": PlaylistSettings(delayMinutes: 0.01,
                order: .sorted, videoSequence: false, beginFirst: true, playIntro: true)],
                itemsByScreen: ["screen": [PlaylistItem(file: "intro"), PlaylistItem(file: "regular")]],
                screenKeys: ["screen"], currentEntryIds: [:])
            var finish: ((WallpaperApplyResolution) -> Void)?
            XCTAssertFalse(driver.shouldAdvanceOnVideoEnd(screenKey: "screen"))
            XCTAssertEqual(driver.requestBeginning(screenKey: "screen", now: Date()) { id, callback in
                XCTAssertEqual(id, "intro"); finish = callback; return .pending
            }, .pending)
            XCTAssertFalse(driver.shouldAdvanceOnVideoEnd(screenKey: "screen"))
            finish?(.applied)
            XCTAssertTrue(driver.shouldAdvanceOnVideoEnd(screenKey: "screen"))
            driver.sync(settingsByScreen: ["screen": PlaylistSettings(delayMinutes: 0.01,
                order: .sorted, videoSequence: false, beginFirst: true, playIntro: true)],
                itemsByScreen: ["screen": [PlaylistItem(file: "intro"), PlaylistItem(file: "regular")]],
                screenKeys: ["screen"], currentEntryIds: ["screen": "intro"])
            XCTAssertTrue(driver.shouldAdvanceOnVideoEnd(screenKey: "screen"))
            XCTAssertFalse(driver.needsBeginning(screenKey: "screen"))
            _ = driver.requestAdvance(screenKey: "screen", now: Date()) { id, _ in
                XCTAssertEqual(id, "regular"); return .applied
            }
            XCTAssertFalse(driver.shouldAdvanceOnVideoEnd(screenKey: "screen"))
        }
    }

    func testDaytimeReorderRefreshesCurrentIndexByID() {
        withDriver { driver in
            let settings = ["screen": PlaylistSettings(mode: .daytime)]
            let first = PlaylistItem(file: "a", daytimeEnd: 1)
            let second = PlaylistItem(file: "b", daytimeEnd: 1)
            let now = Date()
            driver.sync(settingsByScreen: settings, itemsByScreen: ["screen": [first, second]],
                        screenKeys: ["screen"], currentEntryIds: ["screen": "a"])
            XCTAssertTrue(driver.tick(now: now, isPaused: false).isEmpty)
            driver.sync(settingsByScreen: settings, itemsByScreen: ["screen": [second, first]],
                        screenKeys: ["screen"], currentEntryIds: ["screen": "a"])
            XCTAssertEqual(driver.tick(now: now, isPaused: false), ["screen"])
        }
    }

    func testFailedDaytimeCandidateDoesNotRepeatOrBlockAnotherDisplay() {
        withDriver { driver in
            let now = Date()
            let due: Set<String> = ["a", "b"]
            let items = [PlaylistItem(file: "bad", daytimeEnd: 1), PlaylistItem(file: "other", daytimeEnd: 1)]
            driver.sync(settingsByScreen: ["a": PlaylistSettings(mode: .daytime)],
                        itemsByScreen: ["a": items], screenKeys: ["a", "b"], currentEntryIds: [:])
            XCTAssertEqual(driver.nextScheduledScreen(due: due, now: now), "a")
            var attempted: [String] = []
            XCTAssertEqual(driver.requestAdvance(screenKey: "a", now: now) { id, _ in
                attempted.append(id)
                return .failed
            }, .failed)
            XCTAssertEqual(attempted, ["bad"])
            XCTAssertEqual(driver.nextScheduledScreen(due: due, now: now), "b")
            XCTAssertNil(driver.nextScheduledScreen(due: ["a"], now: now))
            XCTAssertEqual(driver.nextScheduledScreen(due: due, now: now.addingTimeInterval(6)), "a")
        }
    }

    func testSingletonVideoEndDoesNotRemountTheCurrentEntry() {
        withDriver { driver in
            driver.sync(settingsByScreen: ["screen": PlaylistSettings(videoSequence: true)],
                        itemsByScreen: ["screen": [PlaylistItem(file: "only")]],
                        screenKeys: ["screen"], currentEntryIds: ["screen": "only"])
            XCTAssertFalse(driver.shouldAdvanceOnVideoEnd(screenKey: "screen"))
        }
    }

    func testSingleTimerEntryDoesNotScheduleRepeatedRemountsButCanBeginOnce() {
        var configuration = PlaylistConfiguration(enabled: true, ids: ["only"])
        XCTAssertFalse(PlaylistSettingsBridge.shouldSchedule(configuration: configuration))
        configuration.beginFirst = true
        XCTAssertTrue(PlaylistSettingsBridge.shouldSchedule(configuration: configuration))
        configuration.mode = .daytime
        configuration.beginFirst = false
        XCTAssertTrue(PlaylistSettingsBridge.shouldSchedule(configuration: configuration))
    }

    func testSavedConfigurationFlagsAndEndpointsAreConsumedByTheProductionBridge() {
        let configuration = PlaylistConfiguration(enabled: true, delayMinutes: 0.125,
            mode: .daytime, ids: ["a", "b"], shuffle: true, videoSequence: true,
            updateOnPause: true, beginFirst: true, playIntro: true, daytimeEnds: ["a": 0.4])
        let settings = PlaylistSettingsBridge.settings(configuration: configuration)
        XCTAssertEqual(settings.delayMinutes, 0.125)
        XCTAssertEqual(settings.mode, .daytime)
        XCTAssertTrue(settings.videoSequence)
        XCTAssertTrue(settings.updateOnPause)
        XCTAssertEqual(PlaylistSettingsBridge.items(configuration: configuration), [
            PlaylistItem(file: "a", daytimeEnd: 0.4), PlaylistItem(file: "b", daytimeEnd: 1)])
    }
}
