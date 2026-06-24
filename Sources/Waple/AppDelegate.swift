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
    private weak var fitMenu: NSMenu?

    @objc private func setFitMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = FitMode(rawValue: raw) else { return }
        SceneRenderSettings.fitMode = mode
        fitMenu?.items.forEach { $0.state = (($0.representedObject as? String) == raw) ? .on : .off }
        if let folder = currentFolderURL { apply(folderURL: folder) }  // 현재 배경 재적용으로 즉시 반영
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖼"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "라이브러리 열기",
                                action: #selector(openLibrary), keyEquivalent: "l"))
        let fitItem = NSMenuItem(title: "화면 맞춤", action: nil, keyEquivalent: "")
        let fitMenu = NSMenu()
        for mode in FitMode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(setFitMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.state = (SceneRenderSettings.fitMode == mode) ? .on : .off
            fitMenu.addItem(item)
        }
        fitItem.submenu = fitMenu
        menu.addItem(fitItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Waple",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        self.fitMenu = fitMenu

        libraryVM.onApply = { [weak self] folder in self?.apply(folderURL: folder) }
        libraryVM.onError = { [weak self] message in self?.notify(message) }

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
            // 프로그램 생성 NSWindow 는 닫힐 때 기본적으로 release 되어, 강한 참조 프로퍼티가
            // 댕글링되고 재오픈 시 use-after-free 가 된다. 프로퍼티가 수명을 관리하도록 막는다.
            window.isReleasedWhenClosed = false
            libraryWindow = window
        }
        libraryWindow?.center()
        libraryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func apply(folderURL: URL) {
        do {
            let project = try ProjectJSONParser.parse(folderURL: folderURL)
            guard RendererFactory.makeRenderer(for: project) != nil else {
                notify("지원하지 않는 타입입니다: \(project.type.storageString)")
                return
            }
            var newRenderers: [WallpaperRenderer] = []
            do {
                for view in desktopController.contentViews {
                    guard let renderer = RendererFactory.makeRenderer(for: project) else { continue }
                    try renderer.mount(in: view, project: project)
                    newRenderers.append(renderer)
                }
            } catch {
                // 일부만 마운트된 렌더러를 정리해 화면별 비대칭/유령 렌더러를 방지. 기존 배경은 유지.
                newRenderers.forEach { $0.teardown() }
                throw error
            }
            // 전부 성공한 뒤에만 기존 렌더러를 정리하고 교체한다.
            renderers.forEach { $0.teardown() }
            renderers = newRenderers
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
