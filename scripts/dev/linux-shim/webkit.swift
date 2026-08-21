// 리눅스용 **WebKit 대역 선언**(shim). 동작하지 않는다 — 타입체크 전용이다.
// 배경·규약은 `metal.swift` 머리말과 같다(본문은 더미, 각 선언 위에 실제 시그니처를 주석으로,
// 확신 없는 자리는 `확신 없음`).
//
// 커버 대상: `WebRenderer.swift` · `WebInputProxyView.swift` · `WallpaperSchemeHandler.swift`
// (그리고 `WebRenderer(mode:)` 를 직접 생성하는 `RendererFactory.swift`).
//
// **이 심이 재현하지 *못* 하는 것 — WebRenderer 의 사고 이력과 직결된다:**
//  · 애플의 `WKNavigationDelegate`/`NSWindowDelegate` 요구사항은 전부 **optional @objc** 라
//    시그니처가 어긋나도 컴파일은 통과하고 셀렉터만 조용히 사라진다(WebRenderer.swift:271~ 의
//    CI run 32214982769 사고). 리눅스에는 ObjC 런타임이 없어 `@objc` 를 못 쓰므로 여기서는
//    **프로토콜 확장의 기본 구현**으로 optional 성질만 흉내낸다. 즉 **같은 함정을 그대로 둔다** —
//    이 도구는 그 사고를 잡지 못한다(`docs/dev/linux-typecheck.md` 한계 ③).
//  · 애플 WebKit 타입은 전부 `@MainActor` 다. 여기 타입은 전부 비격리라 격리 진단(WebRenderer 의
//    `nonisolated` 표기 필요성, RendererFactory 의 "비격리 컨텍스트에서 메인액터 초기화자" 경고)은
//    리눅스에서 **재현되지 않는다**(한계 ④). 그 표기를 지워도 여기서는 통과한다.
import AppKit
// **아래 둘은 WebKit API 가 아니라 리눅스 Foundation 의 결손분이다** — 애플에서는 Foundation 이
// 늘 주는 것이라 여기에 있어도 거짓 통과를 만들지 않는다(macOS 에서는 무조건 보인다).
// 커스텀 스킴 응답을 만드는 `WallpaperSchemeHandler.swift` 가 `Foundation`+`WebKit` 만 import 하는데,
//  · `HTTPURLResponse`/`URLRequest`/`URLResponse` 는 리눅스에서 `FoundationNetworking` 에 있다
//    (리눅스 Foundation 에는 `AnyObject` 별칭만 남아 "no accessible initializers" 가 난다).
//    같은 이유로 `coregraphics.swift` 도 이 모듈을 재수출한다.
//  · `autoreleasepool` 은 리눅스 Foundation 에 아예 없다(실측: `cannot find 'autoreleasepool' in scope`).
@_exported import FoundationNetworking

/// 실제(Darwin): `@inlinable public func autoreleasepool<Result>(invoking body: () throws -> Result)
///                rethrows -> Result` — 리눅스에는 없다. 호출부는 전부 트레일링 클로저라 라벨이 생략된다.
public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}

// MARK: - 설정 · 콘텐츠 컨트롤러

/// 실제: `open class WKWebsiteDataStore: NSObject { open class var `default`: WKWebsiteDataStore
///        open class func nonPersistent() -> WKWebsiteDataStore }`
open class WKWebsiteDataStore: NSObject {
    public override init() { super.init() }
    public static func nonPersistent() -> WKWebsiteDataStore { WKWebsiteDataStore() }
    public static let `default` = WKWebsiteDataStore()
}

/// 실제: `public enum WKUserScriptInjectionTime: Int { case atDocumentStart = 0, atDocumentEnd = 1 }`
public enum WKUserScriptInjectionTime: Int {
    case atDocumentStart = 0
    case atDocumentEnd = 1
}

/// 실제: `open class WKUserScript: NSObject {
///        public init(source: String, injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool)
///        open var source: String { get } }`
open class WKUserScript: NSObject {
    public let source: String
    public let injectionTime: WKUserScriptInjectionTime
    public let isForMainFrameOnly: Bool
    public init(source: String, injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool) {
        self.source = source
        self.injectionTime = injectionTime
        self.isForMainFrameOnly = forMainFrameOnly
        super.init()
    }
}

/// 실제: `open class WKFrameInfo: NSObject { open var isMainFrame: Bool { get }
///        open var request: URLRequest { get }; open var webView: WKWebView? { get } }`
open class WKFrameInfo: NSObject {
    public var isMainFrame: Bool { false }
    public var request: URLRequest { URLRequest(url: URL(fileURLWithPath: "/")) }
    public override init() { super.init() }
}

/// 실제: `open class WKScriptMessage: NSObject { open var body: Any { get }; open var name: String { get }
///        open var frameInfo: WKFrameInfo { get }; open var webView: WKWebView? { get } }`
open class WKScriptMessage: NSObject {
    public var body: Any { 0 }
    public var name: String { "" }
    public var frameInfo: WKFrameInfo { WKFrameInfo() }
    public override init() { super.init() }
}

/// 실제: `@MainActor public protocol WKScriptMessageHandler: NSObjectProtocol {
///        func userContentController(_ userContentController: WKUserContentController,
///                                   didReceive message: WKScriptMessage) }`
/// 이 요구사항은 optional 이 **아니다**(필수) — 기본 구현을 두지 않는다.
public protocol WKScriptMessageHandler: NSObjectProtocol {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage)
}

/// 실제: `open class WKUserContentController: NSObject {
///        open func addUserScript(_ userScript: WKUserScript)
///        open func add(_ scriptMessageHandler: any WKScriptMessageHandler, name: String)
///        open func removeScriptMessageHandler(forName name: String)
///        open func removeAllUserScripts() }`
open class WKUserContentController: NSObject {
    public override init() { super.init() }
    open func addUserScript(_ userScript: WKUserScript) {}
    open func add(_ scriptMessageHandler: any WKScriptMessageHandler, name: String) {}
    open func removeScriptMessageHandler(forName name: String) {}
    open func removeAllUserScripts() {}
}

/// 실제: `open class WKWebViewConfiguration: NSObject {
///        open var userContentController: WKUserContentController
///        open var websiteDataStore: WKWebsiteDataStore
///        open func setURLSchemeHandler(_ urlSchemeHandler: (any WKURLSchemeHandler)?,
///                                      forURLScheme urlScheme: String) }`
open class WKWebViewConfiguration: NSObject {
    public var userContentController = WKUserContentController()
    public var websiteDataStore = WKWebsiteDataStore.default
    public override init() { super.init() }
    open func setURLSchemeHandler(_ urlSchemeHandler: (any WKURLSchemeHandler)?,
                                  forURLScheme urlScheme: String) {}
}

// MARK: - 내비게이션

/// 실제: `open class WKNavigation: NSObject { open var effectiveContentMode: WKContentMode { get } }`
open class WKNavigation: NSObject {
    public override init() { super.init() }
}

/// 실제: `public enum WKNavigationActionPolicy: Int { case cancel = 0, allow = 1, download = 2 }`
/// 확신 없음: `download` 는 macOS 11.3+ 추가분이라 원시값 배치를 헤더로 확인하지 못했다.
public enum WKNavigationActionPolicy: Int {
    case cancel = 0
    case allow = 1
    case download = 2
}

/// 실제: `public enum WKNavigationType: Int { case linkActivated = 0, formSubmitted, backForward,
///        reload, formResubmitted, other = -1 }`
public enum WKNavigationType: Int {
    case linkActivated = 0
    case formSubmitted = 1
    case backForward = 2
    case reload = 3
    case formResubmitted = 4
    case other = -1
}

/// 실제: `open class WKNavigationAction: NSObject { open var request: URLRequest { get }
///        open var sourceFrame: WKFrameInfo { get }; open var targetFrame: WKFrameInfo? { get }
///        open var navigationType: WKNavigationType { get } }`
open class WKNavigationAction: NSObject {
    public var request: URLRequest { URLRequest(url: URL(fileURLWithPath: "/")) }
    public var sourceFrame: WKFrameInfo { WKFrameInfo() }
    public var targetFrame: WKFrameInfo? { nil }
    public var navigationType: WKNavigationType { .other }
    public override init() { super.init() }
}

/// 실제: `@MainActor public protocol WKNavigationDelegate: NSObjectProtocol { ... }` — **요구사항이 전부
/// `optional @objc`** 다. 리눅스에는 ObjC 런타임이 없어 `@objc optional` 을 쓸 수 없으므로 프로토콜
/// 확장의 기본 구현으로 대체한다. 그래서 **셀렉터 어긋남을 못 잡는다**(머리말 참조).
/// 여기 나열한 것은 WapleRender 가 실제로 구현하는 셋뿐이다.
public protocol WKNavigationDelegate: NSObjectProtocol {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!)
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!)
    /// 실제: `optional func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction)
    ///        async -> WKNavigationActionPolicy` — 완료핸들러형과 **별개로 실재하는** async 요구사항이다
    ///        (WebRenderer.swift:329~ 의 근거. 이름이 같고 인자 개수가 달라 모호성이 없다).
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error)
}
public extension WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {}
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy { .allow }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
}

// MARK: - 커스텀 스킴

/// 실제: `public protocol WKURLSchemeTask: NSObjectProtocol { var request: URLRequest { get }
///        func didReceive(_ response: URLResponse); func didReceive(_ data: Data)
///        func didFinish(); func didFailWithError(_ error: any Error) }`
/// `NSObjectProtocol` 상속이 중요하다 — `WallpaperSchemeHandler` 가 `ObjectIdentifier(task)` 로
/// 태스크 아이덴티티를 잡는데 그건 클래스 바운드 프로토콜에서만 된다.
public protocol WKURLSchemeTask: NSObjectProtocol {
    var request: URLRequest { get }
    func didReceive(_ response: URLResponse)
    func didReceive(_ data: Data)
    func didFinish()
    func didFailWithError(_ error: any Error)
}

/// 실제: `@MainActor public protocol WKURLSchemeHandler: NSObjectProtocol {
///        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask)
///        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) }`
/// 이 둘은 optional 이 **아니다**(필수) — 기본 구현을 두지 않는다.
public protocol WKURLSchemeHandler: NSObjectProtocol {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask)
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask)
}

// MARK: - 웹뷰

/// 실제: `open class WKSnapshotConfiguration: NSObject { open var rect: CGRect
///        open var snapshotWidth: NSNumber?; open var afterScreenUpdates: Bool }`
open class WKSnapshotConfiguration: NSObject {
    public var rect: CGRect = .null
    public var afterScreenUpdates: Bool = true
    public override init() { super.init() }
}

/// 실제(macOS): `@MainActor open class WKWebView: NSView {
///        public init(frame: CGRect, configuration: WKWebViewConfiguration)
///        open var configuration: WKWebViewConfiguration { get }
///        weak open var navigationDelegate: (any WKNavigationDelegate)?
///        open var url: URL? { get }
///        open func load(_ request: URLRequest) -> WKNavigation?
///        open func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation?
///        open func evaluateJavaScript(_ javaScriptString: String,
///                                     completionHandler: ((Any?, (any Error)?) -> Void)? = nil)
///        open func takeSnapshot(with snapshotConfiguration: WKSnapshotConfiguration?,
///                               completionHandler: @escaping (NSImage?, (any Error)?) -> Void) }`
/// 확신 없음: `load`/`loadHTMLString` 의 반환값이 `@discardableResult` 인지(호출부가 결과를 버린다).
/// 여기서는 버려도 경고가 나지 않도록 `@discardableResult` 를 붙였다 — 애플이 그렇지 않다면
/// macOS 에서 "result unused" **경고**가 추가로 날 뿐 통과/실패는 갈리지 않는다.
open class WKWebView: NSView {
    private let _configuration: WKWebViewConfiguration
    public var configuration: WKWebViewConfiguration { _configuration }
    public weak var navigationDelegate: (any WKNavigationDelegate)?
    public var url: URL? { nil }
    public init(frame: CGRect, configuration: WKWebViewConfiguration) {
        self._configuration = configuration
        super.init(frame: frame)
    }
    @discardableResult
    open func load(_ request: URLRequest) -> WKNavigation? { nil }
    @discardableResult
    open func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? { nil }
    open func evaluateJavaScript(_ javaScriptString: String,
                                 completionHandler: ((Any?, (any Error)?) -> Void)? = nil) {}
    open func takeSnapshot(with snapshotConfiguration: WKSnapshotConfiguration?,
                           completionHandler: @escaping (NSImage?, (any Error)?) -> Void) {}
}
