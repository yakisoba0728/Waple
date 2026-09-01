# 레인 8 — 앱 계층 · 재생정책 배선 (감사 r2, HEAD=`b883386e`)

대상: `/Users/yakisoba0728/Documents/GitHub/Waple` · 읽기 전용 · 빌드/테스트 미실행.
초점: PR #8 이 `AppDelegate.swift`(±356) · `PlaylistDriver.swift`(±126) · `LibraryViewModel.swift`(±55) ·
`PlaybackPolicyComposition.swift`(±47) · `AppLogic.swift`(±36) 에 심은 **새 결함**.

PR #8 이 이 레인에서 한 일 요약(재현: `git show b883386e -- Sources/Waple/AppDelegate.swift`):
동기 `apply(folderURL:) -> Bool` 을 **3상태 비동기**(`WallpaperApplyDisposition{applied,pending,failed}` +
`WallpaperApplyResolution{applied,failed,cancelled}`)로 바꾸고, ffmpeg 선변환을 RendererSwap **앞**으로
당겼으며(`VideoPreparationBatch`), 재생정책 `monitorIndex` 를 배열 위치 대신 **화면 키 역탐색**으로 바꿨다.
앞 둘은 실제로 결함을 고쳤다(비디오 mount 중 기존 렌더러 선-teardown, pending 을 Bool true 로 접던 문제).
셋째도 순수층은 타입으로 막았다. 아래는 그 과정에서 **새로 생긴 것**들이다.

---

### 🟡 F1 — `.cancelled`(정상적인 세대 교체)를 실패로 읽는다 — **오늘은 무해하지만 F035/F036 불변식이 계약에서 빠졌다** (PR #8 신규)

- 자리: `Sources/Waple/AppDelegate.swift:883-887`(`performScreensChanged`) ·
  `:896-903`(`cleanupAfterFailedScreenRebuild`) · `:572-578`(`cancelPendingRendererApply`) ·
  `:667`(`applyResolved` 진입부) · `:754`(`RendererSwap.apply(existing: renderers)`)
- 근거/재현(정적 호출 사슬 — 순서대로 읽으면 그대로 성립한다):
  1. `performScreensChanged:883` 이 `applyCurrentSelection { resolution in guard resolution != .applied else { return }; cleanupAfterFailedScreenRebuild() }` 를 건다.
     비디오(mkv/webm)가 걸려 있으면 `applyResolved:702-747` 이 `.pending` 을 돌려주고
     `pendingRendererApplyCompletion = completion`(`:705`)으로 이 클로저를 붙잡는다.
  2. 그 사이 **아무 apply 나** 새로 들어오면 `applyResolved:667` 이 `cancelPendingRendererApply()` 를 부른다.
     진입점은 셋이다 — ① 사용자가 라이브러리에서 배경을 클릭(`libraryVM.apply:438` → `requestApply:589`),
     ② 1초 재생목록 틱(`tickPlaylist:1019`; 이때 `hasPendingAdvance` 가드(`:1029`)는 **AppDelegate 쪽 pending 을
     보지 않으므로** 막지 못한다), ③ 0.5초 디바운스 뒤 두 번째 `performScreensChanged`.
  3. `cancelPendingRendererApply:577` 이 옛 completion 을 **동기로** `completion?(.cancelled)` 호출.
  4. `:884` 의 `guard resolution != .applied` 는 `.cancelled` 를 통과시켜 `cleanupAfterFailedScreenRebuild()`
     → `renderers.forEach { $0.teardown() }; renderers = []`(`:897-898`).
  5. 스택은 아직 `applyResolved` 안이다. 실행이 `:670` 이후로 돌아와 `:754` 에서 `existing: renderers` 를
     읽는데 **그 값이 방금 `[]` 가 됐다.**
- **오늘의 실동작 영향은 없다 — 이 검증 자체가 이 항목의 값이다.** `cleanupAfterFailedScreenRebuild` 의
  유일한 호출 경로는 `performScreensChanged` 이고, 거기 도달했다는 것은 `:875` 의
  `desktopController.rebuild()` 가 **이미 옛 창을 전부 놓았다**는 뜻이다(`:876-882` 가 그 렌더러들을
  "이미 사라진 창에 마운트된" 좀비라고 적는다). rebuild 와 pending 등록 사이에 다른 코드가 끼어들 수 없고
  (같은 동기 메인 프레임), 어떤 후행 apply 든 `:667` 에서 **자기 swap(`:754`) 전에** 취소하므로 새 렌더러가
  먼저 마운트되는 순서도 없다. 즉 teardown 대상은 항상 좀비이거나 `[]` 이고, 바탕화면은 이 결함과 무관하게
  이미 비어 있다. `RendererSwap.apply`(`AppLogic.swift:142-173`)는 `existing` 을 **재사용하지 않고**
  롤백 보존만 하므로 "재사용을 잃는다" 도 성립하지 않는다.
- 그럼에도 문제인 것 셋:
  (a) **타입 독스트링과 소비자가 어긋난다.** `WallpaperApplyResolution.cancelled`(`LibraryViewModel.swift:24-25`)
      는 cancelled = "더 최신 적용 요청이 세대를 교체한 경우 … 실패 후보를 계속 순회하면 안 된다" 인데
      `:884` 만 그것을 실패로 읽는다. 다른 두 소비자(`applyCurrentSelection:619`, `PlaylistDriver:242`)는
      독스트링대로 `.failed` 와 구분한다 — 셋 중 하나만 다르다.
  (b) **`:880-882` 가 스스로 정한 조건을 위반한다.** 그 주석은 "실패가 **확정된** 이 시점에만 정리하고
      다음 적용에 맡긴다" 인데, `.cancelled` 는 실패 확정이 아니라 진행 중인 다른 적용의 존재다.
  (c) **재진입 지뢰.** `cancelPendingRendererApply:577` 이 살아있는 `applyResolved` 프레임 **안에서**
      completion 을 동기 호출하고, 그 completion 이 `renderers`(`:754` 가 곧 읽을 값)를 자유롭게 바꿀 수
      있다. 오늘은 소비자가 하나뿐이라 무해하지만, `.cancelled` 를 정리 신호로 읽는 소비자가 **살아있는**
      렌더러를 들고 있는 순간 F035/F036(롤백 보존)이 그대로 무력화된다. 그 계약은 지금 코드 어디에도
      적혀 있지 않다.
- 기지 목록 대조: 해당 없음(PR #8 이 도입한 `.cancelled` 자체가 신규). F035/F036/F487 의 **재발은 아니다** —
  그 경로는 여전히 지켜진다.
- 전제조건: ffmpeg 선변환이 필요한 소스가 화면 세트에 있고, 그 pending 중 다른 apply 가 들어와야 한다.

---

### 🟠 F2 — 부 화면 재생목록 전진이 **스테일한 전역 선택** 때문에 후보 전부를 태우고, 매 틱 반복한다 (PR #8 신규)

- 자리: `Sources/Waple/AppDelegate.swift:997-1009`(`requestStagedSecondarySelection`, 특히 `:1002-1003`) ·
  `Sources/Waple/PlaylistDriver.swift:213-219`(`continueAdvance` 의 동기 `.failed` 재귀)
- 근거/재현:
  - `git show b883386e -- Sources/Waple/AppDelegate.swift` 의 `tickPlaylist` 훅 — **종전** 부 화면 경로는
    후보만 검사했다: `playlistDriver.advance(screenKey: key) { id in ... store.resolveFolderURL(for: entry) != nil }`.
    실패해도 `applyCurrentSelection()`(전역 실패 시 `global: nil` 폴백 있음)로 이어졌다.
  - **현재** 경로는 `requestSecondaryPlaylistCandidate:963` → `requestStagedSecondarySelection:997` 이고,
    거기서 `:1002-1003` 이 **후보와 무관하게** `currentFolderURL` 의 전역 프로젝트를 먼저 요구한다:
    `guard let resolved = projectForMount(folderURL: folder), RendererFactory.makeRenderer(for: resolved) != nil else { return .failed }`.
  - `currentFolderURL` 이 스테일하면(폴더 외부 삭제/이동 — `applyCurrentSelection:625-630` 의 F482 가
    존재를 인정하는 상태) 이 가드가 **모든 후보에 대해 똑같이** 실패한다.
  - `PlaylistDriver.continueAdvance:213-218` 은 동기 `.failed` 를 받으면 후보를 하나 더 뽑아 재귀한다.
    `PlaylistRuntime.drawByOrder`(`Sources/WapleCore/PlaylistRuntime.swift:98-100`)의 독스트링대로
    셔플백/커서는 **뽑는 순간 소모된다**. 즉 한 틱에 `entryIds.count` 번 소모하고 `.exhausted` 로 끝난다.
  - 성공 커밋이 없으므로 `runtime.commit`(경과시간 0)이 안 돌고, `PlaylistRuntime.tick:317-333` 은 그
    화면을 **다음 1초 틱에도 다시 due** 로 낸다 → 위 소모가 매초 반복.
- 왜 문제인가: 매초 (엔트리 수)회의 북마크 해석 + 스테일 `project.json` 파스 시도가 메인 스레드에서 돌고,
  셔플 순서가 조용히 뒤섞이며, 사용자에게는 **아무 메시지도 뜨지 않는다**(`:1003` 은 notify/markApplyResult
  를 거치지 않는다). 종전 경로는 이 조건에서 `applyCurrentSelection` 의 `global: nil` 폴백으로 회복했다.
- 기지 목록 대조: 해당 없음.
- 전제조건: 재생목록이 굴리는 화면이 2개 이상(`playlistScreenKeys()` 결과 길이 ≥2)이고, 부 화면이
  주 화면보다 먼저 due 이며, `currentFolderURL` 이 스테일. 주 화면이 한 번 성공하면 `currentFolderURL`
  이 갱신되어 해소된다 — 그래서 지속시간은 최대 한 간격이다.

---

### 🟡 F3 — PR #8 이 BACKLOG 의 낡은 항목을 지우면서 **또 다른 낡은 항목을 새로 써 넣었다**

- 자리: `BACKLOG.md:23`(제품화 요약 표) · `BACKLOG.md:461`(제품화 §1) · `BACKLOG.md:649`
- 근거/재현:
  - `git show b883386e -- BACKLOG.md` → `-| [제품화] | 배포 결심 | Developer ID 공증 · 접근성 · 현지화(하드코딩 한국어 40+) |`
    `+| [제품화] | 배포 결심 | Developer ID 공증 · **창 닫힘 오류 알림** · WapleSaver 안내문 현지화 |`
    (기지 M6 "제품화 표 2항목 이미 해소" 에 대한 수정이다.)
  - 그런데 새로 넣은 "창 닫힘 오류 알림" 의 근거 문장 `BACKLOG.md:461` 은 **PR #8 이 손대지 않았고**
    지금도 이렇게 적혀 있다: *"잔여: 창 닫힘 상태의 오류는 **여전히 NSLog only** → UNUserNotification 승격은 배포 결심 시"*.
  - 코드는 그 문장을 반증한다(전부 `git log -S pendingNotice -- Sources/Waple/AppDelegate.swift` = `391fd472`,
    **PR #8 이전**):
    `AppDelegate.swift:1580-1583`(창 닫힘 → `pendingNotice` 저장 + `refreshStatusIcon()`) ·
    `:1250`(상태바 툴팁에 덧붙임) · `:1896-1897`(트레이 메뉴에 항목으로 노출) ·
    `:491-495`(창이 열리는 순간 배너로 승격).
- 왜 문제인가: 배포 게이트 표가 이미 해소된 항목을 미해소로 세고 있다. 실제 잔여는 "UNUserNotification
  으로의 능동 알림 승격" 하나이고, 표의 문구("창 닫힘 오류 알림")는 그것을 가리키지 않는다.
  이 리포가 가장 싫어하는 부류 — **정본이 코드와 어긋난 것**이고, 게다가 정본 수정 커밋 자신이 만들었다.
- 기지 목록 대조: M6 의 **후속**이지 재보고가 아니다(M6 이 지적한 두 항목은 실제로 지워졌다).
  `BACKLOG.md:462` 의 "잔여: 메인창 닫힘 상태의 base-assets NSLog-only 안내뿐" 도 같은 이유로 거짓이다
  (`BaseAssetsWarningGate.presentIfNeeded` → `present:` = `AppDelegate.notify`(`:802-812`) → 위 경로 그대로).

---

### 🟡 F4 — "타입으로 막았다" 는 `monitorIndex` 가 **키 충돌 폴백에서는 여전히 붕괴**한다

- 자리: `Sources/Waple/AppDelegate.swift:1142-1144` (`uniquingKeysWith: { first, _ in first }`) ·
  대조군 `:1347-1354`(같은 파일이 이미 이 위험을 적어 둔 자리) ·
  키 생성기 `Sources/WapleRender/DesktopWindow.swift:9-14`
- 근거/재현: `DesktopWindow.screenKey(for:)` 는 `NSScreenNumber` 가 없을 때 `"name-\(localizedName)"`
  으로 떨어진다. `AppDelegate.swift:1347-1352` 가 **같은 파일에서** "같은 모델 모니터 두 대는
  localizedName 이 같다 … 2026-08-19 스윕 §부록 ④ 의 unverified 항목" 이라고 적고 `uniqueKeysWithValues`
  트랩을 `uniquingKeysWith: { _, later in later }` 로 바꿔 뒀다.
  새로 들어온 `:1142` 의 역탐색 맵은 같은 충돌에서 두 화면을 **한 인덱스로 접는다**(그리고 `first` 를
  택해 `:1353` 의 `later` 와 규약도 어긋난다). 그러면 `rendererProjects` 의 두 렌더러가 같은
  `monitorIndex` 를 받아 **한 화면의 pause 결정을 다른 화면이 그대로 받는다** — PR #8 이 고쳤다고
  주장하는 스큐와 정확히 같은 증상이다.
- 왜 문제인가: `PlaybackPolicyComposition.swift:123-128` 이 "이제는 관례가 아니라 타입이 강제한다" 고
  적었는데, 강제되는 것은 "호출자가 인덱스를 준다" 까지이고 **그 인덱스가 옳다는 것은 아니다.**
  주석이 실제보다 강하게 말하고 있다.
- 기지 목록 대조: 해당 없음(`:1347` 의 기록은 다른 함수 `stillCaptureInputs` 에 대한 것이다).
- 등급 근거: 트리거(`NSScreenNumber` 부재 + 동일 모델 2대)는 이 컨테이너에서 확인할 수 없다 —
  코드 경로는 명확하고 방아쇠는 미검증. 리포의 `:1351` 이 같은 정직함으로 적어 둔 상태와 동급으로 둔다.

---

### ⚪ F5 — 관찰 4건 (전부 확인됨, 실동작 손상은 없거나 미미)

1. **수동 "다음 배경" 이 pending 중에는 조용히 죽는다.**
   `PlaylistDriver.swift:167` `guard pendingAdvance == nil else { return .pending }` — completion 을 등록하지
   않고 `.pending` 을 반환한다(계약상 `.pending` 은 "나중에 정확히 한 번 부른다" 인데 여기서는 아무도 안 부른다).
   호출부 `AppDelegate.swift:1056`(`advancePlaylist`, 하단 바 forward·트레이 "다음 배경")는 반환을 버린다.
   → ffmpeg 변환 중(최대 300초, `FFmpegConverter.swift:120` 의 기본 timeout) 버튼이 무반응이고 notify 도 없다.
   `tickPlaylist:1029` 만 `hasPendingAdvance` 를 미리 보고 빠진다.
2. **오류 가시성 — notify 를 타지 않는 실패 경로 4곳**(전부 PR #8 이전부터 있던 성질이지만 새 코드에도 그대로다):
   `AppDelegate.swift:641-644`(`requestAssignedSelection` 의 마운트 가능 할당 0건) ·
   `:959`(재생목록 후보의 엔트리 부재) · `:968-969`(후보 폴더 해석 실패) · `:1002-1003`(F2 의 그 가드).
   앞 셋은 "후보 건너뛰기" 라 침묵이 설계지만, `:641` 과 `:1003` 은 `markApplyResult(success:)` 도 거치지
   않아 상태바 오류 글리프(`refreshStatusIcon`)에도 안 잡힌다.
3. **`SteamCmdDownloader` 의 argv 경화가 두 자리 중 한 자리에만 걸려 있다.**
   `SteamCmdDownloader.swift:123-133` 이 "steamcmd 는 `+` 로 시작하는 argv 를 새 명령으로 읽는다" 를
   근거로 `itemId` 를 숫자로 확정하는데, 같은 `arguments()`(`:52-54`)의 `username` 은 `:139` 의
   공백 제거 후 비어있지 않은지만 본다. 사용자 자신이 입력하는 값이라 신뢰경계는 아니지만,
   `+` 로 시작하는 username 은 `+login` 뒤에서 명령으로 읽혀 그 뒤 argv 정렬이 통째로 어긋난다.
4. **`LibraryViewModel` 의 주석이 자기 캡처 리스트와 어긋난다.**
   `LibraryViewModel.swift:318-320` "백그라운드 블록은 self 를 캡처하지 않는다" ↔ 바로 아래 `:321`
   `importQueue.async { [weak self] in`(그리고 `:344` 도 같다). 실질(강한 참조 없음)은 맞지만 문장은 거짓이고,
   블록 안에서 self 를 안 쓰므로 그 캡처 자체가 불필요하다.

---

## 확인했지만 문제없던 것 (다음 라운드 시간 절약용)

**요약(6줄).** ① 재생정책은 빠진 축이 없다 — 판정 출력 3개(`pauseMask`/`muted`/`stop`)가 전부 소비되고,
6축 입력이 모두 배선돼 있으며, 미배선 입력 4종은 근거와 함께 문서화돼 있다(UI 노출도 0). ② 평가기 우선순위는
전순서라 동시 발화 결과가 결정적이다. ③ 동시성 3부류(importQueue 의 VM 접근·백그라운드 AppKit·비동기화
mutable static)는 이 레인에 **남은 것이 없다**. ④ `WorkshopAPI` 의 API 키는 로그·URLCache·오류 문자열
어디로도 새지 않는다. ⑤ 주석이 인용한 오라클·줄번호는 전부 실재·일치한다(M10/M20/M21 류 드리프트 0).
⑥ `PlaybackPolicyGate.declaredPolicy` 는 프로덕션 호출부 0건이다(브리핑 전제와 다름). 상세는 아래.


- **재생정책의 축은 빠진 것이 없다.** 판정 출력 3개가 전부 소비된다 —
  `pauseMask`→`AppDelegate:1182-1185`, `muted`→`:1190-1192`(`setPolicyMuted`), `stop`→`pause` 로 축소
  (`PlaybackPolicyComposition.swift:42-100`, 되돌릴 조건 2개를 숫자로 적어 둔 **결론**이지 미결이 아니다).
  미배선 **입력**은 `vramPressure`·`external*Request`·`unpauseAero`·`forcePauseAll` 이고
  `PlaybackObservers.swift:128-131` + `AppLogic.swift:524-539` 가 이유를 적는다.
  `GlobalPlaybackSettings.setPauseVRAM`(`PlaybackPolicyRuntime.swift:68`)은 **프로덕션 호출부 0건**이라
  UI 가 사용자에게 거짓 약속을 하지 않는다(설정 화면에 vram 토글 없음 — `grep -rn "VRAM" Sources/Waple/` 확인).
- **6축은 전부 배선돼 있고 우선순위는 결정적이다.** `PlaybackConditionsBuilder.make`(`PlaybackObservers.swift:104-132`)
  가 focus/maximized/fullscreen/audio/displaySleep/battery 를 채우고,
  `PlaybackEvaluator.evaluate`(`WaplePolicy/PlaybackPolicy.swift:443-555`)는 고정 순서 ②→⑦ 뒤
  ⑨ 조기 이탈 둘(`stop` ≻ `sleepLatched`)로 끝나므로 전순서다. 동률/경합 자리가 없다.
  `AppLogic.swift:509-522` 의 착지점 인용 6건(`:115`/`:119`/`:122`/`:68`/`:61`/`:48`)은 **실제 줄과 일치**한다
  (M10/M20/M21 류의 줄번호 드리프트 없음).
- `PlaybackMasks` 는 창 bounds 를 다시 뒤집지 않는다 — `DesktopVisibilityMonitor.swift:157` 이
  `currentSnapshots()` 안에서 이미 `cocoaFlipped` 로 담는다. `PlaybackPolicyRuntime.swift:110-112` 의
  좌표계 주석은 정확하다.
- **동시성 3부류 중 남은 것은 없다.** ① `importQueue` 블록이 만지는 것은
  `LibraryStore.scanImportableFolders`(`LibraryStore.swift:168-184`) · `extractZipToTemp`(`:213-223`) ·
  주입된 `videoPrepare` 뿐이고 셋 다 스토어 가변 상태를 건드리지 않는 순수 파일시스템 함수다.
  ② 백그라운드 AppKit 은 `writeLockscreenStill`(`AppDelegate.swift:1765-1785`)의
  `NSImage(contentsOf:)`/`NSBitmapImageRep`(뷰 아님·이미지 I/O) 와 `captureSceneStill`(`:1472`,
  `NSView.init` 만 `main.sync` 로 다녀오는 것을 `:1460-1471` 이 명시)뿐 — 둘 다 PR #8 밖이고 근거가 적혀 있다.
  ③ `Sources/Waple` 의 `nonisolated(unsafe) static var` 는 `GlobalPlaybackSettings.defaults`(`PlaybackPolicyRuntime.swift:42`)
  **한 개**이고 테스트 시임이다(나머지 `static var` 는 전부 계산 프로퍼티).
- **`WorkshopAPI` 의 키 취급은 건전하다.** 검색 URL 이 `?key=` 를 달고 나가지만 전송은 전용
  `.ephemeral` 세션 + `urlCache = nil`(`WorkshopAPI.swift:283-294`), Keychain 저장(`:158-236`),
  UI 로 나가는 것은 `error.localizedDescription`(`WorkshopViewModel.swift:175`·`:201`,
  `DiscoverViewModel.swift:95`)뿐이라 URL 이 실리지 않는다. `NSLog` 호출 3곳(`:219`/`:224`/`:232`)은
  OSStatus 만 찍는다. `preview_url` 은 https 강제(`:114-116`), `publishedfileid` 는 숫자 20자리 이내 확정(`:86-88`).
- `PlaybackVerdict` 의 `isPaused(monitorIndex:)`(`WaplePolicy/PlaybackPolicy.swift:420-424`)가 음수를
  false 로 떨어뜨리므로 `AppDelegate:1177` 의 `?? -1` 폴백은 안전하다(사라진 화면 = 무동작).
- 주석이 인용한 오라클은 실재한다:
  `PlaybackPolicyCompositionTests.testPerProjectDecideAllUsesRealMonitorIndexNotArrayPosition`
  (`Tests/WapleAppTests/PlaybackPolicyCompositionTests.swift:292`) 외 2건(`:307`·`:320`),
  배선 스캔 `PlaybackPolicyWiringTests.testMonitorIndexComesFromTheSameScreenArrayAsTheMasks`(`:175`).
  후자가 소스 텍스트 스캔이라는 사실을 `:172-174` 가 스스로 적는다.
- `PlaybackPolicyGate.declaredPolicy`(`AppLogic.swift:464`)는 **프로덕션 호출부 0건**(테스트 전용).
  `:488-490` 이 "별개의 질문에 답한다" 고 남겨 둔 대로이지만, 그 질문을 하는 코드는 없다.
  (브리핑의 "소비처는 `PlaybackPolicyGate` 하나" 는 현재 코드와 맞지 않는다 — 판정자는 `PlaybackPolicyResolver` 다.)
- `AppLogic.swift:532-539` 의 "절전 래치가 `externalMuteRequest` 를 삼킨다" 는 **기지 미해결**이며
  도달 0(호출부 없음)이다 — 새 발견 아님.
- `VideoPreparationBatch`(`AppLogic.swift:176-208`)의 중복 소스 제거·부분 실패 처리·`accumulated` 병합은
  `applyResolved:702-747` 의 세대 가드(`:710`)와 맞물려 콜백 이중 호출을 만들지 않는다(경로 4개 전부 추적함).
- `RendererSwap`·`PerRendererPauseState`·`AppliedFlag` 의 리셋 규약(`:770-774`, `:1131-1135`, `:1223-1224`)은
  일관되고, 렌더러 세트 교체 시 pause/mute 엣지 추적이 둘 다 리셋된다.
