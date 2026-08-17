# UI 전면 개편 청사진 (2026-08-17)

> 상태: **청사진 확정, 화면 구현 미착수.**
> 이미 커밋된 것: 디자인 토큰(`Sources/Waple/DesignSystem/`) · 현지화 오라클 구멍 3종 수리 ·
> UI 규약 오라클 3건(`Tests/WapleAppTests/UIConventionTests.swift`).
> 이 문서는 화면별 병렬 에이전트의 **유일한 공통 기준**이다. 여기 없는 규약은 없는 것이다.
>
> 이 문서의 사실은 전부 2026-08-17 코드·캡처 실측이다. 추정은 "추정" 이라고 적었다.

방향은 **네이티브 macOS 정통**이다. 2026-07-12~13 의 네이티브 재설계
([스펙](history/specs/2026-07-12-native-ui-redesign.md))를 뒤집는 게 아니라 완성도를 끌어올린다.
그 스펙의 결정 — WE 는 구조 참고일 뿐 / 시각은 전부 시스템 / 커스텀 hex 금지 / Now Playing 바가
유일한 시그니처 — 은 그대로 유효하다.

이번에 바뀌는 것은 둘이다.

1. **3탭 세그먼티드 피커를 사이드바 소스리스트로 대체**한다.
2. **창 단위 `darkAqua` 강제를 걷어낸다**(§8.1) — 스펙 §3 을 뒤집는 유일한 항목이고, 근거는
   "시스템이 공짜로 주는 것을 받아먹는다" 는 이번 방향 자체다. 지금은 코드 두 줄이 그걸 막아
   **라이트 모드가 아예 존재하지 않는다**(라이트 캡처가 다크와 md5 동일).

그 김에 접근성과 영어 UI 를 개편과 **동시에** 처리한다(나중에 따로 하면 전 화면을 두 번 만진다).
둘 다 사실상 0 에서 시작한다 — 접근성 API 사용 1건, 한국어 문자열 커버율 49%.

"정통" 이 뜻하는 바는 **시스템이 공짜로 주는 것을 최대한 받아먹는다**는 것이다 —
`NavigationSplitView` · 시맨틱 컬러 · `.regularMaterial` · SF Symbols · `.inspector` ·
`Form(.grouped)` · `ContentUnavailableView`. 커스텀으로 흉내내지 않는다. 다크모드·접근성·
Dynamic Type·OS 업데이트 대응이 거의 공짜로 따라오는 게 이 방향을 고른 이유다.

---

## 0. 목표 배치

```
┌─────────────────────────────────────────────┐
│ ◉ ○ ○   Waple                    ⌕  ⚙  ▤   │  통합 툴바(unified)
├──────────┬──────────────────────────────────┤
│ 라이브러리 │  ┌────┐ ┌────┐ ┌────┐ ┌────┐  │
│  전체    │  │    │ │    │ │    │ │    │  │  콘텐츠(우물)
│  씬      │  └────┘ └────┘ └────┘ └────┘  │
│  동영상   │   Aurora  Rain   City   Space  │
│  웹      │                                 │
│ 창작마당  │  ┌────┐ ┌────┐ ┌────┐ ┌────┐  │
│  둘러보기 │  │    │ │    │ │    │ │    │  │
│  검색    │  └────┘ └────┘ └────┘ └────┘  │
├──────────┴──────────────────────────────────┤
│ ▶ Aurora Borealis      ━━━━━●━━  🔊 ⏭      │  Now Playing 바
└─────────────────────────────────────────────┘
                                    + 우측 표준 인스펙터(.inspector, 접이식)
```

---

## 1. 네비게이션 구조

### 1.1 사이드바 항목 (확정)

`NavigationSplitView(sidebar:content:detail:)` 가 아니라 **2열 +
`.inspector`** 다 — 3열 `NavigationSplitView` 의 세 번째 열은 "다음 단계로 내비게이트한 상세"
이지 "현재 선택의 속성 패널" 이 아니다. macOS 14 의 `.inspector(isPresented:)` 가 후자를 위한
표준이고, 툴바 토글·폭 조절·기억을 시스템이 처리한다.

| 섹션 | 항목 | SF Symbol | 선택 시 콘텐츠 | 상태 매핑 |
| --- | --- | --- | --- | --- |
| **라이브러리** | 전체 | `square.grid.2x2` | 라이브러리 그리드 | `criteria.types = []` |
| | 씬 | `sparkles` | 〃 | `criteria.types = [.scene]` |
| | 동영상 | `play.rectangle` | 〃 | `criteria.types = [.video]` |
| | 웹 | `globe` | 〃 | `criteria.types = [.web]` |
| | 즐겨찾기 | `heart` | 〃 | `criteria.favoritesOnly = true` |
| **폴더** (동적) | 사용자 폴더 n개 | `folder` | 〃 | `activeFolder = <name>` |
| **창작마당** | 둘러보기 | `sparkle.magnifyingglass` | `DiscoverView`(큐레이션 레일) | — |
| | 검색 | `magnifyingglass` | `WorkshopTabView`(텍스트 검색 그리드) | — |

- 섹션 헤더는 `Section("라이브러리")` — `List(selection:).listStyle(.sidebar)` 가 소스리스트
  스타일·접힘·선택 하이라이트를 전부 준다. 커스텀 하이라이트를 그리지 마라.
- **폴더 섹션은 항목이 0개면 통째로 숨긴다**(빈 헤더는 소음이다).
- 사이드바 폭은 `Metrics.navSidebarMin/Ideal/Max`. 고정폭 금지 — 영어 UI 에서 항목 라벨이
  길어지고(Subscriptions·Workshop) Dynamic Type 큰 글씨에서 더 길어진다.

### 1.2 현행 → 신규 1:1 매핑

| 현행 | 신규 | 비고 |
| --- | --- | --- |
| `MainTab.installed` (세그먼트 "설치됨") | 라이브러리 > 전체 | 기본 선택 |
| `MainTab.discover` (세그먼트 "검색") | 창작마당 > 둘러보기 | 라벨 변경 — "검색"은 텍스트 검색 쪽에 준다 |
| `MainTab.workshop` (세그먼트 "창작마당") | 창작마당 > 검색 | |
| 툴바 필터 토글 → `FilterSidebarView`(좌측 List) | **없어진다** | 아래 참조 |
| 툴바 세그먼티드 `Picker("보기")` | **없어진다** | 사이드바가 대체 |
| 그리드 안의 폴더 타일 + `backTile("뒤로 — %@")` | 사이드바 폴더 섹션 | 그리드에서 제거 |
| 툴바 "정보 패널" 버튼(`sidebar.trailing`) | `.inspector` 기본 토글 | 시스템이 제공 |

**없어지는 것**
- `enum MainTab` 전체.
- `FilterSidebarView` — 좌측이 네비게이션 사이드바가 되면서 자리가 없어진다. 그 내용은 둘로 갈린다:
  - 유형·즐겨찾기 → **사이드바 항목으로 승격**(위 표).
  - 태그·나이 등급 → 툴바 **필터 팝오버**(`line.3.horizontal.decrease.circle`, 활성 시 `.fill`).
    희소하게 쓰이고 값이 동적이라 사이드바에 상주시키면 사이드바가 길어진다.
- 그리드의 `folderTile` / `backTile`.
- `Metrics.sidebarWidth`(220) 사용처 — 상수는 남기되 신규 코드는 `navSidebarMin/Ideal/Max`.

**새로 생기는 것**
- `Shell/SidebarView.swift` — 소스리스트.
- `Shell/LibrarySection.swift` — 순수 네비 모델(선택 ↔ 필터 상태 변환). 단위 테스트 대상.
- `Shell/SmokeLaunch.swift` — 스모크 환경변수 해석(§6).
- 툴바 필터 팝오버.
  **Phase 1 현재 상태(Unit A)**: 툴바 버튼과 팝오버 껍데기는 A 가 만들었고, 그 안의 내용은
  기존 `FilterSidebarView` 를 **그대로 호출**한다(그 파일은 A 가 편집하지 않았다).
  전용 `FilterPopover.swift` 로 갈아끼우고 `FilterSidebarView` 를 지우는 것은 Unit B 몫이다 —
  셸 교체와 필터 UI 재작성을 같은 페이즈에 섞으면 회귀 원인을 못 가린다.

### 1.3 "구독" 은 왜 없나

사용자 스케치의 `창작마당 > 구독` 에는 **대응하는 표면이 없다.** Waple 은 Steam 구독을
추적하지 않는다 — steamcmd 로 내려받는 즉시 라이브러리 엔트리가 되고, 스펙의 기능 매핑 표도
"구독 취소 = 라이브러리에서 제거" 로 매핑해 두었다. 그래서 그 자리에 **둘러보기**(기존 디스커버
레일)를 놓았다. 구독 목록이 정말 필요하면 Steam 인증(웹 API 키만으로는 불가)이 선행돼야 하는
별도 SP 다. **이 항목은 사용자 확인이 필요하다** — §8 참조.

### 1.4 툴바

`NSToolbar` 브리징은 유지(`hosting.sceneBridgingOptions = [.toolbars]`, `window.toolbarStyle = .unified`).

> **정정(2026-08-17, Unit A 실측).** 아래 표의 "시스템 자동" 두 줄은 **틀렸다.**
> `NSHostingController` + `sceneBridgingOptions = [.toolbars]` 조합에서는 사이드바 토글도
> 인스펙터 토글도 **툴바에 자동으로 붙지 않는다.** 확인 방법: 직접 만든 토글 둘을 넣고 찍었더니
> 각각 하나씩만 나왔다(시스템이 붙였다면 둘씩 보였을 것이다). 그래서 A 가 두 버튼을
> `.navigation`(사이드바) · `.primaryAction`(인스펙터)에 직접 만들었다. 자세한 실측은 §7.2.

| 위치 | 항목 | 조건 |
| --- | --- | --- |
| `.navigation` | 사이드바 토글 | ~~시스템 자동~~ → **직접 만든다**(`NavigationSplitViewVisibility` 바인딩 토글) |
| `.principal`/좌측 | 없음 | 세그먼트 제거 |
| `.primaryAction` | 검색 필드 | 라이브러리 = `viewModel.searchText`, 창작마당>검색 = `workshopVM.searchText`, 둘러보기 = 없음 |
| | 필터 팝오버 | 라이브러리 선택 시에만 |
| | 정렬 메뉴 | 라이브러리·창작마당>검색 |
| | 디스플레이(시트) · 설정(창) | 상시 |
| | 모바일(비활성+툴팁) | 상시 — 기능 매핑 표 유지 |
| | 인스펙터 토글 | ~~`.inspector` 기본 제공~~ → **직접 만든다**. 라이브러리 선택 시에만 노출 |

검색 필드는 `.searchable(text:placement:.toolbar)` 를 우선 검토하라 — 시스템 서치필드는 ⌘F·
Esc 취소·접근성 라벨을 공짜로 준다. 현행 `TextField(...).frame(width: 190)` 은 그 전부를 잃는다.

캡처에서 확인된 것 하나: 현행 정렬 `Picker(.menu)` 는 `labelsHidden` 없이도 **라벨 없는 작은
쉐브론 스테퍼처럼** 렌더돼, 무엇을 하는 컨트롤인지 화면에서 읽히지 않는다. 툴바에서는
`Menu` + `Label("정렬", systemImage: "arrow.up.arrow.down")` 형태(아이콘 + 접근성 이름)가
낫다 — 아이콘 전용 툴바 버튼 규약(§4.5)과도 맞는다.

---

## 2. 화면별 분해 — 단위와 소유 파일

**규칙: 한 파일은 한 시점에 한 단위만 소유한다.** 아래 표의 "소유" 는 *그 페이즈 동안* 이다.
페이즈가 다르면 같은 파일을 다른 단위가 소유할 수 있고, 그건 충돌이 아니다.

**`AppDelegate.swift`(1,115줄)는 생각보다 덜 얽혀 있다**(2026-08-17 실측). 순수 결정 로직 14개가
이미 `AppLogic.swift` 로 추출돼 있고 뷰모델 연결이 **클로저 주입 21개로 단방향**이라,
UI 를 교체해도 본문은 거의 안 건드려도 된다. 여기 하드코딩된 UI 는 셋뿐이다 —
**트레이 메뉴**(`:138-158`, `:1075-1108`) · **창 2개의 생성과 외관**(`:311-355`, `darkAqua`
강제 포함) · **스모크 훅**(`:238-243`, `:246-248`, `:271-274`). 그래서 이 파일은 통째 소유가
아니라 **영역별로 배정**한다: 창 생성·스모크 = Unit A(Phase 1), 트레이 메뉴·상태 아이콘 =
Unit E(Phase 3). 두 페이즈가 겹치지 않으므로 동시 편집이 없다.

### 페이즈

```
Phase 0  토큰 + 규약 오라클        ← 완료. 이후 DesignSystem/ 는 동결.
Phase 1  A(셸·네비)  ∥  S(공유 컴포넌트)     ← 두 단위는 파일이 겹치지 않는다
         ─ 게이트: 스모크 5종 캡처 + 사용자 판정 + NavigationSplitView 실현성 증명
Phase 2  B(라이브러리)  ∥  C(창작마당)  ∥  D(설정·온보딩·디스플레이)
         ─ 게이트: 단위별 스모크 캡처 + 사용자 판정
Phase 3  E(메뉴바·마감)            ← 단독
         ─ 게이트: 스모크 5종 재캡처 + 전량 테스트 + 현지화 오라클
```

### Unit A — 셸·네비게이션 (Phase 1, 단독)

목표: 사이드바 + 인스펙터 + 통합 툴바 + Now Playing 바. **콘텐츠 영역은 기존 B/C/D 뷰를
그대로 호출한다** — 재스타일은 Phase 2 다. A 의 산출물은 "껍데기가 바뀌어도 전부 동작한다".

| 파일 | 처분 |
| --- | --- |
| `Sources/Waple/Shell/MainWindowView.swift` | 수정(전면) |
| `Sources/Waple/Shell/SidebarView.swift` | 신규 |
| `Sources/Waple/Shell/LibrarySection.swift` | 신규(순수) |
| `Sources/Waple/Shell/SmokeLaunch.swift` | 신규(순수) |
| `Sources/Waple/Shell/NowPlayingBar.swift` | 수정(토큰 적용·접근성) |
| `Sources/Waple/Shell/StatusBanner.swift` | 수정(`Motion`·`Surface` 적용) |
| `Sources/Waple/main.swift` | 수정(스모크 활성화 정책) |
| `Sources/Waple/AppDelegate.swift` | **수정 — 스모크 블록(:237–276)과 창 생성(`openLibrary`)만.** 트레이 메뉴·상태 아이콘은 손대지 않는다(E 소유 영역) |
| `Tests/WapleAppTests/ShellNavigationTests.swift` | 신규 |
| `Tests/WapleAppTests/SmokeLaunchTests.swift` | 신규 |

### Unit S — 공유 컴포넌트 (Phase 1, A 와 병렬)

A 와 파일이 하나도 겹치지 않으므로 동시에 돌린다. **A 는 S 의 산출물에 의존하지 않는다**
(A 는 시스템 프리미티브만 쓴다). 채택은 B/C/D 부터.

| 파일 | 처분 |
| --- | --- |
| `Sources/Waple/DesignSystem/Components/PreviewThumbnail.swift` | 신규 — `PreviewImageCache`(WallpaperGridView 에서 **순수 이동**) + 로컬 파일 비동기 썸네일 뷰 |
| `Sources/Waple/DesignSystem/Components/TileChrome.swift` | 신규 — `enum TileRing`, `View.tileRing(_:)`, `View.tileThumbnailClip(corner:)` |
| `Sources/Waple/DesignSystem/Components/Badges.swift` | 신규 — `TypeBadge`, `MetricBadge` |
| `Sources/Waple/DesignSystem/Components/SectionHeader.swift` | 신규 — 콘텐츠 영역 섹션 제목 |
| `Sources/Waple/WallpaperGridView.swift` | **이 페이즈 한정** 수정 — `PreviewImageCache`·`StillPreviewView` 를 빼내고 새 컴포넌트 호출로 교체. 그 외 손대지 마라 |
| `Sources/Waple/Surfaces/Displays/DisplaysView.swift` | **이 페이즈 한정** 수정 — `DisplaysThumbView` 를 새 컴포넌트로 교체 |
| `Tests/WapleAppTests/ComponentTests.swift` | 신규(순수 로직만 — `TileRing` 결정 등) |

⚠️ `PreviewImageCache` 는 `AppUIFixRegressionTests` 가 이름으로 참조한다(:240–264).
**파일은 옮겨도 타입 이름·API 는 그대로 둬라.** 회귀 테스트 파일은 전 단위 동결이다
(이 절 아래 "동결 파일" 목록).

### Unit B — 라이브러리 (Phase 2)

| 파일 | 처분 |
| --- | --- |
| `Sources/Waple/WallpaperGridView.swift` | 수정(전면) — 폴더 타일·뒤로 타일 제거, 타일 접근성, 토큰 |
| `Sources/Waple/SelectionPanelView.swift` | 수정(전면) — 인스펙터 콘텐츠로. 파일명은 유지 |
| `Sources/Waple/PropertyEditorView.swift` | 수정 — `Form(.grouped)` 로, 토큰 |
| `Sources/Waple/Surfaces/Installed/FilterSidebarView.swift` | **삭제** → 툴바 필터 팝오버(`Surfaces/Installed/FilterPopover.swift` 신규) |
| `Sources/Waple/LibraryViewModel.swift` | 수정(필요 시) |
| `Sources/Waple/LibraryFiltering.swift` | 수정(필요 시) |
| `Sources/Waple/AnimatedPreviewView.swift` | 수정(필요 시) |
| 테스트 | `LibraryFilteringTests` · `LibraryViewModelTests` · `LibraryApplyBranchTests` · `LibraryRemovalTests` · `PropertyLabelTests` · `PreviewMediaTests` |

### Unit C — 창작마당·둘러보기 (Phase 2)

| 파일 | 처분 |
| --- | --- |
| `Sources/Waple/Surfaces/Workshop/WorkshopTabView.swift` | 수정 |
| `Sources/Waple/Surfaces/Workshop/DiscoverView.swift` | 수정 |
| `Sources/Waple/Surfaces/Workshop/RemoteTile.swift` | 수정 |
| `Sources/Waple/Surfaces/Workshop/APIKeyGateView.swift` | 수정 |
| `Sources/Waple/Surfaces/Workshop/WorkshopViewModel.swift` | 수정(필요 시) |
| `Sources/Waple/Surfaces/Workshop/DiscoverViewModel.swift` | 수정(필요 시) |
| `Sources/Waple/WorkshopAPI.swift` · `SteamCmdDownloader.swift` | 수정(필요 시) |
| 테스트 | `DiscoverViewModelTests` · `WorkshopAPITests` · `WorkshopDownloadTests` · `WorkshopPagingTests` · `SteamCmdDownloaderTests` · `SteamCmdTerminateTests` |

### Unit D — 설정·온보딩·디스플레이 (Phase 2)

| 파일 | 처분 |
| --- | --- |
| `Sources/Waple/Surfaces/Settings/SettingsView.swift` | 수정 |
| `Sources/Waple/Surfaces/Settings/SettingsViewModel.swift` | 수정(필요 시) |
| `Sources/Waple/Shell/OnboardingView.swift` | 수정 — `Shell/` 이지만 A 소유가 아니다(파일 단위 소유) |
| `Sources/Waple/Surfaces/Displays/DisplaysView.swift` | 수정 |
| 테스트 | `SettingsViewModelTests` · `SettingsPresentationTests` · `OnboardingTests` · `DisplayDiagramLayoutTests` |

### Unit E — 메뉴바·마감 (Phase 3, 단독)

| 파일 | 처분 |
| --- | --- |
| `Sources/Waple/AppDelegate.swift` | 수정 — 트레이 메뉴 구조·상태 아이콘·툴팁 |
| `Sources/Waple/AppLogic.swift` | 수정 허용(Phase 3 에서만) |
| `Sources/Waple/main.swift` | 수정 — 편집 메뉴 6개 `NSLocalizedString` 래핑(§9.3) |
| `Resources/en.lproj/Localizable.strings` | **정규화** — 단위별 블록을 다시 정렬해 하나로 합치고 마커 제거, 죽은 키 제거 |
| `Tests/WapleAppTests/LocalizationCoverageTests.swift` | 패턴에 `withTitle` 추가 — **코드 래핑과 같은 커밋에서만**(§5.3) |
| 전 화면 | 접근성·현지화 최종 스윕(코드 수정 최소, 누락 보완만) |
| 테스트 | 회귀 스위트 전체 + 스모크 5종 재캡처 + 라이트/다크 + 영어 로케일 |

### 동결 파일 (전 페이즈)

아무 단위도 만지지 않는다. 만져야 하면 멈추고 통합자에게 올린다.

- `Sources/Waple/DesignSystem/*.swift` — **Phase 0 이후 동결.** 토큰이 개편 중에 늘어나면
  모든 단위가 이 파일을 만지게 되고 그 순간 병렬이 깨진다. 부족하면 통합자를 거쳐라.
- `Sources/Waple/DesignSystem/Components/*.swift` — Phase 1(S) 이후 동결.
- `Sources/Waple/AppLogic.swift` — Phase 2 동안 동결. 새 순수 로직은 **자기 디렉터리에 새 파일**로.
- 비 UI: `BaseAssetsWarningGate` · `DesktopVisibilityMonitor` · `LoginItemController` ·
  `ScreenSaverController` · `StillWallpaper` · `VideoImport`.
- `Tests/WapleAppTests/UIConventionTests.swift` — **동결 아님, 단 편집 범위가 정해져 있다.**
  자기 파일을 허용 목록에서 **지우는 것만** 허용된다. 목록에 추가하거나 판정 로직을 무르게
  만드는 것은 금지 — 그건 오라클을 끄는 것이다.
- 회귀 테스트: `AppCoreFixRegressionTests` · `AppUIFixRegressionTests` · `AppUIV06RegressionTests` ·
  `AppUIV07RegressionTests` · `PauseGateTests` · `StatusBannerModelTests` · `DesktopIntegrationTests` ·
  `ScreenSaverLogicTests` · `NowPlayingSubtitleTests`.
  **빨개지면 그 변경이 틀린 것이다**(AGENTS: "테스트를 고쳐야 하는 리팩토링은 틀린 리팩토링이다").

### 겹칠 수밖에 없는 파일 — `Resources/en.lproj/Localizable.strings`

모든 단위가 문자열을 추가한다. 프로토콜:

1. **마커 블록은 이미 만들어 두었다**(파일 하단, 단위 6개분). 자기 구역에만 추가한다.
   **새로 만들지 마라** — 셋이 각자 파일 끝에 구역을 만들면 전부 같은 줄에 붙어
   순차 머지가 전부 충돌한다. 미리 비워 둔 이유가 이것이다.
2. 기존 줄은 **재정렬하지 않는다.** 정렬 욕구는 참아라 — 전체 재정렬 diff 는 무조건 충돌한다.
3. **삭제**는 공용 영역을 건드린다(고아 번역 테스트 때문에 UI 문구를 지우면 여기서도 지워야 한다).
   삭제는 한 줄 단위라 서로 다른 줄이면 git 이 자동 병합한다. 인접 줄 삭제가 겹치면 충돌 —
   그때는 양쪽 삭제를 모두 살려서 해결한다.
4. 단위 머지는 **순차**로 한다(동시 머지 금지). 머지할 때마다
   `swift test --filter LocalizationCoverageTests` 를 돌린다.
5. Phase 3 에서 E 가 마커를 걷고 알파벳순 한 블록 + 포맷 지정자 블록으로 정규화한다.

---

## 3. 공유 컴포넌트

### 3.1 이미 있는 것 — 새로 만들지 마라

| 필요 | 쓸 것 |
| --- | --- |
| 빈 상태 | `ContentUnavailableView` (커스텀 금지) |
| 라벨+값 행 | `LabeledContent` |
| 설정 폼 | `Form { Section { } }.formStyle(.grouped)` |
| 구분선 | `Divider()` |
| 진행 표시 | `ProgressView` |
| 사이드바 | `List(selection:).listStyle(.sidebar)` + `Section` |
| 인스펙터 | `.inspector(isPresented:)` |
| 검색 | `.searchable(text:)` |

### 3.2 Unit S 가 만드는 것

세 원칙:
- **제네릭 슬롯을 가진 컨테이너 컴포넌트를 만들지 않는다.** `TileFrame<Thumb, Badge, Caption>`
  같은 것은 이 저장소에서 4번 일어난 타입체커 폭발의 정확한 재료다(AGENTS "함정").
  대신 **모디파이어 + 구체 뷰**로 쪼갠다.
- 모든 함수·프로퍼티에 반환 타입을 명시한다.
- 컴포넌트 안에 한국어 리터럴을 두지 않는다 — 문자열은 호출부가 `Text` 로 넘긴다(§5).

| 컴포넌트 | 시그니처(초안) | 대체 대상 |
| --- | --- | --- |
| `PreviewThumbnail` | `struct PreviewThumbnail: View { let url: URL?; var placeholderFont: Font }` | `StillPreviewView`(그리드) · `DisplaysThumbView`(디스플레이) — 같은 F500 패턴의 복제 2벌 |
| `TileRing` + `.tileRing(_:)` | `enum TileRing { case none, focus, selected, emphasis, dropTarget }` | 그리드 타일·원격 타일·모니터 박스·레일 타일의 `overlay(stroke)` 4벌 |
| `.tileThumbnailClip(corner:)` | `func tileThumbnailClip(corner: CGFloat) -> some View` | `frame`+`clipped`+`clipShape` 3연타 4벌 |
| `TypeBadge` | `struct TypeBadge: View { let symbol: String; let label: Text }` | `WallpaperGridView.typeBadge` |
| `MetricBadge` | `struct MetricBadge: View { let symbol: String; let value: Text }` | `RemoteTileView.ratingBadge` · 평점/구독 수 |
| `SectionHeader` | `struct SectionHeader: View { let title: Text }` | `DiscoverView` 레일 제목 · `DisplaysView` 헤더 |

이미 `DesignSystem/` 에 있고 **바로 쓸 수 있는 것**(Phase 0 완료):
`View.tileLift(_:)`(호버 리프트) · `View.tileAccessibility(label:value:isSelected:onActivate:)` ·
`SystemPreference`(reduceMotion·reduceTransparency·differentiateWithoutColor·increaseContrast).
접근성 설정은 **화면에서 직접 읽지 마라** — 토큰(`Motion`·`ColorRole`)이 이미 소비하고 있다.

### 3.3 의존 순서

```
Phase 0 토큰 ──┬─→ Phase 1 S(컴포넌트) ──┬─→ Phase 2 B ─┐
               │                          ├─→ Phase 2 C ─┼─→ Phase 3 E
               └─→ Phase 1 A(셸)  ────────┴─→ Phase 2 D ─┘
```

- A 와 S 사이에 의존 없음(파일도 안 겹침) → 병렬.
- B/C/D 는 A 와 S **둘 다** 필요 → 둘이 다 끝나야 시작.
- E 는 전부 끝나야 시작.

---

## 4. 접근성 규약

전제(2026-08-17 실측): 접근성은 **0 에서 시작한다.**

- `Sources/Waple` 전체에서 `.accessibilityLabel` / `Value` / `Hint` / `Element` / `AddTraits`
  **전부 0건**. `.focusable` **0건**. 유일한 접근성 API 는 상태바 아이콘의
  `accessibilityDescription` 1건이다.
- `reduceMotion` · `accessibilityReduceTransparency` · `differentiateWithoutColor`
  **전 소스 0건** — 애니메이션 진입점 6개가 무조건 실행되고, 시스템 재질 5곳에 폴백이 없다.
- `keyboardShortcut` 은 3개뿐이고 그중 ⌘O 는 **빈 상태 버튼에만** 있어 라이브러리가 차면
  사라진다.
- 타일은 `Button` 이 아니라 `VStack` + `.onTapGesture`(단일=포커스, 더블=적용).
  **키보드만으로 배경을 고르고 적용할 방법이 지금은 없다.**

"기존 것을 개선" 이 아니라 "처음 붙인다". 그래서 §4.1 의 표준 형태를 그대로 복사해 쓰는 것이
가장 확실하고, `UIConventionTests`(§7.5)가 빠뜨림을 기계로 잡는다.

### 4.1 커스텀 타일 — 표준 형태 (복사해서 써라)

`VStack { 썸네일; 제목 }` + `onTapGesture` 는 화면에서만 버튼이다. 보조기술에는 이미지 하나와
텍스트 하나가 따로 읽히고, 누를 수 있다는 것도 적용 중이라는 것도 전달되지 않는다.

```swift
tileBody
    .tileThumbnailClip(corner: Surface.tileCorner)
    .tileRing(applied ? .selected : (focused ? .focus : .none))
    .tileLift(hovered)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { apply() }
    .onTapGesture { focus() }
    .tileAccessibility(
        label: Text(entry.title),                 // 런타임 데이터 — 번역 대상 아님
        value: statusText,                        // Text? — 아래 4.2
        isSelected: applied,                      // 시각 링과 반드시 같은 조건
        onActivate: { apply() }                   // 키보드 Return
    )
    // 우클릭 메뉴에 있는 항목마다 1:1 로 — 아래 4.3
    .accessibilityAction(named: Text("선택(속성 보기)")) { select() }
    .accessibilityAction(named: Text("적용")) { apply() }
    .accessibilityAction(named: Text("즐겨찾기")) { toggleFavorite() }
    .accessibilityAction(named: Text("재생목록에 추가")) { togglePlaylist() }
    .accessibilityAction(named: Text("Finder에서 보기")) { reveal() }
    .accessibilityAction(named: Text("라이브러리에서 제거")) { confirmRemove() }
    .contextMenu { … }
```

`tileAccessibility` 가 붙이는 것: `accessibilityElement(children: .combine)` ·
`accessibilityLabel` · `accessibilityValue` · `.isButton`(+ `.isSelected`) ·
`focusable` · `onKeyPress(.return)`.

### 4.2 `accessibilityValue` 에 무엇을 넣나

**label 은 "무엇인가", value 는 "지금 어떤 상태인가".** 상태를 label 에 이어 붙이지 마라 —
상태가 바뀔 때 VoiceOver 가 항목 전체를 다시 읽는다.

| 타일 | value |
| --- | --- |
| 라이브러리 · 적용 중 | `Text("적용 중")` |
| 라이브러리 · 미지원 | `Text("지원 예정")` |
| 라이브러리 · 그 외 | `nil` |
| 원격 · 다운로드 중 | `Text(String(format: NSLocalizedString("다운로드 중 %lld%%", …), pct))` |
| 원격 · 완료 | `Text("적용")` 가 아니라 상태어를 쓸 것 |
| 모니터 박스 | 할당된 배경 제목, 없으면 `Text("전역 배경")` |

### 4.3 우클릭 메뉴 전용 기능은 도달 불가다 — 이게 가장 큰 구멍

현재 라이브러리 타일의 `contextMenu` 에는 **11개 동작**이 들어 있다(선택·적용·조작 창·재생목록·
폴더로 이동·모니터에 적용·할당 해제·즐겨찾기·Finder·제거·폴더 삭제). 이 중 인스펙터에도 있는
것은 절반뿐이고, 나머지는 **마우스 우클릭 외에 도달할 방법이 없다.** VoiceOver 사용자와
키보드 전용 사용자에게 그 기능들은 존재하지 않는 것과 같다.

실측된 **완전 도달 불가 5개**(다른 어떤 경로로도 없다):

| 기능 | 위치 | 개편 후 대안 |
| --- | --- | --- |
| `선택(속성 보기)` | 그리드 타일 | `accessibilityAction` + 인스펙터 자동 표시 |
| `적용 + 조작 창 열기` | 그리드 타일(웹) | `accessibilityAction`. 인스펙터에도 이미 "조작 창 열기" 가 있으니 인스펙터 경로 안내로도 가능 |
| `폴더로 이동` | 그리드 타일(서브메뉴) | 평탄화 불가 → 인스펙터에 폴더 선택 컨트롤을 두고 `accessibilityAction` 은 인스펙터를 여는 것으로 |
| `Finder에서 보기` | 그리드 타일 | `accessibilityAction`(단순 액션이라 그대로 가능) |
| `폴더 삭제(항목은 유지)` | 폴더 타일 | 폴더가 사이드바로 가면 사이드바 행의 `contextMenu` + `accessibilityAction` |

규칙 — **`contextMenu` 항목과 `accessibilityAction` 항목은 1:1 이어야 한다.**

- 단위 완료 조건에 넣어라: "이 화면의 모든 `contextMenu` 블록에 대해, 같은 뷰에 같은 수의
  `.accessibilityAction(named:)` 가 있다."
- 서브메뉴(`Menu("폴더로 이동")`)는 평탄화한다 — `accessibilityAction` 은 중첩되지 않는다.
  대상이 동적이면(모니터 목록) 대표 액션 하나(예: "모니터에 적용")로 인스펙터를 열어 거기서
  고르게 하라. 인스펙터가 접근 가능한 대안 경로다.
- 파괴적 동작은 `accessibilityAction` 에서도 반드시 확인 대화상자를 거친다.

### 4.4 키보드

- **Return = 주 동작.** 단, `.keyboardShortcut(.defaultAction)` 을 **창 전체에 걸지 마라** —
  F503 에서 정확히 그 이유로 제거했다(검색 필드에 포커스가 있어도 Enter 가 배경을 적용해
  전체 리마운트가 났다). `tileAccessibility(onActivate:)` 의 `onKeyPress(.return)` 는 **그 타일에
  포커스가 있을 때만** 발화하므로 안전하다.
- 처리하지 않는 키는 `.ignored` 를 반환해 상위로 흘려보낸다.
- 사이드바·그리드·인스펙터 사이 이동은 Tab. 커스텀 포커스 관리 금지.
- Esc = 시트/팝오버 닫기(`.keyboardShortcut(.cancelAction)`, 이미 `DisplaysView` 가 그렇게 한다).

### 4.5 색·모션·글자 크기

- **색만으로 상태를 전달하지 마라.** 적용 중 = 액센트 링 **+** 재생 글리프(현행 유지).
  미지원 = 감채도 **+** "지원 예정" 배지(현행 유지). 새 상태를 추가하면 같은 규칙을 지켜라.
- 호버를 색으로 표현하지 마라 — 포인터가 없는 사용자에게 전달되지 않는다. `tileLift` 를 쓴다.
- 모션은 `Motion` 토큰만 쓴다. 화면에서 `.spring(...)`·`.easeInOut(...)` 을 직접 쓰지 마라 —
  그 순간 `reduceMotion` 이 빠진다.
- **고정 높이는 Dynamic Type 에서 잘린다.** `frame(height:)` 대신 `frame(minHeight:)` +
  `.fixedSize(horizontal: false, vertical: true)`. 현행 위험 지점: `Metrics.nowPlayingHeight`(56),
  `DisplaysView.statusRow`(22), `assignmentRail`(92), `Metrics.settingsSize`·`onboardingSize`.
  시트는 `ScrollView` 로 감싼다(F090 선례 — 온보딩이 이미 그렇게 한다).
- 아이콘 전용 버튼은 `Label("문구", systemImage:)` + `.help("문구")` 둘 다 — `Label` 이 접근성
  이름이 되고 `.help` 가 툴팁이 된다. 현행 툴바가 이미 이 형태다. 유지하라.
- 비활성은 `.disabled(true)` 로만 만든다. 색으로 흉내내면 실제로 눌리는 가짜 비활성이 된다.
- **투명도 줄이기**: 시스템 `Material` 은 대체로 스스로 반응하지만, 재질 **위에** 직접 그린
  반투명(디스플레이 모니터 박스의 그라디언트 스크림 등)은 반응하지 않는다.
  `ColorRole.mediaScrimOpacity` 가 그 분기를 대신 처리한다 — 직접 `.black.opacity(0.72)` 를
  쓰지 마라.

### 4.6 대비 — 시스템 값은 손대지 않는다

실측 1건 미달: 사이드바 섹션 헤더 **2.63:1**(WCAG AA 4.5:1 미달).
다만 이건 이 앱이 고른 색이 아니라 macOS `List(.sidebar)` 의 **시스템 기본값**이다.

**규약: 시스템 기본 대비를 커스텀 색으로 덮어쓰지 마라.**

- 시스템 값을 이기려고 `.foregroundStyle(.white)` 같은 걸 넣으면, 라이트 모드·고대비 모드·
  향후 OS 업데이트에서 전부 따로 깨진다. 시맨틱을 버리는 순간 세 가지 대응을 직접 떠안는다.
- 대신 (1) `darkAqua` 강제를 걷어내 시스템의 라이트/다크 값이 제대로 적용되게 하고(§8.1),
  (2) 시스템 "대비 증가" 설정을 존중한다(시맨틱 컬러면 자동).
- **우리가 고른 색**이 AA 미달이면 그건 우리 책임이다 — 그런 자리가 나오면 시맨틱 색을
  다른 것으로 바꿔라(불투명도를 올리는 게 아니라).

---

## 5. 현지화 규약

근거: `AGENTS.md:34-45`, `Tests/WapleAppTests/LocalizationCoverageTests.swift`.

### 5.0 ⚠️ 가장 중요한 사실 — 절반 이상은 strings 파일로 못 고친다

실측(2026-08-17): 한국어 리터럴 250개 중 **키가 있는 것은 122개(49%)**. 그리고
**사용자 대면 오류/상태 문자열 42건 중 40건은 `en.lproj` 에 무엇을 넣어도 영어로 안 나온다.**

원인은 "번역이 없어서" 가 아니라 **싱크의 타입이 `String` 이라서**다.
SwiftUI 의 `Text` 는 오버로드가 둘이다.

```swift
Text("적용 실패")        // Text(_ key: LocalizedStringKey) — 현지화됨
Text(someString)         // Text(_ content: some StringProtocol) — 현지화 안 됨
```

문자열을 `String` 변수에 담아 뷰까지 나르면 **후자가 선택되고, 조용히 번역이 사라진다.**
컴파일도 되고 테스트도 초록이다. 해당 패턴 5곳:

| 위치 | 싱크 |
| --- | --- |
| `SettingsView.swift:88` | `Text(message)` ← `vm.statusMessage: String?` |
| `WorkshopTabView.swift:24` | `Text(message)` ← `vm.statusMessage: String?` |
| `DiscoverView.swift:25` | `Text(message)` ← `workshopVM.statusMessage: String?` |
| `APIKeyGateView.swift:25` | `Text(message)` |
| `StatusBanner.swift:49` | `Label(msg, systemImage:)` ← `StatusBannerModel.message: String?` |

같은 문구가 경로에 따라 갈리는 실증: `SelectionPanelView.swift:115` 의
`'%@'을(를) 라이브러리에서 제거할까요?` 는 `String(format: NSLocalizedString(...))` 라
번역되는데, `WallpaperGridView.swift:85` 의 **완전히 같은 문구**는 `String` 보간이라 안 된다.

**규약: 사용자 대면 문자열을 미현지화 `String` 으로 나르지 마라.**

두 가지 적합한 방법이 있고, **이 저장소에서는 (a)를 권장한다.**

- **(a) 생산 지점에서 현지화한다** — 뷰모델·AppDelegate 가 메시지를 만들 때
  `NSLocalizedString` / `String(format: NSLocalizedString(...), …)` 로 완성해 넘긴다.
  타입은 `String` 그대로여도 되고, "이미 현지화된 문자열" 이라고 문서화한다.
  **권장 이유: 리터럴이 `NSLocalizedString(` 안에 남아 오라클(패턴 1)에 그대로 잡힌다.**
- **(b) 싱크 타입을 `LocalizedStringKey` / `LocalizedStringResource` 로 바꾼다** —
  `statusMessage = "적용 실패: \(reason)"` 이 키 `적용 실패: %@` 로 해석돼 동작은 맞다.
  **그러나 그 리터럴은 어떤 스캔 패턴에도 걸리지 않는다** — 대입문이기 때문이다.
  즉 런타임 버그 하나를 고치면서 오라클 사각지대를 새로 만든다. (b)를 택하려면
  **같은 커밋에서 스캔 패턴에 그 대입 형태를 추가**해야 한다.

어느 쪽이든 판정은 하나다 — **영어 로케일로 실제로 띄워 그 문구가 영어로 나오는가**(§5.5).

### 5.1 기본

- **키가 곧 한국어 원문이다.** `ko.lproj` 는 비어 있어야 한다(`testKoreanCatalogStaysEmpty`).
- SwiftUI 표시 API 의 문자열 리터럴은 `LocalizedStringKey` 로 해석돼 자동 번역된다 —
  호출부를 고칠 필요가 없다. 영어는 `Resources/en.lproj/Localizable.strings` 하나로 나온다.
- **AppKit 경로는 자동 해석이 없다.** `NSMenuItem(title:)` · `window.title` ·
  `NSOpenPanel.message`/`.prompt` · `NSImage(systemSymbolName:accessibilityDescription:)` 는
  `NSLocalizedString(_:comment:)` 로 감싼다. Unit E 의 트레이 메뉴가 전부 여기 해당한다.
- **값이 끼면 포맷 지정자를 명시한다.** 문자열 보간(`"\(x)분"`)은 추론이 모호해진다.
  `String(format: NSLocalizedString("%lld분", comment: ""), x)` — `%@`(String) · `%lld`(Int) ·
  `%.1f`(Double) 를 정확히 쓴다. 기존 8건이 `en.lproj` 하단 블록에 모여 있다.

### 5.2 새 문자열을 추가할 때

1. 한국어를 소스에 쓴다.
2. **같은 커밋에서** `en.lproj` 의 자기 마커 블록에 번역을 넣는다(§2 프로토콜).
3. `swift test --filter LocalizationCoverageTests` 로 확인한다.

### 5.3 오라클의 사각지대 — 반드시 알아야 할 것

`LocalizationCoverageTests` 는 **정해진 API 이름 목록**으로만 리터럴을 찾는다. 목록에 없는
API 로 문자열을 표시하면 **테스트는 초록인데 영어가 안 나온다.**

2026-08-17 실측으로 `ContentUnavailableView`·`ProgressView`·`LabeledContent` 세 API 가 목록에
없어 한국어 6건이 빠져나가고 있었고, 커밋 `80c1ee6` 에서 패턴과 번역을 함께 채웠다.
**개편은 `ContentUnavailableView` 를 대량으로 쓴다** — 같은 구멍을 다시 파지 마라.

규칙 — 둘 중 하나를 반드시 한다.

- **(권장) 문자열을 `Text` 로 감싸 넘긴다.** `Text` 는 이미 패턴에 있으므로 어떤 API 에
  넣든 잡힌다. 접근성 문자열도 이 방법으로 커버된다(`accessibilityValue`·
  `accessibilityAction(named:)` 는 패턴에 **없지만** 안에 든 `Text` 리터럴이 잡힌다).
  `tileAccessibility` 가 `String` 이 아니라 `Text` 를 받는 이유가 이것이다.
- 문자열을 받는 새 뷰 API 를 도입하면 **같은 커밋에서** 패턴 목록도 늘린다.

부수 효과 하나: 스캐너는 파일 전문을 읽으므로 **주석 안의 예제 코드도 걸린다.** 문서 주석에
한국어 리터럴이 든 코드 예제를 넣으면 번역 누락으로 잡힌다(이 개편 준비 중 실제로 걸렸다).
패턴을 줄여 회피하지 말고 주석을 프로즈로 바꿔라.

**남아 있는 사각지대 3종**(2026-08-17 실측, 아직 안 고쳤다):

| 사각지대 | 실례 | 규약 |
| --- | --- | --- |
| **삼항으로 고른 라벨** | `Button(cond ? "즐겨찾기 해제" : "즐겨찾기")` — `(` 바로 뒤가 `"` 가 아니라 둘 다 안 잡힌다 | 삼항으로 **문자열**을 고르지 말고 **`Text`** 를 골라라: `label: { cond ? Text("…") : Text("…") }`. 둘 다 잡힌다 |
| **enum 계산 프로퍼티 `label`** | `LibraryTypeFilter.label`·`NowPlayingSubtitle.typeLabel` 이 `return "장면"` — `"장면"` 은 지금 `en.lproj` 에 없다 | enum 표시 라벨은 **`NSLocalizedString` 으로 감싼다**(패턴 1 이 잡는다) |
| **`addItem(withTitle:)`** | `main.swift:18-24` 의 편집 메뉴 6개(실행 취소·다시 실행·오려두기·복사·붙여넣기·전체 선택) | 아래 ⚠️ |

⚠️ **`withTitle:` 은 이중 사각지대다.** 패턴 3 은 소문자 `title:` 만 보므로 스캔에서 빠지고,
`NSMenu.addItem(withTitle:)` 은 **자동 현지화도 하지 않는다**. 그래서 **패턴만 추가하고 코드를
안 고치면 오라클이 거짓 초록을 낸다** — strings 에 키가 생겨 "번역됨" 으로 보이지만 런타임은
계속 한국어다. 반드시 **같은 커밋에서 `NSLocalizedString` 래핑 + 패턴 추가 + 번역**을 함께
한다(Unit E).

### 5.4 개편이 만드는 새 문자열(예상)

사이드바 항목("전체"·"씬"·"동영상"·"웹"·"즐겨찾기"·"라이브러리"·"창작마당"·"둘러보기"·"폴더"),
접근성 액션 이름 11종 이상, 상태 value 문구, 필터 팝오버 라벨. **삭제**될 것: "보기"(세그먼트),
"필터 사이드바", "정보 패널", "뒤로 — %@", "표시". 삭제분은 고아 번역 테스트가 잡으므로
`en.lproj` 에서도 함께 지운다.

`en.lproj` 122키 중 **5개는 죽은 키**(런타임에 조회되지 않는다). 그중 3건의 원인은
`OnboardingView.row(title: String)` → `Text(title)` 비현지화 오버로드다 — §5.0 과 같은 병이고,
파라미터를 `Text` 로 바꾸면 함께 낫는다(Unit D).

### 5.5 ⚠️ 개발 실행으로는 영어를 볼 수 없다

`swift run Waple` 은 **항상 한국어**다. `.lproj` 는 리포 루트에 있고 `Package.swift` 의
`resources:` 선언은 `WapleRender/Resources/WEAssets` 뿐이라 빌드 산출물에 들어가지 않는다
(`find .build -name '*.lproj'` → 빈 결과). 영어는 `scripts/package-app.sh` 가
`Contents/Resources` 로 복사한 **패키징 앱에서만** 나온다.

`.lproj` 를 SPM 리소스로 옮기는 것은 **하지 마라** — SPM 리소스 번들에 넣으면 `Bundle.main`
조회가 실패한다(AGENTS.md §UI 문자열). 대신 검증 절차를 이렇게 고정한다.

```bash
bash scripts/package-app.sh
Waple.app/Contents/MacOS/Waple -AppleLanguages '(en)'    # 영어 UI 확인
```

**영어 UI 작업을 시작하기 전에 이 경로가 실제로 도는지 한 번 확인하라.** 안 되면 그 뒤의
모든 "영어로 고쳤다" 는 검증되지 않은 주장이다.

---

## 6. WAPLE_SMOKE 훅 이관 계획

**먼저 전제를 정정한다. `WAPLE_SMOKE` 는 자동 게이트가 아니다.**
`.github/` · `scripts/` · `Tests/` 어디에도 참조가 **0건**이고, CI 는
`swift build --build-tests` → `.saver` 컴파일 → `swift test` 뿐 스크린샷 단계가 없다.
"판정 게이트" 는 `docs/history/plans/2026-07-1*.md` 에 적힌 **사람이 눈으로 보는 수동 절차**로만
존재한다.

그래서 이 절의 무게는 "게이트를 지켜라" 가 아니라 이것이다 —
**개편 후 육안 재판정의 유일한 수단인데, 지금 구조상 깨져도 CI 가 초록이라 아무도 모른다.**
훅이 조용히 죽는 것이 이 저장소가 이번 사이클 내내 잡아온 실패 유형이다(CI 트리거 부재
`509781d`, 리소스 번들 누락 `912050c`, 방금 §5.3 의 현지화 오라클).

### 6.1 현재 배선 — 실측

| 환경변수 | 위치 | 효과 |
| --- | --- | --- |
| `WAPLE_SMOKE` | `main.swift:8` | 활성화 정책 `.regular`(Dock 아이콘 — 창 캡처에 필요) |
| | `AppDelegate.swift:238-243` | 메인창 자동 오픈 + 첫 항목 포커스 |
| | `MainWindowView.swift:30` | `showFilters = true`(필터 사이드바 노출) |
| | `AppDelegate.swift:276` | 온보딩 시트 억제 |
| `WAPLE_SMOKE_TAB` | `MainWindowView.swift:27-28` | 초기 탭 강제. 값 = `MainTab.rawValue`(`discover`/`workshop`) |
| `WAPLE_SMOKE_DISPLAYS` | `MainWindowView.swift:29` | 디스플레이 시트 열린 상태로 시작 |
| `WAPLE_SMOKE_SETTINGS` | `main.swift:8`, `AppDelegate.swift:246-248` | `.regular` + 설정 창 자동 오픈 |
| `WAPLE_SMOKE_ONBOARDING` | `main.swift:8`, `AppDelegate.swift:271-274` | `.regular` + 온보딩 시트 강제 표시 |

배선은 위 소스 5곳이 전부다. 절차는 `docs/history/` 의 플랜 문서에 다음 형태로 남아 있다.

```bash
swift build
WAPLE_SMOKE=1 .build/debug/Waple & APP=$!
sleep 6
WID=$(swift scripts/window-id.swift Waple)
screencapture -l"$WID" -x /tmp/waple-smoke.png
kill $APP
```

### 6.2 개편이 깨는 것

- `WAPLE_SMOKE_TAB` 의 **의미가 사라진다** — `MainTab` 이 없어진다.
- `showFilters` 가 사라진다 — `FilterSidebarView` 가 없어진다.
- 두 상태 모두 `MainWindowView` 의 `@State` 초기값이라, 뷰를 갈아엎으면 **컴파일 에러 없이
  조용히 사라진다.** `ProcessInfo...environment[...]` 를 지운 자리는 아무도 못 알아챈다.
  캡처는 계속 나오고, 그냥 항상 기본 화면만 찍힌다. 이게 정확히 "게이트가 조용히 무력화" 다.

### 6.3 이관 원칙

**환경변수 이름과 값을 바꾸지 않는다.** 스크립트·CI 에 없다는 것은 곧 "고쳐줄 곳이 없다"는
뜻이 아니라 "깨져도 알려줄 곳이 없다"는 뜻이다. 이름을 바꾸면 `docs/history/` 의 절차와
사용자의 손 기억이 전부 어긋난다. 의미만 새 구조로 재해석한다.

| 환경변수 | 개편 후 의미 |
| --- | --- |
| `WAPLE_SMOKE` | 변경 없음 + **사이드바 노출 보장** + 첫 항목 포커스 + 인스펙터 표시(`showFilters=true` 자리를 승계 — 캡처에 좌우 열이 다 나와야 판정이 된다) |
| `WAPLE_SMOKE_TAB=discover` | 사이드바 선택 = **창작마당 > 둘러보기** |
| `WAPLE_SMOKE_TAB=workshop` | 사이드바 선택 = **창작마당 > 검색** |
| `WAPLE_SMOKE_TAB=installed` | 사이드바 선택 = **라이브러리 > 전체** (기존 기본값의 명시형 — 신규 허용값) |
| `WAPLE_SMOKE_DISPLAYS` | 변경 없음 |
| `WAPLE_SMOKE_SETTINGS` | 변경 없음 |
| `WAPLE_SMOKE_ONBOARDING` | 변경 없음 |

### 6.4 조용한 무력화를 막는 장치 — Unit A 의 **필수** 완료 조건

환경변수 해석을 **순수 함수로 뽑고 단위 테스트를 붙인다.** 그러면 배선을 빠뜨렸을 때
"이상한 스크린샷" 이 아니라 **빨간 테스트**가 난다.

`Sources/Waple/Shell/SmokeLaunch.swift` (신규, 순수 — AppKit·SwiftUI 의존 금지):

```swift
/// 스모크 캡처 환경변수 → 초기 UI 상태. 순수 — 테스트가 이 함수만 검증하면
/// 배선 누락이 스크린샷이 아니라 빨간 테스트로 드러난다.
struct SmokeLaunchState: Equatable {
    var isCapture: Bool            // .regular 활성화 정책 필요
    var opensLibrary: Bool
    var section: LibrarySelection? // nil = 기본(라이브러리 > 전체)
    var showsSidebar: Bool
    var showsInspector: Bool
    var opensDisplays: Bool
    var opensSettings: Bool
    var forcesOnboarding: Bool
    var suppressesOnboarding: Bool
}

enum SmokeLaunch {
    static func state(env: [String: String]) -> SmokeLaunchState { … }
}
```

`Tests/WapleAppTests/SmokeLaunchTests.swift` 가 최소한 검증할 것:

1. 빈 환경 → 캡처 아님, 온보딩 억제 아님.
2. `WAPLE_SMOKE=1` → 캡처·창 오픈·사이드바·인스펙터 전부 참, 온보딩 억제 참.
3. `WAPLE_SMOKE_TAB` 세 값이 각각 올바른 사이드바 선택으로 매핑된다.
4. **알 수 없는 `WAPLE_SMOKE_TAB` 값은 기본으로 폴백하고 조용히 무시하지 않는다**
   (`SmokeLaunch` 가 `nil` 을 돌려주고 호출부가 `NSLog` 로 남긴다 — 오타로 엉뚱한 화면을
   찍고 통과시키는 걸 막는다).
5. `WAPLE_SMOKE_SETTINGS` / `_ONBOARDING` 단독으로도 캡처 정책이 켜진다.
6. `_ONBOARDING` 은 강제 표시, 그 외 `WAPLE_SMOKE*` 는 억제(현행 규약 무회귀).

그리고 **호출부는 이 함수 하나만 소비한다** — `main.swift`·`AppDelegate`·`MainWindowView` 가
각자 `ProcessInfo` 를 읽던 현행 3분산을 없앤다. 분산돼 있으면 한 곳만 고치고 넘어가게 된다.

### 6.5 재판정 일정

| 시점 | 캡처 | 판정자 |
| --- | --- | --- |
| Phase 1 완료 직후 (**팬아웃 전, 필수**) | 5종 전부: `WAPLE_SMOKE` / `+_TAB=installed` / `+_TAB=discover` / `+_TAB=workshop` / `_DISPLAYS` / `_SETTINGS` / `_ONBOARDING` | 사용자 |
| Phase 2 각 단위 완료 | 그 단위 표면만 (B→`WAPLE_SMOKE`, C→`_TAB` 2종, D→`_DISPLAYS`·`_SETTINGS`·`_ONBOARDING`) | 사용자 |
| Phase 3 완료 | 5종 전부 재캡처 + **라이트/다크 양쪽**(§8.1) + **영어 로케일**(패키징 앱, §5.5) | 사용자 |

- **Phase 1 게이트를 건너뛰지 마라.** A 가 껍데기만 바꾸고 콘텐츠는 기존 뷰를 그대로 쓰는
  이유가 이것이다 — 이 시점의 캡처는 "네비게이션 이관이 무손실인가" 만 묻는 깨끗한 질문이 된다.
  B/C/D 가 동시에 들어간 뒤에 찍으면 무엇 때문에 깨졌는지 못 가린다.
- 영어 로케일 캡처를 반드시 한 번은 한다. 오라클은 *누락* 만 잡고 *잘림* 은 못 잡는다 —
  사이드바 폭·툴바 배치는 영어에서 더 길어진다. **`swift run` 으로는 영어가 안 나온다** —
  반드시 패키징 앱 + `-AppleLanguages '(en)'`(§5.5).

### 6.6 스크립트로 승격할 것인가 — 하지 않는다(이번엔)

절차를 `scripts/mac-session/smoke-capture.sh` 로 만들면 편해지지만, **판정은 여전히 사람이**
한다(픽셀 비교 게이트가 아니라 "보기 좋고 네이티브다운가" 판정이다). 스크립트가 초록을 내도
아무것도 보장하지 않으므로, 자동화는 오히려 "돌렸으니 됐다"는 착각을 만든다.
대신 §6.4 의 순수 함수 테스트가 **기계가 판정할 수 있는 부분**(배선 존재 여부)을 가져간다.
이 분리를 지켜라.

---

## 7. 이관 순서와 위험

### 7.1 순서

1. **Phase 0 — 토큰** (완료). `DesignSystem/` 동결.
2. **Phase 1 — A ∥ S.** A 의 첫 작업은 §7.2 의 실현성 확인이다.
3. **게이트 — 스모크 5종 + 사용자 판정.** 통과 못 하면 Phase 2 를 시작하지 않는다.
4. **Phase 2 — B ∥ C ∥ D.** 순차 머지(§2 문자열 프로토콜).
5. **Phase 3 — E.** 트레이·현지화 정규화·최종 재판정.

### 7.2 최대 미지수 — `NavigationSplitView` × `NSHostingController`

> ## ✅ 해소됨 — 2026-08-17 Unit A 실측. **폴백은 쓰지 않는다.**
>
> 프로토타입 3벌을 실제로 띄워 캡처로 확인했다(`WAPLE_SMOKE=1`, 창 캡처).
>
> | 물음 | 결과 |
> | --- | --- |
> | `NavigationSplitView` 2열이 이 창에서 뜨는가 | **된다.** 소스리스트 재질·섹션 헤더·선택 하이라이트 전부 시스템 기본값으로 나온다 |
> | 사이드바 토글이 브리징 툴바에 **자동으로** 붙는가 | **안 붙는다.** 직접 만들어야 한다 |
> | 직접 만든 `.toolbar` 항목은 계속 브리징되는가 | **된다.** `.navigation`·`.primaryAction` 양쪽 다 정상 — 툴바가 비는 회귀는 없었다 |
> | `.inspector` 가 뜨는가 / 토글이 자동으로 붙는가 | **뜬다 / 안 붙는다.** `isPresented` 바인딩은 정상 동작 |
> | `.searchable(placement: .toolbar)` | **된다.** 툴바 우측에 시스템 서치필드로 나온다. 그래서 §8.4 는 "바꾼다" 로 확정 |
> | 열 폭이 실행 간에 저장되는가 | **안 된다.** 세 번 실행 후 앱 defaults 도메인에 스플릿·사이드바 오토세이브 키가 하나도 생기지 않았다. 매 실행 `navigationSplitViewColumnWidth` 의 ideal 로 시작한다(허용) |
>
> 토글 자동 부착 여부는 이렇게 갈랐다: 직접 만든 토글 둘을 넣고 찍어 **각각 하나씩만** 보이는지
> 확인했다. 시스템이 붙였다면 둘씩 보였을 것이다.
>
> 즉 막힌 것은 없고, 시스템이 공짜로 주는 범위가 문서보다 **두 칸 좁았을** 뿐이다.
> 폴백(`HSplitView` + 수동 사이드바)은 채택하지 않았다.


이 앱은 SwiftUI `App`/`Scene` 을 쓰지 않는다. `NSHostingController` 를 `NSWindow` 에 담고
`sceneBridgingOptions = [.toolbars]` 로 툴바만 브리징한다(`AppDelegate.openLibrary`).
`NavigationSplitView` 와 `.inspector` 는 **Scene 기반 사용을 전제로 문서화돼 있고**,
이 조합에서의 동작(사이드바 토글 버튼이 툴바에 자동으로 뜨는가, 열 폭이 저장되는가,
`.inspector` 토글이 툴바에 붙는가)은 여기서 검증할 수 없다.

**Unit A 는 다른 작업을 하기 전에 이것부터 확인한다.** 순서:

1. 최소 프로토타입으로 `NavigationSplitView` + `.inspector` 를 현재 창 생성 경로에 띄운다.
2. `WAPLE_SMOKE=1` 캡처로 사이드바 토글·인스펙터 토글이 툴바에 나오는지 눈으로 본다.
3. 안 되면 **폴백**: `HSplitView` + `List(selection:).listStyle(.sidebar)` + 툴바에 직접 만든
   토글 버튼. 이 조합은 이 저장소에 **이미 있다**(`FilterSidebarView` 가 `.listStyle(.sidebar)`,
   `MainWindowView` 가 조건부 `HStack`). 폴백을 택하면 이 문서에 그 사실과 이유를 적어라.
4. 어느 쪽이든 창 생성이 `AppDelegate` 라는 사실은 안 바뀐다 — `NSWindow` 를 SwiftUI
   `WindowGroup` 으로 바꾸는 것은 **이번 스코프 밖**이다(액세서리 앱 정책·창 수명 규약
   `isReleasedWhenClosed=false`·`darkAqua` 강제가 전부 그 코드에 얽혀 있다).

### 7.3 회귀가 날 만한 곳

| 위험 | 왜 | 완화 |
| --- | --- | --- |
| **스모크 게이트 무력화** | 삭제해도 컴파일 에러가 안 난다 | §6.4 순수 함수 + 테스트 |
| **`onOpenWorkshop` 끊김** | `MainWindowView.onAppear` 에서 `tab = .workshop` 로 배선. `MainTab` 이 사라지면 이 줄이 지워지고, 빈 라이브러리의 "창작마당 열기" 버튼이 조용히 무동작이 된다 | A 가 사이드바 선택으로 재배선. B 가 빈 상태 버튼 동작을 눈으로 확인 |
| **`panelVisible` 이중 관리** | 현재 `LibraryViewModel.panelVisible`(전역) + 툴바 버튼. `.inspector(isPresented:)` 로 옮기면 소유자가 둘이 된다 | 바인딩 하나만 남긴다. A 가 결정하고 B 는 따른다 |
| **폴더 내비게이션 이관** | `activeFolder` 를 그리드(B)와 사이드바(A)가 함께 읽는다. 파일은 안 겹치지만 **의미가 겹친다** | `activeFolder` 는 계속 단일 소스. 사이드바는 쓰기, 그리드는 읽기. 그리드에서 폴더로 들어가는 경로는 **없앤다**(뒤로 타일 포함) |
| **`sceneBridgingOptions` 툴바 회귀** | 툴바 아이템 구성을 바꾸면 브리징이 조용히 빈 툴바를 낼 수 있다 | Phase 1 캡처에서 확인 |
| **PropertyEditor 커밋 경로** | F494(슬라이더)·감사 V06(컬러 디바운서)·미커밋 텍스트 커밋이 `onDisappear` 에 걸려 있다. 인스펙터는 시트와 **생명주기가 다르다** — 인스펙터를 접어도 `onDisappear` 가 안 올 수 있다 | B 는 커밋 트리거를 인스펙터 표시 상태 변화에도 건다. 슬라이더 드래그 중 인스펙터를 접어 값이 저장되는지 손으로 확인 |
| **고정 크기 시트 잘림** | 설정 560×820·온보딩 460×430. 항목이 늘거나 영어가 길어지면 잘린다 | D 는 `ScrollView` + `minHeight`. F090 선례 |
| **`darkAqua` 강제와 접근성 대비** | 창 단위 다크 강제(스펙 §3)라 시스템 "대비 증가"·라이트 모드가 반영되지 않는다 | **걷어낸다**(2026-08-17 사용자 승인). 선행 조건은 리터럴 색 13곳 제거 — §8.1 참조 |
| **`.lproj` 가 개발 실행에 없다** | `swift run Waple` 은 항상 한국어. "영어 확인했다" 가 검증 불가 주장이 된다 | §5.5 의 패키징 앱 절차. 단위 완료 조건에 넣었다 |
| **미현지화 `String` 전파** | `Text(someString)` 오버로드는 조용히 번역을 버린다. 이미 42건 중 40건이 이 병 | §5.0. 뷰모델 4곳 + 배너 1곳이 진원지 |
| **테스트 수 2,180 → 2,262** | `UIConventionTests` 3건 + 같은 날 엔진 수정 17건. 각 단위의 신규 테스트로 더 늘어난다 — 정상이다 | 각 단위가 커밋 메시지에 증감과 이유를 적는다. **줄면** 무언가 지워진 것이다 |
| **292개 초록이 아무것도 보장하지 않는다** | SwiftUI 를 인스턴스화하는 테스트가 0개 | §7.4. "테스트 통과" 를 개편 완료 근거로 쓰지 마라 |
| **타입체커 폭발** | 이 저장소에서 4번 났고 SwiftUI 뷰 빌더가 특히 취약하다. 사이드바+콘텐츠+인스펙터를 한 `body` 에 넣으면 유력하다 | 각 열을 별도 `private var … : some View` 로 뺀다. 제네릭 슬롯 컴포넌트 금지(§3.2). CI 가 로컬과 다른 Xcode 를 쓴다 — 큰 변경은 PR 로 CI 를 한 번 태워라 |

### 7.4 ⚠️ 안전망이 없다 — 무엇으로 잡을 것인가

실측(2026-08-17): `Tests/WapleAppTests` 292개 중 **`import SwiftUI` 하는 파일이 0개**,
SwiftUI 뷰를 인스턴스화하는 테스트가 **0개**다. 즉 **레이아웃·색·모션·접근성·구조를 어떻게
바꾸든 292개가 전부 초록으로 남는다.** 이 스위트가 실제로 잡는 개편 회귀는 **카피 변경뿐**이다
(`NowPlayingSubtitleTests` 의 부제 전문 단언, `SettingsPresentationTests:40,45,47` 의
`"사용 중"`·`"brew install ffmpeg"` 포함 단언).

이 사실을 모르고 "테스트 292개 통과" 를 근거로 삼으면, **개편이 다 깨져 있어도 초록이다.**

뷰 스냅샷 테스트를 도입하자는 게 아니다(무겁고 이 저장소의 골든 정책과도 어긋난다).
`LocalizationCoverageTests` 가 이미 쓰는 **소스 텍스트 스캔** 방식으로, 기계가 판정할 수 있는
만큼만 가져간다. **이미 만들어 커밋했다** — `Tests/WapleAppTests/UIConventionTests.swift`(3건):

| 오라클 | 잡는 것 | 현재 허용 목록 |
| --- | --- | --- |
| `testAnimationsComeFromMotionTokens` | 화면 코드의 `.spring(`/`.easeInOut(`/`.linear(`/`withAnimation(.` | MainWindowView(A) · StatusBanner(A) · RemoteTile(C) · WallpaperGridView(B) |
| `testContextMenusHaveAccessibilityCounterpart` | `contextMenu` 는 있는데 `accessibilityAction` 이 없는 파일 | WallpaperGridView(B) |
| `testTapDrivenViewsDeclareAccessibility` | `onTapGesture` 는 있는데 접근성 표현이 없는 파일 | DisplaysView(D) · WallpaperGridView(B) |

**허용 목록은 줄어들기만 한다.** 담당 단위가 마이그레이션하며 자기 파일을 지운다.
목록에 남았는데 더는 위반하지 않으면 그것도 실패다 — 목록이 썩어 새 위반을 덮어주는 걸 막는다.
**목록에 파일을 추가하지 마라.**

저장소 규범대로 **일부러 깨뜨려 잡히는지 확인했다**(2026-08-17): 비허용 파일에 `.spring(` ·
`.contextMenu` · `onTapGesture` 를 각각 넣어 3건 모두 빨강, 허용 파일의 위반을 없애 스테일
경로도 빨강. 네 경로 전부 확인 후 되돌렸다.

⚠️ **텍스트 스캔이라 주석에 눈이 없다 — 양방향으로.** 주석에 `tileAccessibility` 라고 적으면
그 파일의 위반이 **침묵**하고, 주석에 `.spring(` 이라고 적으면 깨끗한 파일이 **오탐**한다
(둘 다 파괴 검증 중 실제로 재현됐다). `LocalizationCoverageTests` 도 같은 이유로 주석 속
한국어 리터럴을 잡는다. **규약 API 이름을 주석에 원문 그대로 쓰지 마라** — 설명이 필요하면
백틱 없이 풀어 쓰거나 이름을 쪼개라.

여전히 **자동으로 못 잡는 것**(사람이 캡처로 봐야 한다): 실제 레이아웃·잘림·대비·
포커스 순서·VoiceOver 읽기 순서·영어 문구의 길이. 그래서 §6.5 의 육안 재판정을 건너뛰면 안 된다.

값싸게 더 붙일 수 있는 것(선택, 필요해지면):
- 스모크 훅 도달 단언 — `SmokeLaunch` 순수 함수 테스트(§6.4, Unit A 필수).
- 사이드바 선택 → 필터 상태 매핑 테스트 — `LibrarySection` 순수 함수(Unit A).
- 하드코딩 치수 상한 오라클 — 지금 81곳이라 즉시 도입하면 노이즈다. Phase 3 에서
  숫자가 충분히 줄었을 때 상한선을 걸어 재발을 막는 편이 낫다.

### 7.5 각 단위의 완료 조건 (공통)

- [ ] `swift build` 통과.
- [ ] `swift test` **순차** 통과(`--parallel` 은 이 저장소에서 거짓 실패를 낸다 — AGENTS).
- [ ] `swift test --filter LocalizationCoverageTests` 통과.
- [ ] 동결 파일 목록을 건드리지 않았다(`git diff --stat` 으로 확인).
- [ ] 이 화면의 모든 `contextMenu` 항목에 대응하는 `accessibilityAction` 이 있다(§4.3).
- [ ] `swift test --filter UIConventionTests` 통과 + **자기 파일을 허용 목록에서 지웠다**(§7.4).
- [ ] 애니메이션을 `Motion` 토큰으로만 만들었다.
- [ ] 새 한국어 문자열이 `en.lproj` 자기 블록에 있다.
- [ ] 사용자 대면 문자열을 미현지화 `String` 으로 뷰까지 나르지 않았다(§5.0).
- [ ] 패키징 앱 + `-AppleLanguages '(en)'` 로 이 화면의 영어 표시를 눈으로 확인했다(§5.5).
- [ ] 스모크 캡처를 찍어 사용자 판정을 받았다.
- [ ] 커밋 메시지가 한국어 서술형이고 접두사가 없으며 **AI 귀속 트레일러가 없다**.

---

## 7.9 ⚠️ 라이트 모드 판정 — 이 머신에서는 못 한다 (2026-08-18 실측)

`darkAqua` 강제는 코드에서 걷어냈다(Unit E). 그런데 **라이트에서 실제로 성립하는지는
이 머신에서 판정할 수 없다.**

실측: `defaults delete -g AppleInterfaceStyle` 로 키를 지워도
`System Events → appearance preferences → dark mode` 가 **계속 `true`** 다.
키가 없으면 라이트여야 하는데 아니다 — 이 머신은 다른 경로로 다크가 고정돼 있다.
그래서 "라이트로 바꾸고 찍은" 캡처가 실제로는 다크이고, 중앙 픽셀이
`(41,42,45)` 로 다크 캡처와 같다.

**이 증상을 "앱이 아직 다크를 강제한다" 로 오독하지 마라.** 강제는 지워졌다(코드 확인).
종전에 같은 md5 를 근거로 "라이트 모드가 없다" 고 판정했던 것과 **겉보기 증상이 같아서**
특히 위험하다 — 그때는 앱이 원인이었고 지금은 캡처 환경이 원인이다.

대신 확인한 것(간접 근거):
- `Sources/Waple` 전체에서 UI 색은 전부 `ColorRole`/시맨틱이다. 남은 리터럴 2건은
  `PropertyEditorView.swift:256,259` 뿐이고 **월페이퍼 속성 데이터의 파스 폴백**이라
  외관과 무관하다.
- 창 생성 두 곳(`AppDelegate.swift:338`·`:393`)에 `window.appearance` 대입이 없다.
- `NSApp.appearance`·`NSRequiresAquaSystemAppearance` 도 0건(앱·plist 양쪽).

**남은 완료 조건**: 라이트가 실제로 켜지는 머신에서 5표면을 찍어 육안 판정할 것.
그 전까지 "라이트 모드 동작" 을 확정으로 적지 마라.

---

## 8. 확정되지 않은 결정 — 사용자 확인 필요

> **1번은 2026-08-17 사용자 승인으로 확정됐다 — 걷어낸다.** 아래 항목의 "확인 필요" 표기는
> 무효이고, 근거·선행 조건·소유 배정은 그대로 유효하다. 이 결정은 2026-07-12 스펙 §3
> ("다크 하의 시맨틱 값만 사용, 라이트 대응 없음")을 **명시적으로 대체한다** — 스펙을
> 몰라서 어긴 것이 아니라 읽고 뒤집은 것이므로, 이후 누구도 스펙 §3 을 근거로 되돌리지 말 것.
> 되돌리려면 이 결정과 아래 근거를 반박해야 한다.
>
> 2~5번은 여전히 미확정이며, 각 항목의 권고대로 진행하되 뒤집힐 수 있다.

1. **`darkAqua` 강제를 걷어낸다** — 이 문서에서 스펙을 뒤집는 유일한 항목이다.
   **(2026-08-17 승인 확정)**

   실측(2026-08-17): `AppDelegate.swift:325`·`:347` 이 `window.appearance =
   NSAppearance(named: .darkAqua)` 로 두 창 모두 다크를 강제한다. 시스템을 라이트로 바꾸고
   찍은 캡처가 다크 캡처와 **md5 까지 동일**했다 — 이 앱에는 라이트 모드가 존재하지 않는다.

   근거는 코드 주석의 `// WE 관례 — 항상 다크` 와 스펙 §3("다크 하의 시맨틱 값만 사용,
   라이트 대응 없음")이다. 읽고 판단한 결론: **그 근거는 이번 방향과 정면으로 모순된다.**
   "네이티브 정통 = 시스템이 공짜로 주는 것을 최대한 받아먹는다" 를 고른 이유의 큰 부분이
   시스템 외관을 따라가는 것인데, 지금은 그걸 코드 두 줄로 막고 있다. WE 가 항상 어둡다는
   것은 WE 의 사정이지 macOS 앱이 사용자 설정을 무시할 이유가 아니다.

   - **소유: Unit A**(창 생성이 A 의 스코프). `window.appearance` 대입 2줄 제거.
   - **선행 조건: 리터럴 색 13곳 제거.** 강제를 걷어내면 라이트에서 그 자리만 깨진다.
     `ColorRole` 이 전부 시맨틱이라 토큰을 채택한 화면은 자동으로 따라온다 — 즉
     **부록 A §A.4 를 끝낸 단위부터 라이트가 정상 동작한다.** 순서상 강제 제거는
     Phase 2 가 끝난 뒤(Phase 3, Unit E)가 안전하다. A 는 코드만 준비하고 플래그로 막아
     두거나, E 가 제거한다 — **A 와 E 중 누가 지울지는 A 가 결정하고 이 문서에 적는다.**
   - **결정(2026-08-17, Unit A): E 가 지운다. A 는 두 줄을 그대로 둔다.**
     근거는 위 "선행 조건" 그대로다 — 리터럴 색 13곳이 B·C·D 소유 파일에 흩어져 있어, A 가
     지금 강제를 걷으면 **A 가 손도 대지 않은 화면들이 라이트에서 깨진 채로 Phase 2 내내
     남는다.** A 의 산출물은 "껍데기가 바뀌어도 전부 동작한다" 인데, 라이트가 깨진 화면을
     남기면 그 판정 자체가 흐려진다. A 가 새로 쓴 색은 전부 `ColorRole`·`Surface` 토큰이라
     강제를 걷는 순간 자동으로 따라온다(A 쪽 선행 조건은 이미 충족돼 있다).
     또한 이 항목은 **사용자 승인 대기 중**이고, 승인 시점이 Phase 3 보다 늦어질 수 있는데
     A 가 미리 지워 두면 되돌릴 커밋을 찾아야 한다.
   - **판정: 라이트/다크 양쪽 스모크 캡처**(§6.5 에 반영).
   - 병렬 단위가 **임의로** 라이트 전용 분기를 넣는 것은 여전히 금지다. 시맨틱 토큰만 쓰면
     분기가 필요 없다 — 분기를 쓰고 싶어졌다면 리터럴 색이 남아 있다는 뜻이다.
2. **`창작마당 > 구독` 의 처분**(§1.3). 대응 표면이 없어 "둘러보기" 로 대체했다.
   진짜 구독 목록을 원한다면 Steam 인증이 필요한 별도 SP 다.
3. **폴더를 사이드바로 올릴 것인가.** Finder/Photos 관례에는 맞지만, 폴더가 많은 사용자는
   사이드바가 길어진다. 대안은 그리드 안 폴더 타일 유지(현행). 권고는 사이드바 이관이되
   폴더 0개면 섹션을 숨기는 것.
4. **검색 필드를 `.searchable` 로 바꿀 것인가.** ⌘F·Esc·접근성을 공짜로 얻지만, 툴바 배치가
   시스템 결정이 되어 현재의 "정렬 메뉴 옆 고정폭 필드" 배치와 달라진다. 권고: 바꾼다.
   → **적용됨(Unit A, Phase 1).** 실측상 툴바 우측에 시스템 서치필드로 정상 표시된다(§7.2).
   부수 변경 둘: (a) 둘러보기 표면에서는 검색 필드가 **사라진다**(거를 대상이 없다),
   (b) 창작마당>검색에서 종전의 `.disabled(!hasAPIKey)` 가 없어졌다 — `.searchable` 에는
   대응 수정자가 없고, 키가 없으면 콘텐츠가 `APIKeyGateView` 라 입력해도 결과가 없을 뿐이다.
   신경 쓰이면 Unit C 가 게이트 화면에서 안내를 보강하는 편이 낫다.
5. **`Metrics.sidebarWidth`(220)·`panelWidth`(300) 상수 처분.** 새 코드는 min/ideal/max 를
   쓰므로 이 둘은 사용처가 사라진다. 지울지 남길지는 Phase 3 에서 판단(보존 필드 규약과
   무관한 순수 미사용 상수라 지워도 무방하나, 지우는 커밋을 따로 낸다).

---

## 9. 개편 중 함께 고칠 실측 결함

실태 조사(2026-08-17)에서 나온, 감사 문서에 없던 결함이다. 전부 담당 단위가 자기 화면을
개편하면서 함께 고친다 — 따로 처리하면 같은 파일을 두 번 만진다.

### 9.1 디스플레이 시트가 화면 폭 전체로 팽창한다 (Unit D, 심각)

실측 창 크기: 부모 `1280×872`, 시트 **`1800×560`**. 캡처를 보면 시트가 부모 창을 좌우로
넘어 **화면 가장자리까지** 뻗고, 하단 레일이 끝에서 잘린다. 모달 시트가 부모보다 큰 것은
macOS 어디에도 없는 형태다.

**팽창은 실측, 원인은 추정이다.** 유력한 설명: `DisplaysView.swift:192-204` 의
`assignmentRail` — `ScrollView(.horizontal)` 이 콘텐츠의 **이상 폭(ideal width)을 그대로 위로
전파**하고, 라이브러리 193개 × 타일 74pt + 간격이 시트의 이상 폭이 되며, 루트에는
`minWidth` 만 있고 `maxWidth` 가 없어(`:99`) 막지 못한다. **Unit D 의 완료 조건에 "레일 항목
수를 줄이면 폭이 함께 줄어드는지" 를 확인해 이 기전을 확정하는 것을 포함한다** — 기전이
다르면 아래 수정 방향도 틀린다.

수정 방향: 레일 쪽에서 이상 폭 전파를 끊는다 — 루트에 `maxWidth` 를 주거나, 레일을
`.frame(maxWidth: .infinity)` 로 감싸 콘텐츠 폭이 컨테이너를 결정하지 못하게 한다.
**타일 수를 줄여 회피하지 마라** — 라이브러리가 커지면 같은 문제가 돌아온다.
회귀 방지: 라이브러리 200개 이상 상태에서 시트를 열어 캡처.

> **해소됨 — 2026-08-17 Unit D. 기전 확정.** 같은 빌드에서 라이브러리 항목 수만 바꿔 재현했다:
> 200개 → 시트 `1800×560`(화면 폭에 걸려 잘린 값), 5개 → `860×560`(= `displaysMin` 그대로).
> 항목 수가 시트 폭을 정한다 — 위 추정이 맞았다.
>
> 다만 고친 자리는 레일이 아니라 **루트**다. 레일에 상한을 씌우는 안은 가로로 스크롤되는
> 자식이 하나 더 생기는 순간 같은 결함이 돌아온다. 루트가 이상 폭·높이를 스스로 말하게 하고
> (960×620), 상한은 부모 창의 **최소** 크기(`Metrics.windowMin`)로 걸었다.
> 수정 후 재측정: 200개·5개 양쪽 다 `960×620`, 부모 `1280×872` 안에 들어온다.
> 회귀는 `SurfaceSizingTests` 가 소스 스캔 + 상수 불변식으로 잡는다.

### 9.2 설정 창 마지막 섹션이 잘린다 (Unit D)

`Metrics.settingsSize`(560×820) + `SettingsView.swift:20` 의 `.frame(height: 820)` +
리사이즈 불가 창(`AppDelegate.swift:345` 의 `styleMask` 에 `.resizable` 없음)의 조합.
`Metrics.swift:36` 주석은 "5섹션+푸터가 스크롤 없이 한눈에" 인데 현재 섹션은 **6개**다 —
주석이 스테일하고, 마지막 `에셋·도구` 섹션이 실제로 화면 밖으로 밀린다.

수정 방향: **높이를 키우지 마라.** 항목은 앞으로도 늘고 Dynamic Type 큰 글씨에서는 어떤
고정 높이도 결국 넘친다. `Form` 을 스크롤 가능하게 두고(`.frame(height:)` 제거), 창에
`.resizable` 을 주거나 `minHeight` 만 건다. 온보딩이 F090 에서 이미 같은 결정을 했다.
(`Metrics.swift` 주석은 Phase 0 에서 정정해 두었다.)

> **절반 해소 — 2026-08-17 Unit D. 위 서술 두 가지를 정정한다.**
>
> **(1) "잘려서 도달 불가" 가 아니다.** 스크롤바를 항상 보이게 켜고
> (`-AppleShowScrollBars Always`) 찍으면 **종전 빌드에도** 스크롤 트랙이 있고 썸이 트랙의
> 약 86%(= 820/953)를 차지한다 — macOS 의 grouped `Form` 은 스스로 스크롤한다. 그러니
> 마지막 섹션은 스크롤로 닿을 수 있었고, 문제는 "첫 화면에서 반쯤 잘려 보이고 창을 키워
> 한눈에 볼 수 없다" 였다. 콘텐츠 실측 높이는 약 953pt, 창 안쪽은 820pt 다.
>
> **(2) 창 크기는 뷰가 정하지 못한다 — 그래서 이건 Unit D 혼자 못 고친다.**
> `AppDelegate.openSettings` 의 `setContentSize` 가 560×820 을 못 박아서, 뷰의 이상 높이를
> 1000 으로 바꿔 띄워도 창은 `560×848` 그대로였다.
>
> Unit D 가 한 것은 **창 쪽 수정이 먹히도록 뷰의 발목을 푸는 것**이다. 창에 `.resizable` 과
> 콘텐츠 높이 1000 을 임시로 주고 대조했다(패치는 되돌렸다):
>
> | 뷰 | 결과 |
> | --- | --- |
> | 고정 높이 유지 | 창이 **`560×848` 로 되돌아간다** — 뷰의 경직된 요구가 창을 이긴다 |
> | 고정 높이 제거 | 창이 **`560×1028`** 로 열리고 6개 섹션이 전부 보인다 |
>
> 즉 **창만 고쳐도, 뷰만 고쳐도 안 되고 둘 다 필요하다.** 뷰 쪽은 끝났다(높이를 최소·이상·
> 최대로만 말한다). **남은 절반은 `AppDelegate` 소유라 Unit A/E 몫이다** — 설정 창
> `styleMask` 에 `.resizable` 추가 + 못 박는 `setContentSize` 완화.
>
> `Form` 을 `ScrollView` 로 한 겹 더 감싸는 안은 시도했다가 버렸다. 감싼 빌드와 안 감싼
> 빌드의 스크롤바 썸 기하가 픽셀 단위로 같았고(이미 스크롤되니 당연하다), 창이 콘텐츠보다
> 커졌을 때 폼 배경이 따라 늘지 않아 아래가 빈 판으로 남는 단점만 남는다.
>
> ⚠️ **판정 도구 주의.** 합성 입력(`CGEvent` 스크롤·`osascript` 키스트로크)은 이 머신에서
> **전달되지 않는다**(Accessibility 미허용 — 마우스 커서조차 안 움직인다). 그런데 아무
> 오류도 나지 않고 캡처는 멀쩡히 나오므로, "휠을 굴렸는데 화면이 그대로다 → 스크롤 안 된다"
> 는 **거짓 결론**이 된다(실제로 한 번 그렇게 잘못 판정했다). 스크롤 여부는 위처럼
> `-AppleShowScrollBars Always` 로 **정적 캡처에서** 판정하라.

### 9.3 메뉴바 현지화 결함 3건 (Unit E)

| 위치 | 결함 |
| --- | --- |
| `AppDelegate.swift:156` | `NSMenuItem(title: "Quit Waple")` — **한국어 UI 에 영어 항목**. 한글이 없어 오라클도 못 잡는다(역방향 결함). `NSLocalizedString("Waple 종료", …)` + en `Quit Waple` 로 |
| `AppDelegate.swift:1089` | `menuNeedsUpdate` 가 `pauseMenuItem?.title = … ? "재개" : "일시정지"` 로 **생 한국어를 덮어쓴다** — `:143` 에서 애써 `NSLocalizedString` 으로 만든 제목이 메뉴를 열 때마다 무효화된다 |
| `main.swift:18-24` | 편집 메뉴 6개가 `addItem(withTitle:)` 생 한국어. 이중 사각지대(§5.3) |

### 9.4 그 밖에

- **툴바 정렬 컨트롤의 어포던스**(§1.4) — Unit A.
- **`en.lproj` 죽은 키 5개**(§5.4) — 원인 3건은 `OnboardingView.row(title: String)`. Unit D 가
  파라미터를 `Text` 로 바꾸면 함께 낫는다. 나머지 2건은 Unit E 의 정규화에서 제거.
- **인스펙터의 "라이브러리에서 제거" 가 파괴적으로 보이지 않는다** — `Button(role: .destructive)`
  는 `bordered` 스타일 macOS 버튼에서 붉게 틴트되지 않는다(캡처 확인). 역할은 유지하되
  아이콘·확인 대화상자로 위험을 전달한다(현행 확인 대화상자는 이미 있다). Unit B.

---

## 부록 A — 토큰 적용 지도

토큰은 쓰이지 않으면 의미가 없다. 아래는 **현행 리터럴이 어느 토큰으로 바뀌어야 하는지**의
전수 목록이다. 단위별 완료 조건에 이 표의 자기 몫이 들어간다.

### A.1 `Space`

| 현행 | 토큰 | 위치(소유 단위) |
| --- | --- | --- |
| `Metrics.gap`(8) 직접 사용 12곳 | `Space.controlGap` | SettingsView·DisplaysView(D) · WorkshopTabView·DiscoverView(C) |
| `Metrics.gap * 1.5 / * 2 / * 3` | `Space.md` / `Space.lg` / `Space.sheetInset` | OnboardingView(D) — 곱셈으로 스케일을 만들지 마라 |
| `.padding(20)` 그리드·레일 5곳 | `Space.contentInset` | WallpaperGridView(B) · WorkshopTabView·DiscoverView(C) |
| `.padding(16)` 인스펙터 | `Space.panelInset` | SelectionPanelView(B) |
| `.padding(14)` 4곳 | `Space.panelInset`(16 으로 스냅) | DisplaysView(D) · NowPlayingBar 팝오버(A) |
| `.padding(.horizontal, 16)` 하단 바 | `Space.barInset` | NowPlayingBar(A) |
| `spacing: 6` 타일 스택 4곳 | `Space.xs` | WallpaperGridView(B) · RemoteTile(C) |
| `spacing: 3` / `spacing: 4` | `Space.xxs`(4 로 스냅) | SelectionPanelView(B) · OnboardingView(D) |
| `spacing: 10` / `12` / `14` | `Space.md` / `Space.md` / `Space.lg` | 전 단위 |
| `.padding(.horizontal, 2)` 캡션 3곳 | `Space.captionInset` | WallpaperGridView(B) · RemoteTile(C) |
| 배지 `.padding(.horizontal,7)/(.vertical,3)` 2곳 | `Space.badgeH` / `Space.badgeV` | S(컴포넌트로 흡수) |
| `Metrics.gridSpacing + 6` 2곳 | `Metrics.gridRowSpacing` | WallpaperGridView(B) · WorkshopTabView(C) |
| `padding: 28` 다이어그램 | `Metrics.diagramPadding` | DisplaysView(D) |

### A.2 `Typography`

| 현행 | 토큰 | 위치 |
| --- | --- | --- |
| `.title2.bold()` | `Typography.windowHeading` | OnboardingView(D) |
| `.title3.weight(.semibold)` ×3 | `sectionHeader`(레일·시트 헤더) / `itemTitle`(인스펙터 제목) | DiscoverView(C) · DisplaysView(D) · SelectionPanelView(B) |
| `.headline` ×2 | `subsectionHeader` | SelectionPanelView(B) · OnboardingView(D) |
| `.callout.weight(.medium)` | `bodyEmphasis` | NowPlayingBar(A) |
| `.callout` 설명문 ×3 | `secondaryBody` | OnboardingView(D) |
| `.caption` 타일 제목·메타 다수 | `caption` | 전 단위 |
| `.caption2` 배지 ×3 | `badge` | S · WallpaperGridView(B) · RemoteTile(C) |
| `String(format: "%.1f/5", …)` 평점 · 구독 수 · `%lld%%` 진행률 | **`metric`** | SelectionPanelView(B) · RemoteTile(C) |
| 슬라이더 값 `%.2f` · 전환 간격 `%lld분` | **`metricBody`** | PropertyEditorView(B) · NowPlayingBar(A) · SettingsView(D) |
| `.font(.system(size: 40/32))` 폴더·뒤로 글리프 | 삭제(폴더 타일이 사라진다) | WallpaperGridView(B) |

### A.3 `Motion`

| 현행 | 토큰 | 위치 |
| --- | --- | --- |
| `.animation(.spring(response:0.25, dampingFraction:0.8), value: hovered)` ×2 | `View.tileLift(_:)` 로 통째 교체 | WallpaperGridView(B) · RemoteTile(C) |
| `withAnimation(.spring(response:0.3, dampingFraction:0.85))` ×3 | `Motion.run(Motion.reveal)` | MainWindowView ×2(A) · WallpaperGridView(B) |
| `StatusBannerModel.transitionAnimation = .easeInOut(0.2)` | `Motion.fade` | StatusBanner(A) |
| `.transition(.move(edge:.top).combined(with:.opacity))` | `Motion.revealTransition(edge: .top)` | StatusBanner(A) |
| `.transition(.move(edge:.leading/.trailing))` ×2 | `Motion.revealTransition(edge:)` | MainWindowView(A) |
| `scaleEffect` + `shadow` 호버 ×2 | `View.tileLift(_:)` | WallpaperGridView(B) · RemoteTile(C) |

완료 확인: 각 단위의 소유 파일에서 `grep -n "\.spring(\|\.easeInOut(\|withAnimation(\." ` 가 비어야 한다.

### A.4 `ColorRole`

| 현행 | 토큰 | 위치 |
| --- | --- | --- |
| `Color(nsColor: .underPageBackgroundColor)` ×4 | `ColorRole.well` | WallpaperGridView(B) · DisplaysView(D) · WorkshopTabView·DiscoverView(C) |
| `Color(nsColor: .windowBackgroundColor)` | `ColorRole.panel` | SelectionPanelView(B) |
| `Color(nsColor: .separatorColor)` ×2 | `ColorRole.hairline` | StatusBanner(A) · DisplaysView(D) |
| `quaternaryLabelColor.opacity(0.15 / 0.25 / 0.3)` **7곳** | `ColorRole.placeholderFill`(0.25 통일) | B · C · D 전부 |
| `Color.accentColor` 링·글리프 | `ColorRole.selected` | B · C · D |
| `Color.secondary.opacity(0.6)` | `ColorRole.focusRing` | WallpaperGridView(B) · RemoteTile(C) |
| `.foregroundStyle(.orange)` ×2 | `ColorRole.warning` | WorkshopTabView·DiscoverView(C) |
| `.foregroundStyle(.yellow)` ×2 | `ColorRole.rating` | SelectionPanelView(B) · RemoteTile(C) |
| `Color.green` 체크 | `ColorRole.ready` | OnboardingView(D) |
| `.foregroundStyle(.red)` 상태 문구 | `ColorRole.destructive` | SettingsView(D) |
| `.saturation(0.4)` / `.opacity(0.55)` / `.opacity(0.4)` | `unsupportedSaturation` / `unsupportedOpacity` | WallpaperGridView(B) · DisplaysView(D) |
| `.foregroundStyle(.white)` / `.white.opacity(0.75)` 모니터 박스 라벨 | `ColorRole.onMedia` / `onMediaSecondary` | DisplaysView(D) |
| `LinearGradient(colors: [.clear, .black.opacity(0.72)], …)` | `ColorRole.mediaScrimOpacity`(투명도 줄이기 대응 포함) | DisplaysView(D) |
| `.foregroundStyle(.white, Color.accentColor)` 재생 글리프 | `ColorRole.onMedia` + `ColorRole.selected` | WallpaperGridView(B) |

### A.5 `Surface`

| 현행 | 토큰 | 위치 |
| --- | --- | --- |
| `cornerRadius: 6` ×3 | `Surface.thumbCorner` | NowPlayingBar(A) · DisplaysView(D) |
| (배지 `Capsule()` ×2 — 반경 없음) | 그대로 `Capsule()` | 캡슐은 높이에 따라 반경이 정해지므로 토큰이 필요 없다. 실태 조사의 "코너 4종" 은 이 캡슐을 포함해 센 것이고, 명시 반경은 `grep cornerRadius` 기준 **3종**(8·6·10)이다 |
| `Metrics.tileCorner` | `Surface.tileCorner`(별칭 유지) | B · C · D |
| `cornerRadius: 10` | `Surface.cardCorner` | SelectionPanelView(B) |
| `lineWidth: 2.5 / 1.5 / 1 / 3 / 4` | `strokeSelected` / `strokeFocus` / `strokeHairline` / `strokeEmphasis` / `strokeDropTarget` | B · C · D (또는 `S.tileRing`) |
| `shadow(…0.45, radius 9, y 5)` ×2 | `View.tileLift(_:)` | B · C |
| `.background(.bar)` ×2 | `Surface.chrome` | NowPlayingBar(A) · DisplaysView(D) |
| `.ultraThinMaterial` 배지 ×2 | `Surface.badge` | S 컴포넌트로 흡수 |
| `.regularMaterial` 배너 | `Surface.overlay` | StatusBanner(A) |

### A.6 `tileAccessibility`

붙어야 하는 커스텀 타일 **4종**: `WallpaperGridView.tile`(B) · `RemoteTileView`(C) ·
`DisplaysView.railTile`(D) · `DisplaysView.monitorBox`(D).
전부 현재 `onTapGesture` 로만 동작하고 접근성 속성이 하나도 없다.
