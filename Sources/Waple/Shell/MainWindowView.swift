import SwiftUI
import AppKit
import WapleCore
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
    @ObservedObject var banner: StatusBannerModel
    var screenFrames: () -> [CGRect]
    @State private var tab: MainTab = .installed
    @State private var showDisplays = false
    @State private var panelVisible = true
    @State private var showFilterPopover = false
    @State private var showPlaylistConfig = false

    var body: some View {
        VStack(spacing: 0) {
            titleStrip
            tabRow
            if tab == .installed { searchRow }
            content
            bottomBar
        }
        .background(WETheme.Colors.window)
        .ignoresSafeArea()   // fullSizeContentView — 타이틀바 영역까지 우리가 그린다
        .overlay(alignment: .top) { WEStatusBanner(model: banner) }
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

    private var searchRow: some View {
        HStack(spacing: WETheme.Metrics.gap) {
            WESearchField(text: $viewModel.searchText)
                .frame(width: 240)
            Button {
                showFilterPopover.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text("필터 적용 결과")
                }
            }
            .buttonStyle(WEButtonStyle(kind: .accent))
            .popover(isPresented: $showFilterPopover) {
                // 임시(SP2에서 필터 사이드바로 대체): 기존 타입 필터만 노출해 기능 무후퇴.
                Picker("유형", selection: $viewModel.typeFilter) {
                    ForEach(LibraryTypeFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .padding()
                .background(WETheme.Colors.panel)
            }
            Spacer()
            Button {} label: { Image(systemName: "arrowtriangle.up.fill").font(.system(size: 9)) }
                .buttonStyle(WEButtonStyle(kind: .toolbar))
                .disabled(true).opacity(0.55)
                .help("정렬 방향은 SP2에서 제공됩니다")
            WEComboBox(selection: $viewModel.sortOrder,
                       options: Array(LibrarySortOrder.allCases),
                       label: { $0 == .name ? "이름" : "최근 추가순" })
        }
        .padding(.horizontal, WETheme.Metrics.hPad)
        .frame(height: WETheme.Metrics.searchRowH)
        .background(WETheme.Colors.window)
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

    private var bottomBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: WETheme.Metrics.gap) {
                Text("재생목록").font(WETheme.Fonts.sectionBold)
                    .foregroundColor(WETheme.Colors.textPrimary)
                Button { } label: { Label("불러오기", systemImage: "folder.fill") }
                    .buttonStyle(WEButtonStyle()).disabled(true).opacity(0.55)
                    .help("명명 재생목록은 지원 예정입니다")
                Button { } label: { Label("저장", systemImage: "square.and.arrow.down.fill") }
                    .buttonStyle(WEButtonStyle()).disabled(true).opacity(0.55)
                    .help("명명 재생목록은 지원 예정입니다")
                Button { showPlaylistConfig.toggle() } label: { Label("구성", systemImage: "gearshape.2.fill") }
                    .buttonStyle(WEButtonStyle())
                    .popover(isPresented: $showPlaylistConfig) { playlistConfig }
                Button {
                    if let entry = viewModel.focusedEntry { viewModel.togglePlaylist(entry) }
                } label: {
                    Label(playlistAddLabel, systemImage: "plus")
                }
                .buttonStyle(WEButtonStyle(kind: .accent))
                .disabled(viewModel.focusedEntry == nil)
                Spacer()
            }
            HStack(spacing: WETheme.Metrics.gap) {
                Button { } label: { Label("배경화면 편집기", systemImage: "scissors") }
                    .buttonStyle(WEButtonStyle(kind: .largeAccent)).disabled(true).opacity(0.55)
                    .help("에디터는 지원하지 않습니다")
                Button { openWallpaperPanel() } label: { Label("배경화면 열기", systemImage: "square.and.arrow.up") }
                    .buttonStyle(WEButtonStyle(kind: .large))
            }
        }
        .padding(.horizontal, WETheme.Metrics.hPad)
        .padding(.vertical, 8)
        .background(WETheme.Colors.bottomBar)
    }

    private var playlistAddLabel: String {
        guard let e = viewModel.focusedEntry else { return "배경화면 추가" }
        return viewModel.isInPlaylist(e) ? "재생목록에서 제거" : "배경화면 추가"
    }

    /// 기존 하단바 기능(자동 전환·다음·일시정지)을 WE '구성' popover로 수용 — 기능 무후퇴.
    private var playlistConfig: some View {
        VStack(alignment: .leading, spacing: WETheme.Metrics.gap) {
            Toggle("자동 전환 사용", isOn: Binding(
                get: { viewModel.playlist.enabled },
                set: { viewModel.playlist.enabled = $0; viewModel.onPlaylistChanged?() }))
            Stepper("간격: \(viewModel.playlist.intervalMinutes)분", value: Binding(
                get: { viewModel.playlist.intervalMinutes },
                set: { viewModel.playlist.intervalMinutes = $0; viewModel.onPlaylistChanged?() }), in: 1...240)
            HStack {
                Button("다음 배경") { viewModel.onAdvancePlaylist?() }
                    .buttonStyle(WEButtonStyle())
                    .disabled(viewModel.playlist.ids.count < 2)
                Button(viewModel.isPaused ? "재개" : "일시정지") {
                    if let p = viewModel.onTogglePause?() { viewModel.isPaused = p }
                }
                .buttonStyle(WEButtonStyle())
            }
        }
        .padding()
        .frame(width: 260)
        .background(WETheme.Colors.panel)
    }

    /// WE '배경화면 열기' = 디스크에서 임포트(기존 라우팅 재사용: 폴더/zip/동영상).
    private func openWallpaperPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Wallpaper Engine 폴더·상위 폴더·.zip·동영상(mp4/mov)을 선택하세요."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension.lowercased() == "zip" { viewModel.importZip(url) }
        else if VideoImport.isVideoFile(url) { viewModel.importVideoFile(url) }
        else { viewModel.importParent(url) }
    }
}
