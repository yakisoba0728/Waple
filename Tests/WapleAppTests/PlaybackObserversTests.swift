import XCTest
import CoreGraphics
// [2026-08-26] **전원 상수는 `IOKit.ps` 에 있다.** 애플의 `IOKit` 우산 헤더는 `ps/` 를 포함하지
// 않아서 `import IOKit` 만으로는 `kIOPMBatteryPowerKey` 가 안 보인다. 반면 리눅스 심은 서브모듈이
// 없는 단일 모듈(`linux-shim/iokit.swift`)이라 `import IOKit.ps` 가 없다. 그래서 조건부로 받는다 —
// 쓰는 심볼은 양쪽이 같으므로 이 분기 아래로는 코드가 갈리지 않는다.
#if canImport(IOKit.ps)
import IOKit.ps
#else
import IOKit
#endif
@testable import Waple
import WaplePolicy

/// stage 2b 관측자의 **순수 판정 층**.
///
/// 플랫폼 리더(`currentPowerSourceType()` · `defaultOutputDeviceIsRunning()`)는 여기서 검증하지
/// 않는다 — 못 한다. 리눅스 심은 값이 전부 가짜고(각 심 머리말), macOS CI 러너에는 배터리도
/// 데스크탑도 없다. 그래서 리더는 **타입만** 검증되고, 판정 규칙은 전부 이 파일이 본다.
/// 그 경계를 흐리지 않는 것이 이 파일의 목적이다.
final class PlaybackObserversTests: XCTestCase {

    // MARK: 전원

    func testOnlyBatteryCountsAsOnBattery() {
        XCTAssertTrue(PowerSourceObserver.isOnBattery(providingPowerSourceType: kIOPMBatteryPowerKey))
        XCTAssertFalse(PowerSourceObserver.isOnBattery(providingPowerSourceType: kIOPMACPowerKey))
    }

    /// UPS 는 배터리로 치지 않는다 — "곧 꺼진다" 가 아니라 "정전 대비" 라서 벽지를 멈출 이유가
    /// 다르다. 넓히려면 실기 근거를 먼저 만들라는 뜻으로 여기에 못 박는다.
    func testUPSIsNotTreatedAsBattery() {
        XCTAssertFalse(PowerSourceObserver.isOnBattery(providingPowerSourceType: kIOPMUPSPowerKey))
    }

    /// 관측 실패(nil)는 "배터리 아님" 으로 떨어진다 — 관측이 안 되는 것을 이유로 벽지를
    /// 멈추지 않는다는 무회귀 쪽 선택이다.
    func testUnknownPowerSourceFallsBackToNotOnBattery() {
        XCTAssertFalse(PowerSourceObserver.isOnBattery(providingPowerSourceType: nil))
        XCTAssertFalse(PowerSourceObserver.isOnBattery(providingPowerSourceType: "Something Else"))
    }

    // MARK: 오디오

    /// **되먹임 차단이 이 축의 요점이다.** `kAudioDevicePropertyDeviceIsRunningSomewhere` 는
    /// "누군가 장치를 물고 있는가" 라서 우리 자신의 소리도 1 로 친다. 빼지 않으면
    /// `playbackaudio=pause` 인 사용자에서 오디오 반응 벽지가 스스로를 멈춘다.
    func testOurOwnAudioDoesNotCountAsAnotherAppPlaying() {
        XCTAssertFalse(SystemAudioObserver.isOtherAppPlaying(deviceRunningSomewhere: true,
                                                            weArePlayingAudio: true),
                       "우리가 내는 소리로 우리를 멈추면 되먹임이다")
        XCTAssertTrue(SystemAudioObserver.isOtherAppPlaying(deviceRunningSomewhere: true,
                                                           weArePlayingAudio: false))
    }

    func testSilentDeviceIsNeverOtherAppPlaying() {
        XCTAssertFalse(SystemAudioObserver.isOtherAppPlaying(deviceRunningSomewhere: false,
                                                            weArePlayingAudio: false))
        XCTAssertFalse(SystemAudioObserver.isOtherAppPlaying(deviceRunningSomewhere: false,
                                                            weArePlayingAudio: true))
    }

    // MARK: 조건 조립

    private func win(_ pid: Int, _ r: CGRect) -> DesktopVisibilityMonitor.WindowSnapshot {
        .init(ownerName: "app\(pid)", processId: pid, layer: 0, alpha: 1, bounds: r)
    }

    private let screenA = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let screenB = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

    private func build(windows: [DesktopVisibilityMonitor.WindowSnapshot] = [],
                       frontmost: Int? = nil,
                       displayAsleep: Bool = false,
                       onBattery: Bool = false,
                       audioPlaying: Bool = false) -> PlaybackConditions {
        PlaybackConditionsBuilder.make(
            windows: windows, frontmostProcessId: frontmost, currentProcessId: 1,
            screenFrames: [screenA, screenB], visibleFrames: [screenA, screenB],
            displayAsleep: displayAsleep, onBattery: onBattery, audioPlaying: audioPlaying)
    }

    func testAllMonitorsMaskComesFromScreenCount() {
        XCTAssertEqual(build().allMonitorsMask, 0b11)
    }

    func testBooleanAxesArePassedThroughUnchanged() {
        let c = build(displayAsleep: true, onBattery: true, audioPlaying: true)
        XCTAssertTrue(c.displayAsleep)
        XCTAssertTrue(c.onBattery)
        XCTAssertTrue(c.audioPlaying)
    }

    func testWindowMasksReachTheConditions() {
        // B 화면을 덮는 남의 창 + 그 앱이 포커스 → 세 마스크 모두 B 비트.
        let c = build(windows: [win(42, screenB)], frontmost: 42)
        XCTAssertEqual(c.maximizedMask, 0b10)
        XCTAssertEqual(c.fullscreenMask, 0b10)
        XCTAssertEqual(c.unfocusedMask, 0b10)
    }

    /// **아직 배선되지 않은 축은 조건에 들어오지 않는다.** `vramPressure` 는 표본을 만드는
    /// 측정기가 없고, `external*Request`·`forcePauseAll` 은 트레이/IPC 가 붙을 때 함께 본다.
    /// 전부 기본값(무압박·무요청)이라 판정을 좌우하지 않는다 — 그것이 지금의 계약이다.
    func testUnwiredAxesStayAtTheirNeutralDefaults() {
        let c = build(displayAsleep: true, onBattery: true, audioPlaying: true)
        XCTAssertFalse(c.vramPressure)
        XCTAssertFalse(c.externalStopRequest)
        XCTAssertFalse(c.externalPauseRequest)
        XCTAssertFalse(c.externalMuteRequest)
        XCTAssertFalse(c.forcePauseAll)
    }

    /// `layout` 은 지금 항상 `.perMonitor` 다 — Waple 에 stretch/clone 배치가 없다.
    /// 이것이 **가장 좁은 가정**이라는 것이 요점이다: 부분 정지가 허용되는 쪽이라
    /// 한 화면의 조건이 다른 화면의 벽지를 멈추지 않는다.
    func testLayoutIsPerMonitorUntilWapleHasOtherLayouts() {
        XCTAssertEqual(build().layout, .perMonitor)
    }

    /// 조립 → 판정 왕복. 관측자가 채운 조건이 WE 기본값 아래에서 실제로 정지를 낸다.
    func testAssembledConditionsDriveTheVerdict() {
        let conditions = build(windows: [win(42, screenB)], frontmost: 42)
        let verdict = PlaybackEvaluator.evaluate(.weDefault, conditions)
        XCTAssertFalse(verdict.isPaused(monitorIndex: 0), "A 화면은 비어 있다")
        XCTAssertTrue(verdict.isPaused(monitorIndex: 1), "B 화면은 최대화·전체화면 둘 다 성립")
    }

    /// 그리고 아무 일도 없으면 무동작이다 — 관측자를 붙였다는 것만으로 동작이 바뀌지 않는다.
    func testIdleDesktopYieldsRunningUnderWEDefaults() {
        XCTAssertEqual(PlaybackEvaluator.evaluate(.weDefault, build()), .running)
    }
}
