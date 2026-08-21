# 씬 스크립트 API — 전수 표면 · 실물 바인딩 · Waple 대조

> 대상 셋:
> - **선언** `ui/dist/monaco/autocomplete/lib.sceneScript.d.ts` (2570행, 헤더가 스스로
>   "OFFICIAL SCENESCRIPT TYPE DECLARATION - VERSION 2.8" 이라고 밝힌다). 사람이 읽는 문서가
>   아니라 편집기 자동완성이 먹는 **배포물**이라 정본 자격이 있다.
> - **실물** `wallpaper64.exe`(imagebase `0x140000000`) + `bin/scenescript64.dll`(imagebase
>   `0x180000000`). VM 은 DLL(V8)이고 exe 는 오브젝트 바인딩만 건다 — 이 문서가 그 분업을 표로 낸다.
> - **구현** `Sources/WapleRender/TextScriptEngine.swift` 의 `static let shims` JS 프렐류드.
>
> 선행 문서 `spec/engine/script-api.json`(`scripts/spec/measure_script_api.py` 생성)은 **문자열
> 군집**으로 "이름이 등록됐다"까지 증명한다. 이 문서는 그 위에 **등록부 코드**를 읽어
> **이름 ↔ 구현 VA** 를 짚고, 동봉/설치본 스크립트의 **실제 도달 수**로 우선순위를 매긴다.

---

## 1. 표면 전수

`lib.sceneScript.d.ts` 를 통째로 파싱한 결과(파서: 이 문서 작성 시 1회용 — 주석 제거 후
최상위 선언과 그 본문의 최상위 멤버만 센다).

| 항목 | 수 |
| --- | --- |
| 타입 컨테이너 | **42** (class 14 · interface 25 · module 3) |
| 메서드 | **294** (그중 `static` 21) |
| 프로퍼티 | **150** |
| 생성자 | **5** (`Vec2`/`Vec3`/`Vec4`/`Mat3`/`Mat4`) |
| 전역 `declare let` | **8** |
| **표면 합계** | **457** (멤버 444 + 생성자 5 + 전역 8) |

전역 8개: `thisLayer`(:2123) · `thisScene`(:2275) · `console`(:2297) · `renderContext`(:2308) ·
`input`(:2335) · `localStorage`(:2377) · `engine`(:2504) · `shared`(:2571).

컨테이너별 멤버 수(선언 순):

| 컨테이너 | 종류 | d.ts 행 | 메서드 | 프로퍼티 |
| --- | --- | --- | ---: | ---: |
| `IComponent`(이벤트 훅) | interface | 47 | 17 | 0 |
| `Vec2` | class | 171 | 34 | 2 |
| `Vec3` | class | 354 | 35 | 3 |
| `Mat4` | class | 544 | 29 | 1 |
| `Mat3` | class | 703 | 24 | 1 |
| `Vec4` | class | 836 | 30 | 4 |
| `CameraTransforms` | class | 1001 | 0 | 4 |
| `AnimationEvent` | class | 1012 | 0 | 2 |
| `CursorEvent` | class | 1021 | 0 | 2 |
| `MediaPropertiesEvent` | class | 1051 | 0 | 7 |
| `MediaThumbnailEvent` | class | 1091 | 0 | 6 |
| `MediaPlaybackEvent` | class | 1126 | 0 | 4 |
| `MediaTimelineEvent` | class | 1151 | 0 | 2 |
| `MediaStatusEvent` | class | 1166 | 0 | 1 |
| `WEMath` | module | 1177 | 2 | 2 |
| `WEVector` | module | 1200 | 2 | 0 |
| `WEColor` | module | 1215 | 4 | 0 |
| `AudioBuffers` | class | 1241 | 0 | 3 |
| `IObject` | interface | 1250 | 1 | 0 |
| `IThisPropertyObjectBase` | interface | 1260 | 0 | 0 |
| `IMaterial` | interface | 1268 | 0 | 0 |
| `IEffect` | interface | 1276 | 4 | 2 |
| `ITextureAnimation` | interface | 1312 | 7 | 3 |
| `IVideoTexture` | interface | 1373 | 7 | 3 |
| `IAnimationLayer` | interface | 1433 | 7 | 7 |
| `ISoundLayer` | interface | 1509 | 4 | 1 |
| `IEffectLayer` | interface | 1540 | 2 | 3 |
| `ITextLayer` | interface | 1577 | 0 | 15 |
| `IParticleSystemInstance` | interface | 1659 | 0 | 15 |
| `IParticleSystem` | interface | 1740 | 5 | 1 |
| `IImageLayer` | interface | 1776 | 23 | 3 |
| `IModelLayer` | interface | 1912 | 5 | 2 |
| `ICamera` | interface | 1953 | 0 | 2 |
| `IModelData` | interface | 1969 | 2 | 5 |
| `ILayer` | interface | 2020 | 12 | 6 |
| `IScene` | interface | 2129 | 14 | 19 |
| `IConsole` | interface | 2281 | 2 | 0 |
| `IRenderContext` | interface | 2302 | 0 | 0 |
| `IInput` | interface | 2314 | 0 | 3 |
| `ILocalStorage` | interface | 2341 | 4 | 2 |
| `IEngine` | interface | 2383 | 12 | 9 |
| `IAnimation` | interface | 2510 | 6 | 5 |

### 1.1 선언 자체의 결함 두 개

- `ILayer`(:2020)의 `extends` 목록에 **`IModel` 이 있는데 그런 선언이 파일에 없다**
  (`IModelLayer` 의 오타로 보인다). 즉 `thisLayer.rootmotion` / `getBoneCount()` 류는 선언상
  상속되지 않는다 — 그런데 exe 등록부는 실제로 건다(§3).
- `IScene.createLayer`(:2175)의 인자 타입에 **`IAssetHandle` 이 있는데 그런 선언도 없다**.
  `IEngine.registerAsset`(:2446)의 반환형도 같은 미선언 타입이다.

두 이름 다 exe/DLL 어디에도 문자열이 없다 — 즉 선언 파일에만 있는 유령이다.

### 1.2 빈 인터페이스 셋

`IThisPropertyObjectBase`(:1260) · `IMaterial`(:1268) · `IRenderContext`(:2302) 는 본문이
비어 있다. 앞의 둘은 의미가 있다 — `IThisPropertyObjectBase` 의 주석이 `thisObject` 의
정의("The object this property is bound to")이고, `IMaterial` 은 **셰이더 상수 이름이 곧
프로퍼티**라 고정 멤버가 없는 것이 정상이다. `IRenderContext`/`renderContext` 만은 이름조차
어느 바이너리에도 없다(선행 `spec/engine/script-api.json` 의 `script.dts.unbacked` 와 일치).

---

## 2. 실제 도달 — 자산 스크립트가 부르는 것만

`"script"` 키를 가진 JSON 을 전부 훑어 인라인 스크립트를 뽑고(동봉 트리 + WE 설치본
`projects/` · `assets/`), 주석/문자열을 걷어낸 뒤 수신자 타입을 추론해 셌다.

| 코퍼스 | 고유 스크립트 | 도달 API |
| --- | ---: | ---: |
| **동봉** `Sources/WapleRender/Resources/WEAssets` | 6 | **27** |
| 설치본 `projects/defaultprojects` + `assets` | 15 | 43 |
| 설치본 `ui/dist/monaco/snippets`(공식 스니펫) | 15 | 36 |

동봉 6개의 정체: `presets/clock/preset.json`(변형 2) · `presets/clock/previewclock` ·
`presets/clock/preview3dclock` · `presets/countdown/preset.json` +
`scenes/particleelementpreviews/inheritcontrolpointvelocity`.
(`presets/countdown/previewcountdown` 은 preset.json 과 바이트 동일이라 중복 제거.)

### 2.1 동봉 도달 상위 30

| # | 소속 | 멤버 | 동봉 | 설치본 | d.ts | Waple 분류 |
|---|---|---|---:|---:|---|---|
| 1 | 전역 | `thisLayer` | 19 | 23 | :2123 | 구현됨 |
| 2 | ILayer | `origin` | 10 | 17 | :2024 | 구현됨 |
| 3 | ILayer | `angles` | 8 | 8 | :2029 | 구현됨 |
| 4 | 전역 | `thisScene` | 6 | 24 | :2275 | 구현됨 |
| 5 | Vec3 | `x` | 6 | 14 | :355 | 구현됨 |
| 6 | IComponent | `update` | 6 | 12 | :67 | 구현됨 |
| 7 | Vec3 | `z` | 5 | 5 | :357 | 구현됨 |
| 8 | Vec3 | `y` | 4 | 12 | :356 | 구현됨 |
| 9 | 클래스 | `new Vec3(...)` | 4 | 5 | :359 | 구현됨 |
| 10 | ILayer | `scale` | 4 | 4 | :2034 | 구현됨 |
| 11 | 전역 | `engine` | 3 | 7 | :2504 | 구현됨 |
| 12 | IComponent | `init` | 3 | 4 | :55 | 구현됨 |
| 13 | ITextLayer | `text` | 2 | 5 | :1581 | 구현됨 |
| 14 | IScene | `createLayer` | 2 | 4 | :2175 | **스텁**(§5.2 에서 인자 소비까지 해소) |
| 15 | 전역 | `input` | 2 | 3 | :2335 | 구현됨 |
| 16 | IInput | `cursorWorldPosition` | 2 | 3 | :2318 | 구현됨 |
| 17 | IScene | `getLayerIndex` | 2 | 3 | :2185 | 구현됨(§5.4 에서 String 인자 추가) |
| 18 | IScene | `sortLayer` | 2 | 3 | :2180 | **스텁**(§5.3 에서 반환형/기록까지 해소) |
| 19 | IEngine | `canvasSize` | 2 | 2 | :2477 | 구현됨 |
| 20 | ILayer | `visible` | 2 | 2 | :2049 | 구현됨 |
| 21 | ITextLayer | `font` | 2 | 2 | :1611 | **없었음 → §5.1 에서 구현** |
| 22 | ITextLayer | `pointsize` | 2 | 2 | :1606 | **없었음 → §5.1 에서 구현** |
| 23 | Vec3 | `copy` | 2 | 2 | :394 | 구현됨 |
| 24 | Vec3 | `divide` | 2 | 2 | :429 | 구현됨 |
| 25 | Vec3 | `multiply` | 2 | 2 | :424 | 구현됨 |
| 26 | WEMath | `mix` | 2 | 2 | :1185 | 구현됨 |
| 27 | IEngine | `runtime` | 1 | 1 | :2497 | 구현됨 |
| 28 | IScene | `getLayer` | 0 | 12 | :2133 | 구현됨 |
| 29 | 전역 | `localStorage` | 0 | 4 | :2377 | 구현됨 |
| 30 | 전역 | `thisObject` | 0 | 4 | :1260 | 구현됨 |

동봉 도달이 1 이상인 항목은 **27개가 전부**다(28~30은 설치본 도달로 이어 붙였다).
즉 **표면 457 중 동봉이 실제로 만지는 것은 5.9%** 다. 나머지를 짓는 것은 근거 없는 작업이다.

### 2.2 선언에 없는데 동봉 스크립트가 쓰는 것

동봉 `presets/clock` · `presets/countdown` 이 `createScriptProperties()` 로 시작해
`.addText / .addCheckbox / .finish()` 를 체이닝하고 `export var scriptProperties` 를 내보낸다.
이 API 는 **`lib.sceneScript.d.ts` 에 한 글자도 없다**. 정본은 동봉
`scripts/jsclasses/baseclasses.js` 다(순수 JS — 네이티브 바인딩 아님). DLL 쪽 근거는
`scriptProperties`(`0x181648a57`) · `label`/`mode`/`order`/`min`/`max`/`options`/`value`
설정 키와 `_Internal.updateScriptProperties`(`0x18164a8ea`) 다.
Waple 은 심에 `createScriptProperties` 를 직접 구현해 뒀다(오버라이드 주입 포함).

`thisObject` 도 마찬가지로 d.ts 에 **전역 선언이 없다**(인터페이스만 `IThisPropertyObjectBase`
로 있다). DLL 은 `thisObject`(`0x181648de3`)를 `thisLayer`(`0x181648e39`)와 **다른 스택**에서
꺼내는 별개 전역으로 등록한다.

---

## 3. exe 바인딩 등록부 — 이름 ↔ 구현 VA

### 3.1 등록 패턴

과제가 준 좌표(`executeMaterialFunction` 이름 문자열 `0x1401F0156` · 구현 포인터
`0x1401F016C`)를 디스어셈해 보면 등록부 함수 `0x1401EFCA0`–`0x1401F05FC`(IEffect) 안이고,
두 가지 고정 형태가 반복된다.

**메서드**

```
0x1401EFEE6  lea  rdx, [rip+0x2A0A5B]   ; 0x140490948 "getMaterial"
0x1401EFEED  mov  r8d, 0xB              ; 이름 길이
0x1401EFEF3  lea  rcx, [rbx+0x38]       ; 레코드 +0x38 = 이름 필드
0x1401EFEF7  call 0x14000F880           ; std::string 대입
0x1401EFEFC  lea  rax, [rip-0x1E43]     ; 0x1401EE0C0 = 구현
0x1401EFF03  mov  dword ptr [rbx+0x70], 0x800   ; 플래그(인자 수/타입)
0x1401EFF0E  mov  qword ptr [rbx+0x30], rax     ; 구현 포인터
```

**프로퍼티**

```
0x1401EFD4F  lea  rdx, [rip+0x2A064A]   ; 0x1404903A0 "visible"
0x1401EFD56  mov  r8d, 7
0x1401EFD5C  lea  rcx, [rbx+0x68]       ; 레코드 +0x68 = 이름 필드
0x1401EFD60  call 0x14000F880
             ... [rbx+0x38] / +0x40 / +0x48 / +0x50 / +0x58 = 접근자 5칸
```

즉 **`lea rcx,[reg+0x38]` + `call 0x14000F880` = 메서드**, **`lea rcx,[reg+0x68]` = 프로퍼티**다.
`0x14000F880` 호출 사이트는 .text 전체에 524곳이고 그중 132개 함수 안에 있다. 위 두 형태로
이름/구현을 짚으면 스크립트 바인딩 등록부 **19개**가 남는다(나머지는 로그·경로 문자열 조립).

### 3.2 등록부 19개 요약

| 등록부 VA | 인터페이스 | 메서드 | 프로퍼티 |
| --- | --- | ---: | ---: |
| `0x140199780`–`0x14019B4D6` | `IScene`(씬 설정) | 0 | 42 |
| `0x140258CA0`–`0x14025A713` | `ITextLayer` | 0 | 29 |
| `0x140211070`–`0x140212523` | `IImageLayer`(본/블렌드셰이프) | 23 | 1 |
| `0x14024D940`–`0x14024E96E` | `IParticleSystemInstance` | 0 | 24 |
| `0x1401E0530`–`0x1401E1389` | `ILayer`(트랜스폼/부모/어태치먼트) | 11 | 8 |
| `0x14025DA80`–`0x14025E9DA` | (d.ts 미선언) 라이트 오브젝트 | 0 | 18 |
| `0x14026C980`–`0x14026D5DE` | `IAnimationLayer` | 7 | 11 |
| `0x1401EE520`–`0x1401EF118` | `IEffectLayer` + `IImageLayer` | 3 | 12 |
| `0x1401F7090`–`0x1401F7B96` | `ISoundLayer` | 4 | 9 |
| `0x140177F70`–`0x1401786F1` | `IAnimation` | 6 | 5 |
| `0x1402131A0`–`0x14021387A` | `ITextureAnimation` | 7 | 3 |
| `0x140214050`–`0x140214799` | `IVideoTexture` | 7 | 3 |
| `0x140227470`–`0x140227C51` | `IModelLayer` | 5 | 4 |
| `0x14024CB00`–`0x14024D022` | `IParticleSystem` | 5 | 2 |
| `0x1401EFCA0`–`0x1401F05FC` | `IEffect` | 4 | 2 |
| `0x1401577E0`–`0x1401580E2` | (d.ts 미선언) 머티리얼 렌더스테이트 | 0 | 5 |
| `0x1401F3460`–`0x1401F38B5` | `ICamera` | 0 | 4 |
| `0x140004540`–`0x140004721` | 베이스 오브젝트(visible/name) | 0 | 2 |
| `0x1400043A0`–`0x1400044C3` | 베이스 오브젝트(visible) | 0 | 1 |

합계 **267**(메서드 82 · 프로퍼티 185). 그중 **175개가 d.ts 에 선언돼 있고 92개는 없다** —
없는 쪽은 씬 JSON 키와 같은 이름의 편집기 전용 프로퍼티(`bloomhdr*` 15종, `fog*` 12종,
`controlpointangle0..7`, 라이트 18종, 렌더스테이트 5종 등)다.

### 3.3 전수 표 (exe)


#### `0x1401e0530` — ILayer (트랜스폼·부모·어태치먼트)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 메서드 | `getTransformMatrix` | `0x1401df5e0` | ✓ |
| 메서드 | `rotateObjectSpace` | `0x1401df620` | ✓ |
| 메서드 | `lookAt` | `0x1401dfc00` | ✓ |
| 메서드 | `lookAtYaw` | `0x1401dfe30` | ✓ |
| 메서드 | `setParent` | `0x1401e00b0` | ✓ |
| 메서드 | `getParent` | `0x1401e0180` | ✓ |
| 메서드 | `getChildren` | `0x1401e0190` | ✓ |
| 메서드 | `getAttachmentIndex` | `0x1401e01d0` | ✓ |
| 메서드 | `getAttachmentMatrix` | `0x1401e01f0` | ✓ |
| 메서드 | `getAttachmentOrigin` | `0x1401e02c0` | ✓ |
| 메서드 | `getAttachmentAngles` | `0x1401e0390` | ✓ |
| 프로퍼티 | `origin` | `0x1401a4230` | ✓ |
| 프로퍼티 | `scale` | `0x1401a4230` | ✓ |
| 프로퍼티 | `angles` | `0x1401df2f0` | ✓ |
| 프로퍼티 | `parallaxDepth` | `0x1401a3fc0` | ✓ |
| 프로퍼티 | `sortorder` | `0x1401a4930` | — |
| 프로퍼티 | `name` | `0x1401a4bc0` | ✓ |
| 프로퍼티 | `solid` | `0x14019c3f0` | ✓ |
| 프로퍼티 | `disablepropagation` | `0x14019bb40` | — |

#### `0x1401ee520` — IEffectLayer + IImageLayer (이미지 오브젝트)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 메서드 | `getEffect` | `0x1401ecfe0` | ✓ |
| 메서드 | `getEffectCount` | `0x1401ed0b0` | — |
| 메서드 | `transformAttachmentToTexture` | `0x1401ed0d0` | ✓ |
| 프로퍼티 | `size` | `0x1401a3fc0` | ✓ |
| 프로퍼티 | `color` | `0x1401a4230` | ✓ |
| 프로퍼티 | `alpha` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `brightness` | `0x1401a4b00` | — |
| 프로퍼티 | `visible` | `0x1401e1a90` | ✓ |
| 프로퍼티 | `perspective` | `0x14019c620` | ✓ |
| 프로퍼티 | `castshadow` | `0x1401ef120` | — |
| 프로퍼티 | `copybackground` | `0x1401ef350` | — |
| 프로퍼티 | `nointerpolation` | `0x14019bb40` | — |
| 프로퍼티 | `clampuvs` | `0x14019bd70` | — |
| 프로퍼티 | `ledsource` | `0x14019c850` | — |
| 프로퍼티 | `colorBlendMode` | `0x1401a4930` | — |

#### `0x1401efca0` — IEffect (이펙트)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 메서드 | `getMaterial` | `0x1401ee0c0` | ✓ |
| 메서드 | `getMaterialCount` | `0x1401ee1a0` | ✓ |
| 메서드 | `setMaterialProperty` | `0x1401ee1d0` | ✓ |
| 메서드 | `executeMaterialFunction` | `0x1401ee3a0` | ✓ |
| 프로퍼티 | `visible` | `0x1401e1a90` | ✓ |
| 프로퍼티 | `name` | `0x1401a4bc0` | ✓ |

#### `0x140211070` — IImageLayer (본/블렌드셰이프/애니메이션 레이어)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 메서드 | `getTextureAnimation` | `0x14020e670` | ✓ |
| 메서드 | `getVideoTexture` | `0x14020e7b0` | ✓ |
| 메서드 | `getAnimationLayer` | `0x14020e910` | ✓ |
| 메서드 | `getAnimationLayerCount` | `0x14020e9f0` | ✓ |
| 메서드 | `createAnimationLayer` | `0x14020ea30` | ✓ |
| 메서드 | `playSingleAnimation` | `0x14020ef40` | ✓ |
| 메서드 | `destroyAnimationLayer` | `0x14020ef80` | ✓ |
| 메서드 | `getBoneCount` | `0x14020f190` | ✓ |
| 메서드 | `getBoneTransform` | `0x14020f1d0` | ✓ |
| 메서드 | `setBoneTransform` | `0x14020f350` | ✓ |
| 메서드 | `getLocalBoneTransform` | `0x14020f6b0` | ✓ |
| 메서드 | `setLocalBoneTransform` | `0x14020f840` | ✓ |
| 메서드 | `getLocalBoneAngles` | `0x14020fa10` | ✓ |
| 메서드 | `setLocalBoneAngles` | `0x14020fce0` | ✓ |
| 메서드 | `getLocalBoneOrigin` | `0x1402100d0` | ✓ |
| 메서드 | `setLocalBoneOrigin` | `0x140210250` | ✓ |
| 메서드 | `getBlendShapeIndex` | `0x140210400` | ✓ |
| 메서드 | `getBlendShapeWeight` | `0x1402104b0` | ✓ |
| 메서드 | `setBlendShapeWeight` | `0x1402105c0` | ✓ |
| 메서드 | `getBoneIndex` | `0x140210790` | ✓ |
| 메서드 | `getBoneParentIndex` | `0x140210860` | ✓ |
| 메서드 | `applyBonePhysicsImpulse` | `0x140210990` | ✓ |
| 메서드 | `resetBonePhysicsSimulation` | `0x140210e10` | ✓ |
| 프로퍼티 | `alignment` | `0x140212690` | ✓ |

#### `0x140227470` — IModelLayer (모델 오브젝트)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 메서드 | `getAnimationLayer` | `0x140226bc0` | ✓ |
| 메서드 | `getAnimationLayerCount` | `0x140226cb0` | ✓ |
| 메서드 | `createAnimationLayer` | `0x140226d00` | ✓ |
| 메서드 | `playSingleAnimation` | `0x140227220` | ✓ |
| 메서드 | `destroyAnimationLayer` | `0x140227260` | ✓ |
| 프로퍼티 | `visible` | `0x1401e1a90` | ✓ |
| 프로퍼티 | `perspective` | `0x14019c620` | ✓ |
| 프로퍼티 | `castshadow` | `0x1401ef120` | — |
| 프로퍼티 | `rootmotion` | `0x1401e1a90` | ✓ |

#### `0x140258ca0` — ITextLayer (텍스트 오브젝트)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 프로퍼티 | `backgroundbrightness` | `0x1401a4b00` | — |
| 프로퍼티 | `opaquebackground` | `0x14019b4e0` | ✓ |
| 프로퍼티 | `limitwidth` | `0x14019bfa0` | ✓ |
| 프로퍼티 | `limitrows` | `0x14025aca0` | ✓ |
| 프로퍼티 | `limituseellipsis` | `0x14025aec0` | — |
| 프로퍼티 | `blockalign` | `0x14019b920` | — |
| 프로퍼티 | `backgroundcolor` | `0x1401a4230` | ✓ |
| 프로퍼티 | `pointsize` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `padding` | `0x1401a3fc0` | ✓ |
| 프로퍼티 | `spacing` | `0x1401a3fc0` | — |
| 프로퍼티 | `maxwidth` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `maxrows` | `0x1401a4930` | ✓ |
| 프로퍼티 | `msdf` | `0x1401e1a90` | — |
| 프로퍼티 | `outline` | `0x14019b4e0` | — |
| 프로퍼티 | `blur` | `0x14019bfa0` | — |
| 프로퍼티 | `dropshadow` | `0x14025aca0` | — |
| 프로퍼티 | `outlinethickness` | `0x1401a4b00` | — |
| 프로퍼티 | `outlinecolor` | `0x1401a4230` | — |
| 프로퍼티 | `blursize` | `0x1401a4b00` | — |
| 프로퍼티 | `dropshadowsize` | `0x1401a4b00` | — |
| 프로퍼티 | `dropshadowopacity` | `0x1401a4b00` | — |
| 프로퍼티 | `dropshadowcolor` | `0x1401a4230` | — |
| 프로퍼티 | `dropshadowoffset` | `0x1401a3fc0` | — |
| 프로퍼티 | `depthtest` | `0x14025b0e0` | — |
| 프로퍼티 | `horizontalalign` | `0x14025b450` | ✓ |
| 프로퍼티 | `verticalalign` | `0x14025b7c0` | ✓ |
| 프로퍼티 | `anchor` | `0x14025bb30` | ✓ |
| 프로퍼티 | `text` | `0x1401a4bc0` | ✓ |
| 프로퍼티 | `font` | `0x1401a4bc0` | ✓ |

#### `0x14024cb00` — IParticleSystem (파티클 오브젝트)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 메서드 | `play` | `0x14024c5b0` | ✓ |
| 메서드 | `pause` | `0x14024c670` | ✓ |
| 메서드 | `stop` | `0x14024c680` | ✓ |
| 메서드 | `isPlaying` | `0x14024ca10` | ✓ |
| 메서드 | `emitParticles` | `0x14024cac0` | ✓ |
| 프로퍼티 | `visible` | `0x1401e1a90` | ✓ |
| 프로퍼티 | `instance` | `0x1401a4da0` | ✓ |

#### `0x14024d940` — IParticleSystemInstance (파티클 인스턴스)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 프로퍼티 | `alpha` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `size` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `count` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `speed` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `lifetime` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `brightness` | `0x1401a4b00` | — |
| 프로퍼티 | `rate` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `colorn` | `0x1401a4230` | ✓ |
| 프로퍼티 | `controlpoint0` | `0x1401a4230` | ✓ |
| 프로퍼티 | `controlpointangle0` | `0x1401a4230` | — |
| 프로퍼티 | `controlpoint1` | `0x1401a4230` | ✓ |
| 프로퍼티 | `controlpointangle1` | `0x1401a4230` | — |
| 프로퍼티 | `controlpoint2` | `0x1401a4230` | ✓ |
| 프로퍼티 | `controlpointangle2` | `0x1401a4230` | — |
| 프로퍼티 | `controlpoint3` | `0x1401a4230` | ✓ |
| 프로퍼티 | `controlpointangle3` | `0x1401a4230` | — |
| 프로퍼티 | `controlpoint4` | `0x1401a4230` | ✓ |
| 프로퍼티 | `controlpointangle4` | `0x1401a4230` | — |
| 프로퍼티 | `controlpoint5` | `0x1401a4230` | ✓ |
| 프로퍼티 | `controlpointangle5` | `0x1401a4230` | — |
| 프로퍼티 | `controlpoint6` | `0x1401a4230` | ✓ |
| 프로퍼티 | `controlpointangle6` | `0x1401a4230` | — |
| 프로퍼티 | `controlpoint7` | `0x1401a4230` | ✓ |
| 프로퍼티 | `controlpointangle7` | `0x1401a4230` | — |

#### `0x1401f7090` — ISoundLayer (사운드 오브젝트)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 메서드 | `play` | `0x1401f6e50` | ✓ |
| 메서드 | `stop` | `0x1401f6e60` | ✓ |
| 메서드 | `pause` | `0x1401f6f00` | ✓ |
| 메서드 | `isPlaying` | `0x1401f6fb0` | ✓ |
| 프로퍼티 | `volume` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `mintime` | `0x1401a4b00` | — |
| 프로퍼티 | `maxtime` | `0x1401a4b00` | — |
| 프로퍼티 | `attenuation` | `0x1401a4b00` | — |
| 프로퍼티 | `mindistance` | `0x1401a4b00` | — |
| 프로퍼티 | `playbackmode` | `0x1401f7d00` | — |
| 프로퍼티 | `muteineditor` | `0x1401e1a90` | — |
| 프로퍼티 | `startsilent` | `0x14019b4e0` | — |
| 프로퍼티 | `spatialization` | `0x14019bfa0` | — |

#### `0x140199780` — IScene (씬 설정 프로퍼티)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 프로퍼티 | `bloom` | `0x14019b4e0` | ✓ |
| 프로퍼티 | `hdr` | `0x14019b6f0` | — |
| 프로퍼티 | `bloomstrength` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `bloomthreshold` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `bloomhdrstrength` | `0x1401a4b00` | — |
| 프로퍼티 | `bloomhdrthreshold` | `0x1401a4b00` | — |
| 프로퍼티 | `bloomhdrfeather` | `0x1401a4b00` | — |
| 프로퍼티 | `bloomhdrscatter` | `0x1401a4b00` | — |
| 프로퍼티 | `bloomhdriterations` | `0x1401a4930` | — |
| 프로퍼티 | `bloomtint` | `0x1401a4230` | — |
| 프로퍼티 | `clearenabled` | `0x14019b920` | ✓ |
| 프로퍼티 | `clearcolor` | `0x1401a4230` | ✓ |
| 프로퍼티 | `ambientcolor` | `0x1401a4230` | ✓ |
| 프로퍼티 | `skylightcolor` | `0x1401a4230` | ✓ |
| 프로퍼티 | `fogdistance` | `0x14019bb40` | — |
| 프로퍼티 | `fogheight` | `0x14019bd70` | — |
| 프로퍼티 | `fogdistancecolor` | `0x1401a4230` | — |
| 프로퍼티 | `fogheightcolor` | `0x1401a4230` | — |
| 프로퍼티 | `fogdistancestart` | `0x1401a4b00` | — |
| 프로퍼티 | `fogdistanceend` | `0x1401a4b00` | — |
| 프로퍼티 | `fogdistancestartdensity` | `0x1401a4b00` | — |
| 프로퍼티 | `fogdistanceenddensity` | `0x1401a4b00` | — |
| 프로퍼티 | `fogheightstart` | `0x1401a4b00` | — |
| 프로퍼티 | `fogheightend` | `0x1401a4b00` | — |
| 프로퍼티 | `fogheightstartdensity` | `0x1401a4b00` | — |
| 프로퍼티 | `fogheightenddensity` | `0x1401a4b00` | — |
| 프로퍼티 | `fov` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `perspectiveoverridefov` | `0x1401a4b00` | — |
| 프로퍼티 | `nearz` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `farz` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `zoom` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `camerafade` | `0x14019bfa0` | ✓ |
| 프로퍼티 | `transparentsorting` | `0x14019c1c0` | — |
| 프로퍼티 | `customsortorder` | `0x14019c3f0` | — |
| 프로퍼티 | `camerashake` | `0x14019c620` | ✓ |
| 프로퍼티 | `camerashakespeed` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `camerashakeamplitude` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `camerashakeroughness` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `cameraparallax` | `0x14019c850` | ✓ |
| 프로퍼티 | `cameraparallaxamount` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `cameraparallaxdelay` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `cameraparallaxmouseinfluence` | `0x1401a4b00` | ✓ |

#### `0x1402131a0` — ITextureAnimation (텍스처 애니메이션)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 메서드 | `play` | `0x1401fa330` | ✓ |
| 메서드 | `pause` | `0x1401fa340` | ✓ |
| 메서드 | `stop` | `0x1401fa3a0` | ✓ |
| 메서드 | `isPlaying` | `0x1401fa3d0` | ✓ |
| 메서드 | `setFrame` | `0x1401fa400` | ✓ |
| 메서드 | `getFrame` | `0x1401fa430` | ✓ |
| 메서드 | `join` | `0x1401fa490` | ✓ |
| 프로퍼티 | `rate` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `frameCount` | `0x1401fa2a0` | ✓ |
| 프로퍼티 | `duration` | `0x1401fa2f0` | ✓ |

#### `0x140214050` — IVideoTexture (비디오 텍스처)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 메서드 | `play` | `0x1401fa510` | ✓ |
| 메서드 | `pause` | `0x1401fa560` | ✓ |
| 메서드 | `stop` | `0x1401fa580` | ✓ |
| 메서드 | `isPlaying` | `0x1401fa5d0` | ✓ |
| 메서드 | `setCurrentTime` | `0x1401fa650` | ✓ |
| 메서드 | `getCurrentTime` | `0x1401fa620` | ✓ |
| 메서드 | `addEndedCallback` | `0x1401fa730` | ✓ |
| 프로퍼티 | `rate` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `loop` | `0x1401a4a20` | ✓ |
| 프로퍼티 | `duration` | `0x1401fa690` | ✓ |

#### `0x14026c980` — IAnimationLayer (애니메이션 레이어)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 메서드 | `play` | `0x14026c420` | ✓ |
| 메서드 | `pause` | `0x14026c450` | ✓ |
| 메서드 | `stop` | `0x14026c460` | ✓ |
| 메서드 | `isPlaying` | `0x14026c480` | ✓ |
| 메서드 | `setFrame` | `0x14026c4a0` | ✓ |
| 메서드 | `getFrame` | `0x14026c4d0` | ✓ |
| 메서드 | `addEndedCallback` | `0x14026c4f0` | ✓ |
| 프로퍼티 | `visible` | `0x1401e1a90` | ✓ |
| 프로퍼티 | `additive` | `0x14019b4e0` | — |
| 프로퍼티 | `blendin` | `0x14019bfa0` | — |
| 프로퍼티 | `blendout` | `0x14025aca0` | — |
| 프로퍼티 | `name` | `0x1401a4bc0` | ✓ |
| 프로퍼티 | `rate` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `blend` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `blendtime` | `0x1401a4b00` | — |
| 프로퍼티 | `fps` | `0x14026c3e0` | ✓ |
| 프로퍼티 | `frameCount` | `0x14026c400` | ✓ |
| 프로퍼티 | `duration` | `0x14026c410` | ✓ |

#### `0x140177f70` — IAnimation (애니메이션 핸들)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 메서드 | `play` | `0x1401707f0` | ✓ |
| 메서드 | `pause` | `0x140170820` | ✓ |
| 메서드 | `stop` | `0x140170830` | ✓ |
| 메서드 | `isPlaying` | `0x140170860` | ✓ |
| 메서드 | `setFrame` | `0x140170880` | ✓ |
| 메서드 | `getFrame` | `0x1401708a0` | ✓ |
| 프로퍼티 | `rate` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `fps` | `0x140170770` | ✓ |
| 프로퍼티 | `frameCount` | `0x140170790` | ✓ |
| 프로퍼티 | `duration` | `0x1401707a0` | ✓ |
| 프로퍼티 | `name` | `0x1401707b0` | ✓ |

#### `0x1401f3460` — ICamera (카메라 오브젝트)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 프로퍼티 | `visible` | `0x1401e1a90` | ✓ |
| 프로퍼티 | `fov` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `zoom` | `0x1401a4b00` | ✓ |
| 프로퍼티 | `queuemode` | `0x1401f3a20` | — |

#### `0x140004540` — 베이스 오브젝트 (visible/name 공통)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 프로퍼티 | `visible` | `0x1401e1a90` | ✓ |
| 프로퍼티 | `name` | `0x1401a4bc0` | ✓ |

#### `0x1400043a0` — 베이스 오브젝트 (visible 단독)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 프로퍼티 | `visible` | `0x1401e1a90` | ✓ |

#### `0x14025da80` — (d.ts 미선언) 라이트 (라이트 오브젝트)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 프로퍼티 | `color` | `0x1401a4230` | ✓ |
| 프로퍼티 | `intensity` | `0x1401a4b00` | — |
| 프로퍼티 | `radius` | `0x1401a4b00` | — |
| 프로퍼티 | `exponent` | `0x1401a4b00` | — |
| 프로퍼티 | `innercone` | `0x1401a4b00` | — |
| 프로퍼티 | `outercone` | `0x1401a4b00` | — |
| 프로퍼티 | `density` | `0x1401a4b00` | — |
| 프로퍼티 | `volumetricsexponent` | `0x1401a4b00` | — |
| 프로퍼티 | `cascadedistance0` | `0x1401a4b00` | — |
| 프로퍼티 | `cascadedistance1` | `0x1401a4b00` | — |
| 프로퍼티 | `cascadedistance2` | `0x1401a4b00` | — |
| 프로퍼티 | `lightsourcesize` | `0x1401a4b00` | — |
| 프로퍼티 | `controlpoint` | `0x1401a4230` | — |
| 프로퍼티 | `light` | `0x14025eb40` | — |
| 프로퍼티 | `visible` | `0x1401e1a90` | ✓ |
| 프로퍼티 | `castshadow` | `0x1401e1a90` | — |
| 프로퍼티 | `usecookie` | `0x14019b4e0` | — |
| 프로퍼티 | `castvolumetrics` | `0x14019bfa0` | — |

#### `0x1401577e0` — (d.ts 미선언) 렌더스테이트 (머티리얼 렌더스테이트)

| 종류 | 이름 | 구현 VA | d.ts |
|---|---|---|---|
| 프로퍼티 | `blending` | `0x1401587d0` | — |
| 프로퍼티 | `alphawriting` | `0x140158b40` | — |
| 프로퍼티 | `depthtest` | `0x140158eb0` | — |
| 프로퍼티 | `depthwrite` | `0x140159220` | — |
| 프로퍼티 | `cullmode` | `0x140159590` | — |

---

## 4. scenescript64.dll 바인딩 — 전역과 IScene/IEngine 은 여기 있다

exe 등록부에는 `getLayer` · `createLayer` · `registerAsset` · `isRunningInEditor` 같은 이름이
**하나도 없다**(문자열 자체가 없다 — `scripts/re/xref.py` 로 0건). 그것들은 DLL 이 V8
템플릿에 직접 건다. 등록 형태가 exe 와 다르다.

```
0x181631273  lea  r8, [rip+0x10D6]      ; 0x181632350 = 콜백 썽크
0x1816312AD  call 0x180009770           ; FunctionTemplate::New(isolate, callback)
0x1816312B5  mov  dword ptr [rsp+0x20], 8
0x1816312BD  lea  r8, [rip+0x371CAC]    ; 0x1819A2F70 "getLayer"
0x1816312CE  call 0x180029B70           ; String::NewFromUtf8
0x1816312E0  call 0x1800090F0           ; Template::Set(name, template)
```

즉 **콜백 썽크 `lea` 가 이름 `lea` 보다 먼저** 온다. 아래 표는 그 규칙으로 짚었다.
썽크가 `-` 인 행은 이 규칙으로 못 짚은 것(접근자 등록은 게터를 이름 뒤에 싣는 형태가 섞여
있다)이지 "없다"는 뜻이 아니다 — 이름 문자열은 전부 `.rdata` 바인딩 군집
(`0x1819A2B50`–`0x1819A3C60`) 안에 있다.

#### IScene — 등록 구간 `0x181631200`–`0x181631a00`

| 이름 | 콜백 썽크 VA | 등록 지점 VA | d.ts 소속 |
|---|---|---|---|
| `getLayer` | `0x181632350` | `0x1816312bd` | IScene |
| `getLayerByID` | `0x181632620` | `0x18163133b` | IScene |
| `getLayerCount` | `0x181632950` | `0x1816313b6` | IScene |
| `enumerateLayers` | `0x181632c00` | `0x181631437` | IScene |
| `destroyLayer` | `0x181632fc0` | `0x1816314b5` | IScene |
| `createLayer` | `0x181633290` | `0x181631530` | IScene |
| `sortLayer` | `0x181634eb0` | `0x1816315b1` | IScene |
| `getLayerIndex` | `0x181635200` | `0x18163162f` | IScene |
| `getInitialLayerConfig` | `0x181634980` | `0x1816316aa` | IScene |
| `getCameraTransforms` | `0x181635540` | `0x18163172b` | IScene |
| `setCameraTransforms` | `0x1816359e0` | `0x1816317a9` | IScene |
| `getAnimation` | `0x181635ee0` | `0x181631824` | IObject,IScene |
| `createModelData` | `0x1816361f0` | `0x1816318a5` | IScene |
| `destroyModelData` | `0x181636890` | `0x181631923` | IScene |

#### IModelData / thisScene 전역 — 등록 구간 `0x181631a00`–`0x181632000`

| 이름 | 콜백 썽크 VA | 등록 지점 VA | d.ts 소속 |
|---|---|---|---|
| `thisScene` | `0x181631d00` | `0x181631a4f` | — |
| `applyData` | `0x181636b60` | `0x181631af0` | IModelData |
| `replaceData` | `0x181636ef0` | `0x181631b6b` | IModelData |
| `IModelData` | `-` | `0x181631bd4` | — |
| `prototype` | `-` | `0x181631c1c` | — |

#### IConsole / IEngine / IInput / ILocalStorage / 전역 — 등록 구간 `0x181648e00`–`0x18164a300`

| 이름 | 콜백 썽크 VA | 등록 지점 VA | d.ts 소속 |
|---|---|---|---|
| `thisLayer` | `0x1816467c0` | `0x181648e39` | — |
| `log` | `0x181654190` | `0x181648fcf` | IConsole |
| `error` | `0x1816541b0` | `0x181649065` | IConsole |
| `console` | `-` | `0x181649119` | — |
| `isRunningInEditor` | `0x181654d00` | `0x1816491c3` | IEngine |
| `isPortrait` | `0x181654d30` | `0x18164925c` | IEngine |
| `isLandscape` | `0x181654f50` | `0x1816492f5` | IEngine |
| `registerAudioBuffers` | `0x181655170` | `0x18164938e` | IEngine |
| `registerAsset` | `0x181655810` | `0x181649427` | IEngine |
| `setTimeout` | `0x181655e10` | `0x1816494c0` | IEngine |
| `setInterval` | `0x1816562d0` | `0x181649559` | IEngine |
| `clearTimeout` | `0x181656780` | `0x1816495f2` | — |
| `isMobileDevice` | `0x181656950` | `0x18164968b` | IEngine |
| `isDesktopDevice` | `0x181656980` | `0x181649724` | IEngine |
| `isWallpaper` | `0x1816569b0` | `0x1816497bd` | IEngine |
| `isScreensaver` | `0x1816569f0` | `0x181649856` | IEngine |
| `isObjectValid` | `0x181656a30` | `0x1816498ef` | — |
| `openUserShortcut` | `0x181656b70` | `0x181649988` | IEngine |
| `screenResolution` | `-` | `0x1816499cf` | IEngine |
| `canvasSize` | `0x181656d50` | `0x181649a2b` | IEngine |
| `userProperties` | `0x1816570b0` | `0x181649a87` | IEngine |
| `timeOfDay` | `0x181657410` | `0x181649ae3` | IEngine |
| `frametime` | `0x1816578b0` | `0x181649b3f` | IEngine |
| `runtime` | `0x181657ac0` | `0x181649b9b` | IEngine |
| `AUDIO_RESOLUTION_16` | `0x181657cd0` | `0x181649c17` | IEngine |
| `AUDIO_RESOLUTION_32` | `-` | `0x181649c77` | IEngine |
| `AUDIO_RESOLUTION_64` | `-` | `0x181649cd7` | IEngine |
| `engine` | `-` | `0x181649d5e` | — |
| `cursorWorldPosition` | `-` | `0x181649db6` | IInput |
| `cursorScreenPosition` | `0x181657ee0` | `0x181649e12` | IInput |
| `cursorLeftDown` | `0x181658110` | `0x181649e6e` | IInput |
| `input` | `0x181658470` | `0x181649f11` | — |
| `set` | `0x181658680` | `0x181649fbb` | ILocalStorage |
| `get` | `0x181658a80` | `0x18164a054` | ILocalStorage |
| `delete` | `0x181658f70` | `0x18164a0ed` | ILocalStorage |
| `clear` | `0x181659150` | `0x18164a186` | ILocalStorage |
| `global` | `-` | `0x18164a1cd` | — |
| `LOCATION_GLOBAL` | `-` | `0x18164a1f9` | ILocalStorage |
| `screen` | `-` | `0x18164a239` | — |
| `LOCATION_SCREEN` | `-` | `0x18164a265` | ILocalStorage |
| `localStorage` | `-` | `0x18164a2d8` | — |

### 4.1 폐포 검사

- **d.ts 선언인데 exe/DLL 어디에도 이름이 없는 것**: `IModelData` 의 상수 5개
  (`POSITION`/`NORMAL`/`TANGENT_SIGNED`/`UV`/`COLOR`)뿐이다. 그런데 d.ts 자신이
  `readonly POSITION: String = 'position'` 처럼 **값**을 적어 뒀고, DLL 은 그 소문자 값
  (`position` `0x181637A7C` · `normal` `0x181637ACC` · `tangentSigned` `0x181637B1C` ·
  `uv` `0x181637B6C` · `color` `0x181637BBC`)을 등록한다. 즉 상수 이름은 JS 쪽,
  값은 네이티브 쪽 — 폐포는 성립한다. `IRenderContext`/`renderContext` 만 진짜 미백업이다.
- **DLL 등록부에는 있는데 d.ts 에 없는 것**: `thisObject` · `clearTimeout` · `isObjectValid` ·
  `scriptProperties` · `__workshopId` · `_Internal`(+`convertUserProperties` /
  `updateScriptProperties` / `stringifyConfig`) · `_Vec2`.._Mat4 주입 슬롯 · `worldPosition`
  등 이벤트 필드 · `context`.

---

## 5. Waple 대조 — 구현됨 / 스텁 / 없음

방법: `TextScriptEngine.swift` 의 `static let shims` 리터럴을 그대로 뽑아 node `vm` 에서 평가한
뒤, d.ts 멤버 444개를 **각자의 소유 객체에 실제로 접근해** 분류했다. grep 이 아니라 실행이다.
"있다"의 판정은 세 가지를 가른다:

- **없음** — `undefined` 이거나 `__noopProxy()`(모든 접근을 흡수하는 프록시)로 떨어진다.
- **스텁** — 존재하고 예외도 안 나지만 **인자를 버리거나 관측 가능한 효과가 없다**.
- **구현됨** — WE 의미와 맞는 실제 동작이 있다.

| 분류 | 수 | 비율 |
| --- | ---: | ---: |
| 구현됨 | **137** | 30.9% |
| 스텁 | **40** | 9.0% |
| 없음 | **267** | 60.1% |

인터페이스별:

| 인터페이스 | 구현됨 | 스텁 | 없음 |
| --- | ---: | ---: | ---: |
| `IComponent`(훅) | 17 | 0 | 0 |
| `IEngine` | 17 | 0 | 4 |
| `ITextLayer` | 15 | 0 | 0 |
| `Vec3` | 13 | 0 | 25 |
| `Vec2` | 11 | 0 | 25 |
| `ILayer` | 7 | 3 | 8 |
| `ILocalStorage` | 6 | 0 | 0 |
| `IScene` | 5 | 7 | 21 |
| `ISoundLayer` | 4 | 0 | 1 |
| `IEffectLayer` | 4 | 0 | 1 |
| `IParticleSystem` | 4 | 1 | 1 |
| `IImageLayer` | 4 | 3 | 19 |
| `WEMath`/`WEColor` | 4+4 | 0 | 0 |
| `IEffect` | 3 | 2 | 1 |
| `IInput` | 3 | 0 | 0 |
| `IAnimation` | 3 | 7 | 1 |
| `AudioBuffers` | 3 | 0 | 0 |
| `CameraTransforms` | 3 | 0 | 1 |
| `ITextureAnimation` | 2 | 7 | 1 |
| `IModelLayer` | 2 | 2 | 3 |
| `IConsole` | 0 | 2 | 0 |
| `WEVector` | 2 | 0 | 0 |
| `IObject` | 0 | 1 | 0 |
| `IAnimationLayer` | 0 | 5 | 9 |
| `Vec4` / `Mat3` / `Mat4` | 0 | 0 | 34 / 25 / 30 |
| `IVideoTexture` | 0 | 0 | 10 |
| `IParticleSystemInstance` | 0 | 0 | 15 |
| `IModelData` | 0 | 0 | 7 |
| `ICamera` | 0 | 0 | 2 |
| 이벤트 클래스 6종 | 1 | 0 | 21 |

### 5.0 스텁 전수 — "있는 것처럼 보이지만 아무 일도 안 한다"

| 멤버 | d.ts | 동봉 | 설치본 | 실제로 하는 일 |
| --- | --- | ---: | ---: | --- |
| `IScene.createLayer` | :2175 | 2 | 4 | 설정을 반영하고 `layers` 에 넣지만 **GPU 렌더 경로에 붙지 않는다**(화면에 안 나온다) |
| `IScene.sortLayer` | :2180 | 2 | 3 | 요청 위치를 기록만 한다 — `layers` 위치 인덱스가 read-back 계약이라 재정렬 금지 |
| `IScene.destroyLayer` | :2153 | 0 | 2 | 배열에서 빼지 않고 툼스톤(`visible=false`)만 세운다 |
| `IScene.getInitialLayerConfig` | :2190 | 0 | 0 | 인자를 버리고 항상 항등 설정(origin 0 / angles 0 / scale 1) |
| `IScene.getCameraTransforms` | :2195 | 0 | 0 | 보관값/기본값을 돌려준다(실 카메라 상태 아님) |
| `IScene.setCameraTransforms` | :2200 | 0 | 0 | 값을 보관만 하고 카메라에 반영하지 않는다 |
| `IScene.getAnimation` | :2205 | 0 | 0 | 이름별 no-op 타임라인 심 — 플래그만 돈다 |
| `IObject.getAnimation` | :1254 | 0 | 0 | 위와 같다 |
| `IEffect.executeMaterialFunction` | :1295 | 0 | 0 | **요청 이름 적재까지 구현** — 인코더 배선 대기(§6) |
| `IEffect.setMaterialProperty` | :1290 | 0 | 0 | 실물은 *그 이름을 가진 머티리얼에만* 쓴다(`0x1401EE223` vtbl+0x20 조회) — 심은 전 머티리얼에 무조건 |
| `IConsole.log` / `.error` | :2285 · :2290 | 0 | 0 | 인자를 버리는 빈 함수 — 어디에도 출력되지 않는다 |
| `ITextureAnimation.play/pause/stop/isPlaying/getFrame/setFrame/rate` | :1326–1361 | 0 | 0 | 심 내부 플래그/값만 — 텍스처 애니가 실제로 돌지 않는다 |
| `IAnimation.play/pause/stop/isPlaying/getFrame/setFrame/rate` | :2534–2564 | 0 | 0 | 위와 같다 |
| `IAnimationLayer.play/pause/stop` · `.name` · `.blend` | :1452–1482 | 0 | 0 | 플래그/고정값 — 스켈레톤 블렌드에 반영 안 됨 |
| `IImageLayer.getAnimationLayer` / `createAnimationLayer` | :1810 · :1815 | 0 | 0 | 인자를 버리고 **공용** no-op 심 하나를 돌려준다 |
| `IModelLayer.getAnimationLayer` / `createAnimationLayer` | :1931 · :1936 | 0 | 0 | 위와 같다 |
| `IImageLayer.getTextureAnimation` | :1795 | 0 | 0 | no-op 텍스처 애니 심 |
| `IParticleSystem.emitParticles` | :1764 | 0 | 0 | 인자를 버리고 `this` 반환(방출 없음) |
| `ILayer.setParent`(2 오버로드) | :2079 · :2086 | 0 | 0 | 심 부모 포인터만 — 트랜스폼 재부모화 없음, `adjustTransforms`/`attachment` 인자 무시 |
| `ILayer.getChildren` | :2096 | 0 | 0 | 심이 `addChild` 로 채운 배열만 — 씬 트리 자식은 안 들어간다 |

**스텁 40개 중 동봉 도달이 있는 것은 `createLayer`(2)와 `sortLayer`(2) 둘뿐이다.**
나머지 36개는 도달 0 이라 이번에 짓지 않았다(과제 지시대로).

### 5.1 구현: `ITextLayer.pointsize` / `font` — 동봉 도달 각 2

**증상.** 심의 레이어 객체에 이 두 키가 아예 없었다. 동봉
`presets/clock/preview3dclock/scene.json` 의 텍스트 스크립트 `init()` 이

```js
shadowLayer = thisScene.createLayer({ …, pointsize: thisLayer.pointsize, font: thisLayer.font, … });
```

로 그 값을 그대로 설정에 싣는다 → `undefined` 가 실려 그림자 레이어의 글자 크기가 NaN 이 된다.

**근거.** d.ts:1606·1611. exe 등록부 `0x140258CA0`–`0x14025A713` 이 텍스트 오브젝트
프로퍼티로 `pointsize`(게터 `0x1401A4B00`) · `font`(게터 `0x1401A4BC0`)를 건다.

**한 일.**
- 심 레이어 객체에 `ITextLayer` 프로퍼티 15개를 전부 넣었다(`pointsize` · `font` ·
  `horizontalalign` · `verticalalign` · `anchor` · `padding` · `opaquebackground` ·
  `backgroundcolor` · `limitrows` · `maxrows` · `limitwidth` · `maxwidth` — `text`/`color`/`alpha`
  는 이미 있었다). 기본값은 `SceneDocument` 의 텍스트 파스 폴백과 동일
  (`font "systemfont_arial"` · `pointsize 16` — `SceneDocument.swift:1794-1795`).
- `SceneScriptLayerDescriptor` 에 `pointSize`/`font` 를 더하고 `layersJSONArray` →
  `__layerFromDescriptor` / `__updateSceneLayers` 양쪽에 실었다(마운트와 프레임 말 갱신이
  갈리지 않게 — `layersJSONArray` 주석의 단위 경계와 같은 규율).

**남은 배선(다른 레인 파일 — diff 후보)**: `SceneRenderer.sceneScriptLayers(from:)`
(`Sources/WapleRender/SceneRenderer.swift:246-257`)의 `doc.texts.map` 에 두 줄:

```swift
                text: text.text,
+               pointSize: text.pointSize,
+               font: text.font
```

이게 붙기 전까지 텍스트 레이어는 기본값 16 / `systemfont_arial` 을 본다(종전의 `undefined`
보다는 정확하지만 실값은 아니다).

### 5.2 구현: `IScene.createLayer(설정 객체)` — 동봉 도달 2

d.ts:2175 는 `configuration: String|Object|IAssetHandle|IModelData` 다. 심은 인자를 무조건
`String(name || '')` 로 밟아 **설정 객체를 통째로 버렸다**(이름이 문자열
`"[object Object]"` 가 됐다). 설정 키는 씬 JSON 오브젝트와 같은 이름이라
(`text`/`color`/`alpha`/`pointsize`/`font`/`perspective`/`origin`/`angles`/`scale`/…)
그 규약으로 심 레이어 필드에 얹는다. 벡터 키는 `"r g b"` 문자열·배열·`Vec` 셋 다 받는다.
문자열 인자 경로는 **문자 그대로 종전과 같다**(무회귀).

한계는 그대로다 — 이 레이어는 `thisScene.layers` 에만 있고 GPU 렌더 경로에 붙지 않는다.
그래서 1회 경고도 남겨 뒀다.

### 5.3 구현: `IScene.sortLayer` 반환형 + 요청 기록 — 동봉 도달 2

d.ts:2180 은 `Boolean` 을 돌려준다. 종전은 인자를 전부 버리고 `this`(씬)를 돌려줬다 —
씬은 truthy 라 **실패해도 성공처럼 보였고** 형도 틀렸다. 이제 대상(`String|Number|ILayer`)과
인덱스를 검증해 Boolean 을 돌려주고, 요청 위치를 `__wapleSortIndex` 로 기록한다.

**배열을 실제로 재정렬하지 않는 이유**: `thisScene.layers` 의 위치 인덱스는 렌더러
read-back 채널(`readBackScriptLayerState`)이 `doc.layers` 인덱스로 직접 참조하는 계약이라
(같은 이유로 `destroyLayer` 도 툼스톤이다) 순서를 바꾸면 그 뒤 모든 레이어 값이 어긋난다.

### 5.4 구현: `IScene.getLayerIndex(String)` — 설치본 도달 3

d.ts:2185 는 `String|ILayer` 를 받는다. 종전은 `indexOf` 만 해서 문자열이면 항상 0 이었고,
그 0 이 그대로 `sortLayer` 에 들어가 레이어를 맨 앞으로 밀었다
(WE 동봉 `dino_run` `objects[22].visible` 이 `thisScene.getLayerIndex('postprocess')` 를 쓴다).
이름 조회 규약은 `getLayer` 와 같은 첫 일치이고, 못 찾으면 종전과 같이 0 이다
(인덱스 질의가 씬에 폴백 레이어를 만들면 안 되므로 `getLayer` 와 달리 생성하지 않는다).

---

## 6. `executeMaterialFunction` — 알려진 스텁의 실물과 배선 후보

### 6.1 실물이 하는 일

이름 `0x1401F0156`(길이 0x17) · 구현 포인터 `0x1401F016C` → **`0x1401EE3A0`–`0x1401EE51B`**.

| 위치 | 코드 | 의미 |
| --- | --- | --- |
| `0x1401EE3AD` | `mov rsi,[rcx+0x100]` / `mov rbp,[rcx+0x108]` | 함수 레코드 벡터 begin/end (stride **0x40**) |
| `0x1401EE3BE` | `mov rdi,[r9]` | 인자 = 함수 이름(UTF-8) |
| `0x1401EE3D7` | `call 0x140421E00` | `strlen(name)` |
| `0x1401EE3DC`–`0x1401EE401` | 길이 비교 + `memcmp` | 레코드 `+0x08`(SSO 문자열) 과 대조 — **첫 일치** |
| `0x1401EE411` | `(rsi+0x30 − rsi+0x28) >> 2` | 레코드의 `std::vector<int> fboIndices` 길이 |
| `0x1401EE440` | `mov rbx,[r14+0xE8]` / `rdi = k*0x50` | FBO 레코드 배열(stride 0x50) |
| `0x1401EE468` | `call [rax+0x48]` | 그 FBO 를 렌더 타깃으로 **push** |
| `0x1401EE472`–`0x1401EE491` | `movss` ×4 (`+0x14/+0x18/+0x1C/+0x20`) | `fbos[].clear` 파스 결과(RGBA) |
| `0x1401EE49A` | `call [rax+0x118]` | 클리어색 설정 |
| `0x1401EE4B6` | `call [rax+0x120]` (`dl=1`, `r8d=0`) | **색만** 클리어(깊이 없음) |
| `0x1401EE4BC`–`0x1401EE4E7` | pop | 타깃 복원 |

파스 쪽(`0x1401E8248`–`0x1401E88A1`)은 이미 `EffectManifest.Function` 으로 들어와 있다
(`Sources/WapleCore/EffectManifest.swift:249-297` 의 주석이 정본). 동봉 자산 도달은 1건 —
`effects/fluidsimulation/effect.json` 의 `clearVelocity` / `clearDye`.

### 6.2 이번에 한 일

심의 `executeMaterialFunction` 은 `return m` / `return e` 로 **이름조차 보지 않았다**.
이제 요청 이름을 호출 순서대로(중복 보존) 적재하고 `void` 를 돌려준다(d.ts:1295).
네이티브 쪽에 드레인 접근자를 냈다:

```swift
public func drainMaterialFunctionCalls() -> [String]
```

읽으면 비운다(실물이 호출 즉시 1회 클리어하는 것과 같은 소비 규약). `owner == .layer`
(레이어 프로퍼티 스크립트 — 전체의 대다수)는 항상 빈 배열이라 호출자 무영향.
적재 상한 64 — 이름은 JS 인자라 신뢰 경계 밖이다.

### 6.3 배선 diff 후보 (이 레인이 만지지 않은 파일)

클리어는 렌더 패스라 스크립트 엔진이 직접 못 한다. 소비처는 이미 있다 —
`SceneRendererResources.EffectFBOStore.pendingClear`(`SceneRendererResources.swift:101`)에
인덱스를 넣으면 `SceneRendererFrameEncoder.swift:2084-2095` 의 클리어 전용 렌더 패스가
`fboSpecs[i].clearColor` 로 비우고 비운다. **실물과 같은 색·같은 "색만" 클리어**다.

**(a) `Sources/WapleRender/SceneRendererResources.swift`** — 이펙트 스크립트 엔진을 게이트에만
보관하지 말고 매니페스트와 함께 들고 있어야 한다. 현재 `~:258-270` 이

```swift
if let engine = makeScriptEngine(vs, scriptPropsJSON: eff.visibleScriptProps,
                                 owner: .effect(materials: eff.passList.map(\.constants))) {
    if engine.hasUpdate { visibleGate = EffectVisibleGate(engine: engine, initial: eff.initialVisible) }
    …
    effectMaterialWrites = engine.boundObjectMaterialWrites
}
```

이므로 **로드 시점 1회분**은 여기서 바로 소비할 수 있다:

```swift
+   // T09-D1: 로드/applyUserProperties/init 이 남긴 executeMaterialFunction 요청 → 첫 프레임 클리어 예약.
+   scriptFunctionClears = engine.drainMaterialFunctionCalls()
+       .compactMap { eff.manifest?.function(named: $0) }
+       .flatMap(\.fboIndices)
```

**(b) `Sources/WapleRender/SceneRendererFrameEncoder.swift`** — `update` 가 있는 스크립트는
매 프레임 요청할 수 있으므로 `uniqueStore.pendingClear` 채우는 자리(`~:2076`, `fboTex` 를
다 만든 **직후** · 클리어 루프 `~:2084` **직전**)에 한 덩이:

```swift
+   // T09-D1: 실물 0x1401EE3A0–0x1401EE51B 과 같은 순서 — 이름으로 functions 를 찾아 그 FBO 를
+   // 그 FBO 의 clear 색으로 비운다. 없는 이름은 무시(실물도 선형 탐색 실패 시 아무 일 안 함).
+   if let engine = gpu.visibleGate?.engine {
+       for name in engine.drainMaterialFunctionCalls() {
+           guard let fn = manifest.function(named: name) else { continue }
+           for i in fn.fboIndices where i < fboTex.count { uniqueStore.pendingClear.insert(i) }
+       }
+   }
```

선행 조건 두 가지: `EffectVisibleGate.engine` 이 접근 가능해야 하고(현재 `private` 이면 완화),
`EffectGPU` 가 자기 `EffectManifest`(또는 최소한 `functions` 배열)를 들고 있어야 한다.

주의: `pendingClear` 는 **`spec.unique` FBO 전용 저장소**의 예약 집합이다.
`fluidsimulation` 의 `_rt_Smoke*` 는 전부 `unique` 라 도달 자산에서는 문제가 없지만,
비-unique FBO 를 지목하는 함수가 오면 그 프레임의 풀 텍스처를 비우는 것이 되어 의미가 다르다.
그런 자산은 동봉에 0건이다.

---

## 7. 검증

- 심 JS 는 `scripts/spec/check_js_shim_baseclasses.py` 로 단독/`baseclasses.js` 병행 평가를
  모두 통과한다(음성 대조 selftest 포함).
- 동봉 `presets/clock/preview3dclock` 스크립트 원문을 심 위에서 그대로 `init()` + `update()`
  까지 돌려, 그림자 레이어가 `pointsize 24` · 실제 폰트 경로를 물려받고 매 프레임
  `angles`/`origin`/`text` 가 갱신되는 것을 확인했다.
- Swift 회귀는 `Tests/WapleRenderTests/SceneScriptAPISurfaceTests.swift` (11건).

## 8. 재현

```bash
# 문자열 xref (exe)
WE_ROOT=<WE설치본> python3 scripts/re/xref.py executeMaterialFunction getMaterial

# 선행 정본(문자열 군집 기반)
python3 scripts/spec/measure_script_api.py     # → spec/engine/script-api.json

# 심 JS 정합
python3 scripts/spec/check_js_shim_baseclasses.py
```

이 문서의 등록부 스캔(‌`0x14000F880` 호출 사이트 → 이름/구현 VA 추출, DLL 의
`FunctionTemplate::New` 썽크 페어링)은 1회용 분석이라 스크립트로 남기지 않았다.
다시 필요하면 §3.1 · §4 의 패턴 그대로 재현된다.
