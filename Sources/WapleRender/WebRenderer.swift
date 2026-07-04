import AppKit
import WebKit
import WapleCore

public final class WebRenderer: NSObject, WallpaperRenderer, WKNavigationDelegate, WKScriptMessageHandler {
    public enum Mode { case web; case videoFallback }

    private let mode: Mode
    private var webView: WKWebView?
    /// 테스트 전용 접근자(JS 상태 검증).
    public var webViewForTesting: WKWebView? { webView }
    private var pendingUserPropertiesJSON: String?
    private var audioProvider: SystemAudioSpectrumProvider?
    private var occlusionObserver: NSObjectProtocol?
    private var mouseMonitor: Any?
    private var clickMonitor: Any?
    private var interactionWindow: NSWindow?
    private var lastMouseForward = CFAbsoluteTimeGetCurrent()
    private var pausedManually = false

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
            // 유저 오버라이드 병합(속성 편집 UI) — WE 의 "저장된 사용자 값" 의미론.
            let effective = WallpaperProperties.applying(overrides: UserPropertyStore.overrides(id: project.id), to: props)
            pendingUserPropertiesJSON = WallpaperProperties.weUserPropertiesJSON(effective)
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

        // 가림 시 정지(절전 — 씬/동영상과 동일). 창 없음(headless) → no-op.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self, weak web] note in
            guard let self, let win = web?.window, (note.object as? NSWindow) === win else { return }
            if win.occlusionState.contains(.visible) {
                if !self.pausedManually { self.resume() }
            } else {
                self.setPausedJS(true); self.audioProvider?.stop()
            }
        }
        // 마우스 전달(WE 동작): 전역 mouseMoved(권한 불요) → 뷰 좌표 → DOM mousemove. ~30Hz 스로틀.
        if mode == .web {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self, weak web] _ in
                guard let self, let web, let win = web.window else { return }
                let now = CFAbsoluteTimeGetCurrent()
                guard now - self.lastMouseForward > 1.0 / 30.0 else { return }
                self.lastMouseForward = now
                let inWindow = win.convertPoint(fromScreen: NSEvent.mouseLocation)
                let inView = web.convert(inWindow, from: nil)
                guard web.bounds.contains(inView) else { return }
                // 웹 좌표는 상단 원점 — AppKit 하단 원점에서 반전.
                let x = Int(inView.x), y = Int(web.bounds.height - inView.y)
                web.evaluateJavaScript("window.__wapleMouse(\(x), \(y));")
            }
            // 바탕화면 직접 클릭 전달은 아이콘 클릭과 충돌해 혼란(실사용 피드백 2026-07-05) — 제거.
            // 입력은 조작 창(openInteractionPanel)이 담당한다.
        }
    }

    /// 조작 창: 데스크탑 WKWebView 의 라이브 미리보기(스냅샷 미러) + 실입력 프록시.
    /// 창에서의 마우스/휠/키 입력을 합성 DOM 이벤트로 데스크탑 인스턴스에 재게시 → 실시간 연동.
    public func openInteractionPanel() {
        guard let web = webView else { return }
        if let existing = interactionWindow { existing.makeKeyAndOrderFront(nil); return }
        let proxy = WebInputProxyView(target: web)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "웹 월페이퍼 조작 (실시간 연동)"
        win.contentView = proxy
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        interactionWindow = win
        proxy.start()
    }

    private func setPausedJS(_ paused: Bool) {
        webView?.evaluateJavaScript(
            "if(window.wallpaperPropertyListener&&window.wallpaperPropertyListener.setPaused)window.wallpaperPropertyListener.setPaused(\(paused));")
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // didFinish 는 모든 main-frame 내비게이션마다 발생한다. 속성 주입/오디오 시작은
        // 최초 로드 1회만 수행해야 하므로, 소비 후 pending 을 비워 멱등하게 만든다.
        guard let json = pendingUserPropertiesJSON else { return }
        pendingUserPropertiesJSON = nil
        // 브리지 pending/flush 경유 — 리스너가 나중에 등록돼도 세터 훅이 전달(WE 의미론).
        let js = "window.__wapleApplyProps(\(json), { fps: 30 });"
        webView.evaluateJavaScript(js) { _, error in
            if let error { NSLog("%@", "[Waple] property injection failed: \(error)") }
        }
        audioProvider?.start()
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let type = dict["type"] as? String else { return }
        if type == "mediaListen" {
            startMediaPolling()
        }
    }

    // MARK: - 미디어 연동(페이지가 wallpaperRegisterMedia* 를 등록한 경우에만 폴링)

    /// 테스트 주입용. nil 이면 AppleScript(Music/Spotify) 프로바이더.
    public var nowPlayingProvider: NowPlayingProvider?
    private var mediaPoller: MediaPoller?

    private func startMediaPolling() {
        guard mediaPoller == nil else { return }
        // 5초 간격(MediaPoller): AppleScript 비용(수십 ms)과 체감 실시간성의 균형. 타임라인은 틱마다 배달.
        let poller = MediaPoller(provider: nowPlayingProvider ?? AppleScriptNowPlayingProvider())
        // weak self — poller 콜백이 self 를 소유하면 self→poller→콜백 순환(teardown 전 누수).
        let js: (String, String) -> Void = { [weak self] kind, obj in
            self?.webView?.evaluateJavaScript("window.__wapleMedia && window.__wapleMedia('\(kind)', \(obj));",
                                              completionHandler: nil)
        }
        func q(_ s: String) -> String {
            (try? String(data: JSONEncoder().encode(s), encoding: .utf8) ?? "\"\"") ?? "\"\""
        }
        poller.onPlayback = { info in
            js("status", "{ state: \(info.state.rawValue) }")
            js("playback", "{ state: \(info.state.rawValue) }")
        }
        poller.onProperties = { info in
            js("properties", "{ title: \(q(info.title)), artist: \(q(info.artist)), albumTitle: \(q(info.album)), subTitle: \(q(info.artist)) }")
        }
        poller.onTimeline = { info in
            js("timeline", "{ position: \(info.position), duration: \(info.duration) }")
        }
        // 썸네일(웹 규약 — 실물 3639973107 소비): thumbnail = dataURL 문자열, 색은 "#RRGGBB".
        // 아트워크 실패 시 poller 가 이벤트 자체를 생략(graceful).
        poller.onThumbnail = { _, artwork in
            guard let p = ArtworkColors.palette(imageData: artwork) else { return }
            let mime = artwork.starts(with: [0x89, 0x50]) ? "image/png" : "image/jpeg"
            let dataURL = "data:\(mime);base64,\(artwork.base64EncodedString())"
            let hx = ArtworkColors.hexString
            js("thumbnail", """
                { thumbnail: \(q(dataURL)), primaryColor: \(q(hx(p.primary))), \
                secondaryColor: \(q(hx(p.secondary))), tertiaryColor: \(q(hx(p.tertiary))), \
                textColor: \(q(hx(p.textColor))), highContrastColor: \(q(hx(p.highContrast))), hasThumbnail: true }
                """)
        }
        poller.start()
        mediaPoller = poller
    }

    public func pause() {
        pausedManually = true
        setPausedJS(true)
        audioProvider?.stop()
    }

    public func resume() {
        pausedManually = false
        setPausedJS(false)
        audioProvider?.start()
    }

    public func teardown() {
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        occlusionObserver = nil
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
        if let c = clickMonitor { NSEvent.removeMonitor(c) }
        clickMonitor = nil
        (interactionWindow?.contentView as? WebInputProxyView)?.stop()
        interactionWindow?.orderOut(nil)
        interactionWindow = nil
        audioProvider?.stop()
        audioProvider = nil
        mediaPoller?.stop()
        mediaPoller = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "waple")
        webView?.removeFromSuperview()
        webView = nil
    }
}
