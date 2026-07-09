import AppKit
import AVFoundation
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
    private var activeVideoProjectIds: [String] = []
    private weak var videoMenu: NSMenu?

    private let store = LibraryStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private let monitorStore = MonitorAssignmentStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private let playlistStore = PlaylistStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private var playlistTimer: Timer?
    private lazy var libraryVM = LibraryViewModel(store: store, playlist: playlistStore, monitors: monitorStore)
    private var libraryWindow: NSWindow?
    private var workshopWindow: NSWindow?   // 워크샵 창(강한 참조 — isReleasedWhenClosed=false 로 재오픈 안전)
    private weak var fitMenu: NSMenu?
    private weak var playlistMenu: NSMenu?

    // 데스크탑 가림 자동 일시정지(옵션, UserDefaults 영속, 기본 꺼짐 — 기존 동작 보존).
    private let visibilityMonitor = DesktopVisibilityMonitor()
    private var occlusionTimer: Timer?
    private var pausedByOcclusion = false   // 이 모니터가 정지시켰는지(수동 정지와 사유 분리)
    private weak var occlusionToggleItem: NSMenuItem?

    private static let pauseWhenOccludedKey = "pauseWhenOccluded"
    private var pauseWhenOccluded: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pauseWhenOccludedKey) }   // 기본 false
        set { UserDefaults.standard.set(newValue, forKey: Self.pauseWhenOccludedKey) }
    }

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
        menu.addItem(NSMenuItem(title: "워크샵 열기",
                                action: #selector(openWorkshop), keyEquivalent: "w"))
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
        // 데스크탑이 다른 창에 가려지면 렌더러 일시정지(옵션, 기본 꺼짐).
        let occItem = NSMenuItem(title: "가려지면 일시정지",
                                 action: #selector(toggleOcclusionPause), keyEquivalent: "")
        occItem.state = pauseWhenOccluded ? .on : .off
        menu.addItem(occItem)
        self.occlusionToggleItem = occItem
        menu.addItem(NSMenuItem(title: "웹 조작 창 열기",
                                action: #selector(openWebInteraction), keyEquivalent: "i"))
        menu.addItem(NSMenuItem(title: "정지 배경으로 설정",
                                action: #selector(setStillWallpaper), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "기본 에셋 폴더 설정…",
                                action: #selector(chooseBaseAssets), keyEquivalent: ""))
        menu.addItem(screenSaverMenuItem())  // 화면보호기 토글(feat/screensaver — 구현은 파일 끝 확장)
        // 로그인 시 자동 시작(등록 실패는 조용히 — 체크는 실제 status 반영).
        let loginItem = NSMenuItem(title: "로그인 시 시작",
                                   action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginItem.state = LoginItemController.isEnabled ? .on : .off
        menu.addItem(loginItem)
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
            guard let self else { return }
            _ = self.applyCurrentSelection()  // 할당 변경 즉시 반영
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

        // 가림 자동 일시정지 폴링 시작(꺼져 있으면 no-op).
        scheduleOcclusionTimer()
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
        guard let v = sender.representedObject as? Float else { return }
        let ids = VideoSettingsTarget.projectIds(currentProjectId: currentProjectId,
                                                 activeVideoProjectIds: activeVideoProjectIds)
        guard !ids.isEmpty else { return }
        ids.forEach { VideoSettings.setVolume(v, id: $0) }
        updateVideoMenuStates()
        _ = applyCurrentSelection()
    }

    @objc private func setVideoRate(_ sender: NSMenuItem) {
        guard let r = sender.representedObject as? Float else { return }
        let ids = VideoSettingsTarget.projectIds(currentProjectId: currentProjectId,
                                                 activeVideoProjectIds: activeVideoProjectIds)
        guard !ids.isEmpty else { return }
        ids.forEach { VideoSettings.setRate(r, id: $0) }
        updateVideoMenuStates()
        _ = applyCurrentSelection()
    }

    private func updateVideoMenuStates() {
        guard let menu = videoMenu else { return }
        let ids = VideoSettingsTarget.projectIds(
            currentProjectId: currentProjectId,
            activeVideoProjectIds: activeVideoProjectIds
        )
        guard let id = ids.first else {
            menu.items.forEach { $0.state = .off }
            return
        }
        let vol = VideoSettings.volume(id: id), rate = VideoSettings.rate(id: id)
        let sameVolume = ids.allSatisfy { abs(VideoSettings.volume(id: $0) - vol) < 0.001 }
        let sameRate = ids.allSatisfy { abs(VideoSettings.rate(id: $0) - rate) < 0.001 }
        for item in menu.items {
            guard let f = item.representedObject as? Float else { continue }
            if item.action == #selector(setVideoVolume(_:)) {
                item.state = sameVolume && abs(f - vol) < 0.001 ? .on : .off
            }
            if item.action == #selector(setVideoRate(_:)) {
                item.state = sameRate && abs(f - rate) < 0.001 ? .on : .off
            }
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

    private func projectForMount(folderURL: URL) -> WallpaperProject? {
        guard let project = try? ProjectJSONParser.parse(folderURL: folderURL) else { return nil }
        return PresetResolver.resolve(
            project: project,
            originalFolder: folderURL,
            dependencyFolder: { self.folderForEntry($0) },
            parse: { try? ProjectJSONParser.parse(folderURL: $0) }
        )
    }

    @discardableResult
    private func apply(folderURL: URL) -> Bool {
        guard let project = projectForMount(folderURL: folderURL) else {
            notify("적용 실패: project.json 또는 preset dependency 를 해석할 수 없습니다")
            return false
        }
        guard RendererFactory.makeRenderer(for: project) != nil else {
            notify("지원하지 않는 타입입니다: \(project.type.storageString)")
            return false
        }
        return applyResolved(global: project, folderURL: folderURL)
    }

    @discardableResult
    private func applyCurrentSelection() -> Bool {
        if let folder = currentFolderURL {
            return apply(folderURL: folder)
        }
        return applyResolved(global: nil, folderURL: nil)
    }

    @discardableResult
    private func applyResolved(global project: WallpaperProject?, folderURL: URL?) -> Bool {
        // 화면별로 마운트할 프로젝트 결정(할당 있으면 그 폴더, 없으면 전역; 폴더당 1회 파스) — 추출 로직.
        let screens = desktopController.screenViews
        let projectSlots = MonitorMapping.resolveProjectSlots(
            screenKeys: screens.map { $0.screenKey },
            global: project,
            assignedFolder: { key in
                MonitorMapping.assignedFolder(
                    screenKey: key,
                    assignment: { self.monitorStore.assignment(for: $0) },
                    folderForEntry: { self.folderForEntry($0) })
            },
            parse: { self.projectForMount(folderURL: $0) }
        )
        let screenProjects = Array(zip(screens, projectSlots)).compactMap { screen, project -> (screenKey: String, view: NSView, project: WallpaperProject)? in
            guard let project else { return nil }
            return (screen.screenKey, screen.view, project)
        }

        // 전부 성공해야 교체, 하나라도 실패하면 부분 정리 후 롤백(기존 렌더러 유지) — 추출 로직.
        let result = RendererSwap.apply(
            screens: screenProjects,
            existing: renderers,
            makeAndMount: { pair -> WallpaperRenderer? in
                guard let renderer = RendererFactory.makeRenderer(for: pair.project) else { return nil }
                try renderer.mount(in: pair.view, project: pair.project)
                return renderer
            },
            teardown: { $0.teardown() }
        )
        switch result {
        case .success(let newRenderers):
            renderers = newRenderers
            currentFolderURL = folderURL
            currentProjectId = project?.id
            activeVideoProjectIds = screenProjects
                .filter { $0.project.type == .video }
                .map { $0.project.id }
            updateVideoMenuStates()
            if let project {
                ScreenSaverController.syncVideoPath(for: project)  // 화면보호기 대상 동영상 갱신(feat/screensaver)
            }
            if pausedByOcclusion { renderers.forEach { $0.pause() } }  // 가림 정지 중 교체된 렌더러도 정지 유지
            return true
        case .failure(let error):
            notify("적용 실패: \(error)")
            return false
        }
    }

    private func restoreLastWallpaper() {
        guard let id = store.selectedId,
              let entry = store.entries.first(where: { $0.id == id }),
              let folder = store.resolveFolderURL(for: entry) else {
            _ = applyCurrentSelection()
            return
        }
        apply(folderURL: folder)
    }

    @objc private func screensChanged() {
        ScreenChangeLifecycle.detachRenderersBeforeRebuild(
            existing: &renderers,
            teardown: { $0.teardown() }
        )
        activeVideoProjectIds = []
        desktopController.rebuild()
        _ = applyCurrentSelection()
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
        // 후보를 순서대로 시도하고 실제 적용에 성공하는 첫 배경으로 전진(삭제/폴더 이동 등 실패 후보는 건너뜀).
        _ = PlaylistScheduling.advance(
            from: store.selectedId,
            count: playlistStore.ids.count,
            next: { self.playlistStore.next(after: $0) },
            apply: { id in
                guard let entry = self.store.entries.first(where: { $0.id == id }) else { return false }
                return self.libraryVM.apply(entry)
            })
    }

    // MARK: - 데스크탑 가림 자동 일시정지 (작업 2)

    @objc private func toggleOcclusionPause() {
        pauseWhenOccluded.toggle()
        occlusionToggleItem?.state = pauseWhenOccluded ? .on : .off
        scheduleOcclusionTimer()
    }

    /// 폴링 타이머 재구성. 켜짐 → 1초 폴링(.common 모드). 꺼짐 → 정지하고, 가림 정지 중이었으면 해제.
    private func scheduleOcclusionTimer() {
        occlusionTimer?.invalidate()
        occlusionTimer = nil
        guard pauseWhenOccluded else {
            if pausedByOcclusion { resumeFromOcclusion() }  // 끄면 정지 상태를 남기지 않는다
            return
        }
        // .common 모드 — 메뉴 트래킹 중에도 폴링(scheduledTimer 는 .default 만 등록).
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkOcclusion() }
        RunLoop.main.add(timer, forMode: .common)
        occlusionTimer = timer
    }

    private func checkOcclusion() {
        let visible = visibilityMonitor.isDesktopVisible()
        if !visible, !pausedByOcclusion {
            renderers.forEach { $0.pause() }
            pausedByOcclusion = true
        } else if visible, pausedByOcclusion {
            resumeFromOcclusion()
        }
    }

    private func resumeFromOcclusion() {
        renderers.forEach { $0.resume() }
        pausedByOcclusion = false
    }

    // MARK: - 정지 배경으로 설정 (작업 3)

    /// 현재 배경에서 정지 이미지를 만들어 전 스크린 데스크탑 배경으로 지정.
    /// 배경 창은 아이콘 레벨 아래라, 라이브 창이 떠 있는 동안 정지 배경은 그 뒤의 폴백 레이어다.
    @objc private func setStillWallpaper() {
        guard let folder = currentFolderURL,
              let project = projectForMount(folderURL: folder) else {
            notify("적용된 배경이 없습니다"); return
        }
        guard let source = StillWallpaper.source(for: project) else {
            notify("정지 배경을 만들 수 없습니다 — preview 이미지가 없습니다"); return
        }
        let stillDir = LibraryStore.defaultBaseDirectory().appendingPathComponent("still", isDirectory: true)
        try? FileManager.default.createDirectory(at: stillDir, withIntermediateDirectories: true)
        let output = StillWallpaper.outputURL(projectId: project.id, stillDir: stillDir)

        let imageURL: URL?
        switch source {
        case .videoFrame(let videoURL): imageURL = extractVideoFrame(from: videoURL, to: output)
        case .sceneCapture:             imageURL = captureSceneStill(to: stillDir)
        case .previewImage(let url):    imageURL = url   // preview 파일 그대로 사용
        }
        guard let image = imageURL else { notify("정지 배경 추출에 실패했습니다"); return }
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(image, for: screen, options: [:])
        }
        notify("정지 배경으로 설정했습니다")
    }

    /// 동영상 t=1s 프레임 → PNG(실패 시 t=0 폴백). 실패 → nil.
    private func extractVideoFrame(from videoURL: URL, to output: URL) -> URL? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        let cg: CGImage
        do {
            cg = try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
        } catch {
            guard let zero = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
            cg = zero
        }
        guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]),
              (try? data.write(to: output, options: .atomic)) != nil else { return nil }
        return output
    }

    /// 활성 씬 렌더러로 1프레임(t=1s) 캡처. 씬이 없으면 nil.
    private func captureSceneStill(to dir: URL) -> URL? {
        guard let scene = renderers.compactMap({ $0 as? SceneRenderer }).first else { return nil }
        let size = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return scene.captureFrames(width: Int(size.width * scale), height: Int(size.height * scale),
                                   times: [1.0], toDir: dir).first
    }

    // MARK: - 로그인 시 시작 (작업 4)

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            try LoginItemController.setEnabled(!LoginItemController.isEnabled)
        } catch {
            // SPM 단독 실행 파일은 등록 실패 가능 — 알럿 없이 로깅만, 체크는 실제 status 로 재조회.
            notify("로그인 항목 설정 실패: \(error.localizedDescription)")
        }
        sender.state = LoginItemController.isEnabled ? .on : .off
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
            let project = currentFolderURL.flatMap { projectForMount(folderURL: $0) }
            try ScreenSaverController.enable(currentProject: project)
            sender.state = .on
            ScreenSaverController.openSettings()  // 사용자가 바로 확인할 수 있게 잠금 화면 패널 열기
        } catch {
            notify("화면보호기 설치 실패: \(error.localizedDescription)")
        }
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// MARK: - 워크샵 (feat/workshop)
// 다른 브랜치와의 충돌을 최소화하기 위해 확장으로 분리(본문은 메뉴 1항목 + 창 프로퍼티 1개만 추가).
// ═════════════════════════════════════════════════════════════════════════════
extension AppDelegate {
    /// 워크샵 창을 연다. libraryWindow 와 동일한 수명 규약(isReleasedWhenClosed=false + 강한 프로퍼티)으로
    /// 재오픈 시 use-after-free 를 막는다. 다운로드→임포트→적용은 기존 libraryVM(importDownloaded/apply) 재사용.
    @objc func openWorkshop() {
        if workshopWindow == nil {
            let hosting = NSHostingController(rootView: WorkshopView(library: libraryVM))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Waple 워크샵"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 560))
            window.isReleasedWhenClosed = false
            workshopWindow = window
        }
        workshopWindow?.center()
        workshopWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
