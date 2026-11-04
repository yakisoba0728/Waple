import Foundation
import UniformTypeIdentifiers
import WapleCore

/// Mirrors the file picker restriction when accepting its selected URL.
enum PropertyResourceSelection {
    static func allowedContentTypes(for property: WallpaperProperty) -> [UTType] {
        switch property.fileType?.lowercased() {
        case "image": return [.image]
        case "video": return [.movie]
        default: return []
        }
    }

    static func accepts(_ url: URL, for property: WallpaperProperty) -> Bool {
        guard url.isFileURL else { return false }
        let allowed = allowedContentTypes(for: property)
        guard !allowed.isEmpty else { return true }
        guard let selected = UTType(filenameExtension: url.pathExtension) else { return false }
        return allowed.contains { selected.conforms(to: $0) }
    }
}
