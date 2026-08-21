# WE 스켈레톤 / 퍼펫 애니메이션 — 실물 대조

대상: `wallpaper64.exe` 2.8.42 (md5 `438cb215f20a8f6c38f57fbc3d9da588`, imagebase `0x140000000`),
설치본 `assets/` · `projects/defaultprojects/`, 에디터 UI `ui/dist/scripts/scripts.js`.
조사일 2026-08-21. 모든 주소는 VA.

---

## 0. 요약 (Waple 과 어긋났던 것)

| # | 항목 | WE 실물 | 종전 Waple | 조치 |
|---|---|---|---|---|
| 1 | 키 오일러 3축의 **파일 순서** | `(Z, Y, X)` = `+0x0c,+0x10,+0x14` | `(X, Y, Z)` 로 읽음 → **X·Z 축 뒤바뀜** | 수정 |
| 2 | 키 회전 보간 | 쿼터니언 **nlerp + 최단호 + 재정규화** | 오일러 성분 lerp | 수정 |
| 3 | 레이어 회전 블렌드 | 쿼터니언 nlerp | 행렬 성분 lerp(길이 수축) | 수정 |
| 4 | 레이어가 안 건드리는 본 | 건너뜀(본별 마스크) | 바인드로 되끌림 | 수정 |
| 5 | 재생 모드 문자열 | `stricmp` 로 `mirror`/`single` 만, 그 밖은 loop | `"clamp"` 를 single 별칭 취급, 대소문자 구분 | 수정 |
| 6 | 레이어 유효 가중치 | `blend × blendin램프 × blendout램프` | 없음 | 추가 |
| 7 | 정점 본 가중치 정규화 | **안 한다**(셰이더 원시 가중합) | `wsum` 나눗셈 | 유지 + 반증 주석 |
| 8 | slerp | 존재하지만 **본 물리/IK 전용**, 애니메이션 경로엔 없음 | 없음 | 기준선으로만 추가 |
| 9 | 단서의 `0.9995f` / `0.0001f` | 이 빌드에 그런 slerp 상수 없음 | — | 반증 |

---

## 1. 동봉 자산 전수 조사

### 1.1 `.mdl`

동봉 트리(`Sources/WapleRender/Resources/WEAssets/`) + 설치본(`wallpaper_engine/`) 합계 **30개**
(내용 고유 28개 — 저장소의 2개는 설치본 사본).

| 매직 | 개수 |
|---|---:|
| `MDLV0004` | 8 |
| `MDLV0014` | 15 |
| `MDLV0017` | 2 |
| `MDLV0023` | 5 |

크기 min/중앙/max = 150 / 5 979 / 570 179 바이트.

**스켈레톤/애니메이션을 가진 파일: 0개.** 30개 전수에서 `MDLS####` · `MDLA####` · `MDAT0001` ·
`MDMP0001` · `MDLE0002` 섹션 매직이 **한 건도** 나오지 않았다. 즉 본 수 분포는 전부 0이고,
동봉 자산만으로는 스켈레톤 평가를 실측 대조할 수 없다. (워크샵 코퍼스 451개 `.mdl` 은 이
컨테이너에 없다 — `spec/formats/mdl-deep.json` 의 `format.mdl.parseCoverage` 는 과거 Z: 드라이브
스캔 기록이다.) 그래서 이 문서의 근거는 **바이너리 + 동봉 셰이더 + 에디터 UI 스키마**다.

### 1.2 퍼펫 관련 JSON 키

동봉 `.json` **3 655개** 전수 스캔 — `puppet` / `bone` / `skeleton` / `animationlayers` /
`ik*` / `constraint` / `look*` / `physics` 키는 **0건**. 실제로 등장하는 애니메이션계 키는
`blending`(1302), `rate`(587), `animationmode`(286), `blendinstart`/`blendinend`(26/24),
`blendoutstart`/`blendoutend`(8/8), `fps`(12), `frame`(12), `animation`(12) 뿐이고 이들은
파티클·프로퍼티 애니메이션 소속이지 스켈레톤 소속이 아니다.

퍼펫 본 스키마는 자산이 아니라 **엔진 문자열 테이블**과 **에디터**에 있다.

`.rdata 0x140492140 – 0x1404921e8` 연속 블록(파서 `0x140265c30`–`0x140266f99`):

```
gd tf ik ikce se re ti tp tm la rs ts rf ri ray raz tax tay
lamin lamax ltmax rax ikrd ikse ikfe ikrminl taz ikd ikg ikr ikrmaxl  blendtime
```

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

---

## 2. 파이프라인 (VA)

MDL 디코더는 `0x140261880`–`0x140265a0c`(단편 다수). 섹션 매직 비교는 `memcmp` 길이 **4**라
`"MDLA"`/`"MDLS"` 만 보고 뒤 4자리는 `atoi`(`0x1402c82c0`)로 읽어 버전 게이트에 쓴다 — 그래서
`MDLA0001`(구 2D 퍼펫)과 `MDLA0006`이 같은 코드 경로다.

### 2.1 애니메이션 키 → 쿼터니언 (로드 시점)

트랙 키는 파일에서 **36바이트**(`0xE38E38E38E38E38F`/`shr 5` 나눗셈 검사 @`0x140263c61`)이고
키 수는 `frameCount + 1`(같은 자리 `cmp rdx, ecx+1`). 9 float = pos3 + 각3 + scale3.
런타임 표현은 **10 float**(pos3 + quat4 + scale3) SoA — 각3이 쿼터니언4로 부풀기 때문이다.

`0x140264188`–`0x1402642ae` (두 번째 사본 `0x1402644c7`–`0x1402645ea`):

```
γ = key[+0x0c] · 0.5f      ; 0.5f 상수 VA 0x1404926c0, 로드 0x14026240a
β = key[+0x10] · 0.5f
α = key[+0x14] · 0.5f
w = cα·cβ·cγ + sα·sβ·sγ    ; 0x14026422e
x = sα·cβ·cγ − cα·sβ·sγ    ; 0x140264250
y = sα·cβ·sγ + cα·sβ·cγ    ; 0x14026427c
z = cα·cβ·sγ − sα·sβ·cγ    ; 0x14026426e
```

이는 `Rz(key[+0x0c]) · Ry(key[+0x10]) · Rx(key[+0x14])` 와 항등이다(수치 검증).
**즉 파일 3축의 의미는 (Z, Y, X)이고 합성은 ZYX다.** 각 단위는 라디안(반각 계수가 `0.5f`,
`π/360` 이 아님).

교차 확인 — 오일러→행렬 헬퍼 `0x140215020`은 인자 순서 `(a1, a2, a3)` 에 대해
`m00 = cos(a2)·cos(a1)`, `m20 = −sin(a2)` 를 쓰므로 `Rz(a1)·Ry(a2)·Rx(a3)`.
씬스크립트 `setLocalBoneAngles(bone, Vec3 v)`(`0x14020fce0`)은 `m00 = cos(v.y)·cos(v.z)` 라
**공개 API 는 (x,y,z)** 다 — 뒤바뀐 것은 파일 바이트 순서지 회전 합성 순서가 아니다.

### 2.2 재생 시계

클립 초기화 `0x1401a8c10`–`0x1401a8ca9` (출력 구조체 = `layer+0xf8`):

```
out[+0x00] = 1/fps                     ; 0x1401a8c5e   (fps ≤ 0 이면 실패 반환)
out[+0x08] = frameCount / fps  = D     ; 0x1401a8c3f   (D ≤ 0 이면 실패)
out[+0x0c] = flags
out[+0x10] = frameCount
stricmp(mode,"mirror")==0 → flags |= 1 ; 0x1401a8c71
stricmp(mode,"single")==0 → flags |= 2 ; 0x1401a8c87
5번째 bool 인자(wraploop)   → flags |= 4
6번째 bool 인자(startpaused)→ flags |= 0x20000000
```

**모드 문자열은 딱 둘.** `"clamp"`·`"loop"`·빈 문자열은 전부 플래그 없음 = loop.
비교가 `stricmp`(`0x1402c10d0`)라 대소문자를 가리지 않는다.

시간 전진 `Playback::advance` `0x1401a9f60`–`0x1401aa18d`, `fmodf` = `0x14041d0c0`:

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
t  = fmodf(T, fd) / fd                     ; fd = 1/fps    (0x1401705a7, 0x1401705ba)
i  = clamp(trunc(T / fd), 0, frameCount-1) ; 0x1401705be–0x1401705d6
j  = min(i + 1, frameCount)                ; 0x1401705dd–0x1401705ea
```

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
5. `world[i] = world[parent] × local[i]` — `0x1401fea63`–`0x1401feada`
   (부모 인덱스 = `bone+0x60`, `-1`=루트, 4x4 곱 `0x14005ecb0`).
6. 스킨 팔레트 → `mat4x3 g_Bones[BONECOUNT]`(uniform id `0x72`, 등록 `0x140003fcb`).
   `BONECOUNT` 콤보는 본 수(가상함수 `vtbl+0xd8`, `0x140207220`), `SKINNING` 콤보 = 1.

**가중치 정규화는 어디에도 없다.** 레이어 가중치는 순서대로 곱해 끌어당길 뿐이고
(합이 1을 넘든 말든), 정점 본 가중치도 셰이더가 그대로 더한다(§3).

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
(수학적으로 동일), 마지막에 뉴턴 1스텝 rsqrt 로 재정규화한다. 위치·스케일은 성분 lerp.
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
- `0.9995f`(`0x3F7FBE77`)는 `.rdata` 어디에도 상수로 없다. 이미지 전체에서 그 4바이트 패턴이
  나오는 곳은 `.text 0x1402cd760` 한 군데뿐이고, 참조하는 rip-상대 명령이 없다 —
  명령 바이트열이 우연히 그 패턴이 된 것이다.
- `0.0001f`(`0x38D1B717`)는 `.rdata 0x1404925fc` 에 실재하고 참조자가 12곳 있다. 그중 하나
  (`0x14021c620`)는 본 물리/IK 솔버(`0x14021c480`)가 루프 진입 전에 `FLT_EPSILON`
  (`0x1404925e0`)과 나란히 레지스터에 올려두는 **솔버 수렴 임계**다. slerp(`0x140216070`)는
  이 상수를 참조하지 않는다 — 나머지 11곳도 전부 스켈레톤 밖(`0x140110630`, `0x1401c2a40`,
  `0x1401d15a0`, `0x1402378a0`, `0x14026eb60` …)이다.
slerp 의 실제 임계는 `0x3F7FFFFE = 1 − FLT_EPSILON = 0.99999988f` 하나뿐이다.

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
저작 시점에 정규화해 두는 전제). 법선/탄젠트도 같은 가중합의 3x3 부분을 쓴다.
`SKINNING_ALPHA` 콤보가 켜지면 `g_BonesAlpha[BONECOUNT]`(uniform id `0x73`)의 가중합을
`saturate` 해 정점 알파에 곱한다.

Waple 의 `PuppetPose.skinnedPositions` / `Model3DPose.cpuSkinnedPacked` 는 `wsum` 으로
나눈다 — 이는 Waple 자체 셰이더(`Mesh3DShaders.mv_skin`)와의 정합을 위한 것이지 WE 파리티가
아니다. **의도적으로 유지**하고 반증 주석만 남겼다(실물 자산은 정규화돼 있어 차이가 없다).

---

## 4. Waple 반영 내역

`Sources/WapleCore/PuppetPose.swift`
- `rotationQuaternion(_:)` 신설 — 파일 (Z,Y,X) 순서 + 반각 식(§2.1) 단일 소스.
  `localMatrix(position:angles:scale:)` 는 이걸 거치도록 재작성(X·Z 뒤바뀜 수정).
- `TRS` / `trsMatrix` / `decomposeTRS` / `quaternionMatrix` / `quatMultiply` / `quatConjugate`.
- `nlerpShortest` — §2.5 그대로. `slerpShortest` — §2.6 기준선(스켈레톤 경로 미사용).
- `sampledTRS` / `sampledLocal` — 회전을 nlerp 로 보간.
- `frame(time:fps:length:mode:)` — `lowercased()` 매칭, `"clamp"` 제거(loop 로 떨어짐).
- `layerWeight(blend:blendIn:blendOut:blendTime:duration:time:)` 신설 — §2.3.
- `worldMatrices` — 바인드 TRS 시딩 → 레이어 순차 캐스케이드(TRS 공간, 회전 nlerp),
  트랙 없는 본은 스킵. 바인드가 TRS 로 분해되지 않으면(스큐/거울) 종전 행렬 lerp 로 폴백.
- `addTRS` — 가산 레이어(위치 델타 + 쿼터니언 델타곱 + nlerp).

`Sources/WapleCore/Model3DPose.swift`
- `sampledTRS` 신설, `sampledLocal` 이 그것을 경유 — 3D 경로도 회전 nlerp.

`Sources/WapleCore/PuppetModel.swift` — `Key.angles` / `Animation.mode` 주석에 근거 VA 기재.

테스트: `Tests/WapleCoreTests/PuppetPoseWEParityTests.swift`(13건 신설),
`Tests/WapleCoreTests/PuppetPoseTests.swift`(회전 헬퍼를 파일 순서로 교정 + z 축 이탈 판별 단언 추가).

---

## 5. 미확정 / 후속

- 가산 레이어의 **기준 포즈**(클립 프레임0 vs 본 레스트) — 구조는 확인, 인자 출처 미추적.
- `wraploop`(재생 플래그 bit2)이 샘플링에 어떻게 쓰이는지.
- 본 물리 / IK 솔버(`0x1401fdf90`) 전체 — `lamin`/`lamax`/`ikd`/`ikrd` 등 §1.2 키의 수식.
- `MDLE0002` · `MDMP0001`(모프 타깃 추정) 섹션.
- 동봉 코퍼스에 스킨 모델이 0개라 **렌더 실측 게이트가 없다** — 워크샵 퍼펫 `.mdl`
  (`models/*_puppet.mdl`)을 확보하면 §2.1 축 순서를 최우선으로 재확인할 것.
