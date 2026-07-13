# SP5′ 설정 창 + 트레이 축소 — 구현 플랜

> **For agentic workers:** 단일 서브에이전트가 Task 1→3 순서로 통째 실행한다. 각 스텝은 체크박스(`- [ ]`)로 추적. Task 4(캡처·판정)는 메인 에이전트 몫 — 실행하지 않는다.

**Goal:** 트레이(상태바) 메뉴에 흩어진 설정 8종(화면 맞춤·동영상 음량/배속·재생목록·가림 정지·정적 배경 동기화·기본 에셋·화면보호기·로그인 시작)을 네이티브 설정 창(grouped Form)으로 통합하고, 트레이를 6항목(열기·최근 배경·일시정지(신설)·설정…·구분선·종료)으로 축소한다.

**Architecture:** `main.swift`가 raw `NSApplication`이라 SwiftUI `Settings{}` 씬 불가 — 설정 창은 **openLibrary 패턴의 별도 NSWindow**(darkAqua·`isReleasedWhenClosed=false`·강한 참조·중복 오픈 가드). 저장은 기존 전역 스토어(`SceneRenderSettings`·`VideoSettings`·`BaseAssetsSettings`·`PlaylistStore`·UserDefaults 키) 그대로, **적용 side-effect(리마운트·타이머·복원·saver 설치)는 전부 AppDelegate 콜백 주입**(`LibraryViewModel.on*` 전례). 표시용 스텝/상태 판정은 순수 `SettingsPresentation`으로 뽑아 단위 테스트.

**Tech Stack:** SwiftUI(macOS 14+, grouped Form), AppKit(NSWindow·NSStatusItem), XCTest. 의존성 추가 없음.

## Global Constraints (전 Task 공통 — 위반 시 판정 탈락)

- **항상 다크**: 설정 창도 `NSAppearance(named: .darkAqua)` 강제. 라이트 대응 코드 금지.
- **커스텀 hex 색 금지**: 시맨틱 컬러·시스템 재질만. **치수는 `Metrics`만**(미세 인라인 패딩 관례는 기존 뷰 따름).
- **WE 자산/로고 복사 금지**. SF Symbols만.
- **macOS 14 floor**: `.formStyle(.grouped)`·`LabeledContent`·2-파라미터 `onChange` 사용 가능.
- **전체 `swift test` 금지** — `swift test --filter <클래스명>` 개별 실행만.
- **git push 금지**. main 직접 커밋, 메시지 `기능(ui): …`.
- **SourceKit/IDE 진단 무시** — `swift build` 출력이 정본.
- **동영상 음량/배속은 이산 스텝 유지(연속 Slider 금지)** — `WallpaperRenderer`에 라이브 setter가 없어 값 변경=teardown+재mount(재생 리셋). 틱마다 리마운트되는 슬라이더는 사고다. 라이브 반영(`queue.volume`/`defaultRate`)은 BACKLOG 기존 항목 유지.
- **기존 동작 보존**: 설정 항목의 저장 키·기본값·적용 경로(리마운트/타이머/복원)는 바꾸지 않는다 — 겉(UI 위치)만 이동.

## 파일 구조

| 파일 | 처분 | 책임 |
| --- | --- | --- |
| `Sources/Waple/AppLogic.swift` | 수정(끝에 추가) | `SettingsPresentation` 순수 카탈로그/상태 판정 |
| `Sources/Waple/Surfaces/Settings/SettingsViewModel.swift` | 생성 | 설정 상태 미러 + AppDelegate 콜백 소비 |
| `Sources/Waple/Surfaces/Settings/SettingsView.swift` | 생성 | grouped Form 5섹션 |
| `Sources/Waple/AppDelegate.swift` | 수정 | 트레이 축소·`openSettings()` 창·코어 setter 분리·VM 주입 |
| `Sources/Waple/LibraryViewModel.swift` | 수정 | `onOpenSettings` 콜백 1줄 추가 |
| `Sources/Waple/Shell/MainWindowView.swift` | 수정 | 설정 버튼 활성화(콜백 호출) |
| `Sources/Waple/main.swift` | 수정 | `WAPLE_SMOKE_SETTINGS` 액티베이션 정책 |
| `Sources/Waple/DesignSystem/Metrics.swift` | 수정 | `settingsSize` |
| `Tests/WapleAppTests/SettingsPresentationTests.swift` | 생성 | 스텝·옵션·상태 판정 테스트 |

**의도적 제외(스코프 아웃):** ① 동영상 음량/배속 라이브 반영(BACKLOG 기존 항목 유지 — 여기선 이산 스텝+리마운트 그대로). ② ffmpeg 경로 설정 UI — `FFmpegConverter`는 env/고정경로 탐지 전용이라 **읽기 전용 상태 표시만**. ③ 잠금화면/스틸 세부 옵션 — 토글 하나만 이동. ④ "웹 조작 창 열기"는 트레이에서 제거하되 설정 창에 넣지 않음(그리드 우클릭 "적용 + 조작 창 열기"로 기존 도달 가능). ⑤ 트레이 아이콘 커스텀(현행 "🖼" 유지).

**트레이 축소 후 구성(6항목):** `Waple 열기 ⌘L` / `최근 배경 ▸` / `일시정지↔재개 ⌘P`(**신설** — 기존엔 수동 정지가 메인창 하단 바 전용이었음, `toggleGlobalPause()` 재사용) / `설정… ⌘,` / 구분선 / `Quit ⌘Q`.

---

### Task 1: SettingsPresentation 순수 로직 + 테스트

**Files:**
- Modify: `Sources/Waple/AppLogic.swift` (파일 끝에 enum 추가)
- Test: `Tests/WapleAppTests/SettingsPresentationTests.swift` (생성)

**Interfaces:**
- Consumes: `OcclusionMode.isSelected(_:enabled:threshold:)` (AppLogic.swift 기존, AppLogicTests로 검증돼 있음)
- Produces(후속 Task가 의존):
  - `SettingsPresentation.volumeSteps/rateSteps: [(label: String, value: Float)]`
  - `SettingsPresentation.playlistIntervalMinutes: [Int]`
  - `SettingsPresentation.occlusionOptions: [(label: String, raw: Double)]`
  - `SettingsPresentation.currentOcclusionRaw(enabled:threshold:) -> Double`
  - `SettingsPresentation.saverStatus(bundled:selected:) -> (label: String, canToggle: Bool)`
  - `SettingsPresentation.ffmpegStatus(available:path:) -> String`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/WapleAppTests/SettingsPresentationTests.swift` 생성:

```swift
import XCTest
@testable import Waple

/// 설정 창 표시용 순수 카탈로그/상태 판정 — 스텝 값이 기존 트레이 메뉴 값과 동일함을 고정한다.
final class SettingsPresentationTests: XCTestCase {

    func testVolumeAndRateStepsMatchLegacyTrayValues() {
        XCTAssertEqual(SettingsPresentation.volumeSteps.map(\.value), [0, 0.25, 0.5, 0.75, 1],
                       "기존 트레이 음소거/25/50/75/100% 와 동일해야 저장값 호환")
        XCTAssertEqual(SettingsPresentation.rateSteps.map(\.value), [0.5, 1, 1.5, 2])
        XCTAssertEqual(SettingsPresentation.playlistIntervalMinutes, [5, 15, 30, 60])
        for s in SettingsPresentation.volumeSteps + SettingsPresentation.rateSteps {
            XCTAssertFalse(s.label.isEmpty)
        }
    }

    func testOcclusionOptionsMatchLegacyMenu() {
        XCTAssertEqual(SettingsPresentation.occlusionOptions.map(\.raw), [-1, 0, 0.30, 0.50, 0.80],
                       "트레이 서브메뉴(사용 안 함/즉시/30/50/80%)에서 그대로 이관")
    }

    func testCurrentOcclusionRawRoundTripsEachOption() {
        for option in SettingsPresentation.occlusionOptions {
            let (enabled, threshold) = OcclusionMode.decode(option.raw)
            XCTAssertEqual(SettingsPresentation.currentOcclusionRaw(enabled: enabled, threshold: threshold),
                           option.raw, "옵션 \(option.label) 저장 → 역산 왕복")
        }
    }

    func testCurrentOcclusionRawFallsBackToOffForUnknownThreshold() {
        // 임계값은 옵션으로만 저장되므로 실사용 불가 경로 — 방어 폴백만 고정한다.
        XCTAssertEqual(SettingsPresentation.currentOcclusionRaw(enabled: true, threshold: 0.33), -1)
    }

    func testSaverStatus() {
        let dev = SettingsPresentation.saverStatus(bundled: false, selected: false)
        XCTAssertFalse(dev.canToggle, "번들에 .saver 없으면(개발 실행) 토글 불가")
        XCTAssertTrue(dev.label.contains("package-app"), "패키징 안내 포함")
        XCTAssertTrue(SettingsPresentation.saverStatus(bundled: true, selected: true).canToggle)
        XCTAssertTrue(SettingsPresentation.saverStatus(bundled: true, selected: true).label.contains("사용 중"))
        XCTAssertTrue(SettingsPresentation.saverStatus(bundled: true, selected: false).canToggle)
    }

    func testFFmpegStatus() {
        XCTAssertTrue(SettingsPresentation.ffmpegStatus(available: true, path: "/opt/homebrew/bin/ffmpeg")
            .contains("/opt/homebrew/bin/ffmpeg"))
        XCTAssertTrue(SettingsPresentation.ffmpegStatus(available: false, path: nil).contains("brew install ffmpeg"))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter SettingsPresentationTests 2>&1 | tail -6`
Expected: **컴파일 실패** — `SettingsPresentation` 미존재.

- [ ] **Step 3: 구현**

`Sources/Waple/AppLogic.swift` 파일 끝에 추가:

```swift
// MARK: - 설정 창 표시 카탈로그 (SP5′)

/// 설정 창의 스텝 목록·상태 라벨 — 순수. 값은 기존 트레이 메뉴와 동일해야 저장값이 호환된다.
enum SettingsPresentation {
    static let volumeSteps: [(label: String, value: Float)] = [
        ("음소거", 0), ("25%", 0.25), ("50%", 0.5), ("75%", 0.75), ("100%", 1),
    ]
    static let rateSteps: [(label: String, value: Float)] = [
        ("0.5×", 0.5), ("1×", 1), ("1.5×", 1.5), ("2×", 2),
    ]
    static let playlistIntervalMinutes = [5, 15, 30, 60]

    /// 가림 정지 옵션(raw: -1=사용 안 함, 0=창 뜨면 즉시, 0.3/0.5/0.8=커버 비율) — 트레이 서브메뉴에서 이관.
    static let occlusionOptions: [(label: String, raw: Double)] = [
        ("사용 안 함", -1),
        ("창이 뜨면 즉시", 0),
        ("30% 이상 가려지면", 0.30),
        ("50% 이상 가려지면", 0.50),
        ("80% 이상 가려지면", 0.80),
    ]

    /// 영속 상태(enabled+threshold) → Picker 선택 raw 역산. 미일치는 방어 폴백(-1).
    static func currentOcclusionRaw(enabled: Bool, threshold: Double) -> Double {
        occlusionOptions.first {
            OcclusionMode.isSelected($0.raw, enabled: enabled, threshold: threshold)
        }?.raw ?? -1
    }

    /// 화면보호기 행 상태. bundled = 앱 번들에 Waple.saver 존재(패키징 앱에서만 true).
    static func saverStatus(bundled: Bool, selected: Bool) -> (label: String, canToggle: Bool) {
        guard bundled else {
            return ("패키징된 앱에서만 사용 가능 — scripts/package-app.sh", false)
        }
        return (selected ? "화면보호기로 사용 중" : "사용 안 함", true)
    }

    static func ffmpegStatus(available: Bool, path: String?) -> String {
        available ? "사용 가능 — \(path ?? "")"
                  : "미설치 — mkv/webm 동영상 변환에 필요합니다 (brew install ffmpeg)"
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter SettingsPresentationTests 2>&1 | tail -6` → Expected: `Executed 6 tests, with 0 failures`
Run: `swift test --filter AppLogicTests 2>&1 | tail -4` → Expected: 0 failures (같은 파일 회귀)

- [ ] **Step 5: Commit**

```bash
git add Sources/Waple/AppLogic.swift Tests/WapleAppTests/SettingsPresentationTests.swift
git commit -m "기능(ui): 설정 표시 순수 카탈로그 — 볼륨/배속/간격 스텝·가림 옵션·saver/ffmpeg 상태 판정"
```

---

### Task 2: SettingsViewModel + SettingsView + Metrics

**Files:**
- Create: `Sources/Waple/Surfaces/Settings/SettingsViewModel.swift`
- Create: `Sources/Waple/Surfaces/Settings/SettingsView.swift`
- Modify: `Sources/Waple/DesignSystem/Metrics.swift`

**Interfaces:**
- Consumes: Task 1 `SettingsPresentation`, 기존 전역 스토어 `SceneRenderSettings.fitMode`·`VideoSettings`·`BaseAssetsSettings.baseAssetsDirectory`·`PlaylistStore`·`LoginItemController`·`ScreenSaverController.isSelected`·`FFmpegConverter.isAvailable/executableURL`, `FitMode.allCases/.label`
- Produces(Task 3가 의존):
  - `SettingsViewModel(playlist: PlaylistStore)` + 주입 클로저: `onApplySelection: (() -> Void)?`, `onSetOcclusion: ((Double) -> Void)?`, `onSetStillSync: ((Bool) -> Void)?`, `onPlaylistChanged: (() -> Void)?`, `onChooseBaseAssets: (() -> Void)?`, `onSetStillWallpaper: (() -> Void)?`, `onToggleSaver: (() -> Bool)?`, `videoTargetIds: () -> [String]`, `occlusionState: () -> (enabled: Bool, threshold: Double)`, `stillSyncEnabled: () -> Bool`
  - `func refresh()`
  - `struct SettingsView: View { @ObservedObject var vm: SettingsViewModel }`
  - `Metrics.settingsSize`

주의: 스토어 시그니처(특히 `BaseAssetsSettings.baseAssetsDirectory`의 옵셔널 여부, `PlaylistStore.enabled/intervalMinutes`)는 실제 코드에 맞춘다 — 아래 코드에서 컴파일이 어긋나면 실코드 우선, 편차 기록.

- [ ] **Step 1: Metrics 추가**

`Metrics.swift`의 `// 검색·창작마당 탭 (SP4′)` 블록 뒤에 추가:

```swift
    // 설정 창 (SP5′)
    static let settingsSize = NSSize(width: 560, height: 640)
```

- [ ] **Step 2: SettingsViewModel.swift 생성**

```swift
import SwiftUI
import WapleCore
import WapleLibrary
import WapleRender

/// 설정 창 상태 미러 + 배선. 저장은 기존 전역 스토어를 직접 읽고 쓰되,
/// 적용 side-effect(리마운트·타이머·복원·saver 설치)는 전부 AppDelegate 주입 클로저로 위임한다
/// (LibraryViewModel.on* 전례 — 뷰가 AppDelegate 내부에 직접 손대지 않는다).
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var fitMode: FitMode = SceneRenderSettings.fitMode
    @Published var occlusionRaw: Double = -1
    @Published var playlistEnabled = false
    @Published var playlistInterval = 15
    @Published var videoVolume: Float?     // nil = 적용 중인 동영상 없음(컨트롤 비활성)
    @Published var videoRate: Float?
    @Published var loginEnabled = LoginItemController.isEnabled
    @Published var stillSync = false
    @Published var saverSelected = ScreenSaverController.isSelected
    @Published var baseAssetsPath = ""
    @Published var statusMessage: String?

    let saverBundled = Bundle.main.url(forResource: "Waple", withExtension: "saver") != nil
    var ffmpegStatus: String {
        SettingsPresentation.ffmpegStatus(available: FFmpegConverter.isAvailable,
                                          path: FFmpegConverter.executableURL?.path)
    }

    private let playlist: PlaylistStore

    // AppDelegate 주입 클로저(측정자/side-effect). 기본값은 no-op — 프리뷰/테스트 안전.
    var onApplySelection: (() -> Void)?
    var onSetOcclusion: ((Double) -> Void)?
    var onSetStillSync: ((Bool) -> Void)?
    var onPlaylistChanged: (() -> Void)?
    var onChooseBaseAssets: (() -> Void)?
    var onSetStillWallpaper: (() -> Void)?
    var onToggleSaver: (() -> Bool)?
    var videoTargetIds: () -> [String] = { [] }
    var occlusionState: () -> (enabled: Bool, threshold: Double) = { (false, 0) }
    var stillSyncEnabled: () -> Bool = { false }

    init(playlist: PlaylistStore) {
        self.playlist = playlist
    }

    /// 창을 열 때마다 실제 스토어에서 다시 읽는다(트레이/적용 경로가 그 사이 바꿨을 수 있음).
    func refresh() {
        fitMode = SceneRenderSettings.fitMode
        let occ = occlusionState()
        occlusionRaw = SettingsPresentation.currentOcclusionRaw(enabled: occ.enabled, threshold: occ.threshold)
        playlistEnabled = playlist.enabled
        playlistInterval = playlist.intervalMinutes
        let ids = videoTargetIds()
        videoVolume = ids.first.map { VideoSettings.volume(id: $0) }
        videoRate = ids.first.map { VideoSettings.rate(id: $0) }
        loginEnabled = LoginItemController.isEnabled
        stillSync = stillSyncEnabled()
        saverSelected = ScreenSaverController.isSelected
        baseAssetsPath = BaseAssetsSettings.baseAssetsDirectory?.path ?? "(자동 탐지)"
        statusMessage = nil
    }

    func setFit(_ mode: FitMode) {
        SceneRenderSettings.fitMode = mode
        fitMode = mode
        onApplySelection?()
    }

    func setOcclusion(_ raw: Double) {
        occlusionRaw = raw
        onSetOcclusion?(raw)   // AppDelegate 가 decode·영속·폴링 타이머 재구성
    }

    func setPlaylistEnabled(_ on: Bool) {
        playlist.enabled = on
        playlistEnabled = on
        onPlaylistChanged?()
    }

    func setPlaylistInterval(_ minutes: Int) {
        playlist.intervalMinutes = minutes
        playlistInterval = minutes
        onPlaylistChanged?()
    }

    func setVolume(_ v: Float) {
        let ids = videoTargetIds()
        guard !ids.isEmpty else { return }
        ids.forEach { VideoSettings.setVolume(v, id: $0) }
        videoVolume = v
        onApplySelection?()   // ponytail: 리마운트 반영(재생 리셋) — 라이브 반영은 BACKLOG(queue.volume) 항목
    }

    func setRate(_ r: Float) {
        let ids = videoTargetIds()
        guard !ids.isEmpty else { return }
        ids.forEach { VideoSettings.setRate(r, id: $0) }
        videoRate = r
        onApplySelection?()
    }

    func setLogin(_ on: Bool) {
        do {
            try LoginItemController.setEnabled(on)
        } catch {
            statusMessage = "로그인 항목 설정 실패: \(error.localizedDescription)"
        }
        loginEnabled = LoginItemController.isEnabled   // 실제 status 재조회(기존 관례)
    }

    func setStillSync(_ on: Bool) {
        stillSync = on
        onSetStillSync?(on)
    }

    func toggleSaver() {
        saverSelected = onToggleSaver?() ?? saverSelected
    }

    func chooseBaseAssets() {
        onChooseBaseAssets?()   // NSOpenPanel(runModal) — 반환 후 경로 재표시
        baseAssetsPath = BaseAssetsSettings.baseAssetsDirectory?.path ?? "(자동 탐지)"
    }

    func makeStillNow() {
        onSetStillWallpaper?()
    }
}
```

- [ ] **Step 3: SettingsView.swift 생성**

```swift
import SwiftUI
import AppKit
import WapleRender

/// 설정 창 — 트레이에 흩어져 있던 설정을 grouped Form 으로 통합(SP5′).
/// 시각은 전부 시스템: grouped Form·시맨틱 컬러·SF Symbols. 치수는 Metrics.settingsSize 만.
struct SettingsView: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        Form {
            playbackSection
            playlistSection
            videoSection
            systemSection
            assetsSection
        }
        .formStyle(.grouped)
        .frame(width: Metrics.settingsSize.width, height: Metrics.settingsSize.height)
        .onAppear { vm.refresh() }
    }

    private var playbackSection: some View {
        Section("배경 재생") {
            Picker("화면 맞춤", selection: Binding(get: { vm.fitMode }, set: { vm.setFit($0) })) {
                ForEach(FitMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("가려지면 일시정지",
                   selection: Binding(get: { vm.occlusionRaw }, set: { vm.setOcclusion($0) })) {
                ForEach(SettingsPresentation.occlusionOptions, id: \.raw) { Text($0.label).tag($0.raw) }
            }
        }
    }

    private var playlistSection: some View {
        Section {
            Toggle("자동 전환",
                   isOn: Binding(get: { vm.playlistEnabled }, set: { vm.setPlaylistEnabled($0) }))
            Picker("전환 간격",
                   selection: Binding(get: { vm.playlistInterval }, set: { vm.setPlaylistInterval($0) })) {
                ForEach(SettingsPresentation.playlistIntervalMinutes, id: \.self) { Text("\($0)분").tag($0) }
            }
            .disabled(!vm.playlistEnabled)
        } header: {
            Text("재생목록")
        } footer: {
            Text("항목 추가는 라이브러리 타일 우클릭 → 재생목록.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var videoSection: some View {
        Section {
            Picker("음량", selection: Binding(get: { vm.videoVolume ?? 0 }, set: { vm.setVolume($0) })) {
                ForEach(SettingsPresentation.volumeSteps, id: \.value) { Text($0.label).tag($0.value) }
            }
            .disabled(vm.videoVolume == nil)
            Picker("배속", selection: Binding(get: { vm.videoRate ?? 1 }, set: { vm.setRate($0) })) {
                ForEach(SettingsPresentation.rateSteps, id: \.value) { Text($0.label).tag($0.value) }
            }
            .disabled(vm.videoRate == nil)
        } header: {
            Text("동영상")
        } footer: {
            Text(vm.videoVolume == nil
                 ? "동영상 배경이 적용 중일 때 조절할 수 있습니다."
                 : "변경 시 재생이 처음부터 다시 시작됩니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var systemSection: some View {
        Section {
            Toggle("로그인 시 시작",
                   isOn: Binding(get: { vm.loginEnabled }, set: { vm.setLogin($0) }))
            Toggle("정적 배경 동기화",
                   isOn: Binding(get: { vm.stillSync }, set: { vm.setStillSync($0) }))
                .help("적용 성공 시 정지 이미지를 실제 바탕화면에도 반영합니다. 끄면 원본을 복원합니다.")
            LabeledContent("화면보호기") {
                HStack(spacing: Metrics.gap) {
                    Text(saver.label).foregroundStyle(.secondary)
                    Button(vm.saverSelected ? "끄기" : "켜기") { vm.toggleSaver() }
                        .disabled(!saver.canToggle)
                }
            }
            LabeledContent("정지 배경") {
                Button("지금 설정") { vm.makeStillNow() }
                    .help("현재 배경에서 정지 이미지를 만들어 모든 화면의 바탕화면으로 지정합니다(1회).")
            }
            if let message = vm.statusMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("시스템 연동")
        }
    }

    private var assetsSection: some View {
        Section {
            LabeledContent("기본 에셋 폴더") {
                HStack(spacing: Metrics.gap) {
                    Text(vm.baseAssetsPath)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("변경…") { vm.chooseBaseAssets() }
                }
            }
            LabeledContent("ffmpeg") {
                Text(vm.ffmpegStatus)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        } header: {
            Text("에셋·도구")
        } footer: {
            Text("일부 씬은 Wallpaper Engine 공유 에셋(assets) 폴더의 텍스처를 참조합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var saver: (label: String, canToggle: Bool) {
        SettingsPresentation.saverStatus(bundled: vm.saverBundled, selected: vm.saverSelected)
    }
}
```

- [ ] **Step 4: 빌드 확인**

Run: `swift build 2>&1 | tail -3` → Expected: `Build complete!`
(임포트/옵셔널이 실코드와 어긋나면 실코드에 맞춰 조정 — `FitMode`·`SceneRenderSettings`·`VideoSettings`·`BaseAssetsSettings`·`FFmpegConverter`의 소속 모듈은 AppDelegate.swift 임포트 세트(WapleCore/WapleLibrary/WapleRender)에서 확인.)

- [ ] **Step 5: Commit**

```bash
git add Sources/Waple/Surfaces/Settings/ Sources/Waple/DesignSystem/Metrics.swift
git commit -m "기능(ui): 설정 창 뷰·뷰모델 — grouped Form 5섹션(재생·재생목록·동영상·시스템 연동·에셋)"
```

---

### Task 3: AppDelegate 트레이 축소 + openSettings 창 + 배선

**Files:**
- Modify: `Sources/Waple/AppDelegate.swift`
- Modify: `Sources/Waple/LibraryViewModel.swift`
- Modify: `Sources/Waple/Shell/MainWindowView.swift`
- Modify: `Sources/Waple/main.swift`

**Interfaces:**
- Consumes: Task 2 `SettingsViewModel`/`SettingsView`/`Metrics.settingsSize`
- Produces: 트레이 6항목, `openSettings()`, `WAPLE_SMOKE_SETTINGS` 스모크 훅, `LibraryViewModel.onOpenSettings`

- [ ] **Step 0: 삭제 대상 외부 참조 사전 확인**

Run: `grep -rn "setFitMode\|updateVideoMenuStates\|setVideoVolume\|setVideoRate\|togglePlaylist\|setPlaylistInterval\|makeOcclusionMenu\|updateOcclusionMenuStates\|toggleLoginItem\|screenSaverMenuItem\|toggleScreenSaver\|desktopStillSyncMenuItem\|toggleDesktopStillSync" Sources/ Tests/ | grep -v AppDelegate.swift`
Expected: 출력 없음(전부 AppDelegate 내부 전용). 출력이 있으면 해당 참조를 먼저 파악하고 편차 기록.

- [ ] **Step 1: 트레이 메뉴 축소**

`applicationDidFinishLaunching`의 메뉴 구성부(67-138행: `let menu = NSMenu()`부터 `self.fitMenu = fitMenu`까지 — 139행의 `self.fitMenu` 대입 포함)를 아래로 교체:

```swift
        // 트레이 축소(SP5′): 설정은 전부 설정 창으로 — 창 없이 필요한 동작만 남긴다.
        let menu = NSMenu()
        menu.delegate = self   // 열 때마다 일시정지 항목 제목 최신화(menuNeedsUpdate)
        menu.addItem(NSMenuItem(title: "Waple 열기",
                                action: #selector(openLibrary), keyEquivalent: "l"))
        menu.addItem(recentMenuItem())  // 최근 배경 서브메뉴(작업 6 — 구현은 확장)
        let pause = NSMenuItem(title: "일시정지",
                               action: #selector(togglePauseFromMenu), keyEquivalent: "p")
        menu.addItem(pause)
        pauseMenuItem = pause
        menu.addItem(NSMenuItem(title: "설정…",
                                action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Waple",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusMenu = menu
```

- [ ] **Step 2: 프로퍼티 정리 + 신규 프로퍼티**

삭제: `private weak var videoMenu: NSMenu?`(:15), `private weak var fitMenu: NSMenu?`(:27), `private weak var playlistMenu: NSMenu?`(:28), `private weak var occlusionMenu: NSMenu?`(:35).
추가(같은 자리 근처):

```swift
    private var settingsWindow: NSWindow?
    private weak var pauseMenuItem: NSMenuItem?
    private weak var statusMenu: NSMenu?
```

`settingsVM`은 `libraryVM` 선언(:23-24) 아래에 lazy 로:

```swift
    private lazy var settingsVM: SettingsViewModel = {
        let vm = SettingsViewModel(playlist: playlistStore)
        vm.onApplySelection = { [weak self] in _ = self?.applyCurrentSelection() }
        vm.onSetOcclusion = { [weak self] raw in self?.setOcclusionMode(raw: raw) }
        vm.onSetStillSync = { [weak self] on in self?.setDesktopStillSync(on) }
        vm.onPlaylistChanged = { [weak self] in self?.schedulePlaylistTimer() }
        vm.onChooseBaseAssets = { [weak self] in self?.chooseBaseAssets() }
        vm.onSetStillWallpaper = { [weak self] in self?.setStillWallpaper() }
        vm.onToggleSaver = { [weak self] in self?.toggleScreenSaverCore() ?? false }
        vm.videoTargetIds = { [weak self] in
            guard let self else { return [] }
            return VideoSettingsTarget.projectIds(currentProjectId: self.currentProjectId,
                                                  activeVideoProjectIds: self.activeVideoProjectIds)
        }
        vm.occlusionState = { [weak self] in
            guard let self else { return (false, 0) }
            return (self.pauseWhenOccluded, self.occlusionCoverageThreshold)
        }
        vm.stillSyncEnabled = { [weak self] in self?.desktopStillSync ?? false }
        return vm
    }()
```

- [ ] **Step 3: 핸들러 정리 — 삭제·코어 분리**

**삭제**(메뉴 전용 배선):
- `setFitMode(_ sender: NSMenuItem)` :56-61
- `setVideoVolume(_:)`/`setVideoRate(_:)`/`updateVideoMenuStates()` :201-244, 그리고 `applyResolved` 내 호출 `updateVideoMenuStates()` :355 1줄
- `togglePlaylist()`/`setPlaylistInterval(_:)` :389-400
- `makeOcclusionMenu()`/`updateOcclusionMenuStates()` :427-453
- `toggleLoginItem(_:)` :575-585 (MARK 주석 포함 — LoginItemController 는 VM 이 직접 사용)
- 화면보호기 확장(:600-625)의 `screenSaverMenuItem()`·`@objc func toggleScreenSaver(_ sender:)`
- 정적 동기화 확장(:651-667)의 `desktopStillSyncMenuItem()`·`@objc func toggleDesktopStillSync(_ sender:)`

**교체/신규**(코어 분리 — 저장·타이머 로직은 원문 그대로 유지):

```swift
    /// 가림 정지 설정(설정 창 경유). raw: -1=끔, 0=즉시, 0.3/0.5/0.8=커버 비율.
    func setOcclusionMode(raw: Double) {
        let (enabled, threshold) = OcclusionMode.decode(raw)
        pauseWhenOccluded = enabled
        occlusionCoverageThreshold = threshold
        scheduleOcclusionTimer()
    }

    /// 트레이 일시정지 항목 — 하단 바와 같은 toggleGlobalPause 를 태운다(상태 공유).
    @objc private func togglePauseFromMenu() {
        _ = toggleGlobalPause()
    }
```

화면보호기 확장에는(기존 toggleScreenSaver 자리):

```swift
    /// 켜기 = saver 설치 + 시스템 선택 + 설정 패널 열기 / 끄기 = 선택 해제. 반환 = 토글 후 선택 상태.
    func toggleScreenSaverCore() -> Bool {
        if ScreenSaverController.isSelected {
            ScreenSaverController.disable()
            return false
        }
        do {
            let project = currentFolderURL.flatMap { projectForMount(folderURL: $0) }
            try ScreenSaverController.enable(currentProject: project)
            ScreenSaverController.openSettings()  // 사용자가 바로 확인할 수 있게 잠금 화면 패널 열기
            return true
        } catch {
            notify("화면보호기 설치 실패: \(error.localizedDescription)")
            return false
        }
    }
```

정적 동기화 확장에는(기존 toggleDesktopStillSync 자리):

```swift
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
```

`setStillWallpaper()`(:513)·`chooseBaseAssets()`(:187)·`openWebInteraction()`(:247)은 **그대로 유지**(각각 설정 창 버튼·설정 창 버튼·그리드 우클릭이 소비).

- [ ] **Step 4: openSettings 창 + 스모크 훅**

`openLibrary()`(:255-277) 아래에 추가:

```swift
    /// 설정 창(SP5′) — openLibrary 와 같은 수명 규약: darkAqua·isReleasedWhenClosed=false·강한 참조.
    @objc func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(vm: settingsVM))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Waple 설정"
            window.styleMask = [.titled, .closable]
            window.setContentSize(Metrics.settingsSize)
            window.appearance = NSAppearance(named: .darkAqua)   // WE 관례 — 항상 다크
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsVM.refresh()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
```

`applicationDidFinishLaunching`의 WAPLE_SMOKE 블록(:177-182) 아래에 추가:

```swift
        // 설정 창 캡처용(판정 게이트): WAPLE_SMOKE_SETTINGS=1 이면 설정 창 자동 오픈.
        if ProcessInfo.processInfo.environment["WAPLE_SMOKE_SETTINGS"] != nil {
            DispatchQueue.main.async { [weak self] in self?.openSettings() }
        }
```

`menuNeedsUpdate`(:788)의 선두를 확장(트레이 열 때 일시정지 제목 최신화):

```swift
    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu {
            pauseMenuItem?.title = manualGlobalPause ? "재개" : "일시정지"
            return
        }
        guard menu === recentMenu else { return }
```

- [ ] **Step 5: LibraryViewModel 콜백 + 메인창 설정 버튼 + main.swift**

`LibraryViewModel.swift`의 `on*` 콜백 선언부(:41-63 근처, `onOpenInteraction` 옆)에 추가:

```swift
    /// 툴바 설정 버튼 → AppDelegate.openSettings (SP5′).
    var onOpenSettings: (() -> Void)?
```

`AppDelegate.applicationDidFinishLaunching`의 콜백 주입부(:154 `onOpenInteraction` 다음 줄)에 추가:

```swift
        libraryVM.onOpenSettings = { [weak self] in self?.openSettings() }
```

`MainWindowView.swift`의 설정 버튼(현행 `Button {} … .disabled(true).help("설정 창은 곧 제공됩니다(SP5′)")`)을 교체:

```swift
            Button { viewModel.onOpenSettings?() } label: { Label("설정", systemImage: "gearshape") }
                .help("설정")
```

`main.swift`의 액티베이션 정책 줄을 교체:

```swift
let env = ProcessInfo.processInfo.environment
// Dock 아이콘 없는 메뉴바(액세서리) 앱. 스모크 캡처(WAPLE_SMOKE / WAPLE_SMOKE_SETTINGS)만 regular.
app.setActivationPolicy(env["WAPLE_SMOKE"] == nil && env["WAPLE_SMOKE_SETTINGS"] == nil ? .accessory : .regular)
```

- [ ] **Step 6: 빌드 + 3스위트 + 잔재 검증**

Run: `swift build 2>&1 | tail -3` → `Build complete!` (신규/수정 파일 경고 0)
Run: `swift test --filter WapleAppTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` → 0 failures (140 + 신규 6 = 146)
Run: `swift test --filter WapleLibraryTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` → 27, 0 failures
Run: `swift test --filter WapleCoreTests 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` → 384, 0 failures
Run: `grep -rn "fitMenu\|videoMenu\|playlistMenu\|occlusionMenu\|updateVideoMenuStates\|screenSaverMenuItem\|desktopStillSyncMenuItem" Sources/` → 출력 없음

- [ ] **Step 7: Commit**

```bash
git add Sources/Waple/AppDelegate.swift Sources/Waple/LibraryViewModel.swift Sources/Waple/Shell/MainWindowView.swift Sources/Waple/main.swift
git commit -m "기능(ui): 트레이 축소·설정 창 배선 — 6항목 메뉴(일시정지 신설)·openSettings 창·코어 setter 분리·WAPLE_SMOKE_SETTINGS"
```

---

### Task 4: 캡처·판정 (메인 에이전트 전용 — 서브에이전트는 실행하지 않는다)

- 빌드 + 3스위트 재검증(메인 독립 재실행).
- 캡처(/tmp 만):
  ```bash
  WAPLE_SMOKE_SETTINGS=1 .build/debug/Waple &   # 설정 창 단독 오픈 → scripts/window-id.swift Waple → screencapture -l<id> /tmp/waple-sp5-settings.png
  WAPLE_SMOKE=1 .build/debug/Waple &            # 메인창 툴바 설정 버튼 활성 상태 확인용(선택)
  ```
- 트레이 메뉴는 캡처 불가(osascript 없음) — 코드 리뷰 + 항목 목록 텍스트 보고로 갈음.
- 사용자 판정 통과 → 문서/BACKLOG 현행화 커밋(스펙 머릿말 SP5′ 완료·트리거 항목 정리·README 트레이/설정 서술 현행화).

## Self-Review 결과

- 스펙 커버리지: "메뉴바 산재 설정(fit·가림 정지·base assets·화면보호기·볼륨/배속·로그인 시작) 통합" = Task 2 Form 5섹션(+재생목록·정적 동기화·정지 배경·ffmpeg 상태) / "트레이 축소" = Task 3 6항목 / 판정 "설정 캡처" = Task 4. 갭 없음.
- 타입 일관성: `SettingsViewModel` 클로저 이름·시그니처가 Task 2 선언 ↔ Task 3 주입에서 일치함을 대조 완료. `SettingsPresentation` API 는 Task 1 정의 ↔ Task 2 소비 일치.
- 동작 보존: 저장 키·기본값 무변경(스토어 재사용), occlusion decode/타이머·still-sync 스케줄/복원·saver enable 로직은 원문 이동. 일시정지는 기존 `toggleGlobalPause()` 공유라 하단 바와 상태 일관.
- 알려진 트레이드오프(의도): 설정 창이 열려 있는 동안 다른 경로(적용/화면 변경)로 activeVideoProjectIds 가 바뀌어도 동영상 섹션 미러는 창 재오픈(refresh) 전까지 스테일일 수 있음 — 이산 스텝 재선택으로 자가 복구되는 표시 문제라 수용.
