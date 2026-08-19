import Foundation

/// 배경이 화면에 맞춰지는 방식.
/// Sendable: 페이로드 없는 String rawValue enum — public 타입이라 자동 추론이 안 되고, 그러면
/// 이 타입을 담는 상수(SnapshotPipeline.fitMode 등)가 "non-Sendable 전역" 진단을 받는다.
public enum FitMode: String, CaseIterable, Sendable {
    case fit       // contain: 비율 유지, 전체 표시(다르면 여백)
    case fill      // cover: 비율 유지, 꽉 채움(넘치는 부분 잘림)
    case stretch   // 비율 무시, 화면에 늘여 채움

    public var label: String {
        switch self {
        case .fit: return "맞춤 (전체 표시)"
        case .fill: return "채움 (꽉 채움)"
        case .stretch: return "늘이기"
        }
    }
}

/// 씬 렌더 프레임 상한(w5d-feature-gaps). 기본 30 — 종전 SceneRenderer 하드코딩과 동일(무회귀).
/// 비디오/웹 배경은 자체 페이싱(AVPlayer/WKWebView)이라 이 설정과 무관하게 동작한다.
public enum SceneFPSCap: Int, CaseIterable {
    case fps30 = 30
    case fps60 = 60

    public var label: String {
        switch self {
        case .fps30: return "30 fps (절전)"
        case .fps60: return "60 fps (부드러움)"
        }
    }
}

/// 렌더 전역 설정(UserDefaults 영속).
public enum SceneRenderSettings {
    private static let key = "waple.fitMode"
    private static let fpsCapKey = "waple.maxFPS"

    /// 영속 저장소. 프로덕션은 `.standard` 이고 **테스트가 갈아끼우는 유일한 주입점**이다.
    ///
    /// [2026-08-19] `UserDefaults.standard` 를 직접 쓰던 것을 연다. `AGENTS.md` 가
    /// "`--parallel` 은 통과/실패 판정에 쓰지 마라 — `SceneRenderSettingsTests` 가 병렬 3/3 실패"
    /// 라고 적고 원인을 "워커 프로세스의 defaults 도메인 차이(원인 미확정)" 로 남겨 뒀는데,
    /// **도메인 차이가 아니라 같은 도메인에 대한 동시 쓰기**다: `.standard` 는 프로세스가 아니라
    /// **사용자** 단위라 SwiftPM 이 띄운 워커 여럿이 같은 키를 공유한다. 한 워커가
    /// `waple.maxFPS` 를 지우고 읽는 사이 다른 워커가 `.fps60` 을 쓰면 앞쪽이 진다.
    /// 테스트가 워커별 고유 suite 를 넣으면 그 경합이 사라진다.
    ///
    /// `nonisolated(unsafe)`: 프로덕션에서는 앱 기동 후 바뀌지 않고(테스트만 갈아끼운다)
    /// `UserDefaults` 자체가 스레드 안전하다 — `WapleProfiler`(:10-29)의 표기 규율과 같다.
    nonisolated(unsafe) public static var defaults: UserDefaults = .standard

    public static var fitMode: FitMode {
        get { FitMode(rawValue: defaults.string(forKey: key) ?? "") ?? .fit }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }

    /// UserDefaults.integer(forKey:) 는 키 미설정 시 0 을 반환 — SceneFPSCap(rawValue: 0) 이 nil 이라
    /// .fps30(기존 하드코딩) 으로 자연 폴백한다.
    public static var maxFPS: SceneFPSCap {
        get { SceneFPSCap(rawValue: defaults.integer(forKey: fpsCapKey)) ?? .fps30 }
        set { defaults.set(newValue.rawValue, forKey: fpsCapKey) }
    }
}
