import Foundation
import WapleCore

/// 배경별 유저 속성 오버라이드(UserDefaults JSON 영속). 값은 String/Bool/Double 만.
public enum UserPropertyStore {
    private static func key(_ id: String) -> String { "waple.userprops.\(id)" }
    private static func resourceKey(_ id: String) -> String { "waple.resource-grants.\(id)" }

    public static func allowsWebMedia(id: String) -> Bool {
        UserDefaults.standard.bool(forKey: "waple.web-media.\(id)")
    }

    public static func setAllowsWebMedia(_ allowed: Bool, id: String) {
        UserDefaults.standard.set(allowed, forKey: "waple.web-media.\(id)")
    }

    public static func allowsSceneScripts(id: String) -> Bool {
        UserDefaults.standard.bool(forKey: "waple.scene-scripts.\(id)")
    }

    public static func setAllowsSceneScripts(_ allowed: Bool, id: String) {
        UserDefaults.standard.set(allowed, forKey: "waple.scene-scripts.\(id)")
    }

    public static func resourceGrants(id: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: resourceKey(id)) as? [String: String] ?? [:]
    }

    public static func setResourceGrant(absolutePath: String?, key: String, id: String) {
        var grants = resourceGrants(id: id)
        grants[key] = absolutePath.flatMap { path in
            guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        UserDefaults.standard.set(grants, forKey: resourceKey(id))
    }

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

    /// C①: {user,value} 바인딩 해석용 유효값 raw 딕셔너리 — project.json 기본값(가장 낮은 우선순위)
    /// 위에 preset·유저 오버라이드를 순서대로 얹는다(defaults < preset < user, effectiveProperties 와
    /// 동일 계층). 사용자가 한 번도 건드리지 않은 키도 project.json 기본값으로 해석되게 하는 게 목적 —
    /// 종전 rawOverrides(id:presetOverrides:presetResourceRoot:)는 defaults 를 아예 안 실어 SceneDocument.
    /// resolveUserBindings 가 미변경 키를 저작 시점 baked value 그대로 남겼다(effectiveProperties/
    /// variantProperties·engine.userProperties 채널과 유효값 정의가 어긋나는 결함의 근본원인).
    public static func rawOverrides(id: String, projectDefaults: [WallpaperProperty],
                                    presetOverrides: [String: PropertyValue], presetResourceRoot: URL?) -> [String: Any] {
        var raw = rawDictionary(from: Dictionary(
            projectDefaults.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first }))
        raw.merge(rawDictionary(from: resolvingPresetResources(presetOverrides, root: presetResourceRoot))) { _, v in v }
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
        UserDefaults.standard.removeObject(forKey: resourceKey(id))
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

    /// 패키지가 선언한 리소스는 프리셋 루트에 속한 상대경로만 허용한다.
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
