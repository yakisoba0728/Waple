import Foundation
import WapleCore

public enum RendererFactory {
    /// 타입 + 코덱으로 렌더러를 라우팅. MVP: video / web 지원, webm 등 미지원 코덱은 WebRenderer 폴백.
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
        default:
            return nil
        }
    }
}
