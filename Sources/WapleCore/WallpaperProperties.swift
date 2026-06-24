import Foundation

public enum PropertyValue: Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case none
}

public struct WallpaperProperty: Equatable {
    public let key: String
    public let type: String
    public let value: PropertyValue
    public let order: Int?
    public let condition: String?

    public init(key: String, type: String, value: PropertyValue, order: Int?, condition: String?) {
        self.key = key
        self.type = type
        self.value = value
        self.order = order
        self.condition = condition
    }
}

public enum WallpaperProperties {
    public static func parse(generalProperties: [String: Any]) -> [WallpaperProperty] {
        var result: [WallpaperProperty] = []
        for (key, raw) in generalProperties {
            guard let dict = raw as? [String: Any] else { continue }
            let type = (dict["type"] as? String) ?? ""
            result.append(WallpaperProperty(
                key: key,
                type: type,
                value: parseValue(dict["value"], type: type),
                order: dict["order"] as? Int,
                condition: dict["condition"] as? String
            ))
        }
        return result.sorted {
            ($0.order ?? Int.max, $0.key) < ($1.order ?? Int.max, $1.key)
        }
    }

    private static func parseValue(_ raw: Any?, type: String) -> PropertyValue {
        switch type {
        case "bool", "checkbox":
            return .bool((raw as? Bool) ?? false)
        case "slider":
            return .number((raw as? Double) ?? 0)
        default:
            if let s = raw as? String { return .string(s) }
            if let b = raw as? Bool { return .bool(b) }
            if let n = raw as? Double { return .number(n) }
            return .none
        }
    }

    public static func parse(folderURL: URL) throws -> [WallpaperProperty] {
        let url = folderURL.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: url) else { throw ProjectParseError.fileNotFound }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProjectParseError.invalidJSON
        }
        let general = (obj["general"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        return parse(generalProperties: general)
    }

    public static func weUserPropertiesJSON(_ props: [WallpaperProperty]) -> String {
        var dict: [String: Any] = [:]
        for p in props {
            var inner: [String: Any] = ["type": p.type]
            switch p.value {
            case .string(let s): inner["value"] = s
            case .bool(let b):   inner["value"] = b
            case .number(let n): inner["value"] = n
            case .none:          break
            }
            dict[p.key] = inner
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
