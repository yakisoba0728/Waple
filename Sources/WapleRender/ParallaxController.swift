import AppKit

public final class ParallaxController {
    public var onOffset: ((CGPoint) -> Void)?
    private var monitor: Any?

    public init() {}

    // teardown() 없이 해제돼도 전역 모니터가 프로세스 수명 동안 남지 않도록 하는 안전망.
    deinit { stop() }

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.emit()
        }
        emit()
    }

    public func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func emit() {
        let frame = NSScreen.main?.frame ?? .zero
        onOffset?(ParallaxController.normalizedOffset(mouse: NSEvent.mouseLocation, screenFrame: frame))
    }

    /// 화면 중심=0, 가장자리=±1, 밖은 클램프. (순수)
    public static func normalizedOffset(mouse: CGPoint, screenFrame: CGRect) -> CGPoint {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return .zero }
        let nx = (mouse.x - screenFrame.midX) / (screenFrame.width / 2)
        let ny = (mouse.y - screenFrame.midY) / (screenFrame.height / 2)
        return CGPoint(x: min(max(nx, -1), 1), y: min(max(ny, -1), 1))
    }
}
