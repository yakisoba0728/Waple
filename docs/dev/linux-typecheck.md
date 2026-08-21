# 리눅스에서 WapleRender 타입체크하기

`scripts/dev/linux-render-typecheck.sh` 는 `Sources/WapleRender/**` 를 **리눅스에서
`swiftc -typecheck`** 한다. macOS CI 왕복(약 10분) 없이 스코프·타입 오류를 커밋 전에 잡는다.

```bash
scripts/dev/linux-render-typecheck.sh          # 커버 대상 전체 타입체크
scripts/dev/linux-render-typecheck.sh --list   # 커버/제외 목록만
```

작업 디렉터리는 `WAPLE_LINUX_TYPECHECK_DIR`(기본 `$TMPDIR/waple-linux-render-typecheck`).

스크립트는 **스스로 락을 잡는다.** 이 컨테이너에서 동시 swift 빌드 2개는 OOM 으로 컨테이너를
통째로 재시작시킨다(실측: 실제로 당했다). 기본 락은 **작업 디렉터리와 무관한 고정 경로**
`$TMPDIR/waple-swift.lock` 이고, 실행할 때마다 어느 락을 잡는지 첫 줄에 찍는다.

> **[2026-08-21] 락 기본값을 유도에서 고정으로 바꿨다.** 종전엔 작업 디렉터리의 상위에서
> 유도했는데, 그러면 `WAPLE_LINUX_TYPECHECK_DIR` 을 다르게 잡은 두 실행이 **서로 다른 락**을
> 잡아 상호배제가 아예 안 된다. 실측으로 `/tmp/swift.lock` 과 `<스크래치패드>/swift.lock` 이
> 동시에 잡혀 있는 것을 봤다 — 유도 기본값은 안전해 **보이기만** 했다.

다른 swift 작업과 묶으려면 `WAPLE_SWIFT_LOCK` 을 **명시해라**(`linux-core-tests.sh` 는 스스로
락을 잡지 않으므로 호출자가 `flock` 으로 감싸는 관례다):

```bash
SC=<공유 스크래치패드>
WAPLE_SWIFT_LOCK="$SC/swift.lock" WAPLE_LINUX_TYPECHECK_DIR="$SC/linux-render-typecheck" \
  scripts/dev/linux-render-typecheck.sh
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

`Sources/WapleRender/**` 의 `.swift` **55개 중 51개**가 타입체크된다(행 기준 약 95% —
제외 4파일이 1,274행이고 트리 전체가 약 24,250행. 행수는 계속 바뀌므로 파일 수가 정본이다).

> **[2026-08-21] 49 → 51.** `VideoRenderer.swift`·`FFmpegConverter.swift` 가 KVO
> (`NSKeyValueObservation`·`observe(_:options:changeHandler:)`)와 `AVPlayerLayer` 심이
> 붙으면서 들어왔다. 이제 남은 제외는 **WebKit 한 덩어리뿐**이다.
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

합계 1,274행(전체의 약 5%). **넷이 전부 WebKit 한 덩어리다** — `WKWebView`·
`WKNavigationDelegate`·`WKScriptMessageHandler`·`WKURLSchemeHandler`(+`UTType`) 심을
쓰면 네 파일이 한꺼번에 들어와 55/55 가 된다.

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

**현재 상태: `spec.yml` 에 프로브 한 스텝만 들어가 있다. 게이트는 아직 아니다.**

### 확정된 것 (1차 자료 실측, 2026-08-21)

| 사실 | 근거 |
|---|---|
| `ubuntu-latest` = **Ubuntu 24.04** | `actions/runner-images` README 의 라벨 표 |
| 그 이미지(`20260816.277.1`)에 **Swift 6.3.3** 동봉 | `images/ubuntu/Ubuntu2404-Readme.md` |
| `swift`·`swiftc` 가 **`/usr/local/bin`** 에 심링크, 실체는 `/usr/share/swift` | `images/ubuntu/scripts/build/install-swift.sh` |
| `SWIFT_PATH=/usr/share/swift/usr/bin` 이 `/etc/environment` 에 박힌다 | 같은 스크립트 |

즉 **툴체인은 있고 PATH 에도 있다.** `swift-actions/setup-swift` 같은 설치 단계는 필요 없고,
`spec` 잡의 "ubuntu 에서 수십 초" 라는 성질도 설치 때문에 깨지지는 않는다
(실측: 최근 `spec` 잡 전체가 15~28초 — run `32473541352` 는 18초, 잡 `timeout-minutes: 10`).

### 미해결 — 그래서 아직 게이트가 아니다

1. **버전이 다르다.** 이 도구를 검증한 로컬 툴체인은 **6.0.3** 이고 러너는 **6.3.3** 이다.
   심 15종은 애플 헤더에서 기계 생성한 것이 아니라 **손으로 적은 것**이라(한계 ②), 새 컴파일러가
   추가 진단을 내면 그대로 빨간불이 된다. 여기서는 잴 수 없다.
2. **기본 언어 모드를 모른다.** 이 도구는 `-swift-version` 을 넘기지 않으므로 러너 기본 모드가
   5 여야 전제가 선다. 6.0.3 에서는 기본이 5 다(아래 프로브의 음성 대조 참조).
3. **러너의 Swift 버전은 움직인다.** `install-swift.sh` 가 이미지 빌드 시점의 `apple/swift`
   **releases/latest** 를 받는다. 게다가 `ubuntu-latest` 라벨 자체가 26.04 로 이동 중이다
   (runner-images README 의 공개 프리뷰 공지). **게이트를 넣는다면 `runs-on` 을 `ubuntu-24.04` 로
   고정해라** — 안 그러면 이미지 갱신이 어느 날 조용히 CI 를 깬다.
4. **도구 자체가 이 세션에 바뀌는 중이다.** 커버 목록(`COVERED`/`EXCLUDED`)이 확장되고 있다.
   움직이는 도구를 차단 게이트로 올리면 실패 원인이 "코드" 인지 "도구" 인지 못 가른다.

### 1단계 — 프로브 (**들어가 있다**)

`spec.yml` 마지막 스텝 `Probe swift on runner`. `set +e` 로 돌고 마지막 명령이 `:` 라
**어떤 경우에도 rc=0** 이다. 로컬 음성 대조(2026-08-21): `swift` 가 PATH 에 **없을 때**도 rc=0
(전건 `command not found`), **있을 때**도 rc=0.

기본 언어 모드 판정에 쓰는 스니펫과 그 돌연변이 실측(로컬 6.0.3):

| 인자 | rc | 진단 |
|---|---|---|
| (없음 — 기본) | 0 | — |
| `-swift-version 5` | 0 | — |
| `-swift-version 6` | **1** | `main actor-isolated var 'probeGlobal' can not be mutated from a nonisolated context` |

즉 프로브가 rc=0 을 주면 러너 기본 모드도 5 이고, rc≠0 이면 전제가 깨진 것이다.

**읽는 법**: `python3 scripts/dev/ci-status.py --branch <브랜치> --jobs` 로 `spec` 잡 id 를 받고
`python3 scripts/dev/ci-status.py --log <JOB_ID>` 로 발췌한다.

### 2단계 — 판단 규칙

프로브 로그를 읽고 **아래 표대로만** 움직여라. 표에 없는 상태면 넣지 마라.

| 프로브 결과 | 다음 |
|---|---|
| `swift --version` rc≠0 또는 `<none>` | **넣지 마라.** 설치 단계가 필요하고 그러면 별도 잡으로 떼는 게 맞다 |
| 버전이 **6.0.x** (로컬과 동일) + 언어 모드 rc=0 | 3단계(관측)를 건너뛰고 바로 4단계(게이트)로 가도 된다 |
| 버전이 **6.3.3**(예상) + 언어 모드 rc=0 | **3단계(관측)를 먼저 돌려라.** 진단 차이를 안 보고 게이트로 올리지 마라 |
| 언어 모드 rc≠0 | **넣지 마라.** 도구에 `-swift-version 5` 를 넘기도록 고치는 게 먼저다(스크립트 소유자에게 넘겨라) |

### 3단계 — 관측 (초록을 깨지 않고 6.3.3 의 진단을 본다)

`spec` 잡 끝에 붙인다. **`continue-on-error` 와 `timeout` 을 둘 다 쓴다** — 이 리포는
`continue-on-error` 만으로 실패가 조용히 묻히는 것을 이미 겪었으므로(`ci.yml` 의 release 레인)
결과를 반드시 요약과 `::warning::` 으로 띄운다.

```yaml
      - name: WapleRender linux typecheck (관측 전용 — 게이트 아님)
        continue-on-error: true
        run: |
          set +e
          # `timeout` 을 안에서도 건다 — 스텝이 매달려 잡 timeout-minutes(10)를 먹으면
          # continue-on-error 와 무관하게 잡이 죽을 여지를 아예 없앤다.
          # 로컬 실측(4코어): 심 ~5초 + WapleCore emit-module ~22초 + 타입체크 ~32초.
          timeout 420 env \
            WAPLE_SWIFT_BIN="${SWIFT_PATH:-$(dirname "$(command -v swiftc)")}" \
            WAPLE_LINUX_TYPECHECK_DIR="$RUNNER_TEMP/waple-typecheck" \
            WAPLE_SWIFT_LOCK="$RUNNER_TEMP/swift.lock" \
            scripts/dev/linux-render-typecheck.sh 2>&1 | tee typecheck.log
          rc=${PIPESTATUS[0]}
          echo "rc=$rc"
          {
            echo "### 리눅스 타입체크 (관측 전용, rc=$rc)"
            echo ""
            if [ "$rc" -eq 0 ]; then
              echo "러너 툴체인에서도 rc=0 — 게이트로 올릴 근거가 섰다."
            else
              echo '```'
              grep -E "error:|!!" typecheck.log | head -40
              echo '```'
            fi
          } >> "$GITHUB_STEP_SUMMARY"
          [ "$rc" -eq 0 ] || echo "::warning title=리눅스 타입체크 관측 실패(rc=$rc)::게이트가 아니라 관측 단계다. 진단이 심(shim) 문제인지 실제 코드 문제인지 가른 뒤에 게이트로 올려라."
          :
```

`WAPLE_SWIFT_BIN` 은 `SWIFT_PATH` 를 먼저 쓴다 — `/usr/local/bin` 에는 `swift`·`swiftc`
심링크만 있고, 도구는 `$WAPLE_SWIFT_BIN/swiftc` 가 실행 가능하기만 하면 되므로 둘 다 되지만
실체 경로 쪽이 안전하다.

### 4단계 — 게이트 (3단계가 rc=0 을 준 **뒤에만**)

위 블록에서 `continue-on-error`·`set +e`·마지막 `:` 를 빼고 `runs-on` 을 `ubuntu-24.04` 로
고정한다. 그 전에 `docs/dev/linux-typecheck.md` 의 이 절과 `AGENTS.md` 를 함께 갱신할 것.

**한 번에 두 단계를 넣지 마라.** 프로브 → 관측 → 게이트를 각각 별도 커밋으로 밀어야
어느 단계에서 어긋났는지 한 번의 실행으로 갈린다.

## 심을 고쳐야 할 때

- **커버 대상이 새 프레임워크 API 를 쓰기 시작하면** `cannot find X in scope` 로 즉시 드러난다
  (조용한 실패가 없다). 해당 심 파일에 선언을 보태고 **실제 시그니처를 주석으로 남겨라.**
- **심 시그니처가 틀렸다고 의심되면** macOS `swift build` 가 유일한 심판이다. 심이 통과시킨
  코드가 macOS 에서 깨졌다면 그 자리를 심에 반영하고 이 문서의 "확신도" 목록을 갱신해라.
- **새 소스 파일을 추가하면** 스크립트가 목록 불일치로 실패한다. `COVERED` 나 `EXCLUDED` 에
  넣고 이 문서의 표를 갱신해라.
