import XCTest
import WapleLibrary
@testable import Waple

final class LibraryFilteringTests: XCTestCase {
    private func entry(_ id: String, _ title: String, _ type: String,
                       tags: [String] = [], rating: String? = nil) -> LibraryEntry {
        LibraryEntry(id: id, title: title, typeRaw: type, fileName: nil, previewName: nil,
                     bookmark: Data(), tags: tags, contentRating: rating)
    }
    private var sample: [LibraryEntry] {
        [entry("1", "바다", "scene", tags: ["Nature"], rating: "Everyone"),
         entry("2", "Alps", "video", tags: ["Nature", "4K"], rating: "Everyone"),
         entry("3", "네온", "web", tags: ["City"], rating: "Mature"),
         entry("4", "바다 야경", "video", tags: ["City"])]
    }
    private func apply(_ search: String = "", _ c: LibraryFilterCriteria = .init(),
                       sort: LibrarySortOrder = .recentFirst,
                       favorites: Set<String> = []) -> [String] {
        LibraryFiltering.apply(sample, search: search, criteria: c, sort: sort,
                               isFavorite: { favorites.contains($0) }).map(\.id)
    }

    func testNoCriteriaKeepsAll() { XCTAssertEqual(apply(), ["4", "3", "2", "1"]) }
    func testNameSortLocaleIndependent() {
        XCTAssertEqual(apply("", .init(), sort: .name), ["2", "3", "1", "4"])  // Alps, 네온, 바다, 바다 야경
    }
    func testSearchComposesWithType() {
        var c = LibraryFilterCriteria(); c.types = [.video]
        XCTAssertEqual(apply("바다", c), ["4"])
    }
    func testTypeMultiSelect() {
        var c = LibraryFilterCriteria(); c.types = [.video, .web]
        XCTAssertEqual(apply("", c), ["4", "3", "2"])
    }
    func testTagFilterAnyMatch() {
        var c = LibraryFilterCriteria(); c.tags = ["City"]
        XCTAssertEqual(apply("", c), ["4", "3"])
    }

    // MARK: - 검색이 태그·유형 라벨까지 매칭 (w5d-library)

    func testSearchMatchesTagCaseInsensitive() {
        // "Nature" 태그를 가진 1·2 만 매칭 — 제목("바다"/"Alps")은 무관.
        XCTAssertEqual(apply("nature"), ["2", "1"])
    }
    func testSearchMatchesLocalizedTypeLabel() {
        // "동영상" = video 의 지역화 라벨 — 2·4 매칭(제목엔 없음).
        XCTAssertEqual(apply("동영상"), ["4", "2"])
    }
    func testSearchTitleStillTakesPrecedenceComposition() {
        // 태그 매칭 추가가 기존 제목 매칭 결과를 깨지 않는지(교집합 아님 — 합집합).
        XCTAssertEqual(apply("바다"), ["4", "1"])
    }
    func testRatingFilterTreatsNilAsNoMatch() {
        var c = LibraryFilterCriteria(); c.ratings = ["Everyone"]
        XCTAssertEqual(apply("", c), ["2", "1"])
    }
    func testFavoritesOnly() {
        var c = LibraryFilterCriteria(); c.favoritesOnly = true
        XCTAssertEqual(apply("", c, favorites: ["3"]), ["3"])
    }
    // MARK: - 검색/필터 무결과 dead-end 판정 (w5d-library)

    func testDeadEndWhenSearchActiveAndZeroResults() {
        XCTAssertTrue(LibraryFiltering.isSearchOrFilterDeadEnd(
            searchText: "존재하지않음", criteria: .init(), filteredCount: 0))
    }
    func testNotDeadEndWhenSearchActiveButHasResults() {
        XCTAssertFalse(LibraryFiltering.isSearchOrFilterDeadEnd(
            searchText: "바다", criteria: .init(), filteredCount: 1))
    }
    func testNotDeadEndWhenNoSearchOrFilterActive() {
        // 빈 폴더 탐색 등 — 필터/검색이 애초에 꺼져 있으면 dead-end 판정 대상이 아니다.
        XCTAssertFalse(LibraryFiltering.isSearchOrFilterDeadEnd(
            searchText: "", criteria: .init(), filteredCount: 0))
    }
    func testDeadEndWhenOnlyCriteriaActiveAndZeroResults() {
        var c = LibraryFilterCriteria(); c.favoritesOnly = true
        XCTAssertTrue(LibraryFiltering.isSearchOrFilterDeadEnd(searchText: "", criteria: c, filteredCount: 0))
    }

    /// 2026-08-17: 루트가 폴더 소속 항목을 **감추지 않는다**로 바뀌었다.
    ///
    /// 종전 단언은 WE 디렉터리 모델(루트 = 미소속 항목)이었고, 그건 그리드에 폴더 타일이
    /// 있다는 전제로만 성립했다. 폴더가 사이드바로 올라가고 타일이 사라진 뒤에는 루트에서
    /// 걸러낸 항목이 그리드 어디에도 안 나온다 — 전부 폴더에 넣은 사용자는 '전체' 에서
    /// 아무 안내도 없는 빈 화면을 보게 된다. 근거 전문은 `LibraryFolders` 주석.
    func testRootShowsEveryEntryIncludingFolderedOnes() {
        let folders = [FolderStore.Folder(name: "메인", ids: ["1", "3"])]
        XCTAssertEqual(LibraryFolders.scoped(sample, folders: folders, active: nil).map(\.id),
                       sample.map(\.id))
    }

    func testActiveFolderNarrowsToItsMembers() {
        let folders = [FolderStore.Folder(name: "메인", ids: ["1", "3"])]
        XCTAssertEqual(LibraryFolders.scoped(sample, folders: folders, active: "메인").map(\.id),
                       ["1", "3"])
    }

    /// 사이드바가 지운 폴더를 아직 가리키고 있는 상태(경합) — 조용히 전체를 보여주면
    /// 좌측 강조와 내용이 어긋난다. 없는 폴더는 0건이 맞다.
    func testUnknownActiveFolderYieldsNothing() {
        XCTAssertTrue(LibraryFolders.scoped(sample, folders: [], active: "없는폴더").isEmpty)
    }
}
