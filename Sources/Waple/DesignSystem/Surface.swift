import SwiftUI

/// 모서리·테두리·그림자·재질 규약(2026-08-17 UI 전면 개편).
///
/// **모서리는 크기에 비례한다.** 같은 반경을 큰 면과 작은 면에 함께 쓰면 작은 쪽은
/// 알약처럼, 큰 쪽은 각지게 보인다. 그래서 썸네일 급(74×46)·타일 급(200×125)·카드 급
/// (히어로 프리뷰)에 세 단계를 둔다. 값은 현행 구현에서 승격했다 —
/// 6(디스플레이 레일·Now Playing 썸네일) / 8(타일·모니터 박스) / 10(인스펙터 히어로).
///
/// **테두리 두께가 상태를 구분한다.** 색을 늘리는 대신 두께로 위계를 만든다:
/// 헤어라인(1) < 포커스(1.5) < 선택(2.5) < 강조(3) < 드롭 대상(4).
/// 드롭 대상이 가장 굵은 이유는 드래그 중에는 포인터가 대상을 가려 얇은 링이 안 보이기 때문이다.
///
/// **그림자는 호버 리프트 하나뿐이다.** 현재 코드에 그림자는 `WallpaperGridView.tile` 과
/// `RemoteTileView` 두 곳에 있고 값이 `(0.45, radius 9, y 5)` 로 **완전히 같다** — 복제다.
/// 하나로 묶어 두지 않으면 개편 중 한쪽만 바뀐다. 정적 그림자는 쓰지 않는다: macOS 는
/// 떠 있음을 그림자가 아니라 **재질**로 표현한다.
enum Surface {
    // MARK: 모서리

    /// 작은 썸네일(레일·하단 바).
    static let thumbCorner: CGFloat = 6
    /// 그리드 타일·모니터 박스.
    static let tileCorner: CGFloat = 8
    /// 카드(인스펙터 히어로 프리뷰).
    static let cardCorner: CGFloat = 10

    // MARK: 테두리 두께

    /// 구분용 최소 두께.
    static let strokeHairline: CGFloat = 1
    /// 키보드 포커스 링.
    static let strokeFocus: CGFloat = 1.5
    /// 선택(적용 중) 링.
    static let strokeSelected: CGFloat = 2.5
    /// 큰 면의 선택 강조(디스플레이 다이어그램 박스) — 면적이 커서 2.5 로는 약하다.
    static let strokeEmphasis: CGFloat = 3
    /// 드롭 대상 — 드래그 중 포인터에 가려도 보여야 한다.
    static let strokeDropTarget: CGFloat = 4

    // MARK: 호버 리프트

    static let liftScale: CGFloat = 1.02
    static let liftShadowRadius: CGFloat = 9
    static let liftShadowY: CGFloat = 5
    static let liftShadowOpacity: Double = 0.45

    // MARK: 재질
    //
    // 재질은 "그 면 뒤에 콘텐츠가 있다"는 신호다. 불투명한 면에는 쓰지 않는다.

    /// 창 크롬 바(하단 Now Playing 바, 시트 안 레일).
    static let chrome: Material = .bar
    /// 썸네일 위에 얹히는 배지 — 아래 이미지가 비쳐야 어디에 붙은 배지인지 읽힌다.
    static let badge: Material = .ultraThinMaterial
    /// 콘텐츠 위에 떠 있는 알림(상태 배너).
    static let overlay: Material = .regularMaterial
}

extension View {
    /// 타일 호버 리프트 — 확대 + 그림자 + 애니메이션을 한 벌로 묶는다.
    ///
    /// 화면별로 세 줄씩 복사하지 않게 하는 게 목적이다(현재 두 파일에 똑같이 복제돼 있다).
    /// 감소 모드에서는 `Motion.hoverLift` 가 nil 이라 애니메이션이 사라지고, 확대도 함께
    /// 멈춘다 — 그림자만 즉시 켜져 "호버 중" 은 여전히 전달된다.
    func tileLift(_ lifted: Bool) -> some View {
        modifier(TileLiftModifier(lifted: lifted))
    }
}

/// `tileLift(_:)` 구현. `ViewModifier` 로 뺀 이유는 타입체커 부담을 뷰 빌더 밖으로 옮기기
/// 위해서다 — 인라인 체인으로 두면 이걸 붙이는 타일 body 의 식이 그만큼 길어진다(AGENTS "함정").
private struct TileLiftModifier: ViewModifier {
    let lifted: Bool

    func body(content: Content) -> some View {
        let scale: CGFloat = (lifted && !Motion.isReduced) ? Surface.liftScale : 1
        let shadowOpacity: Double = lifted ? Surface.liftShadowOpacity : 0
        return content
            .scaleEffect(scale)
            .shadow(color: Color.black.opacity(shadowOpacity),
                    radius: Surface.liftShadowRadius,
                    y: Surface.liftShadowY)
            .animation(Motion.hoverLift, value: lifted)
    }
}
