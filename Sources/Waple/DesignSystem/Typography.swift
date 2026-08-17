import SwiftUI

/// 타이포그래피 역할(2026-08-17 UI 전면 개편).
///
/// **커스텀 폰트도, 커스텀 크기(`.system(size:)`)도 쓰지 않는다.** 시스템 텍스트 스타일
/// (`.title2`/`.headline`/`.callout`/`.caption`…)만 조합한다. 이유는 스펙 §2 의 "시각 = 네이티브"
/// 를 잇는 것이기도 하지만, 실질적으로는 **Dynamic Type 이 공짜로 따라오기 때문**이다.
/// `.system(size: 13)` 은 접근성 큰 글씨 설정에서 그대로 13pt 로 남아 그 자리만 안 커진다 —
/// 현재 코드에도 `Image(systemName:).font(.system(size: 40))` 같은 고정 크기가 남아 있는데,
/// 그건 글리프(장식)라 예외이고 **글자에는 쓰지 않는다**.
///
/// **역할로 부르는 이유.** `.font(.title3.weight(.semibold))` 이라는 같은 표현이 지금
/// 세 파일(DisplaysView 헤더·DiscoverView 레일 제목·SelectionPanelView 항목 제목)에
/// 각각 적혀 있다. 셋은 위계가 서로 다른 자리인데 우연히 같은 값이라, 한 곳을 조정하면
/// 나머지 둘이 조용히 뒤처진다. 역할 이름을 두면 "무엇과 무엇이 같은 급인가" 가 코드에 남는다.
///
/// **숫자에는 `monospacedDigit`.** 값이 바뀌며 자리수가 변하는 숫자(진행률·개수·간격 분)는
/// 비례 숫자로 두면 갱신될 때마다 폭이 흔들려 옆 요소가 밀린다. 열로 정렬되는 숫자와
/// 실시간 갱신되는 숫자는 전부 `metric*` 역할을 쓴다.
enum Typography {
    // MARK: 제목 위계

    /// 창·시트 최상단 제목. 예: 온보딩 "Waple 시작하기".
    static let windowHeading: Font = .title2.weight(.semibold)
    /// 콘텐츠 영역 안의 섹션 제목. 예: 디스커버 레일 제목, 디스플레이 시트 헤더.
    static let sectionHeader: Font = .title3.weight(.semibold)
    /// 인스펙터가 지금 보여주는 대상의 이름.
    static let itemTitle: Font = .title3.weight(.semibold)
    /// 목록·폼 안의 소제목. 예: 온보딩 체크리스트 행 제목, 인스펙터 "속성".
    static let subsectionHeader: Font = .headline

    // MARK: 본문

    /// 기본 본문.
    static let body: Font = .body
    /// 한 단 낮은 본문(설명문·푸터).
    static let secondaryBody: Font = .callout
    /// 강조된 짧은 본문. 예: Now Playing 바의 현재 배경 제목.
    static let bodyEmphasis: Font = .callout.weight(.medium)

    // MARK: 부속

    /// 캡션 — 타일 제목, 메타 한 줄, 폼 푸터.
    static let caption: Font = .caption
    /// 배지·오버레이 안의 아주 짧은 라벨.
    static let badge: Font = .caption2

    // MARK: 수치
    //
    // 자리수가 변하는 숫자 전용. 비례 숫자면 "9%→10%" 에서 폭이 튀어 옆 컨트롤이 밀린다.

    /// 캡션 크기의 수치. 예: 다운로드 진행률, 구독 수, 평점.
    static let metric: Font = .caption.monospacedDigit()
    /// 본문 크기의 수치. 예: 재생목록 전환 간격, 속성 슬라이더 값.
    static let metricBody: Font = .body.monospacedDigit()
}
