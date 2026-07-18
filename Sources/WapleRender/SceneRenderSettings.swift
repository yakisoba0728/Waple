import Foundation

/// 배경이 화면에 맞춰지는 방식.
public enum FitMode: String, CaseIterable {
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

    public static var fitMode: FitMode {
        get { FitMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .fit }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// UserDefaults.integer(forKey:) 는 키 미설정 시 0 을 반환 — SceneFPSCap(rawValue: 0) 이 nil 이라
    /// .fps30(기존 하드코딩) 으로 자연 폴백한다.
    public static var maxFPS: SceneFPSCap {
        get { SceneFPSCap(rawValue: UserDefaults.standard.integer(forKey: fpsCapKey)) ?? .fps30 }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: fpsCapKey) }
    }
}
