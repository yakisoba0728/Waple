# 리눅스에서 WapleRender 타입체크하기

`scripts/dev/linux-render-typecheck.sh` 는 `Sources/WapleRender/**` 를 **리눅스에서
`swiftc -typecheck`** 한다. macOS CI 왕복(약 10분) 없이 스코프·타입 오류를 커밋 전에 잡는다.

```bash
scripts/dev/linux-render-typecheck.sh          # 커버 대상 전체 타입체크
scripts/dev/linux-render-typecheck.sh --list   # 커버/제외 목록만
```

작업 디렉터리는 `WAPLE_LINUX_TYPECHECK_DIR`(기본 `$TMPDIR/waple-linux-render-typecheck`).
스크립트는 **스스로 공유 락을 잡는다**(`WAPLE_SWIFT_LOCK`, 기본은 작업 디렉터리의 상위 +
`/swift.lock`) — 이 컨테이너에서 동시 swift 빌드 2개는 OOM 으로 컨테이너를 재시작시킨다
(실측: 실제로 당했다). `linux-core-tests.sh` 는 스스로 락을 잡지 않으므로 호출자가 `flock` 으로
감싸는 관례인데, 작업 디렉터리를 같은 부모 아래 두면 락 파일이 저절로 같아진다:

```bash
SC=<공유 스크래치패드>
WAPLE_LINUX_TYPECHECK_DIR="$SC/linux-render-typecheck" \
  scripts/dev/linux-render-typecheck.sh          # → 락은 $SC/swift.lock
flock -w 3600 "$SC/swift.lock" env WAPLE_LINUX_TEST_DIR="$SC/linux-tests-shared" \
  scripts/dev/linux-core-tests.sh --filter …     # → 같은 락
```

## 왜 필요한가

WapleRender 는 `import Metal`/`MetalKit`/`AppKit` 이라 리눅스에서 `swiftc -parse` 밖에 못 돌린다.
**`-parse` 는 타입체크를 하지 않는다** — 문법만 본다. 그래서 `-parse` 의 rc=0 은 아무것도
보장하지 않고, 이 브랜치에서 그 공백으로 macOS CI 가 두 번 깨졌다:

| 커밋 | 결함 | `-parse` | 이 도구 |
|---|---|---|---|
| `b98db0a` | `Mesh3DShaders.swift:152` — Swift 멀티라인 리터럴 안 MSL 주석의 `\n` 하나가 MSL 147행을 깼다 | rc=0 (놓침) | **못 잡는다**(아래 한계 ①) |
| `bb5f902` | `SceneRendererResources.swift:1214` — 그 스코프에 없는 이름 `texW`/`texH` | rc=0 (놓침) | **잡는다**(양성 대조 아래) |

## 어떻게 도는가

`scripts/dev/linux-shim/` 의 **대역(shim) 모듈**을 `swiftc -emit-module` 로 만들고, 같은
모듈 검색 경로(`-I`)에서 커버 대상 소스를 `-typecheck` 한다. `Sources/` 는 한 글자도 건드리지
않는다(복사도 링크도 하지 않고 경로를 그대로 넘긴다).

심 모듈(전부 `scripts/dev/linux-shim/`):

| 모듈 | 파일 | 비고 |
|---|---|---|
| `CoreGraphics` | `coregraphics.swift` | CG* + **CoreFoundation 최소분**(`CFData`=`NSData` 등) + `FoundationNetworking` 재수출 |
| `QuartzCore` | `quartzcore.swift` | `CALayer`, `CACurrentMediaTime` |
| `Metal` | `metal.swift` | MTL* 전부 |
| `AppKit` | `appkit.swift` | `NSView`/`NSWindow`/`NSScreen`/`NSEvent`/`NSImage`/… **쓰는 것만** |
| `MetalKit` | `metalkit.swift` | `MTKView`, `MTKViewDelegate` |
| `CoreVideo` | `corevideo.swift` | `CVPixelBuffer`, `CVMetalTextureCache` |
| `AVFoundation` | `avfoundation.swift` | AV* + CoreMedia(`CMTime`·`CMSampleBuffer`) + CoreAudio(`AudioBufferList`) |
| `ScreenCaptureKit` | `screencapturekit.swift` | `SCStream` 계열 — **확신도 낮음** |
| `CoreText` | `coretext.swift` | `CTFont`/`CTLine`/`CTTypesetter` |
| `ImageIO` | `imageio.swift` | `CGImageSource` |
| `Accelerate` | `accelerate.swift` | vDSP FFT + vImage 회전/미러 |
| `JavaScriptCore` | `javascriptcore.swift` | `JSContext`, `JSValue` |
| `CryptoKit` | `cryptokit.swift` | `SHA256` |
| `Compression` | `compression.swift` | `compression_decode_buffer` |
| `simd` | `simd.swift`(기존) + `simd-extra.swift`(신규) | `simd-extra` 는 렌더 계층이 쓰는 것만 보탠다 |
| `WapleCore` | 실제 소스 + `corefoundation.swift` | 매 실행 다시 만든다 |

`simd.swift` 와 `corefoundation.swift` 는 `linux-core-tests.sh`(코어 테스트) 자산이라 건드리지
않았다. `simd-extra.swift` 는 이 스크립트만 함께 컴파일하며, `simd.swift` 에 이미 있는 것을
다시 선언하면 중복 선언 오류가 난다(그 목록이 `simd-extra.swift` 머리말에 있다).

`CFGetTypeID`/`CFBooleanGetTypeID` 만은 `WapleCore` 를 통해 나간다 —
`UserPropertyStore.swift`(WapleRender)가 `Foundation`+`WapleCore` 만 import 하는데 애플에서는
Foundation 이 CoreFoundation 을 재수출하기 때문이다. 스크립트가 읽기 전용 코어 심을
`sed` 로 그 **두 심볼만 public** 으로 바꿔 넣는다(사본이 아니라 파생이라 원본과 어긋날 수 없다).

## 커버 범위

`Sources/WapleRender/**` 의 `.swift` **55개 중 49개**가 타입체크된다(행 기준 약 92% —
제외 6파일이 1,828행이고 트리 전체가 약 24,250행. 행수는 계속 바뀌므로 파일 수가 정본이다).
실측(2026-08-21, 4코어 컨테이너): 심 모듈 빌드 ~5초 + `WapleCore` emit-module ~22초 +
**타입체크 32초**. 락 대기는 별도다.
목록은 스크립트의 `COVERED` 배열이 정본이고 `--list` 로 볼 수 있다.
`OggVorbis/` 하위 6개도 포함한다.

스크립트는 **커버/제외 목록이 실제 트리와 정확히 일치하는지** 매 실행 검사하고 어긋나면
실패한다. 새 파일이 조용히 커버 밖으로 떨어지는 것을 막는다(이런 도구가 죽는 가장 흔한 방식).

### 제외 파일과 이유

| 파일 | 행 | 이유 |
|---|---|---|
| `WebRenderer.swift` | 704 | WebKit(`WKWebView`·`WKNavigationDelegate`·`WKScriptMessageHandler`·`WKUserContentController`) 심 미작성 |
| `WebInputProxyView.swift` | 177 | WebKit + `NSTrackingArea`/`NSColor`/`NSCoder` 등 AppKit 심층 표면 |
| `WallpaperSchemeHandler.swift` | 346 | WebKit(`WKURLSchemeHandler`·`WKURLSchemeTask`) + `UniformTypeIdentifiers`(`UTType`) |
| `RendererFactory.swift` | 47 | `WebRenderer(mode:)` 를 직접 생성 — 위 셋이 들어와야 같이 들어온다 |
| `VideoRenderer.swift` | 340 | `AVPlayerLayer` + **KVO**(`NSKeyValueObservation`, `item.observe(\.status)`) — 리눅스 Foundation 에는 KVO 자체가 없다 |
| `FFmpegConverter.swift` | 214 | `VideoRenderer.unsupportedExtensions` 를 단일 출처로 참조 — VideoRenderer 와 한 묶음 |

합계 1,828행(전체의 7.5%). 넷은 WebKit 한 덩어리이고 둘은 KVO 한 덩어리다 —
둘 중 하나를 심으로 메우면 세 파일씩 함께 들어온다.

## 한계 — 이 도구가 **못** 하는 것

① **MSL/GLSL/JS 문자열 리터럴의 내용은 검사하지 않는다.** `b98db0a` 류(Swift 리터럴 안의
   셰이더 문법)는 여기서 rc=0 이다. 그쪽은 `scripts/spec/check_swift_escapes.py` 와
   `WapleCore` 의 셰이더 테스트가 담당한다.

② **심이 실제 프레임워크와 다르면 거짓 통과/거짓 실패가 난다.** 심은 애플 헤더에서 기계적으로
   뽑은 것이 아니라 **손으로 적은 것**이다. 각 선언 위에 실제 시그니처를 주석으로 적었고,
   확신 없는 자리는 `확신 없음` 이라고 표시했다. 확신도가 낮은 순서:
   - `screencapturekit.swift` — 헤더를 못 봤고 호출부에서 역산했다. `SCShareableContent`
     의 async 팩토리와 `SCStream.addStreamOutput` 의 throws 여부가 미확인.
   - `avfoundation.swift` 의 `AVAsyncProperty`(`asset.load(.duration)`) — 타입 이름·제네릭
     배치가 역산이다.
   - `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` 의 인자 라벨 배치.
   - 열거형 원시값(예: `MTLPixelFormat`)은 이름만 맞추었다. 코드가 `rawValue` 로 왕복을
     시작하면 그때부터 거짓이 된다.

③ **`@objc optional` 프로토콜 요구사항의 셀렉터 어긋남을 못 잡는다.** `SCStreamOutput` 과
   `AVAudioPlayerDelegate` 는 애플에서 optional 이라 이름이 어긋나도 컴파일이 통과하고
   콜백만 조용히 안 온다. 심은 기본 구현으로 그 성질을 재현하므로 **같은 함정을 그대로 둔다.**

④ **동시성 진단(`@MainActor`·`Sendable`)은 macOS 와 다를 수 있다.** 애플 SDK 의 격리
   어노테이션(과 `@preconcurrency` 강등)이 심에는 없다. 심의 타입은 전부 비격리다.

⑤ **런타임 동작은 전혀 검증하지 않는다.** 심 본문은 `fatalError("linux shim")`/더미값이다.

⑥ 다른 작업이 같은 트리에서 `Sources/WapleCore/**` 를 고치는 중이면 swiftc 가
   `input file ... was modified during the build` 로 죽는다. 스크립트가 3회까지 재시도한다.

⑦ **한 번에 모든 오류가 나오지 않는다.** swiftc 드라이버는 파일을 배치로 나눠 돌리고
   한 배치가 실패하면 **남은 배치를 스케줄하지 않는다**. 그래서 출력에 보이는 오류가 전부라고
   믿으면 안 된다 — 고치고 다시 돌려라. (실측: 37파일 중 `UserPropertyStore.swift` 2건만 찍히고
   같은 실행에서 `SceneRenderer.swift` 의 368건이 통째로 안 나왔다.)

**최종 판정자는 여전히 macOS CI 다.** 이 도구는 왕복 횟수를 줄이는 것이지 CI 를 대체하지 않는다.

## 양성 대조 — 이 도구가 실제로 잡는지

`bb5f902` 이전(= `990aa2a`)의 `SceneRendererResources.swift` 를 끼워 넣으면 잡혀야 한다.

```bash
git show 990aa2a:Sources/WapleRender/SceneRendererResources.swift > /tmp/old.swift
scripts/dev/linux-render-typecheck.sh --replace SceneRendererResources.swift=/tmp/old.swift
```

실측(2026-08-21):

```
== 치환: SceneRendererResources.swift → …/SceneRendererResources-990aa2a.swift
== 타입체크: 49 파일 (제외 6) ==
…/SceneRendererResources-990aa2a.swift:1214:51: error: cannot find 'texW' in scope
…/SceneRendererResources-990aa2a.swift:1214:69: error: cannot find 'texH' in scope
== FAIL (rc=1)
```

`bb5f902` 커밋 메시지가 macOS 빌드 로그에서 인용한 자리(`1214:51 texW` · `1214:69 texH`)와
행·열이 정확히 같다. 이 대조가 통과하지 않으면 도구가 고장난 것이다 — 커버 목록이 줄었거나,
심이 그 이름을 우연히 정의해 버렸거나, `--replace` 가 실제로 안 먹은 경우다(**실제로 겪었다**:
락 재실행이 인자를 잃어 도구가 원본을 검사하고 rc=0 을 줬다. 그래서 이 대조가 필요하다).

음성 대조는 인자 없이 돌리는 것 자체다(현 트리에서 rc=0, 타입체크 32초).

추가로 잰 것(같은 방식의 `--replace` 돌연변이 3종):

| 돌연변이 | 기대 | 실측 |
|---|---|---|
| `Scene3DMath.swift` — `simd_determinant(upper)` → `simd_determinant("upper")` | 잡힘 | rc=1, `85:27 no exact matches in call to global function 'simd_determinant'` |
| `TextRasterizer.swift` — `ascent` → `ascentt`(스코프에 없는 이름) | 잡힘 | rc=1, `117:26 cannot find 'ascentt' in scope` |
| `Mesh3DShaders.swift` — MSL 리터럴 안 주석에 `\n` 삽입(`b98db0a` 재현) | **못 잡음** | rc=0 ← 한계 ① 의 실측 근거 |

## CI

**현재 `.github/workflows/spec.yml` 에 넣지 않았다.**

`spec.yml` 의 잡은 `ubuntu-latest` 인데 이 리포의 워크플로 어디에도 리눅스 Swift 툴체인을
설치·참조하는 단계가 없다(`ci.yml` 의 Swift 잡은 전부 `macos-26`). 로컬 `/opt/swift` 는
개발 컨테이너의 경로이지 GitHub 러너의 경로가 아니다.

**확정**: `actions/runner-images` 의 이미지 목록에는 Ubuntu 22.04/24.04 둘 다 `Swift 6.3.3` 이
들어 있다(`images/ubuntu/Ubuntu2404-Readme.md`, 2026-08-21 확인). 즉 툴체인 자체는 있다.

**미해결**: 그 러너의 Swift 는 **6.3.3** 이고 이 도구를 검증한 로컬 툴체인은 **6.0.3** 이다.
버전이 다른 컴파일러가 새 진단을 내는지 여기서는 잴 수 없다. `-swift-version` 을 명시하지
않으므로 두 쪽 다 언어 모드 5 로 도는 것이 기대값이지만 **실측하지 않았다.**
그래서 이 커밋에서는 게이트를 넣지 않았다 — 검증 없이 넣어 CI 를 새로 깨뜨리는 것이
이 도구가 막으려던 바로 그 실패이기 때문이다.

넣기 전에 한 번 재라(`spec` 잡에 임시 단계 하나, 실패하지 않는다):

```yaml
      - name: Probe swift on runner
        run: command -v swift && swift --version || echo "no swift on ubuntu-latest"
```

`swift` 가 확인되면 아래를 `spec` 잡 끝에 붙인다(`WAPLE_SWIFT_BIN` 은 `command -v swift` 의
디렉터리로):

```yaml
      # WapleRender 는 Metal/AppKit 의존이라 리눅스에서 `swiftc -parse` 밖에 못 돌았고,
      # `-parse` 는 타입체크를 하지 않는다 — 그 공백에서 macOS CI 가 두 번 깨졌다
      # (`b98db0a`, `bb5f902`). 대역 모듈로 진짜 타입체크를 돌린다.
      # 한계와 제외 목록은 docs/dev/linux-typecheck.md.
      - name: WapleRender linux typecheck
        run: |
          WAPLE_SWIFT_BIN="$(dirname "$(command -v swift)")" \
          WAPLE_LINUX_TYPECHECK_DIR="$RUNNER_TEMP/waple-typecheck" \
          WAPLE_SWIFT_LOCK="$RUNNER_TEMP/swift.lock" \
            scripts/dev/linux-render-typecheck.sh
```

`swift` 가 없으면 `swift-actions/setup-swift` 같은 설치 단계가 먼저 필요하고, 그러면
`spec` 잡의 "ubuntu 에서 수십 초" 라는 성질이 깨진다 — 그 경우 별도 잡으로 떼는 편이 낫다.

## 심을 고쳐야 할 때

- **커버 대상이 새 프레임워크 API 를 쓰기 시작하면** `cannot find X in scope` 로 즉시 드러난다
  (조용한 실패가 없다). 해당 심 파일에 선언을 보태고 **실제 시그니처를 주석으로 남겨라.**
- **심 시그니처가 틀렸다고 의심되면** macOS `swift build` 가 유일한 심판이다. 심이 통과시킨
  코드가 macOS 에서 깨졌다면 그 자리를 심에 반영하고 이 문서의 "확신도" 목록을 갱신해라.
- **새 소스 파일을 추가하면** 스크립트가 목록 불일치로 실패한다. `COVERED` 나 `EXCLUDED` 에
  넣고 이 문서의 표를 갱신해라.
