# `disablepropagation` — 무엇이 전파되고 무엇이 차단되는가

**조사일 2026-08-21 · WE 2.8.42**
`wallpaper64.exe` (md5 `438cb215f20a8f6c38f57fbc3d9da588`, imagebase `0x140000000`) ·
`bin/wallpaperui.exe` (imagebase `0x140000000`) · `bin/scenescript64.dll` (imagebase `0x180000000`)

이 문서는 **선행 조사(`docs/re/pointer-interaction.md` §4.1·§7 W-4)를 믿지 않고 처음부터 다시 뜬**
독립 재확인이다. 문자열 스캔 → xref → 디스크립터 → 비트 → **비트 소비처 전수** → 트랜스폼 합성부
→ 코퍼스 순으로, 각 단계마다 "다른 문서가 적어 둔 VA 를 베끼지 않고" 직접 계산했다.
결과적으로 선행 조사와 **결론이 일치**하고, 그 과정에서 **별개의 오류 1건**(`solid` 생성자 기본값)을
새로 찾았다.

- 원본 스캔 대상: 설치본 전 트리의 `*.exe`/`*.dll`/`*.scr` **156개**
- 코퍼스: 동봉 `Sources/WapleRender/Resources/WEAssets/**`(json 1,698) ·
  설치본 `wallpaper_engine/**`(json 2,143) · 워크샵 통계 `spec/corpus/scene-schema.json`(씬 162)

---

## 0. 결론

| # | 주장 | 판정 | 확신 |
|---|---|---|---|
| 1 | `disablepropagation` 문자열은 `wallpaper64.exe`(엔진)와 `wallpaperui.exe`(에디터)에만 있다. 다른 바이너리 0건 | — | **확정** — 설치본 바이너리 156개 ASCII+UTF-16LE 전수 스캔 |
| 2 | 엔진의 파스 지점은 **1곳뿐**이다 — 씬 오브젝트 **기저 클래스** 프로퍼티 디스크립터 `sub_1401e0530`. 타입별 파서 4개가 아니다 | — | **확정** — 이미지 전역 disp32 xref 스캔에서 `lea` 2건, 둘 다 같은 함수 안(엔트리 이름 세팅 1 + 다음 엔트리 준비 1) |
| 3 | 저장 위치는 `[obj+0x120]` **bit14**(`0x4000`), dword 비트필드. 오브젝트 타입과 무관하게 **같은 오프셋** | — | **확정** — 게터/세터/직렬화/역직렬화 4 썽크 전부 `0xe`/`0x4000` |
| 4 | 생성자 기본값은 **false**(bit14 = 0) | — | **확정** — 기저 ctor `0x1401ddc72` `mov word [r14+0x120], 0x2001` |
| 5 | **bit14 를 읽는 코드는 이미지 전체에서 단 1곳** — 커서 이벤트 디스패처 `sub_140189e10` 안의 `0x14018a877` | — | **확정** — 전 함수 선형 디스어셈블 후 `bt/bts/btr/btc/shr/sar …,0xe` + `test/and/or/cmp …,0x4000` + 상위바이트 `…,0x40` 전수(197 블록) 검사 |
| 6 | 거기서 하는 일은 **커서 히트테스트 루프의 break** — 아래 오브젝트로 클릭이 내려가지 않게 막는다 | — | **확정** — §3 |
| 7 | WE 의 **부모→자식 트랜스폼 합성**(`sub_1401850a0`)은 `[obj+0x180]`(parent)만 보고 **플래그를 전혀 읽지 않는다** | — | **확정** — 함수 전문에 `+0x120` 참조 0건, 10개 파생 vtable 전부 이 슬롯을 공유(오버라이드 0) |
| 8 | 따라서 Waple 의 현재 동작(`disablePropagation` → 부모 트랜스폼 상속 차단)은 **틀렸다** | — | **확정** |
| 9 | `propagation` 은 **클릭/커서 이벤트의 전파**다. 에디터 라벨이 `Disable click propagation` | — | **확정** — `wallpaperui.exe` 프로퍼티 행 정의가 JSON 키와 로케일 키를 같은 호출에 넘긴다(§5) |
| 10 | **덤**: 형제 키 `solid`(같은 워드 bit13)의 **생성자 기본값은 `true`** 다. Waple 과 기존 문서표는 `false` 로 적고 있다 | — | **확정 · 신규 정정** — 같은 ctor 리터럴 `0x2001` 의 bit13 |
| 11 | 워크샵 코퍼스 `disablepropagation:true` **34건이 전부 `parent` 를 가졌는가** | — | **[미해결]** — 조인 통계가 기록돼 있지 않고 원본 코퍼스가 이 컨테이너에 없다(§6.3) |

---

## 1. 문자열과 파스 지점

### 1.1 전 바이너리 스캔

설치본 전 트리(하위 디렉터리 포함)의 `*.exe`/`*.dll`/`*.scr` **156개**를
ASCII 와 UTF-16LE 로 전수 스캔했다. 문자열을 가진 파일은 **6개**뿐이다.

| 바이너리 | `disablepropagation` | 비고 |
|---|---:|---|
| `wallpaper64.exe` / `wallpaper32.exe` | 1 | 엔진 |
| `distribution/wallpaper{32,64}.exe` | 1 | 위와 동일 파일(배포 사본) |
| `bin/wallpaperui.exe` · `distribution/bin/wallpaperui.exe` | 1 | 에디터 |
| 그 외 150개(`scenescript64.dll`·`webwallpaper64.exe`·`resourceutil64.dll`·`cloneextensions64.dll`·`mediaextensions64.dll`·`winrtutil64.exe`·`edgewallpaper64.exe`·`resourcecompiler64.exe` 포함) | **0** | — |

UTF-16LE 는 전 바이너리 **0건**이다. `scenescript64.dll` 의 `propagation` 1건은
`"propagation roots: "`(내장 LLVM 스케줄러 로그)라 무관하다.

### 1.2 xref — `lea` 2건, 함수 1개

문자열 VA 는 `0x140490338`(파일 오프셋 `0x48f138`, 길이 18 = `0x12`).
15바이트를 넘으므로 SSO 가 아니고 `lea` 로 온다(브리프 함정 10). 그래도 `lea` 선형 스캔을 믿지 않고
**이미지 전 섹션 바이트 스캔**으로 disp32 xref 를 떴다(명령어 끝이 disp32+0…8 바이트 뒤일 수 있는
경우까지 모두 시도, 절대 qword/RVA dword 도 함께). 결과:

| VA | 실제 명령 | 판정 |
|---|---|---|
| `0x140180aa5` | `mov rcx, [rsi+0x30f8]` 의 일부 | 오탐 |
| `0x1401e123f` | `movzx eax, byte [rip+0x2af0ed]` → `0x140490330` | 오탐(문자열 풀 이웃) |
| `0x1401e129a` | `lea rdx, [rip+0x2af097]` → `0x140490338` | **진짜** |
| `0x1401e131a` | `lea rdx, [rip+0x2af017]` → `0x140490338` | **진짜** |
| `.rdata` 4건 | 문자열 풀 자기 자신 | 오탐 |

둘 다 `sub_1401e0530`(`.pdata` 범위 `0x1401e0530`–`0x1401e1389`, 조각 1개) 안이다.

### 1.3 그 함수는 **기저 오브젝트 프로퍼티 디스크립터 등록부**다

`sub_1401e0530` 은 전역 레지스트리 `0x1404e8250`(프로퍼티)과 `0x1404e8290`(스크립트 메서드)에
엔트리를 19개 만든다. 엔트리마다 패턴이 같다:

```
mov  rbx, [rbp-0x38]                 ; 방금 만든 디스크립터
lea  rdx, <이름>;  mov r8d, <len>
lea  rcx, [rbx+0x68]                 ; +0x68 = 프로퍼티 이름   (+0x38 = 스크립트 메서드 이름)
call sub_14000f880                   ; 이름 대입
mov  dword [rbx+0x34], <멤버 오프셋>
mov  dword [rbx+0x30], <타입코드>
mov  qword [rbx+0x38/0x40/0x48/0x50], <역직렬화/직렬화/세터/게터>
```

**브리프 함정 16 이 경고한 그 배치다** — 다음 엔트리의 이름 `lea` 가 현재 엔트리의 스토어 **사이에**
끼어 있다(`0x1401e129a` 의 `lea "disablepropagation"` 은 `solid` 엔트리 한복판에 있다).
순진하게 덤프하면 한 칸 밀린다. 이름 대입 `call sub_14000f880` 을 기준으로 잘라 읽으면:

| 이름 | 필드 | 멤버 오프셋 | 타입코드 |
|---|---|---|---|
| `origin` | `+0x68` | `0x128` | 2 (vec3) |
| `scale` | `+0x68` | `0x134` | 2 |
| `angles` | `+0x68` | `0x140` | 2 |
| `parallaxDepth` | `+0x68` | `0x170` | 1 (float) |
| `sortorder` | `+0x68` | `0x124` | — |
| `getTransformMatrix`·`rotateObjectSpace`·`lookAt`·`lookAtYaw`·`setParent`·`getParent`·`getChildren`·`getAttachmentIndex`·`getAttachmentMatrix`·`getAttachmentOrigin`·`getAttachmentAngles` | `+0x38` | — | 스크립트 메서드 |
| `name` | `+0x68` | `0x1d8` | 5 (string) |
| **`solid`** | `+0x68` | **`0x120`** | 6 (bool) |
| **`disablepropagation`** | `+0x68` | **`0x120`** | 6 (bool) |

`origin`/`scale`/`angles`/`name`/`parallaxDepth`/`sortorder` 와 **같은 테이블**이다 —
즉 이건 **모든 씬 오브젝트가 공유하는 기저 클래스**의 키다. Waple 처럼 이미지/텍스트/파티클/카메라
파서 4곳에 흩어져 있는 게 아니라, **원본은 한 곳**이고 파생 타입이 그걸 상속한다.

> 이미지 전용 키(`perspective` 등)는 별도 레지스트리 `0x1404e8360` 에 `sub_1401ee520` 이 등록한다.
> `disablepropagation` 은 거기에 **없다**.

---

## 2. 저장 위치 — `[obj+0x120]` bit14

디스크립터가 심은 4개 썽크를 전부 떴다. `rdx` 는 디스크립터+0x30 이라 `[rdx+4]` = 멤버 오프셋(`0x120`).

| 역할 | VA | 핵심 |
|---|---|---|
| 역직렬화(JSON→멤버) | `0x14019bb40` | `movsxd r14,[rdx+4]` · `mov r15,[rcx+8]` · `mov ebp,[r14+r15]` · `cmp byte [r8+8], 5` → `call asBool 0x140086300` → `btr edx,0xe` / `bts ecx,0xe` / `cmove` → `mov [r14+r15], ecx` (`0x14019bb75`–`0x14019bb82`) |
| 직렬화(멤버→JSON) | `0x14019bc10` | `test dword [rcx], 0x4000` · `setne` (`0x14019bc1a`) |
| 세터(스크립트) | `0x14019bd10` | `btr eax,0xe` / `bts r9d,0xe` (`0x14019bd20`) |
| 게터(스크립트) | `0x14019bd50` | `shr edx,0xe; and dl,1` (`0x14019bd57`) |

형제 키 `solid` 는 **같은 오프셋의 bit13**(`0x2000`)이다 — 세터 `0x14019c5c0`(`btr eax,0xd`),
게터 `0x14019c600`(`shr edx,0xd`), 직렬화 `0x14019c4ca`(`test dword [rcx],0x2000`).

### 2.1 태그 5 게이트와 생성자 기본값 (브리프 함정 15)

역직렬화기는 `cmp byte [r8+8], 5`(Json 타입 == bool)가 아니면 **스토어를 통째로 건너뛴다.**
`"disablepropagation": 1`(정수)은 값을 바꾸지 못하고 **생성자 값이 남는다.**

기저 생성자 `sub_1401ddbb0`:

```
0x1401ddc72  66 41 c7 86 20 01 00 00  01 20    mov word [r14+0x120], 0x2001
```

`0x2001` = **bit0(1) + bit13(0x2000)**. 따라서

- `visible`  (bit0)  기본 **true**  ✔ 기존 문서표와 일치
- `solid`    (bit13) 기본 **true**  ✘ 기존 문서표·Waple 은 `false`
- `disablepropagation` (bit14) 기본 **false** ✔ 기존 문서표와 일치

같은 ctor 가 `[+0x180] = 0`(parent 없음), `[+0x190] = -1`(attachment 없음),
`[+0x134/0x138/0x13c] = 1.0`(scale), `[+0x170] = 1.0`(parallaxDepth), `[+0xe0..0x11c]` 단위행렬,
`[+0x1d8]` 빈 `std::string`(name)을 깐다.

이 ctor 는 **기저**가 맞다 — 오브젝트 팩토리 `sub_14018ff60` 의 6개 분기와 `sub_1401e6980`,
`sub_140256560` 이 각각 자기 vtable 을 깔기 **전에** 이걸 호출한다(직접 call xref 8건).
파생 ctor 중 bit13 을 **끄는 곳은 없다**(있는 건 `and word [rdi+0x120], 0xfffe` = bit0 제거 1건,
`or …, 0x800` / `or …, 0x100` 뿐).

---

## 3. bit14 소비처 — 전수 조사

### 3.1 방법

`.pdata` 로 얻은 함수 범위 6,277개(코드 4,193,303바이트)를 전부 선형 디스어셈블하고 다음을 전수 수집했다.

1. `bt|bts|btr|btc <any>, 0xe` 와 `shr|sar <any>, 0xe`
2. `test|and|or|cmp|xor <any>, 0x4000`
3. 상위 바이트 경유(`test ah|bh|ch|dh, 0x40`) — **0건**
4. `+0x121` 오프셋 바이트 접근 — **0건**
5. 가상 게터(`sub_140185000`: `movzx eax, word [rcx+0x120]; ret`) 경유를 잡기 위해,
   `call` 직후 3명령 안에서 `eax/ax` 에 대한 bit14 연산 — 5건, 그중 오브젝트 플래그 출처는 1건

1~2 로 197개 블록이 나왔고, 그중 **비-스택 메모리 피연산자를 가진 80블록**을 손으로 봤다.

### 3.2 결과 — **오브젝트 플래그워드에서 bit14 를 읽는 곳은 정확히 1곳**

```
0x14018a868   movzx edx, byte [rbp+0x128]        ; 커서가 창 안인가(현재)
0x14018a86f   movzx eax, word  [r15+0x120]       ; ← 오브젝트 플래그
0x14018a877   bt   ax, 0xe                       ; ← disablepropagation
0x14018a87c   jae  0x14018a89f                   ;   0 → 다음(아래) 오브젝트로 계속
0x14018a87e   test al, 1                         ; bit0 = visible
0x14018a880   je   0x14018a89f                   ;   안 보이면 막지 않는다
0x14018a882   mov  rcx, [r15+0x180]              ; parent
0x14018a889   test rcx, rcx
0x14018a88c   je   0x14018a411                   ;   부모 없음 → **루프 탈출**
0x14018a892   call 0x140185010                   ;   조상 체인 visible?
0x14018a897   test al, al
0x14018a899   jne  0x14018a411                   ;   보인다 → **루프 탈출**
0x14018a89f   mov  rbx,[rbp+0x120]; jmp 0x14018a3ef   ; 계속
```

`sub_140185010` 은 `test byte [rcx+0x120], 1` → `rcx = [rcx+0x180]` 재귀 = **조상까지 다 보이는가**.

같은 워드의 다른 비트를 쓰는 곳 — **bit14 가 아님을 보이려고** 함께 뜬 것이다.
비트 번호와 마스크·VA 는 직접 확인했지만, "뜻" 칸은 bit0/13/14 만 **확정**이고
나머지는 **추정**이다(이 문서의 결론과 무관해서 끝까지 몰지 않았다).

| 비트 | 마스크 | 쓰는 곳 | 뜻 | 등급 |
|---:|---|---|---|---|
| 0 | `1` | `sub_140185010`(`0x140185014`) 외 | `visible` | 확정 |
| 1,2 | `2`,`4` | `sub_1401de470`/`sub_1401de750`(계층 갱신)·`sub_1401e8aa0` | 트랜스폼/계층 더티 | 추정 |
| 7 | `0x80` | `0x14018a071` `mov eax,0x80` → `and ax,[r15+0x120]` (`0x14018a076`) → `cmovne` 로 두 좌표 버퍼 중 택일 | `image.perspective`(기존 문서표) 로 히트테스트 좌표 소스를 고르는 것 | 추정 |
| 8 | `0x100` | `0x140190952`·`0x14019050b` | 팩토리가 타입별로 세팅 | 추정 |
| 9 | `0x200` | 정렬 `sub_1401865c0`(`r11d=0x200`, 5곳) · `config.fullscreen` 파서 `0x1401fae25` | 깊이정렬 제외(정렬키를 `-inf` 로) | 추정 |
| 10,11 | `0xc00` | `sub_14018aac0`(`ebp=0xc00`) | 커서 서브루틴 필터 | 추정 |
| **13** | `0x2000` | `0x14018a00b` `mov r8d,0x2000` → `test word [r15+0x120], r8w` (`0x14018a02d`) | **`solid`** — 히트테스트 참가 게이트 | **확정** |
| **14** | `0x4000` | `0x14018a877` | **`disablepropagation`** | **확정** |

### 3.3 `sub_140189e10` 이 무엇인가 — 커서 이벤트 디스패처

- 호출부는 프레임 갱신 `sub_14017fa70` 의 `0x1401802d5`, **마우스 좌표를 `[scene+0x188..0x190]` 에
  쓴 직후**다.
- 루프는 오브젝트 배열을 **뒤에서 앞으로**(`sub eax,1; jns` @ `0x14018a404`) 돈다 = 위에서 아래로.
- 진입 게이트가 `solid`(bit13)다(`0x14018a02d`, 아니면 `je 0x14018a3fa` 로 다음 오브젝트).
- 호버 상태는 오브젝트 포인터의 FNV-1a 64 해시(basis `0xcbf29ce484222325`, prime `0x100000001b3`,
  `0x14018a122`–`0x14018a1bf`)로 두 해시맵을 친다.
- 실제 판정은 가상 `[vtbl+0x88]`(`0x14018a2bb`).
- 히트하면 전역 핸들러 리스트 `[scene+0x17e0]` 를 돌며, 핸들러의 이벤트 마스크 `[h+0x40]` 비트를
  보고 `[h+0x48]==obj` 이거나 `[h+8]==0` 인 것에만 `r9d = <이벤트 id>` 로 발화한다.

이벤트 id 를 `scenescript64.dll` 의 훅 이름 테이블 `0x1819a3ee0` 에서 **직접 읽어** 대조했다:

| 발화 VA | `r9d` | 마스크 | 훅 이름(테이블 idx) |
|---|---:|---|---|
| `0x14018a5c5` | 8 | `[h+0x40] & 0x100` | `cursorEnter` (8) |
| `0x14018a67e` | 0xa | `& 0x400` | `cursorMove` (10) |
| `0x14018a833` | 0xb | `& 0x800` | `cursorClick` (11) |
| `0x14018a74e` | 0xc/0xd | `bt [h+0x40], r13d` | `cursorDown`(12) / `cursorUp`(13) — `r13 = 0xc | (down^1)` |
| `0x14018a944` | 0xd | `& 0x2000` | `cursorUp` (13) |

훅 테이블(내가 직접 덤프): `0 init · 1 update · 2 resizeScreen · 3 destroy · 4 applyUserProperties ·
5 applyGeneralSettings · 6 animationEvent · 7 cursorHitTest · 8 cursorEnter · 9 cursorLeave ·
10 cursorMove · 11 cursorClick · 12 cursorDown · 13 cursorUp · 14~18 media*`.

즉 이 루프는 **마우스 이벤트를 z-순서로 오브젝트에 배달하는 곳**이고,
bit14 는 그 배달을 **현재 오브젝트에서 끊는다**.

---

## 4. 트랜스폼 전파 경로 — 플래그를 보지 않는다

`getTransformMatrix` 스크립트 썽크 `0x1401df5e0` 이 `call [rax+0x80]` 을 한다.
vtable 베이스는 `0x14048ec88`(팩토리 `0x1401907ff` 가 이 값을 `[obj]` 에 깐다)이고
`+0x80` = `0x14048ed08` = **`sub_1401850a0`**.

`sub_1401850a0` 전문(`0x1401850a0`–`0x1401852f6`)은 이렇다:

```
; ── 캐시 게이트 (0x1401850a9 – 0x1401850ff) ────────────────────────────────
stamp = [obj+0xd0];
if (stamp == 0)                       goto rebuild;          ; 0x1401850b6
if ([obj+0x190] >= 0 && stamp != [[obj+0xc8]+0x144]) goto rebuild;  ; 0x1401850d0
p = [obj+0x180];                                             ; 0x1401850d2
if (p != 0) {
    if (stamp < [p+0xd0])             goto rebuild;          ; 0x1401850e5
    if (!sub_140185040(p))            goto rebuild;          ; 0x1401850ee
}
return obj+0xe0;                      ; 캐시 히트 (0x1401850f0)

; ── rebuild (0x140185100 – ) ───────────────────────────────────────────────
[obj+0xd0] = [[obj+0xc8]+0x144];                ; 프레임 스탬프
행0 = scale.x * basis[0x14c..0x154]             ; -> obj+0xe0..0xe8   (ec = 0)
행1 = scale.y * basis[0x158..0x160]             ; -> obj+0xf0..0xf8   (fc = 0)
행2 = scale.z * basis[0x164..0x16c]             ; -> obj+0x100..0x108 (10c = 0)
행3 = origin[0x128..0x130], w = 1.0             ; -> obj+0x110..0x11c

rcx = [obj+0x180];                              ; <- parent 포인터 (0x14018528a)
if (rcx == 0) return obj+0xe0;                  ;   부모 없음 -> 로컬이 곧 월드 (0x140185294)
if ([obj+0x190] >= 0) parent->vtbl[0x78](&obj->M);   ; attachment (0x1401852a6)
pw = sub_1401850a0([obj+0x180]);                ; 부모 월드 재귀 (0x1401852b0)
sub_14005ecb0(/*out*/tmp, /*rdx*/pw, /*r8*/&obj->M);  ; 행렬곱 (0x1401852c0)
obj+0xe0 = tmp;                                 ; 64바이트 복사 (0x1401852c5–0x1401852df)
```

> 곱 순서(`M <- Local · ParentWorld`)와 행/열 주도 판정은 `scene-object-model.md` §4.4 가 이미
> 확정했다. 여기서 필요한 건 **곱한다는 사실과 그 게이트가 무엇인가** 뿐이라 재판정하지 않았다.

- 함수 전체에 **`+0x120` 참조가 0건**이다. `bt`/`test …,0x4000` 도 0건.
- 부모가 있으면 **무조건** 합성한다. 게이트는 `parent != null` 하나뿐이다.
- `getParent` 썽크 `0x1401e0180` 이 `mov rdx,[rcx+0x180]` 이므로 `+0x180` 이 `parent` 가 맞다
  (`getChildren` `0x1401e0190` 은 `[obj+0x198]`–`[obj+0x1a0]` 벡터).
- 이 슬롯을 갖는 vtable 을 `.rdata` 전수 스캔했더니 **10개**인데 전부 값이 `0x1401850a0` 이다 —
  **어떤 파생 타입도 오버라이드하지 않는다.**

> 즉 "부모 트랜스폼 상속을 끄는" 플래그는 WE 엔진에 **존재하지 않는다**.
> `disablepropagation` 은 물론이고 다른 비트도 이 함수에 영향을 주지 못한다.

---

## 5. `propagation` 이 무엇의 전파인가 — 에디터가 답을 적어 놨다

`wallpaperui.exe` 의 오브젝트 프로퍼티 패널 빌더가 **JSON 키와 로케일 키를 같은 호출에** 넘긴다.

```
0x14019568a  lea r8,  0x140ad8552
0x140195691  lea rdx, "disablepropagation"
0x140195698  lea rcx, [rsp+0x60]
0x14019569d  call 0x140236d90
…
0x1401956ba  lea r8,  "ui_editor_properties_disable_click_propagation"
0x1401956c1  mov r9,  rbx
0x1401956c4  lea rdx, "disablepropagation"
0x1401956cb  call 0x140160f60          ; addProperty(key, localeKey, widget)
```

바로 위 엔트리는 `solid` 이고 로케일 키가 `ui_editor_properties_enable_click_events` 다.
같은 (`solid`, `disablepropagation`) 쌍이 오브젝트 패널 빌더 **세 곳**에 반복된다 —
`solid` 라벨 `lea` 기준 `0x140195674` · `0x14019627f` · `0x1401973a4`
(세 번째는 바로 위에서 `perspective` 를 등록하므로 이미지 패널이다).
(`wallpaperui.exe` 에는 엔진과 같은 디스크립터 등록부 사본도 링크돼 있다 — `0x1402b7585`.)

로케일 실값(`wallpaper_engine/locale/`):

| 키 | en-us | de-de | zh-chs |
|---|---|---|---|
| `solid` → `ui_editor_properties_enable_click_events` | **Enable click events** | Klick-Events aktivieren | 启用点击事件 |
| `disablepropagation` → `ui_editor_properties_disable_click_propagation` | **Disable click propagation** | Klick-Weiterleitungen deaktivieren | 禁用点击穿透 |

### 5.1 배제한 후보

| 후보 | 배제 근거 |
|---|---|
| **부모 트랜스폼 상속** | `sub_1401850a0` 이 플래그를 아예 안 읽는다(§4). 10 vtable 전부 오버라이드 없음 |
| **가시성 전파** | 가시성 전파는 존재하지만 **bit0**(`visible`)이고, `sub_140185010` 의 부모 재귀다. bit14 는 그 재귀의 **호출자**일 뿐 |
| **알파/색 상속** | bit14 를 읽는 코드가 렌더 경로에 0건(§3.2 전수) |
| **오디오/스크립트 이벤트 일반** | bit14 소비 지점의 발화 훅 id 가 8·10·11·12·13 = `cursor*` 전용(§3.3). `media*`(14~18)나 `animationEvent`(6)는 이 루프를 타지 않는다 |
| **깊이정렬/렌더순서** | 정렬 함수 `sub_1401865c0` 이 보는 비트는 **bit9**(`r11d = 0x200`)다 |

### 5.2 주입기가 따로 있는가 (브리프 함정 3)

없다. `Json::Value::find`(`0x140087490`) 호출은 역직렬화기 안의 `find("value")` 하나뿐이고
(애니메이션/유저프로퍼티 바인딩 `{"value": …}` 래퍼를 벗기는 용도),
`disablepropagation` 이라는 이름으로 DOM 에 기본값을 심는 코드는 없다.
키가 없으면 §2.1 의 ctor 기본값(false)이 그대로 남는다.

### 5.3 핸들러가 둘 붙는가 (브리프 함정 2)

디스크립터 엔트리는 1개, 썽크는 역직렬화/직렬화/세터/게터 4개이며 전부 **같은 bit14** 를 만진다.
중복 등록·중복 핸들러는 없다.

---

## 6. 코퍼스 도달

### 6.1 동봉 자산 — **0건** (내가 직접 재측정)

`Sources/WapleRender/Resources/WEAssets/**` 의 `*.json` **1,698개**
(`scene.json` 171 · `project.json` 170 · `preset.json` 82 · `gifscene.json` 1 · 그 외 1,274)에
`disablepropagation` 문자열 **0건**.

### 6.2 설치본 — **0건** (내가 직접 재측정)

`/home/user/Waple-wallpaper-source/wallpaper_engine/**` 의 `*.json` **2,143개**
(`scene.json` 184 · `project.json` 191 · `preset.json` 82 · `gifscene.json` 2 · 그 외 1,684)에
`disablepropagation` 문자열 **0건**. `projects/defaultprojects/**` 도 포함해서 0건이다.

> 즉 **Waple 이 함께 내보내는 자산과 WE 설치본 어디에도 이 키가 없다.**
> 이 키는 워크샵(사용자 제작) 벽지에만 존재한다.

### 6.3 워크샵 코퍼스 — **기록된 측정치 인용**(원본 미보유)

워크샵 코퍼스(`Z:\SteamLibrary\steamapps\workshop\content\431960`)는 이 컨테이너에 없다.
아래는 `spec/corpus/scene-schema.json`(`weVersion 2.8.42`, 씬 **162**종,
생성 `scripts/spec/measure_scene_schema.py`)에 **기록된 값**이고, 나는 재측정하지 못했다.

| 오브젝트 타입 | 키를 가진 오브젝트 수 | 키가 나온 씬 수 | `true` | `false` | Waple 파스 함수 |
|---|---:|---:|---:|---:|---|
| `image` | 2,097 | 63 | **34** | 2,063 | `parseLayer` |
| `text` | 742 | 53 | 0 | 742 | `parseText` |
| `particle` | 408 | 53 | 0 | 408 | `parseParticle` |
| `node` | 595 | 36 | 0 | 595 | (미파스) |
| `sound` | 188 | 53 | 0 | 188 | (미파스) |
| `model` | 265 | 6 | 0 | 265 | (미파스) |
| `camera` | 34 | 14 | 0 | 34 | `parseCameraObject` |
| `light` | 16 | 7 | 0 | 16 | (미파스) |
| `shape` | 14 | 7 | 0 | 14 | (미파스) |

**범위 라벨**: "63씬" 은 *키가 등장한* 씬 수이지 *`true` 인* 씬 수가 아니다.
`true` 34건이 몇 개 씬에 흩어져 있는지는 기록돼 있지 않다.

> **[미해결] — `true` 34건 중 `parent` 를 가진 것이 몇 건인가.**
> `scene-schema.json` 은 키별 도수만 기록하고 `disablepropagation × parent` 조인은 기록하지 않는다.
> `waple.parentTransformRegistration` 항목도 부모-자식 타입쌍만 센다.
> Waple 안의 주석(`SceneDocument.swift:2471`-`2473`)은 "34건 전부 parent 보유" 라고 적고 있으나
> 그 근거가 저장소 어디에도 남아 있지 않아 **독립 확인 불가**다.
> 확인하려면 `measure_scene_schema.py` 에
> `sum(1 for o in objs if o.get("disablepropagation") is True and "parent" in o)` 한 줄을 추가해
> 워크샵 코퍼스가 있는 머신에서 재측정해야 한다.

---

## 7. Waple 이 지금 무엇을 하고 있나

파스(값은 정상 — 태그5 게이트 `weBool` 포함):

| 위치 | 타입 |
|---|---|
| `Sources/WapleCore/SceneDocument.swift:1930` | `SceneLayer` |
| `Sources/WapleCore/SceneDocument.swift:2196` | `SceneCameraObject` |
| `Sources/WapleCore/SceneDocument.swift:2272` | `SceneTextLayer` |
| `Sources/WapleCore/SceneDocument.swift:2879` | `SceneParticle` |

소비(**여기가 틀렸다** — 실물에 대응물이 없다):

| 위치 | 하는 일 |
|---|---|
| `:2476` | `composeParentTransforms` 의 `composeTargets` 에서 제외 |
| `:2483`,`:2487`,`:2519` | `noPropagate` 집합 + `world()` 조상 재귀 차단 |
| `:2600`,`:2604`,`:2615` | `buildParentTransformMap` 의 `noPropagate` |
| `:2626` | `worldParentTransform` 조상 재귀 차단 |
| `:2648`,`:2651` | `composeTextParentTransforms` 스킵 |
| `:2675`,`:2678` | `composeParticleParentTransforms` 스킵 |

반면 Waple 의 포인터 경로(`Sources/WapleRender/SceneRenderer.swift:302`–`362`)는
`dispatchSceneEvent` 전역 브로드캐스트 + 이름 매칭 AABB 호버라서
`solid` 게이트도, z-순서 순회도, 전파 차단도 **하나도 없다**.
`isSolid`/`disablePropagation` 은 파스만 되고 포인터 경로에서 **소비 0건**이다.

---

## 8. 위험 평가 — 고치면 무엇이 어떻게 바뀌나

### 8.1 그림이 바뀌는 대상

`composeTargets` 는 이미 `parent != nil` 을 요구하므로, 가드를 떼서 **새로 합성 대상이 되는 것**은
`disablepropagation == true` **이고** `parent` 를 가진 오브젝트뿐이다. 또 `noPropagate` 를 없애면
그런 오브젝트를 **조상으로 갖는 자손**의 월드값도 조상 체인 끝까지 다시 합성된다.

| 범위 | 바뀌는 건수 | 근거 |
|---|---:|---|
| 동봉 `WEAssets`(json 1,698) | **0** | §6.1 직접 측정 |
| 설치본 `wallpaper_engine`(json 2,143) | **0** | §6.2 직접 측정 |
| 워크샵 코퍼스 `text`/`particle`/`camera` | **0** | §6.3 — 전건 `false`. Waple 이 이들에 건 가드는 **전부 no-op** 이었다 |
| 워크샵 코퍼스 `image` | **≤ 34** (그리고 그 자손) | §6.3 — 정확한 수는 [미해결] |

즉 **동봉/설치본 자산의 렌더 결과는 한 픽셀도 안 바뀐다.**
바뀔 수 있는 최대치는 워크샵 이미지 레이어 34개 + 그 자손이고, 그 34개가 실제로 `parent` 를
가졌는지는 원본 코퍼스 없이 확정 불가다(§6.3). 대표 자산 경로도 코퍼스가 없어 특정할 수 없다 — **[미해결]**.

### 8.2 방향은 어느 쪽인가

고치면 그 레이어들은 "저작 로컬 좌표 그대로" 에서 "부모 월드 × 로컬" 로 **이동한다**.
WE 실물이 무조건 합성하므로(§4) 이동한 쪽이 맞다.
현재 Waple 은 부모가 원점이 아닌 한 그 레이어를 **틀린 자리에** 그리고 있다.

### 8.3 리그레션 위험

- 낮음: 가드가 하는 일이 "합성 제외" 뿐이라, 제거하면 코드 경로가 **기존에 검증된 무조건 합성 경로**로
  합류한다. 새 경로가 생기지 않는다.
- `text`/`particle`/`camera` 쪽 가드는 코퍼스 관측상 항상 거짓이라 제거해도 관측 가능한 변화가 없다.
- 다만 §6.3 이 미해결이라 **워크샵 씬 34건의 실제 이동량을 사전에 계산할 수 없다.**
  스크린샷 회귀가 있는 씬이 그중에 있다면 골든 이미지 갱신이 필요하다.

---

## 9. 넘길 정정안 (이 문서 밖 — 소유권이 다른 파일)

> **행번호 주의**: 아래 `SceneDocument.swift` 행번호는 **2026-08-21 조사 시점** 값이다.
> 같은 파일을 여러 에이전트가 동시에 고치고 있어 드리프트한다. 적용 전에
> `grep -n "disablePropagation\|noPropagate" Sources/WapleCore/SceneDocument.swift` 로 다시 잡아라.

### 9.1 `Sources/WapleCore/SceneDocument.swift` — 트랜스폼 가드 제거

**:2471–2477**

```swift
// before
        // E1: disablePropagation=true 인 레이어는 부모 트랜스폼 상속을 차단 — composeTargets 에서
        // 제외해 저작 로컬 좌표를 그대로 유지한다(코퍼스 실측 34건, 전부 parent 보유라 종전엔
        // 무조건 합성 대상이었다). 이 레이어가 다른 자식의 부모로 쓰일 때는 그 자식이 이 레이어의
        // "저작 로컬 값 = 유효 위치"를 상속받는다(noPropagate 가드 — world() 참조).
        let composeTargets = camera3D != nil ? [] : layers.indices.filter {
            guard layers[$0].parent != nil, !layers[$0].disablePropagation else { return false }
```

```swift
// after
        // W-4 정정: `disablepropagation` 은 **커서 클릭 전파 차단**이지 트랜스폼 상속과 무관하다
        // (object-propagation.md — 실물 합성부 `0x1401850a0` 은 `[obj+0x180]`(parent)만 보고
        // 플래그워드 `+0x120` 을 아예 읽지 않는다. bit14 유일 소비처는 커서 디스패처 `0x14018a877`).
        // 부모가 있으면 무조건 합성한다.
        let composeTargets = camera3D != nil ? [] : layers.indices.filter {
            guard layers[$0].parent != nil else { return false }
```

**:2483, :2487, :2519** — `noPropagate` 지역변수와 `world()` 가드 제거

```swift
// before (:2483)
        var noPropagate: Set<Int> = []
// before (:2487)
            if l.disablePropagation { noPropagate.insert(l.id) }
// before (:2519)
            guard !noPropagate.contains(id) else { return t }  // E1: 전파 차단 — 조상 재귀 없이 로컬 그대로
```
```swift
// after: 세 줄 모두 삭제
```

**:2596–2617 `buildParentTransformMap`** — 반환 튜플에서 `noPropagate` 제거

```swift
// before
    private static func buildParentTransformMap(layers: [SceneLayer], nodes3D: [SceneNode3D], texts: [SceneTextLayer] = [])
        -> (localT: [Int: (origin: Vec2, scale: Vec2, angle: Float)], parentOf: [Int: Int], noPropagate: Set<Int>) {
        …
        var noPropagate: Set<Int> = []
        …
            if l.disablePropagation { noPropagate.insert(l.id) }
        …
            if t.disablePropagation { noPropagate.insert(t.id) }
        …
        return (localT, parentOf, noPropagate)
```
```swift
// after
    private static func buildParentTransformMap(layers: [SceneLayer], nodes3D: [SceneNode3D], texts: [SceneTextLayer] = [])
        -> (localT: [Int: (origin: Vec2, scale: Vec2, angle: Float)], parentOf: [Int: Int]) {
        …   // noPropagate 선언·삽입·반환 3+2곳 삭제
        return (localT, parentOf)
```

**:2621–2634 `worldParentTransform`** — `noPropagate` 파라미터와 가드 제거

```swift
// before
    private static func worldParentTransform(_ id: Int, _ depth: Int,
                                             localT: [Int: (origin: Vec2, scale: Vec2, angle: Float)],
                                             parentOf: [Int: Int], noPropagate: Set<Int>)
        -> (origin: Vec2, scale: Vec2, angle: Float)? {
        guard depth < 32, let t = localT[id] else { return nil }
        guard !noPropagate.contains(id) else { return t }
        guard let pid = parentOf[id],
              let pw = worldParentTransform(pid, depth + 1, localT: localT, parentOf: parentOf, noPropagate: noPropagate)
        else { return t }
```
```swift
// after
    private static func worldParentTransform(_ id: Int, _ depth: Int,
                                             localT: [Int: (origin: Vec2, scale: Vec2, angle: Float)],
                                             parentOf: [Int: Int])
        -> (origin: Vec2, scale: Vec2, angle: Float)? {
        guard depth < 32, let t = localT[id] else { return nil }
        guard let pid = parentOf[id],
              let pw = worldParentTransform(pid, depth + 1, localT: localT, parentOf: parentOf)
        else { return t }
```

**:2647–2652 `composeTextParentTransforms`**

```swift
// before
        guard camera3D == nil,
              texts.contains(where: { $0.parent != nil && !$0.disablePropagation }) else { return }
        let (localT, parentOf, noPropagate) = buildParentTransformMap(layers: layers, nodes3D: nodes3D, texts: texts)
        for i in texts.indices {
            guard !texts[i].disablePropagation, let pid = texts[i].parent,
                  let pw = worldParentTransform(pid, 0, localT: localT, parentOf: parentOf, noPropagate: noPropagate)
            else { continue }
```
```swift
// after
        guard camera3D == nil,
              texts.contains(where: { $0.parent != nil }) else { return }
        let (localT, parentOf) = buildParentTransformMap(layers: layers, nodes3D: nodes3D, texts: texts)
        for i in texts.indices {
            guard let pid = texts[i].parent,
                  let pw = worldParentTransform(pid, 0, localT: localT, parentOf: parentOf)
            else { continue }
```

**:2674–2679 `composeParticleParentTransforms`** — 위와 같은 형태로 `disablePropagation` 3곳 제거.

> 파스(`:1930`/`:2196`/`:2272`/`:2879`)와 모델 필드(`:205`/`:318`/`:401`/`:555`)는 **남긴다** —
> 실물이 값을 갖고 있고, §10 의 커서 경로 구현에서 쓰일 자리다.
> 다만 주석은 "커서 클릭 전파 차단(파스·보존 전용, 소비처 없음)" 으로 고쳐야 한다.

### 9.2 `Sources/WapleCore/SceneDocument.swift:3213` 부근 — 문서표 정정

```swift
// before
    /// | `solid` `0x1401e1283` | `+0x120` bit13 | false |
    /// | `disablepropagation` `0x1401e132b` | `+0x120` bit14 | false |
```
```swift
// after
    /// | `solid` `0x1401e1283` | `+0x120` bit13 | **true**(ctor `0x2001` @`0x1401ddc72`) |
    /// | `disablepropagation` `0x1401e132b` | `+0x120` bit14 | false (ctor `0x2001` @`0x1401ddc72`) |
```

`solid` 기본값을 고치면 **`isSolid` 선언 4곳**(`:241`/`:324`/`:430`/`:557`)의 `= false` 도
`= true` 로, 파스 4곳(`:1936`/`:2198`/`:2278`/`:2884`)의 `weBool(obj["solid"])` 도
`weBool(obj["solid"], true)` 로 가야 한다(태그5 게이트가 실패하면 ctor 기본값을 유지해야 하므로).
`isSolid` 는 현재 소비처가 0건이라 **그림은 안 바뀐다**.

### 9.3 `docs/re/scene-object-model.md:405` — 정정

```markdown
// before
`disablepropagation`(`+0x120` bit, `0x1401e132b`)이 전파 차단 플래그다. 동봉 코퍼스 도달은 §11.2.
```
```markdown
// after
`disablepropagation`(`+0x120` **bit14**, 등록 `0x1401e132b`)은 **커서 클릭 전파 차단**이다 —
트랜스폼 상속과 무관하다. 합성부 `sub_1401850a0` 은 플래그워드를 읽지 않는다(`object-propagation.md` §4).
동봉 코퍼스 도달은 §11.2.
```

같은 파일의 ctor 기본값 표(있다면 `solid` 행)도 §9.2 와 동일하게 `true` 로.

### 9.4 깨지는 테스트

| 테스트 | 지금 | 고친 뒤 |
|---|---|---|
| `Tests/WapleCoreTests/CoreParseSceneFixRegressionTests.swift:419` `testDisablePropagationSkipsParentTransformComposition` | `origin == (10,10)`, `scale == (1,1)` | **실패** → 기대값을 `origin == (520,520)`, `scale == (2,2)` 로 뒤집고 테스트 이름·주석을 "부모 합성은 플래그와 무관하다" 로 바꿔야 한다 |
| 같은 파일 `:244` 주석("disablepropagation 스킵") | — | 문구 정정 |
| `Tests/WapleCoreTests/SceneDocumentFidelityTests.swift:87` `testNumericOneDoesNotSetDefaultFalseFlags` | `XCTAssertFalse(layer.isSolid)` | §9.2 를 같이 적용하면 **실패** → `XCTAssertTrue(layer.isSolid)` + 테스트를 "기본 참" 쪽으로 이동. `disablePropagation` 단언은 그대로 `False` 유지(맞다) |
| `Tests/WapleCoreTests/SceneDocumentFidelityTests.swift:97` `testStringTrueIsNotBoolean` | `XCTAssertFalse(layer.isSolid)` | §9.2 적용 시 **실패** → `XCTAssertTrue` |
| `Tests/WapleCoreTests/SceneDocumentTests.swift:1263`,`:1296`,`:1306` | `disablePropagation` 파스 단언 | 영향 없음(파스는 유지) |

§9.1(트랜스폼)과 §9.2(`solid` 기본값)는 **서로 독립**이다. 따로 커밋해도 된다.

---

## 10. 이후 — 실물 의미론을 구현하려면

`disablepropagation` 을 실제로 쓰려면 포인터 경로에 다음이 필요하다(현재 Waple 에 전무).

1. 오브젝트를 **z-순서 역순**으로 순회(WE: `sortorder`/깊이 정렬 결과 배열을 뒤에서 앞으로).
2. `solid`(bit13, **기본 true**) 인 오브젝트만 히트테스트 대상.
3. 히트 판정은 알파가 아니라 **오브젝트 4×4 를 먹인 쿼드(±size/2)와 광선의 교차**
   (`pointer-interaction.md` §4.3).
4. 히트한 오브젝트에 **바인딩된** 스크립트(또는 전역)에만 `cursor*` 훅 발화.
5. 그 오브젝트가 `disablepropagation && visible && (부모 없음 || 조상 체인 visible)` 이면
   **순회 중단** — 아래 오브젝트에 아무 커서 이벤트도 가지 않는다.

5번이 이 문서가 확정한 유일한 의미론이다.

---

## 11. [미해결]

1. **워크샵 코퍼스 `disablepropagation:true` 34건 중 `parent` 보유 건수** — §6.3. 원본 코퍼스 미보유.
2. **`true` 34건이 몇 개 씬에 있는가** — 기록된 "63씬" 은 *키 등장* 씬 수다.
3. **`solid` 키가 `disablepropagation` 보다 훨씬 드물게 직렬화되는 이유**
   (image 기준 149 vs 2,097). WE 세이브 로직의 조건을 뜨지 않았다. `solid` 기본값 확정(§2.1)에는
   영향이 없다(ctor 리터럴 직독).
4. **`sortorder`(`+0x124`) 디스크립터의 타입코드** — 레지스터(`edi`) 경유라 지배관계를 따지지 않았다.
   이 문서의 결론과 무관.
5. **레지스트리 `0x1404e8250`(기저) ↔ `0x1404e8360`(이미지) 의 연결 지점** — 씬 로드 시 클래스 체인을
   어떻게 훑는지는 뜨지 않았다. `disablepropagation` 이 전 타입에 적용된다는 결론은
   ① 같은 테이블에 `origin`/`scale`/`angles`/`name` 이 있고 ② 코퍼스가 9개 타입 전부에서 이 키를
   기록하며 ③ `+0x120`/`+0x180` 을 쓰는 함수들이 10개 vtable 에 공유된다는 세 근거로 확정했다.

---

## 12. 검증 · 돌연변이

이 문서는 코드를 고치지 않으므로 스위프트 테스트를 돌리지 않았다(**미실행**).
대신 조사 방법 자체를 두 번 돌연변이시켜 "못 찾은 게 아니라 없는 것" 임을 확인했다.

**돌연변이 ①(코퍼스 스캐너).** §6.1/§6.2 의 0건이 스캐너 버그가 아님을 보이려고,
동봉 `scene.json` 사본에 `"disablepropagation":true` 를 심고 같은 스캐너를 돌렸다 →
**1건 검출**. 스캐너는 살아 있다.

**돌연변이 ②(비트 소비처 스캐너).** §3 과 **완전히 같은 스캐너**로 비트 번호만 14 → 13
(`solid`)으로 바꿔 돌렸다.

| 사냥 대상 | `[X+0x120]` 근방 검출 |
|---|---|
| bit13 (`0x2000`) | `0x14018a02d` `test word [r15+0x120], r8w` (`r8d=0x2000`) — **알려진 `solid` 게이트를 정확히 잡았다** (+ `[rax+0x118]` 오탐 3건, 다른 구조체) |
| bit14 (`0x4000`) | `0x14018a877` **1건** |

같은 코드가 존재하는 소비처(bit13)는 찾아내므로, bit14 가 1건인 것은
**스캐너의 위음성이 아니라 실제로 1건**이다.

**교차 확인.** 결론 ①~⑨ 는 서로 독립인 세 증거로 겹쳐 잡았다 —
(a) `wallpaper64.exe` 디스어셈블, (b) `wallpaperui.exe` 프로퍼티 행 정의 + `locale/*.json` 평문,
(c) `scenescript64.dll` 훅 이름 테이블 `0x1819a3ee0` 직독. 셋이 같은 답을 준다.
