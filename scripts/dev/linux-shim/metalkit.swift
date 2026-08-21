// 리눅스용 **MetalKit 대역 선언**(shim). 타입체크 전용. 배경·규약은 `metal.swift` 머리말 참조.
// 애플의 MetalKit 은 Metal 과 AppKit 을 재수출한다 — 여기서도 같게 둔다.
@_exported import Metal
@_exported import AppKit

/// 실제: `public protocol MTKViewDelegate: NSObjectProtocol {
///        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)
///        func draw(in view: MTKView) }`
public protocol MTKViewDelegate: AnyObject {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)
    func draw(in view: MTKView)
}

/// 실제: `open class MTKView: NSView, NSCoding, CALayerDelegate {
///        public init(frame frameRect: CGRect, device: MTLDevice?)
///        weak open var delegate: MTKViewDelegate?
///        open var device: MTLDevice?
///        open var currentDrawable: CAMetalDrawable? { get }
///        open var currentRenderPassDescriptor: MTLRenderPassDescriptor? { get }
///        open var colorPixelFormat: MTLPixelFormat
///        open var depthStencilPixelFormat: MTLPixelFormat
///        open var framebufferOnly: Bool
///        open var clearColor: MTLClearColor
///        open var drawableSize: CGSize
///        open var autoResizeDrawable: Bool
///        open var preferredFramesPerSecond: Int
///        open var isPaused: Bool
///        open var enableSetNeedsDisplay: Bool
///        open func draw() }`
open class MTKView: NSView {
    public weak var delegate: MTKViewDelegate?
    public var device: MTLDevice?
    /// 실제 반환은 `CAMetalDrawable?` — `CAMetalDrawable: MTLDrawable` 이고 `.texture: MTLTexture` 를 준다.
    public var currentDrawable: CAMetalDrawable? { nil }
    public var currentRenderPassDescriptor: MTLRenderPassDescriptor? { nil }
    public var colorPixelFormat: MTLPixelFormat = .bgra8Unorm
    public var depthStencilPixelFormat: MTLPixelFormat = .invalid
    public var framebufferOnly: Bool = true
    public var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    public var drawableSize: CGSize = .zero
    public var autoResizeDrawable: Bool = true
    public var preferredFramesPerSecond: Int = 60
    public var isPaused: Bool = false
    public var enableSetNeedsDisplay: Bool = false
    public var sampleCount: Int = 1
    public init(frame frameRect: CGRect, device: MTLDevice?) {
        self.device = device
        super.init(frame: frameRect)
    }
    open func draw() {}
}

/// 실제: `public protocol CAMetalDrawable: MTLDrawable { var texture: MTLTexture { get }
///        var layer: CAMetalLayer { get } }` — QuartzCore 소속이지만 MTKView 반환형이라 여기 둔다.
public protocol CAMetalDrawable: MTLDrawable {
    var texture: MTLTexture { get }
}
