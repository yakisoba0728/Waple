# `scene.json` 오브젝트 모델 — 실물 대조

대상: `wallpaper64.exe` 2.8.42 (imagebase `0x140000000`), 설치본
`wallpaper_engine/{assets,projects}`, 에디터 `ui/dist/scripts/scripts.js` ·
`ui/dist/monaco/autocomplete/lib.sceneScript.d.ts`.
조사일 2026-08-21. 모든 주소는 VA.

이 문서가 답하는 것: `objects[]` 의 **키 전수**, 트랜스폼 합성 규약(축 순서·단위·TRS·부모),
`instanceoverride` 스키마와 `controlpointangle*`, `variants`, `visible`, 레이어 정렬,
`effects[]` 부착. 그리고 그 각각에 대한 Waple 의 갭.

> **Waple 줄 번호 주의.** `Sources/WapleCore/SceneDocument.swift` · `ParticleSystem.swift` 는
> 이 라운드에 **다른 레인이 병행 편집 중**이라 줄 번호가 흔들린다. 이 문서의 `:NNNN` 은
> **2026-08-21 측정 시점** 값이고, 어긋나면 같은 줄에 적힌 **함수명·심볼명**으로 찾아라.

---

## 0. 요약 — Waple 과 어긋나는 것

| # | 항목 | WE 실물 | Waple 현재 | 근거 |
|---|---|---|---|---|
| 1 | `objects[].angles` 단위 | **라디안** (`sinf`/`cosf` 직접, `π/180` 없음) | 라디안으로 다루고 있으나(`parseText` 주석 "라디안, 이미 변환됨") 바이너리 근거가 문서에 없었다 | §4.2 |
| 2 | `angles` 축 순서 | 파일 `(x, y, z)`, 합성 **`Rz(z)·Ry(y)·Rx(x)`** | 미문서 | §4.2 |
| 3 | 로컬 TRS | `S`(로컬축) → `R` → `T`. 스케일은 회전 **행 3개에 성분별 곱** | 2D 경로는 `origin/scale/angle` 스칼라 합성 | §4.3 |
| 4 | 부모 합성 | `World = Local × ParentWorld`(행-벡터). **부모 스케일이 자식 회전·평행이동에 그대로 섞인다** | `composeParentTransforms` 가 2D 스칼라로 근사 | §4.4 |
| 5 | `controlpointangle0..7` | 실재 · 소비됨. CP 를 **4×4 로 확장**(회전 3행 + 위치 1행) | **미구현** | §6 |
| 6 | `instanceoverride` CP 게이트 | CP `flags & 0x10005`(bit0·2·16) 면 **오버라이드를 적용하지 않는다** | 무조건 대체 | §6.4 · §12 |
| 7 | `instanceoverride.id` | 인스턴스 오브젝트의 **씬 id 등록**(스크립트 조회 키) | 주석에 "미적용" — 실제로도 무해 | §5.3 |
| 8 | `objects[].depth` | **엔진이 안 읽는다**(문자열 자체가 없음) | 안 읽음 — 일치 | §2 · §9 |
| 9 | `objects[].locktransforms` | **엔진이 안 읽는다**(문자열 자체가 없음) | 파스해서 보존(소비처 없음) — 무해한 유령 필드 | §2 |
| 10 | `objects[].particlesrc` | **엔진이 안 읽는다**(문자열 자체가 없음) | 안 읽음 — 일치 | §2 |
| 11 | 드로우 순서 | `customsortorder` 켜졌고 `transparentsorting` 꺼졌을 때만 `sortorder` 오름차순 정렬, 그 외 **배열 순서** | 배열 순서(`order`) — 일치 | §9 |
| 12 | `preset.json` `variants` | **엔진이 안 읽는다** — 에디터 전용(문자열 자체가 없음) | 안 읽음 — 일치 | §7 |
| 13 | `text.spacing` | 디스크립터 타입 1 = **vec2** | `float(obj["spacing"])` 로 스칼라 파스 | §2 · §12 |
| 14 | `effects[]` 드롭 | 엔진은 `visible:false` 여도 **붙이고** 렌더에서 게이트 | 파스에서 드롭(스크립트 있는 것만 보존) | §10 |
| 15 | `objects[].config` | **엔진이 안 읽는다**(`"config"` 조회 사이트 0). `passthrough`/`autosize`/`solidlayer`/`projectlayer`/`instanced` 는 `objects[].image` 가 가리키는 **모델 JSON 루트**의 키다 | `obj["config"]` 를 읽어 같은 플래그를 채운다 — 동봉 4건은 결과가 같지만 **경로가 다르다** | §2.1 정정 |
| 16 | `objects[].scale` z · `angles` x·y | 공통 디스크립터가 **둘 다 vec3**(태그 2, `+0x134`/`+0x140`) | **[2026-08-21 닫음]** `SceneLayer`/`SceneTextLayer` 가 `scaleZ`·`angleX`·`angleY` 로 보존(파스 전용) | §12.1 |
| 17 | `text` 의 `parallaxDepth` | **공통** 오브젝트 디스크립터의 vec2 키(`+0x170`, 태그 1) — 타입별 키가 아니다 | **[2026-08-21 닫음]** `SceneTextLayer.parallaxDepth` 파스. **렌더 소비는 아직** — §12.1.4 | §12.1 |
| 18 | `general.orthogonalprojection.width`/`height` | **둘 다** 태그 1..3 일 때만 읽고, 아니면 두 스토어를 모두 건너뛴다(`0x140187572`–`0x14018758a` → `0x140187602`) | **[2026-08-21 닫음]** `numericInt` 전부-아니면-전무 게이트. 종전 `lenientInt` 는 `{"width":true}` → 1×1 | §12.1 |

---

## 1. 동봉 코퍼스의 정의와 총계

이 문서의 "동봉 코퍼스" 는 설치본 `wallpaper_engine/` 전체에서 **씬 문서** 로 쓰이는 JSON 이다:
`scene.json` 184개 + `gifscene.json` 2개 = **186개**. 저장소 사본
`Sources/WapleRender/Resources/WEAssets/` 는 그중 `assets/` 하위 171 + 1 = 172개와 바이트 동일이고
(`diff -rq` 무출력 — 트리 전체가 동일),
나머지 13(+1)은 `projects/defaultprojects` · `projects/templates/gif` 다.

`preview` 판정은 **경로 세그먼트에 `preview` 문자열이 들어가면 preview** 다
(`previewtorch/` · `particleelementpreviews/` 등). 이 규약으로 **preview 167 / non-preview 19** 이고,
과제 지시의 `controlpointangle1` "11건 / 2 non-prev" · `controlpointangle2` "3건 / 1" 과 정확히 맞는다(§11.3).

| | |
| --- | --- |
| 씬 문서 | 186 (preview 167 · non-preview 19) |
| 파스 실패 | 0 — 전건 엄격 JSON(줄 주석·트레일링 콤마 없음) |
| `objects[]` 원소 | **294** (non-preview 95) |
| 최상위 키 | `general` 186 · `objects` 186 · `camera` 185 · `version` 90 — 그 외 0 |

오브젝트 타입 도수(§3 판정 기준):

| 타입 | 전체 | preview | non-preview |
|---|---:|---:|---:|
| image | 142 | 76 | 66 |
| particle | 123 | 116 | 7 |
| model | 12 | 1 | 11 |
| light | 6 | 3 | 3 |
| text | 5 | 3 | 2 |
| shape(effect quad) | 3 | 3 | 0 |
| sound | 2 | 0 | 2 |
| node(콘텐츠 키 없음) | 1 | 1 | 0 |

---

## 2. `objects[]` 키 전수 — 엔진 ↔ Waple 대조

동봉 186 씬 전수에서 `objects[]` 원소가 갖는 키는 **65개**다. 아래가 전건이며 **자르지 않았다**
(§2.1 공통·팩토리 24 + §2.2 image 11 + text 16 + light 8 + sound 6 = 65.
§2.2 의 image `nointerpolation` 과 "도달 0 등록 키" 목록은 65 밖 — 엔진에는 있으나 코퍼스에 없다).

`F`=등장 파일 수 · `O`=등장 오브젝트 수 · `npF`/`npO`=non-preview 분. `엔진` 열은 두 부류다:

* **디스크립터** — 프로퍼티 디스크립터 테이블에 등록된 이름. 등록부 VA(§2.2)와
  구조체 멤버 오프셋을 적었다. 이 부류는 JSON 주입과 씬스크립트 프로퍼티가 **같은 항목**이다.
* **직접** — 파서가 손으로 읽는 키. 읽는 지점 VA 를 적었다.
* **없음** — 바이너리에 그 문자열이 ASCII·UTF-16LE 어느 쪽으로도 없다.

### 2.1 공통(모든 타입) 및 팩토리 키

> **[2026-08-21 정정] `npF`/`npO` 열 13개가 틀려 있었다 — 분모가 §1 선언과 달랐다.**
> `F`/`O` 열은 §1 이 정의한 **186 씬 전수**로 맞게 세어져 있었는데(40행 전건 재현),
> `npF`/`npO` 열은 **`projects/**` 14개 파일로만** 세어져 있었다. §1 이 선언한 non-preview 는
> **19개**(= `projects/**` 14 + `assets/scenes/**` 5)다. 빠져 있던 `assets/scenes/**` 중
> 오브젝트를 가진 것은 `gifs/gifscene.json`(1) · `modeleditor/scene.json`(2) ·
> `videoplayer/scene.json`(1) 세 파일 4오브젝트고(`particleeditor`·`particleeditor3dscale` 는
> `objects` 가 비어 있다), 그 4오브젝트가 `origin`·`scale`·`angles`·`id`·`name`·`image`·
> `visible`·`color`·`light`·`intensity`·`radius`·`locktransforms`·`parallaxDepth` 13개 열을
> 각각 모자라게 만들고 있었다. **13행 전부 §1 규약대로 다시 세어 고쳤다.**
>
> 재현(이 스니펫이 지금 40행 전건과 일치한다 — 하나라도 어긋나면 표가 낡은 것이다):
>
> ```python
> import json, os, collections
> ROOT = "/home/user/Waple-wallpaper-source/wallpaper_engine"
> files = sorted(os.path.join(dp, f) for dp, _, fn in os.walk(ROOT) for f in fn
>                if f in ("scene.json", "gifscene.json"))          # 186개
> prev = lambda p: any("preview" in s for s in os.path.relpath(p, ROOT).split(os.sep))
> kf = ko = npf = npo = None
> kf, ko, npf, npo = (collections.Counter() for _ in range(4))
> for p in files:                                                   # preview 167 / non-preview 19
>     d = json.loads(open(p, "rb").read().decode("utf-8-sig")); seen = set(); pv = prev(p)
>     for o in d.get("objects") or []:
>         for k in o:
>             ko[k] += 1; seen.add(k)
>             if not pv: npo[k] += 1
>     for k in seen:
>         kf[k] += 1
>         if not pv: npf[k] += 1
> ```

| 키 | F | O | npF | npO | 타입(관측) | 엔진 | Waple |
|---|---:|---:|---:|---:|---|---|---|
| `origin` | 184 | 293 | 17 | 94 | str(291) · dict(2) | 디스크립터 `+0x128` vec3 — 등록 `0x1401e05e3` | `SceneDocument.swift:1529`·`1674` 외 |
| `id` | 182 | 292 | 15 | 93 | int | 직접 `0x14022b01e` | `SceneDocument.swift:1521`·`1526` |
| `name` | 181 | 291 | 14 | 92 | str | 디스크립터 `+0x1d8` string — `0x1401e11e1` | `SceneDocument.swift:1807` 외 |
| `scale` | 173 | 254 | 17 | 74 | str | 디스크립터 `+0x134` vec3 — `0x1401e06b4` | `:1531`·`1676` 외 |
| `angles` | 110 | 174 | 16 | 59 | str(173) · dict(1) | 디스크립터 `+0x140` vec3 — `0x1401e076a`, 전용 주입기 `0x1401df2f0` | `:1530`·`1673`·`2160` 외 |
| `parallaxDepth` | 88 | 131 | 6 | 34 | str(2성분) | 디스크립터 `+0x170` **vec2** — `0x1401e0840` | `:1801`·`1965`·`2073`·`2790` |
| `visible` | 46 | 113 | 6 | 60 | bool(104) · dict(9) | 디스크립터 `+0x120` **bit0** — 타입별 등록(§8) | `:1509`·`1510` (`parse` 본문) |
| `parent` | 1 | 2 | 0 | 0 | int | 직접 `0x1401de4b1`(함수 `0x1401de470`–`0x1401de741`) | `:1532`·`1846` 외 |
| `dependencies` | 9 | 10 | 0 | 0 | list | 직접 `0x14022afae` · `0x1401ddd8e` | `:1852`·`2247`(보존) |
| `effects` | 55 | 103 | 4 | 41 | list | 직접 `0x1401e7004`(파서 `0x1401e6f50`–`0x1401e716c`) | `:1802`·`2014`·`2074`·`2191`·`2239` |
| `instanceoverride` | 91 | 94 | 2 | 5 | dict(61) · null(33) | 직접 `0x14022b42c` | `:2771` → `particleInstanceOverride` `:2851` |
| `sprite` | 1 | 2 | 1 | 2 | null(2) | 직접 — 팩토리 키 순서 `0x140190304` | `:1953` `parseSprite` |
| `image` | 118 | 193 | 13 | 69 | str(142) · null(51) | 팩토리 콘텐츠 키 `0x14019029f` | `:1544` |
| `particle` | 124 | 128 | 5 | 9 | str(123) · null(5) | 팩토리 콘텐츠 키 `0x1401901e9` | `:1554` |
| `model` | 57 | 66 | 5 | 14 | str(12) · null(54) | 팩토리 콘텐츠 키 `0x14019013c` | `:1573` |
| `light` | 4 | 6 | 3 | 5 | str | 디스크립터 `+0x2c0` enum — `0x14025e4d7`, 팩토리 키 `0x1401903ba` | `:1576` |
| `text` | 4 | 5 | 1 | 2 | dict(3) · str(2) | 디스크립터 `+0x450` string — `0x14025a10c`, 팩토리 키 `0x14019034d` | `:1569`·`2137` |
| `sound` | 1 | 2 | 1 | 2 | list | 직접(팩토리) | `:1499` → `parseSound` `:1910` |
| `shape` | 3 | 3 | 0 | 0 | str(`"quad"`) | 팩토리 콘텐츠 키 | `:2014` `isEffectQuad` |
| `config` | 3 | 4 | 0 | 0 | dict | **없음 — 유령 키**(아래 정정) | `SceneDocument.parseLayer` 의 `obj["config"]`(보존) |
| `depth` | 48 | 52 | 0 | 0 | int(51) · float(1) | **없음** | 안 읽음 |
| `locktransforms` | 24 | 53 | 7 | 35 | bool | **없음** | `:1859`·`2121`·`2198`·`2804` 파스만(소비처 0) |
| `particlesrc` | 21 | 21 | 0 | 0 | null(21) | **없음** | 안 읽음 |
| `solid` | 17 | 37 | 3 | 22 | bool(전건 true) | 디스크립터 `+0x120` **bit13** — `0x1401e1283`. **생성자 기본 `true`**(`mov word [r14+0x120], 0x2001` @`0x1401ddc72`), 뜻은 커서 히트테스트 참가(`ui_editor_properties_enable_click_events` = "Enable click events") | `SceneDocument.parseLayer`/`parseCameraObject`/`parseText`/`parseParticle` 의 `weBool(obj["solid"], true)`(소비처 0) |

> **[2026-08-21 정정] `objects[].config` 는 리더 0 인 유령 키다 — 이전 판이 남의 파서를 갖다 붙였다.**
>
> 이전 판은 `config` 를 "서브노드 획득 `0x1401fd330` · `passthrough` 판독 `0x1401fae95`" 라고
> 적었다. **둘 다 `objects[].config` 를 보는 코드가 아니다.**
>
> * `0x1401fd330`(=`0x1401fd330`–`0x1401fd3f0`, `primary()`)은 `[this+0x1b0]` 의 JSON 에서
>   **키 `"image"`**(`0x14048e390`, `lea rdx` @`0x1401fd347`, `operator[]` `0x140086de0`
>   @`0x1401fd355`)를 찾아 태그 4(string)이면 그 문자열을 `[[this+0xc8]+0x1898]` 서브시스템에
>   넘겨(`0x1400d3f80` @`0x1401fd390`) 받아 온 텍스트를
>   **jsoncpp 리더 `0x140017840`**(@`0x1401fd3a0`)로 파싱해 출력 `Json::Value`(`rdx`)에 담는다.
>   `0x140017840` 이 jsoncpp 인 근거: 그 함수 안에 `collectComments` · `allowComments` ·
>   `allowTrailingCommas` · `strictRoot` · `allowDroppedNullPlaceholders` · `allowNumericKeys` ·
>   `allowSingleQuotes` · `stackLimit` · `failIfExtra` · `rejectDupKeys` · `allowSpecialFloats` ·
>   `skipBom` — `CharReaderBuilder::setDefaults` 의 설정 키가 통째로 들어 있다.
>   즉 **모델 JSON 로더**지 `config` 서브노드 획득이 아니다.
>   ([추정] `0x1400d3f80` 자체는 문자열이 0건이라 "파일 읽기" 라고 못 박지는 못한다 —
>   확정된 것은 **`"image"` 값을 넘겨 받은 텍스트를 JSON 으로 파싱한다**는 데까지다.
>   그 텍스트가 모델 파일 내용이라는 것은 아래 실물 대조로 뒷받침된다.)
> * 그 결과를 받는 `0x1401fac50`–`0x1401fb498` 이 `material` · `width` · `height` ·
>   `fullscreen`(bit1) · `nopadding`(bit2) · `autosize`(bit3) · `passthrough`(bit5) ·
>   `solidlayer`(bit9) · `projectlayer`(bit10) · `instanced`(bit11) 을 읽어
>   `[obj+0x304]` 에 OR 한다(`passthrough` 는 `0x1401faeb8` `or dword [rdi+0x304], 0x20`).
>   **이 키들은 전부 모델 JSON 루트의 키다** — 실물로 `assets/models/util/composelayer.json`
>   이 `{"material": …, "passthrough": true}` 이다. 설치본 `.json` **2,143개 전수** 중
>   `passthrough` 를 **키로**(값이 아니라 — `materials/util/passthrough.json` 의
>   `"shader": "passthrough"` 는 값이다) 가진 파일은 **7개**뿐이고, 그중 4개가
>   `assets/models/util/{composelayer, composelayer_depthtest, fullscreenlayer, projectlayer}.json`,
>   나머지 3개가 아래 씬이다.
> * `objects[].config` 를 이름으로 찾는 코드는 **없다**. `"config\0"` C 문자열은 바이너리
>   전체에 4곳뿐이고(`0x1404748c9`·`0x140474c14`·`0x140477f47`·`0x14048e4e5`), 그중 셋은
>   각각 `wallpaperconfig`·`monitorconfig`·`lightconfig` 의 **접미사**다. 독립 문자열
>   `0x140474c14` 의 begin/end 쌍(`0x140474c14`/`0x140474c1a`)을 쓰는 조회는 `0x140020ee6`
>   **한 곳**이고, 거기는 `title`/`config`/`selectedwallpapers` 를 읽는 **트레이 재생목록**
>   코드다(씬 파서 아님). `.text` 안에 `config` 를 만드는 SSO 즉치(`mov` 리터럴)도 **0바이트**다
>   (함정 10 대비 — 이미지 전체 바이트 스캔으로 확인). UTF-16LE 도 0건.
>
> **그래서 무엇이 참인가.** 동봉 4건은 전부 `{"passthrough": true}` 이고, 그 오브젝트는
> **동시에** `"image": "models/util/composelayer.json"` 을 갖는다 — 그 모델 파일 자체가
> `passthrough: true` 다. 즉 `objects[].config` 는 에디터가 남긴 **중복 미러**고, 엔진은
> 모델 파일 쪽만 읽는다. Waple 이 `obj["config"]` 를 읽어 같은 결론에 도달하는 것은 동봉
> 코퍼스에서는 **결과가 우연히 같지만 경로가 다르다** — 모델 파일에만 `passthrough` 가 있고
> `objects[].config` 가 없는 워크샵 자산에서 갈린다. Waple 은 모델 루트 파스도 이미 갖고 있다
> (`SceneDocument.swift` 의 `noPadding = weBool(mj["nopadding"])` 계열, 선언부 주석이 이
> 함수 범위를 정확히 인용한다). **`config` 는 `depth`·`particlesrc`·`locktransforms` 와 같은
> 부류(엔진 리더 0)로 옮겨 읽어야 한다.**

### 2.2 타입별 키 — 등록부 대조

각 타입의 프로퍼티 디스크립터 등록부(= 그 타입이 JSON 에서 읽는 키의 정본):

| 타입 | 등록부 VA | 등록 개수 |
|---|---|---:|
| 오브젝트 베이스 `IObject` | `0x1401e0530`–`0x1401e1389` | 19 = 프로퍼티 8 + 메서드 11 |
| 이미지 레이어 | `0x1401ee520`–`0x1401ef118` | 15 = 프로퍼티 12 + 메서드 3 |
| 이미지 레이어(스크립트 확장) | `0x140211070`–`0x140212523` | 24 = `alignment` 1 + 메서드 23 |
| 텍스트 | `0x140258ca0`–`0x14025a713` | 29 |
| 라이트 | `0x14025da80`–`0x14025e9da` | 18 |
| 사운드 | `0x1401f7090`–`0x1401f7b96` | 13 = 프로퍼티 9 + 메서드 4 |
| 모델 | `0x140227470`–`0x140227c51` | 9 = 프로퍼티 4 + 메서드 5 |
| 카메라 오브젝트 | `0x1401f3460`–`0x1401f38b5` | 4 |
| 파티클 오브젝트 | `0x14024cb00`–`0x14024d022` | 7 = `visible`·`instance` + 메서드 5 |
| 파티클 `instance`(=`instanceoverride`) | `0x14024d940`–`0x14024e96e` | **24** (§5) |
| 이펙트 | `0x1401efca0`–`0x1401f05fc` | 6 = `visible`·`name` + 메서드 4 |
| 애니메이션 레이어 | `0x14026c980`–`0x14026d5de` | 18 = 프로퍼티 11 + 메서드 7 |
| 씬 `general` | `0x140199780`–`0x14019b4d6` | **47** (전건 프로퍼티 · 아래 정정 참조) |

> **[2026-08-21 정정] 씬 `general` 은 42 가 아니라 47 이다.** 이전 판의 42 는 부록 A.2 덤프
> 스크립트가 이름 대입을 **`call 0x14000f880` 하나로만** 잡았기 때문이다. 이 함수의 **마지막
> 5개 항목은 다른 `std::string::assign` 오버로드 `0x14000ddd0` 을 쓴다** — 그래서 통째로
> 빠졌다. 빠진 5개는 전부 실재하고 **동봉 186 씬 중 69 씬(37%)이 쓴다**:
>
> | 키 | 타입 | 멤버 | 이름 대입 VA | 동봉 도달 |
> |---|---|---|---|---:|
> | `gravitydirection` | 2 = vec3 | `+0x3e4` | `0x14019b2f3` | 69 |
> | `gravitystrength` | 4 = float | `+0x3f0` | `0x14019b35c` | 69 |
> | `windenabled` | 6 = 접근자(bit) | `+0xe0` | `0x14019b3b7` | 69 |
> | `winddirection` | 2 = vec3 | `+0x3f4` | `0x14019b436` | 69 |
> | `windstrength` | 4 = float | `+0x400` | `0x14019b498` | 69 |
>
> 오프셋이 `0x3e4`(vec3) → `0x3f0` → `0x3f4`(vec3) → `0x400` 으로 **빈틈 없이 이어진다**는 것이
> 5개가 같은 등록부 소속임을 자체로 증명한다. 형제 문서
> [`scene-postprocessing.md`](scene-postprocessing.md) 가 같은 5개를 같은 VA 로 독립 확인했고
> ("키 47개 … 전건 일치"), Waple 도 `SceneDocument.swift:3497`–`3501` 에서 이미 읽는다.
>
> **세는 방법(이게 정본이다).** 항목 경계를 이름 대입 호출로 잡으면 오버로드를 놓친다.
> **프로퍼티 등록 호출 `call 0x14015a000`(= `table[key]` 슬롯 생성) 의 횟수**를 세라 —
> 범위 `0x140199780`–`0x14019b4d6`(`primary()`/`merged()` 둘 다 이 값, `.pdata` 단편 1개)에서
> **47회**다. 이 규약은 다른 등록부와도 맞아떨어진다: `IObject` 19개 중 REG 8 = "프로퍼티 8",
> image 15개 중 REG 12 = "프로퍼티 12", sound 13개 중 REG 9 = "프로퍼티 9",
> model 9개 중 REG 4, 애니메이션 레이어 18개 중 REG 11 — 전부 위 표의 "프로퍼티 N" 과 같다.
> `general` 만 REG 47 = 항목 47 이라 **메서드가 하나도 없다**. 검증 스크립트는 부록 A.2.

**image**(`0x1401ee520`)

| 키 | F | O | npF | npO | 관측 타입 | 멤버/타입 | Waple |
|---|---:|---:|---:|---:|---|---|---|
| `size` | 57 | 121 | 5 | 57 | str(2성분) | `+0x2f0` vec2 | `:1675` |
| `color` | 27 | 48 | 6 | 26 | str(47) · dict(1) | `+0x330` vec3 | `:1799` |
| `alpha` | 15 | 33 | 2 | 19 | float | `+0x33c` float | `:1798` |
| `brightness` | 11 | 29 | 2 | 19 | float | `+0x340` float | `:1800` |
| `perspective` | 17 | 37 | 3 | 22 | bool | `+0x120` bit | `:1851` |
| `castshadow` | 19 | 19 | 0 | 0 | bool | `+0x120` bit | `:2237` |
| `copybackground` | 39 | 71 | 4 | 24 | bool | `+0x304` bit | `:1855` |
| `nointerpolation` | 0 | 0 | 0 | 0 | — | `+0x304` bit | `:1857` |
| `clampuvs` | 6 | 6 | 0 | 0 | bool | `+0x304` bit | `:1856` |
| `ledsource` | 14 | 34 | 3 | 22 | bool | `+0x304` bit | `:1861` |
| `colorBlendMode` | 35 | 65 | 4 | 24 | int | `+0x32c` int | `:1842`·`2205` |
| `visible` | — | — | — | — | bool/바인딩 | `+0x120` bit(접근자, 타입 6) | 〃 |
| `alignment`※ | 12 | 30 | 2 | 19 | str(전건 `"center"`) | `+0x4b1` enum(`0x14021114b`) | `:1849` |

> ※ `alignment` 는 **`0x1401ee520` 이 아니라 스크립트 확장 등록부 `0x140211070` 소속**이다
> (그 등록부의 유일한 프로퍼티 — REG 1). 이전 판은 이 표에 `alignment` 를 넣으면서
> **`0x1401ee520` 이 실제로 등록하는 `visible` 을 빠뜨렸다**. `0x1401ee520` 의 프로퍼티 12개는
> `size` `color` `alpha` `brightness` **`visible`** `perspective` `castshadow` `copybackground`
> `nointerpolation` `clampuvs` `ledsource` `colorBlendMode` 이고, 나머지 3개 항목은 메서드
> (`getEffect` `getEffectCount` `transformAttachmentToTexture`)다. 부록 A.2 로 재현된다.
>
> **이미지 레이어에 `spacing` 은 없다(유령 키).** `"spacing"` C 문자열은 이미지 전체에
> `0x140491878` **한 곳**뿐이고(UTF-16LE 0건 · `.text` SSO 즉치 0바이트), 그 disp32 참조는
> **정확히 2건**(`0x140259458` 의 SSO 복사 · `0x1402594e6` 의 `lea rdx`)이며 **둘 다 텍스트
> 등록부 `0x140258ca0`–`0x14025a713` 안**이다. 텍스트 쪽 등록은 `0x1402594f4`(이름 대입),
> 타입 1 = vec2, `+0x4f8` — §12 표 5번이 말하는 그것이다. 이미지 레이어 파스는 보존일 뿐
> 소비처가 0 이다(`SceneDocument.swift` 의 `layer.spacing` 선언부 주석이 같은 근거를 든다).

**text**(`0x140258ca0`) — 동봉 도달이 있는 것만 표에 싣고, 도달 0 인 등록 키는 아래 목록으로 대신한다.

| 키 | F | O | 관측 | 멤버/타입 | Waple |
|---|---:|---:|---|---|---|
| `font` | 4 | 5 | str | `+0x490` string | `:2148` |
| `pointsize` | 4 | 5 | float | `+0x4e0` float | `:2149` |
| `horizontalalign` | 4 | 5 | str | `+0x59c` enum | `:2152` |
| `verticalalign` | 4 | 5 | str | `+0x59e` enum | `:2153` |
| `anchor` | 4 | 5 | str | `+0x550` enum | `:2213` |
| `padding` | 4 | 5 | int | `+0x4e8` **vec2** | `:2214` (`uniformVec2`) |
| `backgroundcolor` | 4 | 5 | str | `+0x4d0` vec3 | `:2211` |
| `opaquebackground` | 4 | 5 | bool | `+0x594` bit | `:2210` |
| `backgroundbrightness` | 1 | 2 | float | `+0x4dc` float | `:2215` |
| `blockalign` | 1 | 2 | bool | `+0x594` bit | `:2173` |
| `depthtest` | 1 | 2 | str | `+0x5a0` enum | `:2202` |
| `limitwidth`/`limitrows`/`limituseellipsis` | 1 | 2 | bool | `+0x594` bit ×3 | `:2170`–`2172` |
| `maxwidth` | 1 | 2 | float | `+0x508` float | `:2170` |
| `maxrows` | 1 | 2 | int | `+0x510` int | `:2171` |

도달 0 이지만 등록되어 있는 text 키(14개): `spacing`(**vec2** `+0x4f8`, `0x1402594f4`) ·
`msdf` · `outline` · `blur` · `dropshadow` · `outlinethickness` · `outlinecolor` ·
`blursize` · `dropshadowsize` · `dropshadowopacity` · `dropshadowcolor` ·
`dropshadowoffset`(vec2 `+0x53c`) — 나머지는 위 표와 중복.

**light**(`0x14025da80`)

| 키 | F | O | npF | npO | 관측 | 멤버/타입 | Waple |
|---|---:|---:|---:|---:|---|---|---|
| `color` | (공유) | 6 | | 3 | str | `+0x2cc` vec3 | `:2269` |
| `intensity` | 4 | 6 | 3 | 5 | float | `+0x2e4` float | `:2271` |
| `radius` | 4 | 6 | 3 | 5 | int(2) · float(4) | `+0x2e8` float | `:2270` |
| `exponent` | 1 | 1 | 0 | 0 | float | `+0x2ec` float | `:2272` |
| `density` | 1 | 1 | 0 | 0 | float | `+0x2f8` float | `:2281` |
| `volumetricsexponent` | 1 | 1 | 0 | 0 | float | `+0x2fc` float | `:2280` |
| `cascadedistance0` · `cascadedistance1` · `cascadedistance2` | 1 | 1 | 0 | 0 | float | `+0x300` · `+0x304` · `+0x308` | `:2261` |
| `castshadow` | (공유) | 1 | | 0 | bool | `+0x2c4` bit | `:2275` |

도달 0 등록 키: `innercone`(`+0x2f0`) · `outercone`(`+0x2f4`) · `lightsourcesize`(`+0x30c`) ·
`controlpoint`(**vec3** `+0x2d8`) · `usecookie` · `castvolumetrics`.

**sound**(`0x1401f7090`)

| 키 | F | O | 관측 | 멤버/타입 | Waple |
|---|---:|---:|---|---|---|
| `volume` | 1 | 2 | float | `+0x2f0` | `:1920` |
| `mintime` | 1 | 2 | float | `+0x2f4` | `:1925` |
| `maxtime` | 1 | 2 | float | `+0x2f8` | `:1926` |
| `playbackmode` | 1 | 2 | str(`"single"`) | `+0x30c` enum | `:1923` |
| `startsilent` | 1 | 2 | bool | `+0x310` bit | `:1924` |
| `muteineditor` | 1 | 2 | bool | `+0x310` bit | **안 읽음** |

도달 0 등록 키: `attenuation`(`+0x304`) · `mindistance`(`+0x308`) · `spatialization`.

**model**(`0x140227470`): `visible` · `perspective` · `castshadow` · `rootmotion`(`+0x310` bit, 도달 0).
**camera object**(`0x1401f3460`): `visible` · `fov`(`+0x2d8`) · `zoom`(`+0x2dc`) · `queuemode`(`+0x350` enum) — 동봉 도달 0.

### 2.3 디스크립터 타입 코드

`[desc+0x30]` 의 값 ↔ 주입기(`[desc+0x38]`) 대응. **과제 지시의 `+0x30`=타입 / `+0x38`·`+0x48`·`+0x50`=접근자는 맞다.**
추가로 `[desc+0x34]` = **멤버 오프셋**, `[desc+0x58]` = 변경 통지 훅, `[desc+0x68]` = 이름 문자열이다.

| `+0x30` | 의미 | 주입기(`+0x38`) | raw set(`+0x48`) | raw get(`+0x50`) |
|---:|---|---|---|---|
| 1 | vec2 | `0x1401a3fc0` | `0x1401a4200` | `0x1401a4220` |
| 2 | vec3 | `0x1401a4230` | `0x1401a4530` | `0x1401a4560` |
| 3 | int | `0x1401a4930` | `0x1401a49f0` | `0x1401a4a10` |
| 4 | float | `0x1401a4b00` | `0x1401a49f0` | `0x1401a4a10` |
| 5 | string / enum | `0x1401a4bc0` (enum 은 타입마다 전용) | | |
| 6 | bool — **플래그 워드의 한 비트**(비트 인덱스가 접근자에 인라인) | 예: `0x1401e1a90` | | |
| 7 | 오브젝트 참조 | — | | `0x1401a4da0` |
| 8 | bool — 바이트 | `0x1401a4a20` | `0x1401a4ad0` | `0x1401a4af0` |

vec3 주입기 `0x1401a4230` 는 `strtod`(`0x1402d06ac`)로 공백 구분 3-float 을 읽고,
**단위 변환을 전혀 하지 않는다**. 값이 숫자면 3성분에 브로드캐스트한다(`0x1401a436c`–`0x1401a4380`).
바인딩 객체(`{value:…}`)면 `value` 를 꺼내 같은 경로로 처리한다(`0x1401a43ba`).

---

## 3. 오브젝트 타입 판정 — 콘텐츠 키 우선순위

`objects[]` 원소에 `type` 필드는 **없다.** 팩토리가 키 존재로 갈라진다. Waple 소스(`SceneDocument.parse` 안의 주석, `:1565`)가
인용한 WE 팩토리의 `mov ecx, size` VA 순서 `0x14019013c` · `0x1401901e9` · `0x14019029f` ·
`0x140190304` · `0x14019034d` · `0x1401903ba` = **model → particle → image → sprite → text → light → …** 이다.

동봉 코퍼스에서 이 우선순위가 실제로 갈리는 경우는 **`null` 콘텐츠 키**다:
`image: null` 51건 · `model: null` 54건 · `particle: null` 5건 · `sprite: null` 2건 · `particlesrc: null` 21건.
즉 저작 툴이 **모든 콘텐츠 키 슬롯을 `null` 로 채워 내보내므로**, 키의 *존재* 가 아니라
**값이 비어 있지 않은 문자열인지**로 판정해야 한다. Waple 의 `contentValue()`(NSNull → nil)가 이 규약이다 — 일치.

---

## 4. 트랜스폼 — 축 순서·단위·TRS·부모

### 4.1 오브젝트 베이스 레이아웃

생성자 겸 베이스 JSON 파서 `0x1401ddbb0`–`0x1401de19b` 가 심는 기본값:

| 오프셋 | 필드 | 기본 | 스토어 VA |
|---|---|---|---|
| `+0x120` | 플래그 워드 (bit0=`visible`) | — | — |
| `+0x124` | `sortorder` (int) | **0** | `0x1401ddc7c` |
| `+0x128` | `origin` vec3 | (0,0,0) | — |
| `+0x134` | `scale` vec3 | **(1,1,1)** | `0x1401ddc8a`–`0x1401ddca0` |
| `+0x140` | `angles` vec3 (원본 라디안 보관) | (0,0,0) | — |
| `+0x14c` | 회전 3×3 (9 float) | 단위행렬 | `0x1401ddcb2`–`0x1401ddcd6` |
| `+0x170` | `parallaxDepth` vec2 | 1.0 | `0x1401ddce1` |
| `+0x180` | parent 포인터 | null | `0x1401ddcfe` |
| `+0x190` | attachment index | **-1** | `0x1401ddd0c` |
| `+0xe0` | 캐시된 로컬×부모 4×4 (16 float) | — | §4.3 |
| `+0xd0` | 4×4 캐시 프레임 스탬프 | 0 | — |

### 4.2 회전 — 축 순서와 단위 **[실측 확정]**

`angles` 는 전용 주입기 `0x1401df2f0`–`0x1401df581` 을 쓴다. 이 주입기는 문자열을 3-float 으로 읽고
곧장 `setAngles`(`0x1401dd630`, 함수 `0x1401dd580`–`0x1401dd7c5`)를 호출한다. **중간에 어떤 상수 곱도 없다.**

`setAngles` 는 세 성분 각각에 `0x14041a2e0` 과 `0x14041a9c0` 을 호출한다. 이 둘의 정체는
스켈레톤 문서가 이미 확정한 오일러→행렬 헬퍼 `0x140215020`–`0x14021519c` 로 교차 확인했다:
그 헬퍼의 `m00 = cos(a2)·cos(a1)`(`docs/re/skeleton-animation.md` §2.1)에 해당하는 스토어가
`0x1402150d6` 이고 그 값이 `f(a2)·f(a1)`(둘 다 `0x14041a2e0`)이므로 **`0x14041a2e0` = `cosf`,
`0x14041a9c0` = `sinf`** 다.

`setAngles` 는 `[rdx+8]`(= z) → `[rdx+4]`(= y) → `[rdx+0]`(= x) 순으로 sin/cos 를 구하고
`+0x14c` 부터 9개를 쓴다(`cx=cos x` … `sz=sin z`):

```
+0x14c = cy·cz            +0x158 = sy·cz·sx − cx·sz     +0x164 = cx·cz·sy + sx·sz
+0x150 = cy·sz            +0x15c = sy·sz·sx + cx·cz     +0x168 = cx·sz·sy − sx·cz
+0x154 = −sy              +0x160 = sx·cy                +0x16c = cx·cy
```
(스토어 VA: `0x1401dd6fe` · `0x1401dd727` · `0x1401dd72f` · `0x1401dd73b` · `0x1401dd761` ·
`0x1401dd76c` · `0x1401dd785` · `0x1401dd78d` · `0x1401dd795`. `−sy` 의 부호 반전은
`xorps` vs `0x140492ff0` = `{0x80000000}×4`, `0x1401dd70a`.)

이 9개를 (열0, 열1, 열2) 로 읽으면 정확히 **`Rz(z)·Ry(y)·Rx(x)`** 의 열-우선 3×3 이다.
헬퍼 `0x140215020` 의 `(a1,a2,a3)` 와 대조하면 `a1=z, a2=y, a3=x` 로 일치한다.

> **결론 — 실측 확정.**
> * 파일 3성분의 의미는 **`(x, y, z)`** 다(스켈레톤 `.mdl` 키의 `(Z,Y,X)` 바이트 순서와 다르다).
> * 합성은 **`R = Rz(z)·Ry(y)·Rx(x)`** — 내재 회전으로 X→Y→Z 순.
> * 단위는 **라디안**. `sinf`/`cosf` 에 값이 그대로 들어가고 `π/180`(0.0174533) 도 `π/360` 도 없다.

**코퍼스 교차 검증.** 동봉 씬의 `angles` 는 173건 519성분, 그중 0 이 아닌 것 29개.
`|v|` 최대가 **3.14200**(≈π)이고 π 를 넘는 값이 하나도 없다. 도(度) 규약이면 90·180·45 가 나와야 한다.
게다가 값의 상당수가 정수 도(度)를 라디안으로 변환한 잔여값이다 —
`0.03491`(=2°) · `0.05236`(=3°) · `0.10472`(=6°) · `0.13963`(=8°) · `0.29671`(=17°) ·
`0.40143`(=23°). 에디터 UI 는 도로 보여 주고 파일에는 라디안을 쓴다.

### 4.3 로컬 4×4 — TRS 순서 **[실측 확정]**

`0x1401850a0`–`0x1401852f7` 이 오브젝트의 4×4 를 `[obj+0xe0]` 에 굽는다(프레임 스탬프 `[obj+0xd0]` vs
씬 `[scene+0x144]` 로 캐시 무효화, 부모 체인 유효성 검사 `0x140185040`–`0x140185099`).

```
row0 = scale.x · (m00, m01, m02)     [obj+0xe0 .. +0xe8],  [obj+0xec] = 0
row1 = scale.y · (m03, m04, m05)     [obj+0xf0 .. +0xf8],  [obj+0xfc] = 0
row2 = scale.z · (m06, m07, m08)     [obj+0x100 .. +0x108],[obj+0x10c] = 0
row3 = origin                        [obj+0x110 .. +0x118],[obj+0x11c] = 1.0
```
스토어 VA: `0x1401851e6` · `0x1401851ea` · `0x1401851f6` (row0), `0x140185228`–`0x140185238` (row1),
`0x140185267`–`0x140185282` (row2), `0x140185150`–`0x14018516e` (row3), `0x140185146`(=1.0).

행-벡터 규약(`v' = v·M`)이므로 열-벡터로 옮기면 **`p' = T(origin) · R(z,y,x) · S(scale) · p`** —
즉 **스케일 먼저, 그다음 회전, 마지막 평행이동**. 비균일 스케일은 **오브젝트 로컬 축**에 걸린다.

### 4.4 부모 합성 — 부모 스케일이 자식에 섞이는 방식 **[실측 확정]**

같은 함수 꼬리(`0x14018528a`–`0x1401852e3`):

```
parent = [obj+0x180]
if (parent) {
    if ([obj+0x190] >= 0)  parent->vtbl[0x78](parent, attachIdx, /*inout*/ M);   // 본/어태치먼트 선-변환
    P = parent->worldMatrix();                       // 재귀 (0x1401852b0)
    M = matmul(out, A=P, B=M);                       // 0x1401852c0
}
```
`0x14005ecb0`–`0x14005efef` 의 곱셈은 `B` 의 각 행 성분을 스칼라로 뽑아 `A` 의 행들에 곱한다
(`movss xmm5,[r8]` / `movsd xmm3,[rdx]` … `0x14005ecca`–`0x14005ecf2`), 즉 **`out = B · A`**.
따라서 `M ← Local · ParentWorld` — 행-벡터에서 **자식 로컬이 먼저, 부모가 나중**이다(표준).

> **부모 스케일 → 자식 회전.** 부모의 4×4 는 이미 `scale.x/y/z` 가 **행별로 곱해진** 상태다.
> 그 행렬을 자식 로컬의 오른쪽에 곱하므로, **부모의 비균일 스케일은 자식의 회전 축을 늘려
> 전단(shear)을 만든다.** 별도의 "회전에서 스케일을 벗겨내는" 보정은 없다.
> 자식의 평행이동도 부모 스케일만큼 늘어난다(= row3 이 부모 행렬을 통과).

씬스크립트가 보는 `getTransformMatrix`(`0x1401df5e0` → vtbl `+0x80`)의 구현
`0x1401dd7d0`–`0x1401dd8f5` 은 **스케일이 없는** `R|T` 4×4 를 같은 방식으로 부모 체인 합성한다.
두 행렬은 다르다 — 스크립트 API 로 읽은 행렬에는 스케일이 안 들어 있다.

### 4.5 계층

`parent` 는 **오브젝트 `id`** 를 가리킨다(`0x1401de470`–`0x1401de741` 이 `parent`/`attachment` 를 읽는다).
`disablepropagation`(`+0x120` **bit14**, 등록 `0x1401e132b`)은 **커서 클릭 전파 차단**이지
**트랜스폼 상속과 무관하다**. 부모→자식 합성부 `sub_1401850a0`(vtbl `+0x80`, `0x1401850a0`–`0x1401852f7`)은
`[obj+0x180](parent)` 만 보고 플래그워드 `+0x120` 을 **아예 읽지 않으며**(전문 참조 0건, 10 vtable 오버라이드 0),
bit14 를 읽는 코드는 이미지 전체에서 커서 이벤트 디스패처 `0x14018a877` **1곳**뿐이다.
에디터가 이 키를 로케일 키 `ui_editor_properties_disable_click_propagation`
(= "Disable click propagation")에 묶는다. 상세는 `docs/re/object-propagation.md` §3·§4·§5.
동봉 코퍼스 도달은 §11.2.

---

## 5. `instanceoverride` 전수 스키마

### 5.1 정체

`instanceoverride` 는 **파티클 오브젝트의 `instance` 서브오브젝트**(씬스크립트 `IParticleSystemInstance`)를
JSON 으로 직렬화한 것이다. 파티클 오브젝트 등록부 `0x14024cb00` 이
`instance` 를 타입 7(오브젝트 참조) · 멤버 `+0x778` 로 등록한다(`0x14024cc92`).

파서 `0x14022af30`–`0x14022b92a` 의 처리 순서:

1. `instanceoverride` 노드 획득 — `0x14022b446`.
2. **레거시 마이그레이션**: 노드에 `color`(0..255 표기)가 있으면 3성분을 `/255` 해서
   `sprintf("%.5f %.5f %.5f")`(포맷 문자열 `0x1404890d8`)로 만들고 `colorn` 으로 **삽입**한 뒤
   `color` 를 **제거**한다(`0x14022b462`–`0x14022b746`). 즉 엔진 내부에서 `color` 는 존재하지 않는다.
3. 노드가 객체(태그 7)면
   `0x1401a38f0(&instance.id /*obj+0x780*/, node)` → **`id` 등록**(§5.3),
   `0x1401730d0(scene+0x1708, &obj->instance /*+0x778*/, node)` → **멤버별 주입**.
   객체가 아니면 기본값 인스턴스를 생성한다(`0x14022b7a2` → 생성자 `0x14024d760`).

`0x1401730d0`–`0x14017470f` 은 **JSON 오브젝트의 멤버를 순회하며 이름으로 디스크립터를 찾아 주입**한다
(멤버 이름 획득 `0x14017313a`, 대상 vtbl 호출 `0x14017314f`). 따라서 **디스크립터에 없는 키는 조용히 무시**된다.

### 5.2 디스크립터 24개 (전수)

등록부 `0x14024d940`–`0x14024e96e`. `+0x34`= `instance` 구조체 내부 오프셋.

| # | 이름 | `+0x30` 타입 | `+0x34` 오프셋 | 등록 VA | 생성자 기본값 |
|---:|---|---:|---|---|---|
| 1 | `alpha` | 4 float | `0xc8` | `0x14024d9fc` | 1.0 |
| 2 | `size` | 4 float | `0xcc` | `0x14024dac3` | 1.0 |
| 3 | `count` | 4 float | `0xd0` | `0x14024db78` | 1.0 |
| 4 | `speed` | 4 float | `0xd4` | `0x14024dc2d` | 1.0 |
| 5 | `lifetime` | 4 float | `0xd8` | `0x14024dcda` | 1.0 |
| 6 | `rate` | 4 float | `0xdc` | `0x14024de3f` | 1.0 |
| 7 | `brightness` | 4 float | `0xe0` | `0x14024dd94` | 1.0 |
| 8 | `colorn` | 2 vec3 | `0xe4` | `0x14024def1` | **(−1,−1,−1)** 센티널 |
| 9–16 | `controlpoint0..7` | 2 vec3 | `0xf0` + 12·i | `0x14024dfc7` · `0x14024e15e` · `0x14024e2c9` · `0x14024e410` · `0x14024e533` · `0x14024e656` · `0x14024e779` · `0x14024e89c` | `.x = FLT_MAX` 센티널 |
| 17–24 | `controlpointangle0..7` | 2 vec3 | `0x150` + 12·i | `0x14024e09f` · `0x14024e20a` · `0x14024e375` · `0x14024e498` · `0x14024e5bb` · `0x14024e6de` · `0x14024e801` · `0x14024e924` | `.x = FLT_MAX` 센티널 |

생성자 `0x14024d760`–`0x14024d8c6`: 스칼라 7개 = `0x3f800000`(1.0, `0x14024d7a2`–`0x14024d7e4`),
`colorn` = `0xbf800000`×3(−1, `0x14024d7ee`–`0x14024d802`),
CP·CP각 16개의 **`.x` 만** `0x7f7fffff`(FLT_MAX, `0x14024d813`–`0x14024d8a9`), `[+0x1b0]` = 0.

> **읽는 법.** 스칼라 7개는 **배수**(기본 1.0). `colorn` 의 −1 과 CP/CP각의 `.x == FLT_MAX` 는
> "지정 안 됨" 센티널이다 — 값 0 과 구분된다. 이 센티널이 §6 의 소비 게이트에서 그대로 쓰인다.

과제 지시가 준 참조 VA 4개는 재확인 결과 **디스크립터 이름 문자열의 `lea` 지점**이며,
컴파일러가 *다음* 항목의 이름 `lea` 를 *현재* 항목의 필드 스토어 **사이에 끼워 넣기 때문에**
`lea` 주변만 보면 한 칸 밀려 읽힌다:

| 지시 VA | 실제로 무엇인가 |
|---|---|
| `0x14024e17a` | `controlpoint1` 블록 안에서 **다음** 항목 `controlpointangle1` 의 이름 `lea` 를 선-적재 |
| `0x14024e1f9` | `controlpointangle1` 블록의 이름 `lea`(→ 이름 대입 `0x14024e20a`) |
| `0x14024e2e5` | `controlpoint2` 블록 안에서 **다음** `controlpointangle2` 의 이름 `lea` 선-적재 |
| `0x14024e364` | `controlpointangle2` 블록의 이름 `lea`(→ 이름 대입 `0x14024e375`) |

항목 경계는 `mov rbx, [rbp-0x30]`(디스크립터 재-로드) 지점이다. 이 경계로 자르면 위 24행 표가 나온다.

### 5.3 `id`

`instanceoverride.id` 는 프로퍼티가 **아니다**. `0x1401a38f0`–`0x1401a3bde` 가 노드에서 `id` 를 찾아
(`0x1401a3911`·`0x1401a3946`·`0x1401a3973`) 정수이고 0 이 아니면 그 값을 `instance` 객체의
id 슬롯(`obj+0x780` = `instance+8`)에 넣고 씬 id 맵에 등록한다(`0x1401a39ab` → `0x140078250`).
0 이거나 없으면 새 id 를 할당한다(`0x1401a39b8` 경로).

동봉 실측으로도 그렇다 — `remapvalue/scene.json` 의 오브젝트 `id`=26, `instanceoverride.id`=27 로 **서로 다르다**.
따라서 "다른 오브젝트를 가리키는 참조" 가 아니라 **인스턴스 서브오브젝트 자신의 씬 id** 다.
Waple 이 무시하는 것은 옳다(스크립트에서 `id` 로 인스턴스를 찾는 기능이 없으므로).

### 5.4 값 형태

주입기는 스칼라/문자열을 직접 받고, 노드가 객체면 **바인딩 파서**
`0x1401a4db0`–`0x1401a5a8e` 를 태운 뒤 `value` 를 초기값으로 꺼낸다.
바인딩 파서가 읽는 키 전수: `user` · `name` · `condition` · `type` · `animation` · `options` ·
`parent` · `key` · `relative` · `value` · `c0`~`c3` · `events` · `script` · `scriptproperties`
(각각 `0x1401a4de7` · `0x1401a4ef5` · `0x1401a4f1b` · `0x1401a4f41` · `0x1401a50b5` · `0x1401a5230` ·
`0x1401a5273` · `0x1401a52b4` · `0x1401a538a` · `0x1401a53b6` · `0x1401a550b`~`0x1401a568a` ·
`0x1401a57a3` · `0x1401a5803` · `0x1401a5829`).

동봉 코퍼스 `instanceoverride` 값 형태: 숫자 · `"x y z"` 문자열 ·
`{user, value}`(count 2건) · `{animation:{c0,c1,c2,…}}`(controlpointangle1 4건).

---

## 6. `controlpointangle0..7` — 단위와 결합

### 6.1 파티클 정의 쪽의 짝

파티클 `.json` 의 `controlpoint[]` 파서는 `0x1401c5490`–`0x1401d152c` 안,
`0x1401d04ec`(키 `"controlpoint"`)–`0x1401d0814` 다. **고정 8회 루프**(`inc r14d` / `cmp r14d, 8`
@`0x1401d0807`–`0x1401d080a`)이고 슬롯 주소는 `shl rdi,5` = **인덱스 × 32** 로 만든다.

| 슬롯 필드 | 오프셋(정의 구조체) | 읽는 키 | 판독 VA |
|---|---|---|---|
| flags | `0xa4 + 32·i` | `flags` | `0x1401d058c` → 스토어 `0x1401d05ae` |
| parent | `0xa8 + 32·i` | `parentcontrolpoint` | `0x1401d07eb` → 스토어 `0x1401d07ff` |
| offset vec3 | `0xac + 32·i` | `offset` | `0x1401d05b6` → 스토어 `0x1401d06ac` |
| **angles vec3** | `0xb8 + 32·i` | **`angles`** | `0x1401d06ce` → 스토어 `0x1401d07c9` |

즉 **CP 는 정의 단계에서부터 위치 + 각도 쌍**이다. 동봉 파티클 250파일 1856 CP 원소 중
`angles` 를 쓰는 것은 0건이라, 실제 저작은 각도를 **씬의 `instanceoverride` 로만** 넣는다.

루프가 끝난 뒤 `0x1401d081b`–`0x1401d087e` 가 파스 도중 모은 인덱스 집합(`[rbp+0x600]`,
삽입 지점 `0x1401cafe0`·`0x1401cf07e` — remap 계열 엘리먼트의 출력 CP)을 훑어
그 CP 들의 `flags` 에 **`|= 0x10000`(bit16)** 을 세운다(`0x1401d086c`). 즉 bit16 은
**JSON 으로 저작할 수 없고 로드 시 엔진이 붙이는 비트**다 — Waple 이 이미 "remap 출력 대상" 으로
문서화한 그 비트와 같다.

### 6.2 런타임 소비 — CP 는 4×4 다 **[실측 확정]**

씬 파티클 오브젝트의 CP 갱신 루틴 `0x14022bd40`–`0x14022c30a`, 핵심 구간
`0x14022bf3d`–`0x14022c0b6`:

```
xmm12 = FLT_MAX                                        ; 0x14022bec6 (상수 0x14049297c)
dst   = [sys+0x400] + i*0xD0                           ; 0x14022bf15/0x14022bf1f  (레코드 0xD0 바이트)
if (dst[+0xC0] & 0x10005) continue;                    ; 0x14022bf26  ← §6.3 플래그 게이트
touched = false                                        ; xor cl,cl @0x14022bf3b
angles.x = [obj + 0x8c8 + 12·i]                        ; 0x14022bf3d  (= instance+0x150 + 12i)
if (angles.x == FLT_MAX) goto position;                ; 0x14022bf47 / 0x14022bf4d
cz=cos([+0x8d0]) sz=sin([+0x8d0])                      ; 0x14022bf60 / 0x14022bf6c
cy=cos([+0x8cc]) sy=sin([+0x8cc])                      ; 0x14022bf81 / 0x14022bf8d
cx=cos(angles.x) sx=sin(angles.x)                      ; 0x14022bf99 / 0x14022bfa6
touched = true                                         ; mov cl,1 @0x14022bfba
dst[+0x80..0x88] = ( cy·cz,  cy·sz, −sy )              ; 0x14022bfcd / 0x14022bff6 / 0x14022bfff
dst[+0x90..0x98] = ( sy·cz·sx − cx·sz, sy·sz·sx + cx·cz, sx·cy )   ; 0x14022c00b / 0x14022c031 / 0x14022c03a
dst[+0xa0..0xa8] = ( cx·cz·sy + sx·sz, cx·sz·sy − sx·cz, cx·cy )   ; 0x14022c057 / 0x14022c060 / 0x14022c069
position:
pos.x = [obj + 0x868 + 12·i]                           ; 0x14022c073  (= instance+0xf0 + 12i)
if (pos.x == FLT_MAX) { if (!touched) continue; else goto next; }  ; 0x14022c07d–0x14022c08d
dst[+0xb0..0xb8] = pos                                 ; 0x14022c08f / 0x14022c098 / 0x14022c0af
```

> **`0x868` = `0x778 + 0xf0`, `0x8c8` = `0x778 + 0x150`** — §5.2 의 `controlpointN` / `controlpointangleN`
> 오프셋과 정확히 맞는다. 소스가 `instanceoverride` 임이 산술로 확정된다.

**결론.**
* `controlpointangleN` 의 3성분 → 위 sin/cos 조합은 §4.2 의 `setAngles` 와 **식이 완전히 동일**하다.
  따라서 **단위는 라디안, 파일 순서는 `(x, y, z)`, 합성은 `Rz(z)·Ry(y)·Rx(x)`** 다.
* **CP 위치와의 결합 방식**: 곱해지거나 더해지지 않는다. 런타임 CP 레코드(`0xD0` 바이트)의
  `+0x80` 부터가 **4×4 변환**이고, 회전 3행이 `controlpointangleN` 에서, 평행이동 행(`+0xb0`)이
  `controlpointN` 에서 각각 **독립적으로** 채워진다. 즉 각도는 CP 를 움직이지 않고 **CP 프레임의 방향**을 준다.
* 두 슬롯은 **개별 센티널**을 가진다 — 각도만 지정하거나 위치만 지정하는 것이 가능하다.

코퍼스 값이 이 해석을 뒷받침한다: `presets/water` 의 물방울 프리셋은
`controlpoint1 = "22 0 0"` / `controlpointangle1 = "0 0 −0.52360"`,
`controlpoint2 = "−22 0 0"` / `controlpointangle2 = "0 0 0.52360"` —
**±22px 떨어진 두 CP 를 Z 축으로 ∓30°(= ∓π/6 rad)씩 벌린 수도꼭지**다.

### 6.3 적용 게이트 **[Waple 갭]**

CP 갱신 진입부에 게이트가 있다(`0x14022bf26`):

```
rdi = [sys+0x400]; rbx = cpIndex*0xD0
if ([rdi + rbx + 0xC0] & 0x10005) skip;      ; jne 0x14022c17d
```
`0x10005` = **bit0(값 1) | bit2(값 4) | bit16(값 0x10000)**. Waple 이 이미 문서화한 CP 플래그 의미
(`ParticleSystem.swift:1486` `controlPointFlags` 선언 주석)와 맞는다 —
bit0 = 마우스 포인터 구동, bit2 = 부모 시스템 CP 에 부착, bit16 = 엔진 갱신 스킵(remap 출력 대상).
**이 셋 중 하나라도 서 있으면 `instanceoverride` 의 CP 위치·각도가 적용되지 않는다.**

동봉 파티클 CP 원소는 1856개(그중 `flags` 를 명시한 것 1812)이고 값 분포는
`0` 1757 · `1` 28 · `2` 10 · `4` 7 · `16` 10 이다. 값을 **비트로** 풀면 게이트에 걸리는 것은
`flags:1`(bit0) 28 + `flags:4`(bit2) 7 = **35 원소**다.
`flags:2`(bit1)·`flags:16`(**bit4**, 0x10 ≠ 0x10000)는 게이트 대상이 **아니다** — 값 16 을
bit16 으로 읽지 않도록 주의. bit16 은 §6.1 대로 로드 시 엔진이 붙인다.

### 6.4 Waple 선행 조건 — 코드 수준

`docs/re/bundled-key-coverage.md` 와 `SceneDocument.swift:2842` 인근 주석의 유보("CP 표현을 위치+회전으로
넓히는 게 선행 조건")를 구체화하면 이렇다. **1→6 순서로 해야 한다** — 3만 먼저 넣으면 값을 받아
버릴 곳이 없다.

1. **`ParticleSystem.swift` `ParticleSystemDef.controlPoints`(`:1477`)** — 이 배열을
   위치+회전으로 넓힌다. 최소 변경은 형제 배열 추가:
   `public var controlPointAngles: [Vec3] = Array(repeating: .zero, count: 8)`.
   (구조체로 접는 편이 낫지만 `controlPointFlags`/`controlPointParent` 가 이미 형제 배열이라
   그 관례를 따르는 쪽이 파급이 작다.)
2. **`ParticleSystem.swift` 정의 파서 `cp["offset"]` 판독부(`:2555`)** — 옆에서 `cp["angles"]` 를 읽게 한다.
   현재 소스 주석이 "offset 만 소비, 나머지 셋은 의미 미측정" 이라고 적어 둔 그 자리다.
   `angles` 의 의미는 이제 §6.2 로 측정됐다(라디안, `Rz·Ry·Rx`).
3. **`ParticleSystem.swift` `ParticleInstanceOverride.controlPoints`(`:1277`)** 옆에
   `controlPointAngles: [Int: Vec3]` 를 추가하고 같은 구조체의 `isEmpty` 에 반영.
4. **`SceneDocument.particleInstanceOverride`(`:2851`, CP 루프 `:2872`)** — `controlpoint\(i)` 루프 옆에
   `controlpointangle\(i)` 루프를 더한다. 값 언랩은 `vec3()` 로 동일(문자열·`{value}`·`{animation,value}`).
5. **`ParticleSystem.swift` 오버라이드 적용부(`:2563`)** — 두 가지를 같이 고쳐야 한다:
   (a) 각도도 대체, (b) **§6.3 의 게이트** — `controlPointFlags[id] & 0x10005 != 0` 이면 건너뛴다.
   현재는 무조건 대체라 마우스 구동 CP(bit0)나 부모 부착 CP(bit2)까지 덮어쓴다.
6. **소비처** — `ParticleSimulator.swift:1661`(`def.controlPoints[id]`) 의
   `controlPointPos(id)` 는 CP 를 순수 위치로 본다. 회전이 실제로 그림에 나타나려면
   CP 를 참조하는 이미터/오퍼레이터가 **CP 프레임**을 받아야 한다.
   또 `ParticleSystem.swift:2579`(자식 CP 를 부모 CP 로 갈아끼우는 곳)은 위치만 복사하므로
   회전도 같이 복사해야 한다 — 소스 주석이 이미 "실물은 매 프레임 4×4 를 합성한다" 고 적어 둔 그 지점이다.

**[미해결]** *어느* 이미터/오퍼레이터가 CP 회전을 실제로 읽는지는 확정하지 못했다.
런타임 CP 레코드에 4×4 가 만들어진다는 것까지는 확정했지만(§6.2),
`[sys+0x400][i]+0x80` 을 읽는 소비자(이미터 방향 기저 · `directiontocontrolpoint` 등)를
바이너리에서 특정하지 못했다. 6번 항목의 착지 범위는 그 조사 뒤에 정해야 한다.

---

## 7. `variants`

`variants` 는 **`scene.json` 의 키가 아니다.** 동봉 코퍼스 전수에서 `variants` 는
`preset.json` 82개 중 75개의 최상위 키로만 나타난다(`scene.json` 도달 0).

`wallpaper64.exe` 에는 `variants` · `droplistOptions` · `droplistVisible` 문자열이
**ASCII·UTF-16LE 어느 쪽으로도 0바이트** 존재하지 않는다. → **엔진은 `preset.json` 을 읽지 않는다.**
읽는 것은 에디터다(`ui/dist/scripts/scripts.js`, `variants` 3회).

에디터 규약(같은 파일의 에셋 브라우저 코드):

```js
var e = t.variants, i = t.options && t.options.droplistOptions;
for (var n = 0; n < i.length; ++n) {
    var r = i[n];
    if (angular.isNumber(r.value) && r.value < e.length) {
        var o = e[r.value]; o.name = r.label; o.droplistIndex = r.value;
    }
}
```
`options.droplistOptions[n] = {label, value}` 가 **드롭다운 항목** → `variants[value]` 를 가리키고
그 `label` 이 표시명이 된다. 사용자가 항목을 고르면 그 variant 의
`objects[]` 가 씬에 삽입되고 `dependencies[]` 가 프로젝트에 복사된다.

동봉 `preset.json` 스키마 전수:

| 위치 | 키 | 파일/원소 수 |
|---|---|---:|
| 최상위 | `description` 82 · `group` 82 · `name` 81 · `tag` 80 · `options` 75 · `variants` 75 · `objects` 7 · `dependencies` 7 · `preview` 5 · `scene` 2 · `DISABLED_name` 1 | 82 파일 |
| `options` | `droplistVisible` 75 · `droplistOptions` 75 | |
| `variants[]` | `preview` 329 · `objects` 329 · `dependencies` 326 | 329 variant |
| `variants[].objects[]` | `name` 329 · `angles` 317 · `origin` 317 · `scale` 317 · `particle` 314 · `castshadow` 12 · `effects` 12 · `shape` 12 · **`instanceoverride` 10** · `alpha`/`anchor`/`backgroundcolor`/`color`/`copybackground`/`font`/`horizontalalign`/`locktransforms`/`opaquebackground`/`parallaxDepth`/`perspective`/`pointsize`/`size`/`solid`/`text`/`verticalalign`/`visible` 각 3 · `colorBlendMode` 1 | 329 오브젝트 |

> **`variants[].objects[].instanceoverride` 의 의미**: 씬 오브젝트의 그것과 **같은 스키마**이고,
> 무엇이 언제 어느 변형을 고르느냐는 **에디터의 드롭다운**이다 — 런타임이 아니다.
> 사용자가 프리셋 변형을 고르면 그 오브젝트가 `instanceoverride` 를 **그대로 달고**
> `scene.json` `objects[]` 에 기록되고, 그때부터는 §5 의 경로를 탄다.
> `variants[].objects[]` 에 `id`/`parent` 가 하나도 없는 것이 그 방증이다 — 삽입 시 에디터가 채운다.

---

## 8. `visible` / 조건부 표시

### 8.1 저장 위치

`visible` 은 **불리언이며 플래그 워드의 bit0** 다.
게터 `0x1401e1c90`: `movzx ecx,[rax+rcx]` / `and cl,1` — `[obj+0x120]` bit0.
타입별로 각각 등록된다(멤버 오프셋이 타입마다 다르다):
이미지 `+0x120`(`0x1401ee8e1`) · 라이트 `+0x120`(`0x14025e598`) · 모델 `+0x120`(`0x140227530`) ·
카메라 `+0x120`(`0x1401f3517`) · 파티클 `+0x120`(`0x14024cbbd`) · 이펙트 `+0x118`(`0x1401efd60`) ·
애니메이션 레이어 `+0xd0`(`0x14026ca3e`).

### 8.2 불리언 vs 스크립트 — 둘 다이며, 판정 순서가 있다

bool 주입기 `0x1401e1a90` 의 흐름(다른 타입 주입기도 동형):

```
if (json.tag == 5 /*boolean*/) { bit = asBool(json); }          ; 0x1401e1a9d / 0x1401e1abc
if (ctx.bindingEnabled /*[rbx+0x10]*/) {
    registerBinding(ctx, desc, json);                            ; 0x140176f70 → 0x1401a4db0
    if (json.tag == 7 /*object*/) {
        v = json.find("value");                                  ; 0x140087490
        if (v is boolean) bit = asBool(v);
    }
}
```

> **판정 순서.** ① 평문 불리언이면 그 값. ② 객체면 `value` 가 **초기 상태**를 정하고,
> 같은 객체의 `user`/`script`/`animation`/`condition` 이 **런타임 바인딩**으로 등록되어
> 그 뒤 프레임부터 값을 덮는다. 스크립트가 있어도 `value` 는 첫 프레임 전 상태로 쓰인다.
> 스크립트 표현식 문자열은 `script` 키이고, 그 언어·API 는 `docs/re/scene-script-api.md` 의 대상과 같다
> (`scriptproperties` 로 사용자 오버라이드가 붙는 것도 동일).

동봉 코퍼스 `visible` 형태 도수(294 오브젝트 기준):

| 형태 | 건수 |
|---|---:|
| 키 부재(= 기본 true) | 181 |
| `true` | 75 |
| `false` | 29 |
| `{user, value}` | 8 |
| `{script, value}` | 1 |

`{script, value}` 는 `assets/scenes/particleeditor/scene.json` 1건뿐이다.
Waple(`SceneDocument.parse` 본문 `:1509`-`1513`)은 bool · `{value}` · `{script}` · `{scriptproperties}` 를
전부 처리하므로 이 스키마와 일치한다. **`condition`/`animation` 바인딩은 `visible` 경로에서
Waple 이 안 읽지만 동봉 도달 0** 이다.

---

## 9. 레이어 정렬 **[실측 확정]**

### 9.1 정렬 키

`sortorder` — 오브젝트 베이스의 **int 프로퍼티, 멤버 `+0x124`, 등록 `0x1401e090a`, 기본 0**(`0x1401ddc7c`).
`objects[]` 의 JSON 키로도 그대로 쓸 수 있다(디스크립터이므로).

### 9.2 게이트와 비교자

드로우 리스트 빌더 `0x14018aac0`–`0x14018b22c`:

```
r8d = [scene+0xE0]                       ; 씬 플래그 워드            0x14018aad9
r8d &= 0x3000 ; cmp r8d, 0x2000 ; jne skip                            0x14018ab38–0x14018ab46
    → customsortorder(bit13) 켜짐 AND transparentsorting(bit12) 꺼짐일 때만
    리스트를 복사(0x14018ab57)하고 정렬한다.
    원소 ≤ 0x20 이면 0x14019fde0(비교자 0x140186980), 아니면 큰 정렬 경로(0x14018ab91).
...
eax = [scene+0xE0] ; eax &= 0x1008 ; cmp eax, 0x1000                  0x14018ac91–0x14018aca5
    → transparentsorting(bit12) 켜짐 AND ortho(bit3) 꺼짐(=원근)일 때만
    깊이 정렬/FNV 버킷팅 경로.
```

비교자 `0x140186980`:

```
mov  eax, [rdx + 0x124]      ; b->sortorder
cmp  [rcx + 0x124], eax      ; a->sortorder
setl al                      ; 부호 있는 <
ret
```
→ **`sortorder` 오름차순, signed.**

### 9.3 플래그 비트

| 키 | 비트 | 게터 | 등록 |
|---|---:|---|---|
| ortho(정사영) | `[scene+0xE0]` bit3 | — | `general.orthogonalprojection` 존재 여부 |
| `spritesheetrefreshsync` | bit6 | — | `0x140187674` |
| `transparentsorting` | **bit12** | `0x14019c3d0` (`shr edx,0xc; and dl,1`) | `0x14019ad55` |
| `customsortorder` | **bit13** | `0x14019c600` (`shr edx,0xd; and dl,1`) | `0x14019adfd` |

생성자가 워드를 `0x26` 으로 깐다(`0x140186d1f`) → 둘 다 기본 **false**.

### 9.4 결론과 코퍼스 도달

> * 기본(두 비트 다 0) = **`objects[]` 배열 순서** 그대로. 정렬 자체를 안 탄다.
> * `customsortorder: true` (그리고 `transparentsorting` 꺼짐) → `sortorder` 오름차순.
> * `transparentsorting: true` + **원근** 씬 → 깊이 정렬 경로. 정사영 씬에서는 켜져 있어도 무시.
> * 두 비트가 동시에 서면 `and 0x3000; cmp 0x2000` 이 실패하므로 `sortorder` 정렬을 건너뛴다
>   — **transparentsorting 이 이긴다**. 단 그 씬이 정사영이면 깊이 정렬 경로도 안 타므로
>   결과는 배열 순서다.
> * `objects[].depth` 는 정렬과 무관하다 — 엔진에 그 문자열이 없다(§9.5).

동봉 도달:

| 키 | 파일 수 |
|---|---:|
| `general.customsortorder` | **0** |
| `general.transparentsorting` | 2 (`assets/scenes/modeleditor` · `assets/scenes/particleeditor3dscale`, 둘 다 `true`, 둘 다 non-preview) |
| `objects[].sortorder` | **0** |
| `objects[].depth` | 48 파일 / 52 오브젝트 (전건 preview, 값 `1` ×51 · `-1.84` ×1) |

즉 **동봉 코퍼스에서 정렬 경로가 활성화되는 씬은 없다** — 전부 배열 순서다.

### 9.5 `depth` 가 엔진 키가 아니라는 증거

`wallpaper64.exe` 안의 `"depth\0"` 는 **2건뿐이고 둘 다 오류 메시지의 꼬리**다:
`0x14047a275` = `"#json: unsupported recursion depth"`,
`0x14047f00d` = `"#cbor: unsupported recursion depth"`.
두 주소 모두 rip-상대 xref 도 없고, **절대 8바이트 포인터도 disp32-RVA 참조도 0건**이다
(전-이미지 바이트 스캔). UTF-16LE `"depth"` 도 0건.
`locktransforms` · `particlesrc` · `variants` · `droplistOptions` 는 아예 **0바이트** 존재한다.

---

## 10. `effects[]` 부착

파서 `0x1401e6f50`–`0x1401e716c`:

1. 진입 시 `[obj+0x328] = 1`(재진입 가드), `0x1401de470` 로 부모/어태치먼트를 먼저 확정.
2. **기존 이펙트 리스트를 전부 파괴하고 비운다**(`0x1401e6fa9`–`0x1401e6fef`) — 즉 `effects` 는
   누적이 아니라 **전체 교체**다.
3. `effects` 노드를 얻고(`0x1401e7004`) **배열 순서대로** 순회한다.
4. 각 원소에서 `file` 을 읽어(`0x1401e7083`) **문자열일 때만**(`cmp byte [rax+8],4` @`0x1401e7093`)
   `0x1401e7170(this, filePath, index=-1, node)` 로 **뒤에 덧붙인다**.
   `file` 이 문자열이 아니면 그 원소는 **조용히 건너뛴다** → 뒤 원소가 한 칸 당겨진다.
5. 종료 시 `[obj+0x328] = 0` 후 vtbl `+0x110` 으로 tail-jump(리컴파일/재바인드).

패스 파서 `0x1401e7170`–`0x1401e8a9d` 가 읽는 키(문자열 참조 전수):
`passes` · `material` · `combos` · `conditions` · `fbos` · `name` · `index` · `format` ·
`width` · `height` · `scale` · `source` · `target` · `compose` · `bind` · `copy` · `swap` ·
`clear` · `command` · `action` · `functions` · `uvs` · `fit` · `repeat` · `unique` ·
`rgb_backbuffer` · `rgba_backbuffer`.

**`visible` 게이트와의 상호작용.** `0x1401e6f50` 에는 `visible` 검사가 **없다**.
이펙트의 `visible` 은 이펙트 자신의 프로퍼티(`0x1401efd60`, `[effect+0x118]` bit0)이고
그 게이트는 **렌더 시점**에 걸린다. 즉 WE 는 `visible:false` 인 이펙트도 **리스트에 붙여 두고**
드로우만 건너뛴다 — 그래서 스크립트/사용자 토글이 나중에 켜면 즉시 살아난다.

동봉 도달: `effects` 를 가진 오브젝트 103개(이미지 100 · shape 3), 배열 길이 분포
`1`×94 · `2`×5 · `3`×3 · `4`×1.

**[Waple 갭]** `SceneDocument.parseEffects`(`:2893`, 드롭 `:2912`)는 `visible:false` 이고 스크립트가 없으면
그 이펙트를 **파스 단계에서 드롭**한다. 결과 렌더는 대개 같지만,
`{user, value:false}` 로 꺼진 이펙트를 유저 프로퍼티로 다시 켤 때 **remount 없이는 살아나지 않는다**
(Waple 은 유저 프로퍼티 변경 시 전체 재파스를 하므로 현재는 무회귀 — 그러나 규약은 어긋난다).
또 Waple 은 `for case let e as [String: Any]` 로 **비-객체 원소를 스킵**해 인덱스를 당기는데,
WE 도 `file` 이 문자열이 아니면 스킵하므로 이 점은 우연히 같다.

---

## 11. 동봉 도달 실측

### 11.1 오브젝트 수 분포

| | 값 |
|---|---|
| 씬 문서 | 186 |
| `objects[]` 원소 합 | 294 |
| 씬당 최소 / 중앙 / 최대 | 0 / 1 / **36** |
| `objects[]` 가 빈 씬 | 2 — `assets/scenes/particleeditor` · `assets/scenes/particleeditor3dscale` |
| 최대 씬 | `projects/defaultprojects/dino_run/scene.json` (36) |
| 상위 5 | dino_run 36 · razer_bedroom 18 · dna_fragment 6 · neon_sunset 5 · shimmering_particles 5 |

동봉 코퍼스는 **씬당 1~2 오브젝트인 프리뷰가 압도적**이다(167/186). 실제 저작 씬은 19개뿐.

### 11.2 계층 깊이

| | 값 |
|---|---:|
| `parent` 키를 가진 오브젝트 | **2** (같은 파일 1개) |
| `parent` 를 가진 씬 | 1 — `assets/scenes/particleelementpreviews/inheritcontrolpointvelocity/scene.json` |
| 계층 깊이 히스토그램 | 깊이 1 = 292 · 깊이 2 = **2** |
| 최대 깊이 | **2** (`Solid` id=31 → parent 24) |
| dangling parent | 0 |
| 중복 `id` | 0 |
| self-parent / 순환 | 0 |

> **동봉 코퍼스로는 3단 이상 계층·부모 스케일 전파를 실측 대조할 수 없다.**
> §4.4 의 부모 합성 규약은 전적으로 바이너리 근거다.

### 11.3 `instanceoverride` 사용

`scene.json` 기준:

| | preview | non-preview |
|---|---:|---:|
| `instanceoverride` 를 가진 씬 | 56 | **2** |
| `instanceoverride` 를 가진 오브젝트 | 56 | 5 |

동봉 트리 전체(= `scene.json` + `preset.json` 의 `variants[].objects[]`) 기준 키별 파일 수:

| io 키 | preview | non-preview | 합 |
|---|---:|---:|---:|
| `controlpoint1` | 35 | 1 | 36 |
| `id` | 30 | 1 | 31 |
| `controlpoint2` | 23 | 1 | 24 |
| `size` | 21 | 1 | 22 |
| **`controlpointangle1`** | 9 | **2** | **11** |
| `count` | 9 | 1 | 10 |
| `alpha` | 3 | 3 | 6 |
| `speed` | 6 | 0 | 6 |
| `rate` | 5 | 0 | 5 |
| `lifetime` | 3 | 0 | 3 |
| `colorn` | 3 | 0 | 3 |
| `brightness` | 2 | 1 | 3 |
| **`controlpointangle2`** | 2 | **1** | **3** |

`controlpointangle*` 의 non-preview 건은 **전부 `preset.json` 안**이다
(`assets/presets/water/preset.json` · `assets/presets/magic/preset.json`).
**`scene.json` 만 보면 non-preview 도달은 0** 이다 —
`particleInstanceOverride` 주석(`SceneDocument.swift:2849` 인근)의 "둘 다 preview 씬이라 non-preview 도달은 0" 은
`scene.json` 범위 안에서는 맞고, 프리셋 템플릿까지 세면 2건이다.

관측된 `controlpointangle*` 값 전수:

| 값 | 건수 | 해석 |
|---|---:|---|
| `"0.00000 -0.00000 0.00000"` | 4 | 영각 |
| `"0.00000 0.00000 -0.52360"` / `"0.00000 0.00000 0.52360"` | 3 / 3 | **∓π/6 = ∓30°** (Z축) |
| `{animation:{c0,c1,c2,…}}` | 4 | 키프레임 바인딩(`value` 2.4783676 = 142.0°) |

### 11.4 기타

| 항목 | 값 |
|---|---|
| `effects[]` 길이 | 1:94 · 2:5 · 3:3 · 4:1 |
| `visible` 형태 | §8.2 표 |
| `angles` 성분 수 | 전건 3 |
| `size` 성분 수 | 전건 2 |
| `parallaxDepth` 값 | `"1.000 1.000"` 93 · `"1.00000 1.00000"` 33 · `"0.00000 0.00000"` 5 |
| `colorBlendMode` | `0`×59 · `11`×5 · `12`×1 |
| `shape` | 전건 `"quad"` |
| `alignment` | 전건 `"center"` |

---

## 12. Waple 갭 — 파일:줄

| # | 갭 | Waple 위치 | WE 근거 | 동봉 도달 |
|---|---|---|---|---|
| 1 | `instanceoverride.controlpointangle0..7` 미파스 | `SceneDocument.particleInstanceOverride:2872` (루프에 없음) · `ParticleSystem.ParticleInstanceOverride:1277` (필드 없음) | 디스크립터 §5.2 · 소비 §6.2 | scene 6 · preset 5 |
| 2 | 인스턴스 CP 오버라이드에 **flags 게이트 없음** | `ParticleSystem.swift:2563` | `test [cp+0xC0], 0x10005` @`0x14022bf26` | 저작 flags 로 35원소 + 엔진 설정 bit16 |
| 3 | 정의 `controlpoint[].angles` 미파스 | `ParticleSystem.swift:2555` | 파서 `0x1401d06ce` → `+0xb8+32i` | 0건(그러나 스키마 정본) |
| 4 | 자식 CP 부착이 **위치만** 복사 | `ParticleSystem.swift:2579` | 실물은 4×4 전체 | — |
| 5 | `text.spacing` 을 스칼라로 파스 | `Sources/WapleCore/SceneDocument.swift:2197` (`parseText`) — 이미지 레이어도 `:1858` | 디스크립터 타입 **1 = vec2**, `+0x4f8`, 등록 `0x1402594f4` | 동봉 0 / 워크샵 171 |
| 6 | `sound.muteineditor` 미파스 | `parseSound` (`Sources/WapleCore/SceneDocument.swift:1910`부터) | 디스크립터 `+0x310` bit, 등록 `0x1401f75e0` | 2 오브젝트 |
| 7 | `objects[].locktransforms` 를 파스해 보존(엔진엔 없는 키) | `Sources/WapleCore/SceneDocument.swift:1859`·`2121`·`2198`·`2804` | 바이너리에 문자열 0바이트 | 53 오브젝트 |
| 8 | `effects[].visible:false` 를 파스에서 드롭 | `Sources/WapleCore/SceneDocument.swift:2912` (`parseEffects` `:2893`) | 엔진은 붙이고 렌더에서 게이트(§10) | — |
| 9 | `angles` 축 순서·단위에 바이너리 근거가 없었다 | `Sources/WapleCore/SceneDocument.swift:1530`·`2160` 및 렌더러 | §4.2 | 29개 비영 성분 |
| 10 | 부모 스케일→자식 회전 전단 미반영 | `composeParentTransforms` (`Sources/WapleCore/SceneDocument.swift:2382`) 는 2D 스칼라 근사 | §4.4 | 동봉 도달 0(깊이 ≤ 2) |
| 11 | `sortorder` 미파스 | `SceneDocument.parse` 전역 | 디스크립터 `+0x124`, 비교자 `0x140186980` | 0 (그러나 워크샵 씬은 쓸 수 있다) |

**갭이 아닌 것**(확인해 둔다): `depth` · `particlesrc` · `variants` — WE 도 안 읽으므로
Waple 이 안 읽는 것이 맞다. `instanceoverride.id` 무시도 맞다(§5.3).

---

## 12.1 [2026-08-21 닫음] 트랜스폼 성분 소실 3건 + 텍스트 `parallaxDepth`

이 절은 §12 의 갭 표와 같은 축이지만 **이번 라운드에서 파스까지 닫은 것**만 모은다.
넷 다 근거를 이 세션에서 직접 다시 떴다(브리프 함정 16 — 인계 문서의 VA 를 베끼지 않았다).

### 12.1.1 공통 오브젝트 디스크립터 표의 타입 태그 — 직접 재확인

등록부는 `0x1401e0530`–`0x1401e1389`(`merged()`) 한 함수이고, 한 항목은
`[rbx+0x30]`=**타입 태그** · `[rbx+0x34]`=멤버 오프셋 · `[rbx+0x68]`=이름 순으로 굽힌다.
**이름 `lea` 는 그 항목의 태그 스토어보다 앞에 나오고, 다음 항목의 이름 `lea` 가 현재 항목의
태그 스토어 사이에 끼어 들어온다**(예: `0x1401e129a` 의 `"disablepropagation"` 이
`"solid"` 의 오프셋 스토어와 태그 스토어 사이에 있다). 순진하게 덤프하면 한 칸 밀린다.

| 키 | 이름 `lea` | 멤버 | 태그 스토어 | 태그 | 성분 |
|---|---|---|---|---:|---:|
| `origin` | `0x1401e05d2` | `+0x128` (`0x1401e05f8`) | `0x1401e0629` | 2 | 3 |
| `scale` | `0x1401e06a3` | `+0x134` (`0x1401e06c6`) | `0x1401e06ea` | 2 | 3 |
| `angles` | `0x1401e0759` | `+0x140` (`0x1401e0795`) | `0x1401e07ae` | 2 | 3 |
| `parallaxDepth` | `0x1401e082f` | `+0x170` (`0x1401e0848`) | `0x1401e085a` | **1** | **2** |
| `name` | `0x1401e11d0` | `+0x1d8` (`0x1401e11ed`) | `0x1401e1203` | 5 | (string) |
| `solid` / `disablepropagation` | `0x1401e1272` / `0x1401e131a` | `+0x120` bit | `0x1401e12a8` / `0x1401e1350` | 6 | (bit) |

타입 태그 ↔ 성분 수 사전(등록기 `0x140176742`–`0x140176771`, `docs/re/property-animation.md` §7):
**1→2 · 2→3 · 3→4 · 4→1**. 즉 `origin`/`scale`/`angles` 는 vec3, `parallaxDepth` 는 vec2 다.
씬스크립트 d.ts 도 같은 말을 한다 — `ILayer.origin/angles/scale: Vec3`(:2028·:2033),
`ILayer.parallaxDepth: Vec2`(:2039), 그리고 `ILayer extends ITextLayer`(:2020)이므로
**텍스트 오브젝트도 같은 표면**이다.

### 12.1.2 닫은 것

| 자리 | 종전 | 지금 | 도달(동봉 172씬 / 설치본 186씬) |
|---|---|---|---|
| `SceneLayer.scale` z | 버림 | `SceneLayer.scaleZ`(기본 1) | **7 / 24** (이미지 4 / 21 + shape 쿼드 3 / 3) |
| `SceneTextLayer.scale` z | 버림 | `SceneTextLayer.scaleZ` | 텍스트 **3 / 5** |
| `angles` x·y | 버림 | `angleX`/`angleY`(기본 0) | 레이어·텍스트 **0 / 0** |
| `SceneTextLayer.parallaxDepth` | 필드 없음 | `parallaxDepth`(기본 (1,1)) | 텍스트 **3 / 3**(전건 `"1.000 1.000"` = 기본값) |

**인계 수치 정정 2건.**
① "동봉 71 / 설치본 92 오브젝트가 `s s s` 형태" 는 **텍스트를 뺀** z≠1 오브젝트 수다
(텍스트를 넣으면 74 / 97). 그리고 그중 실제로 값을 잃던 것은 `SceneLayer`
**7 / 24**(이미지 4 / 21 + shape 쿼드 3 / 3)와 `SceneTextLayer` **3 / 5** 뿐이다 — 파티클(`scale3D`) · 모델
(`SceneObject3D.scale`) · 그룹 노드(`SceneNode3D.scale`)는 이미 `Vec3` 이라 소실이 없었다.
(shape 쿼드는 동봉·설치본 각 3개뿐이고 **전건이 3성분 `scale`, z≠1** 이다 — lightshafts 프리뷰
1.20791 / 2.03800 / 2.09076.)
② "전건 균일값이라 2D 렌더는 무영향" 의 **전건 균일값은 사실이 아니다**.
`presets/rain/previewperspective` 파티클 `"0.500 0.500 0.100"`,
설치본 `projects/defaultprojects/razer_bedroom` 모델 `"1.65900 1.48800 3.95800"` ·
`"220.10500 123.08000 146.04300"`, `dino_run` 이미지 `"10.82100 0.50000 0.50000"` 처럼
z 가 x·y 와 다른 저작이 실재한다. **결론(2D 렌더 무영향)은 맞지만 근거가 틀렸다** —
무영향인 이유는 "균일값이라서" 가 아니라 **2D 정사영 경로가 z 스케일을 애초에 안 읽어서**다.
`angles` x·y 도 마찬가지다: 두 코퍼스에서 x 또는 y 가 0 이 아닌 오브젝트는 1 / 7 건인데
**전건이 light(1/1) · model(0/3) · particle(0/3)** 이라 이미 `Vec3` 을 들고 있던 타입이고,
`SceneLayer`/`SceneTextLayer` 도달은 **0 / 0** 이다.

### 12.1.3 왜 `Vec3` 으로 넓히지 않고 별 필드인가

`scale`/`angleZ` 는 `composeParentTransforms` · `composeLayerTransforms3D` ·
`composeTextParentTransforms` · `composeLightParentTransforms` 와 렌더 인코더까지
`Vec2`/`Float` 로 흐르는 소비처 다수다. 타입을 넓히면 **`WapleRender` 소유 파일이 함께
움직인다**(이 세션에 `SceneRenderer.swift` 는 다른 에이전트가 동시 편집 중이다).
`SceneLayer.originZ`(2026 이전 라운드)가 이미 같은 문제를 **별 필드**로 풀어 두었고,
그 필드도 부모 체인 합성에서 **월드로 굽히지 않는다**(합성 4함수가 `origin`/`scale`/`angleZ`
만 되쓴다). 새 세 필드도 같은 규약 — **로컬 값 그대로 남는다.**
소비가 붙을 때 합성 규약(부모 z 스케일 누적 여부)을 함께 정하면 된다.

### 12.1.4 넘길 것 — 텍스트 `parallaxDepth` **렌더** 소비 (`Sources/WapleRender/` 소유)

씬스크립트 표면은 이미 닫혀 있다 — 같은 세션의 `SceneRenderer.swift` 클러스터가
`SceneScriptLayerDescriptor` 에 `d.parallaxDepth = SIMD2(text.parallaxDepth.x, text.parallaxDepth.y)`
(`SceneRenderer.swift:313` 인근)와 `scale: SIMD3(…, text.scaleZ)` ·
`angles: SIMD3(text.angleX, text.angleY, text.angleZ)` 를 이미 배선했다.
**남은 것은 그림 쪽 하나뿐이다.**

`SceneRendererFrameEncoder.swift:1668`(`encodeText`):

```swift
-        var depth = SIMD2<Float>(1, 1)
+        // W-V②: 텍스트도 공통 오브젝트 디스크립터의 `parallaxDepth`(`+0x170`, 태그 1 = vec2,
+        // 등록 `0x1401e082f`)를 갖는다 — 이미지(`:550`/`:1438`)·파티클(`:1734`/`:1785`)과 같은
+        // 규약으로 `v_main` buffer 2 에 싣는다. 동봉·설치본 텍스트는 전건 `"1.000 1.000"` 이라
+        // 가중이 항등이고, `cameraparallax` 미보유 씬은 `camOffset == 0` 이라 어차피 비트동일이다.
+        var depth = SIMD2<Float>(t.def.parallaxDepth.x, t.def.parallaxDepth.y)
```

`v_main` 은 이미 `float2 p = (v.xy + cameraOffset * parallaxDepth + shakeOffset) * aspectScale`
(`QuadShaders.swift:17`)라 셰이더는 손댈 필요가 없다. 무회귀 근거: 두 재현 코퍼스의 텍스트
`parallaxDepth` 는 **동봉 3 / 설치본 3 건이고 전건 `"1.000 1.000"`** 이며, 그 세 씬
(`presets/clock/preview3dclock` · `presets/clock/previewclock` · `presets/countdown/previewcountdown`)
은 `cameraparallax` 를 켜지 않는다. 값이 갈리는 것은 워크샵뿐이다
(1,597 중 956 저작 · `cameraparallax` 활성 56씬 안에서 482 실효 · 그중 269 이 0 · 184 가 음수).

호버 히트테스트(`SceneRenderer.hoverParallaxShift`, `:553`)도 이미지 레이어만 시차 보정을
하고 텍스트는 대상 목록에 없다 — 텍스트에 포인터 스코프가 생기면 같이 봐야 한다. **[미해결]**

---

## 13. 배제한 가설

1. **"`objects[].angles` 는 도(度)다."** — 반증. 주입기 `0x1401df2f0` → `setAngles` `0x1401dd630`
   경로에 `π/180` 상수가 없고, 코퍼스 최대 절댓값이 3.142 로 π 를 넘지 않으며,
   0.05236(3°)·0.13963(8°) 같은 라디안 변환 잔여값이 관측된다.
2. **"`.mdl` 키처럼 `angles` 도 파일 순서가 `(Z,Y,X)` 다."** — 반증.
   `setAngles` 가 `[rdx+0]`→x, `[rdx+4]`→y, `[rdx+8]`→z 로 쓰고 행렬이 `Rz(z)Ry(y)Rx(x)` 로 맞는다.
   `.mdl` 의 `(Z,Y,X)` 는 **파일 바이트 순서**이지 회전 합성 순서가 아니다
   (`docs/re/skeleton-animation.md` §2.1 과 모순 없음).
3. **"`objects[].depth` 가 2D z 정렬 키다."** — 반증. 엔진에 `"depth"` 키 문자열이 없다(§9.5).
   정렬 키는 `sortorder` 이고 그 비교자는 `0x140186980` 이다.
4. **"`controlpointangle*` 은 CP 위치를 회전시킨다(위치에 곱해진다)."** — 반증.
   `0x14022bf3d`–`0x14022c0b6` 에서 회전 3행(`+0x80`/`+0x90`/`+0xa0`)과 위치 행(`+0xb0`)이
   **서로 다른 소스에서 독립적으로** 채워지고, 두 소스에 개별 FLT_MAX 센티널이 있다.
5. **"`instanceoverride` 는 다른 오브젝트를 `id` 로 참조한다."** — 반증.
   `remapvalue/scene.json` 에서 오브젝트 `id`=26, `instanceoverride.id`=27 이고
   27번 오브젝트는 존재하지 않는다. `0x1401a38f0` 은 그 id 를 **인스턴스 서브오브젝트에 부여**한다.
6. **"`variants` 를 엔진이 읽는다."** — 반증. 문자열 0바이트(ASCII·UTF-16 둘 다).
7. **"`transparentsorting` 과 `customsortorder` 는 같은 정렬 경로다."** — 반증.
   전자는 `and 0x1008 / cmp 0x1000`(원근 전용 깊이 정렬), 후자는 `and 0x3000 / cmp 0x2000`
   (`sortorder` 정렬)로 **서로 배타적**이다.
8. **"`instanceoverride` 의 미지 키(`id` 등)가 파스를 깨뜨린다."** — 반증.
   `0x1401730d0` 이 멤버 이름으로 디스크립터를 조회하므로 모르는 이름은 무해하게 무시된다.

---

## 14. 확정하지 못한 것

* **[미해결] CP 회전의 최종 소비자.** 런타임 CP 레코드(`[sys+0x400] + i·0xD0`)의 `+0x80` 4×4 가
  만들어지는 것까지는 확정했지만(§6.2), 그 회전을 읽는 이미터/오퍼레이터를 특정하지 못했다.
  `controlpointattract` 계열은 CP **위치**만 읽는 것으로 이미 문서화돼 있다
  (`docs/re/particle-operator-vm.md` 의 `opid 10 controlpointattract` 절). 회전을 쓰는 경로가
  이미터의 방향 기저인지,
  `directiontocontrolpoint` remap 인지 확정 못 했다.
* **[해소 2026-08-21] `objects[].config` 서브노드의 이름 해석.** 못 찾은 게 아니라 **없었다.**
  `0x1401fd330` 은 `"config"` 를 안 쓴다 — `"image"` 로 모델 파일을 로드하는 함수다.
  `passthrough` 판독(`0x1401fae95` → `[obj+0x304] |= 0x20`)은 그 **모델 파일**의 루트 키를
  읽는 것이다. `objects[].config` 는 엔진 리더 0 인 유령 키다(§2.1 정정 상자에 근거 전부).
* **[미해결] `sortorder` 정렬의 안정성.** 비교자는 확정했지만
  `0x14019fde0`(≤32 원소) / `0x14018ab91`(대형) 두 경로가 stable sort 인지 확인하지 않았다.
  동봉 도달이 0 이라 실측 대조도 불가능하다.
* **[해소 2026-08-21] `general` 디스크립터 전수 대조.** 개수는 **47**로 확정했다(§2.2 정정 상자 ·
  부록 A.2). 항목별 타입·오프셋·기본값 전수는 형제 문서
  [`scene-postprocessing.md`](scene-postprocessing.md) 가 독립적으로 47개 전건 대조해 두었으므로
  여기서 되풀이하지 않는다. 이 문서의 범위는 여전히 `objects[]` 라
  `general` 은 정렬 관련 4개(`transparentsorting`·`customsortorder`·ortho·`spritesheetrefreshsync`)만 다룬다.
* **동봉 코퍼스의 한계.** 계층 깊이 최대 2 · `parent` 2건 · `sortorder` 0건 · `customsortorder` 0건이라
  **계층 합성과 정렬은 실측 대조가 사실상 불가능하다.** §4.4 · §9 의 결론은 바이너리 단독 근거다.

---

## 부록 A. 재현 절차

```bash
# wpe.py(PE/.pdata 로더 + primary()/merged()) 와 vdis2.py(주석 붙은 capstone 덤프) 가 있는
# 분석용 스크래치패드. 세션마다 경로가 다르므로 각자 환경에 맞춰 둘 것.
S=<scratchpad>
WE=/home/user/Waple-wallpaper-source/wallpaper_engine
```

**A.1 오브젝트 키 전수**

```bash
python3 - <<'PY'
import json,os,collections
ROOT=os.environ.get("WE","/home/user/Waple-wallpaper-source/wallpaper_engine")
files=[os.path.join(dp,f) for dp,_,fn in os.walk(ROOT) for f in fn
       if f in ("scene.json","gifscene.json")]
prev=lambda p: any('preview' in s for s in p.replace(ROOT+'/','').split('/'))
kf=collections.Counter(); ko=collections.Counter()
for p in sorted(files):
    d=json.loads(open(p,'rb').read().decode('utf-8-sig'))
    seen=set()
    for o in d.get("objects") or []:
        for k in o: ko[k]+=1; seen.add(k)
    for k in seen: kf[k]+=1
print(len(files), len(ko))
for k,v in ko.most_common(): print("%-24s F=%-4d O=%d"%(k,kf[k],v))
PY
```
→ `186 65` 가 먼저 찍히고 키별 도수가 따른다. §2 의 표와 일치해야 한다.

**A.2 디스크립터 등록부 덤프**

규약: **이름 문자열 대입 호출**을 항목 경계로 잡고, 그 직전 마지막 `lea rdx,[rip+…]` 를
이름으로, 그 뒤의 `[rbx+0x30]`(타입) · `[rbx+0x34]`(멤버 오프셋) ·
`[rbx+0x38/0x48/0x50/0x58]`(접근자)을 필드로 읽는다.
**`mov rbx,[rbp-0x30]` 을 경계로 삼으면 안 된다** — §5.2 에서 설명한 이름 `lea` 선-적재 때문에
한 칸 밀린다.

> **[2026-08-21 정정 — 이전 판이 씬 `general` 을 5개 놓친 원인]**
> 이름 대입 오버로드는 **둘**이다: `0x14000f880` 과 `0x14000ddd0`. 이전 판 스크립트는 앞의
> 하나만 `ASSIGN` 으로 잡아서, `0x14000ddd0` 을 쓰는 항목을 **경계로 인식하지 못하고 직전
> 항목에 흡수**시켰다. 그 결과 (a) 항목 수가 5 모자라고(42 vs 47), (b) 마지막으로 남은 항목
> `cameraparallaxmouseinfluence` 의 멤버 오프셋이 뒤 항목들의 스토어에 오염돼
> `+0x33c` 대신 `+0x400` 으로 찍혔다. 아래 판은 두 오버로드를 다 잡고, 각 필드는 **블록 안
> 첫 스토어만** 채택한다(오염 방지). **개수 판정은 등록 호출 `0x14015a000` 을 세는 쪽이
> 더 튼튼하다** — 이름 대입 오버로드가 또 늘어도 흔들리지 않고, 프로퍼티만 세므로
> "프로퍼티 N + 메서드 M" 의 N 을 직접 준다.

```python
import sys, re, collections; sys.path.insert(0, "<scratchpad>")
from wpe import pe, DATA, merged
import capstone
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
ASSIGN = (0x14000f880, 0x14000ddd0)   # std::string::assign 오버로드 둘 다
REG    = 0x14015a000                  # 프로퍼티 등록(= table[key] 슬롯 생성)

def strat(va, n=64):
    o = pe.va2off(va)
    if o is None: return None
    z = DATA[o:o+n].split(b"\x00")[0]
    return z.decode() if 1 <= len(z) <= 48 and all(0x20 <= c < 0x7f for c in z) else None

def dump(fva):
    lo, hi = merged(fva)[:2]
    code = DATA[pe.va2off(lo):pe.va2off(lo)+(hi-lo)]
    cur = None; lastlea = None; regs = {}; out = []; nreg = 0
    for ins in md.disasm(code, lo):
        m = re.match(r"(\w+), \[rip ([+-]) (0x[0-9a-f]+)\]$", ins.op_str)
        if ins.mnemonic == "lea" and m:
            t = ins.address + ins.size + int(m.group(3), 16) * (1 if m.group(2) == "+" else -1)
            regs[m.group(1)] = t
            if m.group(1) == "rdx" and strat(t): lastlea = strat(t)
        if ins.mnemonic == "call" and ins.op_str.startswith("0x"):
            t = int(ins.op_str, 16)
            if t in ASSIGN:
                if cur: out.append(cur)
                cur = {"name": lastlea, "at": hex(ins.address)}; continue
            if t == REG: nreg += 1
        if cur is None: continue
        m = re.match(r"dword ptr \[rbx \+ (0x[0-9a-f]+)\], (0x[0-9a-f]+|\d+)$", ins.op_str)
        if ins.mnemonic == "mov" and m and ("f%s" % m.group(1)) not in cur:
            cur["f%s" % m.group(1)] = int(m.group(2), 0)          # 블록 안 첫 스토어만
        m = re.match(r"qword ptr \[rbx \+ (0x[0-9a-f]+)\], (\w+)$", ins.op_str)
        if ins.mnemonic == "mov" and m and ("p%s" % m.group(1)) not in cur:
            cur["p%s" % m.group(1)] = hex(regs.get(m.group(2), 0))
    if cur: out.append(cur)
    print("  범위 %#x-%#x  항목 %d  프로퍼티(REG) %d" % (lo, hi, len(out), nreg))
    for e in out: print("   ", e)

for f in (0x14024d940, 0x1401e0530, 0x140199780, 0x1401ee520,
          0x140258ca0, 0x14025da80, 0x1401f7090, 0x140227470,
          0x1401f3460, 0x14024cb00, 0x1401efca0, 0x14026c980, 0x140211070):
    print("=====", hex(f)); dump(f)
```

기대 출력(항목 / REG):

| 등록부 | 항목 | REG(=프로퍼티) |
|---|---:|---:|
| `0x14024d940` instance | 24 | 24 |
| `0x1401e0530` IObject | 19 | 8 |
| `0x140199780` **general** | **47** | **47** |
| `0x1401ee520` image | 15 | 12 |
| `0x140258ca0` text | 29 | 29 |
| `0x14025da80` light | 18 | 18 |
| `0x1401f7090` sound | 13 | 9 |
| `0x140227470` model | 9 | 4 |
| `0x1401f3460` camera | 4 | 4 |
| `0x14024cb00` particle | 7 | 2 |
| `0x1401efca0` effect | 6 | 2 |
| `0x14026c980` anim layer | 18 | 11 |
| `0x140211070` image 스크립트확장 | 24 | 1 |

REG 열이 §2.2 표의 "프로퍼티 N" 과 **13개 등록부 전건 일치**한다 — 이게 이 규약이 맞다는
자체 검증이다.

**A.3 회전 규약 확인**

```bash
python3 $S/vdis2.py 0x1401df2f0 0x1401df430   # angles 주입기 — π/180 없음
python3 $S/vdis2.py 0x1401dd6d4 0x1401dd7a0   # setAngles 3×3 (9개 스토어)
python3 $S/vdis2.py 0x140215020 0x1402151a0   # 스켈레톤 문서와 교차확인 → cos=0x14041a2e0
python3 $S/vdis2.py 0x1401850a0 0x1401852f7   # 로컬 4×4 = S·R | T, 부모 합성
```

**A.4 CP 각도 소비 확인**

```bash
python3 $S/vdis2.py 0x14022bea0 0x14022c0d0   # FLT_MAX 센티널 · sin/cos · 4×4 · flags 게이트
python3 $S/vdis2.py 0x1401d0480 0x1401d0880   # 파티클 정의 controlpoint[] 파서
```

**A.5 문자열 부재 증명**

```bash
python3 - <<'PY'
import sys; sys.path.insert(0, "<scratchpad>")   # wpe.py 가 있는 곳
from wpe import DATA
for k in ("depth","locktransforms","particlesrc","sortorder","variants","droplistOptions"):
    print("%-18s ascii+NUL=%d raw=%d utf16le=%d"%(
        k, DATA.count(k.encode()+b'\0'), DATA.count(k.encode()),
        DATA.count(k.encode('utf-16-le'))))
PY
```
→ `locktransforms`/`particlesrc`/`variants`/`droplistOptions` 는 전부 0.
`depth` 는 `ascii+NUL=2` 지만 둘 다 `"…unsupported recursion depth"` 의 꼬리이고 xref 0.

**A.6 정렬 게이트/비교자**

```bash
python3 $S/vdis2.py 0x14018aac0 0x14018ab90   # and 0x3000/cmp 0x2000 게이트
python3 $S/vdis2.py 0x140186980 0x140186990   # 비교자: sortorder 오름차순
python3 $S/vdis2.py 0x14018ac60 0x14018acc0   # and 0x1008/cmp 0x1000 (transparentsorting)
```
