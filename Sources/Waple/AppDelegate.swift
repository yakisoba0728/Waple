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

    private let store = LibraryStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private let monitorStore = MonitorAssignmentStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private let playlistStore = PlaylistStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private let favoritesStore = FavoritesStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private let folderStore = FolderStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private var playlistTimer: Timer?
    private lazy var libraryVM = LibraryViewModel(store: store, playlist: playlistStore, monitors: monitorStore,
                                                  favorites: favoritesStore, folders: folderStore)
    private lazy var settingsVM: SettingsViewModel = {
        let vm = SettingsViewModel(playlist: playlistStore)
        vm.onApplySelection = { [weak self] in _ = self?.applyCurrentSelection() }
        vm.onSetOcclusion = { [weak self] raw in self?.setOcclusionMode(raw: raw) }
        vm.onSetStillSync = { [weak self] on in self?.setDesktopStillSync(on) }
        vm.onPlaylistChanged = { [weak self] in self?.schedulePlaylistTimer() }
        vm.onChooseBaseAssets = { [weak self] in self?.chooseBaseAssets() }
        vm.onSetStillWallpaper = { [weak self] in self?.setStillWallpaper() }
        vm.onToggleSaver = { [weak self] in self?.toggleScreenSaverCore() ?? false }
        vm.videoTargetIds = { [weak self] in
            guard let self else { return [] }
            return VideoSettingsTarget.projectIds(currentProjectId: self.currentProjectId,
                                                  activeVideoProjectIds: self.activeVideoProjectIds)
        }
        vm.occlusionState = { [weak self] in
            guard let self else { return (false, 0) }
            return (self.pauseWhenOccluded, self.occlusionCoverageThreshold)
        }
        vm.stillSyncEnabled = { [weak self] in self?.desktopStillSync ?? false }
        return vm
    }()
    private let bannerModel = StatusBannerModel()
    private let onboardingModel = OnboardingModel()
    private var baseAssetsWarningGate = BaseAssetsWarningGate()
    private var libraryWindow: NSWindow?

    // 최초 실행 온보딩(앱셸 스코프 B): 완료 플래그(UserDefaults 영속). 첫 실행에만 안내 시트 1회.
    private static let onboardingCompletedKey = "waple.onboardingCompleted"
    private var onboardingCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.onboardingCompletedKey) }
    }

    // 데스크탑 가림 자동 일시정지(옵션, UserDefaults 영속, 기본 꺼짐 — 기존 동작 보존).
    private let visibilityMonitor = DesktopVisibilityMonitor()
    private var occlusionTimer: Timer?
    // 렌더 정지 사유(가림·수동·슬립)를 한 곳에서 합성 — 서로 덮어쓰지 않게. 합성 로직은 PauseGate(순수).
    private var pauseGate = PauseGate()

    // 정적 배경 동기화(작업 1): 적용 성공 후 스틸 생성/설정을 지연·디바운스하는 작업 핸들.
    private var stillSyncWork: DispatchWorkItem?

    // 최근 배경 서브메뉴(작업 6): 열 때마다 최신 목록으로 다시 채운다(NSMenuDelegate).
    private weak var recentMenu: NSMenu?

    // 설정 창 + 축소된 트레이(SP5′): 설정 창 강한 참조·일시정지 항목·상태바 메뉴 참조.
    private var settingsWindow: NSWindow?
    private weak var pauseMenuItem: NSMenuItem?
    private weak var statusMenu: NSMenu?

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 상태바 아이콘 — 시스템 심볼 템플릿(라이트/다크 메뉴바 자동 적응). 심볼 부재 시 이모지 폴백.
        if let symbol = NSImage(systemSymbolName: "water.waves", accessibilityDescription: "Waple") {
            symbol.isTemplate = true
            statusItem.button?.image = symbol
        } else {
            statusItem.button?.title = "🖼"
        }

        // 트레이 축소(SP5′): 설정은 전부 설정 창으로 — 창 없이 필요한 동작만 남긴다.
        let menu = NSMenu()
        menu.delegate = self   // 열 때마다 일시정지 항목 제목 최신화(menuNeedsUpdate)
        menu.addItem(NSMenuItem(title: "Waple 열기",
                                action: #selector(openLibrary), keyEquivalent: "l"))
        menu.addItem(recentMenuItem())  // 최근 배경 서브메뉴(작업 6 — 구현은 확장)
        let pause = NSMenuItem(title: "일시정지",
                               action: #selector(togglePauseFromMenu), keyEquivalent: "p")
        menu.addItem(pause)
        pauseMenuItem = pause
        menu.addItem(NSMenuItem(title: "설정…",
                                action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Waple",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusMenu = menu

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
        libraryVM.onOpenSettings = { [weak self] in self?.openSettings() }
        libraryVM.onAdvancePlaylist = { [weak self] in self?.advancePlaylist() }
        libraryVM.onTogglePause = { [weak self] in self?.toggleGlobalPause() ?? false }
        schedulePlaylistTimer()

        desktopController.rebuild()

        // 화면 구성 변경(모니터 연결/해제/해상도) 시 창 재구성 후 재적용.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // 시스템/디스플레이 슬립 중 렌더 정지, 웨이크 시 재개(수동·가림 사유가 남아 있으면 유지).
        // NSWorkspace 알림은 default 센터가 아니라 workspace 전용 센터로 온다.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceCenter.addObserver(self, selector: #selector(sleepBegan), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceCenter.addObserver(self, selector: #selector(sleepEnded), name: name, object: nil)
        }

        // 마지막 선택 배경 복원.
        restoreLastWallpaper()

        // 가림 자동 일시정지 폴링 시작(꺼져 있으면 no-op).
        scheduleOcclusionTimer()

        // 스모크 확인용: 실행 시 메인창 자동 오픈 + 첫 항목 포커스(상세 패널이 채워진 상태로
        // 캡처되도록 — 판정 게이트용). WAPLE_SMOKE=1 아닐 땐 no-op.
        if ProcessInfo.processInfo.environment["WAPLE_SMOKE"] != nil {
            DispatchQueue.main.async { [weak self] in
                self?.openLibrary()
                self?.libraryVM.focusedId = self?.libraryVM.entries.first?.id
            }
        }

        // 설정 창 캡처용(판정 게이트): WAPLE_SMOKE_SETTINGS=1 이면 설정 창 자동 오픈.
        if ProcessInfo.processInfo.environment["WAPLE_SMOKE_SETTINGS"] != nil {
            DispatchQueue.main.async { [weak self] in self?.openSettings() }
        }

        // 최초 실행 온보딩(앱셸 스코프 B). 항목 상태는 기존 감지에서, "해결"은 기존 배관을 재사용.
        onboardingModel.readiness = { [weak self] in
            (content: !(self?.store.entries.isEmpty ?? true),
             baseAssets: BaseAssetsSettings.baseAssetsDirectory != nil,
             ffmpeg: FFmpegConverter.isAvailable)
        }
        onboardingModel.onChooseBaseAssets = { [weak self] in self?.chooseBaseAssets() }
        onboardingModel.onOpenSettings = { [weak self] in self?.openSettings() }
        maybePresentOnboarding()
    }

    /// 첫 실행이면 라이브러리 창 + 안내 시트를 1회 띄운다. 스모크 캡처와 분리:
    /// WAPLE_SMOKE_ONBOARDING 은 (플래그 무관) 강제 표시, 그 외 WAPLE_SMOKE* 는 억제(기존 4종 무회귀).
    private func maybePresentOnboarding() {
        let env = ProcessInfo.processInfo.environment
        if env["WAPLE_SMOKE_ONBOARDING"] != nil {
            DispatchQueue.main.async { [weak self] in self?.openLibrary(); self?.onboardingModel.present() }
            return
        }
        guard Onboarding.shouldPresent(completed: onboardingCompleted),
              !env.keys.contains(where: { $0.hasPrefix("WAPLE_SMOKE") }) else { return }
        onboardingCompleted = true   // 표시 시점에 확정 — 1회 보장(재표시 안 함)
        DispatchQueue.main.async { [weak self] in self?.openLibrary(); self?.onboardingModel.present() }
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
        _ = applyCurrentSelection()  // 누락 텍스처 즉시 반영(할당-전용 표시 중에도 — P-B4)
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
            let root = MainWindowView(viewModel: libraryVM, banner: bannerModel,
                                      onboarding: onboardingModel,
                                      screenFrames: { NSScreen.screens.map(\.frame) })
            let hosting = NSHostingController(rootView: root)
            // SwiftUI .toolbar → NSToolbar 브리징(macOS 14+ 전용 — 그래서 배포 타깃도 14).
            hosting.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Waple"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.toolbarStyle = .unified
            window.setContentSize(Metrics.windowDefault)
            window.minSize = Metrics.windowMin
            window.appearance = NSAppearance(named: .darkAqua)   // WE 관례 — 항상 다크
            // 프로그램 생성 NSWindow 는 닫힐 때 기본적으로 release 되어, 강한 참조 프로퍼티가
            // 댕글링되고 재오픈 시 use-after-free 가 된다. 프로퍼티가 수명을 관리하도록 막는다.
            window.isReleasedWhenClosed = false
            libraryWindow = window
        }
        libraryWindow?.center()
        libraryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 설정 창(SP5′) — openLibrary 와 같은 수명 규약: darkAqua·isReleasedWhenClosed=false·강한 참조.
    @objc func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(vm: settingsVM))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Waple 설정"
            window.styleMask = [.titled, .closable]
            window.setContentSize(Metrics.settingsSize)
            window.appearance = NSAppearance(named: .darkAqua)   // WE 관례 — 항상 다크
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsVM.refresh()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
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
            if let project {
                ScreenSaverController.syncVideoPath(for: project)  // 화면보호기 대상 동영상 갱신(feat/screensaver)
            }
            if pauseGate.isPaused { renderers.forEach { $0.pause() } }  // 어떤 사유든 정지 중 교체된 렌더러도 정지 유지
            scheduleDesktopStillSync()  // 정적 배경 동기화(옵션, 기본 꺼짐 — 내부에서 가드)
            pushRecent(project?.id)     // 최근 배경 목록 갱신(nil = 무선택 → no-op)
            baseAssetsWarningGate.presentIfNeeded(
                after: result,
                fingerprint: BaseAssetsSettings.fingerprint,
                missingRequiredSharedAssets: { renderer in
                    (renderer as? SceneRenderer)?.hasMissingRequiredSharedAssets
                },
                present: { [weak self] message in
                    guard let self else { return false }
                    return self.notify(message)
                }
            )
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
        if !apply(folderURL: folder) {
            // F031: 실패한 선택이 Now Playing/그리드에 계속 "적용됨"으로 오표시되지 않도록 UI 쪽 선택을
            // 비운다(영속 store.selectedId 는 유지 — 다음 실행도 같은 배경을 먼저 시도하되, 원본이
            // 다시 연결되면 자동 복구되고, 실패해도 아래와 동일하게 화면별 할당으로 폴백해 무해하다).
            libraryVM.selectedId = nil
            // F032: 전역 선택 마운트가 실패해도 화면별 할당(MonitorMapping) 배경은 정상일 수 있다 —
            // apply(folderURL:) 의 실패를 그냥 버리면(종전) 정상적인 할당-전용 배경까지 통째로 누락된다.
            // apply 실패는 applyResolved 이전(projectForMount/makeRenderer)에서 나므로 currentFolderURL 은
            // 아직 미설정 — applyCurrentSelection() 이 전역 없이(global: nil) 화면별 할당만 재시도한다.
            _ = applyCurrentSelection()
        }
    }

    @objc private func screensChanged() {
        // F036/F035: renderers 를 여기서 선-소거하면 desktopController.rebuild() 직후 재적용이 실패했을 때
        // RendererSwap.apply(existing:) 의 롤백 안전망("mount 실패 시 existing 은 건드리지 않는다")이 이미
        // 빈 배열을 붙잡아 무력화된다. 살아있는 renderers 를 그대로 넘겨 applyResolved → RendererSwap 이
        // 성공했을 때만 이전 렌더러를 정리하고, 실패하면 보존하게 한다(옛 창은 rebuild 로 사라지지만, 다음
        // 재시도가 성공할 때까지 renderers 배열 자체는 유효한 객체를 유지 — 자원 정리를 성공 시점까지 지연).
        activeVideoProjectIds = []
        desktopController.rebuild()
        _ = applyCurrentSelection()
    }

    /// 재생목록 타이머 재구성. 비활성/빈 목록 → 정지(스케줄 조건은 추출 로직).
    private func schedulePlaylistTimer() {
        playlistTimer?.invalidate()
        playlistTimer = nil
        guard PlaylistScheduling.shouldRun(enabled: playlistStore.enabled, ids: playlistStore.ids) else { return }
        let interval = PlaylistScheduling.intervalSeconds(minutes: playlistStore.intervalMinutes)
        playlistTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, PlaylistScheduling.shouldAdvanceNow(isPaused: self.pauseGate.isPaused) else { return }
            self.advancePlaylist()
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

    /// 가림 정지 설정(설정 창 경유). raw: -1=끔, 0=즉시, 0.3/0.5/0.8=커버 비율.
    func setOcclusionMode(raw: Double) {
        let (enabled, threshold) = OcclusionMode.decode(raw)
        pauseWhenOccluded = enabled
        occlusionCoverageThreshold = threshold
        scheduleOcclusionTimer()
    }

    /// 트레이 일시정지 항목 — 하단 바와 같은 toggleGlobalPause 를 태우고, 하단 바 미러(isPaused)도 동기화
    /// (안 하면 트레이로 토글한 상태가 하단 바 라벨/프리뷰 애니에 반영되지 않는다).
    @objc private func togglePauseFromMenu() {
        libraryVM.isPaused = toggleGlobalPause()
    }

    /// 폴링 타이머 재구성. 켜짐 → 1초 폴링(.common 모드). 꺼짐 → 정지하고, 가림 정지 중이었으면 해제.
    private func scheduleOcclusionTimer() {
        occlusionTimer?.invalidate()
        occlusionTimer = nil
        guard pauseWhenOccluded else {
            applyPause(pauseGate.set(.occlusion, active: false))  // 끄면 가림 사유 해제(다른 사유 없으면 재개)
            return
        }
        // .common 모드 — 메뉴 트래킹 중에도 폴링(scheduledTimer 는 .default 만 등록).
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkOcclusion() }
        RunLoop.main.add(timer, forMode: .common)
        occlusionTimer = timer
    }

    private func checkOcclusion() {
        let occluded = !visibilityMonitor.isDesktopVisible(threshold: occlusionCoverageThreshold)
        applyPause(pauseGate.set(.occlusion, active: occluded))
    }

    // MARK: - 전역 일시정지 (메인창 하단 바)

    /// 하단 바 일시정지 토글 — 새 상태 반환. 가림·슬립 정지와 독립(하나라도 있으면 정지 유지).
    /// 반환값은 수동 사유 하나만이 아니라 실제 정지 여부(pauseGate.isPaused, F040) — 예: 가림으로
    /// 이미 정지 중일 때 수동을 껐다 해도 여전히 정지 중이면 true 를 반환해야 UI 가 거짓 재생을 안 보인다.
    func toggleGlobalPause() -> Bool {
        let (_, action) = pauseGate.toggle(.manual)
        applyPause(action)
        return pauseGate.isPaused
    }

    /// PauseGate 결정을 실제 렌더러에 적용(사유 합성은 gate 가, 실제 pause/resume I/O 는 여기서).
    /// F040: 가림·슬립처럼 토글 메뉴를 거치지 않는 사유도 하단 바/트레이 미러(libraryVM.isPaused)를
    /// 여기서 함께 갱신한다 — 경계를 안 넘는 .none 은 상태 변화가 없으므로 미러도 스킵(가림 폴링이
    /// 매초 재호출해도 불필요한 SwiftUI 재발행을 만들지 않는다).
    private func applyPause(_ action: PauseGate.Action) {
        switch action {
        case .pause:  renderers.forEach { $0.pause() }
        case .resume: renderers.forEach { $0.resume() }
        case .none:   return
        }
        libraryVM.isPaused = pauseGate.isPaused
    }

    // MARK: - 시스템/디스플레이 슬립 자동 정지 (앱셸 스코프 A)

    /// 슬립 진입(willSleep/screensDidSleep) — 슬립 사유 켜고 필요 시 정지.
    @objc private func sleepBegan() { applyPause(pauseGate.set(.sleep, active: true)) }

    /// 웨이크(didWake/screensDidWake) — 슬립 사유 끄고, 수동·가림 사유가 없을 때만 재개.
    @objc private func sleepEnded() { applyPause(pauseGate.set(.sleep, active: false)) }

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
        case .sceneCapture:             return captureSceneStill(to: stillDir, output: output)
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

    /// 활성 씬 렌더러로 1프레임(t=1s) 캡처 → 프로젝트별 output 으로 복사. 씬 없음/실패 → nil.
    /// captureFrames 는 고정 파일명(frame_t1.0.png)이라 그대로 반환하면 씬 전환 때마다 같은 URL 이
    /// 재설정돼 macOS 배경 캐시가 갱신을 무시한다(P-B2) — 프로젝트별 경로로 복사해 URL 을 구분.
    private func captureSceneStill(to dir: URL, output: URL) -> URL? {
        guard let scene = renderers.compactMap({ $0 as? SceneRenderer }).first else { return nil }
        let size = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let captured = scene.captureFrames(width: Int(size.width * scale), height: Int(size.height * scale),
                                                 times: [1.0], toDir: dir).first else { return nil }
        let fm = FileManager.default
        try? fm.removeItem(at: output)   // safeName 은 영숫자만 남기므로 captured 와 충돌 불가
        guard (try? fm.copyItem(at: captured, to: output)) != nil else { return nil }
        return output
    }

    @discardableResult
    private func notify(_ message: String) -> Bool {
        NSLog("%@", "[Waple] \(message)")
        guard let window = libraryWindow, window.isVisible else {
            return false
        }
        bannerModel.show(message)
        return true
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// MARK: - 화면보호기 (feat/screensaver)
// 다른 브랜치와의 충돌을 최소화하기 위해 본문을 건드리지 않고 확장으로 분리했다.
// 배선: 메뉴 1항목(applicationDidFinishLaunching) + apply 성공 경로 1줄(syncVideoPath).
// ═════════════════════════════════════════════════════════════════════════════
extension AppDelegate {
    /// 켜기 = saver 설치 + 시스템 선택 + 설정 패널 열기 / 끄기 = 선택 해제. 반환 = 토글 후 선택 상태.
    func toggleScreenSaverCore() -> Bool {
        if ScreenSaverController.isSelected {
            ScreenSaverController.disable()
            return false
        }
        do {
            let project = currentFolderURL.flatMap { projectForMount(folderURL: $0) }
            try ScreenSaverController.enable(currentProject: project)
            ScreenSaverController.openSettings()  // 사용자가 바로 확인할 수 있게 잠금 화면 패널 열기
            return true
        } catch {
            notify("화면보호기 설치 실패: \(error.localizedDescription)")
            return false
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

    /// 정적 배경 동기화 설정(설정 창 경유). 켜면 즉시(지연 후) 동기화, 끄면 원본 복원.
    func setDesktopStillSync(_ enabled: Bool) {
        desktopStillSync = enabled
        if enabled {
            scheduleDesktopStillSync()
        } else {
            stillSyncWork?.cancel()
            restoreDesktopOriginals()
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

    /// 백업된 원본 바탕화면 복원. 복원 성공/파일 부재(복원 불가 확정) 키만 백업에서 제거하고
    /// 연결 안 된 화면 키는 보존한다 — 종전 전체 소거(= [:])가 분리 모니터 백업을 유실했다(P-D1).
    func restoreDesktopOriginals() {
        let originals = desktopOriginals
        guard !originals.isEmpty else { return }
        let screens = NSScreen.screens.map { (key: DesktopWindow.screenKey(for: $0), screen: $0) }
        desktopOriginals = StillDesktopSync.restorePass(
            originals: originals,
            connectedKeys: screens.map(\.key),
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            restore: { key, path in
                guard let screen = screens.first(where: { $0.key == key })?.screen else { return false }
                return (try? NSWorkspace.shared.setDesktopImageURL(
                    URL(fileURLWithPath: path), for: screen, options: [:])) != nil
            }
        )
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
        if menu === statusMenu {
            // F040: 수동 사유만 보면 가림·슬립으로 실제 정지 중일 때도 "일시정지"로 오표시된다 —
            // 실제 렌더 상태(pauseGate.isPaused, 사유 무관)를 기준으로 라벨을 정한다.
            pauseMenuItem?.title = pauseGate.isPaused ? "재개" : "일시정지"
            return
        }
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
