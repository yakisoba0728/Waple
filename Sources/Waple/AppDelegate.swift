import AppKit
import WapleRender

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let desktopController = DesktopWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖼"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Quit Waple",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem.menu = menu

        // 디버그: 데스크탑 창이 보이는지 확인용 반투명 빨강. Task 7 에서 영상으로 대체.
        desktopController.rebuild()
        for view in desktopController.contentViews {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.5).cgColor
        }
    }
}
