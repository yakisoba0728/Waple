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

worldspace 시스템은 부모 체인을 **버린다**. 다만 §1 의 중력 게이트가 worldspace 를 배제하므로
`worldBasis` 를 먹는 시스템의 top 은 **항상** `parent · local` 전체 체인이다. 두 분기가 서로를
정확히 배타하므로 우리 배선에는 이 분기가 닿지 않는다.

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
- **worldspace 파티클의 드로우 변환.** §2-1 에서 실물은 worldspace 시스템의 스택 top 을
  오브젝트 **로컬** 4×4 로 덮어쓴다(항등이 아니다). Waple `particle3DVertices` 는
  `def.flags` worldspace 시 오브젝트 행렬을 통째로 우회해 `p.pos` 를 직결한다(F731).
  두 규약이 어긋날 여지가 있고 동봉 도달도 있다(worldspace def 114건). 이번 과제 범위 밖이라
  **손대지 않았다** — 별도 라운드에서 판정할 것.
