import SwiftUI
import WapleCore
import WapleLibrary

/// 우측 상세 패널: 히어로 프리뷰(상시 애니) → 제목·메타 → 액션 → 속성 편집.
struct SelectionPanelView: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        Group {
            if let entry = viewModel.focusedEntry {
                content(for: entry)
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("배경을 선택하세요").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .frame(width: Metrics.panelWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func content(for entry: LibraryEntry) -> some View {
        let supported = viewModel.isSupported(entry)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if let url = viewModel.previewURL(for: entry) {
                        AnimatedPreviewView(url: url, animating: true)
                    } else {
                        ZStack {
                            Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                            Image(systemName: "photo").foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(height: Metrics.heroHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title).font(.title3.weight(.semibold)).lineLimit(2)
                    Text(NowPlayingSubtitle.typeLabel(entry.typeRaw) + (supported ? "" : " · 지원 예정"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    Button {
                        _ = viewModel.apply(entry)
                    } label: {
                        Label("배경으로 적용", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!supported)

                    HStack(spacing: 8) {
                        Menu {
                            ForEach(viewModel.screens, id: \.key) { screen in
                                Button(screen.name) { viewModel.assign(entry, toScreen: screen.key) }
                            }
                        } label: {
                            Label("모니터별", systemImage: "display")
                        }
                        .disabled(!supported)

                        Button {
                            viewModel.togglePlaylist(entry)
                        } label: {
                            Label(viewModel.isInPlaylist(entry) ? "목록 제거" : "목록 추가",
                                  systemImage: viewModel.isInPlaylist(entry) ? "minus.circle" : "plus.circle")
                        }
                        .disabled(!supported)
                    }
                    .frame(maxWidth: .infinity)

                    if WallpaperType.from(entry.typeRaw) == .web {
                        Button {
                            viewModel.onOpenInteraction?()
                        } label: {
                            Label("조작 창 열기", systemImage: "cursorarrow.click").frame(maxWidth: .infinity)
                        }
                    }
                }

                Divider()

                // 기존 편집기 임베드(내부 리스타일은 SP2′). id로 엔트리 전환 시 상태 리셋.
                PropertyEditorView(entry: entry, viewModel: viewModel).id(entry.id)
            }
            .padding(16)
        }
    }
}
