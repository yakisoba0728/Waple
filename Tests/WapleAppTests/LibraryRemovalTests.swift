import XCTest
import WapleLibrary
@testable import Waple

final class LibraryRemovalTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func makeWallpaper(id: String) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + id, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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

    /// F070 대조: 할당이 있던 항목(전역 선택 여부 무관)은 onAssignmentsChanged 경로로 이미 재적용이
    /// 트리거되므로 onGlobalSelectionRemoved 는 발화하면 안 된다(중복 정리 방지).
    func testRemove_withAssignment_doesNotTriggerOnGlobalSelectionRemoved() throws {
        let base = tempDir()
        let store = LibraryStore(baseDirectory: base)
        let playlist = PlaylistStore(baseDirectory: base)
        let monitors = MonitorAssignmentStore(baseDirectory: base)
        let favorites = FavoritesStore(baseDirectory: base)
        let folders = FolderStore(baseDirectory: base)
        let entry = try store.importFolder(makeWallpaper(id: "assigned"))
        store.select(entry.id)
        monitors.setAssignment(entry.id, for: "display-1")

        let vm = LibraryViewModel(store: store, playlist: playlist, monitors: monitors,
                                  favorites: favorites, folders: folders)
        var globalSelectionRemoved = false
        vm.onGlobalSelectionRemoved = { globalSelectionRemoved = true }

        vm.remove(entry)

        XCTAssertFalse(globalSelectionRemoved, "할당이 있으면 onAssignmentsChanged 경로로 충분 — 중복 발화 금지")
    }
}
