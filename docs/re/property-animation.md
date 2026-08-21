# WE 프로퍼티 애니메이션(키프레임) — 실물 대조

대상: `wallpaper64.exe` (imagebase `0x140000000`), 동봉 자산
`Sources/WapleRender/Resources/WEAssets/`, 설치본 `wallpaper_engine/assets/`·`projects/`,
에디터 UI `ui/dist/scripts/scripts.js`, 라벨 `locale/ui_en-us.json`. 조사일 2026-08-21. 모든 주소는 VA.

---

## 0. 요약 — Waple 과 어긋났던 것

| # | 항목 | WE 실물 | 종전 Waple | 실측 어긋남 | 조치 |
|---|---|---|---|---|---|
| 1 | 베지어 핸들 **x 스케일** | `P1x = f0 + 0.5·dx·front.x`, `P2x = f1 + 0.5·dx·back.x` (VA 0x1401a9d60) | `f0 + front.x` (스케일 없음) | 값 범위의 **13.71%** | **수정** |
| 2 | `options.wraploop` | 끝점 키프레임을 첫 키프레임과 같게(VA 0x1401a98b0–0x1401a9bb3) | 미파스·미소비 | 후반 절반 정지 — 코퍼스 Δ 최대 **291.0**(=범위 전체), **Waple 이 지금 파스하는 블록**만 보면 **126.1** | **수정** |
| 3 | 키프레임 `step` | 오른쪽 키프레임 flag bit2 → 구간을 왼쪽 값으로 고정(VA 0x1401a9d18) | 미파스 | 자산 도달 0(에디터 저작 가능) | **수정** |
| 4 | `mode` 비교 | `stricmp`, 미인식 문자열은 **loop** (VA 0x1401a8c78/0x1401a8c91) | 대소문자 구분 + 미인식은 **클램프** | 자산 도달 0 | **수정** |
| 5 | 구간 탐색 경계 | 반개구간 `k1 ≤ f < k2` (VA 0x1401a9cd8) | 닫힌구간 | step 도입 전에는 무영향 | **수정** |
| 6 | 시간 → 값 | 정수 프레임 2개 샘플 + 선형 보간(VA 0x1401723d8) | 연속 프레임 직접 평가 | ≤ 0.16%(아래 §5) | **유지 + 반증 주석** |
| 7 | 근 찾기 | `u=0`에서 0.999 반감, `abs(X−f) < 0.01` 프레임, 1000회 상한 | [0,1] 24회 이분법 | WE 쪽이 최대 0.02 덜 수렴 | **유지**(Waple 이 더 정확) |
| 8 | `fps`/`length` 부재 | 애니 **전체 드롭**(VA 0x1401a9714, 0x1401a8c21) | 30fps·마지막 키프레임 길이로 대체 | 도달 0 | 유지 + 주석 |
| 9 | `c0..c3` 누락 채널 | **캐스케이드 중단**(c0 없으면 0트랙, c0+c2 면 c2 유실) | 빈 트랙으로 자리 유지 | 도달 0(전수 연속) | 유지 + 주석 |
| 10 | 키프레임 순서 | 정렬 안 함, `frame ≤ 직전` 을 **드롭**(초기 −1) | 정렬 | 도달 0 | 유지 + 주석 |
| 11 | `relative` | **키 존재만** 확인(값 무시) → `false` 도 상대 | bool 값을 읽음 | 도달 0(1건, true) | 유지 + 주석 |
| 12 | `options.random` | flags bit2 을 **세우기만 하고 읽는 곳이 0건**(§2.6 — 함수 전체 추적 스윕) | 없음 | 도달 0 | **반증** — 구현하지 않는다 |
| 13 | `lockangle`/`locklength`/`magic` | 바이너리 xref **0건** — 에디터 전용 | 이미 무시 | — | 확인(종전 주석이 옳았다) |
| 14 | `events` 발화 경계 | `oldTime ≤ e.t < newTime`(초 단위) | `prevF < m ≤ curF`(프레임) | 한 틱 | 유지 + 주석 |
| 15 | 애니 스키마 **bool 타입 게이트** | 여섯 자리 다 `cmp byte [..+8], 5` 지만 **실패 분기가 갈린다** — 옵션 3키·`step` 은 false, 핸들 `enabled` 둘은 **true**(§2.5) | 맨 `as? Bool` — `JSONSerialization` 의 `1` 이 **true** 로 샘 | 도달 0(코퍼스 bool 전수가 진짜 bool) | **수정**(false 부류는 게이트, 핸들은 기본 켜짐) |
| 16 | `wraploop` × `mode` | **직교** — 런타임에 모드 게이트가 없다(§2.4) | (해당 없음) | 도달 0(`true` 2블록 다 `loop`) | 확인 + 테스트로 못박음 |
| 17 | `options` 블록 부재 | 태그 7 아니면 애니 **전체 드롭**(0x1401a56a6/0x1401a96bb) | 빈 딕셔너리로 관용 | 도달 0 | 유지 + 주석 |
| 18 | 핸들 `enabled` **폴라리티** | 객체이기만 하면 기본 **enabled** — 끄는 건 진짜 bool `false` 뿐(0x1401a8ebb back / 0x1401a8f1c front) | 미커밋 변경이 옵션용 게이트를 걸어 **반대로** 만들었다 | 도달 0(핸들 76/76 명시 bool) | **반증 + 되돌림** |

---

## 1. 자산 전수 조사 — 실제로 등장하는 키

동봉 트리 + 설치본(`assets/`, `projects/`) 전체 JSON 을 훑어 `"animation"` 객체를 전수 수집했다.
**애니 블록 7개 / 파일 6개**가 전부다(동봉 트리와 설치본이 같은 집합).

```
animation 블록 키 : c0×7  options×7  c1×6  c2×6  relative×1        (c3 는 0)
keyframe 키       : frame×38  value×38  front×38  back×38  lockangle×38  locklength×38
handle 키         : enabled×76  x×76  y×76  magic×56      (키프레임 38 × front/back 2면)
options 키        : fps×7  length×7  mode×7  wraploop×7
```

관측 값 분포: `mode` = loop 6 / mirror 1 · `wraploop` = `true` 2 / `null` 5 ·
`fps` = 20×4, 30×2, 15×1 · `length` = 60×6, 30×1.

**preview / non-preview 분리**(저장소 규약 `scripts/spec/measure_material_schema.py:is_preview` —
경로 세그먼트(basename 제외) 중 `preview` 로 **시작**하는 것이 있는가):

| | 블록 | 파일 |
|---|---:|---:|
| preview | 4 | 4 |
| non-preview | **3** | **2** |

`wraploop` 은 7블록 전건에 키가 있다(preview 4 / non-preview 3). 값이 `true` 인 **2블록은 둘 다
non-preview** 이고 같은 파일이다 —
`scenes/particleelementpreviews/maintaindistancebetweencontrolpoints/scene.json` 의
`/objects/0/origin` 과 `/objects/1/instanceoverride/controlpoint1`.
(`particleelementpreviews` 는 `particle` 로 시작하므로 위 규약상 preview 가 아니다. 이름만 보고
"프리뷰라 무시해도 된다" 고 읽으면 안 된다 — 이 후처리는 실제로 발화한다.)
`null` 5블록은 preview 4 + non-preview 1(`presets/magic/preset.json`)이다.

**`random`·`startpaused`·`events` 는 두 트리 어디에도 없다**(0/7). 설치본 `projects/` 트리에는
`animation` 블록 자체가 0건이다 — 동봉 트리와 `assets/` 가 바이트 동일이므로 코퍼스는 사실상
이 7블록이 전부다.

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
  두 `enabled` 는 **부재·비-bool 이 true** 다 — §2.5 의 폴라리티 표를 볼 것.

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
`init` 의 반환값을 `dil` 에 잠깐 피신시켜 두고(0x1401a9861) 그 뒤에 세우므로, **`init` 이 false 를
돌려도 bit4 는 세워진다** — 어차피 호출부가 애니를 통째로 버리므로 관측 가능한 차이는 없다.

**`options` 블록 자체가 태그 7(object)이어야 한다.** 옵션 파서 진입부 `0x1401a96bb
cmp byte ptr [rcx+8], 7` → `jne 0x1401a989b`(= `xor al,al; ret`)이고, 호출부도 파서를 부르기 전에
같은 검사를 한 번 더 한다(`0x1401a56a6 cmp byte ptr [r15+8], 7` → `jne 0x1401a57e1`).
`find` 가 못 찾으면 널 싱글턴(0x140084ac0)을 돌려 태그 0 이 되므로 **`options` 부재 = 애니 드롭**이다.

#### 키별 요구·기본값 (부재/타입 불일치 시)

| 키 | jsoncpp 태그 게이트 | WE 의 부재 동작 | Waple |
| --- | --- | --- | --- |
| `options`(블록) | 7 object — 0x1401a56a6 / 0x1401a96bb | **애니 전체 드롭** | 빈 딕셔너리로 관용 |
| `length` | 1–3 numeric — 0x1401a9714 (`dec eax; cmp eax,2; ja`) | **애니 전체 드롭** | 마지막 키프레임 frame |
| `fps` | 1–3 numeric — 0x1401a9723 | **애니 전체 드롭**(추가로 `fps<=0`·`length/fps<=0` 도 드롭) | 30 |
| `mode` | 4 string — 0x1401a9828 `cmp dl,4`; 아니면 `xor ecx,ecx`(NULL) | NULL → stricmp 건너뜀 → flags 0 = **loop** (0x1401a8c67 `test rcx,rcx`, 0x1401a8c6c 빈 문자열도 동일) | 같음 |
| `random` | 5 bool — 0x1401a97f9 | **false** (그리고 세워도 읽는 곳이 없다 — §2.6) | 파스 안 함 |
| `startpaused` | 5 bool — 0x1401a97df | **false** | 같음 |
| `wraploop` | 5 bool — 0x1401a985d | **false** | 같음 |

인자 배치 확인(x64): `rcx`=mode · `xmm1`=fps · `r8d`=length(`asInt` 0x1401a9815) ·
`r9`=out · `[rsp+0x20]`=random(0x1401a9850) · `[rsp+0x28]`=startpaused(0x1401a9845).

> **주입기 기본값 ≠ 바인더 기본값.** 에디터가 *새로 만들 때* 쓰는 값은
> `{fps:30,length:60,mode:"loop",wraploop:!0}`(scripts.js char@238870)로 `wraploop` 이 **true** 다.
> 자산 JSON 을 *읽는* 쪽이 따라야 하는 건 바인더 기본값 **false** 다. 주입기 기본값을 부재
> 기본값으로 옮기면 `wraploop` 을 안 적은 애니가 전부 랩된다.

상태 구조체(= 애니 객체 `+0x38`):

```
+0x00 f32 1/fps   +0x04 f32 time(초)   +0x08 f32 length/fps(초)   +0x0c u32 flags   +0x10 i32 length
+0x18..+0x28 vector<Event>(stride 0x28)          ; 애니 객체 기준 +0x50
```

flags: `0x1` mirror · `0x2` single · `0x4` random · `0x10` wraploop · `0x20000000` startpaused ·
`0x40000000` single 종료 · `0x80000000` 미러 역주행.

### 2.4 `wraploop` 후처리 `0x1401a98b0–0x1401a9bb3`

`.pdata` 조각 6개가 사슬로 이어진 하나의 함수다(`merged()` 기준). 종전 판이 적은 끝
`0x1401a9b90` 은 xmm 복원 라벨이지 함수 끝이 아니다 — `ret` 은 `0x1401a9ba6` 이고 그 뒤에
noreturn 스텁 둘(`0x1401a9ba7` · `0x1401a9bad`)이 붙는다.

호출부 `0x1401a5762`:

```
if ([anim+0x44] & 0x10) {                     ; options.flags bit4 — **모드 검사 없음**
    rdi = [anim+0x28]                         ; tracks.end
    rbx = [anim+0x20]                         ; tracks.begin
    while (rbx != rdi) {
        wrapLoop([anim+0x48] /*ecx = length, i32*/, rbx /*rdx = &track*/)   ; 0x1401a5780/0x1401a5784
        rbx += 0x30                           ; Track stride
    }
}
```

인자 순서는 **`(int length, vector<Keyframe>* track)`** 이다(종전 판이 `(track, length)` 로 적었다).
`Track` 은 `vector<Keyframe>`(+0x00) + 프레임 캐시 `vector<float>`(+0x18) = 0x30 이고,
`Keyframe` stride 는 **0x1c** 다 — 0x1401a98d9 `imul rax, 0x6db6db6db6db6db7`(÷7)와
0x1401a98fb `imul rax, rax, 0x1c` 가 그 증거다.

본체:

1. 키프레임 2개 미만이면 반환(0x1401a98dd `cmp rax,1` / `jbe`).
2. 첫 키프레임의 `value`(`xmm7` ← `[begin+4]`)·`front` 8바이트(`xmm6` ← `[begin+0x14]`)·
   `flags`(`r10d` ← `[begin+8]`)를 보관(0x1401a98e7–0x1401a9904). **트리밍 전에** 읽고,
   트리밍은 뒤에서만 pop 하므로 `begin` 이 움직이지 않는다.
3. `last.frame > length` 인 동안 pop_back(0x1401a9920–0x1401a9959). 루프 머리에서
   `count <= 1` 이면 더 안 지우고 나간다 → **최소 1개는 남는다**. 그 뒤 다시 `count <= 1`
   이면 0x1401a9b90 으로 빠져 **아무것도 쓰지 않고** 반환한다(0x1401a996e `jbe`) —
   즉 지운 것을 되돌리지 않는다.
4. `last.frame == length` 면 그 키프레임을 재사용(0x1401a999b `je 0x1401a9b45`),
   아니면 `{frame=length, 나머지 전부 0}` 을 **append**(0x1401a99b5–0x1401a99c4, 용량이 모자라면
   0x1401a99d2 재할당 경로). append 된 끝점은 front 가 0/disabled 이고 step 비트도 0 이다.
5. 두 경로가 같은 꼬리(0x1401a9b45–0x1401a9b8b)로 합류해 끝점에 기록한다:
   `value = kf0.value`(0x1401a9b8b `movss [rcx-0x18], xmm7`).
   `kf0.flags & 2`(front enabled)면 `flags |= 1`(back enabled) + `back = −kf0.front`
   (0x1401a9b48 `test r10b,2` → 0x1401a9b58 `xorps` 부호마스크 `0x140492ff0` = `{0x80000000}×4`,
   저장 0x1401a9b5f `movsd [rcx-0x10]` = backX·backY 동시).
   아니면 `flags &= ~1`(0x1401a9b66) — **backX/backY 는 지우지 않는다**.
   덮기 경로에서 끝점의 `front`(bit1)와 `step`(bit2)은 손대지 않는다.

에디터 라벨이 그대로 규약이다:
`ui_editor_animation_modal_loop_wrap_help_body` = *"Sets the last frame of the animation equal to the
first frame, resulting in a smooth loop that ends exactly where it starts."*

**"마지막 키프레임 → 첫 키프레임 보간 허용" 가설은 반증됐다.** 평가기(0x1401a9bc0)와 시간 진행
(0x1401a9f60)은 bit4 를 **아예 읽지 않는다**(§2.6 의 flags 리더 전수). 순환 구간이 생기는 게 아니라
파스 시점에 키프레임 배열이 다시 쓰인다. 구별되는 관측 세 가지:

- 끝점의 들어오는 핸들이 `kf0.back` 이 아니라 **`−kf0.front`** 다. 순환 보간이라면 마지막→첫
  구간이 `last.front` / `kf0.back` 을 쓴다.
- `frame > length` 인 키프레임이 **파괴**된다(순환 보간에는 없는 부작용).
- `frame == length` 가 이미 있으면 붙이는 게 아니라 **덮는다**.

`−kf0.front` 가 하는 일도 정확히 적어 둔다. §3.1 의 제어점 규약이
`P1 = P0 + (0.5·dx·front.x, front.y)` / `P2 = P3 + (0.5·dx·back.x, back.y)` 라 x 에 구간폭 `dx` 가
곱해지므로, 끝점의 나가는 기울기가 frame 0 의 들어오는 기울기와 **정확히** 같아지는 것은
마지막 구간폭이 첫 구간폭과 같을 때뿐이다. 동봉 두 블록은 키프레임 0/30 + 끝점 60 이라 `dx` 가
둘 다 30 — 정확히 맞는다. 일반 저작에서는 "핸들 부호반전" 이지 "기울기 일치" 가 아니다.

**`mode` 와 직교한다.** 호출부는 `test byte ptr [r13+0x44], 0x10` **하나만** 보고 mode 비트
(bit0 mirror / bit1 single)를 보지 않는다. 옵션 파서도 mode 와 무관하게 bit4 를 세운다
(0x1401a9881). 즉 `{"mode":"mirror","wraploop":true}` 는 "랩된 트랙을 미러 재생" 으로 **둘 다**
걸린다. `"loop"` 강제는 에디터 저작 측 제약뿐이다(§4).

**Waple 파스 도달은 코퍼스 도달과 다르다.** `true` 2블록 중
`/objects/1/instanceoverride/controlpoint1` 은 `SceneDocument` 가 `instanceoverride` 애니를
드롭해서(§6.1) `PropertyAnimation.parse` 에 닿지 않는다 — 지금 실제로 이 후처리를 타는 것은
`/objects/0/origin` **하나**다.

### 2.5 애니 스키마의 bool 타입 게이트 — 태그 5 검사는 여섯 자리 다, 폴라리티는 둘

`animation` 스키마에서 bool 을 읽는 자리는 여섯이고, **전부** `cmp byte ptr [..+8], 5` 로
jsoncpp 태그를 먼저 보고 통과할 때만 `asBool`(0x140086300)을 부른다. 다만 **검사가 실패했을 때
무엇이 되는지가 두 부류로 갈린다** — 이 문서의 종전 판이 여섯을 한 덩어리로 묶어
"태그 5 아니면 전부 false" 라고 적은 것은 **틀렸다**(2026-08-21 재검증에서 반증).

| 자리 | 태그 검사 | 실패 분기 타깃 | 부재·비-bool 결과 |
| --- | --- | --- | --- |
| `options.wraploop` | 0x1401a985d | `jne 0x1401a9887`(`or` 를 건너뜀) | **false** |
| `options.startpaused` | 0x1401a97df | `jne 0x1401a97f6` → `xor r13d, r13d` | **false** |
| `options.random` | 0x1401a97f9 | `jne 0x1401a9810` → `xor edi, edi` | **false** |
| 키프레임 `step` | 0x1401a8f77 | `jne 0x1401a8faf` → `xor sil, sil` | **false** |
| `back.enabled` | 0x1401a8ebb | `jne 0x1401a8eed` → **`mov bpl, 1`** | **true** |
| `front.enabled` | 0x1401a8f1c | `jne 0x1401a8f4e` → **`mov r14b, 1`** | **true** |

핸들 두 자리만 폴라리티가 반대다. `back`/`front` 가 **객체(태그 7)이기만 하면**
(바깥 검사 0x1401a8e94 `cmp byte ptr [r15+8], 7` / 0x1401a8ef5 `cmp byte ptr [r14+8], 7`)
`enabled` 는 **기본 켜짐**이고, 끄는 방법은 **진짜 bool `false` 하나뿐**이다. 핸들 자체가 없거나
객체가 아니면 그때만 disabled 다. 레지스터 대응도 확정해 둔다 — **r15 = `back`**(find 0x1401a8e2d),
**r14 = `front`**(find 0x1401a8e54). 종전 판이 두 VA 의 이름을 뒤집어 적었다.

> 이 폴라리티는 **관측 가능하다**. `{"front":{"x":1,"y":5}}` 처럼 `enabled` 를 생략한 핸들을
> WE 는 그 핸들로 곡선을 휘게 읽는다. 반대로 `{"front":{}}` 는 enabled 지만 x/y 가 0 이라
> 결과가 disabled 와 같다(`P1 = P0`) — 그래서 "빈 객체" 로는 차이가 안 보이고 x/y 가 있어야 보인다.

**태그 게이트 자체는 하중을 받는다.** `asBool` 은 관대하다 — 태그 1/2(int/uint)를
`cmp qword ptr [rcx], 0; setne al`(0x14008634b)로, 태그 3(real)을 double 비교(0x14008632e)로
받아 **`1` 을 true 로 돌려준다**. 태그 0(null)만 `xor al, al`(0x14008635a)이다. 앞단 태그 검사가
없었다면 WE 도 `"wraploop": 1` 을 true 로 읽었을 것이다. 그래서 **false 부류 네 자리**에는 이
게이트가 필요하고, **true 부류 두 자리**에는 같은 게이트를 옮기면 오히려 원본과 갈린다.

Waple 쪽 사고는 반대 방향에서 같은 자리였다. Foundation 의 `JSONSerialization` 은 숫자와
불리언을 똑같이 `NSNumber` 로 주고 Swift 동적 캐스트가 둘을 섞는다 — 리눅스 실측으로
`{"wraploop":1}` → `as? Bool` == **true**, `{"wraploop":1.0}` → **true** 다
(`"true"`·`null` 은 nil 이라 우연히 맞았다). 그래서 `EffectManifest.isJSONBool`
(`NSNumber.objCType == "c"`)로 먼저 가른다.

**코퍼스 도달 0** — 애니 7블록의 bool 값을 전수 타입 census 하면 `wraploop` null×5 / bool×2,
`front`/`back` 의 `enabled` 는 **양면 합쳐 bool×76**(키프레임 38 × 2면, 전부 진짜 bool)이고
`step`·`random`·`startpaused` 는 아예 없다. 숫자·문자열로 적힌 bool 도, `enabled` 를 생략한
핸들도 한 건도 없으므로 두 규칙 다 동봉 코퍼스 위에서 **비트 동일**이다. 손으로 저작된 값만 갈린다.

Waple 구현은 두 부류를 갈라 옮겼다 — `PropertyAnimation.parse` 의 `b()` 가 false 부류
네 자리(`wraploop`·`startpaused`·`step`, 그리고 읽지 않는 `random`)를, `handleEnabled()` 가
핸들 두 자리를 맡는다. 테스트는 `PropertyAnimationOptionsTests` ③(false 부류) ·
③-2(핸들 폴라리티)가 각각 못박는다.

### 2.6 `options.random` — 죽은 비트(반증)

파서는 형제 5키와 **완전히 같은 모양**이다: `find "random"`(0x1401a9777) → 태그 5 검사
(0x1401a97f9) → `asBool`(0x140086300) → 5번째 인자 `[rsp+0x20]`(0x1401a9850) →
`or dword ptr [rbx+0xc], 4`(0x1401a8ca5). 그런데 **읽는 곳이 없다.**

측정 방법(재현 가능):

1. `.text`(rawsize `0x424a00` = 4,344,320바이트)를 **재동기 선형 스윕**한다 — capstone 이 데이터에
   막히면 1바이트 전진해 다시 붙인다. 명령 **1,146,785개**.
2. `.pdata` 를 사슬 병합한 함수 단위로 나눈다.
3. 각 함수에서 `mov/movzx r, [X+0xc]` 또는 `[X+0x44]` 로드를 시작점으로 잡고 **함수 끝까지**
   레지스터 복사(`mov r2, r1`)를 따라가며, bit2 가 선 즉시값으로 `test`/`and`/`bt`/`cmp` 하는
   자리를 모은다. 메모리 직접 형태(`test byte ptr [X+0xc], 4`)도 같이 센다.

결과: 바이너리 전체 **54건**, 애니 코드 **0건**. 애니 영역 유일 히트인
`0x1401aa147 and dword ptr [rbx+0xc], 0x7fffffff` 는 미러 방향비트를 지우는 마스크라 bit2 를
**보존**한다(읽지 않는다). 나머지 53건은 CRT·텍스처 포맷·오디오 등 다른 구조체의 `+0xc` 다.

애니 상태 flags 를 실제로 읽는 자리는 이게 전부이고 **전부 다른 비트**다:

| VA | 무엇 |
| --- | --- |
| 0x1401a9f69 → 0x1401a9f73 | `test r14d, 0x60000000` — bit29 startpaused \| bit30 single 종료 |
| 0x1401a9f88 | `and r15d, 2` — bit1 single |
| 0x1401a9fb7 | `shr r12d, 0x1f` — bit31 미러 역주행 |
| 0x1401aa055 | `test r14b, 1` — bit0 mirror |
| 0x1401aa147 / 0x1401aa165 | bit31 토글 |
| 0x1401aa181 | bit30 single 종료 세우기 |
| 0x1401a5762 | `test byte ptr [r13+0x44], 0x10` — bit4 wraploop |
| 0x1401707f7 · 0x14017080e | 스크립트 `play()` — bit30 검사 후 bit29\|30 클리어 |
| 0x140170827 | `pause()` — bit29 세우기 |
| 0x140170837 · 0x140170845 | `stop()` — bit29 세우고 bit30\|31 클리어 |
| 0x140170867 | `isPlaying()` — `(flags & 0x60000000) == 0` |

> **고정 창 스윕으로는 이 판정을 못 한다.** 로드 `0x1401a9f69` 에서 bit0 검사 `0x1401aa055` 까지가
> **65 명령**이라 20명령 창이면 대조군(mirror)조차 못 찾는다. 이 문서의 종전 판이 그 창으로
> "대조군을 전부 찾아낸다" 고 적었던 것은 사실이 아니었다(2026-08-21 재검증에서 정정).
> 함수 전체 추적으로 바꾸면 대조군 bit0·bit1·bit4·bit29/30 이 전부 잡히고 bit2 만 0 이다.

에디터도 안 쓴다. 로케일에 `ui_editor_animation_modal_random_start_frame`("Random start frame")이
남아 있지만 `ui/` 전체에서 그 키를 참조하는 곳이 **0건**이다(형제 `..._start_paused` 1건 ·
`..._loop_wrap` 3건 — `grep -ro` 전수). 애니 옵션 화이트리스트에도 없다:
퍼펫 `case"length":case"fps":case"wraploop":case"smoothing":case"stiffness":case"mode":case"events"`
(char@235954), 카메라경로는 같은 형태에서 `wraploop`/`mode`/`events` 만(char@281098).

자산 도달도 0 — 동봉·설치본 애니 7블록 전수에 키 자체가 없다.

세 층(런타임·에디터·자산) 모두에서 흔적만 남은 키라 의미를 확정할 근거가 없다. **구현하지 않는다.**

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

`ui/dist/scripts/scripts.js` (바이트 1,187,134 / 문자 1,186,896 — **아래 `@` 는 전부 문자 오프셋**이다.
UTF-8 이라 두 값이 최대 238 만큼 다르므로 `grep -b` 로는 재현되지 않는다. 재현:
`open(p,'rb').read().decode('utf-8').find(pat)`):

- 새 프로퍼티 애니의 기본 옵션은 `{fps:30,length:60,mode:"loop",wraploop:!0}`(@238870) —
  **`wraploop` 이 `true`** 다. 퍼펫은 `{length:10,fps:10,mode:"loop",wraploop:!0,smoothing:0,
  stiffness:1}`(@235782), 카메라 경로는 `{length:10,fps:10,mode:"single",wraploop:!1}`(@280948).
  이 셋은 **주입기(에디터가 새로 만들 때) 기본값**이고, 자산을 *읽는* 쪽이 따라야 하는
  바인더 기본값은 §2.3 표의 **false** 다. 둘을 섞으면 `wraploop` 을 안 적은 애니가 전부 랩된다.
- `wraploop` 은 **`mode === 'loop'` 일 때만** 저장된다(`"loop"!==e.mode&&delete e.wraploop`, @575499).
  체크박스 자체도 `ng-if="settings.mode === 'loop'"`(@810392) 로 숨는다.
  런타임은 모드와 무관하게 flag 를 소비하므로(§2.4) 이건 **저작 측 제약**이다.
- 켜는 순간 `frame >= length` 인 키프레임을 지우고(@575938 — 런타임의 `frame > length` 와 달리
  **경계를 포함**한다) 곡선을 다시 만든다.
  탄젠트 자동계산도 랩어라운드로 바뀐다(`I() = wraploop && mode==='loop'`, @555215).
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
3. **[미해결] `length` 가 정수가 아니면 끝점 프레임과 루프 주기가 갈린다.** WE 는 `asInt`
   (0x1401a9815)로 **한 번** i32 화해 끝점 프레임에도 루프 주기에도 같은 정수를 쓴다. Waple 은
   끝점만 `length.rounded(.towardZero)` 로 절단하고 `PropertyAnimation.length` 는 Float 를
   유지한다 — `length: 45.9` 면 끝점은 frame 45 인데 loop 랩은 45.9 에서 일어난다.
   동봉·설치본 7블록의 `length` 는 전수 정수(60×6 · 30×1)라 **도달 0**. 고치지 않은 이유는
   `length` 자체를 절단하면 wraploop 과 무관한 모든 애니의 loop/mirror 주기가 바뀌기 때문이다.
   키프레임 `frame` 도 같은 성격이다(WE `asInt` 0x1401a8fb5 ↔ Waple Float, 코퍼스 전수 정수).
4. `SceneDocument.swift` 의 상수 애니 주석이 `{animation:{...}}` 를 **"55씬/287건"** 이라고
   적는데, 동봉 트리에서 `"animation"` 키가 딕셔너리인 자리는 **전 트리 통틀어 7건**뿐이다
   (2026-08-21 전수 census). 그 수치는 다른 코퍼스(워크샵)에서 온 것으로 보인다 — 이 레인 밖이라
   손대지 않았지만, 동봉 도달을 그 숫자로 읽으면 안 된다.
5. `PropertyAnimation` 에 `wrapLoop` 필드가 생겼다. 라운드트립 걱정은 **지금은 없다** —
   `Sources/` 전체에서 `"animation"` 을 **쓰는**(직렬화하는) 자리가 0건이고
   `ProjectJSONBuilder.swift` 는 12행짜리로 애니를 다루지 않는다(2026-08-21 실측).
   애니를 다시 내보내는 자리가 생기면 그때 `options.wraploop` 를 함께 써야 한다 —
   `wrapLoop` 필드를 보존용으로 남겨 둔 이유가 그것이다(트랙에는 이미 구워져 있어서
   랩된 트랙을 그대로 쓰면 끝점 키프레임이 하나 늘어난 채로 나간다).

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
