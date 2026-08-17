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

    /// 유형 + 미지원 꼬리표 한 줄. 조립을 뷰 밖으로 뺀 이유는 두 가지다.
    ///
    /// 종전에는 `유형라벨 + " · 지원 예정"` 문자열 덧셈이었다. 앞쪽은 이미 번역된 값인데
    /// 뒤쪽 꼬리표는 생 한국어라, 영어 시스템에서 "Video · 지원 예정" 처럼 반만 번역된 줄이
    /// 나온다. 완성된 문자열을 넘기려면 꼬리표까지 포함해 포맷 지정자로 조립해야 한다.
    /// 그리고 뷰 빌더 안에서 조건 분기로 문자열을 만들면 그 자리의 식이 길어진다(타입체커).
    private func metaLine(_ entry: LibraryEntry, supported: Bool) -> String {
        let type = NowPlayingSubtitle.typeLabel(entry.typeRaw)
        guard !supported else { return type }
        return String(format: NSLocalizedString("%@ · 지원 예정", comment: "미지원 배경 메타 줄"), type)
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
                        // 삼항으로 문자열을 고르면 어느 쪽도 스캔 패턴에 안 걸린다(여는 괄호 뒤가
                        // 따옴표가 아니다). Text 를 골라야 둘 다 잡히고 둘 다 번역된다.
                        .help(viewModel.isFavorite(entry) ? Text("즐겨찾기 해제") : Text("즐겨찾기"))
                    }
                    HStack(spacing: 6) {
                        Text(verbatim: metaLine(entry, supported: supported))
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
                    // F503: .keyboardShortcut(.defaultAction) 제거 — 창 전체에 걸리는 바로가기라
                    // 패널 표시 중 검색 필드 등 무관한 포커스에서 Enter 를 쳐도 포커스된 엔트리가
                    // 적용(전체 리마운트)되는 오발동 풋건이 있었다. 적용은 더블클릭·컨텍스트 메뉴·
                    // 이 버튼 클릭으로 충분하다(비파괴적이라 low 판단이나 오발동 방지가 낫다고 판단).
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
                            // 이 자리가 영어 캡처에서 유일하게 한국어로 남아 있던 곳이다 —
                            // 삼항이 고르던 것이 String 이라 번역이 조용히 사라졌다.
                            Label(title: { viewModel.isInPlaylist(entry) ? Text("목록 제거") : Text("목록 추가") },
                                  icon: { Image(systemName: viewModel.isInPlaylist(entry) ? "minus.circle" : "plus.circle") })
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
                    .confirmationDialog(String(format: NSLocalizedString("'%@'을(를) 라이브러리에서 제거할까요?", comment: "라이브러리 제거 확인"), entry.title),
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
