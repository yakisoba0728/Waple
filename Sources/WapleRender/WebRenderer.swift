import AppKit
// @preconcurrency 는 델리게이트 witness 문제의 해법이 **아니었다**(실측 run 32218275170:
// 경고가 그대로 남았다). 게이트의 해법은 async 델리게이트 구현이고 근거는 그 메서드 주석에 있다.
// 여기 @preconcurrency 를 남기는 이유는 별개다 — WebKit SDK 격리 애너테이션이 만드는
// 부수 진단(초기화자·프로퍼티 접근)을 줄인다. 게이트와는 무관하니 게이트를 고치려고
// 이 줄을 만지지 마라.
@preconcurrency import WebKit
import WapleCore

/// WKUserContentController 는 등록된 메시지 핸들러를 강참조한다(Apple 문서 명시). WebRenderer 가
/// 자신을 직접 등록하면 self→webView→configuration→userContentController→self 순환이 생겨, 이 순환이
/// 유지되는 한 self 의 참조 카운트가 0 에 도달하지 못한다 — teardown() 을 명시적으로 부르지 않는
/// 경로에서는 `deinit { teardown() }` 안전망 자체가 실행되지 않는다(F386). ucc 에는 self 대신 이
/// 프록시를 등록해 실제 리스너를 약하게만 참조하게 하여 순환을 원천 차단한다(표준 WKWebView 패턴).
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

public final class WebRenderer: NSObject, WallpaperRenderer, WKNavigationDelegate, WKScriptMessageHandler,
                                NSWindowDelegate {
    public enum Mode { case web; case videoFallback }

    private let mode: Mode
    private var webView: WKWebView?
    /// 테스트 전용 접근자(JS 상태 검증).
    public var webViewForTesting: WKWebView? { webView }
    var mediaPollingForTesting: Bool {
        mediaPoller?.isRunningForTesting ?? false
    }
    private var userPropertiesJSON: String?
    private var userPropertiesByKey: [String: WallpaperProperty] = [:]
    private var projectRootURL: URL?
    var audioProviderFactory: () -> AudioSpectrumProviding = { SystemAudioSpectrumProvider() }
    private var audioProvider: AudioSpectrumProviding?
    private var hasAudioListener = false
    private var occlusionObserver: NSObjectProtocol?
    private var mouseMonitor: Any?
    private var interactionWindow: NSWindow?
    private var lastMouseForward = CFAbsoluteTimeGetCurrent()
    private var pausedManually = false
    /// 가림으로 자동 정지했는지 — visible 복귀 시 자동 재개 판단(수동 pause 와 구분, VideoRenderer 패턴).
    private(set) var pausedByOcclusion = false
    private var effectivePauseApplied = false
    private var isEffectivelyPaused: Bool { pausedManually || pausedByOcclusion }
    private var userSelectedResourceOverrides: [String: String] = [:]

    // MARK: F840 — 페이지 유발 파일시스템 열거 상한
    //
    // randomFile 브리지 메시지는 인자 타입만 검증하고 곧장 재귀 디렉터리 열거(+엔트리별 stat)를
    // 백그라운드에 띄웠다. JS 한 줄(`for(;;) wallpaperRequestRandomFileForProperty(k, cb)`)이면
    // 워크가 수천 개 동시에 뜨고, deliverFetchAllDirectories 는 didFinish 마다 같은 워크를 자동 실행한다.
    // 세 방향으로 막는다: 인-플라이트 개수, 열거 엔트리 수, 브리지 문자열 길이.

    /// 동시에 진행 가능한 재귀 디렉터리 열거 수(randomFile + fetchall 공용). 초과 요청은 빈 응답.
    private static let maxInFlightDirectoryWalks = 2
    /// 열거 1회가 방문할 엔트리 수 상한 — 사용자가 홈 디렉터리를 고른 경우의 폭주도 여기서 끊긴다.
    /// nonisolated: 이 클래스는 @MainActor 프로토콜 적합으로 멤버 전체가 메인 액터로 추론되고, 그러면
    /// **static let 도 격리된다**(AppDelegate:430 의 `SettingsView.minHeight` 진단이 같은 사례). 아래
    /// regularFiles 는 백그라운드 큐 전용(F573)이라 이 상수를 격리 밖에서 읽어야 한다.
    nonisolated private static let maxEnumeratedEntries = 20_000
    /// 브리지 문자열 인자(name/requestId) 길이 상한(바이트). 초과 메시지는 폐기.
    private static let maxBridgeStringBytes = 1024
    /// 진행 중인 재귀 열거 수. 메인 큐에서만 읽고 쓴다(브리지 메시지·didFinish·완료 콜백 전부 메인).
    private var inFlightDirectoryWalks = 0

    public init(mode: Mode) {
        self.mode = mode
        super.init()
    }

    /// teardown 미호출 경로 안전망(SceneRenderer.deinit 과 동일 패턴 — 감사 L1). teardown() 은 각 필드를
    /// 옵셔널 해제로 정리해 멱등이라 마운트 전/teardown 후 재호출도 안전.
    deinit {
        teardown()
    }

    public func mount(in container: NSView, project: WallpaperProject) throws {
        // 감사 V06: 재마운트 시 선행 정리 — 방치하면 이전 WKWebView 가 container 에 잔존하고
        // occlusionObserver/mouseMonitor 핸들이 덮여 teardown 로도 해제 불가능하게 누수된다
        // (SceneRenderer.mount/VideoRenderer.mount 와 대칭). teardown 은 멱등이라 첫 마운트도 안전.
        teardown()
        guard let fileName = WallpaperPathSecurity.normalizedRelativePath(project.fileName),
              let fileURL = WallpaperPathSecurity.containedFileURL(fileName, root: project.folderURL) else {
            throw RendererError.assetMissing
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw RendererError.assetMissing }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(WallpaperSchemeHandler(rootURL: project.folderURL),
                                   forURLScheme: WallpaperSchemeHandler.scheme)
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: WebHardPauseJS.source,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: WallpaperBridgeJS.source,
                                       injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.add(WeakScriptMessageHandler(target: self), name: "waple")  // F386: self 강참조 순환 차단
        config.userContentController = ucc

        let web = WKWebView(frame: container.bounds, configuration: config)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.addSubview(web)
        self.webView = web

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
            let mergedOverrides = UserPropertyStore.overrides(
                id: project.id,
                presetOverrides: project.presetOverrides,
                presetResourceRoot: project.presetFolderURL
            )
            let effective = WallpaperProperties.applying(overrides: mergedOverrides, to: props)
            userPropertiesJSON = WallpaperProperties.weUserPropertiesJSON(effective)
            userPropertiesByKey = Dictionary(uniqueKeysWithValues: effective.map { ($0.key, $0) })
            // 절대경로 허용목록은 effective 에 실제 반영된 병합 오버라이드 기준 — 유저 직접 선택 외에
            // 프리셋 리소스 해석(resolvingPresetResources, 프리셋 폴더 봉쇄 검증 완료)의 절대경로도 포함.
            userSelectedResourceOverrides = Self.absoluteResourceOverrides(from: mergedOverrides)
            projectRootURL = project.folderURL.standardizedFileURL
            web.load(URLRequest(url: url))
            let provider = audioProviderFactory()
            provider.onFrame = { [weak self] frame in
                // F840-sweep: `String(format: "%.3f", .infinity)` 는 `"inf"` 를 내고 그건 유효한 JS
                // 리터럴이 아니다 — 배열 하나가 통째로 파스 실패해 그 틱의 오디오 배달이 사라진다.
                // 리포에 이미 `TextScriptEngine.jsNumber`(비유한 → "0") 가 있는데 이 자리가 안 거쳤다.
                let csv = frame.map { TextScriptEngine.jsNumber($0) }.joined(separator: ",")
                self?.webView?.evaluateJavaScript("if(window.__wapleAudio)window.__wapleAudio([\(csv)]);")
            }
            audioProvider = provider
        case .videoFallback:
            guard let baseURL = URL(string: base) else { throw RendererError.assetMissing }
            // F576: 정상 경로(VideoRenderer)와 같은 배경별 음량을 폴터 <video> 에도 적용.
            // 감사 V06: 화면 맞춤(fitMode)도 정상 경로와 같은 설정을 object-fit 으로 전달.
            web.loadHTMLString(
                VideoFallbackHTML.html(forVideoFile: fileName,
                                       volume: VideoSettings.volume(id: project.id),
                                       fitMode: SceneRenderSettings.fitMode),
                baseURL: baseURL
            )
        }

        // 가림 시 정지(절전 — 씬/동영상과 동일). 창 없음(headless) → no-op.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self, weak web] note in
            guard let self, let win = web?.window, (note.object as? NSWindow) === win else { return }
            self.occlusionChanged(visible: win.occlusionState.contains(.visible))
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
                // WKWebView 는 flipped(상단 원점) — convert 결과가 이미 웹 좌표계라 재반전 금지
                // (비교: WebInputProxyView 는 non-flipped NSView 라 (1-ny) 반전이 필요).
                let x = Int(inView.x), y = Int(inView.y)
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
        if let existing = interactionWindow {
            // 닫힘(windowWillClose)으로 멈춘 미러 타이머 재시작(start 는 멱등).
            (existing.contentView as? WebInputProxyView)?.start()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let proxy = WebInputProxyView(target: web)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "웹 월페이퍼 조작 (실시간 연동)"
        win.contentView = proxy
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        interactionWindow = win
        proxy.start()
    }

    /// 조작 창 닫힘 — 12Hz 미러 타이머 정지(teardown 까지 상주하던 낭비 제거). 창은 보존(재오픈 재사용).
    /// NSWindowDelegate 도 optional @objc 요구사항이라 셀렉터를 고정한다(아래 WKNavigationDelegate 주석 참조).
    public func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win === interactionWindow else { return }
        (win.contentView as? WebInputProxyView)?.stop()
    }

    private func setPausedJS(_ paused: Bool) {
        webView?.evaluateJavaScript("""
            if (window.__wapleSetPaused) {
              window.__wapleSetPaused(\(paused));
            } else {
              if (window.__wapleHardPauseController) {
                window.__wapleHardPauseController.setPaused(\(paused));
              }
              if (window.wallpaperPropertyListener &&
                  window.wallpaperPropertyListener.setPaused) {
                window.wallpaperPropertyListener.setPaused(\(paused));
              }
            }
            """) { _, error in
                if let error {
                    NSLog("%@", "[Waple] pause injection failed: \(error)")
                }
            }
    }

    private func synchronizeEffectivePause(forceJavaScript: Bool = false) {
        let effective = isEffectivelyPaused
        let changed = effectivePauseApplied != effective
        effectivePauseApplied = effective
        if changed || forceJavaScript {
            setPausedJS(effective)
        }

        if effective || !hasAudioListener {
            audioProvider?.stop()
        } else {
            audioProvider?.start()
        }
        if effective {
            mediaPoller?.stop()
        } else {
            mediaPoller?.start()
        }
    }

    // MARK: - WKNavigationDelegate — @objc 셀렉터 고정(아래 주석의 사고 이력을 읽고 지울 것)
    //
    // [2026-08-19] **이 파일의 델리게이트 메서드는 셀렉터를 명시로 고정한다.** 근거(추정 아님, CI 실측):
    // `-strict-concurrency=complete` 만 추가한 커밋 ead3d1d(CI run 32214982769)에서 소스 변경이 하나도
    // 없는 WebRendererSecurityTests 두 건이 debug·release 양쪽에서 실패했다 —
    //   · testWebRendererBlocksExternalTopFrameNavigation: web.url.host 가 "evil"(차단 실패, 커밋됨)
    //   · testWebRendererBlocksSubframeNavigationToDisallowedHost: iframe href 읽기 nil(교차출처 = 커밋됨)
    // 둘 다 "decisionHandler(.cancel) 이 아예 호출되지 않았다"는 뜻이다. 정책 코드 자체는 무변경이다.
    //
    // WKNavigationDelegate 의 요구사항은 전부 **optional @objc** 라 런타임에 respondsToSelector: 로
    // 조회된다. 구현이 요구사항의 witness 자격을 잃으면 암묵 @objc 노출과 함께 **셀렉터가 사라지고**,
    // WebKit 은 그냥 "구현 안 함"으로 보고 기본값(.allow)으로 진행한다 — 컴파일 에러도, 런타임 로그도
    // 없이 **보안 게이트가 조용히 꺼진다**. 최신 SDK 의 decisionHandler 블록에는 동시성 어노테이션이
    // 붙어 있어 엄격 동시성이 켜지면 우리 쪽 `(WKNavigationActionPolicy) -> Void` 와의 불일치가 더 이상
    // 관용되지 않는 것으로 보인다(툴체인이 없어 진단 로그로 최종 확인은 못 했다).
    //
    // 같은 런에서 **블록 인자가 없는** didFinish/didCommit 은 정상 동작했다(WebPropertyDeliveryTests 통과
    // = didFinish 가 __wapleApplyProps 를 실제로 호출했다). 즉 관측된 위험은 완료 핸들러(블록) 인자를
    // 가진 optional 델리게이트 메서드에 국한된다. 그래도 나머지도 같이 고정한다 — 언어 모드를 .v6 로
    // 올릴 때 관용 폭이 또 줄어들 수 있고, 이 실패 양식은 **테스트가 있어야만** 보이기 때문이다.
    //
    // 셀렉터를 명시하면 witness 매칭 성공 여부와 무관하게 ObjC 진입점이 보장된다. 반대로 witness 가
    // 여전히 성립하는 메서드는 셀렉터가 틀리면 컴파일 에러가 나므로(요구사항 셀렉터와 불일치) 오타는
    // 조용히 지나가지 않는다. **이 어노테이션을 지우려면 위 두 테스트를 반드시 돌려라.**
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard Self.isAllowedTopFrameURL(webView.url) else { return }
        synchronizeEffectivePause(forceJavaScript: isEffectivelyPaused)
        // didFinish 는 모든 허용 main-frame 내비게이션마다 발생한다. WE 는 문서가 다시 로드될 때도
        // 저장된 사용자 속성을 다시 전달하므로 JSON 을 소비하지 않는다.
        guard let json = userPropertiesJSON else { return }
        // 브리지 pending/flush 경유 — 리스너가 나중에 등록돼도 세터 훅이 전달(WE 의미론).
        let js = "window.__wapleApplyProps(\(json), { fps: 30 });"
        webView.evaluateJavaScript(js) { _, error in
            if let error { NSLog("%@", "[Waple] property injection failed: \(error)") }
        }
        deliverFetchAllDirectories()
    }

    /// F572: 문서가 실제로 교철되면(커밋) 이전 문서의 audioListen/mediaListen 등록은 JS 월드와
    /// 함께 소멸한다 — 리셋하지 않으면 새 문서인데도 캡처+FFT+미디어 폴섹이 pause/teardown 까지
    /// 계속 소모. didFinish 가 아니라 didCommit 에서 리셋하는 이유: (1) 초기 로드는 커밋 후에야
    /// 스크립트가 실행돼 리스너 등록 메시지가 리셋 뒤에 도착하고(didFinish 리셋은 등록을 지움),
    /// (2) 프래그먼트/pushState 같은 동일 문서 납비게이션은 JS 월드가 유지되며 didCommit 이
    /// 발생하지 않는다(리셋하면 살아 있는 문서의 등록이 고립된다).
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard Self.isAllowedTopFrameURL(webView.url) else { return }
        // 소비자가 있을 때만 동기화 — 미등록 문서(초기 로드 등)에서의 무조건 동기화는
        // 프로바이더에 불필요한 stop 을 추가할 뿐 아무 효과도 없다.
        let hadConsumers = hasAudioListener || mediaPoller != nil
        hasAudioListener = false
        mediaPoller?.stop()
        mediaPoller = nil
        if hadConsumers {
            synchronizeEffectivePause()
        }
    }

    /// 톱/서브프레임 내비게이션 게이트.
    ///
    /// **async 형태로 구현한다 — 완료핸들러 형태로 되돌리지 마라.**
    ///
    /// 완료핸들러형 `webView(_:decidePolicyFor:decisionHandler:)` 는 엄격 동시성 아래서
    /// 요구사항과 시그니처가 어긋난다(SDK 가 클로저에 붙인 동시성 애너테이션 때문).
    /// 어긋나면 optional @objc 요구사항의 **witness 자격**을 잃고 → 암묵적 @objc 상실 →
    /// 셀렉터 상실 → respondsToSelector: 가 NO → WebKit 이 기본값 .allow 로 진행한다.
    /// 컴파일 오류 없이 경고 한 줄만 남고 게이트는 무음으로 죽는다.
    ///   warning: ... nearly matches optional requirement ... of protocol 'WKNavigationDelegate'
    /// 실측 CI run 32214982769 에서 게이트가 통째로 무력화됐다.
    ///
    /// 앞서 두 가지 우회를 시도했고 둘 다 실패했다. 기록해 둔다:
    ///  · `@objc(webView:decidePolicyForNavigationAction:decisionHandler:)` 로 셀렉터 고정 →
    ///    SDK 가 같은 셀렉터를 async 요구사항으로도 노출하므로 충돌해 **컴파일 실패**
    ///    (run 32217958771: "conflicts with optional requirement method 'webView(_:decidePolicyFor:)'").
    ///  · `@preconcurrency import WebKit` → 경고가 그대로 남아 witness 미복원(run 32218275170).
    ///
    /// 그 실패한 시도가 정답을 알려줬다: SDK 에 async 요구사항 `webView(_:decidePolicyFor:)` 가
    /// 실재한다. 클로저 애너테이션을 추측해 맞추는 대신 그쪽을 구현한다 — 이름이 달라
    /// 모호성이 없고, WebKit 이 결과를 기다리므로 차단 의미도 그대로다.
    ///
    /// WebRendererSecurityTests 의 두 건이 이 계약의 감시자다.
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.targetFrame?.isMainFrame != false {
            guard Self.isAllowedTopFrameURL(navigationAction.request.url) else { return .cancel }
        } else {
            // 서브프레임(iframe 등) — 메인프레임만 게이팅하면 <iframe src="https://…"> 로 원격 콘텐츠가
            // 무검증 로드된다(egress/IP 유출, 감사 S1). 로컬(에셋/about:blank/data:)만 허용.
            // F571: 이 게이트는 내비게이션(메인+서브프레임)만 다룬다. <img>/<script>/fetch 등
            // 서브리소스의 원격 로드는 WE 호환(WE 자체가 네트워크 허용)을 위해 열어 두는 의도된
            // 범위 — 전면 차단은 원격 리소스를 쓰는 WE 웹 월페이퍼를 깨므로 수용 한계로 문서화.
            guard Self.isAllowedSubframeURL(navigationAction.request.url) else { return .cancel }
        }
        return .allow
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard Self.isAllowedBridgeMessage(message, topURL: webView?.url) else { return }
        guard let dict = message.body as? [String: Any], let type = dict["type"] as? String else { return }
        if type == "audioListen" {
            hasAudioListener = true
            synchronizeEffectivePause()
        } else if type == "audioUnlisten" {
            hasAudioListener = false
            synchronizeEffectivePause()
        } else if type == "mediaListen" {
            startMediaPolling()
            synchronizeEffectivePause()
        } else if type == "randomFile",
                  let name = dict["name"] as? String,
                  let requestID = dict["requestId"] as? String,
                  // F840: 길이 검증(종전엔 String 인지만 봤다). 메가바이트급 문자열이 그대로
                  // 프로퍼티 조회 키·JS 리터럴 인코딩을 타는 것을 막는다.
                  name.utf8.count <= Self.maxBridgeStringBytes,
                  requestID.utf8.count <= Self.maxBridgeStringBytes {
            switch randomFileTarget(forProperty: name) {
            case .file(let path):
                deliverRandomFileResponse(requestID: requestID, propertyName: name, filePath: path)
            case .directory(let directoryURL):
                // F840: 인-플라이트 상한 — 초과분은 워크를 띄우지 않고 빈 응답(콜백 계약은 지킨다).
                guard inFlightDirectoryWalks < Self.maxInFlightDirectoryWalks else {
                    deliverRandomFileResponse(requestID: requestID, propertyName: name, filePath: "")
                    return
                }
                inFlightDirectoryWalks += 1
                // F573: 디렉터리 재귀 열거+stat 은 파일 수만큼 I/O — 메인 프리즈 방지를 위해
                // 백그라운드에서 해석. 응답은 requestId 매칭이라 비동기 전달이 안전하다.
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let path = self?.randomFilePath(in: directoryURL) ?? ""
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.inFlightDirectoryWalks -= 1
                        self.deliverRandomFileResponse(requestID: requestID, propertyName: name,
                                                       filePath: path)
                    }
                }
            case nil:
                deliverRandomFileResponse(requestID: requestID, propertyName: name, filePath: "")
            }
        }
    }

    static func isAllowedTopFrameURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme == "about", url.absoluteString == "about:blank" { return true }
        return url.scheme == WallpaperSchemeHandler.scheme && url.host == WallpaperSchemeHandler.host
    }

    /// 서브프레임 게이트: 톱프레임 허용목록 + data: (인라인, 원격 fetch 없이 자체완결).
    /// http(s)/ws(s) 등 그 외 스킴은 전부 차단(허용목록 방식 — 미지 스킴을 기본 거부).
    static func isAllowedSubframeURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme == "data" { return true }
        return isAllowedTopFrameURL(url)
    }

    private static func isAllowedBridgeMessage(_ message: WKScriptMessage, topURL: URL?) -> Bool {
        if isAllowedAssetURL(message.frameInfo.request.url) { return true }
        return message.frameInfo.isMainFrame && isAllowedTopFrameURL(topURL)
    }

    private static func isAllowedAssetURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == WallpaperSchemeHandler.scheme && url.host == WallpaperSchemeHandler.host
    }

    /// randomFile 대상 해석 결과. directory 는 재귀 열거가 필요해 호출부에서 백그라운드로 본낸다(F573).
    private enum RandomFileTarget {
        case file(String)       // 단일 파일 — 즉시 응답 가능
        case directory(URL)     // 재귀 열거 필요
    }

    private func randomFileTarget(forProperty name: String) -> RandomFileTarget? {
        guard let root = projectRootURL,
              let property = userPropertiesByKey[name],
              case .string(let rawPath) = property.value else { return nil }
        let type = property.type.lowercased()
        guard type == "directory" || type == "file" else { return nil }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        if type == "file" {
            guard let fileURL = resourceURL(for: property, rawPath: path, projectRoot: root),
                  isRegularFile(fileURL, containedIn: path.hasPrefix("/") ? nil : root) else { return nil }
            return .file(fileURL.resolvingSymlinksInPath().path)
        }

        guard let directoryURL = resourceURL(for: property, rawPath: path, projectRoot: root),
              isDirectory(directoryURL, containedIn: path.hasPrefix("/") ? nil : root) else { return nil }
        return .directory(directoryURL)
    }

    private func deliverFetchAllDirectories() {
        // 프로퍼티 필터+경로 검증(단일 stat)은 메인 상태(userPropertiesByKey/projectRootURL)를
        // 읽으므로 여기서 스냅섯하고, 재귀 열거만 백그라운드로 본낸다.
        var targets: [(key: String, directoryURL: URL)] = []
        for key in userPropertiesByKey.keys.sorted() {
            guard let property = userPropertiesByKey[key],
                  property.type.lowercased() == "directory",
                  property.mode?.lowercased() == "fetchall",
                  let directoryURL = fetchAllDirectoryURL(for: property) else { continue }
            targets.append((key, directoryURL))
        }
        guard !targets.isEmpty else { return }
        // F840: didFinish 마다 자동 실행되므로 페이지가 location.reload 로 반복 유발할 수 있다 —
        // randomFile 과 같은 인-플라이트 상한을 공유한다(초과 시 이번 didFinish 분은 건너뛴다).
        guard inFlightDirectoryWalks < Self.maxInFlightDirectoryWalks else { return }
        inFlightDirectoryWalks += 1
        // F573: 재귀 열거+stat 은 파일 수만큼 I/O — 메인 프리즈 방지를 위해 백그라운드에서 해석 후
        // 메인으로 복귀해 전달(teardown 후면 webView 가 nil 이라 evaluateJavaScript 가 no-op).
        // 캡처는 불변 스냅샷으로 넘긴다 — @Sendable 클로저가 가변 var 를 참조하면 Swift 6 에선 에러다.
        // 값 타입 배열이라 복사는 참조 하나(의미 변화 없음).
        let snapshot = targets
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resolved: [(String, [String])] = snapshot.map { target in
                let files = self?.regularFiles(in: target.directoryURL)
                    .map { $0.resolvingSymlinksInPath().path } ?? []
                return (target.key, files)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlightDirectoryWalks -= 1
                for (key, files) in resolved {
                    self.deliverDirectoryFilesAddedOrChanged(propertyName: key, files: files)
                }
            }
        }
    }

    private func fetchAllDirectoryURL(for property: WallpaperProperty) -> URL? {
        guard let root = projectRootURL,
              case .string(let rawPath) = property.value else { return nil }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              let directoryURL = resourceURL(for: property, rawPath: path, projectRoot: root),
              isDirectory(directoryURL, containedIn: path.hasPrefix("/") ? nil : root) else { return nil }
        return directoryURL
    }

    /// nonisolated: F573 계약대로 **백그라운드 큐에서 호출된다**. 이 클래스는 WKNavigationDelegate
    /// 등 @MainActor 프로토콜 적합으로 멤버 전체가 메인 액터로 추론되는데, 이 셋은 인스턴스 상태를
    /// 하나도 읽지 않고 FileManager 만 만지므로 격리에서 명시적으로 빼낸다(= 진단이 가리키던
    /// "메인 액터 메서드를 백그라운드에서 호출" 이 실제로 안전하다는 근거를 코드에 적는 것).
    nonisolated private func randomFilePath(in directoryURL: URL) -> String? {
        regularFiles(in: directoryURL).randomElement()?.resolvingSymlinksInPath().path
    }

    /// F573: 재귀 열거+파일별 stat — 메인 스레드 동기 호출 금지(백그라운드 큐 전용).
    nonisolated private func regularFiles(in directoryURL: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            // F840: 열거 엔트리 상한 — 상한이 없으면 워크 하나가 트리 크기만큼(홈 디렉터리를 고른
            // 경우 수십만 stat) 돌아, 인-플라이트 상한만으로는 부족하다.
            visited += 1
            if visited > Self.maxEnumeratedEntries {
                NSLog("%@", "[Waple] directory enumeration truncated at \(Self.maxEnumeratedEntries) entries: \(directoryURL.path)")
                break
            }
            if isRegularFile(url, containedIn: directoryURL) {
                candidates.append(url)
            }
        }
        return candidates.sorted { $0.path < $1.path }
    }

    private func resourceURL(for property: WallpaperProperty, rawPath: String, projectRoot: URL) -> URL? {
        if rawPath.hasPrefix("/") {
            let selected = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard userSelectedResourceOverrides[property.key] == selected else { return nil }
            return URL(fileURLWithPath: rawPath)
        }
        return WallpaperPathSecurity.containedFileURL(rawPath, root: projectRoot)
    }

    private func isDirectory(_ url: URL, containedIn root: URL?) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        guard let root else { return true }
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let realURL = url.resolvingSymlinksInPath().standardizedFileURL
        return WallpaperPathSecurity.contains(realURL, in: realRoot)
    }

    /// nonisolated: regularFiles(백그라운드)가 엔트리마다 호출한다 — 인스턴스 상태 무접근(위 주석 참조).
    nonisolated private func isRegularFile(_ url: URL, containedIn root: URL?) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        guard let root else { return true }
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let realURL = url.resolvingSymlinksInPath().standardizedFileURL
        return WallpaperPathSecurity.contains(realURL, in: realRoot)
    }

    private func deliverRandomFileResponse(requestID: String, propertyName: String, filePath: String) {
        let js = "window.__wapleRandomFileResponse && window.__wapleRandomFileResponse(\(Self.jsStringLiteral(requestID)), \(Self.jsStringLiteral(propertyName)), \(Self.jsStringLiteral(filePath)));"
        webView?.evaluateJavaScript(js) { _, error in
            if let error { NSLog("%@", "[Waple] random file callback failed: \(error)") }
        }
    }

    private func deliverDirectoryFilesAddedOrChanged(propertyName: String, files: [String]) {
        let js = "window.__wapleDirectoryFilesAddedOrChanged && window.__wapleDirectoryFilesAddedOrChanged(\(Self.jsStringLiteral(propertyName)), \(Self.jsArrayLiteral(files)));"
        webView?.evaluateJavaScript(js) { _, error in
            if let error { NSLog("%@", "[Waple] directory fetchall callback failed: \(error)") }
        }
    }

    private static func jsStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return "\"\"" }
        return string
    }

    private static func jsArrayLiteral(_ value: [String]) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    private static func absoluteResourceOverrides(from overrides: [String: PropertyValue]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in overrides {
            guard case .string(let rawPath) = value else { continue }
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else { continue }
            out[key] = URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return out
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
            // F840-sweep: 같은 이유로 jsNumber 경유(비유한 → 0). osascript 파스 실패 시 0 이라
            // 현재 도달은 미입증이지만, 가드가 있는데 안 거치는 상태를 남길 이유가 없다.
            js("timeline", "{ position: \(TextScriptEngine.jsNumber(Float(info.position))), "
                         + "duration: \(TextScriptEngine.jsNumber(Float(info.duration))) }")
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
        mediaPoller = poller
    }

    public func pause() {
        guard !pausedManually else { return }
        pausedManually = true
        synchronizeEffectivePause()
    }

    public func resume() {
        guard pausedManually else { return }
        pausedManually = false
        synchronizeEffectivePause()
    }

    /// 가림 상태 전이(옵저버 클로저에서 분리 — webView 창 없이도 테스트 가능). 가림 정지는 수동 pause 와
    /// 별개 플래그로 추적: 종전에는 복귀 분기가 resume() 을 불렀지만 resume() 은 `guard pausedManually`
    /// 전제라 즉시 반환 → JS/오디오가 영구 정지되는 데드패스였다(감사 W-B1). 수동 pause 중이면 복귀해도
    /// 재개하지 않는다(수동 정지가 우선 — resume() 으로만 해제).
    func occlusionChanged(visible: Bool) {
        let occluded = !visible
        guard pausedByOcclusion != occluded else { return }
        pausedByOcclusion = occluded
        synchronizeEffectivePause()
    }

    public func teardown() {
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        occlusionObserver = nil
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
        (interactionWindow?.contentView as? WebInputProxyView)?.stop()
        interactionWindow?.orderOut(nil)
        interactionWindow = nil
        audioProvider?.stop()
        audioProvider = nil
        mediaPoller?.stop()
        mediaPoller = nil
        effectivePauseApplied = false
        pausedManually = false
        pausedByOcclusion = false
        hasAudioListener = false
        userPropertiesJSON = nil
        userPropertiesByKey = [:]
        userSelectedResourceOverrides = [:]
        projectRootURL = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "waple")
        webView?.removeFromSuperview()
        webView = nil
    }
}
