# 레인 9 — SwiftUI 셸 · 디자인 시스템 · 현지화 · 접근성

대상: `/Users/yakisoba0728/Documents/GitHub/Waple` @ `b883386e` (읽기 전용, 빌드 미실행)

## PR #8 이 이 레인에서 바꾼 것

```
git show --stat b883386e -- Sources/Waple/Shell Sources/Waple/Surfaces Sources/Waple/DesignSystem \
  Sources/Waple/PropertyEditorView.swift Sources/Waple/PropertyGrouping.swift \
  Sources/Waple/SelectionPanelView.swift Sources/Waple/WallpaperGridView.swift \
  Sources/Waple/AnimatedPreviewView.swift Resources/en.lproj/Localizable.strings \
  Tests/WapleAppTests/UIConventionTests.swift Tests/WapleAppTests/LocalizationCoverageTests.swift
→ Tests/WapleAppTests/UIConventionTests.swift | 386 ++++--  (1 file changed, 358 insertions, 28 deletions)
```

**담당 파일 중 PR #8 이 건드린 것은 `UIConventionTests.swift` 단 하나다.** 소스는 한 줄도 안 바뀌었다.
그래서 이 레인의 초점은 "PR #8 이 게이트를 실제로 고쳤는가" 다.

### 검증 수단 — 파서 파이썬 포트

`swift test` 금지 규약 때문에, PR #8 이 새로 심은 파서 4개
(`contextMenuItems` · `topLevelItems` · `itemChunk` · `accessibilityActionLabels` · `tapGestureSites`)를
**Swift 원문 그대로 파이썬으로 포트**해 실제 소스에 돌렸다.

- 포트: `/private/tmp/claude-501/-Users-yakisoba0728-Documents-GitHub/bcd06135-7c97-4b04-8714-361dcd4a2973/scratchpad/lane09/port.py`
- **충실도 근거**: 무변경 트리에서 포트의 출력이 초록 스위트와 일치한다 —
  `itemsChecked = 10` (`> 5` 통과), 짝 없는 항목 0건, `onTapGesture` 자리 4개 전부 준수 (`> 3` 통과).
- 그 위에 돌연변이를 **파일이 아니라 메모리에서** 주입해(작업 트리 무변경) 게이트 반응을 쟀다.

---

## 🟠 L9-1 — `testContextMenusHaveAccessibilityCounterpart` 는 **한 가지 표기만** 잡는다. `Button { … } label: { … }` 는 조용히 면제된다 (PR #8 "반만 고침")

- **자리**: `Tests/WapleAppTests/UIConventionTests.swift:145` (`guard !item.labels.isEmpty else { continue }`)
  · 파서 원인은 `:252-280` (`itemChunk`) · 면제되는 실물은
  `Sources/Waple/WallpaperGridView.swift:336-338` · `:365-367`
- **근거/재현**:

  ```
  python3 (port.py) 로 WallpaperGridView.swift 를 통과시킨 결과
  BASE                                items=9  labels-empty(=조용히 skip)=2  unmatched=0
  M-B  Button("폴더 삭제(항목은 유지)", role: .destructive) { … }   → unmatched=1  ← 빨강 (게이트 작동)
  M-A  Button(role: .destructive) { … } label: { Label("폴더 통째로 삭제", …) } → unmatched=0 ← 초록 (게이트 실패)
  M-A2 Button { … } label: { Text("폴더 통째로 삭제") }              → unmatched=0 ← 초록
  M-A3 Button("\(entry.title) 폴더 통째로 삭제", role: .destructive) { … } → unmatched=0 ← 초록
  M-A4 멀티라인 `} label: {` 형태                                    → unmatched=0 ← 초록
  ```

  원인은 `itemChunk`(`:252-280`)가 **첫 번째 짝 맞는 `}` 에서 항목을 끊는 것**이다.
  `Button { action } label: { … }` 에서 그 `}` 는 **액션 클로저**의 끝이라, `label:` 절이
  chunk 에 들어오지 않는다 → `labelRegion`(`:286-298`)이 `label:` 을 못 찾고 첫 괄호 그룹
  (`Button(role: .destructive)` → `"role: .destructive"`, 또는 `Button {` → 액션 본문의 괄호)만
  본다 → 문자열 리터럴 0개 → `:145` 의 `guard` 가 **아무 말 없이 건너뛴다**.
  보간 라벨(`\(…)`)도 같은 `guard` 에 걸린다 — `stringLiterals`(`:352-374`)가 보간 리터럴을 제외하기 때문.
- **왜 문제인가**: PR #8 의 주석(`:112-127`)은 종전 게이트가 "사실상 영구 면제"였다며
  **항목 단위 1:1** 로 좁혔다고 적고, 실측 재현으로 `Button("폴더 삭제(항목은 유지)", role: .destructive)`
  한 형태를 썼다. 그런데 **그 게이트가 지키려는 바로 그 메뉴 안에서 10개 중 2개가 여전히 면제 중**이고
  (`WallpaperGridView.swift:336` 재생목록 토글 · `:365` 즐겨찾기 토글), 면제되는 표기는 아이콘 라벨을 붙일 때 자연히 쓰는
  가장 흔한 SwiftUI 관용구다. 즉 파괴적 동작을 `label:` 형태로 새로 넣으면 §4.3 위반이
  초록으로 실린다 — 직전 감사가 "돌연변이 1건으로 살아 있음 확인" 이라 적은 그 자리다
  (그 1건은 `testAnimationsComeFromMotionTokens` 의 `.spring(` 이었고, 이 오라클이 아니다).
- **기지 목록 대조**: 해당 없음. 직전 감사 `AUDIT-FULL-2026-08-31.md:2113-2115` 는
  이 오라클을 "`.contextMenu` 항목마다 짝 액션을 요구" 로 **긍정 평가**했다 — 그 평가가 반만 맞다.

## 🟠 L9-2 — `testTapDrivenViewsDeclareAccessibility` 의 체인 판정이 **자식 뷰의 접근성 표현을 삼켜** 탭 뷰를 면제한다

- **자리**: `Tests/WapleAppTests/UIConventionTests.swift:470-471`
  (`let continuation = indent(next) > depth || next.trimmed.isEmpty`)
- **근거/재현**: `WallpaperGridView.thumbnail` 체인(`:198` 앞)에 접근성 없는 새 탭 컨트롤을 넣되,
  바로 아래 `.overlay { … }` 안에 **다른 뷰의** `.accessibilityLabel` 이 있게 배치:

  ```
  T1  .onTapGesture { viewModel.removeFromLibrary(entry) }
      .overlay(alignment: .topTrailing) {
          Text("!").accessibilityLabel(Text("유실"))      ← 이 배지의 라벨
      }
      → 새 자리(:198) hasAccessibility = True  ← 초록 (게이트 실패)
  T2  같은 자리, overlay 없이               → hasAccessibility = False ← 빨강 (게이트 작동)
  ```

  `continuation` 이 **더 깊은 들여쓰기 줄을 무조건 체인에 포함**하므로, 모디파이어의 트레일링
  클로저 **안쪽**(= 자식 뷰의 코드)이 통째로 체인 텍스트에 들어온다. 배지·오버레이의
  `accessibilityLabel` 이 탭 대상 뷰의 것으로 오인된다.
- **왜 문제인가**: 이 저장소의 타일은 전부 `.overlay { 배지 }` 를 여러 겹 쌓는 형태다
  (`WallpaperGridView.swift:198-200` 만 해도 3겹). 그 옆에 탭 제스처를 붙이는 순간 게이트가
  꺼진다 — 접근성 표현 없는 탭 뷰가 초록으로 실린다.
- **기지 목록 대조**: 해당 없음.

## 🟠 L9-3 — 영어 시스템에서 한국어로 뜨는 UI 문자열이 남아 있다 (`WebInputProxyView`), 그리고 "이 한 건뿐" 이라는 주석이 거짓이다

- **자리**: `Sources/WapleRender/WebInputProxyView.swift:80`
  ```swift
  override func draw(_ dirtyRect: NSRect) {
      …
      let s = "월페이퍼 미리보기 로딩 중…"
      (s as NSString).draw(at: NSPoint(x: 20, y: bounds.midY), withAttributes: attrs)
  ```
  거짓 주석: `Sources/WapleRender/WebRenderer.swift:233-237`
- **근거/재현**:
  ```
  grep -n "월페이퍼 미리보기" Resources/en.lproj/Localizable.strings   → 0건 (NOT IN en.lproj)
  ```
  `LocalizationCoverageTests.swift:41-53` 의 패턴 4개 어디에도 안 걸린다 —
  ① `NSLocalizedString(` 아님 ② SwiftUI 표시 API 목록에 없음(AppKit `NSString.draw`)
  ③ `label|title|withTitle|message|placeholder|tooltip` 인자 아님 ④ `.title=/.stringValue=/…` 대입 아님.
  그래서 누락·고아 양방향 차집합 어느 쪽에도 안 잡히고 스위트는 초록이다.
- **왜 문제인가**: 이 문자열은 `WebRenderer.swift:238` 이 여는 **바로 그 조작 창의 콘텐츠 뷰**가
  스냅샷 도착 전에 그리는 문구다. 영어 시스템 사용자는 창 제목만 영어고 안쪽은 한국어를 본다.
  `AGENTS.md:68` 이 "AppKit 경로는 자동 해석이 없다 — `NSLocalizedString` 으로 감쌀 것" 을
  규약으로 못박은 바로 그 부류다.
  더 나쁜 것은 **주석의 거짓**이다 — `WebRenderer.swift:236-237` 은
  *"실측 결과 `Sources/Waple` 밖의 한국어 UI 리터럴은 **이 한 건뿐**이라 넓혀도 소음이 없다"* 라고
  단정한다. 그 "실측" 은 **구멍이 있는 그 패턴 자체로 잰 것**이라 자기확인이고, 결과는 틀렸다 —
  같은 기능, 같은 창, 바로 옆 파일에 두 번째 건이 있다.
- **정밀도 주의**: `AUDIT-FULL-2026-08-31.md:2074` 의 "AppKit 경로(`NSMenuItem(title:)`·`window.title`)의
  미현지화 한국어 **0건**" 행은 그 두 API 로 **스코프가 한정**돼 있어 문자 그대로는 참이다.
  거짓인 것은 `WebRenderer.swift:236-237` 주석 쪽이다.
- **기지 목록 대조**: 해당 없음. `Sources/WapleSaver`(.m) 1건은 기지(리포가 스스로 기록)이며 별건이다.

## 🟠 L9-4 — 키보드 전용 사용자는 인스펙터에 **도달할 수 없다** (`focusedId` 를 마우스만 쓴다)

- **자리**: `Sources/Waple/WallpaperGridView.swift:182` (`focusedId` 를 쓰는 유일한 뷰 경로)
  · `Sources/Waple/DesignSystem/TileAccessibility.swift:81-82` (`.focusable` + `onKeyPress(.return)`)
- **근거/재현**:
  ```
  grep -rn "focusedId" --include="*.swift" Sources/Waple | grep -v DesignSystem
  → LibraryViewModel.swift:55(선언) :92 :229(selectForPropertiesView) :260
    WallpaperGridView.swift:164(읽기) :182(.onTapGesture 로 쓰기)
    AppDelegate.swift:368(초기 1회)
  ```
  즉 `focusedId` 에 값을 넣는 **뷰 경로는 마우스 탭 하나**와,
  `selectForPropertiesView` 를 부르는 두 자리 — 우클릭 메뉴 `Button("선택(속성 보기)")`(`WallpaperGridView.swift:327`)와
  `accessibilityAction(named: Text("선택(속성 보기)"))`(`:441`, `sharedActions :439-445`) — 뿐이다.
  `tileAccessibility` 의 `.focusable(true)` 가 주는 SwiftUI 포커스는 `focusedId` 를 건드리지 않고,
  `onKeyPress(.return)` 는 `onActivate` = **적용**(`WallpaperGridView.swift:186`)이지 선택이 아니다.
- **왜 문제인가**: `SelectionPanelView.swift:35` 은 `viewModel.focusedEntry` 로만 내용을 정한다.
  따라서 **표준 키보드 탐색(Tab)만** 쓰는 사용자는(VoiceOver 로터도, 우클릭도 없이)
  **속성 편집기·모니터별 할당·폴더 이동·재생목록·즐겨찾기·제거·조작 창 열기** 전부에 닿을 수 없고,
  타일에서 Return 을 치면 (선택이 아니라) 배경이 곧바로 적용된다.
  `UIConventionTests.swift:108-109` 는 이 규약의 목적을 *"VoiceOver 사용자와 **키보드 전용
  사용자**에게 그 안의 항목은 존재하지 않는 것과 같다"* 로 적지만, 처방인
  `accessibilityAction(named:)` 은 **VoiceOver 로터 전용**이라 후자를 메우지 못한다.
  (macOS 의 옵트인 "전체 키보드 접근" 이 별도 경로를 줄 여지는 실기 확인 몫이지만,
  아래 세 사실은 소스만으로 확정된다: ① `focusedId` 쓰기는 마우스 탭·우클릭·로터뿐
  ② Return 은 선택이 아니라 적용 ③ 포커스 링이 키보드 포커스로는 켜지지 않는다.)
  게이트는 초록이다 — `tileAccessibility` **존재**만 보고 포커스가 선택을 구동하는지는 안 보기 때문.
- **부수 증상(같은 뿌리)**: `ColorRole.swift:41` 은 *"키보드 포커스는 중성 링이다"* 라고 규약을 적는데,
  그 링을 켜는 값은 `WallpaperGridView.swift:164` 의 `viewModel.focusedId == entry.id` —
  **마우스 클릭 상태**다. 키보드 포커스로는 이 저장소가 정의한 포커스 링이 뜨지 않는다.
- **잔여 마우스 전용 기능(오늘 기준)**: 우클릭 항목 중 인스펙터에 짝이 없는 것은
  **`Finder에서 보기` 1건**뿐이다(`WallpaperGridView.swift:368` · 접근성 액션 `:443`; `SelectionPanelView` 에 `revealInFinder` 참조 0건).
  2026-08-17 실측의 "11 중 5" 는 인스펙터 컨트롤(`SelectionPanelView.swift:161-177`,
  `monitorMenu :198` · `playlistButton :222` · `folderMenu :247` · `favoriteButton :121`)로 해소돼 있다.
- **기지 목록 대조**: 해당 없음.

## 🟡 L9-5 — 모션 게이트의 정규식이 **`.easeOut(`·`withAnimation {`·생 `.transition(`** 을 못 본다

- **자리**: `Tests/WapleAppTests/UIConventionTests.swift:93-95`
  (`text.contains(".spring(") || ".easeInOut(" || ".linear(" || "withAnimation(."`)
  · 살아 있는 증거 `Sources/Waple/SelectionPanelView.swift:308` (`.transition(.opacity)`)
- **근거/재현**:
  ```
  grep -rn "\.transition(" --include="*.swift" Sources/Waple | grep -v DesignSystem
  → WallpaperGridView.swift:111  .transition(Motion.revealTransition(edge: .bottom))   (토큰)
    Shell/StatusBanner.swift:75   .transition(Motion.revealTransition(edge: .top))      (토큰)
    SelectionPanelView.swift:308  .transition(.opacity)                                  ← 생 트랜지션
  ```
  네 항 어디에도 `.easeOut(` · `.easeIn(` · `.bouncy` · `.smooth` · `.snappy` ·
  `.interpolatingSpring(` · `.timingCurve(` · `withAnimation {`(점 없는 트레일링 클로저 형태) ·
  `.transition(` 가 없다.
- **왜 문제인가**: `Motion.swift:63-70` 은 *"`.transition` 은 애니메이션과 별개다 … 그래서
  트랜지션 자체도 여기서 만든다"* 라고 규약을 적지만, 게이트에는 트랜지션 항이 아예 없다.
  `.transition(.move(edge:))` 나 `.animation(.easeOut(…))` 을 새로 쓰면 그 자리만
  `reduceMotion` 을 무시한 채 초록으로 지나간다.
  **`:308` 자체는 기능상 무해하다** — `.opacity` 는 감소 모드에서 `revealTransition` 이
  내놓는 것과 같은 형태다. 규약 이탈이자 게이트 구멍의 증거일 뿐, 접근성 결함은 아니다.
- **기지 목록 대조**: 해당 없음.

## 🟡 L9-6 — 모집단 하한 가드 `sitesChecked > 3` 이 실제 4 라 여유가 0 이다 (올바른 리팩터가 빨개진다)

- **자리**: `Tests/WapleAppTests/UIConventionTests.swift:408-409`
- **근거/재현**:
  ```
  grep -rn "onTapGesture" --include="*.swift" Sources/Waple | grep -v DesignSystem | wc -l → 4
  (WallpaperGridView.swift:181,:182 · Surfaces/Displays/DisplaysView.swift:124,:252)
  포트로 확인: 4자리 전부 준수, 하한은 > 3 → 여유 0
  ```
  포트에 T4(탭 자리 1개 제거)를 주입하면 저장소 전체가 3자리 → `XCTAssertGreaterThan(3, 3)` 실패.
- **왜 문제인가**: 타일 하나를 `.onTapGesture` 대신 표준 `Button` 으로 옮기는 것은 이 규약이
  **권장하는 방향**인데, 그렇게 하면 게이트가 *"onTapGesture 자리를 3개만 찾았다 — 스캔이 깨졌다"*
  라는 **틀린 진단 문구**로 빨개진다. 다음 사람은 규약을 지킨 자기 변경을 되돌리거나
  하한을 낮추게 되고, 하한을 낮추면 가드가 무의미해진다.
  (같은 구조인 `itemsChecked > 5` 는 실제 10 이라 여유가 있다.)
- **기지 목록 대조**: 해당 없음.

## 🟡 L9-7 — `SystemPreference` 가 스스로 적은 소비자 목록에 `Surface` 가 있는데 `Surface.swift` 는 한 번도 읽지 않는다

- **자리**: `Sources/Waple/DesignSystem/SystemPreference.swift:8-9`
  (*"토큰(`Motion`·`ColorRole`·`Surface`)이 여기를 읽고, 화면은 토큰만 쓴다"*)
- **근거/재현**:
  ```
  grep -rn "SystemPreference\." --include="*.swift" Sources/
  → DesignSystem/Motion.swift:24      (reduceMotion)
    DesignSystem/ColorRole.swift:116  (reduceTransparency)
  ```
  `Surface.swift` 전문에 `SystemPreference` 참조 0건. 재질 3종
  (`Surface.swift:53` `chrome:.bar` · `:55` `badge:.ultraThinMaterial` · `:57` `overlay:.regularMaterial`)에
  `reduceTransparency` 분기가 없다. 또 `differentiateWithoutColor`(`:31`)·`increaseContrast`(`:37`)는
  전 저장소 소비처 0건이다(선언부 주석이 "추가 보강용"·"보통 읽을 일이 없다" 라 의도된 것으로 읽힌다).
- **왜 문제인가**: 규약 문서가 소비자로 지목한 토큰이 실제로는 소비하지 않는다.
  시스템 `Material` 이 대체로 스스로 반응하므로 실동작 위험은 낮지만,
  "빠뜨림이 구조적으로 불가능해진다" 는 이 파일의 주장이 `Surface` 에 대해서는 성립하지 않는다.
- **기지 목록 대조**: 해당 없음.

## 🟡 L9-8 — combo `Picker` 에 무선택 방어가 없다 (오버라이드가 옵션 집합을 벗어나면 빈 팝업)

- **자리**: `Sources/Waple/PropertyEditorView.swift:236-245` (`case .picker`)
- **근거/재현**: `LibraryViewModel.swift:499-520` → `WallpaperProperties.applying(overrides:to:)`
  (`Sources/WapleCore/WallpaperProperties.swift:244-252`)은 **타입 강제 없이 값을 그대로 덮어쓴다**:
  ```swift
  guard let o = overrides[p.key] else { return p }
  var out = p
  out.value = o          // ← options 와의 정합을 확인하지 않는다
  ```
  `PropertyEditorView` 는 `selection: Binding<PropertyValue>` 와 `.tag(opt.value)` 를 짝짓기만 하고
  **매칭 실패 시 폴백이 없다**. 도달 경로(코퍼스 불필요):
  ① 사용자가 combo 값을 골라 `UserDefaults` 에 저장 → ② 워크샵 재다운로드 등으로 그 옵션이
  `project.json` 에서 사라짐 → ③ `applying` 이 사라진 값을 되돌려 넣음 → 태그와 매칭 0 →
  화면에 빈 팝업 버튼. 값이 무엇인지 볼 수도, 그 컨트롤만 되돌릴 수도 없다(전체 "초기화" 뿐).
  같은 증상이 `parseValue` 의 `default` 분기(`WallpaperProperties.swift:198-205`)에서도 난다 —
  `"value"` 키가 없는 combo 는 `.none` 이 되는데 `.none` 태그를 가진 옵션은 없다.
- **왜 문제인가**: `parseValue` 의 주석(`WallpaperProperties.swift:199-202`)이 *"combo 기본값/option tag가 .bool로 오타입되면
  … SwiftUI Picker가 무선택 상태가 된다"* 라고 이 실패를 이미 알고 있으면서, 파스 시점의
  bool/number 혼동만 막았다. **UI 측에는 방어가 한 줄도 없다** — 무선택이 실제로 일어났을 때
  화면이 그것을 알리거나 복구시키는 경로가 없다.
- **기지 목록 대조**: 기지 M3(`JSON 0/1 → bool 오타입`)의 **UI 측 잔여**다. M3 은 파스 타입,
  이건 그 뒤 화면의 무방어를 가리킨다.
- **의심(미확인)**: 실물 `project.json` 에 `"value": 0` + `options[].value: "0"` 처럼
  **같은 combo 안에서 JSON 타입이 갈리는** 패키지가 실제로 있는지는 코퍼스 부재로 재지 못했다.
  구조상 가능하다(둘 다 `parseValue(_, type:"combo")` 의 `default` 분기를 타고 원 JSON 타입을 보존한다).

## ⚪ L9-9 — `topLevelItems` 의 주석이 구현과 어긋난다 (`ForEach` 자식)

- **자리**: `Tests/WapleAppTests/UIConventionTests.swift:227-229`
- **근거/재현**: 주석은 *"중첩 `{ … }`(= `Menu` 의 자식, **`ForEach` 본문**, `label:` 클로저)은
  건너뛴다"* 라고 적지만, `topLevelItems`(`:230-249`)는 `Button`/`Menu` 키워드에서만
  `itemChunk` 로 건너뛴다. `ForEach` 는 키워드가 아니므로 스캐너가 그 클로저 안으로 들어가
  **자식 `Button` 을 최상위 항목으로 센다**. 현행 코드에서는 두 `ForEach` 가 모두 `Menu` 안에
  있어(`WallpaperGridView.swift:342` · `:351`) `Menu` 의 chunk 에 삼켜지므로 증상이 안 난다.
- **왜 문제인가**: 실동작 영향 없음(더 세는 방향 = 더 엄격). 다음 사람이 `.contextMenu` 최상위에
  `ForEach` 를 놓으면 주석이 약속한 것과 다르게 동작한다는 정본 오차일 뿐이다.
- **기지 목록 대조**: 해당 없음.

---

## 확인했지만 문제없던 것

1. **문자열 보간이 든 `Text()` 는 0건**. `grep -rnE 'Text\("[^"]*\\\(' Sources/` → 0.
   패턴이 보간 리터럴을 키로 뽑아 "번역된 척" 하는 경로는 현재 살아 있지 않다.
   값이 끼는 문구는 전부 `String(format: NSLocalizedString("… %@ …"), x)` 로 명시돼 있다(AGENTS.md:69 준수).
2. **`en.lproj` 285항목의 포맷 지정자 정합 — 어긋남 0건**. 파이썬 전수 대조에서 나온 3건
   ("30/50/80% 이상 가려지면")은 `% i`(공백 플래그+`i`) 오탐이고, 그 셋은 `AppLogic.swift:625-627` 의
   Picker 라벨이라 `String(format:)` 을 통과하지 않는다. 위치 지정자 재배열(`%2$lld of %1$lld`)도 정상.
3. **`ko.lproj` 는 비어 있고**(`testKoreanCatalogStaysEmpty`), `NSMenuItem(title:)`·`NSMenu(title:)`·
   `NSOpenPanel.prompt/message`·`window.title` 은 전부 `NSLocalizedString` 으로 감싸져 있다
   (`main.swift:30-42` · `AppDelegate.swift:229-253,428-431` · `WallpaperGridView.swift:481` ·
   `WebRenderer.swift:238`). `NSAlert`·`messageText`·`informativeText` 는 저장소에 사용처가 0건이다.
4. **combo 태그/선택 타입은 파스 시점에는 일관**하다 — `WallpaperProperties.parse`(`:160-161` 옵션 · `:166` 값)가
   속성 값과 옵션 값에 **같은 `type`** 으로 `parseValue` 를 쓰고, `UserPropertyStore.set/overrides`
   (`Sources/WapleRender/UserPropertyStore.swift:38-50` · `:61-70`)의 왕복도 CFBoolean 판별로
   `.bool`/`.number` 를 보존한다. 남는 위험은 L9-8 의 **오버라이드/옵션 집합 불일치**뿐이다.
5. **`PropertyEditorView` 의 유실 경로는 닫혀 있다**. `SelectionPanelView.swift:55` 의 `.id(entry.id)`
   가 엔트리 전환 때 재마운트 → `onDisappear → commitPending()`(`PropertyEditorView.swift:107` · `:161-165`)이 텍스트·슬라이더·
   컬러 세 dirty 집합을 전부 영속화하고, 인스펙터 접힘도 `onChange(of: viewModel.panelVisible)`
   (`PropertyEditorView.swift:106`)로 커밋 트리거에 포함된다. `reload()`(`PropertyEditorView.swift:151-158`)가 dirty 를 커밋 없이 비우는 것은
   "초기화를 무르지 않는다" 는 의도이며 주석과 일치한다.
6. **두 게이트 다 평범한 표기에는 실제로 작동한다** — 포트 실험 T2(접근성 없는 순수 신규
   `onTapGesture`)와 M-B(`Button("리터럴", role:)`)는 둘 다 빨개진다. PR #8 이 주장한 수정은
   **거짓이 아니라 불완전**하다.
7. **`darkAqua` 강제 제거는 실제로 이뤄졌다** — `grep -rn "darkAqua" Sources/` 는 주석 5건뿐이고
   `window.appearance = …` 대입은 0건이다. `ColorRole` 의 hex/RGB 리터럴 0건도 **직접 확인**했다
   (`grep -nE '0x|#[0-9a-fA-F]{3}|Color\(red|NSColor\(red|calibrated|srgb' Sources/Waple/DesignSystem/ColorRole.swift` → 0건).
   즉 파일 머리말의 자기주장("이 파일에 hex 는 한 개도 없다")이 실제로 성립한다.
8. **`.gesture(TapGesture())` 계열은 저장소에 0건**이다(L9-2 의 전방 구멍으로만 존재).
   `.onLongPressGesture`·`.simultaneousGesture`·`.highPriorityGesture` 도 0건.
