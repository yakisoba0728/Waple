import SwiftUI
import WapleLibrary

enum MainTab: String, CaseIterable {
    case installed, workshop, displays
    var label: String {
        switch self {
        case .installed: return "설치됨"; case .workshop: return "워크샵"; case .displays: return "디스플레이"
        }
    }
}

/// WE식 통합 메인창: 상단 탭/검색/필터 + 콘텐츠 + 하단 상태 바.
struct MainWindowView: View {
    @ObservedObject var viewModel: LibraryViewModel
    var screenFrames: () -> [CGRect]
    @State private var tab: MainTab = .installed

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
            Divider()
            bottomBar
        }
        .frame(minWidth: 1100, minHeight: 700)
    }

    @ViewBuilder
    private var topBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                ForEach(MainTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        Text(t.label).font(.system(size: 13, weight: tab == t ? .bold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(tab == t ? Color.accentColor.opacity(0.25) : .clear)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            if tab == .installed {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("검색", text: $viewModel.searchText).textFieldStyle(.plain).frame(width: 180)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(6)
                Picker("", selection: $viewModel.typeFilter) {
                    ForEach(LibraryTypeFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 110)
                Picker("", selection: $viewModel.sortOrder) {
                    ForEach(LibrarySortOrder.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 130)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .installed:
            HStack(spacing: 0) {
                WallpaperGridView(viewModel: viewModel)
                Divider()
                SelectionPanelView(viewModel: viewModel)
            }
        case .workshop:
            WorkshopView(library: viewModel)
        case .displays:
            DisplaysTabView(viewModel: viewModel, screenFrames: screenFrames)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 16) {
            Text("현재: \(viewModel.appliedTitle ?? "없음")").font(.caption).lineLimit(1)
            Spacer()
            Button {
                viewModel.onAdvancePlaylist?()
            } label: { Label("다음 배경", systemImage: "forward.fill").font(.caption) }
            .disabled(viewModel.playlist.ids.count < 2)
            Button {
                if let paused = viewModel.onTogglePause?() { viewModel.isPaused = paused }
            } label: {
                Label(viewModel.isPaused ? "재개" : "일시정지",
                      systemImage: viewModel.isPaused ? "play.fill" : "pause.fill").font(.caption)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
