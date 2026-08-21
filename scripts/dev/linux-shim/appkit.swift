// 리눅스용 **AppKit 대역 선언**(shim). 타입체크 전용 — 동작하지 않는다.
// 배경·규약은 `metal.swift` 머리말과 같다.
//
// **AppKit 전체를 흉내내지 않는다.** `Sources/WapleRender/**` 중 커버 대상 파일이 실제로 쓰는
// 심볼만 있다. 그래서 WebKit 계열(`WebRenderer`·`WebInputProxyView`·`WallpaperSchemeHandler`)은
// 커버 대상이 아니다 — `docs/dev/linux-typecheck.md` 의 제외 목록 참조.
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
    public override init() { super.init() }
    public func cgImage(forProposedRect proposedDestRect: UnsafeMutablePointer<NSRect>?,
                        context referenceContext: NSGraphicsContext?,
                        hints: [NSImageRep.HintKey: Any]?) -> CGImage? { nil }
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

/// 실제: `open class NSResponder: NSObject { ... }`
open class NSResponder: NSObject {
    public override init() { super.init() }
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

    /// 실제: `public init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
    ///        backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool)`
    public init(contentRect: NSRect, styleMask style: StyleMask,
                backing backingStoreType: BackingStoreType, defer flag: Bool) { super.init() }
    open func setFrame(_ frameRect: NSRect, display flag: Bool) {}
    open func orderFrontRegardless() {}
    open func orderOut(_ sender: Any?) {}
    open func makeKeyAndOrderFront(_ sender: Any?) {}
    /// 실제: `open func convertPoint(fromScreen point: NSPoint) -> NSPoint` (macOS 10.12+)
    open func convertPoint(fromScreen point: NSPoint) -> NSPoint { point }
    open func convertPoint(toScreen point: NSPoint) -> NSPoint { point }
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
}
public let NSApp: NSApplication! = nil
