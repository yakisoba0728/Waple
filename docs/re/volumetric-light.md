# 볼류메트릭 라이트(라이트 샤프트) 복원

WE 의 볼류메트릭 라이트를 **셰이더 평문 + `wallpaper64.exe`(imagebase `0x140000000`)** 양쪽에서
복원한 기록이다. `docs/re/scene-postprocessing.md` §W-17~19 가 "구조가 다르다" 고만 적어 둔 자리를
채운다 — 패스 구성, 샘플 수 규칙, 감쇠/가중, 최종 합성, 그리고 **씬 키 도달 수**까지.

- 셰이더 평문: `wallpaper_engine/assets/shaders/volumetrics*.{vert,frag}` · `blur_k3.frag` ·
  `passthrough.frag` · `common_blur.h`
- 머티리얼: `wallpaper_engine/assets/materials/util/volumetrics_*.json` (6개)
- 바이너리: 파이프라인 `0x140196ce0`–`0x1401988d6`, 리졸브 `0x140198d00`–`0x140198e18`,
  라이트 프로퍼티 등록 `0x14025da80`–`0x14025e827`, 라이트 생성자 `0x14018ff60`
- 코퍼스: 동봉 172 + 설치본 186 = 358 씬 · 워크샵 162 씬은 `spec/corpus/scene-schema.json` 실측치 인용

> **방법론 메모.** 이 항목은 x86 을 파기 전에 셰이더를 읽었어야 하는 전형이었다.
> 샘플 수(12/24/32/64 · 2/3/5/8), 감쇠 곡선, 최종 `×0.1`, 콘 스무드스텝 — **픽셀을 정하는 상수는
> 전부 `volumetricsfront.frag` 191줄 안에 평문으로 있다.** 바이너리가 답한 것은 그 셰이더를
> *어떻게 굴리는가*(패스·타깃·해상도·게이트·유니폼 팩·기본값)뿐이다. 아래 §1/§2 가 그 경계다.

---

## 1. 셰이더에서 얻은 것 — 픽셀 수식 전부

### 1.1 `volumetricsfront.frag` 의 뼈대

```glsl
// :63-72  두 뎁스를 읽어 레이 구간을 정한다
float backDepth  = texSample2DBackBuffer(g_Texture1, screenUV.xy, ...).r;  // _rt_volumetricsBack
float limitDepth = texLoad2D(g_Texture3, screenUV.xy, ...).r;              // _rt_volumetricsSingle
clip(backDepth - screenUVDepth.z);       // 헐 밖이면 픽셀 폐기
backDepth = min(backDepth, limitDepth);  // ← 씬 지오메트리로 출구를 자른다(가려짐의 정체)
```

`REVERSEDEPTH` 콤보에서는 부호가 뒤집혀 `clip(z - backDepth)` / `max(backDepth, limitDepth)` 다(:66-72).

| 정체 | 슬롯 | 뜻 |
| --- | --- | --- |
| `g_Texture1` = `_rt_volumetricsBack` | `sampler2DBackBuffer` | 라이트 **헐 백페이스 깊이** = 레이 출구 |
| `g_Texture3` = `_rt_volumetricsSingle` | `sampler2D`, `texLoad2D` | **씬 깊이** = 출구 상한(가려짐) |
| `g_Texture0` = `_rt_shadowAtlas` | `sampler2DComparison` | `SHADOW` 콤보에서만 |
| `g_Texture2` | `sampler2D` | `COOKIE` 콤보 텍스처 |

프래그먼트 진입점 자체가 **입구**다 — `volumetricsfront.vert:13` 이 헐 프론트페이스를
`a_Position * vec3(0.99, 0.99, 1.0)` 로 살짝 줄여 그린다(POINTLIGHT 은 스케일 없음, :11).
카메라가 헐 안이면 `FULLSCREEN` 콤보가 그 자리에 근평면 풀스크린 삼각형을 넣는다(:16-22).

### 1.2 샘플 수 — QUALITY 콤보 (`:78-97`)

```glsl
#if SHADOW || COOKIE
  QUALITY==4 → 64 · ==3 → 32 · ==2 → 24 · else → 12
#else
  QUALITY==4 →  8 · ==3 →  5 · ==2 →  3 · else →  2
#endif
```

`scene-postprocessing.md` §W-17 이 적은 "12~64" 는 **셰도우/쿠키가 붙은 가지만**이다.
셰도우도 쿠키도 없는 라이트는 **2~8** 샘플로 끝난다. 반경 감쇠 하나뿐인 적분은 매끈해서
샘플이 적어도 되고, 그래서 저품질에서만 블러를 태운다(§2.4).

### 1.3 구간 분할과 지터 (`:113`, `:124-130`)

```glsl
vec3 worldStep = (worldEnd.xyz - worldStart.xyz) / CAST3(sampleCount + 1.0);
#if SHADOW
    worldStart.xyz += worldStep * hash12(screenUV);   // 셰도우 가지에서만 지터
#endif
for (uint s = 0u; s < sampleCount; ++s) { worldStart.xyz += worldStep; ... }
```

**나누는 값이 `N+1` 이고 루프가 더한 뒤 샘플한다** — 즉 k번째(0-based) 샘플은 구간의
`(k+1)/(N+1)` 지점이고 양 끝점을 절대 밟지 않는다. `hash12` 지터는 `SHADOW` 전용이다.

### 1.4 감쇠·가중 (`:115-122`, `:132`, `:139-140`)

```glsl
float maxLightScale = VAR_SPOT_PARAMS_INTENSITY;
float invRadius = 1.0 / VAR_SPOT_PARAMS_RADIUS;
#if POINTLIGHT
  maxLightScale *= length(worldEnd - worldStart) * invRadius * 0.5;   // :119
#else
  maxLightScale *= length(worldEnd - worldStart) * invRadius;         // :121
#endif
...
float radiusFalloff = pow(saturate(1.0 - (length(lightDelta) * invRadius)), VAR_EXPONENT);  // :132
float spotCookie = dot(normalize(lightDelta), VAR_SPOT_FORWARD);
spotCookie = smoothstep(VAR_SPOT_PARAMS_OUTER, VAR_SPOT_PARAMS_INNER, spotCookie);          // :140
```

- 반경 감쇠는 **`radius` 밖에서 정확히 0** 이다. 지수 꼬리가 없다(§W-19 정정).
- 콘은 `smoothstep`(3차)이지 선형 램프가 아니다(§W-18 정정).
- `lightDelta` 는 **라이트 → 샘플** 방향이다. 뷰 레이와 라이트 방향의 각도가 아니다 —
  이게 "화면공간 갓레이" 와 "볼륨 라이트" 를 가르는 지점이다.
- `POINTLIGHT` 은 `spotCookie = 1.0`(:137), `COOKIE` 는 텍스처 RGB 를 곱한다(:154,178).

### 1.5 최종 (`:185-191`)

```glsl
shadowFactor /= sampleCount;
gl_FragColor.rgb = VAR_DENSITY * maxLightScale * shadowFactor * VAR_COLOR * 0.1;
gl_FragColor.a = 1;
```

**`density` 는 순수 배수다.** 거리 감쇠가 아니다 — `density = 0` 이면 화면에 아무것도 안 나온다.
`0.1` 은 하드코딩 스케일이다.

### 1.6 블러 (`blur_k3.frag` + `common_blur.h:25-30`)

```glsl
vec3 blur3(vec2 u, vec2 d) {
    return tex(u + d)*0.25 + tex(u)*0.5 + tex(u - d)*0.25;
}
// blur_k3.vert:13 — d = 1.0 / g_Texture0Resolution.xy (한 픽셀)
```

`VERTICAL` 콤보로 h/v 를 가른다. 반경 1픽셀짜리 3탭이다.

### 1.7 머티리얼 6장 (`materials/util/volumetrics_*.json`)

| 파일 | 셰이더 | 콤보 | 블렌드 | 컬 | 샘플 텍스처 |
| --- | --- | --- | --- | --- | --- |
| `volumetrics_back` | `volumetricsback` | — | normal | normal | — (프래그 본문 없음 = 뎁스만) |
| `volumetrics_front` | `volumetricsfront` | — | **additive** | normal | — (기본 슬롯) |
| `volumetrics_fullscreen` | `volumetricsfront` | `FULLSCREEN=1` | **additive** | nocull | — |
| `volumetrics_blur_h` | `blur_k3` | `VERTICAL=0` | normal | nocull | `_rt_volumetricsLightBuffer` |
| `volumetrics_blur_v` | `blur_k3` | `VERTICAL=1` | normal | nocull | `_rt_volumetricsLightBufferB` |
| `volumetrics_combine` | `passthrough` | — | **additive** | nocull | `_rt_volumetricsLightBuffer` |

`front`/`fullscreen`/`combine` 셋 다 `depthtest`/`depthwrite` disabled 다.

---

## 2. 바이너리에서 얻은 것 — 어떻게 굴리는가

### 2.1 게이트

| 게이트 | VA | 뜻 |
| --- | --- | --- |
| `test byte [this+0x418], 1` | `0x140196cf5` | 볼류메트릭 파이프라인 활성 비트. 0 이면 함수가 즉시 반환 |
| `movzx r15d, byte [ctx+0x1ad]` / `test r15b,r15b` | `0x140196d13`–`0x140196d1e` | **볼류메트릭 QUALITY 바이트**. 0 이면 전부 끔 |
| `byte [light+0x2c4]` 비트 | `0x14025e7bb` 등록 | `castvolumetrics` (기본 false, `0x14019048d`) |

`[ctx+0x1ad]` 는 **앱 품질 설정**이다 — 씬 JSON 키가 아니다. 같은 바이트가 그대로 `QUALITY`
콤보로 들어간다(`0x140198273`). 이웃 `[ctx+0x1ac]` 는 셰도우맵 품질이고
`LIGHTS_SHADOW_MAPPING_QUALITY` 콤보로 간다(`0x1401983af`).

### 2.2 렌더 타깃 4장 — 포맷과 **FBO 스케일**

전부 `sub_1401aadb0(rtManager, width, height, divisor, name, colorFormat, depthFormat, flags, flags2)`
로 만든다. `divisor` 가 스케일이라는 근거는 형제 호출부다 — 같은 인자가
`_rt_FullFrameBuffer`=1 · `_rt_4FrameBuffer`=4 · `_rt_8FrameBuffer`=8 · `_rt_Bloom`=8
(`0x14017f585`–`0x14017f681`). `0x1b` 은 "포맷 없음" 이다(뎁스 없는 컬러 타깃과 컬러 없는
뎁스 타깃이 각각 그 슬롯에 `0x1b` 을 넣는다).

| 이름 | VA(할당) | divisor | 컬러 | 뎁스 | 조건 |
| --- | --- | --- | --- | --- | --- |
| `_rt_volumetricsBack` | `0x140196dd8` | **1**(풀해상도) | `0x1b`(없음) | `0x19` | 항상 |
| `_rt_volumetricsSingle` | `0x140196e33` | `Q≥3 ? 4 : 8` | `0x1b`(없음) | `Q<3 ? 0x17 : 0x19` | 항상 |
| `_rt_volumetricsLightBuffer` | `0x140196e94` | `Q≥3 ? 4 : 8` | HDR? `0xf` : `1` | `0x1b`(없음) | 항상 |
| `_rt_volumetricsLightBufferB` | `0x140196eea` | 같음 | 같음 | `0x1b` | **Q<3 에서만** |

- divisor 산출: `0x140196d79`–`0x140196d88` (`edi = quality >= 3 ? 4 : 8`).
- HDR 판정: `0x14017e750`–`0x14017e75b` — `([ctx+0x118] >> 13) & 1`.
- `Back` 만 풀해상도인 이유는 명확하다. 헐 백페이스 깊이는 프론트 픽셀과 같은 화면 좌표에서
  `sampler2DBackBuffer` 로 읽히므로 해상도가 어긋나면 입·출구가 흐트러진다.

### 2.3 라이트 유니폼 팩 — `g_RenderVar0..4`

한 라이트를 그리기 직전 `[scene+0xc8]` 상수 블록의 `+0xa8`부터 5개 `float4` 를 채운다
(`0x140198716`–`0x1401987f5`). 셰이더 `#define` 과 1:1 로 맞는다.

| 유니폼 | 오프셋 | 값 | VA | 씬 키 |
| --- | --- | --- | --- | --- |
| `g_RenderVar0` (`VAR_SHADOWMAP_TRANSFORMS`) | `+0xa8` | `[light+0x310]` float4 | `0x140198716` | — |
| `g_RenderVar1.x` (`..._RADIUS`) | `+0xb8` | `radius × 0.99` | `0x140198760` (f32=0.99) | `radius` |
| `g_RenderVar1.y` (`..._INNER`) | `+0xbc` | `cos(innercone × π/180)` | `0x1401986ac`(f32=0.0174532924) → `0x140198770` | `innercone` |
| `g_RenderVar1.z` (`..._OUTER`) | `+0xc0` | `cos(outercone × π/180)` | `0x140198778` | `outercone` |
| `g_RenderVar1.w` (`..._INTENSITY`) | `+0xc4` | `[light+0x2e4]` | `0x140198780` | `intensity` |
| `g_RenderVar2.xyz` (`VAR_LIGHT_ORIGIN`) | `+0xc8` | 월드 원점 | `0x140198797`–`0x1401987a9` | `origin` |
| `g_RenderVar2.w` (`VAR_DENSITY`) | `+0xd4` | `[light+0x2f8]` | `0x1401987b2` | **`density`** |
| `g_RenderVar3.xyz` (`VAR_SPOT_FORWARD`) | `+0xd8` | `[light+0x320]` float4 | `0x14019871d` | (angles 유래) |
| `g_RenderVar4.xyz` (`VAR_COLOR`) | `+0xe8` | `[light+0x2cc..0x2d4]` | `0x1401987df`–`0x1401987ed` | `color` |
| `g_RenderVar4.w` (`VAR_EXPONENT`) | `+0xf4` | `[light+0x2fc]` | `0x1401987f5` | **`volumetricsexponent`** |

**콘 각은 저작 단위가 도(度)** 이고 셰이더가 받는 건 코사인이다. Waple 은
`SceneLight3D.forwardSpotConeCosines`(`SceneDocument.swift:733`)가 같은 변환을 이미 한다.

### 2.4 패스 구성표 — 실물

라이트 하나당 2패스, 프레임당 리졸브 3패스. 재료·타깃·게이트는 전부 확정이다.

| # | 언제 | 머티리얼 | 그리는 것 | 타깃 | 게이트 | VA |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 라이트마다 | `volumetrics_back` | 라이트 헐 메시 | `_rt_volumetricsBack`(뎁스만) | — | 재료 `0x140197579` · 셋/드로우/언셋 `0x1401977f1`·`0x140197800`·`0x140197806` |
| 2 | 라이트마다 | `volumetrics_front` **또는** `volumetrics_fullscreen` | 헐 메시 또는 풀스크린 삼각형 | `_rt_volumetricsLightBuffer` (additive) | 첫 라이트에서 1회 클리어 `0x14019791b`–`0x14019792d` | 재료 로드 `0x140198457`·`0x140198478` · 선택 `0x140198536`–`0x140198546` · 셋/드로우/언셋 `0x14019881c`·`0x14019883c`·`0x140198842` |
| 3 | 프레임마다 | `volumetrics_blur_h` | 풀스크린 삼각형 | `_rt_volumetricsLightBufferB` | **QUALITY < 3** | `0x140198d21`–`0x140198d6b` |
| 4 | 프레임마다 | `volumetrics_blur_v` | 〃 | `_rt_volumetricsLightBuffer` | **QUALITY < 3** | `0x140198d80`–`0x140198dbd` |
| 5 | 프레임마다 | `volumetrics_combine` | 〃 | 씬 컬러 (additive) | 항상 | `0x140198df3`–`0x140198e18` |

읽는 법 몇 가지:

- `volumetricsback.frag` 는 **본문이 비어 있다**(2줄). 패스 1은 깊이만 남긴다.
- 패스 2 의 두 머티리얼 선택은 `[scene + (flag^1)*8 + 0x388]` 인덱싱이다(`0x140198546`) —
  플래그가 서면 `+0x388`(fullscreen), 서지 않으면 `+0x390`(front). 같은 플래그가 드로우 대상도
  헐 메시 ↔ 풀스크린 삼각형으로 바꾼다(`0x140198824`–`0x14019883c`). 즉 **카메라가 헐 안에
  들어갔을 때의 대체 경로**다.
- 라이트버퍼는 프레임당 **한 번만** 클리어되고 나머지 라이트는 additive 로 누적된다.
- **블러는 QUALITY < 3 에서만 존재한다.** `_rt_volumetricsLightBufferB` 와 blur 머티리얼 두 장은
  Q≥3 에서 아예 만들어지지도 않고(`0x140196ea0`–`0x140196ea4`), 리졸브도 같은 조건으로
  두 패스를 건너뛴다(`0x140198d21`). 샘플이 많으면 블러가 필요 없다는 설계다.
- 헬퍼 정체: `0x140155fc0` = 머티리얼 셋 · `[vtable+8]` = 메시 드로우 · `0x140157430` = 머티리얼 언셋 ·
  `[vtable+0x48]` = 렌더타깃 푸시 · `0x140162040` = 렌더타깃 팝(`add [rt+0x50], -8`).

### 2.5 라이트 프로퍼티 오프셋과 기본값

등록 테이블 `0x14025da80`–`0x14025e827`(키 → `[light+off]`, 타입 4=float · 5=enum · 6=bool),
기본값은 생성자 `0x14018ff60`.

| 씬 키 | 오프셋 | 기본값 | 기본값 VA |
| --- | --- | --- | --- |
| `light`(종) | `+0x2c0` | `5` | `0x140190486` |
| `castshadow`/`usecookie`/`castvolumetrics` | `+0x2c4` (비트) | 전부 **false** | `0x14019048d` |
| `color` | `+0x2cc` | `0 0 0` | `0x140190460` |
| `intensity` | `+0x2e4` | `0` | `0x14019047f` |
| `radius` | `+0x2e8` | **`1.0`** | `0x140190494` |
| `exponent`(일반 라이팅) | `+0x2ec` | `2.0` | `0x14019049e` |
| `innercone` | `+0x2f0` | `20.0`(도) | `0x1401904a8` |
| `outercone` | `+0x2f4` | `30.0`(도) | `0x1401904b2` |
| **`density`** | `+0x2f8` | **`2.0`** | `0x1401904bc` |
| **`volumetricsexponent`** | `+0x2fc` | **`1.0`** | `0x1401904c6` |
| `cascadedistance0/1` | `+0x300`/`+0x304` | `3.0` / `10.0` | `0x1401904d0`/`0x1401904da` |

Waple 의 파스 기본값(`SceneDocument.swift:1918`–`1921`)은 `density 2` · `volumetricsexponent 1` ·
`castvolumetrics false` 로 **일치**한다. `radius` 만 `?? 0` 이라 WE(1.0)와 다르다 — 다만
코퍼스에서 `radius` 무저작 라이트는 0건이라 실물 차이는 없다.

---

## 3. 씬 키 전수 조사 — 도달 수

### 3.1 동봉 172 + 설치본 186 = 358 씬 (2026-08-21 실측)

전 씬을 재귀 전수 스캔(모든 깊이·모든 키)했다.

| 키 | 358 씬 도달 | 값 |
| --- | ---: | --- |
| `castvolumetrics` | **0** | — |
| `density`(라이트) | 1 | `7.48` |
| `volumetricsexponent` | 1 | `4.0` |

`castvolumetrics` 는 **문자열 자체가 동봉/설치본 자산 JSON 어디에도 없다.** 실행파일
(`wallpaper64.exe`·`wallpaper32.exe`·`wallpaperui.exe`)에만 있다.

라이트 오브젝트 자체가 희소하다 — 동봉 172 씬에 라이트 3개(2씬), 설치본 186 씬에 6개(4씬).
`density`/`volumetricsexponent` 를 가진 유일한 라이트는
`scenes/particleelementpreviews/collisionmodel/scene.json` 의 `lpoint`
(`density 7.48` · `volumetricsexponent 4.0` · `radius 811.69` · `intensity 6.44` · `castshadow true`)
인데 **`castvolumetrics` 가 없다** → WE 에서도 이 패스는 켜지지 않는다.

재현:

```bash
grep -rl castvolumetrics Sources/WapleRender/Resources/WEAssets/ \
    /home/user/Waple-wallpaper-source/wallpaper_engine/assets/    # 무출력
```

### 3.2 워크샵 코퍼스 162 씬 (`spec/corpus/scene-schema.json` 인용)

| 키 | 건수 | 씬 수 | 값 분포 |
| --- | ---: | ---: | --- |
| `castvolumetrics` | 4 | **3** | 전부 `true` |
| `density` | 27 | 11 | `0.65`–`4.12`, distinct 7 |
| `volumetricsexponent` | 27 | 11 | `1.0`–`3.04`, distinct 6 |

**판정.** 동봉 도달 0 · 워크샵 도달 3씬. 픽셀 수식은 옮길 가치가 있지만(§4), 라이트버퍼
다운스케일 + blur 체인처럼 **RT 두 장과 파이프라인 셋을 새로 짓는** 성능 스캐폴딩은 짓지 않는다.

---

## 4. Waple 이식 — 무엇이 바뀌었나

`Sources/WapleRender/VolumetricLightPass.swift`.

### 4.1 종전 (구조가 달랐다)

화면공간 원뿔 근사 1패스였다. 픽셀마다 **뷰 레이와 라이트 방향의 각도** 하나로 원뿔을 그리고
`exp(-density × dist × 0.001)` 로 감쇠했다. 레이마치도, 라이트 볼륨도, 반경도 없었다.
`density` 를 거리 감쇠 계수로 오해한 것이 핵심 오류다(실물은 순수 배수, §1.5).

### 4.2 지금

| 항목 | 실물 | 이식 후 |
| --- | --- | --- |
| 모델 | N 샘플 레이마치 | **동일** — `volumetricsfront.frag:105-191` 전사 |
| 샘플 수 | QUALITY 콤보 표 | **동일** — `VolumetricMath.sampleCount`. Waple 은 티어 4 · 셰도우 미바인딩 → **8** |
| 구간 분할 | `(N+1)` 분할, 끝점 미접촉 | **동일** |
| 반경 감쇠 | `pow(saturate(1-d/R), E)` | **동일** (W-19 해소) |
| 콘 | `smoothstep(outer, inner, cos)`, `lightDelta` 기준 | **동일** (W-18 해소) |
| POINTLIGHT | `spotCookie=1`, 스케일 ×0.5 | **동일** — 콘 코사인 퇴화값(`outer ≤ -0.999`)으로 판정 |
| 최종 | `density × maxLightScale × mean × color × 0.1` | **동일** |
| 입·출구 | 헐 뎁스 2패스 | **해석해**: 뷰 레이 ↔ 반경 구 교차 + 근평면 클램프 |
| 씬 뎁스 클립 | `min(backDepth, limitDepth)` | **없음** ← 남은 구멍 |
| 라이트버퍼 | 1/4·1/8 + blur3 h/v | 없음(목적지에 풀해상도 직접 additive) |

**해석해 대체가 왜 성립하나.** WE 의 헐은 포인트라이트에서 반경 구이고, 셰이더가 쓰는 반경도
`radius × 0.99` 이며 프론트 vert 가 헐을 `0.99` 배 한다 — 즉 포인트라이트에 대해서는 구 교차가
헐 뎁스 2패스와 동치다. 스팟 콘 헐은 같은 구로 감싸고 콘 감쇠가 바깥을 0 으로 눌러 근사한다
(콘 밖 샘플의 `spotCookie` 가 0 이므로 적분에 기여하지 않는다). 근평면 클램프는 WE 의
`FULLSCREEN` 콤보(카메라가 헐 안 → 근평면에서 시작)와 같은 뜻이다.

**의도적 이탈: 풀해상도·무블러.** WE 자신이 QUALITY≥3 에서 blur 를 **아예 건너뛴다**
(`0x140198d21`). 즉 "풀해상도 · 무블러" 는 WE 고품질 경로의 모양이고, 1/8 다운샘플은 저품질
성능 아티팩트다. 복원한 규칙은 `VolumetricMath.lightBufferDivisor` / `blursLightBuffer` /
`blur3Weights` 에 **복원 전용**으로 남겨 뒀다(AGENTS.md "보존 필드는 데드코드가 아니다").

### 4.3 화면 변화 한 줄

> 갓레이가 **화면 전체에 깔리던 원뿔 워시**에서 **라이트 반경 구 안쪽만 채우는 국소 볼륨**으로
> 바뀐다 — 반경 밖에서 정확히 0 이 되어 무한 꼬리가 사라지고, 스포트 가장자리가 3차 보간으로
> 부드러워진다.

### 4.4 남은 두 배선 (이번 담당 파일 밖)

1. **`radius` 배선 — 한 줄.** `SceneRenderer3D.swift:1925`–`1934` 의
   `VolumetricLightParameters(...)` 호출에 `radius: light.radius` 를 더하면 된다.
   그전까지 `VolumetricLightParameters.radius` 는 기본값 0 이고, 패스는 WE 라이트 생성자
   기본 반경 1.0(`0x140190494`)으로 마치한다 — 반경 1 짜리 헐이라 **사실상 비가시**이고,
   그게 WE 가 무저작 반경에 대해 하는 일 그대로다. `encode` 가 1회 경고를 남긴다.
2. **씬 뎁스 클립(W-17 잔여).** `SceneRenderer3D.swift:1466` 의 `pooledDepth` 는
   `usage=[.renderTarget]` · `storeAction=.dontCare` 라 샘플할 수 없다. `.shaderRead` 를 주고
   저장한 뒤 `encode` 에 넘기면 `_rt_volumetricsSingle` 과 같은 역할을 해서 샤프트가
   지오메트리에 가려진다. 그전까지는 통과한다.

또한 `Tests/WapleRenderTests/VolumetricLightTests.swift` 의
`testVolumetricLightDirectionUsesForwardConverterNotRawEulerAngles` 는 **`density: 0` · `radius` 무저작**
씬으로 중앙 픽셀이 밝기를 단언한다. 종전 모델에서 `exp(-0 × d × 0.001) = 1` 이라 통과하던
픽스처인데, 실물에서 `density` 는 순수 배수라 0 이면 **WE 도 아무것도 안 그린다**(§1.5).
콘/방향 변환기 회귀를 계속 잡으려면 그 씬의 `density` 만 올리면 된다 — 반경 무저작(=WE 기본 1.0)
이어도 카메라가 10 밖에 안 떨어져 있어 헐이 중앙 화소를 덮는다. 같은 순수 함수로 미리 계산한
중앙 화소 값은 `density × 0.3333` 이다:

| `density` | 0 | 1 | 2 | 2.5 | **3** | 4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 중앙 rgb | 0.0000 | 0.3333 | 0.6667 | 0.8333 | **1.0000** | 1.3333 → 포화 1.0 |

즉 `"density":0` 을 `"density":3` 으로 바꾸면 단언(`> 0.5`)이 포화 마진과 함께 성립한다.
`radius` 까지 저작하면(예: 20) 배선 완료 후에도 그대로 통과한다.

---

## 5. `scene-postprocessing.md` §W-17~19 정정

| 항목 | 종전 기술 | 이번 실측 |
| --- | --- | --- |
| W-17 "12~64 샘플" | 그렇게만 적힘 | **셰도우/쿠키 가지만** 12~64. 그 외는 2~8 (`:88-96`) |
| W-17 "5패스" | 패스 수만 | 라이트당 2 + 프레임당 3. 블러 2 는 **QUALITY<3 에서만** |
| W-17 `×0.1` | 위치 미표기 | `volumetricsfront.frag:190` |
| W-18 콘 | `smoothstep(outer, inner, cos)` — **맞음** | 인자 `cos` 가 **뷰 레이가 아니라 `normalize(샘플-라이트)`** 라는 점이 핵심 |
| W-19 반경 | `pow(saturate(1-d/r), exp)` — **맞음** | `r` 은 `radius × 0.99` (`0x140198760`) |
| (신규) FBO 스케일 | 없음 | 라이트버퍼/Single `Q≥3 ? 1/4 : 1/8`, Back 은 풀해상도 |
| (신규) QUALITY 출처 | 없음 | 앱 설정 바이트 `[ctx+0x1ad]` — 씬 키 아님 |

---

## 6. 리눅스 단독 대조

`VolumetricLightPass.swift` 말미의 `enum VolumetricMath` 는 Metal·simd 를 안 쓰는 **순수 산술**만
모아 둔 자리다. 그 블록만 잘라 리눅스에서 컴파일·실행하고, 같은 파일이 아닌 **독립 전사본**
(`volumetricsfront.frag` 를 줄 단위로 옮긴 참조 구현)과 값을 대조했다.

```bash
S=/home/user/Waple/Sources/WapleRender/VolumetricLightPass.swift
{ echo 'import Foundation'; sed -n "/^enum VolumetricMath {/,\$p" "$S"; } > math_only.swift
swiftc -O math_only.swift main.swift -o volcheck && ./volcheck    # main.swift = 참조 전사 + 대조
```

실행 결과(2026-08-21, Swift on Linux):

```
== 1. 샘플 수 규칙          Q0..Q4 → shadow 12/12/24/32/64 · plain 2/2/3/5/8      (참조 전사와 일치)
== 2. 라이트버퍼 FBO 스케일  Q0..Q2 → 1/8 · 블러 있음   |  Q3..Q4 → 1/4 · 블러 없음
== 3. 반경 감쇠 R=100       E=1: 1.0 .8 .6 .4 .2 0 0    E=2: 1.0 .64 .36 .16 .04 0 0
                            E=4: 1.0 .4096 .1296 .0256 .0016 0 0     (반경 밖 정확히 0)
== 4. 콘 smoothstep         inner=cos15° outer=cos30° → 0°:1.0  10°:1.0  20°:0.8293  30°:0  40°:0
== 5. 헐 반경               radius 811.69 → 803.57312 · radius 0 → 0.99 (WE ctor 기본 1.0 × 0.99)
== 6. 샘플 위치 N=8         0.1111 0.2222 … 0.8889   (끝점 미접촉)
== 7. 전 구간 대조          Q1..Q4 × point/spot 8케이스 전부 ref == ported (오차 ≤1e-4)
                            예: Q4 point ref=1.058749 ported=1.058749 · Q4 spot ref=1.278193 ported=1.278194
== 8. density=0             rgb=0.000000  (VAR_DENSITY 는 순수 배수)
ALL OK (실패 0)
```

§7 의 입력은 동봉 `collisionmodel` 씬의 실제 라이트 저작값
(`density 7.48` · `volumetricsexponent 4` · `intensity 6.44` · `radius 811.69` ·
`origin 281.837 315.168 162`)이다.

---

## 7. 남은 미확정

- `_rt_volumetricsSingle` 을 **무엇이 채우는지**는 셰이더 쪽 용법(`texLoad2D` 로 `limitDepth`,
  `min(backDepth, limitDepth)`)과 할당 스펙(뎁스 전용 · 라이트버퍼와 같은 해상도)까지가 확정이고,
  씬 깊이를 그 해상도로 내려 담는 지점의 VA 는 특정하지 않았다. 소비 규약이 확정이라 이식에는
  영향이 없다.
- `sub_1401aadb0` 의 8·9번째 인자(`Back` 은 `(bit<<25)|8` / `bit<<5`, 나머지는 `8`·`0xa`·`0`)는
  플래그로 보이나 의미 미확정. 스케일·포맷과 무관하다.
- `[this+0x418]` 비트 1/2 의 정확한 수명(활성 플래그 · 프레임당 클리어 래치)은 관측된 사용처
  (`0x140196cf5` 게이트 · `0x14019791b` 클리어 · `0x140198d06` 리졸브 진입)까지만 확정.
