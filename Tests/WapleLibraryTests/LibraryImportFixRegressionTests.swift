import XCTest
@testable import WapleLibrary

/// 임포트 경로 결함 수정(F580–F586) 회귀 모음 — 각 테스트는 개별 F주석을 참조한다.
final class LibraryImportFixRegressionTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WapleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func base() -> URL { tmp.appendingPathComponent("store", isDirectory: true) }

    /// 임시 배경 폴더(project.json + 더미 자산) 생성(LibraryStoreTests 관례와 동일).
    private func makeWallpaperFolder(id: String, type: String = "video") throws -> URL {
        let folder = tmp.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"{"type":"\#(type)","file":"wallpaper.mp4","preview":"preview.jpg","title":"\#(id)"}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
        try Data("dummy".utf8).write(to: folder.appendingPathComponent("wallpaper.mp4"))
        return folder
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

    // MARK: - F580: zip workshopid 경로 탈출

    /// workshopid 에 경로 탈출("../escaped")을 심은 zip 을 가져와도 관리 폴더는 imported/ 안에
    /// 갇혀 있어야 한다 — 비살균 id 를 폴더명에 쓰면 removeItem/moveItem 이 임의 디렉터리를 파괴한다.
    func testImportZipMaliciousWorkshopIdStaysInsideImportedDir() throws {
        let zipURL = try makeZipFixture(wrapperName: "Wallpaper", workshopId: "../escaped", tag: "Evil")
        let store = LibraryStore(baseDirectory: base())
        let imported = store.importZip(zipURL)
        XCTAssertEqual(imported.count, 1, "살균 후 폴더명 폴더백으로 가져오기는 성공해야 한다")

        let resolved = try XCTUnwrap(store.resolveFolderURL(for: imported[0]))
        let importedRoot = base().appendingPathComponent("imported", isDirectory: true).standardizedFileURL
        XCTAssertTrue(resolved.standardizedFileURL.path.hasPrefix(importedRoot.path + "/"),
                      "관리 폴더는 imported/ 안에 갇혀 있어야 한다 — 실제: \(resolved.path)")
        // 탈출 대상 경로(imported/../escaped == base/escaped)가 생성·교체되지 않아야 한다.
        XCTAssertFalse(FileManager.default.fileExists(atPath: base().appendingPathComponent("escaped").path),
                       "imported/ 밖 탈출 경로에 폴더가 생기면 안 된다")
    }

    // MARK: - F581: 유일화 엔트리 재임포트 멱등

    /// workshopid 없는 두 배경이 같은 폴더명 id 로 귀결돼 유일화(-2)가 발동한 뒤, 두 번째 폴더를
    /// 재임포트하면 같은 소스로 식별해 기존 유일화 엔트리를 갱신해야 한다(X-3, X-4 … 중복 누적 방지).
    func testReimportOfUniquifiedEntryUpdatesInPlaceInsteadOfAccumulating() throws {
        let parentA = tmp.appendingPathComponent("A", isDirectory: true)
        let parentB = tmp.appendingPathComponent("B", isDirectory: true)
        let folderA = parentA.appendingPathComponent("Wallpaper", isDirectory: true)
        let folderB = parentB.appendingPathComponent("Wallpaper", isDirectory: true)
        for (folder, tag) in [(folderA, "A"), (folderB, "B")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let json = #"{"type":"video","file":"wallpaper.mp4","preview":"preview.jpg","title":"\#(tag)"}"#
            try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
            try Data("dummy-\(tag)".utf8).write(to: folder.appendingPathComponent("wallpaper.mp4"))
        }

        let store = LibraryStore(baseDirectory: base())
        try store.importFolder(folderA)              // "Wallpaper"
        let entryB = try store.importFolder(folderB) // 다른 실경로 충돌 → "Wallpaper-2"
        XCTAssertEqual(entryB.id, "Wallpaper-2")

        let entryB2 = try store.importFolder(folderB) // 같은 폴더 재임포트
        XCTAssertEqual(entryB2.id, "Wallpaper-2",
                       "F581: 같은 소스 재임포트는 새 접미가 아니라 기존 유일화 엔트리 갱신이어야 한다")
        XCTAssertEqual(store.entries.count, 2, "X-3, X-4 … 중복 누적 금지")
        XCTAssertEqual(Set(store.entries.map(\.id)), ["Wallpaper", "Wallpaper-2"])
    }

    // MARK: - F582: importParent 2단계 분할 + 저장 일괄화

    /// 스캔 단계(scanImportableFolders)는 스토어를 건드리지 않고(백그라운드 안전),
    /// 등록 단계(importFolders)와의 합성이 종전 importParent 와 동치여야 한다.
    func testScanImportableFoldersIsPureAndCompositionMatchesImportParent() throws {
        _ = try makeWallpaperFolder(id: "wp1")
        let store = LibraryStore(baseDirectory: base())
        let scanned = store.scanImportableFolders(in: tmp)
        XCTAssertTrue(store.entries.isEmpty, "스캔 단계는 스토어를 변경하지 않아야 한다")
        XCTAssertTrue(scanned.contains { $0.lastPathComponent == "wp1" })

        let imported = store.importFolders(scanned)
        XCTAssertEqual(imported.map(\.id), ["wp1"], "비배경 폴더(store 디렉터리)는 등록 단계에서 걸러진다")
    }

    /// 저장 일괄화 후에도 결과는 종전과 동치 — 전부 가져오고 인덱스가 실제 영속돼야 한다.
    func testImportParentImportsAllAndPersists() throws {
        for i in 1...5 { _ = try makeWallpaperFolder(id: "wp\(i)") }
        let store = LibraryStore(baseDirectory: base())
        let imported = store.importParent(tmp)
        XCTAssertEqual(Set(imported.map(\.id)), Set((1...5).map { "wp\($0)" }))

        let reloaded = LibraryStore(baseDirectory: base())
        XCTAssertEqual(reloaded.entries.count, 5, "일괄 save 가 실제 기록됐어야 한다")
    }

    // MARK: - F584: importExtractedZip 실패 경로 정리

    /// project.json 이 깨진 배경은 findProjectRoots 가 찾지만 등록(importFolder)은 실패한다 —
    /// 이동된 관리 폴더가 엔트리 없이 imported/ 에 고아로 남으면 안 된다.
    func testImportZipInvalidProjectJsonLeavesNoOrphanManagedFolder() throws {
        let pkg = tmp.appendingPathComponent("pkg-bad", isDirectory: true)
        let inner = pkg.appendingPathComponent("Bad", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("{ not valid json".utf8).write(to: inner.appendingPathComponent("project.json"))
        let zipURL = tmp.appendingPathComponent("bad-\(UUID().uuidString).zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", pkg.path, zipURL.path]
        try ditto.run(); ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0, "픽스처 zip 생성")

        let store = LibraryStore(baseDirectory: base())
        XCTAssertTrue(store.importZip(zipURL).isEmpty)
        let importedDir = base().appendingPathComponent("imported", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: importedDir.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "F584: 등록 실패한 관리 폴더가 고아로 남으면 안 된다 — \(leftovers)")
    }

    /// stable workshopid 재가져오기는 새 임시 루트를 관리 위치로 옮기지 못해도 기존 관리 폴더를
    /// 보존해야 한다. 소스 부모를 읽기 전용으로 만들어 dest 삭제는 성공하지만 move 는 실패하는
    /// 실제 순서를 결정적으로 재현한다.
    func testStableIdReimportMoveFailureRollsBackExistingManagedFolder() throws {
        try XCTSkipIf(getuid() == 0, "root 실행 시 권한 0o555 기반 move 실패 재현 불가")
        let store = LibraryStore(baseDirectory: base())
        let originalZip = try makeZipFixture(wrapperName: "Wallpaper", workshopId: "ROLLBACK1", tag: "Original")
        let original = try XCTUnwrap(store.importZip(originalZip).first)
        let originalFolder = try XCTUnwrap(store.resolveFolderURL(for: original))
        let originalAsset = originalFolder.appendingPathComponent("wallpaper.mp4")
        XCTAssertEqual(try String(contentsOf: originalAsset, encoding: .utf8), "dummy-Original")

        let replacementTemp = tmp.appendingPathComponent("replacement-temp", isDirectory: true)
        let replacementRoot = replacementTemp.appendingPathComponent("Wallpaper", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementRoot, withIntermediateDirectories: true)
        let replacementJSON = #"{"type":"video","file":"wallpaper.mp4","title":"Replacement","workshopid":"ROLLBACK1"}"#
        try Data(replacementJSON.utf8).write(to: replacementRoot.appendingPathComponent("project.json"))
        try Data("dummy-Replacement".utf8).write(to: replacementRoot.appendingPathComponent("wallpaper.mp4"))

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: replacementTemp.path)
        defer {
            if FileManager.default.fileExists(atPath: replacementTemp.path) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacementTemp.path)
            }
        }

        XCTAssertTrue(store.importExtractedZip(replacementTemp).isEmpty, "이동 실패 픽스처는 가져오기에 실패해야 한다")
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalAsset.path),
                      "새 root 이동 실패가 기존 stable-id 관리 폴더를 삭제하면 안 된다")
        XCTAssertEqual(try String(contentsOf: originalAsset, encoding: .utf8), "dummy-Original",
                       "실패한 교체 뒤 기존 콘텐츠가 그대로 남아야 한다")
        XCTAssertEqual(store.entries.map(\.id), ["ROLLBACK1"], "기존 라이브러리 엔트리도 유지돼야 한다")
    }

    // MARK: - F585: FolderStore.move 빈 이름 가드

    /// createFolder 와 대칭 — 트림 후 빈 이름으로는 폴더를 만들지 않는다(루트 이동과 동일 취급).
    func testMoveToWhitespaceOnlyNameCreatesNoFolder() {
        let store = FolderStore(baseDirectory: base())
        store.createFolder("A")
        store.move("id1", to: "A")
        store.move("id1", to: "   ")
        XCTAssertEqual(store.folders.map(\.name), ["A"], "공백 이름 폴더는 생성되지 않아야 한다")
        XCTAssertTrue(store.folders[0].ids.isEmpty, "공백 이동은 루트 이동과 동일하게 기존 소속만 해제")
    }

    // MARK: - F586: 기존 엔트리 북마크 해석 실패 시 충돌 검사

    private struct SeedIndex: Codable { var entries: [LibraryEntry]; var selectedId: String? }

    /// 기존 엔트리의 북마크가 깨져 해석이 nil 이면 같은 소스인지 확인할 수 없다 — 충돌 검사를
    /// 건너뛰고 무통지 대체하지 말고 유일화해 둘 다 보존해야 한다.
    func testImportWithUnresolvableExistingBookmarkUniquifiesInsteadOfReplacing() throws {
        let storeDir = base()
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let broken = LibraryEntry(id: "X", title: "Broken", typeRaw: "video",
                                  fileName: nil, previewName: nil, bookmark: Data("garbage".utf8))
        let data = try JSONEncoder().encode(SeedIndex(entries: [broken], selectedId: nil))
        try data.write(to: storeDir.appendingPathComponent("library.json"))

        let store = LibraryStore(baseDirectory: storeDir)
        let folder = try makeWallpaperFolder(id: "X")
        let entry = try store.importFolder(folder)
        XCTAssertEqual(entry.id, "X-2", "해석 불가 엔트리를 무통지 대체하지 말고 유일화해야 한다")
        XCTAssertEqual(Set(store.entries.map(\.id)), ["X", "X-2"])
        XCTAssertEqual(store.entries.first(where: { $0.id == "X" })?.bookmark, Data("garbage".utf8),
                       "기존 엔트리는 보존돼야 한다")
    }
}
