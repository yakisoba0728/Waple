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
                return VideoRenderer.isSupportedContainer(url) ? VideoRenderer() : WebRenderer(mode: .videoFallback)
            }
            return VideoRenderer()
        case .scene:
            return SceneRenderer()
        default:
            return nil
        }
    }
}
