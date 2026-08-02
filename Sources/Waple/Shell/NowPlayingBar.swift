import SwiftUI
import AppKit
import WapleCore
import WapleLibrary
import WapleRender

/// Now Playing 부제(순수): 타입 라벨 + 재생목록 상태. 뷰와 분리해 단위 테스트.
enum NowPlayingSubtitle {
    static func text(typeRaw: String?, playlistCount: Int, intervalMinutes: Int, playlistEnabled: Bool) -> String {
        guard let typeRaw else { return "라이브러리에서 배경을 선택하세요" }
        var parts = [typeLabel(typeRaw)]
        if playlistCount > 0 { parts.append("재생목록 \(playlistCount)개") }
        if playlistEnabled, playlistCount > 0 { parts.append("\(intervalMinutes)분마다 전환") }
        return parts.joined(separator: " · ")
    }

    /// 하단 바 음량/배속 컨트롤(w5d-settings-ia) 노출 여부 — 적용된 배경이 동영상일 때만. 설정 창에
    /// 묻혀 있던 컨트롤을 재생 컨텍스트(appliedEntry)를 이미 아는 하단 바로 옮기며, 씬/웹/무배경일
    /// 때는 스피커 아이콘 자체를 숨겨 무의미한 컨트롤을 노출하지 않는다.
    static func showsVideoControls(typeRaw: String?) -> Bool {
        typeRaw.map { WallpaperType.from($0) == .video } ?? false
    }

    static func typeLabel(_ raw: String) -> String {
        switch WallpaperType.from(raw) {
        case .scene: return "장면"
        case .video: return "동영상"
        case .web: return "웹"
        case .preset: return "프리셋"
        case .application: return "응용 프로그램"
        case .unknown(let s): return s
        }
    }

    /// 하단 바 표시 엔트리(F495): 전역 선택 우선, 없으면 모니터 할당 중 하나 — 할당만으로 재생 중인
    /// 세션(전역 적용 무)에서 "적용된 배경 없음"으로 표시되던 불일치 방지.
    static func displayedEntry(global: LibraryEntry?, assignedIds: [String], entries: [LibraryEntry]) -> LibraryEntry? {
        if let global { return global }
        guard let id = assignedIds.first else { return nil }
        return entries.first { $0.id == id }
    }

    /// 모니터 할당 id 목록(감사 V06): Dictionary 순회 순서는 실행/상태마다 달라 멀티모니터에서
    /// 표시되는 배경이 들쭉날쭉했다 — 화면 키 정렬 순으로 고정해 결정적으로 한다.
    static func sortedAssignedIds(_ all: [String: String]) -> [String] {
        all.sorted { $0.key < $1.key }.map(\.value)
    }

    /// 대상별 값이 모두 같으면 그 값, 아니면 nil(F496) — 멀티모니터에 서로 다른 값이 적용된 상태에서
    /// 첫 대상 값만 보고 틀린 체크마크를 달지 않게 한다(nil = 체크 없음).
    static func commonValue(_ values: [Float]) -> Float? {
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}

/// 시그니처: 하단 Now Playing 바 — 적용 중 배경의 애니 썸네일·제목 상시 + 재생 컨트롤 + 재생목록 + 가져오기.
struct NowPlayingBar: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var showPlaylist = false

    private var appliedEntry: LibraryEntry? {
        // F495: 전역 선택만 볼 경우 할당-전용 세션에서 재생 중인데도 "적용된 배경 없음"으로 표시됨.
        // 감사 V06: 대상 id 는 키 정렬 순(결정적) — Dictionary values 순회는 실행마다 달랐다.
        NowPlayingSubtitle.displayedEntry(global: viewModel.globalEntry,
                                          assignedIds: NowPlayingSubtitle.sortedAssignedIds(viewModel.monitors.all),
                                          entries: viewModel.entries)
    }

    var body: some View {
        HStack(spacing: 12) {
            thumb
            VStack(alignment: .leading, spacing: 2) {
                Text(appliedEntry?.title ?? "적용된 배경 없음")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(NowPlayingSubtitle.text(typeRaw: appliedEntry?.typeRaw,
                                             playlistCount: viewModel.playlist.ids.count,
                                             intervalMinutes: viewModel.playlist.intervalMinutes,
                                             playlistEnabled: viewModel.playlist.enabled))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 380, alignment: .leading)

            Spacer()

            Button {
                if let paused = viewModel.onTogglePause?() { viewModel.isPaused = paused }
            } label: {
                Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .help(viewModel.isPaused ? "재생" : "일시정지")

            Button { viewModel.onAdvancePlaylist?() } label: {
                Image(systemName: "forward.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.playlist.ids.count < 2)
            .help("다음 배경")

            // w5d-settings-ia: 동영상 음량/배속 — 재생 컨텍스트(appliedEntry)를 이미 아는 하단 바로
            // 설정 창에서 이관. 적용된 배경이 동영상일 때만 노출(그 외엔 컨트롤할 대상이 없다).
            if NowPlayingSubtitle.showsVideoControls(typeRaw: appliedEntry?.typeRaw) {
                videoControlsMenu
            }

            Divider().frame(height: 24)

            Button { showPlaylist.toggle() } label: {
                Label("재생목록", systemImage: "music.note.list")
            }
            .popover(isPresented: $showPlaylist, arrowEdge: .top) { playlistPopover }

            Button { openWallpaperPanel() } label: {
                Label("가져오기", systemImage: "plus")
            }
            .help("Wallpaper Engine 폴더·zip·동영상 가져오기")
        }
        .padding(.horizontal, 16)
        .frame(height: Metrics.nowPlayingHeight)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var thumb: some View {
        Group {
            if let e = appliedEntry, let url = viewModel.previewURL(for: e) {
                AnimatedPreviewView(url: url, animating: !viewModel.isPaused).scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
            }
        }
        .frame(width: Metrics.nowPlayingThumb, height: Metrics.nowPlayingThumb)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 음량/배속 메뉴(w5d-settings-ia). F820 으로 리마운트 없는 라이브 반영이 됐지만, 연속
    /// 슬라이더는 드래그 틱마다 UserDefaults 쓰기+플레이어 조정을 유발하므로 이산 스텝 유지 —
    /// SettingsPresentation 의 기존 스텝을 재사용해 설정 창과 동일한 값 집합(저장값 호환).
    /// 대상은 videoTargetIds()(모니터별 할당 포함, 설정 창과 동일 소스).
    private var videoControlsMenu: some View {
        Menu {
            Section("음량") {
                ForEach(SettingsPresentation.volumeSteps, id: \.value) { step in
                    Button {
                        applyToVideoTargets { VideoSettings.setVolume(step.value, id: $0) }
                    } label: {
                        if step.value == currentVideoVolume {
                            Label(step.label, systemImage: "checkmark")
                        } else {
                            Text(step.label)
                        }
                    }
                }
            }
            Section("배속") {
                ForEach(SettingsPresentation.rateSteps, id: \.value) { step in
                    Button {
                        applyToVideoTargets { VideoSettings.setRate(step.value, id: $0) }
                    } label: {
                        if step.value == currentVideoRate {
                            Label(step.label, systemImage: "checkmark")
                        } else {
                            Text(step.label)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: currentVideoVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.title3)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("동영상 음량 · 배속")
    }

    private var currentVideoVolume: Float? {
        NowPlayingSubtitle.commonValue(viewModel.videoTargetIds().map { VideoSettings.volume(id: $0) })
    }
    private var currentVideoRate: Float? {
        NowPlayingSubtitle.commonValue(viewModel.videoTargetIds().map { VideoSettings.rate(id: $0) })
    }

    /// 현재 적용 중인 모든 동영상 대상(모니터별 할당 포함)에 변경을 저장하고 라이브 반영을 태운다
    /// (F820 — 리마운트 없이 AVPlayer.volume/defaultRate 직접 조정, 재생 리셋 없음).
    private func applyToVideoTargets(_ mutate: (String) -> Void) {
        let ids = viewModel.videoTargetIds()
        guard !ids.isEmpty else { return }
        ids.forEach(mutate)
        viewModel.onVideoSettingsChanged?()
    }

    /// 재생목록 관리: 자동 전환·간격 + 선택 항목 추가/제거 + 목록.
    private var playlistPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            // playlist(PlaylistStore)는 @Published 가 아니라 직접 mutate 만으로는 body(간격 라벨·부제)가
            // 재평가되지 않는다 — togglePlaylist 전례처럼 owning VM 에 objectWillChange 를 쏘아 갱신을 건다.
            Toggle("자동 전환", isOn: Binding(
                get: { viewModel.playlist.enabled },
                set: { viewModel.playlist.enabled = $0; viewModel.objectWillChange.send(); viewModel.onPlaylistChanged?() }))
            Stepper(String(format: NSLocalizedString("간격: %lld분", comment: "재생목록 전환 간격"),
                            viewModel.playlist.intervalMinutes), value: Binding(
                get: { viewModel.playlist.intervalMinutes },
                set: { viewModel.playlist.intervalMinutes = $0; viewModel.objectWillChange.send(); viewModel.onPlaylistChanged?() }), in: 1...240)
            // w5d-playback: 고정 순서만 순환하던 자동 전환에 무작위 순서 옵션 추가.
            Toggle("셔플(무작위 순서)", isOn: Binding(
                get: { viewModel.playlist.shuffle },
                set: { viewModel.playlist.shuffle = $0; viewModel.objectWillChange.send(); viewModel.onPlaylistChanged?() }))
            if let focused = viewModel.focusedEntry {
                Button(viewModel.isInPlaylist(focused) ? "'\(focused.title)' 제거" : "'\(focused.title)' 추가") {
                    viewModel.togglePlaylist(focused)
                }
            }
            Divider()
            if viewModel.playlist.ids.isEmpty {
                Text("재생목록이 비어 있습니다 — 타일 우클릭 또는 위 버튼으로 추가하세요")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.playlist.ids, id: \.self) { id in
                    Text(viewModel.entries.first { $0.id == id }?.title ?? id)
                        .font(.caption).lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    /// '가져오기' = 디스크에서 임포트(WallpaperGridView 와 공유하는 ImportPanel — 폴더/zip/동영상).
    private func openWallpaperPanel() {
        ImportPanel.run(into: viewModel)
    }
}
