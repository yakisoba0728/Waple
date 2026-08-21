# 동봉 자산 키 커버리지 — 우리가 통째로 못 읽는 키

**측정일 2026-08-21 · WE 2.8.42 · `scripts/re/bundled_key_coverage.py`**

동봉 WE 자산 JSON **1,698개 전건**에서 키 경로를 뽑아, Waple 소스가 그 키 문자열을 읽는지
기계적으로 대조한 결과다. 목적은 하나 — **"우리가 통째로 못 읽고 버리는 키"의 완전한 목록**을
근거와 함께 얻는 것. 기억이나 감이 아니라 `자산에 있는 키 ∖ 소스에 있는 문자열` 로 계산했다.

```bash
python3 scripts/re/bundled_key_coverage.py                 # 요약(아래 표 그대로)
python3 scripts/re/bundled_key_coverage.py --by-leaf        # 키 이름 단위로 접어서
python3 scripts/re/bundled_key_coverage.py --json           # 기계 판독
python3 scripts/re/bundled_key_coverage.py --schema particle --status none
```

인자 없이 돌면 요약, `--json` 이면 `{summary, gaps, gaps_by_leaf}` 를 낸다. 표준 라이브러리만
쓰고 2초대에 끝난다. 판정 기준은 스크립트 docstring 에 전부 적혀 있다.

> **자산 개수 정정.** 과제 지시는 3,655개였지만 실측은 **1,698개**다. 동봉 트리 전체 파일은
> 2,940개고 그중 `.json` 이 1,698 · `.tex` 311 · `.tex-json` 298 · `.vert`/`.frag` 각 242 …
> 이다. 이 도구는 확장자가 정확히 `.json` 인 것만 본다(`.tex-json` 은 텍스처 빌드 사이드카라
> 런타임 스키마가 아니다). 동봉본은 WE 설치본 `assets/` 와 **바이트 동일**하다
> (`diff -rq` 무출력) — `--assets /path/to/wallpaper_engine/assets` 로 교차 검증하면 같은 수가 나온다.

---

## 1. 총계

| | |
| --- | --- |
| 자산 파일 | **1,698** (.json) |
| 대조 코퍼스 | 코드 429개(`Sources/`+`Tests/`) · 문서 235개(`docs/`·`spec/`·`scripts/`·루트 md) — WEAssets 와 이 도구 자신은 제외 |
| 키 이름(고유) | **320** |
| 키 경로(스키마별 합) | **848** |
| 파스됨 / 언급만 / 없음 | **701 / 103 / 44** |
| 관대 파스 필요 | 31건(줄 주석·트레일링 콤마) · 실패 0건 |

**구멍 총계: 키 경로 147개 = 키 이름 74개.**

> **안정된 값은 총계다.** 그 안의 `없음`/`언급만` 경계는 문서 코퍼스에 달려 있어, 누가
> 리포트에 그 키를 적기만 해도 `없음` → `언급만` 으로 옮겨간다. 실제로 이 라운드 중에
> 형제 문서 [`unimplemented-json-keys.md`](unimplemented-json-keys.md) 가 병행 작성되면서
> `arcamount`·`wraploop` 이 그렇게 이동했다(경로 51/96 → 44/103). **총계 147 은 그동안
> 한 번도 변하지 않았다** — 아래 순위표의 순서도 그대로다(정렬 키가 도달 수라서).
> 그러니 "무엇이 구멍인가" 는 총계로 읽고, `없음`/`언급만` 은 "누가 이미 적어 뒀는가" 로만 읽어라.

---

## 2. 판정 기준

### 2.1 스키마 — 파일명 우선, 그 다음 경로

동봉 자산은 최상위 디렉터리가 스키마를 말해 주지 않는다.
`presets/magic/previewtrinity/materials/presets/magic_trinity.json` 은 프리셋 폴더 안의
*머티리얼*이다. 그래서 아래 순서로 판정하고, **위에서 먼저 맞는 것이 이긴다**.

| # | 규칙 | 스키마 |
| --- | --- | --- |
| 1–6 | basename 이 `scene.json` / `project.json` / `effect.json` / `template.json` / `preset.json` / `config.json` | scene · project · effect · template · preset · config |
| 7–9 | 경로에 `/materials/` · `/models/` · `/particles/` 세그먼트 | material · model · particle |
| 10 | `zcompat/web/*.json` | zcompat-web |
| 11 | `shaders/declarations.json` | shaderdecl |
| 12 | 최상위가 `scenes/` (잔여) | scene — `scenes/gifs/gifscene.json` 1건. 파일명이 관례를 벗어나지만 내용은 씬 그래프고 WE `templates/gif` 프로젝트가 `file` 로 가리킨다 |
| 13 | 그 외 | misc — **현재 0건** |

`*.tex` 는 JSON 이 아니라 대상이 아니고 `*.tex-json` 도 제외한다.
`effect.json` 128건은 전건 `effects/**` 하위임을 확인했다.

### 2.2 키 경로 표기

`general.clampuvs` · `passes[].compose` · `objects[].effects[]` 꼴이다.
집계 단위는 **등장 파일 수**(한 파일에 100번 나와도 1).

**열린 사전은 `<*>` 로 접는다** — `constantshadervalues` · `combos` · `usershadervalues` ·
`general.properties` · `gizmos[].vars` · `condition`/`conditions[]`. 이 아래의 키 이름은
셰이더 유니폼명·콤보명·저작자 지정명이라 스키마가 아니다. 접지 않으면
`constantshadervalues` 하나로 키 경로가 135개 불어나 히스토그램이 무의미해진다.

### 2.3 3분류

키 이름을 `"` 로 감싼 리터럴(`"clampuvs"`)로 `grep -rF` 한다. WE 자산 파서는 전건
`obj["key"]` 첨자 방식이고 Codable/CodingKeys 를 쓰지 않으므로(`ProjectJSONParser` ·
`SceneDocument` · `ParticleSystem` 전부) 이 검색이 타당한 대리 지표다.

| 분류 | 뜻 |
| --- | --- |
| **없음** | 소스·테스트·문서 어디에도 그 리터럴이 없다 |
| **언급만** | 주석/문서/테스트에만 있다 — 파서 코드에는 없다 |
| **파스됨** | `Sources/` 의 **비주석 코드**에 있다 |

주석 판정은 파일 단위다. 문자열 리터럴 상태를 추적하며 `//` 와 `/* */` 를 걷어낸 "코드만"
텍스트를 만들고 그 안에 리터럴이 있어야 파스됨이다(`"http://…"` 오인 방지).

**코퍼스에서 두 가지를 반드시 뺐다.**

1. `Sources/WapleRender/Resources/WEAssets/` **자신.** 동봉 자산이 `Sources/` **안에** 있어서,
   빼지 않으면 모든 키가 자기 자신에 매칭돼 전건 "파스됨" 이 되는 무의미한 항등식이 된다.
2. **이 도구와 이 리포트**(`SELF_EXCLUDE`). 초안에서 실제로 밟았다 — 이 문서가
   디스어셈 인용문으로 `"nopadding"`·`"duration"`·`"delay"` 를 담고 있어서, 문서를 저장하는
   순간 그 키들이 `없음` → `언급만` 으로 옮겨갔다(없음 51 → 42). **구멍을 적은 문서가 그
   구멍을 메워서는 안 된다.**

### 2.4 문자열 보간으로 만드는 키

`SceneDocument` 는 번호 붙은 키를 루프로 읽는다:

```swift
if let v = vec3(io["controlpoint\(i)"]) { ov.controlPoints[i] = v }   // SceneDocument.swift:2327
```

이러면 `"controlpoint1"` 리터럴이 소스에 **한 번도 안 나온다**. 순진한 리터럴 검색은 동봉
34개 씬이 쓰는 이 키를 구멍으로 오판한다(초안에서 실제로 그랬다). 그래서 코드의
`"접두사\(…)"` 꼴 리터럴에서 접두사를 모아 두고, 키 이름이 그 접두사 + **숫자**로 끝나면
파스됨(보간)으로 친다.

숫자로 한정하는 것이 핵심이다 — `controlpoint` 접두사는 `controlpoint1` 을 잡지만
`controlpointangle1` 은 **안 잡는다**. 후자는 실제로 미구현이고
(`SceneDocument.swift:2297` 선언부 주석이 그렇게 적고 있다) 그 구멍이 접두사 일치에
먹혀 사라지면 안 된다.

### 2.5 반드시 알고 볼 두 가지 편향

**(a) 주입 ≠ 소비.** 리터럴이 코드에 있다고 그 키를 *읽는* 것은 아니다. 기본값 주입기가
그 이름을 **쓰는**(write) 자리일 수도 있다. `파스됨` 은 "읽는다"가 아니라 **"이 문자열이
파서 코드에 등장한다"** 로만 읽어야 한다.

**(b) 이름 충돌.** 대조는 키 **이름**으로 하는데 보고는 키 **경로**로 한다. `min` 은
`initializer[].min` 에서 읽지만 `emitter[].min` 은 안 읽을 수 있는데 둘 다 `파스됨` 으로
찍힌다. 표의 `~` 표시가 그런 행이다.

**즉 아래 구멍 목록은 실제 구멍의 하한이다.** 여기 오른 것은 확실한 구멍이고, `파스됨`
701개 안에도 구멍이 섞여 있다. 편향 방향이 안전한 쪽(과소 보고)이라 목록의 신뢰도는 높다.

---

## 3. 스키마별 키 개수

| 스키마 | 파일 | 키 경로 | 파스됨 | 언급만 | 없음 | 설명 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| material | 639 | 18 | 16 | 2 | 0 | 머티리얼 — `passes[]` 셰이더·블렌딩·텍스처 |
| particle | 289 | 157 | 146 | 3 | **8** | 파티클 — emitter/initializer/operator/renderer |
| scene | 172 | 311 | 257 | 30 | **24** | 씬 그래프 — camera·general·objects |
| project | 170 | 11 | 10 | 1 | 0 | 프로젝트 매니페스트 |
| effect | 128 | 49 | 41 | 8 | 0 | 이펙트 매니페스트 — passes/dependencies/gizmos |
| template | 124 | 2 | 2 | 0 | 0 | 에디터 신규-씬 템플릿 |
| model | 86 | 7 | 6 | 0 | **1** | 모델 래퍼 — material + 레이어 플래그 |
| preset | 82 | 129 | 107 | 11 | **11** | 프리셋 매니페스트 — `variants[].objects` |
| zcompat-web | 5 | 4 | 1 | 3 | 0 | 웹 월페이퍼 소스 패치 규칙 |
| config | 2 | 3 | 0 | 3 | 0 | zcompat 셰이더 대체 규칙 |
| shaderdecl | 1 | 157 | 115 | 42 | 0 | 에디터 셰이더 선언 카탈로그 |
| **합계** | **1,698** | **848** | **701** | **103** | **44** | |

읽는 법 세 가지:

- **material 639파일 / 키 경로 18개.** 스키마가 좁고 반복이 많다. 구멍 0.
- **shaderdecl 은 파일 1개인데 키 경로 157개.** 에디터 임포터용 카탈로그라 도달 수가
  전부 1이다 — 구멍 표 최하위에 몰린다. 렌더러 파리티와 무관하다.
- **scene 이 구멍의 절반(54/147)을 차지한다.** 다만 그 상당수는 타임라인 애니메이션
  곡선의 에디터 전용 잠금 플래그가 곡선 인덱스 `c0`/`c1`/`c2` 로 흩어진 것이다(§5 B 참조).

---

## 4. 구멍 표 — 없음 + 언급만, 동봉 도달 수 내림차순 (키 경로 단위 상위 30)

`python3 scripts/re/bundled_key_coverage.py --top 30` 의 출력 그대로다.
`~` 는 키 이름이 두 스키마 이상에 걸침(편향 b).

| 파일 | 스키마 | 키 경로 | 상태 | 타입 |
| ---: | --- | --- | --- | --- |
| 168 | scene | `general.camerapreview` | 언급만 | bool |
| 125 | effect | `description` | 언급만 | string ~ |
| 87 | scene | `version` | 언급만 | int ~ |
| 86 | project | `version` | 언급만 | int ~ |
| 82 | preset | `description` | 언급만 | string ~ |
| 75 | preset | `options.droplistOptions` | **없음** | array |
| 75 | preset | `options.droplistVisible` | **없음** | bool |
| 75 | preset | `variants` | 언급만 | array |
| 69 | effect | `version` | 언급만 | int ~ |
| 48 | scene | `objects[].depth` | 언급만 | float,int |
| 32 | particle | `emitter[].duration` | 언급만 | int |
| 21 | effect | `gizmos` | 언급만 | array |
| 21 | effect | `gizmos[].vars` | 언급만 | object |
| 21 | scene | `objects[].particlesrc` | **없음** | null |
| 12 | effect | `performance` | 언급만 | string |
| 8 | particle | `children[].controlpointstartindex` | **없음** | int,null |
| 6 | particle | `initializer[].arcamount` | 언급만 | float |
| 6 | scene | `objects[].instanceoverride.controlpointangle1` | 언급만 | object,string ~ |
| 5 | preset | `variants[].objects[].instanceoverride.controlpointangle1` | 언급만 | object,string ~ |
| 5 | zcompat-web | `actions` | 언급만 | array |
| 5 | zcompat-web | `actions[].insert` | 언급만 | string |
| 5 | zcompat-web | `actions[].replace` | 언급만 | string |
| 4 | particle | `emitter[].delay` | **없음** | float,int |
| 3 | particle | `initializer[].inputrangemax` | **없음** | int |
| 3 | preset | `…controlpointangle1.animation.c0[].back.magic` | 언급만 | bool ~ |
| 3 | preset | `…controlpointangle1.animation.c0[].front.magic` | 언급만 | bool ~ |
| 3 | preset | `…controlpointangle1.animation.c0[].lockangle` | **없음** | bool ~ |
| 3 | preset | `…controlpointangle1.animation.c0[].locklength` | **없음** | bool ~ |
| 3 | preset | `…controlpointangle1.animation.c1[].lockangle` | **없음** | bool ~ |
| 3 | preset | `…controlpointangle1.animation.c1[].locklength` | **없음** | bool ~ |

경로 단위로 보면 하위 6칸이 `lockangle`/`locklength`/`magic` **한 가족**이 곡선 인덱스
`c0`/`c1`/`c2` 로 흩어진 것뿐이다. 그래서 아래 상세는 **키 이름 단위**(`--by-leaf`)로
접어 30개의 서로 다른 키를 다룬다.

---

## 5. 상위 30 상세 — 값·자산·바이너리 VA·붙일 자리

VA 는 `WE_ROOT=… python3 scripts/re/xref.py <키>` 로 뽑았고, 소속 함수는 `.pdata` 기반
`primary(va)` 로 확정했다.

상위 30행은 **24개의 서로 다른 키 이름**을 담는다 — 여섯 행이 같은 이름의 다른 스키마
중복이다(`version` ×3, `description` ×2, `controlpointangle1` ×2, `lockangle`/`locklength` ×2).
거기에 **짝이 되거나 같은 파서 함수에서 읽히는 10개**를 더해 **34개**를 아래에 정리했다
(`inputrangemin` · `bouncefactor` · `nopadding` · `collisionbehavior` · `controlpointangle2` ·
`editable` · `maximumprojectid` · `frag` · `vert` · `locktopointer`). 짝을 빼면 판정이
반쪽이 되기 때문이다 — `inputrangemax` 만 고치고 `inputrangemin` 을 두면 remap 은 여전히 틀린다.

**이 절의 가장 중요한 소득: "엔진 참조 없음"이 곧 "우리 구멍"은 아니다.**
34개 중 **19개(B 17 + C 2)는 wallpaper64.exe 가 아예 읽지 않는다.** 도달 수 1위인
`camerapreview`(168) 부터가 그렇다. 도달 수만 보고 위에서부터 구현했다면 절반 이상을
헛일에 썼을 것이다.

판정 4종:

- **A. 진짜 구멍** — 엔진이 읽고 우리가 안 읽는다. 고쳐야 한다.
- **B. 에디터 전용** — `wallpaperui.exe` 또는 `ui/dist` JS 만 읽는다. 렌더러 파리티 무관.
- **C. 죽은 키** — 어떤 바이너리도 안 읽는다. 자산에만 남은 잔재.
- **D. 메타데이터** — 읽어도 픽셀이 안 변한다(UI 라벨·스키마 버전).

### A. 진짜 구멍 (10개) — 우선순위 순

| # | 키 | 도달 | 상태 | 타입/값 예시 | 대표 자산 |
| --- | --- | ---: | --- | --- | --- |
| A1 | `emitter[].duration` | 32 | 언급만 | int — `1`, `0` | `presets/lightning/particles/presets/thunderbolt_beam_child.json` |
| A2 | `emitter[].delay` | 4 | **없음** | float — `0.2`, `0` | 같은 파일 |
| A3 | `initializer[].arcamount` | 6 | 언급만 | float — `0.1`, `0.44` | `presets/lightning/particles/presets/thunderbolt.json` |
| A4 | `children[].controlpointstartindex` | 8 | **없음** | int/null — `1`, `null` | `presets/lightning/particles/presets/thunderbolt_child_spawner.json` |
| A5 | `initializer[]`·`operator[].inputrangemax` | 4 | **없음** | int — `300`, `50` | `scenes/particleelementpreviews/remapvalue/particles/new_particle_system.json` |
| A6 | `operator[].inputrangemin` | 1 | **없음** | int — `150` | 같은 파일 |
| A7 | `…animation.options.wraploop` | 3+3 | 언급만 | bool/null — `true`, `null` | `effects/blendgradient/preview/scene.json` |
| A8 | `nopadding` (model) | 2 | **없음** | bool — `true` | `scenes/gifs/models/background.json` |
| A9 | `operator[].collisionbehavior` · `operator[].bouncefactor` | 2 · 1 | **없음** | string — `"slide"` / float — `0.7` | `scenes/particleelementpreviews/collisionquad/…/new_particle_system.json` · `…/collisionplane/…` |

**바이너리 근거와 붙일 자리**

| # | 문자열 VA | 참조 VA | 소속 함수 | 우리 쪽 붙일 자리 |
| --- | --- | --- | --- | --- |
| A1 | `0x140489b60` | `0x1401c1ca9` | **`0x1401c1c70`** 이미터 파서 | `Sources/WapleCore/ParticleSystem.swift` — `ParticleSystemDef.parse` 의 이미터 루프(`parsePeriodic` 바로 옆, ~L1608~1724) |
| A2 | `0x1404781e0` | `0x1401c1ccc` | 같은 함수 | 같은 자리 |
| A3 | `0x14048f780` | `0x1401bc3d3`(주입기 `0x1401bc080`) · `0x1401ca482`(소비 `0x1401c5490`) | | `ParticleSystem.swift:1066 parseInitializers` — `case "mapsequencebetweencontrolpoints"` |
| A4 | `0x14048fc30` | `0x1401c1723`(`0x1401c1430`) · `0x1401d09c4`(`0x1401c5490`) | | `ParticleSystem.swift:1877` `json["children"]` 루프 (`ChildLink`) |
| A5 | `0x14048f830` | `0x1401bc634`(`0x1401bc4b0`) · `0x1401bfd34`(**`0x1401bfbb0`**) · `0x1401ca9eb`·`0x1401ce98c`(`0x1401c5490`) | | `ParticleSystem.swift:1503 case "remapvalue"` / `:1213 case "remapinitialvalue"` |
| A6 | `0x14048f820` | `0x1401bc541` · `0x1401bfc41` · `0x1401ca89d` · `0x1401ce836` | 위와 동일 함수들 | 같은 자리 |
| A7 | `0x14048eec0` | `0x1401a97c3` (`Json::Value::find`) | **`0x1401a96b0`** | `Sources/WapleCore/PropertyAnimation.swift:198` `let opts = a["options"]` 블록 |
| A8 | `0x140490be8` | `0x1401fae33` | **`0x1401fac50`** | `Sources/WapleCore/SceneDocument.swift:1369-1372` (`passthrough`/`autosize`/`solidlayer`/`projectlayer` 읽는 자리) |
| A9 | `0x14048faf0` (`bouncefactor` `0x14048fb40`) | `0x1401c0175`·`0x1401c01c1` / `0x1401c00b7`·`0x1401c00dd` → 주입기 **`0x1401c00a0`**; 소비 `0x1401c0403`·`0x1401c0429` → **`0x1401c03f0`** | | `ParticleSystem.swift:1245 parseOperators` — 충돌 오퍼레이터 케이스 |

**A5/A6 은 확실한 결함이다.** 소스는 `outputrangemin`/`outputrangemax` 를 읽으면서
(`ParticleSystem.swift:1517-1522`) 짝이 되는 `inputrange*` 를 안 읽는다. 즉 remap 의
입력 구간이 하드코딩돼 있고, 자산이 `inputrangemin:150 / inputrangemax:200` 으로 좁힌
구간을 무시한다. `0x1401bfbb0` 은 **이미 우리 소스가 인용하는 주소**다
(`ParticleSystem.swift:1505` — "부재 기본 2.0 — 주입기 0x1401bfbb0") — 같은 함수를 읽으면서
바로 옆 키를 빠뜨린 것이다.

**A1/A2 의 실효.** `duration` 은 동봉 32파일에 32번 나오는데 그중 30번이 `0`(= 무제한,
무의미)이고 전부 `scenes/particleelementpreviews/*` 소속이다. 나머지 2번이
`thunderbolt_beam_child` 의 `duration:1` 이고, 같은 이미터가 `delay:0.2` 를 함께 적어
**실제 타이밍 버스트**를 기술한다 — 번개 줄기가 0.2초 늦게 1초만 방출되는 연출이다. 파서 `0x1401c1c70` 을 디스어셈하면 저장 위치까지 확정된다:

```
0x1401c1c87  lea rdx, "rate"       → movss [rdi+0]
0x1401c1ca9  lea rdx, "duration"   → movss [rdi+4]
0x1401c1ccc  lea rdx, "delay"      → movss [rdi+8],  [rdi+0xc]=duration, [rdi+0x10]=delay
0x1401c1ced  lea rdx, "instantaneous"
```

**A8 의 실효.** `0x1401fac50` 은 모델 래퍼 파서이고, `nopadding` 바로 **다음** 키가
`autosize` 다(`0x1401fae64`) — 우리가 이미 읽는 그 키다. 처리는 플래그 세팅이다:

```
0x1401fae33  lea rdx, "nopadding"
0x1401fae56  or dword ptr [rdi + 0x304], 4      ; 플래그 bit2
0x1401fae64  lea rdx, "autosize"                 ; ← 우리는 여기만 읽는다
```

도달은 2건이지만 그 둘이 `scenes/gifs/` 와 `scenes/videoplayer/` 의 배경 모델이다 —
GIF·비디오 월페이퍼 경로라 눈에 띄는 자리다.

### B. 에디터 전용 (17개) — 렌더러 파리티 무관

| 키 | 스키마 | 도달 | wallpaper64.exe | 어디서 읽나 |
| --- | --- | ---: | --- | --- |
| `general.camerapreview` | scene | **168** | 문자열 0곳 | `bin/wallpaperui.exe` 에만 존재 |
| `options.droplistOptions` | preset | 75 | 0곳 | `ui/dist` 1파일 |
| `options.droplistVisible` | preset | 75 | 0곳 | `ui/dist` 1파일 |
| `variants` | preset | 75 | 0곳 | `ui/dist` 11파일 · `locale` 26 |
| `gizmos` | effect | 21 | 0곳 | `ui/dist` 7파일 |
| `gizmos[].vars` | effect | 21 | 0곳 | 〃 |
| `performance` | effect | 12 | 0곳 | `ui/dist` 54파일 · `locale` 36 |
| `…animation.c*[].lockangle` | scene·preset | 3+3 | 0곳 | 베지어 핸들 잠금 UI 상태 |
| `…animation.c*[].locklength` | scene·preset | 3+3 | 0곳 | 〃 |
| `…animation.c*[].back/front.magic` | preset | 3 | 0곳 | 〃 |
| `editable` | effect | 2 | 0곳 | `ui/dist/scripts/*.js` |
| `maximumprojectid` | config | 2 | 0곳 | `bin/wallpaperui.exe` |
| `frag` / `vert` | config | 2 | 문자열은 있으나 `lea` 0건 | zcompat 셰이더 대체 — UI 프로세스 |
| `actions` / `actions[].insert` / `actions[].replace` | zcompat-web | 5 | 0곳 | 웹 월페이퍼 소스 패치 — UI 프로세스 |

**붙일 자리: 없다.** 조치는 "무시가 정답"이라는 사실을 코드에 남기는 것이다.
`camerapreview` 는 도달 168로 전체 1위인데 엔진이 안 읽으므로, 이걸 구현하려는 다음 사람이
같은 조사를 반복하지 않도록 `SceneDocument` 의 `general` 파스 근처(`:981` 부근)에 한 줄
유보 주석을 남기는 편이 낫다. `lockangle`/`locklength`/`magic` 도 마찬가지로
`PropertyAnimation.swift` 의 키프레임 파스(`:169 keyframes`)에 남긴다.

### C. 죽은 키 (2개) — 어떤 바이너리도 안 읽는다

| 키 | 스키마 | 도달 | 근거 |
| --- | --- | ---: | --- |
| `objects[].particlesrc` | scene | 21 | 설치본 전체 `grep -rlF particlesrc` → **자산 21 + projects 1** 뿐. `bin/`·`ui/`·`plugins/` 0건. 동봉 21건 전부 값이 `null` 이다 |
| `controlpoint[].locktopointer` | particle | 2 | 자산 2건(`particles/exampleturbolence*.json`)뿐. 바이너리 0곳 |

`objects[].depth`(48건)도 사실상 여기다 — `.rdata` 의 `depth` 문자열 2건은 둘 다
`"json: unsupported recursion depth"` / `"cbor: unsupported recursion depth"` 의 **접미사**이고
독립 리터럴이 아니다. 짧은 문자열 SSO 조립(`mov dword …, 'tped'`) 도 `.text` 전역 스캔
0건이라, 씬 키로서의 `depth` 는 2.8.42 엔진에 존재하지 않는다. 값도 48파일 52건 중 51건이
`1` 이고 나머지 1건만 `-1.84` 다 — 의미 있는 분포가 아니다.

### D. 메타데이터·유보 (5개) — 읽어도 픽셀이 안 변하거나, 이미 근거가 기록돼 있다

| 키 | 스키마 | 도달 | 타입/값 | 엔진 VA |
| --- | --- | ---: | --- | --- |
| `description` | effect 125 · preset 82 | 207 | string — `"ui_editor_effect_fire_description"` | 문자열 `0x1404776e8`, 참조 **1건** `0x140056524`(함수 `0x140056220`) |
| `version` | scene 87 · project 86 · effect 69 | 242 | int — `1`, `0` | 문자열 `0x140476ce8`, 참조 `0x140056566` 등 5건 |
| `objects[].depth` | scene | 48 | int — `1` | (위 C 참조) |
| `objects[].instanceoverride.controlpointangle1` | scene 6 · preset 5 | 11 | string/object — `"0.00000 -0.00000 0.00000"` | 문자열 `0x1404914b8`, 참조 `0x14024e17a`·`0x14024e1f9` (함수 `0x14024d940`) |
| `…controlpointangle2` | preset | 2 | string — `"0.00000 0.00000 0.52360"` | 문자열 `0x140491440`, 참조 `0x14024e2e5`·`0x14024e364` (같은 함수) |

`description`/`version` 의 유일한 엔진 참조 함수 `0x140056220` 이 읽는 키 집합은
`key · file · status · name · description · version · options` 다 — **이펙트 매니페스트가
아니라 별개 매니페스트 리더**다. 즉 `effect.json` 의 `description` 을 읽는 코드는 엔진에 없다.
`version` 은 자산 242건이 전부 `1`(일부 `0`)이라 분기 근거도 관측되지 않는다.

`controlpointangleN` 은 **메타데이터가 아니라 유보 중인 진짜 구멍**이지만, 우리 소스가
이미 그 사실과 VA(`0x140491490+` · `0x14024e08e`)를 `SceneDocument.swift:2297-2303` 에
기록해 두었기 때문에 여기서 새로 밝힐 게 없어 D 로 분류했다. 붙일 자리는
`SceneDocument.swift:2306 particleInstanceOverride` 다 — `controlpoint\(i)` 루프
(`:2327`) 바로 옆에 `controlpointangle\(i)` 루프를 더하면 된다. 그렇게 하면 §2.4 의
접두사 규칙이 자동으로 이 행을 구멍 목록에서 지운다.

---

## 6. 상위 30 밖에서 눈여겨볼 것

도달 수가 작아 상위 30 밖으로 밀렸지만 **엔진이 읽는** 키들이다. 도달이 작은 이유는
동봉 자산이 그 기능을 쓰는 씬을 몇 개만 담고 있어서지, 중요도가 낮아서가 아니다.

| 키 | 스키마 | 도달 | 상태 | 값 예시 | 엔진 근거 | 붙일 자리 |
| --- | --- | ---: | --- | --- | --- | --- |
| `general.lightconfig` | scene | 2 | 언급만 | `{"point":1,"pointshadow":1}` | 문자열 `0x14048e4e0`, SSO 적재 `0x1401876a2` → 함수 **`0x140186c90`** | `SceneDocument.swift:981` 부근 `general` 파스 / `Scene3DLighting.swift` |
| `general.transparentsorting` | scene | 2 | 언급만 | `true` | `0x14019acc4`·`0x14019ad44` → **`0x140199780`** | `SceneDocument` `general` 파스 → 반투명 정렬 규약 |
| `general.spritesheetrefreshsync` | scene | 2 | 언급만 | `true` | `0x140187656` → **`0x140186c90`** (`lightconfig` 와 같은 함수) | 스프라이트시트 갱신 동기 — `SceneRenderer` |
| `emitter[].cone` | particle | 2 | 언급만 | `0` | `0x1401b94ae`(`0x1401b9100`) · `0x1401c6146`(`0x1401c5490`) | 동봉 2건은 값이 `0` 이라 무해하지만 워크샵 자산은 다를 수 있다 |
| shaderdecl 42건 | shaderdecl | 각 1 | 언급만 | — | — | 에디터 임포터 카탈로그. 렌더러 무관이라 **의도적으로 안 읽는 게 맞다** |

`lightconfig`/`spritesheetrefreshsync` 가 **같은 함수 `0x140186c90`** 에서 읽힌다는 것은
그 함수가 씬 `general` 리더라는 뜻이다 — 우리가 이미 읽는 `bloom`·`clearcolor`·
`orthogonalprojection` 과 한 자리에 있다. 즉 붙일 자리가 이미 열려 있고 근거도 확보돼 있다.

`particle` 스키마의 구멍 11건(없음 8 + 언급만 3)은 A1–A6 · A9(2키) · `cone` ·
`locktopointer` 로 전부 설명됐다 — **하나도 미분류가 없다**.

`scene` 스키마 구멍 54건 중 **40건**이 `lockangle`/`locklength`/`magic`/`wraploop` 가족이
곡선 인덱스(`c0`/`c1`/`c2`)와 `constantshadervalues` 경로로 흩어진 것이다 — 키 이름으로
접으면 4개다. 남는 14개 이름은 `camerapreview` · `version` · `depth` · `particlesrc` ·
`controlpointangle1/2` · 위 표의 넷(`lightconfig`·그 자식 `pointshadow`·`transparentsorting`·
`spritesheetrefreshsync`) · `orthogonalprojection.auto` · 그리고 `countdown` 프리셋 전용
저작 키 셋(`date`·`recurring`·`finalMessage`)이다.

---

## 7. 이 도구의 한계

1. **하한만 준다.** §2.5 (b) 의 이름 충돌 때문에 `파스됨` 701개 안에도 구멍이 있다.
   경로별 정밀 판정을 하려면 파서 코드의 **호출 문맥**을 봐야 하는데 그건 이 도구의 범위 밖이다.
2. **주입 ≠ 소비를 못 가른다.** 기본값 주입기가 이름을 쓰는 자리도 `파스됨` 이다.
3. **동봉 자산 범위만 본다.** 워크샵 코퍼스에는 여기 안 나오는 키가 더 있다.
   `--assets` 로 다른 트리를 가리켜 같은 대조를 돌릴 수 있다.
4. **값 어휘는 안 본다.** `emitter[].name` 이 `sphererandom` 인지 `boxrandom` 인지는
   키 경로가 아니라 값이라 이 도구가 다루지 않는다.
5. **`없음`/`언급만` 경계는 문서 코퍼스에 민감하다.** 누가 리포트에 키 이름을 따옴표째
   적기만 해도 그 키가 `없음` → `언급만` 으로 옮겨간다. 총계(=구멍 집합)는 그때도 안 변한다.
   위 수치는 2026-08-21 · 코드 429개 · 문서 235개 기준이다. 도구 자신과 이 리포트는
   `SELF_EXCLUDE` 로 빠지지만, 형제 리포트까지 자동으로 빠지지는 않는다.
6. **`파스됨` 701개는 검증하지 않았다.** 이 도구가 답하는 질문은 "키 문자열이 파서 코드에
   있는가" 하나다. 있는데 잘못 읽는 것은 이 도구의 사정거리 밖이다 — 그건 A/B 스냅샷과
   골든 게이트의 몫이다.
