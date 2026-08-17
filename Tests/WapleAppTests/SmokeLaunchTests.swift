import XCTest
@testable import Waple

/// 스모크 캡처 훅의 배선 오라클.
///
/// `WAPLE_SMOKE` 는 자동 게이트가 아니다 — CI·scripts·Tests 어디에도 참조가 없고, 판정은
/// 사람이 캡처를 보는 수동 절차다. 그래서 UI 개편이 훅을 깨도 **CI 는 초록**이고, 캡처는
/// 계속 나오되 늘 기본 화면만 찍힌다. 그 실패는 스크린샷을 옆에 놓고 비교하기 전에는
/// 아무도 못 알아챈다.
///
/// 기계가 판정할 수 있는 몫(환경변수 → 초기 상태 해석)을 여기로 가져온다. 남는 몫
/// ("보기 좋고 네이티브다운가")은 계속 사람이 본다. 이 분리가 요점이다.
final class SmokeLaunchTests: XCTestCase {

    // MARK: - 1. 스모크가 아닌 실행

    func testEmptyEnvironmentIsNotACapture() {
        let s = SmokeLaunch.state(env: [:])
        XCTAssertFalse(s.isCapture, "일반 실행은 액세서리 앱이어야 한다(Dock 아이콘 없음)")
        XCTAssertFalse(s.opensLibrary)
        XCTAssertFalse(s.focusesFirstEntry)
        XCTAssertFalse(s.showsSidebar)
        XCTAssertFalse(s.showsInspector)
        XCTAssertFalse(s.opensDisplays)
        XCTAssertFalse(s.opensSettings)
        XCTAssertFalse(s.forcesOnboarding)
        XCTAssertFalse(s.suppressesOnboarding, "스모크가 아니면 최초 실행 온보딩을 막을 이유가 없다")
        XCTAssertNil(s.selection)
        XCTAssertNil(s.unrecognizedTab)
    }

    /// 관계없는 변수가 있어도 스모크로 오인하지 않는다(접두사 매칭이 너무 넓지 않은가).
    func testUnrelatedEnvironmentIsIgnored() {
        let s = SmokeLaunch.state(env: ["HOME": "/tmp", "WAPLE_REAL_PKGS": "/x", "SMOKE": "1"])
        XCTAssertFalse(s.isCapture)
        XCTAssertFalse(s.suppressesOnboarding)
    }

    // MARK: - 2. WAPLE_SMOKE=1 전체 배선

    func testSmokeOpensLibraryWithBothColumns() {
        let s = SmokeLaunch.state(env: ["WAPLE_SMOKE": "1"])
        XCTAssertTrue(s.isCapture)
        XCTAssertTrue(s.opensLibrary)
        XCTAssertTrue(s.focusesFirstEntry, "인스펙터가 채워진 상태로 찍혀야 판정이 된다")
        XCTAssertTrue(s.showsSidebar, "좌열이 없으면 네비게이션 이관을 눈으로 판정할 수 없다")
        XCTAssertTrue(s.showsInspector, "종전 showFilters(좌측 필터 노출)의 자리를 승계한다")
        XCTAssertTrue(s.suppressesOnboarding, "온보딩 시트가 화면을 가리면 캡처가 무의미하다")
        XCTAssertFalse(s.forcesOnboarding)
        XCTAssertNil(s.selection, "TAB 미지정 = 기본(라이브러리 > 전체)")
    }

    // MARK: - 3. WAPLE_SMOKE_TAB 세 값

    func testTabValuesMapToSidebarSelections() {
        let cases: [(String, LibrarySelection)] = [
            ("installed", .all),
            ("discover", .discover),
            ("workshop", .workshopSearch),
        ]
        for (raw, expected) in cases {
            let s = SmokeLaunch.state(env: ["WAPLE_SMOKE": "1", "WAPLE_SMOKE_TAB": raw])
            XCTAssertEqual(s.selection, expected, "WAPLE_SMOKE_TAB=\(raw)")
            XCTAssertNil(s.unrecognizedTab, "WAPLE_SMOKE_TAB=\(raw) 는 알려진 값이다")
        }
    }

    /// 값은 종전 MainTab.rawValue 를 그대로 쓴다 — 이름을 바꾸면 docs/history 의 절차와
    /// 사용자의 손 기억이 어긋나는데, 고쳐줄 스크립트가 어디에도 없다.
    func testTabVocabularyIsUnchangedFromTheSegmentedEra() {
        XCTAssertEqual(SmokeLaunch.selection(tab: "discover"), .discover)
        XCTAssertEqual(SmokeLaunch.selection(tab: "workshop"), .workshopSearch)
        XCTAssertNil(SmokeLaunch.selection(tab: "Discover"), "대소문자는 관용하지 않는다")
    }

    // MARK: - 4. 알 수 없는 값은 조용히 무시하지 않는다

    func testUnknownTabFallsBackButIsReported() {
        let s = SmokeLaunch.state(env: ["WAPLE_SMOKE": "1", "WAPLE_SMOKE_TAB": "libary"])
        XCTAssertNil(s.selection, "기본으로 폴백한다")
        XCTAssertEqual(s.unrecognizedTab, "libary",
                       "오타 원문을 실어 보내야 호출부가 로그로 남긴다 — 안 그러면 오타난 캡처가 "
                        + "기본 화면을 찍고 조용히 통과한다")
        XCTAssertTrue(s.isCapture, "값이 틀려도 캡처 자체는 진행한다(찍은 뒤 로그로 알린다)")
    }

    // MARK: - 5. 설정·온보딩은 단독으로도 캡처 정책을 켠다

    func testSettingsAndOnboardingEnableCaptureOnTheirOwn() {
        XCTAssertTrue(SmokeLaunch.state(env: ["WAPLE_SMOKE_SETTINGS": "1"]).isCapture)
        XCTAssertTrue(SmokeLaunch.state(env: ["WAPLE_SMOKE_SETTINGS": "1"]).opensSettings)
        XCTAssertTrue(SmokeLaunch.state(env: ["WAPLE_SMOKE_ONBOARDING": "1"]).isCapture)
    }

    /// 반대로 `_TAB`·`_DISPLAYS` 는 단독으로 창을 띄우지 않는다 — 종전 규약 그대로다.
    /// (이 둘만 주고 실행하면 창이 안 떠서 캡처가 실패하는데, 그게 의도된 동작이다.)
    func testTabAndDisplaysAloneDoNotOpenAnything() {
        let tabOnly = SmokeLaunch.state(env: ["WAPLE_SMOKE_TAB": "discover"])
        XCTAssertFalse(tabOnly.isCapture)
        XCTAssertFalse(tabOnly.opensLibrary)
        XCTAssertEqual(tabOnly.selection, .discover, "해석 자체는 한다 — 창을 안 띄울 뿐이다")

        let displaysOnly = SmokeLaunch.state(env: ["WAPLE_SMOKE_DISPLAYS": "1"])
        XCTAssertFalse(displaysOnly.isCapture)
        XCTAssertFalse(displaysOnly.opensLibrary)
        XCTAssertTrue(displaysOnly.opensDisplays)
    }

    func testDisplaysSheetOpensWithSmoke() {
        let s = SmokeLaunch.state(env: ["WAPLE_SMOKE": "1", "WAPLE_SMOKE_DISPLAYS": "1"])
        XCTAssertTrue(s.isCapture)
        XCTAssertTrue(s.opensLibrary)
        XCTAssertTrue(s.opensDisplays)
    }

    // MARK: - 6. 온보딩: 하나는 강제, 나머지는 억제

    func testOnboardingIsForcedByItsOwnVariableAndSuppressedByEveryOther() {
        let forced = SmokeLaunch.state(env: ["WAPLE_SMOKE_ONBOARDING": "1"])
        XCTAssertTrue(forced.forcesOnboarding)
        XCTAssertFalse(forced.suppressesOnboarding, "강제와 억제가 동시에 참이면 안 된다")
        XCTAssertTrue(forced.opensLibrary, "시트를 얹을 창이 먼저 떠야 한다")

        for key in ["WAPLE_SMOKE", "WAPLE_SMOKE_SETTINGS", "WAPLE_SMOKE_TAB", "WAPLE_SMOKE_DISPLAYS"] {
            let s = SmokeLaunch.state(env: [key: "1"])
            XCTAssertTrue(s.suppressesOnboarding, "\(key) 실행에서 온보딩 시트가 캡처를 가리면 안 된다")
            XCTAssertFalse(s.forcesOnboarding, key)
        }
    }

    /// 강제와 다른 스모크 변수를 함께 준 경우 — 강제가 이긴다(온보딩 캡처가 목적이므로).
    func testForcedOnboardingWinsOverSuppression() {
        let s = SmokeLaunch.state(env: ["WAPLE_SMOKE": "1", "WAPLE_SMOKE_ONBOARDING": "1"])
        XCTAssertTrue(s.forcesOnboarding)
        XCTAssertFalse(s.suppressesOnboarding)
    }
}
