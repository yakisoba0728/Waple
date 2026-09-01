# 보충 레인 — 앱 외부연동 · 라이브러리 영속화 · 스크린세이버 (r3 스톨 복구)

대상 HEAD `b883386e`. 읽기 전용 — 파일 수정 0건, `swift build`/`swift test` 미실행.
담당 파일 전수 정독: `Sources/Waple/{SteamCmdDownloader,WorkshopAPI,VideoImport,BaseAssetsWarningGate,LibraryViewModel}.swift`
(1,210줄) · `Sources/WapleLibrary/` 8파일(887줄) · `Sources/WapleSaver/WapleSaverView.m`(204줄).

**기지 대조 범위**: `AUDIT-FULL-2026-08-31.md` · `-r2.md` · `-r3.md`(색인+기각표+미판정표) ·
`docs/audit-r2-lanes/lane08·lane10` · **그리고 r3 §4.1 의 교훈대로 `docs/` 전체**
(`swarm-audit-2026-08-26.md` · `full-audit-2026-08-26.md` · `sweep-2026-08-19.md` · `AUDIT.md` · `BACKLOG.md`).
그 확대 덕에 아래 F1 의 성격이 "신규 발견"에서 **"두 번 보고되고 한 번 오기각된 채 아직 안 고쳐진 것"** 으로 바뀌었다.

---

## F1 [🟠 high] `hasStableId` 가 **살균 전** workshopid 로 계산돼 관리 폴더명(**살균 후**)과 갈린다 — 서로 다른 배경 두 개가 무통지로 서로를 파괴한다. **기지 발견이 반만 고쳐졌고, 나머지 반은 08-26 검증자가 오기각했다**

### 자리
| 좌표 | 내용 |
| --- | --- |
| `Sources/WapleLibrary/LibraryStore.swift:257` | `let hasStableId = parsed?.workshopId != nil` — **원문** id 로 판정 |
| `Sources/WapleLibrary/LibraryStore.swift:258` | `var name = WallpaperPathSecurity.normalizedPathComponent(parsed?.id) ?? root.lastPathComponent` — **살균 실패 시 래퍼 폴더명 폴백** |
| `Sources/WapleLibrary/LibraryStore.swift:269-271` | `if fm.fileExists(dest), !hasStableId { name = uniqueManagedName(...) }` — 유일화가 `hasStableId` 로 **꺼진다** |
| `Sources/WapleLibrary/LibraryStore.swift:277-288` | 기존 관리 폴더를 `.<name>.replaced-<uuid>` 로 스테이징 |
| `Sources/WapleLibrary/LibraryStore.swift:299-304` | 등록 성공 시 **그 백업을 영구 삭제**(`fm.removeItem(at: backup)`) |
| `Sources/WapleCore/ProjectJSONParser.swift:294-296` | `parseStringOrNumber` — **빈/공백 문자열만** nil 로 떨어뜨린다 |
| `Sources/WapleCore/WallpaperPathSecurity.swift:4-30` | `normalizedRelativePath`/`normalizedPathComponent` — `..`·`/`·절대·URL스킴·`.`-단독을 전부 nil |

### 기전
`hasStableId`(:257)와 `name`(:258)이 **서로 다른 정의역의 함수**로 계산된다.
`parseStringOrNumber` 는 트림 후 비어 있지 않으면 무조건 통과시키고,
`normalizedPathComponent` 는 훨씬 좁다. 두 집합의 차(`"."`, `".."`, `"../evil"`, `"a/b"`, `"/1"`,
`"http:x"`, `"%2e%2e%2fx"` …)에서 **`hasStableId=true` 인데 `name` 은 비유일한 래퍼 폴더명**이 된다.
WE export 관례상 그 래퍼명은 `Wallpaper/` 라 사실상 항상 충돌한다(F247 주석이 :252-254 에서 그렇게 적는다).

그러면 :269 의 유일화가 꺼지고 → :282 가 기존 폴더를 숨김 형제로 옮기고 → :290 이 새 콘텐츠를 얹고 →
:299 등록 성공 → **:302 가 백업을 영구 삭제**한다. PR #8 이 넣은 롤백(:277-288)은 *등록 실패* 만 되돌리므로
이 경로에서는 아무 방어도 하지 않는다.

### 실행한 재현
```
$ python3 /private/tmp/claude-501/-Users-yakisoba0728-Documents-GitHub/\
bcd06135-7c97-4b04-8714-361dcd4a2973/scratchpad/hasstableid_probe.py
```
(프로브는 `WallpaperPathSecurity.swift:4-30` · `ProjectJSONParser.swift:32-33,294-306` ·
`LibraryStore.swift:256-312` 을 줄단위로 옮긴 포트다 — 각 함수 위에 원본 좌표를 주석으로 달아 뒀다.)

```
입력                 parseStringOrNumber(=hasStableId)  normalizedPathComponent
  '12345'              hasStableId=True             name='12345'
  ''                   hasStableId=False            name=None      ← dc75a58f 가 닫은 유일한 칸
  '   '                hasStableId=False            name=None
  '.'                  hasStableId=True             name=None      ← 열려 있음
  '..'                 hasStableId=True             name=None
  '../evil'            hasStableId=True             name=None
  'a/b'                hasStableId=True             name=None
  '/1'                 hasStableId=True             name=None
  'http:x'             hasStableId=True             name=None
  '%2e%2e%2fx'         hasStableId=True             name=None

--- 시나리오: WE export 관례 래퍼 `Wallpaper/` 두 개 ---
  [zip1: workshopid 없음] hasStableId=False name='Wallpaper' entryId='Wallpaper' backup_deleted=False
  [zip2: workshopid="."] hasStableId=True  name='Wallpaper' entryId='.'         backup_deleted=True

결과:
  entry id='Wallpaper'  -> /imported/Wallpaper  내용=dummy-SECOND     ← 앨리어싱
  entry id='.'          -> /imported/Wallpaper  내용=dummy-SECOND     ← 같은 폴더를 두 엔트리가
  imported/ 실제 내용: ['Wallpaper']
  FIRST 배경 파일 생존? False                                          ← 영구 소실
```
즉 `{"workshopid":"."}` **한 글자**로 이미 가져와 둔 배경의 파일이 사라지고, 그 라이브러리 엔트리는
다른 배경의 콘텐츠를 가리킨다. 경고도 로그도 없다(`:305` catch 는 등록 실패에만 걸린다).

**그 결과는 바로 위 F247 주석이 "막는다"고 적은 문장과 글자 그대로 같다** — `LibraryStore.swift:252-254`:
> `// 래퍼명(WE export 관례 Wallpaper/)은 비유일이라 그대로 쓰면, 동명이나 서로 다른`
> `// 배경의 두 번째 zip import 가 첫 배경의 관리 폴더를 조용히 지우고 그 위에 얹혀`
> `// 첫 엔트리의 북마크가 두 번째 배경 콘텐츠로 앨리어싱된다(무경고 데이터 손실).`

주석이 기술한 방어(`name` 을 선언 id 로 정한다)는 `name` 이 그 id 로 정해질 때만 성립하는데,
살균 실패 시 :258 이 **정확히 그 비유일 래퍼명으로 되돌아간다**. 방어와 판정이 같은 조건에 걸려 있지 않다.

### 왜 최고가치인가 — 두 번 보고됐고, 한 번은 **오기각**됐다
1. **2026-08-21 `dc75a58f`** 가 이 기전을 정확히 문장으로 적으면서 **빈 문자열 칸 하나만** 닫았다:
   `ProjectJSONParser.swift:281-285` — *"`normalizedPathComponent("")` 가 nil 을 내 이미 폴더명으로
   폴백하지만, 그 폴백이 오히려 '빈 id + 비유일 폴더명' 조합을 만든다 … F247·F581 이 막으려던 바로 그 손실"*.
   재현: `git log --oneline -S '공백뿐인 문자열은 부재로 본다' -- Sources/WapleCore/ProjectJSONParser.swift`
   → `dc75a58f (2026-08-21)`. 불변식은 "id 가 살균을 통과했는가" 인데 고친 것은 "id 가 비었는가" 다.
2. **2026-08-26 `docs/swarm-audit-2026-08-26.md:289`** 가 남은 절반을 그대로 지목했다:
   > `[F지원] hasStableId 가 살균 실패한 workshopid 를 '안정적 재임포트'로 오판 — 동명 관리 폴더를 백업 없이 통째로 교체 — LibraryStore.swift:254`
3. **같은 날 `docs/full-audit-2026-08-26.md:200`·`:274` 의 회의적 검증자가 형제 발견을 기각했다**:
   > `LibraryStore.swift:273 재가입 데이터 소실 경로는 **반증**(방어 코드 확인)됐음`
   > `LibraryStore 재가입은 project.json 사전 파스(hasStableId) 방어로 트리거 재현 불가`
   **기각 근거로 든 그 "hasStableId 방어" 가 바로 같은 문서 짝(swarm:289)이 깨져 있다고 적은 것이다.**
   두 08-26 산출물이 서로 모순인 채 병합됐고, 검증자가 고른 쪽이 위 재현으로 반증된다.
   더 정확히는 — `grep -n "254\|살균 실패\|LibraryStore" docs/full-audit-2026-08-26.md` 로 확인한 결과
   **통합 문서는 swarm:289(`:254`) 항목을 아예 싣지 않았다.** 즉 그 기각을 뒤집을 수 있었던 형제 발견이
   같은 날 같은 스웜에서 나왔는데도 통합 단계에서 사라졌고, 남은 것은 기각뿐이다.
4. `BACKLOG.md`·`AUDIT-FULL-2026-08-31{,-r2,-r3}.md` 에 `hasStableId` 문자열 0건
   (`grep -rn "hasStableId" AUDIT*.md BACKLOG.md` → 0). 즉 **세 번의 전체 감사가 이 자리를 다시 못 봤다.**
5. **r3 §4.2 의 M65 정정도 부분 반증된다.** 그 정정은 *"zip 임포트는 `LibraryStore.swift:266-269` 의
   `uniqueManagedName` 이 막는다"* 고 적었는데, :269 의 조건이 `…, !hasStableId` 라 **`hasStableId`
   가 참이면 그 방어가 꺼진다**. M65 의 전제는 `!hasStableId` 인 경우에만 성립한다.

### 모집단
- **설치본 코퍼스 191건: 도달 0** — `workshopid` 키 자체가 0건이다(`ProjectJSONParser.swift:287-290` 이
  `ProjectJSONInstallCorpusTests` 로 그 도수를 고정한다). 워크샵 코퍼스 446 폴더는 이 머신에 없어 미측정.
- 따라서 도달 경로는 **손편집·서드파티 export 도구·악성 zip** 한정이다. F580(같은 파일 :259-262)이 같은
  모집단을 근거로 이미 high 로 처리된 자리이고, 이쪽은 F580 과 달리 **경로 탈출이 아니라 사용자 데이터 파괴**다.
- 오라클 공백: `Tests/WapleLibraryTests/LibraryImportFixRegressionTests.swift:53-68`(F580)이
  `workshopId: "../escaped"` 를 쓰지만 **빈 스토어**에 넣어 `imported/` 봉쇄만 단언한다.
  `LibraryStoreTests.swift:254-278`(F247)은 workshopid **둘 다 유효**한 경우만 본다.
  "살균 실패 id + 기존 동명 관리 폴더" 조합을 단언하는 테스트는 리포 전체에 0건.

**심각도 근거(정직하게)**: 결과는 무통지 영구 데이터 손실이라 기준상 🔴 이지만, **자연 모집단 도달이 0**
(설치본 191/191 에 `workshopid` 키 자체가 없다)이고 파괴 범위가 `imported/` 안으로 한정되므로 🟠 로 둔다.
워크샵 코퍼스 446 폴더로 `workshopid` 값 분포를 재면 등급이 올라갈 수 있다 — 이 라운드는 그 코퍼스가 없다.

### 선행 레인과의 경계
`docs/audit-r2-lanes/lane10-library-saver.md` 가 실측 반증한 두 축과 **다른 축**이다 —
lane10 이 반증한 것은 (a) zip slip/ditto 살균, (b) `moveItem(dest→숨김)` 하에서의 **북마크 해석**이다.
이 발견은 **정체성 플래그(:257)와 폴더명(:258)의 정의역 불일치**이고, 북마크 해석은 정상 동작하는데도
(정상 해석되기 **때문에**) 첫 엔트리가 남의 콘텐츠로 앨리어싱된다.
프로브가 북마크를 "경로" 로 모델링한 것도 lane10 이 뒷받침한다 —
`lane10-library-saver.md` 「확인했지만 문제없던 것」 2 의 `scratchpad/bmprobe.py` 실측이
`removeItem`/`rename` 양쪽에서 북마크가 **경로로 먼저 해석되고 새 콘텐츠를 읽는다**는 것을 이미 쟀다.

---

## F2 [🟡 medium] PR #8 의 세이버 재적재 게이트가 안내 텍스트 레이어를 **contentsScale 1.0 에 영구 고정**시켰다 — 커버리지 0 타깃에 PR #8 이 새로 심은 회귀

### 자리
- `Sources/WapleSaver/WapleSaverView.m:32` — `initWithFrame:isPreview:` 가 `[self reloadContentIfNeeded]`
- `:117-131` — `reloadContentIfNeeded` 게이트
- `:133-141` — `loadContentForPath:` → 재생 불가 시 `showMessage:`
- `:169-180` — `showMessage:`, 그중 **`:176-177`**
  `CGFloat scale = self.window.screen.backingScaleFactor; self.messageLayer.contentsScale = scale > 0.0 ? scale : 1.0;`

### 기전 (코드+diff 로 확정)
1. `initWithFrame:isPreview:` 시점에 이 뷰는 아직 **어떤 창에도 붙어 있지 않다** — `self.window == nil`
   → `nil.screen.backingScaleFactor` = `0.0` → :177 이 폴백 `1.0` 을 찍는다.
2. 동영상이 설정돼 있지 않으면 그 자리에서 `showMessage:`(:139)가 messageLayer 를 만든다 — **scale 1.0**.
3. 이후 `startAnimation`(:41-47, 창에 붙은 뒤)이 부르는 `reloadContentIfNeeded` 는
   `hasLoadedContent=YES` · `samePath`(nil==nil) · `sameIdentity`(`!playable` → **YES**) ·
   `contentMatchesState`(`!playable && player==nil` → YES) 로 **:127-129 에서 조기 반환**한다.
   `showMessage:` 는 다시 불리지 않고, `layoutContent`(:182-186)는 frame 만 만지고 contentsScale 은 건드리지 않는다.
   → **세이버 프로세스 수명 내내 안내 텍스트가 1× 백킹스토어로 남는다.**

### PR #8 이 만든 회귀임의 증거
```
$ git show b883386e -- Sources/WapleSaver/WapleSaverView.m
-        [self loadContent];            (initWithFrame)
+        [self reloadContentIfNeeded];
-    [self loadContent];  // 시작 시 재로드 — 앱에서 배경을 바꿨어도 최신 경로를 반영   (startAnimation)
+    [self reloadContentIfNeeded];
```
PR #8 **이전에는** `startAnimation` 이 매번 `loadContent` → `tearDownContent` → `showMessage:` 였다.
창에 붙은 뒤 레이어가 다시 만들어졌으므로 `self.window.screen.backingScaleFactor` 가 **실제 배율**이었다.
게이트가 그 재생성을 없애면서 초기화 시점의 폴백값이 영구화됐다.

### 확정/추론의 경계
- **확정**(코드·diff): 창 부재 시점의 생성 · 게이트의 조기 반환 · contentsScale 을 갱신하는 코드가 리포에 0건
  (`grep -rn "contentsScale" Sources/WapleSaver/` → `:177` 한 줄).
- **추론**: 그 결과가 Retina 에서 흐릿하게 보인다는 시각적 귀결. 세이버 실동작은 이 라운드도 못 띄웠다
  (브리핑 §「확인하지 못한 것」5).

### 기지 대조
- `contentsScale|backingScaleFactor` 를 `AUDIT*.md` + `docs/` + `BACKLOG.md` 전수 grep → **0건**.
- 인접 기지 둘은 **다른 결함이고 둘 다 이미 닫혔다**:
  `AUDIT.md:222`(showMessage 재호출 시 이전 레이어 미제거 → 지금은 `tearDownContent:197-198` 이 제거),
  `swarm-audit-2026-08-26.md:200`(layoutContent 가 messageLayer 를 0×0 으로 → 지금은 `:184-185` 가
  `NSMakeRect(32, NSMidY-40, W-64, 80)`).
- **왜 아무도 못 잡았는가**: lane10 이 🟡 로 적은 그대로다 — 이 타깃의 유일한 테스트
  `scripts/dev/tests/test_waple_saver_lifecycle.py:38-59` 는 `.m` 을 문자열로 읽는 `assertIn` 이라
  *언제 어떤 상태에서* 레이어가 만들어지는지에 대해 구조적으로 눈이 없다.

---

## F3 [🟡 medium] 담당 두 파일의 주석 좌표 인용 4건 중 **3건 무효** — 전건 출생 시점에는 정확했다(M10 계통 신규 자리, lane08 ⑤ 전칭의 추가 반례)

### 실측 표 (`sed -n 'Np'` 로 각 줄 원문 확인)
| 인용 자리 | 인용 대상 | 현재 그 줄의 실제 내용 | 진짜 자리 | 판정 |
| --- | --- | --- | --- | --- |
| `Sources/Waple/WorkshopAPI.swift:273` | `WorkshopViewModel:133`(client 가 Task 로 넘어가는 자리) | `canLoadMore = false`(clearKey 본문) | `:157` | **무효** |
| `Sources/Waple/WorkshopAPI.swift:273` | `:164` (같은 목적) | `}` | `:189` | **무효** |
| `Sources/Waple/WorkshopAPI.swift:273` | `DiscoverViewModel:88` | `let items = try await client.search(...)` | `:88` | 유효 |
| `Sources/WapleLibrary/LibraryStore.swift:134` | `WorkshopViewModel:253 → setRating` | `// 보간으로 만든 문자열은 애초에 번역 대상이 되지 않는다(§5.0).` | `:290` | **무효**(−37) |
| `Sources/WapleLibrary/LibraryStore.swift:136` | 자기파일 `(:152)` = `importFolders(scanImportableFolders(in:))` | `/// 이미 쓰이는 id 와 충돌할 때 접미(-2, -3, …)로 유일화한다.` | `:162` | **무효**(−10) |

재현:
```
sed -n '133p;157p;164p;189p;253p;290p' Sources/Waple/Surfaces/Workshop/WorkshopViewModel.swift
sed -n '88p'        Sources/Waple/Surfaces/Workshop/DiscoverViewModel.swift
sed -n '152p;162p'  Sources/WapleLibrary/LibraryStore.swift
```

### 출생 대조 — r3 §4.1 의 교훈(“출생은 파일 이력이 아니라 문자열 pickaxe”)을 적용했다
```
git log --oneline -S 'WorkshopViewModel:253' -- Sources/WapleLibrary/LibraryStore.swift   → 5aee54c6 (2026-08-19)
git log --oneline -S 'WorkshopViewModel:133' -- Sources/Waple/WorkshopAPI.swift           → 06c1244f (2026-08-25)
git show 5aee54c6:Sources/Waple/Surfaces/Workshop/WorkshopViewModel.swift | sed -n '253p'
  →  if let score = item.voteScore { library.setRating(score, for: entry) }        ← 출생 시 정확
git show 06c1244f:Sources/Waple/Surfaces/Workshop/WorkshopViewModel.swift | sed -n '133p;164p'
  →  let fetched = try await client.search(...)   /   let batch = try await client.search(...)   ← 둘 다 정확
```
즉 **"애초부터 틀렸다"가 아니라 전형적 사후 드리프트**다(r3 이 `refuted` 3건을 낸 그 함정을 피했다).
자기파일 `(:152)` 만은 출생 시점에도 `uniqueEntryId` 본문(`var n = 2`)을 가리켰다 — 유일한 출생 오류다.

### 기지 대조
- `WorkshopAPI.swift:273/274` · `LibraryStore.swift:134/136` 을 `AUDIT*.md`+`docs/`+`BACKLOG.md` 전수 grep → **0건**.
- 계통(M10 → r2 §0 → r3 M6/M18/M54/M55/M56/M62/O25)은 기지다. **증분은 두 가지**:
  (a) 이 두 파일은 그 어느 항목의 모집단에도 없다(M18=AppDelegate, M54=WallpaperCompatibilityAnalyzer,
  M6=Particle*, M55=ShaderPreprocessor, M56=SceneRendererResources);
  (b) `lane08-app.md:164`·`179-180` 의 전칭 —
  *"⑤ 주석이 인용한 오라클·줄번호는 전부 실재·일치한다(M10/M20/M21 류 드리프트 0)"* —
  에 대한 **추가 반례**다. r3 M18 이 이미 `AppDelegate.swift` 로 그 전칭을 깼으므로 판정 자체는 새롭지 않다.

---

## F4 [🟡 medium] r3 §4.3 「미판정」 1건 — **확정한다.** 손상 zip 은 로그 0건 + 사용자에게 **틀린 원인**을 지목한다. 08-26 에도 같은 발견이 있었고 아직 안 고쳐졌다

r3 §4.3 이 *"`WapleLibrary/LibraryStore.swift:218` zip 해제 타임아웃/실패가 `try?` 로 원인이 지워지고
사용자에게 다른 원인을 가리키는 안내가 뜬다. 손상 zip 은 로그 0건"* 을 **미판정**으로 남겼다.
전 사슬을 좌표로 따라가 **확정**한다.

| 단계 | 좌표 | 하는 일 |
| --- | --- | --- |
| 1 | `ZipImporter.swift:51-52` | `p.standardOutput/standardError = FileHandle.nullDevice` — ditto 의 진단이 통째로 버려진다 |
| 2 | `ZipImporter.swift:55` | `return p.terminationStatus == 0` — **비-0 종료에 로그 한 줄도 없다**(손상 zip = ditto exit 1) |
| 3 | `ZipImporter.swift:53` | `do { try p.run() } catch { return false }` — 실행 실패도 무로그 |
| 4 | `LibraryStore.swift:217-221` | `(try? extract(zipURL, temp)) == true` — `ZipImportError.extractionTimedOut` 이 여기서 소멸, `return nil` |
| 5 | `LibraryViewModel.swift:350` | `temp.map { … } ?? (imported: [], attempted: 0)` — 실패가 **"시도 0건"** 으로 둔갑 |
| 6 | `LibraryViewModel.swift:300-301` | `attempted == 0` → `onNotify?(emptyMessage)` |
| 7 | `LibraryViewModel.swift:354-355` | 그 emptyMessage = **"zip 에서 가져온 배경이 없습니다. project.json 이 포함돼 있는지 확인하세요."** |

즉 5분 타임아웃·손상 아카이브·디스크 가득·ditto 부재 **전부**가 사용자에게 "project.json 이 없나 보라"는
**엉뚱한 지시**로 표시된다. 타임아웃만 `ZipImporter.swift:72` 가 NSLog 를 남기고, 나머지는 로그도 0건이다.

**기지 대조**: 같은 결함이 `docs/full-audit-2026-08-26.md:274` 에도 있다 —
*"(3) extractionTimedOut 타입 오류가 전 프로덕션 경로에서 삼켜져 타임아웃이 '배경 없음' 메시지로 위장"*.
즉 **08-26 에 보고 → 미수정 → r3 이 미판정으로 재발견 → 지금 확정**. 새 id 가 아니라 그 두 항목의 종결로 병합할 것.

---

## ⚪ 관찰 (확정 못 함 — 승격 금지)

- **O-a `LibraryStore.swift:364-374` 의 지연 북마크 갱신이 뷰모델 스냅샷에는 영원히 안 닿는다.**
  `resolveFolderURL` 은 stale 일 때 `resolved.bookmarkData(...)`(**동기 파일시스템 I/O**)를 뜬 뒤
  갱신을 `DispatchQueue.main.async` 로 미룬다(F840 주석 :358-363). 그런데 그 블록이 고치는 것은
  **스토어의** `entries` 이고, `LibraryViewModel.previewState(:477-483)` 가 넘기는 `entry` 는
  `LibraryViewModel.entries`(별도 `@Published` 복사본, `:52`·`:154`)의 값이다. 두 배열을 다시 맞추는
  코드는 임포트·제거·평점 경로뿐(`:258`·`:327`·`:351`·`:399`·`:408`)이라, **세션 내내 뷰모델 쪽 북마크는
  stale 인 채**로 남고 그리드 body 평가마다 타일당 `bookmarkData()` 를 다시 뜬다.
  다음 실행에서의 해석 실패 방지라는 저장 목적은 유지된다(스토어 복사본이 저장되므로) — 손해는 세션 내
  반복 I/O 뿐이다. **stale 로 돌아오는 조건을 이 머신에서 실측하지 않아** 도수 미확정.
- **O-b `SteamCmdDownloader.swift:182-184` 의 "어떤 경로든 반환을 보장" 이 전칭으로는 거짓.**
  `killer`(:205-210)·`escalator`(:202-204) 가 둘 다 `proc.isRunning` 을 먼저 본다. steamcmd 가 이미
  종료했는데 손자 프로세스가 파이프 쓰기끝을 붙잡고 있으면 `handle.availableData`(:218)가 EOF 를 못 받고
  두 워크아이템은 아무 것도 하지 않는다. **홈브루 steamcmd 의 실제 프로세스 트리를 확인하지 못해** 도달 미확정.
- **O-c `LibraryViewModel.importZip` 의 무거운 구간이 반만 백그라운드다.** 주석(:338-339)은 "해제(ditto,
  무거움)는 백그라운드" 라고 적지만, 해제물을 `$TMPDIR` 에서 `~/Library/Application Support/Waple/imported/`
  로 옮기는 `fm.moveItem`(`LibraryStore.swift:290`)은 메인 홉 안이다. 같은 볼륨이면 rename(무해)이지만
  홈이 다른 볼륨(네트워크 홈 등)이면 복사가 되고 그만큼 메인 스레드가 멈춘다. 그 전제는 어디에도 안 적혀 있다.

---

## 확인했지만 문제없던 것 (다음 라운드의 시간을 아끼기 위한 기록)

1. **`ProjectJSONBuilder.videoProject`(`WapleCore/ProjectJSONBuilder.swift:6-11`)의 JSON 이스케이프는 건전하다.**
   `VideoImport.swift:41` 이 파일명·제목을 넘기지만 빌더가 `JSONSerialization.data(withJSONObject:)` 를
   쓰므로 `"`·`\`·개행이 든 파일명에도 유효 JSON 이 나온다. 문자열 보간이 아니다 — 거짓 양성으로 걸렀다.
2. **API 키 유출 경로 0건 — lane08 ④ 재확인.** UI 로 나가는 것은
   `(error as? LocalizedError)?.errorDescription ?? error.localizedDescription` 뿐
   (`WorkshopViewModel.swift:173-175`·`:198-200`, `DiscoverViewModel.swift:95-96`)이고 URL 이 실리지 않는다.
   `SteamAPIKeyStore` 의 NSLog 3곳(`WorkshopAPI.swift:219`·`:224`·`:232`)은 OSStatus·현지화 메시지만 찍는다.
3. **`ZipImporter.waitForExitOrKill`(`:60-74`)의 "이미 종료한 프로세스에 terminationHandler 를 늦게 다는"
   레이스는 이 툴체인에서 재현되지 않는다.** `Tests/WapleLibraryTests/ZipImportAuditRegressionTests.swift:88-93`
   (`testWaitForExitOrKillReturnsForFastProcess`, `/usr/bin/true`)가 정확히 그 창을 때리는데 초록이다
   (전체 스위트 실패 0). 발견으로 올리지 않는다.
4. **세이버의 한국어 리터럴(`WapleSaverView.m:139`)은 기지다.**
   `Tests/WapleAppTests/LocalizationCoverageTests.swift` 의 `sourceKeys()` 주석이
   *"`Sources/WapleSaver` 는 여전히 사각지대다 — Objective-C(.m)라 이 스캐너가 안 읽고, `.saver` 번들에
   `.lproj` 자체가 없다"* 로 스스로 적고, `AUDIT-FULL-2026-08-31.md:2087` 도 같은 사실을 기록한다.
5. **`videoPath` 의 CFPreferences 호스트 스코프는 앱↔세이버가 일치한다.**
   `ScreenSaverController.swift:154-156` 이 `kCFPreferencesAnyHost` 로 쓰고(→ `~/Library/Preferences/
   kr.yaki.waple.saver.plist`), 세이버 폴백(`WapleSaverView.m:76-78`)이 정확히 그 경로를 읽는다.
   ByHost 로 갈렸다면 폴백이 영영 못 찾았을 자리인데, 갈려 있지 않다.
6. **UI 가 스토어를 뷰모델 밖에서 변형하는 자리는 없다** — `filteredCache` 무효화 논증(`LibraryViewModel.swift:64-73`)이 성립한다.
   `grep -rn "\.folders\.\|\.favorites\.\|\.playlist\.\|\.monitors\." Sources/Waple/` 의 뷰 쪽 히트는
   전부 읽기이거나(`WallpaperGridView.swift:345`, `SelectionPanelView.swift:248`, `NowPlayingBar.swift:112`…)
   `viewModel.objectWillChange.send()` 를 동반한다(`NowPlayingBar.swift:302`·`:306`·`:310`).
7. **`FolderStore.createFolder`(`FolderStore.swift:29-34`)는 프로덕션 호출부 0건**(테스트 전용).
   폴더 생성의 실제 진입점은 `SelectionPanelView.swift:67` → `LibraryViewModel.moveToFolder` →
   `FolderStore.move`(:37-52)의 암묵 생성이다. 결함은 아니지만 두 진입점의 규약(:41 F585 트림 대칭)이
   한쪽에서만 검증된다.
8. **6개 스토어의 백업-실패 가드·원자적 쓰기·3분기 로드는 여전히 6/6 대칭이다** — lane10 clean #1 재확인
   (Favorites:30-37 · Folder:72-79 · Library:69-76 · Monitor:80-87 · PlaylistStateTime:45-52 · Playlist:85-92).
   r3 H5 의 "7번째만 미준수" 전제도 이 6개에 대해서는 유효하다.
9. **`WorkshopQuery.isValidPublishedFileID`(`WorkshopAPI.swift:86-88`)는 계 진입점 전부에 걸려 있다** —
   `SteamCmdDownloader.download:129` 가 argv 조립·경로 조립 **앞**에서 막는다. steamcmd argv 의
   `username` 슬롯 무검증은 r3 §4.1 이 `lane08-app.md:146-150` 중복으로 기각한 자리라 다시 올리지 않는다.
