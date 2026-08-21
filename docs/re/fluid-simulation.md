# 유체 시뮬레이션 이펙트(`effects/fluidsimulation`) 완전 해부

**측정일 2026-08-21 · WE 2.8.42 · `wallpaper64.exe`(imagebase `0x140000000`)**

동봉 이펙트 46종(최상위 `effect.json` 기준) 중 **가장 복잡한 하나**를 끝까지 뜯는다.
이 이펙트만 가진 것이 셋이다 —

* **동봉 `effect.json` 128건 중 유일하게 `functions` 를 갖는다**(전수 실측, preview 사본에도 없다).
* **`conditions` 를 갖는 유일한 이펙트**다(본체 4건 + preview 사본 4건 = 8건이 코퍼스 전부).
* **`unique` FBO 8~9장 + `command:"swap"` 2회**로 프레임을 넘겨 상태를 누적하는 유일한 이펙트다
  (motionblur 가 `unique` 1장으로 두 번째다).

목적은 하나다: **Waple 의 이펙트 파이프라인이 오늘 이걸 돌릴 수 있는가.** 결론은 §6.

이웃 문서와의 경계 — 콤보/`#require`/`conditions` **문법**은 `docs/re/shader-combos.md`,
엔진 유니폼 140종의 census 는 `docs/re/shader-uniforms.md`, 블렌드 상태는
`docs/re/material-blend.md`, 스크립트 API 표면은 `docs/re/scene-script-api.md` 가 정본이다.
이 문서는 **이 이펙트 하나의 실물 수식과 자원 흐름**만 다루고, 그 문서들의 규약은 인용만 한다.

재현 절차는 부록 A, 인용한 함수 범위는 부록 B.

---

## 0. 다섯 줄 요약

1. **패스 20개(드로우 18 + `swap` 2), FBO 9장.** 압력 Jacobi 는 **9회**이고 매니페스트에
   같은 패스가 9번 복제돼 있다. 핑퐁은 완전 무충돌이다 — 18개 드로우 패스 어디에도
   읽는 텍스처와 쓰는 텍스처가 겹치는 자리가 없다.
2. **`fit` 은 정사각이 아니다.** `0x1401eb2f8`–`0x1401eb37b` 이 **긴 변을 N 에 맞추고 종횡비를
   보존하며 확대는 하지 않는다**. 즉 1920×1080 레이어에서 `fit:256` 은 **256×144** 다.
   Waple 은 `fit` 을 N×N 정사각으로 읽는다(`EffectManifest.swift:400`) — 그래서 속도장 텍셀이
   화면에서 정사각이 아니게 되고, `aspect = g_Texture0Resolution.y/.x` 가 0.5625 대신 **1.0**
   이 된다. 이 하나가 이 이펙트에서 가장 큰 그림 차이다(§6-W1).
3. **`functions` 는 죽은 코드도 에디터 UI 도 아니다** — 씬 스크립트 API
   `IEffect.executeMaterialFunction(name)` 의 대상 테이블이고, 그 선언은 WE 가 배포하는
   `ui/dist/monaco/autocomplete/lib.sceneScript.d.ts:1295` 에 공개돼 있다. **워크샵 저작자용**이다.
   설치본 전수에서 이걸 **호출하는 자산은 0건**이다(비-바이너리 히트는 그 `.d.ts` 선언 한 줄뿐).
4. **원본 결함 확정** — 소비 루프(`0x1401ee440`–`0x1401ee4fe`)가 파스된 FBO 인덱스 **값을 읽지
   않고 개수만 쓴다**. 그래서 `clearDye`(인덱스 `[6,7]`, 개수 2)는 염료가 아니라 **속도장
   `fbos[0..1]` 을 비운다**. 그림으로는 "연기가 사라진다" 가 아니라 **"흐름이 멎고 연기가
   그 자리에 얼어붙는다"** 가 된다(§4.3). `clearVelocity` 는 인덱스가 우연히 `[0,1]` 이라 맞는다.
5. **Waple 은 이 이펙트를 오늘 로드하면 대체로 돈다.** 매니페스트 축(포맷·`unique`·`clear`·
   `swap`·`conditions`·`functions`·씬 오버라이드 인덱스)은 전부 이미 실물 규약이다. 남은 결손은
   **① `fit` 종횡비(위 2) ② `LIGHTING=1` 에서 `#require LightingV1` 미주입 → 이펙트 통째 폴백
   ③ `g_EffectTextureProjectionMatrixInverse` 항등(회전/부분 레이어에서 커서 임펄스 어긋남)**
   셋이다. ①만 그림이 조용히 틀리고, ②는 시끄럽게 폴백한다.

---

## 1. 매니페스트 전문 전개

### 1.1 파일 성질

| 항목 | 값 |
|---|---|
| 경로(동봉) | `Sources/WapleRender/Resources/WEAssets/effects/fluidsimulation/effect.json` |
| 설치본과 | `diff -rq` **0건**(트리 전체 바이트 동일) |
| 크기 | 8,283 B · 최상위 키 12개 |
| **엄격 JSON** | **실패** — `dependencies` 배열 끝에 트레일링 콤마. 동봉 `effect.json` 128건 중 27건이 엄격 파스 실패고, 최상위(비-preview) 실패는 **이 파일 하나**다 |
| `replacementkey` | `fluidsimulation` (디렉터리명과 같다) |
| `group` / `performance` | `interactive` / `veryexpensive` |
| `preview` | `preview/project.json` |

**preview 사본은 본체와 다른(더 오래된) 스냅샷이다.** 이걸 본체로 착각하면 결론이 통째로 뒤집힌다:

| 파일 | 본체 | `preview/` 사본 |
|---|---|---|
| `effect.json` | `functions` **있음** | **없음** (그 외 전부 동일) |
| `..._combine.frag` | `#include "common_pbr_2.h"` + **`#require LightingV1`** + `PerformLighting_V1(...)` | `#include "common_pbr.h"` + `uniform vec4 g_LightsColorPremultiplied[3]` + `ComputePBRLight(...)` ×4 언롤 |
| `..._combine.vert` | `g_LightsPosition` **전 5줄 주석 처리**, `varying vec3 v_WorldPos` | `uniform vec3 g_LightsPosition[4]` **활성**, `v_Light{0,1,2}Direction*` varying |
| `..._vorticity.frag` | `// [COMBO] INTERACTIVE` + 커서 블록이 `#if INTERACTIVE` 로 감싸짐 + `attachmentproject`/`attachmentangles` 어노테이션 | 콤보 없음, 커서 블록 무조건, 어노테이션 없음 |

> **`docs/re/shader-uniforms.md:821-822` 정정 필요.** 그 표는 `g_LightsPosition`(순위 2)과
> `g_LightsColorPremultiplied`(순위 3)의 저작레인 도달처를 "`fluidsimulation` **이펙트 본체**
> (preview 아님)" 라고 적었는데 **반대**다. 실측(설치본 전수 grep):
> `g_LightsPosition` 5줄은 본체 `..._combine.vert:22,42,43,44,45` **전부 `//` 안**이고,
> 활성 참조는 `preview/shaders/.../fluidsimulation_combine.vert:25,44,45,46,47` 뿐이다.
> `g_LightsColorPremultiplied` 도 본체 `.frag` 에는 **0회**, preview 사본에만 5회다.
> 실제로 본체가 `LIGHTING=1` 에서 쓰는 라이트 유니폼은 `#require LightingV1` 이 생성하는
> **`g_LPoint_*`/`g_LSpot_*`/`g_LTube_*`/`g_LDirectional_*`/`g_LFeature_Shadow*` 계열**이다
> (`docs/re/shader-combos.md` §3.5). 이름 축이 통째로 다르다.

### 1.2 FBO 9장 — 전개표

원본 레코드는 **stride `0x50`**, 필드 배치는 파서(`0x1401e7440`–`0x1401e7969`)에서 직접 읽었다:
`+0x08` 포맷 enum · `+0x0c` scale(byte) · `+0x0e` width(u16) · `+0x10` height(u16) ·
`+0x12` **fit**(u16) · `+0x14…+0x20` clear RGBA(float×4) · `+0x28` 이름(std::string) ·
`+0x48` 플래그(**bit0=unique**, **bit1=clear**, **bit2=uvs repeat**). 미선언 정수는 `0xffff`.

| # | 이름 | 크기 지정 | `format` | Metal 등가 | `clear` | `unique` | `conditions` | 역할 |
|---:|---|---|---|---|---|---|---|---|
| 0 | `_rt_SmokeVelocity1` | `fit:256` | `rg1616f` | `.rg16Float` | `"0 0 0 0"` | ✔ | — | 속도장 A |
| 1 | `_rt_SmokeVelocity2` | `fit:256` | `rg1616f` | `.rg16Float` | `"0 0 0 0"` | ✔ | — | 속도장 B |
| 2 | `_rt_SmokePressure1` | `fit:256` | `r16f` | `.r16Float` | `"0 0 0 0"` | ✔ | — | 압력 A |
| 3 | `_rt_SmokePressure2` | `fit:256` | `r16f` | `.r16Float` | `"0 0 0 0"` | ✔ | — | 압력 B |
| 4 | `_rt_SmokeDivergence` | `fit:256` | `r16f` | `.r16Float` | — | ✔ | — | ∇·u |
| 5 | `_rt_SmokeCurl` | `fit:256` | `r16f` | `.r16Float` | — | ✔ | — | ω |
| 6 | `_rt_SmokeDye1` | `scale:2` | `rgba_backbuffer` | HDR? `.rgba16Float` : `.rgba8Unorm` | `"0 0 0 0"` | ✔ | — | 염료 A |
| 7 | `_rt_SmokeDye2` | `scale:2` | `rgba_backbuffer` | 〃 | `"0 0 0 0"` | ✔ | — | 염료 B |
| 8 | `_rt_SmokeNormal` | `scale:2` | `rgba8888` | `.rgba8Unorm` | — | **✘** | `[{"LIGHTING":1}]` | 염료 α 로부터의 노멀 |

관측 규칙 셋 —

* **`clear` 를 가진 6장은 전건 `unique` 다.** 프레임을 넘겨 누적하는 버퍼만 시작값을 정의할 필요가
  있다. `_rt_SmokeDivergence`/`_rt_SmokeCurl` 은 매 프레임 자기 패스가 전면 덮어쓰므로 `clear` 가 없다.
* **`_rt_SmokeNormal` 만 `unique` 가 아니다.** 프레임 간 지속이 필요 없고(같은 프레임 안에서
  만들어 같은 프레임에 소비) 조건부라 공유 풀에서 받는다.
* **`rgba_backbuffer` 는 고정 포맷이 아니다** — `0x1401e7562`(`stricmp`)가 해시맵 조회 **전에**
  가로채 씬 HDR 비트(`[[eff+0x130]+0xc8]+0x118 & 0x2000`)로 enum 14(`rgba16161616f`) 또는
  enum 0(`rgba8888`)으로 치환한다(`0x1401e7572`–`0x1401e7596`).

### 1.3 `fit` 의 실물 의미 — **정사각이 아니다** (신규 확정)

`0x1401eb2cc`–`0x1401eb381` 이 dst 크기 `(W0,H0)`(4 로 하한 클램프, `0x1401ea5e4`)에서
최종 텍스처 크기를 만든다. 의사코드 그대로:

```
W = (width  선언?  width  : W0)          # 0x1401eb2cc, 0xffff 초과면 미선언
H = (height 선언?  height : H0)          # 0x1401eb2d7
if (fit 선언) {                          # 0x1401eb2f8  cmp ax, 0x1000 / ja → 미선언
    if (W >= H) { W' = min(fit, W); H' = (int)((float)H / (float)W * (float)W'); }   # 0x1401eb311-0x1401eb340
    else        { H' = min(fit, H); W' = (int)((float)W / (float)H * (float)H'); }   # 0x1401eb346-0x1401eb377
} else { W' = W; H' = H; }               # 0x1401eb37d
createRenderTarget(W', H', scale, name, format, 0x1b, wrap, 1)   # 0x1401eba0b
```

즉 **`fit:N` = "긴 변을 N 으로, 종횡비 보존, 확대 금지"**. `cvttss2si`(0 방향 절삭)로 정수화한다.

이 이펙트에 대한 귀결:

| 화면 | WE 의 속도/압력/발산/컬 그리드 | `aspect = res.y/res.x` | 텍셀 모양(화면상) |
|---|---|---|---|
| 1920×1080 | **256 × 144** | 0.5625 | **정사각** |
| 2560×1440 | **256 × 144** | 0.5625 | 정사각 |
| 1080×1920(세로) | **144 × 256** | 1.7778 | 정사각 |
| 정사각 레이어 | 256 × 256 | 1.0 | 정사각 |

**유체 솔버가 성립하려면 텍셀이 정사각이어야 한다** — curl/divergence/Jacobi/gradient
전부가 `Δx = Δy = 1 텍셀` 을 가정한 유한차분이고, 이류(advection)는 속도를 텍셀/초로
해석해 UV 로 되돌린다. `fit` 이 종횡비를 보존하는 이유가 정확히 이것이다.

`fit` 과 `scale` 이 **둘 다** 있을 때의 상호작용은 **[미해결]** — 이 이펙트에는 그런 FBO 가
없고(`fit` 6장은 `scale` 미선언, `scale` 3장은 `fit` 미선언), `scale` 은 위 크기 계산과 별도로
`createRenderTarget` 의 4번째 인자로 넘어가(`0x1401eb9d4`) 내부에서 처리된다.

### 1.4 패스 20개 — 전개표

`target` 부재 = 이펙트 출력. `bind[].index` 는 셰이더 `g_TextureN` 슬롯 번호다.

| 원본 idx | 머티리얼 / 명령 | target | bind 0 | bind 1 | bind 2 | bind 4 | 조건 | 씬 pass id(preview) |
|---:|---|---|---|---|---|---|---|---:|
| 0 | `..._curl.json` | `_rt_SmokeCurl` | `Velocity1` | — | — | — | — | 19 |
| 1 | `..._vorticity.json` | `_rt_SmokeVelocity2` | `Velocity1` | `Curl` | — | — | — | 21 |
| 2 | `..._divergence.json` | `_rt_SmokeDivergence` | `Velocity2` | — | — | — | — | 22 |
| 3 | `..._clear.json` | `_rt_SmokePressure2` | `Pressure1` | — | — | — | — | 23 |
| 4 | `..._pressure.json` | `_rt_SmokePressure1` | `Divergence` | `Pressure2` | — | — | — | 24 |
| 5 | 〃 | `_rt_SmokePressure2` | `Divergence` | `Pressure1` | — | — | — | 25 |
| 6 | 〃 | `_rt_SmokePressure1` | `Divergence` | `Pressure2` | — | — | — | 26 |
| 7 | 〃 | `_rt_SmokePressure2` | `Divergence` | `Pressure1` | — | — | — | 27 |
| 8 | 〃 | `_rt_SmokePressure1` | `Divergence` | `Pressure2` | — | — | — | 28 |
| 9 | 〃 | `_rt_SmokePressure2` | `Divergence` | `Pressure1` | — | — | — | 29 |
| 10 | 〃 | `_rt_SmokePressure1` | `Divergence` | `Pressure2` | — | — | — | 30 |
| 11 | 〃 | `_rt_SmokePressure2` | `Divergence` | `Pressure1` | — | — | — | 31 |
| 12 | 〃 | `_rt_SmokePressure1` | `Divergence` | `Pressure2` | — | — | — | 32 |
| 13 | `..._gradientsubtract.json` | `_rt_SmokeVelocity1` | `Pressure1` | `Velocity2` | — | — | — | 33 |
| 14 | `..._advection.json` | `_rt_SmokeVelocity2` | `Velocity1` | **`Velocity1`** | — | — | — | 34 |
| 15 | `..._advection_dye.json` | `_rt_SmokeDye2` | `Velocity2` | `Dye1` | `previous` | — | — | 35 |
| 16 | `..._normal.json` | `_rt_SmokeNormal` | `Dye2` | — | — | — | **패스 `[{"LIGHTING":1}]`** | 36 |
| 17 | `..._combine.json` | **(출력)** | `Dye2` | `previous` | `Normal`<br>`[{"LIGHTING":1}]` | `Velocity2`<br>`[{"RENDERING":3}]` | — | 37 |
| 18 | `command:"swap"` | `Velocity2` | source `Velocity1` | | | | | (없음) |
| 19 | `command:"swap"` | `Dye2` | source `Dye1` | | | | | (없음) |

패스 14 가 **같은 FBO 를 슬롯 0 과 1 에 두 번** 바인드한다(속도장을 자기 자신으로 이류).
슬롯 3 은 매니페스트가 바인드하지 않는다 — 셰이더 어노테이션의 `"default"` 로 채워진다(§1.6).

**씬 오버라이드 인덱스 정합 실측.** preview `scene.json` 의 `effects[0].passes` 는 **18개**
(id 19,21…37 — 20 은 결번)이고, 위 표의 원본 idx 0..17 과 **1:1로 맞는다** — id 23 에만
`pressure:0.8`(= `..._clear.vert` 의 `u_Pressure`), id 36 에만 `depth:0.5`(= `..._normal.frag`
의 `u_Depth`), id 35 에만 `DYE:1` 이 실려 있다. 즉 **명령 패스도 원본 배열 슬롯을 소비하고,
에디터는 배열 **끝**의 빈 원소만 잘라낸다** — `SceneRendererResources.swift:713-733` 의 정정이
이 자산으로 재확인된다.

### 1.5 `conditions` — 4건 전부

| 자리 | 조건 | 참일 때 | 거짓일 때 |
|---|---|---|---|
| `fbos[8]` (`_rt_SmokeNormal`) | `LIGHTING == 1` | FBO 생성 | **아예 안 만든다** |
| `passes[16]` (`..._normal`) | `LIGHTING == 1` | 패스 실행 | 패스 통째 스킵(씬 오버라이드 인덱스는 그대로 증가) |
| `passes[17].bind[2]` | `LIGHTING == 1` | 슬롯 2 ← `_rt_SmokeNormal` | **그 슬롯만** 언바인드 |
| `passes[17].bind[3]`(index 4) | `RENDERING == 3` | 슬롯 4 ← `_rt_SmokeVelocity2` | 〃 |

**좌변은 씬의 `effects[i].combos`(이펙트 인스턴스 레벨)다** — 패스 레벨이 아니다.
평가기 `0x1401e63b0` 의 2번째 인자는 세 호출 지점(`0x1401e7404` fbo · `0x1401e79fd` pass ·
`0x1401e7ed0` bind) 전건 `rdx = r13` 이고, `r13` 은 `0x1401e7319`(`find(effectNode, "combos")`)
가 이펙트당 **1회** 잡은 노드다. 패스 combos 와의 병합은 없다.

**설치본 전수(scene.json 184개)에서 `effects[].combos` 는 0건이다.** 그러므로 셋 다 항상 거짓 —
출하 콘텐츠에서 이 이펙트의 **조명 경로는 죽어 있다**.

> 여기 원본 설계의 이음매가 하나 보인다. `LIGHTING`/`RENDERING` 은 `[COMBO]` 어노테이션의
> `"material"` 키(`ui_editor_properties_lighting` / `..._rendering`)로 **에디터 프로퍼티**에
> 묶여 있고, preview 씬이 보여 주듯 에디터가 쓰는 자리는 `passes[].combos` 다(`BLENDMODE:0`).
> 그런데 `conditions` 는 `effects[].combos` 만 본다. 에디터가 이 둘을 함께 쓰는지는
> **[미해결]** — 출하 자산에 `effects[].combos` 가 0건이라 역산할 수 없고, `wallpaperui.exe`
> 는 이 조사 범위 밖이다. 함께 쓰지 **않는다면** `LIGHTING=1` 을 켠 사용자는 WE 에서도
> `g_Texture2` 가 미바인드인 채 `PerformLighting_V1` 을 돌게 된다.

### 1.6 콤보 · 사용자 값 전수

`// [COMBO]` 선언(본체 기준, 스테이지 합집합):

| 콤보 | 선언 파일 | 기본 | UI 옵션 | 소비처 |
|---|---|---:|---|---|
| `PERSPECTIVE` | advection.vert · vorticity.vert · combine.frag | 0 | (토글) | `squareToQuad` UV 워프 |
| `POINTEMITTER` | advection.frag · vorticity.frag | **1** | `[0,1,2,3]` | 점 에미터 개수 |
| `LINEEMITTER` | advection.frag · vorticity.frag | 0 | `[0,1,2,3]` | 선 에미터 개수 |
| `RENDERING` | advection.frag · combine.frag | 0 | gradient 0 / emitter_color 1 / background_color 2 / distortion 3 | 색 모드 |
| `INTERACTIVE` | vorticity.frag | **1** | (토글) | 커서 임펄스 블록 |
| `BLENDMODE` | combine.frag | **31** | `type:"imageblending"` | `ApplyBlending` — 31 = `A + B*opacity`(가산) |
| `OPAQUE` | combine.frag | 0 | (토글) | 출력 α=1 |
| `WRITEALPHA` | combine.frag | **1** | (토글) | 0 이면 α 를 `previous` 것으로 되돌림 |
| `LIGHTING` | combine.frag | 0 | (토글) | 노멀 패스 + PBR |
| `COLLISIONMASK` | (슬롯 유래) advection.frag `g_Texture3` | — | `require {"DYE":0}` | 충돌 마스크 |
| `DYEEMITTER` | (슬롯 유래) advection.frag `g_Texture4` | — | `require {"DYE":1}` | 텍스처 염료 주입 |
| `DYE` | **선언 없음** | — | — | 머티리얼 `fluidsimulation_advection_dye.json` 이 `{"DYE":1}` 로 켠다 |

> `POINTEMITTER` 의 `options` 가 `[0,1,2,3]` 인데 셰이더는 `#if POINTEMITTER >= 4` 까지, `gizmos`
> 도 `POINTEMITTER ge 4` 까지 정의한다. 즉 **4번째 점 에미터(`emitterPos3` 등)는 UI 에서 도달
> 불가**다. 원본 저작 불일치로 보이며 런타임에는 무해하다(값 4 가 오면 정상 동작한다).

머티리얼 `constantshadervalues`(패스 상수):

| 머티리얼 | 키 | 값 | 셰이더 유니폼 |
|---|---|---:|---|
| `..._advection.json` | `dissipation` | 0.2 | `m_Dissipation` |
| `..._advection_dye.json` | `dissipation` | 0.4 | `m_Dissipation` (+ `combos {DYE:1}`) |

사용자 값(유니폼 꼬리 주석) 전수 — `material` 키 → 기본값/범위:

| 유니폼 | `material` | 기본 | 범위 | 그룹 | 셰이더 |
|---|---|---:|---|---|---|
| `u_Curl` | `curl` | 30.0 | [0,50] | simulation | vorticity.frag |
| `u_CursorInfluence` | `cursorinfluence` | 1.0 | [0,2] | simulation | vorticity.vert |
| `u_Pressure` | `pressure` | 0.8 | [0,1] | simulation | clear.vert |
| `u_Viscosity` | `viscosityfactor` | 1.0 | [0,20] | simulation | advection.frag |
| `u_Dissipation` | `dissipationfactor` | 1.0 | [0.01,10] | simulation | advection.frag |
| `m_Dissipation` | `dissipation` | 1.0 | [0,1] | simulation (hidden) | advection.frag |
| `u_Lifetime` | `lifetime` | 0.1 | [0.1,1] | simulation ("high pass") | advection.frag |
| `u_Saturation` | `saturation` | 1.0 | [0,1] | — | advection.frag |
| `u_ConstantVelocityAngle` | `forcedirection` | π | `direction`, `rad2deg` | gravity | advection.frag |
| `u_ConstantVelocityStrength` | `forcestrength` | 0.0 | [0,100] | gravity | advection.frag |
| `u_Depth` | `depth` | 0.5 | [0,1] | material | normal.frag |
| `u_Roughness` / `u_Metallic` | `roughness` / `metallic` | 0.5 / 0.5 | [0,1] | material | combine.frag (`#if LIGHTING`) |
| `u_Brightness` | `brightness` | 1.0 | [0.01,5] | — | combine.frag |
| `u_Alpha` | `opacity` | 1.0 | [0.01,1] | — | combine.frag |
| `u_Feather` | `feather` | 1.0 | [0.01,1] | — | combine.frag |
| `u_HueShift` | `hue` | 0.0 | [0,1] | — | combine.frag |
| `m_EmitterPos{0..3}` `m_EmitterAngle*` `m_EmitterSize*` `m_EmitterSpeed*` `m_EmitterColor*` | 동명 | 표 아래 | | point_emitter_{1..4} | vorticity.frag(속도) / advection.frag(색) |
| `m_LineEmitterPosA/B{0..2}` `…Angle*` `…Size*` `…Speed*` `…Color*` | 동명 | 〃 | | line_emitter_{1..3} | 〃 |
| `g_Point{0..3}` | `point{0..3}` | (0 0)(1 0)(1 1)(0 1) | hidden | | `#if PERSPECTIVE==1` |

에미터 기본값: `emitterPos` = (0.5,0.5)/(0.5,0.7)/(0.7,0.7)/(0.7,0.5), `emitterSize` 0.05,
`emitterSpeed` 100(범위 [0,1000]), `emitterAngle` 0, `emitterColor` 빨강/초록/파랑/노랑.
`lineEmitterPosA/B` = (0.1,0.1)–(0.4,0.1) 등, `lineEmitterSize` 0.02, `lineEmitterSpeed` 100.

**텍스처 슬롯**(매니페스트가 안 묶는 것):

| 셰이더 | 슬롯 | 어노테이션 | 자산 존재 |
|---|---:|---|---|
| vorticity.frag | `g_Texture2` | `{"hidden":true,"default":"util/noise"}` | ✔ `materials/util/noise.tex` |
| combine.frag | `g_Texture3` | `{"default":"gradient/gradient_fire","require":{"RENDERING":0}}` | ✔ `materials/gradient/gradient_fire.tex` |
| advection.frag | `g_Texture3` | `mode:"opacitymask"`, `combo:"COLLISIONMASK"`, `require {"DYE":0}` | (사용자 페인트) |
| advection.frag | `g_Texture4` | `mode:"rgbmask"`, `combo:"DYEEMITTER"`, `require {"DYE":1}` | (사용자 페인트) |
| combine.frag | `g_Texture6/7` | `_rt_shadowAtlas` / `_alias_lightCookie`, `#if LIGHTS_SHADOW_MAPPING` / `#if LIGHTS_COOKIE` | 엔진 내부 |

**preview 씬이 저작한 값**(= WE 자신이 고른 "보기 좋은" 세팅): `LINEEMITTER:1`, `POINTEMITTER:0`,
`BLENDMODE:0`, `curl 30`, **`cursorinfluence 4`**, `viscosityfactor 2.29`, `lifetime 0.32`,
`dissipationfactor 1.0`, `feather 0.68`, `lineEmitterSpeed0 1261.6`, `lineEmitterSize0 0.0353`.

> `cursorinfluence 4` 는 어노테이션 범위 `[0.0, 2.0]` **밖**이고 `lineEmitterSpeed0 1261.6` 도
> `[0,1000]` 밖이다. 즉 **`range` 는 에디터 슬라이더 전용이고 런타임 클램프가 아니다** —
> 저작된 `constantshadervalues` 는 그대로 유니폼으로 간다. Waple 도 클램프하지 않는다(정합).

---

## 2. 셰이더 전문 — 패스별 수식

전 패스 공통: 정점은 화면 채움 3각/4각(`gl_Position = vec4(a_Position, 1.0)` — MVP 없음.
**출력 패스만 예외**로 `combine.vert` 가 `mul(vec4(a_Position,1), g_ModelViewProjectionMatrix)` 를
쓴다). 머티리얼은 전건 `blending:"normal"` · `depthtest:"disabled"` · `depthwrite:"disabled"` ·
`cullmode:"nocull"`. `docs/re/material-blend.md` §2 대로 **WE 의 `normal` 은 BlendEnable=FALSE**
(= 덮어쓰기)다 — 시뮬레이션 패스가 알파로 섞이면 안 되므로 이게 필수 조건이다.

기호: `u` = 프래그먼트 UV, `N = (Nx,Ny)` = 속도 그리드 텍셀 수, `h = (1/Nx, 1/Ny)`,
`Δt = g_Frametime`(초), `dt = min(1/20, Δt)`.

### 2.1 공통 이웃 샘플 규약

curl / vorticity / divergence / pressure / gradientsubtract 의 `.vert` 다섯 개가 **같은 네 줄**을
쓴다(curl·vorticity 는 `a_TexCoord` 를, 나머지 셋은 그것을 복사한 `v_TexCoord` 를 기점으로 쓸 뿐
결과는 동일하다):

```glsl
vec2 texelSize = CAST2(1.0) / g_Texture0Resolution.xy;
v_TexCoordLeftTop     = a_TexCoord.xyxy;   v_TexCoordRightBottom = a_TexCoord.xyxy;
v_TexCoordLeftTop.x     -= texelSize.x;    v_TexCoordLeftTop.w     += texelSize.y;
v_TexCoordRightBottom.x += texelSize.x;    v_TexCoordRightBottom.w -= texelSize.y;
```

`.frag` 가 뽑아 쓰는 네 좌표:

```
vL = (u.x − hx, u.y)      vR = (u.x + hx, u.y)
vT = (u.x, u.y + hy)      vB = (u.x, u.y − hy)
```

즉 **+y 가 "Top"** 인 UV 규약이다. WE 텍스처 공간은 y-down 이라 화면상 `vT` 는 실제로 **아래쪽**
이다 — 발산·압력경사·이류가 전부 같은 축(d/d(uv.y))을 쓰므로 정합이고, 부호가 실제로 뒤집히는
것은 **컬 하나**뿐이다(소용돌이 회전 방향이 반대가 된다).
`g_Texture0Resolution` 은 **각 패스의 슬롯 0** 해상도라서, dye 패스에서는 속도 그리드 해상도가
들어온다(§2.9). 경계 밖 샘플은 클램프(가장자리 복제)다 — `uvs:"repeat"` 를 안 쓴다.

### 2.2 패스 0 — curl (`fluidsimulation_curl`)

```glsl
float L = texSample2D(g_Texture0, vL).y;   float R = texSample2D(g_Texture0, vR).y;
float T = texSample2D(g_Texture0, vT).x;   float B = texSample2D(g_Texture0, vB).x;
float vorticity = R - L - T + B;
gl_FragColor = vec4(0.5 * vorticity, 0.0, 0.0, 1.0);
```

```
ω(u) = ½·[ (v_y(vR) − v_y(vL)) − (v_x(vT) − v_x(vB)) ]   ≈  (Δx/2)·(∂x v_y − ∂y v_x)
```

**단위는 텍셀**이다 — 1/(2Δx) 의 Δx 를 접어 버려서 전 솔버가 "텍셀/초" 로 일관되게 돈다.
경계 처리 없음.

### 2.3 패스 1 — 와도 구속 + 외력 (`fluidsimulation_vorticity`)

```glsl
float dt = min(1.0/20.0, g_Frametime);
float L,R,T,B,C = curl(vL,vR,vT,vB,vUv);
vec2 force = 0.5 * vec2(abs(T) - abs(B), abs(R) - abs(L));
force /= length(force) + 0.0001;
force *= u_Curl * C;
force.y *= -1.0;
vec2 velocity = texSample2D(g_Texture0, v_TexCoord).xy;
velocity += force * dt;
velocity = min(max(velocity, -1000.0), 1000.0);
```

```
N      = ∇|ω| / (‖∇|ω|‖ + 1e-4)          (성분 순서가 (∂y, ∂x) 로 뒤집혀 들어온다)
f_conf = u_Curl · ω · (N_y, −N_x)         (force.y *= −1 이 이 부호를 만든다)
v     += f_conf · dt ,   v ∈ [−1000, 1000]²
```

성분 순서 `(|T|-|B|, |R|-|L|)` 이 **일부러 뒤바뀐 것**과 뒤이은 `force.y *= -1` 이 합쳐져
2차원 외적 `ω · (N × ẑ)` 을 이룬다. `+0.0001` 이 0-나눗셈 가드다.
`u_Curl`(기본 30, preview 30)이 구속 세기 ε 이다.

이 패스가 **속도장에 들어오는 모든 외력의 유일한 창구**다 — 에미터(§5.4)와 커서 임펄스(§5.2)도
여기서 더해지고, 결과가 `_rt_SmokeVelocity2` 로 나간다.

### 2.4 패스 2 — 발산 (`fluidsimulation_divergence`) — **유일한 경계조건**

```glsl
float L = tex(vL).x;  float R = tex(vR).x;  float T = tex(vT).y;  float B = tex(vB).y;
vec2 C = tex(vUv).xy;
if (vL.x < 0.0) { L = -C.x; }
if (vR.x > 1.0) { R = -C.x; }
if (vT.y > 1.0) { T = -C.y; }
if (vB.y < 0.0) { B = -C.y; }
float div = 0.5 * (R - L + T - B);
```

```
∇·v(u) = ½·[ v_x(vR) − v_x(vL) + v_y(vT) − v_y(vB) ]
경계:  vL.x < 0 → v_x(vL) := −v_x(u)        (좌·우·상·하 4면, 법선 성분 반사)
```

네 개의 `if` 가 **솔버 전체에서 유일한 명시 경계조건**이다: 도메인 밖 고스트 셀의 법선 속도를
`-C`(내부값의 반사)로 두어 **벽을 통과하지 못하게** 한다. 조건은 정점보간된 이웃 좌표로
판정하므로 최외곽 한 줄에서만 발화한다. 다른 패스(curl/Jacobi/gradient/advection)에는
경계 처리가 없고 클램프 샘플링에 의존한다.

### 2.5 패스 3 — 압력 감쇠 (`fluidsimulation_clear`)

정점에서 계수를 만들고 프래그먼트에서 곱하기만 한다:

```glsl
// .vert
v_TexCoord.z = pow(u_Pressure, 60 * g_Frametime);
// .frag
gl_FragColor = v_TexCoord.z * texSample2D(g_Texture0, v_TexCoord.xy);
```

```
p' = p · u_Pressure^(60·Δt)        # u_Pressure 기본 0.8, Δt = 생 g_Frametime
```

**여기만 `dt`(1/20 클램프)가 아니라 생 `Δt` 를 쓴다.** 지수를 `60Δt` 로 두어 감쇠가
**프레임률 독립**이다 — 60 fps 에서 지수 1, 즉 "1/60 초당 ×0.8"(기본값). 60 fps 기준 반감기는
약 3.1 프레임(52 ms)이다. 이름이 `clear` 지만 실제로는 **완전 소거가 아니라 지수 감쇠**고,
전 프레임 압력장을 초기추정으로 재활용해 Jacobi 9회로도 수렴을 벌어들이는 장치다.

### 2.6 패스 4–12 — Jacobi 압력 솔브 ×9 (`fluidsimulation_pressure`)

```glsl
float L,R,T,B,C = p(vL,vR,vT,vB,vUv);      // g_Texture1 = 반대편 압력 버퍼
float divergence = texSample2D(g_Texture0, vUv).x;   // g_Texture0 = _rt_SmokeDivergence
float pressure = (L + R + B + T - divergence) * 0.25;
```

```
p⁽ᵏ⁺¹⁾[i,j] = ( p⁽ᵏ⁾[i−1,j] + p⁽ᵏ⁾[i+1,j] + p⁽ᵏ⁾[i,j−1] + p⁽ᵏ⁾[i,j+1] − (∇·v)[i,j] ) / 4
```

즉 표준형 `(L+R+B+T + α·b)/β` 에서 `α = -1`, `β = 4`(Δx=1 텍셀). `C` 를 읽지만 쓰지 않는다
(원본에도 남아 있는 죽은 로컬).

**반복 횟수 9 는 매니페스트에 하드코딩**돼 있다 — 같은 머티리얼 패스를 9번 복제했다.
콤보로 조절되지 않는다. 체인은 `clear→P2`, 그다음 `P2→P1, P1→P2, …` 로 아홉 번,
**마지막이 `P1` 에 착지**하고 패스 13 이 그 `P1` 을 읽는다.

### 2.7 패스 13 — 압력 경사 제거 (`fluidsimulation_gradientsubtract`)

```glsl
float L,R,T,B = p(vL,vR,vT,vB);            // g_Texture0 = _rt_SmokePressure1
vec2 velocity = texSample2D(g_Texture1, vUv).xy;   // g_Texture1 = _rt_SmokeVelocity2
velocity.xy -= vec2(R - L, T - B);
```

```
v_divfree = v − ∇p ,     ∇p = ( p(vR) − p(vL),  p(vT) − p(vB) )      # ½ 계수 없음
```

**여기엔 `0.5` 가 없다** — curl/divergence 의 중심차분에는 있고 여기엔 없다. 곧 투영이
발산 연산자 대비 **2배 과이완**(over-relaxed)이다. 참조 구현(PavelDoGreat WebGL-Fluid-Simulation)
과 동일한 형태이므로 **의도된/전승된 값**으로 취급해야 한다. 0.5 를 넣으면 흐름이 눈에 띄게
더 끈적해진다 — 이식할 때 "고치면" 안 된다.

### 2.8 패스 14 — 속도 이류 (`fluidsimulation_advection`, `DYE` 미설정)

```glsl
vec2 texelSize = CAST2(1.0) / g_Texture0Resolution.xy;
float dt = min(1.0/20.0, g_Frametime);
vec2 coord = vUv - dt * texSample2D(g_Texture0, vUv).xy * texelSize;
vec4 result = texSample2D(g_Texture1, coord);
float decayFactor = u_Viscosity;                       // DYE==0
float decay = 1.0 + decayFactor * m_Dissipation * dt;  // m_Dissipation = 0.2 (머티리얼 상수)
float lowPass = step(length(result.rgb), u_Lifetime) * 0.5;
gl_FragColor = result / (decay + lowPass);
float aspect = g_Texture0Resolution.y / g_Texture0Resolution.x;
vec2 constantSpeed = vec2(sin(u_ConstantVelocityAngle), -cos(u_ConstantVelocityAngle)) * u_ConstantVelocityStrength;
constantSpeed.y *= aspect;
gl_FragColor.xy += constantSpeed * g_Frametime;
```

준-라그랑주 역추적 + 소산:

```
x_back = u − dt · v(u) ⊙ h                       # h = 1/그리드해상도, v 단위 = 텍셀/초
v'     = v(x_back) / ( decay + lowPass )
  decay   = 1 + ν·m·dt          ν = u_Viscosity(viscosityfactor), m = m_Dissipation(0.2)
  lowPass = 0.5 · [ ‖v(x_back)‖ < u_Lifetime ]
```

* 역추적 거리는 **텍셀 단위 속도 × dt** 를 `h` 로 UV 화한 것 — 즉 `v` 는 "그리드 텍셀/초" 다.
  바이리니어 필터가 보간을 대신한다(1차 정확도, 수치 확산이 큰 고전 Stam 이류).
* `decay`: `ν = u_Viscosity`(`viscosityfactor`, 기본 1, preview 2.29), `m = 0.2`.
  60 fps 기본값이면 1 + 1·0.2·0.0167 = 1.0033 → 프레임당 0.33 % 감쇠.
* `lowPass`: 이름은 "high pass"(UI 라벨)인데 실제는 **컷오프**다. `‖result.rgb‖ < u_Lifetime`
  이면 분모에 0.5 를 더해 `÷1.5` → 잔여 흐름을 빠르게 없앤다. `rg16f` 텍스처의 `.b` 는 0 이므로
  속도 패스에서 `length(result.rgb) = ‖v‖` 다.
* **중력/상시력만 생 `Δt`** 를 쓴다(다른 항은 `dt`). 방향은 `(sinθ, -cosθ)` — θ=π 기본값이면
  `(0, +1)` = UV +y = 화면 아래. `constantSpeed.y *= aspect` 로 화면상 등방이 된다
  (**§1.3 의 `fit` 종횡비가 여기서 그림에 직접 닿는다**).
* `#if COLLISIONMASK`: `solid = mask.r * mask.a`, `v.xy = mix(v.xy, 0, solid)` — 마스크가
  칠해진 곳에서 속도를 0 으로 지우는 **소프트 장애물**.

### 2.9 패스 15 — 염료 이류 + 주입 (`fluidsimulation_advection_dye`, `DYE=1`)

같은 셰이더의 `DYE` 분기. 슬롯 0 = `_rt_SmokeVelocity2`(속도), 슬롯 1 = `_rt_SmokeDye1`,
슬롯 2 = `previous`.

```glsl
vec2 coord = vUv - dt * vel(vUv).xy * texelSize;    // texelSize = 1/속도해상도
vec4 result = dye(coord);
float decayFactor = u_Dissipation;                  // dissipationfactor
float boundaryMask = step(0.0,coord.x)*step(coord.x,1.0)*step(0.0,coord.y)*step(coord.y,1.0);
float decay = 1.0 + decayFactor * m_Dissipation * dt;   // m_Dissipation = 0.4
float lowPass = step(length(result.rgb), u_Lifetime) * 0.5;
result *= boundaryMask;
gl_FragColor = result / (decay + lowPass);
```

**`g_Texture0Resolution` 이 염료가 아니라 속도장 해상도라는 점이 중요하다** — 두 텍스처가 같은
UV 공간에 있고 속도가 속도-텍셀/초이므로 역추적 거리는 속도 그리드 기준이어야 맞다.
염료는 `scale:2`(dst/2)라 해상도가 다르지만 UV 는 같다.

`boundaryMask` 는 도메인 밖으로 역추적된 픽셀을 **경성 절단**한다(속도 패스에는 없다) —
가장자리에서 염료가 클램프로 번지는 것을 막는다.

이어서 주입(§5.4)이 온다. `RENDERING` 에 따라 세 가지 합성:

```glsl
vec4 AddEmitterColor(texCoord, amt, currentColor, emitterColor) {
#if RENDERING == 2                       // 배경색 주입
    return mix(currentColor, texSample2D(g_Texture2, texCoord), amt);      // g_Texture2 = previous
#endif
#if RENDERING == 1                       // 에미터색 주입
    emitterColor *= amt;
    return min(currentColor + vec4(mix(g_Frametime, 1.0, u_Saturation) * emitterColor, amt),
               max(CAST4(1.0), vec4(emitterColor, amt)));
#endif
    return min(currentColor + CAST4(amt), CAST4(1.0));                     // RENDERING 0/3: 밀도만
}
```

`RENDERING==0`(기본)에서는 **밀도(회색)만 쌓고 색은 combine 이 그래디언트 맵으로 입힌다**.

`#if DYEEMITTER` 텍스처 주입:

```
s = tex4(v_TexCoord) ;  s.rgb *= s.a
out = min( out + ( s.rgb·u_Saturation ,  saturate(dot(s.rgb, vec3(Δt)) · s.a) ) , 1 )
```

> 원본 불일치 하나: 에미터/충돌마스크는 `emitterUV`(PERSPECTIVE 보정)를 쓰는데
> `DYEEMITTER` 만 생 `v_TexCoord` 로 샘플한다(`advection.frag:167`). `PERSPECTIVE==1` 에서
> 텍스처 염료 주입만 워프가 안 걸린다.

### 2.10 패스 16 — 노멀 (`fluidsimulation_normal`, `LIGHTING==1`)

```glsl
float refAlpha = tex(fxCoords).a;
vec2 ist = CAST2(1.0) / g_Texture0Resolution.xy;      // 염료 해상도
float s10 = tex(fxCoords + vec2(ist.x, 0.0)).a;
float s01 = tex(fxCoords + vec2(0.0, ist.y)).a;
vec2 base = vec2(s10 - refAlpha, s01 - refAlpha) * CAST2(25.0 * u_Depth);
base = clamp(base, CAST2(-1.0), CAST2(1.0)) * refAlpha;
vec3 normal = vec3(base, 0.0);  normal.x = -normal.x;
normal.z = sqrt(saturate(1.0 - normal.x*normal.x - normal.y*normal.y));
gl_FragColor = vec4(normal * CAST3(0.5) + CAST3(0.5), 1.0);
```

염료 알파를 높이장으로 보는 **전진차분** 노멀. 게인 `25·u_Depth`, `×refAlpha` 로 염료가 없는
곳은 평평(0,0,1)해진다. 출력은 `rgba8888` 에 0..1 로 패킹.

### 2.11 패스 17 — combine (출력)

유일하게 MVP 를 쓰는 패스다(`combine.vert:32`). 슬롯: 0 = `Dye2`, 1 = `previous`,
2 = `Normal`(LIGHTING), 3 = 그래디언트 맵(어노테이션 default), 4 = `Velocity2`(RENDERING==3).

```glsl
vec4 albedo = texSample2D(g_Texture0, fxCoords.xy);
#if RENDERING == 0      // 그래디언트 맵
    vec4 g = texSample2D(g_Texture3, vec2(albedo.r, 0.5));
    vec3 hsv = rgb2hsv(g.rgb); hsv.x += u_HueShift;
    albedo.rgb = hsv2rgb(hsv) * u_Brightness;  albedo.a *= g.a;
#elif RENDERING == 1    albedo.rgb *= u_Brightness;
#elif RENDERING == 2    albedo.rgb *= u_Brightness;  albedo.rgb /= albedo.a + 0.00001;   // 언프리멀티
#endif
albedo.a = smoothstep(0.0, u_Feather, albedo.a);
#if RENDERING == 3      // 왜곡
  #if LIGHTING   vec2 velocity = texSample2D(g_Texture2, fxCoords).xy * 2.0 - 1.0;       // 노멀맵을 변위로
  #else          float pressure = texSample2D(g_Texture4, fxCoords).x;
                 vec2 velocity = vec2(ddx(pressure), ddy(pressure));
                 velocity = sign(velocity) * smoothstep(CAST2(0.01), CAST2(10.0), abs(velocity));
  #endif
  albedo.rgb = texSample2D(g_Texture1, v_TexCoord.xy - velocity).rgb;  albedo.a = 1;
#endif
albedo.a *= fxMask;
#if LIGHTING
  vec3 normal = normalize(texSample2D(g_Texture2, fxCoords).rgb * 2.0 - 1.0);
  vec3 f0 = mix(CAST3(0.04), albedo.rgb, u_Metallic);
  vec3 light = PerformLighting_V1(v_WorldPos, albedo.rgb, normal, vec3(0,0,1), CAST3(1.0), f0, u_Roughness, u_Metallic);
  vec3 ambient = max(CAST3(0.001), g_LightAmbientColor) * albedo.rgb;
  albedo.rgb = CombineLighting(light, ambient);
#endif
#if OPAQUE   albedo.a = 1;
#else
  vec4 prev = texSample2D(g_Texture1, v_TexCoord.xy);
  #if BLENDMODE == 0   albedo = mix(prev, albedo, saturate(albedo.a) * u_Alpha);
  #else                albedo.rgb = ApplyBlending(BLENDMODE, prev.rgb, albedo.rgb, albedo.a * u_Alpha);
  #endif
  albedo.a = saturate(prev.a + albedo.a);
  #if WRITEALPHA == 0  albedo.a = prev.a;  #endif
#endif
```

`BLENDMODE` 기본 31 = `common_blending.h:264-266` 의 `return A + B*opacity` = **가산**.
preview 는 0(정상 알파 lerp)으로 덮는다.

> **원본 이름/바인드 불일치**: `RENDERING==3 && !LIGHTING` 분기가 `g_Texture4` 를 `pressure`
> 라 부르는데 매니페스트가 슬롯 4 에 묶는 것은 **`_rt_SmokeVelocity2`(rg16f)** 다. 즉 `.x` 는
> 압력이 아니라 **속도 x 성분**이고 그 화면공간 미분을 왜곡 오프셋으로 쓴다. 압력 버퍼를 슬롯
> 4 에 묶는 자리는 매니페스트 어디에도 없다 — 리팩터 잔재로 보이며, 그림은 "속도 x 의 도함수로
> 왜곡" 이라는 (의도와 다르지만) 동작하는 결과를 낸다.
>
> 또 `LIGHTING=1 && RENDERING=3` 이면 `g_Texture2` 를 **노멀맵이자 변위장**으로 두 번 읽는다.

### 2.12 타임스텝 · 그리드 · 스케일링 규약 요약

| 항목 | 값 | 근거 |
|---|---|---|
| 시뮬 dt | `min(1/20, g_Frametime)` — **50 ms 상한** | vorticity.frag:105 · advection.frag:109 |
| 압력 감쇠 dt | **생 `g_Frametime`**, 지수 `60Δt` | clear.vert:14 |
| 중력 dt | **생 `g_Frametime`** | advection.frag:177 |
| 에미터 dt | 점: 호출부에서 `g_Frametime * speed` / 선: 헬퍼 안에서 `g_Frametime * speed` — 둘 다 ∝Δt 1회 | vorticity.frag:91,138 |
| 속도 단위 | **그리드 텍셀 / 초** (UV 변환은 `× 1/res`) | advection.frag:111 |
| 그리드 간격 | Δx = Δy = 1 텍셀 (모든 유한차분이 이 가정) | §2.2–2.7 |
| 속도/압력 그리드 | `fit:256` → 긴 변 256, 종횡비 보존 | §1.3 |
| 염료 그리드 | `scale:2` → dst/2 | §1.2 |
| 속도 클램프 | `[-1000, 1000]` 텍셀/초 | vorticity.frag:125 |
| 압력 반복 | **9** (매니페스트 복제) | §2.6 |

---

## 3. 핑퐁 규약

### 3.1 읽기/쓰기 전수표

| # | 패스 | 읽음 | 씀 | 충돌? |
|---:|---|---|---|---|
| 0 | curl | V1 | **Curl** | 없음 |
| 1 | vorticity | V1, Curl | **V2** | 없음 |
| 2 | divergence | V2 | **Div** | 없음 |
| 3 | clear(압력감쇠) | P1 | **P2** | 없음 |
| 4 | jacobi 1 | Div, P2 | **P1** | 없음 |
| 5 | jacobi 2 | Div, P1 | **P2** | 없음 |
| 6..12 | jacobi 3..9 | Div, P(반대) | **P(교대)** | 없음 |
| 13 | gradientsubtract | P1, V2 | **V1** | 없음 |
| 14 | advection(vel) | V1, V1 | **V2** | 없음 |
| 15 | advection(dye) | V2, D1, prev | **D2** | 없음 |
| 16 | normal | D2 | **Normal** | 없음 |
| 17 | combine | D2, prev, Normal, V2 | (출력) | — |
| 18 | swap | V1 ↔ V2 | | |
| 19 | swap | D1 ↔ D2 | | |

**18개 드로우 패스 전건에서 읽는 텍스처와 쓰는 텍스처가 겹치지 않는다.** 이건 우연이 아니라
설계다 — GL/D3D/Metal 모두 같은 텍스처를 동시에 read+write 하면 미정의다.

프레임 끝 상태(swap 직전): 최신 속도 = `V2`(패스 14 출력), 최신 염료 = `D2`(패스 15 출력).
swap 두 번이 그것을 `V1`/`D1` 로 옮겨 **다음 프레임의 패스 0 이 `V1` 을 읽으면 곧 최신**이 된다.
압력은 swap 하지 않는다 — 9회 Jacobi 가 항상 `P1` 에 착지하고 패스 3 이 그 `P1` 을 읽으므로
프레임 경계에서 이미 정합이다.

`swap` 은 **포인터 교환**이지 복사가 아니다(`0x1401e7170` 이 명령 패스를 정식 패스로 push 하고,
Waple 은 `makeSwapPass` → `fboTex.swapAt`, `SceneRendererResources.swift:899-916`).

### 3.2 `unique` 가 이 이펙트에서 뜻하는 것

`unique:true` 는 **"프레임 풀에서 체크아웃하지 말고 이 이펙트 인스턴스 전용으로 프레임을 넘겨
들고 있어라"** 다. 원본에서 그 차이는 **렌더 타깃 풀의 키 이름**으로 드러난다:

| 종류 | 풀 키 | 근거 |
|---|---|---|
| `unique` | `<이름>_<이펙트 인스턴스 id>` — **치수 접미사 없음** | `0x1401eb381`(bit0 분기) → `0x1401eb3b5`(`"_"`) + `0x1401eb3d7`(`[[rbp-0x18]+8]` = 인스턴스 id) |
| 공유 | `<이름>_<W>_<H>_<scale>` | `0x1401eb4fa` 분기 → `0x1401eb552`(W) · `0x1401eb6eb`(H) · `0x1401eb737`(scale) |

즉 **`unique` RT 는 창 리사이즈로 키가 바뀌지 않는다** — `fit:` 절대 크기 버퍼가 dst 변화에
휘둘리지 않게 하는 장치다. Waple 도 같은 결론에 도달해 있다
(`SceneRendererFrameEncoder.swift:2013-2027` 의 "인덱스별 (폭,높이,포맷) 대조" 주석).

**`unique` 없이는 이 이펙트가 원리적으로 못 돈다.** 프레임 로컬 풀이면 (a) swap 이 매 프레임
리셋되고 (b) 체크아웃 순서가 바뀌면 같은 이름이 다른 텍스처를 받는다 — 시뮬 상태가 프레임 간에
존재하지 않게 된다.

`_rt_SmokeNormal` 하나만 공유 풀인 이유: 같은 프레임 안에서 만들어(패스 16) 같은 프레임에
소비(패스 17)하므로 지속이 필요 없다. 조건부라 자주 존재하지도 않는다.

### 3.3 `clear` 의 실물 기구

`clear` 문자열 파서는 `0x1401e7629`–`0x1401e777b` 다. 확정 규약(Waple 의 기존 정본과 일치):
구분자는 **스페이스(0x20)뿐**, 정확히 **4성분**이어야 하고, 모자라면 `0x1401e777b` 로 빠져
**clear 비트 자체가 안 선다**. 빈 문자열은 `0x1401e7641` 이 4성분을 0 으로 채우고 그대로 켠다.
성공 시 `0x1401e7771`: `r15d = 2` → 레코드 `+0x48` 의 **bit 1**.

클리어 실행은 FBO 획득 루틴 안에 있다 — `0x1401eba2c` 의 `test byte [rcx+0x48], 2` 뒤에
① 렌더 타깃 푸시(`0x1401eba4c`, vtbl+0x48) ② `+0x14/+0x18/+0x1c/+0x20` 4 float 를 실어
클리어색 설정(`0x1401eba85`, vtbl+0x118) ③ **색만** 클리어(`0x1401ebaa8`, vtbl+0x120,
`dl=1`/`r8d=0`) ④ 타깃 복귀. **`executeMaterialFunction` 의 클리어(§4.2)와 글자 그대로 같은
5-호출 시퀀스**다.

**클리어 빈도는 [미해결]** — 그 코드는 텍스처 신규 생성(`0x1401eba0b`)과 기존 리사이즈
(`0x1401eba23`) **양쪽 경로 뒤에** 있고, 이 루틴(`0x1401ea500`)은 vtable 슬롯
(`0x140490540`)이라 rel32 호출부가 없어 호출 빈도를 못 짚었다. 다만 **매 프레임일 수는 없다**:
`clear` 를 가진 6장이 전부 속도/압력/염료이고, 매 프레임 0 으로 비우면 이 이펙트는 어떤
그림도 못 만든다. 그래서 "생성/리사이즈 시 1회" 로 취급하는 Waple 의 현행 규약
(`SceneRendererFrameEncoder.swift:2069-2075`)이 관측과 모순되지 않는다.

---

## 4. `functions` — 정체 · 결함 · 실제 그림 영향

### 4.1 선언 전문과 파스 결과

```json
"functions": {
    "clearVelocity": { "action": "clear", "fbos": [ "_rt_SmokeVelocity1", "_rt_SmokeVelocity2" ] },
    "clearDye":      { "action": "clear", "fbos": [ "_rt_SmokeDye1", "_rt_SmokeDye2" ] }
}
```

| 이름 | action | 선언 FBO | **파스된 인덱스** | 원본 소비가 실제로 비우는 것 |
|---|---|---|---|---|
| `clearDye` | clear | `_rt_SmokeDye1`, `_rt_SmokeDye2` | `[6, 7]` | **`fbos[0]`, `fbos[1]` = Velocity1, Velocity2** ✘ |
| `clearVelocity` | clear | `_rt_SmokeVelocity1`, `_rt_SmokeVelocity2` | `[0, 1]` | `fbos[0]`, `fbos[1]` = Velocity1, Velocity2 ✔(우연) |

(항목 순서는 jsoncpp `std::map` = 키 사전순이므로 `clearDye` 가 먼저다.)

파서 `0x1401e8248`–`0x1401e88a1` 은 이름을 **제대로 푼다**: 선언된 fbo 목록을 stride `0x50` 로
선형 탐색(`0x1401e8630`–`0x1401e867d`, 이름은 레코드 `+0x28`)해 찾은 인덱스를
`0x1401e8691`(`mov [r14], esi`)로 push 한다. 중복 제거는 **없다**.

### 4.2 소비 — 결함 확정

`executeMaterialFunction` 의 네이티브 구현은 `0x1401ee3a0`–`0x1401ee51b` 다.

```
0x1401ee3ad  rsi = [this+0x100]  ; functions.begin (stride 0x40)
0x1401ee3b7  rbp = [this+0x108]  ; functions.end
0x1401ee3d0-0x1401ee40a  이름 선형 탐색(memcmp), 첫 일치 → 0x1401ee411
0x1401ee411  mov rax, [rsi+0x30]      ; fboIndices.end
0x1401ee417  sub rax, [rsi+0x28]      ; − fboIndices.begin
0x1401ee41b  sar rax, 2               ; ÷4  ==> n = 원소 "개수"
0x1401ee415  xor ebp, ebp             ; i = 0
0x1401ee440  mov rbx, [r14+0xe8]      ; fbos.begin (stride 0x50)
0x1401ee447  movsxd rax, ebp
0x1401ee44a  lea rdi, [rax+rax*4]     ;  5*i
0x1401ee44e  add rdi, rdi             ; 10*i   →  [rbx + rdi*8] = fbos + 80*i
0x1401ee451  mov rcx, [rbx + rdi*8]   ; fbos[i].texture      ← **i 는 루프 카운터**
0x1401ee468  call [rax+0x48]          ; 렌더 타깃 푸시
0x1401ee472-0x1401ee491  fbos[i] 의 clear RGBA 4 float 적재
0x1401ee49a  call [rax+0x118]         ; SetClearColor
0x1401ee4b6  call [rax+0x120]         ; Clear(dl=1, r8d=0 — 색만)
0x1401ee4bc-0x1401ee4e7  타깃 복귀
0x1401ee4ea-0x1401ee4fe  i++; i < n 이면 0x1401ee440 로
```

**루프 본문 어디에도 `fboIndices` 벡터의 원소를 읽는 명령이 없다.** `0x1401ee411`–`0x1401ee41b`
는 begin/end 포인터 차로 **개수만** 뽑고, 인덱싱은 전부 카운터 `ebp` 다. 즉 실효 동작은

```
clear(name)  ⟹  for i in 0 .. n−1:  clearColorOnly( fbos[i], fbos[i].clear )
             여기서 n = |fboIndices(name)|  (인덱스 "값" 은 어디서도 읽지 않는다)
```

**어떤 `functions` 항목이든 `fbos` 배열의 앞에서부터 n 장을 비운다.** 이름이 가리키는 곳이
아니다. 원본 결함이다 — 파스가 정확히 푼 값을 소비가 버린다.

부수 확인: 클리어 루프에 **`unique` 여부를 보는 분기가 없다**(`0x1401ee440`–`0x1401ee4fe`).
`clear` 키가 없는 FBO 도 `+0x14..+0x20` 이 파스에서 0 으로 남아 있어 (0,0,0,0) 으로 비워진다.

### 4.3 이 이펙트에서 실제로 무슨 그림 차이가 나는가

전제: 조건부 `_rt_SmokeNormal` 은 출하 콘텐츠에서 항상 빠지지만 **배열 끝(인덱스 8)** 이라
0..7 의 인덱스는 흔들리지 않는다.

**`clearVelocity`** — 인덱스 `[0,1]` 과 "앞에서 2장" 이 우연히 같다. **의도대로 동작한다.**

**`clearDye`** — 의도는 `fbos[6],[7]`(염료), 실제는 `fbos[0],[1]`(속도). 화면에서:

| | 의도된 그림 | 실제 그림 |
|---|---|---|
| 즉시 | 연기/염료가 **한 프레임에 사라진다**. 속도장은 그대로라 새로 주입된 염료가 즉시 기존 흐름을 타고 흐른다 | 화면의 연기는 **그대로 남고**, 흐름이 **멎는다**(속도 0) |
| 다음 프레임들 | 에미터가 새 염료를 뿌리며 정상 진행 | 염료가 제자리에서 지수 감쇠만 한다: 속도 0 → 역추적 `coord = u` → `dye ← dye/(decay+lowPass)`. 기본값 60 fps 에서 `decay = 1+1·0.4·0.0167 = 1.0067`(프레임당 0.66 %), 밝기가 `u_Lifetime` 아래로 떨어지면 `lowPass` 가 붙어 `÷1.5`(프레임당 33 %)로 급감 |
| 흐름 복귀 | — | 점/선 에미터가 켜져 있으면 **다음 프레임에 즉시** 속도가 다시 주입돼 흐름이 재개된다. 에미터가 0 개(커서 전용 세팅)면 커서를 움직일 때까지 정지 |
| 숨은 킥 | — | **압력장(`fbos[2],[3]`)은 안 비워진다.** 다음 프레임 패스 13 이 속도 0 에서 직전 프레임의 `−∇p` 를 그대로 빼므로 **한 프레임짜리 역방향 "퍽"** 이 생긴다. 압력은 ×0.8/(1/60 s) 로 감쇠하므로 ~20 프레임(0.3 s)에 걸쳐 잦아든다 |

한 줄로: **"염료 지우기" 버튼이 "흐름 정지 + 살짝 반동" 버튼이 된다.**
그리고 `clearVelocity` 와 `clearDye` 는 **완전히 같은 일**을 한다(둘 다 n=2).

### 4.4 누가 부르는가 — 확정

**죽은 코드가 아니다. 에디터 UI 전용도 아니다. 씬 스크립트(워크샵) 전용이다.**

근거 셋:

1. **등록 지점**. `0x1401efca0`–`0x1401f01b0` 이 이펙트 객체의 스크립트 메서드 표를 짓는다.
   `0x1401f0156` 이 이름 `"executeMaterialFunction"`(길이 `0x17`, 문자열 `0x1404908f0`)을 심고
   `0x1401f016c` 가 네이티브 포인터 `0x1401ee3a0` 을, `0x1401f0173` 이 인자 수 1 을 넣는다.
   같은 표의 이웃: `visible`(`0x1401efd4f`) · `name`(`0x1401efe21`) ·
   `getMaterial`(`0x1401efee6`) · `getMaterialCount`(`0x1401effb0`) ·
   `setMaterialProperty`(`0x1401f006f`, 핸들러 `0x1401ee1d0`).
2. **공개 선언**. WE 가 배포하는 에디터 자동완성 정의
   `ui/dist/monaco/autocomplete/lib.sceneScript.d.ts:1295` 에
   `executeMaterialFunction(propertyName: String): void;` 가 `IEffect` 멤버로 실려 있다.
3. **자산 도달 0**. 설치본 전수 grep 에서 `executeMaterialFunction` 을 담은 파일은 그 `.d.ts`
   하나와 실행 파일 6개(`wallpaper{32,64}.exe`, `distribution/` 사본, `bin/wallpaperui.exe`,
   그 사본)뿐이다. **씬 스크립트도, `project.json` 도, 어떤 JSON 도 부르지 않는다.**
   `clearVelocity`/`clearDye` 문자열도 `assets/effects/fluidsimulation/effect.json` **한 곳**
   에만 있고 **어떤 바이너리에도 없다**(ASCII·UTF-16LE 양쪽 0건) — 저작자가 지은 이름이다.

`wallpaperui.exe` 에도 같은 문자열이 있지만, 에디터가 엔진과 같은 스크립트 바인딩 등록 코드를
공유하는 것으로 설명되고 **"에디터에 버튼이 있다" 는 증거는 못 찾았다**([미해결]).

**판정**: `functions` 는 워크샵 저작자가 씬 스크립트에서
`thisObject.executeMaterialFunction('clearDye')` 로 부르라고 있는 **공개 API 의 자산 측 절반**이다.
WE 자신은 한 번도 쓰지 않는다. 그래서 이 결함이 지금까지 아무에게도 안 걸렸다 —
**출하 콘텐츠에서는 절대 실행되지 않는 경로**다.

### 4.5 결함에서 파생되는 두 위험

1. **일반화**. `functions` 항목이 옳게 동작하려면 그 `fbos` 목록이 **`fbos` 배열의 접두(prefix)를
   집합으로 덮어야** 한다(순서는 무관 — 값을 안 읽으므로). 그렇지 않은 워크샵 이펙트는 전부
   엉뚱한 버퍼를 비운다.
2. **범위 밖 접근 가능성**. 파서가 중복 이름을 걸러내지 않으므로
   `"fbos": ["_rt_A","_rt_A", … 20회]` 같은 선언은 `n = 20 > |fbos|` 를 만들고, 소비 루프는
   `fbos.begin + 80·i` 를 **경계 검사 없이** 읽어 vtable 호출까지 간다(`0x1401ee451` →
   `0x1401ee468`). 워크샵 `effect.json` 은 신뢰 경계 밖이므로 실물에서는 **크래시 벡터**다.
   Waple 은 파스된 실인덱스를 쓰고 `materialFunctionClearTargets(_:table:fboCount:)`
   (`SceneRendererResources.swift:154-163`)가 `0..<fboCount` 로 한 번 더 자르므로 면역이다.

> **[미해결] 파서 쪽 잠재 결함 하나.** 이름 탐색 커서 `esi` 가 `0x1401e85fb` 에서 `r13d` 로
> **시드**되는데, `r13d` 를 0 으로 되돌리는 `xor r13d, r13d`(`0x1401e87e3`)를 건너뛰는 경로가
> 하나 있다(`0x1401e85f2` 의 긴-문자열 해제 분기 → `0x1401e87e6`). 커서가 이월되면 배열 뒤쪽
> 이름이 앞쪽 fbo 를 못 찾아 개수가 줄 수 있다. **이 이펙트에서는 두 목록 모두 인덱스가
> 오름차순(0,1 / 6,7)이라 어느 쪽이든 n=2 로 같다** — 그래서 그림에는 영향이 없다.

### 4.6 Waple 의 현재 선택

Waple 은 **결함을 재현하지 않는다** — 파스된 실인덱스를 쓴다. 그 결정과 근거가
`SceneRendererFrameEncoder.swift:2114-2122` 에 `[미해결]` 로 명시돼 있다.

이 문서의 판단: **재현하지 않는 쪽이 맞다.** 이유 셋 —
① 출하 콘텐츠 도달 0 이라 "충실 재현" 이 지킬 그림이 없다.
② 워크샵 저작자가 이 API 를 쓴다면 그가 기대하는 것은 **이름이 가리키는 버퍼**다(에디터
자동완성이 그렇게 광고한다). 결함을 흉내내면 Waple 만 "왜 안 지워지지" 가 된다.
③ §4.5 의 범위 밖 접근을 그대로 옮기면 신뢰 경계 밖 입력으로 크래시한다.
다만 **의도적 이탈**이므로 `docs/re/unimplemented-json-keys.md` 계열의 이탈 대장에 올려 둘 값어치는 있다.

---

## 5. 마우스 / 시간 입력

### 5.1 정점 — 커서 언프로젝션 (`fluidsimulation_vorticity.vert:47-99`)

```glsl
vec2 pointer     = g_PointerPosition;      pointer.y     = 1.0 - pointer.y;
vec2 pointerLast = g_PointerPositionLast;  pointerLast.y = 1.0 - pointerLast.y;
vec4 preTransformPoint     = vec4(pointer     * 2 - 1, 0.0, 1.0);
vec4 preTransformPointLast = vec4(pointerLast * 2 - 1, 0.0, 1.0);
v_PointerUV.xyz     = mul(preTransformPoint,     g_EffectTextureProjectionMatrixInverse).xyw;
v_PointerUV.xy     *= 0.5;   v_PointerUV.xy     /= v_PointerUV.z;
v_PointerUVLast.xyz = mul(preTransformPointLast, g_EffectTextureProjectionMatrixInverse).xyw;
v_PointerUVLast.xy *= 0.5;   v_PointerUVLast.xy /= v_PointerUVLast.z;
v_PointerUV.w = g_Texture0Resolution.y / -g_Texture0Resolution.x;
float moveAmt = length(g_PointerPosition - g_PointerPositionLast);
v_PointDelta.x = step(0, moveAmt) * 0.5 + moveAmt * 10.0 * u_CursorInfluence;
v_PointDelta.y = 60.0 / max(0.0001, u_CursorInfluence);
v_PointerUV.w *= -v_PointDelta.y;
v_PointerUVLast.w = v_PointerUV.w;
v_PointerUV.xy += 0.5;      v_PointerUV.y     = 1.0 - v_PointerUV.y;      v_PointerUV.z = 1;
v_PointerUVLast.xy += 0.5;  v_PointerUVLast.y = 1.0 - v_PointerUVLast.y;  v_PointerUVLast.z = 1;
```

두 번의 y-플립은 **상쇄되는 실수가 아니라 NDC 왕복**이다:
텍스처 UV(y-down) → `1-y` → y-up → `2x-1` → NDC → `M` → `×0.5 +0.5` → [0,1] y-up → `1-y` →
텍스처 UV. **따라서 `M = I` 이면 결과가 정확히 `g_PointerPosition` 이고, 전화면·무회전
레이어에서는 그게 정답이다.** 회전·부분 배치·`orthogonalprojection` 스케일이 있는 레이어에서는
`M` 이 그 역변환을 담당한다.

파생 유니폼 두 개:

| varying | 식 | 뜻 |
|---|---|---|
| `v_PointDelta.y` | `60 / max(1e-4, u_CursorInfluence)` | 임펄스 반경의 **역수** — 반경 = `cursorinfluence/60` UV |
| `v_PointerUV.w` | `(H/−W) · (−60/CI)` = `(H/W)·60/CI` | y 축용 같은 역수(종횡비 보정) |
| `v_PointDelta.x` | `step(0, moveAmt)·0.5 + moveAmt·10·CI` | 임펄스 세기. `step(0, moveAmt)` 은 `moveAmt ≥ 0` 이라 **항상 1** → 상수항 0.5 |

기본 `cursorinfluence = 1` → 반경 1/60 ≈ 0.0167 UV. preview 의 4 → 0.0667 UV.

### 5.2 프래그먼트 — 임펄스 (`fluidsimulation_vorticity.frag:161-207`, `#if INTERACTIVE`)

```glsl
vec2 lDelta   = v_PointerUV.xy - v_PointerUVLast.xy;
vec2 texDelta = v_TexCoord.xy  - v_PointerUVLast.xy;
float distLDelta = length(lDelta) + 0.0001;   lDelta /= distLDelta;
float distOnLine = dot(lDelta, texDelta);
float rayMask = max(step(0.0, distOnLine) * step(distOnLine, distLDelta), step(distLDelta, 0.1));
distOnLine = saturate(distOnLine / distLDelta) * distLDelta;
vec2 posOnLine = v_PointerUVLast.xy + lDelta * distOnLine;
vec2 d = (v_TexCoord.xy - posOnLine) * vec2(v_PointDelta.y, v_PointerUV.w);
float pointerDist = saturate(1.0 - length(d)) * rayMask * rippleMask;
float inputStrength = pointerDist * 1.0 * (v_PointDelta.x + g_PointerState.z);
velocity += lDelta * inputStrength * 300;
```

```
v += 300 · d̂ · cone · strength
  d̂       = normalize(p_now − p_last)              커서 이동 방향
  p_seg    = p_last + d̂ · clamp(dot(d̂, u − p_last), 0, |Δp|)     선분 최근접점
  cone     = saturate( 1 − ‖ (u − p_seg) ⊙ (60/c, (60/c)·(H/W)) ‖ ) · rayMask · rippleMask
  strength = 0.5 + 10·c·‖Δp‖ + g_PointerState.z        c = u_CursorInfluence
```

* `p_seg` = 이전→현재 커서 **선분 위의 최근접점**. 프레임 간 커서 점프에도 선을 그리며 힘을
  주도록 하는 장치다(cursorripple 과 같은 관용).
* `rayMask`: `step(distLDelta, 0.1)` 이 있어 **이동량이 0.1 UV 이하면 선분 제한이 꺼진다**
  (평상시는 항상 1). 큰 점프에서만 선분 밖을 잘라낸다.
* 방향은 커서 이동 방향 `lDelta`(정규화). **커서가 멈춰 있으면 `lDelta ≈ 0/1e-4 = 0`** 이라
  세기의 상수항 0.5 와 클릭 항이 있어도 힘이 0 이다.
* `g_PointerState.z` = 좌버튼 힘(미클릭 0). 클릭 중이면 세기에 그대로 더해진다.
* 최종 배율 **300**(텍셀/초 단위).

### 5.3 시간 입력

| 유니폼 | 쓰는 곳 | 값 규약 |
|---|---|---|
| `g_Frametime` | vorticity(dt) · advection(dt, 중력, 에미터) · clear.vert(감쇠 지수) | **초 단위 프레임 델타**. WE 는 그대로, Waple 은 `frameDelta` 로 0…50 ms 클램프 후 `eng.timeAndPad.w` |
| `g_Time` | vorticity.frag:151 — 선 에미터 노이즈 스크롤 `uv*0.1 + g_Time*0.01` | 씬 경과 초 |

`g_Time` 은 `#if LINEEMITTER >= 1` 안에서만 쓰인다.

### 5.4 에미터 (커서와 별개의 상시 입력)

**속도 에미터**(vorticity.frag) — 감쇠 없는 **하드 디스크**:

```glsl
vec2 EmitterVelocity(texCoord, aspect, position, angle, size, speed) {
    vec2 delta = position - texCoord;          //  delta.y *= aspect  ← 주석 처리됨
    float amt = step(length(delta), size) * speed;
    return vec2(sin(angle), -cos(angle)) * amt;   //  emitterSpeed.y *= aspect  ← 주석 처리됨
}
// 호출: EmitterVelocity(..., g_Frametime * m_EmitterSpeedN)
```

```
v += (sin θ, −cos θ) · F · Δt · [ ‖p − u‖ ≤ r ]     θ=emitterAngle, F=emitterSpeed, r=emitterSize
```

**`aspect` 는 인자로 받지만 두 줄 다 주석 처리돼 쓰이지 않는다** — 즉 속도 에미터의 디스크는
UV 상 원, **화면상으로는 타원**이다(원본 그대로).

**선 에미터** — 선분까지의 거리 + 노이즈 게이트:

```glsl
float amt = step(length(delta), size) * g_Frametime * speed;
vec2 emitterSpeed = vec2(sin(angle), -cos(angle)) * amt;
emitterSpeed *= step(CAST2(0.5), noise);      // noise = tex(util/noise, uv*0.1 + g_Time*0.01).rg
```

노이즈 게이트가 **성분별**(x·y 독립)이라 선을 따라 힘이 얼룩덜룩 켜졌다 꺼진다 —
preview 의 "바닥에서 피어오르는 연기" 가 그 결과다.

**염료 에미터**(advection.frag, `#if DYE`) — 이쪽은 **`aspect` 를 쓴다**:

```glsl
vec2 delta = position - texCoord;  delta.y *= aspect;
float amt = smoothstep(size, 0.0, length(delta));      // edge0 > edge1 → 중심 1, 반경 0
```

즉 **속도 주입은 타원, 색 주입은 화면상 원**이다(원본 비대칭).
`smoothstep(size, 0.0, x)` 는 edge0 > edge1 인 역방향 호출이라 GLSL/HLSL 명세상 "정의되지
않음" 이지만 두 백엔드 모두 `clamp((x-e0)/(e1-e0))` 로 계산해 의도대로 동작한다 — **이식 시
`1 - smoothstep(0, size, x)` 로 "고치면 안 된다"**(감쇠 곡선이 다르다).

---

## 6. Waple 갭 — 이걸 지금 로드하면 무엇이 깨지는가

읽은 파일: `Sources/WapleCore/EffectManifest.swift`(564줄) ·
`Sources/WapleRender/SceneRendererResources.swift`(2,501줄) ·
`Sources/WapleRender/SceneRendererFrameEncoder.swift`(2,358줄) ·
`Sources/WapleCore/ShaderPreprocessor.swift` · `Sources/WapleCore/GLSLTranslator.swift`.

### 6.1 지원 / 미지원 전수표

| # | 축 | 실물 | Waple | 판정 | 착지 |
|---:|---|---|---|---|---|
| 1 | 트레일링 콤마 JSON | 관대 파스 | `parse` 가 엄격 실패 시 `AssetJSON.relaxed` 재시도 | **지원** | `EffectManifest.swift:345-350` |
| 2 | `fbos[].format` 19종 | 해시맵 + 백버퍼 치환 | 동일 enum + `metalFormat` | **지원** — `rg1616f→.rg16Float`, `r16f→.r16Float`, `rgba_backbuffer→HDR? .rgba16Float : .rgba8Unorm` | `SceneRendererResources.swift:1621-1637` |
| 3 | `fbos[].unique` | 인스턴스별 지속 RT | `UniqueFBOStore`(인스턴스 1개) + 1 GiB 예산 | **지원** | `SceneRendererResources.swift:92-108` · `FrameEncoder.swift:2013-2075` |
| 4 | `fbos[].clear` | 스페이스 4성분, 생성 시 | 동일(빈 문자열=0, 3성분 거부) | **지원** | `EffectManifest.swift:530-545` |
| 5 | **`fbos[].fit`** | **긴 변 N, 종횡비 보존** | **N×N 정사각** | **✘ 불일치** | `EffectManifest.swift:399-402` |
| 6 | `fbos[].scale` | dst/scale | 동일 | 지원 | `FrameEncoder.swift:2030-2031` |
| 7 | `command:"swap"` | 포인터 교환 | `fboTex.swapAt` | **지원** | `SceneRendererResources.swift:899-916` |
| 8 | 씬 pass 인덱스 = 원본 배열 인덱스 | 명령 패스도 슬롯 소비 | `enumerated()` 로 동일 | **지원**(preview 18/18 검증, §1.4) | `SceneRendererResources.swift:734-757` |
| 9 | `conditions`(fbo/pass/bind) | 좌변 = `effects[].combos` | 동일, `comboValue` 로 태그 1/2/3 만 | **지원** | `EffectManifest.swift:466-505` · `SceneDocument.swift:3052-3062` |
| 10 | `functions` 파스 | action `clear` 만, 이름→인덱스 | 동일 | **지원** | `EffectManifest.swift:427-455` |
| 11 | `functions` 소비 | **개수만 쓰는 결함** | 실인덱스 사용 | **의도적 이탈**(§4.6) | `FrameEncoder.swift:2114-2127` |
| 12 | `executeMaterialFunction` 스크립트 API | 네이티브 즉시 클리어 | JS 적재 → 드레인 → pendingClear | **지원** | `TextScriptEngine.swift:2509-2531` |
| 13 | `blending:"normal"` = 블렌딩 OFF | BlendEnable FALSE | 이펙트 파이프라인이 블렌드 미설정 | **일치**(우연히 정합) | `docs/re/material-blend.md` B3 |
| 14 | `#require LightingV1` | LIGHTING≠0 이면 코드 생성·삽입 | **줄만 소비**, 주입 없음 | **부분** — LIGHTING=0 은 정확 일치, LIGHTING≠0 은 MSL 컴파일 실패 → 이펙트 폴백 | `ShaderPreprocessor.swift:274-329` |
| 15 | `g_Frametime` / `g_Time` | 프레임 델타 / 경과 | `eng.timeAndPad.w` / `.x` | 지원(캡처는 1/30 고정) | `GLSLTranslator.swift:1408` |
| 16 | `g_PointerPosition{,Last}` · `g_PointerState` | 커서 UV(y-down) · 버튼 힘 | `eng.timeAndPad.yz` · `pointerLastAndPad.xy/.z` | **지원** | `GLSLTranslator.swift:1405-1411` · `SceneRenderer.swift:785-788` |
| 17 | `g_EffectTextureProjectionMatrixInverse` | 레이어 배치의 역투영 | `float4x4(1.0)` | **부분** — 전화면·무회전이면 정답(§5.1), 회전/부분 레이어는 임펄스가 어긋난다 | `GLSLTranslator.swift:1421` |
| 18 | `g_TextureNResolution` | `(paddedW,paddedH,imgW,imgH)` | fbo 는 `(w,h,w,h)` | 규약 일치(이 이펙트의 슬롯은 전부 렌더타깃이라 패딩 없음). **다만 값은 W1 때문에 틀린다** — `fit` FBO 슬롯에서 `(256,256,…)` 이 실려 `aspect`/`texelSize` 가 어긋난다 | `SceneRendererResources.swift:1185-1195` |
| 19 | 샘플러 어노테이션 `"default"`(`util/noise`, `gradient/gradient_fire`) | 자산 로드 | `t.textureDefaults[slot]` 폴백 + 이펙트 로컬 루트 | **지원**, 두 자산 모두 동봉에 존재 | `SceneRendererResources.swift:1226` |
| 20 | `mul(v,M)` HLSL 순서 | 행벡터 | `(b*a)` | 지원 | `GLSLTranslator.swift:1633-1636` |
| 21 | `inverse(mat3)`(common_perspective.h, `#if HLSL`) | HLSL 분기 컴파일 | `HLSL=1` 시딩 + `inverse→we_inverse` 리네임. 헤더 정의는 `inverse` 이름 그대로 방출되고 호출부만 `we_inverse` 로 가므로 **중복 정의 없음**(헤더 쪽은 죽은 함수) | 지원 | `ShaderPreprocessor.swift:38` · `GLSLTranslator.swift:1587,1943,2001` |
| 22 | `ddx`/`ddy`/`frac`/`saturate`/`CAST*`/`texSample2D` | HLSL 방언 | 전건 매핑 | 지원 | `GLSLTranslator.swift:1586-1690` |
| 23 | 조건문(`if (vL.x < 0.0) {...}`) · 다중 varying(vec2/vec3/vec4×3) | — | 본문 통과 + 타입 어댑터 | 지원 | — |
| 24 | 압력 9회 = 파이프라인 18개 | — | 패스별 `MTLRenderPipelineState` 18개(같은 셰이더 9개는 같은 MSL 이지만 별개 파이프라인) | 지원, 비용 축 | — |

### 6.2 판정 — 이걸 지금 로드하면

**돈다. 다만 두 군데가 틀리고 한 조건에서 통째로 폴백한다.**

**W1 (P0) `fit` 종횡비 — 조용히 틀린 그림.**
`EffectManifest.swift:399-402` 이 `fixedW = clampedFixed(f["fit"]); fixedH = fixedW` 로
정사각을 만든다. 1920×1080 에서 WE 는 **256×144**, Waple 은 **256×256**. 귀결 넷 —

1. `aspect = g_Texture0Resolution.y/.x` 가 **0.5625 대신 1.0**. 염료 에미터(§5.4)의 원이
   **가로로 16:9 만큼 늘어난다**. 중력(`constantSpeed.y *= aspect`)도 세로 성분이 1.78배 세진다.
2. 텍셀이 화면에서 정사각이 아니게 되어 **유한차분 솔버 전체가 이방성**을 얻는다.
   같은 속도 벡터가 x 로는 1920/256 = 7.5 px, y 로는 1080/256 = 4.2 px 를 움직인다 —
   흐름이 가로로 1.78배 늘어져 보인다.
3. 커서 임펄스 반경도 `v_PointerUV.w = (H/W)·60/CI` 가 1·60/CI 가 되어 **세로로 찌그러진다**.
4. 메모리: 256×144 → 256×256 은 속도/압력/발산/컬 6장에서 1.78배(작은 절대량이라 무해).

착지: `EffectManifest.swift:399-402` 을 dst 비례 계산으로 옮기거나(파스 시점엔 dst 를 모르므로)
`FBO` 에 `fitBox: Int?` 를 새로 두고 소비처
`SceneRendererFrameEncoder.swift:2030-2031` · `SceneRendererResources.swift:1186-1190`
두 곳에서 `W0>=H0 ? (min(fit,W0), H0*W'/W0) : (W0*H'/H0, min(fit,H0))` 로 푼다
(절삭은 `Int(Float)` = 0 방향, `0x1401eb33b` 의 `cvttss2si` 와 같게). `width`/`height` 명시가
있으면 그것이 `W0/H0` 를 대신한다는 점(§1.3 의사코드)도 함께 옮겨야 한다.
`fit` 보유 동봉 이펙트는 `fluidsimulation` 6장 + `cursorripple` 2장(`fit:512`)이므로
회귀 표면이 좁다.

**W2 (P1) `LIGHTING=1` → 이펙트 통째 폴백.**
`ShaderPreprocessor.swift:274-329` 가 `#require` 줄을 **소비**하는 것까지는 실물과 같지만
`LIGHTING≠0` 일 때의 코드 생성은 미구현이다. 그러면 `combine.frag:116` 의
`PerformLighting_V1(...)` 호출부가 미정의로 남아 MSL 컴파일이 실패하고
`SceneRendererResources.swift:766-768` 가 이펙트를 통째로 버린다.
**"조용히 틀린 그림" 이 아니라 "시끄러운 폴백" 이므로 현행 선택은 옳다.**
도달 조건: 사용자가 에디터에서 Lighting 을 켜 `passes[17].combos.LIGHTING = 1` 이 실리는 경우.
출하 콘텐츠 도달 0.

착지(2단계): ① `ScenePBRLighting.swift` 의 계산을 재사용해
`vec3 PerformLighting_V1(worldPos, color, normal, viewVector, specularTint, f0, roughness, metallic)`
스텁을 주입하고, ② 라이트 배열(`g_LPoint_*` 등)을 렌더러가 씬 라이트로 채운다.
②가 없으면 길이 0 배열 + 검은 라이팅이 되므로 **①만 먼저 넣으면 안 된다**(현행 주석이 그 이유를 이미 적어 뒀다).

**W3 (P2) `g_EffectTextureProjectionMatrixInverse` 항등.**
§5.1 대로 전화면·무회전 레이어에서는 정답이다. preview 씬은 256×256 정사각 레이어 + 오르토라
정답 범위 안이다. 회전·부분 배치 레이어에서 커서 임펄스가 엉뚱한 자리에 찍힌다.
`PERSPECTIVE==1` 의 `rippleMask`(수평선 밖 차단)도 함께 무력해진다.

**W4 (P3) 유니폼 이름 축 정정.** `docs/re/shader-uniforms.md` §7.3 순위 2·3 이
`g_LightsPosition`/`g_LightsColorPremultiplied` 의 "저작레인 도달" 을 이 이펙트 **본체**로
적었는데 실제로는 **preview 사본 전용**이다(§1.1). 본체의 라이팅은 `#require` 가 생성하는
다른 유니폼 계열을 쓴다. **우선순위 표의 2·3위가 실제 도달 없는 항목**이라는 뜻이므로
그 문서 소유자가 재산정할 필요가 있다.

**깨지지 않는 것들**(확인해 둔다): `swap` · `unique` 지속 · `clear` 1회 · 9회 Jacobi 의
포맷별 파이프라인(`.rg16Float`/`.r16Float` 타깃) · 씬 오버라이드 18슬롯 정렬 ·
`conditions` 전건 false · `util/noise`/`gradient_fire` 해석 · 트레일링 콤마 ·
`blending:"normal"` = 덮어쓰기 · `functions` 파스와 스크립트 왕복.

---

## 7. Metal 이식 난이도 (패스별)

| 패스 | 난이도 | 이유 |
|---|---|---|
| curl · divergence · gradientsubtract | **하** | 4-탭 유한차분, 분기 없음. `if` 4개(divergence)는 그대로 옮겨진다. 이미 번역기로 통과할 형태 |
| pressure(Jacobi ×9) | **하** | 5-탭 산술. 다만 **같은 셰이더로 9개 파이프라인**을 만들게 되므로 파이프라인 캐시(같은 MSL + 같은 타깃 포맷)를 안 넣으면 콜드 스타트가 9배다 |
| clear(압력 감쇠) | **하** | `pow` 한 번. `v_TexCoord` 가 `vec3` 인 것만 주의(다른 패스와 이름은 같고 타입이 다르다 — 스테이지 쌍 안에서는 일관) |
| normal | **하** | 3-탭 전진차분 |
| vorticity(frag) | **중** | 산술 자체는 쉽다. 어려운 건 **콤보 조합** — `POINTEMITTER`(0..4) × `LINEEMITTER`(0..3) × `INTERACTIVE` × `PERSPECTIVE` 로 퍼뮤테이션이 40종. `util/noise` 텍스처 슬롯 기본값 해석과 `g_Time` 스크롤도 필요 |
| vorticity(vert) | **중상** | `g_EffectTextureProjectionMatrixInverse` 실값이 필요하다(W3). `mul` 인자 순서, `.xyw` 스위즐 뒤 원근 나눗셈, 두 번의 y-플립 — **한 군데만 틀려도 임펄스가 화면 반대편에 찍힌다**. 검증은 "커서 위치에 힘이 생기는가" 라는 눈 판정뿐이라 디버깅이 비싸다 |
| advection (velocity + dye, 같은 셰이더) | **중상** | `DYE` 로 갈리는 두 인스턴스 + `RENDERING` 3분기 × `POINTEMITTER`/`LINEEMITTER` × `COLLISIONMASK`/`DYEEMITTER`/`PERSPECTIVE`. 그리고 **`g_Texture0Resolution` 이 염료 패스에서도 속도 해상도**라는 규약을 놓치면 이류 거리가 2배 틀린다. `smoothstep(edge0>edge1)` 역방향 호출을 "고치지 않는" 규율도 필요 |
| combine | **상** | 셋이 겹친다: ① `BLENDMODE` 33종(`common_blending.h` 전체) ② `#require LightingV1` 코드 생성 + 라이트 배열 피드(= W2, 이 리포에서 가장 큰 미착지 블록) ③ `RENDERING==3` 의 `ddx`/`ddy` 화면공간 미분(이펙트 체인 안에서 dst 해상도 기준이라 스케일드 FBO 와 섞이면 규약이 흔들린다). 게다가 유일하게 MVP 를 쓰는 패스다 |
| **자원 관리 전체** | **중** | `unique` 8장 지속 + swap + `fit` 종횡비 + 포맷별 타깃. Waple 은 이미 대부분 갖췄고 남은 건 W1 하나다 |

가장 싼 착지 순서: **W1(fit) → W3(투영행렬) → W2(LightingV1)**.
W1 은 순수 산술이라 리눅스 레인에서 단위 테스트로 닫히고, 그림 개선폭이 가장 크다.

---

## 8. 배제한 가설

1. **"`fit` 은 정사각 N×N 이다."** — `0x1401eb30c`–`0x1401eb377` 의 두 갈래 비율 계산
   (`cvtsi2ss`/`divss`/`mulss`/`cvttss2si`)이 반증한다. 정사각이면 이 여섯 명령이 통째로
   불필요하다. 또 셰이더가 `aspect = res.y/res.x` 를 실제로 소비하는 자리가 세 곳(중력·염료
   에미터·커서 반경)인데 정사각이면 그 세 줄이 전부 무의미해진다.
2. **"`clear` 는 매 프레임 실행된다."** — 코드 위치(생성·리사이즈 양 경로 뒤)만 보면 그럴듯하나,
   `clear` 를 가진 6장이 전부 프레임 간 누적 버퍼라 매 프레임 0 이면 이 이펙트가 어떤 그림도
   못 만든다. 호출 빈도 자체는 못 짚었으므로 §3.3 에 [미해결] 로 남겼다.
3. **"`functions` 는 에디터 UI 버튼용이다."** — `wallpaperui.exe` 에 문자열이 있는 건 사실이나,
   결정적 증거는 반대쪽에 있다: 이름이 `IEffect` 의 **스크립트 메서드 표**에 등록되고
   (`0x1401f0156`+`0x1401f016c`, 인자 1개) WE 가 배포하는 씬 스크립트 `.d.ts` 에 공개 선언돼
   있다. 에디터 전용이라면 `.d.ts`(= 워크샵 저작자용 자동완성)에 실을 이유가 없다.
4. **"`g_LightsPosition` 이 fluidsimulation 본체에서 쓰인다"**(기존 정본 §7.3) — 본체 5줄이
   전부 `//` 주석이다(§1.1). preview 사본과 뒤바뀐 기재다.
5. **"vorticity.vert 의 두 y-플립은 상쇄되는 버그다."** — NDC(y-up) ↔ 텍스처(y-down) 왕복이라
   설계상 필요하다(§5.1). 하나만 지우면 임펄스가 상하 반전된다.
6. **"`gradientsubtract` 의 0.5 누락은 오타다."** — curl/divergence 에는 0.5 가 있고 여기만
   없는 건 사실이나, 참조 구현과 동일하고 "2배 과이완" 이라는 일관된 물리적 해석이 있다.
   고치면 유체가 눈에 띄게 끈적해진다 = 원본과 다른 그림. 그대로 옮긴다.
7. **"`RENDERING==3` 의 `g_Texture4` 는 압력장이다"**(셰이더 변수 이름) — 매니페스트가
   슬롯 4 에 묶는 것은 `_rt_SmokeVelocity2` 다(§1.4). 어떤 패스도 압력 버퍼를 슬롯 4 에
   묶지 않는다.

---

## 9. 확정하지 못한 것

1. **[미해결] `clear` 실행 빈도**(§3.3). 기구는 `0x1401eba2c`–`0x1401ebadf` 로 확정했으나,
   그 코드를 품은 `0x1401ea500` 이 vtable 슬롯(`0x140490540`)이라 호출 빈도를 못 짚었다.
   함수적 배제(매 프레임일 수 없다)만 세웠다.
2. **[미해결] `fit` × `scale` 동시 선언**의 해석. 이 이펙트에 사례가 없고
   `createRenderTarget`(`0x1401aadb0`)이 `scale` 을 가상호출 `[[dev]+0x70]` 로 넘겨서
   내부 처리를 못 열었다.
3. **[미해결] 에디터가 `LIGHTING` 을 `effects[].combos` 에도 쓰는가**(§1.5).
   출하 씬 184개에 `effects[].combos` 가 0건이라 역산 불가. 안 쓴다면 WE 자신도
   `LIGHTING=1` 에서 `g_Texture2` 미바인드로 돈다.
4. **[미해결] `functions` 파서의 탐색 커서 이월**(§4.5 각주). `0x1401e85fb` 가 `esi` 를
   `r13d` 로 시드하는데 `xor r13d,r13d`(`0x1401e87e3`)를 건너뛰는 경로가 하나 있다.
   이 이펙트에서는 두 목록 모두 오름차순이라 결과가 같아 판별이 안 된다.
5. **[미해결] `wallpaperui.exe` 의 `executeMaterialFunction` 용례.** 엔진과 공유하는 스크립트
   바인딩 등록으로 설명되지만, 에디터 UI 에 "리셋" 버튼이 있는지는 확인하지 않았다
   (에디터 바이너리는 이 조사 범위 밖).
6. **[미해결] `attachmentproject` / `attachmentangles` 어노테이션**(본체 vorticity.frag 의
   `m_EmitterPos*`·`m_LineEmitterPos*` 12건). preview 사본에는 없는 신규 키이고
   `wallpaper64.exe` 문자열 스캔에서 확인하지 않았다. 퍼펫/어태치먼트에 에미터를 붙이는
   에디터 기능으로 보이나 런타임 소비 여부 미확정.
7. **[미해결] 워크샵 코퍼스에서의 실제 사용 분포.** 이 컨테이너에 워크샵 pkg 가 없어
   `functions`/`executeMaterialFunction`/`effects[].combos` 의 실사용 빈도를 못 쟀다.
   설치본만으로는 "출하 콘텐츠 도달 0" 까지가 한계다.

---

## 부록 A — 재현 절차

전부 리포 밖 원본만 읽는다:
`/root/.claude/uploads/…/440072bd-wallpaper64.exe` · `/home/user/Waple-wallpaper-source/wallpaper_engine/`.

```bash
WE=/home/user/Waple-wallpaper-source/wallpaper_engine
FX=$WE/assets/effects/fluidsimulation

# ① 동봉 사본이 설치본과 바이트 동일한지
diff -rq /home/user/Waple/Sources/WapleRender/Resources/WEAssets/effects/fluidsimulation "$FX"

# ② preview 사본이 다른 스냅샷임을 확인 (§1.1)
diff "$FX/effect.json" "$FX/preview/effects/fluidsimulation/effect.json"
diff -rq "$FX/shaders" "$FX/preview/shaders"

# ③ effect.json 전수 — functions / conditions / 엄격 파스 실패
python3 - "$WE" <<'PY'
import os,sys,json,re
def relaxed(t):
    try: return json.loads(t)
    except Exception: pass
    t=re.sub(r'//[^\n]*','',t); t=re.sub(r',(\s*[}\]])',r'\1',t)
    try: return json.loads(t)
    except Exception: return None
n=fail=0; fn=[]; cnd=[]
for dp,_,fs in os.walk(sys.argv[1]):
    for f in fs:
        if f!='effect.json': continue
        p=os.path.join(dp,f); n+=1
        t=open(p,encoding='utf-8',errors='replace').read()
        try: json.loads(t)
        except Exception: fail+=1
        d=relaxed(t)
        if isinstance(d,dict):
            if 'functions' in d: fn.append(p)
            if '"conditions"' in json.dumps(d): cnd.append(p)
print(n, '엄격실패', fail, 'functions', len(fn), 'conditions', len(cnd))
PY
# 기대: 135 엄격실패 27 functions 1 conditions 2   (동봉만 세면 128 / 27 / 1 / 2)

# ④ 씬 전수에 effects[].combos 가 있는가 (§1.5)  → 기대: scenes 184 / hits 0
#    주의: 그냥 grep '"combos"' 하면 **패스 레벨** combos 60건이 잡혀 반대 결론이 난다.
python3 - "$WE" <<'EOF4'
import os,sys,json,re
def relaxed(t):
    try: return json.loads(t)
    except Exception: pass
    t=re.sub(r'//[^\n]*','',t); t=re.sub(r',(\s*[}\]])',r'\1',t)
    try: return json.loads(t)
    except Exception: return None
n=0; hits=[]
for dp,_,fs in os.walk(sys.argv[1]):
    if 'scene.json' not in fs: continue
    d=relaxed(open(os.path.join(dp,'scene.json'),encoding='utf-8',errors='replace').read())
    if not isinstance(d,dict): continue
    n+=1
    for o in d.get('objects') or []:
        for e in (o.get('effects') or []) if isinstance(o,dict) else []:
            if isinstance(e,dict) and 'combos' in e: hits.append((dp, e.get('file')))
print('scenes', n, 'effect-level combos', len(hits))
EOF4

# ⑤ executeMaterialFunction 호출 자산 (§4.4)  → 기대: .d.ts 1건 + exe 6건, 씬 스크립트 0건
grep -rl 'executeMaterialFunction' "$WE"
grep -rl 'clearVelocity\|clearDye' "$WE"          # 기대: effect.json 한 건

# ⑥ 바이너리 — 세션 스크래치의 RE 도구. $SP 는 그 디렉터리(세션마다 다르다).
python3 "$SP/vdis2.py" 0x1401ee3a0 0x1401ee51c   # executeMaterialFunction 소비(결함)
python3 "$SP/vdis2.py" 0x1401e8248 0x1401e88a1   # functions 파서
python3 "$SP/vdis2.py" 0x1401e7440 0x1401e7969   # fbos[] 필드 파서(fit/scale/clear/unique/uvs)
python3 "$SP/vdis2.py" 0x1401eb2b0 0x1401eb3a0   # fit 종횡비 계산  ← §1.3 의 핵심
python3 "$SP/vdis2.py" 0x1401eba14 0x1401ebae0   # clear 실행 5-호출 시퀀스
python3 "$SP/vdis2.py" 0x1401effc0 0x1401f01b0   # 스크립트 메서드 등록표
python3 -c "import sys;sys.path.insert(0,'$SP');import wxref;print(wxref.funcs_of(0x1401e63b0))"
#   → {0x1401e7170: [0x1401e7405, 0x1401e79fe, 0x1401e7ed0]} — conditions 평가 3지점
```

게이트: `python3 scripts/spec/check_address_ranges.py` · `python3 scripts/spec/validate.py`
(둘 다 이 문서 작성 전후로 오류 0).

## 부록 B — 이 문서가 인용한 함수 범위

| 함수(가칭) | 범위 | 역할 |
|---|---|---|
| `Effect::parse` | `0x1401e7170`–`0x1401e814e` | `combos`(`0x1401e7319`) · `fbos`(`0x1401e735c`) · `passes` · `conditions` 3지점 |
| ↳ fbo 필드 파스 | `0x1401e7440`–`0x1401e7969` | `scale`/`fit`/`width`/`height`/`unique`/`clear`/`uvs`/`format`, 백버퍼 치환 `0x1401e7562` |
| ↳ clear 문자열 파스 | `0x1401e7629`–`0x1401e777b` | 스페이스 4성분, 성공 시 `+0x48` bit1 (`0x1401e7771`) |
| ↳ `functions` 파스 | `0x1401e8248`–`0x1401e88a1` | 키 사전순, action `clear` 고정, 이름→인덱스 선형탐색 `0x1401e8630`–`0x1401e867d` |
| `Effect::evalConditions` | `0x1401e63b0`–`0x1401e6976` | 맨몸=`==`, `ge/gt/le/lt`, 전부 AND, fail-open |
| `Effect::acquireRenderTargets` | `0x1401ea500`–`0x1401ebbb6` | `fit` 종횡비 `0x1401eb2cc`–`0x1401eb381` · unique 키 `0x1401eb38c` · 공유 키 `0x1401eb4fa` · 생성/리사이즈 `0x1401eb96a`–`0x1401eba28` · clear `0x1401eba2c`–`0x1401ebadf` |
| ↳ (호출자, vtable `0x140490538`) | `0x1401ea310`–`0x1401ea4e0` | 대상 크기 질의 → 위 루틴 |
| `Effect::createRenderTarget` | `0x1401aadb0`–`0x1401ab3d8` | 이름 해시 + 풀 조회 + `[[dev]+0x70]` 생성 |
| `Effect::executeMaterialFunction` | `0x1401ee3a0`–`0x1401ee51b` | 이름 선형탐색 `0x1401ee3d0`–`0x1401ee40a` · **개수만 뽑는 결함** `0x1401ee411`–`0x1401ee41b` · 클리어 루프 `0x1401ee440`–`0x1401ee4fe` |
| `Effect::setMaterialProperty` | `0x1401ee1d0`–`0x1401ee3a0` | 형제 스크립트 메서드(이 문서는 등록만 인용) |
| `Effect::registerScriptAPI` | `0x1401efca0`–`0x1401f01b0` | `visible`/`name`/`getMaterial`/`getMaterialCount`/`setMaterialProperty`/`executeMaterialFunction` |
| `Shader::generateLightingV1` | `0x140169140`–`0x14016b0d4` | `#require LightingV1` 코드 생성(인용만 — 정본은 `docs/re/shader-combos.md` §3.5) |
| jsoncpp `find` | `0x140086de0`– | 위 파서들의 키 조회 |
| jsoncpp `isIntegral` / `asInt` / `asBool` | `0x1400886e0`– / `0x140085ee0`– / `0x140086300`– | 타입 게이트 |
| jsoncpp `getMemberNames` | `0x140088360`– | `functions` 키 열거(사전순) |

문자열 앵커: `"fbos"`=`0x140490724` · `"conditions"`=`0x140490730` · `"format"`=`0x14049073c` ·
`"fit"`=`0x140490744` · `"target"`=`0x140490788` · `"compose"`=`0x140490790` ·
`"bind"`=`0x140490798` · `"unique"`=`0x1404907a0` · `"clear"`=`0x1404907a8` · `"uvs"`=`0x1404907b0` ·
`"rgba_backbuffer"`=`0x1404907b8` · `"index"`=`0x140490820` · `"functions"`=`0x140490828` ·
`"getMaterialCount"`=`0x1404908c0` · `"setMaterialProperty"`=`0x1404908d8` ·
`"executeMaterialFunction"`=`0x1404908f0` · `"getMaterial"`=`0x140490948` ·
`"combos"`=`0x14048b4c4` · `"scale"`=`0x14048f64c` · `"repeat"`=`0x14048f6f8` · `"_"`=`0x14048de40` ·
`"width"`=`0x140473be8` · `"height"`=`0x140473bf8` · `"name"`=`0x1404748b8` · `"visible"`=`0x1404903a0`.
