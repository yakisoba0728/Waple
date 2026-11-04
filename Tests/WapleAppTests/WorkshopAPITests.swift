import XCTest
import Security
@testable import Waple

/// Steam Web API 클라이언트의 순수 로직(URL 조립 / query_type 결정 / 응답 파싱) 검증.
/// 네트워크는 건드리지 않는다.
final class WorkshopAPITests: XCTestCase {

    // MARK: - query_type 결정(가장 중요 — 검색어가 있으면 무조건 12)

    func testQueryTypeIsTextSearchForAnyNonEmptySearchRegardlessOfSort() {
        for sort in WorkshopSort.allCases {
            XCTAssertEqual(WorkshopQuery.queryType(searchText: "sky", sort: sort), 12,
                           "검색어가 있으면 정렬과 무관하게 12(RankedByTextSearch)여야 검색이 적용된다")
        }
    }

    func testQueryTypeUsesSortRawValueWhenSearchEmpty() {
        XCTAssertEqual(WorkshopQuery.queryType(searchText: "", sort: .subscriptions), 9)
        XCTAssertEqual(WorkshopQuery.queryType(searchText: "", sort: .latest), 1)
        XCTAssertEqual(WorkshopQuery.queryType(searchText: "", sort: .trend), 3)
        XCTAssertEqual(WorkshopQuery.queryType(searchText: "", sort: .votes), 0)
    }

    func testQueryTypeTreatsWhitespaceOnlySearchAsEmpty() {
        XCTAssertEqual(WorkshopQuery.queryType(searchText: "   \n ", sort: .latest), 1,
                       "공백뿐인 검색어는 빈 검색으로 취급(정렬 rawValue 사용)")
    }

    // MARK: - searchURL 조립

    private func queryDict(_ url: URL?) -> [String: String] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func testSearchURLContainsRequiredParams() {
        let url = WorkshopQuery.searchURL(apiKey: "KEY", page: 2, numPerPage: 30,
                                          searchText: "neon", sort: .votes)
        let q = queryDict(url)
        XCTAssertEqual(q["key"], "KEY")
        XCTAssertEqual(q["appid"], "431960")               // Wallpaper Engine 고정
        XCTAssertEqual(q["page"], "2")
        XCTAssertEqual(q["numperpage"], "30")
        XCTAssertEqual(q["search_text"], "neon")
        XCTAssertEqual(q["query_type"], "12")              // 검색어 있음 → 12
        XCTAssertEqual(q["return_tags"], "true")
        XCTAssertEqual(q["return_previews"], "true")
        XCTAssertEqual(q["return_metadata"], "true")
        XCTAssertEqual(q["return_short_description"], "true")
        XCTAssertTrue(url?.absoluteString.hasPrefix("https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/") ?? false)
    }

    func testSearchURLEmptySearchUsesSortAndPercentEncodesText() {
        let url = WorkshopQuery.searchURL(apiKey: "K", page: 1, numPerPage: 10,
                                          searchText: "hello world", sort: .subscriptions)
        let q = queryDict(url)
        XCTAssertEqual(q["search_text"], "hello world")     // 디코드된 값
        XCTAssertTrue(url!.absoluteString.contains("hello%20world"), "search_text 는 퍼센트 인코딩되어야 한다")

        let empty = WorkshopQuery.searchURL(apiKey: "K", page: 1, numPerPage: 10,
                                            searchText: "", sort: .subscriptions)
        XCTAssertEqual(queryDict(empty)["query_type"], "9")  // 빈 검색 → 정렬(구독순=9)
    }

    // MARK: - 응답 파싱(관대: 문자열/정수 혼용·필드 누락)

    func testParseExtractsItems() {
        let json = """
        {"response":{"total":2,"publishedfiledetails":[
          {"publishedfileid":"111","title":"Neon City","preview_url":"https://img/a.jpg",
           "subscriptions":1234,"file_size":"5000","tags":[{"tag":"Scene"},{"tag":"Anime"}]},
          {"publishedfileid":"222","title":"Ocean","preview_url":"https://img/b.jpg",
           "subscriptions":"77","tags":["Video"]}
        ]}}
        """.data(using: .utf8)!
        let items = WorkshopResponseParser.parse(json)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "111")
        XCTAssertEqual(items[0].title, "Neon City")
        XCTAssertEqual(items[0].previewURL?.absoluteString, "https://img/a.jpg")
        XCTAssertEqual(items[0].subscriptions, 1234)
        XCTAssertEqual(items[0].fileSize, 5000)             // 문자열 "5000" → 정수
        XCTAssertEqual(items[0].tags, ["Scene", "Anime"])   // [{"tag":…}] 형태
        XCTAssertEqual(items[1].subscriptions, 77)          // 문자열 "77" → 정수
        XCTAssertEqual(items[1].tags, ["Video"])            // 문자열 배열 형태도 허용
    }

    func testParseLenientOnMissingFields() {
        let json = """
        {"response":{"publishedfiledetails":[
          {"publishedfileid":"333"}
        ]}}
        """.data(using: .utf8)!
        let items = WorkshopResponseParser.parse(json)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "333")
        XCTAssertEqual(items[0].title, "333", "title 누락 시 id 로 폴백")
        XCTAssertNil(items[0].previewURL)
        XCTAssertNil(items[0].subscriptions)
        XCTAssertEqual(items[0].tags, [])
    }

    func testParseDropsEntriesWithoutId() {
        let json = """
        {"response":{"publishedfiledetails":[
          {"title":"no id"}, {"publishedfileid":"","title":"empty id"}, {"publishedfileid":"ok"}
        ]}}
        """.data(using: .utf8)!
        let items = WorkshopResponseParser.parse(json)
        XCTAssertEqual(items.map(\.id), ["ok"])
    }

    func testParseGarbageOrEmptyReturnsEmpty() {
        XCTAssertEqual(WorkshopResponseParser.parse(Data()).count, 0)
        XCTAssertEqual(WorkshopResponseParser.parse("not json".data(using: .utf8)!).count, 0)
        XCTAssertEqual(WorkshopResponseParser.parse("{\"response\":{}}".data(using: .utf8)!).count, 0)
    }

    func testSearchURLRequestsVoteData() {
        let url = WorkshopQuery.searchURL(apiKey: "K", page: 1, numPerPage: 10, searchText: "", sort: .trend)
        XCTAssertEqual(queryDict(url)["return_vote_data"], "true")
    }

    // MARK: - Keychain 저장 OSStatus 처리 — 호출 주입으로 실제 Keychain 없이 검증.

    func testSaveUpdatesExistingItemWithoutDeleteOrAdd() {
        var deleteCalls = 0
        var updateCalls = 0
        var addCalls = 0
        let failure = SteamAPIKeyStore.save(
            "abc123",
            delete: { _ in deleteCalls += 1; return errSecSuccess },
            update: { _, _ in updateCalls += 1; return errSecSuccess },
            add: { _, _ in addCalls += 1; return errSecSuccess }
        )
        XCTAssertNil(failure)
        XCTAssertEqual(deleteCalls, 0)
        XCTAssertEqual(updateCalls, 1)
        XCTAssertEqual(addCalls, 0)
    }

    func testSaveAddsWhenUpdateFindsNoExistingItem() {
        let failure = SteamAPIKeyStore.save(
            "abc123",
            delete: { _ in errSecItemNotFound },
            update: { _, _ in errSecItemNotFound },
            add: { _, _ in errSecSuccess }
        )
        XCTAssertNil(failure)
    }

    func testSaveReportsACLDeniedWhenUpdateIsDenied() {
        let failure = SteamAPIKeyStore.save(
            "abc123",
            delete: { _ in errSecAuthFailed },
            update: { _, _ in errSecAuthFailed },
            add: { _, _ in errSecDuplicateItem }
        )
        XCTAssertEqual(failure, .aclDenied)
        XCTAssertTrue(failure?.message.contains("키체인 접근") == true)
    }

    func testSaveReportsOtherFailureForUnrelatedAddError() {
        let failure = SteamAPIKeyStore.save(
            "abc123",
            delete: { _ in errSecItemNotFound },
            update: { _, _ in errSecItemNotFound },
            add: { _, _ in errSecParam }
        )
        XCTAssertEqual(failure, .other(errSecParam))
    }

    func testClearSucceedsEvenIfDeleteReportsItemNotFound() {
        let failure = SteamAPIKeyStore.save(
            "",
            delete: { _ in errSecItemNotFound },
            update: { _, _ in XCTFail("Clear must not update"); return errSecSuccess },
            add: { _, _ in errSecSuccess }
        )
        XCTAssertNil(failure)
    }

    func testClearReportsFailureWhenDeleteFails() {
        let failure = SteamAPIKeyStore.save(
            "",
            delete: { _ in errSecAuthFailed },
            update: { _, _ in XCTFail("Clear must not update"); return errSecSuccess },
            add: { _, _ in errSecSuccess }
        )
        XCTAssertEqual(failure, .other(errSecAuthFailed))
    }

    func testFailedKeyReplacementPreservesExistingKey() {
        var storedKey: String? = "old-key"
        var addCalls = 0
        let failure = SteamAPIKeyStore.save(
            "new-key",
            delete: { _ in storedKey = nil; return errSecSuccess },
            update: { _, _ in errSecParam },
            add: { _, _ in addCalls += 1; return errSecParam }
        )

        XCTAssertEqual(failure, .other(errSecParam))
        XCTAssertEqual(storedKey, "old-key")
        XCTAssertEqual(addCalls, 0)
    }

    // MARK: - HTTP 오류 메시지 분리(F133) — 429/5xx는 재시도 안내, 인증 오류만 키 확인 안내.

    func testHTTPErrorMessageForRateLimitSuggestsRetryNotKeyCheck() {
        let msg = WorkshopError.http(429).errorDescription ?? ""
        XCTAssertTrue(msg.contains("429"))
        XCTAssertFalse(msg.contains("API 키"), "429(레이트리밋)는 키 오류가 아니므로 키 확인을 안내하면 안 된다")
    }

    func testHTTPErrorMessageForServerErrorSuggestsRetryNotKeyCheck() {
        for code in [500, 502, 503] {
            let msg = WorkshopError.http(code).errorDescription ?? ""
            XCTAssertTrue(msg.contains("\(code)"))
            XCTAssertFalse(msg.contains("API 키"), "5xx(Steam 장애)는 키 오류가 아니므로 키 확인을 안내하면 안 된다")
        }
    }

    func testHTTPErrorMessageForAuthFailureSuggestsKeyCheck() {
        for code in [401, 403] {
            let msg = WorkshopError.http(code).errorDescription ?? ""
            XCTAssertTrue(msg.contains("API 키"), "\(code)는 인증 실패이므로 키 확인 안내가 맞다")
        }
    }

    func testHTTPErrorMessageForOtherCodesOmitsKeyGuidance() {
        let msg = WorkshopError.http(418).errorDescription ?? ""
        XCTAssertTrue(msg.contains("418"))
        XCTAssertFalse(msg.contains("API 키"), "분류되지 않은 코드까지 키 오류로 오도하면 안 된다")
    }

    func testSearchThrowsHTTPErrorForNon2xxStatus() async throws {
        // 종전엔 이 throw 경로(WorkshopClient.search 의 non-2xx → WorkshopError.http) 테스트가 전무했다.
        let client = WorkshopClient { _ in (Data(), 429) }
        do {
            _ = try await client.search(apiKey: "K", searchText: "", sort: .subscriptions)
            XCTFail("429 응답은 throw 해야 한다")
        } catch WorkshopError.http(let code) {
            XCTAssertEqual(code, 429)
        }
    }

    func testParseExtractsVoteScore() {
        let json = """
        {"response":{"publishedfiledetails":[
          {"publishedfileid":"7","title":"T","vote_data":{"score":0.91,"votes_up":10,"votes_down":1}},
          {"publishedfileid":"8","title":"U"}
        ]}}
        """
        let items = WorkshopResponseParser.parse(Data(json.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].voteScore, 0.91)
        XCTAssertNil(items[1].voteScore)
    }
}
