# 레인 7 — 비디오 · 오디오 · 웹 벽지 (HEAD `b883386e`, 읽기 전용)

PR #8 이 이 레인에서 만진 파일: `WallpaperSchemeHandler.swift`(±264) · `VideoRenderer.swift`(+19) ·
`SystemAudioSpectrumProvider.swift`(+17) · `WapleCore/AudioSpectrum.swift`(±18) ·
`SceneVideoLayer.swift`(±5) · `WebRenderer.swift`(±2).
(`git show b883386e --stat | grep -E 'Video|Web|Audio|Scheme'`)

---

## 발견

### 🟠 L7-1 — F820 "음량/배속 라이브 반영" 이 `.videoFallback`(WebRenderer) 경로를 빠뜨렸다: ffmpeg 없는 머신의 webm 배경은 음량 조작이 통째로 무시된다

- **자리**: `Sources/Waple/AppDelegate.swift:653` · `Sources/WapleRender/WebRenderer.swift:58` · `:175` · `:355`
- **근거/재현**:
  ```
  grep -n "applyLiveVideoSettings" Sources/Waple/AppDelegate.swift
  # 653:  renderers.compactMap { $0 as? VideoRenderer }.forEach { $0.applyLiveVideoSettings() }
  grep -n "mountedVolume" Sources/WapleRender/WebRenderer.swift
  # 58: private var mountedVolume: Float = 0      ← mount 때 1회만 대입
  # 175: mountedVolume = VideoSettings.volume(id: project.id)
  # 355: case .videoFallback: return mountedVolume > 0
  git show 23c8e277 -- Sources/Waple/AppDelegate.swift
  # -libraryVM.onVideoSettingsChanged = { [weak self] in _ = self?.applyCurrentSelection() }
  # +libraryVM.onVideoSettingsChanged = { [weak self] in self?.applyLiveVideoSettings() }
  ```
  경로: `NowPlayingBar.swift:228` `VideoSettings.setVolume` → `:292` `viewModel.onVideoSettingsChanged?()`
  → `AppDelegate:301` → `:653`. 그 653 이 `as? VideoRenderer` 로 걸러 낸다.
  `.videoFallback` 렌더러의 도달 조건은 `RendererFactory.swift:49-51` —
  `if !FFmpegConverter.isAvailable { return webViewPlayableContainer(ext) ? WebRenderer(mode: .videoFallback) : nil }`
  (= ffmpeg 미설치 + `webm`). 그 렌더러의 음량은 `VideoFallbackHTML.html(volume: mountedVolume)`
  로 **마운트 시점에 HTML 에 구워진다.**
- **왜 문제인가**: F820(`23c8e277`, 2026-07-24) 이전에는 `applyCurrentSelection()` 전체 리마운트가
  폴백 HTML 을 새 음량으로 다시 만들어 값이 반영됐다. F820 이 리마운트를 없애면서 라이브 경로를
  `VideoRenderer` 에만 달았으므로, ffmpeg 미설치 사용자의 webm 배경에서는 음량 메뉴가 **아무 일도
  하지 않는다.** UI 는 성공처럼 보인다 — `NowPlayingBar.currentVideoVolume` 이 UserDefaults 를
  읽으므로 체크마크는 새 값으로 옮겨간다. 부수적으로 `WebRenderer.isPlayingAudio`(`:355`)가
  같은 낡은 `mountedVolume` 을 보므로 재생정책의 오디오 축 판정도 어긋난다.
- **기지 목록 대조**: 해당 없음.
  `grep -n "mountedVolume\|videoFallback\|applyLiveVideoSettings\|F820" AUDIT-FULL-2026-08-31.md` → **0건**.

---

### 🟡 L7-2 — PR #8 이 스킴 핸들러 스트리밍을 다시 메인 큐 응답성에 결합시키면서, 그러지 말라고 적어 둔 근거 주석을 같이 지웠다

- **자리**: `Sources/WapleRender/WallpaperSchemeHandler.swift:104-134`(start → `Task.detached` + `@MainActor deliver`) · `:295-302`(청크 루프)
- **근거/재현**: `git show b883386e -- Sources/WapleRender/WallpaperSchemeHandler.swift`
  삭제된 블록(구 `:264-270`):
  > `감사 H: main.sync 왕복이면 스트리밍 처리량이 메인 큐 응답성에 결합되므로 ioQueue 에서 직접 전달한다.`
  > `F590: live 확인과 didReceive 호출을 한 락 구간에서 원자화한 F575 는 폐기 — … 교착이 실재했다`

  현재 코드는 64 KiB 청크마다 `guard await deliver(.data(data)) else { return }`(`:301`)로
  MainActor 홉을 한다. `chunkSize = 64*1024`(`:16`) → 100 MB 미디어 1건에 약 1,600 홉,
  4K 500 MB 면 약 8,000 홉.
- **왜 문제인가**: 교착(F575)·use-after-stop 축에서는 새 설계가 확실히 낫고(태스크를 강참조로
  들어 ObjectIdentifier 재사용 위험도 없앴다), 그 자체는 개선이다. 문제는 **되돌린 축과 그 이유가
  트리에 남지 않은 것**이다. `3854bc8f`(2026-07-20) 가 "스킴핸들러 main.sync" 로 없앴던 결합이
  형태만 바뀌어(`sync` → `await`, 스레드 블록은 없음) 돌아왔는데, 새 주석(`:200-203`)은
  "청크마다 await 하므로 전달 순서·백프레셔를 유지" 라고만 적고 처리량 결합은 말하지 않는다.
  씬 렌더가 메인을 60 fps 로 점유하는 동안 웹 벽지의 `<video>` Range 스트리밍이 그 뒤에 줄 선다.
- **기지 목록 대조**: 해당 없음(직전 감사는 스킴 핸들러를 4건 목록에만 올렸다 —
  `AUDIT-FULL-2026-08-31.md:1904`, `:2031`).

---

### 🟡 L7-3 — BACKLOG 의 `3538758087` 비디오-백드 플레이크는 "원인 미규명" 이 아니다 — 기전이 코드에 이미 적혀 있고 자리를 특정할 수 있다

- **자리**: `Sources/WapleRender/SceneRendererFrameEncoder.swift:2492` ·
  `Sources/WapleRender/SceneRendererResources.swift:396` ·
  `Sources/WapleRender/SceneVideoLayer.swift:112-114` · `:124-136` · `:351-359`
- **근거/재현**:
  헤드리스 캡처의 비디오 레이어 합성은
  ```
  SceneRendererFrameEncoder.swift:2492
      base = video.headlessTexture(at: time, device: device) ?? layer.texture
  ```
  이고, 그 `layer.texture` 는 **1×1 투명 placeholder** 다:
  ```
  SceneRendererResources.swift:396
      } else if let sv = videoLayerProvider(...), let ph = makeTexture(Data([0,0,0,0]), 1, 1, device) {
  ```
  즉 디코드가 한 번 실패하면 그 레이어가 "조금 다른" 이 아니라 **통째로 사라진** 프레임이 된다.
  `VideoBackedSceneCaptureTests.swift:179` 의 단언 (c) `XCTAssertEqual(px1u, px2u)` 는 바이트 동일을
  요구하므로 이 all-or-nothing 분기 하나로 깨진다. 그리고 그 실패는 **부하 의존**으로 세 갈래다:

  | # | 자리 | 기전 |
  | --- | --- | --- |
  | 1 | `SceneVideoLayer.swift:112-114` | 파일 스스로 적고 있다 — *"다중 마운트 시 메모리 압박으로 텍스처 할당이 비결정 실패(→ **폴백 프레임 편차**)"*. `rgbaTexture` 의 `device.makeTexture` 가 nil 이면 그대로 placeholder. |
  | 2 | `:356-358` | `copyCGImage(at: wrappedTime)` throw → `catch` 가 **`.zero` 프레임으로 폴백**. 같은 t 인데 한쪽만 t=0 프레임이 된다. |
  | 3 | `:124-136` | `duration` lazy 의 **5초 세마포어 타임아웃**(`assetLoadTimeoutSeconds`) → `duration = 0` → `wrap(6.0, 0) = 6.0`(무-wrap) → 짧은 루프 mp4 의 끝을 넘겨 2 를 유발. 캡처 A/B 는 각각 새 `SceneRenderer` → 새 `SceneVideoLayer` 라 **duration 로드를 독립 2회** 한다 — 한쪽만 타임아웃하면 두 캡처가 갈린다. |

  실측 프로필(BACKLOG:627 "같은 커밋을 조건만 바꿔 돌리면 0/3 · 3/3 · 1/4 — 부하 의존")과 정확히 맞는다.
- **왜 문제인가**: BACKLOG 는 *"원인 미규명 — 규명 전 임계를 건드리지 말 것"* 으로 잠가 뒀는데,
  같은 리포의 `SceneVideoLayer.swift:112-114` 가 이미 그 기전(부하 → 할당 실패 → 폴백 편차)을
  이름까지 붙여 적고 있다. 문서와 코드가 어긋난 채로 항목이 잠겨 있어 다음 세션이 같은 자리를 다시 판다.
- **정직한 한계(의심으로 분류할 부분)**: 1·2 는 플레이크 실측(2026-08-16)보다 먼저 존재했다
  (`git log -S maximumSize -- Sources/WapleRender/SceneVideoLayer.swift` → `3636dd3c` 2026-07-15).
  3 은 그 뒤(`a4e65459` 2026-08-19)에 생겼으므로 **당시 실패의 원인은 아니고 지금 새로 생긴 네 번째
  갈래**다. 실물 코퍼스가 없어 `3538758087` 임베디드 mp4 의 길이가 6 s 미만인지 확인하지 못했다 —
  3 의 성립은 **의심**이다. 1·2 는 코드만으로 성립한다.
- **다음 판별(코퍼스 있는 세션, 1줄)**: `SceneVideoLayer.headlessTexture` 가 nil 을 돌려준 횟수와
  `duration` 값을 로깅해 A/B 두 캡처를 비교한다. nil>0 이면 1/2, `duration==0` 이면 3.
- **기지 목록 대조**: 해당 없음(BACKLOG 항목 자체는 기지 — 여기서 올리는 것은 "미규명" 이라는
  **문서 서술이 코드와 어긋난다** 는 점이다).

---

### ⚪ L7-4(관찰) — `FFmpegConverter` 의 evict 는 `.part.mp4` 임시파일을 `*.mp4` 로 세고, 변환 캐시는 `isActive` 보호를 전혀 못 받는다

- **자리**: `Sources/WapleRender/FFmpegConverter.swift:171-186` · `Sources/WapleRender/VideoTextureExtractor.swift:87-104` · `:132-135`
- **근거/재현**: `run()` 의 임시파일은 `cacheDir().appendingPathComponent("\(UUID().uuidString).part.mp4")`
  (`FFmpegConverter.swift:173`)라 `pathExtension == "mp4"` 다 — `evictOldest` 의 필터
  `$0.pathExtension == "mp4" && !isActive($0)`(`VideoTextureExtractor.swift:94`)에 그대로 걸린다.
  또 `isActive` 레지스트리는 `SceneVideoLayer.init`(`SceneVideoLayer.swift:141`) 만 채우고 그쪽 캐시
  디렉터리는 `Waple/cache`(`defaultCacheDir`)인 반면, ffmpeg 결과는 `Waple/converted`(`cacheDir`)다 —
  **두 디렉터리가 달라 보호가 한 번도 성립하지 않는다.**
- **왜 문제인가**: (a) 변환 중 앱이 죽어 남은 고아 `.part.mp4` 가 `keep = 8` 예산을 잠식해 유효
  변환물이 조기 evict 된다. (b) 재생 중인 변환 mp4 도 evict 대상이다 — AVPlayer 는 열린 fd 로
  버티지만 다음 마운트에서 수백 MB 재변환이 다시 돈다. 실동작 파손은 아니라 관찰로 둔다.
- **기지 목록 대조**: F840 이 고친 "evict 없음" 의 잔여(재발 아님 — 상한 자체는 실재한다).

---

### ⚪ L7-5(의심) — `deliver` 의 `false` 가 두 원인을 구분하지 못한다

- **자리**: `Sources/WapleRender/WallpaperSchemeHandler.swift:337-352`
- **근거**: `deliver` 는 (a) `activeTasks[id] == nil`(stop 됨)과 (b) `HTTPURLResponse(...)` 가 nil
  둘 다 `false` 를 낸다. 호출부(`streamFile`/`deliverNotFound` 의 `guard await deliver(...) else { return }` 다섯 자리)는 전부 (a) 로 간주해 `return` 한다.
  (b) 라면 태스크는 살아 있는데 `didReceive`/`didFinish` 가 한 번도 안 불리고, 리포 전체에
  `didFailWithError` 호출이 **0건**(`grep -rn didFailWithError Sources` → 없음)이라 그 리소스 로드가
  영구 대기하고 `activeTasks`/`ioJobs` 엔트리도 남는다. 종전 코드는 `HTTPURLResponse(...)!` 강제
  언랩이라 최소한 크래시로 드러났다.
- **왜 의심인가**: Darwin 의 `HTTPURLResponse(url:statusCode:httpVersion:headerFields:)` 가 실제로
  nil 을 내는 입력을 이 코드 경로에서 만들지 못했다(status 는 200/206/404/416 고정, url 은 non-nil).
  **도달 미입증** 이므로 발견이 아니라 의심으로 적는다.

---

## 확인했지만 문제없던 것 (다음 라운드의 시간 절약용)

1. **기지 M20 은 6/6 전건 수정됐다.** 감사가 지목한 `:59`·`:64`·`:69`(2)·`:170`·`:214`·`:220` 이
   전부 생성자 `rdi` 기준으로 옮겨졌고(현행 `:59`·`:64`·`:69`·`:171`·`:215`·`:218`), 정본
   `spec/engine/effect-fbo-audio.json:261,265,269,273` 의 `mov [rdi+0xEC/0xF0/0xF4/0xF8]` 와 일치한다.
   `:171` 이 "생성자 베이스 `0x1404e55a0+0xEC` = 스레드 베이스 `0x1404e55a8+0xE4`" 로 두 기준의
   관계까지 적어 게인 필드 `AP+0x0C`(스레드 기준) 인용과 모순이 없다. 산수도 맞다
   (`0x1404e568c − 0x1404e55a0 = 0xEC`, `− 0x1404e55a8 = 0xE4`).
   덤: PR #8 이 `lea rbx,[rcx+8]` 을 `0x1400c0cb4` 로 적던 자리를 지워, 같은 명령을 `0x1400c0ca6`(`:166`)
   과 두 주소로 부르던 **자기모순도 함께 사라졌다.**
2. **밴드 축약은 정본대로 MAX 다.** `AudioSpectrum.spectrum`(`:371`)의 `if b >= 0, b < bandCount, v > out[b] { out[b] = v }`,
   `AudioSpectrum16.groupMax`(`:32-45`), `AudioSpectrumProcessor` 의 ⑨⑩ 2단 `maxss` 전부 일치.
   0 입력 경로에 log/나눗셈이 없다 — 재현:
   `grep -n "log(\|log10\|logf" Sources/WapleCore/AudioSpectrum{,16,Processor}.swift Sources/WapleRender/SystemAudioSpectrumProvider.swift | grep -v log2n`
   → 히트는 `AudioSpectrumProcessor.swift:73` 의 **주석 한 줄뿐**(실코드 0건).
   `Float` 언더플로는 **전수 미검증**: 엔벨로프 하강이 선형 슬루(초당 0.5)라 지수 점근이 없고
   스냅 epsilon `1e-4`(`AudioSpectrumProcessor.swift:101`)가 목표에 붙으면 바로 앉히므로
   비정규수 도달 경로를 못 만들었다 — 그래도 전수로 확인한 것은 아니다.
   나눗셈 발산은 `peakEnvelopeFloor = 0.001`(`AudioSpectrumProcessor.swift:99`)이 막고,
   `bandOfBin`/`binCount`/`windowLength`/`engineFFTLength` 는 전부 `safeInt` 가드를 태운다.
3. **ffmpeg 인자 주입은 성립하지 않는다.** `arguments(input:output:)`(`FFmpegConverter.swift:101-105`)
   에서 소스 경로는 항상 `-i` 의 **값 자리**라 `-` 로 시작해도 옵션으로 해석되지 않고, 출력은
   `cacheDir()/<uuid>.part.mp4` 절대경로다. 절대경로(`/` 시작)라 ffmpeg 프로토콜 접두 판정에도 안 걸린다.
   프로세스 고아화는 `runOnce`(`:197-218`)가 SIGTERM→5초→SIGKILL 로 에스컬레이션한다.
4. **`preparedConversionURL` 트랜잭션(PR #8 신설)에 이중 completion·중복 변환은 없다.**
   `VideoPreparationBatch.init`(`AppLogic.swift:190-194`)이 소스를 중복 제거하고,
   `applyResolved` 는 종단 경로에서 `completion` 을 부르지 않으며(`AppDelegate.swift:813-819` — `markApplyResult` + `return .applied`/`.failed` 뿐),
   `.failed`/`.ready` 어느 쪽도 `pendingVideoPreparation` 을 흘리지 않는다
   (`completePendingRendererApply`(`AppDelegate.swift:580-587`, `:585`)가 nil 로 비운다).
5. **`AudioInputSettings.defaults` 주입(PR #8 신설)은 위생적이다.** 소비처가
   `AudioInputPipelineTests.swift:20/24` 한 곳뿐이고 setUp/tearDown 이 대칭이며 suite 이름에
   pid+UUID 가 들어간다. 프로덕션 읽기는 `volumeSetting`/`thresholdSetting` 두 곳뿐이다.
6. **웹 브리지의 JS 문자열 삽입은 안전하다.** `deliverRandomFileResponse`/`deliverDirectoryFilesAddedOrChanged`
   (`WebRenderer.swift:711-722`)와 미디어 배달(`:760`)이 전부 `JSONEncoder` 리터럴을 거친다.
   `WebCompatPatch.load`(`WebCompatPatch.swift:123-126`)의 파일명 조각도 `sanitizedProjectID`(`:137`)가
   `..`·구분자·널·빈 문자열을 끊는다.
7. **`VideoRenderer` 의 볼륨/배속은 라이브 반영이 맞고 mkv/webm 재변환을 다시 타지 않는다**
   (`VideoRenderer.swift:356-367` — `player.volume`/`isMuted`/`defaultRate` 직접 대입, 리마운트 없음).
   L7-1 은 그 **자매 경로(WebRenderer.videoFallback)** 가 빠진 것이지 이쪽 결함이 아니다.

---

## 이 라운드에서 **보지 않은** 레인 파일 (브리핑의 "이미 훑은 자리를 같은 방식으로 다시 훑지 마라" 규칙)

`WebHardPauseJS.swift` · `WallpaperBridgeJS.swift`(표면 목록만 확인) · `WebInputProxyView.swift` ·
`SceneAudioPlayer.swift` · `AudioResponse.swift` · `ArtworkColors.swift` · `OggVorbis/` ·
`VideoFallbackHTML.swift` 는 PR #8 이 **한 줄도 만지지 않았고**(`git show b883386e --stat` 에 부재)
직전 감사가 이미 훑은 자리라 재검증 대신 위 다른 각도(설정 라이브 반영 · 캡처 결정성 · 서브프로세스
캐시)에 시간을 썼다. `WallpaperSchemeHandler` 의 적대적 경로 입력 14종도 그 코드가 **변하지 않았으므로**
(PR #8 은 동시성 구조만 바꿨고 `parseRangeHeader`/`fileURL(forRequestPath:)`/`WallpaperPathSecurity` 는
`nonisolated` 표기 외 무변경) 재검증하지 않았다.
