import Foundation

/// 콘텐츠 영역이 지금 무엇을 그리는가.
///
/// 사이드바 항목은 8개 이상이지만 **콘텐츠 뷰는 셋뿐**이다 — 라이브러리 계열(전체·씬·동영상·
/// 웹·즐겨찾기·폴더)은 전부 같은 그리드를 그리고 필터 상태만 다르다. 종전 `MainTab` 이
/// "탭 = 화면 = 상태" 를 하나로 묶고 있었는데, 사이드바는 그 셋을 분리해야 표현된다.
enum ShellSurface: Hashable {
    case library
    case discover
    case workshopSearch
}

/// 사이드바의 한 행. `List(selection:)` 의 태그 값이자 스모크 훅의 초기 선택 값이다.
enum LibrarySelection: Hashable {
    case all
    case scene
    case video
    case web
    case favorites
    case folder(String)
    case discover
    case workshopSearch
}

/// 셸이 들고 있는 네비게이션 상태 전부. 순수 변환의 입출력 타입이다.
///
/// `criteria`·`folder` 는 실제로는 `LibraryViewModel` 이 소유한다(그리드도 같은 값을 읽는다).
/// 여기서 값 타입으로 한 번 감싸는 이유는 **변환을 뷰 밖에서 테스트하기 위해서**다 —
/// 사이드바 선택과 필터 상태의 왕복이 어긋나면 "씬이 하이라이트된 채 웹까지 보이는" 거짓말이
/// 화면에 남는데, 그건 캡처를 눈으로 봐도 잘 안 보인다.
struct ShellState: Equatable {
    var surface: ShellSurface = .library
    var criteria = LibraryFilterCriteria()
    var folder: String?
}

/// 사이드바 선택 ↔ 셸 상태의 순수 변환.
///
/// ## 왜 양방향인가 — 쓰기 주체가 둘이다
///
/// 사이드바만 필터를 쓰는 게 아니다. 툴바 필터(종전 `FilterSidebarView`)도 같은
/// `criteria.types`·`favoritesOnly` 를 쓴다. 선택을 별도 `@State` 로 들고 있으면 필터 쪽에서
/// 유형을 바꿨을 때 사이드바 하이라이트가 그대로 남아 **화면이 거짓말을 한다.**
///
/// 그래서 선택은 저장하지 않고 **상태에서 매번 유도**한다(`selection(for:)`). 사이드바로
/// 표현할 수 없는 조합(예: 씬+웹 동시 선택)이면 `nil` 을 돌려 아무 행도 강조되지 않게 한다 —
/// 틀린 행을 강조하는 것보다 낫다.
///
/// ## 태그·나이 등급은 건드리지 않는다
///
/// 사이드바가 다루는 축은 유형·즐겨찾기·폴더 셋뿐이다. 태그/등급은 툴바 필터의 축이고
/// 서로 직교하므로, 사이드바 선택이 그 값을 지우면 안 된다 — "씬" 을 눌렀더니 걸어둔 태그가
/// 사라지는 동작이 된다. 그래서 `applying` 은 기존 기준을 받아 두 축만 덮어쓴다.
enum LibrarySection {
    /// 이 선택이 그리는 콘텐츠 표면.
    static func surface(for selection: LibrarySelection) -> ShellSurface {
        switch selection {
        case .discover: return .discover
        case .workshopSearch: return .workshopSearch
        case .all, .scene, .video, .web, .favorites, .folder: return .library
        }
    }

    /// 선택을 적용한 뒤의 셸 상태.
    ///
    /// 창작마당 계열 선택은 라이브러리 상태를 **보존**한다 — 둘러보기에 다녀와도 걸어둔 폴더와
    /// 유형 필터가 그대로 있어야 사용자가 자리를 잃지 않는다.
    static func applying(_ selection: LibrarySelection, to state: ShellState) -> ShellState {
        var next = state
        next.surface = surface(for: selection)
        guard next.surface == .library else { return next }
        next.criteria.favoritesOnly = (selection == .favorites)
        next.criteria.types = types(for: selection)
        next.folder = folderName(for: selection)
        return next
    }

    /// 상태에서 유도한 사이드바 선택. 사이드바로 표현할 수 없는 조합이면 nil(강조 없음).
    static func selection(for state: ShellState) -> LibrarySelection? {
        switch state.surface {
        case .discover: return .discover
        case .workshopSearch: return .workshopSearch
        case .library: break
        }
        // 폴더가 먼저다 — 폴더 안에서는 유형 필터를 걸 수 없으므로(applying 이 비운다) 모호하지 않다.
        if let folder = state.folder { return .folder(folder) }
        if state.criteria.favoritesOnly {
            return state.criteria.types.isEmpty ? .favorites : nil
        }
        let types = state.criteria.types
        if types.isEmpty { return .all }
        guard types.count == 1, let only = types.first else { return nil }
        switch only {
        case .scene: return .scene
        case .video: return .video
        case .web: return .web
        // `.all` 은 필터 열거의 '무필터' 값이지 사이드바 행이 아니다 — 집합에 들어오면 표현 불가.
        case .all: return nil
        }
    }

    private static func types(for selection: LibrarySelection) -> Set<LibraryTypeFilter> {
        switch selection {
        case .scene: return [.scene]
        case .video: return [.video]
        case .web: return [.web]
        case .all, .favorites, .folder, .discover, .workshopSearch: return []
        }
    }

    private static func folderName(for selection: LibrarySelection) -> String? {
        if case .folder(let name) = selection { return name }
        return nil
    }
}
