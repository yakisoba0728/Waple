import CoreGraphics

/// 간격 스케일(2026-08-17 UI 전면 개편).
///
/// **왜 스케일인가 — 실측(2026-08-17).** 종전 간격 토큰은 `Metrics.gap = 8` 하나뿐이었고,
/// 나머지는 화면마다 리터럴이었다. 세어 보면 **하드코딩 치수 81곳 / 12파일** 대
/// `Metrics` 참조 56곳 — **치수 결정의 59% 가 토큰을 우회**한다. 3파일 이상에서 반복되는
/// 무토큰 값이 10개고, 상위는 `6`(11회/5파일) · `2`(9/5) · **`20`(9회/3파일 — 최다 무토큰
/// 패딩)** · `14`(6/4) · `3`(5/5) · `10`(5/4) 이다.
///
/// 더 나쁜 건 **토큰이 있는데도 리터럴을 다시 쓴** 경우다 — `gridSpacing = 14` 가 있는데
/// `14` 를 6번, `gap = 8` 이 있는데 `8` 을 3번 다시 적었다. 토큰 하나로는 부족했다는 신호다:
/// 이름이 하나뿐이면 그 이름에 안 맞는 자리에서는 그냥 숫자를 쓰게 된다.
///
/// 그리고 `3`(SelectionPanelView 메타 스택)과 `4`(OnboardingView 제목 스택)처럼 **같은
/// 역할인데 1pt 다른** 쌍이 여럿이라, 화면을 나란히 놓으면 정렬이 미세하게 어긋난다.
/// 눈으로는 "왠지 정돈이 덜 됐다" 로만 보이고 원인을 못 찾는 종류의 어긋남이다.
///
/// **값의 근거.** macOS HIG 는 4pt 그리드를 전제하되 8pt 이하 미세 간격에는 2pt 스텝을
/// 허용한다. 그래서 `2·4·6·8` 은 2pt 스텝(글자·아이콘 사이의 광학 간격), `8` 위로는 4pt
/// 스텝(`12·16·20·24`)으로 간다. 이미 코드에 있던 값 중 스케일 밖은 `3·10·14·22` 넷뿐이고
/// 전부 인접 스텝으로 스냅된다(3→4, 10→12, 14→16, 22→24 또는 20).
///
/// **정수만 쓴다.** SwiftUI 는 소수 간격을 백킹 스케일에 맞춰 반올림하므로, 2x 디스플레이에서
/// 홀수 소수 간격은 이웃 뷰마다 다른 픽셀로 떨어져 헤어라인 두께가 들쭉날쭉해진다.
///
/// 치수(타일 폭·창 크기 등)는 `Metrics`, 이 파일은 **뷰 사이의 빈 공간**만 담는다.
enum Space {
    // MARK: 스케일

    /// 2 — 글자 광학 인셋. 라운드 썸네일 아래 캡션을 썸네일 가장자리와 눈으로 맞출 때.
    static let hairline: CGFloat = 2
    /// 4 — 한 덩어리 안의 줄 간격(제목↔부제).
    static let xxs: CGFloat = 4
    /// 6 — 아이콘↔글자, 썸네일↔캡션.
    static let xs: CGFloat = 6
    /// 8 — 나란한 컨트롤 사이. 종전 `Metrics.gap`.
    static let sm: CGFloat = 8
    /// 12 — 한 섹션 안의 블록 사이.
    static let md: CGFloat = 12
    /// 16 — 섹션 사이, 패널 안쪽 여백.
    static let lg: CGFloat = 16
    /// 20 — 스크롤 콘텐츠의 바깥 여백.
    static let xl: CGFloat = 20
    /// 24 — 시트 안쪽 여백.
    static let xxl: CGFloat = 24

    // MARK: 역할 별칭
    //
    // 별칭을 두는 이유: 나중에 "타일 사이를 한 단 벌리자" 같은 요구가 오면 스케일이 아니라
    // 역할만 바꾸면 된다. 별칭 없이 화면마다 `Space.md` 를 직접 쓰면 그 요구가 전 화면
    // 일괄 수정이 되고, 일괄 수정은 반드시 몇 군데를 빠뜨린다.

    /// 나란한 컨트롤(버튼·필드·아이콘) 사이.
    static let controlGap: CGFloat = sm
    /// 세로 스택 안의 블록 사이.
    static let stackGap: CGFloat = md
    /// 스크롤 콘텐츠(그리드·레일)의 바깥 여백.
    static let contentInset: CGFloat = xl
    /// 인스펙터·사이드바 안쪽 여백.
    static let panelInset: CGFloat = lg
    /// 시트 안쪽 여백.
    static let sheetInset: CGFloat = xxl
    /// 하단 Now Playing 바 좌우 여백.
    static let barInset: CGFloat = lg
    /// 썸네일 아래 캡션의 좌우 광학 인셋.
    static let captionInset: CGFloat = hairline
    /// 배지(캡슐)의 안쪽 여백 — 가로.
    static let badgeH: CGFloat = 7
    /// 배지(캡슐)의 안쪽 여백 — 세로. 가로보다 좁아야 캡슐이 납작해 보이지 않는다.
    static let badgeV: CGFloat = 3
}
