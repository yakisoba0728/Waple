import XCTest
@testable import Waple
import WapleLibrary

/// 감사 V06 회귀 테스트 — Waple 앱 UI 항목. 뷰 레벨 배선(SwiftUI 라이프사이클 의존)은 단위 테스트
/// 대상이 아니며(AppUIFixRegressionTests 헤더 주석 전례), 추출된 순수 로직/주입 가능 경로만 검증한다.
final class AppUIV06RegressionTests: XCTestCase {

    private func entry(_ id: String, tags: [String]? = nil, rating: String? = nil) -> LibraryEntry {
        LibraryEntry(id: id, title: id, typeRaw: "scene", fileName: nil, previewName: nil,
                     bookmark: Data(), tags: tags, contentRating: rating)
    }

    private func applyIds(_ entries: [LibraryEntry], _ c: LibraryFilterCriteria) -> [String] {
        LibraryFiltering.apply(entries, search: "", criteria: c, sort: .recentFirst,
                               isFavorite: { _ in false }).map(\.id)
    }

    // MARK: - 감사 V06(1): 선택 집합 = 그 축의 available 전체 → 무필터

    func testSelectAllTags_isUnfilteredSoUntaggedEntriesStay() {
        // 사이드바 '전체' 버튼은 criteria.tags = Set(availableTags) 를 설정한다 — 이 상태가 필터
        // 활성이면 태그 없는 배경("c")이 전부 숨겨진다(종전 동작).
        let entries = [entry("a", tags: ["Nature"]),
                       entry("b", tags: ["City"]),
                       entry("c")]   // 태그 없음
        var c = LibraryFilterCriteria(); c.tags = ["Nature", "City"]   // available 전체
        XCTAssertEqual(applyIds(entries, c), ["c", "b", "a"],
                       "'전체' 선택은 무필터와 같아야 한다 — 태그 없는 배경도 보여야 함")
    }

    func testPartialTagSelection_stillFiltersUntaggedEntries() {
        // 규칙의 과잉 적용 방지: available 의 일부만 고른 정상 필터는 그대로 동작해야 한다.
        let entries = [entry("a", tags: ["Nature"]),
                       entry("b", tags: ["City"]),
                       entry("c")]
        var c = LibraryFilterCriteria(); c.tags = ["Nature"]
        XCTAssertEqual(applyIds(entries, c), ["a"])
    }

    func testSelectAllRatings_isUnfilteredSoUnratedEntriesStay() {
        // 등급 축의 동일 구조: 개별 토글을 전부 체크하면 contentRating 없는 배경("c")이 사라졌다.
        let entries = [entry("a", rating: "Everyone"),
                       entry("b", rating: "Mature"),
                       entry("c")]   // 등급 없음
        var c = LibraryFilterCriteria(); c.ratings = ["Everyone", "Mature"]   // available 전체
        XCTAssertEqual(applyIds(entries, c), ["c", "b", "a"],
                       "등급 전체 체크는 무필터와 같아야 한다 — 등급 없는 배경도 보여야 함")
    }

    func testPartialRatingSelection_stillFiltersUnratedEntries() {
        let entries = [entry("a", rating: "Everyone"),
                       entry("b", rating: "Mature"),
                       entry("c")]
        var c = LibraryFilterCriteria(); c.ratings = ["Everyone"]
        XCTAssertEqual(applyIds(entries, c), ["a"])
    }

    // MARK: - 감사 V06(2): ColorPicker 커밋 디바운스(editingChanged 없음 대용)

    func testCommitDebouncer_coalescesBurstIntoOne() {
        // 컬러 패널 드래그 중 연속 set 은 마지막 1회만 커밋돼야 한다(setProperty → 전체 리마운트 스톰 방지).
        let d = CommitDebouncer(delay: 0.05, queue: DispatchQueue(label: "waple.test.debounce"))
        let lock = NSLock()
        var count = 0
        for _ in 0..<20 { d.schedule { lock.lock(); count += 1; lock.unlock() } }
        Thread.sleep(forTimeInterval: 0.3)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(count, 1, "연속 예약은 취소·재예약으로 합쳐져 마지막 1회만 실행돼야 한다")
    }

    func testCommitDebouncer_cancelPreventsPendingExecution() {
        // 시트 닫힘 시 즉시 커밋 경로와 중복 실행되지 않도록 취소된 작업은 발화하지 않는다.
        let d = CommitDebouncer(delay: 0.05, queue: DispatchQueue(label: "waple.test.debounce2"))
        let lock = NSLock()
        var count = 0
        d.schedule { lock.lock(); count += 1; lock.unlock() }
        d.cancel()
        Thread.sleep(forTimeInterval: 0.2)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(count, 0)
    }

    // MARK: - 감사 V06(3): 화면 수 기준선 — 첫 '새 디스플레이 감지'가 삼켜지지 않는다

    func testScreenBaseline_firstChangeIsDetected() {
        // 종전 lazy 기준선은 첫 접근(정착 후)에 잡혀 기준선=2 로 시작, 첫 감지가 항상 false 였다.
        var b = ScreenCountBaseline(1)   // 기준선은 실행 시 구성(1대)에서 캡처
        XCTAssertTrue(b.update(settled: 2), "실행 시 1대 → 첫 연결로 2대: 감지돼야 한다")
    }

    func testScreenBaseline_sameOrDecreaseIsNotNewDetection() {
        var b = ScreenCountBaseline(2)
        XCTAssertFalse(b.update(settled: 2), "정착 후 동일 수는 버스트 중간값 — 미감지")
        XCTAssertFalse(b.update(settled: 1), "해제는 '새 디스플레이'가 아니다")
        XCTAssertTrue(b.update(settled: 3), "이후 증가는 다시 감지")
        XCTAssertFalse(b.update(settled: 3), "갱신된 기준선과 같으면 미감지")
    }

    // MARK: - 감사 V06(4): 모니터 할당 표시 순서 — Dictionary 순회가 아니라 키 정렬

    func testSortedAssignedIds_deterministicKeyOrder() {
        let all = ["200": "b", "100": "a", "300": "c"]
        XCTAssertEqual(NowPlayingSubtitle.sortedAssignedIds(all), ["a", "b", "c"],
                       "Dictionary values 순회는 실행마다 달라 표시 배경이 들쭉날쭉했다 — 키 정렬로 고정")
    }

    func testDisplayedEntry_picksLowestScreenKeyDeterministically() {
        let entries = [entry("a"), entry("b")]
        let all = ["200": "b", "100": "a"]
        let picked = NowPlayingSubtitle.displayedEntry(global: nil,
                                                       assignedIds: NowPlayingSubtitle.sortedAssignedIds(all),
                                                       entries: entries)
        XCTAssertEqual(picked?.id, "a", "전역 선택이 없으면 항상 가장 작은 화면 키의 배경을 표시해야 한다")
    }
}
