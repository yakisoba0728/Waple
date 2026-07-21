import XCTest
import WapleLibrary
@testable import Waple

final class LibraryRemovalTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)   // tearDown 에서 정리($TMPDIR 리터 방지)
        return d
    }
    private func makeWallpaper(id: String) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + id, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        tempDirs.append(folder)   // tearDown 에서 정리
        let json: [String: Any] = ["type": "video", "file": "a.mp4", "title": id]
        try! JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent("project.json"))
        return folder
    }

    func testRemoveClearsAllStores() throws {
        let base = tempDir()
        let store = LibraryStore(baseDirectory: base)
        let playlist = PlaylistStore(baseDirectory: base)
        let monitors = MonitorAssignmentStore(baseDirectory: base)
        let favorites = FavoritesStore(baseDirectory: base)
        let folders = FolderStore(baseDirectory: base)
        let entry = try store.importFolder(makeWallpaper(id: "gone"))
        store.select(entry.id)
        playlist.ids = [entry.id]
        monitors.setAssignment(entry.id, for: "display-9")
        favorites.toggle(entry.id)
        folders.move(entry.id, to: "폴더A")

        let vm = LibraryViewModel(store: store, playlist: playlist, monitors: monitors,
                                  favorites: favorites, folders: folders)
        vm.focusedId = entry.id
        var assignmentsChanged = false
        vm.onAssignmentsChanged = { assignmentsChanged = true }

        vm.remove(entry)

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.selectedId)
        XCTAssertTrue(playlist.ids.isEmpty)
        XCTAssertNil(monitors.assignment(for: "display-9"))
        XCTAssertFalse(favorites.isFavorite(entry.id))
        XCTAssertNil(folders.folderName(of: entry.id))
        XCTAssertNil(vm.focusedId)
        XCTAssertTrue(vm.entries.isEmpty)
        XCTAssertTrue(assignmentsChanged, "할당이 있던 항목 제거 → 재적용 트리거")
    }

    /// F069: 재생목록에 '없던' 항목을 제거할 때는 onPlaylistChanged 를 호출해 자동전환 카운트다운을
    /// 불필요하게 리셋하면 안 된다.
    func testRemove_notInPlaylist_doesNotTriggerPlaylistChanged() throws {
        let base = tempDir()
        let store = LibraryStore(baseDirectory: base)
        let playlist = PlaylistStore(baseDirectory: base)
        let monitors = MonitorAssignmentStore(baseDirectory: base)
        let favorites = FavoritesStore(baseDirectory: base)
        let folders = FolderStore(baseDirectory: base)
        let entry = try store.importFolder(makeWallpaper(id: "not-in-playlist"))
        // playlist.ids 를 건드리지 않음 — entry 는 재생목록에 없다.

        let vm = LibraryViewModel(store: store, playlist: playlist, monitors: monitors,
                                  favorites: favorites, folders: folders)
        var playlistChanged = false
        vm.onPlaylistChanged = { playlistChanged = true }

        vm.remove(entry)

        XCTAssertFalse(playlistChanged, "재생목록에 없던 항목 제거는 onPlaylistChanged 를 태우면 안 된다(F069)")
    }

    /// F069 대조: 재생목록에 '있던' 항목 제거는 여전히 onPlaylistChanged 를 태워야 한다(무회귀).
    func testRemove_inPlaylist_stillTriggersPlaylistChanged() throws {
        let base = tempDir()
        let store = LibraryStore(baseDirectory: base)
        let playlist = PlaylistStore(baseDirectory: base)
        let monitors = MonitorAssignmentStore(baseDirectory: base)
        let favorites = FavoritesStore(baseDirectory: base)
        let folders = FolderStore(baseDirectory: base)
        let entry = try store.importFolder(makeWallpaper(id: "in-playlist"))
        playlist.ids = [entry.id]

        let vm = LibraryViewModel(store: store, playlist: playlist, monitors: monitors,
                                  favorites: favorites, folders: folders)
        var playlistChanged = false
        vm.onPlaylistChanged = { playlistChanged = true }

        vm.remove(entry)

        XCTAssertTrue(playlistChanged, "재생목록에 있던 항목 제거는 여전히 onPlaylistChanged 를 태워야 한다")
    }

    /// F070: 할당 없이 전역으로만 적용 중이던(selectedId == entry.id, 할당 없음) 배경을 제거하면
    /// AppDelegate 가 currentFolderURL 을 함께 지울 수 있도록 onGlobalSelectionRemoved 가 발화해야
    /// 한다 — 안 그러면 스테일한 currentFolderURL 이 이후 재적용에서 제거된 배경을 되살린다.
    func testRemove_globalSelectionWithoutAssignment_triggersOnGlobalSelectionRemoved() throws {
        let base = tempDir()
        let store = LibraryStore(baseDirectory: base)
        let playlist = PlaylistStore(baseDirectory: base)
        let monitors = MonitorAssignmentStore(baseDirectory: base)
        let favorites = FavoritesStore(baseDirectory: base)
        let folders = FolderStore(baseDirectory: base)
        let entry = try store.importFolder(makeWallpaper(id: "global-only"))
        store.select(entry.id)   // 전역 선택 — 할당은 없음

        let vm = LibraryViewModel(store: store, playlist: playlist, monitors: monitors,
                                  favorites: favorites, folders: folders)
        var globalSelectionRemoved = false
        vm.onGlobalSelectionRemoved = { globalSelectionRemoved = true }
        var assignmentsChanged = false
        vm.onAssignmentsChanged = { assignmentsChanged = true }

        vm.remove(entry)

        XCTAssertTrue(globalSelectionRemoved, "할당 없이 전역 적용 중이던 배경 제거는 onGlobalSelectionRemoved 를 태워야 한다(F070)")
        XCTAssertFalse(assignmentsChanged, "할당이 없었으므로 onAssignmentsChanged 는 무관")
    }

    /// F070 복합 케이스: 제거 대상이 전역 선택이면서 모니터 할당도 병존하면, 종전 가드
    /// (`selectedId == entry.id && !hadAssignment`) 때문에 onGlobalSelectionRemoved 가 발화하지
    /// 않았다 — 그러면 onAssignmentsChanged 경유 applyCurrentSelection 이 스테일 currentFolderURL
    /// 을 재적용해 제거된 배경이 부활한다(파일 보존이라 apply 성공). 전역 선택이면 할당 병존 여부와
    /// 무관하게 발화해야 하고, 재적용 트리거(onAssignmentsChanged)보다 **먼저** 발화해야 한다
    /// (순서가 뒤집히면 스테일 재적용이 먼저 일어난다).
    func testRemove_globalSelectionWithAssignment_triggersOnGlobalSelectionRemovedBeforeAssignmentsChanged() throws {
        let base = tempDir()
        let store = LibraryStore(baseDirectory: base)
        let playlist = PlaylistStore(baseDirectory: base)
        let monitors = MonitorAssignmentStore(baseDirectory: base)
        let favorites = FavoritesStore(baseDirectory: base)
        let folders = FolderStore(baseDirectory: base)
        let entry = try store.importFolder(makeWallpaper(id: "selected-and-assigned"))
        store.select(entry.id)                              // 전역 선택
        monitors.setAssignment(entry.id, for: "display-1")  // + 모니터 할당 병존(복합 케이스)

        let vm = LibraryViewModel(store: store, playlist: playlist, monitors: monitors,
                                  favorites: favorites, folders: folders)
        var order: [String] = []
        vm.onGlobalSelectionRemoved = { order.append("globalSelectionRemoved") }
        vm.onAssignmentsChanged = { order.append("assignmentsChanged") }

        vm.remove(entry)

        XCTAssertEqual(order, ["globalSelectionRemoved", "assignmentsChanged"],
                       "복합 케이스: 전역 선택 정리 통지가 재적용 트리거보다 먼저 발화해야 한다(F070)")
    }

    /// F070 대조: 할당만 있고 전역 선택은 '다른' 배경인 항목을 제거할 때 onGlobalSelectionRemoved 가
    /// 발화하면 살아있는 전역 선택의 currentFolderURL 까지 잘못 비우게 된다 — 발화 금지.
    func testRemove_assignedButNotGlobalSelection_doesNotTriggerOnGlobalSelectionRemoved() throws {
        let base = tempDir()
        let store = LibraryStore(baseDirectory: base)
        let playlist = PlaylistStore(baseDirectory: base)
        let monitors = MonitorAssignmentStore(baseDirectory: base)
        let favorites = FavoritesStore(baseDirectory: base)
        let folders = FolderStore(baseDirectory: base)
        let entry = try store.importFolder(makeWallpaper(id: "assigned-only"))
        let other = try store.importFolder(makeWallpaper(id: "still-selected"))
        store.select(other.id)   // 전역 선택은 다른 배경
        monitors.setAssignment(entry.id, for: "display-1")

        let vm = LibraryViewModel(store: store, playlist: playlist, monitors: monitors,
                                  favorites: favorites, folders: folders)
        var globalSelectionRemoved = false
        vm.onGlobalSelectionRemoved = { globalSelectionRemoved = true }
        var assignmentsChanged = false
        vm.onAssignmentsChanged = { assignmentsChanged = true }

        vm.remove(entry)

        XCTAssertFalse(globalSelectionRemoved, "전역 선택이 아닌 항목 제거로 전역 선택을 비우면 안 된다")
        XCTAssertTrue(assignmentsChanged, "할당이 있던 항목 제거 → 재적용 트리거는 유지")
    }
}
