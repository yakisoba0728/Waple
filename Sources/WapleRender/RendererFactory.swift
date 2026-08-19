import Foundation
import WapleCore

public enum RendererFactory {
    /// **nonisolated 로 남겨야 한다 — @MainActor 를 붙이지 마라.**
    /// AppDelegate.captureSceneStill(F486)이 백그라운드 큐에서 이 팩토리를 부른다(마운트+GPU 대기를
    /// 메인에서 빼낸 것이 F486 이고, 격리를 붙이면 그 비격리 호출부가 컴파일되지 않아 자동으로 되돌아간다).
    ///
    /// 대가로 `.web` 분기의 `WebRenderer(mode:)` 생성이 "메인 액터 초기화자를 비격리 컨텍스트에서 호출"
    /// 진단을 남긴다(WebRenderer 는 WKNavigationDelegate 등 @MainActor 프로토콜 적합으로 격리가 **추론**된다).
    /// 지금은 SDK 어노테이션이 preconcurrency 로 강등돼 경고지만 **언어 모드를 .v6 로 올리면 에러가 된다** —
    /// 그때 F486 과 정면으로 부딪친다. 그 시점의 선택지는 둘이고, 둘 다 여기서 처리할 수 없다:
    ///  · 캡처 경로가 씬 전용이므로 팩토리를 거치지 않고 SceneRenderer 를 직접 만들게 한다(호출부 수정), 또는
    ///  · 캡처 경로를 뷰 없는 오프스크린 렌더 타깃으로 분리해 AppKit 의존 자체를 없앤다.
    /// ⚠️ `MainActor.assumeIsolated { WebRenderer(...) }` 로 덮는 것은 **안 된다** — captureSceneStill 은
    /// 백그라운드에서 이 함수를 부르고 프로젝트 타입을 가리지 않으므로(웹 프로젝트면 `as? SceneRenderer`
    /// 캐스트 실패로 nil 이 되는 것이 현재 동작), 웹 프로젝트에서 즉시 트랩이 된다.
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
