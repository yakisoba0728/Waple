# `.rdata` JSON 키 중 Waple 미구현 목록

`wallpaper64.exe` 의 `.rdata` 에서 JSON 키로 보이는 문자열을 전부 뽑아, **동봉 자산에 실제로
키로 등장하는 것만** 남긴 뒤 Waple 소스와 대조한 결과다.

선행 스윕의 "147개" 는 재현되지 않는다. 이 문서는 그 목록을 폐기하고 처음부터 다시 만든 것이다.
결론부터: **동봉 코퍼스 도달이 있는 미구현 키는 22개**다. 147 과 자릿수가 다른 이유는 §4 에 적었다.

- 바이너리: `440072bd-wallpaper64.exe` md5 `438cb215f20a8f6c38f57fbc3d9da588`
  (= `wallpaper_engine/wallpaper64.exe`), imagebase `0x140000000`
- `.rdata` : VA `0x140426000`–`0x1404DB1AC` (파일 오프셋 `0x424E00`, 크기 `0xB5200`)
- 소스 스냅샷: 2026-08-21 00:53 UTC, `Sources/**/*.swift`(WEAssets 제외) 집합 md5
  `26f47974bc7672ac048b2c4bf7d61a3d`
  - 측정 중에도 트리가 바뀌었다. 첫 측정(00:35경)에서 미구현이던 `functions` · `action` ·
    `compose` 가 00:53 재측정에서 구현으로 바뀌었다(`WapleCore/EffectManifest.swift`).
    아래 §5 표는 **00:53 스냅샷 기준**이다.

---

## 0. 재측정 — 2026-08-21 09:36 UTC (§5 표 22개 중 **20개가 구현됐다**)

> **§5 의 22개 표는 00:53 스냅샷이다. 그 뒤 여러 커밋이 들어갔다.** 아래가 현재 트리 기준
> 재판정이다. 판정 방법은 §3(b) 그대로 — `"키"` 형태 따옴표 리터럴이 **주석이 아닌 코드 줄**에
> 있는지, 대상은 `Sources/**` 의 `.swift`/`.js`/`.h`/`.m`, `Sources/WapleRender/Resources/WEAssets/`
> 제외. 재현 스크립트는 §부록 B.
>
> - 측정 시각 **2026-08-21 09:36 UTC**
> - `Sources/**/*.swift`(WEAssets 제외) **158개**, 집합 md5 **`0e2c05a3b0487257f52e6d99d6cd206c`**
>   (재현: `find Sources -name '*.swift' -not -path '*/Resources/WEAssets/*' | sort | xargs md5sum | md5sum`)
> - 대상 파일(`.swift`/`.js`/`.h`/`.m`) 159개
>
> **측정 중에도 트리가 바뀐다 — 실측으로 확인했다.** 이 라운드에는 파티클 키 9개 ·
> `keepaspect` · `lightconfig` 등을 **다른 작업자가 동시에 구현하고 있었다.**
> 위 md5 를 09:36 에 뜬 뒤 **16분 안에 두 번 더 바뀌었다** — 09:46
> `ffcc5716c730ee80dc3349c3e8785452`, 09:52 `8287287fbbf1e67d5f12f649719ca36e`.
> (세 시점 모두 판정 결과는 위 4개로 같았다.) 그러니 이 절은 "현재 상태" 가 아니라
> **09:36 md5 시점의 스냅샷**이다. md5 가 다르면 다시 재라 — 판정기는 §부록 B 에 그대로 있고
> 1초 안에 끝난다.
>
> | 구분 | 개수 | 키 |
> | --- | ---: | --- |
> | 리터럴 판정 = 구현됨 | **18** | `schemecolor` `duration` `controlpointstartindex` `arcamount` `wraploop` `delay` `inputrangemax` `nopadding` `transparentsorting` `auto` `spritesheetrefreshsync` `cone` `lightconfig` `collisionbehavior` `keepaspect` `inputrangemin` `bouncefactor` `pointshadow` |
> | 리터럴은 없지만 **동적 구성**(§3(c) 부류) | **2** | `controlpointangle1` `controlpointangle2` — `SceneDocument.swift:2964` 의 `io["controlpointangle\(i)"]`, `i in 0..<8`. `controlpoint1`/`controlpoint2` 와 **같은 오탐군**이다 |
> | **여전히 미구현** | **2** | `version` · `description` |
>
> **남은 2개는 "고쳐야 할 갭" 이 아니다.** §5.2 가 이미 확정해 둔 대로 둘 다 엔진 쪽
> **리더가 0**이다 — `version` 은 패키지/모듈 매니페스트 기록 경로에만 나오고
> (`0x140056566`·`0x140040DA0`·`0x14011BB5D`), `description` 은 직렬화 좌변 1곳(`0x140056524`)뿐이다.
> 즉 **엔진이 안 읽는 키를 Waple 도 안 읽는 것**이라 일치다.
> `version` 이 `SceneDocument.swift:2798` 에 나오지만 그 줄은 주석이라 판정에 들지 않는다.
>
> **결론: 이 문서가 처음 세운 22개 목록은 사실상 소진됐다.** 남은 실질 갭은 **0개**다.
> 다만 §4 가 밝힌 대로 "동봉 도달 0 이면서 미구현" 인 키는 이 문서의 사정권 밖이고,
> 그쪽은 형제 문서 [`bundled-key-coverage.md`](bundled-key-coverage.md) 가 총계로 다룬다.

---

## 1. 후보 추출 기준

`.rdata` 원시 바이트를 정규식으로 훑는다. 디스어셈블을 거치지 않으므로 동기 어긋남이 없다.

**ASCII**

- 인쇄 가능 바이트 `[\x20-\x7e]` 가 3–32개 이어지고 `\x00` 으로 끝난다.
- 시작 위치 바로 앞 바이트가 `\x00` 이어야 한다(= 앞 문자열의 종단 또는 정렬 패딩).
  이 조건이 접미사 오탐(`...blendmode` 안의 `mode` 등)을 막는다.
- 최종 판정 정규식: `^[a-z][a-z0-9_]{2,31}$`
  - 소문자 시작 — WE 의 JSON 스키마 키는 전부 소문자다.
  - 길이 3–32 — `id`/`up`/`p0` 같은 2글자 키는 여기서 탈락한다(§2 · §4 참조).
  - `.`/`/`/`-`/공백을 배제 — 파일 경로·GLSL 토큰·로케일 문자열을 거른다.

**UTF-16LE**

- `(?:[\x20-\x7e]\x00){3,32}\x00\x00`, 짝수 오프셋 정렬, 앞 2바이트가 `\x00\x00`.
- 같은 정규식으로 판정.

재현:

```python
import re, struct
DATA = open(BIN, 'rb').read()          # rdata: rawptr 0x424E00, rawsize 0xB5200, RVA = off + 0x1200
blob = DATA[0x424E00:0x424E00 + 0xB5200]
KEY  = re.compile(r'^[a-z][a-z0-9_]{2,31}$')
asc  = {m.group()[:-1].decode(): m.start() for m in re.finditer(rb'[\x20-\x7e]{3,32}\x00', blob)
        if (m.start() == 0 or blob[m.start()-1] == 0)
        and KEY.match(m.group()[:-1].decode('ascii', 'ignore'))}
u16  = {m.group()[:-2].decode('utf-16-le'): m.start()
        for m in re.finditer(rb'(?:[\x20-\x7e]\x00){3,32}\x00\x00', blob)
        if m.start() % 2 == 0 and (m.start() < 2 or blob[m.start()-2:m.start()] == b'\x00\x00')
        and KEY.match(m.group()[:-2].decode('utf-16-le'))}
```

## 2. 단계별 개수

| 단계 | 개수 | 비고 |
| --- | --- | --- |
| ① `.rdata` ASCII 후보 | 1350 | |
| ① `.rdata` UTF-16LE 후보 | 93 | 그중 ASCII 에 없는 것 75 |
| ① 합집합 | **1425** | |
| ② 동봉 자산에 **키로** 등장 | **270** | 잔여 1155 는 §3 에서 폐기 |
| ③ Waple 소스에 `"키"` 리터럴이 코드로 존재 | 241 | 주석에만 있는 것은 제외 |
| ③ 미등장 | 29 | |
| ④ 오탐 제거(동적 구성·제네릭 슬롯 7건) | **22** | 최종 |

- 동봉 자산: `Sources/WapleRender/Resources/WEAssets/` 아래 `*.json` 1698개 + `*.tex-json` 298개
  = **1996개**(과제문의 "3655" 는 현재 트리와 맞지 않는다. 전체 파일 수도 2940개다).
  JSON 파싱은 `//` 주석과 후행 쉼표를 허용하는 관대 파서를 써서 **1996개 전건 파싱 성공**
  (엄격 파서는 31개 실패 — `effects/*/effect.json` 다수가 `//"preview" : ...` 주석을 갖고
  `effects/fluidsimulation/effect.json` 등은 배열 후행 쉼표를 갖는다).
- 자산 고유 키 511개 중 241개는 `.rdata` 후보에 없다. 세 부류다.
  1. 길이 2 (`id` 451건, `up` 168건, `p0`–`p3`) — 정규식 하한에 걸림.
  2. 대문자 포함 (`REFRACT`, `VERTICAL`, `CUTOUT`, `parallaxDepth`, `colorBlendMode`,
     `droplistOptions` …) — 콤보명·스크립트 프로퍼티라 키 정규식 대상 아님.
  3. **바이너리에 아예 없음** — `nonpoweroftwo`(232건), `nomip`(123건), `camerapreview`(168건),
     `spritesheetsequences`(52건), `gizmos`, `particlesrc`, `locktransforms`, `replacementkey`,
     `alphachannelpriority` 등. 전수 검색으로 ASCII/UTF-16 어느 쪽에도 없음을 확인했다.
     `.tex` 컴파일러·에디터 툴 쪽 어휘라 런타임 exe 에 들어오지 않는다.

## 3. 오탐 제거

**(a) 동봉 코퍼스 필터 — 1425 → 270.** 걸러진 1155개는 대부분 JSON 과 무관하다.
로케일명(`england`, `britain`, `czech`, `american`), PostScript 글리프명(`idieresis`,
`dieresis`, `bsuperior`, `seveneighths`, `dollaroldstyle`), DLL/서브시스템명(`advapi32`,
`audioses`, `cefcommandline`, `browserhook`, `asusstrixosd`), CRT 심볼(`frexp`, `eexec`,
`alnum`, `cntrl`), 익명 토큰(`si9`, `x47`, `n81`, `vx5`, `yj9`) 따위다.
UTF-16 후보 93개는 **한 개도** 자산 키와 겹치지 않았다 — WE 의 JSON 키는 전량 ASCII 이고,
UTF-16 문자열은 Win32 경로·UI·로케일 전용이다. 즉 UTF-16 스캔의 순수 기여는 0 이다.

**(b) Waple 구현 판정.** `grep -rF` 로만 보면 실패한다. 예를 들어 `duration` 은
`minperiodicduration` 의 부분문자열이라 항상 히트하고, `description` 은 SwiftUI 의
`description:` 인자에 히트한다. 그래서 **`"키"` 형태의 따옴표 리터럴이 주석이 아닌 코드 줄에
있는지**로 판정했다. `grep -rF "키"` 만 쓰면 미구현이 18개로 더 줄어드는데(부분문자열 히트를
구현으로 오인), 그건 과소보고다.
- 대상은 `Sources/**` 의 `.swift`/`.js`/`.h`/`.m` 155개 파일. **`Resources/WEAssets/` 는 제외한다** —
  동봉 자산 자체가 `Sources/` 안에 있어서 그냥 `grep -rF Sources/` 를 돌리면 모든 키가 자기 자신에
  히트해 결과가 전멸한다. 선행 스윕이 어긋난 원인 중 하나로 의심되는 지점이다.
- `version` 은 `"version"` 이 `SceneDocument.swift:2181` 주석에만 있어 **미구현**으로 판정했다.

**(c) 나머지 29개 중 7개는 오탐이다 — 제거한다.**

| 키 | 동봉 파일 수 | 제거 사유 |
| --- | ---: | --- |
| `controlpoint1` | 36 | `SceneDocument.swift:2327` 의 `io["controlpoint\(i)"]`, `i in 0..<8` 로 **동적 구성**. 리터럴만 없다. |
| `controlpoint2` | 24 | 위와 동일. |
| `point0` `point1` `point2` `point3` | 9/9/8/8 | `objects[].effects[].passes[].constantshadervalues` 하위 = **셰이더 상수 이름 슬롯**. `SceneDocument.parseEffects` 가 `for (k, v) in cs` 로 이름 불문 통과시킨다(lightshafts 폴리곤 꼭짓점). |
| `multiply` | 1 | 위와 동일한 `constantshadervalues` 슬롯. |

같은 논리로 `general.properties` 하위 이름도 `WallpaperProperties.parse(generalProperties:)` 가
제네릭 처리한다. 다만 `schemecolor` 는 **바이너리가 이 이름을 특수 처리**(26개 참조 사이트,
전용 저장 슬롯)하므로 표에 남기되 "제네릭 커버 + 특수 소비 미구현" 으로 표시했다.

## 4. 이 방법이 못 잡는 것

동봉 코퍼스 필터는 정밀도를 위해 **재현율을 버린다.** 정량적으로:

- 걸러진 1155개 중 **251개는 Waple 이 이미 구현한 진짜 JSON 키**다
  (`alphachange`, `boxrandom`, `controlpointattract`, `audioprocessingmode`,
  `turbulentvelocityrandom` 계열 …). 동봉 자산이 안 쓸 뿐 워크샵 자산은 쓴다.
- 즉 "동봉 도달 0" 은 "키가 아니다" 를 뜻하지 않는다. **동봉 도달 0 이면서 미구현**인 키가
  얼마나 되는지는 이 문서의 사정권 밖이고, 별도 스윕이 필요하다. 확실히 아는 것만 §부록 A 에 적었다.
- 선행 보고의 "147" 은 (a) `Resources/WEAssets` 를 grep 대상에서 빼지 않았거나
  (b) 동봉 도달 필터 없이 후보 전량을 대조했거나 (c) 위 두 오탐군을 걸러내지 않은 결과로 보인다.
  어느 쪽이든 이 문서의 22 와는 다른 모집단이다.

## 5. 미구현 키 — 동봉 도달 수 내림차순

> **이 표는 2026-08-21 00:53 UTC 스냅샷이다 — 현재 판정은 §0 을 봐라.** 22개 중 20개가
> 그 뒤 구현됐다(리터럴 18 + 동적 구성 2). 표를 지우지 않고 남기는 이유는 **동봉 도달 수 ·
> 값 분포 · 바이너리 귀속** 이 여전히 유효한 측정이기 때문이다. "미구현" 열만 낡았다.

동수일 때는 non-preview 파일 수, 그다음 키 이름 순으로 정렬했다.
"non-prev" 는 경로에 `preview` 가 없는 파일 수 — 실제 씬에서의 도달을 뜻한다.

### 5.1 자산·스키마

| # | 키 | 파일 | non-prev | 스키마 | 부모 경로 | 값 타입 · 실측 분포 | 대표 자산 |
| ---: | --- | ---: | ---: | --- | --- | --- | --- |
| 1 | `version` | 248 | 54 | effect / material / model / particle 루트 | `(root)` 242 · `passes[].combos` 6 | int — `0`×171 `1`×59 `2`×16 `3`×1 | `effects/blend/effect.json`, `effects/_empty/effect.json` |
| 2 | `description` | 207 | 65 | effect / preset 루트 | `(root)` | str(로컬라이즈 키) — `"ui_editor_preset_magic_description"` | `effects/blend/effect.json`, `presets/magic/preset.json` |
| 3 | `schemecolor` | 162 | 2 | project `general.properties` / material `usershadervalues` | `general.properties` 161 · `passes[].usershadervalues` 1 | dict×161 `{"order":0,"text":"ui_browse_properties_scheme_color","type":"color","value":"0 0 0"}` · str×1 `"tint"` | `scenes/modeleditor/project.json`, `materials/util/fade.json` |
| 4 | `duration` | 84 | 53 | **(a)** tex-json `spritesheetsequences[]` 52 · **(b)** particle `emitter[]` 32 | 위 두 곳 | int — `1`×54 `0`×30 | `materials/particle/bubbles/bubble1.tex-json`, `presets/lightning/particles/presets/thunderbolt.json` |
| 5 | `controlpointangle1` | 11 | 2 | scene `objects[].instanceoverride` | `objects[].instanceoverride`, `variants[].objects[].instanceoverride` | str "x y z"(라디안)×7 · `{animation:…}` 바인딩×4. 유효값 7건(`0 0 ±0.52360`, magic 애니) / 무효 4건(`0 -0 0`) | `presets/water/preset.json`, `presets/magic/preset.json` |
| 6 | `controlpointstartindex` | 8 | 2 | particle `children[]` | `children[]` (14건) | `null`×12 · int `1`×2 | `presets/lightning/particles/presets/thunderbolt.json`, `presets/fireworks/preview_fireworks1/particles/presets/fireworks1.json` |
| 7 | `arcamount` | 6 | 2 | particle `initializer[]` | `initializer[]` | float — `0.1`×4 `0.44`×2 | `presets/lightning/particles/presets/thunderbolt.json`, `presets/lightning/previewdischarge/particles/presets/dischargearc.json` |
| 8 | `wraploop` | 6 | 1 | 프로퍼티 애니메이션 `animation.options` | `…/animation/options` (7건) | `null`×5 · `true`×2 | `presets/magic/preset.json`, `effects/blendgradient/preview/scene.json` |
| 9 | `delay` | 4 | 2 | particle `emitter[]` | `emitter[]` | `0`×2 · `0.2`×2 | `presets/lightning/particles/presets/thunderbolt.json`, `presets/lightning/particles/presets/thunderbolt_beam_child.json` |
| 10 | `inputrangemax` | 4 | 1 | particle `initializer[]` 3 · `operator[]` 1 | 위 두 곳 | int — `50`×2 `200` `300` | `presets/lightning/particles/presets/thunderbolt_beam_child.json`, `scenes/particleelementpreviews/remapvalue/particles/new_particle_system.json` |
| 11 | `controlpointangle2` | 3 | 1 | scene `objects[].instanceoverride` | 5 번과 동일 | str `"0.00000 0.00000 0.52360"`×3 | `presets/water/preset.json`, `presets/water/previewdrippingwater/scene.json` |
| 12 | `nopadding` | 2 | 2 | model 루트 | `(root)` | `true`×2 | `scenes/gifs/models/background.json`, `scenes/videoplayer/models/background.json` |
| 13 | `transparentsorting` | 2 | 2 | scene `general` | `general` | `true`×2 | `scenes/modeleditor/scene.json`, `scenes/particleeditor3dscale/scene.json` |
| 14 | `auto` | 2 | 2 | scene `general.orthogonalprojection` | `general/orthogonalprojection` | `true`×2 | `scenes/gifs/gifscene.json`, `scenes/videoplayer/scene.json` |
| 15 | `spritesheetrefreshsync` | 2 | 2 | scene `general` | `general` | `true`×2 | `scenes/gifs/gifscene.json`, `scenes/videoplayer/scene.json` |
| 16 | `cone` | 2 | 1 | particle `emitter[]` | `emitter[]` | int `0`×2 (전건 무효값) | `presets/magic/particles/presets/magic_vortex_orb.json` |
| 17 | `lightconfig` | 2 | 1 | scene `general` | `general` | dict — `{"point":2}`, `{"point":1,"pointshadow":1}` | `scenes/modeleditor/scene.json`, `scenes/particleelementpreviews/collisionmodel/scene.json` |
| 18 | `collisionbehavior` | 2 | 0 | particle `operator[]` (collision*) | `operator[]` | str `"slide"`×2 | `scenes/particleelementpreviews/collisionquad/particles/new_particle_system.json` |
| 19 | `keepaspect` | 1 | 1 | material `passes[].usertextures[]` | `passes[].usertextures[]` | `true` | `scenes/videoplayer/materials/background.json` |
| 20 | `inputrangemin` | 1 | 0 | particle `operator[]` | `operator[]` | int `150` | `scenes/particleelementpreviews/remapvalue/particles/new_particle_system.json` |
| 21 | `bouncefactor` | 1 | 0 | particle `operator[]` (collision*) | `operator[]` | float `0.69999999` | `scenes/particleelementpreviews/collisionplane/particles/new_particle_system.json` |
| 22 | `pointshadow` | 1 | 0 | scene `general.lightconfig` | `general/lightconfig` | int `1` | `scenes/particleelementpreviews/collisionmodel/scene.json` |

### 5.2 바이너리 파서와 주입 ≠ 소비 판정

원본의 JSON 소비는 세 계층으로 갈린다. 판정은 이 계층 구분에 근거한다.

- **주입기** — `Json::Value::find`(`0x140087490`) 로 키를 찾아 **없으면**
  `operator[]`(`0x140086DE0`) 로 만들고 기본값을 심는다. DOM 만 바꾼다. 여기만 있으면 "주입".
- **리플렉션 바인더** `H_*` — `H_FLOAT 0x1401D7D30` / `H_INT 0x1401D7BE0` /
  `H_STRING 0x1401D7E80` / `H_BOOL 0x1401D8120`. `(rcx=아카이브, rdx=키, r8|xmm2=기본값)`.
  읽기·쓰기 양방향이며 멤버에 착지한다. 여기 있으면 "소비".
- **런타임 팩토리 / 직독** — `operator[]` + `asFloat`(`0x140086220`) / `asInt`(`0x140085F70`) /
  `asBool`(`0x140086300`) / `asString`(`0x140085CC0`) 후 구조체 오프셋에 저장. "소비".

| # | 키 | 파서 함수 VA | 참조 사이트 | 저장/효과 | 판정 |
| ---: | --- | --- | --- | --- | --- |
| 1 | `version` | 자산 스키마 리더 **없음**. `0x140056220`–`0x14005675C` 는 패키지 매니페스트 **기록**(`key/file/status/name/description/version/options`). `0x140040470`–`0x140041211` 은 `config.json`(`general/user/videoframework/editor`) 전용, `0x14011B950`–`0x14011BE39` 는 모듈 매니페스트(`name/version/exports`) | `0x140056566`, `0x140040DA0`, `0x14011BB5D` | — | **주입만 (소비 없음)** — effect/material/model 루트의 `version` 을 읽는 코드가 exe 에 없다. Waple 이 무시하는 게 맞다. |
| 2 | `description` | `0x140056220`–`0x14005675C` (직렬화 전용, `operator[]` 좌변) | `0x140056524` (1곳뿐) | — | **주입만 (소비 없음)** — 리더 0. 에디터 UI 표시용 로컬라이즈 키. |
| 3 | `schemecolor` | `0x140181AF0`–`0x140182F84` (project `general.properties` 파서) | `0x1401821F9` (+ UI/브라우저 계열 25곳) | `general.properties.schemecolor.value`("r g b") → `[wallpaper+0x31B0/0x31B4/0x31B8]` float3 (`0x140182311`–`0x140182323`) | **소비** — 전용 슬롯에 착지. Waple 은 이 이름을 특수 처리하지 않는다(제네릭 사용자 속성으로만 커버). |
| 4a | `duration` (emitter) | `0x1401C1C70`–`0x1401C1E17` (이미터 타이밍 리더) · 주입기 `0x1401B8DF0`–`0x1401B90FA` | `0x1401C1CA9` / `0x1401B8EC9`, `0x1401B8EEC` | `[emit+0x04]` 및 `[emit+0x0C]` 에 동일 값(`0x1401C1CC7`, `0x1401C1CF4`) = ON 윈도우 min/max 시드 | **소비** (멤버 저장 확정) |
| 4b | `duration` (tex-json) | **없음** — 부모 키 `spritesheetsequences` 문자열이 exe 에 존재하지 않는다 | — | — | **런타임 미도달** — `.tex` 컴파일 타임 메타. 별도로 `0x140177F70`–`0x1401786F1`(`rate/fps/duration/name/play/pause/stop`)은 런타임 시퀀스 객체의 프로퍼티 등록이며 tex-json 을 읽지 않는다. |
| 5 | `controlpointangle1` | `0x14024D940`–`0x14024E96E` (instanceoverride 프로퍼티 테이블: `controlpoint0..7` + `controlpointangle0..7`) | `0x14024E17A`, `0x14024E1F9` | 디스크립터에 타입 2 + 게터/세터 함수 포인터 등록 (`[desc+0x30]`=타입, `+0x38/+0x48/+0x50`=접근자) | **소비** |
| 6 | `controlpointstartindex` | `0x1401C1430`–`0x1401C179D` (`children[]` 바인더) · 팩토리 `0x1401C5490`–`0x1401D152C` | `0x1401C1723` (`H_INT`, 기본 0), `0x1401D09C4` | 자식 시스템 CP 인덱스 오프셋 | **소비** |
| 7 | `arcamount` | `0x1401BC080`–`0x1401BC470` (initializer 바인더) · 팩토리 `0x1401C5490`–`0x1401D152C` | `0x1401BC3D3` (`H_FLOAT`, 기본 **0.3** @`0x140492694`), `0x1401CA482` | 형제 키 `controlpointstart/controlpointend/arcdirection/sizereductionamount` 와 한 블록 | **소비** |
| 8 | `wraploop` | `0x1401A96B0`–`0x1401A98A8` (애니메이션 옵션: `length/fps/mode/random/startpaused/wraploop`) | `0x1401A97C3` | `find` → 타입 5(bool) 검사 → 분기 | **소비** (단 동봉 7건 중 5건이 `null` 이라 실효 도달은 2건) |
| 9 | `delay` | `0x1401C1C70`–`0x1401C1E17` · 주입기 `0x1401B8DF0`–`0x1401B90FA` | `0x1401C1CCC` / `0x1401B8F75`, `0x1401B8F98` | `[emit+0x08]`, `[emit+0x10]` (`0x1401C1CFA`, `0x1401C1CFF`) | **소비** |
| 10 | `inputrangemax` | 주입기 `0x1401BC4B0`–`0x1401BC980`(initializer) · `0x1401BFBB0`–`0x1401C0080`(operator) — 부재 시 기본 **int 1** 삽입(`0x1401BC676`). 리더는 팩토리 `0x1401C5490`–`0x1401D152C` | 주입 `0x1401BC634/0x1401BC655`, `0x1401BFD34/0x1401BFD55`; 리드 `0x1401CA9EB`, `0x1401CE98C` | 문자열/스칼라 파스 후 `movss [rax]` | **주입 + 소비 둘 다** |
| 11 | `controlpointangle2` | `0x14024D940`–`0x14024E96E` | `0x14024E2E5`, `0x14024E364` | 5 번과 동일 | **소비** |
| 12 | `nopadding` | `0x1401FAC50`–`0x1401FB498` (model 루트: `material/width/height/fullscreen/nopadding/autosize/passthrough/…`) | `0x1401FAE33` | bool → `[model+0x304] \|= 4` (`0x1401FAE56`) | **소비** |
| 13 | `transparentsorting` | `0x140199780`–`0x14019B4D6` (scene `general` 프로퍼티 테이블, bloom/fog/camera 47키와 동일 블록) | `0x14019ACC4`, `0x14019AD44` | 타입 6(bool) 디스크립터 + 게터 `0x14019BFA0` / 세터 `0x14019C070` | **소비** |
| 14 | `auto` | `0x140186C90`–`0x140188816` (scene 루트/`orthogonalprojection`) | `0x140187512` | bool true → `[scene+0xE0] \|= 0x18` (`0x140187565`) 이고 그때 `width`/`height` 를 **읽지 않는다** | **소비** |
| 15 | `spritesheetrefreshsync` | `0x140186C90`–`0x140188816` | `0x140187656` | bool true → `[scene+0xE0] \|= 0x40` (`0x140187674`) | **소비** |
| 16 | `cone` | `0x1401B9100`–`0x1401B992C` (이미터 지오메트리: `flags/origin/directions/sign/distancemin/distancemax/speedmin/speedmax/controlpoint/cone`) · 팩토리 `0x1401C5490`–`0x1401D152C` | `0x1401B94AE` (`H_FLOAT`, 기본 0), `0x1401C6146` | 이미터 원뿔 각 | **소비** (동봉 전건 `0` 이라 실효 도달 0) |
| 17 | `lightconfig` | `0x140186C90`–`0x140188816` | `0x1401876A2` (SSO — `lea` 아님, `mov eax,[rip+…+7]` + `movsd`) | 하위 카운트를 `[scene+0x121C]` 에 니블 패킹: `point`→bit0‑3, `spot`→4‑7, `tube`→8‑11, `directional`→12‑15, 이하 2비트 필드 (`0x140187B7A`–`0x140187C2C`) | **소비** — 라이트 종류별 최대 개수 = 셰이더 퍼뮤테이션 힌트 |
| 18 | `collisionbehavior` | 주입기 `0x1401C00A0`–`0x1401C03EC` · 리더 `0x1401C03F0`–`0x1401C0536` | 주입 `0x1401C0175/0x1401C01C1`, 리드 `0x1401C0403` | `asString` → `[op+0x10]` 에 열거값: `"slide"`(`0x14048FB04`)→1, `"stop"`(`0x140473B34`)→2, `"delete"`(`0x14048FB0C`)→3, 그 외→0 (`0x1401C0475`–`0x1401C04EC`) | **주입 + 소비** |
| 19 | `keepaspect` | `0x140154480`–`0x140155668` (material pass `usertextures`: `name/type/system/usershortcut/keepaspect/value/user`) | `0x140154871` | `find` → 태그5(`0x140154887`) → `asBool`(`0x140154890`) → `cmovne r12d, 1` (`0x1401548A0`) → 0x38바이트 레코드 `+0x30`(`0x140154a09`). **소비처**(2026-08-21 확정): `merged()` 로 `0x1401556e0`–`0x140155fbb`(6조각) — `0x140155d23` 이 로드 종횡비 강제를 해제하고 `0x140155daf` 가 `pass+0x2b0/+0x2b2` 를 실제 텍스처 치수로 덮는다 → `0x140209433`/`0x140209449` → `g_TextureNResolution.zw` | **소비** |
| 20 | `inputrangemin` | 10 번과 동일 (기본 **0** 삽입 `0x1401BC589`) | 주입 `0x1401BC541/0x1401BC56B`, `0x1401BFC41/0x1401BFC6B`; 리드 `0x1401CA89D`, `0x1401CE836` | `movss [rax], xmm6` (`0x1401CA925`) | **주입 + 소비** |
| 21 | `bouncefactor` | 주입기 `0x1401C00A0`–`0x1401C03EC` (기본 **0.5**, `movabs 0x3FE0000000000000` @`0x1401C0100`) · 리더 `0x1401C03F0`–`0x1401C0536` | 주입 `0x1401C00B7/0x1401C00DD`, 리드 `0x1401C0429` | `asFloat` → **`-1.0 - v`**(상수 −1.0 @`0x1404929B8` 적재 `0x1401C043D`, `subss` `0x1401C044F`) 후 `[op]` 에 4채널 브로드캐스트(`0x1401C0469`) — 반사 계수 −(1+e) | **주입 + 소비** — `-(1+e)` 변환 규약에 주의 |
| 22 | `pointshadow` | `0x140186C90`–`0x140188816` (`lightconfig` 하위) | `0x140187AF3` (SSO 적재) | `[scene+0x121C]` 니블 필드 | **소비** |

정리하면 **22개 중 소비되지 않는 건 `version`·`description`·`duration`(tex-json 쪽) 3건뿐**이고,
나머지 19건은 원본이 실제로 값을 쓴다. "미구현" 목록이지만 대부분은 진짜 기능 공백이다.

## 6. 상위 15 착지 지점

동봉 도달 상위 15개(§5 의 1–15). 파일은 `Sources/` 기준 상대 경로.

| # | 키 | 붙일 자리 |
| ---: | --- | --- |
| 1 | `version` | **착지 불필요** — 원본에도 리더가 없다. `WapleCore/EffectManifest.swift` `parseStrict` 에서 계속 무시하되, "리더 없음(§5.2)" 근거 주석만 남긴다. |
| 2 | `description` | **착지 불필요** — 리더 0. 다만 `Waple/PropertyEditorView.swift` 가 워크샵 항목 설명을 보여줄 때 로컬라이즈 키를 풀 여지는 있다(렌더 무관, UI 선택사항). |
| 3 | `schemecolor` | `WapleCore/WallpaperProperties.swift` `parse(generalProperties:localization:)` 가 이미 제네릭 파스하므로 **소비만 추가**: `WapleCore/SceneDocument.swift` `parse(...)` 에서 `general.properties.schemecolor.value` 를 `Vec3` 로 뽑아 `SceneDocument` 필드로 올리고, `WapleRender/SceneRenderer.swift` 의 엔진 상수 테이블에 `g_SchemeColor` 슬롯으로 노출한다. |
| 4 | `duration` | `WapleCore/ParticleSystem.swift` `parse(_:material:instanceOverride:resolveChild:)` 의 `json["emitter"]` 루프(`case "sphererandom"`/`"boxrandom"` 근처)에서 `injected(e, "duration", …)` 를 읽어 `Emitter` 에 ON 윈도우 필드를 추가하고, `emitterPeriodic` 과 같은 병렬 배열 규약으로 `ParticleSimulator` 방출 게이트에 넘긴다. tex-json 쪽은 손대지 않는다(런타임 미도달). |
| 5 | `controlpointangle1` | `WapleCore/ParticleSystem.swift` 의 `ParticleInstanceOverride` 에 `controlPointAngles: [Vec3?]` 를 추가하고 `WapleCore/SceneDocument.swift` `particleInstanceOverride(_:)` 에서 `io["controlpointangle\(i)"]` 를 `controlpoint\(i)` 와 같은 루프로 파스한 뒤, CP 를 소비하는 `ParticleSimulator` 의 CP 변환(attract/vortex 타깃 베이크)에서 회전을 적용한다. **CP 표현을 위치+회전으로 넓히는 게 선행 조건**이다. |
| 6 | `controlpointstartindex` | `WapleCore/ParticleSystem.swift` `json["children"]` 루프(≈:1877)에서 정수로 읽어, 자식 시스템이 부모 CP 배열을 참조할 때의 시작 인덱스로 쓴다. 동봉 14건 중 12건이 `null` 이라 **기본 0 폴백이 필수**. |
| 7 | `arcamount` | `WapleCore/ParticleSystem.swift` `parseInitializers(_:)` 의 원/구 계열 이니셜라이저에 `injected(o, "arcamount", 0.3)` 로 추가 — 기본값 0.3 은 `H_FLOAT` 상수(`0x140492694`)에서 온다. 형제 `arcdirection`(기본 `"0 1 0"`)과 짝이라 같이 붙이는 편이 낫다. |
| 8 | `wraploop` | `WapleCore/PropertyAnimation.swift` 의 options 파스(`mode`/`startpaused` 옆, ≈:213)에 `wrapLoop: (opts["wraploop"] as? Bool) ?? false` 를 추가하고 키프레임 샘플러의 마지막→처음 보간 경로에 태운다. `null` 은 false 로 접어야 한다(동봉 5/7 이 null). |
| 9 | `delay` | 4 번과 같은 자리 — `Emitter` 의 OFF(대기) 윈도우. `[emit+0x08]`/`[emit+0x10]` 구조를 그대로 min/max 쌍으로 옮긴다. |
| 10 | `inputrangemax` | `WapleCore/ParticleSystem.swift` `parseOperators(_:)` 의 `case "remapvalue"` → `RemapSpec` 에 `inMin`/`inMax` 를 추가한다(현재 입력을 `[0,1]` 로 가정한다). 기본값은 원본 주입기대로 `0`/`1`, 실측 값은 50–300 이라 미지원 시 리맵이 통째로 뭉개진다. `parseInitializers` 쪽 쌍둥이 블록도 같이. |
| 11 | `controlpointangle2` | 5 번과 동일 코드 경로(같은 `controlpointangle\(i)` 루프에서 함께 잡힌다). |
| 12 | `nopadding` | `WapleCore/SceneDocument.swift` `resolveLayerTexture(...)` 의 model 루트 플래그 파스(`model["fullscreen"]`/`model["autosize"]` 옆)에 bool 로 추가 — 텍스처 패딩 없이 원본 크기 그대로 쓰는 경로. |
| 13 | `transparentsorting` | `WapleCore/SceneDocument.swift` `parse(...)` 의 `general[...]` 블록(≈:981–1000)에서 bool 로 읽어 `SceneDocument` 에 얹고, `WapleRender/SceneRenderer3D.swift` 의 3D 오브젝트 정렬 단계에서 반투명 뎁스 정렬 토글로 소비. |
| 14 | `auto` | `WapleCore/SceneDocument.swift:981` 의 `general["orthogonalprojection"]` dict 분기에서 `proj["auto"] == true` 면 `width`/`height` 를 **읽지 말고** 뷰포트 크기를 그대로 쓰도록 한다(원본이 `\|= 0x18` 후 두 키를 건너뛴다). |
| 15 | `spritesheetrefreshsync` | 13 번과 같은 `general` 블록. 스프라이트시트 레이어의 프레임 진행을 씬 전역 클록에 동기화하는 플래그 — `WapleRender/SceneRenderer.swift` 의 스프라이트시트 프레임 선택에 전달. |

나머지 7개는 도달이 얕아 우선순위가 낮다.
`cone`(동봉 전건 0), `lightconfig`+`pointshadow`(`WapleRender/Scene3DLighting.swift` 의 라이트
슬롯 상한 8 을 종류별 카운트로 대체 — 코드 주석 :211 이 이미 이 필요를 적어 뒀다),
`collisionbehavior`+`bouncefactor`(`ParticleSystem.parseOperators` 의 collision 계열,
`bouncefactor` 는 원본이 `-(1+v)` 로 변환 저장, `collisionbehavior` 는 slide=1/stop=2/delete=3/기타=0), `inputrangemin`(10번과 동일),
`keepaspect` — **[2026-08-21 정정] `SceneDocument` 쪽 슬롯 정규화는 이미 완료**이고 남은 갭은
렌더 배선인데 **현재 도달 0** 이다: `materialUserTextureKeepAspect` 는 렌더러 소비처가 0건이고,
유일 도달 자산 `scenes/videoplayer/materials/background.json` 을 Waple 이 마운트하지 않으며
(비디오는 `SceneVideoLayer` 경로), WE 에서도 엔진이 런타임에 `wproperties.videotex.value` 를
써 넣어야 켜진다(`0x140120050`). `usertexturereference` 는 동봉+설치본 JSON 3655건에 0건.
전문은 `docs/re/material-blend.md` §2.5.

---

## 부록 A. 동봉 도달 0 이라 §5 에 못 올라간 미구현 키

§4 의 재현율 손실을 부분적으로 메운다. **§5.2 에서 스키마가 확정된 파서 함수 범위 안에서만**
문자열 참조를 재수집해, (후보 ∩ 동봉 도달 0 ∩ Waple 미구현) 인 것을 뽑았다. 즉 "JSON 키인 게
바이너리로 증명됐는데 동봉 자산이 안 쓰는" 키들이다. 워크샵 자산에는 나올 수 있다.

| 파서 | 키 |
| --- | --- |
| scene 루트 `0x140186C90`–`0x140188816` | `refreshdelay`, `precache`, `paths`, `norecompile`, `directionalshadow` |
| scene `general` `0x140199780`–`0x14019B4D6` | `customsortorder` |
| particle initializer `0x1401BC080`–`0x1401BC470` | `arcdirection`, `sizereductionamount` |
| particle remap `0x1401BC4B0`–`0x1401BC980`, `0x1401BFBB0`–`0x1401C0080` | `inputcomponent`, `outputcomponent` |
| model `0x1401FAC50`–`0x1401FB498` | `usertexturereference` |
| instanceoverride `0x14024D940`–`0x14024E96E` | `controlpointangle0`, `controlpointangle3`–`controlpointangle7` |
| project properties `0x140181AF0`–`0x140182F84` | `alignmentx`, `alignmenty`, `alignmentz`, `alignmentposition`, `alignmentfliph`, `lutparams`, `params`, `wcc_amt`, `wcc_v`, `wec_brs`, `wec_con`, `wec_e`, `wec_hue`, `wec_sa` |

같은 수집에서 나온 `controlpoint0`/`controlpoint3`–`controlpoint7` 은 Waple 이
`io["controlpoint\(i)"]` 로 이미 커버하므로 제외했고, `slide`/`stop` 은 키가 아니라
`collisionbehavior` 의 **값**이라 제외했다.

## 부록 B. 재현 절차

1. **후보 추출** — §1 의 스니펫. 결과 ASCII 1350 / UTF-16 93 / 합집합 1425.
2. **동봉 키 집계** — `Sources/WapleRender/Resources/WEAssets/**/*.{json,tex-json}` 1996개를
   관대 파서(`//` 주석 제거 + 후행 쉼표 제거)로 읽고, dict 를 재귀 순회하며 키·부모 경로·값을
   센다. 고유 키 511, 후보와의 교집합 270.
3. **소스 대조** — `Sources/**/*.{swift,js,h,m}` 중 `Resources/WEAssets` **제외** 155개 파일에서
   `"키"` 리터럴이 주석이 아닌 줄에 있는지 본다. 미등장 29.

   §0 재측정에 쓴 판정기(그대로 붙여 쓸 수 있다 — `//` 줄 주석 · `///` 문서 주석 ·
   `/* … */` 블록 주석 · 줄 끝 `//`(따옴표 밖의 것만)을 전부 지우고 남은 코드에서만 찾는다):

   ```python
   import os, re
   ROOT = "/home/user/Waple"
   EXCL = os.path.join(ROOT, "Sources", "WapleRender", "Resources", "WEAssets")
   files = [os.path.join(dp, f)
            for dp, _, fn in os.walk(os.path.join(ROOT, "Sources")) if not dp.startswith(EXCL)
            for f in fn if f.endswith((".swift", ".js", ".h", ".m"))]

   def code_lines(path):
       out, inblock = [], False
       for ln, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
           s = line.strip()
           if inblock:
               if "*/" in s: inblock = False; s = s.split("*/", 1)[1]
               else: continue
           while "/*" in s:
               pre, rest = s.split("/*", 1)
               if "*/" in rest: s = pre + rest.split("*/", 1)[1]
               else: s = pre; inblock = True; break
           if s.startswith(("//", "///", "*")): continue
           q = esc = False; cut = None                       # 따옴표 밖의 `//` 만 자른다
           for i, ch in enumerate(s):
               if esc: esc = False; continue
               if ch == "\\": esc = True; continue
               if ch == '"': q = not q; continue
               if not q and ch == "/" and s[i:i+2] == "//": cut = i; break
           if cut is not None: s = s[:cut]
           if s: out.append((ln, s))
       return out

   CACHE = {p: code_lines(p) for p in files}
   def implemented(key):
       return [(p, ln, s) for p, L in CACHE.items() for ln, s in L if '"%s"' % key in s]
   ```

   **이 판정기는 동적 구성을 못 잡는다** — `io["controlpointangle\(i)"]` 같은 보간은
   리터럴이 없어 "미구현" 으로 나온다. §3(c) 가 그 부류를 손으로 걸러 내는 이유다.
   그리고 이 판정기는 **리터럴의 존재**만 본다 — 그 값이 실제로 소비되는지는 보지 않는다.
4. **오탐 제거** — §3(c) 의 7개(동적 보간 2 + `constantshadervalues` 슬롯 5). 최종 22.
5. **바이너리 귀속** — `scripts/re/xref.py` 로 문자열 VA 와 `lea`/SSO 참조를 잡고
   `.pdata` 로 함수 경계를 잡는다(체인된 조각은 병합해야 한다). 짧은 키·13–15자 키는
   `lea` 가 아니라 `mov`/`movups` 로 스택에 조립되므로 **`lea` 스캔만으로는 놓친다**
   (`lightconfig`·`pointshadow` 가 실제로 그랬다). disp32 를 전수 훑어 타깃이 문자열 범위
   `[va, va+len]` 에 드는 모든 참조를 잡는 방식이 안전하다.
