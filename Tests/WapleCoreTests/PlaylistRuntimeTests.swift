import XCTest
@testable import WapleCore

/// `PlaylistRuntime` — 순수 조각들을 **한 결정**으로 엮는 층의 계약 잠금.
///
/// 여기서 잠그는 것은 조각 하나하나의 산수가 아니라(그건 `PlaylistTransitionTests` 가 한다)
/// **조각들이 놓이는 순서와 상태의 소유자**다. 실제로 두 번 틀렸던 자리가 그것이다:
///   ① 경과시간 누적이 판정 **앞**인지 뒤인지 (0x140076d3b 세 관문이 `addss` 앞이다)
///   ② 백/커서/경과시간이 전역인지 **화면별**인지 (WE 는 모니터 노드 안이다)
///
/// 시계는 전부 주입한다 — `Date()` 를 읽는 자리가 하나라도 있으면 daytime/dayofweek 를
/// 결정적으로 판정할 수 없다.
final class PlaylistRuntimeTests: XCTestCase {

    private let noon = PlaylistClockReading(hour: 12, minute: 0, weekday: 3, firstDayOfWeek: 0)

    private func items(_ n: Int) -> [PlaylistItem] {
        (0..<n).map { PlaylistItem(file: "w\($0).json") }
    }

    /// `XCTAssertEqual(_:_:accuracy:)` 는 옵셔널을 받지 않는다 — 화면이 없으면 어떤 기대값과도
    /// 안 맞는 `-1` 로 떨어뜨려 "없음" 이 조용히 통과하지 않게 한다.
    private func elapsed(_ runtime: PlaylistRuntime, _ key: String) -> Float {
        runtime.scheduler(for: key)?.elapsedSeconds ?? -1
    }

    private func runtime(_ settings: PlaylistSettings,
                         items list: [PlaylistItem],
                         screens: [String] = ["A"]) -> PlaylistRuntime {
        var r = PlaylistRuntime(settings: settings, items: list, seed: 12345)
        r.setActiveScreens(screens)
        return r
    }

    // MARK: - ① 누적은 판정 앞이고, 세 관문은 누적 앞이다

    func testAccumulatesElapsedMirrorsTheThreeGatesBeforeAddss() {
        let timer = PlaylistSettings(delayMinutes: 10, mode: .timer)
        XCTAssertTrue(timer.accumulatesElapsed(isPaused: false))
        XCTAssertFalse(timer.accumulatesElapsed(isPaused: true),
                       "0x140076d3b — updateonpause 없이 정지 중이면 addss 에 도달하지 못한다")

        var withUpdate = timer
        withUpdate.updateOnPause = true
        XCTAssertTrue(withUpdate.accumulatesElapsed(isPaused: true))

        XCTAssertFalse(PlaylistSettings(delayMinutes: 10, mode: .daytime).normalized()
                        .accumulatesElapsed(isPaused: false),
                       "0x140076d4a — mode ∈ {2,3} 은 경과시간 축 전체를 건너뛴다")
        XCTAssertFalse(PlaylistSettings(delayMinutes: 0.005, mode: .timer)
                        .accumulatesElapsed(isPaused: false),
                       "0x140076d54 — delay < 0.01분이면 addss 앞에서 이탈한다")
    }

    /// **정지 중에는 시계가 멈춘다.** 이 테스트가 없으면 "누적은 늘 하고 전진만 막는" 재구현이
    /// 통과하고, 그러면 한 시간 정지 뒤 재개하는 순간 전환이 즉시 터진다.
    func testPauseFreezesTheClockInsteadOfDeferringIt() {
        var r = runtime(PlaylistSettings(delayMinutes: 1, mode: .timer, transitionConfigValue: -1), items: items(3))
        for _ in 0..<3600 {
            XCTAssertTrue(r.tick(deltaSeconds: 1, isPaused: true, now: noon, isVideo: { _ in false }).isEmpty)
        }
        XCTAssertEqual(elapsed(r, "A"), 0, accuracy: 0.0001,
                       "정지 한 시간이 경과시간에 한 톨도 쌓이면 안 된다")
        // 재개 첫 틱도 그대로다 — 1분치가 아직 안 찼다.
        XCTAssertTrue(r.tick(deltaSeconds: 1, isPaused: false, now: noon, isVideo: { _ in false }).isEmpty)
    }

    func testUpdateOnPauseKeepsTheClockRunningWhilePaused() {
        var settings = PlaylistSettings(delayMinutes: 1, mode: .timer)
        settings.updateOnPause = true
        var r = runtime(settings, items: items(3))
        var advanced: [String] = []
        for _ in 0..<60 {
            advanced += r.tick(deltaSeconds: 1, isPaused: true, now: noon, isVideo: { _ in false })
        }
        XCTAssertEqual(advanced, ["A"], "updateonpause 가 켜져 있으면 정지 중에도 전진한다")
    }

    // MARK: - 5초 상한

    func testSleepDoesNotBurstThroughSeveralAdvancesAtOnce() {
        var r = runtime(PlaylistSettings(delayMinutes: 1, mode: .timer), items: items(4))
        // 절전에서 한 시간 만에 깨어난 틱 한 번.
        let advances = r.tick(deltaSeconds: 3600, isPaused: false, now: noon, isVideo: { _ in false })
        XCTAssertTrue(advances.isEmpty, "0x140076c56 minss 5.0f — 한 틱은 최대 5초다")
        XCTAssertEqual(elapsed(r, "A"), 5, accuracy: 0.0001)
    }

    func testNegativeDeltaFromClockAdjustmentDoesNotRewindElapsed() {
        var r = runtime(PlaylistSettings(delayMinutes: 1, mode: .timer), items: items(4))
        _ = r.tick(deltaSeconds: 5, isPaused: false, now: noon, isVideo: { _ in false })
        _ = r.tick(deltaSeconds: -1000, isPaused: false, now: noon, isVideo: { _ in false })
        XCTAssertEqual(elapsed(r, "A"), 5, accuracy: 0.0001,
                       "시계 되감김은 0 으로 잘린다 — WE 는 QPC 라 음수가 없고 우리는 Date() 를 쓸 수 있다")
    }

    // MARK: - 전진과 경과시간 리셋

    func testAdvanceHappensExactlyAtDelayAndResetsTheClock() {
        var r = runtime(PlaylistSettings(delayMinutes: 1, order: .sorted, mode: .timer), items: items(3))
        for _ in 0..<59 {
            XCTAssertTrue(r.tick(deltaSeconds: 1, isPaused: false, now: noon, isVideo: { _ in false }).isEmpty)
        }
        XCTAssertEqual(r.tick(deltaSeconds: 1, isPaused: false, now: noon, isVideo: { _ in false }), ["A"])
        XCTAssertEqual(r.nextCandidate(screenKey: "A", now: noon), 0)
        r.commit(index: 0, screenKey: "A")
        XCTAssertEqual(elapsed(r, "A"), 0, accuracy: 0.0001,
                       "0x1400684ea — 전진이 경과시간을 지운다")
    }

    /// **후보를 내는 것과 확정하는 것은 다르다.** 마운트가 실패할 수 있으므로 `tick` 은
    /// 경과시간을 지우지 않는다 — 지우는 것은 `commit` 뿐이다. 이 분리가 없으면
    /// 삭제된 엔트리 하나가 재생목록을 그 자리에 영구 정지시킨다(F-이력과 같은 결함).
    func testTickAloneDoesNotCommit() {
        var r = runtime(PlaylistSettings(delayMinutes: 0.01, order: .sorted, mode: .timer), items: items(3))
        _ = r.tick(deltaSeconds: 1, isPaused: false, now: noon, isVideo: { _ in false })
        XCTAssertNil(r.scheduler(for: "A")?.currentIndex, "확정 전에는 걸린 것이 없다")
        XCTAssertGreaterThan(r.scheduler(for: "A")?.elapsedSeconds ?? 0, 0)
    }

    // MARK: - never / 시각 기반 모드

    func testNeverModeNeverAdvances() {
        let settings = PlaylistSettings(delayMinutes: 60, mode: .never).normalized()
        XCTAssertEqual(settings.delayMinutes, 0, "파서가 delay 를 0 으로 덮는다(0x140075d41)")
        var r = runtime(settings, items: items(3))
        for _ in 0..<10_000 {
            XCTAssertTrue(r.tick(deltaSeconds: 5, isPaused: false, now: noon, isVideo: { _ in false }).isEmpty)
        }
    }

    func testDaytimePicksTheSlotAndStaysThereWithinIt() {
        let list = [
            PlaylistItem(file: "morning.json", daytimeEnd: 0.5),   // ~12:00 까지
            PlaylistItem(file: "evening.json", daytimeEnd: 0.875), // ~21:00 까지
            PlaylistItem(file: "night.json", daytimeEnd: 1.0),
        ]
        var r = runtime(PlaylistSettings(mode: .daytime), items: list)
        let morning = PlaylistClockReading(hour: 8, minute: 0, weekday: 3, firstDayOfWeek: 0)
        let evening = PlaylistClockReading(hour: 20, minute: 0, weekday: 3, firstDayOfWeek: 0)

        XCTAssertEqual(r.tick(deltaSeconds: 1, isPaused: false, now: morning, isVideo: { _ in false }), ["A"])
        XCTAssertEqual(r.nextCandidate(screenKey: "A", now: morning), 0)
        r.commit(index: 0, screenKey: "A")
        XCTAssertTrue(r.tick(deltaSeconds: 1, isPaused: false, now: morning, isVideo: { _ in false }).isEmpty,
                      "같은 시간대 안에서는 아무 일도 일어나지 않는다")

        XCTAssertEqual(r.tick(deltaSeconds: 1, isPaused: false, now: evening, isVideo: { _ in false }), ["A"])
        XCTAssertEqual(r.nextCandidate(screenKey: "A", now: evening), 1)
    }

    func testDaytimeWithoutAnyDaytimeEndNeverMatches() {
        var r = runtime(PlaylistSettings(mode: .daytime), items: items(3))
        XCTAssertTrue(r.tick(deltaSeconds: 1, isPaused: false, now: noon, isVideo: { _ in false }).isEmpty,
                      "daytimeend 가 없는 항목은 매치되지 않는다 — 걸 것이 없으면 그대로 둔다")
    }

    func testDayOfWeekMapsMondayToSlotZeroAndSundayToSix() {
        var r = runtime(PlaylistSettings(mode: .dayOfWeek), items: items(7))
        let monday = PlaylistClockReading(hour: 9, minute: 0, weekday: 1, firstDayOfWeek: 0)
        let sunday = PlaylistClockReading(hour: 9, minute: 0, weekday: 0, firstDayOfWeek: 0)
        XCTAssertEqual(r.tick(deltaSeconds: 1, isPaused: false, now: monday, isVideo: { _ in false }), ["A"])
        XCTAssertEqual(r.nextCandidate(screenKey: "A", now: monday), 0)
        r.commit(index: 0, screenKey: "A")
        XCTAssertEqual(r.tick(deltaSeconds: 1, isPaused: false, now: sunday, isVideo: { _ in false }), ["A"])
        XCTAssertEqual(r.nextCandidate(screenKey: "A", now: sunday), 6)
    }

    func testDayOfWeekWithShortListLeavesEmptySlotsAlone() {
        var r = runtime(PlaylistSettings(mode: .dayOfWeek), items: items(3))
        let sunday = PlaylistClockReading(hour: 9, minute: 0, weekday: 0, firstDayOfWeek: 0)
        XCTAssertTrue(r.tick(deltaSeconds: 1, isPaused: false, now: sunday, isVideo: { _ in false }).isEmpty,
                      "슬롯 6 에 항목이 없다 — 걸 것이 없으면 그대로 둔다")
    }

    // MARK: - 동영상

    func testVideoSequenceHoldsTheTimerAndTheVideoEndTakesOver() {
        var settings = PlaylistSettings(delayMinutes: 0.01, order: .sorted, mode: .timer)
        settings.videoSequence = true
        var r = runtime(settings, items: items(3))
        for _ in 0..<10 {
            XCTAssertTrue(r.tick(deltaSeconds: 1, isPaused: false, now: noon, isVideo: { _ in true }).isEmpty,
                          "videosequence + 현재가 동영상 → 타이머는 보류한다")
        }
        XCTAssertTrue(r.shouldAdvanceOnVideoEnd(screenKey: "A"),
                      "보류한 전진은 동영상이 끝날 때 반대편이 받는다")
    }

    func testVideoEndDoesNothingOutsideTimerMode() {
        var settings = PlaylistSettings(delayMinutes: 10, mode: .daytime)
        settings.videoSequence = true
        let r = runtime(settings, items: items(3))
        XCTAssertFalse(r.shouldAdvanceOnVideoEnd(screenKey: "A"),
                       "videosequence 는 mode == timer 밖에서는 죽은 키다(0x140067762)")
    }

    func testBeginFirstShowsIntroAndTheIntroAdvancesOnVideoEndWithoutVideoSequence() {
        var settings = PlaylistSettings(delayMinutes: 10, order: .sorted, mode: .timer)
        settings.beginFirst = true
        settings.playIntro = true
        var r = runtime(settings, items: items(3))
        XCTAssertEqual(r.begin(), ["A"])
        XCTAssertEqual(r.currentIndex(for: "A"), 0)
        XCTAssertEqual(r.scheduler(for: "A")?.introShowing, true, "0x140067edc — 인트로 래치가 선다")
        XCTAssertTrue(r.shouldAdvanceOnVideoEnd(screenKey: "A"),
                      "playintro + 인트로가 걸려 있으면 videosequence 없이도 끝나면 넘어간다")
        r.commit(index: 1, screenKey: "A")
        XCTAssertEqual(r.scheduler(for: "A")?.introShowing, false, "0x140067ff2 — 다른 전진이 래치를 지운다")
    }

    func testIntroWallpaperHoldsTheTimerAdvanceForVideos() {
        var settings = PlaylistSettings(delayMinutes: 0.01, order: .sorted, mode: .timer)
        settings.beginFirst = true
        settings.playIntro = true
        var r = runtime(settings, items: items(3))
        _ = r.begin()
        XCTAssertTrue(r.tick(deltaSeconds: 5, isPaused: false, now: noon, isVideo: { _ in true }).isEmpty,
                      "0x140076d87 — 인트로 벽지가 걸려 있으면 동영상 타이머 전진을 보류한다")
    }

    func testBeginFirstIsIgnoredOutsideTimerMode() {
        var settings = PlaylistSettings(delayMinutes: 10, mode: .daytime)
        settings.beginFirst = true
        settings.playIntro = true
        var r = runtime(settings.normalized(), items: items(3))
        XCTAssertTrue(r.begin().isEmpty, "mode != timer 면 파서가 beginfirst 를 아예 안 읽는다")
    }

    // MARK: - ② 상태는 화면별이다

    func testTwoScreensKeepIndependentClocks() {
        var r = runtime(PlaylistSettings(delayMinutes: 1, order: .sorted, mode: .timer),
                        items: items(4), screens: ["A", "B"])
        // B 만 30초 앞서 있는 상황을 만든다.
        r.restoreElapsed(["B": 30])
        for _ in 0..<29 {
            XCTAssertTrue(r.tick(deltaSeconds: 1, isPaused: false, now: noon, isVideo: { _ in false }).isEmpty)
        }
        // 30번째 틱에서 B 만 60초를 채운다(A 는 30초).
        XCTAssertEqual(r.tick(deltaSeconds: 1, isPaused: false, now: noon, isVideo: { _ in false }), ["B"],
                       "앞선 화면만 넘어간다 — 전역 카운터가 아니다")
        XCTAssertEqual(elapsed(r, "A"), 30, accuracy: 0.0001)
    }

    func testTwoScreensDrawDifferentShuffleSequences() {
        var r = runtime(PlaylistSettings(delayMinutes: 1, order: .random, mode: .timer),
                        items: items(8), screens: ["display-1", "display-2"])
        var a: [Int] = []
        var b: [Int] = []
        for _ in 0..<8 {
            a.append(r.nextCandidate(screenKey: "display-1", now: noon) ?? -1)
            b.append(r.nextCandidate(screenKey: "display-2", now: noon) ?? -1)
        }
        XCTAssertNotEqual(a, b, "화면마다 시드가 달라야 두 모니터가 같은 수열을 나란히 걷지 않는다")
        XCTAssertEqual(Set(a).count, 8, "소진형이므로 한 바퀴에 8종이 전부 나온다")
        XCTAssertEqual(Set(b).count, 8)
    }

    /// **시드는 `String.hashValue` 가 아니다.** 스위프트 문자열 해시는 프로세스마다 시드가
    /// 달라서 같은 모니터가 실행마다 다른 수열을 걷는다 — 그러면 여기 잠금 자체가 불가능하다.
    func testScreenSeedIsStableAcrossInstances() {
        func firstFive() -> [Int] {
            var r = runtime(PlaylistSettings(order: .random, mode: .timer), items: items(6),
                            screens: ["display-42"])
            return (0..<5).map { _ in r.nextCandidate(screenKey: "display-42", now: noon) ?? -1 }
        }
        XCTAssertEqual(firstFive(), firstFive())
    }

    func testUnpluggedScreenKeepsItsStateForWhenItComesBack() {
        var r = runtime(PlaylistSettings(delayMinutes: 10, order: .sorted, mode: .timer),
                        items: items(4), screens: ["A", "B"])
        _ = r.tick(deltaSeconds: 5, isPaused: false, now: noon, isVideo: { _ in false })
        r.setActiveScreens(["A"])                                  // B 를 뽑았다
        XCTAssertTrue(r.tick(deltaSeconds: 5, isPaused: false, now: noon, isVideo: { _ in false }).isEmpty)
        XCTAssertEqual(elapsed(r, "B"), 5, accuracy: 0.0001,
                       "뺐다 끼우는 사이에 시계가 0 으로 돌아가면 안 된다")
        r.setActiveScreens(["A", "B"])                             // 다시 끼웠다
        XCTAssertEqual(elapsed(r, "B"), 5, accuracy: 0.0001)
        XCTAssertEqual(elapsed(r, "A"), 10, accuracy: 0.0001)
    }

    func testRestoreKeepsValuesForScreensThatAreNotAttachedYet() {
        var r = runtime(PlaylistSettings(mode: .timer), items: items(3), screens: ["A"])
        r.restoreElapsed(["A": 12, "ghost": 34])
        XCTAssertEqual(r.elapsedByScreen["ghost"], 34,
                       "다음 부팅에 다시 붙을 모니터의 값을 버리지 않는다")
        XCTAssertEqual(r.elapsedByScreen["A"], 12)
    }

    func testRestoreRejectsHostileValues() {
        var r = runtime(PlaylistSettings(mode: .timer), items: items(3), screens: ["A"])
        r.restoreElapsed(["A": -5])
        XCTAssertEqual(r.scheduler(for: "A")?.elapsedSeconds, 0)
        r.restoreElapsed(["A": .nan])
        XCTAssertEqual(r.scheduler(for: "A")?.elapsedSeconds, 0, "파일은 신뢰 경계 밖이다")
    }

    // MARK: - 순서

    /// 소진형 셔플의 요점 — Waple 의 종전 `shuffleNext`(직전 1개만 회피)는 3곡에서 A,B,A,B 가
    /// 나올 수 있었다. 백은 그것을 구조적으로 막는다.
    func testExhaustiveShuffleCoversEveryItemBeforeRepeating() {
        var r = runtime(PlaylistSettings(order: .random, mode: .timer), items: items(3), screens: ["A"])
        var draws: [Int] = []
        for _ in 0..<5 {
            guard let index = r.nextCandidate(screenKey: "A", now: noon) else { return XCTFail("후보 없음") }
            draws.append(index)
            r.commit(index: index, screenKey: "A")
        }
        XCTAssertEqual(Set(draws).count, 3, "임의의 5연속 안에 3종이 전부 든다")
        XCTAssertEqual(Set(draws.prefix(3)).count, 3, "첫 백은 n 개다 — 한 바퀴 안에 반복이 없다")
    }

    func testSortedOrderWalksTheListInOrder() {
        var r = runtime(PlaylistSettings(order: .sorted, mode: .timer), items: items(3), screens: ["A"])
        let draws = (0..<5).map { _ -> Int in
            let index = r.nextCandidate(screenKey: "A", now: noon) ?? -1
            r.commit(index: index, screenKey: "A")
            return index
        }
        XCTAssertEqual(draws, [0, 1, 2, 0, 1])
    }

    func testChangingTheItemCountRebuildsTheBagInsteadOfDrawingStaleIndices() {
        var r = runtime(PlaylistSettings(order: .random, mode: .timer), items: items(8), screens: ["A"])
        _ = r.nextCandidate(screenKey: "A", now: noon)
        r.apply(settings: PlaylistSettings(order: .random, mode: .timer), items: items(2))
        for _ in 0..<20 {
            let index = r.nextCandidate(screenKey: "A", now: noon) ?? -1
            XCTAssertTrue((0..<2).contains(index), "목록이 줄었는데 옛 인덱스가 나오면 범위 밖 접근이다: \(index)")
        }
    }

    func testEmptyPlaylistNeverProducesAnAdvance() {
        var r = runtime(PlaylistSettings(delayMinutes: 0.01, mode: .timer), items: [], screens: ["A"])
        XCTAssertTrue(r.tick(deltaSeconds: 5, isPaused: false, now: noon, isVideo: { _ in false }).isEmpty)
        XCTAssertNil(r.nextCandidate(screenKey: "A", now: noon))
        XCTAssertFalse(r.shouldAdvanceOnVideoEnd(screenKey: "A"))
    }

    func testUnknownScreenKeyIsInert() {
        var r = runtime(PlaylistSettings(mode: .timer), items: items(3), screens: ["A"])
        XCTAssertNil(r.nextCandidate(screenKey: "nope", now: noon))
        XCTAssertFalse(r.shouldAdvanceOnVideoEnd(screenKey: "nope"))
        r.commit(index: 0, screenKey: "nope")   // 트랩하지 않는다
    }

    // MARK: - 시계 읽기

    func testClockReadingMovesAllThreeOriginsAtOnce() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.firstWeekday = 2   // 월요일 시작
        // 2026-08-17 은 월요일이다.
        let monday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 17,
                                                        hour: 13, minute: 45)) ?? Date()
        let reading = PlaylistClockReading(date: monday, calendar: calendar)
        XCTAssertEqual(reading.hour, 13)
        XCTAssertEqual(reading.minute, 45)
        XCTAssertEqual(reading.weekday, 1, "SYSTEMTIME 규약 — 일=0 이므로 월=1")
        XCTAssertEqual(reading.firstDayOfWeek, 0, "LOCALE_IFIRSTDAYOFWEEK 규약 — 월=0")
        XCTAssertEqual(PlaylistDayOfWeek.index(weekday: reading.weekday,
                                               firstDayOfWeek: reading.firstDayOfWeek), 0)

        calendar.firstWeekday = 1   // 일요일 시작
        XCTAssertEqual(PlaylistClockReading(date: monday, calendar: calendar).firstDayOfWeek, 6)
    }
}
