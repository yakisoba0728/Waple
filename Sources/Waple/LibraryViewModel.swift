import Foundation
import Combine
import WapleCore
import WapleLibrary
import WapleRender

final class LibraryViewModel: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published var selectedId: String?
    /// 속성 편집 시트 대상(nil = 닫힘).
    @Published var propertyEditorEntry: LibraryEntry?

    /// 적용 요청을 AppDelegate 로 전달한다(폴더 URL). 마운트 성공 여부를 반환한다.
    var onApply: ((URL) -> Bool)?

    /// 사용자에게 보여줄 오류 메시지를 AppDelegate 로 전달한다.
    var onError: ((String) -> Void)?

    private let store: LibraryStore
    let playlist: PlaylistStore
    let monitors: MonitorAssignmentStore

    /// 화면 목록 제공(키+표시명) — AppDelegate 주입.
    var screensProvider: (() -> [(key: String, name: String)])?
    /// 모니터 할당 변경 → 즉시 재적용 트리거.
    var onAssignmentsChanged: (() -> Void)?
    /// 재생목록 변경 → 타이머 재구성 트리거.
    var onPlaylistChanged: (() -> Void)?
    /// 웹 조작 창 열기(적용된 웹 월페이퍼의 입력 프록시) — AppDelegate 주입.
    var onOpenInteraction: (() -> Void)?

    init(store: LibraryStore, playlist: PlaylistStore, monitors: MonitorAssignmentStore) {
        self.store = store
        self.playlist = playlist
        self.monitors = monitors
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
