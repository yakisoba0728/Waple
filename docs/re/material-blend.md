# 머티리얼 / 블렌드 서브시스템 — 동봉 자산 전수 대조

**측정일 2026-08-21 · WE 2.8.42 · wallpaper64.exe SHA256 `40e2ce02…cd993b0` (imagebase 0x140000000)**

동봉 자산(`Sources/WapleRender/Resources/WEAssets/`)의 머티리얼 JSON **전건**과
`wallpaper64.exe` 의 블렌드 경로를 대조한 결과다. 워크샵 코퍼스는 이 컨테이너에 없으므로
**코퍼스 수치는 기존 정본을 인용만 하고 새로 측정하지 않았다** — 새로 측정한 것은 전부
동봉 자산과 바이너리다.

재현:

```bash
# 키 경로 히스토그램 · 씬 인라인 머티리얼 · blending 도수
python3 -c "import sys;sys.path.insert(0,'scripts/spec');import measure_material_schema as M,json;\
print(json.dumps({'h':M.key_path_histogram(),'s':M.scene_inline_materials(),'b':M.blending_census()},ensure_ascii=False,indent=1))"

# 블렌드 디스크립터 기록 자리 · 문자열↔D3D11 완전표
WE_ROOT=/path/to/wallpaper_engine python3 -c "import sys;sys.path.insert(0,'scripts/spec');import measure_render_state as M,json;\
pe=M.PE(M.BIN);s,d=M.blend_desc_sites(pe);print(json.dumps({'sites':s,'dropped':d,'table':M.blend_string_table(s),'flags':M.blend_flag_table(s)},ensure_ascii=False,indent=1))"
```

정본 반영분:

| 정본 | 항목 |
| --- | --- |
| `spec/assets/material-schema.json` | `material.keyPathHistogram` · `material.sceneInlineMaterials` · `material.blendingCensus` |
| `spec/engine/render-state.json` | `renderState.blend.descriptorWriteSites` · `renderState.blend.stringToState` · `renderState.blend.cacheKeyDerivation` · `renderState.blend.notParsedAt1401c2a40` |

---

## 0. 세 줄 요약

1. 동봉 머티리얼 JSON은 **639건 / 고유 키 경로 50개**이고, 그중 정본이 한 번도 세지 않던 키는
   `passes[].usertextures[].keepaspect` **1건**뿐이다.
2. 문자열 ↔ D3D11 블렌드 상태 표는 **명령 주소까지 복원**했다(4모드 + 플래그 비트 6개).
   과제가 지목한 **0x1401c2a40 은 블렌드 파서가 아니다** — 파티클 `blendin*/blendout*` 창 파서다.
3. Waple 은 `blending` 을 **`additive` 냐 아니냐** 로만 읽는다. `normal`(= 블렌딩 OFF)과
   `alphatocoverage` 가 `translucent` 로 접힌다.

---

## 1. 동봉 머티리얼 키 경로 히스토그램

모집단은 경로에 `materials` 디렉터리 세그먼트가 있는 `*.json` 전수(= `**/materials/**/*.json`).
**639건**, 전건 엄격 JSON(관대 파서 불필요), 전건 `passes[0].shader` 보유.

| 트리 | 파일 |
| --- | --- |
| `effects/` | 236 |
| `materials/` | 95 |
| `presets/` | 249 |
| `scenes/` | 59 |
| **합** | **639** |

> `spec/assets/material-schema.json` 의 번들 머티리얼 **331**(= effects/ 236 + materials/ 95)과
> 분모가 다르다. 그 문서는 `presets/` 와 `scenes/` 를 의도적으로 제외한다.
> **639** 는 `spec/engine/render-state.json` 의 `assets` 분모와 같은 집합이다.

키 경로 → 도달 파일 수(내림차순, 전 50건):

| 키 경로 | 전체 | effects | materials | presets | scenes |
| --- | ---: | ---: | ---: | ---: | ---: |
| `passes` | 639 | 236 | 95 | 249 | 59 |
| `passes[].shader` | 639 | 236 | 95 | 249 | 59 |
| `passes[].depthwrite` | 623 | 236 | 79 | 249 | 59 |
| `passes[].depthtest` | 621 | 236 | 78 | 248 | 59 |
| `passes[].cullmode` | 608 | 232 | 69 | 248 | 59 |
| `passes[].blending` | 602 | 236 | 60 | 249 | 57 |
| `passes[].textures` | 401 | 54 | 47 | 245 | 55 |
| `passes[].combos` | 151 | 20 | 28 | 101 | 2 |
| `passes[].constantshadervalues` | 107 | 6 | 1 | 99 | 1 |
| `passes[].alphawriting` | 60 | 5 | · | 43 | 12 |
| `passes[].combos.REFRACT` | 43 | · | · | 43 | · |
| `passes[].constantshadervalues.ui_editor_properties_overbright` | 33 | 1 | · | 32 | · |
| `passes[].constantshadervalues.ui_editor_properties_refract_amount` | 29 | · | · | 29 | · |
| `passes[].combos.VERTICAL` | 16 | 14 | 2 | · | · |
| `passes[].combos.CUTOUT` | 11 | · | · | 11 | · |
| `passes[].constantshadervalues.ui_editor_properties_cutout_end` | 9 | · | · | 9 | · |
| `passes[].constantshadervalues.ui_editor_properties_cutout_opacity` | 9 | · | · | 9 | · |
| `passes[].constantshadervalues.ui_editor_properties_cutout_start` | 9 | · | · | 9 | · |
| `passes[].combos.version` | 6 | · | 6 | · | · |
| `passes[].combos.COLORFONT` | 4 | · | 4 | · | · |
| `passes[].combos.MSDF` | 4 | · | 4 | · | · |
| `passes[].constantshadervalues.dissipation` | 4 | 4 | · | · | · |
| `passes[].combos.DYE` | 2 | 2 | · | · | · |
| `passes[].combos.LIGHTING` | 2 | · | 1 | · | 1 |
| `passes[].combos.UPSAMPLE` | 2 | · | 2 | · | · |
| `passes[].combos.VERSION` | 2 | 1 | 1 | · | · |
| `passes[].combos.vertexcolor` | 2 | · | 2 | · | · |
| `passes[].constantshadervalues.roughness` | 2 | · | 1 | · | 1 |
| `passes[].combos.{BICUBIC,BLOOM,BLUR,CLEARALPHA,COMBINEDBG,DISPLAYHDR,FULLSCREEN,LINEAR,PINCH,REFLECTION,SPIN}` | 각 1 | · | 각 1 | · | · |
| `passes[].combos.{ENABLEMASK,FOG}` | 각 1 | 각 1 | · | · | · |
| `passes[].combos.spritesheet` | 1 | · | · | · | 1 |
| `passes[].constantshadervalues.metallic` | 1 | · | · | · | 1 |
| `passes[].constantshadervalues.reflectivity` | 1 | · | 1 | · | · |
| `passes[].culling` | 1 | · | 1 | · | · |
| `passes[].usershadervalues` / `.schemecolor` | 각 1 | · | 각 1 | · | · |
| `passes[].usertextures` / `[].name` / `[].keepaspect` | 각 1 | · | · | · | 각 1 |

**씬 안의 인라인 머티리얼은 0건이다.** 동봉 씬 172개 / 오브젝트 203개 전부 `objects[].material`
키가 부재하고, `passes[0].shader` 를 가진 인라인 딕트도 씬 트리 전체에 없다. 머티리얼은
`image`/`model`/`particle` 을 거쳐 **경로로만** 참조된다 — 즉 이 서브시스템의 모집단은
파일 집합으로 닫힌다. (`objects[].effects[].passes[]` 오버라이드 층은 머티리얼이 아니라
`spec/corpus/scene-schema.json` 소관이다.)

경계 밖 1건: `shaders/declarations.json` 이 에디터 임포트 템플릿으로 `blending:"translucent"`
를 7번 싣는다. 머티리얼 파일이 아니라 **에디터가 새 머티리얼을 만들 때 쓰는 기본값 표**다.

---

## 2. canon 에 없는 키 (도달 수 순)

`spec/assets/material-schema.json` 원문에 **키 이름이 문자열로 한 번도 등장하지 않는** 키:

| 키 경로 | 도달 | 실물 |
| --- | ---: | --- |
| `passes[].usertextures[].keepaspect` | **1** | `scenes/videoplayer/materials/background.json` — `usertextures:[{"name":"videotex","keepaspect":true}]` |

**그게 전부다.** 나머지 49개 키 경로는 전부 정본의 어느 항목엔가 이름이 실려 있다.

`keepaspect` 가 빠진 이유는 결함이 아니라 **모집단 경계**다 — 정본의 `material.userTextures`
는 `번들 도수 0` / `항목키 name+type`(코퍼스 50건)을 싣는데, 그 "번들" 이 `effects/`+`materials/`
331건이라 `scenes/` 의 이 1건이 분모 밖이었다. 키 자체는 `spec/assets/misc-schema.json`
(`keepaspect`, 2001행)과 `spec/engine/media.json`(527행)이 이미 다룬다 — **정본 전체로 보면
미기록이 아니고, 머티리얼 스키마 문서 안에서만 비어 있었다.**

이번에 추가한 `material.keyPathHistogram` 이 이 경계를 메운다(`정본이 안 싣던 키` 키에 명시).

**정본의 번들 모집단(331) 밖에서만 도달하는 키** — 도달 수 순:

| 키 경로 | 도달 | presets | scenes |
| --- | ---: | ---: | ---: |
| `passes[].combos.REFRACT` | 43 | 43 | · |
| `passes[].constantshadervalues.ui_editor_properties_refract_amount` | 29 | 29 | · |
| `passes[].combos.CUTOUT` | 11 | 11 | · |
| `passes[].constantshadervalues.ui_editor_properties_cutout_start` | 9 | 9 | · |
| `passes[].constantshadervalues.ui_editor_properties_cutout_opacity` | 9 | 9 | · |
| `passes[].constantshadervalues.ui_editor_properties_cutout_end` | 9 | 9 | · |
| `passes[].combos.spritesheet` | 1 | · | 1 |
| `passes[].constantshadervalues.metallic` | 1 | · | 1 |
| `passes[].usertextures` (+ `[].name`, `[].keepaspect`) | 1 | · | 1 |

이 키들은 전부 **코퍼스 도수로는 정본에 실려 있다**(REFRACT 186, CUTOUT 10, spritesheet 60 …).
번들 도수만 0으로 보였던 것이다.

**덤으로 잡힌 정본 부패 1건** — `waple.keyLiteralCoverage` 가 `compose:false`,
`functions:false` 를 싣고 있었는데 지금 소스에는 둘 다 있다
(`Sources/WapleCore/EffectManifest.swift:376`, `:420`). 확정 등급인데 사실이 아니었다.
재측정해 `compose/conditions/functions → true`, `미등장 → [culling, editable, performance]` 로
고쳤고, 짝인 `waple.gap.composeAndConditions.미소비 렌더 키` 도 `[]` 로 맞췄다(둘 다 파스는
하지만 렌더러가 읽는 자리는 아직 없다는 사실을 note 에 적었다).

---

## 2.5 `passes[].usertextures[].keepaspect` — 소비처를 떴다 (2026-08-21)

§2 가 "정본에 없던 키 1건" 으로 지목한 그 키다. 파스만 있고 규약이 비어 있었으므로
`wallpaper64.exe` 에서 **파서와 소비처를 직접 다시 떴다**(선행 인용을 베끼지 않았다).

### 2.5.1 파서 — 인용된 범위가 맞다

`primary(0x140154871)` = **`0x140154480`–`0x140155668`**(단일 `.pdata` 조각). 머티리얼 패스
파서이고 `combos` → `constantshadervalues` → `usershadervalues` → `usertextures` 순으로 읽는다.

`usertextures[]`(`0x140154685`) 루프는 원소가 태그 4(문자열) 또는 7(객체)일 때만 처리하고,
진입마다 `xor r12b, r12b`(`0x140154717`)로 플래그를 0 으로 깐다 — **부재 시 false**.
객체 갈래에서만 `name`(`0x140154786`) · `type`(`0x1401547fc`, `stricmp "system"`→1 /
`"usershortcut"`→2) · `keepaspect`(find `0x140154871` → 태그 5 확인 `0x140154887` →
`asBool` `0x140154890` → `cmovne r12d, 1` `0x1401548a0`)를 읽는다. 문자열 갈래는
`0x14015477a` 로 이 블록을 통째로 건너뛴다(= 항상 false).

레코드는 **0x38바이트**(`mov ecx, 0x38` `0x1401549d9`)이고 `+0x30` 에 플래그가 들어간다
(`mov byte [rax+0x30], r12b` `0x140154a09`). 그 레코드가 `pass+0x270` 의
`unordered_map<int slot, UserTexture*>` 에 **슬롯 인덱스**로 꽂힌다
(`sub_14004b8a0` = 4바이트 키 FNV-1a find, 노드 `+0x10`=키 `+0x18`=값 / 삽입 `0x140154b3c`).
레코드 `+0x10` 은 유저 프로퍼티 `<name>.value` 문자열이다
(`[engine+0x1718]` 에서 이름으로 찾고 `"value"` 를 다시 찾는다 — `0x140154a30`–`0x140154a96`).

### 2.5.2 소비처 — `sub_1401556e0`

**`primary()` 만으로는 안 잡힌다**(`0x1401556e0`–`0x140155745` 짜리 조각이 나온다).
`merged()` 로 **6조각 = `0x1401556e0`–`0x140155fbb`** 가 한 몸이다. 패스의 `textures[]`
(최대 10슬롯, `0x140155752`)를 돌면서 그 슬롯에 유저 텍스처가 있으면 이름을 갈아끼우는
루틴이고, `keepaspect` 를 **두 자리에서** 읽는다.

먼저 "레퍼런스 크기" 를 정한다 — 패스 JSON 의 `usertexturereference.width/height`
(`0x140155909` — 그 객체 안의 `width` `0x140155974` / `height` `0x14015599a`), 없으면 슬롯의 기본 텍스처(`textures[i]`)
파일을 프로브해서(`sub_14014d500` `0x140155a23`) 얻는다. 그 값을 `pass+0x2b0`/`+0x2b2`
(u16 두 개)에 넣고(`0x140155a6d` / `0x140155a75`) 종횡비 `xmm6 = refW / refH`
(`divss` `0x140155aaf`)를 만든다.

| # | VA | 조건 | 하는 일 |
| --- | --- | --- | --- |
| ① | `0x140155d23` `cmp byte [rcx+0x30], 0` | 참 | 텍스처 로드 디스크립터의 float `[rsp+0x54]` 를 **0.0f** 로 덮는다(`0x140155d29`). 거짓이면 `xmm6`(= 레퍼런스 종횡비)이 그대로 실린다(`0x140155c10`) |
| ② | `0x140155daf` `cmp byte [rax+0x30], 0` | 참 | `pass+0x2b0/+0x2b2` 를 **실제로 로드된 텍스처의 `[tex+0x2c]`/`[tex+0x30]`**(= imageW/imageH)으로 덮는다(`0x140155db5`–`0x140155dcb`) |

그리고 유저 텍스처가 실제로 붙으면 `pass+0x1f8` 비트 2 를 세운다(`or` `0x140155e41`,
진입 시 `and …,0xfffffffb` `0x1401556fd` 로 리셋).

### 2.5.3 그 크기가 셰이더로 가는 길

`sub_140209360` 이 텍스처 바인드마다 도는 "해상도 상수" 루틴이다:

```
0x140209423  mov  rcx, [rcx+0x498]          ; 현재 머티리얼 패스
0x14020942a  test byte [rcx+0x1f8], 4       ; 유저 텍스처 있음?
0x140209433  movzx eax, word [rcx+0x2b0]    ; 있으면 그 u16 쌍을
0x140209449  movzx eax, word [rcx+0x2b2]    ;   [ctx+0x2f0]/[ctx+0x2f4] 로
0x140209459  (없으면) [ctx+0x2f0] = [tex+0x2c], [ctx+0x2f4] = [tex+0x30]
...
0x1402094f8  call [vtable+0xb0](this, imgW/paddedW, imgH/paddedH,
                                 [tex+0x20], [tex+0x24], (int)ctx+0x2f0, (int)ctx+0x2f4)
```

인자 배열이 Waple 의 `g_TextureNResolution = (paddedW, paddedH, imageW, imageH)` 규약과
정확히 겹친다(`[tex+0x20]/[tex+0x24]` = padded, `[tex+0x2c]/[tex+0x30]` = image,
xmm1/xmm2 = `image/padded` UV 스케일 — `divss` `0x1402094b4` / `0x1402094c0`).

**즉 `keepaspect` 는 UV 도 쿼드 크기도 직접 건드리지 않는다.** 하는 일은 딱 둘이다.

1. 텍스처 로더에 넘기는 **목표 종횡비를 0(= 강제하지 않음)** 으로 만든다.
2. 셰이더가 보는 `g_TextureNResolution.zw` 를 레퍼런스 크기가 아니라 **실제 이미지 크기**로
   바꾼다.

즉 기본값(false)이 "유저가 꽂은 그림을 슬롯의 레퍼런스 종횡비에 **맞춰 넣는다**" 이고
`true` 가 "원본 비율 그대로 두고 원본 크기를 그대로 보고한다" 다.

### 2.5.4 `fit` 과는 다른 계산이다

`fbos[].fit`(`EffectManifest.FBO.fittedBox`, 원본 `0x1401eb2cc`–`0x1401eb381`)은
`W' = min(fit, 긴 변)` + `짧은 변 = trunc(비율 × W')` 로 **치수를 만든다**.
`keepaspect` 에는 그런 산술이 **하나도 없다** — `min` 도 클램프도 절단도 없고, 어느 쪽
크기를 고르느냐의 선택만 있다. **재사용할 계산이 없다.**

### 2.5.5 [미해결] · Waple 도달

* **[미해결] 크롭이냐 레터박스냐** — 디스크립터 `+0x54`(종횡비)를 읽는 로더 본체는
  `*(engine+0x1518)` 의 가상함수 `+0x50`(`0x140155d81` 간접 호출)이고, 그 구체 구현을
  정적으로 잡지 못했다. 다만 로드 전 캐시 조회 키가
  `[usershortcut_]<value>x<trunc(종횡비×10)>`(`0x140155ab6` `mulss xmm7 = 10.0` →
  `0x140155ac3` `cvttss2si`)라 **종횡비별로 다른 텍스처를 만든다**는 것까지는 확정이다.
* **[미해결] 캐시 히트 비대칭** — 위 캐시 조회(`sub_14014cf90` `0x140155be3`)가 성공하면
  `0x140155e3a` 로 점프해 소비처 ②(`0x140155daf`)를 **건너뛴다.** 즉 캐시가 이미 그 키를
  들고 있으면 `keepaspect` 가 참이어도 `pass+0x2b0` 이 레퍼런스 크기로 남는다. 원본의
  결함으로 보이지만 실행 관측을 못 했으므로 확정으로 쓰지 않는다.
* **Waple 도달 = 그림 변화 0건.** 근거 셋:
  1. `SceneLayer.materialUserTextureNames` / `materialUserTextureKeepAspect` 는
     **렌더러 소비처가 0** 이다(`Sources/**/*.swift` 전수 — 파스·보존 전용).
     렌더러가 읽는 유저 텍스처는 **이펙트 패스** 쪽
     (`SceneEffectPass.userTextureNames`, `SceneRendererResources.swift:1285`)이고
     `keepaspect` 는 **머티리얼 패스 전용**이다(문자열 `keepaspect` xref 1건 = `0x140154871`).
  2. 유일한 도달 자산 `scenes/videoplayer/materials/background.json` 을 Waple 은 **마운트하지
     않는다**. `videoplayer` 라는 문자열이 Waple 소스에 코드로 0건이고(주석·테스트만),
     비디오는 `SceneVideoLayer` 가 `video` 레이어에 직접 프레임을 공급한다(`55a025d`).
  3. WE 에서도 이 경로는 엔진이 런타임에 `wproperties.videotex.value` 를 써 넣어야 켜진다
     (`0x140120050`, 리터럴 `"videotex"` `0x140489d38`). 값이 비면
     `cmp qword [rdx+0x20], 0` / `je`(`0x1401558b1`)로 슬롯 전체를 건너뛴다.
  4. `usertexturereference` 는 동봉+설치본 JSON 3655건에 **0건**이다 — 레퍼런스 크기는
     실측 코퍼스에서 항상 "슬롯 기본 텍스처 프로브" 갈래로만 온다.

그래서 **구현하지 않았다.** 지금 붙이면 도달 0인 코드가 되고, 켜지는 조건(머티리얼 유저
텍스처 배선 + 비디오 씬 마운트)이 둘 다 없는 상태에서는 옳은지 그른지 검증할 방법도 없다.
배선이 생기는 시점에 위 표 ①②를 그대로 옮기면 된다.

---

## 3. 동봉 자산의 `blending` 값 전수

| 값 | 전체 | effects | materials | presets | scenes |
| --- | ---: | ---: | ---: | ---: | ---: |
| `normal` | **205** | 188 | 8 | 4 | 5 |
| `translucent` | **200** | 47 | 46 | 95 | 12 |
| `additive` | **197** | 1 | 6 | 150 | 40 |
| `alphatocoverage` | **0** | · | · | · | · |
| (키 없음 → 열거값 0 = normal) | 37 | · | 35 | · | 2 |

- **`alphatocoverage` 는 동봉 자산에 한 건도 없다.** 워크샵 코퍼스에만 40건(정본
  `renderState.authoring.valueDistribution`). 동봉만으로는 이 모드의 회귀를 볼 수 없다.
- `effect.json` **128개 / 패스 220개는 `blending` 키를 하나도 갖지 않는다.** 이펙트 패스의
  블렌드 상태는 그 패스가 참조하는 material 이 정한다.
- 소비처별로 갈라 보면 그림이 달라진다:

| 모집단 | normal | translucent | additive | 키 없음 |
| --- | ---: | ---: | ---: | ---: |
| `materials/effects/**` (이펙트 체인 패스 머티리얼) | 196 | 1 | 0 | 0 |
| 그 외(레이어 · 파티클 · 모델 머티리얼) | 9 | 199 | 197 | 37 |

이펙트 체인 머티리얼은 사실상 전건 `normal` 이고, 레이어/파티클은 사실상 전건
`translucent`/`additive` 다. 이 분리가 아래 Waple 대조의 핵심이다.

---

## 4. 문자열 ↔ D3D11 블렌드 상태 — 완전 표

### 4.1 문자열 → 열거값 (`FUN_1401577e0`, 등록자)

레코드는 `0x1404e9390` 부터 `0x28` 바이트 간격 4개(std::string 0x20 + 값 1바이트).
끝 포인터 `0x1404e9430` 이 `0x1404e9340` 에, 시작이 `0x1404e9338` 에 실린다.
이 배열은 `.data` 의 **런타임 초기화** 영역이라 파일 바이트로는 0이다 — 값은 기록 명령에서만 읽힌다.

| 문자열 | 문자열 VA | `lea` | 값 기록 명령 | 열거값 |
| --- | --- | --- | --- | ---: |
| `normal` | `0x140476fd0` | `0x140157d82` | `0x140157d9e` `mov byte [0x1404e93b0], sil` (sil=0 — `0x140157803` `xor esi,esi`) | **0** |
| `translucent` | `0x14048b500` | `0x140157db2` | `0x140157dd6` `mov byte [0x1404e93d8], 1` | **1** |
| `additive` | `0x14048b520` | `0x140157dea` | `0x140157e0e` `mov byte [0x1404e9400], 2` | **2** |
| `alphatocoverage` | `0x14048b510` | `0x140157e22` | `0x140157e4a` `mov byte [0x1404e9428], 3` | **3** |

프로퍼티 키 `"blending"` 은 `0x14048b638`, 등록은 `0x140157897`(`lea rdx`), 프로퍼티 id 는
`0x1401578b4` `mov dword [rbx+0x34], 0x1f0` = **496**.

역매핑(직렬화)은 `FUN_1401531c0` (`0x1401531c0–0x1401531f2`):
`0x1401531d2` → `normal`(기본), `0x1401531ea` → `translucent`,
`0x1401531e2` → `additive`, `0x1401531da` → `alphatocoverage`.
쓰는 곳은 `0x14020a1f4` `xor ecx,ecx` + `0x14020a1f6 call` → `0x14020a20e` 의 `"blending"` 키.

**기본값**: `blending` 키가 없으면 열거값 **0 = normal**. 블렌드 상태 객체 생성자가
오브젝트+0x26 을 0으로 두기 때문이다 — `0x140098ed3` `mov byte [rcx+0x26], sil`
(sil=0 @`0x140098eaf`).

### 4.2 열거값 → `D3D11_BLEND_DESC` (`FUN_140099f60`, `0x140099f60–0x14009a358`)

스택 디스크립터 베이스는 **RSP+0x20**. `0x14009a0b4` `mov r8d, 0x108`(=264=`sizeof(D3D11_BLEND_DESC)`)
+ `0x14009a0be call` 이 그 자리를 0으로 민다. 공통 기본 WriteMask 는
`0x14009a0c5` `mov byte [rsp+0x44], 7`.

스위치 선택자는 `0x14009a0c3` `mov ecx, esi` · `0x14009a0ca` `and ecx, 7`.

| blending | 열거값 | 분기 | AlphaToCoverage | BlendEnable | SrcBlend | DestBlend | BlendOp | SrcBlendAlpha | DestBlendAlpha | BlendOpAlpha | WriteMask |
| --- | ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- | ---: |
| `normal` | 0 | `0x14009a0cd` | FALSE | FALSE | `ONE`(2) | `ZERO`(1) | `ADD`(1) | `ONE`(2) | `ZERO`(1) | `ADD`(1) | 7 |
| `translucent` | 1 | `0x14009a0d2` | FALSE | **TRUE** | `SRC_ALPHA`(5) | `INV_SRC_ALPHA`(6) | `ADD`(1) | `SRC_ALPHA`(5) | `INV_SRC_ALPHA`(6) | `ADD`(1) | 7 |
| `additive` | 2 | `0x14009a0db` | FALSE | **TRUE** | `SRC_ALPHA`(5) | `ONE`(2) | `ADD`(1) | `SRC_ALPHA`(5) | `ONE`(2) | `ADD`(1) | 7 |
| `alphatocoverage` | 3 | `0x14009a0e4` | **TRUE** | FALSE | `ONE`(2) | `ZERO`(1) | `ADD`(1) | `ONE`(2) | `ZERO`(1) | `ADD`(1) | 7 |

각 필드를 쓰는 **명령 주소**:

| 필드 | normal | translucent | additive | alphatocoverage |
| --- | --- | --- | --- | --- |
| `AlphaToCoverageEnable` | memset | memset | memset | **`0x14009a0f2`** |
| `IndependentBlendEnable` | memset | memset | memset | memset |
| `RT0.BlendEnable` | memset | `0x14009a32b` | `0x14009a2fe` | memset |
| `RT0.SrcBlend` | `0x14009a112` | `0x14009a333` | `0x14009a306` | `0x14009a112` |
| `RT0.DestBlend` | `0x14009a10a` | `0x14009a33b` | `0x14009a30e` | `0x14009a10a` |
| `RT0.BlendOp` | `0x14009a122` | `0x14009a122` | `0x14009a122` | `0x14009a122` |
| `RT0.SrcBlendAlpha` | `0x14009a102` | `0x14009a343` | `0x14009a316` | `0x14009a102` |
| `RT0.DestBlendAlpha` | `0x14009a0fa` | `0x14009a34b` | `0x14009a31e` | `0x14009a0fa` |
| `RT0.BlendOpAlpha` | `0x14009a11a` | `0x14009a11a` | `0x14009a11a` | `0x14009a11a` |
| `RT0.RenderTargetWriteMask` | `0x14009a0c5` | `0x14009a0c5` | `0x14009a0c5` | `0x14009a0c5` |

`alphatocoverage` 는 `0x14009a0f2` 에서 AlphaToCoverage 만 켜고 `0x14009a0fa`(normal 블록)로
흘러든다 — 그래서 나머지가 normal 과 완전히 같다. `translucent`/`additive` 는
`0x14009a353` / `0x14009a326` 의 `jmp 0x14009a11a` 로 ADD/ADD 합류점에 들어온다.

생성·바인딩:

- `CreateBlendState` — `0x14009a1e1` `call [rax+0xa0]` (desc = RSP+0x20, out = RBP+0x60)
- 캐시 저장 — `0x14009a1f2` `mov [rax+rsi*8], rdx` (배열 `[rdi+0x140]`, 색인 = 캐시키)
- 바인딩 — `0x14009a232` `call [rax+0x118]`, BlendFactor=NULL(`0x14009a228` `xor r8d,r8d`),
  SampleMask=`0xffffffff`(`0x14009a21b`)

### 4.3 캐시 키와 플래그 비트 — 문자열만 보면 놓치는 층

```
캐시키 = word[obj+0x28] | (word[obj+0x28] 의 bit9 ? byte[obj+0x26] : 4)
```

| 단계 | 명령 |
| --- | --- |
| 상태워드 적재 | `0x140099ff8` `movzx eax, word [rdi+0x28]` |
| bit9 검사 | `0x140099ffc` `bt ax, 9` |
| bit9=1 → 머티리얼 열거값 | `0x14009a003` `movzx ecx, byte [rdi+0x26]` |
| bit9=0 → 4 | `0x14009a009` `mov ecx, 4` |
| 합성 | `0x14009a015` `or eax, ecx` · `0x14009a024` `mov esi, eax` |

스위치 뒤에 **모든 모드 공통으로** 덧씌워지는 플래그(값은 전부 바이트 실측):

| 비트 | 테스트 | 덮어쓰는 것 | 기록 명령 |
| --- | --- | --- | --- |
| `0x80` | `0x14009a12a` | SrcBlend=`ONE`, DestBlend=`INV_SRC_ALPHA`, Src/DestBlendAlpha=`ONE` (프리멀티 오버 + 알파 누적) | `0x14009a12f` `0x14009a137` `0x14009a13f` `0x14009a147` |
| `0x18` | `0x14009a14f` | WriteMask=0xF(RGBA) | `0x14009a155` |
| `0x10` | `0x14009a15a` | BlendOpAlpha=`MAX`, Src/DestBlendAlpha=`ONE` | `0x14009a160` `0x14009a168` `0x14009a170` |
| `0x20` | `0x14009a178` | BlendOp=`MAX`, Src/DestBlendAlpha=`ONE` | `0x14009a17e` `0x14009a186` `0x14009a18e` |
| `0x40` | `0x14009a196` | BlendOp=`MIN`, Src/DestBlendAlpha=`ONE` | `0x14009a19c` `0x14009a1a4` `0x14009a1ac` |
| `0x100` | `0x14009a1b4` | SrcBlend=`DEST_COLOR`, Src/DestBlendAlpha=`ONE` | `0x14009a1ba` `0x14009a1c2` `0x14009a1ca` |

**키 4의 정체(종전 정본의 미결 항목)** — `renderState.blend.flagBits.keyValue4` 는 "도달 불가이거나
플래그가 항상 같이 켜지거나, 어느 쪽인지 모른다" 로 남아 있었다. 명령을 읽으면 절반은 닫힌다:
키 4는 **bit9 가 꺼져 있을 때의 정적 기본값**이다(`0x14009a009` 가 조건 없이 4를 싣는다).
그 분기는 `0x14009a0eb` 에서 WriteMask 를 8(ALPHA only)로만 쓰고
`0x14009a0f0` `jmp 0x14009a12a` 로 스위치 본문을 통째로 건너뛴다 → Src/Dest/Op 는 memset 0.
그 상태로 `CreateBlendState` 를 부르면 D3D11 이 거절하므로 **반드시 위 플래그 비트와 함께
쓰인다**(예: `4|0x10|0x20|0x80` 이면 전 필드가 유효값으로 채워진다). 즉 (a) 도달 불가는
탈락하고 (b) 만 남는다. 어느 패스가 그 조합을 켜는지는 여전히 이 문서의 범위 밖이다.

키 5·6·7 은 `0x14009a0e9` `jne 0x14009a12a` 로 빠져 디스크립터 필드를 하나도 쓰지 않는다.
상태워드 하위 3비트가 열거값 자리로 예약돼 0이라면 위 식으로 만들어지지 않는 값이다.

### 4.4 blending 은 뎁스스텐실도 고른다

`0x140099f84–0x140099f9f`:

```
0x140099f84  movzx eax, byte [rcx+0x26]   ; blending 열거값
0x140099f88  test al, al
0x140099f8a  je   0x140099f95             ; 0 → rcx = 0
0x140099f8c  mov  ecx, 1
0x140099f91  cmp  al, 3
0x140099f93  jne  0x140099f98             ; 1·2 → rcx = 1
0x140099f95  mov  rcx, r12                ; 3 → rcx = 0
0x140099f98  movzx eax, byte [rdi+0x24]   ; depthtest 비트
0x140099f9c  or   rax, rcx
0x140099f9f  mov  rdx, [rdi+rax*8+0xc0]   ; 뎁스스텐실 상태 표
```

즉 **`translucent`/`additive` 는 저작된 `depthwrite` 와 무관하게 뎁스 쓰기가 꺼진다**
(슬롯 1 = DepthWriteMask ZERO). `normal`/`alphatocoverage` 는 OR 하지 않는다.
정본 `renderState.depthStencil.table` 의 `select` 규칙이 이 명령이고, Waple 은
`Sources/WapleRender/SceneRenderer3D.swift:797` 에서 **이미 같은 규칙을 구현한다**.

---

## 5. 0x1401c2a40 은 블렌드 파서가 아니다 — 오식별 정정

과제 전제는 "블렌드 파서 primary 는 0x1401c2a40 근방" 이었다. **아니다.**

`0x1401c2a40–0x1401c2e4e`(`.pdata` 조각 5개 병합)가 찾는 키는
`blendinstart` / `blendinend` / `blendoutstart` / `blendoutend`
(문자열 VA `0x14048f850` · `0x14048f860` · `0x14048f870` · `0x14048f880`)이고,
`0x1401c2d80` 이후 `rcpps` 로 구간 역수 두 개를 만들어 float4 로 splat 한다.
= **파티클 오퍼레이터의 수명-가중 창(blend window) 파서**다.

유일한 호출부는 `0x1401c5490`(파티클 시스템 JSON 파서 — `emitter`/`initializer`/`operator`/
`renderer`/`turbulence`/`boids` … 182개 키를 참조한다)에서 **11곳**:
`0x1401cb884` `0x1401cc43c` `0x1401cc7da` `0x1401cc9be` `0x1401ccf66` `0x1401cd194`
`0x1401cd407` `0x1401ce3d6` `0x1401ce64b` `0x1401cf11c` `0x1401cf1dc`.

이 저장소는 이미 그렇게 알고 있다 — `Sources/WapleCore/ParticleSystem.swift:509` 의
`BlendWindow` 주석이 같은 VA(`0x1401c2c26`, `0x1401c2cd3`, `0x1401c2d9f–0x1401c2da8`)를 인용한다.
동봉 자산에서도 이 키들은 `presets/fireworks/**`, `presets/lightning/**`,
`scenes/particleelementpreviews/capvelocity/**` 의 **파티클** JSON 에만 나온다.

머티리얼 `blending` 과는 **문자열 접두어가 겹칠 뿐 아무 관계가 없다.** 정본
`renderState.blend.notParsedAt1401c2a40` 에 이 사실을 못 박아 다음 사람이 같은 곳으로
끌려가지 않게 했다.

> **방법론 함정 2("한 요소가 기본 opcode + 확장 두 개의 핸들러를 가질 수 있다")도 이 자리엔
> 해당하지 않는다.** 머티리얼 프로퍼티 등록자(`0x1401578b4`~`0x1401578dc`)는 확실히 프로퍼티당
> 핸들러 포인터를 4개(`+0x38`/`+0x40`/`+0x48`/`+0x50`) 달지만, `blending` 의 문자열↔열거값 매핑은
> 그 핸들러가 아니라 위 4.1 의 레코드 배열 하나로 끝난다. 확장 핸들러를 더 찾을 필요가 없다.

---

## 6. Waple 대조 — 어긋난 항목

Waple 이 `blending` 을 읽는 자리는 전부 **`== "additive"` 단일 비교**다:

| 자리 | 코드 |
| --- | --- |
| 2D 레이어 | `Sources/WapleRender/SceneRendererResources.swift:552` `blendAdditive: layer.blendMode == "additive"` [줄번호 재측정 2026-08-28, 종전 `:488`] |
| 2D 커스텀 셰이더 레이어 | `SceneRendererResources.swift:1617` `let additive = layer.blendMode == "additive"` |
| 3D 메시 | `Sources/WapleRender/SceneRenderer3D.swift:806` `additive = blend == "additive"` [줄번호 재측정 2026-08-28, 종전 `:781-782`] |
| 파티클 | `Sources/WapleCore/ParticleSystem.swift:768` `(p0["blending"] as? String) == "additive" ? .additive : .translucent` |

| # | 항목 | WE(실측) | Waple | 동봉 도달 | 등급 |
| --- | --- | --- | --- | ---: | --- |
| **B1** | `blending:"normal"` | BlendEnable **FALSE** — dst.rgb ← src.rgb 덮어쓰기 | 블렌딩 ON(프리멀티 over). `normal` 과 `translucent` 가 **같은 파이프라인**으로 접힌다 | 레이어/파티클/모델 머티리얼 **46건**(명시 9 + 키 부재 37). 그중 실사용 레이어는 `scenes/gifs`·`scenes/videoplayer` 배경 2건(둘 다 불투명 → 화면 영향 0) | 실재하나 동봉 관측 영향 ≈ 0 |
| **B2** | `blending:"alphatocoverage"` | normal + `AlphaToCoverageEnable=TRUE` | 2D: 미처리(=over). 3D: `alphaCutoff=0.5` discard 근사(`SceneRenderer3D.swift:782`) | 동봉 **0건**, 코퍼스 40건 | 2D 미구현 / 3D 의도적 근사 |
| **B3** | 이펙트 체인 패스의 material `blending` | 패스 머티리얼이 정한다 | `SceneRendererResources.swift:2019 effectPipeline` 은 블렌드 상태를 **아예 설정하지 않는다**(= 항상 blending OFF = WE `normal`) | `materials/effects/**` 197건 중 196건이 `normal` 이라 일치. 어긋나는 것은 `effects/blur/preview/materials/effects/blur_combine.json`(translucent) **1건** | 구조적 갭, 동봉 도달 1 |
| **B4** | 파티클 `blending` 도메인 | 4종 | `BlendKind { additive, translucent }` 2종 — `normal`·`alphatocoverage` 가 `translucent` 로 접힌다 | `materials/particle/**` 은 additive 41 / translucent 13 → 동봉 도달 **0** | 도메인 축소, 현 자산 무영향 |
| **B5** | `RenderTargetWriteMask` | 기본 **7(RGB)** — 머티리얼 드로우는 알파를 안 쓴다 | Metal 기본 `.all`(RGBA), `destinationAlphaBlendFactor` 까지 설정 | 전 머티리얼 드로우 | **수정 후보 아님** — 아래 참조 |
| **B6** | `alphawriting` | 프로퍼티 497. D3D11 필드로 가는 경로는 정본도 미추적(상태워드 bit3/bit4 가 후보) | `SceneDocument.swift:1327` 에서 파스·보존만, 소비 0 | 동봉 60건(effects 5 · presets 43 · scenes 12) | 양쪽 다 미해결 |
| **B7** | `translucent` 의 알파 채널 | Src/DestBlendAlpha = `SRC_ALPHA`/`INV_SRC_ALPHA` + WriteMask 7(=알파 미기록) | `ONE`/`INV_SRC_ALPHA` + 알파 기록 | 200건 | RGB 동치, 알파만 갈림(B5 와 같은 뿌리) |

**B5/B7 이 수정 후보가 아닌 이유.** WE 는 스트레이트(비-프리멀티) 알파를 셰이더에서 내고
블렌드 상태가 `SRC_ALPHA` 를 곱한다(정본 `renderState.alpha.straightNotPremultiplied`).
Waple 은 셰이더에서 미리 곱하고 `ONE` 을 쓴다 — **RGB 결과는 수식이 같다.** 갈라지는 것은
알파 채널뿐인데, Waple 은 레이어를 `acc` 텍스처에 쌓고 나중에 합성하므로 **알파를 써야 한다**.
WriteMask 7 은 WE 의 "중간 acc 가 없다" 는 구조와 한 몸이라 떼어서 옮길 수 없다.
이건 결함이 아니라 **구조 분기**이고, 정본이 이미 그렇게 기록하고 있다.

**B1 의 성격.** `SceneRenderer.swift:1342-1355` 주석이 이미 "WE 4모드 중 어느 것도 프리멀티
소스를 옳게 합성하지 못한다" 는 판단과 A/B 실측(3690417937, premult-over 0.917·1.005 vs
additive 0.912·1.043)을 근거로 프리멀티 오버를 **의도적으로** 고른 상태다.
다만 그 주석이 다루는 것은 `translucent`/`additive` 이고, **`normal` 을 `translucent` 와
같은 파이프라인으로 접는 선택은 어디에도 근거가 적혀 있지 않다.**
알파<1 텍셀을 가진 `normal` 머티리얼이 WE 에서는 배경을 지우고 Waple 에서는 섞인다.

---

## 7. 정확한 diff 후보 (Metal 파이프라인 코드는 이 작업에서 건드리지 않았다)

### D-1 (B1) — `normal` 전용 파이프라인

`Sources/WapleRender/SceneRenderer.swift` — `pipeline`(`v_main`/`f_main`, `att` 기준) 옆에
`blending OFF` 변형을 하나 더 만들고, `SceneRendererFrameEncoder.swift:1504` 의 파이프라인
선택 사슬에 `layer.blendMode == "normal"` 분기를 `blendAdditive` 앞에 넣는다.

```
+ // WE: blending "normal" = BlendEnable FALSE (renderState.blend.stringToState @0x14009a0cd)
+ att.isBlendingEnabled = false
+ self.layerOpaquePipeline = try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pdesc) }
+ att.isBlendingEnabled = true
```

**권고: 지금은 넣지 마라.** 동봉 자산 관측 영향이 0이고(해당 2건이 불투명),
`f_main` 이 프리멀티 출력을 내므로 blending OFF 로 바꾸면 `acc` 알파 규약이 함께 깨진다.
넣으려면 코퍼스 A/B 가 먼저 필요하다 — B1 은 **근거를 남기는 것까지가 이번 몫**이다.

### D-2 (B3) — 이펙트 체인 패스가 material `blending` 을 따르게

`SceneRendererResources.swift:2019 effectPipeline(source:device:)` 에 `blending: String`
인자를 더하고 `translatedLayerPipeline`(:1563-1583)과 같은 3분기를 쓴다.

```
- func effectPipeline(source: String, device: MTLDevice) -> MTLRenderPipelineState? {
+ func effectPipeline(source: String, blending: String, device: MTLDevice) -> MTLRenderPipelineState? {
      ...
      pd.colorAttachments[0].pixelFormat = .rgba8Unorm
+     if blending != "normal" && blending != "alphatocoverage" {
+         let a = pd.colorAttachments[0]!
+         a.isBlendingEnabled = true
+         a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
+         a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
+         a.destinationRGBBlendFactor = blending == "additive" ? .one : .oneMinusSourceAlpha
+         a.destinationAlphaBlendFactor = blending == "additive" ? .one : .oneMinusSourceAlpha
+     }
```

호출부(`:549`)는 `EffectManifest` 가 패스 material 의 `blending` 을 실어 와야 한다 —
지금은 `shader`/`textures`/`combos` 만 읽는다. **동봉 도달 1건(preview 자산)** 이므로
우선순위는 낮지만, 코퍼스 이펙트가 `translucent` 패스를 쓰면 바로 드러나는 갭이다.

### D-3 (B4) — 파티클 blending 도메인

`Sources/WapleCore/ParticleSystem.swift:741` `BlendKind` 에 `normal`/`alphaToCoverage` 를
더할 근거가 **지금은 없다**(동봉 도달 0). `:768` 의 `? .additive : .translucent` 폴백이
`normal` 을 조용히 삼킨다는 사실만 주석으로 남기는 편을 권한다.

### D-4 (B2) — 2D `alphatocoverage`

3D 는 이미 `alphaCutoff=0.5` discard 근사를 한다(`SceneRenderer3D.swift:782`).
2D 는 MSAA 가 없어 alpha-to-coverage 자체가 성립하지 않으므로, 같은 근사를
`f_main` 쪽에 붙이거나 **명시적으로 하지 않기로** 결정하고 기록하는 두 길 중 하나다.
동봉 0건 / 코퍼스 40건이라 **코퍼스 있는 환경에서 판단할 항목**이다.

---

## 7.5 오브젝트 `colorBlendMode` — 전 범위 확정 (2026-08-21, 클러스터 AJ)

§1–§7 은 머티리얼 `blending`(4모드, 하드웨어 블렌드 상태)이다. **`colorBlendMode` 는 다른
필드다** — 오브젝트(`objects[]`)의 정수 키이고, 머티리얼 `combos.BLENDMODE` 로 실려
`common_blending.h` 의 `ApplyBlending` 을 고른다. 이름이 비슷할 뿐 §4 의 문자열 표와 무관하다.

### 7.5.1 도메인은 0…32 이고 33개가 전부다

세 근거가 독립으로 같은 답을 준다.

1. **셰이더** `assets/shaders/common_blending.h` 의 `ApplyBlending` 은 `#if BLENDMODE == n` 을
   n=1…32 로 **정확히 32개** 갖고, 어느 것도 안 맞으면 마지막 줄
   `return mix(A, BlendNormal(A,B), opacity)` 로 떨어진다. 모드는 런타임 인자가 아니라
   **전처리기 콤보**다 — 함수 인자 `blendMode` 는 본문에서 한 번도 읽히지 않는다.
2. **에디터 드롭다운** `bin/wallpaperui.exe`(12,742,640 B) 파일오프셋 `0x00ad2ee0`–`0x00ad33b7`
   에 `isgrouptitle` 두 개(`ui_editor_blending_group_native` / `…_group_emulated`)와
   **`ui_editor_blending_*` 라벨 33개**가 한 블록이다(33 = 0…32). 같은 블록의 값 리터럴은
   `2 3 4 5 6 9 11…32` 이고 빠진 `0 1 7 8 10` 은 12MB 바이너리 어디서든 접히는 짧은 리터럴이다.
   **라벨↔값 짝을 이 풀 순서로 짓지 마라** — 함정 #16 그대로 한 칸씩 밀린다. 이름은
   `common_blending.h` 매크로에서 읽어야 안전하다.
   → **[2026-08-21]** 짝을 명령에서 직접 떴다(§7.6). 매크로 이름과 UI 이름은 **일곱 자리에서
   갈리므로**(4·5·9·10·20·31·32) 매크로 이름만으로는 저작자의 의도를 읽을 수 없다.
3. **파서** `colorBlendMode`(문자열 `0x140490870`, 디스크립터 등록 `0x1401eeec2`, 멤버
   오프셋 `0x32c`)는 리플렉션 int 주입기 `0x1401a4930` 이 태그 1/2 는 `mov`, 태그 3 은
   `cvttsd2si`(`0x1401a4962`)로 **생짜 int32** 를 꽂는다. **범위 검사도 클램프도 없다.**
   태그 4(문자열)는 `jne 0x1401a4970` 으로 저장을 건너뛰어 **생성자 기본값 0 이 남는다**
   (`0x1401e6a14` `mov [rbx+0x32c], eax`, eax=0 — 함정 #15 그대로).

> 부수 정정: §4.1 이 `blending` 의 `[rbx+0x34] = 0x1f0` 을 "프로퍼티 id 496" 이라 적었는데,
> 같은 자리를 **멤버 오프셋**으로 쓰는 명령이 실재한다 — `0x1401ea0b6` `mov byte [rdi+0x1f0], al`
> 이 머티리얼 객체의 blending 열거값을 그 오프셋에 쓴다. `colorBlendMode` 도 마찬가지로
> `[rbx+0x34] = 0x32c` 이고 `0x140206be0` 이 `[rdi+0x32c]` 를 읽는다. 즉 디스크립터의
> `+0x34` 는 **멤버 오프셋**이다.

### 7.5.2 범위 밖 정수 = 클램프가 **아니라** Normal 로 흘러내림

`colorBlendMode` 는 `combos.BLENDMODE` 로 **그대로** 실린다 — 세 자리 전건
(`0x140206be0` 오브젝트 머티리얼 합성기 · `0x1401ebc96` effectpassthrough 합성기 ·
`0x140257911` 세 번째 사본) `movsxd rcx, esi` 후 대입이고 상한 검사가 없다.
그러면 셰이더가 `#define BLENDMODE 99` 로 컴파일돼 `ApplyBlending` 마지막 줄로 떨어지고
결과는 **BlendNormal = `mix(A,B,opacity)`**, 즉 평범한 알파 합성이다. 음수도 같다.

→ `SceneDocument.blendModeVal`(`Sources/WapleCore/SceneDocument.swift:3495`)이 범위 밖을
**32 로 자르지 않고 0 으로 떨어뜨리는** 종전 선택은 이제 실측 뒷받침이 있다. 0 도 결국 같은
알파 합성이라 불투명 배경에서 화면이 같다. (종전 주석은 "32 로 자르면 Negation 이 적용된다"
는 **추론**이었다. 결론은 같지만 근거가 바뀐다.)

### 7.5.3 0 과 31 은 셰이더 표에 도달하지 않는다 — WE 의 native 고속 경로

머티리얼 합성기 세 자리가 전건 같은 코드를 갖는다:

```
0x140206be0  mov  esi, [rdi+0x32c]   ; colorBlendMode
0x140206be9  test esi, esi
0x140206beb  je   0x140206bf2        ; 0 이면
0x140206bed  cmp  esi, 0x1f
0x140206bf0  jne  0x140206bf5        ; 31 이 아니면 그대로
0x140206bf2  mov  esi, r12d          ; 0 또는 31 → combos.BLENDMODE = 0
0x140206c26  movsxd rcx, esi
0x140206c29  mov  [rax], rcx
```

그리고 드로우 직전에 머티리얼 blending 열거값을 **갈아끼운다**(두 자리, 사본):

```
0x1401ea096  cmp  dword [rbx+0x32c], 0x1f
0x1401ea0a4  jne  0x1401ea0aa
0x1401ea0a6  mov  al, 2              ; 2 = additive (§4.1 표)
0x1401ea0b6  mov  [rdi+0x1f0], al
                                     ; else al = call [vtable+0x120] (머티리얼 자기 blending)
0x140208786  cmp  dword [rbp+0x32c], 0x1f   ; 두 번째 사본 — 원값을 0x14020878d/0x140208795 에서
                                     ;   [rsp+0xb0] 로 빼 두고 0x140208c09 에서 되돌린다
```

거기에 **프레임버퍼 요청도 같은 조건으로 걸린다** — `0x1401e8ef2`/`0x1401e8f44` 가 같은
`0 또는 31` 검사를 하고, 아닐 때만 `_rt_FullFrameBuffer`(`0x14048b588`)를 잡는다
(`0x1401e8f7f` / `0x1401ea0fb`).

정리:

| colorBlendMode | combos.BLENDMODE | 머티리얼 blending | `_rt_FullFrameBuffer` | 성격 |
| ---: | ---: | --- | --- | --- |
| 0 | 0 | 저작대로(오브젝트 기본) | 안 잡음 | native |
| 31 | 0 | **강제 additive(2)** | 안 잡음 | native |
| 1…30 · 32 | 그 값 | 저작대로 | **잡음** | emulated(셰이더) |
| 범위 밖 | 그 값 | 저작대로 | 잡음 | `#if` 미적중 → BlendNormal |

에디터 UI 의 그룹 헤더 `native (fast)` / `emulated (slow)` 가 이 분기와 정확히 맞는다
(**추정**: 그룹 멤버십 자체는 `wallpaperui.exe` 를 더 뜯어야 확정된다. 확정된 것은
"엔진이 native 로 처리하는 오브젝트 모드는 0 과 31 뿐" 이다).

> **[2026-08-21 · 위 추정 해소 — 툼스톤]** 뜯었다. `wallpaperui.exe` 의 두 `isgrouptitle`
> 사이(`0x14016007e`–`0x1401600f3`)에 적재되는 항목은 **정확히 {0, 31}** 이고, 나머지 31개는
> `group_emulated`(`0x1401600f3`) 뒤에 온다. 곧 그룹 멤버십 = 엔진 고속 경로다. 위 괄호의
> "추정" 문면은 기록으로 남긴다 — 지금의 등급은 **확정**이다. 전문은 §7.6.3,
> 정본은 `spec/engine/blend-modes.json` `blend.nativeVsEmulated`.

`genericimage2.frag` 의 해당 블록이 emulated 경로의 정본이다:

```glsl
#if BLENDMODE
    vec2 screenCoord = v_ScreenCoord.xy / v_ScreenCoord.z * vec2(0.5, 0.5) + 0.5;
    vec4 screen = texSample2D(g_Texture4, screenCoord);   // g_Texture4 default "_rt_FullFrameBuffer"
    gl_FragColor.rgb = ApplyBlending(BLENDMODE, screen.rgb, gl_FragColor.rgb, gl_FragColor.a);
    gl_FragColor.a = screen.a;
#endif
```

### 7.5.4 알파 / 프리멀티플라이

* WE 는 **straight(비-프리멀티)** 알파를 셰이더에서 내고 블렌드 상태가 `SRC_ALPHA` 를 곱한다
  (§6 B5/B7, 정본 `renderState.alpha.straightNotPremultiplied`).
* 위 블록의 `ApplyBlending` 은 **A·B 양변 모두 straight** 다. A 는 프레임버퍼 색(누적 결과),
  B 는 이 레이어의 straight 색, opacity 는 이 레이어의 straight 알파.
* 알파는 `gl_FragColor.a = screen.a` 로 되돌리고, 머티리얼 드로우는 `WriteMask 7`(§4.2)이라
  **알파를 아예 기록하지 않는다**.
* Waple `QuadShaders.f_blend` 는 같은 규약이다 — `c.rgb` 에 알파를 곱하지 않고
  `applyBlending(mode, d.rgb, c.rgb*tint.rgb, c.a*tint.a)` 로 넘기고 `float4(r, d.a)` 로 쓴다
  (하드웨어 블렌딩 OFF). dst 로 쓰는 acc 는 프리멀티 누적이지만 **누적 RGB 식이
  `src*a + dst*(1-a)` 로 WE 프레임버퍼와 동일**하므로 A 가 그대로 맞고, 알파는 `d.a` 를
  되쓰므로 "안 건드림" 과 같다. **즉 이 경로의 RGB·A 는 WE 와 수식이 같다.**
* 31 도 마찬가지다 — `A + B*o` = `dst + src.rgb*src.a` 는 WE 의 additive 하드웨어 블렌드
  (`SRC_ALPHA`/`ONE`)와 같은 식이다. **틀리지 않고, 대신 비싸다**(§7.5.6).

### 7.5.5 코퍼스 도달 — 범위 라벨 포함

| 모집단 | 측정 |
| --- | --- |
| 워크샵 코퍼스(정본 `spec/corpus/scene-schema.json` `scene.objects.colorBlendMode` **인용**, 이 컨테이너에 코퍼스가 없어 재측정 안 함) | image **782건/83씬**, text **41건/14씬**, 범위 밖 **0건**. image 분포 31:447 · 0:132 · 11:45 · 6:37 · 2:29 · 1:16 · 22:12 · 7:11 · 32:10 · 9:9 · 30:7 · 12:5 · 23:4 · 24:4 · 3:3 · 4:2 · 21:2 · 8/15/16/18/19/27/28 각 1. text 분포 0:18 · 31:12 · 11:4 · 12:2 · 17:2 · 24:2 · 28:1 |
| image 미도달 모드 | 5 · 10 · 13 · 14 · 17 · 20 · 25 · 26 · 29 (9종) |
| 동봉 `Sources/WapleRender/Resources/WEAssets` (json 1698) | `objects[].colorBlendMode` 42건/32파일 **전건 0**. `passes[].combos.BLENDMODE` 10건/8파일 = {0:6, 2:2, 9:1, 23:1} |
| 설치본 `wallpaper_engine` (json 2143) | `colorBlendMode` 66건/36파일 = {0:60, 11:5, 12:1}. `passes[].combos.BLENDMODE` 12건/10파일 = {0:6, 2:2, 9:1, 12:1, 23:1, 30:1} |
| 셰이더 `[COMBO] "type":"imageblending"` 선언(설치본 `*.frag`/`*.vert` 전수 58줄) | `default` = 0×14 · 2×10 · 9×10 · 12×6 · 31×8 · 32×5 · 30×3 · 22×2 |
| `colorBlendMode ∉ {0,31}` × 머티리얼 `blending == "additive"` | 설치본 6건(`razer_bedroom` 11×5·12×1) 전부 `material` 키 부재 → **동봉·설치본 도달 0** |

**따라서 워크샵 코퍼스에서 31 이 image 오브젝트의 57%(447/782)로 최다**이고, 이것이 WE 에서는
셰이더를 아예 안 타는 native 경로다.

### 7.5.6 Waple 대조 — 어긋난 항목 (§6 표의 연장)

| # | 항목 | WE(실측) | Waple | 도달 | 등급 |
| --- | --- | --- | --- | --- | --- |
| **B8** | `colorBlendMode == 31` | `combos.BLENDMODE=0` + 머티리얼 blending **additive 강제**, 프레임버퍼 스냅샷 **안 잡음**(`0x1401ea096`·`0x1401e8ef2`) | `f_blend` 스냅샷 경로 + `case 31: A+B*o`. **수식 동일**, 대신 레이어마다 acc 전체를 blit 한다(`SceneRendererFrameEncoder.swift:474` `blit.copy(from: acc, to: snap)`) | 워크샵 image 447/782 · text 12/41. 동봉/설치본 0 | **성능**(그림 차이 없음) |
| **B9** | `colorBlendMode ∉ {0,31}` 인데 머티리얼이 `additive`/`translucent` | 셰이더 블렌드 결과에 **하드웨어 블렌드가 한 번 더 적용**된다(머티리얼 blending 이 그대로 남으므로) | `f_blend` 는 하드웨어 블렌딩 OFF — 계산 결과를 직기록 | 배경 알파 1 이면 두 경로가 같다. 갈리는 것은 acc 알파 < 1 구간 + additive 조합. **동봉·설치본 도달 0**, 워크샵 미측정 | **[미해결]** |
| **B10** | 범위 밖 정수 | 클램프 없음 → `#if` 미적중 → BlendNormal | 파스에서 0 으로 접음(`SceneDocument.swift:3495`) | 세 코퍼스 전건 0 | **일치**(불투명 배경 기준) |

**B8 의 정확한 패치안**(소유 밖 — `SceneRendererFrameEncoder.swift` / `SceneRenderer.swift` 는 U):
`encodeDrawPlan`(`:861` `case .layer where layers[item.idx].colorBlendMode != 0`)의 매치 조건을
`!= 0 && != 31` 로 좁히고, `GPULayer.blendAdditive` 를 `layer.colorBlendMode == 31 || 머티리얼
additive` 로 계산하면(`SceneRendererResources.swift:552`) 31 은 기존 additive 파이프라인으로
떨어진다. **스냅샷 blit 1회와 풀 텍스처 1장이 레이어마다 사라진다.**
텍스트 쪽(`:845` `case .text where … colorBlendMode != 0`)도 대칭으로 처리해야 한다.
단, `f_main`/additive 파이프라인은 **프리멀티 출력**(`c.rgb*tint.rgb*a`)이고 WE 는 straight+
`SRC_ALPHA` 라 RGB 는 같지만 **알파를 기록한다**(§6 B5/B7 의 구조 분기) — 그 차이는
`colorBlendMode` 도입 전과 동일하므로 새 회귀는 아니다. 넣기 전에 `BlendModeCoverageTests`
(31 대 9 의 구분)와 골든 A/B 를 돌려라.

## 7.6 에디터 드롭다운 — 라벨↔값 전수와 native/emulated 확정 (2026-08-21, 클러스터 CJ)

§7.5.1 은 `bin/wallpaperui.exe` 의 라벨 33개를 세면서 **"라벨↔값 짝은 이 풀 순서로 짓지 마라"**
로 끝냈다(함정 #16). 이번에 그 짝을 **명령에서 직접** 떴다. 정본은
`spec/engine/blend-modes.json`(`blend.editorDropdown` · `blend.nativeVsEmulated`)이고
생성기는 `scripts/spec/measure_blend_modes.py` 다.

### 7.6.1 짝을 짓는 명령 — **값이 라벨보다 앞이다**

드롭다운 항목 하나는 세 명령으로 만들어진다(`bin/wallpaperui.exe`, imagebase `0x140000000`):

```
0x1401600c7  lea r8,  [rip + 0x97403a]   ; 0x140ad4108  "31"
0x1401600ce  lea rdx, [rip + 0x974083]   ; 0x140ad4158  "ui_editor_blending_add"
0x1401600d5  call 0x14015fa30            ; f(rcx = json, rdx = label, r8 = value)
```

`sub_14015fa30`(`0x14015fa30`–`0x14015fba9`)이 rdx 를 `"label"` 키에, r8 을 `"value"` 키에
넣는다 — `0x14015fa6d` `lea rdx, "label"`(`0x140ac99bc`) 과, `0x14015faf6` `mov rcx, rbp`
(rbp 는 `0x14015fa4e` 에서 r8 을 받았다) 뒤의 `"value"`(`0x140ab21f0`)다.

**값 문자열이 라벨보다 먼저 적재된다.** 그래서 "라벨 다음에 나오는 정수" 로 짝지으면 한 칸
밀린다 — 이 문서를 쓰면서 실제로 한 번 밀렸고(생성기가 두 `lea` 의 목적지를 바꿔 읽어 0건이
나왔다) 그래서 생성기가 `ui_editor_blending_` 접두와 `\d+` 를 **양쪽 다** 단언한다.

33개 중 31개가 이 고정 패턴(7+7+5바이트)이다. 나머지 둘은 MSVC 가 `std::string` 을 길게
지어 올리는 갈래라 패턴이 다르고, **바이트 증거로** 확정했다:

| 값 | 라벨 | 증거 |
| ---: | --- | --- |
| 1 | `ui_editor_blending_darken` | `0x14016035a` `lea rcx, "1"`(`0x140accdf0`) → `sub_140234c20`(len=1) → 키 `"value"` `0x140160387` |
| 30 | `ui_editor_blending_tint` | `0x140160213` `mov word [rax+4], 0x3033` = `"30"`, 길이 2 는 `0x140160206` `mov dword [rax], 2` → 키 `"value"` `0x140160219` |

교차검증: 33개 값 집합이 **정확히 0…32** 다(생성기가 아니면 exit(1)).

### 7.6.2 전수 표 — UI 이름은 매크로 이름과 **일곱 자리에서 갈린다**

| 값 | UI 라벨(`ui_editor_blending_…`) | `common_blending.h` 매크로 | 갈리나 |
| ---: | --- | --- | :---: |
| 0 | `normal` | `BlendNormal` | |
| 1 | `darken` | `BlendDarken` | |
| 2 | `multiply` | `BlendMultiply` | |
| 3 | `color_burn` | `BlendColorBurn` | |
| 4 | `linear_burn` | `BlendSubstract` | ● |
| 5 | `darker_color` | (매크로 없음 — `min(A,B)`) | ● |
| 6 | `lighten` | `BlendLighten` | |
| 7 | `screen` | `BlendScreen` | |
| 8 | `color_dodge` | `BlendColorDodge` | |
| 9 | `linear_dodge` | `BlendAdd` | ● |
| 10 | `lighter_color` | (매크로 없음 — `max(A,B)`) | ● |
| 11 | `overlay` | `BlendOverlay` | |
| 12 | `soft_light` | `BlendSoftLight` | |
| 13 | `hard_light` | `BlendHardLight` | |
| 14 | `vivid_light` | `BlendVividLight` | |
| 15 | `linear_light` | `BlendLinearLight` | |
| 16 | `pin_light` | `BlendPinLight` | |
| 17 | `hard_mix` | `BlendHardMix` | |
| 18 | `difference` | `BlendDifference` | |
| 19 | `exclusion` | `BlendExclusion` | |
| 20 | `subtract` | `BlendSubstract`(**4와 같은 매크로**) | ● |
| 21 | `reflect` | `BlendReflect` | |
| 22 | `glow` | `BlendGlow` | |
| 23 | `phoenix` | `BlendPhoenix` | |
| 24 | `average` | `BlendAverage` | |
| 25 | `negation` | `BlendNegation` | |
| 26 | `hue` | `BlendHue` | |
| 27 | `saturation` | `BlendSaturation` | |
| 28 | `color` | `BlendColor` | |
| 29 | `luminosity` | `BlendLuminosity` | |
| 30 | `tint` | `BlendTint` | |
| 31 | `add` | (매크로 없음 — `A + B·opacity`) | ● |
| 32 | `diffuse_light` | (매크로 없음 — `mix(A, A+A·B, o)`) | ● |

**이것이 함정 #27 의 교과서적 사례다.** 매크로 이름만 인용하면:

* 모드 4 를 "Subtract" 라고 부르게 되는데 저작자가 UI 에서 고른 것은 **Linear Burn** 이다.
  Photoshop 의 Linear Burn 이 `base + blend − 1` 인 것과 정확히 맞고, 매크로 이름 쪽이 오기다.
* 모드 9 를 "Add" 라고 부르게 되는데 UI 의 **Add 는 모드 31** 이다. 모드 9 는 **Linear Dodge**
  (= 클램프 있는 가산)이고, 31 은 클램프 없이 `A + B·o` 인 하드웨어 additive 다.
  워크샵 씬에서 image 오브젝트의 최다 값이 31 인 것(§7.5.5)이 이 이름으로 자연스럽게 읽힌다 —
  저작자가 고른 것은 "Add" 였다.
* 모드 20 은 UI 에서 **Subtract** 인데 매크로가 모드 4 와 같다. 곧 **WE 의 Subtract 는 실제로
  Linear Burn 을 한다** — 원본의 결함이고, 이식본은 그 결함을 그대로 보존해야 한다
  (`BlendMSL.applyBlending` `case 20` 이 `case 4` 와 같은 식인 것이 옳다).

### 7.6.3 native / emulated 그룹 — §7.5.3 의 **추정을 확정으로**

드롭다운은 `isgrouptitle` 두 개로 갈린다:

```
0x14016007e  lea rdx, "ui_editor_blending_group_native"     ; 0x140ad40e0
   … normal(0) · add(31) …
0x1401600f3  lea rdx, "ui_editor_blending_group_emulated"   ; 0x140ad4130
   … tint(30) · darken(1) · … 나머지 31개 …
```

두 헤더 사이에 적재되는 항목은 **정확히 {0, 31}** 이다(생성기가 값 목록을 미리 알지 않고
**적재 주소 순서로만** 판정한다 — 0/31 을 필터로 넣으면 순환 논증이 된다).

이것은 §7.5.3 이 엔진에서 뜬 고속 경로와 **경계가 같다**:

| 엔진 자리 | 하는 일 |
| --- | --- |
| `0x140206be0` · `0x1401ebc96` · `0x140257911` | `colorBlendMode ∈ {0,31}` 이면 `combos.BLENDMODE = 0` |
| `0x1401ea096` · `0x140208786` | `colorBlendMode == 31` 이면 머티리얼 blending 을 additive(2)로 강제 |
| `0x1401e8ef2` · `0x1401e8f44` | 같은 검사로 `_rt_FullFrameBuffer` 요청을 건너뜀 |

곧 §7.5.3 의 "**추정**: 그룹 멤버십 자체는 wallpaperui.exe 를 더 뜯어야 확정된다" 는
**해소됐다** — 뜯었고, 답은 native = {0, 31} 이다. 그 절의 옛 문면은 툼스톤으로 남긴다.

### 7.6.4 수식 3자 대조 — 어긋나는 자리 0

`BlendMSL.swift`(MSL) 가 원본과 갈리는 자리를 찾기 위해, 세 문면을 파이썬으로 옮겨
격자 평가했다:

1. **WE 원문** `common_blending.h` — `blend == 0.0` / `blend == 1.0` 정확 비교와
   무가드 `sqrt(base)` 까지 문면 그대로.
2. **`Sources/WapleRender/BlendMSL.swift`** — `select(...)` · `max(s,1e-5)` 관용구 그대로.
3. **`Sources/WapleCore/BuiltinShaderIncludes.swift`** — GLSL 심(`step(...)` 관용구).

격자: A·B 각 성분을 0…255/255 중 52단계 + `{0, 0.5, 1}`, opacity `{0, 0.25, 0.5, 0.75, 1}`,
모드 0…32 와 범위 밖 `{-1, 33, 99}`.

**결과: 입력이 [0,1] 안이면 36개 모드값 전건 `|Δ| < 1e-9`. 고칠 자리가 없다.**

범위 밖([0,1] 밖) 입력에서만 갈리고, 갈리는 자리는 **전부 이미 등록된 이탈**이다:

| 모드 | 갈리는 이유 | 등록처 |
| --- | --- | --- |
| 3 · 8 · 14 · 17 · 21 · 22 | WE 의 `blend == 0` / `blend == 1` **정확 비교**를 `s <= 0` / `s >= 1` **범위 비교**로 바꿨다 | `spec/engine/deviations.json` `deviation.D3` |
| 12 | WE 는 `sqrt(base)` 무가드(base<0 에서 NaN) · 포트는 `sqrt(max(b,0))` | 아래 §7.6.5 |
| 26 · 27 · 28 · 29 | WE 의 `#ifdef HDR color = saturate(color)` 를 포트는 무조건 적용 | `BlendMSL.swift` F676 주석 |

8비트 입력(`k/255`)에서는 `max(s, 1e-5)` 엡실론이 **발동조차 하지 않는다** — `1−s` 의 최소
비영값이 `1/255 ≈ 0.0039` 로 `1e-5` 보다 두 자리 크고, `s == 1` 은 `select` 가 먼저 잡는다.

### 7.6.5 클램프와 알파 — 명령 단위 확인

**클램프.** `f` 접미 매크로는 클램프가 **없다**(`BlendLinearDodgef(base, blend) = (base + blend)`,
`common_blending.h:106`). 모드 15 의 `blend >= 0.5` 가지가 바로 그것을 쓰므로 **1을 넘을 수 있다**
— MSL 포트가 `b + 2.0*(s-0.5)` 로 클램프 없이 두는 것이 원본과 같다. 최종 클램프는 렌더타깃이
한다: Waple 은 `accPixelFormat` 이 LDR 에서 `bgra8Unorm`(UNORM 쓰기 클램프),
HDR·high/ultra 에서 `rgba16Float`(클램프 없음)이고 — WE 도 LDR 은 UNORM, HDR 은 float 이라
**두 경로 다 같다**. (`Sources/WapleRender/SceneRenderer.swift` 의 `var accPixelFormat` 참조.)

**알파.** `genericimage2.frag:162-167` 이 emulated 경로의 정본이다:

```glsl
gl_FragColor.rgb = ApplyBlending(BLENDMODE, screen.rgb, gl_FragColor.rgb, gl_FragColor.a);
gl_FragColor.a = screen.a;
```

* `screen` 은 `g_Texture4`(= `_rt_FullFrameBuffer`) 샘플 — **프레임버퍼 색이므로 straight** 다.
* `gl_FragColor` 는 같은 파일 머리에서 `color.rgb *= g_Brightness; color.a *= g_UserAlpha;`
  로 만들어진다(`genericimage2.frag:67-69`) — **rgb 에 알파를 곱하는 자리가 없다.**
  곧 B 도 straight 이고 opacity 는 그 레이어의 straight 알파(`albedo.a × g_UserAlpha`)다.
* 그래서 **`ApplyBlending` 의 A·B 는 절대 프리멀티가 아니다.**

Waple `QuadShaders.f_blend` 가 같은 규약이다 — `c.rgb * tint.rgb`(알파 미곱) 와
`o = c.a * tint.a`(= `albedo.a × g_UserAlpha`) 를 넘기고, `float4(r, d.a)` 로 dst 알파를
되쓴다. WE 는 알파를 `screen.a` 로 되돌린 뒤 `WriteMask 7`(§4.2)이라 아예 기록하지 않으므로
**"안 건드림" 이라는 결과가 같다.** 여기에 고칠 자리도 없다.

---

## 8. 게이트

| 게이트 | 결과 |
| --- | --- |
| `python3 scripts/spec/check_canon_generator_keys.py` | **통과** — 불일치 0. 대조 건수 **+7**(이 작업이 더한 항목 수) |
| `python3 scripts/spec/validate.py` | **통과** — 오류 0. 확정 **+7** · 헤지 **+0** |
| `python3 scripts/spec/check_address_ranges.py` | 통과 — 범위 인용 157건 · 위반 0 |
| `python3 scripts/spec/check_spec_shrink_guard.py` | 통과 |
| `python3 scripts/spec/check_stray_artifacts.py` | 통과 |
| `python3 scripts/spec/check_int_narrowing.py` | **실패 — 이 작업과 무관.** `SRC = Sources` 만 훑는 Swift 전용 검사이고(344 → 365), 이번 변경에 Swift 는 없다 |
| `scripts/dev/linux-core-tests.sh` | **빌드 실패 — 이 작업과 무관한 기존 상태.** `Tests/WapleCoreTests/SimplexNoiseTests.swift:61` 의 `v.map(String.init)` 이 리눅스 시임에서 타입 추론에 실패한다. 이번 변경은 `scripts/spec/*.py` 와 `spec/**/*.json` 뿐이고 Swift 는 한 줄도 건드리지 않았다 |
