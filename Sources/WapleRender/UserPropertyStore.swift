import Foundation
import WapleCore

/// 배경별 유저 속성 오버라이드(UserDefaults JSON 영속). 값은 String/Bool/Double 만.
public enum UserPropertyStore {
    private static func key(_ id: String) -> String { "waple.userprops.\(id)" }

    /// 씬 파서(userProps:)용 raw 딕셔너리.
    public static func rawOverrides(id: String) -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: key(id)) ?? [:]
    }

    public static func rawOverrides(id: String, presetOverrides: [String: PropertyValue]) -> [String: Any] {
        rawOverrides(id: id, presetOverrides: presetOverrides, presetResourceRoot: nil)
    }

    public static func rawOverrides(id: String, presetOverrides: [String: PropertyValue], presetResourceRoot: URL?) -> [String: Any] {
        var raw = rawDictionary(from: resolvingPresetResources(presetOverrides, root: presetResourceRoot))
        raw.merge(rawOverrides(id: id)) { _, user in user }
        return raw
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

    public static func overrides(id: String, presetOverrides: [String: PropertyValue]) -> [String: PropertyValue] {
        overrides(id: id, presetOverrides: presetOverrides, presetResourceRoot: nil)
    }

    public static func overrides(id: String, presetOverrides: [String: PropertyValue], presetResourceRoot: URL?) -> [String: PropertyValue] {
        var out = resolvingPresetResources(presetOverrides, root: presetResourceRoot).filter { _, value in value != .none }
        out.merge(overrides(id: id)) { _, user in user }
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

    private static func rawDictionary(from overrides: [String: PropertyValue]) -> [String: Any] {
        var raw: [String: Any] = [:]
        for (key, value) in overrides {
            switch value {
            case .bool(let bool):
                raw[key] = bool
            case .number(let number):
                raw[key] = number
            case .string(let string):
                raw[key] = string
            case .none:
                break
            }
        }
        return raw
    }

    private static func resolvingPresetResources(_ overrides: [String: PropertyValue], root: URL?) -> [String: PropertyValue] {
        guard let root else { return overrides }
        var out = overrides
        for (key, value) in overrides {
            guard case .string(let rawPath) = value else { continue }
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !path.hasPrefix("/"),
                  let url = WallpaperPathSecurity.containedFileURL(path, root: root),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            out[key] = .string(url.path)
        }
        return out
    }
}
