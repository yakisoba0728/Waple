import XCTest
@testable import WapleLibrary

final class FavoritesFolderStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testFavoritesToggleAndPersist() {
        let base = tempDir()
        let s = FavoritesStore(baseDirectory: base)
        XCTAssertFalse(s.isFavorite("a"))
        s.toggle("a")
        XCTAssertTrue(s.isFavorite("a"))
        XCTAssertTrue(FavoritesStore(baseDirectory: base).isFavorite("a"))  // 영속
        s.toggle("a")
        XCTAssertFalse(s.isFavorite("a"))
    }

    func testFolderMoveAndRemove() {
        let base = tempDir()
        let s = FolderStore(baseDirectory: base)
        s.createFolder("메인")
        s.move("w1", to: "메인")
        XCTAssertEqual(s.folderName(of: "w1"), "메인")
        s.move("w1", to: "메인")                       // 중복 이동 멱등
        XCTAssertEqual(s.folders.first?.ids, ["w1"])
        s.move("w1", to: nil)                          // 루트로
        XCTAssertNil(s.folderName(of: "w1"))
        s.move("w2", to: "새폴더")                      // 미존재 폴더 → 자동 생성
        XCTAssertEqual(FolderStore(baseDirectory: base).folderName(of: "w2"), "새폴더")
        s.removeFolder("새폴더")
        XCTAssertNil(s.folderName(of: "w2"))
    }

    func testOrphanAPIs() {
        let base = tempDir()
        let pl = PlaylistStore(baseDirectory: base)
        pl.ids = ["a", "b", "a"]
        pl.remove("a")
        XCTAssertEqual(pl.ids, ["b"])
        let mon = MonitorAssignmentStore(baseDirectory: base)
        mon.setAssignment("a", for: "display-1")
        mon.setAssignment("c", for: "display-2")
        mon.removeAssignments(entryId: "a")
        XCTAssertNil(mon.assignment(for: "display-1"))
        XCTAssertEqual(mon.assignment(for: "display-2"), "c")
    }
}
