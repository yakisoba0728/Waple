import AppKit

public final class DesktopWindow: NSWindow {
    public init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // 아이콘 뒤·정적 배경 위. Darwin 27 에서 .desktopWindow 는 시스템 정적 배경보다
        // 아래로 묻혀 보이지 않으므로, 아이콘 레벨 바로 아래(= 배경 위, 아이콘 아래)로 둔다.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
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
