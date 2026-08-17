import SwiftUI

/// 검색(디스커버) 탭 — Steam QueryFiles 정렬 4종을 가로 레일 행으로 조합한다. 신규 네트워크 코드 없음
/// (WorkshopClient 재사용, 스펙 §디스커버). 행별 로드는 동시에, 실패는 행 단위로 격리한다.
@MainActor
final class DiscoverViewModel: ObservableObject {
    enum RowState: Equatable {
        case loading
        case loaded([WorkshopItem])
        /// 연관값은 **이미 현지화된 문구**다 — 뷰가 그대로 표시한다(§5.0).
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        let sort: WorkshopSort
        var state: RowState = .loading
        var id: Int { sort.rawValue }

        /// 레일 제목. **이미 현지화된 문자열**이다 — `WorkshopSort.label` 과 같은 이유로
        /// enum 계산 프로퍼티는 커버리지 스캐너에 잡히지 않아, 감싸지 않으면 영어 시스템에서
        /// 레일 제목만 한국어로 남는다.
        ///
        /// 정렬 라벨(`WorkshopSort.label`)과 문구가 다른 것은 의도다 — 이쪽은 편집자가 붙인
        /// 진열대 이름이고, 저쪽은 메뉴에서 고르는 축의 이름이라 어투가 다르다.
        var title: String {
            switch sort {
            case .trend: return NSLocalizedString("인기 급상승", comment: "디스커버 레일 제목")
            case .latest: return NSLocalizedString("최신 등록", comment: "디스커버 레일 제목")
            case .subscriptions: return NSLocalizedString("구독 순", comment: "디스커버 레일 제목")
            case .votes: return NSLocalizedString("평점 순", comment: "디스커버 레일 제목")
            }
        }
    }

    static let rowSorts: [WorkshopSort] = [.trend, .latest, .subscriptions, .votes]
    static let rowItemCount = 12

    @Published private(set) var rows: [Row] = DiscoverViewModel.rowSorts.map { Row(sort: $0) }

    private let client: WorkshopClient
    private let keyProvider: () -> String?
    private var attemptedLoad = false
    /// 마지막으로 로드한 키. 키가 바뀌면(재발급/계정 변경) 낡은 레일을 버리고 재로드한다.
    private var loadedKey: String?

    init(client: WorkshopClient = .live(),
         keyProvider: @escaping () -> String? = { SteamAPIKeyStore.load() }) {
        self.client = client
        self.keyProvider = keyProvider
    }

    /// 탭 진입 시 로드(키 게이트 통과 후 호출된다). 4행 동시 — 행이 끝나는 대로 개별 갱신.
    /// 같은 키로의 재진입은 스킵하되, 키가 바뀌었으면 낡은 레일을 비우고 재로드한다.
    func loadIfNeeded() async {
        let key = keyProvider()
        guard key != nil else { return }              // 키 없으면 로드 안 함(뷰가 이미 게이트)
        guard !attemptedLoad || key != loadedKey else { return }
        rows = Self.rowSorts.map { Row(sort: $0) }    // 재로드 시 이전 결과 비우고 .loading 으로
        await withTaskGroup(of: Void.self) { group in
            for index in rows.indices {
                group.addTask { @MainActor in await self.loadRow(at: index) }
            }
        }
        // 탭 이탈 취소로 그룹이 조기 종료됐으면 시도로 세지 않는다 — 재진입 시 다시 로드돼야 한다.
        guard !Task.isCancelled else { return }
        attemptedLoad = true
        loadedKey = key
    }

    /// 실패 행 재시도.
    func reload(_ sort: WorkshopSort) async {
        guard let index = rows.firstIndex(where: { $0.sort == sort }) else { return }
        rows[index].state = .loading
        await loadRow(at: index)
    }

    private func loadRow(at index: Int) async {
        guard let key = keyProvider() else {
            rows[index].state = .failed(NSLocalizedString("Steam Web API 키가 필요합니다.",
                                                          comment: "레일 로드 중 키가 사라진 경우"))
            return
        }
        do {
            let items = try await client.search(apiKey: key, page: 1, numPerPage: Self.rowItemCount,
                                                searchText: "", sort: rows[index].sort)
            rows[index].state = .loaded(items)
        } catch {
            // 탭 이탈 등으로 .task 가 취소된 경우 — 실패가 아니므로 행을 .failed 로 굳히지 않는다.
            if isCancellation(error) { return }
            rows[index].state = .failed((error as? LocalizedError)?.errorDescription
                                        ?? error.localizedDescription)
        }
    }
}

/// .task 취소(탭 이탈 등) 식별 — URLSession 은 경로/OS 에 따라 CancellationError 또는
/// URLError.cancelled 로 throw 하므로 둘 다 취소로 본다.
private func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}
