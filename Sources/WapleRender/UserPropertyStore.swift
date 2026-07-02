import Foundation
import WapleCore

/// 배경별 유저 속성 오버라이드(UserDefaults JSON 영속). 값은 String/Bool/Double 만.
public enum UserPropertyStore {
    private static func key(_ id: String) -> String { "waple.userprops.\(id)" }

    /// 씬 파서(userProps:)용 raw 딕셔너리.
    public static func rawOverrides(id: String) -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: key(id)) ?? [:]
    }

    public static func overrides(id: String) -> [String: PropertyValue] {
        var out: [String: PropertyValue] = [:]
        for (k, v) in rawOverrides(id: id) {
            if let b = v as? Bool { out[k] = .bool(b) }
            else if let d = v as? Double { out[k] = .number(d) }
            else if let i = v as? Int { out[k] = .number(Double(i)) }
            else if let s = v as? String { out[k] = .string(s) }
        }
        return out
    }

    public static func set(_ value: PropertyValue, key propKey: String, id: String) {
        var raw = rawOverrides(id: id)
        switch value {
        case .bool(let b): raw[propKey] = b
        case .number(let n): raw[propKey] = n
        case .string(let s): raw[propKey] = s
        case .none: raw.removeValue(forKey: propKey)
        }
        UserDefaults.standard.set(raw, forKey: key(id))
    }

    public static func reset(id: String) {
        UserDefaults.standard.removeObject(forKey: key(id))
    }
}
