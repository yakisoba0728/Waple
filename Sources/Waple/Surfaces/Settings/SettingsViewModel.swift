import SwiftUI
import WapleCore
import WapleLibrary
import WapleRender

/// 설정 창 상태 미러 + 배선. 저장은 기존 전역 스토어를 직접 읽고 쓰되,
/// 적용 side-effect(리마운트·타이머·복원·saver 설치)는 전부 AppDelegate 주입 클로저로 위임한다
/// (LibraryViewModel.on* 전례 — 뷰가 AppDelegate 내부에 직접 손대지 않는다).
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var fitMode: FitMode = SceneRenderSettings.fitMode
    @Published var occlusionRaw: Double = -1
    @Published var playlistEnabled = false
    @Published var playlistInterval = 15
    @Published var videoVolume: Float?     // nil = 적용 중인 동영상 없음(컨트롤 비활성)
    @Published var videoRate: Float?
    @Published var loginEnabled = LoginItemController.isEnabled
    @Published var stillSync = false
    @Published var saverSelected = ScreenSaverController.isSelected
    @Published var baseAssetsPath = ""
    @Published var statusMessage: String?

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
    var videoTargetIds: () -> [String] = { [] }
    var occlusionState: () -> (enabled: Bool, threshold: Double) = { (false, 0) }
    var stillSyncEnabled: () -> Bool = { false }

    init(playlist: PlaylistStore) {
        self.playlist = playlist
    }

    /// 창을 열 때마다 실제 스토어에서 다시 읽는다(트레이/적용 경로가 그 사이 바꿨을 수 있음).
    func refresh() {
        fitMode = SceneRenderSettings.fitMode
        let occ = occlusionState()
        occlusionRaw = SettingsPresentation.currentOcclusionRaw(enabled: occ.enabled, threshold: occ.threshold)
        playlistEnabled = playlist.enabled
        playlistInterval = playlist.intervalMinutes
        let ids = videoTargetIds()
        videoVolume = ids.first.map { VideoSettings.volume(id: $0) }
        videoRate = ids.first.map { VideoSettings.rate(id: $0) }
        loginEnabled = LoginItemController.isEnabled
        stillSync = stillSyncEnabled()
        saverSelected = ScreenSaverController.isSelected
        baseAssetsPath = BaseAssetsSettings.baseAssetsDirectory?.path ?? "(자동 탐지)"
        statusMessage = nil
    }

    func setFit(_ mode: FitMode) {
        SceneRenderSettings.fitMode = mode
        fitMode = mode
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

    func setVolume(_ v: Float) {
        let ids = videoTargetIds()
        guard !ids.isEmpty else { return }
        ids.forEach { VideoSettings.setVolume(v, id: $0) }
        videoVolume = v
        onApplySelection?()   // ponytail: 리마운트 반영(재생 리셋) — 라이브 반영은 BACKLOG(queue.volume) 항목
    }

    func setRate(_ r: Float) {
        let ids = videoTargetIds()
        guard !ids.isEmpty else { return }
        ids.forEach { VideoSettings.setRate(r, id: $0) }
        videoRate = r
        onApplySelection?()
    }

    func setLogin(_ on: Bool) {
        do {
            try LoginItemController.setEnabled(on)
        } catch {
            statusMessage = "로그인 항목 설정 실패: \(error.localizedDescription)"
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
        baseAssetsPath = BaseAssetsSettings.baseAssetsDirectory?.path ?? "(자동 탐지)"
    }

    func makeStillNow() {
        onSetStillWallpaper?()
    }
}
