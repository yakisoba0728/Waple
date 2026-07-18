import SwiftUI
import WapleCore
import WapleLibrary

/// 우측 상세 패널: 히어로 프리뷰(상시 애니) → 제목·메타 → 액션 → 속성 편집.
struct SelectionPanelView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var confirmRemove = false
    /// 초기화 시 PropertyEditorView 를 재마운트(onAppear 재로드)해 편집기 상태를 새로고침.
    @State private var propsGeneration = 0

    var body: some View {
        Group {
            if let entry = viewModel.focusedEntry {
                content(for: entry)
            } else {
                // 네이티브 빈 상태(w5d-polish) — WorkshopTabView:33 과 동일한 ContentUnavailableView 문법.
                ContentUnavailableView("배경을 선택하세요", systemImage: "photo.on.rectangle.angled")
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
                        AnimatedPreviewView(url: url, animating: true).scaledToFill()
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
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.title).font(.title3.weight(.semibold)).lineLimit(2)
                        Spacer()
                        Button {
                            viewModel.toggleFavorite(entry)
                        } label: {
                            Image(systemName: viewModel.isFavorite(entry) ? "heart.fill" : "heart")
                                .foregroundStyle(viewModel.isFavorite(entry) ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(viewModel.isFavorite(entry) ? "즐겨찾기 해제" : "즐겨찾기")
                    }
                    HStack(spacing: 6) {
                        Text(NowPlayingSubtitle.typeLabel(entry.typeRaw) + (supported ? "" : " · 지원 예정"))
                        if let r = entry.rating {
                            Label(String(format: "%.1f/5", r * 5), systemImage: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
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

                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Label("라이브러리에서 제거", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .confirmationDialog("'\(entry.title)'을(를) 라이브러리에서 제거할까요?",
                                        isPresented: $confirmRemove) {
                        Button("제거(파일은 유지)", role: .destructive) { viewModel.remove(entry) }
                        Button("취소", role: .cancel) {}
                    } message: {
                        Text("디스크의 원본 폴더는 삭제되지 않습니다. 재생목록·모니터 할당·즐겨찾기·폴더에서 함께 제거됩니다.")
                    }
                }

                Divider()

                HStack {
                    Text("속성").font(.headline)
                    Spacer()
                    Button("초기화") {
                        viewModel.resetProperties(for: entry)
                        propsGeneration += 1
                    }
                    .font(.caption)
                }
                // 기존 편집기 임베드(내부 리스타일은 SP2′). id로 엔트리 전환/초기화 시 재마운트(상태 리셋).
                PropertyEditorView(entry: entry, viewModel: viewModel).id("\(entry.id)-\(propsGeneration)")
            }
            .padding(16)
        }
    }
}
