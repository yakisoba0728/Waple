import SwiftUI
import AppKit
import WapleCore
import WapleLibrary

/// 네이티브 메인창: 사이드바 + 콘텐츠 + 표준 인스펙터 + 통합 툴바 + Now Playing 바.
/// WE 는 배치 참고만 — 컨트롤·색·재질은 전부 시스템(스펙 2026-07-12 네이티브 재설계).
///
/// ## 2026-08-17 개편: 3탭 세그먼트 → 사이드바 소스리스트
///
/// 종전에는 툴바의 세그먼티드 `Picker` 가 화면 셋(설치됨·검색·창작마당)을 갈랐고, 유형·
/// 즐겨찾기 필터는 좌측의 별도 필터 사이드바에, 상세는 `HStack` 안의 세 번째 열에 있었다.
/// 개편 후 그 셋이 각각 사이드바 항목 · 사이드바 항목 · 표준 인스펙터로 간다.
///
/// ## 실측: 이 조합에서 시스템이 **주지 않는** 것
///
/// 이 앱의 창은 SwiftUI `Scene` 이 아니라 `NSHostingController` + `NSWindow` 이고 툴바만
/// `sceneBridgingOptions` 로 브리징한다. 그 위에서 `NavigationSplitView` 와 `.inspector` 는
/// **정상 동작하지만**(2026-08-17 캡처로 확인), 사이드바 토글과 인스펙터 토글은
/// **자동으로 툴바에 붙지 않는다.** Scene 기반이면 공짜인 두 버튼을 여기서는 직접 만든다.
/// 확인 방법은 단순했다: 직접 만든 토글 둘을 넣고 찍었더니 각각 하나씩만 나왔다 —
/// 시스템이 붙였다면 둘씩 보였을 것이다.
///
/// 열 폭 저장도 없다. 세 번 실행 후 앱 defaults 도메인에 스플릿·사이드바 관련 오토세이브 키가
/// 하나도 생기지 않았다. 그래서 매 실행 `navigationSplitViewColumnWidth` 의 ideal 로 시작한다.
struct MainWindowView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var banner: StatusBannerModel
    @ObservedObject var onboarding: OnboardingModel
    var screenFrames: () -> [CGRect]
    // 워크샵/디스커버 VM 은 창이 소유 — 사이드바를 오가도 결과·다운로드 진행 상태가 유지된다.
    @StateObject private var workshopVM: WorkshopViewModel
    @StateObject private var discoverVM = DiscoverViewModel()

    /// 콘텐츠 표면. 사이드바 선택 중 **라이브러리 계열이 아닌 축**만 여기 남는다 —
    /// 유형·즐겨찾기·폴더는 `viewModel` 이 이미 들고 있고, 두 벌로 두면 갈라진다.
    @State private var surface: ShellSurface = SmokeLaunch.current.selection
        .map(LibrarySection.surface(for:)) ?? .library
    @State private var showDisplays = SmokeLaunch.current.opensDisplays
    @State private var showFilters = false
    @State private var columns: NavigationSplitViewVisibility =
        SmokeLaunch.current.showsSidebar ? .all : .automatic

    init(viewModel: LibraryViewModel, banner: StatusBannerModel, onboarding: OnboardingModel,
         screenFrames: @escaping () -> [CGRect]) {
        self.viewModel = viewModel
        self.banner = banner
        self.onboarding = onboarding
        self.screenFrames = screenFrames
        _workshopVM = StateObject(wrappedValue: WorkshopViewModel(library: viewModel))
    }

    var body: some View {
        VStack(spacing: 0) {
            split
            NowPlayingBar(viewModel: viewModel)
        }
        .frame(minWidth: Metrics.windowMin.width, minHeight: Metrics.windowMin.height)
        .overlay(alignment: .top) { StatusBanner(model: banner) }
        .sheet(isPresented: $showDisplays) {
            DisplaysView(viewModel: viewModel, screenFrames: screenFrames)
        }
        // 사이드바 선택 전환은 이 뷰가 소유한 상태라 AppDelegate 가 아니라 여기서 배선한다
        // (onOpenSettings/onAdvancePlaylist 등 다른 콜백과 달리 창 밖 side-effect 가 아님).
        .onAppear { viewModel.onOpenWorkshop = { select(.workshopSearch) } }
    }

    // MARK: - 열

    private var split: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(viewModel: viewModel, selection: sidebarSelection)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.automatic)
        .modifier(ToolbarSearchField(text: searchText, prompt: searchPrompt, onSubmit: submitSearch))
        .inspector(isPresented: inspectorPresented) { inspector }
        .toolbar { toolbarContent }
        // 최초 실행 온보딩(앱셸 스코프 B). 디스플레이 시트와 다른 뷰에 부착 — 동일 뷰 다중 .sheet 충돌 회피.
        .sheet(isPresented: $onboarding.isPresented) { OnboardingView(model: onboarding) }
    }

    @ViewBuilder
    private var detail: some View {
        switch surface {
        case .library: WallpaperGridView(viewModel: viewModel)
        case .discover: DiscoverView(vm: discoverVM, workshopVM: workshopVM)
        case .workshopSearch: WorkshopTabView(vm: workshopVM)
        }
    }

    /// 인스펙터는 라이브러리 표면에서만 나온다. 창작마당에서도 열려 있으면 **닫을 방법이 없다** —
    /// 토글 버튼은 라이브러리 전용이라 툴바에서 사라지는데 패널만 남는다(첫 캡처에서 실제로 그랬다).
    /// 저장은 계속 `viewModel.panelVisible` 한 벌이다. 게터에만 표면 조건을 얹고 세터는 라이브러리에서만
    /// 쓰게 막아, 창작마당으로 이동했다는 이유로 사용자의 접기/펴기 선택이 지워지지 않게 한다.
    private var inspectorPresented: Binding<Bool> {
        Binding(get: { surface == .library && viewModel.panelVisible },
                set: { shown in
                    guard surface == .library else { return }
                    viewModel.panelVisible = shown
                })
    }

    @ViewBuilder
    private var inspector: some View {
        SelectionPanelView(viewModel: viewModel)
            .inspectorColumnWidth(min: Metrics.inspectorMin,
                                  ideal: Metrics.inspectorIdeal,
                                  max: Metrics.inspectorMax)
    }

    // MARK: - 선택

    /// 사이드바 선택. **저장하지 않고 유도한다** — 툴바 필터도 같은 `criteria` 를 쓰므로
    /// 별도 `@State` 로 두면 필터로 유형을 바꿨을 때 하이라이트가 거짓말을 한다.
    private var sidebarSelection: Binding<LibrarySelection?> {
        Binding(get: { LibrarySection.selection(for: shellState) },
                set: { if let new = $0 { select(new) } })
    }

    private var shellState: ShellState {
        ShellState(surface: surface, criteria: viewModel.criteria, folder: viewModel.activeFolder)
    }

    private func select(_ selection: LibrarySelection) {
        let next = LibrarySection.applying(selection, to: shellState)
        surface = next.surface
        viewModel.criteria = next.criteria
        viewModel.activeFolder = next.folder
    }

    // MARK: - 검색

    /// 표면마다 검색이 향하는 곳이 다르다. 둘러보기는 큐레이션 레일이라 검색이 없으므로 nil —
    /// 아무것도 거르지 않는 검색창을 띄우는 것보다 없는 편이 정직하다.
    private var searchText: Binding<String>? {
        switch surface {
        case .library: return $viewModel.searchText
        case .workshopSearch: return $workshopVM.searchText
        case .discover: return nil
        }
    }

    private var searchPrompt: Text {
        surface == .workshopSearch ? Text("워크샵 검색") : Text("검색")
    }

    private func submitSearch() {
        guard surface == .workshopSearch else { return }
        Task { await workshopVM.search() }
    }

    // MARK: - 툴바

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { Motion.run(Motion.reveal) { toggleSidebar() } } label: {
                Label("사이드바", systemImage: "sidebar.leading")
            }
            .help("사이드바")
        }
        ToolbarItemGroup {
            if surface == .library { filterButton }
            sortMenu
            Button {} label: { Label("모바일", systemImage: "iphone") }
                .disabled(true)
                .help("모바일 페어링은 지원하지 않습니다")
            Button { showDisplays = true } label: { Label("디스플레이", systemImage: "display") }
                .help("모니터별 배경 할당")
            Button { viewModel.onOpenSettings?() } label: { Label("설정", systemImage: "gearshape") }
                .help("설정")
            if surface == .library { inspectorToggle }
        }
    }

    private func toggleSidebar() {
        columns = (columns == .detailOnly) ? .all : .detailOnly
    }

    /// 태그·나이 등급처럼 값이 동적이고 희소하게 쓰이는 축. 사이드바에 상주시키면 사이드바가
    /// 길어지므로 툴바 팝오버로 뺀다. 내용은 종전 필터 뷰를 그대로 재사용한다 —
    /// 전용 팝오버 뷰는 Phase 2(Unit B) 소관이고, 셸 교체와 섞으면 회귀 원인을 못 가린다.
    private var filterButton: some View {
        Button { showFilters.toggle() } label: {
            Label("필터", systemImage: viewModel.criteria.isActive
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help("필터")
        .popover(isPresented: $showFilters, arrowEdge: .bottom) {
            FilterSidebarView(viewModel: viewModel)
        }
    }

    /// 종전 `Picker(.menu)` 는 툴바에서 라벨 없는 작은 쉐브론처럼 렌더돼 무엇을 하는
    /// 컨트롤인지 화면에서 읽히지 않았다(캡처 확인). 아이콘 + 접근성 이름이 붙는
    /// `Menu` + `Label` 형태로 바꾼다 — 아이콘 전용 툴바 버튼 규약과도 맞는다.
    @ViewBuilder
    private var sortMenu: some View {
        switch surface {
        case .library:
            Menu {
                Picker("정렬", selection: $viewModel.sortOrder) {
                    ForEach(LibrarySortOrder.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("정렬", systemImage: "arrow.up.arrow.down")
            }
            .help("정렬")
        case .workshopSearch:
            Menu {
                Picker("정렬", selection: $workshopVM.sort) {
                    ForEach(WorkshopSort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("정렬", systemImage: "arrow.up.arrow.down")
            }
            .disabled(!workshopVM.hasAPIKey)
            .help("정렬")
        case .discover:
            EmptyView()
        }
    }

    private var inspectorToggle: some View {
        Button { Motion.run(Motion.reveal) { viewModel.panelVisible.toggle() } } label: {
            Label("정보 패널", systemImage: "sidebar.trailing")
        }
        .help("정보 패널")
    }
}

/// 툴바 검색 필드. 표면에 따라 붙였다 뗐다 해야 해서 모디파이어로 뺐다 —
/// 뷰 빌더 안에서 `.searchable` 을 조건 분기하면 그 자리의 식이 두 벌로 늘어난다(타입체커).
///
/// 시스템 서치필드를 쓰는 이유: ⌘F·Esc 취소·접근성 이름·플레이스홀더를 공짜로 받는다.
/// 종전 `TextField(...).frame(width: 190)` 은 그 전부를 잃고 있었다.
private struct ToolbarSearchField: ViewModifier {
    let text: Binding<String>?
    let prompt: Text
    let onSubmit: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text {
            content
                .searchable(text: text, placement: .toolbar, prompt: prompt)
                .onSubmit(of: .search, onSubmit)
        } else {
            content
        }
    }
}
