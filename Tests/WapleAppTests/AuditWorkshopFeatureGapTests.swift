import XCTest
@testable import Waple
import WapleCore
import WapleLibrary

@MainActor
final class AuditWorkshopFeatureGapTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDown() async throws {
        for directory in tempDirectories { try? FileManager.default.removeItem(at: directory) }
        tempDirectories = []
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func library(at directory: URL) -> LibraryViewModel {
        LibraryViewModel(store: LibraryStore(baseDirectory: directory),
                         playlist: PlaylistStore(baseDirectory: directory),
                         monitors: MonitorAssignmentStore(baseDirectory: directory),
                         favorites: FavoritesStore(baseDirectory: directory),
                         folders: FolderStore(baseDirectory: directory))
    }

    private func wallpaperFolder() throws -> URL {
        let directory = try temporaryDirectory().appendingPathComponent("local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"type":"video","file":"wallpaper.mp4","title":"Fixture"}"#.utf8)
            .write(to: directory.appendingPathComponent("project.json"))
        try Data([0, 1, 2]).write(to: directory.appendingPathComponent("wallpaper.mp4"))
        return directory
    }

    private func item(_ id: String = "123456") -> WorkshopItem {
        WorkshopItem(id: id, title: "Fixture", previewURL: nil, subscriptions: nil,
                     tags: [], fileSize: nil, voteScore: nil)
    }

    func testDownloadedRemoteIdentitySurvivesRestartAndAppliesTheActualLocalEntry() async throws {
        let directory = try temporaryDirectory()
        let original = library(at: directory)
        let folder = try wallpaperFolder()
        var finish: ((URL?) -> Void)?
        var downloadedIDs: [String] = []
        let vm = WorkshopViewModel(library: original, keyProvider: { nil }, steamcmdAvailable: true,
                                   usernameProvider: { "fixture" }, usernameSaver: { _ in },
                                   downloader: { id, _, _, completion in
            downloadedIDs.append(id)
            finish = completion
            return nil
        })
        let remote = item()
        vm.download(remote)
        finish?(folder)
        await pump()
        XCTAssertEqual(downloadedIDs, [remote.id])
        let local = try XCTUnwrap(original.entries.first)
        XCTAssertNotEqual(local.id, remote.id)
        XCTAssertEqual(local.workshopItemID, remote.id)

        let restored = library(at: directory)
        var applied = false
        restored.onApply = { _, _ in applied = true; return .applied }
        let reloadedVM = WorkshopViewModel(library: restored, keyProvider: { nil }, steamcmdAvailable: false,
                                          usernameProvider: { "" }, usernameSaver: { _ in },
                                          downloader: { _, _, _, _ in XCTFail("Installed item must not redownload"); return nil })
        XCTAssertEqual(reloadedVM.downloadState(for: remote)?.phase, .done)
        XCTAssertEqual(reloadedVM.downloadState(for: remote)?.entryId, local.id)
        reloadedVM.download(remote)
        reloadedVM.apply(remote)
        XCTAssertTrue(applied)
        XCTAssertEqual(restored.selectedId, local.id)
    }

    func testRemovingInstalledEntryClearsRemoteInstalledState() throws {
        let directory = try temporaryDirectory()
        let library = library(at: directory)
        let remote = item()
        let entry = try XCTUnwrap(library.importDownloaded(try wallpaperFolder(), workshopItemID: remote.id))
        let vm = WorkshopViewModel(library: library, keyProvider: { nil }, steamcmdAvailable: false,
                                   usernameProvider: { "" }, usernameSaver: { _ in })
        XCTAssertEqual(vm.downloadState(for: remote)?.entryId, entry.id)
        library.remove(entry)
        XCTAssertNil(vm.downloadState(for: remote))
        XCTAssertNil(LibraryStore(baseDirectory: directory).entries.first { $0.workshopItemID == remote.id })
    }

    func testReimportPreservesDownloadedRemoteIdentityAndLegacyIndexStillLoads() throws {
        let directory = try temporaryDirectory()
        let store = LibraryStore(baseDirectory: directory)
        let folder = try wallpaperFolder()
        let downloaded = try store.importFolder(folder, workshopItemID: "123456")
        let reimported = try store.importFolder(folder)
        XCTAssertEqual(reimported.id, downloaded.id)
        XCTAssertEqual(reimported.workshopItemID, "123456")
        XCTAssertEqual(LibraryStore(baseDirectory: directory).entries.first?.workshopItemID, "123456")

        let legacyDirectory = try temporaryDirectory()
        let encoded = try JSONEncoder().encode(downloaded)
        var legacyEntry = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyEntry.removeValue(forKey: "workshopItemID")
        let legacy = try JSONSerialization.data(withJSONObject: ["entries": [legacyEntry]])
        try legacy.write(to: legacyDirectory.appendingPathComponent("library.json"))
        let restored = LibraryStore(baseDirectory: legacyDirectory)
        XCTAssertEqual(restored.entries.count, 1)
        XCTAssertNil(restored.entries.first?.workshopItemID)
    }

    func testCancelAndRetryRejectsOldCallbacksWithoutAffectingAnotherDownload() async throws {
        let library = library(at: try temporaryDirectory())
        var requests: [(String, (SteamCmdDownloader.Progress) -> Void, (URL?) -> Void, SteamCmdDownloader.DownloadTask)] = []
        let vm = WorkshopViewModel(library: library, keyProvider: { nil }, steamcmdAvailable: true,
                                   usernameProvider: { "fixture" }, usernameSaver: { _ in },
                                   downloader: { id, _, progress, completion in
            let task = SteamCmdDownloader.DownloadTask()
            requests.append((id, progress, completion, task))
            return task
        })
        let first = item("123456")
        let other = item("654321")
        vm.download(first)
        vm.download(first)
        XCTAssertEqual(requests.count, 1, "An active item cannot start a second process")
        vm.cancelDownload(first)
        vm.cancelDownload(first)
        XCTAssertTrue(requests[0].3.isCancelled)
        XCTAssertEqual(vm.downloadState(for: first)?.phase, .cancelled)
        vm.download(first)
        vm.download(other)
        XCTAssertEqual(requests.count, 3)
        requests[0].1(.success)
        requests[0].2(try wallpaperFolder())
        await pump()
        XCTAssertTrue(library.entries.isEmpty, "Cancelled completion must never import")
        XCTAssertEqual(vm.downloadState(for: first)?.phase, .downloading(nil))
        XCTAssertFalse(requests[1].3.isCancelled)
        XCTAssertFalse(requests[2].3.isCancelled)
        requests[2].1(.downloading(40))
        await pump()
        XCTAssertEqual(vm.downloadState(for: other)?.phase, .downloading(40))
        requests[1].2(try wallpaperFolder())
        await pump()
        XCTAssertEqual(vm.downloadState(for: first)?.phase, .done)
        XCTAssertEqual(library.entries.count, 1)
        vm.cancelDownload(other)
        XCTAssertTrue(requests[2].3.isCancelled)
        XCTAssertEqual(vm.downloadState(for: first)?.phase, .done)
    }

    func testCancellationBeforeProcessLaunchDoesNotExecuteTheCommand() {
        let task = SteamCmdDownloader.DownloadTask()
        task.cancel()
        let result = SteamCmdDownloader.run(exe: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "printf 'Success. Downloaded item 1 to \"/tmp/unused-fixture\"\\n'"],
            timeout: 1, progress: { _ in XCTFail("Cancelled task must not produce progress") }, task: task)
        XCTAssertFalse(result.sawSuccess)
        XCTAssertNil(result.path)
    }

    func testCancellationStopsATermIgnoringProcessBeforeItsTimeout() async {
        let task = SteamCmdDownloader.DownloadTask()
        let entered = expectation(description: "Local fixture process started")
        let finished = expectation(description: "Cancelled process returns")
        let run = Task.detached {
            let result = SteamCmdDownloader.run(exe: URL(fileURLWithPath: "/bin/sh"),
                args: ["-c", "trap '' TERM; printf 'Update state (0x61) progress: 1\\n'; while :; do :; done"],
                timeout: 30, terminateGrace: 0.1,
                progress: { _ in entered.fulfill() }, task: task)
            finished.fulfill()
            return result
        }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel(terminateGrace: 0.1)
        await fulfillment(of: [finished], timeout: 5)
        let result = await run.value
        XCTAssertFalse(result.sawSuccess)
        XCTAssertTrue(task.isCancelled)
    }

}
