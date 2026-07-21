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

    /// 1회성 래치 — transport 의 진입/재개를 결정적으로 인터리브한다.
    private actor Latch {
        private var signaled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if signaled { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func signal() {
            guard !signaled else { return }
            signaled = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
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

    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)   // tearDown 에서 정리($TMPDIR 리터 방지)
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

    /// 정렬 급변경 경합: 낡은 검색 응답이 늦게 도착해도 최신 검색 결과를 덮어쓰지 않아야 한다(요청 에폭).
    func testStaleSearchIsDiscardedWhenNewerSearchWins() async {
        let entered = Latch()   // 낡은 검색이 transport 에 진입(epoch=1 확정)했음을 알린다
        let proceed = Latch()   // 최신 검색이 적용된 뒤 낡은 검색을 재개시킨다
        let vm = makeVM { url in
            // 정렬로 두 응답 구분: subscriptions(query_type 9)=낡은 검색, latest(1)=최신 검색
            if self.queryValue(url, "query_type") == "9" {
                await entered.signal()
                await proceed.wait()
                return (self.itemsJSON(ids: 1...5), 200)      // 낡은 데이터 — 반영되면 안 됨
            }
            return (self.itemsJSON(ids: 100...105), 200)       // 최신 데이터 — 반영돼야 함
        }
        vm.sort = .subscriptions
        let stale = Task { await vm.search() }   // 첫(낡은) 검색 — transport 에서 붙잡힘
        await entered.wait()                       // epoch=1·URL(정렬9) 확정 후에만 진행
        vm.sort = .latest
        await vm.search()                          // 최신 검색 — 즉시 완료·적용(epoch=2)
        XCTAssertEqual(vm.results.map(\.id), (100...105).map(String.init), "최신 검색 결과가 반영된다")
        await proceed.signal()                     // 낡은 검색 재개
        await stale.value                          // 낡은 응답 도착 — epoch 불일치로 폐기돼야 함
        XCTAssertEqual(vm.results.map(\.id), (100...105).map(String.init), "낡은 응답이 최신을 덮어쓰지 않는다")
        XCTAssertFalse(vm.isSearching, "최신 검색 종료 후 스피너 내려감(낡은 검색 defer 가 건드리지 않음)")
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

    /// 탭 이탈로 .task 가 취소되면 URLSession 은 URLError.cancelled 를 던진다 — 이를 실패로 오판해
    /// results 를 비우고 attemptedInitialLoad 까지 세워 재진입 자동 재시도를 막던 회귀.
    func testCancelledSearchLeavesNoFailureStateAndRetriesOnReentry() async {
        let recorder = URLRecorder()
        let cancelled = FailSwitch(true)
        let vm = makeVM { url in
            recorder.record(url)
            if cancelled.failing { throw URLError(.cancelled) }
            return (self.itemsJSON(ids: 1...30), 200)
        }
        await vm.searchIfNeeded()                    // 취소된 첫 로드
        XCTAssertNil(vm.statusMessage, "취소는 실패가 아니다 — 메시지를 남기지 않는다")
        XCTAssertTrue(vm.results.isEmpty)
        cancelled.failing = false
        await vm.searchIfNeeded()                    // 재진입 — 취소를 시도로 세지 않았으므로 재요청
        XCTAssertEqual(vm.results.count, 30)
        XCTAssertEqual(recorder.urls.count, 2)
    }

    /// CancellationError 변형도 동일하게 다룬다 — 이미 로드된 결과를 취소된 재검색이 지우면 안 된다.
    func testSearchCancellationErrorKeepsPreviousResults() async {
        let cancelled = FailSwitch(false)
        let vm = makeVM { _ in
            if cancelled.failing { throw CancellationError() }
            return (self.itemsJSON(ids: 1...30), 200)
        }
        await vm.search()
        XCTAssertEqual(vm.results.count, 30)
        cancelled.failing = true
        await vm.search()
        XCTAssertEqual(vm.results.count, 30, "취소된 재검색이 기존 결과를 지우면 안 된다")
        XCTAssertNil(vm.statusMessage)
    }

    /// loadMore 도 같은 취소 오판을 가졌다 — 취소된 페이지 로드가 실패 메시지를 남기면 안 된다.
    func testCancelledLoadMoreDoesNotSetFailureMessage() async {
        let cancelled = FailSwitch(true)
        let vm = makeVM { url in
            if self.queryValue(url, "page") == "2" && cancelled.failing { throw URLError(.cancelled) }
            return (self.itemsJSON(ids: 1...30), 200)
        }
        await vm.search()
        await vm.loadMore()                          // 취소된 페이지 로드
        XCTAssertNil(vm.statusMessage, "취소는 실패 메시지를 남기지 않는다")
        XCTAssertEqual(vm.results.count, 30)
        XCTAssertTrue(vm.canLoadMore, "재시도 가능 상태를 유지한다")
    }
}
