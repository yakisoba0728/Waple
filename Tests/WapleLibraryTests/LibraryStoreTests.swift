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

    /// 상위 폴더가 아니라 개별 배경 폴더(project.json 포함)를 직접 고른 경우에도 가져와야 한다.
    func testImportParentOnSingleWallpaperFolderImportsIt() throws {
        let folder = try makeWallpaperFolder(id: "111")
        let store = LibraryStore(baseDirectory: base())
        let imported = store.importParent(folder)
        XCTAssertEqual(imported.map(\.id), ["111"])
        XCTAssertEqual(store.entries.map(\.id), ["111"])
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

    /// 손상된 library.json 은 빈 라이브러리로 취급되지만, 다음 save() 가 덮어쓰기 전에
    /// 원본을 .corrupt-* 로 백업해 데이터 손실을 막아야 한다.
    func testCorruptIndexIsBackedUpNotClobbered() throws {
        let storeDir = base()
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let indexURL = storeDir.appendingPathComponent("library.json")
        let garbage = Data("{ this is not valid json".utf8)
        try garbage.write(to: indexURL)

        let store = LibraryStore(baseDirectory: storeDir)
        XCTAssertTrue(store.entries.isEmpty)
        // 다음 save() 트리거(select).
        store.select("ghost")

        // 원본 손상 파일은 백업으로 보존돼야 한다.
        let backups = try FileManager.default.contentsOfDirectory(at: storeDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("library.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), garbage)
        // 새 인덱스가 기록됐어야 한다(빈 entries + ghost selection).
        let store2 = LibraryStore(baseDirectory: storeDir)
        XCTAssertEqual(store2.selectedId, "ghost")
        XCTAssertTrue(store2.entries.isEmpty)
    }

    /// 존재하지 않는 id 를 select 해도 그대로 영속되며, 다음 인스턴스에서 해당 엔트리는 없다.
    func testSelectUnknownIdPersistsButResolvesToNoEntry() throws {
        let store = LibraryStore(baseDirectory: base())
        store.select("ghost")
        XCTAssertEqual(store.selectedId, "ghost")
        let store2 = LibraryStore(baseDirectory: base())
        XCTAssertEqual(store2.selectedId, "ghost")
        XCTAssertNil(store2.entries.first(where: { $0.id == "ghost" }))
    }

    /// 기존 id 를 재가져오면 갱신된 필드를 반영하며 목록 맨 끝으로 이동한다.
    func testReimportUpdatesEntryAndMovesToEnd() throws {
        let a = try makeWallpaperFolder(id: "A")
        let b = try makeWallpaperFolder(id: "B")
        let store = LibraryStore(baseDirectory: base())
        try store.importFolder(a)
        try store.importFolder(b)
        XCTAssertEqual(store.entries.map(\.id), ["A", "B"])
        // A 의 title 을 바꿔 재가져오기.
        let json = #"{"type":"video","file":"wallpaper.mp4","preview":"preview.jpg","title":"A-new"}"#
        try Data(json.utf8).write(to: a.appendingPathComponent("project.json"))
        try store.importFolder(a)
        XCTAssertEqual(store.entries.map(\.id), ["B", "A"])
        XCTAssertEqual(store.entries.last?.title, "A-new")
    }

    /// F194: 서로 다른 실제 폴더 두 개가 (workshopid 가 없어) 같은 project id 로 귀결되는 경우,
    /// 두 번째 가져오기가 첫 번째를 무통지로 대체(엔트리 실종 + 북마크 앨리어싱)하면 안 되고,
    /// 접미로 유일화해 둘 다 라이브러리에 보존해야 한다.
    func testImportFolderCollisionWithDifferentRealPathUniquifiesInsteadOfReplacing() throws {
        let parentA = tmp.appendingPathComponent("A", isDirectory: true)
        let parentB = tmp.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: parentA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parentB, withIntermediateDirectories: true)
        let folderA = parentA.appendingPathComponent("Wallpaper", isDirectory: true)
        let folderB = parentB.appendingPathComponent("Wallpaper", isDirectory: true)
        for (folder, tag) in [(folderA, "A"), (folderB, "B")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let json = #"{"type":"video","file":"wallpaper.mp4","preview":"preview.jpg","title":"\#(tag)"}"#
            try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
            try Data("dummy-\(tag)".utf8).write(to: folder.appendingPathComponent("wallpaper.mp4"))
        }

        let store = LibraryStore(baseDirectory: base())
        let entryA = try store.importFolder(folderA)
        let entryB = try store.importFolder(folderB)

        XCTAssertEqual(entryA.id, "Wallpaper")
        XCTAssertNotEqual(entryB.id, entryA.id, "다른 실경로면 무통지 대체 대신 유일화해야 한다")
        XCTAssertEqual(Set(store.entries.map(\.id)), [entryA.id, entryB.id])
        // 둘 다 각자의 원래 실경로를 정확히 가리켜야 한다(북마크 앨리어싱 없음).
        XCTAssertEqual(store.resolveFolderURL(for: entryA)?.standardizedFileURL, folderA.standardizedFileURL)
        XCTAssertEqual(store.resolveFolderURL(for: entryB)?.standardizedFileURL, folderB.standardizedFileURL)
    }

    // MARK: - 작업 4: zip 가져오기

    func testFindProjectRootsRecursesAndStopsAtRoot() throws {
        let tree = tmp.appendingPathComponent("tree", isDirectory: true)
        let wrapped = tree.appendingPathComponent("wrap/111", isDirectory: true)   // 중첩된 배경
        let top = tree.appendingPathComponent("222", isDirectory: true)
        let nested = wrapped.appendingPathComponent("assets", isDirectory: true)   // 배경 내부 하위(무시 대상)
        for d in [wrapped, top, nested] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: d.appendingPathComponent("project.json"))
        }
        let roots = ZipImporter.findProjectRoots(in: tree)
        XCTAssertEqual(Set(roots.map(\.lastPathComponent)), ["111", "222"],
                       "중첩 wrapper 는 찾되, 배경 루트 내부 하위 폴더는 무시")
    }

    func testImportZipExtractsMovesAndImports() throws {
        // wrapper/111/project.json 구조를 --keepParent zip 으로 만들어 재귀 탐색·이동 검증.
        let pkg = tmp.appendingPathComponent("pkg", isDirectory: true)
        let inner = pkg.appendingPathComponent("111", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let json = #"{"type":"video","file":"wallpaper.mp4","preview":"preview.jpg","title":"zipwp"}"#
        try Data(json.utf8).write(to: inner.appendingPathComponent("project.json"))
        try Data("dummy".utf8).write(to: inner.appendingPathComponent("wallpaper.mp4"))

        let zipURL = tmp.appendingPathComponent("wp.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", pkg.path, zipURL.path]
        try ditto.run(); ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0, "픽스처 zip 생성")

        let store = LibraryStore(baseDirectory: base())
        let imported = store.importZip(zipURL)
        XCTAssertEqual(imported.map(\.id), ["111"])
        XCTAssertEqual(store.entries.map(\.id), ["111"])

        // 관리 위치로 옮겨져, 임시 정리 후에도 북마크가 유효해야 한다.
        let resolved = store.resolveFolderURL(for: imported[0])
        XCTAssertNotNil(resolved)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: resolved!.appendingPathComponent("project.json").path))
    }

    func testImportZipExtractionFailureReturnsEmpty() throws {
        let store = LibraryStore(baseDirectory: base())
        let imported = store.importZip(tmp.appendingPathComponent("nope.zip"),
                                       extract: { _, _ in false })
        XCTAssertTrue(imported.isEmpty)
        XCTAssertTrue(store.entries.isEmpty)
    }

    /// A2 분할 검증: extractZipToTemp(백그라운드 단계)는 스토어를 건드리지 않고 해제만 하고,
    /// importExtractedZip(메인 단계)이 등록 + 임시 정리를 완료한다 — 둘의 합성이 importZip 과 동치.
    func testExtractZipToTempThenImportExtractedZipTwoPhase() throws {
        let zipURL = try makeZipFixture(wrapperName: "Wallpaper", workshopId: "SPLIT1", tag: "Split")
        let store = LibraryStore(baseDirectory: base())

        let temp = try XCTUnwrap(store.extractZipToTemp(zipURL), "해제 단계 성공")
        XCTAssertTrue(store.entries.isEmpty, "해제 단계는 스토어 미변경")
        XCTAssertFalse(ZipImporter.findProjectRoots(in: temp).isEmpty, "해제물에 배경 루트 존재")

        let imported = store.importExtractedZip(temp)
        XCTAssertEqual(imported.map(\.id), ["SPLIT1"])
        XCTAssertEqual(store.entries.map(\.id), ["SPLIT1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "임시 디렉터리는 등록 단계가 정리")
    }

    /// A2 분할 검증(실패 경로): 해제 실패 시 nil + 임시 정리 + 스토어 불변.
    func testExtractZipToTempExtractionFailureReturnsNil() throws {
        let store = LibraryStore(baseDirectory: base())
        XCTAssertNil(store.extractZipToTemp(tmp.appendingPathComponent("nope.zip"),
                                            extract: { _, _ in false }))
        XCTAssertTrue(store.entries.isEmpty)
    }

    /// `--keepParent` zip 픽스처: wrapper/<wrapperName>/project.json + wallpaper.mp4(내용=tag 로 구분).
    private func makeZipFixture(wrapperName: String, workshopId: String?, tag: String) throws -> URL {
        let pkg = tmp.appendingPathComponent("pkg-\(UUID().uuidString)", isDirectory: true)
        let inner = pkg.appendingPathComponent(wrapperName, isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let workshopField = workshopId.map { #","workshopid":"\#($0)""# } ?? ""
        let json = #"{"type":"video","file":"wallpaper.mp4","preview":"preview.jpg","title":"\#(tag)"\#(workshopField)}"#
        try Data(json.utf8).write(to: inner.appendingPathComponent("project.json"))
        try Data("dummy-\(tag)".utf8).write(to: inner.appendingPathComponent("wallpaper.mp4"))

        let zipURL = tmp.appendingPathComponent("wp-\(UUID().uuidString).zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", pkg.path, zipURL.path]
        try ditto.run(); ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0, "픽스처 zip 생성")
        return zipURL
    }

    /// F247 필수 회귀: 래퍼 폴더명이 같아도(WE export 관례 `Wallpaper/`) workshopid 가 다르면
    /// 별개 배경이다 — 두 번째 zip import 가 첫 배경의 관리 폴더를 지우고 그 위에 얹혀 첫 엔트리를
    /// 무통지로 실종시키면 안 된다. 둘 다 라이브러리에 살아남고, 각자의 파일 내용도 뒤섞이면 안 된다.
    func testImportZipSameWrapperNameDifferentWorkshopIdBothSurvive() throws {
        let zipA = try makeZipFixture(wrapperName: "Wallpaper", workshopId: "AAA111", tag: "First")
        let zipB = try makeZipFixture(wrapperName: "Wallpaper", workshopId: "BBB222", tag: "Second")

        let store = LibraryStore(baseDirectory: base())
        let importedA = store.importZip(zipA)
        XCTAssertEqual(importedA.map(\.id), ["AAA111"])
        let importedB = store.importZip(zipB)
        XCTAssertEqual(importedB.map(\.id), ["BBB222"])

        // 둘 다 라이브러리 인덱스에 살아남아야 한다(무통지 대체 금지).
        XCTAssertEqual(Set(store.entries.map(\.id)), ["AAA111", "BBB222"])

        // 각자의 관리 폴더가 실제로 디스크에 남아있고, 내용이 뒤섞이지 않아야 한다.
        let resolvedA = try XCTUnwrap(store.resolveFolderURL(for: importedA[0]))
        let resolvedB = try XCTUnwrap(store.resolveFolderURL(for: importedB[0]))
        XCTAssertNotEqual(resolvedA, resolvedB)
        let contentA = try Data(contentsOf: resolvedA.appendingPathComponent("wallpaper.mp4"))
        let contentB = try Data(contentsOf: resolvedB.appendingPathComponent("wallpaper.mp4"))
        XCTAssertEqual(String(data: contentA, encoding: .utf8), "dummy-First")
        XCTAssertEqual(String(data: contentB, encoding: .utf8), "dummy-Second")
    }

    /// 잔여 케이스: 둘 다 workshopid 가 전혀 없으면 폴더명 폴백만으로는 정체성을 확정할 수 없다.
    /// 이때 관리 폴더 충돌을 만나면 지우지 말고 유일화해야 한다(재가져오기인지 확정 불가 = 보수적으로 보존).
    func testImportZipSameWrapperNameNoWorkshopIdUniquifiesInsteadOfDeleting() throws {
        let zipA = try makeZipFixture(wrapperName: "Wallpaper", workshopId: nil, tag: "First")
        let zipB = try makeZipFixture(wrapperName: "Wallpaper", workshopId: nil, tag: "Second")

        let store = LibraryStore(baseDirectory: base())
        let importedA = store.importZip(zipA)
        let importedB = store.importZip(zipB)
        XCTAssertEqual(importedA.map(\.id), ["Wallpaper"])
        XCTAssertNotEqual(importedB.map(\.id), ["Wallpaper"], "정체성 불명 충돌은 유일화되어야 한다")

        XCTAssertEqual(Set(store.entries.map(\.id)).count, 2, "둘 다 보존")
        let resolvedA = try XCTUnwrap(store.resolveFolderURL(for: importedA[0]))
        let resolvedB = try XCTUnwrap(store.resolveFolderURL(for: importedB[0]))
        let contentA = try Data(contentsOf: resolvedA.appendingPathComponent("wallpaper.mp4"))
        let contentB = try Data(contentsOf: resolvedB.appendingPathComponent("wallpaper.mp4"))
        XCTAssertEqual(String(data: contentA, encoding: .utf8), "dummy-First", "첫 배경 파일이 지워지면 안 된다")
        XCTAssertEqual(String(data: contentB, encoding: .utf8), "dummy-Second")
    }

    func testResolveFolderURLReturnsOriginalLocation() throws {
        let folder = try makeWallpaperFolder(id: "111")
        let store = LibraryStore(baseDirectory: base())
        let entry = try store.importFolder(folder)
        let resolved = store.resolveFolderURL(for: entry)
        XCTAssertEqual(resolved?.standardizedFileURL, folder.standardizedFileURL)
    }
}
