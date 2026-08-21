# `.pkg` 컨테이너와 `project.json` 매니페스트 — 로더 전표 + 동봉 전수 대조

**조사일 2026-08-21 · WE 2.8.42 `wallpaper64.exe` (md5 `438cb215f20a8f6c38f57fbc3d9da588`, imagebase `0x140000000`)**
**대상: 설치본 `/home/user/Waple-wallpaper-source/wallpaper_engine/` + 동봉 자산 `Sources/WapleRender/Resources/WEAssets/` — 9,078 파일 1.20 GB 전수**

## 0. 결론

| 항목 | 판정 |
| --- | --- |
| 이 환경의 실물 `.pkg` | **0개.** 두 루트 9,078 파일 전건에서 `PKGV` 매직 **0건**. `find -iname '*.pkg'` 도 0건 |
| 그래서 무엇으로 확정했나 | **로더 디스어셈**(`0x140276700`)이 1차 근거. 합성 `.pkg` 왕복 + 실물 페이로드 LZ4 해제로 교차검증 |
| 컨테이너 압축 | **없다.** TOC·페이로드 모두 무압축. `LZ4_decompress_safe`(`0x14014c160`) 호출자는 전 바이너리에 **2곳**(`0x1400ce760`·`0x14015c8d0`)이고 **둘 다 `.tex` 경로**다 |
| LZ4 실측 | 순수 파이썬 LZ4 블록 디코더로 **해제 성공**. `effectpreview.tex` mip0 47,371 → 262,144 B, 합성 pkg 슬라이스에서 뽑은 사본과 **바이트 동일** |
| 매직 검증 | WE 는 `"PKGV"` 를 **비교하지 않는다** — 바이너리에 그 4바이트 시퀀스가 **0건**이다. `atoi(magic+4) > 24` 만 거부(`0x140276964`) |
| 엔트리 키 정규화 | 바이트별 C `tolower` **뿐**(`0x140276ac4`·`0x140274003`). 역슬래시→슬래시 변환 **없음** |
| `scene.pkg` vs `scene.json` | 우선순위 다툼이 **없다.** `project.json` 의 `file` 이 단독 결정자고, `.pkg` 는 그 파일이 **디스크에 없을 때만** 시도하는 폴백이다(`0x14011e330`–`0x14011e3f9`) |
| `project.json` `type` | **읽히지 않는다.** `file`(또는 `dependency`) 확장자로 유도해 `type` 을 **덮어쓴다**(`0x14011e520` → `0x14011e300`) |
| `contentrating`/`tags`/`visibility`/`approved` | `wallpaper64.exe` 에 문자열조차 **없다** — 런타임이 안 읽는다(`wallpaperui.exe` 전용) |
| Waple 갭 | 마운트 선택자 1건(고), 타입 유도표 1건(중), 정규화·게이트 3건(저) — §7 |

---

## 1. 실물 도달 실측

### 1.1 `.pkg` 파일 (과제 6항)

| 루트 | 파일 | 바이트 | `.pkg` 확장자 | `PKGV` 매직 보유 |
| --- | --- | --- | --- | --- |
| `wallpaper_engine/`(설치본 전체) | 6,138 | 1,122,265,206 | **0** | **0** |
| `WEAssets/`(동봉 사본) | 2,940 | 79,515,997 | **0** | **0** |
| 합계 | 9,078 | 1,201,781,203 | **0** | **0** |

확장자만 본 게 아니라 **모든 파일의 첫 4 KiB 에서 `PKGV` 를 찾았다** — 다른 확장자로 위장한
패키지도 없다. 시스템 전역 `find / -iname '*.pkg'` 는 Go 툴체인 테스트 픽스처 4건뿐이다.

**따라서 "동봉 `.pkg` 평균 엔트리 수"·"총 바이트" 는 이 환경에서 산출할 수 없다 — 표본이 0이다.**

과거 세션이 **워크샵 코퍼스**(이 환경에 없음)에서 뽑아 `spec/` 에 굳혀 둔 수치는 아래가 전부다.
재현 불가이므로 출처를 명시해 인용만 한다.

| 값 | 수 | 출처 |
| --- | --- | --- |
| 파싱한 `scene.pkg` | 162 | `spec/corpus/inventory.json` `corpus.pkgParsed` |
| 파스 오류 | 0 | 같은 파일 `corpus.pkgParseErrors` |
| 엔트리(알려진 확장자만) | 19,781 | `corpus.entryExtensions` 합 → **pkg 당 122.1** (파생치, 확장자 없는 엔트리 미포함) |
| 매직 분포 | `PKGV0002·0007·0008·0011·0012·0016`~`0024` 14종, 최빈 `0023`×50 | `spec/formats/pkg.json` `format.pkg.magicDistribution` |

### 1.2 `project.json` 361건 전수 (과제 4·5항의 실측 기반)

| 최상위 키 | 도수 | 엔진이 읽나 |
| --- | --- | --- |
| `file` | 361 | **읽는다**(§5) |
| `title` | 359 | 읽는다 — 없으면 폴더명으로 채움 |
| `general` | 341 | 읽는다(`general.properties`) |
| `type` | 288 | **안 읽는다** — 유도해서 덮어씀 |
| `version` | 175 | 이 만큼도 안 읽는다(§5.5) |
| `official` | 19 | 문자열 부재 |
| `preview` | 19 | 읽는다(절대경로화) |
| `authorsteamid` | 12 | 문자열 부재 |
| `visibility` | 10 | `wallpaper64.exe` 문자열 부재 |
| `timestamp` | 4 | 문자열 부재 |
| `description` | 3 | 기록 전용(§5.5) |
| `templateoptions` | 3 | 문자열 부재 |
| `approved` | 2 | 문자열 부재 |
| `contentrating` | 2 | `wallpaper64.exe` 문자열 부재 |
| `tags` | 2 | `wallpaper64.exe` 문자열 부재 |

`type` 원문: `scene` 286 · **키 없음 73** · `web` 2 (설치본은 전건 소문자다 — 대소문자 혼용은 워크샵 쪽 문제).
`file` 확장자: `.json` 358 · `.html` 2 · `.exe` 1. `file` 값: `scene.json` 353, 그 외 `ricepod.json`
`fantasticcar.json` `techno.json` `audiophile.json` `gifscene.json` `index.html` `sheep.exe` 각 1.

**설치본 361건 중 `file` 이 `.pkg` 인 것은 0건이고, `file` 이 디스크에 없어 `.pkg` 폴백이 도는
경우도 0건이며, `file` 과 같은 stem 의 `.pkg` 가 병존하는 경우도 0건이다.**
즉 §6 의 우선순위 규칙은 이 코퍼스로는 **분기 자체가 안 도는** 규칙이고, 코드로만 확정된다.

---

## 2. 컨테이너 레이아웃

### 2.1 바이트 오프셋 표

문자열은 전부 **i32 길이 접두 + 널 종단 없음**이다. 정수는 전부 **리틀엔디언 i32**(`std::istream::read`
로 메모리에 그대로 얹는다 — `0x14004aa50`, 엔디언 변환 없음). **정렬·패딩 없음.**

| 오프셋 | 필드 | 크기 | 읽는 VA | 비고 |
| --- | --- | --- | --- | --- |
| 0 | `magicLen` | i32 | `0x140060746` | `> 8` 이면 매직을 **빈 문자열로 만들고 바이트를 안 먹는다**(`0x140060752`) |
| 4 | `magic` | `magicLen` B | `0x1400607fd` | 실물은 `"PKGV%04d"` 8B. **엔진은 접두를 비교하지 않는다** |
| 4+`magicLen` | `entryCount` | i32 | `0x14027698d` | 부호 있음. `<= 0` 이면 엔트리 표를 건너뛰고 **성공 반환** |
| — | 엔트리 레코드 × `entryCount` | | | 아래 |
| = TOC 끝 | `dataBase` | — | `0x140276b4d`(tellg) | 여기부터 페이로드 |

엔트리 레코드(연속, 패딩 없음):

| 상대 오프셋 | 필드 | 크기 | 읽는 VA | 비고 |
| --- | --- | --- | --- | --- |
| +0 | `nameLen` | i32 | `0x1402769b0` | `> 0x800` 이면 이름을 **빈 문자열로 만들고 바이트를 안 먹는다**(`0x1402769bb`) |
| +4 | `name` | `nameLen` B | `0x140276a4d` | UTF-8. 적재 즉시 **바이트별 `tolower`**(`0x140276ac0`–`0x140276ad6`) |
| +4+`nameLen` | `offset` | i32 | `0x140276a70` | **`dataBase` 상대**. 적재 후 전 엔트리에 `dataBase` 가산(`0x140276b63`) |
| +8+`nameLen` | `size` | i32 | `0x140276a82` | 바이트 수 |

페이로드는 `dataBase + offset` 부터 `size` 바이트. **엔트리별 헤더도, 압축도, 정렬도 없다.**

### 2.2 버전 게이트

```
0x140276941  call 0x140060720          ; ReadLengthPrefixedString(stream, &magic, maxLen=8)
0x140276946  cmp  qword [rbp+0xf], 4   ; magic.size() > 4 일 때만 버전을 본다
0x14027694b  jbe  0x140276980          ;   4 이하면 **버전 검사를 통째로 건너뛴다**
0x14027695f  call 0x1402c82c0          ; atoi(magic.c_str() + 4)
0x140276964  cmp  eax, 0x18
0x140276967  jle  0x140276980          ; version <= 24 만 통과 (부호 있는 비교)
0x14027696c  lea  rcx, [rip+0x21b975]  ; 0x1404922e8 "Cannot open %s, version %i not supported.\n"
```

**`"PKGV"` 접두 비교가 없다.** 바이너리 전역에서 ASCII `PKGV` 는 **0건**이다(대비: `TEXV0005`
`MDLV0023` 은 각각 `0x14048b910`·`0x140492318` 에 리터럴로 있고 `memcmp` 로 비교된다).
즉 WE 가 보는 건 **"5~8바이트 문자열이고, 4번째 글자부터가 24 이하 정수로 읽힌다"** 뿐이다.
`atoi` 규약상 숫자가 아니면 0 이므로 `"XXXX????"` 도 통과한다.

### 2.3 상한과 방어 (엔진이 실제로 두는 것)

| 대상 | 상한 | VA | 위반 시 |
| --- | --- | --- | --- |
| `magicLen` | ≤ 8 | `0x140060752` | 빈 문자열 반환, **스트림 미전진** → 이후 파스 전체가 밀린다 |
| 버전 | ≤ 24 | `0x140276964` | 에러 로그 + 반환 2 |
| `nameLen` | ≤ 0x800 (2048) | `0x1402769bb` | 빈 이름, **스트림 미전진** → 이후 파스 전체가 밀린다 |
| `entryCount` | **상한 없음** | — | 음수·0 은 빈 패키지로 성공 처리 |
| `offset`/`size` | **검증 없음** | — | 그대로 `seekg`/길이 상한에 실림 |

두 "미전진" 경로는 방어라기보다 **버그에 가깝다**(스트림을 되돌리지도, 실패로 끊지도 않는다).
Waple 은 두 경우 모두 `malformed` 로 끊으므로 **더 안전한 쪽**이고, 이 차이는 정상 파일에서
관측되지 않는다.

### 2.4 반환 코드

| 값 | 뜻 | VA |
| --- | --- | --- |
| 0 | 성공 | `0x140276b6e` |
| 1 | 파일을 못 열었다 (`"VFS missing file: %s\n"` `0x1404922d0`) | `0x140276925` |
| 2 | 버전 미지원 | `0x14027672d` 초기값, `0x14027697b` 로 탈출 |

호출측(`0x14010e18f`–`0x14010e1cf`)은 1 → UI 에러 코드 **5**, 2 → 코드 **4** 로 옮긴다.

---

## 3. 압축 — 실측

### 3.1 코드 근거

`LZ4_decompress_safe` 는 `0x14014c160` 이다(`docs/re/tex-format.md` §7 에서 확정). 전 바이너리
`.pdata` 조각 단위로 호출자를 세면 **2곳**뿐이다.

| 호출 지점 | 소속 함수 | 무엇 |
| --- | --- | --- |
| `0x14015dcf8` | `0x14015c8d0` | `TEXB` mip 페이로드 리더 |
| `0x1400ce7bc` | `0x1400ce760` | 텍스처 업로드 워커(같은 mip 바이트) |

**패키지 경로(`0x140276700`·`0x140273f50`)에는 없다.** zlib/Wuffs 호출도 없다. 컨테이너는
**통짜도 아니고 엔트리별도 아니라, 아예 압축이 아니다.**

### 3.2 실행한 검증

`lz4` 파이썬 모듈이 없어 **순수 파이썬 LZ4 블록 디코더**를 짜서 돌렸다(프레임 헤더 없음 —
`.tex` 는 블록 포맷이고 해제 크기를 컨테이너가 별도 필드로 준다).

```
[통제군] 디스크 .tex mip0 LZ4 해제: 47371 -> 262144 bytes  OK
합성 pkg: 48126 bytes, 엔트리 3
파스: PKGV0023 version= 23 count= 3 dataBase= 137
  scene.json                                    off=137   size=282    bytes-identical=True
  effects/blendgradient/preview/materials/effectpreview.tex
                                                off=419   size=47458  bytes-identical=True
  shaders/empty.frag                            off=47877 size=249    bytes-identical=True
round-trip 전건 일치: True
[검증] pkg 슬라이스에서 뽑은 .tex mip0 LZ4 해제: 47371 -> 262144 bytes, 디스크본과 동일=True
```

곧 **pkg 슬라이스를 그대로 `.tex` 리더에 먹여 LZ4 해제가 성공했다** — 컨테이너가 페이로드를
건드리지 않는다는 뜻이다. 버전 게이트도 같은 스크립트로 실측했다.

```
  magic PKGV0024       -> OK version=24
  magic PKGV0025       -> REJECT (version 25 not supported (>24))
  magic PKGV0100       -> REJECT (version 100 not supported (>24))
  magic PKGV0001       -> OK version=1
  magic XXXX0023       -> OK version=23        ← 접두를 안 본다는 증거
  magic PKGV           -> OK (버전 검사 자체를 건너뜀)
  magic PKGV000000023  -> 길이 13 > 8 → 매직 소실 + 스트림 미전진 → EOF
```

### 3.3 코퍼스 근거 (과거 측정, 재현 불가)

`spec/corpus/workshop-shaders.json` 은 워크샵 `scene.pkg` 162개에서 뽑은 `.frag`/`.vert`
**3,378건**을 `decodeFailures: 0` 으로 기록한다. GLSL 원문이 그대로 실려 있다 — TOC 슬라이스를
평문 텍스트로 읽어 성공했다는 뜻이고, **엔트리 무압축의 실물 증거**다.

---

## 4. 로더 전표 — 필드마다 VA

### 4.1 컨테이너 적재 `0x140276700`

`(this, std::string utf8Path)`. 진입 즉시 `0x140078a40(this+0x38)`(엔트리 맵 비우기)을 부르고,
경로를 `MultiByteToWideChar(CP_UTF8, …)`(`0x140426678`, 2패스)로 `std::wstring` 화해
`this+0x18` 에 넣은 뒤 `0x140277820(this+0x78, path, 0x20)` 으로 파일을 연다
(`mode |= 1` → `ios::in|ios::binary`, `0x140277833`).

이 함수 자체는 vtable 슬롯이 아니라 **직접 호출**된다(§4.3 2번). 객체는 §4.2 의 VFS 와
같은 클래스이고 ctor 는 `0x140273d70`, vtable 은 `0x140492238`(`0x140273d88` 에서 심는다).
레이아웃:

| 오프셋 | 멤버 | 근거 |
| --- | --- | --- |
| +0x18 | `std::wstring` `.pkg` 절대경로 | `0x140276872` 대입, `0x140274130` 재사용 |
| +0x38 | `std::unordered_map` `_Max_bucket_size` (float 1.0f) | `0x140273e06` |
| +0x40 | 같은 맵의 리스트 센티넬 | `0x140273de7`(`operator new(0x38)` = 노드 크기) |
| +0x48 | 맵 원소 수 | `0x140273dce` |
| +0x50 / +0x68 | 버킷 벡터 / 마스크 | `0x14027406c` / `0x140274068` |
| +0x78 | `std::ifstream` | `0x1402768f7` |
| +0x108 | 열림 여부 | `0x14027690d` |

엔트리 노드(맵 값): 키 `std::string` 이 `+0x10`(크기 `+0x20`, 용량 `+0x28`), **`offset` 이
`+0x30`, `size` 가 `+0x34`** (`0x140276aef`·`0x140276af5`).

TOC 를 다 읽은 뒤:

```
0x140276b46  lea rdx, [rbp-0x41] ; mov rcx, rdi ; call 0x14004a840   ; tellg()  (seekoff(0,cur,in))
0x140276b56  mov edx, [rax+8] ; add edx, [rax]                       ; 절대 위치
0x140276b63  add dword ptr [rax+0x30], edx                           ; 전 엔트리 offset += dataBase
```

### 4.2 엔트리 조회 + 열기 `0x140273f50` (VFS `openFile`, vtable `0x140492238`+0x08)

1. 요청 이름을 복사해 **바이트별 `tolower`**(`0x140274000`–`0x140274015`, `0x1402bfb1c` = CRT `tolower`
   — C 로케일에서 `'A'..'Z'` 만 `+0x20`, `0x80` 이상 바이트는 손대지 않음).
2. **FNV-1a 64비트** 해시: `h = 0xcbf29ce484222325`, 바이트마다 `h ^= b; h *= 0x100000001b3`
   (`0x14027402b`·`0x140274040`·`0x14027405b`).
3. `h & mask`(`0x140274068`)로 버킷을 잡고 길이 비교 + `memcmp`(`0x1402740b8`)로 확정.
4. **찾았고 `size > 0`** 이면(`0x140274124`·`0x14027412a`):
   ```
   0x14027413d  call 0x140277820        ; ifstream::open(this+0x18, ios::in|binary)
   0x140274142  movsxd rdx, [rbx+0x30]  ; entry.offset (이미 dataBase 가산됨)
   0x14027414c  call 0x14004a920        ; seekg(offset, beg)      ; dir 0=beg, 2=end
   0x140274151  mov eax, [rbx+0x34]
   0x140274154  mov [r12+0x110], eax    ; 스트림에 길이 상한을 심는다
   ```
   **해제도, 변환도 없다.**
5. **못 찾았거나 `size <= 0`** 이면 `0x140274161` 로 빠져 **마운트된 디렉터리 루트에서 실제 파일**을
   연다(`0x140274425` `filebuf::open`). 즉 VFS 는 *패키지 → 디스크* **합집합**이다.

> **`size == 0` 은 "없음"과 같다.** 0바이트 엔트리는 조회에서 탈락하고 디스크 폴백으로 넘어간다.

### 4.3 마운트 디스패처 `0x14010df40`

`project.json` 의 `file` 을 절대경로화한 문자열(`[rbp+0xb8]`)의 **확장자만** 보고 갈린다.
`0x140118880` 은 "이 확장자로 끝나는가" 술어다.

| 순서 | 조건 | 동작 | VA |
| --- | --- | --- | --- |
| 1 | `.gif` 로 끝남 | 플래그 `0x20` 세우고 GIF 씬 경로로 이탈 | `0x14010e0ee`–`0x14010e12c` |
| 2 | `.pkg` 로 끝남 | `0x140276700`(패키지 적재) | `0x14010e14d`–`0x14010e18a` |
| 3 | 그 외 | `0x1402764d0`(**부모 폴더**를 루트로 마운트) | `0x14010e1d1`–`0x14010e20c` |

이후 공통으로 `filename()` 을 씬 문서 이름으로 쓴다(`0x14010e231`–`0x14010e253`).
**어느 분기도 다른 분기를 되짚지 않는다** — 2번에서 실패하면 에러 코드 5 로 끝난다.

---

## 5. `project.json` 매니페스트

### 5.1 리더 `0x14011d7d0`

`(out ProjectRecord*, std::filesystem::path)`. `ProjectRecord`: `+0x01` 유효 플래그,
`+0x04` 타입 enum, `+0x08` 본 JSON, `+0x30` 프리셋 원본 JSON.
JSON 값의 타입 태그는 jsoncpp 규약 그대로다 — `[value+8]` 하위 바이트가
`0`=null `1`=int `2`=uint `3`=real **`4`=string** `5`=bool `6`=array **`7`=object**
(`0x14011d9f1` `cmp byte [rax+8], 4`, `0x14010a703` `cmp byte [rax+8], 7`).

| 키 | 기대 타입 | 읽는 VA | 동작 / 기본값 |
| --- | --- | --- | --- |
| `file` | string(4) | `0x14011d9e1`·`0x14011deb4` | 프로젝트 폴더 기준 **절대경로로 정규화해 다시 써 넣는다**. 없으면 프리셋 병합 경로로 |
| `preview` | string(4) | `0x14011df1d`·`0x14011dfe2` | 절대경로화해 다시 씀. 문자열이 아니면 **null 로 덮어씀**(`0x14011e027`) |
| `title` | string(4) | `0x14011e08a`·`0x14011e0f7` | 문자열이 아니면 **폴더명**으로 채워 씀 |
| `type` | — | — | **입력으로 안 쓴다.** 유도 결과를 캐논 문자열로 **덮어쓴다**(`0x14011e300`) |
| `general` | object(7) | `0x14010a6f7` | `general.properties`(object)가 wproperties 스키마 |
| `dependency` | string(4) | `0x14011e894` | 있으면 그 경로의 확장자로 타입을 유도하고 `.pkg` 폴백을 **막는다** |
| `preset` | — | `0x14011d8e4` | 프리셋 체인 해석 |
| `project` | string(4) | `0x14011d61c` | 경로 정규화 대상(`0x14011d3b0`) |
| `workshopid` | — | `0x14010ab00` | **읽지 않고 쓴다** — §5.4 |

### 5.2 타입 enum과 캐논 문자열 (`0x14011e2aa`–`0x14011e2f9`)

| 값 | 캐논 문자열 | VA |
| --- | --- | --- |
| 0 | `Unknown` | `0x14011e2e9` |
| 1 | `Scene` | `0x14011e2e0` |
| 2 | `Web` | `0x14011e2d7` |
| 3 | `Application` | `0x14011e2ce` |
| 4 | `Video` | `0x14011e2c5` |
| 5 | (매핑 없음 → `Unknown` 으로 출력) | `0x14011e864` |

`+0x01` 유효 플래그 = `type != 0`(`0x14011e325`–`0x14011e32d`).

### 5.3 확장자 → 타입 분류기 `0x14011e520`

입력 문자열을 `std::filesystem::path` 로 만들어 **확장자를 소문자로** 뽑은 뒤(`0x140053f80`),
`.rdata` 의 확장자 테이블들과 순서대로 `memcmp` 한다. 테이블은 `[imagebase + i*8 + RVA]` 로 색인된다.

| 순서 | 테이블 RVA | 개수 | 확장자 | 결과 | 매치 VA |
| --- | --- | --- | --- | --- | --- |
| 1 | `0x483850` | 3 | `.json` `.pkg` `.gif` | **1 Scene** | `0x14011e7a5` |
| 2 | `0x4837d0` | 1 | `.html` | **2 Web** | `0x14011e79e` |
| 3 | `0x4837c0` | 1 | `.exe` | **3 Application** | `0x14011e7ac` |
| 4 | `0x483810` | 7 | `.mp4` `.wmv` `.avi` `.m4v` `.mov` `.webm` `.mkv` | **4 Video** | `0x14011e7b3` |
| 5 | — | — | 문자열이 `http://`·`https://` 로 시작(`0x140018980`) | **2 Web** | `0x14011e79e` |
| 6 | `0x4837e0` | 5 | `.png` `.bmp` `.jpeg` `.jpg` `.jfif` | **5** | `0x14011e864` |
| 7 | — | — | 그 외 | **0 Unknown** | `0x14011e800` |

분류기에 들어가는 문자열은 **`dependency` 가 문자열이면 그것, 아니면 `file` 의 절대경로**다
(`0x14011e14b`–`0x14011e159` vs `0x14011e1f7`–`0x14011e242`). `type` 값은 어느 쪽에도 안 들어간다.

> `.htm` 은 표에 **없다** — WE 는 `.html` 만 Web 으로 본다.

### 5.4 `workshopid` 는 경로에서 나온다

`0x14010a9a0`–`0x14010ab27` 이 프로젝트 폴더 경로를 뒤에서부터 컴포넌트 단위로 훑으며
`strtoull(comp, NULL, 10)`(`0x1402c0e80`, `r8d = 0xa`)을 두 번 부른다.

```
0x14010aabc  call 0x1402c0e80          ; strtoull(<상위 컴포넌트>, 0, 10)
0x14010aac1  cmp  rax, 0x69758         ; == 431960  (Wallpaper Engine Steam AppID)
0x14010aac7  jne  0x14010ab36          ;   아니면 workshopid 를 아예 안 쓴다
0x14010aadf  call 0x1402c0e80          ; strtoull(<그 아래 컴포넌트>, 0, 10)
0x14010ab00  lea  rdx, [rip+0x369239]  ; 0x140473d40 "workshopid"
0x14010ab27  call 0x140085610          ; json["workshopid"] = <그 수>
```

즉 `…/steamapps/workshop/content/431960/<id>/` 구조일 때만 `<id>` 를 채우고,
그 밖의 폴더(로컬 프로젝트·설치본 기본 배경)에서는 `workshopid` 를 **건드리지 않는다**.
`project.json` 에 적힌 `workshopid` 는 입력으로 쓰이지 않는다.

### 5.5 읽히지 않는 키

`contentrating` · `tags` · `visibility` · `approved` · `ratingsex` 는 **`wallpaper64.exe` 안에
문자열 자체가 없다**(전건 grep 0). `wallpaperui.exe` 에만 있다 — 저작·업로드 UI 전용이다.
`official` · `authorsteamid` · `timestamp` · `templateoptions` 도 같다.

`0x140056220`–`0x14005675C` 의 기록 함수가 내보내는 `key`/`file`/`status`/`name`/`description`/
`version`/`options` 중 **`status`·`description` 은 전 바이너리 xref 가 이 기록 함수 1건뿐이다.**
즉 `wallpaper64.exe` 안에 **대응하는 읽기 함수가 없다.**
(같은 `key`/`options` 문자열을 쓰는 `0x1401a4db0` 은 wproperty 스키마 리더지 이 매니페스트가 아니다 —
그쪽은 `user`/`value`/`condition`/`script`/`animation` 을 같이 읽는다.)
이 매니페스트는 리스트 노드마다 가상 호출 `+0x30`(name)·`+0x38`(description)·`+0x40`(version)·
`+0x50`(options)로 채워지는 **런타임 산출물**이고, 호출자는 `0x14001eae0`·`0x140021e50` 다.
**`.pkg` 안에 이런 매니페스트가 들어 있다는 증거는 이 바이너리에서 찾지 못했다. `[미해결]`**

---

## 6. `scene.pkg` vs 평문 `scene.json` — 누가 이기나

**우선순위 다툼이 성립하지 않는다.** 결정자는 `project.json` 의 `file` 하나다.
`.pkg` 는 그 파일이 **없을 때만** 도는 폴백이고, 그 폴백에도 게이트가 셋 붙는다
(`0x14011e330`–`0x14011e3f9`):

```
cmp  dword [rdi+4], 1        ; ① type 유도 결과가 Scene 일 때만
jne  skip
call 0x14011e880             ; ② json 에 string 타입 `dependency` 가 있으면 → skip
test al, al ; jne skip
lea  rcx, [rbp-0x28]
call 0x140018f30             ; ③ is_regular_file(<file 절대경로>) 가 true 면 → skip
test al, al ; jne skip
...  replace_extension("pkg")            ; 0x14011e368 "pkg" (점 없음) + 0x140060d90
call 0x140018f30             ; ④ 바꾼 경로가 실제 파일이면
je   skip
...  json["file"] = <그 .pkg 절대경로>    ; 0x14011e3f2
```

| 디스크 상태 (`file` = `"scene.json"`) | WE 가 여는 것 |
| --- | --- |
| `scene.json` 만 | `scene.json` (폴더 마운트) |
| `scene.json` + `scene.pkg` 둘 다 | **`scene.json`** — ③에서 빠진다 |
| `scene.pkg` 만 | `scene.pkg` (④에서 재작성) |
| 둘 다 없음 | 실패 |

| 디스크 상태 (`file` = `"scene.pkg"`) | WE 가 여는 것 |
| --- | --- |
| `scene.pkg` 있음 | `scene.pkg` — `.json` 을 **찾아보지도 않는다** |
| `scene.pkg` 없음, `scene.json` 있음 | ③에서 통과하지만 ④가 `replace_extension("pkg")` → 같은 `scene.pkg` → 없음 → 실패 |

`file` 이름은 `scene.*` 일 필요가 없다. 설치본 실측(§1.2)이 `ricepod.json` `techno.json`
`audiophile.json` `fantasticcar.json` `gifscene.json` 5건을 보여 준다 — 폴백도 그 stem 을 따라간다
(`techno.json` 이 없으면 `techno.pkg` 를 본다).

`gifscene.pkg` 라는 이름은 **엔진 안 어디에도 없다.** `gifscene.json` 리터럴만
`0x140489300` 에 있고, GIF 분기는 §4.3 처럼 `.gif` **확장자**로 잡는다.

---

## 7. Waple 갭

### 7.1 [고] 마운트 대상을 `file` 이 아니라 파일 존재로 고른다

`Sources/WapleRender/SceneRendererResources.swift:166` `pkgURL(in:)` 은 `scene.pkg`/`gifscene.pkg`
**두 이름만** 하드코딩해 찾고, `Sources/WapleRender/SceneRenderer.swift:1207` 이 그게 있으면
무조건 패키지로 마운트한다. WE 규칙(§6)과 세 군데에서 갈린다.

| 상황 | WE | Waple | 결과 |
| --- | --- | --- | --- |
| `file:"scene.json"` + 잔존 `scene.pkg` | `scene.json` | **`scene.pkg`** | 다른 씬을 그린다 |
| `file:"techno.json"` 부재, `techno.pkg` 존재 | `techno.pkg` | `pkgURL` 이 nil → 폴더 마운트 → `techno.json` 없음 → `.noScene` | **적용 실패** |
| `file:"scene.pkg"` 부재, `scene.json` 존재 | 실패 | `scene.json` 으로 성공 | Waple 이 더 관대(무해) |

**착지 지점** — `SceneRenderer.swift:1207`. `pkgURL(in:)` 호출을 `project.fileName` 기반 결정으로
바꾼다: ① `fileName` 을 폴더 기준으로 풀어 존재하면 그 확장자로 분기(`.pkg` → 패키지, 그 외 → 폴더),
② 없으면 stem 을 `.pkg` 로 바꿔 재시도, ③ 그것도 없으면 현재의 `scene.pkg`/`gifscene.pkg` 탐색을
**하위 호환 폴백**으로 남긴다. `pkgURL(in:)` 은 ③ 전용으로 축소.
`Sources/WapleCore/WallpaperCompatibilityAnalyzer.swift:654` 의 같은 하드코딩도 같이 따라간다.

### 7.2 [중] 확장자 → 타입 유도표가 WE 표와 다르다

`Sources/WapleCore/ProjectJSONParser.swift:45`–`49` 의 폴백표는 `json`/`html`,`htm`/`exe`/
`VideoFormats.nativeExtensions`(= `mp4`,`m4v`,`mov` — `Sources/WapleCore/WallpaperType.swift:44`)뿐이다.

| WE(§5.3) | Waple | 차이 |
| --- | --- | --- |
| `.pkg` → Scene | 없음 | `type` 누락 + `file:"scene.pkg"` 인 항목이 `.preset` 으로 남는다 |
| `.gif` → Scene | 없음 | 같은 문제 |
| `.wmv .avi .webm .mkv` → Video | 없음 | 분류 자체가 안 된다(재생 불가와는 별개 축) |
| `.png .bmp .jpeg .jpg .jfif` → 5 | 없음 | WE 도 5를 `Unknown` 으로 출력하므로 영향 작음 |
| `http(s)://` → Web | 없음 | 원격 URL 배경 미분류 |
| `.html` 만 Web | `.htm` 도 Web | Waple 이 더 관대(무해) |
| **`type` 을 먼저 읽음** | `type` 우선 | **WE 는 `type` 을 아예 안 읽는다**(§5.1) |

마지막 줄이 본질이다. WE 는 `"type":"video"` + `"file":"scene.json"` 을 **Scene** 으로 본다.
Waple 은 video 로 본다.

**착지 지점** — `ProjectJSONParser.swift:34`–`49`. 확장자표에 `pkg`/`gif` → `.scene` 을 추가하는 게
최소 수선이다. `type` 무시까지 맞추는 건 회귀 위험이 크므로(워크샵 코퍼스가 `type` 에 의존해
분류돼 있다) **별도 판단**으로 남긴다. 분류 축과 재생 가능 축을 섞지 않도록, 타입 유도용
확장자 집합은 `VideoFormats.nativeExtensions` 와 **분리**해서 새로 두는 편이 낫다.

### 7.3 [저] 조회 키 정규화가 WE 보다 넓다

`Sources/WapleCore/ScenePackage.swift:111` `normalizedLookupKey` = 역슬래시→슬래시 + Swift
`.lowercased()`. WE 는 **바이트별 C `tolower`** 뿐이다(§4.2).

- 역슬래시 변환: WE 에 없다. Waple 은 정확 일치 뒤의 **폴백** 색인이라 추가 히트만 만든다(무해).
- 유니코드 소문자화: Swift 는 전체 케이스 폴딩이라 키릴·그리스 등도 접는다. WE 는 `A-Z` 만.
  Waple 쪽에서만 **서로 다른 두 엔트리가 같은 정규화 키로 충돌**할 수 있다(먼저 온 것이 이김 —
  `ScenePackage.swift:35`). 코퍼스에서 실제 충돌은 확인하지 못했다. `[미해결]`

**착지 지점** — 고칠 필요는 낮다. 고친다면 `ScenePackage.swift:112` 에서 `.lowercased()` 를
ASCII 한정 소문자화로 좁히면 WE 와 동치가 된다.

### 7.4 [저] 매직·버전 게이트 방향이 반대다

`ScenePackage.swift:71` 은 `^PKGV[0-9]{4}$` 를 **강제**하고 버전 상한은 **두지 않는다**.
WE 는 정반대다 — 접두를 안 보고 상한 24 를 건다(§2.2).

- Waple 이 더 엄격: `magicLen != 8` 이거나 접두가 다른 파일을 거부. WE 는 받는다.
- Waple 이 더 관대: `PKGV0025` 이상을 파싱 시도. WE 는 거부한다.

`ScenePackage.swift:63`–`70` 의 주석은 "값 범위 게이트를 두지 않는" 근거로 RePKG 를 든다.
그 결론(프레이밍이 버전 불변)은 **엔진 코드로도 맞다** — `0x140276980` 이후 버전 분기가 없다.
다만 주석이 함의하는 "WE 도 낙관적으로 받는다" 는 **틀렸다.**

**착지 지점** — `ScenePackage.swift:63`–`71`. 주석에 "WE 는 `atoi(magic+4) > 24` 를 거부한다
(`0x140276964`)"를 적고, 게이트 정책이 **의도적 이탈**임을 명시. 코드 변경은 불필요.

### 7.5 [저] `size == 0` 엔트리 처리

WE 는 `size <= 0` 엔트리를 **없는 것으로 보고 디스크 폴백**으로 넘긴다(`0x14027412a`).
Waple `ScenePackage.data(for:)`(`ScenePackage.swift:96`, 슬라이스는 `:102`)은 **빈 `Data`** 를
돌려주고, `SceneRendererResources.swift:191`(`probeAssetData`, `:190`)이 그걸 성공으로 보고 공유 에셋 폴백을
**건너뛴다**. 0바이트 엔트리를 가진 pkg 는 관측하지 못했다.

**착지 지점** — `ScenePackage.swift:96` `data(for:)` 가 `e.size == 0` 이면 `nil` 을 반환.

### 7.6 이미 맞는 것 (다시 손대지 말 것)

- 헤더 파스 순서·필드 크기·`blobBase` 규약: `ScenePackage.swift:41`–`93`(`blobBase` 는 `:87`)이 §2.1 과 **완전 일치**.
- 씬 문서 이름을 `project.json` `file` 로 정하는 것: `SceneDocument.swift:1418`. 맞다.
- 무압축 가정: 맞다.
- 언팩 폴더 마운트(`fromDirectory`): WE 의 §4.3 3번 분기와 같은 개념. 맞다.

---

## 8. 확정하지 못한 것

| 항목 | 상태 |
| --- | --- |
| 실물 `.pkg` 바이트 덤프 | **`[미해결]` — 이 환경에 표본이 0개다.** §2 는 코드 + 합성 왕복으로만 확정 |
| 동봉 `.pkg` 총 바이트 / 평균 엔트리 수 | **산출 불가**(표본 0). 워크샵 코퍼스 파생치 122.1 은 §1.1 참조 |
| `PKGV0002` 등 구버전의 프레이밍 차이 | 코드에 버전 분기가 **없으므로** 차이가 없다고 본다. 실물로 확인 못 함 |
| `key/file/status/name/description/version/options` 매니페스트의 읽기 함수 | **없다**(xref 1건). `.pkg` 와의 관계도 미확인 |
| 유니코드 정규화 키 충돌 실사례 | 코퍼스 부재로 미확인 |
| `resourceutil64.dll` 등 형제 바이너리의 pkg IO | **없다** — `PKGV`·`.pkg`·`scene.pkg` 전건 0 히트(`resourceutil64.dll` `resourcecompiler64.exe` `wallpaperservice64.exe` `webwallpaper64.exe`). `scenescript64.dll` 에 `.pkg` 1건이 있으나 패키지 IO 로 이어지는 코드는 확인하지 못했다 |

---

## 부록 A. 재현 절차

### A.1 실물 도달 실측 (§1)

```bash
python3 - <<'EOF'
import os
roots=["/home/user/Waple-wallpaper-source/wallpaper_engine",
       "/home/user/Waple/Sources/WapleRender/Resources/WEAssets"]
n=t=h=0
for r in roots:
    for dp,_,fn in os.walk(r):
        for f in fn:
            p=os.path.join(dp,f); n+=1; t+=os.path.getsize(p)
            if b'PKGV' in open(p,'rb').read(4096): h+=1
print(n,t,h)   # -> 9078 1201781203 0
EOF
```

`project.json` 361건 센서스는 같은 순회에서 `json.load` 후 최상위 키를 세면 재현된다(§1.2 표).

### A.2 컨테이너 왕복 + LZ4 해제 (§3.2)

스크래치의 `pkgref.py` 가 ① 엔진 순서 그대로의 리더(`read_pkg`), ② 순수 파이썬 LZ4 블록
디코더(`lz4_block_decompress`), ③ 합성 빌더(`build_pkg`)를 담는다. 핵심만 옮기면:

```python
def read_pkg(b):
    p = 0
    mlen, p = i32(b, p)
    magic = "" if mlen > 8 else b[p:p+mlen].decode(); p += 0 if mlen > 8 else mlen
    if len(magic) > 4 and atoi(magic[4:]) > 24: raise PkgError            # 0x140276964
    count, p = i32(b, p)
    out = []
    for _ in range(count):
        nlen, p = i32(b, p)
        name = "" if nlen > 0x800 else b[p:p+nlen].decode('utf-8')        # 0x1402769bb
        p += 0 if nlen > 0x800 else nlen
        off, p = i32(b, p); size, p = i32(b, p)
        out.append((ascii_lower(name), off, size))                        # 0x140276ac4
    base = p                                                              # 0x140276b4d
    return [(k, base + o, s) for (k, o, s) in out]                        # 0x140276b63
```

`ascii_lower` 는 `'A'..'Z'` 만 접는다 — Swift `.lowercased()` 를 쓰면 §7.3 의 차이가 섞인다.

### A.3 로더 디스어셈

```python
import sys; sys.path.insert(0, '<scratchpad>')
import vdis2
vdis2.dis(0x140276700, 0x140276bd2)   # 컨테이너 적재
vdis2.dis(0x140273f50, 0x14027458a)   # VFS openFile (조회 + seek)
vdis2.dis(0x14011d7d0, 0x14011e51c)   # project.json 리더
vdis2.dis(0x14011e520, 0x14011e872)   # 확장자 → 타입 분류기
```

`.rdata` 확장자 테이블은 포인터 배열이라 rip-상대 xref 로 안 잡힌다 — 절대 64비트 포인터를
직접 찾아야 한다:

```python
import struct
from wpe import pe, DATA
pat = struct.pack('<Q', 0x140478088)          # ".pkg" 문자열 VA
i = DATA.find(pat); print(hex(pe.off2va(i)))  # -> 0x140483858 (테이블 슬롯)
```

### A.4 LZ4 호출자 census (§3.1)

`.pdata` 조각마다 따로 디스어셈해야 한다 — `.text` 전체 선형 스윕은 데이터-인-코드에서
동기를 잃고 xref 를 통째로 놓친다(실제로 `.pkg` 문자열 xref 가 0건으로 나왔다).

```python
for (b, e, u) in FUNCS:
    for ins in md.disasm(DATA[pe.va2off(b):pe.va2off(b)+(e-b)], b):
        if ins.mnemonic == 'call' and ins.op_str == '0x14014c160':
            print(hex(ins.address), hex(primary(ins.address)[0]))
# -> 0x1400ce7bc 0x1400ce760 / 0x14015dcf8 0x14015c8d0   (둘 다 .tex)
```
