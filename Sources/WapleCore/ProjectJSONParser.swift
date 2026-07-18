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
        return parse(json: obj, folderURL: folderURL)
    }

    /// F231: project.json 을 호출자가 이미 별도 목적(예: WallpaperCompatibilityAnalyzer 의 raw 필드
    /// 검사)으로 파싱해 `[String: Any]` 를 들고 있을 때 파일을 다시 읽고 다시 JSON 파싱하지 않도록 하는
    /// 진입점. `obj` 는 이미 유효한 JSON 오브젝트임이 보장되므로(호출자가 그 자체로 얻었음) throws 가
    /// 필요 없다 — 파싱 실패 가능성은 위 `parse(data:folderURL:)` 의 guard 에서만 발생한다.
    public static func parse(json obj: [String: Any], folderURL: URL) -> WallpaperProject {
        // F194: 폴더 basename 은 관리 위치 이동·zip 재래핑(임포트 관례상 `Wallpaper/` 등 비유일 래퍼명)에
        // 안정적이지 않다. project.json 이 워크샵 id 를 선언하면(전역 유일) identity 로 우선 채택하고,
        // 없을 때만 종전대로 폴더명에 폴백한다 — steamcmd 코퍼스는 폴더명 자체가 워크샵 id 라 무변화.
        let workshopId = parseStringOrNumber(obj["workshopid"])
        let id = workshopId ?? folderURL.lastPathComponent
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
            workshopId: workshopId,
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
            // parseNumber는 CFBoolean을 배제하므로 숫자 검사를 먼저 — NSNumber(0/1)의 as? Bool 둔갑 방지
            if let number = parseNumber(value) {
                out[key] = .number(number)
            } else if let bool = value as? Bool {
                out[key] = .bool(bool)
            } else if let string = value as? String {
                out[key] = .string(string)
            }
        }
        return out
    }

    private static func parseNumber(_ value: Any) -> Double? {
        // CFBoolean 선배제 — 아래 as Double/Int 브리징이 CFBoolean도 1.0/0.0 으로 통과시키므로
        // NSNumber 케이스의 where 만으론 불충분(JSON true 가 number 로 둔갑).
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        switch value {
        case let double as Double:
            return double
        case let int as Int:
            return Double(int)
        case let number as NSNumber:
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
