import SwiftUI
import WapleLibrary
import WapleRender

enum MainTab: String, CaseIterable {
    case installed, discover, workshop
    var label: String {
        switch self {
        case .installed: return "설치됨"; case .discover: return "검색"; case .workshop: return "창작마당"
        }
    }
    var icon: String {
        switch self {
        case .installed: return "square.and.arrow.down.fill"
        case .discover: return "safari"
        case .workshop: return "globe"
        }
    }
}

/// WE 2.8.42 셸: 타이틀 스트립 → 탭줄 → (탭 콘텐츠) → 하단 바. 수치는 전부 WETheme.
struct MainWindowView: View {
    @ObservedObject var viewModel: LibraryViewModel
    var screenFrames: () -> [CGRect]
    @State private var tab: MainTab = .installed
    @State private var showDisplays = false
    @State private var panelVisible = true

    var body: some View {
        VStack(spacing: 0) {
            titleStrip
            tabRow
            content
            // 하단 바는 Task 7에서 추가
        }
        .background(WETheme.Colors.window)
        .ignoresSafeArea()   // fullSizeContentView — 타이틀바 영역까지 우리가 그린다
        .sheet(isPresented: $showDisplays) {
            DisplaysTabView(viewModel: viewModel, screenFrames: screenFrames)
                .frame(minWidth: 900, minHeight: 560)
                .background(WETheme.Colors.panel)
        }
    }

    /// WE 타이틀바: 좌 상태 텍스트(신호등 우측) · 중앙 타이틀 · 우측 » 패널 토글.
    private var titleStrip: some View {
        ZStack {
            Text("Waple — Wallpaper Engine 호환")
                .font(WETheme.Fonts.title)
                .foregroundColor(WETheme.Colors.textSecondary)
            HStack(spacing: 0) {
                if !SteamCmdDownloader.isAvailable {
                    Text("steamcmd를 사용할 수 없습니다.")
                        .font(WETheme.Fonts.caption)
                        .foregroundColor(WETheme.Colors.danger)
                        .padding(.leading, WETheme.Metrics.trafficLightInset)
                }
                Spacer()
                Button {
                    panelVisible.toggle()
                } label: {
                    Image(systemName: panelVisible ? "chevron.right.2" : "chevron.left.2")
                        .font(WETheme.Fonts.body)
                        .foregroundColor(WETheme.Colors.textPrimary)
                        .frame(width: 34, height: WETheme.Metrics.titlebarH - 8)
                        .background(WETheme.Colors.accent)
                        .cornerRadius(WETheme.Metrics.corner)
                }
                .buttonStyle(.plain)
                .padding(.trailing, WETheme.Metrics.hPad)
            }
        }
        .frame(height: WETheme.Metrics.titlebarH)
        .background(WETheme.Colors.titlebar)
    }

    /// 탭 3개(좌) + 모바일/디스플레이/설정 버튼(우).
    private var tabRow: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases, id: \.self) { t in
                WETabButton(title: t.label, systemImage: t.icon, isActive: tab == t,
                            hasDropdown: t == .installed) { tab = t }
            }
            Spacer()
            WETopButton(title: "모바일", systemImage: "iphone",
                        disabledHint: "모바일 페어링은 지원하지 않습니다") {}
            WETopButton(title: "디스플레이", systemImage: "display") { showDisplays = true }
            WETopButton(title: "설정", systemImage: "gearshape.fill",
                        disabledHint: "설정 창은 곧 제공됩니다(SP5)") {}
        }
        .padding(.horizontal, WETheme.Metrics.hPad)
        .frame(height: WETheme.Metrics.tabRowH)
        .background(WETheme.Colors.tabRow)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .installed:
            HStack(spacing: 0) {
                WallpaperGridView(viewModel: viewModel)   // SP2에서 WE 그리드로 교체
                if panelVisible {
                    Divider().overlay(WETheme.Colors.border)
                    SelectionPanelView(viewModel: viewModel)  // SP2에서 WE 패널로 교체
                }
            }
        case .discover:
            VStack {
                Spacer()
                Text("검색(디스커버) 탭은 SP4에서 제공됩니다")
                    .font(WETheme.Fonts.body).foregroundColor(WETheme.Colors.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .workshop:
            WorkshopView(library: viewModel)   // SP4에서 WE 창작마당으로 교체
        }
    }
}
