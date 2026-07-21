import XCTest
@testable import WapleLibrary

final class LibraryMetadataTests: XCTestCase {
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
    /// project.json 을 가진 배경 폴더 생성.
    private func makeWallpaper(in dir: URL, id: String, tags: [String], rating: String?) -> URL {
        let folder = dir.appendingPathComponent(id, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var json: [String: Any] = ["type": "video", "file": "a.mp4", "title": id, "tags": tags]
        if let rating { json["contentrating"] = rating }
        let data = try! JSONSerialization.data(withJSONObject: json)
        try! data.write(to: folder.appendingPathComponent("project.json"))
        return folder
    }

    func testImportFillsTagsAndContentRating() throws {
        let base = tempDir()
        let store = LibraryStore(baseDirectory: base)
        let folder = makeWallpaper(in: tempDir(), id: "w1", tags: ["Anime", "4K"], rating: "Everyone")
        let entry = try store.importFolder(folder)
        XCTAssertEqual(entry.tags, ["Anime", "4K"])
        XCTAssertEqual(entry.contentRating, "Everyone")
    }

    func testDecodeOldIndexWithoutNewFields() throws {
        // 구버전 index(신규 필드 부재)가 그대로 디코드되는지 — 마이그레이션 안전성.
        let old = """
        {"entries":[{"id":"x","title":"t","typeRaw":"video","bookmark":""}],"selectedId":null}
        """
        let base = tempDir()
        try old.data(using: .utf8)!.write(to: base.appendingPathComponent("library.json"))
        let store = LibraryStore(baseDirectory: base)
        XCTAssertEqual(store.entries.first?.id, "x")
        XCTAssertNil(store.entries.first?.rating)
    }

    func testBackfillFillsNilTagsFromDisk() throws {
        let base = tempDir()
        let folder = makeWallpaper(in: tempDir(), id: "w2", tags: ["Nature"], rating: nil)
        // 1차 스토어로 정상 임포트 후, 인덱스에서 tags 를 지워 구버전 상태를 재현.
        var store: LibraryStore? = LibraryStore(baseDirectory: base)
        _ = try store!.importFolder(folder)
        store = nil
        let url = base.appendingPathComponent("library.json")
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var entries = raw["entries"] as! [[String: Any]]
        entries[0].removeValue(forKey: "tags")
        entries[0].removeValue(forKey: "contentRating")
        raw["entries"] = entries
        try JSONSerialization.data(withJSONObject: raw).write(to: url)
        // 재로드 → init 백필이 디스크 project.json 에서 채워야 한다.
        let reloaded = LibraryStore(baseDirectory: base)
        XCTAssertEqual(reloaded.entries.first?.tags, ["Nature"])
    }

    func testSetRatingPersists() throws {
        let base = tempDir()
        let folder = makeWallpaper(in: tempDir(), id: "w3", tags: [], rating: nil)
        let store = LibraryStore(baseDirectory: base)
        let entry = try store.importFolder(folder)
        store.setRating(0.87, id: entry.id)
        let reloaded = LibraryStore(baseDirectory: base)
        XCTAssertEqual(reloaded.entries.first?.rating, 0.87)
    }
}
