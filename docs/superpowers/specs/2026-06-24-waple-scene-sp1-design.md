# Waple — Scene 타입 SP1: 정적 이미지 레이어 컴포지터 (설계 문서)

- 작성일: 2026-06-24
- 상태: 설계 확정 대기 (사용자 리뷰 전)
- 선행: video/web 병합 완료(main). `WallpaperRenderer`/`RendererFactory`/`DesktopWindowController` 존재.
- 범위: Scene 메가 프로젝트의 **첫 서브프로젝트(SP1)** 만. 나머지는 별도 사이클.

---

## 1. 개요 / 목표

Wallpaper Engine `type:"scene"` 중 **정적 이미지 씬**을 macOS 데스크탑에 렌더한다.
목적은 두 가지:
1. `.pkg → .tex → scene.json → Metal` **전체 체인의 타당성 실증**.
2. 이후 모든 Scene 서브프로젝트(BC3·효과·파티클·오디오)가 올라설 **렌더 기반 구축**.

검증 타깃: `2899965423`(단일 PNG), `2188368235`(2 PNG 다층).

---

## 2. Scene 메가 프로젝트 분해 (SP1의 위치)

각 SP는 독립 spec→plan→구현 사이클.

1. **SP1 (본 문서)** — 에셋 파이프라인 + Metal 정적 이미지 레이어 컴포지터.
2. **SP1.5** — 비디오-텍스처 씬(내장 MP4): `2958411739`/`3147346398`/`3363473482`. 기존 AVFoundation 재사용하는 별도 저비용 윈.
3. **SP2** — BC3/LZ4 텍스처 디코드 + 패럴랙스/깊이.
4. **SP3** — 스톡 효과 셰이더 라이브러리(waterwaves/blur/tint/scroll/opacity/shake).
5. **SP4** — 파티클 시스템.
6. **SP5** — 오디오 반응(Simple_Audio_Bars; web의 `SystemAudioSpectrumProvider` 재사용).
7. **SP6** — Heavy 꼬리(퍼펫/3D, 초대형 컴포지션, 커스텀 셰이더 다수).

---

## 3. 정찰 결과 (Ground Truth)

`/Users/yakisoba/Downloads/packages` 31개 씬 + 실제 타깃 분석으로 확정.

### 3.1 `.pkg` 포맷 (전 버전 0001~0024 동일, 31개 검증)
리틀엔디언:
```
int32 versionLen                       // 예: 8
ascii  "PKGV00NN" (versionLen 바이트)
int32 entryCount
entryCount × { int32 nameLen; name(nameLen, ASCII); int32 offset; int32 size }
blob_base = 테이블 직후 위치
bytes(entry) = buf[blob_base + offset : blob_base + offset + size]
```
entry[0].offset == 0. entry[0]은 항상 `scene.json`/`gifscene.json`(`{`로 시작).
`blob_base + last.offset + last.size == filesize`.

### 3.2 `.tex` 포맷 + 페이로드 종류
헤더: `"TEXV0005\0" "TEXI0001\0" int32 format; int32 flags; int32 texW; int32 texH;
int32 imgW; int32 imgH; ...` 이어서 `"TEXB000x\0"` 밉 컨테이너. 밉 데이터의 **실제 페이로드**는
종류가 섞임 — 시그니처로 판별:
- `\x89PNG` → PNG, `\xFF\xD8\xFF` → JPEG (ImageIO로 디코드)
- `ftyp`/`mdat`/`moov` → **내장 MP4 비디오**(비디오-텍스처) → **SP1 스킵**(SP1.5)
- 그 외 → raw RGBA8888 또는 **DXT5/BC3(format enum9)** → BC3는 **SP1 스킵**(SP2)

**텍스처 페이로드 census(31개 씬)**: 단일 PNG/JPEG 정적 씬 다수(`2899965423`,`2905844074`,
`3292508781`,`3301542557` 등), 2 PNG(`2188368235`), 다층 PNG(`3394601417` 13장 등),
RAW/BC 혼합 다수, **비디오-텍스처 3개**(`2958411739`,`3147346398`,`3363473482`).

### 3.3 scene.json 구조 (SP1 대상 형태 — 실제 `2958411739`/`2899965423` 기준)
```jsonc
{
  "general": {
    "orthogonalprojection": { "width": 1920, "height": 1080 },
    "clearcolor": "0.70000 0.70000 0.70000",   // "r g b" 0~1
    "clearenabled": true,
    "bloom": false, "cameraparallax": false      // SP1 무시
  },
  "objects": [
    {                                   // 이미지 레이어
      "image": "models/Untitled.json",  // → 모델 JSON(pkg 내)
      "origin": "960.00000 540.00000 0.00000",   // 씬 픽셀 좌표
      "size": "1920.00000 1080.00000",
      "scale": "1.00000 1.00000 1.00000",
      "angles": "0.00000 0.00000 0.00000",
      "alpha": 1.0, "color": "1 1 1", "brightness": 1.0,
      "alignment": "center",            // origin = 쿼드 중심
      "visible": { "value": true, "script": "..." }  // SP1은 .value만
    },
    { "sound": ["sounds/Untitled.mp3"], ... }       // SP1 무시(이미지 없는 object)
  ]
}
```
**간접참조 체인**: `object.image`="models/X.json"(pkg) → `model.material`="materials/Y.json"(pkg) →
`material.passes[0].textures[0]`="Z" → `materials/Z.tex`(pkg). 모델 JSON엔 `width`/`height`도 있음.
머티리얼은 `shader`(예 `genericimage2`)·`blending`(translucent)·`textures[]` 보유.

### 3.4 공유 에셋 의존
31개 중 12개가 공유 `assets/` 참조하지만 실제 해석되는 외부 참조는
`models/util/{composelayer,solidlayer,projectlayer,fullscreenlayer}.json`(작은 풀스크린 쿼드 모델)뿐.
SP1 타깃(자체 pkg에 모델 포함)은 이를 안 씀 → **SP1은 외부 util 모델 해석 불필요**(필요 시 풀스크린 쿼드 합성).

---

## 4. 아키텍처

순수 파싱은 `WapleCore`(TDD), 디코드·Metal 렌더는 `WapleRender`.

```
RendererFactory (실험 플래그 ON일 때만 .scene → SceneRenderer)
SceneRenderer (MTKView, WallpaperRenderer)
  ├─ ScenePackage      (WapleCore: .pkg 언팩)
  ├─ SceneDocument     (WapleCore: scene.json → 레이어 + 간접참조 해석)
  ├─ TexImage          (WapleCore: .tex 헤더 → 포맷/페이로드 종류/범위)
  ├─ TexDecoder        (WapleRender: PNG/JPEG→ImageIO, raw RGBA8888→직접)
  └─ Metal 파이프라인  (직교 투영 + 텍스처 쿼드 알파 합성, QuadShaders.metal)
```

---

## 5. 컴포넌트 상세

### 5.1 `ScenePackage` (WapleCore — TDD)
- `static func parse(data: Data) throws -> ScenePackage` / `entries: [(name,offset,size)]` /
  `func data(for name: String) -> Data?`.
- 잘못된 헤더/범위 → throw(우아한 실패).

### 5.2 `TexImage` (WapleCore — TDD)
- `static func parse(_ data: Data) -> TexImage?` → `{ width, height, format: Int,
  payload: PayloadKind, payloadRange: Range<Int> }`.
- `enum PayloadKind { case png, jpeg, rawRGBA8888, bc3, video, unknown }` (시그니처+format enum으로 판별).

### 5.3 `SceneDocument` (WapleCore — TDD)
- `static func parse(package: ScenePackage) throws -> SceneDocument`.
- `SceneDocument { projection: (w:Int,h:Int), clearColor: (r,g,b), layers: [SceneLayer] }`.
- `SceneLayer { textureEntryName: String, origin:(x,y), size:(w,h), scale:(x,y), angleZ: Float,
  alpha: Float, color:(r,g,b), brightness: Float }` — `image`→model→material→texture 해석 결과.
- 이미지 없는 object(sound/particle 등)·`visible.value==false`는 제외. 해석 실패 레이어는 스킵.

### 5.4 `TexDecoder` (WapleRender — 수동)
- `static func rgba(from tex: TexImage, data: Data) -> (pixels: Data, w:Int, h:Int)?`.
- png/jpeg → `CGImageSource`로 디코드 후 RGBA8888 비트맵; rawRGBA8888 → 직접; **bc3/video/unknown → nil**(+로그, 레이어 스킵).

### 5.5 `SceneRenderer: WallpaperRenderer` (WapleRender — 수동)
- `mount(in:project:)`: 폴더의 `scene.pkg`(없으면 `gifscene.pkg`) 로드 → `ScenePackage` →
  `SceneDocument` → 레이어별 `.tex`를 `TexDecoder`로 RGBA → `MTLTexture` → `MTKView` 구성.
- 렌더: 직교 투영(projection w/h)으로 각 레이어 쿼드를 origin/size/scale/angleZ/alpha로 후→전 합성, clearcolor 배경.
- `MTKView`는 `isPaused=true` + `enableSetNeedsDisplay=true`(정적 온디맨드 드로우 → 가림 스로틀링 무관).
- `pause/resume/teardown` 구현(정적이라 pause는 no-op 수준, teardown은 뷰·리소스 해제).

### 5.6 `RendererFactory` 확장
- `static var experimentalSceneEnabled = false`. true일 때만 `.scene` → `SceneRenderer`.
- 기본(false)에선 `.scene`은 기존대로 nil(라이브러리에 "지원 예정"). **SP1은 사용자 미노출**(부분 렌더 방지).

---

## 6. 데이터 흐름
적용(실험 플래그 ON 또는 dev 경로) → SceneRenderer.mount → pkg 언팩 → scene.json·model·material 파싱 →
레이어별 .tex 디코드 → MTLTexture → 직교 투영 합성 렌더.

---

## 7. 좌표/투영 규약 (SP1의 "매직넘버" — 실측 게이트)
- 직교 투영 `width×height`(예 1920×1080). object `origin`은 씬 픽셀 좌표, `alignment:"center"`면 origin=쿼드 중심.
- **Y축 방향(상단 0 vs 하단 0)·Metal NDC 매핑·원점은 블로그가 아니라 실측으로 확정**.
  첫 렌더가 상하 반전/오프셋일 수 있음 → preview.jpg(또는 2레이어 합성)와 대조해 보정.

---

## 8. 에러 처리 / 우아한 강등 / 실험 게이팅

| 상황 | 처리 |
|---|---|
| pkg 없음/파싱 실패 | mount throw, 무크래시 |
| .tex가 bc3/video/unknown | 해당 레이어 스킵 + 로그(부분 렌더) |
| 이미지 없는 object | 무시(sound/particle 등) |
| Metal 디바이스 없음 | 우아한 실패 |
| 효과/파티클/3D 노드 | SP1은 무시(best-effort) — **그래서 사용자 미노출(experimental)** |

---

## 9. 테스트 전략

- **TDD(WapleCore)**:
  - `ScenePackage`: 합성 pkg 바이트(포맷대로 구성)로 entries/추출 검증.
  - `TexImage`: 합성 헤더로 width/height/payload 종류 판별(png/jpeg/raw/bc3/video 시그니처).
  - `SceneDocument`: 인라인 scene.json + model + material JSON으로 레이어·간접참조 해석, sound object 제외, visible=false 제외.
- **오라클 검증(수동, ground truth)**: Swift `ScenePackage`가 실제 pkg에서 추출한 `scene.json` 바이트가
  `/tmp/wepkg.py` 출력과 **바이트 동일**한지 1회 대조(합성 fixture가 내 가정을 그대로 인코딩하는 위험 차단).
- **수동 게이트**:
  - G-S1: `2899965423` 단일 이미지가 데스크탑에 올바른 방향/크기로 렌더(좌표 규약 §7).
  - G-S2: `2188368235` 2레이어가 올바른 순서·정렬로 합성.

---

## 10. 범위 밖 / 향후
- 비디오-텍스처(SP1.5), BC3/LZ4·패럴랙스(SP2), 효과 셰이더(SP3), 파티클(SP4), 오디오 반응(SP5), Heavy(SP6).
- gifscene(다중 프레임 .tex), 3D/퍼펫 모델, 카메라 패럴랙스/셰이크, bloom/HDR, `visible.script` 평가.
- 사용자 노출(라이브러리에서 scene 정식 지원 표시)은 SP3 이후.

---

## 11. 리스크 / 미해결
- **좌표/투영 규약**(§7) — 실측 전 미확정, 첫 렌더 오방향 가능성 최대 리스크.
- **간접참조/텍스처 이름 해석** — 머티리얼 `textures[]`가 이름("Untitled")인지 경로인지 씬마다 다를 수 있음 → `materials/<name>.tex` 우선, 실패 시 경로로 재시도.
- **부분 렌더의 함정** — 복잡 씬이 절반만 그려져 깨져 보임 → experimental 게이트로 사용자 미노출 유지.
- **MTKView in 데스크탑-레벨 창** — 정적 드로우로 SP1은 무관하나, 애니메이션 SP2+에서 가림 스로틀링 게이트 복귀.
