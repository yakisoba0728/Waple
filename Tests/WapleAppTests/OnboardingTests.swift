import XCTest
@testable import Waple

/// 최초 실행 온보딩 게이트(앱셸 스코프 B) — 첫 실행 플래그 로직(순수) 검증.
final class OnboardingTests: XCTestCase {
    func testShouldPresentOnlyWhenNotCompleted() {
        XCTAssertTrue(Onboarding.shouldPresent(completed: false), "첫 실행(완료 플래그 없음) → 표시")
        XCTAssertFalse(Onboarding.shouldPresent(completed: true), "완료 후 → 재표시 안 함")
    }

    // MARK: - '배경 추가' 행 가져오기 액션 (w5d-onboarding)

    func testImportContentInvokesClosureThenRefreshesReadiness() {
        let model = OnboardingModel()
        var importCalled = false
        var readinessCallCount = 0
        model.onImport = { importCalled = true }
        model.readiness = { readinessCallCount += 1; return (true, false, false) }

        model.importContent()

        XCTAssertTrue(importCalled, "AppDelegate 배선(NSOpenPanel+routeImport)을 호출해야 한다")
        XCTAssertGreaterThanOrEqual(readinessCallCount, 1, "가져오기 후 상태를 다시 읽어야 초록 체크가 즉시 갱신된다")
        XCTAssertTrue(model.hasContent, "성공적으로 가져왔다면 hasContent 가 즉시 반영돼야 한다")
    }
}
