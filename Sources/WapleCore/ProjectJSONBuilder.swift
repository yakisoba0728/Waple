import Foundation

/// project.json 문자열 생성(작업 5). WallpaperProperties.weUserPropertiesJSON 과 같은 관례.
public enum ProjectJSONBuilder {
    /// 원시 동영상 임포트용 최소 project.json. ProjectJSONParser 로 왕복 가능한 필드만 담는다.
    public static func videoProject(file: String, preview: String, title: String) -> String {
        let dict: [String: Any] = ["type": "video", "file": file, "preview": preview, "title": title]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
