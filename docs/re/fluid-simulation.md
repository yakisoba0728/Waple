# 유체 시뮬레이션 이펙트(`effects/fluidsimulation`) 완전 해부

**측정일 2026-08-21 · WE 2.8.42 · `wallpaper64.exe`(imagebase `0x140000000`)**
**2026-08-21 2차 실측** — 경계조건/샘플러 어드레싱(§2.4·§2.4a) · 반복 9회의 수치적 정체(§2.13) ·
셰이더 자산 전수(§1.7) · 저작 키 도달(§1.6.1·§1.6.2) · `attachment*` 어노테이션(§1.6.3)을 더했고,
[미해결] 넷을 닫았다(§9). **§4.5 각주의 "파서 잠재 결함" 기재는 오독이라 철회했다.**

**2026-08-21 3차 실측(정밀도 축)** — 남은 [미해결] 다섯 건에 **도달을 매기고**(§9.0) 그중
`r16f` 반올림(§9-4)을 닫았다. 부수로 **본문 오류 둘을 정정한다** — §5.4 의
"`1 - smoothstep(0, size, x)` 로 고치면 안 된다"(대수적으로 같다) 와 §4.3 의
"염료가 지수 감쇠만 한다"(비 HDR 씬에서는 **29 % 밝기에 영구히 얼어붙는다**). §2.13 의 수치
실험은 세션 스크래치의 파이썬에만 있었는데 이제 리포 안에서 돈다 —
`Sources/WapleCore/FluidSimulation{,Precision,Grid}.swift` + 테스트 두 벌.

동봉 이펙트 46종(최상위 `effect.json` 기준) 중 **가장 복잡한 하나**를 끝까지 뜯는다.
이 이펙트만 가진 것이 셋이다 —

* **동봉 `effect.json` 128건 중 유일하게 `functions` 를 갖는다**(전수 실측, preview 사본에도 없다).
* **`conditions` 를 갖는 유일한 이펙트**다(본체 4건 + preview 사본 4건 = 8건이 코퍼스 전부).
* **`unique` FBO 8장 + `command:"swap"` 2회**로 프레임을 넘겨 상태를 누적하는 유일한 이펙트다
  (motionblur 가 `unique` 1장으로 두 번째다. 46종 중 FBO 를 선언하는 것은 9종뿐이고 `swap` 은
  이것 하나다 — 전수표 §1.7).

목적은 하나다: **Waple 의 이펙트 파이프라인이 오늘 이걸 돌릴 수 있는가.** 결론은 §6.

이웃 문서와의 경계 — 콤보/`#require`/`conditions` **문법**은 `docs/re/shader-combos.md`,
엔진 유니폼 140종의 census 는 `docs/re/shader-uniforms.md`, 블렌드 상태는
`docs/re/material-blend.md`, 스크립트 API 표면은 `docs/re/scene-script-api.md` 가 정본이다.
이 문서는 **이 이펙트 하나의 실물 수식과 자원 흐름**만 다루고, 그 문서들의 규약은 인용만 한다.

재현 절차는 부록 A, 인용한 함수 범위는 부록 B.

---

## 0. 일곱 줄 요약

1. **선언 패스 20개(드로우 18 + `swap` 2), FBO 9장. 출하 콘텐츠에서 실제로 도는 것은 19개**다
   (`LIGHTING=0` 이라 패스 16 `normal` 이 스킵된다 — §1.5). 드로우 18회가 만드는 구별되는
   (셰이더, 콤보) 프로그램은 **10개**이고, 압력 Jacobi 는 **9회**로 매니페스트에 같은 패스가
   9번 복제돼 있다(§1.7). 핑퐁은 완전 무충돌이다 — 18개 드로우 패스 어디에도
   읽는 텍스처와 쓰는 텍스처가 겹치는 자리가 없다.
2. **`fit` 은 정사각이 아니다.** `0x1401eb2f8`–`0x1401eb37b` 이 **긴 변을 N 에 맞추고 종횡비를
   보존하며 확대는 하지 않는다**. 즉 1920×1080 레이어에서 `fit:256` 은 **256×144** 다.
   Waple 은 `fit` 을 N×N 정사각으로 읽었고(`EffectManifest.swift:400`) 그래서 속도장 텍셀이
   화면에서 정사각이 아니게 되고, `aspect = g_Texture0Resolution.y/.x` 가 0.5625 대신 **1.0**
   이 됐다 — 이 이펙트에서 가장 큰 그림 차이였다.
   **2026-08-21 착지**: `EffectManifest.FBO.fittedBox` 가 규약 전문을 담고 두 소비처
   (`SceneRendererFrameEncoder.swift:2034-2036` 할당 · `SceneRendererResources.swift:1214-1216`
   `texRes`)가 그것으로 푼다. `scale` 상호작용(§1.3.1)과 입력 출처(§1.3.2)도 함께 확정했다.
   회귀 표면 실측: 동봉+설치본 FBO 선언 112건 중 `fit` 보유 **28건**(이펙트 2종), 그중
   실제로 치수가 바뀌는 것은 `cursorripple` 뿐이다(§6-W1 표).
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
6. **압력 반복 9회는 "수렴" 이 아니라 "평활" 이다** (신규, §2.13). 4텍셀 이하 오차는 완전히
   지우지만 에미터 규모(σ≈13텍셀)의 발산은 **2.6 % 밖에** 못 지운다 — 큰 규모에서 이 흐름은
   비압축이 아니다. 그리고 §2.7 의 `0.5` 누락은 오타가 아니라 **9회 예산에 맞춘 2배 과이완**이다:
   반복 9회에서는 셋 중 셋 다 원본이 "고친" 형태를 이기고, 반복을 늘리면 원본은 오히려 발산한다.
   **반복수와 계수는 한 쌍이다 — 둘 중 하나만 고치지 마라.**
   **2026-08-21 추가(§2.13(e))**: 그 수치들은 `r16f` 로 접어도 **0.002 pp 안에서 같다** —
   9회에서는 절단 오차가 반올림을 압도한다. 반올림이 무는 곳은 `u_Pressure = 1.0` 하나다
   (float64 24.30 % ↔ binary16 55.43 %). **정작 그림을 바꾸는 반올림은 압력이 아니라 염료다** —
   비 HDR 씬의 `rgba8888` 염료는 정지하면 60 fps 에서 **레벨 75(29 % 밝기)에 영구히 얼어붙고**
   그 레벨은 프레임률에 비례해 올라간다(144 fps → 180 = 71 %). §4.3 의 기재를 이것으로 정정했다.
7. **경계는 축마다 다르다** (신규, §2.4·§2.4a). 속도는 divergence 패스의 `if` 4개로 법선 성분
   **반사**·접선 성분 **미끄럼**, 염료만 `boundaryMask` 로 **흡수**다. 나머지는 전부 샘플러
   clamp 에 기댄다 — 그 clamp 가 기본값이라는 것을 `0x1401e78ca`–`0x1401e7915`(파스) ·
   `0x1401eb976`–`0x1401eb990`(소비) · 엔진 프레임버퍼 5장의 상수 `2`(`0x14017f494` 외 4)로
   못 박았다. **이 축은 Waple 과 갭이 없다.**

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

관측 규칙 넷 —

* **아홉 장 전건이 샘플러 어드레싱 `clamp` 다** — `uvs` 를 하나도 선언하지 않는다.
  기구는 §2.4a 에 VA 로 있다(파스 `0x1401e78ca`–`0x1401e7915`, 소비 `0x1401eb976`–`0x1401eb990`).
  이게 §2.4 의 경계조건이 성립하는 **전제**다: 도메인 밖 이웃 샘플이 가장자리 복제(Neumann)라야
  divergence 의 반사 `if` 넷이 "고스트 셀만 뒤집는" 국소 수정으로 동작한다.
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

#### 1.3.1 `fit` × `scale` — **[해결, 2026-08-21]** 경쟁이 아니라 합성이다

종전 이 절은 상호작용을 `[미해결]` 로 남겼다. 렌더타깃 쪽을 마저 뜯어 확정한다.

`scale` 은 위 크기 계산에 **전혀 참여하지 않는다**. 레코드의 `+0x0c` 바이트를 그대로 읽어
(`0x1401eb97d`) 스택 슬롯에 얹고(`0x1401eb98a`), 생성 호출의 **4번째 인자**로 넘긴다
(`0x1401eb9d4` → `0x1401eba0b`). 나눗셈은 **렌더타깃 생성자**가 한다:

```
RT::RT(this, w, h, scale, …)                    # 0x1400d2c60
  [this+0x18] = (u16) w                          # 0x1400d2c9c   "full" 폭
  [this+0x1a] = (u16) h                          # 0x1400d2ca7   "full" 높이
  [this+0x1c] = scale                            # 0x1400d2cb2
  [this+0x14] = (u16) max(2, w / scale)          # 0x1400d2ca1 idiv → 0x1400d2cbc cmovg → 0x1400d2cc4
  [this+0x16] = (u16) max(2, h / scale)          # 0x1400d2cc9 idiv → 0x1400d2cd3 cmovg → 0x1400d2ce4
```

리사이즈 경로도 같은 식이다 — `0x140161f40`–`0x140161fa5` 가 `+0x18/+0x1a` 에 새 full 을
쓰고 `+0x1c` 의 scale 로 나눠 `+0x14/+0x16` 을 다시 만든다(하한 2 동일, `0x140161f83`).
그리고 실제 텍스처 폭은 `+0x14` 에서 온다(`0x140161fb9`가 텍스처 객체 `+0x20` 에 싣는다).

즉 **최종 텍스처 = `max(2, W'/scale) × max(2, H'/scale)`** 이고 `fit:256, scale:2` 는
긴 변 128 이다. 배타 관계가 아니다.

**코퍼스 도달은 0이다** — 동봉+설치본 `effect.json` 의 FBO 선언 112건(동봉 55 + 설치본 57) 중 `fit`+`scale`
동시 선언 0건, `width|height`+`scale` 도 0건(census: 이 문서 부록 A 의 재현 절차).
그래서 이 규약은 **워크샵 저작에서만** 관측될 수 있다.

> **하한 2 에 대한 Waple 의 의도적 편차.** Waple 은 하한을 1 로 둔다. 2 로 올리려면
> `fit` 미선언 FBO 의 종전 `max(1, dst/scale)` 까지 같이 움직여야 하는데(무회귀 규약 위반),
> 두 값이 갈리는 구간은 "한 축이 1 이하로 떨어지는 dst" 뿐이라 코퍼스 도달이 0이다.

#### 1.3.2 `fit` 의 입력은 무엇인가 — **화면이 아니라 이펙트 dst 서피스**

`(W0,H0)` 는 이펙트 객체의 가상 호출 `[vtable+0x128]`(`0x1401ea5b1`)이 채우는 int2 이고,
`max(4, ·)` 로 하한이 걸린다(`0x1401ea5e4`·`0x1401ea606`). **같은 `(W0,H0)` 가 이펙트
자신의 핑퐁 렌더타깃(`this+0x2c8`/`+0x2d0`)을 만든다** — `0x1401eb0dd`(W0) ·
`0x1401eb09e`(H0) → `0x1401eb0e5` 호출, scale 인자는 1 이다. 그 결과가 `0x1401eb0f8` 에서
`this + idx*8 + 0x2c8` 에 저장된다. 핑퐁 쌍이 곧 이펙트 체인의 dst 이므로,
`fit` 의 기준은 **이 이펙트가 그려 넣는 서피스**다. 전화면 framebuffer 레이어에서는
화면 해상도와 같아지지만 그건 우연이고, 부분 레이어에서는 레이어 크기다.
Waple 의 대응값은 빌드 시점 `effW/effH`(레이어 크기, `isFrameBuffer` 면 프로젝션 크기,
`SceneRendererResources.swift:369-412`)와 프레임 시점 `dst` 크기다.

#### 1.3.3 `width`/`height` 는 `fit` 의 **입력**을 갈아치운다

`0x1401eb2e3`/`0x1401eb2f4` 는 선언된 `width`/`height` 를 `W`/`H` 에 넣고, 그 뒤 `fit`
분기는 **그 값들로** major 를 고른다. 즉 `{"fit":256,"width":1024,"height":512}` 는 dst 를
전혀 보지 않고 256×128 이 된다. 세 값이 u16 필드(`0x1401e7804`·`0x1401e7834`·`0x1401e7857`,
미선언 `0xffff`)라 **`> 0x1000`(4096)이면 미선언 취급**이라는 점도 여기서 나온다
(`0x1401eb2dc`·`0x1401eb2ec`·`0x1401eb2fd`). 도달 0건.

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
`0x1401e7ecf` bind — 종전 기재 `0x1401e7ed0` 은 그 `call` 의 **rel32 피연산자 위치**였다, [VA-스캐너위치]
`docs/dev/re-methodology.md` 함정 #16b) 전건 `rdx = r13` 이고, `r13` 은 `0x1401e7319`(`find(effectNode, "combos")`)
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

#### 1.6.1 저작 레인은 **선언 없는 패스에도 키를 흩뿌린다** (신규 실측)

preview 씬의 18개 패스 오버라이드를 셰이더 어노테이션과 대조한 전수(재현: 부록 A ⑧):

| 원본 idx | 머티리얼 | 셰이더가 선언한 `material` 키 | 씬이 실은 키 | **그중 미선언** |
|---:|---|---:|---:|---:|
| 0 | curl | 0 | 0 | 0 |
| 1 | vorticity | 41 | 11 | 0 |
| 2 | divergence | 0 | 0 | 0 |
| 3 | clear | 1 | 7 | **6** |
| 4–12 | pressure ×9 | 0 | **0** | 0 |
| 13 | gradientsubtract | 0 | 0 | 0 |
| 14 | advection | 39 | 11 | **2** |
| 15 | advection(DYE) | 39 | 10 | **2** |
| 16 | normal | 1 | 7 | **6** |
| 17 | combine | 16 | 10 | **6** |
| | **합** | | **56** | **22 (39 %)** |

* **압력 9개 패스에는 오버라이드가 하나도 없다.** 반복수 9가 저작 표면에 전혀 노출돼 있지
  않다는 것의 자산 측 증거다(§2.13).
* 미선언 22건의 정체는 전부 에미터 키다. `emitterPos0`(advection.frag:28 · vorticity.frag:33) ·
  `lineEmitterPosA0/B0`(advection.frag:44,45 · vorticity.frag:53,54) ·
  `lineEmitterSize0`(advection.frag:46 · vorticity.frag:56)은 **그 두 셰이더에만** 있는데 씬은
  clear·normal·combine 패스에도 실었다. `lineEmitterAngle0`/`lineEmitterSpeed0` 는 한술 더 떠
  **vorticity.frag:55·57 에만** 있는데(advection.frag 에는 없다) advection 두 패스에도 실려 있다.
* ⇒ **소비자는 모르는 `constantshadervalues` 키를 조용히 버려야 한다.** 경고를 찍으면
  이 이펙트 하나에서 프레임마다 22줄이 나온다. WE 자신이 만든 씬이 이러므로 "워크샵이 지저분한
  것" 이 아니라 **에디터의 정상 동작**이다.

#### 1.6.1a 콤보는 흩뿌려지지 **않는다** — 값 경로와 콤보 경로가 다르다 (신규 2026-08-21)

§1.6.1 은 에디터가 `constantshadervalues` 를 선언하지 않은 패스에도 흩뿌린다는 것을 보였다
(56건 중 22건). **콤보는 정반대다.** 같은 preview 씬의 `passes[].combos` 전수:

| 원본 idx (씬 pass id) | 머티리얼 | 씬이 실은 `combos` | 그 셰이더가 선언하는가 |
|---:|---|---|---|
| 1 (21) | vorticity | `LINEEMITTER:1`, `POINTEMITTER:0` | ✔ 둘 다 `vorticity.frag` 에 `[COMBO]` |
| 14 (34) | advection | `LINEEMITTER:1`, `POINTEMITTER:0` | ✔ 둘 다 `advection.frag` 에 `[COMBO]` |
| 15 (35) | advection(DYE) | `DYE:1`, `LINEEMITTER:1`, `POINTEMITTER:0` | ✔ (`DYE` 는 머티리얼 `combos` 를 되비춘 것) |
| 17 (37) | combine | `BLENDMODE:0` | ✔ `combine.frag` 에만 있는 콤보 |
| 0·2·3·4–13·16 | curl·divergence·clear·pressure×9·normal | **없음** | 그 셰이더에 `[COMBO]` 가 하나도 없다 |

**한 건도 어긋나지 않는다** — 콤보는 그것을 선언한 셰이더의 패스에만 간다.
값(`constantshadervalues`)은 39 % 가 어긋나는데 콤보는 0 % 다. ⇒ 에디터 안에서
**두 경로는 다른 코드**이고, 콤보 경로는 **선언 주도**다.

이것이 §1.5 의 [미해결]에 주는 것: `LIGHTING` 은 `combine.frag` 에만 선언돼 있으므로 이 규칙대로면
`passes[17].combos` 로만 실리고 `conditions`(= `effects[].combos` 만 본다)는 **영원히 거짓**이다.
다만 이건 "속성 편집 레인" 한 곳의 행동이라 이펙트 인스턴스 레벨 UI 의 존재를 배제하지는
못한다 — §9-2 참조.

> 부수 관찰(확정 아님, **추정**): 미선언 값 22건의 정체는 preview 씬에서 활성 기즈모
> (`LINEEMITTER ge 1` 인 `EffectLineEmitter` 하나)가 묶는 다섯 변수
> `lineEmitterPosA0`/`PosB0`/`Angle0`/`Size0`/`Speed0` 와 `emitterPos0` 여섯이고, 그것이
> **선언 키를 하나라도 가진 패스(3·14·15·16·17)에만** 실렸다(선언 키가 0개인 curl·divergence·
> pressure 아홉에는 안 실렸다). 기즈모 변수를 모든 패스에 동기화하는 저작 동작으로 보이지만
> 표본이 한 씬뿐이라 규칙으로 못 세운다.

#### 1.6.2 코퍼스 도달 — **이펙트 자신의 preview 뿐이다**

| 범위 | scene.json | `fluidsimulation` 을 마운트하는 씬 |
|---|---:|---:|
| 동봉 `WEAssets` | 171 | **1** (`effects/fluidsimulation/preview/scene.json`) |
| 설치본 `wallpaper_engine` 전체 | 184 | **1** (같은 파일의 설치본 사본) |

이 문서의 모든 "저작된 값" 은 그 한 씬에서 온다. **출하 배경화면 중 이 이펙트를 쓰는 것은
0건**이고, 그래서 §1.5 의 `conditions` 3건도 §4.4 의 `functions` 도 전부 도달 0 이다.

#### 1.6.3 `attachmentproject` / `attachmentangles` — **[해결 2026-08-21] 에디터 전용, 런타임 소비 0**

종전 §9-6 이 [미해결]로 남긴 항목이다. **종전 기재의 "12건" 도 틀렸다** — 다시 세면:

| 어노테이션 | 건수 | 붙는 자리 | 값의 형태 |
|---|---:|---|---|
| `attachmentproject` | **10** | `m_EmitterPos0..3`(4) + `m_LineEmitterPosA/B0..2`(6) | `true`(불리언) |
| `attachmentangles` | **4** | `m_EmitterPos0..3` 만 | **문자열** `"emitterAngle0".."emitterAngle3"` — 짝이 되는 각도 프로퍼티의 이름이다. 불리언이 아니다 |

둘 다 본체 `vorticity.frag` 에만 있고(다른 17개 셰이더 0건) preview 사본에는 없다.
선 에미터는 `attachmentangles` 를 안 받는다 — 선분은 두 점으로 방향이 정해지기 때문이다.

**바이너리 전수(설치본 `.exe`/`.dll` 전건, ASCII + UTF-16LE 양쪽):**

| 파일 | `attachmentproject` | `attachmentangles` |
|---|---:|---:|
| `bin/wallpaperui.exe`(에디터) | 1 | 1 |
| `distribution/bin/wallpaperui.exe`(같은 파일 사본) | 1 | 1 |
| `wallpaper64.exe` · `wallpaper32.exe` · `webwallpaper64.exe` · `edgewallpaper64.exe` · `scenescript{32,64}.dll` · `resourceutil{32,64}.dll` · `mediaextensions*` · `cloneextensions*` · `winrtutil*` · 나머지 전부 | **0** | **0** |

**런타임은 이 키를 읽지 않는다.** 비-바이너리 히트도 둘뿐이다 — 셰이더 자신과
`ui/dist/scripts/scripts.js`(에디터 UI).

**무엇을 하는 키인지도 그 JS 가 답한다.** `attachmentproject` 가 참이면 그 머티리얼
프로퍼티의 컨텍스트 메뉴에 `ui_editor_properties_context_menu_bind_attachment_projection`
버튼(클립 아이콘)이 붙고, 누르면 `getAllAttachments` 로 고른 어태치먼트의 `{{ID}}`/`{{NAME}}`
을 스니펫에 치환해 **씬 스크립트를 생성해 붙여 준다**. 스니펫은
`ui/dist/monaco/snippets/script_project_attachment.js` —

```js
export function update() {
    return thisLayer.transformAttachmentToTexture(thisScene.getLayerByID('{{ID}}'), '{{NAME}}').translation();
}
```

`attachmentangles` 가 있으면 `script_project_attachment_angle.js` 쪽을 쓰고, **그 값(문자열)을
`{{ANGLE}}` 자리에 그대로 치환한다**(`e.replace("{{ANGLE}}", n.attachmentangles)`) — 그래서
`m_EmitterPos0` 의 `"emitterAngle0"` 이 스크립트 안의 프로퍼티 이름이 된다:

```js
export function update() {
    var mat = thisLayer.transformAttachmentToTexture(thisScene.getLayerByID('{{ID}}'), '{{NAME}}');
    thisObject['{{ANGLE}}'] = mat.angle();
    return mat.translation();
}
```

생성된 텍스트는 `n.linkScript = e` 로 그 프로퍼티의 **링크 스크립트**가 된다. 즉 이 어노테이션이
만드는 것은 값이 아니라 **`{animation}`/링크 스크립트 저작물**이고, 런타임은 그 스크립트만 본다.

> **판정**: 이 두 키는 **저작 편의 어노테이션**이다. "에미터를 퍼펫 뼈에 붙인다" 는 기능은
> 어노테이션이 아니라 그것이 만들어 주는 **스크립트**가 수행하고, 그 스크립트는 씬의 평범한
> `constantshadervalues` 애니메이션 경로로 흘러간다. **Waple 이 이 키를 파스할 이유는 없다** —
> 파스해도 소비할 런타임 동작이 없기 때문이다. 진짜 질문은 그 스니펫이 부르는
> `transformAttachmentToTexture` 가 동작하느냐인데 — 이름 문자열 `0x140490928`(길이 `0x1c`),
> 등록부 `0x1401ee520`–`0x1401ef118` 안에서 `0x1401ef0a4` 가 이름을, `0x1401ef0ba`/`0x1401ef0c8`
> 이 네이티브 포인터 **`0x1401ed0d0`**(`0x1401ed0d0`–`0x1401edb1b`)을 심는다(직접 재측).
> 반환형은 `.d.ts:1555` 기준 `Mat3` 다.
> **Waple 은 이미 그 자리를 알고 noop 프록시로 막아 뒀다**(`TextScriptEngine.swift` 의 `T-G15`,
> `__makeLayer`/형제 둘 다). 즉 이 어노테이션이 유도하는 저작 흐름은 Waple 에서
> "스크립트는 돌지만 에미터가 안 따라간다" 가 된다 — 이 문서의 결손이 아니라
> `docs/re/scene-script-api.md` 의 결손이고, 도달 자산은 0건이다.

### 1.7 셰이더·머티리얼 자산 전수 — 어느 파일이 어느 단계인가

브리프 질문 4. 동봉본과 설치본은 트리 전체가 **바이트 동일**(`diff -rq` 0건, 65파일).
`.frag`/`.vert` 는 **본체 18 + preview 사본 18 = 36개**이고, `.h` 는 이 이펙트가 소유하지
않는다 — 전역 `shaders/` 의 것을 `#include` 한다.

| 단계(패스 idx) | `.frag` | 줄 | `.vert` | 줄 | `#include` / `#require` |
|---|---|---:|---|---:|---|
| 0 curl | `..._curl.frag` | 21 | `..._curl.vert` | 21 | — |
| 1 vorticity(+에미터+커서) | `..._vorticity.frag` | 210 | `..._vorticity.vert` | 101 | frag `common.h` · vert `common_perspective.h` |
| 2 divergence | `..._divergence.frag` | 26 | `..._divergence.vert` | 23 | — |
| 3 clear(압력 감쇠) | `..._clear.frag` | **8** | `..._clear.vert` | 15 | — |
| 4–12 pressure ×9 | `..._pressure.frag` | 24 | `..._pressure.vert` | 23 | — |
| 13 gradientsubtract | `..._gradientsubtract.frag` | 23 | `..._gradientsubtract.vert` | 23 | — |
| 14·15 advection(+DYE) | `..._advection.frag` | 191 | `..._advection.vert` | 27 | vert `common_perspective.h` |
| 16 normal | `..._normal.frag` | 30 | `..._normal.vert` | **10** | — |
| 17 combine(출력) | `..._combine.frag` | 141 | `..._combine.vert` | 51 | frag `common_blending.h` + `common_pbr_2.h` + **`#require LightingV1`** · vert `common_perspective.h` |

관측 셋 —

* **`divergence.vert` · `pressure.vert` · `gradientsubtract.vert` 는 서로 바이트 동일**하다
  (sha256 앞 8자리 `2a546c13`, 23줄 588 B ×3). §2.1 이 "같은 네 줄" 이라 부른 것은 실제로는
  **같은 파일 내용**이다. `curl.vert`(21줄)와 `vorticity.vert`(101줄)는 `a_TexCoord` 를 기점으로
  쓰는 점만 다르고 이웃 네 줄은 동일하다.
* **preview 사본과 본체가 다른 파일은 정확히 셋**이다 — `combine.frag`(141↔129줄),
  `combine.vert`(51↔53줄), `vorticity.frag`(210↔209줄). 나머지 15쌍은 sha 가 같다.
  `effect.json` 의 `functions` 유무까지 합쳐 **차이는 총 4파일**이다(§1.1 표가 이 넷이다).
* **드로우 18회가 만드는 구별되는 (셰이더, 콤보) 프로그램은 10개**다 — 압력 9회가 전부 같은
  프로그램이고, `advection` 만 `DYE` 0/1 로 갈려 하나의 소스에서 둘이 나온다. 머티리얼 파일도
  10개이고 **전건** `blending:"normal"` · `depthtest/depthwrite:"disabled"` · `cullmode:"nocull"` 이다
  (10/10 실측).

> 유체 관련 셰이더가 **전역 `shaders/` 에는 한 장도 없다**(전역 137파일 전수 확인).
> 이름에 `fluid` 가 들어간 유일한 전역 히트는 `shimmer.frag:11` 의 그래디언트 자산명
> `gradient/gradient_ferro_fluid` 로, 유체 시뮬과 무관하다.

**이펙트 46종 중 격자 솔버는 이것 하나다**(전수 실측). FBO 를 선언하는 이펙트는 9종뿐이고,
그중 프레임을 넘겨 상태를 들고 있는 것(`unique`)은 둘이다:

| 이펙트 | 패스 | FBO | `unique` | `swap` |
|---|---:|---:|---:|---:|
| **fluidsimulation** | **20** | **9** | **8** | **2** |
| motionblur | 3 | 2 | 1 | 0 |
| cursorripple | 3 | 2 | 0 | 0 |
| godrays · shine | 5 | 2 | 0 | 0 |
| blur · localcontrast | 4 | 2 | 0 | 0 |
| blurprecise · glitter | 2 | 1 | 0 | 0 |
| 나머지 37종 | ≤2 | **0** | 0 | 0 |

`watercaustics` · `waterflow` · `waterripple` · `waterwaves` 는 넷 다 **패스 1개 · FBO 0개**다 —
프레임 간 상태를 담을 곳이 없으므로 솔버가 아니라 절차적 파형이다.
`cursorripple` 만 2패스 파동 시뮬(`_rt_EightBuffer1/2`, `fit:512`)인데 `unique` 도 `swap` 도
쓰지 않는다 — 그쪽 규약은 이 문서의 범위 밖이다.

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
판정하므로 최외곽 한 줄에서만 발화한다 — 프래그먼트 중심이 `u.x = (i+0.5)/Nx` 이므로
`vL.x = u.x − 1/Nx < 0` 은 `i = 0` 에서만 참이고(`0.5/Nx < 1/Nx`, `i=1` 이면 `1.5/Nx > 1/Nx`),
네 면 모두 같다. 다른 패스(curl/Jacobi/gradient/advection)에는 경계 처리가 없고 클램프
샘플링에 의존한다.

**"반사인가 흡수인가" 에 대한 정확한 답**(브리프 질문 2) — **셋이 섞여 있고, 축마다 다르다.**

| 자리 | 도메인 밖 취급 | 물리적 뜻 |
|---|---|---|
| divergence 의 법선 성분 (4면) | `−C` = **반사** | 벽을 통과하는 유량 0. 자유 미끄럼(free-slip)의 압력 소스항 |
| divergence 의 접선 성분 | 손대지 않음 → 샘플러 clamp = 가장자리 복제 | 벽에서 미끄러진다(no-slip 아님) |
| Jacobi 압력 (패스 4–12) | clamp = `p_ghost = p_inner` | `∂p/∂n = 0` — free-slip 압력 BC의 표준형. **의도적으로 맞다** |
| gradientsubtract (패스 13) | clamp | 가장자리 열에서 `∇p_x = p(vR) − p(u)` 라 법선 속도가 **정확히 0 이 되지는 않는다**(반쪽 차분) |
| 속도 이류 (패스 14) | clamp | 밖으로 역추적되면 **가장자리 속도를 자기복제**한다 = 흡수도 반사도 아님. 벽에 붙은 흐름이 유지된다 |
| 염료 이류 (패스 15) | `boundaryMask` **경성 절단** = **흡수** | 밖으로 역추적된 염료는 0. 유일하게 명시적으로 버리는 자리(§2.9) |

즉 **속도는 반사(법선)+미끄럼(접선), 염료는 흡수**다. 두 축이 다른 것은 원본 그대로이고
참조 구현(PavelDoGreat)과도 같다.

**그 `if` 넷이 실제로 얼마나 버는가 — 돌연변이 실측.** §2.13 과 같은 수치 재현에서, 왼쪽 벽
6텍셀 앞에 벽을 향하는 가우시안 흐름을 놓고 투영(발산 → Jacobi 9 → 경사 제거) 한 번을 돌린 뒤
**최외곽 열의 법선 속도**(= 벽을 통과하는 유량)를 잰 것:

| | 좌벽 법선속도 `mean(abs(v_x[:,0]))` | 전체 잔존 `mean(abs(div))` |
|---|---:|---:|
| 투영 전 | 0.063348 | — |
| **원본**(반사 `if` 4개) | **0.024691** | 0.000719 |
| 돌연변이: `if` 넷 제거 | 0.065716 | 0.000464 |

`if` 를 지우면 투영이 벽 유량을 **거의 손대지 못한다**(0.0633 → 0.0657, 오히려 늘었다).
즉 이 네 줄이 이 솔버의 벽을 만드는 전부다. 흥미로운 부작용도 보인다 — **반사를 켜면 전체
잔존 발산이 오히려 커진다**(0.000464 → 0.000719). 벽에 일부러 발산 소스를 심어 흐름을
되밀기 때문이고, "발산을 줄이는 것" 과 "벽을 세우는 것" 이 이 스킴에서 서로 다른 목표라는 뜻이다.
**이식할 때 `if` 넷을 빼먹으면 연기가 화면 밖으로 새어 나간다** — 그리고 잔차 지표만 보면
"더 좋아졌다" 고 오판하게 된다.

#### 2.4a 샘플러 어드레싱은 어디서 정해지는가 — **[신규 확정 2026-08-21]**

위 표의 여섯 행 중 넷이 "clamp" 에 기대므로 그게 실제로 clamp 인지 기계로 못 박는다.
종전 이 문서는 `uvs:"repeat"` 를 안 쓴다는 사실만 적고 기본값을 **근거 없이** clamp 라 불렀다.

**파스** — FBO 레코드의 `uvs` 값은 문자열 `"repeat"` 와만 대조한다(길이 6 `memcmp`):

```
0x1401e78ca  cmp r8, 6                     ; 길이가 6이 아니면 대조조차 안 한다
0x1401e78d0  lea rdx, [rip+…] ; 0x14048f6f8 "repeat"
0x1401e78da  call memcmp
0x1401e78e3  mov sil, 1                    ; 일치
0x1401e78f2  xor sil, sil                  ; 불일치 — **다른 문자열은 전부 여기로**
0x1401e7912  or edi, 4                     ; 일치일 때만 레코드 +0x48 의 bit2
0x1401e7915  mov dword ptr [rbp+0x48], edi
```

**소비** — 렌더타깃 생성 인자를 그 bit 하나로 고른다:

```
0x1401eb976  test byte ptr [r10+0x48], 4   ; r10 = FBO 레코드
0x1401eb97b  mov eax, ecx                  ; ecx = 0 (여기 도달 시 텍스처 포인터가 null)
0x1401eb982  mov ecx, 2
0x1401eb987  cmove eax, ecx                ; ZF(=bit2 없음) → eax = 2
0x1401eb990  mov dword ptr [rbp-0x38], eax ; createRenderTarget 의 8번째 인자
0x1401eba0b  call 0x1401aadb0              ; 8번째 인자 = 호출자 [rsp+0x38]
             ; 피호출자는 그것을 [rsp+0x128] 에서 읽어(0x1401aade9) 다시 [rsp+0x38] 에 얹고
             ; 0x1401aae12 이 디바이스 [vtbl+0x70] 로 **자리 그대로** 넘긴다
```

**따라서 `uvs:"repeat"` = 인자 0, 그 외(미선언 포함) = 인자 2.** 이 인자가 "어드레싱" 이고
2 가 clamp 라는 것의 근거 둘:

1. **엔진 자신의 프레임버퍼 다섯 장이 전건 2 를 넘긴다** — `_rt_<N>FrameBuffer`(`0x14017f494`),
   `_rt_FullFrameBuffer`(`0x14017f57d`), `_rt_4FrameBuffer`(`0x14017f5cd`),
   `_rt_8FrameBuffer`(`0x14017f60a`), `_rt_Bloom`(`0x14017f64e`) — 전부 같은 스택 슬롯
   `[rsp+0x38]` 에 상수 `2`. 블룸/다운샘플 체인이 랩이면 화면 반대편이 가장자리로 새어 들어온다.
2. **코퍼스에서 `uvs` 를 선언하는 유일한 FBO 가 타일 아틀라스다** — `glitter` 의
   `_rt_GlitterTiles`(FBO 선언 112건 중 **4건** = 동봉 2 + 설치본 2, 전부 같은 이펙트의
   본체/preview 사본). 기본이 랩이라면 이 키를 쓸 이유가 없다.

> 부수 확정: `"repeat"` 정확 일치만 본다. `uvs:"clamp"` 같은 형제 값은 **조용히 무시**되고
> 기본(2)으로 남는다 — 결과가 우연히 같아서 워크샵에서 티가 안 난다.
> Waple 은 이미 같은 규약이다: bind 슬롯 기본 clamp(`for slot in bindSlots { texWrap[slot] = 1 }`)
> 위에 `uvsRepeat` FBO 를 소스로 삼는 슬롯만 0 으로 재정의한다
> (`SceneRendererResources.swift` 의 주석 마커 `X-①`. 이 파일은 이 세션에 여러 클러스터가
> 동시에 고치고 있어 행번호가 움직이므로 마커로 가리킨다). **이 축은 갭 없음.**

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

### 2.13 반복 9회의 정체 — **수렴이 아니라 평활이다** (신규, 수치 실측)

브리프 질문 1 은 "각 단계가 몇 번 도는지와 그 상수의 출처" 다. 개수는 §1.4·§2.6 에서
매니페스트 실측으로 닫혔다(9는 **하드코딩된 패스 복제**, 콤보도 저작 키도 아니다).
남은 것은 "그래서 9회면 압력 방정식이 풀리는가" 인데, **안 풀린다.** 그리고 그게 결함이 아니다.

여기 숫자는 바이너리가 아니라 **§2.2–§2.7 의 확정된 셰이더 식을 그대로 옮긴 수치 실험**이다
(재현: 부록 A ⑦). 격자 256×144(= 1920×1080 에서의 `fit:256`), 경계는 실물과 동일하게
divergence 만 반사 `if` 4개, 나머지는 clamp.

**(a) Jacobi 의 모드별 감쇠.** `p ← (L+R+B+T − div)/4` 의 오차 감쇠계수는
`μ = (cos kx + cos ky)/2` 다. x 방향으로만 변하는 모드(ky=0)에서:

| 오차 파장 | `μ` | `μ⁹`(9회 뒤 남는 비율) |
|---|---:|---:|
| 2텍셀(나이퀴스트) | 0.000000 | **0.000000** |
| 4텍셀 | +0.500000 | **0.001953** |
| 8텍셀 | +0.853553 | **0.240478** |
| 그리드폭 N=256 | +0.999849 | **0.998646** |
| 최장 파장 2N | +0.999962 | **0.999661** |

즉 **9회는 4텍셀 이하를 완전히 지우고 8텍셀을 1/4 로 줄이며, 그보다 큰 규모는 손도 못 댄다.**
전형적인 다중격자 스무더 1회분이다.

**(b) 투영이 실제로 지우는 발산량.** 셰이더 그대로(§2.4 발산 + 9회 Jacobi + §2.7 경사 제거,
`0.5` 없음) 돌려 잔존 발산을 잰 것:

| 입력 속도장 | 반복 9(실물) | 참고: 18 | 참고: 50 |
|---|---:|---:|---:|
| 에미터 규모(σ=13텍셀 ≈ `emitterSize 0.05`) | **97.40 %** | 94.90 % | 86.72 % |
| 커서 임펄스 규모(σ=4텍셀 ≈ `cursorinfluence 1`) | **78.08 %** | 63.64 % | 80.46 % |
| 고주파 백색잡음 | **46.52 %** | 48.09 % | 48.63 % |

**에미터가 만든 큰 규모의 발산은 2.6 % 밖에 안 지워진다.** 다시 말해 이 이펙트의 흐름은
큰 규모에서 **비압축이 아니다**. 눈에 보이는 "유체다움" 은 압력 투영이 아니라
**이류(§2.8) + 와도 구속(§2.3)** 이 만든다.

**(c) 왜 `gradientsubtract` 에 `0.5` 가 없는가 — 돌연변이로 확정.** §2.7 은 "참조 구현과 같으니
고치지 마라" 까지만 말했다. 실제로 넣어 보면:

| 입력 | 반복 | 원본(0.5 없음) | `0.5` 넣은 변종 |
|---|---:|---:|---:|
| 에미터 규모 | **9** | **97.40 %** | 98.70 % |
| 커서 규모 | **9** | **78.08 %** | 89.04 % |
| 백색잡음 | **9** | **46.52 %** | 64.54 % |
| 커서 규모 | 500 | 115.69 %(발산) | 18.14 % |
| 에미터 규모 | 5000 | 115.69 %(발산) | 14.90 % |

**반복 9회에서는 세 경우 전부 원본이 이긴다.** `0.5` 를 넣은 "이론적으로 옳은" 형태는
반복을 많이 줘야 비로소 유리해지고, 원본은 반복을 늘리면 오히려 **발산한다**(2배 과이완이라
수렴 반경 밖). 즉 **`0.5` 누락과 반복 9회는 한 쌍으로 튜닝된 값**이다 —
둘 중 하나만 "고치면" 그림이 나빠진다. 이식자에게 주는 규칙은 하나다:
**반복수와 계수를 함께 바꾸지 않는 한 어느 쪽도 건드리지 마라.**

**(d) `u_Pressure`(압력 감쇠, §2.5)의 실제 역할.** 전 프레임 압력을 초기추정으로 재활용하는
따뜻한 시작이다. 매끄러운 발산장에서의 정상상태 **Jacobi 잔차** `|∇²p − div|`(초기 대비.
(b)의 "잔존 발산" 과는 다른 지표다 — 이쪽은 압력 방정식이 얼마나 풀렸는지만 본다):

| `u_Pressure` | 정상상태 잔차 | 도달 프레임 |
|---:|---:|---|
| 0.0 (재활용 없음) | 99.77 % | 즉시 |
| **0.8 (기본·preview)** | **98.76 %** | ~10 |
| 0.95 | 94.85 % | ~60 |
| 1.0 (감쇠 없음) | 22.28 % | ~600(10초) |

**기본값 0.8 에서는 따뜻한 시작이 사실상 아무것도 벌어 주지 않는다**(99.77 → 98.76 %).
큰 규모 압력을 실제로 누적하려면 `pressure` 를 1.0 에 붙여야 하고, 그러면 반응이 10초 느려진다.
그래서 UI 슬라이더 `pressure [0,1]` 은 "얼마나 비압축으로 갈 것인가 ↔ 얼마나 빨리 반응할 것인가"
의 트레이드오프 노브다. 백색잡음처럼 고주파가 실린 장에서는 같은 0.8 이 18.9 % → 7.7 % 로
**두 배 넘게** 벌어 준다 — 즉 이 노브도 고주파 대역에서만 효과가 있다.

> **경계 — 이 절은 바이너리 실측이 아니다.** (a)–(d) 는 확정된 셰이더 식의 수치 재현이다.
> 실물 GPU 는 `r16f`(10비트 가수)로 돌므로 아주 작은 잔차 구간에서는 여기 숫자보다 나쁘다.
> 반올림 영향은 재지 않았다 — [미해결]로 §9 에 남긴다.
> **[해소 2026-08-21] → (e).** 재 봤고, 위 문장의 "여기 숫자보다 나쁘다" 는 **반복 9회에서는
> 사실이 아니다**(0.002 pp). 나쁜 구간이 따로 있고 그 조건이 좁다.

### 2.13(e) `r16f`/`rg16f` 반올림의 실제 영향 — **[신규 확정 2026-08-21]**

(a)–(d) 와 같은 셰이더 식을 쓰되 **모든 저장 자리를 IEEE 754 binary16 으로 접어** 다시 잰 것이다
(격자 256×144, 경계 동일). 양자화는 `Double → Float → binary16`(최근접-짝수) 순서라 저장 단계는
GPU 와 같은 한 번의 반올림을 거친다. 계산 자리는 fp64 라 실물(fp32)보다 정확하지만, 가수가
53 ↔ 23 ↔ 10비트라 **저장이 지배적**이므로 결론이 갈리지 않는다.

**(e-1) 출하 설정에서는 차이가 없다.**

| 반복 | float64 | binary16 | 차 |
|---:|---:|---:|---:|
| **9(실물)** | 97.406 % | 97.408 % | **+0.002 pp** |
| 18 | 94.911 % | 94.914 % | +0.003 pp |
| 50 | 86.752 % | 86.762 % | +0.010 pp |

이유는 (a) 다. 9회가 지우는 것은 4텍셀 이하뿐이고 에미터 규모(σ≈13텍셀) 오차는 손도 못 대므로
**절단 오차가 반올림 오차를 세 자릿수 압도한다.** ⇒ **(b)·(c)의 float64 표는 실물에서 그대로
유효하다** — 이 문서를 근거로 이식하는 사람이 "실물은 더 나쁘겠지" 하고 여유를 둘 필요가 없다.

**(e-2) 반올림이 무는 곳은 `u_Pressure = 1.0` 하나다.** (d) 와 같은 따뜻한 시작을 600프레임 돌린
정상상태 Jacobi 잔차:

| `u_Pressure` | float64 | binary16 | 차 |
|---:|---:|---:|---:|
| 0.8 (기본·preview) | 94.29 % | 94.30 % | +0.00 pp |
| 0.95 | 83.48 % | 83.50 % | +0.02 pp |
| **1.0 (감쇠 없음)** | **24.30 %** | **55.43 %** | **+31.13 pp** |

기구는 한 줄이다 — 정규 구간의 binary16 은 **상대 `2^-11` 미만의 증분을 저장에서 버린다**
(최근접-짝수라 반 ulp 미만은 사라진다). 압력이 프레임을 넘어 누적될수록 한 번의 Jacobi 갱신은
`div/4` 규모로 고정인데 `p` 는 커지므로, 어느 순간 상대 증분이 그 문턱 아래로 내려가 **정체**한다.
`u_Pressure < 1` 이면 감쇠가 `p` 의 누적 상한을 만들어 그 문턱에 닿기 전에 멈춘다.

⇒ **(d)의 결론이 강해진다.** 그 절은 "`pressure` 슬라이더를 1.0 에 붙여야 큰 규모 압력이
쌓이는데 그러면 반응이 10초 느려진다" 였다. 여기에 하나가 더 붙는다 — **1.0 에 붙여도
float64 가 약속하는 만큼은 안 쌓인다.** 즉 `r16f` 가 그 슬라이더의 상단을 실질적으로 잘라낸다.

**(e-3) 진짜 그림에 닿는 반올림은 압력이 아니라 염료다.** §4.3 을 보라 — `rgba8888` 염료 버퍼는
감쇠를 **완전히 멈춘다**. 압력장의 `r16f` 는 출하 설정에서 그림에 안 닿고, 염료의 8비트는 닿는다.

재현은 리포 안에 있다: `Sources/WapleCore/FluidSimulationGrid.swift`(격자 파이프라인) ·
`FluidSimulationPrecision.swift`(binary16·unorm8) ·
`Tests/WapleCoreTests/FluidSimulationPrecisionTests.swift`(작은 격자로 같은 부호를 회귀로 잠근다).

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

**클리어 빈도는 여전히 [미해결]이지만, 기구는 좁혔다**(2026-08-21 재측 · 3차 재측은 §9-1 —
직접 호출 0건 · `call [reg+0xB8]` 이 24 아니라 25 · 네 vtable 전건 슬롯 23 재확인). 종전 서술은
"생성과 리사이즈 **양쪽 경로 뒤에** 있다" 였는데, 그보다 강하다 — **두 경로가 클리어에서
합류한다**:

```
0x1401eb96a  mov rcx, qword ptr [r10]      ; 레코드 +0 = 보유 중인 렌더타깃(있으면 non-null)
0x1401eb970  jne 0x1401eba1c               ; 이미 있다 → 리사이즈 갈래
             ...(없을 때)  0x1401eba0b  call 0x1401aadb0   ; 신규 생성
0x1401eba10  mov rcx, [rbp-0x68]           ; ↘
0x1401eba1c  mov r8d, [rbp-0x30]           ; (리사이즈 갈래)
0x1401eba23  call 0x140161f40              ;  RT::resize
0x1401eba28  mov rcx, [rbp-0x68]           ; ↘
0x1401eba2c  test byte ptr [rcx+0x48], 2   ; ← 두 갈래가 여기서 만난다. 조건은 clear 비트뿐
0x1401eba30  je  0x1401ebadf
```

즉 **이 루틴이 불릴 때마다, 크기가 안 변해도 클리어가 돈다.** "생성 시 1회" 는 기구의 성질이
아니라 **호출 빈도의 성질**이다. 그래서 질문은 `Effect::acquireRenderTargets`(`0x1401ea500`)의
호출 빈도 하나로 좁혀진다. 그것은 못 짚었다 — 이 함수는 이펙트 클래스 vtable
(**베이스 `0x140490488`**, 생성자 `0x1401e698e`·`0x1401e6b52` 가 `lea` 로 싣는다)의
**슬롯 23 = `+0xB8`** 이고, `call [reg+0xB8]` 사이트 24곳을 전수로 훑었지만 전부 다른 클래스의
vtable(`[[ctx+0xc8]+0x158]` 매니저 등)이라 이 클래스의 호출부를 특정하지 못했다.

함수적 배제는 그대로 유효하다: `clear` 를 가진 6장이 전부 속도/압력/염료이고 매 프레임 0 이면
이 이펙트가 어떤 그림도 못 만든다. 그러므로 "생성/리사이즈 시 1회" 로 취급하는 Waple 의 현행 규약
(`SceneRendererFrameEncoder.swift:2069-2075`)은 관측과 모순되지 않는다.

> **다만 갈라지는 구간이 하나 있다.** WE 는 이 루틴이 불리면 **크기가 그대로여도** 비운다.
> Waple 은 보유 텍스처의 `(폭, 높이, 포맷)` 이 어긋날 때만 재생성하고 그때만 `pendingClear` 에
> 넣는다(`SceneRendererFrameEncoder.swift` 의 주석 마커 `X-⑧` 아래 `uniqueStore` 할당 루프 —
> 이 파일도 동시 편집 중이라 행번호 대신 마커로 가리킨다).
> `fit:256` 버퍼는 1920×1080 ↔ 2560×1440 에서 **둘 다
> 256×144** 라 치수가 안 바뀌므로, 창을 그 사이로 리사이즈하면 **WE 는 (호출된다면) 비우고
> Waple 은 유지한다**. 그림 차이는 "리사이즈 순간 흐름이 리셋되는가" 한 프레임짜리이고,
> 도달 자산이 0건이라 지금 고칠 것은 아니다 — 위 호출 빈도가 확정되면 그때 판정할 자리다.

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

> **[정정 2026-08-21] 위 표의 "지수 감쇠만 한다" 는 비 HDR 씬에서 틀렸다 — 염료는 도중에
> 얼어붙는다.**
>
> `_rt_SmokeDye1/2` 는 `rgba_backbuffer` 라 씬 HDR 비트가 꺼지면 **`rgba8888`** 이다(§1.2).
> 설치본 씬 184개 중 `general.hdr` 이 참인 것은 **3개**뿐이고 **이 이펙트의 preview 씬도
> 거짓**이므로 기본 경로가 8비트다. 흐름이 멎으면 염료 패스는 `dye ← dye/(decay + lowPass)`
> 한 줄로 줄어드는데, 매 프레임 unorm8 로 접히므로 **감소분이 반 레벨(0.5/255) 미만이 되는
> 순간 값이 그대로 고정**된다.
>
> 60 fps 기본값(`dissipationfactor` 1.0 · `m_Dissipation` 0.4 → `decay = 1.00667`)에서:
> 255 에서 출발해 **165 프레임(2.75 s) 만에 레벨 75 에 도달한 뒤 영원히 멈춘다.**
> 화면 밝기로 **29 %** 다. `lowPass`(÷1.5)가 구해 주지 못하는 이유는 그 대역이 더 아래이기
> 때문이다 — `length(rgb) ≤ u_Lifetime` 은 기본 0.1 에서 레벨 14 이하, preview 의 0.32 에서도
> 레벨 47 이하라 **정체 레벨 75 에 못 닿는다.**
>
> **그리고 정체 레벨은 프레임률에 비례해 올라간다.** 프레임당 감소는 `1/fps` 로 줄어드는데
> 반올림 문턱은 `0.5/255` 로 고정이기 때문이다 — 즉 **모니터가 빠를수록 잔상이 밝다**:
>
> | fps | 10 · 20 | 30 | 60 | 120 | 144 |
> |---|---:|---:|---:|---:|---:|
> | 정체 레벨(기본 `lifetime` 0.1) | **25** | 37 | **75** | 150 | **180** |
> | 화면 밝기 | 9.8 % | 14.5 % | 29.4 % | 58.8 % | **70.6 %** |
>
> 10 fps 와 20 fps 가 같은 것은 `dt = min(1/20, g_Frametime)` 상한 때문이다(§2.12).
> 30 fps 이하에서는 `lowPass` 대역(preview `lifetime` 0.32 → 레벨 47)이 정체 레벨을 덮어
> 염료가 레벨 1까지 빠져나간다 — **같은 씬이 모니터에 따라 다르게 보이는 정확한 기구**다.
>
> **이식 규율**: 이건 결함이지만 **원본의 결함**이라 재현해야 그림이 같다. Waple 도 염료를
> `.rgba8Unorm` 으로 두는 한 자동으로 같은 정체가 난다 — 반대로 "정밀도를 올려 주자" 며
> 비 HDR 씬에서도 `.rgba16Float` 를 쓰면 **연기가 원본보다 깨끗하게 사라져** 갈린다.
> 값 잠금은 `Tests/WapleCoreTests/FluidSimulationPrecisionTests.swift`
> (`testStaticDyeFreezesPartWayDownInAnLDRBuffer` 외 셋).


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

> **[2026-08-21 3차 · 여전히 못 닫는다 — 왜 못 닫는지를 적어 둔다]** 이 항목(§9.0 의 G5)은
> **판별 불가**다. 자산 쪽 증거는 전부 소진했다(에디터 JS 1,548파일 0건 · 씬 스크립트 0건 ·
> `clearDye`/`clearVelocity` 는 어떤 바이너리에도 0건). 남은 유일한 수단은
> `wallpaperui.exe` 를 직접 디스어셈해 문자열 없이 부르는 경로가 있는지 보는 것인데
> 그 바이너리는 이 조사 범위 밖이다. **도달이 0이므로 우선순위도 최하위다**(§9.0).

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

> **~~[미해결] 파서 쪽 잠재 결함 하나.~~ → [해결 2026-08-21] 결함이 아니다 — 기재를 철회한다.**
>
> 종전 이 각주는 이렇게 적었다: 이름 탐색 커서 `esi` 가 `0x1401e85fb` 에서 `r13d` 로 시드되는데
> `xor r13d, r13d`(`0x1401e87e3`)를 건너뛰는 경로(`0x1401e85f2`)가 있으니 커서가 이월될 수 있다.
> **다시 떠서 보니 `r13` 은 커서가 아니라 MSVC 가 함수 전체에 걸쳐 쓰는 영(零) 레지스터다.**
>
> 증거는 세 갈래를 다 따라가면 나온다:
>
> * **함수 앞머리가 r13 을 상수 0 으로 쓴다** — `mov [rbp-0x70], r13d`(`0x1401e850a`) ·
>   `mov [rbp-0x58], r13`(`0x1401e850e`) · `mov rbx, r13`(`0x1401e8554`) ·
>   `mov rdi, r13`(`0x1401e8578`). 전부 "0 을 넣는" 자리다.
> * **탐색 갈래만 r13 을 더럽힌다** — `mov r13, [rbp-0x30]`(`0x1401e85fe`, 임시 문자열 포인터) ·
>   `mov r13, rax`(`0x1401e87d8`). 그래서 그 갈래 끝에 `xor r13d, r13d`(`0x1401e87e3`)로
>   **영 레지스터 불변식을 복구**한다. 커서 리셋이 아니다.
> * **건너뛰는 두 경로는 r13 을 아예 안 건드린다** — `0x1401e85f2`(빈 이름:
>   `asString`(`0x140085cc0`) 결과 길이 0 → `test r12,r12`/`jne` 가 `0x1401e85b1` 에서 안 갈림) ·
>   `0x1401e8597`(값 타입이 문자열(4)이 아님). 두 경로 사이 구간(`0x1401e8581`–`0x1401e85f2`)에
>   r13 을 쓰는 명령은 **읽기 둘뿐**이고 쓰기는 없다.
>
> ⇒ `esi` 는 **모든 항목에서 0 으로 시드된다.** 이월은 일어나지 않는다.
> (종전 기재가 무해했던 이유도 같이 적어 둔다: 이 이펙트의 두 목록은 인덱스가 오름차순이라
> 이월이 있었더라도 n=2 로 같았을 것이다. 그래서 그림으로는 판별이 안 됐고, 그게 이 오독이
> 오래 남은 이유다 — **공통 브리프 함정 #16 의 실례**다.)

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
않음" 이지만 두 백엔드 모두 `clamp((x-e0)/(e1-e0))` 로 계산해 의도대로 동작한다 — ~~**이식 시
`1 - smoothstep(0, size, x)` 로 "고치면 안 된다"**(감쇠 곡선이 다르다).~~

> **[정정 2026-08-21] 위 취소선 문장은 틀렸다 — 두 형태는 항등이다.**
> `t = clamp(1 − x/size, 0, 1)` 로 두면
> `smoothstep(size, 0, x) = t²(3−2t)` 이고
> `1 − smoothstep(0, size, x) = 1 − (1−t)²(1+2t) = 1 − (1 − 3t² + 2t³) = t²(3−2t)` 다.
> `x ≥ 0`, `size > 0` 전 구간에서 같은 값이고, 실측으로도 세 `size`(0.02·0.05·0.3) ×
> 201 표본에서 `1e-15` 안이다
> (`FluidSimulationTests.testReverseSmoothstepEqualsOneMinusForwardSmoothstep`).
>
> **그래서 권고가 뒤집힌다.** 정방향 형태로 바꾸면 그림이 같으면서 **`edge0 >= edge1` 이라는
> 명세상 미정의 호출을 피한다.** MSL 의 `smoothstep` 은 "edge0 >= edge1 이면 결과 미정의" 라고
> 명시하므로, GLSL 을 MSL 로 옮기는 Waple 에서는 정방향이 **더 안전한 이식**이다.
> (원본 GLSL 자산을 고치라는 뜻이 아니다 — 번역 결과물 이야기다.)
> §7 의 advection 행에 적힌 *"`smoothstep(edge0>edge1)` 역방향 호출을 '고치지 않는' 규율"* 도
> 같은 이유로 철회한다 — **감쇠 곡선이 아니라 미정의 동작이 걸려 있는 자리다.**

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
| 18 | `g_TextureNResolution` | `(paddedW,paddedH,imgW,imgH)` | fbo 는 `(w,h,w,h)` | 규약 일치(이 이펙트의 슬롯은 전부 렌더타깃이라 패딩 없음). 종전엔 값이 W1 때문에 틀렸다 — `fit` FBO 슬롯에 `(256,256,…)` 이 실려 `aspect`/`texelSize` 가 어긋났다. **2026-08-21 착지**: `fit` 갈래가 `fittedBox` 로 풀린다(1920×1080 이면 `(256,144,256,144)`) | `SceneRendererResources.swift:1206-1221` |
| 19 | 샘플러 어노테이션 `"default"`(`util/noise`, `gradient/gradient_fire`) | 자산 로드 | `t.textureDefaults[slot]` 폴백 + 이펙트 로컬 루트 | **지원**, 두 자산 모두 동봉에 존재 | `SceneRendererResources.swift:1226` |
| 20 | `mul(v,M)` HLSL 순서 | 행벡터 | `(b*a)` | 지원 | `GLSLTranslator.swift:1633-1636` |
| 21 | `inverse(mat3)`(common_perspective.h, `#if HLSL`) | HLSL 분기 컴파일 | `HLSL=1` 시딩 + `inverse→we_inverse` 리네임. 헤더 정의는 `inverse` 이름 그대로 방출되고 호출부만 `we_inverse` 로 가므로 **중복 정의 없음**(헤더 쪽은 죽은 함수) | 지원 | `ShaderPreprocessor.swift:38` · `GLSLTranslator.swift:1587,1943,2001` |
| 22 | `ddx`/`ddy`/`frac`/`saturate`/`CAST*`/`texSample2D` | HLSL 방언 | 전건 매핑 | 지원 | `GLSLTranslator.swift:1586-1690` |
| 23 | 조건문(`if (vL.x < 0.0) {...}`) · 다중 varying(vec2/vec3/vec4×3) | — | 본문 통과 + 타입 어댑터 | 지원 | — |
| 24 | 압력 9회 = 파이프라인 18개 | — | 패스별 `MTLRenderPipelineState` 18개(같은 셰이더 9개는 같은 MSL 이지만 별개 파이프라인) | 지원, 비용 축 | — |
| 25 | **샘플러 어드레싱(`fbos[].uvs`)** | 기본 인자 `2`(clamp), `uvs:"repeat"` 만 `0`. 파스 `0x1401e78ca`–`0x1401e7915`, 소비 `0x1401eb976`–`0x1401eb990` | bind 슬롯 기본 `texWrap=1`(clamp) + `uvsRepeat` FBO 소스 슬롯만 `0` | **지원 — 갭 없음**(신규 확정 §2.4a). 이 이펙트는 `uvs` 0건이라 아홉 장 전건 clamp 이고, 그게 §2.4 경계조건의 전제다 | `SceneRendererResources.swift` 마커 `X-①` |
| 26 | **`constantshadervalues` 의 미선언 키** | 매칭 없으면 그냥 안 실린다 | 동일(모르는 키 무시) | **지원** — 그래야 한다. 이 이펙트 preview 씬만으로 56건 중 **22건**이 대상 패스가 선언하지 않은 키다(§1.6.1). 경고를 찍으면 프레임마다 22줄 | — |
| 27 | **염료 버퍼 정밀도(`rgba_backbuffer` → 비 HDR 이면 `rgba8888`)** | 8비트 저장이 정지한 염료의 감쇠를 **완전히 멈춘다**(60 fps 에서 레벨 75 = 29 % 밝기, §4.3 정정) | 같은 포맷 규약(축 2) → **자동으로 같은 정체가 난다** | **일치 — 다만 의도적으로 지켜야 한다.** "정밀도를 올려 주자" 며 비 HDR 씬에서 `.rgba16Float` 를 쓰면 연기가 원본보다 깨끗하게 사라져 갈린다 | `SceneRendererResources.swift` 의 `metalFormat` (축 2 와 같은 자리) |
| 28 | **압력 버퍼 정밀도(`r16f`)** | 반복 9회에서는 float64 와 0.002 pp 차이. `u_Pressure = 1.0` 에서만 +31 pp 로 벌어진다(§2.13(e)) | 같은 포맷 | **일치 · 갭 없음.** 출하 설정에서 그림에 안 닿는다 | — |

### 6.2 판정 — 이걸 지금 로드하면

**돈다. 다만 한 군데가 틀리고 한 조건에서 통째로 폴백한다.**
(W1 은 **2026-08-21 착지** — 아래는 무엇이 왜 틀렸었는지의 기록 + 회귀 표면 실측이다.)

**W1 (P0) `fit` 종횡비 — 조용히 틀린 그림. [해결 2026-08-21]**
종전 `EffectManifest.swift:399-402` 이 `fixedW = clampedFixed(f["fit"]); fixedH = fixedW` 로
정사각을 만들었다. 1920×1080 에서 WE 는 **256×144**, Waple 은 **256×256**. 귀결 넷 —

1. `aspect = g_Texture0Resolution.y/.x` 가 **0.5625 대신 1.0**. 염료 에미터(§5.4)의 원이
   **가로로 16:9 만큼 늘어난다**. 중력(`constantSpeed.y *= aspect`)도 세로 성분이 1.78배 세진다.
2. 텍셀이 화면에서 정사각이 아니게 되어 **유한차분 솔버 전체가 이방성**을 얻는다.
   같은 속도 벡터가 x 로는 1920/256 = 7.5 px, y 로는 1080/256 = 4.2 px 를 움직인다 —
   흐름이 가로로 1.78배 늘어져 보인다.
3. 커서 임펄스 반경도 `v_PointerUV.w = (H/W)·60/CI` 가 1·60/CI 가 되어 **세로로 찌그러진다**.
4. 메모리: 256×144 → 256×256 은 속도/압력/발산/컬 6장에서 1.78배(작은 절대량이라 무해).

**실제 착지 모양.** `FBO` 가 `fit`/`declaredWidth`/`declaredHeight` 셋을 **따로** 들고
(파스 시점엔 dst 를 모르므로 치수로 접을 수 없다), 규약 전문은
`EffectManifest.FBO.fittedBox(baseWidth:baseHeight:)` 주석에 VA 와 함께 있다.
`fit` 이 없으면 그 함수가 `nil` 을 돌려 **소비처가 종전 경로를 그대로 탄다** — 이게 무회귀의
핵심 장치다. 소비처는 둘:

* `SceneRendererFrameEncoder.swift:2034-2036` — 실제 텍스처 할당(프레임 시점 `dst` 기준).
* `SceneRendererResources.swift:1214-1216` — `g_TextureNResolution`(빌드 시점 `effW/effH` 기준).
  `fit` 미선언 갈래는 **한 글자도 안 건드렸다**. 특히 scale 갈래는 정수 바닥이 아니라
  부동소수 나눗셈(`lh/s`)이라, 정수화하면 dst 가 scale 로 나누어떨어지지 않는 모든 씬에서
  값이 움직인다. 그건 별건이고 이 커밋의 범위가 아니다.

`fixedWidth`/`fixedHeight` 는 하위호환 표현으로 남겼고 `fit` 만 있는 FBO 에서는 **정사각
봉투**를 되비춘다 — 그것을 치수로 쓰면 W1 이 되살아나므로 함정을
`EffectFboFitTests.testLegacyFixedSizeMirrorsTheEnvelopeNotTheResult` 가 지킨다.

**회귀 표면 전수(동봉 + 설치본 `wallpaper_engine/assets`, FBO 선언 112건 실측).**
`fit` 보유는 **28건 = 이펙트 2종**이고 나머지 82건은 `fit` 미선언이라 **전건 종전 그대로**다.

| 이펙트 / FBO | `fit` | dst | 종전(정사각) | 새 규약 | 그림이 바뀌나 |
|---|---:|---|---|---|---|
| `fluidsimulation` `_rt_SmokeVelocity1/2`·`Pressure1/2`·`Divergence`·`Curl` (6장 ×2트리 ×본체/preview = 24건) | 256 | 1920×1080 | 256×256 | **256×144** | **예** |
| 〃 | 256 | 2560×1440 | 256×256 | **256×144** | **예** |
| 〃 | 256 | 1080×1920 | 256×256 | **144×256** | **예** |
| 〃 | 256 | 256×256 (**동봉 preview 씬**) | 256×256 | 256×256 | 아니오 |
| `cursorripple` `_rt_EightBuffer1/2` (2장 ×2트리 = 4건) | 512 | 1920×1080 | 512×512 | **512×288** | **예** |
| 〃 | 512 | 256×256 (**동봉 preview 씬**) | 512×512 | **256×256** (확대 금지) | **예** |
| `glitter` `_rt_GlitterTiles` (`width`/`height` 256×256, 4건) | — | 임의 | 256×256 | 256×256 | 아니오 |
| 나머지 82건(`scale` 또는 무선언) | — | 임의 | `dst/scale` | `dst/scale` | 아니오 |

**출하 자산이 실제로 마운트하는 씬에서 바뀌는 건 하나뿐이다.** `scene.json` 전수 355개
(동봉 + 설치본)에서 `fit` 보유 이펙트를 쓰는 자리는 **4건**이고 전부 두 이펙트의
`preview/scene.json`(256×256 정사각 레이어 + 256×256 오르토)이다. 그중
`fluidsimulation` 은 정사각이라 **불변**이고, `cursorripple` 은 확대 금지가 걸려
**512×512 → 256×256** 으로 바뀐다. 즉 **동봉 도달 그림 변화 = 1이펙트 × 2FBO × 2트리**.
1920×1080 워크샵 콘텐츠에서의 개선(위 표 1·2·5행)은 코퍼스에 자산이 없어 **수치로만** 남긴다.

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
| advection (velocity + dye, 같은 셰이더) | **중상** | `DYE` 로 갈리는 두 인스턴스 + `RENDERING` 3분기 × `POINTEMITTER`/`LINEEMITTER` × `COLLISIONMASK`/`DYEEMITTER`/`PERSPECTIVE`. 그리고 **`g_Texture0Resolution` 이 염료 패스에서도 속도 해상도**라는 규약을 놓치면 이류 거리가 2배 틀린다. `smoothstep(edge0>edge1)` 역방향 호출은 **정방향 `1 - smoothstep(0, size, x)` 로 옮기는 편이 안전하다**(§5.4 정정 — 두 형태는 항등이고 정방향만 명세상 정의돼 있다) |
| combine | **상** | 셋이 겹친다: ① `BLENDMODE` 33종(`common_blending.h` 전체) ② `#require LightingV1` 코드 생성 + 라이트 배열 피드(= W2, 이 리포에서 가장 큰 미착지 블록) ③ `RENDERING==3` 의 `ddx`/`ddy` 화면공간 미분(이펙트 체인 안에서 dst 해상도 기준이라 스케일드 FBO 와 섞이면 규약이 흔들린다). 게다가 유일하게 MVP 를 쓰는 패스다 |
| **자원 관리 전체** | **중** | `unique` 8장 지속 + swap + `fit` 종횡비 + 포맷별 타깃. **2026-08-21 로 전건 착지**(W1 포함) |

가장 싼 착지 순서는 **W1(fit) → W3(투영행렬) → W2(LightingV1)** 이었다.
W1 은 순수 산술이라 리눅스 레인에서 단위 테스트로 닫히고 그림 개선폭이 가장 커서 먼저 갔다
(2026-08-21, `Tests/WapleCoreTests/EffectFboFitTests.swift` 11케이스). **남은 것은 W3 → W2** 다.

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

### 9.0 갭 도달표 — **[신규 2026-08-21]**

이 문서는 리포에서 `[미해결]` 문자열이 가장 많은 문서다 — **3차 실측 직전 기준 19줄**
(이 절이 그 19줄을 설명하면서 문자열을 더 쓰므로 지금 세면 더 나온다. 아래 분류는
**3차 실측 직전**의 19줄에 대한 것이다):

| 종류 | 줄 수 | 내용 |
|---|---:|---|
| **고유 미해결 사실** | **8** | 아래 다섯 건(G1 2줄 · G2 2줄 · G3 1줄 · G4 2줄 · G5 1줄) |
| 이미 닫힌 항목의 툼스톤 | 7 | §1.3.1 · §1.6.3 · §4.5 각주 · §9-5·6·7·8 |
| 다른 절·코드로의 참조 | 4 | 머리말 · §4.6(`SceneRendererFrameEncoder` 주석) · §8-2 · 부록 A ⑥c |

즉 **열려 있는 사실은 다섯 건**이다. 각 건의 **도달**(= 그 사실을 모르면 몇 개의 실물 자산이
틀리게 렌더되나)을 동봉 `WEAssets` + 설치본 `wallpaper_engine` 전수로 재면:

| # | 갭 | 절 | 지배하는 선언 | 그림이 틀릴 씬(동봉 171 + 설치본 184 = **355**) | 워크샵 | 상태 |
|---|---|---|---|---:|---|---|
| **G4** | `r16f`/`rg16f` 반올림 | §2.13 · §9-4 | `r16f` 8 + `rg1616f` 4 = **FBO 선언 24건**(양 트리, 전건 이 이펙트) | **2** (양 트리의 `fluidsimulation/preview`) | 미측정 | **[해소 2026-08-21]** — 답은 "출하 설정에서 그림 차이 0". 대신 **비 HDR 염료의 `rgba8888`** 이 훨씬 크게 문다(§4.3 정정) |
| **G1** | `acquireRenderTargets` 호출 빈도 | §3.3 · §9-1 | `clear` 보유 **FBO 선언 24건**(양 트리, 전건 이 이펙트) | **2**, 그것도 "리사이즈 순간 1프레임" 조건부 | 미측정 | 열림 — 이번에 **더 좁혔다**(아래 G1) |
| **G5** | `wallpaperui.exe` 네이티브 호출 경로 | §4.4 | `clearDye`/`clearVelocity` 문자열 **자산 1파일**(바이너리 0건) | **0** | 미측정 | 열림 — 판별 불가(그 바이너리 디스어셈은 범위 밖) |
| **G2** | 에디터가 `LIGHTING` 을 `effects[].combos` 에 쓰는가 | §1.5 · §9-2 | `conditions` 보유 **effect.json 4건**(양 트리 본체+preview) | **0** — 355 씬 전수에서 `effects[].combos` **0건** | 미측정 | 열림 — 이번에 **양성 증거**를 얻었다(아래 G2) |
| **G3** | 워크샵 코퍼스 사용 분포 | §9-3 | — | 정의상 측정 불가 | **미측정** | 열림 — 이 컨테이너에 워크샵 pkg 가 없다 |

**읽는 법 셋.**

* **도달의 상한이 2다.** 이 이펙트를 마운트하는 씬이 양 트리 통틀어 preview 둘뿐이기 때문이다
  (§1.6.2). 즉 **남은 다섯 건 중 어느 것도 출하 배경화면의 그림을 바꾸지 않는다.**
  이 문서가 값을 하는 자리는 출하 콘텐츠가 아니라 **워크샵 이식 충실도**다.
* **"0" 과 "미측정" 을 섞지 마라.** 위 표의 0 은 355 씬 전수 측정 결과이고, 워크샵 열은
  전부 **미측정**이다(코퍼스가 없다 — `docs/dev/re-methodology.md` §0-2).
* 그래서 닫는 순서는 도달이 아니라 **닫을 수 있느냐**로 정했다. G4 는 순수 산술이라 이
  컨테이너에서 끝까지 닫힌다. G1·G5 는 바이너리, G2 는 에디터, G3 은 코퍼스가 필요하다.

**아직 열려 있는 것**

1. **[미해결] `Effect::acquireRenderTargets`(`0x1401ea500`)의 호출 빈도**(§3.3).
   클리어 기구 자체는 이제 완전히 열렸다 — 생성 갈래와 리사이즈 갈래가 `0x1401eba2c` 에서
   **합류**하므로 이 루틴이 불릴 때마다 `clear` 비트가 선 FBO 는 비워진다. 남은 것은
   "얼마나 자주 불리는가" 하나다. 이 함수는 이펙트 vtable(베이스 `0x140490488`, 생성자
   `0x1401e698e`·`0x1401e6b52`)의 **슬롯 23 = `+0xB8`** 이고, 이미지 전체에서
   `call [reg+0xB8]` 24곳을 훑었지만 전부 다른 클래스의 vtable 이었다.
   함수적 배제(매 프레임일 수 없다)만 세웠다. **다음 수단**: 이 vtable 을 `[obj]` 에 심는
   생성자 두 곳에서 객체가 어느 컨테이너에 등록되는지 따라가 그 컨테이너의 순회 지점을 찾는 것.

   **[2026-08-21 재측 — 여전히 열려 있지만 세 가지가 새로 확정됐다]**
   * **직접 호출이 이미지 전체에 0건이다.** `.text` 를 바이트로 훑어 `call rel32`(`E8`)·
     `jmp rel32`(`E9`)의 목적지가 `0x1401ea500` 또는 슬롯 22 `0x1401ea310` 인 자리를 셌더니
     **둘 다 0**이다. 즉 이 루틴은 **오직 가상 디스패치로만** 도달한다 — 인라인된 직접 호출을
     찾는 시도는 무의미하다.
   * **`call [reg+0xB8]` 은 24곳이 아니라 25곳이다.** 종전 스캔이 **SIB 형식**(`modrm.rm == 4`,
     즉 `call [base+index*s+0xB8]`)을 한 자리 놓쳤다. 25곳 전건이 수신자를
     `[[ctx+0xc8]+0x158]` 꼴 매니저에서 뽑는다는 결론은 그대로다(예:
     `0x1401f69ef`·`0x1401f6ad8`·`0x1401f6be3`·`0x1401f6d13` 네 곳이 함수 `0x1401f5980` 안에서
     같은 매니저를 부른다).
   * **"어느 vtable 로 오든 `+0xB8`" 은 맞지만, 그것을 확인하는 순진한 방법은 틀린다.**
     이 바이너리는 vtable[-1] 에 RTTI 로케이터가 **없어서**(`0x140490488` 앞 칸이
     `0x2f`, `0x1404911a8` 앞 칸이 `0x1401fbae0` 로 둘 다 포인터가 아니다) 인접한 vtable 들이
     **하나의 연속된 포인터 배열로 보인다.** 그래서 "함수 포인터가 아닐 때까지 거슬러 올라가
     베이스를 찾는" 방법은 `0x140491260` 을 **슬롯 45(+0x168)** 로 잘못 판정한다.
     알려진 표(여기서는 `0x140490488`)와 **정렬**해서 풀어야 실제 베이스 `0x1404911a8` 이
     나오고 그때 `0x140491260 − 0x1404911a8 = 0xB8` 로 슬롯 23 이 된다.
     (`0x140491a08`→베이스 `0x140491950`, `0x140491dc8`→베이스 `0x140491d10` 도 같다.)
2. **[미해결] 에디터가 `LIGHTING` 을 `effects[].combos` 에도 쓰는가**(§1.5).
   출하 씬 184개에 `effects[].combos` 가 0건이라 역산 불가. 에디터 프런트엔드(`ui/dist`, 1,548
   파일)의 JS 에서 `combos` 를 쓰는 자리는 `shaderpreset.combos` 하나뿐이라 **거기서도 답이
   안 나온다** — 이펙트 콤보 저작은 네이티브 `wallpaperui.exe` 안에 있고 그 바이너리는
   이 조사 범위 밖이다. 안 쓴다면 WE 자신도 `LIGHTING=1` 에서 `g_Texture2` 미바인드로 돈다.

   **[2026-08-21 재측 — 부재 증명에서 양성 증거로 올라갔다. 그래도 못 닫는다.]**
   종전 근거는 "`effects[].combos` 가 0건" 이라는 **부재**뿐이었다. 이번에는 이 이펙트의
   preview 씬(= WE 에디터가 실제로 저장한 유일한 사례)에서 **에디터가 콤보를 어떻게 쓰는지**
   를 직접 봤다(§1.6.1a). 결론: **콤보는 그 콤보를 선언한 셰이더의 패스에만** 실린다 —
   `LINEEMITTER`/`POINTEMITTER` → 21·34·35(vorticity·advection ×2), `BLENDMODE` → 37(combine),
   `DYE` → 35. 선언 안 한 패스에는 **한 건도** 없다. `constantshadervalues` 가 22건이나
   흩뿌려지는 것(§1.6.1)과 정반대다 — 즉 에디터 안에서 **콤보 경로와 값 경로는 다른 코드**다.
   `LIGHTING` 은 `combine.frag` 에만 선언돼 있으므로 이 규칙대로면 `passes[17].combos` 로만
   가고 `conditions` 는 영원히 거짓이다.
   **왜 그래도 못 닫나**: 이것은 "속성 편집 레인" 하나의 행동이다. 이펙트 인스턴스 레벨의
   별도 UI 가 `effects[].combos` 를 쓸 가능성은 여전히 배제 못 한다 — 그걸 배제하려면
   `wallpaperui.exe` 네이티브를 떠야 하고 그건 이 조사 범위 밖이다. **판별 불가**로 남긴다.
3. **[미해결] 워크샵 코퍼스에서의 실제 사용 분포.** 이 컨테이너에 워크샵 pkg 가 없어
   `functions`/`executeMaterialFunction`/`effects[].combos` 의 실사용 빈도를 못 쟀다.
   설치본만으로는 "출하 콘텐츠 도달 0" 까지가 한계다.
4. ~~[미해결] `r16f`/`rg16f` 반올림이 §2.13 의 수치에 미치는 영향.~~ → **[해소 2026-08-21]**
   종전 기재는 이랬다: *"그 절은 float64 로 재현한 것이고 실물은 반가수 10비트다. 잔차가
   작아지는 구간에서 실물이 더 나쁠 것은 확실하나 얼마나인지는 재지 않았다. 압력장이 `r16f`
   한 장이라는 점(§1.2)이 실제 수렴 한계를 §2.13(b)보다 앞당길 수 있다."*

   **재 봤다. "확실하다" 던 그 예측이 출하 설정에서는 틀렸다.** 전문은 §2.13(e).
   요지 셋 —
   * **반복 9회에서는 차이가 0.01 pp 안이다.** §2.13(a) 때문이다 — 9회는 큰 규모 오차를
     손도 못 대므로 **절단 오차가 반올림 오차를 세 자릿수 압도한다.**
     따라서 **§2.13(b)·(c)의 float64 표는 실물에서 그대로 유효하다.**
   * **반올림이 실제로 무는 자리는 정확히 하나다** — `u_Pressure` 를 **1.0** 으로 둔
     따뜻한 시작. 압력이 프레임을 넘어 무한히 누적되면 한 번의 Jacobi 갱신이 반 ulp
     (상대 `2^-11`) 아래로 내려가 저장에서 통째로 사라진다. 256×144·600프레임 실측:
     정상상태 잔차가 float64 **24.30 %** ↔ binary16 **55.43 %** 로 **+31.1 pp** 갈린다.
     `u_Pressure ≤ 0.95` 에서는 누적 상한이 생겨 차이가 0.02 pp 아래로 사라진다 —
     **§2.13(d)가 "0.8 은 거의 벌어 주지 않는다" 고 한 그 감쇠가 `r16f` 한계도 같이 가린다.**
   * **압력장이 아니라 염료 버퍼가 진짜 문제다.** `_rt_SmokeDye1/2` 는
     `rgba_backbuffer` 라 비 HDR 씬에서 **`rgba8888`** 이고(설치본 씬 184개 중 `general.hdr`
     참은 **3개**뿐, 이 이펙트의 preview 씬도 거짓), 8비트 반올림이 감쇠를 **완전히 멈춘다**.
     §4.3 의 기재를 이것으로 정정했다.

   재현은 리포 안에서 돈다 — `Sources/WapleCore/FluidSimulationPrecision.swift`(binary16·unorm8
   양자화) · `FluidSimulationGrid.swift`(발산→Jacobi→경사 제거) ·
   `Tests/WapleCoreTests/FluidSimulationPrecisionTests.swift`.

**이번에 닫은 것**(툼스톤 — 종전 항목 번호를 남긴다)

5. ~~[미해결] `fit` × `scale` 동시 선언~~ → **[해결] §1.3.1.** `scale` 은 `fit` 계산에 참여하지
   않고 렌더타깃 생성자 `0x1400d2c60` 이 나눈다. 최종 = `max(2, W'/scale) × max(2, H'/scale)`.
   코퍼스 도달 0건(FBO 선언 112건 중 `fit`+`scale` 동시 0건). **이 항목이 §1.3.1 착지 이후에도
   목록에 남아 있었다 — 그 자체가 기재 오류였고 여기서 정리한다.**
6. ~~[미해결] `functions` 파서의 탐색 커서 이월~~ → **[해결] §4.5 각주.** 이월은 없다.
   `r13` 은 커서가 아니라 MSVC 영 레지스터이고, `xor r13d,r13d`(`0x1401e87e3`)를 건너뛰는 두
   경로(`0x1401e85f2`·`0x1401e8597`)는 r13 을 애초에 더럽히지 않는다. **원래 기재가 오독이었다.**
7. ~~[미해결] `wallpaperui.exe` 의 `executeMaterialFunction` 용례~~ → **[해결] 버튼은 없다.**
   에디터 프런트엔드 `ui/` 1,548 파일 전수에서 `executeMaterialFunction` 히트는
   `monaco/autocomplete/lib.sceneScript.d.ts`(= 저작자용 자동완성 선언) **한 줄뿐**이고,
   `clearDye`/`clearVelocity` 는 설치본 **전체**에서 `assets/effects/fluidsimulation/effect.json`
   **한 파일**에만 있다(바이너리 0건, JS 0건). 에디터 UI 는 JS 주도이므로(§1.6.3 의
   `attachmentproject` 버튼이 그 패턴을 보여 준다) UI 버튼이 있으려면 JS 에 이름이 있어야 한다.
   없다. **잔여 리스크**: `wallpaperui.exe` 네이티브 안에 문자열 없이 호출하는 경로가 있을
   가능성은 배제 못 한다 — 그 바이너리 디스어셈은 이 조사 범위 밖이다.
8. ~~[미해결] `attachmentproject` / `attachmentangles`~~ → **[해결] §1.6.3.** 런타임 바이너리
   전수 0건, 에디터 `wallpaperui.exe` 만 각 1건. 씬 스크립트 링크 스크립트를 생성해 주는
   **저작 편의 어노테이션**이고 런타임 소비는 없다. 종전 기재의 건수 "12" 도 정정했다 —
   `attachmentproject` **10** · `attachmentangles` **4**(그리고 후자는 불리언이 아니라
   짝 각도 프로퍼티 **이름 문자열**이다).

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
python3 "$SP/vdis2.py" 0x1401efca0 0x1401f01b0   # 스크립트 메서드 등록표(함수 시작 = 0x1401efca0)
python3 -c "import sys;sys.path.insert(0,'$SP');import wxref;print(wxref.funcs_of(0x1401e63b0))"
#   → {0x1401e7170: [0x1401e7405, 0x1401e79fe, 0x1401e7ed0]} — conditions 평가 3지점. [VA-스캐너위치]
#     주의: wxref 가 돌려주는 값은 **rel32 피연산자의 주소**이지 호출 명령의 시작이 아니다
#     (방법론 함정 #16b). 실제 `call` 명령은 각각 **0x1401e7404 · 0x1401e79fd · 0x1401e7ecf** 다 —
#     문서 본문은 이 셋을 인용해야 하고, 위 출력을 그대로 베끼면 안 된다.
#     대조 도구: WE_ROOT=<설치본> python3 scripts/re/va_citations.py docs/re/fluid-simulation.md

# ⑥b 어드레싱(§2.4a) — 파스 · 소비 · 엔진 프레임버퍼의 상수 2
#    **반드시 함수 시작에서 선형으로 내려온다.** 임의의 중간 주소를 시작으로 주면 vdis2 가
#    명령 경계를 잃고 쓰레기를 뱉는다(공통 브리프 §1). 원하는 구간은 grep 으로 골라라.
python3 "$SP/vdis2.py" 0x1401e7170 0x1401e8a9d | sed -n '/1401e78ca/,/1401e7918/p'  # uvs=="repeat" → +0x48 bit2
python3 "$SP/vdis2.py" 0x1401ea500 0x1401ebbb6 | sed -n '/1401eb96a/,/1401eba30/p'  # bit2 → 인자 0/2 → createRenderTarget
python3 "$SP/vdis2.py" 0x14017f1b0 0x14017fa6f | grep -n 'rsp + 0x38\], 2\|call 0x1401aadb0'  # 프레임버퍼 5장 전부 2
python3 "$SP/vdis2.py" 0x1401e7170 0x1401e8a9d | sed -n '/1401e8593/,/1401e8691/p'  # functions 이름 탐색(§4.5 각주)

# ⑥c vtable 슬롯 확인(§3.3 [미해결] 1)  → 베이스 0x140490488, +0xB8 = 0x1401ea500
python3 - <<'EOF6C'
import sys,struct; sys.path.insert(0,'$SP')
from wpe import pe, DATA
o=pe.va2off(0x140490488)
for k in range(0x18):
    print(hex(0x140490488+8*k), hex(struct.unpack_from('<Q',DATA,o+8*k)[0]))
EOF6C

# ⑦ §2.13 수치 실험 — 셰이더 식 그대로(격자 256×144, divergence 반사 4면, 나머지 clamp).
#    반복수 n 과 gradientsubtract 계수(1.0 / 0.5)를 바꿔 잔존 발산을 재는 것이 전부다.
#    ~~스크립트는 세션 스크래치에 두었다(AO_jacobi.py / AO_jacobi2.py / AO_proj2.py).~~
#    **[2026-08-21] 그 스크립트는 컨테이너와 함께 사라졌다 — 즉 이 표를 재현할 수단이
#    리포에 없었다.** 이제 리포 안에 있다:
#        Sources/WapleCore/FluidSimulationGrid.swift        발산 → Jacobi ×N → 경사 제거
#        Sources/WapleCore/FluidSimulationPrecision.swift   binary16 / unorm8 양자화
#        Sources/WapleCore/FluidSimulation.swift            패스별 프래그먼트 산술
#        Tests/WapleCoreTests/FluidSimulation{,Precision}Tests.swift
#    회귀 테스트는 디버그 빌드 시간 때문에 작은 격자(32×18·64×36)를 쓰고 **부호와 자릿수만**
#    잠근다. 문서의 256×144 절대값을 다시 뽑으려면 같은 API 를 그 크기로 부르면 된다:
#        FluidSimulationGrid.projectionResidualPercent(velocityX:velocityY:width:height:
#                                                      iterations:coefficient:precision:)
#        FluidSimulationGrid.warmStartResidualPercent(divergence:width:height:frames:
#                                                     iterationsPerFrame:pressureDecay:precision:)
#    실행: scripts/dev/linux-core-tests.sh --filter FluidSimulation

# ⑦b §2.13(e) 정밀도 축 — binary16 은 `Double → Float → binary16`(최근접-짝수)로 접는다.
#    (e-1) 반복 9/18/50 에서 float64 와 binary16 의 잔존 발산 차이 → 0.002 / 0.003 / 0.010 pp
#    (e-2) u_Pressure 0.8 / 0.95 / 1.0 · 600프레임 정상상태 잔차
#          → 94.29↔94.30 · 83.48↔83.50 · **24.30↔55.43**
#    (e-3) LDR 염료 정체: FluidSimulationPrecision.ldrDyeDecayFixedPoint(
#              startLevel: 255, dissipationFactor: 1.0, materialDissipation: 0.4,
#              lifetime: 0.1, frameTime: 1.0/fps)
#          → fps 10·20 → 25 · 30 → 37 · 60 → 75 · 120 → 150 · 144 → 180

# ⑦c §1.6.1a 콤보 vs 값 — preview 씬의 패스 오버라이드를 셰이더 [COMBO] 선언과 대조
python3 - <<'EOF7C'
import json, re, os
FX='/home/user/Waple/Sources/WapleRender/Resources/WEAssets/effects/fluidsimulation'
rj=lambda p: json.loads(re.sub(r',(\s*[}\]])', r'\1', open(p, encoding='utf-8').read()))
eff=rj(f'{FX}/effect.json'); scene=rj(f'{FX}/preview/scene.json')
sc=[e for o in scene['objects'] for e in (o.get('effects') or []) if 'fluid' in str(e.get('file',''))][0]
for p, sp in zip(eff['passes'], sc['passes']):
    if 'command' in p: continue
    sh=rj(f'{FX}/{p["material"]}')['passes'][0]['shader']
    declared=set()
    for ext in ('.frag', '.vert'):
        f=f'{FX}/shaders/{sh}{ext}'
        if os.path.exists(f):
            declared |= set(re.findall(r'"combo"\s*:\s*"([^"]+)"', open(f, encoding='utf-8').read()))
    got=set((sp.get('combos') or {}).keys()) - {'DYE'}   # DYE 는 머티리얼이 켠다
    print(sp.get('id'), sh.split('/')[-1], '선언', sorted(declared), '씬', sorted(got),
          '미선언', sorted(got - declared))
EOF7C
#   기대: '미선언' 이 전 패스에서 빈 목록 — 값과 달리 콤보는 흩뿌려지지 않는다(§1.6.1a)

# ⑧ 저작 오버라이드 vs 셰이더 선언(§1.6.1) · 씬 도달(§1.6.2) · 셰이더 전수(§1.7)
python3 - <<'EOF8'
import os,json,re,hashlib
FX='/home/user/Waple/Sources/WapleRender/Resources/WEAssets/effects/fluidsimulation'
rj=lambda p: json.loads(re.sub(r',(\s*[}\]])',r'\1',open(p,encoding='utf-8').read()))
eff=rj(f'{FX}/effect.json'); scene=rj(f'{FX}/preview/scene.json')
sc=[e for o in scene['objects'] for e in (o.get('effects') or []) if 'fluid' in str(e.get('file',''))][0]
def matkeys(base):
    ks=set()
    for ext in ('.frag','.vert'):
        p=f'{FX}/shaders/{base}{ext}'
        if os.path.exists(p):
            ks |= set(re.findall(r'"material"\s*:\s*"([^"]+)"', open(p,encoding='utf-8').read()))
    return ks
D=U=0
for p,sp in zip(eff['passes'], sc['passes']):
    if 'command' in p: continue
    sh=rj(f'{FX}/{p["material"]}')['passes'][0]['shader']
    ks=matkeys(sh); ov=set((sp.get('constantshadervalues') or {}).keys())
    D+=len(ov&ks); U+=len(ov-ks)
print('선언된 키 오버라이드', D, '· 미선언', U)      # 기대: 34 / 22
for t in ('shaders/effects','preview/shaders/effects'):
    for f in sorted(os.listdir(f'{FX}/{t}')):
        b=open(f'{FX}/{t}/{f}','rb').read()
        print(t.split('/')[0], f, len(b.splitlines()), hashlib.sha256(b).hexdigest()[:8])
EOF8
#   기대: divergence/pressure/gradientsubtract 의 .vert 가 전부 sha 2a546c13 · 23줄
#         본체↔preview 가 다른 파일은 combine.frag / combine.vert / vorticity.frag 셋뿐

# ⑨ attachment 어노테이션 · executeMaterialFunction 의 에디터 도달(§1.6.3 · §9-7·8)
python3 - <<'EOF9'
import os
WE='/home/user/Waple-wallpaper-source/wallpaper_engine'
for dp,_,fs in os.walk(WE):
    for f in fs:
        if not f.lower().endswith(('.exe','.dll')): continue
        d=open(os.path.join(dp,f),'rb').read()
        for s in ('attachmentproject','attachmentangles'):
            a,u=d.count(s.encode()), d.count(s.encode('utf-16-le'))
            if a or u: print(os.path.join(dp,f).replace(WE,''), s, a, u)
EOF9
#   기대: bin/wallpaperui.exe 와 그 distribution 사본만, 각 (1, 0). 런타임 바이너리 0건.
grep -rl 'attachmentproject\|attachmentangles' "$WE" | grep -v '\.exe$'   # JS 1 + frag 1
grep -rl 'executeMaterialFunction' "$WE/ui"                              # .d.ts 1건뿐
grep -rl 'clearDye\|clearVelocity' "$WE"                                 # effect.json 1건뿐
```

게이트: `python3 scripts/spec/check_address_ranges.py` · `python3 scripts/spec/validate.py`
(둘 다 이 문서 작성 전후로 오류 0).

**인용 VA 기계 대조(문서 전건).** 이 문서에 적힌 `0x14…` 주소를 전부 뽑아
`.pdata` 함수 시작에서 **선형으로** 디스어셈해 명령 경계인지 대조했다(뒤로 디스어셈 금지).
2026-08-21 실행 결과 — 인용 주소 **229개** 중:

* `.text` 안 **174건** → 명령 경계 **173건 OK**. 유일한 비-경계는 `0x1401ebae0` 인데, [VA-정정]
  이건 위 ⑥ 의 `vdis2.py <시작> <끝>` 의 **끝 인자**라 경계일 필요가 없다(시작만 경계여야 한다).
* `.rdata` 등 `.pdata` 밖 **52건** — 문자열 앵커와 vtable 앵커라 명령 검사 대상이 아니다.
* 예외 3건(`0x1401e7405` · `0x1401e79fe` · `0x1401e7ed0`)은 `wxref` 가 돌려주는 [VA-스캐너위치]
  **rel32 피연산자 주소**라 역시 대상이 아니다.

**[2026-08-21 3차 · 재대조와 정정]** 리포에 `scripts/re/va_citations.py` 가 생겨서 그것으로 다시
돌렸다(`WE_ROOT=<설치본 사본> python3 scripts/re/va_citations.py docs/re/fluid-simulation.md`).
고유 VA **234** · 데이터/리프 52 · 경계 OK 174 · **경계 이탈 8** 이고, 8건의 정체는 전부 설명된다:

| VA | 정체 | 조치 |
|---|---|---|
| `0x1401e7ed0` | `call 0x1401e63b0` 의 **rel32 피연산자 위치**(+1) | **본문을 `0x1401e7ecf` 로 정정**(§1.5) — 방법론 함정 #16b | [VA-스캐너위치]
| `0x1401e7405` · `0x1401e79fe` | 〃 (본문은 이미 올바른 `0x1401e7404`·`0x1401e79fd` 를 쓴다) | 부록 ⑥ 주석에만 남는 `wxref` 출력이라 그대로 두되 명령 주소를 병기했다 | [VA-스캐너위치]
| `0x1401ebae0` | `vdis2.py` 의 **끝 인자** | 그대로(끝은 경계일 필요가 없다) | [VA-정정]
| `0x14017f480` · `0x1401e78b0` · `0x1401eb960` · `0x1401effc0` | 이 문단 **아래**의 정오 기록이 "종전에 틀렸던 주소" 로 인용하는 값들 | 그대로(기록이므로 남겨야 한다) | [VA-정정]

즉 **본문에 남아 있던 비-경계 인용은 `0x1401e7ed0` 한 건이었고 이번에 정정했다.** [VA-정정]

이 대조로 이번 갱신의 초안에서 **비-경계 시작 주소 3건**(`0x1401e78b0` · `0x1401eb960` · [VA-정정]
`0x14017f480`)과 종전부터 있던 **1건**(`0x1401effc0`)을 잡아 함수 시작으로 바꿨다. [VA-정정]
재현:

```python
import sys, re, io, contextlib
sys.path.insert(0, SP)
from wpe import merged
from vdis2 import dis
for va in VAS:                      # 문서에서 뽑은 VA 목록
    m = merged(va)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        out = dis(m[0], m[1])       # ← 반드시 함수 시작부터
    txt = out if isinstance(out, str) else buf.getvalue()
    starts = {int(x.group(1), 16) for x in
              (re.match(r'^(0x[0-9a-f]+)\s+([0-9a-f]+)\s+(.*)$', l) for l in txt.splitlines()) if x}
    assert va in starts, hex(va)
```

## 부록 B — 이 문서가 인용한 함수 범위

| 함수(가칭) | 범위 | 역할 |
|---|---|---|
| `Effect::parse` | `0x1401e7170`–`0x1401e814e` | `combos`(`0x1401e7319`) · `fbos`(`0x1401e735c`) · `passes` · `conditions` 3지점 |
| ↳ fbo 필드 파스 | `0x1401e7440`–`0x1401e7969` | `scale`/`fit`/`width`/`height`/`unique`/`clear`/`uvs`/`format`, 백버퍼 치환 `0x1401e7562` |
| ↳ clear 문자열 파스 | `0x1401e7629`–`0x1401e777b` | 스페이스 4성분, 성공 시 `+0x48` bit1 (`0x1401e7771`) |
| ↳ `functions` 파스 | `0x1401e8248`–`0x1401e88a1` | 키 사전순, action `clear` 고정, 이름→인덱스 선형탐색 `0x1401e8630`–`0x1401e867d` |
| `Effect::evalConditions` | `0x1401e63b0`–`0x1401e6976` | 맨몸=`==`, `ge/gt/le/lt`, 전부 AND, fail-open |
| `Effect::acquireRenderTargets` | `0x1401ea500`–`0x1401ebbb6` | `fit` 종횡비 `0x1401eb2cc`–`0x1401eb381` · unique 키 `0x1401eb38c` · 공유 키 `0x1401eb4fa` · 생성/리사이즈 `0x1401eb96a`–`0x1401eba28` · clear `0x1401eba2c`–`0x1401ebadf` |
| ↳ (호출자, vtable `0x140490538` = 슬롯 22) | `0x1401ea310`–`0x1401ea4fa` | 대상 크기 질의 → 위 루틴. **종전 기재 `–0x1401ea4e0` 은 짧았다** — `.pdata` 조각 3개를 이은 실범위가 `0x1401ea4fa` 다(2026-08-21 재측) |
| `Effect::createRenderTarget` | `0x1401aadb0`–`0x1401ab40d` | 이름 해시 + 풀 조회 + `[[dev]+0x70]` 생성(`0x1401aae12`, 인자 8개를 그대로 전달). **종전 기재 `–0x1401ab3d8` 은 정상 반환 경로의 끝이고 `.pdata` 실끝은 `0x1401ab40d`**(오류 스로우 꼬리 포함) |
| `RT::RT`(렌더타깃 생성자) | `0x1400d2c60`–`0x1400d3219` | `scale` 나눗셈 + 하한 2(§1.3.1) |
| `RT::resize` | `0x140161f40`–`0x140162037` | 기존 텍스처 재치수화(§1.3.1·§3.3) |
| `Engine::createFrameBuffers`(가칭) | `0x14017f1b0`–`0x14017fa6f` | `_rt_<N>FrameBuffer`·`_rt_FullFrameBuffer`·`_rt_4FrameBuffer`·`_rt_8FrameBuffer`·`_rt_Bloom` 다섯 장을 만든다. **어드레싱 인자가 전건 상수 `2`** — `0x14017f494`·`0x14017f57d`·`0x14017f5cd`·`0x14017f60a`·`0x14017f64e`(§2.4a 근거 1) |
| jsoncpp `asString` | `0x140085cc0`–`0x140085e58` | `functions` 의 fbo 이름 문자열화(`0x1401e85a5`) |
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
`"width"`=`0x140473be8` · `"height"`=`0x140473bf8` · `"name"`=`0x1404748b8` · `"visible"`=`0x1404903a0` ·
`"_rt_"`=`0x14048dfe8` · `"FrameBuffer"`=`0x14048dff0` · `"_rt_FullFrameBuffer"`=`0x14048b588` ·
`"_rt_4FrameBuffer"`=`0x14048e058` · `"_rt_8FrameBuffer"`=`0x14048e040` · `"_rt_Bloom"`=`0x14048e030`.

**vtable 앵커.** 이펙트 클래스 vtable 베이스 = **`0x140490488`**(생성자 `0x1401e698e` ·
`0x1401e6b52` 가 `lea rax, [rip+…]` 로 싣는다 — rip-상대 스캔 실측, 이 두 곳이 전부다).
슬롯 22(`+0xB0`) = `0x140490538` → `0x1401ea310`, 슬롯 23(`+0xB8`) = `0x140490540` →
`0x1401ea500`.

이미지 전체 바이트 스캔으로 **`0x1401ea500` 이 박힌 자리는 4곳**이다 — `0x140490540` ·
`0x140491260` · `0x140491a08` · `0x140491dc8`. 그중 셋(`0x140490540` · `0x140491a08` ·
`0x140491dc8`)은 바로 앞 칸(`−8`)에 `0x1401ea310` 을 갖는 파생 vtable 이고,
`0x140491260` 만 슬롯 22 를 다른 함수로 덮었다. **어느 vtable을 통해 오든 오프셋은 `+0xB8` 로
같다** — 그래서 §3.3 의 호출부 탐색을 `+0xB8` 로 걸었고, 그 24곳이 전부 다른 클래스였다.
