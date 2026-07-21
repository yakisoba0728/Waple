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
            // CFBoolean 판별 — NSNumber(0/1)의 as? Bool 둔갑 방지 (ProjectJSONParser.parseNumber와 동일 규칙)
            if let n = v as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() { out[k] = .bool(n.boolValue) }
                else { out[k] = .number(n.doubleValue) }
            }
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

    /// preset(project.json "preset" 키) 오버라이드는 배경 작성자가 제어하는 신뢰 경계 밖 값이다.
    /// 상대경로는 preset 루트 안에 봉쇄해 해석하지만, **절대경로 값은 root 유무와 무관하게 항상
    /// 폐기한다** — WebRenderer 의 userSelectedResourceOverrides 허용목록은 이 함수의 반환값을
    /// 그대로 스캔해 절대경로 문자열을 "사용자가 파일피커로 직접 선택"한 것으로 취급하므로, 여기서
    /// 걸러내지 않으면 악성 web 배경이 project.json 에 `"preset":{"key":"/etc/passwd"}` 를 심어
    /// randomFile/fetchall 브릿지로 임의 절대경로의 파일 존재 여부·디렉터리 목록을 프로빙할 수 있다
    /// (F357). 진짜 사용자 선택은 이 함수를 거치지 않는 별도 경로(overrides(id:) → UserDefaults,
    /// LibraryViewModel.setProperty)로만 들어오므로 영향받지 않는다.
    private static func resolvingPresetResources(_ overrides: [String: PropertyValue], root: URL?) -> [String: PropertyValue] {
        var out = overrides
        for (key, value) in overrides {
            guard case .string(let rawPath) = value else { continue }
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            if path.hasPrefix("/") {
                out[key] = PropertyValue.none   // 신뢰 경계 밖 절대경로 — 허용목록에 편입되지 않도록 폐기
                continue
            }
            guard let root,
                  let url = WallpaperPathSecurity.containedFileURL(path, root: root),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            out[key] = .string(url.path)
        }
        return out
    }
}
