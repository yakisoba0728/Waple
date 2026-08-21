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

**[2026-08-21 추가] 결함이 둘이 아니라 넷이다.**

- `ITextLayer.padding`(:1616)이 **`Number` 로 선언돼 있는데 실물은 vec2 다.** 텍스트 디스크립터
  등록 `0x140259421` 의 타입 태그가 **1**(= vec2)이고 멤버는 `+0x4e8` 이다 — 같은 태그 1 인
  형제 키는 `spacing`(`0x1402594f4`, `+0x4f8`)과 `dropshadowoffset`(`0x140259d61`, `+0x53c`) 로,
  둘 다 이름부터 2성분이다. 생성자도 두 성분을 따로 심는다:
  `0x140256bbf` `mov dword [rdi+0x4e8], 0x42000000` · `0x140256bc9` `mov dword [rdi+0x4ec], 0x42000000`
  (= **(32.0, 32.0)**). 대조군으로 같은 등록부의 진짜 스칼라 float 키는 태그 **4** 다
  (`pointsize` `0x140259363`/`+0x4e0` · `maxwidth` `0x1402595af`/`+0x508` ·
  `outlinethickness` `0x1402599e8`/`+0x520`). 정렬 검증: 태그/오프셋을 생성자 스토어와 3건 대조했다
  — `pointsize`↔`0x140256bf2`(`mov dword [rdi+0x4e0], 0x42000000` = 32.0) ·
  `outlinethickness`↔`0x140256c43`(`mov dword [rdi+0x520], 0x40800000` = 4.0) ·
  `anchor`↔`0x140256c99`(`mov byte [rdi+0x550], al`, `al` 은 `0x140256be6` 의 `xor eax,eax` 이후
  재대입이 없어 **0** = enum "none"). 세 건이 다 맞으므로 이 덤프는 한 칸 밀리지 않았다.
- `AnimationEvent`(:1012)는 **선언돼 있는데 이 클래스를 받는 `IComponent` 멤버가 없다.**
  고아가 아니라 선언 누락이다 — 실물 훅 테이블(§9.2)의 id 6 이 `animationEvent` 이고 그것이
  이 클래스의 소비자다. 같은 형태로 `CursorEvent.hitBox`(:1045)는 id 7 `cursorHitTest` 의 잔재다.

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

**[2026-08-21] 남은 배선은 `8de9dba` 로 들어왔다** — `SceneRenderer.sceneScriptLayers(from:)`
의 `doc.texts.map` 이 `pointSize: text.pointSize, font: text.font` 를 넘긴다. 그 커밋이
드러낸 더 큰 사실은 §9 로 옮겨 적었다: **같은 부류(디스크립터에 자리가 없거나 인자를 안 넘겨
심의 하드코딩 기본값이 저작값 대신 보이는 필드)가 하나가 아니라 전수로 있었다.**

이 절이 적어 둔 심 기본값 `pointsize 16` 도 그 사이에 낡았다 — `SceneDocument.parseText` 의
폴백이 WE 생성자(`0x140256bf2` `mov dword [rdi+0x4e0], 0x42000000`)대로 **32** 로 정정되면서
16 은 어느 쪽 규약도 아니게 됐다. 심 기본값도 32 로 맞췄다(§9.3).

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
- Swift 회귀는 `Tests/WapleRenderTests/SceneScriptAPISurfaceTests.swift` (**19건** — 2026-08-21에
  §9 용 6건 추가). 이 타깃은 macOS 전용이라 리눅스 레인에서는 못 돌린다(§9 의 검증 절 참조).

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

---

## 9. 디스크립터 배선 전수 감사 (2026-08-21)

`8de9dba` 가 `SceneRenderer.sceneScriptLayers(from:)` 의 텍스트 분기에서 `pointSize`/`font` 를
**안 넘겨** `thisLayer.pointsize` 가 저작값과 무관하게 늘 16 이던 결함(G15)을 고쳤다. 이 절은
그 결함이 **한 건이 아니라 부류**임을 전수로 확인한 결과다.

부류의 정의: **씬 문서에는 파스돼 있는데 `SceneScriptLayerDescriptor` 를 못 건너서, JS 심의
하드코딩 기본값이 저작값 대신 스크립트에 보이는 것.** 화면은 안 바뀌므로 렌더 회귀 테스트로는
안 잡히고, `SceneScriptAPISurfaceTests` 도 디스크립터를 **직접** 만들어 검증하므로 못 잡는다.
잡히는 유일한 지점이 이 표다.

### 9.1 전수표

세 열의 뜻:
- **문서** — `SceneDocument` 에 그 값이 파스돼 있는가.
- **종전** — 2026-08-21 이전에 JS 가 실제로 보던 값.
- **도달** — 워크샵 코퍼스(`spec/corpus/scene-schema.json`, **162씬** · 이미지 오브젝트 4,713 ·
  텍스트 오브젝트 1,597)에서 그 키를 **저작한** 오브젝트 수. "스크립트가 읽는 수"가 아니라
  "값이 있는데 안 넘어가는 수"다.

#### (a) 이미지 레이어 분기 (`doc.layers.map`)

| 디스크립터 필드 | d.ts | 문서 | 종전 | 도달(워크샵) |
|---|---|---|---|---|
| `name` `visible` `alpha` `origin`(xyz) `size` `id` `parentId` `animationLayerCount` | ✓ | ✓ | **실값** | — |
| `scale` | :2034 | `Vec2` 뿐 | z 를 **1 로 고정** | `scale` 3,055 (성분 분해는 [미해결]) |
| `angles` | :2029 | `angleZ` 뿐 | x·y 를 **0 으로 고정** | `angles` 3,264 (동봉 171씬 중 x·y≠0 이 1건, 설치본 184씬 중 7건) |
| `solid` | :2054 | `isSolid`(bit13, ctor 기본 **true**) | `textureEntryName.isEmpty` — **다른 값** | `solid` 149 (그 밖 4,564 는 ctor 기본 true) |
| **`color`** | :1785 | ✓ | **항상 (1,1,1)** | **1,372 / 110씬** |
| **`parallaxDepth`** | :2039 | ✓ | **`undefined`**(심에 프로퍼티 자체가 없었다; 등록 `0x1401e0840` 태그 1 = vec2 `+0x170`) | **1,573 / 121씬** |
| **`alignment`** | :1790 | ✓ | **`undefined`**(동상, 등록 `0x14021114b` 태그 5 `+0x4b1`) | **556 / 64씬** |
| **`perspective`** | :1565 | ✓ | 항상 `false` | **88 / 28씬** |
| `brightness` | 선언 없음 | ✓ | 없음 | 248 / 26씬 (d.ts 밖이라 이번 범위 밖) |

#### (b) 텍스트 분기 (`doc.texts.map`)

| 디스크립터 필드 | d.ts | 문서 | 종전 | 도달(워크샵) |
|---|---|---|---|---|
| `name` `visible` `alpha` `origin`(xy) `scale` `text` `pointSize` `font` | ✓ | ✓ | **실값** | — |
| **`id`** | :2138 소비 | ✓ | **항상 0** → `getLayerByID` 로 텍스트를 못 찾고 부모 배선에서도 빠진다 | **1,597 / 123씬 (전건)** |
| **`parentId`** | :2091 소비 | ✓ | **항상 nil** → `getParent()` 가 언제나 루트 | **1,236 / 88씬** |
| **`angles`** | :2029 | `angleZ` | **항상 (0,0,0)** | **1,315 / 104씬** |
| **`origin.z`** | :2024 | `originZ` | **항상 0** | (3D 텍스트 한정 — 워크샵 성분 분해 [미해결]) |
| **`solid`** | :2054 | `isSolid` | **항상 false** | 52 저작 + 나머지 1,545 는 ctor 기본 true |
| **`color`** | :1586 | ✓ | **항상 (1,1,1)** | **1,200 / 101씬** |
| **`horizontalalign`** | :1621 | ✓ | 항상 "center" | **1,597 (전건)** — 값 분포 center 1,334 · left 164 · right 99 |
| **`verticalalign`** | :1626 | ✓ | 항상 "center" | **1,597 (전건)** |
| **`anchor`** | :1632 | ✓ | 항상 "none" | **1,429 / 111씬** |
| **`padding`** | :1616 | `Vec2` | **`0`(Number)** — 형도 값도 틀렸다 | **1,597 (전건)** |
| **`opaquebackground`** | :1596 | ✓ | 항상 false | **1,426 / 110씬** |
| **`backgroundcolor`** | :1601 | ✓ | 항상 (0,0,0) | **1,426 / 110씬** |
| **`limitrows`/`maxrows`** | :1637 :1642 | `maxRows: Int?` | 항상 false / 1 | **1,594 / 121씬** |
| **`limitwidth`/`maxwidth`** | :1647 :1652 | `maxWidth: Float?` | 항상 false / 500 | **1,594 / 121씬** |
| `parallaxDepth` | :2039 | **파스 없음** | `undefined` | 956 — `spec/corpus/scene-schema.json` `waple.gapImpact` 가 이미 아는 갭 |
| `size` | :1560 | 없음 | `(0,0)` 고정 | 실물은 래스터된 텍스트의 픽셀 크기 — **[미해결]** |

굵은 줄이 이번에 확인한 G15 부류다. **이미지 4개 + 텍스트 14개.**

### 9.2 훅 테이블 전수 — `scenescript64.dll` `0x1819a3ee0`

이름 포인터 테이블을 직독하고 소비자를 디스어셈해 **19엔트리**를 확정했다
(`docs/re/pointer-interaction.md` §5.1 의 독립 재현 — 이름·VA·개수가 전건 일치한다).

소비자 `0x18164bfa0`(primary) 의 루프:

```
0x18164c59d  xor  r14d, r14d                 ; id = 0
0x18164c5a0  lea  rax, [rip+0x357939]        ; 0x1819a3ee0 = 이름 포인터 테이블
0x18164c5a7  mov  r15d, 1                    ; bit = 1
0x18164c5b0  mov  r8, [rax + r14*8]          ; name = table[id]
0x18164c5c7  call 0x180029c50                ; v8 Object::Get(module, name)
0x18164c5fa  call 0x180016480                ; IsFunction()
0x18164c645  mov  [rcx + r14*8 + 0x40], rax  ; 훅 핸들 캐시
0x18164c64a  or   [rcx + 0xd8], r15d         ; 존재 비트마스크 |= 1<<id
0x18164c651  rol  r15d, 1
0x18164c65e  cmp  r14, 0x13                  ; **19회**
```

| id | 이름 | 문자열 VA | `d.ts` `IComponent` | Waple 수집 |
|---:|---|---|:---:|:---:|
| 0 | `init` | `0x1819a3904` | ✓ | ✓ (lifecycle) |
| 1 | `update` | `0x1819a390c` | ✓ | ✓ |
| 2 | `resizeScreen` | `0x1819a3918` | ✓ | **없었음 → 수집 추가**(발화 배선 미완, §9.5) |
| 3 | `destroy` | `0x1819a3928` | ✓ | **없었음 → 수집 추가**(동상) |
| 4 | `applyUserProperties` | `0x1819a3930` | ✓ | ✓ (lifecycle) |
| 5 | `applyGeneralSettings` | `0x1819a3948` | ✓ | **없었음 → 수집 추가**(동상) |
| 6 | `animationEvent` | `0x1819a3960` | **없음** | ✓ (발화까지 배선됨) |
| 7 | `cursorHitTest` | `0x1819a3970` | **없음** | **일부러 안 한다** — exe 발화 0곳(죽은 훅) |
| 8 | `cursorEnter` | `0x1819a3980` | ✓ | ✓ |
| 9 | `cursorLeave` | `0x1819a3990` | ✓ | ✓ |
| 10 | `cursorMove` | `0x1819a39a0` | ✓ | ✓ |
| 11 | `cursorClick` | `0x1819a39b0` | ✓ | ✓ |
| 12 | `cursorDown` | `0x1819a39c0` | ✓ | ✓ |
| 13 | `cursorUp` | `0x1819a39d0` | ✓ | ✓ |
| 14 | `mediaStatusChanged` | `0x1819a39e0` | ✓ | ✓ |
| 15 | `mediaPlaybackChanged` | `0x1819a39f8` | ✓ | ✓ |
| 16 | `mediaPropertiesChanged` | `0x1819a3a10` | ✓ | ✓ |
| 17 | `mediaThumbnailChanged` | `0x1819a3a28` | ✓ | ✓ |
| 18 | `mediaTimelineChanged` | `0x1819a3a40` | ✓ | ✓ |

인자 형태는 d.ts 선언대로다(`init`/`update` 는 바인드 프로퍼티 값 1개, `resizeScreen(Vec2)`,
`applyUserProperties(Object)`, `applyGeneralSettings(Object)`, cursor 6종 `(CursorEvent)`,
media 5종 각자의 이벤트 클래스). d.ts 에 없는 둘의 인자는 d.ts 가 **클래스만** 남겨 뒀다 —
id 6 은 `AnimationEvent{name, frame}`(:1012), id 7 은 `CursorEvent.hitBox`(:1045).

**도달(코퍼스 3종 전수, `export function <이름>` 실측)**: `update` 26 · `init` 10 ·
`applyUserProperties` 4 · `cursorDown` 2 · `cursorClick`/`cursorUp`/`cursorMove` 각 1.
id 2·3·5·7 은 동봉 6 · 설치본 15 · 공식 스니펫 15 어디에도 **0건**이다 — 그래서 발화 배선을
지금 짓지 않고 수집까지만 했다.

### 9.3 이번에 고친 것 (`TextScriptEngine.swift`)

1. **디스크립터에 자리를 만들었다** — §9.1 굵은 줄 전부(`color` `parallaxDepth` `alignment`
   `perspective` `horizontalAlign` `verticalAlign` `anchor` `padding` `opaqueBackground`
   `backgroundColor` `limitRows`/`maxRows` `limitWidth`/`maxWidth`). 이니셜라이저 인자가 아니라
   기본값 있는 `var` 라, 실값을 아직 안 채우는 호출부는 **문자 그대로 종전과 같은 값**을 본다.
2. **`layersJSONArray(_:full:)`** — 마운트(`__setSceneLayers`)만 정적 표면을 싣고 프레임 말
   갱신(`__updateSceneLayers`)은 종전 14키 그대로다. 정적 값은 프레임마다 같으므로 다시 실을
   이유가 없고, 레이어 수 × 14키의 매 프레임 JSON 직렬화 비용만 는다.
3. **심 기본값 정정** — `pointsize` 16 → **32**(§5.1), `padding` `0`(Number) → **`Vec2(32,32)`**
   (§1.1의 태그 1 근거). `createLayer` 설정 키 매핑도 `padding` 을 Number 표에서 Vec2 표로 옮겼다
   (숫자 하나가 오면 `Vec2` 생성자가 두 성분에 브로드캐스트 — 실물 vec2 주입기의 태그 1/2/3
   경로와 같은 규약).
4. **심에 없던 프로퍼티 추가** — `parallaxDepth`(:2039) · `alignment`(:1790). 종전엔 읽으면
   `undefined` 라 그 값을 쓴 산술이 통째로 NaN 이었다.

### 9.4 §2 코퍼스 재측정 — "호출되는데 심에 없는 것" 둘

§2 의 도달 측정을 재현했다(동봉 6 · 설치본 15 · 공식 스니펫 15 — 종전 수치와 일치).
그 위에 **공식 스니펫**(`ui/dist/monaco/snippets/`, 편집기가 "Bind SceneScript" 로 그대로
붙여 넣는 정본 15개)을 다시 훑어 두 건을 찾았다.

- **`IEffectLayer.transformAttachmentToTexture`**(d.ts:1555 · exe `0x1401ed0d0`) — 심에 **없었다**.
  `script_project_attachment.js` · `script_project_attachment_angle.js` 가

  ```js
  return thisLayer.transformAttachmentToTexture(thisScene.getLayerByID('{{ID}}'), '{{NAME}}').translation();
  ```

  로 부른다(스니펫 15개 중 **2건**). 첫 `update` 에서
  `TypeError: thisLayer.transformAttachmentToTexture is not a function` 이 나고 **그 스크립트가
  통째로 죽는다**. 부착점 본 트랜스폼은 렌더 경로 소유라 심이 계산할 근거가 없으므로
  `getEffect`/`getVideoTexture` 와 같은 `__noopProxy` 규약으로 **죽지만 않게** 했다 — 반환
  프록시의 `.translation()`/`.angle()` 도 프록시라 `floatArray(from:)` 가 `nil`(= 직전 값 유지)로
  떨어뜨린다. **identity `Mat3` 를 돌려주면 안 된다**: 그러면 origin 이 (0,0) 으로 튀어 오히려
  회귀다.
- **`IScene.getLayerByID` 가 문자열을 못 받았다**(d.ts:2138 은 `id: String` 이다). 위 스니펫이
  `getLayerByID('{{ID}}')` 로 **따옴표 안에** 정수 id 를 심는데 심은 `__wapleId === id` 로
  비교했다 — number `===` string 이라 **항상 null** 이었다. 문자열화 비교로 고쳤다
  (`__wapleId` 0 = "id 미지정" 은 매칭에서 제외).

두 건은 §9.1 (b) 의 `id` 미배선과 **겹쳐서** 나쁘다: 문자열 비교를 고쳐도 텍스트 레이어는
디스크립터가 `id` 를 안 실어 여전히 못 찾는다. 둘 다 필요하다.

### 9.5 넘길 것 — `SceneRenderer.sceneScriptLayers(from:)` (다른 레인 소유)

`Sources/WapleRender/SceneRenderer.swift:230-266`. 위 자리를 실값으로 채우는 패치다.
**이 패치 없이는 §9.3 의 새 필드가 전부 기본값 그대로다**(그래서 무회귀이고, 그래서 미완이다).

```swift
        let imageLayers = doc.layers.map { layer -> SceneScriptLayerDescriptor in
            var d = SceneScriptLayerDescriptor(
                name: layer.name,
                visible: layer.initialVisible,
                alpha: layer.alpha,
                origin: SIMD3<Float>(layer.origin.x, layer.origin.y, layer.originZ),
                scale: SIMD3<Float>(layer.scale.x, layer.scale.y, 1),
                angles: SIMD3<Float>(0, 0, layer.angleZ),
                size: SIMD2<Float>(layer.size.x, layer.size.y),
                solid: layer.textureEntryName.isEmpty,
                id: layer.id, parentId: layer.parent,
                animationLayerCount: layer.animationLayers.count
            )
            // T-G15: 종전엔 자리가 없어 JS 가 심 기본값(흰색 / (1,1) / "center" / false)을 봤다.
            d.color = SIMD3<Float>(layer.color.x, layer.color.y, layer.color.z)
            d.parallaxDepth = SIMD2<Float>(layer.parallaxDepth.x, layer.parallaxDepth.y)
            d.alignment = layer.alignment
            d.perspective = layer.perspective
            return d
        }
        let textLayers = doc.texts.map { text -> SceneScriptLayerDescriptor in
            var d = SceneScriptLayerDescriptor(
                name: text.name,
                visible: text.initialVisible,
                alpha: text.alpha,
                // T-G15: originZ/angleZ/id/parent 는 텍스트에도 파스돼 있는데 종전엔 안 넘겨
                // JS 가 0 / 0 / 0 / 루트를 봤다. id 누락은 getLayerByID 와 부모 배선을 동시에 막는다.
                origin: SIMD3<Float>(text.origin.x, text.origin.y, text.originZ),
                scale: SIMD3<Float>(text.scale.x, text.scale.y, 1),
                angles: SIMD3<Float>(0, 0, text.angleZ),
                size: SIMD2<Float>(0, 0),
                text: text.text,
                id: text.id, parentId: text.parent,
                pointSize: text.pointSize, font: text.font
            )
            d.color = SIMD3<Float>(text.color.x, text.color.y, text.color.z)
            d.horizontalAlign = text.horizontalAlign
            d.verticalAlign = text.verticalAlign
            d.anchor = text.anchor
            d.padding = SIMD2<Float>(text.padding.x, text.padding.y)
            d.opaqueBackground = text.opaqueBackground
            d.backgroundColor = SIMD3<Float>(text.backgroundColor.x, text.backgroundColor.y,
                                             text.backgroundColor.z)
            // maxRows/maxWidth 는 nil=무제한이라 게이트와 값으로 갈라 싣는다(WE 도 따로 등록한다 —
            // limitrows 0x140258ff7 · maxrows 0x14025966d).
            d.limitRows = text.maxRows != nil
            d.maxRows = text.maxRows ?? 1
            d.limitWidth = text.maxWidth != nil
            d.maxWidth = text.maxWidth ?? 500
            return d
        }
```

**따로 판단할 것 — `solid`.** d.ts:2054 의 `ILayer.solid` 는 실물에서 등록 `0x1401e1283`
(타입 6 = 플래그 비트, 멤버 `+0x120`)이고 `SceneDocument` 는 그것을 `isSolid`(bit13, ctor 기본
**true**)로 파스한다. 그런데 디스크립터는 이미지 분기에서 `layer.textureEntryName.isEmpty`
(= "텍스처가 없다")를 싣고 텍스트 분기에서는 아예 안 싣는다. 셋이 서로 다른 값이다.
`layer.isSolid` / `text.isSolid` 로 바꾸는 것이 실물 규약이지만, **스크립트 도달이 세 코퍼스
전건 0** 이라 그림이 바뀌는 씬은 확인되지 않는다. 바꾸면 텍스트 1,545개 + 이미지 다수의
`thisLayer.solid` 가 false→true 로 뒤집히므로, 이 레인에서 단독으로 밀어 넣지 않고 넘긴다.

### 9.6 넘길 것 — `SceneDocument` (다른 레인 소유)

디스크립터가 아니라 **파스**에서 값이 사라지는 것들이라 여기서는 못 고친다.

- `SceneLayer.scale` 이 `Vec2` 라 씬 JSON 의 `scale.z` 가 소실된다(동봉 171씬 중 71 오브젝트,
  설치본 184씬 중 92 — 전건 균일 3성분 `"s s s"`). JS 는 `thisLayer.scale.z` 를 늘 1 로 본다.
- `SceneLayer.angleZ`/`SceneTextLayer.angleZ` 뿐이라 `angles.x`/`.y` 가 소실된다(동봉 1 · 설치본 7
  오브젝트가 x·y≠0). 2D 렌더에는 무영향이지만 JS 표면은 틀린다.
- `SceneTextLayer` 에 `parallaxDepth` 필드가 없다(워크샵 텍스트 1,597 중 956). 이미
  `spec/corpus/scene-schema.json` 의 `waple.gapImpact` 가 렌더 갭으로 적어 둔 항목이고,
  스크립트 표면 갭이기도 하다.
- `spec/corpus/scene-schema.json` 의 `waple.valueShapeMismatch` 가 아직
  "`SceneTextLayer.spacing` 은 `Float?`" 라고 적고 있는데 현재 코드는 `Vec2?` 다 — 스펙 덤프가
  낡았다(재측정 대상).

### 9.7 검증

리눅스 레인에서 끝낼 수 있는 것은 다 끝냈다. macOS 전용은 그렇다고 명시한다.

| 무엇 | 어떻게 | 결과 |
|---|---|---|
| 심 JS 문법·`baseclasses.js` 공존 | `python3 scripts/spec/check_js_shim_baseclasses.py` | OK (음성 대조 selftest 포함) |
| Swift 리터럴 이스케이프 | `python3 scripts/spec/check_swift_escapes.py` | 위반 0 / 셰이더 주석 파손 0 |
| `Sources/WapleRender/**` 타입체크 | `scripts/dev/linux-render-typecheck.sh` | 커버 51파일 rc=0 |
| 심 동작(정적 표면·`getLayerByID` 문자열·부착점 스니펫) | 심 리터럴을 뽑아 node `vm` 에서 직접 평가 | 30 프로브 전건 기대값 |
| 디스크립터 → JSON(`layersJSONArray`) | 소스에서 구조체+함수 **원문을 그대로 뽑아** 리눅스 `swiftc` 로 단독 컴파일 후 실행 | 24 단언 통과 |
| `Tests/WapleRenderTests/SceneScriptAPISurfaceTests.swift` | **못 돌렸다** — macOS 전용 타깃. `swiftc -parse` 구문 검사만 통과 | **미검증** |

돌연변이 대조(§3.4 규약) 6건, 6건 다 잡혔다: 심 `pointsize` 32→16 · `getLayerByID` 를 `===` 로
되돌림 · `transformAttachmentToTexture` 제거(→ 스니펫이 `TypeError` 로 죽는 것을 재현) ·
`layersJSONArray` 의 `full` 게이트 제거 · `padding` 성분 순서 뒤집기 · 디스크립터 `padding`
기본값 (32,32)→(0,0).

훅 테이블 재현:

```python
import struct
# H_pe.PEX: 임의 PE 로더(imagebase/섹션/pdata)
p = PEX('<WE설치본>/bin/scenescript64.dll')          # imagebase 0x180000000
o = p.va2off(0x1819a3ee0)
for i in range(19):                                   # 개수 근거: cmp r14, 0x13 @ 0x18164c65e
    va = struct.unpack_from('<Q', p.d, o + 8 * i)[0]
    print(i, hex(va), p.d[p.va2off(va):][:32].split(b'\x00')[0].decode())
```

텍스트 디스크립터 태그/오프셋(§1.1 의 `padding` 근거)은 등록부 `0x140258ca0`–`0x14025a713` 을
`0x14000f880`(std::string 대입) 호출 사이트 기준으로 훑어 `[rbx+0x30]`(타입)·`[rbx+0x34]`(멤버
오프셋)을 읽으면 나온다. **한 칸 밀림 검증은 필수다** — 생성자 스토어 3건(`pointsize`↔`+0x4e0`
32.0 · `outlinethickness`↔`+0x520` 4.0 · `anchor`↔`+0x550` 0)과 대조해 정렬을 확인했다.
(`anchor` 스토어는 즉값이 아니라 `al` 이다 — `0x140256be6` 의 `xor eax,eax` 로 0 임을 따로 짚었다.
남의 주석에 적힌 "`mov byte [rdi+0x550], 0`" 은 그 축약이다.)
