// 리눅스용 **QuartzCore 대역 선언**(shim). 타입체크 전용. 배경·규약은 `metal.swift` 머리말 참조.
@_exported import CoreGraphics

/// 실제: `open class CALayer: NSObject { open var isGeometryFlipped: Bool
///        open var contents: Any?; open var contentsScale: CGFloat; open var frame: CGRect
///        open var bounds: CGRect; open var backgroundColor: CGColor?; ... }`
open class CALayer: NSObject {
    public var isGeometryFlipped: Bool = false
    public var contents: Any?
    public var contentsScale: CGFloat = 1
    public var frame: CGRect = .zero
    public var bounds: CGRect = .zero
    public var backgroundColor: CGColor?
    public var isOpaque: Bool = false
    public var masksToBounds: Bool = false
    public var sublayers: [CALayer]?
    /// 실제: `open var autoresizingMask: CAAutoresizingMask`
    public var autoresizingMask: CAAutoresizingMask = []
    public override init() { super.init() }
    open func addSublayer(_ layer: CALayer) {}
    open func removeFromSuperlayer() {}
    open func setNeedsDisplay() {}
}

/// 실제: `public struct CAAutoresizingMask: OptionSet { public let rawValue: UInt32
///        static let layerMinXMargin/layerWidthSizable/layerMaxXMargin/
///                  layerMinYMargin/layerHeightSizable/layerMaxYMargin }`
/// 원시값은 헤더의 비트 순서(1,2,4,8,16,32)를 그대로 적었다.
public struct CAAutoresizingMask: OptionSet {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let layerNotSizable = CAAutoresizingMask([])
    public static let layerMinXMargin = CAAutoresizingMask(rawValue: 1)
    public static let layerWidthSizable = CAAutoresizingMask(rawValue: 2)
    public static let layerMaxXMargin = CAAutoresizingMask(rawValue: 4)
    public static let layerMinYMargin = CAAutoresizingMask(rawValue: 8)
    public static let layerHeightSizable = CAAutoresizingMask(rawValue: 16)
    public static let layerMaxYMargin = CAAutoresizingMask(rawValue: 32)
}

/// 실제: `open class CAMetalLayer: CALayer { open var device: MTLDevice?
///        open var pixelFormat: MTLPixelFormat; open var framebufferOnly: Bool
///        open var drawableSize: CGSize; open func nextDrawable() -> CAMetalDrawable? }`
/// 확신 없음: WapleRender 는 현재 주석에서만 언급하고 실제로 쓰지 않아 검증되지 않았다.
open class CAMetalLayer: CALayer {}

/// 실제: `public func CACurrentMediaTime() -> CFTimeInterval` (mach_absolute_time 기반 단조 시계)
public func CACurrentMediaTime() -> CFTimeInterval { Date().timeIntervalSinceReferenceDate }

/// 실제: `open class CADisplayLink: NSObject { ... }` — macOS 14+ 에도 있다.
/// 확신 없음: WapleRender 는 주석에서만 언급한다.
open class CADisplayLink: NSObject {
    public var isPaused: Bool = false
    public func invalidate() {}
}
