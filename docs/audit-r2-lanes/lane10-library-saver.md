# 레인 10 — 라이브러리 영속화 · 스크린세이버 · 패키징

대상 HEAD `b883386e`(PR #8). 담당: `Sources/WapleLibrary/` 8파일 · `Sources/WapleSaver/WapleSaverView.m` ·
`Sources/WapleCore/WallpaperPathSecurity.swift`·`WallpaperCompatibilityAnalyzer.swift` · `scripts/package-app.sh`.

## PR #8 이 이 레인에서 한 일 (사실 확인)

`git show --stat b883386e -- Sources/WapleLibrary/` = 6파일. **`ZipImporter.swift`·`LibraryEntry.swift`·
`package-app.sh`·`WallpaperPathSecurity.swift`·`WallpaperCompatibilityAnalyzer.swift` 는 PR #8 이 손대지 않았다**
(브리핑의 "6파일 전부"는 6개 *저장소* 파일을 가리킨다).

변경의 실체는 둘뿐이다.

1. `backupCorruptStoreFile` 을 `-> Bool` 로 바꾸고 **6개 저장소 save() 전부**가 실패 시 `return` 하도록 대칭 적용.
   `git show b883386e -- Sources/WapleLibrary/` 로 6/6 확인 — **비대칭 없음. 이 수정 자체는 옳고 완전하다.**
2. `importExtractedZipCounting` 의 stable-id 교체를 `removeItem(dest)` → `moveItem(dest→숨김형제)` + 롤백으로 교체.
3. 세이버는 `startAnimation` 마다 재적재 → `reloadContentIfNeeded` 게이트(M8 수정).

아래 발견은 그 셋을 각각 검증한 결과다.

---

### [🟠] `--deep` 서명이 중첩 `.saver` 에 `--identifier kr.yaki.waple` 을 강제 적용한다 — `CFBundleIdentifier` 와 불일치한 채 공증에 들어간다
- 자리: `scripts/package-app.sh:99-105` (정본: `docs/RELEASING.md:83` "4. `codesign --force --deep` 서명(중첩 saver 번들 포함)")
- 근거/재현:
  ```
  sed -n '99,105p' scripts/package-app.sh
  # SIGN_ARGS=(--force --deep --sign "$WAPLE_SIGN_IDENTITY"); codesign "${SIGN_ARGS[@]}" --identifier kr.yaki.waple "$APP"
  man codesign | col -b | sed -n '83,90p'
  #   --deep  (DEPRECATED for signing as of macOS 13.0) ...
  #     • All signing options will be applied, in turn, to all nested content.
  #       This is almost never what you want.
  ```
  중첩 번들은 `$APP/Contents/Resources/Waple.saver`, 그 `Info.plist` 의 `CFBundleIdentifier` 는
  `kr.yaki.waple.saver`(`package-app.sh:88`). `--identifier kr.yaki.waple` 이 여기에도 적용된다.
- 왜 문제인가: 서명 식별자 ≠ 번들 식별자인 중첩 코드는 Gatekeeper/공증의 대표 지적 사항이고, `--deep` 자체가
  macOS 13 부터 **서명 용도로 폐기**됐다. 릴리스 파이프라인의 검증(`release.yml:239-242` `stapler validate` +
  `spctl -a -vvv -t install`)은 DMG 레벨 얕은 검사라 중첩 식별자 불일치를 잡지 못한다. 올바른 순서는
  안쪽(`.saver`) 먼저 자기 식별자로 서명 → 바깥(`.app`) 서명이다.
- 기지 목록 대조: 해당 없음(기지 M8 은 세이버 재생성 결함이고 서명과 무관).

### [🟠] `ZipImporter` 에 압축폭탄·디스크 고갈 상한이 전혀 없다 — 임포트는 인터넷 다운로드 파일을 여는 신뢰 경계다
- 자리: `Sources/WapleLibrary/ZipImporter.swift:47-56` · `Sources/WapleLibrary/LibraryStore.swift:213-223`
- 근거/재현:
  ```
  grep -rn "volumeAvailableCapacity\|availableCapacity\|uncompressedSize\|압축률" Sources/   # 0건
  ```
  방어는 `extractionTimeout: TimeInterval = 300`(ZipImporter.swift:41) 하나뿐이고, 그것도 *시간* 상한이다.
  해제 목적지는 `fm.temporaryDirectory`(LibraryStore.swift:216) = 부트 볼륨.
- 왜 문제인가: ditto 는 APFS 에 초당 GB 단위로 쓴다. 300초 상한 안에서 수십~수백 GB 를 부트 볼륨에 쏟을 수
  있고, 그 사이 macOS 전체가 디스크 부족으로 흔들린다. 실패 시 `try? fm.removeItem(at: temp)` 로 공간은
  **사후에** 회수되지만(LibraryStore.swift:219, 241) 그 전에 시스템이 이미 손상 상태다. 해제 전 free space
  확인도, 누적 바이트 상한도, 엔트리 수 상한도 없다.
- 기지 목록 대조: 해당 없음(V06 은 *행 걸린 프로세스*의 타임아웃만 다뤘다 — 크기는 다루지 않았다).

### [🟠] `.corrupt-*` 백업을 읽거나 사용자에게 알리는 코드가 리포 전체에 0건 — "복구 가능한 사용자 설정" 이라는 주석의 근거가 성립하지 않는다
- 자리: `Sources/WapleLibrary/MonitorAssignmentStore.swift:3-21` (주석 "복구 가능한 사용자 설정의 무음 파괴를 막는다")
- 근거/재현:
  ```
  grep -rn "corrupt\|손상" Sources/Waple/*.swift
  # → LibraryViewModel.swift:457 한 줄(북마크 해석 실패 주석). UI·알림·복구 경로 0건.
  grep -rn "corrupt-" Sources/    # → 0건(쓰는 쪽조차 이 접두를 다시 읽지 않는다)
  ```
- 왜 문제인가: favorites.json 한 바이트만 깨져도 사용자의 즐겨찾기는 UI 에서 즉시 전멸하고, 다음 토글이
  거의 빈 파일을 기록한다. 남는 것은 `~/Library/Application Support/Waple/favorites.json.corrupt-<ms>`
  와 `NSLog` 한 줄뿐 — 앱은 사용자에게 아무 말도 하지 않고, 그 파일을 되읽는 코드도 없다. PR #8 이
  이 기전을 6/6 대칭으로 다듬었지만, 기전의 **출구**가 없다는 것은 그대로다.
- 기지 목록 대조: 해당 없음.

### [🟡] PR #8 이 함수 시그니처와 호출자 6곳을 다 고치면서 그 함수의 정본 주석은 안 고쳤다 — "3개 저장소가 공유" · "JSON" 둘 다 거짓
- 자리: `Sources/WapleLibrary/MonitorAssignmentStore.swift:3-4`
  > `/// 손상된 스토어 JSON 을 덮어쓰기 전 1회 백업(rename). ...`
  > `/// Library/Playlist/Monitor 스토어가 공유한다.`
- 근거/재현:
  ```
  grep -rn "backupCorruptStoreFile(\|backupCorruptFile(" Sources/WapleLibrary/
  # FavoritesStore:34 FolderStore:76 LibraryStore:73 MonitorAssignmentStore:49,84
  # PlaylistStateTimeStore:49 PlaylistStore:89  → 공유 저장소는 3개가 아니라 6개
  ```
  그리고 `PlaylistStateTimeStore` 가 백업하는 것은 JSON 이 아니라 **WE 바이트 포맷**
  `playliststatetime.bin`(`PlaylistStateTimeStore.swift:18`, `PlaylistStateTimeFile.encode`).
- 왜 문제인가: 이 리포가 가장 비싸게 치는 부류(정본·주석이 코드와 어긋남)다. 다음 세션이 "Favorites/Folder 는
  이 규약 밖" 이라고 오독하면 그 둘의 손상 경로를 다르게 고친다.
- 기지 목록 대조: 해당 없음.

### [🟡] 스키마 마이그레이션 방어가 6개 중 1개에만 있다 — `FolderStore.Folder` 에 필드를 하나 더하면 기존 folders.json 전부가 corrupt 오판으로 전멸한다
- 자리: `Sources/WapleLibrary/PlaylistStore.swift:14-23`(방어 있음) vs `Sources/WapleLibrary/FolderStore.swift:5-9`(없음)
- 근거/재현: `PlaylistStore` 는 그 위험을 주석으로 명시하고 손으로 `init(from:)`+`decodeIfPresent` 를 썼다:
  > `/// 합성 init(from:) 는 누락 키에서 throw 한다 ... 구버전 JSON 전부가 corrupt 오판으로 초기화되는 걸 막기 위해`
  같은 위험에 노출된 `FolderStore.Folder`(`name`/`ids` 둘 다 비-Optional, 합성 Codable)와
  `LibraryStore.Index`(`entries` 비-Optional, `LibraryStore.swift:43-46`), `LibraryEntry` 의 앞 6필드
  (`LibraryEntry.swift:4-9`)에는 같은 방어가 없다. 회귀 테스트도 PlaylistStore 만 있다
  (`Tests/WapleLibraryTests/MonitorAndPlaylistTests.swift:179-247`).
- 왜 문제인가: `PlaylistStore` 가 문서화한 사고가 나머지 저장소에서 그대로 재현된다. 다음 필드 추가 =
  사용자 폴더/라이브러리 전멸 + `.corrupt-*` 백업(위 항목대로 아무도 안 읽는다).
- 기지 목록 대조: 해당 없음.

### [🟡] `LibraryStore.load()` 는 전부-아니면-전무 디코드다 — 엔트리 1개의 손상이 라이브러리 전체를 비운다(리포는 다른 곳에서 관용 디코드를 실천한다)
- 자리: `Sources/WapleLibrary/LibraryStore.swift:57-64`
- 근거/재현: `try JSONDecoder().decode(Index.self, from: data)` — 엔트리 단위 salvage 없음.
  대조군: `Tests/WapleCoreTests/AssetJSONLenientTests.swift`(씬 에셋 JSON 은 관용 디코드가 정본).
- 왜 문제인가: 손상 시 `entries=[]` → `indexCorrupt=true` → 다음 사용자 조작이 빈 인덱스를 기록한다.
  favorites/playlist/monitors 의 id 는 전부 고아가 되고(각 저장소는 멀쩡히 살아 있으므로),
  라이브러리만 비어 보인다. 원자적 쓰기(`options: [.atomic]`, :80) 덕에 부분 기록으로는 도달하기 어렵고
  FS 손상이 필요하므로 🔴 이 아니라 🟡 로 둔다.
- 기지 목록 대조: 해당 없음.

### [🟡] PR #8 이 새로 심은 `.<name>.replaced-<uuid>` 숨김 폴더 — 임포트 중 종료되면 영구 잔존하고, 다음 임포트가 엔트리를 중복시킨다
- 자리: `Sources/WapleLibrary/LibraryStore.swift:276-288` (신설) · 회수는 `:301-309`, `:322-331` 뿐
- 근거/재현:
  ```
  grep -rn "replaced-" Sources/            # → LibraryStore.swift:278 한 곳(쓰는 자리)뿐. GC·기동 시 회수 0건.
  python3 scratchpad/bmprobe.py            # 시나리오 3(CRASH-AFTER-RENAME) 실측
  ```
  실측(위 프로브, 이 머신 APFS):
  `dest` 를 `.NAME.replaced-<uuid>` 로 rename 한 뒤 새 dest 를 만들지 않은 상태에서 기존 엔트리의
  북마크를 해석하면 → **숨김 백업 경로로 해석되고 `stale=true`** 다.
  그러면 `resolveFolderURL`(`LibraryStore.swift:364-374`)이 그 숨김 경로를 library.json 에 **영속**시킨다.
- 왜 문제인가: rename 성공 후 move 전에 앱이 죽거나 강제 종료되면 (a) 관리 폴더가 Finder 에 안 보이는
  숨김 이름으로 영구히 남고(어떤 코드도 회수하지 않는다), (b) 엔트리는 그 숨김 경로로 재영속되며,
  (c) 같은 배경을 다시 임포트하면 `dest` 부재 → 스테이징 없이 move 성공 → `importFolder` 에서 기존 엔트리가
  숨김 경로로 해석돼 `sameFolder=false` → **`id-2` 중복 엔트리**가 생긴다. PR #8 이전(`removeItem`)에는
  같은 창에서 폴더가 지워졌으므로 "숨은 채 영구 잔존" 이라는 상태 자체가 없었다.
- 기지 목록 대조: 해당 없음(PR #8 이 새로 만든 상태).

### [🟡] 세이버 수명주기의 유일한 테스트는 소스 텍스트 grep 이고, 게이트를 뒤집어도 통과한다
- 자리: `scripts/dev/tests/test_waple_saver_lifecycle.py:38-59` (PR #8 신설, +63줄)
- 근거/재현: 테스트는 `.m` 을 문자열로 읽어 `assertIn` 만 한다. 특히 `:46` `self.assertIn("return;", reload)`
  는 어떤 조기 반환이 있어도 참이다. `reloadContentIfNeeded`(`WapleSaverView.m:117-131`)의 게이트를
  `if (self.hasLoadedContent && ...) return;` → `if (!(self.hasLoadedContent && ...)) return;` 로 **뒤집어도**
  단언된 4개 부분문자열(`isEqualToString:self.loadedVideoPath`, `self.player != nil`, `return;`,
  `[self loadContentForPath:path]`)이 전부 그대로라 초록이다.
  다른 게이트도 행위를 안 본다: `ci.yml:183-191` 은 `clang` 으로 **컴파일만** 하고 산출물을 버리고,
  `spec.yml:363-380` 은 `@implementation` 이름과 plist 리터럴의 문자열 동일성만 본다.
- 왜 문제인가: 기지 M8("startAnimation 마다 플레이어 재생성")의 수정에 **행위 커버리지가 0** 이다.
  204줄 ObjC 는 여전히 인스턴스화된 적이 없다(브리핑 "확인하지 못한 것 4" 그대로).
- 기지 목록 대조: M8 의 *수정 품질* 에 대한 새 관찰(M8 재보고 아님).

### [🟡] 세이버: 파일 정체성 판정이 심링크를 따라가지 않아, PR #8 이 노린 "같은 경로 원자적 교체" 감지가 심링크 videoPath 에서 무력화된다
- 자리: `Sources/WapleSaver/WapleSaverView.m:97` (`attributesOfItemAtPath:error:`) vs `:85` (`fileExistsAtPath:`)
- 근거/재현: `attributesOfItemAtPath:error:` 는 말단 심링크를 따라가지 않는다(Apple 문서). `fileExistsAtPath:`
  는 따라간다. 도달 가능성 실측 — ditto 는 zip 의 심링크 엔트리를 **심링크로 복원한다**:
  ```
  python3 -c '...zipfile, external_attr=(stat.S_IFLNK|0o777)<<16...'   # scratchpad/zt/mk.py
  /usr/bin/ditto -x -k sym2.zip sandbox3 ; ls -la sandbox3/Wallpaper/
  # lrwxr-xr-x  evil -> /private/tmp/.../victim      (exit=0)
  ```
- 왜 문제인가: `imported/<id>/wallpaper.mp4` 가 심링크면 `videoFileIdentityForPath:` 가 담는 inode/크기/mtime 은
  **링크 자신의 것**이라 대상이 교체돼도 변하지 않는다. `:91-92` 주석이 정확히 그 경우를 고쳤다고 적어 둔
  자리("워크숍 재임포트는 최종 경로를 유지한 채 새 디렉터리를 옮겨 놓으므로")인데, 심링크 경유에서는
  낡은 AVPlayer 가 그대로 남는다.
- 기지 목록 대조: 해당 없음.

### [🟡] `package-app.sh` 의 `.lproj` 목록이 하드코딩이라 새 로케일은 조용히 빠진다
- 자리: `scripts/package-app.sh:30` — `cp -R "Resources/en.lproj" "Resources/ko.lproj" "$APP/Contents/Resources/"`
- 근거/재현: `ls Resources/` → `en.lproj ko.lproj`(현재는 목록이 완전 — 실동작 결함 아님).
  `Tests/WapleAppTests/LocalizationCoverageTests.swift` 는 en/ko 의 *내용*만 보고 `package-app.sh` 가
  `Resources/*.lproj` 를 전부 동봉하는지는 보지 않는다.
- 왜 문제인가: `ja.lproj` 를 추가하면 테스트는 초록인데 번들에는 안 들어가 그 언어만 한국어로 나온다.
  같은 스크립트가 바로 위(:39-45)에서 WEAssets 는 후보 루프+존재 검사로 방어하는 것과 비대칭이다.
- 기지 목록 대조: 해당 없음.

### [⚪] 세이버: `isPreview` 미사용 · 화면당 별도 AVPlayer · `stopAnimation` 이 디코더를 놓지 않는다(PR #8 의 의도된 대가)
- 자리: `WapleSaverView.m:25-35`(isPreview 를 저장도 참조도 안 함) · `:49-52`(pause 만)
- 왜 기록하는가: `ScreenSaverEngine` 은 화면마다 인스턴스를 만들므로 N개 디스플레이 = 같은 파일의 N개 디코더다.
  시스템 설정의 미리보기 썸네일도 전체 AVPlayer 를 띄운다. PR #8 이 stop 에서 해제를 없앤 것은 M8 수정의
  핵심이므로 결함이 아니라 **거래**다 — 다만 그 대가로 상주 비용이 `legacyScreenSaver` 프로세스 수명 전체로
  늘었다는 사실은 어디에도 안 적혀 있다(`:43-44` 주석은 이득만 적는다).

---

## 의심 (확인 못 함 — 발견으로 올리지 않음)

- `WapleSaverView.m:28-30` 은 `wantsLayer = YES` **뒤에** `self.layer = [CALayer layer]` 를 대입한다.
  Apple 문서의 레이어 호스팅 규약은 반대 순서(layer 먼저, wantsLayer 나중)다. 실동작에서 AppKit 이 백킹
  레이어를 교체하며 서브레이어를 떨어뜨리는지는 세이버를 실제로 띄워야 확인된다(브리핑 "확인하지 못한 것 4").
- `configuredVideoPath`(`:66-81`)는 `CFPreferencesCopyAppValue` 를 동기화 없이 부른다. 앱은 쓰기 뒤
  `CFPreferencesSynchronize`(`ScreenSaverController.swift:156`) 하므로 cfprefsd 경유로 보일 것으로 보이나,
  장시간 상주 세이버 프로세스의 캐시 거동은 실측하지 않았다.
- `package-app.sh:115-131` 스모크는 `sleep 6` 뒤 `kill -0` 로 생존을 본다. 좀비 상태의 자식에게 `kill -0` 이
  성공할 수 있는 창이 이론상 있으나(bash 의 SIGCHLD 수거 타이밍), 6초면 수거가 끝났을 것이라 재현 못 함.
- `imported/` 관리 폴더는 라이브러리에서 제거해도 영구 잔존한다(`LibraryStore.swift:338-344`
  "파일은 건드리지 않음", 회수 코드 0건: `grep -rn '"imported"' Sources/` = `LibraryStore.swift:243` 한 곳, 생성뿐). 의도된 설계로
  주석에 적혀 있어 결함으로 올리지 않지만, 디스크 비용이 무제한이고 UI 에 회수 수단이 없다.

---

## 확인했지만 문제없던 것 (다음 라운드의 시간을 아끼기 위한 기록)

1. **PR #8 의 백업-실패 가드는 6/6 완전 대칭이다.** Favorites:34 · Folder:76 · Library:73 · Monitor:84 ·
   PlaylistStateTime:49 · Playlist:89 전부 `guard ... else { NSLog; return }`. 원자적 쓰기(`options:.atomic`)도
   6/6, `loadFailed` 3분기 규약(`readStoreFile`)도 6/6. 비대칭은 **DI 이음새 하나뿐** —
   `MonitorAssignmentStore.swift:41,48-55` 만 주입 가능하고 나머지 5개의 가드는 결정적으로 검증되지 않는다(⚪).
2. **`moveItem(dest→숨김)` 이 stable-id 재임포트를 깨뜨리지 않는다 — 가설 반증.** `URL(resolvingBookmarkData:)`
   가 inode 대신 경로로 먼저 해석하는지 ctypes/CoreFoundation 프로브로 실측했다
   (`scratchpad/bmprobe.py`, `python3 bmprobe.py`): PR #8 전(`removeItem`)·후(`rename`) **양쪽 다**
   `imported/ROLLBACK1` 로 해석되고 `stale=true` 이며 **새 콘텐츠**를 읽는다. 즉 `importFolder` 의
   `sameFolder`(`LibraryStore.swift:107-108`) 판정은 두 구현에서 동일하게 참이고, `id-2` 중복은 생기지 않는다.
   판정에 실린 사실은 **두 구현이 같은 경로 문자열로 해석된다**는 것이고, 이는 위 출력으로 직접 측정됐다.
   (프로브가 찍는 `/private/var` vs `/var` 표기 차는 raw CFURL 을 그대로 쓴 탓이며, 실코드는 양변에
   `standardizedFileURL` 을 건다. 그 정규화가 `/private` 접두까지 흡수한다는 것은
   `Tests/WapleLibraryTests/LibraryStoreTests.swift:301-307`(`testResolveFolderURLReturnsOriginalLocation`)이
   NSTemporaryDirectory 하위 경로로 통과 중이라는 사실이 방증한다 — 직접 실행해 확인하지는 않았다.)
3. **`ditto -x -k` 는 zip slip 과 절대경로 엔트리를 살균한다 — 실측.**
   ```
   # scratchpad/zt/mk.py 로 픽스처 생성 후
   /usr/bin/ditto -x -k slip.zip dest   # ../../ESCAPED-DOTDOT.txt → dest/ESCAPED-DOTDOT.txt (exit 0, 탈출 없음)
   /usr/bin/ditto -x -k abs.zip  dest   # /tmp/ESCAPED-ABS.txt     → dest/tmp/ESCAPED-ABS.txt (exit 0, /tmp 무변화)
   /usr/bin/ditto -x -k sym.zip  dest   # 심링크 아래로 쓰는 엔트리 → "Not a directory", exit 1(해제 전체 실패)
   ```
   심링크 **엔트리 자체**는 복원되지만(위 🟡 항목), 그 심링크를 **관통해 쓰는** 것은 ditto 가 막는다.
   `findProjectRoots`(`ZipImporter.swift:20-27`)의 심링크 스킵과 `FileManager.removeItem`(심링크 비추종)이
   나머지를 막으므로 **zip 임포트에 경로 탈출 파괴 경로는 없다**.
4. **엔트리 삭제 시 orphan id 누수 없음.** `LibraryViewModel.remove(_:)`(`Sources/Waple/LibraryViewModel.swift:244-265`)
   가 playlist·monitors·favorites·folders 네 저장소를 모두 정리한다(:253-256). `PlaylistStateTimeStore` 는
   화면 키로만 색인하므로 엔트리 고아가 성립하지 않는다.
5. **공증 파이프라인은 갖춰져 있다.** `package-app.sh` 에 없는 것이 맞고(설계), `release.yml:193-242` 가
   임시 키체인 → `.p12` 임포트 → `set-key-partition-list` → 패키징 → `notarytool submit --wait` →
   `stapler staple`/`validate` → `spctl` 을 수행한다. 위 🟠 `--deep` 항목 외에는 공증 준비에 공백 없음.
6. **arm64 단일 아키텍처는 정본 의도다** — `README.md:70` "macOS 14 or later, Apple Silicon ... Intel is untested".
   `clang`/`swift build` 에 `-arch` 가 없는 것은 거짓 양성이 아니라 문서화된 선택이다.
7. `package-app.sh` 는 `set -euo pipefail`(`:2`) 이 걸려 있고 clang·hdiutil·codesign 실패는 전부 전파된다.
   스테이징 정리 `trap`(`:142`)도 있다. "실패해도 성공으로 끝나는 자리"는 찾지 못했다.
8. `WallpaperPathSecurity.normalizedPathComponent`(`:26-30`)는 `..`·절대경로·URL 스킴·NUL·퍼센트 인코딩을
   모두 거르고 단일 컴포넌트만 통과시킨다. F580 회귀 테스트(`LibraryImportFixRegressionTests.swift:53-66`)가
   `imported/` 봉쇄를 단언한다. 추가 결함 없음.
9. `WallpaperCompatibilityAnalyzer.swift`(1,177줄)는 PR #8 이 손대지 않았고 진단 리포트 생성 전용이다.
   표적 점검만 했다 — 새 발견 없음.
