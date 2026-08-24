import XCTest
@testable import Waple
import WapleCore
import WapleLibrary

/// WorkshopViewModel.download 상태머신 — downloader 주입 심으로 steamcmd 없이
/// phase 매핑·실패 메시지·완료(임포트) 경로를 검증한다.
@MainActor
final class WorkshopDownloadTests: XCTestCase {

    /// 다운로더 콜백 캡처 — 테스트가 progress/completion 을 수동으로 몰아 상태 전이를 검증한다.
    private final class FakeDownloader {
        private(set) var calls: [(itemId: String, username: String)] = []
        private(set) var progress: ((SteamCmdDownloader.Progress) -> Void)?
        private(set) var completion: ((URL?) -> Void)?
        var body: WorkshopViewModel.Downloader {
            { itemId, username, progress, completion in
                self.calls.append((itemId, username))
                self.progress = progress
                self.completion = completion
            }
        }
    }

    private var savedUsername = ""
    private var tempDirs: [URL] = []

    // SteamCmdDownloader.username 은 UserDefaults.standard 전역 영속 — 스냅샷/복원으로 방어한다.
    // 이 방어는 직렬 실행 전제다(테스트 병렬 실행 시 스냅샷/복원이 인터리브해 상호 오염 가능 — 기본
    // 직렬 실행에서는 안전). 완전 격리는 프로덕션 측 UserDefaults 주입 설계 변경이 필요해 여기선 유지.
    override func setUp() async throws {
        savedUsername = SteamCmdDownloader.username   // download() 가 UserDefaults 를 덮어쓰므로 복원용
    }

    override func tearDown() async throws {
        SteamCmdDownloader.username = savedUsername
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }   // $TMPDIR 리터 방지
        tempDirs = []
    }

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    private func makeLibrary() -> LibraryViewModel {
        let dir = tempDir()
        return LibraryViewModel(store: LibraryStore(baseDirectory: dir),
                                playlist: PlaylistStore(baseDirectory: dir),
                                monitors: MonitorAssignmentStore(baseDirectory: dir),
                                favorites: FavoritesStore(baseDirectory: dir),
                                folders: FolderStore(baseDirectory: dir))
    }

    private func makeItem(id: String = "123", voteScore: Double? = nil) -> WorkshopItem {
        WorkshopItem(id: id, title: "t\(id)", previewURL: nil, subscriptions: nil,
                     tags: [], fileSize: nil, voteScore: voteScore)
    }

    private func makeVM(fake: FakeDownloader, library: LibraryViewModel? = nil) -> WorkshopViewModel {
        let vm = WorkshopViewModel(client: WorkshopClient(transport: { _ in (Data(), 200) }),
                                   library: library ?? makeLibrary(),
                                   keyProvider: { "KEY" },
                                   steamcmdAvailable: true,
                                   downloader: fake.body)
        vm.usernameInput = "tester"
        return vm
    }

    /// steamcmd 결과 폴더 임포트용 임시 배경 폴더(project.json + 더미 자산).
    private func makeWallpaperFolder(id: String) throws -> URL {
        let folder = tempDir().appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"{"type":"video","file":"wallpaper.mp4","title":"\#(id)"}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
        try Data("dummy".utf8).write(to: folder.appendingPathComponent("wallpaper.mp4"))
        return folder
    }

    func testDownloadStartsAndMapsProgressToPhases() async {
        let fake = FakeDownloader()
        let vm = makeVM(fake: fake)
        vm.download(makeItem())
        XCTAssertEqual(fake.calls.map(\.itemId), ["123"])
        XCTAssertEqual(fake.calls.map(\.username), ["tester"], "trim된 username 이 그대로 전달된다")
        XCTAssertEqual(vm.downloads["123"]?.phase, .downloading(nil), "시작 즉시 다운로드 상태")

        fake.progress?(.downloading(42)); await pump()
        XCTAssertEqual(vm.downloads["123"]?.phase, .downloading(42))
        fake.progress?(.verifying); await pump()
        XCTAssertEqual(vm.downloads["123"]?.phase, .verifying)
        fake.progress?(.committing); await pump()
        XCTAssertEqual(vm.downloads["123"]?.phase, .committing)
        fake.progress?(.success); await pump()
        XCTAssertEqual(vm.downloads["123"]?.phase, .importing, "성공 신호는 임포트 진행으로 매핑")
    }

    func testFailedProgressMarksFailed() async {
        let fake = FakeDownloader()
        let vm = makeVM(fake: fake)
        vm.download(makeItem())
        fake.progress?(.failed); await pump()
        XCTAssertEqual(vm.downloads["123"]?.phase, .failed)
    }

    func testNilCompletionMarksFailedWithLoginHint() async {
        let fake = FakeDownloader()
        let vm = makeVM(fake: fake)
        let item = makeItem()
        vm.download(item)
        fake.completion?(nil); await pump()
        XCTAssertEqual(vm.downloads["123"]?.phase, .failed)
        XCTAssertNil(vm.downloads["123"]?.entryId)
        XCTAssertTrue(vm.statusMessage?.contains("‘\(item.title)’ 다운로드 실패") == true)
        XCTAssertTrue(vm.statusMessage?.contains("steamcmd +login") == true, "세션 캐시(1회 로그인) 안내 포함")
    }

    func testCompletionImportsFolderAndMarksDone() async throws {
        let fake = FakeDownloader()
        let library = makeLibrary()
        let vm = makeVM(fake: fake, library: library)
        let folder = try makeWallpaperFolder(id: "123")
        vm.download(makeItem(voteScore: 0.8))
        fake.completion?(folder); await pump()

        XCTAssertEqual(vm.downloads["123"]?.phase, .done)
        XCTAssertEqual(vm.downloads["123"]?.entryId, "123", "workshopid 없으면 폴더명이 엔트리 id")
        let entry = library.entries.first { $0.id == "123" }
        XCTAssertNotNil(entry, "결과 폴더가 라이브러리로 임포트된다")
        XCTAssertEqual(entry?.rating, 0.8, "워크샵 평점을 라이브러리 평점으로 저장")
    }

    func testUnimportableCompletionMarksFailed() async {
        let fake = FakeDownloader()
        let library = makeLibrary()
        let vm = makeVM(fake: fake, library: library)
        vm.download(makeItem())
        fake.completion?(tempDir())   // project.json 없는 폴더 → 임포트 실패
        await pump()
        XCTAssertEqual(vm.downloads["123"]?.phase, .failed)
        XCTAssertTrue(library.entries.isEmpty)
    }

    // MARK: - 실패 사유 (2026-08-25)

    /// **실패 사유가 타일 상태에 실리는가.**
    ///
    /// 종전에는 사유가 `statusMessage`(화면 전역 캡션)에만 있었다. 여러 개를 동시에 받다 실패하면
    /// **어느 타일의 사유인지** 알 수 없었다. 이제 `DownloadUIState.failureReason` 이 함께 들고
    /// 타일이 `.help()` 툴팁으로 보여준다.
    func testDownloadFailureCarriesItsReasonOnTheTileState() async {
        let fake = FakeDownloader()
        let vm = makeVM(fake: fake)
        let item = makeItem()
        vm.download(item)
        fake.completion?(nil); await pump()

        let state = vm.downloads[item.id]
        XCTAssertEqual(state?.phase, .failed)
        XCTAssertNotNil(state?.failureReason, "타일이 사유를 들고 있어야 툴팁으로 보여줄 수 있다")
        XCTAssertEqual(state?.failureReason, vm.statusMessage,
                       "타일 사유와 화면 캡션은 같은 문장이어야 한다 — 두 말이 갈리면 어느 쪽이 맞는지 모른다")
    }

    /// **임포트 실패 분기는 사유를 아예 안 남기고 있었다.**
    ///
    /// 다운로드는 성공했는데 라이브러리 임포트가 실패한 경우다(받은 폴더에 `project.json` 이 없다).
    /// 위 세 분기와 달리 `statusMessage` 조차 세우지 않아 **사유가 어디에도 없었다** —
    /// 타일은 "다운로드 실패" 만 말했고 그건 사실도 아니었다(다운로드는 됐다).
    func testImportFailureAfterSuccessfulDownloadExplainsItself() async throws {
        let fake = FakeDownloader()
        let vm = makeVM(fake: fake)
        let item = makeItem()
        vm.download(item)
        // project.json 이 없는 폴더 — 다운로드는 성공, 임포트는 실패한다.
        let empty = tempDir().appendingPathComponent("no-project", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        fake.completion?(empty); await pump()

        XCTAssertEqual(vm.downloads[item.id]?.phase, .failed)
        let reason = try XCTUnwrap(vm.downloads[item.id]?.failureReason,
                                   "임포트 실패도 사유를 남겨야 한다 — 종전엔 어디에도 없었다")
        XCTAssertTrue(reason.contains("project.json"), "무엇이 문제인지 말해야 한다: \(reason)")
        XCTAssertEqual(vm.statusMessage, reason)
    }

    /// negative control — 성공 경로는 사유를 남기지 않는다.
    /// 이게 깨지면 위 둘이 "항상 채워진 필드" 를 검사하는 셈이 된다.
    func testSuccessfulDownloadLeavesNoFailureReason() async throws {
        let fake = FakeDownloader()
        let vm = makeVM(fake: fake)
        let item = makeItem()
        vm.download(item)
        fake.completion?(try makeWallpaperFolder(id: item.id)); await pump()
        XCTAssertEqual(vm.downloads[item.id]?.phase, .done)
        XCTAssertNil(vm.downloads[item.id]?.failureReason, "성공에는 실패 사유가 없어야 한다")
    }
}
