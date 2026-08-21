# 파티클 오퍼레이터 VM — opid 전수 대조표

> 대상: `wallpaper64.exe` (imagebase `0x140000000`).
> 이 문서는 **오퍼레이터 바이트코드 VM 하나**만 다룬다. 이미터/이니셜라이저/렌더러는
> 각자 다른 스트림·다른 opcode 공간을 쓴다(§1.3).
> 페이드 창의 **산술**은 `Sources/WapleCore/ParticleSystem.swift:520-560` 주석이 정본이다.
> 여기서 새로 확정한 것은 **opid ↔ 이름 ↔ 핸들러의 40개 전수 대응**과 **빈 슬롯 27의 정체**다.

---

## 1. 구조

### 1.1 명령 레코드

오퍼레이터는 C++ 객체가 아니라 아레나에 범프 할당되는 바이트코드 레코드다.

```
[+0x00] u8   opcode          0 = 스트림 끝
[+0x02] u16  레코드 전체 크기   ; 전진 폭
[+0x10] ...  페이로드          ; 할당기가 반환하는 포인터가 여기다
```

크기 필드를 쓰는 곳: 할당기 `mov word ptr [rdx+2], <size>` (예: `0x1401d89c1`),
전진 블록 `movzx eax, word ptr [r14+2]` (`0x140240279`).

### 1.2 디스패치 루프

| 위치 | 코드 | 의미 |
| --- | --- | --- |
| `0x14023fcb7` | `mov r14, [rsi+0x90]` | 스트림 시작 |
| `0x14023fcc3` | `cmp byte [r14], 0` → `je 0x14024bace` | opcode 0 = 종료 |
| `0x14023fd6c` | `movzx eax, byte [r14]` | opcode 적재 |
| `0x14023fd7f` | `dec eax` | 인덱스 = opid − 1 |
| `0x14023fdbc` | `mov eax, [r9 + rcx*4 + 0x24bb58]` | `r9 = imagebase`(`lea r9,[rip-0x23fd77]` @`0x14023fd70`) |
| `0x14023fdc4` | `add rax, r9` / `jmp rax` | 절대 주소 = imagebase + 테이블값 |
| `0x140240279` | `movzx eax, word [r14+2]` / `add r14, rax` / `jmp 0x14023fd6c` | 다음 명령 |

**경계 검사가 없다.** `0x14023fdbc` 앞에 `cmp`/`ja` 가 하나도 없으므로 opid 가 40을 넘으면
바로 옆 테이블을 인덱싱한다. 즉 테이블 길이는 **런타임이 아니라 생성기(파서)가 보증**한다.

VM 함수 전체 범위는 `.pdata` 4조각을 `UNW_FLAG_CHAININFO` 로 묶어
**`0x14023fbc0–0x14024be38`**(조각: `0x14023fbc0–0x14023fccd`, `0x14023fccd–0x14024bace`,
`0x14024bace–0x14024bae3`, `0x14024bae3–0x14024be38`). 모든 case 본문은 두 번째 조각 안에 있다.

### 1.3 스트림이 여럿이다 — 혼동 주의

정의 객체(파서의 `r13`)는 스트림 포인터를 다섯 개 들고 있고, 소멸자 `0x1401c4000` 이 그중
둘을 opcode 별로 순회한다.

| 정의 오프셋 | 스트림 | 근거 |
| --- | --- | --- |
| `+0x58` | 이미터(sphererandom/boxrandom/layerimage) | 소멸자가 opcode 3 에서 `[rbx+0xa0]` 벡터 해제(`0x1401c4033`) — layerimage |
| `+0x68` | 이니셜라이저 16종 | 소멸자가 opcode 5 에서 `[rbx+4]` 소멸(`0x1401c40c4`) — colorlist |
| `+0x78` | **오퍼레이터**(이 문서) | 파서가 `mov [r13+0x78], rax` (`0x1401cc489`), 길이 `[r13+0x80]`(`0x1401cc494`) |
| `+0x88`, `+0x98` | 렌더러/그 외 | — |

또 파서는 **에디터 반영용 두 번째 스트림**(`[rsp+0x30]`)을 병행 기록한다. 이쪽 할당기는
`0x1401d89d0`(opid 8, 크기 `0x2c`, 페이로드 `+4`) 처럼 **다른 opcode 공간**을 쓰고 레코드에
키 문자열 포인터를 싣는다(`mov [rax], r15` @`0x1401cb41b`). **오퍼레이터 opid 와 무관하다.**

### 1.4 파티클 SoA 오프셋 범례(VM 의 `rsi`)

| 오프셋 | 내용 | 근거 |
| --- | --- | --- |
| `+0x24` | 상태 플래그 바이트 | `test byte [rsi+0x24], 8` @`0x14023fc08` |
| `+0x90` | 오퍼레이터 스트림 | `0x14023fcb7` |
| `+0x258` / `+0x260` | age / lifetime | `rcpps [lifetime]` × `[age]` @`0x1402402b4`–`0x1402402ea` |
| `+0x270` / `+0x278` | 현재 size / 기준 size | 프롤로그 무조건 복사 `0x14023fc99` |
| `+0x280..0x290` | 회전각 x/y/z | angularmovement 적분 대상 `0x14024000d` |
| `+0x298..0x2a8` | 각속도 x/y/z | 같은 곳 |
| `+0x2b0..0x2c0` | 위치 x/y/z | movement `0x14023fef7` |
| `+0x2c8..0x2d8` | 속도 x/y/z | 같은 곳 |
| `+0x2e0..0x2f0` | 직전 위치 x/y/z | `flags&4` 일 때 복사 `0x14023fe9d` |
| `+0x2f8..0x308` / `+0x318..0x328` | 현재 color rgb / 기준 color rgb | `flags&8` 복사 `0x14023fc1b` |
| `+0x310` / `+0x330` | 현재 alpha / 기준 alpha | `flags&0x10` 복사 `0x14023fc7b` |
| `+0x338` | 파티클별 난수(위상 랜덤화) | oscillate*/turbulence 가 읽음 |
| `+0x340` | 파티클 수 | 모든 루프 상한 |
| `+0x400` | 컨트롤포인트 배열 | `0x140241554` 계열 |

프롤로그가 매 프레임 size/color/alpha 를 **기준값으로 되돌리고** 시작하므로, 그 셋을 만지는
오퍼레이터는 누적이 아니라 매 프레임 재계산이다.

---

## 2. 점프테이블 범위 확정 — **정확히 40 엔트리**

테이블 시작은 `0x14024bb58`(imagebase-상대 u32 배열, `base + tbl[opid-1]`).
끝은 세 가지가 서로 맞물려 확정된다.

1. **다음 테이블의 시작.** VM 함수 안의 간접 점프 13곳이 쓰는 테이블 베이스를 전부 뽑으면
   `0x24bb58, 0x24bbf8, 0x24bc14, 0x24bc30, 0x24bc80, 0x24bc9c, 0x24bcb4, 0x24bcfc,
   0x24bd4c, 0x24bd68, 0x24bd80, 0x24bdc8, 0x24be00` 이다. 첫 두 개의 차이가
   `0x24bbf8 − 0x24bb58 = 0xa0 = 40 × 4`.
2. **그 사이를 참조하는 코드가 없다.** `.text` 전체에서 `mov r32,[base+idx*4+disp32]` 형태의
   disp32 가 `[0x24bb58, 0x24bbf8)` 에 드는 것은 `0x14023fdbc` **한 곳뿐**이다.
3. **41번째 이후 값은 다른 스위치의 것이다.** `tbl[40..46]` = `0x140242aaf, 0x140242af1,
   0x140242b33, 0x140242ba7, 0x140242bc4, 0x140242c13, 0x140242c5b` 인데, 이 7개는
   turbulence 핸들러 안의 서브 스위치(`jmp rax` @`0x140242aad`, 베이스 `0x24bbf8`) 대상이다.

따라서 유효 범위는 **`0x14024bb58–0x14024bbf8`**, opid **1..40**.

---

## 3. opid 27 은 빈 슬롯이다

`tbl[26] = 0x00000000` → 주소 `0x140000000`(= imagebase, 코드가 아니다). 이 슬롯을 타면
즉사한다. 그런데 **아무도 opid 27 을 쓰지 않는다**:

- 오퍼레이터 opcode 를 찍는 곳은 딱 두 군데다.
  ① 할당기 썽크 26개(`0x1401d89b0`–`0x1401d8d50`, `mov byte [rdx], <opid>`) — 값은 1..26.
  ② 페이드 창 공용 파서의 승격 `mov byte [r15], r14b` (`0x1401c2e33`) — `r9d` 로 넘어온 값.
- `.text` 전체에서 위 26개 썽크를 호출하는 함수는 파서 `0x1401c5490` **하나뿐**이다.
- 파서 안의 `mov r9d, imm` 은 **`0x1c`(28)부터 `0x28`(40)까지 13개**이고 `0x1b`(27)은 없다.

즉 **27 에 대응하는 이름은 존재하지 않는다.** 위치로 보면 27은 승격 opcode 를 원소 등장
순서대로 매긴 수열의 **첫 자리**, 즉 `movement`(base 1)의 페이드 창 변종 자리다.
`movement` 브랜치(`0x1401cb215`–`0x1401cb551`)에는 `0x1401c2a40` 호출이 아예 없어
그 case 본문이 컴파일되지 않았고, MSVC 가 구멍을 0 으로 채웠다.
**`movement` 는 `blendin*/blendout*` 키를 적어도 무시된다.**

---

## 4. opid → 이름 → 핸들러 전수표

1..26 은 할당기 썽크가 찍는 base opcode, 28..40 은 페이드 창 게이트 통과 시 공용 파서가
덮어쓰는 ext opcode 다(§5). 크기는 **레코드 전체**이고 페이로드는 그보다 `0x10` 작다.

| opid | 이름 | 핸들러 VA | opcode 를 찍는 곳 | 레코드 크기 | 파서 진입점 |
| ---: | --- | --- | --- | ---: | --- |
| 1 | `movement` | `0x14023fdc9–0x14023ffc7` | `0x1401d89b0` | `0x30` | `0x1401cb215` |
| 2 | `angularmovement` | `0x14023ffc7–0x1402400e7` | `0x1401d89f0` | `0x90` | `0x1401cb551` |
| 3 | `alphafade` | `0x14024029d–0x14024033a` | `0x1401d8a30` | `0x30` | `0x1401cb8a5` |
| 4 | `sizechange` | `0x14024033a–0x1402403a2` | `0x1401d8a50` | `0x50` | `0x1401cb96b` |
| 5 | `colorchange` | `0x1402403a2–0x140240457` | `0x1401d8a70` | `0x90` | `0x1401cbb6f` |
| 6 | `alphachange` | `0x140240457–0x1402404c0` | `0x1401d8ab0` | `0x50` | `0x1401cbf31` |
| 7 | `oscillateposition` | `0x1402404c0–0x1402409bb` | `0x1401d8ad0` | `0xe0` | `0x1401cc084` |
| 8 | `oscillatealpha` | `0x140240f17–0x140241080` | `0x1401d8af0` | `0xb0` | `0x1401cc617` |
| 9 | `oscillatesize` | `0x14024123a–0x1402413a0` | `0x1401d8b10` | `0xb0` | `0x1401cc7fb` |
| 10 | `controlpointattract` | `0x140241554–0x14024172d` | `0x1401d8b30` | `0xc0` | `0x1401cc9da` |
| 11 | `maintaindistancetocontrolpoint` | `0x14024197a–0x140241ccf` | `0x1401d8b70` | `0x70` | `0x1401ccdcc` |
| 12 | `maintaindistancebetweencontrolpoints` | `0x140242058–0x140242352` | `0x1401d8b90` | `0x60` | `0x1401ccf82` |
| 13 | `reducemovementnearcontrolpoint` | `0x14024268f–0x1402427b8` | `0x1401d8bb0` | `0xa0` | `0x1401cd1b0` |
| 14 | `turbulence` | `0x14024295a–0x140242d6e` | `0x1401d8bd0` | `0x100` | `0x1401cd423` |
| 15 | `vortex` | `0x1402431be–0x1402433ea` | `0x1401d8bf0` | `0xf0` | `0x1401cd8a9` |
| 16 | `vortex_v2` | `0x1402433ea–0x140243a17` | `0x1401d8c10` | `0x120` | `0x1401cde40` |
| 17 | `boids` | `0x140244121–0x1402446fd` | `0x1401d8c30` | `0x50` | `0x1401ce402` |
| 18 | `capvelocity` | `0x1402446fd–0x140244790` | `0x1401d8c50` | `0x60` | `0x1401ce5cd` |
| 19 | `remapvalue` | `0x140244874–0x140246ec0` | `0x1401d8c70` | `0x160` | `0x1401ce667` |
| 20 | `inheritvaluefromevent` | `0x140249c30–0x14024a355` | `0x1401d8c90` | `0x60` | `0x1401cf157` |
| 21 | `collisionplane` | `0x14024afb2–0x14024b0f4` | `0x1401d8cb0` | `0x80` | `0x1401cf1f8` |
| 22 | `collisionsphere` | `0x14024b0f4–0x14024b1b9` | `0x1401d8cd0` | `0x70` | `0x1401cf410` |
| 23 | `collisionbox` | **`0x140240279`(전진 블록 = no-op)** | `0x1401d8cf0` | `0x30` | `0x1401cf655` |
| 24 | `collisionbounds` | `0x14024b1b9–0x14024b653` | `0x1401d8d10` | `0x30` | `0x1401cf6de` |
| 25 | `collisionquad` | `0x14024b653–0x14024b8ab` | `0x1401d8d30` | `0x140` | `0x1401cf737` |
| 26 | `collisionmodel` | `0x14024b8ab–0x14024bace` | `0x1401d8d50` | `0x40` | `0x1401cfd9f` |
| **27** | **(없음 — 빈 슬롯)** | `0x140000000` | — | — | — |
| 28 | `angularmovement` +창 | `0x1402400e7–0x140240279` | `0x1401c2e33`(승격) | `0x90` | `mov r9d,0x1c` @`0x1401cb878` |
| 29 | `oscillateposition` +창 | `0x1402409bb–0x140240f17` | 〃 | `0xe0` | `mov r9d,0x1d` @`0x1401cc430` |
| 30 | `oscillatealpha` +창 | `0x140241080–0x14024123a` | 〃 | `0xb0` | `mov r9d,0x1e` @`0x1401cc7c2` |
| 31 | `oscillatesize` +창 | `0x1402413a0–0x140241554` | 〃 | `0xb0` | `mov r9d,0x1f` @`0x1401cc9a6` |
| 32 | `controlpointattract` +창 | `0x14024172d–0x14024197a` | 〃 | `0xc0` | `mov r9d,0x20` @`0x1401ccdaf` |
| 33 | `maintaindistancetocontrolpoint` +창 | `0x140241ccf–0x140242058` | 〃 | `0x70` | `mov r9d,0x21` @`0x1401ccf44` |
| 34 | `maintaindistancebetweencontrolpoints` +창 | `0x140242352–0x14024268f` | 〃 | `0x60` | `mov r9d,0x22` @`0x1401cd165` |
| 35 | `reducemovementnearcontrolpoint` +창 | `0x1402427b8–0x14024295a` | 〃 | `0xa0` | `mov r9d,0x23` @`0x1401cd3eb` |
| 36 | `turbulence` +창 | `0x140242d6e–0x1402431be` | 〃 | `0x100` | `mov r9d,0x24` @`0x1401cd889` |
| 37 | `vortex_v2` +창 | `0x140243a17–0x140244121` | 〃 | `0x120` | `mov r9d,0x25` @`0x1401ce3b4` |
| 38 | `capvelocity` +창 | `0x140244790–0x140244874` | 〃 | `0x60` | `mov r9d,0x26` @`0x1401ce63c` |
| 39 | `remapvalue` +창 | `0x140246ec0–0x140249c30` | 〃 | `0x160` | `mov r9d,0x27` @`0x1401cf108` |
| 40 | `inheritvaluefromevent` +창 | `0x14024a355–0x14024afb2` | 〃 | `0x60` | `mov r9d,0x28` @`0x1401cf1d0` |

핸들러 끝 주소는 **코드 배치 순서상 다음 case 의 시작**이다(전부 `start < end`).
28..40 은 전부 **점프테이블로만 도달**한다 — 함수 안 어떤 직접 분기의 대상도 아니다
(직접 분기 대상 전수 대조로 확인).

opid 23 의 슬롯 값 `0x140240279` 는 **전진 블록 자체**다. 즉 `collisionbox` 는 파싱되고
`0x30` 바이트를 차지하지만 시뮬레이션에서 아무 일도 하지 않는다. `controlpoint` 키도
읽기만 하고 버린다(`0x1401cf697`–`0x1401cf6c2`, 반환값 미사용). 사실상 폐기된 원소이며
`collisionbounds`(24)가 그 자리를 대신한다.

---

## 5. 페이드 창 승격(28–40) 메커니즘

공용 파서 **`0x1401c2a40–0x1401c2e4e`** 가 `blendinstart`(`0x14048f850`) ·
`blendinend`(`0x14048f860`) · `blendoutstart`(`0x14048f870`) · `blendoutend`(`0x14048f880`)
넷을 읽어 인자 `rcx` 가 가리키는 **0x40 바이트 슬롯**에 브로드캐스트 vec4 넷을 굽는다.

```
[+0x00] blendinstart(보정)        ; 0x1401c2dd1
[+0x10] rcp(blendinend − inStart) ; 0x1401c2df6
[+0x20] blendoutend(보정)         ; 0x1401c2ddc
[+0x30] rcp(outEnd − blendoutstart) ; 0x1401c2e04
```

게이트(`0x1401c2deb`–`0x1401c2e31`)를 통과하면 **`mov byte [r15], r14b`**(`0x1401c2e33`)로
레코드 opcode 를 base → ext 로 덮어쓴다. `r8`=opcode 바이트 주소, `r9d`=ext opcode.

런타임 가중치는 `.pdata` 엔트리가 없는 리프 **`0x14022a530–0x14022a575`**:
`t = age/lifetime` (`rcpps [rdx+rax*4]` × `[rcx+rax*4]`),
`w = max(0, min(1,(P2−t)·P3)) · max(0, min(1,(t−P0)·P1))`.

호출부는 11곳이지만 대상은 **13종**이다. `controlpointattract`(`0x1401ccdaf`)와
`turbulence`(`0x1401cd889`)가 `mov r9d, imm` 뒤 `jmp` 로 남의 호출부
(`0x1401cc436` / `0x1401cc439`)에 뛰어들기 때문이다. **`mov r9d, imm` 을 세어야 맞다.**

창 슬롯의 페이로드 오프셋(파스 측 `lea` ↔ 핸들러 측 `lea r9,[r14+…]` 로 교차 확인):

| ext | 페이로드 오프셋 | 파스 측 | 핸들러 측(`instr+`) |
| ---: | --- | --- | --- |
| 28 | `+0x30` | `0x1401cb874` | `+0x40` |
| 29 | `+0x90` | `0x1401cc429` | `+0xa0` |
| 30 | `+0x60` | `0x1401cc7ba` | `+0x70` |
| 31 | `+0x60` | `0x1401cc99e` | `+0x70` |
| 32 | `+0x60` | `0x1401ccdab` | `+0x70` |
| 33 | `+0x10` | `0x1401ccf62` | `+0x20` |
| 34 | `+0x00` | `0x1401cd191` | `+0x10` |
| 35 | `+0x00` | `0x1401cd404` | `+0x10` |
| 36 | `+0x80` | `0x1401cd882` | `+0x90` |
| 37 | `+0x90` | `0x1401ce3cf` | `+0xa0` |
| 38 | `+0x10` | `0x1401ce638` | `+0x20` |
| 39 | `+0x110` | `0x1401cf101` | `+0x120` |
| 40 | `+0x10` | `0x1401cf1ca` | `+0x20` |

---

## 6. 파스 페이로드 레이아웃

표기: **페이로드 오프셋**(= 레코드 오프셋 − `0x10`). `vec4` 는 스칼라를 `shufps …, 0` 으로
4레인 브로드캐스트한 것. VA 는 그 값을 페이로드에 쓰는 명령이다.

### opid 1 `movement` — 레코드 `0x30` / 페이로드 `0x20`
키: `gravity`(`0x1401cb250`) · `drag`(`0x1401cb35e`) · `flags`(`0x1401cb39d`)

| off | 내용 | VA |
| --- | --- | --- |
| `+0x00` | `gravity.x, gravity.y` (raw f32×2) | `0x1401cb365` |
| `+0x08` | `gravity.z` | `0x1401cb377` |
| `+0x0c` | `flags` (i32) | `0x1401cb3d3` |
| `+0x10` | `drag` (f32) | `0x1401cb3a4` |

핸들러가 읽는 자리는 `r14+0x10/+0x18/+0x1c/+0x20`(`0x14023fdc9`–`0x14023fe6d`).

### opid 2 `angularmovement` — `0x90` / `0x80`
키: `force`(`0x1401cb58f`) · `drag`(`0x1401cb69e`) · 창 4키

`+0x00/+0x10/+0x20` = `force.x/y/z` vec4 (`0x1401cb6b0`,`0x1401cb6c0`,`0x1401cb6d1`) ·
`+0x30..+0x6f` = 창 · `+0x70` = `drag`(`0x1401cb6f8`)

### opid 3 `alphafade` — `0x30` / `0x20`
키: `fadeintime`(`0x1401cb8e0`) · `fadeouttime`(`0x1401cb914`)
`+0x00` = `fadeintime`(`0x1401cb922`) · `+0x10` = `fadeouttime`(`0x1401cb94b`).
역수는 런타임에서 낸다(`rcpps [r14+0x10]` @`0x1402402b4`).

### opid 4 `sizechange` — `0x50` / `0x40`
키: `starttime` `endtime` `startvalue` `endvalue`(`0x1401cb9a6`,`0x1401cb9d6`,`0x1401cba0a`,`0x1401cba3d`)

| off | 내용 | VA |
| --- | --- | --- |
| `+0x00` | `startvalue` | `0x1401cba9b` |
| `+0x10` | `endvalue − startvalue` | `0x1401cba9e` |
| `+0x20` | `starttime` | `0x1401cba81` |
| `+0x30` | `rcp(endtime − starttime)` | `0x1401cba97` |

### opid 5 `colorchange` — `0x90` / `0x80`
`+0x00/+0x10/+0x20` = `startvalue.rgb`(`0x1401cbe2b`,`0x1401cbe37`,`0x1401cbe44`) ·
`+0x30/+0x40/+0x50` = `(endvalue − startvalue).rgb`(`0x1401cbe59`,`0x1401cbe6e`,`0x1401cbe83`) ·
`+0x60` = `starttime`(`0x1401cbe13`) · `+0x70` = `rcp(endtime − starttime)`(`0x1401cbe1e`)

### opid 6 `alphachange` — `0x50` / `0x40`
`sizechange` 와 동일 배치: `+0x00`(`0x1401cc061`) `+0x10`(`0x1401cc064`)
`+0x20`(`0x1401cc047`) `+0x30`(`0x1401cc05d`)

### opid 7 `oscillateposition` — `0xe0` / `0xd0`
키: `mask` `frequencymin` `frequencymax` `phasemin` `phasemax` `scalemin` `scalemax`

| off | 내용 | VA |
| --- | --- | --- |
| `+0x00/+0x10/+0x20` | `mask.x/y/z` | `0x1401cc312`,`0x1401cc321`,`0x1401cc331` |
| `+0x30` / `+0x40` | `frequencymin` / `frequencymax` | `0x1401cc33f` / `0x1401cc344` |
| `+0x50` / `+0x60` | `phasemin` / `phasemax` | `0x1401cc34e` / `0x1401cc357` |
| `+0x70` / `+0x80` | `scalemin` / `scalemax` | `0x1401cc35f` / `0x1401cc367` |
| `+0x90..+0xcf` | 창 | `0x1401cc429` |

### opid 8 `oscillatealpha` — `0xb0` / `0xa0`
`+0x00` freqmin(`0x1401cc79a`) `+0x10` freqmax(`0x1401cc7a8`) `+0x20` phasemin(`0x1401cc7ad`)
`+0x30` phasemax(`0x1401cc7b6`) `+0x40` scalemin(`0x1401cc7cf`) `+0x50` scalemax(`0x1401cc7d6`)
`+0x60..+0x9f` 창

### opid 9 `oscillatesize` — `0xb0` / `0xa0`
opid 8 과 동일 배치: `0x1401cc97e`,`0x1401cc98c`,`0x1401cc991`,`0x1401cc99a`,`0x1401cc9b3`,`0x1401cc9ba`

### opid 10 `controlpointattract` — `0xc0` / `0xb0`
키: `offset` `scale` `threshold` `deletethreshold` `flags` `controlpoint`

| off | 내용 | VA |
| --- | --- | --- |
| `+0x00/+0x10/+0x20` | `offset.x/y/z` | `0x1401ccc20`,`0x1401ccc2f`,`0x1401ccc3f` |
| `+0x30` | `scale` | `0x1401ccbff` |
| `+0x40` | `threshold` | `0x1401ccc08` |
| `+0x50` | `deletethreshold` | `0x1401ccc10` |
| `+0x60..+0x9f` | 창 | `0x1401ccdab` |
| `+0xa0` | `flags` | `0x1401ccbe2` |
| `+0xa4` | `controlpoint`(≥7 → 7 클램프 `0x1401ccd01`) | `0x1401ccd06` |

### opid 11 `maintaindistancetocontrolpoint` — `0x70` / `0x60`
`+0x00` `distance`(`0x1401ccf12`) · `+0x04` `variablestrength`(`0x1401ccf3f`) ·
`+0x10..+0x4f` 창 · `+0x50` `controlpoint`(`0x1401ccedf`)

### opid 12 `maintaindistancebetweencontrolpoints` — `0x60` / `0x50`
`+0x00..+0x3f` 창 · `+0x40` `controlpointstart`(`0x1401cd095`) ·
`+0x44` `controlpointend`(`0x1401cd162`)

### opid 13 `reducemovementnearcontrolpoint` — `0xa0` / `0x90`
`+0x00..+0x3f` 창 · `+0x40` `distanceinner`(`0x1401cd39f`) · `+0x50` `distanceouter`(`0x1401cd3bd`) ·
`+0x60` `reductioninner`(`0x1401cd3c9`) · `+0x70` `reductionouter`(`0x1401cd3e7`) ·
`+0x80` `controlpoint`(`0x1401cd391`)

### opid 14 `turbulence` — `0x100` / `0xf0`
키: `mask` `scale` `phasemin` `phasemax` `speedmin` `speedmax` `timescale` + 오디오반응 5키

| off | 내용 | VA |
| --- | --- | --- |
| `+0x00/+0x10/+0x20` | `mask.x/y/z` | `0x1401cd6a2`,`0x1401cd6af`,`0x1401cd6bd` |
| `+0x30` | `scale` | `0x1401cd6cc` |
| `+0x40` / `+0x50` | `speedmin` / `speedmax` | `0x1401cd6e4` / `0x1401cd6ed` |
| `+0x60` / `+0x70` | `phasemin` / `phasemax` | `0x1401cd6d1` / `0x1401cd6db` |
| `+0x80..+0xbf` | 창 | `0x1401cd882` |
| `+0xc0` | `timescale` | `0x1401cd690` |
| `+0xc4` | 파생 플래그(`timescale`·`scale` 0 판정 OR) | `0x1401cd742` |
| `+0xd0..+0xef` | 오디오 반응 블록 | 파서 `0x1401c1e20` @`0x1401cd749` |

### opid 15 `vortex` — `0xf0` / `0xe0`
키: `offset` `axis` `flags` `distanceinner` `distanceouter` `speedinner` `speedouter` `controlpoint`

| off | 내용 | VA |
| --- | --- | --- |
| `+0x00/+0x10/+0x20` | `offset.x/y/z` | `0x1401cdc77`,`0x1401cdc86`,`0x1401cdc96` |
| `+0x30/+0x40/+0x50` | `axis.x/y/z` | `0x1401cdca3`,`0x1401cdcb0`,`0x1401cdcc5` |
| `+0x60` | `distanceinner` | `0x1401cdcc9` |
| `+0x70` | `rcp(distanceouter − distanceinner)`(동일 시 1.0) | `0x1401cdce3` |
| `+0x80` | `speedinner` | `0x1401cdcf4` |
| `+0x90` | `speedouter − speedinner` | `0x1401cdcff` |
| `+0xa0` | `flags&1` 축 투영 마스크(NaN 또는 0) | `0x1401cdd25` |
| `+0xb0` | `controlpoint` | `0x1401cdd06` |
| `+0xc0..+0xdf` | 오디오 반응 블록 | `0x1401cdd1e` → `0x1401c1e20` |

### opid 16 `vortex_v2` — `0x120` / `0x110`
키: `axis` `flags` `distanceinner` `distanceouter` `speedinner` `speedouter` `centerforce`
`controlpoint` `ringradius` `ringwidth` `ringpulldistance` `ringpullforce`

| off | 내용 | VA |
| --- | --- | --- |
| `+0x00` | 내측 반경 (`flags&4` 면 ring 기반 분기) | `0x1401ce245` / `0x1401ce268` |
| `+0x10` | `rcp(외측 − 내측)` | `0x1401ce281` |
| `+0x20` / `+0x30` | `speedinner` / `speedouter − speedinner` | `0x1401ce2a6` / `0x1401ce2af` |
| `+0x40` | `flags&1` 축 투영 마스크 | `0x1401ce2de` |
| `+0x50` | `centerforce` | `0x1401ce2b9` |
| `+0x60` / `+0x70` | `ringradius` / `ringpullforce` | `0x1401ce293` / `0x1401ce29d` |
| `+0x80..+0x8b` | `axis`(raw vec3) | `0x1401ce222`,`0x1401ce22d` |
| `+0x90..+0xcf` | 창 | `0x1401ce3cf` |
| `+0xd0` | `controlpoint` | `0x1401ce2be` |
| `+0xe0..+0xff` | 오디오 반응 블록 | `0x1401ce2d7` → `0x1401c1e20` |
| `+0x100` | `flags`(런타임 `test byte [r14+0x110], 4` @`0x1402434eb`) | `0x1401ce217` |

### opid 17 `boids` — `0x50` / `0x40`
| off | 내용 | VA |
| --- | --- | --- |
| `+0x00` | `separationthreshold` | `0x1401ce4ea` |
| `+0x10` | `neighborthreshold` | `0x1401ce4b2` |
| `+0x20` | `maxspeed` (vec4) | `0x1401ce5b2` |
| `+0x30` | `separationfactor` (f32) | `0x1401ce516` |
| `+0x34` | `alignmentfactor` (f32) | `0x1401ce580` |
| `+0x38` | `cohesionfactor` (f32) | `0x1401ce54b` |
| `+0x3c` | `flags` (i32) | `0x1401ce474` |

### opid 18 `capvelocity` — `0x60` / `0x50`
`+0x00` `maxspeed`(`0x1401ce642`) · `+0x10..+0x4f` 창

### opid 19 `remapvalue` — `0x160` / `0x150`
키: `operation` `input` `output` `inputcomponent` `outputcomponent` `transformfunction`
`flags` `inputrangemin/max` `outputrangemin/max` `inputcontrolpoint0/1` `outputcontrolpoint0/1`
`transforminputscale` `transformoctaves`

| off | 내용 | VA |
| --- | --- | --- |
| `+0x00` | `operation` enum | `0x1401ce6e4` |
| `+0x04` | `input` enum | `0x1401ce71e` |
| `+0x08` | `output` enum | `0x1401ce759` |
| `+0x0c` | `inputcomponent` | `0x1401ce794` |
| `+0x10` | `outputcomponent` | `0x1401ce7cf` |
| `+0x14` | `transformfunction` | `0x1401ce80a` |
| `+0x18` | `transformoctaves` | `0x1401cf0f7` |
| `+0x1c` | `flags` | `0x1401ce83d` |
| `+0x20/+0x30/+0x40` | `inputrangemin.xyz` | `0x1401cee1a`,`0x1401cee2a`,`0x1401cee3a` |
| `+0x50/+0x60/+0x70` | `rcp(input span).xyz` | `0x1401cee4a`,`0x1401cee5a`,`0x1401cee6a` |
| `+0x80/+0x90/+0xa0` | `outputrangemin.xyz` | `0x1401cee7a`,`0x1401cee8d`,`0x1401ceea0` |
| `+0xb0/+0xc0/+0xd0` | `output span.xyz` | `0x1401ceeb0`,`0x1401ceec0`,`0x1401ceed0` |
| `+0xe0` / `+0xe4` | `inputcontrolpoint0` / `outputcontrolpoint0`(min/max 정규화 `0x1401cef46`) | `0x1401cef00` / `0x1401cef4f` |
| `+0xe8` / `+0xec` | `inputcontrolpoint1` / `outputcontrolpoint1`(`0x1401cf010`) | `0x1401cefca` / `0x1401cf019` |
| `+0xf0` | `transforminputscale` | `0x1401cf0c5` |
| `+0x100` | 파생 f32(가상 함수 반환) | `0x1401cf111` |
| `+0x110..+0x14f` | 창 | `0x1401cf101` |

#### opid 19 런타임 — 입력 정규화와 `flags` 클램프 게이트

[2026-08-21 추가] 위 페이로드가 핸들러에서 어떻게 쓰이는지까지 옮긴다. 핸들러 진입부가
`+0x2c` 의 최하위 비트를 뽑아 두고(`movzx r9d, byte [r14+0x2c]` `0x140244996` /
`and r9b, 1` `0x1402449a0`), `inputcomponent` 축약(점프테이블 `0x140245020`) 뒤에

    t = (v − inputrangemin) · rcp(inputrangemax − inputrangemin)

를 건다. 자리는 둘이다 — 3성분 판 `subps xmm0,xmm1` `0x140245096` + `mulps xmm0,xmm2`
`0x140245099`(이하 두 성분 `0x1402450a0`–`0x1402450b2`), 스칼라 판 `subps xmm7,xmm1`
`0x1402450fa` + `mulps xmm7,xmm2` `0x1402450fd`.

그 **직후**가 클램프인데 **`flags` bit0 게이트가 걸려 있다**:
`test r9b,r9b` `0x1402450be`(3성분) / `0x140245105`(스칼라) → 서 있을 때만
`minps` 1.0(`0x140483640`, `0x1402450cd` / `0x14024510a`) + `maxps` 0(`0x1402450d3` /
`0x140245117`). `flags` 주입 기본이 int 1 이라 **기본은 클램프 켜짐**이다.
그 다음이 `transformfunction` 디스패치(`mov eax,[r14+0x24]` `0x14024512c`) —
즉 **정규화·클램프가 transform 보다 먼저**이고, `transforminputscale` 은 transform **안**이다.

`inputcomponent` 축약 arm 은 값을 세 레인에 **브로드캐스트**한 뒤 정규화하므로,
`inputrange*` 가 vec3 면 같은 신호가 성분마다 다른 t 를 낸다(`x` `0x140245022` ·
`y` `0x140245029` · `z` `0x140245034` · `average` `0x140245043`(×⅓ `0x140492db0`) ·
`sum` `0x140245059` · `max` `0x140245068` · `min` `0x140245077`; `all` 은 arm 없이 통과).

#### 이미터 레코드 — `cone` 과 방출 창

오퍼레이터가 아니라 이미터지만 같은 팩토리(`0x1401c5490`–`0x1401d152c`)가 만든다.

| off | 내용 | VA |
| --- | --- | --- |
| `+0x00` | `rate` | `0x1401c1ca5` |
| `+0x04` | `duration` | `0x1401c1cc7` |
| `+0x08` | `delay` | `0x1401c1cfa` |
| `+0x0c` | `duration` **사본** | `0x1401c1ce3`(`mov eax,[rdi+4]`) → `0x1401c1cf4` |
| `+0x10` | `delay` **사본** | `0x1401c1cff` |
| `+0x18/+0x1c` | `minperiodicduration` / `maxperiodicduration` | `0x1401c1d66` / `0x1401c1dac` |
| `+0x20/+0x24` | `minperiodicdelay` / `maxperiodicdelay` | `0x1401c1d89` / `0x1401c1dcf` |
| `+0x28` | `maxtoemitperperiod` | `0x1401c1df5` |
| `+0x34/+0x38` | `instantaneous` (역시 두 칸) | `0x1401c1d18` / `0x1401c1d22` |
| `+0x3c` | `flags` | `0x1401c1d35` |
| `+0xe4` | **`-cos(cone · π)`** | `0x1401c61ce` |

> **한 칸 밀림 주의(함정 16).** `duration` 은 `+0x04` 와 `+0x0c`, `delay` 는 `+0x08` 과 `+0x10`
> 이다 — *`+0x04`/`+0x08` 이 duration, `+0x0c`/`+0x10` 이 delay* 가 **아니다**. `delay` 의
> `asFloat` 반환(`0x1401c1cde`)과 그 두 저장(`0x1401c1cfa`·`0x1401c1cff`) 사이에 `duration`
> 사본 복사(`0x1401c1ce3`·`0x1401c1cf4`)가 끼어 있어서 순진하게 읽으면 어긋난다.
> 커밋 `87abb1f` 의 메시지가 정확히 그렇게 어긋나 있다(코드는 스칼라 한 칸씩만 쓰므로 무해).
> `+0x18`/`+0x20` 은 함수 꼬리(`0x1401c1deb`–`0x1401c1e0c`)가 `minss` 로 max 에 맞춰 내린다.

`cone` 은 `sphererandom` 바인더(`0x1401b9100`–`0x1401b992c`)에만 있고 기본 0 이다
(`xorps xmm2,xmm2` `0x1401b94ab` → `H_FLOAT` `0x1401b94b8`, 키 `lea` `0x1401b94ae`).
소비는 `asFloat` `0x1401c61b5` → `mulss xmm0, π`(`0x140492834`) `0x1401c61ba` →
`call 0x1400d2a10`(→`0x14041a2e0` = **`cosf`**) `0x1401c61bf` → `xorps xmm0, -0.0`
(`0x140492ff0`) `0x1401c61c4` → `movss [rsi+0xe4]` `0x1401c61ce`.
즉 **반회전 단위**(0→−1 · 0.5=90°→0 · 1=180°→+1)다.
동봉·설치본 각 2건 전부 `cone: 0` 이라 **실효 도달 0**.
**[미해결]** 이 −cos 임계값을 방향 샘플러가 어떻게 쓰는지는 아직 못 짚었다.

### opid 20 `inheritvaluefromevent` — `0x60` / `0x50`
`+0x00` `input` enum(`0x1401cf1ce`, 문자열→enum `0x1402611f0`) · `+0x10..+0x4f` 창

### opid 21–26 충돌 계열

공통 필드는 두 헬퍼가 채운다.
`0x1401c03f0`: `bouncefactor`(`0x14048fb40`) → `+0x00` vec4(`0x1401c0469`),
`collisionbehavior`(`0x14048faf0`) → `+0x10` i32
(`bounce`=0 `0x1401c04ec` · `slide`=1 `0x1401c0485` · `stop`=2 `0x1401c04b4` · `delete`=3 `0x1401c04e3`).
`0x1401c0860`(→`0x1401c00a0`): `origin`/`plane` 등 형상 키의 기본값 주입.

파스 후 패스 `0x1401cc4ab`–`0x1401cc4d4` 가 opcode **21·22·25** 인 레코드에 대해
`and dword [instr+0x24], ~2` (= 페이로드 `+0x14` bit1 클리어)를 건다.

| opid | 페이로드 |
| ---: | --- |
| 21 `collisionplane` | `+0x00` bouncefactor · `+0x10` behavior · `+0x14` 플래그 · `+0x20/+0x30/+0x40` 평면 법선 xyz(`0x1401cf3b2`,`0x1401cf3bf`,`0x1401cf3cc`) · `+0x60`,`+0x68` `distance` 파생(`0x1401cf38d`,`0x1401cf3a6`) |
| 22 `collisionsphere` | `+0x14` 플래그(`0x1401cf628`) · `+0x18` `controlpoint`(`0x1401cf62e`) · `+0x20/+0x30/+0x40` `origin.xyz`(`0x1401cf5a0`,`0x1401cf5b7`,`0x1401cf5ca`) · `+0x50` `radius`(`0x1401cf602`) |
| 23 `collisionbox` | 공통 필드만. `controlpoint` 는 읽고 버린다(`0x1401cf6c2`). |
| 24 `collisionbounds` | 공통 필드만. 고유 키 없음(`0x1401cf6de`–`0x1401cf720`). |
| 25 `collisionquad` | `+0x14` 플래그(`0x1401cfd6b`) · `+0x18` `controlpoint`(`0x1401cfd72`) · `+0x20..+0xf0` `origin`/`plane`/`forward`/`size` 파생 기저(`0x1401cfc61`–`0x1401cfccb`) · `+0x100`,`+0x10c`,`+0x118` raw vec3 3개(`0x1401cfc12`,`0x1401cfc28`,`0x1401cfc41`) · `+0x120`(`0x1401cfc4f`) |
| 26 `collisionmodel` | `+0x20`,`+0x28` 모델 핸들 2워드(`0x1401cfde8`,`0x1401cfdf5`). 모델 참조는 별도 18바이트 레코드 벡터에 push 된다(`0x1401d84b0` @`0x1401cfe0c`). |

---

## 7. 핸들러 동작 요약

공통 헬퍼: `0x14022a120` = 컨트롤포인트 객체(`rcx`)의 월드 위치 `+0x30/+0x34/+0x38` 를
vec4 셋으로 브로드캐스트 · `0x14024f2d0` = 컨트롤포인트 레코드 앞 **0x40(64)바이트** 복사 ·
`0x14022a8a0` = 축/평면 enum(`1/2/3`)에 따라 기저 벡터 구성 ·
`0x14022a530` = 페이드 창 가중치 · `0x1404210f0` = `memcpy`.

> **[2026-08-21 정정] `0x14024f2d0` 은 44바이트가 아니라 `0x40`(64)바이트다.** 이 저장소에서
> 다시 떠서 확인했다 — 함수는 `0x14024f2d0`–`0x14024f331`(`ret`)이고 `.pdata` 항목이 없는
> 리프다. 본문은 `mov eax,[rdx+N] / mov [rcx+N],eax` 를 **dword 16회**(N = `0x00`,`0x04`,…,
> `0x3c` — 첫 쌍 `0x14024f2d0`/`0x14024f2d2`, 마지막 쌍 `0x14024f328`/`0x14024f32b`) 돌고
> `mov rax,rcx`(`0x14024f32e`)로 dst 를 돌려준다. 16×4 = **64바이트** = CP 레코드의
> `+0x00..+0x3f`, 즉 **현재 프레임 월드 4×4 전체**다(레코드 배치는
> `docs/re/particle-control-points.md` §1 — `+0x40` 은 직전 프레임, `+0x80` 은 base 4×4).
> 값에는 영향이 없다(오퍼레이터 VM 은 스냅샷의 `+0x30/+0x34/+0x38` 만 읽는다) — 표기만 틀렸다.
> 같은 모양의 3×3 축소 사본은 `0x1400dd7d0`(4×4 stride `0x10` → 3×3 stride `0xc`, dword 9회,
> `0x1400dd7d0`–`0x1400dd807`)이고 이니셜라이저 opid 13 만 그것을 쓴다.

| opid | 요약 |
| ---: | --- |
| 1 | `gravity`·dt 를 속도(`+0x2c8..`)에 더하고 `(1 − drag·dt)` 로 감쇠한 뒤 위치(`+0x2b0..`)에 적분한다. `flags&1` 이면 오브젝트 변환(`0x1401f87e0` @`0x14023fe13`)으로 gravity 를 회전시키고, 컨테이너 `flags&4` 면 직전 위치(`+0x2e0..`)를 먼저 복사한다. |
| 2 | `force`·dt 를 각속도(`+0x298..`)에 더하고 `drag` 로 감쇠, 각속도를 회전각(`+0x280..`)에 적분한다. 위치는 건드리지 않는다. |
| 3 | `t = age/lifetime` 으로 alpha(`+0x310`)에 `min(1, t/fadein)·min(1, (1−t)/fadeout)` 를 곱한다. 역수는 `rcpps`(`0x1402402b4`,`0x1402402c7`)로 런타임 계산. |
| 4 | `u = clamp01((t − starttime)·rcpDur)` 로 size(`+0x270`)에 `start + delta·u` 를 적용한다. 프롤로그가 매 프레임 `+0x278`(기준 size)에서 되돌린 뒤라 누적되지 않는다. |
| 5 | 같은 `u` 로 color rgb(`+0x2f8/+0x300/+0x308`)를 `start + delta·u` 로 채운다. |
| 6 | 같은 `u` 로 alpha(`+0x310`)를 `start + delta·u` 로 채운다. |
| 7 | 파티클별 난수(`+0x338`)로 frequency/phase/scale 을 min↔max 보간하고, 사인파를 `mask` 축별로 위치(`+0x2b0..`)에 더한다. 사인은 다항 근사(상수 `1.2732`@`0x1404836a0`, `-0.7851`@`0x1404836b0`). |
| 8 | 같은 진동식을 alpha(`+0x310`)에 적용. |
| 9 | 같은 진동식을 size(`+0x270`)에 적용. |
| 10 | `CP[controlpoint]` 위치(+`offset`)로 향하는 스텝을 `1 − dist/threshold` 선형 램프로 만들어 위치·속도에 적용하고, `deletethreshold` 안쪽 입자는 수명을 끊는다. `flags&2` 면 스텝을 거리로 클램프. |
| 11 | 컨트롤포인트로부터의 거리를 `distance` 로 되돌린다: `pos += (distance/|d| − 1)·s·d`. 속도는 건드리지 않는다. |
| 12 | 두 컨트롤포인트를 잇는 선분에 대해 같은 거리 유지 연산을 한다(`controlpointstart`/`end`). |
| 13 | 컨트롤포인트로부터의 거리로 `reductioninner`↔`reductionouter` 를 보간해 속도(`+0x2c8..`)를 감쇠시킨다. |
| 14 | `0x14022a8a0` 으로 만든 축 기저와 3D 노이즈(위상 `phasemin/max`, 속도 `speedmin/max`, `timescale`)로 속도를 교란한다. `+0xd0` 오디오 블록이 세기를 변조하고, 내부 서브 스위치(`jmp rax` @`0x140242aad`, 테이블 `0x24bbf8`, 7분기)가 `mask` 조합을 특수화한다. |
| 15 | 중심 = `CP[controlpoint] + offset`. 반경 거리로 `speedinner`↔`speedouter` 를 램프해 접선 `cross(n, axis)` 방향 속도를 준다. `flags&1` 일 때만 축 성분을 투영 제거(`+0xa0` 마스크). |
| 16 | v1 과 같되 중심이 컨트롤포인트 자체이고, `flags&2` 의 `centerforce`(반경속도 감쇠 `v_r *= 1−cf`)와 `flags&4` 의 ring 인력(`ringradius/ringwidth/ringpulldistance/ringpullforce`)이 추가된다(게이트 `test byte [r14+0x110], 4` @`0x1402434eb`). |
| 17 | 4-입자 그룹 위상으로 이웃을 서브샘플링(`N = count/100 + 1`, `mul 0x51eb851f`/`shr 6`/`inc` @`0x140244153`–`0x140244167`)해 분리·정렬·응집 세 힘을 속도에 더하고 `maxspeed` 로 자른다. 제자리 갱신이라 같은 프레임 안에서 서로 영향을 준다. |
| 18 | 속도 크기를 `maxspeed` 로 클램프한다: `s = min(1, maxspeed·rsqrt(|v|²))`(`rsqrtps` @`0x140244756`, `minps` @`0x140244760`) 를 세 성분에 곱한다. `+0x2c8..+0x2d8` 만 만진다. |
| 19 | `input` 채널(위치/속도/색/알파/크기/수명 등)을 읽어 `inputrange`→`outputrange` 로 사상하고 `transformfunction`(노이즈 `transformoctaves`/`transforminputscale` 포함)을 태워 `output` 채널에 쓴다. VM 안에서 가장 큰 핸들러(9,804바이트)이고 자체 서브 스위치 4개를 쓴다(테이블 `0x24bc30`@`0x140244af4` · `0x24bc80`@`0x140245016` · `0x24bc9c`@`0x140245144` · `0x24bcb4`@`0x14024599b`). |
| 20 | 이벤트(충돌/사망/스폰)가 남긴 값을 `input` 채널로 받아 파티클 속성에 주입한다. 이벤트 버퍼는 `[rsi+0x478]`. |
| 21 | 평면(법선 `+0x20..`, 거리 `+0x60`)과의 충돌을 처리한다. `collisionbehavior` 에 따라 반사(`bouncefactor`)·슬라이드·정지·삭제. |
| 22 | 구(중심 `+0x20..`, 반지름 `+0x50`) 충돌. 컨트롤포인트에 붙는다. |
| 23 | **no-op** — 점프테이블이 전진 블록(`0x140240279`)을 가리킨다. |
| 24 | 씬 경계 상자 충돌(고유 키 없음, 경계는 런타임에서 조회). |
| 25 | 사각형 패치(원점·평면·전방·크기) 충돌. 기저 벡터를 파스 시각에 미리 굽는다. |
| 26 | 3D 모델 메시와의 충돌. 모델 로드/BVH 조회(`0x1401d4580`, `0x140250e00`, `0x1402517d0`)를 태운다. |
| 28–40 | 각 base 와 동일하되, 매 4-입자 그룹마다 `0x14022a530` 으로 창 가중치 `w` 를 구해 `new = old + w·(unweighted − old)` 로 섞는다. |

---

## 8. Waple 미구현 대조

`Sources/WapleCore/ParticleSystem.swift:1269-1580` 의 오퍼레이터 파스 스위치는 **20종**을
구현한다: `movement` `alphafade` `sizechange` `colorchange` `angularmovement` `oscillatealpha`
`oscillateposition` `controlpointattract` `boids` `maintaindistancetocontrolpoint` `vortex`
`vortex_v2` `turbulence` `oscillatesize` `alphachange` `remapvalue` `capvelocity`
`reducemovementnearcontrolpoint` `maintaindistancebetweencontrolpoints` `inheritvaluefromevent`.

페이드 창은 `ParticleSystem.swift:1257-1266` 이 **모든 원소에 병렬 테이블로** 붙이므로
ext opid 28–40 은 base 가 구현된 한 별도 공백이 아니다.

### 미구현 opid

| opid | 이름 | 동봉 자산 도달 | 도달 파일 |
| ---: | --- | ---: | --- |
| 21 | `collisionplane` | **1** | `scenes/particleelementpreviews/collisionplane/particles/new_particle_system.json` |
| 22 | `collisionsphere` | **1** | `…/collisionsphere/particles/new_particle_system.json` |
| 23 | `collisionbox` | **0** | — (원본에서도 no-op) |
| 24 | `collisionbounds` | **1** | `…/collisionbounds/particles/new_particle_system.json` |
| 25 | `collisionquad` | **1** | `…/collisionquad/particles/new_particle_system.json` |
| 26 | `collisionmodel` | **1** | `…/collisionmodel/particles/new_particle_system.json` |
| 27 | (이름 없음) | **0** | — (파서에 경로 없음) |

측정: `Sources/WapleRender/Resources/WEAssets` 의 JSON 1,698개 중 파싱에 성공한 1,667개에서
`operator[].name` 을 집계. 셸 대조도 같다 —
`grep -rho '"name"[[:space:]]*:[[:space:]]*"collisionplane"' . | wc -l` → 1.
(동봉 자산은 `"name" : "x"` 처럼 콜론 앞에도 공백이 있어 `grep -rc '"name": "x"'` 는 0을 낸다.)

### 참고 — 구현된 원소의 도달 수(동봉)

`movement` 264 · `alphafade` 250 · `sizechange` 112 · `angularmovement` 47 ·
`oscillatealpha` 36 · `controlpointattract` 34 · `colorchange` 32 · `turbulence` 22 ·
`oscillateposition` 17 · `remapvalue` 12 · `alphachange` 10 · `vortex` 9 ·
`reducemovementnearcontrolpoint` 9 · `oscillatesize` 8 · `boids` 5 · `vortex_v2` 5 ·
`maintaindistancebetweencontrolpoints` 5 · `capvelocity` 3 ·
`maintaindistancetocontrolpoint` 3 · `inheritvaluefromevent` 1.

창 게이트를 실제로 통과해 **ext opcode 로 승격되는** 인스턴스는 동봉에서 13건뿐이다:
opid 29 ×2 · 30 ×2 · 36 ×4 · 38 ×3 · 39 ×2. 나머지 8종(28·31·32·33·34·35·37·40)은 도달 0.

---

## 9. 재현

```bash
cd <scratchpad>
python3 -c "
from wpe import pe, primary, DATA
import struct
o = pe.va2off(0x14024bb58)
for i in range(40):
    d = struct.unpack_from('<I', DATA, o + i*4)[0]
    print(i+1, hex(pe.imagebase + d))
"
# 이름 체인
python3 -c "
from vdis2 import dis
dis(0x1401c5490, 0x1401d152c)" | grep -B6 stricmp
# 승격 opcode 13개
python3 -c "
from vdis2 import dis
import re
for l in dis(0x1401c5490,0x1401d152c,show=False):
    if re.search(r'mov r9d, 0x(1[b-f]|2[0-8])\$', l.split(';')[0].strip()): print(l)"
```

동봉 자산 도달 수:

```bash
cd Sources/WapleRender/Resources/WEAssets
grep -rho '"name"[[:space:]]*:[[:space:]]*"collisionquad"' . | wc -l
```

---

> **[2026-08-21 · VA 인용 정정 1건]** `scripts/re/va_citations.py` 전수 대조로 잡았다.
> `collisionmodel` 행의 "모델 참조 push" 호출 자리가 `0x1401cfdcc` 로 적혀 있었는데 그 주소는
> `movzx edx, byte ptr [rbp + 0x2238]` 의 **한복판**(+4)이다. 이미지 전체에서 `call 0x1401d84b0`
> 을 바이트로 훑으면 자리가 **둘뿐**이고(`0x1401c6fda` · `0x1401cfe0c`) 이 함수 안의 것은
> `0x1401cfe0c` 다. 바로 앞이 `mov dword ptr [rbp + 0x1a0], 3` / `lea rdx, [rbp + 0x1a0]` /
> `mov rcx, rsi` 로 인자를 세우는 자리라 문맥도 맞는다. `0x1401cfe0c` 로 고쳤다.
