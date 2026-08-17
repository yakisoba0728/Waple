import AppKit
import SwiftUI

/// 네이티브 재설계 치수 상수. 색 토큰 없음 — 색은 시맨틱 컬러/시스템 재질만 쓴다(스펙 §2).
///
/// 2026-08-17 개편으로 디자인 시스템이 다섯 파일로 갈렸다. **이 파일은 치수만** 담는다:
/// - 간격(뷰 사이 빈 공간) → `Space`
/// - 폰트 역할 → `Typography`
/// - 애니메이션·reduceMotion → `Motion`
/// - 역할별 시맨틱 색 매핑 → `ColorRole` (hex 는 여전히 0개 — 위 "색 토큰 없음" 은 유효하다)
/// - 모서리·테두리·그림자·재질 → `Surface`
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
    static let settingsSize = NSSize(width: 560, height: 820)   // 5섹션+푸터가 스크롤 없이 한눈에

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
