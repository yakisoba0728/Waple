import Foundation

public enum WallpaperType: Equatable {
    case video
    case scene
    case web
    case application
    case preset
    case unknown(String)

    /// project.json 의 "type" 값(부재 가능)을 정규화한다. 부재/빈 문자열은 프리셋으로 본다.
    public static func from(_ raw: String?) -> WallpaperType {
        guard let raw = raw, !raw.isEmpty else { return .preset }
        switch raw.lowercased() {
        case "video": return .video
        case "scene": return .scene
        case "web": return .web
        case "application": return .application
        case "preset": return .preset
        default: return .unknown(raw)
        }
    }

    /// 라이브러리 인덱스에 저장할 안정적인 문자열. `from` 과 왕복 가능.
    public var storageString: String {
        switch self {
        case .video: return "video"
        case .scene: return "scene"
        case .web: return "web"
        case .application: return "application"
        case .preset: return "preset"
        case .unknown(let s): return s
        }
    }

    public var isSupportedInMVP: Bool { self == .video || self == .web || self == .scene }
}
