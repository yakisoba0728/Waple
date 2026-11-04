import AppKit
import MetalKit
import QuartzCore
import WapleCore

/// Non-interactive transparent outgoing-frame overlay. The incoming renderer lives underneath.
@MainActor
public final class PlaylistTransitionView: MTKView, @preconcurrency MTKViewDelegate {
    private var transitionRenderer: PlaylistTransitionRenderer?
    private let commandQueue: MTLCommandQueue
    private let durationMillis: Int
    private var startTime: CFTimeInterval?
    private var completion: (@MainActor () -> Void)?
    private(set) var isFinished = false

    public init?(oldImage: NSImage, kind: PlaylistTransitionKind, durationMillis: Int,
                 completion: @escaping @MainActor () -> Void) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do { transitionRenderer = try PlaylistTransitionRenderer(device: device, oldImage: oldImage, kind: kind) }
        catch {
            NSLog("[Waple] playlist transition unavailable: %@", String(describing: error))
            return nil
        }
        commandQueue = queue
        self.durationMillis = max(0, durationMillis)
        self.completion = completion
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Use init(oldImage:kind:durationMillis:completion:)") }

    public override var isOpaque: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, startTime == nil { startTime = CACurrentMediaTime() }
    }

    /// Idempotent cancellation never calls the natural-completion callback.
    public func cancel() {
        guard !isFinished else { return }
        isFinished = true
        isPaused = true
        delegate = nil
        transitionRenderer = nil
        completion = nil
        removeFromSuperview()
    }

    /// Shared with the actual draw callback so timing/lifecycle tests do not duplicate its decision.
    @discardableResult
    func advance(elapsed: TimeInterval) -> Float {
        guard !isFinished else { return 1 }
        let progress = TransitionTimeline.progress(elapsed: Float(elapsed), transitionTimeMillis: durationMillis)
        if progress >= 1 {
            let callback = completion
            cancel()
            callback?()
        }
        return progress
    }

    public func draw(in view: MTKView) {
        guard !isFinished else { return }
        let now = CACurrentMediaTime()
        if startTime == nil { startTime = now }
        let progress = advance(elapsed: now - (startTime ?? now))
        guard !isFinished, let renderer = transitionRenderer,
              let drawable = currentDrawable, let buffer = commandQueue.makeCommandBuffer() else { return }
        do {
            try renderer.encode(to: drawable.texture, progress: progress, commandBuffer: buffer)
            buffer.present(drawable)
            buffer.commit()
        } catch {
            NSLog("[Waple] playlist transition draw failed: %@", String(describing: error))
            // Let the incoming renderer remain visible even if a GPU resource is no longer available.
            let callback = completion
            cancel()
            callback?()
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
