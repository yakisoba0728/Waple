import AppKit
import WebKit
import WapleCore

public final class WebRenderer: NSObject, WallpaperRenderer, WKNavigationDelegate, WKScriptMessageHandler {
    public enum Mode { case web; case videoFallback }

    private let mode: Mode
    private var webView: WKWebView?
    private var pendingUserPropertiesJSON: String?

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
            let props = (try? WallpaperProperties.parse(folderURL: project.folderURL)) ?? []
            pendingUserPropertiesJSON = WallpaperProperties.weUserPropertiesJSON(props)
            web.load(URLRequest(url: URL(string: base + encoded)!))
        case .videoFallback:
            web.loadHTMLString(VideoFallbackHTML.html(forVideoFile: fileName),
                               baseURL: URL(string: base)!)
        }

        self.webView = web
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let json = pendingUserPropertiesJSON else { return }
        let js = """
        if (window.wallpaperPropertyListener && window.wallpaperPropertyListener.applyUserProperties) {
          window.wallpaperPropertyListener.applyUserProperties(\(json));
        }
        if (window.wallpaperPropertyListener && window.wallpaperPropertyListener.applyGeneralProperties) {
          window.wallpaperPropertyListener.applyGeneralProperties({ fps: 30 });
        }
        """
        webView.evaluateJavaScript(js)
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // MVP: randomFile 등 메시지 수신만(랜덤 파일 소스 없음 → no-op).
    }

    public func pause() {
        webView?.evaluateJavaScript(
            "if(window.wallpaperPropertyListener&&window.wallpaperPropertyListener.setPaused)window.wallpaperPropertyListener.setPaused(true);")
    }

    public func resume() {
        webView?.evaluateJavaScript(
            "if(window.wallpaperPropertyListener&&window.wallpaperPropertyListener.setPaused)window.wallpaperPropertyListener.setPaused(false);")
    }

    public func teardown() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "waple")
        webView?.removeFromSuperview()
        webView = nil
    }
}
