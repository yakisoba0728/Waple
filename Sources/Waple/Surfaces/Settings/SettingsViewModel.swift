import SwiftUI
import WapleCore
import WapleLibrary
import WaplePolicy
import WapleRender

/// 설정 창 상태 미러 + 배선. 저장은 기존 전역 스토어를 직접 읽고 쓰되,
/// 적용 side-effect(리마운트·타이머·복원·saver 설치)는 전부 AppDelegate 주입 클로저로 위임한다
/// (LibraryViewModel.on* 전례 — 뷰가 AppDelegate 내부에 직접 손대지 않는다).
/// 비-@MainActor: 동기 전용이다 — 만들고, 읽고, 배선하는 자리가 전부 이미 메인 액터라
/// (AppDelegate·SettingsView) 표기가 없어도 오프메인 접근 경로가 생기지 않는다.
/// 오프메인 콜백이 있는 Workshop/Discover VM 과 달리 @MainActor 불필요.
///
/// 종전 이 줄은 "nonisolated AppDelegate 가 소유·구성한다(LibraryViewModel 과 동일 규약)" 였다.
/// 2026-08-19 엄격 동시성 도입에서 **앞쪽 전제가 바뀌었다** — AppDelegate 는 이제 `@MainActor` 다
/// (LibraryViewModel 은 테스트 타깃 사정으로 아직 `@unchecked Sendable` — 그쪽 주석 참조).
/// 여기만 표기를 안 붙이는 것은 잔재가 아니라 판단이다: 이 타입에는 큐를 넘는 경로가 하나도 없어
/// (DispatchQueue 사용 0) 표기가 잡아 줄 것이 없고, 붙이면 비격리 `SettingsViewModelTests` 가
/// 컴파일되지 않는다.
final class SettingsViewModel: ObservableObject {
    @Published var fitMode: FitMode = SceneRenderSettings.fitMode
    @Published var maxFPS: SceneFPSCap = SceneRenderSettings.maxFPS
    @Published var occlusionRaw: Double = -1
    @Published var playlistEnabled = false
    @Published var playlistInterval = 15
    @Published var playlistShuffle = false
    @Published var loginEnabled = LoginItemController.isEnabled
    @Published var stillSync = false
    @Published var saverSelected = ScreenSaverController.isSelected
    @Published var baseAssetsPath = ""
    /// WE 전역 재생정책(stage 3④). 저장은 `GlobalPlaybackSettings`(UserDefaults) 이고 여기는 미러다.
    ///
    /// **stage 2 는 이 키들을 쓰는 화면을 만들지 않았다** — 사용자가 정책을 바꿀 방법이 아예
    /// 없었고, 그래서 WE 기본값(최대화·전체화면 = 일시정지, 절전 = 정지)이 **끌 수 없는**
    /// 동작이었다. 이 화면이 그것을 끄거나 세게 만들 수 있게 한다.
    @Published var playbackPolicy: PlaybackPolicy = .weDefault
    /// **이미 현지화된** 문구. 뷰는 `Text(String)`(비현지화 오버로드)로 표시하므로, 여기서
    /// 완성해 넘기지 않으면 영어 시스템에서도 한국어로 남는다(청사진 §5.0 권장 (a)).
    /// 이 방식을 고른 이유: 리터럴이 `NSLocalizedString(` 안에 남아 커버리지 오라클에 그대로 걸린다.
    @Published var statusMessage: String?

    /// 공유 에셋 폴더 미지정 표시. 경로 자리에 들어가지만 경로가 아니라 UI 문구라 번역 대상이다.
    private static var autoDetectedLabel: String {
        NSLocalizedString("(자동 탐지)", comment: "공유 에셋 폴더 미지정")
    }

    let saverBundled = Bundle.main.url(forResource: "Waple", withExtension: "saver") != nil
    var ffmpegStatus: String {
        SettingsPresentation.ffmpegStatus(available: FFmpegConverter.isAvailable,
                                          path: FFmpegConverter.executableURL?.path)
    }

    private let playlist: PlaylistStore

    // AppDelegate 주입 클로저(측정자/side-effect). 기본값은 no-op — 프리뷰/테스트 안전.
    var onApplySelection: (() -> Void)?
    var onSetOcclusion: ((Double) -> Void)?
    var onSetStillSync: ((Bool) -> Void)?
    var onPlaylistChanged: (() -> Void)?
    var onChooseBaseAssets: (() -> Void)?
    var onSetStillWallpaper: (() -> Void)?
    var onToggleSaver: (() -> Bool)?
    /// 정책이 바뀌었다 — AppDelegate 가 **즉시** 재적용한다. 폴링이 ≤1초 뒤에 어차피 고치지만,
    /// 설정을 바꾼 직후의 1초는 사용자가 "안 먹었다" 로 읽는 구간이다.
    var onPlaybackPolicyChanged: (() -> Void)?
    var occlusionState: () -> (enabled: Bool, threshold: Double) = { (false, 0) }
    var stillSyncEnabled: () -> Bool = { false }
    /// 화면이 둘 이상인가 — 축별 선택지에서 `pauseall` 을 보일지 결정한다(WE UI 빌더 `k(e,t,a)`
    /// 의 첫 인자 `e = runtime.multimonitor`). 기본 false 는 프리뷰/테스트 안전값이다.
    var multiMonitor: () -> Bool = { false }

    init(playlist: PlaylistStore) {
        self.playlist = playlist
    }

    /// 창을 열 때마다 실제 스토어에서 다시 읽는다(트레이/적용 경로가 그 사이 바꿨을 수 있음).
    func refresh() {
        fitMode = SceneRenderSettings.fitMode
        maxFPS = SceneRenderSettings.maxFPS
        let occ = occlusionState()
        occlusionRaw = SettingsPresentation.currentOcclusionRaw(enabled: occ.enabled, threshold: occ.threshold)
        playlistEnabled = playlist.enabled
        playlistInterval = playlist.intervalMinutes
        playlistShuffle = playlist.shuffle
        loginEnabled = LoginItemController.isEnabled
        stillSync = stillSyncEnabled()
        saverSelected = ScreenSaverController.isSelected
        baseAssetsPath = BaseAssetsSettings.baseAssetsDirectory?.path ?? Self.autoDetectedLabel
        playbackPolicy = GlobalPlaybackSettings.current
        statusMessage = nil
    }

    // MARK: - WE 재생정책 (stage 3④)

    /// 한 축의 액션을 바꾼다. 저장은 WE 의 키·값 문자열 그대로다(`GlobalPlaybackSettings`) —
    /// 나중에 WE 설치본에서 가져오기를 붙일 때 매핑표가 필요 없게 하려는 것이다.
    func setPlaybackAction(_ action: PlaybackAction, for trigger: PlaybackTrigger) {
        GlobalPlaybackSettings.set(action, for: trigger)
        playbackPolicy[trigger] = action
        onPlaybackPolicyChanged?()
    }

    /// 전 축을 미설정으로 되돌린다 = **WE 기본값**. "끄기" 가 아니라는 것이 요점이다 —
    /// 미설정이 곧 WE 기본값이라 되돌리면 최대화·전체화면 정지가 다시 켜진다.
    func resetPlaybackPolicy() {
        GlobalPlaybackSettings.reset()
        playbackPolicy = GlobalPlaybackSettings.current
        onPlaybackPolicyChanged?()
    }

    /// 이 축이 사용자에게 제시할 액션 목록. 정본은 `PlaybackTrigger.allowedActions(multiMonitor:)`
    /// 이고(WE UI 빌더에서 옮긴 것) 여기서 다시 정하지 않는다.
    func playbackOptions(for trigger: PlaybackTrigger) -> [PlaybackAction] {
        trigger.allowedActions(multiMonitor: multiMonitor())
    }

    func setFit(_ mode: FitMode) {
        SceneRenderSettings.fitMode = mode
        fitMode = mode
        onApplySelection?()
    }

    /// 전역 FPS 상한(w5d-feature-gaps) — preferredFramesPerSecond 는 mount 시점에만 읽으므로, 지금
    /// 재생 중인 씬에도 즉시 반영되도록 fitMode 와 동일하게 재적용(리마운트)을 태운다.
    func setMaxFPS(_ cap: SceneFPSCap) {
        SceneRenderSettings.maxFPS = cap
        maxFPS = cap
        onApplySelection?()
    }

    func setOcclusion(_ raw: Double) {
        occlusionRaw = raw
        onSetOcclusion?(raw)   // AppDelegate 가 decode·영속·폴링 타이머 재구성
    }

    func setPlaylistEnabled(_ on: Bool) {
        playlist.enabled = on
        playlistEnabled = on
        onPlaylistChanged?()
    }

    func setPlaylistInterval(_ minutes: Int) {
        playlist.intervalMinutes = minutes
        playlistInterval = minutes
        onPlaylistChanged?()
    }

    /// 셔플(무작위 순서, w5d-playback) — NowPlayingBar 팝오버와 동일 저장소를 공유.
    func setPlaylistShuffle(_ on: Bool) {
        playlist.shuffle = on
        playlistShuffle = on
        onPlaylistChanged?()
    }

    func setLogin(_ on: Bool) {
        do {
            try LoginItemController.setEnabled(on)
        } catch {
            statusMessage = String(format: NSLocalizedString("로그인 항목 설정 실패: %@",
                                                            comment: "로그인 항목 토글 실패"),
                                   error.localizedDescription)
        }
        loginEnabled = LoginItemController.isEnabled   // 실제 status 재조회(기존 관례)
    }

    func setStillSync(_ on: Bool) {
        stillSync = on
        onSetStillSync?(on)
    }

    func toggleSaver() {
        saverSelected = onToggleSaver?() ?? saverSelected
    }

    func chooseBaseAssets() {
        onChooseBaseAssets?()   // NSOpenPanel(runModal) — 반환 후 경로 재표시
        baseAssetsPath = BaseAssetsSettings.baseAssetsDirectory?.path ?? Self.autoDetectedLabel
    }

    func makeStillNow() {
        onSetStillWallpaper?()
    }
}
