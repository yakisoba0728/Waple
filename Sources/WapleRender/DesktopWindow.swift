import AppKit

public final class DesktopWindow: NSWindow {
    /// 모니터별 배경 할당의 안정 키(CGDirectDisplayID 기반; 실패 시 이름).
    public let screenKey: String

    /// NSScreen → 안정 키(CGDirectDisplayID 기반; 실패 시 이름). 정적 배경 동기화가
    /// 화면별 원본을 같은 키로 저장·복원하도록 init 과 공유한다.
    public static func screenKey(for screen: NSScreen) -> String {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "display-\(n.uint32Value)"
        }
        return "name-\(screen.localizedName)"
    }

    public init(screen: NSScreen) {
        screenKey = DesktopWindow.screenKey(for: screen)
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // 아이콘 뒤·정적 배경 위. Darwin 27 에서 .desktopWindow 는 시스템 정적 배경보다
        // 아래로 묻혀 보이지 않으므로, 아이콘 레벨 바로 아래(= 배경 위, 아이콘 아래)로 둔다.
        level = WallpaperWindowLevel.desktopWallpaper
        // 전체화면 앱 위 보조창 허용(.fullScreenAuxiliary) — 전체화면 스페이스에서도 배경 유지.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
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
