# 호환성 분석기 · DeepScan — 무엇을 판정하고 그 근거가 무엇인가

**작성: 2026-08-21, 3차 웨이브 클러스터 AB.** 대상은
`Sources/WapleCore/WallpaperCompatibilityAnalyzer.swift` 와 `Sources/WapleCompatCore/DeepScan.swift`.

이 문서가 있는 이유: 이 두 스캐너는 이번 세션 내내 **다른 작업의 제동장치**였다. 여러 클러스터가
"여기가 함께 움직인다" 며 변경을 미뤘는데, 정작 **규칙이 몇 개이고 각각이 실물 몇 건에 닿는지**를
아무도 재 본 적이 없었다. 종전 테스트는 합성 픽스처 6~13건뿐이라 "이 규칙을 고치면 몇 건이
움직이나" 라는 질문에 답할 수단 자체가 없었다.

여기 적힌 수치는 전부 실측이고, `Tests/WapleCoreTests/WallpaperCompatibilityCorpusAuditTests.swift`
가 같은 수치를 테스트로 고정한다. **규칙을 바꾸면 그 테스트가 먼저 깨지고, 깨진 차이가 곧 도달
건수다.**

---

## 1. 코퍼스와 범위 라벨

| 트리 | 경로 | project.json 폴더 | 비고 |
|---|---|---:|---|
| 설치본 | `<WE_ROOT>/assets` + `<WE_ROOT>/projects` | **191** | `assets/**/preview` 170 + `projects/**` 21 |
| 동봉 | `Sources/WapleRender/Resources/WEAssets` | **170** | 설치본 `assets/` 와 바이트 동일 |

설치본 191건의 타입 분포: **scene 188 · web 2 · application 1**(preset·video **0건**).
씬 188건은 **전건 언팩**이고 두 트리 전체에 `.pkg` 파일이 **0개**다.
프로퍼티는 241개이고 타입은 `color 203 · slider 17 · combo 14 · bool 7` 넷뿐이다.

> **워크샵 코퍼스는 이 환경에 없다.** `~/Downloads/wallpaper_dev` 도, `corpus_scan/scenes-index.tsv`
> 가 가리키는 447종도 파일이 남아 있지 않다. 그래서 아래 "도달 0건" 은 전부 **설치본+동봉 361
> 프로젝트 기준**이지 "실물에 없다" 는 뜻이 아니다.

자산 JSON 은 세 트리 합쳐 **3,655개**이고 그중 **63개가 JSONC**(줄 주석/트레일링 콤마)다 —
`effect.json` 54 · `preset.json` 8 · 머티리얼 1(`defaultprojects/fantasticcar/materials/car/glass.json`).
`project.json` 중 JSONC 는 **0건**이다. (`check_lenient_json_reach.py` 가 찍는 "32건" 은 같은 것을
**트리 상대경로 중복 제거**로 센 값이다. 동봉과 설치본 `assets/` 가 바이트 동일이라 31+31+1=63 →
31+1=32.)

---

## 2. 분석기가 판정하는 것 — 19개 규칙 전수

계약은 **"이슈 없음 = 렌더 가능"** 이고, 판정은 UI 의 호환성 표시로 그대로 나간다.
`severity == .error` 가 하나라도 있으면 그 프로젝트는 `isBlocked` 다.

| # | 코드 | 등급 | 트리거 | 근거 | 설치본 도달 | 동봉 도달 |
|---|---|---|---|---|---:|---:|
| 1 | `invalidProjectJSON` | error | `AssetJSON.dictionary(project.json)` == nil | 리더 정의(관용 파스 실패 = 읽을 수 없음) | 0 | 0 |
| 2 | `unsupportedApplicationType` | error | `type == "application"` | `RendererFactory` 에 application 렌더러가 없다 | **1** (`sheep`) | 0 |
| 3 | `unknownProjectType` | error | `WallpaperType.unknown(raw)` | `ProjectJSONParser` 타입 추론 | 0 | 0 |
| 4 | `unsafeWallpaperFilePath` | error | 원문 `file` 은 문자열인데 `project.fileName == nil`, 또는 `containedFileURL` nil | `WallpaperPathSecurity` | 0 | 0 |
| 5 | `missingWallpaperFile` | error | web/video/application: `file` 부재 또는 디스크에 없음 | 파일 존재 | 0 | 0 |
| 6 | `unicodeNormalizedFileMatch` | warning | 선언 파일/프리뷰가 바이트로는 없고 NFC/NFD 동치가 있음 | 파일시스템 정규화 | 0 | 0 |
| 7 | `unsafePreviewPath` | warning | 원문 `preview` 는 있는데 `previewName == nil` | `WallpaperPathSecurity` | 0 | 0 |
| 8 | `missingPreviewFile` | warning | 프리뷰 선언, 실물·동치 모두 없음 | 파일 존재 | 0 | 0 |
| 9 | `missingScenePackage` | error | 씬: 마운트 소스도 유효 메인파일도 없음 / 패키지 파스 실패 / 후보 문서 부재 | **렌더러와 같은 `ScenePackage.resolveMountSource`**(§4) | 0 | 0 |
| 10 | `missingPresetDependency` | error | preset: `dependency` 부재 또는 코퍼스에 없음 | `PresetResolver` 파리티(F411, id ∪ 폴더명) | 0 | 0 |
| 11 | `unsupportedPropertyType` | warning | 타입 ∉ `currentPropertyTypes` | **근거 약함 — §3.3** | 0 | 0 |
| 12 | `propertyDisplayCondition` | warning | `!PropertyConditionEvaluator.canEvaluate(condition)` | AngularJS 1.6.10 파서 파리티 | 0 | 0 |
| 13 | `nonNativeVideoContainer` | warning | 비디오 확장자 ∉ `VideoFormats.nativeExtensions` | `VideoRenderer` 단일 소스 | 0 | 0 |
| 14 | `webServiceWorker` | warning | 대소문자 무시 부분일치 `serviceWorker` | 브라우저 API 이름(WE 바이너리엔 없다 — CEF 쪽) | 0 | 0 |
| 15 | `webRandomFileBridge` | warning | 부분일치 `wallpaperRequestRandomFileForProperty` | `bin/webwallpaper64.exe` ASCII ×1 | 0 | 0 |
| 16 | `webAudioListener` | warning | 부분일치 `wallpaperRegisterAudioListener` | `bin/webwallpaper64.exe` ASCII ×1 | **1** | 0 |
| 17 | `webMediaIntegration` | warning | 부분일치 `wallpaperRegisterMedia` \| `wallpaperMedia` | 같은 바이너리의 `wallpaperRegisterMedia{Playback,Properties,Status,Thumbnail,Timeline}Listener` 5종 + `wallpaperMediaIntegration` | 0 | 0 |
| 18 | `remoteNetworkReference` | warning | **요청을 만드는 자리**의 `http(s)://` | §3.1 — 종전 규칙은 2/2 거짓 양성이었다 | 0 (종전 2) | 0 |
| 19 | `webPluginBridge` | warning | 부분일치 `wallpaperPluginListener` | §3.2 — 이번에 추가 | **2** | 0 |

**19종 중 도달하는 것은 3종뿐이다.** 나머지 16종은 이 코퍼스로는 **아무것도 검증되지 않는다** —
합성 픽스처가 있는 것과 없는 것이 섞여 있으니 이 표를 근거 목록으로 쓸 때 주의할 것.

이슈가 아닌 **피처 태그**(리포트에만 실린다): 설치본 실측
`scenePackage 188 · sceneParticle 125 · sceneLayer 116 · scene3DModel 61 · sceneEffect 55 ·
sceneScript 8 · sceneLight 4 · sceneText 4 · pluginBridge 2 · propertyListener 2 ·
audioListener 1 · sceneSound 1`. `webLifecycle`·`webGL`·`fileURL`·`randomFile`·`serviceWorker`·
`mediaIntegration`·`remoteNetwork` 은 0건.

### 최종 판정(설치본 191건)

- blocked **1건**(`sheep` — `unsupportedApplicationType`)
- warning **3건**(`webAudioListener` 1 + `webPluginBridge` 2)
- 나머지 190건 무이슈

---

## 3. 실물 대조에서 나온 것

### 3.1 `remoteNetworkReference` — 도달 2건이 **전건 거짓 양성**이었다 [확정]

종전 규칙은 크롤한 텍스트 파일 어디서든 `https?://` 부분일치였다. 경고는 프로젝트당 1건이므로
설치본 도달은 **2건**(웹 프로젝트 2개 전건)이고, 그 2건이 무엇에 걸렸는지는 아래와 같다:

| 경고 | 걸린 파일 | 그 파일의 `http(s)://` 전부 | 실체 |
|---|---|---|---|
| #1 `corsair_o_tron` | `js/TweenMax.min.js` | `http://greensock.com`, `.../standard-license`, `http://www.w3.org/1999/xhtml`, `http://www.w3.org/2000/svg` | 라이선스 배너 주석 + **XML 네임스페이스 이름** |
| #2 `corsair_collection` | `main.25cf1bbdb69093b2a190.js` | `http://g.co/ng/security#xss`, `https://angular.io/docs/...`, `http://www.w3.org/{1999/xhtml, 1999/xlink, 2000/svg, 2000/xmlns/, XML/1998/namespace}` | Angular 에러 메시지의 문서 링크 + 네임스페이스 이름 |

네임스페이스 URI 는 XML Namespaces 규약상 **가져오지 않는 식별자**다. 그리고 `corsair_o_tron` 은
`fetch`/`XMLHttpRequest`/`WebSocket`/`EventSource`/`sendBeacon` 이 **한 건도 없다** — 경고 문구가
말하는 "this request" 자체가 존재하지 않는다.

**조치**: 요청을 만드는 문법 자리(HTML `src`/`href`/`srcset`/`poster`/`action`, JS 요청 API 첫 인자,
`XMLHttpRequest.open` 둘째 인자, ES 모듈 `from`, CSS `url()`/`@import`)의 URL 만 본다.
도달 **2 → 0**(참 양성은 원래 0). 양성 대조는 `testWebFeatureScanFollowsLocalScripts` 의
`fetch('https://example.invalid/data.json')` 이 그대로 유지한다.
**알려진 한계**: URL 이 변수를 거치면(`var u = "https://…"; fetch(u)`) 못 잡는다. 정적 스캔의
원리적 한계이고, 종전 규칙은 그 대신 정밀도를 0 으로 만들었다.

### 3.2 `wallpaperPluginListener` — **거짓 음성 2/2** [확정 → 규칙 추가]

`bin/webwallpaper64.exe` 의 웹 브리지 표면을 ASCII `wallpaper[A-Za-z0-9_]{2,60}` 로 전수하면 13종이다:

```
wallpaper64 ×3                              wallpaperGetUtilities ×1
wallpaperMediaIntegration ×1                wallpaperOnVideoEnded ×2
wallpaperPluginListener ×2                  wallpaperPropertyListener ×6
wallpaperRegisterAudioListener ×1           wallpaperRegisterMediaPlaybackListener ×1
wallpaperRegisterMediaPropertiesListener ×1 wallpaperRegisterMediaStatusListener ×1
wallpaperRegisterMediaThumbnailListener ×1  wallpaperRegisterMediaTimelineListener ×1
wallpaperRequestRandomFileForProperty ×1    wallpaperRequestTakeScreenshotResponse ×3
```

이 중 **`wallpaperPluginListener` 만 Waple 의 `WallpaperBridgeJS.swift` 가 정의하지 않는다**
(`grep -rn "PluginListener" Sources/` = 0건). iCUE/Chroma LED 플러그인 채널이고, 설치본 웹 벽지
**2/2 전건**(`corsair_o_tron/js/main.js`, `corsair_collection/main.*.js`)이 실제로 등록한다.
종전에는 분석기가 이 2건에 대해 아무 말도 하지 않았다 → `.warning` 규칙 `webPluginBridge` 추가.

### 3.3 `currentPropertyTypes` — **WE 스키마도 Waple 패널도 아니다** [확정, 도달 0 → 미조치]

WE 가 아는 벽지 유저 프로퍼티 `type` 은 `ui/dist/scripts/scripts.js` 의
`views/includes/browseruserproperties.html` 템플릿(byte @750151, 길이 7,272)이 분기하는 **12종**
`bool color combo combolutfilters directory divider file scenetexture slider textinput usershortcut volume`
\+ 형제 템플릿의 `group`. (형제 파일 `PropertyDecoration.swift:9` 가 같은 오프셋을 이미 인용한다 —
독립적으로 다시 떠서 같은 목록을 얻었다.)

| 방향 | 항목 | 실체 |
|---|---|---|
| WE 에 있는데 Waple 집합에 없음 | `volume` `combolutfilters` `divider` | 실물이 쓰면 경고가 나가는데, 그게 **우연히** 맞다(`PropertyControl.kind` 가 셋 다 `.displayOnly`) |
| Waple 집합에 있는데 WE 스키마에 없음 | `checkbox` | WE 에선 **템플릿 옵션·플러그인 설정**의 타입(`option.type === 'checkbox'`), 벽지 프로퍼티 타입 아님 |
| 〃 | `texture` | WE **씬 에디터 오브젝트 인스펙터**의 타입(byte @994481, `ng-switch on="property.type"`) — 다른 namespace |
| 〃 | `text` `label` | `type ==` 비교가 **0건**. 프로퍼티의 **필드 이름**(라벨 문자열·옵션 라벨)과 혼동으로 보인다 **[미해결]** |

게다가 이슈 문구는 "Waple 의 프로퍼티 패널이 편집 못 한다" 인데, 집합에 있는
`usershortcut` `group` `text` `label` `texture` 는 `PropertyControl.kind(forType:)`
(`Sources/Waple/AppLogic.swift:365`)가 `.displayOnly` 를 준다 — **경고가 나가야 하는데 안 나간다**.

**지금 고치지 않은 이유**: 설치본·동봉에 등장하는 타입은 넷뿐이라 위 차이 7종이 전부 도달 0이고,
`group` 을 미지로 돌리면 워크샵 코퍼스(여기서 측정 불가)에서 대량 경고가 난다. 정정안은 §6.

### 3.4 `wallpaperWillGoBackground/Foreground` — WE 2.8.42 에 **문자열이 없다** [확정 / 해석은 추정]

`webLifecycle` 피처가 탐지하는 두 이름은 설치본 전 트리(exe·dll·ui·assets·projects) ASCII·UTF-16LE
전수에서 **0건**이다. Waple 의 `WallpaperBridgeJS.swift:287` 은 그 두 이름을 호출한다.
**확정**: WE 2.8.42 설치본에 그 문자열이 없다. **추정**: 다른 버전/문서 기반이거나 다른 제품의 API다.
피처 태그일 뿐 이슈를 만들지 않고 코퍼스 도달도 0이라 이번에 건드리지 않았다. `WapleRender` 는
이 과제 소유가 아니다 → §6.

---

## 4. 마운트 규약 — 세 벌이던 것을 두 벌로

렌더러는 2026-08-21 부터 `ScenePackage.resolveMountSource`(`SceneRenderer.swift:1454`)를 쓴다:
**`project.json` 의 `file` 이 단독 결정자**이고 `.pkg` 는 그 파일이 디스크에 없을 때의 폴백이다.
분석기는 그 뒤에도 `scene.pkg`/`gifscene.pkg` **이름 두 개의 존재**로 골랐고, DeepScan 은
아예 그 두 이름이 없으면 스캔을 포기했다.

갈리던 자리(전부 렌더러 쪽이 맞다):

| 상황 | 렌더러/WE | 종전 분석기 | 종전 DeepScan |
|---|---|---|---|
| `file:"techno.json"` 부재 + `techno.pkg` 존재 | pkg 를 연다 | 폴더 마운트 → **거짓 `missingScenePackage`** | 미지원 |
| `Scene.pkg`(대소문자 표기 차) | `legacyPackageURL` 이 잡는다 | 못 찾는다 | 미지원 |
| `file:"scene.json"` 실재 + 잔존 `scene.pkg` | **폴더**(디스크의 scene.json) | **pkg** → 다른 씬을 검사 | pkg |
| 언팩(pkg 없음) | 폴더 마운트 | 폴더 마운트 (G-E3-01 에서 수정됨) | **미지원** |

**조치**: 분석기·DeepScan 둘 다 `ScenePackage.resolveMountSource` 를 부른다. DeepScan 은
`SceneDocument.parse(sceneFileName:)` 도 넘긴다.

**도달 실측**

- 분석기 쪽: 설치본+동봉 361건에 `.pkg` 가 0개고 `file` 이 전건 실재 → **판정 변화 0건**.
  회귀 방지는 새 단위 테스트 3종(`WallpaperCompatibilitySceneMountTests` ④-a/b/c)이 맡는다.
- DeepScan 쪽: 씬 **188/188 이 폴더 마운트**로 바뀐다(종전 전건 미지원). `SceneDocument` 는
  파일명을 넘기면 **188/188**, 관례 이름만이면 **184/188** 이 열린다 — 차이 4건은
  `audiophile` `fantasticcar` `ricepod` `techno`.

> `check_scene_mount_parity.py` 는 이 넷 중 **어느 것도 보지 않는다.** 그 게이트가 보는 것은
> ① `sceneCandidates` 후보 이름 리스트가 `SceneDocument` 와 글자 그대로 같은가,
> ② 분석기에 `ScenePackage.fromDirectory(folderURL)` 리터럴이 있고 렌더러가
> `sceneFileName: project.fileName` 을 넘기는가, ③ 동봉 씬 개수 하한 — 셋뿐이다.
> **마운트 선택자가 같은 함수인지는 검사하지 않고, DeepScan 은 게이트 시야 밖이다.**

---

## 5. DeepScan 과 분석기의 관계 — 5층이 중복, 2층이 별개

| 층 | 분석기 | DeepScan | 판정 |
|---|---|---|---|
| project.json 파스·타입 집계 | `AssetJSON`(관용) + `ProjectJSONParser` | 같음(이번에 관용으로 맞춤) | **중복** |
| 프로퍼티 타입 인구조사·미지 타입 | `currentPropertyTypes` | **같은 상수를 참조** | **중복**(단일 소스 유지) |
| 조건식 평가 가능성 | `canEvaluate` | `canEvaluate && evaluate != nil` | **중복 + 술어 상이** |
| preset 의존 해소 | 존재만 확인(id ∪ 폴더명) | 존재 + **마운트 가능한 타입인가** | **중복 + DeepScan 이 더 엄격** |
| 웹 브리지 신호 | 크롤 64파일/2MB, 신호 10종 | **엔트리 파일 1개, 신호 2종** | **중복 + DeepScan 이 부분집합** |
| 씬 자산 실디코드(TEX/MDL/파티클/셰이더 번역·Metal 컴파일) | 없음(키 존재로 피처 태그만) | 있음 | **별개 층** |
| 비디오 재생 가능성 | 확장자 집합만 | AVAsset 헤더 프로브 + 변환 가능 버킷 | **별개 층** |

**정본을 하나로 모을 수 있는가 — 결론: 앞 5층은 가능, 뒤 2층은 아니다.**
DeepScan 의 프로젝트 레벨 층(위 5개)은 분석기의 `WallpaperCompatibilityReport` 를 **소비**해서
만들 수 있다. 그러면 `projectContainer`/`projectFolders` 사본(현재 두 파일에 거의 동일한 구현이
따로 있다)도 함께 사라진다. 이번 웨이브에서는 하지 않았다 — `WapleCompatCore` 는 `import Metal`
이라 **리눅스에서 테스트가 아예 안 되고**(§7), 그만한 재배선을 타입체크만 믿고 넣을 수는 없다.

---

## 6. 게이트가 검사하지 **않는** 것

| 게이트 | 보는 것 | 이 영역에서 **안** 보는 것 |
|---|---|---|
| `check_scene_mount_parity.py` | 후보 이름 리스트 동일 · `fromDirectory` 존재 · 동봉 씬 개수 | **마운트 선택자가 같은 함수인가** · **DeepScan 전체** |
| `check_lenient_json_reach.py` | 자산 JSON 관용 도달 + 리더 6파일의 `AssetJSON` 호출 수 | **`Sources/WapleCompatCore/**` 가 `WIRED` 표에 없다** — 스캐너가 렌더러보다 엄격해도 초록 |
| `check_int_narrowing.py` | `DeepScan.swift` 의 `safeInt(` 핀 1개 | 그 외 DeepScan 로직 전부 |
| `check_js_shim_baseclasses.py` | `TextScriptEngine` 심 ↔ `baseclasses.js` 공존 | 웹 브리지(`WallpaperBridgeJS`) 표면과 분석기 탐지 문자열의 대응 — **아무도 안 본다** |
| `scripts/dev/linux-render-typecheck.sh` | `Sources/WapleRender/**` 55/55 | **`Sources/WapleCompatCore/**` 는 커버 목록에 없다** |

---

## 7. 열려 있는 것

1. **`WapleCompatCore` 는 리눅스 검증 수단이 없다.** 테스트 타깃(`Tests/WapleCompatCoreTests`)은
   `import Metal` 때문에 리눅스에서 안 돌고, 타입체크 스크립트의 커버 목록에도 없다. 이번 웨이브의
   DeepScan 변경은 **타입체크만 통과했고 동작은 macOS CI 가 처음 검증한다.**
   (스크래치패드에 임시 하네스를 만들어 `DeepScan.swift`·`DeepReport.swift`·
   `Tests/WapleCompatCoreTests/*.swift` 를 리눅스에서 `-typecheck` 했다. `SnapshotPipeline.swift`·
   `ProfilePipeline.swift` 는 AppKit 심 공백(`NSImage(contentsOf:)`)·`Darwin` 부재로 제외했다.)
2. **`currentPropertyTypes` 의 이름과 뜻이 어긋난다**(§3.3). 도달 0이라 이번엔 주석으로만 기록했다.
3. **`text` `label` 이 어디서 왔는지 모른다**(§3.3). WE UI 에 `type == 'text'`/`'label'` 비교가 0건이다.
4. **preset 의존 판정이 두 스캐너에서 다르다.** 분석기는 존재만 보고, DeepScan 은 마운트 가능한
   타입까지 본다. 런타임(`PresetResolver` + `RendererFactory`)은 후자와 같으므로 **분석기 쪽이
   거짓 음성**이다 — `application`/`unknown`/또 다른 `preset` 에 의존하는 preset 을 통과시킨다.
   설치본 도달 0(preset 0건)이라 미조치.
5. **웹 브리지 4종은 아무도 안 본다** — `wallpaperGetUtilities` `wallpaperOnVideoEnded`
   `wallpaperRequestTakeScreenshotResponse` `wallpaperPluginListener`(이번에 마지막 것만 배선).
   앞 셋은 Waple 브리지가 **구현하고 있으므로** 경고 대상이 아니다(`WallpaperBridgeJS.swift` 실측).
6. **`PropertyDecoration.swift:12` 의 "프로퍼티 244개"** 와 이 문서의 241개가 다르다. 그쪽이 어떤
   범위를 셌는지 확인하지 못했다 **[미해결]** — 그 파일은 이 과제 소유가 아니다.
