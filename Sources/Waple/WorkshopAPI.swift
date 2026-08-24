import Foundation
import Security
import WapleCore

// Steam Web API(IPublishedFileService/QueryFiles) 로 Wallpaper Engine 워크샵을 검색한다.
// URL 조립·query_type 결정·응답 파싱은 전부 순수 함수(WorkshopQuery/WorkshopResponseParser)로 분리해
// 네트워크 없이 단위 테스트한다(AppLogic/FFmpegConverter 패턴). 실제 fetch 는 WorkshopClient 가
// 주입 가능한 transport 로 수행한다. API 키는 Keychain 에만 저장(비밀값 — UserDefaults 금지).

/// 검색 정렬. rawValue = Steam query_type(검색어가 있으면 12 로 강제됨 — WorkshopQuery.queryType).
/// 실측: 0=RankedByVote, 1=RankedByPublicationDate, 3=RankedByTrend, 9=RankedByTotalUniqueSubscriptions.
enum WorkshopSort: Int, CaseIterable, Identifiable {
    case subscriptions = 9
    case latest = 1
    case trend = 3
    case votes = 0

    var id: Int { rawValue }

    /// 정렬 메뉴에 뜨는 이름. **이미 현지화된 문자열**이다.
    ///
    /// enum 계산 프로퍼티는 현지화 오라클의 사각지대다 — 커버리지 스캐너는 정해진 표시 API
    /// 이름 목록으로만 리터럴을 찾으므로 `return "구독순"` 은 어디에도 걸리지 않는다.
    /// 그래서 테스트가 초록인데 영어 시스템의 정렬 메뉴만 한국어로 남아 있었다.
    /// 생산 지점에서 감싸 두면 스캐너의 패턴 1(`NSLocalizedString(`)에 그대로 잡히고,
    /// 호출부는 `Text(sort.label)` 비현지화 오버로드여도 이미 번역된 값을 받는다.
    var label: String {
        switch self {
        case .subscriptions: return NSLocalizedString("구독순", comment: "워크샵 정렬 — 구독 수")
        case .latest: return NSLocalizedString("최신", comment: "워크샵 정렬 — 최근 등록")
        case .trend: return NSLocalizedString("트렌드", comment: "워크샵 정렬 — 인기 급상승")
        case .votes: return NSLocalizedString("투표순", comment: "워크샵 정렬 — 평점")
        }
    }
}

/// 워크샵 항목(그리드 표시에 필요한 최소 필드만).
struct WorkshopItem: Identifiable, Equatable {
    let id: String            // publishedfileid
    let title: String
    let previewURL: URL?
    let subscriptions: Int?
    let tags: [String]
    let fileSize: Int?
    let voteScore: Double?    // vote_data.score 0…1(다운로드 시 라이브러리 평점으로 저장)
}

/// URL 조립 + query_type 결정(순수). appid 431960 = Wallpaper Engine 고정.
enum WorkshopQuery {
    static let appid = "431960"
    static let endpoint = "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/"

    /// 검색어가 비어있지 않으면 반드시 12(RankedByTextSearch) — 아니면 Steam 이 search_text 를 무시한다(실측).
    /// 비어있으면 사용자가 고른 정렬(sort.rawValue)을 그대로 쓴다.
    static func queryType(searchText: String, sort: WorkshopSort) -> Int {
        trimmed(searchText).isEmpty ? sort.rawValue : 12
    }

    static func searchURL(apiKey: String, page: Int, numPerPage: Int,
                          searchText: String, sort: WorkshopSort) -> URL? {
        guard var comps = URLComponents(string: endpoint) else { return nil }
        let search = trimmed(searchText)
        comps.queryItems = [
            .init(name: "key", value: apiKey),
            .init(name: "appid", value: appid),
            .init(name: "page", value: String(page)),
            .init(name: "numperpage", value: String(numPerPage)),
            .init(name: "search_text", value: search),
            .init(name: "query_type", value: String(queryType(searchText: search, sort: sort))),
            .init(name: "return_tags", value: "true"),
            .init(name: "return_previews", value: "true"),
            .init(name: "return_metadata", value: "true"),
            .init(name: "return_short_description", value: "true"),
            .init(name: "return_vote_data", value: "true"),
        ]
        return comps.url
    }

    /// F840: publishedfileid 살균 — **숫자만**. 이 문자열은 steamcmd argv 와 파일 경로 두 곳으로
    /// 흘러간다. 셸도 보간도 없지만 steamcmd 는 `+` 로 시작하는 argv 를 **새 명령**으로 해석하므로
    /// id 하나가 `+runscript` 면 임의 명령이 주입되고(SteamCmdDownloader.arguments),
    /// 같은 문자열이 `steamapps/workshop/content/<appid>/<id>` 경로 조각으로도 들어가
    /// `../` 탈출이 된다(SteamCmdDownloader.resultPathCandidates).
    /// LibraryStore 의 F580(패키지 선언 id 살균)과 같은 규율 — **값이 계에 들어오는 지점**에서 막는다.
    /// 상한 20자리: 실제 publishedfileid 는 64비트 10진수라 최대 20자리다.
    static func isValidPublishedFileID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 20 && id.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 응답 파싱(순수). ponytail: Codable 대신 JSONSerialization + 관대 추출 —
/// Steam 은 카운트를 문자열/정수 혼용으로 주고 필드를 통째로 빠뜨리기도 하므로,
/// 이 리포의 ProjectJSONParser 와 동일한 관대 파싱 관용구를 쓴다(누락/타입불일치 → nil).
enum WorkshopResponseParser {
    static func parse(_ data: Data) -> [WorkshopItem] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let details = response["publishedfiledetails"] as? [[String: Any]] else {
            return []
        }
        return details.compactMap(item(from:))
    }

    private static func item(from obj: [String: Any]) -> WorkshopItem? {
        guard let id = lenientString(obj["publishedfileid"]), !id.isEmpty else { return nil }
        let title = lenientString(obj["title"]) ?? id
        // F840: preview_url 은 원격 문자열이다. URLSession 은 file:// 도 그대로 처리하므로
        // 스킴 검증 없이 넘기면 원격이 지정한 로컬 파일을 앱이 읽어 화면에 그린다.
        // https 만 허용(NowPlayingProvider.isValidArtworkURL 의 F564 와 같은 정책).
        let preview = lenientString(obj["preview_url"])
            .flatMap(URL.init(string:))
            .flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        let vote = (obj["vote_data"] as? [String: Any]).flatMap { lenientDouble($0["score"]) }
        return WorkshopItem(
            id: id,
            title: title,
            previewURL: preview,
            subscriptions: lenientInt(obj["subscriptions"]),
            tags: parseTags(obj["tags"]),
            fileSize: lenientInt(obj["file_size"]),
            voteScore: vote
        )
    }

    /// tags 는 QueryFiles 에서 [{"tag":"Scene"}] 형태(구버전은 ["Scene"]). 둘 다 관대하게 처리.
    private static func parseTags(_ value: Any?) -> [String] {
        if let objects = value as? [[String: Any]] {
            return objects.compactMap { lenientString($0["tag"]) }
        }
        if let strings = value as? [String] { return strings }
        return []
    }

    private static func lenientString(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.stringValue
    }

    private static func lenientInt(_ value: Any?) -> Int? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func lenientDouble(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

/// API 키 저장소 — Keychain(kSecClassGenericPassword). 비밀값이라 UserDefaults 금지.
enum SteamAPIKeyStore {
    static let service = "kr.yaki.waple.steam-api-key"
    static let account = "default"  // ponytail: 단일 키 — 계정 고정

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    /// save() 실패 원인 — UI 가 .message 를 그대로 사용자에게 보여줄 수 있다.
    enum SaveFailure: Equatable {
        /// delete 가 실패했는데 add 가 errSecDuplicateItem — 구항목이 그대로 남아 막혔을 가능성이
        /// 높다(재서명/재빌드 후 레거시 파일 키체인 ACL 이 코드서명 cdhash 에 묶여 delete 를 거부하는
        /// 함정 케이스가 대표적).
        case aclDenied
        case other(OSStatus)

        /// **이미 현지화된 문자열** — UI 는 그대로 표시하기만 한다.
        /// 종전에는 리터럴 두 개를 `+` 로 이어 붙여 만들었는데, 그러면 키가 반 토막씩 두 개가 돼
        /// 번역이 불가능하다(번역문의 어순이 원문과 같다는 보장이 없다). 키는 한 문장이어야 한다.
        var message: String {
            switch self {
            case .aclDenied:
                return NSLocalizedString(
                    "API 키를 저장하지 못했습니다 — Keychain 이 기존 항목 삭제를 거부했습니다(권한/서명 변경 가능성). macOS '키체인 접근' 앱에서 'kr.yaki.waple.steam-api-key' 항목을 지운 뒤 다시 시도하세요.",
                    comment: "Keychain ACL 거부로 API 키 저장 실패")
            case .other(let status):
                // %d — OSStatus 는 Int32 다. %lld 로 받으면 폭이 어긋난다.
                return String(format: NSLocalizedString("API 키를 저장하지 못했습니다(Keychain 오류 %d).",
                                                        comment: "분류되지 않은 Keychain 저장 실패"),
                              status)
            }
        }
    }

    /// 저장: 항상 삭제 후 추가. SecItemAdd 단독은 두 번째 저장에서 errSecDuplicateItem 으로 조용히 실패한다.
    /// 빈 값이면 삭제만(클리어). 종전엔 SecItemDelete/SecItemAdd 의 OSStatus 를 전부 버려, 저장이 조용히
    /// 실패해도 원인(잠금/ACL 거부/엔타이틀먼트 없음)을 로깅·구분·안내할 수 없었다 — 상태를 검사·로깅하고
    /// 실패 원인을 반환한다. delete/add 는 테스트 주입(기본 SecItemDelete/SecItemAdd) — 실제 Keychain
    /// 없이 ACL 거부 등 실패 경로를 결정적으로 검증할 수 있다.
    @discardableResult
    static func save(_ key: String,
                     delete: (CFDictionary) -> OSStatus = SecItemDelete,
                     add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd) -> SaveFailure? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let deleteStatus = delete(baseQuery() as CFDictionary)
        let deleteOK = deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound
        if !deleteOK {
            NSLog("%@", "[Waple] SteamAPIKeyStore: 기존 항목 삭제 실패 — OSStatus \(deleteStatus)")
        }
        guard !trimmed.isEmpty else {
            if deleteOK { return nil }
            let failure = SaveFailure.other(deleteStatus)
            NSLog("%@", "[Waple] SteamAPIKeyStore: 키 삭제(클리어) 실패 — \(failure.message)")
            return failure
        }
        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = Data(trimmed.utf8)
        let addStatus = add(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            let failure: SaveFailure = (addStatus == errSecDuplicateItem && !deleteOK) ? .aclDenied : .other(addStatus)
            NSLog("%@", "[Waple] SteamAPIKeyStore: 키 저장 실패 — OSStatus \(addStatus)(선행 delete \(deleteStatus)) — \(failure.message)")
            return failure
        }
        return nil
    }
}

enum WorkshopError: Error, LocalizedError {
    case badURL
    case http(Int)

    /// 종전엔 모든 비-2xx 를 "API 키를 확인하세요"로 단일 처리해, 429(레이트리밋)·5xx(Steam 장애)도
    /// 키 오류로 오진단했다 — 실제로는 멀쩡한 키를 사용자가 재발급(파괴적 "API 키 변경")하도록
    /// 오도할 수 있다. 429/5xx는 재시도 안내로, 인증 실패(401/403)만 키 확인으로 분리한다.
    /// **이미 현지화된 문자열.** 뷰모델이 그대로 `statusMessage` 에 담아 뷰가 표시한다 —
    /// 보간으로 만들면 `Text(String)` 비현지화 오버로드에 닿아 영어 시스템에서도 한국어로 남는다.
    var errorDescription: String? {
        switch self {
        case .badURL:
            return NSLocalizedString("검색 URL 을 만들 수 없습니다.", comment: "URLComponents 조립 실패")
        case .http(let code):
            switch code {
            case 429:
                return NSLocalizedString("Steam 요청이 너무 잦습니다(HTTP 429). 잠시 후 다시 시도하세요.",
                                         comment: "레이트리밋 — 키 오류가 아니다")
            case 500...599:
                return String(format: NSLocalizedString("Steam 서버 응답 오류(HTTP %lld). 잠시 후 다시 시도하세요.",
                                                        comment: "Steam 장애 — 키 오류가 아니다"), code)
            case 401, 403:
                return String(format: NSLocalizedString("Steam 응답 오류(HTTP %lld). API 키를 확인하세요.",
                                                        comment: "인증 실패 — 키 확인 안내"), code)
            default:
                return String(format: NSLocalizedString("Steam 응답 오류(HTTP %lld).",
                                                        comment: "분류되지 않은 HTTP 오류"), code)
            }
        }
    }
}

/// 실제 fetch. transport 주입으로 네트워크 없이 테스트 가능(파싱은 WorkshopResponseParser 로 별도 검증).
/// [2026-08-25] `Sendable` — 이 값은 뷰모델(@MainActor)에서 `Task` 안으로 넘어간다
/// (`WorkshopViewModel:133`·`:164`, `DiscoverViewModel:88`). 그때 `sending 'self.client'` 진단이
/// 났는데, 실제로는 **넘겨도 되는 값**이다: 저장 프로퍼티가 `transport` 클로저 하나뿐이고
/// 가변 상태가 없다. 그 사실을 타입으로 적는다 — 클로저도 `@Sendable` 로 올려 실제 검사를 받게 한다.
///
/// 주입되는 클로저 둘 다 이미 조건을 만족한다: `live()` 는 파일 정적 `session` 만 캡처하고,
/// 테스트 더블은 값 타입 픽스처만 캡처한다.
struct WorkshopClient: Sendable {
    /// URL → (Data, HTTP status). 기본은 URLSession.
    var transport: @Sendable (URL) async throws -> (Data, Int)

    /// F840: `URLSession.shared` 를 쓰지 않는다. 공유 세션의 `URLCache.shared` 는 **전체 URL 문자열**을
    /// 키로 디스크 캐시(`~/Library/Caches/<bundleid>/Cache.db`)를 만드는데, 검색 URL 은
    /// `?key=<API 키>` 를 쿼리로 달고 나간다(WorkshopQuery.searchURL) — 캐시 가능한 응답이 한 번만
    /// 와도 Keychain 전용이어야 할 키가 평문으로 디스크에 남는다. README·설정 UI 의
    /// "키는 Keychain 에만 저장됩니다" 와 정면으로 모순되는 상태였다.
    /// `.ephemeral` 은 캐시·쿠키·자격증명을 전부 메모리에만 둔다(urlCache=nil 로 한 번 더 못 박는다).
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func live() -> WorkshopClient {
        WorkshopClient { url in
            let (data, response) = try await WorkshopClient.session.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 200
            return (data, code)
        }
    }

    func search(apiKey: String, page: Int = 1, numPerPage: Int = 30,
                searchText: String, sort: WorkshopSort) async throws -> [WorkshopItem] {
        guard let url = WorkshopQuery.searchURL(apiKey: apiKey, page: page, numPerPage: numPerPage,
                                                searchText: searchText, sort: sort) else {
            throw WorkshopError.badURL
        }
        let (data, code) = try await transport(url)
        guard (200..<300).contains(code) else { throw WorkshopError.http(code) }
        return WorkshopResponseParser.parse(data)
    }
}
