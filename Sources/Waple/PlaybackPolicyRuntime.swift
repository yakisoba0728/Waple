import AppKit
import CoreGraphics
import WapleCore
import WaplePolicy

// MARK: - 전역 재생정책면 (stage 2 — 정책이 실제로 사는 곳)
//
// [2026-08-26] **stage 1 은 정책의 출처를 절반만 알고 있었다.**
//
// stage 1 은 `project.json` 의 `general.properties.playback*` 6키(= 벽지별 선언)만 읽고,
// 하나도 선언되지 않으면 `.running` 으로 단축했다. 그 단축의 근거는 "부재 = run" 이었는데,
// **실측하면 그 경로는 실질적으로 죽어 있다** — 로컬 코퍼스 `project.json` 191개 중 이 6키를
// 선언한 것이 **0개**다(2026-08-26 전수 grep).
//
// 정책이 실제로 사는 곳은 WE 의 **전역 사용자 설정**이다. 설치본 `config.json` 실측:
//
//     general.user.playbackfocus       = "run"
//     general.user.playbackmaximized   = "pause"
//     general.user.playbackfullscreen  = "pause"
//     general.user.playbackaudio       = "run"
//     general.user.playbacksleep       = "stop"
//     general.user.playbackonbattery   = "run"
//     general.user.pausevram           = false
//
// 이 값들이 `PlaybackPolicy.weDefault` 와 **전 축 일치**한다 — RE 가 맞았고, 다만 그 기본값이
// 사는 자리가 벽지가 아니라 전역이었다. 벽지별 키는 그 위에 얹는 **덮어쓰기**이고, WE 가
// 벽지마다 `""` 를 주입하는 것(`FUN_140046ff0` → `FUN_140086eb0(param_1,"playbackfocus","")`)이
// 곧 "전역을 따른다" 는 뜻이다. 파서가 빈 문자열을 버리는 것도 그래서 옳다.
//
// **그래서 `PlaybackPolicy.init(weConfig:)` 는 여기서 쓰는 것이 맞다.** stage 1 이 그 생성자를
// 금지한 것은 여전히 옳다 — 부재 키를 `weDefault` 로 채우는 동작이 **벽지별 선언**에는 틀리기
// 때문이다(아무것도 선언 안 한 벽지가 남의 창 최대화만으로 멈춘다). 전역면에서는 그 채움이
// 정확히 원하는 것이다. 두 층이 다른 기본값 규칙을 갖는다는 것이 요점이고, 그래서 층을 나눴다.

/// WE 전역 사용자 설정(`config.json` 의 `general/user`)에 대응하는 Waple 쪽 면.
///
/// 저장은 `UserDefaults` 다. 키는 **WE 의 이름을 그대로** 쓴다(`waple.playback.` 접두만 붙인다) —
/// 나중에 WE 설치본에서 가져오기를 붙일 때 매핑표가 필요 없게 하려는 것이다.
enum GlobalPlaybackSettings {
    /// 테스트가 갈아끼운다. `SceneRenderSettings.defaults`(:51)와 같은 표기 규율이다 —
    /// 프로덕션에서는 기동 후 바뀌지 않고 `UserDefaults` 자체가 스레드 안전하다.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    static let prefix = "waple.playback."
    static var vramKey: String { prefix + "pausevram" }
    static func key(for trigger: PlaybackTrigger) -> String { prefix + trigger.weConfigKey }

    /// 현재 전역 정책. **미설정 키는 WE 기본값**(`PlaybackPolicy.weDefault`)이다 —
    /// 처음 실행하는 사용자가 WE 와 같은 동작을 얻는다는 뜻이고, 그것이 이 프로젝트의 목표다.
    static var current: PlaybackPolicy {
        var stored: [String: String] = [:]
        for trigger in PlaybackTrigger.allCases {
            if let raw = defaults.string(forKey: key(for: trigger)), !raw.isEmpty {
                stored[trigger.weConfigKey] = raw
            }
        }
        // `object(forKey:)` 로 받는다 — `bool(forKey:)` 는 미설정을 false 로 뭉개는데,
        // 이 축의 WE 기본값이 마침 false 라 지금은 같지만 "미설정" 과 "false" 를 구분하지
        // 못하는 코드는 기본값이 바뀌는 날 조용히 틀린다.
        let vram = defaults.object(forKey: vramKey) as? Bool ?? PlaybackPolicy.weDefault.pauseVRAM
        return PlaybackPolicy(weConfig: stored, pauseVRAM: vram)
    }

    static func set(_ action: PlaybackAction, for trigger: PlaybackTrigger) {
        defaults.set(action.weConfigValue, forKey: key(for: trigger))
    }

    static func setPauseVRAM(_ on: Bool) { defaults.set(on, forKey: vramKey) }

    /// 전 축을 미설정으로 되돌린다(= WE 기본값). 테스트 격리에도 쓴다.
    static func reset() {
        for trigger in PlaybackTrigger.allCases { defaults.removeObject(forKey: key(for: trigger)) }
        defaults.removeObject(forKey: vramKey)
    }
}

// MARK: - 두 층의 병합

enum PlaybackPolicyResolver {
    /// 전역 정책 위에 **벽지가 선언한 축만** 덮어쓴다.
    ///
    /// 반환이 옵셔널이 아닌 것이 stage 1 의 `declaredPolicy` 와의 결정적 차이다. stage 1 은
    /// "선언 없음 → nil → 평가기를 부르지 않고 `.running`" 이었는데, 그 단축은 전역면이
    /// 없다는 전제 위에서만 옳았다. 이제 선언이 없으면 **전역 정책이 그대로 적용된다** —
    /// WE 의 `""` 주입이 뜻하는 바와 같다.
    static func effective(global: PlaybackPolicy, declaring properties: [String: String]) -> PlaybackPolicy {
        var policy = global
        for trigger in PlaybackTrigger.allCases {
            guard let raw = properties[trigger.weConfigKey], !raw.isEmpty else { continue }
            policy[trigger] = PlaybackAction(weConfigValue: raw)
        }
        return policy
    }

    /// 이 벽지에 대한 판정. 전역 정책은 호출 시점에 읽는다.
    static func verdict(for project: WallpaperProject,
                        conditions: PlaybackConditions,
                        global: PlaybackPolicy = GlobalPlaybackSettings.current) -> PlaybackVerdict {
        PlaybackEvaluator.evaluate(effective(global: global, declaring: project.playbackProperties), conditions)
    }
}

// MARK: - 창 파생 마스크 (focus · maximized · fullscreen)
//
// 세 축 전부 "다른 앱의 창이 **어느 모니터에서** 무엇을 하고 있는가" 라서, 입력이 같다 —
// `DesktopVisibilityMonitor.WindowSnapshot` 배열과 화면 프레임 배열이다. 그래서 관측자를
// 새로 만들지 않고 **그 스냅샷을 재사용**한다(그 파일의 `currentSnapshots()` 가 이미
// `CGWindowListCopyWindowInfo` 를 읽는다). 여기 있는 것은 전부 순수 함수다.
//
// 좌표계 주의: `CGWindowListCopyWindowInfo` 의 `bounds` 는 **좌상단 원점**이고 `NSScreen` 은
// 좌하단이다. 변환은 `DesktopVisibilityMonitor.cocoaFlipped(_:mainScreenHeight:)` 를 쓴다 —
// 그 함수가 이미 이 리포의 정본이고, 여기서 두 번째 구현을 만들지 않는다.
enum PlaybackMasks {
    /// 한 창이 어느 화면에 속하는가 — **겹치는 면적이 가장 큰** 화면. 겹침이 없으면 nil.
    /// (창이 두 화면에 걸치는 경우 WE 도 하나로 귀속시킨다 — 마스크는 화면당 1비트다.)
    static func screenIndex(of bounds: CGRect, screenFrames: [CGRect]) -> Int? {
        var best: (index: Int, area: Double)?
        for (i, frame) in screenFrames.enumerated() {
            let inter = bounds.intersection(frame)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { continue }
            let a = Double(inter.width * inter.height)
            if best == nil || a > best!.area { best = (i, a) }
        }
        return best?.index
    }

    /// 판정 대상 창인가 — 자기 자신(Waple)과 데스크탑 레이어·투명 창은 뺀다.
    /// `DesktopVisibilityMonitor.isBlocking` 과 같은 성질을 보지만 **목적이 다르다**:
    /// 저쪽은 "데스크탑이 가려졌나", 여기는 "남의 앱이 이 화면을 쓰고 있나" 다.
    static func isForeignWindow(_ w: DesktopVisibilityMonitor.WindowSnapshot, currentProcessId: Int) -> Bool {
        w.processId != currentProcessId && w.layer == 0 && w.alpha > 0.01
            && w.bounds.width > 1 && w.bounds.height > 1
    }

    /// 창이 주어진 사각형을 **거의 정확히** 덮는가. 최대화·전체화면 판정의 공통 술어다.
    ///
    /// 왜 정확 일치가 아닌가: macOS 는 창 그림자·정수 반올림으로 몇 포인트가 어긋난다.
    /// 왜 "덮는다(포함)" 가 아닌가: 그러면 화면보다 큰 창(다중 화면에 걸친 창)이 모든 화면을
    /// 최대화로 오판한다. 그래서 **양방향 허용오차**로 본다.
    static func covers(_ bounds: CGRect, _ target: CGRect, tolerance: CGFloat = 4) -> Bool {
        guard target.width > 0, target.height > 0 else { return false }
        return abs(bounds.minX - target.minX) <= tolerance
            && abs(bounds.minY - target.minY) <= tolerance
            && abs(bounds.width - target.width) <= tolerance
            && abs(bounds.height - target.height) <= tolerance
    }

    /// `unfocusedMask` — **다른 앱이 포커스를 가진** 모니터.
    ///
    /// `frontmostProcessId` 가 우리 자신이거나 없으면 0(= 어느 화면도 뺏기지 않았다).
    /// 포커스 앱의 창이 놓인 화면들에 비트를 세운다. 창이 하나도 없으면(예: 메뉴바 전용 앱)
    /// 0 이다 — 화면을 점유하지 않는 앱에 벽지를 멈출 이유가 없다.
    static func unfocused(windows: [DesktopVisibilityMonitor.WindowSnapshot],
                          frontmostProcessId: Int?,
                          currentProcessId: Int,
                          screenFrames: [CGRect]) -> UInt32 {
        guard let front = frontmostProcessId, front != currentProcessId else { return 0 }
        var mask: UInt32 = 0
        for w in windows where w.processId == front && isForeignWindow(w, currentProcessId: currentProcessId) {
            if let i = screenIndex(of: w.bounds, screenFrames: screenFrames), i < 32 { mask |= 1 << UInt32(i) }
        }
        return mask
    }

    /// `maximizedMask` — 다른 앱의 창이 그 화면의 **visibleFrame**(메뉴바·독 제외)을 덮는 모니터.
    static func maximized(windows: [DesktopVisibilityMonitor.WindowSnapshot],
                          currentProcessId: Int,
                          visibleFrames: [CGRect]) -> UInt32 {
        mask(windows: windows, currentProcessId: currentProcessId, targets: visibleFrames)
    }

    /// `fullscreenMask` — 다른 앱의 창이 그 화면의 **frame**(전체)을 덮는 모니터.
    static func fullscreen(windows: [DesktopVisibilityMonitor.WindowSnapshot],
                           currentProcessId: Int,
                           screenFrames: [CGRect]) -> UInt32 {
        mask(windows: windows, currentProcessId: currentProcessId, targets: screenFrames)
    }

    private static func mask(windows: [DesktopVisibilityMonitor.WindowSnapshot],
                             currentProcessId: Int,
                             targets: [CGRect]) -> UInt32 {
        var mask: UInt32 = 0
        for w in windows where isForeignWindow(w, currentProcessId: currentProcessId) {
            for (i, target) in targets.enumerated() where i < 32 {
                if covers(w.bounds, target) { mask |= 1 << UInt32(i) }
            }
        }
        return mask
    }

    /// 부착된 전 모니터 비트합(`PlaybackConditions.allMonitorsMask`). 33개 이상은 32로 자른다 —
    /// 마스크가 `UInt32` 라 그 이상은 표현할 수 없다(WE 도 같은 폭이다).
    static func allMonitors(count: Int) -> UInt32 {
        let n = max(0, min(count, 32))
        return n == 32 ? UInt32.max : (1 << UInt32(n)) - 1
    }
}
