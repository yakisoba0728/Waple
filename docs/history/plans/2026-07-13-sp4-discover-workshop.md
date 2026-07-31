# SP4′ 검색(디스커버)·창작마당 탭 네이티브 재구축 — 구현 플랜

> **For agentic workers:** 이 플랜은 단일 서브에이전트가 Task 1→5 순서로 통째 실행한다(사용자 지정 방식 — superpowers:executing-plans 상당). 각 스텝은 체크박스(`- [ ]`)로 추적한다. Task 6(캡처·판정)은 메인 에이전트 몫이므로 실행하지 않는다.

**Goal:** 메인창 검색 탭(플레이스홀더)을 Steam QueryFiles 정렬 4종 가로 레일(디스커버)로, 창작마당 탭(레거시 `WorkshopView`)을 네이티브 그리드 + 무한 스크롤 + 다운로드 진행 UI + 타일 평점으로 재구축한다.

**Architecture:** 백엔드는 전부 재사용(`WorkshopClient`·`SteamCmdDownloader`·`SteamAPIKeyStore`·`DownloadUIState` 상태머신) — 신규 네트워크 코드 없음. `WorkshopViewModel`을 레거시 파일에서 분리해 페이징을 추가하고, 신규 `DiscoverViewModel`이 정렬 4종(트렌드 3·최신 1·구독순 9·투표 0)을 행별로 동시 로드한다. 두 탭은 공용 원격 타일(`RemoteTileView`)·공용 키 게이트(`APIKeyGateView`)·공유 다운로드 상태(단일 `WorkshopViewModel` 인스턴스, `MainWindowView`가 소유)를 쓴다. 레거시 `WorkshopView.swift`는 대체 완료 시 삭제(병행 유지 없음).

**Tech Stack:** SwiftUI(macOS 14+), XCTest. 의존성 추가 없음.

## Global Constraints (전 Task 공통 — 위반 시 판정 탈락)

- **항상 다크**: 창 단위 `darkAqua` 강제는 기존 그대로. 라이트 대응 코드 금지.
- **커스텀 hex 색 금지**: 시맨틱 컬러(`.secondary`·`.tertiary`·`.orange`·`.yellow`·`.red`)·시스템 재질(`.ultraThinMaterial`·`Color(nsColor: .underPageBackgroundColor)`·`.quaternaryLabelColor`)·`accentColor`만.
- **치수는 `Metrics`만**: 신규 명명 치수는 전부 `Sources/Waple/DesignSystem/Metrics.swift`에 추가. 단 기존 뷰들이 쓰는 미세 인라인 패딩 관례(20·6·2 등, `WallpaperGridView` 참조)는 그대로 따른다.
- **WE 자산/로고 복사 금지**. SF Symbols만.
- **macOS 14 floor**: `ContentUnavailableView`, 2-파라미터 `onChange(of:)` 사용 가능(사용할 것 — 구식 1-파라미터는 deprecated 경고).
- **전체 `swift test` 금지**(렌더 GT 수십 분). 개별 필터 실행만: `swift test --filter <클래스명>`.
- **git push 금지**. main 직접 커밋, 메시지 관례 `기능(ui): …`.
- **SourceKit/IDE 진단은 스테일 노이즈** — `swift build` 컴파일러 출력이 정본.
- 파일 이동은 `git mv` + 편집(BSD sed `\b` 미지원 — 텍스트 치환 필요 시 perl, 적용 후 grep으로 실반영 검증).

## 파일 구조 (신규는 SP2′/3′의 `Surfaces/` 관례를 따른다)

| 파일 | 처분 | 책임 |
| --- | --- | --- |
| `Sources/Waple/Surfaces/Workshop/WorkshopViewModel.swift` | 생성(이동+확장) | 검색·페이징·다운로드 상태머신·API 키 상태 |
| `Sources/Waple/Surfaces/Workshop/DiscoverViewModel.swift` | 생성 | 정렬 4종 행 조합·행별 실패 격리 |
| `Sources/Waple/Surfaces/Workshop/RemoteTile.swift` | 생성 | `WorkshopPreview`(이동)·`RemoteTileView`(평점 배지·다운로드 컨트롤) |
| `Sources/Waple/Surfaces/Workshop/APIKeyGateView.swift` | 생성 | 키 미설정 안내(두 탭 공용) |
| `Sources/Waple/Surfaces/Workshop/WorkshopTabView.swift` | 생성 | 창작마당 탭(그리드+무한 스크롤+유틸 스트립) |
| `Sources/Waple/Surfaces/Workshop/DiscoverView.swift` | 생성 | 검색 탭(가로 레일 4행) |
| `Sources/Waple/WorkshopView.swift` | **Task 4에서 삭제** | (레거시 — Task 1~3 동안은 빌드 유지용으로 존치) |
| `Sources/Waple/Shell/MainWindowView.swift` | 수정 | 탭별 툴바 분기·VM 소유·`WAPLE_SMOKE_TAB` |
| `Sources/Waple/DesignSystem/Metrics.swift` | 수정 | SP4′ 치수 5종 추가 |
| `Tests/WapleAppTests/WorkshopPagingTests.swift` | 생성 | 페이징·중복 제거·실패 재시도 |
| `Tests/WapleAppTests/DiscoverViewModelTests.swift` | 생성 | 행 조합·쿼리타입 매핑·실패 격리 |

**의도적 제외(스코프 아웃):** ① "이미 설치됨" 배지 — `WorkshopItem.id`(publishedfileid)와 `LibraryEntry.id`(project.json id)의 일치 보장이 코드상 없어 오표시 위험(원하면 BACKLOG로). ② 디스커버 탭 내 텍스트 검색 — 텍스트 검색은 창작마당 탭 전담(동일 코퍼스에 검색 UI 이중화 방지). ③ 스팀 투표 액션 — 표시만(스펙 기능 매핑 그대로).

---

### Task 1: WorkshopViewModel 분리 + keyProvider 주입 + 무한 스크롤 페이징

**Files:**
- Create: `Sources/Waple/Surfaces/Workshop/WorkshopViewModel.swift`
- Modify: `Sources/Waple/WorkshopView.swift` (클래스 제거 — 뷰·프리뷰는 존치, 빌드 유지)
- Test: `Tests/WapleAppTests/WorkshopPagingTests.swift`

**Interfaces:**
- Consumes: `WorkshopClient.search(apiKey:page:numPerPage:searchText:sort:)`(WorkshopAPI.swift:181-203), `SteamAPIKeyStore.load()/save()`, `SteamCmdDownloader`, `LibraryViewModel.importDownloaded(_:)/setRating(_:for:)/apply(_:)/entries`
- Produces(후속 Task가 의존):
  - `WorkshopViewModel.init(client: WorkshopClient = .live(), library: LibraryViewModel, keyProvider: @escaping () -> String? = { SteamAPIKeyStore.load() })`
  - `@Published private(set) var results: [WorkshopItem]`, `isSearching: Bool`, `isLoadingMore: Bool`, `canLoadMore: Bool`, `hasAPIKey: Bool`, `downloads: [String: DownloadUIState]`
  - `func searchIfNeeded() async`, `search() async`, `loadMore() async`, `download(_:)`, `apply(_:)`, `saveAPIKey()`, `clearAPIKey()`
  - `let pageSize = 30`, `let steamcmdAvailable: Bool`, 중첩 타입 `DownloadUIState`(기존 그대로)

- [ ] **Step 1: 레거시 원본 정독**

`Sources/Waple/WorkshopView.swift` 전체(291줄)를 읽는다. 클래스 `WorkshopViewModel`(8-125행)을 아래에서 이동·확장하고, 뷰(`WorkshopView`)와 `private struct WorkshopPreview`/`WorkshopPreviewCache`는 이 Task에서 건드리지 않는다.

- [ ] **Step 2: 실패하는 테스트 작성**

`Tests/WapleAppTests/WorkshopPagingTests.swift` 생성:

```swift
import XCTest
@testable import Waple
import WapleCore
import WapleLibrary

/// WorkshopViewModel 검색·무한 스크롤 페이징 — 네트워크는 WorkshopClient.transport 주입으로 목킹.
/// (리포 첫 transport-mock 경로 — 이후 async VM 테스트의 준거.)
@MainActor
final class WorkshopPagingTests: XCTestCase {

    /// transport 는 오프메인에서 호출될 수 있으므로 락으로 기록한다.
    private final class URLRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL] = []
        func record(_ u: URL) { lock.lock(); stored.append(u); lock.unlock() }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private final class FailSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var _failing: Bool
        init(_ failing: Bool) { _failing = failing }
        var failing: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _failing }
            set { lock.lock(); _failing = newValue; lock.unlock() }
        }
    }

    private func itemsJSON(ids: ClosedRange<Int>) -> Data {
        let details = ids.map { "{\"publishedfileid\":\"\($0)\",\"title\":\"t\($0)\"}" }
            .joined(separator: ",")
        return Data("{\"response\":{\"publishedfiledetails\":[\(details)]}}".utf8)
    }

    private func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
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

    private func makeVM(transport: @escaping (URL) async throws -> (Data, Int)) -> WorkshopViewModel {
        WorkshopViewModel(client: WorkshopClient(transport: transport),
                          library: makeLibrary(),
                          keyProvider: { "KEY" })
    }

    func testSearchLoadsFirstPageAndArmsLoadMore() async {
        let recorder = URLRecorder()
        let vm = makeVM { url in recorder.record(url); return (self.itemsJSON(ids: 1...30), 200) }
        await vm.search()
        XCTAssertEqual(vm.results.count, 30)
        XCTAssertTrue(vm.canLoadMore, "꽉 찬 페이지(=pageSize) → 다음 페이지 있음")
        XCTAssertEqual(queryValue(recorder.urls[0], "page"), "1")
        XCTAssertEqual(queryValue(recorder.urls[0], "numperpage"), "30")
    }

    func testLoadMoreAppendsNextPageAndDedups() async {
        let recorder = URLRecorder()
        let vm = makeVM { url in
            recorder.record(url)
            let page = self.queryValue(url, "page")
            // 2페이지는 29·30을 중복 포함(스팀 페이징 시프트 재현) — 중복 id 는 버려져야 한다
            return (self.itemsJSON(ids: page == "1" ? 1...30 : 29...58), 200)
        }
        await vm.search()
        await vm.loadMore()
        XCTAssertEqual(queryValue(recorder.urls[1], "page"), "2")
        XCTAssertEqual(vm.results.count, 58, "30 + 30 - 중복 2 = 58 (ForEach id 충돌 방지)")
        XCTAssertEqual(Set(vm.results.map(\.id)).count, 58)
    }

    func testShortPageDisarmsLoadMore() async {
        let recorder = URLRecorder()
        let vm = makeVM { url in
            recorder.record(url)
            return (self.itemsJSON(ids: self.queryValue(url, "page") == "1" ? 1...30 : 31...33), 200)
        }
        await vm.search()
        await vm.loadMore()
        XCTAssertFalse(vm.canLoadMore, "부분 페이지 → 끝")
        await vm.loadMore()
        XCTAssertEqual(recorder.urls.count, 2, "끝난 뒤 loadMore 는 요청을 내지 않는다")
    }

    func testSearchAfterLoadMoreResetsToPageOne() async {
        let recorder = URLRecorder()
        let vm = makeVM { url in recorder.record(url); return (self.itemsJSON(ids: 1...30), 200) }
        await vm.search()
        await vm.loadMore()
        await vm.search()
        XCTAssertEqual(queryValue(recorder.urls[2], "page"), "1", "재검색은 1페이지부터")
        XCTAssertEqual(vm.results.count, 30, "append 아닌 교체")
    }

    func testLoadMoreFailureKeepsPageForRetry() async {
        let recorder = URLRecorder()
        let failing = FailSwitch(true)
        let vm = makeVM { url in
            recorder.record(url)
            if self.queryValue(url, "page") == "2" && failing.failing { throw URLError(.timedOut) }
            return (self.itemsJSON(ids: self.queryValue(url, "page") == "1" ? 1...30 : 31...60), 200)
        }
        await vm.search()
        await vm.loadMore()                       // 실패
        XCTAssertNotNil(vm.statusMessage)
        XCTAssertTrue(vm.canLoadMore, "실패해도 재시도 가능해야 한다")
        failing.failing = false
        await vm.loadMore()                       // 같은 2페이지 재요청 → 성공
        XCTAssertEqual(queryValue(recorder.urls[2], "page"), "2")
        XCTAssertEqual(vm.results.count, 60)
    }

    func testSearchIfNeededRunsOnceAndSkipsWithoutKey() async {
        let recorder = URLRecorder()
        let vm = makeVM { url in recorder.record(url); return (self.itemsJSON(ids: 1...30), 200) }
        await vm.searchIfNeeded()
        await vm.searchIfNeeded()
        XCTAssertEqual(recorder.urls.count, 1, "탭 재진입은 재요청하지 않는다")

        let keyless = WorkshopViewModel(client: WorkshopClient(transport: { _ in (Data(), 200) }),
                                        library: makeLibrary(), keyProvider: { nil })
        XCTAssertFalse(keyless.hasAPIKey)
        await keyless.searchIfNeeded()
        XCTAssertTrue(keyless.results.isEmpty, "키 없으면 요청 자체를 내지 않는다")
    }
}
```

- [ ] **Step 3: 실패 확인**

Run: `swift test --filter WorkshopPagingTests 2>&1 | tail -8`
Expected: **컴파일 실패** — `WorkshopViewModel`에 `keyProvider:` 파라미터·`loadMore`·`canLoadMore`가 없음.

- [ ] **Step 4: VM 이동 + 확장 구현**

`Sources/Waple/Surfaces/Workshop/WorkshopViewModel.swift` 생성(레거시 8-125행을 기반으로 이동 — 다운로드 3함수 `download`/`applyProgress`/`finishDownload`/`apply`와 `DownloadUIState`는 **한 글자도 바꾸지 않고** 그대로 복사):

```swift
import SwiftUI
import WapleLibrary

// Steam 워크샵 검색·페이징·다운로드 상태머신. 순수 로직(WorkshopAPI/SteamCmdDownloader)을 얇게 배선한다.
// @MainActor — async 클라이언트/다운로더 콜백이 오프메인에서 재개되므로 @Published 변경을 전부 메인으로 모은다.
// keyProvider — Keychain(SteamAPIKeyStore) 직독을 주입으로 바꿔 네트워크리스 테스트를 가능하게 한다.
@MainActor
final class WorkshopViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var sort: WorkshopSort = .subscriptions
    @Published private(set) var results: [WorkshopItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var canLoadMore = false
    @Published var statusMessage: String?
    @Published private(set) var hasAPIKey: Bool
    @Published var apiKeyInput = ""
    @Published var usernameInput: String
    @Published private(set) var downloads: [String: DownloadUIState] = [:]

    let steamcmdAvailable = SteamCmdDownloader.isAvailable
    let pageSize = 30

    private let client: WorkshopClient
    private let library: LibraryViewModel
    private let keyProvider: () -> String?
    private var page = 1
    private var attemptedInitialLoad = false

    struct DownloadUIState: Equatable {
        enum Phase: Equatable {
            case downloading(Double?), verifying, committing, importing, done, failed
        }
        var phase: Phase
        var entryId: String?   // 임포트된 라이브러리 엔트리 id(적용용)
    }

    init(client: WorkshopClient = .live(), library: LibraryViewModel,
         keyProvider: @escaping () -> String? = { SteamAPIKeyStore.load() }) {
        self.client = client
        self.library = library
        self.keyProvider = keyProvider
        self.hasAPIKey = keyProvider() != nil
        self.usernameInput = SteamCmdDownloader.username
    }

    // MARK: - API 키

    func saveAPIKey() {
        SteamAPIKeyStore.save(apiKeyInput)
        hasAPIKey = keyProvider() != nil
        if hasAPIKey {
            apiKeyInput = ""
            statusMessage = nil
        } else {
            statusMessage = "API 키를 저장하지 못했습니다."
        }
    }

    func clearAPIKey() {
        SteamAPIKeyStore.save("")
        hasAPIKey = false
        results = []
        canLoadMore = false
        attemptedInitialLoad = false
    }

    // MARK: - 검색·페이징

    /// 탭 첫 진입 시 기본 목록(빈 검색 + 현재 정렬) 자동 로드 — 재진입에는 재요청하지 않는다.
    func searchIfNeeded() async {
        guard hasAPIKey, !attemptedInitialLoad else { return }
        await search()
    }

    func search() async {
        guard let key = keyProvider() else { hasAPIKey = false; return }
        attemptedInitialLoad = true
        isSearching = true
        statusMessage = nil
        page = 1
        canLoadMore = false
        defer { isSearching = false }
        do {
            results = try await client.search(apiKey: key, page: page, numPerPage: pageSize,
                                              searchText: searchText, sort: sort)
            canLoadMore = results.count == pageSize
            if results.isEmpty { statusMessage = "결과가 없습니다." }
        } catch {
            results = []
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "검색 실패: \(error.localizedDescription)"
        }
    }

    /// 그리드 마지막 타일 onAppear 에서 호출 — 다음 페이지를 append(중복 id 는 버린다: ForEach id 충돌 방지).
    func loadMore() async {
        guard canLoadMore, !isLoadingMore, !isSearching, let key = keyProvider() else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        page += 1
        do {
            let batch = try await client.search(apiKey: key, page: page, numPerPage: pageSize,
                                                searchText: searchText, sort: sort)
            let known = Set(results.map(\.id))
            results.append(contentsOf: batch.filter { !known.contains($0.id) })
            canLoadMore = batch.count == pageSize
        } catch {
            page -= 1   // 다음 loadMore 가 같은 페이지를 재시도
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "더 불러오기 실패: \(error.localizedDescription)"
        }
    }

    // MARK: - 다운로드 → 임포트 → 적용 (레거시 그대로 이동)

    func download(_ item: WorkshopItem) {
        guard steamcmdAvailable else {
            statusMessage = "steamcmd 가 필요합니다: brew install steamcmd"; return
        }
        let username = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            statusMessage = "steamcmd 로그인 계정(username)을 먼저 입력하세요."; return
        }
        SteamCmdDownloader.username = username
        downloads[item.id] = DownloadUIState(phase: .downloading(nil), entryId: nil)
        SteamCmdDownloader.download(
            itemId: item.id, username: username,
            progress: { [weak self] p in Task { @MainActor in self?.applyProgress(item.id, p) } },
            completion: { [weak self] url in Task { @MainActor in self?.finishDownload(item, url) } }
        )
    }

    private func applyProgress(_ id: String, _ p: SteamCmdDownloader.Progress) {
        guard var state = downloads[id], state.phase != .done else { return }
        switch p {
        case .downloading(let v): state.phase = .downloading(v)
        case .verifying: state.phase = .verifying
        case .committing: state.phase = .committing
        case .success: state.phase = .importing
        case .failed: state.phase = .failed
        }
        downloads[id] = state
    }

    private func finishDownload(_ item: WorkshopItem, _ url: URL?) {
        guard let url else {
            downloads[item.id] = DownloadUIState(phase: .failed, entryId: nil)
            statusMessage = "‘\(item.title)’ 다운로드 실패 — 터미널에서 `steamcmd +login \(usernameInput)` 로 1회 로그인해 세션을 캐시했는지 확인하세요."
            return
        }
        guard let entry = library.importDownloaded(url) else {
            downloads[item.id] = DownloadUIState(phase: .failed, entryId: nil)
            return
        }
        if let score = item.voteScore { library.setRating(score, for: entry) }
        downloads[item.id] = DownloadUIState(phase: .done, entryId: entry.id)
    }

    func apply(_ item: WorkshopItem) {
        guard let entryId = downloads[item.id]?.entryId,
              let entry = library.entries.first(where: { $0.id == entryId }) else { return }
        _ = library.apply(entry)
    }
}
```

`Sources/Waple/WorkshopView.swift`에서 클래스 `WorkshopViewModel`(8-125행, 파일 상단 주석 2줄 포함)을 **삭제**한다. 뷰·`WorkshopPreview`·`WorkshopPreviewCache`·import 는 그대로 둔다(레거시 뷰는 이동된 VM을 같은 모듈에서 그대로 소비 — Task 4에서 파일째 삭제).

- [ ] **Step 5: 테스트·빌드 통과 확인**

Run: `swift test --filter WorkshopPagingTests 2>&1 | tail -8` → Expected: `Executed 6 tests, with 0 failures`
Run: `swift build 2>&1 | tail -3` → Expected: `Build complete!`
주의: `WorkshopClient(transport:)` 멤버와이즈 init 이 없다고 나오면 WorkshopAPI.swift 의 `WorkshopClient` 선언을 확인하고 테스트 헬퍼를 실제 init 시그니처에 맞춘다(구조 변경 금지).

- [ ] **Step 6: 기존 워크샵 테스트 회귀 확인**

Run: `swift test --filter WorkshopAPITests 2>&1 | tail -4` → Expected: 0 failures

- [ ] **Step 7: Commit**

```bash
git add Sources/Waple/Surfaces/Workshop/WorkshopViewModel.swift Sources/Waple/WorkshopView.swift Tests/WapleAppTests/WorkshopPagingTests.swift
git commit -m "기능(ui): 워크샵 VM 분리 — keyProvider 주입·무한 스크롤 페이징(중복 제거·실패 재시도)"
```

---

### Task 2: DiscoverViewModel — 정렬 4종 행 조합

**Files:**
- Create: `Sources/Waple/Surfaces/Workshop/DiscoverViewModel.swift`
- Test: `Tests/WapleAppTests/DiscoverViewModelTests.swift`

**Interfaces:**
- Consumes: `WorkshopClient.search(apiKey:page:numPerPage:searchText:sort:)`, `WorkshopSort`(trend=3·latest=1·subscriptions=9·votes=0), `SteamAPIKeyStore.load()`
- Produces(후속 Task가 의존):
  - `DiscoverViewModel.init(client: WorkshopClient = .live(), keyProvider: @escaping () -> String? = { SteamAPIKeyStore.load() })`
  - `@Published private(set) var rows: [Row]` — `Row { sort: WorkshopSort, state: RowState, title: String, id: Int }`, `RowState { loading, loaded([WorkshopItem]), failed(String) }`
  - `func loadIfNeeded() async`, `func reload(_ sort: WorkshopSort) async`
  - `static let rowSorts: [WorkshopSort] = [.trend, .latest, .subscriptions, .votes]`, `static let rowItemCount = 12`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/WapleAppTests/DiscoverViewModelTests.swift` 생성:

```swift
import XCTest
@testable import Waple

/// 디스커버 행 조합 — 정렬 4종이 각자 올바른 query_type 으로 나가고, 행 실패가 서로 격리되는지.
@MainActor
final class DiscoverViewModelTests: XCTestCase {

    private final class URLRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL] = []
        func record(_ u: URL) { lock.lock(); stored.append(u); lock.unlock() }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private final class FailSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var _failing = true
        var failing: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _failing }
            set { lock.lock(); _failing = newValue; lock.unlock() }
        }
    }

    private func itemsJSON(count: Int) -> Data {
        let details = (1...count).map { "{\"publishedfileid\":\"\($0)\",\"title\":\"t\($0)\"}" }
            .joined(separator: ",")
        return Data("{\"response\":{\"publishedfiledetails\":[\(details)]}}".utf8)
    }

    private func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    func testLoadPopulatesAllRowsWithSortSpecificQueries() async {
        let recorder = URLRecorder()
        let vm = DiscoverViewModel(client: WorkshopClient(transport: { url in
            recorder.record(url); return (self.itemsJSON(count: 2), 200)
        }), keyProvider: { "KEY" })

        await vm.loadIfNeeded()

        XCTAssertEqual(vm.rows.map(\.sort), [.trend, .latest, .subscriptions, .votes], "행 순서 고정")
        for row in vm.rows {
            guard case .loaded(let items) = row.state else {
                return XCTFail("\(row.sort) 행이 로드되지 않음: \(row.state)")
            }
            XCTAssertEqual(items.count, 2)
        }
        XCTAssertEqual(Set(recorder.urls.compactMap { queryValue($0, "query_type") }),
                       ["3", "1", "9", "0"], "트렌드3·최신1·구독순9·투표0")
        for url in recorder.urls {
            XCTAssertEqual(queryValue(url, "numperpage"), "12")
            XCTAssertEqual(queryValue(url, "page"), "1")
            XCTAssertEqual(queryValue(url, "search_text"), "", "빈 검색이어야 query_type 이 정렬값이 된다")
        }
    }

    func testRowFailureIsIsolatedAndRetryRecovers() async {
        let failing = FailSwitch()
        let vm = DiscoverViewModel(client: WorkshopClient(transport: { url in
            if self.queryValue(url, "query_type") == "1" && failing.failing { throw URLError(.timedOut) }
            return (self.itemsJSON(count: 2), 200)
        }), keyProvider: { "KEY" })

        await vm.loadIfNeeded()

        for row in vm.rows {
            if row.sort == .latest {
                guard case .failed = row.state else { return XCTFail("최신 행은 실패여야 함") }
            } else {
                guard case .loaded = row.state else { return XCTFail("\(row.sort) 행은 격리돼 성공해야 함") }
            }
        }

        failing.failing = false
        await vm.reload(.latest)
        guard case .loaded(let items) = vm.rows[1].state else { return XCTFail("재시도 후 로드돼야 함") }
        XCTAssertEqual(items.count, 2)
    }

    func testLoadIfNeededRunsOnce() async {
        let recorder = URLRecorder()
        let vm = DiscoverViewModel(client: WorkshopClient(transport: { url in
            recorder.record(url); return (self.itemsJSON(count: 1), 200)
        }), keyProvider: { "KEY" })
        await vm.loadIfNeeded()
        await vm.loadIfNeeded()
        XCTAssertEqual(recorder.urls.count, 4, "탭 재진입에 재요청하지 않는다")
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter DiscoverViewModelTests 2>&1 | tail -6`
Expected: **컴파일 실패** — `DiscoverViewModel` 미존재.

- [ ] **Step 3: 구현**

`Sources/Waple/Surfaces/Workshop/DiscoverViewModel.swift` 생성:

```swift
import SwiftUI

/// 검색(디스커버) 탭 — Steam QueryFiles 정렬 4종을 가로 레일 행으로 조합한다. 신규 네트워크 코드 없음
/// (WorkshopClient 재사용, 스펙 §디스커버). 행별 로드는 동시에, 실패는 행 단위로 격리한다.
@MainActor
final class DiscoverViewModel: ObservableObject {
    enum RowState: Equatable {
        case loading
        case loaded([WorkshopItem])
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        let sort: WorkshopSort
        var state: RowState = .loading
        var id: Int { sort.rawValue }
        var title: String {
            switch sort {
            case .trend: return "인기 급상승"
            case .latest: return "최신 등록"
            case .subscriptions: return "구독 순"
            case .votes: return "평점 순"
            }
        }
    }

    static let rowSorts: [WorkshopSort] = [.trend, .latest, .subscriptions, .votes]
    static let rowItemCount = 12

    @Published private(set) var rows: [Row] = DiscoverViewModel.rowSorts.map { Row(sort: $0) }

    private let client: WorkshopClient
    private let keyProvider: () -> String?
    private var attemptedLoad = false

    init(client: WorkshopClient = .live(),
         keyProvider: @escaping () -> String? = { SteamAPIKeyStore.load() }) {
        self.client = client
        self.keyProvider = keyProvider
    }

    /// 탭 진입 시 1회 로드(키 게이트 통과 후 호출된다). 4행 동시 — 행이 끝나는 대로 개별 갱신.
    func loadIfNeeded() async {
        guard !attemptedLoad else { return }
        attemptedLoad = true
        await withTaskGroup(of: Void.self) { group in
            for index in rows.indices {
                group.addTask { @MainActor in await self.loadRow(at: index) }
            }
        }
    }

    /// 실패 행 재시도.
    func reload(_ sort: WorkshopSort) async {
        guard let index = rows.firstIndex(where: { $0.sort == sort }) else { return }
        rows[index].state = .loading
        await loadRow(at: index)
    }

    private func loadRow(at index: Int) async {
        guard let key = keyProvider() else {
            rows[index].state = .failed("Steam Web API 키가 필요합니다.")
            return
        }
        do {
            let items = try await client.search(apiKey: key, page: 1, numPerPage: Self.rowItemCount,
                                                searchText: "", sort: rows[index].sort)
            rows[index].state = .loaded(items)
        } catch {
            rows[index].state = .failed((error as? LocalizedError)?.errorDescription
                                        ?? error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter DiscoverViewModelTests 2>&1 | tail -6` → Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Waple/Surfaces/Workshop/DiscoverViewModel.swift Tests/WapleAppTests/DiscoverViewModelTests.swift
git commit -m "기능(ui): 디스커버 행 조합 ViewModel — 정렬 4종 동시 로드·행별 실패 격리"
```

---

### Task 3: 공용 컴포넌트 — RemoteTileView·WorkshopPreview 이동·APIKeyGateView + Metrics

**Files:**
- Create: `Sources/Waple/Surfaces/Workshop/RemoteTile.swift`
- Create: `Sources/Waple/Surfaces/Workshop/APIKeyGateView.swift`
- Modify: `Sources/Waple/WorkshopView.swift` (`private struct WorkshopPreview`·`private enum WorkshopPreviewCache` 127-157행 **삭제** — 같은 모듈의 internal 이동본과 이름 충돌 방지)
- Modify: `Sources/Waple/DesignSystem/Metrics.swift`

**Interfaces:**
- Consumes: `WorkshopItem`, `WorkshopViewModel.DownloadUIState`(Task 1), `Metrics`
- Produces(후속 Task가 의존):
  - `struct WorkshopPreview: View { let url: URL? }` (internal)
  - `struct RemoteTileView: View` — `init(item: WorkshopItem, download: WorkshopViewModel.DownloadUIState?, steamcmdAvailable: Bool, onDownload: @escaping () -> Void, onApply: @escaping () -> Void)` (멤버와이즈)
  - `struct APIKeyGateView: View { @ObservedObject var vm: WorkshopViewModel }`
  - `Metrics.searchFieldWidth/usernameFieldWidth/downloadBarWidth/keyGateFieldWidth/keyGateTextWidth`

- [ ] **Step 1: Metrics 추가**

`Sources/Waple/DesignSystem/Metrics.swift`의 `// 공통 간격` 블록 앞에 추가:

```swift
    // 검색·창작마당 탭 (SP4′)
    static let searchFieldWidth: CGFloat = 190     // 툴바 검색 필드(설치됨 탭 기존 하드코딩 190 승격)
    static let usernameFieldWidth: CGFloat = 180
    static let downloadBarWidth: CGFloat = 90
    static let keyGateFieldWidth: CGFloat = 320
    static let keyGateTextWidth: CGFloat = 420
```

- [ ] **Step 2: RemoteTile.swift 생성**

```swift
import SwiftUI
import AppKit

// MARK: - 원격 프리뷰(URLSession 비동기 로드 + NSCache — 셀 재활용 시 재다운로드 방지)
// 레거시 WorkshopView 에서 이동, 디스커버·창작마당 공용이라 internal 로 승격.

enum WorkshopPreviewCache {
    static let cache = NSCache<NSURL, NSImage>()
}

struct WorkshopPreview: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        image = nil
        guard let url else { return }
        if let cached = WorkshopPreviewCache.cache.object(forKey: url as NSURL) { image = cached; return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = NSImage(data: data) else { return }
        WorkshopPreviewCache.cache.setObject(img, forKey: url as NSURL)
        image = img
    }
}

// MARK: - 원격 타일(디스커버 레일·창작마당 그리드 공용)
// 설치됨 타일(WallpaperGridView.tile)과 같은 문법: 라운드 썸네일 + 제목 아래 + 호버 리프트.
// 폭은 소비자가 정한다 — 그리드는 셀에 맞춰 늘어나고, 레일은 .frame(width: Metrics.tileWidth) 고정.

struct RemoteTileView: View {
    let item: WorkshopItem
    let download: WorkshopViewModel.DownloadUIState?
    let steamcmdAvailable: Bool
    var onDownload: () -> Void
    var onApply: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumb
            Text(item.title)
                .font(.caption)
                .foregroundStyle(hovered ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 2)
            HStack(spacing: 4) {
                if let subs = item.subscriptions {
                    Label(subs.formatted(), systemImage: "person.2")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .help("구독 \(subs.formatted())")
                }
                Spacer(minLength: 4)
                control
            }
            .padding(.horizontal, 2)
        }
        .scaleEffect(hovered ? 1.02 : 1)
        .shadow(color: .black.opacity(hovered ? 0.45 : 0), radius: 9, y: 5)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovered)
        .onHover { hovered = $0 }
    }

    private var thumb: some View {
        WorkshopPreview(url: item.previewURL)
            .frame(height: Metrics.tileThumbHeight)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: Metrics.tileCorner))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.tileCorner)
                    .stroke(hovered ? Color.secondary.opacity(0.6) : .clear, lineWidth: 1.5)
            )
            .overlay(alignment: .topTrailing) {
                if let score = item.voteScore { ratingBadge(score) }
            }
    }

    /// 스팀 투표 점수(0~1)를 별 5점 환산 표시 — 표시만, 투표 액션 없음(스펙 기능 매핑).
    private func ratingBadge(_ score: Double) -> some View {
        Label(String(format: "%.1f", score * 5), systemImage: "star.fill")
            .font(.caption2)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.yellow)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(6)
            .help(String(format: "평점 %.1f/5", score * 5))
    }

    @ViewBuilder
    private var control: some View {
        switch download?.phase {
        case nil:
            Button("다운로드", action: onDownload)
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!steamcmdAvailable)
                .help(steamcmdAvailable ? "steamcmd 로 다운로드해 라이브러리에 추가"
                                        : "steamcmd 가 필요합니다: brew install steamcmd")
        case .downloading(let v):
            if let v {
                ProgressView(value: v, total: 100)
                    .frame(width: Metrics.downloadBarWidth)
                    .help("다운로드 중 \(Int(v))%")
            } else {
                stage("다운로드 중")
            }
        case .verifying: stage("검증 중")
        case .committing: stage("설치 중")
        case .importing: stage("가져오는 중")
        case .done:
            Button("적용", action: onApply)
                .buttonStyle(.borderedProminent).controlSize(.small)
        case .failed:
            Button("다시 시도", action: onDownload)
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func stage(_ label: String) -> some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.small)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 3: APIKeyGateView.swift 생성**

```swift
import SwiftUI

/// Steam Web API 키 미설정 안내 — 검색·창작마당 탭 공용 게이트. 키는 Keychain(SteamAPIKeyStore)에만 저장.
struct APIKeyGateView: View {
    @ObservedObject var vm: WorkshopViewModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.fill").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("Steam Web API 키가 필요합니다").font(.title3.weight(.semibold))
            Text("워크샵을 검색하려면 본인 발급 API 키가 필요합니다. 아래에서 발급 후 붙여넣으세요. 키는 Keychain 에만 저장됩니다.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Metrics.keyGateTextWidth)
            Link("API 키 발급: steamcommunity.com/dev/apikey",
                 destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
            SecureField("API 키 붙여넣기", text: $vm.apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: Metrics.keyGateFieldWidth)
                .onSubmit { vm.saveAPIKey() }
            Button("저장") { vm.saveAPIKey() }
                .buttonStyle(.borderedProminent)
                .disabled(vm.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let message = vm.statusMessage {
                Text(message).foregroundStyle(.red).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
```

- [ ] **Step 4: 레거시에서 프리뷰 제거**

`Sources/Waple/WorkshopView.swift`의 127-157행 구획(`// MARK: - 프리뷰 이미지…` 주석부터 `WorkshopPreviewCache`·`WorkshopPreview` 정의 끝까지)을 삭제한다. 레거시 뷰의 `WorkshopPreview(url:)` 사용처는 그대로 — 이동된 internal 본을 쓴다. **같은 모듈에 동명 타입이 남으면 모호성 컴파일 에러가 나므로 이 삭제는 이 Task 안에서 반드시 함께 간다.**

- [ ] **Step 5: 빌드 확인**

Run: `swift build 2>&1 | tail -3` → Expected: `Build complete!` (뷰 전용 Task — 단위 테스트 없음, 표면 검증은 캡처 게이트)

- [ ] **Step 6: Commit**

```bash
git add Sources/Waple/Surfaces/Workshop/RemoteTile.swift Sources/Waple/Surfaces/Workshop/APIKeyGateView.swift Sources/Waple/WorkshopView.swift Sources/Waple/DesignSystem/Metrics.swift
git commit -m "기능(ui): 원격 타일·API 키 게이트 공용 컴포넌트 — 프리뷰 로더 이동·평점 배지·SP4′ Metrics"
```

---

### Task 4: WorkshopTabView + 셸 배선 + 레거시 삭제

**Files:**
- Create: `Sources/Waple/Surfaces/Workshop/WorkshopTabView.swift`
- Modify: `Sources/Waple/Shell/MainWindowView.swift` (전면 — 아래 전체 코드로 교체)
- Delete: `Sources/Waple/WorkshopView.swift`

**Interfaces:**
- Consumes: Task 1 `WorkshopViewModel`(searchIfNeeded/search/loadMore/downloads/…), Task 2 `DiscoverViewModel`, Task 3 `RemoteTileView`/`APIKeyGateView`, `Metrics.searchFieldWidth` 등
- Produces: `WorkshopTabView(vm:)`, `MainWindowView`가 `workshopVM`·`discoverVM`을 `@StateObject`로 소유(탭 전환에도 결과·다운로드 상태 유지), `WAPLE_SMOKE_TAB` env(값 `discover`|`workshop` = `MainTab.rawValue`)

- [ ] **Step 1: WorkshopTabView.swift 생성**

```swift
import SwiftUI
import AppKit

/// 창작마당 탭 — 네이티브 그리드 + 무한 스크롤. 검색 필드·정렬 메뉴는 셸 툴바가 담당한다(MainWindowView).
struct WorkshopTabView: View {
    @ObservedObject var vm: WorkshopViewModel

    private let columns = [GridItem(.adaptive(minimum: Metrics.tileWidth), spacing: Metrics.gridSpacing)]

    var body: some View {
        Group {
            if vm.hasAPIKey { browser } else { APIKeyGateView(vm: vm) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .task { await vm.searchIfNeeded() }
        .onChange(of: vm.sort) { _, _ in Task { await vm.search() } }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            utilityStrip
            if let message = vm.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }
            if vm.isSearching && vm.results.isEmpty {
                Spacer()
                ProgressView("검색 중…")
                Spacer()
            } else if vm.results.isEmpty {
                ContentUnavailableView("결과 없음", systemImage: "magnifyingglass",
                                       description: Text("툴바 검색창에 검색어를 입력하거나 정렬을 바꿔보세요."))
            } else {
                grid
            }
        }
    }

    /// steamcmd 상태 + 다운로드 계정 — 다운로드 전제조건이라 탭 안에 상시 노출(캡션 크기로 절제).
    private var utilityStrip: some View {
        HStack(spacing: Metrics.gap) {
            if !vm.steamcmdAvailable {
                Label("steamcmd 미설치 — `brew install steamcmd` 후 다시 실행", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Text("steamcmd 계정").font(.caption).foregroundStyle(.secondary)
            TextField("username", text: $vm.usernameInput)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .frame(width: Metrics.usernameFieldWidth)
                .help("다운로드용 Steam 계정. 최초 1회 터미널에서 `steamcmd +login <계정>` 으로 로그인해 세션을 캐시하세요 — 비밀번호는 앱이 저장하지 않습니다.")
            Button("API 키 변경") { vm.clearAPIKey() }
                .controlSize(.small)
                .help("Keychain 의 Steam Web API 키를 지우고 다시 입력")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, Metrics.gap)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Metrics.gridSpacing + 6) {
                ForEach(vm.results) { item in
                    RemoteTileView(item: item,
                                   download: vm.downloads[item.id],
                                   steamcmdAvailable: vm.steamcmdAvailable,
                                   onDownload: { vm.download(item) },
                                   onApply: { vm.apply(item) })
                        .onAppear {
                            if item.id == vm.results.last?.id { Task { await vm.loadMore() } }
                        }
                }
            }
            .padding(20)
            if vm.isLoadingMore {
                ProgressView().controlSize(.small).padding(.bottom, 16)
            }
        }
    }
}
```

- [ ] **Step 2: MainWindowView.swift 전면 교체**

파일 전체를 아래로 교체(변경점: `WAPLE_SMOKE_TAB` 초기 탭 · 명시 init + `@StateObject` VM 2종 소유 · 툴바 탭별 switch · 패널 토글 설치됨 전용 · 검색폭 Metrics 승격 · discover/workshop 콘텐츠 배선):

```swift
import SwiftUI
import AppKit
import WapleCore
import WapleLibrary

enum MainTab: String, CaseIterable, Identifiable {
    case installed, discover, workshop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .installed: return "설치됨"; case .discover: return "검색"; case .workshop: return "창작마당"
        }
    }
}

/// 네이티브 메인창: 통합 툴바(탭 세그먼트·탭별 검색/정렬·패널 토글) + 콘텐츠 + Now Playing 바.
/// WE는 배치 참고만 — 컨트롤·색·재질은 전부 시스템(스펙 2026-07-12 네이티브 재설계).
struct MainWindowView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var banner: StatusBannerModel
    var screenFrames: () -> [CGRect]
    // 워크샵/디스커버 VM 은 창이 소유 — 탭을 오가도 결과·다운로드 진행 상태가 유지된다.
    @StateObject private var workshopVM: WorkshopViewModel
    @StateObject private var discoverVM = DiscoverViewModel()
    // WAPLE_SMOKE_TAB=discover|workshop — 캡처용 초기 탭 강제(스모크 규약, MainTab.rawValue)
    @State private var tab: MainTab =
        ProcessInfo.processInfo.environment["WAPLE_SMOKE_TAB"].flatMap(MainTab.init(rawValue:)) ?? .installed
    @State private var showDisplays = ProcessInfo.processInfo.environment["WAPLE_SMOKE_DISPLAYS"] != nil
    @State private var showFilters = ProcessInfo.processInfo.environment["WAPLE_SMOKE"] != nil  // 스모크 캡처용 기본 노출
    @State private var panelVisible = true

    init(viewModel: LibraryViewModel, banner: StatusBannerModel, screenFrames: @escaping () -> [CGRect]) {
        self.viewModel = viewModel
        self.banner = banner
        self.screenFrames = screenFrames
        _workshopVM = StateObject(wrappedValue: WorkshopViewModel(library: viewModel))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            NowPlayingBar(viewModel: viewModel)
        }
        .frame(minWidth: Metrics.windowMin.width, minHeight: Metrics.windowMin.height)
        .overlay(alignment: .top) { StatusBanner(model: banner) }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showDisplays) {
            DisplaysView(viewModel: viewModel, screenFrames: screenFrames)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("보기", selection: $tab) {
                ForEach(MainTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItemGroup {
            switch tab {
            case .installed:
                TextField("검색", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Metrics.searchFieldWidth)
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showFilters.toggle() } } label: {
                    Label("필터", systemImage: viewModel.criteria.isActive
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .help("필터 사이드바")
                Picker("정렬", selection: $viewModel.sortOrder) {
                    ForEach(LibrarySortOrder.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .help("정렬")
            case .workshop:
                TextField("워크샵 검색", text: $workshopVM.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Metrics.searchFieldWidth)
                    .onSubmit { Task { await workshopVM.search() } }
                    .disabled(!workshopVM.hasAPIKey)
                Picker("정렬", selection: $workshopVM.sort) {
                    ForEach(WorkshopSort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(!workshopVM.hasAPIKey)
                .help("정렬")
            case .discover:
                EmptyView()   // 디스커버는 큐레이션 레일 — 텍스트 검색은 창작마당 탭 전담
            }
            Button {} label: { Label("모바일", systemImage: "iphone") }
                .disabled(true)
                .help("모바일 페어링은 지원하지 않습니다")
            Button { showDisplays = true } label: { Label("디스플레이", systemImage: "display") }
                .help("모니터별 배경 할당")
            Button {} label: { Label("설정", systemImage: "gearshape") }
                .disabled(true)
                .help("설정 창은 곧 제공됩니다(SP5′)")
            if tab == .installed {
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { panelVisible.toggle() } } label: {
                    Label("정보 패널", systemImage: "sidebar.trailing")
                }
                .help(panelVisible ? "정보 패널 숨기기" : "정보 패널 보기")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .installed:
            HStack(spacing: 0) {
                if showFilters {
                    FilterSidebarView(viewModel: viewModel)
                        .transition(.move(edge: .leading))
                    Divider()
                }
                WallpaperGridView(viewModel: viewModel)
                if panelVisible {
                    Divider()
                    SelectionPanelView(viewModel: viewModel)
                        .transition(.move(edge: .trailing))
                }
            }
        case .discover:
            DiscoverView(vm: discoverVM, workshopVM: workshopVM)
        case .workshop:
            WorkshopTabView(vm: workshopVM)
        }
    }
}
```

주의: 이 시점에 `DiscoverView`가 아직 없으므로 **빌드가 깨진다** — Step 3에서 임시 스텁 없이 곧장 Task 5의 `DiscoverView`를 만들지 말고, 이 Task 안에서는 `case .discover:`를 잠시 `Text("")`로 두지 **말 것**. 대신 Task 4와 Task 5를 아래 순서로 커밋한다: Step 3(레거시 삭제)까지 작업 후 빌드가 `DiscoverView` 미존재로만 실패하는 것을 확인하고, **Task 5의 DiscoverView.swift를 먼저 생성**한 다음 두 Task를 각자의 커밋으로 나눠 커밋한다(커밋 순서: Task 4 파일들 → Task 5 파일). git 커밋은 파일 단위 스테이징이므로 가능하다. 단, **Task 4 커밋에 MainWindowView.swift를 포함하면 그 커밋 시점 트리가 빌드 불가**가 되므로, MainWindowView.swift와 DiscoverView.swift는 **Task 5 커밋에 함께** 넣는다(Task 4 커밋 = WorkshopTabView 생성 + WorkshopView.swift 삭제 + 이 시점 트리는 아직 구 MainWindowView… 그런데 구 MainWindowView가 삭제된 WorkshopView를 참조하면 그것도 깨진다).

**→ 결론(단순화): Task 4와 Task 5는 파일을 전부 만든 뒤 하나의 커밋으로 합친다.** 커밋 분리보다 "모든 커밋은 빌드 그린" 원칙이 우선이다. 아래 Task 5까지 마친 뒤 Step 4로 진행.

- [ ] **Step 3: 레거시 삭제**

```bash
git rm Sources/Waple/WorkshopView.swift
```

- [ ] **Step 4: (Task 5 완료 후) 빌드·전 스위트 확인 — Task 5의 Step 2로 이동**

---

### Task 5: DiscoverView — 정렬 4종 가로 레일 (+ Task 4와 합동 커밋)

**Files:**
- Create: `Sources/Waple/Surfaces/Workshop/DiscoverView.swift`

**Interfaces:**
- Consumes: `DiscoverViewModel`(rows/loadIfNeeded/reload), `WorkshopViewModel`(hasAPIKey/downloads/download/apply/statusMessage/steamcmdAvailable), `RemoteTileView`, `APIKeyGateView`, `Metrics`
- Produces: `DiscoverView(vm:workshopVM:)` — MainWindowView `case .discover`가 소비

- [ ] **Step 1: DiscoverView.swift 생성**

```swift
import SwiftUI
import AppKit

/// 검색(디스커버) 탭 — 정렬 4종 가로 레일. 키 게이트·다운로드 상태는 워크샵 VM 을 공유한다
/// (다운로드가 어느 탭에서 시작됐든 같은 진행 상태가 보인다).
struct DiscoverView: View {
    @ObservedObject var vm: DiscoverViewModel
    @ObservedObject var workshopVM: WorkshopViewModel

    var body: some View {
        Group {
            if workshopVM.hasAPIKey { rails } else { APIKeyGateView(vm: workshopVM) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .task(id: workshopVM.hasAPIKey) {
            if workshopVM.hasAPIKey { await vm.loadIfNeeded() }
        }
    }

    private var rails: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.gridSpacing + 6) {
                if let message = workshopVM.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }
                ForEach(vm.rows) { row in section(row) }
            }
            .padding(.vertical, 20)
        }
    }

    @ViewBuilder
    private func section(_ row: DiscoverViewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Text(row.title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
            switch row.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: Metrics.tileThumbHeight)
            case .failed(let message):
                HStack(spacing: Metrics.gap) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Button("다시 시도") { Task { await vm.reload(row.sort) } }
                        .controlSize(.small)
                }
                .padding(.horizontal, 20)
            case .loaded(let items):
                if items.isEmpty {
                    Text("항목이 없습니다").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: Metrics.gridSpacing) {
                            ForEach(items) { item in
                                RemoteTileView(item: item,
                                               download: workshopVM.downloads[item.id],
                                               steamcmdAvailable: workshopVM.steamcmdAvailable,
                                               onDownload: { workshopVM.download(item) },
                                               onApply: { workshopVM.apply(item) })
                                    .frame(width: Metrics.tileWidth)   // 레일은 고정폭 타일
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, Metrics.gap)   // 호버 리프트 그림자 클리핑 여유
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: 빌드 + 3스위트 확인 (Task 4 몫 포함)**

Run: `swift build 2>&1 | tail -3` → Expected: `Build complete!`
Run: `swift test --filter WapleAppTests 2>&1 | tail -4` → Expected: 0 failures (기존 131 + 신규 9)
Run: `swift test --filter WapleLibraryTests 2>&1 | tail -4` → Expected: 0 failures
Run: `swift test --filter WapleCoreTests 2>&1 | tail -4` → Expected: 0 failures
그리고 레거시 참조 잔재 검증: `grep -rn "WorkshopView(" Sources/ | grep -v WorkshopTabView` → 출력 없음이어야 한다.

- [ ] **Step 3: 합동 Commit (Task 4 + 5)**

```bash
git add Sources/Waple/Surfaces/Workshop/WorkshopTabView.swift Sources/Waple/Surfaces/Workshop/DiscoverView.swift Sources/Waple/Shell/MainWindowView.swift
git rm --cached --ignore-unmatch Sources/Waple/WorkshopView.swift 2>/dev/null; true
git add -u Sources/Waple/
git commit -m "기능(ui): 검색·창작마당 탭 네이티브 재구축 — 디스커버 레일 4종·무한 스크롤 그리드·툴바 검색/정렬 통합·WAPLE_SMOKE_TAB·레거시 WorkshopView 제거"
```

---

### Task 6: 캡처·판정 (메인 에이전트 전용 — 서브에이전트는 실행하지 않는다)

- 빌드 + 3스위트 재검증(메인이 독립 재실행).
- 캡처(캡처 PNG는 /tmp 만, 리포 커밋 금지):
  ```bash
  WAPLE_SMOKE=1 WAPLE_SMOKE_TAB=discover .build/debug/Waple &   # → scripts/window-id.swift Waple → screencapture -l<id> /tmp/waple-sp4-discover.png
  WAPLE_SMOKE=1 WAPLE_SMOKE_TAB=workshop .build/debug/Waple &   # → /tmp/waple-sp4-workshop.png
  ```
- Steam API 키가 Keychain 에 없으면 두 탭 모두 `APIKeyGateView` 캡처가 된다(실데이터 캡처는 사용자 키 입력 후 동일 바이너리로 재캡처 — 재빌드하면 Keychain ACL 프롬프트가 다시 뜰 수 있으니 캡처 전 마지막 빌드 이후 사용자 키 입력 순서 유지).
- 사용자 판정 통과 → 문서/BACKLOG 현행화 커밋(스펙 머릿말 SP4′ 완료 표기·BACKLOG 트리거 항목 이동·README 필요 시).

## Self-Review 결과

- 스펙 커버리지: 디스커버 행 4종(트렌드3·최신1·구독순9·투표0) = Task 2+5 / 창작마당 검색·정렬·페이지드 로딩(네이티브 스크롤로 페이지네이션 컨트롤 폐기) = Task 1+4 / 다운로드 진행 UI(DownloadUIState 재사용) + 타일 평점(voteScore 별 환산) = Task 3 / 키 미설정 안내 공유 = Task 3 / 모바일·설정 비활성+툴팁 = SP1′ 기존 유지 / 투표는 표시만 = ratingBadge 액션 없음. 갭 없음.
- 타입 일관성: `WorkshopViewModel.DownloadUIState`(중첩) 참조 경로, `RemoteTileView` 시그니처, `DiscoverViewModel.Row/RowState`, `Metrics.*` 5종 — Task 간 대조 완료.
- 커밋 그린 원칙: Task 4의 MainWindowView 교체가 DiscoverView 에 의존하므로 4+5 합동 커밋으로 조정(본문에 명시).
