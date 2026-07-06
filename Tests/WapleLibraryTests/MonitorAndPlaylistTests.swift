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

    func testCorruptFileBackedUpNotClobbered() throws {
        // 종전: 손상 monitors.json 을 try? 로 무시하고 첫 저장이 기본값으로 덮어써 사용자 할당 영구 손실.
        let dir = tempDir()
        let url = dir.appendingPathComponent("monitors.json")
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: url)
        MonitorAssignmentStore(baseDirectory: dir).setAssignment("a", for: "x")  // 저장 트리거
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("monitors.json.corrupt") }
        XCTAssertEqual(backups.count, 1, "손상 원본이 백업 없이 파괴됨(회귀)")
        XCTAssertEqual(try Data(contentsOf: backups[0]), garbage, "손상 원본 바이트 보존")
        XCTAssertEqual(MonitorAssignmentStore(baseDirectory: dir).assignment(for: "x"), "a", "새 데이터는 정상 저장")
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

    func testCorruptFileBackedUpNotClobbered() throws {
        // 종전: 손상 playlist.json 을 try? 로 무시하고 첫 저장이 기본값으로 덮어써 재생목록 구성 영구 손실.
        let dir = tempDir()
        let url = dir.appendingPathComponent("playlist.json")
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: url)
        let p = PlaylistStore(baseDirectory: dir)
        p.enabled = true  // 저장 트리거
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("playlist.json.corrupt") }
        XCTAssertEqual(backups.count, 1, "손상 원본이 백업 없이 파괴됨(회귀)")
        XCTAssertEqual(try Data(contentsOf: backups[0]), garbage, "손상 원본 바이트 보존")
        XCTAssertTrue(PlaylistStore(baseDirectory: dir).enabled, "새 데이터는 정상 저장")
    }
}
