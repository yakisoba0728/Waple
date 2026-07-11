# Waple 메인 UI 개편(WE식 통합창) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 분산된 창/메뉴 UI를 실제 Wallpaper Engine처럼 탭 하나짜리 통합 메인창(설치됨/워크샵/디스플레이 + 우측 속성 패널 + 하단 바)으로 재구성한다.

**Architecture:** 데이터 계층(LibraryStore/PlaylistStore/MonitorAssignmentStore/AppLogic) 무변경. LibraryViewModel에 브라우즈 상태(focusedId·검색·필터·정렬)만 추가하고, SwiftUI 뷰를 재배치한다. 창은 기존 `libraryWindow`를 승격(다크 강제). 스펙: `docs/superpowers/specs/2026-07-11-waple-ui-design.md`.

**Tech Stack:** SwiftUI + AppKit(NSViewRepresentable, NSWindow), 외부 의존성 0.

## Global Constraints

- 항상 다크: 메인창 `window.appearance = NSAppearance(named: .darkAqua)`.
- 데이터 스토어·AppLogic 시그니처 변경 금지.
- 기존 기능 퇴행 금지: 드롭/zip/동영상 임포트, 조작 창, 미지원 뱃지, 컨텍스트 메뉴, 워크샵 다운로드→그리드 반영.
- 각 태스크 끝에 `swift build` 에러 0 + 해당 테스트 green + 커밋.
- 주석·커밋 메시지는 리포 관례(한국어) 유지.

---

### Task 1: 브라우즈 상태 + 필터/정렬 로직 (TDD)

**Files:**
- Create: `Sources/Waple/LibraryFiltering.swift`
- Modify: `Sources/Waple/LibraryViewModel.swift` (필드 추가)
- Test: `Tests/WapleAppTests/LibraryFilteringTests.swift`

**Interfaces:**
- Produces: `enum LibraryTypeFilter: String, CaseIterable { case all, scene, video, web }`, `enum LibrarySortOrder: String, CaseIterable { case recentFirst, name }`, `LibraryFiltering.apply(_:search:type:sort:) -> [LibraryEntry]`, `LibraryViewModel.focusedId/searchText/typeFilter/sortOrder/filteredEntries/focusedEntry`

- [x] **Step 1: 실패하는 테스트 작성** — `Tests/WapleAppTests/LibraryFilteringTests.swift`

```swift
import XCTest
import WapleLibrary
@testable import Waple

final class LibraryFilteringTests: XCTestCase {
    private func entry(_ id: String, _ title: String, _ type: String) -> LibraryEntry {
        LibraryEntry(id: id, title: title, typeRaw: type, fileName: nil, previewName: nil, bookmark: Data())
    }
    private var sample: [LibraryEntry] {
        [entry("1", "바다", "scene"), entry("2", "Alps", "video"), entry("3", "네온", "web"),
         entry("4", "바다 야경", "video")]
    }

    func testRecentFirstIsReversedInsertionOrder() {
        let out = LibraryFiltering.apply(sample, search: "", type: .all, sort: .recentFirst)
        XCTAssertEqual(out.map(\.id), ["4", "3", "2", "1"])
    }
    func testNameSortUsesLocalizedCompare() {
        let out = LibraryFiltering.apply(sample, search: "", type: .all, sort: .name)
        XCTAssertEqual(out.map(\.title), ["Alps", "네온", "바다", "바다 야경"])
    }
    func testSearchMatchesTitleCaseInsensitive() {
        XCTAssertEqual(LibraryFiltering.apply(sample, search: "바다", type: .all, sort: .name).count, 2)
        XCTAssertEqual(LibraryFiltering.apply(sample, search: "alps", type: .all, sort: .name).map(\.id), ["2"])
    }
    func testTypeFilter() {
        XCTAssertEqual(LibraryFiltering.apply(sample, search: "", type: .video, sort: .recentFirst).map(\.id), ["4", "2"])
        XCTAssertEqual(LibraryFiltering.apply(sample, search: "", type: .web, sort: .recentFirst).map(\.id), ["3"])
    }
    func testSearchAndTypeCompose() {
        XCTAssertEqual(LibraryFiltering.apply(sample, search: "바다", type: .video, sort: .recentFirst).map(\.id), ["4"])
    }
}
```

- [x] **Step 2: 실패 확인**

Run: `swift test --filter LibraryFilteringTests 2>&1 | tail -5`
Expected: 컴파일 실패("cannot find 'LibraryFiltering'").

- [x] **Step 3: 최소 구현** — `Sources/Waple/LibraryFiltering.swift`

```swift
import Foundation
import WapleCore
import WapleLibrary

enum LibraryTypeFilter: String, CaseIterable {
    case all, scene, video, web
    var label: String {
        switch self {
        case .all: return "전체"; case .scene: return "장면"; case .video: return "동영상"; case .web: return "웹"
        }
    }
}

enum LibrarySortOrder: String, CaseIterable {
    case recentFirst, name
    var label: String { self == .recentFirst ? "최근 추가순" : "이름순" }
}

/// 그리드 표시용 순수 필터/정렬 — 스토어 순서(추가순)를 입력으로 받는다.
enum LibraryFiltering {
    static func apply(_ entries: [LibraryEntry], search: String,
                      type: LibraryTypeFilter, sort: LibrarySortOrder) -> [LibraryEntry] {
        var out = entries
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            out = out.filter { $0.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        if type != .all {
            out = out.filter { entryType($0) == type }
        }
        switch sort {
        case .recentFirst: return out.reversed()   // 스토어는 import 순 append — 역순 = 최신순
        case .name: return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    private static func entryType(_ e: LibraryEntry) -> LibraryTypeFilter {
        switch WallpaperType.from(e.typeRaw) {
        case .scene: return .scene
        case .video: return .video
        case .web: return .web
        default: return .all   // preset 등 — 타입 필터에 안 걸리고 '전체'에만 표시
        }
    }
}
```

- [x] **Step 4: LibraryViewModel에 브라우즈 상태 추가** — `Sources/Waple/LibraryViewModel.swift`의 `@Published var propertyEditorEntry` 아래에 추가(`propertyEditorEntry`는 Task 5에서 제거):

```swift
    // MARK: - 브라우즈 상태(메인창 UI) — selectedId(=적용됨)와 구분되는 패널 포커스.
    @Published var focusedId: String?
    @Published var searchText = ""
    @Published var typeFilter: LibraryTypeFilter = .all
    @Published var sortOrder: LibrarySortOrder = .recentFirst

    var filteredEntries: [LibraryEntry] {
        LibraryFiltering.apply(entries, search: searchText, type: typeFilter, sort: sortOrder)
    }
    var focusedEntry: LibraryEntry? { entries.first { $0.id == focusedId } }
    /// 하단 바 "현재:" 표시용 — 적용된(selectedId) 배경 제목.
    var appliedTitle: String? { entries.first { $0.id == selectedId }?.title }
```

- [x] **Step 5: 통과 확인 + 커밋**

Run: `swift test --filter LibraryFilteringTests 2>&1 | tail -3` → PASS(5 tests)
```bash
git add Sources/Waple/LibraryFiltering.swift Sources/Waple/LibraryViewModel.swift Tests/WapleAppTests/LibraryFilteringTests.swift
git commit -m "기능(ui): 라이브러리 브라우즈 상태 + 검색/타입/정렬 순수 필터 (WE식 메인창 1/7)"
```

---

### Task 2: GIF 애니 프리뷰 컴포넌트

**Files:**
- Create: `Sources/Waple/AnimatedPreviewView.swift`
- Test: `Tests/WapleAppTests/PreviewMediaTests.swift`

**Interfaces:**
- Produces: `PreviewMedia.isAnimated(_ url: URL) -> Bool`, `struct AnimatedPreviewView: View` (`init(url: URL, animating: Bool)`) — 그리드 타일·우측 패널 공용.

- [x] **Step 1: 실패하는 테스트** — `Tests/WapleAppTests/PreviewMediaTests.swift`

```swift
import XCTest
@testable import Waple

final class PreviewMediaTests: XCTestCase {
    func testGifDetectionByExtension() {
        XCTAssertTrue(PreviewMedia.isAnimated(URL(fileURLWithPath: "/a/preview.GIF")))
        XCTAssertTrue(PreviewMedia.isAnimated(URL(fileURLWithPath: "/a/preview.gif")))
        XCTAssertFalse(PreviewMedia.isAnimated(URL(fileURLWithPath: "/a/preview.jpg")))
        XCTAssertFalse(PreviewMedia.isAnimated(URL(fileURLWithPath: "/a/previewgif")))
    }
}
```

- [x] **Step 2: 실패 확인** — `swift test --filter PreviewMediaTests 2>&1 | tail -3` → 컴파일 실패.

- [x] **Step 3: 구현** — `Sources/Waple/AnimatedPreviewView.swift`

```swift
import SwiftUI
import AppKit

enum PreviewMedia {
    static func isAnimated(_ url: URL) -> Bool { url.pathExtension.lowercased() == "gif" }
}

/// preview.gif 네이티브 재생(NSImageView.animates) — SwiftUI Image는 GIF 애니를 지원하지 않는다.
/// animating=false 면 첫 프레임 정지(그리드 성능: 호버 중에만 재생).
struct AnimatedPreviewView: NSViewRepresentable {
    let url: URL
    var animating: Bool

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = animating
        v.image = NSImage(contentsOf: url)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        // URL 변경(그리드 셀 재사용) 시에만 재로드 — animates 토글은 매 업데이트 반영.
        if context.coordinator.url != url {
            context.coordinator.url = url
            v.image = NSImage(contentsOf: url)
        }
        v.animates = animating
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator { var url: URL; init(url: URL) { self.url = url } }
}
```

- [x] **Step 4: 통과 확인 + 커밋**

Run: `swift test --filter PreviewMediaTests 2>&1 | tail -3` → PASS, `swift build 2>&1 | tail -2` → 에러 0.
```bash
git add Sources/Waple/AnimatedPreviewView.swift Tests/WapleAppTests/PreviewMediaTests.swift
git commit -m "기능(ui): preview.gif 네이티브 애니 컴포넌트 (WE식 메인창 2/7)"
```

---

### Task 3: 디스플레이 다이어그램 (TDD) + 디스플레이 탭

**Files:**
- Create: `Sources/Waple/DisplaysTabView.swift`
- Test: `Tests/WapleAppTests/DisplayDiagramLayoutTests.swift`

**Interfaces:**
- Consumes: `LibraryViewModel.screens/assignedEntryTitle(forScreen:)/assign(_:toScreen:)/clearAssignment(forScreen:)/focusedEntry` (Task 1)
- Produces: `DisplayDiagramLayout.rects(screenFrames:container:padding:) -> [CGRect]` (입력 순서 보존), `struct DisplaysTabView: View`

- [x] **Step 1: 실패하는 테스트** — `Tests/WapleAppTests/DisplayDiagramLayoutTests.swift`

```swift
import XCTest
@testable import Waple

final class DisplayDiagramLayoutTests: XCTestCase {
    func testSideBySideMonitorsFillContainerProportionally() {
        // 주모니터(0,0,1920,1080) + 우측 보조(1920,0,1920,1080) → 컨테이너 800×300, 패딩 0
        let rects = DisplayDiagramLayout.rects(
            screenFrames: [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                           CGRect(x: 1920, y: 0, width: 1920, height: 1080)],
            container: CGSize(width: 800, height: 300), padding: 0)
        // 전체 3840×1080 → 스케일 = min(800/3840, 300/1080) = 0.2083…
        let s = min(800.0 / 3840.0, 300.0 / 1080.0)
        XCTAssertEqual(rects[0].width, 1920 * s, accuracy: 0.5)
        XCTAssertEqual(rects[1].minX, rects[0].maxX, accuracy: 0.5)
        // 수직 중앙 정렬
        XCTAssertEqual(rects[0].midY, 150, accuracy: 0.5)
    }
    func testAppKitBottomOriginIsFlippedToTopOrigin() {
        // 보조가 주모니터 '위'(AppKit y+) → 다이어그램(상단 원점)에선 더 작은 y
        let rects = DisplayDiagramLayout.rects(
            screenFrames: [CGRect(x: 0, y: 0, width: 1000, height: 500),
                           CGRect(x: 0, y: 500, width: 1000, height: 500)],
            container: CGSize(width: 500, height: 500), padding: 0)
        XCTAssertLessThan(rects[1].minY, rects[0].minY)
    }
    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(DisplayDiagramLayout.rects(screenFrames: [], container: CGSize(width: 100, height: 100), padding: 8).isEmpty)
    }
}
```

- [x] **Step 2: 실패 확인** — `swift test --filter DisplayDiagramLayoutTests 2>&1 | tail -3` → 컴파일 실패.

- [x] **Step 3: 구현** — `Sources/Waple/DisplaysTabView.swift`

```swift
import SwiftUI
import WapleLibrary

/// NSScreen.frames(하단 원점) → 컨테이너 좌표(상단 원점) 비례 배치. 순수 함수 — 유닛 테스트 대상.
enum DisplayDiagramLayout {
    static func rects(screenFrames: [CGRect], container: CGSize, padding: CGFloat) -> [CGRect] {
        guard !screenFrames.isEmpty else { return [] }
        let union = screenFrames.dropFirst().reduce(screenFrames[0]) { $0.union($1) }
        let availW = max(1, container.width - padding * 2)
        let availH = max(1, container.height - padding * 2)
        let s = min(availW / union.width, availH / union.height)
        let offX = padding + (availW - union.width * s) / 2
        let offY = padding + (availH - union.height * s) / 2
        return screenFrames.map { f in
            // AppKit y(하단 기준) → 다이어그램 y(상단 기준): union 상단으로부터의 거리로 뒤집는다.
            let topDistance = union.maxY - f.maxY
            return CGRect(x: offX + (f.minX - union.minX) * s,
                          y: offY + topDistance * s,
                          width: f.width * s, height: f.height * s)
        }
    }
}

/// WE 디스플레이 화면: 모니터 배치 다이어그램 + 선택 모니터에 배경 할당/해제.
struct DisplaysTabView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var selectedScreenKey: String?
    /// AppDelegate 주입 — NSScreen 프레임(키 순서는 viewModel.screens와 동일해야 함).
    var screenFrames: () -> [CGRect]

    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { geo in
                let screens = viewModel.screens
                let rects = DisplayDiagramLayout.rects(screenFrames: screenFrames(),
                                                       container: geo.size, padding: 24)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(zip(screens, rects)), id: \.0.key) { screen, rect in
                        monitorBox(screen: screen, rect: rect)
                    }
                }
            }
            actionBar
        }
        .padding()
        .onAppear { if selectedScreenKey == nil { selectedScreenKey = viewModel.screens.first?.key } }
    }

    @ViewBuilder
    private func monitorBox(screen: (key: String, name: String), rect: CGRect) -> some View {
        let selected = selectedScreenKey == screen.key
        VStack(spacing: 4) {
            Text(screen.name).font(.headline).lineLimit(1)
            Text(viewModel.assignedEntryTitle(forScreen: screen.key) ?? "전역 배경").font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
        .frame(width: rect.width, height: rect.height)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.gray.opacity(0.5), lineWidth: selected ? 3 : 1))
        .contentShape(Rectangle())
        .onTapGesture { selectedScreenKey = screen.key }
        .offset(x: rect.minX, y: rect.minY)
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack {
            if let key = selectedScreenKey {
                Text(viewModel.screens.first { $0.key == key }?.name ?? key).bold()
                Spacer()
                Button("선택한 배경 적용") {
                    if let entry = viewModel.focusedEntry { viewModel.assign(entry, toScreen: key) }
                }
                .disabled(viewModel.focusedEntry == nil || !(viewModel.focusedEntry.map(viewModel.isSupported) ?? false))
                .help("설치됨 탭에서 배경을 먼저 선택하세요")
                Button("할당 해제") { viewModel.clearAssignment(forScreen: key) }
                    .disabled(viewModel.assignedEntryTitle(forScreen: key) == nil)
            } else {
                Text("모니터를 선택하세요").foregroundColor(.secondary)
            }
        }
        .frame(height: 28)
    }
}
```

- [x] **Step 4: 통과 확인 + 커밋**

Run: `swift test --filter DisplayDiagramLayoutTests 2>&1 | tail -3` → PASS(3), `swift build` 에러 0.
```bash
git add Sources/Waple/DisplaysTabView.swift Tests/WapleAppTests/DisplayDiagramLayoutTests.swift
git commit -m "기능(ui): 디스플레이 탭 — 모니터 다이어그램 배치 + 할당/해제 (WE식 메인창 3/7)"
```

---

### Task 4: WallpaperGridView (LibraryView 개조)

**Files:**
- Create: `Sources/Waple/WallpaperGridView.swift` (LibraryView.swift 본문 이동·개조)
- Delete: `Sources/Waple/LibraryView.swift` (이 태스크에서 git rm)

**Interfaces:**
- Consumes: `filteredEntries/focusedId/apply/isSupported/previewURL/screens/assign/togglePlaylist/isInPlaylist/onOpenInteraction` (Task 1), `AnimatedPreviewView/PreviewMedia` (Task 2)
- Produces: `struct WallpaperGridView: View` (`init(viewModel: LibraryViewModel)`) — 임포트 패널·드롭 로직 포함(기존 LibraryView에서 이동).

- [ ] **Step 1: 구현** — `Sources/Waple/WallpaperGridView.swift` 생성. 기존 `LibraryView.swift`에서 `PreviewImageCache`, `importFolder()/routeImport()/handleDrop()` 을 그대로 옮기고, 뷰 본문을 다음으로 교체(상단 헤더·sheet 제거 — TopBar/패널이 대체):

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

/// 설치됨 탭 좌측 그리드: 클릭=선택(패널), 더블클릭=적용, 호버=gif 재생+제목. WE 브라우저 재현.
struct WallpaperGridView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var hoveredId: String?

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 12)]

    var body: some View {
        Group {
            if viewModel.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(viewModel.filteredEntries, id: \.id) { entry in
                            tile(for: entry)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop($0) }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("라이브러리가 비어 있습니다").font(.title3)
            Text("Wallpaper Engine 폴더·zip·동영상을 드래그하거나 가져오세요.").foregroundColor(.secondary)
            Button("폴더 가져오기…") { importFolder() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tile(for entry: LibraryEntry) -> some View {
        let supported = viewModel.isSupported(entry)
        let focused = viewModel.focusedId == entry.id
        let applied = viewModel.selectedId == entry.id
        let hovered = hoveredId == entry.id
        ZStack(alignment: .bottomLeading) {
            preview(for: entry, animating: hovered)
                .frame(height: 110).frame(maxWidth: .infinity).clipped()
            // 하단 그라데이션 + 제목(WE 타일) — 호버/포커스에서만 노출.
            if hovered || focused {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 44).frame(maxHeight: .infinity, alignment: .bottom)
                Text(entry.title).font(.caption).bold().foregroundColor(.white)
                    .lineLimit(1).padding(6)
            }
            // 타입/상태 뱃지(우상단)
            VStack(alignment: .trailing, spacing: 3) {
                badge(badgeText(for: entry, supported: supported), color: supported ? Color.accentColor : .gray)
                if applied { badge("적용됨", color: .green) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(5)
        }
        .cornerRadius(8)
        .opacity(supported ? 1.0 : 0.5)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(focused ? Color.accentColor : (applied ? Color.green.opacity(0.7) : Color.clear), lineWidth: 2))
        .contentShape(Rectangle())
        .onHover { hoveredId = $0 ? entry.id : (hoveredId == entry.id ? nil : hoveredId) }
        .onTapGesture(count: 2) { if supported { _ = viewModel.apply(entry) } }
        .onTapGesture { viewModel.focusedId = entry.id }
        .contextMenu { contextMenu(for: entry, supported: supported) }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color).foregroundColor(.white).cornerRadius(4)
    }

    private func badgeText(for entry: LibraryEntry, supported: Bool) -> String {
        guard supported else { return "지원 예정" }
        let type = WallpaperType.from(entry.typeRaw)
        return type == .scene ? "scene · 부분" : type.storageString
    }

    @ViewBuilder
    private func preview(for entry: LibraryEntry, animating: Bool) -> some View {
        if let url = viewModel.previewURL(for: entry) {
            if PreviewMedia.isAnimated(url) {
                AnimatedPreviewView(url: url, animating: animating)
            } else if let image = PreviewImageCache.image(url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.gray.opacity(0.3))
            }
        } else {
            Rectangle().fill(Color.gray.opacity(0.3))
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

    // MARK: 임포트(기존 LibraryView에서 이동 — 로직 무변경)

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

- [ ] **Step 2: LibraryView.swift 삭제** — `git rm Sources/Waple/LibraryView.swift`. 참조 지점은 AppDelegate:244(`LibraryView(viewModel:)`) 하나 — **컴파일이 깨지므로 이 태스크에서는 임시로** AppDelegate:244를 `WallpaperGridView(viewModel: libraryVM)`로 치환(Task 6에서 MainWindowView로 재치환).

- [ ] **Step 3: 빌드·기존 테스트 확인 + 커밋**

Run: `swift build 2>&1 | tail -2` → 에러 0. `swift test --filter WapleAppTests 2>&1 | tail -3` → PASS.
```bash
git add -A Sources/Waple
git commit -m "기능(ui): WE식 그리드 타일 — 클릭 선택/더블클릭 적용/호버 gif·제목 (WE식 메인창 4/7)"
```

---

### Task 5: SelectionPanelView + 속성 인라인화

**Files:**
- Create: `Sources/Waple/SelectionPanelView.swift`
- Modify: `Sources/Waple/PropertyEditorView.swift` (임베드용 소폭 수정), `Sources/Waple/LibraryViewModel.swift` (`propertyEditorEntry` 제거)

**Interfaces:**
- Consumes: `focusedEntry/apply/isSupported/previewURL/screens/assign/togglePlaylist/isInPlaylist/onOpenInteraction` (Task 1·4), `AnimatedPreviewView` (Task 2), `PropertyEditorView(entry:viewModel:)` (기존)
- Produces: `struct SelectionPanelView: View` (`init(viewModel: LibraryViewModel)`) — 고정폭 300.

- [ ] **Step 1: PropertyEditorView 임베드화** — `Sources/Waple/PropertyEditorView.swift`에서 시트 전용 요소 제거: `body`의 `.frame(minWidth: 420, minHeight: 320)` 을 삭제하고, 상단에 닫기 버튼이 있으면 삭제(패널이 항상 표시). `onDisappear` 커밋 로직(2026-07-11 수정분)은 유지.

- [ ] **Step 2: LibraryViewModel에서 `propertyEditorEntry` 제거** — 선언(11행 인근) 삭제. 컴파일러가 잡는 참조(구 LibraryView는 Task 4에서 삭제됨)를 모두 제거.

- [ ] **Step 3: 구현** — `Sources/Waple/SelectionPanelView.swift`

```swift
import SwiftUI
import WapleCore
import WapleLibrary

/// 우측 상시 패널(WE 우측 컬럼): 선택 배경의 프리뷰·메타·액션·속성 편집.
struct SelectionPanelView: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        Group {
            if let entry = viewModel.focusedEntry {
                content(for: entry)
            } else {
                VStack {
                    Spacer()
                    Text("배경을 선택하세요").foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    @ViewBuilder
    private func content(for entry: LibraryEntry) -> some View {
        let supported = viewModel.isSupported(entry)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                previewBlock(for: entry)
                Text(entry.title).font(.headline).lineLimit(2)
                Text(WallpaperType.from(entry.typeRaw).storageString + (supported ? "" : " · 지원 예정"))
                    .font(.caption).foregroundColor(.secondary)
                actionButtons(for: entry, supported: supported)
                Divider()
                Text("속성").font(.subheadline).bold()
                // 기존 편집기 임베드 — 시트 폐지. id로 엔트리 전환 시 상태 리셋.
                PropertyEditorView(entry: entry, viewModel: viewModel).id(entry.id)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func previewBlock(for entry: LibraryEntry) -> some View {
        Group {
            if let url = viewModel.previewURL(for: entry) {
                AnimatedPreviewView(url: url, animating: true)   // 패널은 상시 재생(WE 동일)
            } else {
                Rectangle().fill(Color.gray.opacity(0.3))
            }
        }
        .frame(height: 158).frame(maxWidth: .infinity).clipped().cornerRadius(8)
    }

    @ViewBuilder
    private func actionButtons(for entry: LibraryEntry, supported: Bool) -> some View {
        VStack(spacing: 8) {
            Button { _ = viewModel.apply(entry) } label: {
                Text("배경으로 적용").frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!supported)
            HStack(spacing: 8) {
                Menu("모니터에 적용") {
                    ForEach(viewModel.screens, id: \.key) { screen in
                        Button(screen.name) { viewModel.assign(entry, toScreen: screen.key) }
                    }
                }
                .disabled(!supported)
                Button(viewModel.isInPlaylist(entry) ? "재생목록 제거" : "재생목록 추가") {
                    viewModel.togglePlaylist(entry)
                }
                .disabled(!supported)
            }
            if WallpaperType.from(entry.typeRaw) == .web {
                Button("조작 창 열기") { viewModel.onOpenInteraction?() }.frame(maxWidth: .infinity)
            }
        }
    }
}
```

- [ ] **Step 4: 빌드·테스트 + 커밋**

Run: `swift build 2>&1 | tail -2` → 에러 0. `swift test --filter WapleAppTests 2>&1 | tail -3` → PASS.
```bash
git add Sources/Waple/SelectionPanelView.swift Sources/Waple/PropertyEditorView.swift Sources/Waple/LibraryViewModel.swift
git commit -m "기능(ui): 우측 상시 패널 — 프리뷰/액션/속성 인라인, 시트 폐지 (WE식 메인창 5/7)"
```

---

### Task 6: MainWindowView — 탭 셸 + TopBar + BottomBar

**Files:**
- Create: `Sources/Waple/MainWindowView.swift`
- Modify: `Sources/Waple/LibraryViewModel.swift` (하단 바 콜백 3개 추가)

**Interfaces:**
- Consumes: `WallpaperGridView`(4), `SelectionPanelView`(5), `DisplaysTabView`(3), `WorkshopView(library:)`(기존), `filteredEntries/searchText/typeFilter/sortOrder/appliedTitle`(1)
- Produces: `struct MainWindowView: View` (`init(viewModel: LibraryViewModel, screenFrames: @escaping () -> [CGRect])`), VM 콜백 `onAdvancePlaylist: (() -> Void)?`, `onTogglePause: (() -> Bool)?`, `@Published var isPaused: Bool`

- [ ] **Step 1: VM 콜백 추가** — `Sources/Waple/LibraryViewModel.swift` 주입 콜백 블록(30행 인근)에 추가:

```swift
    /// 하단 바: 재생목록 다음으로 — AppDelegate 주입.
    var onAdvancePlaylist: (() -> Void)?
    /// 하단 바: 전역 일시정지 토글(새 상태 반환) — AppDelegate 주입.
    var onTogglePause: (() -> Bool)?
    @Published var isPaused = false
```

- [ ] **Step 2: 구현** — `Sources/Waple/MainWindowView.swift`

```swift
import SwiftUI
import WapleLibrary

enum MainTab: String, CaseIterable {
    case installed, workshop, displays
    var label: String {
        switch self {
        case .installed: return "설치됨"; case .workshop: return "워크샵"; case .displays: return "디스플레이"
        }
    }
}

/// WE식 통합 메인창: 상단 탭/검색/필터 + 콘텐츠 + 하단 상태 바.
struct MainWindowView: View {
    @ObservedObject var viewModel: LibraryViewModel
    var screenFrames: () -> [CGRect]
    @State private var tab: MainTab = .installed

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
            Divider()
            bottomBar
        }
        .frame(minWidth: 1100, minHeight: 700)
    }

    @ViewBuilder
    private var topBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                ForEach(MainTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        Text(t.label).font(.system(size: 13, weight: tab == t ? .bold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(tab == t ? Color.accentColor.opacity(0.25) : .clear)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            if tab == .installed {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("검색", text: $viewModel.searchText).textFieldStyle(.plain).frame(width: 180)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(6)
                Picker("", selection: $viewModel.typeFilter) {
                    ForEach(LibraryTypeFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 110)
                Picker("", selection: $viewModel.sortOrder) {
                    ForEach(LibrarySortOrder.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(width: 130)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .installed:
            HStack(spacing: 0) {
                WallpaperGridView(viewModel: viewModel)
                Divider()
                SelectionPanelView(viewModel: viewModel)
            }
        case .workshop:
            WorkshopView(library: viewModel)
        case .displays:
            DisplaysTabView(viewModel: viewModel, screenFrames: screenFrames)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 16) {
            Text("현재: \(viewModel.appliedTitle ?? "없음")").font(.caption).lineLimit(1)
            Spacer()
            Button {
                viewModel.onAdvancePlaylist?()
            } label: { Label("다음 배경", systemImage: "forward.fill").font(.caption) }
            .disabled(viewModel.playlist.ids.count < 2)
            Button {
                if let paused = viewModel.onTogglePause?() { viewModel.isPaused = paused }
            } label: {
                Label(viewModel.isPaused ? "재개" : "일시정지",
                      systemImage: viewModel.isPaused ? "play.fill" : "pause.fill").font(.caption)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
```

- [ ] **Step 3: 빌드 + 커밋**

Run: `swift build 2>&1 | tail -2` → 에러 0.
```bash
git add Sources/Waple/MainWindowView.swift Sources/Waple/LibraryViewModel.swift
git commit -m "기능(ui): 통합 메인창 셸 — 탭/검색/필터 TopBar + 재생목록/일시정지 BottomBar (WE식 메인창 6/7)"
```

---

### Task 7: AppDelegate 통합 — 창 승격·다크 강제·메뉴 정리

**Files:**
- Modify: `Sources/Waple/AppDelegate.swift`

**Interfaces:**
- Consumes: `MainWindowView(viewModel:screenFrames:)`(6)
- Produces: 통합 `openMainWindow()`, `toggleGlobalPause() -> Bool`

- [ ] **Step 1: openLibrary() 개편** — AppDelegate:242 `openLibrary()`를 다음으로 교체(메뉴 셀렉터 이름 유지 — 참조 지점 최소 변경):

```swift
    @objc private func openLibrary() {
        if libraryWindow == nil {
            let root = MainWindowView(viewModel: libraryVM,
                                      screenFrames: { NSScreen.screens.map(\.frame) })
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Waple"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.appearance = NSAppearance(named: .darkAqua)   // WE 관례 — 항상 다크
            window.isReleasedWhenClosed = false
            libraryWindow = window
        }
        libraryWindow?.center()
        libraryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
```

**주의**: `screenFrames`의 키 순서는 `screensProvider`(viewModel.screens)와 동일해야 다이어그램-이름 매칭이 맞는다. AppDelegate에서 `screensProvider`가 어떤 순서로 화면을 나열하는지 확인하고(NSScreen.screens 순서 기반인지), 다르면 같은 소스에서 (key, name, frame)을 한 번에 뽑는 provider 하나로 통일하라.

- [ ] **Step 2: 워크샵 별창 제거** — `workshopWindow` 프로퍼티(23행), `openWorkshop()`(781행)과 상태바 메뉴의 "워크샵 열기" 항목(67행) 삭제. "라이브러리 열기" 메뉴 타이틀을 "Waple 열기"로 변경. `WorkshopView` 참조는 MainWindowView가 유일해짐을 `grep -rn "WorkshopView(" Sources/`로 확인.

- [ ] **Step 3: 전역 일시정지 + 하단 바 콜백 배선** — AppDelegate에 추가(기존 `pausedByOcclusion` 로직과 독립된 수동 정지; `resumeFromOcclusion()` 인근):

```swift
    private var manualGlobalPause = false

    /// 하단 바 일시정지 토글 — 새 상태 반환. 가림 정지와 독립(둘 중 하나라도 있으면 정지 유지).
    func toggleGlobalPause() -> Bool {
        manualGlobalPause.toggle()
        if manualGlobalPause {
            renderers.forEach { $0.pause() }
        } else if !pausedByOcclusion {
            renderers.forEach { $0.resume() }
        }
        return manualGlobalPause
    }
```

viewModel 콜백 주입부(기존 `libraryVM.onApply = …` 블록)에 추가:

```swift
        libraryVM.onAdvancePlaylist = { [weak self] in self?.advancePlaylist() }
        libraryVM.onTogglePause = { [weak self] in self?.toggleGlobalPause() ?? false }
```

`advancePlaylist()`가 `private`이면 그대로 두고 클로저로 호출(같은 타입 내부라 접근 가능). 렌더러 교체 경로(applyResolved 등)에서 `pausedByOcclusion` 정지 유지를 하는 지점(339행)에 `|| manualGlobalPause` 조건을 추가해 수동 정지도 교체 후 유지되게 한다.

- [ ] **Step 4: 전체 검증 + 커밋**

Run: `swift build 2>&1 | tail -2` → 에러 0. `swift test 2>&1 | tail -5` → 전 타깃 green(렌더 스위트 포함 — 오래 걸리면 `--filter WapleAppTests` 먼저, 전체는 마지막 1회).
```bash
git add Sources/Waple/AppDelegate.swift
git commit -m "기능(ui): 메인창 승격(다크 강제)·워크샵 별창 폐지·하단바 배선 (WE식 메인창 7/7)"
```

- [ ] **Step 5: 수동 스모크(수용 기준 검증)** — 앱 실행(`swift run Waple`) 후 확인, 결과를 최종 보고에 기록:
1. 메인창에서 검색→타일 클릭(패널 갱신)→속성 슬라이더 변경(재적용)→더블클릭 적용.
2. 디스플레이 탭: 다이어그램이 실제 배치와 일치, 할당/해제 즉시 반영.
3. 워크샵 탭 로드(API 키 화면 또는 브라우저), 다운로드→설치됨 그리드 반영.
4. 시스템 라이트 모드에서도 창이 다크인지.
5. 하단 바: 현재 배경명, 다음 배경, 일시정지/재개.
6. 드롭 임포트(폴더/zip/동영상), 웹 배경 조작 창.
