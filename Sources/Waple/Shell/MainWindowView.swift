import SwiftUI
import AppKit
import WapleCore
import WapleLibrary

enum MainTab: String, CaseIterable, Identifiable {
    case installed, discover, workshop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .installed: return "설치됨"; case .discover: return "검색"; case .workshop: return "창작마당"
        }
    }
}

/// 네이티브 메인창: 통합 툴바(탭 세그먼트·탭별 검색/정렬·패널 토글) + 콘텐츠 + Now Playing 바.
/// WE는 배치 참고만 — 컨트롤·색·재질은 전부 시스템(스펙 2026-07-12 네이티브 재설계).
struct MainWindowView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var banner: StatusBannerModel
    @ObservedObject var onboarding: OnboardingModel
    var screenFrames: () -> [CGRect]
    // 워크샵/디스커버 VM 은 창이 소유 — 탭을 오가도 결과·다운로드 진행 상태가 유지된다.
    @StateObject private var workshopVM: WorkshopViewModel
    @StateObject private var discoverVM = DiscoverViewModel()
    // WAPLE_SMOKE_TAB=discover|workshop — 캡처용 초기 탭 강제(스모크 규약, MainTab.rawValue)
    @State private var tab: MainTab =
        ProcessInfo.processInfo.environment["WAPLE_SMOKE_TAB"].flatMap(MainTab.init(rawValue:)) ?? .installed
    @State private var showDisplays = ProcessInfo.processInfo.environment["WAPLE_SMOKE_DISPLAYS"] != nil
    @State private var showFilters = ProcessInfo.processInfo.environment["WAPLE_SMOKE"] != nil  // 스모크 캡처용 기본 노출
    @State private var panelVisible = true

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
            content
                // 최초 실행 온보딩(앱셸 스코프 B). 디스플레이 시트와 다른 뷰에 부착 — 동일 뷰 다중 .sheet 충돌 회피.
                .sheet(isPresented: $onboarding.isPresented) { OnboardingView(model: onboarding) }
            NowPlayingBar(viewModel: viewModel)
        }
        .frame(minWidth: Metrics.windowMin.width, minHeight: Metrics.windowMin.height)
        .overlay(alignment: .top) { StatusBanner(model: banner) }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showDisplays) {
            DisplaysView(viewModel: viewModel, screenFrames: screenFrames)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("보기", selection: $tab) {
                ForEach(MainTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarItemGroup {
            switch tab {
            case .installed:
                TextField("검색", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Metrics.searchFieldWidth)
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showFilters.toggle() } } label: {
                    Label("필터", systemImage: viewModel.criteria.isActive
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .help("필터 사이드바")
                Picker("정렬", selection: $viewModel.sortOrder) {
                    ForEach(LibrarySortOrder.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .help("정렬")
            case .workshop:
                TextField("워크샵 검색", text: $workshopVM.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Metrics.searchFieldWidth)
                    .onSubmit { Task { await workshopVM.search() } }
                    .disabled(!workshopVM.hasAPIKey)
                Picker("정렬", selection: $workshopVM.sort) {
                    ForEach(WorkshopSort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(!workshopVM.hasAPIKey)
                .help("정렬")
            case .discover:
                EmptyView()   // 디스커버는 큐레이션 레일 — 텍스트 검색은 창작마당 탭 전담
            }
            Button {} label: { Label("모바일", systemImage: "iphone") }
                .disabled(true)
                .help("모바일 페어링은 지원하지 않습니다")
            Button { showDisplays = true } label: { Label("디스플레이", systemImage: "display") }
                .help("모니터별 배경 할당")
            Button { viewModel.onOpenSettings?() } label: { Label("설정", systemImage: "gearshape") }
                .help("설정")
            if tab == .installed {
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { panelVisible.toggle() } } label: {
                    Label("정보 패널", systemImage: "sidebar.trailing")
                }
                .help(panelVisible ? "정보 패널 숨기기" : "정보 패널 보기")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .installed:
            HStack(spacing: 0) {
                if showFilters {
                    FilterSidebarView(viewModel: viewModel)
                        .transition(.move(edge: .leading))
                    Divider()
                }
                WallpaperGridView(viewModel: viewModel)
                if panelVisible {
                    Divider()
                    SelectionPanelView(viewModel: viewModel)
                        .transition(.move(edge: .trailing))
                }
            }
        case .discover:
            DiscoverView(vm: discoverVM, workshopVM: workshopVM)
        case .workshop:
            WorkshopTabView(vm: workshopVM)
        }
    }
}
