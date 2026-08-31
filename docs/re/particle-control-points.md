# 파티클 컨트롤 포인트 — 주입에서 소비까지

> 대상: `wallpaper64.exe` (imagebase `0x140000000`). 이 문서의 VA 는 **전부 이 저장소에서 직접 다시 떴다**
> (함정 16 — 남의 주석을 베끼지 않았다). 오퍼레이터 바이트코드 VM 자체는
> `docs/re/particle-operator-vm.md` 가 정본이고, 여기서는 **컨트롤포인트(CP)가 어디서 만들어져
> 누가 매 프레임 읽는가**만 다룬다.
>
> 문장마다 **[확정] / [추정] / [미해결]** 을 붙였다. 근거 VA 가 없는 문장은 [추정] 이상이다.

---

## 0. 한 줄 요약

**[확정] CP 소비처는 셋이고, 셋 다 매 프레임 CP 레코드 `+0x00..0x3f`(현재 프레임 월드 4×4)를 읽는다.**

| 소비처 | 함수 | CP 에서 읽는 것 |
| --- | --- | --- |
| 이미터 VM | `0x1402378a0`–`0x14023b33d` | **4×4 전체**(회전 3행 + 위치 행) |
| 이니셜라이저 VM | `0x14023b340`–`0x14023fbbc` | opid 8·13·14·15 — 13 은 **3×3 회전까지**, 나머지는 위치 행 |
| 오퍼레이터 VM | `0x14023fbc0`–`0x14024be38` | **위치 행 `+0x30/+0x34/+0x38` 만** (46 스냅샷 전수 확인) |

`instanceoverride.controlpointN` / `controlpointangleN` 은 이 셋에 **간접으로** 닿는다:
씬 오브젝트의 프로퍼티백 → CP 레코드의 **base 4×4 `+0x80..0xbf`** → 매 프레임 오브젝트 변환과
합성되어 `+0x00..0x3f` → 위 셋. 즉 **소비처가 없다는 종전 판단은 틀렸다.**

---

## 1. 런타임 CP 레코드 — `0xd0` 바이트

시스템 객체의 `[sys+0x400]` 이 CP 배열 포인터, `[sys+0x44]` 가 개수다. 인덱싱은 언제나
`imul rXX, idx, 0xd0` + `add rXX, [sys+0x400]` 이다(전수 67곳, §10 재현).

| 오프셋 | 내용 | 근거 VA |
| --- | --- | --- |
| `+0x00..+0x3f` | **현재 프레임 월드 4×4**(행 4개 × 16B, 행3 = 평행이동) | 마스터 갱신이 여기 쓴다 `0x14022e80a`–`0x14022e829` · `0x14022a0c4`–`0x14022a0dd` |
| `+0x30/+0x34/+0x38` | 그 4×4 의 **위치**(= CP 월드 좌표) | `Matrix::row(3)` `0x140255cf0`(`rax = rcx + idx*16`, `idx<4` 어서트 `0x140255d00`) |
| `+0x40..+0x7f` | **직전 프레임** 4×4 사본 | 프레임 끝 복사 루프 `0x1402377a0`–`0x1402377d9`(그리고 `0x14022f250`–`0x14022f28c`) |
| `+0x80..+0xbf` | **base(저작) 4×4** — `offset` 이 행3, `angles` 가 3×3 | ctor `0x14022ce42`–`0x14022ce82` · 오버라이드 `0x14022bfcd`–`0x14022c0af` |
| `+0xc0` | `flags` | `0x14022e461` `mov edx,[rsi+rdi+0xc0]` |
| `+0xc4` | `parentcontrolpoint` | `0x14022e684` `mov eax,[rsi+rdi+0xc4]` |
| `+0xc8..+0xcf` | (관측된 접근 없음 — 패딩) | — |

**[확정] `+0x40` 이 "직전 프레임" 인 이유**는 프레임 안의 호출 순서다(§3). 그리고 그것을 읽는
유일한 소비자가 이니셜라이저 opid 8 `inheritcontrolpointvelocity` 다:

```
0x14023bc36  mov edx, 3
0x14023bc3b  imul rbx, rax, 0xd0        ; rax = [r14+0xc] = controlpoint
0x14023bc42  add rbx, [rdi+0x400]
0x14023bc4c  call 0x140255cf0           ; row3( CP + 0x00 )  = 현재 위치
0x14023bc51  lea rcx, [rbx+0x40]
0x14023bc63  call 0x140255cf0           ; row3( CP + 0x40 )  = 직전 위치
0x14023bc80  subps xmm6, xmm0           ; Δ = 현재 − 직전
0x14023bc78  movss xmm3, [rdx+0x150]    ; dt
0x14023bc8e  divps xmm6, xmm2           ; v = Δ / dt
```
그 뒤 `min/max`(`[r14+4]`,`[r14+8]`) 로 스케일해 파티클 속도 `+0x2c8/+0x2d0/+0x2d8` 에
**더한다**(`0x14023bd58`–`0x14023bd99`).
**[확정]** 그러니 CP 를 애니메이션으로 흔들면 그 속도가 스폰 파티클에 상속된다.
**[확정]** 시스템 flags bit0(`0x14023bc68 test byte [rdi+0x20],1`)이 서고 그 CP 의 `flags & 2` 가
**서지 않았을 때만** 오브젝트 변환 보정(`0x14023bcce` `0x14005f0d0` → `0x14023bce4` `0x14019d470`)이
걸린다(`0x14023bc9c test byte [rbx+0xc0], 2` → 참이면 건너뜀). 속도 상속 자체는 언제나 일어난다.

---

## 2. 값이 CP 레코드에 들어오는 경로 네 가지

### 2.1 파티클 `.json` 의 `controlpoint[]` (정적) — ctor `0x14022c3c0`

**[확정]** 시스템 생성자가 `[sys+0x44]` 개의 레코드를 `0xd0` 씩 잡고(`0x14022cd95`
`imul rcx, rax, 0xd0` → `0x14022cda1` 재할당) 다음을 채운다:

```
0x14022cdf4..0x14022ce2d   +0x40..+0x7f = 항등행렬 (0x3f800000 대각 4개)
0x14022ce36..0x14022ce68   +0x80/+0x90/+0xa0 ← 항등행렬 3행
0x14022cdec  eax = [sys + i*0x20 + 0xc0]  → 0x14022ce4b  +0xc4 = parentcontrolpoint
0x14022cddc  eax = [sys + i*0x20 + 0xbc]  → 0x14022cde4  +0xc0 = flags
0x14022cea9/0x14022ceb9/0x14022cec9 : [sys + i*0x20 + 0xc4/0xc8/0xcc] → +0xb0/+0xb4/+0xb8
0x14022ced9..0x14022cf4a   +0x80..0xbf → +0x40..0x7f → +0x00..0x3f
```

**[확정] 이 경로는 `angles` 를 쓰지 않는다.** `+0x80/+0x90/+0xa0` 에 항등행렬을 넣고
`+0xb0..+0xb8` 에만 `offset` 을 넣는다. 디스크립터 슬롯(스트라이드 **0x20**)에서 읽는 것은
`+0xbc`(flags) · `+0xc0`(parentcontrolpoint) · `+0xc4..+0xcf`(offset) 셋뿐이다.
**[확정, 2026-08-21 재확인]** 파티클 `.json` 의 `controlpoint[].angles` 는 디스크립터
`+0xd0+32i` 에 **실제로 파스된다** — 파서의 고정 8회 루프(`0x1401d0530`–`0x1401d080e`,
슬롯 `shl rdi,5`@`0x1401d0593`)가 `flags`→`+0xa4`(`0x1401d05ae`) · `offset`→`+0xac/+0xb0/+0xb4`
(`0x1401d06ac`/`0x1401d06bc`) · **`angles`→`+0xb8/+0xbc/+0xc0`**(키 `lea`@`0x1401d06ce`,
스토어 `0x1401d07c9`/`0x1401d07d9`) · `parentcontrolpoint`→`+0xa8`(`0x1401d07ff`) 를 쓴다.
파서 베이스는 생성자 베이스보다 `0x18` 작을 뿐(파서 `flags` `+0xa4` ↔ 생성자 `+0xbc`)
**슬롯 내 상대 배치는 동일**하다 — `flags`+0 / `parent`+4 / `offset`+8..+0x10 /
`angles`+0x14..+0x1c, 합 `0x20` = 스트라이드. `angles` 만 주입기가 없다(부재 시
`find` 가 널 노드를 주고 그대로 건너뛴다 — `cmp byte [rax+8],4`@`0x1401d06da`).
**그런데 이 생성자가 그 자리를 읽지 않는다.**
**[미해결]** 다른 곳에서 그 12바이트를 읽는 지점은 못 찾았다 — 즉 파티클 `.json` 쪽 `angles` 는
**실효 0** 일 가능성이 높지만 전수 반증은 못 했다. (씬 쪽 `controlpointangleN` 은 §2.2 로
**확실히 살아 있다** — 그쪽은 다른 함수가 `+0x80..0xaf` 를 직접 쓴다.)

> **[해소 2026-08-21 · 레인 BJ — 부분]** 그물을 좁혔다(전수 반증은 여전히 못 했다).
> ① **생성자를 다시 떠서 재확인했다.** `0x14022c3c0`–`0x14022cf93` 의 CP 루프
> (`0x14022cdc0`–`0x14022cf55`)가 디스크립터에서 읽는 명령은 **다섯 개뿐**이다 —
> `+0xbc`(`0x14022cddc`) · `+0xc0`(`0x14022cdec`) · `+0xc4/0xc8/0xcc`
> (`0x14022cea9`/`0x14022ceb9`/`0x14022cec9`). `angles` 자리(생성자 공간 `+0xd0+32i`)는 없다.
> ② **디스크립터를 읽으려면 스트라이드 `0x20` 인덱싱이 필요하다.** 이미지 전체를 바이트로
> 훑어 `REX.W shl reg, 5`(`48/49 C1 E0..E7 05`) **424자리 / 139함수**, `imul reg, reg, 0x20`
> **0자리**를 뽑았고, 그중 CP 디스크립터 베이스를 쓰는 함수는 **셋뿐**이다 —
> 파서(`0x1401d0593` · `0x1401d0868`)와 생성자(`0x14022cdd8`). 파서의 두 번째 자리는
> `angles` 가 아니라 **bit16 표시**다(§12.3).
> ③ **남은 구멍**: 8슬롯을 언롤한 상수 오프셋 접근(`[X+0xd0]`, `[X+0xf0]`, …)은 이 그물에
> 안 걸린다. 그래서 `[미해결]` 을 지우지 않는다.
> ④ **정정**: 위 본문은 생성자가 `+0x80/+0x90/+0xa0` **세 행**에 항등을 넣는다고 적었는데,
> 실제로는 **네 행**이다 — `0x14022ce42`(+0x80) · `0x14022ce59`(+0x90) · `0x14022ce68`(+0xa0) ·
> `0x14022ce82`(**+0xb0**). 그래서 base 의 `+0xbc` 는 항등에서 온 `1.0` 이다.

### 2.2 씬 `instanceoverride.controlpointN` / `controlpointangleN` — `0x14022bd40`

**[확정] 등록부.** 정적 초기화자 `0x14024d940`–`0x14024e96e` 가 **24개** 프로퍼티를
씬 파티클 오브젝트의 프로퍼티백(`obj+0x778`)에 등록한다. 항목 경계는 이름 대입
`call 0x14000f880` 기준으로 잘라야 한다(**함정 16** — 다음 항목 이름의 `lea` 가 현재 항목
스토어 사이에 낀다: 예로 `lea "controlpointangle0"` @`0x14024e08e` 는 `controlpoint0` 의
`[rbx+0x34]=0xf0` 저장 **앞**에 있다).

| 이름 | 타입(`+0x30`) | 오프셋(`+0x34`) | 이름 대입 VA |
| --- | ---: | --- | --- |
| `alpha` `size` `count` `speed` `lifetime` `brightness` `rate` | 4(f32) | `0xc8` `0xcc` `0xd0` `0xd4` `0xd8` `0xe0` `0xdc` | `0x14024d9fc` … `0x14024de3f` |
| `colorn` | 2(vec3) | `0xe4` | `0x14024def1` |
| `controlpoint0..7` | 2(vec3) | `0xf0 + 12·i` | `0x14024dfc7` `0x14024e15e` `0x14024e2c9` `0x14024e410` `0x14024e533` `0x14024e656` `0x14024e779` `0x14024e89c` |
| `controlpointangle0..7` | 2(vec3) | `0x150 + 12·i` | `0x14024e09f` `0x14024e20a` `0x14024e375` `0x14024e498` `0x14024e5bb` `0x14024e6de` `0x14024e801` `0x14024e924` |

**[확정] 미지정 센티널.** 프로퍼티백 생성자 `0x14024d760`–`0x14024d8c6` 가 16개 vec3 슬롯의
**`.x` 만** `0x7f7fffff`(FLT_MAX)로 깐다(`0x14024d813`–`0x14024d8a9`, 16개 스토어 전수 확인).
스칼라 7개는 `1.0`(`0x14024d7a2`–`0x14024d7e4`), `colorn` 은 `−1.0` 셋(`0x14024d7ee`–`0x14024d802`)이다.
즉 **위치와 각도는 서로 독립으로 "지정 안 됨" 을 표현한다.**

**[확정] CP 레코드로의 반영** — `0x14022bd40`–`0x14022c30a`. `r13 = [sys+8]`(씬 오브젝트),
프로퍼티백은 `r13+0x778`(`0x14022be45 lea r8,[r13+0x778]`). CP 인덱스 `r15d`, `rbp = 3·r15`:

```
0x14022bf26  test dword [rdi + rbx + 0xc0], 0x10005 ; jne 0x14022c17d   ← CP 통째로 건너뜀
0x14022bf3d  movss xmm11, [r13 + rbp*4 + 0x8c8]   ; angles.x  (= 백+0x150 + 12i)
0x14022bf47  ucomiss xmm11, xmm12(FLT_MAX) ; je 0x14022c073             ← 각도 미지정
   cos/sin ×3 (0x14041a2e0 / 0x14041a9c0) →
0x14022bfcd/0x14022bff6/0x14022bfff   CP +0x80/+0x84/+0x88
0x14022c00b/0x14022c031/0x14022c03a   CP +0x90/+0x94/+0x98
0x14022c057/0x14022c060/0x14022c069   CP +0xa0/+0xa4/+0xa8
0x14022c073  movss xmm0, [r13 + rbp*4 + 0x868]    ; pos.x    (= 백+0xf0 + 12i)
0x14022c07d  ucomiss xmm0, FLT_MAX ; je …                                  ← 위치 미지정
0x14022c08f/0x14022c098/0x14022c0a7   CP +0xb0/+0xb4/+0xb8
0x14022c0b6..0x14022c17d              +0x80..0xbf → (오브젝트 변환 합성) → +0x00..0x3f
```

**[확정] 절대 대체다.** 파티클 `.json` 의 `offset`/`angles` 가 만든 base 를 **덮어쓴다**
(합산 아님 — 위 스토어들이 전부 `movss`/`mov`).
**[확정] 게이트 `0x10005`**(bit0 마우스 · bit2 부모부착 · bit16 remap출력)에 걸리는 CP 는
위치도 각도도 통째로 건너뛴다.
**[확정] 각도만/위치만 지정도 가능하다** — 두 센티널 검사가 독립이고, 각도만 지정되면
`cl=1` 이 서서 위치 검사를 통과한 뒤 재합성으로 간다(`0x14022c085 test cl,cl`).

**[확정] 회전식은 오브젝트 `angles` 와 완전히 같다** — 세 각을 각각 `cosf`(`0x14041a2e0`) ·
`sinf`(`0x14041a9c0`) 로 풀어 `Rz·Ry·Rx` 를 만든다(라디안, 파일 순서 `(x,y,z)`).

### 2.3 마스터 CP 갱신 `0x14022e3e0`–`0x14022ebde` — 매 프레임 `+0x00` 재계산

CP 개수만큼(`[sys+0x44]`) 돌면서 `flags`(`+0xc0`)로 갈라진다:

| 게이트 | VA | 하는 일 |
| --- | --- | --- |
| `bt edx,0x10`(bit16) | `0x14022e468` | **아무것도 안 한다**(remap 출력 CP — 오퍼레이터가 직접 쓴다) |
| `test dl,1`(bit0) | `0x14022e472` | `+0x80..0xbf` → `+0x00..0x3f` 복사 후 `+0x30/+0x34/+0x38` 을 **마우스 광선 교차점**으로 덮는다(`0x14022e656`–`0x14022e662`) |
| `test dl,4`(bit2) | `0x14022e66e` | 부모 시스템(`[sys+0x10]`)의 current CP `[parent+0x400] + [CP+0xc4]*0xd0` 에 부착. `[parent+0x44]` 로 경계검사(`0x14022e68b`). `(부모·자식 모두 world) || bit3`이면 부모 4×4를 그대로 복사한다. 나머지는 자식 base가 아니라 transform-stack 공간 bridge를 곱한다: child-world/parent-local=`P×Tp`, child-local/parent-world=`P×inverse(Tc)`, 둘 다 local=`P×Tp×inverse(Tc)` (`0x14022e6ee`–`0x14022eb26`). |
| 그 외 | `0x14022eb2d` | `test edx, 0x10005` 로 다시 걸러낸 뒤 `0x14022a070` 호출 |

**[확정] 기본 경로 `0x14022a070`** 은 `[sys+0x20] & 1` (시스템 flags bit0)일 때만
`0x14024f0e0`(4×4 곱)로 **base × 오브젝트 변환** 을 만들어 `+0x00..0x3f` 에 넣는다
(`0x14022a0bc`–`0x14022a0dd`). 아니면 CP `flags&2` 여부에 따라 갱신을 아예 생략한다
(`0x14022a0ea` → `al=0` 반환).

**[확정] 자식 CP 피드 게이트도 여기에 있다**:
```
0x14022eb35  test byte [r14+0x3f6], 1        ; 자식 CP 피드가 켜졌는가
0x14022eb3d  je 0x14022eb4c                  ; 아니면 그냥 기본 갱신
0x14022eb3f  movzx eax, byte [r14+0x3f5]     ; controlpointstartindex
0x14022eb47  cmp r12d, eax ; jae 0x14022eb5e ; idx >= start 면 **기본 갱신을 건너뛴다**
```
즉 `startIndex` 이상의 CP 슬롯은 엔진이 안 만지고 **부모 파티클이 채운다**(§6).

### 2.4 부모 파티클 → 자식 CP (§6)

---

## 3. 프레임 안의 순서 — 왜 `+0x40` 이 "직전" 인가

**[확정]** 시뮬 스텝 `0x140236cd0`–`0x140237894` 의 꼬리가 정확히 이 순서다:

```
0x1402376fe  call 0x14022e3e0    ; ① CP 월드 4×4(+0x00..0x3f) 를 이번 프레임 값으로 갱신
0x14023771b  call 0x1402378a0    ; ② 이미터 VM → 스폰 → 이니셜라이저 VM(0x14023b340)
0x140237784  call 0x14023fbc0    ; ③ 오퍼레이터 VM (드래그 서브스텝 — 조건부 반스텝)
0x140237793  call 0x14023fbc0    ; ④ 오퍼레이터 VM (본스텝)
0x1402377a0..0x1402377d9         ; ⑤ +0x00..0x3f  →  +0x40..0x7f  (다음 프레임의 "직전")
```
①과 ⑤ 사이에서 ②③④가 돌기 때문에, 그 구간 동안 `+0x00` = 이번 프레임, `+0x40` = 지난 프레임이다.
같은 ①⑤ 쌍이 자식/인스턴스 경로 `0x14022ebe0` 에도 있다(`0x14022f243` 호출 + `0x14022f250` 복사 루프).

---

## 4. 소비처 전수

### 4.1 오퍼레이터 VM — **위치만** [확정]

CP 를 만지는 오퍼레이터는 `controlpointattract`(10) · `maintaindistancetocontrolpoint`(11) ·
`maintaindistancebetweencontrolpoints`(12) · `reducemovementnearcontrolpoint`(13) ·
`vortex`(15) · `vortex_v2`(16) · `remapvalue`(19) · `collisionsphere`(22) · `collisionquad`(25)
와 그 페이드창 변종이다.

패턴은 언제나 **두 단계**다:
1. `0x14024f2d0` 으로 CP 레코드 **`+0x00..+0x3f`(정확히 0x40바이트, dword 16개)** 를
   스택 스크래치에 통째로 복사한다. 호출 46곳.
2. `0x14022a120` 으로 그 스냅샷의 `+0x30/+0x34/+0x38` 만 뽑아 vec4 셋으로 브로드캐스트한다.
   호출 44곳. (나머지 둘은 `0x14022a150` — 이쪽도 `[r9+0x30/0x34/0x38]` **셋만** 읽는다.)

**[확정] 오퍼레이터 VM 안에서 회전 3행은 한 번도 읽히지 않는다.** VM 전문(`0x14023fbc0`–`0x14024be38`)에서
스냅샷 버퍼 40개(`[rbp+0x12e0]` … `[rbp+0x1e20]`)를 참조하는 명령은 **버퍼당 정확히 2개**
(복사용 `lea rcx` 와 `0x14022a120` 인자용 `lea rcx`)뿐이다. 스냅샷이 4×4 전체를 뜨는 것은
**호출 규약의 잔재**이고, 실제 소비는 평행이동뿐이다.

> 종전 `particle-operator-vm.md` §7 의 "`0x14024f2d0` = 컨트롤포인트 스냅샷 **44바이트** 복사"
> 는 오기였다. **0x40 = 64바이트**다 — 함수는 `0x14024f2d0`–`0x14024f331`(`ret`)이고
> `mov eax,[rdx+N]`/`mov [rcx+N],eax` 를 N = `0x00`..`0x3c` 로 **dword 16회** 돈다
> (마지막 쌍 `0x14024f328`/`0x14024f32b`, 반환 `mov rax,rcx` @`0x14024f32e`).
> `.pdata` 항목이 없는 리프라 `primary()`/`merged()` 가 `None` 을 준다 — 호출 대상 주소가
> 곧 명령 경계라 거기서 선형으로 떴다. 값에는 영향이 없다.
> **[2026-08-21] 그 문서에서 실제로 정정됐다**(§7 에 근거 블록 추가).

### 4.2 이니셜라이저 VM — opid 8·13·14·15 [확정]

이니셜라이저 스트림은 정의 `+0x68`, 레코드는 `[+0x00] opcode / [+0x02] size / 페이로드 +0x04`
(오퍼레이터와 달리 페이로드가 `+4` 다). 디스패치는
`0x14023b5c0 movzx eax, byte [r14]` → `dec eax` → `mov eax,[rbx + rcx*4 + 0x23fa78]`(테이블
**`0x14023fa78`**) → `add rax,rbx` / `jmp rax` (`0x14023b5c9`–`0x14023b5d3`).

**opid ↔ 이름 ↔ 핸들러 (16개 — 할당기 썽크 전수 대조)**

| opid | 이름 | 썽크 | 레코드 크기 | 핸들러 |
| ---: | --- | --- | ---: | --- |
| 1 | `lifetimerandom` | `0x1401d84e0` | `0x10` | `0x14023b5d5` |
| 2 | `sizerandom` | `0x1401d8500` | `0x10` | `0x14023b63c` |
| 3 | `colorrandom` | `0x1401d8520` | `0x20` | `0x14023b6a1` |
| 4 | `hsvcolorrandom` | `0x1401d8560` | `0x20` | `0x14023b74a` |
| 5 | `colorlist` | `0x1401d85a0` | `0x34` | `0x14023b86b` |
| 6 | `alpharandom` | `0x1401d87c0` | `0x10` | `0x14023ba6f` |
| 7 | `velocityrandom` | `0x1401d87e0` | `0x20` | `0x14023bac6` |
| **8** | **`inheritcontrolpointvelocity`** | `0x1401d8820` | `0x10` | **`0x14023bc32`** |
| 9 | `turbulentvelocityrandom` | `0x1401d8840` | `0x64` | `0x14023bdbc` |
| 10 | `rotationrandom` | `0x1401d8860` | `0x20` | `0x14023bf55` |
| 11 | `positionoffsetrandom` | `0x1401d8880` | `0x30` | `0x14023c09a` |
| 12 | `angularvelocityrandom` | `0x1401d88d0` | `0x20` | `0x14023c3a6` |
| **13** | **`mapsequencearoundcontrolpoint`** | `0x1401d88f0` | `0x5c` | **`0x14023c4cf`** |
| **14** | **`mapsequencebetweencontrolpoints`** | `0x1401d8930` | `0x38` | **`0x14023ca93`** |
| **15** | **`remapinitialvalue`** | `0x1401d8970` | `0x68` | **`0x14023ce53`** |
| 16 | `inheritinitialvaluefromevent` | `0x1401d8990` | `0x08` | `0x14023f445` |

테이블 17번 이후(`0x14023ce8b` …)는 **`remapinitialvalue` 안쪽 서브스위치**의 것이다 —
opid 공간이 아니다(파서가 초기화 스트림 `[rsp+0x48]` 에 대해 부르는 썽크가 정확히 16개이고,
17번 엔트리 `0x14023ce8b` 이 15번 핸들러 본문 안에 들어 있다).
**오퍼레이터 27번 같은 구멍은 여기엔 없다** — 1..16 이 빈틈없이 다 있다.
(위 16개는 파서 `0x1401c5490`–`0x1401d152c` 안의 `call 0x1401d8xxx` 를 **전수로** 뽑아
직전 `lea rcx,[rsp+0x48]` 로 스트림을 귀속시켜 얻었다. 썽크를 바이트 패턴으로만 훑으면
`0x1401d8860`(opid 10)을 놓친다 — 실제로 한 번 놓쳤다.)

**[확정] opid 13 은 CP 의 3×3 회전을 실제로 쓴다** — CP 소비처 중 유일하다:
```
0x14023c501  imul rbx, rax, 0xd0            ; rax = [r14+0x54] = controlpoint
0x14023c524  call 0x14024f2d0               ; CP +0x00..0x3f → [rbp+0x568]
0x14023c537  call 0x1400dd7d0               ; 4×4(stride 0x10) → 3×3(stride 0xc) → [rbp+0x330]
0x14023c544  call 0x140255cf0 (edx=3)       ; CP 위치
0x14023c577  call 0x140184440([rbp-0x30], [rbp+0x330], [r14+0x2c])   ; 기저벡터 ①×CP회전
0x14023c58e  call 0x140184440([rbp+0xd8],  [rbp+0x330], [r14+0x38])  ; ②
0x14023c5a5  call 0x140184440([rbp+0xe8],  [rbp+0x330], [r14+0x44])  ; ③
```
`0x140184440(out, mat3, v)` 은 `out = v · M`(3×3, stride 0xc)다.
**[확정] 그러므로 `controlpointangleN` 은 `mapsequencearoundcontrolpoint` 를 쓰는 시스템에서
회전 평면을 실제로 돌린다.** 이것이 "CP 각도의 소비처" 다.

### 4.3 이미터 VM — **4×4 전체** [확정]

`0x1402378a0`–`0x14023b33d` 안 두 자리가 CP 를 읽는다. 둘 다 **행 0·1·2(회전 3×3)와 행 3(위치)을 모두 읽는다** — arm A 는 행0 의 w 성분(`+0x0c`)까지, arm B 는 xyz 만:

```
; arm A  (0x140237c18  cmp al,1 → 이 가지)
0x140237c27  mov edx, [r15+0xf0]            ; CP 인덱스
0x140237c33  imul rcx, rdx, 0xd0
0x140237c42  movups xmm11, [rax+rcx+0x10]   ; 행1
0x140237c48  movups xmm14, [rax+rcx+0x20]   ; 행2
0x140237c54  movdqu xmm0,  [rax+rcx+0x30]   ; 행3(위치)
0x140237c5a/0x140237c5f/0x140237c4e/0x140237c86 : +0x00/+0x04/+0x08/+0x0c  ; 행0
0x140237c65  addps xmm0, [r15+0x70]         ; 위치 += 이미터 origin

; arm B  (0x14023847f 이후)
0x14023848e  mov edx, [r15+0xa8]            ; CP 인덱스
0x1402384af  imul rcx, rdx, 0xd0
0x1402384c8/0x1402384cd : 행1·행2 ; 0x1402384c2/0x1402384d2/0x1402384ea : 행3 + origin
0x140238502/0x1402384f6/0x1402384d8 : 행0
```
**[확정] 이미터에 `controlpoint` 를 붙이면 방출 형상의 원점뿐 아니라 방향 기저까지 CP 프레임을 따른다.**
파스 측은 `controlpoint` 를 `asUInt`(`0x140085f70`) 후 **7 로 클램프**해
`sphererandom` → `[rsi+0xe0]`(`0x1401c600d`), `boxrandom` → `[rsi+0x98]`(`0x1401c6915`) 에 넣는다.
**[추정]** 런타임 오프셋(`+0xf0`/`+0xa8`)이 파스 오프셋보다 정확히 `0x10` 큰 것은 이미터 레코드에
`0x10` 헤더가 붙기 때문으로 보이지만, 복사 지점을 직접 짚지는 않았다.

> **[구현 2026-08-31]** `ParticleSystemDef.emitterControlPoints`가 두 파서 값을 CP0 기본·unsigned
> 7-clamp로 보존하고, `ParticleSimulator.spawn`이 sphere/box 로컬 변위와 초기속도 방향에 active
> CP 3×3을 적용한다. row3와 emitter origin은 위치에만 후가산한다. 공개 parse→step 오라클과
> 동봉 dripping-water **6 선언 / 4 물리 파일 / 2 고유 바이트** 도달 테스트는
> [`particle-emitter-controlpoint-binary-2026-08-31.md`](particle-emitter-controlpoint-binary-2026-08-31.md)가 정본이다.

### 4.4 `remapinitialvalue`(15)·`remapvalue`(19)

**[확정]** 둘 다 `inputcontrolpoint0/1`·`outputcontrolpoint0/1` 로 CP 를 읽는다
(15: `0x14023cfa0`·`0x14023d0b9`·`0x14023d0c4`·`0x14023d326`·`0x14023d3b8`·`0x14023d47c`·
`0x14023deb4`·`0x14023e02b`·`0x14023e036`·`0x14023eacd`·`0x14023edcd`·`0x14023f0ec` 의 `imul …,0xd0`).
19 는 `docs/re/particle-operator-vm.md` §6 opid 19 참조. **위치만** 읽는다(§4.1 의 전수 결과에 포함).

---

## 5. `mapsequencebetweencontrolpoints` 전문 [확정]

### 5.1 파스 — `0x1401ca1cf`–`0x1401ca6bd`

게이트 `stricmp` vs `0x14048fe20` @`0x1401ca1e1` → 할당기 `0x1401d8930`(opcode **0x0e**,
레코드 `0x38`, 페이로드 `0x34`) @`0x1401ca205` → 기본값 주입기 `0x1401bc080`–`0x1401bc419` @`0x1401ca214`.

**페이로드 레이아웃**(핸들러의 `[r14+X]` = 페이로드 `+(X−4)`):

| 페이로드 | 내용 | 파스 VA | 핸들러 VA |
| --- | --- | --- | --- |
| `+0x00` | **스텝** `1.0 / (count − 1.0)`, 분모 하한 `1e-4` | `0x1401ca29d`(`divss`) → `0x1401ca2af` | `[r14+4]` `0x14023cda2` |
| `+0x04` | **시퀀스 누산기 t**(레코드에 남는 상태, 초기 0) | `0x1401ca296` | `[r14+8]` `0x14023cc0f` |
| `+0x08` | `bounds[0]` | `0x1401ca367` | `[r14+0xc]` `0x14023cc34` |
| `+0x0c` | `bounds[1] − bounds[0]` | `0x1401ca383` | `[r14+0x10]` `0x14023cc25` |
| `+0x10` | `limitbehavior == "mirror"` (0/1) | `0x1401ca3ca` | `[r14+0x14]` `0x14023cdc6` |
| `+0x14` | `controlpointstart` (≤7 클램프) | `0x1401ca449` | `[r14+0x18]` `0x14023cadb` |
| `+0x18` | `controlpointend` (≤7 클램프) | `0x1401ca456` | `[r14+0x1c]` `0x14023cac1` |
| `+0x1c` | `flags` | `0x1401ca489` | `[r14+0x20]` `0x14023cc4b` |
| `+0x20` | `arcamount` | `0x1401ca4bc` | `[r14+0x24]` `0x14023ccd5` |
| `+0x24..+0x2c` | `arcdirection` (x,y,z) | `0x1401ca5d0`·`0x1401ca5e2` | `[r14+0x28]` `0x14023ccc5` |
| `+0x30` | `sizereductionamount` | `0x1401ca607` | `[r14+0x34]` `0x14023cd75` |

클램프는 `0x1401ca435`–`0x1401ca456`(`mov edx,7` / `cmp` / `cmovb` — **부호 없는** 비교라
음수는 7 이 된다). 파스 꼬리 `0x1401ca60c`–`0x1401ca628` 이 정의의 CP 개수
(`[def+0x2c]`)를 `max(현재, start+1, end+1)` 로 밀어 올린다.

**주입 기본값**(주입기 `0x1401bc080`, 전부 직접 확인):

| 키 | 기본 | VA |
| --- | --- | --- |
| `count` | **32** (`mov qword [rax], 0x20`) | `0x1401bc0db` |
| `bounds` | **`"0 1"`** (문자열, `0x14048f734`) | `0x1401bc1d0`–`0x1401bc1ee` |
| `limitbehavior` | **`"repeat"`** (`0x14048f6f8`) | `0x1401bc2b0`–`0x1401bc2ce` |
| `controlpointstart` | **0** (int 노드 직접 조립) | `0x1401bc35e`–`0x1401bc39f` |
| `controlpointend` | **1** (`mov r8d,1` → `H_INT`) | `0x1401bc3a4` / `0x1401bc3b4` |
| `flags` | **0** (`xor r8d,r8d` → `H_INT`) | `0x1401bc3b9` / `0x1401bc3c6` |
| `arcamount` | **0.3** (`0x140492694`) | `0x1401bc3cb` / `0x1401bc3dd` |
| `arcdirection` | **`"0 1 0"`** (`0x14048f6d0`) | `0x1401bc3e2` / `0x1401bc3f3` |
| `sizereductionamount` | **0.9** (`0x1404926e8`) | `0x1401bc3f8` / `0x1401bc40a` |

> **함정 16 실사례.** `lea "controlpointend"` @`0x1401bc3aa` 는 `mov r8d,1` @`0x1401bc3a4` 와
> `call H_INT` @`0x1401bc3b4` **사이**에 있고, 그 다음 `xor r8d,r8d` @`0x1401bc3b9` 가
> `flags` 의 기본을 **0** 으로 만든다. 인접 `lea` 로 귀속하면 `flags` 기본을 1 로 잘못 읽는다.

### 5.2 런타임 — `0x14023ca93`–`0x14023ce53`

`rdi` = 시스템, `r12d` = 파티클 인덱스, `r14` = 레코드.

```
p   = (pos.x, pos.y, pos.z)                                  ; [rdi+0x2b0/0x2b8/0x2c0]
A   = row3( CP[controlpointstart] )                          ; 0x14023caf1
B   = row3( CP[controlpointend]   )                          ; 0x14023cb1b
Δ   = B − A                                                  ; 0x14023cb32–0x14023cb4b
L   = |Δ|                                                    ; 0x14023cb50  (0x14019e890 = length)
Ls  = max(L, FLT_MIN)                                        ; 0x14023cb5d  (0x1404925d0)
d   = Δ / Ls                                                 ; 0x14023cb78–0x14023cb93
if ([rdi+0x20] & 1)  p -= A                                  ; 0x14023cb55 / 0x14023cba3
perp = p − (p·d)·d                                           ; 0x14023cbdf–0x14023cc2f
s    = bounds0 + t·span                                      ; 0x14023cc25 + 0x14023cc34
arc  = 1 − powf(|2t − 1|, 2)                                 ; 0x14023cc46 (powf) / 0x14023cc53
if (flags & 1)  perp *= arc                                  ; 0x14023cc58–0x14023cc66
p'   = perp + A + s·Ls·d                                     ; 0x14023cc6b–0x14023cca7
if (flags & 8)  p' += arcdirection · (arc · Ls · arcamount)   ; 0x14023ccbd–0x14023cce7
pos  = p'                                                    ; 0x14023ccf8/0x14023cd0a/0x14023cd1c
if (flags & 2)  vel *= arc                                   ; 0x14023cd22–0x14023cd68
if (flags & 4)  size *= (1 − sr) + sr·arc                     ; 0x14023cd6e–0x14023cd9c  ([rdi+0x278])
; --- 시퀀스 진행 ---
t += step                                                    ; 0x14023cda2–0x14023cdbe
if (t > 1):  mirror==0 → t = 0                               ; 0x14023cdcc–0x14023cdd0
             mirror==1 → step = −step ; t = 1 − (t − 1)      ; 0x14023cddb–0x14023cdef
if (t < 0):  step = −step ; t = −t                           ; 0x14023ce13–0x14023ce48
```

**[확정] 핵심 다섯 가지**

1. **이건 위치 이니셜라이저다.** 스폰된 파티클을 `CP[start] → CP[end]` 선분 위
   매개변수 `s` 자리로 **옮긴다**. 그리고 파티클의 축 수직 성분(`perp`)은 보존한다.
2. **`t` 는 스폰 순서 카운터다.** 레코드 안(`+0x04`)에 남아 파티클 하나 스폰마다
   `1/(count−1)` 씩 전진한다. 파티클 위치에서 유도하는 값이 **아니다**.
3. **`limitbehavior`** 는 그 카운터의 경계 동작이다 — `repeat`(기본) = 0 으로 되감기,
   `mirror` = 스텝 부호 반전 왕복.
4. **`arcamount` 는 시퀀스를 휘게 한다.** 세기는 `arcamount · |B−A| · (1 − (2t−1)²)` —
   중앙(t=0.5)에서 최대, 양 끝에서 0. 방향은 `arcdirection`(기본 `(0,1,0)`).
   **`flags & 8` 이 서야 적용된다** — 기본 `flags` 가 0 이므로 **기본은 꺼져 있다**.
5. **`sizereductionamount` 는 끝에서 크기를 줄인다** — `size *= (1−sr) + sr·arc`.
   `sr = 0.9` 기본이면 양 끝에서 원래 크기의 10%. **`flags & 4` 게이트**.
   `[rdi+0x278]` 은 **기준 size** 라 매 프레임 되돌아오지 않고 유지된다.

**[확정] 이 핸들러가 만지는 SoA 슬롯은 전부다**: `+0x2b0/+0x2b8/+0x2c0`(위치) ·
`+0x2c8/+0x2d0/+0x2d8`(속도) · `+0x278`(기준 size) · `+0x20`(시스템 flags 판독) · `+0x400`(CP).
**스프라이트 시퀀스 슬롯 `+0x268` 은 건드리지 않는다.** (`+0x268` 이 시퀀스 슬롯인 근거:
이니셜라이저 프롤로그 `0x14023b4e9`–`0x14023b50e` 가 `[sys+0x48]`([추정] animationmode) 이 0 이면 0 을,
아니면 파티클 난수 `[sys+0x338]` 값을 그대로 넣고, `remapinitialvalue` 의 출력 arm
`0x14023ce8b` 이 여기 쓴다.)
`mapsequencearoundcontrolpoint`(13) 도 마찬가지로 `+0x2b0..+0x2d8` 만 만진다(전수 확인).

**[미해결]** `[rdi+0x20] & 1` 이 설 때만 `p −= A` 를 하는 이유(월드/로컬 스페이스 구분으로
보이나, 안 설 때 수직 성분이 **원점을 지나는 축** 기준이 되는 것이 의도인지 확인 못 했다).

`mirror` 판정이 `cmp dword [r14+0x14], r13d`(`0x14023cdc6`)인데 **`r13d` 는 0** 이다 —
이니셜라이저 VM 프롤로그의 `xor r13d, r13d`(`0x14023b37e`). 즉 `jne` = "mirror != 0" 이다.
그리고 두 경계 검사의 `jbe`(`0x14023cdc4` · `0x14023ce34`)는 **비순서(NaN)에서도 잡힌다** —
`t` 가 NaN 이면 실물은 `t`/`step` 을 그대로 둔다(부호 반전 없음).

### 5.3 `mapsequencearoundcontrolpoint`(opid 13) — 페이로드와 런타임 산술 [해소 2026-08-31]

레코드 `0x5c` / 페이로드 `0x58`(썽크 `0x1401d88f0` — `mov byte [rdx],0xd` @`0x1401d88f7`,
`mov word [rdx+2],0x5c` @`0x1401d8901`). 파스 `0x1401c9930`–`0x1401ca1c2`, 게이트
`stricmp` vs `0x14048fe00` @`0x1401c993a`, 주입기 `0x1401bbc90`–`0x1401bc074` @`0x1401c9970`.
파스 베이스는 `rsi`(썽크가 `lea rax,[rdx+4]` 로 페이로드를 돌려준다), 핸들러 베이스는 `r14` = 페이로드 − 4.

| 페이로드 | 내용 | 파스 스토어 | 핸들러 로드 | 주입 기본 |
| --- | --- | --- | --- | --- |
| `+0x00` | 스텝 `1 / max(count, 1e-4)` — **`−1` 없음** | `0x1401c9a01` | — | `count` 32 (`0x1401bbceb`) |
| `+0x04` | 누산기 `t`(초기 0) | `0x1401c99e8` | `[r14+8]` `0x14023c9cd` | — |
| `+0x08` | `bounds[0]` | `0x1401c9ac9` | `[r14+0xc]` `0x14023c650` | `"0 1"` (`0x1401bbd93`) |
| `+0x0c` | `bounds[1] − bounds[0]` | `0x1401c9ae5` | `[r14+0x10]` `0x14023c63f` | — |
| `+0x10..+0x18` | **`speedmin` (vec3)** | `0x1401c9d82` / `0x1401c9d9b` | `[r14+0x14]` `0x14023c7d9` · `[r14+0x18]` `0x14023c7f9` · `[r14+0x1c]` `0x14023c7a0` | **`"0 0 0"`** (`0x1401bbeb3`, 상수 `0x14048f4d4`) |
| `+0x1c..+0x24` | **`speedmax−speedmin` span (vec3)** | raw max 뒤 `FUN_14005f0a0` @`0x1401c9d9e` | `[r14+0x20]` `0x14023c7d3` · `[r14+0x24]` `0x14023c7ef` · `[r14+0x28]` `0x14023c752` | raw max **`"0 0 0"`** (`0x1401bbf7b`) |
| `+0x28`/`+0x34`/`+0x40` | 기저벡터 셋(`axis` 에서 조립) | `0x1401c9ebb`/`0x1401c9ecd`/`0x1401c9ec3` → `0x1401c19e0` @`0x1401c9ed4` | `[r14+0x2c]`/`[r14+0x38]`/`[r14+0x44]` | `axis` **`"0 0 1"`** (`0x1401bbfc4`, 상수 `0x14048f6e0`) |
| `+0x4c` | `limitbehavior == "mirror"` | `0x1401c9b2c` | `[r14+0x50]` `0x14023c9df` | `"repeat"` (`0x1401bbfda`) |
| `+0x50` | `controlpoint`(≤7 클램프) | `0x1401c9b75` | `[r14+0x54]` `0x14023c4fd` | 0 (`0x1401bbff0`) |
| `+0x54` | (읽히지만 **파스가 안 쓴다** — 아래) | — | — | `flags` 0 (`0x1401bc002`) |

**[확정] `speedmin`/`speedmax` 는 살아 있다.** 핸들러가 min과 span 여섯 성분을 전부 읽고, 그 사이에
균일난수 `0x1401f87a0` 호출이 **정확히 셋**(`0x14023c74d` · `0x14023c7c7` · `0x14023c7ea`) 끼어
기저벡터 셋과 섞여 스폰 속도가 된다. 부재 기본이 `"0 0 0"` 이라 안 적으면 기여가 0 이다.
동봉·설치 저작 **2선언**(`presets/magic/.../magic_trinity.json` — `speedmin "0 10 0"` ·
`speedmax "0 100 0"`).

**[해소 2026-08-31] 위치·속도·상태식 전체를 opid 13에서 닫고 production에 옮겼다.**

```text
D = normalize(axis)                          // 정확한 영벡터만 (0,0,1) 대체
B = normalize(cross(D, Z))                   // D.x==0 && D.y==0 이면 (1,0,0)
C = cross(D, B)
(D, B, C) = 각 벡터 × CP의 현재 3×3          // 0x140184440, row-vector 규약

q      = position - CP
axial  = dot(q, D)
radius = length(q - axial*D)
theta  = 2π * (boundsMin + t*boundsSpan)
R      = cos(theta)*C + sin(theta)*B
T      = -sin(theta)*C + cos(theta)*B

position' = CP + axial*D + radius*R
velocity' = velocity
          + T*lerp(speedMin.x, speedMax.x, rx)
          + R*lerp(speedMin.y, speedMax.y, ry)
          + D*lerp(speedMin.z, speedMax.z, rz)
```

RNG 호출은 **rz → rx → ry** 순서이며 speed가 전부 0이어도 세 번을 소비한다. 누산기는
`t += step`; 위쪽 repeat는 `fmodf(t,1)`, mirror는 step 부호를 뒤집고 `1-(t-1)`로 반사한다.
아래쪽은 mirror와 무관하게 반사하고, NaN은 두 ordered 비교를 통과하지 않아 그대로 남는다.
정확한 1은 `>`가 아니므로 한 번 소비된다. Waple은 raw JSON max를 모델에 보존하므로 solver에서
`max-min`을 계산한다. `ParticleMapSequenceOracleTests` 41건이 원 궤도, raw min/max affine,
CP row-vector 회전, repeat/mirror/NaN, 무속도 3드로와 실제 spawn 배선을 잠근다.

**[미해결 — 신규] `around` 파스는 `flags` 를 한 번도 읽지 않는다.** 주입기는 `flags` 기본 0 을
DOM 에 심지만(`xor r8d,r8d` @`0x1401bc002` → `H_INT` @`0x1401bc00f`), `0x1401c9930`–`0x1401ca1c2`
어디에도 `"flags"`(`0x14048f4cc`) `lea` 가 없다(그 구간의 `lea rdx,[rip→0x14048…]` 전수:
mapsequencearoundcontrolpoint · count ×2 · bounds · limitbehavior · mirror · controlpoint ·
speedmin ×2 · speedmax ×2 · axis). 그런데 `0x1401ca184 test byte [rsi+0x54], 1` 이 그 자리를 읽어
두 번째 스트림 레코드를 찍을지 고른다(§5.4). **그래서 Waple 의 `MapSequenceAroundSpec` 에는
`flags` 를 싣지 않았다** — 읽히지 않는 값을 필드로 만들면 유령이 된다.

### 5.4 두 mapsequence 는 **이니셜라이저 스트림 밖에도** 레코드를 찍는다 [between bit4 확정 · around 남음]

**[2026-08-31 해소]** `[rsp+0x30]` 은 별도 레코드 VM의 팩토리 커서이고, 소비자는
`FUN_1401d15a0`(`0x1401d15a0`)이다. 이 절이 처음 기록한 `between flags` bit4 레코드는
**씬 `instanceoverride.count` 배율에 맞춰 opid 14 페이로드의 `step` 을 매 업데이트 다시 쓰는
동적 패치 레코드**다. 오퍼레이터 VM(`0x14023fbc0`)과는 정말 다른 계열이었지만, 효과가
미확정인 것은 아니게 됐다.

#### 5.4.1 팩토리 scratch와 opcode 4 레코드 [확정]

팩토리 시작 `0x1401c5b41`–`0x1401c5b70` 에서 scratch 원점
`B = qword[factoryContext+0x1450]` 를 잡고
`[rbp+0x70] = B`(두 번째 스트림 불변 base), `[rsp+0x30] = B`(그 스트림의 현재 cursor),
`[rsp+0x40] = B+0x4000`(이니셜라이저 스트림 불변 base)를 둔다. `[rsp+0x48]` 은 그
이니셜라이저 스트림의 현재 cursor다. `mapsequence*` 는 조건부로 두 번째 스트림에도 하나 찍는다:

```
; between — 0x1401ca62c
0x1401ca62c  test byte [r13+8], 0x20   ; jne → 안 찍음
0x1401ca637  test byte [rdi+0x1c], 0x10 ; je  → 안 찍음      ← 페이로드 flags **bit4**
0x1401ca658  call 0x1401d8950           ; opcode 4, 레코드 0x24
0x1401ca66c  [P+0x08] = 0x24
0x1401ca673  [P+0x00] = [rsp+0x40]       ; 이니셜라이저 스트림 base
0x1401ca6a4  [P+0x10] = asFloat(count)
0x1401ca6ac  [P+0x14] = -1.0f
0x1401ca6b3  [P+0x18] = 0xd0
0x1401ca6ba  [P+0x1c] = P_between - [rsp+0x40]

; around — 0x1401ca17d
0x1401ca17d  test byte [r13+8], 0x20   ; jne → 안 찍음
0x1401ca184  test byte [rsi+0x54], 1   ; je  → 안 찍음
0x1401ca1a1  call 0x1401d8910           ; opcode 3, 레코드 0x24
0x1401ca1b8  [rax+0x14] = 0xd0
```
여기서 `[r13+8]`은 별도 미상 객체가 아니라 **파티클 JSON 최상위 `flags`**다. 같은 팩토리가
`"flags"` 키를 `0x1401c55e4`에서 잡고, 숫자면 `asInt`(`0x1401c56e4`)의 하위 byte를
`[r13+8]`에 `0x1401c56f0`에서 저장한다. 따라서 between 레코드의 정확한 producer 조건은
`(system.flags & 0x20) == 0 && (between.flags & 0x10) != 0`이다(시스템 bit5의 이름은 미확정).

그리고 around 은 그와 별개로 `0x1401c9ed9 test byte [r13+8],0x10` 이 **안 서면**
`0x1401d8800`(opcode `0x0a`, `0x3c`)로 또 하나를 찍고 거기에 `speedmin`/`speedmax` 를 **다시**
파스해 넣는다(`0x1401c9efb`–`0x1401ca161`).

`0x1401d8950` 자체는 더 단순하다. 입력 cursor가 가리키던 주소를 레코드 base `R`이라 하면
`0x1401d8950`–`0x1401d8961` 은 `R[0] = 4`, cursor `= R+0x24`, 반환값 `P = R+4`만 만든다.
따라서 위 쓰기를 레코드 기준으로 옮기면 다음과 같다.

| 레코드 필드 | 값 | 의미 |
| --- | --- | --- |
| `R+0x00` `u8` | `4` | VM opcode |
| `R+0x04` `u64` | 이니셜라이저 스트림 base | 목적 스트림 포인터(복사 뒤 rebase) |
| `R+0x0c` `i32` | `0x24` | 다음 레코드 stride |
| `R+0x14` `f32` | authored `count` | 배율의 상수항 |
| `R+0x18` `f32` | `-1.0` | 분모 bias |
| `R+0x1c` `u32` | `0xd0` | 런타임 source 멤버 offset |
| `R+0x20` `i32` | `P_between - initializerBase` | opid 14 페이로드 `+0x00`(`step`)의 목적 offset |

#### 5.4.2 factory 임시 버퍼는 런타임까지 **두 번 deep-copy + rebase** 된다 [확정]

이 레코드는 stack/scratch 주소를 런타임에 붙들지 않는다.

1. 팩토리 꼬리 `0x1401d035f`–`0x1401d03ee` 가 길이
   `L = [rsp+0x30] - B` 를 구해 `FUN_1401c2e70(B, B+L)`(`0x1401d038c`)로 복사하고,
   결과 디스크립터 `+0x98`에 새 포인터, `+0xa0`에 `L`을 둔다. 빈 스트림도
   `FUN_1401c2e50`의 16-byte 정렬 zero sentinel을 소유한다.
2. `FUN_1401c2e70`(`0x1401c2e70`–`0x1401c2ebb`)은 `L+0x10`을 정렬 할당해 `memcpy`하고
   끝에 zero word를 둔다. 이어 `FUN_1401c2ef0` 호출 셋(`0x1401d03b1`, `0x1401d03c6`,
   `0x1401d03db`)이 각 레코드를 `R += signext(i32[R+0x0c])`로 걷고 `R+0x04`가 옛
   `B+0x2000`/`B+0x4000`/`B+0x6000`이면 대응하는 새 스트림 포인터로 바꾼다. 이 opcode 4의
   `R+0x04`는 옛 `B+0x4000`이므로 디스크립터 `+0x68` 포인터로 바뀐다.
3. `FUN_1401c4220`도 source 디스크립터 `+0x98/+0xa0`을 다시 `FUN_1401c2e70`으로 복사
   (`0x1401c44c8`–`0x1401c44e4`)한 뒤, 세 primary 스트림 포인터를 다시 rebase한다
   (`0x1401c44eb`–`0x1401c4564`). 시스템 생성 `0x14022cc5a`–`0x14022ccb7`에서 이 deep copy의
   목적은 `system+0x18`이다. 따라서 런타임의 이니셜라이저 스트림은 `system+0x80`, 두 번째
   스트림은 `system+0xb0`(길이 `system+0xb8`)에 있다.

#### 5.4.3 소비 VM과 opcode 4의 정확한 식 [확정]

정상 업데이트는 `0x14022be45`–`0x14022be5d`, 자식/복사 업데이트는
`0x14022f967`–`0x14022f982`에서 같은 `FUN_1401d15a0`을 부른다. 함수는
`mov rdi,[rdx+0x98]`(`0x1401d1756`)로 위 두 번째 스트림을 잡고, opcode 0 sentinel까지
opcode 1…14 점프테이블(`0x1401d17c0`–`0x1401d17e1`)을 돈다. opcode 4 arm은
`0x1401d186a`–`0x1401d189c`이며 그대로 쓰면 다음 식이다.

```text
next = R + signext(i32[R+0x0c])
source = f32[runtimeParams + u32[R+0x1c]]
denominator = max(source * f32[R+0x14] + f32[R+0x18], 1e-4)
f32[u64[R+0x04] + signext(i32[R+0x20])] = 1.0 / denominator
```

상수는 `1e-4` @`0x1404925fc`, `1.0` @`0x140492704`이고 루프 백에지는
`0x1401d228b`–`0x1401d2296`이다. 이 레코드에 값을 대입하면 결론은 하나다.

```text
between.step = 1 / max(authoredCount * runtimeParams.count - 1, 1e-4)
```

`runtimeParams`는 호출부가 넘기는 외부 파티클 인스턴스 블록 `particle+0x778`이고, `+0xd0`
(`particle+0x848`)은 추측성 scale이 아니라 **`instanceoverride.count`**다. 블록 생성자
`FUN_14024d760`의 `0x14024d7bc`가 기본 `1.0`을 심고, 등록 함수 `FUN_14024d940`은 문자열
`"count"`(`0x14048f72c`)와 멤버 offset `0xd0`을 `0x14024db67`/`0x14024db8a`에서 한
프로퍼티로 묶는다. 즉 bit4는 opid 14 핸들러가 이후 스폰에서 읽을 누산기 step을 현재 인스턴스
count 배율에 맞춰 갱신한다. 이 쓰기는 기존 값에 대한 배수가 아니라 **매 업데이트의 양수 대입**이다.
따라서 `limitbehavior:"mirror"`가 직전 스폰에서 step 부호를 음수로 뒤집었더라도 다음
`FUN_1401d15a0` 호출은 다시 위 양수로 덮는다. count가 바뀔 때만 재계산하는 구현으로는 같지 않다.

#### 5.4.4 실물 도달과 Waple 갭 [확정]

동봉 `Sources/WapleRender/Resources/WEAssets`와 원본 `wallpaper_engine/assets`를 각각 전수하면
bit4 선언은 두 트리 모두 정확히 다음 **2선언**이다(동명의 `preview` 복사본은 flags 7/3이라 제외).

| 프리셋 | flags | 동시에 켜진 기존 산술 | bit4 step (`C = instanceoverride.count`) |
| --- | ---: | --- | --- |
| `presets/lightning/particles/presets/thunderbolt.json` | 23 (`0b10111`) | bit0 수직 arc · bit1 속도 arc · bit2 size arc; bit3 꺼짐 | `1 / max(32*C - 1, 1e-4)`(count 부재 → 주입 32) |
| `presets/lightning/particles/presets/thunderbolt_beam_child.json` | 19 (`0b10011`) | bit0 수직 arc · bit1 속도 arc; bit2/3 꺼짐 | `1 / max(8*C - 1, 1e-4)`(저작 count 8) |

두 프리셋은 최상위 시스템 `flags:0`이라 `[def+8]&0x20` producer 게이트를 통과하고,
`limitbehavior` 부재(주입 `"repeat"`)다. 이를 참조하는 동봉 장면은 `instanceoverride.count`를
따로 저작하지 않아 `C=1`이고, 각각 `1/31`, `1/7`로 정적 초기 step과 수치가 같다. repeat라 위
mirror 부호 재대입 차이도 없다. 따라서 **이 정확한 동봉 장면의 현재 출력은 Waple 갭에 의해
달라지지 않는다.** 하지만 커스텀 장면/에디터가 두 시스템에 count 배율을 주면 즉시 도달한다
(예: `C=0.5`면 `1/15`, `1/3`). Waple은
`ParticleSystemDef.parse`와 `ParticleSimulator`는 이제 파스 시점의 `instanceOverride.count`를
`instanceCountMultiplier`로 보존하고, 위 producer 게이트가 열린 선언의 step을 매 `step(_:)`
시작에 다시 대입한다. 아래 1·2·4는 `ParticleMapSequenceOracleTests`가 순수/통합 오라클로 잠근다.
다만 Waple에는 런타임 프로퍼티 애니메이션으로 override count를 바꾸는 통로가 없으므로 현재 구현
범위는 **정적 instance override**까지다. 직접 조립한 def와 override 부재는 기본 배율 `1`을 쓴다.

자식도 별도 count 기본값을 쓰는 것이 아니라 **루트 scene instance의 owner count를 공유**한다.
루트 생성 경로 `FUN_14018ff60`은 `FUN_1402293a0(..., plVar10)`으로 scene object를 owner로 넘기고,
자식 생성 `FUN_14022ebe0`·`FUN_140236cd0`·`FUN_1402378a0`은 모두 같은 부모의 owner
`param_1[1]`을 `FUN_1402293a0`의 세 번째 인자로 다시 넘긴다. 따라서 Waple의 SceneDocument는
**전체** `instanceOverride`를 자식 JSON 파스에 넘기지 않고(자식 emitter/maxCount 등 authored 정적
값 유지), 루트 파스가 확정한 `instanceCountMultiplier`만 모든 자식/손자 def에 재귀 주입한다.
직접 `ParticleSystemDef.parse(resolveChild:)`를 부르는 경로도 같은 후처리를 탄다. 이는 동적 override
객체 전체를 구현한 것이 아니라, 현재 정적 범위에서 opcode 4가 읽는 owner count만 보존한 것이다.

1. `authoredCount=8`, `C=0.5`, between bit4 on, system bit5 off → `step=1/3`.
2. 같은 입력에서 between bit4 off **또는** system bit5 on → 정적 authored step `1/7` 유지
   (두 producer 게이트를 각각 대조).
3. `authoredCount*C−1 <= 1e-4` → 정확히 `10000`; 분모 clamp를 count clamp로 바꾸지 않았음을 감시
   (현재 authored step의 동일 clamp 오라클이 있고, opcode 4 배율 경로의 별도 직교 테스트는 남음).
4. mirror가 음수로 바꾼 step도 다음 업데이트 시작에 양수 식으로 덮임. `C` 값 변화가 없는 프레임도
   다시 써야 한다는 런타임 순서 오라클.

**남은 것**: 소비 VM 가족 자체는 찾았지만, 이 절의 `around` 쪽은 아직 닫지 않았다.
`FUN_1401d15a0`의 opcode 3/10 arm이 존재하는 것과 별개로, §5.3의 **파서가 `flags`를 안 읽는데
`0x1401ca184`가 `+0x54`를 게이트로 읽는 모순**, 그 게이트의 실물 도달, opcode 10의
`speedmin`/`speedmax` 최종 필드 의미는 계속 미해결이다. 함정 2("한 요소에 핸들러가 둘 붙을 수
있다")의 실사례라는 결론도 그대로다.

**[정정]** §8.3 의 "값 16 은 bit4 이고 런타임이 읽는 비트가 아니라 아무 데도 안 걸린다" 는
**`controlpoint[].flags`** 에 대한 문장이다. `mapsequencebetweencontrolpoints` **자신의** `flags`
bit4 는 위처럼 걸린다 — 두 `flags` 는 다른 필드다.

---

## 6. 자식 시스템의 CP 상속 — `controlpointstartindex` [확정]

### 6.1 자식 링크 디스크립터

파스: 대형 팩토리 `0x1401c5490`–`0x1401d152c` 안에서 자식 링크 구조체(`[rbp+0x490]` 기준)를 채운다 —
`flags` → `+0x64`(`0x1401d09be`), `controlpointstartindex` → `+0x68`(`0x1401d09db`,
키 `lea` `0x1401d09c4`, `asUInt` `0x140085f70`).

### 6.2 스폰 시 — `0x14022c3c0` 이 시스템에 심는다

```
0x14022ccbf  rax = [rbp+0x110]                  ; 자식 링크 디스크립터
0x14022cccb  test byte [rax+0x64], 1 ; je …     ; 자식 flags bit0 게이트
0x14022ccd1  or  byte [sys+0x3f6], 1            ; "부모 파티클이 CP 를 먹인다" 플래그
0x14022ccda  mov dword [sys+0x44], 8            ; CP 개수를 8 로 강제
0x14022cce3  movzx eax, byte [rax+0x68]         ; controlpointstartindex
0x14022cce7  mov byte [sys+0x3f5], al
...
0x14022ccf8  and byte [sys+0x3f6], 0xfe         ; 게이트 실패 시 끈다
```

### 6.3 매 프레임 — `0x14022a580`–`0x14022a898` 이 **읽는 자리**다

호출부는 `0x140236401` · `0x1402364b0`(둘 다 `0x1402308a0` 안). 인자는
`rcx = 부모 시스템`, `rdx = 자식 링크 디스크립터`, `r8 = 자식 시스템`, `r9 = 부모 SoA(+0x258)`.
레지스터 대응은 안에서 확인된다 — `[rbx+0xe8]` = `부모+0x340` = **파티클 수**,
`[rbx+0x58/0x60/0x68]` = `부모+0x2b0/0x2b8/0x2c0` = **위치 x/y/z**, `[rbx+8]` = `부모+0x260` = lifetime.

```
0x14022a593  test byte [rdx+0x64], 1 ; je → 즉시 반환      ; 자식 flags bit0
0x14022a710  edx = [rsi+0x68]                              ; = controlpointstartindex
0x14022a715  cmp edx, 8 ; jge → 종료
루프(ecx = 부모 파티클 인덱스):
0x14022a730  cmp ecx, [rbx+0xe8] ; jae → 종료              ; 파티클 수
0x14022a743  xmm0 = lifetime[ecx] ; == xmm7(0) → 건너뜀    ; 죽은 파티클은 슬롯을 안 먹는다
0x14022a754  r9 = [rdi+0x400]                              ; **자식** 시스템 CP 배열
0x14022a75e  imul r8, edx, 0xd0
0x14022a765  test dword [r9+r8+0xc0], 0x10005 ; jne → 건너뜀
0x14022a787  inc edx                                       ; 슬롯 소비
0x14022a7de/0x14022a7ff/0x14022a816
             CP[edx] +0x30/+0x34/+0x38 = 변환된 부모 파티클 위치
```
변환 행렬은 `[rcx+0x20]&1`(부모 시스템 flags)과 `[r8+0x20]&1`(자식 시스템 flags)의 조합으로
고른다(`0x14022a5f7`–`0x14022a6a9`) — 둘 다 월드면 항등, 아니면 오브젝트 변환(`[[rcx]+0x30]`).

**[확정] 의미**: `controlpointstartindex = k` 인 자식 시스템은 CP 슬롯 `k, k+1, … 7` 에
**부모의 살아 있는 파티클 위치**를 순서대로 받는다. 슬롯 `0..k−1` 은 자기 저작값을 쓴다.
그래서 `mapsequencebetweencontrolpoints(controlpointstart=0, controlpointend=1)` 같은
자식이 "부모 파티클 두 개 사이를 잇는 번개" 가 된다(동봉 `thunderbolt_child_spawner`).

**[확정] 부수효과**: 이 경로가 켜지면 자식 CP 개수가 **무조건 8** 이 된다(`0x14022ccda`).
**[확정] 게이트가 두 겹이다** — 자식 링크 `flags & 1` 이 없으면 `[sys+0x3f6]` 도 안 서고
`0x14022a580` 도 즉시 반환한다.
**[미해결]** CP 자신의 `flags & 0x10005` 로 건너뛴 슬롯은 `edx` 를 전진시키지 않는다
(`0x14022a765` → `0x14022a81d` 는 `ecx` 만 증가). 즉 막힌 슬롯에서 배정이 **정체**한다.
의도인지 버그인지 판단 못 했다(동봉 도달 0 — §8).

> **[해소 2026-08-21 · 레인 BJ — 도달 정정 + 동작 확정. 의도는 여전히 미상]**
> **"동봉 도달 0" 이 틀렸다. 실제 도달은 동봉 2파일 / 설치본 2파일이다.**
> 자식 링크 `flags & 1` 이 선 4링크를 전부 펼쳐 자식 파티클의 CP `flags` 를 대조했다:
>
> | 부모 | 자식 | `controlpointstartindex` | 자식 CP flags | 결과 |
> | --- | --- | ---: | --- | --- |
> | `presets/lightning/.../thunderbolt.json` | `thunderbolt_child_spawner.json` | 부재 → **0** | CP1 = **4**(bit2) | **슬롯 1 에서 정체** — 슬롯 0 하나만 채워진다 |
> | `presets/lightning/previewthunderbolt/.../thunderbolt.json` | 〃 | 부재 → 0 | 〃 | 〃 |
> | `.../thunderbolt_child_spawner.json` | `thunderbolt_beam_child.json` | **1** | 전부 0 | 정상(슬롯 1..7) |
> | `previewthunderbolt/.../thunderbolt_child_spawner.json` | 〃 | 1 | 전부 0 | 정상 |
>
> 그리고 **정체는 "한 칸 밀림" 이 아니라 "그 뒤로 아무것도 안 채워짐" 이다.** 두 건너뛰기
> (죽은 파티클 `0x14022a74c`, 막힌 슬롯 `0x14022a771`)가 **같은** 자리 `0x14022a81d` 로 가고
> 거기서는 `inc ecx` 만 한다. 루프 종료 조건이 `ecx >= [rbx+0xe8]`(부모 파티클 수) 이므로
> 남은 부모 파티클이 전부 같은 슬롯에서 튕기고 끝난다.
> **부수로 확정**: 죽은 판정은 `ucomiss xmm0, xmm7(0)` + `jp`/`je` 라 **NaN 수명은 살아 있는
> 것으로 친다**(`0x14022a749`–`0x14022a74e`).
> 산술은 `ParticleControlPointMath.childControlPointFeed` 로 옮겼고
> `ParticleControlPointFrameTests.testChildFeedBlockedSlotStallsForever` 가 값으로 잠갔다.
> **의도인지 버그인지는 여전히 판단 못 했다 — 그건 [미해결] 로 남는다.**

---

## 7. `relative` base 규약 [확정]

### 7.1 파스 — base 를 **키프레임에 굽는다**

바인딩 파서 `0x1401a4db0`–`0x1401a5a8e` 안:
```
0x1401a538a  lea rsi, "relative"(0x14048ed68)
0x1401a539e  call Json::Value::find
0x1401a53a3  test rax, rax ; je 0x1401a55de      ← **키 존재만** 본다(값 미판독)
0x1401a53bd  find("value")
0x1401a53cc  cmp byte [rax+8], 4 ; jne 0x1401a55de  ← value 가 **문자열**일 때만
0x1401a544a…  strtod ×3 → xmm6 / xmm7 / xmm8
0x1401a5574  call 0x1401a89a0(xmm0=xmm7, rdx=c1)
0x1401a55b1  call 0x1401a89a0(xmm0=xmm8, rdx=c2)
   (c0 는 그 위 같은 모양의 호출)
```
`0x1401a89a0`–`0x1401a8c04` 은 배열(태그 6)을 돌며 각 원소의 `value` 를 `asFloat`
(`0x140086220` @`0x1401a8a81`)로 읽어 **`addss xmm0, xmm6`(`0x1401a8a8a`)** 한 뒤
`cvtss2sd` → `movsd [r14]`(`0x1401a8aa1`/`0x1401a8aa5`)로 **JSON DOM 을 제자리 수정**한다.
**`c3` 는 이 처리를 받지 않는다**(호출이 셋뿐이다).

### 7.2 런타임 — **절대 대입이다**

등록부 항목의 함수 포인터 넷은 vec3 항목 전체가 **같은 값**을 공유한다
(`lea r14, 0x1401a4230` @`0x14024defc` · `lea r15, 0x1401a4530` @`0x14024df0b` ·
`lea r12, 0x1401a4560` @`0x14024df15` · `lea rsi, 0x14022ab30` @`0x14024da31` —
`colorn` 항목 앞에서 한 번 잡고 `controlpoint*`/`controlpointangle*` 항목이 그대로 재사용한다.
`controlpoint0` 의 스토어가 `0x14024dfe5`(`+0x38`=r14) · `0x14024dfed`(`+0x48`=r15) ·
`0x14024dff1`(`+0x50`=r12) · `0x14024dff5`(`+0x58`=rsi)):

| 슬롯 | 함수 | 역할 |
| --- | --- | --- |
| `+0x38` | `0x1401a4230` | JSON 값(태그 판별 포함)에서 심는 파스 세터 |
| **`+0x48`** | **`0x1401a4530`** | **평가된 vec3 를 대상에 쓰는 런타임 세터** |
| `+0x50` | `0x1401a4560` | 현재 값 읽기 |
| `+0x58` | `0x14022ab30` | 사후 훅 — 더티 비트 |

애니 평가기가 부르는 것은 `+0x48` 이다(`0x1401726aa call qword [rax+0x18]`,
`rax` = `0x14024e970` 이 돌려준 `항목+0x30`):

```
0x1401a4530  test r8, r8 ; je …
0x1401a4535  movsxd r9, [rdx+4]              ; 디스크립터의 오프셋(0xf0+12i / 0x150+12i)
0x1401a4539  movsd  xmm0, [r8]               ; x,y
0x1401a453e  movsd  [r9+rcx], xmm0           ; **대입** (누산 아님)
0x1401a4544  mov    eax, [r8+8]              ; z
0x1401a4548  mov    [r9+rcx+8], eax
0x1401a454d  rax = [rdx+0x28] ; if (rax) jmp rax
                → 0x14022ab30: mov byte [rcx+0x1b0], 1     ; 더티 비트
```
`rcx` = 프로퍼티백 = `obj+0x778` 이므로 더티 비트는 `obj+0x928` 이고, 오브젝트 업데이트
`0x140230650` 이 그것을 보고 CP 재구성을 돌린다:
```
0x1402307bd  cmp byte [r14+0x928], 0 ; je 0x1402307ff
0x1402307e5  mov byte [r14+0x928], 0
0x1402307fa  call 0x14022bd40                 ; §2.2
```
평가기 쪽 인자 배치: `rcx = [rbx+8]` = 대상 객체, `rdx = rax` = 항목`+0x30`,
`r8` = 평가 결과 vec3(`lea r8,[rbp+0x430]` @`0x14017247c` 계열).
평가 자체는 `0x1401a9bc0` ×N, 정수 프레임 2샘플 선형보간 `0x1401723d8`–`0x140172490` 이다.

### 7.3 결론

**[확정] 정적 `value` 는 런타임 base 가 아니다.** 애니가 있으면 매 프레임 **절대 대체**된다.
`relative` 는 **저작 시점 오프셋**이고, 파스에서 c0/c1/c2 키프레임 값에 더해 굽혀 사라진다.

**[확정] 코퍼스가 이 해석을 그대로 확인해 준다.**
`scenes/particleelementpreviews/maintaindistancebetweencontrolpoints/scene.json` 의
`instanceoverride.controlpoint1` 은 `value = "0.00000 436.42032 0.00000"` 이고
`c1[0].value = 436.42032` 다 — **frame 0 값이 정적 `value` 와 정확히 같다**(합산이었다면 872.8).
`presets/magic/previewvortexorb/scene.json` 의 `controlpointangle1` 도
`value = "2.47837 -0.62832 0.02213"` ↔ `c0[0]/c1[0]/c2[0] = 2.4783676 / −0.62831855 / 0.022130774` 로 일치.
반대로 `relative: true` 인 유일한 블록(같은 파일의 `/objects/0/origin`)은
`value = "128.00000 238.94785 0.00000"` 인데 `c0[0]/c1[0]/c2[0] = 0` 이다 — 굽고 나면
역시 frame 0 = 정적 `value` 가 된다. **두 규약 모두 "frame 0 == 정적 value" 로 수렴한다.**

**[확정] Waple 은 이미 맞다.** `PropertyAnimation.value(component:atTime:base:)`
(`Sources/WapleCore/PropertyAnimation.swift:159`)가 `relative ? base + raw : raw` 로 평가
시점에 더한다. 베지어가 `value` 에 대해 아핀이라 파스 시점 굽기와 동치다.
**[확정] 잔여 차이 둘**(둘 다 코퍼스 도달 0):
- 실물은 `value` 가 **문자열일 때만** 굽는다(`0x1401a53cc`). Waple 은 타입을 안 본다.
- 실물은 **c3 를 제외**한다. Waple 은 성분 구분 없이 `base` 를 더한다.

---

## 8. 코퍼스 도달 (범위 라벨 필수)

측정 코퍼스 둘, JSON 은 **관용 파서**로 읽었다(`scripts/spec/measure_misc_assets.lenient_json`).

| | 동봉 `Sources/WapleRender/Resources/WEAssets` | 설치본 `/home/user/Waple-wallpaper-source/wallpaper_engine` |
| --- | ---: | ---: |
| `.json` 파일 | **1,698** | **2,143** |
| `json.loads` 성공 | 1,667 | 2,110 |
| **관용 파서로만 성공(JSONC)** | **31** | **32** |
| 복구 실패 | 0 | 1 |

> 브리프의 "3,655 중 63" 은 이 두 코퍼스 합(3,841) 기준으로는 **재현되지 않는다**.
> 여기서 잰 JSONC 는 31 + 32 = **63** 으로 개수는 맞고, 분모가 3,841 이다.
> **[미해결]** 분모 3,655 의 출처.

### 8.1 씬 쪽 `instanceoverride.controlpoint*`

두 코퍼스가 **완전히 같은 수치**를 낸다(설치본 `assets/` 가 동봉 트리와 같은 집합).

| 키 | 오브젝트 수(objects[] 직속) |
| --- | ---: |
| `controlpoint1` | 34 |
| `controlpoint2` | 22 |
| `controlpointangle1` | 6 |
| `controlpointangle2` | 1 |

저작 파일 수 **35**. `controlpointangle*` 를 저작한 씬은 **6 오브젝트 / 소수 파일**뿐이다.

### 8.2 `{animation}` 바인딩 — **`variants[]` 를 빠뜨리면 안 된다**

경로별 `animation` 딕셔너리 전수(양 코퍼스 동일, **7블록 / 6파일**):

| 경로 | 개수 | 파일 |
| --- | ---: | --- |
| `objects[].instanceoverride.controlpoint1` | 1 | `scenes/particleelementpreviews/maintaindistancebetweencontrolpoints/scene.json` |
| `objects[].instanceoverride.controlpointangle1` | 1 | `presets/magic/previewvortexorb/scene.json` |
| **`variants[].objects[].instanceoverride.controlpointangle1`** | **3** | `presets/magic/preset.json` · `presets/magic/previewcolorsparkle/presets/magic/preset.json` · `presets/magic/previewvortexorb/presets/magic/preset.json` |
| `objects[].origin` | 1 | `…/maintaindistancebetweencontrolpoints/scene.json` |
| `objects[].effects[].passes[].constantshadervalues.multiply` | 1 | `effects/blendgradient/preview/scene.json` |

**[확정] 정정**: 커밋 `aa976b7` 메시지의 "`controlpointangle1` 4" 중 **3건은 `objects[]` 가 아니라
`variants[].objects[]`** 다. `SceneDocument` 는 프리셋 `variants[]` 를 파스하지 않으므로
`instanceOverrideAnimations` 로 실제로 들어오는 것은 **2블록**(`controlpoint1` 1 + `controlpointangle1` 1)이다.
`relative` 를 가진 블록은 7 중 **1건**이고 그것은 `objects[].origin` 이다 — **`instanceoverride` 아래
`relative` 는 0건**이다.

**[2026-08-31 동적 각도 배선]** 직접 `objects[]`에서 파스되는 `controlpointangleN` 트랙은
`ParticleSimulator`가 자체 시간으로 매 서브스텝 평가하고, 이미터와 opid 13이 같은 live 3×3을 읽는다.
루트 GPU 시스템이 트랙을 보존해 2D/3D 라이브와 캡처 reset에 공통 전달한다. block mask는
`0x10005`이고, 코퍼스의 decimal `16`은 `0x10`이라 허용된다는 양성 대조도 있다. 다만
`previewvortexorb`의 particle은 emitter CP0·around 0이라 angle1 소비처 교집합은 0이다.

**[2026-08-31 동적 위치 배선]** `controlpointN`도 자체 시계에서 live CP를 갱신한다. emitter,
mapsequence 13/14, remap CP 입력, maintain-between은 그 배열을 직접 읽고, 파스 때 target을 굽는
attract/maintain-to/vortex/reduce는 binding을 통해 `runtimeCP - defCP`를 합성한다. flags&4 자식은
`parentcontrolpoint`가 가리키는 부모 live 위치/각도를 매 스텝 받는다. vortex binding은 authored
offset을 별도로 보존하므로 정적 부모 CP 재베이크와 동적 이동 모두 offset을 정확히 한 번만 더한다.

### 8.3 파티클 `.json` 쪽

| | 동봉 | 설치본 |
| --- | ---: | ---: |
| 파티클류 `.json`(`emitter`/`initializer`/`controlpoint` 보유) | 289 | 296 |
| `controlpoint[]` 원소 | 1,816 | 1,856 |
| 그중 `angles` 저작 | **0** | **0** |
| `controlpoint[].flags` 분포 | 0:1725 · 부재:36 · 1:28 · **16:10** · 2:10 · 4:7 | 0:1757 · 부재:44 · 1:28 · 16:10 · 2:10 · 4:7 |
| `initializer[].name == mapsequencebetweencontrolpoints` | 12 | 12 |
| `initializer[].name == mapsequencearoundcontrolpoint` | 7 | 7 |
| `children[]` 링크 | 101 | 101 |
| `children[].controlpointstartindex` | `null`×99 · `1`×2 | 동일 |
| `children[].flags` | 부재 86 · 0:9 · **1:4** · 2:2 | 동일 |
| `emitter[].controlpoint` | 부재 288 · `1`×4 · `2`×2 | 부재 295 · `1`×4 · `2`×2 |

**[확정 → 2026-08-21 정정 · 마커 갱신 2026-08-28]** 값 `16` 은 **bit4**(0x10)이지 bit16 이
아니다. ~~런타임이 읽는 비트는 bit0·bit2·bit3·bit16 뿐~~(**틀렸다 — bit1 이 빠졌다.
바로 아래 정정 블록**)이므로 이 10건은 **아무 데도 안 걸린다**.

> **[정정 2026-08-21 · 레인 BJ] 이 문장은 `bit1` 을 빠뜨렸다 — 문서가 자기 자신과 모순이었다.**
> `bit1`(값 2)은 런타임이 **두 자리에서** 읽는다:
> `and r9d, 2` @`0x14022a08c`(기본 갱신 — 공간 변환 갈림, §12.2)와
> `test byte [rbx+0xc0], 2` @`0x14023bc9c`(이니셜라이저 opid 8 — 오브젝트 보정 게이트).
> 같은 문서의 §1 과 §2.3 은 bit1 을 제대로 적고 있다. 읽히는 비트는 **다섯**이다 —
> bit0·**bit1**·bit2·bit3·bit16. (값 `16` 이 bit4 라 아무 데도 안 걸린다는 결론 자체는 맞다.)
> **bit1 저작 도달 10 원소 / 동봉 1,816**(설치본도 10 / 1,856) — 전건 `idx == 1`.
>
> **[신설] `parentcontrolpoint` 저작의 94%는 죽은 값이다.** 동봉 1,816 원소 중
> `parentcontrolpoint` 키를 가진 것이 **108**(`0`×77 · `1`×17 · `2`×14, 설치본 동일)인데,
> 그 값을 실제로 쓰는 게이트인 bit2 가 서는 원소는 **7**뿐이다 → **101 원소가 무의미**하다.
**[확정]** `children[].flags` 에 bit0 이 선 링크가 **4건**이고, `controlpointstartindex` 가
실린 것이 **2건**이다 — §6 의 자식 CP 피드가 실제로 도달하는 자산이 있다.

---

## 9. Waple 대조 — 정확한 패치안

> **[2026-08-21 후속 라운드 결과]** 아래 P1~P4 를 **재검증**하고(남의 주석을 베끼지 않고 이
> 저장소에서 전부 다시 떴다) 안전한 것부터 적용했다. 현재 상태:
>
> | | 상태 | 비고 |
> | --- | --- | --- |
> | **P4** 문서 정정(44→0x40) | **적용** | `docs/re/particle-operator-vm.md` §7. 함수 `0x14024f2d0`–`0x14024f331`, dword 16회 = 64B 확인 |
> | **P3** CP 각도 소비처 주석 | **적용** | `ParticleSystem.swift` 두 자리. 소비처 둘을 재확인했고, **파티클 `.json` 쪽 `angles` 는 base 에 안 실린다**는 구분을 명시 |
> | **P2** `children[].flags` | **부분 적용** | `ChildLink.flags` + 런타임 CP 작업 배열. between·CP remap 입력·`maintaindistancebetweencontrolpoints`와 베이크형 attract/vortex/maintain/reduce까지 live CP를 소비한다. 남은 것은 비항등 mixed-space 부모→자식 transform-stack 4×4 변환이다. |
> | **P1** `mapsequence` = 위치 | **between·around 적용** | 두 타입 모두 선언별 solver로 위치·속도를 되쓰고 `p.frame`은 건드리지 않는다. between은 크기도 갱신한다. around는 CP 프레임·RNG·상태·Float 명령순서까지 오라클로 잠겼다. |
>
> **P1 무회귀 증명(새로 잰 것).** 동봉 `WEAssets` 와 설치본 두 코퍼스 모두에서
> `initializer[].name` 이 `mapsequence*` 인 파티클 `.json` 은 **17파일 / 19선언**(between 12 ·
> around 7)이고, 그 `material` 이 가리키는 텍스처는 다섯 종
> (`particle/halo` · `particle/halo_2` · `particle/beam/beam_0` · `particle/beam/beam_2` ·
> `particle/misc/star_0`)뿐이다. 다섯 `.tex` 를 `scripts/spec/measure_tex_deep.parse_tex` 로
> 열면 **전부 `TEXS` 섹션이 없다**(`texs=None`). Waple 렌더러의 시트 분기는
> `if !sys.frames.isEmpty` 안에 있고 `frames` 는 `TEXS` 에서만 오므로
> (`SceneRendererResources.resolveTextureWithFrames`), `p.frame >= 0` 분기
> (`SceneRendererFrameEncoder.swift:123`/`:264`, **그리고 `SceneRenderer3D.swift:2367` —
> 종전 경고가 빠뜨린 세 번째 소비처**)는 이 19건에서 **애초에 도달하지 않는다**.
> 19건 전부 `animationmode` 부재라 `randomframe` 경로와도 겹치지 않는다.
> 즉 "동봉 19건의 그림이 바뀐다" 는 경고는 **성립하지 않는다**.
>
> **그런데도 미적용인 이유**는 다른 데 있다: `p.frame = t·count` 를 걷으면
> `Tests/WapleCoreTests/TexFramesAndMapSequenceTests.swift` 의 세 테스트가 깨지는데
> (`testMapSequenceBetween_projectsOntoSegment` 2.0 / `…_clampsOutsideSegment` 0 /
> `testMapSequenceAround_angleToSequence` 4.0) 그 파일이 이 라운드의 **소유 밖**이다.
> 소스에는 `[근거없음 — 걷어낼 자리]` 표시만 남겼다(`ParticleSimulator` `case let .mapSequence`).
>
> **재검증에서 원문과 어긋난 것은 없었다.** 점프테이블 16개, 썽크 opcode(13→`0x5c`, 14→`0x38`),
> 두 핸들러의 SoA 슬롯 전수(`+0x268` 0회), CP ctor 가 회전 3행에 항등을 넣는 것,
> `children[].flags`/`controlpointstartindex` 의 파스·주입 자리 — 전부 그대로 재현됐다.
> 다만 §4.1 이 "종전 `particle-operator-vm.md` §7 은 오기다" 라고만 적어 둔 것은 이제
> **그 문서에서 실제로 고쳐졌다**.

> ---
>
> **[2026-08-21 세 번째 라운드 — 클러스터 AT] 무회귀를 먼저 재고, 산술만 잠갔다.**
>
> | | 상태 | 근거 |
> | --- | --- | --- |
> | **P1-① 도달 재측정** | **끝** | `p.frame >= 0` 분기를 지나는 mapsequence 자산 **0건**(아래) |
> | **P1-② 산술 이식** | **적용** | `MapSequenceBetweenSolver`(`ParticleSimulator.swift`) — 오라클 27건 |
> | **P1-③ 페이로드 파스** | **적용** | `MapSequenceBetweenSpec` / `MapSequenceAroundSpec` + `def.mapSequence{Between,Around}` |
> | **P1-④ 위치 대입 배선** | **미적용** | 화면이 바뀌고 A/B 캡처가 불가능하다(아래 수치) |
> | **P1-⑤ `p.frame` 대입 삭제** | **미적용** | 소유 밖 테스트 파일이 걸린다(§P1 패치안) |
> | **P2 자식 CP 피드** | **파스만**(전 라운드 그대로) | 소비는 `bakeControlPointTargets` 구조 변경이 먼저 |
> | **§11 [미해결] 3** | **절반 닫음** | `around` 의 `speedmin`/`speedmax` 자리·기본·소비처 확정(§5.3) |
>
> **① 도달 — 0 이다(양성 대조 포함).** 관용 파서(`measure_misc_assets.lenient_json`)로 다시 셌다:
> 동봉 `.json` **1,698** 중 `initializer[].name` 이 `mapsequence*` 인 파티클 **17파일 / 19선언**
> (between **12** · around **7**), 설치본 **2,143** 중에서도 **똑같이 17 / 19**.
> 그 `material` 8종(`materials/particle/halo_1.json` · `materials/presets/{discharge,dischargearc,
> dna,magic_trinity,starcircle,thunderbolt,thunderbolt_beam_child}.json`)이 가리키는 텍스처는
> 다섯 종(`particle/halo` · `particle/halo_2` · `particle/beam/beam_0` · `particle/beam/beam_2` ·
> `particle/misc/star_0`)이고, `measure_tex_deep.parse_tex` 로 열면 **다섯 다 `texs = None`** 이다.
> **양성 대조**: 같은 트리의 `.tex` **311개 중 52개는 TEXS 를 갖는다**(`particle/fire/fire1..3`
> `TEXS0002`, `particle/shape/{sparks_thick,electricity}_sheet` `TEXS0003` 등) — 탐지가 도는데
> 이 다섯만 없는 것이다. Waple 은 `sys.frames` 를 `resolveTextureWithFrames(def.material?.textureName)`
> 에서만 받고(`SceneRendererResources.buildParticles`), 시트 분기는 전부 `if !sys.frames.isEmpty`
> 안에 있다. 그리고 19선언 전부 `animationmode: null` 이다.
> → **`p.frame >= 0`(`SceneRendererFrameEncoder` 두 자리 · `SceneRenderer3D` 한 자리)를 지나는
> mapsequence 자산은 0건이다.** 즉 `p.frame` 대입을 걷어내는 것 자체는 그림을 안 바꾼다.
>
> **② 그런데 위치 대입은 그림을 바꾼다 — 그래서 안 넣었다.** `flags` 저작 분포(동봉·설치 동일):
> `4`×2 · `7`×3 · `3`×1 · `15`×2 · `23`×1 · `19`×1 · 부재×2 = 12선언.
> 비트별로 세면 **bit0(수직 성분 수렴) 10선언 · bit1(속도 감쇠) 10선언 · bit2(크기 축소) 8선언 ·
> bit3(arc 벌지) 4선언**이다. `sizereductionamount` 는 **저작 0건**이라 8선언 전부 주입 기본 0.9 —
> 즉 시퀀스 양 끝에서 크기가 원래의 **10%** 가 된다. 이건 눈에 보이는 변화다.
> **이 컨테이너에는 Metal 이 없어 A/B 캡처가 불가능하므로 배선은 맥 라운드로 넘긴다**(§P1 절차).
>
> **③ 새로 확정한 것 셋.**
> 1. **`between` 과 `around` 의 스텝 식이 다르다.** between 은 `1 / max(count − 1, 1e-4)`
>    (`subss xmm0, xmm10(1.0)` @`0x1401ca249` → `comiss xmm14(1e-4)` @`0x1401ca24e` →
>    `divss` @`0x1401ca29d` → `movss [rdi]` @`0x1401ca2af`), around 은 **`−1` 없이**
>    `1 / max(count, 1e-4)`(`comiss` @`0x1401c99a5` → `divss` @`0x1401c99ef` → `movss [rsi]` @`0x1401c9a01`).
>    상수는 둘 다 루프 진입 전 `xmm14 = 1e-4`(`0x1404925fc`, 적재 `0x1401c70a1`) ·
>    루프 백에지 `xmm10 = 1.0`(`0x140492704`, 적재 `0x1401c70c0`)에서 온다.
> 2. **`around` 의 `speedmin`/`speedmax` 는 살아 있다**(§5.3).
> 3. **`between` 의 `flags` bit4(`0x10`)는 죽은 비트가 아니다**(§5.4).
>
> **④ 검증.** `verify-isolated.sh AT … --filter ParticleMapSequenceOracleTests` →
> **27건 0실패**(rc=0). 돌연변이 4건(스텝의 `−1` 제거 · `arc` 지수 2→1 ·
> 크기식 `(1−sr)+sr·arc` → `sr+(1−sr)·arc` · `controlpointend` 주입 기본 1→0)을 넣으니
> **8개 테스트 15단언이 실패**했다 — 네 돌연변이 전부 잡힌다.

> **[2026-08-31 네 번째 라운드 — 위치 배선 해소]** opid 14의 산술·페이로드가 이미 완결돼
> 있었으므로 실제 스폰 경로의 no-op을 red 통합 테스트로 재현한 뒤 배선했다. `ParticleSimulator`는
> `mapSequenceBetween` 선언마다 `MapSequenceBetweenSolver` 하나를 보유하고, 매 스폰에서
> between-only ordinal로 같은 상태를 이어 쓴다. around는 인덱스를 소비하지 않는다.
>
> red에서는 burst 3개가 전부 원점/크기 4에 남아 **6단언이 실패**했다. green에서는 count=3의
> `t=0,0.5,1`이 위치 x=`0,5,10`, 크기=`0.4,4,0.4`를 만들었고, around 사이에 둔 두 between
> 선언도 독립 상태로 x=`100,200`을 냈다. `ParticleMapSequenceOracleTests` 29건과
> `ParticleSimulatorTests`·`TexFramesAndMapSequenceTests`를 합친 관련 93건이 모두 통과했다.
> 이 라운드 당시 남겼던 `around` 기저 혼합식은 2026-08-31 후속 라운드에서 opid 13으로
> 연결됐다. ChildLink 동적 CP 피드도 같은 날 런타임 작업 배열까지 연결됐고, 남은 경계는 아래
> P2에 적는다.

아래 파일들은 **이 클러스터의 소유가 아니다**. 고치지 않았다. 넘긴다.

### P1. `mapsequence*` 는 스프라이트 프레임 선택이 **아니다** (가장 큰 어긋남)

**현상.** `ParticleSystem.swift` 의 `Initializer.mapSequence` 주석이 종전에
"스프라이트시트 프레임 선택(스폰 시 확정)" 이라고 적었고, `ParticleSimulator.swift` 의
`case let .mapSequence(count, _, between)` 이 `p.frame = t * max(0, count)` 만 한다.
`SceneRendererFrameEncoder.swift` 의 `if p.frame >= 0 { idx = sheetFrameIndex(sequence: p.frame, …) }`
두 자리와 `SceneRenderer3D.swift` 의 형제 분기가 그 `p.frame` 으로 시트 인덱스를 고른다.
(**함정 20** — 남의 파일 줄 번호 대신 그 줄의 코드를 적는다.)

**실측.** 실물 핸들러 둘(`0x14023c4cf` around / `0x14023ca93` between)이 만지는 SoA 슬롯을
전수로 뽑으면 `+0x2b0/+0x2b8/+0x2c0`(위치) · `+0x2c8/+0x2d0/+0x2d8`(속도) ·
`+0x278`(기준 size, between 만) 뿐이고 **시퀀스 슬롯 `+0x268` 은 없다**.
`+0x268` 이 시퀀스 슬롯인 것은 `0x14023b4ef`/`0x14023b503`(animationmode 초기화)과
`0x14023ce8b`(`remapinitialvalue` 출력 arm)이 증명한다.

**패치안 (before/after — 개념)**

```swift
// Sources/WapleCore/ParticleSystem.swift  `case mapSequence` (before)
/// 스프라이트시트 프레임 선택(스폰 시 확정). between=false: CP0 기준 각도 → 시퀀스,
/// true: CP0→CP1 구간 투영 → 시퀀스. count=시퀀스 길이(시트 프레임 수와 다를 수 있음 — mirror 폴드).
case mapSequence(count: Float, mirror: Bool, between: Bool)
```
```swift
// (after)
/// **위치 이니셜라이저다 — 스프라이트 프레임과 무관하다**(docs/re/particle-control-points.md §5).
/// 실물 핸들러 0x14023ca93(between) / 0x14023c4cf(around) 가 만지는 SoA 슬롯은
/// 위치 +0x2b0/+0x2b8/+0x2c0 · 속도 +0x2c8/+0x2d0/+0x2d8 · 기준 size +0x278 뿐이고
/// 시퀀스 슬롯 +0x268 은 **한 번도 안 쓴다**(전수 확인).
/// `count` 는 시트 프레임 수가 아니라 **시퀀스 스텝 수**이고, 레코드에 남는 누산기 t 가
/// 스폰마다 1/(count−1) 씩 전진한다(스텝 저장 0x1401ca2af, 누산기 0x1401ca296).
case mapSequence(count: Float, mirror: Bool, between: Bool,
                 boundsMin: Float, boundsSpan: Float,      // 주입 기본 "0 1"
                 cpStart: Int, cpEnd: Int,                  // 주입 기본 0 / 1, ≤7 클램프
                 flags: Int,                                // 주입 기본 0 — 아래 넷의 게이트
                 arcAmount: Float, arcDirection: Vec3,      // 기본 0.3 / (0,1,0)
                 sizeReduction: Float)                      // 기본 0.9
```
> 최소 침습으로 가려면 케이스 시그니처를 흔들지 말고 `ParticleSystemDef` 에 필드를 더하는
> 기존 관례(`mapSequenceAxis`/`mapSequenceArcAmount`)를 따라도 된다. 다만 `controlpointstart`
> /`controlpointend` 는 **이니셜라이저마다 다를 수 있으므로** def 레벨로 올리면 다중 선언에서
> 마지막이 이긴다 — 그 손실을 감수할지는 소유자 판단이다.

```swift
// Sources/WapleCore/ParticleSystem.swift  parseInitializers `case "mapsequencebetweencontrolpoints"` (before)
case "mapsequencebetweencontrolpoints":
    inits.append(.mapSequence(count: injected(i, "count", 32),
                              mirror: (i["limitbehavior"] as? String) == "mirror", between: true))
    mapSeqArcAmount = injected(i, "arcamount", 0.3)
```
```swift
// (after) — 주입 기본값 전수는 0x1401bc080 에서 직접 확인했다(문서 §5.1 표).
case "mapsequencebetweencontrolpoints":
    // bounds 주입 기본 "0 1"(0x1401bc1d0) · limitbehavior "repeat"(0x1401bc2b0) ·
    // controlpointstart 0(0x1401bc35e) · controlpointend 1(0x1401bc3a4) ·
    // flags 0(0x1401bc3b9 `xor r8d,r8d` — **함정 16**: 인접 `mov r8d,1` 은 controlpointend 것) ·
    // arcamount 0.3(0x1401bc3cb) · arcdirection "0 1 0"(0x1401bc3e2) · sizereductionamount 0.9(0x1401bc3f8).
    let b = pvec2OrDefault(i["bounds"], Vec2(0, 1))          // 문자열 "a b"
    inits.append(.mapSequence(count: injected(i, "count", 32),
                              mirror: (i["limitbehavior"] as? String) == "mirror",
                              between: true,
                              boundsMin: b.x, boundsSpan: b.y - b.x,
                              cpStart: min(7, UInt32(bitPattern: Int32(pint(i["controlpointstart"]) ?? 0)) < 7
                                             ? (pint(i["controlpointstart"]) ?? 0) : 7),
                              cpEnd:   min(7, UInt32(bitPattern: Int32(pint(i["controlpointend"]) ?? 1)) < 7
                                             ? (pint(i["controlpointend"]) ?? 1) : 7),
                              flags: pint(i["flags"]) ?? 0,
                              arcAmount: injected(i, "arcamount", 0.3),
                              arcDirection: pvec3(i["arcdirection"]) ?? Vec3(x: 0, y: 1, z: 0),
                              sizeReduction: injected(i, "sizereductionamount", 0.9)))
```

```swift
// Sources/WapleCore/ParticleSimulator.swift  `case let .mapSequence(count, _, between)` (before)
case let .mapSequence(count, _, between):
    let t: Float
    if between { … CP0→CP1 투영 … } else { … CP0 기준 각도 … }
    p.frame = t * max(0, count)
```
```swift
// (after) — between 분기만. 실물 0x14023ca93–0x14023ce53 의 순서를 그대로 옮긴다.
case let .mapSequence(count, mirror, between, b0, bSpan, cpS, cpE, flags, arcAmt, arcDir, sizeRed)
     where between:
    // 시퀀스 누산기 t 는 **이니셜라이저 인스턴스의 상태**다 — Particle 이 아니라 시뮬 쪽에
    // 원소별 슬롯(예: `var mapSeqPhase: [Int: (t: Float, step: Float)]`)이 필요하다.
    // 스텝 = 1/(count−1), 분모 하한 1e-4 (0x1401ca249–0x1401ca29d).
    var (t, step) = phase[opIndex] ?? (0, 1 / max(count - 1, 1e-4))
    guard cpS < def.controlPoints.count, cpE < def.controlPoints.count else { break }
    let A = s3(def.controlPoints[cpS])
    let D = s3(def.controlPoints[cpE]) - A
    let L = simd_length(D), Ls = max(L, .leastNormalMagnitude)
    let d = D / Ls
    var q = p.pos
    if def.flags & 1 != 0 { q -= A }              // 0x14023cb55
    let perpRaw = q - simd_dot(q, d) * d
    let s = b0 + t * bSpan
    let arc = 1 - powf(abs(2 * t - 1), 2)         // 0x14041e350 = powf
    var perp = perpRaw
    if flags & 1 != 0 { perp *= arc }
    var np = perp + A + s * Ls * d
    if flags & 8 != 0 { np += s3(arcDir) * (arc * Ls * arcAmt) }
    p.pos = np
    if flags & 2 != 0 { p.vel *= arc }
    if flags & 4 != 0 { p.size *= (1 - sizeRed) + sizeRed * arc }
    // 누산 + 경계
    t += step
    if t > 1 { if mirror { step = -step; t = 1 - (t - 1) } else { t = 0 } }
    else if t < 0 { step = -step; t = -t }
    phase[opIndex] = (t, step)
    // **p.frame 은 건드리지 않는다.**
```
`around` 분기(`between == false`)의 실물 식도 2026-08-31 후속 라운드에서 옮겼다.
세 기저벡터·CP 3×3·원주 위치·속도·repeat/mirror 상태를 `MapSequenceAroundSolver`가 소비한다.

**무회귀 — [정정 2026-08-21] 이 경고는 성립하지 않는다.** `p.frame` 을 안 쓰게 되면
`p.frame >= 0` 분기가 죽고 시트 인덱스가 `particleSheetFrameIndex` 폴터로 가는 것은 맞다.
그런데 그 분기는 전부 `if !sys.frames.isEmpty` 안에 있고, `sys.frames` 는
`resolveTextureWithFrames(def.material?.textureName)` → `.tex` 의 **TEXS 섹션**에서만 온다.
`mapsequence*` 19선언이 쓰는 텍스처 다섯 종에는 TEXS 가 **없다**(양성 대조: 같은 트리의
`.tex` 311개 중 52개는 TEXS 를 갖는다). → **도달 0건, 그림 변화 0.** 자세한 수치는 §9 세 번째
라운드 블록.

**그러나 위치 대입 배선은 별개로 그림을 바꾼다** — 아래 `after` 스케치는 파티클을 실제로
선분 위로 옮기고, 동봉 12선언 중 8선언이 `flags & 4` 로 크기를 양 끝에서 10% 까지 줄인다.
그쪽은 A/B 캡처가 필요하다(맥 절차는 §9).

**[2026-08-31 해소]** 아래 `after` 중 **산술·페이로드 파스·between 시뮬 배선이 모두 들어갔다** —
`MapSequenceBetweenSolver`(`ParticleSimulator.swift`) · `MapSequenceBetweenSpec` /
`MapSequenceAroundSpec` + `def.mapSequenceBetween` / `def.mapSequenceAround`
(`ParticleSystem.swift`). 케이스 시그니처는 **안 바꿨다** — 페이로드를 def 배열에 실었으므로
`SceneRendererResources.swift` 의 `if case .mapSequence(_, true, _)` 패턴이 그대로 산다.
시뮬은 선언별 solver 슬롯을 보존하며 `p.frame`은 건드리지 않는다. between의 두 번째 스트림
opcode 4와 동적 CP 피드도 2026-08-31 후속 라운드에서 연결됐다. around 위치·속도 산식도 같은 날
해소됐고, **남은 것은 around 보조 스트림 opcode 3/10 의미**다.

### P2. `ChildLink.controlPointStartIndex` 소비 배선 — **부분 해소(2026-08-31)**

`ParticleSimulator.stepChildren`가 링크 `flags & 1`일 때 매 프레임 부모 파티클 위치를 자식의
런타임 CP 작업 배열에 공급한다. `ParticleControlPointMath.childControlPointFeed`가 슬롯 선택을
맡고, 자식 시뮬레이터는 이전/현재 배열을 함께 보존한다.

**규약**(§6): 자식 링크 `flags & 1` 일 때만, 자식 시스템의 CP 슬롯
`startIndex … 7` 에 **부모의 살아 있는 파티클 위치**를 순서대로 채운다.
그 슬롯들은 저작 CP 를 덮고, `flags & 0x10005` 인 CP 는 건너뛴다.
자식 CP 개수는 8 로 강제된다(`0x14022ccda`).

**현재 소비자**는 세 부류다.

- `mapsequencebetweencontrolpoints`: 스폰 때 현재 CP[start/end]를 직접 읽는다. thunderbolt
  spawner→beam 체인의 실제 동적 두 끝점이 이 경로를 탄다.
- CP 입력 `remapvalue`: `remapCP`가 정적 def 대신 런타임 배열을 읽는다.
- `maintaindistancebetweencontrolpoints`: 직전 선분에서 구한 축 비율과 수직 성분을 현재 선분으로
  옮긴다. 정적 CP는 종전 clamp fast path를 유지한다.

통합 테스트는 실제 링크 토폴로지의 `x=[0,50,100]` 배치와, 선분 `0→110`이 `0→120`으로
움직일 때 중간 파티클 `x=55→60`·수직 성분 보존을 잠근다.

**후속 해소(2026-08-31)**: `controlpointattract`·`vortex`·
`maintaindistancetocontrolpoint`·`reducemovementnearcontrolpoint`는 정적 target에
`runtime CP - def CP` 이동분을 합성하는 공통 resolver를 쓴다. 따라서 부모 파티클
피드와 scene `controlpointN` 키프레임을 포함한 동적 CP가 베이크형 소비자에도
즉시 반영된다. **남은 경계는 하나**다: 정적 부모→자식 프레임은 번들의
world/world와 identity bridge까지 위치·회전을 전달하지만, 비항등 mixed-space의
transform-stack 4×4 bridge는 같은 좌표계 직접 전달 근사다.

### P3. `ParticleSystemDef.controlPointAngles` 의 `[미해결]` 을 닫는다

`ParticleSystemDef.controlPointAngles` 와
`ParticleInstanceOverride.controlPointAngles`(둘 다 `ParticleSystem.swift`)의 "소비처 미확정" 은
**닫힌다** — 소비처는 두 곳이다:
1. **이미터 VM** `0x140237c42`–`0x140237c86` / `0x1402384c8`–`0x140238502` (4×4 전체)
2. **이니셜라이저 opid 13** `mapsequencearoundcontrolpoint` 의 3×3 기저 변환
   (`0x14023c537` → `0x14023c577`/`0x14023c58e`/`0x14023c5a5`)

다만 **[확정] 파티클 `.json` 의 `controlpoint[].angles` 는 런타임 base 행렬에 반영되지 않는다**
(생성자 `0x14022c3c0` 이 회전 3행에 항등을 넣는다 — §2.1). 살아 있는 것은 **씬 쪽
`controlpointangleN`** 뿐이다. 구현은 이 둘을 분리해 정적/동적 scene angle만 live frame에 넣는다.
동봉 `controlpoint[].angles` 저작 **0건**이라 그림 변화는 없다.

**[구현 2026-08-31]** 정적 scene override 각도는 별도 `controlPointFrameAngles`에 들어가 두 소비자
모두에 배선됐다: opid 13과 sphere/box emitter spawn. 파티클 본문 `controlpoint[].angles`는 계속
보존만 하고 두 소비자에는 넣지 않는다. `instanceOverrideAnimations`의 위치·각도는
`ParticleSimulator` 시계에서 매 스텝 평가되고, 최초 생성·캡처·seek 재생성이 같은 트랙을
받는다. 남은 것은 object-world/parent/pointer를 포함한 동적 active 행렬 합성이다.

### P4. 문서 정정 (`docs/re/particle-operator-vm.md` §7)

"`0x14024f2d0` = 컨트롤포인트 스냅샷 **44바이트** 복사" → **0x40(64)바이트**.
그리고 "`0x14022a120` = 컨트롤포인트 객체(`rcx`)의 월드 위치 `+0x30/+0x34/+0x38`" 는 맞다.
CP 레코드에 4×4 가 셋(현재/직전/base) 있다는 것을 §1 로 링크해 두면 좋다.

---

## 10. 재현

```bash
SC=<scratchpad>
python3 - <<'PY'
import sys; sys.path.insert(0, "$SC")
from wpe import pe, primary, merged, DATA
from vdis2 import dis
import struct

# ① 이니셜라이저 점프테이블 16개
o = pe.va2off(0x14023fa78)
for i in range(16):
    print(i+1, hex(pe.imagebase + struct.unpack_from('<I', DATA, o+i*4)[0]))

# ② mapsequencebetweencontrolpoints 런타임 전문
dis(0x14023ca93, 0x14023ce53)

# ③ 자식 CP 피드
dis(0x14022a580, 0x14022a898)

# ④ instanceoverride → CP base
dis(0x14022bd40, 0x14022c1d0)
PY
```

CP 스트라이드 전수(67곳):
```bash
python3 -c "
import sys; sys.path.insert(0,'$SC')
from zscan import scan
from wpe import primary
for va,l in scan(r'imul \w+, \w+, 0xd0'):
    p=primary(va); print(hex(va), hex(p[0]) if p else '?', l)"
```

오퍼레이터 VM 이 CP 스냅샷의 어느 오프셋을 읽는지(= 위치뿐임을 확인):
```bash
python3 -c "
import sys,re; sys.path.insert(0,'$SC')
from vdis2 import dis
ls=dis(0x14023fbc0,0x14024be38,show=False)
d=set()
for i,l in enumerate(ls):
    if 'call 0x14024f2d0' in l:
        for j in range(i-1,max(0,i-12),-1):
            m=re.search(r'lea rcx, \[rbp \+ (0x[0-9a-f]+)\]', ls[j])
            if m: d.add(int(m.group(1),16)); break
hits={}
for l in ls:
    for m in re.finditer(r'\[rbp \+ (0x[0-9a-f]+)\]', l):
        v=int(m.group(1),16)
        for b in d:
            if b<=v<b+0x40: hits.setdefault(b,[]).append(v-b)
print({hex(k):sorted(set(v)) for k,v in hits.items()})"
# → 모든 버퍼가 {0x0} 만 (복사 인자 + 0x14022a120 인자, 각 1회)
```

코퍼스 census 는 `$SC/Z_census.py`(관용 파서 `scripts/spec/measure_misc_assets.lenient_json` 재사용).

---

## 11. [미해결] 목록

1. 파티클 `.json` `controlpoint[].angles`(디스크립터 `+0xd0+32i`)를 **읽는** 지점.
   생성자 `0x14022c3c0` 은 안 읽는다. 전수 반증은 못 했다 — 동봉 도달 0 이라 실효는 0.
   **[해소 2026-08-21 · 부분]** §2.1 덧붙임 — 스트라이드 `0x20` 인덱서를 이미지 전수로
   **3함수**(파서 2자리 · 생성자 1자리)까지 좁혔다. 언롤 상수 접근만 남았다.
2. `mapsequencebetweencontrolpoints` 의 `[sys+0x20] & 1` 게이트(`0x14023cb55`)가 왜
   수직 성분 기준점을 바꾸는지(월드/로컬 구분으로 보이나 확증 없음).
3. ~~`mapsequencearoundcontrolpoint`(opid 13)의 **페이로드·런타임 산술 전수**~~ —
   **[해소 2026-08-31, §5.3]**
   페이로드 지도(`+0x00` 스텝 · `+0x04` t · `+0x08/+0x0c` bounds · `+0x10..0x18` `speedmin` ·
   `+0x1c..0x24` `speedmax` · `+0x28/+0x34/+0x40` 기저 · `+0x4c` mirror · `+0x50` controlpoint)와
   `speedmin`/`speedmax` 의 소비처(핸들러 `[r14+0x14..0x1c]`/`[r14+0x20..0x28]`, 균일난수 3드로와
   혼합) · 주입 기본(**둘 다 `"0 0 0"`**)까지 확정했다. 위치·속도·CP 프레임·RNG 호출 순서와
   repeat/mirror 상태식도 production solver로 옮겼다. 파스가 `flags` 를 안 읽는데
   `0x1401ca184` 가 `+0x54` 를 읽는 모순은 아래 3b의 보조 스트림 문제로만 남는다.
3b. ~~`[rsp+0x30]` 스트림의 VM과 `between` opcode 4 효과~~ —
   **[해소 2026-08-31 · between, §5.4]** 소비자는 `FUN_1401d15a0`이고 opcode 4는
   `step = 1/max(authoredCount*instanceoverride.count−1, 1e-4)`를 opid 14 페이로드에 다시 쓴다.
   팩토리 scratch → 디스크립터 → 런타임 시스템의 두 차례 deep copy/rebase와 `count` 멤버
   `+0xd0`까지 닫았다. 동봉 도달 2선언은 둘 다 현재 `instanceoverride.count=1`이라 정적 step과
   같지만, 비기본 override에서 살아 있다.
   **남은 것**: `around`의 opcode 3/10 producer 필드 의미와 §5.3의 `flags` 파스 모순/도달.
4. §6 의 슬롯 정체(막힌 CP 에서 `edx` 미전진)가 의도인지.
   **[해소 2026-08-21 · 부분]** §6 덧붙임 — **동작**은 확정했고(정체가 아니라 "그 뒤로 아무것도
   안 채워짐"), **도달 정정**: 종전 "동봉 도달 0" 은 오측이고 실제로는 **동봉 2파일 / 설치 2파일**
   (`thunderbolt.json` → `thunderbolt_child_spawner.json`)이 걸린다. **의도인지는 여전히 미상.**
5. 이미터 레코드의 파스↔런타임 오프셋 차이 `0x10` 의 복사 지점.
6. 브리프의 "JSON 3,655개" 분모 출처(이 저장소 두 코퍼스 합은 3,841, JSONC 63 은 일치).
7. `arcdirection` 이 **어느 공간**의 벡터인지(시스템 로컬로 보이나 변환 지점 없음 —
   `0x14019d570`(scale) → `0x14019e860`(add) 로 그냥 더한다. 즉 **로컬 축 그대로**로 보이지만
   오브젝트 회전과의 관계는 확인 못 했다).
8. `[sys+0x3f7]` 바이트(`0x14022be77`, `0x14023641b`, `0x1402364bc`)의 의미 —
   자식 CP 피드와 같은 경로에서 전파되는데 소비처를 못 짚었다.

> **[2026-08-21 · 레인 BJ] 위 8건 밖에서 새로 확정한 것은 §12 에 있다** — CP 슬롯 상한 8,
> `flags` bit1 의 의미(월드 저작), bit16 을 파서가 세우는 규칙, 마우스 역투영 전문,
> `locktopointer` 가 죽은 키라는 것, 그리고 §8.3 이 bit1 을 빠뜨린 자기모순.
> 소유 밖 패치안은 §13.

---

## 12. [2026-08-21 · 레인 BJ] 갭 도달표와 새로 확정한 것

> 이 절의 VA 는 **전부 이 레인에서 `.pdata` 함수 시작부터 선형으로 다시 떴다**
> (함정 14·15). 코퍼스 수치는 관용 파서(`scripts/spec/measure_misc_assets.lenient_json`)로
> 동봉 1,698 `.json` · 설치본 2,143 `.json` 을 전수 재측정한 것이다.
> **워크샵 코퍼스는 이 컨테이너에 없다 — 워크샵 도달은 0 이 아니라 미측정이다**(함정 19).

### 12.0 문서가 남긴 갭 15건 — 도달 순

도달은 "이 사실이 틀리면 몇 개의 실물 자산이 달라지나" 다. 범위는 **동봉 `WEAssets`**
(파티클류 `.json` 289 · CP 원소 1,816) / **설치본**(296 · 1,856) 두 코퍼스다.

| # | 갭(문서 위치) | 도달(동봉 / 설치) | 이 라운드 |
| ---: | --- | --- | --- |
| 1 | §11-2 `mapsequencebetween` 의 `[sys+0x20]&1` 게이트 의미 | **12 선언 / 12** (between 전건) | **간접 해소** — 같은 비트의 의미를 §12.2 에서 확정했다(시스템 worldspace). 이 핸들러에서 왜 `p −= A` 를 그 비트로 가르는지는 여전히 미상 |
| 2 | §11-1 파티클 `.json` `controlpoint[].angles` 를 읽는 지점 | `angles` 저작 **0 / 0** (실효 0) | **부분 해소** — 스트라이드 `0x20` 인덱서를 이미지 전수로 3함수까지 좁혔다(§2.1 덧붙임) |
| 3 | §11-4 자식 CP 피드 슬롯 정체가 의도인가 | **2 파일 / 2** ← 종전 "0" 은 **오측** | **도달 정정 + 동작 확정**(§6 덧붙임). 의도는 미상 |
| 4 | §11-3b `[rsp+0x30]` 스트림의 VM | between bit4 **2 선언 / 2**, around 게이트 미상 | **between 해소** — `FUN_1401d15a0` opcode 4, `step=1/max(authoredCount*instanceoverride.count−1,1e-4)` (§5.4). around 3/10은 남음 |
| 5 | §5.4 around 쪽 두 번째 스트림 게이트의 도달 | 미상(§11-3b′ 에 종속) | 손대지 않음 |
| 6 | §11-3a `speedmin`/`speedmax` 혼합 대수식 | **2 선언 / 2** (`magic_trinity`) | 손대지 않음 |
| 7 | §11-3b(신규) around 파스가 `flags` 를 안 읽는데 `0x1401ca184` 가 `+0x54` 를 읽는 모순 | **7 선언 / 7** | 손대지 않음 |
| 8 | §11-5 이미터 레코드 파스↔런타임 오프셋 `0x10` | `emitter[].controlpoint` **6 선언 / 6** | 손대지 않음 |
| 9 | §11-7 `arcdirection` 이 어느 공간인가 | between `flags & 8` **4 선언 / 4** | 손대지 않음 |
| 10 | §11-8 `[sys+0x3f7]` 바이트의 의미 | 자식 CP 피드 링크 **4 / 4** | 손대지 않음 |
| 11 | §9 P1-④ 위치 대입 배선 미적용 | between **12 선언 / 12** | 손대지 않음(A/B 캡처 불가 — Metal 없음) |
| 12 | §9 P1-⑤ `p.frame` 대입 삭제 | **0**(도달 0 이 이미 증명됨) | 손대지 않음(소유 밖 테스트) |
| 13 | §9 P2 자식 CP 피드 **소비** 배선 | **4 링크 / 4** | 손대지 않음(`bakeControlPointTargets` 구조 변경이 먼저) |
| 14 | §11-6 브리프 분모 3,655 의 출처 | 코드 도달 0(장부 문제) | 손대지 않음 |
| 15 | §9 P1 의 around 런타임 산술 미이식 | **7 선언 / 7** | 손대지 않음 |

**이 라운드가 실제로 닫은 것은 위 표보다 위쪽에 있다.** 15건 중 도달이 두 자리를 넘는 것은
1·11(12 선언) 뿐인데, 둘 다 **화면이 바뀌는 배선**이라 이 컨테이너에서는 A/B 를 못 뜬다.
그래서 도달 기준을 "CP 사실 전체"로 넓혀 다시 세고, 아래 넷을 확정했다 — 각각
**245 파일 / 28 원소 / 10 원소 / 16 원소**에 걸린다.

### 12.1 [확정] CP 슬롯 상한은 **8** — 근거 셋이 같은 수를 준다

1. **파서가 디스크립터 배열을 `0x100` 바이트로 0-메모리셋한다.**
   ```
   0x1401d04d8  lea  rcx, [r13 + 0xa4]
   0x1401d04df  xor  edx, edx
   0x1401d04e1  mov  r8d, 0x100
   0x1401d04e7  call 0x1404217a0            ; memset
   ```
   `0x100 / 0x20`(슬롯 스트라이드, `shl rdi, 5` @`0x1401d0593`) = **8**.
2. **파스 루프가 고정 8회다.** `inc r14d` / `cmp r14d, 8` / `jl 0x1401d0530`
   (`0x1401d0807`–`0x1401d080e`). 배열 **길이를 읽지 않고** `operator[](i)`(`0x140086540`)를
   8번 부른 뒤 태그 7(object)이 아니면 그 자리를 건너뛴다(`cmp byte [rax+8], 7` @`0x1401d053e`).
   → **9번째 이후 원소는 파스조차 안 된다.**
3. **씬 프로퍼티백 등록부가 정확히 8+8 개다** — 문자열 전수:
   `controlpoint0`(`0x140491408`) … `controlpoint7`(`0x1404914f8`),
   `controlpointangle0`(`0x140491490`) … `controlpointangle7`(`0x140491508`).
   `controlpoint8` 도 `controlpointangle8` 도 이미지에 **없다**.

그리고 자식 CP 피드가 켜지면 개수가 **강제로 8** 이 된다(`mov dword [r12+0x44], 8` @`0x14022ccda`).

**도달**: `controlpoint[]` 를 가진 파일 **동봉 245 / 설치 250**. 길이 분포는
동봉 `8`×220 · `2`×19 · `3`×6, 설치 `8`×225 · `2`×19 · `3`×6 — **최댓값이 8**이라
상한을 넘는 저작은 두 코퍼스에 **0건**이다(워크샵은 미측정).

**부수 [확정]**: 파스 루프는 `"id"` 를 **한 번도 읽지 않는다**. 슬롯은 배열 위치다.
읽는 키는 넷뿐 — `offset`(`0x1401d05b6`) · `flags`(`0x1401d058c`) ·
`angles`(`0x1401d06ce`) · `parentcontrolpoint`(`0x1401d07eb`).

### 12.2 [확정 — 신규] CP 의 좌표계: `flags` bit1 은 **"이 CP 의 `offset` 은 월드 좌표"** 다

기본 갱신 `0x14022a070`–`0x14022a117` 을 전수로 뜨면 네 갈래다:

```
0x14022a08c  mov  r9d, [rbx + 0xc0] ; and r9d, 2      ; CP flags bit1
0x14022a097  je   A
0x14022a099  test edx, edx ; je A                     ; idx == 0 이면 A (예외)
             jmp  B
A: 0x14022a0a3  test byte [rcx + 0x20], 1             ; 시스템 flags bit0 = worldspace
   0x14022a0ab  je   C
   0x14022a0bc  call 0x14024f0e0(dst, rdx = 오브젝트 월드 4×4, r8 = CP+0x80)
   0x14022a0c4  CP+0x00..0x3f = dst ; return true      ; cur = base × objectWorld
C: 0x14022a0ea  test r9d, r9d ; je 0x14022a10d(return false)
B: 0x14022a0ef  test byte [rax], 1 ; jne 0x14022a10d(return false)
   0x14022a0fc  call 0x1402290d0(rcx = 오브젝트 월드, rdx = out)   ; 4×4 역행렬
   0x14022a10b  jmp  0x14022a0b5                       ; cur = base × inverse(objectWorld)
```

| 시스템 worldspace(`[sys+0x20]&1`) | CP bit1 | 결과 |
| --- | --- | --- |
| 예 | 아니오 | `cur = base × objectWorld` (로컬 → 월드) |
| 예 | 예 | **갱신 없음** (둘 다 월드) |
| 아니오 | 예 | `cur = base × inverse(objectWorld)` (월드 → 로컬) |
| 아니오 | 아니오 | **갱신 없음** (둘 다 로컬) |

즉 **공간이 어긋날 때만 변환한다**. 갱신을 건너뛰면 `cur` 은 생성자가 넣은 base 사본 그대로다
(`0x14022ced9`–`0x14022cf4a`) — 함정 13 그대로, 실패 분기가 `false` 가 아니라 **생성자 기본값**을 남긴다.

`0x1402290d0` 이 역행렬인 근거: `0x1402290e2`부터 `[rcx]`/`[rcx+0x10]`/`[rcx+0x20]`/`[rcx+0x30]`
네 행을 `shufps` 로 섞어 여인수를 만드는 고전 SSE 4×4 역행렬이다(`primary` = `0x1402290d0`–`0x140229318`).
`[obj+0x30]` 이 변환 스택 top(= 부모 체인이 다 곱해진 월드행렬)인 것은 `docs/re/particle-world-basis.md` §2 에 이미 재 있다.

**그래서 CP 좌표는 정규화 좌표가 아니다 — 씬/오브젝트 단위다.**
저작값이 그대로 증거다: `"450 0 0"`(discharge) · `"0 -450 0"`(thunderbolt) · `"512 512 0"`(previewdischarge).

**예외 하나**: `idx == 0` 이면 bit1 이 서 있어도 A 로 간다(`test edx, edx` @`0x14022a099`).
**동봉·설치 도달 0** — bit1 저작 10건이 전부 `idx == 1` 이다.

**도달 10 CP 원소 / 1,816**(설치본 10 / 1,856):
`discharge` · `dischargearc`(×3) · `thunderbolt`(×2) — 시스템 `flags: 0` 이라 **역행렬 경로** ·
`water_faucet`(×2) · `water_faucet_large`(×2) — 시스템 `flags: 1` 이라 **갱신 없음**.

### 12.3 [확정 — 신규] bit16 은 저작 키가 아니라 **파서가 세운다**

```
0x1401d0860  mov  ecx, [rbx + 0x10]                  ; 수집된 출력 CP id
0x1401d0863  cmp  ecx, 8 ; jae 0x1401d0878           ; 8 이상은 무시
0x1401d0868  shl  rcx, 5
0x1401d086c  or   dword [rcx + r13 + 0xa4], 0x10000  ; = cp[id].flags |= bit16
0x1401d0878  mov  rbx, [rbx] ; cmp rbx, rax ; jne 0x1401d0860
```
수집 자리는 둘이다 — `remapvalue` `0x1401cf05d`–`0x1401cf07e`,
`remapinitialvalue` `0x1401cafc2`–`0x1401cafe0`. 게이트는 **`0x1401bc470`**:
```
0x1401bc470  cmp ecx, 0x10 ; sete al ; ret
```
즉 **출력 채널이 `controlpoint`(표 인덱스 16)일 때만** 넣고, 넣는 값은 둘 다
**`outputcontrolpoint0`**(≤7 클램프)다 — `remapvalue` 는 `[rsi+0xe4]`(`lea r8` @`0x1401cf069`),
`remapinitialvalue` 는 `[rdi+0x4c]`(`lea r8` @`0x1401cafce`).
두 레코드의 네 슬롯은 각각 `remapvalue` `0xe0/0xe4/0xe8/0xec` ·
`remapinitialvalue` `0x48/0x4c/0x50/0x54` 이고 순서는 in0 · out0 · in1 · out1 이다
(클램프 자리 `0x1401caeb5`–`0x1401caecf` · `0x1401caf6d`–`0x1401caf87`).

> 형제 술어 `0x1401bc480` 은 `{7,8} ∪ {16,17,18}` 을 참으로 준다 —
> `distancetocontrolpoint`·`positionbetweentwocontrolpoints`·`controlpoint`·
> `deltatocontrolpoint`·`directiontocontrolpoint`. 그쪽은 **CP 개수 상향**용이다
> (`[r13+0x2c] = max(현재, in+1, out+1)`, `0x1401cef6d`–`0x1401cef8f`).
> **함정 16 자리**: `[rsi+0xe0]` 은 인접 `lea "outputcontrolpoint0"`(`0x1401ceef9`)의 것이
> 아니라 **직전** 키 `inputcontrolpoint0` 의 값이다. 순서는 `0xe0`=in0 · `0xe4`=out0 ·
> `0xe8`=in1 · `0xec`=out1.

**도달 0 / 0**: 두 코퍼스에서 `remapvalue`/`remapinitialvalue` 의 `output` 값은
`color`·`opacity`·`velocity`·`speed` 뿐이고 `"controlpoint"` 는 **0건**,
`outputcontrolpoint0/1` 키 저작도 **0건**이다. → **Waple 이 bit16 을 안 세워도 지금 그림은 안 바뀐다**
(`ParticleSystem.swift` 의 `[미해결] bit16 은 Waple 이 아직 세지 않는다` 는 규칙이 확정됐으니
 이 근거로 닫을 수 있다 — 패치안은 §13).

### 12.4 [확정] 마우스가 들어오는 자리 — bit0 슬롯, **평행이동 행만**

`0x14022e472`(`test dl, 1`) 갈래 전문:

```
0x14022e47b..0x14022e4ae  base(+0x80..0xbf) → cur(+0x00..0x3f)         ; 네 행 통째 복사
0x14022e4ba  xmm8 = [ctx + 0x8c]            ; 포인터 x (정규화 0..1)
0x14022e4c3  xmm7 = 1.0 - [ctx + 0x90]      ; 포인터 y (뒤집는다)
0x14022e514/0x14022e51f  ×2   0x14022e535/0x14022e53f  −1.0
                                            ; ndc = (2x−1, 1−2y)
0x14022e4d3  call 0x14005ecb0([ctx+0x38], [ctx+0x40])   ; view·proj
0x14022e4e0  call 0x14005f730([rsp+0x20], rax)          ; 역행렬
0x14022e54f..0x14022e59c  (ndc.x, ndc.y, 0, 1)·M 뒤 x/w, y/w          ; **z 는 계산 안 한다**
0x14022e4e5  test byte [r14 + 0x20], 1 → 0x14022e5a1 jne 0x14022e64a
   서면   0x14022e64a  (x, y, z) = (u, v, 0)                          ; 시스템이 이미 월드
   안 서면 0x14022e5a7  M2 = inverse([ctx+0x30]) ; (u, v, 0, 1)·M2     ; 오브젝트 로컬로 내림
0x14022e656..0x14022e662  CP +0x30/+0x34/+0x38 = 그 점
```

**회전 3행은 이 경로에서 한 번도 안 건드린다** — base 복사분(= `controlpointangleN` 이 만든 회전)이
그대로 남는다. 그래서 마우스 CP 도 `controlpointangleN` 의 회전을 유지한다.

**[확정] CP 로 들어오는 외부 입력은 마우스뿐이다.** 마스터 갱신 `0x14022e3e0`–`0x14022ebde`
전문에서 `call` 대상은 **다섯**뿐이다 — `0x14005ecb0`(4×4 곱) · `0x14005f730`(역행렬) ·
`0x1402290d0`(역행렬) · `0x14022a070`(기본 갱신) · `0x14024f0e0`(4×4 곱).
**오디오·시간·난수 호출이 0건**이다. 오디오는 `remapvalue` 입력 채널로 파티클에 닿지,
CP 슬롯으로 들어오지 않는다.

> **정확히 하자.** 위 문장은 **CP 레코드(`+0x00..0x3f`)에 매 프레임 값을 넣는 경로** 이야기다.
> **base(`+0x80..0xbf`)에는 입력이 하나 더 있다** — 씬 스크립트다.
> `spec/engine/script-api.json` 의 `0x14024d940` 등록부는 `IParticleSystemInstance` 로
> `alpha` · `colorn` · **`controlpoint0..7`** · `count` · `lifetime` · `rate` · `size` · `speed`
> **15개**를 노출한다. 스크립트가 쓰면 §7.2 의 런타임 세터(`+0x48` = `0x1401a4530`)를 거쳐
> 프로퍼티백에 절대 대입되고 더티 비트(`0x14022ab30` → `obj+0x928`)가 서서
> `0x14022bd40`(§2.2)이 다시 돈다. 애니메이션 `{animation}` 바인딩과 **같은 통로**다.
> **`controlpointangle*` 는 스크립트 API 에 없다** — 씬 json 저작으로만 들어온다.

**도달 28 CP 원소 / 1,816**(설치본 28 / 1,856) — `examplecursorfollow` · `examplecursoravoid` ·
`interactive/trail_0..2` · `fireflies` · `bubbles1` · `vapor0`/`vapor1`/`vapor1_child` ·
`powerup` · `dust_motes_0` · `dna` · `magic_vortex_orb` · `exampleturbolence` 등.

### 12.5 [확정 — 신규] `controlpoint[].locktopointer` 는 **죽은 키**다

WE 설치본 트리의 **`.json` 이 아닌 파일 3,995개**를 ASCII · UTF-16LE · 대소문자 무시로
전수 스캔해 `locktopointer` 히트 **0건**(함정 8·11 — 바이너리 하나로 판단하지 않았다).
문자열은 오직 자산 `.json` **2파일**에만 있다 —
`particles/exampleturbolence.json` · `particles/exampleturbolence3d.json`(합 **16 원소**).

**그래서 관측 가능한 갈림이 하나 생긴다**:
`exampleturbolence3d.json` 의 CP 1 은 `locktopointer: true` 인데 `flags: 0` 이라
**실물은 마우스를 안 따라간다**. 형제 `exampleturbolence.json` 의 CP 1 은 `flags: 1` 이라 따라간다.
`locktopointer` 를 읽는 구현은 그 두 파일에서 실물과 갈린다.

### 12.6 [확정] 디스크립터 기본값은 전부 **0** — 실패 분기가 남기는 것도 0이다

파서는 `memset(def + 0xa4, 0, 0x100)`(§12.1)으로 시작한다. 그 위에:

| 키 | 주입기 | 소비 | 저장 | 태그 게이트 |
| --- | --- | --- | --- | --- |
| `offset` | `H_STRING`(`0x1401d7e80`) 기본 `"0 0 0"`(`0x14048f4d4`) | `strtod`×3 | `+0xac/0xb0/0xb4` | **문자열(태그 4)일 때만** `0x1401d05c5` |
| `flags` | `0x1401d8280` 기본 0 | `asUInt`(`0x140085f70`) | `+0xa4` | 없음(불리언도 1/0 — 함정 17) |
| `parentcontrolpoint` | `0x1401d8280` 기본 0 | `asInt` | `+0xa8` | 없음 |
| `angles` | **없다** | `strtod`×3 | `+0xb8/0xbc/0xc0` | **문자열일 때만** `0x1401d06da` |

**함정 13 실사례가 코퍼스에 있다**: 동봉 `presets/lightning/.../thunderbolt_fizzle.json` 의 CP 1 은
`"offset": null` 이다 → 태그 4 검사에 걸려 저장이 **안 되고** 메모리셋 0 이 남는다 → `(0,0,0)`.
`offset` 부재는 동봉 **59 원소**(1,816 − 1,757), `flags` 부재 **36**, `parentcontrolpoint` 부재 **1,708**.

### 12.7 [확정] 규약은 **행 우선 · 행벡터** — 값으로 판정했다

함정 12 대로 레이아웃이 아니라 **쪼개는 지점**을 봤다. 두 자리가 같은 답을 준다:
- 마우스 점 변환 `0x14022e5b8`–`0x14022e643` 이 `out = u·row0 + v·row1 + 0·row2 + row3` 을
  성분별로 펼친다(`[rsp+0x20]`=row0.x, `[rsp+0x30]`=row1.x, `[rsp+0x40]`=row2.x, `[rsp+0x50]`=row3.x).
- 곱셈기 `0x14024f0e0`(`0x14024f191`–`0x14024f210`)이
  `dst.row0 = A[0][0]·B.row0 + A[0][1]·B.row1 + A[0][2]·B.row2 + A[0][3]·B.row3` 다.
  호출 규약은 `0x14024f0e0(rcx = dst, rdx = B, r8 = A)` → **`dst = A × B`**.
  그래서 `0x14022a0bc` 의 `r8 = CP+0x80`, `rdx = 오브젝트 월드` 는 `cur = base × objectWorld` 다.

씬 `controlpointangleN` 이 만드는 3×3(스토어 순서까지 그대로, `0x14022bf53`–`0x14022c069`):
```
+0x80 = cos(y)cos(z)                     +0x84 = cos(y)sin(z)                     +0x88 = -sin(y)
+0x90 = sin(x)sin(y)cos(z)-cos(x)sin(z)  +0x94 = sin(x)sin(y)sin(z)+cos(x)cos(z)  +0x98 = sin(x)cos(y)
+0xa0 = cos(x)sin(y)cos(z)+sin(x)sin(z)  +0xa4 = cos(x)sin(y)sin(z)-sin(x)cos(z)  +0xa8 = cos(x)cos(y)
```
= 행벡터 규약의 `Rx·Ry·Rz`(열벡터로 읽으면 `Rz·Ry·Rx` — 같은 행렬). 라디안이고 파일 순서는 `(x,y,z)`.
부호 반전은 `xorps xmm1, xmm14` @`0x14022bfe1`(`xmm14 = -0.0`, 적재 `0x14022bed8` ← `0x140492ff0`),
센티널은 `xmm12 = FLT_MAX`(적재 `0x14022bec6` ← `0x14049297c`).

### 12.8 이식물

위 산술은 전부 `Sources/WapleCore/ParticleControlPointFrame.swift` 로 뽑았다
(Foundation 만 — `import simd` 없음). 회귀는
`Tests/WapleCoreTests/ParticleControlPointFrameTests.swift` 가 값으로 잠근다.
**배선(파스·시뮬·렌더)은 이 레인의 소유가 아니라 §13 에 패치안으로 넘긴다.**

### 12.9 재현

```bash
SC=<scratchpad>
python3 - <<'PY'
import sys; sys.path.insert(0, "$SC")
from vdis2 import dis
dis(0x14022a070, 0x14022a118)     # ① 기본 갱신 네 갈래(§12.2)
dis(0x14022e3e0, 0x14022ebde)     # ② 마스터 갱신 전문(§12.4) — call 대상 다섯 확인
dis(0x14022c3c0, 0x14022cf93)     # ③ 생성자: 디스크립터 다섯 읽기 + 항등 네 행
dis(0x1401d04d8, 0x1401d0880)     # ④ CP 파스 루프(§12.1) + bit16 표시(§12.3)
PY
```

스트라이드 `0x20` 인덱서 전수(§2.1 덧붙임의 근거):
```bash
python3 -c "
import sys; sys.path.insert(0,'$SC')
from wpe import pe, DATA, primary
h=[pe.off2va(i) for i in range(len(DATA)-4)
   if DATA[i] in (0x48,0x49) and DATA[i+1]==0xC1 and 0xE0<=DATA[i+2]<=0xE7 and DATA[i+3]==0x05]
f={}
for va in h:
    p=primary(va)
    if p: f.setdefault(p[0],[]).append(va)
print(len(h),'자리 /',len(f),'함수')
for k in (0x1401c5490, 0x14022c3c0): print(hex(k), [hex(v) for v in f.get(k,[])])"
# → 424 자리 / 139 함수, 0x1401c5490 = [0x1401d0593, 0x1401d0868], 0x14022c3c0 = [0x14022cdd8]
```

코퍼스 재측정:
```bash
python3 - <<'PY'
import os, sys, collections
sys.path.insert(0, "/home/user/Waple/scripts/spec")
from measure_misc_assets import lenient_json
for root in ["Sources/WapleRender/Resources/WEAssets",
             "/home/user/Waple-wallpaper-source/wallpaper_engine"]:
    lens, flags, keys = collections.Counter(), collections.Counter(), collections.Counter()
    for dp, dn, fn in os.walk(root):
        for f in fn:
            if not f.endswith(".json"): continue
            d = lenient_json(open(os.path.join(dp, f), "rb").read())
            if not isinstance(d, dict): continue
            cps = d.get("controlpoint")
            if not isinstance(cps, list): continue
            lens[len(cps)] += 1
            for e in cps:
                if isinstance(e, dict):
                    flags[repr(e.get("flags"))] += 1
                    for k in e: keys[k] += 1
    print(root, dict(sorted(lens.items())), dict(flags.most_common()), dict(keys.most_common()))
PY
```

---

## 13. [2026-08-21 · 레인 BJ] 넘길 것 — 소유 밖 패치안

아래는 전부 **이 레인의 소유가 아니다**(`ParticleSystem.swift` / `ParticleSimulator.swift` 는
같은 시각 다른 레인이 고치고 있었다). 고치지 않았다.

### 13.1 `ParticleSystem.swift` — bit16 `[미해결]` 을 닫는다

현재 주석: `**[미해결]** bit16 은 Waple 이 아직 세지 않는다(remap 출력 CP 표시 미구현).`

규칙이 §12.3 으로 확정됐다. 파스에서 `remapvalue`/`remapinitialvalue` 의 출력 채널이
`.controlPoint`(표 인덱스 16)일 때 `controlPointFlags[clampControlPoint(outputCP0)] |= 0x10000`
을 OR 하면 된다. **도달 0** 이라 그림은 안 바뀐다 — 주석을 규칙으로 갈아 끼우는 것이 요점이다.

`RemapSpec` 이 이미 `outputChannel: RemapChannel` 과 `outputCP0: Int` 를 들고 있으므로
파스 꼬리(`controlPointFlags` 확정 직전, 씬 오버라이드 블록 **앞**)에 이것만 넣으면 된다:

```swift
for op in ops {
    guard case let .remapValueEx(spec) = op,
          spec.outputChannel == .controlPoint else { continue }
    let slot = ParticleControlPointLimits.clampIndex(spec.outputCP0)
    controlPointFlags[slot] |= ParticleControlPointFlag.remapOutput   // 0x1401d086c
}
```
> 실물은 `remapinitialvalue`(이니셜라이저) 쪽도 같은 집합에 넣는다(`0x1401cafce`). Waple 의
> `.remapInitialValue(output: String?, …)` 는 아직 `RemapChannel` 로 파스하지 않으므로
> 그쪽은 문자열 `"controlpoint"` 비교가 필요하다 — **도달 0 이라 급하지 않다.**
> 순서 주의: 실물은 CP `flags` 를 세운 **뒤** 씬 오버라이드 게이트(`0x14022bf26`)가 돈다.
> Waple 에서도 `cpOverrideBlocked` 보다 앞에 두지 않으면 bit16 이 게이트에 안 걸린다.

### 13.2 `ParticleSystem.swift` — `clampControlPoint` 를 공용 상수로

`private static func clampControlPoint(_:)` 가 지금 파일 안에 갇혀 있다. 규약이 같으므로
`ParticleControlPointLimits.clampIndex` 로 위임하면 **부호 없는 클램프**(음수 → 7)가
한 자리에서 잠긴다. 지금 두 구현이 갈리면 아무 테스트도 안 잡는다.

### 13.3 `ParticleSystem.swift` — CP 슬롯 상한을 상수로

`Array(repeating: …, count: 8)` 이 네 자리(`controlPoints` · `controlPointAngles` ·
`controlPointFlags` · `controlPointParent`)에 리터럴 `8` 로 박혀 있다.
`ParticleControlPointLimits.slotCount` 로 바꾸면 §12.1 의 근거가 코드에 붙는다.

### 13.4 `ParticleSystem.swift` — `controlPointAngles` 소비 — **해소(2026-08-31)**

`def.controlPointFrameAngles`와 scene `controlpointangleN` 키프레임을 런타임 CP 3×3 기저로
조립해 sphere/box emitter와 `mapsequencearoundcontrolpoint`(opid 13)이 읽는다.
아래 코드는 구현 전 최소 패치 제안이며, 현행 코드는 동일 규약을
`ParticleControlPointMath` 프레임 헬퍼와 `ParticleSimulator` 런타임 배열로 나누어 구현했다:

```swift
// 지금:  var controlPoints = Array(repeating: Vec3(x: 0, y: 0, z: 0), count: 8)
// 뒤:
var controlPointBases = Array(repeating: CPMatrix4.identity,
                              count: ParticleControlPointLimits.slotCount)
…
controlPointBases[slot] = ParticleControlPointMath.authoredBase(offset: off)   // angles 는 실효 0 (§2.1)
…
// 씬 오버라이드(절대 대체 · 센티널 · 0x10005 게이트)를 한 줄로:
let r = ParticleControlPointMath.applyInstanceOverride(
    base: controlPointBases[id], flags: controlPointFlags[id],
    overrideAngles: ov.controlPointAngles[id] ?? Vec3(x: .greatestFiniteMagnitude, y: 0, z: 0),
    overrideTranslation: ov.controlPoints[id] ?? Vec3(x: .greatestFiniteMagnitude, y: 0, z: 0))
if !r.skipped { controlPointBases[id] = r.base }
```
`bakeControlPointTargets` 는 `controlPointBases[cp].translation` 을 쓰면 지금과 동치다.
**그림 변화**: `controlpointangleN` 저작 씬(동봉 `objects[]` 기준 7 오브젝트)에서만 회전이 붙는다.
회전을 실제로 소비하는 것은 이미터(`0x140237c42` 계열)와 `mapsequencearoundcontrolpoint`
(`0x14023c537`)이므로, 그 둘을 배선하기 전에는 `translation` 만 쓰이고 **그림은 안 바뀐다**.

### 13.5 `ParticleSimulator.swift` — 자식 CP 피드 소비 (§6 · §12.0-3) — **부분 해소**

`ChildLink.flags` / `controlPointStartIndex` 는 이제 파스뿐 아니라 `stepChildren`에서 소비된다.
`ParticleControlPointMath.childControlPointFeed(startIndex:parentLifetimes:childControlPointFlags:)`
가 실물과 같은 슬롯 정체를 계산하고, 각 자식 시뮬레이터의 런타임 CP 배열에 부모 위치를 쓴다.
between·CP remap·이동 선분 유지가 이 배열을 직접 읽는다.

베이크형 attract/vortex/maintain/reduce도 공통 live-target resolver로 전환됐다.
`flags & 4` 부착 자식은 `parentcontrolpoint` 매핑을 통해 부모의 live 위치·각도를
매 스텝 받는다. 남은 것은 비항등 mixed-space 부모→자식 transform-stack 4×4 변환
(`0x14022a5f7`–`0x14022a6a9`)뿐이다. 막힌 슬롯에서 슬롯을 전진시키지 않는 규약은
helper와 회귀 테스트가 잠근다.

### 13.6 마우스 CP (미배선)

Waple 에는 마우스 구동 CP 가 아예 없다 — 동봉 **28 CP 원소**가 정적 CP 로 처리된다.
산술은 `ParticleControlPointMath.pointerControlPointTranslation` 에 있고, 필요한 입력은
① 정규화 포인터 `(x, y)`, ② `inverse(viewProjection)`, ③ `inverse(objectWorld)`,
④ 시스템 worldspace 비트다. 셋 다 `WapleRender` 쪽에 이미 있는 값이라 배선은 얇지만
**화면이 바뀌므로 A/B 캡처가 필요하다**(이 컨테이너에 Metal 이 없다).
