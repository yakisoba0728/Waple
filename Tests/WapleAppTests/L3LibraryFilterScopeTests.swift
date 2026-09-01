import XCTest
import WapleLibrary
@testable import Waple

/// r3-M24 — 폴더를 고르면 태그·나이등급 필터가 조용히 무필터로 무너지던 결함의 오라클.
///
/// 기전: "선택 집합이 그 축의 available 전체를 덮으면 무필터" 규칙(감사 V06)의 **모집단**을
/// `LibraryFiltering.apply` 가 입력 엔트리에서 유도했다. 그런데 폴더를 고르면 입력은
/// `LibraryFolders.scoped` 를 거친 **폴더 범위**이고, 사용자가 고른 태그는 팝오버가 나열한
/// **전체 엔트리** 기준이다. 좁아진 모집단은 `isSuperset(of:)` 를 쉽게 만족해 축이 통째로
/// 건너뛰어진다. 새 `availableTags`/`availableRatings` 인자가 그 모집단을 호출부에서 받는다.
///
/// 별도 파일인 이유는 같은 라운드에서 여러 레인이 동시에 고치고 있어서다 —
/// 내용상 형제는 `LibraryFilteringTests` 다.
final class L3LibraryFilterScopeTests: XCTestCase {
    private func entry(_ id: String, _ title: String, _ type: String,
                       tags: [String] = [], rating: String? = nil) -> LibraryEntry {
        LibraryEntry(id: id, title: title, typeRaw: type, fileName: nil, previewName: nil,
                     bookmark: Data(), tags: tags, contentRating: rating)
    }

    /// 라이브러리 전체는 태그 두 종(Nature·City)인데 폴더 안에는 Nature 만 있다.
    /// 사용자가 팝오버에서 Nature 하나만 골랐으므로 그 축은 **살아 있어야** 한다.
    func testTagFilterSurvivesFolderScope() {
        let all = [entry("1", "바다", "scene", tags: ["Nature"]),
                   entry("2", "네온", "web", tags: ["City"]),
                   entry("3", "숲", "scene", tags: ["Nature"]),
                   entry("4", "무태그", "video")]
        let scoped = [all[0], all[3]]   // 폴더 안 = Nature 하나 + 태그 없는 것 하나
        var criteria = LibraryFilterCriteria()
        criteria.tags = ["Nature"]

        // 모집단을 안 주면 종전 동작: scoped 의 태그 집합이 {Nature} 라 선택이 superset →
        // 축이 건너뛰어져 태그 없는 "4" 까지 남는다.
        let collapsed = LibraryFiltering.apply(scoped, search: "", criteria: criteria,
                                               sort: .recentFirst, isFavorite: { _ in false })
        XCTAssertEqual(collapsed.map(\.id), ["4", "1"])

        // 팝오버와 같은 모집단(전체 엔트리)을 주면 축이 살아 있다.
        let fixed = LibraryFiltering.apply(scoped, search: "", criteria: criteria,
                                           sort: .recentFirst, isFavorite: { _ in false },
                                           availableTags: Set(all.flatMap { $0.tags ?? [] }))
        XCTAssertEqual(fixed.map(\.id), ["1"])
    }

    /// 나이등급 축도 같은 규약. 폴더 안에 Everyone 만 있어도 전체에 Mature 가 있으면 필터가 산다.
    func testRatingFilterSurvivesFolderScope() {
        let all = [entry("1", "바다", "scene", rating: "Everyone"),
                   entry("2", "네온", "web", rating: "Mature"),
                   entry("3", "무등급", "video")]
        let scoped = [all[0], all[2]]
        var criteria = LibraryFilterCriteria()
        criteria.ratings = ["Everyone"]

        let fixed = LibraryFiltering.apply(scoped, search: "", criteria: criteria,
                                           sort: .recentFirst, isFavorite: { _ in false },
                                           availableRatings: Set(all.compactMap(\.contentRating)))
        XCTAssertEqual(fixed.map(\.id), ["1"])
    }

    /// 모집단 전체를 고른 경우는 종전 규약 그대로 **무필터**다(감사 V06 무회귀) —
    /// 태그가 없는 배경도 숨기지 않는다.
    func testSelectingEveryAvailableTagStaysUnfiltered() {
        let all = [entry("1", "바다", "scene", tags: ["Nature"]),
                   entry("2", "네온", "web", tags: ["City"]),
                   entry("3", "무태그", "video")]
        var criteria = LibraryFilterCriteria()
        criteria.tags = ["Nature", "City"]

        let out = LibraryFiltering.apply(all, search: "", criteria: criteria,
                                         sort: .recentFirst, isFavorite: { _ in false },
                                         availableTags: Set(all.flatMap { $0.tags ?? [] }))
        XCTAssertEqual(out.map(\.id), ["3", "2", "1"])
    }
}
