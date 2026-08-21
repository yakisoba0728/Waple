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

**셰이더 콤보 넷 — 무엇이 세우나 (2026-08-21 실측).** 콤보 이름은 전부 ≤15바이트라 MSVC SSO 로
오고, `lea` 가 아니라 데이터 블롭의 `mov`/`movzx`/`movsd` 로 실린다(선형 `lea` 스캔은 0건을 준다).

| 콤보 | 세우는 조건 | 판정 VA | 이름 문자열 적재 |
| --- | --- | --- | --- |
| `SHADOW` | `[light+0x2c4]` **bit0**(`castshadow`) **그리고** `[mat+0x1ac] != 0`(셰도우맵 품질) | `0x1401981ea`·`0x1401981fa` | `0x140491a80` (`"SHADOW\0"`) |
| `COOKIE` | `[light+0x2c4]` **bit1**(`usecookie`) | `0x14019817e`–`0x140198188` | `0x140491b18` (`"COOKIE\0"`) |
| `QUALITY` | `[mat+0x1ad]` 바이트 **그대로** | `0x140198273` → `0x1401982bc` | `0x140491a88` (`"QUALITY\0"`) |
| `POINTLIGHT` | `[light+0x2c0] == 0` (= 씬 `"light":"lpoint"`) | `0x1401982fa` / `jne 0x140198445` | `0x140491a90`+`0x140491a98` (`"POINTLIGHT\0"`) |

즉 **POINTLIGHT ⟺ `light == "lpoint"`** 다(종 표는 `docs/re/scene-lighting.md` §1.1). Waple 은
호출부가 종을 안 넘겨 콘 코사인 퇴화(`outer ≤ −0.999`)로 근사한다 — 코퍼스에서는 일치하지만
`ldirectional`(종 3, 콘 미저작)은 원리상 잘못 잡는다(도달 0건, §3).

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
(`0x140198679`–`0x1401987f5`). 상수 블록은 `+0xa8`부터 **stride 0x10** 이므로
`+0xa8/+0xb8/+0xc8/+0xd8/+0xe8` = `g_RenderVar0..4` 다. 셰이더 `#define` 과 1:1 로 맞는다.

| 유니폼 | 오프셋 | 값 | VA | 씬 키 |
| --- | --- | --- | --- | --- |
| `g_RenderVar0` (`VAR_SHADOWMAP_TRANSFORMS`) | `+0xa8` | `[light+0x310]` float4 | `0x140198716`(load)/`0x14019871d`(store) | — |
| `g_RenderVar1.x` (`..._RADIUS`) | `+0xb8` | `radius × 0.99` | `0x140198760` (f32=0.99) | `radius` |
| `g_RenderVar1.y` (`..._INNER`) | `+0xbc` | `cos(innercone × π/180)` | `0x1401986ac`(f32=0.0174532924) → `0x140198770` | `innercone` |
| `g_RenderVar1.z` (`..._OUTER`) | `+0xc0` | `cos(outercone × π/180)` | `0x140198778` | `outercone` |
| `g_RenderVar1.w` (`..._INTENSITY`) | `+0xc4` | `[light+0x2e4]` | `0x140198780` | `intensity` |
| `g_RenderVar2.xyz` (`VAR_LIGHT_ORIGIN`) | `+0xc8` | 월드 원점 | `0x140198797`–`0x1401987a9` | `origin` |
| `g_RenderVar2.w` (`VAR_DENSITY`) | `+0xd4` | `[light+0x2f8]` | `0x1401987b2` | **`density`** |
| `g_RenderVar3.xyz` (`VAR_SPOT_FORWARD`) | `+0xd8` | `[light+0x320]` float4 | `0x140198680`(load)/`0x140198687`(store) | (angles 유래) |
| `g_RenderVar4.xyz` (`VAR_COLOR`) | `+0xe8` | `[light+0x2cc..0x2d4]` | `0x1401987df`–`0x1401987ed` | `color` |
| `g_RenderVar4.w` (`VAR_EXPONENT`) | `+0xf4` | `[light+0x2fc]` | `0x1401987f5` | **`volumetricsexponent`** |

> **[2026-08-21 정정] 위 두 행은 종전 표에서 한 칸 밀려 있었다.** 종전 표는 `g_RenderVar0` 에
> load VA(`0x140198716`)를, `g_RenderVar3` 에 **같은 명령쌍의 store VA**(`0x14019871d`)를 적어
> 두 행이 한 명령쌍을 나눠 가졌다. 실제로 `0x140198716`/`0x14019871d` 는 `[light+0x310] → +0xa8`
> 한 쌍이고, `g_RenderVar3`(`+0xd8`)를 채우는 것은 `0x140198680`/`0x140198687`
> (`[light+0x320] → +0xd8`)이다. 디스크립터·언롤 코드에서 반복되는 오프바이원이다(공통 브리프 함정 #16).

**콘 각은 저작 단위가 도(度)** 이고 셰이더가 받는 건 코사인이다. 변환은 **deg2rad 만**이다:

```
0x140198724  movss xmm0, [rsi+0x2f0]      ; innercone (도)
0x14019872c  mulss xmm0, xmm6             ; xmm6 = [0x140492628] f32 = 0.0174532924 (= π/180)
0x140198730  call 0x14041a2e0             ; cosf
0x140198770  movss [rax+0xbc], xmm7       ; → g_RenderVar1.y = VAR_SPOT_PARAMS_INNER
0x140198738  movss xmm0, [rsi+0x2f4]      ; outercone (도)
0x140198740  mulss xmm0, xmm6
0x140198744  call 0x14041a2e0
0x140198778  movss [rax+0xc0], xmm0       ; → g_RenderVar1.z = VAR_SPOT_PARAMS_OUTER
```

`0x14041a2e0` 이 `cosf` 라는 근거: 소인수 경로가 `1.0 − x²·0.5`(`0x14041a340`–`0x14041a348`,
상수 `0x140471bb0`=1.0 · `0x140471bc0`=0.5)이고 극소 |x| 에서 `1.0`(`0x140471cb8`)을 돌려준다.
`xmm6`/`xmm7` 은 Win64 비휘발성이라 `cosf` 호출을 넘어 살아남는다.

**⚠️ 그래서 `innercone`/`outercone` 은 광축에서 잰 반각(도)이고 `× 0.5` 가 붙지 않는다.**
V1 PBR 패커도 똑같다(`0x140192e64`–`0x140192e86` inner → `g_LSpot_Origin[i].w`,
`0x140192eaa`–`0x140192ebf` outer → `g_LSpot_Direction[i].w`; 같은 `xmm7` deg2rad,
적재 `0x1401910bf`). 즉 **볼류메트릭과 PBR 두 레인이 같은 규약**이다.

**Waple 은 지금 이 자리에서 갈린다.** 호출부 `SceneRenderer3D.swift:1918` 이
`SceneLight3D.forwardSpotConeCosines`(`SceneDocument.swift:960`)를 쓰는데 그 함수는 아직
`toHalfRadians = π/180 * 0.5`(`:962`)를 곱한다 — 저작 `innercone 10 / outercone 30` 이
`cos5°/cos15°` 가 되어 **콘이 WE 절반 폭**으로 그려진다. 같은 모듈(WapleRender)에 정본
`Scene3DLighting.spotConeCosines`(`* 0.5` 없음)가 이미 있으므로 호출부 한 줄 교체로 닫힌다.
이번 담당 파일 밖이라 §4.4 에 패치안으로 남긴다.

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

**이 표는 부분집합이다 — 전수 18키는 `docs/re/scene-lighting.md` §1.3** 에 있고, 2026-08-21 에
등록 테이블을 다시 떠서 **행 단위로 재확인했다**(항목당 `lea rdx,<이름>` → `mov [reg+0x34],<오프셋>`
→ `mov [reg+0x30],<타입>`; 타입 2=vec3 4=float 5=enum 6=bool). 이 표에 빠진 것은
`controlpoint`(`+0x2d8`, vec3, `2 0 0`, `0x14025e412`/`0x140190474`) ·
`cascadedistance2`(`+0x308`, `100.0`, `0x14025e29c`/`0x1401904e4`) ·
`lightsourcesize`(`+0x30c`, `0`, `0x14025e35e`) · `visible`(`+0x120`, 공통 오브젝트 필드,
`0x14025e587`) 넷이다.

**`+0x2c4` 비트 배정(볼류메트릭이 실제로 읽는 자리) — 세터에서 배타적으로 확정.**

| 키 | 비트 | 세터 VA | 게터 VA | 확정 근거 |
| --- | --- | --- | --- | --- |
| `castshadow` | bit0 | 공통 `0x1401e1a90` | 공통 `0x1401e1b60` | 남는 비트 + `SHADOW` 콤보 게이트 `0x1401981ea` `test byte [light+0x2c4], 1` · V1 point 패커 `0x14019326b`–`0x1401932ae` |
| `usecookie` | bit1 | `0x14019b4e0` (`or ecx, 2` @`0x14019b51a`) | `0x14019b5b0` (`test byte [rcx], 2`) | 직접 |
| `castvolumetrics` | **bit2** | `0x14019bfa0` (`or ecx, 4` @`0x14019bfda`) | `0x14019c070` (`test byte [rcx], 4`) | 직접 |

**`castvolumetrics` 라이트의 저작 키 전수.** 볼류메트릭 **전용** 키는 없다 — 라이트 오브젝트가
가질 수 있는 키는 위 18개(라이트 고유) + 공통 오브젝트 키(`id`/`name`/`origin`/`angles`/`scale`/
`parent`/`visible`/…)뿐이고, 볼류메트릭 패스는 그중 일부만 읽는다. §2.3 의 유니폼 팩이 실제로
읽는 라이트 필드는 **여덟 개**다:

| 소비되는 필드 | 오프셋 | 어디로 |
| --- | --- | --- |
| `light`(종) | `+0x2c0` | `POINTLIGHT` 콤보 (`0x1401982fa`) |
| `castshadow`/`usecookie` | `+0x2c4` bit0/bit1 | `SHADOW`/`COOKIE` 콤보 |
| `color` | `+0x2cc`,`+0x2d0`,`+0x2d4` | `VAR_COLOR` |
| `intensity` | `+0x2e4` | `VAR_SPOT_PARAMS_INTENSITY` |
| `radius` | `+0x2e8` | `VAR_SPOT_PARAMS_RADIUS` (`× 0.99`) |
| `innercone`/`outercone` | `+0x2f0`/`+0x2f4` | `..._INNER`/`..._OUTER` (`cosf(deg·π/180)`) |
| `density` | `+0x2f8` | `VAR_DENSITY` |
| `volumetricsexponent` | `+0x2fc` | `VAR_EXPONENT` |

여기에 파생 필드 둘(`[light+0x310]` 셰도우맵 변환 · `[light+0x320]` 스팟 forward — 후자가
`angles` 유래)이 더해진다. 게이트는 `castvolumetrics`(`+0x2c4` bit2).

⚠️ **`exponent`(`+0x2ec`)는 볼류메트릭에 안 쓰인다.** 그건 일반 PBR 라이팅의 감쇠 지수고
(`ComputePBRLightShadow` 의 `exponent`), 볼류메트릭은 `volumetricsexponent`(`+0x2fc`)를 쓴다.
§2.3 유니폼 팩 전 구간에 `[rsi+0x2ec]` 적재가 **한 번도 없다**. 형제 키에 속기 쉬운 자리다
(공통 브리프 함정 #8).

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

### 4.4 남은 배선 (이번 담당 파일 밖)

1. ~~**`radius` 배선**~~ — **[2026-08-21 완료]** `SceneRenderer3D.swift:1934` 가
   `radius: light.radius` 를 넘긴다. `VolumetricLightParameters.radius` 의 기본값 0 이
   남아 있는 것은 이제 **씬이 `radius` 를 저작하지 않은 경우**뿐이고(파스가 `?? 0`,
   `SceneDocument.swift:1916`), 그때 패스는 WE 라이트 생성자 기본 반경 1.0
   (`0x140190494`)으로 마치한다 — 헐 0.99 라 **사실상 비가시**이고, 그게 WE 가 무저작
   반경에 대해 하는 일 그대로다. `encode` 가 1회 경고를 남긴다.
   그 퇴화가 그냥 어두운 것으로 끝나지 않는다는 실측은 §6.1 에 있다.
2. **씬 뎁스 클립(W-17 잔여).** `SceneRenderer3D.swift:1466` 의 `pooledDepth` 는
   `usage=[.renderTarget]` · `storeAction=.dontCare` 라 샘플할 수 없다. `.shaderRead` 를 주고
   저장한 뒤 `encode` 에 넘기면 `_rt_volumetricsSingle` 과 같은 역할을 해서 샤프트가
   지오메트리에 가려진다. 그전까지는 통과한다. 설계 전문은 **§7.2**.

3. 🔴 **콘 코사인이 반으로 좁다 — 한 줄 패치.** `SceneRenderer3D.swift:1918` 이

   ```swift
   let cone = SceneLight3D.forwardSpotConeCosines(inner: light.innerCone, outer: light.outerCone)
   ```

   를 쓰는데 그 2D 포트는 아직 `toHalfRadians = π/180 * 0.5`(`SceneDocument.swift:962`)를 곱한다.
   WE 는 deg2rad 만 곱한다(§2.3 실측: 볼류메트릭 `0x14019872c`/`0x140198740`, V1 PBR
   `0x140192e6d`/`0x140192eb3`). 같은 모듈에 정본이 있으므로 **호출부 한 줄**이면 닫힌다:

   ```swift
   let cone = Scene3DLighting.spotConeCosines(inner: light.innerCone, outer: light.outerCone)
   ```

   더 근본적인 수선은 `SceneDocument.forwardSpotConeCosines:962` 의 `* 0.5` 제거인데, 그건 2D
   포워드 라이팅 전체를 함께 바꾸므로 그 레인이 판단할 일이다(그 경우
   `SceneForwardLightKindTests.testSpotConeHalfAngleCosines` 와
   `VolumetricLightTests` 의 `cos5°/cos15°` 기대값 두 곳이 `cos10°/cos30°` 로 함께 간다).
   **두 파일 다 이번 담당 밖이라 손대지 않았다.**

또한 `Tests/WapleRenderTests/VolumetricLightTests.swift` 의
`testVolumetricLightDirectionUsesForwardConverterNotRawEulerAngles` 는 종전에 **`density: 0` ·
`radius` 무저작** 씬으로 중앙 픽셀 밝기를 단언했다. 옛 모델에서 `exp(-0 × d × 0.001) = 1` 이라
통과하던 픽스처인데, 실물에서 `density` 는 순수 배수라 0 이면 **WE 도 아무것도 안 그린다**(§1.5).
지금 픽스처는 `density 3` · `radius 20` 이고, 그 값의 근거와 예측 픽셀값은 §6.1–§6.2 다.

> **[2026-08-21 정정]** 이 자리에 "중앙 rgb = `density × 0.3333`" 표가 있었다. **그 표는
> 광축(ndc = 0) 레이를 푼 값이라 실제 픽셀과 다르다** — 어떤 화면 해상도에도 광축 위에 앉는
> 픽셀은 없다. 같은 픽스처의 실제 중앙 픽셀은 `density × 0.0751`(radius 무저작) ·
> `density × 0.1687`(radius 20)이다. 그 표를 믿고 검산한 것이 §6.1 의 "4.5배" 소동이다.

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
| (신규) QUALITY 출처 | 없음 | 앱 설정 바이트 `[ctx+0x1ad]` — 씬 키 아님. **샘플 수 저작 키는 존재하지 않는다**(§7.4) |
| (신규) POINTLIGHT 조건 | 없음 | `[light+0x2c0] == 0` ⟺ `light == "lpoint"` (`0x1401982fa`) |

### 5.1 `scene-postprocessing.md` §7 의 W-18·W-19 행은 **이미 낡았다** `[인계]`

그 문서 `:598`–`:600` 의 "Waple" 열은 `VolumetricLightPass.swift:162,169,177` 에서
`exp(−density·dist·0.001)` · 선형 콘 램프를 인용한다. 그건 **`7c66d46` 이전**의 코드다.
현행 트리에서 두 수식은 이미 실물이고(`VolumetricLightPass.swift` 의 `metalSource`
`pow(saturate(1.0 - dist * u.lightCone.z), u.lightParams.y)` ·
`smoothstep(u.lightCone.x, u.lightParams.w, cosAngle)`), 인용된 줄 번호에는 그 코드가 없다.
그 문서는 이번 담당 밖이라 고치지 않았다 — 제안하는 정정:

| 행 | 지금 | 이렇게 |
| --- | --- | --- |
| W-18 | **확정**(갭) | ~~확정~~ → **해소 `7c66d46`** · Waple 열을 `smoothstep(outer, inner, cos)` 로 |
| W-19 | **확정**(갭) | ~~확정~~ → **해소 `7c66d46`** · Waple 열을 `pow(saturate(1−d/(radius·0.99)), volumetricsexponent)` 로 |
| W-17 | **확정**(구조 차이) | 유지하되 Waple 열을 "8샘플 레이마치 1패스 + 구 교차 해석해, 씬 뎁스 클립 없음" 으로. "12~64샘플" 은 셰도우/쿠키 가지 전용(`:78-86`), 그 외는 2~8(`:88-96`) |

**남은 진짜 갭은 W-17 셋 중 씬 뎁스 클립 하나**이고, 거기에 이 문서가 새로 더하는 것이
🔴 콘 반각(§4.4-3)이다 — 그건 §7 표에 아직 없는 항목이다.

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

### 6.1 "CPU 1.0 vs Metal 0.2235, 4.5배" — 전말 (2026-08-21)

macOS CI 가 아래를 보고했다.

- 픽스처: 카메라 `(0,0,10)` → 원점 · `fov 50` · 64×64. 라이트 `origin "0 0 0"` · `angles "0 0 0"` ·
  `intensity 6` · `innercone 10` · `outercone 30` · `density 3` · `volumetricsexponent 1` ·
  **`radius` 키 없음**(→ 헐 `0.99`).
- 같은 픽스처를 CPU 순수 산술로 풀면 **1.0**(보고는 "포화" 라고 했지만 실은 포화가 아니라 **정확히** 1.0 이다 — 아래 표).
- 실제 Metal 렌더의 중앙 픽셀은 **0.2235**(= 57/255). 약 **4.5배** 차.

**두 구현이 갈린 것이 아니다. 레이가 갈렸다.** 검산 쪽이 **광축(ndc = 0) 레이**를 풀었고
셰이더는 **픽셀 중심 레이**를 푼다. 64×64 의 "중앙" 픽셀 (32,32) 의 NDC 는 `(0,0)` 이 아니라
`(+1/64, −1/64) = (±0.015625)` 다 — **어떤 짝수 해상도에도 광축 위에 앉는 픽셀은 없다.**

그 반 픽셀이 왜 4.4배가 되는가:

| 단계 | 광축 레이(ndc=0) | 픽셀 중심 레이(ndc=±0.015625) |
| --- | ---: | ---: |
| 레이와 라이트의 최근접 거리 | `0` | **`0.10304`** |
| 구 교차 구간 `segment` | `1.980000` | `1.969247` (×0.99457) |
| `maxLightScale` | `12.000000` | `11.934833` |
| 샘플 8개의 `spotCookie` | `1,1,1,1,0,0,0,0` | **`0.9566, 0.6710, 0, 0, 0,0,0,0`** |
| `shadowFactor / N` | `0.277778` | **`0.062960`** (×0.22665) |
| 최종 `rgb` | **`1.000000`** | **`0.225425`** |

지배항은 `spotCookie` 다. 헐이 `0.99` 뿐이라 8 샘플이 라이트에서 `0.150`–`0.773` 밖에 안 떨어져
앉는데, 그 거리에서 옆으로 `0.103` 비끼면 각도가 콘 반각 15° 를 넘어간다 — 3번째 샘플의
`cos` 가 `0.9571` 로 `cos15° = 0.96593` **아래**로 내려가 `smoothstep` 이 0 을 준다.
`1.000000 / 0.225425 = 4.4361` 이 곧 보고된 "4.5배" 다.

**0.225425 가 관측치와 맞는지도 끝까지 따라간다.** 목적지가 `bgra8Unorm`(비-sRGB) 이므로
`round(0.225425 × 255) = 57`, 캡처 PNG 는 `OffscreenCapture.png` 가 `.deviceRGB` 로 **원바이트를
그대로** 싣고(감마 인코딩 없음), `NSBitmapImageRep.colorAt` 이 `57/255 = 0.223529` 를 돌려준다.
**관측치 0.2235 와 정확히 같다.** 즉 셰이더는 처음부터 맞는 값을 냈다.

같은 계산을 배선된 `radius 20`(헐 `19.8`)로 돌리면 중앙 `0.506209`(바이트 129) · 코너 (2,2)
`0.047063`(바이트 12)이고, 이건 §4.4 각주가 이미 인용하던 수와 같다 — 즉 `radius` 가 도달한
경로에서는 검산과 렌더가 이미 맞아 있었다. 4.5배는 **헐이 `0.99` 로 퇴화한 픽스처에서만** 터진다.

### 6.2 같은 식을 두 번 적은 자리 — 전수 대조표

`metalSource`(MSL 문자열)와 `VolumetricMath`(CPU) 가 같은 식을 두 벌 갖는 자리를 전부 세웠다.
"갈릴 수 있나" 는 **값이 실제로 달라질 수 있는가**다.

| # | 식 | `volumetricsfront.frag` | `metalSource`(MSL) | `VolumetricMath`(CPU) | 갈릴 수 있나 |
| ---: | --- | --- | --- | --- | --- |
| 1 | 픽셀 → NDC | `:60-61` (`v_ScreenPos.xyz / .w`) | `volumetricVertex` uv → `ndc` | **종전 없음** → `pixelNDC` 신설 | **여기서 갈렸다(§6.1)** |
| 2 | 뷰 레이 재구성 | `:105-111` (`mul(·, g_EffectModelMatrix)` 역투영) | `normalize(fwd + right·(ndc.x·tanHalf·aspect) + up·(ndc.y·tanHalf))` | **종전 없음** → `viewRayDirection` 신설 | **여기서 갈렸다(§6.1)** |
| 3 | 헐 입·출구 | `:63-74` 뎁스 2패스 | 구 교차 축약형(`a = dot(d,d) = 1` 가정) | **종전 없음** → `hullSpan` 신설 | 방향 미정규화면 조용히 틀림 — 주석에 가정 명시 |
| 4 | `tEnter`/`tExit` 클램프 | FULLSCREEN 근평면 / `min(back, limit)` | `max(-b-sq, near)` / `min(-b+sq, far)` | `hullSpan` | 근평면을 **레이 길이**로 잰다(`near/cosθ` 아님) — 두 벌은 같고 WE 와만 다른 근사다. `radius 20` 픽스처(근평면 클램프가 실제로 걸리는 쪽)에서 오차 `5.3e-6` |
| 5 | `worldStep` 의 `(N+1)` 분모 | `:113` | `segment / (N + 1.0)` | `marchMeanFactor`(+ 해석식 `samplePosition`) | 일치 |
| 6 | 샘플 순서(`p += step` 후 샘플) | `:130` | 더한 뒤 샘플 | **누산으로 통일**(닫힌 꼴 아님) | 일치. 닫힌 꼴로 적으면 반올림 누적이 달라져 비트 대조 불가 |
| 7 | `shadowFactor /= N` | `:187` | `*= marchParams.y` (= `1/N`) | `* (1 / Float(N))` | 일치(`N+1` 아님 — 나눌 때만 `N`) |
| 8 | `maxLightScale` | `:115-122` | `intensity · seg · lightCone.z · lightCone.w` | `maxLightScale(...)` — **나눗셈이었다 → 역수 곱으로 정렬** | 정렬 전 ulp 차 |
| 9 | 반경 감쇠 | `:132` | `pow(saturate(1 − d·invHull), E)` | `radialFalloff` — **나눗셈이었다 → 역수 곱으로 정렬** | 정렬 전 ulp 차 |
| 10 | 지수 클램프 | 없음(WE 는 안 한다) | `encode` 가 `max(0, exponent)` 로 **업로드 전** 클램프 | **`radialFalloff` 엔 없었다** → `marchMeanFactor` 에 추가 | **음수 지수에서 갈렸다**: CPU 는 `powf(base, −1)` 을 실제로 계산하고, GPU 는 `encode` 의 클램프 때문에 `pow(base, 0) = 1` 만 본다. 저작값은 무클램프 파스(`SceneDocument.swift:1919`)라 도달 가능한 입력이다 |
| 11 | 콘 `smoothstep` | `:139-140` | `smoothstep(lightCone.x, lightParams.w, cos)` | `coneFalloff` | 일치. 퇴화(`inner == outer`)만 규약이 다르다(MSL 은 0 나눗셈) — 호출부가 `+1e-4` 로 벌려 도달 불가(`SceneDocument.swift:739`) |
| 12 | `normalize(lightDelta)` | `:139` | `lightDelta / max(dist, 1e-6)` | 같은 **나눗셈** 형태 | 일치 |
| 13 | POINTLIGHT 게이트 | `#if POINTLIGHT` | `lightDirection.w < 0.5` | `PixelInput.isPoint` = `VolumetricLightParameters.isPointLight` (`outer ≤ −0.999`) | 일치(판정 단일 소스) |
| 14 | POINTLIGHT `×0.5` | `:119` vs `:121` | `lightCone.w` | `pointLightScale` | 일치 |
| 15 | 헐 반경 `radius × 0.99` | `vert:13` + `0x140198760` | `encode` 가 유니폼에 굽는다 | `hullRadius(radius:)` — **같은 함수** | 단일 소스 |
| 16 | 최종 `× 0.1` | `:190` | 마지막 곱 | `finalScale` | 일치 |
| 17 | 유니폼 팩 순서 | — | `lightParams`(x=density y=exp z=intensity w=inner) · `lightCone`(x=outer y=hull z=1/hull w=pointScale) · `marchParams`(x=N y=1/N) | `PixelInput` 필드명을 같은 이름으로 맞춤 | 슬롯별 대조 결과 **전부 일치**. 구조체 크기도 11×`float4` = 176B 로 동일 |

### 6.3 배제한 가설

출력 경로도 끝까지 봤고, 아래는 전부 **아니다**.

| 가설 | 배제 근거 |
| --- | --- |
| sRGB/감마 인코딩 | 파이프라인 포맷이 `bgra8Unorm`(**`_srgb` 변종 아님**, `VolumetricLightPass.swift` 의 `makeDescriptor`), `writeFramePNG` 는 `getBytes` 원바이트 → `OffscreenCapture.png` 가 `.deviceRGB` 로 그대로 싣는다. 변환 지점이 존재하지 않는다 |
| 감마 × 다른 인자의 곱 | 위와 같은 이유로 감마 인자 자체가 0개. 그리고 픽셀 예측이 감마 없이 **바이트 단위로 맞는다**(57) |
| 목적지가 `rgba16Float`(HDR 경로) | 픽스처에 `hdr` 없음 → `hdrActive == false` → `accPixelFormat == .bgra8Unorm` |
| `finalizeScene` 후처리(톤맵/블룸) | 이 씬은 `sceneWantsLDRBloom == false` 라 `source === destination` → `finalizeScene` 이 `return true` 로 즉시 빠진다(무연산) |
| additive 블렌드가 값을 바꿈 | `clearcolor "0 0 0"` 위에 `one/one` 이라 더할 배경이 0. 알파는 프래그가 `a = 1` 을 쓰므로 255 → `colorAt` 의 언프리멀티플이 무영향 |
| uv y-flip / 픽셀 인덱싱 | (32,32)·(31,31)·(31,32) 예측이 모두 같은 값(대칭). 정점 셰이더의 `ndc == 보간된 clip.xy` 임을 대수로 확인 |
| 유니폼 스트라이드/필드 어긋남 | 표 §6.2 #17 — 슬롯 전수 대조 일치 |
| `shadowFactor` 를 `N` 대신 `(N+1)` 로 나눔 | 그러면 `0.200378`(바이트 51)이다. 관측 `0.2235`(57)와 다르다 — **값으로** 배제 |
| 샘플 순서(더하기 전에 샘플) | **이 픽스처로는 못 가른다** — 값이 `0.225425` 로 같다. 버려지는 첫 샘플이 헐 표면(감쇠 정확히 0)에 앉고 늘어나는 마지막 샘플은 라이트 뒤(콘 0)라 둘 다 기여가 0 이기 때문이다. 셰이더 평문(`:130` 이 더한 뒤 샘플)과 MSL 이 같다는 **독법**으로만 배제된다 |
| `pow` base/exponent 규약(`pow(0,0)`) | 이 픽스처는 `E = 1` 이라 도달하지 않는다(규약 자체는 §6.2 #10 에서 정렬) |

### 6.4 보강한 것

1. **`VolumetricMath` 가 이제 프래그먼트 전체를 덮는다.** `pixelNDC` · `viewRayDirection` ·
   `hullSpan` · `marchMeanFactor` · `pixelValue`(+ `dot3`/`length3`/`normalize3`)를 더했다.
   종전엔 감쇠 항만 있어서 **호출자가 레이 재구성을 직접 다시 적어야 했고**, 그게 §6.1 사고의
   물리적 원인이다. `import Foundation` 하나로 서는 성질은 유지했다(`SIMD3<Float>` 는
   표준 라이브러리 타입이고 `simd` 모듈이 아니다) — 위 추출 절차가 그대로 성립한다.
2. **리눅스에서 값이 고정된다.** 추출 실행 결과(2026-08-21, Swift 6.0.3 on Linux):

   ```
   radius=0.0  hull=0.9900  center(32,32)=0.225425  byte=57   corner(2,2)=0.000000  onAxis=1.000000  ratio=4.4361
   radius=20.0 hull=19.8000 center(32,32)=0.506209  byte=129  corner(2,2)=0.047063  onAxis=0.506250  ratio=1.0001
   ndc(32,32,64,64) = (0.015625, -0.015625)
   ndc(0,0,1,1)     = (0.0, 0.0)
   ```

   `pixelNDC(x:0, y:0, width:1, height:1)` 이 정확히 `(0,0)` 이므로 **광축 레이도 같은 API 로**
   표현된다 — "1×1 로 부르면 광축" 이 §6.1 의 두 수를 한 함수 안에서 나란히 보게 해 준다.
3. **테스트 두 겹.** `Tests/WapleRenderTests/VolumetricLightTests.swift` 에
   `testVolumetricMathMirrorsShaderForFixturePixel` 을 새로 뒀다 — GPU 없이 위 값 전부와
   변환기 두 개(`forwardLightAxis` → `(0,0,1)`, `forwardSpotConeCosines(10,30)` → `cos5°/cos15°`)를
   못 박는다. 그리고 기존 Metal 테스트의 단언을 **대비 비교에서 CPU 미러와의 절대 대조로**
   올렸다(`accuracy: 0.02` ≈ 5/255 — 양자화와 GPU 초월함수 오차는 덮고 4.4배 발산은 잡는 폭).
   대비 단언 두 개는 그대로 둔다(방향/콘 변환기 회귀를 그쪽이 잡는다). 기대치를 변환기로
   만들지 않고 **의도한 값**(`(0,0,1)`, `cos5°/cos15°`)에서 만든 이유는, 변환기가 회귀하면
   기대치까지 같이 움직여 단언이 무력해지기 때문이다.

**고치지 않은 것.** `metalSource` 의 픽셀 수식은 한 줄도 안 바꿨다 — `volumetricsfront.frag`
대조에서 틀린 곳이 없었고(§6.2), 관측 픽셀이 CPU 예측과 바이트 단위로 맞았다.
`VolumetricMath` 쪽에서 바꾼 것은 **GPU 와 같은 순서로 적기 위한 정렬 세 곳**뿐이다
(§6.2 #8·#9 역수 곱, #10 지수 클램프). 값이 눈에 띄게 달라지는 변경은 없다.

---

## 7. W-17 (깊이 기반 5패스) — 설계안과 A/B 절차 `[미구현·검증 불가]`

**이 컨테이너에서는 구현하지 않는다.** 리눅스에 Metal 이 없어 파이프라인·RT·컬링을 한 줄도
실행 검증할 수 없고, W-17 은 RT 세 장 + 파이프라인 넷을 새로 짓는 구조 변경이다. 검증 없는
구조 변경은 이 리포가 이미 두 번 당한 실패형(macOS CI 파손)이라 설계안만 남긴다.

### 7.1 지금 무엇이 실제로 비어 있나

§4.2 표에서 "동일" 이 아닌 행은 셋뿐이고, **화면에 보이는 결함은 하나**다.

| 구멍 | 화면 증상 | 난이도 |
| --- | --- | --- |
| **씬 뎁스 클립 없음** (`min(backDepth, limitDepth)`) | 샤프트가 오브젝트를 **통과해** 비친다 | 작다 — 기존 뎁스 텍스처 재사용 |
| 라이트버퍼 다운스케일 + blur3 h/v 없음 | 없음(WE 도 Q≥3 에선 안 한다, `0x140198d21`) | 중간 |
| 헐 뎁스 2패스 → 구 교차 해석해 | 스팟 콘 헐을 구로 감싼 만큼 **콘 밖 샘플을 헛돈다**(값은 0) | 크다 |

### 7.2 단계 1 — 씬 뎁스 클립 (권장, 유일하게 화면을 고친다)

WE 대응: `volumetricsfront.frag:64` `limitDepth = texLoad2D(g_Texture3, ...)` +
`:71` `backDepth = min(backDepth, limitDepth)`(비-REVERSEDEPTH 레인).

Waple 이식 형태 — **패스를 늘리지 않는다.** 구 교차의 `tExit` 을 씬 뎁스로 한 번 더 자른다.

1. `SceneRenderer3D` 의 3D 뎁스 텍스처를 샘플 가능하게 만든다.
   현재 `SceneRenderer3D.swift:1466` 의 pooled depth 는 `usage=[.renderTarget]` ·
   `storeAction=.dontCare` 다. `usage=[.renderTarget, .shaderRead]` · `storeAction=.store` 로
   바꾸고 `encode3D` 가 그 텍스처를 `VolumetricLightPass.encode` 에 넘긴다.
   (포맷은 현행 그대로. `depth32Float` 이면 `texture2d<float>` 로 읽는다.)
2. `metalSource` 의 프래그먼트에 슬롯을 하나 더 준다 —
   `texture2d<float> sceneDepth [[texture(0)]]`, `constant` 유니폼에 `invProj`(또는
   near/far 두 값)를 실어 **깊이 → 뷰 공간 거리**로 되돌린다. 그 값이 `limitDepth` 다.
3. `tExit = min(tExit, sceneDepthDistance)` 한 줄. `tExit <= tEnter` 면 종전대로 0 반환.
4. CPU 미러 `VolumetricMath.PixelInput` 에 `sceneDepth: Float?` 를 더하고
   `hullSpan` 의 `exit` 에 같은 `min` 을 건다 — 두 벌이 갈리지 않게(§6.2 규약).

**주의 셋.**
- 뎁스 텍스처는 `SceneRenderer3D.swift` 소관이라 이 레인이 못 만든다 — 인계 항목이다(§4.4).
- MSL 은 `stage_in`·정점 반환 구조체에 **행렬 멤버를 금지한다**. `invProj` 를 정점 출력으로
  흘리지 말고 프래그먼트 `constant` 버퍼로만 넘겨라(이 리포가 실제로 당했다).
- 뎁스를 `.store` 로 바꾸면 타일 메모리 절약이 사라진다. 볼류메트릭 씬(코퍼스 도달 0건)에서만
  켜지도록 `volumetricLightPass != nil` 로 게이트하는 것이 맞다.

### 7.3 단계 2 — 라이트버퍼 + blur3 + combine (구조 패리티, 화면 이득 없음)

| 패스 | 목적지 | 포맷 | 해상도 | 게이트 |
| --- | --- | --- | --- | --- |
| march | `lightBuffer` | HDR 씬 `rgba16Float`, 아니면 `bgra8Unorm` | `1/divisor` | 항상 |
| `blur_k3` h | `lightBufferB` | 같음 | 같음 | `QUALITY < 3` |
| `blur_k3` v | `lightBuffer` | 같음 | 같음 | `QUALITY < 3` |
| combine(additive) | 씬 컬러 | — | 풀 | 항상 |

- `divisor` = `VolumetricMath.lightBufferDivisor(quality:)` (Q≥3 → 4, else 8) — 실측 `0x140196d79`.
- `blur` 여부 = `VolumetricMath.blursLightBuffer(quality:)` (Q<3) — 실측 `0x140196ea0`·`0x140198d21`.
- 커널 = `VolumetricMath.blur3Weights` `[0.25, 0.5, 0.25]`.
- 라이트버퍼는 **프레임당 한 번만 클리어**하고 라이트마다 additive 누적(`0x14019791b`).
  현행 Waple 은 목적지에 직접 additive 라 이 클리어 규약이 이미 등가다.
- `Back` 만 풀해상도인 것은 뎁스 정합 때문(§2.2). 단계 2 에는 뎁스 RT 가 없으므로 무관.

**Waple 의 `qualityTier` 는 4 고정**(`VolumetricLightPass.qualityTier`)이라 단계 2 를 넣어도
blur 가지는 죽은 코드가 된다. 넣을 이유는 "저해상도 옵션이 생겼을 때" 뿐이다.

### 7.4 샘플 수의 **저작 키 대응 — 없다**

브리프 질문에 대한 확정 답이다. `QUALITY` 는 **앱 설정 바이트** `[mat+0x1ad]`(`0x140198273`)이고
scene.json 키가 아니다. 저작자가 볼류메트릭 샘플 수를 지정하는 키는 WE 에 **존재하지 않는다** —
등록 테이블 18키(§2.5) 어디에도 없다. `LIGHTS_SHADOW_MAPPING_QUALITY` 는 이웃 바이트
`[mat+0x1ac]`(`0x1401983af`)로 역시 앱 설정이다.

| Waple `qualityTier` | 셰도우 미바인딩 샘플 수 | 셰도우/쿠키 가지 |
| ---: | ---: | ---: |
| 1 | 2 | 12 |
| 2 | 3 | 24 |
| 3 | 5 | 32 |
| **4 (현행 고정)** | **8** | 64 |

### 7.5 A/B 절차 (macOS 세션에서만 가능)

1. **한 세션 안에서** before/after 캡처를 둘 다 뜬다 — 세션 간 캡처 비결정 29종
   (`spec/golden/nondeterminism.json`)이 판독을 막는다. BACKLOG 의 반복 실패형이다.
2. 픽스처: `Tests/WapleRenderTests/VolumetricLightTests.swift` 의
   `testVolumetricLightDirectionUsesForwardConverterNotRawEulerAngles` 씬에 **불투명 메시 하나**를
   라이트와 카메라 사이에 놓는다(현행 픽스처는 `models/missing.mdl` 이라 가려질 것이 없다).
   단계 1 이 붙기 전에는 그 메시 뒤에서도 샤프트가 보이고, 붙은 뒤에는 사라져야 한다.
3. 수치 대조는 CPU 미러로 한다 — `VolumetricMath.pixelValue` 에 `sceneDepth` 를 먹인 값과
   실렌더 픽셀을 `accuracy: 0.02`(≈5/255)로 맞댄다. 대비 단언만으로는 몇 배 발산이 통과한다(§6.1).
4. 골든: `castvolumetrics` 도달이 동봉 172 · 설치본 186 에서 **0건**이라(§3.1)
   `spec/golden/snapshot` 170종은 **한 장도 안 바뀐다**. 그래도 `golden-gate.sh` 를 돌려
   "0종 상이" 를 확인하는 것이 A/B 의 마지막 칸이다 — 안 바뀌어야 하는데 바뀌면 게이트가
   아니라 이식이 틀린 것이다.
5. 되돌리기: 단계 1 은 `tExit` 한 줄 + 텍스처 usage 두 플래그라 되돌리기가 싸다.
   단계 2 는 RT 두 장 + 파이프라인 셋이라 별도 커밋으로 분리한다.

---

## 8. 남은 미확정

- `_rt_volumetricsSingle` 을 **무엇이 채우는지**는 셰이더 쪽 용법(`texLoad2D` 로 `limitDepth`,
  `min(backDepth, limitDepth)`)과 할당 스펙(뎁스 전용 · 라이트버퍼와 같은 해상도)까지가 확정이고,
  씬 깊이를 그 해상도로 내려 담는 지점의 VA 는 특정하지 않았다. 소비 규약이 확정이라 이식에는
  영향이 없다.
- `sub_1401aadb0` 의 8·9번째 인자(`Back` 은 `(bit<<25)|8` / `bit<<5`, 나머지는 `8`·`0xa`·`0`)는
  플래그로 보이나 의미 미확정. 스케일·포맷과 무관하다.
- `[this+0x418]` 비트 1/2 의 정확한 수명(활성 플래그 · 프레임당 클리어 래치)은 관측된 사용처
  (`0x140196cf5` 게이트 · `0x14019791b` 클리어 · `0x140198d06` 리졸브 진입)까지만 확정.
