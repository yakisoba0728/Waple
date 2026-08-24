import XCTest
@testable import Waple

/// [2026-08-25] `@MainActor` — `StatusBannerModel` 이 `@MainActor` 가 되면서 필요해졌다.
/// 그 모델은 원래부터 "메인 스레드 전용"(선언 주석)이었고 이제 타입이 그걸 말한다.
@MainActor
final class StatusBannerModelTests: XCTestCase {
    func testShowSetsMessageAndBumpsGeneration() {
        let m = StatusBannerModel()
        XCTAssertNil(m.message)
        m.show("적용 실패")
        XCTAssertEqual(m.message, "적용 실패")
        let g1 = m.generation
        m.show("두 번째")   // 연속 표시 → 세대 증가(자동소멸 타이머 리셋 근거)
        XCTAssertEqual(m.message, "두 번째")
        XCTAssertGreaterThan(m.generation, g1)
    }

    func testDismissClears() {
        let m = StatusBannerModel()
        m.show("x")
        m.dismiss()
        XCTAssertNil(m.message)
    }

    // MARK: - F092: 취소된 자동소멸 태스크가 새 메시지를 지우면 안 된다

    /// 정상 만료(취소 없이 sleep 이 반환) → dismiss 가 실행돼야 한다(기존 동작 무회귀).
    func testAutoDismissAfterDelay_normalCompletion_dismisses() async {
        let m = StatusBannerModel()
        m.show("x")
        await m.autoDismissAfterDelay(sleep: { /* 즉시 만료 */ })
        XCTAssertNil(m.message, "정상 만료 시 dismiss 되어야 한다")
    }

    /// 핵심 회귀 테스트: 취소된 옛 태스크는 dismiss 를 실행하면 안 된다. 종전 코드(`try? await
    /// Task.sleep(...); model.dismiss()`)는 취소든 정상 만료든 구분 없이 dismiss 를 호출했다 —
    /// 그 버전이었다면 이 테스트는 실패(message == nil)했을 것이다.
    func testAutoDismissAfterDelay_cancelled_doesNotDismiss() async {
        let m = StatusBannerModel()
        m.show("A")
        let started = expectation(description: "sleep 진입")
        // "A" 용 자동소멸 태스크(SwiftUI 라면 .task(id: generation) 가 만드는 것과 같은 역할).
        let task = Task {
            await m.autoDismissAfterDelay(sleep: {
                started.fulfill()
                try await Task.sleep(nanoseconds: 3_600_000_000_000)   // 사실상 무한 대기 — 취소로만 빠져나감
            })
        }
        await fulfillment(of: [started], timeout: 2)

        // 실제 흐름 재현: 4초가 지나기 전에 새 메시지가 뜬다(= generation 증가) → SwiftUI 가 "A" 용
        // 태스크를 취소하고 "B" 용 새 태스크를 시작한다. 순서가 핵심 — cancel/await 를 show 뒤에 둬야
        // "취소된 옛 태스크가 방금 표시된 새 메시지를 지우는" 경합을 재현한다.
        m.show("B")
        task.cancel()
        _ = await task.value   // "A" 태스크가 취소를 처리(구버전: try? 로 삼키고 dismiss 강행)할 때까지 대기

        XCTAssertEqual(m.message, "B", "취소된 옛 태스크가 새로 표시된 메시지를 지우면 안 된다(F092)")
    }
}
