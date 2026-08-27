import AppKit
import CoreAudio
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
import WaplePolicy

// MARK: - 재생정책 관측자 (stage 2b)
//
// `PlaybackConditions` 의 여섯 축을 실제 시스템 상태로 채운다. 층을 둘로 나눈다:
//
//   · **순수 판정** — 원시 입력(문자열·마스크·불리언)을 받아 답을 낸다. 테스트 대상이다.
//   · **플랫폼 리더** — 그 원시 입력을 실제로 긁어 온다. 얇게 유지한다.
//
// 리더 쪽은 **이 컨테이너에서 동작을 검증할 수 없다.** 리눅스 심(`linux-shim/iokit.swift` ·
// `coreaudio.swift`)은 값이 전부 가짜라 항상 "AC 전원 · 무음" 을 낸다고 각 머리말에 적혀 있고,
// macOS CI 러너도 배터리가 없고 데스크탑이 없다. 그래서 **리더가 검증받는 것은 타입뿐**이고,
// 실제 판정이 맞는지는 사람이 실기에서 봐야 한다. 그 사실을 여기 적어 두는 것이
// "관측자를 붙였으니 동작한다" 는 오해를 막는 유일한 방법이다.

// MARK: 전원

enum PowerSourceObserver {
    /// 순수. WE 의 `playbackonbattery` 가 보는 것과 같은 판정이다 —
    /// 평가기 `0x14006d28c–0x14006d296` 이 읽는 플래그 `0x1404e52e4` bit4.
    ///
    /// **UPS 는 배터리로 치지 않는다.** 애플은 `kIOPMUPSPowerKey` 를 따로 돌려주는데,
    /// UPS 는 "곧 꺼진다" 가 아니라 "정전 대비" 라서 벽지를 멈출 이유가 다르다.
    /// 확신이 없으므로 **배터리만 true** 로 좁힌다 — 넓히려면 실기 근거를 먼저 만들 것.
    static func isOnBattery(providingPowerSourceType: String?) -> Bool {
        providingPowerSourceType == kIOPMBatteryPowerKey
    }

    /// 플랫폼 리더. `nil` 스냅샷은 애플에서 "시스템 전체를 보고 답하라" 는 뜻이라
    /// `IOPSCopyPowerSourcesInfo()` 를 따로 뜨지 않는다(뜨면 해제 책임만 생긴다).
    static func currentPowerSourceType() -> String? {
        guard let t = IOPSGetProvidingPowerSourceType(nil) else { return nil }
        return t.takeUnretainedValue() as String
    }

    static func isOnBattery() -> Bool { isOnBattery(providingPowerSourceType: currentPowerSourceType()) }
}

// MARK: 오디오

enum SystemAudioObserver {
    /// 순수. `kAudioDevicePropertyDeviceIsRunningSomewhere` 는 "이 장치를 **누군가** 물고
    /// 있는가" 라서, 우리 자신이 소리를 내고 있으면 그것도 1 이 된다.
    ///
    /// **그래서 우리가 내는 소리를 빼야 한다.** 안 빼면 오디오 반응 벽지가 스스로를 멈추는
    /// 되먹임이 생긴다(`playbackaudio=pause` 인 사용자에서). WE 는 WASAPI 세션을 열거해
    /// 자기 세션을 제외하는데, CoreAudio 의 이 속성에는 그런 분해가 없다 — 그래서
    /// "우리가 재생 중인가" 를 호출부에서 받아 뺀다.
    static func isOtherAppPlaying(deviceRunningSomewhere: Bool, weArePlayingAudio: Bool) -> Bool {
        deviceRunningSomewhere && !weArePlayingAudio
    }

    /// 플랫폼 리더 — 기본 출력 장치가 누군가에게 물려 있는가.
    /// 실패(장치 없음·권한 없음)는 **false** 로 떨어뜨린다. 관측 실패로 벽지를 멈추는 것보다
    /// 관측 실패로 계속 재생하는 쪽이 무회귀에 가깝다.
    static func defaultOutputDeviceIsRunning() -> Bool {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // `kAudioObjectSystemObject` 는 `Int32` 라 `AudioObjectID`(UInt32)로 접어야 한다.
        // 값이 1 인 컴파일 타임 상수라 변환이 안전하고, `AudioObjectID(` 는 좁힘 센서스의
        // 패턴(`U?Int…(`)에 걸리지 않는다.
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID) == 0,
              deviceID != 0 else { return false }

        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &runningAddr, 0, nil, &runningSize, &running) == 0 else {
            return false
        }
        return running != 0
    }
}

// MARK: - 조건 조립 (순수)

enum PlaybackConditionsBuilder {
    /// 관측 결과를 `PlaybackConditions` 로 접는다. **여기에는 I/O 가 없다** — 그래서 조건
    /// 조립 규칙(마스크 계산·화면 수 → allMonitorsMask)이 전부 테스트된다.
    ///
    /// `layout` 은 지금 항상 `.perMonitor` 다. Waple 은 아직 stretch/clone 배치를 갖지 않는다 —
    /// 갖게 되면 여기에 실제 배치를 넘겨야 하고, 그 전까지 `.perMonitor` 가 **가장 좁은**
    /// 가정이다(부분 정지가 허용되는 쪽이라 전 화면을 한꺼번에 멈추지 않는다).
    static func make(windows: [DesktopVisibilityMonitor.WindowSnapshot],
                     frontmostProcessId: Int?,
                     currentProcessId: Int,
                     screenFrames: [CGRect],
                     visibleFrames: [CGRect],
                     displayAsleep: Bool,
                     onBattery: Bool,
                     audioPlaying: Bool) -> PlaybackConditions {
        PlaybackConditions(
            layout: .perMonitor,
            allMonitorsMask: PlaybackMasks.allMonitors(count: screenFrames.count),
            unfocusedMask: PlaybackMasks.unfocused(windows: windows,
                                                   frontmostProcessId: frontmostProcessId,
                                                   currentProcessId: currentProcessId,
                                                   screenFrames: screenFrames),
            maximizedMask: PlaybackMasks.maximized(windows: windows,
                                                   currentProcessId: currentProcessId,
                                                   visibleFrames: visibleFrames),
            fullscreenMask: PlaybackMasks.fullscreen(windows: windows,
                                                     currentProcessId: currentProcessId,
                                                     screenFrames: screenFrames),
            audioPlaying: audioPlaying,
            displayAsleep: displayAsleep,
            onBattery: onBattery)
        // `vramPressure` 는 넘기지 않는다 — 표본을 만드는 측정기가 없다(`VRAMHysteresis` 는
        // 모델만 있고 `MTLDevice.currentAllocatedSize` 를 먹이는 자리가 아직 없다).
        // 기본값 false 로 두는 것이 "압박 없음" 이라 무회귀 쪽이다.
        // `external*Request`·`forcePauseAll` 도 같다 — 트레이/IPC 가 붙을 때 함께 본다.
    }
}
