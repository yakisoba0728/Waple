import XCTest
@testable import WapleLibrary

final class LibraryStoreTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WapleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// 임시 배경 폴더(project.json + 더미 자산) 생성.
    private func makeWallpaperFolder(id: String, type: String = "video") throws -> URL {
        let folder = tmp.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"{"type":"\#(type)","file":"wallpaper.mp4","preview":"preview.jpg","title":"\#(id)"}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
        try Data("dummy".utf8).write(to: folder.appendingPathComponent("wallpaper.mp4"))
        return folder
    }

    private func base() -> URL { tmp.appendingPathComponent("store", isDirectory: true) }

    func testImportFolderAddsEntry() throws {
        let folder = try makeWallpaperFolder(id: "111")
        let store = LibraryStore(baseDirectory: base())
        let entry = try store.importFolder(folder)
        XCTAssertEqual(entry.id, "111")
        XCTAssertEqual(entry.typeRaw, "video")
        XCTAssertEqual(store.entries.count, 1)
    }

    func testImportFolderIsIdempotentById() throws {
        let folder = try makeWallpaperFolder(id: "111")
        let store = LibraryStore(baseDirectory: base())
        try store.importFolder(folder)
        try store.importFolder(folder)
        XCTAssertEqual(store.entries.count, 1)
    }

    func testImportParentSkipsInvalidSubfolders() throws {
        _ = try makeWallpaperFolder(id: "111")
        _ = try makeWallpaperFolder(id: "222")
        // project.json 없는 폴더 → 스킵 대상
        let bad = tmp.appendingPathComponent("333", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)

        let store = LibraryStore(baseDirectory: base())
        let imported = store.importParent(tmp)
        // tmp 안에는 store 디렉터리도 있으나 project.json 없으므로 스킵됨
        XCTAssertEqual(Set(imported.map(\.id)), ["111", "222"])
    }

    func testEntriesPersistAcrossInstances() throws {
        let folder = try makeWallpaperFolder(id: "111")
        let store1 = LibraryStore(baseDirectory: base())
        try store1.importFolder(folder)
        store1.select("111")

        let store2 = LibraryStore(baseDirectory: base())
        XCTAssertEqual(store2.entries.map(\.id), ["111"])
        XCTAssertEqual(store2.selectedId, "111")
    }

    func testResolveFolderURLReturnsOriginalLocation() throws {
        let folder = try makeWallpaperFolder(id: "111")
        let store = LibraryStore(baseDirectory: base())
        let entry = try store.importFolder(folder)
        let resolved = store.resolveFolderURL(for: entry)
        XCTAssertEqual(resolved?.standardizedFileURL, folder.standardizedFileURL)
    }
}
