import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WapleCore
import WapleLibrary

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
                    LazyVGrid(columns: columns, spacing: Metrics.gridRowSpacing) {
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
                    .padding(Space.contentInset)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ColorRole.well)
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
        // 제목이 끼는 문구는 String(format:) 로 조립한다 — 보간으로 만들면 그 문자열이
        // 비현지화 오버로드로 붙어 영어에서 한국어가 그대로 나온다. 같은 문구를 인스펙터는
        // 이미 이 방식으로 조립하고 있었고, 여기만 갈라져 있었다(2026-08-17 실측).
        .confirmationDialog(
            removeConfirmEntry.map {
                String(format: NSLocalizedString("'%@'을(를) 라이브러리에서 제거할까요?",
                                                 comment: "라이브러리 제거 확인"), $0.title)
            } ?? "",
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
            Text(String(format: NSLocalizedString("뒤로 — %@", comment: "폴더 뒤로가기"), name)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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

    private func tile(for entry: LibraryEntry) -> some View {
        let supported = viewModel.isSupported(entry)
        let applied = viewModel.selectedId == entry.id
        return tileSurface(entry, supported: supported, applied: applied)
            .modifier(tileActions(entry, supported: supported))
            .contextMenu { contextMenu(for: entry, supported: supported) }
    }

    /// 타일 본체 + 포인터 제스처 + 표준 접근성 표현.
    ///
    /// 종전에는 이 자리가 화면에서만 버튼이었다 — 보조기술에는 이미지 하나와 텍스트 하나가
    /// 따로 읽히고, 누를 수 있다는 것도 지금 적용 중이라는 것도 전달되지 않았으며 키보드로는
    /// 닿을 수조차 없었다. 표준 형태(청사진 §4.1)를 그대로 쓴다.
    ///
    /// 주 동작(Return)은 더블클릭과 **같은 조건**이다 — 미지원 배경은 마우스로도 적용되지
    /// 않으므로 키보드에서만 되게 하면 두 경로가 갈린다. 미지원 타일도 포커스 대상으로는
    /// 남긴다: 탭 순서에서 빠지면 그 항목이 있다는 사실 자체가 전달되지 않는다.
    private func tileSurface(_ entry: LibraryEntry, supported: Bool, applied: Bool) -> some View {
        let focused = viewModel.focusedId == entry.id
        let hovered = hoveredId == entry.id
        return VStack(alignment: .leading, spacing: Space.xs) {
            thumbnail(entry, supported: supported, applied: applied, focused: focused, hovered: hovered)
            Text(entry.title)
                .font(Typography.caption)
                .foregroundStyle(focused ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, Space.captionInset)
        }
        .tileLift(hovered)
        .contentShape(Rectangle())
        .onHover { hoveredId = $0 ? entry.id : (hoveredId == entry.id ? nil : hoveredId) }
        .onTapGesture(count: 2) { activate(entry, supported: supported) }
        .onTapGesture { viewModel.focusedId = entry.id }
        .tileAccessibility(label: Text(entry.title),
                           value: tileStatus(applied: applied, supported: supported),
                           isSelected: applied,
                           onActivate: { activate(entry, supported: supported) })
    }

    private func thumbnail(_ entry: LibraryEntry, supported: Bool,
                           applied: Bool, focused: Bool, hovered: Bool) -> some View {
        ZStack {
            preview(for: entry, animating: hovered)
                .frame(height: Metrics.tileThumbHeight)
                .frame(maxWidth: .infinity)
        }
        .tileThumbnailClip()
        .tileRing(TileRing.tile(selected: applied, focused: focused))
        .overlay(alignment: .topTrailing) { typeBadge(for: entry, supported: supported) }
        .overlay(alignment: .bottomLeading) { appliedGlyph(applied) }
        .saturation(supported ? 1 : ColorRole.unsupportedSaturation)
        .opacity(supported ? 1 : ColorRole.unsupportedOpacity)
    }

    /// 적용 중임을 색(액센트 링)만이 아니라 글리프로도 말한다 — 색만으로 상태를 전달하면
    /// 색약 사용자에게 링과 무링의 구분이 사라진다(청사진 §4.5).
    @ViewBuilder
    private func appliedGlyph(_ applied: Bool) -> some View {
        if applied {
            Image(systemName: "play.circle.fill")
                .font(Typography.body)
                .symbolRenderingMode(.palette)
                .foregroundStyle(ColorRole.onMedia, ColorRole.selected)
                .padding(Space.xs)
        }
    }

    /// 보조기술이 읽는 현재 상태. 라벨(무엇인가)에 이어 붙이지 않는 이유는 상태가 바뀔 때마다
    /// 항목 전체가 다시 읽히기 때문이다(청사진 §4.2).
    private func tileStatus(applied: Bool, supported: Bool) -> Text? {
        if applied { return Text("적용 중") }
        if !supported { return Text("지원 예정") }
        return nil
    }

    /// 주 동작 — 더블클릭과 Return 이 공유한다.
    private func activate(_ entry: LibraryEntry, supported: Bool) {
        guard supported else { return }
        _ = viewModel.apply(entry)
    }

    private func typeBadge(for entry: LibraryEntry, supported: Bool) -> some View {
        TypeBadge(symbol: typeSymbol(entry.typeRaw),
                  label: supported ? Text(verbatim: NowPlayingSubtitle.typeLabel(entry.typeRaw))
                                   : Text("지원 예정"))
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
        let url = viewModel.previewURL(for: entry)
        if let url, PreviewMedia.isAnimated(url) {
            AnimatedPreviewView(url: url, animating: animating).scaledToFill()
        } else {
            // F500: 정지 프리뷰는 비동기 로드 뷰 — body 평가 중 메인 동기 디스크 읽기 제거.
            // nil 도 이 뷰가 받는다(플레이스홀더 내장) — 호출부에서 다시 그리지 않는다.
            PreviewThumbnail(url: url)
        }
    }

    /// 우클릭 메뉴 항목과 1:1 로 대응하는 접근성 액션 묶음.
    ///
    /// 우클릭은 마우스 전용이다 — 이 메뉴의 항목 중 절반은 다른 어떤 경로로도 도달할 수
    /// 없어서, 보조기술·키보드 사용자에게는 그 기능들이 존재하지 않는 것과 같았다.
    /// 중첩 메뉴 둘(폴더로 이동·모니터에 적용)은 평탄화가 불가능하므로 대표 액션 하나로
    /// **인스펙터를 여는 것**으로 대체한다. 인스펙터에 같은 컨트롤이 있고, 그쪽은 표준
    /// 컨트롤이라 처음부터 접근 가능하다(청사진 §4.3).
    private func tileActions(_ entry: LibraryEntry, supported: Bool) -> TileContextActions {
        TileContextActions(
            supported: supported,
            isWeb: WallpaperType.from(entry.typeRaw) == .web,
            playlistLabel: viewModel.isInPlaylist(entry) ? Text("재생목록에서 제거") : Text("재생목록에 추가"),
            favoriteLabel: viewModel.isFavorite(entry) ? Text("즐겨찾기 해제") : Text("즐겨찾기"),
            select: { showProperties(entry) },
            apply: { _ = viewModel.apply(entry) },
            applyAndOpenInteraction: { _ = viewModel.apply(entry); viewModel.onOpenInteraction?() },
            togglePlaylist: { viewModel.togglePlaylist(entry) },
            toggleFavorite: { viewModel.toggleFavorite(entry) },
            reveal: { revealInFinder(entry) },
            confirmRemove: { removeConfirmEntry = entry })
    }

    /// 패널이 접혀 있어도 즉시 보이도록(F103류 데드엔드 방지) 포커스와 노출을 함께 바꾼다.
    private func showProperties(_ entry: LibraryEntry) {
        Motion.run(Motion.reveal) { viewModel.selectForPropertiesView(entry) }
    }

    @ViewBuilder
    private func contextMenu(for entry: LibraryEntry, supported: Bool) -> some View {
        // 패널 개폐 곡선은 Motion 토큰이 소유한다 — 화면이 직접 곡선을 만들면 그 자리만
        // "동작 줄이기" 설정을 무시한다. 종전 값(response 0.3 / damping 0.85)이 그대로
        // Motion.reveal 로 승격돼 있어 감각은 바뀌지 않는다.
        Button("선택(속성 보기)") { showProperties(entry) }
        if supported { Button("적용") { _ = viewModel.apply(entry) } }
        if WallpaperType.from(entry.typeRaw) == .web {
            Button("적용 + 조작 창 열기") { _ = viewModel.apply(entry); viewModel.onOpenInteraction?() }
        }
        if supported {
            // 삼항으로 String 을 고르면 여는 괄호 뒤가 따옴표가 아니라 두 문구 다 커버리지
            // 스캔에서 빠진다 — 실제로 이 넷은 번역이 통째로 없었는데 아무 것도 실패하지
            // 않았다. Text 를 고르면 둘 다 잡히고 둘 다 번역된다(청사진 §5.3).
            Button { viewModel.togglePlaylist(entry) } label: {
                viewModel.isInPlaylist(entry) ? Text("재생목록에서 제거") : Text("재생목록에 추가")
            }
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
                    Button(screenMenuTitle(screen)) { viewModel.assign(entry, toScreen: screen.key) }
                }
                if viewModel.screens.contains(where: { viewModel.assignedEntryTitle(forScreen: $0.key) != nil }) {
                    Divider()
                    ForEach(viewModel.screens.filter { viewModel.assignedEntryTitle(forScreen: $0.key) != nil }, id: \.key) { screen in
                        Button(String(format: NSLocalizedString("%@ 할당 해제", comment: "모니터 할당 해제"), screen.name)) { viewModel.clearAssignment(forScreen: screen.key) }
                    }
                }
            }
        }
        // 정리 그룹(w5d-library) — 즐겨찾기·Finder·제거는 우측 패널로 다시 포커스하지 않아도
        // 그리드에서 벗어나지 않고 완결된다.
        Divider()
        Button { viewModel.toggleFavorite(entry) } label: {
            viewModel.isFavorite(entry) ? Text("즐겨찾기 해제") : Text("즐겨찾기")
        }
        Button("Finder에서 보기") { revealInFinder(entry) }
        Button("라이브러리에서 제거", role: .destructive) { removeConfirmEntry = entry }
    }

    /// 모니터 메뉴 항목 제목 — 화면 이름 + 현재 할당된 배경. 종전엔 꼬리표를 문자열 보간으로
    /// 붙여, 앞의 화면 이름은 시스템 값인데 꼬리표만 한국어로 남았다. 값이 둘이므로 포맷
    /// 지정자를 명시해 조립한다(AGENTS: 보간은 지정자 추론이 모호해진다).
    private func screenMenuTitle(_ screen: (key: String, name: String)) -> String {
        guard let current = viewModel.assignedEntryTitle(forScreen: screen.key) else { return screen.name }
        return String(format: NSLocalizedString("%@ (현재: %@)", comment: "모니터 메뉴 — 현재 할당"),
                      screen.name, current)
    }

    /// 원본 폴더를 Finder 로 열어 선택 표시(macOS 보편 관례) — 해석 실패(북마크 stale 등) → 무동작.
    private func revealInFinder(_ entry: LibraryEntry) {
        guard let url = viewModel.folderURL(for: entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: 임포트

    func importFolder() {
        ImportPanel.run(into: viewModel)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileURL = UTType.fileURL.identifier
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(fileURL) {
            handled = true
            provider.loadItem(forTypeIdentifier: fileURL, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { self.viewModel.routeImport(url) }
            }
        }
        return handled
    }
}

/// 그리드 타일의 접근성 액션 묶음. `WallpaperGridView.tileActions(_:supported:)` 가 만든다.
///
/// 뷰 빌더 밖의 별도 타입으로 뺀 이유는 둘이다. 하나는 타입체커 — 액션이 아홉이라 호출부
/// 체인에 그대로 이으면 그 자리의 식이 아홉 겹 더 깊어진다(이 저장소에서 네 번 터진 자리다).
/// 다른 하나는 검증 — 우클릭 메뉴와 1:1 인지 확인하려면 목록이 한 곳에 모여 있어야 한다.
///
/// 파괴적 동작(`제거`)은 여기서도 바로 실행하지 않고 확인 대화상자를 연다. 보조기술
/// 경로라고 확인 단계를 건너뛰면, 되돌릴 수 없는 동작이 로터에서 한 번에 발화한다.
private struct TileContextActions: ViewModifier {
    let supported: Bool
    let isWeb: Bool
    let playlistLabel: Text
    let favoriteLabel: Text
    let select: () -> Void
    let apply: () -> Void
    let applyAndOpenInteraction: () -> Void
    let togglePlaylist: () -> Void
    let toggleFavorite: () -> Void
    let reveal: () -> Void
    let confirmRemove: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if supported {
            supportedActions(sharedActions(content))
        } else {
            sharedActions(content)
        }
    }

    /// 지원 여부와 무관하게 늘 있는 것 — 우클릭 메뉴의 하단 정리 그룹과 같은 순서.
    private func sharedActions<V: View>(_ view: V) -> some View {
        view
            .accessibilityAction(named: Text("선택(속성 보기)"), select)
            .accessibilityAction(named: favoriteLabel, toggleFavorite)
            .accessibilityAction(named: Text("Finder에서 보기"), reveal)
            .accessibilityAction(named: Text("라이브러리에서 제거"), confirmRemove)
    }

    @ViewBuilder
    private func supportedActions<V: View>(_ view: V) -> some View {
        let base = view
            .accessibilityAction(named: Text("적용"), apply)
            .accessibilityAction(named: playlistLabel, togglePlaylist)
            // 중첩 메뉴 둘의 대표 액션. 목적지가 동적(폴더 목록·모니터 목록)이라 평탄화할 수
            // 없으므로 인스펙터를 열어 거기서 고르게 한다.
            .accessibilityAction(named: Text("폴더로 이동"), select)
            .accessibilityAction(named: Text("모니터에 적용"), select)
        if isWeb {
            base.accessibilityAction(named: Text("적용 + 조작 창 열기"), applyAndOpenInteraction)
        } else {
            base
        }
    }
}

/// 배경 가져오기 패널(w5d-onboarding): NSOpenPanel(폴더·zip·동영상) → LibraryViewModel.routeImport 로
/// 라우팅. WallpaperGridView(툴바)·NowPlayingBar(하단 가져오기)·AppDelegate(온보딩 "가져오기…")가
/// 공유해 패널 설정이 세 벌로 갈라지지 않게 한다.
enum ImportPanel {
    @discardableResult
    static func run(into viewModel: LibraryViewModel) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .zip, .movie]
        panel.allowsMultipleSelection = false
        // AppKit 경로는 자동 해석이 없다 — 감싸지 않으면 영어 시스템에서도 한국어로 뜬다.
        panel.message = NSLocalizedString("Wallpaper Engine 폴더·상위 폴더·.zip·동영상(mp4/mov)을 선택하세요.",
                                          comment: "가져오기 패널 안내")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        viewModel.routeImport(url)
        return true
    }
}
