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
**[추정]** 파티클 `.json` 의 `controlpoint[].angles` 는 디스크립터 `+0xd0+32i` 에 파스되어
있지만(파스 측 슬롯 스트라이드 32 는 기존 문서와 일치), **이 생성자가 그 자리를 읽지 않는다.**
**[미해결]** 다른 곳에서 그 12바이트를 읽는 지점은 못 찾았다 — 즉 파티클 `.json` 쪽 `angles` 는
**실효 0** 일 가능성이 높지만 전수 반증은 못 했다. (씬 쪽 `controlpointangleN` 은 §2.2 로
**확실히 살아 있다** — 그쪽은 다른 함수가 `+0x80..0xaf` 를 직접 쓴다.)

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
| `test dl,4`(bit2) | `0x14022e66e` | 부모 시스템(`[sys+0x10]`)의 CP `[parent+0x400] + [CP+0xc4]*0xd0` 에 부착. `[parent+0x44]` 로 경계검사(`0x14022e68b`). `test dl,8`(bit3, `0x14022e6b3`)이면 부모 4×4 를 **그대로 복사**, 아니면 부모 4×4 × 자기 base 를 합성 |
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
> 는 오기다. **0x40 = 64바이트**다(`0x14024f2d0`–`0x14024f32b`, dword 16회). 값에는 영향이
> 없지만 정정해 둔다.

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
파스 측은 `controlpoint` 를 `asInt`(`0x140085f70`) 후 **7 로 클램프**해
`sphererandom` → `[rsi+0xe0]`(`0x1401c600d`), `boxrandom` → `[rsi+0x98]`(`0x1401c6915`) 에 넣는다.
**[추정]** 런타임 오프셋(`+0xf0`/`+0xa8`)이 파스 오프셋보다 정확히 `0x10` 큰 것은 이미터 레코드에
`0x10` 헤더가 붙기 때문으로 보이지만, 복사 지점을 직접 짚지는 않았다.

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

---

## 6. 자식 시스템의 CP 상속 — `controlpointstartindex` [확정]

### 6.1 자식 링크 디스크립터

파스: 대형 팩토리 `0x1401c5490`–`0x1401d152c` 안에서 자식 링크 구조체(`[rbp+0x490]` 기준)를 채운다 —
`flags` → `+0x64`(`0x1401d09be`), `controlpointstartindex` → `+0x68`(`0x1401d09db`,
키 `lea` `0x1401d09c4`, `asInt` `0x140085f70`).

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

**[확정]** 값 `16` 은 **bit4**(0x10)이지 bit16 이 아니다. 런타임이 읽는 비트는
bit0·bit2·bit3·bit16 뿐이므로 이 10건은 **아무 데도 안 걸린다**.
**[확정]** `children[].flags` 에 bit0 이 선 링크가 **4건**이고, `controlpointstartindex` 가
실린 것이 **2건**이다 — §6 의 자식 CP 피드가 실제로 도달하는 자산이 있다.

---

## 9. Waple 대조 — 정확한 패치안

아래 파일들은 **이 클러스터의 소유가 아니다**. 고치지 않았다. 넘긴다.

### P1. `mapsequence*` 는 스프라이트 프레임 선택이 **아니다** (가장 큰 어긋남)

**현상.** `Sources/WapleCore/ParticleSystem.swift:143` 의 주석이
"스프라이트시트 프레임 선택(스폰 시 확정)" 이라고 적고, `ParticleSimulator.swift:1367-1388`
(`case let .mapSequence(count, _, between)`)이 `p.frame = t * count` 만 한다.
`SceneRendererFrameEncoder.swift:123-124` 와 `:264-265` 가 그 `p.frame` 으로 시트 인덱스를 고른다.

**실측.** 실물 핸들러 둘(`0x14023c4cf` around / `0x14023ca93` between)이 만지는 SoA 슬롯을
전수로 뽑으면 `+0x2b0/+0x2b8/+0x2c0`(위치) · `+0x2c8/+0x2d0/+0x2d8`(속도) ·
`+0x278`(기준 size, between 만) 뿐이고 **시퀀스 슬롯 `+0x268` 은 없다**.
`+0x268` 이 시퀀스 슬롯인 것은 `0x14023b4ef`/`0x14023b503`(animationmode 초기화)과
`0x14023ce8b`(`remapinitialvalue` 출력 arm)이 증명한다.

**패치안 (before/after — 개념)**

```swift
// Sources/WapleCore/ParticleSystem.swift:143  (before)
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
// Sources/WapleCore/ParticleSystem.swift:1842-1849  (before)
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
// Sources/WapleCore/ParticleSimulator.swift:1367-1388  (before)
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
`around` 분기(`between == false`)의 실물 식은 §4.2 의 세 기저벡터 변환까지 필요하므로
이번 라운드에서 옮기지 않았다 — **[미해결]** 로 남긴다.

**무회귀 경고.** `p.frame` 을 안 쓰게 되면 `SceneRendererFrameEncoder.swift:123`/`:264` 의
`p.frame >= 0` 분기가 죽고 시트 인덱스가 `particleSheetFrameIndex` 폴터로 간다.
동봉에서 `mapsequence*` 를 쓰는 파티클은 12+7 = 19건이므로 **그림이 바뀐다**.
바꾸기 전에 그 19건의 시트 프레임 수를 세고 A/B 캡처를 잡는 것을 권한다.

### P2. `ChildLink.controlPointStartIndex` 소비 배선

`Sources/WapleCore/ParticleSystem.swift:1265` 의 `[파스·보존 전용]` 을 닫을 수 있다.

**규약**(§6): 자식 링크 `flags & 1` 일 때만, 자식 시스템의 CP 슬롯
`startIndex … 7` 에 **부모의 살아 있는 파티클 위치**를 순서대로 채운다.
그 슬롯들은 저작 CP 를 덮고, `flags & 0x10005` 인 CP 는 건너뛴다.
자식 CP 개수는 8 로 강제된다(`0x14022ccda`).

**패치안**: `ChildLink` 에 `flags: Int` 를 추가로 파스하고(현재 `children[].flags` 미파스 —
파스 VA `0x1401d09be`, 주입 기본 0), `ParticleSimulator` 의 자식 인스턴스 스폰/갱신 지점
(`ParticleSimulator.swift:435` `makeInstance` / `:821-830` 의 자식 갱신 루프)에서 매 프레임
```swift
if link.flags & 1 != 0 {
    var slot = max(0, link.controlPointStartIndex)
    for parent in parentAlive where slot < 8 {
        if childDef.controlPointFlags[slot] & 0x10005 != 0 { continue }   // 실물은 slot 을 전진 안 시킨다
        childInstance.controlPoints[slot] = parent.pos                    // 필요시 부모→자식 스페이스 변환
        slot += 1
    }
}
```
**주의 ①** Waple 의 CP 는 현재 `def` 에 정적으로 박혀 있고
(`ParticleSystem.parse` 가 로드 시 1회 베이크), `controlpointattract` 등은 **target 을 이미
구워 갔다**(`bakeControlPointTargets`). 자식 CP 를 매 프레임 바꾸려면 **베이크를 걷어내고**
소비 시점에 CP 를 읽도록 바꿔야 한다 — 구조 변경이라 별도 라운드가 맞다.
**주의 ②** 실물은 막힌 슬롯에서 `slot` 을 전진시키지 않는다(§6 [미해결]). 위 스케치는
`continue` 로 `slot` 을 고정해 실물과 같게 뒀다 — 무한 정체가 실물 동작이다.

### P3. `ParticleSystemDef.controlPointAngles` 의 `[미해결]` 을 닫는다

`Sources/WapleCore/ParticleSystem.swift:1527-1528` 과
`ParticleInstanceOverride.controlPointAngles`(`Sources/WapleCore/ParticleSystem.swift:1291-1314`)의 "소비처 미확정" 은
**닫힌다** — 소비처는 두 곳이다:
1. **이미터 VM** `0x140237c42`–`0x140237c86` / `0x1402384c8`–`0x140238502` (4×4 전체)
2. **이니셜라이저 opid 13** `mapsequencearoundcontrolpoint` 의 3×3 기저 변환
   (`0x14023c537` → `0x14023c577`/`0x14023c58e`/`0x14023c5a5`)

다만 **[확정] 파티클 `.json` 의 `controlpoint[].angles` 는 런타임 base 행렬에 반영되지 않는다**
(생성자 `0x14022c3c0` 이 회전 3행에 항등을 넣는다 — §2.1). 살아 있는 것은 **씬 쪽
`controlpointangleN`** 뿐이다. 주석을 그렇게 고쳐야 한다.
동봉 `controlpoint[].angles` 저작 **0건**이라 그림 변화는 없다.

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
2. `mapsequencebetweencontrolpoints` 의 `[sys+0x20] & 1` 게이트(`0x14023cb55`)가 왜
   수직 성분 기준점을 바꾸는지(월드/로컬 구분으로 보이나 확증 없음).
3. `mapsequencearoundcontrolpoint`(opid 13)의 **페이로드 전수**. 핸들러가 읽는 자리
   (`[r14+0x08/0x0c/0x10/0x2c/0x38/0x44/0x54]`)는 짚었지만 파스 측 대응을 다 못 떴다.
   `speedmin`/`speedmax` 가 어디로 가는지 미확정.
4. §6 의 슬롯 정체(막힌 CP 에서 `edx` 미전진)가 의도인지.
5. 이미터 레코드의 파스↔런타임 오프셋 차이 `0x10` 의 복사 지점.
6. 브리프의 "JSON 3,655개" 분모 출처(이 저장소 두 코퍼스 합은 3,841, JSONC 63 은 일치).
7. `arcdirection` 이 **어느 공간**의 벡터인지(시스템 로컬로 보이나 변환 지점 없음 —
   `0x14019d570`(scale) → `0x14019e860`(add) 로 그냥 더한다. 즉 **로컬 축 그대로**로 보이지만
   오브젝트 회전과의 관계는 확인 못 했다).
8. `[sys+0x3f7]` 바이트(`0x14022be77`, `0x14023641b`, `0x1402364bc`)의 의미 —
   자식 CP 피드와 같은 경로에서 전파되는데 소비처를 못 짚었다.
