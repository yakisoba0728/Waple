# `remapvalue` 의 `operation` — 판정: **적용 동사**다 (값 곡선이 아니다)

리포에 양립 불가능한 두 독법이 커밋돼 있었다. 이 문서는 그 충돌을 끝낸다.

- 바이너리: `wallpaper64.exe` (imagebase `0x140000000`)
  - 문자열 포인터 표 `0x140484d90`–`0x140484f40`
  - 매퍼 `0x140260f50`(채널 20) · `0x140260fb0`(**operation 4**) · `0x140261030`(축 8) · `0x1402611f0`(이벤트 동사 14)
  - 파서/팩토리 `0x1401c5490`–`0x1401d152c`, `remapvalue` 게이트 `0x1401ce660`, `remapinitialvalue` 게이트 `0x1401ca6cd`
  - 기본값 주입기 `0x1401bfbb0`–`0x1401c0080`(오퍼레이터) · `0x1401bc4b0`–`0x1401bc980`(이니셜라이저)
  - VM 핸들러 opid 19 `0x140244874`–`0x140246ec0`, 페이드창 변종 opid 39 `0x140246ec0`–`0x14024a355`
- 에셋: `Sources/WapleRender/Resources/WEAssets/**/*.json` (설치본 `wallpaper_engine/assets/` 와 해당 11파일 **md5 동일**)
- 로케일: `wallpaper_engine/locale/ui_en-us.json` · `ui_ko-kr.json`
- 도수 정본: `spec/assets/particle-corpus.json` (`particleCorpus.operator.remapvalue` = all 12 · unique 10 — 본 문서 §2.1 과 일치)

> **방법론 메모.** 이 항목은 **x86 을 파기 전에 로케일을 읽었어야 하는** 전형이었다.
> `ui_editor_particle_remap_value_operation_remap = 'Assign'` 한 줄이 판정을 끝낸다.
> 디스어셈블은 그 뒤의 세부(어느 배열에, 어떤 산술로, 어떤 순서로)를 확정했다.

---

## 0. 판정

| 독법 | 주장 | 판정 |
| --- | --- | --- |
| **A** | `operation` 은 값 곡선 변형자. `subtract` → `v = 1 − v01` | **틀렸다.** 값 산출 구간은 `operation` 을 **한 번도 읽지 않는다** |
| **B** | `operation` 은 적용 동사. `output` 과 조합해 최종 동사를 고른다 | **맞다.** 다만 리포의 *형태*(13종 융합 `RemapVerb`)는 실물 구조가 아니다 |

실물의 형태는 융합 열거가 아니라 **직교 3축**이다:

```
output(18채널)  ×  operation(4산술)  ×  outputcomponent(all/x/y/z)
   어느 배열에        어떻게 합치나         어느 성분에
```

`operation` 은 그중 **산술 결합자** 축 하나이고, 값은 정확히 넷이다:

| 값 | enum | 런타임 산술 | 로케일(en-us) |
| ---: | --- | --- | --- |
| 0 | `remap` | `dst = v` (`movaps`+`movups`) | **Assign** |
| 1 | `multiply` | `dst = v · dst` (`mulps`) | Multiply |
| 2 | `add` | `dst = v + dst` (`addps`) | Add |
| 3 | `subtract` | `dst = dst − v` (`subps`) | Subtract |
| 4 · 5 | (빈 칸 · 미지 문자열 센티넬) | **적용 안 함**(그 4-파티클 그룹 통째 스킵) | — |

`remap` 이 "리맵(=곡선)" 이 아니라 **"덮어쓰기(Assign)"** 라는 것이 이 이름이 만든 함정의 전부다.

### 0.1 결정적 증거 세 줄

| # | 위치 | 명령 | 의미 |
| ---: | --- | --- | --- |
| ① | `0x14024598a`–`0x1402459a5` | `mov eax,[r14+0x18]` / `dec eax` / `cmp eax,0x11` / `ja` / `mov ecx,[rdx+rax*4+0x24bcb4]` / `jmp rcx` | **`output` 이 먼저** 분기한다(18 케이스) |
| ② | `0x1402459a7`–`0x1402459b1` | `mov ecx,[r14+0x10]` / `test ecx,ecx`·`sub ecx,1`×2·`cmp ecx,1` | **그 안에서 `operation` 이** 4갈래 |
| ③ | `0x1402459d2` · `0x1402459e7` · `0x1402459fb` · `0x140245a14` | `subps`·`addps`·`mulps`·`movups` — 전부 **목적지 배열 `[rsi+0x260]` 에 대해** | 값이 아니라 **적용**을 고른다 |

그리고 **부정 증거**: 값 산출 구간 `0x140244874`–`0x1402459a5` 안에 `[r14+0x10]`(= operation) 읽기가
**하나도 없다**. 핸들러 전체(`0x140244874`–`0x140246ec0`)에서 그 오프셋을 읽는 곳은 정확히 32곳이고,
**전부 output 점프테이블 뒤**다(§5.3).

---

## 1. 리포의 두 독법 — 어떻게 공존하고 어디서 부딪히나

두 독법은 **같은 JSON 키를 두 번 소비**한다. `ParticleSystem.swift` 의 파스가 이렇게 적혀 있다
(2026-08-21 시점 줄번호; 다른 에이전트가 편집 중이라 줄은 밀릴 수 있다 — 함수명이 정본이다):

```swift
// ParticleSystem.swift:1863  parseOperators / case "remapvalue"
let parsedOperation = (o["operation"] as? String).flatMap { RemapOperation(rawValue: $0.lowercased()) }
...
} else if let verb = remapVerb(outputName, operation: parsedOperation) {   // ← 독법 B 소비
    let spec = RemapSpec(
        verb: verb,
        operation: parsedOperation ?? .remap,                              // ← 독법 A 로 다시 저장
```

### 1.1 독법 A — `ParticleSimulator.remapEval` 3단계

`ParticleSimulator.swift:1718` (`remapEval` 안):

```swift
switch spec.operation {
case .remap, .multiply, .add: v = v01
case .subtract: v = 1 - v01
}
```

정규화값 `v01∈[0,1]` 을 **단항 셰이핑**한다는 해석이다. 근거는 `RemapOperation`
(`ParticleSystem.swift:633`) 의 doc 주석에 `[추정]` 으로 명시돼 있다 — "제2 피연산자 부재".

### 1.2 독법 B — `ParticleSystem.remapVerb(_:operation:)`

`ParticleSystem.swift:1349`:

```swift
let op = operation ?? .remap
switch raw {
case "color":        return op == .multiply ? .multiplyColor : .setColor
case "opacity":      return op == .multiply ? .multiplyOpacity : .setOpacity
case "size":         return op == .multiply ? .multiplySize : .setSize
case "rotation":     return op == .add || op == .subtract ? .addRotation : .setRotation
case "angularspeed": return op == .add || op == .subtract ? .addAngularVelocity : .setAngularVelocity
case "velocity":     return op == .add || op == .subtract ? .addVelocity : .setVelocity
case "speed":        return .multiplySpeed
default:             return nil
}
```

### 1.3 충돌의 정확한 형태

`operation: "subtract"` 인 자산 하나가 오면 **두 해석이 동시에 적용된다**:

1. `remapVerb` 가 `.addRotation` 을 고르고(B),
2. `remapEval` 이 값을 `1 − v01` 로 뒤집는다(A).

실물은 `rot.z −= v` 하나다. Waple 은 `rot.z += (1−v01) 매핑값 × dt` 가 된다 — 부호도, 곡선도,
프레임 의존성도 전부 다르다. 동봉 자산에 `subtract` 가 0건이라 **오늘 눈에 안 보일 뿐**이다.

`operation` 부재(= 실물 기본 `multiply`, §6)에서는 **오늘 바로 틀린다**:
`thunderbolt.json` 의 `output:"opacity"` 2건이 `.setOpacity`(덮어쓰기)로 파스돼
`alphafade`·`alphachange` 결과를 통째로 밀어낸다. 실물은 `alpha *= v` 다.

> 종전 커밋의 자기평가는 정확했다 — `remapVerb` doc 주석이 이미
> "> **미확정 — 시뮬 쪽 감사가 필요하다.**" 로 이 충돌을 표시해 두었다. 이 문서가 그 감사다.

---

## 2. 에셋 실측 (x86 앞에)

### 2.1 도수 — `WEAssets` 트리, all / unique

`unique` = 파일 내용 sha256 중복 제거(프리뷰 사본 제거). 정본 규약은
`spec/assets/particle-corpus.json` 의 `note` 와 같다.

**`remapvalue`(오퍼레이터) — all 12 · unique 10** (`particleCorpus.operator.remapvalue` 와 일치)

| `operation` | `output` | all | unique | 파일 |
| --- | --- | ---: | ---: | --- |
| `"remap"` | `velocity` | 6 | 5 | `presets/rain/**/rain_screen*.json` |
| `"remap"` | `color` | 1 | 1 | `scenes/particleelementpreviews/remapvalue/particles/new_particle_system.json` |
| **부재** | `speed` | 3 | 2 | `presets/rain/**/rain_screen{,_4k}.json` |
| **부재** | `opacity` | 2 | 2 | `presets/lightning/**/thunderbolt.json` |
| `"add"` / `"subtract"` | — | 0 | 0 | — |

**`remapinitialvalue`(이니셜라이저) — all 3 · unique 3**

| `operation` | `output` | all | 파일 |
| --- | --- | ---: | --- |
| `"remap"` | `color` | 1 | `scenes/particleelementpreviews/remapinitialvalue/particles/new_particle_system.json` |
| **`"multiply"`** | **부재** | 1 | `presets/lightning/particles/presets/thunderbolt_beam_child.json` |
| 부재 | 부재 | 1 | `presets/lightning/previewthunderbolt/particles/presets/thunderbolt_beam_child.json` |

> **[정정] `RemapOperation` doc 주석의 "동봉 실측 `remap` 16건 · `multiply` 2건" 은 범위가 틀렸다.**
> 그 수는 동봉 트리와 **설치본 트리를 합산**한 값이다(둘은 md5 동일 사본). 동봉 트리 기준으로는
> `remap` **8**(all) · `multiply` **1**(all) 이다. `spec/assets/particle-corpus.json` 이 정본이고
> 범위 표기 없는 숫자를 쓰지 말라는 그 파일의 규약이 여기서도 그대로 적용된다.

형제 키 도수(동봉 트리, `remapvalue`+`remapinitialvalue` 15 인스턴스 all 기준):

| 키 | all | 키 | all |
| --- | ---: | --- | ---: |
| `outputrangemin` / `outputrangemax` | 11 / 11 | `inputrangemin` / `inputrangemax` | 1 / 4 |
| `transformfunction` / `transforminputscale` | 11 / 11 | `flags` | 5 |
| `input` | 6 | `inputcontrolpoint0` | 4 |
| `blendinstart` / `blendinend` | 2 / 2 | `blendoutstart` / `blendoutend` | 0 / 0 |
| **`inputcomponent`** | **0** | **`outputcomponent`** | **0** |
| **`component`**(Waple 이 읽는 키) | **0** | `min` / `max` | 0 / 0 |
| `transformoctaves` · `inputcontrolpoint1` · `outputcontrolpoint0/1` | 0 | | |

### 2.2 미리보기 씬 — 의도가 평문이다

`scenes/particleelementpreviews/remapvalue/particles/new_particle_system.json` 의 오퍼레이터:

```json
{ "id": 14, "name": "remapvalue",
  "input": "distancetocontrolpoint", "inputcontrolpoint0": 1,
  "inputrangemin": 150, "inputrangemax": 200,
  "operation": "remap", "output": "color",
  "outputrangemin": "1 0 0", "outputrangemax": "0 0 1" }
```

CP1 로부터 150→200 거리에서 색을 **빨강→파랑으로 덮어쓴다**. `operation:"remap"` 이 "곡선 항등"
이든 "Assign" 이든 이 한 건만으로는 갈리지 않는다 — **미리보기는 판정에 쓸 수 없다.**
(자매 `remapinitialvalue` 프리뷰도 같은 구조라 마찬가지다.) 판정은 §3–§5 가 한다.

에셋이 판정에 기여하는 것은 **하나**다: `operation:"multiply"` 인 `remapinitialvalue` 1건이
`output` 도 `outputrangemin/max` 도 없이 `inputrangemax:50` 만 갖는다는 사실. 독법 A 라면
"곱하기 곡선"은 제2 피연산자가 없어 의미가 없고, 독법 B 라면 "(기본 출력)에 곱한다" 로 성립한다.
§6 에서 기본 출력이 `size` 임이 확정되므로 후자다.

### 2.3 셰이더/GLSL 평문 — 도달 0

`assets/shaders/**` 와 `WEAssets/shaders/**` 전수에 `remap` 문자열 **0건**.
`remapvalue` 는 CPU 파티클 VM 전용이고 셰이더에 서술이 없다. (이 갈래는 여기서 닫힌다.)

---

## 3. 문자열 표 — 경계와 인덱서

### 3.1 포인터 배열 전수 (`.rdata`, qword)

`0x140484d90`–`0x140484f40` 은 **다섯 개의 서로 다른 어휘가 한 배열에 이어 붙은** 구간이다.
표들 사이에 구분자가 없으므로 **인접만으로 소속을 추론하면 안 된다** — 각 구획의 경계는
§3.2 의 인덱싱 코드가 정한다.

| 구간 | 원소 수 | 내용 | 인덱서 |
| --- | ---: | --- | --- |
| `0x140484d90`–`0x140484e00` | 14 | `setcolor` · `multiplycolor` · `setopacity` · `multiplyopacity` · `setcoloropacity` · `multiplycoloropacity` · `setvelocity` · `addvelocity` · `setsize` · `multiplysize` · `setrotation` · `addrotation` · `setangularvelocity` · `addangularvelocity` | `0x1402611f0` (`cmp ebx,0xe`, 센티넬 `0xf`) |
| `0x140484e00`–`0x140484e38` | 7 | `none` · `sine` · `square` · `saw` · `triangle` · `simplexnoise` · `fbmnoise` | `0x140261120`–`0x1402611e8` (언롤 7연쇄, 센티넬 `8`) |
| `0x140484e38` | — | `NULL` 한 칸. **코드가 읽지 않는다**(종단자가 아니라 정렬 구멍) | — |
| `0x140484e40`–`0x140484e80` | 8 | `all` · `x` · `y` · `z` · `sum` · `average` · `max` · `min` | `0x140261030`–`0x140261114` (언롤 8연쇄, 센티넬 `9`) |
| `0x140484e80`–`0x140484f20` | **20** | 채널 20종(§5.3 표) | `0x140260f50` (`cmp ebx,0x14`, 센티넬 `0x15`) |
| **`0x140484f20`–`0x140484f40`** | **4** | **`remap` · `multiply` · `add` · `subtract`** | **`0x140260fb0`–`0x14026102c`** (언롤 4연쇄, 센티넬 `5`) |
| `0x140484f40`– | — | 포인터가 아니다(`0x0d830f5a5b89a097` 등 이미지 밖 값) | — |

문자열 실체(바이트 덤프, `0x140491f20`부터):

```
0x140491f20  74 69 6d 65 6f 66 64 61 79 00 00 00 61 64 64 00   timeofday...add.
0x140491f30  73 75 62 74 72 61 63 74 00 00 00 00 61 6c 6c 00   subtract....all.
0x140491f60  6c 61 79 65 72 6f 72 69 67 69 6e 00 72 65 6d 61   layerorigin.rema
0x140491f70  70 00 00 00 00 00 00 00 6d 75 6c 74 69 70 6c 79   p.......multiply
```

즉 `remap`@`0x140491f6c` · `multiply`@`0x140491f78` · `add`@`0x140491f2c` · `subtract`@`0x140491f30`.
(`RemapOperation` doc 주석의 네 주소는 정확하다.)

### 3.2 **인접이 아니라 인덱싱 코드로** 경계를 확정한다

채널 20 표는 **루프**로 읽힌다:

```
0x140260f62  lea rsi, [rip+0x223f17]        ; 0x140484e80
0x140260f70  mov rcx, [rsi + rbx*8]
0x140260f82  cmp ebx, 0x14                  ; 20 항
0x140260f87  mov eax, 0x15                  ; 못 찾으면 21
```

operation 4 표는 **루프가 아니다** — 네 포인터를 각각 rip-상대로 직접 읽는 **언롤 연쇄**다.
그래서 "채널 표 바로 뒤에 붙어 있다" 는 관찰은 근거가 아니고, 아래 네 줄이 근거다:

```
0x140260fc0  mov rcx, [rip+0x223f59]  ; 0x140484f20  "remap"     → ebx=0
0x140260fd2  mov rcx, [rip+0x223f4f]  ; 0x140484f28  "multiply"  → ebx=1
0x140260fea  mov rcx, [rip+0x223f3f]  ; 0x140484f30  "add"       → ebx=2
0x140261002  mov rcx, [rip+0x223f2f]  ; 0x140484f38  "subtract"  → ebx=3
0x140261018  mov eax, 5                                          ; 못 찾으면 5
```

비교는 `0x140421d80`(대소문자 무시 문자열 비교)이고, 반환은 `0x14026101f  mov eax, ebx`.

**센티넬이 `4` 가 아니라 `5` 인 것은 이 바이너리의 일관된 관례다** — 매퍼 다섯을 전부 재면
예외 없이 `센티넬 = 원소 수 + 1` 이고 인덱스 `원소 수` 한 칸이 비어 있다:

| 매퍼 | 원소 수 | 유효 인덱스 | 빈 칸 | 센티넬 |
| --- | ---: | --- | ---: | ---: |
| `0x140260f50` 채널 | 20 | 0..19 | 20 | **21**(`0x15`) |
| `0x140260fb0` operation | 4 | 0..3 | 4 | **5** |
| `0x140261030` 축 | 8 | 0..7 | 8 | **9** |
| `0x140261120` transform | 7 | 0..6 | 7 | **8** |
| `0x1402611f0` 이벤트 동사 | 14 | 0..13 | 14 | **15**(`0xf`) |

런타임 영향은 없다 — 빈 칸도 센티넬도 §5.2 의 `jne` 로 **무동작**이다.

### 3.3 Waple `RemapVerb` 의 출처는 `remapvalue` 가 아니다

`RemapVerb`(`ParticleSystem.swift:589`) 의 doc 주석은 raw 문자열의 출처를
"wallpaper64.exe 스트링 @0x491fd0–0x4920b0" 이라 적는다. 그 구간(VA `0x140491fd0`–`0x1404920bb`)은
§3.1 첫 구간, 즉 **`inheritvaluefromevent` / `inheritinitialvaluefromevent` 전용 어휘**다.
호출부가 그것을 못 박는다 — `0x1402611f0` 을 부르는 곳은 딱 둘이고 둘 다 그 두 원소의 분기다:

| 호출부 | 소속 분기 |
| --- | --- |
| `0x1401cb0d0` | 이니셜라이저 `inheritinitialvaluefromevent` (게이트 `0x1401cb069`) |
| `0x1401cf1c5` | 오퍼레이터 `inheritvaluefromevent` (게이트 `0x1401cf157`) |

`remapvalue` / `remapinitialvalue` 분기는 이 표를 **전혀 부르지 않는다**(§4).
그리고 `RemapVerb` 의 13개 중 **`multiplyspeed` 는 바이너리 어디에도 없는 문자열이다**
(`wallpaper64.exe` 전수 검색 0건 — `setspeed` 도 0건). 즉 `RemapVerb` 는
"다른 원소의 어휘 12개 + Waple 이 만든 1개" 이고, `remapvalue` 의 실물 어휘가 아니다.

---

## 4. 파스 — `operation` 이 레코드 어디에 앉는가

`remapvalue` 게이트는 `0x1401ce660`(`stricmp` 대상 `"remapvalue"`@`0x140490058`).
그 안에서 **기본값 주입기 → 리드 → 매퍼 → 레코드 저장** 이 키마다 한 벌씩 돈다.

```
0x1401ce6a0  call 0x1401bfbb0        ; 기본값 주입기 (§6)
0x1401ce6a5  lea rdx, "operation"
0x1401ce6d0  call 0x140085ca0        ; 문자열 획득(Json::Value → const char*)
0x1401ce6d8  call 0x140260fb0        ; MAP_OPERATION  → eax ∈ {0,1,2,3,5}
0x1401ce6e4  mov dword ptr [rsi], eax        ; ★ 페이로드 +0x00
```

| 키 | 매퍼 | 페이로드 오프셋 | 저장 VA | VM 에서 (`r14`+0x10) |
| --- | --- | --- | --- | --- |
| `operation` | `0x140260fb0` (4) | **`+0x00`** | `0x1401ce6e4` | `[r14+0x10]` |
| `input` | `0x140260f50` (20) | `+0x04` | `0x1401ce71e` | `[r14+0x14]` |
| `output` | `0x140260f50` (20) | `+0x08` | `0x1401ce759` | `[r14+0x18]` |
| `inputcomponent` | `0x140261030` (8) | `+0x0c` | `0x1401ce794` | `[r14+0x1c]` |
| `outputcomponent` | `0x140261030` (8) | `+0x10` | `0x1401ce7cf` | `[r14+0x20]` |
| `transformfunction` | `0x140261120` (7) | `+0x14` | `0x1401ce80a` | `[r14+0x24]` |
| `flags` | 정수 획득 `0x140085f70` | `+0x1c` | `0x1401ce83d` | `[r14+0x2c]` |

레코드 헤더가 `0x10` 바이트라 **페이로드 오프셋 + 0x10 = VM 의 `r14` 오프셋**이다
(`docs/re/particle-operator-vm.md` §1.1 과 같은 규약). `[r14+0x2c]` 를 `and r9b,1` 로 쪼개는
`0x1402449a0` 이 그 대응을 교차 확인해 준다.

`remapinitialvalue`(이니셜라이저, 게이트 `0x1401ca6cd`)는 **같은 레이아웃**이다 —
`operation`@`0x1401ca74b` → `[rdi+0]`, `input`@`0x1401ca785` → `[rdi+4]`,
`output`@`0x1401ca7c0` → `[rdi+8]`.

**여기서 이미 독법 B 의 *형태*가 반증된다.** 실물은 `output` 과 `operation` 을 **각각 다른 필드에**
따로 저장한다. 융합 동사 문자열은 파스 어디에도 생기지 않는다.

---

## 5. 런타임 — 그 오프셋이 어떻게 쓰이는가

VM opid **19**(`0x13`) → 핸들러 `0x140244874` (점프테이블 `0x14024bb58` 의 `tbl[18]`).
페이드 창이 유의미하면 opid **39**(`0x27`, 파서 `mov r9d,0x27`@`0x1401cf108`) → `0x140246ec0`.

### 5.1 순서 — 값이 **먼저** 완성되고, 그 다음에 `operation` 이 나온다

```
0x140244874  값 산출 시작 (입력 채널 → inputcomponent 축약 → 정규화 → transform → outputrange 매핑)
             …  이 구간에 [r14+0x10] 읽기 0회  …
0x140245946  mulps xmm1,[rbp+0x260]   0x140245954  addps xmm1,[rbp+0x250]   ; y = span·t + min
0x14024594d  mulps xmm2,[rbp+0x240]   0x14024595b  addps xmm2,[rbp+0x200]   ; z = span·t + min
0x14024596a  test cl,cl → (flags&2) 면 출력 [0,1] 클램프
0x14024598a  mov eax,[r14+0x18]        ; ★ output
0x140245993  ja 0x140246e52            ; 1..18 밖이면 무동작
0x1402459a5  jmp rcx                   ; 18-way
0x1402459a7  mov ecx,[r14+0x10]        ; ★ operation — 여기가 최초 등장
```

값은 `xmm3`(x) · `[rbp-0x80]`(y) · `[rbp-0x70]`(z) 에, x 는 `[rsp+0x70]` 에도 스필된다.

### 5.2 4갈래 산술 — `output:"size"` 케이스 전문

```
0x140245a1d  mov ecx,[r14+0x10]
0x140245a21  test ecx,ecx      je 0x140245a7c      ; 0 remap
0x140245a25  sub ecx,1         je 0x140245a68      ; 1 multiply
0x140245a2a  sub ecx,1         je 0x140245a54      ; 2 add
0x140245a34  cmp ecx,1         jne 0x140246e57     ; 3 subtract, 그 외 무동작
0x140245a3d  mov rax,[rsi+0x270] ; movups xmm0,[rax+rdi*4] ; subps xmm0,xmm3 ; movups → dst − v
0x140245a54  mov rax,[rsi+0x270] ; addps xmm3,[rax+rdi*4]  ; movups          → v + dst
0x140245a68  mov rax,[rsi+0x270] ; mulps xmm3,[rax+rdi*4]  ; movups          → v · dst
0x140245a7c  mov rax,[rsi+0x270] ; movaps xmm0,[rsp+0x70]  ; movups          → v
```

`0x140246e52` / `0x140246e57` 은 둘 다 **다음 4-파티클 그룹으로 넘어가는 공통 꼬리**다
(`0x140246e52` 는 `mov r8,[rsp+0x40]` 복구 한 줄이 더 있을 뿐).
즉 `operation` 이 `4`·`5`(미지 문자열)이면 **그 오퍼레이터는 아무 일도 하지 않는다.**

### 5.3 출력 18채널 × 목적지 배열

`output` 은 `0x140260f50` 이 매긴 채널 인덱스이고, VM 은 `dec`+`cmp 0x11` 로 **1..18 만** 받는다.
점프테이블은 `0x14024bcb4`–`0x14024bcfc`(18 × 4바이트 = `0x48`). 끝은 두 가지로 잠긴다 —
`cmp eax,0x11`/`ja` 가 인덱스를 0..17 로 자르고, 다음 테이블의 시작이 정확히 `0x14024bcfc`
다(`docs/re/particle-operator-vm.md` §2 가 뽑아 둔 VM 테이블 베이스 목록의 `0x24bcfc`).

| idx | 채널 문자열 | 목적지(`rsi+`) | operation 스위치 수 | 비고 |
| ---: | --- | --- | ---: | --- |
| 0 | `lifetimefraction` | — | — | `ja` 로 탈락 → **무동작** |
| 1 | `maxlifetime` | `0x260` | 1 | 수명 |
| 2 | `size` | `0x270` | 1 | |
| 3 | `opacity` | `0x310` | 1 | 알파 |
| 4 | `speed` | `0x2c8/0x2d0/0x2d8` | 1 | `\|v\|` 에 산술 후 방향 보존 재스케일(§5.5) |
| 5 | `rotation` | `0x290` | 1 | **z 성분만** |
| 6 | `angularspeed` | `0x2a8` | 1 | **z 성분만**, `test byte [rsi+0x24],2` 게이트 |
| 7 | `distancetocontrolpoint` | `0x2b0/0x2b8/0x2c0` + `0x400` | 1 | 위치를 CP 방향으로 이동 |
| 8 | `positionbetweentwocontrolpoints` | `0x2b0/0x2b8/0x2c0` + `0x400` | 1 | |
| 9–12 | `runtime` `timeofday` `particlesystemtime` `layertime` | — | — | 테이블이 곧장 꼬리로 → **무동작** |
| 13 | `color` | `0x2f8/0x300/0x308` | 4 | |
| 14 | `position` | `0x2b0/0x2b8/0x2c0` | 4 | |
| 15 | `velocity` | `0x2c8/0x2d0/0x2d8` | 4 | |
| 16 | `controlpoint` | `0x400` | 4 | |
| 17 | `deltatocontrolpoint` | `0x2b0/0x2b8/0x2c0` + `0x400` | 4 | |
| 18 | `directiontocontrolpoint` | `0x2b0/0x2b8` + `0x400` | 4 | |
| 19 | `layerorigin` | — | — | `ja` 로 탈락 → **무동작** |

합 `8×1 + 6×4 = 32` — §0.1 의 32 와 정확히 맞는다.

`speed` 만 산술이 다르다(`0x140245b05`–`0x140245ba7`): 먼저 `sqrtps` 로 `s=|v|` 를 구하고,
`operation` 으로 `s'`(= `v` / `s·v` / `s+v` / `s−v`)를 만든 뒤
`v *= (s>0 ? s'·rcp(s) : s')` 로 **방향을 보존한 채 크기만** 바꾼다. 그래서 `multiply` 는
"속도 배수", `remap` 은 "속력 지정"이 된다.

### 5.4 `outputcomponent` — 벡터 출력의 바깥 스위치

벡터 채널 6종은 `operation` **앞에** `outputcomponent`(`[r14+0x20]`)로 한 번 더 분기한다.
`color` 예(`0x140245fce`):

| 값 | 축 | 진입 | 목적지 |
| ---: | --- | --- | --- |
| 0 | `all` | `0x140246161` | `0x2f8`+`0x300`+`0x308` 세 배열 전부 |
| 1 | `x` | `0x1402460ed` | `0x2f8` |
| 2 | `y` | `0x140246071` | `0x300` |
| 3 | `z` | (폴스루 `0x140245ff5`) | `0x308` |
| 4–7 (`sum`/`average`/`max`/`min`) · 9(미지) | — | `0x140245fef  jne 0x140246e52` | **무동작** |

`sum`/`average`/`max`/`min` 은 **입력 축약 전용**이다(출력에 오면 무동작).

### 5.4.1 `inputcomponent` — 입력 축약 (2026-08-21 추가 실측)

§5.4 는 출력 축만 다뤘다. 입력 축(`[r14+0x1c]`)은 값 산출 **앞머리**에 따로 있다
(`0x140244ffe`–`0x140245091`). `dec`+`cmp eax,6`+`ja`(`0x140245002`–`0x140245007`)로 **1..7 만**
받고 7항 점프테이블 `0x14024bc80` 으로 흩는다. 표를 덤프해 확인한 대응:

| 값 | 축 | 진입 | 산술 |
| ---: | --- | --- | --- |
| 0 | `all` | (`ja` 로 표를 건너뜀) | **축약하지 않는다** — 세 성분이 각자 정규화·변환을 지난다 |
| 1 | `x` | `0x140245022` | 세 자리에 x 브로드캐스트 |
| 2 | `y` | `0x140245029` | 세 자리에 y 브로드캐스트 |
| 3 | `z` | `0x140245034` | 세 자리에 z 브로드캐스트 |
| 4 | `sum` | `0x140245059` | `(y + x) + z` |
| 5 | `average` | `0x140245043` | `((y + x) + z) · 0.33333334`(`0x140492db0`) |
| 6 | `max` | `0x140245068` | `maxps` 연쇄 (x,y) → z |
| 7 | `min` | `0x140245077` | `minps` 연쇄 |

**`all` 이 "무축약" 이라는 것이 §5.4 의 출력 `all`(=세 배열 전부)과 짝이다** — 실물 값
파이프라인은 처음부터 끝까지 **3성분**이고, 축 키 둘은 그중 어디를 좁힐지만 고른다.
Waple 의 입력 파이프라인은 아직 스칼라라 `all` 을 x 로 떨어뜨린다(종전 기본과 같은 값이라 무회귀).
**[미해결]** — 3성분 입력 파이프라인은 별건이다.

### 5.5 페이드 창 변종 — 적용 모형이 `old + w·(unweighted − old)` 임을 확정

opid 39 핸들러(`0x140246ec0`–`0x14024a355`)는 base 의 근사 복제인데, 네 산술이 전부
**가중 lerp 로 감싸여** 있다. `w` 는 `0x14022a530` 이 내고 `[rsp+0x50]` 에 스필된다
(`0x140247fe1` 호출). `output:maxlifetime` 케이스(`0x14024800a`–`0x1402480c7`):

| op | 명령 | 결과 |
| ---: | --- | --- |
| 0 `remap` | `subps xmm1,xmm0` → `mulps w` → `addps xmm0` | `old + w·(v − old)` |
| 1 `multiply` | `mulps xmm1,xmm0` → `subps xmm0` → `mulps w` → `addps xmm0` | `old + w·(v·old − old)` |
| 2 `add` | `addps xmm1,xmm0` → `subps xmm0` → `mulps w` → `addps xmm0` | `old + w·v` |
| 3 `subtract` | `subps xmm1,[rsp+0x60]` → `subps xmm0` → `mulps w` → `addps xmm0` | `old − w·v` |

즉 **`BlendWindow` doc 주석의 "필드별 `new = old + w·(unweighted − old)`" 는 옳다.**
그리고 `add` 어디에도 `dt` 곱이 없다 — **WE 의 `add` 는 rate 가 아니라 프레임당 가산**이다.

---

## 6. 부재 기본값 — `operation` 은 `remap` 이 아니라 **`multiply`** 다

WE 는 팩토리 직전에 `if (!json.find(k)) json[k] = C;` 꼴 주입기를 돌린다
(`docs/re/particle-operator-vm.md` 계열 주석과 같은 패턴). 문자열 주입기는 `0x1401d7e80`
(`Json::Value::find`@`0x140087490` 이 nil 이면 태그 4 문자열로 삽입 — `0x1401d7ead  jne` 가 게이트).

`remapvalue` 주입기 `0x1401bfbb0`–`0x1401c0080`(`.pdata` 3조각 병합, 코드는 `0x1401c001a` 의
`jmp 0x1401d8040` 로 끝난다):

| 키 | 주입 VA | 기본값 | 인덱스 |
| --- | --- | --- | ---: |
| **`operation`** | `0x1401bfbba`–`0x1401bfbda` (`mov r8,[0x140484f28]`) | **`"multiply"`** | **1** |
| `input` | `0x1401bfbdf`–`0x1401bfbf0` (`[0x140484e80]`) | `"lifetimefraction"` | 0 |
| `output` | `0x1401bfbf5`–`0x1401bfc06` (`[0x140484e90]`) | **`"size"`** | 2 |
| `inputcomponent` | `0x1401bfc0b`–`0x1401bfc1c` (`[0x140484e40]`) | `"all"` | 0 |
| `outputcomponent` | `0x1401bfc21`–`0x1401bfc32` (`[0x140484e40]`) | `"all"` | 0 |
| `inputrangemin` | `0x1401bfc8c` | int `0` | |
| `inputrangemax` | `0x1401bfd76` | int `1` | |
| `outputrangemin` | `0x1401bfe64` | int `0` | |
| `outputrangemax` | `0x1401bff52` | int `1` | |
| `inputcontrolpoint0` / `1` | `0x1401bff7d` / `0x1401bff8f` | `0` / `1` | |
| `outputcontrolpoint0` / `1` | `0x1401bffa4` / `0x1401bffb6` | `0` / `1` | |
| `transformfunction` | `0x1401bffcb`–`0x1401bffdc` (`[0x140484e00]`) | `"none"` | 0 |
| `transforminputscale` | `0x1401bffe1`–`0x1401bfff3` | `2.0f` (`0x1404927a8`) | |
| `transformoctaves` | `0x1401bfff8`–`0x1401c0008` | `3` | |
| `flags` | 꼬리 `jmp 0x1401d8040` → `0x1401d809d` | **int `1`** | |

`remapinitialvalue` 주입기 `0x1401bc4b0`–`0x1401bc980` 은 **한 곳만 다르다** —
`input` 기본이 `"maxlifetime"`(`[0x140484e88]`, `0x1401bc4df`)이다. `operation` 은 똑같이
`"multiply"`(`0x1401bc4ba`), `output` 은 똑같이 `"size"`(`0x1401bc4f5`).

> **이게 왜 큰가.** 동봉 `remapvalue` 12건 중 **5건이 `operation` 부재**다(§2.1).
> WE 는 그 5건을 전부 **곱하기**로 돌린다. Waple 은 `parsedOperation ?? .remap` 으로
> **덮어쓰기**를 고른다.

---

## 7. 배제한 가설 (구별 실험과 그 결과)

| 가설 | 참이면 관측돼야 할 것 | 실제 관측 | 판정 |
| --- | --- | --- | --- |
| **A. `operation` 은 값 곡선 변형자** | 값 산출 구간(`0x140244874`–`0x1402459a5`)에서 `[r14+0x10]` 을 읽어 `xmm` 값에 산술을 건다 | 그 구간에 `[r14+0x10]` 읽기 **0회**. 32회 전부 output 디스패치 **뒤** | **배제** |
| A′. `subtract` = `1−v` | 어딘가에 `1.0 − v` 형태(`subps xmm, (1,1,1,1)`)가 operation 3 에서만 실행된다 | operation 3 은 `subps 목적지배열, v` — 피감수가 **목적지**다 | **배제** |
| **B. `operation`+`output` = 적용 동사** | operation 이 목적지 배열에 대한 산술을 고른다 | `movaps`/`mulps`/`addps`/`subps` 4갈래 × 18 채널 | **채택** |
| B′. 파스가 융합 동사 문자열을 만든다 | 파서가 `"multiplycolor"` 류를 조립하거나 14항 표를 인덱싱한다 | `output`·`operation` 을 **다른 필드**에 저장(`+0x08`/`+0x00`). 14항 표는 `inheritvaluefromevent` 전용 | **배제** |
| C. `operation` 은 둘 다(곡선 + 동사) | 값 산출과 적용 양쪽에서 읽힌다 | 적용 쪽에서만 읽힌다 | **배제** |
| D. `remap` = 항등 곡선 | 로케일이 "Remap"/"Curve" 류 | `ui_editor_particle_remap_value_operation_remap = **'Assign'**` (ko: **'지정'**) | **배제** |

**실행하지 못한 실험**: WE 를 실제로 띄워 `operation:"subtract"` 자산의 화면을 관측하는 것.
리눅스 환경이라 실행 대조는 불가능했다. 그러나 위 다섯 갈래(코드·표·주입기·로케일·자산)가
전부 같은 방향이라 판정은 확정으로 둔다.

---

## 8. Waple 착지 지점

> **[2026-08-21 갱신] §8.1–§8.4 는 반영됐다.** 아래 네 절은 *착지 전* 상태를 기록한 것이고,
> 실제로 무엇이 어떻게 들어갔는지·자산 영향 실측·되돌리기 실험은 **§8.6** 에 있다.
> §8.5(주석 출처 정정)도 `RemapVerb` doc 주석에 반영했다.

우선순위 순. 줄번호는 2026-08-21 시점이고 **함수/심볼명이 정본**이다.

### 8.1 `remapEval` 3단계를 **삭제**한다 — 독법 A 제거

`Sources/WapleCore/ParticleSimulator.swift:1718` (`ParticleSimulator.remapEval`)

```swift
switch spec.operation {
case .remap, .multiply, .add: v = v01
case .subtract: v = 1 - v01
}
```

→ `v = v01` 로 단순화. `RemapOperation` 은 값 파이프라인에서 완전히 빠져야 한다.

**무회귀 조건**: 동봉/설치본 자산에 `subtract` 0건이므로 이 삭제만으로는 **관측 변화가 없다**.
`.remap/.multiply/.add` 는 이미 항등이었다. 즉 이 변경은 **순수 무회귀**이고 먼저 넣어도 안전하다.

### 8.2 `operation` 부재 기본값을 `.multiply` 로 — **관측이 바뀐다**

`Sources/WapleCore/ParticleSystem.swift:1876` (`parseOperators` / `case "remapvalue"`)

```swift
operation: parsedOperation ?? .remap,     // → ?? .multiply
```

및 `ParticleSystem.swift:1349` `remapVerb` 안의 `let op = operation ?? .remap` → `?? .multiply`.

**도달**: 동봉 `remapvalue` 5건(all) / 4건(unique). 그중 실제로 그림이 바뀌는 것은
`thunderbolt.json`·`previewthunderbolt/thunderbolt.json` 의 `output:"opacity"` 2건이다 —
`setOpacity`(alphafade 를 밀어냄) → `multiplyOpacity`(번개 깜빡임이 페이드 위에 얹힘).
`output:"speed"` 3건은 레거시 `.remapValue(.speed)` 경로(`hasExt == false`)를 타므로
이미 곱하기다 — **우연히 맞아 있었다.** 무회귀.

**주의**: `RemapSpec.operation` 의 doc 주석("부재 remap", `ParticleSystem.swift:738`)도 같이 고쳐야
한다. 그리고 `RemapOperation`(`:633`) 의 `[추정] remap=항등 · subtract=1−v` 블록은 **반증됐다** —
`remap`=Assign, `multiply`=×, `add`=+, `subtract`=− 로 교체.

### 8.3 `RemapVerb` 를 (채널 × 산술)로 재설계 — 구조 변경

`ParticleSystem.swift:589` `RemapVerb`, `:735` `RemapSpec.verb`, `:1349` `remapVerb`,
`ParticleSimulator.swift:573`·`:1440` 의 `switch spec.verb`, `:364` `hasDisplayRemaps`.

현재의 13종 융합 열거는 (a) 출처가 다른 원소의 어휘이고(§3.3), (b) 실물의 18×4×4 직교 조합을
표현할 수 없다. 착지 형태는 `RemapSpec` 에 `outputChannel`(열거 20종) + `operation`(4종) +
`outputComponent`(all/x/y/z) 를 두고, 시뮬레이터가 `(채널 → 대상 필드)` 와 `(산술 → 결합)` 을
따로 적용하는 것이다. `verb` 는 그 조합의 **파생 뷰**로 남기면 기존 테스트가 살아남는다.

지금 당장 고쳐야 하는 개별 오류(위 재설계 없이도 가능):

| 자리 | 지금 | 실물 |
| --- | --- | --- |
| `remapVerb` `"color"`/`"opacity"`/`"size"` | `multiply` 만 곱, 나머지 전부 set | `remap`=set · `multiply`=× · `add`=+ · `subtract`=− |
| `remapVerb` `"rotation"`/`"angularspeed"` | `add`·`subtract` → add, 그 외 set | 위와 같음. **게다가 z 성분 전용**(§5.3) |
| `remapVerb` `"speed"` | 항상 `multiplySpeed` | `operation` 4종 전부 `\|v\|` 에 적용 |
| `remapVerb` `default:` → `nil`(드롭) | 채널 7종만 지원 | 18종. 특히 `position`(14) · `controlpoint`(16) · `maxlifetime`(1) |
| `output` 부재 → `nil` → 드롭 | | 부재는 `"size"` 로 주입돼 **드롭되지 않는다**(§6) |
| `ParticleSimulator` `.addRotation`/`.addAngularVelocity` = `val * (w*dt)` | dt 곱 | **dt 없음**(§5.5) |

### 8.4 `component` 는 실물 키가 아니다

`ParticleSystem.swift:791` `RemapSpec.component`, `:1891` `pcomponent(o["component"])`,
`:2497` 근처 `pcomponent` 헬퍼.

`wallpaper64.exe` 에 `component` 라는 독립 키 문자열이 **없다**(`inputcomponent`@`0x14048f760` ·
`outputcomponent`@`0x14048f810` 만 있다 — `lea rdx` 로 실제 적재되는 주소다). 동봉 자산 도달도 0건이다.
실물 키 두 개(`inputcomponent`/`outputcomponent`, 각 `all/x/y/z/sum/average/max/min` 8종)로
갈라야 한다. `remapEval` 의 `.directionToControlPoint` 성분 선택은 `inputcomponent` 쪽이다.

**무회귀**: 동봉·설치본 도달이 양쪽 다 0이라 키를 갈아도 관측 변화가 없다.

### 8.5 `RemapVerb` doc 주석의 출처 표기 정정

`ParticleSystem.swift:589` 위 주석의 "`wallpaper64.exe` 스트링 @0x491fd0–0x4920b0" 은
`inheritvaluefromevent` 어휘 구간이다(§3.3). `remapvalue` 와 무관하다고 명시해야 한다.

---

### 8.6 착지 기록 (2026-08-21, 코드 반영 완료)

§8.1–§8.4 를 구현했다. **판정은 전부 디스어셈으로 독립 재확인했고**(아래), 자산 영향은 시뮬로
직접 재측정했다. `RemapVerb` 는 지우지 않고 `RemapSpec` 의 **읽기 뷰**로 남겼다(§8.3 의 제안대로).

### 재확인한 것 (이 커밋에서 다시 뜬 것)

| 판정 | 재확인 방법 | 결과 |
| --- | --- | --- |
| `output` 이 먼저, `operation` 이 나중 | 핸들러 전 구간 덤프 후 `[r14+0x10]` grep | **32건, 최소 주소 `0x1402459a7`** — 디스패치 `0x1402459a5` 뒤. 확인 |
| 출력 점프테이블 18항 | `pe.read(0x14024bcb4, 20*4)` | idx 8..11 이 전부 `0x140246e52`(공통 꼬리), idx 18·19 는 다음 표. 확인 |
| operation 표 4항 · 센티넬 5 | `dis(0x140260fb0, 0x140261030)` | `[0x140484f20/28/30/38]` → 0/1/2/3, `mov eax,5`. 확인 |
| 주입기 기본 `multiply`/`size`/`all` | `dis(0x1401bfbb0, 0x1401bfc40)` | `mov r8,[0x140484f28]`+`lea rdx,"operation"` → H_STRING. 확인 |
| 파스 저장 오프셋 7종 | `dis` 후 `mov dword ptr [rsi+…], eax` 추출 | `operation`+0x00 · `input`+0x04 · `output`+0x08 · `inputcomponent`+0x0c · `outputcomponent`+0x10 · `transformfunction`+0x14 · `flags`+0x1c. 확인 |
| **`rotation`/`angularspeed` 가 z 전용** | rotation 핸들러(`0x140245bac`) 목적지 + 형제 `angularmovement`(`0x14024000d`–`0x140240039`) | 회전 배열 = `0x280/0x288/0x290`, 각속도 = `0x298/0x2a0/0x2a8`. remap 은 `0x290`·`0x2a8` **하나씩**만 건드린다 → **rot.z / angvel.z**. 확인 |
| **`add` 에 `dt` 곱이 없다** | 핸들러 전 구간에서 dtScaled 슬롯 `[rbp+0xf0]` grep | **0건**. (§5.5 의 페이드 변종 논거보다 강한 직접 관측) 확인 |
| `component` 는 실물 키가 아니다 | ASCII + UTF-16LE 전수 검색 | `inputcomponent`@`0x14048f760` · `outputcomponent`@`0x14048f810` 둘뿐, `component` 단독 0건. 확인 |
| 채널 표 20 · 축 표 8 | 포인터 배열 덤프 + `strat` | §3.1 표 그대로. 확인 |

**틀린 판정은 없었다.** 새로 잰 것은 §5.4.1(입력 축약 7갈래)뿐이고, 그것은 종전 문서가
다루지 않은 자리다.

### 자산 영향 — 시뮬 실측 (동봉 12파일)

같은 자산을 두 벌 시뮬해(현 파스 vs `operation` 부재 기본을 종전 `remap` 으로 되돌린 대조군)
파티클 전 필드 비트동일 여부를 봤다. `Tests/WapleCoreTests/RemapOperationAxesTests.swift` 의
`testBundledAssetsOnlyThunderboltOpacityChangesWithTheNewDefault` 가 그 측정 자체다.

| 파일 | `remapvalue` | 경로 | 결과 |
| --- | --- | --- | ---: |
| `presets/lightning/particles/presets/thunderbolt.json` | `output:"opacity"`, operation 부재 | Ex | **바뀐다** |
| `presets/lightning/previewthunderbolt/…/thunderbolt.json` | 〃 | Ex | **바뀐다** |
| `presets/rain/particles/presets/rain_screen.json` | `velocity`+`remap` / `speed`(부재) | Ex / **레거시** | 비트동일 |
| `presets/rain/particles/presets/rain_screen_4k.json` | 〃 | Ex / **레거시** | 비트동일 |
| `presets/rain/particles/presets/rain_screen_fast.json` | `velocity`+`remap` | Ex | 비트동일 |
| `presets/rain/particles/presets/rain_screen_fast_4k.json` | 〃 | Ex | 비트동일 |
| `presets/rain/previewrainscreen/…/rain_screen.json` | 〃(사본) | Ex / **레거시** | 비트동일 |
| `presets/rain/previewrainscreen/…/rain_screen_fast.json` | 〃(사본) | Ex | 비트동일 |
| `scenes/…/remapvalue/…/new_particle_system.json` | `color`+`remap` | Ex | 비트동일 |
| `scenes/…/remapinitialvalue/…/new_particle_system.json` | (이니셜라이저, Waple 미파스) | — | 비트동일 |
| `presets/lightning/…/thunderbolt_beam_child.json` ×2 | 〃 | — | 비트동일 |

**§8.2 의 예측대로 12건 중 정확히 2건이다.** 그 둘도 **알파만** 갈린다 —
`opacity` 는 표시 파생이라 위치·속도·크기는 비트동일이고, 파티클 수가 매 프레임 같으므로
**RNG 드로 스트림이 그대로**다(`testThunderboltChangeIsAlphaOnly` 가 400스텝 전수로 못박는다).

`output:"speed"` 3건이 무회귀인 이유는 §8.2 가 적은 그대로다 — 확장 키가 **하나도 없어서**
레거시 `.remapValue(.speed)` 경로를 타고, 그쪽은 원래 곱하기였다(`우연히 맞아 있었다`).
`testBundledSpeedRemapsStayOnTheLegacyPath` 가 그 경로 선택을 못박는다.

### 구현 범위와 남긴 것

구현한 채널 9종: `maxlifetime` · `size` · `opacity` · `speed` · `rotation`(z) · `angularspeed`(z) ·
`color` · `position` · `velocity`. 각각 4산술 × (벡터 채널이면) `outputcomponent` 축.

- **실물도 무동작**인 6종(`lifetimefraction` · `runtime` · `timeofday` · `particlesystemtime` ·
  `layertime` · `layerorigin`)은 파스는 하고 적용하지 않는다 — 실물과 관측이 같다.
- **[미해결] 미구현** CP 계열 5종(`controlpoint` · `distancetocontrolpoint` ·
  `positionbetweentwocontrolpoints` · `deltatocontrolpoint` · `directiontocontrolpoint`).
  실물은 위치 배열과 함께 CP 배열 `[rsi+0x400]` 을 건드리는데 Waple 의 CP 는 `def.controlPoints`
  라는 시스템 수준 상수다. 동봉 도달 0건이라 지어내지 않았다.
- **의도적 이탈 둘**(둘 다 동봉 도달 0건, 기존 테스트가 고정하고 있다):
  `velocity`+`add`/`subtract` 는 Waple 에서 **비파괴**(이번 스텝 적분에만 실림)이고 실물은 파괴적이다.
  `speed` 도 같은 비파괴 규약이다 — 다만 `multiply` 는 `s'/s` 에서 `s` 가 상쇄돼 산술이 같다.
- **[미해결] 미지 문자열 센티넬.** `operation`/`inputcomponent`/`outputcomponent` 에 어휘 밖
  문자열이 오면 실물은 센티넬(5 / 9)을 내고 그 오퍼레이터가 **통째 무동작**이 된다. Waple 은
  열거에 센티넬 자리가 없어 부재 기본으로 떨어진다. 동봉 도달 0건이라 미뤄 뒀다.

### 되돌리기 실험 — 테스트가 실제로 무는가

프리즈한 트리에서 착지 하나씩을 되돌려 `--filter "Particle|Remap"`(315 테스트)를 돌렸다:

| 되돌린 것 | 실패 |
| --- | ---: |
| §8.1 `operation` 단항 셰이핑 복원(`subtract` → `1−v01`) | **1** |
| §8.2 부재 기본 `multiply` → `remap` | **9** (자산 실측 3 · 파스 4 · 종전 테스트 2) |
| §8.3 `rotation`/`angularspeed` 를 전 성분 + `dt` 곱으로 | **5** |
| §8.3 `output` 부재 드롭 + 채널 7종 외 드롭 | **40** |
| §8.4 `inputcomponent`/`outputcomponent` 분리 취소 | **10** |

전체(1,309 테스트) 실패 0 · spec 게이트 15종 전부 통과.

---

## 9. 남은 미확정

- **빈 칸 인덱스 `4` 의 정체.** 센티넬 규칙(`원소 수 + 1`)은 매퍼 다섯 전수로 확정했지만(§3.2),
  그 규칙이 "열거에 `Count` 항이 하나 있다" 는 뜻인지 단순 관례인지는 확인하지 못했다.
  **[미해결]** — 런타임 영향은 없다(4·5 둘 다 §5.2 의 `jne` 로 무동작).
- **`flags` 비트의 전수 의미.** 여기서 확정한 것은 둘뿐이다:
  bit0 = 정규화 입력 `t` 를 `[0,1]` 로 클램프(`and r9b,1`@`0x1402449a0`,
  `minps`/`maxps`@`0x14024510a`·`0x140245117`), bit1 = **outputrange 매핑 뒤의 최종 값**을
  `[0,1]` 로 클램프(`shr ecx,1`@`0x140244a21` → `[rbp+0x1e0]` → `test cl,cl`@`0x140245791`·
  `0x14024596a`). 기본값이 `1` 이라는 것과, `rain_screen` 의
  `flags:3` + `outputrange −5..7` 조합이 배수를 `[0,1]` 로 가둔다는 것까지가 관측이다.
  **Waple 은 `flags` 를 아예 파스하지 않는다** — 별건이고 이 문서의 판정과 독립이다.
  → **[2026-08-21 해소]** "상위 비트는 안 봤다" 를 §10.3 이 닫았다: 두 핸들러 모두
  `[r14+0x2c]` 를 **정확히 두 번** 읽고(`0x140244986`·`0x140244996` / `0x140246fc9`·
  `0x140246fd9`) bit0·bit1 만 뽑는다 — **bit2 이상은 죽어 있다.** 기본 1 의 출처도
  공유 주입 꼬리 `0x1401d8040`(`0x1401d8071` 타입 int · `0x1401d809d` 값 1)로 못박았고,
  거기로 뛰어드는 자리는 `0x1401bc91a`·`0x1401c001a` 둘뿐이다.
- **`transformfunction` 파형의 실제 모양.** §5 는 `operation` 만 다뤘다.
  → **[2026-08-21 해소]** §10.4 가 실측으로 닫았다. 디스패치는 **핸들러 안**에 있고
  (`0x14024512c`–`0x140245144`, 6항 점프 테이블 `0x14024bc9c`), 종전의 "파서가 따로
  발행하는 값 공급자 레코드" 추정은 **틀렸다.** `sine` 은 `0.5 − 0.5·cos(π·s·t)` 로
  주기가 `2/s` 이고(`RemapTransform` doc 주석의 `[추정]` 은 주기를 **2배 빠르게** 잡았다),
  `square`/`saw`/`triangle` 은 그 주석의 추정과 일치한다(`square` 의 정확한 0.5 만 갈린다 —
  실물은 최근접짝수 반올림이라 **0**). `none` 은 `transforminputscale` 을 **곱하지 않는다.**
- **`rotation`/`angularspeed` 가 z 전용인 이유.** 핸들러가 `[rsi+0x290]`·`[rsi+0x2a8]` 만
  건드리는 것은 확정이지만, 그것이 "2D 경로라 z 만" 인지 "이 채널의 정의가 z" 인지는 안 봤다.
- **실행 대조 없음.** §7 의 구별 실험은 전부 정적 관측이다.

---

## 부록 A. 재현 절차

도구는 scratchpad 의 `wpe.py` / `vdis2.py`.

**A.1 문자열 표 경계**

```python
from wpe import pe; import struct
for i in range(0, 60):          # 0x140484d90 .. 0x140484f60 을 덮는다
    va = 0x140484d90 + i*8
    print(hex(va), hex(struct.unpack('<Q', pe.read(va,8))[0]))
```

`0x140484f40` 부터 이미지 밖 값이 나오면 표 끝이다.

**A.2 매퍼 다섯**

```python
from vdis2 import dis
dis(0x140260f50, 0x140260fae)   # 채널 20,        루프,       센티넬 0x15
dis(0x140260fb0, 0x14026102c)   # operation 4,    언롤 4연쇄, 센티넬 5
dis(0x140261030, 0x140261114)   # 축 8,           언롤 8연쇄, 센티넬 9
dis(0x140261120, 0x1402611e8)   # transform 7,    언롤 7연쇄, 센티넬 8
dis(0x1402611f0, 0x14026124e)   # 이벤트 동사 14, 루프,       센티넬 0xf
```

**A.3 매퍼 호출부** — `.text` 전수에서 `e8` rel32 가 위 다섯을 가리키는 곳을 센다.
`0x140260fb0` 은 `0x1401ca73f`(remapinitialvalue) · `0x1401ce6d8`(remapvalue) **둘뿐**,
`0x1402611f0` 은 `0x1401cb0d0` · `0x1401cf1c5` **둘뿐**이다.

**A.4 파서 저장 오프셋**

```python
dis(0x1401ce600, 0x1401ce8a0)   # 0x1401ce600 이 명령 경계임을 먼저 확인할 것
```

`mov dword ptr [rsi], eax`(operation) → `[rsi+4]`(input) → `[rsi+8]`(output) → … 순서를 본다.

**A.5 핸들러에서 operation 읽기 위치**

```python
dis(0x140244874, 0x140246ec0)   # 파일로 받아 'r14 + 0x10]' 를 grep
```

32건이 나오고 **최소 주소가 `0x1402459a7`** 이면(= 디스패치 `0x1402459a5` 보다 뒤) 독법 A 는 배제된다.

**A.6 출력 점프테이블**

```python
b = pe.read(0x14024bcb4, 18*4)
[hex(0x140000000 + struct.unpack_from('<I', b, i*4)[0]) for i in range(18)]
```

**A.7 주입기 기본값**

```python
dis(0x1401bfbb0, 0x1401c0080)   # H_STRING=0x1401d7e80 / H_INT=0x1401d7be0 / H_FLOAT=0x1401d7d30
```

`mov r8, qword ptr [rip+…]` 의 **타깃 주소가 표 슬롯**이고, 거기 담긴 포인터가 기본 문자열이다
(`[0x140484f28]` → `"multiply"`).

**A.8 로케일**

```bash
python3 - <<'PY'
import json
j = json.load(open('wallpaper_engine/locale/ui_en-us.json', encoding='utf-8'))
for k, v in j.items():
    if 'remap_value_operation' in k: print(k, '=', v)
PY
```

**A.9 에셋 도수** — `WEAssets` 만 훑고 파일 sha256 로 사본을 지운 뒤
`operator[]`/`initializer[]` 에서 `name in {remapvalue, remapinitialvalue}` 인 원소를 센다.
결과가 `remapvalue` all 12 · unique 10 이면 `spec/assets/particle-corpus.json` 과 맞는 것이다.

---

## 10. [2026-08-21 추가] 값 산출식 전문 — 범위·클램프·역방향

§5 는 `operation`(적용 산술)만 다뤘다. 이 절은 그 **앞** 구간, 곧 입력 신호가 값이 되기까지의
산술을 전부 못박는다: 입력 범위 정규화 · `flags` 클램프 · `transformfunction` 파형 ·
출력 범위 매핑 · 역방향 범위(min > max) · 퇴화 범위(min == max).

### 10.0 결론 — 성분 c ∈ {x, y, z} 마다

```
span_c = inputrangemax_c − inputrangemin_c            ; 파스 시각 (vec3 sub 0x14005f0a0 @0x1401ceaf0)
if (span_c == 0.0f) span_c = 0x34000000               ; = 2^-23 ≈ 1.1920929e-07  (@0x1401cedf3)
rcp_c  = rcpps(span_c)                                ; ★ 12비트 근사, 정확한 나눗셈이 아니다 (@0x1401cee47)
outSpan_c = outputrangemax_c − outputrangemin_c       ; 파스 시각 (@0x1401cedbb) — 클램프·부호보정 없음

;--- 런타임 (VM opid 19 핸들러) ------------------------------------------------
t_c = (in_c − inputrangemin_c) · rcp_c                ; subps @0x1402450fa · mulps @0x1402450fd
if (flags & 1)  t_c = max(0, min(t_c, 1))             ; minps @0x14024510a → maxps @0x140245117
v_c = transform(t_c, transforminputscale)             ; 점프 테이블 0x14024bc9c, §10.4
out_c = outSpan_c · v_c + outputrangemin_c            ; mulps @0x140245783 · addps @0x140245788
if (flags & 2)  out_c = max(0, min(out_c, 1))         ; minps @0x140245799 → maxps @0x1402457a0
```

여기서 얻어지는 판정 넷:

1. **클램프는 `flags` 두 비트로만 켜진다.** bit0 은 정규화 직후의 `t`, bit1 은 출력 매핑
   **직후**의 최종값. 그 밖의 클램프는 없다.
2. **역방향 범위는 특수 처리가 아예 없다.** `inputrangemin > inputrangemax` 면 `span < 0` →
   `rcp < 0` → `t` 가 감소 함수가 될 뿐이다. `outputrangemin > outputrangemax` 면
   `outSpan < 0` → 출력이 `outputrangemin` 에서 내려간다. 어디에도 `abs`·min/max 스왑·
   부호 검사가 없다(§10.2, §10.5).
3. **퇴화 입력 범위(min == max)만 특수 처리가 있다.** 정확히 `0.0f` 일 때만 `2^-23` 으로
   치환되어 `rcp ≈ 2^23` 이 되고, 사실상 `inputrangemin` 에서의 계단 함수가 된다.
   출력 범위에는 나눗셈이 없으므로 그런 치환도 없다.
4. **`transforminputscale` 은 `transformfunction: none` 에서 곱해지지 않는다.**
   `none`(그리고 어휘 밖 센티넬)은 변환 디스패치를 통째로 건너뛰어 `v = t` 가 된다(§10.4).

### 10.1 레코드 오프셋 — 두 방향으로 교차 확인

파서는 `rsi`(=레코드), VM 은 `r14` 를 쓰는데 **`op = r14 + 0x10`** 이다(레코드 앞 0x10 은
VM 헤더). 그 어긋남을 모르면 표가 통째로 한 칸 밀린다. 확인은 양방향으로 했다 —
파서의 스토어와 VM 의 로드가 같은 필드를 가리키는지:

| `op+` (파서 `rsi+`) | VM `r14+` | 뜻 | 파서 근거 | VM 근거 |
| --- | --- | --- | --- | --- |
| `0x10` | `0x20` | `outputcomponent` | `0x1401ce7cf` | — |
| `0x14` | `0x24` | `transformfunction` | `0x1401ce80a` | `0x14024512c` |
| `0x18` | `0x28` | `transformoctaves` | `0x1401cf0f7` | `0x140245252` |
| **`0x1c`** | **`0x2c`** | **`flags`** | `0x1401ce83d` | `0x140244986`·`0x140244996` |
| `0x20`/`0x30`/`0x40` | `0x30`/`0x40`/`0x50` | `inputrangemin` x/y/z | `0x1401cee1a`… | `0x14024499b`… |
| `0x50`/`0x60`/`0x70` | `0x60`/`0x70`/`0x80` | `rcp(span)` x/y/z | `0x1401cee4a`… | `0x1402449ae`… |
| `0x80`/`0x90`/`0xa0` | `0x90`/`0xa0`/`0xb0` | `outputrangemin` x/y/z | `0x1401cee7a`… | `0x1402449c0`… |
| `0xb0`/`0xc0`/`0xd0` | `0xc0`/`0xd0`/`0xe0` | **`outputrange` 폭** x/y/z | `0x1401ceeb0`… | `0x1402449c8`… |
| `0xe0`/`0xe4`/`0xe8`/`0xec` | — | `outputcontrolpoint0/1` 쌍 | `0x1401cef00`… | — |
| `0xf0` | `0x100` | `transforminputscale`(브로드캐스트) | `0x1401cf0c5` | `0x14024497e` |

> **함정 16 실사례(다시).** 파서에서 `lea rdx, "flags"`(`0x1401ce803`)는 **직전 키
> (`transformfunction`)의 스토어 앞**에 스케줄돼 있다. `lea` 바로 뒤의
> `mov dword ptr [rsi+0x14], eax`(`0x1401ce80a`)는 `flags` 가 아니라 `transformfunction` 이고,
> `flags` 는 그 다음 `asInt`(`0x1401ce831`) → `mov dword ptr [rsi+0x1c], eax`(`0x1401ce83d`)다.
> 같은 어긋남이 `transforminputscale`/`transformoctaves` 쌍에도 있다
> (`lea "transformoctaves"` `0x1401cf0b7` 뒤의 `movups [rsi+0xf0]` `0x1401cf0c5` 는
> **`transforminputscale`** 이다).

### 10.2 입력 범위 — 파스 시각에 굽는다

```
0x1401ceaf0  call 0x14005f0a0                 ; span = inputrangemax − inputrangemin (vec3)
0x1401cedd1  ; i = 0..2 루프
0x1401cede0  ucomiss xmm0, xmm13              ; xmm13 = 0
0x1401cede4  jp   0x1401cedf9                 ; NaN → 치환 안 함
0x1401cede6  jne  0x1401cedf9                 ; ≠ 0 → 치환 안 함
0x1401cedf3  mov  dword ptr [rax], 0x34000000 ; ★ 정확히 0 일 때만 2^-23
0x1401cee47  rcpps xmm0, xmm1                 ; ★ 근사 역수
0x1401cee4a  movups xmmword ptr [rsi+0x50], xmm0
```

**상수 적재 자리를 셌다(함정 4 — 호출 자리가 아니라).** `0x34000000` 을 즉치로 쓰는
자리는 이미지 전체에 **정확히 2곳**이고 둘 다 파티클 파스 함수 `0x1401c5490` 안이다:

| VA | 어느 파스 |
| --- | --- |
| `0x1401cae45` | `remapinitialvalue`(이니셜라이저) |
| `0x1401cedf3` | `remapvalue`(오퍼레이터) |

**함의 셋:**

- **`rcpps` 는 근사다.** Newton-Raphson 보정이 뒤따르지 않는다(`0x1401cee47` 다음 명령이
  곧바로 `movups` 스토어다). 기본 범위 0..1 에서는 `rcp(1.0) = 1.0` 이 정확해 관측이
  안 갈리지만, `150..200`(폭 50) 같은 자리에서는 마지막 몇 비트가 다르다.
  Waple 이 정확한 나눗셈을 쓰는 것은 헤드리스 결정성 때문이고, **비트동일은 불가능**하다.
- **역방향 입력 범위**(`min > max`)는 `span < 0` → `rcp < 0` 이 되어 `t` 가 감소한다.
  분기도 보정도 없다.
- **퇴화 입력 범위**(`min == max`)는 `rcp(2^-23) = 2^23` 이라 `t` 가 폭발하고,
  `flags & 1` 이면 `x < min` → 0 / `x > min` → 1 인 **계단**이 된다.
  `flags & 1` 이 아니면 그대로 8388608 배가 흘러나간다.

### 10.3 `flags` — 비트 둘뿐이고, 기본값은 1이다

**읽는 자리는 핸들러마다 정확히 둘**이고 그게 전부다:

```
0x140244986  mov   ecx, dword ptr [r14+0x2c]
0x140244996  movzx r9d, byte ptr  [r14+0x2c]
0x1402449a0  and   r9b, 1                 ; bit0 → t 클램프 게이트
0x140244a21  shr   ecx, 1
0x140244a2a  and   cl, 1                  ; bit1 → 최종값 클램프 게이트
0x140244a6b  mov   dword ptr [rbp+0x1e0], ecx
```

페이드창 변종(opid 39)도 같다: `0x140246fc9` · `0x140246fd9` · `0x140246fe3`.
**bit2 이상을 읽는 자리는 두 핸들러 어디에도 없다** — 파서도 `[rsi+0x1c]` 를 한 번 쓰기만 하고
읽지 않는다. 곧 `remapvalue`/`remapinitialvalue` 에 관한 한 **상위 비트는 죽어 있다**.
(§9 의 "상위 비트는 안 봤다" 를 이것으로 닫는다.)

**부재 기본값 = int 1.** `remapvalue` 주입기(`0x1401bfbb0`–`0x1401c0080`)의 키 목록에는
`flags` 가 **없다**. 대신 두 주입기가 공유 꼬리로 **점프**해서 거기서 심는다:

```
0x1401bc91a  jmp 0x1401d8040        ; remapinitialvalue 주입기 0x1401bc4b0 의 꼬리
0x1401c001a  jmp 0x1401d8040        ; remapvalue        주입기 0x1401bfbb0 의 꼬리
```

`0x1401d8040` 이 하는 일:

```
0x1401d8050  lea  rdx, [0x14048f4cc]           ; "flags"
0x1401d8057  call 0x140087490                  ; Json::Value::find
0x1401d805f  jne  0x1401d810b                  ; 이미 있으면 아무것도 안 한다
0x1401d8071  mov  byte ptr [rsp+0x28], 1       ; 임시 Json::Value 의 타입 = 1(intValue)
0x1401d8088  call 0x140086de0                  ; json["flags"]
0x1401d809d  mov  qword ptr [rax], 1           ; ★ 값 = 1
```

**꼬리로 뛰어드는 자리는 위 둘뿐**이다(이미지 전수). 곧 `flags` 기본 1 은 remap 계열 두
원소에만 적용된다 — 다른 오퍼레이터의 동명 `flags` 와 무관하다.

그리고 파스는 `asInt`(`0x140085f70` @`0x1401ce831`) 직독이라 **`isNumeric` 게이트가 없다**
— 브리프 함정 18 그대로, `"flags": true` 는 1로 들어온다.

기본 1 의 뜻: **`t` 는 기본으로 `[0,1]` 로 잘리고, 출력은 기본으로 안 잘린다.**
동봉 자산이 정확히 그 규약에 기대고 있다 — `rain_screen` 의 `simplexnoise` 항목은
`flags` 를 안 쓰면서 `outputrangemin: "-100 -50 0"`/`outputrangemax: "100 -500 0"` 을
쓴다(출력 클램프가 켜져 있으면 전부 죽는다). 같은 파일의 `fbmnoise` 항목만
`flags: 3` 으로 **둘 다** 켜고 `-5..7` 을 `[0,1]` 로 가둔다.

### 10.4 `transformfunction` — 파형 넷을 실측했다 (§9 의 [추정] 해소)

문자열 포인터 표 `0x140484e00` 을 다시 떠서 어휘 순서를 확정했다(NULL 종단):

| 값 | 문자열 VA | 이름 |
| ---: | --- | --- |
| 0 | `0x14047709c` | `none` |
| 1 | `0x140491fc0` | `sine` |
| 2 | `0x140491fc8` | `square` |
| 3 | `0x140491f84` | `saw` |
| 4 | `0x140491f88` | `triangle` |
| 5 | `0x140491f98` | `simplexnoise` |
| 6 | `0x140491fa8` | `fbmnoise` |
| 7 | (NULL) | 표 끝 → 센티넬 8 |

디스패치는 **핸들러 안에** 있다(종전 문서의 "핸들러 밖 값 공급자 레코드" 추정은 틀렸다):

```
0x14024512c  mov  eax, dword ptr [r14+0x24]     ; transformfunction
0x140245137  dec  eax
0x140245139  cmp  eax, 5
0x14024513c  ja   0x140245928                   ; 0(none) 과 ≥7(센티넬) → 변환 없음
0x140245144  mov  ecx, dword ptr [rdx+rax*4+0x24bc9c]   ; 6항 점프 테이블 0x14024bc9c
```

`0x140245928` 은 `movaps xmm12, [1.0]` 하나 하고 곧장 출력 매핑(`0x140245779`)으로 뛴다 —
**`v = t` 이고 `transforminputscale` 을 곱하지 않는다.**

여섯 암과 산술(모두 `s = transforminputscale`, `u = s·t`, `xmm15 = 0.5` @`0x14023fd64`):

| 값 | 이름 | 암 VA | 산술 |
| ---: | --- | --- | --- |
| 1 | `sine` | `0x140245150` | `0.5·sin(π·s·t − π/2) + 0.5` = **`0.5 − 0.5·cos(π·s·t)`** |
| 2 | `square` | `0x14024544a` | `roundEven(u − trunc(u)) + (u < 0 ? 1 : 0)` = `frac(u) > 0.5 → 1, else 0`(정확히 0.5 는 **0**) |
| 3 | `saw` | `0x1402454ea` | `(u − trunc(u)) + (t < 0 ? 1 : 0)` = `frac(u)` |
| 4 | `triangle` | `0x140245578` | `1 − \|2·frac(\|u\|) − 1\|` |
| 5 | `simplexnoise` | `0x14024562a` | `0.5·noise + 0.5` |
| 6 | `fbmnoise` | `0x1402457ad` | `0.5·fbm(octaves) + 0.5` |

근거(각 암의 결정적 명령):

* **sine** — `mulps xmm7, xmm9`(`0x140245164`)에서 `xmm9 = transforminputscale · π`
  (`0x14024498e` 가 `[0x1404836d0]` = `3.14159274f` 를 곱해 만든다), 이어
  `subps xmm7, [0x1404836c0]`(`0x140245168`, `1.5707964f` = π/2).
  그 뒤는 Cephes `sinf` 의 벡터 인라인이다 — 4/π `0x1404836a0` = `1.27323949f`,
  DP1 `0x1404836b0` = `-0.78515625f`, DP2 `0x140483710` = `-2.4187565e-4f`,
  DP3 `0x140483700` = `-3.7748951e-8f` 가 전부 그 상수다. 마지막
  `mulps xmm6, xmm15`(`0x140245245`) + `addps xmm6, xmm15`(`0x140245249`) 가 `[0,1]` 로 접는다.
  **주기는 `t` 기준 `2/s` 다** — `π·s·t` 이지 `2π·s·t` 가 아니다.
* **square** — `roundps xmm0, xmm7, 0xb`(`0x140245456`, 0xb = 0방향 절사 + 정밀도예외억제) →
  `subps`(`0x14024545f`) → `cmpltps xmm7, xmm10`(`0x140245462`, `xmm10 = 0` @`0x140244892`) →
  `andps` 1.0(`0x140245467`) → `roundps xmm2, xmm1, 8`(`0x14024546b`, 8 = 최근접짝수) →
  `addps`(`0x140245471`). **최근접짝수라 `frac(u)` 가 정확히 0.5 면 0 이다.**
* **saw** — 부호 검사가 `u` 가 아니라 **곱하기 전의 `t`** 를 본다
  (`0x1402454f5` 에서 `xmm1 = t·s` 를 따로 만들고 `0x1402454f9` 가 `xmm7`(=`t`)을 비교).
  `s > 0` 이면 결과가 같지만 `s < 0` 이면 square 와 갈린다 — 그대로 옮겨야 하는 비대칭이다.
* **triangle** — `andps` 절댓값 마스크(`0x140245593`, `0x1402455ab`; 마스크
  `0x140483790` = `0x7fffffff`), `mulps` 2.0(`0x1402455a4`, `0x1404837b0`),
  `subps` 1.0(`0x1402455a7`), `subps xmm0(1.0), xmm7`(`0x1402455af`).

### 10.5 출력 범위 매핑 — 그리고 역방향

```
0x14024576a  movaps xmm12, [0x140483640]        ; (1,1,1,1)
0x14024577f  movaps xmm0, xmm14                 ; xmm14 = outputrange 폭 x
0x140245783  mulps  xmm0, xmmword ptr [rsp+0x70]; × v
0x140245788  addps  xmm0, xmm13                 ; + outputrangemin x
0x140245791  test   cl, cl                      ; flags bit1
0x140245799  minps  xmm0, xmm12
0x1402457a0  maxps  xmm3, xmm0                  ; xmm3 = 0
```

y·z 레인은 `0x140245935`–`0x140245986` 에 같은 모양으로 한 벌 더 있다(폭
`[rbp+0x260]`/`[rbp+0x240]`, 최소 `[rbp+0x250]`/`[rbp+0x200]`).

**곧 `out = 폭·v + min` 이고 폭은 파스 시각의 순수 뺄셈이다.** `outputrangemin >
outputrangemax` 면 폭이 음수가 되어 출력이 `min` 에서 **내려간다**. 그게 실물 자산에
실재한다 — 동봉 `scenes/particleelementpreviews/remapvalue/…/new_particle_system.json` 이
`outputrangemin: "1 0 0"` → `outputrangemax: "0 0 1"` 이다(성분별 폭 `(−1, 0, +1)`,
빨강 → 파랑). 짝인 `remapinitialvalue` 프리뷰는 그 반대(`"0 0 1"` → `"1 0 0"`)다.

### 10.6 페이드창 변종(opid 39)도 같다

`0x140247f50`–`0x140247f73` 이 base 와 글자 그대로 같은 `폭·v + min` → `flags bit1` 클램프이고,
`t` 클램프 게이트도 `0x140247702`/`0x140247753` 에 있다. **§5.5 의 가중 lerp 는 그 뒤**라
**클램프는 가중 전의 unweighted 값에 걸린다.**

### 10.7 도달 — `remapvalue` 12건의 키 실측

동봉 `Sources/WapleRender/Resources/WEAssets/**`: `operator[].remapvalue` **12건**,
`initializer[].remapinitialvalue` **3건**(§2.1 의 all 12 와 일치). 설치본
`wallpaper_engine/**` 도 같은 12+3 이다(전부 `assets/` 사본 — `projects/` 도달 0).
**워크샵 코퍼스는 이 컨테이너에 없다 — 미측정이다.**

| 파일(동봉 기준) | `transformfunction` | `transforminputscale` | `flags` | 입력범위 | 출력범위 |
| --- | --- | ---: | ---: | --- | --- |
| `scenes/particleelementpreviews/remapvalue/…` | **부재(none)** | **부재(2.0)** | 부재(1) | 150 → 200 | `"1 0 0"` → `"0 0 1"` **(역방향)** |
| `presets/lightning/particles/presets/thunderbolt.json` | `sine` | 6 | **0** | 부재 | 부재 |
| `presets/lightning/previewthunderbolt/…/thunderbolt.json` | `sine` | 6 | **0** | 부재 | 부재 |
| `presets/rain/…/rain_screen.json` ×2(+4k) | `simplexnoise` | 10 | 부재(1) | 부재 | `"-100 -50 0"` → `"100 -500 0"` |
| `presets/rain/…/rain_screen.json` ×2(+4k) | `fbmnoise` | 8 | **3** | 부재 | −5 → 7 |
| `presets/rain/…/rain_screen_fast(_4k).json` ×3 | `simplexnoise` | 10 | 부재(1) | 부재 | `"-100 -200 0"` → `"100 -1200 1"` 등 |

읽을 것 셋:

- `transformfunction` **부재**는 12건 중 **1건**뿐이고, 그 1건이 하필 입력범위·역방향
  출력범위를 둘 다 쓰는 프리뷰 씬이다.
- `flags` 를 **명시**하는 것은 3종류다: `0`(thunderbolt 2건 — 클램프 전부 끔),
  `3`(rain fbmnoise 3건 — 둘 다 켬), 나머지는 부재(=1).
- 출력범위 역방향은 성분 단위로 실재한다(`1 → 0`).

### 10.8 Waple 대조 — 갈리는 자리 넷

`ParticleSimulator.remapEval` / `remapNormalizeInput` 기준(둘 다 이 과제의 **소유 밖**이라
이번에 고치지 않았다 — 아래는 정확한 패치안이다).

| # | WE | Waple 현재 | 동봉 도달 |
| --- | --- | --- | ---: |
| **D1** | `transformfunction: none` → `v = t`, **`transforminputscale` 곱하지 않음**. 클램프는 `flags & 1` 일 때만 | `let x = normalize(raw) * spec.inputScale` 뒤 `case .none: v01 = clamp01(x)` — **항상 곱하고 항상 클램프** | **1건** (프리뷰 씬. `s` 기본 2.0 이라 램프가 2배 가팔라지고 `raw = 175` 에서 이미 포화한다 — 실물은 200) |
| **D2** | `sine` 주기가 `t` 기준 **`2/s`**(`0.5 − 0.5·cos(π·s·t)`) | `0.5 − 0.5·cos(2π·frac(s·t))` = 주기 `1/s` — **2배 빠르다** | **2건** (thunderbolt + 프리뷰. `s = 6` → 실물 3주기 / Waple 6주기) |
| **D3** | `flags` 를 파스하고 두 클램프를 그것으로 게이트 | `RemapSpec` 이 `flags` 를 **안 들고 있다**. `.none` 만 항상 클램프, 나머지는 한 번도 안 함 | `flags:0` 2건 · `flags:3` 3건 (다만 D2 와 겹치고, noise 는 이미 `[0,1]` 이라 bit1 만 실효) |
| **D4** | `square` 의 정확히 0.5 는 **0**(최근접짝수) | `f < 0.5 ? 0 : 1` → 0.5 는 1 | 0건 (동봉에 `square` 없음) |

**정확한 패치안**(소유 클러스터로 넘김):

1. `RemapSpec` 에 `public let flags: Int` 추가, 파스는 `injected(o, "flags", 1)` —
   **`asInt` 직독이라 불리언도 1/0 으로 받아야 한다**(`JSONNumerics` 의 `lenient*` 사다리).
2. `remapEval` 의 2단계를 아래로:
   ```swift
   var t = Self.remapNormalizeInput(raw, spec)          // 스케일 곱하지 않는다
   if spec.flags & 1 != 0 { t = max(0, min(1, t)) }     // 0x1402449a0 / 0x14024510a
   let u = t * spec.inputScale                          // 변환 암에서만 곱한다
   let v01: Float
   switch spec.transform {
   case .none:            v01 = t                       // ★ u 가 아니라 t (0x140245928)
   case .some(.sine):     v01 = 0.5 - 0.5 * cosf(.pi * u)          // 0x140245164/0x140245168
   case .some(.square):   let f = u - u.rounded(.towardZero)
                          v01 = f.rounded(.toNearestOrEven) + (u < 0 ? 1 : 0)
   case .some(.saw):      let f = u - u.rounded(.towardZero)
                          v01 = f + (t < 0 ? 1 : 0)     // 부호는 t 로 본다 (0x1402454f9)
   case .some(.triangle): let a = abs(u); let f = a - a.rounded(.towardZero)
                          v01 = 1 - abs(2 * f - 1)
   case .some(.simplexnoise), .some(.fbmnoise): /* 종전대로 */ break
   }
   ```
3. 4단계(출력 매핑) 뒤에 `if spec.flags & 2 != 0 { clamp01 }` 을 성분마다.
4. 순수 산술은 이미 `Sources/WapleCore/RemapOperation.swift`(이 과제가 신설)에
   `RemapValueMath` 로 뽑아 두었고 `RemapOperationMathTests` 가 잠근다 — 위 배선은
   그 함수를 부르면 된다.

### 10.9 이 절이 못 닫은 것

- **[미해결] `rcpps` 근사의 비트동일.** Waple 은 정확한 나눗셈을 쓴다. 폭이 1.0 이 아닌
  자산(프리뷰 씬 하나)에서 마지막 비트가 갈릴 수 있다. 재현하려면 12비트 근사 테이블을
  모사해야 하는데 그건 CPU 모델 의존이라 **재현하지 않는 쪽이 옳다.**
- **[미해결] 3성분 입력 파이프라인.** §5.4.1 과 같은 갭이다. 위 식은 성분마다 독립인데
  Waple 의 값 파이프라인은 스칼라라 `inputcomponent: all` + vec3 `inputrange*` 를 못 낸다.
  동봉 도달 0.
- **[미해결] `simplexnoise`/`fbmnoise` 의 입력 좌표.** `0.5·n + 0.5` 매핑은 확정했지만
  노이즈 함수에 무엇을 넣는지(위상 솔트 `[op+0x100]`, 옥타브 `[op+0x18]`)는 이 절에서
  안 뜯었다. Waple 의 `remapNoiseOctaves` 는 여전히 [추정]이다.

### 10.10 재현

```python
from vdis2 import dis
dis(0x140244874, 0x1402459a7)   # 값 산출 구간 전문 (정규화 → 클램프 → 변환 → 출력 매핑)
dis(0x1401ce660, 0x1401cf1f1)   # remapvalue 파스 + 굽기 (양끝 다 명령 경계다 — 함정 17)
dis(0x1401d8040, 0x1401d810b)   # flags 기본 1 주입 꼬리
```

```python
# 변환 점프 테이블 (6항)
from wpe import pe; import struct
b = pe.read(0x14024bc9c, 6*4)
print([hex(0x140000000 + struct.unpack_from('<I', b, i*4)[0]) for i in range(6)])
# -> 0x140245150 0x14024544a 0x1402454ea 0x140245578 0x14024562a 0x1402457ad
```

```bash
# 0x34000000 즉치 스토어가 정말 2곳뿐인지 (상수 적재 자리 세기 — 함정 4)
python3 - <<'PY'
import re, sys; sys.path.insert(0,'<scratchpad>')
from wpe import pe, DATA
T=[s for s in pe.sections if s['name']=='.text'][0]
seg=DATA[T['rawptr']:T['rawptr']+T['rawsize']]; va0=pe.imagebase+T['va']
print([hex(va0+m.start()) for m in re.finditer(rb'\xc7[\x00-\x07\x40-\x47\x80-\x87]\x00\x00\x00\x34', seg)])
PY
```

```bash
# 자산 도수
python3 - <<'PY'
import os, json
for root in ('Sources/WapleRender/Resources/WEAssets',):
    n = 0
    for dp, _, fn in os.walk(root):
        for f in fn:
            if not f.endswith('.json'): continue
            try: j = json.load(open(os.path.join(dp, f), encoding='utf-8'))
            except Exception: continue
            if not isinstance(j, dict): continue
            for e in (j.get('operator') or []):
                if isinstance(e, dict) and e.get('name') == 'remapvalue':
                    n += 1
                    print(os.path.relpath(os.path.join(dp, f), root),
                          e.get('transformfunction', '<absent>'), e.get('transforminputscale', '<absent>'),
                          e.get('flags', '<absent>'), e.get('outputrangemin', '<absent>'), e.get('outputrangemax', '<absent>'))
    print('remapvalue all =', n)   # 12
PY
```
