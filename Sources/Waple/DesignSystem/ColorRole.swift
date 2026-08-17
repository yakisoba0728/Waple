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
/// 골랐고, 그래서 같은 뜻이 다른 값으로 갈라졌다 — 플레이스홀더 채움색이
/// `quaternaryLabelColor` 를 **0.15 / 0.25 / 0.3** 세 가지 불투명도로 쓰고 있다
/// (WallpaperGridView 0.3·0.15, DisplaysView 0.25, SelectionPanelView 0.3, RemoteTile 0.3).
/// 이건 의도된 위계가 아니라 파일별로 따로 정한 흔적이다. 원칙만 있고 매핑이 없으면
/// 불일치는 시간 문제였다.
///
/// 그래서 이 파일이 담는 것은 **역할 → 시맨틱 색의 매핑 하나뿐**이다. 값의 출처는 여전히
/// 시스템이고, 다크·라이트·고대비·색약 대응은 시스템이 계속 책임진다.
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
    static let well: Color = Color(nsColor: .underPageBackgroundColor)
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
