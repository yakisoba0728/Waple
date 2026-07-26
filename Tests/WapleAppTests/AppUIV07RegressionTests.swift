import XCTest
@testable import Waple
import WapleLibrary

/// 감사 V07 회귀 테스트 — Waple 앱 UI 항목. V06 와 동일하게 뷰 레벨 배선은 단위 테스트 대상이
/// 아니며, 추출된 순수 로직(LibraryFiltering)만 검증한다.
final class AppUIV07RegressionTests: XCTestCase {

    private func entry(_ id: String, typeRaw: String) -> LibraryEntry {
        LibraryEntry(id: id, title: id, typeRaw: typeRaw, fileName: nil, previewName: nil,
                     bookmark: Data(), tags: nil, contentRating: nil)
    }

    private func applyIds(_ entries: [LibraryEntry], _ c: LibraryFilterCriteria) -> [String] {
        LibraryFiltering.apply(entries, search: "", criteria: c, sort: .recentFirst,
                               isFavorite: { _ in false }).map(\.id)
    }

    // MARK: - 감사 V07(1): 유형 축도 "선택 집합 = 그 축의 available 전체 → 무필터"(감사 V06 과 동일 규약)

    func testSelectAllTypes_isUnfilteredSoAllMappedEntriesStay() {
        // 사이드바 유형 토글은 scene/video/web 3종 — 전부 체크하면 criteria.types 가 그 3종이 된다.
        // 종전엔 이 상태도 필터 활성이라 entryType 이 .all 로 매핑되는 배경(preset 등, "d")이 숨겨졌다.
        let entries = [entry("a", typeRaw: "scene"),
                       entry("b", typeRaw: "video"),
                       entry("c", typeRaw: "web"),
                       entry("d", typeRaw: "preset")]   // .all 매핑 — 사이드바에 토글 없음
        var c = LibraryFilterCriteria(); c.types = [.scene, .video, .web]   // available 전체
        XCTAssertEqual(applyIds(entries, c), ["d", "c", "b", "a"],
                       "유형 3종 전체 체크는 무필터와 같아야 한다 — .all 매핑 배경도 보여야 함")
    }

    func testPartialTypeSelection_stillFiltersAllMappedEntries() {
        // 규칙의 과잉 적용 방지: 3종 중 일부만 고른 정상 필터는 그대로 동작해야 한다(.all 매핑은 미표시).
        let entries = [entry("a", typeRaw: "scene"),
                       entry("b", typeRaw: "video"),
                       entry("d", typeRaw: "preset")]
        var c = LibraryFilterCriteria(); c.types = [.scene]
        XCTAssertEqual(applyIds(entries, c), ["a"])
    }
}
