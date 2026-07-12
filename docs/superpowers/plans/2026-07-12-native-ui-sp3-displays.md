# SP3′: 디스플레이 화면 네이티브 승격 Implementation Plan

> 상태: **완료·판정 통과(2026-07-12)** — 썸네일 합성은 할당 임시 시드로 실렌더 검증(원복 완료).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) 구문.

**Goal:** 디스플레이 시트를 WE 디스플레이 선택 화면의 네이티브 번역으로 승격 — 모니터 박스에 **할당 배경 썸네일**을 채우고, 선택/할당/해제를 한 화면에서.

**Architecture:** `DisplayDiagramLayout`(순수, 테스트 유지) 재사용. 구 `DisplaysTabView` → `Surfaces/Displays/DisplaysView`로 개명·재작성. 스펙: [2026-07-12-native-ui-redesign.md](../specs/2026-07-12-native-ui-redesign.md) SP3′.

**Tech Stack:** SwiftUI(macOS 14+), 외부 의존성 0.

## Global Constraints

- 커스텀 hex 금지(시맨틱/재질/accentColor), SF Symbols, 치수는 `Metrics`(신규 필요 시 추가).
- 커밋 `기능(ui): …` 관례, push 금지, main 직접. 매 태스크 `swift build` + `swift test --filter WapleAppTests` 그린 후 커밋.
- `DisplayDiagramLayout` enum(이름·구현)은 변경 금지 — DisplayDiagramLayoutTests 가 검증 중.
- 캡처는 /tmp만. macOS에 `timeout` 없음(백그라운드+kill).

---

### Task 1: VM 헬퍼 — 화면별 할당 엔트리 조회

**Files:**
- Modify: `Sources/Waple/LibraryViewModel.swift`
- Modify: `Tests/WapleAppTests/LibraryViewModelTests.swift` (테스트 1건 추가)

**Interfaces:**
- Produces: `LibraryViewModel.assignedEntry(forScreen key: String) -> LibraryEntry?` — Task 2의 썸네일 로딩이 소비.

- [ ] **Step 1: 실패 테스트** — `LibraryViewModelTests.swift` 말미에 추가(파일의 기존 픽스처 `tempDir()`/`entry(id:title:)`/`seedLibrary(_:entries:)`/`makeVM(dir:)` 그대로 사용):

```swift
    func testAssignedEntryLookup() throws {
        let dir = tempDir()
        let e = entry(id: "wp9", title: "Aurora")
        try seedLibrary(dir, entries: [e])
        let vm = makeVM(dir: dir)
        vm.assign(e, toScreen: "display-7")
        XCTAssertEqual(vm.assignedEntry(forScreen: "display-7")?.id, "wp9")
        XCTAssertNil(vm.assignedEntry(forScreen: "display-none"))
        vm.clearAssignment(forScreen: "display-7")
        XCTAssertNil(vm.assignedEntry(forScreen: "display-7"))
    }
```

- [ ] **Step 2: 실패 확인** — `swift test --filter LibraryViewModelTests` → FAIL(멤버 부재).

- [ ] **Step 3: 구현** — `LibraryViewModel.swift`의 `assignedEntryTitle(forScreen:)` 옆에:

```swift
    /// 화면에 할당된 라이브러리 엔트리(썸네일 로딩용). 미할당/유실 id → nil(전역 배경).
    func assignedEntry(forScreen key: String) -> LibraryEntry? {
        guard let id = monitors.assignment(for: key) else { return nil }
        return entries.first { $0.id == id }
    }
```

- [ ] **Step 4: 통과 + Commit**

```bash
swift test --filter LibraryViewModelTests 2>&1 | tail -1
git add Sources/Waple/LibraryViewModel.swift Tests/WapleAppTests/LibraryViewModelTests.swift
git commit -m "기능(ui): 화면별 할당 엔트리 조회 헬퍼 — 디스플레이 썸네일용"
```

---

### Task 2: DisplaysView 재작성 + 셸 배선

**Files:**
- Rename: `git mv Sources/Waple/DisplaysTabView.swift Sources/Waple/Surfaces/Displays/DisplaysView.swift` (디렉터리 생성 필요)
- Modify: `Sources/Waple/Shell/MainWindowView.swift`, `Sources/Waple/DesignSystem/Metrics.swift`

**Interfaces:**
- Produces: `struct DisplaysView: View` — `init(viewModel: LibraryViewModel, screenFrames: @escaping () -> [CGRect])`(자체 닫기 버튼 포함).
  `Metrics.displaysMin = NSSize(width: 860, height: 560)` 추가.
  `MainWindowView`: 시트 내용 교체 + `@State showDisplays` 초기값 `ProcessInfo.processInfo.environment["WAPLE_SMOKE_DISPLAYS"] != nil`(판정 캡처용 — WAPLE_SMOKE 기본 캡처엔 영향 없음).
- 유지: 파일 상단 `enum DisplayDiagramLayout { … }` **원문 그대로**(테스트 대상).

- [ ] **Step 1: Metrics 추가** — `static let displaysMin = NSSize(width: 860, height: 560)`.

- [ ] **Step 2: 파일 이동 + 재작성**

```bash
mkdir -p Sources/Waple/Surfaces/Displays
git mv Sources/Waple/DisplaysTabView.swift Sources/Waple/Surfaces/Displays/DisplaysView.swift
```

내용 교체 — **`DisplayDiagramLayout` enum(기존 5-22행)은 그대로 두고** 그 아래 `DisplaysTabView` struct 만 다음으로 대체:

```swift
/// 디스플레이 화면(WE 디스플레이 선택의 네이티브 번역): 모니터 배치 다이어그램에 할당 배경
/// 썸네일을 채우고, 클릭 선택 → 하단 액션(선택 배경 적용/할당 해제).
struct DisplaysView: View {
    @ObservedObject var viewModel: LibraryViewModel
    var screenFrames: () -> [CGRect]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedScreenKey: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("디스플레이", systemImage: "display.2").font(.title3.weight(.semibold))
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            GeometryReader { geo in
                let screens = viewModel.screens
                let rects = DisplayDiagramLayout.rects(screenFrames: screenFrames(),
                                                       container: geo.size, padding: 28)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(zip(screens, rects)), id: \.0.key) { screen, rect in
                        monitorBox(screen: screen, rect: rect)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            actionBar.padding(12)
        }
        .frame(minWidth: Metrics.displaysMin.width, minHeight: Metrics.displaysMin.height)
        .onAppear { if selectedScreenKey == nil { selectedScreenKey = viewModel.screens.first?.key } }
    }

    @ViewBuilder
    private func monitorBox(screen: (key: String, name: String), rect: CGRect) -> some View {
        let selected = selectedScreenKey == screen.key
        let assigned = viewModel.assignedEntry(forScreen: screen.key)
        ZStack(alignment: .bottomLeading) {
            thumbnail(for: assigned)
                .frame(width: rect.width, height: rect.height)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(screen.name).font(.callout.weight(.semibold)).foregroundStyle(.white)
                Text(assigned?.title ?? "전역 배경")
                    .font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            .padding(10)
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.tileCorner))
        .overlay(RoundedRectangle(cornerRadius: Metrics.tileCorner)
            .stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: selected ? 3 : 1))
        .contentShape(Rectangle())
        .onTapGesture { selectedScreenKey = screen.key }
        .offset(x: rect.minX, y: rect.minY)
    }

    /// 할당 배경 썸네일(gif 는 정지 첫 프레임 — 다이어그램은 배치 확인 용도). 없으면 플레이스홀더.
    @ViewBuilder
    private func thumbnail(for entry: LibraryEntry?) -> some View {
        if let entry, let url = viewModel.previewURL(for: entry), let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
                Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: Metrics.gap) {
            if let key = selectedScreenKey {
                Text(viewModel.screens.first { $0.key == key }?.name ?? key).font(.callout.weight(.semibold))
                if viewModel.focusedEntry == nil {
                    Text("설치됨 탭에서 배경을 먼저 선택하세요").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let entry = viewModel.focusedEntry { viewModel.assign(entry, toScreen: key) }
                } label: {
                    Label(applyLabel, systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.focusedEntry == nil
                          || !(viewModel.focusedEntry.map(viewModel.isSupported) ?? false))
                Button("할당 해제") { viewModel.clearAssignment(forScreen: key) }
                    .disabled(viewModel.assignedEntry(forScreen: key) == nil)
            } else {
                Text("모니터를 선택하세요").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(height: 30)
    }

    private var applyLabel: String {
        viewModel.focusedEntry.map { "'\($0.title)' 적용" } ?? "선택한 배경 적용"
    }
}
```

주의: `Metrics.gap`이 없으면(클론 시절 삭제됨) `Metrics.swift`에 `static let gap: CGFloat = 8` 추가.

- [ ] **Step 3: 셸 배선** — `MainWindowView.swift`:
- `@State private var showDisplays = false` → `= ProcessInfo.processInfo.environment["WAPLE_SMOKE_DISPLAYS"] != nil`.
- `.sheet(isPresented: $showDisplays) { … }` 내용을 다음으로 교체(기존 VStack/닫기 래퍼 제거):

```swift
        .sheet(isPresented: $showDisplays) {
            DisplaysView(viewModel: viewModel, screenFrames: screenFrames)
        }
```

- [ ] **Step 4: 빌드 + 테스트** — `swift build && swift test --filter WapleAppTests 2>&1 | tail -1` (DisplayDiagramLayoutTests 포함 그린 — enum 무변경 확인).

- [ ] **Step 5: Commit**

```bash
git add -A Sources/Waple
git commit -m "기능(ui): 디스플레이 화면 네이티브 승격 — 모니터 박스 썸네일·선택 링·적용/해제 액션 바"
```

---

### Task 3: 시트 포함 캡처 + 판정 게이트

**Files:**
- Modify: `scripts/window-id.swift` (`--bounds` 모드 추가)

**Interfaces:**
- Produces: `swift scripts/window-id.swift Waple --bounds` → `X Y W H`(정수, CG 상단원점 — screencapture -R 과 동일 좌표계). `/tmp/waple-sp3-displays.png`.

- [ ] **Step 1: --bounds 추가** — `scripts/window-id.swift` 전체 교체:

```swift
// 지정 앱(기본 Waple)의 메인창(layer 0) 정보 출력 — 캡처용.
//   window-id.swift [앱이름]            → CGWindowID
//   window-id.swift [앱이름] --bounds   → "X Y W H" (시트가 창 위에 겹쳐도 영역 캡처로 포함 가능)
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let name = args.count > 1 ? args[1] : "Waple"
let wantBounds = args.contains("--bounds")
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == name
    && (w[kCGWindowLayer as String] as? Int) == 0 {
    if wantBounds {
        guard let b = w[kCGWindowBounds as String] as? [String: Any],
              let x = b["X"] as? Double, let y = b["Y"] as? Double,
              let wd = b["Width"] as? Double, let ht = b["Height"] as? Double else { continue }
        print("\(Int(x)) \(Int(y)) \(Int(wd)) \(Int(ht))")
        exit(0)
    }
    if let id = w[kCGWindowNumber as String] as? Int { print(id); exit(0) }
}
fputs("window not found: \(name)\n", stderr)
exit(1)
```

- [ ] **Step 2: 캡처** — 시트는 별도 창이라 `-l`(단일 창)로는 누락 → 메인창 **영역** 캡처(-R, 시트 포함 합성):

```bash
swift build
WAPLE_SMOKE=1 WAPLE_SMOKE_DISPLAYS=1 .build/debug/Waple & APP=$!
sleep 7
read X Y W H <<< "$(swift scripts/window-id.swift Waple --bounds)"
screencapture -R"$X,$Y,$W,$H" -x /tmp/waple-sp3-displays.png
kill $APP
```
Expected: 디스플레이 시트(모니터 박스 썸네일·액션 바)가 담긴 캡처. 영역 캡처 특성상 창 모서리 밖 데스크탑이 소량 포함될 수 있음(무해 — 보고에 명시).

- [ ] **Step 3: Commit + 판정 요청**

```bash
git add scripts/window-id.swift
git commit -m "기능(ui): window-id --bounds — 시트 포함 영역 캡처 지원"
```

/tmp/waple-sp3-displays.png 를 사용자에게 제시 — "모니터 박스·썸네일·액션 바가 네이티브답고 쓸만한가?" 판정 통과 = SP3′ 완료.

---

## SP3′에서 의도적으로 안 하는 것

- 다이어그램 내 드래그로 배경 이동(WE 에 없는 기능 — YAGNI)
- 모니터 박스 gif 라이브 재생(배치 확인 용도라 정지 프레임 — 성능/단순)
- 검색 탭(SP4′)·설정 창/트레이(SP5′)
