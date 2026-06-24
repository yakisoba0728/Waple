import AppKit
import SwiftUI
import WapleCore
import WapleLibrary
import WapleRender

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let desktopController = DesktopWindowController()
    private var renderers: [WallpaperRenderer] = []
    private var currentFolderURL: URL?

    private let store = LibraryStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private lazy var libraryVM = LibraryViewModel(store: store)
    private var libraryWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖼"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "라이브러리 열기",
                                action: #selector(openLibrary), keyEquivalent: "l"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Waple",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        libraryVM.onApply = { [weak self] folder in self?.apply(folderURL: folder) }

        desktopController.rebuild()

        // 화면 구성 변경(모니터 연결/해제/해상도) 시 창 재구성 후 재적용.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // 마지막 선택 배경 복원.
        restoreLastWallpaper()
    }

    @objc private func openLibrary() {
        if libraryWindow == nil {
            let hosting = NSHostingController(rootView: LibraryView(viewModel: libraryVM))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Waple"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 760, height: 500))
            libraryWindow = window
        }
        libraryWindow?.center()
        libraryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    private func restoreLastWallpaper() {
        guard let id = store.selectedId,
              let entry = store.entries.first(where: { $0.id == id }),
              let folder = store.resolveFolderURL(for: entry) else { return }
        apply(folderURL: folder)
    }

    @objc private func screensChanged() {
        desktopController.rebuild()
        if let folder = currentFolderURL {
            apply(folderURL: folder)
        }
    }

    private func notify(_ message: String) {
        NSLog("[Waple] \(message)")
    }
}
