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
    // 요청 세대. 정렬 급변경마다 새 search 가 뜨고 응답이 경합한다 — 시작 시 증가·캡처하고,
    // 응답 적용 직전에 최신 세대와 비교해 낡은 응답(다른 정렬/이전 검색)을 폐기한다.
    private var searchEpoch = 0

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
        searchEpoch &+= 1
        let epoch = searchEpoch
        attemptedInitialLoad = true
        isSearching = true
        statusMessage = nil
        page = 1
        canLoadMore = false
        // 최신 세대만 isSearching 을 내린다 — 낡은 search 가 먼저 끝나도 스피너를 끄지 않게.
        defer { if epoch == searchEpoch { isSearching = false } }
        do {
            let fetched = try await client.search(apiKey: key, page: 1, numPerPage: pageSize,
                                                  searchText: searchText, sort: sort)
            guard epoch == searchEpoch else { return }   // 더 새 검색이 떴다 → 이 응답 폐기
            results = fetched
            canLoadMore = fetched.count == pageSize
            if fetched.isEmpty { statusMessage = "결과가 없습니다." }
        } catch {
            guard epoch == searchEpoch else { return }
            results = []
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "검색 실패: \(error.localizedDescription)"
        }
    }

    /// 그리드 마지막 타일 onAppear 에서 호출 — 다음 페이지를 append(중복 id 는 버린다: ForEach id 충돌 방지).
    func loadMore() async {
        guard canLoadMore, !isLoadingMore, !isSearching, let key = keyProvider() else { return }
        let epoch = searchEpoch
        isLoadingMore = true
        defer { isLoadingMore = false }   // 이 loadMore 단독 소유 플래그 — 무조건 해제(폐기돼도 재개통해야 함)
        // page 는 append 가 실제 반영될 때만 올린다 — 검색이 끼어들어 폐기되면 page 를 건드리지 않아
        // pagination gap(중간 페이지 건너뜀)을 원천 차단한다. 실패 시에도 page 미변경이라 재시도가 같은 페이지.
        let nextPage = page + 1
        do {
            let batch = try await client.search(apiKey: key, page: nextPage, numPerPage: pageSize,
                                                searchText: searchText, sort: sort)
            guard epoch == searchEpoch else { return }   // 검색이 끼어든 응답 → page/results 미변경 후 폐기
            page = nextPage
            let known = Set(results.map(\.id))
            results.append(contentsOf: batch.filter { !known.contains($0.id) })
            canLoadMore = batch.count == pageSize
        } catch {
            guard epoch == searchEpoch else { return }
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
