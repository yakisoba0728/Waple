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
    var label: String {
        switch self {
        case .subscriptions: return "구독순"
        case .latest: return "최신"
        case .trend: return "트렌드"
        case .votes: return "투표순"
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
        let preview = lenientString(obj["preview_url"]).flatMap(URL.init(string:))
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

        var message: String {
            switch self {
            case .aclDenied:
                return "API 키를 저장하지 못했습니다 — Keychain 이 기존 항목 삭제를 거부했습니다(권한/서명 변경 가능성). " +
                       "macOS '키체인 접근' 앱에서 'kr.yaki.waple.steam-api-key' 항목을 지운 뒤 다시 시도하세요."
            case .other(let status):
                return "API 키를 저장하지 못했습니다(Keychain 오류 \(status))."
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

    var errorDescription: String? {
        switch self {
        case .badURL: return "검색 URL 을 만들 수 없습니다."
        case .http(let code): return "Steam 응답 오류(HTTP \(code)). API 키를 확인하세요."
        }
    }
}

/// 실제 fetch. transport 주입으로 네트워크 없이 테스트 가능(파싱은 WorkshopResponseParser 로 별도 검증).
struct WorkshopClient {
    /// URL → (Data, HTTP status). 기본은 URLSession.
    var transport: (URL) async throws -> (Data, Int)

    static func live() -> WorkshopClient {
        WorkshopClient { url in
            let (data, response) = try await URLSession.shared.data(from: url)
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
