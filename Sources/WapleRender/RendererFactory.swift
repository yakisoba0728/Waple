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
            // F556: WKWebView(videoFallback)가 실제 재생 가능한 건 사실상 webm(VP8/VP9)뿐 — mkv/avi 등을
            // videoFallback 으로 라우팅하면 검은 화면인데 apply 성공으로 오표시된다. 재생 불가 컨테이너는
            // nil 반환(호출부가 지원 불가로 표면화).
            if !FFmpegConverter.isAvailable {
                return webViewPlayableContainer(url.pathExtension) ? WebRenderer(mode: .videoFallback) : nil
            }
            return VideoRenderer()
        case .scene:
            return SceneRenderer()
        default:
            return nil
        }
    }

    /// F556: WKWebView(.videoFallback)가 실제 재생 가능한 컨테이너인지 — 사실상 webm 뿐.
    static func webViewPlayableContainer(_ ext: String) -> Bool {
        ext.lowercased() == "webm"
    }
}
