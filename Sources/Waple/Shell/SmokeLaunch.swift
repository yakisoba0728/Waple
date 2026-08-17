import Foundation

/// 스모크 캡처 환경변수가 결정하는 초기 UI 상태.
///
/// 필드가 잘게 나뉜 이유: 종전 배선은 같은 변수를 세 파일이 각자 읽어 각자 해석했다
/// (활성화 정책은 main, 창 오픈은 AppDelegate, 초기 탭·시트는 뷰). 한 곳만 고치고 넘어가도
/// 컴파일은 통과했고, 캡처는 계속 나왔다 — 그냥 늘 기본 화면만 찍혔다.
struct SmokeLaunchState: Equatable {
    /// 활성화 정책 `.regular` 가 필요한가(Dock 아이콘 — 창 캡처의 전제).
    var isCapture = false
    /// 실행 직후 메인 창을 띄우는가.
    var opensLibrary = false
    /// 첫 항목에 포커스를 주는가(인스펙터가 채워진 상태로 찍히게 하려는 것).
    /// `opensLibrary` 와 분리한 이유: 온보딩 강제도 창은 띄우지만 포커스는 주지 않는다 —
    /// 온보딩 캡처의 주인공은 시트이지 뒤에 깔린 그리드가 아니다(현행 무회귀).
    var focusesFirstEntry = false
    /// 초기 사이드바 선택. nil = 기본(라이브러리 > 전체).
    var selection: LibrarySelection?
    /// 해석하지 못한 `WAPLE_SMOKE_TAB` 원문.
    ///
    /// `selection` 이 nil 인 것만으로는 "변수를 안 줬다" 와 "오타를 줬다" 를 구분할 수 없다.
    /// 구분하지 못하면 오타난 캡처가 조용히 기본 화면을 찍고 통과한다 — 그래서 원문을 실어
    /// 보내고 호출부가 로그로 남긴다.
    var unrecognizedTab: String?
    /// 사이드바를 펼친 상태로 시작하는가.
    var showsSidebar = false
    /// 인스펙터를 펼친 상태로 시작하는가.
    /// 종전 `showFilters`(좌측 필터 사이드바 강제 노출)의 자리를 승계한다 — 캡처에 좌우 열이
    /// 모두 나와야 "네비게이션 이관이 무손실인가" 를 눈으로 판정할 수 있다.
    var showsInspector = false
    /// 디스플레이 시트를 열린 상태로 시작하는가.
    var opensDisplays = false
    /// 설정 창을 자동으로 여는가.
    var opensSettings = false
    /// 온보딩 시트를 (완료 플래그와 무관하게) 강제로 띄우는가.
    var forcesOnboarding = false
    /// 최초 실행 온보딩을 억제하는가(온보딩 캡처 외의 스모크에서 시트가 화면을 가리지 않게).
    var suppressesOnboarding = false
}

/// 스모크 캡처 환경변수 → 초기 UI 상태. **순수** — AppKit·SwiftUI 의존이 없다.
///
/// ## 왜 순수 함수로 뽑았나
///
/// `WAPLE_SMOKE` 는 자동 게이트가 아니다. `.github/`·`scripts/`·`Tests/` 어디에도 참조가
/// 없고(2026-08-17 실측), 판정은 사람이 캡처를 눈으로 보는 수동 절차로만 존재한다.
/// 그래서 **훅이 죽어도 CI 는 초록이다** — UI 를 갈아엎다가 환경변수 읽는 줄을 지우면
/// 컴파일 에러도 테스트 실패도 나지 않고, 캡처는 계속 나오되 늘 기본 화면만 찍힌다.
/// 이 저장소가 이번 사이클에 반복해서 맞은 실패 유형이 정확히 그것이다(CI 트리거 부재,
/// 리소스 번들 누락, 현지화 오라클 사각지대).
///
/// 배선 존재 여부는 기계가 판정할 수 있는 부분이다. 그 몫을 여기로 가져와
/// `SmokeLaunchTests` 가 지키고, 사람은 "보기 좋고 네이티브다운가" 만 판정한다.
///
/// ## 이름과 값은 계약이다
///
/// 스크립트에 참조가 없다는 것은 "고칠 곳이 없다" 가 아니라 **"깨져도 알려줄 곳이 없다"**
/// 는 뜻이다. 이름을 바꾸면 `docs/history/` 의 절차와 사용자의 손 기억이 전부 어긋난다.
/// 그래서 개편에서도 변수 이름·값은 그대로 두고 **의미만 새 구조로 재해석**했다.
enum SmokeLaunch {
    /// 이 프로세스의 스모크 상태. 호출부(main·AppDelegate·MainWindowView)는 전부 이것 하나만
    /// 본다 — 각자 `ProcessInfo` 를 읽던 종전 3분산이 "한 곳만 고치고 넘어감" 의 온상이었다.
    static let current: SmokeLaunchState = state(env: ProcessInfo.processInfo.environment)

    static let variablePrefix = "WAPLE_SMOKE"

    static func state(env: [String: String]) -> SmokeLaunchState {
        let smoke = env[variablePrefix] != nil
        let settings = env["\(variablePrefix)_SETTINGS"] != nil
        let onboarding = env["\(variablePrefix)_ONBOARDING"] != nil
        let displays = env["\(variablePrefix)_DISPLAYS"] != nil
        let tab = env["\(variablePrefix)_TAB"]

        var out = SmokeLaunchState()
        // 활성화 정책은 창을 띄우는 세 변수만 켠다. `_TAB`·`_DISPLAYS` 는 단독으로 창을 띄우지
        // 않으므로 `.regular` 로 올릴 이유가 없다(현행 main.swift:8 과 동일 집합).
        out.isCapture = smoke || settings || onboarding
        out.opensLibrary = smoke || onboarding
        out.focusesFirstEntry = smoke
        out.showsSidebar = smoke
        out.showsInspector = smoke
        out.opensDisplays = displays
        out.opensSettings = settings
        out.forcesOnboarding = onboarding
        // 온보딩 억제는 접두사 전체 매칭이다 — `_TAB` 만 준 실행에서도 시트가 뜨면 안 된다.
        out.suppressesOnboarding = !onboarding && env.keys.contains { $0.hasPrefix(variablePrefix) }

        if let tab {
            out.selection = selection(tab: tab)
            if out.selection == nil { out.unrecognizedTab = tab }
        }
        return out
    }

    /// `WAPLE_SMOKE_TAB` 값 → 사이드바 선택.
    ///
    /// 값은 종전 `MainTab` 의 rawValue 그대로다. `installed` 는 종전에는 그냥 기본값이라
    /// 명시할 일이 없었는데, 개편 후에는 "라이브러리 > 전체를 콕 집어 찍는다" 는 뜻으로
    /// 쓸 수 있어 허용값으로 승격했다.
    static func selection(tab: String) -> LibrarySelection? {
        switch tab {
        case "installed": return .all
        case "discover": return .discover
        case "workshop": return .workshopSearch
        default: return nil
        }
    }
}
