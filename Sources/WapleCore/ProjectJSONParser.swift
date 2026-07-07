import Foundation

public enum ProjectParseError: Error, Equatable {
    case fileNotFound
    case invalidJSON
}

public enum ProjectJSONParser {
    public static func parse(folderURL: URL) throws -> WallpaperProject {
        let projectURL = folderURL.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL) else {
            throw ProjectParseError.fileNotFound
        }
        return try parse(data: data, folderURL: folderURL)
    }

    public static func parse(data: Data, folderURL: URL) throws -> WallpaperProject {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProjectParseError.invalidJSON
        }
        let id = folderURL.lastPathComponent
        let type = WallpaperType.from(obj["type"] as? String)
        let rawTitle = obj["title"] as? String
        let title = (rawTitle?.isEmpty == false) ? rawTitle! : id
        let tags = (obj["tags"] as? [String]) ?? []
        let presetOverrides = parsePresetOverrides(obj["preset"])
        return WallpaperProject(
            id: id,
            type: type,
            fileName: WallpaperPathSecurity.normalizedRelativePath(obj["file"] as? String),
            previewName: WallpaperPathSecurity.normalizedRelativePath(obj["preview"] as? String),
            title: title,
            tags: tags,
            contentRating: obj["contentrating"] as? String,
            workshopId: parseStringOrNumber(obj["workshopid"]),
            dependency: WallpaperPathSecurity.normalizedPathComponent(obj["dependency"] as? String),
            folderURL: folderURL,
            presetOverrides: presetOverrides,
            presetFolderURL: type == .preset ? folderURL : nil
        )
    }

    private static func parsePresetOverrides(_ value: Any?) -> [String: PropertyValue] {
        guard let raw = value as? [String: Any] else { return [:] }
        var out: [String: PropertyValue] = [:]
        for (key, value) in raw {
            if value is NSNull { continue }
            if let bool = value as? Bool {
                out[key] = .bool(bool)
            } else if let number = parseNumber(value) {
                out[key] = .number(number)
            } else if let string = value as? String {
                out[key] = .string(string)
            }
        }
        return out
    }

    private static func parseNumber(_ value: Any) -> Double? {
        switch value {
        case let double as Double:
            return double
        case let int as Int:
            return Double(int)
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return number.doubleValue
        default:
            return nil
        }
    }

    private static func parseStringOrNumber(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.stringValue
    }
}
