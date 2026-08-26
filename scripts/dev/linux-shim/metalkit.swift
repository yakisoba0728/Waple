// 리눅스용 **MetalKit 대역 선언**(shim). 타입체크 전용. 배경·규약은 `metal.swift` 머리말 참조.
// 애플의 MetalKit 은 Metal 과 AppKit 을 재수출한다 — 여기서도 같게 둔다.
@_exported import Metal
@_exported import AppKit

/// 실제: `public protocol MTKViewDelegate: NSObjectProtocol {
///        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)
///        func draw(in view: MTKView) }`
/// [2026-08-26] **요구사항에 `@MainActor` 를 붙인다 — 실물이 그렇다.**
///
/// 안 붙이면 `SceneRenderer.draw(in:)` 이 비격리 witness 가 되고, 그 안에서 `@MainActor` 인
/// `tickAnimationEvents` 를 부르는 것이 오류가 된다(`SceneRenderer.swift:2310`,
/// `[#ActorIsolatedCall]`). macOS CI 는 초록인데 이 하네스만 붉었다 — 즉 **커버 55/55 라고
/// 적혀 있던 이 게이트가 실제로는 rc=1 로 죽어 있었다.** 원본 HEAD `eecc889` 를 CI 와 같은
/// Swift 6.3.2 로 돌려 확인한 사실이고, 6.2 에서도 같다(툴체인 차이가 아니라 심 부정확이다).
///
/// **프로토콜 전체에 붙이면 안 된다.** 그러면 `SceneRenderer` 가 전역 액터 추론으로 통째로
/// `@MainActor` 가 되어 `mount`/`captureFrames`/`teardown`/`init` 이 전부 격리되고,
/// `AppDelegate.captureSceneStill`(비격리·백그라운드 큐)이 컴파일되지 않는다 — 그 함수들에
/// `@MainActor` 를 붙이지 말라는 `SceneRenderer.swift:1937`·`:1969` 의 금지와 정면으로 부딪힌다.
/// 실측으로도 그 형태는 테스트 4곳을 깨뜨렸다. 실물 swiftinterface 와 같은 **요구사항 단위**가 맞다.
@preconcurrency @MainActor public protocol MTKViewDelegate: AnyObject {
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
