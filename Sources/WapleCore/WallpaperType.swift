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

    public var isSupportedInMVP: Bool { self == .video || self == .web || self == .scene || self == .preset }
}

/// 비디오 컨테이너 확장자 분류 — 단일 소스(F230). VideoRenderer(재생 판단)와
/// WallpaperCompatibilityAnalyzer/DeepScan(진단) 이 전부 이걸 참조해야 세 곳이 드리프트하지 않는다.
/// (WapleCore 는 WapleRender 에 의존하지 않으므로 canonical 값은 여기 두고 VideoRenderer 가 이걸 가리킨다.)
public enum VideoFormats {
    /// AVFoundation 이 변환 없이 바로 재생하는 컨테이너.
    public static let nativeExtensions: Set<String> = ["mp4", "m4v", "mov"]
}
