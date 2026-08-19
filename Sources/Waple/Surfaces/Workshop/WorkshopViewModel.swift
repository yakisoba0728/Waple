import SwiftUI
import WapleLibrary

// Steam 워크샵 검색·페이징·다운로드 상태머신. 순수 로직(WorkshopAPI/SteamCmdDownloader)을 얇게 배선한다.
// @MainActor — async 클라이언트/다운로더 콜백이 오프메인에서 재개되므로 @Published 변경을 전부 메인으로 모은다.
// keyProvider — Keychain(SteamAPIKeyStore) 직독을 주입으로 바꿔 네트워크리스 테스트를 가능하게 한다.
// downloader·steamcmdAvailable — SteamCmdDownloader 정적 호출/실행파일 탐지를 주입으로 바꿔
// 다운로드 상태머신을 steamcmd 없이 테스트한다(기본값=현행 정적 호출).
@MainActor
final class WorkshopViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var sort: WorkshopSort = .subscriptions
    @Published private(set) var results: [WorkshopItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var canLoadMore = false
    /// 상태/오류 문구. **여기 담기는 값은 이미 현지화돼 있다** — 뷰는 `Text(message)` 로
    /// 그대로 표시한다. 그 오버로드(`Text(_ content: some StringProtocol)`)는 번역을 하지
    /// 않으므로, 번역은 문자열을 **만드는 쪽**에서 끝나 있어야 한다(청사진 §5.0 (a)).
    /// 대안이던 `LocalizedStringKey` 로 타입을 바꾸는 길은 대입문이라 어떤 스캔 패턴에도
    /// 걸리지 않아, 런타임 버그 하나를 고치면서 오라클 사각지대를 새로 만든다.
    @Published var statusMessage: String?
    @Published private(set) var hasAPIKey: Bool
    @Published var apiKeyInput = ""
    @Published var usernameInput: String
    @Published private(set) var downloads: [String: DownloadUIState] = [:]

    let steamcmdAvailable: Bool
    let pageSize = 30

    private let client: WorkshopClient
    private let library: LibraryViewModel
    private let keyProvider: () -> String?
    private let keySaver: (String) -> SteamAPIKeyStore.SaveFailure?
    private let downloader: Downloader
    private var page = 1
    private var attemptedInitialLoad = false
    // F492: steamcmd 출력 신호(다운로드별) — 완료 콜백의 nil 하나로는 원인을 알 수 없어,
    // ERROR!/성공 라인 관측 여부로 실패 유형(로그인 계열 vs 그 외)을 나누는 데 쓴다.
    private var sawErrorSignal = Set<String>()
    private var sawSuccessSignal = Set<String>()
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

    /// 다운로드 실행 심 — 시그니처는 SteamCmdDownloader.download 와 같다(테스트에서 콜백 캡처용).
    /// 콜백 둘이 `@Sendable` 인 것은 그쪽 시그니처를 따라간 것이다(백그라운드 큐 → 메인 큐를 거쳐
    /// 불린다는 사실). 심의 파라미터 위치는 반변이라 `@Sendable` 아닌 클로저를 받는 테스트 페이크도
    /// 그대로 대입된다 — 넓은 쪽이 좁은 쪽 자리에 들어가는 방향이기 때문이다.
    typealias Downloader = (_ itemId: String, _ username: String,
                            _ progress: @escaping @Sendable (SteamCmdDownloader.Progress) -> Void,
                            _ completion: @escaping @Sendable (URL?) -> Void) -> Void

    init(client: WorkshopClient = .live(), library: LibraryViewModel,
         keyProvider: @escaping () -> String? = { SteamAPIKeyStore.load() },
         keySaver: @escaping (String) -> SteamAPIKeyStore.SaveFailure? = { SteamAPIKeyStore.save($0) },
         steamcmdAvailable: Bool = SteamCmdDownloader.isAvailable,
         downloader: @escaping Downloader = { itemId, username, progress, completion in
             SteamCmdDownloader.download(itemId: itemId, username: username,
                                         progress: progress, completion: completion)
         }) {
        self.client = client
        self.library = library
        self.keyProvider = keyProvider
        self.keySaver = keySaver
        self.steamcmdAvailable = steamcmdAvailable
        self.downloader = downloader
        self.hasAPIKey = keyProvider() != nil
        self.usernameInput = SteamCmdDownloader.username
    }

    // MARK: - API 키

    func saveAPIKey() {
        // F491: 저장 실패(SaveFailure)를 버리고 구키 존재(keyProvider)만으로 성공 판정하던 함정 —
        // ACL 거부 시 구키를 계속 쓰는데 사용자는 새 키가 저장된 줄 알았다. 실패는 메시지로 표면화하고
        // 입력을 유지해 재시도할 수 있게 한다.
        if let failure = keySaver(apiKeyInput) {
            hasAPIKey = keyProvider() != nil
            statusMessage = failure.message
            return
        }
        hasAPIKey = keyProvider() != nil
        if hasAPIKey {
            apiKeyInput = ""
            statusMessage = nil
        } else {
            statusMessage = NSLocalizedString("API 키를 저장하지 못했습니다.",
                                             comment: "저장은 성공했다는데 다시 읽으면 키가 없다")
        }
    }

    func clearAPIKey() {
        // F493: 삭제 실패를 무시하고 hasAPIKey = false 로 두면 stale 키가 Keychain 에 남아 다음 실행
        // 때 부활한다 — 실패를 표면화하고 상태를 그대로 유지한다.
        if let failure = keySaver("") {
            statusMessage = failure.message
            return
        }
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
            if fetched.isEmpty {
                statusMessage = NSLocalizedString("결과가 없습니다.", comment: "검색 결과 0건")
            }
            // 성공 완료 시점에만 시도로 센다 — 실패/취소된 첫 로드는 탭 재진입 시 자동 재시도돼야 한다.
            attemptedInitialLoad = true
        } catch {
            // 탭 이탈 등으로 .task 가 취소된 경우 — 실패가 아니므로 결과/메시지를 건드리지 않는다.
            if isCancellation(error) { return }
            guard epoch == searchEpoch else { return }
            results = []
            statusMessage = (error as? LocalizedError)?.errorDescription
                ?? String(format: NSLocalizedString("검색 실패: %@", comment: "분류되지 않은 검색 오류"),
                          error.localizedDescription)
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
            if isCancellation(error) { return }   // 취소는 실패가 아니다 — page/results/메시지 미변경
            guard epoch == searchEpoch else { return }
            statusMessage = (error as? LocalizedError)?.errorDescription
                ?? String(format: NSLocalizedString("더 불러오기 실패: %@", comment: "다음 페이지 로드 오류"),
                          error.localizedDescription)
        }
    }

    // MARK: - 다운로드 → 임포트 → 적용 (레거시 그대로 이동)

    func download(_ item: WorkshopItem) {
        guard steamcmdAvailable else {
            statusMessage = NSLocalizedString("steamcmd 가 필요합니다: brew install steamcmd",
                                              comment: "다운로더 미설치")
            return
        }
        let username = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            statusMessage = NSLocalizedString("steamcmd 로그인 계정(username)을 먼저 입력하세요.",
                                              comment: "계정 미입력")
            return
        }
        SteamCmdDownloader.username = username
        downloads[item.id] = DownloadUIState(phase: .downloading(nil), entryId: nil)
        sawErrorSignal.remove(item.id)   // F492: 재시도 시 이전 실행의 신호가 섞이지 않게 초기화
        sawSuccessSignal.remove(item.id)
        downloader(item.id, username,
                   { [weak self] p in Task { @MainActor in self?.applyProgress(item.id, p) } },
                   { [weak self] url in Task { @MainActor in self?.finishDownload(item, url) } })
    }

    private func applyProgress(_ id: String, _ p: SteamCmdDownloader.Progress) {
        guard var state = downloads[id], state.phase != .done else { return }
        switch p {
        case .downloading(let v): state.phase = .downloading(v)
        case .verifying: state.phase = .verifying
        case .committing: state.phase = .committing
        case .success:
            state.phase = .importing
            sawSuccessSignal.insert(id)   // F492
        case .failed:
            state.phase = .failed
            sawErrorSignal.insert(id)   // F492
        }
        downloads[id] = state
    }

    private func finishDownload(_ item: WorkshopItem, _ url: URL?) {
        guard let url else {
            downloads[item.id] = DownloadUIState(phase: .failed, entryId: nil)
            // F492: 원인 불문 로그인 오진단 방지 — 관측된 steamcmd 신호로 실패 유형을 나눈다.
            // ERROR! 라인은 로그인/세션 계열이 대표적이라 기존 안내를 유지하고, 성공 후 폴더 부재와
            // 무신호(타임아웃·실행 실패·네트워크)는 로그인 무관 원인을 안내한다.
            // 보간 대신 포맷 지정자 — 번역문에서 배경 제목과 계정명의 어순이 원문과 다를 수 있고,
            // 보간으로 만든 문자열은 애초에 번역 대상이 되지 않는다(§5.0).
            if sawSuccessSignal.contains(item.id) {
                statusMessage = String(
                    format: NSLocalizedString("‘%@’ 다운로드는 완료됐지만 결과 폴더를 찾지 못했습니다 — steamcmd 의 content 폴더 위치를 확인하세요.",
                                              comment: "성공 신호는 봤는데 폴더가 없다"),
                    item.title)
            } else if sawErrorSignal.contains(item.id) {
                statusMessage = String(
                    format: NSLocalizedString("‘%@’ 다운로드 실패 — 터미널에서 `steamcmd +login %@` 로 1회 로그인해 세션을 캐시했는지 확인하세요.",
                                              comment: "ERROR! 라인 관측 — 로그인/세션 계열이 대표적"),
                    item.title, usernameInput)
            } else {
                statusMessage = String(
                    format: NSLocalizedString("‘%@’ 다운로드 실패 — steamcmd 가 완료 신호를 내지 않았습니다(시간 초과·네트워크·실행 오류 가능). 터미널에서 `steamcmd +login %@` 세션 캐시를 확인하고 직접 시도해 원인을 파악하세요.",
                                              comment: "무신호 실패 — 로그인 무관 원인"),
                    item.title, usernameInput)
            }
            sawErrorSignal.remove(item.id)
            sawSuccessSignal.remove(item.id)
            return
        }
        sawErrorSignal.remove(item.id)
        sawSuccessSignal.remove(item.id)
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

/// .task 취소(탭 이탈 등) 식별 — URLSession 은 경로/OS 에 따라 CancellationError 또는
/// URLError.cancelled 로 throw 하므로 둘 다 취소로 본다.
private func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}
