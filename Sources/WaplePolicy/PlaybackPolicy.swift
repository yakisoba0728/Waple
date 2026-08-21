import Foundation

// WE 2.8.42 의 재생 정책(playback policy)을 순수 함수로 옮긴 것이다.
//
// **`import Foundation` 하나만 쓴다.** `simd`·CoreGraphics·AppKit 을 들이지 않는다 —
// `WapleCore` 가 `import simd` 때문에 리눅스에서 빌드되지 않아 그 타깃에 의존하는 테스트가
// 전부 macOS 러너에서만 돌고, 왕복이 10분이다(실측: `swift test --filter WapleSnapshotTests`
// 조차 전 패키지를 빌드하다 `AudioResponse.swift:2 no such module 'simd'` 로 죽는다).
// 이 파일은 그 사슬 밖에 있으므로 리눅스 spec 레인에서 초 단위로 검증된다.
//
// 정본: spec/engine/playback-policy.json. 아래 주소는 전부 wallpaper64.exe 2.8.42
// (imagebase 0x140000000) 이며, 검사기 `scripts/spec/check_playback_policy.py` 가
// 이 파일을 텍스트 파싱해 정본과 대조한다 — 값을 고치면 정본도 같이 고쳐야 한다.

// MARK: - 액션

/// 재생 액션. WE 는 이것을 **문자열 열거**로 저장하고, 로더가 정수로 접는다.
///
/// 매퍼 `0x140141880–0x14014191a` 는 문자열 길이로 먼저 가른 뒤 리터럴을 비교한다.
/// 반환값이 곧 전역에 저장되는 정수다:
///
/// ```
/// 0x14014189a  cmp dword ptr [rax], 0x706f7473   ; "stop"
/// 0x1401418a2  mov eax, r8d                      ; r8 = 길이 4 → stop = 4
/// 0x1401418b8  movabs rdx, 0x6c6c616573756170    ; "pauseall"
/// 0x1401418c7  mov eax, 3                        ; pauseall = 3
/// 0x1401418df  ... "pause"                       ; 0x1401418f4  mov eax, 2
/// 0x140141909  cmp dword ptr [rcx], 0x6574756d   ; "mute"
/// 0x140141914  sete al                           ; mute = 1, 그 밖의 길이 4 = 0
/// 0x140141918  xor eax, eax                      ; 미인식 = 0 = run
/// ```
///
/// 미인식 문자열은 **조용히 `run`** 이다. 오타 하나가 "정책 없음" 이 되는 설계이므로
/// `init(weConfigValue:)` 도 실패 가능 이니셜라이저로 만들지 않는다 — 실물이 안 그런다.
///
/// `Comparable` 은 rawValue 순서다. WE 의 번호 자체가 **강도의 사다리**라
/// (`run` < `mute` < `pause` < `pauseAll` < `stop`) 그 순서에 의미가 있다.
public enum PlaybackAction: UInt32, Comparable, CaseIterable, Sendable {
    case run = 0
    case mute = 1
    case pause = 2
    case pauseAll = 3
    case stop = 4

    /// WE `config.json` 의 문자열 → 액션. 미인식은 `.run`(매퍼 `0x140141918`).
    public init(weConfigValue: String) {
        switch weConfigValue {
        case "mute": self = .mute
        case "pause": self = .pause
        case "pauseall": self = .pauseAll
        case "stop": self = .stop
        default: self = .run
        }
    }

    /// WE `config.json` 에 실제로 쓰이는 문자열.
    public var weConfigValue: String {
        switch self {
        case .run: return "run"
        case .mute: return "mute"
        case .pause: return "pause"
        case .pauseAll: return "pauseall"
        case .stop: return "stop"
        }
    }

    public static func < (lhs: PlaybackAction, rhs: PlaybackAction) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - 축

/// 재생 정책의 축 여섯 개. `pausevram` 은 열거가 아니라 불이라 여기 없다.
///
/// 설정 키 문자열의 VA 와 기본값 설치 자리(`0x140046f20` 계열)는 각 case 주석에 적었다.
public enum PlaybackTrigger: String, CaseIterable, Sendable {
    /// 다른 앱이 포커스를 가짐. 키 `playbackfocus` @0x140476df0, 전역 0x1404e53c0.
    case focus
    /// 다른 앱이 최대화됨. 키 `playbackmaximized` @0x140476e00, 전역 0x1404e53c4.
    case maximized
    /// 다른 앱이 전체화면. 키 `playbackfullscreen` @0x140476e18, 전역 0x1404e53c8.
    case fullscreen
    /// 다른 앱이 오디오 재생 중. 키 `playbackaudio` @0x140476e58, 전역 0x1404e53d4.
    case audio
    /// 디스플레이 절전. 키 `playbacksleep` @0x140476e48, 전역 0x1404e53cc.
    case displaySleep
    /// 노트북 배터리 구동. 키 `playbackonbattery` @0x140476e30, 전역 0x1404e53d0.
    case battery

    /// WE `config.json` 의 키 이름.
    ///
    /// 전역 저장 순서는 문자열 순서와 다르다 — 로더 `0x14006c280–0x14006ce9b` 가
    /// focus/maximized/fullscreen 다음에 **sleep(0x1404e53cc) → onbattery(0x1404e53d0)**
    /// 순으로 쓴다(0x14006c4c6 · 0x14006c534). 주소로 축을 유추하지 마라.
    public var weConfigKey: String {
        switch self {
        case .focus: return "playbackfocus"
        case .maximized: return "playbackmaximized"
        case .fullscreen: return "playbackfullscreen"
        case .audio: return "playbackaudio"
        case .displaySleep: return "playbacksleep"
        case .battery: return "playbackonbattery"
        }
    }

    /// 기본값 설치자 `0x140046f20` 이 키가 없을 때 넣는 값.
    ///
    /// 각 자리는 `cmp byte ptr [rax+8], 4`(jsoncpp 태그 4 = stringValue)로 이미 값이
    /// 있으면 건너뛰고, 없으면 리터럴을 심는다:
    /// focus `0x140046f44`→"run" · maximized `0x14004701b`→"pause" ·
    /// fullscreen `0x1400470bd`→"pause" · onbattery `0x140047128`→"run" ·
    /// sleep `0x140047188`→"stop" · audio `0x1400471e8`→"run".
    /// 설치본 `config.json` 의 `general/user/*` 가 이 여섯과 글자 그대로 같다.
    public var weDefault: PlaybackAction {
        switch self {
        case .focus: return .run
        case .maximized: return .pause
        case .fullscreen: return .pause
        case .audio: return .run
        case .displaySleep: return .stop
        case .battery: return .run
        }
    }

    /// UI 드롭리스트가 이 축에 **제시하는** 액션 목록.
    ///
    /// 옵션 빌더는 `ui/dist/scripts/scripts.js` 의 `function k(e,t,a)` 하나뿐이다
    /// (`e` = 멀티모니터, `t` = mute 허용, `a` = stop 허용):
    ///
    /// ```js
    /// var i=[{value:"run"}];
    /// t && i.push({value:"mute"});
    /// e ? (i.push({value:"pause"}), i.push({value:"pauseall"}))
    ///   : i.push({value:"pause"});
    /// a && i.push({value:"stop"});
    /// ```
    ///
    /// 호출은 여섯 줄이 나란히 있다:
    /// `Focus=k(t,!0,!1)` · `Maximized=k(t,!0,!0)` · `Fullscreen=k(t,!0,!0)` ·
    /// `Sleep=k(!1,!1,!0)` · `Battery=k(!1,!1,!0)` · `Audio=k(!1,!0,!1)`
    /// (`t = e.runtime.multimonitor`).
    ///
    /// **첫 인자가 축마다 다르다.** sleep·battery·audio 는 `t` 가 아니라 리터럴 `!1` 이라
    /// 모니터가 몇 대든 `pauseall` 을 제시하지 않는다. 처음에 이 셋도 `t` 를 받는 줄 알고
    /// 짰다가 테스트가 잡았다 — 엔진도 같은 편이다(세 축 다 액션 3 에 분기가 없다).
    ///
    /// **엔진 디스패치가 이 표와 정확히 일치한다** — 목록에 없는 액션은 분기 자체가 없어
    /// 무동작(= `run`)이 된다. focus 는 `stop` 분기가 없고(0x14006d1fe 에서 4 는 그냥 빠진다),
    /// audio 는 mute/pause 만(0x14006d259–0x14006d261), battery 는 stop/pause 만
    /// (0x14006d29e–0x14006d2ac), sleep 은 pause/stop 만(0x14006ed9a–0x14006eda2) 본다.
    ///
    /// **한 자리만 어긋난다**: `pauseall` 은 UI 가 멀티모니터에서만 보여주지만 엔진은
    /// 모니터 수와 무관하게 처리한다. 모니터가 하나면 `pause` 와 관측상 같은 결과라
    /// (`isPaused(monitorIndex: 0)` 가 양쪽 다 참) 실제 차이는 없다.
    public func allowedActions(multiMonitor: Bool) -> [PlaybackAction] {
        var out: [PlaybackAction] = [.run]
        if allowsMute { out.append(.mute) }
        out.append(.pause)
        if multiMonitor && honorsMultiMonitor { out.append(.pauseAll) }
        if allowsStop { out.append(.stop) }
        return out
    }

    /// `k` 의 첫 인자. 창 상태 세 축만 `runtime.multimonitor` 를 받는다.
    private var honorsMultiMonitor: Bool {
        switch self {
        case .focus, .maximized, .fullscreen: return true
        case .audio, .displaySleep, .battery: return false
        }
    }

    /// `k` 의 두 번째 인자.
    private var allowsMute: Bool {
        switch self {
        case .focus, .maximized, .fullscreen, .audio: return true
        case .displaySleep, .battery: return false
        }
    }

    /// `k` 의 세 번째 인자.
    private var allowsStop: Bool {
        switch self {
        case .maximized, .fullscreen, .displaySleep, .battery: return true
        case .focus, .audio: return false
        }
    }
}

// MARK: - 정책

/// 여섯 축 + `pausevram` 불. WE `config.json` 의 `general/user` 에 그대로 사는 값들이다.
public struct PlaybackPolicy: Equatable, Sendable {
    public var focus: PlaybackAction
    public var maximized: PlaybackAction
    public var fullscreen: PlaybackAction
    public var audio: PlaybackAction
    public var displaySleep: PlaybackAction
    public var battery: PlaybackAction

    /// `pausevram` @0x140477038. 열거가 아니라 **불**이다 —
    /// 기본값 설치자가 `cmp byte ptr [rax+8], 5`(jsoncpp 태그 5 = booleanValue)로 보고
    /// 없으면 `false` 를 넣는다(0x140047d52–0x140047d78).
    public var pauseVRAM: Bool

    public init(
        focus: PlaybackAction = .run,
        maximized: PlaybackAction = .pause,
        fullscreen: PlaybackAction = .pause,
        audio: PlaybackAction = .run,
        displaySleep: PlaybackAction = .stop,
        battery: PlaybackAction = .run,
        pauseVRAM: Bool = false
    ) {
        self.focus = focus
        self.maximized = maximized
        self.fullscreen = fullscreen
        self.audio = audio
        self.displaySleep = displaySleep
        self.battery = battery
        self.pauseVRAM = pauseVRAM
    }

    /// WE 기본값. `init` 의 기본 인자와 같은 값이지만 **이름 있는 상수**를 따로 둔다 —
    /// "기본값이 무엇인가" 를 묻는 자리가 기본 인자에 기대면 정본과 대조할 수 없다.
    public static let weDefault = PlaybackPolicy(
        focus: .run,
        maximized: .pause,
        fullscreen: .pause,
        audio: .run,
        displaySleep: .stop,
        battery: .run,
        pauseVRAM: false
    )

    /// `config.json` 의 `general/user` 딕셔너리에서 읽는다. 없는 키는 WE 기본값,
    /// 인식 못 하는 문자열은 `.run`(매퍼 `0x140141918`).
    public init(weConfig: [String: String], pauseVRAM: Bool = false) {
        self.init()
        for trigger in PlaybackTrigger.allCases {
            let raw = weConfig[trigger.weConfigKey]
            self[trigger] = raw.map(PlaybackAction.init(weConfigValue:)) ?? trigger.weDefault
        }
        self.pauseVRAM = pauseVRAM
    }

    public subscript(trigger: PlaybackTrigger) -> PlaybackAction {
        get {
            switch trigger {
            case .focus: return focus
            case .maximized: return maximized
            case .fullscreen: return fullscreen
            case .audio: return audio
            case .displaySleep: return displaySleep
            case .battery: return battery
            }
        }
        set {
            switch trigger {
            case .focus: focus = newValue
            case .maximized: maximized = newValue
            case .fullscreen: fullscreen = newValue
            case .audio: audio = newValue
            case .displaySleep: displaySleep = newValue
            case .battery: battery = newValue
            }
        }
    }
}

// MARK: - 조건

/// 다중 모니터 배치. `config.json` 의 `general/wallpaperconfig/layout`(정수).
///
/// 값은 UI 가 확정한다 — `W.layouts=[{value:0},{value:1},{value:2}]` 이고 라벨은
/// `ui_browse_monitors_layout_per_monitor`("Wallpaper per display") ·
/// `..._fit`("Stretch single wallpaper") · `..._clone_wallpaper`("Clone single wallpaper").
/// 엔진은 이 값을 0x1404e52e0 에 담는다(0x14006a59f–0x14006a5b3, 키 문자열 @0x140474924).
public enum MonitorLayout: Int, CaseIterable, Sendable {
    /// 모니터마다 다른 벽지. 마스크가 모니터별로 독립이다.
    case perMonitor = 0
    /// 벽지 하나를 전 모니터에 늘린다.
    case stretch = 1
    /// 벽지 하나를 전 모니터에 복제한다.
    case clone = 2

    /// 벽지 하나가 전 모니터를 덮는가 = 부분 정지가 무의미한가.
    ///
    /// 엔진은 이 판정을 **두 가지 방식으로** 한다. 마스크 병합과 focus 축은
    /// `layout != 0`(0x14006d103 · 0x14006d208 의 `test r9d, r9d`)이고,
    /// fullscreen/maximized 의 `pause` 는 `layout ∈ {1,2}`
    /// (0x14006d150–0x14006d15b · 0x14006d1b3–0x14006d1be 의 `sub/cmp` 사다리)다.
    /// 정의역이 {0,1,2} 뿐이라 둘은 같은 술어다.
    public var spansAllMonitors: Bool { self != .perMonitor }
}

/// 평가 입력. 마스크는 전부 **비트 = 1 << monitorIndex** 규약이다.
///
/// 규약의 근거는 두 자리다. 마스크를 만드는 쪽(0x140074d40–0x140074d50)이
/// `movzx ecx, byte [rax+0x51]` → `shl r8d, cl` → `or r9d, r8d` 로 전 모니터를 접고,
/// 읽는 쪽(0x140073a5a–0x140073a64)이 같은 `[rax+0x51]` 로 `bt eax, ecx` 한다.
public struct PlaybackConditions: Equatable, Sendable {
    /// 0x1404e52e0. `general/wallpaperconfig/layout`.
    public var layout: MonitorLayout
    /// 0x1404e52ec. 부착된 전 모니터의 비트합.
    public var allMonitorsMask: UInt32
    /// 0x1404e5300. 다른 앱이 포커스를 가진 모니터.
    public var unfocusedMask: UInt32
    /// 0x1404e5304. 다른 앱이 최대화된 모니터.
    public var maximizedMask: UInt32
    /// 0x1404e5308. 다른 앱이 전체화면인 모니터.
    public var fullscreenMask: UInt32
    /// 다른 앱이 오디오를 내고 있는가. 평가기가 0x14006d21f–0x14006d251 에서 확인한다.
    public var audioPlaying: Bool
    /// 디스플레이가 절전에 들어갔는가. 래치는 평가기 밖(0x14006ed90)에서 세운다.
    public var displayAsleep: Bool
    /// 배터리 구동인가. 플래그 0x1404e52e4 의 bit4(0x14006d28c–0x14006d296).
    public var onBattery: Bool
    /// VRAM 압박 래치. 플래그 bit10 — `VRAMHysteresis` 가 만든다.
    public var vramPressure: Bool
    /// 외부(트레이·IPC) 정지 요청. 플래그 bit3, 설정자 0x14006eb10–0x14006eb35.
    public var externalStopRequest: Bool
    /// 외부 일시정지 요청. 플래그 bit0, 설정자 0x14006eaf4. 적용기가
    /// `test bpl, 0x21`(bit0|bit5)로 소비한다(0x140073a4f).
    public var externalPauseRequest: Bool
    /// 외부 음소거 요청. 플래그 bit6, 설정자 0x14006ed74. 적용기가
    /// `test bpl, 0xc0`(bit6|bit7)로 소비한다(0x140073a7b).
    public var externalMuteRequest: Bool
    /// 플래그 bit1. 세워져 있으면 평가기가 일시정지 마스크를 **통째로 지운다**
    /// (0x14006d274–0x14006d27d 의 `shr eax,1` / `cmovne r15d, 0`).
    /// 비트를 세우는 쪽은 설정 키 `unpauseaero` @0x140475390 에 걸려 있다(0x14002fc24).
    public var unpauseAero: Bool
    /// 플래그 bit22. 세워져 있으면 평가기가 마스크를 전체로 올린다
    /// (0x14006d281–0x14006d288 의 `shr eax,0x16` / `cmovne r15d, r11d`).
    public var forcePauseAll: Bool

    public init(
        layout: MonitorLayout = .perMonitor,
        allMonitorsMask: UInt32 = 1,
        unfocusedMask: UInt32 = 0,
        maximizedMask: UInt32 = 0,
        fullscreenMask: UInt32 = 0,
        audioPlaying: Bool = false,
        displayAsleep: Bool = false,
        onBattery: Bool = false,
        vramPressure: Bool = false,
        externalStopRequest: Bool = false,
        externalPauseRequest: Bool = false,
        externalMuteRequest: Bool = false,
        unpauseAero: Bool = false,
        forcePauseAll: Bool = false
    ) {
        self.layout = layout
        self.allMonitorsMask = allMonitorsMask
        self.unfocusedMask = unfocusedMask
        self.maximizedMask = maximizedMask
        self.fullscreenMask = fullscreenMask
        self.audioPlaying = audioPlaying
        self.displayAsleep = displayAsleep
        self.onBattery = onBattery
        self.vramPressure = vramPressure
        self.externalStopRequest = externalStopRequest
        self.externalPauseRequest = externalPauseRequest
        self.externalMuteRequest = externalMuteRequest
        self.unpauseAero = unpauseAero
        self.forcePauseAll = forcePauseAll
    }

    /// 모니터 인덱스 목록 → 비트마스크. 실물의 `shl r8d, cl` 과 같이 5비트로 접는다.
    public static func mask(monitorIndices: [Int]) -> UInt32 {
        var out: UInt32 = 0
        for index in monitorIndices where index >= 0 {
            out |= 1 << (index & 31)
        }
        return out
    }
}

// MARK: - 판정

/// 평가 결과. 출력은 셋뿐이다 — 정지·음소거·일시정지 마스크.
public struct PlaybackVerdict: Equatable, Sendable {
    /// 렌더러를 통째로 내린다(메모리 해제). 다른 둘을 **가린다**.
    public let stop: Bool
    /// 음소거. WE 에서 음소거는 모니터별이 아니라 **전역**이다
    /// (적용기 0x140073a7b–0x140073a85 가 인스턴스마다 같은 값을 먹인다).
    public let muted: Bool
    /// 비트 = 1 << monitorIndex. `UInt32.max` 는 전 모니터.
    public let pauseMask: UInt32

    public init(stop: Bool, muted: Bool, pauseMask: UInt32) {
        self.stop = stop
        self.muted = muted
        self.pauseMask = pauseMask
    }

    /// 아무것도 하지 않는 판정.
    public static let running = PlaybackVerdict(stop: false, muted: false, pauseMask: 0)

    /// 이 모니터가 일시정지 상태인가.
    ///
    /// 실물은 `bt eax, ecx`(0x140073a64)라 오프셋을 32로 나눈 나머지를 쓴다. 여기서도
    /// 같게 접는다 — 마스크를 만드는 쪽(`shl r8d, cl`)이 같은 규칙이라 두 쪽이 맞물린다.
    /// 음수 인덱스는 실물에 없는 입력이므로 거짓으로 떨어뜨린다.
    public func isPaused(monitorIndex: Int) -> Bool {
        guard monitorIndex >= 0 else { return false }
        let bit: UInt32 = 1 << (monitorIndex & 31)
        return pauseMask & bit != 0
    }
}

// MARK: - 평가기

/// 여섯 축과 플래그를 하나의 판정으로 접는 순수 함수.
public enum PlaybackEvaluator {
    /// 축 디스패치(0x14006d0e0–0x14006d2b4)와 판정 적용(0x14006d403–0x14006d4a6)을
    /// 실물 순서 그대로 옮겼다. **순서가 계약이다** — 마스크에 대입하는 축과 OR 하는 축이
    /// 섞여 있고, 플래그 override 둘이 축 사이에 끼어든다.
    ///
    /// 우선순위: `stop` ≻ `displaySleep` ≻ (`pauseMask`, `mute`).
    /// 근거는 판정 적용부의 조기 이탈 둘이다:
    /// ```
    /// 0x14006d407  test ecx, 0x408          ; bit3(외부 정지) | bit10(VRAM 압박)
    /// 0x14006d423  cmovne ebx, r14d         ; 하나라도 서면 stop = 1
    /// 0x14006d453  test bl, bl ; jne …      ; stop 이면 pause/mute 를 아예 갱신하지 않는다
    /// 0x14006d45b  shr eax, 5 ; test … jne  ; 절전 래치(bit5)여도 갱신하지 않는다
    /// ```
    public static func evaluate(
        _ policy: PlaybackPolicy,
        _ conditions: PlaybackConditions
    ) -> PlaybackVerdict {
        var pauseMask: UInt32 = 0
        var muted = false
        var stop = false

        // ① layout 이 0 이 아니면 최대화 마스크가 전체화면 마스크를 흡수한다.
        //    0x14006d103  test r9d, r9d / 0x14006d108  or ecx, r8d
        //    (실물은 그 결과를 전역 0x1404e5304 에 되쓴다 — 여기서는 지역값으로 둔다)
        var maximizedMask = conditions.maximizedMask
        if conditions.layout.spansAllMonitors {
            maximizedMask |= conditions.fullscreenMask
        }

        // ② fullscreen 축 — 0x14006d111–0x14006d176.
        //    실물은 여기서 마스크에 **대입**하지만 이 시점의 마스크는 0 이라 OR 과 같다.
        applyWindowStateAxis(
            action: policy.fullscreen,
            conditionMask: conditions.fullscreenMask,
            conditions: conditions,
            pauseMask: &pauseMask,
            muted: &muted,
            stop: &stop
        )

        // ③ maximized 축 — 0x14006d176–0x14006d1e4. 여기부터는 실물도 OR 이다.
        applyWindowStateAxis(
            action: policy.maximized,
            conditionMask: maximizedMask,
            conditions: conditions,
            pauseMask: &pauseMask,
            muted: &muted,
            stop: &stop
        )

        // ④ focus 축 — 0x14006d1e4–0x14006d21f.
        //    축 전체가 `test edx, edx / je` 로 마스크 비었을 때 통째로 건너뛴다.
        //    stop(4) 분기가 **없다** — 0x14006d1fe 의 `cmp ecx,1 / jne` 에서 빠져나간다.
        if conditions.unfocusedMask != 0 {
            switch policy.focus {
            case .mute:
                muted = true                                    // 0x14006d21b
            case .pause:
                if conditions.layout.spansAllMonitors {
                    pauseMask = .max                            // 0x14006d20d–0x14006d216
                } else {
                    pauseMask |= conditions.unfocusedMask
                }
            case .pauseAll:
                pauseMask = .max                                // 0x14006d203
            case .run, .stop:
                break
            }
        }

        // ⑤ audio 축 — 0x14006d21f–0x14006d26c. mute 와 pause 만 본다.
        //    pause 는 layout 과 무관하게 **전 모니터**다(`mov r15d, r11d`, r11d = -1).
        if conditions.audioPlaying {
            switch policy.audio {
            case .mute:
                muted = true                                    // 0x14006d268
            case .pause:
                pauseMask = .max                                // 0x14006d263
            case .run, .pauseAll, .stop:
                break
            }
        }

        // ⑥ 플래그 override 둘이 축 사이에 낀다 — 0x14006d26c–0x14006d288.
        //    battery 축보다 **앞이라** 배터리 pause 가 다시 덮을 수 있다. 순서가 계약이다.
        if conditions.unpauseAero { pauseMask = 0 }
        if conditions.forcePauseAll { pauseMask = .max }

        // ⑦ battery 축 — 0x14006d28c–0x14006d2b4. stop 과 pause 만 본다.
        if conditions.onBattery {
            switch policy.battery {
            case .stop:
                stop = true                                     // 0x14006d2a3
            case .pause:
                pauseMask = .max                                // 0x14006d2ac
            case .run, .mute, .pauseAll:
                break
            }
        }

        // ⑧ 절전 래치. 평가기 밖(0x14006ed90–0x14006edc8)에서 세워지는데,
        //    **액션이 pause(2) 이거나 stop(4) 일 때만** 세운다 — run/mute/pauseall 이면
        //    핸들러가 `ret` 으로 빠지고(0x14006edc8) 비트가 안 선다. 그래서 절전 중이라도
        //    그 셋이면 다른 축이 평소대로 평가된다.
        let sleepLatched = conditions.displayAsleep
            && (policy.displaySleep == .pause || policy.displaySleep == .stop)

        // ⑨ 판정 적용 — 0x14006d403–0x14006d4a6.
        if stop || conditions.externalStopRequest || conditions.vramPressure
            || (sleepLatched && policy.displaySleep == .stop) {
            return PlaybackVerdict(stop: true, muted: false, pauseMask: 0)
        }

        // 절전 래치는 pause/mute 갱신을 통째로 막는다(0x14006d45b–0x14006d463). 대신
        // 적용기가 `test bpl, 0x21` 로 bit5 를 직접 보고 **전 인스턴스를** 멈춘다
        // (0x140073a4f–0x140073a6d) — 그래서 결과는 "전 모니터 일시정지" 다.
        if sleepLatched {
            return PlaybackVerdict(stop: false, muted: false, pauseMask: .max)
        }

        // 외부 요청 둘은 적용기가 축 결과와 OR 로 합친다.
        if conditions.externalPauseRequest { pauseMask = .max }
        if conditions.externalMuteRequest { muted = true }

        return PlaybackVerdict(stop: false, muted: muted, pauseMask: pauseMask)
    }

    /// fullscreen · maximized 두 축은 다섯 액션을 전부 처리하고 모양이 같다.
    /// 0x14006d111–0x14006d176(fullscreen) 과 0x14006d176–0x14006d1e4(maximized).
    private static func applyWindowStateAxis(
        action: PlaybackAction,
        conditionMask: UInt32,
        conditions: PlaybackConditions,
        pauseMask: inout UInt32,
        muted: inout Bool,
        stop: inout Bool
    ) {
        switch action {
        case .run:
            break
        case .mute:
            // 0x14006d16b · 0x14006d1d3 — 두 자리 다 OR 이다(참으로만 올린다).
            if conditionMask != 0 { muted = true }
        case .pause:
            if conditions.layout.spansAllMonitors {
                // 벽지 하나가 전 모니터를 덮으면 **전부 가려졌을 때만** 멈춘다.
                // 0x14006d162 · 0x14006d1c5 의 `cmp r10d, r8d / cmove r15d, r11d`.
                if conditions.allMonitorsMask == conditionMask { pauseMask = .max }
            } else {
                pauseMask |= conditionMask                      // 0x14006d15d · 0x14006d1c0
            }
        case .pauseAll:
            // 0x14006d145 · 0x14006d1a7 의 `neg / sbb / and` — 마스크가 비지 않으면 전체.
            if conditionMask != 0 { pauseMask = .max }
        case .stop:
            // 0x14006d138 · 0x14006d190.
            if conditionMask != 0 { stop = true }
        }
    }
}

// MARK: - VRAM 히스테리시스

/// `pausevram` 이 켜졌을 때 도는 상태 머신. 평가기 안 `0x14006d2e5–0x14006d403`.
///
/// **이 축의 결과는 pause 가 아니라 stop 이다.** 래치는 플래그 bit10 인데, 판정 적용부가
/// `test ecx, 0x408`(bit3 | bit10)로 bit3(외부 정지 요청)와 **같은 자리에서** 보고
/// `cmovne ebx, 1` 로 정지 플래그를 세운다(0x14006d407–0x14006d423). 이름이 `pausevram`
/// 이라 일시정지로 읽히지만 실물은 렌더러를 내린다.
///
/// 표본은 PDH 카운터 `\GPU Local Adapter Memory(*)\Local Usage` 하나다. 표본 스레드
/// `0x140141460–0x1401417dc` 가 `PdhCollectQueryDataEx(query, 1, event)` 로 **1초** 간격
/// 신호를 받아(0x1401414d1) 인스턴스 배열을 `PDH_FMT_LARGE`(0x400)로 받아 벡터에 넣는다.
///
/// 평가기가 그 벡터를 읽는 방식은 이렇다(0x14006d308–0x14006d377):
///   · 원소가 **2개 미만이면 통째로 건너뛴다**(`cmp rax, 2 / jb`)
///   · 사용량 = 원소[0] ÷ 1_000_000 (매직 0x431BDE82D7B634DB, `sar rdx, 0x12`) → MB
///   · 총량 = **마지막 원소의 하위 32비트**를 MB 로 읽고 [0x801, 0x1FFFF] 밖이면 건너뛴다
///     (`lea eax, [r8-0x801] / cmp eax, 0x1F7FE / ja`) = 2049–131071 MB
///
/// 마지막 원소를 총량으로 읽는 것은 같은 카운터의 다른 인스턴스 값이므로 단위가 어긋난다.
/// 여기서는 **WE 가 의도한 의미**(사용 MB · 총 MB)를 인자로 받고, 실물이 강제하는
/// 표본수·범위 게이트를 그대로 건다. 정본 `spec/engine/playback-policy.json` 의
/// `playbackPolicy.vram.sampling` 에 원문 그대로 적어 두었다.
public struct VRAMHysteresis: Equatable, Sendable {
    /// 진입 문턱. 0x14006d365 의 `mulss xmm0, [0x1404926e4]` = 0.800000011920929f.
    public static let enterFraction: Float = 0.8
    /// 복귀 문턱. 0x14006d3d1 의 `mulss xmm0, [0x1404926d4]` = 0.75f.
    public static let releaseFraction: Float = 0.75
    /// 즉시 복귀 문턱. 0x14006d3de 의 `mulss xmm6, [0x1404926a0]` = 0.3499999940395355f.
    public static let immediateReleaseFraction: Float = 0.35
    /// 복귀 유지 시간(초). 0x14006d3c5 의 `comiss xmm0, [0x140492888]` = 15.0f.
    public static let sustainSeconds: Float = 15.0
    /// 표본 벡터의 최소 원소 수. 0x14006d31a `cmp rax, 2 / jb`.
    public static let minimumSampleCount: Int = 2
    /// 총량 하한(MB). 0x14006d32d–0x14006d334 의 범위 검사 하단.
    public static let minimumTotalMegabytes: UInt32 = 2049
    /// 총량 상한(MB). 같은 검사의 상단(0x801 + 0x1F7FE).
    public static let maximumTotalMegabytes: UInt32 = 131071

    /// bit10 이 서 있는가 = 렌더러를 내려야 하는가.
    public private(set) var isEngaged: Bool
    /// 진입 이후 "문턱 아래" 로 누적된 시간(초). 실물은 0x1404e6428 의 float 하나이고
    /// 갱신은 `QueryPerformanceCounter` 차이를 더하는 0x140057720 이다.
    public private(set) var secondsBelowEnterThreshold: Float

    public init(isEngaged: Bool = false, secondsBelowEnterThreshold: Float = 0) {
        self.isEngaged = isEngaged
        self.secondsBelowEnterThreshold = secondsBelowEnterThreshold
    }

    /// 표본 하나를 먹인다. 반환값은 갱신 뒤의 `isEngaged`.
    ///
    /// - Parameters:
    ///   - usedMegabytes: 사용 중인 VRAM(MB).
    ///   - totalMegabytes: 총 VRAM(MB).
    ///   - sampleCount: PDH 인스턴스 수. 2 미만이면 상태를 **건드리지 않는다**.
    ///   - deltaSeconds: 직전 표본과의 간격. 실물의 표본 주기는 1초다.
    @discardableResult
    public mutating func update(
        usedMegabytes: Float,
        totalMegabytes: UInt32,
        sampleCount: Int,
        deltaSeconds: Float
    ) -> Bool {
        // 게이트 둘. 어느 쪽이든 걸리면 실물은 0x14006d403 으로 바로 뛰어서 래치를
        // **유지한 채** 아무것도 하지 않는다 — 지우지 않는다는 점이 중요하다.
        guard sampleCount >= Self.minimumSampleCount else { return isEngaged }
        guard totalMegabytes >= Self.minimumTotalMegabytes,
              totalMegabytes <= Self.maximumTotalMegabytes else { return isEngaged }

        let total = Float(totalMegabytes)
        let used = usedMegabytes

        // 진입: 0x14006d37c `comiss xmm7, xmm0 / jb` — "미만" 이 아니면 진입이다.
        // NaN 이면 comiss 가 CF 를 세워 jb 가 걸리므로 복귀 경로로 간다. `!(used < x)` 로
        // 적으면 NaN 이 진입이 되어 실물과 갈린다 — 그래서 `used >= x` 로 적는다.
        if used >= total * Self.enterFraction {
            isEngaged = true
            // 0x14006d39b `mov dword ptr [0x1404e6428], 0` — 진입할 때마다 타이머를 0 으로.
            secondsBelowEnterThreshold = 0
            return isEngaged
        }

        // 래치가 안 서 있으면 타이머도 돌지 않는다(0x14006d3ad `test al,1 / je`).
        guard isEngaged else { return isEngaged }

        // 0x14006d3b8 `call 0x140057720` — 누적은 문턱 아래에 있는 틱에서만 일어난다.
        secondsBelowEnterThreshold += deltaSeconds

        // 0x14006d3c5–0x14006d3dc: 15초를 **넘고** 75% 아래면 복귀.
        if secondsBelowEnterThreshold > Self.sustainSeconds,
           total * Self.releaseFraction > used {
            isEngaged = false
            return isEngaged
        }
        // 0x14006d3de–0x14006d3e9: 35% 아래면 시간과 무관하게 즉시 복귀.
        if total * Self.immediateReleaseFraction > used {
            isEngaged = false
        }
        return isEngaged
    }
}
