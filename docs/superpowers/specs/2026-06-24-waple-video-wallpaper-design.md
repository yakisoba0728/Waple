# Waple — Wallpaper Engine 배경화면 macOS 구동 (설계 문서)

- 작성일: 2026-06-24
- 상태: 설계 확정 대기 (사용자 리뷰 전)
- 범위: **MVP = 동영상(Video) 배경화면**. 아키텍처는 씬/웹/프리셋까지 확장 가능하게 설계.

---

## 1. 개요 / 목표

Wallpaper Engine(Windows)에서 받은 배경화면 폴더를 macOS로 가져와, 네이티브 앱(Waple)으로
데스크탑 라이브 배경화면으로 렌더링한다.

워크플로:
1. 사용자가 Windows의 Wallpaper Engine에서 배경을 받는다.
2. 해당 워크샵 폴더(들)를 Mac으로 복사한다. (예: `packages/<workshopid>/`)
3. Waple에서 폴더를 가져오면, 타입에 맞는 렌더러가 데스크탑 배경으로 재생한다.

**최종 목표는 모든 WE 타입 지원이지만, 1차 구현은 동영상에 집중한다.**

---

## 2. 핵심 결정 사항

| 항목 | 결정 |
|---|---|
| 기술 스택 | **네이티브 Swift** (SwiftUI + AppKit + AVFoundation). 씬은 추후 Metal, 웹은 추후 WKWebView. |
| 배포 대상 | **공개 배포 앱**. 단, 빌드는 개인용 MVP부터 점진적. 배포는 Developer ID + 공증 경로(App Store 샌드박스 아님). |
| 지원 타입 | 최종: Video/Scene/Web 전부. **MVP: Video만.** 나머지는 인식하되 "지원 예정"으로 강등. |
| 라이브러리 UX | 라이브러리 + 썸네일 그리드 전환. |
| 저장 전략 | **원본 위치 참조** (security-scoped bookmark). GB 단위 중복 복사 회피. |
| 앱 형태 | **메뉴바 앱(MVP)**. 메뉴바에서 SwiftUI 라이브러리 창을 연다. 추후 풀 UI 앱으로 확장. |
| 멀티 모니터 | **MVP: 모든 화면 동일 배경.** 아키텍처는 화면별 설정 수용. |
| 자원 절약(가림/배터리 일시정지) | **MVP 생략.** 아키텍처는 후크 수용(렌더러 pause/resume). |

---

## 3. 정찰 결과 (Ground Truth)

실제 자산 두 폴더를 분석해 확정한 사실. (`/Users/yakisoba/Downloads/assets`, `/Users/yakisoba/Downloads/packages`)

### 3.1 `assets/` = WE 엔진 내장 공유 자산
사용자 배경이 아님. 셰이더·머티리얼·파티클·폰트·에디터 씬. **동영상 0개.**
MVP에는 직접 쓰지 않음. **씬 렌더링 구현 시** 참조할 공유 자산 루트(상대경로 폴백 대상)이며
`.tex`(`TEXV0005`), `scene.json`, GLSL 셰이더 포맷의 레퍼런스.

### 3.2 `packages/` = 실제 배경화면 42개 / 1.4GB
폴더명 = Steam Workshop 숫자 ID.

| 타입 | 개수 | 비고 |
|---|---|---|
| scene / Scene | 31 | `.pkg`(PKGV0001~0024) 안에 scene.json + .tex + .dxs. **대소문자 혼용.** |
| video | 9 | **전부 H.264(avc1) mp4. webm/VP9 0개.** AVFoundation 네이티브 재생 가능. |
| web | 1 | index.html + js/css + p5.js. WE JS 브릿지 필요. |
| (없음/프리셋) | 1 | `dependency`+`preset`로 다른 씬을 오버라이드. |

동영상 9개 상세: 해상도 1080p~4K, 세로형(1920×3200) 1개 존재, fps 24/25/30/60 혼재,
9개 중 8개가 AAC 오디오 트랙 보유(1개 무음).

### 3.3 `project.json` 스키마 (파서가 따라야 할 정확한 형태)

```jsonc
{
  "type": "video",            // video | scene | "Scene" | web | (없음=프리셋). 소문자로 비교할 것.
  "file": "wallpaper.mp4",    // 메인 자산 파일명(폴더 기준 상대). 프리셋엔 없음.
  "preview": "preview.jpg",   // 썸네일(jpg/gif/png). 항상 존재. gif는 애니메이션.
  "title": "...",             // 표시명. 비ASCII(한/중/일) 흔함.
  "description": "...",       // \r\n, BBCode, HTML 섞일 수 있음.
  "tags": ["Anime"],
  "contentrating": "Everyone",// 또는 "Mature", 없을 수도.
  "workshopid": "2913506072", // 없을 수도. 폴더명과 동일.
  "workshopurl": "steam://url/CommunityFilePage/<id>",
  "general": {
    "supportsaudioprocessing": true,   // 웹 등.
    "properties": { /* 사용자 설정 항목들 */ }
  },
  "dependency": "2593802559", // 프리셋 전용: 기반 배경 ID(로컬에 없을 수도).
  "preset": { /* 프리셋 전용: 기반 properties 오버라이드 */ }
}
```

`general.properties` 항목 타입: `color, bool, slider, combo, text, textinput, file, checkbox,
scenetexture, replacetexture, group`. 색상값은 **0~1 실수 3개를 공백으로 구분한 문자열**
(`"0.61 0.48 0.30"`, hex/255 아님). 일부 항목은 `condition`(가시성 조건식) 보유.
→ **MVP에서는 properties를 raw로만 보존**, 설정 UI는 향후.

### 3.4 파서가 견뎌야 할 현실
- 모든 필드는 **누락 가능**. 방어적 디코딩 필수.
- `type` 대소문자 혼용 → 소문자 정규화.
- 파일명에 한글/일본어/공백/괄호/앰퍼샌드 흔함 → `project.json.file`을 그대로 읽고 URL 인코딩 주의.
- `.DS_Store`, 웹 폴더의 `.history/`·`.vscode/` 등 잡파일 무시.

---

## 4. 아키텍처

4개 모듈로 분리. 각 모듈은 단일 책임 + 명확한 인터페이스.

```
WapleApp (UI/생명주기)
  ├─ 메뉴바 NSStatusItem  ──opens──▶  SwiftUI 라이브러리 창
  │                                        │ apply(project)
  ▼                                        ▼
WapleLibrary (LibraryStore)  ◀──reads──  WapleCore (모델/파서)
  │ selected project                       (WallpaperProject, ProjectJSONParser)
  ▼
WapleRender
  ├─ DesktopWindowController  (NSScreen마다 데스크탑-레벨 NSWindow)
  ├─ RendererFactory          (type → renderer)
  └─ WallpaperRenderer 프로토콜
       └─ VideoRenderer (AVQueuePlayer + AVPlayerLooper + AVPlayerLayer)
```

### 4.1 WapleCore (순수 Swift, UI 의존 없음, 테스트 가능)
- `WallpaperType`: `.video, .scene, .web, .application, .preset, .unknown(String)`
  — **모든 타입을 인식**(미지원도 enum으로 보존)해야 "지원 예정" 강등이 가능.
- `WallpaperProject`: `id`(폴더명), `type`, `fileName`, `previewName`, `title`,
  `description`, `tags`, `contentRating`, `workshopId`, `dependency`, `presetOverrides`,
  `rawProperties`(JSON), `folderURL`.
- `ProjectJSONParser`: `project.json` → `WallpaperProject`. 방어적 디코딩, 타입 소문자 정규화.
- `WallpaperProperty`(향후 설정 UI용): MVP에선 raw 보존만.

### 4.2 WapleLibrary
- `LibraryStore`: 가져온 배경 목록 + 선택 상태 관리.
  - **임포트(참조 방식)**: 폴더 선택 → 파서 검증 → 경로 + **security-scoped bookmark** 저장
    (실제 파일 복사 없음). 부모 폴더(예: `packages`) 선택 시 하위 폴더 **일괄 스캔/임포트**.
  - **영속화**: 라이브러리 인덱스(JSON, Application Support) + 선택 id(UserDefaults).
  - 무효 항목(파싱 실패/파일 없음)은 일괄 임포트 중 스킵+로그.
- 원본 이동/삭제로 bookmark가 깨지면 항목을 "경로 없음" 상태로 표시(크래시 X).

### 4.3 WapleRender
- `DesktopWindowController`
  - `NSScreen.screens`마다 borderless **데스크탑-레벨** `NSWindow` 1개 생성.
  - 창 설정(시작점, **현재 macOS(Darwin 27)에서 실측 검증 필요**):
    - `level = CGWindowLevelForKey(.desktopWindow)` 기준 — 아이콘 뒤·정적 배경 위.
    - `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`
    - `ignoresMouseEvents = true`, `hasShadow = false`, 투명 배경, `isOpaque = false`.
  - `NSApplication.didChangeScreenParametersNotification` 구독 → 화면 연결/해제/해상도 변경 시 창 재배치.
  - **검증 항목**: Mission Control / "데스크탑 보기" / Stage Manager에서 가려지지 않는지.
- `WallpaperRenderer` (프로토콜) — 확장 핵심 이음새
  ```swift
  protocol WallpaperRenderer {
      func mount(in view: NSView, project: WallpaperProject) throws
      func pause(); func resume(); func teardown()
  }
  ```
- `VideoRenderer` (MVP 구현)
  - `AVQueuePlayer` + `AVPlayerLooper`로 끊김 없는 루프(seek-to-zero 금지).
  - `AVPlayerLayer`, `videoGravity = .resizeAspectFill`(세로형/비16:9 대응; 추후 fit 옵션).
  - **기본 음소거**(`isMuted = true`), 추후 오디오 토글.
  - **코덱 감지**: `AVURLAsset`가 재생 불가(webm/VP9 등)면 `RendererError.unsupportedCodec` throw.
- `RendererFactory`: `WallpaperType` → 렌더러.
  - MVP: `.video` → `VideoRenderer`. 그 외 → nil(미지원).

### 4.4 WapleApp
- `NSStatusItem` 메뉴바 아이콘. 메뉴: 라이브러리 열기 / 일시정지·재개 / 종료.
- SwiftUI **라이브러리 창**: 썸네일 그리드(애니메이션 gif 지원), 타입 배지,
  클릭 시 적용, 폴더 임포트 버튼, 미지원 항목은 "지원 예정" 표시.
- 실행 시 마지막 선택 배경 복원 → 데스크탑 창 재생성·재생.

---

## 5. 데이터 흐름

- **임포트**: 폴더 선택 → `ProjectJSONParser` → 유효하면 `LibraryStore` 등록(경로+bookmark) → 그리드 표시.
- **적용**: 썸네일 클릭 → `LibraryStore.select(id)` → `RendererFactory`가 타입 매칭 렌더러 생성 →
  각 `DesktopWindow`의 contentView에 `mount` → 재생.
- **실행 복원**: 저장된 선택 id → 같은 경로의 project 로드 → 렌더 재생.
- **화면 변경**: `DesktopWindowController`가 창 재구성 후 현재 배경 재mount.

---

## 6. 에러 처리 / 우아한 강등 (중요)

"모든 타입 지원" 목표를 실제로 지키려면, 미지원도 깨지지 않고 인지되어야 한다.

| 상황 | 처리 |
|---|---|
| 미지원 타입(scene/web/preset, MVP) | 라이브러리에 표시 + "지원 예정" 배지. 적용 시 안내. 크래시 X. |
| 미지원 코덱(webm/VP9) | "이 코덱은 아직 지원 안 함" 안내. 향후 WKWebView 폴백 경로 예약. |
| project.json 없음/파싱 실패 | 일괄 임포트 중 스킵 + 로그. 단건이면 사용자에 안내. |
| 메인 자산 파일 없음 | 적용 시 에러 상태 표시. |
| bookmark 끊김(원본 이동/삭제) | "경로 없음" 상태로 표시, 재지정 유도. |

---

## 7. 테스트 전략

- **단위 (WapleCore)**: `ProjectJSONParser`를 실제 fixture로 검증
  — video / scene / `Scene`(대문자) / web / preset(no type)의 진짜 `project.json`.
  타입 대소문자 정규화, 누락 필드, 색상 문자열 파싱.
- **단위 (WapleLibrary)**: 임포트 시 bookmark 저장/복원, 인덱스 영속화, 일괄 스캔 스킵 로직.
- **단위 (WapleRender)**: `RendererFactory` 타입→렌더러 선택, 코덱 미지원 throw 경로.
- **수동/통합**: 데스크탑 창이 아이콘 뒤에 보이는지, 동영상 끊김 없는 루프, 멀티모니터 동일 배경,
  Mission Control/Stage Manager 동작, 실행 복원.

---

## 8. 범위 밖 / 향후 로드맵

MVP 이후, 우선순위 순:
1. **자원 절약**: 창 가림(occlusion)·풀스크린·배터리 시 렌더러 pause/resume.
2. **오디오 토글** + 볼륨, **aspect fit/fill 옵션**.
3. **웹 타입**: `WKWebView` + WE JS 브릿지 shim(`wallpaperPropertyListener`,
   `wallpaperRegisterAudioListener` 등). webm 동영상도 `<video>`로 폴백 통합 가능.
4. **화면별 다른 배경**, 라이브러리 정렬/검색/태그.
5. **general.properties → 설정 UI** 자동 매핑(color/slider/bool/combo + condition 가시성).
6. **프리셋**: `dependency` 해석 → 기반 배경 로드 → `preset` 오버라이드 적용.
7. **씬 타입(대형)**: `.pkg`(PKGV00xx) 언팩 → `scene.json` 파싱 → `.tex` 디코드 →
   GLSL/HLSL 이펙트 파이프라인 Metal 재구현 → 공유 `assets/` 의존 해결. 사실상 WE 렌더러 재구현.
8. **배포**: Developer ID 서명 + 공증, 자동 업데이트(Sparkle), 로그인 시 실행.

---

## 9. 미해결 리스크 / 검증 필요

- **데스크탑 창 레벨**: ✅ **해결(Darwin 27 실측)**. `.desktopWindow`(−2147483623)는 시스템
  정적 배경보다 아래로 묻혀 보이지 않았다. `.desktopIconWindow − 1`(−2147483604)로 변경 →
  창 서버 조회로 정적 배경(−...623) 위·아이콘(−...603) 아래에 풀스크린·`alpha=1`·`onscreen=1`
  확인. (`Sources/WapleRender/DesktopWindow.swift`)
- **Stage Manager / Mission Control** 상호작용 — 아직 수동 확인 필요.
- **샌드박스 vs 데스크탑 창**: App Store 샌드박스와 충돌 → Developer ID 경로 전제.
- **codec 감지**: `ffprobe`는 이 Mac에 미설치. 앱 내부는 `AVAsset`/`AVURLAsset` 네이티브 판정 사용.
