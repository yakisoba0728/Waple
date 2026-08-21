# 씬 카메라 모션 복원 — shake · parallax · fade · 투영

wallpaper64.exe(imagebase `0x140000000`)에서 **씬 카메라가 매 프레임 어떻게 움직이는지**를
바이트 단위로 복원한 기록이다. 파스·기본값 쪽은 `docs/re/scene-postprocessing.md` §2·§5 가
이미 확정해 두었으므로 여기서는 **소비(consumption)** 만 다룬다 — 파스 표를 다시 싣지 않고
필요한 곳에서 참조한다. 겹치는 결론은 이번에 독립 재측정해 확인/정정했다.

- 바이너리: `/root/.claude/uploads/.../440072bd-wallpaper64.exe`
- 코퍼스: 동봉 `Sources/WapleRender/Resources/WEAssets/**`(씬 172) + 설치본
  `wallpaper_engine/**`(씬 190, `assets/` + `projects/defaultprojects/`)
- 셰이더 평문: `wallpaper_engine/assets/shaders/`, `assets/materials/`
- 타입 정의 평문: `wallpaper_engine/ui/dist/monaco/autocomplete/lib.sceneScript.d.ts`

---

## 0. 요약 — 이 문서가 확정한 것

| # | 결론 | 등급 |
|---|---|---|
| 1 | camera shake 는 **노이즈가 아니라 2주파 사인/코사인 3성분**이다. 펄린·심플렉스·퍼뮤테이션 테이블을 쓰지 않는다 | 확정 |
| 2 | shake 위상은 `speed² × g_Time` — **속도의 제곱**이다 | 확정 |
| 3 | shake 는 eye 와 target 에 **같은 델타**를 더한다 = 순수 평행이동, **회전 없음** | 확정 |
| 4 | `camerashakeroughness` 는 주파수가 아니라 **벡터 크기 리매핑 지수**(`|v|^(r³)`)다. r=1 이면 무연산 | 확정 |
| 5 | 2D(정사영) 씬은 shake 진폭이 `orthoHeight` 로 스케일되고 z 성분이 0 이다 | 확정 |
| 6 | parallax 에 **시간(자동) 성분은 없다**. 마우스 전용이며 `mouseinfluence` 는 초점을 캔버스 중앙↔마우스 사이에서 선형 보간한다 | 확정 |
| 7 | `cameraparallaxdelay` 는 지연 시간이 아니라 **수렴률 노브**: `α = min(1, 10·(1 − delay/3)·dt)`. `delay ≥ 3` 이면 완전 정지 | 확정 |
| 8 | 레이어 시차 오프셋은 `(origin − focus) × amount × parallaxDepth`, **z 는 항상 0**, 그리고 **정사영 씬에서만** 적용된다 | 확정 |
| 9 | parallax 는 레이어 이동과 별개로 **`g_ParallaxPosition` 유니폼**(renderState `+0x9c`)도 만든다 | 확정 |
| 10 | `camerafade` 는 씬 시작 페이드인이 **아니다**. `camera.paths` 가 있을 때만 살아 있고, 각 경로 구간의 **처음 0.5초·마지막 0.5초**를 `materials/util/fade.json`(스킴 컬러 ×0.7)로 덮는다 | 확정 |
| 11 | `camerapreview` 는 바이너리에 문자열 자체가 없다 — 런타임 미소비(에디터 전용) | 확정(재확인) |
| 12 | 2D 씬은 뷰 행렬을 만든 뒤 **eye 를 (W/2, H/2, 2000)으로 재중심화**한다 | 확정 |
| 13 | `orthogonalprojection.auto` 는 로드 1회가 아니라 **매 프레임** 재계산된다 | 확정 |
| 14 | **`camerashake:true` 동봉 코퍼스 도달 0건**, 설치본 전체에서도 1건(`ricepod`, 3D) | 확정 |
| 15 | Waple 의 `parallaxDelay` 의미론(= 지수 시상수 초)은 **틀렸다**. 기본 0.1 근처에서만 우연히 맞는다 | 확정 |
| 16 | Waple 주석의 "camerashake 코퍼스 활성 13/168씬" 은 **반증됐다**(실측 0/168) | 확정 |
| 17 | 레이어 `perspective` = 오브젝트 flags `+0x120` **bit7**. 소비는 `0x1401ed265` 게이트 → `0x140184f00` | 확정 |
| 18 | 레이어 `perspective` 는 **정사영(2D) 씬 전용**이다(`renderState+0x118` bit10 = "이 씬은 2D") | 확정 |
| 19 | 레이어 원근 카메라는 `d = H/(2·tan(fov/2))` 거리에 놓이고 **화면 배율은 `s(z) = d/(d − z)`**. `fov` 는 `general.perspectiveoverridefov` | 확정 |
| 20 | `perspective:true` 실제 씬 도달은 **동봉·설치본 통틀어 1건**(`preview3dclock`)이고 그 `origin.z = 0` 이라 정사영과 픽셀 동일 | 확정 |
| 21 | shake·parallax **어디에도 난수원이 없다**. `g_Time`·포인터·`dt` 의 결정적 함수라 캡처 결정성(`captureRandomSeed`)에 영향이 없다 | 확정 |
| 22 | 시차 스무딩은 **1차 저역통과의 지수형이 아니다** — α 가 `dt` 에 선형이라 **프레임률 독립이 아니다**(60Hz vs 120Hz 실측 차 2.8e-5 @delay 0.3, 1초) | 확정 |
| 23 | `camera.paths` 재생 보간은 **3차 에르미트**다. 이웃 제어점을 구간 끝점으로 클램프해 접선이 양 끝 모두 `0.5·(p1 − p0)` — 닫힌 식은 `p0 + Δ·(−u³ + 1.5u² + 0.5u)` 이고 **스무스스텝이 아니다** | 확정 |
| 24 | 보간은 eye·center·**up**·zoom 네 축 전부에 걸린다. 한 구간에서 읽는 제어점은 **정확히 둘**(`imul` 이 `idx`·`idx+1` 뿐) | 확정 |
| 25 | 전진 임계(구간 끝)가 팔마다 다르다 — 보간 `ts[i+1]` · 마지막 붙듦 **`duration − ts[i]`** · 시작 전 **`ts[i] + ts[i+1]`** | 확정 |
| 26 | 그래서 `duration > ts[last]` 인 경로는 저작 duration 보다 `ts[last]` 만큼 **짧게** 끝난다(설치본 4경로, 전부 `demon_core`: 300→260 · 450→416 · 400→360 · 350→314초) | 확정 |
| 27 | `duration == ts[last]` 면 마지막 transform 으로 **넘어가지 않고** 곧장 다음 경로다(설치본 21경로 중 16건) | 확정 |
| 28 | 경로 전환은 transform 인덱스와 경과 시간을 **한 qword 스토어로 함께** 0 으로 민다(`0x140189ad9`). transform 만 넘길 때는 경과 시간을 유지한다(dword 스토어) | 확정 |
| 29 | **자동회전(autorotate)이 존재하지 않는다.** 저작 JSON·`lib.sceneScript.d.ts`·바이너리 문자열 어디에도 없다. 시간이 미는 유일한 카메라 축은 `camera.paths` 다 | 확정 |
| 30 | 오브젝트 `parallaxDepth` 기본값은 **(1.0, 1.0)** 이다 — 레이어 생성자 `0x1401ddce1`/`0x1401ddcec` 가 `+0x170`/`+0x174` 에 `0x3f800000` 을 쓴다 (§7 **W-7 해소**) | 확정 |
| 31 | 같은 생성자가 오브젝트 flags(`+0x120`)를 **`0x2001`** 로 깐다 → `visible` 기본 **true**, `perspective` 기본 **false** | 확정 |
| 32 | 설치본 경로 코퍼스는 6씬·21경로·41transform 이고 **전 경로가 transform 1~2개**, `timestamp[0] == 0` 전건이다. transform `zoom` 저작은 9/41 인데 경로 씬 6개가 **전부 3D** 라 zoom 은 코퍼스에서 소비되지 않는다 | 확정 |
| 33 | 시차 오프셋에 **최대치 클램프가 없다**. clamp01 은 포인터 입력과 `g_ParallaxPosition` 출력에만 있고, 레이어 오프셋은 `|origin − focus|` 에 비례해 무한히 커진다 | 확정 |
| 34 | `scene+0x13c` 를 가리키는 프로퍼티 디스크립터가 **0건**이다(전 함수 스캔에서 `mov [desc+0x34], 0x13c` 0건) → JSON 도달 불가 확정 (§1.2 [미해결] **부분 해소**) | 확정 |
| 35 | 씬 생성자가 flags 를 **`0x26`** 으로 깐다 → **`camerafade` 기본 true**, `orthogonalprojection`·auto·`camerashake`·`cameraparallax` 기본 false. 같은 두 qword 스토어가 경로 재생 상태 `scene+0xe4/0xe8/0xec` 를 전부 0 으로 만든다 (§8.8) | 확정 |

---

## 1. 프레임 파이프라인에서 카메라가 놓이는 자리

```
Renderer::frame(renderer, dt)                 0x14017fa70 – 0x1401816cc
  ├ 시간 누적    [renderer+0x148](f64) += dt ; [renderer+0x140] = (f32)  0x14017fcca–0x14017fce5
  │              432000.0 초과 시 0 으로 되감음(상수 0x14049296c)        0x14017fcde–0x14017fcf6
  ├ Scene::updateCamera(scene, dt)             0x14017fd26 → 0x1401891a0
  ├ Composite::buildProjection(renderer)       0x14017fd2e → 0x140183a70
  ├ zoom 적용(정사영 씬 한정)                   0x14017fd45 – 0x14017fd5d
  └ … 레이어 그리기 … camerafade 오버레이       0x140180c1a – 0x140180cc0
```

### 1.1 renderState 는 renderer + 0x10 이다 (이번에 확정)

`scene[0xd8]`(= scene-postprocessing.md 가 "렌더 상태" 라 부르는 객체)의 정체를 고정했다.

```
0x140181b82  lea  r9, [r14 + 0x10]          ; r14 = renderer
0x140181b8c  call 0x140186c90               ; Scene::Scene(..., r9)
0x140181b9a  mov  qword ptr [r14], rax      ; renderer[0] = scene   (역참조 확인)
0x140186d13  mov  qword ptr [r14 + 0xd8], rsi   ; scene[0xd8] = rsi = r9
```

→ **`renderState = renderer + 0x10`**. 이 한 줄이 아래 두 필드를 서로 검증해 준다:

| renderer | renderState | 정체 | 근거 |
|---|---|---|---|
| `+0x140` | `+0x130` | **`g_Time`**(초) | 유니폼 ID 3 핸들러 `0x1400d8457` 가 `[renderState+0x130]` 을 그대로 복사 |
| `+0x130` | `+0x120` | **`g_Alpha`** | 유니폼 ID 0 핸들러 `0x1400d83d7`; camerafade 가 여기에 알파를 쓴다(§4) |

유니폼 점프테이블: 디스패처 `0x1400d8300`.
인덱스 바이트 표 `0x1400daaac` · 오프셋 표 `0x1400da984` — 데이터다, 명령이 아니다 [VA-데이터표]
(바이트가 `00 01 02 03 …`). `.pdata` 조각 `0x1400da981`–`0x1400dab3c` 안에 들어 있어 경계 검사에는
걸리지만 디스어셈 대상이 아니다.
같은 테이블에서 이번 문서에 필요한 renderState 필드를 전부 뽑았다:

| 유니폼 | ID | renderState 오프셋 | 크기 | 핸들러 VA | 등록 VA |
|---|---:|---|---|---|---|
| `g_Alpha` | 0 | `+0x120` | f32 | `0x1400d83d7` | — |
| `g_Time` | 3 | `+0x130` | f32 | `0x1400d8457` | — |
| `g_Frametime` | 4 | `+0x14c` | f32 | `0x1400d846f` | — |
| `g_Daytime` | 5 | `+0x140` | f32 | `0x1400d8487` | — |
| `g_PointerPositionLast` | 104 | `+0x94` | vec2 | `0x1400d9e12` | `0x1400d9df8`… |
| **`g_PointerPosition`** | **105** | **`+0x8c`** | vec2 | `0x1400d9df8` | `0x140003ecf`(id) · `0x140003ed7`(이름) |
| `g_PointerState` | 106 | — | — | — | `0x140003eef` · `0x140003ef7` |
| **`g_ParallaxPosition`** | **107** | **`+0x9c`** | vec2 | `0x1400d9e90` | `0x140003f0f`(id) · `0x140003f17`(이름) |
| `g_RenderVar0` | 108 | `+0xa8` | vec4 | `0x1400d9eaa` | `0x140003f2e` · `0x140003f35` |

> **함정 기록.** 유니폼 이름 문자열은 16바이트 정렬 블록(`0x14048d100`–`0x14048db80`)에 있고,
> 등록 초기화자(`0x140002860`)는 **ID 를 스택에 먼저 깔고 그 다음 이름을 `lea`** 한다.
> `lea` 바로 뒤의 `mov imm` 를 ID 로 읽으면 전부 한 칸씩 밀린다.

### 1.2 `Scene::updateCamera` — `0x1401891a0` – `0x140189e07`

인자 `(rcx = scene, xmm1 = dt)`. 9개 `.pdata` 조각이 한 함수다(`primary()` 로 병합).

```
① 자식 오브젝트 업데이트 루프                       0x1401891f0 – 0x140189203
② 활성 카메라 레이어 탐색(objects 역순, flags bit0)  0x140189220 – 0x14018924e
③ camera.paths 유무 판정 (scene[0x310] vs [0x318])   0x140189251 – 0x140189271
④ 실효 fov 선택 → scene[0x148]                      0x140189278 – 0x1401892c4   (§5.1)
⑤ eye/target/up/zoom 결정 — 세 경로 중 하나
     A. 카메라 레이어 있음      0x1401892d3 – 0x140189425
     B. 레이어도 경로도 없음    0x14018942a – 0x1401894a4
     C. camera.paths 재생       0x1401894a9 – 0x140189b07
   각 경로 끝에서 camerashake(flags bit7) 호출        0x140189420 / 0x14018949f / 0x140189a6f
⑥ fov 클램프 [0.1, 179.9] → scene[0x148]            0x140189b0f – 0x140189b4c   (§5.2)
⑦ cameraparallax(flags bit8) 초점 계산               0x140189b42 – 0x140189cf3   (§3)
⑧ 뷰 행렬 빌드 → renderState+0x38                    0x140189cf3 – 0x140189d8b
⑨ orthogonalprojection.auto 재계산                   0x140189d8f – 0x140189d9b   (§5.4)
⑩ 2D eye 재중심화 (W/2, H/2, 2000)                   0x140189da0 – 0x140189df0   (§5.5)
```

씬 런타임 카메라 슬롯(파스된 `camera.*` 원본과 별개):

| 오프셋 | 내용 | 비고 |
|---|---|---|
| `scene+0xf0/0xf4/0xf8` | 런타임 **eye** | shake 가 여기에 가산 |
| `scene+0xfc/0x100/0x104` | 런타임 **target(center)** | shake 가 같은 값 가산 |
| `scene+0x108/0x10c/0x110` | 런타임 **up** | shake 무관 → **롤 없음** |
| `scene+0x114` | 런타임 **zoom**(카메라 레이어/경로 유래) | `0x14017fd5d` 에서 `general.zoom` 과 곱해짐 |
| `scene+0xe4 / 0xe8 / 0xec` | 경로 인덱스 / 트랜스폼 인덱스 / 경로 경과시간 | §4 |
| `scene+0x340/0x344` | **시차 초점**(정사영 픽셀 좌표, 스무딩 상태) | §3 |

경로 B(레이어도 경로도 없음)가 `scene+0x118/0x124/0x130` (= 파스된 `camera.eye/center/up`) 을
`scene+0xf0/0xfc/0x108` 로 그대로 복사하는 것이 위 세 슬롯의 정의를 확정한다
(`0x14018942e`–`0x14018948a`). 같은 자리에서 `scene+0x13c → scene+0x114`(`0x140189484`–`0x14018948a`)도
복사되는데, `0x13c` 는 생성자 기본 1.0(`0x140186d51`)이고 **JSON 이 이 슬롯을 쓰는 경로를 못 찾았다 — [미해결]**
> **[2026-08-21 부분 해소]** "못 찾았다" 가 아니라 **없다**. 전 `.pdata` 함수를 훑어
> `mov dword ptr [desc+0x34], 0x13c`(프로퍼티 디스크립터의 오프셋 필드) 스토어를 세면 **0건**이다.
> 대조군으로 같은 스캔이 `0x170`(`parallaxDepth` @`0x1401e0848`) · `0x334`(`cameraparallaxamount`
> @`0x14019b189`) · `0x338`(`cameraparallaxdelay` @`0x14019b20d`)는 정확히 잡는다.
> → **`scene+0x13c` 는 어떤 JSON 키로도 쓰이지 않는다**(확정). 코퍼스 실측도 같은 말을 한다 —
> `camera` 블록이 저작한 키는 동봉·설치본 통틀어 `eye`/`center`/`up`/`paths` 넷뿐이다.
> 정체는 **`CameraTransforms.zoom`(스크립트 전용 정적 카메라 zoom)** 이 **유력**하다:
> `scene+0x118`(eye) · `+0x124`(center) · `+0x130`(up) · `+0x13c` 배치가
> `lib.sceneScript.d.ts:1001-1006` 의 `class CameraTransforms { eye; center; up; zoom }` 와 정확히
> 같고, `IScene.getCameraTransforms()`/`setCameraTransforms()`(`:2193-2200`)가 그 클래스를 주고받는다.
> 다만 그 API 구현은 `bin/scenescript64.dll` 에 있고(`wallpaper64.exe` 에는 `getCameraTransforms`
> 문자열이 **0건**, DLL 에는 있다) 콜백이 vtable 간접이라 바이트로는 못 박았다 — **등급: 유력**.

(`general.zoom` 은 별개 슬롯 `0x154`, 생성자 기본 1.0 @`0x140186d93`). `scene+0x114` 자체의 생성자
기본값도 1.0 이다(`0x140186d46`).

---

## 2. camera shake — `0x140199580` – `0x14019977c`

호출: `shake(rcx = scene, rdx = &scene[0xf0] /*eye*/, r8 = &scene[0xfc] /*target*/)`.
게이트는 세 곳 모두 `test r?b, r?b` + `jns` 로 **flags 바이트의 bit7 = `camerashake`** 를 본다
(`0x14018940a` · `0x140189490` · `0x140189a5d`).

### 2.1 수식 전문

```
T = renderState.g_Time                                 ; [scene+0xd8] + 0x130   0x1401995de·0x140199600
s = scene[0x328]  camerashakespeed                     ; 0x1401995d2
a = scene[0x32c]  camerashakeamplitude                 ; 0x1401995e5
r = scene[0x330]  camerashakeroughness                 ; 0x14019959e

k   = powf(r, 3.0)                                     ; 0x1401995cd   상수 3.0 @0x140492830
phi = s * s * T                                        ; 0x1401995f7 (s·s) → 0x140199600 (×T)

v.x = cosf(phi)                                        ; 0x14019960b   cosf = 0x14041a2e0
v.y = sinf(phi * 1.3329999446868896)                   ; 0x14019961e   상수 @0x140492728, sinf = 0x14041a9c0
v.z = sinf(phi)                                        ; 0x14019962a

if (scene.flags[0xe0] & 8)          /* 정사영 = 2D */   ; 0x14019962f
        v.z   = 0                                      ; 0x140199644
        scale = scene[0x358] * 0.1 * (a * 0.1)         ; 0x14019963b–0x14019964c  = a·H/100
else    /* 원근 = 3D */
        scale = a * 0.1                                ; 0x1401995fb / 0x140199653

/* 거칠기 리매핑 — k 가 1 도 0 도 아닐 때만 */
if (k > 0.001 && k != 1.0) {                           ; 0x140199657 (@0x140492608) · 0x14019966e (@0x140492704)
        L = sqrtf(v.x² + v.y² + v.z²)                  ; 0x140199676–0x1401996b0  sqrtf = 0x14041ad10
        m = powf(L, k)                                 ; 0x1401996bc
        v = (v / L) * m                                ; 0x1401996c1–0x1401996ed
}

delta = v * scale                                      ; 0x1401996fa · 0x140199719 · 0x14019971e
eye    += delta                                        ; 0x140199712–0x140199742   (rdx)
target += delta                                        ; 0x140199747–0x14019976a   (r8)
```

성분 배치가 미묘하다 — **x 는 코사인, y 는 1.333배 주파수 사인, z 는 사인**이다:
`[rdi+0]←v.x`, `[rdi+4]←v.y`, `[rdi+8]←v.z`(`0x140199731` / `0x14019973d` / `0x140199742`).

### 2.2 CRT 함수 동정

| VA | 정체 | 근거 |
|---|---|---|
| `0x14041a2e0` | `cosf`(코어) | 소각 근사가 `1 − 0.5x²` — 상수 `0x140471bb0`=1.0, `0x140471bc0`=0.5 (`0x14041a340`–`0x14041a348`) |
| `0x14041a9c0` | `sinf`(코어) | 소각 근사가 `x − x³/6` — 상수 `0x140471d40`=0.16666666666666666 (`0x14041aa20`–`0x14041aa28`) |
| `0x14041e350` | `powf(base=xmm0, exp=xmm1)` | 같은 함수가 `0x140182d85`–`0x140182dc6` 에서 색상 3성분에 `pow(c, 2.0)`(감마)로 쓰인다 |
| `0x14041ad10` | `sqrtf` | 도메인 에러 경로가 문자열 `"sqrtf"`(`0x140471e00`)를 `_matherr` 에 넘긴다 |

### 2.3 성질

- **회전 없다.** eye 와 target 에 *같은* 벡터를 더하므로 시선 방향이 보존된다. `up` 은 건드리지 않아
  롤도 없다. 카메라는 순수하게 평행이동한다.
- **위상은 속도의 제곱.** `speed=3`(에디터 기본) → `phi = 9·t`. `speed` 를 2배로 하면 주파수는 4배다.
- **roughness 기본값 1 은 완전 무연산.** `k = 1³ = 1` → `ucomiss ... je` 로 리매핑 블록을 건너뛴다.
  즉 저작 코퍼스 전건(§6)에서 이 키는 아무 효과가 없다.
- **roughness 는 주파수가 아니라 크기 곡선.** `|v'| = |v|^(r³)`. `r<1` 이면 지수가 작아져
  `|v|` 가 1 쪽으로 밀리고(진폭이 고르게 커짐), `r>1` 이면 대비가 과장된다.
  `r³ ≤ 0.001` 이면 리매핑을 통째로 건너뛴다 — `r ≤ 0.1` 이 그 경계다.
- **2D 진폭 단위는 픽셀.** 2D 스케일이 `a·H/100` 이라 `orthogonalprojection.height` 에 비례한다.
  기본 `a=0.5`, `H=256` → 피크 1.28 정사영 단위. 3D 스케일은 `a·0.1` 월드 단위다.
- **감쇠(decay)가 없다.** 진폭은 시간에 무관한 상수 `scale` 이다 — 지수 감쇠 포락선도, 임펄스
  트리거도, 스프링도 없다. `camerashake` 가 켜져 있는 한 **영구히 같은 크기로** 떤다.
  (`0x1401995e5` 에서 읽은 `amplitude` 가 `0x1401996fa`–`0x14019971e` 까지 시간 항 없이 그대로 곱해진다.)
- **난수원이 없다.** `sinf`/`cosf`/`powf`/`sqrtf` 호출뿐이고 `g_Time` 말고 다른 입력이 없다.
  결정적 시드도 필요 없다 — 같은 `g_Time` 이면 항상 같은 값이다. 즉 이 수식을 Waple 에 이식해도
  `SnapshotPipeline.captureRandomSeed` 의 캡처 결정성이 새로 깨지지 않는다.
- **shake 는 시차 초점에도 새어 들어간다.** §3 의 초점 계산이 `scene[0xf0]`(= shake 가 이미 더해진 eye)
  을 읽으므로, 2D 에서 shake 와 parallax 를 동시에 켜면 `g_ParallaxPosition` 도 함께 떤다
  (`0x140189c18` / `0x140189c24`).

### 2.4 배제한 가설 — 심플렉스 노이즈

리포에 `Sources/WapleCore/SimplexNoise.swift` 가 있고 퍼뮤테이션 테이블을 `0x140484f40`(256B)·
`0x1404833a0`(512B) 에서 덤프해 왔기에, shake 가 같은 테이블을 쓰는지 먼저 확인했다. **안 쓴다.**

- `0x140484f40` 의 코드 참조는 4곳뿐이다: `0x140198a98`(fn `0x140198910`), `0x14027b09c`,
  `0x14027b2d6`, `0x14027b4db`. shake 함수(`0x140199580`)는 없다.
- `0x140198910` 은 2D 심플렉스가 맞다 — F2 = 0.3660253882408142(`0x1404926a4`),
  G2 = 0.21132487058639526(`0x140492680`), 격자 스큐/언스큐(`0x1401989b3`–`0x140198a1f`).
  입력에 `g_Time`(`[rax+0x130]`, `0x140198994`)을 쓰고, 진입 게이트가 `[rcx+0x90] & 0x10000` 이다.
  `rcx` 는 라이트 객체로 보인다 — 바로 앞 함수 `0x140196ce0` 이 `light+0x320` 을 다루는
  라이트 업데이터다(`volumetric-light.md` §의 `0x14019871d`). **등급: 유력**(호출자가 전부 vtable
  간접이라 소유자를 바이트로 못 박지 못했다). 어느 쪽이든 **카메라 shake 와 무관**한 것은 확정이다.
- 즉 **Waple 의 `SimplexNoise` 를 카메라 shake 에 재사용하면 WE 와 달라진다.**

---

### 2.5 [2026-08-21 정정] `sqrtf` 호출 팔은 도달 불가다

§2.1 은 거칠기 리매핑의 길이를 "`L = sqrtf(...)`" 로 적었다. 실제로 도는 것은 **인라인 `sqrtss`**
이고 CRT `sqrtf`(`0x14041ad10`) 호출은 도달 불가 분기다:

```
0x140199691  xorps   xmm0, xmm0
0x140199698  ucomiss xmm0, xmm2        ; 0  vs  L²
0x14019969b  ja      0x1401996a8       ; 0 > L² 일 때만 CRT 호출
0x14019969d  xorps   xmm11, xmm11
0x1401996a1  sqrtss  xmm11, xmm2       ; ← 실제 경로
0x1401996a8  movaps  xmm0, xmm2
0x1401996ab  call    0x14041ad10       ; sqrtf — 도메인 에러 보고용
```

`L² = x² + y² + z²` 는 음수가 될 수 없으므로(성분이 `sinf`/`cosf` 결과라 NaN 도 아니다)
`ja` 가 서는 경우가 없다. 결론은 안 바뀐다 — 값은 같다. 다만 "CRT `sqrtf` 를 부른다" 는 서술은
틀렸다. `cosf`/`sinf`/`powf` 동정(§2.2)은 그대로 유효하다.


## 3. camera parallax

parallax 는 **두 개의 독립 출력**을 만든다. 하나는 셰이더 유니폼, 하나는 레이어 트랜스폼이다.
둘의 게이트 조건이 다르다는 점이 핵심이다.

### 3.1 초점(focus) 계산 — `0x140189b42` – `0x140189cf3`

게이트: `test dword ptr [rbx+0xe0], 0x100`(flags **bit8 = `cameraparallax`**) @ `0x140189b42`.
꺼져 있으면 블록 전체를 건너뛴다 → `scene+0x340/0x344` 도 `g_ParallaxPosition` 도 갱신되지 않는다.

```
rs = scene[0xd8]                                        ; renderState
f  = rs[0x118]                                          ; renderState 플래그

infl = (f & 0x200200) ? 0.0 : scene[0x33c]              ; 0x140189b67–0x140189b7a
                                                        ;   cameraparallaxmouseinfluence
mx = clamp01(rs[0x8c])                                  ; 0x140189b8d/0x140189b9d  g_PointerPosition.x
my = clamp01(1.0 − rs[0x90])                            ; 0x140189b95/0x140189ba8  (Y 반전)
if (f & 0x800) mx = 1.0 − mx                            ; 0x140189bac–0x140189bb6  (포인터 X 미러)

W = scene[0x354] ; H = scene[0x358]                     ; 정사영 폭/높이
focus.x = W*0.5*(1−infl) + W*mx*infl + scene[0xf0]      ; 0x140189bda–0x140189c18
focus.y = H*0.5*(1−infl) + H*my*infl + scene[0xf4]      ; 0x140189bde–0x140189c24

/* 지연 스무딩 */
d = scene[0x338]                                        ; cameraparallaxdelay   0x140189c0d
if (d > 0) {                                            ; 0x140189c15 / 0x140189c2c
    α = (1.0 − d/3.0) * 10.0 * dt                       ; 0x140189c2e–0x140189c43  (3.0, 10.0 @0x140492868)
    if (α > 1.0) α = 1.0                                ; 0x140189c47–0x140189c4d
    focus = prev + (focus − prev) * α                   ; 0x140189c51–0x140189c75
}                                                        /* d ≤ 0 이면 즉시 스냅 */
scene[0x340] = focus.x ; scene[0x344] = focus.y          ; 0x140189c79 / 0x140189c84

/* 유니폼 출력 */
rs[0x9c] = clamp01(focus.x / W)                          ; 0x140189ca1–0x140189cbe   g_ParallaxPosition.x
rs[0xa0] = clamp01(focus.y / H)                          ; 0x140189c90–0x140189cc6   g_ParallaxPosition.y
if (rs[0x118] & 0x800) rs[0x9c] = 1.0 − rs[0x9c]         ; 0x140189cd5–0x140189cea
```

**읽어야 할 것들**

1. **자동(시간) 성분이 없다.** 초점의 두 항은 "캔버스 중앙" 과 "마우스 위치" 뿐이다.
   `mouseinfluence` 는 둘 사이의 선형 보간 계수이지 게인이 아니다.
   `infl = 0` → 초점은 캔버스 중앙에 고정되고 **시차는 시간에 따라 전혀 움직이지 않는다.**
2. **`delay` 는 지연이 아니라 수렴률**이다. `rate = 10·(1 − delay/3)` [1/s], `α = min(1, rate·dt)`.
   실효 시상수 `τ = 1/rate = 0.3/(3 − delay)` 초.

   | delay | rate [1/s] | τ [s] | 비고 |
   |---:|---:|---:|---|
   | 0 (이하) | — | 0 | 즉시 스냅(스무딩 분기 자체를 건너뜀) |
   | 0.1 (에디터 기본) | 9.667 | **0.1034** | |
   | 1.0 | 6.667 | 0.150 | `ricepod` 저작값 |
   | 2.0 | 3.333 | 0.300 | |
   | 3.0 | 0.0 | ∞ | **완전 정지** — 초점이 영원히 초기값 |
   | > 3.0 | 음수 | — | α<0 → 목표에서 **멀어진다**(발산). 엔진이 방어하지 않는다 |

   즉 `delay` 는 0..3 구간 노브이며, 0.1 → 0.1034 s 라 "delay 초" 해석이 기본값 근처에서만
   3.4% 오차로 우연히 맞는다. 그 밖에서는 전부 틀린다(§7 W-3).
3. `α` 가 `dt` 에 **선형**이다(지수 `1−exp(−dt/τ)` 가 아니다). 프레임률이 낮으면 `α` 가 1 로 클램프되어
   스냅한다.
4. 초점은 **정사영 픽셀 좌표**([0,W]×[0,H])다. 2D 씬의 `camera.eye` 는 코퍼스 전건 `(0,0,0)` 이므로
   무저작 초점은 정확히 캔버스 중앙 `(W/2, H/2)` 이고 `g_ParallaxPosition = (0.5, 0.5)` 다.
   `depthparallax.vert:44` 의 `g_ParallaxPosition * 2 - 1` 이 이 정규화를 그대로 확증한다.
5. `rs[0x118]` 의 bit9 / bit21 중 하나라도 서면 마우스 영향이 **0 으로 강제**된다(초점=중앙 고정).
   두 비트의 이름은 **[미해결]** — 다른 참조가 `0x140176431`(bit21) 한 곳뿐이라 의미를 못 박지 못했다.
   bit11 은 포인터 X 미러다(유력 — `0x14018e08c` 이 같은 비트로 `rs[0x8c]` 를 뒤집는다).

### 3.2 레이어 오프셋 — `0x140189e10` 안 `0x14018a0a9` – `0x14018a11b`

게이트가 **둘**이다(`0x140189f17` – `0x140189f2c`):

```
ecx = scene[0xe0]
r13b = ((ecx >> 8) & 1)   /* cameraparallax */
    && ((ecx >> 3) & 1)   /* orthogonalprojection 활성 = 2D */
```

**즉 3D(원근) 씬에서는 레이어 시차 오프셋이 전혀 적용되지 않는다.** 3D 에서 `cameraparallax` 를
켜면 `g_ParallaxPosition` 유니폼만 갱신된다.

```
/* rdx = 레이어 오브젝트(vtable+0x60 이 1 또는 4 인 것만), rbx = scene */
dx = rdx[0x128] − scene[0x340]      /* origin.x − focus.x */   ; 0x14018a0b3 / 0x14018a0c3
dy = rdx[0x12c] − scene[0x344]      /* origin.y − focus.y */   ; 0x14018a0bb / 0x14018a0d3
A  = scene[0x334]                   /* cameraparallaxamount */ ; 0x14018a0cb

off.x = A * dx * rdx[0x170]         /* × parallaxDepth.x */    ; 0x14018a0de / 0x14018a0ff
off.y = A * dy * rdx[0x174]         /* × parallaxDepth.y */    ; 0x14018a0e5 / 0x14018a10d
off.z = A * 0.0 = 0                                            ; 0x14018a0ef  (xmm6 는 0x140189f3b 에서 0)
```

`off` 벡터(`[rsp+0x40..0x48]`)는 레이어 드로우 호출의 인자로 넘어간다
(`0x14018a235` → `0x14019dbb0`, `0x14018a2a3` → 오브젝트 vtable `+0x88`).
게이트가 꺼지면 `[rsp+0x40..0x48]` 는 `0x14018a086`/`0x14018a093` 에서 깐 0 그대로다.

**오브젝트 오프셋 근거** — 오브젝트 프로퍼티 디스크립터 테이블 `0x1401e0530` – `0x1401e1389`
(씬 `general` 과 같은 등록 헬퍼 `0x14000f880`, `+0x30`=타입 · `+0x34`=오프셋):

| 이름 | 오프셋 | 타입 | 이름 세팅 VA | 문자열 VA |
|---|---|---:|---|---|
| `origin` | `0x128` | 2 (vec3) | `0x1401e05d2` | `0x14048f4dc` |
| `scale` | `0x134` | 2 | `0x1401e06a3` | — |
| `angles` | `0x140` | 2 | `0x1401e0759` | `0x14048fc5c` |
| **`parallaxDepth`** | **`0x170`** | **1 (vec2)** | `0x1401e082f` | `0x1404902c8` |
| `sortorder` | `0x124` | int | `0x1401e08f9` | `0x1404902d8` |
| `name` | `0x1d8` | 5 (string) | `0x1401e11d0` | — |

`lib.sceneScript.d.ts:2037-2039` 이 `ILayer.parallaxDepth: Vec2` 를
"Controls parallax strength along x and y axes individually" 로 기술해 타입/의미가 맞물린다.

**기하학적 의미.** `newOrigin = focus + (origin − focus)·(1 + A·depth)` — 즉 초점을 중심으로 한
**스케일 아웃**이다. `infl=0` 이면 초점이 캔버스 중앙에 고정되므로 시차가 아니라 **정적 확대**가 된다
(A=0.5, depth=1 → 중앙 기준 1.5배). 마우스 영향이 있어야 비로소 "따라오는" 시차가 된다.

`off.z` 가 항상 0 이므로 **레이어 깊이(z) 방향 이동은 없다** — 시차는 전적으로 화면 평면 안에서 일어난다.

### 3.3 `g_ParallaxPosition` 소비처(동봉 평문)

| 셰이더 | 사용 |
|---|---|
| `assets/effects/depthparallax/shaders/effects/depthparallax.vert:44-46` | `prlxInput = g_ParallaxPosition*2−1` → 투영축으로 회전 → `v_ParallaxOffset` |
| `assets/effects/depthparallax/preview/shaders/effects/depthparallax.frag:67,71,75` | 시차 매핑 뷰 방향 |

동봉 셰이더 전량에서 이 두 파일이 전부다.

---

## 4. camerafade — 씬 시작 페이드가 **아니다**

`camerafade` 는 flags bit2 다. 소비처는 딱 두 곳이고 둘 다 **`camera.paths` 존재**를 추가 조건으로 건다.

### 4.1 머티리얼 로드 — `0x140181bae` – `0x140181bda`

```
rcx = renderer[0]                                  ; scene
if (scene[0xe0] & 4) == 0            → 스킵         ; 0x140181bae
if (scene[0x310] == scene[0x318])    → 스킵         ; 0x140181bb7–0x140181bc5  (paths 비어 있음)
renderer[0x3180] = LoadMaterial("materials/util/fade.json")  ; 0x140181bce–0x140181bda
                                                    ; 문자열 @0x14048e308
```

즉 **경로가 없는 씬은 fade 머티리얼을 아예 만들지 않는다.** `camerafade:true` 만으로는 아무 일도 없다.

### 4.2 알파 곡선 — `0x140180c1a` – `0x140180cc0`

```
t = scene[0xec]                                    ; 현재 경로 구간의 경과 시간
T = paths[scene[0xe4]].duration                    ; path 스트라이드 0x20, +0x18 = duration
                                                   ; 0x140180c48 (shl rdx,5) / 0x140180c4c
rem = T − t                                        ; 0x140180c56
alpha = 0                                          ; 0x140180c0e (xorps xmm3)
if (rem < 0.5)        alpha = 1 − 2*rem            ; 0x140180c5e→0x140180c81–0x140180c8c  (페이드 아웃)
else if (t < 0.5)     alpha = 1 − 2*t              ; 0x140180c6c→0x140180c77–0x140180c8c  (페이드 인)
if (alpha > 0) {                                   ; 0x140180c90 (xmm13 = 0.0 @0x140180166)
    renderState[0x120] = alpha        /* g_Alpha */; 0x140180ca2
    bind(renderer[0x3180]); drawFullscreen();      ; 0x140180caa / 0x140180cb6 / 0x140180cc0
}
```

상수 0.5 는 `0x1404926c0`, 1.0 은 `0x14018032a`(xmm14). **양쪽 0.5 초, 선형.**

### 4.3 무엇으로 페이드되는가 — 검정이 아니다

```json
// assets/materials/util/fade.json
{"passes":[{"shader":"fade","cullmode":"nocull","depthtest":"disabled",
            "depthwrite":"disabled","blending":"translucent",
            "usershadervalues":{"schemecolor":"tint"}}]}
```
```glsl
// assets/shaders/fade.frag
uniform lowp vec3 color; // {"material":"tint","default":"0.315, 0.135, 0.1125"}
gl_FragColor = vec4(color * 0.7, g_Alpha);
```

`tint` 가 프로젝트 **스킴 컬러**에 바인딩된다. 페이드 색 = `schemecolor × 0.7`,
머티리얼 기본값은 `(0.315, 0.135, 0.1125)` — 어두운 주황이다. **검정 페이드가 아니다.**

### 4.4 씬 시작 페이드인은?

`0x1401891a0`/`0x14017fa70`/`0x140181af0` 어디에도 "씬 로드 후 N 초" 형태의 전역 페이드가 없다.
`camerafade` 는 경로 구간 경계 전용이다. **씬 시작 페이드인은 없다**(경로가 있는 씬은 경로
구간 0 의 페이드인이 결과적으로 시작 페이드처럼 보인다 — `t=0` 에서 alpha=1).
플레이리스트 전환의 페이드는 별개 축이다(`docs/re/playlist-transition.md`).

### 4.5 경로 데이터 레이아웃(부수 확정)

`camera.paths` → `scripts/camera_XX.json` → `{"paths":[{"duration":…,"transforms":[{"timestamp","eye","center","up","zoom"}]}]}`

| 구조 | 스트라이드 | 필드 |
|---|---:|---|
| path | `0x20` | `+0x00/+0x08` transforms begin/end, `+0x18` **duration** |
| transform | `0x2c` | `+0x00` timestamp, `+0x04` eye(3), `+0x10` center(3), `+0x1c` up(3), `+0x28` **zoom** |

근거: `imul rdx, rax, 0x2c`(`0x1401894bd`), `shl rsi, 5`(`0x1401894c5`),
`[rdx+rcx+0x28]` → `scene[0x114]`(`0x140189a3f`/`0x140189a4e`), `[rdx+r8+0x18]`(`0x140180c4c`).
경로 끝에서 다음 경로로 넘어가고 마지막이면 0 으로 되감는다(`0x140189acd`–`0x140189b00`).

> **경로 재생 자체(보간 곡선·전진 임계·되감기)는 §8 에서 바이트 단위로 복원했다.**

---

## 5. 투영

여기는 `scene-postprocessing.md` §5 가 이미 확정한 영역이다. **재측정으로 전건 확인**했고,
그 문서가 다루지 않은 세 가지(카메라 레이어 fov 오버라이드 · auto 재계산 주기 · 2D eye 재중심화)를 더한다.

### 5.1 실효 fov 선택 — `0x140189278` – `0x1401892c4` (재확인)

```
eax = 0x144 (perspectiveoverridefov) ; edx = 0x140 (fov)
test r9b, 8            ; flags bit3 = 정사영
cmove eax, edx         ; bit3==0(3D) 이면 fov, bit3==1(2D) 이면 override
scene[0x148] = scene[eax]
```
**2D 는 `perspectiveoverridefov`(기본 95°), 3D 는 `fov`(기본 50°).** 확인.

**추가 — 카메라 레이어가 있으면 fov 를 덮는다.** `0x1401893bf` – `0x140189402`:
`test r8b, 8` 로 정사영이 아닐 때만, 카메라 레이어의 애니메이션 슬롯
(`[camObj+0x2c0]` 배열의 `[idx]+0x33c`) 또는 정적값 `[camObj+0x2d8]` 을 `scene[0x148]` 에 쓴다.
같은 자리에서 `[…]+0x338` / `[camObj+0x2dc]` → `scene[0x114]`(zoom)은 **정사영 여부와 무관하게** 덮는다.

### 5.2 클램프 — `0x140189b1a` – `0x140189b4c` (재확인)

`fov = clamp(fov, 0.1, 179.9)` — 상수 `0x140492654`=0.1, `0x140492900`=179.9. 확인.

### 5.3 투영 행렬 — `0x140183a70` – `0x140184016` (재확인)

분기 `test byte ptr [rdi+0xe0], 8` @ `0x140183aa2`.

- **원근(bit3=0)** — `0x140183edf` –
  - `aspect = renderer[0x84] / renderer[0x88]` (렌더타깃 폭/높이, **f32**) — `0x140183ee9`
    (진입 `rcx` 는 renderState 가 아니라 **renderer** 다 — `0x14017fd2b` 이 `mov rcx, rsi` 로 넘긴다.
    같은 함수의 `[rcx+0x1528]`(디바이스)도 renderState 의 `+0x1518` 과 `0x10` 차이로 정합한다.
    정사영 파스가 정수로 쓰는 `renderState[0x84]/[0x88]` 과 **다른 필드**이니 혼동하지 말 것)
  - `near = scene[0x14c]`, `far = scene[0x150]` — `0x140183f20` / `0x140183f28`
  - `fovRad = scene[0x148] * 0.01745329238474369` — `0x140183f38`, 상수 `0x140492628`
    → **fov 단위는 도(degree)**. 확정.
  - 행렬 빌더 = 디바이스 vtable `+0x10`, 인자 순서 `(matrix, fovRad, aspect, near, far)` — `0x140183f50`
  - **세로 화각인가**: 인자 배치가 표준 `PerspectiveFov(fovY, aspect, near, far)` 와 일치하고
    aspect 가 별도 인자로 들어간다는 점에서 **세로(유력)**. 빌더가 디바이스 vtable 뒤에 있어
    바이트로 못 박지는 못했다 — **[미해결]**. (Waple 은 이미 세로로 구현돼 있고 코퍼스에 반례가 없다.)
  - `0x140183f11` 의 `je` 는 진입 분기의 결과가 이미 정해져 있어 ±2000 팔이 **도달 불가**다
    (ortho 쪽의 대칭 사고와 같은 모양 — `scene-postprocessing.md` §5.3 보강 항목 참조).
- **정사영(bit3=1)** — `0x140183ab8` – `0x140183eda`: near/far **±2000 고정**
  (`0x140183df9`/`0x140183e01`, 상수 `0x14049294c`=2000.0 · `0x140492a1c`=−2000.0),
  `nearz`/`farz` 를 읽는 팔은 도달 불가. `fovRad` 는 `[camera+0x120]` 에 그대로 실린다(`0x140183dd9`).

> **[부분 해소 — §5.7.3]** 이 슬롯(`renderer+0x120` = `renderState+0x110`)의 **정사영 쪽 값**은
> 소비처를 찾았다: 레이어 `perspective` 원근 카메라의 화각이다(`0x140184f17`). 즉 2D 씬의
> 레이어 원근은 `general.perspectiveoverridefov` 를 쓴다.
> **원근 쪽 값**(`2·atanf((1/m11)/2000)`, `0x140183f53`–`0x140183f71`, `xmm6`=2000.0 @`0x140183f09`)은
> 여전히 소비처 미상이다 — **[미해결]**. 레이어 원근 게이트가 2D 전용이라 그 경로로는 도달하지 않는다.

### 5.4 `orthogonalprojection.auto` 는 매 프레임 돈다 (신규)

```
0x140189d8f  test byte ptr [rbx+0xe0], 0x10      ; bit4 = auto
0x140189d9b  call 0x14018b2c0                    ; Scene::autoSizeOrtho
```
`Scene::updateCamera` 꼬리에 있으므로 **로드 1회가 아니라 프레임마다** 첫 `type==1` 오브젝트의
`size` 로 정사영 크기와 오브젝트 센터링을 다시 잡는다. 오브젝트 `size` 가 애니메이션되면 따라 움직인다.

### 5.5 2D eye 재중심화 (신규) — `0x140189da0` – `0x140189df0`

```
if (scene[0xe0] & 8) {                       /* 정사영 */
    rs[0x68] += (float)rs[0x84] * 0.5;       /* eye.x += W/2 */    ; 0x140189db0–0x140189dc4
    rs[0x6c] += (float)rs[0x88] * 0.5;       /* eye.y += H/2 */    ; 0x140189dd0–0x140189de4
    rs[0x70]  = 2000.0;                      /* eye.z */           ; 0x140189df0 (imm 0x44fa0000)
}
```
뷰 행렬(`renderState+0x38`)은 **재중심화 전** eye 로 이미 만들어졌다(`0x140189d0b`–`0x140189d8b`,
룩앳 빌더 `0x14019d920`). 즉 이 보정은 **셰이더가 보는 eye 위치**(정사영 볼륨 `[0,W]×[0,H]` 기준
캔버스 중앙, z=+2000 = far 평면)만 고친다. 정사영 near/far 가 ±2000 인 것과 정확히 맞물린다.

### 5.6 zoom 적용 조건 (부수)

```
0x14017fd3f  eax = scene[0xe0]; shr eax,3; test al,1     ; 정사영일 때만
0x14017fd50  xmm0 = scene[0x154]            /* general.zoom */
0x14017fd5d  xmm0 *= scene[0x114]           /* 카메라 레이어/경로 zoom */
```
**`zoom` 은 2D 전용**이고 두 채널이 곱해진다. 3D 씬에서는 무시된다.
(`lib.sceneScript.d.ts:1957-1962` 의 `ICamera.fov`="For 3D scenes only" / `zoom`="For 2D scenes only" 와 일치.)

### 5.7 레이어 `perspective` 플래그 — z 가 화면 크기에 먹는 법 (신규 · 이번 레인 확정)

이 문서의 종전 판은 오브젝트 `perspective` 키를 다루지 않았다. **소비처를 찾았다.**

#### 5.7.1 키 → 비트 (직접 재측정)

오브젝트 프로퍼티 디스크립터 등록에서 `"perspective"`(문자열 `0x140490890`, 길이 11 → SSO 라
`lea` 가 아니라 `movsd`+`mov` 로 온다)는 두 클래스에 붙는다: `0x1401ee9a4`(이미지 계열) ·
`0x140227535`(다른 레이어 클래스). 등록 직후 `[desc+0x34] = 0x120`(오프셋) · `[desc+0x30] = 6`(타입),
핸들러 4종 `0x14019c620`/`0x14019c6f0`/`0x14019c7f0`/`0x14019c830` 이 실린다(`0x1401ee9bd`–`0x1401eea1a`).

> **디스크립터 표 함정 재확인.** 이름 등록 `call 0x14000f880` **뒤**에 오는 `+0x30`/`+0x34` 스토어가
> *방금 등록한* 항목의 것이다. 다음 항목의 SSO 문자열 세팅이 그 사이에 끼어들어 있어서, 순진하게
> 읽으면 한 칸 밀린다. 여기서는 `visible`(같은 `+0x120`, 타입 6)의 스토어와 대조해 정렬을 확인했다.

비트는 핸들러 안에 박혀 있다 — `0x14019c653`–`0x14019c659`:
```
btr edx, 7        ; false
bts ecx, 7        ; true
cmove ecx, edx    ; asBool(0x140086300) 결과로 선택
mov [r14+r15], ecx ; r14 = [desc+4] = 0x120
```
→ **`perspective` = 오브젝트 flags(`+0x120`) bit7.** (`visible` 은 같은 dword bit0 — `0x1401e1ac6`
`and 0xfffffffe` / `or 1`.)

#### 5.7.2 소비 게이트 — `0x1401ed259` – `0x1401ed27a`

```
0x1401ed259  test dword ptr [rs+0x118], 0x400   ; renderState 플래그 bit10 = **정사영 씬**
0x1401ed263  je  skip
0x1401ed265  test byte  ptr [obj+0x120], 0x80   ; 레이어 perspective
0x1401ed26c  je  skip
0x1401ed26e  lea r8,  [rbp+0x50]                ; ← renderState[0x11a0] 에서 복사한 **투영행렬**
0x1401ed272  mov rcx, rdi                       ; renderState
0x1401ed275  lea rdx, [rsp+0x30]                ; ← renderState[0x1160] 에서 복사한 **뷰행렬**
0x1401ed27a  call 0x140184f00
```

**renderState+0x118 bit10 = "이 씬은 정사영(2D)"** 이다(이번에 확정):
`0x14018768a` 가 `scene[0xe0]` bit3(=`orthogonalprojection`)이 설 때만 이 비트를 세우고
(`0x14018767c`–`0x140187688`), 씬 초기화 `0x1401872ca` 가 지운다. 같은 비트를 보는 다른 소비처가
독립 확증한다 — `0x1402582ff` 는 2D 가 아닐 때 `materials/fonts/fontbackground_depth.json` 을 고르고,
`0x14018e175` 는 2D 면 z 성분을 0 으로 죽인다.

> 즉 **레이어 `perspective` 는 정사영(2D) 씬 전용**이다. 3D 씬에서 켜도 아무 일도 없다.
> 시차 레이어 오프셋(§3.2)과 같은 모양의 게이트다.

같은 함수(`0x1401ed0d0` – `0x1401edb1b`)에 **두 번째** 호출부가 있다(`0x1401ed5b9`–`0x1401ed5dc`):
부모(`r14`)가 `perspective` 인데 자식(`rsi`)은 아닐 때 자식에도 같은 변환을 적용한다 —
**부모의 원근이 자식에 상속되고, 자식이 이미 켰으면 두 번 걸지 않는다.** 텍스트 레이어 쪽
(`0x14025746a` · `0x140258587` · `0x14025d886` · `0x14025d9fa`)도 같은 bit10 을 본다.

#### 5.7.3 카메라 구성 — `0x140184f00` – `0x140184ff7`

인자 `(rcx = renderState, rdx = view 4×4, r8 = proj 4×4)`. **proj 는 입력이자 출력**이다 —
정사영 행렬의 `m[1][1]` 을 읽어 거리를 역산한 뒤 그 자리에 원근 행렬을 덮어쓴다.

```
fov = rs[0x110]                                   ; 0x140184f17  실효 fov(라디안)
t   = tanf(fov * 0.5)                             ; 0x140184f28 → 0x14041b0d0
inv = 1.0 / proj[0x14]                            ; 0x140184f43  proj[0x14] = m11 = 2/H
d   = 1.0 / (t / inv)   = 1/(tan(fov/2)·m11) = H/(2·tan(fov/2))     ; 0x140184f48 · 0x140184f54

view[0x30] -= (float)rs[0x84] * rs[0xf8]          ; 0x140184f4c–0x140184f7e   (= W·0.5)
view[0x34] -= (float)rs[0x88] * rs[0xfc]          ; 0x140184f83–0x140184fa2   (= H·0.5)
view[0x38]  = -d                                  ; 0x140184f77(부호반전 @0x140492ff0) · 0x140184fb3

far  = max(15000.0, d + 1000.0)                   ; 0x140184f6f · 0x140184fa7 · 0x140184faf
near = 5.0                                        ; 0x140184fd2 · 0x140184fda
asp  = rs[0x74] / rs[0x78]                        ; 0x140184fb8 · 0x140184fc4  (렌더타깃 W/H, f32)
device->vtbl[0x10](proj, fov, asp, near, far)     ; 0x140184fbd · 0x140184fe0  (§5.3 과 같은 빌더)
```

행렬 오프셋 `0x30/0x34/0x38` 은 요소 12/13/14 다 — **열주도든 행주도든 여기가 병진**이라
이 지점은 규약 판정에 쓸 수 없다(함정 §14). 규약 논거는 다른 곳에서 가져와야 한다.

**CRT 동정(재측정).** `0x14041b0d0` 은 `tanf` 다 — 소각 근사가 `x + x³·(1/3)`,
상수 `0x140471e98` = `0.3333333333333333`(`0x14041b12c` `vfmadd132sd`). `sinf`(`x − x³/6`)·
`cosf`(`1 − x²/2`)와 구분된다.

**`rs[0xf8]`/`rs[0xfc]` 의 정체(이번에 확정).** `Composite::buildProjection` 의 정사영 팔이 쓴다:
```
0x140183d96  rs[0xf8] = 0.5 − (오른쪽크롭 − 왼쪽크롭)/(2·W)
0x140183dc1  rs[0xfc] = 0.5 − (위쪽크롭  − 아래크롭)/(2·H)
```
크롭/맞춤 오프셋이 없으면 정확히 **0.5** 다. 원근 팔은 같은 슬롯을 **0 으로 밀어 둔다**
(`0x140183ef1  mov qword ptr [rcx+0x108], 0`) — 어차피 게이트가 2D 전용이라 도달하지 않는다.
(renderer+0x108/0x10c = renderState+0xf8/0xfc. renderState = renderer + 0x10.)

**`rs[0x110]` 의 정체(§5.3 미해결 해소).** 정사영 팔이 `rs[0x110] = scene[0x148]·(π/180)`
(`0x140183dc9`–`0x140183dd9`, 상수 `0x140492628`)를 넣는다. 2D 씬의 `scene[0x148]` 은
`perspectiveoverridefov`(§5.1)이므로 **레이어 원근의 화각은 `general.perspectiveoverridefov`** 다.
`fov` 가 아니다. (원근 팔이 같은 슬롯에 `2·atanf((1/m11)/2000)` 를 넣는 것은 여전히
소비처 미상 — **[미해결]**. 게이트가 2D 전용이라 이 경로와는 무관하다.)

#### 5.7.4 그래서 z 가 화면 크기에 어떻게 먹는가 (수식)

카메라는 캔버스 중앙 `(W·cx, H·cy)` 위 거리 `d` 에 놓여 −z 를 본다(뷰 병진이 `(−W·cx, −H·cy, −d)`).
정사영 픽셀 공간의 점 `(x, y, z)` 는 원근분할 뒤

```
d       = H / (2·tan(fov/2))              fov = perspectiveoverridefov (도)
s(z)    = d / (d − z)
screen  = center + (xy − center) · s(z)   center = (W·cx, H·cy),  크롭 없으면 (W/2, H/2)
```

- `z = 0` → `s = 1` → **정사영과 픽셀 동일**. `perspective` 를 켜도 그림이 안 바뀐다.
- `z > 0`(카메라 쪽) → 확대, `z < 0` → 축소. `z ≥ d` 는 카메라 평면 뒤라 클립된다.

**코퍼스 검산.** 저작 기본 `fov 95° · H 256`:
`tan(47.5°) = 1.0913` → `d = 256/2.18262 = 117.29`. `z = +10` 이면 `s = 1.0932`(9.3% 확대).
동봉 6씬이 저작한 `perspectiveoverridefov = 90.760002` 에서는 `d = 126.31`.
`H = 1080`(설치본 초광폭 4씬) → `d = 494.82`.
이 값들은 `Tests/WapleCoreTests/SceneGeometryCameraMathTests.swift` 가 자물쇠로 걸고 있다.

**코퍼스 실피해는 0 이다.** `perspective:true` 저작이 동봉·설치본 통틀어
`presets/clock/preview3dclock/scene.json` 1씬 + `presets/clock/preset.json` 템플릿 1건뿐이고,
그 레이어의 `origin.z` 가 `0.000` 이라 `s(0) = 1` — 정사영 출력과 픽셀 동일이다(§6.6).

---

## 6. 동봉 도달 실측

`general` 블록을 가진 모든 JSON(파일명 `scene.json` 에 한정하지 않음 — `ricepod.json`,
`fantasticcar.json` 이 그 밖에 있다)을 세었다.

### 6.1 키 도달·값 분포

| 키 | 동봉(172) | 설치본(190) | 저작값 분포(설치본) |
|---|---:|---:|---|
| `camerashake` | 168 | 175 | `false` 174 · **`true` 1** |
| `camerashakespeed` | 168 | 175 | `3.0` 96 · `3` 78 · `5` 1 |
| `camerashakeamplitude` | 168 | 175 | `0.5` 173 · `0.01` 2 |
| `camerashakeroughness` | 168 | 175 | `1.0` 96 · `1` 77 · `0.1` 2 |
| `cameraparallax` | 168 | 175 | `false` 174 · **`true` 1** |
| `cameraparallaxamount` | 168 | 175 | `0.5` 174 · `1` 1 |
| `cameraparallaxdelay` | 168 | 175 | `0.1`/`0.10000000149011612` 174 · `1` 1 |
| `cameraparallaxmouseinfluence` | 168 | 175 | `0` 173 · `1.0` 1 · `0.5` 1 |
| `camerapreview` | 168 | 175 | `true` 전건 |
| `camerafade` | 94 | 102 | `true` 99 · `false` 3 |
| `fov` | 94 | 98 | `50.0` 97 · `100` 1 |
| `perspectiveoverridefov` | 77 | 77 | `95.0` 71 · `90.760002` 6 |
| `nearz` | 92 | 96 | `0.01` 계열 92 · `0.1` 계열 4 |
| `farz` | 92 | 96 | `10000.0` 전건 |
| `orthogonalprojection` | 171 | 183 | 동봉 `{256,256}`166 · `{auto:true}`2 · `{600,600}`1 · `{640,640}`1 · `null`1 <br> 설치본 `{256,256}`166 · `{1920,1080}`4 · `null`3 · `{3840,2160}`2 · `{auto:true}`2 · 기타 초광폭 4 |
| `zoom` | 89 | 92 | `1.0` 전건 |
| 오브젝트 `parallaxDepth` | 99/203 오브젝트 (83씬) | 131/294 (88씬) | `1 1` 118 · `0 0` 5 |

### 6.2 실제로 켜진 씬 — 단 둘

| 씬 | 기능 | 값 | 투영 | 동봉? |
|---|---|---|---|---|
| `assets/effects/depthparallax/preview/scene.json` | `cameraparallax:true` | amount 0.5 · delay 0.1 · **mouseinfluence 1.0** | 정사영 600×600 | **동봉 ✓** |
| `projects/defaultprojects/ricepod/ricepod.json` | `camerashake:true` | speed 5 · amplitude 0.01 · roughness 0.1 | `null` = **원근(3D)** | 동봉 ✗ |

**`camerashake:true` 는 동봉 코퍼스에 0건**이다. 동봉만 쓰는 회귀 스위트로는 shake 경로를
검증할 수 없다.

`depthparallax` 프리뷰의 유일한 레이어는 `parallaxDepth: "0.00000 0.00000"` 이다 —
**레이어 이동량이 0**이고, 시차의 목적이 전적으로 `g_ParallaxPosition` 유니폼 공급이다.
§3.2 의 "레이어 오프셋" 채널은 동봉 코퍼스에서 **실제로 켜지는 사례가 0건**이다.

### 6.3 `ricepod` shake 를 수식에 대입

```
speed 5 → phi = 25·t
roughness 0.1 → k = powf(0.1f,3.0f)
```
`0.1f³ = 1.0000000447e-3`, 비교 상수 `0x140492608` = `1.0000000475e-3`. 두 값의 차(2.8e-12)가
이 크기의 float ulp(≈1.16e-10)보다 작아 **같은 float 로 반올림**된다 → `comiss` 가 같음 →
`jbe` 성립 → **거칠기 리매핑을 건너뛴다**. 3D 이므로 `scale = 0.01 × 0.1 = 0.001` 월드 단위.

```
delta(t) = 0.001 · ( cos(25t), sin(33.325t), sin(25t) )
```
`ricepod` 는 `camera.paths` 도 있으므로 경로 재생 분기(`0x140189a6f`)에서 shake 가 붙는다.

### 6.4 `camera.paths` / `camerafade` 도달

| 씬 | `camerafade` 실효 |
|---|---|
| `projects/defaultprojects/arsenal/scene.json` | 키 없음 → **기본 true** |
| `projects/defaultprojects/demon_core/scene.json` | `false` |
| `projects/defaultprojects/dna_fragment/scene.json` | `false` |
| `projects/defaultprojects/fantasticcar/fantasticcar.json` | 키 없음 → **기본 true** |
| `projects/defaultprojects/neon_sunset/scene.json` | `false` |
| `projects/defaultprojects/ricepod/ricepod.json` | `true` |

**동봉 코퍼스에는 `camera.paths` 씬이 0건**이다 → 동봉만 보면 `camerafade` 는 저작 94건 전부가
**도달 불가**(경로가 없어 머티리얼조차 로드되지 않는다). 설치본 6씬 중 3씬에서만 실효한다.

### 6.5 `camerapreview` — 런타임 미소비 재확인

`wallpaper64.exe` 전체를 ASCII·UTF-16LE 양쪽으로 훑어 `camerapreview` 문자열 **0건**.
같은 스캔에서 `camerashake`(`0x14048e900` 외 3), `cameraparallax`(`0x140488ae0`,
`0x140489100` 외), `camerafade`(`0x14048e8c8`), `perspectiveoverridefov`(`0x14048e8e8`),
`nearz`(`0x14048e8dc`), `farz`(`0x14048e8d4`), `orthogonalprojection`(`0x1404890c0`) 은 전부 존재한다.
15바이트 이하 SSO 리터럴 가능성도 배제했다(`parallax` 바이트열의 코드 내 임베드 0건).
→ **에디터 전용 키. 168씬 전건 저작이지만 플레이어는 읽지 않는다.**

### 6.6 레이어 `perspective` 도달 (신규)

`general` 이 아니라 **오브젝트** 키다. JSON 전량(파일명 무관)에서 세었다.

| 코퍼스 | `"perspective"` 저작 | `true` | `false` |
|---|---:|---:|---:|
| 동봉 `Sources/WapleRender/Resources/WEAssets/**` | 18건 | **2** | 16 |
| 설치본 `wallpaper_engine/**` | 40건 | **2** | 38 |

`true` 2건의 정체(양쪽 코퍼스 동일 파일):

| 파일 | 종류 | `origin` | `angles` |
|---|---|---|---|
| `presets/clock/preview3dclock/scene.json` | 씬 오브젝트 | `… … 0.000` | `0.000 0.000 …` |
| `presets/clock/preset.json` | 프리셋 템플릿(씬 아님) | — | — |

즉 **실제 씬 도달은 1건**이고 그 `origin.z = 0` 이라 `s(0) = 1` — 정사영 출력과 픽셀 동일이다.
`Sources/WapleCore/SceneDocument.swift:242-243` 의 "`perspective:true` 19씬 전부 x/y angles 0"
주장은 **이 두 코퍼스로는 재현되지 않는다**(19씬이 아니라 1씬). 워크샵 코퍼스 수치일 수 있으나
그 자산은 이 컨테이너에 없다(`corpus_scan/` 에 인덱스 tsv 만 있고 씬 JSON 은 없다) — **범위 라벨
없는 수치라 그대로 두면 오해를 부른다**. §7 P-7 참조.

### 6.7 이번 레인에서 재측정한 `general` 키 전수

`general` 블록을 가진 JSON 전량(동봉 333 · 설치본 370 — 씬이 아닌 프리셋/이펙트 JSON 포함)에서
`camera*`/`fov`/`*projection`/`zoom`/`nearz`/`farz` 를 다시 세어 §6.1 과 **전건 일치**함을 확인했다.
바이너리 문자열 스캔(ASCII·UTF-16LE)도 다시 떠서, 플레이어가 아는 카메라 관련 키가 아래 15개로
**닫혀 있음**을 확인했다 — 이 목록 밖의 `camera*` 키는 없다.

```
camerafade(0x14048e8c8)  cameraparallax(0x140488ae0)  cameraparallaxamount(0x14048e968)
cameraparallaxdelay(0x14048e950)  cameraparallaxmouseinfluence(0x140489100)
camerashake(0x14048e918)  camerashakeamplitude(0x14048e998)  camerashakeroughness(0x14048e980)
camerashakespeed(0x14048e900)  farz(0x14048e8d4)  nearz(0x14048e8dc)
orthogonalprojection(0x1404890c0)  perspectiveoverridefov(0x14048e8e8)
perspective(0x140490890, 오브젝트 키)  parallaxDepth(0x1404902c8, 오브젝트 키)
```
`camerapreview` 는 **여전히 0건**이다(같은 스캔에서 위 15개는 전부 잡힌다).
유니폼 이름 `g_ParallaxPosition`(`0x14048dad0`)과 UI 문자열 `ui_browse_properties_mouse_parallax`
(`0x140488bc8`)가 추가로 잡히는데, 앞은 셰이더 유니폼이고 뒤는 에디터 라벨이라 저작 키가 아니다.

**시차 입력원 결론(질문 1 에 대한 답).** 입력은 **마우스 하나뿐**이다.
`g_PointerPosition`(renderState+0x8c, 0..1 정규화)이 유일한 외부 입력이고,
**창 위치도 시간도 초점 식에 들어가지 않는다**(§3.1 의 두 항은 캔버스 중앙과 포인터뿐).
`dt` 는 스무딩 계수에만 들어간다. 세 입력이 합쳐지는 구조가 아니다.

---

## 7. Waple 갭

`Sources/WapleCore/SceneDocument.swift`, `Sources/WapleRender/SceneRenderer.swift`,
`Sources/WapleRender/SceneRendererFrameEncoder.swift`, `Sources/WapleRender/SceneRenderer3D.swift`,
`Sources/WapleRender/ParallaxController.swift` 대조.

| # | 항목 | WE 실측 | Waple 현행 | 등급 | 착지 지점 |
|---|---|---|---|---|---|
| **C-1** | shake 수식 | §2.1 (`cos φ`, `sin 1.333φ`, `sin φ`; `φ = s²·t`) | 2주파 사인 근사 + `roughness` 를 **고주파 오버톤 혼합비**로 해석, `φ = s·t` (`SceneRenderer.swift:920-937`) | **확정 · 미해소** | `SceneRenderer.cameraShakeOffset` 을 §2.1 로 축자 대체. 호출부·바인딩 불변(주석이 이미 그 계약을 적어 두었다) |
| **C-2** | shake `roughness` 의미 | `|v|^(r³)` 크기 리매핑. **r=1 = 무연산** | 오버톤 혼합비(`norm = 1/(1+rough)`) — r=1 이 큰 변화를 준다 | **확정 · 미해소** | 위와 동일 |
| **C-3** | shake 진폭 단위 | 2D `a·H/100` 정사영 픽셀 · 3D `a·0.1` 월드 | `amplitude × shakeNDCScale(0.03)` NDC 고정 (`SceneRenderer.swift:918`) | **확정 · 미해소** | 2D 는 `a*projectionHeight/100` 을 픽셀→NDC 로 환산, 3D 는 `a*0.1` 을 월드 오프셋으로 |
| **C-4** | shake 성분 수 | 3성분(2D 는 z=0) | 2성분(x,y) | 확정 · 2D 무영향 | 3D 경로(`SceneRenderer3D`)에 z 추가 |
| **C-5** | shake 적용 대상 | eye **와** target 에 동일 델타 = 평행이동 | 셰이더 전역 가산(`camX/camY`, `SceneRendererFrameEncoder.swift:668-669`) — 2D 는 등가, 3D 는 `viewProj` 좌승 | 유력 · 실질 등가 | 3D 는 `eye`/`center` 양쪽 가산이 축자 등가 |
| **C-6** | shake 시계 | `g_Time`(renderState+0x130), 432000 s 되감김 | 씬 시간 `t` | 확정 · 등가 | 조치 불요 |
| **C-7** | `camerashake` 코퍼스 활성 | 동봉 **0/168**, 설치본 1/175(3D, `ricepod`) | 주석 "코퍼스 활성 13/168씬(2D 11/3D 2)" (`SceneDocument.swift:1182-1183`), "코퍼스 0.04..1.0 / 0.0..1.1 / 0.5..7.0" (`:1186-1190`) | **확정 · 반증** | 주석 수치를 실측으로 교체. 값 범위 주장도 근거 없음(동봉·설치본 전건 `0.5/1.0/3.0`, 예외는 `0.01/0.1/5` 하나) |
| **W-1** | parallax 시간 성분 | **없음**(마우스 전용) | 없음 | 확정 · 일치 | 조치 불요 |
| **W-2** | `mouseinfluence` 의미 | 초점을 **중앙↔마우스 선형 보간** — `infl=0` 이어도 (정적) 오프셋이 남는다 | 목표 오프셋에 곱하는 게인 (`SceneRenderer.swift:1750`) — `infl=0` → 오프셋 0 | **확정 · 미해소** | 초점 모델로 교체: `focus = lerp(center, mouse, infl)`, 레이어 오프셋 = `(origin−focus)·amount·depth` |
| **W-3** | `cameraparallaxdelay` | `α = min(1, 10·(1−d/3)·dt)`, τ = `0.3/(3−d)`, `d≥3` 정지 | `α = 1 − exp(−dt/d)`, τ = `d` 초 (`ParallaxController.swift:45-50`) | **확정 · 미해소** | `smoothed()` 를 `α = min(1, 10*(1 - delay/3)*dt)` 로. 기본 0.1 에서 τ 0.100→0.103(3.4%)이라 **동봉 회귀 영향은 미미**, 비기본값(설치본 `ricepod` d=1: 1.0s→0.15s, 6.7배)에서 크게 갈린다 |
| **W-4** | 레이어 오프셋 공식 | `(origin − focus) × amount × parallaxDepth`, z=0 | 전역 `cameraOffset × parallaxDepth`(`SceneRendererFrameEncoder.swift:668-669`), `cameraOffset = mouse × amount × infl × 0.1` | **확정 · 미해소** | `origin` 종속항이 통째로 없다. WE 는 초점에서 먼 레이어일수록 더 움직인다 |
| **W-5** | 레이어 오프셋 게이트 | `cameraparallax` **&&** 정사영(2D) | 2D 전용(3D 는 채널 없음) | 확정 · 일치 | 조치 불요 |
| **W-6** | `g_ParallaxPosition` 유니폼 | renderState+0x9c, `clamp01(focus/size)`, 기본 (0.5,0.5) | **미구현**(리포 전체에 문자열 없음) | **확정 · 미해소** | `depthparallax` 이펙트를 구현할 때 필요. 무저작 씬은 `(0.5,0.5)` 로 채워야 셰이더가 중립이 된다 |
| **W-7** | `parallaxDepth` 기본값 | ~~**[미해결]** — 오브젝트 생성자에서 초기화 지점을 못 찾았다~~ → **`(1.0, 1.0)` 확정** (`0x1401ddce1`/`0x1401ddcec`, §8.6) | `Vec2(1,1)` — `SceneDocument.swift` 의 `public var parallaxDepth: Vec2 = Vec2(x: 1, y: 1)`(세 곳) 과 파스 폴백 `vec2(obj["parallaxDepth"]) ?? Vec2(x: 1, y: 1)` | **해소 · 일치** | 조치 불요. Waple 값이 맞았다. (이번 레인도 처음엔 `.text` **선형** 스윕으로 0건을 받아 같은 결론에 갇힐 뻔했다 — §8.6 방법론 기록 참조) |
| **F-1** | `camerafade` 의미 | 경로 구간 처음/끝 0.5초를 `schemecolor×0.7` 로 덮음. **경로 없으면 무동작** | "파스만(의미 미확정 — 소비 보류)" (`SceneDocument.swift:1216-1218`) | **확정 · 신규** | 카메라 경로를 구현할 때 함께. 동봉 코퍼스 도달 0건이라 우선순위 낮음 |
| **F-2** | 씬 시작 페이드인 | **없다** | 없음 | 확정 · 일치 | 조치 불요 |
| **P-1** | `fov` 단위/축 | 도(확정) / 세로(유력) | 도·세로 (`SceneRenderer3D.swift:1460-1461,1526`) | 확정+유력 · 일치 | 조치 불요 |
| **P-2** | `nearz`/`farz` 기본 | 0.1 / 10000, **3D 원근에서만 사용** | `?? 0.1` / `?? 10000` (`SceneDocument.swift:1885-1886`) | 확정 · 일치 | 조치 불요(2026-08-21 정정 반영됨) |
| **P-3** | 2D 실효 fov | `perspectiveoverridefov`(기본 95) | `perspectiveOverrideFov: Float = 95` 파스 반영, 렌더는 리터럴 95 하드코딩 잔존 | 확정 · 부분 미해소 | `scene-postprocessing.md` W-7 과 동일 항목 |
| **P-4** | `orthogonalprojection.auto` 주기 | **매 프레임** (`0x140189d8f`) | 로드 시 1회(`width ?? 1920` 폴백) | 확정 · 미해소 | 오브젝트 `size` 애니메이션이 있을 때만 갈린다. 동봉 auto 2씬은 정적 |
| **P-5** | 2D eye 재중심화 | `(W/2, H/2, 2000)` (`0x140189da9`–`0x140189df0`) | 해당 개념 없음 | 확정 · 미해소 | 2D 에서 `g_EyePosition` 을 쓰는 셰이더가 생기면 필요 |
| **P-6** | `zoom` 게이트 | 정사영일 때만, `general.zoom × 카메라레이어zoom` | `zoom` 파스·보존만(`SceneDocument.swift:1287` 부근) | 확정 · 미해소 | 코퍼스 전건 1.0 이라 회귀 위험 없음 |
| **P-7** | 레이어 `perspective` | 2D 전용. view 를 `(W·cx, H·cy, d)` 로 옮기고 proj 를 `PerspectiveFov(pofov, aspect, 5, max(15000,d+1000))` 로 교체. `s(z) = d/(d−z)` | `SceneRendererFrameEncoder.quadVertices` 의 "M4 근사" — `perspectiveFov` 를 리터럴 95 로 받고, 상단 코너 x 만 `1/(1+tan(fov/2)·0.1)` 로 줄이는 **임의 근사**(:622-631). z 를 아예 안 본다 | **확정 · 미해소** | `SceneCameraMath.layerPerspectiveScale(z:orthoHeight:fovDegrees:)` 로 코너를 초점 기준 스케일. 저작 fov 는 리터럴이 아니라 `doc.perspectiveOverrideFov` |
| **P-8** | `perspective:true` 도달 주장 | 동봉·설치본 실제 씬 **1건**(`preview3dclock`, `origin.z=0`) | `SceneDocument.swift:242-243` "19씬 전부 x/y angles 0" — 범위 라벨 없음, 이 두 코퍼스로 재현 불가 | **미해결(반증 아님)** | 주장에 코퍼스 범위 라벨을 붙이거나 실측으로 교체. 워크샵 코퍼스가 근거라면 그렇게 적어야 한다 |
| **X-1** | 순수 산술의 자리 | — | shake·parallax 산술이 전부 `WapleRender`(리눅스 실행 검증 불가)에 있었다 | 해소 | **`Sources/WapleCore/SceneCameraMath`** 신설 — shake/초점/α/레이어오프셋/유니폼/레이어원근을 실측 그대로 담고 `SceneGeometryCameraMathTests`(26개)가 닫힌 식으로 잠근다. `ParallaxController.smoothed` 는 α 를 여기로 위임 |
| **A-1** | 자동회전(autorotate) | **존재하지 않는다**(§8.0 — JSON·`d.ts`·바이너리 키·셰이더 유니폼 전부 0건) | Waple 에도 없다 | 확정 · 일치 | 조치 불요. "카메라가 자동으로 돈다" 는 요구가 오면 `camera.paths` 로 표현해야 한다 |
| **F-3** | `camera.paths` 재생 | 3차 에르미트, `v = p0 + Δ·(−u³+1.5u²+0.5u)`, eye·center·**up**·zoom 네 축(§8.2) | **미구현.** `SceneDocument.swift` 의 `guard … let camDict = scene["camera"] as? [String: Any]` 블록이 eye/center/up/fov/nearZ/farZ 만 읽고 `paths` 키를 아예 보지 않는다 | **확정 · 미구현** | `WapleCore.CameraMotion.step(paths:state:dt:)` 로 이미 뽑아 뒀다. 남은 것은 ① `camera.paths` 파스 ② `scripts/camera_XX.json` 로드 ③ 렌더 배선. 동봉 도달 0건이라 회귀 위험 0 |
| **F-4** | 경로 전진 임계 | 팔마다 다르고(`ts[i+1]` / `duration − ts[i]` / `ts[i]+ts[i+1]`), `duration == ts[last]` 면 마지막 transform 을 건너뛴다(§8.3) | 미구현 | 확정 · 미구현 | 이식할 때 "직관적인 `duration`" 으로 고치지 말 것 — §8.4 가 그 부작용을 적어 뒀다 |
| **P-9** | 오브젝트 flags 기본값 | 생성자가 `+0x120`을 **`0x2001`** 로 깐다 → `visible` true · `perspective` false (§8.6) | `visible` 기본 true · `SceneDocument.swift` 의 `public var perspective: Bool = false` | 확정 · 일치 | 조치 불요. 함정 15 의 근거가 이제 바이트로 있다 |
| **X-2** | 순수 산술의 자리(시간축) | — | 경로 재생·페이드 곡선·실효 fov/zoom·2D eye 재중심화가 **어디에도 없었다** | 해소 | **`Sources/WapleCore/CameraMotion.swift`** 신설. `SceneCameraMath`(무상태 스칼라)와 축을 나눠, 여기는 **상태가 굴러가는** 것만 담는다. `CameraMotionTests`(15) · `CameraMotionPathTests`(16)가 값으로 잠근다 |

### 7.1 우선순위

0. **[2026-08-21 갱신] W-3 은 해소됐다** — `ParallaxController.smoothed` 가 `α = min(1, 10·(1−delay/3)·dt)`
   로 교체됐고, 산술 본체는 `WapleCore.SceneCameraMath.parallaxAlpha` 로 내려가 리눅스에서 실행 검증된다.

1. **W-3(`delay` 매핑)** — 한 줄 수정, 동봉 회귀 위험 거의 없음, 즉시 해소 가능.
2. **C-7(주석 반증)** — 코드 변경 없음. 잘못된 실측 주장이 후속 판단을 오염시키고 있다.
3. **C-1/C-2/C-3(shake 수식)** — 함수 하나 축자 대체. 동봉 도달 0건이라 **비트동일 회귀 위험 0**,
   다만 그래서 회귀 스위트로 검증도 안 된다(설치본 `ricepod` 를 오라클로 써야 한다).
4. **W-2/W-4(parallax 구조)** — 구조 변경. 동봉 1씬(`depthparallax`)의 `parallaxDepth=0` 때문에
   레이어 채널은 여전히 무영향이라, 실효 이득은 W-6(유니폼)과 함께 갈 때 생긴다.
5. **[2026-08-21 추가] W-7 은 해소됐다** — `parallaxDepth` 기본값이 `(1.0, 1.0)` 으로 확정됐고
   Waple 값이 이미 맞다(§8.6). 조치 없음.
6. **[2026-08-21 추가] F-3/F-4(`camera.paths`)는 새 축이다.** 산술은 이미
   `WapleCore.CameraMotion` 에 있고 리눅스에서 실행 검증된다. 남은 것은 파스·로드·배선인데
   **동봉 도달 0건**이라 회귀 위험이 없는 대신 회귀 스위트로 검증도 안 된다 —
   설치본 `arsenal`/`demon_core` 를 오라클로 써야 한다(C-1 계열과 같은 상황이다).
   우선순위는 낮다. 다만 §8.4 의 quirk 는 **이식할 때 반드시 같이** 가져가야 한다.

---

## 8. `camera.paths` 재생 — WE 의 **유일한** 자동 카메라 모션 (2026-08-21 신규)

§1.2 가 "경로 C: `camera.paths` 재생 `0x1401894a9` – `0x140189b07`" 이라고 범위만 적어 둔 자리다.
여기서 그 안을 전부 복원했다. **`Scene::updateCamera` 를 `.pdata` 함수 시작(`0x1401891a0`)에서
선형으로 내려와** 읽었다(함정 17 — 후보 주소에서 거슬러 올라가면 명령 경계가 밀린다).

### 8.0 먼저: 자동회전(autorotate)은 **없다**

x86 을 뜨기 전에 자산부터 훑었다(함정 7).

| 스캔 | 결과 |
|---|---|
| 동봉 1698 JSON · 설치본 2143 JSON 에서 `autorotate`/`rotationspeed`/`orbit`/`spin` | `"Spin"`/`"spin"`/`"SPIN"` 만 (사용자 프로퍼티 라벨·이펙트 이름) — **카메라 키 0건** |
| `lib.sceneScript.d.ts` 의 `interface ICamera` | `fov`(3D 전용) · `zoom`(2D 전용) **둘뿐** |
| `lib.sceneScript.d.ts` 의 `class CameraTransforms` | `eye` · `center` · `up` · `zoom` |
| §6.7 의 바이너리 카메라 키 15개 | 회전·시간 관련 키 없음 |
| `wallpaper64.exe` 바이트 전수(ASCII + UTF-16LE) | `autorotate` **0건** · `g_Camera` **0건** (대조군: `g_EyePosition` @`0x14048d378` 1건 · `g_ParallaxPosition` @`0x14048dad0` 1건은 잡힌다). `bin/*64.dll` 전량에도 `g_Camera` 0건 |
| 셰이더 유니폼 전수(`.vert`/`.frag`/`.h`) | 카메라 관련은 `g_EyePosition`(동봉 25 · 설치본 25) · `g_ViewUp`(8 · 8) · `g_ViewRight`(8 · 8) · `g_ParallaxPosition`(7 · 7) · `g_EyeColor`(4 · 4) — **`g_Camera*` 라는 이름의 유니폼은 양쪽 코퍼스·바이너리 어디에도 0건** |

→ **시간이 스스로 미는 카메라 축은 `camera.paths` 하나다.** shake 는 시간의 함수지만 진폭이
상수라 감쇠도 임펄스 트리거도 없고(§2.3), parallax 는 초점 식에 시간 항이 아예 없다(§3.1).

### 8.1 세 개의 팔 — 그리고 팔마다 다른 "구간 끝"

진입 상태는 셋이다: `scene+0xe4` 경로 인덱스 · `scene+0xe8` transform 인덱스 ·
`scene+0xec` **현재 경로 안에서의 절대 경과 초**.

```
rbp   = scene[0x310]                                     ; paths.begin
rsi   = pathIndex << 5                                   ; path 스트라이드 0x20   0x1401894c5
rcx   = [rsi+rbp]                                        ; transforms.begin
count = ([rsi+rbp+8] − rcx) / 0x2c                       ; 0x1401894e4–0x1401894f0 (magic 0x2e8ba2e8ba2e8ba3)
rdx   = transformIndex * 0x2c                            ; 0x1401894bd
xmm2  = [rdx+rcx]        = cur.timestamp                 ; 0x1401894eb
xmm3  = scene[0xec]      = elapsed                       ; 0x1401894b5

0x1401894f4  comiss xmm3, xmm2 / jb  → ① beforeSegment
0x1401894fd  cmp    r8(idx+1), count / jae → ② holdingLast
                                       그 외 → ③ interpolating
```

| 팔 | 조건 | 자세 | **구간 끝**(전진 임계) | 저장 VA |
|---|---|---|---|---|
| ① beforeSegment | `elapsed < ts[i]` | `transforms[i]` 스냅 | `ts[i] + (i+1<n ? ts[i+1] : 0)` | `0x1401899f3` `addss` |
| ② holdingLast | `i+1 ≥ n` | `transforms[i]` 스냅 | **`duration − ts[i]`** | `0x1401899da` `subss` |
| ③ interpolating | 그 외 | 에르미트(§8.2) | `ts[i+1]` | `0x140189552` |

셋 다 같은 스택 슬롯 `[rsp+0x120]` 에 실리고, 전진 판정이 그 값을 본다(`0x140189a7f`).
①의 `ts[i] + ts[i+1]` 은 **덧셈이다** — 뺄셈도 아니고 `ts[i+1]` 단독도 아니다. 저작 첫
timestamp 가 0 이면(설치본 21경로 전건) `ts[i+1]` 과 같아져 정상 동작하고, 0 이 아니면 어긋난다.

스냅 팔은 `movsd`+`mov` 로 **원본 값을 그대로 복사**한다(`0x1401899f7`–`0x140189a3f`):
`+0x04..0x0c` → eye(`scene+0xf0`) · `+0x10..0x18` → center(`+0xfc`) · `+0x1c..0x24` → up(`+0x108`) ·
`+0x28` → zoom(`+0x114`). 이것이 §4.5 의 transform 레이아웃을 소비 쪽에서 재확인한다.

### 8.2 보간은 **3차 에르미트**다 — 스무스스텝이 아니다

```
u = (elapsed − ts[i]) / (ts[i+1] − ts[i])          ; 0x14018950d → 0x140189567 divss
```

> **코퍼스로는 이 뺄셈이 검증되지 않는다.** 설치본 21경로가 전부 `timestamp[0] == 0` 이라
> `u = elapsed / (ts1 − ts0)` 로 잘못 써도 같은 값이 나온다. 돌연변이 검증에서 실제로 그
> 변형이 **31개 테스트를 전부 통과**했다(M9). 코퍼스 픽스처만으로 잠근 자리는 이런 항을
> 놓친다 — 첫 timestamp 가 0 이 아닌 **합성 경로**를 따로 만들어 잠갔다
> (`CameraMotionPathTests.testUSubtractsSegmentStart`).


기저 조립(`0x140189572`–`0x1401895c5`, 상수 3.0 @`0x140492830` · 1.0 = `xmm15`):

```
u2 = u·u ; u3 = u2·u ; 3u2 = u2·3.0
h11 = u3 − u2                       0x140189593
h01 = 3u2 − 2u3                     0x1401895a1
h00 = (2u3 − 3u2) + 1               0x1401895a6 → 0x1401895c0
h10 = (u3 − 2u2) + u                0x1401895b3 → 0x1401895c5
```

접선은 **양 끝이 같다.** 이웃 제어점을 구간 끝점으로 클램프하기 때문이고, 컴파일러가
`p − p` 를 **명령으로 남겨서** 그 사실이 그대로 보인다(zoom 성분이 가장 짧아 읽기 쉽다):

```
0x140189951  xmm0 = cur.zoom (p0)     0x140189957  xmm2 = next.zoom (p1)
0x140189969  subss xmm3, xmm0         ; (p0 − p0)  ← 이전 제어점 = p0
0x140189975  subss xmm1, xmm0         ; (p1 − p0)
0x14018997e  mulss xmm3, 0.5          0x140189989  mulss xmm1, 0.5
0x14018998d  addss xmm3, xmm1         ; m0 = 0.5(p0−p0) + 0.5(p1−p0)
0x140189985  subss xmm0, xmm2         ; (p1 − p1)  ← 다음 제어점 = p1
0x140189991  mulss xmm0, 0.5          0x140189995  addss xmm0, xmm1   ; m1
```

→ **`m0 = m1 = 0.5·(p1 − p0)`**. 구간 안에서 읽는 제어점은 **정확히 둘**이다 —
`imul` 이 `idx*0x2c`(`0x1401894bd`)와 `(idx+1)*0x2c`(`0x140189530`) 둘뿐이고, `idx−1`/`idx+2` 를
만드는 명령이 없다.

누산 순서(x 성분, `0x1401895f2`–`0x140189636`):

```
acc = m0·h10 ; acc += h00·p0 ; acc += m1·h11 ; acc += h01·p1  →  scene+0xf0
```

**닫힌 식.** `m0 = m1 = 0.5Δ` 를 대입하면

```
v(u) = p0 + Δ · f(u),   f(u) = −u³ + 1.5u² + 0.5u,   Δ = p1 − p0
```

| u | `f(u)` (실물) | 스무스스텝 `3u²−2u³` | 선형 `u` |
|---:|---:|---:|---:|
| 0.25 | **0.203125** | 0.15625 | 0.25 |
| 0.50 | 0.5 | 0.5 | 0.5 |
| 0.75 | **0.796875** | 0.84375 | 0.75 |

`f′(0) = f′(1) = 0.5` — **양 끝 기울기가 0 이 아니다.** 스무스스텝처럼 끝에서 멈추지 않고
일정 속도로 들어왔다 나간다. 경로 사이는 C¹ 이 아니라 **구간별 이즈**다.

**네 축 전부에 걸린다.** eye(`0x1401895bc`–`0x1401896d2`) · center(`0x1401896db`–`0x14018980c`) ·
**up**(`0x140189815`–`0x140189948`) · zoom(`0x140189951`–`0x1401899ac`). up 도 보간되므로
경로 재생 중에는 **롤이 생긴다** — shake 가 up 을 건드리지 않는 것(§2.3)과 대비된다.

### 8.3 전진과 되감기 — `0x140189a74` – `0x140189b07`

```
elapsed += dt                                        ; 0x140189a77 (xmm6 = dt) · 0x140189a87 저장
if (elapsed <= segmentEnd) 끝                        ; 0x140189a8f jbe   ← **같으면 전진하지 않는다**
if (i+1 < count && duration > ts[i+1])               ; 0x140189ab0 jae · 0x140189abf comiss/jbe
     scene[0xe8] = i+1                               ; 0x140189ac5  **dword** — elapsed 유지
else scene[0xe8..0xef] = 0                           ; 0x140189ad9  **qword** — idx·elapsed 동시 0
     scene[0xe4] = (pathIndex+1 >= pathCount) ? 0 : pathIndex+1   ; 0x140189ad6–0x140189b00 cmovae
```

`0x140189ad9` 가 qword 스토어라는 것이 실질적인 관측이다 — `0xe8`(transform 인덱스)과
`0xec`(경과 시간)이 연속이라 **경로 전환 한 번에 둘 다** 0 이 된다. transform 만 넘길 때는
`0xe8` 만 dword 로 써서 경과 시간이 유지된다. 이 비대칭이 없으면 절대 timestamp 기반 보간이 깨진다.

shake 는 **전진 전에** 얹힌다(`0x140189a6f` → `0x140189a77`). 즉 이번 프레임 자세는 `elapsed`
기준이고 `dt` 는 다음 프레임분이다.

### 8.4 저작 duration 이 그대로 지켜지지 않는 자리 (엔진 quirk)

②의 구간 끝이 `duration − ts[i]` 라서, 마지막 transform 을 실제로 붙들게 되는 경로는
**저작 duration 보다 `ts[last]` 만큼 짧게** 끝난다. 조건은 둘 다 서야 한다:

1. `duration > ts[last]` (아니면 ②에 도달하기 전에 다음 경로로 간다 — §8.3 의 `comiss/jbe`)
2. `ts[last] > 0`

설치본 21경로 중 이 조건에 걸리는 것은 **`demon_core/scripts/camera_00.json` 의 4경로뿐**이다.

| 경로 | duration | `ts[last]` | 실효 재생 |
|---|---:|---:|---:|
| demon_core 0 | 300 | 40 | **260** |
| demon_core 1 | 450 | 34 | **416** |
| demon_core 2 | 400 | 40 | **360** |
| demon_core 3 | 350 | 36 | **314** |
| neon_sunset 0 | 5 | 0 (transform 1개) | 5 (일치) |
| 나머지 16 | = `ts[last]` | — | 저작값 그대로 |

`demon_core` 는 `camerafade:false` 라 페이드와는 상호작용하지 않는다. 만약 켰다면 페이드아웃
조건(`duration − elapsed < 0.5`, §4.2)이 `elapsed > 299.5` 인데 경로가 260 에서 끝나므로
**페이드아웃이 영원히 안 걸렸을** 것이다 — 이 quirk 를 "직관적인 `duration`" 으로 고치면
그쪽 동작이 같이 바뀐다. 실물을 그대로 이식하는 것이 옳다.

### 8.5 설치본 경로 코퍼스 전수 (동봉 = 0)

`paths` 배열을 가진 JSON 전량(파일명 무관)에서 세었다.

| 항목 | 동봉 `WEAssets/**`(씬 172) | 설치본 `wallpaper_engine/**`(씬 190) |
|---|---:|---:|
| `camera.paths` 를 가진 씬 | **0** | 6 |
| 경로(path) | 0 | 21 |
| transform | 0 | 41 |
| transform 개수 분포 | — | `2` × 20 · `1` × 1 |
| `timestamp[0] == 0` | — | **21/21** |
| `duration == ts[last]` | — | 16/21 (나머지 5는 `>`; §8.4) |
| transform 이 `zoom` 을 저작 | — | 9/41 (`ricepod` · `neon_sunset`) |
| 경로 씬의 투영 | — | **6/6 이 `orthogonalprojection: null` = 3D** |

마지막 줄이 중요하다 — `zoom` 은 정사영 전용이므로(§5.6) **저작된 transform `zoom` 9건은
코퍼스에서 한 번도 소비되지 않는다.** 그래서 transform 에 `zoom` 키가 없을 때의 파서 기본값은
코퍼스로는 판별할 수 없다(§8.7).

`camerafade` 실효(§6.4 재측정 일치): `ricepod` `true` · `arsenal`/`fantasticcar` 키 없음(기본 true)
· `demon_core`/`neon_sunset`/`dna_fragment` `false` → **설치본 6경로 씬 중 3씬**에서만 페이드가 돈다.

### 8.6 `parallaxDepth` 기본값 = (1.0, 1.0) — §7 W-7 **해소**

레이어 생성자(`0x1401ddbb0` – `0x1401de19b`, `.pdata` 5조각)가 멤버를 리터럴로 깐다:

```
0x1401ddc72  mov word  ptr [r14+0x120], 0x2001     ; flags
0x1401ddc7c  mov qword ptr [r14+0x124], 0          ; sortorder · origin.x
0x1401ddc83  mov qword ptr [r14+0x12c], 0          ; origin.y · origin.z
0x1401ddc8a  mov dword ptr [r14+0x134], 0x3f800000 ; scale.x = 1
0x1401ddc95  mov dword ptr [r14+0x138], 0x3f800000 ; scale.y = 1
0x1401ddca0  mov qword ptr [r14+0x13c], 0x3f800000 ; scale.z = 1 · angles.x = 0
0x1401ddcab  mov qword ptr [r14+0x144], 0          ; angles.y · angles.z
…
0x1401ddcd6  mov dword ptr [r14+0x16c], 0x3f800000
0x1401ddce1  mov dword ptr [r14+0x170], 0x3f800000 ; parallaxDepth.x = 1
0x1401ddcec  mov dword ptr [r14+0x174], 0x3f800000 ; parallaxDepth.y = 1
```

같은 클래스인 근거: 오브젝트 디스크립터 표(`0x1401e0530`)가 `origin`→`0x128` · `scale`→`0x134` ·
`angles`→`0x140` 을 등록하는데, 위 초기화가 그 셋을 정확히 `(0,0,0)`/`(1,1,1)`/`(0,0,0)` 로 깐다.
그리고 소비 쪽(`0x14018a0ff`/`0x14018a10d`)이 곱하는 슬롯이 바로 `+0x170`/`+0x174` 다.

부수 확정 두 가지:

- **flags 초기값 `0x2001`** → `visible`(bit0) 기본 **true**, `perspective`(bit7) 기본 **false**.
  함정 15("저장을 건너뛰는 실패 분기는 false 가 아니라 생성자 기본값을 유지한다")가 여기서
  바이트로 확인된다. bit13(0x2000)의 이름은 **[미해결]**.
- `parallaxDepth` 디스크립터 재확인 — 이름 `0x1404902c8`("parallaxDepth", 길이 13),
  `[desc+0x34] = 0x170`(`0x1401e0848`), `[desc+0x30] = 1`(vec2, `0x1401e085a`).
  바로 뒤 `0x1401e0861` 의 `movsd [rip+…]`(`0x1404902d8`)는 **다음 항목의 SSO 이름**이라
  현재 항목의 값이 아니다 — 함정 16 의 그 모양이다.

> **방법론 기록.** 처음엔 `.text` 를 **선형으로** 디스어셈해 `[reg+0x170]` 스토어를 찾았고
> "0건" 이 나왔다. 그건 틀린 답이다 — 섹션 선형 스윕은 데이터/패딩에서 명령 경계가 어긋나
> 그 뒤 전부를 놓친다. 같은 스캔이 `origin`(`+0x128`)·`scale`(`+0x134`)도 0건을 줬다는 점에서
> 바로 들통났다. **`.pdata` 함수 시작마다 따로 디스어셈**하면 `+0x170` 을 덮는 스토어가 50건,
> 그 중 오브젝트 디스크립터 등록 함수(`0x1401e0530`)가 있는 레이어 클래스 대역에 9건이고 위 두 줄이 거기 있다.

### 8.7 이 절이 남기는 `[미해결]`

1. **transform 의 `zoom` 파서 기본값.** 스냅/보간 둘 다 `+0x28` 을 읽지만, JSON 에 `zoom` 이 없을 때
   파서가 무엇을 넣는지는 확인하지 못했다. 코퍼스로도 판별 불가다 — `zoom` 을 저작한 9 transform 이
   전부 3D 씬에 있어 소비 자체가 안 된다(§8.5). `scene+0x114` 의 **생성자** 기본은 1.0(`0x140186d46`)
   이지만 그것은 별개 슬롯이다.
2. **transform 이 3개 이상인 경로의 중간 전진.** 설치본 21경로가 전부 1~2개라 실물로 관측할 자산이
   없다. 코드상으로는 §8.3 조건이 매 구간에 그대로 적용된다(중간 `ts[k]` 가 `duration` 을 넘으면
   거기서 다음 경로로 튄다).
3. **경로가 하나도 없는 path(빈 `transforms`)**. 실물은 **첫 경로**의 transform 유무만 검사하고
   (`0x140189261`–`0x140189269`) 나머지 경로는 방어하지 않는다. 그런 자산에서 무엇을 읽는지는
   확인하지 않았다(Waple 오라클은 `nil` 을 준다 — 의도적 divergence).
4. ~~`scene+0xe4`/`0xe8`/`0xec` 를 **씬 로드 시** 무엇으로 놓는지.~~ → **§8.8 에서 해소.** 셋 다 0 이다.

---

### 8.8 씬 생성자의 카메라 기본값 (신규 · §8.7-4 해소)

`Scene::Scene`(`0x140186c90` – `0x140188816`, `.pdata` 4조각). 진입에서 `xor r15d, r15d`
(`0x140186cb4`)로 **r15 = 0** 을 만들어 두고 멤버를 리터럴로 깐다.

```
0x140186d1f  mov qword ptr [r14+0xe0], 0x26        ; flags = 0x26  **그리고 scene[0xe4] = 0**
0x140186d3f  mov qword ptr [r14+0xe8], r15         ; scene[0xe8] = 0 **그리고 scene[0xec] = 0**
0x140186d46  mov dword ptr [r14+0x114], 0x3f800000 ; 런타임 zoom      = 1.0
0x140186d51  mov dword ptr [r14+0x13c], 0x3f800000 ; camera zoom 슬롯 = 1.0  (§1.2)
0x140186d5c  mov dword ptr [r14+0x140], 0x42480000 ; fov                    = 50.0
0x140186d67  mov dword ptr [r14+0x144], 0x42be0000 ; perspectiveoverridefov = 95.0
0x140186d72  mov dword ptr [r14+0x148], 0x42480000 ; 실효 fov(초기) = 50.0
0x140186d7d  mov dword ptr [r14+0x14c], 0x3dcccccd ; nearz = 0.1
0x140186d88  mov dword ptr [r14+0x150], 0x461c4000 ; farz  = 10000.0
0x140186d93  mov dword ptr [r14+0x154], 0x3f800000 ; general.zoom = 1.0
```

**경로 재생 상태 셋이 전부 0 에서 시작한다** — 두 qword 스토어가 `0xe0/0xe4` 와 `0xe8/0xec` 를
쌍으로 덮기 때문이다. §8.3 의 "경로 전환은 qword 하나로 둘을 민다" 와 같은 레이아웃 활용이다.

**flags 초기값 `0x26` = `0b100110`** — bit1 · bit2 · bit5 가 선다. 그중 **bit2 = `camerafade`** 이므로
**`camerafade` 는 키가 없으면 기본 true** 다(§6.4 가 코퍼스 관찰로 말하던 것을 바이트로 확정).
bit3(`orthogonalprojection`) · bit4(auto) · bit7(`camerashake`) · bit8(`cameraparallax`)는 전부 0 —
**기본 false** 다. bit1 · bit5 의 이름은 **[미해결]**.

`nearz`/`farz`/`fov`/`perspectiveoverridefov`/`zoom` 기본값은 §5.1·§7 P-2 가 코퍼스로 말하던 값과
**전건 일치**한다(0.1 / 10000 / 50 / 95 / 1.0). 이제 근거가 코퍼스가 아니라 생성자 리터럴이다.

---

## 부록 C. VA 인용 정정 기록 (2026-08-21)

`scripts/re/va_citations.py` 전수 대조로 이 문서의 인용 세 건이 **명령 경계가 아니었다**.
전부 +1~+4 어긋난 것이고, 그 주소에서 선형 디스어셈을 시작하면 없는 명령이 보인다(함정 17).
직접 다시 떠서 정정했다 — 결론은 하나도 안 바뀐다.

> [VA-정정] 종전 `0x1401872cb` → `0x1401872ca` · 종전 `0x140227539` → `0x140227535` · 종전 `0x1401ee98c` → `0x1401ee98a`

| 정정 | 실제 명령 | 무엇이었나 |
|---|---|---|
| `0x1401872ca` | `and dword ptr [r13 + 0x118], 0xfffffbff` | renderState 플래그 bit10(정사영) **해제** — 마스크 `0xfffffbff` 가 그 비트다. §5.7.2 서술 그대로 |
| `0x140227535` | `movsd xmm0, qword ptr [rip + 0x269353]` → `0x140490890` `"perspective"` | 두 번째 레이어 클래스의 SSO 이름 적재. 종전 값은 그 명령의 **disp32 필드 위치**(xref 스캔 산출물을 그대로 적은 것) |
| `0x1401ee98a` | `cmp rcx, 0x1f` | 부록 A 의 디스어셈 **시작** 주소. 여기서 내려오면 `0x1401ee9a4` 의 `lea "perspective"` → `0x1401ee9bd` 의 `[rbx+0x34] = 0x120` 이 순서대로 보인다 |

같은 스윕에서 남은 이탈 1건은 **정정 대상이 아니다**: `0x1400daaac` [VA-데이터표] (유니폼 ID → 인덱스 바이트 표,
§1.1)는 코드가 아니라 `.text` 안에 박힌 **데이터 표**다(바이트가 `00 01 02 03 …`).
`.pdata` 조각 `0x1400da981`–`0x1400dab3c` 안에 들어 있어 도구가 "명령 내부" 로 분류할 뿐
디스어셈 대상이 아니다. **[2026-08-21 갱신]** 전용 마커 `[VA-데이터표]` 가 생겨 그것으로 바꿨다(종전엔 이름과 주석은
"바이트 스캐너가 산출한 disp32·변위 필드 위치" 를 말하고 있어 **이 사례(함수 범위 안에 박힌
데이터 표)와 뜻이 정확히 겹치지는 않는다.** 도구 쪽에 범주를 하나 더 두거나 주석을 넓히는 게
맞다(§7 "넘길 것").

---

## 부록 A. 재현 절차

```bash
S=/tmp/claude-0/-home-user/abe2d757-2792-5050-8baf-0be7e33c5b76/scratchpad

# 1) shake 함수 전문
python3 $S/vdis2.py 0x140199580 0x14019977d

# 2) 카메라 업데이트(9조각 병합 — primary/function_frags 로 확인 후 통짜 디스어셈)
python3 -c "import sys;sys.path.insert(0,'$S');from wpe import function_frags;print(function_frags(0x1401891a0))"
python3 $S/vdis2.py 0x1401891a0 0x140189e08

# 3) 레이어 시차 오프셋
python3 $S/vdis2.py 0x140189e10 0x14018aab9   # 게이트 0x140189f17, 수식 0x14018a0a9

# 4) camerafade
python3 $S/vdis2.py 0x140180c0b 0x140180cc5   # 알파 곡선
python3 $S/vdis2.py 0x140181bab 0x140181be1   # fade.json 로드

# 5) 유니폼 ID → renderState 오프셋 (g_Time / g_ParallaxPosition 확정)
#    인덱스 0x1400daaac[uid] → 오프셋테이블 0x1400da984[idx]*4 → 핸들러 VA   [VA-데이터표] (둘 다 데이터 표)
python3 - <<'PY'
import sys,struct;sys.path.insert(0,"/tmp/claude-0/-home-user/abe2d757-2792-5050-8baf-0be7e33c5b76/scratchpad")
from wpe import pe,DATA
for uid in (0,3,4,5,104,105,107,108):
    ci=DATA[pe.va2off(0x1400daaac+uid)]   # [VA-데이터표] 데이터 표
    off=struct.unpack_from('<I',DATA,pe.va2off(0x1400da984+ci*4))[0]
    print(uid, hex(0x140000000+off))
PY

# 5b) 레이어 perspective — 키→비트, 게이트, 카메라 구성 (§5.7)
python3 $S/vdis2.py 0x1401ee98a 0x1401eea50   # 디스크립터: 이름 등록 뒤의 +0x34/+0x30 이 그 항목의 것
python3 $S/vdis2.py 0x14019c620 0x14019c680   # 핸들러 안의 btr/bts 7 → bit7 확정
python3 $S/vdis2.py 0x1401ed259 0x1401ed280   # 게이트: rs[0x118]&0x400(2D) && obj[0x120]&0x80
python3 $S/vdis2.py 0x140184f00 0x140184ff8   # d = 1/(tan(fov/2)·m11), near 5 / far max(15000,d+1000)
python3 $S/vdis2.py 0x14018767c 0x140187695   # rs[0x118] bit10 ← scene[0xe0] bit3 (정사영)
python3 $S/vdis2.py 0x140183d57 0x140183de1   # rs[0xf8]/rs[0xfc] = 0.5 − 크롭차/(2·크기), rs[0x110] = fovRad

# 5c) 레이어 perspective 도달 (오브젝트 키라 general 스캔으로는 안 잡힌다)
grep -rho '"perspective"[[:space:]]*:[[:space:]]*[a-z]*' --include=*.json \
     /home/user/Waple/Sources/WapleRender/Resources/WEAssets | sort | uniq -c

# 5d) 경로 재생 — 세 팔 · 에르미트 기저 · 접선 · 전진 (§8)
#     반드시 함수 시작에서 선형으로 내려올 것(함정 17). 중간 주소에서 뜨면 기저 조립이 깨져 보인다.
python3 -c "import sys;sys.path.insert(0,'$S');from wpe import merged;print([hex(x) for x in merged(0x1401891a0)[:2]])"
python3 $S/vdis2.py 0x1401891a0 0x140189e08 > /tmp/updcam.asm
sed -n '/0x1401894a9/,/0x1401899d2/p' /tmp/updcam.asm   # 팔 선택 + 에르미트(zoom 성분이 제일 짧다)
sed -n '/0x140189951/,/0x1401899ac/p' /tmp/updcam.asm   # 접선: subss xmm3,xmm0 / subss xmm0,xmm2 = (p−p)
sed -n '/0x140189a74/,/0x140189b07/p' /tmp/updcam.asm   # 전진 · qword 리셋 · 경로 되감기

# 5e) parallaxDepth 기본값 (§8.6) — **.text 선형 스윕은 0건을 준다. .pdata 함수 단위로 떠라.**
python3 $S/vdis2.py 0x1401ddc60 0x1401ddd40    # 레이어 생성자 리터럴: +0x170/+0x174 = 0x3f800000
python3 $S/vdis2.py 0x1401e07f0 0x1401e0870    # 디스크립터: 이름 등록 뒤의 +0x34=0x170 / +0x30=1

# 5f) `scene+0x13c` 를 쓰는 JSON 키가 있는가 (§1.2 부분 해소) — 디스크립터 오프셋 필드 전수
python3 - <<'PY2'
import sys,struct;sys.path.insert(0,"/tmp/claude-0/-home-user/abe2d757-2792-5050-8baf-0be7e33c5b76/scratchpad")
from wpe import pe,DATA,frag_of
for want in (0x13c,0x170,0x334,0x338):
    pat=struct.pack('<I',want); i=0; hits=[]
    while True:
        i=DATA.find(pat,i)
        if i<0: break
        if i>=3 and DATA[i-3]==0xC7 and (DATA[i-2]&0xF8)==0x40 and DATA[i-1]==0x34:
            va=pe.off2va(i-3); f=frag_of(va) if va else None
            if va: hits.append((hex(va), hex(f[0]) if f else '?'))
        i+=1
    print(hex(want), hits)
PY2

# 5g) 경로 코퍼스 전수 (동봉은 0건 — 설치본만 나온다)
python3 - <<'PY3'
import json,glob,os,collections
root='/home/user/Waple-wallpaper-source/wallpaper_engine'
rows=[]
for f in sorted(glob.glob(os.path.join(root,'**','*.json'),recursive=True)):
    try: d=json.load(open(f,encoding='utf-8-sig'))
    except Exception: continue
    if not isinstance(d,dict) or not isinstance(d.get('paths'),list): continue
    for i,p in enumerate(d['paths']):
        if not isinstance(p,dict) or 'transforms' not in p: continue
        ts=[t.get('timestamp') for t in p['transforms']]
        rows.append((os.path.relpath(f,root),i,p.get('duration'),len(ts),ts))
print('paths',len(rows),'transforms',sum(r[3] for r in rows))
print('ts[0]==0 전건?',all(r[4][0]==0 for r in rows))
print(collections.Counter('eq' if r[2]==r[4][-1] else 'gt' for r in rows))
for r in rows:
    if r[2]!=r[4][-1]: print('  duration>ts[last]:',r)
PY3

# 6) 코퍼스 도달 (파일명을 scene.json 으로 좁히지 말 것 — ricepod.json/fantasticcar.json 누락)
python3 - <<'PY'
import json,glob,os,collections
for label,root in [('bundled','/home/user/Waple/Sources/WapleRender/Resources/WEAssets'),
                   ('install','/home/user/Waple-wallpaper-source/wallpaper_engine')]:
    on=[]
    for f in glob.glob(os.path.join(root,'**','*.json'),recursive=True):
        try: d=json.load(open(f,encoding='utf-8-sig'))
        except Exception: continue
        g=d.get('general') if isinstance(d,dict) else None
        if not isinstance(g,dict): continue
        if g.get('camerashake') is True or g.get('cameraparallax') is True:
            on.append(os.path.relpath(f,root))
    print(label,on)
PY
```

## 부록 B. 배제한 가설

| 가설 | 왜 틀렸나 |
|---|---|
| shake 가 펄린/심플렉스 노이즈 | 퍼뮤테이션 테이블 `0x140484f40`/`0x1404833a0` 의 코드 참조 4곳에 shake 함수가 없다. shake 는 `sinf`/`cosf` 3회 호출뿐(§2.4) |
| shake 가 여러 옥타브를 합성 | `sinf`/`cosf` 호출이 정확히 3회(`0x14019960b`·`0x14019961e`·`0x14019962a`). 옥타브 루프 없음 |
| `roughness` 가 주파수 노브 | `phi` 계산에 `roughness` 가 들어가지 않는다. `powf` 지수로만 쓰인다 |
| shake 가 카메라를 회전시킨다 | eye 와 target 에 같은 델타 → 시선 방향 불변. `up`(scene+0x108)은 미접촉 |
| `camerashakespeed` 가 선형 시간 스케일 | `mulss xmm6, xmm6`(`0x1401995f7`)로 제곱된다 |
| parallax 에 자동 드리프트가 있다 | 초점 식(`0x140189bda`–`0x140189c24`)에 시간 항이 없다. `dt` 는 스무딩 α 에만 들어간다 |
| `cameraparallaxdelay` 가 "지연 시간(초)" | `(1 − d/3)·10·dt` 는 **비율**이다. `d=3` 이면 α=0 = 영구 정지 — 지연이라면 3초 뒤 따라와야 한다 |
| parallax 가 레이어 z(깊이)를 민다 | z 성분이 `amount × 0`(`0x14018a0ef`, xmm6 은 `0x140189f3b` 에서 0) |
| parallax 가 3D 씬에서도 레이어를 민다 | 게이트가 `bit8 && bit3`(`0x140189f17`–`0x140189f2c`) — 정사영 전용 |
| `camerafade` 가 씬 시작 페이드인 | 소비 2곳 모두 `scene[0x310] != scene[0x318]`(경로 존재)을 요구한다 |
| `camerafade` 가 검정 페이드 | `fade.frag` 가 `schemecolor × 0.7` 을 쓴다 |
| `camerapreview` 가 런타임 키 | 문자열이 바이너리에 없다(ASCII·UTF-16LE·SSO 임베드 전부 0건) |
| 정사영 씬이 `nearz`/`farz` 를 쓴다 | ±2000 고정. `[rdi+0x14c]` 로드가 보이는 팔은 진입 분기 때문에 도달 불가 |
| `orthogonalprojection.auto` 가 로드 1회 | `Scene::updateCamera` 꼬리(`0x140189d8f`)에서 매 프레임 호출 |
| 레이어 `perspective` 가 3D 씬에서도 동작 | 게이트가 `renderState+0x118` bit10(=정사영) 를 먼저 본다(`0x1401ed259`). 3D 는 `je` 로 빠진다 |
| 레이어 `perspective` 의 화각이 `general.fov` | 2D 씬의 `scene[0x148]` 은 `perspectiveoverridefov` 다(`0x140189278` `cmove`). 그 값이 `rs[0x110]` 을 거쳐 `0x140184f17` 로 들어간다 |
| 레이어 `perspective` 가 z 와 무관한 사다리꼴 왜곡 | 순수 `PerspectiveFov` 교체다. z=0 평면은 정사영과 픽셀 동일이고 왜곡은 전적으로 `s(z)=d/(d−z)` 에서 나온다 |
| shake/parallax 에 난수원이 있다 | `sinf`/`cosf`/`tanf`/`powf`/`sqrtf` 뿐. 노이즈 테이블 참조도 RNG 호출도 없다(§2.4) |
| 시차 스무딩이 프레임률 독립 | α 가 `dt` 에 **선형**이다(`0x140189c43` `mulss xmm4, xmm6`). 지수 보정이 없다 |
| WE 에 자동회전(autorotate) 카메라가 있다 | 동봉 1698 · 설치본 2143 JSON 에 그런 키가 0건이고, `ICamera` 는 `fov`/`zoom` 둘뿐이며, 바이너리가 아는 카메라 키 15개(§6.7)에도 없다(§8.0) |
| 셰이더가 카메라 모션을 `g_Camera*` 유니폼으로 받는다 | `g_Camera` 문자열이 동봉·설치본 자산과 바이너리 통틀어 **0건**이다. 카메라 관련은 `g_EyePosition`·`g_ViewUp`·`g_ViewRight`·`g_ParallaxPosition`·`g_EyeColor` 뿐이다(§8.0) |
| 경로 보간이 선형(lerp)이다 | `u²`·`u³` 를 만들고 네 계수를 조립한다(`0x140189572`–`0x1401895c5`). `u=0.25` 에서 실물 `0.203125` ≠ 선형 `0.25` |
| 경로 보간이 스무스스텝(`3u²−2u³`)이다 | 접선 항 `(h10+h11)·0.5Δ` 가 살아 있어 끝 기울기가 0 이 아니라 0.5 다. `u=0.25` 에서 `0.203125` ≠ `0.15625` |
| 경로 보간이 카트멀-롬(이웃 4점) | 제어점 주소를 만드는 `imul` 이 `idx`·`idx+1` 둘뿐이다. `idx−1`/`idx+2` 를 만드는 명령이 없고, 대신 `p−p` 뺄셈이 명령으로 남아 있다(§8.2) |
| 경로가 저작 `duration` 만큼 재생된다 | 마지막 transform 을 붙드는 팔의 구간 끝이 `duration − ts[last]` 다(`0x1401899da`). 설치본 4경로가 실제로 짧게 끝난다(§8.4) |
| 시차 오프셋에 상한이 있다 | `0x14018a0b3`–`0x14018a115` 에 `minss`/`maxss` 가 없다. clamp01 은 포인터 입력과 `g_ParallaxPosition` 출력에만 있다 |
| `parallaxDepth` 기본값이 0 이다 | 레이어 생성자가 `+0x170`/`+0x174` 에 `0x3f800000`(=1.0)을 쓴다(`0x1401ddce1`/`0x1401ddcec`) |
| 오브젝트 `perspective` 기본값이 true 다 | 생성자 flags 초기값이 `0x2001` — bit7 이 0 이다(§8.6) |
| 카메라 shake 가 CRT `sqrtf` 를 부른다 | 실제 경로는 인라인 `sqrtss`(`0x1401996a1`)다. `sqrtf` 팔은 `0 > L²` 일 때만 가는 도달 불가 분기(§2.5) |
