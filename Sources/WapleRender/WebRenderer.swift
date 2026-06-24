import AppKit
import WebKit
import WapleCore

public final class WebRenderer: NSObject, WallpaperRenderer, WKNavigationDelegate, WKScriptMessageHandler {
    public enum Mode { case web; case videoFallback }

    private let mode: Mode
    private var webView: WKWebView?
    private var pendingUserPropertiesJSON: String?
    private var audioProvider: SystemAudioSpectrumProvider?

    public init(mode: Mode) {
        self.mode = mode
        super.init()
    }

    public func mount(in container: NSView, project: WallpaperProject) throws {
        guard let fileName = project.fileName else { throw RendererError.assetMissing }
        let fileURL = project.folderURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw RendererError.assetMissing }

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(WallpaperSchemeHandler(rootURL: project.folderURL),
                                   forURLScheme: WallpaperSchemeHandler.scheme)
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: WallpaperBridgeJS.source,
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(self, name: "waple")
        config.userContentController = ucc

        let web = WKWebView(frame: container.bounds, configuration: config)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.addSubview(web)

        let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let base = "\(WallpaperSchemeHandler.scheme)://\(WallpaperSchemeHandler.host)/"

        switch mode {
        case .web:
            guard let url = URL(string: base + encoded) else { throw RendererError.assetMissing }
            // 속성 부재(파일 없음)는 정상이지만, 파싱 오류는 사용자 커스터마이즈가 통째로
            // 사라지므로 무음 폴백([])하되 로깅해 진단 가능하게 한다.
            var props: [WallpaperProperty] = []
            do {
                props = try WallpaperProperties.parse(folderURL: project.folderURL)
            } catch ProjectParseError.fileNotFound {
                // project.json 없음/속성 없음 — 정상.
            } catch {
                NSLog("%@", "[Waple] failed to parse properties for \(project.folderURL.path): \(error)")
            }
            pendingUserPropertiesJSON = WallpaperProperties.weUserPropertiesJSON(props)
            web.load(URLRequest(url: url))
            let provider = SystemAudioSpectrumProvider()
            provider.onFrame = { [weak self] frame in
                let csv = frame.map { String(format: "%.3f", $0) }.joined(separator: ",")
                self?.webView?.evaluateJavaScript("if(window.__wapleAudio)window.__wapleAudio([\(csv)]);")
            }
            audioProvider = provider
        case .videoFallback:
            guard let baseURL = URL(string: base) else { throw RendererError.assetMissing }
            web.loadHTMLString(VideoFallbackHTML.html(forVideoFile: fileName), baseURL: baseURL)
        }

        self.webView = web
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // didFinish 는 모든 main-frame 내비게이션마다 발생한다. 속성 주입/오디오 시작은
        // 최초 로드 1회만 수행해야 하므로, 소비 후 pending 을 비워 멱등하게 만든다.
        guard let json = pendingUserPropertiesJSON else { return }
        pendingUserPropertiesJSON = nil
        let js = """
        if (window.wallpaperPropertyListener && window.wallpaperPropertyListener.applyUserProperties) {
          window.wallpaperPropertyListener.applyUserProperties(\(json));
        }
        if (window.wallpaperPropertyListener && window.wallpaperPropertyListener.applyGeneralProperties) {
          window.wallpaperPropertyListener.applyGeneralProperties({ fps: 30 });
        }
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error { NSLog("%@", "[Waple] property injection failed: \(error)") }
        }
        audioProvider?.start()
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // MVP: randomFile 등 메시지 수신만(랜덤 파일 소스 없음 → no-op).
    }

    public func pause() {
        webView?.evaluateJavaScript(
            "if(window.wallpaperPropertyListener&&window.wallpaperPropertyListener.setPaused)window.wallpaperPropertyListener.setPaused(true);")
        audioProvider?.stop()
    }

    public func resume() {
        webView?.evaluateJavaScript(
            "if(window.wallpaperPropertyListener&&window.wallpaperPropertyListener.setPaused)window.wallpaperPropertyListener.setPaused(false);")
        audioProvider?.start()
    }

    public func teardown() {
        audioProvider?.stop()
        audioProvider = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "waple")
        webView?.removeFromSuperview()
        webView = nil
    }
}
