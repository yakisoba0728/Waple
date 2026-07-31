import XCTest
@testable import Waple

/// 디스커버 행 조합 — 정렬 4종이 각자 올바른 query_type 으로 나가고, 행 실패가 서로 격리되는지.
@MainActor
final class DiscoverViewModelTests: XCTestCase {

    private final class FailSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var _failing = true
        var failing: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _failing }
            set { lock.lock(); _failing = newValue; lock.unlock() }
        }
    }

    private final class KeyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _v: String?
        init(_ v: String?) { _v = v }
        var value: String? {
            get { lock.lock(); defer { lock.unlock() }; return _v }
            set { lock.lock(); _v = newValue; lock.unlock() }
        }
    }

    private func itemsJSON(count: Int) -> Data {
        let details = (1...count).map { "{\"publishedfileid\":\"\($0)\",\"title\":\"t\($0)\"}" }
            .joined(separator: ",")
        return Data("{\"response\":{\"publishedfiledetails\":[\(details)]}}".utf8)
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
            if queryValue(url, "query_type") == "1" && failing.failing { throw URLError(.timedOut) }
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

    /// 키 클리어 후 재입력(계정/키 변경) → 낡은 레일을 버리고 재로드해야 한다. 같은 키 재진입은 스킵.
    func testKeyChangeReloadsRailsButSameKeySkips() async {
        let recorder = URLRecorder()
        let key = KeyBox("K1")
        let vm = DiscoverViewModel(client: WorkshopClient(transport: { url in
            recorder.record(url); return (self.itemsJSON(count: 1), 200)
        }), keyProvider: { key.value })

        await vm.loadIfNeeded()
        XCTAssertEqual(recorder.urls.count, 4, "첫 로드: 4행")

        await vm.loadIfNeeded()
        XCTAssertEqual(recorder.urls.count, 4, "같은 키 재진입은 재로드하지 않는다")

        key.value = "K2"   // 키 변경(클리어 후 재입력 시뮬레이트)
        await vm.loadIfNeeded()
        XCTAssertEqual(recorder.urls.count, 8, "키 변경 시 4행 재로드")
        for row in vm.rows {
            guard case .loaded = row.state else { return XCTFail("재로드 후 로드 상태여야 함: \(row.state)") }
        }
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

    /// 탭 이탈로 .task 가 취소되면 행 로드가 CancellationError 로 끝난다 — 행을 .failed 로 굳히고
    /// attemptedLoad 까지 세워 재진입 자동 재시도를 막던 회귀.
    func testCancelledLoadLeavesRowsUnfailedAndRetriesOnReentry() async {
        let blocking = FailSwitch()   // failing=true 동안 transport 를 붙잡아 둔다(취소 전까지 미완료)
        let vm = DiscoverViewModel(client: WorkshopClient(transport: { _ in
            if blocking.failing {
                try await Task.sleep(nanoseconds: 10_000_000_000)   // 취소되면 즉시 CancellationError
            }
            return (self.itemsJSON(count: 1), 200)
        }), keyProvider: { "KEY" })

        let load = Task { await vm.loadIfNeeded() }
        load.cancel()                            // 탭 이탈 — .task 취소와 동일
        await load.value
        for row in vm.rows {
            guard case .loading = row.state else {
                return XCTFail("취소된 행은 .failed 가 아니라 .loading 이어야 함: \(row.state)")
            }
        }

        blocking.failing = false
        await vm.loadIfNeeded()                  // 재진입 — 취소를 시도로 세지 않았으므로 다시 로드
        for row in vm.rows {
            guard case .loaded = row.state else { return XCTFail("재진입 후 로드돼야 함: \(row.state)") }
        }
    }
}
