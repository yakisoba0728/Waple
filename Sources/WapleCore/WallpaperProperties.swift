import Foundation

public enum PropertyValue: Equatable, Hashable, Sendable {   // 페이로드 String/Bool/Double — 값 타입
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
    public let order: Double?
    public let condition: String?
    // 편집 UI 메타(project.json 원문): 라벨/슬라이더 범위/콤보 옵션.
    public var text: String? = nil
    public var min: Double? = nil
    public var max: Double? = nil
    public var step: Double? = nil
    public var options: [Option]? = nil
    public var index: Int? = nil
    public var mode: String? = nil
    public var fileType: String? = nil

    public init(key: String, type: String, value: PropertyValue, order: Double?, condition: String?,
                text: String? = nil, min: Double? = nil, max: Double? = nil, step: Double? = nil,
                options: [Option]? = nil, index: Int? = nil, mode: String? = nil, fileType: String? = nil) {
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
        self.index = index
        self.mode = mode
        self.fileType = fileType
    }
}

public enum WallpaperProperties {
    public static func parse(generalProperties: [String: Any]) -> [WallpaperProperty] {
        parse(generalProperties: generalProperties, localization: nil)
    }

    public static func parse(generalProperties: [String: Any],
                             localization: [String: Any]?,
                             localeIdentifier: String = Locale.preferredLanguages.first ?? Locale.current.identifier) -> [WallpaperProperty] {
        let localized = localizationTable(localization, localeIdentifier: localeIdentifier)
        var result: [WallpaperProperty] = []
        for (key, raw) in generalProperties {
            guard let dict = raw as? [String: Any] else { continue }
            let type = (dict["type"] as? String) ?? ""
            var options: [WallpaperProperty.Option]? = nil
            if let opts = dict["options"] as? [[String: Any]] {
                options = opts.map { WallpaperProperty.Option(label: localizedString(($0["label"] as? String) ?? "", table: localized) ?? "",
                                                              value: parseValue($0["value"], type: "")) }
            }
            result.append(WallpaperProperty(
                key: key,
                type: type,
                value: parseValue(dict["value"], type: type),
                order: parseNumber(dict["order"]),
                condition: dict["condition"] as? String,
                text: localizedString(dict["text"] as? String, table: localized),
                min: parseNumber(dict["min"]), max: parseNumber(dict["max"]), step: parseNumber(dict["step"]),
                options: options,
                index: parseInt(dict["index"]),
                mode: dict["mode"] as? String,
                fileType: dict["fileType"] as? String
            ))
        }
        return result.sorted {
            ($0.order ?? Double.greatestFiniteMagnitude, $0.key) < ($1.order ?? Double.greatestFiniteMagnitude, $1.key)
        }
    }

    private static func parseValue(_ raw: Any?, type: String) -> PropertyValue {
        switch type.lowercased() {
        case "bool", "checkbox":
            // WE project.json 은 종종 bool 을 문자열로 싣는다("1"/"true") — 네이티브 Bool 경로(무회귀)
            // 다음에만 문자열을 관용 파스. 숫자 NSNumber(0/1)의 as? Bool 둔갑은 기존 동작 그대로 보존.
            if let b = raw as? Bool { return .bool(b) }
            if let s = raw as? String { return .bool(s == "true" || (lenientFloat(s) ?? 0) != 0) }
            return .bool(false)
        case "slider":
            // 마찬가지로 문자열 숫자("0.5") 관용 — parseNumber(무회귀, Double 정밀도 보존) 우선 시도 후
            // 실패(비숫자·String)할 때만 lenientFloat 폴백. lenientFloat(raw) 를 바로 쓰지 않는 이유:
            // NSNumber(bool) 이 Swift 에서 `as? Double` 로도 브리지되어(1.0/0.0) parseNumber 의 CFBoolean
            // 배제를 무력화한다 — 문자열로 이미 좁힌 값에만 적용해 그 함정을 피한다.
            if let n = parseNumber(raw) { return .number(n) }
            if let s = raw as? String, let f = lenientFloat(s) { return .number(Double(f)) }
            return .number(0)
        default:
            if let s = raw as? String { return .string(s) }
            if let b = raw as? Bool { return .bool(b) }
            if let n = parseNumber(raw) { return .number(n) }
            return .none
        }
    }

    private static func parseNumber(_ raw: Any?) -> Double? {
        if let n = raw as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : n.doubleValue
        }
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        return nil
    }

    private static func parseInt(_ raw: Any?) -> Int? {
        if let n = raw as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : n.intValue
        }
        if let i = raw as? Int { return i }
        // F530-sweep: project.json 은 신뢰 경계 밖이다 — `{"value": 1e300}` 하나로
        // 맨 `Int(d)` 가 트랩했다. 이 자리는 스윕 6단계가 전부 놓쳤고
        // scripts/spec/check_int_narrowing.py 의 R1 이 잡아냈다.
        if let d = raw as? Double { return safeInt(d) }
        return nil
    }

    public static func parse(folderURL: URL) throws -> [WallpaperProperty] {
        let url = folderURL.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: url) else { throw ProjectParseError.fileNotFound }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProjectParseError.invalidJSON
        }
        let generalObject = obj["general"] as? [String: Any]
        let general = generalObject?["properties"] as? [String: Any] ?? [:]
        let localization = generalObject?["localization"] as? [String: Any]
        return parse(generalProperties: general, localization: localization)
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

    private static func localizationTable(_ localization: [String: Any]?,
                                          localeIdentifier: String) -> [String: String] {
        guard let localization else { return [:] }
        let normalized = localeIdentifier.replacingOccurrences(of: "_", with: "-").lowercased()
        let language = normalized.split(separator: "-").first.map(String.init)
        let candidates = [
            normalized,
            language,
            "en-us",
            "en"
        ].compactMap { $0 }

        for candidate in candidates {
            if let table = exactLocalizationTable(localization, key: candidate) { return table }
            if candidate.count == 2,
               let key = localization.keys.first(where: { $0.lowercased().hasPrefix(candidate + "-") }),
               let table = exactLocalizationTable(localization, key: key) {
                return table
            }
        }

        for key in localization.keys.sorted() {
            if let table = exactLocalizationTable(localization, key: key) { return table }
        }
        return [:]
    }

    private static func exactLocalizationTable(_ localization: [String: Any], key: String) -> [String: String]? {
        guard let raw = localization.first(where: { $0.key.lowercased() == key.lowercased() })?.value as? [String: Any] else {
            return nil
        }
        return raw.reduce(into: [String: String]()) { out, pair in
            if let value = pair.value as? String { out[pair.key] = value }
        }
    }

    private static func localizedString(_ raw: String?, table: [String: String]) -> String? {
        guard let raw else { return nil }
        return table[raw] ?? raw
    }
}
