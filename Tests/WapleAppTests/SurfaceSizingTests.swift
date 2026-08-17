import XCTest
@testable import Waple

/// 시트·창이 **콘텐츠의 이상 크기에 끌려다니지 않는지** 지키는 오라클(Unit D).
///
/// ## 왜 소스 스캔인가
///
/// 이 저장소의 앱 테스트는 SwiftUI 뷰를 하나도 인스턴스화하지 않는다 — 레이아웃을 어떻게
/// 바꾸든 전부 초록이다(청사진 §7.4). 그래서 `LocalizationCoverageTests`·`UIConventionTests`
/// 와 같은 방식으로, **기계가 판정할 수 있는 만큼만** 소스 텍스트에서 가져간다.
/// 실제 창 크기는 사람이 캡처로 봐야 하고, 아래 두 결함도 그렇게 발견됐다.
///
/// ## 무엇을 막는가 — 둘 다 실측된 결함이다
///
/// **디스플레이 시트(청사진 §9.1).** `ScrollView` 는 스크롤 축의 이상 크기로 콘텐츠의 이상
/// 크기를 그대로 위로 전파한다. 하단 배경 레일이 가로 스크롤이라, 루트가 자기 이상 폭을
/// 말하지 않으면 **라이브러리 항목 수가 시트 폭을 정한다.** 2026-08-17 실측: 같은 빌드에서
/// 200개 → `1800×560`(화면 폭에 걸려 잘림), 5개 → `860×560`. 항목 수만 바꿔 재현했다.
///
/// **설정 창(청사진 §9.2).** 반대 방향의 같은 병이다. 뷰가 창 높이를 프레임에 못 박으면
/// 그 경직된 요구가 **창이 요청한 크기를 이긴다.** 2026-08-17 실측(창에 `.resizable` +
/// 콘텐츠 높이 1000 을 임시로 주고 대조): 고정 높이를 둔 뷰는 창을 `560x848` 로 되돌리고,
/// 걷어낸 뷰는 `560x1028` 로 열려 6개 섹션이 전부 보였다. 즉 창 쪽만 고쳐서는 아무 것도
/// 달라지지 않고, 뷰가 먼저 놓아 주어야 한다.
///
/// (청사진 §9.2 의 "잘려서 도달 불가" 는 정정한다. 스크롤바를 항상 보이게 켜고 찍으면
/// 종전 빌드에도 트랙이 있고 썸이 트랙의 약 86%(= 820/953)다 — grouped `Form` 은 스스로
/// 스크롤한다. 문제는 도달 불가가 아니라 창을 키워 한눈에 볼 수 없다는 것이었다.)
///
/// 답은 하나다 — **루트가 자기 이상 크기를 말하되 그 이상으로 경직되지 않는다.**
final class SurfaceSizingTests: XCTestCase {

    /// 리포 루트 — 테스트 바이너리는 .build 안이라 소스 파일 위치에서 거슬러 올라간다.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent("Sources/Waple").appendingPathComponent(relative)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(text.count, 500, "\(relative) 를 못 읽었다 — 경로 규약이 바뀌었나?")
        return text
    }

    private func matches(_ pattern: String, in text: String) throws -> Int {
        let rx = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        return rx.numberOfMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    }

    // MARK: - 디스플레이 시트

    /// 루트 프레임 하나가 이상 폭과 이상 높이를 **함께** 말해야 한다.
    ///
    /// 선언만 남기고 호출을 지우면 결함이 그대로 돌아오므로, 상수 이름이 아니라
    /// **`frame` 호출 안에 둘 다 있는지**를 본다.
    func testDisplaysSheetRootDeclaresItsOwnIdealSize() throws {
        let text = try source("Surfaces/Displays/DisplaysView.swift")
        let count = try matches(#"\.frame\([^)]*idealWidth:[^)]*idealHeight:[^)]*\)"#, in: text)
        XCTAssertEqual(count, 1,
                       "디스플레이 시트 루트가 이상 크기를 스스로 말해야 한다. 없으면 하단 레일의 "
                        + "콘텐츠 폭(항목 수 × 타일 폭)이 시트 폭이 된다 — 200개에서 1800pt 로 실측됐다.")
    }

    /// 모달 시트가 부모 창보다 커서는 안 된다. 상한은 부모의 **최소** 크기여야 —
    /// 사용자가 창을 최소까지 줄여 놓은 상태에서 시트를 열어도 넘치지 않는다.
    func testDisplaysSheetNeverOutgrowsTheSmallestParentWindow() {
        XCTAssertLessThanOrEqual(DisplaysView.idealWidth, DisplaysView.maxWidth)
        XCTAssertLessThanOrEqual(DisplaysView.idealHeight, DisplaysView.maxHeight)
        XCTAssertLessThanOrEqual(DisplaysView.maxWidth, Metrics.windowMin.width,
                                 "시트 상한이 부모 최소 폭을 넘으면 다시 부모 밖으로 삐져나온다")
        XCTAssertLessThanOrEqual(DisplaysView.maxHeight, Metrics.windowMin.height)
        XCTAssertGreaterThanOrEqual(DisplaysView.idealWidth, Metrics.displaysMin.width,
                                    "이상 폭이 최소 폭보다 작으면 최소 폭이 이겨 이상값이 죽은 값이 된다")
        XCTAssertGreaterThanOrEqual(DisplaysView.idealHeight, Metrics.displaysMin.height)
    }

    // MARK: - 설정 창

    /// 창 높이를 프레임에 못 박으면 창이 커져도 뷰가 따라오지 않는다 — 창 쪽 수정이
    /// 무력화된다. 높이는 최소·이상·최대로만 말한다.
    func testSettingsDoesNotPinItsWindowHeight() throws {
        let text = try source("Surfaces/Settings/SettingsView.swift")
        XCTAssertEqual(try matches(#"\.frame\([^)]*height:\s*Metrics\.settingsSize\.height"#, in: text), 0,
                       "고정 높이로 되돌아갔다 — 창에 .resizable 을 줘도 560x848 로 되돌아간다(실측)")
        XCTAssertEqual(try matches(#"\.frame\([^)]*minHeight:[^)]*idealHeight:[^)]*maxHeight:[^)]*\)"#, in: text), 1,
                       "최소·이상·최대를 함께 말해야 한다. 이상값이 없으면 이번엔 반대로 "
                        + "콘텐츠 전체 높이가 창 높이로 전파돼 작은 화면에서 창이 화면 밖까지 자란다")
    }

    // MARK: - 온보딩 시트

    /// 3행짜리 체크리스트에 고정 430pt 를 주면 아래 약 40% 가 빈 칸으로 남는다(2026-08-17 캡처).
    /// 세로는 콘텐츠가 정하고, 큰 글씨에서 넘칠 때만 스크롤한다(F090).
    func testOnboardingHeightFollowsItsContent() throws {
        let text = try source("Shell/OnboardingView.swift")
        XCTAssertEqual(try matches(#"\.frame\([^)]*Metrics\.onboardingSize\.height"#, in: text), 0,
                       "고정 높이로 되돌아갔다 — 시트 아래가 다시 빈 칸이 된다")
        XCTAssertTrue(text.contains("ScrollView {"),
                      "큰 글씨 설정에서 잘리는 대신 스크롤되어야 한다(F090 선례)")
    }
}
