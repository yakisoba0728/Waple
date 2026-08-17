import AppKit
import SwiftUI

/// 색 **역할** 규약(2026-08-17 UI 전면 개편).
///
/// ## 이 파일이 `Metrics.swift` 의 "색 토큰 없음" 을 뒤집는가 — 아니다
///
/// 스펙 §2 의 결정은 **"커스텀 hex 색 금지 — 시맨틱 컬러와 시스템 재질만"** 이었다.
/// 이 파일에 hex 는 한 개도 없다. 전부 `NSColor` 시맨틱 값이거나 SwiftUI 시스템 색이다.
/// 즉 **색 값을 새로 만들지 않는다**는 원칙은 그대로다.
///
/// 바뀌는 건 다른 축이다. 종전에는 "어떤 상황에 어떤 시맨틱 색을 쓸지" 를 화면마다 각자
/// 골랐고, 그래서 같은 뜻이 다른 값으로 갈라졌다. 2026-08-17 실측:
///
/// - 화면 코드에 **리터럴 색 13곳**. `Metrics.swift` 의 "색 토큰 없음" 주석은 의도였을 뿐
///   사실이 아니었다.
/// - 그중 **상태색 4종이 토큰 없이 생 컬러로만 존재**한다 — 오류 `.red`×2 · 경고
///   `.orange`×2 · 즐겨찾기/평점 `.yellow`×2 · 성공 `.green`. 같은 뜻을 다음에 쓸 사람이
///   무엇을 골라야 하는지 코드에 적혀 있지 않았다.
/// - 불투명도 매직넘버 **9종**. 플레이스홀더 하나에 `quaternaryLabelColor` 를
///   **0.3 / 0.25 / 0.15** 세 값으로(WallpaperGridView 0.3·0.15, DisplaysView 0.25,
///   SelectionPanelView 0.3, RemoteTile 0.3), 비활성 디밍에 0.55 와 0.4 를 섞어 쓰고 있다.
///
/// 이건 의도된 위계가 아니라 파일별로 따로 정한 흔적이다. 원칙만 있고 매핑이 없으면
/// 불일치는 시간 문제였다.
///
/// 그래서 이 파일이 담는 것은 **역할 → 시맨틱 색의 매핑 하나뿐**이다. 값의 출처는 여전히
/// 시스템이고, 다크·라이트·고대비·색약 대응은 시스템이 계속 책임진다.
/// **이 매핑이 전부 시맨틱이라는 사실이, 창 단위 `darkAqua` 강제를 걷어낼 수 있게 하는
/// 전제다**(청사진 §8.1) — 리터럴 색이 남아 있으면 라이트 모드에서 그 자리만 깨진다.
///
/// ## 사용 규칙
///
/// - **파괴적 동작은 색이 아니라 `role:` 로 표현한다.** `Button(role: .destructive)` /
///   `.accessibilityAddTraits` 가 색·보이스오버·확인 흐름을 함께 처리한다. `ColorRole.destructive`
///   는 버튼이 아닌 자리(상태 텍스트 등)에서만 쓴다.
/// - **비활성은 색을 바꾸지 않는다.** `.disabled(true)` 만 걸면 시스템이 알아서 흐리게 한다.
///   직접 `.foregroundStyle(.secondary)` 로 흉내내면 실제로는 눌리는 "가짜 비활성"이 된다.
/// - **호버는 색이 아니라 리프트로 표현한다**(`Surface.tileLift`). 색으로 호버를 표현하면
///   포인터가 없는 접근성 사용자에게 전달되지 않는다.
/// - **선택과 포커스를 구분한다.** 선택(적용 중)은 액센트, 키보드 포커스는 중성 링이다.
///   둘 다 액센트로 칠하면 "무엇이 적용 중인지" 를 잃는다.
enum ColorRole {
    // MARK: 배경 층위
    //
    // 세 단: 우물(콘텐츠) < 패널(크롬) < 재질(떠 있는 것). 깊이를 색이 아니라 층으로 표현한다.

    /// 콘텐츠 우물 — 그리드·레일이 놓이는 한 단 깊은 바닥.
    ///
    /// **종전 값 `underPageBackgroundColor` 를 걷어냈다(Unit E, 2026-08-17).** 그 값은
    /// 다크에서만 "한 단" 이었고 라이트에서는 콘텐츠 열 전체를 회색 매트로 덮었다.
    /// `darkAqua` 강제를 걷어내기 전에는 라이트가 존재하지 않아 드러날 수 없던 자리다.
    ///
    /// 실측(2026-08-17, macOS 26. 값은 API 가 아니라 **화면에 칠해 캡처로 읽은** 것이다 —
    /// `underPageBackgroundColor` 는 라이트에서 `.cgColor` 가 0.972 를 돌려주는데 실제로
    /// 그려지는 것은 0.685 다. Preview 의 페이지 둘레 회색이 바로 이 값이고, 페이지가
    /// 얹히지 않는 우리 화면에서는 그냥 회색 판이 된다):
    ///
    /// | 색 | 라이트 | 다크 |
    /// | --- | --- | --- |
    /// | `underPageBackgroundColor`(종전) | **0.685** | 0.208 |
    /// | `controlBackgroundColor`(현행) | 1.000 | 0.157 |
    /// | 사이드바(시스템 소스리스트) | 0.925 | 0.213 |
    ///
    /// 종전 값은 라이트에서 사이드바(0.925)와 0.24 나 벌어져 콘텐츠 열만 비활성처럼 보였고,
    /// 그 위에 놓인 `secondaryLabelColor` 본문(검정 50%)의 대비가 **3.5:1** 로 WCAG AA
    /// (4.5:1)에 못 미쳤다. 흰 바닥에서는 7.7:1 이다 — 취향이 아니라 가독성 문제였다.
    ///
    /// `controlBackgroundColor` 를 고른 이유는 Apple 문서의 정의 그대로다("브라우저·테이블
    /// 뷰 같은 큰 인터페이스 요소의 배경") — 우리 우물이 정확히 그리드와 레일이다.
    /// 다크에서 우물이 0.208 → 0.157 로 한 단 내려가지만, 인접한 사이드바가 0.213 이라
    /// "콘텐츠가 더 깊다" 는 층위는 오히려 또렷해진다.
    static let well: Color = Color(nsColor: .controlBackgroundColor)
    /// 패널 — 인스펙터·사이드바처럼 우물 위에 얹히는 크롬 면.
    static let panel: Color = Color(nsColor: .windowBackgroundColor)
    /// 구분선. `Divider()` 로 충분하면 그걸 쓰고, 커스텀 스트로크가 필요할 때만.
    static let hairline: Color = Color(nsColor: .separatorColor)

    /// 이미지가 아직/영영 없는 자리의 채움. **0.25 로 통일**한다 —
    /// 0.15 는 우물 위에서 거의 사라졌고 0.3 은 실제 썸네일보다 무거웠다.
    static let placeholderFill: Color = Color(nsColor: .quaternaryLabelColor).opacity(0.25)

    // MARK: 상태

    /// 지금 적용 중 / 선택됨. 시스템 액센트 — 사용자가 시스템 설정에서 고른 색이다.
    static let selected: Color = .accentColor
    /// 키보드 포커스 링. 액센트가 아닌 중성색이어야 '선택'과 구별된다.
    static let focusRing: Color = Color.secondary.opacity(0.6)
    /// 드래그가 올라와 있는 드롭 대상. 선택과 같은 액센트를 쓰되 굵기로 구분한다
    /// (`Surface.strokeDropTarget`) — 색을 하나 더 늘리는 대신 두께를 쓴다.
    static let dropTarget: Color = .accentColor

    /// 되돌릴 수 없는 동작의 상태 텍스트. 버튼에는 `role: .destructive` 를 쓸 것.
    static let destructive: Color = .red
    /// 주의 — 진행은 되지만 무언가 빠졌다(steamcmd 미설치 등).
    static let warning: Color = .orange
    /// 준비됨 — 온보딩 체크리스트의 완료 표시.
    static let ready: Color = .green
    /// 평점 별.
    static let rating: Color = .yellow

    // MARK: 이미지 위
    //
    // 썸네일·그라디언트 위에 얹는 글자는 **시맨틱 라벨색을 쓰면 안 된다** — 라벨색은 시스템
    // 배경 대비로 계산된 값이라, 임의의 사진 위에서는 대비가 보장되지 않는다(밝은 썸네일 위
    // 라이트 모드 labelColor = 검정 위 검정). 그래서 여기만 고정 흰색 + 어두운 스크림이다.
    // hex 가 아니라 SwiftUI 시스템 흑백이므로 "커스텀 색 금지" 와 충돌하지 않는다.

    /// 이미지·그라디언트 위 1차 글자.
    static let onMedia: Color = .white
    /// 이미지 위 2차 글자.
    static let onMediaSecondary: Color = Color.white.opacity(0.75)
    /// 이미지 하단 스크림의 최대 농도(위→아래 그라디언트의 끝값).
    /// "투명도 줄이기" 가 켜지면 스크림을 더 진하게 해 글자 대비를 확보한다 — 시스템 `Material`
    /// 과 달리 직접 그린 그라디언트는 그 설정에 스스로 반응하지 않는다.
    static var mediaScrimOpacity: Double { SystemPreference.reduceTransparency ? 0.9 : 0.72 }

    // MARK: 감광
    //
    // 색이 아니라 불투명도/채도로 표현하는 상태. 색을 바꾸면 다크·고대비에서 대비가 무너진다.

    /// 미지원 항목의 불투명도.
    static let unsupportedOpacity: Double = 0.55
    /// 미지원 항목의 채도 — 흑백에 가깝게 빼서 "쓸 수 없다"를 색맹 사용자에게도 전달한다.
    static let unsupportedSaturation: Double = 0.4
    /// 대체 표시(전역 배경 폴백 썸네일 등)의 불투명도.
    static let dimmedOpacity: Double = 0.55
}
