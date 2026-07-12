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

/// 네이티브 메인창: 통합 툴바(탭 세그먼트·검색·필터·정렬·패널 토글) + 콘텐츠 + Now Playing 바.
/// WE는 배치 참고만 — 컨트롤·색·재질은 전부 시스템(스펙 2026-07-12 네이티브 재설계).
struct MainWindowView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var banner: StatusBannerModel
    var screenFrames: () -> [CGRect]
    @State private var tab: MainTab = .installed
    @State private var showDisplays = false
    @State private var showFilters = false      // SP2′에서 사이드바로 승격 — 지금은 popover
    @State private var panelVisible = true

    var body: some View {
        VStack(spacing: 0) {
            content
            NowPlayingBar(viewModel: viewModel)
        }
        .frame(minWidth: Layout.windowMin.width, minHeight: Layout.windowMin.height)
        .overlay(alignment: .top) { WEStatusBanner(model: banner) }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showDisplays) {
            VStack(spacing: 0) {
                DisplaysTabView(viewModel: viewModel, screenFrames: screenFrames)
                HStack {
                    Spacer()
                    Button("닫기") { showDisplays = false }.keyboardShortcut(.cancelAction)
                }
                .padding()
            }
            .frame(minWidth: 860, minHeight: 540)
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
            if tab == .installed {
                TextField("검색", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                Button { showFilters.toggle() } label: {
                    Label("필터", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("유형 필터")
                .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                    // 임시(SP2′에서 필터 사이드바로 대체) — 기능 무후퇴용 최소 노출.
                    Picker("유형", selection: $viewModel.typeFilter) {
                        ForEach(LibraryTypeFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .padding(12)
                }
                Picker("정렬", selection: $viewModel.sortOrder) {
                    ForEach(LibrarySortOrder.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .help("정렬")
            }
            Button {} label: { Label("모바일", systemImage: "iphone") }
                .disabled(true)
                .help("모바일 페어링은 지원하지 않습니다")
            Button { showDisplays = true } label: { Label("디스플레이", systemImage: "display") }
                .help("모니터별 배경 할당")
            Button {} label: { Label("설정", systemImage: "gearshape") }
                .disabled(true)
                .help("설정 창은 곧 제공됩니다(SP5′)")
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { panelVisible.toggle() } } label: {
                Label("정보 패널", systemImage: "sidebar.trailing")
            }
            .help(panelVisible ? "정보 패널 숨기기" : "정보 패널 보기")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .installed:
            HStack(spacing: 0) {
                WallpaperGridView(viewModel: viewModel)
                if panelVisible {
                    Divider()
                    SelectionPanelView(viewModel: viewModel)
                        .transition(.move(edge: .trailing))
                }
            }
        case .discover:
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "safari").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("검색 탭은 준비 중입니다").font(.title3)
                Text("창작마당 탭에서 Steam 워크샵을 검색할 수 있습니다")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .workshop:
            WorkshopView(library: viewModel)
        }
    }
}
