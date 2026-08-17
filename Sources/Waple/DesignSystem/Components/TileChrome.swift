import SwiftUI

/// 타일 테두리의 상태 위계.
///
/// **왜 열거형인가.** 2026-08-17 실측: 타일 테두리를 그리는 자리가 넷이고
/// (그리드 타일·원격 타일·모니터 박스·레일 썸네일) 네 곳이 각자 삼항으로 색과 두께를 고르고
/// 있었다. 색은 넷 다 달랐고 두께는 1 / 1.5 / 2 / 2.5 / 3 / 4 여섯 값이 섞여 있었다.
/// 값을 고르는 코드가 흩어져 있으면 "무엇이 더 강한 상태인가" 가 어디에도 적혀 있지 않게 된다.
/// 여기서는 케이스 순서가 곧 위계고, 두께가 그 위계를 눈에 보이게 한다(`Surface` 의 두께 규약).
///
/// **색을 늘리는 대신 두께를 쓴다.** 선택과 드롭 대상은 둘 다 액센트다 — 구분은 두께가 한다.
/// 색을 하나 더 만들면 다크·라이트·고대비·색약 네 축을 새로 책임져야 하지만 두께는 그렇지 않다.
///
/// **`.hairline` 은 청사진 초안에 없던 케이스다.** 초안은 `none/focus/selected/emphasis/dropTarget`
/// 다섯이었는데, 실측해 보니 모니터 박스는 **아무 상태도 아닐 때 separator 1pt 를 그린다**
/// (`DisplaysView` 미선택 박스). 큰 면이 우물 위에 놓이면 테두리 없이는 경계가 사라지기 때문이다.
/// 이걸 `.none` 으로 뭉개면 그 화면이 다시 자기 스트로크를 직접 그리게 되고, 그 순간 이 열거형이
/// 있는 이유가 없어진다.
enum TileRing: Equatable {
    /// 링 없음. 그리드·레일 타일의 평상시.
    case none
    /// 중성 구분선. 큰 면이 배경과 붙어 보이지 않게 하는 최소 테두리.
    case hairline
    /// 키보드 포커스(또는 포인터 호버로 같은 위계를 표현하는 자리).
    case focus
    /// 지금 적용 중 / 이 화면에 할당됨.
    case selected
    /// 큰 면의 선택. `selected` 와 같은 색이되 면적이 커서 2.5 로는 약하다.
    case emphasis
    /// 드래그가 올라와 있는 드롭 대상.
    case dropTarget
}

extension TileRing {
    /// 링 색. 값은 전부 `ColorRole` 에서 온다 — 여기서 색을 만들지 않는다.
    var color: Color {
        switch self {
        case .none: return .clear
        case .hairline: return ColorRole.hairline
        case .focus: return ColorRole.focusRing
        case .selected, .emphasis: return ColorRole.selected
        case .dropTarget: return ColorRole.dropTarget
        }
    }

    /// 링 두께. 값은 전부 `Surface` 에서 온다.
    /// `.none` 이 0 인 것은 의도다 — 종전 그리드는 투명색에 1.5 를 줘 "안 보이는 링" 을 그리고
    /// 있었는데, 그러면 나중에 색만 바꿨을 때 두께가 어디서 왔는지 아무도 모른다.
    var lineWidth: CGFloat {
        switch self {
        case .none: return 0
        case .hairline: return Surface.strokeHairline
        case .focus: return Surface.strokeFocus
        case .selected: return Surface.strokeSelected
        case .emphasis: return Surface.strokeEmphasis
        case .dropTarget: return Surface.strokeDropTarget
        }
    }

    /// 작은 타일(그리드·원격·레일)의 상태 → 링.
    ///
    /// **선택이 포커스를 이긴다.** 둘 다일 때 "지금 적용 중" 이 "지금 커서가 여기 있다" 보다
    /// 오래 가는 정보다. 종전 그리드가 이미 이 순서였고, 순서를 코드 한 곳에 고정해 둔다.
    static func tile(selected: Bool, focused: Bool) -> TileRing {
        if selected { return .selected }
        if focused { return .focus }
        return .none
    }

    /// 큰 면(디스플레이 모니터 박스)의 상태 → 링.
    ///
    /// 드롭 대상이 선택을 이긴다 — 드래그 중에는 "놓으면 여기" 가 유일하게 필요한 정보다.
    /// 아무 상태도 아니면 `.none` 이 아니라 `.hairline` 인 이유는 이 열거형 문서 참조.
    static func surface(dropTargeted: Bool, selected: Bool) -> TileRing {
        if dropTargeted { return .dropTarget }
        if selected { return .emphasis }
        return .hairline
    }
}

extension View {
    /// 상태 링을 얹는다. 링은 오버레이라 레이아웃을 바꾸지 않는다.
    ///
    /// - Parameter corner: 링의 모서리. 썸네일 클립과 **같은 값**을 줘야 링이 이미지 가장자리에
    ///   붙는다. 기본값은 타일 급이고, 작은 썸네일은 `Surface.thumbCorner` 를 넘긴다.
    func tileRing(_ ring: TileRing, corner: CGFloat = Surface.tileCorner) -> some View {
        modifier(TileRingModifier(ring: ring, corner: corner))
    }

    /// 썸네일을 프레임에 맞춰 자르고 모서리를 둥글린다.
    ///
    /// 종전에는 `clipped()` + `clipShape(RoundedRectangle(...))` 3연타가 네 곳에 흩어져 있었고,
    /// 한 곳은 `clipped()` 를 빠뜨려 같은 모양인지 읽어야만 알 수 있었다.
    func tileThumbnailClip(corner: CGFloat = Surface.tileCorner) -> some View {
        modifier(TileThumbnailClipModifier(corner: corner))
    }
}

/// `tileRing(_:corner:)` 구현. `ViewModifier` 로 뺀 이유는 `Surface.tileLift` 와 같다 —
/// 타입체커 부담을 호출부의 뷰 빌더 밖으로 옮긴다(AGENTS "함정").
private struct TileRingModifier: ViewModifier {
    let ring: TileRing
    let corner: CGFloat

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: corner)
                .stroke(ring.color, lineWidth: ring.lineWidth)
        )
    }
}

/// `tileThumbnailClip(corner:)` 구현.
private struct TileThumbnailClipModifier: ViewModifier {
    let corner: CGFloat

    func body(content: Content) -> some View {
        content
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: corner))
    }
}
