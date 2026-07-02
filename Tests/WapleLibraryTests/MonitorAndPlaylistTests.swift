import XCTest
@testable import WapleLibrary

final class MonitorAssignmentStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testAssignPersistAndReload() {
        let dir = tempDir()
        let s = MonitorAssignmentStore(baseDirectory: dir)
        XCTAssertNil(s.assignment(for: "display-1"))
        s.setAssignment("wallpaper-A", for: "display-1")
        s.setAssignment("wallpaper-B", for: "display-2")
        XCTAssertEqual(s.assignment(for: "display-1"), "wallpaper-A")
        // 재로드(영속성)
        let s2 = MonitorAssignmentStore(baseDirectory: dir)
        XCTAssertEqual(s2.assignment(for: "display-1"), "wallpaper-A")
        XCTAssertEqual(s2.assignment(for: "display-2"), "wallpaper-B")
        // 해제
        s2.setAssignment(nil, for: "display-1")
        XCTAssertNil(MonitorAssignmentStore(baseDirectory: dir).assignment(for: "display-1"))
    }

    func testCorruptFileFallsBackEmpty() throws {
        let dir = tempDir()
        try Data("not json".utf8).write(to: dir.appendingPathComponent("monitors.json"))
        let s = MonitorAssignmentStore(baseDirectory: dir)
        XCTAssertNil(s.assignment(for: "x"))
        s.setAssignment("a", for: "x")  // 저장 가능해야
        XCTAssertEqual(MonitorAssignmentStore(baseDirectory: dir).assignment(for: "x"), "a")
    }
}

final class PlaylistStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testDefaultsAndPersistence() {
        let dir = tempDir()
        let p = PlaylistStore(baseDirectory: dir)
        XCTAssertFalse(p.enabled)
        XCTAssertEqual(p.intervalMinutes, 30, "기본 30분")
        XCTAssertEqual(p.ids, [])
        p.enabled = true
        p.intervalMinutes = 5
        p.ids = ["a", "b", "c"]
        let p2 = PlaylistStore(baseDirectory: dir)
        XCTAssertTrue(p2.enabled)
        XCTAssertEqual(p2.intervalMinutes, 5)
        XCTAssertEqual(p2.ids, ["a", "b", "c"])
    }

    func testNextRotatesAndWraps() {
        let p = PlaylistStore(baseDirectory: tempDir())
        p.ids = ["a", "b", "c"]
        XCTAssertEqual(p.next(after: "a"), "b")
        XCTAssertEqual(p.next(after: "c"), "a", "래핑")
        XCTAssertEqual(p.next(after: "zz"), "a", "목록 밖 → 처음부터")
        XCTAssertEqual(p.next(after: nil), "a")
    }

    func testNextEmptyListIsNil() {
        let p = PlaylistStore(baseDirectory: tempDir())
        XCTAssertNil(p.next(after: nil))
    }

    func testToggleMembership() {
        let p = PlaylistStore(baseDirectory: tempDir())
        p.toggle("a"); p.toggle("b")
        XCTAssertEqual(p.ids, ["a", "b"])
        p.toggle("a")
        XCTAssertEqual(p.ids, ["b"], "재토글 = 제거")
    }
}
