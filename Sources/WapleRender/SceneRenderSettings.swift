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

/// 렌더 전역 설정(UserDefaults 영속).
public enum SceneRenderSettings {
    private static let key = "waple.fitMode"

    public static var fitMode: FitMode {
        get { FitMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .fit }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
