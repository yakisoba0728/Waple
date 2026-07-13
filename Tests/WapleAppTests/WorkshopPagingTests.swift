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
