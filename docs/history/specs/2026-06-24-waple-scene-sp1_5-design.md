# Waple — Scene SP1.5: 비디오-텍스처 재생 + 씬 라이브러리 노출 (설계 문서)

- 작성일: 2026-06-24
- 상태: 설계 확정 대기 (사용자 리뷰 전)
- 선행: SP1(정적 이미지 컴포지터) main 병합. `SceneRenderer`/`ScenePackage`/`SceneDocument`/`TexImage`/`TexDecoder`/`VideoRenderer` 존재.
- 범위: 비디오-텍스처 씬 재생(SP1.5-A) + 씬을 라이브러리에 정식 노출(SP1.5-B).

---

## 1. 개요 / 목표

WE 씬의 `.tex`에 **내장된 MP4 비디오**(비디오-텍스처)를 데스크탑에 재생하고, 씬 타입을
라이브러리 UI에 정식 노출한다(부분 렌더 포함, 사용자 결정).

---

## 2. 정찰 결과 (Ground Truth)

비디오-텍스처 씬 3개:
- `2958411739` — **단일 풀스크린 비디오**(video `.tex` + sound object). SP1.5로 **완전 렌더**.
- `3147346398` — 비디오 + `Simple_Audio_Bars` 오디오-반응 이펙트/셰이더. SP1.5는 **비디오만**(부분; 오디오바는 SP5).
- `3363473482` — 비디오 + `audio_ring`/`audio_visualizer` 이펙트. SP1.5는 **비디오만**(부분).

`.tex`의 비디오 페이로드: `TexImage.parse`가 `payload == .video`, `payloadRange`로 내장 MP4 바이트 범위 제공
(헤더 후 `ftyp...avc1`(H.264) mp4 박스). AVFoundation 네이티브 재생 가능(웹 webm과 달리 H.264).

---

## 3. 설계

### SP1.5-A. 비디오-텍스처 재생
- `SceneRenderer.mount`가 파싱 후 레이어 중 **비디오-텍스처 레이어**(해당 `.tex`의 `payload == .video`)를 감지.
- 감지 시: 내장 MP4 바이트(`payloadRange`)를 **캐시 파일**로 추출
  (`~/Library/Application Support/Waple/cache/<sceneId>.mp4`, 있으면 재사용) → 기존 **`VideoRenderer`에 위임**
  (캐시 폴더를 가리키는 합성 `WallpaperProject`로 `mount`). 음소거·끊김없는 루프·`resizeAspectFill`.
- 미감지 시: 기존 Metal 정적 이미지 컴포지터(SP1) 경로.
- 비디오 + 이펙트 씬: 비디오만 재생(다른 레이어/이펙트 무시 = 부분).

### SP1.5-B. 씬 라이브러리 노출
- `RendererFactory`: **`experimentalSceneEnabled` 플래그 제거** → `.scene`은 항상 `SceneRenderer`로 라우팅.
- `WallpaperType.isSupportedInMVP`에 `.scene` 추가 → 라이브러리에서 씬 타일 클릭 가능(“지원 예정” 제거).
- 정직성 라벨: 씬 타일 배지를 **`scene · 부분`** 으로 표시(부분/블랭크 렌더 가능성 안내). 클릭은 허용.

---

## 4. 컴포넌트

| 컴포넌트 | 위치 | 검증 |
|---|---|---|
| `VideoTextureExtractor` (ScenePackage+SceneDocument → 비디오 레이어 탐지 → MP4를 캐시로 추출 → URL) | WapleRender | **TDD**(탐지/추출 바이트) + 수동(재생) |
| `SceneRenderer` 수정 (비디오 분기: 추출 → `VideoRenderer` 위임; pause/resume/teardown 위임) | WapleRender | 수동 |
| `RendererFactory` 수정 (플래그 제거, `.scene` 항상 라우팅) | WapleRender | **TDD** |
| `WallpaperType.isSupportedInMVP` (+ `.scene`) | WapleCore | **TDD** |
| `LibraryView` 타일 (씬 배지 `scene · 부분`) | Waple | 수동 |

### VideoTextureExtractor (핵심)
- `static func videoLayer(in doc: SceneDocument, package: ScenePackage) -> String?` — 첫 비디오-텍스처 레이어의 `textureEntryName` 반환(없으면 nil). `package.data(for:)` + `TexImage.parse` + `payload == .video`로 판별.
- `static func extractMP4(textureEntryName: String, package: ScenePackage, sceneID: String) -> URL?` — `TexImage.payloadRange` 바이트를 캐시 파일에 쓰고 URL 반환(존재 시 재사용). 추출 바이트는 `ftyp` 박스 포함.

---

## 5. 데이터 흐름
적용 → `SceneRenderer.mount` → pkg/scene 파싱 → `VideoTextureExtractor.videoLayer` 탐지 →
있으면 `extractMP4` → 합성 `WallpaperProject`(type=.video, file=`<id>.mp4`, folderURL=캐시) → `VideoRenderer.mount` →
없으면 Metal 이미지 컴포지터.

---

## 6. 에러 처리 / 강등
| 상황 | 처리 |
|---|---|
| 비디오 추출 실패 | 비디오 레이어 스킵 → 가능하면 Metal 경로, 아니면 빈 렌더, 무크래시 |
| BC3-only/이펙트-only 씬 노출 | 블랭크/부분 렌더(사용자 수용). 무크래시 |
| 캐시 쓰기 실패 | 임시 디렉터리 폴백 또는 스킵 |

---

## 7. 테스트
- **TDD**: `VideoTextureExtractor.videoLayer`(합성 ScenePackage: 비디오 `.tex` 레이어 포함/미포함),
  추출 바이트가 `ftyp` 시그니처로 시작; `RendererFactory.makeRenderer(.scene)` → `SceneRenderer`;
  `WallpaperType.scene.isSupportedInMVP == true`.
- **수동 게이트**: `2958411739` 비디오가 데스크탑에 루프·음소거 재생; 라이브러리에서 씬 타일이 `scene · 부분` 배지로 클릭 가능.

---

## 8. 범위 밖 / 리스크
- 비디오 + 이펙트 합성(SP3 효과 / SP5 오디오), 비디오-as-Metal-텍스처(다층 합성용).
- BC3 디코드·패럴랙스(SP2).
- **리스크**: 부분/블랭크 렌더 씬이 노출되어 깨져 보일 수 있음(사용자가 “모든 씬 노출” 선택). 향후 “완전 렌더 판정” 또는 베타 표시로 개선 가능.
- 캐시 정리 정책(누적) — 향후. SP1.5는 추출 후 재사용만.
