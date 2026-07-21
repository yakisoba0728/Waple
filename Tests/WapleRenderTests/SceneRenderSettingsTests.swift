import XCTest
@testable import WapleRender

/// 전역 FPS 상한(w5d-feature-gaps) — 씬 렌더가 30fps 로 고정돼 WE 기본(디스플레이 주사율 60+)보다
/// 낮던 것을 사용자 선택(30/60)으로 연다. 비디오/웹은 자체 페이싱이라 미적용.
final class SceneRenderSettingsTests: XCTestCase {
    /// rawValue 0(UserDefaults 미설정 키의 기본 정수값)은 기존 하드코딩(30)과 동일하게 폴백해야 무회귀다 —
    /// 폴백 식 복제 대신 실제 maxFPS 게터 경유로 검증한다 — 키 미설정 상태가 필요해 키 이름을 직접 쓴다(SceneRenderSettings.fpsCapKey private 과 동일 유지 필요).
    func testMaxFPSFallsBackTo30WhenUnset() {
        let old = SceneRenderSettings.maxFPS
        defer { SceneRenderSettings.maxFPS = old }
        UserDefaults.standard.removeObject(forKey: "waple.maxFPS")
        XCTAssertEqual(SceneRenderSettings.maxFPS, .fps30)
    }

    func testMaxFPSRoundtripsThroughUserDefaults() {
        let old = SceneRenderSettings.maxFPS
        defer { SceneRenderSettings.maxFPS = old }

        SceneRenderSettings.maxFPS = .fps60
        XCTAssertEqual(SceneRenderSettings.maxFPS, .fps60)
        SceneRenderSettings.maxFPS = .fps30
        XCTAssertEqual(SceneRenderSettings.maxFPS, .fps30)
    }

    func testFPSCapLabelsAreNonEmpty() {
        // 설정 창 Picker 가 그대로 쓰는 라벨 — 최소한 비어있지 않은지만 방어.
        for cap in SceneFPSCap.allCases {
            XCTAssertFalse(cap.label.isEmpty)
        }
    }
}
