import XCTest
@testable import Waple
import WapleCore

/// 속성 목록 → 섹션 자르기(순수).
///
/// 이 규칙이 틀리면 화면에서는 "카드가 좀 이상하다" 로만 보이고 원인을 못 찾는다 —
/// 빈 카드가 하나 뜨거나, 원본이 넣은 안내 문구가 조용히 사라진다. 그래서 판정을
/// 뷰 밖으로 빼서 여기서 못 박는다.
final class PropertyGroupingTests: XCTestCase {

    /// `displayOnly` 로 떨어지는 타입(PropertyControl.kind 의 default 갈래).
    private func heading(_ key: String) -> WallpaperProperty {
        WallpaperProperty(key: key, type: "text", value: .string(""), order: nil, condition: nil, text: key)
    }

    private func slider(_ key: String) -> WallpaperProperty {
        WallpaperProperty(key: key, type: "slider", value: .number(0), order: nil, condition: nil,
                          text: key, min: 0, max: 1)
    }

    private func sections(_ props: [WallpaperProperty]) -> [PropertySection] {
        PropertyGrouping.sections(in: props, visible: Array(props.indices))
    }

    func testControlsBeforeAnyHeadingFormAnUntitledSection() {
        let out = sections([slider("a"), slider("b")])
        XCTAssertEqual(out, [PropertySection(title: nil, rows: [0, 1])])
    }

    func testHeadingStartsANewSectionAndOwnsWhatFollows() {
        let out = sections([slider("a"), heading("H"), slider("b"), slider("c")])
        XCTAssertEqual(out, [
            PropertySection(title: nil, rows: [0]),
            PropertySection(title: 1, rows: [2, 3]),
        ])
    }

    /// 첫 속성이 곧 구분 문구인 경우가 흔하다 — 그때 제목도 내용도 없는 선두 덩어리를
    /// 만들면 카드 하나가 빈 채로 뜬다.
    func testLeadingHeadingDoesNotProduceAnEmptyFirstSection() {
        let out = sections([heading("H"), slider("a")])
        XCTAssertEqual(out, [PropertySection(title: 0, rows: [1])])
    }

    /// 뒤에 컨트롤이 없는 displayOnly 는 제목이 아니라 안내 문단이다. 버리면 원본이
    /// 사용자에게 하려던 말이 사라지므로, 빈 rows 로 남겨 호출부가 문단으로 그리게 한다.
    func testTrailingHeadingSurvivesWithNoRows() {
        let out = sections([slider("a"), heading("note")])
        XCTAssertEqual(out, [
            PropertySection(title: nil, rows: [0]),
            PropertySection(title: 1, rows: []),
        ])
    }

    func testConsecutiveHeadingsEachKeepTheirOwnSection() {
        let out = sections([heading("H1"), heading("H2"), slider("a")])
        XCTAssertEqual(out, [
            PropertySection(title: 0, rows: []),
            PropertySection(title: 1, rows: [2]),
        ])
    }

    /// 표시 대상 인덱스만 받는다 — 조건부 숨김·장식 제외를 통과하지 못한 항목은 섹션 구조에
    /// 영향을 주지 않아야 한다(숨겨진 제목이 뒤 컨트롤을 가져가면 카드가 엉뚱하게 갈린다).
    func testInvisibleIndicesAreIgnored() {
        let props = [slider("a"), heading("hidden"), slider("b")]
        let out = PropertyGrouping.sections(in: props, visible: [0, 2])
        XCTAssertEqual(out, [PropertySection(title: nil, rows: [0, 2])])
    }

    func testEmptyInputProducesNoSections() {
        XCTAssertTrue(sections([]).isEmpty)
    }
}
