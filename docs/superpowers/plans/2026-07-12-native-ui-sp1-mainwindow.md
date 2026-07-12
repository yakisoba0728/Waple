# SP1′: 메인창 전체 네이티브 재구축 Implementation Plan

> 상태: **완료·판정 통과(2026-07-12)** + 후속 수정 3건(Metrics 개명·gif 셀 오버플로·scaledToFill).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** WE 픽셀 클론 스킨을 걷어내고, 메인창 전체(툴바 크롬·그리드·상세 패널·Now Playing 바·배너)를 네이티브 SwiftUI/macOS 디자인(항상 다크)으로 재구축한다. WE는 배치 참고만.

**Architecture:** 커스텀 hex 토큰(WETheme)·커스텀 컨트롤(WEControls) 삭제 → 시맨틱 컬러/시스템 재질/네이티브 컨트롤. 치수 상수만 `Layout`으로 유지. 시그니처는 하단 Now Playing 바 하나. ViewModel 배선·데이터 계층 무변경.

**Tech Stack:** SwiftUI(macOS 13+), NSToolbar(unified, sceneBridgingOptions), 외부 의존성 0. 스펙: [2026-07-12-native-ui-redesign.md](../specs/2026-07-12-native-ui-redesign.md)

## Global Constraints

- macOS 13+, Swift 5.9, 외부 SPM 의존성 0.
- **커스텀 hex 색 금지** — `Color(nsColor:)` 시맨틱/시스템 재질/`accentColor`만. 치수는 `Layout` 상수만(뷰 리터럴 금지: 4/6/8 수준 미세 패딩은 예외 허용).
- 다크 강제(`darkAqua`) 유지. 아이콘은 SF Symbols.
- 커밋 메시지 `기능(ui): …`/`정리: …` 리포 관례, 한국어. push 금지, main 직접 커밋.
- 매 태스크: `swift build` 성공 + `swift test --filter WapleAppTests` 그린 후 커밋.
- 기존 ViewModel/스토어 API 시그니처 변경 금지. `MainWindowView(viewModel:banner:screenFrames:)` 시그니처 유지.
- macOS에 `timeout` 없음 — 스모크는 백그라운드+kill 패턴.
- 캡처 이미지를 리포에 커밋하지 말 것(/tmp에만 — 사생활).

---

### Task 1: 클론 잔재 정리

**Files:**
- Delete: `scripts/we-compare.sh`, `docs/reference/we/waple-sp1.png`

**Interfaces:**
- Produces: 없음(삭제만). WETheme/WEControls 삭제는 소비자가 사라지는 Task 7에서.

- [ ] **Step 1: 삭제 + 빌드 확인**

```bash
git rm scripts/we-compare.sh docs/reference/we/waple-sp1.png
swift build 2>&1 | tail -2
```
Expected: `Build complete!`

- [ ] **Step 2: Commit**

```bash
git commit -m "정리: 픽셀 클론 검증 도구·캡처 산출물 제거 (네이티브 재설계 피벗)"
```

---

### Task 2: Layout — 치수 상수

**Files:**
- Create: `Sources/Waple/DesignSystem/Layout.swift`

**Interfaces:**
- Produces: `enum Layout` — `tileWidth/tileThumbHeight/tileCorner/gridSpacing/panelWidth/heroHeight/nowPlayingHeight/nowPlayingThumb: CGFloat`, `windowDefault/windowMin: NSSize`. 이후 전 태스크가 소비.

- [ ] **Step 1: 구현**

`Sources/Waple/DesignSystem/Layout.swift`:

```swift
import AppKit
import SwiftUI

/// 네이티브 재설계 치수 상수. 색 토큰 없음 — 색은 시맨틱 컬러/시스템 재질만 쓴다(스펙 §2).
enum Layout {
    // 그리드 타일(16:10 썸네일 + 아래 제목)
    static let tileWidth: CGFloat = 200
    static let tileThumbHeight: CGFloat = 125
    static let tileCorner: CGFloat = 8
    static let gridSpacing: CGFloat = 14

    // 우측 상세 패널
    static let panelWidth: CGFloat = 300
    static let heroHeight: CGFloat = 170

    // 하단 Now Playing 바
    static let nowPlayingHeight: CGFloat = 56
    static let nowPlayingThumb: CGFloat = 40

    // 창
    static let windowDefault = NSSize(width: 1280, height: 820)
    static let windowMin = NSSize(width: 1024, height: 680)
}
```

- [ ] **Step 2: 빌드 + Commit**

```bash
swift build 2>&1 | tail -2
git add Sources/Waple/DesignSystem/Layout.swift
git commit -m "기능(ui): Layout 치수 상수 — 네이티브 재설계 (색 토큰 없음)"
```

---

### Task 3: NowPlayingBar — 시그니처 컴포넌트

**Files:**
- Create: `Sources/Waple/Shell/NowPlayingBar.swift`
- Test: `Tests/WapleAppTests/NowPlayingSubtitleTests.swift`

**Interfaces:**
- Consumes: `Layout`(Task 2), 기존 `LibraryViewModel`(entries·selectedId·isPaused·onTogglePause·onAdvancePlaylist·playlist·focusedEntry·togglePlaylist·isInPlaylist·previewURL·importZip/importVideoFile/importParent), `AnimatedPreviewView`, `PreviewMedia`, `VideoImport`.
- Produces: `struct NowPlayingBar: View` — `init(viewModel: LibraryViewModel)`.
  `enum NowPlayingSubtitle { static func text(typeRaw: String?, playlistCount: Int, intervalMinutes: Int, playlistEnabled: Bool) -> String }` (순수 — 테스트 대상).

- [ ] **Step 1: 실패 테스트 작성**

`Tests/WapleAppTests/NowPlayingSubtitleTests.swift`:

```swift
import XCTest
@testable import Waple

final class NowPlayingSubtitleTests: XCTestCase {
    func testNoWallpaper() {
        XCTAssertEqual(NowPlayingSubtitle.text(typeRaw: nil, playlistCount: 0,
                                               intervalMinutes: 30, playlistEnabled: false),
                       "라이브러리에서 배경을 선택하세요")
    }

    func testTypeOnly() {
        XCTAssertEqual(NowPlayingSubtitle.text(typeRaw: "scene", playlistCount: 0,
                                               intervalMinutes: 30, playlistEnabled: false),
                       "장면")
    }

    func testTypeWithPlaylistOff() {
        XCTAssertEqual(NowPlayingSubtitle.text(typeRaw: "video", playlistCount: 3,
                                               intervalMinutes: 15, playlistEnabled: false),
                       "동영상 · 재생목록 3개")
    }

    func testTypeWithPlaylistOn() {
        XCTAssertEqual(NowPlayingSubtitle.text(typeRaw: "web", playlistCount: 5,
                                               intervalMinutes: 15, playlistEnabled: true),
                       "웹 · 재생목록 5개 · 15분마다 전환")
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter NowPlayingSubtitleTests`
Expected: FAIL — `cannot find 'NowPlayingSubtitle'`.

- [ ] **Step 3: 구현**

`Sources/Waple/Shell/NowPlayingBar.swift`:

```swift
import SwiftUI
import AppKit
import WapleCore
import WapleLibrary

/// Now Playing 부제(순수): 타입 라벨 + 재생목록 상태. 뷰와 분리해 단위 테스트.
enum NowPlayingSubtitle {
    static func text(typeRaw: String?, playlistCount: Int, intervalMinutes: Int, playlistEnabled: Bool) -> String {
        guard let typeRaw else { return "라이브러리에서 배경을 선택하세요" }
        var parts = [typeLabel(typeRaw)]
        if playlistCount > 0 { parts.append("재생목록 \(playlistCount)개") }
        if playlistEnabled, playlistCount > 0 { parts.append("\(intervalMinutes)분마다 전환") }
        return parts.joined(separator: " · ")
    }

    static func typeLabel(_ raw: String) -> String {
        switch WallpaperType.from(raw) {
        case .scene: return "장면"
        case .video: return "동영상"
        case .web: return "웹"
        case .preset: return "프리셋"
        case .application: return "응용 프로그램"
        case .unknown(let s): return s
        }
    }
}

/// 시그니처: 하단 Now Playing 바 — 적용 중 배경의 애니 썸네일·제목 상시 + 재생 컨트롤 + 재생목록 + 가져오기.
struct NowPlayingBar: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var showPlaylist = false

    private var appliedEntry: LibraryEntry? {
        viewModel.entries.first { $0.id == viewModel.selectedId }
    }

    var body: some View {
        HStack(spacing: 12) {
            thumb
            VStack(alignment: .leading, spacing: 2) {
                Text(appliedEntry?.title ?? "적용된 배경 없음")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(NowPlayingSubtitle.text(typeRaw: appliedEntry?.typeRaw,
                                             playlistCount: viewModel.playlist.ids.count,
                                             intervalMinutes: viewModel.playlist.intervalMinutes,
                                             playlistEnabled: viewModel.playlist.enabled))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 380, alignment: .leading)

            Spacer()

            Button {
                if let paused = viewModel.onTogglePause?() { viewModel.isPaused = paused }
            } label: {
                Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .help(viewModel.isPaused ? "재생" : "일시정지")

            Button { viewModel.onAdvancePlaylist?() } label: {
                Image(systemName: "forward.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.playlist.ids.count < 2)
            .help("다음 배경")

            Divider().frame(height: 24)

            Button { showPlaylist.toggle() } label: {
                Label("재생목록", systemImage: "music.note.list")
            }
            .popover(isPresented: $showPlaylist, arrowEdge: .top) { playlistPopover }

            Button { openWallpaperPanel() } label: {
                Label("가져오기", systemImage: "plus")
            }
            .help("Wallpaper Engine 폴더·zip·동영상 가져오기")
        }
        .padding(.horizontal, 16)
        .frame(height: Layout.nowPlayingHeight)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var thumb: some View {
        Group {
            if let e = appliedEntry, let url = viewModel.previewURL(for: e) {
                AnimatedPreviewView(url: url, animating: !viewModel.isPaused)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
            }
        }
        .frame(width: Layout.nowPlayingThumb, height: Layout.nowPlayingThumb)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 재생목록 관리: 자동 전환·간격 + 선택 항목 추가/제거 + 목록.
    private var playlistPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("자동 전환", isOn: Binding(
                get: { viewModel.playlist.enabled },
                set: { viewModel.playlist.enabled = $0; viewModel.onPlaylistChanged?() }))
            Stepper("간격: \(viewModel.playlist.intervalMinutes)분", value: Binding(
                get: { viewModel.playlist.intervalMinutes },
                set: { viewModel.playlist.intervalMinutes = $0; viewModel.onPlaylistChanged?() }), in: 1...240)
            if let focused = viewModel.focusedEntry {
                Button(viewModel.isInPlaylist(focused) ? "'\(focused.title)' 제거" : "'\(focused.title)' 추가") {
                    viewModel.togglePlaylist(focused)
                }
            }
            Divider()
            if viewModel.playlist.ids.isEmpty {
                Text("재생목록이 비어 있습니다 — 타일 우클릭 또는 위 버튼으로 추가하세요")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.playlist.ids, id: \.self) { id in
                    Text(viewModel.entries.first { $0.id == id }?.title ?? id)
                        .font(.caption).lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    /// '가져오기' = 디스크에서 임포트(기존 라우팅 재사용: 폴더/zip/동영상).
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
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter NowPlayingSubtitleTests && swift test --filter WapleAppTests 2>&1 | tail -2`
Expected: PASS (신규 4건 포함).

- [ ] **Step 5: Commit**

```bash
git add Sources/Waple/Shell/NowPlayingBar.swift Tests/WapleAppTests/NowPlayingSubtitleTests.swift
git commit -m "기능(ui): Now Playing 바 — 적용 배경 썸네일·제목 + 재생/다음/재생목록/가져오기 (시그니처)"
```

---

### Task 4: 네이티브 크롬 — 통합 툴바 + MainWindowView 재작성

**Files:**
- Modify: `Sources/Waple/Shell/MainWindowView.swift` (전체 교체)
- Modify: `Sources/Waple/AppDelegate.swift` (openLibrary 창 설정)

**Interfaces:**
- Consumes: `NowPlayingBar`(Task 3), `Layout`(Task 2), 기존 `WallpaperGridView`/`SelectionPanelView`/`WorkshopView`/`DisplaysTabView`/`WEStatusBanner`(Task 7에서 rename 전까지 기존 이름), `LibraryTypeFilter`/`LibrarySortOrder`.
- Produces: `MainWindowView` — **기존 시그니처 유지** `init(viewModel: LibraryViewModel, banner: StatusBannerModel, screenFrames: @escaping () -> [CGRect])`. `enum MainTab { case installed, discover, workshop }` 유지(케이스 동일).
- 창 규약 변경: fullSizeContentView·투명 타이틀바 **철회** → 표준 타이틀바 + `toolbarStyle = .unified` + `hosting.sceneBridgingOptions = [.toolbars]`.

- [ ] **Step 1: AppDelegate 창 설정 교체**

`openLibrary()`의 창 생성부를 다음으로 교체(`isReleasedWhenClosed` 주석·`window.appearance` 주석은 유지):

```swift
let root = MainWindowView(viewModel: libraryVM, banner: bannerModel,
                          screenFrames: { NSScreen.screens.map(\.frame) })
let hosting = NSHostingController(rootView: root)
hosting.sceneBridgingOptions = [.toolbars]   // SwiftUI .toolbar → NSToolbar 브리징(macOS 13+)
let window = NSWindow(contentViewController: hosting)
window.title = "Waple"
window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
window.toolbarStyle = .unified
window.setContentSize(Layout.windowDefault)
window.minSize = Layout.windowMin
window.appearance = NSAppearance(named: .darkAqua)   // WE 관례 — 항상 다크
window.isReleasedWhenClosed = false
```

(titlebarAppearsTransparent/titleVisibility/backgroundColor 설정 줄은 제거.)

- [ ] **Step 2: MainWindowView 전체 재작성**

`Sources/Waple/Shell/MainWindowView.swift` 내용 전체 교체:

```swift
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
```

- [ ] **Step 3: 빌드 + 테스트 + 스모크**

Run: `swift build && swift test --filter WapleAppTests 2>&1 | tail -2 && { WAPLE_SMOKE=1 .build/debug/Waple & APP=$!; sleep 5; screencapture -x /tmp/sp1n-t4.png; kill $APP; }`
Expected: 그린. 캡처에서 **통합 툴바에 세그먼트 탭·검색·버튼들이 보여야 함.**
**폴백:** `.toolbar` 아이템이 안 뜨면(스모크 캡처에 툴바 없음) `sceneBridgingOptions` 문제 — 그 경우 `VStack` 최상단에 커스텀 바(`.background(.bar)`, 동일 컨트롤 배치)로 전환하고 최종 보고에 편차 기록.

- [ ] **Step 4: Commit**

```bash
git add Sources/Waple/Shell/MainWindowView.swift Sources/Waple/AppDelegate.swift
git commit -m "기능(ui): 네이티브 통합 툴바 크롬 — 세그먼트 탭·검색·필터·정렬·패널 토글 + Now Playing 통합"
```

---

### Task 5: 그리드 재작성 — 네이티브 타일

**Files:**
- Modify: `Sources/Waple/WallpaperGridView.swift` (전체 교체)

**Interfaces:**
- Consumes: `Layout`, 기존 `viewModel`(filteredEntries·isSupported·focusedId·selectedId·apply·previewURL·onOpenInteraction·togglePlaylist·isInPlaylist·screens·assign·clearAssignment·assignedEntryTitle·importParent/importZip/importVideoFile), `PreviewMedia`/`AnimatedPreviewView`/`PreviewImageCache`(파일 내 기존 private 캐시 유지).
- Produces: `WallpaperGridView` — `init(viewModel: LibraryViewModel)` 유지. 임포트/드롭/컨텍스트 메뉴 로직은 기존 코드 그대로 보존(아래 코드에 포함).

- [ ] **Step 1: 전체 교체**

`Sources/Waple/WallpaperGridView.swift`:

```swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WapleCore
import WapleLibrary

/// 미리보기 이미지 디코드 캐시(URL→NSImage). body 재평가마다의 반복 디스크 I/O 제거.
private enum PreviewImageCache {
    private static let cache = NSCache<NSURL, NSImage>()
    static func image(_ url: URL) -> NSImage? {
        if let c = cache.object(forKey: url as NSURL) { return c }
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

/// 네이티브 그리드: underPage 우물 + 라운드 썸네일 타일(제목 아래) + 호버 라이브 프리뷰/리프트 +
/// 적용 중 액센트 링. 클릭=선택, 더블클릭=적용(기존 UX 유지).
struct WallpaperGridView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var hoveredId: String?

    private let columns = [GridItem(.adaptive(minimum: Layout.tileWidth), spacing: Layout.gridSpacing)]

    var body: some View {
        Group {
            if viewModel.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Layout.gridSpacing + 6) {
                        ForEach(viewModel.filteredEntries, id: \.id) { entry in
                            tile(for: entry)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop($0) }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("라이브러리가 비어 있습니다").font(.title3.weight(.semibold))
            Text("Wallpaper Engine 폴더·zip·동영상을 드래그하거나 가져오세요")
                .font(.callout).foregroundStyle(.secondary)
            Button("배경화면 가져오기…") { importFolder() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tile(for entry: LibraryEntry) -> some View {
        let supported = viewModel.isSupported(entry)
        let focused = viewModel.focusedId == entry.id
        let applied = viewModel.selectedId == entry.id
        let hovered = hoveredId == entry.id

        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                preview(for: entry, animating: hovered)
                    .frame(height: Layout.tileThumbHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: Layout.tileCorner))
            .overlay(
                RoundedRectangle(cornerRadius: Layout.tileCorner)
                    .stroke(applied ? Color.accentColor : (focused ? Color.secondary.opacity(0.6) : .clear),
                            lineWidth: applied ? 2.5 : 1.5)
            )
            .overlay(alignment: .topTrailing) { typeBadge(for: entry, supported: supported) }
            .overlay(alignment: .bottomLeading) {
                if applied {
                    Image(systemName: "play.circle.fill")
                        .font(.body)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                }
            }
            .saturation(supported ? 1 : 0.4)
            .opacity(supported ? 1 : 0.55)

            Text(entry.title)
                .font(.caption)
                .foregroundStyle(focused ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .scaleEffect(hovered ? 1.02 : 1)
        .shadow(color: .black.opacity(hovered ? 0.45 : 0), radius: 9, y: 5)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovered)
        .contentShape(Rectangle())
        .onHover { hoveredId = $0 ? entry.id : (hoveredId == entry.id ? nil : hoveredId) }
        .onTapGesture(count: 2) { if supported { _ = viewModel.apply(entry) } }
        .onTapGesture { viewModel.focusedId = entry.id }
        .contextMenu { contextMenu(for: entry, supported: supported) }
    }

    private func typeBadge(for entry: LibraryEntry, supported: Bool) -> some View {
        Label(supported ? NowPlayingSubtitle.typeLabel(entry.typeRaw) : "지원 예정",
              systemImage: typeSymbol(entry.typeRaw))
            .font(.caption2)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(6)
    }

    private func typeSymbol(_ raw: String) -> String {
        switch WallpaperType.from(raw) {
        case .scene: return "sparkles"
        case .video: return "play.rectangle.fill"
        case .web: return "globe"
        case .preset: return "square.stack"
        case .application, .unknown: return "questionmark.circle"
        }
    }

    @ViewBuilder
    private func preview(for entry: LibraryEntry, animating: Bool) -> some View {
        if let url = viewModel.previewURL(for: entry) {
            if PreviewMedia.isAnimated(url) {
                AnimatedPreviewView(url: url, animating: animating)
            } else if let image = PreviewImageCache.image(url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholderThumb
            }
        } else {
            placeholderThumb
        }
    }

    private var placeholderThumb: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
            Image(systemName: "photo").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: LibraryEntry, supported: Bool) -> some View {
        Button("선택(속성 보기)") { viewModel.focusedId = entry.id }
        if supported { Button("적용") { _ = viewModel.apply(entry) } }
        if WallpaperType.from(entry.typeRaw) == .web {
            Button("적용 + 조작 창 열기") { _ = viewModel.apply(entry); viewModel.onOpenInteraction?() }
        }
        if supported {
            Button(viewModel.isInPlaylist(entry) ? "재생목록에서 제거" : "재생목록에 추가") { viewModel.togglePlaylist(entry) }
            Menu("모니터에 적용") {
                ForEach(viewModel.screens, id: \.key) { screen in
                    Button(screen.name + (viewModel.assignedEntryTitle(forScreen: screen.key).map { " (현재: \($0))" } ?? "")) {
                        viewModel.assign(entry, toScreen: screen.key)
                    }
                }
                if viewModel.screens.contains(where: { viewModel.assignedEntryTitle(forScreen: $0.key) != nil }) {
                    Divider()
                    ForEach(viewModel.screens.filter { viewModel.assignedEntryTitle(forScreen: $0.key) != nil }, id: \.key) { screen in
                        Button("\(screen.name) 할당 해제") { viewModel.clearAssignment(forScreen: screen.key) }
                    }
                }
            }
        }
    }

    // MARK: 임포트(로직 무변경)

    func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .zip, .movie]
        panel.allowsMultipleSelection = false
        panel.message = "Wallpaper Engine 폴더·상위 폴더·.zip·동영상(mp4/mov)을 선택하세요."
        if panel.runModal() == .OK, let url = panel.url { routeImport(url) }
    }

    private func routeImport(_ url: URL) {
        if url.pathExtension.lowercased() == "zip" { viewModel.importZip(url) }
        else if VideoImport.isVideoFile(url) { viewModel.importVideoFile(url) }
        else { viewModel.importParent(url) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileURL = UTType.fileURL.identifier
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(fileURL) {
            handled = true
            provider.loadItem(forTypeIdentifier: fileURL, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { self.routeImport(url) }
            }
        }
        return handled
    }
}
```

- [ ] **Step 2: 빌드 + 테스트 + 스모크**

Run: `swift build && swift test --filter WapleAppTests 2>&1 | tail -2 && { WAPLE_SMOKE=1 .build/debug/Waple & APP=$!; sleep 5; screencapture -x /tmp/sp1n-t5.png; kill $APP; }`
Expected: 그린 + 라운드 타일·아래 제목·배지가 보임.

- [ ] **Step 3: Commit**

```bash
git add Sources/Waple/WallpaperGridView.swift
git commit -m "기능(ui): 네이티브 그리드 타일 — 라운드 썸네일·하단 제목·타입 배지·적용 링·호버 리프트"
```

---

### Task 6: 상세 패널 재작성

**Files:**
- Modify: `Sources/Waple/SelectionPanelView.swift` (전체 교체)

**Interfaces:**
- Consumes: `Layout`, 기존 `viewModel`(focusedEntry·isSupported·apply·previewURL·screens·assign·togglePlaylist·isInPlaylist·onOpenInteraction), `PropertyEditorView`(무변경 임베드 — 내부 리스타일은 SP2′), `NowPlayingSubtitle.typeLabel`.
- Produces: `SelectionPanelView` — `init(viewModel: LibraryViewModel)` 유지.

- [ ] **Step 1: 전체 교체**

`Sources/Waple/SelectionPanelView.swift`:

```swift
import SwiftUI
import WapleCore
import WapleLibrary

/// 우측 상세 패널: 히어로 프리뷰(상시 애니) → 제목·메타 → 액션 → 속성 편집.
struct SelectionPanelView: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        Group {
            if let entry = viewModel.focusedEntry {
                content(for: entry)
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("배경을 선택하세요").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .frame(width: Layout.panelWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func content(for entry: LibraryEntry) -> some View {
        let supported = viewModel.isSupported(entry)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if let url = viewModel.previewURL(for: entry) {
                        AnimatedPreviewView(url: url, animating: true)
                    } else {
                        ZStack {
                            Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                            Image(systemName: "photo").foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(height: Layout.heroHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title).font(.title3.weight(.semibold)).lineLimit(2)
                    Text(NowPlayingSubtitle.typeLabel(entry.typeRaw) + (supported ? "" : " · 지원 예정"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    Button {
                        _ = viewModel.apply(entry)
                    } label: {
                        Label("배경으로 적용", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!supported)

                    HStack(spacing: 8) {
                        Menu {
                            ForEach(viewModel.screens, id: \.key) { screen in
                                Button(screen.name) { viewModel.assign(entry, toScreen: screen.key) }
                            }
                        } label: {
                            Label("모니터별", systemImage: "display")
                        }
                        .disabled(!supported)

                        Button {
                            viewModel.togglePlaylist(entry)
                        } label: {
                            Label(viewModel.isInPlaylist(entry) ? "목록 제거" : "목록 추가",
                                  systemImage: viewModel.isInPlaylist(entry) ? "minus.circle" : "plus.circle")
                        }
                        .disabled(!supported)
                    }
                    .frame(maxWidth: .infinity)

                    if WallpaperType.from(entry.typeRaw) == .web {
                        Button {
                            viewModel.onOpenInteraction?()
                        } label: {
                            Label("조작 창 열기", systemImage: "cursorarrow.click").frame(maxWidth: .infinity)
                        }
                    }
                }

                Divider()

                // 기존 편집기 임베드(내부 리스타일은 SP2′). id로 엔트리 전환 시 상태 리셋.
                PropertyEditorView(entry: entry, viewModel: viewModel).id(entry.id)
            }
            .padding(16)
        }
    }
}
```

- [ ] **Step 2: 빌드 + 테스트 + 스모크**

Run: `swift build && swift test --filter WapleAppTests 2>&1 | tail -2 && { WAPLE_SMOKE=1 .build/debug/Waple & APP=$!; sleep 5; screencapture -x /tmp/sp1n-t6.png; kill $APP; }`
Expected: 그린 + 히어로 프리뷰·prominant 적용 버튼이 보임.

- [ ] **Step 3: Commit**

```bash
git add Sources/Waple/SelectionPanelView.swift
git commit -m "기능(ui): 네이티브 상세 패널 — 히어로 프리뷰·prominent 적용·모니터별/재생목록 액션"
```

---

### Task 7: 배너 네이티브화 + 클론 스킨 삭제

**Files:**
- Rename: `git mv Sources/Waple/Shell/WEStatusBanner.swift Sources/Waple/Shell/StatusBanner.swift`
- Delete: `Sources/Waple/DesignSystem/WETheme.swift`, `Sources/Waple/DesignSystem/WEControls.swift`, `Tests/WapleAppTests/WEThemeTests.swift`
- Modify: `Sources/Waple/Shell/MainWindowView.swift` (배너 참조 1곳)

**Interfaces:**
- Produces: `struct StatusBanner: View` — `init(model: StatusBannerModel)`. `StatusBannerModel`은 무변경(테스트 유지).

- [ ] **Step 1: rename + 재작성**

```bash
git mv Sources/Waple/Shell/WEStatusBanner.swift Sources/Waple/Shell/StatusBanner.swift
```

`Sources/Waple/Shell/StatusBanner.swift` 내용 교체(모델은 그대로 유지, 뷰만):

```swift
import SwiftUI

/// notify() 메시지의 창 내 표시 모델. 메인 스레드 전용(AppDelegate·뷰에서만 접근).
final class StatusBannerModel: ObservableObject {
    @Published private(set) var message: String?
    @Published private(set) var generation = 0

    func show(_ message: String) {
        self.message = message
        generation += 1
    }

    func dismiss() { message = nil }
}

/// 네이티브 상태 배너 — 캡슐 재질, 4초 후 자동 소멸.
struct StatusBanner: View {
    @ObservedObject var model: StatusBannerModel

    var body: some View {
        if let msg = model.message {
            Label(msg, systemImage: "info.circle")
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                .padding(.top, 10)
                .task(id: model.generation) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    model.dismiss()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
```

`MainWindowView`의 `.overlay(alignment: .top) { WEStatusBanner(model: banner) }` → `StatusBanner(model: banner)`.

- [ ] **Step 2: 클론 스킨 삭제 + 잔여 참조 0 확인**

```bash
git rm Sources/Waple/DesignSystem/WETheme.swift Sources/Waple/DesignSystem/WEControls.swift Tests/WapleAppTests/WEThemeTests.swift
grep -rn "WETheme\|WEControls\|WEButtonStyle\|WETabButton\|WETopButton\|WESearchField\|WEComboBox\|WEStatusBanner" Sources Tests || echo CLEAN
```
Expected: `CLEAN` (하나라도 나오면 해당 참조를 이 태스크에서 네이티브로 정리).

- [ ] **Step 3: 전 스위트 확인**

Run: `swift build && swift test --filter WapleAppTests 2>&1 | tail -2 && swift test --filter WapleLibraryTests 2>&1 | tail -2 && swift test --filter WapleCoreTests 2>&1 | tail -2`
Expected: 전부 PASS. 앱 스위트 기대치 121건(기존 119 + NowPlayingSubtitle 4 − WEThemeTests 2).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "정리: WE 클론 스킨(WETheme·WEControls) 삭제 + 상태 배너 네이티브화"
```

---

### Task 8: 캡처 도구 + 판정 게이트

**Files:**
- Create: `scripts/window-id.swift`

**Interfaces:**
- Produces: `/tmp/waple-sp1-native.png` (리포 미커밋 — 사용자 판정용).

- [ ] **Step 1: 창 ID 도구**

`scripts/window-id.swift`:

```swift
// 지정 앱(기본 Waple)의 메인창(layer 0) CGWindowID 출력 — screencapture -l 용.
// 데스크탑 월페이퍼 창(레이어 음수)은 제외된다.
import CoreGraphics
import Foundation

let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Waple"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == name
    && (w[kCGWindowLayer as String] as? Int) == 0 {
    if let id = w[kCGWindowNumber as String] as? Int { print(id); exit(0) }
}
fputs("window not found: \(name)\n", stderr)
exit(1)
```

- [ ] **Step 2: 창 단독 캡처**

```bash
swift build
WAPLE_SMOKE=1 .build/debug/Waple & APP=$!
sleep 6
WID=$(swift scripts/window-id.swift Waple)
screencapture -l"$WID" -x /tmp/waple-sp1-native.png
kill $APP
```
Expected: /tmp/waple-sp1-native.png — 메인창 단독(데스크탑 미포함). 캡처가 검거나 비면 보고에 기록.

- [ ] **Step 3: Commit (도구만 — 캡처는 미커밋)**

```bash
git add scripts/window-id.swift
git commit -m "기능(ui): 창 단독 캡처용 window-id 도구 (판정 캡처는 리포 미커밋)"
```

- [ ] **Step 4: 사용자 판정 요청**

/tmp/waple-sp1-native.png 를 사용자에게 제시: "네이티브답고 보기 좋은가? 어긋난 곳 지적" — 판정 통과가 SP1′ 완료 게이트. 지적은 Layout 상수/해당 뷰 수정으로 반영.

---

## 태스크 순서와 의존

1(정리) → 2(Layout) → 3(NowPlayingBar) → 4(크롬+셸) → 5(그리드) → 6(패널) → 7(배너+스킨 삭제) → 8(캡처·판정).
4-7은 서로 다른 파일이지만 7이 4의 배너 참조를 만지므로 순차 실행. 매 커밋 빌드·테스트 그린.

## SP1′에서 의도적으로 안 하는 것

- 필터 사이드바·즐겨찾기·태그/등급·평점·제거·폴더 (SP2′ — 필터는 임시 popover 유지)
- PropertyEditorView 내부 리스타일 (SP2′)
- 디스플레이 화면 네이티브 승격 (SP3′ — 기존 뷰 시트 유지), 검색 탭 콘텐츠 (SP4′), 설정 창·트레이 축소 (SP5′)
