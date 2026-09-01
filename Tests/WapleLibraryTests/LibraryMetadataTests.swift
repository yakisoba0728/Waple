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

    // MARK: - r3-M64: 백필의 실패 두 종류

    /// **회귀 핀(r3-M64).** 북마크 해석 실패는 **일시적**일 수 있다(외장/네트워크 볼륨 미마운트).
    /// 재시도 조건이 `tags == nil` 이라 `[]` 로 마킹하면 다시는 안 본다 — 볼륨을 안 꽂은 채
    /// 한 번 기동한 것만으로 태그가 영구 소실됐다. `nil` 로 남겨야 다음 실행이 재시도한다.
    func testBackfillLeavesTagsNilWhenTheBookmarkCannotResolve() throws {
        let base = tempDir()
        // 빈 북마크 → URL(resolvingBookmarkData:) 가 던진다 = 해석 실패(구버전 인덱스: tags 부재).
        let old = """
        {"entries":[{"id":"x","title":"t","typeRaw":"video","bookmark":""}],"selectedId":null}
        """
        try old.data(using: .utf8)!.write(to: base.appendingPathComponent("library.json"))

        let store = LibraryStore(baseDirectory: base)
        XCTAssertNil(store.entries.first?.tags, "해석 실패를 [] 로 못 박으면 안 된다")
        // 인덱스에도 []가 기록되지 않아야 **다음 실행**이 재시도한다.
        let reloaded = LibraryStore(baseDirectory: base)
        XCTAssertNil(reloaded.entries.first?.tags, "디스크에도 [] 가 남으면 재시도가 영영 막힌다")
    }

    /// 반대편: 폴더는 열렸는데 `project.json` 이 없거나 깨진 경우는 **안정적** 결과라
    /// 종전대로 `[]` 로 못 박아 매 실행 파스 I/O 를 막는다.
    func testBackfillMarksEmptyWhenTheFolderResolvesButProjectJSONIsGone() throws {
        let base = tempDir()
        let folder = makeWallpaper(in: tempDir(), id: "w4", tags: ["Nature"], rating: nil)
        var store: LibraryStore? = LibraryStore(baseDirectory: base)
        _ = try store!.importFolder(folder)
        store = nil

        // 폴더는 그대로 두고(북마크는 해석된다) project.json 만 지운다 + 인덱스를 구버전화.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("project.json"))
        let url = base.appendingPathComponent("library.json")
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var entries = raw["entries"] as! [[String: Any]]
        entries[0].removeValue(forKey: "tags")
        entries[0].removeValue(forKey: "contentRating")
        raw["entries"] = entries
        try JSONSerialization.data(withJSONObject: raw).write(to: url)

        let reloaded = LibraryStore(baseDirectory: base)
        XCTAssertEqual(reloaded.entries.first?.tags, [], "해석은 됐는데 메타데이터가 없으면 [] 로 확정")
    }
}
