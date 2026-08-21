# 텍스트 레이어 · 폰트 렌더링 — 실물 대조

대상: `wallpaper64.exe` 2.8.42 (imagebase `0x140000000`), 설치본
`wallpaper_engine/{assets,bin,ui}`, 셰이더 평문 `assets/shaders/font.{vert,frag}`,
머티리얼 `assets/materials/fonts/*.json`, 폰트 자산 `assets/fonts/`,
에디터 타입 선언 `ui/dist/monaco/autocomplete/lib.sceneScript.d.ts`.
조사일 2026-08-21. 모든 주소는 VA.

이 문서가 답하는 것: 폰트 **자산 포맷**(실제로 무엇인가), **폰트 해석 체인**(systemfont 별칭·
폴백·FreeType 크기 규약), 텍스트 오브젝트 **JSON 키 전수 29종**(디스크립터 VA·멤버 오프셋·
타입·생성자 기본값·enum 값), **MSDF 대 비트맵**의 분기 조건과 파라미터, **레이아웃 규약**
(줄바꿈·자간·행간·정렬·양쪽정렬·말줄임·앵커), **런타임 텍스트 갱신**, 동봉·워크샵 **도달 실측**,
그리고 Waple 의 갭.

> **Waple 줄 번호 주의.** `Sources/WapleCore/SceneDocument.swift` 는 이 라운드에 **다른 레인이
> 병행 편집 중**이다. 이 문서의 `:NNNN` 은 **2026-08-21 측정 시점** 값이고, 어긋나면 같은 줄에
> 적힌 **함수명·심볼명**으로 찾아라.

> **선행 문서.** `docs/re/scene-object-model.md` §2.2 가 텍스트 키 일부(도달 있는 14개)를 이미
> 표로 갖고 있다. 이 문서는 그 표를 **29키 전수 + 기본값 + enum 값 + 소비처**로 확장하고,
> 거기서 "도달 0 등록 키" 로만 나열된 12개의 **실제 의미와 셰이더 배선**을 채운다.

---

## 0. 요약 — Waple 과 어긋나는 것

| # | 항목 | WE 실물 | Waple 현재 | 근거 |
|---|---|---|---|---|
| 1 | `pointsize` 기본값 | **32.0** (생성자 `0x140256bf2`) | ~~`?? 16`~~ → **`?? 32`** (2026-08-21 반영, `parseText`) | §4.3 · §4.5 |
| 2 | `pointsize` 상한 | **256 pt** 로 클램프(`0x1401b054a`) · 하한 1 pt(`0x1401b055b`) | `maxPointSize = 8192`(`TextRasterizer`) — **거부**이지 클램프가 아니다. 도달 0 이라 미반영(§10.1c·§11 G2, 근거는 그 상수 주석에 기록) | §3.4 |
| 3 | 300 DPI 환산 | `FT_Set_Char_Size(face, 0, (int)(pt*64), 300, 300)` — `0x1401ad1d4`/`0x1401ad1dc`/`0x1401ad1e5`/`0x1401ad1f2` | `weRenderDPI = 300`(`TextRasterizer`) — **일치**, 배율은 양쪽 다 **한 번만** 적용(이중 적용 아님) | §3.4 · §4.5⑤ |
| 4 | `spacing` 소비 | vec2 = **(자간 px, 행간 추가 px)** — `0x1401b1194` · `0x1401b0c04` | 파스만(`:2227`), 래스터에 **미적용** | §7.3 |
| 5 | `padding` 기본값 | **(32, 32)** (생성자 `0x140256bbf`/`0x140256bc9`) · 각 축 **512 클램프**(`0x140257e43`) | ~~`?? Vec2(0,0)`~~ → **`?? Vec2(32,32)`** (반영). 클램프는 소비처가 없어 미반영 | §4.3 · §4.5 · §8 |
| 6 | `outlinethickness` 기본값 | **4.0** (`0x140256c43`), 켜지면 **max(값, 1.0)** (`0x1402574e4`–`0x1402574fc`) | ~~`?? 0`~~ → **`?? 4`** (반영) | §4.3 · §4.5 · §6.2 |
| 7 | `msdf` · `blur` · `blursize` · `dropshadow` · `dropshadowsize` · `dropshadowopacity` · `dropshadowcolor` · `dropshadowoffset` | **8키 모두 등록·소비**(`+0x518` bit0/2/3, `+0x530`/`0x534`/`0x538`/`0x544`/`0x53c`) | **파스 자체가 없다** | §4.2 · §6 |
| 8 | outline 렌더 | MSDF 셰이더 `OUTLINE_ENABLED` 콤보로 실제 그린다 | **파스·보존만.** 종전 `SceneTextLayer.outline` 선언부 주석이 "래스터 소비는 outline 만 최소 구현(TextRasterizer 참조)" 라 적었으나 `TextRasterizer.swift` 에 `outline`/`stroke` 문자열이 **0건**이었다 — **2026-08-21 주석 정정 완료**(렌더는 여전히 미구현) | §6.4 · §11 G7 |
| 9 | `opaquebackground` 배경 박스 | `materials/fonts/fontbackground{,_depth}.json`(`flat` 셰이더)로 **별도 쿼드**를 그린다 — `0x140258326` | 파스만 | §8 |
| 10 | 워드랩 알고리즘 | **글리프(HarfBuzz 클러스터) 단위 그리디** — 폭 초과 시 그 자리에서 개행(`0x1401b1240`–`0x1401b1272`) | `CTTypesetterSuggestLineBreak`(UAX#14 **단어** 경계) — `TextRasterizer.swift:49` | §7.2 |
| 11 | 수직 정렬 기준 | 폰트 **ascender/descender 메트릭**(`0x1402576b9`–`0x1402577c4`) | 래스터 박스(ascent+descent+leading 의 ceil) — `TextRasterizer.swift:104` | §7.5 |
| 12 | 폴백 폰트 체인 | 고정 8단 테이블 `0x140484c40`(arial → seguiemj → arialuni → segoeui → **fonts/TwemojiMozilla.ttf** → seguisym → msyh → Malgun) | CoreText 캐스케이드에 위임(순서·이모지 페이스가 플랫폼 기본) | §3.3 |
| 13 | 콤보 조합 | `OUTLINE/BLUR/DROP_SHADOW` 3비트 → 머티리얼 8슬롯 캐시(`0x1401b3d97`) | 콤보 개념 없음 | §6.4 |
| 14 | `depthtest` enum 값 | `"enabled"` = **0**, `"disabled"` = **1**, 생성자 기본 **0(=enabled)** | `s != "disabled"` → 기본 true — **의미 일치** | §4.4 |
| 15 | `limit*` 게이트와 `max*` 값 | **서로 다른 멤버**(게이트 `+0x594` bit2/bit3 · 값 `+0x508` float / `+0x510` int)이고 주입기가 키마다 따로 돈다 — `limitrows:false, maxrows:9` 인 오브젝트의 멤버는 **9** 다 | ~~`maxRows: Int?` 하나로 접어 미체크 저작값 소실~~ → **`limitRows`/`maxRowsValue` 로 분리**(2026-08-21 AV). `maxWidth`/`maxRows` 는 계산 프로퍼티라 래스터 소비부 무수정 | §4.2 · §4.3 · §11 G16 |
| 16 | 커서 히트 상자 | `size` 멤버 `+0x2f0` = **잉크박스 + 2·clamp(padding,512)**(`0x140258900`), 상자 함수는 이미지와 동일(`0x14019dbb0`) | 배선 없음 — `buildPointerTargets` 가 텍스트를 `.geometryUnknown`(전건 배달)로 둔다. 등가값(`GPUText.rasterWidth`/`Height`)은 **이미 있다** | §8b · §11 G17 |

---

## 1. 조사 범위와 코퍼스 정의

**동봉 코퍼스**: 설치본 `wallpaper_engine/` 전체의 씬 문서 `scene.json` 184 + `gifscene.json` 2
= **186개**(`docs/re/scene-object-model.md` §1 과 동일 정의). 그중 텍스트 오브젝트를 가진 것은
**4씬 · 5오브젝트**(§10.1).

**리포 동봉 코퍼스**: 저장소 사본 `Sources/WapleRender/Resources/WEAssets/` 는 설치본의 **부분집합**
이라 씬 문서가 **172개**이고 텍스트는 **3씬 · 3오브젝트**(전건 preview)다 — §10.1b. 두 수치를
섞어 쓰지 마라. 이 문서에서 라벨 없는 "동봉" 은 **설치본 186** 을 뜻한다(§10.1).

**워크샵 코퍼스**: 이 머신에는 워크샵 트리가 없다(`scripts/spec/measure_corpus.py` 의 `WE_WORKSHOP`
기본값은 Windows 경로다). 대신 리포에 정본화되어 있는 `spec/corpus/scene-schema.json`
(162씬 스캔 결과)의 `text` 항목을 인용한다 — **1,597 텍스트 오브젝트 / 123씬**(§10.2).
이 문서의 워크샵 수치는 전부 그 파일에서 온 것이고 이번에 새로 측정한 것이 아니다.

**바이너리**: 텍스트·폰트 경로는 전부 `wallpaper64.exe` 안에 있다. `bin/resourceutil64.dll` ·
`bin/scenescript64.dll` 에는 FreeType/HarfBuzz 문자열이 **0건**이다(§12 배제한 가설 ①).

---

## 2. 폰트 자산 포맷 — "포맷이 없다" 가 답이다

### 2.1 `assets/fonts/` 는 순수 sfnt 파일 디렉터리다

설치본 `assets/fonts/` 는 **19개 파일 = 폰트 15 + 라이선스 텍스트 4** 뿐이다. 매직 헤더를
바이트로 뜯으면 전부 표준 sfnt(TrueType/OpenType)다 — WE 고유 헤더도, 컨테이너도, 사전 생성
아틀라스도 **없다**.

```
RobotoMono-Regular.ttf
0000  00 01 00 00 00 0e 00 80 00 03 00 60 47 53 55 42  |...........`GSUB|
0010  46 ec 25 df 00 01 50 8c 00 00 02 a8 4f 53 2f 32  |F.%...P.....OS/2|
      └ sfntVersion 0x00010000 · numTables 0x000e · searchRange/entrySel/rangeShift
        이후 16B 테이블 디렉터리 엔트리(tag, checksum, offset, length) 반복

Segment7Standard.otf
0000  4f 54 54 4f 00 0e 00 80 00 03 00 60 42 41 53 45  |OTTO.......`BASE|
      └ sfntVersion 'OTTO'(CFF 아웃라인)

TwemojiMozilla.ttf
0000  00 01 00 00 00 11 01 00 00 04 00 10 43 4f 4c 52  |............COLR|
0010  b8 ea f5 d2 00 0f b0 1c 00 01 a9 d8 43 50 41 4c  |............CPAL|
      └ COLR/CPAL = 레이어드 컬러 폰트(유일한 컬러 폰트)
```

| 파일 | sfnt | 테이블 수 | 크기 | 커닝 | 컬러 |
|---|---|---:|---:|---|---|
| `8bitOperatorPlus8-Regular.ttf` | `0x00010000` | 10 | 20,824 | — | — |
| `Alcubierre.otf` | `OTTO` | 11 | 38,512 | **`kern`** | — |
| `Atami-Regular.otf` | `OTTO` | 12 | 22,452 | `GPOS` | — |
| `Blackout 2 AM.ttf` | `0x00010000` | 20 | 28,308 | **`kern`** + `GPOS` | — |
| `CursedTimerUlil-Aznm.ttf` | `0x00010000` | 13 | 14,656 | — | — |
| `Lazer84.ttf` | `0x00010000` | 11 | 36,776 | — | — |
| `Monofur-PK7og.ttf` | `0x00010000` | 15 | 169,452 | — | — |
| `NotoSans-Regular.ttf` | `0x00010000` | 18 | 455,188 | `GPOS` | — |
| `RobotoMono-Regular.ttf` | `0x00010000` | 14 | 86,908 | — | — |
| `Segment7Standard.otf` | `OTTO` | 14 | 10,464 | `GPOS` | — |
| `TwemojiMozilla.ttf` | `0x00010000` | 17 | 1,158,828 | — | **COLR/CPAL** |
| `kust.ttf` | `0x00010000` | 16 | 124,732 | — | — |
| `opensticks.ttf` | `0x00010000` | 14 | 252,484 | — | — |
| `spincycle_3d_ot.otf` | `OTTO` | 12 | 44,640 | **`kern`** + `GPOS` | — |
| `summer85.ttf` | `0x00010000` | 11 | 63,548 | — | — |

라이선스 텍스트 4개: `RobotoMono-Regular License.txt` · `SIL Open Font License.txt` ·
`monof_tt-be11.txt`(monofur) · `twemojimozilla.txt`(CC-BY-4.0).

**커닝은 자산이 갖고 오고 엔진이 소비한다** — WE 는 HarfBuzz 로 셰이핑하므로 `GPOS` 의
`kern` 피처가 그대로 적용된다(§3.5). 레거시 `kern` 테이블만 있는 3종(`Alcubierre` ·
`Blackout 2 AM` · `spincycle_3d_ot`)이 실제로 커닝되는지는 HarfBuzz 설정에 달렸고 확인하지
않았다 **[미해결]**. 어느 쪽이든 **별도의 커닝 자산 파일은 없다**.

**아틀라스 참조 방식**: 자산에는 아틀라스가 없다. 아틀라스는 **런타임에만** 만들어지고
`__font_atlas_`/`__font_atlas_color_` 라는 **가상 텍스처 이름**으로 등록된다(§6.3).

저장소 사본 `Sources/WapleRender/Resources/WEAssets/fonts/` 는 설치본과 **바이트 동일**하다
(`diff -rq` 무출력).

### 2.2 `font` 값의 세 형태

`objects[].font` 는 문자열 하나이고 세 부류로 갈린다:

1. `"systemfont_<alias>"` — 8종 별칭(§3.2). Windows 폰트 디렉터리의 실제 파일로 치환된다.
2. `"fonts/RobotoMono-Regular.ttf"` 처럼 **자산 상대 경로**(동봉 프리셋이 쓰는 형태).
3. 그 외 임의 경로 — 워크샵 씬이 프로젝트 안의 폰트를 가리킬 때.

동봉 5건의 실제 값: `fonts/Segment7Standard.otf` ×2 · `systemfont_arial` ×1 ·
`fonts/Monofur-PK7og.ttf` ×1 · `fonts/RobotoMono-Regular.ttf` ×1.
워크샵은 **136개 distinct 값**(1,597건 전건 문자열).

---

## 3. 폰트 해석 체인

### 3.1 진입점

레이아웃 캐시 조회/생성은 **`0x1401b0410`–`0x1401b323b`** 하나의 거대 함수다(이하 `GetLaidOutText`).
텍스트 오브젝트가 `0x1402575c9` 에서 호출하고 결과 포인터를 `this+0x5a8` 에 보관한다.
인자는 `(폰트매니저 = scene+0x18a0, FontKey*, const char* utf8text, 0)`.

### 3.2 `systemfont_*` 별칭표 — `0x140484cc0`

`{ 표시명, 별칭, Windows 파일명 }` 3-포인터 × 8 엔트리, 스트라이드 `0x18`.
인덱스 판정은 텍스트 오브젝트 쪽 `0x1402571e6`–`0x14025742f` 이 문자열 비교로 하고,
파일명 조회는 `0x1401b05b2`–`0x1401b05bd`(`[0x140484cd0 + idx*0x18]`)가 한다.

| idx | 표시명 | `font` 값 | Windows 파일 |
|---:|---|---|---|
| 0 | Arial | `systemfont_arial` | `arial.ttf` |
| 1 | Calibri | `systemfont_calibri` | `calibri.ttf` |
| 2 | Cambria | `systemfont_cambria` | `cambria.ttc` |
| 3 | Comic Sans | `systemfont_comicsans` | `comic.ttf` |
| 4 | Consolas | `systemfont_consolas` | `consola.ttf` |
| 5 | Sans Serif | `systemfont_sansserif` | `micross.ttf` |
| 6 | Segoe | `systemfont_segoe` | `segoeui.ttf` |
| 7 | Verdana | `systemfont_verdana` | `verdana.ttf` |
| **8** | — | (그 외 전부) | 문자열을 **경로 그대로** 쓴다 (`0x1401b05ad` `cmp eax, 8; je`) |

디렉터리 접두는 `0x1401ab7c0`(Windows Fonts 경로)이 만들고 `0x140076f60` 이 결합한다.

### 3.3 폴백 체인 — 테이블 `0x140484c40`, 소비 `0x1401ad670`

`{ const char* 경로, int32 시스템폰트디렉터리여부 }` × **8 엔트리**, 스트라이드 `0x10`.
`0x1401ad79e` 가 `lea` 로 잡고 `[r14+0x18]`(0..7)로 순차 소비한다. 즉 **순서가 규약이다**.

| # | 경로 | sysdir | 무엇 |
|---:|---|---:|---|
| 0 | `arial.ttf` | 1 | 라틴 일반 |
| 1 | `seguiemj.ttf` | 1 | Segoe UI Emoji (COLR 컬러) |
| 2 | `arialuni.ttf` | 1 | Arial Unicode MS |
| 3 | `segoeui.ttf` | 1 | Segoe UI |
| 4 | **`fonts/TwemojiMozilla.ttf`** | **0** | **WE 동봉 자산** — Segoe UI Emoji 가 없을 때의 이모지 |
| 5 | `seguisym.ttf` | 1 | Segoe UI Symbol |
| 6 | `msyh.ttc` | 1 | Microsoft YaHei — 중문 |
| 7 | `Malgun.ttf` | 1 | 맑은 고딕 — **한글** |

동작: 이미 로드된 페이스들에 대해 `0x1402f0060`(FT_Get_Char_Index 계열)로 코드포인트를 찾고,
전부 0 이면 다음 엔트리를 **그때 로드**한다(`0x1401ad790` `cmp r12d, 8` 상한).
`sysdir == 0` 인 엔트리(#4)만 WE 자산 VFS 로 연다.

> **CJK 처리는 이 체인이 전부다.** WE 는 스크립트/언어 태그를 보고 폰트를 고르지 않는다 —
> 요청 폰트에 글리프가 없으면 위 순서대로 내려간다. 한글은 #7(`Malgun.ttf`), 간체 중문은
> #6(`msyh.ttc`) 에서 잡힌다. 일본어 전용 폰트는 체인에 **없다**(`msyh.ttc`/`Malgun.ttf` 의
> 한자·가나 커버리지에 의존한다).

### 3.4 크기 규약 — 300 DPI 가 실물이다

`0x1401b0520`–`0x1401b0565`:

```
0x1401b0520  cmp byte ptr [r13 + 0x18], 0      ; FontKey+0x18 = "해상도 스케일" 플래그
0x1401b0525  movss xmm0, dword ptr [r13 + 0xc] ; FontKey+0x0c = pointsize
0x1401b052b  je   0x1401b0546
0x1401b0530  movss xmm15, dword ptr [rax + 0x78]
0x1401b0536  divss xmm15, 768.0               ; 뷰포트높이 / 768
0x1401b053f  mulss xmm15, xmm0
0x1401b0546  movaps xmm15, xmm0               ; 플래그 0 → 그대로
0x1401b054a  minss xmm15, 256.0               ; 상한 256 pt
0x1401b055b  comiss xmm6(1.0), xmm15          ; 하한 1 pt
```

씬 텍스트 레이어는 `FontKey+0x18` 을 **항상 0** 으로 넣는다(`0x140257466`) — 즉 해상도
스케일은 안 탄다(UI/에디터 텍스트용 경로로 보인다 **[미해결]**).

그리고 페이스 로드에서:

```
0x1401ad1bc  mov edx, 0x756e6963              ; 'unic' = FT_ENCODING_UNICODE
0x1401ad1c4  call 0x1402f4b80                 ; FT_Select_Charmap
0x1401ad1c9  movss xmm0, [rsp + 0xf0]         ; pt
0x1401ad1d4  mulss xmm0, 64.0
0x1401ad1dc  mov r9d, 0x12c                   ; horz_resolution = 300
0x1401ad1e5  mov dword ptr [rsp + 0x20], 0x12c ; vert_resolution = 300
0x1401ad1ed  cvttss2si r8d, xmm0              ; char_height = pt * 64 (26.6)
0x1401ad1f2  call 0x1402f4dd0                 ; FT_Set_Char_Size
```

**실효 래스터 픽셀 크기 = clamp(pointsize, 1, 256) × 300/72 = pointsize × 25/6 ≈ 4.1667×.**
`lib.sceneScript.d.ts:1606` 의 "Size of the font in points for 300 DPI" 가 문자 그대로 사실이다.
동봉 실측으로도 맞는다: `previewclock` 은 `pointsize 24` 에 에디터가 기록한 `size "379 117"` —
117 / (24 × 25/6) = 1.17 ≈ RobotoMono 의 em 당 줄높이.

Waple 의 `weRenderDPI = 300`(`TextRasterizer.swift:17`)은 이로써 **바이너리 근거가 생겼다**
(종전엔 d.ts 주석만 근거였다).

### 3.5 셰이핑

HarfBuzz 를 정적 링크했다(`hb_shape_plan_create2` 등 심볼 문자열이 `.rdata` 에 남아 있다;
`bin/licenses/licenses_main.html` 에 FreeType · HarfBuzz · msdfgen 라이선스 3종 모두 존재).
`0x1401b0dae`–`0x1401b0e17` 이 버퍼 생성 → UTF-32 추가 → shape → glyph infos/positions 를 돌린다.
글리프 어드밴스는 26.6 이고 `sar 6` 으로 정수 픽셀화한 뒤 자간을 더한다(§7.3).

---

## 4. 텍스트 오브젝트 JSON 스키마 전수

### 4.1 디스크립터 등록자

**`0x140258ca0`–`0x14025a713`** 하나의 정적 초기화 함수가 텍스트 타입의 키를 **29개** 등록한다
(`0x140004814` 가 유일한 호출자 — CRT 정적 초기화). 각 등록 블록은 디스크립터 구조체에
다음을 쓴다:

| 오프셋 | 내용 |
|---|---|
| `+0x30` | 타입 코드 — `0`=int · `1`=vec2 · `2`=vec3 · `4`=float · `5`=string/enum · `6`=bool |
| `+0x34` | 오브젝트 멤버 오프셋 |
| `+0x38`/`+0x40`/`+0x48`/`+0x50`/`+0x58` | 세터/게터/직렬화 람다 (bool 은 람다가 **비트 마스크를 인코딩**한다) |
| `+0x68` | 키 문자열 |

### 4.2 29키 전수표 (자르지 않았다)

`등록 VA` = 그 키의 문자열 대입(`lea rcx,[rbx+0x68]`) 지점. `기본값` = 생성자 `0x140256ae0` 이
쓰는 값. `F/O` = 동봉 씬 파일 수 / 오브젝트 수(§10.1), `wsO` = 워크샵 오브젝트 수(§10.2).

| # | 키 | 등록 VA | 타입 | 멤버 | 기본값 | F | O | wsO | Waple |
|---:|---|---|---|---|---|---:|---:|---:|---|
| 1 | `text` | `0x14025a108` | 5 str | `+0x450` | `""` | 4 | 5 | 1597 | `parseText` `:2167`–`:2173` |
| 2 | `font` | `0x14025a1a5` | 5 str | `+0x490` | **`"systemfont_arial"`** | 4 | 5 | 1597 | `:2178` — 기본값 일치 |
| 3 | `backgroundcolor` | `0x140259295` | 2 vec3 | `+0x4d0` | `(0,0,0)` | 4 | 5 | 1426 | `:2241` |
| 4 | `backgroundbrightness` | `0x140258d66` | 4 float | `+0x4dc` | **`1.0`** | 1 | 2 | 1424 | `:2245` |
| 5 | `pointsize` | `0x14025935f` | 4 float | `+0x4e0` | **`32.0`** | 4 | 5 | 1597 | `parseText` — **32**(반영) |
| 6 | `padding` | `0x14025941d` | 1 vec2 | `+0x4e8` | **`(32,32)`** | 4 | 5 | 1597 | `parseText` — **(32,32)**(반영) |
| 7 | `spacing` | `0x1402594f0` | 1 vec2 | `+0x4f8` | `(0,0)` | 0 | 0 | 171 | `:2227` 파스만 |
| 8 | `maxwidth` | `0x1402595ab` | 4 float | `+0x508` | **`500.0`** | 1 | 2 | 1594 | `:2200` |
| 9 | `maxrows` | `0x140259669` | 0 int | `+0x510` | **`1`** | 1 | 2 | 1594 | `:2201` |
| 10 | `msdf` | `0x140259725` | 6 bool | `+0x518` **bit0** | `false` | 0 | 0 | 0 | **없음** |
| 11 | `outline` | `0x1402597df` | 6 bool | `+0x518` **bit1** | `false` | 0 | 0 | 3 | `:2237` |
| 12 | `blur` | `0x140259886` | 6 bool | `+0x518` **bit2** | `false` | 0 | 0 | 0 | **없음** |
| 13 | `dropshadow` | `0x14025993c` | 6 bool | `+0x518` **bit3** | `false` | 0 | 0 | 0 | **없음** |
| 14 | `outlinethickness` | `0x1402599e4` | 4 float | `+0x520` | **`4.0`** | 0 | 0 | 3 | `parseText` — **4**(반영) |
| 15 | `outlinecolor` | `0x140259a74` | 2 vec3 | `+0x524` | `(0,0,0)` | 0 | 0 | 3 | `:2238` |
| 16 | `blursize` | `0x140259b0e` | 4 float | `+0x530` | **`6.0`** | 0 | 0 | 0 | **없음** |
| 17 | `dropshadowsize` | `0x140259ba2` | 4 float | `+0x534` | **`6.0`** | 0 | 0 | 0 | **없음** |
| 18 | `dropshadowopacity` | `0x140259c26` | 4 float | `+0x538` | **`1.0`** | 0 | 0 | 0 | **없음** |
| 19 | `dropshadowoffset` | `0x140259d5d` | 1 vec2 | `+0x53c` | **`(4,4)`** | 0 | 0 | 0 | **없음** |
| 20 | `dropshadowcolor` | `0x140259cc4` | 2 vec3 | `+0x544` | `(0,0,0)` | 0 | 0 | 0 | **없음** |
| 21 | `anchor` | `0x14025a060` | 5 enum | `+0x550` | `0` = `"none"` | 4 | 5 | 1429 | `:2243` 파스만 |
| 22 | `opaquebackground` | `0x140258e39` | 6 bool | `+0x594` **bit1** | `false` | 4 | 5 | 1426 | `:2240` 파스만 |
| 23 | `limitwidth` | `0x140258f1a` | 6 bool | `+0x594` **bit2** | `false` | 1 | 2 | 1594 | `:2200` |
| 24 | `limitrows` | `0x140258ff3` | 6 bool | `+0x594` **bit3** | `false` | 1 | 2 | 1594 | `:2201` |
| 25 | `limituseellipsis` | `0x1402590d5` | 6 bool | `+0x594` **bit4** | `false` | 1 | 2 | 1594 | `:2202` |
| 26 | `blockalign` | `0x1402591af` | 6 bool | `+0x594` **bit5** | `false` | 1 | 2 | 1423 | `:2203` |
| 27 | `horizontalalign` | `0x140259ef0` | 5 enum | `+0x59c` | `1` = `"center"` | 4 | 5 | 1597 | `:2182` |
| 28 | `verticalalign` | `0x140259fa8` | 5 enum | `+0x59e` | `1` = `"center"` | 4 | 5 | 1597 | `:2183` |
| 29 | `depthtest` | `0x140259e1e` | 5 enum | `+0x5a0` | `0` = `"enabled"` | 1 | 2 | 1391 | `:2232` |

**`+0x594` bit0** 은 생성자가 1 로 켜지만(`0x140256cf2` `mov dword [rdi+0x594], 1`) 위 5키 중
어느 것도 아니다 — 이 라운드에 소비처를 못 찾았다. **[미해결]**

`objects[]` 공통 키(`id`/`name`/`origin`/`scale`/`angles`/`color`/`alpha`/`brightness`/`visible`/
`parent`/`effects`/`colorBlendMode`/`copybackground`/`clampuvs`/`solid`/`perspective`/
`disablepropagation`/`ledsource` 등)는 텍스트 디스크립터가 아니라 오브젝트 공통 디스크립터
소관이다 — `docs/re/scene-object-model.md` §2.1 을 보라. `size` · `parallaxDepth` ·
`locktransforms` · `castshadow` 는 텍스트 경로에서 **엔진이 안 읽는다**(같은 문서 §2 참조).

### 4.3 생성자 기본값 — `0x140256ae0`–`0x140256d16`

```
0x140256b71  movups xmm0, [0x14048ef50]                 ; "systemfont_arial" (16B SSO)
0x140256baa  call 0x140016fc0                           ; applied-font ← font (섀도 사본)
0x140256baf  mov qword ptr [rdi + 0x4d0], rsi(0)        ; backgroundcolor = (0,0,0)
0x140256bbf  mov dword ptr [rdi + 0x4e8], 0x42000000    ; padding.x = 32.0
0x140256bc9  mov dword ptr [rdi + 0x4ec], 0x42000000    ; padding.y = 32.0
0x140256be8  mov dword ptr [rdi + 0x4dc], 0x3f800000    ; backgroundbrightness = 1.0
0x140256bf2  mov dword ptr [rdi + 0x4e0], 0x42000000    ; pointsize = 32.0
0x140256c06  mov qword ptr [rdi + 0x4f8], rax(0)        ; spacing = (0,0)
0x140256c1a  mov dword ptr [rdi + 0x508], 0x43fa0000    ; maxwidth = 500.0
0x140256c2e  mov dword ptr [rdi + 0x510], 1             ; maxrows = 1
0x140256c38  mov qword ptr [rdi + 0x514], 1             ; (섀도 maxrows=1) + flags@0x518 = 0
0x140256c43  mov dword ptr [rdi + 0x520], 0x40800000    ; outlinethickness = 4.0
0x140256c5a  mov dword ptr [rdi + 0x53c], 0x40800000    ; dropshadowoffset.x = 4.0
0x140256c64  mov dword ptr [rdi + 0x540], 0x40800000    ; dropshadowoffset.y = 4.0
0x140256c6e  mov dword ptr [rdi + 0x530], 0x40c00000    ; blursize = 6.0
0x140256c78  mov dword ptr [rdi + 0x534], 0x40c00000    ; dropshadowsize = 6.0
0x140256c82  mov dword ptr [rdi + 0x538], 0x3f800000    ; dropshadowopacity = 1.0
0x140256c99  mov byte  ptr [rdi + 0x550], al(0)         ; anchor = none
0x140256cbb  mov word  ptr [rdi + 0x5a0], ax(0)         ; depthtest = enabled (+섀도)
0x140256cc7  or   word ptr [rdi + 0x120], 0x100         ; 공통 플래그 bit8
0x140256cf2  mov dword ptr [rdi + 0x594], 1             ; [미해결] bit0
0x140256d06  mov dword ptr [rdi + 0x59c], 0x01010101    ; halign=1 valign=1 (+섀도 2바이트)
```

### 4.5 기본값의 **유일한 출처**가 생성자라는 것 — 독립 재확인 (2026-08-21, 레인 E)

§4.3 의 세 값(`pointsize` 32.0 · `padding` (32,32) · `outlinethickness` 4.0)을 남의 표를 베끼지 않고
바이너리에서 다시 떴다. 절차와 결과는 이렇다.

**① 문자열 xref 전수** — `"pointsize"` `0x1404917e8` · `"padding"` `0x140491870` ·
`"outlinethickness"` `0x1404918e8`. ASCII 와 **UTF-16LE 를 둘 다** 훑었고 UTF-16LE 는 셋 다 **0건**.
`.text` 전 구간에서 disp32 를 0…4바이트 꼬리까지 열어 스캔한 결과, 세 키의 코드 참조는
**전부 디스크립터 등록자 `0x140258ca0`–`0x14025a713` 안에만** 있다(`padding` 은 바깥 히트가 2건
나왔는데 하나는 `"nopadding"` 의 부분 문자열 `0x140490bea`, 다른 하나 `0x1403dba83` 은 `jmp` 의
rel32 가 우연히 겹친 오탐이다 — 둘 다 이 키의 참조가 아니다). 즉 **`H_FLOAT 0x1401D7D30` /
`H_INT 0x1401D7BE0` 류 리플렉션 바인더의 "기본값 인자" 경로는 텍스트 레이어에 없다.**

**② 디스크립터에는 기본값 칸이 없다** — 등록 블록이 쓰는 것은 `+0x30`(타입) · `+0x34`(멤버 오프셋) ·
`+0x38/+0x40/+0x48/+0x50/+0x58`(람다) · `+0x68`(키 문자열)뿐이다. 직접 읽은 값:

| 키 | 문자열 대입 | 길이 인자 | `[desc+0x34]` | `[desc+0x30]` |
|---|---|---:|---|---|
| `pointsize` | `0x140259352` | `mov r8d, 9` | `0x4e0` (`0x140259396`) | `4`=float (`0x14025939d`) |
| `padding` | `0x140259410` | `mov r8d, 7` | `0x4e8` (`0x14025942d`) | `1`=vec2 (`0x140259446`) |
| `outlinethickness` | `0x1402599d7` | `mov r8d, 0x10` | `0x520` (`0x1402599fa`) | `4`=float (`0x140259a09`) |

> **함정 16 실사례**: `dropshadow` 블록 한가운데(`0x140259957`)에 *다음* 항목인
> `"outlinethickness"` 의 `lea` 가 끼어 있다. 순진하게 "가장 가까운 `lea`" 로 짝지으면 한 칸 밀린다.
> 위 표는 `mov r8d, len` 의 **길이**로 짝을 검증했다(9/7/16 = 각 키의 실제 길이).

**③ 값을 심는 곳은 생성자 하나뿐이고, 그 생성자가 씬 텍스트 오브젝트의 것이 맞다** —
`0x140256ae0`–`0x140256d16` 의 유일한 호출자는 `0x140190364` 이고, 그 자리는 오브젝트 팩토리
`0x14018ff60`–`0x1401909b1` 의 `find(obj,"text")` 분기다(`0x140190343` find → `0x14019034d`
`mov ecx, 0x5d0` = 오브젝트 크기 → `0x140190364` call). 생성자가 쓰는 값:
`0x140256bf2` `[rdi+0x4e0] = 0x42000000`(32.0) · `0x140256bbf`/`0x140256bc9`
`[rdi+0x4e8]`/`[rdi+0x4ec] = 0x42000000` · `0x140256c43` `[rdi+0x520] = 0x40800000`(4.0).

**④-a bool 도 같은 구조다(교차 검증)** — `opaquebackground` 의 bool 세터 `0x14019b4e0` 은
`cmp byte [v+8], 5` 로 태그를 확인하고 그때만 `asBool`(`0x140086300`) 결과로 `[this+0x594]` 의
**bit1**(마스크 `0x2` — `or ecx,2` / `and r8d,~2` @`0x14019b516`–`0x14019b51a`)을 세우거나 지운다.
태그가 5 가 아니면 스토어 블록을 통째로 건너뛴다. 이것이 §8(a) 의 패딩 게이트
`[this+0x594] & 2` 가 `opaquebackground` 라는 것의 **직접 근거**다(종전엔 배경 쿼드 경로에서
같은 마스크를 쓴다는 정황 근거뿐이었다).

**④ 주입기의 실패 분기가 생성자 값을 남긴다(함정 15)** — float 주입기 `0x1401a4b00` 은
Json 태그 1/2/3 일 때만 `asFloat`(`0x140086220`) → `movss [member]`; 태그 7(오브젝트)이면
`find("value")` 로 한 번 더 들어가고, **그 밖의 태그(문자열 포함)는 스토어 자체를 건너뛴다**.
vec2 주입기 `0x1401a3fc0` 도 같은 구조다(태그 1/2/3 브로드캐스트 · 태그 4 `"x y"` 파스 ·
그 외 무시). 그래서 "키가 없다" 와 "키가 있지만 타입이 다르다" 가 **둘 다 생성자 기본값**으로
수렴한다 — Waple 의 `float(...) ?? 32` / `uniformVec2(...) ?? Vec2(32,32)` 폴백과 1:1 이다.

**⑤ DPI 이중 적용이 아니다** — `pointsize` 는 `+0x4e0` 에서 **스케일 없이** FontKey`+0x0c` 로
들어가고(`0x140257443` `movss xmm0,[rbx+0x4e0]` → `0x140257461` `movss [rbp-0x5d],xmm0`),
`clamp(1,256)` 뒤 `FT_Set_Char_Size(face, 0, (int)(pt*64), 300, 300)` 로 간다(§3.4).
FreeType 규약상 그 인자는 1/64 **포인트**이므로 실효 픽셀 = pt × 300/72 이고, 배율은 **한 번만**
곱해진다. Waple 의 `TextRasterizer.render` 도 `pointSize * weRenderDPI / 72` 를 한 번만 곱하므로
16 → 32 는 배율 문제가 아니라 **순수한 기본값 오류**였다.

---

### 4.4 enum 값표

각 enum 테이블은 `{ std::string 이름(+0x00), uint8 값(+0x20) }` 스트라이드 `0x28` 이다.
테이블 자체는 `.data` 의 **BSS 영역**(rawsize 밖)이라 파일에는 0 만 있고, 위 등록자가
런타임에 채운다 — 그래서 아래 VA 를 파일 오프셋으로 환산해 열어 보면 아무것도 없다.

**`anchor`** — 테이블 `0x1404e9b40`, 소비 점프테이블 `0x1402588d4`:

| 값 | 문자열 | 핸들러 |
|---:|---|---|
| 0 | `none` | `0x1402588cc` (변환 없음) |
| 1 | `center` | `0x1402586f6` |
| 2 | `top` | `0x14025863c` |
| 3 | `topright` | `0x140258676` |
| 4 | `right` | `0x14025873c` |
| 5 | `bottomright` | `0x14025888d` |
| 6 | `bottom` | `0x14025878d` |
| 7 | `bottomleft` | `0x140258779` |
| 8 | `left` | `0x1402586d2` |
| 9 | `topleft` | `0x1402585e7` |

**`horizontalalign`** — 테이블 `0x1404e9a40`: `left`=0 · `center`=1 · `right`=2.
**`verticalalign`** — 테이블 `0x1404e9ac0`: **`bottom`=0 · `center`=1 · `top`=2**(순서가 값 순이 아니다).
**`depthtest`** — 테이블 `0x1404e99e0`: **`enabled`=0 · `disabled`=1**(값이 뒤집혀 있다).

`depthtest` 의 역방향 배정은 소비처에서 교차 검증된다: `0x14025747f` 이
`[this+0x5a0] == 0` 일 때만 "깊이 있음" 플래그를 1 로 만들고, `0x1401b37e3` 이 그 플래그가
참일 때 `basefont_msdf_depth.json` 을 고른다 — 즉 `"enabled"` → depth 머티리얼. 일관된다.

---

## 5. 오브젝트 레이아웃과 더티 체크

### 5.1 섀도 페어

`0x140256f20`–`0x1402570ec` 는 "현재 값" 과 "적용된 값" 을 쌍으로 비교해 재레이아웃 필요성을
판정한다. 이 비교 목록이 곧 **레이아웃에 영향을 주는 키의 전수**다.

| 현재 | 섀도 | 의미 |
|---|---|---|
| `+0x450` std::string | `+0x470` | `text` |
| `+0x490` std::string | `+0x4b0` | `font` |
| `+0x4e0` | `+0x4e4` | `pointsize` |
| `+0x4e8,+0x4ec` | `+0x4f0,+0x4f4` | `padding` |
| `+0x4f8,+0x4fc` | `+0x500,+0x504` | `spacing` |
| `+0x508` | `+0x50c` | `maxwidth` |
| `+0x510` | `+0x514` | `maxrows` |
| `+0x518` | `+0x51c` | 이펙트 플래그 — **`(cur==0) == (prev==0)`** 로만 비교(`0x1402570c6`–`0x1402570e2`) |
| `+0x594` | `+0x598` | opaquebackground/limit*/blockalign 플래그 |
| `+0x59c` | `+0x59d` | `horizontalalign` |
| `+0x59e` | `+0x59f` | `verticalalign` |
| `+0x5a0` | `+0x5a1` | `depthtest` |

`+0x518` 을 "0 인가 아닌가" 로만 비교하는 것이 핵심이다 — outline↔blur 전환은 **아틀라스
재생성 없이** 콤보만 갈아끼우면 되기 때문이다(§6.4).

### 5.2 `FontKey` — 레이아웃 캐시 키, 0x58 바이트

`0x14025742f`–`0x1402575c9` 가 스택에 조립해 `GetLaidOutText` 로 넘긴다. 이 구조체가
**"무엇이 레이아웃을 결정하는가" 의 정의**다.

| off | 타입 | 출처 | 비고 |
|---|---|---|---|
| `+0x00` | `const char*` | `font` c_str | |
| `+0x08` | int32 | systemfont 인덱스 0..8 | `0x140257241`(기본 8) |
| `+0x0c` | float | `pointsize` | |
| `+0x10` | float | `spacing.x` | **자간(px)** |
| `+0x14` | float | `spacing.y` | **행간 추가(px)** |
| `+0x18` | bool | 해상도 스케일 | 텍스트 레이어는 **항상 0** |
| `+0x19` | bool | 깊이 필요 | `!(scene[0x118] & 0x400) && depthtest==0` (`0x14025746a`) |
| `+0x1a` | bool | **MSDF 요청** | `[this+0x518] != 0` (`0x1402574d3`) |
| `+0x1b` | uint8 | `horizontalalign` | |
| `+0x1c` | float | outline 두께 | outline 켜짐: `max(값, 1.0)`; 꺼짐: `0` |
| `+0x20..0x28` | vec3 | `outlinecolor` | |
| `+0x2c` | float | blur 크기 | blur 켜짐: `max(값, 0.01)`; 꺼짐: `0` |
| `+0x30` | float | dropshadow 크기 | 켜짐: `max(값, 0.01)`; 꺼짐: `0` |
| `+0x34` | float | `dropshadowopacity` | |
| `+0x38..0x40` | vec3 | `dropshadowcolor` | |
| `+0x44,+0x48` | vec2 | `dropshadowoffset` | dropshadow 꺼짐이면 `(0,0)` |
| `+0x4c` | float | `maxwidth` | `limitwidth` 켜졌을 때만 씀 — 아니면 **0 = 무제한** |
| `+0x50` | int32 | `maxrows` | `limitrows` 켜졌을 때만 — 아니면 **0 = 무제한** |
| `+0x54` | bool | `limituseellipsis` | |
| `+0x55` | bool | `blockalign` | |

`0.01` 하한 상수는 `0x140257510`(`f32=0.01`), `1.0` 하한은 `0x1402574ec`.

### 5.3 레이아웃 결과 객체

`GetLaidOutText` 가 돌려주는 객체(텍스트 오브젝트 `+0x5a8` 에 보관)의 필드. `+0x90`–`+0xa8`
은 `0x1401b2dde`–`0x1401b2e1e` 이 한 번에 채운다.

| off | 내용 | 쓰기 VA |
|---|---|---|
| `+0x19` | 깊이 필요 (FontKey 사본 — 객체 앞부분이 FontKey 레이아웃이다) | — |
| `+0x20` | MSDF 아틀라스 여부 | `0x1401b08aa` |
| `+0x90` | 잉크 바운딩박스 minX | `0x1401b2dec` |
| `+0x94` | minY | `0x1401b2dfa` |
| `+0x98` | maxX | `0x1401b2e03` |
| `+0x9c` | maxY | `0x1401b2e0c` |
| `+0xa0` | 줄 높이 = `FT 라인높이>>6 + spacing.y` | `0x1401b2e15` |
| `+0xa4` | 줄 수 | `0x1401b2dde` |
| `+0xa8` | **포인트 크기**(클램프 후) — 이펙트 폭 환산에 쓴다(§6.2) | `0x1401b2e1e` |

---

## 6. MSDF 대 비트맵

### 6.1 언제 MSDF 를 타는가 — `0x1401b0600`–`0x1401b0643`

```
if (FontKey.msdf)                      -> MSDF     ; +0x1a, = (msdf|outline|blur|dropshadow)
else if (outlineThickness >= 1.0)      -> MSDF
else if (blurSize        >  0.0)       -> MSDF
else if (dropShadowSize  >  0.0)       -> MSDF
else if (|dropShadowOffset| > 1.19e-7) -> MSDF     ; 0x1401b4080 이 길이 제곱을 돌려준다
else                                   -> 비트맵
```

씬 텍스트 레이어에 한정하면 첫 줄이 나머지를 포섭한다(꺼진 이펙트는 수치를 0 으로 밀어 넣으므로).
**결론: `msdf` · `outline` · `blur` · `dropshadow` 중 하나라도 true 면 MSDF, 아니면 비트맵.**
JSON 에 `msdf` 를 단독으로 켜는 것이 "MSDF 로 그려라" 의 정식 스위치다.

MSDF 여부는 **캐시 키에도 들어간다** (`0x1401b0664`–`0x1401b070c`):

* 이름이 비면 `"DEFAULT"`.
* MSDF → `<name> + "_msdf"` — **크기가 키에 없다. 한 폰트당 아틀라스 하나를 모든 크기가 공유한다.**
* 비MSDF → `<name> + "_" + int(pt * 64)` — **크기별 아틀라스**.

### 6.2 MSDF 파라미터 — 자산이 아니라 전부 코드 상수다

글리프 래스터 `0x1401ae080`–`0x1401afdfb` 안:

```
0x1401af409  call 0x140281900                 ; msdfgen Shape 정규화로 보인다 [추정]
0x1401af40e  movsd xmm1, [0x1404927c8]        ; f64 3.0  ← msdfgen edgeColoringSimple 기본 임계
0x1401af41a  call 0x140283500                 ; edgeColoringSimple(shape, 3.0) [추정]
0x1401af427  movss xmm2, [0x14049287c]        ; f32 12.0
0x1401af433  movss xmm7, [0x140492890]        ; f32 24.0
0x1401af48d  divss xmm8, xmm1                 ; xmm8 = 셀 최대변 / 글리프 bbox 최대변 (fit scale)
0x1401af495  divss xmm2, xmm8                 ; 12 / scale  → 좌·하 12 텍셀 패딩(translate)
0x1401af4b4  divss xmm7, xmm8                 ; 24 / scale  → msdfgen range
0x1401af4c5  cmp r14d, 0x6f75746c             ; 'outl' = FT_GLYPH_FORMAT_OUTLINE
0x1401af5c5  call 0x14028a910                 ; msdfgen: generateMSDF
```

* **range = 24 아틀라스 텍셀**(글리프 단위로는 `24 / fitScale`).
* **글리프당 패딩 = 12 텍셀**(range 의 절반) — `translate = 12/scale − bboxMin`.
* **엣지 컬러링 각도 임계 = 3.0** (msdfgen 기본값).
* 중간 버퍼는 픽셀당 float3, `256.0` 으로 8비트화(`0x1401af5d5`).
* 생성 설정 구조체(`rbp+0x60`)는 `1` / `2` / `1` 세 값이다(`0x1401af542`·`0x1401af54a`·`0x1401af551`) — msdfgen 의 `MSDFGeneratorConfig{overlapSupport, ErrorCorrectionConfig{mode, distanceCheckMode}}` 배치와 맞지만 필드 이름 대응은 **[추정]** 이다.

셰이더에 넘어가는 값은 `0x1401b3db8` 이 **상수 24.0** 을 `g_RenderVar0.x` 에 쓴다. 즉
`assets/shaders/font.frag` 의 `MSDF_RANGE` 는 **런타임 계산이 아니라 붙박이 24.0** 이고,
자산에는 어떤 MSDF 파라미터도 들어 있지 않다.

이펙트 폭의 단위 환산은 `0x1401b3d9e`–`0x1401b3dc9`:

```
scale = (32.0 / font.pointSize) * 0.24        ; 0.24 = 72/300
g_RenderVar0.y = scale * outlineThickness      ; OUTLINE_WIDTH
g_RenderVar0.z = scale * blurSize              ; BLUR_RADIUS
g_RenderVar0.w = scale * dropShadowSize        ; DROP_SHADOW_RADIUS
g_RenderVar1.w = scale * dropShadowOffset.x
g_RenderVar2.w = scale * dropShadowOffset.y
```

그 뒤 `0x1401b3e96`–`0x1401b3f4d` 이 안전장치를 건다 — MSDF 패딩 12 텍셀 안에서 번지게 하려는
클램프다:

```
RenderVar0.z (BLUR_RADIUS)         = min(값, 6.0)     ; 0x1401b3eb5
RenderVar0.w (DROP_SHADOW_RADIUS)  = min(값, 6.0)     ; 0x1401b3ed4
RenderVar1.w (DS_OFFSET.x)         = min(값, 6.0)     ; 0x1401b3ef3
RenderVar2.w (DS_OFFSET.y)         = min(값, 6.0)     ; 0x1401b3f12
RenderVar0.y (OUTLINE_WIDTH)       = min(값, 5.1)     ; 0x1401b3e86  (상수 0x14049285c)
if (OUTLINE_WIDTH + BLUR_RADIUS > 5.1)
    OUTLINE_WIDTH = max(5.1 − BLUR_RADIUS, 0)         ; 0x1401b3f34–0x1401b3f45
```

### 6.3 아틀라스

생성 `0x1401ac8d0`–`0x1401aca1d`:

```
0x1401ac98b  mov dword ptr [rdi], 0x200        ; width  = 512
0x1401ac994  mov dword ptr [rdi + 4], 0x200    ; height = 512
0x1401ac99b  mov byte  ptr [rdi + 8], r14b     ; (호출부에서 항상 0)
0x1401ac99f  mov byte  ptr [rdi + 9], bpl      ; MSDF 플래그
0x1401ac9a8  mov ecx, 0x40000                  ; 1 B/px  = 512*512
0x1401ac9b4  mov ecx, 0x100000                 ; 4 B/px  = 512*512*4  (MSDF 또는 컬러)
```

텍스처 등록 `0x1401ac7f0`–`0x1401ac8c4`:

| 이름 | 포맷 | 조건 |
|---|---|---|
| `__font_atlas_` | **9 = r8** | MSDF 아님 |
| `__font_atlas_` | **0 = rgba8888** | MSDF |
| `__font_atlas_color_` | **0 = rgba8888** | 컬러 글리프가 하나라도 있을 때(`[atlas+0x28] != 0`) |

포맷 코드는 `docs/re/tex-format.md` §2.1 의 열거(0=rgba8888, 9=r8)와 같은 것이다.
컬러 아틀라스 치수는 `512 × [atlas+0x38]`(슈퍼샘플 배수) — 이 경로의 호출은 배수 1
(`0x1401b08a4` `mov r8d, 1`).

컬러 글리프는 FreeType 이 `FT_PIXEL_MODE_BGRA` 로 주고 WE 는 **B↔R 스왑만** 해서
그대로 넣는다(`0x1401afa2d`–`0x1401afb29`) — 화이트닝도 프리멀티플라이 해제도 없다.
(이 사실은 `Sources/WapleRender/TextRasterizer.swift` 의 언프리멀티플라이 블록 주석이
이미 VA 로 인용하고 있다 — 이번 조사와 일치한다.)

### 6.4 머티리얼 선택과 콤보

`0x1401b3430`–`0x1401b3b53` 이 두 배치(단색/MSDF 배치 + 컬러 글리프 배치)를 각각 그린다.

콤보 인덱스 `0x1401b3b60`–`0x1401b3f79`:

```
idx = 0
if (outlineThickness >= 1.0) { 콤보 OUTLINE_ENABLED=1;     idx = 1; r15 = 3 } else r15 = 2
if (blurSize > 0)            { 콤보 BLUR_ENABLED=1;        idx = r15        }
if (dropShadowSize > 0 || |dsOffset| > eps)
                             { 콤보 DROP_SHADOW_ENABLED=1; idx |= 4 }        ; 0x1401b3d97
```

즉 `idx = outline | blur<<1 | dropshadow<<2`, 0..7. 머티리얼은 그 인덱스로 캐시된다:

| 배열 베이스 | 머티리얼 |
|---|---|
| `[this + idx*8 + 0xb8]` | `materials/fonts/basefont_msdf.json` |
| `[this + idx*8 + 0xf8]` | `materials/fonts/basefont_msdf_depth.json` |
| `[this + 0xa8]` (단일) | `materials/fonts/basefont.json` |
| `[this + 0xb0]` (단일) | `materials/fonts/basefont_depth.json` |
| — | `basefontrgba{,_depth,_msdf,_msdf_depth}.json` (컬러 배치) |

**비MSDF 경로에는 콤보 슬롯이 없다** — outline/blur/dropshadow 는 구조적으로 MSDF 전용이다.

`OUTLINE_ENABLED` · `BLUR_ENABLED` · `DROP_SHADOW_ENABLED` 문자열은 `0x14048f0f8` ·
`0x14048f108` · `0x14048f118` 에 있고 **어떤 `.json` 머티리얼에도 없다** — 런타임 콤보다.
반면 `MSDF` · `COLORFONT` 는 머티리얼 파일이 정적으로 선언한다(`basefont_msdf.json` 등).

### 6.5 셰이더 배선 — `assets/shaders/font.frag` ↔ 오브젝트 멤버

`g_RenderVar0..3` 의 오브젝트 멤버 오프셋은 `+0xa8`/`+0xb8`/`+0xc8`/`+0xd8` 이다
(`docs/re/camera-motion.md` 의 유니폼표가 `g_RenderVar0` = `+0xa8` 을 이미 못박아 두었다).

| 셰이더 심볼 | 유니폼 성분 | 멤버 | 쓰기 VA | 값 |
|---|---|---|---|---|
| `MSDF_RANGE` | `g_RenderVar0.x` | `+0xa8` | `0x1401b3db8` | **상수 24.0** |
| `OUTLINE_WIDTH` | `g_RenderVar0.y` | `+0xac` | `0x1401b3ddc` | `scale × outlinethickness` |
| `BLUR_RADIUS` | `g_RenderVar0.z` | `+0xb0` | `0x1401b3df3` | `scale × blursize` |
| `DROP_SHADOW_RADIUS` | `g_RenderVar0.w` | `+0xb4` | `0x1401b3e0a` | `scale × dropshadowsize` |
| `OUTLINE_COLOR` | `g_RenderVar1.xyz` | `+0xb8..0xc0` | `0x1401b3e4e` | `outlinecolor` |
| `DROP_SHADOW_OFFSET.x` | `g_RenderVar1.w` | `+0xc4` | `0x1401b3e1e` | `scale × dropshadowoffset.x` |
| `DROP_SHADOW_COLOR` | `g_RenderVar2.xyz` | `+0xc8..0xd0` | `0x1401b3e6b` | `dropshadowcolor` |
| `DROP_SHADOW_OFFSET.y` | `g_RenderVar2.w` | `+0xd4` | `0x1401b3e3a` | `scale × dropshadowoffset.y` |
| `DROP_SHADOW_OPACITY` | `g_RenderVar3.x` | `+0xd8` | `0x1401b3f5f` | `dropshadowopacity` |

`DROP_SHADOW_OFFSET` 이 `vec2(g_RenderVar1.w, g_RenderVar2.w)` 로 **쪼개져** 있다는 셰이더의
특이한 정의가 `+0xc4` / `+0xd4` 두 곳에 나뉘어 쓰이는 코드와 정확히 맞는다 — 이 매핑의
교차 검증이다.

`g_Color4` 는 레이어 `color`(vec3) + `alpha` 이고, 셰이더는 **MSDF·COLORFONT 조합에 따라
색 적용이 다르다**:

| MSDF | COLORFONT | 결과 |
|---|---|---|
| 0 | 0 | `vec4(g_Color4.rgb, ConvertSampleR8(tex0) * g_Color4.a)` |
| 0 | 1 | `vec4(tex0.rgb, tex0.a * g_Color4.a)` — **레이어 색이 rgb 에 안 곱해진다** |
| 1 | 0 | `ApplyOutline(..., g_Color4.rgb, g_Color4.a)` |
| 1 | 1 | `ApplyOutline(..., tex1.rgb, g_Color4.a)` — 색은 `g_Texture1`(컬러 아틀라스) |

---

## 7. 레이아웃 규약

### 7.1 문단 분리

텍스트는 UTF-8 → UTF-32 로 펼친 뒤 **U+000A(`\n`)** 로만 문단을 나눈다
(`0x1401b0a30` `cmp dword ptr [rbx], 0xa`). CR(U+000D)은 문단 구분자가 아니라 **공백류**로 취급된다.

### 7.2 워드랩 — 클러스터 단위 그리디

`0x1401b1240`–`0x1401b1272`:

```
if (maxwidth <= 0)                 skip     ; limitwidth 꺼짐
if (현재 줄 글리프 수 == 0)         skip     ; 첫 글리프는 무조건 놓는다
if (cp <= 0x20 && cp ∈ {9,13,32})  skip     ; 공백류 앞에서는 안 끊는다
if (cluster == 직전 cluster)       skip     ; 같은 클러스터 내부에서는 안 끊는다
if (penX + advance > maxwidth)     새 줄     ; 0x1401b13c5
```

공백류 집합은 비트마스크 상수 `0x100002200` = **{U+0009, U+000D, U+0020}** 이다
(`0x1401b1253` 등 5곳에서 재사용). **U+000A 는 이 집합에 없다** — 하드 개행으로 따로 처리된다.

> **이것은 단어 단위 줄바꿈이 아니다.** 폭이 넘치면 그 글리프 자리에서 끊는다.
> 공백 경계로 되돌아가는 재추적 코드를 이 라운드에 찾지 못했다 — **[부분 미해결]**.
> (찾은 것은 새 줄 레코드 push 뿐이고 `0x1401b6be0`/`0x1401b6c20`/`0x1401b6de0` 은
> 벡터 resize 헬퍼다.) 그 대신 **클러스터 경계는 지킨다** — 결합 문자·리거처는 안 쪼갠다.
> CJK 는 클러스터가 글자마다라 자연히 글자 단위로 접힌다.

`maxwidth` 의 단위는 **래스터 픽셀**(= 300 DPI 픽셀)이다 — 누적 어드밴스와 같은 축에서 비교한다.

### 7.3 자간·행간 — `spacing` 은 vec2 이고 둘 다 픽셀이다

```
0x1401b1166  mov eax, dword ptr [rdx + rdi*4]     ; HarfBuzz x_advance (26.6)
0x1401b1169  sar eax, 6                           ; → 정수 픽셀
0x1401b118d  cvtdq2ps xmm6, xmm6
0x1401b1194  addss xmm6, dword ptr [r11 + 0x10]   ; + spacing.x   ← 자간
```

```
0x1401b0bf0  mov ecx, dword ptr [rax + 0x2c]      ; FT 라인 높이 (26.6)
0x1401b0bf3  sar ecx, 6
0x1401b0c04  addss xmm6, dword ptr [r13 + 0x14]   ; + spacing.y   ← 행간 추가
0x1401b0c0a  movss dword ptr [rbp + 0xc0], xmm6   ; 최종 줄 높이
```

**어드밴스를 26.6 → 정수 픽셀로 먼저 자른 뒤** 자간을 더한다는 점이 중요하다 — WE 의 글자
간격은 서브픽셀이 아니다. 행간도 마찬가지로 `FT height >> 6` 정수 픽셀이 기준이다.

### 7.4 행 내 수평 정렬과 `blockalign`

행 내 정렬(`0x1401b2990`–`0x1401b29be`):

```
halign == 0 (left)   -> 오프셋 0
halign == 2 (right)  -> 오프셋 = 블록폭 − 행폭
halign == 1 (center) -> 오프셋 = (블록폭 − 행폭) * 0.5
```

`blockalign`(양쪽 정렬, `0x1401b21f5`–`0x1401b22d1`):

```
if (!FontKey.blockalign) skip
행의 공백류({9,13,32}) 개수 n 을 센다
if (n <= 0) skip
extra = (목표폭 − 행폭) / n
그 행의 **공백 글리프 어드밴스에만** extra 를 더한다   ; 0x1401b22b1
```

즉 WE 의 양쪽 정렬은 **공백을 늘리는 방식**이고 글자 사이는 안 벌린다. 공백이 없는 행
(CJK 등)에는 아무 효과가 없다.

> 행 내 정렬의 "블록폭"(레지스터 `xmm14`)과 양쪽 정렬의 "목표폭"(`xmm9`)이 각각
> **`maxwidth` 인지 가장 긴 행의 폭인지**는 확정하지 못했다 — **[미해결]**.
> `limitwidth` 가 꺼진 경우엔 후자일 수밖에 없다(`maxwidth` 가 0 이므로).

### 7.5 블록 피벗과 수직 정렬 — `0x1402576b9`–`0x1402577c4`

레이아웃 결과의 잉크 박스와 폰트 메트릭으로 레이어 로컬 오프셋 `+0x2f8`(x) / `+0x2fc`(y) 를 만든다.
`asc`/`desc` 는 폰트 메트릭(`[face+0x80]+0x24`, `+0x28`, 26.6 → `>>6`), `n` = 줄 수,
`lh` = 줄 높이:

```
yOff = (maxY + minY) * 0.5                       ; 잉크 박스 세로 중앙
halign == 0 (left)   : xOff = (maxX − minX) * 0.5
halign == 2 (right)  : xOff = −(maxX − minX) * 0.5
halign == 1 (center) : xOff = 0
valign == 2 (top)    : yOff −= asc
valign == 1 (center) : yOff −= (asc − (n−1)·lh) * 0.5
valign == 0 (bottom) : yOff −= (desc − (n−1)·lh)
```

수평은 "왼쪽 정렬이면 origin 이 블록 좌변" 이라는 Waple 규약과 **같다**.
수직은 WE 가 **폰트 ascender/descender** 를 쓰는 반면 Waple 은 래스터 박스를 쓴다(§0 #11).

### 7.6 말줄임 — U+2026

`0x1401b1921`–`0x1401b199e`. `limituseellipsis` 가 켜지고 `maxrows` 로 잘렸을 때:

```
마지막 행의 끝이 이미 U+2026 이면 아무 것도 안 한다     ; 0x1401b192d
끝에서부터 공백류({9,13,32})를 모두 지운다              ; 0x1401b1950–0x1401b1993
U+2026 를 붙인다                                        ; 0x1401b1995 mov edx, 0x2026
```

### 7.7 `anchor` — 화면 가장자리 스냅

`0x1402585c0` 이 씬(`this+0xc8`)의 화면 사각형 `+0x100`(좌) `+0x104`(상) `+0x108`(우) `+0x10c`(하)
를 읽어 모델 행렬의 평행이동 행(`[rdx+0x30]`)에 더한다. 예:

* `topleft`(9): `(+0x100, −(+0x104))`
* `top`(2): `((+0x100 − +0x108)·0.5, −(+0x104))`
* `center`(1): `((+0x100 − +0x108)·0.5, (+0x10c − +0x104)·0.5)`
* `bottomleft`(7): `(+0x100, +0x10c)`
* `none`(0): 아무것도 안 한다(`0x1402588cc` 가 `al=0` 을 돌려주고 끝)

즉 `anchor` 는 **배경 박스만의 앵커가 아니라 레이어 전체를 화면 가장자리에 붙이는 기능**이다.
(`Sources/WapleCore/SceneDocument.swift:445` 의 필드 주석은 "배경 박스 앵커" 라고 적었는데,
실물은 텍스트 쿼드와 배경 쿼드가 공유하는 **레이어 모델 행렬**에 적용된다.)

---

## 8. `padding` 과 배경 박스

`padding`(vec2)은 두 곳에서 쓰인다.

**(a) 글리프 쿼드 오프셋** — `0x140257d70`–`0x140258045`:

```
if ([this+0x320] > 0 || ([this+0x304] & 0x10) || ([this+0x594] & 2))
     padX = min(padding.x, 512.0);  padY = min(padding.y, 512.0)
else padX = padY = 0
padY −= layout.minY
if (layout.minX < 0) padX −= layout.minX
모델 행렬에 (padX, padY, 0) 을 로컬 평행이동으로 합성
```

즉 **패딩은 세 게이트 중 하나가 참일 때만** 효력이 있고, 각 축 **512 상한**이 있다.

**세 게이트의 정체 — 2026-08-21(클러스터 AV)에 나머지 둘을 확정했다.**

| 게이트 | 뜻 | 쓰기 VA |
|---|---|---|
| `[this+0x594] & 2` | `opaquebackground`(bit1) | 주입기(§4.2) |
| `[this+0x320] > 0` | **이펙트 체인이 실재한다.** 이펙트 빌더 `0x1401e6f50` 이 진입 시 0 으로 깔고(`0x1401e6fef` `mov qword [rsi+0x320], 0`), 이펙트별 패스 집계 `0x1401e7170` 이 `add dword [r8+0x320], eax` 로 누적한다(`0x1401e895b`; `eax = !(bit13 of +0x304) + [pass+0x140]`). 형제 `+0x324` 는 같은 자리에서 패스 수를 센다(`0x1401e8974`) | `0x1401e895b` |
| `[this+0x304] & 0x10` | **오프스크린 합성이 필요하다.** 같은 빌더가 `0x1401e6fa2` `or dword [rsi+0x304], 0x10` 로 켜고, 조건은 세 갈래다 — `colorBlendMode`(`+0x32c`)가 **0 도 31 도 아니거나**(`0x1401e6f74`–`0x1401e6f81`), `+0x304 & 0x100` 이 켜져 있거나(`0x1401e6f83`), 씬 렌더 설정 `[[this+0xc8]+0x118] & 0x1800000` 이 켜져 있으면(`0x1401e6f96`) | `0x1401e6fa2` |

(`+0x304` 는 오브젝트 공통 플래그 워드다 — 생성자 `0x1401e69ea` 가 `0x8040` 으로 깔고
`docs/re/scene-object-model.md` §2.1 이 bit6 `copybackground` / bit8 `ledsource` /
bit14 `nointerpolation` / bit15 `clampuvs` 를 짚어 두었다. **bit4 는 저작 키가 아니라 파생
플래그**라 등록표에 없다 — 등록표에서 `+0x304` 를 쓰는 넷은 위 네 키뿐이고
`0x1401eeb8e`·`0x1401eec5d`·`0x1401eed26`·`0x1401eee1a` 에서 확인된다.)

**(b) 배경 쿼드** — `0x140258050`–`0x14025857a`:

```
0x1402580eb  test byte ptr [rcx + 0x594], 2     ; opaquebackground 아니면 배경 안 그림
0x1402581b7  movss xmm0, 512.0                  ; 같은 512 클램프
0x1402582b4  movss  xmm3, [rbx + 0x4dc]         ; backgroundbrightness (else xmm13 @0x1402582be)
0x1402582c2  movsd  xmm0, [rbx + 0x4d0]         ; backgroundcolor.rg
0x1402582cd  mulss  xmm2(=brightness), [rbx + 0x4d8]  ; b  * backgroundbrightness
0x1402582d9  mulps  xmm0, xmm3(broadcast)       ; rg * backgroundbrightness
0x1402582dc  movsd  [rax + 0x124], xmm0         ; 오브젝트 색상 슬롯 = bgcolor * bgbrightness
0x140258326  lea rdx, "materials/fonts/fontbackground.json"
0x14025831f  lea r8,  "materials/fonts/fontbackground_depth.json"
0x14025834c  cmp dword ptr [rbx + 0x32c], 0x1f  ; colorBlendMode == 31 → 블렌드 슬롯 2, 아니면 1
```

배경 머티리얼은 `flat` 셰이더(`assets/materials/fonts/fontbackground.json`)이고 크기는
잉크 박스 + 패딩이다. **`backgroundbrightness` 는 `backgroundcolor` 에 곱해지는 배수**다.

---

## 8b. 텍스트 오브젝트의 `size` — 커서 히트 상자가 여기 걸려 있다 (2026-08-21, 클러스터 AV)

`docs/re/scene-script-api.md` §9.1 (b) 와 `docs/re/pointer-interaction.md` §7.4 우선순위 2 가
"실물 텍스트의 히트 상자는 래스터된 픽셀 크기 — [미해결]" 로 남겨 둔 항목이다. **규약은 확정했다.**

### 8b.1 히트 상자는 `size` 멤버 `+0x2f0` 이고, 텍스트도 이미지와 **같은 함수**를 탄다

- 히트 순회(`0x140189fff`–`0x14018a42f`)는 오브젝트마다 타입 가상함수 `[vtbl+0x60]` 을 부른다
  (`0x14018a041`). **텍스트 오브젝트는 4를 돌려준다** — vtable `0x140491950`(생성자
  `0x140256af7` `lea rax,[rip+0x23ae52]` → `0x140256b05` `mov [rdi],rax`) 의 슬롯 `+0x60` 이
  `0x1400fde90` = `mov eax,4; ret` 이다.
- 순회는 `eax == 1 || eax == 4` 를 같은 레지스터(`rdx`)로 모아(`0x14018a044`–`0x14018a050`)
  **하나의 상자 함수** `0x14019dbb0` 에 넘긴다(`0x14018a242`). 즉 텍스트와 이미지의 히트 기하는
  코드가 동일하다.
- 그 함수가 읽는 크기는 `mov rax, qword [rbx+0x2f0]`(`0x14019dd8a`) — **vec2 하나**를 8바이트로
  집어 x 를 `xmm11`, y 를 `xmm12` 로 갈라 기저벡터에 곱하고(`0x14019dde3`·`0x14019de31`),
  `mulps xmm4, (-0.5,-0.5,-0.5,-0.5)`(`0x14019de4b`)로 ±0.5 쿼드를 만든다. `pointer-interaction.md`
  W-6 의 평행사변형이 이것이고, 이미지 레이어와 **완전히 같은 규약**이다.
- `+0x2f0` 은 저작 키다 — 공통 레이어 등록자 `0x1401ee520` 의 첫 엔트리 `"size"`
  (`lea` `0x1401ee5bd` → 대입 `0x1401ee5ce` → `[desc+0x34]=0x2f0` `0x1401ee5da` ·
  `[desc+0x30]=1`(vec2) `0x1401ee5f0` · 주입기 `0x1401a3fc0`).

### 8b.2 그런데 텍스트는 그 멤버를 **레이아웃 결과로 덮어쓴다**

레이아웃(§5.3)이 끝난 직후 텍스트 빌드가 `call qword [rax+0x110]`(`0x1402575db`)로 가상함수
슬롯 `+0x110` = **`0x140258900`** 을 부른다. 그 함수 전체가 `+0x2f0` 계산이다:

```
0x140258906  cmp byte [rcx+0x328], 0        ; 이펙트 빌더 재진입 가드(1 이면 즉시 return)
0x140258916  rax = [rcx+0x5a8]              ; 레이아웃 결과 객체(§5.3)
0x140258927  xmm1 = [rax+0x98] - [rax+0x90] ; 잉크박스 maxX - minX
0x14025892f  xmm2 = [rax+0x9c] - [rax+0x94] ; 잉크박스 maxY - minY
0x140258949  (레이아웃이 없으면) xmm1 = xmm2 = 2.0
0x140258954  if ([rcx+0x320] > 0 || [rcx+0x304] & 0x10 || [rcx+0x594] & 2)   ; §8 과 **같은 세 게이트**
0x140258986      xmm4 = min(padding.x, 512.0); xmm3 = min(padding.y, 512.0)  ; [rcx+0x4e8]/[rcx+0x4ec]
0x14025896f  else xmm4 = xmm3 = 0
0x1402589a9  xmm4 += xmm4; xmm3 += xmm3     ; 양쪽에 붙으므로 2배
0x1402589b9  [rcx+0x2f0] = xmm1 + xmm4      ; size.x
0x1402589c1  [rcx+0x2f4] = xmm2 + xmm3      ; size.y
0x1402589f5  call [vtbl+0xb0] (cvttss2si 한 정수 폭/높이로 렌더 타깃 생성) …+0xb8 …+0xc0
```

**확정**: `size = (잉크박스 폭 + 2·clamp(padding.x,512), 잉크박스 높이 + 2·clamp(padding.y,512))`.
패딩 항은 §8 과 **같은 세 게이트**(이펙트 있음 / 오프스크린 합성 / `opaquebackground`) 하에서만
0 이 아니다. 폰트 메트릭 그 자체가 아니라 **워드랩·행제한까지 끝난 실제 잉크 박스**다
(`+0x90`–`+0x9c` 를 쓰는 곳이 `0x1401b2dec`–`0x1401b2e0c`, 레이아웃 말미다).

즉 이 값은 그리기와 히트가 **같은 수**를 쓴다 — 배경 박스 크기(§8 (b))도 잉크박스+패딩이다.

### 8b.3 `scene.json` 의 `text.size` 는 에디터가 써 넣은 그 값의 스냅샷이다

워크샵 정본 코퍼스는 텍스트 **1,597 / 1,597 전건**이 `size` 를 문자열로 저작한다
(`spec/corpus/scene-schema.json` `waple.unparsedObjectKeys`, distinct 684, range 2.0–8316.0).
최빈값이 **`"2.00000 2.00000"` 36건**인 것이 결정적이다 — 2.0 은 §8b.2 의 "레이아웃 결과가 없을 때"
폴백(`0x140258949`)이고 저작자가 손으로 넣을 값이 아니다. 즉 그 키는 **에디터가 자기 계산 결과를
직렬화해 둔 것**이고, 런타임은 로드 때 주입했다가 첫 레이아웃에서 **다시 덮어쓴다**.

→ 그래서 정적 텍스트에 한해 `text.size` 는 **WE 자신의 폰트 스택으로 잰 히트 상자**다.
   스크립트로 텍스트가 바뀌면 낡는다(실물은 매 레이아웃마다 재계산한다).

### 8b.4 Waple 이 이미 갖고 있는 등가물

`TextRasterizer.render` 가 돌려주는 `Raster.width`/`height` 가 §8b.2 의 잉크박스에 대응한다
(`ceil(줄별 폭 최대) + 2` × `줄높이 × 줄수 + 2`, 워드랩·`maxRows` 잘림 반영 후). 렌더러가 그것을
`GPUText.rasterWidth`/`rasterHeight` 로 이미 보관하고(`SceneRendererResources.rasterize`),
그리기 쿼드도 그 값 × `scale` 로 만든다 — 즉 **Waple 안에서 "그린 자리"는 이미 그 상자다.**

**남는 차이(정직하게)**:

| 차이 | 실물 | Waple |
|---|---|---|
| 패딩 항 | 게이트 하에서 `+2·clamp(padding,512)` | **0**(래스터에 패딩 개념이 없다). 워크샵 코퍼스 도달: `opaquebackground:true` 4/1,426 · `effects` 저작 450/1,597 · `colorBlendMode` 는 별도 — 즉 **이펙트 있는 텍스트에서 상자가 실물보다 작다** |
| 메트릭 | FreeType/HarfBuzz, 300 DPI | CoreText 캐스케이드(§G9/G10/G11 의 차이가 그대로 폭·높이에 실린다) |
| `anchor` | 모델 행렬 평행이동을 화면 가장자리로 스냅(§7.7) | 미구현 — 그리기도 안 하므로 Waple 안에서는 "그린 자리 = 클릭되는 자리"가 유지된다 |
| 가장자리 여백 | 없음 | `+2 px`(래스터 캔버스 여백) |

---

## 9. 런타임 텍스트 갱신

### 9.1 스크립트 바인딩이 전부다

`text` 는 타입 5(문자열) 디스크립터 하나뿐이고, 동적 텍스트는 **공통 프로퍼티 스크립트 래퍼**
(`{"value": ..., "script": ..., "scriptproperties": {...}}`)로 들어온다 —
`docs/re/scene-script-api.md` 가 다루는 그 메커니즘과 같은 것이고 텍스트 전용 경로가 아니다.

동봉 프리셋 3건이 실증한다:

| 프리셋 | `text.value` | 스크립트가 하는 일 |
|---|---|---|
| `assets/presets/clock/previewclock` | `"<Clock>"` | `new Date()` → `HH:MM(:SS)` 문자열 반환 |
| `assets/presets/clock/preview3dclock` | `"<3D Clock>"` | 시계 + `thisScene.createLayer` 로 그림자 레이어 생성, 커서 방향으로 `angles` 회전 |
| `assets/presets/countdown/previewcountdown` | `"Time until Christmas:"` | `scriptProperties.date` 까지 남은 시간 문자열 |

`update(value)` 가 문자열을 반환하면 그것이 `text` 가 된다. `dino_run` 의 두 라벨은 스크립트가
아니라 다른 레이어 스크립트가 `thisScene` 조회로 값을 넣는다(`text` 는 평문 `"00000"`).

### 9.2 `%H:%M` 같은 토큰 치환은 **없다** (배제)

바이너리에 `%H : %M` · `%H : %M : %S` · `%I : %M : %S %p` · `%m / %d / %y` 문자열이 있지만
(`0x14042be30` · `0x14042be50` · `0x14042be60` · `0x14042be68`), 이들은 **MSVC CRT 로케일 테이블**이다:

* 같은 `.rdata` 블록에 `%a %b %e %T %Y`(C 로케일 `%c`), `:AM:am:PM:pm`, `0123456789-`,
  `%.0Lf`, `0123456789ABCDEFabcdef-+Xx` 가 연속으로 놓여 있다 — `std::time_get`/`num_get`
  패싯의 상수표 배치 그대로다.
* 참조하는 함수는 `0x1402acb70` · `0x1402ad150` · `0x1402b2d90` · `0x1402b7c20` · `0x1404202b0`
  네댓 개이고, 전부 텍스트/폰트 서브시스템 바깥(`0x1402ac…`–`0x1404202b0` 대역)의 CRT 영역이다.
* 텍스트 디스크립터 29키 중 포맷 문자열을 받는 키가 없고, `GetLaidOutText` 는 받은 UTF-8 을
  그대로 UTF-32 로 펼칠 뿐 치환 루프가 없다.

**결론: WE 텍스트 레이어에 지원 토큰 목록 같은 것은 존재하지 않는다.** 시계·날짜는 100%
씬 스크립트가 만든다. (전수로 뽑을 토큰 테이블이 없다는 것이 이 항목의 답이다.)

---

## 10. 도달 실측

### 10.1 설치본 코퍼스 (`wallpaper_engine/` 186 씬 전수, 2026-08-21 측정)

텍스트 오브젝트가 있는 씬 **4개**, 오브젝트 **5개**. 오브젝트 판정은 Waple 의 팩토리 순서와
같게 했다(`image`/`particle`/`sprite` 가 **문자열**이 아니고 `text` 가 non-null) — `image: null`
을 든 preset 시계들이 여기서 빠지면 3오브젝트로 과소 집계된다(실제로 한 번 그렇게 셌다).
preview 판정은
`docs/re/scene-object-model.md` §1 규약(경로 세그먼트에 `preview`)을 그대로 쓴다.

| 씬 | preview? | 텍스트 오브젝트 |
|---|---|---:|
| `projects/defaultprojects/dino_run/scene.json` | non-preview | 2 |
| `assets/presets/clock/previewclock/scene.json` | preview | 1 |
| `assets/presets/clock/preview3dclock/scene.json` | preview | 1 |
| `assets/presets/countdown/previewcountdown/scene.json` | preview | 1 |

텍스트 오브젝트가 가진 키는 **34개**(공통 키 포함, 전건이며 자르지 않았다).
`F`/`O` = 파일/오브젝트 수, `npF`/`npO` = non-preview 분.

| 키 | F | O | npF | npO |
|---|---:|---:|---:|---:|
| `anchor` `backgroundcolor` `color` `font` `horizontalalign` `id` `name` `opaquebackground` `origin` `padding` `pointsize` `scale` `size` `text` `verticalalign` `visible` (16키) | 4 | 5 | 1 | 2 |
| `alpha` `angles` `colorBlendMode` `copybackground` `image` `locktransforms` `model` `parallaxDepth` `particle` `perspective` `solid` (11키) | 3 | 3 | 0 | 0 |
| `backgroundbrightness` `blockalign` `depthtest` `limitrows` `limituseellipsis` `limitwidth` `maxrows` `maxwidth` (8키) | 1 | 2 | 1 | 2 |

**동봉 도달 0인 텍스트 디스크립터 키는 12개**이고 아래가 전건이다(자르지 않았다):
`spacing` · `msdf` · `outline` · `blur` · `dropshadow` · `outlinethickness` · `outlinecolor` ·
`blursize` · `dropshadowsize` · `dropshadowopacity` · `dropshadowcolor` · `dropshadowoffset`.
즉 §4.2 의 29키 중 **17키가 동봉에 도달하고 12키는 도달 0** 이다.

### 10.1b 리포 동봉 코퍼스 (`Sources/WapleRender/Resources/WEAssets/`, 172 씬 전수, 2026-08-21 측정)

설치본과 **다른 범위**다(172 vs 186) — 라벨을 반드시 구분해서 읽어라. 텍스트 오브젝트는
**3씬 · 3오브젝트**이고 **전건 preview**(non-preview 0)다.

| 씬 | 텍스트 오브젝트 | `pointsize` | `padding` |
|---|---:|---|---|
| `presets/clock/previewclock/scene.json` | 1 | 24.0 | 0 |
| `presets/clock/preview3dclock/scene.json` | 1 | 24.0 | 0 |
| `presets/countdown/previewcountdown/scene.json` | 1 | 24.0 | 0 |

### 10.1c 기본값 3종의 **도달** — 세 범위 전부 0 (2026-08-21 측정)

"기본값에 의존하는(= 그 키를 생략한) 텍스트 오브젝트 수" 다. 이게 0 이면 기본값을 바꿔도
**관측 가능한 변화가 없다**.

| 키 | 리포 동봉 172씬 (텍스트 3) | 설치본 186씬 (텍스트 5) | 워크샵 정본 코퍼스 (텍스트 1,597) |
|---|---:|---:|---:|
| `pointsize` 생략 | **0** / 3 | **0** / 5 | **0** / 1,597 |
| `padding` 생략 | **0** / 3 | **0** / 5 | **0** / 1,597 |
| `outlinethickness` 생략 | 3 / 3 | 5 / 5 | 1,594 / 1,597 |

`outlinethickness` 만 생략 도달이 있으나, 실물 소비가 `outline`(플래그 `+0x518` bit1) 게이트
하에만 있고(`0x1402574df` `test cl,2`) 세 범위 전부 `outline` 이 **미저작 또는 false** 다
(워크샵의 `outline:true` 3건은 `outlinethickness` 를 명시한다). 따라서 이 기본값 교체도
**그림이 바뀌는 씬은 0건**이다 — 규약 정합만의 변경이다.

워크샵 수치의 출처는 §10.2 와 같은 `spec/corpus/scene-schema.json` 이고 이번에 다시 읽었다
(`text.pointsize.n = 1597`, `text.padding.n = 1597`, `text.outlinethickness.n = 3`,
`scene.corpus.population.scenes = 162`).

### 10.2 워크샵 코퍼스 (`spec/corpus/scene-schema.json`, 162씬 · 텍스트 1,597 오브젝트 / 123씬)

| 키 | n | 씬 | 타입 분포 / 값 분포 |
|---|---:|---:|---|
| `font` | 1597 | 123 | str; distinct 136 |
| `pointsize` | 1597 | 123 | float 918 · **dict 679**(바인딩); 범위 **3.0 – 250.97** |
| `horizontalalign` | 1597 | 123 | center 1334 · left 164 · right 99 |
| `verticalalign` | 1597 | 123 | center 1482 · top 86 · bottom 29 |
| `padding` | 1597 | 123 | **int 1426 · str 171**; 범위 0 – 300 |
| `text` | 1597 | 123 | **dict 1381**(스크립트) · str 216 |
| `limitwidth` | 1594 | 121 | false 1434 · **true 160** |
| `limitrows` | 1594 | 121 | false 1418 · **true 176** |
| `limituseellipsis` | 1594 | 121 | false 1512 · **true 82** |
| `maxrows` | 1594 | 121 | 1:1582 · 2:4 · 3:2 · 4:2 · 5:2 · 13:1 · 30:1 |
| `maxwidth` | 1594 | 121 | float 1562 · dict 32; 10.0 – 7294.48 |
| `anchor` | 1429 | 111 | none 1361 · center 50 · left 8 · right 5 · top 3 · bottomright 1 · topright 1 |
| `backgroundcolor` | 1426 | 110 | distinct 3 |
| `opaquebackground` | 1426 | 110 | false 1422 · **true 4** |
| `backgroundbrightness` | 1424 | 109 | 전건 1.0 |
| `blockalign` | 1423 | 108 | false 1410 · **true 13** |
| `depthtest` | 1391 | 101 | **전건 `"enabled"`** |
| **`spacing`** | **171** | **13** | **전건 `"0.00000 0.00000"` 문자열(vec2)** |
| `outline` | 3 | 1 | 전건 true |
| `outlinecolor` | 3 | 1 | 3종 |
| `outlinethickness` | 3 | 1 | 범위 1.25 – 9.72, distinct 3 |
| `msdf` `blur` `blursize` `dropshadow` `dropshadowsize` `dropshadowopacity` `dropshadowcolor` `dropshadowoffset` | **0** | 0 | — |

`padding` 의 `str` 171건과 `spacing` 의 171건이 같은 수인 것은 우연이 아니다 — 같은 저작
도구가 두 키를 `"x y"` 벡터 문자열로 함께 내보냈다.

> 이 절의 수치는 **이번에 새로 측정한 것이 아니라** 리포에 정본화된
> `spec/corpus/scene-schema.json` 에서 읽은 것이다(§1). 워크샵 트리가 이 머신에 없다.

---

## 11. Waple 갭과 착지 지점

측정 시점 2026-08-21. 줄 번호는 흔들릴 수 있으니 심볼로 찾아라.

| # | 갭 | 파일:줄 | 실물 | 착지 지점 제안 |
|---:|---|---|---|---|
| ~~G1~~ **닫힘** | `pointsize` 기본 16 | `SceneDocument.swift` `parseText` | **32.0** | **2026-08-21 반영** — `?? 32`. 세 범위 전건이 키를 갖고 있어(§10.1c) 그림이 바뀌는 씬 0건. 테스트 `SceneDocumentTests.testTextLayerDefaultsMatchEngineConstructor` 가 VA 와 함께 잠갔다 |
| G2 | `pointSize` 상한 8192 | `Sources/WapleRender/TextRasterizer.swift:12` | **256 pt 클램프**(`0x1401b054a`), 하한 1 pt | `maxPointSize` 를 상한 클램프(reject 아님)로 바꾸고 256 으로. 워크샵 최대가 250.97 이라 도달 직전이다 |
| G3 | `spacing` 미소비 | `SceneDocument.swift:2227` 는 파스, `TextRasterizer.render` 에 인자 없음 | 자간=어드밴스에 px 가산 · 행간=줄높이에 px 가산 | `render(...)` 에 `spacing: Vec2` 추가 → 자간은 `kCTKernAttributeName`(글리프별 가산이라 근사) 또는 CTRun 재배치, 행간은 `lineH + spacing.y`. 도달은 워크샵 171건이지만 **전건 (0,0)** 이라 회귀 위험 0 |
| ~~G4~~ **부분 닫힘** | `padding` 기본·클램프 | `SceneDocument.swift` `parseText` | 기본 **(32,32)**, 축당 **512 클램프**, `opaquebackground` 등 게이트 하에서만 유효 | **기본값만 반영**(`?? Vec2(32,32)`). 512 클램프는 **소비처가 없어 미반영** — 소비를 구현할 때 같이 넣어라(안 그러면 저장만 하는 값에 상한이 생겨 왕복이 깨진다) |
| ~~G5~~ **부분 닫힘** | `outlinethickness` 기본·하한 | `SceneDocument.swift` `parseText` | 기본 **4.0**, outline 켜지면 `max(값,1.0)` | **기본값만 반영**(`?? 4`). `max(1.0)` 은 소비 시점 규칙이라 래스터 구현과 함께 |
| G6 | 이펙트 8키 미파스 | `parseText` 전역 | `msdf`(`+0x518` bit0) · `blur`(bit2) · `dropshadow`(bit3) · `blursize` `+0x530`(기본 6) · `dropshadowsize` `+0x534`(기본 6) · `dropshadowopacity` `+0x538`(기본 1) · `dropshadowcolor` `+0x544` · `dropshadowoffset` `+0x53c`(기본 (4,4)) | `SceneTextLayer` 에 필드 8개 추가 + `parseText` 에 파스 8줄. 동봉·워크샵 도달 0 이라 **파스만으로는 그림이 안 바뀐다** — 갭을 문서화된 상태로 닫는 값싼 수 |
| ~~G7~~ **주석 닫힘** | outline 렌더 미구현인데 주석은 구현했다고 말함 | `SceneDocument.swift` `SceneTextLayer.outline` 선언부 | 셰이더 `OUTLINE_ENABLED` 콤보 실재 | **2026-08-21 주석 정정 완료**(렌더는 여전히 미구현). 구현한다면 `TextRasterizer` 에서 CoreText 스트로크(`kCTStrokeWidthAttributeName` 음수 = fill+stroke)로 근사하거나, 제대로 하려면 MSDF 파이프라인이 필요하다 |
| G8 | 배경 박스 미구현 | 파스만(`:2240`, `:2241`, `:2245`) | `fontbackground.json`(`flat`) 쿼드, 색 = `backgroundcolor × backgroundbrightness`, 크기 = 잉크박스+패딩 | 텍스트 쿼드 앞에 단색 쿼드 하나. **동봉 5건은 전건 `false`**, 워크샵도 1,426건 중 `true` 4건뿐이라 우선순위 낮음 |
| G9 | 워드랩 알고리즘 차이 | `TextRasterizer.swift:49` | 클러스터 단위 그리디(공백 앞에서만 회피) | UAX#14 단어 랩은 **더 예쁘지만 실물과 다르다.** 긴 단어가 있을 때 줄 수가 달라진다 → `maxrows` 잘림·말줄임 결과가 갈린다. 실물 재현이 목표면 `CTTypesetterSuggestClusterBreak` 로 바꾼다 |
| G10 | 수직 정렬 기준 | `TextRasterizer.swift:104`(`lineH`) + `SceneRendererResources.swift:2374` 부근 | ascender/descender 메트릭 기반(§7.5) | `leading` 을 줄높이에서 빼고 ascender 기준으로 베이스라인을 잡으면 실물에 붙는다 |
| G11 | 양쪽 정렬 방식 | `TextRasterizer.swift:85` `CTLineCreateJustifiedLine` | **공백 어드밴스만** 늘린다 | CoreText 는 글자 사이도 늘릴 수 있다. 공백 없는 행(CJK)에서 실물은 **아무 것도 안 하는데** Waple 은 늘린다 |
| G12 | 폴백 체인 | 없음(CoreText 캐스케이드) | 8단 고정 순서, 인덱스 4(다섯 번째)가 **동봉 `fonts/TwemojiMozilla.ttf`** | 최소한 이모지만이라도 동봉 Twemoji 를 우선 등록하면 WE 와 같은 그림이 된다. `WEAssets/fonts/TwemojiMozilla.ttf` 가 이미 리포에 있다(바이트 동일 확인) |
| ~~G13~~ **주석 닫힘** | `anchor` 의미 | `SceneDocument.swift` `SceneTextLayer.anchor` 선언부 | **레이어 모델 행렬 전체**에 화면 가장자리 오프셋(가상함수 `0x1402585c0`, vtable `0x140491950` 슬롯 `0x1404919f8`, 평행이동 행 `[rdx+0x30]` 갱신 `0x140258633`) | 주석 정정 + 필요 시 `SceneRendererFrameEncoder` 의 텍스트 트랜스폼에 화면 사각형 기반 오프셋 |
| G14 | `systemfont_segoe`/`sansserif` | `TextRasterizer.swift:228` 이 둘 다 시스템 UI 폰트로 보냄 | `segoeui.ttf` / `micross.ttf`(Microsoft Sans Serif) | macOS 에 둘 다 없으니 현 동작이 합리적이다. **갭이 아니라 의도적 대체**로 주석에 못박기만 하면 된다 |
| ~~G16~~ **닫힘** | `limitwidth`/`limitrows` 미체크 시 저작값 소실 | `SceneDocument.swift` `parseText` | 게이트(`+0x594` bit2/bit3)와 값(`+0x508` float / `+0x510` int)이 **서로 다른 멤버**이고 적용 루프(`0x1401731d0`)가 키마다 따로 돌아 게이트와 무관하게 값이 착지한다 | **2026-08-21(AV) 반영** — 저장 프로퍼티 `limitWidth`/`maxWidthValue`/`limitRows`/`maxRowsValue` 넷으로 가르고 `maxWidth`/`maxRows` 는 계산 프로퍼티로 남겼다(래스터·워드랩 소비부 무수정 = 무회귀). 남은 배선은 `SceneRenderer.sceneScriptLayers(from:)` 의 4줄 — `d.limitRows = text.limitRows` / `d.maxRows = text.maxRowsValue` / `d.limitWidth = text.limitWidth` / `d.maxWidth = text.maxWidthValue`(지금은 `text.maxRows != nil` 로 되읽어 미체크 저작값을 못 싣는다) |
| G17 | **텍스트 오브젝트의 커서 히트 상자가 없다** | `Sources/WapleRender/SceneRenderer.swift` `buildPointerTargets(doc:)` 가 텍스트를 `.geometryUnknown` 으로 떨어뜨린다 | `size` 멤버 `+0x2f0` = 잉크박스 + 2·clamp(padding,512)(§8b), 히트 함수는 이미지와 동일한 `0x14019dbb0` | `GPUText.rasterWidth`/`rasterHeight`(이미 `textLayers` 에 있고 `:1793` 에서 `:1926` 보다 **먼저** 만들어진다)로 쿼드를 만든다. 정확한 패치안은 §8b.4 아래 문단 |
| G15 | **텍스트 레이어의 `pointsize`/`font` 가 씬 스크립트에 배선되지 않는다** | `Sources/WapleRender/SceneRenderer.swift` `sceneScriptLayers(from:)` 의 `textLayers` 블록 | `ITextLayer.pointsize`/`font`(d.ts:1606·1611)는 디스크립터 실값 | `SceneScriptLayerDescriptor(...)` 에 `pointSize: text.pointSize, font: text.font` 를 넘긴다. 지금은 두 인자를 **아예 안 넘겨서** Swift 기본값(`TextScriptEngine.swift:35` 의 `pointSize: Float = 16`, `font: "systemfont_arial"`)이 그대로 들어가고, 그래서 모든 텍스트 레이어에서 `thisLayer.pointsize` 가 저작값과 무관하게 16 을 돌려준다. 기본 파스값이 32 로 바뀐 지금은 그 16 이 어느 쪽 규약도 아니다. `SceneScriptAPISurfaceTests` 는 디스크립터를 **직접** 만들어 검증하므로 이 배선 누락을 못 잡는다 |

**우선순위 제안**: ~~G1 · G5 · G4~~(기본값 3종 — 2026-08-21 반영) → ~~G7 · G13~~(주석 정정 완료) →
~~G15~~(2026-08-21 클러스터 U 가 배선) → ~~G16~~(2026-08-21 클러스터 AV) →
**G17**(히트 기하 — 배선하면 텍스트 바인딩 스크립트 타겟팅이 열린다) →
G6(파스 8키) → G3(spacing 소비) → G9/G10/G11(레이아웃 정합) → G8/G12(렌더 확장).

### 11.1 G17 정확한 패치안 (`SceneRenderer.swift` — 이 레인 소유 밖)

**새 수식을 쓰면 안 된다 — 그리기 경로가 이미 쓰는 세 함수를 그대로 재사용한다.**

1. `textLayers = buildTexts(...)`(`:1793`)가 `buildPointerTargets(doc:)`(`:1926`)보다 **먼저** 돈다.
2. `GPUText.rasterWidth`/`rasterHeight` 에 스케일 전 글리프 픽셀 크기가 이미 있다
   (`SceneRendererResources.rasterize`).
3. `SceneRendererFrameEncoder.textAlignmentString(h:v:)` 가 텍스트의
   `horizontalAlign`/`verticalAlign` 를 이미지 레이어와 **같은 `alignment` 문자열**로 바꾼다.
   그 함수 주석이 "`quadVertices`/`alignedCenter` 규약과 정확히 일치" 를 이미 못박아 뒀고,
   `encodeText` 의 애니 재계산 경로(`:1654`–`:1656`)가 정확히
   `quadVertices(origin:, size: Vec2(t.rasterWidth, t.rasterHeight), scale:, angleZ:, alignment: align, …)`
   로 텍스트 쿼드를 만든다. 히트 쿼드도 **같은 인자**를 `layerHitQuad` 에 주면 회전·음수 스케일·
   앵커까지 자동으로 정합한다(이미지 경로와 두 갈래로 갈리지 않는다).

`buildPointerTargets(doc:)` 의 텍스트 분기(현재 `.geometryUnknown` 으로 떨어지는 자리):

```swift
// 종전
guard i >= 0, i < doc.layers.count else {
    return PointerTarget(engine: pair.engine, scope: .geometryUnknown, parallaxDepth: none)
}

// 제안 — 텍스트 디스크립터 인덱스는 doc.layers.count + uid(F743/S-34, buildTexts 와 동일 규약)
guard i >= 0 else { return PointerTarget(engine: pair.engine, scope: .geometryUnknown, parallaxDepth: none) }
if i >= doc.layers.count {
    let u = i - doc.layers.count
    // 래스터가 없으면(빈 텍스트 = 드로우 스킵) 상자를 만들 근거가 없다 → 종전 전건 배달 유지
    guard u < doc.texts.count, u < textLayers.count,
          textLayers[u].rasterWidth > 0, textLayers[u].rasterHeight > 0 else {
        return PointerTarget(engine: pair.engine, scope: .geometryUnknown, parallaxDepth: none)
    }
    let t = doc.texts[u], g = textLayers[u]
    // 히트 순회의 첫 관문은 텍스트도 `solid`(bit13) 다 — `0x14018a02d` 는 타입을 안 가린다
    guard t.isSolid else {
        return PointerTarget(engine: pair.engine, scope: .unhittable, parallaxDepth: none)
    }
    // AV: 실물은 `size` 멤버 `+0x2f0`(= 잉크박스 + 2·clamp(padding,512), `0x140258900`)을 이미지와
    // **같은** 상자 함수 `0x14019dbb0` 에 먹인다(`0x14019dd8a` 가 `+0x2f0` 을 읽고 `0x14019de4b`
    // 가 ±0.5). 텍스트 오브젝트의 타입 가상함수는 4(`0x1400fde90`)이고 순회는 1 과 4 를 같은
    // 분기로 모은다(`0x14018a044`–`0x14018a050`). Waple 의 등가물이 래스터 픽셀 크기다.
    let align = Self.textAlignmentString(h: t.horizontalAlign, v: t.verticalAlign)
    let quad = Self.layerHitQuad(origin: t.origin,
                                 size: Vec2(x: g.rasterWidth, y: g.rasterHeight),
                                 scale: t.scale, angleZ: t.angleZ, alignment: align)
    return PointerTarget(engine: pair.engine, scope: .object(quad), parallaxDepth: t.parallaxDepth)
}
```

**넣기 전에 반드시 읽을 것 — 이 상자는 실물보다 작을 수 있다.** §8b.4 의 차이표대로 패딩 항이
빠져 있고(이펙트가 붙은 텍스트에서 실물은 축당 `+2·padding`, 기본 32 면 `+64 px`),
CoreText/FreeType 메트릭 차이도 남는다. 좁히는 방향의 변경이므로 **틀리면 그 텍스트에 붙은
스크립트가 커서 이벤트를 통째로 못 받는다**. 안전판으로 다음 중 하나를 같이 넣는 것을 권한다.

1. 패딩을 상자에만 더한다 — `size += 2 * min(text.padding, 512)` 를 §8 의 세 게이트 중
   Waple 이 아는 둘(`!t.effects.isEmpty` · `t.opaqueBackground`)로 켠다. 그러면 실물보다
   **작아지지는** 않는다(세 번째 게이트는 켜지는 쪽으로만 틀린다).
2. 그리고/또는 상자에 소량의 여유(예: 축당 `+2 px` 래스터 캔버스 여백분)를 남긴다.

`SceneSharedScriptTests:538` 의 `simulateCursorClick(x: 1, y: 1)` 은 이 배선이 들어가는 순간
**load-bearing 이 된다**(그 스크립트는 텍스트 오브젝트에 붙어 있다) — 같이 고쳐야 한다.
`pointer-interaction.md` §7.3 ①의 주석이 그 사실을 이미 못박아 두었다.

---

## 12. 배제한 가설

1. **"폰트 로딩이 `resourceutil64.dll` 에 있을 것"** — 아니다. `bin/resourceutil64.dll` 에
   FreeType/HarfBuzz/msdf 문자열이 0건이고, `bin/scenescript64.dll` 도 마찬가지다.
   `wallpaper64.exe` 가 `FREETYPE_PROPERTIES` · `HB_SHAPER_LIST` · `_msdf` 를 모두 갖고 있다.
2. **"MSDF 파라미터가 자산(JSON)에 박혀 있을 것"** — 아니다. `assets/materials/fonts/*.json`
   에는 `combos: {MSDF:1, COLORFONT:1}` 밖에 없고 range/px 비율은 전부 코드 상수다
   (셰이더 쪽 24.0 은 `0x1401b3db8`, 생성 쪽 24/12 는 `0x1401af433`/`0x1401af427`).
3. **"`assets/fonts/` 에 WE 전용 폰트 포맷이 있을 것"** — 아니다. 전부 표준 sfnt(§2.1).
   아틀라스는 런타임 산물이고 디스크에 없다.
4. **"`%H:%M` 류 토큰 치환이 있을 것"** — 아니다. 그 문자열들은 MSVC CRT 로케일 패싯이다(§9.2).
5. **"`text.spacing` 이 스칼라"** — 아니다. 디스크립터 타입 1 = vec2 이고 두 성분이 각각
   자간·행간으로 **서로 다른 곳에서 소비된다**(§7.3). `docs/re/scene-object-model.md` §0 #13 이
   지적한 갭이 이번에 소비처까지 확정됐다.
6. **"`depthtest` enum 은 disabled=0"** — 아니다. `enabled`=0 · `disabled`=1 이다(§4.4).
   생성자 기본이 0 이므로 **텍스트의 기본 깊이 상태는 "켜짐"** 이다.
7. **"outline/blur/dropshadow 는 비트맵 경로에서도 된다"** — 아니다. 비MSDF 머티리얼에는
   콤보 슬롯 자체가 없고(§6.4), 이펙트가 하나라도 켜지면 MSDF 로 강제 전환된다(§6.1).

### 확정 못 한 것 (`[미해결]`)

* `+0x594` **bit0** 의 의미 — 생성자가 1 로 켜지만 등록된 5개 bool 중 어느 것도 아니다.
  (이번에 `opaquebackground` = **bit1** 은 세터 마스크로 확정했다 — §4.5④-a. bit0 은 여전히 미상.)
* **[E 레인 추가]** WE 오브젝트 팩토리의 `text` 분기는 `find(obj,"text") != null` 만 본다
  (`0x140190343`–`0x14019034b`) — `image`/`light` 분기와 달리 **값의 태그를 확인하지 않는다**.
  즉 `"text": null` 인 오브젝트도 실물은 텍스트로 만들고, Waple 은 `contentValue(...) != nil`
  이라 만들지 않는다. **도달은 0 이다**(설치본 294 오브젝트 · 리포 동봉 203 오브젝트 전수에서
  `"text": null` 0건)이므로 이번에 맞추지 않았다. 맞출 때는 빈 텍스트 레이어가 생기는 쪽이
  실물이라는 점만 기억해라.
* `FontKey+0x18`(해상도 스케일 플래그)를 1 로 넣는 호출자 — 씬 텍스트 레이어는 항상 0 이다.
  UI/에디터 텍스트 경로로 **보이나** 확인 못 했다.
* **[AV 추가] Waple 의 래스터 상자와 실물 잉크박스의 실제 오차를 못 쟀다.** §8b 는 실물 쪽 식을
  확정했지만, 같은 문자열·같은 폰트에서 FreeType(300 DPI)과 CoreText 가 내는 폭·높이가 몇 % 나
  갈리는지는 **이 컨테이너에서 측정할 수 없다**(WE 를 실행할 수 없고, 워크샵 코퍼스도 없다 —
  공통 브리프 함정 19). `spec/corpus/scene-schema.json` 의 `text.size` 분포(1,597건, range
  2.0–8316.0)와 우리 래스터 크기를 대조하려면 코퍼스가 있는 환경이 필요하다.
* **[AV 추가] `[this+0x304] & 0x100` 을 켜는 자리** — §8 표의 오프스크린 합성 게이트 세 갈래 중
  하나인데, 그 비트를 세우는 코드는 못 찾았다(등록표의 `+0x304` 네 키는 bit6/8/14/15 다).
* `scene+0x118 & 0x400` 과 `& 0x2000` 의 의미 — 전자는 텍스트/배경의 depth 머티리얼 선택을
  무효화하고(`0x1402582ff`), 후자는 다른 분기를 탄다(`0x1402582a8`). 씬 렌더 모드 플래그로
  보이지만 확정 못 했다.
* **워드랩의 공백 경계 재추적 유무**(§7.2) — 찾지 못했다. 찾은 코드만 보면 클러스터 단위
  그리디다. 실물 스크린샷 대조로 확정하는 것이 확실하다.
* `0x1401b120c`–`0x1401b1238` 이 글리프 정점 속성 `+0x94` 에 넣는
  `max(u16[atlas+0x1a],1) × 12 × 0.03125` 의 의미 — MSDF 관련 스케일로 **보이나** 소비처를
  못 짚었다.
* 컬러 아틀라스 슈퍼샘플 배수 `[atlas+0x38]` 이 1 이 아닌 경로가 있는지 — 이번에 본 호출은
  전부 1 이다(`0x1401b08a4`).

---

## 부록 A — 재현 절차

전제: 스크래치패드에 `wpe.py`(PE/pdata 헬퍼) · `vdis2.py`(capstone 디스어셈블러)가 있고
`BIN` 이 `wallpaper64.exe` 를 가리킨다.

```bash
# 1) 셰이더·머티리얼 평문 — x86 파기 전에 여기부터
cd wallpaper_engine
cat assets/shaders/font.frag                       # median/ScreenPxRange/MSDF_RANGE/COLORFONT
for f in assets/materials/fonts/*.json; do echo "== $f"; cat "$f"; done

# 2) 폰트 자산 바이트
python3 - <<'PY'
import struct,os
for f in sorted(os.listdir('assets/fonts')):
    if not f.lower().endswith(('.ttf','.otf','.ttc')): continue
    d=open('assets/fonts/'+f,'rb').read()
    n=struct.unpack_from('>H',d,4)[0]
    tabs=[d[12+16*i:16+16*i].decode('latin1') for i in range(n)]
    print(f, d[:4], n, len(d), sorted(tabs))
PY

# 3) 디스크립터 등록자 — 29키 · 타입 · 멤버 · 람다
python3 -c "
import sys; sys.path.insert(0,'.')
from vdis2 import dis; dis(0x140258ca0, 0x14025a713)" > TXTREG.asm
grep -nE 'lea rcx, \[rbx \+ 0x68\]|mov dword ptr \[rbx \+ 0x3[04]\]' TXTREG.asm

# 4) 생성자 기본값
python3 -c "
import sys; sys.path.insert(0,'.')
from vdis2 import dis; dis(0x140256ae0, 0x140256d16)"

# 5) FontKey 조립 + 더티 체크
python3 -c "
import sys; sys.path.insert(0,'.')
from vdis2 import dis; dis(0x140256f20, 0x1402577d6)"

# 6) 폰트 획득 · MSDF 판정 · 캐시 이름 · 레이아웃 (거대 함수 — 파일로 받아 grep)
python3 -c "
import sys; sys.path.insert(0,'.')
from vdis2 import dis; dis(0x1401b0410, 0x1401b323b)" > FG.asm
grep -nE '0x2026|0x100002200|cmp dword ptr \[rbx\], 0xa|r13 \+ 0x(10|14|1a|1c|4c|50|54)' FG.asm

# 7) msdfgen 파라미터
python3 -c "
import sys; sys.path.insert(0,'.')
from vdis2 import dis; dis(0x1401ae080, 0x1401afdfb)" | grep -nE 'f32=(12|24|32|256)\.0|f64=3\.0'

# 8) 머티리얼·콤보·RenderVar
python3 -c "
import sys; sys.path.insert(0,'.')
from wpe import merged
from vdis2 import dis
m=merged(0x1401b3430); dis(m[0], m[1])" | grep -E 'materials/fonts|0x1b3b60'
python3 -c "
import sys; sys.path.insert(0,'.')
from vdis2 import dis; dis(0x1401b3b60, 0x1401b3f79)"

# 9) 테이블 덤프 (systemfont 8 · 폴백 8 · anchor 점프테이블 10)
python3 - <<'PY'
import sys,struct; sys.path.insert(0,'.')
from wpe import pe
S=lambda a: pe.read(a,48).split(b'\x00')[0].decode()
for i,va in enumerate(range(0x140484cc0,0x140484d80,0x18)):
    a,b,c=struct.unpack('<QQQ',pe.read(va,24)); print('sysfont',i,S(a),S(b),S(c))
for i,va in enumerate(range(0x140484c40,0x140484cc0,0x10)):
    a,b=struct.unpack('<QQ',pe.read(va,16)); print('fallback',i,S(a),b)
b=pe.read(0x1402588d4,40)
for i in range(10):
    print('anchor',i,hex(0x140000000+struct.unpack_from('<I',b,i*4)[0]))
PY

# 10) 동봉 도달 실측
python3 - <<'PY'
import json,os,collections
F,O=collections.Counter(),collections.Counter(); files=set()
for r,_,fs in os.walk('.'):
    for n in fs:
        if n not in ('scene.json','gifscene.json'): continue
        p=os.path.join(r,n); j=json.load(open(p,encoding='utf-8-sig'))
        objs=[o for o in j.get('objects',[]) if 'text' in o]
        if not objs: continue
        files.add(p)
        for o in objs:
            for k in o: O[k]+=1
        for k in {k for o in objs for k in o}: F[k]+=1
print(len(files),'scenes', sum(O[k] for k in ['text']),'objects')
for k,v in O.most_common(): print(k,F[k],v)
PY
```
