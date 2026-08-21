# 파티클 월드 기저 (`ParticleSimulator.worldBasis`)

`movement` 오퍼레이터의 **월드 중력**을 파티클 로컬 공간으로 옮길 때 쓰는 3×3 기저의 유도.
바이너리는 `wallpaper64.exe` 2.8.42 (imagebase `0x140000000`).

이 문서가 답하는 질문은 하나다 — **오브젝트 월드행렬의 무엇을, 어떤 방향으로 곱하는가.**
행/열을 뒤집거나 스케일을 빼면 컴파일도 되고 테스트도 통과하면서 조용히 틀린 그림이 나오므로,
아래는 전부 디스어셈 관측이고 추론에는 그렇다고 표시했다.

---

## 1. 게이트 — 언제 변환하는가

`movement` 핸들러(오퍼레이터 VM `0x14023fbc0` 의 점프테이블 갈래, `0x14023fdc9`부터):

```
0x14023fdc9  movsd  xmm8, [r14+0x10]      ; 오퍼레이터 gravity.xy
0x14023fdd8  mov    eax,  [r14+0x18]      ; gravity.z
0x14023fde2  test   byte ptr [r14+0x1c], 1  ; ← 오퍼레이터 flags bit0 = "월드 중력"
0x14023fde7  je     0x14023fe37             ;   꺼짐 → 변환 없이 원본 중력 그대로
0x14023fde9  test   byte ptr [rsi+0x20], 1  ; ← 시스템 flags bit0 = worldspace
0x14023fded  jne    0x14023fe37             ;   켜짐 → 이미 월드 시뮬이라 변환 스킵
```

**두 비트가 AND 로 걸린다.** 하나라도 어긋나면 `gravity` 가 그대로 실린다.
`ParticleSimulator.bakeMovementGravity` 의 `(m.worldGravity && !simulatesInWorldSpace)` 가 이것이다.

`r14` = 오퍼레이터 디스크립터(`+0x10..0x18` gravity vec3, `+0x1c` flags, `+0x20` drag),
`rsi` = 파티클 시스템(`+0x20` 시스템 flags).

## 2. 무엇을 읽는가 — 변환 스택 top

게이트를 통과하면:

```
0x14023fdef  mov  rdx, [rsi]           ; 파티클 시스템이 얹힌 오브젝트
0x14023fdf2  lea  rcx, [rbp+0x1e60]    ; 3×3 스크래치
0x14023fdf9  mov  rdx, [rdx+0x30]      ; ← 오브젝트 +0x30 = 변환 스택 TOP 포인터
0x14023fdfd  call 0x1400dd7d0          ; 4×4 → 촘촘한 3×3
0x14023fe02  mov  r8, rax
0x14023fe05  lea  rdx, [rbp+0x210]     ; gravity
0x14023fe0c  lea  rcx, [rbp+0xe90]     ; out
0x14023fe13  call 0x1401f87e0          ; out.c = dot(row_c, gravity)
0x14023fe20  movsd xmm8, [rax] …       ; 결과를 gravity 자리에 되쓴다
```

`+0x30` 이 스택 top 인 근거는 push/pop 자리에 있다 — `0x14022efcc`:

```
mov  rdx, [rax+0x30]      ; 현재 top
lea  rcx, [rdx+0x40]      ; 4×4 = 0x40 바이트
mov  [rax+0x30], rcx      ; push
movups [rcx],      [rdx]  ; 부모 top 을 새 top 에 **복제**
movups [rcx+0x10], …      ; (4×16 바이트)
```

그리고 `0x14022effd` 가 `0x14005ecb0(out, rdx=부모top, r8=로컬4×4)` 로 합성해 top 에 눌러 쓰고,
`0x14022f06f` 의 `add qword [rax+0x30], -0x40` 이 pop 한다.
→ **top 은 부모 체인이 전부 곱해진 월드행렬이다.**

### 2-1. 합성은 무조건이 아니다 (파티클 전용 분기)

파티클 시스템 순회(`0x1402375f5` push 직후)는 한 가지를 더 본다:

```
0x14023761b  test byte ptr [rbx+0x20], 1   ; 시스템 worldspace 비트
0x140237626  je   0x140237648
             ; 켜짐 → 부모를 합성하지 않고 로컬 4×4 를 top 에 통째로 덮어씀 (0x140237628–0x140237646)
0x140237648  ; 꺼짐 → out = mul(부모top, 로컬) 후 top 에 되씀 (0x14005ecb0)
```

worldspace 시스템은 부모 체인을 **버린다**. 여기서 덮어쓰는 4×4 는 그 시스템 인스턴스의
`psys+0x3a0` 이다(오브젝트가 아니라 **파티클 시스템**의 필드 — `lea r8,[rbx+0x3a0]` @0x1402375e3,
`rbx` = psys). 다만 §1 의 중력 게이트가 worldspace 를 배제하므로 `worldBasis` 를 먹는 시스템의 top 은
**항상** `parent · local` 전체 체인이다. 두 분기가 서로를 정확히 배타하므로 우리 배선에는 이 분기가
닿지 않는다.

### 2-2. 변환 스택은 오브젝트가 아니라 **그래픽스 컨텍스트**에 있다 (§2 표현 정정)

`[psys+0]` 은 씬 오브젝트가 아니라 렌더 컨텍스트다. 컨텍스트 생성자(0x14017c6d0)가 스택 셋을 깐다:

```
0x14017c6e0  lea rax, [rcx+0x2f0]
0x14017c723  mov [rcx+0x30], rax          ; stack0 베이스 = ctx+0x2F0
0x14017c72e  mov [rcx+0x38], ctx+0x4F0    ; stack1
0x14017c739  mov [rcx+0x40], ctx+0x6F0    ; stack2   (각 0x200 = 4×4 8단)
0x14017d56c… 세 스택의 베이스 4×4 를 전부 **항등**으로 초기화
```

이 구분이 중요한 이유는 §6 이다 — 스택 루트는 **단계마다 다르다**. 업데이트 단계에서는 항등이라
top = 순수 월드행렬이지만(그래서 §2–§3 의 결론이 성립한다), 렌더 패스는 루트를 **뷰 행렬**로
갈아끼운다(0x1401ecc30). 렌더 패스가 진입 시 세 스택의 top 을 저장하고(0x1401ecb6c–0x1401ecbdc)
종료 시 복원하므로(0x1401eceaf–0x1401ecebf) 시뮬이 보는 값은 오염되지 않는다. 게다가 오퍼레이터
VM(0x14023fbc0)의 호출자는 시뮬 스텝(0x140236cd0) **2건뿐**이고 렌더 경로(0x1402366f0)는 업데이트
계열(0x1402378a0/0x14023b340/0x14023fbc0)을 하나도 부르지 않는다 — `worldBasis` 에 뷰가 섞일 경로가
구조적으로 없다.

## 3. 규약 확정 — 행/열, 스케일

### 3-1. 추출 (`0x1400dd7d0`)

```
mov eax,[rdx];      mov [rcx],eax        ; 바이트 0x00 → 0x00
mov eax,[rdx+4];    mov [rcx+4],eax      ;        0x04 → 0x04
mov eax,[rdx+8];    mov [rcx+8],eax      ;        0x08 → 0x08
mov eax,[rdx+0x10]; mov [rcx+0xc],eax    ;        0x10 → 0x0c
… 0x14,0x18 → 0x10,0x14 · 0x20,0x24,0x28 → 0x18,0x1c,0x20
mov rax,rcx; ret
```

`mov` 9회뿐이다. **정규화도, 역행렬도, 전치도 없다.**
16바이트 블록 0·1·2 의 앞 3성분 → 12바이트 스트라이드 3×3.
→ **스케일이 그대로 실린다**(회전만 뽑는 경로가 아니다).

### 3-2. 곱셈 (`0x1401f87e0`)

`rcx`=out, `rdx`=v, `r8`=3×3. 디코드하면:

```
out[0] = v.x*m[0x00] + v.y*m[0x04] + v.z*m[0x08]
out[1] = v.x*m[0x0c] + v.y*m[0x10] + v.z*m[0x14]
out[2] = v.x*m[0x18] + v.y*m[0x1c] + v.z*m[0x20]
```

즉 `out.c = dot(row_c, v)` — `ParticleWorldBasis.apply` 와 일치.

**호출자는 전 바이너리에서 `0x14023fe13` 단 1건이다**(`e8` 전수 스캔). 이 3×3 곱은 오직
월드 중력 변환에만 쓰인다 → `worldBasis` 의 소비처가 하나뿐임이 구조적으로 보장된다.

### 3-3. 블록 0..2 는 기저인가, 전치된 무엇인가 — **결정적 관측**

여기가 유일하게 조용히 틀릴 수 있는 지점이다. "행우선 D3D 행벡터"와 "열우선 GL 열벡터"는
같은 변환에 대해 **메모리 배치가 동일**하므로 셰이더 문법(`mul(v,M)`)이나 행렬곱 인자 순서로는
갈리지 않는다. 실제로 `spec/engine/mul-convention.json` 자신이 "업로드 측에서 전치할 수 있으므로
규약 판별의 증거가 되지 못한다"고 적어 두었고, 그 전치는 실재한다 — `0x14019289d` 가 백엔드
플래그(`[rax+0x118] & 1`)를 보고 `0x1401928e0` 에서 4×4 를 원소별로 전치해 올리거나
`0x1401929a9` 에서 그대로 올린다.

그래서 **CPU 측 바이트 배치**를 직접 봐야 한다. 실물이 *같은 4×4* 를 두 조각으로 쪼개는 자리가
파티클 갱신 대역에 있다(`0x140238dce` 부터):

```
0x140238dce  lea  rdx, [rbp+0x70]     ; ← 4×4
0x140238dd6  call 0x1400dd7d0         ; 블록 0..2 → 기저 3×3
0x140238ddb  mov  edx, 3
0x140238de0  lea  rcx, [rbp+0x70]     ; ← 같은 4×4
0x140238de4  call 0x14005f600         ; Matrix::block(i) = m + 16*i  (i≤3 어서션 포함)
0x140238de9  movss xmm14, [rax]       ; 0x30
0x140238dee  movss xmm15, [rax+4]     ; 0x34
0x140238df4  movss xmm0,  [rax+8]     ; 0x38   → **위치(병진)**
```

즉 실물 4×4 는 `블록0..2 = 기저 | 블록3 = 병진` 이다. 이는 Waple `simd_float4x4`
(열우선 — `columns.0..2` = 기저, `columns.3` = 병진)와 **바이트 동일**이다.

교차검증: `0x14005ecb0` 의 곱셈식을 디코드하면 `out[4i+j] = Σ_k A[4k+j]·B[4i+k]` 이고,
`i=3` 을 넣으면 `t_out = A_기저 · t_B + t_A`(B[15]=1) — 블록3 이 병진일 때만 성립하는 형태다.
`0x14005f680`(균등 스케일 4×4)의 대각도 바이트 `0·0x14·0x28·0x3c` 로 4float/블록을 확인시킨다.

**결론**

| 항목 | 확정값 | 근거 VA |
|---|---|---|
| 행/열 | 행우선 3×3, 행 c = 로컬 축 c 의 월드 이미지 = Waple `m.columns.c.xyz` | 0x1400dd7d0 · 0x140238de4 |
| 방향 | 월드 → 로컬 (기저에 대한 투영) | 0x1401f87e0 |
| 스케일 | **포함**(정규화 코드 없음) | 0x1400dd7d0 |
| 부모 체인 | **포함**(변환 스택 top) | 0x14022efcc–0x14022f06f · 0x1402375f5–0x140237667 |
| 역행렬 | 없음 — 직교 회전에서만 `Rᵀ = R⁻¹` 라 정확, 비균등 스케일에선 축별로 배가 된다(실물 그대로) | 0x1400dd7d0 |

## 4. 동봉 도달 — **0 씬**

`ParticleSimulator.worldBasis` 는 `SceneRenderer.encode3DParticles` → `stepParticleSnapshots`
경로에서만 대입된다. 즉 **camera3D 씬 전용**이다(2D 정사영 경로는 이 코드를 아예 안 탄다).

설치본(`wallpaper_engine/`)과 동봉 사본(`WEAssets/`) 전수:

| 항목 | all | unique |
|---|---|---|
| 파티클 def 파일 | 585 | 216 |
| 시스템 `flags` bit0(worldspace) 선 def | 114 | — |
| `movement` 오퍼레이터 `flags` bit0(월드 중력) 보유 def | 12 | — |
| └ 그중 시스템 worldspace 꺼짐(= 게이트 통과) | 8 | **2** |
| └ 그중 gravity 비영 | 8 | 2 |

게이트를 통과하는 unique def 는 `presets/water/…/water_impact.json`(gravity `0 -150 0`) 과
`water_impact_droplets.json`(`0 -1000 0`) 둘뿐이고, 나머지 6건은 프리뷰/트리 중복 사본이다.

씬 쪽. 씬 파일은 `scene.json` 만이 아니다 — `defaultprojects` 의 절반은 `project.json` 의 `file`
키가 가리키는 **프로젝트명 JSON**(`audiophile/audiophile.json` 등)이다. `objects[]` 보유로 판별하면
동봉 씬 JSON 은 372개이고, 그중 `SceneDocument.parseCamera` 의 guard(`general.orthogonalprojection`
이 딕셔너리가 **아님** + `camera{eye,center,up}` 존재 — `fov` 는 선택 키다)를 통과하는
**camera3D 씬은 12개**다(설치본 8 + 에디터 씬 2, 후자는 동봉 사본과 중복되어 ×2):

```
arsenal · audiophile · demon_core · dna_fragment · fantasticcar · neon_sunset · ricepod · techno
scenes/modeleditor · scenes/particleeditor3dscale                     (설치본·WEAssets 양쪽)
```

이 12개 3D 씬에 마운트된 파티클 오브젝트는 **총 4건**이고, 그중 게이트를 통과하는 것은 **0건**이다.
위 두 water def 를 마운트하는 유일한 씬 `presets/water/previewwaterimpact/scene.json` 은
`general.orthogonalprojection` 이 딕셔너리라 **2D 오르토 씬**이고(따라서 `encode3DParticles` 를
아예 안 탄다), 게다가 그 오브젝트는 `angles = 0 0 0` 이라 기저가 균등 스케일뿐이다.

> **화면이 바뀌는 동봉 씬 = 0.**

배선의 값어치는 동봉 회귀가 아니라 사용자 씬(3D + 회전된 오브젝트 + 월드 중력)에 있다.
비-대상 시스템은 대입 자체를 건너뛰므로 `worldBasis` 가 항등으로 남고 `didSet` 도 안 불려
`movementGravity` 재구움조차 없다 — 산술이 비트동일이다.

## 5. `[미해결]`

- **오브젝트 로컬 4×4(`obj+0x360`)의 조립식.** 스택 top 이 `parent · local` 이라는 것과 그
  배치가 Waple 과 동일하다는 것은 확정했지만, `local` 이 JSON `origin/angles/scale` 로부터
  **어떤 오일러 순서**로 조립되는지는 이 라운드에서 보지 않았다. Waple 은
  `Scene3DMath.modelMatrix` 의 ZYX 를 쓰는데, 그 근거는 별도 실측(2026-07-03 주석)이고
  여기서 새로 확인한 바 없다. 회전 순서가 틀리면 기저도 같이 틀리지만, 그건 드로우 배치와
  **같은 방향으로** 틀리므로(둘 다 `particleWorldMatrix` 하나를 쓴다) 이 배선이 새로 만드는
  오차는 아니다.
- **비균등 스케일에서의 실물 의도.** 정규화가 없으니 축별 배율이 중력에 실리는 것은 관측
  사실이지만, 그것이 WE 의 의도인지 방치된 버그인지는 알 수 없다. 동봉 도달 0 이라 판정 불가.
- ~~**worldspace 파티클의 드로우 변환.**~~ → **§6 에서 확정(2026-08-21). 어긋나지 않는다.**

---

## 6. worldspace 파티클의 **드로우** 변환 (2026-08-21 확정)

§5 가 `[미해결]` 로 남겼던 항목이다. 결론부터: **실물은 worldspace 파티클을 그릴 때 오브젝트
변환(부모 체인 + 자기 로컬)을 통째로 버린다. Waple `particle3DVertices` 의 F731 우회와 같은
규약이고, 어긋나는 동봉 씬은 0개다.**

§2-1 이 인용한 `0x14023761b` 은 **드로우가 아니라 시뮬**(자식 인스턴스 순회)이었다. 드로우는 별도
vfunc 쌍이고, 거기서도 같은 비트를 보되 **다른 4×4** 로 덮어쓴다. 아래가 그 실측이다.

### 6-0. 먼저 GLSL — CPU 는 드로우에서 위치를 만지지 않는다

`assets/shaders/genericparticle.vert`(GS 없는 갈래):

```glsl
vec3 position = ComputeParticlePosition(a_TexCoordVec4.xy, textureRatio,
                                        vec4(a_Position.xyz, in_ParticleSize), right, up);
gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
```

`common_particles.h`:

```glsl
vec3 ComputeParticlePosition(vec2 uvs, float textureRatio, vec4 positionAndSize, vec3 right, vec3 up)
{ return positionAndSize.xyz + (positionAndSize.w * right * (uvs.x-0.5)
                              - positionAndSize.w * up * (uvs.y-0.5) * textureRatio); }
void ComputeParticleTangents(in vec3 rotation, out vec3 right, out vec3 up)
{ … mRotation = mul(mRotation, mat3(g_OrientationRight, g_OrientationUp, g_OrientationForward)); … }
```

즉 `a_Position` = 시뮬이 적재한 파티클 위치 그대로이고, 빌보드 전개도 모델 공간에서 일어난 뒤
**모델뷰프로젝션 하나**가 전부 처리한다(`g_ModelMatrixInverse` 로 눈 위치를 모델 공간으로 끌어오는
`ComputeParticleTrailTangents` 가 "`a_Position` 은 모델 공간"임을 한 번 더 못 박는다).
그래서 "worldspace 드로우 규약" = "그 모델뷰가 무엇인가" 다.

### 6-1. 드로우 vfunc 쌍 — `0x140236600` → `0x1402366f0`

파티클 시스템 vtable 의 연속 슬롯이다 — `0x1404915f8` = 업데이트(`0x140230650`),
`0x140491600` = 렌더(`0x140236600`). 두 슬롯이 붙어 있어 "한 요소에 핸들러 둘"이 아님도 확인된다
(`0x1402366f0` 의 호출자는 `0x1402366c1`(0x140236600) + 자기 재귀 2건이 전부다).

`0x140236600` (오브젝트 배치):

```
0x14023661d  lea r8, [rbx+0x660]          ; [rbx]->vfunc0x80() 이 돌려준 로컬 4×4 사본
0x140236646  mov rax,[rbx+0x2c0]          ; ctx
0x140236658  … push (부모 top 복제)        ; ctx+0x30 += 0x40
0x14023667e  test byte [rbx+0x2e0], 1
0x140236697  call 0x14005ecb0             ; top = mul(부모top, [rbx+0x660])
0x1402366c1  call 0x1402366f0             ; ← 파티클 재귀 드로우
0x1402366d2  add qword [rax+0x30], -0x40  ; pop
```

`0x1402366f0` 의 **첫 분기**가 이 문서의 답이다:

```
0x1402366fb  cmp qword [rcx+0x358], 0     ; 머티리얼 없음 → 즉시 return
0x14023670c  test byte [rcx+0x20], 1      ; ← 시스템 worldspace 비트 (§1 과 같은 비트)
0x140236718  je   0x14023674c             ;   꺼짐 → 손대지 않음(부모·자기 합성 유지)
0x14023671a  mov  rax, [rcx]              ;   켜짐 ↓  rax = ctx
0x14023671d  movups xmm0, [rax+0xAF0]     ;   ctx+0xAF0 의 4×4 를
0x140236724  mov  rdx, [rax+0x30]         ;   현재 stack0 top 에
0x140236728  movups [rdx], xmm0           ;   통째로 덮어씀 (…+0x10/+0x20/+0x30 까지 0x140236748)
```

**`psys+0x3a0`(시뮬 갈래가 쓰는 값)이 아니라 `ctx+0xAF0` 이다.** 이 차이가 전부다.

### 6-2. `ctx+0xAF0` = 렌더 패스의 stack0 **루트** 스냅샷

| 시점 | 하는 일 | VA |
|---|---|---|
| 컨텍스트 생성 | `ctx+0xAF0..0xB2F` := **항등** (세 스택 베이스도 같은 자리에서 항등) | 0x14017cbbf–0x14017cc0a · 0x14017d56c–0x14017d60f |
| 씬 패스 진입 직후 | `ctx+0xAF0..0xB2F := *[ctx+0x30]` — **루트를 뜬다** | 0x1401ecd03–0x1401ecd2b (패스 변종 0x1402083dd–0x140208405) |
| 씬 패스 종료 | 다시 **항등** | 0x1401ecece–0x1401ecf1c (변종 0x14020858b–…) |

스냅샷은 **카메라 셋업 직후, 오브젝트 순회 직전**에 찍힌다. 2D 정사영 패스에서 그 루트가 무엇인지가
그대로 보인다:

```
0x1401ecb54  test byte [rcx+0x304], 2
0x1401ecbef  jne  0x1401eccfc            ; ← 3D 패스는 아래 셋업을 건너뛴다(호출자가 이미 세움)
0x1401ecbf8  call qword ptr [rax+0x80]   ; 씬 루트 4×4
0x1401ecc06  call 0x14005f730            ; **역행렬** (=뷰 행렬)
0x1401ecc30  movups [rcx], xmm0 …        ; rcx = [ctx+0x30] = stack0 베이스 ← 뷰
0x1401ecc5a  …                           ; stack1 베이스 := 항등
0x1401eccf9  call qword ptr [rax+0x18]   ; stack2 := ortho(±w/2, ±h/2, -1000, 1000)
0x1401eccfc  … ctx+0xAF0 := *[ctx+0x30]
```

(`0x14005f730` 이 4×4 역행렬인 근거: 여인수 전개 후 `1/det`(xmm11)를 원소마다 곱해 `[rcx+…]` 에
쓴다 — 0x14005fb91–0x14005fc36 대역.)

즉 stack0 은 **모델뷰 스택**이고 그 루트는 뷰다. 3D 패스는 이 셋업을 건너뛰지만 스냅샷 자체는
동일하게 찍으므로, **어느 경로에서도 `ctx+0xAF0` 에는 오브젝트 변환이 한 조각도 안 들어간다.**

> **확정: worldspace 파티클의 modelview = 패스 루트(뷰)뿐 → model 부분은 항등 →
> `a_Position` 은 순수 월드 좌표.** 부모 체인만 버리는 게 아니라 **자기 로컬까지** 버린다.

### 6-3. 교차검증 — 시뮬 쪽 "합성 대신 치환"과 짝이 맞는다

worldspace 시스템은 좌표를 **변환 스택 루트 기준 절대좌표**로 들고 다닌다. 같은 규칙이 세 자리에
반복된다:

| 자리 | 비-worldspace | worldspace |
|---|---|---|
| 시뮬 자식 순회 (0x140237626) | `top = mul(부모top, psys+0x3a0)` @0x14023764c | `top := psys+0x3a0` @0x140237628 |
| 시뮬 자식 순회 (0x14023b0f4) | `top ·= psys+0x3a0` @0x14023b121 | `top := psys+0x3a0` @0x14023b101 |
| **드로우** (0x14023670c) | 손대지 않음 | `top := ctx+0xAF0` @0x14023671d |

그리고 그 `psys+0x3a0` 를 굽는 `0x14022a360` 이 worldspace 갈래에서 `inverse(stack0 top)` 을 앞에
곱해(0x14022a46f `0x14005f730` → 0x14022a482 `0x14005ecb0`) **절대좌표로 저장**한다. 업데이트 단계의
stack0 루트는 항등이므로(§2-2) 그 "절대"가 곧 월드다. 렌더가 top 을 패스 루트로 되돌리는 것이
정확히 이 규약의 반대쪽 짝이다 — 월드 좌표를 뷰에 그대로 태운다.

### 6-4. Waple 대조 — 어긋나지 않는다

```swift
let worldspace = (sys.def.flags & 1) != 0
let colScale = worldspace ? Float(1) : simd_length(…m.columns.0…)
…
if worldspace { center = p.pos } else { center = (m * SIMD4(p.pos, 1)).xyz }
```

- **위치**: 실물 model = 항등 ↔ Waple `center = p.pos` (오브젝트 변환 0 적용). 일치.
- **크기**: 실물의 빌보드 전개는 모델 공간에서 일어나고 model = 항등, 뷰는 강체라 크기가 월드
  단위다 ↔ Waple `colScale = 1`. 일치.
- **입도**: 실물은 `[psys+0x20]&1` 을 **시스템마다**(자식 재귀 0x140236b78/0x140236c38 포함) 본다
  ↔ Waple 도 `sys.def.flags` 를 시스템별로 본다. 일치.
- 비-worldspace 갈래는 실물이 아예 손대지 않는 쪽이라 Waple 도 종전 `m` 경로 그대로다(무회귀).

### 6-5. 동봉 도달 실측 — **어긋나는 씬 0개**

설치본 + `WEAssets` 전수(§4 와 같은 판별식):

| 항목 | 수 |
|---|---|
| 씬 JSON(`objects[]` 보유) | 372 |
| camera3D 씬 (`parseCamera` guard 통과) | 12 |
| 파티클 오브젝트 마운트 (전 씬) | **248** (그중 def 경로 미해결 8 — 전부 2D preset preview 의 `particles/presets/*.json`, 패키지 내부 경로라 설치 트리에 파일이 없다) |
| worldspace(루트 `flags` 값 1) 마운트 | **24** |
| worldspace(루트 **또는 자손**) 마운트 | **26** |
| └ 그중 camera3D 씬 | **0** |
| camera3D 12씬의 파티클 마운트 | **4** — demon_core · ricepod · neon_sunset(`Fog 1`) · dna_fragment |
| └ 그중 worldspace | **0** (네 def 모두 `flags` 키 부재 = 0, 자손 포함) |

worldspace 마운트 26건은 **전부 2D 정사영 preset preview 씬**이다(`presets/water/…`,
`presets/smoke/…`, `presets/fireworks/preview_fireworks3`, `presets/magic/previewvortexorb`,
`presets/rain/previewrainsplashes`, `presets/stars/previewshootingstar`,
`scenes/particleelementpreviews/inheritcontrolpointvelocity`, … ×2 = 설치본·WEAssets 중복).
2D 경로는 `encode3DParticles`/`particle3DVertices` 를 아예 안 탄다.

> **`particle3DVertices` 의 worldspace 갈래는 동봉 코퍼스에서 한 번도 안 밟힌다 → 어긋나는 씬 0개.
> 코드는 손대지 않았다.**

(참고로 그 26건의 오브젝트는 전부 비항등 변환이다 — origin `(128, 234, 0)` 류. 즉 이 갈래가 3D 씬에
있었다면 §6-6 의 갭이 곧바로 화면에 나왔을 것이다. 2D 라 안 나올 뿐이다.)

### 6-6. `[미해결]` — worldspace **방출** 좌표계

드로우는 확정했지만 그 짝인 **방출**은 확정하지 못했다.

실물의 방출 셋업(`0x140238c8f`)은 위치 변환과 방향 3×3 을 worldspace 비트로 갈라 잡는다:

```
0x140238c62  movaps xmm1, xmm12          ; xmm12 = 1.0f (0x1402379a1)
0x140238c75  call 0x1401a27f0            ; [rbp+0x490] := 3×3 항등 (스트라이드 12, 대각 = xmm1)
0x140238c7a  call 0x14005f680            ; [rbp+0x70]  := 4×4 항등
0x140238c83  call 0x14005f680            ; [rbp+0x410] := 4×4 항등
0x140238c8f  test byte [rsi+0x20], 1     ; worldspace
0x140238c96  mov  rdx, [[rsi]+0x30]      ; stack0 top
0x140238c9a  je   0x140238cc8
             ; 켜짐 → [rbp+0x490] := basis3x3(top)          (0x140238ca3, 위치 변환은 **항등 유지**)
0x140238cc8  ; 꺼짐 → [rbp+0x3d0] := inverse(top) (0x14005f730) → [rbp+0x70] = [rbp+0x410] := 그것
0x140238d3a  ; [rbp+0x520] = mul([rbp+0x410], emitter+0xb8)
```

이 모양은 "**에미터 4×4 가 절대좌표**라면 worldspace = 월드 방출 / 아니면 `inverse(월드)` 로 로컬
방출"로 딱 떨어진다. 그런데 그 에미터 4×4(`emitter+0xb8`)는 컨트롤포인트 노드의 `+0x18` 에서
복사되고(0x14023adf3), 그 노드 행렬이 절대인지 로컬인지는 **이번 라운드에서 확인하지 않았다.**
추측으로 정하면 조용히 틀린 그림이 되므로 확정하지 않는다.

영향 범위: Waple `ParticleSimulator` 는 worldspace 여부와 무관하게 **에미터 로컬**로 방출한다.
만약 실물이 월드 방출이라면 두 구현은 **오브젝트 월드행렬이 항등일 때만** 일치한다(어긋나는 양은
정확히 `M_obj`). 고칠 자리는 드로우가 아니라 **방출**(`WapleCore`)이다. §6-5 대로 동봉 camera3D
도달이 0 이라 동봉 회귀는 없고, 이번 라운드는 드로우 규약 확정까지만 하고 멈췄다.

부수적으로 미확정인 것 하나 더: worldspace 시스템이 **자식 시스템을 가질 때**, 드로우는 자기
파티클을 그린 뒤 자식 순회 직전에 `top := psys+0x3a0` 로 되돌린다(0x140236ae9–0x140236b1d).
루트 시스템의 `psys+0x3a0` 는 생성자의 항등 초기화(0x140229661–0x1402296a9, 대각 0x3a0/0x3b4/0x3c8/0x3dc)
뿐이고 `0x14022a360`(호출자 5건: 0x1402364e0 · 0x1402374e0 · 0x14023753d · 0x14023b004 · 0x14023b076)은
자식 인스턴스 생성 자리에만 도는 것으로 보이는데, 그러면 자식이 뷰 없는 top 을 받는다 — 실물의 의도인지 방치된 경로인지
판정하지 못했다. 동봉 도달 0 이라 검증 수단도 없다.
