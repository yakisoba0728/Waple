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

    /// P4: move 는 createFolder 와 달리 대상 이름을 트림하지 않아, 끝공백만 다른 이름이
    /// 별개 폴더로 취급돼 중복 생성됐다. "Foo " 로 move 해도 기존 "Foo" 로 합쳐져야 한다.
    func testMoveTrimsTargetNameNoDuplicateFolder() {
        let base = tempDir()
        let s = FolderStore(baseDirectory: base)
        s.createFolder("Foo")
        s.move("w1", to: "Foo ")  // 끝공백
        XCTAssertEqual(s.folders.count, 1, "끝공백 트림 실패로 중복 폴더 생성됨(회귀)")
        XCTAssertEqual(s.folderName(of: "w1"), "Foo")
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
