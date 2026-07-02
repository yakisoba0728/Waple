import Foundation

public enum PropertyValue: Equatable, Hashable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case none
}

public struct WallpaperProperty: Equatable {
    public struct Option: Equatable {
        public let label: String
        public let value: PropertyValue
        public init(label: String, value: PropertyValue) { self.label = label; self.value = value }
    }

    public let key: String
    public let type: String
    public var value: PropertyValue
    public let order: Int?
    public let condition: String?
    // 편집 UI 메타(project.json 원문): 라벨/슬라이더 범위/콤보 옵션.
    public var text: String? = nil
    public var min: Double? = nil
    public var max: Double? = nil
    public var step: Double? = nil
    public var options: [Option]? = nil

    public init(key: String, type: String, value: PropertyValue, order: Int?, condition: String?,
                text: String? = nil, min: Double? = nil, max: Double? = nil, step: Double? = nil,
                options: [Option]? = nil) {
        self.key = key
        self.type = type
        self.value = value
        self.order = order
        self.condition = condition
        self.text = text
        self.min = min
        self.max = max
        self.step = step
        self.options = options
    }
}

public enum WallpaperProperties {
    public static func parse(generalProperties: [String: Any]) -> [WallpaperProperty] {
        var result: [WallpaperProperty] = []
        for (key, raw) in generalProperties {
            guard let dict = raw as? [String: Any] else { continue }
            let type = (dict["type"] as? String) ?? ""
            var options: [WallpaperProperty.Option]? = nil
            if let opts = dict["options"] as? [[String: Any]] {
                options = opts.map { WallpaperProperty.Option(label: ($0["label"] as? String) ?? "",
                                                              value: parseValue($0["value"], type: "")) }
            }
            func dbl(_ v: Any?) -> Double? {
                if let d = v as? Double { return d }
                if let i = v as? Int { return Double(i) }
                return nil
            }
            result.append(WallpaperProperty(
                key: key,
                type: type,
                value: parseValue(dict["value"], type: type),
                order: dict["order"] as? Int,
                condition: dict["condition"] as? String,
                text: dict["text"] as? String,
                min: dbl(dict["min"]), max: dbl(dict["max"]), step: dbl(dict["step"]),
                options: options
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

    /// 유저 오버라이드를 기본값 위에 병합한 효과값 목록(순수).
    public static func applying(overrides: [String: PropertyValue], to props: [WallpaperProperty]) -> [WallpaperProperty] {
        props.map { p in
            guard let o = overrides[p.key] else { return p }
            var out = p
            out.value = o
            return out
        }
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
