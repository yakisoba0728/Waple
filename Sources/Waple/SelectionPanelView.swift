import SwiftUI
import WapleCore
import WapleLibrary

/// 우측 상시 패널(WE 우측 컬럼): 선택 배경의 프리뷰·메타·액션·속성 편집.
struct SelectionPanelView: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        Group {
            if let entry = viewModel.focusedEntry {
                content(for: entry)
            } else {
                VStack {
                    Spacer()
                    Text("배경을 선택하세요").foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .frame(width: 300)
        .background(WETheme.Colors.panel)
    }

    @ViewBuilder
    private func content(for entry: LibraryEntry) -> some View {
        let supported = viewModel.isSupported(entry)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                previewBlock(for: entry)
                Text(entry.title).font(.headline).lineLimit(2)
                Text(WallpaperType.from(entry.typeRaw).storageString + (supported ? "" : " · 지원 예정"))
                    .font(.caption).foregroundColor(.secondary)
                actionButtons(for: entry, supported: supported)
                Divider()
                Text("속성").font(.subheadline).bold()
                // 기존 편집기 임베드 — 시트 폐지. id로 엔트리 전환 시 상태 리셋.
                PropertyEditorView(entry: entry, viewModel: viewModel).id(entry.id)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func previewBlock(for entry: LibraryEntry) -> some View {
        Group {
            if let url = viewModel.previewURL(for: entry) {
                AnimatedPreviewView(url: url, animating: true)   // 패널은 상시 재생(WE 동일)
            } else {
                Rectangle().fill(Color.gray.opacity(0.3))
            }
        }
        .frame(height: 158).frame(maxWidth: .infinity).clipped().cornerRadius(8)
    }

    @ViewBuilder
    private func actionButtons(for entry: LibraryEntry, supported: Bool) -> some View {
        VStack(spacing: 8) {
            Button { _ = viewModel.apply(entry) } label: {
                Text("배경으로 적용").frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!supported)
            HStack(spacing: 8) {
                Menu("모니터에 적용") {
                    ForEach(viewModel.screens, id: \.key) { screen in
                        Button(screen.name) { viewModel.assign(entry, toScreen: screen.key) }
                    }
                }
                .disabled(!supported)
                Button(viewModel.isInPlaylist(entry) ? "재생목록 제거" : "재생목록 추가") {
                    viewModel.togglePlaylist(entry)
                }
                .disabled(!supported)
            }
            if WallpaperType.from(entry.typeRaw) == .web {
                Button("조작 창 열기") { viewModel.onOpenInteraction?() }.frame(maxWidth: .infinity)
            }
        }
    }
}
