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
}
