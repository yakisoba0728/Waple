import XCTest
@testable import Waple
import WapleLibrary

/// fix-g8 회귀 테스트 — Waple 앱 UI/워크샵 감사 항목(F-35/36/37/97/98/101/102/103, 코드 주석 F490–F500).
/// 뷰 레벨 수정(F490 Stepper 정합·F494 슬라이더 커밋 시점·F497 알림 갱신·F498 캐시·F501 deprecated
/// API 교체·F502 conformance 제거·F503 단축키 제거)은 SwiftUI 라이프사이클 의존이라 단위 테스트 대상이
/// 아니며, 추출된 순수 로직/주입 가능 경로만 검증한다.
@MainActor
final class AppUIFixRegressionTests: XCTestCase {

    // MARK: - 공통 픽스처

    private final class FakeDownloader {
        private(set) var progress: ((SteamCmdDownloader.Progress) -> Void)?
        private(set) var completion: ((URL?) -> Void)?
        var body: WorkshopViewModel.Downloader {
            { _, _, progress, completion in
                self.progress = progress
                self.completion = completion
            }
        }
    }

    private var savedUsername = ""

    override func setUp() async throws {
        savedUsername = SteamCmdDownloader.username   // download() 가 UserDefaults 를 덮어쓰므로 복원용
    }

    override func tearDown() async throws {
        SteamCmdDownloader.username = savedUsername
    }

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
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

    private func makeItem(id: String = "123") -> WorkshopItem {
        WorkshopItem(id: id, title: "t\(id)", previewURL: nil, subscriptions: nil,
                     tags: [], fileSize: nil, voteScore: nil)
    }

    private func makeVM(fake: FakeDownloader,
                        keySaver: @escaping (String) -> SteamAPIKeyStore.SaveFailure? = { _ in nil },
                        keyProvider: @escaping () -> String? = { "KEY" }) -> WorkshopViewModel {
        let vm = WorkshopViewModel(client: WorkshopClient(transport: { _ in (Data(), 200) }),
                                   library: makeLibrary(),
                                   keyProvider: keyProvider,
                                   keySaver: keySaver,
                                   steamcmdAvailable: true,
                                   downloader: fake.body)
        vm.usernameInput = "tester"
        return vm
    }

    /// VM 콜백이 Task { @MainActor } 로 한 번 홉하므로 메인 액터 큐를 비워 적용을 기다린다.
    private func pump() async {
        for _ in 0..<3 { await Task.yield() }
    }

    private func entry(_ id: String) -> LibraryEntry {
        LibraryEntry(id: id, title: "t\(id)", typeRaw: "video",
                     fileName: nil, previewName: nil, bookmark: Data())
    }

    // MARK: - F491(F-36): saveAPIKey 가 SaveFailure 를 버리지 않는다

    func testSaveAPIKey_aclDeniedSurfacesMessageAndKeepsInput() {
        let vm = makeVM(fake: FakeDownloader(),
                        keySaver: { _ in .aclDenied },
                        keyProvider: { "OLD-KEY" })   // 구키가 계속 읽히는 상황
        vm.apiKeyInput = "NEW-KEY"
        vm.saveAPIKey()

        XCTAssertEqual(vm.statusMessage, SteamAPIKeyStore.SaveFailure.aclDenied.message,
                       "ACL 거부 안내(키체인 접근 앱에서 삭제)가 그대로 표시돼야 한다")
        XCTAssertEqual(vm.apiKeyInput, "NEW-KEY",
                       "실패인데 입력을 지우면 재시도할 수 없다 — 종전엔 구키 존재로 성공 판정해 지웠다")
        XCTAssertTrue(vm.hasAPIKey, "구키는 살아 있으므로 게이트 상태는 실제와 일치시킨다")
    }

    func testSaveAPIKey_successClearsInputAndMessage() {
        let vm = makeVM(fake: FakeDownloader())
        vm.apiKeyInput = "NEW-KEY"
        vm.statusMessage = "이전 오류"
        vm.saveAPIKey()

        XCTAssertNil(vm.statusMessage)
        XCTAssertEqual(vm.apiKeyInput, "")
        XCTAssertTrue(vm.hasAPIKey)
    }

    // MARK: - F493(F-101): clearAPIKey 가 삭제 실패를 무시하지 않는다

    func testClearAPIKey_deleteFailureKeepsStateAndSurfacesMessage() {
        let failure = SteamAPIKeyStore.SaveFailure.other(-25300)
        let vm = makeVM(fake: FakeDownloader(), keySaver: { _ in failure })
        vm.clearAPIKey()

        XCTAssertEqual(vm.statusMessage, failure.message, "삭제 실패를 사용자에게 표면화")
        XCTAssertTrue(vm.hasAPIKey,
                      "stale 키가 Keychain 에 남았는데 false 로 두면 다음 실행 때 부활을 숨긴다")
    }

    func testClearAPIKey_successClearsKey() {
        let vm = makeVM(fake: FakeDownloader())
        vm.clearAPIKey()
        XCTAssertFalse(vm.hasAPIKey)
    }

    // MARK: - F492(F-37): 다운로드 실패 메시지를 신호로 구분한다

    func testFailedCompletion_withoutSignal_reportsGenericCause() async {
        let fake = FakeDownloader()
        let vm = makeVM(fake: fake)
        let item = makeItem()
        vm.download(item)
        fake.completion?(nil)   // 아무 신호 없이 실패(타임아웃·실행 실패 등)
        await pump()

        XCTAssertEqual(vm.downloads["123"]?.phase, .failed)
        XCTAssertTrue(vm.statusMessage?.contains("완료 신호를 내지 않았습니다") == true,
                      "로그인 단정 대신 타임아웃·네트워크·실행 오류 가능성을 안내")
        XCTAssertTrue(vm.statusMessage?.contains("steamcmd +login") == true,
                      "세션 캐시 확인 경로는 유지")
    }

    func testFailedCompletion_afterErrorSignal_keepsLoginHint() async {
        let fake = FakeDownloader()
        let vm = makeVM(fake: fake)
        let item = makeItem()
        vm.download(item)
        fake.progress?(.failed)   // steamcmd ERROR! 라인 — 로그인/세션 계열이 대표적
        await pump()
        fake.completion?(nil)
        await pump()

        XCTAssertTrue(vm.statusMessage?.contains("세션을 캐시했는지") == true,
                      "ERROR! 신호 관측 시 기존 로그인 안내 유지")
    }

    func testFailedCompletion_afterSuccessSignal_reportsMissingFolder() async {
        let fake = FakeDownloader()
        let vm = makeVM(fake: fake)
        let item = makeItem()
        vm.download(item)
        fake.progress?(.success)   // 완료 신호는 왔는데 결과 폴더가 없음
        await pump()
        fake.completion?(nil)
        await pump()

        XCTAssertEqual(vm.downloads["123"]?.phase, .failed)
        XCTAssertTrue(vm.statusMessage?.contains("결과 폴더를 찾지 못했습니다") == true,
                      "성공 후 폴더 부재는 로그인 무관 원인으로 안내")
    }

    func testSignalsDoNotLeakAcrossRetries() async {
        let fake = FakeDownloader()
        let vm = makeVM(fake: fake)
        let item = makeItem()
        vm.download(item)
        fake.progress?(.failed)
        await pump()
        fake.completion?(nil)
        await pump()
        // 재시도 — 이전 실행의 ERROR! 신호가 남아 있으면 이번 무신호 실패가 로그인으로 오진단된다.
        vm.download(item)
        fake.completion?(nil)
        await pump()

        XCTAssertTrue(vm.statusMessage?.contains("완료 신호를 내지 않았습니다") == true,
                      "재시도 시 신호 초기화 — 이전 실행의 신호가 섞이면 안 된다")
    }

    // MARK: - F495(F-97): 하단 바 표시 엔트리 — 전역 선택 우선, 할당 폴백

    func testDisplayedEntry_prefersGlobalSelection() {
        let entries = [entry("g"), entry("a")]
        let picked = NowPlayingSubtitle.displayedEntry(global: entries[0],
                                                       assignedIds: ["a"], entries: entries)
        XCTAssertEqual(picked?.id, "g")
    }

    func testDisplayedEntry_fallsBackToMonitorAssignment() {
        let entries = [entry("a")]
        let picked = NowPlayingSubtitle.displayedEntry(global: nil,
                                                       assignedIds: ["a"], entries: entries)
        XCTAssertEqual(picked?.id, "a",
                       "할당-전용 세션에서도 재생 중인 배경이 표시돼야 한다(종전엔 '적용된 배경 없음')")
    }

    func testDisplayedEntry_nilWhenNothingPlaying() {
        let picked = NowPlayingSubtitle.displayedEntry(global: nil,
                                                       assignedIds: [], entries: [entry("a")])
        XCTAssertNil(picked)
        let stale = NowPlayingSubtitle.displayedEntry(global: nil,
                                                      assignedIds: ["gone"], entries: [entry("a")])
        XCTAssertNil(stale, "유실된 할당 id 는 표시하지 않는다")
    }

    // MARK: - F496(F-98): 체크마크는 전 대상 공통 값일 때만

    func testCommonValue_uniformValuesReturnValue() {
        XCTAssertEqual(NowPlayingSubtitle.commonValue([0.5, 0.5, 0.5]), 0.5)
    }

    func testCommonValue_mixedValuesReturnNil() {
        XCTAssertNil(NowPlayingSubtitle.commonValue([0.5, 0.25]),
                     "모니터별 값이 다른데 첫 대상 값에 체크하면 표시와 실제가 어긋난다")
    }

    func testCommonValue_emptyReturnsNil() {
        XCTAssertNil(NowPlayingSubtitle.commonValue([]))
    }

    // MARK: - F499(F-102): 성공 라인의 목적지 경로 파싱

    func testSuccessPath_extractsQuotedPath() {
        let line = #"Success. Downloaded item 3520916483 to "/opt/homebrew/steamapps/workshop/content/431960/3520916483" :"#
        XCTAssertEqual(SteamCmdDownloader.successPath(line),
                       "/opt/homebrew/steamapps/workshop/content/431960/3520916483",
                       "성공 라인이 알려준 경로를 후보 스캔보다 우선해 stale 임포트를 막는다")
    }

    func testSuccessPath_withoutPathReturnsNil() {
        XCTAssertNil(SteamCmdDownloader.successPath("Success. Downloaded item 123"))
        XCTAssertNil(SteamCmdDownloader.successPath(#"ERROR! Download item 123 failed (Failure)"#))
        XCTAssertNil(SteamCmdDownloader.successPath("Update state (0x61) downloading, progress: 42.00"))
    }

    // MARK: - F500(F-103): 프리뷰 캐시 — 비동기 로드 + 캐시 히트

    func testPreviewImageCache_loadsAndCaches() async throws {
        // 2×2 PNG 를 임시 파일로 만든다.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("테스트 PNG 생성 실패"); return
        }
        let url = tempDir().appendingPathComponent("preview.png")
        try png.write(to: url)

        XCTAssertNil(PreviewImageCache.cached(url), "로드 전에는 캐시 미스")
        let loaded = await PreviewImageCache.load(url)
        XCTAssertNotNil(loaded, "백그라운드 디코드 성공")
        XCTAssertNotNil(PreviewImageCache.cached(url), "로드 후 캐시 히트 — body 재평가 시 디스크 재읽기 없음")
        let again = await PreviewImageCache.load(url)
        XCTAssertTrue(again === loaded, "두 번째 로드는 캐시된 동일 인스턴스")
    }

    func testPreviewImageCache_missingFileReturnsNil() async {
        let url = tempDir().appendingPathComponent("missing.png")
        let loaded = await PreviewImageCache.load(url)
        XCTAssertNil(loaded, "읽기 실패 → nil(플레이스홀더 표시 경로)")
        XCTAssertNil(PreviewImageCache.cached(url), "실패는 캐시하지 않는다")
    }
}
