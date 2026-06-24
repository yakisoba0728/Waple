import AppKit

public final class DesktopWindow: NSWindow {
    public init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // 시작점: 아이콘 뒤·정적 배경 위. Step 4 에서 실측 검증할 것.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        setFrame(screen.frame, display: true)

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        contentView = content
    }
}
