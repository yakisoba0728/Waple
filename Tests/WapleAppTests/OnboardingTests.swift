import XCTest
@testable import Waple

/// 최초 실행 온보딩 게이트(앱셸 스코프 B) — 첫 실행 플래그 로직(순수) 검증.
final class OnboardingTests: XCTestCase {
    func testShouldPresentOnlyWhenNotCompleted() {
        XCTAssertTrue(Onboarding.shouldPresent(completed: false), "첫 실행(완료 플래그 없음) → 표시")
        XCTAssertFalse(Onboarding.shouldPresent(completed: true), "완료 후 → 재표시 안 함")
    }
}
