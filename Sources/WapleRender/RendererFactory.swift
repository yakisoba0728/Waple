import Foundation
import WapleCore

public enum RendererFactory {
    /// SP1: scene 은 실험 플래그 ON 일 때만 라우팅(부분 렌더 → 사용자 미노출).
    public static var experimentalSceneEnabled = false

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
            return experimentalSceneEnabled ? SceneRenderer() : nil
        default:
            return nil
        }
    }
}
