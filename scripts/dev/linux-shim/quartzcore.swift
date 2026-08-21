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
    public override init() { super.init() }
    open func addSublayer(_ layer: CALayer) {}
    open func removeFromSuperlayer() {}
    open func setNeedsDisplay() {}
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
