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
