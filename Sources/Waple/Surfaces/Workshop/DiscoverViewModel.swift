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
