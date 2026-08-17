import AppKit
import SwiftUI

/// 모션 규약(2026-08-17 UI 전면 개편).
///
/// **`reduceMotion` 분기를 토큰 안에 가둔다.** 각 화면이 `@Environment(\.accessibilityReduceMotion)`
/// 를 읽어 스스로 분기하면 애니메이션이 붙은 자리 하나하나가 빠뜨릴 기회가 된다 — 현재
/// 코드에는 스프링 3곳·페이드 1곳·트랜지션 3곳이 있고, 개편 후엔 더 늘어난다. 그래서
/// **애니메이션은 이 파일에서만 만든다.** 화면은 `Motion.hoverLift` 를 받아 쓰기만 하고
/// 감소 모드를 알지 못한다. 빠뜨림이 구조적으로 불가능해진다.
///
/// **`Animation?` 을 돌려주는 이유.** `withAnimation(_:_:)` 과 `.animation(_:value:)` 는 둘 다
/// `Animation?` 을 받고 `nil` 이면 애니메이션 없이 즉시 반영한다. 즉 nil 반환만으로
/// 호출부 수정 없이 모션을 끌 수 있다 — 호출부에 `if` 가 생기지 않는 유일한 형태다.
///
/// **감소 모드에서 무엇을 남기나.** 애플 HIG 는 "모션 감소"를 *모든 변화를 끊으라*가 아니라
/// *이동·확대를 페이드로 대체하라*로 정의한다. 그래서 이동/확대(호버 리프트)는 `nil`(완전 정지),
/// 나타남/사라짐은 짧은 페이드로 남긴다. 상태 변화가 하드컷으로 튀면 무엇이 바뀌었는지
/// 놓치기 쉬워 오히려 접근성이 나빠진다.
///
/// **왜 SwiftUI 환경값이 아니라 `NSWorkspace` 인가.** 이 앱은 `NSHostingController` 로 붙는
/// AppKit 앱이고, 애니메이션 생성 지점이 뷰 바깥(`StatusBannerModel.show`, AppDelegate 콜백)
/// 에도 있다. 환경값은 뷰 안에서만 읽히므로 그 자리들이 분기에서 빠진다.
/// 대가는 하나 — 설정을 바꿔도 이미 그려진 뷰가 자동으로 재평가되지 않는다(다음 상태 변화나
/// 재실행부터 반영). 접근성 설정은 세션 중 거의 바뀌지 않으므로 받아들인다.
enum Motion {
    /// 시스템 "동작 줄이기" 설정.
    static var isReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: 곡선 파라미터
    //
    // 값 자체는 종전 구현에서 승격했다 — 사용자가 이미 판정을 통과시킨 감각이라 재발명하지
    // 않는다. 리프트는 짧고 탄력 있게(0.25/0.8), 패널 개폐는 그보다 한 박자 느슨하게
    // (0.3/0.85) — 큰 면적이 움직일수록 감쇠를 키워야 오버슈트가 눈에 안 띈다.

    static let liftResponse: Double = 0.25
    static let liftDamping: Double = 0.8
    static let revealResponse: Double = 0.3
    static let revealDamping: Double = 0.85
    /// 페이드 기본 길이. 배너 등장/소멸에서 이미 쓰던 값.
    static let fadeDuration: Double = 0.2
    /// 감소 모드 대체 페이드. 기본 페이드보다 짧게 — 대체물은 눈에 덜 띌수록 좋다.
    static let reducedFadeDuration: Double = 0.12

    // MARK: 역할별 애니메이션

    /// 호버 리프트(확대 + 그림자). 감소 모드에서는 **정지** — 이동·확대는 대체하지 않고 없앤다.
    static var hoverLift: Animation? {
        isReduced ? nil : .spring(response: liftResponse, dampingFraction: liftDamping)
    }

    /// 사이드바·인스펙터 개폐, 시트 안 영역 전환. 감소 모드에서는 짧은 페이드로 대체.
    static var reveal: Animation? {
        isReduced
            ? .easeInOut(duration: reducedFadeDuration)
            : .spring(response: revealResponse, dampingFraction: revealDamping)
    }

    /// 배너·오버레이의 등장/소멸. 원래 불투명도 변화라 감소 모드에서도 길이만 줄인다.
    static var fade: Animation {
        .easeInOut(duration: isReduced ? reducedFadeDuration : fadeDuration)
    }

    /// 선택 변경처럼 "값이 갱신됐다"만 알리면 되는 곳. 감소 모드에서도 동일(불투명도뿐).
    static var stateChange: Animation { .easeInOut(duration: reducedFadeDuration) }

    // MARK: 트랜지션
    //
    // `.transition` 은 애니메이션과 별개다 — 애니메이션을 nil 로 만들어도 `.move` 트랜지션은
    // 위치를 바꾸며 사라진다(단지 즉시). 그래서 트랜지션 자체도 여기서 만든다.

    /// 가장자리에서 밀려 들어오는 등장. 감소 모드에서는 이동을 빼고 페이드만 남긴다.
    static func revealTransition(edge: Edge) -> AnyTransition {
        isReduced ? AnyTransition.opacity : AnyTransition.move(edge: edge).combined(with: .opacity)
    }

    // MARK: 실행 헬퍼

    /// `withAnimation` 래퍼. 호출부가 `Motion.isReduced` 를 몰라도 되게 하는 게 목적이다.
    /// 제네릭·`rethrows` 는 `withAnimation` 의 시그니처를 그대로 전달하기 위한 것으로,
    /// 반환값을 쓰는 호출부(예: 토글 결과)를 막지 않는다.
    @discardableResult
    static func run<T>(_ animation: Animation?, _ body: () throws -> T) rethrows -> T {
        try withAnimation(animation, body)
    }
}
