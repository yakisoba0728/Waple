import AppKit

public final class DesktopWindowController {
    private var windows: [DesktopWindow] = []

    public init() {}

    /// 모든 화면에 대해 데스크탑 창을 다시 만든다.
    public func rebuild() {
        teardown()
        for screen in NSScreen.screens {
            let window = DesktopWindow(screen: screen)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    public var contentViews: [NSView] {
        windows.compactMap { $0.contentView }
    }

    /// 화면 키와 함께(모니터별 배경).
    public var screenViews: [(screenKey: String, view: NSView)] {
        windows.compactMap { w in w.contentView.map { (w.screenKey, $0) } }
    }

    public func teardown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}
