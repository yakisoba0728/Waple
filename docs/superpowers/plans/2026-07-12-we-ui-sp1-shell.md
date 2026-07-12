# SP1: WE 디자인 시스템 + 창 셸 Implementation Plan

> 상태: 실행 완료 후 **폐기** — 네이티브 피벗(SP1′)이 스킨(WETheme/WEControls)을 제거. 이력 보존용.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Waple 메인창을 실제 Wallpaper Engine 2.8.42의 셸(통합 다크 타이틀바·탭 3개+우상단 버튼 3개·검색줄·하단 재생목록 바)과 시각적으로 동일하게 재구축하고, 모든 수치의 단일 출처인 WETheme 토큰을 확립한다.

**Architecture:** 디자인 시스템 선행 — `WETheme`(레퍼런스 스크린샷 실측 토큰) + 셸이 소비하는 컨트롤 킷을 만들고, `MainWindowView`를 WE 셸로 교체한다. 중앙 콘텐츠(그리드·우측 패널)는 기존 뷰를 임시 임베드(SP2에서 교체). 데이터 계층·ViewModel 콜백 계약은 무변경.

**Tech Stack:** SwiftUI(macOS 13+), AppKit(NSWindow 크롬), 외부 의존성 0. 스펙: [2026-07-12-we-ui-clone-design.md](../specs/2026-07-12-we-ui-clone-design.md)

## Global Constraints

- macOS 13+, Swift 5.9, 외부 SPM 의존성 0 (리포 원칙).
- **수치(색·간격·폰트 크기·코너)는 `WETheme`에만 존재** — 표면 뷰에 리터럴 금지.
- WE 실제 자산 파일·로고 복사 금지. 아이콘은 SF Symbols.
- 레퍼런스: `docs/reference/we/installed-filter-closed.png`, `docs/reference/we/installed-filter-open.png` (없으면 Task 1에서 중단하고 사용자에게 요청).
- 커밋 메시지: `기능(ui): …` 스타일(리포 관례), 한국어.
- 매 태스크 끝에서 `swift build` 성공 + `swift test --filter WapleAppTests` 그린 유지.
- 기존 ViewModel API(searchText·typeFilter·sortOrder·filteredEntries·onApply 등) 시그니처 변경 금지.
- 이 플랜의 색·치수 기본값은 스크린샷 육안 추정치 — Task 1이 실측으로 교정한다(추정치 그대로 출시 금지).

---

### Task 1: 레퍼런스 실측 — 스포이드 도구 + 토큰 값 추출

**Files:**
- Create: `scripts/we-eyedrop.swift`
- Create: `docs/reference/we/sp1-measurements.md`

**Interfaces:**
- Produces: `docs/reference/we/sp1-measurements.md` — Task 2가 WETheme 값을 채울 때 읽는 실측표(이름→hex/px).

- [ ] **Step 1: 레퍼런스 파일 존재 확인**

Run: `ls docs/reference/we/`
Expected: `installed-filter-closed.png`, `installed-filter-open.png` 존재.
**없으면 여기서 중단**하고 사용자에게 "WE 스크린샷 2장을 docs/reference/we/에 저장해 주세요"라고 보고한다. (스펙 규칙: 스크린샷 없이 착수 금지.)

- [ ] **Step 2: 스포이드 스크립트 작성**

`scripts/we-eyedrop.swift`:

```swift
// WE 레퍼런스 스크린샷 픽셀 스포이드. 사용:
//   swift scripts/we-eyedrop.swift <png> <fx> <fy> [반경]
// fx/fy = 0..1 비율 좌표. 반경(기본 2) 내 평균색을 hex로 출력.
import AppKit

let args = CommandLine.arguments
guard args.count >= 4,
      let img = NSImage(contentsOfFile: args[1]),
      let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let fx = Double(args[2]), let fy = Double(args[3]) else {
    fputs("usage: we-eyedrop.swift <png> <fx 0..1> <fy 0..1> [radius]\n", stderr)
    exit(2)
}
let r = args.count > 4 ? Int(args[4]) ?? 2 : 2
let px = Int(fx * Double(rep.pixelsWide - 1))
let py = Int(fy * Double(rep.pixelsHigh - 1))
var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0
for dy in -r...r {
    for dx in -r...r {
        let x = min(max(px + dx, 0), rep.pixelsWide - 1)
        let y = min(max(py + dy, 0), rep.pixelsHigh - 1)
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        sr += c.redComponent; sg += c.greenComponent; sb += c.blueComponent; n += 1
    }
}
guard n > 0 else { exit(1) }
func h(_ v: Double) -> String { String(format: "%02X", Int((v / n * 255).rounded())) }
print("#\(h(sr))\(h(sg))\(h(sb))  @(\(px),\(py)) of \(rep.pixelsWide)x\(rep.pixelsHigh)")
```

- [ ] **Step 3: 실행 확인(실패 케이스)**

Run: `swift scripts/we-eyedrop.swift`
Expected: stderr에 `usage: …`, exit code 2.

- [ ] **Step 4: 랜드마크 실측**

아래 각 지점을 `installed-filter-closed.png`(약칭 C)·`installed-filter-open.png`(약칭 O)에서 샘플링한다.
좌표는 시작점 — **출력된 색이 주변과 다르면(경계에 걸침) ±0.01씩 옮겨 균일 영역에서 다시 딴다.**

```bash
P=docs/reference/we/installed-filter-closed.png
Q=docs/reference/we/installed-filter-open.png
swift scripts/we-eyedrop.swift $P 0.50 0.020   # titlebar 배경
swift scripts/we-eyedrop.swift $P 0.50 0.052   # 탭줄 배경
swift scripts/we-eyedrop.swift $P 0.035 0.052  # 활성 탭 채움
swift scripts/we-eyedrop.swift $P 0.115 0.052  # 비활성 탭 채움
swift scripts/we-eyedrop.swift $P 0.09 0.094   # 검색창 배경
swift scripts/we-eyedrop.swift $P 0.235 0.094  # 파랑 액센트(필터 버튼)
swift scripts/we-eyedrop.swift $P 0.69 0.094   # 콤보 배경
swift scripts/we-eyedrop.swift $P 0.35 0.888 5 # 그리드 영역 배경(페이지네이션 주변)
swift scripts/we-eyedrop.swift $P 0.98 0.60 1  # 우측 패널 스크롤바 홈/패널 경계
swift scripts/we-eyedrop.swift $P 0.80 0.635   # 우측 패널 배경(속성 행 사이)
swift scripts/we-eyedrop.swift $P 0.885 0.552  # 구독 취소 빨강
swift scripts/we-eyedrop.swift $P 0.885 0.972  # 확인 버튼 파랑
swift scripts/we-eyedrop.swift $P 0.27 0.972   # 하단 대형 어두운 버튼(배경화면 열기)
swift scripts/we-eyedrop.swift $P 0.05 0.927   # 하단 바 배경(재생목록 라벨 주변)
swift scripts/we-eyedrop.swift $Q 0.055 0.128  # 필터 패널 파랑 버튼(필터 초기화)
swift scripts/we-eyedrop.swift $Q 0.08 0.30 4  # 필터 패널 배경
```

- [ ] **Step 5: 치수 실측**

미리보기 앱(또는 스크린샷 뷰어)의 픽셀 좌표로 다음을 재서 기록(스크린샷 픽셀 = 논리 pt 로 간주, 창 폭 ~1454 기준):
titlebar 높이, 탭줄 높이·탭 1개 높이/좌우 패딩, 검색줄 높이·검색창 높이/폭, 우측 패널 폭,
하단 바(재생목록 줄 높이 + 대형 버튼 줄 높이 + 상하 패딩), 버튼 코너 반경(확대해서 px 카운트), 기본 폰트 캡높이 기준 크기(제목/본문/캡션).

- [ ] **Step 6: 실측표 기록**

`docs/reference/we/sp1-measurements.md`에 아래 형식으로 전 항목 기록(값은 Step 4-5 실측 결과):

```markdown
# SP1 실측표 (WE 2.8.42, installed-filter-*.png 기준)
| 토큰 | 값 | 출처 지점 |
| --- | --- | --- |
| bgTitlebar | #.. | C 0.50,0.020 |
| bgTabRow | #.. | C 0.50,0.052 |
| tabActive | #.. | C 0.035,0.052 |
| tabInactive | #.. | C 0.115,0.052 |
| bgField | #.. | C 0.09,0.094 |
| accent | #.. | C 0.235,0.094 |
| bgControl | #.. | C 0.69,0.094 |
| bgGrid | #.. | C 0.35,0.888 |
| bgPanel | #.. | C 0.80,0.635 |
| danger | #.. | C 0.885,0.552 |
| bgBottomBar | #.. | C 0.05,0.927 |
| bgLargeButton | #.. | C 0.27,0.972 |
| bgSidebar | #.. | O 0.08,0.30 |
| titlebarH / tabRowH / searchRowH / bottomBarH | ..px | 치수 실측 |
| rightPanelW / fieldH / cornerRadius / font(title,body,caption) | ..px | 치수 실측 |
```

- [ ] **Step 7: Commit**

```bash
git add scripts/we-eyedrop.swift docs/reference/we/
git commit -m "기능(ui): WE 레퍼런스 스포이드 도구 + SP1 실측표 (스크린샷 2장 포함)"
```

---

### Task 2: WETheme — 토큰 단일 출처

**Files:**
- Create: `Sources/Waple/DesignSystem/WETheme.swift`
- Test: `Tests/WapleAppTests/WEThemeTests.swift`

**Interfaces:**
- Consumes: `docs/reference/we/sp1-measurements.md` (Task 1 실측값).
- Produces: `WETheme.Colors.*: Color` / `WETheme.Metrics.*: CGFloat` / `WETheme.Fonts.*: Font` /
  `NSColor.weWindowBackground: NSColor` / `Color(weHex: UInt32)` — 이후 전 태스크가 소비.

- [ ] **Step 1: 실패 테스트 작성**

`Tests/WapleAppTests/WEThemeTests.swift`:

```swift
import XCTest
@testable import Waple

final class WEThemeTests: XCTestCase {
    /// weHex 이니셜라이저가 RGB 성분을 정확히 복원하는지(토큰 전체가 이 경로를 탄다).
    func testHexColorRoundTrip() {
        let ns = NSColor(WETheme.color(0x2A6EE0)).usingColorSpace(.sRGB)!
        XCTAssertEqual(Int((ns.redComponent * 255).rounded()), 0x2A)
        XCTAssertEqual(Int((ns.greenComponent * 255).rounded()), 0x6E)
        XCTAssertEqual(Int((ns.blueComponent * 255).rounded()), 0xE0)
    }

    /// 토큰이 최소한 서로 구분되는 값인지(복붙 실수 방어).
    func testTokensDistinct() {
        XCTAssertNotEqual(WETheme.Metrics.titlebarH, 0)
        XCTAssertNotEqual(WETheme.Metrics.rightPanelW, 0)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter WEThemeTests`
Expected: FAIL — `cannot find 'WETheme'`.

- [ ] **Step 3: WETheme 구현**

`Sources/Waple/DesignSystem/WETheme.swift` — **아래 hex/치수 기본값을 Task 1 실측표 값으로 교체해서** 작성한다
(기본값은 육안 추정치. 실측표에 없는 항목만 기본값 유지 + `// 추정` 주석):

```swift
import SwiftUI
import AppKit

/// WE 2.8.42 실측 디자인 토큰 — 수치의 유일한 출처(표면 뷰에 리터럴 금지).
/// 출처: docs/reference/we/sp1-measurements.md (installed-filter-*.png 스포이드/실측).
enum WETheme {
    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    enum Colors {
        static let titlebar      = WETheme.color(0x0C0D13)  // 실측표 bgTitlebar 로 교체
        static let tabRow        = WETheme.color(0x0C0D13)  // bgTabRow
        static let tabActive     = WETheme.color(0x173A66)  // tabActive
        static let tabInactive   = WETheme.color(0x15161D)  // tabInactive
        static let window        = WETheme.color(0x101219)  // bgGrid(콘텐츠 기본 바탕)
        static let panel         = WETheme.color(0x14161F)  // bgPanel(우측 패널·시트)
        static let sidebar       = WETheme.color(0x12141C)  // bgSidebar(필터 패널, SP2)
        static let field         = WETheme.color(0x07080C)  // bgField(검색창)
        static let control       = WETheme.color(0x191B24)  // bgControl(콤보·일반 버튼)
        static let controlHover  = WETheme.color(0x232633)  // control 호버(실측 불가 시 control+10%)
        static let largeButton   = WETheme.color(0x191C26)  // bgLargeButton(하단 대형)
        static let bottomBar     = WETheme.color(0x0E0F16)  // bgBottomBar
        static let border        = WETheme.color(0x2A2D3A)  // 컨트롤 1px 보더(확대 실측)
        static let accent        = WETheme.color(0x2A6EE0)  // accent(필터·확인·» 파랑)
        static let danger        = WETheme.color(0xC03830)  // danger(구독 취소)
        static let textPrimary   = WETheme.color(0xFFFFFF)
        static let textSecondary = WETheme.color(0xA7ADBB)
        static let textDisabled  = WETheme.color(0x5A5F6D)
    }

    enum Metrics {
        static let titlebarH: CGFloat = 34        // 실측표로 교체
        static let tabRowH: CGFloat = 30
        static let tabH: CGFloat = 26
        static let searchRowH: CGFloat = 44
        static let fieldH: CGFloat = 30
        static let rightPanelW: CGFloat = 315
        static let bottomPlaylistRowH: CGFloat = 36
        static let bottomLargeRowH: CGFloat = 34
        static let corner: CGFloat = 3
        static let hPad: CGFloat = 10             // 셸 좌우 기본 패딩
        static let gap: CGFloat = 8               // 컨트롤 사이 기본 간격
        static let trafficLightInset: CGFloat = 78 // 신호등 폭 회피(타이틀 좌측 요소 시작점)
    }

    enum Fonts {
        static let title = Font.system(size: 13)          // 타이틀바 중앙
        static let tab = Font.system(size: 12, weight: .semibold)
        static let body = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let sectionBold = Font.system(size: 15, weight: .bold)  // "재생목록" 라벨
    }
}

extension NSColor {
    /// NSWindow.backgroundColor 용(콘텐츠가 타이틀바 아래까지 칠할 때 이음새 방지).
    static var weWindowBackground: NSColor {
        NSColor(WETheme.Colors.window)
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter WEThemeTests`
Expected: PASS 2건.

- [ ] **Step 5: Commit**

```bash
git add Sources/Waple/DesignSystem/WETheme.swift Tests/WapleAppTests/WEThemeTests.swift
git commit -m "기능(ui): WETheme 토큰 — WE 2.8.42 실측 색·치수 단일 출처"
```

---

### Task 3: WEControls — 셸 소비 컨트롤 킷

**Files:**
- Create: `Sources/Waple/DesignSystem/WEControls.swift`

**Interfaces:**
- Consumes: `WETheme.Colors/Metrics/Fonts` (Task 2).
- Produces(이후 셸 태스크가 정확히 이 시그니처로 소비):
  - `struct WEButtonStyle: ButtonStyle` — `init(kind: Kind = .toolbar)`, `enum Kind { case toolbar, accent, large, largeAccent }`
  - `struct WETabButton: View` — `init(title: String, systemImage: String, isActive: Bool, hasDropdown: Bool = false, action: @escaping () -> Void)`
  - `struct WETopButton: View` — `init(title: String, systemImage: String, disabledHint: String? = nil, action: @escaping () -> Void)`
  - `struct WESearchField: View` — `init(text: Binding<String>)`
  - `struct WEComboBox<T: Hashable>: View` — `init(selection: Binding<T>, options: [T], label: @escaping (T) -> String)`
- 비고: 체크박스·슬라이더·별점·배지·페이지네이션은 소비자가 생기는 SP2에서 추가(YAGNI — 스펙 컨트롤 킷의 잔여분).

- [ ] **Step 1: 구현**

`Sources/Waple/DesignSystem/WEControls.swift`:

```swift
import SwiftUI

/// WE 공용 버튼. toolbar=어두운 사각(우상단·재생목록 줄), accent=파랑, large*=하단 대형 2종.
struct WEButtonStyle: ButtonStyle {
    enum Kind { case toolbar, accent, large, largeAccent }
    var kind: Kind = .toolbar

    func makeBody(configuration: Configuration) -> some View {
        let bg: Color = {
            switch kind {
            case .toolbar: return WETheme.Colors.control
            case .accent: return WETheme.Colors.accent
            case .large: return WETheme.Colors.largeButton
            case .largeAccent: return WETheme.Colors.accent
            }
        }()
        let isLarge = kind == .large || kind == .largeAccent
        return configuration.label
            .font(WETheme.Fonts.body)
            .foregroundColor(WETheme.Colors.textPrimary)
            .padding(.horizontal, WETheme.Metrics.hPad)
            .frame(height: isLarge ? WETheme.Metrics.bottomLargeRowH : WETheme.Metrics.fieldH - 4)
            .frame(maxWidth: isLarge ? .infinity : nil)
            .background(configuration.isPressed ? bg.opacity(0.8) : bg)
            .overlay(RoundedRectangle(cornerRadius: WETheme.Metrics.corner)
                .stroke(WETheme.Colors.border, lineWidth: 1))
            .cornerRadius(WETheme.Metrics.corner)
            .contentShape(Rectangle())
    }
}

/// 상단 탭(설치됨/검색/창작마당). 활성=파랑 틴트 채움+파랑 보더, hasDropdown=우측 ▾.
struct WETabButton: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    var hasDropdown: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(WETheme.Fonts.caption)
                Text(title).font(WETheme.Fonts.tab)
                if hasDropdown { Image(systemName: "chevron.down").font(.system(size: 8)) }
            }
            .foregroundColor(WETheme.Colors.textPrimary)
            .padding(.horizontal, WETheme.Metrics.hPad)
            .frame(height: WETheme.Metrics.tabH)
            .background(isActive ? WETheme.Colors.tabActive : WETheme.Colors.tabInactive)
            .overlay(RoundedRectangle(cornerRadius: WETheme.Metrics.corner)
                .stroke(isActive ? WETheme.Colors.accent : WETheme.Colors.border, lineWidth: 1))
            .cornerRadius(WETheme.Metrics.corner)
        }
        .buttonStyle(.plain)
    }
}

/// 우상단 버튼(모바일/디스플레이/설정). disabledHint 있으면 비활성+툴팁.
struct WETopButton: View {
    let title: String
    let systemImage: String
    var disabledHint: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(WETheme.Fonts.caption)
                Text(title)
            }
        }
        .buttonStyle(WEButtonStyle(kind: .toolbar))
        .disabled(disabledHint != nil)
        .opacity(disabledHint != nil ? 0.55 : 1)
        .help(disabledHint ?? title)
    }
}

/// 검색창 — 좌측 텍스트, 우측 돋보기(WE 배치).
struct WESearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 0) {
            TextField("검색", text: $text)
                .textFieldStyle(.plain)
                .font(WETheme.Fonts.body)
                .foregroundColor(WETheme.Colors.textPrimary)
                .padding(.horizontal, WETheme.Metrics.hPad)
            Image(systemName: "magnifyingglass")
                .font(WETheme.Fonts.body)
                .foregroundColor(WETheme.Colors.textSecondary)
                .padding(.trailing, WETheme.Metrics.hPad)
        }
        .frame(height: WETheme.Metrics.fieldH)
        .background(WETheme.Colors.field)
        .overlay(RoundedRectangle(cornerRadius: WETheme.Metrics.corner)
            .stroke(WETheme.Colors.border, lineWidth: 1))
        .cornerRadius(WETheme.Metrics.corner)
    }
}

/// 콤보(정렬 등) — 어두운 사각 + 우측 ▾, Menu 기반.
struct WEComboBox<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { opt in
                Button(label(opt)) { selection = opt }
            }
        } label: {
            HStack {
                Text(label(selection)).font(WETheme.Fonts.body)
                    .foregroundColor(WETheme.Colors.textPrimary)
                Spacer(minLength: WETheme.Metrics.gap)
                Image(systemName: "chevron.down").font(.system(size: 9))
                    .foregroundColor(WETheme.Colors.textSecondary)
            }
            .padding(.horizontal, WETheme.Metrics.hPad)
            .frame(height: WETheme.Metrics.fieldH)
            .background(WETheme.Colors.control)
            .overlay(RoundedRectangle(cornerRadius: WETheme.Metrics.corner)
                .stroke(WETheme.Colors.border, lineWidth: 1))
            .cornerRadius(WETheme.Metrics.corner)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Waple/DesignSystem/WEControls.swift
git commit -m "기능(ui): WE 컨트롤 킷(셸 소비분) — 버튼·탭·검색창·콤보"
```

---

### Task 4: 창 크롬 — 통합 다크 타이틀바 + WAPLE_SMOKE 훅 정식화

**Files:**
- Modify: `Sources/Waple/AppDelegate.swift` (openLibrary, 약 247-265행)
- Modify: `Sources/Waple/main.swift` (기존 미커밋 WAPLE_SMOKE diff 포함 커밋)

**Interfaces:**
- Consumes: `NSColor.weWindowBackground` (Task 2).
- Produces: 창 스타일 규약 — `fullSizeContentView`+투명 타이틀바+타이틀 숨김. 셸(Task 5)은 콘텐츠 최상단에 자체 타이틀 스트립을 그린다(신호등은 좌상단 오버레이).

- [ ] **Step 1: openLibrary 창 설정 수정**

`AppDelegate.openLibrary()`의 창 생성부를 다음으로 교체(기존 `window.appearance` 줄 유지):

```swift
let window = NSWindow(contentViewController: hosting)
window.title = "Waple"
window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.backgroundColor = .weWindowBackground
window.setContentSize(NSSize(width: 1456, height: 1000))   // WE 실측 창 크기(실측표 확인)
window.minSize = NSSize(width: 1100, height: 700)
window.appearance = NSAppearance(named: .darkAqua)
window.isReleasedWhenClosed = false
```

- [ ] **Step 2: 빌드 + 육안 확인**

Run: `swift build && { WAPLE_SMOKE=1 .build/debug/Waple & APP=$!; sleep 5; screencapture -x /tmp/sp1-t4.png; kill $APP; }`
(macOS에 `timeout` 없음 — 백그라운드+kill 패턴 고정.)
Expected: 빌드 성공, 창이 뜨고 타이틀바 영역까지 어두운 배경(기존 콘텐츠가 위로 확장돼 보여도 이 시점엔 정상).

- [ ] **Step 3: 전체 앱 테스트 그린 확인**

Run: `swift test --filter WapleAppTests 2>&1 | tail -3`
Expected: PASS (기존 115+2건).

- [ ] **Step 4: Commit (미커밋 스모크 훅 포함)**

```bash
git add Sources/Waple/AppDelegate.swift Sources/Waple/main.swift
git commit -m "기능(ui): 통합 다크 타이틀바(fullSizeContentView) + WAPLE_SMOKE 스모크 훅 정식화"
```

---

### Task 5: 셸 골격 — 타이틀 스트립 + 탭줄

**Files:**
- Create: `Sources/Waple/Shell/` (디렉터리)
- Modify: `Sources/Waple/MainWindowView.swift` → `git mv Sources/Waple/MainWindowView.swift Sources/Waple/Shell/MainWindowView.swift` 후 내용 교체

**Interfaces:**
- Consumes: `WETabButton`/`WETopButton`(Task 3), `WETheme`(Task 2), 기존 `LibraryViewModel`·`WallpaperGridView`·`SelectionPanelView`·`WorkshopView`·`DisplaysTabView`(무변경 임베드).
- Produces: `enum MainTab { case installed, discover, workshop }` / `struct MainWindowView: View` —
  `init(viewModel: LibraryViewModel, screenFrames: @escaping () -> [CGRect])` (기존 시그니처 유지 — AppDelegate 호출부 무변경).
  내부 `@State tab`, `@State showDisplays`(디스플레이 시트), `@State panelVisible = true`(» 토글).

- [ ] **Step 1: 파일 이동 + 셸 교체**

```bash
mkdir -p Sources/Waple/Shell && git mv Sources/Waple/MainWindowView.swift Sources/Waple/Shell/MainWindowView.swift
```

내용 전체를 다음으로 교체:

```swift
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
```

- [ ] **Step 2: 빌드 + 테스트**

Run: `swift build && swift test --filter WapleAppTests 2>&1 | tail -3`
Expected: 빌드 성공, PASS. (구 `MainTab.displays` 참조는 소스에 없음 — 확인 완료된 사실.)

- [ ] **Step 3: 스모크 육안 확인**

Run: `{ WAPLE_SMOKE=1 .build/debug/Waple & APP=$!; sleep 5; screencapture -x /tmp/sp1-t5.png; kill $APP; }`
Expected: /tmp/sp1-t5.png에서 타이틀 스트립·탭 3개·우측 버튼 3개·» 토글이 WE 배치로 보임.

- [ ] **Step 4: Commit**

```bash
git add -A Sources/Waple
git commit -m "기능(ui): WE 셸 골격 — 타이틀 스트립(상태·타이틀·» 토글) + 탭 3개/우상단 버튼 3개"
```

---

### Task 6: 검색줄 — 검색창·필터 토글·정렬

**Files:**
- Modify: `Sources/Waple/Shell/MainWindowView.swift`

**Interfaces:**
- Consumes: `WESearchField`/`WEComboBox`/`WEButtonStyle`(Task 3), 기존 `viewModel.searchText`/`typeFilter`/`sortOrder`(`LibraryTypeFilter`/`LibrarySortOrder` — LibraryFiltering.swift, 무변경).
- Produces: `searchRow` 뷰 — 설치됨 탭에서만 표시(WE 동일). 필터 버튼은 임시 popover로 기존 타입 필터 수용(SP2에서 사이드바로 대체).

- [ ] **Step 1: searchRow 추가**

`MainWindowView`에 `@State private var showFilterPopover = false` 추가, `content` 위(탭줄 아래)에 삽입:

```swift
// body의 VStack: titleStrip / tabRow / (tab == .installed ? searchRow : nil) / content
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
```

`body`의 `VStack`을 다음으로 갱신:

```swift
VStack(spacing: 0) {
    titleStrip
    tabRow
    if tab == .installed { searchRow }
    content
}
```

- [ ] **Step 2: 빌드 + 테스트 + 스모크**

Run: `swift build && swift test --filter WapleAppTests 2>&1 | tail -3 && { WAPLE_SMOKE=1 .build/debug/Waple & APP=$!; sleep 5; screencapture -x /tmp/sp1-t6.png; kill $APP; }`
Expected: 그린 + 검색줄이 WE 배치(검색창·파랑 필터 버튼 좌측, ▲·정렬 콤보 우측).

- [ ] **Step 3: Commit**

```bash
git add Sources/Waple/Shell/MainWindowView.swift
git commit -m "기능(ui): WE 검색줄 — 검색창·필터 토글(임시 popover)·정렬 콤보"
```

---

### Task 7: 하단 바 — 재생목록 줄 + 대형 버튼 2개

**Files:**
- Modify: `Sources/Waple/Shell/MainWindowView.swift`

**Interfaces:**
- Consumes: `WEButtonStyle`(Task 3), 기존 `viewModel.playlist`(PlaylistStore)·`viewModel.focusedEntry`·`viewModel.togglePlaylist(_:)`·`viewModel.isInPlaylist(_:)`·`viewModel.onAdvancePlaylist`·`viewModel.onTogglePause`·`viewModel.isPaused`, `WallpaperGridView.importFolder()`와 동일한 NSOpenPanel 패턴.
- Produces: `bottomBar` 뷰. 매핑: 배경화면 추가=포커스 항목 재생목록 토글 / 구성=popover(자동 전환·간격·다음·일시정지 — 기존 기능 재수용) / 배경화면 열기=임포트 패널 / 불러오기·저장·편집기=비활성+툴팁.

- [ ] **Step 1: bottomBar 구현**

`MainWindowView`에 `@State private var showPlaylistConfig = false` 추가, `body` VStack 마지막에 `bottomBar` 추가:

```swift
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
```

파일 상단에 `import AppKit`과 `import WapleCore` 추가(NSOpenPanel·VideoImport).

- [ ] **Step 2: 빌드 + 테스트 + 스모크**

Run: `swift build && swift test --filter WapleAppTests 2>&1 | tail -3 && { WAPLE_SMOKE=1 .build/debug/Waple & APP=$!; sleep 5; screencapture -x /tmp/sp1-t7.png; kill $APP; }`
Expected: 그린 + 하단 바 2줄(재생목록 줄 + 대형 버튼 2개)이 WE 배치.

- [ ] **Step 3: Commit**

```bash
git add Sources/Waple/Shell/MainWindowView.swift
git commit -m "기능(ui): WE 하단 바 — 재생목록 줄(구성 popover에 기존 기능 수용) + 편집기/열기 대형 버튼"
```

---

### Task 8: WEStatusBanner + notify() UI 승격

**Files:**
- Create: `Sources/Waple/Shell/WEStatusBanner.swift`
- Modify: `Sources/Waple/AppDelegate.swift` (notify(), openLibrary(), libraryVM 배선부)
- Modify: `Sources/Waple/Shell/MainWindowView.swift` (배너 오버레이)
- Test: `Tests/WapleAppTests/StatusBannerModelTests.swift`

**Interfaces:**
- Produces:
  - `final class StatusBannerModel: ObservableObject` — `@Published private(set) var message: String?`,
    `@Published private(set) var generation: Int`, `func show(_ message: String)`, `func dismiss()`.
  - `struct WEStatusBanner: View` — `init(model: StatusBannerModel)`. 표시 4초 후 자동 소멸(.task(id: generation)).
  - `MainWindowView.init(viewModel:banner:screenFrames:)` — **시그니처 변경**, AppDelegate 호출부 동시 수정.
  - `AppDelegate.notify()` — NSLog 항상 + 메인창 표시 중이면 배너.

- [ ] **Step 1: 실패 테스트 작성**

`Tests/WapleAppTests/StatusBannerModelTests.swift`:

```swift
import XCTest
@testable import Waple

final class StatusBannerModelTests: XCTestCase {
    func testShowSetsMessageAndBumpsGeneration() {
        let m = StatusBannerModel()
        XCTAssertNil(m.message)
        m.show("적용 실패")
        XCTAssertEqual(m.message, "적용 실패")
        let g1 = m.generation
        m.show("두 번째")   // 연속 표시 → 세대 증가(자동소멸 타이머 리셋 근거)
        XCTAssertEqual(m.message, "두 번째")
        XCTAssertGreaterThan(m.generation, g1)
    }

    func testDismissClears() {
        let m = StatusBannerModel()
        m.show("x")
        m.dismiss()
        XCTAssertNil(m.message)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter StatusBannerModelTests`
Expected: FAIL — `cannot find 'StatusBannerModel'`.

- [ ] **Step 3: 구현**

`Sources/Waple/Shell/WEStatusBanner.swift`:

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

/// WE식 상단 배너 — 어두운 패널 + 파랑 보더, 4초 후 자동 소멸.
struct WEStatusBanner: View {
    @ObservedObject var model: StatusBannerModel

    var body: some View {
        if let msg = model.message {
            Text(msg)
                .font(WETheme.Fonts.body)
                .foregroundColor(WETheme.Colors.textPrimary)
                .padding(.horizontal, WETheme.Metrics.hPad * 2)
                .padding(.vertical, 8)
                .background(WETheme.Colors.panel)
                .overlay(RoundedRectangle(cornerRadius: WETheme.Metrics.corner)
                    .stroke(WETheme.Colors.accent, lineWidth: 1))
                .cornerRadius(WETheme.Metrics.corner)
                .padding(.top, WETheme.Metrics.titlebarH + 8)
                .task(id: model.generation) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    model.dismiss()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
```

- [ ] **Step 4: 배선**

`MainWindowView`: `@ObservedObject var banner: StatusBannerModel` 프로퍼티 추가(뷰모델 다음 위치),
`body`의 최상위를 `.overlay(alignment: .top) { WEStatusBanner(model: banner) }`로 감싼다.

`AppDelegate`:

```swift
// 프로퍼티 추가(libraryVM 근처):
private let bannerModel = StatusBannerModel()

// openLibrary()의 root 생성부 교체:
let root = MainWindowView(viewModel: libraryVM, banner: bannerModel,
                          screenFrames: { NSScreen.screens.map(\.frame) })

// notify() 교체:
private func notify(_ message: String) {
    NSLog("%@", "[Waple] \(message)")
    if let w = libraryWindow, w.isVisible {
        bannerModel.show(message)
    }
}
```

- [ ] **Step 5: 테스트 통과 + 전체 그린**

Run: `swift test --filter WapleAppTests 2>&1 | tail -3`
Expected: PASS (신규 2건 포함).

- [ ] **Step 6: Commit**

```bash
git add Sources/Waple/Shell/WEStatusBanner.swift Sources/Waple/Shell/MainWindowView.swift Sources/Waple/AppDelegate.swift Tests/WapleAppTests/StatusBannerModelTests.swift
git commit -m "기능(ui): WEStatusBanner — notify() 창 내 배너 승격(NSLog 병행, AUDIT high 표적 해소)"
```

---

### Task 9: 통합 정리 — 다크 강제 일원화 + 전체 검증

**Files:**
- Modify: `Sources/Waple/Shell/MainWindowView.swift` (잔여 정리)
- Modify: `Sources/Waple/WallpaperGridView.swift`, `Sources/Waple/SelectionPanelView.swift` (배경색만 WETheme으로 — 셸과 이음새 제거)

**Interfaces:**
- Consumes: 앞 태스크 전부.
- Produces: SP1 완성 상태 — 이후 SP2가 `WallpaperGridView`/`SelectionPanelView`를 통째로 교체.

- [ ] **Step 1: 이음새 제거**

기존 뷰가 셸 안에서 시스템 색으로 떠 보이는 부분만 최소 수정:
- `SelectionPanelView.body`의 `.background(Color(nsColor: .windowBackgroundColor).opacity(0.6))` →
  `.background(WETheme.Colors.panel)`.
- `WallpaperGridView`의 `emptyState`/그리드 컨테이너에 `.background(WETheme.Colors.window)` 추가.
(두 파일 다른 부분 수정 금지 — SP2에서 통째 교체 예정.)

- [ ] **Step 2: 전체 테스트**

Run: `swift test 2>&1 | tail -5`
Expected: 전 타깃 PASS(렌더 스위트 포함 — 시간 오래 걸리면 `--filter WapleAppTests` + `--filter WapleLibraryTests`로 최소 확인 후 전체는 백그라운드로).

- [ ] **Step 3: Commit**

```bash
git add Sources/Waple/WallpaperGridView.swift Sources/Waple/SelectionPanelView.swift
git commit -m "기능(ui): SP1 통합 정리 — 기존 임베드 뷰 배경을 WETheme으로 통일"
```

---

### Task 10: 좌우비교 산출 + 사용자 판정 게이트

**Files:**
- Create: `scripts/we-compare.sh`
- Create: `docs/reference/we/compare-sp1.html`

**Interfaces:**
- Consumes: WAPLE_SMOKE 훅(Task 4), 레퍼런스 PNG(Task 1).
- Produces: `docs/reference/we/compare-sp1.html` — WE 스크린샷과 Waple 캡처를 좌우 배치. 사용자 판정이 SP1 완료 게이트.

- [ ] **Step 1: 비교 스크립트 작성**

`scripts/we-compare.sh`:

```bash
#!/bin/bash
# 사용: scripts/we-compare.sh <sp-라벨> <we-레퍼런스.png>
# WAPLE_SMOKE로 앱을 띄워 메인창을 캡처하고, 레퍼런스와 좌우 배치한 HTML을 생성한다.
set -euo pipefail
cd "$(dirname "$0")/.."
LABEL="${1:?usage: we-compare.sh <label> <reference.png>}"
REF="${2:?usage: we-compare.sh <label> <reference.png>}"
OUT="docs/reference/we"
swift build
WAPLE_SMOKE=1 .build/debug/Waple &
APP_PID=$!
sleep 6
# 메인창 위치·크기(AppleScript) → 영역 캡처(그림자 없이).
read -r X Y W H < <(osascript -e 'tell application "System Events" to tell (first process whose unix id is '"$APP_PID"')
  set p to position of window 1
  set s to size of window 1
  return ((item 1 of p) as text) & " " & ((item 2 of p) as text) & " " & ((item 1 of s) as text) & " " & ((item 2 of s) as text)
end tell')
screencapture -x -R"$X,$Y,$W,$H" "$OUT/waple-$LABEL.png"
kill $APP_PID 2>/dev/null || true
cat > "$OUT/compare-$LABEL.html" <<HTML
<!doctype html><meta charset="utf-8"><title>WE vs Waple — $LABEL</title>
<body style="margin:0;background:#000;color:#fff;font:13px -apple-system">
<div style="display:flex;gap:4px">
<figure style="flex:1;margin:0"><figcaption>WE (레퍼런스)</figcaption><img src="$(basename "$REF")" style="width:100%"></figure>
<figure style="flex:1;margin:0"><figcaption>Waple ($LABEL)</figcaption><img src="waple-$LABEL.png" style="width:100%"></figure>
</div></body>
HTML
echo "→ $OUT/compare-$LABEL.html"
```

Run: `chmod +x scripts/we-compare.sh`

- [ ] **Step 2: 비교 산출**

Run: `scripts/we-compare.sh sp1 docs/reference/we/installed-filter-closed.png`
Expected: `docs/reference/we/compare-sp1.html` 생성. (System Events 접근성 프롬프트가 뜨면 승인 후 재실행.)

- [ ] **Step 3: 사용자 판정 요청**

compare-sp1.html(또는 두 PNG)을 사용자에게 제시하고 판정을 받는다:
"타이틀 스트립·탭줄·검색줄·하단 바가 WE와 동일한가? 색·간격·크기 중 어긋난 항목 지적 부탁."
지적 항목은 **WETheme 값 수정으로만** 반영(뷰 코드 수정은 구조 오류일 때만). 판정 통과까지 반복.

- [ ] **Step 4: Commit**

```bash
git add scripts/we-compare.sh docs/reference/we/
git commit -m "기능(ui): WE 좌우비교 스크립트 + SP1 비교 산출물"
```

---

## 태스크 순서와 의존

1 (실측) → 2 (WETheme) → 3 (컨트롤) → 4 (크롬) → 5 (셸 골격) → 6 (검색줄) → 7 (하단 바) → 8 (배너) → 9 (통합) → 10 (판정 게이트).
5-8은 모두 5의 파일을 수정하므로 순차 실행(병렬 금지). 매 태스크 커밋 시점에 빌드·테스트 그린.

## SP1에서 의도적으로 안 하는 것

- 그리드·우측 패널·필터 사이드바의 WE화 (SP2 — 지금은 기존 뷰 임베드)
- 컨트롤 킷 잔여분: 체크박스·슬라이더·별점·배지·페이지네이션 (SP2, 소비자와 함께)
- 검색(디스커버) 탭 콘텐츠 (SP4), 설정 창 (SP5), 디스플레이 화면 WE화 (SP3 — 지금은 기존 뷰 시트)
- 트레이 메뉴 축소 (SP5 — 설정 창이 생겨야 옮길 곳이 있음)
