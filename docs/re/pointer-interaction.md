# 커서/입력 상호작용 — 샘플링 · 유니폼 · 파티클 CP · 레이어 히트테스트 · 스크립트 훅

WE 가 **마우스 하나를 받아 벽지 안에서 무엇을 하는지**를 계층 전체로 복원한 기록이다.
`docs/re/camera-motion.md` 가 이미 확정한 **parallax 초점 모델**과 `g_PointerPosition` 의
renderState 슬롯(`+0x8c`, 유니폼 id 105, y = `1 − pointer.y`, 소비부 clamp01)은 **반복하지 않는다**.
이 문서는 그 위에 **① 값이 어디서 만들어지는가 ② 그 밖의 소비처는 어디인가**를 얹는다.

- 바이너리: `/root/.claude/uploads/.../440072bd-wallpaper64.exe` (imagebase `0x140000000`) ·
  `wallpaper_engine/bin/scenescript64.dll` (imagebase `0x180000000`) · `bin/wallpaperui.exe`(에디터 UI 문자열)
- 코퍼스: 동봉 `Sources/WapleRender/Resources/WEAssets/**` + 설치본 `wallpaper_engine/assets/**` ·
  `projects/defaultprojects/**` · 워크샵 코퍼스 통계 `spec/corpus/scene-schema.json`
- 셰이더 평문: `wallpaper_engine/assets/effects/*/shaders/effects/*`
- 타입 정의 평문: `wallpaper_engine/ui/dist/monaco/autocomplete/lib.sceneScript.d.ts`

---

## 0. 요약 — 이 문서가 확정한 것

| # | 결론 | 등급 |
|---|---|---|
| 1 | `g_PointerPosition` 은 **클라이언트 픽셀 ÷ 표면 픽셀**이다 — 소스에 **클램프가 없다**. 초기값 `(0,0)`, 창 밖이면 `[0,1]` 을 벗어난 값이 그대로 들어간다 | 확정 |
| 2 | `g_PointerState` 는 renderState `+0xa4` 의 **비트 2개**에서 합성된다. `.x/.y` = 버튼 누름 유지, **`.z` 는 누른 첫 프레임에만 1.0**(클릭 임펄스), `.w` 는 항상 0 | 확정 |
| 3 | 그 "첫 프레임" 은 렌더러 프레임 꼬리 `0x140181623`–`0x14018162d` 의 `if (s & 1) s := s or 2` 가 만든다. `g_PointerPositionLast` 도 같은 자리에서 이월된다 | 확정 |
| 4 | 좌버튼은 **커서가 데스크톱(또는 자기 벽지 창) 위에 있을 때만** 눌린 것으로 친다 — 다른 앱 창 위 클릭은 무시. 판정은 `WindowFromPoint` + 클래스명/윈도우 프롭 검사(`0x14010d9b0`) | 확정 |
| 5 | 커서 반응 셰이더는 동봉에 **3종**뿐이다 — `cursorripple` · `fluidsimulation` · **`xray`**(`shader-uniforms.md` §4 는 앞 둘만 적었다) | 확정 · 정정 |
| 6 | 파티클 컨트롤포인트 `flags` **bit0** = 마우스 구동. 매 프레임 **CP 의 평행이동 행만** 커서 언프로젝트 좌표로 교체된다(회전은 저작 행렬에서 복사) | 확정 |
| 7 | 그 언프로젝션은 **NDC z = 0** 평면이고, 2D(정사영) 씬은 `(X, Y, 0)`, 3D 씬은 추가로 씬 행렬 역변환을 한 번 더 통과한다 | 확정 |
| 8 | 커서에 반응하는 파티클 요소는 **`controlpointattract` 하나**다. 동봉 22건 전건이 그것이고, 그중 20건이 `scale < 0`(밀침) | 확정 |
| 9 | `controlpoint[].locktopointer` 는 **어느 바이너리에도 문자열이 없다** — 에디터 표기용 잔재 (`bundled-key-coverage.md` §11 재확인) | 확정(재확인) |
| 10 | 레이어 히트테스트는 존재한다. 게이트는 `solid` = 오브젝트 플래그워드 `[obj+0x120]` **bit13**, 전파 차단은 `disablepropagation` = **bit14** | 확정 · 신규 |
| 11 | 판정은 **알파 임계가 아니다** — 오브젝트 변환을 먹인 **쿼드(±size/2)** 와 커서 광선의 교차다. 회전을 존중한다 | 확정 |
| 12 | 히트테스트는 레이어 시차 오프셋 `(origin − focus)·amount·parallaxDepth` 를 **똑같이 적용**하고 나서 판정한다 — 클릭이 그려진 자리에 맞는다 | 확정 |
| 13 | `config.fullscreen` 모델(`[obj+0x304]` bit1)은 히트테스트를 **건너뛰고 항상 맞는다**. 그때 커서 월드좌표는 `pointer × 표면크기` | 확정 |
| 14 | 씬스크립트 훅 테이블은 **19개**이고, `lib.sceneScript.d.ts` 에 없는 **`cursorHitTest`(idx 7)** 와 `animationEvent`(idx 6)가 들어 있다 | 확정 · 신규 |
| 15 | **`cursorHitTest` 는 exe 어디에서도 발화되지 않는다** — 등록만 된 죽은 훅 | 확정 · 신규 |
| 16 | 커서 훅은 **히트한 오브젝트에 바인딩된 스크립트**(또는 `[inst+8] == 0` 인 스크립트)에만 간다. 전 스크립트 브로드캐스트가 아니다 | 확정 |
| 17 | WE 는 **`WH_MOUSE_LL` 전역 저수준 마우스 훅**(`SetWindowsHookExW(14, …)` @ `0x140126902`)을 설치해 데스크톱 클릭을 최대 16개 벽지 창에 `PostMessageW(WM_LBUTTONUP)` 로 되쏜다 | 확정 |
| 18 | `disablepropagation` 의 실물 의미는 **커서 히트 전파 차단**이지 부모 트랜스폼 상속 차단이 아니다 — Waple 이 다른 뜻으로 쓰고 있다(§7 W-4) | 확정 · 미해소 |

확정 못 한 것은 §9 에 모아 뒀다.

---

## 1. 커서 원천 — OS 샘플링과 renderState 필드

### 1.1 샘플러 `0x140110630` – `0x140113bb0`

7개 `.pdata` 조각이 한 함수다(`primary()` 로 병합). 앱 틱 함수이고 커서 외에 `g_Daytime` 도
여기서 만든다(`GetLocalTime` → 1/24·1/1440·1/86400·1/86400000 가중합 → `renderer+0x150`,
`0x140111526`–`0x14011159c`). 커서 부분만 옮기면:

```
GetCursorPos(&pt)                                        ; 0x1401115a8
GetKeyState(VK_LBUTTON)                                  ; 0x1401115b1   (ecx=r14d=1 @0x1401112d2)
r8 = renderer                                            ; [r15+0x180]
cl = renderer[0xb4] & 1                                  ; 직전 프레임 버튼 상태
if (GetKeyState >> 8) & 1 {                              ; 지금 눌려 있다
    if (!cl) {                                           ; 방금 눌렸다
        h = WindowFromPoint(pt)                          ; 0x1401115d8
        if (isDesktopSurface(h) || h == ourHWND)         ; 0x1401115e4 / 0x1401115ed
            setButton(renderer, true)                    ; 0x14010dab0
    }
} else if (cl) setButton(renderer, false)                ; 0x14011160a

if (ScreenToClient(ourHWND, &pt)) {                      ; 0x14011161a
    v = float2(pt.x, pt.y)                               ; 0x140109f60
    v /= renderer[0x84]                                  ; = 표면 크기(px, float2)   0x14011163b
    renderer[0x9c] = v                                   ; = renderState+0x8c = g_PointerPosition
}                                                        ; 0x14011164b
```

- **클램프가 없다.** `divps` 결과를 그대로 `movsd` 로 쓴다. 멀티모니터에서 커서가 이 벽지 창
  밖에 있으면 `ScreenToClient` 가 음수/초과 좌표를 주고 그것이 유니폼에 그대로 실린다.
- **좌표계는 Win32 클라이언트 좌표** — 원점 좌상단, **y 아래로 증가**. 그래서 커서 반응
  셰이더가 전부 `pointer.y = 1.0 - pointer.y` 로 뒤집는다(§2).
- **갱신 주기는 프레임 1회.** 이 함수가 앱 틱이다.

### 1.2 renderState 포인터 필드 맵

`renderState = renderer + 0x10`(camera-motion §1.1). 생성자 `0x14017c6d0` 이 초기값을 심는다.

| renderState | renderer | 정체 | 초기값 | 근거 |
|---|---|---|---|---|
| `+0x74` / `+0x78` | `+0x84` / `+0x88` | 표면 크기(px, float2) | `1.0` / `1.0` | `0x14017c76f` 초기화 · `0x14011163b` 나눗셈 · `0x14019dbdb` 되곱셈 |
| `+0x8c` | `+0x9c` | **`g_PointerPosition`**(0..1, y-down) | `(0,0)` | `0x14017c77d` · 쓰기 `0x14011164b` · 유니폼 핸들러 `0x1400d9df8` |
| `+0x94` | `+0xa4` | **`g_PointerPositionLast`** | `(0,0)` | `0x14017c784` · 이월 `0x140181615`–`0x14018161c` · 핸들러 `0x1400d9e12` |
| `+0x9c` | `+0xac` | `g_ParallaxPosition` | `(0,0)` | camera-motion §3 |
| `+0xa4` | `+0xb4` | **포인터 상태 비트워드** | `0` | `0x14017c792` · 쓰기 `0x14010dab0` / `0x14018169e` |
| `+0x1838` | `+0x1848` | 커서 상호작용 마스터 게이트(byte) | `[미해결]` | 읽기 `0x140189e31` · `0x1401802af` |

### 1.3 `g_PointerState`(유니폼 id 106) 합성 — 핸들러 `0x1400d9e2c` – `0x1400d9e8b`

`shader-uniforms.md` §2 표는 이 유니폼을 "`float4(0,0,클릭힘,0)`" 이라고만 적었다. 실물은
renderState `+0xa4` 의 **두 비트**에서 만든다(`xmm14 = 1.0f`, `0x1400d8343` 에서 적재):

```
uint s = rs[0xa4];
out.x = out.y = (s & 1) ? 1.0 : 0.0;          ; 0x1400d9e36 – 0x1400d9e4e
out.z = ((s & 1) && !(s & 2)) ? 1.0 : 0.0;    ; 0x1400d9e59 – 0x1400d9e6f
out.w = 0;                                    ; 0x1400d9e67 / 0x1400d9e7d
```

- **bit0 = 좌버튼 눌림 유지.** 샘플러 `0x14010dab0` 이 세우고 지운다.
- **bit1 = "이미 처리했다".** 렌더러 프레임 함수 `0x14017fa70` 꼬리가 매 프레임 갱신한다:

```
0x140181615  rs.pointerLast = rs.pointer          ; g_PointerPositionLast 이월
0x140181623  eax = rs[0xa4]
0x140181629  if (eax & 1) eax |= 2                ; 0x14018162d
0x14018164f  else         eax &= ~2
0x14018169e  rs[0xa4] = eax
```

따라서 **`.z` 는 버튼이 눌린 첫 프레임에만 1.0** 이고 그 뒤로는 0 이다 — 셰이더가 이걸
"클릭 임펄스"로 쓴다(`cursorripple` 은 `g_PointerState.z * 5.0` 로 한 프레임 큰 힘을 준다).
`.x/.y` 는 누르고 있는 동안 계속 1.0 이지만 **동봉 셰이더 중 `.x/.y` 를 읽는 것은 없다**.

> `.w` 가 0 인 것과 `.x/.y` 가 같은 값인 것은 실물 코드 그대로다. "버튼 4개"가 아니다.

### 1.4 `g_PointerPosition` 소비처 전수(exe 내부)

renderState `+0x8c` 를 읽는 지점은 exe 전체에서 네 곳뿐이다(`.pdata` 전 함수 선형 스윕).

| 소비처 | VA | 하는 일 | 문서 |
|---|---|---|---|
| 유니폼 핸들러 105 | `0x1400d9df8` | 셰이더로 그대로 전달(qword 복사 = 2 float) | shader-uniforms §2 |
| 카메라 parallax 초점 | `0x140189b8d` | `clamp01` 후 초점 보간 | **camera-motion §3** |
| 파티클 CP 마우스 구동 | `0x14022e4ba` | 언프로젝트 → CP 평행이동 교체 | **§3** |
| 레이어 히트테스트 | `0x14019dbd3` | `fullscreen` 지름길에서 `× 표면크기` | **§4.4** |

---

## 2. 셰이더 유니폼 — 평문 소비처

### 2.1 `cursorripple`

`assets/effects/cursorripple/shaders/effects/cursorripple_apply_force.vert`:

```glsl
uniform vec2 g_PointerPosition;
uniform vec2 g_PointerPositionLast;
...
vec2 pointer = g_PointerPosition;
pointer.y = 1.0 - pointer.y; // Flip pointer screen space Y to match texture space Y
vec2 pointerLast = g_PointerPositionLast;
pointerLast.y = 1.0 - pointerLast.y;
...
v_PointerUV.xyz = mul(vec4(pointer * 2 - 1, 0.0, 1.0), g_EffectTextureProjectionMatrixInverse).xyw;
v_PointerUV.xy *= 0.5;  v_PointerUV.xy /= v_PointerUV.z;
...
v_PointDelta.x = length(g_PointerPosition - g_PointerPositionLast);
v_PointDelta.x *= 100;
v_PointDelta.y = 60.0 / max(0.0001, g_RippleScale);
```

`…_apply_force.frag`:

```glsl
uniform vec4 g_PointerState;
...
float timeAmt = min(1.0 / 30.0, g_Frametime) / 0.02;
float pointerMoveAmt = v_PointDelta.x;
float inputStrength = pointerDist * timeAmt * (pointerMoveAmt + g_PointerState.z * 5.0);
```

**이 유니폼 셋의 규약이 셰이더 평문에 그대로 적혀 있다** — `y` 뒤집기, `*2-1` NDC 변환,
`g_EffectTextureProjectionMatrixInverse` 로 이펙트 쿼드 로컬 UV 로 되돌리기, 직전 프레임과의
선분(`posOnLine`)에 대한 거리로 힘을 주기. 프레임 사이를 **선분으로 보간**하기 때문에 커서를
빠르게 움직여도 물결이 끊기지 않는다.

### 2.2 `fluidsimulation`

`fluidsimulation_vorticity.vert:48-84` 가 같은 패턴을 쓰되 게인이 다르다:

```glsl
float moveAmt = length(g_PointerPosition - g_PointerPositionLast);
v_PointDelta.x = step(0, moveAmt) * 0.5 + moveAmt * 10.0 * u_CursorInfluence;
v_PointDelta.y = 60.0 / max(0.0001, u_CursorInfluence);
```

`u_CursorInfluence` 는 머티리얼 파라미터다:
`// {"material":"cursorinfluence","label":"ui_editor_properties_cursor_influence","default":1.0,"range":[0.0, 2.0],"group":"ui_editor_properties_simulation"}`.
`…_vorticity.frag:198` 은 `inputStrength = pointerDist * 1.0 * (pointerMoveAmt + g_PointerState.z)`
로 클릭 게인이 `cursorripple`(×5)보다 작다. `step(0, moveAmt) * 0.5` 때문에 **커서가 멈춰 있어도
상시 0.5 의 기저 힘**이 있다 — `cursorripple` 에는 없는 성질이다.

### 2.3 `xray` — `shader-uniforms.md` 가 빠뜨린 세 번째 소비처

`assets/effects/xray/shaders/effects/xray.vert`:

```glsl
uniform vec2 g_PointerPosition;
uniform float g_PointerScale; // {"material":"size","label":"ui_editor_properties_size","default":0.2,"range":[0.0, 1.0]}
...
vec2 pointer = g_PointerPosition;
pointer.y = 1.0 - pointer.y;
v_PointerUV.xyz = mul(vec4(pointer * 2 - 1, 0.0, 1.0), g_EffectTextureProjectionMatrixInverse).xyw;
v_PointerScale = mix(999, 1.0 / g_PointerScale, step(0.001, g_PointerScale));
```

`ui_en-us.json`: `ui_editor_effect_xray_description = "Blends between two images based on cursor position."`
커서 위치에 `g_Texture2`(기본 `particle/halo_6`) 스프라이트를 그려 두 텍스처를 블렌딩한다.
`g_PointerPositionLast`/`g_PointerState` 는 쓰지 않는다 — **위치만** 쓴다.

> 프리뷰 변형은 다른 셰이더다. `xray/preview/…/xray.vert:36` 은 `g_EffectTextureProjectionMatrixInverse`
> 대신 `g_ModelViewProjectionMatrixInverse` 를 쓰고, `g_PointerScale` 선언이 `.frag` 로 옮겨 가 있으며
> 머티리얼 키도 `size` 가 아니라 `ui_editor_particle_element_exponent`(기본 5, range `[0.01,20]`)다.
> `shader-uniforms.md:428` 의 `g_PointerScale` 행은 그 **프리뷰 쪽 키**를 적은 것이다.

### 2.4 동봉 도달 실측

동봉(`Sources/WapleRender/Resources/WEAssets`)과 설치본 `assets/` 는 같은 트리라 수치가 같다.

| 유니폼 | 파일 수 | non-preview | preview | 파일 |
|---|---:|---:|---:|---|
| `g_PointerPosition` | **6** | 3 | 3 | `cursorripple_apply_force.vert` · `fluidsimulation_vorticity.vert` · `xray.vert` (각 ×2) |
| `g_PointerPositionLast` | **4** | 2 | 2 | `cursorripple` · `fluidsimulation` (각 ×2) |
| `g_PointerState` | **4** | 2 | 2 | `cursorripple_apply_force.frag` · `fluidsimulation_vorticity.frag` (각 ×2) |
| `g_PointerScale` | **2** | 1 | 1 | `xray.vert`(non-preview) · `xray/preview/xray.frag` |
| `g_ParallaxPosition` | 4 | 2 | 2 | `depthparallax` — camera-motion §3 |

설치본 전체(`.exe`/`.dll`/에디터 JS 포함) 기준으로는 `g_PointerPosition` 13파일 ·
`g_PointerPositionLast` 11 · `g_PointerState` 10 인데, 셰이더가 아닌 것은
`wallpaper32/64.exe` · `distribution/*` · `bin/wallpaperui.exe` · `ui/dist/scripts/scripts.js`(에디터
자동완성 목록)뿐이다.

머티리얼 키 도달: `cursorinfluence` 는 **3건**(`fluidsimulation_vorticity.vert` ×2 선언 +
`fluidsimulation/preview/scene.json:74` 에서 `"cursorinfluence": 4` 로 1건 오버라이드).

---

## 3. 파티클 상호작용 — 컨트롤포인트 `flags` bit0

`scene-object-model.md` §12 가 CP `flags` bit0 = 마우스 구동이라고 적어 뒀다. 그 경로를 끝까지 따라간다.

### 3.1 CP 구조체와 드라이버 `0x14022e3e0` – `0x14022ebde`

3개 조각이 한 함수다. `(rcx = 파티클 시스템)`.

```
sys[0x400] = CP 배열 베이스, stride 0xd0
sys[0x44]  = CP 개수
sys[0x20]  bit0 = 이 시스템이 정사영(2D) 씬 소속
sys[0x10]  = 부모 시스템
```

CP 구조체(stride `0xd0`):

| 오프셋 | 정체 | 근거 |
|---|---|---|
| `+0x00`..`+0x3f` | **런타임 4×4**(평행이동 = `+0x30`..`+0x38`) | `0x14022e656`–`0x14022e662` 가 여기 쓴다 |
| `+0x40`..`+0x7f` | 직전 프레임 4×4 스냅샷 | `0x14022f250`–`0x14022f284` 가 드라이버 호출 직후 복사 |
| `+0x80`..`+0xbf` | 저작 4×4(`offset`/`angles` 로 만든 것) | `0x14022e47b`–`0x14022e4ae` 가 여기서 복사해 온다 |
| `+0xc0` | **`flags`** | `0x14022e461` |
| `+0xc4` | `parentcontrolpoint` | `0x14022e684` |

디스패치(`edx = flags`):

```
0x14022e468  bt edx, 0x10   → bit16 이면 이 CP 는 통째로 건너뛴다(remap 출력 대상)
0x14022e472  test dl, 1     → bit0  마우스 구동   (§3.2)
0x14022e66e  test dl, 4     → bit2  부모 시스템 CP 부착
0x14022e6b3  test dl, 8     → bit3  bit2 의 하위 수정자(부모 행렬 통째 복사)
0x14022eb35  그 외          → CP 애니메이션 기본 갱신 0x14022a070
```

### 3.2 마우스 구동 경로 `0x14022e47b` – `0x14022e669`

```
CP[0x00..0x3f] ← CP[0x80..0xbf]                 ; 회전/스케일은 저작 행렬 그대로   0x14022e47b–0x14022e4ae
rs   = sys[0]                                    ; renderState
ndc.x = 2*rs[0x8c] − 1                           ; 0x14022e4ba, 0x14022e514, 0x14022e535
ndc.y = 2*(1 − rs[0x90]) − 1                     ; 0x14022e4c3, 0x14022e51f, 0x14022e53f
M     = inverse( proj · view )                   ; 0x14005ecb0(합성) → 0x14005f730(역행렬)
p     = M · vec4(ndc.x, ndc.y, 0, 1)             ; **z = 0 평면**
p.xy /= p.w                                      ; 0x14022e597 / 0x14022e59c
if (sys[0x20] & 1) {                             ; 2D(정사영) 씬
    world = (p.x, p.y, 0)                        ; 0x14022e64a–0x14022e652
} else {                                         ; 3D 씬
    N = inverse(rs[0x30])                        ; 0x14022e5af – 0x14022e5b3
    world = N · vec4(p.x, p.y, 0, 1)             ; 아핀(w 나눗셈 없음)  0x14022e5b8–0x14022e643
}
CP[0x30..0x38] = world                           ; 0x14022e656–0x14022e662
```

**평행이동 행만 바뀐다.** CP 의 각도(저작 `angles`)는 매 프레임 저작 행렬에서 다시 복사되므로
마우스가 CP 를 회전시키지는 않는다. `y` 뒤집기는 여기서도 셰이더와 같다.

### 3.3 JSON 키 · 기본값 · 파서 VA

| 키 | 위치 | 타입 | 기본 | 파서 VA | 소비 VA |
|---|---|---|---|---|---|
| `controlpoint[].flags` | 파티클 시스템 루트 | uint | **0** | `0x1401d0561` → uint 주입기 `0x1401d8280`, 슬롯 쓰기 `0x1401d05ae` | `0x14022e461` |
| `controlpoint[].offset` | 〃 | vec3 | `0 0 0` | `0x1401d0552` | 저작 행렬 |
| `controlpoint[].angles` | 〃 | vec3 | `0 0 0` | `0x1401d06ce` | 저작 행렬 |
| `controlpoint[].parentcontrolpoint` | 〃 | uint | 0 | `0x1401d0573` | `0x14022e684`(bit2 일 때만) |
| `controlpoint[].locktopointer` | 〃 | — | — | **없음** | **없음** |
| `operator[].controlpoint` | `controlpointattract` 등 | int | 0 | `0x1401ccc65` → `0x1401ccd01` | CP 인덱스 클램프 `>=7u → 7` |

슬롯은 `id` 가 아니라 **배열 위치**다(고정 8회 루프 `0x1401d0807`–`0x1401d080a`, 슬롯 주소
`shl rdi,5` + `[rdi + r13 + 0xa4]`). `Sources/WapleCore/ParticleSystem.swift` 의 `parseSystem` CP 루프
(`var controlPointFlags = Array(…)` 이하, 이번 라운드 기준 `:2596-2600`)가 이미 이 규약을 문서화·구현해 뒀다.

파서는 `flags` 에 **bit16 을 스스로 얹기도 한다** — `0x1401d086c`
`or dword [rcx + r13 + 0xa4], 0x10000`. 즉 bit16(엔진 갱신 스킵)은 저작 값이 아니라
파스 중 유도되는 비트다.

### 3.4 커서에 반응하는 요소 — 전수

동봉+설치본 코퍼스를 통째로 스캔해 **"bit0 CP 를 실제로 참조하는 이니셜라이저/오퍼레이터"** 를
셌다(`controlpoint` / `inputcontrolpoint0` / `inputcontrolpoint1` / `controlpointstart` /
`controlpointend` 전 키 대상).

| 요소 | bit0 CP 참조 건수 | 비고 |
|---|---:|---|
| **`controlpointattract`** | **22** | 전건. `scale > 0` = 끌림 2건, `scale < 0` = 밀침 20건. (동봉 `controlpointattract` **전체**는 34건 — `"controlpointattract"` 문자열 실측, `ParticleSystem.swift` 의 `case controlPointAttract` 주석과 일치. 그중 22건이 마우스 CP 를 본다) |
| 그 외 (`vortex` · `maintaindistancetocontrolpoint` · `reducemovementnearcontrolpoint` · `mapsequence*` · `remapvalue` · `inheritcontrolpointvelocity` · 충돌체) | **0** | 동봉 도달 0. 코드상 막혀 있지는 않다 |

즉 **커서 반응 파티클 = `controlpointattract` + 마우스 CP** 조합 하나다. 난류(`turbulence`)를
커서로 트리거하는 경로는 코퍼스에도 코드 게이트에도 없다 — `exampleturbolence.json` 은
난류와 `controlpointattract` 를 **나란히** 놓았을 뿐 서로 엮여 있지 않다.

`controlpointattract` 의 커서 관련 키(주입 기본값은 `ParticleSystem.swift` 의 `case controlPointAttract` 주석이 이미 확정):

| 키 | 기본 | 의미 |
|---|---|---|
| `controlpoint` | 0 | 대상 CP. bit0 이면 커서 |
| `scale` | — | 가속 크기. **음수 = 밀침** |
| `threshold` | ortho 15.0 / 원근 0.5 | 반응 반경 |
| `flags` | 2 | bit0 = 근접 입자 삭제(`0x14024193d`) · bit1 = 오버슛 클램프(`0x140241750`). **이미 측정돼 있다** — `ParticleSystem.swift` 의 `case controlPointAttract` 주석(`:342-350`). 에디터도 같은 짝을 보여 준다(`ui_editor_properties_delete_particles_in_center` + `checkBit(findProperty('flags').value, 1)`, `bin/wallpaperui.exe` 프로퍼티 풀) |

### 3.5 동봉 도달 실측 — 마우스 CP

동봉/설치본 `assets/` 는 동일 트리. **28파일 · 28원소**가 `flags & 1` 인 CP 를 갖는다
(preview 12 / non-preview 16).

| 쓰임 | 파일 수 | 파일 |
|---|---:|---|
| CP0 bit0 만(오퍼레이터 없음) — 방출 원점이 커서를 따라감 | 3 | `particles/examplecursorfollow.json` · `presets/interactive/particles/presets/trail_1.json` · 그 preview |
| CPn(n≥1) bit0 + `controlpointattract` | 22 | `examplecursoravoid` · `exampleturbolence` · `bubbles1` · `fireflies` · `trail_0` · `trail_2` · `dust_motes_0` · `magic_vortex_orb` · `powerup` · `vapor0` · `vapor1` · `vapor1_child` · `scenes/particleelementpreviews/layerimage/…` (+ preview 사본) |
| bit0 인데 **참조하는 요소가 없다**(무동작) | 3 | `presets/abstract/…/dna.json`(CP2) · 그 preview · `presets/magic/previewvortexorb/…/magic_vortex_orb.json`(CP2) |

`scale` 값 분포(22건): `-10000` · `-5000` · `-2048` · `-1024`×2 · `-750` · `-650` · `-550` ·
`-512`×3 · `-500`×2 · `-350`×2 · `-300`×2 · `1024`×2 … 대부분 **밀침**이다. WE 자신의 프리셋 이름도
`ui_editor_particle_example_cursor_avoid = "Avoid cursor"` / `ui_editor_preset_interactive_description
= "Interactive particles that are affected by the cursor."` 다.

`locktopointer` 는 **자산 2건**(`particles/exampleturbolence.json`,
`particles/exampleturbolence3d.json`)에만 있고 두 파일 모두 같은 CP 에 `flags: 1` 을 **함께** 적어
뒀다. 런타임은 `flags` 만 읽는다 — `bundled-key-coverage.md:320` 과 같은 결론이다.

---

## 4. 레이어 히트테스트

### 4.1 오브젝트 플래그워드 `[obj+0x120]` 의 비트

`scene-object-model.md:251` 은 `+0x120` 을 "플래그 워드(bit0=`visible`)" 까지만 적어 뒀다.
등록부 `0x1401e0530`–`0x1401e1389` 의 접근자 썽크를 읽어 비트를 확정했다:

| 키 | 비트 | 접근자 VA | 비트 조작 VA | 등록 VA |
|---|---:|---|---|---|
| `visible` | 0 | `0x1401e1c90` | `and cl, 1` | — |
| `perspective` | **7** | `0x14019c620` | `btr/bts …, 7` @ `0x14019c655` / `0x14019c659` | `0x1401ee9b5`(이미지) |
| `solid` | **13** | `0x14019c3f0` | `btr/bts …, 0xd` @ `0x14019c425` / `0x14019c429` | `0x1401e1283` |
| `disablepropagation` | **14** | `0x14019bb40` | `btr/bts …, 0xe` @ `0x14019bb75` / `0x14019bb79` | `0x1401e132b` |

스크립트 게터도 같은 비트를 본다 — `solid` → `test dword [rcx], 0x2000` @ `0x14019c4ca`,
`disablepropagation` → `test dword [rcx], 0x4000` @ `0x14019bc1a`.

에디터 라벨(`bin/wallpaperui.exe` 프로퍼티 디스크립터 문자열 풀):
`ui_editor_properties_enable_click_events` → `solid`,
`ui_editor_properties_disable_click_propagation` → `disablepropagation`.
`ui_en-us.json` 이 그 둘을 "Enable click events" / "Disable click propagation" 로 번역한다.

### 4.2 프레임 워크 `0x140189e10` – `0x14018aab9`

9조각이 한 함수다. 호출은 렌더러 프레임 함수 `0x14017fa70` 에서 **프레임당 1회**,
`renderer[0x1848]`(= renderState `+0x1838`) 게이트가 열려 있을 때만 한다(`0x1401802af`–`0x1401802d5`).
인자는 `rcx = scene`.

```
rs = scene[0xd8]                                 ; renderState
if (!rs[0x1838]) return                          ; 0x140189e31
① 커서 → 월드 광선 2벌 준비                      ; vtbl+0xb0 / vtbl+0x40  (정사영용·원근용)
② 커서 스크린좌표 vtbl+0xa8 → [rbp-0x60]
③ moved = (커서좌표 != scene[0x300..0x304])       ; 0x140189e9f – 0x140189ec3
   scene[0x300..0x304] = 커서좌표                  ; 0x140189ee4
④ down = rs[0xa4] & 1  ·  prevDown = scene[0x308] ; 0x140189ef4 / 0x140189ed7
⑤ parallaxOn = scene[0xe0] bit8 && bit3           ; 0x140189f17 – 0x140189f2c  (= camera-motion 의 게이트)
⑥ 오브젝트 목록 선택
     3D(bit3=0): scene[0x268] 에 정렬본을 만든다   ; 0x140189fb0 / 0x140189fc6
     2D(bit3=1): scene[0x158] 원본 그대로          ; 0x140189fd4
⑦ 목록을 **뒤에서 앞으로**(= 앞면부터) 훑는다      ; 0x14018a024 – 0x14018a40b
     if (!(obj[0x120] & 0x2000)) continue         ; solid 아니면 스킵  0x14018a02d
     kind = obj->vtbl[0x60]()                     ; 1·4 → 쿼드 히트테스트, 5 → 0x140185520
     if (obj[0x120] & 0x80) 원근 광선 사용         ; perspective 비트  0x14018a076
     if (parallaxOn) 시차 오프셋 계산              ; 0x14018a0b3 – 0x14018a115
     hit = 0x14019dbb0(...) || 0x140185520(...)   ; 0x14018a242 / 0x14018a265
     hitBox = obj->vtbl[0x88](...)                ; std::string 반환 — CursorEvent.hitBox
     …이벤트 발화(§5.2)…
     if (!(obj[0x120] & 0x4000)) continue         ; disablepropagation 아니면 다음 오브젝트  0x14018a877
     if (!(obj[0x120] & 1))      continue         ; 안 보이면 전파를 막지 않는다               0x14018a87e
     p = obj[0x180]                               ; 0x14018a882
     if (!p || (p[0x120] & 1)) break              ; **루프 탈출** — 뒤 레이어로 안 넘어간다     0x14018a88c / 0x14018a899
⑧ scene[0x308] = down                             ; 0x14018a44f
```

호버 상태는 오브젝트 포인터의 **FNV-1a 64** 해시(`0x14018a122`–`0x14018a1bf`,
basis `0xcbf29ce484222325` · prime `0x100000001b3`)로 두 개의 해시맵을 친다 —
"지금 호버 중" (`scene[0x2d8]`/mask `scene[0x2f0]`)과 "누른 채로 잡고 있는"
(`scene[0x298]`/mask `scene[0x2b0]`).

**시차 보정.** ⑤ 가 켜지면 오브젝트 origin(`[obj+0x128]`)에서 씬 초점(`scene[0x340]`)을 빼고
`scene[0x334]`(amount)를 곱한 뒤 `[obj+0x170]`(parallaxDepth)를 다시 곱해
(`0x14018a0c3`–`0x14018a115`) 커서 광선 원점에 더한다(`0x14019dd79`). camera-motion §3 이 확정한
레이어 오프셋 식과 **같은 식**이다 — 그래서 시차로 밀린 레이어도 눈에 보이는 자리에서 클릭된다.

### 4.3 실제 판정 `0x14019dbb0` – `0x14019df86` — **쿼드**다

```
if (obj[0x304] & 2) {                     ; config.fullscreen  → §4.4
    out = (rs[0x8c] * rs[0x74], rs[0x90] * rs[0x78], 0);
    return true;                          ; 0x14019dbc1 – 0x14019dc11
}
M   = obj->vtbl[0x80]()                   ; 오브젝트 4×4(scene-object-model §4.4)
sz  = obj[0x2f0]                          ; (width, height)
c0..c3 = M.axisX * (±0.5*sz.x) + M.axisY * (±0.5*sz.y) + M.origin + parallaxOffset
hit = 0x14019d5a0(rayOrigin, rayDir, c0, c1, c2, c3, &t)
return t >= 0;                            ; 0x14019deef – 0x14019df2d
```

`±0.5` 상수는 `0x140493000`(-0.5 ×4)와 `0x140492dd0`(+0.5 ×4)에서 온다.

- **알파 임계가 없다.** 텍스처를 한 번도 샘플링하지 않는다.
- **바운딩 박스도 아니다** — 오브젝트 4×4 를 그대로 먹인 **회전/스케일된 쿼드**다.
- 모델/퍼펫(kind 5)은 별도 함수 `0x140185520`–`0x14018593c` 를 타고, 그 결과의 뼈 이름이
  `CursorEvent.hitBox` 로 실린다(`vtbl+0x88` 이 `std::string` 을 채운다 — SSO 판정 `0x14018a2cc`).

### 4.4 `config.fullscreen` 지름길

모델 루트 파서 `0x1401fac50` 이 `fullscreen` 키를 읽어(`lea rdx, [rip…] "fullscreen"` @ `0x1401fadf6`)
`[model+0x304] |= 2`(`0x1401fae1e`)와 `[model+0x120] |= 0x200`(`0x1401fae25`)을 세운다. 그 bit1 이
서면 히트테스트는 **기하를 보지 않고 항상 참**을 돌려주고, 커서 월드좌표를
`pointer × 표면크기` 로 준다. 동봉 도달은 `models/util/fullscreenlayer.json` 1건이다
(설치본은 `projects/defaultprojects/neon_sunset/models/cloudsbg.json` 이 추가).

### 4.5 동봉 도달 실측 — `solid` / `disablepropagation`

| 대상 | `solid` | `disablepropagation` |
|---|---|---|
| 동봉 `assets/` | 16파일 / 18오브젝트 **true**(preview 14 · non-preview 2 — `presets/clock/preset.json`, `presets/countdown/preset.json`) | **0** |
| 설치본 `projects/defaultprojects/` | 3파일 / 22오브젝트 true (`razer_vortex` · `razer_bedroom` · `shimmering_particles`) | **0** |
| 워크샵 코퍼스(`spec/corpus/scene-schema.json`, 씬 162종) | image 149건(true 139) / 26씬 · text 52건(true 35) / 12씬 | image 2097건 중 **true 34** / 63씬 |

즉 `disablepropagation: true` 는 **동봉에는 아예 없고 워크샵 코퍼스에만 34건** 있다.

---

## 5. 씬 스크립트 입력 API

`scene-script-api.md` §4 는 `IInput` 3프로퍼티의 등록 VA 까지 적어 뒀다. 여기서는 **훅 쪽**을 보완한다.

### 5.1 훅 테이블 — 19개(문서엔 17개)

`scenescript64.dll` 의 이름 포인터 테이블 `0x1819a3ee0` (19엔트리, 뒤이어 콜백 테이블 `0x1819a3f78`).
소비자 `0x18164bfa0`–`0x18164e041` 이 `cmp r14, 0x13`(`0x18164c65e`)로 **19회** 돌며 각 이름을
JS 모듈에서 찾고(`0x18164c5c7`), 있으면 영속 핸들을 `[obj + idx*8 + 0x40]` 에 캐시하고
`[obj+0xd8] |= (1 << idx)`(`0x18164c64a`, `rol r15d, 1` @ `0x18164c651`)로 **비트마스크**를 세운다.

| idx | 이름 | 문자열 VA | `d.ts` | exe 발화 |
|---:|---|---|---|---|
| 0 | `init` | `0x1819a3904` | ✓ | ✓ |
| 1 | `update` | `0x1819a390c` | ✓ | ✓ (`0x14017275e` r9d=1) |
| 2 | `resizeScreen` | `0x1819a3918` | ✓ | ✓ (`0x14017f760` mask 4) |
| 3 | `destroy` | `0x1819a3928` | ✓ | ✓ |
| 4 | `applyUserProperties` | `0x1819a3930` | ✓ | ✓ |
| 5 | `applyGeneralSettings` | `0x1819a3948` | ✓ | ✓ |
| 6 | `animationEvent` | `0x1819a3960` | **없음** | ✓ (`0x1401726d2` · `0x14020021a` · `0x14021cdae` r9d=6) |
| 7 | **`cursorHitTest`** | `0x1819a3970` | **없음** | **없음** |
| 8 | `cursorEnter` | `0x1819a3980` | ✓ | ✓ (mask `0x100` @ `0x14018a58d`) |
| 9 | `cursorLeave` | `0x1819a3990` | ✓ | ✓ (mask `0x200` @ `0x14018aa3a`) |
| 10 | `cursorMove` | `0x1819a39a0` | ✓ | ✓ (mask `0x400` @ `0x14018a378` · `0x14018a646`) |
| 11 | `cursorClick` | `0x1819a39b0` | ✓ | ✓ (mask `0x800` @ `0x14018a7fb`) |
| 12 | `cursorDown` | `0x1819a39c0` | ✓ | ✓ (`bt eax, r13d`, r13d=0xc @ `0x14018a6f8`) |
| 13 | `cursorUp` | `0x1819a39d0` | ✓ | ✓ (같은 자리 r13d=0xd · mask `0x2000` @ `0x14018a908`) |
| 14..18 | `mediaStatusChanged` … `mediaTimelineChanged` | `0x1819a39e0`.. | ✓ | ✓ |

`cursorHitTest` 는 **exe 어디에서도 발화되지 않는다** — 훅 인덱스를 받는 범용 디스패처
`0x140177ad0` 의 호출부 9곳이 넘기는 인덱스는 1 · 6 · 0x11 뿐이고, 커서 워커
`0x140189e10` 도 마스크 `0x80` 을 시험하지 않는다. 등록만 되어 있는 죽은 훅이다.

### 5.2 배달 규약 — 브로드캐스트가 **아니다**

exe 쪽은 스크립트 인스턴스 리스트 `renderState[0x17e0]` 를 훑는다. 각 노드에서:

```
inst = node[0x10]
if (inst == 0) continue
if (inst[0x48] != hitObject && inst[8] != 0) continue     ; 0x14018a709 – 0x14018a714
if (!(inst[0x40] & (1 << hookIdx))) continue              ; 0x14018a716 – 0x14018a71d
if (inst[0x44] != 2) continue                             ; 0x14018a71f
scriptEngine = rs[0x1830]
scriptEngine->vtbl[0x20]()                                 ; 스코프 진입(첫 배달에서 1회)
scriptEngine->vtbl[0x40](inst[0x38], inst[0x48], hookIdx, &event, extra)  ; 0x14018a766
… 루프 후 scriptEngine->vtbl[0x28]()                       ; 스코프 이탈
```

- `inst[0x40]` = §5.1 의 `[obj+0xd8]` 비트마스크가 그대로 넘어온 것이다.
- `inst[0x48]` = 이 스크립트가 붙은 오브젝트. **히트한 오브젝트와 같아야** 커서 이벤트를 받는다.
  예외는 `inst[8] == 0` 인 인스턴스로, 그 경우 어느 오브젝트가 맞았든 받는다.
- `cursorDown`/`cursorUp` 은 인덱스를 상수로 넣지 않고 `r13d = (down ^ 1) | 0xc` 로 만든다
  (`0x14018a6ef`–`0x14018a6f8`) — 눌림이면 0xc, 뗌이면 0xd.
- `cursorClick` 은 **뗄 때** 발화하되, 그 오브젝트가 "누른 채 잡고 있던" 해시맵에 들어 있어야 한다
  (`0x14018a7aa`–`0x14018a7b2`). 즉 **같은 오브젝트에서 눌렀다 뗀 경우만**.
- `cursorMove` 는 커서가 실제로 움직였을 때만(`[rbp+0x138]`, `0x14018a326`).

### 5.3 `CursorEvent` 필드

`lib.sceneScript.d.ts:1021-1046` 이 정본이다. DLL `.rdata` 의 필드 이름과 정확히 맞는다:

| 필드 | 문자열 VA | xref | d.ts |
|---|---|---|---|
| `worldPosition` | `0x1819a3440` | `0x181648472` | `Vec3` — "Only X and Y are supported right now" |
| `localPosition` | `0x1819a3450` | `0x1816484b1` | `Vec3` — 오브젝트 로컬 |
| `hitBox` | `0x1819a3460` | `0x1816484f0` | `String?` — 퍼펫 뼈 이름/인덱스 |
| `button` | `0x1819a3434` | `0x181648433` | d.ts 에서 **주석 처리**("Currently always 0 … NOT USED") — 그런데 DLL 은 필드를 실제로 채운다 |
| `screenPosition` | — | — | d.ts 에서 주석 처리, DLL 에도 문자열 없음 |

`IInput`(d.ts:2312-2330) 3프로퍼티는 `scene-script-api.md` §4 표에 이미 있다
(`cursorWorldPosition` `0x181649db6` · `cursorScreenPosition` `0x181657ee0`/`0x181649e12` ·
`cursorLeftDown` `0x181658110`/`0x181649e6e`). 단위는 d.ts 가 못박는다 — world 는 씬 월드,
screen 은 **픽셀**, leftDown 은 Boolean.

### 5.4 동봉 도달 실측 — 스크립트

| API | 동봉 `assets/` | 설치본 `projects/defaultprojects/` |
|---|---|---|
| `export function cursorDown` | 0 | **1** — `dino_run/scene.json`(오브젝트 `mario_walk_1`, `visible` 프로퍼티 바인딩) |
| `cursorEnter`/`Leave`/`Move`/`Up`/`Click`/`HitTest` | 0 | 0 |
| `input.cursorWorldPosition` | **2** — `presets/clock/preset.json`, `presets/clock/preview3dclock/scene.json` | **1** — `dino_run/scene.json` |
| `input.cursorScreenPosition` · `input.cursorLeftDown` | 0 | 0 |

`clock` 프리셋의 쓰임이 규약을 잘 보여 준다:

```js
var delta = thisLayer.origin.subtract(input.cursorWorldPosition);
delta = delta.divide(new Vec3(engine.canvasSize, 1));
var rotation = new Vec3(delta.y, -delta.x, …).multiply(50);
thisLayer.angles = rotation;
```

`input.cursorWorldPosition` 이 **레이어 origin 과 같은 공간(씬 픽셀)** 이라는 것을 이 코드가
증언한다 — 뺀 다음 `engine.canvasSize` 로 나눠야 정규화가 되기 때문이다.

---

## 6. OS 연동 — 데스크톱/아이콘/윈도우 회피

### 6.1 클릭 소유권 판정 `0x14010d9b0` – `0x14010da93`

```
GetClassNameW(h, cls, 32)                              ; 0x14010d9df
prop = GetPropW(h, L"WallpaperEngineParent")           ; 0x14010d9ef   (문자열 0x1404758f0)
if (wcsicmp(cls, L"SysListView32") == 0) {             ; 0x140475630
    h2 = GetParent(h);  GetClassNameW(h2, cls, 32);
    return wcsicmp(cls, L"SHELLDLL_DefView") == 0;     ; 0x140475608
}
if (prop == 1) return true;
if (wcsicmp(cls, L"SHELLDLL_DefView") == 0) return true;
return wcsicmp(cls, L"Progman") == 0;                  ; 0x1404755d8
```

즉 **데스크톱 아이콘 리스트(`SysListView32` under `SHELLDLL_DefView`) · 데스크톱 뷰 ·
`Progman` · 자기 벽지 부모 창** 위에서만 클릭을 인정한다. 다른 앱 창 위에서 누른 클릭은
`g_PointerState` 비트를 세우지 않는다.

**비대칭에 주의.** 이 검사는 **버튼에만** 걸린다. 커서 **위치**(`g_PointerPosition`)는
어느 창이 위에 있든 매 프레임 갱신된다(§1.1 — `ScreenToClient` 성공만 조건).

### 6.2 전역 저수준 마우스 훅 `0x140126640` – `0x1401267b3`

`SetWindowsHookExW(WH_MOUSE_LL = 14, 0x140126640, hInst, 0)` @ `0x140126902`, 참조 카운트
`0x1404e8c98` 로 1회만 건다. 훅 프로시저는:

- `WM_MOUSEMOVE`(0x200) · `WM_LBUTTONDOWN`(0x201) · `WM_LBUTTONUP`(0x202)를 가른다.
- `WM_LBUTTONUP` 이면 벽지 창 배열 `0x1404e8d70`(**최대 16개**)를 돌며
  `PostMessageW(hwnd, 0x202, 0, MAKELPARAM(x,y))` 로 되쏜다(`0x1401266c0`–`0x1401266e1`).
- `WM_LBUTTONDOWN` 이면 `WindowFromPoint` → `GetPropW(L"WallpaperEngineParent")` /
  클래스명(`WallpaperEngineParent` · `SHELLDLL_DefView` · `Progman` · `CabinetWClass`) 검사로
  데스크톱 소유를 확인한다(`0x140126727`–`0x140126758`).

이것이 "데스크톱 아이콘을 가린 벽지에서도 클릭이 먹는" 장치다. 아이콘 자체를 피해 가는
로직(아이콘 사각형 회피 등)은 **없다** — 클릭은 언제나 셸이 먼저 받고, 벽지는 사후 통보를 받는다.

`ShowCursor` 호출도 둘 있다(`0x1400ff6f7` · `0x14011080d`) — 커서 숨김/복원용이며 상호작용
좌표와는 무관하다.

---

## 7. Waple 대조

읽기만 했다. 파일:줄은 이번 라운드 기준.

| # | 항목 | 실물 | Waple | 판정 | 착지 지점 |
|---|---|---|---|---|---|
| **W-1** | `g_PointerPosition` 기본 | **`(0,0)`** (renderState ctor `0x14017c77d`) | `(0.5, 0.5)` (`SceneRenderer.swift:760`, `GLSLTranslator.swift:1402` 주석) | **확정 · 미해소** | 미구동 씬에서 `cursorripple` 파문이 화면 중앙에 생긴다. `(0,0)` 으로 바꾸면 좌상단 = 화면 밖 취급이라 실물과 같아진다 |
| **W-2** | `g_PointerPositionLast` 기본 | `(0,0)` | `(0.5,0.5)` (`SceneRenderer.swift:777`) | 확정 · 미해소 | W-1 과 한 쌍 |
| **W-3** | `g_PointerState.z` | **누른 첫 프레임만 1.0**(`0x140181623`–`0x14018162d`) | 누르고 있는 동안 계속 `pointerDown`(`SceneRenderer.swift:779`·`GLSLTranslator.swift:1411`) | **확정 · 미해소** | 클릭 유지 시 `cursorripple` 이 실물보다 훨씬 강하게 계속 밀어낸다. `pointerDownEdge = down && !downLast` 를 한 프레임만 세우면 된다 |
| **W-3b** | `g_PointerState.x/.y` | 누름 유지 동안 1.0 | 항상 0 | 확정 · 무해 | 동봉 셰이더 소비 0건. 기록만 |
| **W-4** | `disablepropagation` 의미 | **커서 히트 전파 차단**(`[obj+0x120]` bit14, 유일 소비 `0x14018a86f`) | **부모 트랜스폼 상속 차단**(`SceneDocument.swift:2420-2436`·`2553`·`2564`·`2600`·`2627`) | **확정 · 미해소** | 워크샵 코퍼스 `true` 34건(63씬)이 잘못된 좌표로 합성된다. 실물은 트랜스폼과 무관하다 — 계층 합성에서 이 필드를 떼고, 히트테스트 쪽으로 옮겨야 한다 |
| **W-5** | `solid` 게이트 | 히트테스트가 **`solid` 아닌 오브젝트를 건너뛴다**(`0x14018a02d`) | `isSolid` 를 파스만 하고 이벤트는 **전 엔진 브로드캐스트**(`SceneRenderer.swift:294-295`, 주석이 "WE 규약 — 스크립트가 스스로 히트테스트" 라고 적었다) | **확정 · 미해소** | 주석의 전제가 실물과 반대다. `eventEngines` 대신 `solid` + 쿼드 히트 결과로 좁혀야 한다 |
| **W-6** | 히트 판정 도형 | 오브젝트 4×4 를 먹인 **쿼드**(회전 존중), `size` ±0.5 | 축정렬 AABB, **회전 무시**(`SceneRenderer.swift:324-328` `layerHitRect`) | 확정 · 미해소 | 회전 레이어에서 어긋난다. `angleZ` 를 먹인 4점 + point-in-quad 로 대체 |
| **W-7** | 히트 시 시차 보정 | 광선 원점에 `(origin−focus)·amount·depth` 를 더한다(`0x14018a0b3`–`0x14018a115`) | 없음 | 확정 · 미해소 | camera-motion W-2/W-4 를 해소한 뒤 같은 함수를 히트테스트에서도 부르면 된다 |
| **W-8** | `cursorEnter/Leave` 대상 | **모든 `solid` 오브젝트**가 자동 호버 대상 | 훅을 export 한 엔진의 **바인드 레이어 1개**만(`SceneRenderer.swift:214-218`·`330-336`) | 확정 · 부분 | 실물은 스크립트가 없어도 히트테스트를 돌린다(유저 숏컷용). 스크립트 배달만 보면 근사치는 맞다 |
| **W-9** | `cursorClick` 타이밍 | **뗄 때**, 같은 오브젝트에서 눌렀을 때만 | **누를 때** `cursorDown` 과 함께(`SceneRenderer.swift:572-573`) | 확정 · 미해소 | 한 줄 이동. 누른 오브젝트를 기억했다가 up 에서 비교 |
| **W-10** | 파티클 CP bit0 | 매 프레임 CP 평행이동을 커서로 교체 | **의도적 미구현**(`ParticleSystem.swift` `controlPointFlags` 주석 `:1520-1528` — "bit0 은 헤드리스에 커서가 없고") + CP 를 로드 시 1회 **베이크**(`bakeControlPointTargets`, `:2632`) | 확정 · 미해소 | 동봉 28파일이 정적 CP 로 돈다 — `examplecursorfollow` 류는 아예 움직이지 않는다. 베이크를 유지하려면 bit0 CP 만 매 프레임 재베이크가 필요하다 |
| **W-11** | `controlpoint[].flags`/`parentcontrolpoint` 파스 | uint 주입기 기본 0 | 파스함(`ParticleSystem.swift` CP 루프 `:2598` 이하), bit2 만 소비 | 확정 · 부분 | bit0 소비만 추가하면 된다 |
| **W-12** | `xray` 이펙트 | `g_PointerPosition` + `g_PointerScale` | `g_PointerScale` 은 머티리얼 파라미터로 흐름. 배선 자체는 있음 | 보고 | `shader-uniforms.md:675` 의 "cursorripple·fluidsimulation 만" 문장을 정정 |
| **W-13** | `cursorHitTest` 훅 | 등록되나 **발화 없음** | 없음 | 확정 · 일치 | 조치 불요. 구현하면 안 된다 |
| **W-14** | 커서 소유권(데스크톱 판정) | `WindowFromPoint` + 셸 클래스 검사 | 없음(전역 클릭 모니터가 무조건 받는다) | 확정 · macOS 제약 | §8 |
| **W-15** | `config.fullscreen` 항상-히트 | `[obj+0x304]` bit1 | `configPassthrough`/`configAutosize` 는 파스, `fullscreen` 은 모델 루트 키로만 인지(`SceneDocument.swift:251-256`) | 보고 | 동봉 도달 1건이라 우선순위 낮음 |

### 7.1 우선순위

1. **W-4(`disablepropagation`)** — 의미 자체가 다르다. 워크샵 코퍼스 34건이 영향받고,
   고치는 방향은 "쓰지 않기"라 회귀 위험이 오히려 낮다.
2. **W-1/W-2/W-3(포인터 유니폼 기본·엣지)** — 세 줄 수정. `cursorripple`/`fluidsimulation` 을
   쓰는 씬의 무입력 상태 픽셀이 실물과 달라져 있다.
3. **W-5/W-9(이벤트 배달 규약)** — 주석의 전제가 뒤집혔으므로 문서부터 정정.
4. **W-10(파티클 CP bit0)** — 동봉 28파일. 다만 헤드리스 캡처 결정성과 충돌하므로
   `SceneRenderer.capturePointerUV` 핀과 같은 계약이 필요하다.
5. **W-6/W-7(히트 도형·시차)** — camera-motion W-2/W-4 해소와 묶어야 이득이 난다.

---

## 8. macOS 에서의 제약 — 정직하게

| 실물이 쓰는 것 | macOS 대응 | 제약 |
|---|---|---|
| `GetCursorPos`(전역 커서 좌표) | `NSEvent.mouseLocation` | **권한 불필요.** 앱이 비활성이어도 읽힌다. Waple 의 마우스 모니터가 이미 이걸 쓴다 |
| `ScreenToClient` | `NSWindow.convertPoint(fromScreen:)` | 문제 없음 |
| `GetKeyState(VK_LBUTTON)` (전역 버튼 상태) | `NSEvent.pressedMouseButtons` | **권한 불필요.** 폴링이면 가능 |
| `SetWindowsHookExW(WH_MOUSE_LL)` (전역 훅) | `CGEvent.tapCreate` | **접근성(Accessibility) 권한 필요.** TCC 프롬프트가 뜨고, 사용자가 거부하면 전역 클릭을 못 받는다. 데스크톱 벽지 창은 보통 `ignoresMouseEvents`/`.desktopWindow` 라 로컬 이벤트도 안 온다 |
| `WindowFromPoint` + 창 클래스명 | `CGWindowListCopyWindowInfo` | **Screen Recording 권한**이 있어야 다른 앱의 창 이름/소유자를 볼 수 있다(macOS 10.15+). 창 **경계**만은 권한 없이도 얻히므로 "커서 아래에 다른 앱 창이 있는가" 정도는 근사 가능 |
| `GetPropW(L"WallpaperEngineParent")` | 대응 없음 | Waple 자신의 창은 자기가 안다. 셸(Finder) 데스크톱 창 판정은 `kCGWindowOwnerName == "Finder"` 로 근사 |
| 데스크톱 아이콘 클릭 통과 | — | macOS 에서 벽지 창은 `NSWindow.Level.desktopIconWindow` **아래**에 두면 아이콘이 자동으로 위에 오고 클릭도 Finder 가 먼저 받는다. 즉 WE 의 `PostMessageW` 되쏘기에 해당하는 장치가 **필요 없다** — 대신 벽지가 클릭을 받을 방법도 없어진다 |

**결론.** 커서 **위치** 계층(§1·§2·§3 — 유니폼과 파티클 CP)은 macOS 에서 권한 없이 실물과
동등하게 구현할 수 있다. 커서 **클릭** 계층(§4·§5·§6)은 그렇지 않다:

- 벽지 창이 아이콘 아래에 있으면 클릭이 오지 않고,
- 위로 올리면 아이콘을 쓸 수 없으며,
- 전역 이벤트 탭으로 우회하려면 접근성 권한이 필요하다.

따라서 `cursorDown`/`cursorUp`/`cursorClick`/`g_PointerState.z` 는 **권한 없는 기본 구성에서는
발화하지 않는 것이 정상**이라고 못박아 두는 편이 낫다. `SceneRenderer.setPointerButtonDown`
(`SceneRenderer.swift:316`)과 `simulateCursorClick`(`:312`)이 이미 그 전제로 만들어져 있다.

---

## 부록 A. 재현 절차

```bash
S=/tmp/claude-0/-home-user/abe2d757-2792-5050-8baf-0be7e33c5b76/scratchpad

# 0) 평문부터 — x86 파기 전에
cd /home/user/Waple-wallpaper-source/wallpaper_engine
grep -rl "g_Pointer" assets/                    # → cursorripple · fluidsimulation · xray
grep -rn "locktopointer" assets/ | head
python3 - <<'PY'                                # 바이너리 전수: locktopointer 0건
import glob,os
for f in glob.glob('bin/*')+glob.glob('*.exe'):
    if not os.path.isfile(f): continue
    d=open(f,'rb').read()
    if b'locktopointer' in d or 'locktopointer'.encode('utf-16-le') in d: print(f)
PY

# 1) 커서 샘플러(GetCursorPos/GetKeyState/WindowFromPoint/ScreenToClient)
python3 -c "import sys;sys.path.insert(0,'$S');from wpe import function_frags;print(function_frags(0x140110630))"
python3 $S/vdis2.py 0x1401115a0 0x140111660

# 2) g_PointerState 합성 · 프레임 꼬리의 last 이월 + bit1 세우기
python3 $S/vdis2.py 0x1400d9e2c 0x1400d9e90
python3 $S/vdis2.py 0x1401815e0 0x1401816b4

# 3) 데스크톱 소유권 판정 · WH_MOUSE_LL 훅
python3 $S/vdis2.py 0x14010d9b0 0x14010da94
python3 $S/vdis2.py 0x140126640 0x1401267b4

# 4) 파티클 CP 드라이버
python3 -c "import sys;sys.path.insert(0,'$S');from wpe import function_frags;print(function_frags(0x14022e3e0))"
python3 $S/vdis2.py 0x14022e3e0 0x14022e6e0     # bit16/bit0/bit2 분기 + 언프로젝션
python3 $S/vdis2.py 0x14022eb20 0x14022ebde     # 루프 꼬리

# 5) 히트테스트 워커와 쿼드 판정
python3 $S/vdis2.py 0x140189e10 0x14018a460
python3 $S/vdis2.py 0x14019dbb0 0x14019df2f

# 6) solid / disablepropagation / perspective 비트
python3 $S/vdis2.py 0x1401e11f0 0x1401e1360     # 등록부
python3 $S/vdis2.py 0x14019c3f0 0x14019c440     # solid  → bts 0xd
python3 $S/vdis2.py 0x14019bb40 0x14019bb90     # disablepropagation → bts 0xe
python3 $S/vdis2.py 0x14019c620 0x14019c6a0     # perspective → bts 7

# 7) scenescript64 훅 테이블 19개
python3 - <<'PY'
import sys,struct;sys.path.insert(0,"/tmp/claude-0/-home-user/abe2d757-2792-5050-8baf-0be7e33c5b76/scratchpad")
from pe2 import PE
ss=PE('/home/user/Waple-wallpaper-source/wallpaper_engine/bin/scenescript64.dll')
for i in range(19):
    p=struct.unpack_from('<Q',ss.d,ss.va2off(0x1819a3ee0+i*8))[0]
    o=ss.va2off(p); print(i, hex(p), ss.d[o:ss.d.index(b'\0',o)].decode())
PY

# 8) 동봉 도달 — 마우스 CP 와 그것을 참조하는 요소
python3 - <<'PY'
import json,glob,os
root='/home/user/Waple/Sources/WapleRender/Resources/WEAssets'
def walk(o):
    yield o
    if isinstance(o,dict):
        for v in o.values(): yield from walk(v)
    elif isinstance(o,list):
        for v in o: yield from walk(v)
n=0; ops={}
for p in glob.glob(os.path.join(root,'**','*.json'),recursive=True):
    try: d=json.load(open(p,encoding='utf-8-sig'))
    except Exception: continue
    for node in walk(d):
        if not isinstance(node,dict): continue
        cps=node.get('controlpoint')
        if not isinstance(cps,list): continue
        mouse={i for i,c in enumerate(cps) if isinstance(c,dict) and isinstance(c.get('flags'),int) and c['flags']&1}
        if not mouse: continue
        n+=1
        for k in ('operator','initializer'):
            for op in node.get(k) or []:
                if isinstance(op,dict) and op.get('controlpoint') in mouse:
                    ops[op.get('name')]=ops.get(op.get('name'),0)+1
print('mouse-CP files', n, ops)
PY
```

## 부록 B. 배제한 가설

| 가설 | 왜 틀렸나 |
|---|---|
| `g_PointerPosition` 이 `[0,1]` 로 클램프된다 | 쓰기 지점 `0x14011163b`–`0x14011164b` 에 `maxps`/`minps` 가 없다. clamp01 은 **parallax 소비부**에만 있다(camera-motion §3) |
| 미구동 시 포인터가 화면 중앙 `(0.5,0.5)` | renderState 생성자 `0x14017c77d` 가 qword 0 을 쓴다 — `(0,0)` |
| `g_PointerState` 가 버튼 4개(좌/우/중/보조) | `.x`·`.y` 는 같은 비트, `.z` 는 그 비트의 엣지, `.w` 는 상수 0. 우클릭·휠 코드가 없다 |
| `g_PointerState.z` 가 "클릭 세기"(아날로그) | 값이 `xmm14 = 1.0f`(`0x1400d8343`) 아니면 0 이다 |
| `.z` 가 버튼 유지 동안 1 | 프레임 꼬리 `or eax, 2`(`0x14018162d`)가 다음 프레임부터 `.z` 를 0 으로 만든다 |
| `locktopointer` 가 런타임 키 | ASCII·UTF-16LE 모두 설치본 바이너리 전수(`wallpaper32/64.exe` + `bin/*.exe` 16 + `bin/*.dll` 24)에 0건. 에디터 JS(`ui/dist/scripts/scripts.js`)에도 0건 |
| 커서가 난류(`turbulence`)를 트리거한다 | `turbulence` 파서·핸들러에 `controlpoint` 키가 없다. 동봉 `exampleturbolence.json` 은 `turbulence` 와 `controlpointattract` 를 나란히 놓았을 뿐이다 |
| 마우스 CP 가 CP 의 회전도 바꾼다 | `0x14022e47b`–`0x14022e4ae` 가 저작 4×4 를 통째로 복사한 **뒤** `+0x30..+0x38`(평행이동)만 덮어쓴다 |
| 마우스 CP 언프로젝션이 z=near 평면 | `xmm12 = 0`(`0x14022e413`)이 z 입력이다 — NDC **z = 0** |
| 히트테스트가 알파 임계를 쓴다 | `0x14019dbb0` 전 구간에서 텍스처 샘플이 없다. 입력은 4×4 · `size` · 광선뿐 |
| 히트테스트가 축정렬 바운딩 박스 | 쿼드 4점을 오브젝트 4×4 의 X/Y 축으로 만든다(`0x14019de24`·`0x14019de68`) — 회전이 들어간다 |
| `solid` 없는 레이어도 커서 이벤트를 받는다 | `test word [r15+0x120], 0x2000; je` (`0x14018a02d`)가 루프의 첫 관문이다. **단** 동봉 `dino_run` 이 반례로 남아 있다(§9) |
| 커서 훅이 전 스크립트에 브로드캐스트된다 | `cmp [inst+0x48], r15`(`0x14018a709`) — 히트 오브젝트와 소유자가 같아야 한다(`[inst+8]==0` 예외) |
| `cursorHitTest` 가 히트테스트를 스크립트에 위임하는 훅 | 등록만 되고 exe 발화 지점이 0곳. 범용 디스패처 `0x140177ad0` 의 호출 9곳도 인덱스 7 을 넘기지 않는다 |
| WE 가 데스크톱 아이콘 사각형을 피해 그린다 | 회피 코드가 없다. 클릭은 셸이 먼저 받고 WE 는 `WH_MOUSE_LL` 로 사후 통보를 받는다 |
| `disablepropagation` 이 부모 트랜스폼 상속을 끊는다 | bit14 를 읽는 지점이 exe 전체에서 `0x14018a877` 하나뿐이고(`.pdata` 전 함수 선형 스윕), 그 자리는 커서 워커의 루프 탈출 조건이다. 트랜스폼 합성(`0x1401850a0` 계열)은 이 비트를 보지 않는다 |

---

## 9. 확정 못 한 것

| 항목 | 상태 |
|---|---|
| `renderState+0x1838`(커서 상호작용 마스터 게이트)를 **쓰는** 지점 | `[미해결]`. `.pdata` 등재 전 함수를 선형 스윕해도 읽기 2곳(`0x140189e31`·`0x1401802af`)만 나온다. 설정 역직렬화가 오프셋 계산으로 쓰는 것으로 보이나 확정 못 했다 |
| `renderState+0x74/+0x78` 에 표면 크기를 **쓰는** 지점 | `[미해결]`. 생성자 기본 `(1.0,1.0)`(`0x14017c76f`)과 두 소비처(나눗셈·되곱셈)로 정체는 확정, 기록 지점은 미확정 |
| 동봉 `dino_run/scene.json` 의 `cursorDown` 이 `solid` 없이 어떻게 발화하나 | `[미해결]`. 해당 오브젝트(`mario_walk_1`)에 `solid` 키가 없고 씬 전체에 `solid` 가 0건인데, 워커는 `solid` 없는 오브젝트를 건너뛴다. `solid` 의 **기본값이 true** 이거나(오브젝트 ctor 에서 `+0x120` 에 상수를 심는 지점을 못 찾았다), 로더가 스크립트 훅을 보고 bit13 을 얹거나, 이 기본 프로젝트가 현행 빌드에서 실제로 동작하지 않거나 — 셋 중 하나다 |
| CP0 이 "시스템 방출 원점" 이라는 것의 코드 근거 | `[미해결]`. 코퍼스 근거는 강하다(`examplecursorfollow.json` 이 CP0 bit0 만 갖고 이미터 `origin` 이 `0 0 0`). 이미터가 CP0 행렬을 읽는 지점은 못 짚었다 |
| `[inst+8] == 0`(어느 오브젝트가 맞아도 이벤트를 받는 스크립트)의 정체 | `[미해결]`. 프로퍼티 바인딩이 없는 스크립트로 보이나 확정 못 했다 |
| `[inst+0x44] == 2` 게이트의 의미 | `[미해결]`. 스크립트 인스턴스 종류 코드로 보인다 |
| `renderState[0x1710]` 의 `[+0x118] & 0xc000000` 게이트(유저 숏컷 발화 억제) | `[미해결]` |
| `input.cursorWorldPosition`/`cursorScreenPosition` 을 채우는 exe 측 필드 | `[미해결]`. d.ts 가 단위를 못박고(`world` = 씬 월드, `screen` = 픽셀) 동봉 `clock` 스크립트가 그 규약을 증언하지만, DLL↔exe 콜백 경로는 안 짚었다 |
| CP `flags` bit3(부모 행렬 통째 복사)·bit16 의 동봉 도달 | 0건 — `scene-object-model.md` §12 와 같다 |
| 히트테스트 `vtbl+0x88`(hitBox 채우기)의 퍼펫 뼈 판정 규약 | `[미해결]`. 함수 `0x140185520`–`0x14018593c` 만 짚었다 |
