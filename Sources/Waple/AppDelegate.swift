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
    private weak var fitMenu: NSMenu?
    private weak var playlistMenu: NSMenu?

    // 데스크탑 가림 자동 일시정지(옵션, UserDefaults 영속, 기본 꺼짐 — 기존 동작 보존).
    private let visibilityMonitor = DesktopVisibilityMonitor()
    private var occlusionTimer: Timer?
    private var pausedByOcclusion = false   // 이 모니터가 정지시켰는지(수동 정지와 사유 분리)
    private weak var occlusionMenu: NSMenu?

    // 정적 배경 동기화(작업 1): 적용 성공 후 스틸 생성/설정을 지연·디바운스하는 작업 핸들.
    private var stillSyncWork: DispatchWorkItem?

    // 최근 배경 서브메뉴(작업 6): 열 때마다 최신 목록으로 다시 채운다(NSMenuDelegate).
    private weak var recentMenu: NSMenu?

    private static let pauseWhenOccludedKey = "pauseWhenOccluded"
    private var pauseWhenOccluded: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pauseWhenOccludedKey) }   // 기본 false
        set { UserDefaults.standard.set(newValue, forKey: Self.pauseWhenOccludedKey) }
    }

    // 가림 커버 임계값(작업 3): 0=기존(창 존재 시 즉시), 0.3/0.5/0.8=합집합 커버 비율. 기본 0.
    private static let occlusionThresholdKey = "occlusionCoverageThreshold"
    private var occlusionCoverageThreshold: Double {
        get { UserDefaults.standard.double(forKey: Self.occlusionThresholdKey) }   // 기본 0
        set { UserDefaults.standard.set(newValue, forKey: Self.occlusionThresholdKey) }
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
        menu.addItem(recentMenuItem())  // 최근 배경 서브메뉴(작업 6 — 구현은 확장)
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
        // 데스크탑이 다른 창에 가려지면 렌더러 일시정지(옵션, 기본 꺼짐). 서브메뉴로 커버 임계값 선택(작업 3).
        let occItem = NSMenuItem(title: "가려지면 일시정지", action: nil, keyEquivalent: "")
        occItem.submenu = makeOcclusionMenu()
        menu.addItem(occItem)
        menu.addItem(NSMenuItem(title: "웹 조작 창 열기",
                                action: #selector(openWebInteraction), keyEquivalent: "i"))
        menu.addItem(NSMenuItem(title: "정지 배경으로 설정",
                                action: #selector(setStillWallpaper), keyEquivalent: ""))
        menu.addItem(desktopStillSyncMenuItem())  // 정적 배경 동기화 토글(작업 1 — 구현은 확장)
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
            scheduleDesktopStillSync()  // 정적 배경 동기화(옵션, 기본 꺼짐 — 내부에서 가드)
            pushRecent(project?.id)     // 최근 배경 목록 갱신(nil = 무선택 → no-op)
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

    /// 커버 임계값 라디오 서브메뉴. represented 값: -1=사용안함, 0=기존(즉시), 0.3/0.5/0.8=비율.
    private func makeOcclusionMenu() -> NSMenu {
        let m = NSMenu()
        let options: [(String, Double)] = [
            ("사용 안 함", -1),
            ("창이 뜨면 즉시(기존)", 0),
            ("30% 이상 가려지면", 0.30),
            ("50% 이상 가려지면", 0.50),
            ("80% 이상 가려지면", 0.80),
        ]
        for (title, mode) in options {
            let it = NSMenuItem(title: title, action: #selector(setOcclusionMode(_:)), keyEquivalent: "")
            it.representedObject = mode
            m.addItem(it)
        }
        occlusionMenu = m
        updateOcclusionMenuStates()
        return m
    }

    private func updateOcclusionMenuStates() {
        occlusionMenu?.items.forEach {
            guard let mode = $0.representedObject as? Double else { return }
            $0.state = OcclusionMode.isSelected(mode, enabled: pauseWhenOccluded,
                                                threshold: occlusionCoverageThreshold) ? .on : .off
        }
    }

    @objc private func setOcclusionMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? Double else { return }
        let (enabled, threshold) = OcclusionMode.decode(mode)
        pauseWhenOccluded = enabled
        occlusionCoverageThreshold = threshold
        updateOcclusionMenuStates()
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
        let visible = visibilityMonitor.isDesktopVisible(threshold: occlusionCoverageThreshold)
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

    /// 현재 배경에서 정지 이미지를 만들어 전 스크린 데스크탑 배경으로 지정(수동 1회).
    /// 배경 창은 아이콘 레벨 아래라, 라이브 창이 떠 있는 동안 정지 배경은 그 뒤의 폴백 레이어다.
    /// 원본 보존/복원은 자동 동기화(작업 1) 전용 — 수동 설정은 사용자의 명시적 1회 액션이라 백업 없음.
    @objc private func setStillWallpaper() {
        guard currentFolderURL != nil else { notify("적용된 배경이 없습니다"); return }
        guard let image = generateStillImage() else {
            notify("정지 배경을 만들 수 없습니다"); return
        }
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(image, for: screen, options: [:])
        }
        notify("정지 배경으로 설정했습니다")
    }

    /// still 산출 디렉터리(라이브러리 베이스/still).
    private func stillDirectory() -> URL {
        LibraryStore.defaultBaseDirectory().appendingPathComponent("still", isDirectory: true)
    }

    /// 현재 배경 → 정지 이미지 파일(공통). 소스 없음/추출 실패 → nil. (수동 설정·자동 동기화 공유)
    private func generateStillImage() -> URL? {
        guard let folder = currentFolderURL,
              let project = projectForMount(folderURL: folder),
              let source = StillWallpaper.source(for: project) else { return nil }
        let stillDir = stillDirectory()
        try? FileManager.default.createDirectory(at: stillDir, withIntermediateDirectories: true)
        let output = StillWallpaper.outputURL(projectId: project.id, stillDir: stillDir)
        switch source {
        case .videoFrame(let videoURL): return extractVideoFrame(from: videoURL, to: output)
        case .sceneCapture:             return captureSceneStill(to: stillDir)
        case .previewImage(let url):    return url   // preview 파일 그대로 사용
        }
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
// MARK: - 정적 배경 동기화 + 잠금화면 스틸 (작업 1·2)
// 배경 적용 성공 시 현재 배경의 정지 이미지를 실제 macOS 바탕화면에 자동 설정한다.
// 목적: 메뉴바/Dock 틴트 매칭, Mission Control 축소뷰, 스크린샷/화면공유, 앱 미실행 폴백.
// 기본 꺼짐 — 사용자 바탕화면을 말없이 바꾸는 건 침습적이라 옵트인.
// 배선: 메뉴 1항목 + apply 성공 경로 1줄(scheduleDesktopStillSync) + applicationWillTerminate.
// ═════════════════════════════════════════════════════════════════════════════
extension AppDelegate {
    private static var desktopStillSyncKey: String { "desktopStillSync" }
    private static var desktopOriginalsKey: String { "waple.desktopSync.originals" }

    /// 동기화 사용 여부(UserDefaults 영속, 기본 false).
    var desktopStillSync: Bool {
        get { UserDefaults.standard.bool(forKey: Self.desktopStillSyncKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.desktopStillSyncKey) }
    }

    /// 화면키 → 최초 덮어쓰기 직전 원본 바탕화면 경로(UserDefaults 영속).
    /// 인메모리가 아니라 영속시켜 terminate 없이 크래시해도 복원 가능하게 한다.
    private var desktopOriginals: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.desktopOriginalsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.desktopOriginalsKey) }
    }

    func desktopStillSyncMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "정적 배경 동기화",
                              action: #selector(toggleDesktopStillSync(_:)), keyEquivalent: "")
        item.state = desktopStillSync ? .on : .off
        return item
    }

    @objc func toggleDesktopStillSync(_ sender: NSMenuItem) {
        desktopStillSync.toggle()
        sender.state = desktopStillSync ? .on : .off
        if desktopStillSync {
            scheduleDesktopStillSync()      // 켜면 현재 배경을 즉시(지연 후) 동기화
        } else {
            stillSyncWork?.cancel()
            restoreDesktopOriginals()       // 끄면 원본 복원
        }
    }

    /// 적용 성공 후 스틸 생성/설정 예약. 첫 프레임 안정화를 위해 수 초 지연 + 디바운스
    /// (연속 재적용 — fit/속성/화면변경 — 은 취소·재예약으로 흡수). 꺼져 있으면 no-op.
    func scheduleDesktopStillSync() {
        stillSyncWork?.cancel()
        guard desktopStillSync else { return }
        let work = DispatchWorkItem { [weak self] in self?.syncDesktopStill() }
        stillSyncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// 현재 배경 스틸을 전 스크린 바탕화면으로 설정. 최초 덮어쓰기 직전 원본을 화면별로 백업(가드).
    /// 실패는 조용히 — 이 기능은 폴백일 뿐이다.
    private func syncDesktopStill() {
        guard desktopStillSync, let image = generateStillImage() else { return }
        var originals = desktopOriginals
        let stillPath = stillDirectory().path
        for screen in NSScreen.screens {
            let key = DesktopWindow.screenKey(for: screen)
            let current = NSWorkspace.shared.desktopImageURL(for: screen)?.path
            if StillDesktopSync.shouldBackupOriginal(
                currentPath: current, stillDirPath: stillPath, hasBackup: originals[key] != nil) {
                originals[key] = current
            }
            try? NSWorkspace.shared.setDesktopImageURL(image, for: screen, options: [:])
        }
        desktopOriginals = originals
        writeLockscreenStill(image)  // 작업 2: 잠금화면 스틸 갱신(graceful)
    }

    // MARK: - 잠금화면 스틸 (작업 2)

    /// dscl 로 현재 사용자 GeneratedUID 조회(잠금화면 스틸 경로 키). 실행 실패 → nil.
    private func currentUserGeneratedUID() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = [".", "-read", "/Users/\(NSUserName())", "GeneratedUID"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GeneratedUID.parse(dsclOutput: String(decoding: data, as: UTF8.self))
    }

    /// 잠금화면 스틸을 /Library/Caches/Desktop Pictures/<UID>/lockscreen.png 에 PNG 로 기록.
    /// 디렉터리 부재(신규 macOS 등)/권한 실패는 조용히 스킵(graceful) — 폴백 기능일 뿐.
    /// ⚠️ macOS 26+ 는 비공개 WallpaperExtensionKit 확장으로 잠금화면을 관리 — 범위 외(별도 SP).
    private func writeLockscreenStill(_ image: URL) {
        guard let uid = currentUserGeneratedUID() else { return }
        let dir = URL(fileURLWithPath: "/Library/Caches/Desktop Pictures/\(uid)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }  // 디렉터리 부재 → 스킵
        // 원본이 PNG 가 아닐 수 있어(preview.jpg 등) PNG 로 재인코딩.
        guard let nsImage = NSImage(contentsOf: image),
              let tiff = nsImage.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: dir.appendingPathComponent("lockscreen.png"), options: .atomic)
        } catch {
            notify("잠금화면 스틸 기록 실패(무시): \(error.localizedDescription)")
        }
    }

    /// 백업된 원본 바탕화면 복원(파일이 아직 존재하는 화면만). 복원 후 백업 비움.
    func restoreDesktopOriginals() {
        let originals = desktopOriginals
        guard !originals.isEmpty else { return }
        for screen in NSScreen.screens {
            guard let path = originals[DesktopWindow.screenKey(for: screen)],
                  FileManager.default.fileExists(atPath: path) else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
        }
        desktopOriginals = [:]
    }

    /// 종료 시 원본 복원(force-quit 엔 호출 안 됨 — 토글 오프도 복원 경로라 최선 노력으로 충분).
    public func applicationWillTerminate(_ notification: Notification) {
        restoreDesktopOriginals()
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// MARK: - 최근 배경 (작업 6)
// 적용 성공 시 id 를 최근 목록(최대 10)에 push. 상태바 서브메뉴에서 제목을 보여주고
// 클릭 시 기존 적용 경로를 재사용한다. 라이브러리에서 삭제된 id 는 열 때 자동 제외.
// ═════════════════════════════════════════════════════════════════════════════
extension AppDelegate: NSMenuDelegate {
    private static var recentIdsKey: String { "waple.recentWallpaperIds" }
    private var recentWallpaperIds: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.recentIdsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.recentIdsKey) }
    }

    /// 적용 성공 id 를 최근 목록에 반영(중복 제거·선두·최대 10). nil → no-op.
    func pushRecent(_ id: String?) {
        guard let id else { return }
        recentWallpaperIds = RecentWallpapers.push(id, into: recentWallpaperIds)
    }

    func recentMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "최근 배경", action: nil, keyEquivalent: "")
        let m = NSMenu()
        m.delegate = self          // 열 때마다 menuNeedsUpdate 로 최신화
        item.submenu = m
        recentMenu = m
        return item
    }

    /// 서브메뉴를 열 때 최신 목록으로 다시 채운다(그 사이 삭제된 id 는 제외).
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let entries = recentWallpaperIds.compactMap { id in store.entries.first(where: { $0.id == id }) }
        guard !entries.isEmpty else {
            let empty = NSMenuItem(title: "(없음)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for entry in entries {
            let it = NSMenuItem(title: entry.title, action: #selector(applyRecent(_:)), keyEquivalent: "")
            it.representedObject = entry.id
            menu.addItem(it)
        }
    }

    @objc func applyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = store.entries.first(where: { $0.id == id }) else { return }
        _ = libraryVM.apply(entry)   // 기존 적용 경로 재사용(선택 영속·강조 포함)
    }
}
