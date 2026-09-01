# 비디오·GIF·스프라이트시트 재생 — WE 미디어 레이어 전표

대상: `wallpaper64.exe` 2.8.42 (imagebase `0x140000000`, md5 `438cb215f20a8f6c38f57fbc3d9da588`),
`bin/mediaextensions64.dll`, `bin/scenescript64.dll`, `bin/winrtutil64.exe`,
설치본 `assets/scenes/{videoplayer,gifs}` · `projects/templates/gif`, 동봉 사본
`Sources/WapleRender/Resources/WEAssets/`.

**이 문서가 다루지 않는 것(이미 있는 문서로 넘긴다 — 중복 금지):**

| 주제 | 소유 문서 |
| --- | --- |
| MF 파이프라인·GUID 전수·색공간 위임·스톨 워치독·코퍼스 145종 비디오 통계 | `spec/engine/media.json` (`engine.media.*`, `corpus.video.*`) |
| `project.json` 리더·확장자→타입 분류기·`.gif` 마운트 분기 | `docs/re/package-format.md` §4.3 · §5.3 |
| `.tex` TEXS 섹션·`.tex-json` 키 히스토그램·프레임타임 사상 | `docs/re/tex-format.md` §4 · §5 |
| `SPRITESHEET` 콤보의 셰이더 쪽 소비 | `docs/re/shader-combos.md` |
| `combine_video_hdr` 합성 슬롯 | `docs/re/tonemapping.md` §2.4 · `docs/re/scene-postprocessing.md` §3.3·§4 |
| `playbackaudio` 정책 열거·판정 순서 | `Sources/WaplePolicy/PlaybackPolicy.swift` |
| WASAPI 루프백 캡처 → FFT → 밴드 | `docs/re/audio-capture.md` |
| `nopadding`/`spritesheetrefreshsync`/`orthogonalprojection.auto`/`keepaspect` 의 **파서** 명령 단위 | `Sources/WapleCore/SceneDocument.swift` 선언부 주석 |

이 문서는 그 사이에 비어 있던 것 — **저작 형태 → 진입 경로 → 스크립트 표면 → 오디오 게이트**의
접합부와, 그것들이 Waple 에서 어디에 착지하는지 — 를 채운다.

---

## 0. 결론

1. **WE 의 "비디오 월페이퍼"는 씬이 아니라 창이다.** `type:"video"` 프로젝트는 전용
   `VideoWallpaper` 창(HWND)에서 Media Foundation 이 그린다. `assets/scenes/videoplayer/scene.json`
   은 그 **다섯 프레임워크 후보 중 `mfEngine`/`mfEngine.muted` 둘만**을 위한 합성 셸이다 —
   씬 마운트 함수 `0x14011eea0` 의 호출자가 그 두 팩토리(`0x140104240`·`0x1401041d0`)뿐이고,
   `mf`(EVR)·`mf.muted`·`dshow.lav.vmr9`(VMR9)는 HWND 에 직접 그려 씬을 아예 거치지 않는다(§4.2).
2. **GIF 월페이퍼는 비디오가 아니라 스프라이트시트 씬이다.** `.gif` 를 고르면 WE 는
   `assets/scenes/gifs` 템플릿을 `projects/temp/gifs/<stem>/` 로 **복사**하고 원본 GIF 를
   `materials/background.gif` 로 넣은 뒤 그 폴더를 마운트한다(`0x140113c80`, §3.2). 디코드는
   텍스처 파이프라인의 몫이고 미디어 스택은 관여하지 않는다.
3. **`videoplayer`/`gifs` 두 씬에 네 키가 몰린 이유는 하나다** — 둘 다 **크기가 런타임에 정해지는
   외부 프레임 소스를 전면에 붙이는 셸**이기 때문이다. `nopadding`(패딩 금지) ·
   `orthogonalprojection.auto`(정사영 크기를 출력 뷰포트가 정함) · `keepaspect`(슬롯에 늘이지 말고
   비율 유지) · `spritesheetrefreshsync`(시트 진행을 씬 전역 클록에 고정)는 전부 그 한 조건의
   따름정리다(§2.2).
4. **`MediaPlaybackEvent` 는 월페이퍼 비디오와 무관하다.** 그것은 **시스템 미디어 세션**(Spotify 등)
   상태를 스크립트에 배달하는 이벤트이고, 원천은 `bin/winrtutil64.exe -mediainterface` 의
   `Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager` 다(§6.1).
   읽기 전용 — 필드 `state` 하나 + 상수 3개, 메서드 0개. **스크립트가 재생을 제어하는 표면은
   따로 있다**: `IImageLayer.getVideoTexture()` → `IVideoTexture`(play/pause/stop/setCurrentTime/
   loop/rate/addEndedCallback). `volume` 은 **없다**(§6.2).
5. **런타임 스프라이트시트 시퀀스 객체**(`0x140177f70`–`0x1401786f1`)는 `.tex-json` 의
   `spritesheetsequences[]` 가 `.tex` TEXS 로 컴파일된 뒤의 **재생 상태 구조체**다. 필드 오프셋을
   전부 확정했다(§7.2) — `+0x38` 프레임타임, `+0x3c` 현재시각, `+0x40` duration, `+0x44` 플래그,
   `+0x48` frameCount, `+0x68` name. `fps` 는 저장값이 아니라 `1 / frametime` 파생값이다.
6. **비디오 오디오는 기본 출력 엔드포인트로 나간다.** 전용 엔드포인트/카테고리 속성이 없으므로
   WE 자신의 WASAPI **루프백** 캡처가 그 소리를 다시 집어 들인다 — 즉 비디오 사운드는
   오디오 반응 스펙트럼에 **섞인다**(§8.3).
7. 동봉·설치본에서 `type:"video"` 프로젝트는 **0건**이다. 비디오 기계는 사용자가 직접 넣은
   파일로만 도달한다. GIF 도 마찬가지로 템플릿만 있고 실 프로젝트는 0건이다(§1).
8. **[2026-08-21] 프레임워크 레지스트리의 플래그 워드는 두 바이트가 각각 다른 것을 뜻한다.**
   하위 = "Media Foundation 을 요구한다"(`mfplat.dll` 프로브 실패 시 그 후보를 건너뛴다),
   상위 = "창 확장스타일 비트21 을 요구한다"(다르면 창을 부수고 다시 만든다). §4.2 가 남긴
   `[미해결]` 을 닫고, 거기 적힌 추측("씬 합성 가능")이 **틀렸다**는 것도 같이 적는다(§4.5).
   같은 함수가 `videohardwareacceleration`(bit4, **반전**)을 백엔드 `vtbl+0x70` 으로 흘려보낸다 —
   하드웨어 디코딩 게이트의 착지점이다.
9. **[2026-08-21] 비디오 볼륨은 즉시 바뀌지 않는다.** 25 ms 타이머로 램프하고 오르내림이
   비대칭이다(볼륨 1.0 기준 내림 500 ms / 오름 1250 ms). **일시정지도 램프가 끝난 뒤에** 걸린다 —
   곧 정책이 월페이퍼를 멈출 때 소리가 뚝 끊기지 않고 빠진다. 뮤트는 별도 API 가 아니라
   목표 볼륨 0 이다(§8.5).
10. **[2026-08-21] `spritesheetrefreshsync` 는 씬 시작을 늦춘다.** 씬 플래그 bit6 이
    월페이퍼 플래그 `[wallpaper+0x1b8] bit2` 로 옮겨지고, 씬 생성 끝에서 **다음 시트 프레임
    경계까지 `Sleep()`** 한다(배속으로 나누고 상한 250 ms). 레이어별 시계를 만드는 게 **아니다** —
    이식 비용이 종전 추정보다 훨씬 싸다(§7.4).
11. **[2026-08-21] `CreateMediaExtensions` 는 인자 없는 팩토리이고, 짝인 버전 export 는
    함수가 아니라 문자열 포인터 변수다.** 그리고 그 버전 export 는 **설치본 어디에서도 안 읽힌다**
    (6138파일 전수, ASCII·UTF-16 양쪽). §4.4.

---

## 1. 동봉 도달 실측

### 1.1 씬·템플릿 수

| 항목 | 동봉 `WEAssets` | 설치본 `assets` | 설치본 `projects` |
| --- | ---: | ---: | ---: |
| 씬 문서(`scene.json`+`gifscene.json`) | 172 | 172 | 18 |
| 그중 non-preview | 5 | 5 | 18 |
| **비디오 셸 씬** (`scenes/videoplayer`) | **1** | 1 | 0 |
| **GIF 셸 씬** (`scenes/gifs`) | **1** | 1 | 0 |
| GIF 템플릿 프로젝트 (`templates/gif`) | 0 | — | **1** |
| `type` 이 `video` 인 `project.json` | **0** | 0 | **0** |
| `.mp4`/`.webm`/`.mkv` 등 실 비디오 자산 | **0** | 0 | 0 |

동봉 사본과 설치본 `assets/scenes/` 는 `diff -rq` **완전 동일**(§부록 A.1).
설치본 `projects/` 의 `project.json` 21건 타입 분포: `scene` 14 · `web` 2 · `.exe` 1 ·
`type` 키 없음+`.json` 4(= 씬 유도). **비디오 0건.**

`ui/dist/videos/previews/*.webm` 165개는 **UI 카탈로그 미리보기**이지 월페이퍼가 아니다 —
CEF 가 그린다(`webmframework` 설정의 대상). 월페이퍼 재생 경로와 무관.

### 1.2 키 도수 (preview / non-preview 구분)

`preview`·`particleelementpreviews`·`presets` 경로를 preview 로 센다.

| 키 | 위치 | 동봉 non-prev | 동봉 prev | 설치본 `projects` | 값 |
| --- | --- | ---: | ---: | ---: | --- |
| `nopadding` | 모델 json 루트 | **2** | 0 | 2 | 전건 `true` |
| `spritesheetrefreshsync` | `general` | **2** | 0 | 1 | 전건 `true` |
| `orthogonalprojection.auto` | `general` | **2** | 0 | 0 | 전건 `true`, width/height 미저작 |
| `keepaspect` | 머티리얼 `usertextures[]` | **1** | 0 | 0 | `true` |
| `usertextures` (패스) | 머티리얼 | **1** | 0 | 0 | `[{name:"videotex",keepaspect:true}]` |
| `combos.spritesheet` | 머티리얼 | **1** | 0 | 10 | 전건 `1` |
| `general.supportsvideo` | `general` | **0** | 0 | **0** | — |
| `videosequence` | 플레이리스트 설정 | 0 | 0 | 0 | (UI 기본 `false`) |

도달 자산 실명:

* `nopadding` — `scenes/gifs/models/background.json`, `scenes/videoplayer/models/background.json`
  (+ 설치본 `templates/gif/models/background.json`, `templates/flag/models/flag.json`)
* `spritesheetrefreshsync` — `scenes/gifs/gifscene.json`, `scenes/videoplayer/scene.json`
  (+ 설치본 `templates/gif/gifscene.json`)
* `orthogonalprojection.auto` — 위와 같은 2건. **템플릿 쪽은 `auto` 가 아니라 실값**
  (`templates/gif/gifscene.json` 은 `{"height":1080,"width":1920}`) — §2.2 가 이유를 설명한다.
* `keepaspect`/`usertextures`/`videotex` — `scenes/videoplayer/materials/background.json` 단 1건
* `combos.spritesheet` — `scenes/gifs/materials/background.json` + 설치본
  `templates/gif/materials/background.json` + `defaultprojects/dino_run` 9건

`general.supportsvideo` 는 **동봉·설치본 전체에서 0건**이다. 파서는 있다(§3.3) — 저작 자산이 없다.

---

## 2. 두 씬의 저작 형태 전수 (과제 1)

### 2.1 파일 전문

`scenes/videoplayer/` — 4파일 + 컴파일된 셰이더 blob 5개(`shaders/blobsSM40/*.dxs`).

```jsonc
// scene.json
{ "camera": { "center":"0 0 -1.000", "eye":"0 0 0.000", "up":"0.000 1.000 0.000" },
  "general": { "bloom": false, "bloomhdrstrength": 0, "clearcolor": "0.000 0.00 0.000",
               "orthogonalprojection": { "auto": true },
               "spritesheetrefreshsync": true },
  "objects": [ { "angles":"0.000 0.000 0.000", "image":"models/background.json",
                 "origin":"0 0 0.000", "scale":"1.0 1 1.000" } ] }

// models/background.json
{ "material": "materials/background.json", "nopadding": true, "autosize": true }

// materials/background.json
{ "passes": [ { "cullmode":"nocull", "depthtest":"disabled", "depthwrite":"disabled",
                "shader":"genericimage", "textures":[ "util/black" ],
                "usertextures":[ { "name":"videotex", "keepaspect": true } ] } ] }
```

`scenes/gifs/` — 4파일.

```jsonc
// gifscene.json  (videoplayer/scene.json 과 general.bloomhdrstrength 만 다르다)
{ "camera": { … 동일 … },
  "general": { "bloom": false, "clearcolor": "0.000 0.00 0.000",
               "orthogonalprojection": { "auto": true },
               "spritesheetrefreshsync": true },
  "objects": [ { … videoplayer 와 자구까지 동일 … } ] }

// models/background.json  — videoplayer 와 바이트 동일
{ "material": "materials/background.json", "nopadding": true, "autosize": true }

// materials/background.json
{ "passes": [ { "cullmode":"nocull", "depthtest":"disabled", "depthwrite":"disabled",
                "shader":"genericimage", "textures":[ "background" ],
                "combos": { "spritesheet": 1 } } ] }

// materials/background.tex-json   ← 런타임 스키마가 아니라 resourcecompiler 사이드카
{ "nonpoweroftwo": true, "nointerpolation": true, "clampuvs": true,
  "nomip": true, "format": "rgba8888" }
```

두 씬의 **유일한 구조적 차이**는 프레임이 들어오는 경로다.

| | `videoplayer` | `gifs` |
| --- | --- | --- |
| 텍스처 슬롯 0 | `util/black`(플레이스홀더) | `background`(실 시트) |
| 프레임 주입 | `usertextures[0] = videotex` — 런타임이 꽂는 D3D11 공유 텍스처 | 없음. `background.tex` 자체가 시트 |
| 셰이더 콤보 | 없음(기본 경로) | `spritesheet:1` |
| 애스펙트 | `keepaspect: true` | 없음(모델 `autosize` 가 시트 크기를 그대로 씀) |
| 프레임 진행 | 미디어 엔진의 시계 | 씬 클록(`spritesheetrefreshsync`) |

`gifs` 에는 `project.json` 이 **없다**. 이 폴더는 엔진 내부 템플릿이고, 프로젝트로 승격되는 것은
`projects/temp/gifs/<stem>/` 로 복사된 사본뿐이다(§3.2). 저작용 짝은
`projects/templates/gif/`(= 같은 4파일 + `project.json` + `template.json` + `tpreview.png`)이고,
그쪽 `project.json` 은 `templateoptions[0].type = "replacetexture"`,
`parameters.animatedonly = true`, `destination = "materials/background.gif"`,
`adjustprojection = true` 에 옵션 4개(`gif_compression`(DXT5) · `gif_pointfilter` ·
`bilteralfilter`(오타 원문 그대로, 0–100) · `schemeColorFromDominantColor`)를 얹는다.
앞의 셋은 전부 `texture: "materials/background.tex.json"` 을 가리킨다 — **에디터가 tex 사이드카를
고쳐 재컴파일하게 하는 스위치**이지 런타임 키가 아니다.

### 2.2 왜 네 키가 이 두 씬에만 몰려 있나

네 키는 전부 **"내용물의 픽셀 크기를 저작 시점에 모른다"** 는 한 조건에서 파생한다.
일반 씬은 텍스처 크기가 `.tex` 헤더에 박혀 있어 이 문제가 없다.

| 키 | 이 두 씬에서 해결하는 문제 | 일반 씬에서 불필요한 이유 |
| --- | --- | --- |
| `nopadding`(모델 루트) | 베이크 텍스처를 2의 거듭제곱/아틀라스 패딩 없이 **원본 크기 그대로** 쓰라는 요청. 비디오 프레임(1920×1080, 3840×2160…)과 GIF(임의 크기)는 POT 가 아니다 | 저작 텍스처는 컴파일 시 패딩 규약이 이미 확정 |
| `autosize`(모델 루트, 동반) | 레이어 쿼드 크기를 텍스처 크기에서 **런타임에** 가져온다 | `width`/`height` 를 저작에 적는다 |
| `orthogonalprojection.auto` | 정사영 크기를 씬이 아니라 **출력 뷰포트**가 정한다. 파서가 `auto==true` 면 `width`/`height` 를 **읽지 않고**(`0x140187550`→`0x140187602` 점프) `scene+0x354/+0x358` 과 `engine+0x84/+0x88` 을 생성자 0 그대로 둔다 = "엔진이 알아서" | 씬 좌표계가 저작 해상도에 고정돼 있다 |
| `keepaspect`(유저텍스처 슬롯) | 슬롯 크기에 **늘이지 말고** 원본 비율을 유지해 맞춘다. 비디오는 창 비율과 다를 수 있다 | 유저텍스처 자체가 드물다 |
| `spritesheetrefreshsync` | 시트 프레임 진행을 레이어별 누적 시계가 아니라 **씬 전역 클록**에 묶는다 | 파티클 시트는 위상이 달라도 무방(오히려 바람직) |

**세 번째 줄이 이 절의 핵심 관찰이다.** `templates/gif/gifscene.json` 은 같은 템플릿인데
`orthogonalprojection` 이 `auto` 가 아니라 `{"width":1920,"height":1080}` 이다. 차이는
**누가 크기를 정하느냐**다 — `projects/templates/gif` 는 사용자가 에디터로 여는 **저작 템플릿**이라
캔버스 크기가 필요하고(`adjustprojection: true` 가 임포트 시 이 값을 GIF 크기로 덮어쓴다),
`assets/scenes/gifs` 는 엔진이 즉석에서 마운트하는 **런타임 셸**이라 캔버스가 곧 모니터다.
즉 `auto` 는 "저작 단계를 건너뛴 씬" 표식이고, 그래서 정확히 그 두 씬(`videoplayer`,
런타임 `gifs`)에만 있다.

`spritesheetrefreshsync` 가 `videoplayer` 에도 있는 것은 언뜻 이상하다 — 비디오 셸에는 시트가
없다. 두 씬 파일이 **같은 원본에서 갈라져 나온 사본**이라는 것이 가장 단순한 설명이고,
`objects[0]` 이 들여쓰기·소수 표기(`"0 0 -1.000"`, `"1.0 1 1.000"`)까지 자구 동일한 것이 방증이다.
플래그 자체는 무해하다(bit6 은 시트 레이어가 없으면 소비처가 없다). **[미해결]** — bit6 의 실제
소비 지점을 exe 에서 찾지 못했다는 `SceneDocument.spritesheetRefreshSync` 선언부의 기록이 여전히 유효하다.
**[해소 2026-08-21]** 소비 지점을 찾았다 — 씬 플래그가 아니라 **월페이퍼 플래그로 한 번 옮겨 실린다**.
전문은 §7.4. 결론만: `spritesheetrefreshsync` 는 씬을 띄우기 직전에 **다음 시트 프레임
경계까지 `Sleep()` 한다**(최대 250 ms). 그래서 "시트 진행을 씬 전역 클록에 고정" 이라는 위의
읽기는 방향이 맞았고, 기계는 위상 정렬을 **시작 시각 한 번**으로 한다.

파서 명령 단위는 여기서 반복하지 않는다 — `Sources/WapleCore/SceneDocument.swift` 의
`noPadding` · `spritesheetRefreshSync` · `orthoAuto` ·
`materialUserTextureKeepAspect` 선언부 주석이 VA 까지 갖고 있다.

---

## 3. 진입 — 확장자에서 씬까지

### 3.1 `type:"video"` — 씬을 거치지 않는다(원칙)

`project.json` 의 확장자→타입 분류기(`0x14011e520`, `docs/re/package-format.md` §5.3)가
`.mp4 .wmv .avi .m4v .mov .webm .mkv` 를 타입 4(`Video`)로 보낸다. 그 뒤는 씬 마운트가 아니라
`VideoWallpaper` 창 생성이다 — RTTI 이름이 그대로 남아 있다:

```
.?AV<lambda_1..5>@?1??StartVideoWithNewPlayer@VideoWallpaper@@AEAAXPEB_W@Z@
```

창 프로시저는 `0x14012a6a0`–`0x14012ab06`(WM_DESTROY=2 · WM_SIZE=5 · WM_PAINT=0xf ·
WM_ERASEBKGND=0x14 분기). 라이브 설정 반영은 `0x14012a270`–`0x14012a695` 이고, 마지막에
`IsWindow(hwnd)`(IAT `0x140426a20`) → `InvalidateRect(hwnd,NULL,FALSE)`(IAT `0x140426a30`) 로
**창을 무효화**한다. 씬 렌더러의 프레임 루프가 아니다.

### 3.2 `.gif` 스테이징 `0x140113c80`–`0x1401151d8`

월페이퍼 로드 디스패처가 `file` 확장자로 갈린다(`.pkg` `0x140113fde` · `.json` `0x14011418e` ·
`.gif` `0x1401142a4`). `.gif` 분기 전문:

| 순서 | 동작 | VA |
| --- | --- | --- |
| 1 | `path::stem()` 으로 GIF 파일명(확장자 제외)을 뽑아 임시 폴더 이름으로 쓴다 | `0x1401142d5`(`0x14003fc80` = `stem`) |
| 2 | 원본 = `<engineRoot>/assets/scenes/gifs` | `0x140114304` |
| 3 | 대상 = `<engineRoot>/projects/temp/gifs/<stem>` | `0x140114334`·`0x140114347` |
| 4 | 폴더 트리 복사(`0x140051a30`, 플래그 `0x12`, 진행 콜백 객체 `[rsp+0x30]`/`[rsp+0x38]`) | `0x1401143a4` |
| 5 | 실패 시 콜백 vtable`+0x10` → 로그(`0x140098760`, 포맷 `0x140489310`) | `0x1401143d3`–`0x140114413` |
| 6 | GIF 원본 → `projects/temp/gifs/<stem>/materials/background.gif` 로 파일 복사(같은 헬퍼, 플래그 `2`) | `0x140114459`·`0x1401144ac` |
| 7 | 씬 문서 = `projects/temp/gifs/<stem>/gifscene.json` | `0x140114551` |
| 8 | 마운트 루트 = `projects/temp/gifs/<stem>`(`0x1402764d0` = 부모폴더 마운트) | `0x140114655` |

곧 **GIF 는 미디어 스택을 전혀 타지 않는다.** 스테이징 후에는 평범한 스프라이트시트 씬이고,
`materials/background` 텍스처가 GIF 를 디코드해 시트로 만든 결과다(그 디코드는 텍스처 파이프라인
쪽이라 이 문서 밖 — `docs/re/tex-format.md` §5 가 TEXS 를 다룬다).

`docs/re/package-format.md` §4.3 이 기록한 "플래그 `0x20` 세우고 GIF 씬 경로로 이탈"
(`0x14010e0ee`–`0x14010e12c`)이 **여기로 이탈한다**. 두 기록은 같은 흐름의 앞뒤다.

> `projects/temp/gifs` 문자열 `0x1404892b0`, `assets/scenes/gifs` `0x140489298`,
> `materials/background.gif` `0x140489340`, `gifscene.json` `0x140489300`.

### 3.3 `general.supportsvideo` — 씬이 비디오를 품겠다고 선언하는 키

마운트 디스패처(`0x14010df40`) 안:

```
0x14010ead6  lea rdx, [rip+…]      ; 0x140489130 "supportsvideo"
0x14010eae2  cmp byte [rax+8], 5   ; 태그 5 = bool
0x14010eaeb  call 0x140086300      ; asBool
0x14010eaf4  or dword [r14+0x248], 0x8000    ; bit15
```

부재 시 false. **동봉·설치본 도달 0건**이므로 소비 결과를 코퍼스로 확인할 수 없다.
`videotex` 유저텍스처를 가진 씬(= `assets/scenes/videoplayer`)이 이 플래그를 **저작하지 않는다**는
점이 주의할 대목이다 — 즉 `supportsvideo` 는 videoplayer 셸의 조건이 아니라 **워크샵 씬이
비디오 텍스처를 요청할 때** 쓰는 별도 스위치로 보인다. **[미해결]** — bit15 의 소비 지점을
특정하지 못했다.

### 3.4 videoplayer 씬 마운트 `0x14011eea0`–`0x14011f27d`

`assets/scenes/videoplayer/scene.json`(문자열 `0x140489d10`) 을 열고 `0x1402764d0` 으로 엔진
`assets` 루트를 마운트한다. 호출자는 두 곳(`0x1401041d0`, `0x140104240`).

씬을 열기 **전에** `0x140120050`–`0x1401205ca` 가 프로젝트 JSON 에
`wproperties.videotex.value = <비디오 경로>` 를 **써 넣는다**:

```
0x140120131  call [rax+0x98]                       ; 프로젝트 JSON 루트   [VA-정정 2026-08-28]
0x140120141  lea rdx, "wproperties"                ; 0x140474850
0x140120169  lea rdx, "videotex"                   ; 0x140489d38
0x140120188  call 0x140005790                      ; [player+0x80] → std::string (파일 경로)
0x1401201a8  call 0x1402d0b90                      ; malloc(len+5)
0x1401201cd  call 0x1404210f0                      ; memcpy — jsoncpp 길이-접두 문자열 만들기
0x1401201dd  lea rdx, "value"                      ; 0x140474508
0x140120200  mov byte [rbp-0x51], 4 / bts ebx,8    ; 태그 4(string) + allocated
0x1401204b1  lea rdx, "materials/background.json"  ; 0x140489d48
```

> **[VA-정정 2026-08-28]** 위 블록 첫 줄의 주소가 **명령 시작이 아니었다** — 종전
> `0x140120137` → **`0x140120131`**. 이 건의 원인은 앞의 세 VA 오기와 **다르다**: `lea` 를
> `call` 로 적은 것이 아니라 **`call` 의 *다음* 명령 주소를 적었다**(`call [rax+0x98]` 은
> ModRM+disp32 로 6바이트 — `0x131`+6 = `0x137`).
>
> **같은 블록의 `0x140120169`(`lea rdx, "videotex"`)는 맞다.** 나머지 `lea`/`call` 줄도
> 각각 떠서 확인했고 손대지 않았다. 오기 양식이 두 가지(‘`lea` 주소를 적음’ · ‘다음 명령
> 주소를 적음’)이므로 **일괄 오프셋 보정은 불가능하다** — 자리마다 열어 봐야 한다.

곧 **비디오 파일 경로가 유저 프로퍼티로 씬에 주입되고**, 머티리얼의
`usertextures[0].name == "videotex"` 슬롯이 그 이름으로 해석된다.

> `SceneDocument.materialUserTextureKeepAspect` 선언부가 남긴 `[미해결]`("머티리얼 패스 `usertextures` 의 딕셔너리 형태를
> userProps 치환 대상으로 삼지 않는다 — 실피해 0건, `videotex` 는 유저 프로퍼티가 아니라
> 렌더러가 넣는 라이브 텍스처라서")은 **절반만 맞다.** WE 는 `videotex` 를 실제로
> `wproperties` 에 **문자열로** 넣는다(위 코드). 다만 그 값은 텍스처 이름이 아니라 **파일 경로**이고,
> 실제 텍스처는 `0x1400f3480` 이 D3D11 공유 서페이스로 별도 공급한다(§4.3). 즉 "치환 대상이
> 아니다"라는 결론은 유지되지만 이유가 다르다 — **키가 없어서가 아니라, 있는 값이 텍스처 이름이
> 아니어서**다.

---

## 4. 디코더 경로 (과제 2)

### 4.1 문자열 실측 — ASCII·UTF-16LE 양쪽

| 토큰 | ASCII | UTF-16LE | 어디에 |
| --- | --- | --- | --- |
| `ffmpeg` / `ffmpeg.exe` | ✔ | ✘ | `bin/wallpaperui.exe`(14건: `ffmpeg_avi_raw` `ffmpeg_avi_yuv420` `ffmpeg_avi_yuv422` `ffmpeg_gif` `ffmpeg_mp4_h264` `ffmpeg_mp4_h265` 등), `bin/resourcecompiler{32,64}.exe`(`ffmpeg.exe`) |
| `ffmpeg`/`avcodec`/`avformat`/`swscale`/`libvpx` | ✘ | ✘ | **`wallpaper64.exe` 에 0건** (`.?AVcodecvt_base@std@@` 는 MSVC RTTI 오탐) |
| `MFPlat.DLL` `MFReadWrite.dll` `MF.dll` | ✔ | — | `wallpaper64.exe` 임포트 이름 |
| `mfplat.dll` `mfreadwrite.dll` | ✘ | **✔** | `wallpaper64.exe` — 지연로드 재시도 경로가 와이드로 들고 있다 |
| `Media Foundation` / `Media Foundation (muted)` | ✔ | ✘ | `0x1404887a8` / `0x1404887c0` |
| `Media Engine Dx11` / `… (muted)` | ✔ | ✘ | `0x140488720` / `0x140488738` |
| `DirectShow, LAV, VMR9` | ✔ | ✘ | `0x140488768` |
| `Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager` | ✘ | **✔** | `bin/winrtutil64.exe` (WinRT 클래스명은 항상 HSTRING = UTF-16) |
| `nv12`/`yuv`/`dxva`/`d3d11va` | ✘ | ✘ | 어디에도 없다 |

**결론 ①: 재생 경로에 ffmpeg 은 없다.** `ffmpeg.exe` 는 **에디터(`wallpaperui.exe`)의 내보내기**와
**리소스 컴파일러**에서만 쓰인다(`ffmpeg_mp4_h264` 같은 프리셋 이름이 그 증거다). 런타임
`wallpaper64.exe` 에는 토큰이 하나도 없다.

**결론 ②: YUV→RGB 셰이더 변환도 없다.** `MFVideoFormat_NV12`/`ARGB32`/`RGB32`,
`MF_MT_YUV_MATRIX`, `MF_MT_VIDEO_NOMINAL_RANGE` GUID 가 exe 에 **부재**하고(§부록 A.4 로 재확인),
셸 셰이더 `genericimage.frag` 에도 변환 코드가 없다. 변환은 Media Foundation 내부가 한다 —
`spec/engine/media.json` 의 `engine.media.color.delegation` 이 이미 확정한 사실이다.

### 4.2 프레임워크 선택과 폴백 사슬 `0x1400ff750`–`0x1400ffcaf` [이 문서가 새로 확정]

`spec/engine/media.json:engine.media.video.frameworks` 는 **열거값과 UI 라벨**을 갖고 있지만
**폴백 순서**는 없다. 그것이 여기다.

설정 `videoframework`(문자열 `0x140476cf0`)를 `stricmp`(`0x1402c10d0`)로 비교해
`[player+0x260]` 의 `std::vector<std::string>` 을 **우선순위 순서대로** 채운다.
`0x1401031f0` = `emplace_back(const char*)`, `0x140103450` = 리터럴 `"mf"` 전용 특수화
(원소 크기 0x20 = `std::string`).

| `videoframework` 값 | 시도 순서 | 분기 VA |
| --- | --- | --- |
| `dshow.lav.vmr9` | `dshow.lav.vmr9` → `mfEngine` → `mfEngine.muted` → `mf` → `mf.muted` | `0x1400ff7f9`(비교) · `0x1400ff80c`–`0x1400ff841` |
| `mf` | `mf` → `mf.muted` → `dshow.lav.vmr9` → `mfEngine` → `mfEngine.muted` | `0x1400ff855`(비교) · `0x1400ff861`–`0x1400ff88e` |
| 그 외(기본 `mfEngine`, 빈 문자열, 미저작) | `mfEngine` → `mfEngine.muted` → `mf` → `mf.muted` → `dshow.lav.vmr9` | `0x1400ff89c`–`0x1400ff8d8` |

* `.muted` 변형은 **별도 프레임워크가 아니라 같은 백엔드의 음소거 판**이다. `mfEngine.muted` 는
  `IMFMediaEngineClassFactory::CreateInstance` 의 `dwFlags` 에 `MF_MEDIA_ENGINE_FORCEMUTE`(0x4)를
  더한 것이고(`0x1400f2407` `xor r14b,1` → `0x1400f2415` `or edx,0x12`), 오디오 초기화가 실패해도
  영상은 살리려는 **한 단계 완화 재시도**다.
* 소비 루프는 `0x140100cf0`–`0x140101b23`("try each framework"). `0x140101416`–`0x140101446` 가
  `([player+0x268] - [player+0x260]) >> 5` 로 원소 수를 세며 인덱스를 올린다. 실패 시 로그
  `Failed creating video player (%s): %x`(`0x140488780`, 적재 `0x1401011dd` → 로그 `0x14010132f`) 후 다음 후보.
* 전부 실패하면 `SendMessageTimeoutW`(IAT `0x140426720`)로 `0x407` 메시지를 UI 에 올린다
  (`0x14010149b`) — 사용자에게 보이는 `core_balloon_video_error`(`0x140475050`).

프레임워크 레지스트리는 매직-스태틱(가드 `0x1404e9240`)으로 한 번 만들어지고
(`0x1401014ce`–`0x1401017c8`) 5개 항목을 담는다:

| id 문자열 | 표시명 | 표시명 VA | 플래그 워드 | 팩토리 blob | blob`+0x10` 의 생성자 | 씬을 마운트하나 |
| --- | --- | --- | --- | --- | --- | --- |
| `mfEngine` `0x140476f30` | `Media Engine Dx11` | `0x140488720` | `0x0101` | `0x140488940` | `0x140104240`(`r9d=0`) | **✔** `0x14011eea0` |
| `mfEngine.muted` `0x1404884b0` | `Media Engine Dx11 (muted)` | `0x140488738` | `0x0101` | `0x1404888b0` | `0x1401041d0`(`r9d=1`) | **✔** `0x14011eea0` |
| `mf` `0x140476d00` | `Media Foundation` | `0x1404887a8` | `0x0001` | `0x140488880` | `0x140103fa0` | ✘ |
| `mf.muted` `0x1404884c0` | `Media Foundation (muted)` | `0x1404887c0` | `0x0001` | `0x140488910` | `0x140103d70` | ✘ |
| `dshow.lav.vmr9` `0x1404884d0` | `DirectShow, LAV, VMR9` | `0x140488768` | `0x0000` | `0x1404888e0` | `0x140103c50` | ✘ |

**마지막 열이 §0 결론 ①의 근거다.** `assets/scenes/videoplayer/scene.json` 을 여는 함수
`0x14011eea0` 의 호출자는 **정확히 두 곳**(`0x140104201`, `0x14010426e`)이고, 둘 다
`mfEngine` 계열 팩토리다(`.rdata` blob `+0x10` 슬롯을 직접 읽어 확인 — §부록 A.5).
두 팩토리는 `0xeb0` 바이트 객체를 할당해 같은 생성자에 넘기고 **`r9d` 만 다르다**
(`0`/`1`) — `.muted` 쪽이 1 이므로 그 인자는 음소거 플래그다.

`mf`/`dshow` 가 씬을 못 쓰는 이유는 구조적이다: EVR(`MFCreateVideoRendererActivate` +
`MR_VIDEO_RENDER_SERVICE` `0x14042c370` + `IMFVideoDisplayControl` `0x140489f60`)과
VMR9(`CLSID_FilterGraph` `0x14042c340` + `IGraphBuilder` `0x14048a248`)는 **HWND 에 직접
그린다** — 씬에 꽂을 텍스처가 애초에 생기지 않는다.

플래그 워드의 상위 바이트가 `mfEngine` 계열만 1 인 것도 같은 축으로 읽히지만
(씬 합성 가능 = 텍스처로 뽑을 수 있음), 그 워드를 읽는 자리를 특정하지 못했다. **[미해결]**
**[해소 2026-08-21]** — 두 바이트 다 소비 지점을 찾았고, **위 추측은 틀렸다**. 상위 바이트는
"씬 합성 가능" 이 아니라 **창 확장스타일 요구**다. 전문은 §4.5.

같은 함수가 나머지 설정도 처리한다:

| 설정 키 | 저장 위치 | 값 사상 | VA |
| --- | --- | --- | --- |
| `videoaudiooutput`(bool) | `[player+0x17c]` bit3 | 전역값 **AND** `general.location.videoaudiooutput`(있으면) | `0x1400ff8fd`–`0x1400ff985` |
| `videohardwareacceleration`(bool) | `[player+0x17c]` bit4 | **반전 저장**(bit4 = HW 가속 **끔**) | `0x1400ff995`–`0x1400ff9d3` |
| `videoloopmode`(string) | `[player+0x198]` | `syncclock`→1, `synctopo`→2, 그 외(`default`)→0 | `0x1400ff9e3`–`0x1400ffa6e` |
| `videoreadmode`(string) | `[player+0x19c]` | `frommemory`→1, 그 외(`fromdisk`)→0 | `0x1400ffa7c`–`0x1400ffadc` |
| `videomfstutterhack`(bool) | `[player+0x17c]` bit5 | **`videoframework` 가 `mf` 또는 `mfEngine`(또는 미저작/비문자열)일 때만 반영**, 그 외에는 무조건 clear | `0x1400ffaea`–`0x1400ffc9c` |

마지막 줄이 새 사실이다. `spec/engine/media.json` 은 "UI 조건상 `videoframework=='mf'` 일 때만
노출"이라고 적었는데, **엔진 자신도 게이트를 갖고 있다** — 그리고 그 게이트는 `mf` **와**
`mfEngine` 둘 다 통과시킨다(`0x1400ffb37` `memcmp "mf"`, `0x1400ffb61` `memcmp "mfEngine"`).
UI 보다 넓다.

반환값 `r12d` 는 변경 마스크다: `4`=하드웨어가속 변경 · `8`=오디오출력 변경 ·
`0x10`=루프모드 변경 · `0x20`=리드모드 변경. 프레임워크 목록 변경은 마스크에 없다(매번 재구축).

### 4.3 프레임이 GPU 에 올라가는 자리

`spec/engine/media.json:engine.media.mfEngine.pipeline`/`framePacing` 이 이미 확정한 내용이다.
여기서는 **재구현이 실제로 베껴야 하는 계약**만 요약하고 그 이상은 그쪽을 본다.

```
0x1400f34e8  mov rcx, [rbx+0xb0]           ; IDXGIKeyedMutex
0x1400f350e  mov r8d, 0x3e8                ; 1000 ms
0x1400f3514  call [rax+0x40]               ; AcquireSync(key=0, 1000)
0x1400f351b  mov rcx, [rbx+0x58]           ; IMFMediaEngineEx
0x1400f3530  mov rdx, [rbx+0xa8]           ; ID3D11Texture2D (공유 서페이스)
0x1400f3529  lea r8,  [rbx+0xb8]           ; MFVideoNormalizedRect  (src crop)
0x1400f3537  lea r9,  [rsp+0x30]           ; RECT {0,0,w,h}         (dst)
0x1400f3524  mov [rsp+0x20], rdx           ; MFARGB borderColor = (B0,G0,R0,A0xFF)
0x1400f353f  call [rax+0x158]              ; TransferVideoFrame
0x1400f356e  call [rax+0x48]               ; ReleaseSync(0)
```

계약 4가지:

1. **출력 포맷은 `DXGI_FORMAT_B8G8R8A8_UNORM`(87)** 이다(`0x1400f239d` `mov r8d,0x57`
   → `MF_MEDIA_ENGINE_VIDEO_OUTPUT_FORMAT`). NV12 도 YUV 셰이더도 없다.
2. **크롭은 소스 정규화 사각형**(`[player+0xb8..0xc4]`, float 4개)으로 준다. 세터는
   `0x1400f2e90`–`0x1400f2f4e`(가상 메서드 — 직접 호출자 없음): `xmm1→+0xb8`(left),
   `xmm2→+0xbc`(top), `xmm3→+0xc0`(right), `[rsp+0x80]→+0xc4`(bottom), 그리고
   `[player+0x92] = 1` 로 더티 표시.
3. **목적지는 항상 창 전체**(`{0,0,w,h}`, `w/h` 는 `[[rbx+0x88]+0x20/+0x24]`).
   즉 letterbox/pillarbox 는 dst 를 줄여서가 아니라 **경계색으로** 만들어진다.
4. **경계색은 불투명 검정**(BGRA `00 00 00 FF`, `0x1400f34f3`–`0x1400f34ff`). 하드코딩이다 —
   `clearcolor` 나 `schemecolor` 를 쓰지 않는다.

**[미해결]** — `alignment`(§5) 열거값에서 위 정규화 사각형을 만드는 산술을 특정하지 못했다.
`0x1400f2e90` 은 가상 디스패치로 불리고, 호출부를 `VideoWallpaper` 쪽(`0x140100720` ·
`0x140101c50` 이 `[obj+0x160]`/`[obj+0x180]` 을 읽는 후보)까지 좁혔으나 부동소수 경로를
끝까지 잇지 못했다. 정규화 사각형이 **소스** 좌표라는 것과 목적지가 창 전체라는 것까지가 확정이다.

### 4.4 `bin/mediaextensions64.dll` 은 비디오가 아니다

export 177개 중 175개가 OpenAL Soft(`al*`/`alc*`/`*SOFT`)이고, WE 고유는
`CreateMediaExtensions`(ordinal 1) · `WallpaperEngineMedaExtensionVersion`(ordinal 2, 오타 원문)
둘뿐이다. 임포트는 `KERNEL32`(143) · `WINMM`(3) · `SHELL32`(1) · `ole32`(5)로 **MF·DShow·D3D
가 하나도 없다.** FLAC 디코더 문자열(`FLAC__STREAM_DECODER_*`)과 SFML-Audio 계열 오류 문자열
(`Failed to create the audio context`, `Failed to open the audio device`)이 함께 있다 — 곧
**씬 `sound` 레이어용 오디오 스택**이다.

> 함정 8번("한 바이너리 ≠ WE — 미디어는 별도 DLL/프로세스일 가능성이 높다")의 정답은
> 이 DLL 이 **아니고** `bin/winrtutil64.exe`(§6.1)다. 이름이 `mediaextensions` 라서 비디오
> 디코더로 오인하기 쉽다. `spec/engine/media.json:engine.media.mediaextensions.isOpenAL` 이
> 같은 결론을 이미 갖고 있다.

**[2026-08-21 신규] WE 고유 export 2개의 시그니처를 복원했다.**
`spec/engine/media.json:engine.media.unknowns` 가 "복원하지 않았다"로 남겨 둔 항목이다.

> **이 절의 VA 규약.** `0x180…` 은 **`bin/mediaextensions64.dll`**(imagebase `0x180000000`),
> `0x140…` 은 **`wallpaper64.exe`**(imagebase `0x140000000`)다. 두 이미지의 베이스가 달라
> 숫자만으로 갈리지만, 다음 사람이 엉뚱한 이미지에서 뜨지 않도록 문장마다 이름을 붙인다.

**① `CreateMediaExtensions`(ordinal 1, `mediaextensions64.dll` `0x180002808`) —
`void* CreateMediaExtensions(void)`.**
인자를 하나도 읽지 않는다. 진입 첫 명령이 `mov ecx, 0x48` 이라 `rcx` 가 즉시 덮이고
`rdx`/`r8`/`r9` 는 끝까지 안 읽힌다. 호출부도 같은 말을 한다 —
`wallpaper64.exe 0x1400c4bca` 가 인자 셋업 없이 `call rax` 하나다(**양쪽이 독립적으로 arity 0**).

본체는 `0x48`바이트를 할당해 이렇게 채운다:

```
0x180002829  lea  rax, [rip+…]                ; 0x1802dcc70  vptr
0x18000287f  mov  dword [rbx+8], 0x3f800000   ; 1.0f  = max_load_factor
0x18000283f  call 0x180006650                 ; 0x38바이트 리스트 센티넬
0x18000284d  mov  [rax], rax / [rax+8], rax   ; 자기참조 = 빈 리스트
0x18000286f  mov  qword [rbx+0x38], 7         ; _Mask
0x180002877  mov  qword [rbx+0x40], 8         ; _Maxidx
0x18000288a  call 0x180002cf4                 ; 버킷 벡터를 16개로 resize(센티넬로 채움)
```

곧 **vptr + 빈 `std::unordered_map` 하나**가 객체 전부다(MSVC `_Hash` 배치 —
같은 배치가 `wallpaper64.exe` 의 프레임워크 레지스트리에도 그대로 나온다, §4.5.1).
vtable `0x1802dcc70` 의 `+0x18`(`0x1800034a0`)이 `(이름, 바이트, 길이)` 를 받아
`{u32 refcount, void* bytes, u32 size}` 0x18바이트를 만들어 map 에 넣고(`0x1800035b4`–`0x1800035f3`),
`+0x20`(`0x180003a64`)이 refcount 를 내려 0 이면 항목을 지운다(`0x180003aa8`–`0x180003b40`).
곧 **이름으로 참조되는 리프카운트 바이트-블롭 캐시**다 — OpenAL 이 먹을 사운드 파일 원본을
씬끼리 공유하는 자리로 읽힌다.

호스트(`wallpaper64.exe`) 쪽 로더는 `0x1400c4a70`–`0x1400c4c44`:
`LoadLibraryExW(L"mediaextensions64.dll", NULL, 0x1000)`(`0x1400c4b7f`) →
`GetProcAddress(h, "CreateMediaExtensions")`(`0x1400c4bbf`) → `call rax` → `vtbl+0x08`(빈 함수) →
꼬리점프 `jmp [rax+0x18]`(`0x1400c4c11`). **`LoadLibraryW` 가 아니라 `LoadLibraryExW` 다** —
정본이 `LoadLibraryW` 라고 적고 있었고 이번에 고쳤다.

**② `WallpaperEngineMedaExtensionVersion`(ordinal 2, `mediaextensions64.dll` `0x1803119e0`) —
함수가 아니라 데이터다.**
export RVA `0x3119e0` 은 `.text` 밖 `.data` 이고, `.reloc` 에 그 RVA 의 `DIR64`(type 10) 항목이
있다 — 재배치되는 **포인터 변수**라는 뜻이다. 값은 `.rdata 0x1802dcbd0` 의 ASCII
`WallpaperEngineMediaExtensions0002`. 곧 `const char* WallpaperEngineMedaExtensionVersion` 이고
`GetProcAddress` 로 받아 **역참조**하는 것이지 호출하는 것이 아니다.

> **소비자가 없다.** 설치본 6138파일을 ASCII·UTF-16LE **양쪽으로** 전수 스캔했다(함정 8).
> `CreateMediaExtensions` 는 `wallpaper32.exe`·`wallpaper64.exe`·`bin/wallpaperui.exe` 와
> 두 DLL 자신의 export 이름표에 있고, `WallpaperEngineMedaExtensionVersion` 은
> **두 DLL 자신 말고 어디에도 없다.** 버전 협상을 위해 내놓았지만 아무도 안 묻는 export 다.
> (재현: `부록 A.12`)

---

### 4.5 프레임워크 게이트와 백엔드 가상함수 [2026-08-21 신규 — §4.2 의 `[미해결]` 을 닫는다]

> **이 절의 VA 는 전부 `wallpaper64.exe`(imagebase `0x140000000`)다.**

§4.2 는 레지스트리 레코드의 **플래그 워드**(`0x0101`/`0x0001`/`0x0000`)를 값까지만 확정하고
"읽는 자리를 특정하지 못했다"로 끝냈다. 그 자리가 여기다. 그리고 같은 함수가
`videohardwareacceleration`·`videoaudiooutput`·`videoloopmode`·`videoreadmode` 를 **전부**
백엔드로 흘려보낸다 — 곧 §4.2 표의 "저장 위치" 들이 실제로 소비되는 유일한 지점이다.

#### 4.5.1 레지스트리는 `unordered_map` 이고 레코드는 이렇게 생겼다

레지스트리 전역은 `0x1404e9250` 이다. MSVC `std::_Hash` 배치가 그대로 보인다 —
`max_load_factor 1.0f`(`0x1404e9250`, `0x140101812` 가 `0x3f800000` 을 심는다) ·
리스트 head(`0x1404e9258`) · 버킷 벡터(`0x1404e9268..0x1404e9278`) ·
`_Mask = 7`(`0x1404e9280`, `0x1401017fc`) · `_Maxidx = 8`(`0x1404e9288`, `0x140101807`).
빌더는 `0x1401014ce`–`0x1401017c8`, 매직-스태틱 가드는 `0x1404e9240`.

노드가 `{_Next, _Prev, key std::string(0x20), value}` 라 **value 는 노드 + 0x30** 이다.
빌더가 스택에 레코드를 짓는 것을 보면 필드가 잡힌다(mfEngine 기준, 레코드 베이스 `rbp+0x280`):

| 레코드 오프셋 | 내용 | 근거 VA |
| --- | --- | --- |
| `+0x08` (u16) | **플래그 워드** | `0x140101527` `mov word [rbp+0x288], 0x101` · `0x1401015c5`(muted 판) |
| `+0x10` | 표시명 `std::string` | `0x1401014ee` `lea rcx, [rbp+0x290]` → `0x140101530` |
| `+0x88` | 팩토리 blob 포인터 | 소비 쪽 `0x1401011a1` `mov rcx, [rbx+0xb8]`(= 노드+0xb8 = value+0x88) |

곧 소비 쪽에서 **노드+0x38 이 플래그 워드의 하위 바이트, 노드+0x39 가 상위 바이트**다.

#### 4.5.2 하위 바이트 = "이 프레임워크는 Media Foundation 을 요구한다"

후보 루프(§4.2 의 "try each framework")가 이름으로 레코드를 찾은 직후:

```
0x140100fca  call 0x1401038d0                 ; map.find(name)
0x140100fcf  mov  rcx, [rax+8]
0x140100fd3  mov  rax, [rip+…]                ; 0x1404e9258  리스트 end(센티넬)
0x140100fe0  cmovne rbx, rcx                  ; rbx = 찾았으면 노드, 아니면 end
0x140100fe7  je   0x14010141d                 ; 없는 이름 → 이 후보 포기
0x140100fed  mov  eax, [rdi+0x17c]
0x140100ff3  shr  eax, 6
0x140100ff6  test al, 1                       ; [player+0x17c] bit6
0x140100ff8  je   0x140101004                 ; bit6 이 없으면 게이트 없음
0x140100ffa  cmp  byte [rbx+0x38], 0          ; 레코드 플래그 하위 바이트
0x140100ffe  jne  0x14010141d                 ; MF 계열이면 이 후보를 통째로 건너뛴다
```

`bit6` 은 **`mfplat.dll` 이 없다**는 뜻이다. 설정 적용 함수가 `dshow.lav.vmr9` 를 목록에 넣은
직후 프로브를 한다:

```
0x1400fe13f  lea  rcx, [rip+…]                ; 0x140487118  L"mfplat.dll"  (UTF-16)
0x1400fe146  mov  byte [rip+…], 1             ; 0x1404e7e8c  한 번만 프로브하는 래치
0x1400fe14d  call [rip+…]                     ; LoadLibraryW
0x1400fe153  test rax, rax
0x1400fe156  jne  0x1400fe25e
0x1400fe15c  or   dword [rdi+0x17c], 0x40     ; bit6 = MF 없음
0x1400fe188  lea  r8,  [rip+…]                ; 0x140487130 "core_msgbox_media_feature_pack_missing"
```

**표와 맞춘다.** 하위 바이트는 `mf`·`mf.muted`·`mfEngine`·`mfEngine.muted` 넷이 1, `dshow.lav.vmr9`
가 0 이다. 곧 Media Feature Pack 이 없는 시스템에서는 §4.2 의 폴백 사슬이 어떤 설정값이든
**`dshow.lav.vmr9` 하나로 줄어든다.** 이것이 §4.2 의 순서표가 실제로 걸러지는 유일한 자리다.

#### 4.5.3 상위 바이트 = "창 확장스타일 비트21 을 요구한다"

```
0x140101195  movzx edx, byte [rbx+0x39]       ; 레코드 플래그 상위 바이트
0x14010119c  call  0x1400ff350
```

`0x1400ff350`–`0x1400ff3ad` 는 창을 요구에 맞춘다:

```
0x1400ff364  mov  rcx, [rcx+0x168]            ; hwnd
0x1400ff36b  call IsWindow                    ; 창이 없으면 아무 일도 안 한다
0x1400ff37f  mov  edx, 0xffffffec             ; GWL_EXSTYLE (= -20)
0x1400ff384  call GetWindowLongW
0x1400ff38a  shr  eax, 0x15                   ; 비트 21 = 0x00200000
0x1400ff38d  and  eax, 1
0x1400ff390  cmp  al, r12b                    ; 요구와 다르면
0x1400ff399  mov  rcx, [r14+0x168]
0x1400ff3a0  call DestroyWindow               ; 창을 버리고 다시 만든다
```

**수치(비트 21)와 분기는 확정이고, 이름은 해석이다** — Windows SDK 에서 `0x00200000` 은
`WS_EX_NOREDIRECTIONBITMAP` 이다(`spec/engine/media.json:engine.media.enumInterpretation` 에
`보고` 등급으로 적어 두었다. 이 머신에 SDK 가 없다). 그 해석이 맞다면 배치가 자연스럽다 —
`mfEngine` 계열만 D3D11 공유 서페이스로 합성하므로 DWM 리다이렉션 표면이 필요 없고,
EVR·VMR9 는 HWND 에 직접 그리므로 **반드시 있어야** 한다.

§4.2 가 적어 둔 추측("씬 합성 가능 = 텍스처로 뽑을 수 있음")은 **결과적으로 같은 집합을
가리키지만 이유가 다르다.** 상위 바이트는 씬 마운트 여부를 정하지 않는다 — 그건 팩토리
(`0x140104240`/`0x1401041d0`)가 정한다.

#### 4.5.4 설정 → 백엔드 가상함수 (변경 마스크 표)

라이브 설정 반영 함수 `0x140100720`–`0x1401008da` 가 두 번째 인자로 **변경 마스크**를 받는다
(§4.2 가 기록한 `r12d` 반환 마스크의 소비 쪽이다). 백엔드는 `[player+0x160]`.

| 마스크 | 값 | 백엔드 슬롯 | 근거 VA |
| ---: | --- | --- | --- |
| `0x02` | `[player+9]`(뮤트)면 `0.0f`, 아니면 `[player+0x174]` → `[player+0x170]` 에 기록 | `+0x30` | `0x140100834`–`0x14010085f` |
| `0x04` | `([player+0x17c] >> 4) & 1` — **1 = 하드웨어 가속 끔** | `+0x70` | `0x1401007e3`–`0x1401007ff` |
| `0x08` | `([player+0x17c] >> 3) & 1` — `videoaudiooutput` | `+0x68` | `0x1401007c4`–`0x1401007e0` |
| `0x10` | `[player+0x198]` — `videoloopmode` | `+0x58` | `0x140100802`–`0x140100818` |
| `0x20` | `[player+0x19c]` — `videoreadmode` | `+0x60` | `0x14010081b`–`0x140100831` |
| `0x100` | (인자 없음) | `+0x48` | `0x140100862`–`0x140100872` |
| `0x40`/`0x80` | 볼륨 램프 타이머를 켠다 | — | `0x140100875`–`0x1401008a2` (§8.5) |

플레이어를 **처음 만들 때**도 같은 세 슬롯을 같은 순서로 부른다 —
`+0x60`(리드모드) → `+0x68`(오디오출력) → `+0x70`(하드웨어가속),
`0x140101252`–`0x140101287`. 곧 시작 경로와 라이브 경로가 같은 계약을 쓴다.

**이것이 "하드웨어 디코딩 게이트" 의 착지점이다.** 종전에는 저장 위치(`[player+0x17c] bit4`,
반전)까지만 알고 소비 지점이 없었다. 반전을 잊으면 의미가 그대로 뒤집히므로
`spec/engine/media.json:engine.media.video.backendVtable` 에 문장으로 못박고
`Tests/WapleCoreTests/MediaPlaybackCanonTests.swift` 가 그 문장을 잠근다.

---

## 5. 비디오 월페이퍼 프로퍼티 스키마 `0x140104b60`–`0x140108c17` [이 문서가 새로 확정]

`type:"video"` 월페이퍼는 씬처럼 저작 `general.properties` 가 없다. 대신 **엔진이 wproperties JSON
을 통째로 합성한다.** 시그니처는 `(Json::Value* wproperties, uint32 flags)` 이고, 마운트
디스패처가 이렇게 부른다(`0x14010eb16`–`0x14010eb4b`):

```
r9d = [wallpaper+0x1b8]
edx = ((r9d>>7)&1)<<3 | ((r9d>>5)&1)<<2 | ((r9d>>4)&1) | 0xd0
call 0x140104b60
```

`flags` bit0 이 서면 `volume` 슬라이더를 낸다(`0x140104bf3` `test dl,1`) — 곧
`[wallpaper+0x1b8] bit4` = "오디오 트랙이 있다".

합성되는 프로퍼티 전수:

| 키 | type | 범위/옵션 | condition | icon | VA(라벨 적재) |
| --- | --- | --- | --- | --- | --- |
| `volume` | slider | 0 – 100 | — | `fa-volume-up` | `0x140104b87`·`0x140104e28`(max) |
| `rate` | slider | 10 – 200 | — | `fa-play` | `0x14010525f`(min 0xa)·`0x1401052bf`(max 0xc8) |
| `cameraparallax` | bool | — | — | `fa-mouse-pointer` | `0x1401054ab`(키)·`0x140105626`(아이콘) |
| `alignment` | **combo** | 아래 표 | — | `fa-image` | `0x140105960` |
| `alignmentposition` | slider | 0 – 100 | `alignment.value<2&&checkPositionVisibility()` | `fa-arrows-alt-h` | `0x1401060c9` |
| `alignmentx` | slider | 0 – 100 | `alignment.value==3\|\|alignment.value==4` | `fa-arrows-alt-h` | `0x1401064b9` |
| `alignmenty` | slider | 0 – 100 | `alignment.value==3\|\|alignment.value==4` | `fa-arrows-alt-v` | `0x140106877` |
| `alignmentz` (Zoom) | slider | 0 – **200** | `alignment.value==4` | `fa-expand-arrows-alt` | `0x140106c1f` |
| `alignmentfliph` | bool | — | — | `fa-exchange` | `0x140107007` |
| `wcc_v` | combo | (이미지 필터 프리셋) | — | — | `0x140107160` |
| `wcc_amt` | slider | 0 – 100 | `wcc_v.value`(`0x140488eb0` @`0x140107784`) | — | `0x14010746b` |
| `wec_e` | bool | (색 옵션 표시) | — | — | `0x140107872` |
| `wec_brs` `wec_con` `wec_sa` `wec_hue` | slider | 0 – 100 | `wec_e.value`(`0x140488f20` @`0x140107e10` 외 3) | — | `0x140107b07` 외 |
| `schemecolor` | (문자열) | — | — | — | `0x1400ffeb8`(읽는 쪽) |

**`alignment` 열거 — 이 문서의 확정:**

| 값 | 로케일 키 | 영문 라벨 | 값 적재 VA |
| ---: | --- | --- | --- |
| **0** | `ui_browse_properties_alignment_cover` | Cover | `0x140105a60`(`mov qword [rbp+0x4d0], rbx`, rbx=0 @`0x140105a3c`) |
| **1** | `ui_browse_properties_alignment_fill` | Fill | `0x140105b1c` |
| **2** | `ui_browse_properties_alignment_stretch` | Stretch | `0x140105c93` |
| **3** | `ui_browse_properties_alignment_center` | Center | `0x140105bd5` (`mov edx,3` → `0x140084ef0`) |
| **4** | `ui_browse_properties_alignment_free` | Free | `0x140105d4c` (`mov edx,4` → `0x140084ef0`) |

옵션 5개는 **항상 전부** 나온다 — center/free 를 감싸는 `test r14b,r14b`(`0x140105b7b`·
`0x140105cf2`)의 `r14b` 는 `flags` 하위 바이트인데 호출부가 `| 0xd0` 을 강제하므로 0 이 될 수 없다.

읽는 쪽(`0x1400ffcb0`–`0x1400ffcc1` 계열, 슬롯 오프셋은 `VideoWallpaper` 기준):

| 키 | 변환 | 슬롯 |
| --- | --- | --- |
| `volume` | `/100` | `[+0x170]`·`[+0x174]` |
| `rate` | `/100` | `[+0x178]` |
| `schemecolor` | `strtod ×3` → `×255` → 클램프 0–255 → 바이트 3개 | `[+0x174..0x176]`(라이브 경로 `0x14012a40a`–`0x14012a42d`) |
| `alignment` | 정수 그대로 | `[+0x180]` (라이브 경로 `[+0x160]`) |
| `alignmentposition` `alignmentx` `alignmenty` `alignmentz` | `×0.01` | `[+0x190]` `[+0x184]` `[+0x188]` `[+0x18c]` (라이브 `[+0x170]` `[+0x164]` `[+0x168]` `[+0x16c]`) |
| `wec_e` | `asBool` | — |
| `wec_con` `wec_brs` `wec_sa` `wec_hue` | `/50` | `[+0x1e4]` `[+0x1e8]` `[+0x1ec]` `[+0x1f0]` |

기본값은 엔진이 아니라 UI 가 갖고 있다 —
`ui/dist/scripts/scripts.js` `getSharedDefaultProperties()`:
`{alignment:0, alignmentposition:50, rate:100, volume:50, cameraparallax:true}`
(+ 필요 시 `schemecolor:""`). 곧 **기본 alignment 는 Cover(0), 기본 볼륨 50%, 기본 배속 100%** 다.

> 씬 월페이퍼도 `rate`/`volume` 를 받는다 — 로드 디스패처 `0x140114d45`(`rate`, `/100` 후
> **min 0.1 클램프**, `0x140114d84` f32=0.1) · `0x140114da7`(`volume`, `/100` 후 마스터
> `[+0x174]` 를 곱해 `0x1401816d0` 으로) · `0x140114e2c`(`audioprocessing`) ·
> `0x140114f1f`(`cameraparallax`). 즉 볼륨/배속은 비디오 전용 개념이 아니다.

---

## 6. `MediaPlaybackEvent` 스크립트 API (과제 3)

### 6.1 실체 — 시스템 미디어 세션이지 월페이퍼 비디오가 아니다

`bin/scenescript64.dll` 의 ASCII 문자열에 훅 이름 5개가 있다:
`mediaStatusChanged` · `mediaPlaybackChanged` · `mediaPropertiesChanged` ·
`mediaThumbnailChanged` · `mediaTimelineChanged`. UTF-16 판은 없다.

원천은 **별도 프로세스**다:

* `bin/winrtutil64.exe` 가 `-mediainterface` 스위치를 받고(ASCII `-mediainterface`),
  UTF-16 문자열
  `Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager` 를 활성화한다.
  RTTI 에 `RunMediaInterface@@YAHXZ` 람다 6개가 남아 있고, PDB 경로가
  `…\cppwinrt\winrt/Windows.Media.Control.h` 를 가리킨다.
* `wallpaper64.exe` 쪽 짝은 `DesktopMediaExtensions::StartMediaControl`(RTTI
  `.?AV<lambda_1>@?1??StartMediaControl@DesktopMediaExtensions@@AEAAXXZ@`)이고,
  설정 키는 `mediaintegration`(`0x140476...`, config `general/user/mediaintegration: true`)·
  `mediablocklist`.

곧 **SMTC(시스템 미디어 전송 컨트롤)** 이다 — 지금 데스크톱에서 재생 중인 음악/영상의
제목·아티스트·썸네일·재생상태를 월페이퍼 스크립트에 배달한다.

선언(`ui/dist/monaco/autocomplete/lib.sceneScript.d.ts`, `docs/re/scene-script-api.md` §1 의
표와 같은 파일) 전수:

| 클래스 | d.ts 행 | 필드 | 정적 상수 | 메서드 |
| --- | ---: | --- | --- | ---: |
| `MediaStatusEvent` | 1166 | `enabled: Boolean` | — | 0 |
| `MediaPlaybackEvent` | 1126 | `state: Number` | `PLAYBACK_STOPPED=0` `PLAYBACK_PLAYING=1` `PLAYBACK_PAUSED=2` | 0 |
| `MediaTimelineEvent` | 1151 | `position` `duration`(초) | — | 0 |
| `MediaPropertiesEvent` | 1051 | `title` `artist` `subTitle` `albumTitle` `albumArtist` `genres`(콤마 구분) `contentType` | — | 0 |
| `MediaThumbnailEvent` | 1091 | `hasThumbnail` `primaryColor` `secondaryColor` `tertiaryColor` `textColor` `highContrastColor`(전부 Vec3, 정규화 rgb) | — | 0 |

발화 시점(d.ts `IComponent` 훅 주석 원문):

| 훅 | 시점 |
| --- | --- |
| `mediaStatusChanged` | 사용자가 미디어 연동을 켜거나 끌 때 |
| `mediaPlaybackChanged` | 사용자가 미디어를 시작·정지·일시정지할 때 |
| `mediaPropertiesChanged` | 현재 재생 중 미디어의 속성이 바뀔 때 |
| `mediaThumbnailChanged` | 썸네일이 바뀔 때 |
| `mediaTimelineChanged` | 재생 위치가 바뀔 때 — **"특정 앱만 제공한다"** |

**메서드가 0개다.** `MediaPlaybackEvent` 로는 `play`/`pause`/`seek`/`volume` 중 무엇도 못 한다.
월페이퍼 자신의 비디오는 더더욱 못 건드린다 — 이 이벤트의 주체는 데스크톱의 **다른 앱**이다.

### 6.2 스크립트가 재생을 제어하는 진짜 표면

`IImageLayer` 등록부(`0x140211070`–`0x140212523`)에 두 진입점이 있다:

| 등록 이름 | 문자열 VA | 적재 VA | 반환 |
| --- | --- | --- | --- |
| `getTextureAnimation` | `0x140490df0` | `0x14021122c` | `ITextureAnimation`(스프라이트시트/GIF) |
| `getVideoTexture` | `0x140490e08` | `0x1402112e6` | `IVideoTexture`(비디오 파일) |

**`IVideoTexture` 등록부 `0x140214050`–`0x140214799`** — 등록 이름 전수(디스어셈에서 추출한
문자열 집합, 10개):

| 이름 | 종류 | 문자열 VA | d.ts 행 |
| --- | --- | --- | ---: |
| `duration` | readonly 프로퍼티 | `0x140489b60` | 1377 |
| `rate` | 프로퍼티 | `0x1404884a4` | 1382 |
| `loop` | 프로퍼티 | `0x140490a74` | 1387 |
| `play` | 메서드 | `0x140473b3c` | 1392 |
| `pause` | 메서드 | `0x140473b2c` | 1397 |
| `stop` | 메서드 | `0x140473b34` | 1402 |
| `isPlaying` | 메서드 | `0x14048de88` | 1407 |
| `getCurrentTime` | 메서드 | `0x140491000` | 1412 |
| `setCurrentTime` | 메서드 | `0x140490ff0` | 1417 |
| `addEndedCallback` | 메서드 | `0x140491068` | 1422 |

**`volume` 은 등록부에도 d.ts 에도 없다.** 스크립트는 비디오 텍스처의 음량을 못 바꾼다
(월페이퍼 전체 볼륨은 `wproperties.volume` 사용자 속성으로만 — §5).

**`ITextureAnimation` 등록부 `0x1402131a0`–`0x14021387a`** — 10개:
`frameCount`(`0x14048de98`) · `duration` · `rate` · `play` · `pause` · `stop` · `isPlaying` ·
`getFrame`(`0x14048de68`) · `setFrame`(`0x14048de78`) · **`join`**(`0x140490fe4`).
`join` 은 "이 텍스처를 쓰는 모든 머티리얼의 공유 애니메이션 타이머에 **다시 합류**"다
(d.ts:1364) — `spritesheetrefreshsync` 의 스크립트 쪽 짝이다.

두 인터페이스의 표면 차이가 그대로 두 재생 모델의 차이다:

| | `ITextureAnimation`(시트) | `IVideoTexture`(비디오) |
| --- | --- | --- |
| 위치 단위 | **프레임**(`getFrame`/`setFrame`) | **초**(`getCurrentTime`/`setCurrentTime`) |
| 총량 | `frameCount` + `duration` | `duration` 만 |
| 루프 | 없다(d.ts:1329 에 `//loop: Boolean;` 로 **주석 처리**돼 있다 — 시트는 항상 순환) | `loop` 프로퍼티 있음 |
| 전역 동기화 | `join()` | 없다(엔진 시계가 따로) |
| 종료 통지 | 없다 | `addEndedCallback` |

`docs/re/scene-script-api.md` §1 의 컨테이너 표(`ITextureAnimation` 7메서드/3프로퍼티,
`IVideoTexture` 7메서드/3프로퍼티)와 위 등록부 개수가 **정확히 일치**한다 — 선언과 구현이
갈라진 자리가 없다.

---

## 7. 스프라이트시트 경로 (과제 4)

### 7.1 저작 폼 3종

설치본+동봉 `.tex-json` 388건을 파싱해 얻은 루트 키 도수(동봉 298건만 센
`docs/re/tex-format.md` §4 표를 **설치본까지 넓힌 값**):

| 키 | 파일 |
| --- | ---: |
| `format` | 379 |
| `clampuvs` | 324 |
| `nonpoweroftwo` | 291 |
| `nomip` | 170 |
| `alphachannelpriority` | 82 |
| **`spritesheetsequences`** | **58** |
| `bleedtransparentcolors` | 51 |
| `nointerpolation` | 47 |
| `srgb` | 10 |
| **`spritesheet`** | **6** |
| **`imagesequence`** | **3** |
| **`frameduration`** | **3** |
| `halfmip` `forcerawcompression` | 각 2 |

`spritesheetsequences[]` 의 원소 키는 **전건 `{duration, frames, width, height}` 4개뿐**
(58/58) — `name` 은 저작 폼에 **없다**. §7.2 의 런타임 객체가 `name` 을 노출하는데도 그렇다.

`srgb`/`spritesheet`/`imagesequence`/`frameduration` 4키는 동봉 298건에는 없고
설치본 `projects/defaultprojects/` 에만 나온다 — `docs/re/tex-format.md` §4 표에 없는 값이다.
저작 폼은 셋으로 갈린다:

| 폼 | 키 | 예 |
| --- | --- | --- |
| A. 이미 시트인 이미지 | `spritesheet: true` + `spritesheetsequences[{duration,frames,w,h}]` | `dino_run/materials/tard_walk.tex-json` (`duration 0.6`, `frames 6`, 24×24) |
| B. 낱장 시퀀스 | `frameduration: <초>` + `imagesequence: [파일…]` | `dino_run/materials/coin_0.tex-json` (`0.2`s × `coin_0..3.png`) |
| C. GIF | (사이드카에 시트 키 없음) — `assets/scenes/gifs/materials/background.tex-json` 처럼 `nonpoweroftwo/nointerpolation/clampuvs/nomip/format` 만 | 컴파일러가 GIF 프레임에서 시트를 만든다 |

B 의 `imagesequence` 는 확장자가 섞여도 된다 —
`vita_walk_01.tex-json` 이 `["vita_walk_01.png", "vita_walk_02.gif", …]` 다.

세 폼 모두 **컴파일 산출물은 같다**: `.tex` 헤더 `flags & 0x4` + TEXS 섹션
(`docs/re/tex-format.md` §4.1 의 52/52 대조).

### 7.2 런타임 시퀀스 객체 `0x140177f70`–`0x1401786f1` [이 문서가 새로 확정]

프로퍼티 시스템 레지스트리(`0x1404e8140`)에 11개 멤버를 등록한다. 등록 헬퍼
`0x14015a000`, 이름 복사 `0x14000f880`, 디스크립터 레코드는 `[reg+0x30]`=타입코드
(0=int, 4=float, 5=string), `[reg+0x34]`=멤버 오프셋(값 프로퍼티일 때), `[reg+0x38/0x48/0x50]`=핸들러.

객체 본체는 `[wrapper+0xC8]` 가 가리키는 **재생 상태 구조체**다. 게터를 전부 디스어셈해
필드 배치를 확정했다:

| 멤버 | 타입 | 핸들러 VA | 하는 일 | 구조체 필드 |
| --- | --- | --- | --- | --- |
| `rate` | float | `0x1401a4b00` / `0x1401a49f0` / `0x1401a4a10` | 값 프로퍼티(오프셋 `0xd0`, `[reg+0x34]=0xd0` @`0x140178022`) | wrapper `+0xd0` |
| `fps` | float | `0x140170770` | `1.0f / [seq+0x38]` | 파생값 — **저장 안 함** |
| `frameCount` | int | `0x140170790` | `[seq+0x48]` | `+0x48` |
| `duration` | float | `0x1401707a0` | `[seq+0x40]` | `+0x40` |
| `name` | string | `0x1401707b0` | `[seq+0x68]`(SSO std::string, 길이 `+0x78`, 용량 `+0x80`) | `+0x68` |
| `play` | 메서드 | `0x1401707f0` | `if (flags & 0x40000000) time = 0;` 후 `flags &= ~0x60000000` | `+0x3c`, `+0x44` |
| `pause` | 메서드 | `0x140170820` | `flags \|= 0x20000000` | `+0x44` |
| `stop` | 메서드 | `0x140170830` | `flags \|= 0x20000000; flags &= 0x3fffffff; time = 0` | `+0x3c`, `+0x44` |
| `isPlaying` | 메서드 | `0x140170860` | `(flags & 0x60000000) == 0` | `+0x44` |
| `setFrame` | 메서드 | `0x140170880` | `time = frametime * arg` | `+0x3c` |
| `getFrame` | 메서드 | `0x1401708a0` | `time / frametime` (**float 반환** — 정수 아님) | `+0x3c` |

구조체 요약:

| 오프셋 | 타입 | 의미 |
| --- | --- | --- |
| `+0x38` | float | **프레임타임**(초/프레임). `fps` 의 역수원 |
| `+0x3c` | float | 현재 시각(초) |
| `+0x40` | float | 총 재생길이(초) |
| `+0x44` | uint32 | 플래그. bit29(0x20000000)=일시정지, bit30(0x40000000)=정지(다음 `play` 에 0 으로 되감음) |
| `+0x48` | int32 | 프레임 수 |
| `+0x68` | std::string | 시퀀스 이름 |

**이 절이 `docs/re/tex-format.md` §5 의 `[미해결]` 을 일부 좁힌다.** 그 문서는
"TEXS 리더가 총 재생길이를 누적만 하고(`0x14015e514`) 그 값을 읽는 소비처를 특정하지 못했다"
고 적었다. 소비 표면이 여기다 — `duration`(`+0x40`)과 `frameCount`(`+0x48`)를 스크립트에
그대로 내주고, `fps`/`getFrame`/`setFrame` 은 전부 `+0x38`(프레임타임) **하나**를 기준으로
계산한다. 곧 **WE 런타임은 프레임별 frametime 을 재생에 쓰지 않고 시퀀스당 단일
frametime 을 쓴다**(적어도 이 객체 경로에서는). **[미해결]** — `+0x38`/`+0x40`/`+0x48` 을
TEXS 값에서 채우는 초기화 코드는 특정하지 못했다. `0x14015e1d0`–`0x14015e57c` 의 TEXS 리더가
쓰는 구조체(`[rdi]` 누적 duration, `[rdi+0x10..0x20]` 프레임 벡터)와는 **다른 구조체**다.

`name` 이 저작 폼에 없는데 노출되는 이유도 미확정이다 — `.tex-json` 58건 전부 `name` 이
없다(§7.1). 에디터가 만드는 다중 시퀀스(`spritesheetsequences[]` 길이 > 1) 자산이
코퍼스에 없어 확인할 표본이 없다. **[미해결]**

### 7.3 세 재생 객체의 관계

| | 시퀀스 객체 `0x140177f70` | `ITextureAnimation` `0x1402131a0` | `IVideoTexture` `0x140214050` |
| --- | --- | --- | --- |
| 노출 경로 | 프로퍼티 시스템(에디터/내부) | 스크립트 `getTextureAnimation()` | 스크립트 `getVideoTexture()` |
| `rate` `duration` `play` `pause` `stop` `isPlaying` | ✔ | ✔ | ✔ |
| `frameCount` `getFrame` `setFrame` | ✔ | ✔ | ✘ |
| `fps` | **✔** | ✘ | ✘ |
| `name` | **✔** | ✘ | ✘ |
| `join` | ✘ | **✔** | ✘ |
| `loop` `getCurrentTime` `setCurrentTime` `addEndedCallback` | ✘ | ✘ | **✔** |

세 등록부는 서로 다른 함수이고 이름 문자열만 공유한다. `fps`/`name` 이 스크립트 d.ts 에
없는 것이 시퀀스 객체가 **스크립트 표면이 아님**을 보여 준다.

> 같은 골격의 네 번째 등록부 `0x14026c980`–`0x14026d5de` 는 `IAnimationLayer`(퍼펫)다 —
> 위 이름들에 `blendin`/`blendout`/`blendtime`/`additive`/`visible` 이 붙는다.
> `docs/re/skeleton-animation.md` 소관이라 여기서는 다루지 않는다.

---

### 7.4 `spritesheetrefreshsync` 의 소비 지점 [2026-08-21 신규 — §2.2 의 `[미해결]` 을 닫는다]

> **이 절의 VA 는 전부 `wallpaper64.exe`(imagebase `0x140000000`)다.**

종전 기록(`SceneDocument.spritesheetRefreshSync` 선언부)은 "`[reg+0xE0]` 접근 928곳 중 마스크
`0x40` 근처는 프로젝트 플래그 집계 두 벌뿐" 이라고 적고 멈췄다. 그 스캔이 놓친 것은
**비트를 마스크로 검사하지 않고 워드째 실어 `shr` 로 꺼내는** 형태다.

**① 파스** — 씬 플래그 워드 `[scene+0xE0]` bit6: `0x140187674  or dword [r14+0xe0], 0x40`
(씬 문서 파서 `0x140186c90`–`0x1401872ba`).

**② 월페이퍼로 옮겨 싣는다** — 월페이퍼 로드 디스패처(`0x140113c80`–`0x140113d64` 조각):

```
0x140114cea  call 0x140181af0                ; 씬 객체
0x140114d0a  mov  eax, dword [rax+0xe0]      ; 씬 플래그 워드
0x140114d10  shr  eax, 6
0x140114d13  test al, 1                      ; ← bit6
0x140114d15  je   0x140114d1e
0x140114d17  or   dword [rsi+0x1b8], 4       ; 월페이퍼 플래그 bit2
```

짝인 초기화는 `0x1401148c4  and dword [rsi+0x1b8], 0xfffffffb`(bit2 clear)다.
`[wallpaper+0x1b8]` 은 §5 가 이미 쓰는 그 워드다(bit4 = 오디오 트랙 있음, bit6 = 음소거 §8.1).

**③ 소비** — 씬 생성 함수(`0x140110630`–`0x140113bc0`) 끝머리:

```
0x140113510  test byte [r15+0x1b8], 4        ; ← 여기가 소비 지점이다
0x140113518  je   0x1401135ee
0x14011351e  mov  rax, [r15+0x180]           ; 씬
0x140113528  mov  rbx, [rcx+0x158]           ; 레이어 벡터 begin
0x14011352f  mov  rsi, [rcx+0x160]           ; end
0x140113549  call [rax+0x60]                 ; 레이어마다 종류를 묻는다
0x14011354c  cmp  eax, 1                     ; 1 인 첫 레이어를 고른다
0x14011355c  mov  rax, [rdi+0x498]
0x140113563  mov  rdx, [rax+0xd0]            ; 그 레이어의 시퀀스 객체
0x14011356f  mov  eax, [rdx+0x1c] / shr 2 / test al,1   ; 시퀀스가 재생 중인가
0x140113579  mov  rcx, [rdx+0xc0] / r8 = [rdx+0xb8]     ; 프레임 시각 벡터(스트라이드 0x20)
0x14011358c  movsxd rax, [rdx+0x9c]                     ; 현재 프레임 인덱스
0x1401135af  movss xmm0, [rax]                          ; 그 프레임의 시각
0x1401135b3  subss xmm0, [rdx+0xa0]                     ; − 현재 시각  = 남은 시간
0x1401135bb  comiss xmm0, xmm7 / ja                     ; 음수면 0 으로
0x1401135c3  movss xmm1, [r15+0x190]                    ; 월페이퍼 배속(§5 의 rate)
0x1401135cc  comiss xmm1, xmm10 / jbe                   ; 배속 > 0.001 일 때만
0x1401135d2  divss xmm0, xmm1                           ;   남은 시간 / 배속
0x1401135d6  minss xmm0, xmm15                          ; 상한
0x1401135db  mulss xmm0, 1000.0f                        ; 0x140492944 — 초 → ms
0x1401135e3  cvttss2si rcx, xmm0
0x1401135e8  call Sleep                                 ; IAT 0x140426170
```

곧

```
wait = max(nextFrameTime - now, 0) / (rate > 0.001 ? rate : 1)
Sleep(min(wait, 0.25) * 1000)
```

`[wallpaper+0x190]` 이 `rate` 라는 것은 저장 자리에서 확인했다 —
`0x140114d98  movss [rsi+0x190], xmm0` 이고 `xmm0 = max(rate/100, 0.1)`
(`0x140114d8c  divss xmm0, 100.0f` @`0x1404928f8` · `0x140114d90  comiss` vs `0.1f` @`0x140492654`).
저작이 없으면 생성자 기본값이 남으므로 `> 0.001` 가드가 장식이 아니다.

**레지스터 상수의 지배관계**(함정 5). `xmm7` 은 이 함수 안에서 두 번 대입되는데
(`0x140110c95`·`0x140111bc1`) **둘 다 `xorps`** 라 어느 경로로 와도 `0.0` 이다 — 확정.
`xmm15`(상한)와 `xmm10`(배속 하한)은 프롤로그(`0x140110ca7` = `0.25` @`0x14049268c` ·
`0x140110cc2` = `0.001` @`0x140492608`)와 복원 자리(`0x140112656` · `0x14011266f`)에서
**같은 상수를 두 번 싣는다.** 그 사이 `0x14011173a`·`0x140111823` 이 두 레지스터를 스크래치로
쓰지만 복원이 그 뒤에 있다. 그래서 `0x1401135bb` 시점 값은 `0.25`/`0.001` 로 본다 —
**CFG 를 끝까지 풀지는 않았다**는 것을 밝혀 둔다.

**무엇이 확정이고 무엇이 아닌가.**

| | 상태 |
| --- | --- |
| bit6 → `[wallpaper+0x1b8] bit2` 로 옮겨진다 | **확정** (`0x140114d0a`–`0x140114d17`) |
| bit2 가 씬 생성 끝에서 `Sleep` 을 건다 | **확정** (`0x140113510` → `0x1401135e8`) |
| 잠자는 시간 = 다음 프레임 경계까지, 배속으로 나누고 상한 | **확정** (산식 위) |
| 상한 0.25s · 배속 하한 0.001 | 거의 확정 — 위 지배관계 문단 |
| `vtbl+0x60` 이 `1` 을 내는 레이어가 무엇인가 | **[미해결]** — 종류 열거를 안 뜯었다 |
| 시퀀스 객체 `[rdx+0x1c]` bit2(재생 중)와 §7.2 의 `+0x44` bit29/30 의 관계 | **[미해결]** — 두 구조체가 같은 것인지 확인 안 했다 |

**Waple 대조.** `SceneDocument.spritesheetRefreshSync` 는 "파스·보존 전용" 이다. 이식은
`SceneRendererFrameEncoder.spriteFrameTexture` 가 "절대 씬 시간의 순수 함수" 라는 계약과
**충돌하지 않는다** — WE 도 레이어별 시계를 만드는 게 아니라 **씬 시작 시각을 늦출 뿐**이다.
§9.2 의 G8 이 지목한 "레이어별 시계" 비용은 이 키 때문이 아니라 `ITextureAnimation.setFrame`
때문이라는 것이 이번에 갈렸다. §9.2 G12 에 갭 **G19** 로 올린다.

---

## 8. 오디오 (과제 5)

### 8.1 `videoaudiooutput` 은 2단 게이트다 [이 문서가 새로 확정]

`spec/engine/media.json` 은 이 키를 "bool(기본 true)" 로만 적었다. 실제로는 **전역값과
모니터별(`general.location`) 값의 AND** 다. 두 자리에서 같은 규약을 쓴다:

**① 플레이어 설정 적용 `0x1400ff8fd`–`0x1400ff985`**

```
rbx = root["general"]["location"]            ; 0x1400ff8e7 "location"
al  = root["videoaudiooutput"].asBool()      ; 0x1400ff8fd
if (!al) dl = 0
else if (rbx.tag != 7) dl = 1                ; location 이 객체가 아니면 통과
else if (!rbx.find("videoaudiooutput")) dl = 1
else dl = rbx["videoaudiooutput"].asBool()
[player+0x17c] bit3 = dl                     ; 0x1400ff96e–0x1400ff985
```

**② 마운트 디스패처 `0x14010e074`–`0x14010e0ee`** — 같은 2단 판정을 하고 결과를 **반대로**
저장한다: 통과면 `and [wallpaper+0x1b8], ~0x40`(bit6 clear), 아니면 `or …, 0x40`(bit6 set).
곧 **`[wallpaper+0x1b8] bit6 = 음소거**다.

### 8.2 라우팅 — 세 경로

| 프레임워크 | 오디오 렌더러 | 볼륨 조작 | 음소거 |
| --- | --- | --- | --- |
| `mfEngine` | Media Engine 내부(기본 엔드포인트) | `IMFMediaEngine::SetVolume(double)` = vtable `+0x128`, 인자 `[[player+0x50]+0x2d8]`(float→double), `0x1400f2461`–`0x1400f2477` | `CreateInstance` dwFlags 에 `FORCEMUTE`(0x4) 추가 (`0x1400f2407`·`0x1400f2415`) |
| `mf` | `MFCreateAudioRendererActivate` → SAR | `IMFAudioStreamVolume` | `mf.muted` 후보로 재시도 |
| `dshow.lav.vmr9` | `CLSID_DSoundRender`(`0x14042c350`) | `IID_IBasicAudio`(`0x14048a228`) | — |
| 씬 `sound` 레이어 | OpenAL Soft(`bin/mediaextensions64.dll`) | `alSourcef(AL_GAIN,…)` | — |

Media Engine 경로에서 볼륨/뮤트를 가르는 바이트는 `[player+0x21]` 하나이고, 그 값은
`[[player+0x50]+0x118]` 의 **bit17** 이다(`0x1400f20b3`–`0x1400f20c2`). 같은 바이트가
`MF_MEDIA_ENGINE_EXTENSION`(GUID `0x140486168` = `3109FD46-060D-4B62-8DCF-FAFF811318D2`)
설치 여부도 가른다 — **0 일 때만** 설치한다(`0x1400f23ac` `cmp`/`jne`). `spec/engine/media.json`
의 `engine.media.unknowns` 가 남긴 "왜 오디오가 꺼졌을 때만 설치되는가"는 여전히 미해결이고,
여기서 더 좁힌 것은 **그 바이트의 출처가 `[owner+0x118]` bit17** 이라는 것뿐이다.
그 비트를 세우는 코드를 `.text` 전수(`or dword [reg+0x118], imm & 0x20000` 패턴)로 찾았으나
**0건**이다 — 다른 워드에서 접혀 들어오는 것으로 보이나 특정하지 못했다. **[미해결]**

### 8.3 오디오 반응 스펙트럼에 섞이는가 — **섞인다**

근거 세 가지(모두 부재 증명 + 구조):

1. WE 의 캡처는 **WASAPI 루프백**이다 — `docs/re/audio-capture.md` §1.4 가
   `esi = (loopback ? 1 : 0) << 17` (`AUDCLNT_STREAMFLAGS_LOOPBACK`, `0x1400cf663`)로
   기록해 두었다. 루프백은 **엔드포인트 믹스 전체**를 준다. 자기 프로세스 제외 옵션은 없다.
2. WE 는 비디오 오디오를 **기본 렌더 엔드포인트**로 보낸다. `MF_MEDIA_ENGINE_AUDIO_CATEGORY`
   (`C8D4C51D-…`)도 `MF_MEDIA_ENGINE_AUDIO_ENDPOINT_ROLE`(`D2CB93D1-…`)도 exe 에 바이트열이
   **없다**(§부록 A.4). 곧 별도 카테고리·엔드포인트로 격리하지 않는다.
3. 반대로 격리했다는 흔적(전용 세션·프로세스 루프백 `AUDIOCLIENT_ACTIVATION_PARAMS`,
   `ActivateAudioInterfaceAsync`)도 없다.

곧 **비디오 사운드를 켠 채 오디오 반응 씬을 띄우면 그 씬은 자기 소리에 반응한다.**
사용자가 이 되먹임을 끄는 스위치는 `videoaudiooutput`(§8.1) 하나뿐이다.

**[미해결]** — 이것은 구조적 추론이고, 실행 관측은 하지 않았다(Windows 실행 환경 없음).
"섞이지 않게 하는 코드가 없다" 까지가 확정이고 "실제로 섞인다"는 그 따름이다.

### 8.4 `playbackaudio` — 이미 있는 문서로

다른 앱이 소리를 낼 때의 정책 축이다. 문자열→열거 사상은
`0x140141880`–`0x14014191a`: `"stop"`→4 · `"pauseall"`→3 · `"pause"`→2 · `"mute"`→1 ·
그 외(기본 `"run"`)→0, 전역 `0x1404e53d4`. 판정 순서·다른 축과의 상호작용은
`Sources/WaplePolicy/PlaybackPolicy.swift` 가 이미 전부 갖고 있다 — 여기서 반복하지 않는다.

---

### 8.5 볼륨은 즉시 바뀌지 않는다 — 25ms 램프 [2026-08-21 신규]

> **이 절의 VA 는 전부 `wallpaper64.exe`(imagebase `0x140000000`)다.**

`spec/engine/media.json` 은 볼륨을 "`IMFMediaEngine +0x128 (double)`. 오디오 출력이 켜졌을 때만
호출" 로만 적었다. **그 앞에 램프가 하나 더 있다.** 사용자가 볼륨 슬라이더를 움직이거나,
정책이 월페이퍼를 음소거·일시정지시키면 값이 한 번에 가지 않고 **틱마다 조금씩 간다.**

**타이머.** 변경 마스크 `0x40`(음소거) 또는 `0x80`(일시정지)이 오면:

```
0x140100875  test dil, 0xc0
0x14010087b  mov  eax, [rbx+0x17c]
0x140100881  shr  eax, 1
0x140100883  test al, 1
0x140100885  jne  0x1401008c1                 ; 이미 램프 중이면 다시 켜지 않는다
0x140100891  mov  edx, 0x65                   ; 타이머 id 101
0x140100896  mov  r8d, 0x19                   ; 25 ms
0x14010089c  call SetTimer                    ; SetTimer(hwnd, 0x65, 25, NULL)
0x1401008a2  or   dword [rbx+0x17c], 2        ; bit1 = 램프 중
```

**틱 본체**는 `VideoWallpaper` 창 프로시저(`0x140101c50`–`0x140102248`)의 `WM_TIMER` 팔,
산술은 `0x140102092`–`0x140102181`. 정리하면:

```
target  = [player+0x174]                       ; 사용자 볼륨 0..1
silent  = (target == 0) || !(flags bit3)       ; bit3 = videoaudiooutput   (0x140102092–0x1401020b4)
goal    = (muted || paused) ? 0.0f : target    ; muted=[player+9], paused=[player+8]  (0x1401020ba)
cur     = [player+0x170]

if (cur == goal)      done
else if (silent)      cur = goal                                  ; 램프 없이 즉시  (0x1401020de)
else if (cur > goal)  cur -= target*0.03f + 0.02f                 ; 0x1401020ed·0x1401020f5·0x1401020fd
else                  cur += target*0.01f + 0.01f                 ; 0x140102106·0x14010210e·0x140102112·0x140102116

[player+0x170] = cur;  backend->vtbl[0x30](cur)                   ; 0x140102129 / 0x140102170
if (도달) { if (paused) backend->vtbl[0x10](); KillTimer(0x65); flags &= ~2 }
                                                                  ; 0x14010213a–0x140102164
```

상수 VA: `0.03f` `0x140492634` · `0.02f` `0x14049262c` · `0.01f` `0x140492620`
(마지막 것은 재생목록 타이머의 `delay` 하한과 **같은 상수 풀 항목**이다 —
`docs/re/playlist-transition.md` §6.1).

세 가지가 여기서 새로 확정된다.

1. **오르내림이 비대칭이다.** `target = 1.0` 에서 내려갈 때 틱당 `0.05`(→ 20틱 = **500 ms**),
   올라갈 때 틱당 `0.02`(→ 50틱 = **1250 ms**). 정확히 **2.5배**다. 그리고 두 계단 다
   `target` 에 비례하는 항 + 상수항이라, 작은 볼륨에서는 상수항이 지배해 **더 빨리** 끝난다.
2. **일시정지는 소리를 끊는 게 아니라 fade-out 이다.** `paused` 면 목표가 0 이 되고,
   백엔드의 정지(`vtbl+0x10`)는 램프가 **끝난 뒤에야** 불린다(`0x14010213a`–`0x14010214a`).
   곧 `playbackfocus`/`playbackaudio` 정책이 월페이퍼를 멈출 때 소리가 500 ms 에 걸쳐 빠진다.
3. **뮤트는 별도 API 가 아니라 볼륨 0 이다.** 백엔드에 mute 호출이 따로 없다 —
   `[player+9]` 가 목표를 0 으로 만들 뿐이다. (`mfEngine.muted` 의 `FORCEMUTE` 는 **생성 시**
   결정이라 이 축과 다르다, §4.2.)

**들어오는 문**은 둘 다 가상 함수다:

| 진입 | 저장 | 마스크 | vtable 슬롯(.rdata) |
| --- | --- | ---: | --- |
| `setPaused` `0x1400fe970`–`0x1400fe9a8` | `[this+8]` (`0x1400fe979`) | `0x80` (`0x1400fe990`) | `0x140488998` |
| `setMuted` `0x1400fe9b0`–`0x1400fe9e8` | `[this+9]` (`0x1400fe9b9`) | `0x40` (`0x1400fe9d0`) | `0x1404889a0` |

둘 다 `IsWindow([this+0x168])` 로 창이 살아 있는지 본 뒤 `0x140100720`(§4.5.4) 으로
**꼬리점프**한다. 직접 `call` 하는 자리가 이미지에 **0곳**이므로(가상 디스패치만 있다)
"어느 정책이 이걸 부르는가" 는 이 문서 범위에서 특정하지 못했다 — **[미해결]**.
확정된 것은 "정책 축이 미디어에 닿는 문은 이 둘뿐이고, 그 문을 지나면 반드시 램프를 탄다"
까지다.

**Waple 대조.** `Sources/WapleRender/VideoRenderer.swift` 는 두 자리에서 **즉시 대입**한다 —
`queue.volume = volume` / `queue.isMuted = volume <= 0`(attach 경로)과
`player.volume = volume` / `player.isMuted = volume <= 0`(라이브 반영 경로). 램프가 없다.
§9.2 에 갭 **G18** 로 올린다.

---

## 9. Waple 갭과 macOS(AVFoundation/VideoToolbox) 이식 난이도 (과제 7)

### 9.1 이미 맞는 것 (다시 손대지 말 것)

| 항목 | Waple | 근거 |
| --- | --- | --- |
| 비디오는 씬이 아니라 별도 렌더러 | `VideoRenderer.swift` (AVPlayerLayer) | WE 도 별도 창(§3.1) — 구조 동형 |
| 씬 안 비디오 텍스처는 레이어로 합성 | `SceneVideoLayer.swift`(클래스 doc, `씬을 통째로 VideoRenderer 로 스왑` 문단) | WE 의 `videotex` 유저텍스처 슬롯과 동형 |
| 루프 | `AVPlayerLooper`(`VideoRenderer.attachPlayer`) / `actionAtItemEnd = .none` + **종료 시 `seek(0)` 수동 루프**(`SceneVideoLayer.startLive`) | WE 는 `SetLoop(TRUE)`(`0x1400f244d` `mov edx,1` → `0x1400f2455` `call [rax+0xF8]`) — 엔진 내부 루프. **두 경로 중 `SceneVideoLayer` 는 seek 로 감는다** — 아래 정정 |
| 배속 시 음정 유지 | `item.audioTimePitchAlgorithm = .spectral`(`VideoRenderer.attachPlayer`) | WE 도 MF 기본이 그렇다(별도 상수 없음) |
| 가림 시 정지 | `VideoRenderer.attachPlayer` 의 `occlusionObserver` | WE 는 `playbackfocus` 축(PlaybackPolicy) |
| `.tex` 시트 프레임 인덱스 | `TexImage.spriteFrameIndex` | `docs/re/tex-format.md` §5 가 이미 정합 |

> **[2026-08-28 정정 · 루프 행] "seek 로 감지 않는 것까지 같다" 는 거짓이다.**
>
> Waple 은 **루프 경로가 둘**이고 서로 다르다:
>
> | 경로 | 방식 | 위치 |
> | --- | --- | --- |
> | 전체화면 비디오 벽지 | `AVPlayerLooper` — seek 안 한다 | `VideoRenderer.attachPlayer` |
> | **씬 안 비디오 텍스처** | **`AVPlayerItemDidPlayToEndTime` → `seek(to: .zero)` + `play()`** | `Sources/WapleRender/SceneVideoLayer.swift:185-187` |
>
> ```swift
> // SceneVideoLayer.swift:185-187
> endObserver = NotificationCenter.default.addObserver(
>     forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
> ) { [weak p] _ in p?.seek(to: .zero); p?.play() }
> ```
>
> 같은 파일 `:182-184` 의 주석이 **이유까지 적어 두었다**: `AVPlayerLooper` 는 매 루프마다
> 아이템을 교체하는데, 부착한 `AVPlayerItemVideoOutput` 이 새 아이템을 못 따라간다 —
> 그래서 output 기반 재생에서는 단일 아이템 + 수동 seek 가 표준 패턴이다.
>
> ⇒ **`SceneVideoLayer` 는 "다시 손대지 말 것" 목록에 넣을 수 없다.** 이 행이 주장하는
> 동형성은 `VideoRenderer` 쪽에만 해당한다. 씬 경로는 seek 왕복만큼의 **루프 이음매 지연**이
> WE 의 엔진 내부 루프보다 크고, 그 크기는 측정한 적이 없다.
> **[미해결 — 씬 비디오 루프 이음매 지연]**
>
> (다만 위 주석대로 이것은 **AVFoundation 이 강제하는 제약**이지 태만이 아니다. 고치려면
> output 을 쓰지 않는 별도 합성 경로가 필요하다 — 그건 G7/G8 급 비용이다.)

### 9.2 갭 — 파일:줄 + 이식 난이도

| # | 갭 | Waple 위치 | WE 근거 | 난이도 | 이유 |
| --- | --- | --- | --- | --- | --- |
| **G1** | **`alignment` 5모드가 없다.** Waple 은 전역 `FitMode` 3종(`fit`/`fill`/`stretch`)뿐이고 **월페이퍼별이 아니라 앱 전역 설정**이다 | `SceneRenderSettings.swift` — `enum FitMode` · `SceneRenderSettings.fitMode`(전역 getter) · `VideoRenderer.attachPlayer`(`switch SceneRenderSettings.fitMode` → `videoGravity`) | §5 표 — cover(0)/fill(1)/stretch(2)/center(3)/free(4) **+ 월페이퍼별 wproperty** | **중** | AVPlayerLayer 의 `videoGravity` 는 3종밖에 없다. center/free 는 `AVPlayerLayer.frame` 을 직접 계산하거나 `contentsRect`(CALayer)로 크롭해야 한다 — 가능하지만 새 코드다. 저장은 `VideoSettings` 에 키 하나 더 |
| **G2** | **`alignmentposition`/`x`/`y`/`z`(zoom)/`fliph` 가 없다** | 없음 | §5 — 슬라이더 4개 + bool 1개, condition 포함 | **중** | z(zoom)는 `contentsRect` 축소로, x/y 는 그 원점 이동으로, fliph 는 `CALayer.transform` 의 x 스케일 −1 로 낸다. WE 는 이것을 **소스 정규화 사각형**으로 준다(§4.3) — `contentsRect` 가 정확히 같은 좌표계라 사상이 자연스럽다. 다만 WE 의 열거→사각형 산술을 확정하지 못해(§4.3 `[미해결]`) 무엇을 베낄지가 없다 |
| **G3** | ~~**letterbox 색이 다르다.**~~ **닫혔다 (2026-08-28 확인).** WE 는 **불투명 검정 하드코딩**(`0x1400f34ff` `mov byte [rsp+0x53],0xFF`)이고 Waple 도 이제 같다 | `Sources/WapleRender/VideoRenderer.swift:213` — `layer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)`. 같은 파일 `:205-212` 주석이 이 갭 항목(`§9.2 G3`)을 인용하며 WE 의 MFARGB 구성 3자리를 근거로 싣는다 | §4.3 계약 4 | ~~하~~ | **해소** — 예고했던 "한 줄" 이 실제로 들어갔다. 웹 폴백은 이미 `background:#000` 이라 두 경로의 레터박스가 같다 |
| **G4** | **볼륨 기본값이 반대다.** Waple 기본 **0(음소거)**, WE 기본 **50** | `VideoSettings.volume(id:)`(`d.object(forKey:) == nil ? 0 : …`) | §5 — UI `getSharedDefaultProperties` `{volume:50}` | **하** | 값 하나. 단 Waple 주석(`VideoSettings` 선언부 주석)이 "바탕화면이 예고 없이 소리 내지 않도록 보수적 기본(설계 2026-07-02)"이라고 **의도적 이탈**을 명시했다 — 정합 대상이 아니라 **정책 차이**로 남기는 게 맞다 |
| **G5** | ~~**배속 범위가 다르다.** Waple `0.25–4`(`setRate` 클램프), WE `0.1–2`(슬라이더 10–200)~~ **닫혔다 (2026-08-28 확인).** Waple 도 **`0.1–2.0`** 이다 | `Sources/WapleRender/VideoSettings.swift` — `minRate: Float = 0.1` · `maxRate: Float = 2.0`, `setRate` 가 `max(minRate, min(maxRate, r))` 로 클램프 | §5 표(`0x14010525f` min 0xa · `0x1401052bf` max 0xc8), 씬 경로 min 클램프 0.1(`0x140114d84`) | ~~하~~ | **해소** — 예고했던 "클램프 상수 두 개" 가 실제로 들어갔다. WE 슬라이더 10–200 ÷100 = 0.1–2.0 과 **정확히 일치** |
| **G6** | **`videoaudiooutput` 2단 게이트(전역 ∧ 모니터별)가 없다** | `VideoSettings.volume(id:)` 만 있고 전역 오디오 스위치 없음 | §8.1 (`0x1400ff8fd`–`0x1400ff985`, `0x14010e074`–`0x14010e0ee`) | **하** | 전역 UserDefaults 키 하나 + `isMuted` 에 AND. 멀티모니터 축은 Waple 이 아직 모니터별 설정을 안 가져 지금은 1단으로 충분 |
| **G7** | **`IVideoTexture` 스크립트 표면이 통째로 없다.** `getVideoTexture()` 가 no-op 프록시를 반환한다 | `TextScriptEngine` JS 심 — `__makeLayer`/`__makeRootLayer` 의 `getVideoTexture` (`getVideoTexture: function() { return __noopProxy(); }`) | §6.2 — play/pause/stop/isPlaying/getCurrentTime/setCurrentTime/duration/rate/loop/addEndedCallback | **중** | `SceneVideoLayer` 에 이미 `AVPlayer` 가 있다(`SceneVideoLayer.player`). JSContext 브리지로 10개 멤버를 잇는 일 — 새 IPC 나 디코더는 필요 없다. `addEndedCallback` 은 `AVPlayerItemDidPlayToEndTime` 관찰로(이미 `endObserver` 필드가 있다, `SceneVideoLayer.endObserver`) |
| **G8** | **`ITextureAnimation` 이 스텁이다.** `frameCount:1, fps:0, duration:0` 고정이고 실 시트와 연결되지 않았다. `join()` 이 **없다** | `TextScriptEngine.__makeTextureAnimation` | §6.2 · §7.2 | **중** | `TexImage` 가 이미 프레임 수·프레임타임을 갖고 있다(`docs/re/tex-format.md` §5). 값을 심에 밀어넣는 것은 배선이고, `setFrame` 이 실제로 표시 프레임을 바꾸게 하려면 `SceneRendererFrameEncoder.spriteFrameTexture`가 "절대 씬 시간의 순수 함수"라는 현재 계약을 **레이어별 시계**로 바꿔야 한다 — 그게 비용의 대부분이다. `SceneDocument.spritesheetRefreshSync` 선언부가 이미 같은 지점을 지목했다 |
| **G9** | **심 표면이 WE 와 다르다.** Waple `ITextureAnimation` 심에 `getFrameCount`/`getRate`/`setRate`/`getDuration`/`getProgress`/`setProgress`/`isPaused` 가 있는데 **WE 에는 없다**(WE 는 `frameCount`/`rate`/`duration` **프로퍼티**) | `TextScriptEngine.__makeTextureAnimation` | §6.2 등록부 10개 전수 | **하** | 없는 것을 추가로 주는 것은 무해하지만, 프로퍼티(`anim.rate = 2`)를 쓰는 워크샵 스크립트는 Waple 심에서 **아무 일도 안 일어난다**(getter/setter 만 있고 프로퍼티가 아니다). 프로퍼티 형태를 같이 노출하면 끝 |
| **G10** | **GIF 월페이퍼 경로가 없다.** `.gif` 를 고르면 스테이징도 gifs 씬도 없다 | `ScenePackage.swift`(마운트 결정 주석)(주석: "`.gif` 전용 분기가 없다 … 폴더 마운트로 떨어진다") | §3.2 (`0x140113c80` 전 8단계) | **중** | 템플릿 복사·GIF→시트 디코드·`gifscene.json` 마운트 3단계. macOS 는 `CGImageSourceCreateWithURL` 로 GIF 프레임과 delay 를 바로 준다(ImageIO) — 디코드는 오히려 WE 보다 쉽다. 다만 도달 실측 0건(§1)이라 **우선순위 최하** |
| **G11** | **`keepaspect` 소비처가 없다** | `SceneDocument.materialUserTextureKeepAspect` 선언부("파스·보존 전용") | §2.1 — `videoplayer` 1건 | **중** | **[2026-08-21 정정] UV 스케일이 아니다.** ① 텍스처 로더에 넘기는 목표 종횡비를 0(강제 없음)으로 하고 ② `g_TextureNResolution.zw` 를 레퍼런스 크기가 아니라 **실제 이미지 크기**로 바꾼다(`0x140155d23` / `0x140155daf` → `0x140209433`). 난이도 **하 → 중**: 머티리얼 `usertextures` 배선 자체가 Waple 에 없고, 유일 도달 자산(`scenes/videoplayer`)을 Waple 이 마운트하지 않아 **현재 도달 0**이다. 전문은 `docs/re/material-blend.md` §2.5 |
| **G12** | **`nopadding`/`orthoAuto` 소비처가 없다** | `SceneDocument.noPadding` · `SceneDocument.orthoAuto` 선언부(둘 다 "착지 지점(미배선)") | §2.2 | **하** | `orthoAuto` 는 `SceneRenderer.swift` 의 `projW/projH` 계산 한 자리(드로어블 크기 사용). `nopadding` 은 Metal 이 NPOT 를 기본 허용해 **애초에 할 일이 없다** — WE 의 D3D9 시절 유산 |
| **G19** | **`spritesheetrefreshsync` 소비가 없다.** WE 는 씬을 띄우기 직전 다음 시트 프레임 경계까지 잔다 | `SceneDocument.spritesheetRefreshSync`(선언부 "착지 지점(미배선)") | §7.4 (`0x140113510` → `0x1401135e8` `Sleep`) | **하** | 씬 마운트 직전에 `min(다음프레임까지/배속, 0.25)초` 만큼 시작을 늦추면 끝이다. **레이어별 시계가 필요 없다** — G8 이 지목한 비용은 이 키가 아니라 `setFrame` 때문이라는 것이 2026-08-21 에 갈렸다. 도달은 동봉 1965 json 중 2건(§10.0)이라 우선순위는 낮다 |
| **G13** | **컨테이너 허용목록이 좁다.** WE 7종, Waple 네이티브 3종 + ffmpeg 변환 8종 | `VideoFormats.nativeExtensions`(`WallpaperType.swift`)(`mp4/m4v/mov`) · `VideoRenderer.unsupportedExtensions`(`webm mkv avi wmv flv ogv mpg mpeg`) | `spec/engine/media.json:engine.media.video.containerAllowlist` | **상** | `.wmv`(VC-1/WMV3)는 macOS 에 디코더가 없다. `.mkv`/`.webm`(VP9/AV1)는 VideoToolbox 가 컨테이너를 못 연다. **ffmpeg 외부 변환이 현재 유일한 답**이고 그건 이미 있다(`FFmpegConverter.swift`) — 다만 ffmpeg 부재 시 WKWebView 폴백으로 떨어진다. WE 는 OS 스택(LAV 포함)에 위임해 이 문제가 없다. **구조적 격차이지 버그가 아니다** |
| **G14** | **HDR 비디오 경로가 없다** | `SceneVideoLayer.swift`(클래스 doc `스코프 밖(근거 없어 미구현): … HDR video`) | `spec/engine/media.json:engine.media.color.hdrProbe`(`MF_MT_TRANSFER_FUNCTION` 15/16, `MF_MT_VIDEO_PRIMARIES` 9) + `combine_video_hdr`(`docs/re/tonemapping.md`) | **중** | AVFoundation 은 `AVPlayerLayer` 에 EDR 을 자동 적용하고 `CAMetalLayer.wantsExtendedDynamicRangeContent` 로 씬 합성도 가능하다 — WE 처럼 전달함수를 직접 읽을 필요가 **없다**. 어려움은 톤매핑 합성 슬롯(`combine_video_hdr`)을 Waple 파이프라인에 넣는 쪽 |
| **G15** | **색공간 기본 추정을 명시적으로 맞추지 않았다** | 없음(AVFoundation 기본에 맡김) | `spec/engine/media.json:engine.media.color.corpusImplication` — colr 없는 표본 107/145 | **하** | WE 도 상수를 안 갖고 OS 에 위임한다. **양쪽 다 위임이므로 "같은 상수를 베낀다"가 성립하지 않는다.** 차이가 나면 그건 MF 와 AVFoundation 의 기본 추정 차이이고, 코드로 맞출 게 아니라 실측으로 확인할 문제 |
| **G16** | **`MediaPoller` 는 5초 폴링, WE 는 이벤트 구동** | `MediaPoller.start()`(`Timer(timeInterval: 5,…)`) | §6.1 — SMTC 는 콜백 등록 | **중** | macOS 는 `MediaRemote` 가 비공개 API 라 AppleScript 폴링이 사실상 유일한 합법 경로다. `mediaTimelineChanged` 의 해상도가 5초로 뭉개지는 것이 실질 손실 — WE d.ts 도 이 훅을 "특정 앱만 제공"이라고 적어 두었으니 **허용 가능한 이탈** |
| **G18** | **볼륨 램프가 없다.** WE 는 25ms 타이머로 fade-out 500ms / fade-in 1250ms(볼륨 1.0 기준)를 밟고, **일시정지도 램프가 끝난 뒤에** 건다 | `VideoRenderer.attachPlayer`(`queue.volume = volume`) · 라이브 반영(`player.volume = volume`) — 둘 다 즉시 대입 | §8.5 (`0x140102092`–`0x140102181`, 상수 `0x140492634`/`0x14049262c`/`0x140492620`) | **하** | `AVPlayer.volume` 을 `CADisplayLink`/`Timer` 로 같은 계단(`target*0.03+0.02` 내림 · `target*0.01+0.01` 오름, 25ms)으로 밟으면 끝이다. 새 개념이 없다. 다만 **정지 순서**가 계약이다 — 램프가 끝난 뒤에 `pause()` 를 불러야 WE 와 같은 소리가 난다 |
| **G17** | **`videoplayer` 셸 씬을 쓰지 않는다** | `VideoRenderer` 가 AVPlayerLayer 를 직접 얹는다 | §3.4 — WE 는 `wproperties.videotex.value` 주입 + 씬 마운트 | **하(의도적)** | 셸 씬은 **D3D11 공유 텍스처를 씬에 꽂기 위한 우회**다. macOS 는 `CVMetalTextureCache` 로 제로카피가 되므로 셸이 필요 없다. 다만 **워크샵 씬이 `videotex` 유저텍스처를 쓸 때**는 얘기가 다르다 — 그건 G7 과 같은 배선이고 `SceneVideoLayer` 가 이미 그 모양이다 |

### 9.3 난이도 요약

| 난이도 | 항목 | 공통 사유 |
| --- | --- | --- |
| **해소** (2) | ~~G3~~ ~~G5~~ | **[2026-08-28]** 둘 다 코드에 들어갔다 — `VideoRenderer.swift:213`(레터박스 검정) · `VideoSettings.swift` `minRate 0.1`/`maxRate 2.0`. 아래 남은 집계에서 뺐다 |
| **하** (7) | G4 G6 G9 G12 G15 G18 G19 | 상수·플래그·한 줄 배선. AVFoundation 에 이미 대응물이 있다 (G11 은 2026-08-21 에 **중**으로 올렸다 — 위 표 참조. G18 은 2026-08-21 에 새로 추가했다) |
| **중** (7) | G1 G2 G7 G8 G10 G14 G16 | 새 코드가 필요하지만 **플랫폼이 막지 않는다**. G8 만 렌더러 계약(레이어별 시계) 변경을 동반해 실질 비용이 크다 |
| **상** (1) | G13 | macOS 에 디코더가 **없다**. 외부 변환 외 방법이 없고 그건 이미 구현돼 있다 — "구현"이 아니라 "포기 지점 문서화"가 남은 일 |

> **[2026-08-28 집계 갱신]** 종전 이 표는 **하 9 / 중 7 / 상 1** 이었고 G3·G5 를 열린
> 항목으로 세고 있었다. 둘 다 이미 닫혀 있다(위 §9.2 의 해당 행에 근거를 실었다).
> 열린 갭은 **15개**(하 7 · 중 7 · 상 1)다. `G11` 은 **중** 칸에 세지 않는다 — 도달 0 이라
> 위 표에서 별도 주석으로만 다룬다(종전과 같다).
>
> 대신 §9.1 에서 **새 [미해결] 하나가 열렸다** — 씬 비디오의 seek 수동 루프 이음매 지연.
> 갭 번호를 새로 붙이지 않은 이유는 그것이 "구현 누락" 이 아니라 **플랫폼 제약에서 오는
> 측정되지 않은 편차**이기 때문이다(G13 과 같은 부류다).

**macOS 가 오히려 유리한 자리 3개**를 기록해 둔다 — 이식 계획이 WE 를 그대로 베끼려다
손해 보는 자리다:

1. **공유 텍스처/키드뮤텍스가 필요 없다.** WE 는 미디어 엔진의 D3D11 디바이스와 렌더 디바이스가
   달라서 `IDXGIResource::GetSharedHandle` → `OpenSharedResource` → `IDXGIKeyedMutex` 3단을
   탄다(§4.3). macOS 는 `CVMetalTextureCache` 로 `CVPixelBuffer`(IOSurface)를 바로
   `MTLTexture` 로 본다 — `SceneVideoLayer.frameHold` 링이 그 자리를 이미 지킨다.
2. **스톨 워치독이 필요 없다.** `spec/engine/media.json:engine.media.mfEngine.stallWatchdog` 이
   기록한 지수 백오프 복구(0.1s 클램프 / 0.2s 임계 / `next = 4*cur+10`)와
   `videomfstutterhack`(Media Session 경로)은 **MF 고유의 병리**에 대한 대증요법이다.
   AVFoundation 에 같은 증상이 없으면 이식 대상이 아니다.
3. **NV12→RGB 를 직접 쓸 수 있다.** WE 는 `B8G8R8A8_UNORM` 으로 강제 변환받는다(대역폭 손해).
   Waple 은 `CVMetalTextureCache` 로 Y/CbCr 두 평면을 그대로 받아 셰이더에서 변환할 수 있다 —
   더 싸다. **단 이 경로를 택하면 색행렬을 직접 골라야 하고, 그건 G15 의 "위임" 이점을 버리는
   것**이다. 지금처럼 `kCVPixelFormatType_32BGRA` 로 받는 편이 WE 와 결과가 가깝다.

---

## 10. 확정하지 못한 것

### 10.0 본문 `[미해결]` 전수와 도달 [2026-08-21 신설]

본문에 흩어져 있던 `[미해결]` 표시가 **11건**이었다. 하나씩 세어 도달을 매긴다.
도달은 **실측이고 범위 라벨을 붙인다** — 설치본
(`/home/user/Waple-wallpaper-source/wallpaper_engine`, 파스에 성공한 json 2498건 ·
`project.json` 191건) 과 동봉(`Sources/WapleRender/Resources/WEAssets`, json 1965건)만
셌다. **워크샵 코퍼스는 이 컨테이너에 없어 미측정**이다(0 이 아니다).

| # | 자리 | 무엇이 미해결이었나 | 도달(범위 라벨) | 2026-08-21 결과 |
| ---: | --- | --- | --- | --- |
| 1 | §2.2 | 씬 `spritesheetrefreshsync`(bit6)의 소비 지점 | 저작: 설치본 json 2498 중 **3** · 동봉 1965 중 **2**. 워크샵 미측정 | **[해소 2026-08-21]** §7.4 — 씬 시작 전 `Sleep(다음 프레임까지, 최대 250ms)` |
| 2 | §3.3 | `general.supportsvideo`(bit15)의 소비 지점 | 저작: 설치본 2498 중 **0** · 동봉 1965 중 **0**. 워크샵 미측정 | **좁힘**(아래 10.1) |
| 3 | §3.4 | `materialUserTextureKeepAspect` 가 남긴 인용 | `usertextures` 저작: 설치본 **1** · 동봉 **1** | 이 문서가 이미 이유를 교체했다(결론 유지) |
| 4 | §4.2 | 프레임워크 레지스트리 플래그 워드의 소비 지점 | 엔진 내부 표 5건 — 저작 자산이 아니라 도달 개념이 없다 | **[해소 2026-08-21]** §4.5 |
| 5 | §4.3 | `alignment` 열거 → 소스 정규화 사각형 산술 | `type:"video"` 프로젝트: 설치본 `project.json` 191 중 **0**(`scene` 150 · `web` 2 · type 키 없음 39). 워크샵 미측정 | 미해소 |
| 6 | §7.2 | `docs/re/tex-format.md` §5 의 미해결(누적 duration 의 소비처) | `spritesheetsequences`: 설치본 **58** · 동봉 **52** | 이 문서가 부분 좁힘(소비 표면 확정) — 유지 |
| 7 | §7.2 | 시퀀스 구조체 `+0x38`/`+0x40`/`+0x48` 를 TEXS 값으로 채우는 초기화 | 위와 같음 | 미해소 |
| 8 | §7.2 | 시퀀스 `name` 의 출처 | `.tex-json` **58/58 전건 `name` 미저작** → 표본 0. 워크샵 미측정 | 미해소(코퍼스가 없어 이 컨테이너에서 닫을 수 없다) |
| 9 | §8.2 | `[owner+0x118]` bit17 의 출처 | 런타임 상태 — 도달 개념이 없다 | **좁힘**(아래 10.2) |
| 10 | §8.3 | 비디오 오디오가 실제로 스펙트럼에 섞이는지 | 실행 관측 필요. Windows 실행 환경 없음 | 미해소(구조적 추론 유지) |
| 11 | §9.2 G2 | `alignment*` 갭 — 5번을 그대로 참조한다 | 5번과 같음 | 5번에 종속 |

**이번에 하나가 늘었다.** §8.5 가 `setPaused`/`setMuted` 를 **부르는 쪽**을 특정하지 못했다
(가상 디스패치라 직접 `call` 이 이미지에 0곳). 곧 본문 표시는 이제 12건이다 — 4번이 닫혔고
새로 1건이 생겼다.

### 10.1 2번(`supportsvideo` bit15)이 어디까지 좁혀졌나

> **이 절의 VA 는 전부 `wallpaper64.exe`(imagebase `0x140000000`)다.**

bit15 는 **개별적으로 검사되지 않는다.** `[wallpaper+0x248]` 워드가 통째로 접혀 들어간다:

```
0x140110a19  mov ebx, 0x100d
0x140110a7b  mov eax, 0x100f
0x140110a8c  cmovne ebx, eax                 ; [rbp+0x368] != 0 이면 0x100f
0x140110a9d  or  ebx, dword [r15 + 0x248]    ; 월페이퍼 플래그 워드를 통째로 얹는다
0x140110ad2  mov dword [rbp - 0x60], ebx     ; 생성 디스크립터 +0x20
0x140110ae8  call 0x14017c6d0                ; 씬 객체 생성자
```

생성자가 그 필드를 그대로 옮긴다:

```
0x14017c7d5  mov eax, dword [rdx + 0x20]     ; 디스크립터 +0x20
0x14017c7d8  mov dword [rcx + 0x118], eax    ; this + 0x118
```

곧 **씬 객체의 `+0x118` 은 `[wallpaper+0x248] | 0x100d`(또는 `| 0x100f`)의 사본**이다.
남은 일은 그 워드에서 bit15 를 읽는 자리를 찾는 것인데, `[reg+0x118]` 425자리를 전수로 보면
비트 검사는 `0x400`·`0x800`·`0x2000`·`0x10000`·`0x200000`·`0x1800000`·`0x8000000`·`0xc000000`
뿐이고 `0x8000` 은 없다. 그래서 **이 객체 경로에서는 소비되지 않는다** 까지가 확정이고,
또 다른 사본이 있는지는 못 봤다.

### 10.2 9번(`[owner+0x118]` bit17)이 어디까지 좁혀졌나

종전 기록은 "`or dword [reg+0x118], imm & 0x20000` 패턴 **0건**" 이었다. 이번에 **왜 0건인지**를
찾았다 — 위 10.1 이 그 답이다. `+0x118` 은 세워지는 워드가 아니라 **`+0x248` 에서 복사되는
워드**다. 그래서 `+0x118` 을 아무리 뒤져도 안 나온다.

그런데 `+0x248` 쪽에도 `0x20000` 즉치가 없다. 전수로 다시 확인했다:

* `[reg+0x248]` 을 건드리는 명령 **194개** 중 즉치 비트연산은 `0x2000`(`0x14010e6ba`) ·
  `0x6000`(`0x14010e6da`) · `0x8000`(`0x14010eaf4`) · `0x40` set/clear(`0x14010edc1`·`0x14010edcb`·
  `0x14010f1a1`·`0x14010f1aa`) 뿐이다.
* 이미지 전체에서 즉치 `0x20000` 을 쓰는 명령은 **28개**이고, 그중 `edx`/`r8d` 같은 인자
  레지스터에 싣고 곧바로 호출로 가는 자리는 **0곳**이다.
* 일반 set/clear API `0x140115a90`–`0x140115b86`(`flags = (flags | setMask) & ~clearMask`,
  `[wallpaper+0x248]` 과 `[[wallpaper+0x180]+0x128]` 을 함께 갱신)는 마스크를 **런타임 인자**로
  받는다.

곧 bit17 은 **즉치가 아니라 계산된 마스크**(`1 << n` 꼴)로 들어온다는 것이 남은 가설이고,
그 자리는 못 찾았다. 다음 사람이 이 항목을 다시 팔 때 `or …, 0x20000` 스캔은 **다시 0건이
나올 것**이므로 그쪽에 시간을 쓰지 마라 — 이 문단이 그 말을 하려고 있다.

---

### 10.3 종전 표

| # | 항목 | 어디까지 했나 |
| --- | --- | --- |
| 1 | `alignment` 열거값 → 소스 정규화 사각형 산술 | 세터 `0x1400f2e90`–`0x1400f2f4e` 와 필드(`+0xb8..0xc4`) 확정. 호출부를 `VideoWallpaper`(`0x140100720`·`0x140101c50`)로 좁혔으나 부동소수 경로를 끝까지 못 이었다 |
| 2 | `[owner+0x118]` bit17(= 오디오 출력 활성)의 출처 | `.text` 전수에서 `or dword [reg+0x118], imm & 0x20000` 패턴 **0건**. 다른 워드에서 접혀 오는 것으로 보이나 미특정 — **[좁힘 2026-08-21]** 접혀 오는 워드를 특정했다(`[wallpaper+0x248]` → 씬 객체 `+0x118`, §10.2). 그 워드에도 `0x20000` 즉치가 없다는 것까지 전수로 확인했다 |
| 3 | 프레임워크 레지스트리 플래그 워드(`0x0101`/`0x0001`/`0x0000`) 의미 | 값은 확정(§4.2 표). 소비 지점 미특정 — **[해소 2026-08-21]** 하위 바이트 = MF 요구, 상위 바이트 = 창 확장스타일 비트21 요구. §4.5 |
| 4 | `general.supportsvideo`(bit15 @`0x14010eaf4`) 소비 지점 | 파서 확정. 소비처 미특정. 동봉 도달 0건이라 코퍼스로도 확인 불가 — **[좁힘 2026-08-21]** 워드가 씬 객체 `+0x118` 로 복사되는 것까지 확정. 그 객체에서 `0x8000` 을 검사하는 자리는 없다(§10.1) |
| 5 | `spritesheetrefreshsync`(씬 bit6) 소비 지점 | `SceneDocument.spritesheetRefreshSync` 선언부의 기록이 유효 — `[reg+0xE0]` 접근 928곳 중 마스크 `0x40` 근처는 프로젝트 플래그 집계 두 벌뿐 — **[해소 2026-08-21]** 마스크가 아니라 `shr eax, 6` 로 꺼낸다(`0x140114d0a`). 전문 §7.4 |
| 6 | 시퀀스 구조체(`+0x38`/`+0x40`/`+0x48`)를 TEXS 값으로 채우는 초기화 | 구조체 배치는 게터로 전부 확정(§7.2). 초기화 코드 미특정. TEXS 리더 `0x14015e1d0`–`0x14015e57c` 의 구조체와는 다른 구조체임을 확인 — **[2026-08-21 음성 결과]** `name`(`+0x68`)의 SSO 초기화 `mov qword [reg+0x80], 0xf` 를 이미지 전수로 찾으면 **7곳**인데, 그중 같은 함수 안에서 `movss [reg+0x38]` 과 `[reg+0x48]` 을 함께 건드리는 곳은 **0곳**이다. 곧 이 구조체는 "한 함수가 베이스 하나로 필드를 죽 채우는" 모양이 아니다 — 다음 사람은 그 가정을 버리고 시작해라 |
| 7 | 시퀀스 `name` 의 출처 | `.tex-json` 58건 전부 `name` 미저작. 다중 시퀀스 자산이 코퍼스에 없어 표본 0 |
| 8 | 비디오 오디오가 실제로 스펙트럼에 섞이는지 | "섞이지 않게 하는 코드가 없다"까지가 확정(§8.3). 실행 관측은 안 했다 |
| 9 | `videoloopmode` 의 `syncclock`/`synctopo` 동작 | 열거값·저장 슬롯(`[player+0x198]`) 확정. 코드 경로 미추적 (`spec/engine/media.json:engine.media.unknowns` 와 같은 상태) |
| 10 | `videoreadmode: frommemory` 가 Media Engine 소스 로딩까지 바꾸는지 | `[player+0x19c]` 저장 확정. `spec/engine/media.json` 의 같은 항목을 넘지 못했다 |

## 배제한 가설

| 가설 | 왜 틀렸나 |
| --- | --- |
| "WE 는 ffmpeg 을 번들해 재생에 쓴다" | `wallpaper64.exe` 에 `ffmpeg`/`avcodec`/`avformat`/`swscale`/`libvpx` 토큰이 **ASCII·UTF-16 양쪽 모두 0건**. `ffmpeg.exe` 는 `wallpaperui.exe`(내보내기 프리셋 `ffmpeg_mp4_h264` 등)와 `resourcecompiler64.exe` 에만 있다 |
| "`bin/mediaextensions64.dll` 이 비디오 디코더다" | export 177 중 175 가 OpenAL Soft. 임포트에 MF/DShow/D3D 가 하나도 없다(§4.4) |
| "프레임은 NV12 로 올라가 셰이더에서 YUV→RGB 를 한다" | `MF_MEDIA_ENGINE_VIDEO_OUTPUT_FORMAT = 87`(`B8G8R8A8_UNORM`, `0x1400f239d`). `MFVideoFormat_NV12`/`MF_MT_YUV_MATRIX` GUID **부재**. `genericimage.frag` 에 변환 코드 없음 |
| "`MediaPlaybackEvent` 로 월페이퍼 비디오를 제어한다" | 필드 1개(`state`) + 상수 3개, **메서드 0개**. 원천은 다른 프로세스(`winrtutil64.exe`)의 SMTC 다(§6.1). 제어 표면은 `IVideoTexture`(§6.2) |
| "GIF 는 비디오 파이프라인으로 재생된다" | `.gif` 는 `assets/scenes/gifs` 템플릿을 `projects/temp/gifs/<stem>` 로 복사하는 **씬 스테이징**이다(§3.2). 미디어 스택 미관여 |
| "`videomfstutterhack` 은 `videoframework=='mf'` 일 때만 유효하다" | 엔진 게이트는 `mf` **와** `mfEngine` 둘 다 통과시킨다(`0x1400ffb37`·`0x1400ffb61`). UI 조건이 엔진보다 좁다 |
| "`videoplayer` 씬의 `spritesheetrefreshsync` 는 비디오 프레임 동기화용이다" | 비디오 셸에는 스프라이트시트가 없다. `gifs/gifscene.json` 과 `objects[0]` 자구까지 동일한 **사본 흔적**으로 보는 편이 단순하다(§2.2) |
| "`orthogonalprojection.auto` 는 GIF/비디오 씬의 표식이다" | 저작 템플릿 `projects/templates/gif/gifscene.json` 은 **실값 1920×1080** 이다. `auto` 는 "저작 단계를 건너뛴 런타임 셸" 표식이다(§2.2) |

---

## 부록 A. 재현 절차

모든 명령은 `…` 로 시작한다. RE 도구는 스크래치패드
(`wpe.py` = PE 파서, `vdis2.py` = `dis(start,end)`, `xr.py` = rip-상대 xref, `cx.py` = call xref,
`iat.py` = IAT 이름, `pex.py` = export/import)에 있다.

**디스어셈 규율과 그 예외.** 원칙은 `primary()` 로 잡은 함수 시작에서만 `dis()` 를 부르는 것이다
(`.pdata` 조각 ≠ 함수). 이 문서가 인용한 함수 중 **`.pdata` 항목이 아예 없는 것 12개**가 있다 —
`0x140084ef0`(`Json::Value(Int)`) · `0x140141880`(playbackaudio 매퍼) ·
`0x140170770`·`0x140170790`·`0x1401707a0`·`0x1401707b0`·`0x1401707f0`·`0x140170820`·
`0x140170830`·`0x140170860`·`0x140170880`·`0x1401708a0`(시퀀스 게터/메서드) ·
`0x1401a49f0`·`0x1401a4a10`. 전부 **예외를 던지지 않는 리프**라 언와인드 정보가 없는 경우다.
근거로 각 진입 직전 바이트가 `c3 cc cc …`(`ret` + `int3` 패딩)임을 확인했다:

```python
from wpe import pe
for va in (0x140141880, 0x140170770, 0x1401708a0):
    print(hex(va), pe.read(va-8,8).hex())
# -> c3cccccccccccccc / 205bc3cccccccccc / c3cccccccccccccc
```

곧 함수 **시작**임이 확정된 주소이므로 `dis()` 를 그 자리에서 부른 것이 안전하다.
IAT/`.data` 주소(`0x1404e53d4` `0x1404e8140` `0x1404e9240`)는 raw 가 없는 섹션이라
`pe.read` 가 빈 바이트를 준다 — 값이 아니라 **주소**로만 인용했다.

### A.1 동봉 == 설치본 확인 (§1.1)

```bash
diff -rq /home/user/Waple-wallpaper-source/wallpaper_engine/assets/scenes \
         /home/user/Waple/Sources/WapleRender/Resources/WEAssets/scenes
# -> 출력 없음(완전 동일)
find /home/user/Waple/Sources/WapleRender/Resources/WEAssets \
     \( -name scene.json -o -name gifscene.json \) | wc -l      # -> 172
```

### A.2 키 도수 (§1.2)

```bash
python3 - <<'EOF'
import json,os,collections
ROOTS={'WEAssets':'Sources/WapleRender/Resources/WEAssets',
       'projects':'/home/user/Waple-wallpaper-source/wallpaper_engine/projects'}
cnt=collections.Counter()
def prev(p):
    lp=p.lower(); return 'preview' in lp or 'particleelementpreviews' in lp
for tag,root in ROOTS.items():
    for dp,dn,fn in os.walk(root):
        for f in fn:
            if not f.endswith('.json'): continue
            p=os.path.join(dp,f)
            try: d=json.load(open(p,encoding='utf-8-sig'))
            except Exception: continue
            if not isinstance(d,dict): continue
            k=tag+('/prev' if prev(p) else '/main')
            for ps in (d.get('passes') or []):
                if isinstance(ps,dict):
                    if 'spritesheet' in (ps.get('combos') or {}): cnt[k+' combos.spritesheet']+=1
                    if ps.get('usertextures'): cnt[k+' usertextures']+=1
            if 'nopadding' in d: cnt[k+' model.nopadding']+=1
            g=d.get('general')
            if isinstance(g,dict):
                if 'spritesheetrefreshsync' in g: cnt[k+' gen.ssrefresh']+=1
                op=g.get('orthogonalprojection')
                if isinstance(op,dict) and 'auto' in op: cnt[k+' ortho.auto']+=1
                if 'supportsvideo' in g: cnt[k+' gen.supportsvideo']+=1
for k,v in sorted(cnt.items()): print(v,k)
EOF
# -> WEAssets/main {combos.spritesheet 1, gen.ssrefresh 2, model.nopadding 2,
#                   ortho.auto 2, usertextures 1}
#    projects/main {combos.spritesheet 10, gen.ssrefresh 1, model.nopadding 2}
#    gen.supportsvideo 는 어느 쪽에도 없다
```

### A.3 `.tex-json` 키 히스토그램 (§7.1)

```bash
cd /home/user/Waple-wallpaper-source/wallpaper_engine && python3 - <<'EOF'
import json,os,collections
keys=collections.Counter(); seq=collections.Counter(); n=0
for r in ('assets','projects','ui'):
    for dp,dn,fn in os.walk(r):
        for f in fn:
            if f.endswith('.tex-json') or f.endswith('.tex.json'):
                n+=1; d=json.load(open(os.path.join(dp,f),encoding='utf-8-sig'))
                for k in d: keys[k]+=1
                for s in d.get('spritesheetsequences',[]) or []:
                    for k in s: seq[k]+=1
print(n, dict(keys)); print(dict(seq))
EOF
# -> 388 · spritesheetsequences 58 · spritesheet 6 · imagesequence 3 · frameduration 3 · srgb 10
#    seq keys = {duration:58, frames:58, height:58, width:58}   ← name 없음
```

### A.4 문자열/GUID 부재 확인 (§4.1 · §8.2)

```bash
cd /home/user/Waple-wallpaper-source/wallpaper_engine
for enc in s l; do strings -a -e$enc wallpaper64.exe \
  | grep -icE 'ffmpeg|avcodec|avformat|swscale|libvpx|nv12|dxva'; done   # -> 0, 0
strings -a wallpaper64.exe | grep -c '\.?AVcodecvt_base'                  # -> 1 (오탐 원인)
strings -a bin/wallpaperui.exe | grep -oE 'ffmpeg[a-z0-9_.]*' | sort -u   # -> ffmpeg_mp4_h264 등
```

```python
# GUID 부재 — bytes_le 로 .rdata 를 직접 훑는다
import sys, uuid; sys.path.insert(0,'<scratchpad>')
from wpe import pe, DATA
for name, g in {
  'MFVideoFormat_NV12':'3231564E-0000-0010-8000-00AA00389B71',
  'MF_MT_YUV_MATRIX':'3E23D450-2C75-4D25-A00E-B91670D12327',
  'MF_MEDIA_ENGINE_AUDIO_CATEGORY':'C8D4C51D-350E-41F2-BA46-FAEBBB0857F6',
  'MF_MEDIA_ENGINE_AUDIO_ENDPOINT_ROLE':'D2CB93D1-116A-44F2-9385-F7D0FDA2FB46',
}.items():
    print(name, DATA.find(uuid.UUID(g).bytes_le))   # -> 전부 -1
```

### A.5 프레임워크 폴백 사슬 (§4.2)

```python
import sys; sys.path.insert(0,'<scratchpad>')
from vdis2 import dis
dis(0x1400ff750, 0x1400ffcaf)      # primary() 로 잡은 함수 시작 — 중간 주소로 부르지 말 것
# 0x1400ff7f9 stricmp "dshow.lav.vmr9" / 0x1400ff855 stricmp "mf"
# 0x1401031f0 = emplace_back(const char*) · 0x140103450 = emplace_back("mf")
```

팩토리 blob → 생성자(§4.2 마지막 두 열):

```python
import sys, struct; sys.path.insert(0,'<scratchpad>')
from wpe import pe
for va in (0x140488940, 0x1404888b0, 0x140488880, 0x140488910, 0x1404888e0):
    print(hex(va), [hex(q) for q in struct.unpack('<6Q', pe.read(va, 0x30))])
# 0x140488940 → +0x10 = 0x140104240   (mfEngine)
# 0x1404888b0 → +0x10 = 0x1401041d0   (mfEngine.muted)
# 0x140488880 → +0x10 = 0x140103fa0   (mf)
# 0x140488910 → +0x10 = 0x140103d70   (mf.muted)
# 0x1404888e0 → +0x10 = 0x140103c50   (dshow.lav.vmr9)
```

`0x14011eea0` 의 호출자 전수(= 위 다섯 중 앞의 둘뿐):

```python
from cx import callers
print([hex(c) for c in callers(0x14011eea0)])   # -> ['0x140104201', '0x14010426e']
```

### A.6 GIF 스테이징 (§3.2)

```python
import sys; sys.path.insert(0,'<scratchpad>')
from wpe import function_frags
from vdis2 import dis
p, fr = function_frags(0x1401142a4)     # -> primary 0x140113c80, 조각 5개
dis(fr[0][0], fr[-1][1])
# 0x1401142a4 ".gif" / 0x140114304 "assets/scenes/gifs" / 0x140114334 "projects/temp/gifs"
# 0x140114459 "materials/background.gif" / 0x140114551 "gifscene.json"
```

### A.7 시퀀스 객체 필드 (§7.2)

```python
import sys; sys.path.insert(0,'<scratchpad>')
from vdis2 import dis
dis(0x140177f70, 0x1401786f1)           # 등록부 — 이름 11개
for a,b in [(0x140170770,0x140170790),(0x140170790,0x1401707a0),
            (0x1401707a0,0x1401707b0),(0x1401707b0,0x1401707f0),
            (0x1401707f0,0x140170830),(0x140170830,0x140170880),
            (0x140170880,0x1401708c0)]:
    dis(a,b)                            # 게터/메서드 — [rcx+0xC8] 가 시퀀스 구조체
```

### A.8 `alignment` 열거값 (§5)

```python
import sys, re; sys.path.insert(0,'<scratchpad>')
from vdis2 import dis
dis(0x140104b60, 0x140108c17)           # wproperties 합성기 전문
# cover  : 0x140105a4f  mov qword [rbp+0x4d0], rbx(=0)
# fill   : 0x140105b1c  mov qword [rbp+0x4f8], 1
# stretch: 0x140105c93  mov qword [rbp+0x520], 2
# center : 0x140105bd5  mov edx, 3  → call 0x140084ef0 (Json int)
# free   : 0x140105d4c  mov edx, 4  → call 0x140084ef0
# 조건식 문자열: 0x140488c78 "alignment.value<2&&checkPositionVisibility()"
#               0x140488d70 "alignment.value==3||alignment.value==4"
#               0x140488e00 "alignment.value==4"
```

### A.9 스크립트 등록부 3종 이름 전수 (§6.2 · §7.2)

```bash
python3 - <<'PY'
import sys; sys.path.insert(0,'<scratchpad>')
from vdis2 import dis
import io, contextlib, re
for name,(a,b) in {'IVideoTexture':(0x140214050,0x140214799),
                   'ITextureAnimation':(0x1402131a0,0x14021387a),
                   'sequence':(0x140177f70,0x1401786f1)}.items():
    buf=io.StringIO()
    with contextlib.redirect_stdout(buf): dis(a,b)
    print(name, sorted(set(re.findall(r'"(\w+)"', buf.getvalue()))))
PY
# IVideoTexture     : addEndedCallback duration getCurrentTime isPlaying loop pause play rate setCurrentTime stop
# ITextureAnimation : duration frameCount getFrame isPlaying join pause play rate setFrame stop
# sequence          : duration fps frameCount getFrame isPlaying name pause play rate setFrame stop
```

### A.10 `playbackaudio` 열거 (§8.4)

```python
import sys; sys.path.insert(0,'<scratchpad>')
from vdis2 import dis
dis(0x140141880, 0x14014191a)
# "stop"(0x706f7473)→4 · "pauseall"→3 · "pause"→2 · "mute"(0x6574756d)→1 · 그 외→0
```

### A.12 `mediaextensions64.dll` export 2개 (§4.4) [2026-08-21 신설]

`wpe.py` 는 `wallpaper64.exe` 에 고정돼 있어 DLL 을 못 읽는다. 임의 PE 를 받는 파서를 따로 썼다
(스크래치패드 `BM_pe.py`). 요지는 셋이다.

```python
# 1) export 표 — ordinal / 이름 / VA
p = PE("bin/mediaextensions64.dll")          # imagebase 0x180000000
[(o, n, hex(a)) for o, n, a in p.exports() if not n.startswith(("al", "AL"))]
# -> [(1, 'CreateMediaExtensions', '0x180002808'), (2, 'WallpaperEngineMedaExtensionVersion', '0x1803119e0')]

# 2) ordinal 2 가 데이터인지 — 섹션 범위와 .reloc 을 본다
#    .text  va 0x1000  vsize 0x2064d3   → 0x180001000..0x1802074d3   (0x1803119e0 은 그 밖)
#    .data  va 0x310000                 → 0x1803119e0 은 여기
#    .reloc 에 rva 0x3119e0 의 type 10(DIR64) 항목이 있다 = 재배치되는 포인터
p.read(0x1803119e0, 8)                       # -> d0 cb 2d 80 01 00 00 00  = 0x1802dcbd0
p.cstr(0x1802dcbd0)                          # -> b'WallpaperEngineMediaExtensions0002'

# 3) 소비자 전수 — 설치본 6138파일을 ASCII·UTF-16LE 양쪽으로 훑는다(함정 8)
#    CreateMediaExtensions              : wallpaper32/64.exe · bin/wallpaperui.exe · 두 DLL 자신
#    WallpaperEngineMedaExtensionVersion: 두 DLL 자신뿐 — 소비자 0
```

### A.13 볼륨 램프 (§8.5) [2026-08-21 신설]

**전부 `wallpaper64.exe`(imagebase `0x140000000`) 다.**
`.pdata` 함수 시작에서 **선형으로** 내려와야 한다(함정 15).

```python
from wpe import pe, primary
from vdis2 import dis

# ① 변경 마스크 → 백엔드 슬롯 (§4.5.4). 함수 시작에서 뜬다.
primary(0x1401007e3)          # -> (0x140100720, 0x1401008da, …)
dis(0x140100720, 0x1401008da) # 0x14010073a `mov edi, edx` 가 마스크를 잡는 자리다

# ② 볼륨 램프 (WM_TIMER 팔). 창 프로시저는 **점프테이블**이라 함수 시작에서 선형으로
#    내려오면 표를 지나며 경계가 어긋난다. 팔의 실제 시작은 0x14010206b 이고, 그 앞
#    0x14010205b(`movss xmm1, [rax+0x178]`)이 직전 팔의 꼬리라 거기서 시작하면 경계가 맞는다.
primary(0x1401020a4)          # -> (0x140101c50, 0x140102248, …)  창 프로시저 전체
dis(0x14010205b, 0x1401021a0)
# 0.03f @0x140492634 · 0.02f @0x14049262c · 0.01f @0x140492620

# ③ 들어오는 문 두 개
dis(0x1400fe970, 0x1400fe9a8) # setPaused  ([this+8], 마스크 0x80)
dis(0x1400fe9b0, 0x1400fe9e8) # setMuted   ([this+9], 마스크 0x40)
```

> **`scripts/re/va_citations.py` 로 이 문서를 검사할 때** — 이 문서는 바이너리 7종을 언급하므로
> 그 도구가 머리에 "오탐 가능" 을 찍는다. `wallpaper64.exe` 가 아닌 VA(§4.4 의
> `0x180…` = `mediaextensions64.dll`)는 그 도구로 판정할 수 없다. 아래 §부록 A.12 의
> `BM_pe.py` 로 따로 떠야 한다.

### A.14 도달 실측 (§10.0) [2026-08-21 신설]

```python
# 설치본과 동봉을 각각 훑어 json 을 파스하고 키를 센다. preview 경로는 따로 센다.
# 실측: 설치본 파스 성공 2498건 · 동봉 1965건
#   general.supportsvideo          0 / 0
#   general.spritesheetrefreshsync 3 / 2
#   model.nopadding                4 / 2
#   usertextures · keepaspect      1 / 1
#   spritesheetsequences          58 / 52
#   tex.spritesheet                6 / 0        imagesequence 3 / 0
# project.json 191건 type 분포: scene 150 · web 2 · type 키 없음 39 · video 0
# 비디오 컨테이너 파일: 설치본 .webm 165건이 전부 ui/ 아래(카탈로그 프리뷰), 동봉 0건
# config.json 실측: videoframework=mfEngine · videoaudiooutput=true ·
#                   videohardwareacceleration=true · playbackaudio=run · mediaintegration=true ·
#                   browsetransition={"transition":"none","transitiontime":1500} ·
#                   wallpaperconfigrecent[0..4] 전건 playlist=false(재생목록 사용 0/5) ·
#                   playlists 키 부재
```

**워크샵 코퍼스는 이 컨테이너에 없다 — 위 수치는 전부 "설치본+동봉" 범위이고 워크샵은 미측정이다.**

### A.15 `spritesheetrefreshsync` 소비 지점 (§7.4) [2026-08-21 신설]

**전부 `wallpaper64.exe`.** 종전 스캔이 `[reg+0xE0]` 에 걸린 **마스크 `0x40`** 만 찾아 0건이었다.
비트를 `shr` 로 꺼내는 형태를 같이 봐야 한다 — 인덱스를 뜬 뒤 두 줄이면 된다.

```python
# .pdata 함수마다 capstone 으로 뜬 명령 인덱스에서(스크래치패드 BM_scan.py)
d = [r for r in recs if 0xe0 in r.disps]                 # 928건
[r for r in d if 0x40 in r.imms and r.mn in ('test','and','or','cmp')]
# -> 0x140187674  or dword [r14+0xe0], 0x40              (파스 — 세우는 쪽뿐)

# 워드째 싣고 shr 하는 형태를 따로 본다 — 이게 놓친 형태다
[(r, nxt) for r, nxt in pairs(d) if r.mn == 'mov' and nxt.mn == 'shr' and ', 6' in nxt.ops]
# -> 0x140114d0a  mov eax, [rax+0xe0]  →  0x140114d10  shr eax, 6
```

그다음은 옮겨 실린 비트를 따라간다.

```python
[r for r in recs if 0x1b8 in r.disps and r.mn in ('test','or','and')]
# -> 0x1401148c4  and dword [rsi+0x1b8], 0xfffffffb   (초기화)
#    0x140114d17  or  dword [rsi+0x1b8], 4            (설정)
#    0x140113510  test byte [r15+0x1b8], 4            ← 소비
from vdis2 import dis
dis(0x140113503, 0x1401135f6)      # Sleep 까지
```

### A.11 게이트

```bash
python3 scripts/spec/check_address_ranges.py   # selftest: OK · 위반 0건
cd /home/user/Waple && python3 scripts/spec/validate.py               # 오류 0건
cd /home/user/Waple && python3 scripts/spec/check_canon_generator_keys.py    # 불일치 0건
cd /home/user/Waple && python3 scripts/spec/check_canon_generator_values.py  # 불일치 0건
```
