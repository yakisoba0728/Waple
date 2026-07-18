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

    // MARK: - Keychain 저장 OSStatus 처리(F132) — delete/add 주입으로 실제 Keychain 없이 검증.

    func testSaveSucceedsWhenDeleteAndAddSucceed() {
        let failure = SteamAPIKeyStore.save(
            "abc123",
            delete: { _ in errSecSuccess },
            add: { _, _ in errSecSuccess }
        )
        XCTAssertNil(failure)
    }

    func testSaveSucceedsWhenDeleteFindsNoExistingItem() {
        // 최초 저장: 지울 기존 항목이 없음(errSecItemNotFound) — 정상 경로여야 한다.
        let failure = SteamAPIKeyStore.save(
            "abc123",
            delete: { _ in errSecItemNotFound },
            add: { _, _ in errSecSuccess }
        )
        XCTAssertNil(failure)
    }

    func testSaveReportsACLDeniedWhenDeleteFailsAndAddHitsDuplicate() {
        // 재서명(재빌드) 함정 재현: delete 가 거부돼 실패 → 구항목이 그대로 남아 add 가 errSecDuplicateItem.
        let failure = SteamAPIKeyStore.save(
            "abc123",
            delete: { _ in errSecAuthFailed },
            add: { _, _ in errSecDuplicateItem }
        )
        XCTAssertEqual(failure, .aclDenied)
        XCTAssertTrue(failure?.message.contains("키체인 접근") == true)
    }

    func testSaveReportsOtherFailureForUnrelatedAddError() {
        let failure = SteamAPIKeyStore.save(
            "abc123",
            delete: { _ in errSecItemNotFound },
            add: { _, _ in errSecParam }
        )
        XCTAssertEqual(failure, .other(errSecParam))
    }

    func testClearSucceedsEvenIfDeleteReportsItemNotFound() {
        let failure = SteamAPIKeyStore.save(
            "",
            delete: { _ in errSecItemNotFound },
            add: { _, _ in errSecSuccess }
        )
        XCTAssertNil(failure)
    }

    func testClearReportsFailureWhenDeleteFails() {
        let failure = SteamAPIKeyStore.save(
            "",
            delete: { _ in errSecAuthFailed },
            add: { _, _ in errSecSuccess }
        )
        XCTAssertEqual(failure, .other(errSecAuthFailed))
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
