import XCTest
import WapleLibrary
@testable import Waple

final class LibraryFilteringTests: XCTestCase {
    private func entry(_ id: String, _ title: String, _ type: String) -> LibraryEntry {
        LibraryEntry(id: id, title: title, typeRaw: type, fileName: nil, previewName: nil, bookmark: Data())
    }
    private var sample: [LibraryEntry] {
        [entry("1", "바다", "scene"), entry("2", "Alps", "video"), entry("3", "네온", "web"),
         entry("4", "바다 야경", "video")]
    }

    func testRecentFirstIsReversedInsertionOrder() {
        let out = LibraryFiltering.apply(sample, search: "", type: .all, sort: .recentFirst)
        XCTAssertEqual(out.map(\.id), ["4", "3", "2", "1"])
    }
    func testNameSortUsesLocalizedCompare() {
        let out = LibraryFiltering.apply(sample, search: "", type: .all, sort: .name)
        XCTAssertEqual(out.map(\.title), ["Alps", "네온", "바다", "바다 야경"])
    }
    func testSearchMatchesTitleCaseInsensitive() {
        XCTAssertEqual(LibraryFiltering.apply(sample, search: "바다", type: .all, sort: .name).count, 2)
        XCTAssertEqual(LibraryFiltering.apply(sample, search: "alps", type: .all, sort: .name).map(\.id), ["2"])
    }
    func testTypeFilter() {
        XCTAssertEqual(LibraryFiltering.apply(sample, search: "", type: .video, sort: .recentFirst).map(\.id), ["4", "2"])
        XCTAssertEqual(LibraryFiltering.apply(sample, search: "", type: .web, sort: .recentFirst).map(\.id), ["3"])
    }
    func testSearchAndTypeCompose() {
        XCTAssertEqual(LibraryFiltering.apply(sample, search: "바다", type: .video, sort: .recentFirst).map(\.id), ["4"])
    }
}
