// 리눅스용 **AppKit 대역 — 앱 계층 추가분**(shim). 타입체크 전용.
//
// `appkit.swift` 와 **같은 `AppKit` 모듈로 함께 컴파일**된다(항상 — `--app` 전용이 아니다).
// 파일을 가른 것은 출처를 남기기 위해서다: 종전 AppKit 심은 `Sources/WapleRender/**` 가 쓰는
// **창과 뷰**만 담고 있었고, 여기 있는 것은 전부 앱 계층(`Sources/Waple/**`)이 만지는
// **패널·워크스페이스·뷰컨트롤러** 표면이다
// (`docs/dev/linux-typecheck.md` "프로덕션이 안 쓰는 방향의 API 가 통째로 비어 있다" 와 같은 축).
//
// **여기 없는 것과 그 이유** — `NSMenu`·`NSMenuItem`·`NSMenuDelegate`·`NSStatusBar`·
// `NSStatusItem`·`NSApplicationDelegate`·`NSText` 는 일부러 뺐다. 그 일곱은 `AppDelegate.swift`
// 와 `main.swift` **에서만** 쓰이는데(실측 grep), 그 두 파일은 리눅스에서 타입체크 자체가
// 불가능해 `--app` 커버 밖이다. 이유는 심으로 메울 수 없는 컴파일러 제약이다:
//
//   · `@objc`/`#selector` 는 `-enable-objc-interop` 없이는 아예 오류다
//     (`error: Objective-C interoperability is disabled`).
//   · 그 플래그를 켜면 두 가지가 새로 깨진다(2026-08-21 실측):
//     ① `error: only classes that inherit from NSObject can be declared @objc` —
//        리눅스 Foundation 의 `NSObject` 가 interop 없이 빌드돼서, **어떤 클래스 타입도
//        ObjC 표현 가능하지 않다.** `AppDelegate.swift:1381`
//        `@objc func applyRecent(_ sender: NSMenuItem)` 이 여기서 막힌다.
//     ② `error: broken standard library: cannot find intrinsic operations on
//        UnsafeMutablePointer<T>` — interop 을 켜면 **모든 `inout`→포인터 변환**이 깨진다
//        (`take(&s)` 같은 최소 예제로도 재현). 리눅스 stdlib 에
//        `AutoreleasingUnsafeMutablePointer` 가 없기 때문이다.
//   즉 플래그를 켜도 ①은 못 넘고, 켜는 순간 ②가 새로 생긴다. 그래서 켜지 않는다.
import Foundation
import UniformTypeIdentifiers

/// `NSItemProvider` 는 **애플에서는 Foundation** 타입이다(AppKit 이 아니다). 리눅스
/// swift-corelibs-foundation 에는 없어서 여기서 대신 낸다 — `webkit.swift` 가
/// `HTTPURLResponse`·`autoreleasepool` 을 내는 것과 같은 부류
/// (`docs/dev/linux-typecheck.md` §리눅스 Foundation 결손).
///
/// 실제: `open class NSItemProvider: NSObject, NSCopying, NSSecureCoding {
///          public convenience init(object: NSItemProviderWriting)
///          open func hasItemConformingToTypeIdentifier(_ typeIdentifier: String) -> Bool
///          open func loadItem(forTypeIdentifier typeIdentifier: String,
///                             options: [AnyHashable: Any]? = nil,
///                             completionHandler: NSItemProvider.CompletionHandler? = nil)
///          open func loadObject(ofClass aClass: NSItemProviderReading.Type,
///                               completionHandler: @escaping (NSItemProviderReading?, Error?) -> Void)
///                    -> Progress }`
/// 확신 없음: 실물의 `object:` 는 `NSItemProviderWriting`, `ofClass:` 는
/// `NSItemProviderReading.Type` 을 받는다. 두 프로토콜을 재현하지 않고 각각 `AnyObject` ·
/// `AnyClass` 로 느슨하게 뒀다 — **실물보다 관대하다**(아무 클래스나 넘겨도 통과한다).
/// 호출부는 `NSString` 하나뿐이다(`DisplaysView.swift:139`).
open class NSItemProvider: NSObject {
    public convenience init(object: AnyObject) { self.init() }
    public override init() { super.init() }
    open func hasItemConformingToTypeIdentifier(_ typeIdentifier: String) -> Bool { false }
    open func loadItem(forTypeIdentifier typeIdentifier: String,
                       options: [AnyHashable: Any]? = nil,
                       completionHandler: ((Any?, Error?) -> Void)? = nil) {}
    @discardableResult
    open func loadObject(ofClass aClass: AnyClass,
                         completionHandler: @escaping (Any?, Error?) -> Void) -> Progress {
        Progress(totalUnitCount: 0)
    }
}

/// 실제: `open class NSSavePanel: NSPanel { … }` / `open class NSOpenPanel: NSSavePanel {
///          open class func openPanel() -> NSOpenPanel
///          open var canChooseFiles/canChooseDirectories/allowsMultipleSelection: Bool
///          open var canCreateDirectories: Bool
///          open var allowedContentTypes: [UTType]
///          open var directoryURL: URL?; open var prompt: String?; open var message: String?
///          open var urls: [URL] { get }; open var url: URL? { get }
///          open func runModal() -> NSApplication.ModalResponse }`
/// `NSPanel`/`NSSavePanel` 계층을 생략하고 `NSWindow` 를 직접 상속한다.
open class NSOpenPanel: NSWindow {
    /// 실제: `NSOpenPanel()` 로 직접 만든다(`NSSavePanel` 이 `init()` 을 준다).
    /// 여기서는 `NSWindow` 의 지정 이니셜라이저를 더미로 전달한다.
    public init() {
        super.init(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    }
    public static func openPanel() -> NSOpenPanel { NSOpenPanel() }
    open var canChooseFiles: Bool = true
    open var canChooseDirectories: Bool = false
    open var allowsMultipleSelection: Bool = false
    open var canCreateDirectories: Bool = false
    open var allowedContentTypes: [UTType] = []
    open var directoryURL: URL?
    open var prompt: String?
    open var message: String?
    open var nameFieldStringValue: String = ""
    /// 실제: `open var url: URL? { get }`(`NSSavePanel`) · `open var urls: [URL] { get }`
    open var url: URL? { nil }
    open var urls: [URL] { [] }
    open func runModal() -> NSApplication.ModalResponse { .OK }
}

/// 실제: `open class NSViewController: NSResponder { open var view: NSView
///          open var preferredContentSize: NSSize; open var title: String? }`
/// `SwiftUI.NSHostingController` 의 상위 클래스라 여기 둔다(`NSWindow(contentViewController:)` 가
/// 이 타입을 받는다).
open class NSViewController: NSResponder {
    open var view: NSView = NSView()
    open var preferredContentSize: NSSize = .zero
    open var title: String?
}

extension NSWindow {
    /// 실제: `public convenience init(contentViewController: NSViewController)`
    public convenience init(contentViewController: NSViewController) {
        self.init(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    }
    /// 실제: `public enum NSWindow.ToolbarStyle: Int { case automatic, expanded, preference,
    ///          unified, unifiedCompact }`
    public enum ToolbarStyle: Int {
        case automatic = 0, expanded = 1, preference = 2, unified = 3, unifiedCompact = 4
    }
    /// 실제: `open func setContentSize(_ size: NSSize)`
    public func setContentSize(_ size: NSSize) {}
    /// 실제: `open func deminiaturize(_ sender: Any?)`
    public func deminiaturize(_ sender: Any?) {}
    /// 실제: `open func performClose(_ sender: Any?)`
    public func performClose(_ sender: Any?) {}
}

extension NSBitmapImageRep {
    /// 실제: `public init(cgImage: CGImage)` — **실패 가능이 아니다**(`init?(data:)` 와 다르다).
    /// 호출부: `VideoImport.swift:72` 가 `AVAssetImageGenerator` 결과를 JPEG 로 인코딩한다.
    public convenience init(cgImage: CGImage) {
        self.init(data: Data())!
    }
}

extension NSImage {
    /// 실제: `public convenience init?(systemSymbolName: String, accessibilityDescription: String?)`
    /// (macOS 11+ — SF Symbols).
    public convenience init?(systemSymbolName: String, accessibilityDescription: String?) {
        self.init()
    }
}

extension NSApplication {
    /// 실제: `public struct ModalResponse: RawRepresentable { public static let OK/cancel/… }`
    public struct ModalResponse: RawRepresentable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let OK = ModalResponse(rawValue: 1)
        public static let cancel = ModalResponse(rawValue: 0)
    }
    /// 실제: `extension NSApplication { public class let didChangeScreenParametersNotification: Notification.Name }`
    public static let didChangeScreenParametersNotification =
        Notification.Name("NSApplicationDidChangeScreenParametersNotification")
    public static let didBecomeActiveNotification =
        Notification.Name("NSApplicationDidBecomeActiveNotification")
    public static let willTerminateNotification =
        Notification.Name("NSApplicationWillTerminateNotification")
}

/// 실제: `open class NSImageView: NSControl { open var image: NSImage?
///          open var imageScaling: NSImageScaling; open var animates: Bool }`
/// `NSControl` 계층을 생략하고 `NSView` 를 직접 상속한다.
open class NSImageView: NSView {
    open var image: NSImage?
    open var imageScaling: NSImageScaling = .scaleNone
    open var animates: Bool = false
}
/// 실제: `public enum NSImageScaling: UInt { case scaleProportionallyDown, scaleAxesIndependently,
///          scaleNone, scaleProportionallyUpOrDown }`
public enum NSImageScaling: UInt {
    case scaleProportionallyDown = 0
    case scaleAxesIndependently = 1
    case scaleNone = 2
    case scaleProportionallyUpOrDown = 3
}

/// 실제: `open class NSLayoutConstraint` 의 우선순위 타입.
/// `public struct NSLayoutConstraint.Priority: RawRepresentable { public static let defaultHigh
///  /defaultLow/required/dragThatCanResizeWindow/… ; public init(rawValue: Float) }`
public enum NSLayoutConstraint {
    public struct Priority: RawRepresentable, Equatable {
        public let rawValue: Float
        public init(rawValue: Float) { self.rawValue = rawValue }
        public static let required = Priority(rawValue: 1000)
        public static let defaultHigh = Priority(rawValue: 750)
        public static let defaultLow = Priority(rawValue: 250)
    }
}
/// 실제: `public enum NSLayoutConstraint.Orientation: Int { case horizontal, vertical }`
/// 실물은 `NSLayoutConstraint.Orientation` 이지만 위 `enum NSLayoutConstraint` 에 중첩하면
/// 호출부 표기(`.horizontal`)와 무관하게 이름이 길어져 여기서는 별도 타입으로 둔다.
/// **실물과 이름이 다르다** — 호출부가 타입 이름을 적는 자리가 없어서 통한다.
public enum NSLayoutConstraintOrientation: Int {
    case horizontal = 0, vertical = 1
}
extension NSView {
    /// 실제: `open func setContentCompressionResistancePriority(_ priority: NSLayoutConstraint.Priority,
    ///          for orientation: NSLayoutConstraint.Orientation)`
    public func setContentCompressionResistancePriority(_ priority: NSLayoutConstraint.Priority,
                                                        for orientation: NSLayoutConstraintOrientation) {}
    /// 실제: `open func setContentHuggingPriority(_ priority: NSLayoutConstraint.Priority,
    ///          for orientation: NSLayoutConstraint.Orientation)`
    public func setContentHuggingPriority(_ priority: NSLayoutConstraint.Priority,
                                          for orientation: NSLayoutConstraintOrientation) {}
}

extension NSColor {
    /// 실제: 시맨틱 색은 전부 `open class var …: NSColor { get }` 다.
    /// `Sources/Waple/DesignSystem/ColorRole.swift` 가 쓰는 것만 둔다.
    public static var controlBackgroundColor: NSColor { NSColor() }
    public static var windowBackgroundColor: NSColor { NSColor() }
    public static var separatorColor: NSColor { NSColor() }
    public static var labelColor: NSColor { NSColor() }
    public static var secondaryLabelColor: NSColor { NSColor() }
    public static var tertiaryLabelColor: NSColor { NSColor() }
    public static var quaternaryLabelColor: NSColor { NSColor() }
    public static var textColor: NSColor { NSColor() }
    public static var controlAccentColor: NSColor { NSColor() }
    /// 실제: `open func usingColorSpace(_ space: NSColorSpace) -> NSColor?`
    /// 호출부: `PropertyEditorView.swift:259` 이 `.usingColorSpace(.sRGB)` 로 컬러 피커 결과를
    /// sRGB 성분으로 읽는다.
    public func usingColorSpace(_ space: NSColorSpace) -> NSColor? { nil }
}

extension NSWorkspace {
    /// (`notificationCenter` 는 `appkit.swift` 에 이미 있다.)
    /// 실제: `extension NSWorkspace { public class let screensDidSleepNotification: Notification.Name }` 계열.
    public static let screensDidSleepNotification = Notification.Name("NSWorkspaceScreensDidSleepNotification")
    public static let screensDidWakeNotification = Notification.Name("NSWorkspaceScreensDidWakeNotification")
    public static let willSleepNotification = Notification.Name("NSWorkspaceWillSleepNotification")
    public static let didWakeNotification = Notification.Name("NSWorkspaceDidWakeNotification")

    /// 실제: `open func accessibilityDisplayShouldReduceMotion: Bool { get }` 외 3종.
    /// `DesignSystem/SystemPreference.swift` 가 넷을 전부 읽는다.
    public var accessibilityDisplayShouldReduceMotion: Bool { false }
    public var accessibilityDisplayShouldReduceTransparency: Bool { false }
    public var accessibilityDisplayShouldDifferentiateWithoutColor: Bool { false }
    public var accessibilityDisplayShouldIncreaseContrast: Bool { false }

    /// 실제: `open func open(_ url: URL) -> Bool`
    /// (`ScreenSaverController.swift:162~163` 이 시스템 설정 딥링크를 연다.)
    @discardableResult
    public func open(_ url: URL) -> Bool { false }
    /// 실제: `open func activateFileViewerSelecting(_ fileURLs: [URL])`
    public func activateFileViewerSelecting(_ fileURLs: [URL]) {}
    /// 실제: `open func selectFile(_ fullPath: String?, inFileViewerRootedAtPath: String) -> Bool`
    @discardableResult
    public func selectFile(_ fullPath: String?, inFileViewerRootedAtPath rootFullPath: String) -> Bool { false }
}


/// 실제: `open class NSColorSpace: NSObject { open class var sRGB: NSColorSpace { get }
///          open class var genericRGB/deviceRGB/displayP3/…: NSColorSpace { get } }`
/// (문자열 기반 `NSColorSpaceName` 과는 **다른 타입**이다 — 그쪽은 `NSBitmapImageRep` 계열이 쓴다.)
/// 호출부: `PropertyEditorView.swift:259` 의 `.usingColorSpace(.sRGB)`.
open class NSColorSpace: NSObject {
    public static let sRGB = NSColorSpace()
    public static let genericRGB = NSColorSpace()
    public static let deviceRGB = NSColorSpace()
    public static let displayP3 = NSColorSpace()
}
