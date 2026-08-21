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
| 19 | `step` 이 서면 **핸들을 안 읽는다** | `mov r13d,4`(0x1401a8fed) → `jmp 0x1401a910a` 로 back/front 블록 두 개를 통째로 건너뛴다 — flags bit0·bit1 미설정, 좌표 넷 전부 0 | `step` 만 담고 핸들은 그대로 파스 → **step 키프레임의 오른쪽 구간이 다른 곡선** | 도달 0(`step` 키 0/38 키프레임) · 합성 반례에서 40.535 ↔ 25.000 | **수정**(2026-08-21 클러스터 K) |
| 20 | 구간 **왼쪽 끝점 정확 일치** | 곡선을 풀지 않고 `kf[i-1].value`(0x1401a9d0f `cmp r9d,ebx` → `je 0x1401a9ec0`) | 항상 이분법으로 풀었다 | 도달 0(코퍼스 `front.x` 전수 양수라 X(u) 단조) · 합성 반례에서 166.081 ↔ 100.000 | **수정**(동상) |
| 21 | **숫자 자리의 태그 게이트** | 숫자 여덟 자리 전부 태그 **1..3만** 통과(`dec eax; cmp eax,2; ja`) — bool(태그 5)은 탈락 | 리눅스 Foundation 이 `true` 를 `NSNumber` 로 줘서 `as? Double` == **1.0** → `{"x":true}` 가 좌표 1.0, `{"fps":true}` 가 1fps | 도달 0(여덟 자리 값 타입 census 전건 int/float) | **수정**(동상 — `isJSONBool` 게이트) |
| 22 | **애니 유효 게이트** | **트랙 수 == 프로퍼티 성분 수** 일 때만 애니가 산다 — 등록기가 `sete al`(0x14017679e) → `mov byte ptr [r15+0x18], al`(0x1401767a1), 소비자가 그 바이트로 게이트(0x14017241f) | (해당 없음 — `PropertyAnimation` 은 성분 수를 모른다) | 도달 0 | 문서화 + 넘길 것(§6.7) |
| 23 | `fps <= 0` / `length <= 0` | `init` false(0x1401a8c21 / 0x1401a8c43) → 트랙 0개 → 22 의 게이트가 꺼져 **정적 `value`** | `fps: 0` → 프레임 0 고착 · `length: 0` → 첫 키프레임 고착 | 도달 0 | **수정**(`parse` → `nil`) |
| 24 | `value`/`frame` 비숫자 | **그 키프레임만** 건너뛴다(0x1401a8e7d/0x1401a8e8e → `0x1401a9319` = **루프 진행부**) | 애니 **전체** 드롭 | 도달 0 | **수정** |
| 25 | `length` · 키프레임 `frame` 의 **i32 화** | `asInt` 한 번(0x1401a9815 / 0x1401a8fb5, 태그 3 은 `cvttsd2si` = 0 방향 절단) — 끝점 프레임과 루프 주기가 같은 정수 | `length` 는 Float 유지(끝점만 절단) · `frame` 도 Float | 도달 0(전수 정수) | **수정** |
| 26 | 키프레임 0개 트랙 | **0.0**(0x1401a9bfd) — 단 22 의 게이트를 통과했을 때만 도달 | `base` 유지 | 도달 0 | **유지**(§5.1 — 22 없이 옮기면 더 나빠진다) |
| 27 | `condition` 의 equality/relational | **두 레벨** · 각각 좌결합 **반복**(vendor.js @167616 / @167789) | 여덟 연산자 한 레벨 · **1회** 소비 → 연쇄는 파스 실패 | 도달 0(연쇄 22건 중 **0건**) | **수정**(§7.4) |

---

## 1. 자산 전수 조사 — 실제로 등장하는 키

동봉 트리 + 설치본(`assets/`, `projects/`) 전체 JSON 을 훑어 `"animation"` 객체를 전수 수집했다.
**애니 블록 7개 / 파일 6개**가 전부다(동봉 트리와 설치본이 같은 집합).

> **재측정(2026-08-21, 클러스터 K).** 위 수치를 독립적으로 다시 떴다. 파일 수는
> 동봉 1,698 + `assets/` 1,698 + `projects/` 259 = **3,655**. 그중 **63개가 표준 JSON 이
> 아니다** — `//` 줄주석과 후행 콤마를 쓰는 `effect.json` 27 · `preset.json` 4(양 트리 ×2) +
> `projects/…/glass.json` 1. `json.load` 로 그냥 훑으면 이 63개가 조용히 빠지므로
> **JSONC 관용 파서**(문자열 인식 주석 스트리퍼 + 후행 콤마 제거)로 다시 훑었다:
> 파스 실패 **0**, `"animation"` 객체 **14개**(동봉 7 + `assets/` 7, `projects/` 0) — 같은 수다.
> 확인차 확장자를 가리지 않고 `grep -rl '"animation"'` 도 돌렸는데 두 트리에서 위 6파일뿐이고
> `projects/` 히트 1건은 Unity 의 `UnityEngine.AnimationModule.xml` 이라 무관하다.
> 즉 **63개 비표준 JSON 안에 숨은 애니 블록은 없다**.

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
  **두 게이트의 실패 분기 `ja 0x1401a9319` 는 함수 탈출이 아니라 루프 진행부다**(2026-08-21
  클러스터 Q 확정). 0x1401a9319 부터가 `mov rax,[rbx+0x10]` / `cmp byte ptr [rax+0x19], 0` 으로
  red-black 트리 이터레이터를 전진시키는 코드이고, 0x1401a9356 · 0x1401a938c 의 `jmp 0x1401a8db6`
  이 루프 머리로 되돌아간다. 함수의 유일한 정상 탈출은 0x1401a9398 이고 거기서
  `mov rax,[rbp+8]; cmp [rbp],rax; setne al`(0x1401a939c/0x1401a93ac) 로 **"벡터가 비지
  않았는가"** 를 돌려준다. 즉 **비숫자 `value`/`frame` 은 그 키프레임 하나만 버린다.**
  (호출부는 이 반환값을 **읽지 않는다** — 0x1401a56ec 다음이 곧바로 0x1401a56fc 의 push 다.
   그래서 빈 배열 `"cN": []` 도 **빈 트랙으로 push 된다**.)
  `asInt`(0x140085ee0)는 태그 1/2 를 `mov eax,[rcx]`(하위 32비트), 태그 3 을
  `cvttsd2si eax`(0x140085f12 — **0 방향 절단**), 태그 5 를 0/1 로 준다.
- 직전 프레임을 `[rsp+0xe8]` 에 들고 `frame <= 직전` 이면 **그 키프레임을 버린다**(0x1401a8fc1 `jle`).
  초기값 `0xFFFFFFFF = −1`(0x1401a8d26) → 음수 프레임도 탈락. 즉 **정렬하지 않고 강한 단조만 통과**.
- `step` 이 true 면 flags = 4 로 두고 **핸들을 아예 읽지 않는다**(0x1401a8fed).
  아니면 `back.enabled` → `|= 1` + `back.x/y` 읽기, `front.enabled` → `|= 2` + `front.x/y` 읽기.
  disabled 면 x/y 는 **0 으로 남는다**(0x1401a8fd1 의 `xorps` 초기화).
  두 `enabled` 는 **부재·비-bool 이 true** 다 — §2.5 의 폴라리티 표를 볼 것.

> **[2026-08-21 수정] 이 문단은 문서에만 있었고 코드에는 없었다.** `PropertyAnimation.parse` 가
> `step` 을 담으면서 `front`/`back` 도 그대로 담고 있었다. `step` 은 자기 **왼쪽** 구간을
> 계단으로 만드니 그쪽에서는 핸들이 안 쓰이지만, `front` 는 **오른쪽 구간의 P1** 을 정하고
> `back` 은 `wrapLooped` 끝점 back 의 부호반전 소스다. 그래서 종전 Waple 은 step 키프레임
> 바로 다음 구간이 실물과 다른 곡선이었다. 합성 반례(`step` 키프레임에 `front{x:1,y:40}`,
> 다음 키프레임 `back.enabled=false`)에서 frame 45 값이 **40.535366 ↔ 25.000000** 으로 갈린다.
> 지금은 `step` 이 서면 `front`/`back` 딕셔너리를 `nil` 로 흘려 실물과 필드 단위로 맞춘다.
> 코퍼스 도달 0(`step` 키는 애니 7블록 38키프레임 어디에도 없다).
> 잠금: `PropertyAnimationOptionsTests` ⑩ 두 건(억제 / 비-step 보존).
>
> 실물 파서가 읽는 키가 여덟(`value`·`frame`·`back`·`front`·`enabled`·`x`·`y`·`step`)뿐이라는
> 것은 이번에 `lea rdx,[rip+…]` 문자열 인자를 함수 범위 전체에서 세어 재확인했다.
> `lockangle`/`locklength`/`magic` 은 xref 0 이 아니라 **문자열 자체가 없다** — ASCII·UTF-16LE
> 전수 검색으로 `wallpaper64.exe` · `scenescript64.dll` · `resourceutil64.dll` ·
> `cloneextensions64.dll` · `resourcecompiler64.exe` · `diagnostics64.exe` **여섯 바이너리 모두
> 0건**이다(`beziermode` 도 같다). 함정 13("바이너리 하나 ≠ WE")을 닫아 둔다.
> 참고로 `resourcecompiler64.exe` 에는 `wraploop`·`smoothing`·`stiffness` 가 있다 —
> 퍼펫/카메라경로 쪽 옵션이고 프로퍼티 애니와는 다른 자리다.

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
| `length` | 1–3 numeric — 0x1401a9714 (`dec eax; cmp eax,2; ja`) | **애니 전체 드롭** | 마지막 키프레임 frame(부재/타입 불일치) · `<= 0` 이면 **`parse` → nil** |
| `fps` | 1–3 numeric — 0x1401a9723 | **애니 전체 드롭**(추가로 `fps<=0`·`length/fps<=0` 도 드롭) | 30(부재/타입 불일치) · `<= 0` 이면 **`parse` → nil** |
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

**Waple 파스 도달**(2026-08-21 후속). 종전 판은 `true` 2블록 중
`/objects/1/instanceoverride/controlpoint1` 이 `SceneDocument` 의 `instanceoverride` 드롭
때문에 `PropertyAnimation.parse` 에 닿지 않는다고 적었는데, **클러스터 M 이 그 드롭을 고쳤다** —
이제 `SceneParticle.instanceOverrideAnimations` 로 보존된다
(`SceneDocumentFidelityTests.testInstanceOverrideAnimationBindingIsCaptured`).
그래서 `true` 2블록은 **둘 다** 이 후처리를 탄다.

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

> **[2026-08-21] 같은 누수가 반대 방향으로도 있었다.** `{"a": true}` 를 `strictFloat` 에
> 넣으면 리눅스에서 `Optional(1.0)` 이 나온다(`as? Double` == `Optional(1.0)` · `as? Int` ==
> `Optional(1)` — 이 문서 작성 중 실측). 그런데 애니 스키마에서 **숫자를 읽는 여덟 자리**는
> 전부 `movzx eax,[X+8]; dec eax; cmp eax,2; ja` 로 **태그 1..3(int/uint/real)만** 통과시킨다:
> `value`(0x1401a8e73) · `frame`(0x1401a8e83) · 핸들 `x`/`y` 네 자리(0x1401a904c · 0x1401a9069 ·
> 0x1401a90d9 · 0x1401a90f4) · `options.length`(0x1401a9714) · `options.fps`(0x1401a9723) ·
> `events[].frame`(0x1401a9511). 태그 5 는 전부 탈락이다.
> 게이트를 붙이기 전 Waple 은 `{"front":{"x":true}}` 를 좌표 1.0 으로, `{"fps":true}` 를
> **1 fps**(= 30배 느린 재생)로 읽었다. 지금은 `f()` 가 `isJSONBool` 을 먼저 본다.
> 자리별로 원본과의 거리는 다르다 — 핸들 `x`/`y` 와 `events[].frame` 은 **정확히 일치**하고
> (전자는 0, 후자는 항목 드롭), `value`/`frame` 과 `options.length`/`fps` 는 원본이 각각
> "그 키프레임만 건너뜀"·"애니 전체 드롭" 이라 여전히 다르다(이 문서 §2.3 표의 관용 정책 유지).
> 코퍼스 도달 0 — 여덟 자리 값 타입 census 가 전건 int/float 이다
> (`frame` int×38 · `value` int11/float27 · `x` int52/float24 · `y` int46/float30 ·
>  `fps` int×7 · `length` int×7 · `events` 0건). 잠금: `PropertyAnimationOptionsTests` ⑫.

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
키프레임 0개                    → 0.0                        ; 0x1401a9bfd `cmp [rcx],rax` → `xorps`
frame <= kf[0].frame            → kf[0].value
kf[i-1].frame <= frame < kf[i].frame  → 구간 [i-1, i]        ; 반개구간
i 가 끝까지 가면                → kf[count-1].value          ; 0x1401a9cf5 `jg 0x1401a9ec7`
구간 안에서:
   kf[i-1].frame == frame       → kf[i-1].value              ; 0x1401a9d0f
   kf[i].flags & 4 (step)       → kf[i-1].value              ; 0x1401a9d18 (같은 타깃 0x1401a9ec0)
```

**경계 세 자리의 Waple 대조**(2026-08-21 클러스터 K):

| 경계 | WE | Waple | 조치 |
|---|---|---|---|
| 키프레임 0개 | **0.0** | `value(component:)` 앞 가드가 **base 유지** | **유지**(근거는 §5.1 에서 다시 세웠다 — 이 타입 안에서 닫을 수 없다). 도달 0(트랙 19개 전수 키프레임 2개, 빈 배열 0건) |
| 키프레임 1개 | 두 분기가 같은 값 | 같음 | 확인 + 테스트 |
| 왼쪽 끝점 정확 일치 | 곡선을 **안 푼다** | 항상 이분법으로 풀었다 | **수정** — `front.x < 0` 처럼 X(u) 가 구간 앞으로 튀어나가면 이분법이 **다른 근**을 잡는다. 합성 반례 **166.081 ↔ 100.000**. 도달 0(코퍼스 `front.x` = 1 · 0.50833333 전수 양수) |
| 중복 시각 | 파스에서 버린다(0x1401a8fc1 `jle`) | 정렬로 관용 → 평가기까지 들어옴 | 유지 — 반개구간 탐색이 **마지막 중복**을 왼쪽 끝점으로 잡는다(테스트로 못박음). 도달 0 |

`frame` 인자는 **`int`** 다(`movsxd rbp, edx`). Waple 이 연속 `Float` 를 넘기므로 위 "정확 일치"
분기는 WE 에서는 키프레임마다 매번, Waple 에서는 정확히 맞을 때만 걸린다(§5).

**"정확 일치" 단락이 동봉 코퍼스를 바꾸지 않는 이유(실측).** 코퍼스 핸들 76개의 좌표 분포는
`x` = {1:26, −1:26, 0.50833333:12, −0.50833333:12} · `y` = **{0:46, −0.0:30}** 이다.
`y` 가 전건 0 이므로 모든 구간에서 `P1y = P0y` · `P2y = P3y` 이고, 그러면
`y(u) = v0 + (v1−v0)·(3u²−2u³)` 라 `u → 0` 에서 **정확히 `v0`** 다(Float32 에서도 보정항이
ulp 아래다). 게다가 `front.x` 가 전건 양수, `back.x` 가 전건 음수라 `X(u)` 가 구간 안에서
**단조**여서 이분법도 어차피 `u ≈ 2⁻²⁵` 로 수렴한다. 두 조건이 겹쳐 코퍼스 위에서는
**비트 동일**이고, 갈리려면 `front.x < 0`(비단조) **또는** `front.y ≠ 0`(끝점 접선 이동)이
있어야 한다 — 둘 다 코퍼스 도달 0.

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

트랙 접근에 **경계 검사가 없다** — `mov rcx,[rbx+0x20]`(트랙 벡터의 begin) 에 `0x30`씩 더해
`0x1401a9bc0` 을 부를 뿐이다(0x140172459 / 0x14017249d / 0x140172582 / 0x140172629).
그래서 그 앞의 게이트(§3.4)가 하중을 받는다.

### 3.4 애니 유효 게이트 — **트랙 수 == 프로퍼티 성분 수** (2026-08-21 클러스터 Q 신규)

`0x140175880`(바인딩 등록기)의 애니 분기가 애니 객체를 등록하면서 이 바이트를 굽는다:

```
0x140176742  rcx = [r15+0x10]                 ; 프로퍼티 서술자
0x140176750  edx = [rcx]                      ; 서술자 태그
             tag 1 → r8 = 2   (0x140176771)   ; vec2
             tag 2 → r8 = 3   (0x140176769)
             tag 3 → r8 = 4   (0x140176761)
             그 외  → r8 = rsi = 1            ; float (0x1401758ee / 0x140175d4a 가 esi=1)
0x140176777  rax = ([r15+0x28] − [r15+0x20]) / 0x30      ; **트랙 개수**
0x14017679b  cmp r8, rax
0x14017679e  sete al
0x1401767a1  mov byte ptr [r15+0x18], al      ; = (성분 수 == 트랙 수)
```

per-frame 소비단이 이 바이트 하나로 애니 전체를 켜고 끈다 —
`0x14017241f cmp byte ptr [rbx+0x18], 0` → `je 0x1401726ad`. 0 이면 트랙을 **한 번도 평가하지
않고** 다음 애니로 넘어가므로 **바인딩의 정적 `value` 가 그대로 남는다**.

이 한 자리가 아래 셋을 한꺼번에 설명한다:

1. **`fps<=0` / `length<=0`** — `init` 이 false 를 돌리면 호출부가 c0..c3 파스를 통째로
   건너뛰므로(0x1401a56c0 `test al,al` → `je 0x1401a57e1`) 트랙 수가 **0** 이 되고 게이트가
   꺼진다. **애니 객체 자체는 버려지지 않는다** — 실패 경로도 성공 경로와 0x1401a57e9 에서
   합류해 등록기로 그대로 넘어간다. (종전 문서의 "호출부가 애니를 통째로 버린다" 는 결과는
   맞지만 기전이 틀렸다 — 함정 16.)
2. **`c0..c3` 캐스케이드** — c0+c2 처럼 채널이 비면 트랙 수가 1 이 되고, vec3 프로퍼티의 성분
   수 3 과 어긋나 **애니 전체가 꺼진다**. "c2 만 유실" 이 아니다.
3. **빈 트랙의 0.0 분기(0x1401a9bfd)에 닿는 유일한 입력** — 명시적 `"cN": []` 다. 배열이기만
   하면 키프레임 파서의 반환값과 무관하게 push 되므로(§2.2) 트랙 수는 유지되고, 그 채널만
   0.0 이 된다.

Waple 은 프로퍼티의 성분 수를 모른다(그건 `origin`(vec3)인지 `alpha`(float)인지 아는
`SceneDocument` 의 정보다). 그래서 이 게이트를 `PropertyAnimation` 안으로 옮길 수 없다 —
§3.5 · §5.1 · §6.7 을 볼 것.

### 3.5 성분 수는 어디서 오는가 — 그리고 왜 옮기지 **않았나** (2026-08-21 클러스터 V)

§3.4 를 처음부터 다시 떴다(브리프 함정 16 — 인계 VA 를 베끼지 않았다). 명령 단위는 §3.4 그대로
재현됐고, `r8` 의 기본값이 `esi = 1` 이라는 것도 지배 관계로 확인했다:
`0x140175d4a mov esi, 1` 이 `0x140175d5a je 0x140176742` 를 **직접 지배**한다(그 사이에 rsi 쓰기
없음). 아래가 이번에 새로 확정한 것이다.

#### 3.5.1 태그 ↔ 성분 수 사전은 **디스크립터 표**가 정한다

성분 수는 값의 형태가 아니라 `[binding+0x10]` 이 가리키는 **프로퍼티 디스크립터**의 첫 dword
(타입 태그)가 정한다. 사전은 **1→2 · 2→3 · 3→4 · 그 외→1** 이고, 태그별 vec 주입기가
그 사전과 1:1 로 짝지어져 있다(디스크립터 `+0x8` 에 실리는 함수 포인터):

| 태그 | 성분 | 주입기 | 근거(디스크립터를 굽는 자리) |
|---:|---:|---|---|
| 4 | 1 (float) | `0x1401a4b00` | `0x1401554dc` `mov dword [rdi], 4` + `0x1401554d5 lea rax,[0x1401a4b00]` |
| 1 | 2 (vec2) | `0x1401a3fc0` | `0x1401554b7` `mov dword [rdi], 1` + `0x1401554b0 lea rax,[0x1401a3fc0]` |
| 2 | 3 (vec3) | `0x1401a4230` | `0x140155492` `mov dword [rdi], 2` + `0x14015548b lea rax,[0x1401a4230]` |
| 3 | 4 (vec4) | `0x1401a4580` | `0x140155477` `mov dword [rdi], 3` + `0x1401553cb lea r12,[0x1401a4580]` |

네 주입기 전부가 `0x1401a4db0`(바인딩 파서)을 부르고, 그게 `0x140175880`(등록기)을 부른다 —
즉 **어느 경로로 들어와도 같은 게이트를 탄다.**

#### 3.5.2 오브젝트 프로퍼티는 고정 표다 — 전수로 읽어냈다

| 표 | 함수(`merged()`) | 키 → 태그(→ 성분) |
|---|---|---|
| 공통 오브젝트 | `0x1401e0530`–`0x1401e1389` | `origin` 2(3) `0x1401e0629` · `scale` 2(3) `0x1401e06ea` · `angles` 2(3) `0x1401e07ae` · `parallaxDepth` 1(2) `0x1401e085a` |
| 렌더러블(이미지/이펙트 레이어) | `0x1401ee520`–`0x1401ef118` | `size` 1(2) `0x1401ee5f0` · `color` 2(3) `0x1401ee6b6` · `alpha` 4(1) `0x1401ee782` · `brightness` 4(1) `0x1401ee865` |
| 카메라 오브젝트 | `0x1401f3460`–`0x1401f38b5` | `fov` 4(1) `0x1401f3626` · `zoom` 4(1) `0x1401f36c3` |
| 라이트 | `0x14025da80`–`0x14025e9da` | `color` 2(3) `0x14025db88` · `intensity`/`radius`/`exponent`/`innercone`/`outercone`/`density`/… 전부 4(1) |
| **파티클 `instanceoverride`** | `0x14024d940`–`0x14024e96e` | `alpha`·`size`·`count`·`speed`·`lifetime`·`brightness`·`rate` 4(1) · `colorn` 2(3) `0x14024df3e` · `controlpoint0..7` 2(3) · `controlpointangle0..7` 2(3) |

**그래서 클러스터 Q 의 "instanceoverride 는 값의 형태에서만 유도된다" 는 틀렸다** —
`0x14024d940` 이 키마다 태그를 고정으로 굽는다. 위 표가 그대로 성분 수 사전이다.

#### 3.5.3 `constantshadervalues` 만이 진짜로 유도 불가 — **셰이더 유니폼**이 정한다

이펙트/머티리얼 패스의 상수는 디스크립터를 **런타임에 만든다**. 재료는 컴파일된 셰이더의
유니폼 리플렉션 레코드(`rbx`)다:

```
0x14015542d  movsx eax, byte ptr [rbx+0x45]   ; 유니폼 레지스터 인덱스
0x140155439  lea  eax, [rax*4 + 0x120]        ; → 멤버 오프셋 [rdi+4]
0x14015545b  movsx ecx, byte ptr [rbx+0x44]   ; **유니폼 성분 수(1..4)**
             ecx==1 → tag 4  (0x1401554dc)
             ecx==2 → tag 1  (0x1401554b7)
             ecx==3 → tag 2  (0x140155492)
             ecx==4 → tag 3  (0x140155477)
```

즉 `constantshadervalues` 의 성분 수는 **JSON 에 없다.** 실증: `effects/blendgradient` 의
`multiply` 애니(코퍼스 유일한 이펙트 상수 애니, c0 1트랙)는 셰이더가
`uniform float g_Multiply; // {"material":"multiply", …}`
(`effects/blendgradient/shaders/effects/blendgradient.frag:12`)라 성분 1 → 게이트 통과다.
같은 파일의 `g_EdgeColor` 는 `vec3`(`:17`)이라, `edgecolor` 에 1트랙 애니를 걸면 실물은
**애니를 통째로 끈다**.

`SceneDocument.parse` 에서 이 값을 얻으려면 (a) 패스의 `material` JSON → `shader` 이름 →
`.frag` 를 로드하고, (b) **그 패스의 `combos` 로 전처리**한 뒤(유니폼 선언이 `#if COMBO` 안에
있을 수 있다), (c) `// {"material":"<키>"}` 애노테이션으로 JSON 키 ↔ 유니폼을 매핑해야 한다.
그건 배선이 아니라 새 서브시스템이고, Waple 에서 그 정보를 들고 있는 계층은
`WapleRender`(셰이더 컴파일/리플렉션)다.

#### 3.5.4 그래서 적용하지 않았다 — 그리고 그게 안전한 쪽이다

1. **전면 적용이 불가능하다.** §3.5.3 때문에 `constantshadervalues` 호출부에 넘길 값이 없다.
   인자를 안 넘기는 호출부가 남으면 규약이 반쪽이 된다(클러스터 Q 의 판단과 같다).
2. **값의 형태로 대신 유도하는 것은 위험한 방향으로 틀린다.** vec3 유니폼인데 정적 `value` 가
   스칼라(또는 부재)이고 애니가 3트랙인 저작에서, 형태 유도는 성분 1 ≠ 트랙 3 이라
   **실물이 살려 두는 애니를 Waple 이 죽인다.** 코퍼스로는 검출조차 안 된다(도달 0).
   반대 방향(실물이 죽이는 것을 Waple 이 살리는 것)은 지금도 그렇고, 정적 값이 base 로 남는
   대신 애니가 도는 차이라 **덜 파괴적**이다.
3. **재현 코퍼스 도달 0.** 동봉 `WEAssets`(json 1,698) + 설치본 `wallpaper_engine`(json 2,143)
   전수에서 `{"animation":{…}}` 바인딩은 각각 **7건**이고, 성분 수와 트랙 수가 어긋나는 것은
   **0건**이다:

   | 부모 키 | 트랙 | 성분(근거) | 게이트 |
   |---|---:|---:|---|
   | `origin`(이미지 오브젝트) ×1 | 3 (c0·c1·c2) | 3 (태그 2, `0x1401e0629`) | 통과 |
   | `controlpoint1`(instanceoverride) ×1 | 3 | 3 (태그 2, `0x14024e173`) | 통과 |
   | `controlpointangle1`(instanceoverride) ×4 | 3 | 3 (태그 2, `0x14024e240`) | 통과 |
   | `multiply`(effect const) ×1 | 1 (c0) | 1 (`uniform float g_Multiply`) | 통과 |

   즉 게이트를 넣어도 **재현 코퍼스에서 달라지는 것이 하나도 없고**, 얻는 것은 워크샵에서의
   2번 위험뿐이다.
4. **닫으려면**: `SceneDocument.parse` 가 §3.5.2 의 고정 표를 상수로 들고
   `PropertyAnimation.parse(_:components:)` 에 넘기고, `constantshadervalues` 는
   **셰이더 리플렉션이 파스 경로에 들어온 뒤에** 같이 넣는다. 그 전까지는 반쪽이다.

#### 3.5.5 게이트가 들어와도 §5.1(빈 트랙 0.0)은 **닫히지 않는다**

인계서는 "게이트가 들어오면 빈 트랙 0.0 도 함께 닫히는지 판단하라" 고 했다. **닫히지 않는다.**
게이트는 트랙 **개수**만 본다(`cmp r8, rax` `0x14017679b`). `{"c0":[…], "c1":[], "c2":[…]}` 는
트랙 3개라 vec3 프로퍼티에서 게이트를 **통과**하고, 그다음 per-frame 평가가 c1 트랙을
그대로 샘플한다 — 소비단 vec3 분기 `0x140172582`–`0x1401725f8` 이 `[rbx+0x20]+0x00/0x30/0x60`
셋을 **조건 없이** `0x1401a9bc0` 에 넘기고, 그 평가기가 빈 벡터에서
`cmp qword [rcx], rax`(`0x1401a9bfd`, `rax = [rcx+8]`) → `xorps xmm0, xmm0`(`0x1401a9c0b`) 로
**0.0f** 를 돌린다. Waple 은 같은 자리에서 `base` 를 돌린다
(`PropertyAnimation.value(component:atTime:base:)`).

즉 두 결함은 **직교**한다:

* 트랙 수 불일치 → 게이트(§3.4). Waple 은 미이식(§3.5.4).
* 명시적 `"cN": []` → 0.0. 게이트와 무관. 닫으려면 "채널 키가 없어서 만든 자리지킴 빈 트랙"과
  "저작이 명시한 빈 배열"을 갈라야 하는데(§5.1 항목 4), 그건 성분 수를 **몰라도** 할 수 있다 —
  파스가 `a[key] != nil` 을 이미 구분하고 있으므로 그 비트를 들고 다니면 된다.
  다만 도달 0(코퍼스 트랙 19개 전수가 키프레임 2개, 빈 배열 0건)이고 공개 타입의 계약을
  바꾸는 변경이라 이번 라운드에서 하지 않았다. **§5.1 의 "성분 수를 몰라서 못 닫는다" 는
  이유는 (b) 케이스에 한해 틀렸다** — 못 닫는 게 아니라 안 닫은 것이다.

---

### 3.6 보간 종류는 **둘뿐**이다 — 그리고 `enabled` 비트는 재생에 안 쓰인다 (2026-08-21 클러스터 AF)

임무가 "커브 종류 열거를 바이너리에서 확정하라(**상수 적재** 자리를 세라 — 호출 자리 말고)"
였다. 셌다.

**키프레임 flags 에 상수를 넣는 자리는 파서 `0x1401a8ce0–0x1401a940c` 안에 정확히 넷이다.**

| VA | 명령 | 뜻 |
|---|---|---|
| 0x1401a8fed | `mov r13d, 4` | `step` |
| 0x1401a8ff8 | `xor r13d, r13d` | 핸들 없음 |
| 0x1401a9050 | `mov r13d, 1` | `back` enabled |
| 0x1401a90dd | `or r13d, 2` | `front` enabled |

저장은 둘(`mov [r14+8], r13d` 0x1401a9148 · `mov [rsi+rbp+8], r13d` 0x1401a9257). 즉 flags 워드가
가질 수 있는 값은 `{0,1,2,3,4}` 뿐이고 **이징/커브 타입 태그가 들어갈 자리가 아예 없다.**
런타임 보간 종류는 **큐빅 베지어**와 **계단(step)** 둘이 전부다. Waple 은 둘 다 구현한다.

에디터의 `beziermode` 는 여섯이지만(`let n = ["both","left","right","none","magic"]`
`scripts.js` char@554808 + `"step"` char@566452/@568161) 전부 이 세 비트 + 핸들 좌표로 접힌다:

```js
back .enabled = mode∈{magic, both, left}      front.enabled = mode∈{magic, both, right}
back .magic   = (mode === "magic")            front.magic   = (mode === "magic")
back .x = -1, back.y = 0                      front.x = +1, front.y = 0     // char@566180
mode === "step" → keyframe.step = true                                       // char@566452
```

`magic` 은 **저작 시점에** 이웃 프레임 간격으로 핸들을 재배치하는 표식일 뿐이다
(char@556010 `a.back.magic&&(a.back.x=-.5-s,a.back.y=-.1*r)` /
`a.front.magic&&(a.front.x=.5+o,a.front.y=.1*i)`) — 그 결과가 x/y 에 구워져 저장되므로 런타임에는
자리가 없다. §2.2 가 이미 확인한 대로 `magic`/`lockangle`/`locklength` 문자열은 여섯 바이너리
어디에도 없다.

#### 3.6.1 `enabled`(bit0/bit1)은 **평가기가 읽지 않는다** — 그리고 그게 실제로 갈렸다

키프레임 배열을 stride **0x1c** 로 인덱싱하는 함수는 이미지 전체 `imul r,r,0x1c` 스캔으로
**넷뿐**이다 — 파서 `0x1401a8ce0`(4자리) · `wrapLoop` `0x1401a98b0`(7) · 평가기
`0x1401a9bc0`(3) · 벡터 복사 헬퍼 `0x1401aa430`(4, flags 를 아예 안 본다).
그 넷 안에서 키프레임 flags 를 **읽는** 명령은 딱 둘이다:

```
0x1401a9b48   test r10b, 2                    ; wrapLoop — **첫** 키프레임의 front(bit1)
0x1401a9d18   test byte ptr [r10+r11+8], 4    ; 평가기 — **오른쪽** 키프레임의 step(bit2)
```

`bit0`(back enabled)은 **넷 어디서도 읽히지 않는다.** 쓰기만 셋이다(파서 0x1401a9050 ·
`wrapLoop` 의 `or eax,1` 0x1401a9b51 / `and eax,0xfffffffe` 0x1401a9b66).
제어점 조립(0x1401a9d6d · 0x1401a9d74 · 0x1401a9e58 · 0x1401a9e8f)은 `enabled` 를 보지 않고
**무조건** 네 좌표를 쓴다. disabled 핸들이 접히는 것은 **파서**가 좌표를 안 읽어 0 이 남기
때문이다(0x1401a8fd1 `xorps xmm6/7/8/9` → 0x1401a8ffb / 0x1401a907f 의 `test` 로 읽기 블록 건너뜀).

**Waple 은 반대로 하고 있었다** — 파스에서 좌표를 담고 `segment()` 에서 `enabled` 로 접었다.
코퍼스 위에서는 동치지만(핸들 76/76 이 명시 bool + 좌표 일치) **`wrapLoop` 덮기 경로에서 갈린다**:
그 경로는 실물처럼 bit0 만 지우고 backX/backY 를 남기는데(§2.4 5항), 평가기가 bit0 을 안 보므로
**실물에서는 그 잔존 좌표가 그대로 곡선을 휜다.** 합성 반례

```json
{"animation": {
  "c0": [{"frame": 0,  "value": 10, "front": {"enabled": false, "x": 0, "y": 0}},
         {"frame": 60, "value": 99, "back":  {"enabled": true,  "x": -1, "y": 20}}],
  "options": {"fps": 30, "length": 60, "mode": "loop", "wraploop": true}}}
```

에서 frame 31 값이 **10.000000(종전) ↔ 18.888773(실물)** 로 갈렸다(돌연변이로 재현 확인).

**고쳤다.** `parse` 가 disabled 핸들의 x/y 를 0 으로 굽고(`keyframes()`), `segment()` 는
`enabled` 를 보지 않는다. 정상 파스 경로의 결과는 **한 건도 바뀌지 않는다**(코퍼스 재측정).
잠금: `PropertyAnimationOptionsTests.testDisabledHandleCoordinatesAreZeroedAtParse` ·
`…testWrapLoopOverwriteStaleBackHandleStillShapesTheCurve`.

> 부수 효과: `PropertyAnimationTests` 의 `kf(enabled:false)` 헬퍼가 종전에는 `fx:1`/`bx:-1` 을
> 그대로 넘겨 **실물 파서가 절대 만들지 않는 키프레임**으로 선형성을 시험하고 있었다.
> 헬퍼도 좌표를 0 으로 맞췄다.

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

## 5. 옮기지 않은 것들 — 근거

### 5.1 빈 트랙의 `0.0` (2026-08-21 클러스터 Q 재평가)

클러스터 K 는 "누락 채널을 빈 트랙으로 자리만 지키는 관용과 **짝**이라 의도적 유지" 라고 적었다.
방향은 맞았지만 근거가 약하다 — 실제 이유는 **WE 가 쓰는 규칙이 애초에 "빈 트랙 → 0.0" 이
아니기 때문**이다.

1. WE 의 규칙은 §3.4 의 **트랙 수 == 프로퍼티 성분 수** 라는 전부-아니면-전무 게이트다
   (`sete al` 0x14017679e → `mov byte ptr [r15+0x18], al` 0x1401767a1 → 소비자 게이트
   0x14017241f). 채널이 비면 WE 는 "그 채널만 0" 이 아니라 **애니 전체를 끈다**.
2. `PropertyAnimation` 은 프로퍼티의 성분 수를 모른다. 그 정보는 `origin`(vec3)인지
   `alpha`(float)인지 아는 `SceneDocument` 에만 있다. **그래서 WE 의 게이트를 이 타입 안으로
   옮길 수 없다.**
3. 게이트 없이 `0.0` 만 옮기면 **누락 채널이 base 대신 0 으로 눌린다** — 실물이 하지 않는
   일이다(실물은 그 경우 애니를 끈다). 즉 지금보다 **더** 갈린다.
4. Waple 의 빈 트랙은 두 입력을 뭉뚱그린다: (a) 채널 키 자체가 없음, (b) 명시적 `"cN": []`.
   WE 에서 0.0 에 닿는 것은 (b) 뿐이다(§3.4). 둘을 갈라 (b) 에서만 0 을 돌리려면 트랙 배열
   바깥에 "명시적 빈 채널" 표식을 하나 더 들고 다녀야 하는데, 그래도 1·2 때문에 실물과
   같아지지 않는다.
5. 도달 0 — 코퍼스 트랙 19개가 전수 키프레임 2개이고 빈 배열은 0건이다.

**결론: 고치지 않는다.** 닫으려면 `parse`(또는 `value(component:)`)가 프로퍼티 성분 수를 받아야
한다 — §6.7 의 넘길 것.
잠금: `PropertyAnimationOptionsTests.testMissingChannelKeepsBaseAndDoesNotCollapseToZero`.

> **[2026-08-21 클러스터 AF 판단]** §3.5.5 가 "(b) 명시적 `"cN": []` 만은 성분 수 없이도
> 닫을 수 있다(파스가 `a[key] != nil` 을 이미 구분한다)" 고 지적했고, 그 판단은 맞다.
> 그래도 **이번에도 넣지 않는다.** 이유 셋:
> 1. 도달 0 — 설치본·동봉 애니 7블록 19트랙에 빈 배열이 **0건**이다.
> 2. `PropertyAnimation` 의 **공개 타입 계약을 넓혀야** 한다(트랙 배열 밖에 "명시적 빈 채널"
>    비트를 하나 더 들고 다녀야 한다). 소비처가 0인 상태에서 공개 표면을 넓히는 것은
>    이 파일이 지금까지 일관되게 피해 온 선택이다.
> 3. 닫아도 **부분적으로만** 실물과 같아진다 — 위 1·2·3 항의 성분 수 게이트가 남기 때문에,
>    "(b) 에서 0.0" 을 넣은 뒤에도 vec3 프로퍼티에 `{"c0":[…],"c1":[],"c2":[…]}` 가 오면
>    실물은 (트랙 3개 == 성분 3개라) 애니를 **살려서** c1 만 0 을 내는데 Waple 은 c1 만 0 을
>    내는 것까지는 같아지지만, 반대로 `{"c0":[…],"c1":[]}` 같은 저작에서는 실물이 애니를
>    **끄고** Waple 은 c1=0 으로 그린다. 즉 반쪽만 맞는 상태가 되고, 그 반쪽을 위해 공개
>    계약을 넓히는 교환이 남는다.
>
> 진짜 열쇠는 §3.5.4 가 말한 대로 **`constantshadervalues` 의 성분 수를 파스 경로에서 얻는
> 설계**다. 설계 후보를 §6 에 적어 뒀다.

### 5.2 정수 프레임 양자화를 옮기지 않은 근거

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

1. ~~**`instanceoverride` 의 애니 바인딩이 드롭된다.**~~ → **[2026-08-21 후속] 처리됐다.**
   클러스터 M 이 `particleInstanceOverride` 에 `PropertyAnimation.parse(bind)` 병행 캡처를 넣어
   `SceneParticle.instanceOverrideAnimations` 로 보존한다
   (`SceneDocumentFidelityTests.testInstanceOverrideAnimationBindingIsCaptured`).
   자산 7블록 중 **5블록**이 `objects[].instanceoverride.controlpoint1` /
   `controlpointangle1` 아래에 있었고, `maintaindistancebetweencontrolpoints` 의 움직이는
   컨트롤포인트가 이 수정으로 살아났다 — c1 트랙 `436.42032 → 145.37645` 가
   `PropertyAnimation` 평가로 재현되는 것이 M 의 테스트로 잠겼다(이 레인 평가기의 독립 확인이다).
   (`controlpointangle1` 4블록은 CP 회전 표현이 없어 여전히 별건.)
2. **오브젝트 애니 키 목록이 5개로 고정돼 있다**(SceneDocument.swift:1352
   `["origin", "scale", "alpha", "angles", "color"]`). WE 의 바인딩 파서는 프로퍼티 키를
   가리지 않는다 — 어떤 바인딩에나 `animation` 이 붙을 수 있다.
3. ~~**[미해결] `length` 가 정수가 아니면 끝점 프레임과 루프 주기가 갈린다.**~~ →
   **[2026-08-21 클러스터 Q] 닫았다.** `parse` 가 `length` 를 한 번 `rounded(.towardZero)` 해서
   `PropertyAnimation.length` 자체를 정수로 만든다 — 실물이 `asInt`(0x1401a9815 → 0x140085ee0,
   태그 3 은 `cvttsd2si` 0x140085f12) 한 번으로 끝점 프레임(`[r13+0x48]` → 0x1401a5780)과
   루프 주기(`+0x08 = (float)length/fps`, 0x1401a8c37–0x1401a8c46)를 같은 정수로 쓰기 때문이다.
   키프레임 `frame` 도 같이 닫았다(`asInt` 0x1401a8fb5 → 파스에서 0 방향 절단).
   절단으로 프레임이 겹칠 수 있게 됐으므로 정렬을 **안정**으로 바꿨다(원 인덱스를 2차 키로).
   도달 0(코퍼스 `length` 60×6·30×1 · `frame` int×38 전수 정수).
   잔여: 태그 1/2(int/uint)에서 실물은 `mov eax,[rcx]` 로 **하위 32비트만** 취하고, 겹친
   프레임에서 실물은 **앞의 것**을 남기는데(0x1401a8fc1 `jle`) Waple 은 정렬 관용 때문에 둘 다
   들고 **뒤가 왼쪽 끝점**이 된다. 둘 다 도달 0.
   잠금: `testKeyframeFrameIsTruncatedTowardZero` ·
   `testLengthTruncationGovernsLoopPeriodNotJustWrapEndpoint`.
4. `SceneDocument.swift` 의 상수 애니 주석이 `{animation:{...}}` 를 **"55씬/287건"** 이라고
   적는데, 동봉 트리에서 `"animation"` 키가 딕셔너리인 자리는 **전 트리 통틀어 7건**뿐이다
   (2026-08-21 전수 census). 그 수치는 다른 코퍼스(워크샵)에서 온 것으로 보인다 — 이 레인 밖이라
   손대지 않았지만, 동봉 도달을 그 숫자로 읽으면 안 된다.
   **[2026-08-21 후속]** 클러스터 M 이 `SceneDocument.swift:11`·`:3077` 에 범위 라벨과 실측치를
   붙였다(동봉 1,698 / 설치본 2,143 각각 `constantshadervalues` 밑 `{animation}` **1건/1파일**,
   `"animation"` 딕셔너리 전체 **7블록/6파일**). 원 "55씬/287건" 의 출처는 여전히 **[미해결]**.
5. ~~**[미해결] `fps <= 0` / `length <= 0` 은 "드롭" 이 아니라 "정지" 로 흐른다.**~~ →
   **[2026-08-21 클러스터 Q] 닫았다.** `parse` 가 `fps <= 0 || length <= 0` 에서 `nil` 을 돌린다.
   기전을 직접 다시 떠서 **종전 서술을 한 군데 정정**한다(함정 16):
   `init`(0x1401a8c10)이 `comiss xmm2(0.0), xmm1(fps)` → `jae 0x1401a8cc4`(0x1401a8c21)로
   `fps <= 0` 에서, `comiss xmm2(0.0), xmm0(length/fps)` → `jae`(0x1401a8c43)로
   `length/fps <= 0` 에서 false 를 돌리는 것까지는 맞다(`fps` 는 0 이든 음수든 **같은 명령
   한 자리**다). 호출부가 `test al,al` → `je 0x1401a57e1`(0x1401a56c0)로 c0..c3 파스를 통째로
   건너뛰는 것도 맞다. 그러나 **애니 객체는 버려지지 않는다** — 실패 경로도 성공 경로와
   0x1401a57e9 에서 합류해 등록기 0x140175880 으로 그대로 넘어간다. 애니를 실제로 끄는 것은
   §3.4 의 성분 수 게이트다(트랙 0개 ≠ 성분 수 1..4 → `[anim+0x18] = 0` → 소비자가 건너뜀).
   관측 결과는 종전 서술대로 "정적 `value` 가 그대로" 이고, `parse` 가 `nil` 을 돌리면
   호출부(`SceneDocument.swift:1827` 등)가 `anims[key]` 를 세우지 않아 **정확히 같아진다**.
   `length` 절단(§6.3)과 맞물려 `"length": 0.5` 도 같은 자리에서 걸린다 — 실물도 `asInt` 로
   0 이 되어 같은 자리에서 걸린다. 도달 0(코퍼스 `fps` = 15/20/30 · `length` = 30/60).
   잠금: `testDegenerateFpsOrLengthDropsTheWholeAnimation` · `testFallbackLengthOfZeroAlsoDrops`.
6. `PropertyAnimation` 에 `wrapLoop` 필드가 생겼다. 라운드트립 걱정은 **지금은 없다** —
   `Sources/` 전체에서 `"animation"` 을 **쓰는**(직렬화하는) 자리가 0건이고
   `ProjectJSONBuilder.swift` 는 12행짜리로 애니를 다루지 않는다(2026-08-21 실측).
   애니를 다시 내보내는 자리가 생기면 그때 `options.wraploop` 를 함께 써야 한다 —
   `wrapLoop` 필드를 보존용으로 남겨 둔 이유가 그것이다(트랙에는 이미 구워져 있어서
   랩된 트랙을 그대로 쓰면 끝점 키프레임이 하나 늘어난 채로 나간다).
7. **[2026-08-21 클러스터 V] 애니 유효 게이트(§3.4)는 옮기지 **않는다** — 근거는 §3.5.**
   클러스터 Q 의 제안(`PropertyAnimation.parse(_:components:)`)은 형태로는 옳지만, 전제
   ("`instanceoverride`/`constantshadervalues` 는 성분 수가 **값의 형태에서만** 유도된다")가
   **절반 틀렸다**. `instanceoverride` 는 고정 디스크립터 표라 바이너리에서 그대로 읽어낼 수
   있고(§3.5.2), `constantshadervalues` 만이 진짜로 유도 불가다 — 성분 수가 **셰이더 유니폼
   선언**에서 온다(§3.5.3). 브리프의 조건("전면 적용이 안 되면 적용하지 마라")에 따라
   **적용하지 않았다.** 재현 코퍼스 도달도 0 이다(§3.5.4).
8. **[2026-08-21 클러스터 AF] `constantshadervalues` 성분 수를 파스 경로에서 얻는 설계 후보.**
   §3.5.4 가 남긴 유일한 열쇠다. 실물이 보는 값(`movsx ecx, byte [rbx+0x44]` 0x14015545b)은
   **컴파일된 셰이더의 유니폼 리플렉션**이라 JSON 만으로는 안 나온다. 이 리포에는 이미 그 정보를
   가진 자리가 이미 있다 — `GLSLTranslator.parseUniforms`(`Sources/WapleCore/GLSLTranslator.swift`
   1303행)가 `uniform <type> <name>;` 을 훑어 `(GLSLType, name)` 목록을 내놓는다. 필요한 것은
   그 `GLSLType` 을 성분 수 1..4 로 접는 것뿐이다. 따라서:
   - `EffectManifest`(또는 `GLSLTranslator`)가 이펙트별 `유니폼 이름 → 성분 수(1..4)` 사전을
     내놓게 하고,
   - `SceneDocument` 가 `constantshadervalues` 를 파스할 때 그 사전에서 성분 수를 뽑아
     `PropertyAnimation.parse(_:components:)` 로 넘긴다(오브젝트 프로퍼티는 §3.5.2 의 고정 표,
     `instanceoverride` 는 §3.5 의 디스크립터 표에서 온다).
   - 사전에 없는 유니폼(셰이더 미해석·미번역)은 **게이트를 적용하지 않는다** — 지금 동작 유지.
   이러면 §3.5.4 가 우려한 "실물이 살리는 애니를 죽인다" 가 구조적으로 불가능해진다(모르는
   유니폼은 게이트를 안 타므로). **이번 라운드에서는 하지 않았다** — `GLSLTranslator` ·
   `EffectManifest` · `SceneDocument` 셋이 전부 이 레인 밖이고, 코퍼스 도달이 0이라
   회귀 위험만 있고 관측 이득이 없다. 착수하려면 이 세 파일의 소유자와 함께 가야 한다.

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

**그 `$eval` 이 부르는 파서를 이번에 직접 떴다**(2026-08-21 클러스터 K). 번들된 AngularJS 는
**1.6.10** 이고(`ui/dist/scripts/vendor.js`, `se={full:"1.6.10",major:1,minor:6,dot:10,
codeName:"crystalline-persuasion"}` @**byte** 98389), 재귀하강 파서의 우선순위 사슬이
@byte 167616 부터 그대로 읽힌다:

```
assignment     → ternary ( "=" assignment )?
ternary        → logicalOR ( "?" expression ":" expression )?
logicalOR      → logicalAND ( "||" logicalAND )*                      ; 좌결합 **반복**
logicalAND     → equality  ( "&&" equality )*
equality       → relational ( ("=="|"!="|"==="|"!==") relational )*   ; @167616
relational     → additive ( ("<"|">"|"<="|">=") additive )*           ; @167789
additive       → multiplicative ( ("+"|"-") multiplicative )*         ; @167960
multiplicative → unary ( ("*"|"/"|"%") unary )*                       ; @168124
unary          → ("+"|"-"|"!") unary | primary                        ; @168262
```

즉 **equality 와 relational 이 서로 다른 레벨**이고 둘 다 **좌결합으로 반복**한다.
(위 `scripts.js` 오프셋은 종전 판이 **문자** 오프셋으로 적었다 — 여기 `vendor.js` 오프셋은
**바이트**다. `scripts.js` 바이트로는 `evalCondition` 이 106657 · 375400 · 613938 이다.)

브라우저 경로에는 정규화가 하나 더 있다: `l.condition = l.condition.replace("$","")` — **첫 `$` 하나**를
지운다(@88419). 에디터 경로에는 없다. Waple 은 이 정규화를 하지 않는다(설치본 코퍼스 도달 0).

### 7.2 실물 조건 코퍼스 (설치본 전수, 22건 / 고유 16종) — **§7.6 에서 정정됨**

> **[2026-08-21 클러스터 AF 정정]** 아래 표의 "22건 / 고유 16종" 은 **서로 다른 두 키를 합산한
> 수**다. 특히 "맨 숫자 리터럴 `1` / `0` 5건" 은 이 문법이 **아니다** — `scene.json` 의
> `<binding>.user.condition` 이고 콤보 값 동등비교다. 갈라 센 수와 근거는 §7.6.
> 표 자체는 툼스톤으로 남긴다.


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

### 7.4 비교 연산의 레벨·결합 — **닫았다**(2026-08-21 클러스터 Q)

K 는 이 항목을 "고치면 `canEvaluate` 가 뒤집혀 두 소비처가 함께 움직인다" 는 이유로 문서화만
했다. 그 두 소비처를 실제로 재서 **움직이는 건수가 0** 임을 확인하고 고쳤다.

**소비처 실측**

| 소비처 | 코드 | `canEvaluate` 가 false→true 로 바뀌면 |
|---|---|---|
| `WallpaperCompatibilityAnalyzer` | `:468` `!canEvaluate(condition)` → `.warning .propertyDisplayCondition` | 경고가 **줄기만** 한다 |
| `DeepScan` | `:343` `canEvaluate(c) && evaluate(c, …) != nil` → `conditionsEvaluable += 1` | 집계가 **늘기만** 한다 |

두 소비처 모두 `canEvaluate` 의 **단조 함수**이고, 이 문법 확장 자체가 **단조 확대**다
(지금 파스되는 식은 전부 그대로, 같은 값으로 파스된다 — 종전에 실패하던 연쇄만 새로 성공한다).
설치본 `condition` **22건 / 고유 16종**을 재수집해 비교 연산자가 둘 이상 연쇄하는 식이
**0건**임을 확인했다(전부 `&&` 로만 이어진다 — §7.2 의 분포가 그대로 재현됐다).
따라서 **설치본 코퍼스 위에서 두 소비처의 수치는 한 건도 움직이지 않는다.**
`WallpaperCompatibilityAnalyzerTests` 의 `propertyDisplayCondition` 단언은 "경고가 나오지
않는다" 쪽이라 방향이 같다.

**바뀐 것**: `parseComparison` 을 `parseEquality`/`parseRelational` 두 레벨로 갈라 각각
좌결합으로 반복시켰다. 이제 `a == b == c` → `(a==b)==c` · `a > b == c` → `(a>b)==c` ·
`a == b > c` → `a == (b>c)` 로 Angular 와 같이 읽는다(종전엔 셋 다 파스 실패 → 표시).
잠금: `PropertyConditionEvaluatorTests.testComparisonChainsFollowAngularTwoLevelLeftAssociation`
(좌결합/우결합을 가르는 값까지 포함).

### 7.5 아직 남은 어긋남(고치지 않음, 도달 0 — 테스트로 못박음)

§7.1 의 실물 사슬과 한 줄씩 대조한 나머지다. 둘 다 **설치본 조건 22건 / 고유 16종에 도달 0**
이고, `PropertyConditionEvaluatorTests` 가 "현재 이렇게 동작한다" 를 잠가 둔다
(문법을 Angular 에 맞추면 그 테스트들이 깨져야 한다 — 그때 의도적으로 갱신할 것).

- **산술 연산자**: `additive`(@167960) · `multiplicative`(@168124) · 단항 `+`/`-`(@168262)가
  Waple 에 없다. 토크나이저가 미지 연산자를 만나면 조건 **전체를 파스 실패**로 돌린다
  (부분 평가 금지 — 의도된 설계). 코퍼스 도달 0.
- **`==` vs `===`**: Waple 은 둘을 같게 본다 — `equals()` 가 먼저 양변을 `number()` 로 수치화한다.
  그래서 `'1' === 1` 이 **true**(JS 는 false)다. 느슨한 쪽도 JS 그대로는 아니다 — `'' == 0` 은
  JS 가 true 인데 `Double("")` 이 nil 이라 **false** 다. 실물에서 `===`/`!==` 를 쓰는 12건은
  전건 "문자열 프로퍼티 vs 문자열 리터럴" 또는 "bool vs bool" 이라 두 규약이 같은 답을 낸다.
- **갈리지 않는 것**(확인해서 못박음): 단항 `!` 은 Angular 와 똑같이 비교보다 **강하게** 묶인다
  (`unary → … unary` @168262 ↔ `parsePrimary` 자기재귀). `n=2` 에서
  `!n.value == 1` → `(!2)==1` = **false**(`!(2==1)` 로 묶였다면 true).
  `&&`/`||` 가 피연산자 대신 `Bool` 을 돌려주는 것도 최종 소비가 `truthy` 하나라 관측 차이가 없다.

### 7.6 **`condition` 은 두 개의 다른 키다** (2026-08-21 클러스터 AF)

설치본 JSON **2,143개**를 전수로 걸어(JSONC 관용 파서, 파스 실패 1) `condition` 문자열을
키 위치별로 갈랐다.

설치본에 `condition` 이라는 이름의 키는 **46건**이고 값 타입이 문자열 22 · **객체 24** 다.
셋으로 갈린다.

| 포인터 | 건수 | 고유 | 문법 | 파스 | 소비 |
|---|---:|---:|---|---|---|
| `/general/properties/<k>/condition` | **17** | **14**(빈 문자열 1 포함) | AngularJS 식 | 브라우저 `$eval` | 표시 여부 |
| `/objects/N/visible/user/condition` | **5** | 2 (`"0"`·`"1"`) | **값 동등비교** | `wallpaper64.exe` 0x1401a4f1b | **런타임 바인딩 값** |
| `/gizmos/N/condition` | **24** | 8 | **셰이더 콤보 맵**(객체) | 에디터 | 기즈모 표시 |

셋째는 `{"PERSPECTIVE": 1}` ×10 · `{"POINTEMITTER": {"op":"ge","value":1..4}}` ·
`{"LINEEMITTER": {"op":"ge","value":1..3}}` 뿐이다(파일 10개, 고유 8종). WE 변경로그가 문법의
출처를 밝힌다 — *"Added complex condition support to shader passes, FBOs, bindings (only
supporting ge operator for now)"*(char@705260) · *"Added gt, le, lt condition operators to
passes etc."*(char@705129). 다만 **이 24건이 붙은 `gizmos` 자체가 에디터 전용**이다
(`gizmos` 문자열이 `wallpaper64.exe` 에 ASCII·UTF-16LE 어느 쪽에도 없다 —
`docs/re/unimplemented-json-keys.md` 21행). 변경로그가 말하는 엔진 쪽 자리(`passes`/`fbos`/
바인딩)에 붙은 `condition` 은 설치본 도달 **0** 이다.
**세 문법 중 AngularJS 식은 첫째 하나뿐이다.**


후자는 `projects/defaultprojects/shimmering_particles/scene.json` 의 `/objects/0..4/visible/user`
다섯이 전부다:

```json
{"user": {"condition": "0", "name": "style"}, "value": true}    // objects/0
{"user": {"condition": "1", "name": "style"}, "value": false}   // objects/1..4
```

**문법이 다르다.** 파서는 `user` 객체(태그 7)에서 `name`(태그 4 필수) · `condition`(태그 4일
때만) · `type` 셋을 `Json::Value::find` 로 읽어 0x60 바이트 객체에 굽는다:

```
0x1401a4ee2  cmp eax, 7                       ; user 가 객체인가
0x1401a4ef5  lea rdx, "name"      → find      ; 0x1401a4f01
0x1401a4f1b  lea rdx, "condition" → find      ; 0x1401a4f27
0x1401a4f41  lea rdx, "type"      → find      ; 0x1401a4f4d
0x1401a4f5d  cmp byte [r14+8], 4              ; name 은 **문자열이어야** 한다
0x1401a4f6d  call 0x14028af20 (ecx=0x60)      ; 객체 할당
0x1401a4fcf  asString(name)  → +0x20          ; std::string
0x1401a501b  cmp byte [r15+8], 4 → asString(condition) → +0x40
0x1401a5075  cmp byte [rsi+8], 4 → 0x140153700(type) → +0x18   ; "system"→1 · "usershortcut"→2 · 그 외 0
0x1401a509e  call 0x140175880                 ; 등록기(이름으로 해시 맵)
```

에디터가 이 값을 **콤보 옵션 드롭리스트**로만 고르게 한다는 것이 결정적이다:

```js
// scripts.js char@621236  — 현재 condition 이 옵션 목록에 없으면 options[0].value 로 되돌린다
e.options.findIndex(o => o.value === selectedProperty.condition) < 0 &&
  (selectedProperty.condition = e.options[0].value)
// char@621718 — combo 일 때만 condition 을 붙인다
case "combo":        e = {name: …, condition: selectedProperty.condition}; break;
case "usershortcut": e = {name: …, type: "usershortcut"};
// 템플릿 char@904986
dp-options="project.data.general.properties[selectedProperty.selected].options"
dp-selected="selectedProperty.condition"
```

라벨도 `ui_editor_user_properties_combo_value` = *"Selected combo value for this link:"* 다.
**Waple 은 이걸 이미 맞게 하고 있다** — `SceneDocument.resolveUserBindings` 가
`(current == condition)` 동등비교로 풀고(`TexImage.VariantCondition` 과 동형),
`PropertyConditionEvaluator` 는 손대지 않는다. 잘못돼 있던 것은 **문서의 도달 수**뿐이다.

#### 7.6.1 엔진도 조건을 **저작한다** — 그리고 절대 평가하지 않는다

`"condition"` 문자열(`0x140474a60`)의 이미지 전체 disp32 xref 는 **16자리**다. 그중 **10 이 쓰기**로,
전부 내장 프로퍼티 주입기 `0x140104b60–0x140108c17` 안에 있다. 이 함수는 브라우저 패널에
엔진이 얹는 프로퍼티 열여섯을 `Json::Value` 로 조립한다 — `volume`(slider) · `rate`(slider) ·
`cameraparallax`(bool) · `alignment`(combo, 옵션 6) · `alignmentposition`/`alignmentx`/
`alignmenty`/`alignmentz`(slider) · `alignmentfliph`(bool) · `wcc_v`(**combolutfilters**) ·
`wcc_amt`(slider) · `wec_e`(bool) · `wec_brs`/`wec_con`/`wec_sa`/`wec_hue`(slider).
쓰는 키는 `value` · `type` · `min` · `max` · `icon` · `text` · `order` · `options{label,value}` ·
`condition` 이다.

조건 고유 5종:

```
alignment.value<2&&checkPositionVisibility()   ; 0x1401060e1 · 0x14010620e
alignment.value==3||alignment.value==4         ; 0x1401064d1 · 0x14010688f
alignment.value==4                             ; 0x140106c37
wcc_v.value                                    ; 0x14010779c
wec_e.value                                    ; 0x140107e28 · 0x1401081bd · 0x14010858b · 0x140108a8e
```

**`checkPositionVisibility()` 가 결정적 반증이다** — 그 함수는 브라우저 스코프에만 있다
(`scripts.js` char@106119, `ea.checkPositionVisibility = function(){…}`). 엔진에는 없으므로
엔진은 자기가 쓴 조건조차 평가할 수 없다. 나머지 **읽기 6자리**도 표시 조건식 평가기가 아니다:
씬 `user` 바인딩 파서 둘(0x1401a4f1b · 0x14017512c), TEXB 변형 조건 둘(0x14015cc13 = 바깥
`condition` · 0x14015cd74 = 안쪽 `condition`, 형제 `name` 이 0x14015cd61 — `TexImage
.VariantCondition` 이 파스하는 이중 구조 그대로), 그리고 0x14001f39b · 0x140134c81.
**§7.1 의 "평가는 UI 몫" 을 이걸로 확정한다.**

이 다섯은 `general.properties` 에 실리지 않으므로 Waple 파서 도달은 여전히 0 이다. 다만
**문법 커버리지의 상한**을 보여준다: `<` · `==` · `&&` · `||` · 식별자 truthiness 는 되고
**함수 호출은 안 된다**(토크나이저가 `(`/`)` 를 남겨 `isAtEnd` 가 거짓 → 전체 파스 실패 →
관용 표시). `alignment` 의 옵션 값은 `Json::Value(intValue)`+0 대입(0x140105a4f `mov edx,1` →
0x140086ca0)이라 **숫자**이므로 `<`/`==` 는 수치 비교다.
잠금: `PropertyConditionEvaluatorTests.testEngineInjectedConditionsShowGrammarCeiling`.

#### 7.6.2 평가 컨텍스트와 "없는 프로퍼티"

```js
var ea = T.$new(true);                       // 격리 스코프 — checkPositionVisibility 만 얹혀 있다
W.evalCondition = e => … && ta.$eval(e, W.currentSelection.properties[W.selectedMonitor.location]);
```
(char@106464) 즉 **locals 가 프로퍼티 맵**이다. AngularJS 1.6 의 컴파일된 게터는 멤버 접근이
null-safe 라(`a === undefined ? undefined : a.value`) 없는 키를 던지지 않고 `undefined` 를 낸다.
관측 다섯 — `missing.value` falsy · `== 'x'` false · `> 0` false · `!missing.value` true ·
`undefined == undefined` true — 을 우리 `ConditionValue.none` 이 전부 같이 낸다.
잠금: `…testMissingPropertyReferenceIsUndefinedLikeAngular`.

#### 7.6.3 설치본 17건 전수 평가 결과

각 파일의 **실제 기본값** 위에서 평가하면 이렇다(`…testInstalledProjectConditionCorpusEvaluatesAsAuthored`):

| 파일 | 조건 | 기본값에서 |
|---|---|---|
| corsair_collection ×3 | `scene.value !== 'cartoon' && scene.value !== 'ram'` | **표시** |
| corsair_collection ×2 | `effect.value.startsWith('rainbow') === false` | 숨김 |
| corsair_collection | `effect.value.endsWith('pulse') === true` | **표시** |
| corsair_collection | `… && pulseanimation.value !== 'static'` | **표시** |
| corsair_collection | `… && pulseanimation.value === 'static'` | 숨김 |
| corsair_collection ×3 | `effect.value.endsWith('spiral') === true …` | 숨김 |
| corsair_collection | `effect.value === 'visor'` | 숨김 |
| corsair_collection | `effect.value.endsWith('wave') === true` | 숨김 |
| corsair_o_tron | `showbottom.value > 0` | **표시** |
| corsair_o_tron | `rainbowscheme.value` | 숨김 |
| dino_run | `""` | **표시**(조건 없음과 동일) |
| shimmering_particles | `style.value=='1'` | 숨김 |

`showbottom` 은 **슬라이더인데 `value` 가 문자열 `"150"`** 이다(실물 그대로). JS 의 `"150" > 0`
은 ToNumber 로 150 > 0 = true 이고, `WallpaperProperties.parse` 의 lenient 경로도
`.number(150)` 을 만들어 같은 답을 낸다.

---

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

> **[2026-08-21 클러스터 AF 정정]** 위 분포 `slider 18 · checkbox 2` 는 **세 스키마를 섞어 센 수**다.
> `checkbox` 2건과 `slider` 1건은 `projects/templates/gif/project.json` 의
> `templateoptions[0].options[]` — 즉 **템플릿 마법사 옵션**이고 `general.properties` 가 아니다
> (`{"type":"checkbox","label":"Compressed (DXT5)","key":"gif_compression",
> "texture":"materials/background.tex.json"}` — `texture` 키가 있는 전혀 다른 스키마).
> 실제 `general.properties` 전수는 **241개**다: `color 203 · slider 17 · combo 14 · bool 7`.
> 결론(`divider` 0 · `imgsrc*` 0 · 도달 0)은 그대로다. 전체 census 와 타입별 필수/선택 키,
> 기본값 규칙은 §9.

### 8.1 이 판정은 **편집 UI 전용이다** (2026-08-21 클러스터 AF)

임무가 "에디터 UI 전용이면 못 박아라" 였다. 근거 셋이고 전부 결정적이다.

1. **로케일**(`wallpaper_engine/locale/ui_en-us.json` — 값싸고 결정적):
   `ui_editor_user_properties_condition` = **"Display Condition"**,
   `ui_editor_user_properties_condition_placeholder` = `"otherkey.value == XYZ"`,
   `ui_editor_user_properties_value` = **"Default Value"**.
   조건은 *표시* 를 정하고 `value` 는 *기본값* 이다.
2. **템플릿이 `ng-if`/`ng-show` 하나로 끝난다.** 조건이 거짓이면 행이 안 그려질 뿐,
   `property.value` 는 그대로 남아 `callbackWallpaperPropertyChanged` 로 엔진에 나간다.
   숨겨진 프로퍼티의 값을 바꾸거나 지우는 코드는 없다(char@750308 · @757571 · @945562 · @993077).
3. **엔진은 조건을 쓰기만 한다** — §7.6.1 의 16 xref 분해와 `checkPositionVisibility()` 반증.

따라서 `PropertyDecoration.visibleIndices` 는 **패널에 무엇을 그릴지**만 정한다.
값 합성은 `WallpaperProperties.applying(overrides:to:)` 와 `SceneDocument.resolveUserBindings`
가 하고 **둘 다 이 판정을 보지 않는다** — 숨겨진 프로퍼티도 값은 살아 있다. WE 와 같다.

`group` 은 장식으로 치지 **않는다**. `divider` 는 `<hr>` 하나뿐이지만 `group` 은 제목 + 접기
컨테이너를 그리고 자기 `condition` 으로 **그룹 전체**를 숨긴다(char@757571). 값이 없다는 점은
같아도 화면에 남는 것이 있어 성격이 다르고, 설치본 도달 0(`group` 0건)이라 어느 쪽을 골라도
코퍼스가 안 움직인다 — 정보를 지우지 않는 쪽으로 뒀다.

---

## 9. `general.properties` 타입 전수 (2026-08-21 클러스터 AF)

### 9.1 타입 집합 — 세 층이 다르다

| 층 | 타입 | 근거 |
|---|---|---|
| 브라우저가 **그릴 줄 아는** 것 (12+1) | `color` `bool` `textinput` `slider` `volume` `combo` `combolutfilters` `directory` `file` `scenetexture` `usershortcut` `divider` + 컨테이너 `group` | `browseruserproperties.html` char@750151–757383 의 `ng-if` 전수 + 목록 빌더 char@88480 |
| 에디터가 **저작하게 해 주는** 것 (10) | scene 프로젝트: `color slider bool combo textinput scenetexture usershortcut group` / 그 외: `color slider bool combo textinput directory file group` | `EditorUserPropertyDetailsModalCtrl.typeOptions` char@617200–618900 |
| 엔진이 **주입만** 하는 것 (3) | `volume` `combolutfilters` `divider` | `wallpaper64.exe` 0x140104b60(`volume`/`rate`/`wcc_v`) · 0x14010c650(키 `_d0` = `divider`, 0x14010ce56) |

로케일이 두 번째 층을 그대로 확증한다 — `ui_editor_user_properties_type_*` 열 개가 존재하고
(`color`=Color · `slider`=Slider · `bool`=**Checkbox** · `combo`=Combo · `textinput`=**Text** ·
`directory`=Directory · `file`=File · `scenetexture`=**Texture** · `usershortcut`=User shortcut ·
`group`=Group) `volume`/`combolutfilters`/`divider` 라벨은 **없다**.
즉 **워크샵 `project.json` 에 나올 수 있는 타입은 10 이 상한**이다.

### 9.2 타입별 키와 기본값 규칙

에디터가 타입을 바꿀 때 도는 함수(char@616842, 원문):

```js
delete min, max, mode, options, step, precision, fraction;
switch (type) {
  default:          value = "";                                       // textinput/file/scenetexture/usershortcut
  case "directory": value = "", mode = "ondemand";
  case "color":     value = "1 0 0";
  case "slider":    value = 1, min = 0, max = 1, fraction = true, precision = 1;
  case "bool":      value = true;
  case "combo":     options = [], value = undefined;
}
```

저장(`ok()` char@619685):

- `precision` 은 **로드 시 −1 · 저장 시 +1** 된다 → **파일의 `precision` 은 UI 의
  "Decimal Places" 보다 1 크다.**
- `slider` + `fraction` → `precision` 을 1..4 로 클램프하고
  `step = (precision == 1) ? 1 : 0.1^(precision-1)` 을 **파생**한다.
  `fraction` 이 거짓이면 `step`·`precision` 을 **지운다**(정수 슬라이더).
  실물 대조: `shimmering_particles/count` = `{fraction:true, precision:2, step:0.1}` ✔
- 슬라이더가 아니면 `step`·`precision`·`fraction` 셋 다 지운다.
- `combo` 는 `options` 가 비면 저장이 막히고(`isOkDisabled`), `value` 가 어느 옵션과도 안 맞으면
  **`options[0].value` 로 강제**된다.
- `key` = `toLowerCase().replace(/\W+/g,"")`, 숫자로 시작하면 `_` 접두, 비면 `"newproperty"`.
- `file`/`directory` → `fileType` ∈ {`image`,`video`}; `directory` 는 추가로
  `mode` ∈ {`ondemand`,`fetchall`}.
- 브라우저 렌더 폴백(파일에 없을 때): rzslider 가 `step: step||1` · `precision: precision||1`
  (char@751619), `floor/ceil` = `min`/`max`.

### 9.3 설치본 코퍼스 도달 (`project.json` 191개 · JSON 2,143개 전수 워크)

```
general.properties 를 가진 파일 180 / 프로퍼티 241개
  color   203  type·text·value 203/203 · order 182 · condition 4 · index 3 · shadername 2
  slider   17  type·text·value·order·min·max 17/17 · precision 9 · step 9 · fraction 6
                   · condition 4 · editable 3 · index 2
  combo    14  type·text·value·options 14/14 · order 13 · condition 7 · index 1
  bool      7  type·text·value·order 7/7 · condition 2
  value 의 JSON 타입: color 전건 문자열 · combo 전건 문자열 · bool {bool 6, 문자열 1}
                       · slider {int 15, float 1, 문자열 1}
  options 원소 키는 {label, value} 둘뿐(53쌍)
```

`textinput` · `file` · `directory` · `scenetexture` · `usershortcut` · `group` · `divider` ·
`volume` · `combolutfilters` 는 **도달 0**. 동봉 트리(`Sources/WapleRender/Resources/WEAssets`)는
프로퍼티 161개가 **전부 `color`** 다. 2,143 JSON 전수 워크에서 241/241 이 `/general/properties`
밑이었다 — 다른 자리에 사는 `properties` 맵은 없다.

**Waple 파서가 아직 안 읽는 키**: `precision`(9) · `fraction`(6) · `editable`(3) ·
`shadername`(2) · `icon`(0) · `disabledcondition`(0). 전부 편집 UI 메타이고 런타임 값과 무관해
소비처가 생기기 전엔 담을 이유가 없다. 담게 되면 §9.2 의 `precision` ±1 규약을 같이 옮겨야 한다.

**[미해결] `order` 와 `index` 의 관계.** 브라우저는 `i.sort((e,t) => e.order - t.order)` 하나뿐이고
(char@88420) `index` 를 정렬에 쓰지 않는다. 그런데 에디터의 프로퍼티 목록은 현대 판에서
**`order` 를 지우고 `index` 를 0부터 다시 매긴다**(char@503002
`delete e.order, e.index = t, ++t` · char@503858 `movePropertyToIndex`). 설치본
`shimmering_particles` 는 여섯 프로퍼티가 `index` 0·0·1·2·3·4(0 이 둘)이고 `order` 는 둘만 있다 —
두 키가 실제로 어떻게 화해하는지 확정하지 못했다. Waple 은 `order` 부재를 **맨 뒤 + key 오름차순**
으로 결정화한다(브라우저의 `NaN` 비교는 V8 TimSort 의 삽입 순서에 의존해 결정적이지 않다).
설치본에서 `order` 부재는 22건(color 21 · combo 1)이다.
