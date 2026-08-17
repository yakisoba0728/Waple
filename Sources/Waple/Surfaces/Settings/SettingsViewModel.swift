import SwiftUI
import WapleCore
import WapleLibrary
import WapleRender

/// 설정 창 상태 미러 + 배선. 저장은 기존 전역 스토어를 직접 읽고 쓰되,
/// 적용 side-effect(리마운트·타이머·복원·saver 설치)는 전부 AppDelegate 주입 클로저로 위임한다
/// (LibraryViewModel.on* 전례 — 뷰가 AppDelegate 내부에 직접 손대지 않는다).
/// 비-@MainActor: 동기 전용이고 nonisolated AppDelegate 가 소유·구성한다(LibraryViewModel 과 동일 규약).
/// 오프메인 콜백이 있는 Workshop/Discover VM 과 달리 @MainActor 불필요.
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
    var occlusionState: () -> (enabled: Bool, threshold: Double) = { (false, 0) }
    var stillSyncEnabled: () -> Bool = { false }

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
        statusMessage = nil
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
