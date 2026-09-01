import AppKit
import SwiftUI

/// 네이티브 재설계 치수 상수. 색 토큰 없음 — 색은 시맨틱 컬러/시스템 재질만 쓴다(스펙 §2).
///
/// ⚠️ 위 문장은 **의도이지 사실이 아니었다.** 2026-08-17 실측: 화면 코드에 리터럴 색 13곳,
/// 그중 상태색 4종(오류·경고·평점·성공)은 토큰이 아예 없었다. 원칙만 적어 두고 매핑을
/// 안 만들면 지켜지지 않는다 — 그래서 역할 → 시맨틱 색 매핑을 `ColorRole` 로 분리했다.
/// hex 는 여전히 0개이므로 스펙 §2 자체는 유효하다.
///
/// 2026-08-17 개편으로 디자인 시스템이 여러 파일로 갈렸다. **이 파일은 치수만** 담는다:
/// - 간격(뷰 사이 빈 공간) → `Space`
/// - 폰트 역할 → `Typography`
/// - 애니메이션·reduceMotion → `Motion`
/// - 역할별 시맨틱 색 매핑 → `ColorRole` (hex 는 여전히 0개 — 위 "색 토큰 없음" 은 유효하다)
/// - 모서리·테두리·그림자·재질 → `Surface`
/// - 시스템 접근성 설정 조회 → `SystemPreference`
///
/// **[정정 r3-M25] 자기 실측이 스테일했다.** 종전 이 문단은 "아래 20개 상수 중 …
/// 공유하는 것은 4개(`gap`·`tileCorner`·`tileThumbHeight`·`gridSpacing`)" 라고 적었는데,
/// 두 수가 다 틀렸다. 다시 잰다(2026-09-01, 모집단 = `Sources/` 전체의 `Metrics.<이름>` 참조):
///
/// - 상수는 **28개**다(`grep -c 'static let'`).
/// - 예시로 든 "공유 토큰" 넷 중 **`gap` 과 `tileCorner` 은 프로덕션 참조가 0건**이다
///   (`Metrics.gap` 이 걸리는 두 자리는 `Space.swift` 의 **주석** 안이고, `Metrics.tileCorner`
///   은 어디에서도 안 쓰인다 — 둘 다 `Space`/`Surface` 로 이관하며 남긴 별칭이다).
///   실제로 여러 화면이 공유하는 것은 `tileWidth`·`tileThumbHeight`(각 4) ·
///   `settingsSize`(7) · `windowMin`(5) · `gridSpacing`·`gridRowSpacing`(각 3) 쪽이다.
/// - 참조 0건이 하나 더 있다: `searchFieldWidth`.
///
/// 그래도 지우지 않는다 — 별칭 셋(`gap`·`tileCorner`)은 이관 경로를 문서로 남기는 값이고,
/// 삭제는 이 파일 하나로 끝나지 않는다. 요지는 종전과 같다: 단일 사용처 상수는 토큰이라기보다
/// "그 화면의 숫자에 이름을 붙인 것" 이라, 공유 토큰과 섞여 있으면 무엇이 규약이고 무엇이
/// 지역 상수인지 흐려진다. 정리는 개편 마감 단계(Phase 3)에서 판단한다.
/// **도수를 다시 적을 때는 모집단(`Sources/` 전체)과 잰 날짜를 함께 적어라.**
enum Metrics {
    // 그리드 타일(16:10 썸네일 + 아래 제목)
    static let tileWidth: CGFloat = 200
    static let tileThumbHeight: CGFloat = 125
    /// `Surface.tileCorner` 의 별칭 — 모서리 규약의 단일 출처는 `Surface` 다.
    static let tileCorner: CGFloat = Surface.tileCorner
    static let gridSpacing: CGFloat = 14
    /// 그리드 행 사이. 열 간격보다 넓다 — 타일 아래 제목 한 줄이 행 사이를 시각적으로 좁혀
    /// 같은 값이면 세로가 더 빽빽해 보인다. 종전 호출부의 `gridSpacing + 6` 을 이름으로 승격.
    static let gridRowSpacing: CGFloat = 20

    // 좌측 필터 사이드바(종전 설치됨 탭 전용 — 개편 후 인스펙터/필터 팝오버로 흡수)
    static let sidebarWidth: CGFloat = 220

    // 네비게이션 사이드바(개편: NavigationSplitView 소스리스트).
    // 사용자가 폭을 조절할 수 있어야 하므로 고정값이 아니라 min/ideal/max 로 준다 —
    // 항목 라벨이 영어로 바뀌면(Workshop·Subscriptions) 한국어보다 길어져 고정 220 에서 잘린다.
    static let navSidebarMin: CGFloat = 180
    static let navSidebarIdeal: CGFloat = 215
    static let navSidebarMax: CGFloat = 300

    // 우측 상세 패널
    static let panelWidth: CGFloat = 300
    static let heroHeight: CGFloat = 170

    // 표준 인스펙터(개편: .inspector 모디파이어). 사이드바와 같은 이유로 폭이 가변이어야 한다.
    static let inspectorMin: CGFloat = 260
    static let inspectorIdeal: CGFloat = panelWidth
    static let inspectorMax: CGFloat = 420

    // 하단 Now Playing 바
    static let nowPlayingHeight: CGFloat = 56
    static let nowPlayingThumb: CGFloat = 40

    // 창
    static let windowDefault = NSSize(width: 1280, height: 820)
    static let windowMin = NSSize(width: 1024, height: 680)
    static let displaysMin = NSSize(width: 860, height: 560)

    // 검색·창작마당 탭 (SP4′)
    static let searchFieldWidth: CGFloat = 190     // 툴바 검색 필드(설치됨 탭 기존 하드코딩 190 승격)
    static let usernameFieldWidth: CGFloat = 180
    static let downloadBarWidth: CGFloat = 90
    static let keyGateFieldWidth: CGFloat = 320
    static let keyGateTextWidth: CGFloat = 420

    // 설정 창 (SP5′)
    // **[정정 r3-M22] 이 자리에 있던 경고는 전제 둘이 다 거짓이 됐다.**
    // 종전 문구는 "SettingsView 가 .frame(height:)로 이 값을 고정하고 창도 리사이즈 불가
    // (styleMask 에 .resizable 없음)라 마지막 '에셋·도구' 섹션이 화면 밖으로 밀린다" 였다.
    // 지금 트리에서는 둘 다 성립하지 않는다:
    //  · `AppDelegate` 의 설정 창 `styleMask` 에 `.resizable` 이 **있다**.
    //  · `SettingsView.body` 는 고정 높이가 아니라
    //    `.frame(minHeight:idealHeight:maxHeight: .infinity)` 로 가변이다(그 뷰의 긴 독스트링이
    //    왜 그렇게 바뀌었는지를 적어 두고 있다).
    // 그래서 이 값은 "창을 열 때의 **이상** 높이" 이지 상한이 아니다. 잘림은 해소됐고,
    // 남은 규약만 적어 둔다: 섹션이 늘어도 이 숫자를 키워 대응하지 마라 — Dynamic Type 큰
    // 글씨에서는 어떤 고정 높이도 결국 넘치고, 폼은 이미 스스로 스크롤한다(F090 선례).
    static let settingsSize = NSSize(width: 560, height: 820)

    // 최초 실행 온보딩 시트 (앱셸 스코프 B)
    static let onboardingSize = NSSize(width: 460, height: 430)

    // 디스플레이 다이어그램: 모니터 배치를 그릴 때 컨테이너 안쪽으로 비워 두는 여백.
    // 간격 스케일(Space)이 아니라 레이아웃 계산 파라미터라 여기에 둔다 —
    // DisplayDiagramLayout.rects(padding:) 로 넘어가 배치 수식에 직접 들어간다.
    static let diagramPadding: CGFloat = 28

    // 공통 간격 — `Space.sm` 의 별칭. 간격 규약의 단일 출처는 `Space` 다.
    // 기존 호출부(다수)를 위해 이름을 남긴다. 새 코드는 `Space.controlGap` 등 역할 이름을 쓸 것.
    static let gap: CGFloat = Space.sm
}
