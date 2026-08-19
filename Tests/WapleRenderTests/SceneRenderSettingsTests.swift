import XCTest
@testable import WapleRender

/// 전역 FPS 상한(w5d-feature-gaps) — 씬 렌더가 30fps 로 고정돼 WE 기본(디스플레이 주사율 60+)보다
/// 낮던 것을 사용자 선택(30/60)으로 연다. 비디오/웹은 자체 페이싱이라 미적용.
///
/// ## 병렬 실패의 원인과 수정 (2026-08-19)
///
/// 이 클래스는 `AGENTS.md` 가 "병렬 3/3 실패, 순차 3/3 통과" 로 실측해 둔 둘 중 하나였고,
/// 원인은 "워커 프로세스의 defaults 도메인 차이(원인 미확정)" 로 남아 있었다.
/// **도메인 차이가 아니었다** — `UserDefaults.standard` 는 프로세스가 아니라 **사용자** 단위라
/// SwiftPM 이 띄운 워커 여럿이 **같은 키를 공유**한다. `testMaxFPSFallsBackTo30WhenUnset` 이
/// `waple.maxFPS` 를 지우고 읽는 사이 `testMaxFPSRoundtrips…` 가 `.fps60` 을 쓰면 앞쪽이 진다.
/// 클래스를 단독 필터해도 실패했던 것과도 맞는다(워커는 여전히 여럿이다).
///
/// 이제 `SceneRenderSettings.defaults` 를 **테스트마다 고유한 suite** 로 갈아끼운다.
/// 프로덕션 경로(`.standard`)는 그대로다.
final class SceneRenderSettingsTests: XCTestCase {
    private var suiteName: String!
    private var store: UserDefaults!

    override func setUpWithError() throws {
        // 프로세스 id + UUID — 워커가 여럿이어도, 같은 워커가 여러 테스트를 돌려도 겹치지 않는다.
        suiteName = "waple.tests.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
        store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        SceneRenderSettings.defaults = store
    }

    override func tearDownWithError() throws {
        SceneRenderSettings.defaults = .standard
        store.removePersistentDomain(forName: suiteName)
    }

    /// rawValue 0(UserDefaults 미설정 키의 기본 정수값)은 기존 하드코딩(30)과 동일하게 폴백해야 무회귀다 —
    /// 폴백 식 복제 대신 실제 maxFPS 게터 경유로 검증한다.
    func testMaxFPSFallsBackTo30WhenUnset() {
        // suite 가 새것이라 키가 미설정이다 — 종전처럼 전역 키를 지울 필요가 없다.
        XCTAssertEqual(SceneRenderSettings.maxFPS, .fps30)
    }

    func testMaxFPSRoundtripsThroughUserDefaults() {
        SceneRenderSettings.maxFPS = .fps60
        XCTAssertEqual(SceneRenderSettings.maxFPS, .fps60)
        SceneRenderSettings.maxFPS = .fps30
        XCTAssertEqual(SceneRenderSettings.maxFPS, .fps30)
    }

    func testFitModeRoundtripsAndFallsBack() {
        XCTAssertEqual(SceneRenderSettings.fitMode, .fit, "미설정 키는 .fit 폴백")
        for mode in FitMode.allCases {
            SceneRenderSettings.fitMode = mode
            XCTAssertEqual(SceneRenderSettings.fitMode, mode)
        }
    }

    /// 주입점이 실제로 격리를 만드는지 — 이게 깨지면 병렬 실패가 돌아온다.
    func testInjectedStoreIsIsolatedFromStandardDefaults() throws {
        let sentinel = "waple.maxFPS"
        let before = UserDefaults.standard.object(forKey: sentinel)
        SceneRenderSettings.maxFPS = .fps60
        XCTAssertEqual(UserDefaults.standard.object(forKey: sentinel) as? Int, before as? Int,
                       "주입 저장소에 쓴 값이 .standard 로 샜다 — 병렬 워커끼리 다시 충돌한다")
    }

    func testFPSCapLabelsAreNonEmpty() {
        // 설정 창 Picker 가 그대로 쓰는 라벨 — 최소한 비어있지 않은지만 방어.
        for cap in SceneFPSCap.allCases {
            XCTAssertFalse(cap.label.isEmpty)
        }
    }
}
