import WapleCore

public enum RendererFactory {
    /// MVP: video 만 지원. 나머지 타입은 nil(미지원).
    public static func makeRenderer(for type: WallpaperType) -> WallpaperRenderer? {
        switch type {
        case .video: return VideoRenderer()
        default: return nil
        }
    }
}
