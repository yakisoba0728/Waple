# WE 플레이리스트 · 벽지 전환 서브시스템 복원

> 대상: `wallpaper64.exe` (WE 2.8.42, imagebase `0x140000000`).
> 모든 VA 는 이 이미지 기준이다. 파일:행 인용은 WE 설치본
> (`assets/`, `ui/`, `locale/`) 과 이 리포의 `Sources/` 를 가리킨다.
>
> 재현: `WE_ROOT=<설치본> python3 scripts/re/playlist_transition.py`
> — 셰이더 · UI 스크립트 · 로케일 세 출처에서 전환 표를 각각 뽑아 교차 검증한다.

**선행 스윕(T02)의 "플레이리스트/전환 서브시스템이 canon 에 전혀 없다"는 보고는 절반만 맞다.**
Waple 에는 재생목록이 **있고**(`Sources/WapleLibrary/PlaylistStore.swift`), 전환(transition)은
**하나도 없다**. WE 쪽 재생목록도 Waple 이 가진 것보다 훨씬 크다 — 모드 5종, 항목별 시각
스케줄, 셔플백, 재부팅을 넘는 경과시간 영속. 자세한 대조는 §8.

---

## 0. 한눈에

| 축 | WE | 근거 |
| --- | --- | --- |
| 전환 효과 | **27종**(id 0..26) + 특수값 3(`-1` none, `-2` none-reduce-flicker, `-3` random) | §4 |
| 전환 셰이더 | `dx11playlisttransition.{vert,geom,frag}`, 콤보 `FADEEFFECT` 1개 | §2 |
| 전환 보간 | **호스트는 선형**. 이징은 전부 셰이더 안(`smoothstep`/`pow`) | §5 |
| 재생 모드 | `logon` / `timer` / `daytime` / `dayofweek` / `never` (0..4) | §3 |
| 순서 | `random`(셔플백) / `sorted`(인덱스 커서) | §6 |
| 범위 | **모니터별**. 설정·경과시간·셔플백 전부 모니터 단위 | §3, §7 |

---

## 1. 함수 지도

| VA 범위 | 역할 |
| --- | --- |
| `0x140075790–0x140075a8f` | **전환 설정 파서** — `transition` / `transitionpool` / `transitiontime` |
| `0x140075a90–0x140076bdb` | **플레이리스트 파서** — `settings` + `items` |
| `0x140076be0–0x140076e04` | 프레임마다 도는 **재생목록 타이머 틱**(모니터 순회) |
| `0x140067a00–0x140068f1c` | **다음 벽지 결정** — 모드·순서 분기, 셔플백 |
| `0x140068fc0–0x140069bac` | **전환 시작** — 효과 확정(`-1`/`-2`/`-3`/N), 오버레이 생성 |
| `0x140058050–0x14005812f` | 전환 오버레이 객체 생성자 |
| `0x140058430–0x14005876e` | 전환 잡 디스패치(디스크립터 → 렌더 스레드) |
| `0x140058770–0x14005a884` | **전환 렌더 스레드** — 셰이더 컴파일·프레임 루프·상수버퍼 |
| `0x14005aaf0–0x14005ae7f` | `-2` 경로 — 셰이더 없이 마지막 프레임만 붙잡음 |
| `0x14005c390–0x14005cac9` | 셰이더 컴파일 + **리플렉션 → 능력 플래그** |
| `0x14005deb0–0x14005e16b` | 렌더 객체 생성자 — `g_Hash`/`g_Hash2` 1회 추첨 |
| `0x14005e6d0–0x14005eb03` | 미리보기 경로의 상수버퍼 갱신(설정창 프리뷰) |
| `0x14006a490–0x14006c239` | 재생목록 상태 로드·저장 |
| `0x14006eef0–0x140070688` | `bin/playliststate.bin` 기록 |
| `0x140070690–0x140070dcc` | `bin/playliststatetime.bin` 기록 |
| `0x14006c280–0x14006ce9b` | 일반 설정 로드 — `browsetransition` |
| `0x14003dcf0–0x14003dd3e` | 로케일 첫 요일(`LOCALE_IFIRSTDAYOFWEEK`) |

문자열 상수(전부 `.rdata`, ASCII·NUL 종단):

| 문자열 | VA | 문자열 | VA |
| --- | --- | --- | --- |
| `playlist` | `0x140473c78` | `playlists` | `0x140474ba8` |
| `settings` | `0x140474e50` | `items` | `0x14047491c` |
| `delay` | `0x1404781e0` | `order` | `0x14047456c` |
| `sorted` | `0x1404781e8` | `mode` | `0x140474ec0` |
| `logon` | `0x140474d10` | `daytime` | `0x1404781f0` |
| `dayofweek` | `0x1404781f8` | `never` | `0x140478204` |
| `videosequence` | `0x140478210` | `updateonpause` | `0x140478220` |
| `beginfirst` | `0x140478230` | `playintro` | `0x140478240` |
| `file` | `0x140473b68` | `daytimeend` | `0x140478250` |
| `preset` | `0x140473c54` | `transition` | `0x140474e60` |
| `transitiontime` | `0x140474e70` | `transitionpool` | `0x1404781c8` |
| `random` | `0x140478098` | `none` | `0x14047709c` |
| `browsetransition` | `0x140477088` | `dayofweekoffset` | `0x140475148` |
| `bin/playliststate.bin` | `0x1404780a0` | `bin/playliststatetime.bin` | `0x1404780c8` |
| `PLPV0005` | `0x1404780b8` | `FADEEFFECT` | `0x140477c60` |
| `assets/shaders/HLSL/dx11playlisttransition` | `0x140477c70` | `assets/shaders/HLSL/dx11playlistgaussian` | `0x140477ce8` |
| `assets/materials/util/noise.png` | `0x140477ca0` | `assets/materials/util/clouds_256.png` | `0x140477cc0` |
| `openPlaylist` | `0x140473c68` | `loadplaylist` | `0x14048ad18` |

**짧은 키는 SSO 라 `lea` 가 아니라 `mov`/`movzx` 로 실린다**는 `scripts/re/README.md` 의 경고는
이 서브시스템에는 해당이 없었다 — `delay`/`order`/`mode` 같은 5글자 키도 전부 `lea` 로 잡혔다.
Json 조회 헬퍼 `sub_140086de0(Json::Value*, const char* begin, const char* end)` 가
`std::string` 이 아니라 **원시 포인터 쌍**을 받기 때문이다(`lea rdx, key` / `lea r8, key_end`
가 항상 짝으로 나온다 — 예: `0x140075b44` + `0x140075b3a`). `movzx` 스캔에서 걸린 것은
`random`(`0x1401f37f7`, `0x1401f7aed`) 뿐이고 그건 이 서브시스템과 무관한 정적 문자열
초기화였다. **UTF-16LE 로도 전수 스캔했다** — `playlist`/`transition` 은 0건이고,
UTF-16 인 것은 창 클래스 이름 `WPEUIFadeWindow`(`0x140477830`) 하나뿐이다(§2.5).

찾아봤지만 **바이너리에 아예 없는** 키: `shuffle`, `interval`, `wallpaperid`, `timer`
(설정값으로서. `highprecisiontimer` 안의 부분문자열 `0x140477015` 는 무관하다).
`duration`(`0x140489b60`, `0x14048f3cb`, `0x14048f3e3`)도 전부 다른 서브시스템 것이다.

---

## 2. 셰이더

### 2.1 파일

| 파일 | 줄수 | 역할 |
| --- | --- | --- |
| `assets/shaders/HLSL/dx11playlisttransition.vert` | 125 | 통상은 패스스루. `FADEEFFECT == 23` 일 때만 파편 메시 애니메이션 |
| `assets/shaders/HLSL/dx11playlisttransition.geom` | 162 | `FADEEFFECT == 16` 일 때 벽돌 28장 생성, 그 외에는 점 1개 → 전체화면 쿼드 |
| `assets/shaders/HLSL/dx11playlisttransition.frag` | 810 | 27개 분기 전부 |
| `assets/shaders/HLSL/dx11playlistgaussian.{vert,frag}` | 21 / 40 | 3×3 가우시안(가중치 21/31/48 ÷ 256). 전환과 별개의 유틸 |

리포에 동봉된 사본: `Sources/WapleRender/Resources/WEAssets/shaders/HLSL/` (7개, 해시는
`spec/engine/shaders.json:82` 이하에 기록돼 있다). **셰이더는 이미 손에 있다** — 없는 건 이걸
돌릴 파이프라인이다.

### 2.2 콤보

콤보는 **`FADEEFFECT` 하나뿐**이다(`spec/engine/shaders.json:107` / `:140` / `:165`).
호스트가 정수 문자열로 넣는다:

```
0x140058f31  mov  edx, r8d                        ; r8d = 효과 인덱스
0x140058f3b  call 0x140053e40                     ; int → std::string
0x140058f48  lea  rax, [rip+0x41ed11]  ; 0x140477c60 "FADEEFFECT"
0x140058f98  movups xmm0, [rip+0x41ecd1] ; 0x140477c70  셰이더 경로 42바이트
0x140058fcf  mov  qword ptr [rbp+0x30], 0x2a       ; = 42 = strlen(경로)
```

즉 `{"FADEEFFECT": "<0..26>"}` 하나로 컴파일하고, 결과를 효과 인덱스 해시(FNV-1a,
`0x140058e6a`–`0x140058edf`)로 캐싱한다.

### 2.3 상수버퍼 `g_bufDynamic` (b0)

HLSL 선언(frag 25–38 / vert 22–35 / geom 13–26)과 호스트의 채움 코드가 정확히 맞는다.
채움은 `0x14005a415`–`0x14005a4d4`:

| 오프셋 | HLSL | 채움 VA | 값 |
| --- | --- | --- | --- |
| `0x00` | `g_Progress` | `0x14005a41a` | §5 의 선형 진행도 |
| `0x04` | `g_Hash` | `0x14005a41e` | 객체당 1회 `rand()/32767` |
| `0x08` | `g_Hash2` | `0x14005a427` | 객체당 1회 `rand()/32767` |
| `0x0c` | `g_Random` | `0x14005a430`–`0x14005a440` | **프레임마다** `rand()/32767` |
| `0x10` | `g_AspectRatio` | `0x14005a445`–`0x14005a45f` | `h > 0 ? w/h : 1.0` |
| `0x14` | `g_Width` | `0x14005a472` | 픽셀 폭 |
| `0x18` | `g_Height` | `0x14005a478` | 픽셀 높이 |
| `0x20` | `g_ViewProjection` | `0x14005a47b`–`0x14005a4a3` | 4×4, 전치 저장 |
| `0x60` | `g_ViewProjectionInv` | `0x14005a4ac`–`0x14005a4d4` | 역행렬(`sub_14005f730` 계산) |

`0x20`/`0x60` 정렬은 HLSL 패킹 규칙(float 7개 뒤 `float4x4` 는 16바이트 경계) 그대로다.
`0x14005e6d0`–`0x14005eb03` 에 같은 채움이 한 벌 더 있다(설정창 미리보기 경로).

`rand()` 는 CRT `rand`(`sub_1402c97a0`), 나눗셈 상수 `32767.0f` 는 `0x140492960`.
`g_Hash`/`g_Hash2` 추첨은 렌더 객체 생성자에서 **딱 한 번**:

```
0x14005e0f9  call 0x1402c97a0                     ; rand()
0x14005e105  divss xmm0, [rip+0x434853]  ; 0x140492960 f32=32767.0
0x14005e10d  movss dword ptr [rbx+0x108], xmm0    ; g_Hash
0x14005e115  call 0x1402c97a0                     ; rand()
0x14005e130  movss dword ptr [rbx+0x10c], xmm0    ; g_Hash2
```

그래서 `g_Hash`/`g_Hash2` 는 **한 번의 전환 내내 고정**(구름 패턴·탄흔 위치가 흔들리지
않는다)이고 `g_Random` 만 매 프레임 바뀐다. 참고로 27종 중 `g_Random` 을 읽는 분기는
**하나도 없다** — 세 셰이더 전부 `g_Random` 등장이 cbuffer 선언 한 줄뿐이다
(frag 30 / vert 27 / geom 18). `spec/engine/shaders.json` 의 `gRefs` 에 올라와 있는 것은
cbuffer 멤버이기 때문이다.

### 2.4 텍스처 슬롯

| 슬롯 | 이름 | 언제 |
| --- | --- | --- |
| `t0` | `g_Texture0` | 항상 — **떠나는 벽지의 캡처 프레임** |
| `t0` | `g_Texture0MipMapped` | 같은 슬롯의 밉맵 뷰. 21 CRT, 25 Ice |
| `t1` | `g_Texture1Noise` | 26 Boilover (`assets/materials/util/noise.png`) |
| `t2` | `g_Texture2Clouds` | 26 Boilover (`assets/materials/util/clouds_256.png`) |
| `s0` | `g_Texture0SamplerState` | clamp |
| `s1` | `g_Texture0SamplerStateWrap` | wrap — 26 전용 |

### 2.5 합성 방향 — **떠나는 프레임을 위에 덮는다**

모든 분기가 `color.a` 를 계산하고 마지막에 `color.rgb *= color.a` 로 **프리멀티플라이드**
알파를 만든다(예: frag 224–225 `color.a = 1.0 - progress; color.rgb *= color.a;`).
즉 `g_Texture0` 은 **이전** 벽지의 캡처이고, 새 벽지는 그 아래에서 이미 라이브로 돌고 있다.
전환 창은 그 위에 얹히는 레이어드 오버레이다:

```
0x140058937  mov ecx, 0x8280020    ; WS_EX_NOACTIVATE|NOREDIRECTIONBITMAP|LAYERED|TRANSPARENT
0x140058941  mov r9d, 0x40000000   ; WS_CHILD
0x14005894c  call qword ptr [rip+0x3cddae]  ; CreateWindowExW
```

창 클래스 이름은 **`WPEUIFadeWindow`** — 바이너리에서 **UTF-16LE 로 저장된 유일한
플레이리스트/전환 관련 문자열**이다(`0x140477830`, 등록 `0x1400584de  RegisterClassW`).
`playlist`/`transition`/`Playlist`/`Transition` 을 UTF-16LE 로 전수 스캔하면 **0건**이다 —
이 서브시스템의 나머지 문자열은 전부 ASCII 다.

루프는 진행도가 1.0 에 닿으면 끝난다:

```
0x14005a790  mov  ecx, 0xf
0x14005a795  call qword ptr [rip+0x3cb9d5]   ; Sleep(15)  → 약 66 fps 상한
0x14005a79b  comiss xmm6, xmm14              ; progress vs 1.0
0x14005a79f  jae  0x14005a7ae                ; ≥ 1.0 → 루프 탈출
0x14005a7a1  movzx eax, byte ptr [r15+0x3a]  ; 외부 중단 플래그
0x14005a7a8  je   0x14005a2f4                ; 계속
0x14005a7b4  call qword ptr [rip+0x3cc26e]   ; ShowWindow(hwnd, SW_HIDE)
0x14005a7ca  call 0x14028af70                ; operator delete(obj, 0x168)
0x14005a7d3  call qword ptr [rip+0x3cbf5f]   ; DestroyWindow
```

그러니까 오버레이는 **`progress == 1` 에서 스스로 사라진다**. 이 구조 덕분에
**셰이더는 새 벽지를 전혀 몰라도 된다** — 텍스처가 하나뿐인 이유다.

---

## 3. 플레이리스트 설정 스키마

파서: `0x140075a90–0x140076bdb`. `settings` 오브젝트를 `0x140075b0d` 에서 찾고,
타입이 `objectValue`(7) 가 아니면(`0x140075b30`) 전부 기본값으로 남긴다.

Json 타입 코드는 jsoncpp 규약이다 — `null`=0, `int`=1, `uint`=2, `real`=3, `string`=4,
`bool`=5, `array`=6, `object`=7.

### 3.1 `playlist.settings`

| 키 | 타입 | 구조체 오프셋 | 기본값 | 읽는 VA | 의미 |
| --- | --- | --- | --- | --- | --- |
| `delay` | number | `+0x30` (float) | **60.0** (`0x140075b14`, imm `0x42700000`) | `0x140075b44`–`0x140075b85` | 전환 간격 **분**. `int`/`uint`/`real` 만 받고(`0x140075b56` `cmp ecx,2; jbe`) 그 외 타입이면 **0.0** 이 된다 |
| `order` | string | `+0x34` (int) | `0` = random | `0x140075b8b`–`0x140075bf2` | `"sorted"`(`0x140075bd9`) → 1, 그 밖의 모든 문자열 → 0 |
| `mode` | string | `+0x38` (int) | `1` = timer (`0x140075c3d`) | `0x140075c41`–`0x140075d41` | 아래 표 |
| `videosequence` | bool | `+0x3c` bit0 | false | `0x140075d86`–`0x140075dba` | 동영상이 끝날 때 전환 |
| `updateonpause` | bool | `+0x3c` bit1 | false | `0x140075dc9`–`0x140075dfd` | 일시정지 중에도 전환 |
| `beginfirst` | bool | `+0x3c` bit3 | false | `0x140075e13`–`0x140075e47` | **`mode == timer` 일 때만 읽는다**(`0x140075e02` `cmp dword [r14+0x38],1`) |
| `playintro` | bool | `+0x3c` bit4 | false | `0x140075e5d`–`0x140075e91` | **`beginfirst` 가 켜졌을 때만 읽는다**(`0x140075e4c` `test byte [r14+0x3c],8`) |
| `transition` | bool\|string | `+0x48` (int) | `-1` | §4 | |
| `transitiontime` | number | `+0x4c` (int) | `500` | §4 | |
| `transitionpool` | array\<string\> | `+0x50..+0x60` | 빈 집합 | §4 | |

`+0x3c` **bit2(값 4)는 이 파서가 건드리지 않는다** — 예약이거나 다른 곳에서 세운다.

`mode` 열거:

| 문자열 | 값 | 문자열 VA | 판정 VA |
| --- | --- | --- | --- |
| `logon` | 0 | `0x140474d10` | `0x140075c9d`–`0x140075cad` |
| (기본, 미지정) | 1 = timer | — | `0x140075c3d` |
| `daytime` | 2 | `0x1404781f0` | `0x140075ccb`–`0x140075cdb` |
| `dayofweek` | 3 | `0x1404781f8` | `0x140075cfa`–`0x140075d0a` |
| `never` | 4 | `0x140478204` | `0x140075d29`–`0x140075d39` |

`"timer"` **라는 문자열은 바이너리에 없다.** 기본값 1 이 곧 timer 라서, 어떤 문자열도
매치되지 않으면 자동으로 timer 다. UI 쪽에는 옵션 값으로 존재한다
(`ui/dist/scripts/scripts.js` `timingOptions`, offset 424860 / 19행).

`daytime`·`dayofweek`·`never` 로 판정되면 곧바로 `delay` 를 0 으로 덮는다:

```
0x140075d41  mov dword ptr [r14+0x30], r13d   ; r13d = 0
```

`logon`(0) 은 이 지점을 **건너뛴다**(`0x140075cb1  jmp 0x140075d45`). §6.1 에서 보듯
타이머 틱은 mode 가 2·3 이 아닌 전부에서 도므로, `logon` 은 `delay` 가 살아 있으면
타이머 전환도 **같이** 돈다. `never` 는 `delay = 0` 이 0.01 가드에 걸려 실제로 멈춘다.

### 3.2 `playlist.items[]`

`0x140075eac` 에서 `items` 를 찾고, `array`(6) 나 `object`(7) 면 순회한다.
원소는 스트라이드 **0x48** 바이트 구조체로 저장된다(`0x140075ae7  add rbx, 0x48`).

원소가 문자열이면 그대로 파일 경로. 오브젝트(7)면(`0x1400761a1  cmp eax,7`):

| 키 | 타입 | 구조체 | 읽는 VA |
| --- | --- | --- | --- |
| `file` | string | 항목 문자열 | `0x1400761b1` |
| `daytimeend` | number | `+0x20` (float) | `0x1400761cb` |
| `preset` | string | — | `0x1400761e5` |

항목 구조체(0x48바이트)는 이렇게 생겼다 — 임시 버퍼 `[rbp-0x49]` 를 채워
`sub_140077960` 으로 벡터에 밀어 넣는다(`0x14007632d`):

| 오프셋 | 타입 | 내용 | 근거 |
| --- | --- | --- | --- |
| `+0x00` | `std::string` (32B) | `file` | `0x140076326  lea rdx, [rbp-0x49]` |
| `+0x20` | `float` | `daytimeend` | `0x14007629a  movss [rbp-0x29], xmm0` |
| `+0x28` | `std::string` (32B) | `preset` | `0x1400762b5  lea rcx, [rbp-0x21]` |

`daytimeend` 는 하루를 [0,1] 로 정규화한 **끝나는 시각**이다(§6.2). UI 는 항목 순서가
단조 증가하도록 강제하고, 마지막 항목의 `daytimeend` 는 저장 시 지운다
(`ui/dist/scripts/scripts.js` offset 25625 / 1행, 함수 `y()`).

디스크 표현(UI 직렬화기 `qe()`, offset 24836 / 1행):

```json
{ "name": "…", "settings": { … }, "items": [ "a.pkg", { "file": "b.pkg", "daytimeend": 0.5, "preset": "…" } ] }
```

`daytimeend` 도 `preset` 도 없는 항목은 **문자열로 축약**된다.

### 3.3 저장 위치

- 모니터별 현재 재생목록 — `config.json` → `<user>/general/wallpaperconfig/playlist`
  (키 `playlist` `0x140473c78`). 실측 config 에서는 이 사용자가 재생목록을 안 써서 비어 있다.
- 이름 붙여 저장한 재생목록 모음 — `<user>/general/playlists` (키 `0x140474ba8`).
- 브라우저 수동 전환 설정 — `<user>/general/user/browsetransition`.
  실측값: `{"transition": "none", "transitiontime": 1500}`
  (`/home/user/Waple-wallpaper-source/wallpaper_engine/config.json`).
  §4 의 전환 파서를 **그대로 재사용**한다(`0x14006cdfd  call 0x140075790`).

---

## 4. 전환 종류 표

### 4.1 특수값

전환 파서 `0x140075790–0x140075a8f` 가 `transition` 을 3갈래로 읽는다.

**bool 인 경우**(`0x1400757fd  cmp byte [rax+8], 5`):

```
0x14007580b  call 0x140086300          ; asBool
0x140075813  lea  eax, [rax*2 - 2]     ; true → 0,  false → -2
0x14007581a  mov  dword ptr [r14], eax
```

**string 인 경우**(`0x140075827  cmp byte [rax+8], 4`):

| 문자열 | 결과 | VA |
| --- | --- | --- |
| `"random"` | `-3`, 이어서 `transitionpool` 파싱 | `0x140075882`–`0x14007589d` |
| `"none"` | 저장을 건너뛴다 → 초기값 `-1` 유지 | `0x1400759c1`–`0x1400759cf` |
| 그 외 | `atoi(문자열)` | `0x1400759de`–`0x1400759e3` |

초기값은 함수 진입부에서 세운다: `0x14007579f  mov dword ptr [r8], 0xffffffff`.

| 값 | UI 라벨 | 로케일 키 | 동작 |
| --- | --- | --- | --- |
| `-1` | None | `…_transition_none` | 전환 없음. `0x14006904a` 에서 즉시 빠져나가 캡처조차 안 한다 |
| `-2` | None (reduce flicker) | `…_transition_none_no_flicker` | `0x1400692f8  cmp r12d,-2` → `sub_14005aaf0`. 셰이더 없이 **마지막 프레임만 붙잡아** 새 벽지가 뜰 때의 깜빡임을 가린다 |
| `-3` | Random | `…_transition_random` | 풀에서 추첨(§4.3) |
| `0..26` | 아래 표 | | `clamp(id, 0, 26)` — `0x14006924e`–`0x14006925c` |

`transitionpool` 은 문자열 배열이고, 원소마다 `atoi` 해서 뒤에 붙인다
(`0x140075919  mov eax,[rbx+0x38]` / `0x14007591c  cmp al,4` → `0x140075934  call 0x1402c82c0` →
`0x140075946  call 0x140077840`).
UI 는 풀이 **전체와 같아지면 키를 지운다**(`transitionPoolToggle`, offset 362730 / 19행) —
그래서 "빈 풀 = 전체 허용"이다.

**[2026-08-21 정정] 담는 그릇은 `std::set<int>` 가 아니라 `std::vector<int>` 다.**
종전 문장("집합에 넣는다")과 §4.3·`PlaylistTransition.swift` 의 "std::set 이라 중복이 없고
오름차순" 은 셋 다 틀렸다. 근거 둘.

* **삽입 헬퍼 `0x140077840`(병합 범위 `0x140077840`–`0x140077951`)은 순수 `push_back` 이다.**
  `[vec+8] != [vec+0x10]` 이면 그 자리에 4바이트를 쓰고 `[vec+8] += 4`
  (`0x140077853`–`0x140077876`), 같으면 재할당 경로로 간다(`0x14007787b`–). 정렬도 중복
  제거도 없다.
* **추첨이 연속 배열을 인덱싱한다.** `n = (end - begin) / 4`(`0x1400691fb  sub r12, rax` /
  `0x1400691fe  sar r12, 2`)이고 원소를 `mov ecx, [rax + rbx*4]`(`0x140069249`)로 읽는다.
  레드블랙 트리라면 둘 다 성립할 수 없다.

파스 루프는 jsoncpp 배열을 **인덱스 순서로** 돈다(`0x14007594b  cmp byte [rax+0x19], 0` —
`_Isnil` 을 보는 트리 순회). 그래서 관측되는 계약이 셋이다:

1. **저작 순서가 곧 인덱스다.** `["18","0"]` 의 인덱스 0 은 `18` 이다.
2. **중복이 살아남는다.** `["0","0","26"]` 이면 Fade 가 두 칸을 차지해 확률이 2/3 이 된다 —
   **가중치를 손으로 적을 수 있다는 뜻**이다(UI 는 그런 값을 만들지 않는다).
3. 태그 4(string) 가 아닌 원소는 `push_back` 앞의 검사(`0x14007591c`)에서 걸러져
   **0 이 들어가는 게 아니라 아예 안 들어간다**.

Waple 쪽은 `PlaylistRandomDraw.effectID(pool:unit:)` 이 `Set<Int>` 를 받아 `sorted()` 하고
있었다 — 세 계약을 전부 어겼다. `[Int]` 로 바꾸고
`Tests/WapleCoreTests/PlaylistTransitionTests.swift` 의
`testPoolIndexFollowsAuthoredOrderNotSortOrder` ·
`testPoolKeepsDuplicatesSoWeightsAreAuthorable` 로 값을 잠갔다.

### 4.2 27종

| id | 이름(로케일) | 셰이더 주석 | frag 줄 | 특수 요구 |
| --- | --- | --- | --- | --- |
| 0 | Fade | Fade | 222–225 | |
| 1 | Mosaic | Mosaic | 226–231 | |
| 2 | Diffuse | Diffuse | 232–237 | |
| 3 | Horizontal slide | Horizontal slide | 238–243 | |
| 4 | Vertical slide | Vertical slide | 244–249 | |
| 5 | Horizontal fade | Horizontal fade | 250–254 | |
| 6 | Vertical fade | Vertical fade | 255–259 | |
| 7 | Clouds | Cloud blend | 260–267 | `g_Hash` |
| 8 | Burnt paper | Burnt paper | 268–309 | `g_Hash`, `ddx`/`ddy` |
| 9 | Circular | Circular blend | 310–317 | |
| 10 | Zipper | Zipper | 318–337 | |
| 11 | Door | Door | 338–354 | |
| 12 | Lines | Lines | 355–360 | |
| 13 | Zoom | Zoom | 361–377 | `blur13`(7탭 바이리니어) 2회 |
| 14 | Drip | Drip vertical | 378–393 | `g_Hash` |
| 15 | Pixelate | Pixelate | 394–404 | |
| 16 | Bricks | Bricks | 405–407 | **지오메트리 셰이더**(geom 34–140): 4세트 × 7장 = 28장 |
| 17 | Paint | Paint | 408–468 | `g_Hash`, fbm 8옥타브 |
| 18 | Fade to black | Fade to black | 469–472 | |
| 19 | Twister | Twister | 473–488 | |
| 20 | Black hole | Black hole | 489–532 | `g_Hash` |
| 21 | CRT | CRT | 533–574 | **밉맵 뷰**(`g_Texture0MipMapped`) |
| 22 | Radial wipe | Radial wipe | 575–584 | |
| 23 | Glass shatter | Glass shatter | 585–603 | **정점 메시**(vert 70–122): `a_Center`(TEXCOORD1)·`a_Normal`, 3D 회전 + 뷰프로젝션 |
| 24 | Bullets | Bullets | 604–703 | `g_Hash`, `g_Hash2`, `ddx`/`ddy` |
| 25 | Ice | Ice | 704–744 | **밉맵 뷰**, `g_Hash`, `g_Hash2`, `ddx`/`ddy` |
| 26 | Boilover | Boilover | 745–800 | `g_Texture1Noise`, `g_Texture2Clouds`, wrap 샘플러, 25회 루프 |

교차 검증 출처 3개가 전부 일치한다(`scripts/re/playlist_transition.py` 출력 —
`getTransitionOptions()` 는 offset 360101 / 19행):
셰이더 분기 27개 ↔ `getTransitionOptions()` 의 숫자 값 27개 ↔ 로케일 키 27개.
UI 의 목록 **순서**는 id 순이 아니다(0, 18, 1, 2, … — Fade 다음이 Fade to black).

### 4.3 랜덤 추첨과 27이라는 숫자

풀이 비었을 때(`0x1400691b5  cmp rax, r12` → 같으면 아래로):

```
0x1400691ba  call 0x1402c97a0                    ; rand()  → 0..32767
0x1400691c6  mov  ecx, 0x1a                      ; 상한 26
0x1400691d5  divss xmm1, [rip+0x429783] ; 0x140492960 f32=32767.0
0x1400691dd  mulss xmm1, [rip+0x4296af] ; 0x140492894 f32=27.0
0x1400691e9  cvttss2si eax, xmm1
0x1400691ed  cmp  eax, ecx
0x1400691ef  cmovl ecx, eax                      ; min(·, 26)
0x1400691f6  cmovs ecx, eax(=0)                  ; max(·, 0)
```

**`27.0f`(`0x140492894`)와 상한 `26`(`0x1400691c6`)이 셰이더 분기 수와 정확히 맞는다** —
바이너리가 독립적으로 27종을 확인해 준다.

풀이 비어 있지 않으면 원소 개수 `n = (end-begin)/4` 로 같은 계산을 해서 풀의 인덱스를
고른다(`0x1400691fb`–`0x140069249`). **그 `/4` 와 `[rax + rbx*4]` 가 풀이 `std::vector<int>`
라는 증거다** — §4.1 의 2026-08-21 정정을 봐라.

**[2026-08-21 추가] 풀 경로는 `0..26` 클램프를 거치지 않는다.** 풀에서 뽑은 뒤
`0x14006924c  jmp 0x140069261` 이 클램프 블록(`0x14006924e`–`0x14006925c`)을 **건너뛴다**.
파스 쪽도 원소를 `atoi` 한 값을 그대로 집합에 넣을 뿐이라(`0x140075934` → `0x140075946`)
어디서도 범위를 좁히지 않는다. 즉 손으로 고친 `transitionpool: ["99"]` 는 `FADEEFFECT=99`
로 컴파일된다(셰이더의 27개 분기 어디에도 안 걸린다). 클램프가 걸리는 것은 `transition`
이 리터럴 정수일 때의 **비-`-3` 경로뿐**이다. UI 는 그런 값을 만들지 않으므로 실사용에서는
드러나지 않는다.

`rand()/32767.0` 이 **닫힌 구간 [0,1]** 이라는 점도 여기서 의미가 있다 — `rand()` 가
32767 을 내면 `1.0 × 27 = 27` 이 되어 유효 id 를 넘는다. 빈 풀 경로의 상한 26 은
장식이 아니라 정확히 이 한 경우를 위해 있다.

### 4.4 효과 능력 플래그 — 하드코딩이 아니라 **셰이더 리플렉션**

`0x14005c390–0x14005cac9` 가 컴파일 결과를 리플렉션해 3비트를 세운다. 그 값이
`[obj+0x114]` 에 저장되고(`0x14005983c`) 렌더 스레드가 그걸로 분기한다.

| 비트 | 조건 | 세우는 VA | 결과 |
| --- | --- | --- | --- |
| `1` | 리소스 이름에 `g_Texture0MipMapped` 가 있다 | `0x14005c856` | 소스 텍스처를 밉맵으로 만든다 (21, 25) |
| `2` | VS 입력 시그니처에 `TEXCOORD` **인덱스 1** 이 있다 | `0x14005c786`–`0x14005c78c` | 파편 메시 정점버퍼를 만든다 (`0x14005985e  call sub_14005f3c0`) — 23 |
| `4` | 리소스 이름에 `g_Texture1Noise` 또는 `g_Texture2Clouds` 가 있다 | `0x14005c883` | noise.png / clouds_256.png 를 로드한다 (`0x140059926`, `0x140059a56`) — 26 |

즉 **효과 id ↔ 필요 리소스 표가 코드에 없다.** 셰이더가 무엇을 선언했는지만 본다.
포팅할 때 이 성질을 그대로 가져가면 표를 유지보수할 필요가 없다.

---

## 5. 전환 타이밍과 이징

### 5.1 호스트는 선형이다

렌더 루프(진입 `0x14005a250`, 프레임 역방향 분기 `0x14005a7a8 → 0x14005a2f4`,
대기 재시도 `0x14005a2d1 → 0x14005a250`) 안:

```
0x14005a351  call qword ptr [rip+0x3cc231]        ; QueryPerformanceCounter
0x14005a367  cvtsi2ss xmm0, qword ptr [r15+0xc0]  ; 주파수(ticks/s)
0x14005a370  sub  rcx, qword ptr [r15+0xb8]       ; now - last
0x14005a377  mov  qword ptr [r15+0xb8], rax       ; last = now
0x14005a385  cvtsi2ss xmm6, rcx
0x14005a38a  divss xmm6, xmm0                     ; dt(초)
0x14005a38e  addss xmm6, dword ptr [r15+0xc8]     ; elapsed += dt
0x14005a397  movss dword ptr [r15+0xc8], xmm6
0x14005a3a0  subss xmm6, xmm9                     ; xmm9 = 0.1f  ← 리드인
0x14005a3a5  movd  xmm0, dword ptr [rax+0x60]     ; transitiontime (ms, int)
0x14005a3ad  mulss xmm0, xmm8                     ; xmm8 = 0.001f
0x14005a3b2  divss xmm6, xmm0
0x14005a3b6  comiss xmm14, xmm6                   ; xmm14 = 1.0f
   …                                             ; clamp(·, 0, 1)
0x14005a3cd  movaps xmm6, xmm14
```

```
progress = clamp( (elapsed_seconds - 0.1) / (transitiontime_ms * 0.001), 0.0, 1.0 )
```

상수 VA: `0.1f` `0x140492654`(로드 `0x140059b76`), `0.001f` `0x140492608`(로드 `0x14005a2e3`),
`1.0f` `0x140492704`, `32767.0f` `0x140492960`(로드 `0x14005a2ec`), 하한 0 은 `xorps xmm15`.

**곱셈·거듭제곱·smoothstep 이 없다 — 순수 선형이다.** 0.1초 리드인은 새 벽지가 첫 프레임을
띄울 시간을 벌어 준다(그동안 `progress == 0` 이라 캡처 프레임이 그대로 보인다).

### 5.2 이징은 전부 셰이더 안

곡선은 27개 분기가 각자 만든다. 대표적인 형태:

| 형태 | 예 | 위치 |
| --- | --- | --- |
| 선형 알파 | `color.a = 1.0 - progress` | 0 Fade, frag 224 |
| 임계 + 폭 `smooth` | `1 - smoothstep(0, smooth, max(0, progress*(1+smooth) - r))` | 1·2·5·6·7·9·12, frag 231 등 |
| 제곱 | `fallOffset = pow(smoothstep(0, 0.3, …), 2.0)` | 16 Bricks, geom 90–91 |
| 다단 smoothstep | `smoothstep(0,0.06,p)*0.05 + smoothstep(0.1,0.14,p)*0.08 + smoothstep(0.3,0.36,p)*0.15` | 23 Glass shatter, vert 91–93 |
| 역방향 페이드아웃 | `color.a = smoothstep(1.0, 0.9, g_Progress)` | 23·24·25·26, frag 602 등 |

`progress*(1+smooth) - r` 관용구가 핵심이다. `r` 이 [0,1] 마스크(노이즈·거리·좌표)일 때
`progress` 를 `1+smooth` 로 늘려 두면 `progress == 1` 에서 마스크 전 영역이 확실히 넘어간다.

### 5.3 `transitiontime` 기본값이 세 군데에서 다르다

| 출처 | 값 | 근거 |
| --- | --- | --- |
| **엔진 파서** | **500 ms** | `0x140075a2f  mov dword ptr [r14+4], 0x1f4` |
| UI 새 재생목록 기본 설정 `_e()` | 1500 ms | `ui/dist/scripts/scripts.js` offset 14828 (1행) |
| UI 설정창 폴백(숫자가 아닐 때) | 1000 ms | 같은 파일 `BrowsePlaylistSettingsModalCtrl`, offset 424569 / 19행 |
| 실측 `browsetransition` | 1500 ms | `config.json` `<user>/general/user/browsetransition` |

슬라이더 범위는 0–3000 ms, 스텝 50 (`configureTransitionSlider`, offset 362545 / 19행).
`transitiontime` 이 0 이면 위 나눗셈이 `inf` 를 만들고 clamp 가 즉시 1.0 으로 잘라 낸다 —
전환이 1프레임 만에 끝난다(크래시는 없다).

**[2026-08-21 추가] 클램프가 `comiss` 두 번이라 NaN 이 1.0 으로 간다.**

```
0x14005a3b6  comiss xmm14, xmm6      ; 1.0 vs p
0x14005a3ba  jbe 0x14005a3cd         ; 1.0 <= p  또는 unordered(NaN) → p = 1.0
0x14005a3bc  comiss xmm15, xmm6      ; 0.0 vs p
0x14005a3c0  jbe 0x14005a3c7         ; 0.0 <= p → 유지
0x14005a3c2  xorps xmm6, xmm6        ; 그 외 → p = 0.0
```

`jbe` 는 `CF|ZF` 라 unordered(NaN 이 세우는 `ZF=PF=CF=1`)를 함께 먹는다. 그래서
`transitiontime == 0` 이고 `elapsed` 가 **정확히** 0.1 인 순간의 `0/0 = NaN` 도 1.0 이다.
`elapsed < 0.1` 이면 `-inf` 라 0.0 이고, 그 위는 `+inf` 라 1.0 이다 — 세 갈래 전부 유한하다.

레지스터 셋업도 확인했다: `xmm14 = 1.0f`(`0x140058a4c`, `0x140492704`),
`xmm15 = 0.0f`(`0x140058a6e  xorps`), `xmm9 = 0.1f`(`0x140059b76`, `0x140492654`),
`xmm8 = 0.001f`(`0x14005a2e3`, `0x140492608`).

---

## 6. 언제 다음 벽지로 가는가

### 6.1 타이머 틱 — `0x140076be0–0x140076e04`

모니터 리스트를 매 프레임 순회한다. 모니터 객체 안에 재생목록 설정이 `+0x38` 부터
통째로 박혀 있어서 파서의 `+0x30/0x34/0x38/0x3c` 가 여기서는 `+0x68/0x6c/0x70/0x74` 다.

```
0x140076c88  movss xmm7, [rip+0x41b990]  ; 0x140492620 f32=0.01
0x140076c96  movss xmm8, [rip+0x41bc41]  ; 0x1404928e0 f32=60.0
…
0x140076d3b  test byte ptr [rbx+0x74], 2         ; updateonpause — 정지 중이면 이게 있어야 진행
0x140076d41  mov  eax, dword ptr [rbx+0x70]      ; mode
0x140076d44  sub  eax, 2
0x140076d47  cmp  eax, 1
0x140076d4a  jbe  0x140076d92                    ; mode ∈ {2,3} → 시각 기반, 타이머 안 씀
0x140076d4c  movss xmm1, dword ptr [rbx+0x68]    ; delay(분)
0x140076d51  comiss xmm7, xmm1
0x140076d54  ja   0x140076dad                    ; delay < 0.01 → 아무것도 안 함
0x140076d59  addss xmm0, dword ptr [rbx+0x7c]    ; elapsed += dt
0x140076d5e  movss dword ptr [rbx+0x7c], xmm0
0x140076d63  divss xmm0, xmm8                    ; 초 → 분
0x140076d68  comiss xmm1, xmm0
0x140076d6b  ja   0x140076dad                    ; 아직 delay 에 못 미침
0x140076d79  call qword ptr [rax+0x20]           ; 현재 벽지 타입
0x140076d7c  cmp  eax, 4                         ; 4 = 동영상
0x140076d81  test byte ptr [rbx+0x74], 1         ; videosequence → 타이머 전환 보류
…
0x140076da5  call 0x140067a00                    ; 다음 벽지로
```

정리하면:

- `elapsed` (`+0x7c`, float 초) 는 **프레임 델타를 계속 누적**한다.
- `delay` 는 **분**. `elapsed/60 >= delay` 에서 넘어간다.
- `delay < 0.01분`(=0.6초) 이면 아예 안 돈다 — `never` 모드가 여기 걸린다.
  그리고 **그때는 `elapsed` 누적 자체가 안 일어난다**(`0x140076d54  ja 0x140076dad` 가
  `0x140076d59  addss` 앞에 있다).
- **`updateonpause` 가 꺼져 있으면 일시정지 중에 타이머가 멈춘다**(`0x140076d3b`).
- **`videosequence` 가 켜져 있고 현재가 동영상이면 타이머 전환을 건너뛴다** —
  영상이 끝날 때 다른 경로가 전환한다.

**[2026-08-21 추가] 세 가지가 더 있다. 함수 머리를 직접 뜨고서야 보였다.**

1. **프레임 델타가 5초로 잘린다.**
   ```
   0x140076c4d  cvtsi2ss xmm6, rcx                 ; now - last (ticks)
   0x140076c52  divss    xmm6, xmm0                ; / 주파수 → 초
   0x140076c56  minss    xmm6, dword [rip+…]       ; 0x140492858 f32=5.0   ← 상한
   ```
   곧 절전·최대화·긴 멈춤 뒤에 돌아와도 `elapsed` 가 한 번에 튀지 않는다. 한 틱에 최대 5초다.
   재구현이 `Date()` 차분을 그대로 더하면 여기서 갈린다 —
   `WapleCore.PlaylistSettings.maxTickDeltaSeconds` 에 상수로 두고 테스트로 잠갔다.

2. **인트로 벽지가 걸려 있으면 동영상 전진을 보류한다** — `videosequence` 와 **별개의** 관문이다.
   ```
   0x140076d7c  cmp  eax, 4                        ; 4 = 동영상
   0x140076d81  test byte [rbx+0x74], 1            ; videosequence → 보류
   0x140076d87  cmp  byte [rbx+0xe2], 0            ; 인트로 벽지가 지금 걸려 있다 → 보류
   0x140076d8e  jne  0x140076dad
   ```
   이 둘은 §6.6 의 전진 관문
   `(mode==timer && videosequence) || (playintro && introShowing)` 과 **정확한 여집합**이다 —
   타이머가 보류하는 경우가 곧 동영상 종료가 받는 경우다. 우연이 아니라 설계다.

3. **`daytime`/`dayofweek`(mode 2·3)도 이 틱에서 전진한다** — 다만 경과시간 축을 안 쓸 뿐이다.
   ```
   0x140076d4a  jbe  0x140076d92                   ; mode ∈ {2,3}
   0x140076d92  test r15b, r15b                    ; 세 번째 인자(bool)
   0x140076d95  je   0x140076dad
   0x140076d97  …    call 0x140067a00              ; 다음 벽지 결정
   ```
   `r15b` 는 틱 함수의 **세 번째 인자**다(`0x140076bff  movzx r15d, r8b`). 누가 무엇을 넘기는지는
   못 봤다 — **[미해결]**. "시각 기반 모드는 타이머 틱을 안 탄다" 는 종전 요약은 절반만 맞다:
   `delay`/`elapsed` 축을 안 탈 뿐, 전진 호출은 같은 틱에서 나온다.

### 6.2 `daytime` (mode 2) — `0x140067adc`–`0x140067b61`

```
0x140067ae7  call 0x1402c83d4                ; localtime
0x140067b17  imul ecx, dword ptr [rax+8], 0x3c   ; tm_hour * 60
0x140067b23  add  ecx, dword ptr [rax+4]         ; + tm_min
0x140067b2d  divss xmm1, [rip+0x42ae13]  ; 0x140492948 f32=1440.0
…
0x140067b47  movss xmm0, dword ptr [r9 + rcx*8 + 0x20]   ; item[i].daytimeend
0x140067b52  comiss xmm0, xmm1
0x140067b55  ja   0x140067b66                            ; daytimeend > now → 이 항목
```

`now = (hour*60 + min) / 1440` 로 정규화하고, `daytimeend` 가 그보다 큰 **첫 항목**을 고른다.
항목 스트라이드는 `0x48`(`lea rcx,[rax+rax*8]` → ×9, `*8` → 72).

### 6.3 `dayofweek` (mode 3) — `0x140067bc7`–`0x140067c2e`

```
0x140067be4  call qword ptr [rip+0x3be5c2]   ; GetLocalTime
0x140067bee  movzx ebx, word ptr [rbp-0x6c]  ; SYSTEMTIME.wDayOfWeek (일=0)
0x140067bf2  call 0x14003dcf0                ; 로케일 첫 요일 (0=월 … 6=일)
0x140067bfb  sub  ebx, eax
0x140067c01  add  ebx, 6
   …                                          ; ebx mod 7
```

`index = (wDayOfWeek - firstDayOfWeek + 6) mod 7`. 기본 로케일(월요일 시작, `eax = 0`)에서
월요일(`wDayOfWeek == 1`) → 슬롯 0, 일요일(`0`) → 슬롯 6. 로케일 조회는
`GetLocaleInfoEx(NULL, LOCALE_IFIRSTDAYOFWEEK | LOCALE_RETURN_NUMBER, …)` 이고
6 으로 상한을 건다(`0x14003dd1e`–`0x14003dd25`). 사용자 오버라이드 키 `dayofweekoffset`
(`0x140475148`) 도 있다. UI 는 항목 7개를 넘기지 못하게 막는다
(`ui_browse_playlist_modal_settings_day_of_week_warning_*`).

### 6.4 `order = random` — 셔플백 `0x140068010`–`0x1400681a0`

WE 는 단순 난수가 아니라 **소진형 셔플백**을 쓴다:

1. 백(`+0x50..+0x58`)이 비면 전체 항목으로 채운다(`0x14006803f  call sub_140077240`).
   `playintro` 가 켜져 있으면 첫 항목을 빼고 채운다(`0x14006803b  add r9, 0x48`).
2. 백 크기가 1(=`playintro` 면 2)보다 크면(`0x140068054`–`0x140068065`)
   **지금 재생 중인 벽지를 백에서 제거**한다(`0x1400680a0`–`0x140068114`) — 리필 직후에
   같은 벽지가 다시 나오는 것을 막는다.
3. `idx = clamp((int)(rand()/32767 * n), 0, n-1)` 로 뽑고(`0x140068138`–`0x140068177`)
   **그 항목을 백에서 지운다**(`0x14006819b  call sub_14007a7e0`).

즉 **한 바퀴가 다 돌기 전에는 같은 벽지가 두 번 나오지 않는다.**

**[2026-08-21 신규] 난수원과 시드 — `rand()` 는 스레드마다 따로 돈다.**
(이하 전부 `wallpaper64.exe`, imagebase `0x140000000`.)

`0x1402c97a0` 이 CRT `rand()` 다. MSVC 표준 LCG 그대로다:

```
0x1402c97a4  call 0x1402d9894                    ; __acrt_getptd()  — 스레드별 데이터
0x1402c97a9  imul ecx, dword [rax+0x28], 0x343fd ; seed *= 0x343FD
0x1402c97b0  add  ecx, 0x269ec3                  ; seed += 0x269EC3
0x1402c97b6  mov  dword [rax+0x28], ecx
0x1402c97b9  shr  ecx, 0x10 / and ecx, 0x7fff    ; (seed >> 16) & 0x7FFF   → 0..32767
```

**시드가 `__acrt_getptd()+0x28` 에 있다 — 전역이 아니라 스레드별이다.** 그래서 전환 렌더
스레드(§1 의 `0x140058770`–`0x14005a884`)와 벽지 스레드는 서로 **다른 수열**을 본다.

`srand`(`0x1402c97cc`, 본체 세 명령 — `[__acrt_getptd()+0x28] = ecx`)의 호출부는 이미지 전체에
**정확히 4곳**이고, **네 곳 모두 `QueryPerformanceCounter` 의 하위 32비트로 시드한다**:

| 시드 자리 | 어느 함수 | 시드 값 |
| --- | --- | --- |
| `0x140007ddf` | `0x140007b60` 계열(초기화) | `QPC` 하위 32비트(`0x140007dd6`) |
| `0x14000b530` | `0x14000a220` 계열(초기화) | 같음(`0x14000b524`) |
| `0x1400587ae` | **전환 렌더 스레드 진입부** `0x140058770` | 같음(`0x1400587a2`) — 스레드가 뜰 때마다 |
| `0x14011065e` | **씬 마운트** `0x140110630` | 같음(`0x140110652`) |

여기서 나오는 결론 셋.

1. **셔플백도 전환 추첨도 재현 가능한 시드가 없다.** 저장 파일(§7)에 시드 필드가 없고,
   시드는 매번 QPC 다. 같은 재생목록을 같은 순서로 다시 재생시킬 방법이 엔진에 없다.
2. **전환 효과 추첨은 전환 스레드의 시드를 쓴다.** 그 스레드는 전환마다 새로 뜨고 뜰 때마다
   `srand(QPC)` 하므로, 효과 추첨은 사실상 매 전환 독립이다.
3. **재구현은 여기서 자유롭다.** WE 가 지키는 계약은 "균등하고 재현 불가" 뿐이다. Waple 의
   `ShuffleBag` 이 `SplitMix64` 시드를 받아 **재현 가능**하게 만든 것은 WE 를 어기는 게 아니라
   테스트를 위해 더한 것이다 — 실제 사용에서 시드를 QPC 상당(`DispatchTime.now()`)으로 주면
   관측 동작이 같다.

### 6.5 `order = sorted` — `0x14006826f`–`0x1400682d0`

```
0x140068275  movsxd rax, dword ptr [r14+0x78]   ; 커서
0x140068288  div  rcx                           ; % 항목수
0x14006828b  mov  dword ptr [r14+0x78], edx
0x14006828f  test r13b, r13b                    ; playintro?
0x140068294  test edx, edx                      ; 커서가 0 으로 되감겼나
0x140068298  sub  r8, qword ptr [r14+0x38]      ; ← [2026-08-21 추가] 항목 수를 다시 센다
0x14006829c  sar  r8, 3
0x1400682a0  imul r8, r15
0x1400682a4  cmp  r8, 1
0x1400682a8  jbe  0x1400682b7                   ; **항목이 1개 이하면 건너뛰기를 하지 않는다**
0x1400682aa  mov  dword ptr [r14+0x78], 1       ; → 1 로 건너뛴다(인트로 재생 안 함)
0x1400682b2  mov  edx, 1
…
0x1400682d0  inc  dword ptr [r14+0x78]
```

**[2026-08-21 정정] `count > 1` 가드는 WE 에도 있다.** 종전 덤프가 `0x140068294` 와
`0x1400682aa` 사이의 네 명령을 빠뜨렸고, 그 때문에 `PlaylistTransition.swift` 와 그 테스트가
"이 가드는 Waple 이 더한 것이고 WE 는 인덱스 1 을 낸다"고 적고 있었다. 항목이 1개면 WE 도
인덱스 0 을 낸다. 코드는 처음부터 맞았고 **주석과 테스트 문구만 틀렸다** — 지금은
`testSortedCursorSingleItemIgnoresPlayIntro` 가 그 자리를 값으로 잠근다.
(함정 15 "거꾸로/부분 디스어셈하면 어긋난다" 의 또 한 사례다.)

`beginfirst` 는 별도 경로에서 커서를 0 으로 리셋한다(`0x140067ee6  mov dword ptr [r14+0x78], r13d`).
`playintro` 는 "첫 벽지는 부팅 직후 1회만" 이라는 뜻이라, 되감길 때 인덱스 1 로 건너뛴다.

### 6.6 동영상 종료 → 전진 [2026-08-21 신규 — §10 의 미해결 항목을 닫는다]

§6.1 의 타이머 틱은 `videosequence` 가 켜져 있고 현재가 동영상이면 전진을 **보류**한다.
그 보류를 실제로 받는 반대편이 이 경로다. 세 단계다.

**① 벽지 창이 메시지를 던진다.**

```
0x14011b10c  mov  r8d, dword ptr [rdi+0x154]   ; wParam = 벽지 id
0x14011b113  xor  r9d, r9d                     ; lParam = 0
0x14011b116  mov  edx, 0x40a                   ; WM_USER + 0x0A
0x14011b11b  call qword ptr [rip+0x30b8a7]     ; PostMessageW  (0x1404269c8)
```

`0x40a` 를 싣는 자리는 이미지 전체에 **4곳**뿐이다(`0x14011b116` · `0x140120bcd` ·
`0x140122a37` · `0x1401245c4`). 뒤 두 곳은 `SendMessageTimeoutW`(`0x140426720`) 다.

**② 메인 창 프로시저가 받는다.** 디스패치는 점프테이블이다 — `0x14002d918`
`lea eax,[rdx-0x402]` / `cmp eax,0x13` / `ja 기본` 뒤 RVA `0x2e690` 의 20엔트리 표를
탄다. `msg-0x402 == 8` 이 `0x14002dc43` 이다. 표를 그대로 뜨면
`0x402→0x14002d9d9`, `0x406→0x14002deaa`, `0x407→0x14002dec2`, `0x408→0x14002dcb6`,
`0x409→0x14002dd60`, **`0x40a→0x14002dc43`**, `0x40f→0x14002e218`, `0x411→0x14002d93b`,
`0x412→0x14002dd6c`, `0x415→0x14002d97d`, 나머지는 전부 기본 `0x14002224a` 다.

핸들러 앞머리는 **재진입 가드**다:

```
0x14002dc43  test dword ptr [rip+0x4b18f3], 0x204   ; 0x1404df540 상태 플래그
0x14002dc4d  je   0x14002dc82                       ; 평시 → 전진 경로
0x14002dc4f  cmp  byte ptr [rip+0x4b1f62], sil      ; 0x1404dfbb8 래치
…
0x14002dc68  lea  rcx, [rip+0x447389]               ; 0x140474ff8
             "Windows reentrancy during WM_USER_VIDEO_ENDED prevented."
0x14002dc76  call 0x140098760                       ; 로그만 남기고 0 반환
```

이 문자열의 xref 는 `0x14002dc68` **한 곳뿐**이다. 곧 이 메시지 이름은 우리가 붙인 게
아니라 WE 자신의 것이다.

**③ 전진 관문 `0x140067720`–`0x1400677b9`.** 모니터 노드 리스트(`0x1404e5330`)를 훑는다.
필드 오프셋은 §6.1 과 같은 계 — `+0x68` delay, `+0x6c` order, `+0x70` mode, `+0x74` 플래그,
`+0x78` 커서, `+0x7c` elapsed.

```
0x140067749  cmp  dword ptr [rax+0x154], r9d   ; 이 모니터의 벽지 id == wParam
0x140067756  cmp  qword ptr [rbx+0x38], rax    ; items 벡터가 비어 있지 않다   → dl
0x140067762  cmp  dword ptr [rbx+0x70], 1      ; mode == timer
0x140067768  test byte ptr [rbx+0x74], 1       ; videosequence                → cl
0x140067774  test byte ptr [rbx+0x74], 0x10    ; playintro
0x14006777a  cmp  byte ptr [rbx+0xe2], 0       ; 인트로 벽지가 지금 걸려 있다  → al
0x140067789  test dl, dl / je 다음_노드
0x14006778d  or   cl, al
0x14006778f  jne  0x1400677b0                  ; → 전진
…
0x1400677fa  call 0x140067a00                  ; 다음 벽지 결정(§6.4/§6.5)
```

즉

```
advanceOnVideoEnd = (mode == timer && videosequence) || (playintro && introShowing)
```

**여기서 새로 드러나는 것 두 가지.**

1. **`videosequence` 는 `mode == timer` 밖에서는 죽은 키다.** 파서(§3.1)는 mode 와 무관하게
   이 비트를 읽으므로 설정 파일만 봐서는 이 의존이 보이지 않는다. `daytime`/`dayofweek`/
   `never`/`logon` 에서 `videosequence: true` 를 써 두면 아무 일도 일어나지 않는다.
2. **`[monitor+0xe2]` 는 "지금 걸린 것이 인트로 벽지" 다.** `beginfirst` 분기가 첫 항목을
   걸 때 `playintro` 값을 그대로 심고(`0x140067edc  mov byte ptr [rax+0xe2], r13b`, 여기서
   `r13b` 는 `0x140067d8b`–`0x140067d93` 의 `([flags+0x74] >> 4) & 1` = `playintro`),
   그 밖의 전진에서는 0 으로 지운다(`0x140067ff2  mov byte ptr [rax+0xe2], 0`).
   짝인 `[monitor+0xe1]` 은 `beginfirst` 대기 래치다(`0x140067ebe` 에서 검사, `0x140067ecb`
   에서 소거). 그래서 **인트로 동영상은 `videosequence` 가 꺼져 있어도 끝나면 넘어간다.**

Waple 쪽 구현: `WapleCore.PlaylistSettings.shouldAdvanceOnVideoEnd(introShowing:)`
(계약 잠금 3건 — `Tests/WapleCoreTests/PlaylistTransitionTests.swift`).
아직 **호출부가 없다** — `SceneVideoLayer.endObserver` / `VideoRenderer` 의 종료 통지를
재생목록 전진에 잇는 것은 §8.2 의 갭 #6 이 그대로 남아 있다.

---

## 7. 상태 영속

`bin/playliststatetime.bin`(`0x1404780c8`) 은 **모니터별 경과시간**을 재부팅 너머로 나른다.
기록: `0x140070690–0x140070dcc`.

```
0x140070760  movss xmm6, dword ptr [rbx+0x7c]   ; = §6.1 의 elapsed(초)
0x14007076c  call 0x14007a1d0                   ; map[monitorName]
0x140070771  movss dword ptr [rax], xmm6
```

실측 파일(95바이트, `wallpaper_engine/bin/playliststatetime.bin`):

```
08 00 00 00  "PLPV0005"          u32 길이 + 매직 (매직 VA 0x1404780b8)
ba 02 83 6a                       u32 = 1786970810  → 유닉스 시각 (2026-08-19)
00 00 00 00                       u32 = 0
01 00 00 00                       u32 = 1           맵 항목 수
0f 00 00 00  "wallpaperconfig"    키
03 00 00 00                       하위 항목 3개
08 00 00 00  "Monitor0"  00 00 00 00   float 0.0
08 00 00 00  "Monitor1"  40 fc 69 49   float 958404.0
08 00 00 00  "Monitor2"  40 fc 69 49   float 958404.0
```

문자열은 전부 `u32 길이 + 바이트`, 값은 `float32 LE`.

`958404.0` 초 ≈ 11.1일이다. 이 사용자는 재생목록을 쓰지 않아(§3.3) 전진이 한 번도
일어나지 않았고, 그래서 카운터가 리셋 없이 계속 쌓인 값으로 읽는 게 자연스럽다 —
전진할 때 `0x1400684ea  mov dword ptr [r14+0x7c], r13d` 로 0 이 된다.

`bin/playliststate.bin`(`0x1404780a0`, 기록 `0x14006eef0–0x140070688`) 은 같은 형식으로
같은 디렉터리에 쓰인다. **이 설치본에는 파일이 없어 레코드 내용을 실물 대조하지 못했다**(§10).

---

## 8. Waple 현황 대조

`grep -rn -i "playlist\|transition" Sources/` 결과 156줄. 대부분은 **오디오** 재생목록
(`Sources/WapleRender/SceneAudioPlayer.swift:144` `final class Playlist`)이나 CSS 전환
(`Sources/WapleRender/WebHardPauseJS.swift:521`) 이라 이 서브시스템과 무관하다.

### 8.1 이미 있는 것

| 파일 | 내용 |
| --- | --- |
| `Sources/WapleLibrary/PlaylistStore.swift:5–24` | `Model { enabled, intervalMinutes=30, ids:[String], shuffle=false }`, `playlist.json` 영속 |
| `Sources/Waple/AppLogic.swift:145–208` | `enum PlaylistScheduling` — `shouldScheduleTimer` / `intervalSeconds` / `shuffleNext` / `canAdvance` / `shouldAdvanceNow` / `advance` |
| `Sources/Waple/AppDelegate.swift:684–720` | `schedulePlaylistTimer()` / `advancePlaylist()` |
| `Sources/Waple/Shell/NowPlayingBar.swift:291–297` | 간격 슬라이더(1…240분), 셔플 토글 |
| `Sources/Waple/Surfaces/Settings/SettingsViewModel.swift:70–112` | 설정창 바인딩 |
| `Sources/WapleRender/Resources/WEAssets/shaders/HLSL/dx11playlisttransition.*` | **전환 셰이더 3개가 이미 동봉돼 있다**(HLSL 원문) |
| `spec/engine/shaders.json:82–179` | 세 셰이더의 해시·함수·콤보·`gRefs` 정본 |
| `Sources/WapleCore/PlaylistTransition.swift` | **[2026-08-21 신규]** 순수 코어 — 전환 27+3종·선형 타이밍·셔플백·풀 추첨·모드/순서 열거. `import Foundation` 만 쓰므로 리눅스에서 실제로 돈다 |
| `Tests/WapleCoreTests/PlaylistTransitionTests.swift` | 위의 계약 잠금 54건(왕복·경계·불변식) |

### 8.2 없는 것

| # | WE 기능 | Waple | 붙일 곳 |
| --- | --- | --- | --- |
| 1 | **전환 효과 27종 + 오버레이 파이프라인** | 전무 — 벽지 교체가 즉시 컷 | 신규 `Sources/WapleRender/PlaylistTransitionRenderer.swift`. 훅은 `Sources/Waple/AppDelegate.swift:490` `apply(folderURL:)` — 새 렌더러를 만들기 직전에 기존 렌더러 프레임을 캡처 |
| 2 | `transition` / `transitionpool` / `transitiontime` 스키마 | 없음 | `Sources/WapleLibrary/PlaylistStore.swift` `Model` |
| 3 | 모드 5종(`logon`/`daytime`/`dayofweek`/`never`) | `enabled: Bool` 하나 = timer 전용 | `Sources/Waple/AppLogic.swift` `PlaylistScheduling` 에 모드 디스패치 추가 |
| 4 | 항목별 `daytimeend` / `preset` | `ids: [String]` 평문 배열 | `PlaylistStore.Model.ids` → 구조체 배열로 승격 |
| 5 | **셔플백**(소진 전 무반복) | `shuffleNext` 는 "직전 1개만 회피"(`AppLogic.swift:171–177`) — 3곡짜리 목록에서 A,B,A,B 가 가능 | **구현됨**: `WapleCore.ShuffleBag`. `AppLogic.swift:171–177` 을 그 위임으로 바꾸면 된다 — 대조는 §8.4 |
| 6 | `videosequence`(동영상 끝나면 전환) | 없음 | `Sources/WapleRender` 의 `VideoRenderer` 종료 콜백 → `advancePlaylist()` |
| 7 | `updateonpause` **옵션** | `shouldAdvanceNow(isPaused:)`(`AppLogic.swift:188`) 이 정지 중엔 항상 false — WE 의 `updateonpause=false` 에 **고정** | `AppLogic.swift:188` 을 설정값으로 |
| 8 | `beginfirst` / `playintro` | 없음 | `PlaylistScheduling` |
| 9 | **모니터별 재생목록** | 전역 1개. `MonitorAssignmentStore` 는 있지만 재생목록과 안 엮임 | `PlaylistStore` 를 모니터 키로 분할 |
| 10 | **경과시간 영속** | `Timer` 라 앱 재시작마다 0 부터 | `AppDelegate.swift:684` — 누적 초를 `playlist.json` 에 |
| 11 | 이름 붙인 재생목록 모음(`playlists`) | 없음 | `PlaylistStore` |
| 12 | 수동 전환 설정(`browsetransition`) | 없음 | #1 과 동일 스키마 재사용(WE 도 파서를 공유한다 — `0x14006cdfd`) |
| 13 | `delay` 를 실수 분으로 (WE 하한 0.01분 = 0.6초) | `Int` 분, 하한 1분 | `PlaylistStore.intervalMinutes` + `AppLogic.swift:162–165` |
| 14 | **프레임 델타 5초 상한** (`0x140076c56  minss xmm6, 5.0f`) | 없음 — Waple 은 `Timer` 라 절전에서 깨면 지연분이 한 번에 온다 | `WapleCore.PlaylistSettings.maxTickDeltaSeconds` / `clampedTickDelta(_:)` 를 만들어 뒀다. `AppDelegate.schedulePlaylistTimer()` 가 누적 초를 직접 굴리게 될 때 그 함수를 통과시키면 된다 |
| 15 | **인트로 벽지가 걸려 있으면 동영상 타이머 전진 보류** (`0x140076d87  cmp byte [rbx+0xe2], 0`) | 없음 | `WapleCore.PlaylistSettings.shouldTimerAdvance(...,introShowing:)` 에 관문을 넣었다. `[+0xe2]` 에 해당하는 상태(=인트로 벽지가 지금 걸려 있음)를 `AppDelegate` 가 갖게 되면 넘기면 된다 |

### 8.3 포팅에서 먼저 걸릴 것

- **지오메트리 셰이더가 Metal 에 없다.** 27종 중 실제 GS 를 쓰는 건 **16 Bricks 하나**다
  (geom 34–140). 나머지는 점 1개 → 전체화면 쿼드라는 자명한 GS(geom 141–161)뿐이라
  Metal 에서는 그냥 풀스크린 삼각형 드로우로 대체된다. Bricks 는 CPU 에서 28장의 쿼드를
  정점버퍼로 굽거나 인스턴싱으로 바꾸면 된다.
- **23 Glass shatter 는 정점 메시가 필요하다.** WE 는 `TEXCOORD1` 존재 여부로 이걸 감지해
  (`0x14005c786`) 메시를 만든다(`sub_14005f3c0`). 파편 격자 생성은 이 문서 범위 밖이다.
- **`ddx`/`ddy`** — 8·24·25 가 쓴다. MSL `dfdx`/`dfdy` 로 1:1 대응된다.
- **`g_Random` 은 아무도 안 읽는다.** 상수버퍼 레이아웃 호환을 위해 자리만 두면 된다.
- **`transitiontime` 기본값을 무엇으로 할지**는 §5.3 처럼 WE 자신도 세 값을 쓴다.
  UI 를 따라 1500 ms 가 실사용에 맞다.

### 8.4 셔플 규약이 정확히 어디서 갈리는가

| 축 | Waple `PlaylistScheduling.shuffleNext` (`AppLogic.swift:171–177`) | WE 셔플백 (`0x140068010`–`0x1400681a0`) | 관측되는 차이 |
| --- | --- | --- | --- |
| 상태 | **없다**(무상태). 매번 전체 목록에서 새로 뽑는다 | 백(`+0x50..+0x58`)이 호출 사이에 살아남는다 | Waple 은 재시작·설정변경에 영향이 없고, WE 는 백이 남아 이어 돈다 |
| 후보 집합 | `ids.filter { $0 != current }` — **매 추첨마다** 직전 1개만 제외 | 백에 남은 것 전부. 뽑은 항목은 백에서 삭제 | 3곡에서 Waple 은 `a,b,a,b,a,b` 로 `c` 를 영원히 건너뛸 수 있다 |
| 한 바퀴 보장 | 없음 | **있다** — 백이 빌 때까지 무반복 | n 곡을 n 번 뽑으면 WE 는 반드시 전원, Waple 은 기대값만 |
| 리필 경계 | 개념 자체가 없다 | 백이 비면 전체로 리필하고 **현재 항목을 뺀다**(`0x1400680a0`–`0x140068114`) | 첫 백만 n 개, 이후 백은 **n-1** 개다 |
| `playintro` | 없음 | 리필 시 첫 항목을 제외(`0x14006803b  add r9, 0x48`) | 인트로 벽지가 부팅 후 1회만 나온다 |
| 1곡 퇴화 | `candidates = ids` → 자기 자신 반환 | 백 크기 1 이면 현재 제거 가드가 안 걸린다(`0x14006805b  cmp rax,1`) → 자기 자신 | **같다** |
| 2곡 | 직전 제외 → 항상 교대 | 백 소진 + 리필 시 현재 제거 → 항상 교대 | **같다** |
| 난수 | `Int.random(in:)`(주입 가능) | `rand()/32767 × n` 절단 + 클램프 | WE 는 [0,1] 닫힌 구간이라 상한 클램프가 실제로 쓰인다. **[2026-08-21]** WE 는 `float32`, Waple 은 `Double` 인데 `rand()` 정의역 0…32767 × 풀 크기 1…30 **전건에서 같은 인덱스**가 나온다(`testDoublePathMatchesEngineFloat32PathOverWholeRandDomain`) — 추측이 아니라 전수 대조다 |
| 결정성 | 주입한 `random` 클로저에 달림 | 프로세스 전역 `rand()` 시드 | `ShuffleBag` 은 `SplitMix64` 시드로 완전 재현 가능하게 했다 |

교체 시 무엇이 달라지는가:

- **좋아지는 것** — 3곡 이상에서 특정 배경이 장기간 안 나오는 현상이 사라진다. 사용자
  체감으로는 "셔플이 제대로 도는" 쪽이다. `n` 곡을 `n` 번 넘기면 전원이 한 번씩 나온다.
- **바뀌는 것** — `shuffleNext` 는 순수 함수(무상태)인데 `ShuffleBag` 은 **상태를 갖는다**.
  `AppDelegate` 가 백을 소유하고 재생목록이 바뀔 때 폐기해야 한다. 지금 `advance` 는
  `next:` 클로저를 받으므로 그 클로저 안에서 백을 굴리면 호출 구조는 그대로다.
- **잃는 것** — 없다. 1곡/2곡 퇴화 동작이 기존과 **동일**해서(`위 표`) 회귀 위험이 좁다.
- **주의** — `advance(from:count:next:apply:)` 는 `apply` 실패 시 다음 후보로 넘어간다.
  백에서 뽑은 항목이 `apply` 에 실패하면 그 항목은 **이미 백에서 빠진 상태**다. 실패한
  항목을 백에 되돌릴지(재시도) 그냥 소진시킬지는 정책 선택이고, WE 도 이 상황을 다루는
  코드를 찾지 못했다. 되돌리지 않는 쪽이 무한루프가 없어 안전하다.

---

## 9. 전환 27종의 Metal 이식 난이도

셰이더 자체는 이 작업 범위 밖이다(§8.3). 대신 **무엇이 얼마나 걸릴지**를 분류해 둔다.
분류는 `dx11playlisttransition.{vert,geom,frag}` 를 분기별로 재파싱해 뽑았다 —
`ddx`/`ddy` · 반복문 · `g_Texture0MipMapped` · `g_Texture1Noise`/`g_Texture2Clouds` ·
`g_Hash`/`g_Hash2` · `fbm` 옥타브 수 · `blur13` 호출 수.

### 9.1 등급 정의

| 등급 | 뜻 | 파이프라인 작업 |
| --- | --- | --- |
| **하** | 프래그먼트 산수뿐. HLSL → MSL 문법 치환으로 끝 | 없음 |
| **중** | 밉맵 체인이나 외부 텍스처, 또는 긴 절차 노이즈 | 리소스 준비 1건 |
| **상** | 지오메트리 셰이더 또는 정점 메시 — **드로우 구조 자체가 바뀐다** | 신규 정점 파이프라인 |

`ddx`/`ddy` 는 MSL `dfdx`/`dfdy` 로 1:1 대응되므로 등급을 올리지 않는다.
`g_Hash`/`g_Hash2` 는 전환 시작 시 한 번만 뽑아 상수버퍼에 넣는 값이라(§2.3) 셰이더 쪽
작업이 없다. `g_Random` 은 **27종 중 아무도 안 읽는다** — 레이아웃 자리만 유지하면 된다.

### 9.2 표

| id | 이름 | frag 줄수 | GS 필요 | 정점 메시 | 추가 리소스 | 파생/노이즈 | 등급 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | Fade | 3 | | | | | 하 |
| 1 | Mosaic | 5 | | | | | 하 |
| 2 | Diffuse | 5 | | | | | 하 |
| 3 | Horizontal slide | 5 | | | | | 하 |
| 4 | Vertical slide | 5 | | | | | 하 |
| 5 | Horizontal fade | 4 | | | | | 하 |
| 6 | Vertical fade | 4 | | | | | 하 |
| 7 | Clouds | 7 | | | | `fbm` 6옥타브 | 하 |
| 8 | Burnt paper | 41 | | | | `fbm` 6옥타브, `ddx`/`ddy` | 중 |
| 9 | Circular | 7 | | | | | 하 |
| 10 | Zipper | 19 | | | | | 하 |
| 11 | Door | 16 | | | | | 하 |
| 12 | Lines | 5 | | | | | 하 |
| 13 | Zoom | 16 | | | | `blur13` ×2 (7탭 바이리니어) | 하 |
| 14 | Drip | 15 | | | | `fbm` 2옥타브 | 하 |
| 15 | Pixelate | 10 | | | | | 하 |
| 16 | **Bricks** | 2 | **예** | | | | **상** |
| 17 | Paint | 60 | | | | `fbm` 8+3옥타브 | 중 |
| 18 | Fade to black | 3 | | | | | 하 |
| 19 | Twister | 15 | | | | | 하 |
| 20 | Black hole | 43 | | | | | 중 |
| 21 | CRT | 41 | | | 밉맵 뷰 | | 중 |
| 22 | Radial wipe | 9 | | | | | 하 |
| 23 | **Glass shatter** | 18 | | **예** | | | **상** |
| 24 | Bullets | 99 | | | | `fbm` 4+3옥타브, `ddx`/`ddy` | 중 |
| 25 | Ice | 40 | | | 밉맵 뷰 | `fbm` 8×2옥타브, `ddx`/`ddy` | 중 |
| 26 | Boilover | 64 | | | noise.png + clouds_256.png, wrap 샘플러 | 25회 루프, `fbm` 2+3옥타브 | 중 |

합계: **하 17 · 중 8 · 상 2**.

### 9.3 상 등급 둘의 실체

**16 Bricks — Metal 에 지오메트리 셰이더가 없다.**
`maxvertexcount(4 * BRICKS_PER_SET * SET_COUNT)` = `4 × 7 × 4` = **112 정점 = 28 쿼드**
(geom 102–103). 배치는 `SET_COUNT = 4` 개 세트를 세로로 쌓고, 세트마다 1행 3장 + 2행 4장 =
7장이다(geom 112–139). 2행은 `-1.0 - brickWidthHalf` 로 반 칸 어긋난다 — 벽돌 쌓기다.
**규칙적인 고정 격자라 GS 가 본질적이지 않다.** 28쿼드를 인스턴스 드로우(`instance_id` →
set/brick 인덱스)로 바꾸거나 정점버퍼에 한 번 구워 두면 그대로 재현된다.
frag 쪽 분기는 **2줄**뿐이라(405–407) 프래그먼트 작업은 사실상 없다.

**23 Glass shatter — 정점 메시가 필요하다.**
GS 가 아니라 **VS** 가 문제다. `VS_INPUT` 이 이 효과에서만 `a_Center : TEXCOORD1` 과
`a_Normal : NORMAL` 로 늘어나고(vert 5–8), `VS_OUTPUT` 도 `v_TexCoordBase : TEXCOORD1` ·
`v_WorldPos : TEXCOORD2` · `v_WorldNormal : TEXCOORD3` 세 개가 붙는다(vert 15–18).
본문(vert 70–122)은 파편별 축 난수 → `rotation3d` 4×4 행렬 → `g_ViewProjection` 투영이라
**진짜 3D 변환**이다. 필요한 것은 셰이더 번역이 아니라 **파편 격자 생성기**다 —
WE 는 `TEXCOORD` 인덱스 1 의 존재를 리플렉션으로 감지해(0x14005c786) `sub_14005f3c0` 으로
그 메시를 만든다(§4.4). 그 생성 알고리즘은 아직 안 봤다(§10).

### 9.4 순서 제안

1. **하 17종을 먼저** — 오버레이 파이프라인(캡처 → 레이어드 창 → 진행도 상수버퍼)만
   서면 17종이 한 번에 붙는다. 그중 0 Fade 하나만 돌아도 전환 기능은 "있는" 상태가 된다.
2. **밉맵 2종(21, 25)** — `MTLBlitCommandEncoder.generateMipmaps` 한 줄이다.
3. **26 Boilover** — 텍스처 2장은 이미 동봉돼 있다
   (`Sources/WapleRender/Resources/WEAssets/materials/util/`). wrap 샘플러만 추가.
4. **16 Bricks** — 인스턴스 드로우로.
5. **23 Glass shatter** — 파편 격자 생성기부터. 가장 나중.

**능력 플래그를 하드코딩하지 마라.** WE 는 효과 id ↔ 리소스 표를 갖고 있지 않고,
컴파일된 셰이더를 리플렉션해서 밉맵·정점메시·외부텍스처 세 비트를 세운다(§4.4).
Metal 도 `MTLRenderPipelineReflection` 으로 같은 것을 할 수 있다 — 그러면 위 표가
코드에 들어갈 필요가 없고, 표가 낡을 일도 없다.

## 10. 아직 안 본 것

- `bin/playliststate.bin`(`0x14006eef0–0x140070688`)의 정확한 레코드 구조 — 이 설치본에
  파일이 없어 실물 대조를 못 했다. `playliststatetime.bin` 과 같은 직렬화기를 쓴다.
- `logon` 모드가 무엇을 계기로 전환하는지 — §3.1 에서 보듯 파서는 `delay` 를 0 으로
  덮지 않고, 타이머 틱은 mode 0 에서도 돈다. "로그인 시" 트리거 자체는 이 함수들 밖에 있다.
- 설정 플래그 `+0x3c` **bit2(값 4)** 의 의미. 이 파서는 세우지 않는다.
- 동영상 종료 → 전환 경로(`videosequence` 가 타이머를 보류시킨 뒤 실제로 넘기는 쪽).
  **[해소 2026-08-21]** §6.6 이 세 단계(`PostMessageW 0x40A` → 점프테이블 `0x14002dc43` →
  전진 관문 `0x140067720`)를 전부 이었다. 항목은 툼스톤으로 남긴다.
- `preset` 항목이 전환 시점에 어떻게 적용되는지.
- **[2026-08-21 신규]** 타이머 틱 함수 `0x140076be0` 의 **세 번째 인자**(`0x140076bff  movzx r15d, r8b`).
  `daytime`/`dayofweek` 모드에서 이 값이 참일 때만 전진한다(`0x140076d92`). 호출부를 못 찾았다 —
  "분이 바뀌었다" 같은 시각 이벤트로 보이지만 확인하지 못했다.
- **[2026-08-21 신규]** 셔플백 리필 시 "현재 항목 제거" 가 비교하는 것은 `file` 하나가 아니라
  **`(file, preset)` 짝**이다(`0x1400680a0  lea r8, [rsi+0x28]` — 항목 구조체 `+0x00` 과 `+0x28`
  을 함께 넘긴다). 같은 파일을 다른 프리셋으로 두 번 넣은 재생목록에서 어떻게 되는지는
  코퍼스가 없어 확인하지 못했다(설치본 재생목록 도달 0건 — §3.3).
