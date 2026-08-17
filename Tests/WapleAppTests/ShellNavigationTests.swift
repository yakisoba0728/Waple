import XCTest
@testable import Waple

/// 사이드바 선택 ↔ 라이브러리 필터 상태의 순수 변환 오라클.
///
/// 이 변환이 어긋나면 화면이 **거짓말을 한다** — 사이드바는 "씬" 을 강조하는데 그리드에는
/// 웹까지 보이는 식이다. 캡처를 눈으로 봐도 잘 안 걸리는 종류의 불일치라 기계가 잡아야 한다.
/// 특히 쓰기 주체가 둘이라(사이드바 + 툴바 필터 팝오버) 한쪽만 보고 만들면 반드시 갈라진다.
final class ShellNavigationTests: XCTestCase {

    private let everySelection: [LibrarySelection] = [
        .all, .scene, .video, .web, .favorites, .folder("밤"), .discover, .workshopSearch,
    ]

    // MARK: - 표면

    func testOnlyWorkshopSelectionsLeaveTheLibrarySurface() {
        XCTAssertEqual(LibrarySection.surface(for: .discover), .discover)
        XCTAssertEqual(LibrarySection.surface(for: .workshopSearch), .workshopSearch)
        for selection in [LibrarySelection.all, .scene, .video, .web, .favorites, .folder("밤")] {
            XCTAssertEqual(LibrarySection.surface(for: selection), .library, "\(selection)")
        }
    }

    // MARK: - 선택 → 상태

    func testTypeSelectionsSetExactlyOneType() {
        let base = ShellState()
        XCTAssertEqual(LibrarySection.applying(.scene, to: base).criteria.types, [.scene])
        XCTAssertEqual(LibrarySection.applying(.video, to: base).criteria.types, [.video])
        XCTAssertEqual(LibrarySection.applying(.web, to: base).criteria.types, [.web])
        XCTAssertEqual(LibrarySection.applying(.all, to: base).criteria.types, [],
                       "'전체'는 유형 무필터다 — 세 유형을 다 켜는 것이 아니다")
    }

    func testFavoritesIsItsOwnAxis() {
        let favorites = LibrarySection.applying(.favorites, to: ShellState())
        XCTAssertTrue(favorites.criteria.favoritesOnly)
        XCTAssertEqual(favorites.criteria.types, [], "즐겨찾기는 유형과 직교한다")

        // 즐겨찾기에서 유형으로 이동하면 즐겨찾기가 꺼진다 — 사이드바는 한 행만 선택되므로
        // 두 축이 동시에 켜진 상태는 사이드바로 표현할 수 없다.
        let thenScene = LibrarySection.applying(.scene, to: favorites)
        XCTAssertFalse(thenScene.criteria.favoritesOnly)
        XCTAssertEqual(thenScene.criteria.types, [.scene])
    }

    func testFolderSelectionSetsFolderAndClearsTypeFilter() {
        let scene = LibrarySection.applying(.scene, to: ShellState())
        let folder = LibrarySection.applying(.folder("밤"), to: scene)
        XCTAssertEqual(folder.folder, "밤")
        XCTAssertEqual(folder.criteria.types, [])
        XCTAssertFalse(folder.criteria.favoritesOnly)

        let backToAll = LibrarySection.applying(.all, to: folder)
        XCTAssertNil(backToAll.folder, "라이브러리 상위 항목으로 가면 폴더 스코프가 풀린다")
    }

    /// 사이드바가 다루지 않는 축(태그·나이 등급)은 보존한다. 지우면 "씬을 눌렀더니 걸어둔
    /// 태그가 사라지는" 동작이 된다.
    func testTagAndRatingFiltersSurviveSidebarNavigation() {
        var criteria = LibraryFilterCriteria()
        criteria.tags = ["Anime"]
        criteria.ratings = ["Everyone"]
        let base = ShellState(surface: .library, criteria: criteria, folder: nil)

        for selection in everySelection {
            let next = LibrarySection.applying(selection, to: base)
            XCTAssertEqual(next.criteria.tags, ["Anime"], "\(selection)")
            XCTAssertEqual(next.criteria.ratings, ["Everyone"], "\(selection)")
        }
    }

    /// 창작마당에 다녀와도 라이브러리 자리가 그대로여야 한다.
    func testWorkshopSelectionsPreserveLibraryState() {
        let inFolder = LibrarySection.applying(.folder("밤"), to: ShellState())
        let discover = LibrarySection.applying(.discover, to: inFolder)
        XCTAssertEqual(discover.surface, .discover)
        XCTAssertEqual(discover.folder, "밤", "둘러보기가 라이브러리 폴더 스코프를 지우면 안 된다")

        let back = LibrarySection.applying(.folder("밤"), to: discover)
        XCTAssertEqual(back.surface, .library)
        XCTAssertEqual(back.folder, "밤")
    }

    // MARK: - 상태 → 선택 (왕복)

    func testEverySelectionRoundTrips() {
        for selection in everySelection {
            let state = LibrarySection.applying(selection, to: ShellState())
            XCTAssertEqual(LibrarySection.selection(for: state), selection,
                           "\(selection) 을 적용한 상태에서 같은 행이 다시 유도돼야 한다")
        }
    }

    func testDefaultStateSelectsAll() {
        XCTAssertEqual(LibrarySection.selection(for: ShellState()), .all)
    }

    /// 툴바 필터가 사이드바로 표현할 수 없는 조합을 만들면 아무 행도 강조하지 않는다.
    /// 틀린 행을 강조하는 것보다 낫다.
    func testCombinationsTheSidebarCannotExpressSelectNothing() {
        var multiType = LibraryFilterCriteria()
        multiType.types = [.scene, .web]
        XCTAssertNil(LibrarySection.selection(for: ShellState(criteria: multiType)))

        var favoritesPlusType = LibraryFilterCriteria()
        favoritesPlusType.favoritesOnly = true
        favoritesPlusType.types = [.video]
        XCTAssertNil(LibrarySection.selection(for: ShellState(criteria: favoritesPlusType)))

        var wildcardType = LibraryFilterCriteria()
        wildcardType.types = [.all]
        XCTAssertNil(LibrarySection.selection(for: ShellState(criteria: wildcardType)),
                     "'.all' 은 필터 열거의 무필터 값이지 사이드바 행이 아니다")
    }

    /// 태그만 걸린 상태는 여전히 '전체' 행이다 — 태그는 사이드바 축이 아니므로 유도에 끼지 않는다.
    func testTagOnlyFilterStillSelectsAll() {
        var criteria = LibraryFilterCriteria()
        criteria.tags = ["Anime"]
        XCTAssertEqual(LibrarySection.selection(for: ShellState(criteria: criteria)), .all)
    }

    func testFolderWinsOverTypeWhenBothSomehowSet() {
        var criteria = LibraryFilterCriteria()
        criteria.types = [.scene]
        let state = ShellState(surface: .library, criteria: criteria, folder: "밤")
        XCTAssertEqual(LibrarySection.selection(for: state), .folder("밤"))
    }

    func testWorkshopSurfacesSelectTheirOwnRowRegardlessOfLibraryState() {
        var criteria = LibraryFilterCriteria()
        criteria.types = [.scene]
        let discover = ShellState(surface: .discover, criteria: criteria, folder: "밤")
        XCTAssertEqual(LibrarySection.selection(for: discover), .discover)
        let workshop = ShellState(surface: .workshopSearch, criteria: criteria, folder: "밤")
        XCTAssertEqual(LibrarySection.selection(for: workshop), .workshopSearch)
    }
}
