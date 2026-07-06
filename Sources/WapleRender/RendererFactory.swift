import Foundation
import WapleCore

public enum RendererFactory {
    public static func makeRenderer(for project: WallpaperProject) -> WallpaperRenderer? {
        switch project.type {
        case .web:
            return WebRenderer(mode: .web)
        case .video:
            if let file = project.fileName {
                let url = project.folderURL.appendingPathComponent(file)
                if VideoRenderer.isSupportedContainer(url) { return VideoRenderer() }
                // mkv/avi/webm: ffmpeg 있으면 네이티브 변환 경유(VideoRenderer), 없으면 WKWebView 폴백(기존 동작).
                return FFmpegConverter.isAvailable ? VideoRenderer() : WebRenderer(mode: .videoFallback)
            }
            return VideoRenderer()
        case .scene:
            return SceneRenderer()
        default:
            return nil
        }
    }
}
