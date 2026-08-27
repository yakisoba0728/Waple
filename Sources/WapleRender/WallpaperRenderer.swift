import AppKit
import WapleCore

public protocol WallpaperRenderer: AnyObject {
    /// 컨테이너 뷰에 배경을 mount 하고 재생을 시작한다.
    func mount(in container: NSView, project: WallpaperProject) throws
    func pause()
    func resume()
    func teardown()

    // MARK: - 재생정책 음량면 (stage 3①)
    //
    // [2026-08-27] 이 둘이 프로토콜에 없어서 재생정책 stage 2 가 두 축을 못 적용했다 —
    // `muted` 는 아무 일도 안 했고(`RenderPauseComposition.Decision.policyWantsMute` 가 그
    // 격차를 세고 있었다), `playbackaudio` 축은 **우리 소리를 뺄 방법이 없어** 아예 배선하지
    // 않았다(빼지 못한 채 켜면 오디오 반응 벽지가 스스로를 멈추는 되먹임이 된다).
    // 두 격차가 같은 표면 하나를 기다리고 있었으므로 함께 연다.

    /// 재생정책이 요구하는 음소거를 켜고 끈다.
    ///
    /// **사용자 음량과 다른 층이다.** `VideoSettings.volume(id:)` 는 사용자가 배경마다 고른
    /// 값이고 이 스위치는 그 위에 겹치는 정책 층이다. 그래서 구현은 음량 값을 **덮어쓰면 안
    /// 된다** — 음소거를 풀었을 때 사용자가 고른 값이 그대로 돌아와야 하고, 특히 사용자가
    /// 0(기본값)으로 둔 배경이 음소거 해제로 소리를 내기 시작하면 안 된다.
    ///
    /// **음소거는 정지가 아니다.** 이 호출로 렌더 루프를 멈추지 마라. 소리만 줄이려던 사용자의
    /// 벽지가 얼어붙는 것이 이 축의 유일한 오작동 방식이고, 합류층의 `testMuteAloneNeverPauses`
    /// 가 그 계약의 오라클이다.
    ///
    /// WE 에서 음소거는 **모니터별이 아니라 전역**이다(적용기 0x140073a7b–0x140073a85 가
    /// 인스턴스마다 같은 값을 먹인다). 그래서 호출부는 전 렌더러에 같은 값을 넣는다 —
    /// 구현이 모니터를 구분할 필요가 없다.
    ///
    /// 멱등이어야 한다. 조건 폴링이 1초마다 도는데 호출부의 엣지 추적이 실패하더라도
    /// 같은 값을 두 번 받는 것으로 소리가 튀면 안 된다.
    func setPolicyMuted(_ muted: Bool)

    /// 이 렌더러가 지금 소리를 낼 수 있는 상태인가 — 오디오 축이 **우리 소리를 빼는** 데 쓴다.
    ///
    /// `SystemAudioObserver` 가 보는 `kAudioDevicePropertyDeviceIsRunningSomewhere` 는 "이 장치를
    /// **누군가** 물고 있는가" 라서 우리 자신도 1 로 친다. 빼지 않으면
    /// `playbackaudio` 축이 "다른 앱이 소리를 낸다" 로 오판해 벽지가 스스로를 멈춘다.
    /// 뺄셈 자체는 `SystemAudioObserver.isOtherAppPlaying(deviceRunningSomewhere:weArePlayingAudio:)`
    /// 가 이미 순수 함수로 들고 있고, 이 프로퍼티가 그 두 번째 인자를 채운다.
    ///
    /// **순간 상태가 아니라 의도를 답한다.** `AVAudioPlayer.isPlaying` 처럼 곡 사이·재개 직후
    /// 잠깐 false 로 떨어지는 값을 그대로 쓰면, 1초 폴링이 그 틈을 "우리는 조용하다" 로 읽어
    /// 정책이 껐다 켰다를 반복한다(폴링 주기와 같은 1Hz 진동). 그래서 구현은
    /// "마운트돼 있고, 정지도 음소거도 아니고, 음량이 0이 아니다" 를 본다.
    ///
    /// **모르면 true 로 답해라.** 과대보고는 뺄셈을 키워 `isOtherAppPlaying` 을 false 로
    /// 만들고, 그러면 오디오 축이 안 켜진다 = stage 2 의 현행 동작(무동작)으로 떨어진다.
    /// 과소보고는 되먹임이다. 두 오류의 대가가 대칭이 아니므로 방향을 고정한다.
    var isPlayingAudio: Bool { get }
}

public enum RendererError: Error, Equatable {
    case unsupportedType
    case unsupportedCodec
    case assetMissing
}
