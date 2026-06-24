# Waple — Web 타입 배경화면 지원 (설계 문서)

- 작성일: 2026-06-24
- 상태: 설계 확정 대기 (사용자 리뷰 전)
- 선행: `2026-06-24-waple-video-wallpaper-design.md` (Video MVP — `WallpaperRenderer` 프로토콜,
  `RendererFactory`, `DesktopWindowController` 가 이미 존재)
- 범위: **Web 타입 1종** 추가 + **webm 영상 폴백**(덤). Scene 은 별도 사이클.

---

## 1. 개요 / 목표

Wallpaper Engine 의 `type: "web"` 배경화면(HTML/CSS/JS)을 macOS 데스크탑 라이브 배경으로 렌더한다.
기존 `WallpaperRenderer` 이음새에 `WebRenderer`(WKWebView)를 끼워 넣는다.

부수 효과: WKWebView 가 VP9 를 디코드하므로, AVFoundation 이 못 여는 **webm 영상 배경**을
같은 WebRenderer 로 폴백 재생한다(Video MVP 에서 남긴 코덱 격차 해소).

---

## 2. 핵심 결정 사항

| 항목 | 결정 |
|---|---|
| WE JS 브릿지 깊이 | **풀 WE Web API** 중 macOS 에서 현실적인 부분: 속성 주입 + **실시간 오디오 스펙트럼** + 파일 속성. |
| 미디어 "지금 재생 중" | **이번 사이클 보류**. 리스너는 no-op 스텁(배경이 등록해도 안 깨짐). 사유: macOS 는 비공개 MediaRemote 필요·신규 OS 취약. |
| 시스템 하드웨어 스탯(CPU/RAM/GPU) | **범위 밖.** WE 표준 API 아님(작성자 외부 툴 의존). 없으면 우아하게 실패. |
| 로컬 자산 서빙 | **`WKURLSchemeHandler`** 로 배경 폴더를 단일 커스텀 스킴에 same-origin 서빙. `file://` 금지(= `fetch`/XHR 깨짐), 비공개 file-access 키 금지. |
| 가림 스로틀링 | WKWebView 가 데스크탑-레벨 창을 "가려짐"으로 오인해 rAF/타이머를 throttle → **얼어붙음** 가능. **조기 검증 게이트**로 두고, 발생 시 가림-스로틀 해제. |
| 오디오 캡처 | **ScreenCaptureKit**(SCStream, macOS 13+) 시스템 오디오 → vDSP FFT → 128 floats. "화면 기록" 권한 프롬프트 발생(불가피). |
| `.app` 패키징 | 오디오 TCC 가 번들 ID+서명에 귀속되므로 **이번 사이클에 `.app` + ad-hoc 서명** 진입(오디오 직전 Phase). |
| webm 폴백 | 포함. `type:"video"` + 미지원 코덱 → `WebRenderer`(영상 폴백 모드)로 라우팅. |
| 속성 편집 UI | **범위 밖.** general.properties **기본값만 주입**(편집 UI 는 향후). |

---

## 3. 정찰 / 배경

### 3.1 사용자 라이브러리의 웹 배경 (`3115349801`)
`index.html` + `style.css` + `js/{event,time,script,script-p5,visualizer,animation}.js` +
`jquery.min.js` + `jquery.easing.min.js` + `p5.js` + `.ttf` 폰트 + `wallpaper.jpg`.
`general.supportsaudioprocessing: true`, properties 37개. 오디오 비주얼라이저(p5.js) +
CPU/RAM 모니터(작성자가 `localhost:5000` 외부 툴 가정 → 우리 대상 아님).
`.history/`·`.vscode/` 는 작성자 잔여물 → 무시.

### 3.2 WE Web Wallpaper JS API (브릿지가 제공할 표면)
배경 페이지가 기대하는 전역. 우리가 **제공/호출**하는 것:
- `window.wallpaperPropertyListener` — 배경이 정의하는 객체. 우리가 호출:
  - `applyUserProperties(props)` — `props = { key: { value, type } }`. 색상 `value` 는 `"r g b"` 0–1 문자열.
  - `applyGeneralProperties(props)` — 예 `{ fps, language }`.
  - `setPaused(bool)`.
- `window.wallpaperRegisterAudioListener(cb)` — `cb(Array(128) of Float)` (64 L + 64 R). 매 프레임 호출.
- `window.wallpaperRequestRandomFileForProperty(name, cb)` — `cb(name, filePath)`.
- **no-op 스텁**: `wallpaperRegisterMediaStatusListener`, `wallpaperRegisterMediaPropertiesListener`,
  `wallpaperRegisterMediaThumbnailListener`, `wallpaperRegisterMediaTimelineListener`,
  `wallpaperRegisterMediaPlaybackListener` (등록만 받고 아무것도 안 함).

### 3.3 general.properties 스키마 (속성 파서 대상)
항목 = `key → { type, value, text, order, ... }`. type: `color, bool, slider, combo, text,
textinput, file, checkbox, scenetexture, replacetexture, group`. 부가: `min/max/step/precision`
(slider), `options`(combo), `condition`(가시성 식 — MVP 는 **보존만**, 평가 안 함).
**색상 = 공백 구분 0–1 실수 3개 문자열** (`"0.61 0.48 0.30"`, hex/255 아님).

---

## 4. 아키텍처

속성 파싱만 `WapleCore`(순수·테스트 가능), 렌더·웹·오디오는 `WapleRender`
(WebKit/ScreenCaptureKit/Accelerate). 데스크탑 창은 기존 `DesktopWindowController` 재사용.

```
AppDelegate.apply(project)
  └─ RendererFactory.makeRenderer(for: project)   // 타입+코덱 라우팅(리팩터)
       ├─ .video + 지원 코덱  → VideoRenderer        (기존)
       ├─ .video + 미지원 코덱→ WebRenderer(.videoFallback)
       └─ .web               → WebRenderer(.web)
WebRenderer (WKWebView)
  ├─ WallpaperSchemeHandler  (waple-asset://wallpaper/<path> → 폴더 파일, same-origin)
  ├─ wallpaper-bridge.js     (documentStart 주입: propertyListener/audioListener/requestRandomFile/미디어 no-op)
  ├─ WallpaperProperties     (WapleCore: general.properties → 기본값 → applyUserProperties)
  └─ SystemAudioSpectrumProvider (SCStream→vDSP FFT→128 floats→evaluateJavaScript 콜백)
VideoFallbackHTML (순수: 파일명 → <video loop muted autoplay> HTML)
```

---

## 5. 컴포넌트 상세

### 5.1 `WallpaperProperties` (WapleCore — TDD)
- `struct WallpaperProperty: Equatable { key, type, rawValue, order, min?, max?, step?, options?, condition? }`
- `static func parse(generalProperties: [String: Any]) -> [WallpaperProperty]` — 방어적.
- `static func parse(folderURL: URL) throws -> [WallpaperProperty]` — project.json 의 `general.properties` 읽어 위 호출.
- `static func weUserPropertiesJSON(_ props: [WallpaperProperty]) -> String` — `{ key: { value, type } }`
  형태 JSON. 색상은 `"r g b"` 유지, bool/number 는 그대로. (기본값 주입용)
- `WallpaperProject` 모델은 그대로 둔다(properties 필드 미추가) — 결합도 낮춤. 웹 렌더러가 폴더에서 재파싱.

### 5.2 `WallpaperSchemeHandler` (WapleRender — 수동)
- `WKURLSchemeHandler`. 스킴 `waple-asset`, 호스트 `wallpaper`. `waple-asset://wallpaper/<relpath>`
  → `folderURL/<relpath>` 파일을 읽어 응답. MIME 은 `UTType(filenameExtension:)`.
- **경로 이탈 방지**: 정규화 후 folderURL 하위가 아니면 404.
- 모든 자산이 한 origin → JS `fetch('./config.json')` 등 정상.

### 5.3 `wallpaper-bridge.js` (리소스 — 수동)
- `WKUserScript`(documentStart, mainFrame). `window.wallpaperRegisterAudioListener` 는 콜백을
  보관; 네이티브가 `__wapleAudio(frame)` 로 밀어 넣으면 보관된 콜백 호출. 미디어 등록은 no-op.
  `wallpaperRequestRandomFileForProperty` 는 `webkit.messageHandlers` 로 네이티브에 요청.
- 속성 기본값은 로드 후 네이티브가 `evaluateJavaScript` 로
  `window.wallpaperPropertyListener?.applyUserProperties(<json>)` 및 `applyGeneralProperties({fps:30})` 호출.

### 5.4 `WebRenderer: WallpaperRenderer` (WapleRender — 수동)
- `init(mode: Mode)` where `enum Mode { case web; case videoFallback }`.
- `mount(in:project:)`:
  - `WKWebViewConfiguration` 에 스킴 핸들러 + `WKUserContentController`(브릿지 스크립트 + 메시지 핸들러) 설정.
  - WKWebView 를 컨테이너에 채움(autoresizing). **가림 스로틀링 해제** 처리.
  - `.web`: `waple-asset://wallpaper/index.html`(project.fileName) 로드 → didFinish 시 속성 기본값 주입 →
    `SystemAudioSpectrumProvider` 시작(가능 시).
  - `.videoFallback`: `VideoFallbackHTML.html(forVideoFile: project.fileName)` 를 baseURL=스킴으로 로드.
  - fileName 없음/파일 없음 → `RendererError.assetMissing`.
- `pause()`/`resume()`: `setPaused(true/false)` 호출 + 오디오 일시정지 + (가능 시)미디어 일시정지.
- `teardown()`: 오디오 정지, WKWebView 제거.

### 5.5 `SystemAudioSpectrumProvider` (WapleRender — 수동, 일부 순수 TDD)
- `SCStream`(`capturesAudio = true`) 로 시스템 오디오 PCM 수신 → 윈도잉 → `vDSP` 실수 FFT →
  크기 스펙트럼 → **128 bin 매핑·정규화** → `onFrame([Float])` (~60fps).
- 권한 거부/`SCShareableContent` 실패 → 0 배열 공급(배경은 계속 렌더). 크래시 X.
- 순수 분리: `static func spectrum(fromMagnitudes: [Float], binCount: Int = 128) -> [Float]` → **TDD**.

### 5.6 `VideoFallbackHTML` (WapleRender — TDD, 순수)
- `static func html(forVideoFile name: String) -> String` → 전체화면 `<video loop muted autoplay
  playsinline>` (src = `waple-asset://wallpaper/<URL인코딩된 name>`, `object-fit: cover`, 검은 배경).

### 5.7 `RendererFactory` 리팩터 (WapleRender — TDD)
- `static func makeRenderer(for project: WallpaperProject) -> WallpaperRenderer?`
  - `.video`: `VideoRenderer.isSupportedContainer(folderURL/fileName)` ? `VideoRenderer()` : `WebRenderer(mode: .videoFallback)`
  - `.web`: `WebRenderer(mode: .web)`
  - 그 외: `nil`
- `isSupportedContainer(_ url: URL)` 는 순수 판별자로 유지(단위 테스트 그대로).
- 기존 `makeRenderer(for: WallpaperType)` 호출부(AppDelegate, 기존 테스트)는 새 시그니처로 갱신.

---

## 6. 데이터 흐름

- **웹 적용**: 파싱(type=web) → 팩토리 → `WebRenderer(.web).mount` → 스킴 핸들러 서빙 + 브릿지 주입 →
  index.html 로드 → didFinish: 속성 기본값 주입 + 오디오 시작 → 매 프레임 스펙트럼을 콜백으로 전달.
- **webm 적용**: 파싱(type=video, file=*.webm) → 팩토리가 미지원 코덱 감지 → `WebRenderer(.videoFallback).mount`
  → 생성 HTML 로드 → `<video>` 루프 재생(음소거).

---

## 7. 에러 처리 / 우아한 강등

| 상황 | 처리 |
|---|---|
| WKWebView 내비게이션 실패 | 안내 로그, 무크래시 |
| 오디오 권한 거부 / 미번들(bare 실행) | 스펙트럼 0 공급, 배경은 계속 렌더 |
| index.html / 영상 파일 없음 | `RendererError.assetMissing` |
| 미디어 리스너 등록 | no-op(등록만 수락) |
| 시스템 스탯 요청(localhost 등) | 우리가 안 띄움 → 배경 측에서 조용히 실패 |
| 스킴 경로 이탈 | 404 응답 |

---

## 8. 빌드 순서 (Phase 분할)

오디오는 `.app`+서명을 요구하므로, bare 실행 파일로 검증 가능한 것을 먼저.

**Phase 1 — bare 실행 파일로 검증 (전체의 ~70%)**
1. `WallpaperProperties` 파싱/인코딩 (TDD)
2. `VideoFallbackHTML` (TDD) + `RendererFactory` 리팩터 (TDD)
3. `WallpaperSchemeHandler` + `WebRenderer` 코어 + `wallpaper-bridge.js`(오디오 제외) + 속성 주입
4. **게이트 G1/G2** 실측(아래) — 실제 배경 `3115349801` 및 webm 으로 검증

**Phase 2 — `.app` 필요**
5. `.app` 번들 패키징 + ad-hoc 서명(안정 식별자)
6. `spectrum(fromMagnitudes:)` (TDD) → `SystemAudioSpectrumProvider` → 오디오 배선
7. **게이트 G3** 실측

---

## 9. 조기 검증 게이트 (수동)

- **G1 (서빙)**: `3115349801` 이 WebRenderer 에서 로드되고, JS `fetch` 가 같은-origin 으로 동작
  (콘솔에 origin/fetch 에러 없음, 정적 자산·폰트 로드됨).
- **G2 (가림 스로틀링 — Darwin 27 게이트)**: 데스크탑이 보이는 상태에서 웹 배경 애니메이션이
  **계속 갱신**되는지(얼지 않는지). 얼면 가림-스로틀 해제 적용 후 재확인.
- **G3 (오디오, Phase 2)**: `.app` 에 화면 기록 권한 부여 후 비주얼라이저가 소리에 반응.

---

## 10. 테스트 전략

- **TDD(WapleCore)**: `WallpaperProperties` — color/bool/slider/combo/text 파싱, `weUserPropertiesJSON`
  형태(색상 `"r g b"`), 기본값 추출, condition 보존.
- **TDD(WapleRender 순수)**: `VideoFallbackHTML.html(forVideoFile:)` (태그/속성/스킴 URL·인코딩),
  `spectrum(fromMagnitudes:)` (길이 128·정규화·빈 입력), `RendererFactory.makeRenderer(for:)` 라우팅
  (web→WebRenderer, video mp4→VideoRenderer, video webm→WebRenderer, scene→nil).
- **수동**: WebRenderer 렌더·fetch(G1)·가림(G2)·오디오(G3), webm 폴백 재생.

---

## 11. 범위 밖 / 향후

- 미디어 "지금 재생 중"(MediaRemote) — 별도 사이클.
- 시스템 하드웨어 스탯 — WE API 아님(미지원).
- 속성 **편집** UI(general.properties → 컨트롤; condition 가시성 평가) — 향후(Video 스펙 §8 과 공유).
- Scene 타입 — 별도 대형 사이클.
- 자원 절약(가림/배터리) — Video 스펙과 공유된 향후 항목.
- Core Audio process tap(macOS 14.4+, 덜 위협적인 권한) — v13 플로어 유지 위해 보류, 트레이드오프만 기록.

---

## 12. 리스크 / 미해결

- **가림 스로틀링(G2)** 이 최대 미지수 — Darwin 27 에서 실측 전까지 미확정.
- **TCC/번들**: ad-hoc 서명 `.app` 은 리빌드 시 해시 변동으로 권한 재요청 가능 → 안정 식별자로 ad-hoc 서명.
- **브릿지 충실도**: WE 콜백 계약을 실 배경 1종(`3115349801`)으로만 검증 가능 — 다른 배경에서 깨질 여지.
- "화면 기록" 프롬프트가 배경앱 맥락에선 낯섦(UX 비용) — ScreenCaptureKit 특성상 불가피.
