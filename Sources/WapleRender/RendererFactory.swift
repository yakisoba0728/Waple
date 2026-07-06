import Foundation
import WapleCore

public enum RendererFactory {
    public static func makeRenderer(for project: WallpaperProject) -> WallpaperRenderer? {
        switch project.type {
        case .web:
            return WebRenderer(mode: .web)
        case .video:
            guard let url = WallpaperPathSecurity.containedFileURL(project.fileName, root: project.folderURL) else {
                return nil
            }
            if VideoRenderer.isSupportedContainer(url) { return VideoRenderer() }
            guard FFmpegConverter.needsConversion(url) else { return nil }
            // Common non-native containers: ffmpeg 있으면 네이티브 변환 경유(VideoRenderer), 없으면 WKWebView 폴백.
            return FFmpegConverter.isAvailable ? VideoRenderer() : WebRenderer(mode: .videoFallback)
        case .scene:
            return SceneRenderer()
        default:
            return nil
        }
    }
}
