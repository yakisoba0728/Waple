import AppKit
import AVFoundation
import SwiftUI
import WapleCore
import WapleLibrary
import WapleRender

/// 화면 수 기준선(순수, 감사 V06) — '새 디스플레이 감지' 판정용. 기준선은 생성 시점에 캡처하고
/// 정착 후 값과 비교한다. (종전 lazy 프로퍼티는 첫 접근 — 디바운스 정착 후 — 에 기준선을 잡아
/// 첫 감지를 항상 삼켰다.)
struct ScreenCountBaseline {
    private(set) var settledCount: Int
    init(_ settledCount: Int) { self.settledCount = settledCount }
    /// 정착 후 화면 수를 기준선에 반영하고, 기준선 대비 증가(새 디스플레이) 여부를 반환한다.
    mutating func update(settled: Int) -> Bool {
        defer { settledCount = settled }
        return settled > settledCount
    }
}

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
    // 상태바 아이콘 글리프(w5d-tray): 최근 apply 성공/실패. 다음 적용 성공까지 지속(refreshStatusIcon 참조).
    private var lastApplyFailed = false

    // 정적 배경 동기화(작업 1): 적용 성공 후 스틸 생성/설정을 지연·디바운스하는 작업 핸들.
    private var stillSyncWork: DispatchWorkItem?

    // 화면 구성 변경(F034): didChangeScreenParametersNotification 은 한 물리 이벤트당 여러 번 연속
    // 발화하는 게 macOS 표준 동작이라, 코얼레싱 없이 매번 반응하면 배경이 반복 리마운트된다.
    private var screenChangeWork: DispatchWorkItem?
    // F033: 새 모니터 연결 감지용 — screensChanged 가 실제로(디바운스 정착 후) 실행될 때만 갱신해
    // 한 버스트 안의 중간값이 아니라 '정착 전 vs 정착 후'를 비교한다.
    // 감사 V06: lazy 는 첫 접근(performScreensChanged 의 정착 후)에 기준선을 잡아 첫 '새 디스플레이
    // 감지' 배너가 항상 삼켜졌다 — 기준선은 옵저버 등록 직전(didFinishLaunching)에 캡처한다.
    private var screenBaseline = ScreenCountBaseline(0)

    // F555: 비디오 비동기 실패 Notification 구독 핸들(블록 옵저버는 retain 필요).
    private var videoFailureObserver: NSObjectProtocol?

    // 최근 배경 서브메뉴(작업 6): 열 때마다 최신 목록으로 다시 채운다(NSMenuDelegate).
    private weak var recentMenu: NSMenu?

    // 설정 창 + 축소된 트레이(SP5′): 설정 창 강한 참조·일시정지 항목·상태바 메뉴 참조.
    private var settingsWindow: NSWindow?
    private weak var pauseMenuItem: NSMenuItem?
    private weak var nextMenuItem: NSMenuItem?   // "다음 배경"(w5d-tray) — 후보 2개 미만이면 비활성
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
        // 공유 에셋 해석 결과를 시작 시 1회 남긴다 — 이게 비면 씬이 흰 화면으로 나온다.
        // 배포 산출물에서 동봉 에셋이 통째로 빠진 채 나간 적이 있어(v0.1.0-beta.3), 지원·검증
        // 양쪽에서 "무엇을 잡았는가" 를 바로 볼 수 있어야 한다.
        // 경로만 찍으면 안 된다 — 루트가 **잡혔다**와 그 루트가 **쓸모 있다**는 다르다. 동봉본이
        // 포장에서 빠지거나 사용자가 엉뚱한 폴더를 지정하면 목록에는 뜨는데 shaders/common.h 가
        // 없어 셰이더가 심볼 부재로 조용히 깨진다. 그래서 루트마다 유효 여부를 함께 남긴다.
        let roots = SceneRenderer.resolvedAssetBaseRoots()
        let valid = roots.filter { BaseAssetsSettings.isValidBaseAssetsPack($0) }
        if roots.isEmpty {
            NSLog("%@", "[Waple] base assets: **없음** — 씬이 흰 화면으로 그려진다(설정에서 지정 필요)")
        } else {
            let listed = roots.map { r in
                (BaseAssetsSettings.isValidBaseAssetsPack(r) ? "ok " : "무효 ") + r.path
            }.joined(separator: " | ")
            NSLog("%@", "[Waple] base assets: 유효 \(valid.count)/\(roots.count) — " + listed)
            if valid.isEmpty {
                NSLog("%@", "[Waple] base assets: 유효한 루트가 하나도 없다 — "
                      + "shaders/common.h 부재. 셰이더 #include 가 드롭돼 씬이 불완전하게 그려진다")
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 상태바 아이콘(w5d-tray) — 시스템 심볼 템플릿(라이트/다크 메뉴바 자동 적응) + 재생/정지/오류
        // 글리프·툴팁. 초기값도 refreshStatusIcon() 을 거쳐 이후 갱신과 동일 경로를 탄다.
        refreshStatusIcon()

        // 트레이 축소(SP5′): 설정은 전부 설정 창으로 — 창 없이 필요한 동작만 남긴다.
        let menu = NSMenu()
        menu.delegate = self   // 열 때마다 일시정지 항목 제목 최신화(menuNeedsUpdate)
        menu.addItem(NSMenuItem(title: NSLocalizedString("Waple 열기", comment: ""),
                                action: #selector(openLibrary), keyEquivalent: "l"))
        menu.addItem(recentMenuItem())  // 최근 배경 서브메뉴(작업 6 — 구현은 확장)
        let pause = NSMenuItem(title: NSLocalizedString("일시정지", comment: ""),
                               action: #selector(togglePauseFromMenu), keyEquivalent: "p")
        menu.addItem(pause)
        pauseMenuItem = pause
        // w5d-tray: 메뉴바 상주 앱의 핵심 가치(창을 열지 않고 즉시 조작) — 하단 바엔 이미 있던
        // "다음 배경"을 트레이에도. WE 본가 트레이의 'Change wallpaper' 대응.
        let next = NSMenuItem(title: NSLocalizedString("다음 배경", comment: ""),
                              action: #selector(advanceFromMenu), keyEquivalent: "]")
        menu.addItem(next)
        nextMenuItem = next
        menu.addItem(NSMenuItem(title: NSLocalizedString("설정…", comment: ""),
                                action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        // 이 항목만 영어 원문("Quit Waple")이라 한국어 UI 에 영어가 섞여 있었다. 한글이 없어
        // 커버리지 오라클도 한글 스윕도 못 잡는 역방향 결함이다 — 키를 한국어로 뒤집어야
        // 오라클의 사정권에 들어온다(§9.3).
        menu.addItem(NSMenuItem(title: NSLocalizedString("Waple 종료", comment: ""),
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
        // F070: 전역으로 적용 중이던 배경이 라이브러리에서 제거되면 currentFolderURL 도 함께 비운다
        // (할당 병존 시에도 — 재적용 트리거보다 먼저 비워야 한다) — 안 하면 스테일한 값이
        // 이후 재적용에서 "제거된" 배경을 되살린다.
        libraryVM.onGlobalSelectionRemoved = { [weak self] in
            self?.currentFolderURL = nil
            self?.currentProjectId = nil
        }
        libraryVM.onPlaylistChanged = { [weak self] in self?.schedulePlaylistTimer() }
        libraryVM.onOpenInteraction = { [weak self] in self?.openWebInteraction() }
        libraryVM.onOpenSettings = { [weak self] in self?.openSettings() }
        libraryVM.onAdvancePlaylist = { [weak self] in self?.advancePlaylist() }
        libraryVM.onTogglePause = { [weak self] in self?.toggleGlobalPause() ?? false }
        // w5d-settings-ia: 음량/배속 조절이 설정 창에서 하단 바로 이관 — SettingsViewModel 이 쓰던 것과
        // 동일 소스(VideoSettingsTarget.projectIds)를 libraryVM 에도 주입.
        libraryVM.videoTargetIds = { [weak self] in
            guard let self else { return [] }
            return VideoSettingsTarget.projectIds(currentProjectId: self.currentProjectId,
                                                  activeVideoProjectIds: self.activeVideoProjectIds)
        }
        // F820: 음량/배속 변경은 살아있는 플레이어에 라이브 반영 — 종전 applyCurrentSelection()
        // 전체 리마운트는 mkv/webm 에서 ffmpeg 재변환 대기+재생 리셋(t=0)을 유발했다.
        libraryVM.onVideoSettingsChanged = { [weak self] in self?.applyLiveVideoSettings() }
        schedulePlaylistTimer()

        desktopController.rebuild()

        // 화면 구성 변경(모니터 연결/해제/해상도) 시 창 재구성 후 재적용.
        // 감사 V06: '새 디스플레이 감지' 기준선은 여기서(실행 시 구성) 캡처 — 첫 변경부터 비교가 유효하다.
        screenBaseline = ScreenCountBaseline(NSScreen.screens.count)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // F555: 비디오 배경의 비동기 실패(변환 실패·재생 중 실패 후 회복 불가)를 배너로 표면화.
        // 발행 스레드가 백그라운드일 수 있어 메인으로 홉한다.
        videoFailureObserver = NotificationCenter.default.addObserver(
            forName: .wapleVideoPlaybackFailed, object: nil, queue: nil
        ) { [weak self] note in
            let name = (note.userInfo?["url"] as? URL)?.lastPathComponent
                ?? NSLocalizedString("비디오", comment: "파일명을 못 얻었을 때의 대체 표기")
            DispatchQueue.main.async {
                _ = self?.notify(String(format: NSLocalizedString("비디오를 재생할 수 없습니다: %@",
                                                                  comment: "비디오 비동기 실패"), name))
            }
        }

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

        // 스모크 확인용: 실행 시 메인창 자동 오픈 + 첫 항목 포커스(인스펙터가 채워진 상태로
        // 캡처되도록 — 판정 게이트용). 해석은 전부 SmokeLaunch(순수 + 단위 테스트) 가 한다.
        let smoke = SmokeLaunch.current
        if smoke.opensLibrary {
            DispatchQueue.main.async { [weak self] in
                self?.openLibrary()
                guard smoke.focusesFirstEntry else { return }
                self?.libraryVM.focusedId = self?.libraryVM.entries.first?.id
                self?.libraryVM.panelVisible = smoke.showsInspector
            }
        }

        // 설정 창 캡처용(판정 게이트): WAPLE_SMOKE_SETTINGS=1 이면 설정 창 자동 오픈.
        if smoke.opensSettings {
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
        // w5d-onboarding: '배경 추가' 행 "가져오기…" — WallpaperGridView.importFolder 와 동일한
        // NSOpenPanel+routeImport 배선(ImportPanel)을 재사용해 필수 단계를 시트에서 한 번에 끝낸다.
        onboardingModel.onImport = { [weak self] in
            guard let self else { return }
            ImportPanel.run(into: self.libraryVM)
        }
        maybePresentOnboarding()
    }

    /// 첫 실행이면 라이브러리 창 + 안내 시트를 1회 띄운다. 스모크 캡처와 분리:
    /// WAPLE_SMOKE_ONBOARDING 은 (플래그 무관) 강제 표시, 그 외 WAPLE_SMOKE* 는 억제(기존 4종 무회귀).
    private func maybePresentOnboarding() {
        let smoke = SmokeLaunch.current
        if smoke.forcesOnboarding {
            // 창 오픈은 위 smoke.opensLibrary 블록이 이미 예약했다(온보딩 강제도 그 집합에 든다).
            DispatchQueue.main.async { [weak self] in self?.onboardingModel.present() }
            return
        }
        guard Onboarding.shouldPresent(completed: onboardingCompleted),
              !smoke.suppressesOnboarding else { return }
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
        // NSOpenPanel 의 prompt·message 도 AppKit 경로라 자동 해석이 없다(청사진 §5.1).
        panel.prompt = NSLocalizedString("선택", comment: "열기 패널 확인 버튼")
        panel.message = NSLocalizedString(
            "Wallpaper Engine 기본 에셋(assets) 폴더를 선택하세요. 패키지에 없는 공유 텍스처를 여기서 불러옵니다.",
            comment: "공유 에셋 폴더 선택 안내")
        panel.directoryURL = BaseAssetsSettings.baseAssetsDirectory
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        BaseAssetsSettings.baseAssetsDirectory = url
        _ = applyCurrentSelection()  // 누락 텍스처 즉시 반영(할당-전용 표시 중에도 — P-B4)
    }

    /// 현재 적용된 웹 월페이퍼의 조작 창(실입력 프록시 + 라이브 미러)을 연다.
    @objc private func openWebInteraction() {
        // F022: 화면마다 다른 웹 배경(모니터별 할당)이 동시에 적용될 수 있는데 종전엔 마운트 순서상
        // '첫 번째' WebRenderer 만 대상으로 해 두 번째 이후 화면의 웹 배경은 조작 창(실입력 프록시)을
        // 열 방법이 아예 없었다. renderers 는 화면키를 들고 있지 않아(F039 참조 — 별도 스코프) 특정
        // 화면 하나만 골라 여는 UI는 이번 스코프 밖이지만, 전부 열면 최소한 도달 불가 상태는 없앤다.
        let webRenderers = renderers.compactMap { $0 as? WebRenderer }
        guard !webRenderers.isEmpty else {
            notify(NSLocalizedString("웹 월페이퍼가 적용되어 있지 않습니다 — 웹 배경을 먼저 적용하세요",
                                     comment: "조작 창 — 웹 배경 없음"))
            return
        }
        webRenderers.forEach { $0.openInteractionPanel() }
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
            // `window.appearance = NSAppearance(named: .darkAqua)` 를 걷어냈다(Unit E, 2026-08-17).
            // 종전 주석은 "WE 관례 — 항상 다크" 였고 근거는 2026-07-12 스펙 §3("다크 하의 시맨틱
            // 값만, 라이트 대응 없음")이었다. **그 근거를 읽고 뒤집었다**(청사진 §8.1, 사용자 승인).
            // WE 가 항상 어둡다는 것은 WE 의 사정이지 macOS 앱이 시스템 외관을 무시할 이유가 아니다 —
            // 이번 개편이 고른 "시스템이 공짜로 주는 것을 받아먹는다" 와 정면으로 모순된다.
            // 실측이 그 강제의 크기를 보여줬다: 시스템을 라이트로 바꾸고 찍은 캡처가 다크 캡처와
            // md5 까지 같았다 — 이 앱엔 라이트 모드가 아예 없었다.
            // 걷어낼 수 있게 된 전제는 리터럴 색 13곳이 전부 `ColorRole` 시맨틱으로 옮겨진 것이다
            // (Phase 2 완료). appearance 를 대입하지 않으면 창이 시스템 값을 상속한다.
            // 스펙 §3 을 근거로 되돌리지 마라 — 몰라서 어긴 것이 아니라 읽고 뒤집은 결정이다.
            // 프로그램 생성 NSWindow 는 닫힐 때 기본적으로 release 되어, 강한 참조 프로퍼티가
            // 댕글링되고 재오픈 시 use-after-free 가 된다. 프로퍼티가 수명을 관리하도록 막는다.
            window.isReleasedWhenClosed = false
            window.center()   // F024: 최초 생성 시에만 중앙 배치 — 재오픈마다 사용자가 옮긴 위치를 되돌리지 않는다.
            libraryWindow = window
        }
        // F023: orderFront 계열은 최소화된 창을 복원하지 않는다 — 액세서리 앱(Dock 아이콘 없음)이라
        // 트레이가 유일한 재진입점인데 deminiaturize 가 없으면 최소화된 라이브러리 창이 영영 안 뜬다.
        if libraryWindow?.isMiniaturized == true { libraryWindow?.deminiaturize(nil) }
        libraryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 설정 창(SP5′) — openLibrary 와 같은 수명 규약: isReleasedWhenClosed=false·강한 참조.
    /// (종전 이 줄은 "darkAqua·isReleasedWhenClosed=false·강한 참조" 였다 — darkAqua 강제를
    /// 걷어냈으므로 규약에서도 뺀다. 근거는 openLibrary 쪽 주석.)
    @objc func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(vm: settingsVM))
            let window = NSWindow(contentViewController: hosting)
            window.title = NSLocalizedString("Waple 설정", comment: "")
            window.styleMask = [.titled, .closable]
            window.setContentSize(Metrics.settingsSize)
            // darkAqua 강제 제거 — 근거는 openLibrary 쪽 주석(청사진 §8.1).
            window.isReleasedWhenClosed = false
            window.center()   // F024: 최초 생성 시에만 — 재오픈마다 위치를 되돌리지 않는다.
            settingsWindow = window
        }
        settingsVM.refresh()
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
            notify(NSLocalizedString("적용 실패: project.json 또는 preset dependency 를 해석할 수 없습니다",
                                     comment: "적용 실패 — 파스 불가"))
            markApplyResult(success: false)
            return false
        }
        guard RendererFactory.makeRenderer(for: project) != nil else {
            notify(String(format: NSLocalizedString("지원하지 않는 타입입니다: %@",
                                                    comment: "적용 실패 — 미지원 타입"),
                          project.type.storageString))
            markApplyResult(success: false)
            return false
        }
        return applyResolved(global: project, folderURL: folderURL)
    }

    @discardableResult
    private func applyCurrentSelection() -> Bool {
        if let folder = currentFolderURL {
            if apply(folderURL: folder) { return true }
            // F482: 전역 마운트 실패(스테일 currentFolderURL — 폴더 외부 삭제/이동) 시 화면별 할당
            // 폴백. 종전엔 restoreLastWallpaper(F032)에만 있어 할당 변경·비디오 설정·베이스 에셋·
            // 화면 변경 경로는 정상인 모니터별 할당까지 전부 마운트되지 않았다.
            // (비디오 설정 경로는 F820 에서 라이브 반영으로 바뀌어 더는 재적용을 타지 않는다.)
            // 단, 마운트 가능한 할당이 하나도 없으면 폴백하지 않는다 — 빈 슬롯 성공이 살아있는
            // 렌더러까지 teardown 하는 역효과를 막는다(F035/F036 롤백 보호 유지).
            guard resolvedScreenProjectSlots(global: nil).contains(where: { $0.project != nil }) else { return false }
            return applyResolved(global: nil, folderURL: nil)
        }
        return applyResolved(global: nil, folderURL: nil)
    }

    /// F820: 음량/배속 변경 라이브 반영 — 살아있는 VideoRenderer 의 AVPlayer.volume/defaultRate 를
    /// 직접 조정해 전체 리마운트(mkv/webm 은 ffmpeg 재변환 대기+재생 리셋)를 피한다.
    /// 값 저장은 호출자(NowPlayingBar)가 이미 마쳤고, 마운트 중(변환 대기)인 렌더러는
    /// attachPlayer 시 새 값을 읽으므로 별도의 재적용은 필요 없다.
    private func applyLiveVideoSettings() {
        renderers.compactMap { $0 as? VideoRenderer }.forEach { $0.applyLiveVideoSettings() }
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
            // F028: syncVideoPath 는 activeVideoProjectIds 와 같은 소스(모니터별 할당 반영된
            // screenProjects)를 써야 한다 — 종전엔 여기서만 전역 project 파라미터에 게이팅돼, 전역
            // 선택 없이(project==nil) 화면별 할당만으로 동영상을 표시 중이면 화면보호기 videoPath 가
            // 절대 갱신되지 않았다. screenProjects 는 미할당 화면에 전역을 폴백하므로 전역이 동영상인
            // 경우도 그대로 포함된다(무회귀) — 여러 화면이 서로 다른 동영상이면 첫 번째를 채택.
            ScreenSaverController.syncVideoPath(for: screenProjects.first { $0.project.type == .video }?.project)
            if pauseGate.isPaused { renderers.forEach { $0.pause() } }  // 어떤 사유든 정지 중 교체된 렌더러도 정지 유지
            scheduleDesktopStillSync()  // 정적 배경 동기화(옵션, 기본 꺼짐 — 내부에서 가드)
            if project != nil {
                // F480: 최근 배경은 파서 id(project.id)가 아니라 라이브러리 엔트리 id 여야 한다 —
                // F194 접미 유일화 엔트리(x-2)는 둘이 달라 menuNeedsUpdate 가 무접미 id 의 다른
                // 엔트리를 집거나(원본 제거 시) 못 찾았다. 마운트 폴더로 엔트리 id 를 역탐색한다.
                pushRecent(recentEntryId(mountedFolder: folderURL))
            } else {
                // F029: 전역 선택 없이 화면별 할당만으로 적용하는(공식 지원되는) 모드에서는
                // pushRecent(nil) 이 항상 no-op 이라 실제 적용된 배경이 '최근 배경' 메뉴에 전혀
                // 쌓이지 않았다 — 화면별로 실제 마운트된 프로젝트 id 를 대신 반영한다(중복은
                // pushRecent/RecentWallpapers.push 자체가 제거).
                // F480: 이 분기는 global == nil 이라 마운트된 프로젝트는 전부 화면 할당에서 왔다 —
                // 파서 id 대신 할당 스토어의 엔트리 id 를 그대로 push(접미 유일화 정합).
                screenProjects.forEach { pushRecent(monitorStore.assignment(for: $0.screenKey)) }
            }
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
            markApplyResult(success: true)
            return true
        case .failure(let error):
            notify(String(format: NSLocalizedString("적용 실패: %@", comment: "적용 실패 — 마운트 오류"),
                          String(describing: error)))
            markApplyResult(success: false)
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

    /// F034: didChangeScreenParametersNotification 은 단일 모니터 연결/해제·해상도 정착·Dock
    /// 표시-숨김·디스플레이 슬립/웨이크에서 macOS 가 보통 2~4회 연속 발화한다 — 디바운스 없이 매번
    /// 반응하면 배경이 반복 리마운트된다(동영상 t=0 재시작·웹 페이지 리로드·텍스처 재업로드).
    /// scheduleDesktopStillSync 와 동일한 취소+재예약 패턴으로 흡수.
    @objc private func screensChanged() {
        screenChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performScreensChanged() }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func performScreensChanged() {
        // F033: 새 디스플레이가 연결됐으면(정착 전 대비 화면 수 증가) 화면별 지정 기능을 안내 —
        // 재구성/재적용 '전'에 스냅샷해야 rebuild 이후에도 비교가 유효하다.
        let newScreenDetected = screenBaseline.update(settled: NSScreen.screens.count)

        // F036/F035: renderers 를 여기서 선-소거하면 desktopController.rebuild() 직후 재적용이 실패했을 때
        // RendererSwap.apply(existing:) 의 롤백 안전망("mount 실패 시 existing 은 건드리지 않는다")이 이미
        // 빈 배열을 붙잡아 무력화된다. 살아있는 renderers 를 그대로 넘겨 applyResolved → RendererSwap 이
        // 성공했을 때만 이전 렌더러를 정리하고, 실패하면 보존하게 한다(옛 창은 rebuild 로 사라지지만, 다음
        // 재시도가 성공할 때까지 renderers 배열 자체는 유효한 객체를 유지 — 자원 정리를 성공 시점까지 지연).
        // F487: activeVideoProjectIds 도 여기서 선-소거하지 않는다 — 재적용 실패 시 롤백으로 살아있는
        // 비디오 렌더러의 음량/배속 타깃(VideoSettingsTarget.projectIds)이 사라져 하단 바 조절이
        // 묵묵히 무시되는 상태가 됐다. 성공 시 applyResolved 가 screenProjects 기준으로 항상 재계산하므로 불필요.
        desktopController.rebuild()
        _ = applyCurrentSelection()

        if newScreenDetected {
            notify(NSLocalizedString(
                "새 디스플레이가 연결됐습니다 — 화면마다 다른 배경을 지정하려면 '디스플레이' 버튼을 확인하세요",
                comment: "새 모니터 감지 안내"))
        }
    }

    /// 재생목록 타이머 재구성. 비활성/빈 목록 → 정지(스케줄 조건은 추출 로직).
    private func schedulePlaylistTimer() {
        playlistTimer?.invalidate()
        playlistTimer = nil
        // F483: 후보가 1개뿐이면 타이머를 걸지 않는다 — 매 간격 같은 배경 리마운트만 발생한다
        // (수동 버튼/트레이의 canAdvance 가드와 대칭).
        guard PlaylistScheduling.shouldScheduleTimer(enabled: playlistStore.enabled, ids: playlistStore.ids) else { return }
        let interval = PlaylistScheduling.intervalSeconds(minutes: playlistStore.intervalMinutes)
        playlistTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, PlaylistScheduling.shouldAdvanceNow(isPaused: self.pauseGate.isPaused) else { return }
            self.advancePlaylist()
        }
    }

    private func advancePlaylist() {
        // 후보를 순서대로 시도하고 실제 적용에 성공하는 첫 배경으로 전진(삭제/폴더 이동 등 실패 후보는 건너뜀).
        // w5d-playback: shuffle 이 켜져 있으면 순차 순환 대신 직전 곡 회피 무작위 선곡으로 분기.
        _ = PlaylistScheduling.advance(
            from: store.selectedId,
            count: playlistStore.ids.count,
            next: { current in
                self.playlistStore.shuffle
                    ? PlaylistScheduling.shuffleNext(current: current, ids: self.playlistStore.ids)
                    : self.playlistStore.next(after: current)
            },
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

    /// 트레이 "다음 배경"(w5d-tray) — 하단 바 forward 버튼과 동일하게 기존 advancePlaylist() 재사용.
    @objc private func advanceFromMenu() {
        advancePlaylist()
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
        refreshStatusIcon()
    }

    // MARK: - 상태바 아이콘 글리프·툴팁 (w5d-tray)

    /// apply 성공/실패 초크포인트 — apply(folderURL:) 의 조기 실패 2곳과 applyResolved 의 성공/실패
    /// 분기가 전부 여기를 거친다. 오류 플래그는 다음 적용 성공까지 지속(무음 실패를 능동적으로 드러냄).
    private func markApplyResult(success: Bool) {
        lastApplyFailed = !success
        refreshStatusIcon()
    }

    /// 글리프(재생/정지/오류) + 툴팁(적용된 배경 제목 + 상태) 갱신 — 결정은 StatusIconState(순수).
    private func refreshStatusIcon() {
        let symbolName = StatusIconState.symbolName(isPaused: pauseGate.isPaused, hasError: lastApplyFailed)
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Waple") {
            symbol.isTemplate = true
            statusItem.button?.image = symbol
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = "🖼"   // 심볼 부재 시 이모지 폴백(기존 동작 유지)
        }
        statusItem.button?.toolTip = StatusIconState.tooltip(
            appliedTitle: libraryVM.appliedTitle, isPaused: pauseGate.isPaused, hasError: lastApplyFailed)
    }

    // MARK: - 시스템/디스플레이 슬립 자동 정지 (앱셸 스코프 A)

    /// 슬립 진입(willSleep/screensDidSleep) — 슬립 사유 켜고 필요 시 정지.
    @objc private func sleepBegan() { applyPause(pauseGate.set(.sleep, active: true)) }

    /// 웨이크(didWake/screensDidWake) — 슬립 사유 끄고, 수동·가림 사유가 없을 때만 재개.
    @objc private func sleepEnded() { applyPause(pauseGate.set(.sleep, active: false)) }

    // MARK: - 정지 배경으로 설정 (작업 3)

    /// 현재 배경에서 화면별 정지 이미지를 만들어 데스크탑 배경으로 지정(수동 1회, F046: 모니터별 할당
    /// 인지 — 화면마다 실제로 표시 중인 프로젝트에서 스틸을 뽑아 그 화면에만 적용한다).
    /// 배경 창은 아이콘 레벨 아래라, 라이브 창이 떠 있는 동안 정지 배경은 그 뒤의 폴백 레이어다.
    /// 원본 백업은 F042 부터 수동 경로도 남기지만(이후 동기화가 켜질 때의 자기오염 방지용), 동기화
    /// OFF 상태에서는 종료 시 복원하지 않는다(F481) — 수동 설정은 사용자의 명시적 1회 액션이라 유지.
    @objc private func setStillWallpaper() {
        // F043: currentFolderURL(전역 선택)만 보면 화면별 할당-전용 모드(전역 nil)에서 배경이 실제로
        // 표시 중인데도 "없음" 오탐이 난다 — 실제 마운트된 렌더러 존재 여부로 판정.
        guard !renderers.isEmpty else {
            notify(NSLocalizedString("적용된 배경이 없습니다", comment: "정지 배경 — 대상 없음"))
            return
        }
        // F047: currentFolderURL 은 메인 전용 프로퍼티라 백그라운드 클로저에서 직접 읽으면(다른 apply
        // 가 마침 같은 순간 메인에서 값을 바꿀 수 있어) 동기화 없는 경합이 생긴다 — 큐 진입 '전'
        // 메인에서 스냅샷해 넘긴다.
        let globalFolderURL = currentFolderURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let images = self.generateStillImages(globalFolderURL: globalFolderURL)   // 블로킹 — 백그라운드(F047)
            DispatchQueue.main.async { self.finishSetStillWallpaper(images: images) }
        }
    }

    /// setStillWallpaper 의 메인 스레드 마무리 — 실제 OS 호출 결과에 따라 통지 문구를 정확히 고른다.
    private func finishSetStillWallpaper(images: [String: URL]) {
        guard !images.isEmpty else {
            notify(NSLocalizedString("정지 배경을 만들 수 없습니다", comment: "정지 배경 — 생성 실패"))
            return
        }
        backupOriginalsIfNeeded()   // F042: 덮어쓰기 전에 항상 먼저 백업(동기화 디바운스 경합과 무관)
        var successCount = 0
        let screens = NSScreen.screens
        for screen in screens {
            guard let image = images[DesktopWindow.screenKey(for: screen)] else { continue }
            // F044/F045: try? 로 삼키지 않고 실제 성공 여부를 센다 — 무조건 성공 알림을 띄우던 결함.
            if (try? NSWorkspace.shared.setDesktopImageURL(image, for: screen, options: [:])) != nil {
                successCount += 1
            }
        }
        notify(StillWallpaperNotice.message(successCount: successCount, totalScreens: screens.count))
    }

    /// still 산출 디렉터리(라이브러리 베이스/still).
    private func stillDirectory() -> URL {
        LibraryStore.defaultBaseDirectory().appendingPathComponent("still", isDirectory: true)
    }

    /// 화면키 → 그 화면에 실제로 표시 중인 프로젝트의 정지 이미지(F046). 모니터별 할당을 그대로
    /// 반영하는 MonitorMapping.resolveProjectSlots(applyResolved 와 동일 소스)로 화면별 프로젝트를
    /// 구한 뒤, 같은 프로젝트를 쓰는 화면은 한 번만 생성해 공유한다. 화면/전역 모두 무배경이면 빈 dict.
    /// ⚠️ 블로킹(AVFoundation 디코드·씬 GPU 캡처) — 백그라운드 큐에서 호출(F047). NSScreen 열거는
    /// 메인에서 미리 끝내 두고 넘어온 값을 쓴다(AppKit 뷰 API 는 메인 스레드 전용). globalFolderURL 도
    /// 호출부가 메인에서 스냅샷해 넘긴다(currentFolderURL 을 백그라운드에서 직접 읽는 경합 방지).
    private func generateStillImages(globalFolderURL: URL?) -> [String: URL] {
        // NSScreen 열거·backingScaleFactor 조회는 AppKit 이라 메인에서 미리 캡처(F486: 씬 캡처가
        // 백그라운드로 남려가면서 NSScreen 접근은 전부 이 시점으로 모았다).
        let (screenSizes, mainScale) = DispatchQueue.main.sync {
            (Dictionary(uniqueKeysWithValues: NSScreen.screens.map { (DesktopWindow.screenKey(for: $0), $0.frame.size) }),
             NSScreen.main?.backingScaleFactor ?? 2)
        }
        // F485: 전역 프리셋 해석(projectForMount → PresetResolver → folderForEntry → LibraryStore.entries
        // 읽기 + stale 북마크 시 entries 갱신·save)을 백그라운드에서 직접 치면 락 없는 스토어 경합이다
        // (F047 불완전 — 화면별 슬롯만 main.sync 였다). 슬롯 해석과 같은 main.sync 에서 함께 해석해
        // 스토어 접근을 전부 메인에 모은다.
        let (_, slots) = DispatchQueue.main.sync { () -> (WallpaperProject?, [(key: String, project: WallpaperProject?)]) in
            let g = globalFolderURL.flatMap { self.projectForMount(folderURL: $0) }
            return (g, self.resolvedScreenProjectSlots(global: g))
        }
        let stillDir = stillDirectory()
        try? FileManager.default.createDirectory(at: stillDir, withIntermediateDirectories: true)

        var cache: [String: URL?] = [:]   // 스틸 캐시 키 → 생성 결과(실패도 캐시해 같은 화면 반복 재시도 방지)
        var result: [String: URL] = [:]
        for (key, project) in slots {
            guard let project, let source = StillWallpaper.source(for: project) else { continue }
            let size = screenSizes[key] ?? screenSizes.values.first ?? CGSize(width: 1920, height: 1080)
            // F484: 씬 캡처는 요청 크기로 렌더되므로 캐시 키에 크기를 포함한다 — 종전 id 전용 키라
            // 해상도/종횡비가 다른 두 모니터에 같은 씬이 할당되면 첫 화면 크기 스틸이 재사용됐다.
            // (비디오 프레임·preview 는 크기 무관 — 기존 id 키 유지.)
            let cacheKey = StillWallpaper.cacheKey(projectId: project.id, size: size,
                                                   sizeDependent: StillWallpaper.isSizeDependent(source))
            let url: URL?
            if let cached = cache[cacheKey] {
                url = cached
            } else {
                url = stillImage(for: project, source: source, size: size, scale: mainScale, stillDir: stillDir)
                cache[cacheKey] = url
            }
            if let url { result[key] = url }
        }
        return result
    }

    /// 화면키 → 마운트된 프로젝트(F046 공용 — setStillWallpaper/syncDesktopStill/잠금화면 스틸이 공유).
    /// applyResolved(304행대)와 동일한 MonitorMapping.resolveProjectSlots 호출 — 소스가 어긋나면
    /// 실제 표시와 스틸이 따로 놀아 F046 이 재발한다.
    private func resolvedScreenProjectSlots(global: WallpaperProject?) -> [(key: String, project: WallpaperProject?)] {
        let screens = desktopController.screenViews
        let slots = MonitorMapping.resolveProjectSlots(
            screenKeys: screens.map { $0.screenKey },
            global: global,
            assignedFolder: { key in
                MonitorMapping.assignedFolder(
                    screenKey: key,
                    assignment: { self.monitorStore.assignment(for: $0) },
                    folderForEntry: { self.folderForEntry($0) })
            },
            parse: { self.projectForMount(folderURL: $0) }
        )
        return Array(zip(screens.map { $0.screenKey }, slots))
    }

    /// 프로젝트 하나의 정지 이미지(공통 스위치 — 동영상/씬/프리뷰). 소스 해석 실패/추출 실패 → nil.
    private func stillImage(for project: WallpaperProject, source: StillWallpaper.Source,
                            size: CGSize, scale: CGFloat, stillDir: URL) -> URL? {
        // F484: 크기 의존 소스(씬 캡처)만 출력 파일명에 크기를 넣는다 — 같은 씬의 크기별 스틸이 공존.
        let output = StillWallpaper.outputURL(projectId: project.id,
                                              size: StillWallpaper.isSizeDependent(source) ? size : nil,
                                              stillDir: stillDir)
        switch source {
        case .videoFrame(let videoURL): return extractVideoFrame(from: videoURL, to: output)
        case .sceneCapture:             return captureSceneStill(project: project, size: size, scale: scale, to: stillDir, output: output)
        case .previewImage(let url):    return url   // preview 파일 그대로 사용
        }
    }

    /// 동영상 t=1s 프레임 → PNG(실패 시 t=0 폴백). 실패 → nil. AVFoundation 동기 디코드 — 백그라운드
    /// 큐에서 호출(F047, generateStillImages 경유).
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

    /// 프로젝트 전용 임시 SceneRenderer 로 1프레임(t=1s) 캡처 → output 으로 복사(F046: 화면별로 실제
    /// 마운트된 렌더러가 아니라 프로젝트 자체를 그 화면 크기로 새로 렌더 — 어느 렌더러가 어느 화면
    /// 것인지 추적할 필요 없이 항상 정확한 프로젝트·크기로 캡처된다). 컨테이너는 어떤 창에도 속하지
    /// 않는 오프스크린 NSView — SceneRenderer.mount 는 이미 이런 헤드리스 마운트를 캡처/테스트 용도로
    /// 정식 지원한다("container.window == nil → 사운드 등 라이브 전용 사이드이펙트 스킵, 결정적").
    /// F486: 종전엔 NSView/MTKView 생성이 메인 전용이라는 이유로 마운트(셰이더 컴파일)+GPU 대기
    /// (waitUntilCompleted)까지 main.sync 에서 실행해 무거운 씬이면 수 초간 메뉴/라이브러리 창이
    /// 정지했다(F049). 헤드리스 컨테이너는 창 계층에 들어가지 않고 draw/이벤트도 발생하지 않으며,
    /// captureFrames 는 Metal 커맨드 인코딩+PNG 쓰기뿐이라 스레드 안전하다 — F047 블로킹 큐에서
    /// 전 구간을 그대로 실행한다. NSScreen 이 필요한 scale 만 호출부가 메인에서 캡처해 넘기고,
    /// 완료 후 메인 홉은 호출부(finishSetStillWallpaper/finishSyncDesktopStill)가 담당한다.
    private func captureSceneStill(project: WallpaperProject, size: CGSize, scale: CGFloat, to dir: URL, output: URL) -> URL? {
        guard size.width > 0, size.height > 0,
              let renderer = RendererFactory.makeRenderer(for: project) as? SceneRenderer else { return nil }
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        do {
            try renderer.mount(in: container, project: project)
        } catch {
            return nil
        }
        defer { renderer.teardown() }
        guard let captured = renderer.captureFrames(width: Int(size.width * scale), height: Int(size.height * scale),
                                                    times: [1.0], toDir: dir).first else { return nil }
        let fm = FileManager.default
        try? fm.removeItem(at: output)   // safeName 은 영숫자만 남기므로 captured 와 충돌 불가
        guard (try? fm.copyItem(at: captured, to: output)) != nil else { return nil }
        return output
    }

    /// 상태 배너 + 로그. **`message` 는 이미 현지화된 문자열이어야 한다.**
    ///
    /// 싱크인 `StatusBanner` 는 `Label(msg, systemImage:)` 로 받는데 그 오버로드는
    /// `StringProtocol` 이라 번역하지 않는다 — 한국어 리터럴을 그대로 넘기면 영어 시스템에서
    /// 배너만 한국어로 남고 아무 것도 실패하지 않는다(청사진 §5.0). 싱크 타입을
    /// `LocalizedStringKey` 로 바꾸는 대안은 리터럴을 대입문으로 만들어 스캔 사각지대를
    /// 새로 판다 — 그래서 호출부 전부가 `NSLocalizedString` 으로 완성해서 넘긴다.
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
            let global = currentFolderURL.flatMap { projectForMount(folderURL: $0) }
            // F028: 전역 선택 없이(화면별 할당만) 동영상을 표시 중이어도 화면보호기가 그 동영상을
            // 찾을 수 있게 resolvedScreenProjectSlots(applyResolved 와 동일 소스)로 화면별 프로젝트를
            // 함께 본다. 못 찾으면 종전처럼 전역으로 폴백(무회귀 — 전역이 비디오 아니면 syncVideoPath
            // 내부에서 조용히 no-op).
            let videoProject = resolvedScreenProjectSlots(global: global).first { $0.project?.type == .video }?.project
            try ScreenSaverController.enable(currentProject: videoProject ?? global)
            ScreenSaverController.openSettings()  // 사용자가 바로 확인할 수 있게 잠금 화면 패널 열기
            return true
        } catch {
            // 바깥 문구만 감싼다. 안쪽 localizedDescription 은 ScreenSaverController 가 만드는데
            // 그 파일은 전 페이즈 동결이라 손대지 않았다 — 영어 UI 에서 사유만 한국어로 남는다(보고).
            notify(String(format: NSLocalizedString("화면보호기 설치 실패: %@", comment: "화면보호기 설치 실패"),
                          error.localizedDescription))
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

    /// 현재 배경 스틸을 화면별로 실제 표시 중인 프로젝트에서 만들어 데스크탑에 설정(F046: 모니터별
    /// 할당 인지). 실패는 조용히 — 이 기능은 폴백일 뿐이다.
    private func syncDesktopStill() {
        guard desktopStillSync else { return }
        let globalFolderURL = currentFolderURL   // F047: 메인에서 스냅샷 — 백그라운드 직접 읽기 경합 방지
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let images = self.generateStillImages(globalFolderURL: globalFolderURL)   // 블로킹 — 백그라운드(F047)
            DispatchQueue.main.async { self.finishSyncDesktopStill(images: images) }
        }
    }

    /// syncDesktopStill 의 메인 스레드 마무리 — 백업·실 적용·잠금화면 갱신.
    private func finishSyncDesktopStill(images: [String: URL]) {
        guard desktopStillSync, !images.isEmpty else { return }
        backupOriginalsIfNeeded()   // F042: 원본 백업 — 화면별 최초 덮어쓰기 직전 값만(자기오염 가드)
        for screen in NSScreen.screens {
            guard let image = images[DesktopWindow.screenKey(for: screen)] else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(image, for: screen, options: [:])
        }
        // 잠금화면은 시스템 전역 1장뿐이라 화면별로 나눌 수 없다 — 주 화면(NSScreen.main) 이미지를
        // 우선하고, 못 찾으면(드문 경우) 생성된 것 중 아무거나.
        if let mainKey = NSScreen.main.map(DesktopWindow.screenKey(for:)), let mainImage = images[mainKey] {
            writeLockscreenStill(mainImage)
        } else if let anyImage = images.values.first {
            writeLockscreenStill(anyImage)
        }
    }

    /// 최초 덮어쓰기 직전 원본을 화면별로 백업(자기오염 가드) — 자동 동기화·수동 설정 공용(F042: 수동
    /// "정지 배경으로 설정"이 동기화의 3초 디바운스 창 안에 먼저 실행되면, 이 백업이 자동 동기화
    /// 전용으로만 존재하던 종전엔 원본이 한 번도 백업되지 못했다 — 두 경로가 여기를 함께 거치게 해
    /// 순서와 무관하게 항상 백업이 보장되도록 했다).
    private func backupOriginalsIfNeeded() {
        var originals = desktopOriginals
        let stillPath = stillDirectory().path
        for screen in NSScreen.screens {
            let key = DesktopWindow.screenKey(for: screen)
            let current = NSWorkspace.shared.desktopImageURL(for: screen)?.path
            if StillDesktopSync.shouldBackupOriginal(
                currentPath: current, stillDirPath: stillPath, hasBackup: originals[key] != nil) {
                originals[key] = current
            }
        }
        desktopOriginals = originals
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
    /// dscl 서브프로세스 대기가 블로킹이라(F047) 호출부(메인 스레드)를 막지 않도록 여기서 자체적으로
    /// 백그라운드 큐로 넘어간다 — graceful 기능이라 호출부는 결과를 기다리지 않는다(fire-and-forget).
    private func writeLockscreenStill(_ image: URL) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, let uid = self.currentUserGeneratedUID() else { return }
            let dir = URL(fileURLWithPath: "/Library/Caches/Desktop Pictures/\(uid)", isDirectory: true)
            guard FileManager.default.fileExists(atPath: dir.path) else { return }  // 디렉터리 부재 → 스킵
            // 원본이 PNG 가 아닐 수 있어(preview.jpg 등) PNG 로 재인코딩.
            guard let nsImage = NSImage(contentsOf: image),
                  let tiff = nsImage.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            do {
                try png.write(to: dir.appendingPathComponent("lockscreen.png"), options: .atomic)
            } catch {
                DispatchQueue.main.async {
                    self.notify(String(format: NSLocalizedString("잠금화면 스틸 기록 실패(무시): %@",
                                                                 comment: "잠금화면 스틸 기록 실패"),
                                       error.localizedDescription))
                }
            }
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
    /// F481: 자동 동기화가 켜진 채 종료될 때만 복원한다 — 동기화 OFF 에서의 수동 "정지 배경으로 설정"
    /// 은 사용자의 명시적 1회 액션이라(:616 독스트링) 종료와 함께 되돌리면 그 의도와 모순된다.
    /// (백업 자체는 F042 오염 방지용으로 수동 경로도 남긴다 — 복원 여부만 여기서 가드.)
    public func applicationWillTerminate(_ notification: Notification) {
        guard StillDesktopSync.shouldRestoreOnTerminate(syncEnabled: desktopStillSync) else { return }
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

    /// F480: 마운트된 폴더에 대응하는 라이브러리 엔트리 id(최근 배경 push 용). 엔트리 id 가 아닌
    /// 파서 id 를 push 하면 F194 접미 유일화 엔트리와 불일치해 메뉴 표시/적용이 엉뚱한 배경을
    /// 가리켰다. 폴더 경로 일치로 역탐색(북마크 해석은 엔트리 수만큼 — 적용 성공 시 1회).
    /// 대응 엔트리가 없으면(라이브러리 외 경로 등) nil — 파서 id 폴백을 섞지 않는다(같은 불일치 재발).
    private func recentEntryId(mountedFolder: URL?) -> String? {
        guard let mountedFolder else { return nil }
        let target = mountedFolder.standardizedFileURL.path
        let pairs: [(id: String, path: String)] = store.entries.compactMap { entry in
            guard let url = store.resolveFolderURL(for: entry) else { return nil }
            return (entry.id, url.standardizedFileURL.path)
        }
        return RecentWallpapers.entryId(matchingFolderPath: target, entries: pairs)
    }

    func recentMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: NSLocalizedString("최근 배경", comment: ""), action: nil, keyEquivalent: "")
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
            // 생 한국어를 대입하면 :143 에서 NSLocalizedString 으로 만든 제목을 메뉴를 열
            // 때마다 무효화한다 — 영어 UI 에서 "Pause" 로 떴다가 첫 클릭에 한국어로 바뀌었다.
            // 삼항으로 **문자열**을 고르면 두 리터럴 다 오라클 패턴에 안 걸리므로(§5.3)
            // 삼항 밖에서 각각 감싼다.
            pauseMenuItem?.title = pauseGate.isPaused
                ? NSLocalizedString("재개", comment: "트레이 일시정지 항목 — 정지 중")
                : NSLocalizedString("일시정지", comment: "트레이 일시정지 항목 — 재생 중")
            // w5d-tray: 하단 바 NowPlayingBar 의 .disabled(ids.count < 2) 와 대칭.
            nextMenuItem?.isEnabled = PlaylistScheduling.canAdvance(count: playlistStore.ids.count)
            return
        }
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let entries = recentWallpaperIds.compactMap { id in store.entries.first(where: { $0.id == id }) }
        guard !entries.isEmpty else {
            let empty = NSMenuItem(title: NSLocalizedString("(없음)", comment: ""), action: nil, keyEquivalent: "")
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
