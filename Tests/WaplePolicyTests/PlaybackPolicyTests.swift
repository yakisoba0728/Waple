import XCTest
@testable import WaplePolicy

// `spec/engine/playback-policy.json` 의 `확정` 항목을 그대로 단언한다.
//
// 이 파일은 **자기 산수를 단언하지 않는다.** `SnapshotTests` 가 판정 수식을 베껴서
// 자기 계산을 확인하는 바람에 프로덕션 로직을 지워도 통과하던 전례가 있다. 여기서는
// 기대값을 전부 wallpaper64.exe 2.8.42 에서 읽은 **리터럴**로 적고, 그 근거 VA 를
// 함께 남긴다. 수식을 옮겨 적는 순간 이 테스트는 무의미해진다.

final class PlaybackActionTests: XCTestCase {

    /// 매퍼 0x140141880–0x14014191a 의 반환값. 정수 자체가 계약이다 —
    /// 전역(0x1404e53c0 계열)에 이 값이 그대로 들어가고 디스패치가 `sub 1` 사다리로 가른다.
    func testRawValuesMatchMapper() {
        XCTAssertEqual(PlaybackAction.run.rawValue, 0)
        XCTAssertEqual(PlaybackAction.mute.rawValue, 1)
        XCTAssertEqual(PlaybackAction.pause.rawValue, 2)
        XCTAssertEqual(PlaybackAction.pauseAll.rawValue, 3)
        XCTAssertEqual(PlaybackAction.stop.rawValue, 4)
    }

    func testConfigStringsRoundTrip() {
        XCTAssertEqual(PlaybackAction(weConfigValue: "run"), .run)
        XCTAssertEqual(PlaybackAction(weConfigValue: "mute"), .mute)
        XCTAssertEqual(PlaybackAction(weConfigValue: "pause"), .pause)
        XCTAssertEqual(PlaybackAction(weConfigValue: "pauseall"), .pauseAll)
        XCTAssertEqual(PlaybackAction(weConfigValue: "stop"), .stop)
        for action in PlaybackAction.allCases {
            XCTAssertEqual(PlaybackAction(weConfigValue: action.weConfigValue), action)
        }
    }

    /// 미인식은 **조용히 run** 이다(0x140141918 `xor eax, eax`). 던지지도 nil 도 아니다.
    func testUnknownStringsFallBackToRun() {
        for bogus in ["", "Run", "STOP", "pause_all", "pauseAll", "stopp", "mut", "3"] {
            XCTAssertEqual(PlaybackAction(weConfigValue: bogus), .run, "\(bogus) 가 run 이 아니다")
        }
    }

    /// 길이 4 짜리 비-"mute" 문자열은 매퍼의 마지막 비교(0x140141909)에서 0 이 된다.
    /// 길이로 먼저 가르는 구현이라 이 부류가 특히 헷갈린다.
    func testFourLetterNonMuteIsRun() {
        for bogus in ["muta", "stoq", "aaaa", "Mute"] {
            XCTAssertEqual(PlaybackAction(weConfigValue: bogus), .run)
        }
    }

    /// rawValue 순서 = 강도 사다리.
    func testComparableOrdersBySeverity() {
        XCTAssertTrue(PlaybackAction.run < .mute)
        XCTAssertTrue(PlaybackAction.mute < .pause)
        XCTAssertTrue(PlaybackAction.pause < .pauseAll)
        XCTAssertTrue(PlaybackAction.pauseAll < .stop)
        XCTAssertEqual(PlaybackAction.allCases.sorted(), [.run, .mute, .pause, .pauseAll, .stop])
        XCTAssertEqual(PlaybackAction.allCases.max(), .stop)
    }
}

final class PlaybackTriggerTests: XCTestCase {

    /// 키 문자열. VA 는 각 case 주석 참조.
    func testConfigKeys() {
        XCTAssertEqual(PlaybackTrigger.focus.weConfigKey, "playbackfocus")
        XCTAssertEqual(PlaybackTrigger.maximized.weConfigKey, "playbackmaximized")
        XCTAssertEqual(PlaybackTrigger.fullscreen.weConfigKey, "playbackfullscreen")
        XCTAssertEqual(PlaybackTrigger.audio.weConfigKey, "playbackaudio")
        XCTAssertEqual(PlaybackTrigger.displaySleep.weConfigKey, "playbacksleep")
        XCTAssertEqual(PlaybackTrigger.battery.weConfigKey, "playbackonbattery")
        XCTAssertEqual(Set(PlaybackTrigger.allCases.map(\.weConfigKey)).count, 6)
    }

    /// 기본값 설치자 0x140046f20 이 심는 리터럴. 설치본 config.json 과도 글자 그대로 같다.
    func testDefaultsMatchInstaller() {
        XCTAssertEqual(PlaybackTrigger.focus.weDefault, .run)
        XCTAssertEqual(PlaybackTrigger.maximized.weDefault, .pause)
        XCTAssertEqual(PlaybackTrigger.fullscreen.weDefault, .pause)
        XCTAssertEqual(PlaybackTrigger.audio.weDefault, .run)
        XCTAssertEqual(PlaybackTrigger.displaySleep.weDefault, .stop)
        XCTAssertEqual(PlaybackTrigger.battery.weDefault, .run)
    }

    /// UI 옵션 빌더 `k(multimonitor, allowMute, allowStop)` 의 산출물.
    /// 순서까지 본다 — 드롭리스트 순서가 곧 사용자가 보는 순서다.
    func testAllowedActionsSingleMonitor() {
        XCTAssertEqual(PlaybackTrigger.focus.allowedActions(multiMonitor: false),
                       [.run, .mute, .pause])
        XCTAssertEqual(PlaybackTrigger.maximized.allowedActions(multiMonitor: false),
                       [.run, .mute, .pause, .stop])
        XCTAssertEqual(PlaybackTrigger.fullscreen.allowedActions(multiMonitor: false),
                       [.run, .mute, .pause, .stop])
        XCTAssertEqual(PlaybackTrigger.audio.allowedActions(multiMonitor: false),
                       [.run, .mute, .pause])
        XCTAssertEqual(PlaybackTrigger.displaySleep.allowedActions(multiMonitor: false),
                       [.run, .pause, .stop])
        XCTAssertEqual(PlaybackTrigger.battery.allowedActions(multiMonitor: false),
                       [.run, .pause, .stop])
    }

    func testAllowedActionsMultiMonitor() {
        XCTAssertEqual(PlaybackTrigger.focus.allowedActions(multiMonitor: true),
                       [.run, .mute, .pause, .pauseAll])
        XCTAssertEqual(PlaybackTrigger.maximized.allowedActions(multiMonitor: true),
                       [.run, .mute, .pause, .pauseAll, .stop])
        XCTAssertEqual(PlaybackTrigger.fullscreen.allowedActions(multiMonitor: true),
                       [.run, .mute, .pause, .pauseAll, .stop])
        // audio·sleep·battery 는 빌더 첫 인자가 리터럴 `!1` 이라 모니터 수와 무관하다.
        XCTAssertEqual(PlaybackTrigger.audio.allowedActions(multiMonitor: true),
                       [.run, .mute, .pause])
        XCTAssertEqual(PlaybackTrigger.displaySleep.allowedActions(multiMonitor: true),
                       [.run, .pause, .stop])
        XCTAssertEqual(PlaybackTrigger.battery.allowedActions(multiMonitor: true),
                       [.run, .pause, .stop])
    }

    /// `run` 은 어느 축에서도 빠지지 않고, `pauseall` 은 **창 상태 세 축**이
    /// 멀티모니터일 때만 는다.
    func testRunAlwaysOfferedAndPauseAllOnlyGrows() {
        let honorsMultiMonitor: Set<PlaybackTrigger> = [.focus, .maximized, .fullscreen]
        for trigger in PlaybackTrigger.allCases {
            let single = trigger.allowedActions(multiMonitor: false)
            let multi = trigger.allowedActions(multiMonitor: true)
            XCTAssertEqual(single.first, .run)
            XCTAssertFalse(single.contains(.pauseAll))
            XCTAssertTrue(Set(single).isSubset(of: Set(multi)))
            XCTAssertEqual(Set(multi).subtracting(Set(single)),
                           honorsMultiMonitor.contains(trigger) ? [.pauseAll] : [],
                           "\(trigger.weConfigKey)")
        }
    }

    /// 엔진이 `pauseall`(액션 3) 분기를 갖는 축과 UI 가 제시하는 축이 같은 집합인지.
    /// 갈리면 사용자가 고를 수 없는 동작이 생기거나 그 반대가 된다.
    func testPauseAllOfferedOnlyWhereEngineHandlesIt() {
        for trigger in PlaybackTrigger.allCases {
            let offered = trigger.allowedActions(multiMonitor: true).contains(.pauseAll)
            XCTAssertEqual(offered, [.focus, .maximized, .fullscreen].contains(trigger),
                           "\(trigger.weConfigKey)")
        }
    }
}

final class PlaybackPolicyValueTests: XCTestCase {

    func testWeDefaultMatchesInstalledConfig() {
        let policy = PlaybackPolicy.weDefault
        XCTAssertEqual(policy.focus, .run)
        XCTAssertEqual(policy.maximized, .pause)
        XCTAssertEqual(policy.fullscreen, .pause)
        XCTAssertEqual(policy.audio, .run)
        XCTAssertEqual(policy.displaySleep, .stop)
        XCTAssertEqual(policy.battery, .run)
        XCTAssertFalse(policy.pauseVRAM)
    }

    /// `weDefault` 와 각 축의 `weDefault` 가 갈리면 어느 쪽이 정본인지 알 수 없다.
    func testWeDefaultAgreesWithPerTriggerDefault() {
        for trigger in PlaybackTrigger.allCases {
            XCTAssertEqual(PlaybackPolicy.weDefault[trigger], trigger.weDefault,
                           "\(trigger.weConfigKey) 의 기본값이 두 자리에서 다르다")
        }
    }

    /// 빈 설정 = 설치자가 전부 심은 상태.
    func testEmptyConfigYieldsDefaults() {
        XCTAssertEqual(PlaybackPolicy(weConfig: [:]), PlaybackPolicy.weDefault)
    }

    /// 설치본 config.json 의 `general/user` 실값.
    func testInstalledConfigParses() {
        let policy = PlaybackPolicy(weConfig: [
            "playbackfocus": "run",
            "playbackmaximized": "pause",
            "playbackfullscreen": "pause",
            "playbackaudio": "run",
            "playbacksleep": "stop",
            "playbackonbattery": "run",
        ], pauseVRAM: false)
        XCTAssertEqual(policy, PlaybackPolicy.weDefault)
    }

    /// 키가 **있는데 값이 이상하면** 기본값이 아니라 `run` 이다. 키가 없을 때와 다르다.
    func testPresentButUnknownValueIsRunNotDefault() {
        let policy = PlaybackPolicy(weConfig: ["playbacksleep": "hibernate"])
        XCTAssertEqual(policy.displaySleep, .run)
        XCTAssertEqual(PlaybackPolicy(weConfig: [:]).displaySleep, .stop)
    }

    func testSubscriptGetAndSet() {
        var policy = PlaybackPolicy.weDefault
        for trigger in PlaybackTrigger.allCases {
            policy[trigger] = .pauseAll
            XCTAssertEqual(policy[trigger], .pauseAll)
        }
        XCTAssertEqual(policy.focus, .pauseAll)
        XCTAssertEqual(policy.battery, .pauseAll)
    }
}

final class PlaybackVerdictTests: XCTestCase {

    func testIsPausedReadsBitPerMonitorIndex() {
        let verdict = PlaybackVerdict(stop: false, muted: false, pauseMask: 0b1010)
        XCTAssertFalse(verdict.isPaused(monitorIndex: 0))
        XCTAssertTrue(verdict.isPaused(monitorIndex: 1))
        XCTAssertFalse(verdict.isPaused(monitorIndex: 2))
        XCTAssertTrue(verdict.isPaused(monitorIndex: 3))
    }

    func testAllOnesPausesEveryMonitor() {
        let verdict = PlaybackVerdict(stop: false, muted: false, pauseMask: .max)
        for index in 0..<32 {
            XCTAssertTrue(verdict.isPaused(monitorIndex: index))
        }
    }

    /// 실물의 `bt eax, ecx`(0x140073a64)는 오프셋을 32로 접는다. 마스크를 만드는
    /// `shl r8d, cl`(0x140074d4a)도 같으므로 두 쪽이 맞물린다.
    func testIndexWrapsAtThirtyTwoLikeHardware() {
        let verdict = PlaybackVerdict(stop: false, muted: false, pauseMask: 1)
        XCTAssertTrue(verdict.isPaused(monitorIndex: 0))
        XCTAssertTrue(verdict.isPaused(monitorIndex: 32))
        XCTAssertTrue(verdict.isPaused(monitorIndex: 64))
        XCTAssertFalse(verdict.isPaused(monitorIndex: 33))
    }

    func testNegativeIndexIsNotPaused() {
        let verdict = PlaybackVerdict(stop: false, muted: false, pauseMask: .max)
        XCTAssertFalse(verdict.isPaused(monitorIndex: -1))
    }

    func testRunningIsInert() {
        XCTAssertFalse(PlaybackVerdict.running.stop)
        XCTAssertFalse(PlaybackVerdict.running.muted)
        XCTAssertEqual(PlaybackVerdict.running.pauseMask, 0)
    }

    func testMaskBuilder() {
        XCTAssertEqual(PlaybackConditions.mask(monitorIndices: []), 0)
        XCTAssertEqual(PlaybackConditions.mask(monitorIndices: [0]), 1)
        XCTAssertEqual(PlaybackConditions.mask(monitorIndices: [0, 1, 2]), 0b111)
        XCTAssertEqual(PlaybackConditions.mask(monitorIndices: [31]), 0x8000_0000)
        XCTAssertEqual(PlaybackConditions.mask(monitorIndices: [-1]), 0)
    }
}

final class PlaybackEvaluatorTests: XCTestCase {

    /// 모니터 둘, 독립 배치. 0번만 조건이 걸린 상황을 만든다.
    private func twoMonitors(
        layout: MonitorLayout = .perMonitor,
        fullscreen: UInt32 = 0,
        maximized: UInt32 = 0,
        unfocused: UInt32 = 0
    ) -> PlaybackConditions {
        PlaybackConditions(
            layout: layout,
            allMonitorsMask: 0b11,
            unfocusedMask: unfocused,
            maximizedMask: maximized,
            fullscreenMask: fullscreen
        )
    }

    func testNoConditionsYieldRunning() {
        let verdict = PlaybackEvaluator.evaluate(.weDefault, twoMonitors())
        XCTAssertEqual(verdict, .running)
    }

    // MARK: fullscreen 축 (0x14006d111–0x14006d176)

    func testFullscreenStop() {
        var policy = PlaybackPolicy.weDefault
        policy.fullscreen = .stop
        let verdict = PlaybackEvaluator.evaluate(policy, twoMonitors(fullscreen: 0b01))
        XCTAssertTrue(verdict.stop)
        XCTAssertEqual(verdict.pauseMask, 0)
        XCTAssertFalse(verdict.muted)
    }

    func testFullscreenPausePerMonitorPausesExactlyThatMonitor() {
        let verdict = PlaybackEvaluator.evaluate(.weDefault, twoMonitors(fullscreen: 0b10))
        XCTAssertFalse(verdict.stop)
        XCTAssertEqual(verdict.pauseMask, 0b10)
        XCTAssertFalse(verdict.isPaused(monitorIndex: 0))
        XCTAssertTrue(verdict.isPaused(monitorIndex: 1))
    }

    /// 벽지가 전 모니터를 덮으면 **전부 가려졌을 때만** 멈춘다
    /// (0x14006d162 `cmp r10d, r8d / cmove r15d, r11d`).
    func testFullscreenPauseSpanningNeedsAllMonitors() {
        let partial = PlaybackEvaluator.evaluate(
            .weDefault, twoMonitors(layout: .stretch, fullscreen: 0b01))
        XCTAssertEqual(partial.pauseMask, 0)

        let full = PlaybackEvaluator.evaluate(
            .weDefault, twoMonitors(layout: .stretch, fullscreen: 0b11))
        XCTAssertEqual(full.pauseMask, .max)
    }

    func testFullscreenPauseCloneBehavesLikeStretch() {
        let full = PlaybackEvaluator.evaluate(
            .weDefault, twoMonitors(layout: .clone, fullscreen: 0b11))
        XCTAssertEqual(full.pauseMask, .max)
    }

    func testFullscreenPauseAllIgnoresLayout() {
        var policy = PlaybackPolicy.weDefault
        policy.fullscreen = .pauseAll
        for layout in MonitorLayout.allCases {
            let verdict = PlaybackEvaluator.evaluate(
                policy, twoMonitors(layout: layout, fullscreen: 0b01))
            XCTAssertEqual(verdict.pauseMask, .max, "layout \(layout)")
        }
    }

    func testFullscreenMuteIsGlobal() {
        var policy = PlaybackPolicy.weDefault
        policy.fullscreen = .mute
        let verdict = PlaybackEvaluator.evaluate(policy, twoMonitors(fullscreen: 0b01))
        XCTAssertTrue(verdict.muted)
        XCTAssertEqual(verdict.pauseMask, 0)
    }

    // MARK: maximized 축 (0x14006d176–0x14006d1e4)

    /// layout != 0 이면 최대화 마스크가 전체화면 마스크를 흡수한다(0x14006d108 `or ecx, r8d`).
    func testMaximizedAbsorbsFullscreenMaskWhenSpanning() {
        var policy = PlaybackPolicy.weDefault
        policy.fullscreen = .run
        policy.maximized = .pause
        // 두 모니터 중 하나는 전체화면, 하나는 최대화 → 합치면 전 모니터가 가려진다.
        let spanning = PlaybackEvaluator.evaluate(
            policy, twoMonitors(layout: .stretch, fullscreen: 0b01, maximized: 0b10))
        XCTAssertEqual(spanning.pauseMask, .max)

        // 독립 배치면 흡수가 없으므로 최대화된 모니터만 멈춘다.
        let independent = PlaybackEvaluator.evaluate(
            policy, twoMonitors(layout: .perMonitor, fullscreen: 0b01, maximized: 0b10))
        XCTAssertEqual(independent.pauseMask, 0b10)
    }

    /// 두 축이 각각 마스크를 내면 OR 로 합쳐진다.
    func testFullscreenAndMaximizedMasksCombine() {
        var policy = PlaybackPolicy.weDefault
        policy.fullscreen = .pause
        policy.maximized = .pause
        let verdict = PlaybackEvaluator.evaluate(
            policy, twoMonitors(fullscreen: 0b01, maximized: 0b10))
        XCTAssertEqual(verdict.pauseMask, 0b11)
    }

    // MARK: focus 축 (0x14006d1e4–0x14006d21f)

    func testFocusAxisSkippedWhenMaskEmpty() {
        var policy = PlaybackPolicy.weDefault
        policy.focus = .pauseAll
        XCTAssertEqual(PlaybackEvaluator.evaluate(policy, twoMonitors()).pauseMask, 0)
    }

    func testFocusPausePerMonitor() {
        var policy = PlaybackPolicy.weDefault
        policy.focus = .pause
        let verdict = PlaybackEvaluator.evaluate(policy, twoMonitors(unfocused: 0b01))
        XCTAssertEqual(verdict.pauseMask, 0b01)
    }

    /// focus 의 spanning 분기는 fullscreen 과 다르다 — 전 모니터를 요구하지 않고
    /// 마스크가 비지 않기만 하면 전체를 멈춘다(0x14006d20d–0x14006d216).
    func testFocusPauseSpanningPausesAllOnAnyMonitor() {
        var policy = PlaybackPolicy.weDefault
        policy.focus = .pause
        let verdict = PlaybackEvaluator.evaluate(
            policy, twoMonitors(layout: .stretch, unfocused: 0b01))
        XCTAssertEqual(verdict.pauseMask, .max)
    }

    /// focus 에는 stop 분기가 아예 없다. 설정에 `stop` 을 넣어도 무동작이다.
    func testFocusStopIsNoOp() {
        var policy = PlaybackPolicy.weDefault
        policy.fullscreen = .run
        policy.maximized = .run
        policy.focus = .stop
        let verdict = PlaybackEvaluator.evaluate(policy, twoMonitors(unfocused: 0b11))
        XCTAssertEqual(verdict, .running)
    }

    func testFocusMute() {
        var policy = PlaybackPolicy.weDefault
        policy.focus = .mute
        let verdict = PlaybackEvaluator.evaluate(policy, twoMonitors(unfocused: 0b01))
        XCTAssertTrue(verdict.muted)
        XCTAssertEqual(verdict.pauseMask, 0)
    }

    // MARK: audio 축 (0x14006d21f–0x14006d26c)

    func testAudioPausePausesEveryMonitorRegardlessOfLayout() {
        var policy = PlaybackPolicy.weDefault
        policy.audio = .pause
        for layout in MonitorLayout.allCases {
            var conditions = twoMonitors(layout: layout)
            conditions.audioPlaying = true
            XCTAssertEqual(PlaybackEvaluator.evaluate(policy, conditions).pauseMask, .max,
                           "layout \(layout)")
        }
    }

    func testAudioMute() {
        var policy = PlaybackPolicy.weDefault
        policy.audio = .mute
        var conditions = twoMonitors()
        conditions.audioPlaying = true
        XCTAssertTrue(PlaybackEvaluator.evaluate(policy, conditions).muted)
    }

    func testAudioPauseAllAndStopAreNoOps() {
        var conditions = twoMonitors()
        conditions.audioPlaying = true
        for action in [PlaybackAction.pauseAll, .stop] {
            var policy = PlaybackPolicy.weDefault
            policy.fullscreen = .run
            policy.maximized = .run
            policy.audio = action
            XCTAssertEqual(PlaybackEvaluator.evaluate(policy, conditions), .running,
                           "audio = \(action.weConfigValue)")
        }
    }

    func testAudioAxisSkippedWhenNothingPlaying() {
        var policy = PlaybackPolicy.weDefault
        policy.audio = .pause
        XCTAssertEqual(PlaybackEvaluator.evaluate(policy, twoMonitors()).pauseMask, 0)
    }

    // MARK: battery 축 (0x14006d28c–0x14006d2b4)

    func testBatteryStop() {
        var policy = PlaybackPolicy.weDefault
        policy.battery = .stop
        var conditions = twoMonitors()
        conditions.onBattery = true
        XCTAssertTrue(PlaybackEvaluator.evaluate(policy, conditions).stop)
    }

    func testBatteryPausePausesEveryMonitor() {
        var policy = PlaybackPolicy.weDefault
        policy.battery = .pause
        var conditions = twoMonitors()
        conditions.onBattery = true
        XCTAssertEqual(PlaybackEvaluator.evaluate(policy, conditions).pauseMask, .max)
    }

    func testBatteryMuteAndPauseAllAreNoOps() {
        var conditions = twoMonitors()
        conditions.onBattery = true
        for action in [PlaybackAction.mute, .pauseAll] {
            var policy = PlaybackPolicy.weDefault
            policy.fullscreen = .run
            policy.maximized = .run
            policy.battery = action
            XCTAssertEqual(PlaybackEvaluator.evaluate(policy, conditions), .running,
                           "battery = \(action.weConfigValue)")
        }
    }

    func testBatteryAxisSkippedOnMains() {
        var policy = PlaybackPolicy.weDefault
        policy.battery = .stop
        XCTAssertFalse(PlaybackEvaluator.evaluate(policy, twoMonitors()).stop)
    }

    // MARK: displaySleep (0x14006ed90–0x14006edc8)

    func testSleepStop() {
        var conditions = twoMonitors()
        conditions.displayAsleep = true
        // 기본 정책의 sleep 이 이미 stop 이다.
        XCTAssertTrue(PlaybackEvaluator.evaluate(.weDefault, conditions).stop)
    }

    func testSleepPausePausesEveryMonitor() {
        var policy = PlaybackPolicy.weDefault
        policy.displaySleep = .pause
        var conditions = twoMonitors()
        conditions.displayAsleep = true
        let verdict = PlaybackEvaluator.evaluate(policy, conditions)
        XCTAssertFalse(verdict.stop)
        XCTAssertEqual(verdict.pauseMask, .max)
    }

    /// sleep 이 pause/stop 이 **아니면** bit5 가 서지 않으므로 절전 중에도
    /// 다른 축이 평소대로 평가된다(핸들러가 0x14006edc8 `ret` 으로 빠진다).
    func testSleepRunLeavesOtherAxesAlone() {
        for action in [PlaybackAction.run, .mute, .pauseAll] {
            var policy = PlaybackPolicy.weDefault
            policy.displaySleep = action
            policy.fullscreen = .pause
            var conditions = twoMonitors(fullscreen: 0b10)
            conditions.displayAsleep = true
            let verdict = PlaybackEvaluator.evaluate(policy, conditions)
            XCTAssertFalse(verdict.stop, "sleep = \(action.weConfigValue)")
            XCTAssertEqual(verdict.pauseMask, 0b10, "sleep = \(action.weConfigValue)")
        }
    }

    // MARK: 우선순위 stop ≻ displaySleep ≻ (pauseMask, mute)

    /// stop 이 서면 pause/mute 는 **갱신조차 되지 않는다**(0x14006d453 `test bl,bl / jne`).
    func testStopHidesPauseAndMute() {
        var policy = PlaybackPolicy.weDefault
        policy.fullscreen = .stop
        policy.maximized = .mute
        policy.focus = .pause
        let verdict = PlaybackEvaluator.evaluate(
            policy, twoMonitors(fullscreen: 0b01, maximized: 0b11, unfocused: 0b11))
        XCTAssertTrue(verdict.stop)
        XCTAssertFalse(verdict.muted)
        XCTAssertEqual(verdict.pauseMask, 0)
    }

    /// 절전 래치가 서면 축이 만든 마스크·음소거가 버려지고 전 모니터 정지가 된다
    /// (0x14006d45b–0x14006d463 조기 이탈 + 적용기 0x140073a4f 의 `test bpl, 0x21`).
    func testDisplaySleepHidesAxisPauseAndMute() {
        var policy = PlaybackPolicy.weDefault
        policy.displaySleep = .pause
        policy.fullscreen = .pause
        policy.maximized = .mute
        var conditions = twoMonitors(fullscreen: 0b01, maximized: 0b01)
        conditions.displayAsleep = true
        let verdict = PlaybackEvaluator.evaluate(policy, conditions)
        XCTAssertFalse(verdict.stop)
        XCTAssertFalse(verdict.muted)
        XCTAssertEqual(verdict.pauseMask, .max)
    }

    /// stop 이 절전보다 세다.
    func testStopBeatsDisplaySleep() {
        var policy = PlaybackPolicy.weDefault
        policy.displaySleep = .pause
        policy.battery = .stop
        var conditions = twoMonitors()
        conditions.displayAsleep = true
        conditions.onBattery = true
        let verdict = PlaybackEvaluator.evaluate(policy, conditions)
        XCTAssertTrue(verdict.stop)
        XCTAssertEqual(verdict.pauseMask, 0)
    }

    // MARK: 플래그 경유 정지 (0x14006d407 `test ecx, 0x408`)

    /// pausevram 은 pause 가 아니라 **stop** 으로 승격된다.
    func testVRAMPressurePromotesToStopNotPause() {
        var conditions = twoMonitors()
        conditions.vramPressure = true
        let verdict = PlaybackEvaluator.evaluate(.weDefault, conditions)
        XCTAssertTrue(verdict.stop)
        XCTAssertEqual(verdict.pauseMask, 0)
    }

    func testExternalStopRequestStops() {
        var conditions = twoMonitors()
        conditions.externalStopRequest = true
        XCTAssertTrue(PlaybackEvaluator.evaluate(.weDefault, conditions).stop)
    }

    // MARK: 플래그 override (0x14006d26c–0x14006d288)

    /// bit1 은 축이 만든 마스크를 통째로 지운다.
    func testUnpauseAeroClearsMask() {
        var conditions = twoMonitors(fullscreen: 0b11)
        conditions.unpauseAero = true
        XCTAssertEqual(PlaybackEvaluator.evaluate(.weDefault, conditions).pauseMask, 0)
    }

    /// **순서가 계약이다** — bit1 이 battery 축보다 앞이라 배터리 pause 가 다시 덮는다.
    func testBatteryPauseOverridesUnpauseAero() {
        var policy = PlaybackPolicy.weDefault
        policy.battery = .pause
        var conditions = twoMonitors(fullscreen: 0b11)
        conditions.unpauseAero = true
        conditions.onBattery = true
        XCTAssertEqual(PlaybackEvaluator.evaluate(policy, conditions).pauseMask, .max)
    }

    func testForcePauseAll() {
        var conditions = twoMonitors()
        conditions.forcePauseAll = true
        XCTAssertEqual(PlaybackEvaluator.evaluate(.weDefault, conditions).pauseMask, .max)
    }

    /// bit22 가 bit1 뒤에 오므로 둘이 함께 서면 전체 정지가 이긴다.
    func testForcePauseAllBeatsUnpauseAero() {
        var conditions = twoMonitors()
        conditions.unpauseAero = true
        conditions.forcePauseAll = true
        XCTAssertEqual(PlaybackEvaluator.evaluate(.weDefault, conditions).pauseMask, .max)
    }

    func testExternalPauseAndMuteRequests() {
        var conditions = twoMonitors()
        conditions.externalPauseRequest = true
        conditions.externalMuteRequest = true
        let verdict = PlaybackEvaluator.evaluate(.weDefault, conditions)
        XCTAssertFalse(verdict.stop)
        XCTAssertTrue(verdict.muted)
        XCTAssertEqual(verdict.pauseMask, .max)
    }

    // MARK: UI 표와 엔진의 대응

    /// UI 가 제시하지 않는 액션은 엔진에서 **무동작**이어야 한다 — 즉 `run` 과 같은 판정.
    /// 단 하나 예외가 `pauseall` 이다(UI 는 단일 모니터에서 숨기지만 엔진은 처리한다).
    /// 그 자리는 모니터가 하나면 `pause` 와 관측상 같다는 것을 따로 확인한다.
    func testActionsOutsideAllowedTableAreInert() {
        let conditions = PlaybackConditions(
            layout: .perMonitor,
            allMonitorsMask: 0b11,
            unfocusedMask: 0b11,
            maximizedMask: 0b11,
            fullscreenMask: 0b11,
            audioPlaying: true,
            displayAsleep: true,
            onBattery: true
        )
        for trigger in PlaybackTrigger.allCases {
            let allowed = Set(trigger.allowedActions(multiMonitor: true))
            for action in PlaybackAction.allCases where !allowed.contains(action) {
                var quiet = PlaybackPolicy(
                    focus: .run, maximized: .run, fullscreen: .run,
                    audio: .run, displaySleep: .run, battery: .run)
                quiet[trigger] = action
                XCTAssertEqual(PlaybackEvaluator.evaluate(quiet, conditions), .running,
                               "\(trigger.weConfigKey) = \(action.weConfigValue) 가 무동작이 아니다")
            }
        }
    }

    /// 모니터가 하나면 `pause` 와 `pauseall` 이 관측상 같다 — UI 가 `pauseall` 을
    /// 숨겨도 사용자가 잃는 것이 없다는 근거다.
    func testPauseAndPauseAllAgreeOnSingleMonitor() {
        let conditions = PlaybackConditions(
            layout: .perMonitor, allMonitorsMask: 1, fullscreenMask: 1)
        var pausePolicy = PlaybackPolicy.weDefault
        pausePolicy.fullscreen = .pause
        var pauseAllPolicy = PlaybackPolicy.weDefault
        pauseAllPolicy.fullscreen = .pauseAll
        let a = PlaybackEvaluator.evaluate(pausePolicy, conditions)
        let b = PlaybackEvaluator.evaluate(pauseAllPolicy, conditions)
        XCTAssertTrue(a.isPaused(monitorIndex: 0))
        XCTAssertTrue(b.isPaused(monitorIndex: 0))
        XCTAssertEqual(a.stop, b.stop)
        XCTAssertEqual(a.muted, b.muted)
    }

    /// 순수 함수인지 — 같은 입력이면 같은 출력이고 입력을 건드리지 않는다.
    func testEvaluateIsPure() {
        let conditions = twoMonitors(fullscreen: 0b01, maximized: 0b10, unfocused: 0b11)
        let policy = PlaybackPolicy.weDefault
        let first = PlaybackEvaluator.evaluate(policy, conditions)
        let second = PlaybackEvaluator.evaluate(policy, conditions)
        XCTAssertEqual(first, second)
        XCTAssertEqual(policy, .weDefault)
        XCTAssertEqual(conditions.maximizedMask, 0b10, "입력 마스크가 변형됐다")
    }
}

final class VRAMHysteresisTests: XCTestCase {

    /// 실물 상수. 0.8 과 0.35 는 바이너리에 각각 0.800000011920929 · 0.3499999940395355
    /// 로 들어 있는데 그것이 곧 `Float(0.8)` · `Float(0.35)` 다.
    func testThresholdConstants() {
        XCTAssertEqual(VRAMHysteresis.enterFraction, 0.8)
        XCTAssertEqual(VRAMHysteresis.releaseFraction, 0.75)
        XCTAssertEqual(VRAMHysteresis.immediateReleaseFraction, 0.35)
        XCTAssertEqual(VRAMHysteresis.sustainSeconds, 15.0)
        XCTAssertEqual(VRAMHysteresis.minimumSampleCount, 2)
        XCTAssertEqual(VRAMHysteresis.minimumTotalMegabytes, 2049)
        XCTAssertEqual(VRAMHysteresis.maximumTotalMegabytes, 131071)
    }

    /// 총 8192MB → 진입선 6553.6MB.
    func testEntersAtEightyPercent() {
        var state = VRAMHysteresis()
        XCTAssertFalse(state.update(usedMegabytes: 6553.0, totalMegabytes: 8192,
                                    sampleCount: 2, deltaSeconds: 1))
        XCTAssertTrue(state.update(usedMegabytes: 6554.0, totalMegabytes: 8192,
                                   sampleCount: 2, deltaSeconds: 1))
        XCTAssertTrue(state.isEngaged)
    }

    /// 표본이 2개 미만이면 실물은 통째로 건너뛴다 — 래치를 세우지도 지우지도 않는다.
    func testSampleCountGateLeavesLatchUntouched() {
        var state = VRAMHysteresis()
        XCTAssertFalse(state.update(usedMegabytes: 8000, totalMegabytes: 8192,
                                    sampleCount: 1, deltaSeconds: 1))
        XCTAssertFalse(state.isEngaged)

        var engaged = VRAMHysteresis(isEngaged: true)
        XCTAssertTrue(engaged.update(usedMegabytes: 0, totalMegabytes: 8192,
                                     sampleCount: 1, deltaSeconds: 100))
        XCTAssertTrue(engaged.isEngaged, "게이트에 걸렸는데 래치가 풀렸다")
    }

    /// 총량이 [2049, 131071] MB 밖이면 역시 건너뛴다.
    func testTotalRangeGate() {
        var low = VRAMHysteresis()
        XCTAssertFalse(low.update(usedMegabytes: 2048, totalMegabytes: 2048,
                                  sampleCount: 2, deltaSeconds: 1))
        var high = VRAMHysteresis()
        XCTAssertFalse(high.update(usedMegabytes: 131_072, totalMegabytes: 131_072,
                                   sampleCount: 2, deltaSeconds: 1))
        var edgeLow = VRAMHysteresis()
        XCTAssertTrue(edgeLow.update(usedMegabytes: 2049, totalMegabytes: 2049,
                                     sampleCount: 2, deltaSeconds: 1))
        var edgeHigh = VRAMHysteresis()
        XCTAssertTrue(edgeHigh.update(usedMegabytes: 131_071, totalMegabytes: 131_071,
                                      sampleCount: 2, deltaSeconds: 1))
    }

    /// 복귀에는 **15초 초과 + 75% 미만** 이 함께 필요하다.
    func testReleaseNeedsBothSustainAndSeventyFivePercent() {
        var state = VRAMHysteresis()
        state.update(usedMegabytes: 7000, totalMegabytes: 8192, sampleCount: 2, deltaSeconds: 1)
        XCTAssertTrue(state.isEngaged)

        // 76% 로 내려와도(진입선 아래) 복귀선 위라 계속 걸려 있다.
        for _ in 0..<30 {
            state.update(usedMegabytes: 6300, totalMegabytes: 8192,
                         sampleCount: 2, deltaSeconds: 1)
        }
        XCTAssertTrue(state.isEngaged, "76% 인데 풀렸다")

        // 70% 로 내려오고 15초가 **넘어야** 풀린다. 위 30초 누적이 이미 조건을 채웠으므로
        // 한 틱이면 풀린다.
        XCTAssertFalse(state.update(usedMegabytes: 5734, totalMegabytes: 8192,
                                    sampleCount: 2, deltaSeconds: 1))
    }

    /// 15초는 **초과** 조건이다(`comiss xmm0, 15.0 / jbe`). 정확히 15초면 아직 아니다.
    func testFifteenSecondsExactIsNotEnough() {
        var state = VRAMHysteresis()
        state.update(usedMegabytes: 7000, totalMegabytes: 8192, sampleCount: 2, deltaSeconds: 1)
        for _ in 0..<15 {
            state.update(usedMegabytes: 5000, totalMegabytes: 8192,
                         sampleCount: 2, deltaSeconds: 1)
        }
        XCTAssertEqual(state.secondsBelowEnterThreshold, 15.0)
        XCTAssertTrue(state.isEngaged, "15.0초에 이미 풀렸다")
        XCTAssertFalse(state.update(usedMegabytes: 5000, totalMegabytes: 8192,
                                    sampleCount: 2, deltaSeconds: 1))
    }

    /// 35% 미만이면 시간을 안 채워도 즉시 풀린다.
    func testImmediateReleaseBelowThirtyFivePercent() {
        var state = VRAMHysteresis()
        state.update(usedMegabytes: 7000, totalMegabytes: 8192, sampleCount: 2, deltaSeconds: 1)
        XCTAssertTrue(state.isEngaged)
        XCTAssertFalse(state.update(usedMegabytes: 2000, totalMegabytes: 8192,
                                    sampleCount: 2, deltaSeconds: 0.016))
        XCTAssertFalse(state.isEngaged)
    }

    /// 35% 를 **넘으면** 즉시 복귀는 없다. 8192 * 0.35 = 2867.2.
    func testJustAboveThirtyFivePercentDoesNotReleaseImmediately() {
        var state = VRAMHysteresis()
        state.update(usedMegabytes: 7000, totalMegabytes: 8192, sampleCount: 2, deltaSeconds: 1)
        XCTAssertTrue(state.update(usedMegabytes: 2868, totalMegabytes: 8192,
                                   sampleCount: 2, deltaSeconds: 0.016))
    }

    /// 진입선 위로 다시 올라가면 타이머가 0 으로 되돌아간다(0x14006d39b).
    func testTimerResetsOnReEntry() {
        var state = VRAMHysteresis()
        state.update(usedMegabytes: 7000, totalMegabytes: 8192, sampleCount: 2, deltaSeconds: 1)
        for _ in 0..<14 {
            state.update(usedMegabytes: 5000, totalMegabytes: 8192,
                         sampleCount: 2, deltaSeconds: 1)
        }
        XCTAssertEqual(state.secondsBelowEnterThreshold, 14.0)
        state.update(usedMegabytes: 7000, totalMegabytes: 8192, sampleCount: 2, deltaSeconds: 1)
        XCTAssertEqual(state.secondsBelowEnterThreshold, 0.0)
        XCTAssertTrue(state.isEngaged)
    }

    /// 래치가 안 서 있으면 타이머도 돌지 않는다(0x14006d3ad `test al,1 / je`).
    func testTimerDoesNotRunWhileDisengaged() {
        var state = VRAMHysteresis()
        for _ in 0..<100 {
            state.update(usedMegabytes: 100, totalMegabytes: 8192,
                         sampleCount: 2, deltaSeconds: 1)
        }
        XCTAssertEqual(state.secondsBelowEnterThreshold, 0.0)
        XCTAssertFalse(state.isEngaged)
    }

    /// NaN 은 실물의 `comiss / jb` 에서 복귀 경로로 간다 — 진입이 아니다.
    func testNaNDoesNotEngage() {
        var state = VRAMHysteresis()
        XCTAssertFalse(state.update(usedMegabytes: .nan, totalMegabytes: 8192,
                                    sampleCount: 2, deltaSeconds: 1))
        XCTAssertFalse(state.isEngaged)
    }

    /// 히스테리시스가 실제로 히스테리시스인지 — 78% 는 진입도 복귀도 아니다.
    func testBandBetweenSeventyFiveAndEightyIsSticky() {
        var idle = VRAMHysteresis()
        XCTAssertFalse(idle.update(usedMegabytes: 6390, totalMegabytes: 8192,
                                   sampleCount: 2, deltaSeconds: 1))

        var engaged = VRAMHysteresis(isEngaged: true, secondsBelowEnterThreshold: 100)
        XCTAssertTrue(engaged.update(usedMegabytes: 6390, totalMegabytes: 8192,
                                     sampleCount: 2, deltaSeconds: 1))
    }

    /// 히스테리시스 출력이 곧 `PlaybackConditions.vramPressure` 이고, 그것은 stop 이다.
    func testEngagedStateFeedsStopVerdict() {
        var state = VRAMHysteresis()
        state.update(usedMegabytes: 8000, totalMegabytes: 8192, sampleCount: 2, deltaSeconds: 1)
        var conditions = PlaybackConditions(allMonitorsMask: 0b11)
        conditions.vramPressure = state.isEngaged
        XCTAssertTrue(PlaybackEvaluator.evaluate(.weDefault, conditions).stop)
    }
}
