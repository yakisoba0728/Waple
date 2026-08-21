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

### 0.1 2차 재대조 결과 (2026-08-21)

초판의 사실 주장을 원본과 표본 대조했다. **항목 2~9 는 전부 재확인해 그대로 성립**하고,
아래 넷을 정정했다.

| 정정 | 초판 | 실물 | 근거 |
|---|---|---|---|
| **A** | 파일 3축 순서 `(Z,Y,X)` | **`(X,Y,Z)`** — 초판이 축을 뒤바꾼 쪽이었다 | §2.1 |
| B | `0.9995f` = `0x3F7FBE77` | `0.9995f` = **`0x3F7FDF3B`**. `0x3F7FBE77` 은 **`0.999f`** 이고 `.rdata 0x1404926fc` 에 **실재**한다(참조자 1곳, `0x1401a9d28`) | §2.6 |
| C | 본 제약 문자열 블록에 `gd tf ik …` | 두 번째 항목 **`m`(`0x140492144`)** 이 빠져 있었다. 블록 끝도 `0x1404921e8` 이 아니라 그 자리에서 `blendtime` 이 **시작**한다(끝은 `0x1404921f1`) | §1.2 |
| D | 도수 `blending(1302)` 등의 단위 미표기 | 그 수치는 **occurrence 가 아니라 파일 수**다(occurrence 는 1314). 범위 라벨을 붙였다 | §1.2 |

정정 A 가 코드까지 되돌린 유일한 항목이다. 커밋 `18a7ae6` 의 나머지 변경(nlerp·마스크·모드·
`layerWeight`)은 재대조에서 **전부 옳았다** — 되돌리지 않았다.

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
5. `world[i] = world[parent] × local[i]` — `0x1401fea63`–`0x1401feada`
   (부모 인덱스 = `bone+0x60` — `cmp dword [rax+0x60], -1` @`0x1401fea5d`, `-1`=루트;
   4x4 곱 `call 0x14005ecb0` @`0x1401fea8b` 인자 `rcx`=출력 `rdx`=부모행렬 `r8`=자기 로컬).
   ⚠️ `0x14005ecb0` 의 **피연산자 순서**(rdx×r8 인지 r8×rdx 인지)는 2차에서도 직접 떠 보지
   않았다 — 함정 14 대로 레이아웃만으론 판정 불가다. Waple 은 `world[p] * local`(열벡터 규약)로
   두었고, `skin = world × bindWorld⁻¹` 가 `t=0` 에 항등이 되는 자기정합으로만 지지된다.
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
  `.rdata 0x1404926fc` 에 **실재**한다. 참조자는 `0x1401a9d28` 한 곳뿐이고 slerp 와 무관하다).
  `0x3F7FDF3B` 는 `.rdata` 어디에도 상수로 없다. 이미지 전체에서 그 4바이트 패턴이
  나오는 곳은 `.text 0x1402cd760` 한 군데뿐이고(`3b df 7f 3f` — `cmp`/`jae` 명령 바이트열의
  일부), 이미지 `.text` 전 구간 disp32 스캔에서 그 주소를 가리키는 rip-상대 명령이 **0건**이다.
- `0.0001f`(`0x38D1B717`)는 `.rdata 0x1404925fc` 에 실재하고 참조자가 12곳 있다. 그중 하나
  (`0x14021c620`)는 본 물리/IK 솔버(`0x14021c480`)가 루프 진입 전에 `FLT_EPSILON`
  (`0x1404925e0`)과 나란히 레지스터에 올려두는 **솔버 수렴 임계**다. slerp(`0x140216070`)는
  이 상수를 참조하지 않는다 — 나머지 11곳도 전부 스켈레톤 밖(`0x140110630`, `0x1401c2a40`,
  `0x1401d15a0`, `0x1402378a0`, `0x14026eb60` …)이다.
slerp 의 실제 임계는 `0x3F7FFFFE = 1 − FLT_EPSILON = 0.99999988f` 하나뿐이다
(`.rdata 0x140492700`, rip-상대 참조자 8곳 중 slerp 것은 `0x140216102`).

2차 재확인: `0x140216070` 로의 `call` 은 이미지 전체에 **28곳**이고 그 전부가
`0x1401fdf90`(14곳) · `0x14021c480`(14곳) **두 함수 안**이다. `0x1404925fc`(`0.0001f`)의
rip-상대 참조자는 정확히 **12곳**(`0x140110cbe` `0x140111c76` `0x140112686` `0x1401c2d84`
`0x1401c70a6` `0x1401d1773` `0x1401d2292` `0x14021c625` `0x1402268c1` `0x140237fb7`
`0x140238a33` `0x14026f1b7`)이고 그중 스켈레톤 쪽은 `0x14021c625` 하나뿐이다.

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
- `layerWeight(blend:blendIn:blendOut:blendTime:duration:time:)` — §2.3.
- `worldMatrices` — 바인드 TRS 시딩 → 레이어 순차 캐스케이드(TRS 공간, 회전 nlerp),
  트랙 없는 본은 스킵. 바인드가 TRS 로 분해되지 않으면(스큐/거울) 종전 행렬 lerp 로 폴백.
  부모 합성은 `p < i` 게이트라 **순환 부모·범위 밖 부모는 루트로 떨어진다**(무한재귀 없음).
- `addTRS` — 가산 레이어(위치 델타 + 쿼터니언 델타곱 + nlerp).

`Sources/WapleCore/Model3DPose.swift`
- `sampledTRS` 신설, `sampledLocal` 이 그것을 경유 — 3D 경로도 회전 nlerp.
  `PuppetPose.rotationQuaternion` 을 부르므로 §2.1 정정이 3D 경로에도 그대로 적용된다.

`Sources/WapleCore/PuppetModel.swift` — `Key.angles` / `Animation.mode` 주석에 근거 VA 기재.

`Sources/WapleCore/Model3D.swift` **[2차]** — `Animation.Key` 에 36B/`frameCount+1` 불변식과
WE 의 `int 0x29` 즉사 지점(`0x140263c8c`/`0x140263c95`)을, `Animation.mode` 에 인식 문자열이
둘뿐이라는 사실을 기재.

테스트
- `Tests/WapleCoreTests/PuppetPoseWEParityTests.swift` — 15건. **[2차]** 축 순서 테스트를
  `(X,Y,Z)` 로 교정하고 `testBakeMatchesEngineSlotExpressions`(엔진 굽기 식 + 슬롯 순서 고정) ·
  `testPublicApiEulerConventionMatchesFileConvention`(`setLocalBoneAngles` 행렬 원소 대조) 신설.
- `Tests/WapleCoreTests/PuppetPoseTests.swift` — `key(_:_:rz:)` 헬퍼가 세 번째 슬롯(+0x14)에
  넣도록 교정.
- `Tests/WapleCoreTests/PuppetHostileInputTests.swift` **[2차 신설, 13건]** — 신뢰 경계.
  거짓 본 수(40억/9만) · 순환 부모 · 큰 u32 부모 · 거짓 프레임 수 · `%36` 아닌 트랙 크기 ·
  EOF 넘는 트랙 크기 · 4GB 꼬리 블롭 · 거짓 애니 수 · 범위 밖 정점 본 인덱스 ·
  범위 밖 삼각형 인덱스 · `fps≤0`/`length≤0` · `Playback::sample` 인덱스 규약.

---

## 5. 미확정 / 후속

- **`0x14005ecb0`(4x4 곱)의 피연산자 순서** — §2.4 5번. 함정 14 라 레이아웃만으론 판정 불가고
  2차에서도 직접 뜨지 않았다. Waple 은 자기정합(`t=0` 항등)으로만 지지된다.
- 정확히 `T = D` 인 순간의 샘플 인덱스가 WE(`i=frameCount−1`)와 Waple(`i=frameCount`)에서
  갈리는 문제 — §2.2. 실효 차이는 부동소수 1 ulp 수준이라 정본화하지 않았다.
- 가산 레이어의 **기준 포즈**(클립 프레임0 vs 본 레스트) — 구조는 확인, 인자 출처 미추적.
- `wraploop`(재생 플래그 bit2)이 샘플링에 어떻게 쓰이는지.
- 본 물리 / IK 솔버(`0x1401fdf90`) 전체 — `lamin`/`lamax`/`ikd`/`ikrd` 등 §1.2 키의 수식.
- `MDLE0002` · `MDMP0001`(모프 타깃 추정) 섹션.
- 동봉 코퍼스에 스킨 모델이 0개라 **렌더 실측 게이트가 없다**. 워크샵 퍼펫 `.mdl`
  (`models/*_puppet.mdl`)을 확보하면 §2.1 축 순서를 **가장 먼저** 재확인할 것 — 이 문서가
  같은 자리에서 한 번 틀렸다.
