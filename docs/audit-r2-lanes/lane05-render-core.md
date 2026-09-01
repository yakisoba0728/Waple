# 레인 5 — Metal 렌더 파이프라인 본체 (PR #8 `b883386e` 사후 감사)

대상: `SceneRenderer.swift`(±676) · `SceneRendererFrameEncoder.swift`(+785) ·
`SceneRendererResources.swift`(±79) · `RendererFactory.swift`(±7) · `SceneRenderSettings.swift`(무변경) ·
`SceneRendererFinalizer.swift`(무변경) · `SceneLivePresentationFix.swift`(무변경) ·
`OffscreenCapture.swift`(무변경) · `WallpaperRenderer.swift`(무변경)

읽기 전용 · 빌드 미실행. 재현 명령은 모두 리포 루트(`/Users/yakisoba0728/Documents/GitHub/Waple`)에서 실행.
비교용 부모 스냅샷:
`git show b883386e^:Sources/WapleRender/SceneRenderer.swift > /tmp/old_SceneRenderer.swift`

---

## PR #8 이 이 레인에서 한 일 (요약)

1. **카메라 시차 전면 재구현** — `cameraOffset/targetCameraOffset`(NDC, `maxShift=0.1` 상한) →
   `parallaxFocus`(정사영 픽셀 초점) + `parallaxPosition`(`g_ParallaxPosition`) 2상태.
   레이어 이동은 `SceneCameraMath.parallaxLayerOffset` = `amount·(rootOrigin−focus)·rootDepth`.
2. **draw/interaction 기하 통일** — 마운트의 이름 매칭 `hoverEngineLayers` 폐기 →
   `hoverEngineOwners`(디스크립터 인덱스) + `interactionGeometry` 단일 조립부 +
   `pendingInteractionGeometry` → `presentInteractionGeometry()` 프레임말 승격.
3. **레이어 `perspective` 실구현** — x/y 각 + `originZ` + near/far Sutherland–Hodgman 클립 +
   `projectiveDepth`(clip-space w 복원, `v_main` buffer 5) + `projectedHitPolygon`.
4. **`camerashake` 근사 폐기** — 2주파 사인 합(`shakeNDCScale=0.03`) → `SceneCameraMath.shakeDelta`
   실측식. `cameraOriginPanOffset`(2px 데드존) → `cameraEyeNDCOffset`(데드존 없음, y 부호 반전).
5. **REFRACT 레이어 경로 통합** — `encodeRefractLayer` 독립 사본 → `encodeLayer(refractDraw:)` 위임.
6. `RendererFactory.makeRenderer(preparedVideoURL:)` 추가(비디오 사전변환 주입 — 이 레인 무관).

---

# 발견

### [🟠] `orthographicScene` 게이트가 마운트와 프레임 승격에서 **서로 다르다** — 비-정사영 2D 폴백 씬에서 정적 레이어만 영구 `.unhittable`
- 자리:
  - `Sources/WapleRender/SceneRenderer.swift:621` — `interactionGeometry` 최상단
    `if !orthographicScene { return (.unhittable, none, none) }` (전 descriptor 무조건 닫음)
  - `Sources/WapleRender/SceneRendererFrameEncoder.swift:1656-1705` — `encodeLayer` 승격 블록에
    `orthographicScene` 검사가 **없다**(`!def.isSolid` → `def.perspective` → `.object(quad)`)
  - `Sources/WapleRender/SceneRendererFrameEncoder.swift:2128-2166` — `encodeText` 승격도 동일하게 무게이트
  - `Sources/WapleRender/SceneRenderer.swift:2204` — `orthographicScene = doc.orthographic`
  - `Sources/WapleCore/SceneDocument.swift:1858` —
    `orthographic = orthoAuto || (orthoSize.map { $0.w != 0 && $0.h != 0 } ?? false)`
  - `Sources/WapleRender/SceneRenderer.swift:2031` — `is3D = !meshRenderables.isEmpty || !billboards.isEmpty`
- 근거/재현:
  ```
  grep -n "orthographicScene" Sources/WapleRender/*.swift
  #  SceneRenderer.swift:621  / :746 / :1380 / :2204 / :2994 / FrameEncoder:1013  ← 승격부엔 없음
  grep -rn "pendingInteractionGeometry\[" Sources/WapleRender/
  #  FrameEncoder:1704(image) · 2165(text) · SceneRenderer3D:1631/1759/2207(billboard, is3D 전용)
  ```
  `orthographic == false` **그리고** `is3D == false` 조합이면 승격자가 3D 빌보드뿐이라 아무도 안 돈다.
  이 조합은 도달 가능하다 — 리포 자신이 "projection 이 0인 씬(파서는 명시적 0을 그대로 통과시킨다)"의
  존재를 `SceneRendererResources.swift:363-366` 주석으로 명시하고, `w==0||h==0` 이면 위 파서 식이
  `orthographic=false` 를 낸다. 3D 자산이 없으면 `build3D` 가 비어 `is3D=false` → 2D 경로.
- 왜 문제인가: 그런 씬에서 `buildPointerTargets`/`buildHoverTargets` 가 만든 타깃이 전부
  `.unhittable` 이 되어 cursorEnter/Leave/Move/Down/Up/Click 이 **한 건도 배달되지 않는다**(PR #8 이전엔
  투영 종류와 무관하게 `.object(quad)` 였다 — `git show b883386e -- Sources/WapleRender/SceneRenderer.swift`
  의 구 `buildPointerTargets` 참조). 게다가 `encodeLayer` 승격은 게이트가 없어 **애니/스크립트를 가진
  레이어만** 첫 프레임에 히트 박스가 되살아난다 — 같은 씬 안에서 "정적 레이어는 클릭 불가, 애니 레이어는
  클릭 가능"이라는 자의적 분기가 생긴다. 같은 게이트가 `renderCameraParallaxOffsetPixels`
  (`SceneRenderer.swift:1380`)에도 걸려 그 씬은 시차 이동도 통째로 죽는다.
- 기지 목록 대조: 해당 없음(PR #8 신규).
- 미확인: 코퍼스 부재(`WAPLE_REAL_PKGS` 미설정)라 실제 도달 씬 수는 못 셌다. 코드 경로 도달성만 확정.

---

### [🟠] `g_ParallaxPosition` 이 `cameraparallax:false` 씬에서 **영구 (0,0)** — 정본이 말하는 중립은 (0.5,0.5)
- 자리:
  - `Sources/WapleRender/SceneRenderer.swift:1227` — `var parallaxPosition = SIMD2<Float>(0, 0)`
  - `Sources/WapleRender/SceneRenderer.swift:1314-1315` — `advanceCameraParallax` 첫 줄
    `guard parallaxEnabled else { return false }` (= 유일한 `parallaxPosition` 기록자)
  - `Sources/WapleRender/SceneRendererFrameEncoder.swift:71` —
    `e[80] = parallaxPosition.x; e[81] = parallaxPosition.y  // g_ParallaxPosition`
  - 정본: `Sources/WapleCore/SceneGeometry.swift:163-166`
    "`g_ParallaxPosition`(renderState+0x9c) — `clamp01(focus / 정사영크기)`.
     **무저작 2D 씬(eye=(0,0), infl=0)은 정확히 `(0.5, 0.5)` 다.**"
- 근거/재현:
  ```
  grep -n "parallaxPosition" Sources/WapleRender/SceneRenderer.swift
  #  1227(선언) · 1328(advanceCameraParallax 안) · 2751-2756(capture 저장/복원) · 2987(teardown)
  #  → parallaxEnabled==false 면 1328 이 절대 실행되지 않는다.
  git show b883386e^:Sources/WapleCore/GLSLTranslator.swift | grep -n g_ParallaxPosition
  #  1605: if name == "g_ParallaxPosition" { return "eng.timeAndPad.yz" }   ← 구: 포인터 슬롯 별칭
  grep -n g_ParallaxPosition Sources/WapleCore/GLSLTranslator.swift
  #  1613: ... { return "eng.parallaxAndPad.xy" }                           ← 신: 전용 슬롯
  ```
- 왜 문제인가: PR #8 이 `g_ParallaxPosition` 을 포인터 슬롯 별칭에서 전용 슬롯으로 분리하면서,
  시차가 꺼진 씬에는 그 슬롯을 채우는 코드를 두지 않았다. (구 별칭 `eng.timeAndPad.yz` = `pointerUV`
  도 정본값은 아니었다 — 마우스를 따라다녔다. 그래도 그건 0..1 범위를 **돌아다니는** 값이라
  `*2−1` 후 −1..1 을 훑었고, 지금은 **(−1,−1) 최대 편향에 영구 고정**된다는 점이 더 나쁘다.) 인트리 WE 자산
  `Resources/WEAssets/effects/depthparallax/shaders/effects/depthparallax.vert:44`
  가 `vec2 prlxInput = g_ParallaxPosition * 2 - 1;` 을 하므로 중립 (0.5,0.5)→(0,0) 이어야 할 입력이
  (0,0)→**(−1,−1)** 로 들어간다(같은 이펙트의 preview frag:67/71/75 도 동일 소비). 즉 `cameraparallax`
  를 끈 씬의 depthparallax 이펙트가 최대 편향으로 고정된다.
- 기지 목록 대조: 해당 없음(PR #8 신규 — 슬롯 자체가 신설).
- 판단 유보 지점: `CameraMotion.swift:475-477` 은 "시차가 꺼져 있으면 `nil` — 실물은 이 슬롯을
  갱신하지 않는다(생성자 값이 남는다)" 라고만 적고 **그 생성자 값이 얼마인지는 정본에 없다.**
  (0,0)이 옳다는 근거도 (0.5,0.5)가 옳다는 근거도 이 리포 안에는 없다 — 그 공백 자체가 문제다.

---

### [🟠] 마운트 시 `parallaxFocus` 가 중립(캔버스 중앙)이 아니라 (0,0)이라, `cameraparallaxdelay>0` 씬은 매 마운트마다 반 화면을 미끄러져 들어온다
- 자리:
  - `Sources/WapleRender/SceneRenderer.swift:1224` — `var parallaxFocus = SIMD2<Float>(0, 0)`
    (주석: "생성자/마운트 기본은 0")
  - `Sources/WapleRender/SceneRenderer.swift:2987` — `teardown`: `parallaxFocus = .zero`
  - `Sources/WapleRender/SceneRenderer.swift:1314-1339` — `advanceCameraParallax`
  - `Sources/WapleRender/SceneRenderer.swift:2396-2400` — `updateParallax` 는 `parallaxDelay <= 0`
    일 때만 `advanceCameraParallax` 를 부른다(즉 delay>0 은 마운트~첫 draw 사이에 초점 프라임이 없다)
  - 정본: `Sources/WapleCore/SceneGeometry.swift:107-118` `parallaxFocus`
    (`infl=0` ⇒ `(W·0.5, H·0.5)`), `:157-160` `parallaxLayerOffset` = `amount·(origin−focus)·depth`
- 근거/재현 (계산):
  - `parallaxAmount` 기본 0.5(`SceneCameraMath` 소비, 파스 기본
    `Sources/WapleCore/SceneDocument.swift:1877` `?? 0.5`), `projW=1920` 가정.
  - 중립 초점 = 960. 마운트 초점 = 0. ⇒ 프레임 0 의 레이어 오프셋 오차 =
    `amount · 960 · depth` = **480 px**(amount 0.5, depth 1). NDC 로 `2·480/1920 = 0.5`.
  - `parallaxAlpha(dt, delay) = min(1, 10·(1−delay/3)·dt)`(`SceneGeometry.swift:138`).
    코퍼스 최빈 `delay=0.1`, 60 Hz ⇒ α≈0.161/frame ⇒ 실효 시상수 τ=0.3/(3−0.1)≈0.103 s.
    → 마운트 직후 약 0.3 s 동안 씬 전체가 최대 480 px 미끄러진다.
  - PR #8 이전: `cameraOffset` 이 0 에서 시작했고 오프셋 식이 `cameraOffset × depth` 라 **0 = 무이동**이
    중립이었다(`git show b883386e -- Sources/WapleRender/SceneRenderer.swift`, 삭제된
    `targetCameraOffset`/`maxShift` 블록). 즉 "시작 상태 = 중립"이 "시작 상태 = 최대 편향"으로 뒤집혔다.
- 왜 문제인가: 라이브 마운트/스페이스 전환/리마운트마다 눈에 보이는 슬라이드-인이 생긴다.
  캡처 경로는 `captureFrames` 가 `parallaxFocus = .zero` 후 30 Hz 로 t 까지 리플레이하므로(`SceneRenderer.swift:2752-2757` + `:2833` `advanceCaptureCameraParallax`) 수렴 후 샘플링돼 영향이 없다 — 그래서 골든/픽셀 회귀로는 절대 안 잡힌다.
- 기지 목록 대조: 해당 없음(PR #8 신규).
- 주의: 이 시작값은 테스트가 **잠그고 있다** — `Tests/WapleRenderTests/CameraParallaxRenderTests.swift:83-89`
  가 `renderer.parallaxFocus = .zero` 후 한 프레임 진행이 0 초과임을 단언한다(단 `parallaxAmount = 0`
  이라 레이어 이동은 관측하지 않는다). 즉 의도된 선택일 수 있으나, 정본(중립=(W/2,H/2))과의 어긋남에
  대한 근거 주석·주소 인용이 이 파일에 하나도 없다.

---

### [🟡] M10 재발 — PR #8 이 **부모 시점에 정확했던** 줄 번호 인용을 자기 diff 로 전부 밀어냈다
- 자리 / 인용 → 부모(b883386e^)에서의 실제 줄 → 현재 실제 줄:
  | 인용하는 자리 | 인용 | 부모에서 | 지금 |
  | --- | --- | --- | --- |
  | `SceneRenderSettings.swift:58` | `SceneRenderer.swift:919` | **919 ✓** | 992 |
  | `SceneRenderSettings.swift:58` | `SceneRenderer.swift:2433` | **2433 ✓** | 2591 |
  | `SceneRenderSettings.swift:58` | `SceneRenderer.swift:2623` | **2623 ✓** | 2826 |
  | `SceneRenderSettings.swift:58` | `VideoRenderer.swift:200` | **200 ✓** | 215 |
  | `SceneRenderer.swift:57` | `startClickMonitorIfNeeded`(`:878`) | **878 ✓** | 943 |
  | `SceneRenderer.swift:944` | `startMediaPollingIfNeeded`(`:953`) | **953 ✓** | 1028 |
- 근거/재현:
  ```
  git show b883386e^:Sources/WapleRender/SceneRenderer.swift > /tmp/old_SR.swift
  grep -n "SceneRenderSettings.fitMode" /tmp/old_SR.swift          # 919, 2433, 2623
  grep -n "SceneRenderSettings.fitMode" Sources/WapleRender/SceneRenderer.swift   # 992, 2591, 2826
  git show b883386e^:Sources/WapleRender/VideoRenderer.swift | grep -n "SceneRenderSettings.fitMode"  # 200
  grep -n "SceneRenderSettings.fitMode" Sources/WapleRender/VideoRenderer.swift                       # 215
  grep -n "func startClickMonitorIfNeeded" /tmp/old_SR.swift Sources/WapleRender/SceneRenderer.swift   # 878 → 943
  grep -n "func startMediaPollingIfNeeded" /tmp/old_SR.swift Sources/WapleRender/SceneRenderer.swift   # 953 → 1028
  ```
- 왜 문제인가: `SceneRenderSettings.swift:55-62` 는 "fitMode 를 소비하는 자리는 이 5곳뿐"이라는
  **불변식 문서**다. 그 파일은 PR #8 diff에 **들어 있지도 않은데**(`git show --stat b883386e -- Sources/WapleRender/`)
  5개 중 4개가 무효가 됐다. 다음 사람이 그 목록을 신뢰하면 존재하지 않는 소비처를 읽는다.
  `SceneRenderer.swift:44-64` 의 캡처-오염 4항목 서술도 같은 방식으로 근거 링크를 잃었다.
- 기지 목록 대조: **M10 의 재발**(기지 항목은 "주석이 자기 diff 가 밀어낸 줄 번호 인용").
  단 위 6건은 "PR #8 이전에는 정확했다"가 검증된 신규 파손이라 M10 원본과 별건이다.

---

### [🟡] M10 미해결 잔존(재보고 아님, 상태 확인만)
PR #8 이전부터 이미 어긋나 있던 자기 인용이 그대로 남았고 값만 더 멀어졌다:
`SceneRenderer.swift:51`(`:2232`→2383) · `:944`(`:2217`→2368) · `:951`(`:2375`→2529) ·
`:422`(`mount:1534/:1569`→2260/2298) · `:2014`(`:1221`) · `:2255`(`:1129`) · `:2286`(`:1531`) ·
`:2446`(`:1604/:1634`→2913/2927) · `:1184`(`:242`) ·
`SceneRendererResources.swift:363`(`SceneRenderer.swift:1122`→1419) ·
`SceneRendererFrameEncoder.swift:405`(`:1113/:1119`) · `:478`(`:239-253`) · `:1606`(`:1056`) ·
`:2045`(`:1114`) · `:2514`(`:877`) · `:2755`(`runFrameBufferLayer:426`→407).
재현: 위와 같은 `grep -n "func <심볼>"` 대조.

---

### [⚪] 히트 박스의 카메라 병진 반영이 레이어 종류에 따라 갈린다
- 자리: `SceneRendererFrameEncoder.swift:1694-1705`(동적 이미지 — `frameShakeOffset` 을 `shakePixels`
  로 환산해 히트 쿼드에 굽는다) vs `SceneRenderer.swift:664-691`(마운트 조립 — 굽지 않는다) vs
  `SceneRendererResources.swift:566-569`(정적·비원근·비라이팅 레이어는 `def == nil` → 승격 대상 자체가 아님)
- 근거/재현: `grep -n "shakePixels" Sources/WapleRender/SceneRendererFrameEncoder.swift` → 1695·1700(이미지), 2157·2161(텍스트).
  `pendingInteractionGeometry` 를 쓰는 코드는 `if let def = layer.def` 안에만 있다(FrameEncoder:1656 `if let def = layer.def {`).
- 왜 문제인가: PR #8 로 `frameShakeOffset` 이 shake 뿐 아니라 **정적 `scene.camera.eye` + camera 오브젝트
  팬까지 포함하는 전역 2D 뷰 병진**이 됐다(`SceneRenderer.swift:2604-2606` `cameraEyeNDCOffset`).
  그래서 카메라가 움직이는 씬에서 애니 레이어의 히트 박스는 따라 움직이고 정적 레이어는 안 움직인다.
  PR #8 이전엔 **둘 다** 안 움직였으므로 회귀는 아니고 "반만 고침"이다.
- 기지 목록 대조: 해당 없음.

---

### [⚪] 캡처(30 Hz substep)와 라이브(프레임 dt)가 3D 카메라 스크립트를 서로 다른 횟수로 평가한다
- 자리: `Sources/WapleRender/SceneRenderer.swift:2779-2783`(캡처 3D — `advanceCaptureCameraParallax` 의
  substep 클로저 안에서 `prepareCamera3DFrame(at: sampleTime)`) vs `:2533`(라이브 — 프레임당 1회)
- 근거/재현: `sed -n '2775,2790p' Sources/WapleRender/SceneRenderer.swift`
- 왜 문제인가: `cameraparallaxdelay > 0` 인 3D 씬의 캡처는 `t` 까지 30 Hz 로 되밟으며 매 스텝
  카메라 스크립트를 평가한다(`t=6` → 180회). 스크립트가 shared 상태에 사이드이펙트를 남기면
  라이브(60 Hz, 1회/프레임)와 캡처의 shared 상태 궤적이 다르다. 캡처 자체는 결정적이므로
  A/B 게이트는 통과하지만 "캡처가 라이브를 대표한다"는 전제가 약해진다. 주석은 이 선택을
  명시하나 라이브와의 비대칭은 적지 않았다.
- 기지 목록 대조: 해당 없음.

---

# 브리핑 지정 항목별 판정

### 2. GPU 자원 수명·성능 — **문제 없음(PR #8 신규 결함 0)**
- per-frame `makeBuffer`: `DynamicVertexBuffer`(FrameEncoder:14-30)는 3슬롯 링 + 길이 부족 시에만
  재할당. PR #8 이 이 클래스를 건드리지 않았다. `device.makeBuffer`/`makeTexture` 의 프레임 내
  호출은 FrameEncoder 전체에서 26(링 버퍼) · 388/489(풀/슬롯 캐시)뿐.
  재현: `grep -n "device.makeBuffer\|device.makeTexture" Sources/WapleRender/SceneRendererFrameEncoder.swift`
- 세마포어/completed 핸들러: `grep -rn "addCompletedHandler\|DispatchSemaphore\|waitUntilCompleted\|MTLEvent\|makeFence" Sources/WapleRender/`
  → `SceneRenderer.swift:2814, 2905`(캡처 전용 `waitUntilCompleted`)뿐. `addCompletedHandler` 0건,
  캡처 순환 참조 0건, 세마포어 불균형 0건.
- ⚪ (기존, PR #8 무관): `DynamicVertexBuffer` 는 슬롯 3개를 **펜스 없이** 순환한다. MTKView 기본
  `maximumDrawableCount=3` 이면 N 프레임과 N+3 프레임이 같은 슬롯을 쓰므로 이론상 in-flight 덮어쓰기
  창이 있다. 부모 커밋과 동일하므로 이번 라운드 발견으로 올리지 않는다.

### 3. 일시정지·가림 상태기계 — **통일 유지, 재분열 없음**
- `pause()`(`SceneRenderer.swift:2913-2925`)가 `mtkView?.isPaused = true` 를 세우고
  `drawGateOccludedSince` 를 `scenePausedAt` 으로 인계한다. `resume()`(`:2927-2940`)이 역인계.
  `draw(in:)` 은 `handleOcclusionGate`(`:2500`) 뒤 `if occluded { return }`(`:2503`) 로 단일 게이트.
  `frameDelta(isPaused:)`(`:1358`)가 정지 중 dt=0 을 강제.
- PR #8 이 이 4자리를 건드리지 않았다(`git show b883386e -- Sources/WapleRender/SceneRenderer.swift`
  에 해당 hunk 없음). 새 코드가 추가한 `advanceCameraParallax`/`updateHover` 호출은 모두
  `occluded` 조기 return **뒤**에 있고, 자기 재드로 요청은
  `if cameraParallaxSettling, dt > 0, !shouldAnimate`(`:2537`)로 정지 중(dt==0) 무한 루프가 차단된다.
- **두 상태기계의 우선순위도 확인했다(과거 경합 이력의 재발 없음).**
  AppDelegate 쪽은 별도 채널이다 — `Sources/Waple/AppDelegate.swift:1085-1103` 의
  `occlusionTimer` 가 `visibilityMonitor.isDesktopVisible(threshold:)`(커버리지 임계) 를 폴링해
  `pauseGate.set(.occlusion, …)` → `applyPause`(`:1207-1216`) → `renderer.pause()/resume()` 를 부른다.
  렌더러 쪽은 `draw(in:)` 안의 `view.window?.occlusionState`(`SceneRenderer.swift:2499`) →
  `drawGateOccludedSince` 다. **두 플래그가 같은 값을 두고 다투지 않는다** —
  `handleOcclusionGate` 첫 줄이 `guard scenePausedAt == nil else { return }`
  (`SceneRenderer.swift:2432`)로 명시 정지에 우선권을 넘기고, `pause()`(`:2921-2922`)가
  `drawGateOccludedSince` 를 `scenePausedAt` 으로 인계한 뒤 `nil` 로 비운다. 단방향 인계다.
  재현: `grep -n "occlusion\|isPaused\|\.pause()\|\.resume()" Sources/Waple/AppDelegate.swift`
  (AppDelegate 자체의 상세 감사는 다른 레인 소관 — 여기서는 경합 유무만 확인했다.)

### 4. 동시성(`-strict-concurrency=complete`) — **정적 판정: 진단 감소 방향, 증가 근거 없음**
빌드 금지 조건에서의 마커 대조(부모 vs 현재). *컴파일러 진단 수가 아니라 대리 지표다.*

| 마커 | `SceneRenderer.swift` 부모 | 현재 | FrameEncoder | Resources |
| --- | --- | --- | --- | --- |
| `@MainActor` | 20 | 20 | 0 | 0 |
| `MainActor.assumeIsolated` | 9 | **12** | 0 | 0 |
| `nonisolated(unsafe)` | 2 | **3** | 0 | 0 |
| `@unchecked Sendable` | 4 | 4 | 0 | 0 |
| `Task {` / `@Sendable` / `DispatchQueue` | 0/0/1 | 0/0/1 | 0 | 0 |

- 신규 `nonisolated(unsafe)` 1건: `SceneRenderer.swift:13`
  `nonisolated(unsafe) private(set) var wapleIsAttachedToWindow`(`WapleMTKView`, `MTKView` 상속 =
  `@MainActor` 클래스의 저장 프로퍼티). 메인이 쓰고(`viewDidMoveToWindow`) 캡처 큐가 읽는다
  (`SceneRenderer.swift:2739`). 진단을 **만드는** 표기가 아니라 **끄는** 표기다.
- 신규 `assumeIsolated` 3건: `:2541`, `:2573`, `:2675` — 전부 `draw(in:)`(nonisolated,
  `MTKViewDelegate` 요구) 안에서 `@MainActor func updateHover`/`pointerSceneCoords`(`:977`)를 부른다.
  역시 진단 억제 쪽.
- **감소 방향의 실측 근거**: PR #8 이 `mount(in container: NSView, …)`(nonisolated) 안의
  `@MainActor` AppKit 프로퍼티 접근 `container.window` **3곳을 1곳으로 줄였다**(진입부에
  `let mountWindow = container.window` 1회, `:2019`/`:2259`/`:2297` 는 지역 변수 사용).
  재현: `grep -c "container.window" /tmp/old_SceneRenderer.swift` → 6(코드 3 + 주석 3),
  `grep -n "mountWindow\|container.window" Sources/WapleRender/SceneRenderer.swift` → 코드 1 + 주석 4.
- 새로 심은 백그라운드 AppKit/MTKView 접근·무동기 mutable static: **0건**.
  (`grep -rn "^\s*static var" Sources/WapleRender/SceneRenderer.swift Sources/WapleRender/SceneRendererFrameEncoder.swift` → 0)
- 결론: 기지 **H5**("SceneRenderer.swift 에 진단 25자리")는 PR #8 로 **줄었으면 줄었지 늘지 않았다**
  (`container.window` −2, 신규 격리 위반 0, 신규 억제 표기 +4). 파일은 2,859 → 3,073 줄로 커졌지만
  증가분은 전부 순수 계산/구조체 코드다. 정확한 진단 수는 `swift build` 없이는 확정 불가(브리핑 금지).

### 5. 줄 번호 자기인용 — 위 🟡 2건 참조(신규 6건 + 잔존 16건).

---

# 확인했지만 문제없던 것 (다음 라운드 시간 절약용)

1. **`pendingInteractionGeometry` 키 공간 정합.** 이미지 키 `layer.uid` 는 `doc.layers` 인덱스
   (`Resources:377` `for (uid, layer) in doc.layers.enumerated()`, 디코드 실패는 `continue` 라
   인덱스 불변), 텍스트 키 `sceneScriptImageLayerCount + t.uid`, `sceneScriptImageLayerCount =
   doc.layers.count`(`SceneRenderer.swift:2022`). `PointerTarget.descriptorIndex` 규약과 일치.
2. **텍스트 `quadDirty` 초기값을 `angleZ != 0` → `false` 로 바꾼 것은 회귀 아님.**
   `rasterize()`(`Resources:2540-2568`(`quadVertices` `:2554` · `quadProjectiveDepth` `:2561`))가 이제 `quadVertices`/`quadProjectiveDepth` 로 정적
   `angleZ`·`perspective`·`originZ`·x/y 각을 직접 굽는다(구 수기 `x0/y0` 경로 폐기).
3. **파티클/텍스트의 `depth=(1,1)` 하드코딩 + `renderCameraParallaxOffset(order:)`.**
   `doc.parallaxObjects` 는 `objects[]` **전건**을 담고(`SceneDocument.swift:1908-1917`),
   `cameraParallaxRootsByOrder()`(`:1776-1795`)가 order 전건에 root 를 채우므로 파티클도 커버된다.
   부모 없는 오브젝트는 root == self 라 저작 depth 가 그대로 보존된다.
4. **`quadProjectiveDepth` 산술.** `depth(x,y)=d−originZ−(R·(x−ax,y−ay,0)).z` 는 (x,y)에 affine 이라
   `w(u,v)=a·u+b·v+c` 한 식이 클립으로 새로 생긴 정점에도 성립한다. uv 매핑
   (uv.x: −hw→0/hw→1, uv.y: hh→0/−hh→1)과 `a`/`b` 부호도 일치. `angleX==angleY==0` 이면
   w 가 상수라 `enabled=0`(affine)이 정확히 옳다.
5. **`v_main` 정점 버퍼 5번 슬롯 실재.** `QuadShaders.swift:18`
   `constant float4& projectiveDepth [[buffer(5)]]`. REFRACT 경로도 `v_main` 공유라 안전.
6. **`updateParallax` 의 온디맨드 재드로 생존.** `SceneRenderer.swift:2412` `mtkView?.needsDisplay = true`
   가 남아 있고, `draw` 의 `cameraParallaxSettling` 게이트(`:2537`)가 정착까지 프레임을 이어 요청한다.
   `targetCameraOffset` 삭제로 인한 정지 결함 없음.
7. **`captureFrames` 의 라이브 상태 보존.** `preserveLiveInteraction`(`:2739-2748`)이
   pointer/hover/pending 3배열을, 별도 defer(`:2752-2757`)가 focus/position 2상태를 값 복사로 복원한다.
   defer 역순 실행이라 focus 복원 → interaction 복원 순서도 안전.
8. **`RendererFactory.makeRenderer(preparedVideoURL:)`** 는 기본값 `nil` 이라 기존 호출부 무영향.
   `FFmpegConverter.needsConversion` 가드가 사전변환 URL 오용을 막는다.
