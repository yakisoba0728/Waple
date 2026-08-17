import SwiftUI

extension View {
    /// 커스텀 타일(그리드 타일·원격 타일·레일 썸네일·모니터 박스)의 표준 접근성 표현.
    ///
    /// ## 왜 모디파이어인가
    ///
    /// `VStack { 썸네일; 제목 }` + `.onTapGesture` 는 화면에서는 버튼처럼 보이지만
    /// 보조기술에게는 **버튼이 아니다** — 이미지 하나와 텍스트 하나가 따로 읽히고, 누를 수
    /// 있다는 사실도, 지금 적용 중이라는 사실도 전달되지 않는다. 개편 후 타일은 최소 네
    /// 종류가 되므로, 각 화면이 알아서 붙이게 두면 네 벌이 서로 달라진다. 한 벌로 고정한다.
    ///
    /// 붙는 것은 넷이다.
    /// 1. `accessibilityElement(children: .combine)` — 조각들을 항목 하나로 합친다.
    /// 2. `accessibilityLabel` — 무엇인가(배경 제목).
    /// 3. `accessibilityValue` — 지금 상태는 무엇인가(적용 중·다운로드 진행률·미지원 등).
    /// 4. `isButton` + 필요 시 `isSelected` 트레잇, 그리고 키보드 포커스 + Return 활성화.
    ///
    /// ## 파라미터가 `String` 이 아니라 `Text` 인 이유 — 현지화
    ///
    /// 이 저장소는 **키 = 한국어 원문**이라 한국어 리터럴을 담은 `Text` 는 `LocalizedStringKey`
    /// 로 해석돼 자동 번역된다(AGENTS.md §UI 문자열). 반면 `Text(someString)` 은 번역하지
    /// **않는다**. 파라미터를 `String` 으로 두면 호출부가 한국어 리터럴을 그대로 넘기게 되고,
    /// 그건 영어 시스템에서도 한국어로 읽히는데 아무 것도 실패하지 않는다 — 이 저장소가
    /// 반복해 겪은 "조용한 누락" 그대로다.
    ///
    /// `Text` 를 받으면 호출부가 리터럴(번역됨, `LocalizationCoverageTests` 의 스캔 패턴에도
    /// 걸림)과 런타임 데이터(`Text(entry.title)` — 번역 대상 아님)를 명시적으로 구분하게 된다.
    /// 규약이 타입으로 강제된다.
    ///
    /// ## 우클릭 메뉴 전용 기능은 여기서 도달할 수 없다
    ///
    /// 이 모디파이어는 **주 동작 하나**(Return/더블클릭 = 적용)만 노출한다. 즐겨찾기·제거·
    /// 폴더 이동·모니터 할당처럼 `contextMenu` 에만 있는 동작은 보조기술로 도달 불가다.
    /// 각 타일은 그런 동작마다 `.accessibilityAction(named:)` 을 **추가로** 붙여야 한다.
    /// 규약과 항목 목록은 `docs/ui-redesign-2026-08-17.md` §4.
    ///
    /// - Parameters:
    ///   - label: 항목 이름. 런타임 데이터는 `Text(entry.title)`, 고정 문구는 리터럴 `Text`.
    ///   - value: 현재 상태(적용 중·다운로드 진행률·미지원 등).
    ///     없으면 생략한다 — 빈 값을 넣으면 VoiceOver 가 빈 칸을 읽는다.
    ///   - isSelected: 지금 적용 중/선택됨. 시각 링(`Surface.strokeSelected`)과 **반드시 같은
    ///     조건**을 넘겨라 — 눈에 보이는 선택과 보조기술이 읽는 선택이 갈리면 더 나쁘다.
    ///   - onActivate: 주 동작. nil 이면 포커스 대상이 되지 않는다(장식용 타일).
    func tileAccessibility(label: Text,
                           value: Text? = nil,
                           isSelected: Bool = false,
                           onActivate: (() -> Void)? = nil) -> some View {
        modifier(TileAccessibilityModifier(label: label, value: value,
                                           isSelected: isSelected, onActivate: onActivate))
    }
}

/// `tileAccessibility` 구현. 뷰 빌더 밖으로 빼 타입체커 부담을 호출부에서 덜어낸다(AGENTS "함정").
private struct TileAccessibilityModifier: ViewModifier {
    let label: Text
    let value: Text?
    let isSelected: Bool
    let onActivate: (() -> Void)?

    private var traits: AccessibilityTraits {
        isSelected ? [.isButton, .isSelected] : [.isButton]
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let value {
            core(content).accessibilityValue(value)
        } else {
            core(content)
        }
    }

    private func core(_ content: Content) -> some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityAddTraits(traits)
            // 마우스 없이 타일에 닿을 수 있게 한다. onActivate 가 없는 타일(순수 표시)은
            // 포커스 대상에서 빼 탭 순서를 오염시키지 않는다.
            .focusable(onActivate != nil)
            .onKeyPress(.return) { activate() }
    }

    /// Return 키. 처리하지 않을 때 `.ignored` 를 돌려줘야 상위 뷰(시트의 기본 버튼 등)가
    /// 그 키를 이어받는다 — 무조건 `.handled` 를 반환하면 Enter 가 조용히 먹힌다.
    private func activate() -> KeyPress.Result {
        guard let onActivate else { return .ignored }
        onActivate()
        return .handled
    }
}
