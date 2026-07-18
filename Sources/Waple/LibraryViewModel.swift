import Foundation
import Combine
import WapleCore
import WapleLibrary
import WapleRender

final class LibraryViewModel: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published var selectedId: String?
    // MARK: - 브라우즈 상태(메인창 UI) — selectedId(=적용됨)와 구분되는 패널 포커스.
    @Published var focusedId: String?
    /// 우측 정보 패널 노출 여부(툴바 토글이 소유하던 로컬 @State 를 승격 — selectForPropertiesView 가
    /// focusedId 와 함께 갱신할 수 있어야 하기 때문. 기본 true(기존 동작 무회귀).
    @Published var panelVisible = true
    @Published var searchText = ""
    @Published var criteria = LibraryFilterCriteria()
    @Published var activeFolder: String?
    @Published var sortOrder: LibrarySortOrder = .recentFirst

    var filteredEntries: [LibraryEntry] {
        // 필터/검색 활성 시 폴더 스코프를 벗어나 전체에서 찾는다(사이드바 폴더 타일도 이때 숨김).
        let scopeAll = activeFolder == nil && (!searchText.isEmpty || criteria.isActive)
        let scoped = scopeAll ? entries
            : LibraryFolders.visible(entries: entries, folders: folders.folders, active: activeFolder).entries
        return LibraryFiltering.apply(scoped, search: searchText, criteria: criteria,
                                      sort: sortOrder, isFavorite: { self.favorites.isFavorite($0) })
    }
    /// 루트에서만 노출되는 폴더 타일 목록(검색/필터 중엔 숨김 — 결과에 집중).
    var visibleFolders: [FolderStore.Folder] {
        guard activeFolder == nil, searchText.isEmpty, !criteria.isActive else { return [] }
        return folders.folders
    }
    var availableTags: [String] {
        Array(Set(entries.flatMap { $0.tags ?? [] })).sorted()
    }
    var availableRatings: [String] {
        Array(Set(entries.compactMap(\.contentRating))).sorted()
    }
    var focusedEntry: LibraryEntry? { entries.first { $0.id == focusedId } }
    /// 하단 바 "현재:" 표시용 — 적용된(selectedId) 배경 제목.
    var appliedTitle: String? { entries.first { $0.id == selectedId }?.title }

    /// 적용 요청을 AppDelegate 로 전달한다(폴더 URL). 마운트 성공 여부를 반환한다.
    var onApply: ((URL) -> Bool)?

    /// 사용자에게 보여줄 오류 메시지를 AppDelegate 로 전달한다.
    var onError: ((String) -> Void)?

    private let store: LibraryStore
    let playlist: PlaylistStore
    let monitors: MonitorAssignmentStore
    let favorites: FavoritesStore
    let folders: FolderStore

    /// 화면 목록 제공(키+표시명) — AppDelegate 주입.
    var screensProvider: (() -> [(key: String, name: String)])?
    /// 모니터 할당 변경 → 즉시 재적용 트리거.
    var onAssignmentsChanged: (() -> Void)?
    /// 재생목록 변경 → 타이머 재구성 트리거.
    var onPlaylistChanged: (() -> Void)?
    /// 웹 조작 창 열기(적용된 웹 월페이퍼의 입력 프록시) — AppDelegate 주입.
    var onOpenInteraction: (() -> Void)?
    /// 툴바 설정 버튼 → AppDelegate.openSettings (SP5′).
    var onOpenSettings: (() -> Void)?
    /// 하단 바: 재생목록 다음으로 — AppDelegate 주입.
    var onAdvancePlaylist: (() -> Void)?
    /// 하단 바: 전역 일시정지 토글(새 상태 반환) — AppDelegate 주입.
    var onTogglePause: (() -> Bool)?
    @Published var isPaused = false

    init(store: LibraryStore, playlist: PlaylistStore, monitors: MonitorAssignmentStore,
         favorites: FavoritesStore, folders: FolderStore) {
        self.store = store
        self.playlist = playlist
        self.monitors = monitors
        self.favorites = favorites
        self.folders = folders
        self.entries = store.entries
        self.selectedId = store.selectedId
    }

    // MARK: - 재생목록/모니터별

    func isInPlaylist(_ entry: LibraryEntry) -> Bool { playlist.ids.contains(entry.id) }

    func togglePlaylist(_ entry: LibraryEntry) {
        playlist.toggle(entry.id)
        objectWillChange.send()
        onPlaylistChanged?()
    }

    var screens: [(key: String, name: String)] { screensProvider?() ?? [] }

    func assign(_ entry: LibraryEntry, toScreen key: String) {
        monitors.setAssignment(entry.id, for: key)
        objectWillChange.send()
        onAssignmentsChanged?()
    }

    func clearAssignment(forScreen key: String) {
        monitors.setAssignment(nil, for: key)
        objectWillChange.send()
        onAssignmentsChanged?()
    }

    func assignedEntryTitle(forScreen key: String) -> String? {
        guard let id = monitors.assignment(for: key) else { return nil }
        return entries.first(where: { $0.id == id })?.title
    }

    /// 화면에 할당된 라이브러리 엔트리(썸네일 로딩용). 미할당/유실 id → nil(전역 배경).
    func assignedEntry(forScreen key: String) -> LibraryEntry? {
        guard let id = monitors.assignment(for: key) else { return nil }
        return entries.first { $0.id == id }
    }

    // MARK: - 즐겨찾기/제거

    func isFavorite(_ entry: LibraryEntry) -> Bool { favorites.isFavorite(entry.id) }

    func toggleFavorite(_ entry: LibraryEntry) {
        favorites.toggle(entry.id)
        objectWillChange.send()
    }

    func moveToFolder(_ entry: LibraryEntry, folder: String?) {
        folders.move(entry.id, to: folder)
        objectWillChange.send()
    }

    /// 그리드 우클릭 "선택(속성 보기)" 진입점(w5d-settings-ia) — 포커스와 함께 정보 패널을 노출한다.
    /// 패널이 접힌 상태에서 focusedId 만 바꾸면 라벨이 약속한 속성이 어디에도 나타나지 않는 데드엔드가
    /// 된다 — 포커스 설정과 패널 노출을 하나로 묶어 항상 결과가 보이게 한다.
    func selectForPropertiesView(_ entry: LibraryEntry) {
        focusedId = entry.id
        panelVisible = true
    }

    /// 적용 중인(모니터 할당 없이 전역으로만 적용된) 배경이 라이브러리에서 제거되면, AppDelegate 의
    /// 전역 선택(currentFolderURL/currentProjectId) 도 함께 지우도록 알린다(F070) — 안 하면 스테일한
    /// currentFolderURL 이 남아, 이후 화면 변경·할당 변경 재적용(applyCurrentSelection)이 라이브러리
    /// 에서 이미 사라진 배경을 전역으로 되살린다(제거는 파일을 보존하므로 폴더 자체는 여전히 유효해
    /// apply 가 조용히 성공해버린다).
    var onGlobalSelectionRemoved: (() -> Void)?

    /// 라이브러리에서 제거(파일 보존) + 전 스토어 orphan 정리. 적용 중 배경은 계속 재생된다
    /// (렌더러는 폴더를 직접 들고 있음) — Now Playing 표시는 '적용된 배경 없음'으로 떨어진다.
    func remove(_ entry: LibraryEntry) {
        let hadAssignment = monitors.all.values.contains(entry.id)
        let wasGlobalSelection = selectedId == entry.id && !hadAssignment   // F070
        // F069: 재생목록에 없던 항목을 제거할 때도 무조건 onPlaylistChanged 를 호출하면 자동전환
        // 카운트다운이 불필요하게 리셋된다 — 제거 전에 실제 포함 여부를 확인해 두었다가 가드한다.
        let wasInPlaylist = playlist.ids.contains(entry.id)
        store.remove(id: entry.id)
        playlist.remove(entry.id)
        monitors.removeAssignments(entryId: entry.id)
        favorites.remove(entry.id)
        folders.removeEntry(entry.id)
        entries = store.entries
        if selectedId == entry.id { selectedId = nil }
        if focusedId == entry.id { focusedId = nil }
        if wasInPlaylist { onPlaylistChanged?() }
        if hadAssignment { onAssignmentsChanged?() }
        if wasGlobalSelection { onGlobalSelectionRemoved?() }
    }

    func importParent(_ url: URL) {
        let imported = store.importParent(url)
        entries = store.entries
        if imported.isEmpty {
            onError?("가져온 배경이 없습니다. 선택한 폴더에 유효한 project.json 이 있는지 확인하세요.")
        }
    }

    /// zip 가져오기(작업 4) — 해제 후 담긴 배경들을 관리 위치로 옮겨 가져온다.
    func importZip(_ url: URL) {
        let imported = store.importZip(url)
        entries = store.entries
        if imported.isEmpty {
            onError?("zip 에서 가져온 배경이 없습니다. project.json 이 포함돼 있는지 확인하세요.")
        }
    }

    /// 원시 mp4/mov 가져오기(작업 5) — 최소 project.json 배경으로 감싸 가져온다.
    func importVideoFile(_ url: URL) {
        guard let folder = VideoImport.prepare(from: url),
              (try? store.importFolder(folder)) != nil else {
            onError?("동영상 가져오기에 실패했습니다: \(url.lastPathComponent)")
            return
        }
        entries = store.entries
    }

    /// 워크샵 다운로드 직후 평점 반영(0…1). 표시용 메타 — 실패 무해.
    func setRating(_ score: Double, for entry: LibraryEntry) {
        store.setRating(score, id: entry.id)
        entries = store.entries
    }

    /// 워크샵 다운로드로 받은 배경 폴더 1개를 라이브러리에 가져온다(기존 importFolder 재사용). 실패 → nil.
    @discardableResult
    func importDownloaded(_ folderURL: URL) -> LibraryEntry? {
        guard let entry = try? store.importFolder(folderURL) else {
            onError?("다운로드한 폴더를 가져오지 못했습니다: \(folderURL.lastPathComponent)")
            return nil
        }
        entries = store.entries
        return entry
    }

    /// 마운트 성공 시 true. 재생목록 전진(advancePlaylist)이 실패 후보를 건너뛰는 데 이 반환을 쓴다.
    @discardableResult
    func apply(_ entry: LibraryEntry) -> Bool {
        guard let folder = store.resolveFolderURL(for: entry) else {
            onError?("‘\(entry.title)’의 폴더를 찾을 수 없습니다. 다시 가져오세요.")
            return false
        }
        // 적용(마운트) 성공이 확인된 뒤에만 선택을 영속·강조한다. 실패 시 기존 선택을 유지해
        // 강조/저장된 선택이 항상 실제로 표시되는 배경과 일치하도록 한다.
        guard onApply?(folder) == true else {
            onError?("‘\(entry.title)’을(를) 적용하지 못했습니다.")
            return false
        }
        store.select(entry.id)
        selectedId = entry.id
        return true
    }

    /// Finder에서 보기 등 파일시스템 접근용 폴더 URL(w5d-library). 해석 실패(북마크 stale·손상 등) → nil.
    func folderURL(for entry: LibraryEntry) -> URL? {
        store.resolveFolderURL(for: entry)
    }

    func previewURL(for entry: LibraryEntry) -> URL? {
        guard let folder = store.resolveFolderURL(for: entry),
              let preview = WallpaperPathSecurity.containedFileURL(entry.previewName, root: folder) else { return nil }
        return preview
    }

    func isSupported(_ entry: LibraryEntry) -> Bool {
        WallpaperType.from(entry.typeRaw).isSupportedInMVP
    }

    // MARK: - 유저 속성 편집

    /// 편집 가능한 속성 목록(기본값 + 저장된 오버라이드 병합).
    func editableProperties(for entry: LibraryEntry) -> [WallpaperProperty] {
        guard let folder = store.resolveFolderURL(for: entry) else { return [] }
        let parsed = try? ProjectJSONParser.parse(folderURL: folder)
        let resolved = parsed.flatMap { project in
            PresetResolver.resolve(
                project: project,
                originalFolder: folder,
                dependencyFolder: { dependency in
                    guard let dependencyEntry = store.entries.first(where: { $0.id == dependency }) else { return nil }
                    return store.resolveFolderURL(for: dependencyEntry)
                },
                parse: { try? ProjectJSONParser.parse(folderURL: $0) }
            )
        }
        let propertyRoot = resolved?.folderURL ?? folder
        guard let props = try? WallpaperProperties.parse(folderURL: propertyRoot) else { return [] }
        let overrides = UserPropertyStore.overrides(
            id: entry.id,
            presetOverrides: resolved?.presetOverrides ?? [:],
            presetResourceRoot: resolved?.presetFolderURL
        )
        return WallpaperProperties.applying(overrides: overrides, to: props)
    }

    func setProperty(key: String, value: PropertyValue, for entry: LibraryEntry) {
        UserPropertyStore.set(value, key: key, id: entry.id)
        reapplyIfCurrent(entry)
    }

    func resetProperties(for entry: LibraryEntry) {
        UserPropertyStore.reset(id: entry.id)
        reapplyIfCurrent(entry)
    }

    /// 현재 적용 중인 배경이면 즉시 재적용(변경 반영 — fit-mode 패턴).
    private func reapplyIfCurrent(_ entry: LibraryEntry) {
        if selectedId == entry.id {
            guard let folder = store.resolveFolderURL(for: entry) else { return }
            _ = onApply?(folder)
            return
        }
        if monitors.all.values.contains(entry.id) {
            onAssignmentsChanged?()
        }
    }
}
