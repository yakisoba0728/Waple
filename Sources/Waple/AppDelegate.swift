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
    private var currentProjectId: String?
    private weak var videoMenu: NSMenu?

    private let store = LibraryStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private let monitorStore = MonitorAssignmentStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private let playlistStore = PlaylistStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private var playlistTimer: Timer?
    private lazy var libraryVM = LibraryViewModel(store: store, playlist: playlistStore, monitors: monitorStore)
    private var libraryWindow: NSWindow?
    private weak var fitMenu: NSMenu?
    private weak var playlistMenu: NSMenu?

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
        // 동영상 배경별 음량/배속(설계 2026-07-02 video-100). 현재 배경이 동영상이 아니면 no-op.
        let videoItem = NSMenuItem(title: "동영상 설정", action: nil, keyEquivalent: "")
        let videoMenu = NSMenu()
        let muteItem = NSMenuItem(title: "음소거", action: #selector(setVideoVolume(_:)), keyEquivalent: "")
        muteItem.representedObject = Float(0)
        videoMenu.addItem(muteItem)
        for v in [25, 50, 75, 100] {
            let item = NSMenuItem(title: "음량 \(v)%", action: #selector(setVideoVolume(_:)), keyEquivalent: "")
            item.representedObject = Float(v) / 100
            videoMenu.addItem(item)
        }
        videoMenu.addItem(.separator())
        for r in [0.5, 1.0, 1.5, 2.0] {
            let item = NSMenuItem(title: "배속 \(r)x", action: #selector(setVideoRate(_:)), keyEquivalent: "")
            item.representedObject = Float(r)
            videoMenu.addItem(item)
        }
        videoItem.submenu = videoMenu
        menu.addItem(videoItem)
        self.videoMenu = videoMenu
        let plItem = NSMenuItem(title: "재생목록", action: nil, keyEquivalent: "")
        let plMenu = NSMenu()
        let plToggle = NSMenuItem(title: "자동 전환 사용", action: #selector(togglePlaylist), keyEquivalent: "")
        plToggle.state = playlistStore.enabled ? .on : .off
        plMenu.addItem(plToggle)
        for minutes in [5, 15, 30, 60] {
            let it = NSMenuItem(title: "\(minutes)분 간격", action: #selector(setPlaylistInterval(_:)), keyEquivalent: "")
            it.representedObject = minutes
            it.state = playlistStore.intervalMinutes == minutes ? .on : .off
            plMenu.addItem(it)
        }
        let hint = NSMenuItem(title: "항목은 라이브러리 우클릭으로 추가", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        plMenu.addItem(.separator()); plMenu.addItem(hint)
        plItem.submenu = plMenu
        menu.addItem(plItem)
        self.playlistMenu = plMenu
        menu.addItem(NSMenuItem(title: "웹 조작 창 열기",
                                action: #selector(openWebInteraction), keyEquivalent: "i"))
        menu.addItem(NSMenuItem(title: "기본 에셋 폴더 설정…",
                                action: #selector(chooseBaseAssets), keyEquivalent: ""))
        menu.addItem(screenSaverMenuItem())  // 화면보호기 토글(feat/screensaver — 구현은 파일 끝 확장)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Waple",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        self.fitMenu = fitMenu

        libraryVM.onApply = { [weak self] folder in self?.apply(folderURL: folder) ?? false }
        libraryVM.onError = { [weak self] message in self?.notify(message) }
        libraryVM.screensProvider = { [weak self] in
            self?.desktopController.screenViews.enumerated().map { i, sv in
                (key: sv.screenKey, name: NSScreen.screens.indices.contains(i)
                    ? NSScreen.screens[i].localizedName : sv.screenKey)
            } ?? []
        }
        libraryVM.onAssignmentsChanged = { [weak self] in
            guard let self, let folder = self.currentFolderURL else { return }
            self.apply(folderURL: folder)  // 할당 변경 즉시 반영
        }
        libraryVM.onPlaylistChanged = { [weak self] in self?.schedulePlaylistTimer() }
        libraryVM.onOpenInteraction = { [weak self] in self?.openWebInteraction() }
        schedulePlaylistTimer()

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

    /// WE 기본(공유) 에셋 팩 폴더 선택. 일부 씬은 패키지에 없는 공유 텍스처(particle/halo 등)를
    /// 참조하므로, 사용자의 WE assets 폴더를 가리키면 누락 텍스처가 정상 표시된다.
    @objc private func chooseBaseAssets() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        panel.message = "Wallpaper Engine 기본 에셋(assets) 폴더를 선택하세요. 패키지에 없는 공유 텍스처를 여기서 불러옵니다."
        panel.directoryURL = BaseAssetsSettings.baseAssetsDirectory
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        BaseAssetsSettings.baseAssetsDirectory = url
        if let folder = currentFolderURL { apply(folderURL: folder) }  // 누락 텍스처 즉시 반영
    }

    /// 현재 배경(동영상)의 음량/배속 설정 → 저장 + 재적용(기존 fit-mode 패턴). 체크 상태 갱신.
    @objc private func setVideoVolume(_ sender: NSMenuItem) {
        guard let id = currentProjectId, let v = sender.representedObject as? Float else { return }
        VideoSettings.setVolume(v, id: id)
        updateVideoMenuStates()
        if let folder = currentFolderURL { apply(folderURL: folder) }
    }

    @objc private func setVideoRate(_ sender: NSMenuItem) {
        guard let id = currentProjectId, let r = sender.representedObject as? Float else { return }
        VideoSettings.setRate(r, id: id)
        updateVideoMenuStates()
        if let folder = currentFolderURL { apply(folderURL: folder) }
    }

    private func updateVideoMenuStates() {
        guard let id = currentProjectId, let menu = videoMenu else { return }
        let vol = VideoSettings.volume(id: id), rate = VideoSettings.rate(id: id)
        for item in menu.items {
            guard let f = item.representedObject as? Float else { continue }
            if item.action == #selector(setVideoVolume(_:)) { item.state = abs(f - vol) < 0.001 ? .on : .off }
            if item.action == #selector(setVideoRate(_:)) { item.state = abs(f - rate) < 0.001 ? .on : .off }
        }
    }

    /// 현재 적용된 웹 월페이퍼의 조작 창(실입력 프록시 + 라이브 미러)을 연다.
    @objc private func openWebInteraction() {
        if let web = renderers.compactMap({ $0 as? WebRenderer }).first {
            web.openInteractionPanel()
        } else {
            notify("웹 월페이퍼가 적용되어 있지 않습니다 — 웹 배경을 먼저 적용하세요")
        }
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

    /// 라이브러리 엔트리 id → 배경 폴더 URL(없거나 해석 실패 → nil). MonitorMapping 주입용.
    private func folderForEntry(_ id: String) -> URL? {
        guard let entry = store.entries.first(where: { $0.id == id }) else { return nil }
        return store.resolveFolderURL(for: entry)
    }

    @discardableResult
    private func apply(folderURL: URL) -> Bool {
        let project: WallpaperProject
        do {
            project = try ProjectJSONParser.parse(folderURL: folderURL)
        } catch {
            notify("적용 실패: \(error)")
            return false
        }
        guard RendererFactory.makeRenderer(for: project) != nil else {
            notify("지원하지 않는 타입입니다: \(project.type.storageString)")
            return false
        }

        // 화면별로 마운트할 프로젝트 결정(할당 있으면 그 폴더, 없으면 전역; 폴더당 1회 파스) — 추출 로직.
        let screens = desktopController.screenViews
        let projects = MonitorMapping.resolveProjects(
            screenKeys: screens.map { $0.screenKey },
            global: project,
            assignedFolder: { key in
                MonitorMapping.assignedFolder(
                    screenKey: key,
                    assignment: { self.monitorStore.assignment(for: $0) },
                    folderForEntry: { self.folderForEntry($0) })
            },
            parse: { try? ProjectJSONParser.parse(folderURL: $0) }
        )

        // 전부 성공해야 교체, 하나라도 실패하면 부분 정리 후 롤백(기존 렌더러 유지) — 추출 로직.
        let result = RendererSwap.apply(
            screens: Array(zip(screens, projects)),
            existing: renderers,
            makeAndMount: { pair -> WallpaperRenderer? in
                let (screen, proj) = pair
                guard let renderer = RendererFactory.makeRenderer(for: proj) else { return nil }
                try renderer.mount(in: screen.view, project: proj)
                return renderer
            },
            teardown: { $0.teardown() }
        )
        switch result {
        case .success(let newRenderers):
            renderers = newRenderers
            currentFolderURL = folderURL
            currentProjectId = project.id
            updateVideoMenuStates()
            ScreenSaverController.syncVideoPath(for: project)  // 화면보호기 대상 동영상 갱신(feat/screensaver)
            return true
        case .failure(let error):
            notify("적용 실패: \(error)")
            return false
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

    @objc private func togglePlaylist() {
        playlistStore.enabled.toggle()
        playlistMenu?.items.first?.state = playlistStore.enabled ? .on : .off
        schedulePlaylistTimer()
    }

    @objc private func setPlaylistInterval(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? Int else { return }
        playlistStore.intervalMinutes = m
        playlistMenu?.items.forEach { if $0.representedObject != nil { $0.state = (($0.representedObject as? Int) == m) ? .on : .off } }
        schedulePlaylistTimer()
    }

    /// 재생목록 타이머 재구성. 비활성/빈 목록 → 정지(스케줄 조건은 추출 로직).
    private func schedulePlaylistTimer() {
        playlistTimer?.invalidate()
        playlistTimer = nil
        guard PlaylistScheduling.shouldRun(enabled: playlistStore.enabled, ids: playlistStore.ids) else { return }
        let interval = PlaylistScheduling.intervalSeconds(minutes: playlistStore.intervalMinutes)
        playlistTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.advancePlaylist()
        }
    }

    private func advancePlaylist() {
        guard let nextId = PlaylistScheduling.nextApplicableId(
                  after: store.selectedId,
                  next: { self.playlistStore.next(after: $0) },
                  entryExists: { id in self.store.entries.contains(where: { $0.id == id }) }),
              let entry = store.entries.first(where: { $0.id == nextId }) else { return }
        libraryVM.apply(entry)
    }

    private func notify(_ message: String) {
        NSLog("%@", "[Waple] \(message)")
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// MARK: - 화면보호기 (feat/screensaver)
// 다른 브랜치와의 충돌을 최소화하기 위해 본문을 건드리지 않고 확장으로 분리했다.
// 배선: 메뉴 1항목(applicationDidFinishLaunching) + apply 성공 경로 1줄(syncVideoPath).
// ═════════════════════════════════════════════════════════════════════════════
extension AppDelegate {
    /// "화면보호기로 사용" 토글 메뉴 항목. 체크 상태 = 시스템에 Waple 이 선택되어 있는가.
    func screenSaverMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "화면보호기로 사용",
                              action: #selector(toggleScreenSaver(_:)), keyEquivalent: "")
        item.state = ScreenSaverController.isSelected ? .on : .off
        return item
    }

    /// 켜기 = saver 설치 + 시스템 선택 + 현재 동영상 경로 기록 + 설정 패널 열기. 끄기 = 선택 해제.
    @objc func toggleScreenSaver(_ sender: NSMenuItem) {
        if ScreenSaverController.isSelected {
            ScreenSaverController.disable()
            sender.state = .off
            return
        }
        do {
            let project = currentFolderURL.flatMap { try? ProjectJSONParser.parse(folderURL: $0) }
            try ScreenSaverController.enable(currentProject: project)
            sender.state = .on
            ScreenSaverController.openSettings()  // 사용자가 바로 확인할 수 있게 잠금 화면 패널 열기
        } catch {
            notify("화면보호기 설치 실패: \(error.localizedDescription)")
        }
    }
}
