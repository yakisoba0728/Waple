import AppKit
import WapleCore
import WapleRender

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let desktopController = DesktopWindowController()
    private var renderers: [WallpaperRenderer] = []
    private var currentFolderURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖼"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Apply Folder…",
                                action: #selector(chooseFolder), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Waple",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        desktopController.rebuild()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            apply(folderURL: url)
        }
    }

    private func apply(folderURL: URL) {
        do {
            let project = try ProjectJSONParser.parse(folderURL: folderURL)
            guard RendererFactory.makeRenderer(for: project.type) != nil else {
                notify("지원하지 않는 타입입니다: \(project.type.storageString)")
                return
            }
            renderers.forEach { $0.teardown() }
            renderers.removeAll()
            for view in desktopController.contentViews {
                guard let renderer = RendererFactory.makeRenderer(for: project.type) else { continue }
                try renderer.mount(in: view, project: project)
                renderers.append(renderer)
            }
            currentFolderURL = folderURL
        } catch {
            notify("적용 실패: \(error)")
        }
    }

    private func notify(_ message: String) {
        NSLog("[Waple] \(message)")
    }
}
