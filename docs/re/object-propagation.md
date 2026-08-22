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
| `0x140180aa5` | `mov rcx, [rsi+0x30f8]` 의 일부 | 오탐 |  [VA-스캐너위치]
| `0x1401e123f` | `movzx eax, byte [rip+0x2af0ed]` → `0x140490330` | 오탐(문자열 풀 이웃) |  [VA-스캐너위치]
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
| `parallaxDepth` | `+0x68` | `0x170` | 1 (**vec2** — 아래 정정) |
| `sortorder` | `+0x68` | `0x124` | **0 (int32)** — 아래 정정 |
| `getTransformMatrix`·`rotateObjectSpace`·`lookAt`·`lookAtYaw`·`setParent`·`getParent`·`getChildren`·`getAttachmentIndex`·`getAttachmentMatrix`·`getAttachmentOrigin`·`getAttachmentAngles` | `+0x38` | — | 스크립트 메서드 |
| `name` | `+0x68` | `0x1d8` | 5 (string) |
| **`solid`** | `+0x68` | **`0x120`** | 6 (bool) |
| **`disablepropagation`** | `+0x68` | **`0x120`** | 6 (bool) |

`origin`/`scale`/`angles`/`name`/`parallaxDepth`/`sortorder` 와 **같은 테이블**이다 —
즉 이건 **모든 씬 오브젝트가 공유하는 기저 클래스**의 키다. Waple 처럼 이미지/텍스트/파티클/카메라
파서 4곳에 흩어져 있는 게 아니라, **원본은 한 곳**이고 파생 타입이 그걸 상속한다.

> 이미지 전용 키(`perspective` 등)는 별도 레지스트리 `0x1404e8360` 에 `sub_1401ee520` 이 등록한다.
> `disablepropagation` 은 거기에 **없다**.

> **[2026-08-21 정정] 위 표의 타입코드 두 칸이 틀렸거나 비어 있었다 — 둘 다 실측으로 채웠다.**
> 종전 문면은 `parallaxDepth` = "1 (float)" · `sortorder` = "—"(§11 ④ 가 "레지스터(`edi`)
> 경유라 지배관계를 따지지 않았다" 고 적어 둔 상태)였다. 툼스톤으로 남긴다.
>
> * **`sortorder` 타입코드는 `0` = int32 다.** `mov dword [rbx+0x30], edi`(`0x1401e092b`)의 `edi`
>   는 같은 함수의 `xor edi, edi`(`0x1401e07b9`)가 지배한다 — 그 사이에 `edi`/`rdi` 대입이 없고
>   (`rdi` 는 Win64 비휘발성이라 그 사이 4번의 `call` 을 넘겨도 산다), 같은 구간의
>   `mov byte [rax+0x12], dil`(`0x1401e098b`)이 18글자 `"getTransformMatrix"` 의 NUL 을 쓰므로
>   `dil == 0` 이 독립 확인이다.
>   멤버가 실제로 int32 라는 것은 타입코드에 기대지 않고도 나온다 — 역직렬화 썽크
>   `0x1401a4930` 이 태그 1/2 면 `mov eax, [r8]`(`0x1401a4969`), 태그 3 이면
>   `cvttsd2si eax, qword [r8]`(`0x1401a4962`)로 **32비트**를 만들어 `[r14+rbp]` 에 dword 로
>   쓴다(`0x1401a496c`). **태그 4(string)·5(bool)는 스토어를 건너뛰어 ctor 기본값 0 이 남는다**
>   (브리프 함정 15 — `"sortorder": true` 는 1 이 되지 **않는다**).
>   프로퍼티 스크립트 바인딩(`{"value":…}`) 경로도 `dec eax; cmp eax,2; ja`(`0x1401a49b5`–
>   `0x1401a49ba`)로 태그 1..3 만 받아 `asInt`(`0x140085ee0`)를 부른다.
>   세터/게터 `0x1401a49f0`/`0x1401a4a10` 은 dword 복사 썽크다(`mov eax, dword [r8]` /
>   `mov ecx, dword [rax+rcx]`).
> * **`parallaxDepth` 타입코드 1 은 float 이 아니라 vec2 다.** 역직렬화 썽크 `0x1401a3fc0` 이
>   태그 4(string)면 공백으로 끊어 두 성분을 `[rdi+rsi]`(`0x1401a4046`)와
>   `[rdi+rsi+4]`(`0x1401a4085`)에 각각 쓰고, 태그 1..3(스칼라)이면 `asFloat`(`0x140086220`)
>   하나를 **두 자리에 브로드캐스트**한다(`0x1401a40a4`·`0x1401a40aa`). 형제 문서
>   [`scene-object-model.md`](scene-object-model.md) §2.1 이 이미 "태그 1 = vec2" 로 적고 있었으니
>   **정본끼리 모순**이던 자리다(브리프 함정 24).
> * **타입코드 enum 전체**(같은 프로퍼티 시스템을 쓰는 다른 등록부와 교차 확인):
>   `0` = int32 · `1` = vec2 · `2` = vec3 · `4` = float · `5` = string · `6` = bit 접근자(bool).
>   `4 = float` 는 시퀀스 객체 등록부의 `rate`/`fps`(`mov dword [rbx+0x30], 4` @`0x140178038`·
>   `0x1401780e9`, 역직렬화 `0x1401a4b00` 이 `asFloat` → `movss`)로 잡았고,
>   `6` 은 bool 썽크 쌍(`0x1401a4ad0` 세터 / `0x1401a4af0` 게터, 역직렬화 `0x1401a4a20` 이
>   `cmp byte [r8+8], 5` → `asBool` `0x140086300`)이다. `3` 은 이 이미지에서 도달 0 —
>   **[미해결]**(vec4 로 추정하나 등록 사례를 못 찾았다).

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

> **[2026-08-21 정정] 바로 위 두 줄의 후반부가 틀렸다 — image 와 text 는 이 슬롯을 오버라이드한다.**
> 툼스톤으로 남긴다. `0x1401850a0` **값을 가진** vtable 을 스캔했으니 그 값을 **안 가진** vtable
> (= 오버라이드한 타입)은 애초에 표본에 들어올 수 없다. 표본 추출로 부재를 증명한 자리다.
>
> 타입별 vtable 을 오브젝트 팩토리 `sub_14018ff60` 에서 되짚어 전수로 뽑고(각 분기의
> `mov [obj], vtable` 또는 그 타입 ctor 안의 대입), 슬롯 `+0x80` 을 직접 읽으면:
>
> | 타입 | vtable | 종류코드 `[vt+0x60]` | `+0x80`(getTransformMatrix) |
> |---|---|---:|---|
> | 기저/노드 | `0x14048ec88`(`0x1401907ff`) | 0 | `0x1401850a0` |
> | image | `0x1404911a8`(ctor `0x1401fac7c`) | **1** | **`0x1401fd3f0` (오버라이드)** |
> | particle | `0x1404915b0`(`0x14019020b`) | 2 | `0x1401850a0` |
> | sprite | `0x140491680`(ctor `0x14025657c`) | 3 | `0x1401850a0` |
> | text | `0x140491950`(ctor `0x140256af7`) | **4** | **`0x140256e10` (오버라이드)** |
> | model | `0x140491338`(`0x14019015b`) | 5 | `0x1401850a0` |
> | light | `0x140491c38`(`0x140190441`) | 6 | `0x1401850a0` |
> | sound | `0x140490ae8`(`0x1401905b2`) | 7 | `0x1401850a0` |
> | camera | `0x140490980`(`0x1401906b5`) | 8 | `0x1401850a0` |
> | shape | `0x140491d10`(`0x1401907b4`) | 10 | `0x1401850a0` |
>
> **결론 ⑦·⑧ 은 그대로 산다** — 두 오버라이드 어느 쪽도 플래그워드 `+0x120` 을 읽지 않기 때문이다.
>
> * text `0x140256e10`: **무조건** `sub_1401850a0` 을 부르고(`0x140256e29`) 그 4×4 를
>   `[obj+0x554]` 로 64바이트 복사한 뒤(`0x140256e4c`–`0x140256e6c`), 평행이동 행에
>   `[obj+0x2f8..0x300]` 로컬 오프셋을 **기저(basis)로 회전시켜** 더한다
>   (`M[3] += s·Basis`, `0x140256e70`–`0x140256f07`). `+0x120` 참조 0건.
> * image `0x1401fd3f0`: `[obj+0x4b1] == 0` 이면 `sub_1401850a0` 으로 **꼬리 점프**하고
>   (`0x1401fd3f6`–`0x1401fd407`), 아니면 같은 함수를 호출한 뒤(`0x1401fd41d`) 결과를
>   `[obj+0x450]` 에 복사해 text 와 **같은 산식**으로 로컬 오프셋을 더한다. `+0x120` 참조 0건.
>
> 즉 두 오버라이드는 "기저 합성 결과에 타입 고유의 로컬 오프셋을 덧붙이는" 래퍼이고,
> **부모 체인 합성 자체는 여전히 `sub_1401850a0` 한 곳**이며 그 게이트는 `parent != null` 뿐이다.

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

## 9. 넘길 정정안 (이 문서 밖 — 소유권이 다른 파일) — **§13 에서 적용 완료**

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
   → **[2026-08-21 좁힘 · 여전히 미해결]** 적어도 **엔진 쪽은 아니다.** 두 키의 직렬화 썽크는
   조건 없이 값을 쓴다 — `disablepropagation` `0x14019bc10`(`test dword [rcx], 0x4000` · `setne`
   @`0x14019bc1a`), `solid` `0x14019c4c0`–`0x14019c5c0`(`test dword [rcx], 0x2000` @`0x14019c4ca`
   → `setne byte [rsp+0x20]` @`0x14019c4d3`).
   "기본값이면 생략" 같은 게이트가 썽크 안에 없다. 게다가 `scene.json` 을 쓰는 것은 엔진이 아니라
   **에디터(`bin/wallpaperui.exe`)** 다. 그쪽 세이브 경로는 열지 않았다 — 열려면
   `--binary bin/wallpaperui.exe` 로 재야 한다(§5 의 VA 들이 그 이미지 기준인 것과 같다).
4. **`sortorder`(`+0x124`) 디스크립터의 타입코드** — 레지스터(`edi`) 경유라 지배관계를 따지지 않았다.
   이 문서의 결론과 무관.
   → **[해소 2026-08-21] `0` = int32.** 지배관계를 따졌다(`xor edi,edi` `0x1401e07b9` 가 유일한
   지배 대입, `rdi` 는 비휘발성) + 독립 확인(`dil` 이 SSO NUL 을 쓴다, `0x1401e098b`) +
   멤버 타입 직독(역직렬화 썽크 `0x1401a4930` 이 dword 를 쓴다). 전문은 §1.3 아래 정정 상자.
   태그 게이트도 같이 확정했다 — 태그 1/2/3 만 착지하고 **태그 5(bool)·4(string)는 무시**,
   `{"value":…}` 바인딩 경로는 `asInt`(`0x140085ee0`).
5. **레지스트리 `0x1404e8250`(기저) ↔ `0x1404e8360`(이미지) 의 연결 지점** — 씬 로드 시 클래스 체인을
   어떻게 훑는지는 뜨지 않았다. `disablepropagation` 이 전 타입에 적용된다는 결론은
   ① 같은 테이블에 `origin`/`scale`/`angles`/`name` 이 있고 ② 코퍼스가 9개 타입 전부에서 이 키를
   기록하며 ③ `+0x120`/`+0x180` 을 쓰는 함수들이 10개 vtable 에 공유된다는 세 근거로 확정했다.
   → **[해소 2026-08-21] 씬 로드는 클래스 체인을 훑지 않는다.** 질문의 전제가 틀렸다.
   경로는 이렇다:
   1. `IObject::load`(기저 `0x1401de470`, 타입별 오버라이드는 그 안에서 이걸 부른다)가
      리플렉션 바인더 `sub_1401730d0(propsys+0x1708, this, json)` 을 부른다(`0x1401de4a2`).
   2. 바인더는 JSON 오브젝트의 멤버를 **std::map 순회 = 키 순서**로 돌면서(`0x140173127` 루프)
      키마다 **오브젝트 자신의 가상 함수** `[vtbl+0x20]` 을 불러 디스크립터를 찾고
      (`0x140173152` `call [rax+0x20]`), 찾았고 `desc->flags & 2` 가 아니면
      `desc->deserialize`(`0x14017316c` `call [rax+8]`)를 부른다.
   3. `[vtbl+0x20]` 은 **타입마다 따로 생성된 함수**다 — 기저 `0x1401e1ca0`, image `0x140212a00`.
      둘 다 이름을 FNV-1a-64 로 해싱해 **자기 클래스의 해시 색인**을 한 번 찌르고
      (기저 `0x1404e82d8`/`0x1404e82e8`/`0x1404e8300` · image `0x1404e85e8`/`0x1404e85f8`/`0x1404e8610`),
      실패하면 **인스턴스별 동적 맵**(기저 `[obj+0x248/0x258/0x270]` · image `[obj+0x3d8/0x3e8/0x400]`)을
      찌른다. **부모 클래스의 색인을 부르는 호출은 없다.**
      열거 쪽(`[vtbl+0x10]`: 기저 `0x1401e1e20` · image `0x140212b80`)도 같은 모양이다 —
      각자 자기 색인만 순회한다.
   4. 따라서 **파생 클래스의 색인이 이미 기저 항목을 담고 있다.** 반증법으로 확정된다:
      image 레이어의 `origin`/`scale`/`angles` 는 기저 등록부에만 있는데(§1.3), 그 값이 실제로
      착지하려면 ②의 조회가 image 색인에서 그것을 찾아야 한다. 코퍼스의 이미지 레이어는
      전건 origin/scale 이 반영되므로 image 색인은 기저 항목을 포함한다.
   → 남는 좁은 [미해결]: **기저 항목이 파생 색인으로 복사되는 시점·코드**. 등록 헬퍼는
   `sub_14015a000`(프로퍼티) / `sub_140178e90`(스크립트 메서드)이고 기저는 `0x1404e8250`/`0x1404e8290`,
   image 는 `0x1404e8360` 을 받는데, 그 벡터에서 위 해시 색인이 만들어지는 자리는 뜨지 않았다.
   이 문서의 결론에는 영향이 없다(위 반증법이 독립적으로 성립한다).

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

---

## 13. 적용 기록 — 2026-08-21, 2차 웨이브 클러스터 M

§9 의 정정안을 **실제로 적용했다**. 적용 전에 §2·§3·§4·§5·§6 의 핵심 주장을 이 문서의 VA 를
베끼지 않고 **다시 떴다**(브리프 함정 16).

### 13.1 독립 재확인 결과 — 전건 일치

| 재확인 대상 | 방법 | 결과 |
|---|---|---|
| 기저 ctor 리터럴 | `pe.read(0x1401ddc72, 10)` | `66 41 c7 86 20 01 00 00 01 20` = `mov word [r14+0x120], 0x2001` — **일치** |
| 디스크립터 항목 경계 | `0x1401e1180`–`0x1401e1389` 재덤프, `call 0x14000f880`(이름 대입) 기준 절단 | `solid` 이름 `lea 0x1401e1272` → `call 0x1401e1283`, `+0x34 = 0x120`, `+0x30 = 6`; `disablepropagation` 이름 `lea 0x1401e131a` → `call 0x1401e132b`, `+0x34 = 0x120`, `+0x30 = 6`. **함정 16 의 끼어들기도 그대로 재현**됨(`lea "disablepropagation"` @`0x1401e129a` 이 `solid` 엔트리 스토어 사이에 있다) |
| 비트 번호 | 썽크 4+4개 직접 디스어셈블 | `solid`: 역직렬화 `0x14019c425` `btr edx,0xd`/`bts ecx,0xd` · 직렬화 `0x14019c4ca` `test dword [rcx],0x2000` · 게터 `0x14019c600` `shr edx,0xd`. `disablepropagation`: `0x14019bb75` `btr edx,0xe` · `0x14019bc1a` `…,0x4000` · `0x14019bd57` `shr edx,0xe`. **일치** |
| 합성부가 플래그를 읽는가 | `merged(0x1401850a0)` = `0x1401850a0`–`0x1401852f7`(8조각) 전문 디스어셈블(113줄) | `0x120` **0건** · `bt/bts/btr/btc` **0건** · `0x4000`/`0x2000` **0건**. 참조는 `+0x180`(parent) 3건 · `+0x190`(attachment) 2건뿐이고, `0x1401852b0` 이 자기 자신을 재귀 호출한다. **일치** |
| bit14 소비처 개수 | `.text` 4,344,076바이트 **바이트 스캔**(imm8=0x0e 인 `0f ba /4..7` · `c1 /5,/7` · imm32=0x4000 인 `81`/`f7 /0`/`a9` · 16비트 `66 81`/`66 f7` · 레지스터 마스크 `b8+r 00 40 00 00`) → 원시 204건 중 ±40바이트 안에 disp32 `0x120` 이 있는 것만 | **1건** — `0x14018a877`(`66 0f ba e0 0e` = `bt ax, 0xe`). **일치** |
| 위 스캐너의 위음성 여부 | **돌연변이**: 같은 스캐너를 bit13(0x0d/0x2000)으로 재실행 | 레지스터 마스크 경로가 `0x14018a00c`(`41 b8 00 20 00 00` = `mov r8d,0x2000`, 알려진 `solid` 게이트)와 `0x14018a3f5` 를 잡았고 즉치 경로가 `+0x118` 오탐 3건을 잡았다 → **스캐너는 살아 있다**. bit14 의 레지스터 마스크 경로는 **0건** |  [VA-스캐너위치]
| 에디터 라벨 | `wallpaper_engine/locale/ui_en-us.json` grep | `:2540` `"ui_editor_properties_disable_click_propagation" : "Disable click propagation"` · `:2594` `"ui_editor_properties_enable_click_events" : "Enable click events"`. **일치** |

### 13.2 무회귀 — 범위 라벨 붙인 도달 건수(직접 재측정)

| 변경 | 동봉 `WEAssets`(json **1,698**) | 설치본 `wallpaper_engine`(json **2,143**) | 워크샵(162씬, 기록치 인용 — 재측정 불가) |
|---|---:|---:|---|
| ① 트랜스폼 가드 제거 | **0** (`disablepropagation` 문자열 0건) | **0** (0건) | image `true` **≤34** + 그 자손. text 742 / particle 408 / camera 34 / node 595 / sound 188 / model 265 / light 16 / shape 14 는 **전건 `false`** — 그쪽 가드는 원래도 no-op |
| ② `solid` 기본 true | 그림 **0** — `"solid"` 는 18건이고 **전건 `true`**, 게다가 `isSolid` 소비처가 0건 | 그림 **0** — 40건 전건 `true`, 소비처 0건 | 그림 **0**(소비처 0건). 기록치도 `bool(전건 true)` |
| ③ `instanceoverride` 애니 캡처 | 보존값 **5블록/5파일**(`controlpointangle1` 4 · `controlpoint1` 1), 그림 **0**(소비처 0건) | 동수(같은 6파일) | 미측정 |

즉 **출하 자산(동봉·설치본)의 렌더 결과는 세 변경 모두 한 픽셀도 바뀌지 않는다.**
바뀔 수 있는 최대치는 ①의 워크샵 이미지 레이어 ≤34개와 그 자손이고,
그 34개가 실제로 `parent` 를 가졌는지는 원본 코퍼스 없이 확정 불가다(§6.3, §11 ①).

### 13.3 적용한 것 / 안 한 것

**적용**

- `Sources/WapleCore/SceneDocument.swift` — §9.1 전건(12지점): `composeTargets` 가드 ·
  `world()` 단락 · `buildParentTransformMap` 의 `noPropagate`(선언·삽입 2곳·반환) ·
  `worldParentTransform` 파라미터·단락·재귀 인자 · `composeTextParentTransforms` 3곳 ·
  `composeParticleParentTransforms` 3곳. **파스 4곳과 모델 필드 4곳은 유지**(§9.1 단서대로).
- 같은 파일 §9.2: `isSolid` 선언 4곳 `= true`, 파스 4곳 `weBool(obj["solid"], true)`, 문서표 정정.
- `docs/re/scene-object-model.md` §4.5 와 `solid` 행 — §9.3.
- 테스트: `CoreParseSceneFixRegressionTests`(기대값 반전 + 텍스트/파티클 짝 + 조상 체인 중간마디 3건),
  `SceneDocumentFidelityTests`(`solid` 4파스지점 잠금 + 태그5 케이스 재배치).

**안 한 것**

- `Sources/WapleCore/ParticleSystem.swift` 의 `ParticleInstanceOverride` 에 애니 슬롯을 넣는 안은
  **소유 밖**이라 하지 않았다. 대신 `SceneParticle.instanceOverrideAnimations` 로 받았다.
- §10 의 커서 경로 구현은 이 라운드 범위 밖이다(별도 클러스터가 `Sources/WapleCore/PointerHit.swift` 로
  순수 기하를 진행 중 — 이 문서가 확정한 5번 규칙(`disablepropagation && visible && 조상 visible`
  → 순회 중단)이 그쪽 소비처가 된다).

### 13.4 검증

`scripts/dev/linux-core-tests.sh --filter
'SceneDocument|SceneDocumentFidelity|CoreParseSceneFixRegression|SceneText|SceneGeneralKeys|SceneParticle|PropertyAnimation'`
→ **248 tests / 0 failures**. `scripts/spec/check_*.py` 14개(`check_stray_artifacts.py` 제외) 전부 통과.

**돌연변이 8건 주입 / 8건 검출**(전부 되돌림, 되돌린 뒤 바이트 동일 확인):
`composeTargets` 가드 복원 · 텍스트 가드 복원 · 파티클 가드 복원 ·
`weBool(obj["solid"], true)` → `weBool(obj["solid"])` 4파스지점 각각 ·
`instanceoverride` 애니 캡처 제거.

---

## 14. 2026-08-21 3차 — 이 문서의 결론을 다시 뜨면서 새로 확정한 것

§11 의 [미해결] 5건 중 ④·⑤ 를 닫고, ③ 을 좁혔다. ①·② 는 워크샵 코퍼스가 없어 여전히 열려 있다.
그 과정에서 이 문서의 **틀린 문면 3건**을 정정했다(전부 툼스톤으로 남겼다).

| 자리 | 종전 문면 | 실측 |
|---|---|---|
| §1.3 표 `parallaxDepth` | 타입코드 "1 (float)" | **1 = vec2** — 역직렬화 썽크 `0x1401a3fc0` 이 두 성분을 쓴다(`0x1401a4046`·`0x1401a4085`), 스칼라면 브로드캐스트(`0x1401a40a4`·`0x1401a40aa`) |
| §1.3 표 `sortorder` | 타입코드 "—" | **0 = int32** — `xor edi,edi` `0x1401e07b9` 지배, 썽크 `0x1401a4930` 이 dword 스토어(`0x1401a496c`) |
| §4 vtable 스캔 | "10개 전부 `0x1401850a0`, 오버라이드 0" | image·text 는 `+0x80` 을 **오버라이드한다**(`0x1401fd3f0`·`0x140256e10`). 결론 ⑦·⑧ 은 유지 — 둘 다 `+0x120` 을 안 읽고 기저에 위임한다 |

**형제 문서로 넘긴 신규 확정**(범위가 `objects[]` 전반이라 [`scene-object-model.md`](scene-object-model.md)에 적었다):

* **§4.6 오브젝트 id 중복 규약** — WE 는 중복을 제거하지 않고, id 조회
  (`Scene::findObjectById` `0x140196840`)는 배열 순서에서 **앞이 이긴다**.
  패키지 엔트리의 last-wins(`adda85e`)와 **반대**다.
* **§4.7 부모→자식 상속 축** — 트랜스폼(곱셈)과 가시성(논리 AND) 둘뿐이고
  alpha/color/brightness 는 상속되지 않는다.
* **§9.2b `sortorder` 정렬은 안정(stable)** — 두 경로 다 MSVC `std::stable_sort` 다.
* **§12 텍스트 포인터 스코프** — 커서 히트테스트에서 text(종류코드 4)는 image(1)와 **같은 갈래**이고
  `parallaxDepth` 시차 보정도 똑같이 받는다.
* **§14 CP 회전의 최종 소비자** — 갱신부 `0x14022e3e0` 이 `[cp+0x80]` 4×4 를 활성 트랜스폼
  (`[cp+0x00]`)으로 복사하고(게이트: `[cp+0xc0]` bit0 set · bit16 clear), 이미터 형상 평가부
  `0x1402378a0` 이 그것을 **방향 기저 + 원점**으로 읽는다. `directiontocontrolpoint` remap 이 아니다.

정본: [`spec/engine/scene-objects.json`](../../spec/engine/scene-objects.json)
(생성기 `scripts/spec/measure_scene_objects.py` — 이 컨테이너에서 **돈다**. 위 주소가 낡으면 죽는다).
