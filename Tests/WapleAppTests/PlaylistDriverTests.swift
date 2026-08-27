import XCTest
import WapleCore
import WapleLibrary
@testable import Waple

/// 재생목록 스케줄러의 **앱 측 소비자** 계약.
///
/// 순수층(`Tests/WapleCoreTests/PlaylistRuntimeTests.swift`)이 잠그는 것은 판정 규칙이고,
/// 여기서 잠그는 것은 **두 스키마의 번역**과 **마운트 실패를 견디는 법**이다. 그 둘이 종전에
/// `AppDelegate` 안에 흩어져 있었고, 그래서 리눅스에서 한 줄도 검증되지 않았다.
///
/// **클래스에 `@MainActor` 를 붙이되 `setUp`/`tearDown` 을 오버라이드하지 않는다** —
/// 리눅스 swift-corelibs-xctest 는 그 둘을 nonisolated 로 고정해 격리가 깨지고, 그러면 이
/// 파일이 통째로 리눅스 타입체크 제외 목록으로 밀려난다(`WorkshopPagingTests` 전례).
/// 임시 디렉터리는 각 테스트가 `defer` 로 치운다.
@MainActor
final class PlaylistDriverTests: XCTestCase {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDriver(in dir: URL) -> PlaylistDriver {
        PlaylistDriver(stateTime: PlaylistStateTimeStore(baseDirectory: dir), calendar: .current)
    }

    private func sync(_ driver: PlaylistDriver,
                      enabled: Bool = true,
                      minutes: Int = 1,
                      shuffle: Bool = false,
                      ids: [String],
                      screens: [String],
                      current: String? = nil) {
        driver.sync(enabled: enabled, intervalMinutes: minutes, shuffle: shuffle,
                    ids: ids, screenKeys: screens, currentEntryId: current)
    }

    // MARK: - 스키마 번역

    func testDisabledPlaylistBecomesNeverModeAndStops() {
        let settings = PlaylistSettingsBridge.settings(enabled: false, intervalMinutes: 30, shuffle: false)
        XCTAssertEqual(settings.mode, .never)
        XCTAssertEqual(settings.normalized().delayMinutes, 0,
                       "never 는 파서가 delay 를 0 으로 덮는다 — 그래서 0.01분 가드에 걸려 멎는다")
        XCTAssertFalse(settings.normalized().accumulatesElapsed(isPaused: false))
    }

    func testEnabledPlaylistIsTimerMode() {
        XCTAssertEqual(PlaylistSettingsBridge.settings(enabled: true, intervalMinutes: 30, shuffle: false).mode,
                       .timer)
    }

    func testShuffleTogglePicksTheOrderAxis() {
        XCTAssertEqual(PlaylistSettingsBridge.settings(enabled: true, intervalMinutes: 1, shuffle: true).order,
                       .random)
        XCTAssertEqual(PlaylistSettingsBridge.settings(enabled: true, intervalMinutes: 1, shuffle: false).order,
                       .sorted)
    }

    func testIntervalMinutesCarryTheirOwnFloor() {
        XCTAssertEqual(PlaylistSettingsBridge.settings(enabled: true, intervalMinutes: 30, shuffle: false).delayMinutes,
                       30)
        XCTAssertEqual(PlaylistSettingsBridge.settings(enabled: true, intervalMinutes: 0, shuffle: false).delayMinutes,
                       1, "우리 UI 하한은 1분이다 — WE 의 0.01분보다 좁다")
        XCTAssertEqual(PlaylistSettingsBridge.settings(enabled: true, intervalMinutes: -5, shuffle: false).delayMinutes,
                       1, "손으로 고친 playlist.json 이 음수를 넣어도 시계가 거꾸로 돌면 안 된다")
    }

    /// **저장 스키마도 UI 도 없는 키는 끈 값이어야 한다.** 특히 `videosequence` 를 켜면 타이머가
    /// 동영상에서 전진을 보류하는데 그것을 받아 줄 종료 통지 경로가 아직 없어서, 동영상 배경이
    /// **영원히 안 넘어간다**. 이 단언이 그 사고를 막는다.
    func testKeysWithoutAConsumerStayOff() {
        let settings = PlaylistSettingsBridge.settings(enabled: true, intervalMinutes: 5, shuffle: true)
        XCTAssertFalse(settings.videoSequence, "동영상 종료 통지 경로가 없다 — 켜면 동영상이 멎는다")
        XCTAssertFalse(settings.beginFirst)
        XCTAssertFalse(settings.playIntro)
        XCTAssertFalse(settings.updateOnPause, "종전 shouldAdvanceNow(isPaused:) 와 같은 값")
        XCTAssertEqual(settings.transition, .noTransition,
                       "전환 렌더러가 없다 — 화면에서 실제로 일어나는 일을 그대로 적는다")
    }

    // MARK: - 전진

    func testAdvancesOnceTheIntervalHasElapsed() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let driver = makeDriver(in: dir)
        sync(driver, minutes: 1, ids: ["a", "b", "c"], screens: ["S"])

        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(driver.tick(now: start, isPaused: false).isEmpty)
        XCTAssertTrue(driver.tick(now: start.addingTimeInterval(59), isPaused: false).isEmpty,
                      "1초 틱을 59번 건너뛴 것과 같다 — 5초 상한이 걸려 아직 못 찬다")

        var elapsed = start.addingTimeInterval(59)
        var advanced: [String] = []
        for _ in 0..<30 {
            elapsed = elapsed.addingTimeInterval(5)
            advanced += driver.tick(now: elapsed, isPaused: false)
        }
        XCTAssertEqual(advanced.first, "S")

        var applied: [String] = []
        let picked = driver.advance(screenKey: "S", now: elapsed) { id in applied.append(id); return true }
        XCTAssertEqual(picked, "a", "sorted 순서는 목록 순서다")
        XCTAssertEqual(applied, ["a"])
    }

    func testDisabledPlaylistNeverAdvances() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let driver = makeDriver(in: dir)
        sync(driver, enabled: false, minutes: 1, ids: ["a", "b"], screens: ["S"])
        var now = Date(timeIntervalSince1970: 2_000_000)
        for _ in 0..<10_000 {
            now = now.addingTimeInterval(5)
            XCTAssertTrue(driver.tick(now: now, isPaused: false).isEmpty)
        }
    }

    func testPauseFreezesTheClockInsteadOfDeferringIt() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let driver = makeDriver(in: dir)
        sync(driver, minutes: 1, ids: ["a", "b"], screens: ["S"])
        var now = Date(timeIntervalSince1970: 3_000_000)
        for _ in 0..<1_000 {
            now = now.addingTimeInterval(5)
            XCTAssertTrue(driver.tick(now: now, isPaused: true).isEmpty)
        }
        XCTAssertEqual(driver.elapsedByScreen["S"], 0,
                       "정지가 풀리는 순간 밀린 전환이 터지면 안 된다 — 시계 자체가 멈춘다")
    }

    /// 삭제된 엔트리·사라진 폴더 하나가 재생목록을 그 자리에 영구 정지시키던 결함의 방어.
    func testFailedCandidatesAreSkippedWithinOneLap() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let driver = makeDriver(in: dir)
        sync(driver, ids: ["gone", "alsogone", "ok"], screens: ["S"])
        var tried: [String] = []
        let picked = driver.advance(screenKey: "S", now: Date()) { id in
            tried.append(id)
            return id == "ok"
        }
        XCTAssertEqual(picked, "ok")
        XCTAssertEqual(tried, ["gone", "alsogone", "ok"], "실패 후보를 순서대로 건너뛴다")
    }

    func testEveryCandidateFailingLeavesTheWallpaperAlone() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let driver = makeDriver(in: dir)
        sync(driver, ids: ["a", "b"], screens: ["S"])
        var tries = 0
        XCTAssertNil(driver.advance(screenKey: "S", now: Date()) { _ in tries += 1; return false })
        XCTAssertEqual(tries, 2, "한 바퀴(항목 수)까지만 돈다 — 무한 루프가 되면 안 된다")
    }

    // MARK: - 화면별

    func testTwoScreensRunTheirOwnClocks() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let driver = makeDriver(in: dir)
        sync(driver, minutes: 1, ids: ["a", "b", "c"], screens: ["S1", "S2"])

        var now = Date(timeIntervalSince1970: 4_000_000)
        _ = driver.tick(now: now, isPaused: false)
        // S1 만 한 번 전진시킨다 — 그 화면의 시계만 0 으로 돌아가야 한다.
        for _ in 0..<12 {
            now = now.addingTimeInterval(5)
            _ = driver.tick(now: now, isPaused: false)
        }
        XCTAssertNotNil(driver.advance(screenKey: "S1", now: now) { _ in true })
        XCTAssertEqual(driver.elapsedByScreen["S1"], 0)
        XCTAssertEqual(driver.elapsedByScreen["S2"] ?? 0, 60, accuracy: 0.001,
                       "다른 화면의 경과시간은 그대로다 — 전역 카운터가 아니다")
    }

    // MARK: - 영속

    func testElapsedSurvivesARestartThroughTheWEShapedFile() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = makeDriver(in: dir)
        sync(first, minutes: 60, ids: ["a", "b"], screens: ["display-1"])
        var now = Date(timeIntervalSince1970: 5_000_000)
        for _ in 0..<6 {
            now = now.addingTimeInterval(5)
            _ = first.tick(now: now, isPaused: false)
        }
        XCTAssertEqual(first.elapsedByScreen["display-1"] ?? 0, 30, accuracy: 0.001)
        first.persist(now: now)

        // 파일이 WE 포맷이다 — 다음 라운드에 설치본과 주고받을 수 있어야 한다.
        let raw = try? Data(contentsOf: dir.appendingPathComponent(PlaylistStateTimeStore.fileName))
        let decoded = raw.flatMap { PlaylistStateTimeFile.decode($0) }
        XCTAssertEqual(decoded?.elapsedByName["display-1"], 30)

        let second = makeDriver(in: dir)
        XCTAssertEqual(second.elapsedByScreen["display-1"] ?? 0, 30, accuracy: 0.001,
                       "재시작해도 '이 벽지를 몇 분 봤는지' 가 이어진다")
    }

    /// **첫 `sync` 가 복원한 시계를 지우면 영속이 통째로 무의미해진다** — 복원 직후 사용자 선택
    /// 감지가 한 번 돌면서 adopt 해 버리는 사고가 정확히 그 모양이다.
    func testFirstSyncKeepsTheRestoredClock() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seed = makeDriver(in: dir)
        sync(seed, minutes: 60, ids: ["a", "b"], screens: ["display-1"])
        var now = Date(timeIntervalSince1970: 6_000_000)
        for _ in 0..<10 {
            now = now.addingTimeInterval(5)
            _ = seed.tick(now: now, isPaused: false)
        }
        seed.persist(now: now)

        let reborn = makeDriver(in: dir)
        sync(reborn, minutes: 60, ids: ["a", "b"], screens: ["display-1"], current: "a")
        XCTAssertEqual(reborn.elapsedByScreen["display-1"] ?? 0, 50, accuracy: 0.001)
    }

    /// 사용자가 직접 배경을 고르면 그 화면의 시계는 처음부터다. 안 그러면 방금 고른 배경이
    /// 몇 초 만에 넘어간다 — 경과시간이 재부팅 너머로 이어지는 지금은 특히 그렇다.
    func testUserPickingAWallpaperRewindsThatScreensClock() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let driver = makeDriver(in: dir)
        sync(driver, minutes: 60, ids: ["a", "b"], screens: ["S"], current: "a")
        var now = Date(timeIntervalSince1970: 7_000_000)
        for _ in 0..<10 {
            now = now.addingTimeInterval(5)
            _ = driver.tick(now: now, isPaused: false)
        }
        XCTAssertEqual(driver.elapsedByScreen["S"] ?? 0, 50, accuracy: 0.001)
        sync(driver, minutes: 60, ids: ["a", "b"], screens: ["S"], current: "b")   // 사용자가 b 를 골랐다
        XCTAssertEqual(driver.elapsedByScreen["S"], 0)
    }

    func testUnchangedSelectionDoesNotKeepRewindingTheClock() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let driver = makeDriver(in: dir)
        var now = Date(timeIntervalSince1970: 8_000_000)
        for _ in 0..<10 {
            sync(driver, minutes: 60, ids: ["a", "b"], screens: ["S"], current: "a")
            now = now.addingTimeInterval(5)
            _ = driver.tick(now: now, isPaused: false)
        }
        XCTAssertEqual(driver.elapsedByScreen["S"] ?? 0, 50, accuracy: 0.001,
                       "매 틱 부르는 sync 가 시계를 되돌리면 재생목록이 영원히 안 넘어간다")
    }

    func testEmptyPlaylistIsInert() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let driver = makeDriver(in: dir)
        sync(driver, ids: [], screens: ["S"])
        XCTAssertTrue(driver.tick(now: Date(), isPaused: false).isEmpty)
        XCTAssertNil(driver.advance(screenKey: "S", now: Date()) { _ in true })
    }
}
