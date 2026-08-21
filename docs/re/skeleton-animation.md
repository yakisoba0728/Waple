# WE 스켈레톤 / 퍼펫 애니메이션 — 실물 대조

대상: `wallpaper64.exe` 2.8.42 (md5 `438cb215f20a8f6c38f57fbc3d9da588`, imagebase `0x140000000`
— 업로드본과 설치본 `wallpaper_engine/wallpaper64.exe` 의 md5 가 같음을 재확인),
설치본 `assets/` · `projects/defaultprojects/`, 에디터 UI `ui/dist/scripts/scripts.js`.
조사일 2026-08-21(초판) / **2026-08-21 재대조(2차)**. 모든 주소는 VA.

---

## 0. 요약 (Waple 과 어긋났던 것)

| # | 항목 | WE 실물 | 종전 Waple | 조치 |
|---|---|---|---|---|
| 1 | 키 오일러 3축의 **파일 순서** | **`(X, Y, Z)` = `+0x0c,+0x10,+0x14`** — 합성 `Rz(z)·Ry(y)·Rx(x)` | 초판이 `(Z,Y,X)` 로 바꿔 놓음 = **X·Z 뒤바뀜** | **되돌림(§2.1)** |
| 2 | 키 회전 보간 | 쿼터니언 **nlerp + 최단호 + 재정규화** | 오일러 성분 lerp | 수정 |
| 3 | 레이어 회전 블렌드 | 쿼터니언 nlerp | 행렬 성분 lerp(길이 수축) | 수정 |
| 4 | 레이어가 안 건드리는 본 | 건너뜀(본별 마스크) | 바인드로 되끌림 | 수정 |
| 5 | 재생 모드 문자열 | `stricmp` 로 `mirror`/`single` 만, 그 밖은 loop | `"clamp"` 를 single 별칭 취급, 대소문자 구분 | 수정 |
| 6 | 레이어 유효 가중치 | `blend × blendin램프 × blendout램프` | 없음 | 추가 |
| 7 | 정점 본 가중치 정규화 | **안 한다**(셰이더 원시 가중합) | `wsum` 나눗셈 | 유지 + 반증 주석 |
| 8 | slerp | 존재하지만 **본 물리/IK 전용**, 애니메이션 경로엔 없음 | 없음 | 기준선으로만 추가 |
| 9 | 단서의 `0.9995f` / `0.0001f` | 이 빌드에 그런 slerp 상수 없음 | — | 반증 |
| 10 | 계층 합성 피연산자 순서 | `world[i] = world[parent] ∘ local[i]`(로컬 먼저) — **실측 확정** | 자기정합 추정([미확정])이었음 | 확정(§2.4a) |
| 11 | 스케일 상속 | **상속한다.** 4×4 전체 곱, 스케일 제거·정규직교화 없음 | 명시 안 됨(코드는 이미 상속) | 명문화(§2.4a) |
| 12 | `g_Bones` 유니폼 id | **`0x71`**(`g_BonesAlpha` = `0x72`) | 초판이 `0x72`/`0x73` 으로 **한 칸 밀려** 적음 | 정정(§3) |
| 13 | 2D 퍼펫 워프 대상 | **정점 위치만.** UV 는 `v_TexCoord.xy = a_TexCoord` 로 통과 | 미조사 | 추가(§3.2) |
| 14 | 본 수 상한 | **128** — 넘으면 `int 0x29` 즉사 | 미조사 | 추가(§1.3) |
| 15 | MDLA 클립 레코드 | 클립 **선두에 `u64` id**, 헤더는 `fps·frameCount·flags·boneCount` 넷 | "헤더에 `u32 id` + `u32 0`" — 클립 0 것만 우연히 맞았다 | 정정(§6.1) |
| 16 | MDLA 본 트랙 레코드 | `u32 trackFlags` → `u32 trackBytes` → 트랙 | `u32 트랙크기` → 트랙 → `u32 블롭2크기` → 블롭2 — **다음 본의 flags 를 크기로 읽었다** | 정정(§6.1) |
| 17 | 다중 클립 퍼펫 | 클립 N개 전부 읽힌다 | **두 번째 클립부터 전부 유실**(클립당 4B + Σflags 어긋남) | 수정(§6.1) |
| 18 | MDLS 본 레코드 꼬리 | 행렬 뒤는 **본 제약 config cstring** | "u8 0 패드" — 비어 있지 않으면 전 오프셋이 밀린다 | 수정(§1.3) |
| 19 | `MDLA0003..0006` 차이 | **꼬리 블록만 늘어난다. 키 표현은 불변** | 미조사 | 확정(§6.2) |
| 20 | 음수 시간(역방향 rate) | loop 는 `T += D` 후 `fmod`, mirror 는 0 에서 **반사**(우함수) | `truncatingRemainder` 그대로 → 음수 프레임 → 소비처가 0 으로 뭉갬 | 수정(§2.2) |

### 0.1 2차 재대조 결과 (2026-08-21)

초판의 사실 주장을 원본과 표본 대조했다. **항목 2~9 는 전부 재확인해 그대로 성립**하고,
아래 넷을 정정했다.

| 정정 | 초판 | 실물 | 근거 |
|---|---|---|---|
| **A** | 파일 3축 순서 `(Z,Y,X)` | **`(X,Y,Z)`** — 초판이 축을 뒤바꾼 쪽이었다 | §2.1 |
| B | `0.9995f` = `0x3F7FBE77` | `0.9995f` = **`0x3F7FDF3B`**. `0x3F7FBE77` 은 **`0.999f`** 이고 `.rdata 0x1404926fc` 에 **실재**한다(참조자 1곳, `0x1401a9d24`) | §2.6 |
| C | 본 제약 문자열 블록에 `gd tf ik …` | 두 번째 항목 **`m`(`0x140492144`)** 이 빠져 있었다. 블록 끝도 `0x1404921e8` 이 아니라 그 자리에서 `blendtime` 이 **시작**한다(끝은 `0x1404921f1`) | §1.2 |
| D | 도수 `blending(1302)` 등의 단위 미표기 | 그 수치는 **occurrence 가 아니라 파일 수**다(occurrence 는 1314). 범위 라벨을 붙였다 | §1.2 |

정정 A 가 코드까지 되돌린 유일한 항목이다. 커밋 `18a7ae6` 의 나머지 변경(nlerp·마스크·모드·
`layerWeight`)은 재대조에서 **전부 옳았다** — 되돌리지 않았다.

### 0.2 3차 (2026-08-21, 계층 합성 · 스키닝 · 퍼펫 워프)

2차가 남긴 [미확정] 중 **첫 항목(`0x14005ecb0` 피연산자 순서)을 닫았다**. 함정 14("행/열 주도는
레이아웃만으론 판정 불가")는 여기서 **무력하다** — 곱셈 함수의 산술 자체를 뜨면 두 읽기 방식이
같은 답("r8 이 먼저 적용된다")으로 수렴하기 때문이다(§2.4a). 그리고:

* **스키닝은 선형 블렌드(LBS)** 다. 듀얼 쿼터니언은 셰이더에도 바이너리에도 없다(§3.1).
* **2D 퍼펫 워프는 정점 위치만 바꾸고 텍스처 좌표는 건드리지 않는다**(§3.2). 함정 7 대로
  x86 을 뜨기 전에 셰이더를 grep 해서 나온 답이다.
* 초판·2차가 적은 **`g_Bones` 유니폼 id 가 한 칸 밀려 있었다**(§3). 함정 16 의 그 패턴이다 —
  디스크립터 테이블에서 `lea r8, slot` / `mov slot, ID` 가 **직전 호출 뒤**에 오므로,
  "id 다음 줄의 이름" 이 아니라 "id 와 같은 슬롯을 r8 으로 받는 호출의 이름" 이 짝이다.
* **본 수 상한 128**, 본 레코드 스트라이드 `0xf0` 과 필드 오프셋(§1.3).
* 레이어 캐스케이드의 덮어쓰기 분기 판정 상수가 0 이 아니라 **1.0** 이라는 것(§2.4).

---

## 1. 동봉 자산 전수 조사

### 1.1 `.mdl`

**범위**: 저장소 트리 `Sources/WapleRender/Resources/WEAssets/` (2개) + 설치본
`/home/user/Waple-wallpaper-source/wallpaper_engine/` 전수 (28개) = **30개**. 저장소의 2개는
설치본 `assets/` 사본이다 — md5 가 바이트 동일이라 내용 고유는 **28개**
(`camera.mdl` `7b6b04d824848b4e721727b996d13490`, `sphere.mdl` `80ed368e76ac601bd8dddd89af055da4`).
저장소 트리와 설치본 `assets/` 는 `.json` 수도 1 698개로 같다.

| 매직 | 개수(30 기준) | 고유(28 기준) |
|---|---:|---:|
| `MDLV0004` | 8 | 8 |
| `MDLV0014` | 15 | 15 |
| `MDLV0017` | 2 | 1 |
| `MDLV0023` | 5 | 4 |

크기 min/중앙/max = 150 / 5 979 / 570 179 바이트(30개 기준). **본 수·프레임 수·애니메이션 수의
분포는 전부 0** 이다 — 아래 이유로 스켈레톤/애니 섹션이 하나도 없기 때문이다.

**스켈레톤/애니메이션을 가진 파일: 0개.** 30개를 **파일 전체 바이트 스캔**(섹션 파싱이 아니라
매직 4/8바이트 문자열 검색)해도 `MDLS` · `MDLA` · `MDAT` · `MDMP` · `MDLE` 가 **한 건도** 없다
(2차 재확인, 총 히트 0). 동봉 자산만으로는 스켈레톤 평가를 실측 대조할 수 없다.
(워크샵 코퍼스 451개 `.mdl` 은 이 컨테이너에 없다 — `spec/formats/mdl-deep.json` 의
`format.mdl.parseCoverage` 는 과거 Z: 드라이브 스캔 기록이고, `scripts/spec/measure_mdl_deep.py`
는 워크샵 루트가 없으면 아예 `SystemExit` 로 멎는다.) 그래서 이 문서의 근거는
**바이너리 + 동봉 셰이더 + 에디터 UI 스키마**다.

> `measure_mdl_deep.py` 가 **검사하지 않는 것**(2차 확인): 메시/정점/인덱스/AABB/트레일러/MDMP 는
> 깊이 파스하지만 `MDLS` · `MDLA` · `MDAT` · `MDLE` 섹션은 **매직 도수만 센다**(`sections` 카운터).
> 본 계층·스킨 가중치 정규화·프레임 보간·블렌딩 규약은 그 스크립트의 사정권 밖이고, 이 문서와
> `Tests/WapleCoreTests/Puppet*` 가 그 자리를 덮는다.

### 1.2 퍼펫 관련 JSON 키

**범위**: 저장소 `WEAssets/`(1 698) + 설치본 `assets/`(1 698) + 설치본 `projects/`(259)
= **3 655개**(`scripts/spec/check_lenient_json_reach.py` 의 `TREES` 와 같은 범위. 설치본
`locale/`·`ui/`·`bin/` 184개는 자산이 아니라 제외 — 그쪽까지 넣어도 아래 결론은 같다).
이 중 **63개는 엄격 JSON 파서가 못 읽는다**(`effects/*/effect.json` 계열, 대부분 preview 사본.
Waple 은 관용 리더로 읽는다 — 같은 게이트의 `MIN_LENIENT_NEEDED=31` 이 동봉 트리 단독 수치고,
동봉 31 + 설치본 `assets/` 31 + `projects/` 1 = 63 으로 맞는다). 그 63개는 **원시 바이트
정규식**(ASCII·UTF-16LE 양쪽)으로 따로 훑었고 결과는 같다.

`puppet*` / `bone*` / `skeleton*` / `animationlayers` / `ik*` / `constraint*` / `look*` /
`physics` / `blendin` / `blendout` / `blendtime` / `autosort` / `smoothing` / `stiffness` 키는
3 655개 전수에서 **0건**이다(파스 가능 3 592개 재귀 키 스캔 + 63개 원시 스캔).

실제로 등장하는 애니메이션계 키의 도수. 초판이 적은 수치는 **occurrence 가 아니라 "그 키를
가진 파일 수"** 였다 — 둘을 나란히 둔다(`frame` 이 12 대 76 으로 6배 차이인 것이 단위 표기가
왜 필요한지 보여 준다):

| 키 | 파일 수 | occurrence |
|---|---:|---:|
| `blending` | 1 302 | 1 314 |
| `rate` | 587 | 597 |
| `animationmode` | 286 | 286 |
| `length` | 112 | 115 |
| `frame` | 12 | **76** |
| `blendinstart` / `blendinend` | 26 / 24 | 34 / 32 |
| `blendoutstart` / `blendoutend` | 8 / 8 | 8 / 8 |
| `fps` / `animation` / `mode` / `wraploop` | 12 각각 | 14 각각 |

이들은 파티클·프로퍼티 애니메이션 소속이지 스켈레톤 소속이 아니다. 모델 굽기 옵션 json
(`*.mdl` 과 같은 이름, 설치본 14개)에도 `skinning` 키는 **0건**이다 — `normals` /
`tangentspace` / `seconduvchannel` / `skins` 뿐이다.

**퍼펫/스켈레톤을 쓰는 실물은 코퍼스에 0건이다.** 위 3 655개 JSON 어디에도 `puppet*` /
`animationlayers` 키가 없고, `.mdl` 30개 중 `MDLS`/`MDLA` 섹션을 가진 것도 0개다(§1.1).
그러므로 **이 문서의 모든 결론은 도달 자산 0건**이며 근거는 바이너리·셰이더·에디터 스키마다.
아래 각 절의 결론에 붙일 수 있는 "도달 건수" 는 전부 0 이다 — 렌더 실측 게이트가 없다는 뜻이고,
그래서 수치 검증은 `Tests/WapleCoreTests/PuppetPoseWEParityTests` 의 **합성 포즈 대조**로 대신한다.

퍼펫 본 스키마는 자산이 아니라 **엔진 문자열 테이블**과 **에디터**에 있다.

`.rdata 0x140492140 – 0x1404921f1` 연속 블록(파서 `0x140265c30`–`0x140266f99`).
**저장 순서 그대로**(2차에 바이트 재덤프 — 초판은 두 번째 항목 `m` 을 빠뜨렸다):

```
gd m tf ik ikce se re ti tp tm la rs ts rf ri ray raz tax tay
lamin lamax ltmax rax ikrd ikse ikfe ikrminl taz ikd ikg ikr ikrmaxl  blendtime
```

(`ikfe` 뒤 `0x1404921c4` 에 4바이트 패딩이 있고 `blendtime` 은 `0x1404921e8` 에서 **시작**해
`0x1404921f1` 에서 끝난다. 초판이 적은 `–0x1404921e8` 은 마지막 항목의 시작 주소였다.)

에디터(`scripts.js`, `makeDefaultPhysicsConstraintSettings`)가 쓰는 같은 스키마의 기본값 —
씬 액션 이름은 `puppetGetBoneConstraintsConfig`:

```js
{ se:false, rs:200, rf:20, ri:30, ts:200, tf:20, ti:30, re:false,
  ge:false, gd:"0 -1 0", m:20, s:0, a:"1 0 0",
  r:true,  rax:_, ray:_, raz:true,
  t:false, tax:true, tay:true, taz:true, tm:200,
  la:false, lamin:"0 0 -3.14159265358", lamax:"0 0 3.14159265358",
  lt:false, ltmax:100,
  ik:false, ikd:2, ikg:true, ikr:true, ikrd:25, ikce:false,
  ikrmin:0, ikrmax:Math.PI, ikcp:false, ikcpn:1, ikm:"", ikse:true, ikfe:false,
  layout:_, preset:"none" }
```

퍼펫 애니메이션 편집 기본값: `{length:10, fps:10, mode:"loop", wraploop:true, smoothing:0, stiffness:1}`.
퍼펫 계열 애셋 프로퍼티 키: `puppet`, `puppetdeformation`, `puppettopology`, `puppetblendshape`.
씬스크립트 애니메이션 레이어 config: `blendin`, `blendout`, `blendtime`, `autosort`
(`ui/dist/monaco/autocomplete/lib.sceneScript.d.ts:1426`).

### 1.3 MDLS 본 레코드 (바이너리 실측)

`0x140262530`–`0x1402625c0` 의 파스 루프. 런타임 본 구조체 **스트라이드 `0xf0`(240B)** —
`imul rcx, rax, 0xf0` @`0x140262536`(`vector::size` 도 원소 240B: `sar rax,4` + `imul
0xeeeeeeeeeeeeeef` @`0x1401d76b0`).

| 파스 순서 | 오프셋 | 내용 | VA |
|---|---|---|---|
| 1 | `+0x00` | 이름 cstring | `0x140262545` → `0x14000ddd0` |
| 2 | `+0x64` | u32 flags | `0x14026255a` → `0x140262564` |
| 3 | `+0x60` | **i32 parent**(`-1` = 루트) | `0x140262567` → `0x140262570` |
| 4 | `+0x20` | **64바이트 행렬**(부모상대 로컬 레스트) | `0x140262573`(`r8d=0x40`) → `0x1400d3ef0` |
| 5 | `+0x68` | 본 제약 config(§1.2 키 블록) | `0x1402625a9` → `0x140265c30` |

(파스 5의 config 는 **cstring** 이다 — `0x140262588` 이 읽어 `0x140265c30` 에 넘긴다. 종전 Waple
`PuppetModel` 은 이 자리를 "u8 0 패드" 로 읽고 있었다: 실물이 전부 빈 문자열이라 바이트가 같았을 뿐이고,
비어 있지 않은 본이 하나라도 있으면 이후 전 오프셋이 그 길이만큼 밀린다. 4차에 고쳤다.)

**본 수 상한은 128이다.** 섹션 헤더에서 u32 를 읽고(`0x1402624f4`) `cmp eax, 0x80`
@`0x140262501` 을 넘으면 `int 0x29`(__fastfail) @`0x14026250a` 로 **즉사**한다. `g_Bones`
유니폼 배열이 `mat4x3 × 128` = 6 144B 인 것과 맞는다. Waple 은 즉사하지 않고 그대로 읽는다
(관용 파스 — 의도적 발산, `PuppetHostileInputTests` 가 그 경로를 덮는다).

**역바인드는 파일에 없다.** 본 레코드에 행렬은 이 하나뿐이고 그건 부모상대 로컬 레스트다
(근거: 이 행렬을 TRS 로 분해해 포즈 SoA 에 시딩한 뒤 §2.4a 가 부모 체인으로 다시 합성한다 —
역바인드였다면 체인 합성이 성립하지 않는다. 그리고 코퍼스 실측 2809885105 에서 트랙 첫 키의
평행이동이 이 행렬의 평행이동과 일치한다). 따라서 모델공간 바인드는 **런타임 합성**이다.

MDLS 버전 ≥ 2(`cmp r14d, 2` @`0x1402625c6`)는 뒤에 u16 개수 + **128B 스트라이드**
(`shl rdi, 7` @`0x140262608`) 이름-달린 항목 배열을 하나 더 읽는다 — 내용 미조사.

---

## 2. 파이프라인 (VA)

MDL 디코더는 `0x140261880`–`0x140265a43`(`.pdata` 단편 6개를 이어붙인 범위. 초판이 적은
`0x140265a0c` 는 그중 한 단편의 끝이다). 섹션 매직 비교는 `memcmp` 길이 **4**라
`"MDLA"`/`"MDLS"` 만 보고 뒤 4자리는 `atoi`(`0x1402c82c0`)로 읽어 버전 게이트에 쓴다 — 그래서
`MDLA0001`(구 2D 퍼펫)과 `MDLA0006`이 같은 코드 경로다.

### 2.1 애니메이션 키 → 쿼터니언 (로드 시점) — **파일 3축은 (X, Y, Z)**

> **초판 정정.** 초판은 이 절에서 "파일 순서는 (Z,Y,X)" 라고 결론지었고 그 결론이 커밋
> `18a7ae6` 으로 코드에 들어가 **X 축과 Z 축을 실제로 뒤바꿔 놓았다**. 초판이 적은 네 개의 식
> 자체는 맞다. 틀린 것은 그 넷에 `w/x/y/z` 이름을 붙인 방식이다 — **저장 슬롯을 보지 않고
> "ZYX 쿼터니언 공식의 모양" 으로 이름을 붙였다.** 슬롯을 보면 순서가 뒤집힌다.

트랙 키는 파일에서 **36바이트**이고 키 수는 `frameCount + 1` — `0x140263c61` 에서
`movabs rax, 0xE38E38E38E38E38F` / `mul r8` / `shr rdx, 5` 로 36 나눗셈을 하고,
몫을 `[rbp+0xbc]+1`(= frameCount+1)과 `cmp` 해 다르면 `int 0x29`(`0x140263c8c`),
나머지가 0 이 아니어도 `int 0x29`(`0x140263c95`) — **둘 다 __fastfail 즉사**다.
9 float = pos3 + 각3 + scale3. 런타임 표현은 **10 float**(pos3 + quat4 + scale3) SoA.

굽기 루프 `0x140264188`–`0x1402642ae` (두 번째 사본 `0x1402644c7`–`0x1402645ea`).
`0.5f` 상수 VA `0x1404926c0`, `cosf`=`0x14041a2e0`, `sinf`=`0x14041a9c0`:

```
g = key[+0x0c] · 0.5f
b = key[+0x10] · 0.5f
a = key[+0x14] · 0.5f
slot3 = ca·cb·cg + sa·sb·sg   ; addss 0x14026422e → movss 0x140264244
slot4 = ca·cb·sg − sa·sb·cg   ; subss 0x14026426e → movss 0x140264277
slot5 = sa·cb·sg + ca·sb·cg   ; addss 0x14026427c → movss 0x140264291
slot6 = sa·cb·cg − ca·sb·sg   ; subss 0x140264250 → movss 0x1402642ae
```

**슬롯 번호의 근거.** 한 본의 트랙 블록은 10개 배열의 SoA 이고 배열 `k` 의 베이스는
`r15 + k·N` 이다(`0x1402640e0`–`0x140264129` 에서 조립: `[rbp-0x70]`=3N, `[rsp+0x30]`=4N
— `lea r13d,[r12*4]` `0x140263fd3` → `mov [rsp+0x30],r13d` `0x140263fe9` —, `[rsp+0x60]`=5N,
`[rsp+0x74]`=6N, `[rbp-0x74]`=7N, `[rsp+0x70]`=8N, `[rbp+0x28]`=9N; 블록 스트라이드는
`lea eax,[r12+r12*4]; add eax,eax` = 10N @`0x1402640a6`). 키 `+0x00/+0x04/+0x08`(위치)은
슬롯 0/1/2 로, `+0x18/+0x1c/+0x20`(스케일)은 슬롯 7/8/9 로 **그대로 복사**된다 — 즉
쿼터니언은 슬롯 3..6 이다.

**슬롯 3..6 의 성분 순서는 `(w, x, y, z)` 다.** 같은 SoA 를 본 레스트로 시딩하는 루프
`0x1401fe2f2`–`0x1401fe657` 가 이를 못 박는다: 그 루프는 행렬→쿼터니언 변환
`0x140215730`(호출 `0x1401fe4ad`, 출력 버퍼 `[rbp+0x280]`)의 4 float 을
`[+0x280]`→슬롯3, `[+0x284]`→슬롯4, `[+0x288]`→슬롯5, `[+0x28c]`→슬롯6 으로 흩어 쓴다.
그리고 `0x140215730` 의 trace 분기(`0x14021590b`–`0x140215934`)는
`0.5·sqrt(1+trace)`(= **스칼라부**)를 `[rdi+0x00]` 에, `(r21−r12)·k` 를 `[rdi+0x04]`,
`(r02−r20)·k` 를 `[rdi+0x08]`, `(r10−r01)·k` 를 `[rdi+0x0c]` 에 넣는다 — 첫 칸이 `w`,
이어서 `x,y,z`. (네 분기 전부 같은 배치. 행렬 메모리가 **열 우선**이라는 것은 §2.1 끝의
`setLocalBoneAngles` 대조로 독립 확인된다.)

대입하면

```
(x, y, z, w) = (slot4, slot5, slot6, slot3)
             = quat( Rz(key[+0x14]) · Ry(key[+0x10]) · Rx(key[+0x0c]) )
```

**즉 파일 3축의 의미는 평범하게 (X, Y, Z)이고 합성은 ZYX다.** 각 단위는 라디안(반각 계수가
`0.5f`, `π/360` 이 아님). 검증: 엔진의 `0x140215730` 알고리즘과 위 굽기 식을 그대로 옮겨
무작위 3축 400쌍에 대해 두 가설을 대조했다 — `(X,Y,Z)` 불일치 **0/400**,
`(Z,Y,X)` 불일치 **400/400**.

교차 확인 — 씬스크립트 `setLocalBoneAngles(bone, Vec3 v)`(`0x14020fce0`)이 만드는 행렬을
저장 순서대로 읽으면 `Rz(v.z)·Ry(v.y)·Rx(v.x)` 의 **열 우선** 배치와 정확히 일치한다
(입력 `[r9+8]` 의 3 float 이 `v.x,v.y,v.z`, cos/sin 은 `0x14020fd8c`–`0x14020fdcb`):

| 저장 | 값 | 열우선 해석 |
|---|---|---|
| `+0x00` `0x14020fe09` | `cos(v.y)·cos(v.z)` | r00 |
| `+0x04` `0x14020fe2b` | `cos(v.y)·sin(v.z)` | r10 |
| `+0x08` `0x14020fe31` | `−sin(v.y)` | r20 |
| `+0x10` `0x14020fe54` | `sin(v.x)sin(v.y)cos(v.z) − cos(v.x)sin(v.z)` | r01 |
| `+0x14` `0x14020fe5d` | `sin(v.x)sin(v.y)sin(v.z) + cos(v.x)cos(v.z)` | r11 |
| `+0x18` `0x14020fe7c` | `sin(v.x)·cos(v.y)` | r21 |
| `+0x20` `0x14020fe87` | `cos(v.x)sin(v.y)cos(v.z) + sin(v.x)sin(v.z)` | r02 |
| `+0x24` `0x14020fe8d` | `cos(v.x)sin(v.y)sin(v.z) − sin(v.x)cos(v.z)` | r12 |
| `+0x28` `0x14020fe93` | `cos(v.x)·cos(v.y)` | r22 |

**공개 API 와 파일 규약은 같다.** 초판이 "둘이 어긋난다" 고 적은 것은 슬롯 오독의 결과다.

### 2.2 재생 시계

클립 초기화 `0x1401a8c10`–`0x1401a8cd0` (출력 구조체 = `layer+0xf8`. 초판이 적은
`–0x1401a8ca9` 는 함수 중간의 분기 표적이다 — `.pdata` 단편은 `0x1401a8cd1` 에서 끝난다).
아래는 2차에 명령 단위로 재확인했다:

```
out[+0x00] = 1/fps                     ; divss 0x1401a8c5e → movss 0x1401a8c62
                                       ; (fps ≤ 0 이면 실패 반환: comiss 0x1401a8c21 → 0x1401a8cc4)
out[+0x08] = frameCount / fps  = D     ; divss 0x1401a8c3f → movss 0x1401a8c46
                                       ; (D ≤ 0 이면 실패: comiss 0x1401a8c43 → 0x1401a8cc4)
out[+0x0c] = flags
out[+0x10] = frameCount
stricmp(mode,"mirror")==0 → flags |= 1 ; 0x1401a8c71
stricmp(mode,"single")==0 → flags |= 2 ; 0x1401a8c87
5번째 bool 인자(wraploop)   → flags |= 4
6번째 bool 인자(startpaused)→ flags |= 0x20000000
```

**모드 문자열은 딱 둘.** `"clamp"`·`"loop"`·빈 문자열은 전부 플래그 없음 = loop.
비교가 `stricmp`(`0x1402c10d0`)라 대소문자를 가리지 않는다.

시간 전진 `Playback::advance` `0x1401a9f60`–`0x1401aa1b4`(`.pdata` 단편 7개 병합.
초판의 `0x1401aa18d` 는 마지막 분기의 끝), `fmodf` = `0x14041d0c0`:

```
if (flags & 0x60000000) return              ; 일시정지(0x20000000)/종료(0x40000000)
if (flags & 2) && T >= D  return            ; single 은 끝에서 정지
if (D <= 0) return
if (flags & 0x80000000) dt = -dt            ; 역방향 비트 (0x1401a9fc5)
T += dt ; 이벤트 마커 발화 (스트라이드 0x28, 0x1401a9ff5 / 0x1401aa020)
loop  : T < 0 이면 T += D ; T = fmodf(T, D)         ; 0x1401aa05f–0x1401aa0d7
mirror: 정방향에서 T ≥ D → T = D − fmodf(T,D), flags |= 0x80000000   ; 0x1401aa150–0x1401aa170
        역방향에서 T < 0 → T = −fmodf(T,D),   flags &= ~0x80000000   ; 0x1401aa129–0x1401aa14e
single: T ≥ D → T = D, flags |= 0x40000000                            ; 0x1401aa177–0x1401aa188
```

mirror 는 방향 비트를 가진 **상태 기계**지만 등속에서는 주기 `2D` 삼각파와 값이 같다 —
Waple 의 삼각파 구현을 그대로 둔 근거.

프레임 인덱스/보간계수 `Playback::sample` `0x140170580`–`0x1401705f6`:

```
t  = fmodf(T, fd) / fd                     ; fd = [rcx+0x00] = 1/fps  (call 0x1401705a7, divss 0x1401705ba)
i  = clamp(trunc(T / fd), 0, frameCount-1) ; cvttss2si 0x1401705be, cmov 0x1401705c8/0x1401705d1
j  = min(i + 1, frameCount)                ; lea 0x1401705dd, cmovle 0x1401705e6
```

`frameCount` = `[rcx+0x10]`, `T` = `[rcx+0x04]`. 키가 `frameCount+1` 개이므로 `j` 는 마지막 키에
닿고 `i` 는 그 앞 키까지만 간다. **Waple 은 트랙 키 수로 클램프한다** — 헤더 `frameCount` 가
실제 키 수와 어긋난 데이터에서 WE 는 범위 밖을 읽지만(그 전에 로드가 `int 0x29` 로 죽는다,
§2.1) Waple 은 마지막 키로 물린다. 정확히 `T = D` 인 순간에는 WE 가 `i = frameCount−1`,
`t = fmodf(D, fd)/fd` 를 쓰고 Waple 은 `i = frameCount, t = 0` 을 써서 **끝점에서만** 산출이
갈릴 수 있다(둘 다 마지막 키 부근, 부동소수 1 ulp 문제라 정본화하지 않았다 — [미해결]).

2차 재대조: 위 세 줄은 명령 단위로 일치. `stricmp` 두 개, 플래그 비트 넷, `layer` 필드
오프셋(`+0xcc/+0xd0/+0xf8/+0xfc/+0x100/+0x104/+0x108/+0x18c`)도 전부 재확인했다.

### 2.3 레이어 유효 가중치

`IAnimationLayer` 필드(리플렉션 등록 `0x14026c980`–`0x14026d5de`, 생성자 `0x14026c680`):

| 오프셋 | 필드 | 기본 |
|---|---|---|
| `+0xc8` | `rate` | 1.0 |
| `+0xcc` | `blend` | 1.0 |
| `+0xd0` | 플래그: bit0 `visible`, bit1 `additive`, bit2 `blendin`, bit3 `blendout` | 1 |
| `+0xd8` | `name` | "" |
| `+0xf8` | `1/fps` (`fps` 접근자 `0x14026c3e0` = `1/[+0xf8]`) | |
| `+0xfc` | 현재 시간(초). `getFrame`=`T/fd` `0x14026c4d0`, `setFrame` `0x14026c4a0` | |
| `+0x100` | `duration` `0x14026c410` | |
| `+0x104` | 재생 플래그(§2.2) | |
| `+0x108` | `frameCount` `0x14026c400` | |
| `+0x18c` | `blendtime` | **0.5f** (`0x14026c7af`) |

`effectiveBlend` `0x14026c8b0`–`0x14026c97b`:

```
eps = FLT_EPSILON = 1.1920929e-07          ; VA 0x1404925e0
w = blend
if (blendin)  { f = (min(D,bt) > eps) ? min(T / min(D·0.5, bt), 1) : 1 ; w *= f
                if (!single && f >= 1) flags &= ~4 }   ; 0x14026c923 (인 완료 시 플래그 해제)
if (blendout) { if (min(D,bt) > eps) w *= min((D − T) / min(D·0.5, bt), 1) }
```

램프 길이가 `min(D/2, blendtime)` 인 게 핵심 — 짧은 클립에서 인/아웃이 겹치지 않게 한다.

### 2.4 레이어 캐스케이드

매 프레임 순서(모델 업데이트 `0x1401fdf90`, AVX 쌍둥이 `0x14021c480`):

1. **포즈 SoA 를 본 레스트 TRS 로 시딩** — `0x1401fe2f2`–`0x1401fe657`.
   배열 base `skel+0x230`(+`0x238`), 본 수 `skel+0x228`; 10개 배열에 pos3/quat4/scale3 을 흩어 쓴다.
2. 레이어 목록(`skel+0x3d0`)을 **순서대로** 순회 — `0x1401fed50`.
   `visible`(bit0) 아니면 스킵, `advance(dt · rate)` → `sample(f0, f1, t)` → `effectiveBlend`.
3. 합성 함수 선택 — `0x1401fee15`–`0x1401fee2e`, `0x1401ff32d`:
   * `weight == 1 && !additive` → 덮어쓰기 경로 `0x1401f89a0`
   * `!additive` → 가중 블렌드 `0x1401f9020`
   * `additive` → 가산 `0x1401f9820`
4. 본별 `blendvps` 마스크(`skel`/클립의 per-bone 배열, 로드 `0x1401f8c7b`, 선택 `0x1401f8c9f`) —
   **그 레이어가 건드리지 않는 본은 이전 값을 그대로 둔다.**
5. `world[i] = world[parent] ∘ local[i]` — §2.4a. **3차에 피연산자 순서를 확정했다.**
6. 스킨 팔레트 → `mat4x3 g_Bones[BONECOUNT]`(**uniform id `0x71`**, 등록 `0x140003fcb`).
   `BONECOUNT` 콤보는 본 수(가상함수 `vtbl+0xd8` — `0x1402098b0`/`0x14020a660`/`0x14020abc9`
   에서 호출), `SKINNING` 콤보 = 1(`0x140209883`).
   ⚠️ 팔레트를 **실제로 채우는 지점은 아직 못 찾았다** — `0x1401fdf90` 안에는 4×4 역행렬
   `0x14005f730` 호출이 **0건**이다(그 함수 호출자 33곳 중 스켈레톤 쪽은 `0x140207b50` 하나뿐이고
   그건 레이어 변환 경로다). `skin = world × bindWorld⁻¹` 의 **곱 순서**는 여전히
   자기정합(`t=0` 항등)으로만 지지된다 — [미해결].

**가중치 정규화는 어디에도 없다.** 레이어 가중치는 순서대로 곱해 끌어당길 뿐이고
(합이 1을 넘든 말든), 정점 본 가중치도 셰이더가 그대로 더한다(§3).

**3차 재확인(명령 단위)**: 레이어 루프 몸통을 직접 떴다.
```
0x1401fed50  rdi = *layerIt
0x1401fed54  test byte [rdi+0xd0], 1        ; visible 아니면 스킵 (je 0x1402001ca)
0x1401fed81  xmm0 = dt(xmm13) * [rdi+0xc8]  ; rate 를 dt 에 곱한다 — 위상 적분
0x1401fed89  call 0x1401a9f60               ; Playback::advance(&[rdi+0xf8], dt·rate, …)
0x1401feda8  call 0x140170580               ; Playback::sample → f0, f1, t
0x1401fee0c  call 0x14026c8b0               ; effectiveBlend → xmm8 = w
0x1401fee15  ucomiss xmm8, xmm15            ; xmm15 = **1.0** (0x1401fed21, .rdata 0x140492704)
0x1401fee1d  test byte [rdi+0xd0], 2        ; additive
   → w == 1.0 && !additive : 덮어쓰기  call 0x1401f89a0 @0x1401fef20 / 0x1401fef7b
   → !additive             : 가중 블렌드 call 0x1401f9020 @0x1401ff38e / 0x1401ff3ef
   → additive              : 가산      call 0x1401f9820 @0x1401ff874 / 0x1401ff8e1
```
두 가지가 초판보다 정확해졌다.
* 분기 상수는 **0 이 아니라 1.0** 이다. "유효 가중치가 정확히 1.0이고 가산이 아닐 때만"
  덮어쓰기이고, **가중치 0 인 절대 레이어도 덮어쓰기가 아니라** `mix(…, 0)` = 무변화로 지나간다.
* 블렌드 대상은 **포즈 SoA(`skel+0x230`) 자기 자신**이다(`mov r8,[rax+0x230]` `0x1401fee9b` 이
  그대로 블렌드 인자로 들어간다) — 제자리 캐스케이드지 "레이어별 포즈의 가중 합" 이 아니다.
* `rate` 는 **dt 에 곱해 위상을 적분**한다(`xmm13` = 이 함수의 2번째 인자 = dt, `0x1401fdfca`).
  `time × rate` 순간위상이 아니다 — Waple `integratedCascadeFrame`(C④)의 독립 근거다.
* 호출이 **두 번씩** 나오는 건 스켈레톤이 **두 채널**이기 때문이다(아래).

**포즈 채널이 둘이다.** `0x1401fdf90` 은 같은 모양의 시딩·블렌드를 두 벌 돌린다:

| 채널 | 원소 배열 | 개수 | 포즈 SoA | 시딩 루프 |
|---|---|---|---|---|
| A(본) | `skel+0x38`(스트라이드 `0xf0`) 또는 `skel+0x50` | `skel+0x228` | `skel+0x230` | `0x1401fe2f2`–`0x1401fe657` |
| B | `skel+0x80` 또는 `skel+0x98` | `skel+0x22c` | `skel+0x240` | `0x1401fe670`–`0x1401fe9ea` |

계층 합성(§2.4a)과 `world` 배열(`skel+0x2c8`)은 **A 에만** 있다 — B 는 평면이다. B 의 정체는
미조사([미해결]).

두 채널 모두 로컬 행렬 원본을 **두 군데 중에서** 고르고, 선택자는 **하나를 공유한다**:
`r15b = vector::empty(skel+0x50)` (`call 0x1401fe2d7` → `movzx r15d, al` `0x1401fe2e6`.
`0x1401d76a0` 은 `mov rax,[rcx+8]; cmp [rcx],rax; sete al` 세 줄짜리 leaf 다).
`r15b != 0`(= 오버라이드 배열이 비었다) → 레코드 안의 레스트 행렬 `+0x20`,
`r15b == 0` → 오버라이드 배열 `skel+0x50[i]` / `skel+0x98[i]`
(분기 `0x1401fe2f5` 시딩A, `0x1401fe682` 시딩B, `0x1401fea1e` 합성).

**본 알파는 기본 1.0 이다.** 캐스케이드 직전에 `skel+0x268` 배열 전체를 `0x3f800000`(=1.0)로
채운다(`0x1401febf0`–`0x1401fec10`). 이게 `g_BonesAlpha`(§3)의 소스다.

### 2.4a 계층 합성 — 피연산자 순서 확정 (3차)

루프는 `0x1401fea10`–`0x1401feadf`:

```
rdi = local[i]                         ; bones[i]+0x20  또는  skel+0x50[i]  (0x1401fea1e–0x1401fea3b)
cmp dword [rax+0x60], -1               ; 0x1401fea5d — 부모 인덱스, -1 = 루트
 └ 루트   → world[i] = local[i]         ; 0x1401feaae–0x1401feaba (movups ×4, 64B 그대로)
 └ 그 외  → rbx = skel+0x2c8            ; 0x1401fea63 (world 배열, 원소 64B — sar rax,6 @0x140215e67)
            rax = world[ bones[i].parent ]        ; 0x1401fea76 → 0x1401fea79
            rdx = rax                             ; 0x1401fea7e   ← A 피연산자
            rcx = &tmp                            ; 0x1401fea81
            r8  = rdi                             ; 0x1401fea88   ← B 피연산자
            call 0x14005ecb0                      ; 0x1401fea8b
            world[i] = tmp                        ; 0x1401feace–0x1401feadf (movups ×4)
```

`0x14005ecb0` 의 산술을 직접 떴다(`0x14005ecba`–`0x14005ee4b`). **A(rdx)는 4개씩 통째로**
읽고(`movsd [rdx+8k]`), **B(r8)는 성분을 하나씩 읽어 `shufps ..,0` 으로 브로드캐스트**한다:

```
movss  xmm5, [r8]        0x14005ecd3      ; B[0]
shufps xmm5, xmm5, 0     0x14005edd6
mulps  xmm3, xmm5        0x14005edda      ; xmm3 = A[0..1] (movsd [rdx] 0x14005ecca)
addps  xmm3, xmm0        0x14005edfc      ; += A[4..5]·B[1]
addps  xmm3, xmm1        0x14005ee11      ; += A[8..9]·B[2]
addps  xmm3, xmm2        0x14005ee29      ; += A[12..13]·B[3]
movsd  [rcx], xmm3       0x14005ee3d
```

평탄 인덱스로 **`out[4j+i] = Σₖ A[4k+i]·B[4j+k]`** 다(다음 저장 `[rcx+8]` `0x14005ee4b`,
`[rcx+0x10]` `0x14005eec0`, … 까지 같은 형태로 확인).

**여기서 함정 14 가 무력화된다.** 같은 바이트를 어떻게 읽든 결론이 같기 때문이다:

| 읽기 | 저장 해석 | 이 산술의 뜻 | 벡터 규약 | 먼저 적용되는 쪽 |
|---|---|---|---|---|
| 열 우선 `M[r][c]=m[4c+r]` | — | `out = A · B` | 열벡터 `p' = M p` | **B** |
| 행 우선 `M[r][c]=m[4r+c]` | 위의 전치 | `out = B · A` | 행벡터 `p' = p M` | **B** |

`r8` 이 자기 로컬이므로 **로컬 → 부모 순서**, 즉 열벡터 규약으로 쓰면
`world[i] = world[parent] * local[i]` 다. Waple 이 이미 쓰던 식이 맞았고, 이제 추정이 아니다.

**스케일은 상속된다.** 합성이 4×4 아핀 전체 곱이고 결과를 `movups` 64B 로 통째로 옮긴다 —
스케일 분리·정규직교화 단계가 **없다**. 부모의 비균등 스케일은 자식의 회전 기저까지 늘려
전단(shear)을 만든다. (`PuppetPoseWEParityTests.testNonUniformParentScaleIsInheritedAndShearsChild`)

**부모 인덱스가 자신보다 뒤면** WE 는 아직 안 쓴 `world[parent]` 슬롯을 읽는다(전 프레임 잔값).
Waple 은 `p < i` 게이트로 루트 취급한다 — 순환·역순 부모에서 무한재귀와 미정의값을 막는
의도적 발산이다.

**수치 검증**(코퍼스 도달 0건이라 합성 포즈로 대신): 무작위 6본 체인 **400건**(본 2 400개)에서
위 산술을 그대로 옮긴 기준 구현과 Waple `bindWorlds` 를 대조 — 불일치 **0/2 400**.
피연산자를 뒤바꾼 가설은 불일치 **2 000/2 400**(나머지 400은 루트 본이라 두 가설이 같다).

⚠️ 한 가지 남는다: 이 루프는 레이어 캐스케이드(`0x1401fed50`)보다 **앞**에서 돈다. 즉 여기서
합성되는 것은 (오버라이드 배열이 비었을 때) **레스트 월드** = `bindWorld` 다. 애니메이션이
적용된 뒤의 월드를 어디서 합성하는지는 못 찾았다([미해결]) — 다만 합성 **규칙**은 이 하나뿐이다.

### 2.5 회전 보간 = nlerp (slerp 아님)

키 보간 `0x1401f8c67`–`0x1401f8e1a`, 레이어 블렌드 `0x1401f9483`–`0x1401f9513` ·
`0x1401f9589`–`0x1401f9613`. 셋 다 같은 식이다:

```
dot = q0.x·q1.x + q0.y·q1.y + q0.z·q1.z + q0.w·q1.w   ; 0x1401f8d5e–0x1401f8d6b
s   = signbit(dot) XOR t                              ; andps [0x140483730](-0.0) → xorps
                                                      ; 0x1401f8d6f / 0x1401f8d77
q   = (1 − t)·q0 + s·q1                               ; 0x1401f8d7b–0x1401f8dae
n   = rsqrtps(|q|²) ; q *= 0.5·n·(3 − |q|²·n²)        ; 0x1401f8df1–0x1401f8e0b
                                                      ; 상수 0.5 @0x140483740, 3.0 @0x1404837a0
```

즉 **최단호 보정은 `q1` 을 뒤집는 대신 가중치 `t` 의 부호를 뒤집는 분기 없는 트릭**이고
(수학적으로 동일), 마지막에 뉴턴 1스텝 rsqrt 로 재정규화한다. 2차 재확인: `0x1401f8cef`–
`0x1401f8dae` 가 슬롯 3/4/5/6 여덟 개(A·B 각 4개)를 `movups` 로 읽어 4성분 내적을 만들고
(`addps` `0x1401f8d5e`/`0x1401f8d6b`), `andps [0x140483730]` `0x1401f8d6f` → `xorps` `0x1401f8d77`
로 부호를 옮긴 뒤 네 성분에 **대칭으로** 같은 식을 적용한다 — 회전 슬롯이 3..6 이라는 §2.1 의
전제를 여기서도 확인할 수 있다. 본별 마스크는 `movups xmm13,[r13+rax*4]` `0x1401f8c7b` →
`blendvps` `0x1401f8c9f` 로, 초판이 적은 VA 그대로다. 위치·스케일은 성분 lerp.
스칼라 채널(본 알파 등)은 `lerp` 헬퍼 `0x140178e00` 두 번(키 보간 → 레이어 가중).

가산 레이어 `0x1401f9820`–`0x1401fa270`: 위치는 `subps` 델타(`0x1401f9c39`/`0x1401f9c6a`),
회전은 `xorps` 로 켤레(`0x1401f9e48`/`0x1401f9e60`/`0x1401f9e79`) 후 쿼터니언 곱 + 같은 nlerp
(`0x1401f9f3b`). 기준 포즈가 클립 프레임0인지 본 레스트인지는 미확정 — Waple 은 종전 규약
(클립 프레임0)을 유지한다.

### 2.6 진짜 slerp 는 어디 있나 (반증)

`0x140216070`–`0x140216270` 에 정식 slerp 가 있다:

```
dot = q0·q1
if (dot < 0) { q1 = −q1 ; dot = −dot }                 ; 0x1402160df–0x1402160fc (xorps −0.0)
if (dot > 0.99999988f)  out = (1−t)·q0 + t·q1          ; 상수 VA 0x140492700 = 0x3F7FFFFE
                                                        ; 비교 0x1402160ff, lerp 0x140216116–0x14021616c
                                                        ; ← **정규화 없음**
else Ω = acosf(dot)                                     ; 0x14021618b (acosf 0x14041c220)
     out = (sinf((1−t)Ω)·q0 + sinf(tΩ)·q1) / sinf(Ω)   ; 0x140216193–0x14021621f (sinf 0x14041a9c0)
```

호출자는 **`0x1401fdf90` / `0x14021c480` 두 곳뿐**이고, 그 호출 지점 주변은 `π/180`
(`0x140492628`) · `57.29578`(`0x1404928d0`) · `1/60`(고정 물리 스텝) 상수가 깔린 **본 물리 /
IK 제약 솔버**다(§1.2 의 `lamin`/`lamax`/`ikr*` 키가 여기로 들어간다). 스켈레톤 애니메이션
샘플링/블렌딩 경로에는 slerp 호출이 **0건**이다.

**단서였던 `0.9995f` / `0.0001f` 는 이 빌드의 slerp 상수가 아니다.**
- `0.9995f`는 **`0x3F7FDF3B`** 다(초판이 적은 `0x3F7FBE77` 은 `0.999f` — 별개 상수이고
  `.rdata 0x1404926fc` 에 **실재**한다. 참조자는 `0x1401a9d24`
  (`movss xmm4, [rip+0x2e89d0]`, 함수 `0x1401a9bc0`) 한 곳뿐이고 slerp 와 무관하다).
  `0x3F7FDF3B` 는 `.rdata` 어디에도 상수로 없다. 이미지 전체에서 그 4바이트 패턴이
  나오는 곳은 `.text` 에 한 군데뿐이고, 그 4바이트는 **명령이 아니다** —
  `0x1402cd75f  41 3b df  cmp ebx, r15d` 의 끝 2바이트(그 명령 시작 +1 부터)와
  `0x1402cd762  7f 3f  jg 0x1402cd7a3` 의 2바이트가 잇닿은 것이다. 그러니 그 패턴을 품는
  **명령의 시작은 `0x1402cd75f`** 이고, 초판·2차가 이 자리를 `cmp`/`jae` 라고 적은 것도
  틀렸다(뒤 명령은 `jae` 가 아니라 `jg`). 이미지 `.text` 전 구간 disp32 스캔에서 그 4바이트를
  가리키는 rip-상대 명령은 **0건**이다.
- `0.0001f`(`0x38D1B717`)는 `.rdata 0x1404925fc` 에 실재하고 참조자가 12곳 있다. 그중 하나
  (`0x14021c620`)는 본 물리/IK 솔버(`0x14021c480`)가 루프 진입 전에 `FLT_EPSILON`
  (`0x1404925e0`)과 나란히 레지스터에 올려두는 **솔버 수렴 임계**다. slerp(`0x140216070`)는
  이 상수를 참조하지 않는다 — 나머지 11곳도 전부 스켈레톤 밖(`0x140110630`, `0x1401c2a40`,
  `0x1401d15a0`, `0x1402378a0`, `0x14026eb60` …)이다.
slerp 의 실제 임계는 `0x3F7FFFFE = 1 − FLT_EPSILON = 0.99999988f` 하나뿐이다
(`.rdata 0x140492700`, rip-상대 **disp32 자리** 8곳 중 slerp 것은 `0x140216102` = 명령
`0x1402160ff  comiss xmm1, dword ptr [rip + 0x27c5fa]`).

2차 재확인: `0x140216070` 로의 `call` 은 이미지 전체에 **28곳**이고 그 전부가
`0x1401fdf90`(14곳) · `0x14021c480`(14곳) **두 함수 안**이다. `0x1404925fc`(`0.0001f`)의
rip-상대 참조는 정확히 **12곳**이고 그중 스켈레톤 쪽은 하나뿐이다. **[2026-08-21 정정]** 종전에
적힌 열두 주소는 전부 `disp32` **필드가 박힌 자리**였다(이미지 바이트 스캔의 산출물). 명령의
시작은 그보다 3~5바이트 앞이다 — 아래는 `.pdata` 함수 시작에서 선형으로 다시 뜬 값이다:

| 명령 시작 | 명령 | 함수 |
|---|---|---|
| `0x140110cb9` | `movss xmm8, [rip+0x38193a]` | `0x140110630` |
| `0x140111c72` | `movss xmm6, [rip+0x380982]` | `0x140110630` |
| `0x140112681` | `movss xmm8, [rip+0x37ff72]` | `0x140110630` |
| `0x1401c2d80` | `movss xmm1, [rip+0x2cf874]` | `0x1401c2a40` |
| `0x1401c70a1` | `movss xmm14, [rip+0x2cb552]` | `0x1401c5490` |
| `0x1401d176f` | `movss xmm0, [rip+0x2c0e85]` | `0x1401d15a0` |
| `0x1401d228e` | `movss xmm0, [rip+0x2c0366]` | `0x1401d15a0` |
| **`0x14021c620`** | `movss xmm11, [rip+0x275fd3]` | **`0x14021c480`**(본 물리/IK) |
| `0x1402268bd` | `movss xmm0, [rip+0x26bd37]` | `0x140225900` |
| `0x140237fb3` | `movss xmm1, [rip+0x25a641]` | `0x1402378a0` |
| `0x140238a2f` | `movss xmm1, [rip+0x259bc5]` | `0x1402378a0` |
| `0x14026f1b4` | `comiss xmm2, [rip+0x223441]` | `0x14026eb60` |

열두 자리가 **전부 같은 상수 하나**(`0x1404925fc` = `0x38D1B717` = `1e-4f`)를 읽는다 — 여덟 함수가
같은 수렴/근접 임계를 공유한다는 뜻이고, 그중 스켈레톤 경로는 `0x14021c480` 하나다.

---

## 3. 정점 스키닝 (본 4개, 정규화 없음)

정점 포맷 비트: `0x00800000` = `boneIndices` 4×u32(16B), `0x01000000` = `weights` 4×f32(16B)
→ **본 가중치는 정확히 4개**.

동봉 셰이더가 팔레트를 쓰는 식(`assets/shaders/base/model_vertex_v1.h:147-150`,
`assets/shaders/genericimage3.vert:139-142`):

```glsl
uniform mat4x3 g_Bones[BONECOUNT];
position.xyz = mul(vec4(position, 1.0),
      g_Bones[blendIndices.x] * blendWeights.x + g_Bones[blendIndices.y] * blendWeights.y
    + g_Bones[blendIndices.z] * blendWeights.z + g_Bones[blendIndices.w] * blendWeights.w);
```

**정규화가 없다.** 합이 1이 아닌 데이터는 그대로 축소/확대되어 렌더된다(리소스 컴파일러가
저작 시점에 정규화해 두는 전제). 법선/탄젠트도 같은 가중합의 3x3 부분을 쓴다
(`CAST3X3(g_Bones[…])` — `genericimage3.vert:170-173`, `181-184`).
`SKINNING_ALPHA` 콤보가 켜지면 `g_BonesAlpha[BONECOUNT]`(**uniform id `0x72`**)의 가중합을
`saturate` 해 정점 알파에 곱한다.

**유니폼 id 정정(3차).** 초판·2차는 `g_Bones` = `0x72`, `g_BonesAlpha` = `0x73` 이라고 적었는데
**한 칸 밀려 있었다**. 등록부 `0x140003f48`–`0x140004033` 은 항목마다
`lea r8, slot` → `mov dword slot, ID` → `lea rdx, NAME` → `lea rcx, dst` → `call 0x14016f7a0`
로 완전히 규칙적이고, 짝은 **같은 슬롯을 `r8` 으로 받는 호출의 이름**이다:

| 슬롯 | id | 이름 | id 저장 VA |
|---|---|---|---|
| `[rbp-0x74]` | `0x6f` | `g_RenderVar3` | `0x140003f88` |
| `[rbp-0x70]` | `0x70` | `g_RenderVar4` | `0x140003fa6` |
| `[rbp-0x6c]` | **`0x71`** | **`g_Bones`** | `0x140003fc4`(이름 `lea` `0x140003fcb`) |
| `[rbp-0x68]` | **`0x72`** | **`g_BonesAlpha`** | `0x140003fe2` |
| `[rbp-0x64]` | `0x73` | `g_BlendMap` | `0x140004000` |

초판은 "`0x140003fcb` 에서 `g_Bones` 를 등록" 이라고 **이름 `lea` 의 주소**를 적고 그 **앞줄**의
id 를 짝지었다 — 그런데 그 앞줄(`mov [rbp-0x6c], 0x71`)이 바로 `g_Bones` 것이다.
함정 16 이 경고한 한 칸 밀림과 같은 부류이니 재차 주의.

### 3.1 선형 블렌드 스키닝이지 듀얼 쿼터니언이 아니다

**범위**: 설치본 `assets/shaders/` **137개**(= `.vert` 59 + `.frag` 59 + `.h` 14 + `.geom` 4 +
`declarations.json` 1, 하위 `base/`·`HLSL/`·`editor/` 포함) + 저장소 `WEAssets/shaders/` 137개
(바이트 동일 사본).

* `dualquat` / `dual_quat` / `DQS`(대소문자 무시) 식별자 — **셰이더 137개 전수 0건**.
  (같은 정규식을 `WEAssets/` 트리 전체에 걸면 18건이 나오는데 **전부 `.tex`/`.tga` 바이너리 안의
  우연한 바이트열**이다 — 텍스트 셰이더 파일로 한정하면 0건. 이런 오탐을 그대로 실으면 결론이
  뒤집히므로 명시해 둔다.)
* 바이너리 문자열 전수 스캔에서 `SKIN` 을 포함하는 콤보는 **`SKINNING` 과 `SKINNING_ALPHA` 둘뿐**,
  `[Dd]ual[Qq]uat` 계열은 **0건**.
* `g_Bones[` 를 쓰는 **9개** 전부가 가중 **행렬합**이다. 철자가 둘인데 아핀이라 대수적으로 동치다:

```glsl
// (a) 행렬을 먼저 섞고 한 번 곱한다 — 8개 파일
//     base/model_vertex_v1.h:147-150, genericimage2.vert:86-89, genericimage3.vert:139-142,
//     genericimage4.vert, generic3.vert:120-123, generic4.vert, clippingmaskimage4.vert:97-100,
//     shadowcaster.vert:98-101
mul(vec4(p,1), g_Bones[i.x]*w.x + g_Bones[i.y]*w.y + g_Bones[i.z]*w.z + g_Bones[i.w]*w.w)

// (b) 각각 곱하고 나중에 섞는다 — passthroughblend.vert:19-22
mul(vec4(p,1), g_Bones[i[0]])*w[0] + … + mul(vec4(p,1), g_Bones[i[3]])*w[3]
```

`Σ wᵏ·(Mᵏp) ≡ (Σ wᵏ·Mᵏ)p` 이므로 둘은 같은 LBS 다(부동소수 오차만 다르다.
`PuppetPoseWEParityTests.testTwoShaderSpellingsOfLinearBlendSkinningAgree` 가 200건으로 대조 —
불일치 0). 듀얼 쿼터니언이라면 같은 입력에서 결과가 **다르다**: 같은 축의 0°/180° 두 본을
0.5/0.5 로 섞을 때 LBS 는 회전 기저가 상쇄돼 정점이 축으로 붕괴하고(사탕 포장지) DQ 는 90°
회전을 낸다. Waple 은 붕괴하는 쪽을 고정점으로 박았다
(`testSkinningCollapsesLikeLinearBlendNotDualQuaternion`).

**가중치 0 슬롯은 건너뛰지 않는다.** 셰이더는 네 슬롯을 무조건 읽어 곱하므로 가중치가 0 이어도
`g_Bones[idx]` 인덱싱 자체는 일어난다(범위 밖 인덱스는 GPU 미정의 — Waple 은 `count-1` 로
clamp 한다). **음수 가중치도 그대로 빼진다.** Waple 은 정확히 0 인 슬롯만 건너뛴다 —
값은 동일하고 퇴화 행렬의 `0×NaN` 전파만 막는다(종전 `w > 0` 게이트는 음수 슬롯을 통째로
버려 WE 와 값이 달랐다 — 3차에 고쳤다).

### 3.2 2D 퍼펫 워프는 **UV 를 건드리지 않는다**

퍼펫 스키닝이 손대는 것은 `a_Position` 뿐이고, 텍스처 좌표는 그대로 통과한다:

```glsl
// genericimage2.vert:101-105 / genericimage3.vert:152-156 / clippingmaskimage4.vert:110-114
#if SPRITESHEET
    v_TexCoord.xy = g_Texture0Translation + a_TexCoord.x*g_Texture0Rotation.xy
                                          + a_TexCoord.y*g_Texture0Rotation.zw;
#else
    v_TexCoord.xy = a_TexCoord;      // ← 본과 무관
#endif
```

UV 를 바꾸는 유일한 콤보는 `SPRITESHEET`(시트 프레임 오프셋)이고 본/스킨과 아무 관계가 없다.
즉 **2D 퍼펫은 "UV 고정 메시 워프"** 다 — 텍스처 좌표 워프가 아니다. 텍스처는 정지해 있고
삼각형 그물이 움직인다.

본이 UV·마스크에 간접적으로 개입하는 경로는 **하나뿐**이고, 그것도 워프가 아니라 **모프 가중치
게이팅**이다 — `clippingmaskimage4.vert` 의 `MORPHING_MODIFIERS`(§1.2 의 `puppetblendshape`):

```glsl
uniform mat4x3 g_MorphBoneTransform[11];
uniform vec3   g_MorphBoneRules[11];
...
vec3 preMorphPos            = mul(vec4(localPos,1.0), Σ g_Bones[i.k]*w.k);   // 먼저 스킨
vec3 modifierInverseDelta   = mul(vec4(preMorphPos,1.0), g_MorphBoneTransform[t]);
float bonePointRule = smoothstep(rules.y, rules.z, length(modifierInverseDelta.xy));
float boneAxisRule  = smoothstep(rules.y, rules.z, modifierInverseDelta.x);
morphAmount = mix(bonePointRule, boneAxisRule, rules.x);                     // 모프 가중치만 조절
```

즉 "본 기준 거리/축 거리로 블렌드셰이프 세기를 감쇠" 하는 것이고 UV 는 여전히 안 건드린다.
모프 타깃 자체는 `g_Texture5` 텍스처에서 정점 델타로 읽는다(`MORPHING`).
모프 경로 전체는 이 문서 범위 밖이다([미해결]).

**범위 라벨**(2차 실측): 설치본 `assets/shaders/` **137개** 중 `g_Bones[` 를 쓰는 것은 **9개**
(`base/model_vertex_v1.h`, `clippingmaskimage4.vert`, `generic3.vert`, `generic4.vert`,
`genericimage2.vert`, `genericimage3.vert`, `genericimage4.vert`, `passthroughblend.vert`,
`shadowcaster.vert`). **9개 전부** 위와 같은 원시 가중합이고, `a_BlendWeights` 를 정규화하거나
합으로 나누는 코드는 137개 어디에도 없다. `SKINNING_ALPHA` 는 8개 파일(`genericimage2/3/4` ·
`clippingmaskimage4` 의 vert/frag 쌍)에서만 나온다.

Waple 의 `PuppetPose.skinnedPositions` / `Model3DPose.cpuSkinnedPacked` 는 `wsum` 으로
나눈다 — 이는 Waple 자체 셰이더(`Mesh3DShaders.mv_skin`)와의 정합을 위한 것이지 WE 파리티가
아니다. **의도적으로 유지**하고 반증 주석만 남겼다(실물 자산은 정규화돼 있어 차이가 없다).

---

## 4. Waple 반영 내역

`Sources/WapleCore/PuppetPose.swift`
- `rotationQuaternion(_:)` — 파일 **(X,Y,Z)** 순서 + 반각 식(§2.1) 단일 소스.
  `localMatrix(position:angles:scale:)` 가 이걸 경유한다.
  **[2차]** 초판이 이 함수를 (Z,Y,X)로 바꿔 X·Z 를 뒤바꿔 놓았던 것을 되돌렸다. 슬롯 근거
  (`0x1401fe2f2` 시딩 + `0x140215730` 첫 칸 = 스칼라부)를 함수 주석에 박아 두었다.
- `TRS` / `trsMatrix` / `decomposeTRS` / `quaternionMatrix` / `quatMultiply` / `quatConjugate`.
- `nlerpShortest` — §2.5 그대로. `slerpShortest` — §2.6 기준선(스켈레톤 경로 미사용).
- `sampledTRS` / `sampledLocal` — 회전을 nlerp 로 보간. 프레임 클램프가 트랙 길이 기준
  (§2.2) — 이 클램프를 빼면 손상 데이터에서 **배열 범위 밖 트랩**이다(돌연변이로 실증).
- `frame(time:fps:length:mode:)` — `lowercased()` 매칭, `"clamp"` 제거(loop 로 떨어짐).
  **[4차]** 음수 시간을 모드별로 되돌린다 — loop 는 `+L`(0x1401aa064), mirror 는 `abs`(0x1401aa140).
  single 은 엔진에 음수 분기가 없어 **의도적으로 그대로** 뒀다(소비처 클램프가 같은 값을 낸다).
- `layerWeight(blend:blendIn:blendOut:blendTime:duration:time:)` — §2.3.
- `worldMatrices` — 바인드 TRS 시딩 → 레이어 순차 캐스케이드(TRS 공간, 회전 nlerp),
  트랙 없는 본은 스킵. 바인드가 TRS 로 분해되지 않으면(스큐/거울) 종전 행렬 lerp 로 폴백.
  부모 합성은 `p < i` 게이트라 **순환 부모·범위 밖 부모는 루트로 떨어진다**(무한재귀 없음).
- `addTRS` — 가산 레이어(위치 델타 + 쿼터니언 델타곱 + nlerp).
- **[3차]** `bindWorlds` 주석에 §2.4a 전문(피연산자 순서 증명 + 스케일 상속)을 박았다.
  코드는 그대로다 — 종전 식이 맞았고 추정이 확정으로 바뀐 것이다.
- **[3차]** `skinnedPositions` 의 슬롯 게이트를 `w > 0` → **`w != 0`** 으로 고쳤다(§3.1).
  음수 가중치를 버리던 것이 WE 와 값이 갈리는 지점이었다. `skinMatrices` 주석에 역바인드가
  파일에 없다는 사실(§1.3)과 팔레트 생성 지점 미해결을 기재.

`Sources/WapleCore/Model3DPose.swift`
- `sampledTRS` 신설, `sampledLocal` 이 그것을 경유 — 3D 경로도 회전 nlerp.
  `PuppetPose.rotationQuaternion` 을 부르므로 §2.1 정정이 3D 경로에도 그대로 적용된다.
- **[3차]** `buildBindWorlds` / `cpuSkinnedPacked` 주석에 §2.4a·§3.1 을 참조로 연결.

`Sources/WapleCore/PuppetModel.swift` — `Key.angles` / `Animation.mode` 주석에 근거 VA 기재.
**[4차]** MDLA0001 프레이밍을 §6.1 로 교체(클립 선두 `u64` id · 헤더 4필드 · 본 레코드
`trackFlags|trackBytes|트랙`) 하고, MDLS0001 본 레코드 꼬리 1바이트를 **cstring**(본 제약 config)
으로 읽게 고쳤다. 네이티브 퍼펫의 `Animation.id` 를 그 `u64` 로 채운다(종전 항상 nil).
**[3차]** `Bone.bind` 주석이 "바인드(모델→본) 행렬" 이라고 **반대로** 적고 있던 것을
"부모상대 로컬 레스트" 로 고치고(§1.3) 본 레코드 오프셋·128 상한을 기재했다.

`Sources/WapleCore/Model3D.swift` **[2차]** — `Animation.Key` 에 36B/`frameCount+1` 불변식과
WE 의 `int 0x29` 즉사 지점(`0x140263c8c`/`0x140263c95`)을, `Animation.mode` 에 인식 문자열이
둘뿐이라는 사실을 기재.

테스트
- `Tests/WapleCoreTests/PuppetPoseWEParityTests.swift` — **22건**. **[2차]** 축 순서 테스트를
  `(X,Y,Z)` 로 교정하고 `testBakeMatchesEngineSlotExpressions`(엔진 굽기 식 + 슬롯 순서 고정) ·
  `testPublicApiEulerConventionMatchesFileConvention`(`setLocalBoneAngles` 행렬 원소 대조) 신설.
  **[3차 신설 7건]** `testEngineMatMulFlatFormulaEqualsColumnVectorProduct`(0x14005ecb0 산술 전사) ·
  `testHierarchyComposesParentThenLocalNumerically`(400건 대조, 뒤바꾼 가설 동시 계수) ·
  `testNonUniformParentScaleIsInheritedAndShearsChild` ·
  `testTwoShaderSpellingsOfLinearBlendSkinningAgree`(200건) ·
  `testSkinningCollapsesLikeLinearBlendNotDualQuaternion`(LBS 판별식) ·
  `testNegativeWeightSlotContributesAndZeroSlotDoesNot` · `testVertexHasExactlyFourBoneSlots`.
- `Tests/WapleCoreTests/PuppetPoseTests.swift` — `key(_:_:rz:)` 헬퍼가 세 번째 슬롯(+0x14)에
  넣도록 교정.
- `Tests/WapleCoreTests/PuppetHostileInputTests.swift` **[2차 신설, 13건]** — 신뢰 경계.
  거짓 본 수(40억/9만) · 순환 부모 · 큰 u32 부모 · 거짓 프레임 수 · `%36` 아닌 트랙 크기 ·
  EOF 넘는 트랙 크기 · 4GB 꼬리 블롭 · 거짓 애니 수 · 범위 밖 정점 본 인덱스 ·
  범위 밖 삼각형 인덱스 · `fps≤0`/`length≤0` · `Playback::sample` 인덱스 규약.

---

## 5. 미확정 / 후속

- ~~`0x14005ecb0`(4x4 곱)의 피연산자 순서~~ — **3차에 확정(§2.4a)**. 함정 14 는 이 자리에서
  무력하다: 곱셈 산술 자체를 뜨면 두 읽기가 같은 답으로 수렴한다.
- **`g_Bones` 팔레트를 실제로 채우는 지점** — 못 찾았다(§2.4 6번). `skin = world × bindWorld⁻¹`
  의 **곱 순서**는 여전히 자기정합(`t=0` 항등)으로만 지지된다. 4×4 역행렬 `0x14005f730` 의
  호출자 33곳을 훑었으나 스켈레톤 쪽은 `0x140207b50`(레이어 변환) 하나뿐이었다.
- **애니메이션 적용 뒤의 월드 합성 지점** — `0x1401fea10` 루프는 레이어 캐스케이드보다 **앞**이라
  레스트 월드(=`bindWorld`)를 만든다. 블렌드된 포즈로 다시 합성하는 곳은 미탐(§2.4a).
- **두 번째 포즈 채널**(`skel+0x80`/`+0x98`, 개수 `skel+0x22c`, SoA `skel+0x240`)의 정체 — §2.4.
  계층 합성이 없는 평면 채널이다.
- MDLS 버전 ≥ 2 의 128B 스트라이드 항목 배열(§1.3) — **개수는 MDLA v≥2 트랙 배열의 길이로 쓰인다**(§6.2, `0x140263ce7`). 항목 자체의 내용은 여전히 미조사.
- ~~`MDLA0003..0006` 의 차이~~ — **4차에 확정(§6.2)**. 남은 것은 §6.3 의 다섯 항목이다.
- 정확히 `T = D` 인 순간의 샘플 인덱스가 WE(`i=frameCount−1`)와 Waple(`i=frameCount`)에서
  갈리는 문제 — §2.2. 실효 차이는 부동소수 1 ulp 수준이라 정본화하지 않았다.
- 가산 레이어의 **기준 포즈**(클립 프레임0 vs 본 레스트) — 구조는 확인, 인자 출처 미추적.
- `wraploop`(재생 플래그 bit2)이 샘플링에 어떻게 쓰이는지.
- 본 물리 / IK 솔버(`0x1401fdf90`) 전체 — `lamin`/`lamax`/`ikd`/`ikrd` 등 §1.2 키의 수식.
- `MDLE0002` · `MDMP0001`(모프 타깃 추정) 섹션.
- `MORPHING` / `MORPHING_MODIFIERS` 블렌드셰이프 경로 전체(§3.2) — 게이팅 식만 읽었다.
- 동봉 코퍼스에 스킨 모델이 0개라 **렌더 실측 게이트가 없다**(도달 건수 0/3 655 JSON, 0/30 mdl).
  워크샵 퍼펫 `.mdl`(`models/*_puppet.mdl`)을 확보하면 §2.1 축 순서를 **가장 먼저**
  재확인할 것 — 이 문서가 같은 자리에서 한 번 틀렸다. 그다음이 §2.4a 합성 순서다.

---

## 6. MDLA 섹션 레코드 전문 (2026-08-21, 4차)

> **표본 라벨.** 이 절에는 **실물 대조가 하나도 없다.** 설치본 `.mdl` **28개 전수**를 파일 전체
> 바이트로 다시 훑었고 `MDLS`/`MDLA`/`MDAT`/`MDMP`/`MDLE` 매직은 **0건**이다(§1.1 과 같은 결과,
> 4차에 재확인). 워크샵 코퍼스(`spec/formats/mdl-deep.json` 의 451파일)는 이 컨테이너에 없다.
> 그러므로 아래는 전부 **`wallpaper64.exe` 2.8.42 의 MDL 디코더를 `.pdata` 조각 시작에서 선형으로
> 뜬 결과**이고, 확정 등급은 "엔진이 이렇게 읽는다" 까지다. "실물이 이렇게 생겼다" 는 아니다.
> 디코더 범위는 `0x140261880`–`0x140265a43`(`.pdata` 조각 6개 병합).

### 6.1 섹션 헤더와 클립 레코드

섹션 디스패치는 `strncmp(magic, "MDLA0006", **4**)`(`0x14026397d`)이고 버전은 `atoi(magic+4)`
(`0x14026399a`, `0x1402639a4` 에 저장)라 **`MDLA0001`(2D 퍼펫)과 `MDLA0006`이 같은 코드 경로**다.

```
"MDLA000N" | u8 0                                   ; 매직은 cstring 으로 읽힌다(9B)
u32 nextOff                                         ; 0x1402639a8 → 0x140261770
                                                    ;   u32 를 읽어 reader[+0x18] = base + min(v, size)
                                                    ;   로 **한계**를 세운다(스킵 포인터)
u32 animCount                                       ; 0x1402639b2 → 0x1402639b7
클립 × animCount:
    u64 id                                          ; 0x1402639de → 0x1402616b0(8B 리더) → 0x1402639e8
                                                    ;   클립 오브젝트 +0x00
    cstring name                                    ; 0x1402639f8 → 클립 +0x08 (std::string)
    cstring mode                                    ; 0x140263a11 → 클립 +0x28 (std::string)
    f32  fps                                        ; 0x140263a1b → 0x140263a25 (+0xb8)
    u32  frameCount                                 ; 0x140263a2d → 0x140263a37 (+0xbc)
    u32  flags                                      ; 0x140263a3d → 0x140263a47 (+0xc0)
    u32  boneCount                                  ; 0x140263a4d
    본 × boneCount:                                 ; 루프 머리 0x140263a90
        u32 trackFlags                              ; 0x140263aa7 (범위 밖이면 0)
        u32 trackBytes                              ; 0x140263acb
        trackBytes 바이트                            ; 0x140263afe 가 커서를 그만큼 민다
```

클립 생성자는 `0x140265a90` 이고 `+0x08`·`+0x28` 을 std::string 두 개로 초기화한다 — 이름·모드가
그 두 자리에 착지하는 것이 위 순서의 독립 근거다.

**트랙 크기 불변식(둘 다 __fastfail).** `0x140263c61` `movabs rax, 0xE38E38E38E38E38F` /
`0x140263c74` `shr rdx, 5` 로 36 나눗셈을 하고, 몫 ≠ `frameCount + 1` 이면 `0x140263c85` `cmp` →
`0x140263c8c` `int 0x29`, 나머지 ≠ 0 이면 `0x140263c8e` `test` → `0x140263c95` `int 0x29`.

**`trackFlags` 는 크기가 아니라 플래그다.** 비트0 이 서 있으면 `0x140263c97` `test r15b, 1` →
`0x140263c9d` `or dword [rbp+0xc0], 0x80000000` 로 **클립 flags 에 최상위 비트를 세우는 데만**
쓰이고 키 해석을 바꾸지 않는다. 로더는 그 앞에서 본 레코드도 본다 — `0x140263b1d`
`test byte [rax+rcx+0x64], 2`(본 flags 비트1)와 `0x140263b24` `cmp dword [rax+rcx+0xd4], -1` 이
둘 다 참이면 `0x140263b3f` `or r15d, 1` 로 이 비트를 **강제로 켠다**(본 스트라이드 `0xf0`,
`0x140263b0e` `imul rcx, rax, 0xf0`).

> **이것이 Waple 이 틀렸던 자리다.** 종전 `PuppetModel.swift`·`Model3D.swift` 는 클립 헤더를
> `… | u32 frameCount | u32 0 | u32 boneCount | u32 0` 로, 본 레코드를
> `u32 트랙크기 | 트랙 | u32 블롭2크기 | 블롭2` 로 적고 있었다. 실은 헤더의 마지막 `u32 0` 이
> **본 0 의 trackFlags** 였고, 본마다 읽던 "블롭2크기" 가 **다음 본의 trackFlags** 였다. 그 값이
> 실물에서 0 이라 위치가 우연히 맞았을 뿐이고, ① `trackFlags ≠ 0` 이면 그만큼 커서를 더 밀며
> ② 클립 선두 `u64 id` 를 건너뛰지 않으므로 **클립이 둘 이상이면 두 번째부터 전부 유실**된다
> (한 클립당 정확히 4바이트 + Σ trackFlags 만큼 어긋난다). 회귀 핀은
> `Tests/WapleCoreTests/PuppetMDLAFramingTests.swift`.

### 6.2 버전 게이트 — `MDLA0003`..`MDLA0006` 이 무엇이 다른가

본 트랙 배열 **뒤**에 붙는 블록들이고, 전부 **클립마다** 돈다. 버전은 `[rsp+0x5c]` 에 있다.

| 게이트 | VA | 붙는 것 | 최소 바이트 |
|---|---|---|---|
| 항상 | `0x140263e7b` | 스칼라 f32 트랙 배열 — 개수는 파일이 아니라 **스켈레톤 필드** `[r15+0x28]` (`0x140263e1f`). 원소마다 `u32` → `u32 size` → size바이트 | 0 (개수 0 이면) |
| `v ≥ 2` | `0x140263cc5` | **2차 채널 트랙 배열** — 개수 = MDLS v≥2 의 128B 스트라이드 항목 수(`0x140263ce7` `sar rdi, 7` = /128). 원소마다 `u32 trackFlags` → `u32 trackBytes` → 트랙, 36/`frameCount+1` 불변식 동일 | 0 |
| `v ≥ 3` | `0x14026466a` | ① `u32 count`(`0x14026468d`) + count × (`u32` 건너뜀 `0x140264756` → `u32 size` `0x140264773` → size바이트) ② `u8 gate`(`0x140264838`), 0 이 아니면 **본 수**만큼(`0x14026486d` `sar rdi, 4`) 같은 레코드 | 5 |
| `v ≥ 4` | `0x1402649f9` | `u8 gate`(`0x140264a1e`), 0 이 아니면 **32바이트 레코드** 배열(`0x140264a48` `sar rdx, 5`). 레코드마다 `u32 mask`(`0x140264b1a`), `mask & 1` 이면 `f32`(`0x140264b45`) + `u16 n`(`0x140264b6c`) + 16B 원소 n개. 기본값이 `{u32 0, f32 1.0, ptr×3}`(`0x140264ab3` `mov [rdi+4], 0x3f800000`) | 1 |
| `v ≥ 5` | `0x140264d03` | **f32 6개** — 클립 `+0xc4 +0xc8 +0xcc +0xd0 +0xd4 +0xd8`(`0x140264d33` `0x140264d5c` `0x140264d85` `0x140264dae` `0x140264dd7` `0x140264dfd`). 게이트 바이트 없이 무조건 24바이트 | 24 |
| `v ≥ 6` | `0x140264e05` | `u8 gate`(`0x140264e27`), 0 이 아니면 **본 수**만큼(`0x140264e5c` `sar rdi, 4`) 8B 원소 배열 | 1 |

그러니 **버전이 오를수록 클립 꼬리가 길어질 뿐 키 표현은 한 번도 바뀌지 않는다**:
`MDLA0003` 은 0004 에 없는 것이 없고(0004 가 `u8 gate` 하나를 더 붙인다), 0005 가 f32 6개를,
0006 이 `u8 gate` 하나를 더 붙인다. 세 스칼라 배열(`항상` / `v≥3`①② / `v≥6`)의 원소는 전부
`size/4 == frameCount + 1` 과 `size % 4 == 0` 을 __fastfail 로 강제한다(`0x140263f17` `sar r8d, 2`
→ `0x140263f24`/`0x140263f2c` `int 0x29`, v≥3 쪽은 `0x1402647bd`/`0x1402647ca`) — 즉 **프레임마다
float 하나짜리 트랙**이다.

**클립 flags 의 두 비트가 굽기를 가른다.** `0x140263f84`–`0x140263f92` 가
`(flags & 0x401) == 1` 이면 굽기 블록을 통째로 건너뛴다. 굽기 블록은 본 수를 4의 배수로 올린 뒤
`(frameCount+1) × 본수패딩 × 40` 바이트를 잡는데(`0x14026401b` `lea ecx,[rax+rax*4]` +
`0x14026401e` `shl ecx, 3` = ×40 → `0x140264021`), **40바이트 = 10 float** 이 §2.1 의 포즈 SoA
(pos3 + quat4 + scale3)다. 그리고 `flags & 1` 이면 클립 꼬리에 **0xC0바이트 레코드**가 하나 더
붙는다(`0x140264fc9` `test byte [rbp+0xc0], 1` → `0x140264fdb` `call 0x14028af20`; 기본값에
`-1`(`0x140264ff7`)과 `1.0f` 가 잔뜩 깔린다).

> **[정정 2026-08-21]** 아래 문단은 **블록을 하나 빠뜨렸고 산술도 틀렸다**(31 → **35**).
> 버전 블록 **뒤에 게이트 없는 이벤트 블록이 하나 더** 있다: `u32 이벤트수`(`0x14026536d`
> `mov r13d, dword ptr [rsi]`) + 수 × (`f32 초` `0x1402653bd` `movss xmm0,[rsi]` | NUL 종단
> JSON cstring `0x1402653e0` `cmp byte ptr [rsi], 0`). `flags & 1` 의 0xC0바이트 레코드 경로도
> 이 블록으로 합류한다. 게다가 `v≥3` 블록은 `u8 gate` 앞에 **`u32 count` 를 먼저 읽는다**
> (`0x14026468d` `mov eax,[rsi]` → `0x14026468f` `add rsi,4`) — 그 4바이트도 빠져 있었다.
> 그래서 게이트가 전부 0 이고 이벤트가 없을 때 꼬리는 `4+1+1+24+1+4 = **35**`바이트다.
> 옛 문면은 아래에 그대로 둔다.

클립 루프의 뒤끝은 `0x14026556b` `jl 0x1402639d0` 이다 — **버전 블록까지 읽고 나면 곧바로 다음
클립의 `u64 id`** 가 온다. Model3D 쪽 파서가 쓰는 "가변 트레일러 32~39B → 리싱크" 는 바로 이
꼬리(+ 건너뛰지 않은 `u64 id`)를 통째로 넘기는 휴리스틱이다. `MDLA0006` 에서 모든 게이트가 0 이면
꼬리는 `4 + 1 + 1 + 24 + 1 = 31`바이트, 거기에 다음 클립의 `u64 id` 8바이트가 붙는다.

### 6.3 이 절이 **확정하지 못한** 것

- ~~스켈레톤 필드 `[r15+0x28]`(항상 붙는 스칼라 트랙 배열의 개수)이 **무엇의 개수인지** — 이
  디코더 안에 그 필드를 쓰는 곳이 없다(쓰기 0건).~~
  **해소(2026-08-21): `MDLS` 꼬리 T3 의 레코드 수다.** 쓰기가 **있다** — 같은 함수의 MDLS
  파스 구간에서 `0x14026285f` `mov eax, dword ptr [rsi]` 로 u32 를 읽고
  `0x14026286e` `mov dword ptr [r12+0x28], eax` 로 저장한다(`r12` = 스켈레톤 객체). 바로 뒤
  `test eax,eax`/`je` 가 T3 루프를 건너뛴다. 즉 "항상 붙는 스칼라 트랙 배열" 은 **T3 레코드마다
  하나씩**이고, T3 가 0 이면 그 배열은 0바이트다 — 위 35바이트 관측과 맞물린다.
  Waple 대응물은 `SkeletonTail.constraints` 다. (2D 퍼펫에서 0 이라는 것 자체는 여전히 미검증.)
- 클립 `flags` 비트0·비트10(`0x400`)의 **의미**. 굽기를 건너뛴다는 사실만 읽었다.
- `v ≥ 5` 의 f32 6개가 무엇인지. 값 두 벡터라 AABB(min3/max3)로 보이지만 **소비처를 못 찾았다**.
  Model3D 쪽 주석이 "트레일러: u16 0 | AABB 6f | …" 라고 적은 것과 자리는 맞는다.
- `v ≥ 4` 의 32바이트 레코드 · `flags & 1` 의 0xC0바이트 레코드.
- Model3D 의 클립 id 휴리스틱(`readU16LE(bytes, at: o + 31)`, 마지막 클립은 헤더 `baseId`)이 이
  절의 "클립 선두 u64" 와 어떻게 맞아떨어지는지. 산술이 **4바이트 어긋난다**: 게이트가 전부 0 이면
  이 절의 꼬리는 `[v3 gate 1][v4 gate 1][v5 24][v6 gate 1]` = 27바이트라 다음 클립의 `u64` id 가
  `o + 27` 에 와야 하는데 Model3D 는 `o + 31` 을 읽는다(그리고 그 값이 실측 3파일·17클립에서
  맞았다고 적혀 있다). 남는 가능성은 ① 게이트 중 하나가 실물에서 0 이 아니다, ② 클립 `flags & 1`
  의 0xC0바이트 레코드가 끼어 있다, ③ 그 휴리스틱이 우연히 맞았다 — **워크샵 코퍼스 없이는 못
  가른다.** `Sources/WapleCore/Model3D.swift` 는 내 소유가 아니라 손대지 않았다(패치안은 보고서에).

---

## 부록 A. VA 인용 정정 기록 (툼스톤, 2026-08-21)

`scripts/re/va_citations.py` 전수 대조에서 이 문서의 VA 인용 **10건**이 명령 경계가 아니었다.
아홉은 같은 부류다 — **이미지 바이트 disp32 스캔이 주는 것은 명령 주소가 아니라 `disp32` 필드가
박힌 자리**라, 그대로 적으면 명령 시작보다 3~5바이트 뒤를 가리킨다(방법론 함정 16b).
나머지 하나는 `cmp` 명령 한복판(+1)이었다. 전부 `.pdata` 조각 시작에서 **선형으로** 다시 떠서
확인했고, 서술도 함께 검증했다(그 과정에서 `jae` → `jg` 오기 한 건을 같이 고쳤다).

> **[툼스톤] 종전 이 문서가 적던 값**(전부 disp32 필드 자리 — 명령 시작이 아니다): `0x140110cbe` `0x140111c76` `0x140112686` `0x1401c2d84` `0x1401c70a6` `0x1401d1773` `0x1401d2292` `0x14021c625` `0x1402268c1` `0x140237fb7` `0x140238a33` `0x14026f1b7` `0x1401a9d28` `0x140216102` · 그리고 명령 한복판(+1)이던 `0x1402cd760`.

정정 후에도 **사실 주장은 하나도 바뀌지 않았다**: 참조자 개수(`0x1404925fc` 12곳 ·
`0x140492700` 8곳 · `0x1404926fc` 1곳)는 disp32 자리를 세든 명령을 세든 같고, 어느 함수에
속하는지도 같다. 바뀐 것은 **어느 주소를 적어야 재현되는가** 뿐이다.

새로 확인한 사실 하나: 위 12곳이 읽는 상수는 **전부 같은 하나**다 —
`0x1404925fc` = `0x38D1B717` = **`1e-4f`**. 여덟 함수가 같은 수렴/근접 임계를 공유한다.
