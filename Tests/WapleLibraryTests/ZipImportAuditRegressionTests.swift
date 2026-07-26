import XCTest
@testable import WapleLibrary

/// 감사 V06 — zip 임포트 경로 회귀 모음.
final class ZipImportAuditRegressionTests: XCTestCase {
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

    /// zip 해제 직후 상태의 임시 디렉터리를 흉낸다(배경 루트 N개, workshopid 부여).
    private func makeExtractedTemp(rootCount: Int) throws -> URL {
        let temp = tmp.appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        for i in 1...rootCount {
            let folder = temp.appendingPathComponent("wp\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let json = #"{"type":"video","file":"wallpaper.mp4","title":"wp\#(i)","workshopid":"W000\#(i)"}"#
            try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
            try Data("dummy-\(i)".utf8).write(to: folder.appendingPathComponent("wallpaper.mp4"))
        }
        return temp
    }

    // MARK: - 감사 V06 (1): importExtractedZip 인덱스 저장 일괄화

    /// 루트 N개를 가져와도 인덱스 save 는 1회여야 한다 — 루트마다 저장하면 호출마다 전체 인덱스를
    /// 재작성해 O(n²)(F582 가 importFolders 에 적용한 것과 같은 결함). 기능 결과(전부 등록·영속)는 동치.
    func testImportExtractedZipSavesIndexOnceForMultipleRoots() throws {
        let temp = try makeExtractedTemp(rootCount: 3)
        let store = LibraryStore(baseDirectory: base())
        let savesBefore = store.saveCount

        let imported = store.importExtractedZip(temp)
        XCTAssertEqual(imported.count, 3)
        XCTAssertEqual(store.saveCount - savesBefore, 1,
                       "감사 V06: 루트마다 save 하면 O(n²) — 루프 후 1회만 저장해야 한다")

        let reloaded = LibraryStore(baseDirectory: base())
        XCTAssertEqual(reloaded.entries.count, 3, "일괄 save 가 실제 영속돼야 한다")
    }

    /// `--keepParent` zip 픽스처: wrapper/<wrapperName>/project.json + wallpaper.mp4(LibraryStoreTests 관례와 동일).
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

    // MARK: - 감사 V06 (2): ditto 해제 타임아웃

    /// 행 걸린 해제 프로세스(/bin/sleep 으로 시뮬레이션)는 상한 초과 시 종료(SIGTERM→SIGKILL)되고
    /// extractionTimedOut 을 던져야 한다 — 무한 대기하면 직렬 importQueue 가 영구 정지한다.
    func testWaitForExitOrKillTerminatesHungProcessAndThrows() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        try p.run()

        let start = Date()
        XCTAssertThrowsError(try ZipImporter.waitForExitOrKill(p, timeout: 0.2, terminateGrace: 1)) { error in
            XCTAssertEqual(error as? ZipImporter.ZipImportError, .extractionTimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "타임아웃 후 프로세스를 회수하고 복귀해야 한다")
        XCTAssertFalse(p.isRunning, "행 걸린 프로세스는 종료(SIGTERM→SIGKILL)됐어야 한다")
    }

    /// 정상 종료 프로세스는 에러 없이 돌아와야 한다(타임아웃 오발동 금지).
    func testWaitForExitOrKillReturnsForFastProcess() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        XCTAssertNoThrow(try ZipImporter.waitForExitOrKill(p, timeout: 5, terminateGrace: 1))
    }

    /// 실제 zip 해제의 성공 경로는 타임아웃 도입 후에도 그대로여야 한다.
    func testDittoExtractRealZipSucceeds() throws {
        let zipURL = try makeZipFixture(wrapperName: "Wallpaper", workshopId: "T100", tag: "Ok")
        let dest = tmp.appendingPathComponent("dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        XCTAssertTrue(try ZipImporter.dittoExtract(zipURL, dest))
        // --keepParent 픽스처는 최상위에 pkg 래퍼가 한 단계 더 있다 — 재귀 탐색으로 확인한다.
        XCTAssertEqual(ZipImporter.findProjectRoots(in: dest).count, 1, "해제물에 배경 루트가 있어야 한다")
    }
}
