# 웹 월페이퍼 브리지 — 주입 전역 · zcompat 호환성 패치

**측정일 2026-08-21 · WE 2.8.42**

| 바이너리 | SHA256 | imagebase |
| --- | --- | --- |
| `bin/webwallpaper64.exe` | `51173dab…5b4f6d9d` | 0x140000000 |
| `wallpaper64.exe` | `40e2ce02…cd993b0` | 0x140000000 |

> **먼저 밝힐 것 — 이 과제의 바이너리는 `wallpaper64.exe` 가 아니다.**
> 웹 월페이퍼는 CEF 서브프로세스 `bin/webwallpaper64.exe`(1,337,840바이트)가 돌린다.
> 설치본 전수 grep 결과 `zcompat` 문자열 보유 파일은 `bin/webwallpaper64.exe` 와
> `bin/wallpaperui.exe` 둘뿐이고, `wallpaper64.exe` 에는 `zcompat` · `actions` ·
> `wallpaperPropertyListener` 가 **ASCII·UTF-16LE 어느 인코딩으로도 0건**이다.
> 아래 VA 는 전부 `webwallpaper64.exe` 기준이다.

재현:

```bash
# zcompat 스키마 문자열 블록 (파일오프셋 0x119108–0x119186)
python3 -c "d=open('bin/webwallpaper64.exe','rb').read(); print(repr(d[0x119100:0x1191d0]))"

# 주입 전역 이름 전수 (ASCII)
python3 -c "import re;d=open('bin/webwallpaper64.exe','rb').read();\
print(sorted({m.group().decode() for m in re.finditer(rb'wallpaper[A-Za-z]{3,60}',d)}))"

# ___STAHP 주입 스크립트 원문 (5,936바이트)
python3 -c "d=open('bin/webwallpaper64.exe','rb').read();print(d[0x119ca0:d.index(b'\x00',0x119ca0)].decode())"
```

Waple 반영분:

| 파일 | 내용 |
| --- | --- |
| `Sources/WapleCore/WebCompatPatch.swift` | zcompat 스키마 파스 + 치환 엔진(순수·리눅스 테스트 가능) |
| `Sources/WapleRender/WallpaperSchemeHandler.swift` | 서빙 시점 패치 적용 |
| `Sources/WapleRender/WallpaperBridgeJS.swift` | 주입 전역 |
| `Sources/WapleRender/VideoFallbackHTML.swift` | WE 동영상 래퍼의 onerror/onended 훅 |
| `Tests/WapleCoreTests/WebCompatPatchTests.swift` | 동봉 5건 전수 고정(리눅스 15케이스) |
| `Tests/WapleRenderTests/WebWallpaperInjectedAPITests.swift` | 전역 존재·실런타임 값 + 스킴 응답 |

---

## 0. 다섯 줄 요약

1. **zcompat 은 "런타임 패치" 가 아니라 디스크 재작성이다.** WE 는 벽지의 JS 파일을 **덮어쓴다**
   (0x14000cee4 에서 출력 스트림을 열고 0x14000cf3b 로 쓴다). 실패하면
   `"Failed writing compat fix at %S\n"`. Waple 은 같은 결과를 **서빙 시점 메모리 치환**으로 낸다 —
   남의 워크샵 파일을 건드리지 않는다.
2. 스키마는 딱 4개 키다: `actions[]` · `file` · `replace` · `insert`. **`replace` 가 찾을 문자열,
   `insert` 가 넣을 문자열**로 이름이 직관과 반대다.
3. 동봉 5건은 두 종류다 — **WebGL `texImage2D` 널 인자 가드 4건**, **three.js `alpha:true` →
   불투명 + 고정 클리어컬러 1건**. 둘 다 WebGL 확장 차이가 아니라 **CEF 의 엄격 인자 검사**와
   **데스크탑 합성의 배경 알파** 문제다(§2.4).
4. WE 가 주입하는 전역은 **네이티브 등록 10개 + `___STAHP` 스크립트 전역 7개(+래핑 7개)** 다.
   Waple 대조: 전역 17개 = **구현 10 · 구현(이름 상이) 4 · 스텁 2 · 없음 1**,
   페이지 콜백 6개 = **구현 4 · 스텁 1 · 없음 1**(§4).
5. WKWebView 로 **불가능한 것은 2개**뿐이다 — 화면 스냅샷(`__wpxTakeSnapshot`)과
   플러그인 로드 통지(`wallpaperPluginListener.onPluginLoaded`). 이유는 §6.

---

## 1. zcompat 패치 스키마 전표

### 1.1 문자열 블록

`.rdata` 파일오프셋 0x119108–0x119186 (VA 0x14011ab08–0x14011ab86) 에 스키마 전체가 붙어 있다:

| 파일오프셋 | VA | 문자열 | 역할 |
| --- | --- | --- | --- |
| 0x119108 | 0x14011ab08 | `length before: ` | 로그 접두 |
| 0x119118 | 0x14011ab18 | `Failed writing compat fix at %S\n` | 쓰기 실패 로그(`%S` = wide) |
| 0x11913c | 0x14011ab3c | `431960` | WE Steam AppID — 워크샵 설치본 게이트 |
| 0x119148 | 0x14011ab48 | `assets/zcompat/web` | 전표 디렉터리 |
| 0x11915c | 0x14011ab5c | `.json` | 확장자 |
| 0x119168 | 0x14011ab68 | `actions` | **배열** 키 |
| 0x119170 | 0x14011ab70 | `file` | 항목 키 |
| 0x119178 | 0x14011ab78 | `replace` | 항목 키 |
| 0x119180 | 0x14011ab80 | `insert` | 항목 키 |

이게 전부다. `maximumprojectid` 같은 키는 **웹 전표에는 없다**(그건 `zcompat/scene/shaders/*/config.json`
쪽 스키마다 — §7).

### 1.2 파서 VA

파서는 **독립 함수가 아니라** URL 해석 함수 **0x14000bd80–0x14000d978** 안에 인라인돼 있다.
zcompat 구간은 **0x14000c241–0x14000d14f**.

| 단계 | VA | 동작 |
| --- | --- | --- |
| 경로 → UTF-8 | 0x14000c273 (0x1400378a0) | 로드할 `index.html` 의 wide 경로를 narrow 로 |
| 부모 있나 | 0x14000c27f (0x140006700) | `/`(0x2f)·`\`(0x5c) 둘 다 구분자로 본다 |
| 파일명 제거 | 0x14000c292 (0x1400056b0) | → 프로젝트 디렉터리 |
| 워크샵 ID | 0x14000c29e (0x1400055f0) | 프로젝트 디렉터리의 **폴더명** |
| 프로젝트 디렉터리 보관 | 0x14000c2b1 | `[rbp+0x1d0]` — 액션 `file` 의 기준 |
| 조부모 폴더명 | 0x14000c3bd–0x14000c3e7 | 한 단계 더 올라간 폴더명 |
| **AppID 게이트** | 0x14000c3ec–0x14000c415 | 길이 6 이고 `strcmp(…, "431960")==0` 일 때만 진행 |
| 전표 경로 조립 | 0x14000c468–0x14000c544 | 실행 모듈 경로(0x140006b20, `GetModuleFileNameW`) → 디렉터리(0x140006790) → `/ "assets/zcompat/web"`(0x140004d90 → `path::operator/=` 0x140034b90) → `+ "<워크샵ID>" + ".json"` |
| 존재 확인 | 0x14000c5f9 (0x140006a50 → `GetFileAttributesExW` 0x140051e90) | 없으면 여기서 끝 |
| JSON 파스 | 0x14000c63e–0x14000c65c | jsoncpp |
| `actions` | 0x14000c751–0x14000c76f | **태그 6(array)** 아니면 통째 무시 |
| 항목 순회 | 0x14000c7c7–0x14000c810 | `std::map` 이터레이터(jsoncpp 배열의 내부 표현) |
| `file` 타입 | 0x14000c826–0x14000c844 | **태그 4(string)** 아니면 → 0x14000d0ca |
| `replace` 타입 | 0x14000c84a–0x14000c868 | 〃 |
| `insert` 타입 | 0x14000c86e–0x14000c88c | 〃 |
| 값 읽기 | 0x14000c892–0x14000c902 | `file`→`[rbp+0x18]`, `replace`→`[rbp+0x60]`, `insert`→`[rbp+0x170]` |
| 대상 경로 | 0x14000c907–0x14000c925 | `프로젝트디렉터리 + file` |
| 파일 읽기 | 0x14000c96b (0x140006a50 계열) | 실패/빈 내용이면(0x14000c992) 다음 항목 |
| **치환 루프** | 0x14000ca90–0x14000cc51 | 아래 §1.4 |
| 트레일링 NUL 제거 | 0x14000ce30–0x14000ceb2 | 내용 끝의 `\0` 를 전부 잘라 낸다 |
| 쓰기 | 0x14000cec7–0x14000cf4c | 파일 덮어쓰기 → 실패 시 0x14000cf7e 로그 |
| 다음 항목 | 0x14000d0ca–0x14000d14a | 이터레이터++ 후 0x14000c804(루프 헤드)로 복귀 |
| 루프 종료 | 0x14000d14f | |

**AppID 게이트의 뜻**: `…/steamapps/workshop/content/431960/<워크샵ID>/index.html` 형태,
즉 **Steam 워크샵으로 설치된 벽지**에만 적용한다. 로컬 프로젝트·에디터 미리보기는 건드리지 않는다.

### 1.3 판정 규칙(정확히)

```
actions 가 배열이 아니다            → 전표 전체 무시
항목이 오브젝트가 아니다             → 그 항목만 건너뛰고 다음 항목
file/replace/insert 중 하나라도
  문자열(jsoncpp 태그 4)이 아니다   → 그 항목만 건너뛰고 다음 항목
대상 파일이 없거나 내용이 비었다     → 그 항목만 건너뛰고 다음 항목
```

숫자·불리언은 문자열로 승격되지 않는다(태그 비교가 `cmp byte [rax+8], 4` 라 정확 일치).

### 1.4 치환 의미론

```c
size_t pos = 0;
while ((pos = content.find(replace, pos)) != npos) {   // 0x14000cab0
    content.replace(pos, replace.size(), insert);      // 0x14000cb23 / 0x14000cc0c 계열
    pos += insert.size();                              // 0x14000cb28  add r14, r15
}
```

- **전체 치환**이다(첫 매치만이 아니다).
- 진행 위치를 `insert` 길이만큼 밀기 때문에 **넣은 텍스트는 다시 매치되지 않는다**. 동봉 4건이
  정확히 그 형태다(`u(t,e){t.texImage2D` → `u(t,e){if(e!=null)t.texImage2D` 는 원래 needle 을
  포함하지 않으므로 사실 무해하지만, 규칙 자체가 재매치를 막는다).
- 따라서 **멱등**이다 — WE 가 매 로드마다 이 패치를 다시 돌려도 두 번 적용되지 않는다.
- **빈 `replace` 는 WE 에서 무한 루프다.** `std::string::find(ptr, pos, 0)` 은 `pos <= size` 면
  `pos` 를 돌려주고, `insert` 도 비면 `pos` 가 제자리다. 동봉 5건에는 없지만 JSON 은 사용자
  파일이므로 Waple 은 **빈 `replace` 항목을 버린다**(의도적 분기, `WebCompatPatch.parse`).

### 1.5 적용 시점

같은 함수(0x14000bd80) 가 URL 을 해석하는 도중에, **브라우저에 로드를 지시하기 전에** 돈다
(0x14000d14f 이후 함수는 계속해서 `.gif`(0x14000d2be)·`.webm`(0x14000d2fb) 분기와
`isScreensaver`(0x14000d69a) 설정으로 이어진다). 즉 **로드 1회당 1회**, 페이지가 뜨기 전에.

---

## 2. 동봉 5건 해석

| 워크샵 ID | 액션 수 | 대상 | 무엇을 → 무엇으로 |
| --- | --- | --- | --- |
| 780658164 | 4 | `index_files/index.min.js.Download`, `js/index.min.js`, `js/index2.min.js`, `js/index3.min.js` | `u(t,e){t.texImage2D` → `u(t,e){if(e!=null)t.texImage2D` |
| 780662613 | 4 | 〃 | 〃 |
| 780675904 | 4 | 〃 | 〃 |
| 854685299 | 4 | 〃 | 〃 |
| 784979889 | 1 | `js/index.js` | `new THREE.WebGLRenderer({alpha: true, …})` → `{alpha: false, …}` + `renderer.setClearColor( 0xe0dacd, 1)` |

### 2.1 texImage2D 널 가드 (4건 × 4액션 = 16액션)

동일한 전표가 4개 워크샵 항목에 복사돼 있다 — 같은 템플릿(three.js 기반 벽지)에서 파생된
벽지들이라는 뜻이다. 대상 4개는 같은 번들의 배포 변종이다:

- `index_files/index.min.js.Download` — 브라우저 "다른 이름으로 저장" 산출물(작성자가 그대로 업로드)
- `js/index.min.js`, `js/index3.min.js` — 미니파이어가 인자를 `(t,e)` 로 이름지은 판
- `js/index2.min.js` — **`(e,t)` 로 뒤집힌 판**(그래서 액션도 `u(e,t){if(t!=null)e.texImage2D`)

즉 이 전표는 "이름을 모르는 미니파이 산출물 4가지 변종을 전부 커버한다".

### 2.2 무엇을 고치는가

`u(t, e)` 는 three.js 의 텍스처 업로드 헬퍼다. `e` 가 `null`/`undefined` 일 때
`gl.texImage2D(target, level, internalformat, format, type, source)` 의 6인자 오버로드가
`null` source 를 받는다.

**WebGL 확장 차이가 아니다. 텍스처 포맷 문제도 아니다.** Chromium 의 WebGL 바인딩은
`TexImageSource` 파라미터가 `null` 이면 오버로드 해석 자체가 실패해
`TypeError` 를 던진다. 예외는 rAF 콜백을 타고 올라가 **그 프레임의 그리기 전체를 중단**시키고,
매 프레임 반복되므로 벽지가 검은 화면으로 굳는다. 브라우저에서는 이미지 로드가 캐시로
동기 완료돼 `e` 가 항상 채워져 있었지만, WE 의 로컬 스킴 + 첫 실행에서는 비어 있는 창이 생긴다.

가드 한 줄(`if(e!=null)`)이 그 프레임의 업로드만 건너뛰게 만든다 — 다음 프레임에 이미지가
도착하면 정상 업로드된다.

### 2.3 three.js alpha 배경 (784979889)

`new THREE.WebGLRenderer({alpha: true})` 는 캔버스를 **투명 배경**으로 만든다. 브라우저에서는
`<body>` 의 CSS 배경이 뒤에 깔리지만, WE 는 CEF 를 **데스크탑 창에 오프스크린 합성**하므로
투명 픽셀 뒤에 아무것도 없다 → 바탕화면이 비쳐 보이거나 검게 남는다.

패치는 `alpha: false` 로 바꾸고 **원저작자가 의도한 배경색을 하드코딩**한다
(`0xe0dacd` = 베이지). 이건 WE 운영자가 그 벽지를 직접 보고 고른 값이다 — 일반 규칙이 아니라
**개별 벽지 핫픽스**다. zcompat 이 워크샵 ID 별 파일인 이유가 이것이다.

### 2.4 그래서 zcompat 은 무엇인가

WebGL 확장/텍스처 업로드의 **엔진 차이 보정층이 아니다**. **개별 워크샵 항목의 버그를
운영자가 문자열 치환으로 핫픽스하는 채널**이다. "이 벽지의 이 줄을 이걸로 바꿔라" 가 전부다.

---

## 3. WE 가 주입하는 전역 API 전수

인코딩 확인: 설치본 전체를 `wallpaper[A-Za-z]{3,60}` 로 ASCII·UTF-16LE **둘 다** 훑었다.
주입 API 이름은 **전부 ASCII** 이고 UTF-16LE 판은 0건이다(UTF-16 히트는 `wallpaper_engine`,
`wallpaperservice`, `wallpaperuilog`, `wallpaperengine` — 전부 무관한 설정/로그 문자열).

설치본 `ui/dist` 에는 주입 스크립트가 **없다** — `ui/dist/scripts/scripts.js` 의 `wallpaper*`
심볼은 전부 브라우저 UI(`wallpaperBrowseInner`, `wallpaperThumbnail` …)다. **정본은
`webwallpaper64.exe` 의 `OnContextCreated` 와 그 안에서 평가되는 `___STAHP` 문자열이다.**

### 3.1 네이티브 등록 전역 10개 — `OnContextCreated` 0x140013280–0x1400143f7

등록 순서 그대로(각각 `CefV8Value::CreateFunction` → `global->SetValue`):

| # | 이름 | 등록 VA | 핸들러 처리 VA | 시그니처 |
| --- | --- | --- | --- | --- |
| 1 | `wallpaperRegisterAudioListener` | 0x14001340f | 0x140014a9f | `(cb)` — cb 는 **128개 double 배열** 1개를 받는다(0x140010c0f `mov edx,0x80`, 0x140010c58 `cmp esi,0x80`) |
| 2 | `wallpaperRegisterMediaPropertiesListener` | 0x1400135a0 | 0x140014bea | `(cb)` |
| 3 | `wallpaperRegisterMediaThumbnailListener` | 0x140013731 | 0x140014cd3 | `(cb)` |
| 4 | `wallpaperRegisterMediaPlaybackListener` | 0x1400138c2 | 0x140014f4c | `(cb)` |
| 5 | `wallpaperRegisterMediaTimelineListener` | 0x140013a52 | 0x140015035 | `(cb)` |
| 6 | `wallpaperRegisterMediaStatusListener` | 0x140013be2 | 0x14001511e | `(cb)` |
| 7 | `wallpaperGetUtilities` | 0x140013d73 | 0x140015376 | `() → {isScreensaver(), isWallpaper()}` — **함수 두 개짜리 객체**(0x1400154c5·0x140015604 가 `CreateFunction`) |
| 8 | `wallpaperRequestRandomFileForProperty` | 0x140013f04 | 0x14001592f | `(name, cb)` → 프로세스 메시지 `RequestRandomFile`(0x140015e48) |
| 9 | `wallpaperOnVideoEnded` | 0x140014097 | 0x14001617b | `()` → 프로세스 메시지 `OnVideoEnded`(0x1400161ef) |
| 10 | `wallpaperRequestTakeScreenshotResponse` | 0x140014226 | 0x140016367 | `(w, h, arrayBuffer)` → `RequestTakeScreenshot`(0x140016424) |

같은 함수의 끝(0x140014345 `mov edx, 0x1730` = 5,936바이트, 0x140014390 `CefV8Context::Eval`)에서
`___STAHP` 스크립트를 **document-start 에 평가**한다.

### 3.2 `___STAHP` 스크립트가 만드는 전역 (문자열 @0x119ca0, 5,936바이트)

**자체 전역 7개**

| 이름 | 내용 |
| --- | --- |
| `window.___STAHP` | 중복 주입 가드(`true`) |
| `window.___wpxShared` | `{hasLoaded, onLoadListeners[], onLoad(fn)}` — load 후 등록하면 즉시 호출 |
| `window.wallpaperMediaIntegration` | `{PLAYBACK_STOPPED:0, PLAYBACK_PLAYING:1, PLAYBACK_PAUSED:2}` |
| `window.___wpxAnimLocked` | 정지 중 플래그 |
| `window.___wpxPause` | rAF/타이머 큐잉 + CSS 애니메이션·`<video>`·`<audio>`·`AudioContext` 정지 |
| `window.___wpxUnpause` | 위의 역 + 큐잉된 rAF/interval/timeout 재발행 |
| `window.__wpxTakeSnapshot` | `getDisplayMedia({displaySurface:"browser"})` → canvas → jpeg → `wallpaperRequestTakeScreenshotResponse` |

**래핑 7개** — `requestAnimationFrame` · `cancelAnimationFrame` · `setInterval` · `clearInterval` ·
`setTimeout` · `clearTimeout` · `AudioContext`.
(정지 중 rAF/interval/timeout 을 최대 **1000개**(`maxQueue`)까지 큐잉했다가 해제 시 재발행한다.)

DOM 쪽으로는 `DOMContentLoaded` 에 `.wpxPausePseudoAnimations*` CSS 클래스를 심는다.

### 3.3 WE 가 **페이지에서 호출하는** 콜백 (페이지가 구현하는 규약)

브라우저 프로세스가 JS 문자열을 조립해 `ExecuteJavaScript` 로 넣는다 — 전부
`if(window.wallpaperPropertyListener&&window.wallpaperPropertyListener.<cb>){…(<args>);}` 형태.

| 콜백 | 조립 VA | 인자 |
| --- | --- | --- |
| `applyUserProperties` | 0x1400199e2–0x140019a74 | `<유저 프로퍼티 JSON>` |
| `applyGeneralProperties` | 0x140020730–0x1400207c2 | `{language: …}`(0x140020547–0x1400206e4). 코퍼스 실사용은 `properties.fps` 도 읽는다 |
| `setPaused` | 0x140020208–0x14002028e | `true`/`false`. **정지 시엔 뒤에 `___wpxPause()`, 해제 시엔 앞에 `___wpxUnpause()`** 가 붙고, 가드에 `&&!window.___wpxAnimLocked` 가 들어간다 |
| `userDirectoryFilesAddedOrChanged` | 0x140009c9a–0x14000a0c4 | `('<속성명>', ["f1","f2",…])` |
| `userDirectoryFilesRemoved` | 0x14000a0f7–0x14000a50a | 〃 |

플러그인 통지는 별도다(0x14001f568–0x14001f633):

```js
window.___wpxShared.onLoad(function(){
  window.wallpaperPluginListener && window.wallpaperPluginListener.onPluginLoaded('<name>', '<version>');
});
```

플러그인 이름이 `led`(0x14001f5e8) 이면 **같은 통지를 `'cue'` 로 한 번 더** 보낸다
(0x14001f611) — 동봉 `corsair_o_tron/js/main.js:416` 이 `if (name === 'cue')` 로 받는 그 경로다.

동영상 벽지용 래퍼 HTML(주입 원문 @0x1198f0)은 `v.onended` 에서 `window.wallpaperOnVideoEnded()`
를 부르고, `v.onerror` 에서 `src` 를 비웠다 되돌려 재로드한다.

---

## 4. Waple 대조 — 구현 / 스텁 / 없음

기준은 §3.1(네이티브 10) + §3.2 자체 전역 7 = **17개**. 도달 수는 설치본 웹 벽지
2건(`corsair_collection`, `corsair_o_tron`, JS/HTML/CSS/JSON 12파일)에서 센 문자열 도수다.

| # | 전역 | 도달 | 이번 작업 전 | 이번 작업 후 | 분류 |
| ---: | --- | ---: | --- | --- | --- |
| 1 | `wallpaperRegisterAudioListener` | 1 | 구현 | 구현 | 구현 |
| 2 | `wallpaperRegisterMediaPropertiesListener` | 0 | 구현 | 구현 | 구현 |
| 3 | `wallpaperRegisterMediaThumbnailListener` | 0 | 구현 | 구현 | 구현 |
| 4 | `wallpaperRegisterMediaPlaybackListener` | 0 | 구현 | 구현 | 구현 |
| 5 | `wallpaperRegisterMediaTimelineListener` | 0 | 구현 | 구현 | 구현 |
| 6 | `wallpaperRegisterMediaStatusListener` | 0 | 구현 | 구현 | 구현 |
| 7 | `wallpaperRequestRandomFileForProperty` | 0 | 구현 | 구현 | 구현 |
| 8 | `wallpaperMediaIntegration` | 0 | 구현 | 구현 | 구현 |
| 9 | **`wallpaperGetUtilities`** | 0 | **없음** | `{isScreensaver()→false, isWallpaper()→true}` | **구현(신규)** |
| 10 | **`___wpxShared`** | 0 | **없음** | `{hasLoaded, onLoadListeners, onLoad}` | **구현(신규)** |
| 11 | `___STAHP` | 0 | 중복주입 가드 존재 | 〃 | 구현(이름 상이) |
| 12 | `___wpxPause` | 0 | `__wapleHardPauseController.setPaused(true)` | 〃 | 구현(이름 상이) |
| 13 | `___wpxUnpause` | 0 | `…setPaused(false)` | 〃 | 구현(이름 상이) |
| 14 | `___wpxAnimLocked` | 0 | `…isPaused()` | 〃 | 구현(이름 상이) |
| 15 | **`wallpaperOnVideoEnded`** | 0 | 없음 | 전역 보장 + `VideoFallbackHTML` 이 호출 | **스텁(신규)** |
| 16 | **`wallpaperRequestTakeScreenshotResponse`** | 0 | 없음 | 인자 수용 후 폐기 | **스텁(신규)** |
| 17 | `__wpxTakeSnapshot` | 0 | 없음 | 없음 | **없음**(§6.1) |

**전역 17개 집계 — 구현 10 · 구현(이름 상이) 4 · 스텁 2 · 없음 1.**
"이름 상이" 4개는 기능이 `__wapleHardPauseController` 아래에 **완전히** 있다(정지 중
rAF/타이머 큐잉, CSS 애니메이션·WAAPI·`<video>`/`<audio>`·`AudioContext` 정지 — WE 의
`___STAHP` 보다 넓다). WE 이름으로 부르는 페이지는 없다(도달 0).

콜백 규약(§3.3) — 페이지가 구현하고 네이티브가 부르는 쪽:

| 콜백 | 도달 | 이번 작업 전 | 이번 작업 후 | 분류 |
| --- | ---: | --- | --- | --- |
| `applyUserProperties` | 4 | 구현 | 구현 | 구현 |
| `applyGeneralProperties` | 4 | 구현(`{fps:30}` 만) | + **`language` 기본값**(§5.2) | 구현 |
| `setPaused` | 4 | 구현 | 구현 | 구현 |
| `userDirectoryFilesAddedOrChanged` | 0 | 구현 | 구현 | 구현 |
| **`userDirectoryFilesRemoved`** | 0 | **없음** | 브리지 배달 경로 구현 | **스텁**(네이티브 트리거 미구현 — §6.3) |
| `wallpaperPluginListener.onPluginLoaded` | 2 | 없음 | 없음 | **없음**(§6.2) |

**콜백 6개 집계 — 구현 4 · 스텁 1 · 없음 1.**

**도달 수 상위는 전부 이미 구현돼 있었다**(propertyListener 4종 = 도달 4씩, 오디오 = 1).
도달 2 인 `onPluginLoaded` 만 미구현인데 그건 §6.2 의 이유로 **지어내면 안 되는** 자리다.
새로 채운 나머지는 도달 0 이지만, 없으면 `ReferenceError` 로 **스크립트 하나가 통째로 중단**
되는 부류라 존재 자체가 규약이다.

### 4.1 zcompat 도달

동봉 전표 5건이 겨냥하는 워크샵 항목(780658164 · 780662613 · 780675904 · 784979889 ·
854685299)은 이 컨테이너의 코퍼스에 **한 건도 설치돼 있지 않다**(설치본 웹 벽지는
`corsair_collection`·`corsair_o_tron` 둘뿐). 따라서 **실적용 도달은 0** 이고, 테스트는
전표 5건의 **파스·경로 대조·치환 결과**를 합성 입력으로 고정한다
(`Tests/WapleCoreTests/WebCompatPatchTests.swift`, 15케이스).

---

## 5. Waple 구현 노트

### 5.1 zcompat — 디스크가 아니라 서빙 시점

`WebCompatPatch`(WapleCore) 가 스키마 파스와 치환을, `WallpaperSchemeHandler` 가 적용을 맡는다.

- 전표 조회 키는 **프로젝트 폴더명**이다 — WE 도 같은 값을 쓴다(0x14000c29e).
- 전표 위치는 `BaseAssetsSettings.searchRoots` 아래의 `zcompat/web/<ID>.json`
  (사용자 지정 WE 설치본 → 앱 동봉 `WEAssets`). WE 의 `assets/` 접두는 붙이지 않는다 —
  `searchRoots` 가 이미 그 디렉터리를 가리킨다.
- 적용은 `respondFile` 안에서, 해당 상대 경로에 액션이 있을 때만. **Range 는 무시하고 200 전체**로
  낸다(치환이 길이를 바꾸므로 원본 오프셋 기준 범위가 결과와 대응하지 않는다. WebKit 은
  스크립트/문서에 Range 를 보내지 않고, 보내더라도 200 전체는 RFC 7233 상 허용되는 축소다).
- 32MB 상한을 넘으면 패치를 포기하고 원본을 스트리밍한다(무회귀).
- **디스크는 절대 안 건드린다.** 매 요청이 원본에서 출발하므로 WE 가 필요로 한 멱등성 논증에
  기대지 않는다.

**AppID 게이트(`431960`)는 재현하지 않았다.** 그건 윈도우 워크샵 설치 경로 관습이고
(`…/workshop/content/431960/<ID>/`), Waple 의 라이브러리 폴더 구조가 다르다. 전표가 워크샵 ID
로 키잉돼 있다는 사실이 이미 같은 범위를 만든다.

### 5.2 `applyGeneralProperties` 의 `language`

WE 는 **항상** `language` 를 담는다(0x140020547–0x1400206e4). 값의 형태는 설치본
`locale/ui_<코드>.json` 75개가 그대로 보여 준다 — `en-us`·`ko-kr` 같은 **소문자 BCP-47**.
Waple 의 네이티브 쪽(`WebRenderer`)은 아직 `{fps:30}` 만 보내므로, 브리지가 키가 비어 있을
때만 `navigator.language` 를 소문자화해 채운다. 네이티브가 실제 값을 넣으면 그쪽이 이긴다.

**근사임을 명시한다** — WE 값은 WE UI 언어 설정이고 Waple 값은 시스템 로케일이다.

---

## 6. WKWebView 로 불가능한 것 (짓지 않은 것)

### 6.1 화면 스냅샷 — `__wpxTakeSnapshot` / `wallpaperRequestTakeScreenshotResponse`

WE 의 구현은 **페이지 안에서** `navigator.mediaDevices.getDisplayMedia({audio:false,
video:{displaySurface:"browser", …}})` 로 자기 자신을 캡처해 canvas → jpeg → ArrayBuffer 로
네이티브에 돌려준다(주입 원문 @0x11a1c0 이후, 네이티브 트리거 0x140011d99).

WKWebView 에서 불가능한 이유:

1. **WKWebView 는 `getDisplayMedia` 를 구현하지 않는다.** macOS WKWebView 의 미디어 캡처
   지원은 `WKUIDelegate.webView(_:requestMediaCapturePermissionFor:…)` 를 통한
   **카메라·마이크뿐**이다(`WKMediaCaptureType` 에 `.display` 가 없다). 화면 공유 피커는
   Safari 앱의 기능이지 WebKit 임베더 API 가 아니다.
2. CEF 는 `--auto-select-desktop-capture-source` 류 스위치로 피커 없이 자기 탭을 고를 수
   있지만, WKWebView 에는 대응 스위치가 없다.

**대안(이미 있다)**: Waple 은 `WKWebView.takeSnapshot(with:completionHandler:)` 로 같은
결과를 **네이티브 쪽에서** 얻을 수 있다(`OffscreenCapture.swift` 가 이 계열이다). 페이지를
경유할 이유가 없으므로 페이지 왕복 프로토콜(`__wpxTakeSnapshot` → `…Response`)은 재현하지
않고, 전역만 스텁으로 둬서 호출이 예외로 번지지 않게 한다.

### 6.2 플러그인 로드 통지 — `wallpaperPluginListener.onPluginLoaded`

WE 는 `plugins/led/ledextensions64.dll`(Corsair iCUE / Razer Chroma SDK 브리지)을 로드하고
그 결과를 페이지에 알린다. 이 DLL 은 **윈도우 전용 하드웨어 SDK 래퍼**이고 macOS 대응물이
없다. 도달이 2건 있지만(두 코르세어 벽지 모두), 두 벽지 다 `onPluginLoaded` 가 오지 않으면
LED 출력만 조용히 생략하고 화면 렌더는 정상 동작한다(`corsair_o_tron/js/main.js:415` 는
등록만 하고 나머지 렌더 루프는 독립이다).

**호출을 지어내지 않는다.** 존재하지 않는 `cue` 플러그인을 로드했다고 통지하면 벽지가
`CorsairGetDeviceCount` 류 후속 호출로 진입해 예외를 낸다 — 조용한 미통지가 정확한 축소다.

### 6.3 `userDirectoryFilesRemoved` 의 네이티브 트리거

브리지 쪽(`__wapleDirectoryFilesRemoved` → `listener.userDirectoryFilesRemoved`)은 채웠다.
이걸 발화시킬 디렉터리 감시(WE 는 `FindFirstChangeNotification`, 실패 로그 @0x118ff0)는
`WebRenderer` 소관이라 이번 범위 밖이다. **WKWebView 의 한계가 아니라 미구현**이다 —
`DispatchSource.makeFileSystemObjectSource` 로 구현 가능하다.

---

## 7. 부록 — `zcompat/scene/shaders/*` (웹이 아닌 쪽)

같은 `zcompat` 트리 아래 씬 셰이더용 전표가 2건 있고 **스키마가 다르다**:

```json
{ "maximumprojectid": "9223372036854775807", "frag": "pixelate.frag", "vert": "pixelate.vert" }
```

- 키는 `maximumprojectid` · `frag` · `vert` 3개.
- 디렉터리명이 **셰이더 ID**(2078835426 = pixelate, 2084198056 = Simple_Audio_Bars).
- `maximumprojectid` 는 "이 ID 이하의 프로젝트에만 대체 셰이더를 쓴다" 는 상한으로 읽힌다
  (2078835426 은 `9223372036854775807` = `INT64_MAX` = 전부, 2084198056 은 `2638335396`).
- **이 문자열들은 `webwallpaper64.exe` 에 없다** — 웹 파서와 별개 경로다. 이번 과제 범위(웹)
  밖이라 파서 VA 는 확정하지 않았다.

## 8. 미확정으로 남긴 것

- **전표 디렉터리의 기준 경로.** 0x140006b20(`GetModuleFileNameW`) → 0x140006790(부모) →
  `/ "assets/zcompat/web"` 까지는 확정했지만, 설치본에서 `assets/` 는 루트에 있고 실행 파일은
  `bin/` 에 있다. 부모를 한 번만 벗기면 `bin/assets/…` 가 되어 실물과 맞지 않는다 —
  작업 디렉터리 의존이거나 0x140006790 의 판독이 한 단계 부족하다. **Waple 은 검색 루트를
  따로 갖기 때문에 이 자리를 확정할 실익이 없어 더 파지 않았다.** 확정 없이 인용만 한다.
- **`applyGeneralProperties` 의 `fps` 발신처.** 코퍼스가 `properties.fps` 를 읽고
  (`corsair_o_tron/js/main.js:330`) WE 문서도 그렇게 적지만, `webwallpaper64.exe` 에서 찾은
  `fps` 문자열 참조(0x140020838)는 설정 리더 쪽이고 general-properties 조립부가 아니다.
  다른 프로세스(브라우저 쪽 `wallpaper64.exe`)에서 오는 값일 가능성이 있다.
