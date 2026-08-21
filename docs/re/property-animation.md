# WE 프로퍼티 애니메이션(키프레임) — 실물 대조

대상: `wallpaper64.exe` (imagebase `0x140000000`), 동봉 자산
`Sources/WapleRender/Resources/WEAssets/`, 설치본 `wallpaper_engine/assets/`·`projects/`,
에디터 UI `ui/dist/scripts/scripts.js`, 라벨 `locale/ui_en-us.json`. 조사일 2026-08-21. 모든 주소는 VA.

---

## 0. 요약 — Waple 과 어긋났던 것

| # | 항목 | WE 실물 | 종전 Waple | 실측 어긋남 | 조치 |
|---|---|---|---|---|---|
| 1 | 베지어 핸들 **x 스케일** | `P1x = f0 + 0.5·dx·front.x`, `P2x = f1 + 0.5·dx·back.x` (VA 0x1401a9d60) | `f0 + front.x` (스케일 없음) | 값 범위의 **13.71%** | **수정** |
| 2 | `options.wraploop` | 끝점 키프레임을 첫 키프레임과 같게(VA 0x1401a98b0) | 미파스·미소비 | 후반 절반 정지, Δ 최대 **291.0 = 범위 전체** | **수정** |
| 3 | 키프레임 `step` | 오른쪽 키프레임 flag bit2 → 구간을 왼쪽 값으로 고정(VA 0x1401a9d18) | 미파스 | 자산 도달 0(에디터 저작 가능) | **수정** |
| 4 | `mode` 비교 | `stricmp`, 미인식 문자열은 **loop** (VA 0x1401a8c78/0x1401a8c91) | 대소문자 구분 + 미인식은 **클램프** | 자산 도달 0 | **수정** |
| 5 | 구간 탐색 경계 | 반개구간 `k1 ≤ f < k2` (VA 0x1401a9cd8) | 닫힌구간 | step 도입 전에는 무영향 | **수정** |
| 6 | 시간 → 값 | 정수 프레임 2개 샘플 + 선형 보간(VA 0x1401723d8) | 연속 프레임 직접 평가 | ≤ 0.16%(아래 §5) | **유지 + 반증 주석** |
| 7 | 근 찾기 | `u=0`에서 0.999 반감, `|X−f| < 0.01` 프레임, 1000회 상한 | [0,1] 24회 이분법 | WE 쪽이 최대 0.02 덜 수렴 | **유지**(Waple 이 더 정확) |
| 8 | `fps`/`length` 부재 | 애니 **전체 드롭**(VA 0x1401a9714, 0x1401a8c21) | 30fps·마지막 키프레임 길이로 대체 | 도달 0 | 유지 + 주석 |
| 9 | `c0..c3` 누락 채널 | **캐스케이드 중단**(c0 없으면 0트랙, c0+c2 면 c2 유실) | 빈 트랙으로 자리 유지 | 도달 0(전수 연속) | 유지 + 주석 |
| 10 | 키프레임 순서 | 정렬 안 함, `frame ≤ 직전` 을 **드롭**(초기 −1) | 정렬 | 도달 0 | 유지 + 주석 |
| 11 | `relative` | **키 존재만** 확인(값 무시) → `false` 도 상대 | bool 값을 읽음 | 도달 0(1건, true) | 유지 + 주석 |
| 12 | `options.random` | flags bit2 = "Random start frame" | 없음 | 도달 0 | 미구현(런타임 상태 필요) |
| 13 | `lockangle`/`locklength`/`magic` | 바이너리 xref **0건** — 에디터 전용 | 이미 무시 | — | 확인(종전 주석이 옳았다) |
| 14 | `events` 발화 경계 | `oldTime ≤ e.t < newTime`(초 단위) | `prevF < m ≤ curF`(프레임) | 한 틱 | 유지 + 주석 |

---

## 1. 자산 전수 조사 — 실제로 등장하는 키

동봉 트리 + 설치본(`assets/`, `projects/`) 전체 JSON 을 훑어 `"animation"` 객체를 전수 수집했다.
**애니 블록 7개 / 파일 6개**가 전부다(동봉 트리와 설치본이 같은 집합).

```
animation 블록 키 : c0×7  options×7  c1×6  c2×6  relative×1        (c3 는 0)
keyframe 키       : frame×38  value×38  front×38  back×38  lockangle×38  locklength×38
handle 키         : enabled×38  x×38  y×38  magic×28
options 키        : fps×7  length×7  mode×7  wraploop×7
```

관측 값 분포: `mode` = loop 6 / mirror 1 · `wraploop` = `true` 2 / `null` 5 ·
`fps` = 20×4, 30×2, 15×1 · `length` = 60×6, 30×1.

**나열되지 않은 키**(과제 단서에 있었으나 자산에 없는 것): `keyframes`(에디터 메모리 표현일 뿐
직렬화 이름이 아니다) · `easing` · `interpolation` · `tangent` · `c3` · `events` · `startpaused` ·
`random` · `step` · `smoothing` · `stiffness` · `parent` · `name` · `children`.
뒤 아홉은 **바이너리·에디터에는 있다**(§2, §3) — 자산 도달만 0 이다.

블록이 붙는 자리(도달 분포):

| 자리 | 블록 수 |
|---|---:|
| `objects[].instanceoverride.controlpointangle1` | 4 |
| `objects[].origin` | 1 |
| `objects[].instanceoverride.controlpoint1` | 1 |
| `objects[].effects[].passes[].constantshadervalues.multiply` | 1 |

---

## 2. 바이너리 — 파서

### 2.1 바인딩 파서 `0x1401a4db0–0x1401a5a8e`

`user` / `name` / `condition` / `type` / `relative` / `value` / `c0..c3` / `options` / `events` /
`script` / `scriptproperties` 를 차례로 `Json::Value::find`(0x140087490) 한다.

- `relative`(문자열 `0x14048ed68`) — **키의 존재만** 본다(0x1401a53a3 `test rax,rax`).
  존재하고 `value` 가 **문자열**이면(0x1401a53cc `cmp byte ptr [rax+8], 4`) 공백 구분 float 3개를
  `strtod`(0x1402d06ac)로 뽑아 xmm6/xmm7/xmm8 에 담고, `c0`/`c1`/`c2` 배열의 각 `value` 에
  **파스 시점에 더해 굽는다**(0x1401a89a0). `c3` 는 이 처리를 받지 않는다.
- 트랙 조회는 `c0`(`0x14048eef4`) → `c1`(`…eef8`) → `c2`(`…eefc`) → `c3`(`0x14048ef00`).
  네 문자열이 `.rdata` 에 4바이트 간격으로 연속 배치돼 있다.
  각 채널이 배열(type 6)이 아니면 **거기서 끊는다**(0x1401a56dd/0x1401a5701/0x1401a5720/0x1401a573e).

### 2.2 키프레임 배열 파서 `0x1401a8ce0–0x1401a9400`

읽는 키: `value` · `frame` · `back{enabled,x,y}` · `front{enabled,x,y}` · `step`.
`lockangle`/`locklength`/`magic` 은 **여기 없다**(바이너리 전체 xref 0건).

- `value`·`frame` 은 숫자 타입(1..3)이어야 한다(0x1401a8e73/0x1401a8e83). `frame` 은 `asInt`(0x1401a8fb5) — **i32**.
- 직전 프레임을 `[rsp+0xe8]` 에 들고 `frame <= 직전` 이면 **그 키프레임을 버린다**(0x1401a8fc1 `jle`).
  초기값 `0xFFFFFFFF = −1`(0x1401a8d26) → 음수 프레임도 탈락. 즉 **정렬하지 않고 강한 단조만 통과**.
- `step` 이 true 면 flags = 4 로 두고 **핸들을 아예 읽지 않는다**(0x1401a8fed).
  아니면 `back.enabled` → `|= 1` + `back.x/y` 읽기, `front.enabled` → `|= 2` + `front.x/y` 읽기.
  disabled 면 x/y 는 **0 으로 남는다**(0x1401a8fd1 의 `xorps` 초기화).

키프레임 구조체(28바이트, 저장부 0x1401a9127–0x1401a9148):

```
+0x00 i32 frame     +0x04 f32 value    +0x08 u32 flags(bit0 back, bit1 front, bit2 step)
+0x0c f32 backX     +0x10 f32 backY    +0x14 f32 frontX   +0x18 f32 frontY
```

### 2.3 옵션 파서 `0x1401a96b0–0x1401a98a8` + 초기화 `0x1401a8c10–0x1401a8cd1`

읽는 키: `length`(i32, 필수) · `fps`(f32, 필수) · `mode`(문자열) · `random`(bool) ·
`startpaused`(bool) · `wraploop`(bool).

```
AnimOptions::init(const char* mode, float fps, int length, Options* out, bool random, bool startpaused)
  out[+0x10] = length
  if (0 >= fps)               return false           ; 0x1401a8c21
  out[+0x08] = length / fps                          ; 초 단위 길이
  if (0 >= length/fps)        return false           ; 0x1401a8c43
  out[+0x00] = 1.0f / fps                            ; 초/프레임
  out[+0x0c] = 0
  if (mode && stricmp(mode,"mirror")==0) out[+0x0c] |= 0x1     ; 0x1401a8c71
  if (       stricmp(mode,"single")==0)  out[+0x0c] |= 0x2     ; 0x1401a8c87
  if (random)      out[+0x0c] |= 0x4
  if (startpaused) out[+0x0c] |= 0x20000000
  return true
```

`length`/`fps` 가 숫자가 아니면 옵션 파서가 먼저 false 를 돌린다(0x1401a9714–0x1401a972d).
false 면 호출부(0x1401a56c0 `test al,al` / `je 0x1401a57e1`)가 **트랙을 하나도 파스하지 않는다** —
즉 애니 전체가 사라진다.

`wraploop` 만 초기화 밖에서 별도로 선다: `0x1401a9881  or dword ptr [r12+0xc], 0x10`.

상태 구조체(= 애니 객체 `+0x38`):

```
+0x00 f32 1/fps   +0x04 f32 time(초)   +0x08 f32 length/fps(초)   +0x0c u32 flags   +0x10 i32 length
+0x18..+0x28 vector<Event>(stride 0x28)          ; 애니 객체 기준 +0x50
```

flags: `0x1` mirror · `0x2` single · `0x4` random · `0x10` wraploop · `0x20000000` startpaused ·
`0x40000000` single 종료 · `0x80000000` 미러 역주행.

### 2.4 `wraploop` 후처리 `0x1401a98b0–0x1401a9b90`

호출부 `0x1401a5762`:

```
if ([anim+0x44] & 0x10)                       ; options.flags bit4
    for (track : anim.tracks)  wrapLoop(track, [anim+0x48] /*length*/)   ; Track stride 0x30
```

본체:

1. 키프레임 2개 미만이면 반환(0x1401a98dd).
2. 첫 키프레임의 `value`(`xmm7`)·`front` 8바이트(`xmm6`)·`flags`(`r10d`)를 보관(0x1401a98f5–0x1401a9904).
3. `last.frame > length` 인 동안 pop_back(0x1401a9920–0x1401a9959). 그래도 2개 미만이면 반환.
4. `last.frame == length` 면 그 키프레임을 재사용, 아니면 `{frame=length, 나머지 0}` 을 **append**
   (0x1401a999b `je 0x1401a9b45` / 0x1401a99b5).
5. 끝점에 기록: `value = kf0.value`(0x1401a9b8b).
   `kf0.flags & 2`(front enabled)면 `flags |= 1`(back enabled) + `back = −kf0.front`
   (0x1401a9b58 `xorps` 부호마스크 `0x140492ff0` = `{0x80000000}×4`, 저장 0x1401a9b5f).
   아니면 `flags &= ~1`(0x1401a9b66) — **backX/backY 는 지우지 않는다**.

에디터 라벨이 그대로 규약이다:
`ui_editor_animation_modal_loop_wrap_help_body` = *"Sets the last frame of the animation equal to the
first frame, resulting in a smooth loop that ends exactly where it starts."*

---

## 3. 바이너리 — 평가기

### 3.1 정수 프레임 트랙 평가 `0x1401a9bc0–0x1401a9f56`

시그니처는 `float Track::valueAtFrame(Track* this, int frame)` 이고, `Track` 은
`vector<Keyframe>`(`+0x00`) + **`vector<float>` 프레임 캐시**(`+0x18`)다.
`frame < 캐시크기` 면 캐시를 그대로 돌려주고(0x1401a9bed), 아니면 `frame+1` 로 리사이즈한 뒤
빈 자리를 **정수 프레임마다 채운다**. 즉 곡선은 **정수 프레임에서만** 풀린다.

구간 결정(0x1401a9cb4–0x1401a9d0a):

```
frame <= kf[0].frame            → kf[0].value
kf[i-1].frame <= frame < kf[i].frame  → 구간 [i-1, i]        ; 반개구간
i 가 끝까지 가면                → kf[count-1].value
구간 안에서:
   kf[i-1].frame == frame       → kf[i-1].value              ; 0x1401a9d0f
   kf[i].flags & 4 (step)       → kf[i-1].value              ; 0x1401a9d18
```

제어점 조립(0x1401a9d24–0x1401a9d8c). `dx = kf[i].frame − kf[i-1].frame`:

```
P0 = (f0,           v0)
P1 = (f0 + 0.5·dx·front0.x,  v0 + front0.y)      ; 0x1401a9d74 / 0x1401a9e58
P2 = (f1 + 0.5·dx·back1.x,   v1 + back1.y)       ; 0x1401a9d6d / 0x1401a9e8f
P3 = (f1,           v1)
```

`0.5` 는 `xmm12` (`0x1404926c0`), `3.0` 은 `xmm15` (`0x140492830`), `1.0` 은 `xmm13` (`0x140492704`).
**x 에만 `0.5·dx` 가 붙고 y 에는 아무 스케일도 없다.**

근 찾기(0x1401a9d90–0x1401a9e23):

```
u = (frame − f0) / dx           ; 정수 나눗셈이라 구간 안에서는 항상 0
step = 0.999                    ; 0x1404926fc
for (iter = 0; iter < 1000; ++iter) {
    x = Bez(P0x,P1x,P2x,P3x, u)
    if (0.01 > |x − frame|) break            ; 허용오차는 double 0.01 (0x140492708) — 프레임 단위
    step *= 0.5
    u += (x > frame) ? −step : +step
}
u = min(u, 1.0); if (0 > u) u = 0            ; 0x1401a9e29–0x1401a9e38
return Bez(P0y,P1y,P2y,P3y, u)               ; 0x1401a9e3b–0x1401a9eb9 (캐시에 저장)
```

### 3.2 시간 진행 `0x1401a9f60–0x1401aa1b4`

```
if (flags & 0x60000000) return;                       ; startpaused(bit29) 또는 single 종료(bit30)
if ((flags & 2) && time >= duration) return;          ; single 은 끝에서 멈춘다
if (0 >= duration) return;
if (flags & 0x80000000) dt = −dt;                     ; 미러 역주행
newTime = time + dt;
… 이벤트 크로싱 스캔 …                                  ; oldTime ≤ e.t < newTime (역주행이면 반대)
time = newTime;
single : if (time >= duration) { flags |= 0x40000000; time = duration; }      ; 0x1401aa177
mirror : 정방향  time >= duration → { over = fmodf(time,duration); flags |= 0x80000000; time = duration − over; }
         역방향  time <= 0        → { time = −fmodf(time,duration); flags &= 0x7fffffff; }
loop   : time < 0 → time = fmodf(time + duration, duration);
         time >= duration → time = fmodf(time, duration);                     ; 0x1401aa0cf
```

미러는 방향 비트를 토글하는 상태 기계지만 단조 클록에서는 주기 `2·duration` 삼각파와 동치다.

### 3.3 소비단(시간 → 값) `0x140171440` / `0x1401f2ad0`

```
spf   = anim[+0x38]                       ; 1/fps
time  = anim[+0x3c]
len   = anim[+0x48]
frac  = fmodf(time, spf) / spf            ; 0x1401723e8 + 0x14017242d
f0    = clamp((int)(time / spf), 0, len−1); 0x1401723f5–0x140172413
f1    = min(f0 + 1, len)                  ; 0x140172415
v     = track.at(f0)·(1 − frac) + track.at(f1)·frac      ; 0x140172460–0x14017248c
```

성분별로 이 짝을 반복한다(0x1401f2ad0 은 카메라 경로 3채널 × 3그룹).

---

## 4. 에디터(JS)가 알려주는 것

`ui/dist/scripts/scripts.js`:

- 새 프로퍼티 애니의 기본 옵션은 `{fps:30, length:60, mode:"loop", wraploop:true}` (@238900) —
  설치본 자산의 관측 분포와 일치한다. 퍼펫은 `{length:10, fps:10, mode:"loop", wraploop:true,
  smoothing:0, stiffness:1}`(@235812), 카메라 경로는 `{length:10, fps:10, mode:"single", wraploop:false}`(@280980).
- `wraploop` 은 **`mode === 'loop'` 일 때만** 저장된다(`"loop"!==e.mode && delete e.wraploop`, @575525).
  런타임은 모드와 무관하게 flag 를 소비하므로 이건 저작 측 제약이다.
- 켜는 순간 `frame >= length` 인 키프레임을 지우고(@575755) 곡선을 다시 만든다.
  탄젠트 자동계산도 랩어라운드로 바뀐다(`I() = wraploop && mode==='loop'`, @555227).
- `beziermode` 가 `magic` / `step` 을 고른다(@238254 부근). `magic:true` 는 자동 탄젠트 표식,
  `step:true` 는 §2.2 의 계단 플래그다. `lockangle`/`locklength` 는 핸들 드래그 제약이다.
- 조건 표현식은 `scope.$eval(condition, properties)` — **AngularJS 표현식**이다(@106522, @375231).

`locale/ui_en-us.json`: `ui_editor_animation_modal_random_start_frame` = "Random start frame"
(= flags bit2), `ui_editor_animation_modal_loop_wrap` = "Create smooth animation loop".

---

## 5. 정수 프레임 양자화를 옮기지 않은 근거

동봉 자산의 애니 트랙을 두 방식(정수 2샘플 선형보간 ↔ 연속 프레임 직접 평가)으로 전수 대조했다.

| 트랙 | 값 범위 | 최대 차이 |
|---|---:|---:|
| `blendgradient` multiply c0 (fps 15, len 30, mirror) | 1.0 | **0.00156** (0.16%) |
| `magic` controlpointangle1 c0 (fps 20, len 60, loop) | — | 1.3e-15 |

0.16% 조차 mirror 반환점(`t == duration`) 한 점에서 `f0` 가 `length−1` 로 클램프되기 때문이다.

반대로 양자화를 그대로 옮기면 부작용이 따라온다. `frac = fmodf(time, 1/fps) / (1/fps)` 는
**정확한 프레임 경계에서 0 이 아니라 ≈1** 을 돌린다(float32 실측: fps 30·len 60 에서
`time/spf = 59.999996`, `frac = 0.999997`). 즉 샘플이 한 프레임 앞선다. 같은 대조에서
관측된 5.6% 편차는 **전부 이 경계 인공물**이었다. 정확도를 잃고 부동소수 취약성만 얻는
교환이라 Waple 은 연속 평가를 유지하고, 대신 이 문서와 `PropertyAnimation.value` 주석에
근거를 남긴다.

---

## 6. 남은 파스 diff 후보 (`SceneDocument.swift` — 이 레인 밖)

1. **`instanceoverride` 의 애니 바인딩이 드롭된다.** 자산 7블록 중 **5블록**이
   `objects[].instanceoverride.controlpoint1` / `controlpointangle1` 아래에 있는데,
   `particleInstanceOverride`(SceneDocument.swift:2497)가 `float()`/`vec3()` 로 정적 `value` 만
   언랩한다. `PropertyAnimation.parse(bind)` 를 같은 자리에서 병행 캡처하면
   `maintaindistancebetweencontrolpoints` 의 움직이는 컨트롤포인트가 살아난다
   (`controlpointangle1` 4블록은 CP 회전 표현이 없어 별건).
2. **오브젝트 애니 키 목록이 5개로 고정돼 있다**(SceneDocument.swift:1352
   `["origin", "scale", "alpha", "angles", "color"]`). WE 의 바인딩 파서는 프로퍼티 키를
   가리지 않는다 — 어떤 바인딩에나 `animation` 이 붙을 수 있다.
3. `PropertyAnimation` 에 `wrapLoop` 필드가 생겼다. 라운드트립(ProjectJSONBuilder 등)에서
   애니를 다시 쓰는 자리가 있으면 `options.wraploop` 를 함께 내보내야 한다.

---

## 7. `condition` — 표시 조건식

### 7.1 문법의 정체

`condition` 은 **AngularJS 표현식**이다. 브라우저 UI 가
`W.evalCondition = function(e) { return ta.$eval(e, W.currentSelection.properties[location]) }`
(`scripts.js` @106522), 에디터 프로퍼티 목록이
`l.evalCondition = function(e) { return l.$eval(e, l.pConditionScope || l) }`(@375231),
플러그인 설정 모달까지(@613769) 모두 같은 `$eval` 을 쓴다.
템플릿은 `ng-if="!property.condition || evalCondition(property.condition)"` 이므로
**부재/빈 문자열은 표시**다. 그룹도 같다(`browseruserpropertiesgroup.html`).

로컬 객체가 **프로퍼티 객체 자체**라 조건식이 `foo.value` 로 값을 읽는다 — Waple 이 `.value`
접미사를 떼는 규약의 근거다. 바이너리 쪽은 `condition` 문자열(`0x140474a60`)을 바인딩 파서가
읽어 보관만 하고(0x1401a4f11), 평가는 UI(JS) 몫이다.

브라우저 경로에는 정규화가 하나 더 있다: `l.condition = l.condition.replace("$","")` — **첫 `$` 하나**를
지운다(@88419). 에디터 경로에는 없다. Waple 은 이 정규화를 하지 않는다(설치본 코퍼스 도달 0).

### 7.2 실물 조건 코퍼스 (설치본 전수, 22건 / 고유 16종)

| 형태 | 건수 | Waple |
|---|---:|---|
| `effect.value.endsWith('…') === true …` / `startsWith(…) === false` | **9** | 이번에 지원(§7.3) |
| `scene.value !== 'cartoon' && scene.value !== 'ram'` | 3 | 지원 |
| 맨 숫자 리터럴 `1` / `0` | 5 | 지원 |
| `style.value=='1'` · `showbottom.value > 0` · `rainbowscheme.value` | 3 | 지원 |
| 빈 문자열 | 1 | 지원(항상 표시) |
| `[a,b].includes(x)` 배열 형태 | **0** | 종전부터 지원 |

즉 **종전 미지원 형태가 22건 중 9건**이었고, 종전부터 지원하던 배열 `includes` 는 이 코퍼스에
한 건도 없다.

### 7.3 이번에 고친 것

`ident.startsWith('lit')` / `endsWith` / `includes` 를 토큰화 전에 `true`/`false` 로 접는다
(`replaceIncludes` 와 같은 방식). 좌변이 문자열일 때만 접고, 숫자·불리언이면 손대지 않는다
(JS 에서도 그 메서드가 없어 TypeError). 좌변 부재는 빈 문자열로 접는다 — `canEvaluate` 가
값 없이(`[:]`) 문법 가능 여부만 묻는 경로를 살리기 위한 것이고, `replaceIncludes` 가 부재를
"어느 리터럴과도 불일치" 로 접는 것과 같은 방향이다.

### 7.4 남은 어긋남(고치지 않음, 도달 0)

- **`==` vs `===`**: Waple 은 둘을 같게 본다(양쪽이 수로 읽히면 수 비교). JS 는 `===` 가 타입까지 본다.
  실물 코퍼스에서 `'1'` 대 `1` 같은 교차 타입 비교는 어느 쪽으로 읽어도 결과가 같다.
- **산술 연산자**: Waple 의 토크나이저는 `+ - * / %` 를 만나면 조건 **전체를 파스 실패**로 돌린다
  (부분 평가 금지 — 의도된 설계). Angular 는 지원한다. 코퍼스 도달 0.
- **비교 연산의 결합**: Waple 의 `parseComparison` 은 비결합이라 `a > b == c` 를 파스 실패로 낸다.
  Angular 는 `(a>b) == c`. 코퍼스 도달 0.

---

## 8. `PropertyDecoration` — 장식 프로퍼티

WE 브라우저 템플릿(`views/includes/browseruserproperties.html`, `scripts.js` 오프셋 750144–757383)이
아는 `type` 은 열둘이다:
`color · bool · textinput · slider · volume · combo · combolutfilters · directory · file ·
scenetexture · usershortcut · divider` (+ 그룹 컨테이너 `group`).

이 중 **`divider` 만 편집 위젯 없이 `<hr class="fullWidth">` 하나를 그린다** — WE 자신의 스키마에
장식 타입이 하나 있는 셈이라 `isDecoration` 에 넣었다.
`volume` 은 타입 자체가 장식은 아니고, 오디오 출력이 꺼져 있으면 **라벨만** 숨긴다
(`isPropertyLabelVisible`) — 표시/비표시 판정이 아니라 라벨 가시성이라 Waple 의 관심 밖이다.

설치본 코퍼스의 프로퍼티 `type` 분포는 `color 203 · slider 18 · combo 14 · bool 7 · checkbox 2`
로 `divider` 0건, `imgsrc*` 키 0건이다. 즉 종전 휴리스틱(imgsrc/`<img`/`<a`/`<hr`)과 새로 넣은
`divider` 는 **둘 다 이 코퍼스 도달 0** 이고, 근거는 각각 워크샵 실측(WaifuX)과 WE 템플릿이다.
