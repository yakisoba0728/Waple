import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WapleCore
import WapleLibrary

/// 미리보기 이미지 디코드 캐시(URL→NSImage). body 재평가마다의 반복 디스크 I/O 제거.
private enum PreviewImageCache {
    private static let cache = NSCache<NSURL, NSImage>()
    static func image(_ url: URL) -> NSImage? {
        if let c = cache.object(forKey: url as NSURL) { return c }
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

/// 네이티브 그리드: underPage 우물 + 라운드 썸네일 타일(제목 아래) + 호버 라이브 프리뷰/리프트 +
/// 적용 중 액센트 링. 클릭=선택, 더블클릭=적용(기존 UX 유지).
struct WallpaperGridView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var hoveredId: String?
    @State private var newFolderName = ""
    @State private var folderPromptEntry: LibraryEntry?
    @State private var removeConfirmEntry: LibraryEntry?

    private let columns = [GridItem(.adaptive(minimum: Metrics.tileWidth), spacing: Metrics.gridSpacing)]

    /// 검색/필터가 활성인데 그리드가 0건인가(w5d-library) — 판정은 LibraryFiltering(순수)에 위임.
    private var isSearchOrFilterDeadEnd: Bool {
        LibraryFiltering.isSearchOrFilterDeadEnd(searchText: viewModel.searchText,
                                                  criteria: viewModel.criteria,
                                                  filteredCount: viewModel.filteredEntries.count)
    }

    var body: some View {
        Group {
            if viewModel.entries.isEmpty {
                emptyState
            } else if isSearchOrFilterDeadEnd {
                noResultsState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Metrics.gridSpacing + 6) {
                        if let active = viewModel.activeFolder {
                            backTile(active)
                        }
                        ForEach(viewModel.visibleFolders, id: \.name) { folder in
                            folderTile(folder)
                        }
                        ForEach(viewModel.filteredEntries, id: \.id) { entry in
                            tile(for: entry)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop($0) }
        .alert("새 폴더", isPresented: Binding(get: { folderPromptEntry != nil },
                                              set: { if !$0 { folderPromptEntry = nil } })) {
            TextField("폴더 이름", text: $newFolderName)
            Button("만들기") {
                if let e = folderPromptEntry, !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty {
                    viewModel.moveToFolder(e, folder: newFolderName)
                }
                newFolderName = ""; folderPromptEntry = nil
            }
            Button("취소", role: .cancel) { newFolderName = ""; folderPromptEntry = nil }
        }
        // 그리드 우클릭 "라이브러리에서 제거"(w5d-library) — SelectionPanelView 의 확인 대화상자와
        // 동일한 문구/역할로 그리드에서도 완결(우측 패널로 다시 포커스할 필요 없음).
        .confirmationDialog(
            removeConfirmEntry.map { "'\($0.title)'을(를) 라이브러리에서 제거할까요?" } ?? "",
            isPresented: Binding(get: { removeConfirmEntry != nil },
                                 set: { if !$0 { removeConfirmEntry = nil } })
        ) {
            if let e = removeConfirmEntry {
                Button("제거(파일은 유지)", role: .destructive) { viewModel.remove(e); removeConfirmEntry = nil }
            }
            Button("취소", role: .cancel) { removeConfirmEntry = nil }
        } message: {
            Text("디스크의 원본 폴더는 삭제되지 않습니다. 재생목록·모니터 할당·즐겨찾기·폴더에서 함께 제거됩니다.")
        }
    }

    private func folderTile(_ folder: FolderStore.Folder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: Metrics.tileCorner)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
                Image(systemName: "folder.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(height: Metrics.tileThumbHeight)
            Text("\(folder.name)  ·  \(folder.ids.count)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.activeFolder = folder.name }
        .contextMenu {
            Button("폴더 삭제(항목은 유지)") {
                viewModel.folders.removeFolder(folder.name)
                viewModel.objectWillChange.send()
            }
        }
    }

    private func backTile(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: Metrics.tileCorner)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.15))
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 32)).foregroundStyle(.secondary)
            }
            .frame(height: Metrics.tileThumbHeight)
            Text("뒤로 — \(name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.activeFolder = nil }
    }

    // 네이티브 빈 상태(w5d-polish) — WorkshopTabView:33 이 이미 채택한 ContentUnavailableView 문법 준용.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("라이브러리가 비어 있습니다", systemImage: "photo.stack")
        } description: {
            Text("Wallpaper Engine 폴더·zip·동영상을 드래그하거나 가져오세요")
        } actions: {
            Button("배경화면 가져오기…") { importFolder() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o")
            // w5d-onboarding: 번들 샘플이 없는 첫 실행 사용자를 위한 대체 콘텐츠 경로 — 창작마당(다운로드)으로.
            Button("창작마당 열기") { viewModel.onOpenWorkshop?() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 검색/필터 무결과 dead-end(w5d-library) — 고장인지 결과가 없는 건지 구분하고, 되돌릴 원클릭
    /// 수단을 준다(종전엔 아무 메시지도 없는 빈 스크롤 영역이라 툴바로 돌아가 일일이 해제해야 했다).
    private var noResultsState: some View {
        ContentUnavailableView {
            Label("조건에 맞는 배경이 없습니다", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("검색어나 필터를 조정해보세요")
        } actions: {
            Button("필터 초기화 / 검색 지우기") {
                viewModel.searchText = ""
                viewModel.criteria = LibraryFilterCriteria()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tile(for entry: LibraryEntry) -> some View {
        let supported = viewModel.isSupported(entry)
        let focused = viewModel.focusedId == entry.id
        let applied = viewModel.selectedId == entry.id
        let hovered = hoveredId == entry.id

        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                preview(for: entry, animating: hovered)
                    .frame(height: Metrics.tileThumbHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.tileCorner))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.tileCorner)
                    .stroke(applied ? Color.accentColor : (focused ? Color.secondary.opacity(0.6) : .clear),
                            lineWidth: applied ? 2.5 : 1.5)
            )
            .overlay(alignment: .topTrailing) { typeBadge(for: entry, supported: supported) }
            .overlay(alignment: .bottomLeading) {
                if applied {
                    Image(systemName: "play.circle.fill")
                        .font(.body)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                }
            }
            .saturation(supported ? 1 : 0.4)
            .opacity(supported ? 1 : 0.55)

            Text(entry.title)
                .font(.caption)
                .foregroundStyle(focused ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .scaleEffect(hovered ? 1.02 : 1)
        .shadow(color: .black.opacity(hovered ? 0.45 : 0), radius: 9, y: 5)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovered)
        .contentShape(Rectangle())
        .onHover { hoveredId = $0 ? entry.id : (hoveredId == entry.id ? nil : hoveredId) }
        .onTapGesture(count: 2) { if supported { _ = viewModel.apply(entry) } }
        .onTapGesture { viewModel.focusedId = entry.id }
        .contextMenu { contextMenu(for: entry, supported: supported) }
    }

    private func typeBadge(for entry: LibraryEntry, supported: Bool) -> some View {
        Label(supported ? NowPlayingSubtitle.typeLabel(entry.typeRaw) : "지원 예정",
              systemImage: typeSymbol(entry.typeRaw))
            .font(.caption2)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(6)
    }

    private func typeSymbol(_ raw: String) -> String {
        switch WallpaperType.from(raw) {
        case .scene: return "sparkles"
        case .video: return "play.rectangle.fill"
        case .web: return "globe"
        case .preset: return "square.stack"
        case .application, .unknown: return "questionmark.circle"
        }
    }

    @ViewBuilder
    private func preview(for entry: LibraryEntry, animating: Bool) -> some View {
        if let url = viewModel.previewURL(for: entry) {
            if PreviewMedia.isAnimated(url) {
                AnimatedPreviewView(url: url, animating: animating).scaledToFill()
            } else if let image = PreviewImageCache.image(url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholderThumb
            }
        } else {
            placeholderThumb
        }
    }

    private var placeholderThumb: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
            Image(systemName: "photo").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: LibraryEntry, supported: Bool) -> some View {
        Button("선택(속성 보기)") {
            // 패널이 접혀 있어도 즉시 보이도록(F103류 데드엔드 방지) — MainWindowView 의 기존 패널
            // 토글과 동일한 스프링으로 트랜지션(:127 .move(edge: .trailing))을 재사용한다.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { viewModel.selectForPropertiesView(entry) }
        }
        if supported { Button("적용") { _ = viewModel.apply(entry) } }
        if WallpaperType.from(entry.typeRaw) == .web {
            Button("적용 + 조작 창 열기") { _ = viewModel.apply(entry); viewModel.onOpenInteraction?() }
        }
        if supported {
            Button(viewModel.isInPlaylist(entry) ? "재생목록에서 제거" : "재생목록에 추가") { viewModel.togglePlaylist(entry) }
            Menu("폴더로 이동") {
                Button("새 폴더…") { folderPromptEntry = entry }
                if !viewModel.folders.folders.isEmpty { Divider() }
                ForEach(viewModel.folders.folders, id: \.name) { f in
                    Button(f.name) { viewModel.moveToFolder(entry, folder: f.name) }
                }
                if viewModel.folders.folderName(of: entry.id) != nil {
                    Divider()
                    Button("폴더에서 제거") { viewModel.moveToFolder(entry, folder: nil) }
                }
            }
            Menu("모니터에 적용") {
                ForEach(viewModel.screens, id: \.key) { screen in
                    Button(screen.name + (viewModel.assignedEntryTitle(forScreen: screen.key).map { " (현재: \($0))" } ?? "")) {
                        viewModel.assign(entry, toScreen: screen.key)
                    }
                }
                if viewModel.screens.contains(where: { viewModel.assignedEntryTitle(forScreen: $0.key) != nil }) {
                    Divider()
                    ForEach(viewModel.screens.filter { viewModel.assignedEntryTitle(forScreen: $0.key) != nil }, id: \.key) { screen in
                        Button("\(screen.name) 할당 해제") { viewModel.clearAssignment(forScreen: screen.key) }
                    }
                }
            }
        }
        // 정리 그룹(w5d-library) — 즐겨찾기·Finder·제거는 우측 패널로 다시 포커스하지 않아도
        // 그리드에서 벗어나지 않고 완결된다.
        Divider()
        Button(viewModel.isFavorite(entry) ? "즐겨찾기 해제" : "즐겨찾기") { viewModel.toggleFavorite(entry) }
        Button("Finder에서 보기") { revealInFinder(entry) }
        Button("라이브러리에서 제거", role: .destructive) { removeConfirmEntry = entry }
    }

    /// 원본 폴더를 Finder 로 열어 선택 표시(macOS 보편 관례) — 해석 실패(북마크 stale 등) → 무동작.
    private func revealInFinder(_ entry: LibraryEntry) {
        guard let url = viewModel.folderURL(for: entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: 임포트(로직 무변경)

    func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .zip, .movie]
        panel.allowsMultipleSelection = false
        panel.message = "Wallpaper Engine 폴더·상위 폴더·.zip·동영상(mp4/mov)을 선택하세요."
        if panel.runModal() == .OK, let url = panel.url { routeImport(url) }
    }

    private func routeImport(_ url: URL) {
        if url.pathExtension.lowercased() == "zip" { viewModel.importZip(url) }
        else if VideoImport.isVideoFile(url) { viewModel.importVideoFile(url) }
        else { viewModel.importParent(url) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileURL = UTType.fileURL.identifier
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(fileURL) {
            handled = true
            provider.loadItem(forTypeIdentifier: fileURL, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { self.routeImport(url) }
            }
        }
        return handled
    }
}
