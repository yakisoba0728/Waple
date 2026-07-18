import SwiftUI
import AppKit
import WapleCore
import WapleLibrary

/// Now Playing 부제(순수): 타입 라벨 + 재생목록 상태. 뷰와 분리해 단위 테스트.
enum NowPlayingSubtitle {
    static func text(typeRaw: String?, playlistCount: Int, intervalMinutes: Int, playlistEnabled: Bool) -> String {
        guard let typeRaw else { return "라이브러리에서 배경을 선택하세요" }
        var parts = [typeLabel(typeRaw)]
        if playlistCount > 0 { parts.append("재생목록 \(playlistCount)개") }
        if playlistEnabled, playlistCount > 0 { parts.append("\(intervalMinutes)분마다 전환") }
        return parts.joined(separator: " · ")
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
}

/// 시그니처: 하단 Now Playing 바 — 적용 중 배경의 애니 썸네일·제목 상시 + 재생 컨트롤 + 재생목록 + 가져오기.
struct NowPlayingBar: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var showPlaylist = false

    private var appliedEntry: LibraryEntry? {
        viewModel.entries.first { $0.id == viewModel.selectedId }
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

    /// 재생목록 관리: 자동 전환·간격 + 선택 항목 추가/제거 + 목록.
    private var playlistPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            // playlist(PlaylistStore)는 @Published 가 아니라 직접 mutate 만으로는 body(간격 라벨·부제)가
            // 재평가되지 않는다 — togglePlaylist 전례처럼 owning VM 에 objectWillChange 를 쏘아 갱신을 건다.
            Toggle("자동 전환", isOn: Binding(
                get: { viewModel.playlist.enabled },
                set: { viewModel.playlist.enabled = $0; viewModel.objectWillChange.send(); viewModel.onPlaylistChanged?() }))
            Stepper("간격: \(viewModel.playlist.intervalMinutes)분", value: Binding(
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
