// 리눅스용 **AppKit 대역 선언**(shim). 타입체크 전용 — 동작하지 않는다.
// 배경·규약은 `metal.swift` 머리말과 같다.
//
// **AppKit 전체를 흉내내지 않는다.** `Sources/WapleRender/**` 중 커버 대상 파일이 실제로 쓰는
// 심볼만 있다. [2026-08-21] 커버가 55/55 가 되면서 WebKit 계열
// (`WebRenderer`·`WebInputProxyView`·`WallpaperSchemeHandler`)이 쓰는 표면도 여기 들어왔다:
// `NSTrackingArea`, `NSWindowDelegate`, `NSResponder` 의 마우스/키 이벤트, `NSEvent.keyCode`·
// `scrollingDelta*`·`charactersIgnoringModifiers`, 그리고 파일 끝의 그리기 오버레이
// (`NSRect.fill()`·`NSString.draw(at:withAttributes:)`·`NSImage.draw(in:from:operation:fraction:)`).
//
// 리눅스 Foundation 이 이미 주는 것(다시 선언하면 충돌한다):
//   NSObject, NSNumber, NSString, NSAttributedString, NSLock, NSNull, NSRange, NSLog,
//   NSPoint/NSSize/NSRect(= CGPoint/CGSize/CGRect 별칭), NSEdgeInsets
@_exported import CoreGraphics
@_exported import QuartzCore

// MARK: - NSAttributedString 속성 키(애플에서는 AppKit 이 정의한다)

extension NSAttributedString.Key {
    /// 실제: `public static let font: NSAttributedString.Key` (raw "NSFont")
    public static let font = NSAttributedString.Key("NSFont")
    /// 실제: `public static let foregroundColor: NSAttributedString.Key` (raw "NSColor")
    public static let foregroundColor = NSAttributedString.Key("NSColor")
}

// MARK: - 색 · 이미지

/// 실제: `open class NSColor: NSObject { open class var clear: NSColor { get } ... }`
open class NSColor: NSObject {
    public static let clear = NSColor()
    public static let black = NSColor()
    public static let white = NSColor()
    public override init() { super.init() }
    public var cgColor: CGColor { CGColor(red: 0, green: 0, blue: 0, alpha: 0) }
    // [2026-08-21] `--tests` 가 요구한 표면. 실제 AppKit 에서 이 네 프로퍼티는 **RGB 색공간일 때만**
    // 유효하고 그 외에서는 예외를 던진다 — 타입만 맞추는 심이라 그 조건은 재현하지 않는다.
    // 호출부(`AncestorVisibilityGateRenderTests`)는 `NSBitmapImageRep.colorAt` 이 준 deviceRGB
    // 색이라 실물에서도 유효하다.
    public var redComponent: CGFloat { 0 }
    public var greenComponent: CGFloat { 0 }
    public var blueComponent: CGFloat { 0 }
    public var alphaComponent: CGFloat { 0 }
    /// 실제: HSB 접근자 세 벌. RGB 접근자와 같은 제약(캘리브레이션된 RGB 색공간에서만 유효)이다.
    /// [2026-08-21] `--tests` 가 요구한 표면(`SceneTranslatedEffectRenderTests:557` 이하가
    /// 색상 변환 이펙트의 결과를 밝기로 비교한다).
    public var hueComponent: CGFloat { 0 }
    public var saturationComponent: CGFloat { 0 }
    public var brightnessComponent: CGFloat { 0 }
}

/// 실제: `public struct NSColorSpaceName: RawRepresentable` — `.deviceRGB` 등.
public struct NSColorSpaceName: RawRepresentable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let deviceRGB = NSColorSpaceName(rawValue: "NSDeviceRGBColorSpace")
    public static let calibratedRGB = NSColorSpaceName(rawValue: "NSCalibratedRGBColorSpace")
}

/// 실제: `open class NSImageRep: NSObject { open var size: NSSize; pixelsWide; pixelsHigh }`
open class NSImageRep: NSObject {
    public var size: NSSize = .zero
    public var pixelsWide: Int = 0
    public var pixelsHigh: Int = 0
    public override init() { super.init() }
}

/// 실제: `open class NSBitmapImageRep: NSImageRep {
///        public init?(bitmapDataPlanes planes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
///                     pixelsWide: Int, pixelsHigh: Int, bitsPerSample bps: Int,
///                     samplesPerPixel spp: Int, hasAlpha: Bool, isPlanar: Bool,
///                     colorSpaceName: NSColorSpaceName, bytesPerRow rBytes: Int, bitsPerPixel pBits: Int)
///        open var bitmapData: UnsafeMutablePointer<UInt8>? { get }
///        open func representation(using storageType: NSBitmapImageRep.FileType,
///                                 properties: [NSBitmapImageRep.PropertyKey: Any]) -> Data? }`
open class NSBitmapImageRep: NSImageRep {
    public struct FileType: RawRepresentable, Hashable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let tiff = FileType(rawValue: 0)
        public static let bmp = FileType(rawValue: 1)
        public static let gif = FileType(rawValue: 2)
        public static let jpeg = FileType(rawValue: 3)
        public static let png = FileType(rawValue: 4)
    }
    public struct PropertyKey: RawRepresentable, Hashable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let compressionFactor = PropertyKey(rawValue: "NSImageCompressionFactor")
    }
    public init?(bitmapDataPlanes planes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
                 pixelsWide: Int, pixelsHigh: Int, bitsPerSample bps: Int, samplesPerPixel spp: Int,
                 hasAlpha: Bool, isPlanar: Bool, colorSpaceName: NSColorSpaceName,
                 bytesPerRow rBytes: Int, bitsPerPixel pBits: Int) { nil }
    // [2026-08-21] `--tests` 가 요구한 표면. 실제: `public init?(data: Data)` (NSImageRep 의
    // 지정 이니셜라이저가 아니라 NSBitmapImageRep 자신의 것이다) 와
    // `open func colorAt(x: Int, y: Int) -> NSColor?`.
    public init?(data: Data) { nil }
    public func colorAt(x: Int, y: Int) -> NSColor? { nil }
    /// 실제: `open var cgImage: CGImage? { get }`.
    public var cgImage: CGImage? { nil }
    public var bitmapData: UnsafeMutablePointer<UInt8>? { nil }
    public func representation(using storageType: FileType, properties: [PropertyKey: Any]) -> Data? { nil }
}

/// 실제: `open class NSImage: NSObject { public init?(data: Data); public init?(contentsOfFile: String)
///        open var size: NSSize
///        open func cgImage(forProposedRect proposedDestRect: UnsafeMutablePointer<NSRect>?,
///                          context referenceContext: NSGraphicsContext?,
///                          hints: [NSImageRep.HintKey: Any]?) -> CGImage? }`
/// 확신 없음: `cgImage(forProposedRect:context:hints:)` 의 실제 반환은 `CGImage?` 이고 첫 인자는
/// `UnsafeMutablePointer<NSRect>?` 다(호출부는 전부 `nil` 을 준다).
open class NSImage: NSObject {
    public var size: NSSize = .zero
    public init?(data: Data) { nil }
    public init?(contentsOfFile fileName: String) { nil }
    /// 실제: `public init?(contentsOf url: URL)`.
    /// [2026-08-21] `--tests` 가 요구한 표면(`RealPackagesGroundTruthTests:172`).
    /// 이게 없으면 `NSImage(contentsOf:)` 가 `init()` 에 인자를 넘긴 꼴이 되어
    /// "argument passed to call that takes no arguments" 로 나오고, `img` 가 미해결이라
    /// 뒤따르는 네 줄이 전부 파생 오류로 딸려 나온다(오류 6줄 중 5줄이 그 파생이었다).
    public init?(contentsOf url: URL) { nil }
    public override init() { super.init() }
    public func cgImage(forProposedRect proposedDestRect: UnsafeMutablePointer<NSRect>?,
                        context referenceContext: NSGraphicsContext?,
                        hints: [NSImageRep.HintKey: Any]?) -> CGImage? { nil }
    /// 실제: `open var tiffRepresentation: Data? { get }`.
    /// [2026-08-21] `--tests` 가 요구한 표면(`RealWebGroundTruthTests:66` 이 스냅샷 NSImage 를
    /// TIFF 로 뽑아 `NSBitmapImageRep(data:)` 에 먹인다).
    public var tiffRepresentation: Data? { nil }
}

extension NSImageRep {
    public struct HintKey: RawRepresentable, Hashable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }
}

/// 실제: `open class NSGraphicsContext: NSObject { open class var current: NSGraphicsContext? ... }`
open class NSGraphicsContext: NSObject {
    public static var current: NSGraphicsContext?
    public var cgContext: CGContext { fatalError("linux shim") }
}

// MARK: - 화면

/// 실제: `public struct NSDeviceDescriptionKey: RawRepresentable, Hashable`
public struct NSDeviceDescriptionKey: RawRepresentable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// 실제: `open class NSScreen: NSObject { open class var screens: [NSScreen] { get }
///        open class var main: NSScreen? { get }; open var frame: NSRect { get }
///        open var visibleFrame: NSRect { get }; open var backingScaleFactor: CGFloat { get }
///        open var localizedName: String { get }
///        open var deviceDescription: [NSDeviceDescriptionKey: Any] { get } }`
open class NSScreen: NSObject {
    public class var screens: [NSScreen] { [] }
    public class var main: NSScreen? { nil }
    public var frame: NSRect { .zero }
    public var visibleFrame: NSRect { .zero }
    public var backingScaleFactor: CGFloat { 1 }
    public var localizedName: String { "" }
    public var deviceDescription: [NSDeviceDescriptionKey: Any] { [:] }
    public override init() { super.init() }
}

// MARK: - 뷰 · 창

/// 실제: `open class NSResponder: NSObject {
///        open var acceptsFirstResponder: Bool { get }
///        open func mouseDown(with event: NSEvent); mouseDragged / mouseUp / mouseMoved
///        open func scrollWheel(with event: NSEvent); keyDown / keyUp }`
open class NSResponder: NSObject {
    public override init() { super.init() }
    open var acceptsFirstResponder: Bool { false }
    open func mouseDown(with event: NSEvent) {}
    open func mouseDragged(with event: NSEvent) {}
    open func mouseUp(with event: NSEvent) {}
    open func mouseMoved(with event: NSEvent) {}
    open func scrollWheel(with event: NSEvent) {}
    open func keyDown(with event: NSEvent) {}
    open func keyUp(with event: NSEvent) {}
}

/// 실제: `open class NSTrackingArea: NSObject {
///        public init(rect: NSRect, options: NSTrackingArea.Options, owner: Any?, userInfo: [AnyHashable: Any]?)
///        open var options: NSTrackingArea.Options { get } }`
open class NSTrackingArea: NSObject {
    /// 실제: `public struct NSTrackingArea.Options: OptionSet { public let rawValue: UInt }`
    /// 원시값은 헤더의 비트 배치(mouseEnteredAndExited=0x01, mouseMoved=0x02, …,
    /// activeInKeyWindow=0x20, inVisibleRect=0x200)를 적었다. **확신 없음** — 이름만 확실하다.
    public struct Options: OptionSet {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let mouseEnteredAndExited = Options(rawValue: 0x01)
        public static let mouseMoved = Options(rawValue: 0x02)
        public static let cursorUpdate = Options(rawValue: 0x04)
        public static let activeWhenFirstResponder = Options(rawValue: 0x10)
        public static let activeInKeyWindow = Options(rawValue: 0x20)
        public static let activeInActiveApp = Options(rawValue: 0x40)
        public static let activeAlways = Options(rawValue: 0x80)
        public static let assumeInside = Options(rawValue: 0x100)
        public static let inVisibleRect = Options(rawValue: 0x200)
        public static let enabledDuringMouseDrag = Options(rawValue: 0x400)
    }
    public let options: Options
    public init(rect: NSRect, options: Options, owner: Any?, userInfo: [AnyHashable: Any]?) {
        self.options = options
        super.init()
    }
}

/// 실제: `open class NSView: NSResponder { public init(frame frameRect: NSRect)
///        open var frame: NSRect; open var bounds: NSRect; open var window: NSWindow? { get }
///        open var layer: CALayer?; open var wantsLayer: Bool
///        open var autoresizingMask: NSView.AutoresizingMask
///        open var subviews: [NSView]; open func addSubview(_ view: NSView)
///        open func removeFromSuperview(); open var needsDisplay: Bool
///        open func convert(_ point: NSPoint, from view: NSView?) -> NSPoint
///        open func viewDidMoveToWindow() }`
open class NSView: NSResponder {
    public struct AutoresizingMask: OptionSet {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let none = AutoresizingMask([])
        public static let minXMargin = AutoresizingMask(rawValue: 1)
        public static let width = AutoresizingMask(rawValue: 2)
        public static let maxXMargin = AutoresizingMask(rawValue: 4)
        public static let minYMargin = AutoresizingMask(rawValue: 8)
        public static let height = AutoresizingMask(rawValue: 16)
        public static let maxYMargin = AutoresizingMask(rawValue: 32)
    }
    public var frame: NSRect = .zero
    public var bounds: NSRect = .zero
    public var window: NSWindow? { nil }
    public var layer: CALayer?
    public var wantsLayer: Bool = false
    public var autoresizingMask: AutoresizingMask = []
    public var needsDisplay: Bool = false
    public var subviews: [NSView] = []
    public var superview: NSView? { nil }
    public var isHidden: Bool = false
    public init(frame frameRect: NSRect) { super.init() }
    public override init() { super.init() }
    open func addSubview(_ view: NSView) {}
    open func removeFromSuperview() {}
    open func convert(_ point: NSPoint, from view: NSView?) -> NSPoint { point }
    open func convert(_ rect: NSRect, from view: NSView?) -> NSRect { rect }
    open func viewDidMoveToWindow() {}
    open func viewDidMoveToSuperview() {}
    open func setNeedsDisplay(_ invalidRect: NSRect) {}
    /// 실제: `open func draw(_ dirtyRect: NSRect)`
    open func draw(_ dirtyRect: NSRect) {}
    /// 실제: `open var trackingAreas: [NSTrackingArea] { get }`
    ///        `open func addTrackingArea(_ trackingArea: NSTrackingArea)`
    ///        `open func removeTrackingArea(_ trackingArea: NSTrackingArea)`
    public var trackingAreas: [NSTrackingArea] { [] }
    open func addTrackingArea(_ trackingArea: NSTrackingArea) {}
    open func removeTrackingArea(_ trackingArea: NSTrackingArea) {}
}

/// 실제: `open class NSWindow: NSResponder { ... }`
open class NSWindow: NSResponder {
    public struct StyleMask: OptionSet {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let borderless = StyleMask([])
        public static let titled = StyleMask(rawValue: 1)
        public static let closable = StyleMask(rawValue: 2)
        public static let miniaturizable = StyleMask(rawValue: 4)
        public static let resizable = StyleMask(rawValue: 8)
        public static let fullSizeContentView = StyleMask(rawValue: 32768)
    }
    /// 실제: `public enum NSWindow.BackingStoreType: UInt { case retained, nonretained, buffered }`
    public enum BackingStoreType: UInt { case retained = 0, nonretained = 1, buffered = 2 }
    /// 실제: `public struct NSWindow.Level: RawRepresentable { public let rawValue: Int }`
    public struct Level: RawRepresentable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let normal = Level(rawValue: 0)
        public static let floating = Level(rawValue: 3)
        public static let statusBar = Level(rawValue: 25)
    }
    public struct CollectionBehavior: OptionSet {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let canJoinAllSpaces = CollectionBehavior(rawValue: 1)
        public static let moveToActiveSpace = CollectionBehavior(rawValue: 2)
        public static let managed = CollectionBehavior(rawValue: 4)
        public static let transient = CollectionBehavior(rawValue: 8)
        public static let stationary = CollectionBehavior(rawValue: 16)
        public static let participatesInCycle = CollectionBehavior(rawValue: 32)
        public static let ignoresCycle = CollectionBehavior(rawValue: 64)
        public static let fullScreenPrimary = CollectionBehavior(rawValue: 128)
        public static let fullScreenAuxiliary = CollectionBehavior(rawValue: 256)
    }
    /// 실제: `public struct NSWindow.OcclusionState: OptionSet { static let visible }`
    public struct OcclusionState: OptionSet {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let visible = OcclusionState(rawValue: 2)
    }

    public var contentView: NSView?
    public var level: Level = .normal
    public var collectionBehavior: CollectionBehavior = []
    public var ignoresMouseEvents: Bool = false
    public var hasShadow: Bool = true
    public var isOpaque: Bool = true
    public var backgroundColor: NSColor? = NSColor()
    public var screen: NSScreen? { nil }
    public var occlusionState: OcclusionState { [] }
    public var frame: NSRect { .zero }
    /// 실제: `open var title: String`; `open var isReleasedWhenClosed: Bool`
    ///        `open var isVisible: Bool { get }`; `weak open var delegate: (any NSWindowDelegate)?`
    public var title: String = ""
    public var isReleasedWhenClosed: Bool = true
    public var isVisible: Bool { false }
    /// 실제: `open var alphaValue: CGFloat`.
    /// [2026-08-21] `--tests` 가 요구한 표면(`RealWebGroundTruthTests:249` 가 헤드리스 캡처용
    /// 창을 `alphaValue = 0` 으로 숨긴다).
    public var alphaValue: CGFloat = 1
    public weak var delegate: (any NSWindowDelegate)?
    /// [2026-08-21] `--app` 이 요구한 표면(`AppDelegate.swift` 의 라이브러리/설정 창).
    /// 실제: `open var styleMask: NSWindow.StyleMask` · `open var toolbarStyle: NSWindow.ToolbarStyle`
    ///        `open var minSize/maxSize: NSSize` · `open var contentMinSize/contentMaxSize: NSSize`
    ///        `open var isMiniaturized: Bool { get }`
    public var styleMask: StyleMask = []
    public var minSize: NSSize = .zero
    public var maxSize: NSSize = .zero
    public var contentMinSize: NSSize = .zero
    public var contentMaxSize: NSSize = .zero
    public var isMiniaturized: Bool { false }

    /// 실제: `public init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
    ///        backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool)`
    public init(contentRect: NSRect, styleMask style: StyleMask,
                backing backingStoreType: BackingStoreType, defer flag: Bool) { super.init() }
    open func setFrame(_ frameRect: NSRect, display flag: Bool) {}
    open func orderFrontRegardless() {}
    /// 실제: `open func orderFront(_ sender: Any?)` · `open func close()`.
    /// [2026-08-21] `--tests` 요구 표면(`WebHardPauseTests:163`·`:109`).
    open func orderFront(_ sender: Any?) {}
    open func close() {}
    open func orderOut(_ sender: Any?) {}
    open func makeKeyAndOrderFront(_ sender: Any?) {}
    /// 실제: `open func convertPoint(fromScreen point: NSPoint) -> NSPoint` (macOS 10.12+)
    open func convertPoint(fromScreen point: NSPoint) -> NSPoint { point }
    open func convertPoint(toScreen point: NSPoint) -> NSPoint { point }
    /// 실제: `open func center()`
    ///        `open func makeFirstResponder(_ responder: NSResponder?) -> Bool` (@discardableResult 아님)
    open func center() {}
    @discardableResult
    open func makeFirstResponder(_ responder: NSResponder?) -> Bool { false }
}

/// 실제: `public protocol NSWindowDelegate: NSObjectProtocol { ... }` — 요구사항이 전부
/// **optional @objc** 다. 리눅스에는 ObjC 런타임이 없어 기본 구현으로 대체한다
/// (= 셀렉터 어긋남을 못 잡는다 — `docs/dev/linux-typecheck.md` 한계 ③).
public protocol NSWindowDelegate: NSObjectProtocol {
    func windowWillClose(_ notification: Notification)
    func windowDidResize(_ notification: Notification)
}
public extension NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {}
    func windowDidResize(_ notification: Notification) {}
}

/// 실제: `extension NSWindow { public class let didChangeOcclusionStateNotification: NSNotification.Name }`
/// (원시값 `NSWindowDidChangeOcclusionStateNotification`)
extension NSWindow {
    public static let didChangeOcclusionStateNotification =
        NSNotification.Name("NSWindowDidChangeOcclusionStateNotification")
}

// MARK: - 이벤트

/// 실제: `open class NSEvent: NSObject { ... }`
open class NSEvent: NSObject {
    /// 실제: `public struct NSEvent.EventTypeMask: OptionSet { public let rawValue: UInt64 }`
    public struct EventTypeMask: OptionSet {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }
        public static let leftMouseDown = EventTypeMask(rawValue: 1 << 1)
        public static let leftMouseUp = EventTypeMask(rawValue: 1 << 2)
        public static let rightMouseDown = EventTypeMask(rawValue: 1 << 3)
        public static let rightMouseUp = EventTypeMask(rawValue: 1 << 4)
        public static let mouseMoved = EventTypeMask(rawValue: 1 << 5)
        public static let scrollWheel = EventTypeMask(rawValue: 1 << 22)
    }
    /// 실제: `public enum NSEvent.EventType: UInt { case leftMouseDown = 1, ... }`
    public enum EventType: UInt {
        case leftMouseDown = 1, leftMouseUp = 2, rightMouseDown = 3, rightMouseUp = 4, mouseMoved = 5
        case scrollWheel = 22
    }
    public var type: EventType { .mouseMoved }
    public var locationInWindow: NSPoint { .zero }
    public var window: NSWindow? { nil }
    /// 실제: `open var scrollingDeltaX: CGFloat { get }` / `scrollingDeltaY`
    ///        `open var charactersIgnoringModifiers: String? { get }`
    ///        `open var keyCode: UInt16 { get }`
    /// (앞의 셋은 잘못된 이벤트 타입에서 읽으면 애플에서는 예외/0 이지만 타입은 동일하다.)
    public var scrollingDeltaX: CGFloat { 0 }
    public var scrollingDeltaY: CGFloat { 0 }
    public var charactersIgnoringModifiers: String? { nil }
    public var characters: String? { nil }
    public var keyCode: UInt16 { 0 }
    /// 실제: `open class var mouseLocation: NSPoint { get }` (화면 좌표)
    public class var mouseLocation: NSPoint { .zero }
    /// 실제: `open class func addGlobalMonitorForEvents(matching mask: NSEvent.EventTypeMask,
    ///        handler block: @escaping (NSEvent) -> Void) -> Any?`
    public class func addGlobalMonitorForEvents(matching mask: EventTypeMask,
                                                handler block: @escaping (NSEvent) -> Void) -> Any? { nil }
    /// 실제: `open class func addLocalMonitorForEvents(matching:handler:) -> Any?`
    ///  (핸들러가 `(NSEvent) -> NSEvent?` 라는 점이 global 과 다르다)
    public class func addLocalMonitorForEvents(matching mask: EventTypeMask,
                                               handler block: @escaping (NSEvent) -> NSEvent?) -> Any? { nil }
    /// 실제: `open class func removeMonitor(_ eventMonitor: Any)`
    public class func removeMonitor(_ eventMonitor: Any) {}
}

// MARK: - 워크스페이스 · 앱

/// 실제: `open class NSRunningApplication: NSObject { open var bundleIdentifier: String? { get }
///        open var localizedName: String? { get }; open var processIdentifier: pid_t { get } }`
open class NSRunningApplication: NSObject {
    public var bundleIdentifier: String? { nil }
    public var localizedName: String? { nil }
}

/// 실제: `open class NSWorkspace: NSObject { open class var shared: NSWorkspace { get }
///        open var runningApplications: [NSRunningApplication] { get } }`
open class NSWorkspace: NSObject {
    public static let shared = NSWorkspace()
    public var runningApplications: [NSRunningApplication] { [] }
    public var notificationCenter: NotificationCenter { NotificationCenter.default }
    public override init() { super.init() }
}

/// 실제: `open class NSApplication: NSResponder { open class var shared: NSApplication { get } ... }`
/// `NSApp` 은 전역 `let NSApp: NSApplication!` 이다.
open class NSApplication: NSResponder {
    public static let shared = NSApplication()
    public var keyWindow: NSWindow? { nil }
    public var windows: [NSWindow] { [] }
    /// 실제: `open func activate(ignoringOtherApps flag: Bool)` (macOS 14 에서 deprecated 되고
    /// `activate()` 가 권장되지만 시그니처 자체는 그대로 남아 있다)
    open func activate(ignoringOtherApps flag: Bool) {}
}
public let NSApp: NSApplication! = nil


// MARK: - 그리기 유틸(AppKit 오버레이)

/// 실제: `public enum NSCompositingOperation: UInt { case clear = 0, copy = 1, sourceOver = 2, ... }`
public enum NSCompositingOperation: UInt {
    case clear = 0, copy = 1, sourceOver = 2, sourceIn = 3, sourceOut = 4, sourceAtop = 5
    case destinationOver = 6, destinationIn = 7, destinationOut = 8, destinationAtop = 9
    case xor = 10, plusDarker = 11, plusLighter = 13
}

/// 실제: AppKit 스위프트 오버레이의 `extension NSRect { public func fill(using operation: NSCompositingOperation) }`
/// 와 인자 없는 `fill()`. 확신 없음: 기본 인자 형태인지 오버로드 두 개인지 헤더로 확인하지 못했다.
/// 여기서는 호출부(`bounds.fill()`)만 만족시키는 오버로드 둘로 둔다.
public extension NSRect {
    func fill() {}
    func fill(using operation: NSCompositingOperation) {}
}

/// 실제: `extension NSColor { open func setFill(); open func set() }`
public extension NSColor {
    func setFill() {}
    func set() {}
}

/// 실제: `extension NSString { open func draw(at point: NSPoint,
///        withAttributes attrs: [NSAttributedString.Key: Any]?) }`
/// (애플에서는 AppKit 이 Foundation 의 `NSString` 에 그리기 API 를 얹는다.)
public extension NSString {
    func draw(at point: NSPoint, withAttributes attrs: [NSAttributedString.Key: Any]?) {}
}

/// 실제: `extension NSImage { open func draw(in rect: NSRect, from fromRect: NSRect,
///        operation op: NSCompositingOperation, fraction delta: CGFloat) }`
public extension NSImage {
    func draw(in rect: NSRect, from fromRect: NSRect,
              operation op: NSCompositingOperation, fraction delta: CGFloat) {}
}
