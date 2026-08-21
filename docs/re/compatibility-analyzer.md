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

#### [2026-08-21 정정] 위 문단의 **오프셋 라벨과 `group` 귀속이 틀렸다** — 클러스터 BE 재측정

종전 문면은 지우지 않았다. 무엇이 틀렸었는지 남긴다. 아래는 설치본
`ui/dist/scripts/scripts.js`(char 1,186,896 · byte 1,187,134) 를 **독립적으로 다시 떠서** 얻은 값이다.

| 종전 문면 | 실측 | 판정 |
|---|---|---|
| "byte @750151, 길이 7,272" | 750151 은 **char** 오프셋이고 그것도 템플릿 **본문**이 아니라 `e.put("views/includes/browseruserproperties.html"` 의 이름 문자열 자리다. 본문은 char `[750195, 757420)` = byte `[750374, 757599)`, 길이 **7,225** | **틀림** — 단위 라벨 오류 + 길이 오기(7,232 의 오타로 보인다) |
| "템플릿이 분기하는 12종" | `browseruserproperties.html` 의 `ng-if` 타입 비교는 **13자리 · 고유 12종** | **목록은 맞다** (아래 주의) |
| "형제 템플릿 `browseruserpropertiesgroup.html` 의 `group`" | 그 형제 템플릿(char `[757479, 757963)` · byte `[757658, 758142)` · **484바이트**)에는 **`type` 비교가 0건**이다. 그룹 제목 + `#GroupFoldParent` 접힘 컨테이너만 그린다 | **틀림** |
| — | `group` 을 아는 것은 **JS 컨트롤러**다: byte @88625 `"group"===l.type?t.push(n={properties:[],property:l}):n.properties.push(l)`. 그 함수가 `D.all([e("views/includes/browseruserproperties.html"), e("views/includes/browseruserpropertiesgroup.html")])` 로 두 템플릿을 미리 받아 두고, 정렬된 프로퍼티 목록을 `group` 마다 잘라 구획을 만든 뒤 구획마다 두 템플릿을 각각 인스턴스화한다 | 새 사실 |

**주의 — "11종" 이 나오는 이유(이번에 실제로 나돈 수다).** `color` 만 `property.type==='color'`
**삼중 등호**이고 나머지 11종은 `==` 다. `==` 만 찾는 grep 은 `color` 를 놓쳐 **11종**을 준다.
그리고 `volume` 만 자리가 **둘**이다(`isVolumeEnabled(...)` 유/무로 갈린 두 `ng-if`) — 그래서
자리 13, 고유 12다. 자리별 실측:

```
byte  750860  property.type === 'color'            byte  753410  property.type == 'directory'
byte  751130  property.type == 'bool'              byte  754426  property.type == 'file'
byte  751295  property.type == 'textinput'         byte  755427  property.type == 'scenetexture'
byte  751460  property.type == 'slider'            byte  756444  property.type == 'usershortcut'
byte  752096  property.type == 'volume' && isVolumeEnabled(...)
byte  752635  property.type == 'volume' && !isVolumeEnabled(...)
byte  752964  property.type == 'combo'             byte  757526  property.type == 'divider'
byte  753182  property.type == 'combolutfilters'
```

→ **브라우저 벽지 프로퍼티 패널이 아는 타입은 템플릿 12 + JS 1 = 13종이다.**
`WallpaperCompatibilityAnalyzer.weBrowserPropertyTypes` 가 이 13종을 상수로 들고 있고,
`CompatCoreParityTests.testWEBrowserPropertyTypeSchemaIsThirteen` /
`testPropertyTypeSetDifferenceIsPinnedInBothDirections` 가 원소 단위로 고정한다.

> **덧붙임 — 위 §3.3 본문의 `PropertyDecoration.swift:9` · `AppLogic.swift:365` 인용에 대하여.**
> 다른 파일의 **줄 번호**로 건 참조는 무관한 편집에 밀린다(이 리포가 `RAW_DUMP_ALLOWED` 로 이미
> 한 번 사고를 낸 자리다). 실제로 `PropertyDecoration.swift` 의 그 주석은 지금 파일 머리말
> 전체에 걸쳐 있고 9번째 줄에 있지 않다. 대신 **그 줄의 코드/문구**로 찾아라:
> `PropertyDecoration.swift` 는 `char@750151–757383` 을 인용하는 주석(**단위 라벨은 그쪽이 옳다** —
> `char` 다. 다만 범위 자체는 근사다: 750151 은 템플릿 이름 문자열의 시작이고 757383 은 본문 끝
> 757420 보다 37자 앞이다. 본문 정확 범위는 char `[750195, 757420)`), `AppLogic.swift` 는
> `static func kind(forType type: String) -> Kind` 다.

#### [2026-08-21] `divider` 는 이름이 겹친다 — **어느 namespace 인지 밝히지 않으면 틀린다**

`scripts.js` 에서 `divider` 를 *타입 값*으로 쓰는 자리는 **넷**이고 서로 무관하다.
§3.3 종전 문면은 하나만 언급했고 그게 어느 것인지 밝히지 않았다:

| # | 자리 | 표현식 | namespace |
|---|---|---|---|
| ① | byte @757526 · `views/includes/browseruserproperties.html` | `property.type=='divider'` → `<hr class="fullWidth">` | **벽지 유저 프로퍼티** — `currentPropertyTypes` 가 다루는 것 |
| ② | byte @960811 · `views/templates/droplist.html` | `ng-class="{divider:option.type=='divider',…}"` | 드롭리스트 **항목** |
| ③ | byte @1022004 · `views/templates/propertylist.html` | `ng-switch-when="divider"` (`ng-switch on="property.type"` byte @993662·@994748 아래) | 씬 에디터 **오브젝트 인스펙터** |
| ④ | byte @444157 · JS 메뉴 빌더 | `divider:function(){…push({type:"divider"})…}` (소비 byte @440490 `case"divider":`) | **컨텍스트 메뉴** 항목 |

①만 벽지 유저 프로퍼티다. §3.3 이 "`texture` 는 씬 에디터 인스펙터 타입" 이라고 말한 그 인스펙터가
바로 ③의 `propertylist.html` 인데, 그 인스펙터(byte 길이 37,577)는 `ng-switch-when` 으로
**59자리 · 고유 56종**을 분기한다(`checkbox` `checkboxbit` `checkboxbit3` `vec2` `vec3` `vec4`
`uvec2` `hue` `huesteps` `colorlist` `knob` `particle` `boneweights` `bonedepth` `itemlist`
`matrixselector` `rendertarget` `texturevariant` … 그리고 `divider` `texture`).
벽지 프로퍼티 12종과는 **집합 크기부터 다른 별개 namespace** 다.

참고로 `group` 은 **에디터 쪽 사용자 프로퍼티 목록**에도 나온다:
`views/templates/userproperties.html`(byte @1038697 `prop.type === 'group'`)이 8종
(`color slider combo bool textinput group scenetexture usershortcut`)을 분기한다. 그건 또 다른
소비처이고, 이 문서가 다루는 **브라우저 패널**의 `group` 분기는 위의 JS 컨트롤러 한 자리다.

같은 파일에서 `option.type === 'checkbox'` 는 `views/modals/editortemplatewizardmodal.html` 과
`views/modals/settingspluginmodal.html` 에 있다 — §3.3 의 "`checkbox` 는 템플릿 옵션·플러그인 설정의
타입" 은 **맞다**(재확인).

`text`/`label` 은 이번 전수에서도 `type` 비교가 **0건**이다(§3.3 그대로 **[미해결]**).
전수 방법: `scripts.js` 의 `e.put("views/…")` 89개 템플릿 경계를 뜬 뒤
`([A-Za-z_$][\w.$]*)\.type\s*={2,3}\s*\\?'([a-zA-Z0-9_]+)\\?'` 로 58자리,
`ng-switch on=` 5자리 + `ng-switch-when=` 를 각각 소유 템플릿에 귀속시켰다.
`vendor.js`(853,711바이트)에는 `*.type ==` 형태가 **0건**이다.

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

### [2026-08-21 클러스터 BE] 갈리던 **셋을 합쳤다** — 리포트 소비는 여전히 안 했다

리포트 통째 소비(위 문단)는 여전히 하지 않았다. 대신 **같은 사실을 두 갈래로 계산하던 자리** 셋을
찾아 정본 하나로 모았다. 정본은 전부 `WallpaperCompatibilityAnalyzer.swift`(WapleCore)에 둔다 —
그 모듈은 리눅스에서 **실행**되므로 회귀가 CI 이전에 잡힌다.

| 갈리던 것 | 종전 | 지금 | 판정 변화 |
|---|---|---|---|
| 코퍼스 열거(컨테이너 + 프로젝트 폴더) | **사본 3개** — 분석기 · `DeepScan.projectContainer/projectFolders` · `SnapshotPipeline.sceneContainer` | 정본 `projectContainerURL(for:)` / `projectFolders(in:)`, 나머지 둘은 전달자 | 아래 ★ |
| 표시 조건 평가 가능성 | 분석기 `canEvaluate` / DeepScan `canEvaluate && evaluate != nil` — 술어가 다른데 아무 데도 안 적힘 | 사다리 `PropertyConditionSupport{absent, unsupported, parsedOnly, evaluated}` 하나 | 없음(아래 ☆) |
| 웹 브리지 탐지 문자열 | 분석기 10종 · DeepScan **2종** 이 각각 리터럴 | `WebBridgeSignal` 열거 하나(9종 + `remoteNetwork` 는 값이 필요해 별도) | 없음 |

★ **`SnapshotPipeline.sceneContainer` 는 주석과 코드가 갈려 있었다.** 주석은 "DeepScan.projectContainer
와 동일 규칙" 인데 실제로는 **첫 분기가 통째로 없었다** — `<root>/backgrounds/project.json` 이 있으면
`backgrounds` 자체가 프로젝트 폴더이므로 컨테이너는 `root` 여야 하는데, 그 사본은 그 경우에도
`backgrounds` 를 골라 컨테이너를 한 칸 깊게 잡았다(= 그 프로젝트 자신이 후보에서 사라진다).
**설치본·동봉 도달 0건**(두 트리에 `backgrounds` 라는 이름의 프로젝트 폴더가 없다). 그래서 아무도
못 봤다. 지금은 사본이 없으므로 다시 갈릴 수 없다.

☆ 조건 사다리에서 확정한 것 하나: **빈 조건은 조건이 아니다.** 브라우저 템플릿이
`ng-if="!property.condition || evalCondition(property.condition)"` 라 빈 문자열은 JS falsy →
`evalCondition` 을 **부르지 않는다**. Waple 의 평가기도 같은 결과를 낸다(`Tokenizer` 가 빈
토큰열이면 `(true, exact)`). 설치본 도달 **1건**(`projects/defaultprojects/dino_run` 의 `god_rays`,
`type: bool`, `condition: ""`) — 종전에도 두 스캐너가 이 1건을 통과시켰지만 **이유가 서로 달랐다**
(분석기는 평가기가 true 를 주기 때문에, DeepScan 은 `!c.isEmpty` 로 걸러내기 때문에). 이제 같은 이유다.

**합치지 않은 채로 남은 것**(설명이 붙었을 뿐 갈린 것은 그대로다):
- **웹 스캔의 읽는 범위.** 분석기는 엔트리에서 최대 64파일/2MB 를 따라가고 `DeepScan.scanWeb` 은
  **엔트리 파일 하나**만 읽는다. 설치본 web 2/2 는 엔트리가 `index.html` 이고 신호가 전부 하위
  `js/` 에 있어 DeepScan 쪽 카운터는 **0/2** 로 보인다. 합친 것은 *무엇을 신호로 보는가*이지
  *어디를 읽는가*가 아니다. 크롤 도입은 스캔 벽시계를 건드리므로 별건.
- **preset 의존 판정.** DeepScan 이 더 엄격하고 그쪽이 런타임과 같다(§7-4). 분석기를 그쪽으로
  올리는 것은 판정을 바꾸는 변경이라 도달을 재고 해야 한다(설치본 preset 0건 → 여기서는 못 잰다).

---

## 6. 게이트가 검사하지 **않는** 것

| 게이트 | 보는 것 | 이 영역에서 **안** 보는 것 |
|---|---|---|
| `check_scene_mount_parity.py` | 후보 이름 리스트 동일 · `fromDirectory` 존재 · 동봉 씬 개수 | **마운트 선택자가 같은 함수인가** · **DeepScan 전체** |
| `check_lenient_json_reach.py` | 자산 JSON 관용 도달 + 리더 6파일의 `AssetJSON` 호출 수 | **`Sources/WapleCompatCore/**` 가 `WIRED` 표에 없다** — 스캐너가 렌더러보다 엄격해도 초록<br>**[2026-08-21 갱신] 이 줄은 옛말이다**: `"Sources/WapleCompatCore/DeepScan.swift": 5` 가 표에 들어갔다. 다만 `SnapshotPipeline.swift` 는 아직 없다(이번에 `AssetJSON.dictionary` 를 1건 쓰게 됐다 — 추가안은 보고서로 넘겼다) |
| `check_int_narrowing.py` | `DeepScan.swift` 의 `safeInt(` 핀 1개 | 그 외 DeepScan 로직 전부 |
| `check_js_shim_baseclasses.py` | `TextScriptEngine` 심 ↔ `baseclasses.js` 공존 | 웹 브리지(`WallpaperBridgeJS`) 표면과 분석기 탐지 문자열의 대응 — **아무도 안 본다** |
| `scripts/dev/linux-render-typecheck.sh` | `Sources/WapleRender/**` 55/55 | **`Sources/WapleCompatCore/**` 는 커버 목록에 없다** |

#### [2026-08-21 갱신] 위 표의 마지막 줄은 이제 반만 맞다

`--compat` 스위치가 생겨 `Sources/WapleCompatCore/**` **소스 5 + 실행파일 1 + 테스트 4파일**이
`swiftc -typecheck` 를 받는다(실측 rc=0, 3초). 다만 **타입체크지 실행이 아니다** — 이 타깃은
`import Metal`/`AVFoundation`/`WapleRender` 라 리눅스에서 `swift test` 로 돌지 않고, 실제 실행은
macOS CI 가 처음 한다. §7-1 참조.

#### [2026-08-21] `check_scene_mount_parity.py` 가 **여전히** 안 보는 것

그 게이트는 이제 ①후보 꼬리 일치 ②분석기 `fromDirectory` + 렌더러 `sceneFileName` ③동봉 씬 개수
④두 스캐너의 `resolveMountSource(` 리터럴 ⑤DeepScan 의 `sceneFileName:` 리터럴 — 다섯을 본다.
그런데 **전부 문자열 존재 검사**라 다음은 못 잡는다:

- `resolveMountSource` 에 **어떤 인자를 넘기는지**. 분석기는 `hasDependency: project.dependency != nil`
  을 넘기고 DeepScan 도 같은 식을 넘기지만, 한쪽이 `hasDependency:` 를 빼도 기본값 `false` 로
  컴파일되고 게이트는 초록이다(`resolveMountSource(` 리터럴은 그대로 있으니까).
- **코퍼스 열거**(`projectContainer`/`projectFolders`)가 세 스캐너에서 같은지. 이번에 실제로 갈려
  있던 자리다(§5 ★). 게이트 시야 밖이었다.
- **조건 술어·웹 신호 표**가 두 스캐너에서 같은지. 역시 갈려 있었다.
- `SnapshotPipeline` **전체**. 캡처 파이프라인은 이 게이트의 시야에 아예 없다.

→ 넓힐 수 있는 지점을 보고서에 패치안으로 넘겼다(`scripts/spec/**` 는 클러스터 BE 소유가 아니다).

---

## 7. 열려 있는 것

1. **`WapleCompatCore` 는 리눅스 검증 수단이 없다.** 테스트 타깃(`Tests/WapleCompatCoreTests`)은
   `import Metal` 때문에 리눅스에서 안 돌고, 타입체크 스크립트의 커버 목록에도 없다. 이번 웨이브의
   DeepScan 변경은 **타입체크만 통과했고 동작은 macOS CI 가 처음 검증한다.**
   (스크래치패드에 임시 하네스를 만들어 `DeepScan.swift`·`DeepReport.swift`·
   `Tests/WapleCompatCoreTests/*.swift` 를 리눅스에서 `-typecheck` 했다. `SnapshotPipeline.swift`·
   `ProfilePipeline.swift` 는 AppKit 심 공백(`NSImage(contentsOf:)`)·`Darwin` 부재로 제외했다.)

   **[2026-08-21 갱신]** 임시 하네스는 `scripts/dev/linux-render-typecheck.sh --compat` 로
   정식화됐고 `SnapshotPipeline.swift`·`ProfilePipeline.swift` 도 커버에 들어왔다(소스 5/5).
   **여전히 타입체크뿐이다.** 그래서 클러스터 BE 는 새로 잠글 로직을 되도록
   `WallpaperCompatibilityAnalyzer.swift`(WapleCore — 리눅스에서 **실행**된다)로 옮기고,
   `Tests/WapleCompatCoreTests` 에는 그 정본을 **부르는지**를 확인하는 전달 테스트를 뒀다.
   즉 규칙 자체의 회귀는 리눅스에서, 배선의 회귀는 macOS CI 에서 잡힌다.

   테스트 현황(2026-08-21): `Tests/WapleCompatCoreTests` 는 **2파일 25메서드**다 —
   `DeepScanHelpersTests`(**8메서드**: `Report.pct` · `addSample` · `firstErrorToken` ×3 ·
   언팩 마운트 1케이스 · `rawJSON` 관용 · 타임아웃 상수)와 새 `CompatCoreParityTests`(**17메서드**).
   여전히 **무테스트로 남은 층**: `decodeTex`/`formatBucket`/`scanAssetTextures`,
   `scanEffects`/`resolveShaderMeta`/`resolveCombos`/`compileShaders`, `parseModel`,
   `parseParticle`, `scanSceneSounds`/`verifyOgg`, `scanVideo`, `DeepReport.render`,
   `SnapshotCompare.runCompare`, `SnapshotPipeline.captureFrame`/`pngToRGBA`/`runCapture`,
   `ProfilePipeline` 전부. 앞의 대부분은 GPU·실물 코퍼스가 있어야 해서 이 컨테이너에서 못 잠근다.
2. **`currentPropertyTypes` 의 이름과 뜻이 어긋난다**(§3.3). 도달 0이라 이번엔 주석으로만 기록했다.
   **[2026-08-21]** 어긋남 자체는 그대로 두되, 대조군 `weBrowserPropertyTypes`(WE 실측 13종)를
   상수로 추가하고 양방향 차집합을 테스트가 **원소 단위로** 고정한다. 이제 집합을 고치면 그
   테스트가 먼저 깨진다 — 문서만 흔들리는 상태는 끝났다.
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

7. **[2026-08-21] `SnapshotPipeline.sceneFolders` 는 아직 `.pkg` 규약이다.** 렌더러·분석기·DeepScan 은
   전부 `project.json` 의 `file` 로 옮겼는데 캡처 파이프라인만 `scene.pkg`/`gifscene.pkg` **파일
   존재**로 씬을 고른다. 언팩 코퍼스에서 0개를 준다(설치본 씬 188/188 · 동봉 170/170 이 전부 언팩).
   이번에는 **pkg 가 0개일 때만** 형제 열거로 폴백하도록 했다 — pkg 코퍼스에서는 결과가 바이트
   동일이라 256×144 골든 매니페스트의 엔트리 집합이 안 움직인다. **섞인 코퍼스는 여전히 pkg 만
   준다.** 완전 통일하려면 실물 개발 코퍼스(`~/Downloads/wallpaper_dev` — 이 컨테이너에 없다)에서
   집합 델타를 세야 한다. **[미해결]**

   **폴백의 실제 도달(실측, 파이썬 복제로 셈)** — "188/170 이 전부 살아난다" 가 **아니다.**
   `projectFolders(in:)` 는 컨테이너 **한 단계 아래**만 본다(분석기의 원래 계약이고 이번에 안
   바꿨다). 그래서 루트를 어디에 겨누느냐가 전부다:

   | 겨눈 루트 | 종전 | 지금 |
   |---|---:|---:|
   | `<설치본>` · `<설치본>/assets` · `<설치본>/projects` · `<동봉>` | 0 | **0** (프로젝트 폴더가 두 단계 아래다) |
   | `<설치본>/projects/defaultprojects` | 0 | **16** |
   | `<설치본>/assets/scenes` | 0 | **3** |
   | `<동봉>/scenes` | 0 | **3** |

   동봉 170건 중 **167건은 `effects/<이름>/preview/`** 라 세 단계 아래다 — 자산 프리뷰이지 캡처
   대상 벽지가 아니므로 안 잡히는 게 맞다. 즉 이 폴백이 실제로 살리는 것은
   **defaultprojects 16 + scenes 3** 이다.

8. **[2026-08-21] `WallpaperCompatibilityCorpusAuditTests` 안에 DeepScan 술어의 네 번째 사본이 있다.**
   그 테스트가 `canEvaluate(c) && evaluate(c, values:) != nil` 을 **인라인으로 다시 적어** DeepScan 과
   대조한다. 지금은 값이 같지만, 사다리(`conditionSupport`)를 고치면 그 사본은 따라오지 않는다.
   그 파일은 클러스터 BE 소유가 아니다 — 보고서에 패치안으로 넘겼다.

---

## 8. `WapleCompatCore` 잠금 현황 (2026-08-21 클러스터 BE 실측)

이 모듈은 1,882줄이고 테스트는 오래 **한 파일 8메서드**였다. 무엇이 잠겼고 무엇이 안 잠겼는지
줄 수가 아니라 **판정 단위**로 적는다. "리눅스 실행" 열이 핵심이다 — 이 타깃은 `import Metal` 이라
`swift test` 가 리눅스에서 안 돌고, `--compat` 은 **타입체크만** 한다.

| 층 | 함수 | 종전 | 지금 | 리눅스 실행 |
|---|---|---|---|:--:|
| 리포트 산술 | `Report.pct` | ✅ | ✅ | ✗ |
| 표본 상한 | `DeepAgg.addSample` / `addSample2` | ✅ / ✗ | ✅ / **✅** | ✗ |
| 컴파일 실패 집계 키 | `firstErrorToken` | ✅ | ✅ | ✗ |
| 관용 JSON 배선 | `rawJSON` | ✅ | ✅ | ✗ |
| 상한 상수 | `assetLoadTimeoutSeconds` · `oggDecodeTimeBudget` | ✅ | ✅ | ✗ |
| 씬 마운트(언팩) | `scanScene` 진입 | ✅ 1케이스 | ✅ 1케이스 | ✗ |
| **코퍼스 열거** | `projectContainer` · `projectFolders` | ✗ | **✅ 4배치 · 3스캐너 파리티** | **✓**(정본이 WapleCore) |
| **표시 조건 사다리** | `conditionSupport` ← `scanProperties` | ✗ | **✅** | **✓**(정본이 WapleCore) |
| **프로퍼티 인구조사** | `scanProperties` | ✗ | **✅** | ✗ |
| **웹 브리지 신호** | `WebBridgeSignal` ← `scanWeb` | ✗ | **✅ 9신호 + 승격표 + 크롤범위** | **✓**(표는 WapleCore) |
| **preset 의존** | `scanProject` preset 분기 | ✗ | **✅ 6케이스** | ✗ |
| **타입 디스패치** | `scanProject` invalid/application | ✗ | **✅** | ✗ |
| **자산 경로 봉쇄** | `PkgAssets.baseAssetURL` | ✗ | **✅ 탈출 2종 포함** | ✗ |
| **씬 열거(캡처)** | `SnapshotPipeline.sceneFolders` | ✗ | **✅ 언팩/pkg/혼합** | ✗ |
| **0건 가드** | `DeepScan.run` 의 `projectsFound`(루트 오타 · `--only` 오지정) | ✗ | **✅ 3케이스** | ✗ |
| 잔챙이 | `firstExisting` | ✗ | **✅** | ✗ |
| TEX 디코드 | `decodeTex` · `formatBucket` · `scanAssetTextures` | ✗ | ✗ | — |
| 셰이더 | `scanEffects` · `resolveShaderMeta` · `resolveCombos` · `compileShaders` | ✗ | ✗ | — |
| 모델/파티클/사운드 | `parseModel` · `parseParticle` · `scanSceneSounds` · `verifyOgg` | ✗ | ✗ | — |
| 비디오 | `scanVideo` | ✗ | ✗ | — |
| 리포트 렌더 | `DeepReport.render` | ✗ | ✗ | — |
| 스냅샷 비교 | `SnapshotCompare.runCompare` | ✗ | ✗ | — |
| 캡처 | `captureFrame` · `pngToRGBA` · `runCapture` | ✗ | ✗ | — |
| 프로파일 | `ProfilePipeline` 전부 | ✗ | ✗ | — |

**"—" 는 못 잠근 게 아니라 이 컨테이너에서 못 잠그는 것이다**: GPU(Metal 디바이스)·AVFoundation·
실물 코퍼스가 있어야 한다. 그 층들은 macOS 로컬/CI 에서 `WapleRenderTests` 의 실물 코퍼스
테스트가 부분적으로 덮는다.

**메운 순서의 근거(도달 우선)**: 위에서 굵게 표시한 것들은 전부 **형제 스캐너와 중복인 층**이다
(§5). 중복 + 무테스트가 조용히 갈리는 조합이고, 실제로 갈려 있던 자리가 그 안에 셋 있었다.
자산 디코드 층은 중복이 아니라 **별개 층**이라(§5 아래 두 줄) 갈릴 위험이 없고, 대신 실물
코퍼스가 있어야 의미가 있다 — 그래서 뒤로 미뤘다.
